"""Build private PPTX candidates while raw-copying untouched ZIP records.

This source transformation grants no native identity, publication, or edit rights.
ZIP layouts follow PKWARE APPNOTE 6.3.10 sections 4.3.7/9/12/16.
"""
import hashlib
import os
from pathlib import Path
import re
import struct
from xml.sax.saxutils import quoteattr
import zipfile
import zlib

import office_presentation_source as source_reader
from office_presentation_text_patch import patch_cell_text


MAX_PACKAGE_BYTES = 128 * 1024 * 1024
CHUNK_BYTES = 1024 * 1024
OPERATION_FIELDS = frozenset(('sourcePart', 'shapeId', 'row', 'column',
    'expectedSourceFrameSha256', 'expectedTextSha256', 'startUtf16', 'endUtf16', 'text'))
PRESENTATION = 'ppt/presentation.xml'
P14 = 'http://schemas.microsoft.com/office/powerpoint/2010/main|'
SECTION_URI = '{521415D9-36F7-43E2-AB2F-B90AF26B5E84}'
SECTION_GUID = re.compile(r'\{[\da-f]{8}-[\da-f]{4}-[\da-f]{4}-[\da-f]{4}-[\da-f]{12}\}', re.I | re.ASCII)


def _require(condition, message):
    if not condition:
        raise ValueError(message)


def _sha(data):
    return hashlib.sha256(data).hexdigest()


def _hash_value(value):
    return type(value) is str and re.fullmatch(r'[0-9a-f]{64}', value) is not None


def _read_at(stream, start, size):
    _require(type(start) is int and start >= 0 and 0 <= size <= source_reader.TOTAL_XML_BYTES,
        'A bounded exact ZIP record interval is required')
    stream.seek(start)
    data = stream.read(size)
    _require(len(data) == size, 'A ZIP record interval is incomplete')
    return data


def _write(stream, data):
    _require(stream.tell() + len(data) <= MAX_PACKAGE_BYTES, 'PPTX candidate byte limit exceeded')
    _require(stream.write(data) == len(data), 'The private PPTX candidate write is incomplete')


def _copy_interval(original, output, start, stop):
    _require(0 <= start <= stop, 'The raw ZIP copy interval is invalid')
    position = start
    while position < stop:
        data = _read_at(original, position, min(stop - position, CHUNK_BYTES))
        _write(output, data)
        position += len(data)


def _reject_zip64_extra(data):
    position = 0
    while position < len(data):
        _require(position + 4 <= len(data), 'A ZIP extra record is truncated')
        kind, length = struct.unpack_from('<2H', data, position)
        _require(kind != 1, 'ZIP64 source record edits are unsupported')
        position += 4 + length
        _require(position <= len(data), 'A ZIP extra record length is invalid')


