"""Read authored transitional PPTX slide tables without importing native objects.

Spans are half-open offsets into the returned original UTF-8 slide-part bytes.
This strict read subset does not establish actual UNO identity or write rights.
"""
import hashlib
from contextlib import contextmanager, ExitStack
import os
from pathlib import Path
import posixpath
import re
import struct
import tempfile
from types import SimpleNamespace
from urllib.parse import urlsplit
from xml.parsers import expat
import zipfile


P = 'http://schemas.openxmlformats.org/presentationml/2006/main|'
A = 'http://schemas.openxmlformats.org/drawingml/2006/main|'
R = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
PKG = 'http://schemas.openxmlformats.org/package/2006/relationships|'
CT = 'http://schemas.openxmlformats.org/package/2006/content-types|'
TABLE = 'http://schemas.openxmlformats.org/drawingml/2006/table'
MAIN_CONTENT_TYPE = 'application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml'
SLIDE_CONTENT_TYPE = 'application/vnd.openxmlformats-officedocument.presentationml.slide+xml'
PART_BYTES, TOTAL_XML_BYTES = 8 * 1024 * 1024, 32 * 1024 * 1024
MEMBER_LIMIT, XML_DEPTH, XML_NODES = 4096, 64, 131072


class _Element:
    __slots__ = ('name', 'attributes', 'start', 'end', 'tag_end', 'empty', 'children')

    def __init__(self, name, attributes, start, tag_end, empty):
        self.name, self.attributes = name, attributes
        self.start, self.end, self.tag_end, self.empty = start, None, tag_end, empty
        self.children = []


def _tag_end(data, start):
    if data[start:start + 1] != b'<':
        raise ValueError('A source XML tag has no exact byte location')
    quote = None
    for index in range(start + 1, len(data)):
        value = data[index]
        if quote is not None:
            if value == quote:
                quote = None
        elif value in (34, 39):
            quote = value
        elif value == 62:
            return index + 1
    raise ValueError('A source XML tag is incomplete')


def _xml(data, budget):
    data.decode('utf-8')
    parser = expat.ParserCreate(namespace_separator='|')
    stack, roots = [], []

    def charge(*arguments):
        budget['nodes'] += 1
        if budget['nodes'] > XML_NODES:
            raise ValueError('PPTX source XML node limit exceeded')

    def declaration(version, encoding, standalone):
        if version != '1.0' or encoding is not None and encoding.upper().replace('-', '') != 'UTF8':
            raise ValueError('Unsupported PPTX source XML encoding or version')

    def forbidden(*arguments):
        raise ValueError('PPTX source DTD and entity declarations are unsupported')

    def start(name, attributes):
        charge()
        if len(stack) >= XML_DEPTH:
            raise ValueError('PPTX source XML depth limit exceeded')
        offset = parser.CurrentByteIndex
        end = _tag_end(data, offset)
        node = _Element(name, attributes, offset, end, data[end - 2:end] == b'/>')
        if stack:
            stack[-1].children.append(node)
        else:
            roots.append(node)
        stack.append(node)

    def end(name):
        node = stack.pop()
        if node.name != name:
            raise ValueError('A source XML element is ambiguous')
        if node.empty:
            node.end = node.tag_end
        else:
            offset = parser.CurrentByteIndex
            if data[offset:offset + 2] != b'</':
                raise ValueError('A source XML end tag has no exact byte location')
            node.end = _tag_end(data, offset)

    parser.XmlDeclHandler = declaration
    parser.StartDoctypeDeclHandler = forbidden
    parser.EntityDeclHandler = forbidden
    parser.ExternalEntityRefHandler = forbidden
    parser.StartElementHandler, parser.EndElementHandler = start, end
    parser.CharacterDataHandler = charge
    parser.CommentHandler, parser.ProcessingInstructionHandler = charge, charge
    parser.SetParamEntityParsing(expat.XML_PARAM_ENTITY_PARSING_NEVER)
    parser.Parse(data, True)
    if stack or len(roots) != 1:
        raise ValueError('A source XML part has no unique root')
    return roots[0]


def _children(node, name):
    return [child for child in node.children if child.name == name]


def _one(node, name):
    values = _children(node, name)
    if len(values) != 1:
        raise ValueError('A required PPTX source element is missing or duplicated')
    return values[0]


def _walk(node):
    remaining = [node]
    while remaining:
        current = remaining.pop()
        yield current
        remaining.extend(reversed(current.children))


