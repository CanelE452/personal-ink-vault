"""Exact authored PPTX table structure candidates, before native/publication gates."""
from decimal import Decimal
import os
from pathlib import Path
import struct
from xml.parsers import expat
import zipfile
import zlib

import office_presentation_package_patch as package_writer
import office_presentation_source as source_reader


FIELDS = frozenset(('sourcePart', 'expectedSourcePartSha256', 'xMm', 'yMm',
    'columnWidthsMm', 'rowHeightsMm'))
MAX_TABLES, MAX_CELLS = 20, 100
_require = package_writer._require
_sha = package_writer._sha


def _mm(value, positive=False):
    _require(type(value) in (int, float), 'A numeric millimetre dimension is required')
    number = Decimal(str(value))
    _require(number.is_finite() and -1000 <= number <= 1000 and (not positive or number > 0),
        'The table dimension is outside the supported millimetre range')
    hundredths = number * 100
    _require(hundredths == hundredths.to_integral_value(), 'Table dimensions require exact hundredths of a millimetre')
    return int(hundredths) * 360


def _sizes(values):
    _require(type(values) is list and 1 <= len(values) <= MAX_CELLS,
        'A bounded nonempty row or column size list is required')
    result = [_mm(value, positive=True) for value in values]
    _require(sum(result) <= 36000000, 'The total table dimension exceeds 1000 millimetres')
    return result


def _budget(tables):
    _require(len(tables) <= MAX_TABLES and sum(len(table['cells']) for table in tables) <= MAX_CELLS,
        'The complete presentation table or logical-cell budget is exceeded')


def _frame(shape_id, x, y, widths, heights):
    borders = ''.join('<a:' + side + ' w="12700"><a:solidFill><a:srgbClr val="000000"/>'
        '</a:solidFill><a:prstDash val="solid"/></a:' + side + '>' for side in ('lnL', 'lnR', 'lnT', 'lnB'))
    cell = ('<a:tc><a:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:rPr sz="1200">'
        '<a:solidFill><a:srgbClr val="000000"/></a:solidFill></a:rPr>'
        '<a:t xml:space="preserve"></a:t></a:r><a:endParaRPr sz="1200"/></a:p></a:txBody>'
        '<a:tcPr>' + borders + '<a:solidFill><a:srgbClr val="FFFFFF"/></a:solidFill></a:tcPr></a:tc>')
    grid = ''.join('<a:gridCol w="' + str(width) + '"/>' for width in widths)
    rows = ''.join('<a:tr h="' + str(height) + '">' + cell * len(widths) + '</a:tr>' for height in heights)
    return ('<p:graphicFrame xmlns:p="' + source_reader.P[:-1] + '" xmlns:a="' + source_reader.A[:-1] + '">'
        '<p:nvGraphicFramePr><p:cNvPr id="' + shape_id + '" name="Table ' + shape_id + '"/>'
        '<p:cNvGraphicFramePr><a:graphicFrameLocks noGrp="1"/></p:cNvGraphicFramePr><p:nvPr/>'
        '</p:nvGraphicFramePr><p:xfrm><a:off x="' + str(x) + '" y="' + str(y) + '"/>'
        '<a:ext cx="' + str(sum(widths)) + '" cy="' + str(sum(heights)) + '"/></p:xfrm>'
        '<a:graphic><a:graphicData uri="' + source_reader.TABLE + '"><a:tbl>'
        '<a:tblPr firstRow="0" bandRow="0"/><a:tblGrid>' + grid + '</a:tblGrid>' + rows +
        '</a:tbl></a:graphicData></a:graphic></p:graphicFrame>').encode('ascii')


def _projection(table):
    fields = ('sourcePart', 'shapeId', 'positionEmu', 'extentEmu', 'columnWidthsEmu', 'rowHeightsEmu')
    topology = ('row', 'column', 'rowSpan', 'columnSpan', 'covered', 'anchor')
    return {**{key: table[key] for key in fields},
        'cells': [{key: cell[key] for key in topology} for cell in table['cells']]}