def _layout(archive):
    original = archive.fp
    original.seek(0, os.SEEK_END)
    length = original.tell()
    end_offset = length - 22 - len(archive.comment)
    end = _read_at(original, end_offset, 22 + len(archive.comment))
    signature, disk, central_disk, local_count, count, central_size, central_start, comment = struct.unpack_from('<4s4H2IH', end)
    information = archive.infolist()
    _require(signature == b'PK\x05\x06' and disk == central_disk == 0 and
        local_count == count == len(information) and comment == len(archive.comment) and
        central_start + central_size == end_offset, 'Unsupported PPTX ZIP directory envelope')
    central = _read_at(original, central_start, central_size)
    entries, position, offsets = [], 0, set()
    for item in information:
        _require(position + 46 <= len(central) and central[position:position + 4] == b'PK\x01\x02',
            'Unsupported PPTX ZIP central record')
        name_length, extra_length, comment_length, member_disk = struct.unpack_from('<4H', central, position + 28)
        stop = position + 46 + name_length + extra_length + comment_length
        _require(stop <= len(central) and member_disk == 0, 'The ZIP central member length or disk is invalid')
        record = central[position:stop]
        crc, compressed, expanded = struct.unpack_from('<3I', record, 16)
        offset = struct.unpack_from('<I', record, 42)[0]
        flags, method = struct.unpack_from('<2H', record, 8)
        name = record[46:46 + name_length]
        decoded = name.decode('utf-8' if flags & 0x800 else 'cp437')
        _require(decoded == item.orig_filename and offset == item.header_offset and offset not in offsets and
            (crc, compressed, expanded, flags, method) ==
            (item.CRC, item.compress_size, item.file_size, item.flag_bits, item.compress_type) and
            offset < central_start and compressed != 0xFFFFFFFF and expanded != 0xFFFFFFFF,
            'The ZIP central identity or sizes are ambiguous')
        _reject_zip64_extra(record[46 + name_length:46 + name_length + extra_length])
        entries.append({'info': item, 'central': record, 'name': name, 'offset': offset})
        offsets.add(offset)
        position = stop
    _require(position == len(central) and entries, 'Unsupported trailing or empty ZIP directory')
    ordered = sorted(entries, key=lambda entry: entry['offset'])
    for index, entry in enumerate(ordered):
        item, start = entry['info'], entry['offset']
        stop = ordered[index + 1]['offset'] if index + 1 < len(ordered) else central_start
        header = _read_at(original, start, 30)
        fields = struct.unpack('<4s5H3I2H', header)
        _, _, flags, method, _, _, crc, compressed, expanded, names, extras = fields
        data_start = start + 30 + names + extras
        _require(fields[0] == b'PK\x03\x04' and (flags, method) == (item.flag_bits, item.compress_type) and
            method in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED) and not flags & 1 and
            data_start + item.compress_size <= stop, 'The ZIP local header or payload interval is invalid')
        suffix = _read_at(original, start + 30, names + extras)
        _require(suffix[:names] == entry['name'], 'The ZIP local name differs from its central identity')
        _reject_zip64_extra(suffix[names:])
        payload_end = data_start + item.compress_size
        descriptor = b''
        if flags & 8:
            first = _read_at(original, payload_end, 4)
            descriptor_length = 16 if first == b'PK\x07\x08' else 12
            _require(payload_end + descriptor_length <= stop, 'The ZIP data descriptor overlaps another record')
            descriptor = _read_at(original, payload_end, descriptor_length)
            values = struct.unpack_from('<3I', descriptor, 4 if descriptor_length == 16 else 0)
            _require(values == (item.CRC, item.compress_size, item.file_size) and
                crc in (0, item.CRC) and compressed in (0, item.compress_size) and expanded in (0, item.file_size),
                'The ZIP data descriptor or deferred local sizes differ')
        else:
            _require((crc, compressed, expanded) == (item.CRC, item.compress_size, item.file_size),
                'The ZIP local checksum or sizes differ from the directory')
        entry.update(header=header + suffix, descriptor=descriptor,
            payloadEnd=payload_end, stop=stop, flags=flags)
    return entries, ordered, end


def _signed_package(archive):
    if any(name.casefold().startswith('_xmlsignatures/') for name in archive.namelist()):
        return True
    for part in ('[Content_Types].xml', '_rels/.rels'):
        root = source_reader._xml(archive.read(part), {'nodes': 0})
        for node in source_reader._walk(root):
            value = node.attributes.get('ContentType', node.attributes.get('Type', '')).casefold()
            if '/digital-signature/' in value or '.digital-signature-' in value:
                return True
    return False


def _validate_payloads(archive, changed):
    total = 0
    for item in archive.infolist():
        size = len(changed[item.filename]) if item.filename in changed else item.file_size
        _require(0 <= size <= MAX_PACKAGE_BYTES, 'PPTX member expanded byte limit exceeded')
        total += size
        _require(total <= MAX_PACKAGE_BYTES, 'PPTX aggregate expanded byte limit exceeded')
    for item in archive.infolist():
        with archive.open(item, 'r') as stream:
            remaining = item.file_size
            while remaining:
                data = stream.read(min(remaining, CHUNK_BYTES))
                _require(data and len(data) <= remaining, 'The PPTX member length is incomplete')
                remaining -= len(data)
            _require(not stream.read(1), 'The PPTX member exceeds its declared length')


