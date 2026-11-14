"""Restore observed inline spacing in an owned Writer DOCX export.

Native LR319 is represented by absent inline distance attributes, while native
LR0 and TB0 require explicit zero. Only exact private marker spans authorize
these byte edits; arbitrary margin conversion remains unverified.
"""
import copy
import os
from pathlib import Path
import re
import tempfile
from xml.parsers import expat
import zipfile


WORD = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main|'
DRAWING = 'http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing|'
SPACING = {'distL': 'LeftMargin', 'distR': 'RightMargin',
    'distT': 'TopMargin', 'distB': 'BottomMargin'}
WHITESPACE = b' \t\r\n'


def spacing_mapping(mapping):
    if not isinstance(mapping, dict):
        raise ValueError('Inline spacing requires an exact marker mapping')
    result = {}
    for name, margins in mapping.items():
        if not isinstance(name, str) or re.fullmatch(r'PIV_[0-9a-fA-F]{32}', name) is None:
            raise ValueError('Inline spacing requires a controlled private marker name')
        if not isinstance(margins, dict) or set(margins) != set(SPACING.values()):
            raise ValueError('Inline spacing requires all four native margins')
        for side, value in margins.items():
            allowed = (0, 319) if side in ('LeftMargin', 'RightMargin') else (0,)
            if type(value) is not int or value not in allowed:
                raise ValueError('This native inline spacing has no verified export mapping')
        result[name] = dict(margins)
    return result


def start_tag(data, offset):
    """Locate raw attribute/value spans without serializing XML or splitting > in quotes."""
    if data[offset:offset + 1] != b'<':
        raise ValueError('XML parser did not identify a native start tag')
    position = offset + 1
    while position < len(data) and data[position] not in WHITESPACE + b'/>':
        position += 1
    attributes = []
    while position < len(data):
        whitespace_start = position
        while position < len(data) and data[position] in WHITESPACE:
            position += 1
        if data[position:position + 2] == b'/>':
            return position + 2, position, True, attributes
        if data[position:position + 1] == b'>':
            return position + 1, position, False, attributes
        name_start = position
        while position < len(data) and data[position] not in WHITESPACE + b'=/>':
            position += 1
        name = data[name_start:position]
        while position < len(data) and data[position] in WHITESPACE:
            position += 1
        if not name or data[position:position + 1] != b'=':
            raise ValueError('An XML attribute cannot be located unambiguously')
        position += 1
        while position < len(data) and data[position] in WHITESPACE:
            position += 1
        quote = data[position:position + 1]
        if quote not in (b'"', b"'"):
            raise ValueError('An XML attribute is not quoted')
        value_start = position + 1
        value_end = data.find(quote, value_start)
        if value_end < 0:
            raise ValueError('An XML attribute is not complete')
        position = value_end + 1
        attributes.append((name, whitespace_start, position, value_start, value_end))
    raise ValueError('An XML start tag is not complete')


def inline_edits(data, offset, margins):
    _, insertion, _, attributes = start_tag(data, offset)
    remaining = dict(SPACING)
    edits = []
    for raw_name, start, end, value_start, value_end in attributes:
        name = raw_name.decode('utf-8')
        if name not in SPACING:
            continue
        if name not in remaining:
            raise ValueError('An inline distance attribute is ambiguous')
        side = remaining.pop(name)
        if margins[side] == 319:
            edits.append((start, end, b''))
        elif data[value_start:value_end] != b'0':
            edits.append((value_start, value_end, b'0'))
    added = b''.join((' ' + name + '="0"').encode('ascii')
        for name, side in remaining.items() if margins[side] == 0)
    if added:
        edits.append((insertion, insertion, added))
    return edits