def add_table_part(part_bytes, source_part, operation):
    """Insert one inline editable table without reserializing any existing XML."""
    _require(type(part_bytes) is bytes and 0 < len(part_bytes) <= source_reader.PART_BYTES,
        'An immutable bounded slide part is required')
    _require(type(source_part) is str and source_reader._member_name(source_part) == source_part and
        type(operation) is dict and set(operation) == FIELDS and operation['sourcePart'] == source_part and
        package_writer._hash_value(operation['expectedSourcePartSha256']) and
        _sha(part_bytes) == operation['expectedSourcePartSha256'], 'Invalid or stale closed source table operation')
    x, y = _mm(operation['xMm']), _mm(operation['yMm'])
    widths, heights = _sizes(operation['columnWidthsMm']), _sizes(operation['rowHeightsMm'])
    _require(len(widths) * len(heights) <= MAX_CELLS, 'The new logical cell grid exceeds its budget')
    try:
        root = source_reader._xml(part_bytes, {'nodes': 0})
        original_tables = source_reader._slide(root, source_part)
        _budget(original_tables)
        _require(len(original_tables) < MAX_TABLES and
            sum(len(table['cells']) for table in original_tables) + len(widths) * len(heights) <= MAX_CELLS,
            'The resulting slide table or logical-cell budget is exceeded')
        tree = source_reader._one(source_reader._one(root, source_reader.P + 'cSld'), source_reader.P + 'spTree')
        header = source_reader._one(tree, source_reader.P + 'nvGrpSpPr')
        properties = source_reader._one(tree, source_reader.P + 'grpSpPr')
        _require(not tree.empty and tree.children[:2] == [header, properties], 'The source shape tree headers are invalid')
        extensions = source_reader._children(tree, source_reader.P + 'extLst')
        _require(len(extensions) <= 1 and (not extensions or tree.children[-1] is extensions[0]),
            'The source shape tree extension list must be unique and last')
        used = {source_reader._identity(node.attributes.get('id')) for node in source_reader._walk(root)
            if node.name == source_reader.P + 'cNvPr'}
        identifier = 1
        while identifier in used:
            identifier += 1
        _require(identifier <= 0xFFFFFFFF, 'No positive nonvisual shape identity is available')
        shape_id = str(identifier)
        insertion = extensions[0].start if extensions else part_bytes.rfind(b'</', tree.tag_end, tree.end)
        _require(insertion >= tree.tag_end and (extensions or source_reader._tag_end(part_bytes, insertion) == tree.end),
            'The source shape tree has no exact insertion boundary')
        frame = _frame(shape_id, x, y, widths, heights)
        inserted = b'\n' + frame + b'\n'
        _require(len(part_bytes) + len(inserted) <= source_reader.PART_BYTES, 'The resulting slide XML exceeds its byte budget')
        result = part_bytes[:insertion] + inserted + part_bytes[insertion:]
        tables = source_reader._slide(source_reader._xml(result, {'nodes': 0}), source_part)
        expected = {'sourcePart': source_part, 'shapeId': shape_id, 'positionEmu': {'x': x, 'y': y},
            'extentEmu': {'width': sum(widths), 'height': sum(heights)},
            'columnWidthsEmu': widths, 'rowHeightsEmu': heights,
            'cells': [{'row': row, 'column': column, 'rowSpan': 1, 'columnSpan': 1, 'covered': False, 'anchor': None}
                for row in range(len(heights)) for column in range(len(widths))]}
        _require([_projection(table) for table in tables] ==
            [_projection(table) for table in original_tables] + [expected],
            'The authored table inventory differs from the requested insertion')
        return {'partBytes': result, 'sourcePartSha256': _sha(part_bytes), 'resultPartSha256': _sha(result),
            'shapeId': shape_id, 'frameSha256': _sha(frame), 'insertionByte': insertion,
            'insertedBytes': len(inserted), 'table': expected}
    except (expat.ExpatError, UnicodeError) as error:
        raise ValueError('Unsupported or invalid source table insertion XML') from error