def _apply_operations(catalog, operations):
    origin = {(table['sourcePart'], table['shapeId']): table for table in catalog['tables']}
    parts, ledger = dict(catalog['parts']), []
    for operation in operations:
        _require(type(operation) is dict and set(operation) == OPERATION_FIELDS and
            type(operation['sourcePart']) is str and type(operation['shapeId']) is str and
            type(operation['row']) is int and type(operation['column']) is int and
            operation['row'] >= 0 and operation['column'] >= 0 and
            _hash_value(operation['expectedSourceFrameSha256']), 'Invalid PPTX source text patch operation')
        part, shape_id = operation['sourcePart'], operation['shapeId']
        key = part, shape_id
        _require(key in origin, 'The source text patch targets an unknown part or shape')
        original_table = origin[key]
        _require(_sha(catalog['parts'][part][slice(*original_table['frameSpan'])]) == operation['expectedSourceFrameSha256'],
            'The expected original source frame SHA-256 is stale')
        tables = source_reader._slide(source_reader._xml(parts[part], {'nodes': 0}), part)
        table = next(table for table in tables if table['shapeId'] == shape_id)
        matches = [cell for cell in table['cells'] if (cell['row'], cell['column']) ==
            (operation['row'], operation['column'])]
        _require(len(matches) == 1, 'The source text patch targets an unknown cell coordinate')
        patch = patch_cell_text(parts[part], matches[0], operation['startUtf16'], operation['endUtf16'],
            operation['text'], operation['expectedTextSha256'])
        parts[part] = patch['partBytes']
        ledger.append({'sourcePart': part, 'shapeId': shape_id, 'row': operation['row'], 'column': operation['column'],
            'sourcePartSha256': patch['sourcePartSha256'], 'resultPartSha256': patch['resultPartSha256'],
            'textSha256': patch['textSha256'], 'patches': [
                {'startByte': item['startByte'], 'endByte': item['endByte'],
                    'replacementSha256': _sha(item['replacementBytes']), 'replacementBytes': len(item['replacementBytes'])}
                for item in patch['patches']]})
    return {part: data for part, data in parts.items() if data != catalog['parts'][part]}, ledger