def xml_edits(data, mapping, found):
    data.decode('utf-8')
    parser = expat.ParserCreate(namespace_separator='|')
    starts, ends, records, edits = {}, {}, [], []
    active, depth = None, 0

    def declaration(version, encoding, standalone):
        if encoding is not None and encoding.upper().replace('-', '') != 'UTF8':
            raise ValueError('Inline spacing restoration requires UTF-8 XML')

    def forbidden(*arguments):
        raise ValueError('DTD and entity declarations are not allowed in a Writer export')

    def element(name, attributes):
        nonlocal active, depth
        depth += 1
        if name == WORD + 'bookmarkStart':
            identifier = attributes.get(WORD + 'id')
            starts[identifier] = starts.get(identifier, 0) + 1
            marker = attributes.get(WORD + 'name')
            if marker not in mapping:
                return
            if marker in found or active is not None or not identifier:
                raise ValueError('A controlled inline marker is duplicated or overlaps another marker')
            offset = parser.CurrentByteIndex
            end, _, closed, _ = start_tag(data, offset)
            if not closed:
                raise ValueError('A controlled bookmark tag contains unverified content')
            active = {'name': marker, 'id': identifier, 'inline': False, 'inlineClosed': False}
            found.add(marker)
            edits.append((offset, end, b''))
        elif name == DRAWING + 'inline' and active is not None:
            if active['inline']:
                raise ValueError('A controlled inline marker encloses more than one image')
            active['inline'] = True
            active['inlineDepth'] = depth
            edits.extend(inline_edits(data, parser.CurrentByteIndex, mapping[active['name']]))
        elif name == WORD + 'bookmarkEnd':
            identifier = attributes.get(WORD + 'id')
            ends[identifier] = ends.get(identifier, 0) + 1
            if active is None or identifier != active['id']:
                return
            if not active['inline'] or not active['inlineClosed']:
                raise ValueError('A controlled inline marker does not enclose a complete image')
            offset = parser.CurrentByteIndex
            end, _, closed, _ = start_tag(data, offset)
            if not closed:
                raise ValueError('A controlled bookmark tag contains unverified content')
            edits.append((offset, end, b''))
            records.append(active)
            active = None

    def element_end(name):
        nonlocal depth
        if active is not None and name == DRAWING + 'inline' and depth == active.get('inlineDepth'):
            active['inlineClosed'] = True
        depth -= 1

    parser.XmlDeclHandler = declaration
    parser.StartDoctypeDeclHandler = forbidden
    parser.EntityDeclHandler = forbidden
    parser.ExternalEntityRefHandler = forbidden
    parser.StartElementHandler = element
    parser.EndElementHandler = element_end
    parser.SetParamEntityParsing(expat.XML_PARAM_ENTITY_PARSING_NEVER)
    parser.Parse(data, True)
    if active is not None:
        raise ValueError('A controlled inline marker has no matching end')
    for record in records:
        identifier = record['id']
        if starts.get(identifier) != 1 or ends.get(identifier) != 1:
            raise ValueError('A controlled inline bookmark identity is ambiguous')
    return edits


def apply_edits(data, edits):
    previous_end = -1
    for start, end, replacement in sorted(edits):
        if not 0 <= start <= end <= len(data) or start < previous_end:
            raise ValueError('Inline spacing XML edits overlap or have invalid bounds')
        previous_end = end
    for start, end, replacement in sorted(edits, reverse=True):
        data = data[:start] + replacement + data[end:]
    return data


def restore_inline_spacing(export_path, mapping):
    """Atomically restore only the observed spacing of exactly marked inline images."""
    mapping = spacing_mapping(mapping)
    if not mapping:
        return {'markersRestored': 0, 'partsModified': 0}
    path = Path(export_path)
    temporary = None
    try:
        with zipfile.ZipFile(path) as source:
            information = source.infolist()
            names = [item.filename for item in information]
            if len(names) != len(set(names)):
                raise ValueError('A Writer export contains duplicate ZIP members')
            # A writer mutates ZipInfo header offsets. Own copies and finish all
            # source reads before writing so reader metadata cannot be corrupted.
            members = [(copy.copy(item), source.read(item)) for item in information]
            comment = source.comment
        found, output, modified = set(), [], 0
        for information, payload in members:
            if information.filename.lower().endswith('.xml'):
                edits = xml_edits(payload, mapping, found)
                if edits:
                    payload = apply_edits(payload, edits)
                    modified += 1
            output.append((information, payload))
        if found != set(mapping):
            raise ValueError('A controlled inline marker is absent from the Writer export')
        descriptor, name = tempfile.mkstemp(prefix=path.name + '.', suffix='.tmp', dir=path.parent)
        os.close(descriptor)
        temporary = Path(name)
        with zipfile.ZipFile(temporary, 'w') as destination:
            destination.comment = comment
            for information, payload in output:
                destination.writestr(information, payload)
        with zipfile.ZipFile(temporary) as verified:
            if verified.testzip() is not None or verified.namelist() != names:
                raise ValueError('Restored Writer export failed its ZIP integrity check')
        os.replace(temporary, path)
        return {'markersRestored': len(mapping), 'partsModified': modified}
    except Exception as error:
        raise ValueError('Writer inline spacing restoration failed: ' + str(error)) from error
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