def _number(value, minimum=None):
    if not isinstance(value, str) or re.fullmatch(r'[+-]?[0-9]+', value) is None:
        raise ValueError('A PPTX source dimension is not an exact integer')
    result = int(value)
    if minimum is not None and result < minimum:
        raise ValueError('A PPTX source dimension is outside the supported range')
    return result


def _identity(value):
    if not isinstance(value, str) or re.fullmatch(r'[0-9]+', value) is None:
        raise ValueError('A PPTX source identity is not an unsigned decimal')
    result = int(value)
    if result > 0xFFFFFFFF:
        raise ValueError('A PPTX source identity is outside the supported range')
    return result


def _member_name(name):
    if not isinstance(name, str) or not name or any(ord(character) < 32 for character in name):
        raise ValueError('A PPTX ZIP member name is invalid')
    directory = name.endswith('/')
    value = name[:-1] if directory else name
    if (not value or value.startswith('/') or any(character in value for character in '\\:%?#') or
            any(component in ('', '.', '..') for component in value.split('/'))):
        raise ValueError('A PPTX ZIP member name is not canonical')
    return value + '/' if directory else value


def _zip_envelope(stream):
    stream.seek(0, os.SEEK_END)
    size = stream.tell()
    stream.seek(max(0, size - 65557))
    tail = stream.read(65557)
    position = len(tail)
    record = None
    while True:
        position = tail.rfind(b'PK\x05\x06', 0, position)
        if position < 0:
            break
        if position + 22 <= len(tail):
            candidate = struct.unpack_from('<4s4H2IH', tail, position)
            if position + 22 + candidate[-1] == len(tail):
                record = candidate
                break
    if record is None:
        raise ValueError('A PPTX ZIP end record is missing or truncated')
    _, disk, directory_disk, local_count, count, directory_size, offset, _ = record
    if disk != 0 or directory_disk != 0 or local_count != count:
        raise ValueError('Multi-disk PPTX ZIP packages are unsupported')
    if count == 0xFFFF or directory_size == 0xFFFFFFFF or offset == 0xFFFFFFFF:
        raise ValueError('ZIP64 PPTX source packages are unsupported')
    if count > MEMBER_LIMIT:
        raise ValueError('PPTX source ZIP member limit exceeded')
    if directory_size > TOTAL_XML_BYTES:
        raise ValueError('PPTX source ZIP directory exceeds the bounded metadata limit')
    absolute_end = max(0, size - 65557) + position
    if offset + directory_size != absolute_end:
        raise ValueError('The PPTX ZIP directory location is inconsistent')
    stream.seek(0)
    return count


def _relationships(root, part, members):
    if root.name != PKG + 'Relationships' or root.attributes:
        raise ValueError('Unsupported PPTX relationship root')
    result = {}
    for item in root.children:
        if item.name != PKG + 'Relationship' or item.children:
            raise ValueError('Unsupported PPTX relationship XML')
        attributes = item.attributes
        if set(attributes) - {'Id', 'Type', 'Target', 'TargetMode'}:
            raise ValueError('Unsupported PPTX relationship attributes')
        identifier, kind, target = (attributes.get(name) for name in ('Id', 'Type', 'Target'))
        if (not identifier or identifier.strip() != identifier or identifier in result or
                not kind or not target or attributes.get('TargetMode') not in (None, 'Internal')):
            raise ValueError('A PPTX relationship identity or mode is ambiguous')
        parsed = urlsplit(target)
        if (parsed.scheme or parsed.netloc or parsed.query or parsed.fragment or target.startswith('/') or
                any(character in target for character in '\\:%') or
                any(ord(character) < 32 for character in target)):
            raise ValueError('External or noncanonical PPTX relationship targets are unsupported')
        resolved = posixpath.normpath(posixpath.join(posixpath.dirname(part), target))
        _member_name(resolved)
        if resolved not in members or members[resolved].is_dir():
            raise ValueError('A PPTX relationship target is absent')
        result[identifier] = (kind, resolved)
    return result


def _content_types(root, members):
    if root.name != CT + 'Types':
        raise ValueError('Unsupported PPTX content-type root')
    defaults, overrides = {}, {}
    for item in root.children:
        if item.children:
            raise ValueError('Unsupported PPTX content-type XML')
        if item.name == CT + 'Default':
            extension, content_type = item.attributes.get('Extension'), item.attributes.get('ContentType')
            if not extension or not content_type or extension.lower() in defaults:
                raise ValueError('A PPTX default content type is ambiguous')
            defaults[extension.lower()] = content_type
        elif item.name == CT + 'Override':
            part, content_type = item.attributes.get('PartName'), item.attributes.get('ContentType')
            if not part or not part.startswith('/') or not content_type:
                raise ValueError('A PPTX override content type is invalid')
            part = _member_name(part[1:])
            if part in overrides or part not in members:
                raise ValueError('A PPTX override content type is ambiguous')
            overrides[part] = content_type
        else:
            raise ValueError('Unsupported PPTX content-type entry')
    return defaults, overrides