def _rewrite(archive, output, changed, added_archive=None):
    central_order, physical_order, end = _layout(archive)
    original, offsets, replacements = archive.fp, {}, {}
    _copy_interval(original, output, 0, physical_order[0]['offset'])
    for entry in physical_order:
        item = entry['info']
        offsets[entry['offset']] = output.tell()
        if item.filename not in changed:
            _copy_interval(original, output, entry['offset'], entry['stop'])
            continue
        payload = changed[item.filename]
        if item.compress_type == zipfile.ZIP_DEFLATED:
            level = {0: 6, 2: 9, 4: 3, 6: 1}[item.flag_bits & 6]
            compressor = zlib.compressobj(level, zlib.DEFLATED, -15)
            compressed = compressor.compress(payload) + compressor.flush()
        else:
            compressed = payload
        values = zlib.crc32(payload) & 0xFFFFFFFF, len(compressed), len(payload)
        replacements[item.filename] = values
        header = bytearray(entry['header'])
        for position, value in zip((14, 18, 22), values):
            if not entry['flags'] & 8 or struct.unpack_from('<I', header, position)[0] != 0:
                struct.pack_into('<I', header, position, value)
        _write(output, header)
        _write(output, compressed)
        if entry['descriptor']:
            _write(output, (b'PK\x07\x08' if len(entry['descriptor']) == 16 else b'') + struct.pack('<3I', *values))
        _copy_interval(original, output, entry['payloadEnd'] + len(entry['descriptor']), entry['stop'])
    added_central, added_offsets = [], {}
    if added_archive is not None:
        added_central, added_physical, _ = _layout(added_archive)
        _require(len(central_order) + len(added_central) <= source_reader.MEMBER_LIMIT,
            'PPTX candidate ZIP member limit exceeded')
        original_names = {entry['info'].filename.casefold() for entry in central_order}
        added_names = {entry['info'].filename.casefold() for entry in added_central}
        _require(len(added_names) == len(added_central) and not original_names.intersection(added_names),
            'PPTX candidate ZIP addition has an ambiguous member name')
        for entry in added_physical:
            added_offsets[entry['offset']] = output.tell()
            _copy_interval(added_archive.fp, output, entry['offset'], entry['stop'])
    central_start = output.tell()
    for entry in central_order:
        record = bytearray(entry['central'])
        struct.pack_into('<I', record, 42, offsets[entry['offset']])
        if entry['info'].filename in replacements:
            struct.pack_into('<3I', record, 16, *replacements[entry['info'].filename])
        _write(output, record)
    for entry in added_central:
        record = bytearray(entry['central'])
        struct.pack_into('<I', record, 42, added_offsets[entry['offset']])
        _write(output, record)
    end = bytearray(end)
    count = len(central_order) + len(added_central)
    struct.pack_into('<2H2I', end, 8, count, count, output.tell() - central_start, central_start)
    _write(output, end)


def _verify_catalog(original, current, changed):
    _require(set(original['parts']) == set(current['parts']), 'The candidate source owners changed')
    for part, data in original['parts'].items():
        _require(current['parts'][part] == changed.get(part, data), 'The candidate XML differs from its exact patch plan')
    fields = ('sourcePart', 'shapeId', 'positionEmu', 'extentEmu', 'columnWidthsEmu', 'rowHeightsEmu')
    topology = ('row', 'column', 'rowSpan', 'columnSpan', 'covered', 'anchor')
    expected = [{**{key: table[key] for key in fields}, 'cells': [
        {key: cell[key] for key in topology} for cell in table['cells']]} for table in original['tables']]
    observed = [{**{key: table[key] for key in fields}, 'cells': [
        {key: cell[key] for key in topology} for cell in table['cells']]} for table in current['tables']]
    _require(expected == observed, 'The candidate table source identity, geometry or topology changed')


def patch_pptx(source, destination, operations, expected_source_sha256):
    """Create an exclusive private candidate; the caller separately validates native save rights."""
    _require(type(operations) is list and len(operations) <= 100 and _hash_value(expected_source_sha256),
        'A bounded source text operation list and exact source SHA-256 are required')
    source, destination = Path(source), Path(destination)
    _require(source.stat().st_size <= MAX_PACKAGE_BYTES, 'PPTX package byte limit exceeded before capture')
    owned = None
    try:
        with source_reader.open_pptx_tables(source, max_package_bytes=MAX_PACKAGE_BYTES) as image:
            _require(image.catalog['sourceSha256'] == expected_source_sha256, 'The expected PPTX source SHA-256 is stale')
            image.archive.fp.seek(0, os.SEEK_END)
            size = image.archive.fp.tell()
            _require(size <= MAX_PACKAGE_BYTES, 'PPTX package byte limit exceeded')
            changed, ledger = _apply_operations(image.catalog, operations)
            _require(not changed or not _signed_package(image.archive), 'Signed PPTX package edits are unsupported')
            _validate_payloads(image.archive, changed)
            with destination.open('x+b', buffering=0) as output:
                owned = source_reader._stamp(os.fstat(output.fileno()))[:2]
                if changed:
                    _rewrite(image.archive, output, changed)
                else:
                    _copy_interval(image.archive.fp, output, 0, size)
                output.flush()
                os.fsync(output.fileno())
                output_size = output.tell()
                digest = source_reader._digest(output, output_size)
                _require(source_reader._stamp(destination.stat())[:2] == owned,
                    'The private PPTX candidate was replaced during verification')
                current = source_reader.read_pptx_tables(destination)
                _require(current['sourceSha256'] == digest, 'The candidate bytes differ from the exact constructed image')
                _verify_catalog(image.catalog, current, changed)
                _require(source_reader._digest(output, output_size) == digest,
                    'The candidate bytes changed after catalog verification')
                _require(source_reader._stamp(destination.stat())[:2] == owned,
                    'The private PPTX candidate identity changed')
            result = {'sourceSha256': expected_source_sha256, 'resultSha256': digest,
                'changedParts': sorted(changed), 'operationLedger': ledger}
        return result
    except BaseException as error:
        if owned is not None:
            try:
                if destination.exists():
                    _require(source_reader._stamp(destination.stat())[:2] == owned,
                        'Preserve the foreign replacement of the candidate path')
                    destination.unlink()
            except Exception as cleanup_error:
                error.add_note('Removing owned failed PPTX candidate: ' + str(cleanup_error))
        if isinstance(error, (zipfile.BadZipFile, zipfile.LargeZipFile, zlib.error,
                UnicodeError, struct.error, StopIteration)):
            raise ValueError('Unsupported or invalid PPTX text patch package') from error
        raise