def _plan(catalog, operations):
    parts, expected, ledger = dict(catalog['parts']), [_projection(table) for table in catalog['tables']], []
    _budget(catalog['tables'])
    for operation in operations:
        _require(type(operation) is dict and set(operation) == FIELDS and
            type(operation['sourcePart']) is str and operation['sourcePart'] in parts,
            'A source table insertion must target an exact existing slide part')
        part = operation['sourcePart']
        inserted = add_table_part(parts[part], part, operation)
        parts[part] = inserted['partBytes']
        expected.append(inserted['table'])
        _budget(expected)
        ledger.append({'sourcePart': part, **{key: value for key, value in inserted.items() if key != 'partBytes'}})
    order = {part: index for index, part in enumerate(parts)}
    expected.sort(key=lambda table: order[table['sourcePart']])
    return {part: data for part, data in parts.items() if data != catalog['parts'][part]}, expected, ledger


def _verify(original, current, changed, expected):
    _require(set(original['parts']) == set(current['parts']), 'The candidate source owners changed')
    _require(all(current['parts'][part] == changed.get(part, data) for part, data in original['parts'].items()),
        'The candidate differs from the exact source insertion plan')
    _require([_projection(table) for table in current['tables']] == expected,
        'The candidate table topology or geometry differs from the request-derived ledger')
    _budget(current['tables'])


def add_tables_pptx(source, destination, operations, expected_source_sha256):
    """Build an exclusive exact private candidate; native validation remains mandatory."""
    _require(type(operations) is list and len(operations) <= 100 and package_writer._hash_value(expected_source_sha256),
        'A bounded source structure batch and exact source SHA-256 are required')
    source, destination = Path(source), Path(destination)
    _require(source.stat().st_size <= package_writer.MAX_PACKAGE_BYTES, 'PPTX package byte limit exceeded before capture')
    owned = None
    try:
        with source_reader.open_pptx_tables(source, max_package_bytes=package_writer.MAX_PACKAGE_BYTES) as image:
            _require(image.catalog['sourceSha256'] == expected_source_sha256, 'The expected PPTX source SHA-256 is stale')
            image.archive.fp.seek(0, os.SEEK_END)
            size = image.archive.fp.tell()
            changed, expected, ledger = _plan(image.catalog, operations)
            _require(not changed or not package_writer._signed_package(image.archive), 'Signed PPTX structure edits are unsupported')
            referenced = {'[Content_Types].xml', '_rels/.rels', 'ppt/presentation.xml',
                'ppt/_rels/presentation.xml.rels', *image.catalog['parts']}
            _require(sum(len(changed[name]) if name in changed else image.archive.getinfo(name).file_size
                for name in referenced) <= source_reader.TOTAL_XML_BYTES, 'The resulting referenced XML total exceeds its budget')
            package_writer._validate_payloads(image.archive, changed)
            with destination.open('x+b', buffering=0) as output:
                owned = source_reader._stamp(os.fstat(output.fileno()))[:2]
                if changed:
                    package_writer._rewrite(image.archive, output, changed)
                else:
                    package_writer._copy_interval(image.archive.fp, output, 0, size)
                output.flush()
                os.fsync(output.fileno())
                output_size = output.tell()
                digest = source_reader._digest(output, output_size)
                _require(source_reader._stamp(destination.stat())[:2] == owned,
                    'The private structure candidate was replaced during verification')
                current = source_reader.read_pptx_tables(destination)
                _require(current['sourceSha256'] == digest, 'The structure candidate bytes differ from the constructed image')
                _verify(image.catalog, current, changed, expected)
                _require(source_reader._digest(output, output_size) == digest and
                    source_reader._stamp(destination.stat())[:2] == owned, 'The verified structure candidate changed')
            result = {'sourceSha256': expected_source_sha256, 'resultSha256': digest,
                'changedParts': sorted(changed), 'operationLedger': ledger}
        return result
    except BaseException as error:
        if owned is not None:
            try:
                if destination.exists():
                    _require(source_reader._stamp(destination.stat())[:2] == owned,
                        'Preserve the foreign replacement of the structure candidate')
                    destination.unlink()
            except Exception as cleanup_error:
                error.add_note('Removing owned failed PPTX structure candidate: ' + str(cleanup_error))
        if isinstance(error, (zipfile.BadZipFile, zipfile.LargeZipFile, zlib.error,
                UnicodeError, struct.error, StopIteration)):
            raise ValueError('Unsupported or invalid PPTX structure patch package') from error
        raise