def _merged(value):
    if value is None or value in ('0', 'false'):
        return False
    if value in ('1', 'true'):
        return True
    raise ValueError('A PPTX cell merge flag is unknown')


def _partition(cells, rows, columns):
    assignments, anchors = {}, {}
    for cell in cells:
        row, column = cell['row'], cell['column']
        if row + cell['rowSpan'] > rows or column + cell['columnSpan'] > columns:
            raise ValueError('A PPTX cell span is outside its actual source grid')
        if cell['covered']:
            continue
        coordinate = (row, column)
        anchors[coordinate] = cell
        for y in range(row, row + cell['rowSpan']):
            for x in range(column, column + cell['columnSpan']):
                if (y, x) in assignments:
                    raise ValueError('PPTX source cell anchors overlap')
                assignments[(y, x)] = coordinate
    for cell in cells:
        coordinate = (cell['row'], cell['column'])
        anchor = assignments.get(coordinate)
        if anchor is None:
            raise ValueError('A PPTX source covered cell has no explicit anchor')
        if cell['covered']:
            source = anchors[anchor]
            if (anchor == coordinate or cell['_horizontal'] != (cell['column'] > anchor[1]) or
                    cell['_vertical'] != (cell['row'] > anchor[0]) or
                    cell['row'] + cell['rowSpan'] > anchor[0] + source['rowSpan'] or
                    cell['column'] + cell['columnSpan'] > anchor[1] + source['columnSpan']):
                raise ValueError('A PPTX source covered cell contradicts its anchor')
            cell['anchor'] = {'row': anchor[0], 'column': anchor[1]}
        elif anchor != coordinate:
            raise ValueError('A PPTX source cell is missing its covered state')
        del cell['_horizontal'], cell['_vertical']
    if len(assignments) != rows * columns:
        raise ValueError('The PPTX source cell partition is incomplete')


def _table(frame, table, part):
    identity = _one(_one(frame, P + 'nvGraphicFramePr'), P + 'cNvPr').attributes.get('id')
    _identity(identity)
    transform = _one(frame, P + 'xfrm')
    offset, extent = _one(transform, A + 'off'), _one(transform, A + 'ext')
    if any(child.name not in (A + 'off', A + 'ext') for child in transform.children):
        raise ValueError('Unsupported PPTX table transform')
    grid = _one(table, A + 'tblGrid')
    if any(child.name != A + 'gridCol' for child in grid.children):
        raise ValueError('Unsupported PPTX table grid')
    widths = [_number(item.attributes.get('w'), 0) for item in grid.children]
    source_rows = _children(table, A + 'tr')
    if not widths or not source_rows or any(child.name not in (A + 'tblPr', A + 'tblGrid', A + 'tr') for child in table.children):
        raise ValueError('Unsupported or empty PPTX source table')
    if len(_children(table, A + 'tblPr')) > 1:
        raise ValueError('A PPTX table property root is duplicated')
    heights, cells = [], []
    for row, source_row in enumerate(source_rows):
        heights.append(_number(source_row.attributes.get('h'), 0))
        source_cells = source_row.children
        if len(source_cells) != len(widths) or any(item.name != A + 'tc' for item in source_cells):
            raise ValueError('A PPTX source row does not contain the complete logical cell grid')
        for column, source_cell in enumerate(source_cells):
            body = _one(source_cell, A + 'txBody')
            texts = [item for item in _walk(body) if item.name == A + 't']
            if any(item.children for item in texts):
                raise ValueError('A PPTX text element has unsupported nested markup')
            horizontal = _merged(source_cell.attributes.get('hMerge'))
            vertical = _merged(source_cell.attributes.get('vMerge'))
            cells.append({'row': row, 'column': column,
                'rowSpan': _number(source_cell.attributes.get('rowSpan', '1'), 1),
                'columnSpan': _number(source_cell.attributes.get('gridSpan', '1'), 1),
                'covered': horizontal or vertical, 'anchor': None,
                'cellSpan': (source_cell.start, source_cell.end),
                'textSpans': [(text.start, text.end) for text in texts],
                '_horizontal': horizontal, '_vertical': vertical})
    _partition(cells, len(heights), len(widths))
    return {'sourcePart': part, 'shapeId': identity,
        'positionEmu': {'x': _number(offset.attributes.get('x')), 'y': _number(offset.attributes.get('y'))},
        'extentEmu': {'width': _number(extent.attributes.get('cx'), 0), 'height': _number(extent.attributes.get('cy'), 0)},
        'columnWidthsEmu': widths, 'rowHeightsEmu': heights,
        'frameSpan': (frame.start, frame.end), 'tableSpan': (table.start, table.end), 'cells': cells}