class SlideSections:
    def __init__(self, groups, membership):
        self._groups = groups
        self._membership = membership

    def assign(self, slide_id, target_id):
        _require(target_id in self._membership, 'The destination slide has no verified section')
        self._membership[slide_id] = self._membership[target_id]

    def remove(self, slide_id):
        _require(slide_id in self._membership, 'The removed slide has no verified section')
        del self._membership[slide_id]

    def _ordered_groups(self, logical, numeric_ids):
        _require(self._membership.keys() == numeric_ids.keys(),
            'The PPTX section plan does not cover the saved slides')
        order = [self._membership[slide_id] for slide_id in logical]
        _require(order == sorted(order), 'The PPTX section plan is not contiguous in slide order')
        groups = [[] for _ in self._groups]
        for slide_id, section in zip(logical, order):
            groups[section].append(numeric_ids[slide_id])
        return tuple(tuple(group) for group in groups)


def _presentation(archive):
    data = archive.read(PRESENTATION)
    root = source_reader._xml(data, {'nodes': 0})
    _require(root.name == source_reader.P + 'presentation' and not
        source_reader._children(root, source_reader.P + 'modifyVerifier'),
        'Modify-protected PPTX order edits are unsupported')
    listing = source_reader._one(root, source_reader.P + 'sldIdLst')
    return data, root, listing.children


def _element_end(data, element):
    end = data.rfind(b'</', element.tag_end, element.end)
    _require(end >= element.tag_end and source_reader._tag_end(data, end) == element.end,
        'The PPTX element has no exact closing tag')
    return end


def _plain_children(data, element):
    if not element.empty:
        position = element.tag_end
        for child in element.children:
            _require(not data[position:child.start].strip(), 'Unknown PPTX section XML content')
            position = child.end
        _require(not data[position:_element_end(data, element)].strip(), 'Unknown PPTX section XML content')
    return element.children


def _sections(data, root):
    p = source_reader.P
    extensions = source_reader._children(root, p + 'extLst')
    _require(len(extensions) <= 1, 'The PPTX presentation has ambiguous extension lists')
    extension_list = extensions[0] if extensions else None
    section_extensions = [] if extension_list is None else [
        child for child in extension_list.children if child.name == p + 'ext' and
        child.attributes.get('uri', '').upper() == SECTION_URI]
    candidates = [node for node in source_reader._walk(root) if node.name == P14 + 'sectionLst']
    if not candidates and not section_extensions:
        return extension_list, None, (), ()
    _require(len(candidates) == len(section_extensions) == 1, 'Ambiguous PPTX section metadata')
    section_list, extension = candidates[0], section_extensions[0]
    _require(extension.attributes.keys() == {'uri'} and _plain_children(data, extension) == [section_list] and
        not section_list.attributes, 'Unsupported PPTX section extension metadata')
    groups, members, guids = [], [], set()
    for group in _plain_children(data, section_list):
        _require(group.name == P14 + 'section' and group.attributes.keys() <= {'name', 'id'} and
            len(_plain_children(data, group)) == 1, 'Unsupported PPTX section metadata')
        guid = group.attributes.get('id')
        if guid is not None:
            _require(SECTION_GUID.fullmatch(guid) is not None and guid.upper() not in guids,
                'Invalid or duplicated PPTX section ID')
            guids.add(guid.upper())
        group_list = source_reader._one(group, P14 + 'sldIdLst')
        _require(not group_list.attributes, 'Unsupported PPTX section member list')
        identities = []
        for item in _plain_children(data, group_list):
            _require(item.name == P14 + 'sldId' and item.attributes.keys() == {'id'} and
                not _plain_children(data, item), 'Unsupported PPTX section slide metadata')
            identities.append(source_reader._identity(item.attributes['id']))
        groups.append((group.attributes.get('name'), guid))
        members.append(tuple(identities))
    _require(groups, 'Empty PPTX section metadata is unsupported')
    return extension_list, section_list, tuple(groups), tuple(members)


def _verified_edit_image(image, expected_sha):
    _require(_hash_value(expected_sha) and image.catalog['sourceSha256'] == expected_sha,
        'The expected PPTX order source SHA-256 is stale')
    _require(not _signed_package(image.archive), 'Signed PPTX package edits are unsupported')
    return _presentation(image.archive)


def read_slide_sections(source, expected_sha):
    """Bind authored sections to the worker's stable, zero-based slide IDs."""
    with source_reader.open_pptx_tables(source, max_package_bytes=MAX_PACKAGE_BYTES) as image:
        data, root, listing = _verified_edit_image(image, expected_sha)
        _, _, groups, members = _sections(data, root)
        if not groups:
            return None
        expected = [source_reader._identity(node.attributes['id']) for node in listing]
        _require([value for group in members for value in group] == expected,
            'PPTX section members do not match the authored slide order')
        section_indexes = [index for index, group in enumerate(members) for _ in group]
        return SlideSections(groups, {f'slide-{index}': section for index, section in enumerate(section_indexes)})


def _section_xml(groups, members):
    result = [f'<p14:sectionLst xmlns:p14="{P14[:-1]}">']
    for (name, guid), identities in zip(groups, members):
        attributes = ''.join(' ' + key + '=' + quoteattr(value) for key, value in (
            ('name', name), ('id', guid)) if value is not None)
        result.append('<p14:section' + attributes + '><p14:sldIdLst>')
        result.extend(f'<p14:sldId id="{identity}"/>' for identity in identities)
        result.append('</p14:sldIdLst></p14:section>')
    result.append('</p14:sectionLst>')
    return ''.join(result).encode('utf-8')


def _restore_sections(data, root, extension_list, section_xml):
    namespace = source_reader.P[:-1]
    entry = f'<p:ext xmlns:p="{namespace}" uri="{SECTION_URI}">'.encode() + section_xml + b'</p:ext>'
    if extension_list is None:
        position = _element_end(data, root)
        return position, position, f'<p:extLst xmlns:p="{namespace}">'.encode() + entry + b'</p:extLst>'
    if extension_list.empty:
        opening = data[extension_list.start:extension_list.tag_end]
        name = re.match(rb'<([^\s/>]+)', opening)
        _require(name is not None and opening.endswith(b'/>'), 'Invalid empty PPTX extension list')
        return extension_list.start, extension_list.end, opening[:-2] + b'>' + entry + b'</' + name[1] + b'>'
    position = _element_end(data, extension_list)
    return position, position, entry