def _slide(root, part):
    if root.name != P + 'sld':
        raise ValueError('Unsupported PPTX source slide namespace or root')
    identities = set()
    for item in _walk(root):
        if item.name == P + 'cNvPr':
            identity = _identity(item.attributes.get('id'))
            if identity in identities:
                raise ValueError('A PPTX source nonvisual identity is duplicated numerically')
            identities.add(identity)
    tree = _one(_one(root, P + 'cSld'), P + 'spTree')
    tables = []
    for frame in _walk(tree):
        if frame.name != P + 'graphicFrame':
            continue
        data = _one(_one(frame, A + 'graphic'), A + 'graphicData')
        candidates = [item for item in _walk(data) if item.name == A + 'tbl']
        if data.attributes.get('uri') != TABLE and not candidates:
            continue
        if frame not in tree.children:
            raise ValueError('Grouped or conditional PPTX source tables are unsupported')
        if data.attributes.get('uri') != TABLE or len(candidates) != 1 or candidates[0] not in data.children:
            raise ValueError('A PPTX source table container is ambiguous')
        tables.append(_table(frame, candidates[0], part))
    return tables


def _catalog(archive, expected_count):
    information = archive.infolist()
    if len(information) != expected_count or len(information) > MEMBER_LIMIT:
        raise ValueError('PPTX source ZIP declared and actual member counts differ')
    members, normalized = {}, set()
    for item in information:
        name = _member_name(item.orig_filename)
        if name != item.filename or name.casefold() in normalized:
            raise ValueError('PPTX source ZIP member identities are duplicated or aliased')
        if item.flag_bits & 1 or item.compress_type not in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED):
            raise ValueError('Encrypted or unsupported PPTX ZIP compression is unsupported')
        members[name] = item
        normalized.add(name.casefold())
    budget = {'declared': 0, 'actual': 0, 'nodes': 0}
    reserved, cache = set(), {}

    def reserve(parts):
        for part in parts:
            if part in reserved:
                continue
            item = members.get(part)
            if item is None or item.is_dir():
                raise ValueError('A required PPTX source XML part is absent')
            if item.file_size > PART_BYTES:
                raise ValueError('PPTX source XML part limit exceeded')
            budget['declared'] += item.file_size
            if budget['declared'] > TOTAL_XML_BYTES:
                raise ValueError('PPTX source referenced XML total limit exceeded')
            reserved.add(part)

    def load(part):
        if part not in cache:
            reserve([part])
            with archive.open(members[part], 'r') as stream:
                data = stream.read(PART_BYTES + 1)
            if len(data) > PART_BYTES or len(data) != members[part].file_size:
                raise ValueError('PPTX source XML size differs from its bounded declaration')
            budget['actual'] += len(data)
            if budget['actual'] > TOTAL_XML_BYTES:
                raise ValueError('PPTX source actual XML total limit exceeded')
            cache[part] = (data, _xml(data, budget))
        return cache[part]

    reserve(['[Content_Types].xml', '_rels/.rels'])
    defaults, overrides = _content_types(load('[Content_Types].xml')[1], members)
    roots = _relationships(load('_rels/.rels')[1], '', members)
    presentations = [target for kind, target in roots.values() if kind == R + '/officeDocument']
    if len(presentations) != 1 or presentations[0] != 'ppt/presentation.xml':
        raise ValueError('A unique supported PPTX officeDocument root is required')
    presentation_part = presentations[0]

    def content_type(part):
        return overrides.get(part, defaults.get(part.rsplit('.', 1)[-1].lower()))

    if content_type(presentation_part) != MAIN_CONTENT_TYPE:
        raise ValueError('Unsupported PPTX presentation content type')
    reserve([presentation_part, 'ppt/_rels/presentation.xml.rels'])
    presentation = load(presentation_part)[1]
    if presentation.name != P + 'presentation':
        raise ValueError('Unsupported PPTX presentation namespace or root')
    relationships = _relationships(load('ppt/_rels/presentation.xml.rels')[1], presentation_part, members)
    listing = _one(presentation, P + 'sldIdLst')
    slide_parts, slide_ids, relation_ids = [], set(), set()
    for item in listing.children:
        if item.name != P + 'sldId':
            raise ValueError('Unsupported PPTX slide owner list')
        identity = _identity(item.attributes.get('id'))
        relation = item.attributes.get(R + '|id')
        if identity in slide_ids or relation in relation_ids or relation not in relationships:
            raise ValueError('A PPTX source slide identity is ambiguous')
        kind, target = relationships[relation]
        if kind != R + '/slide' or target in slide_parts or content_type(target) != SLIDE_CONTENT_TYPE:
            raise ValueError('A PPTX source slide relationship is ambiguous')
        slide_ids.add(identity)
        relation_ids.add(relation)
        slide_parts.append(target)
    reserve(slide_parts)
    parts, tables = {}, []
    for part in slide_parts:
        data, root = load(part)
        parts[part] = data
        tables.extend(_slide(root, part))
    return {'parts': parts, 'tables': tables}


def _stamp(value):
    return value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns


class _ReadOnlyImage:
    def __init__(self, stream):
        self._stream = stream

    def read(self, size=-1):
        return self._stream.read(size)

    def seek(self, offset, whence=0):
        return self._stream.seek(offset, whence)

    def tell(self):
        return self._stream.tell()

    def readable(self):
        return True

    def writable(self):
        return False

    def seekable(self):
        return True


def _digest(stream, byte_length, destination=None):
    stream.seek(0)
    digest, remaining = hashlib.sha256(), byte_length
    while remaining:
        data = stream.read(min(remaining, 1024 * 1024))
        if not data:
            raise ValueError('The PPTX source length changed during reading')
        digest.update(data)
        if destination is not None and destination.write(data) != len(data):
            raise ValueError('The private PPTX source image is incomplete')
        remaining -= len(data)
    if stream.read(1):
        raise ValueError('The PPTX source length changed during reading')
    return digest.hexdigest()


@contextmanager
def open_pptx_tables(path, *, max_package_bytes=None):
    """Keep the verified source catalog and its same read-only archive image open."""
    source = Path(path)
    if max_package_bytes is not None and (type(max_package_bytes) is not int or max_package_bytes < 1):
        raise ValueError('A positive source package byte limit is required')
    if source.suffix.lower() != '.pptx':
        raise ValueError('Only the supported transitional PPTX source subset can be read')
    cleanup, processing_error = ExitStack(), None
    try:
        try:
            stream = cleanup.enter_context(source.open('rb', buffering=0))
            before = _stamp(os.fstat(stream.fileno()))
            if max_package_bytes is not None and before[2] > max_package_bytes:
                raise ValueError('PPTX source package byte limit exceeded before capture')
            if _stamp(source.stat()) != before:
                raise ValueError('The PPTX source identity changed before reading')
            source_hash = _digest(stream, before[2])
            view = cleanup.enter_context(tempfile.TemporaryFile(mode='w+b'))
            if _digest(stream, before[2], view) != source_hash:
                raise ValueError('The PPTX source changed while capturing its private image')
            view.flush()
            expected_count = _zip_envelope(view)
            archive = cleanup.enter_context(zipfile.ZipFile(_ReadOnlyImage(view), 'r'))
            catalog = {'sourceSha256': source_hash, **_catalog(archive, expected_count)}

            def verify_original():
                if (_stamp(os.fstat(stream.fileno())) != before or _stamp(source.stat()) != before or
                        _digest(stream, before[2]) != source_hash):
                    raise ValueError('The immutable PPTX source changed during reading')

            verify_original()
        except (OSError, zipfile.BadZipFile, zipfile.LargeZipFile, expat.ExpatError,
                UnicodeError, NotImplementedError, RuntimeError, OverflowError) as error:
            raise ValueError('Unsupported or invalid PPTX source package') from error
        body_error = None
        try:
            yield SimpleNamespace(catalog=catalog, archive=archive)
        except BaseException as error:
            body_error = error
            raise
        finally:
            try:
                verify_original()
            except Exception as error:
                if body_error is None:
                    if isinstance(error, ValueError):
                        raise
                    raise ValueError('The PPTX source could not be verified after reading') from error
                body_error.add_note('PPTX source verification failed after consumer error: ' + str(error))
    except BaseException as error:
        processing_error = error
        raise
    finally:
        try:
            cleanup.close()
        except Exception as error:
            if processing_error is None:
                raise
            processing_error.add_note('Closing the owned PPTX source image failed: ' + str(error))


def read_pptx_tables(path):
    """Return exact source slide table spans or raise ValueError for unknown input."""
    with open_pptx_tables(path) as image:
        return image.catalog