def _apply_slide_order(data, root, listing, physical, logical, sections):
    _require(len(physical) == len(logical) == len(listing) > 0 and
        len(set(physical)) == len(physical) and set(physical) == set(logical),
        'The PPTX slide permutation is incomplete or ambiguous')
    by_id = dict(zip(physical, listing))
    edits = [(slot.start, slot.end, data[by_id[slide].start:by_id[slide].end])
        for slot, before, slide in zip(listing, physical, logical) if before != slide]
    extension_list, current, groups, members = _sections(data, root)
    if sections is None:
        _require(current is None, 'The PPTX serializer introduced unbound section metadata')
        expected = (), ()
    else:
        # Some native save passes omit empty groups or the complete extension.
        remaining = iter(sections._groups)
        _require(all(group in remaining for group in groups),
            'The PPTX serializer introduced or renamed unverified sections')
        numeric = {slide: source_reader._identity(node.attributes['id']) for slide, node in by_id.items()}
        expected = sections._groups, sections._ordered_groups(logical, numeric)
        if (groups, members) != expected:
            replacement = _section_xml(*expected)
            edits.append(_restore_sections(data, root, extension_list, replacement) if current is None
                else (current.start, current.end, replacement))
    chunks, position = [], 0
    for start, end, replacement in sorted(edits):
        _require(position <= start <= end <= len(data), 'PPTX slide order edits overlap')
        chunks.extend((data[position:start], replacement))
        position = end
    chunks.append(data[position:])
    _require(sum(map(len, chunks)) <= source_reader.PART_BYTES, 'PPTX slide order XML exceeds its byte limit')
    return b''.join(chunks), expected


def write_reordered_pptx(source, destination, expected_sha, physical, logical, sections):
    """Write and verify the exact slide-order candidate without a second native save."""
    destination = Path(destination)
    owned = None
    try:
        with source_reader.open_pptx_tables(source, max_package_bytes=MAX_PACKAGE_BYTES) as image:
            data, root, listing = _verified_edit_image(image, expected_sha)
            replacement, expected = _apply_slide_order(data, root, listing, physical, logical, sections)
            changed = {PRESENTATION: replacement} if replacement != data else {}
            _validate_payloads(image.archive, changed)
            by_id = dict(zip(physical, image.catalog['parts']))
            with destination.open('x+b', buffering=0) as output:
                owned = source_reader._stamp(os.fstat(output.fileno()))[:2]
                if changed:
                    _rewrite(image.archive, output, changed)
                else:
                    size = image.archive.fp.seek(0, os.SEEK_END)
                    _copy_interval(image.archive.fp, output, 0, size)
                output.flush()
                os.fsync(output.fileno())
                size = os.fstat(output.fileno()).st_size
                candidate_digest = source_reader._digest(output, size)
                count = source_reader._zip_envelope(output)
                with zipfile.ZipFile(output) as candidate:
                    _layout(candidate)
                    saved, saved_root, _ = _presentation(candidate)
                    _, _, groups, members = _sections(saved, saved_root)
                    _require(saved == replacement and (groups, members) == expected and
                        list(source_reader._catalog(candidate, count)['parts']) == [by_id[slide] for slide in logical] and
                        candidate.namelist() == image.archive.namelist() and candidate.testzip() is None,
                        'The verified PPTX slide order, section membership or ZIP differs')
                _require(source_reader._digest(output, size) == candidate_digest and
                    source_reader._stamp(destination.stat()) == source_reader._stamp(os.fstat(output.fileno())),
                    'The private PPTX order candidate changed during verification')
                return candidate_digest
    except BaseException as error:
        if owned is not None:
            try:
                if destination.exists():
                    _require(source_reader._stamp(destination.stat())[:2] == owned,
                        'Preserve a foreign replacement of the order candidate path')
                    destination.unlink()
            except Exception as cleanup_error:
                error.add_note('Removing owned failed PPTX order candidate: ' + str(cleanup_error))
        raise
