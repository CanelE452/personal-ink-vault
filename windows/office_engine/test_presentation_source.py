"""Pure PPTX source identity and exact UTF-8 spans; root alone executes.

An absent product module yields an explicit API/bootstrap assertion, not an
import error or a claim that XML parsing behavior has already been tested.
"""
import hashlib
import importlib
import importlib.util
import os
from pathlib import Path
import struct
from tempfile import TemporaryDirectory
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import warnings
import zipfile


P = 'http://schemas.openxmlformats.org/presentationml/2006/main'
A = 'http://schemas.openxmlformats.org/drawingml/2006/main'
R = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
PKG = 'http://schemas.openxmlformats.org/package/2006/relationships'
TABLE = 'http://schemas.openxmlformats.org/drawingml/2006/table'
SLIDE = R + '/slide'
XML_PART_BYTES = 8 * 1024 * 1024
MODULE = (importlib.import_module('office_presentation_source')
    if importlib.util.find_spec('office_presentation_source') is not None
    else SimpleNamespace(read_pptx_tables=None))


def cell_xml(text=None, attributes='', drawing='a'):
    text = ('<' + drawing + ':t xml:space="preserve">SAME 😀 é 한글 &amp; &lt;&gt;</' + drawing + ':t>') if text is None else text
    return ('<' + drawing + ':tc' + attributes + '><' + drawing + ':txBody><' + drawing + ':bodyPr/>'
        '<' + drawing + ':lstStyle/><' + drawing + ':p><' + drawing + ':r><' + drawing + ':rPr/>' + text +
        '</' + drawing + ':r><' + drawing + ':endParaRPr/></' + drawing + ':p></' + drawing + ':txBody>'
        '<' + drawing + ':tcPr/></' + drawing + ':tc>').encode('utf-8')


def table_xml(rows=None, drawing='a'):
    if rows is None:
        rows = [[cell_xml(drawing=drawing) for _ in range(2)] for _ in range(2)]
    grid = ('<' + drawing + ':tblGrid><' + drawing + ':gridCol w="3600000"/>'
        '<' + drawing + ':gridCol w="3600000"/></' + drawing + ':tblGrid>').encode('utf-8')
    row_xml = b''.join(('<' + drawing + ':tr h="1260000">').encode('ascii') + b''.join(row) +
        ('</' + drawing + ':tr>').encode('ascii') for row in rows)
    return ('<' + drawing + ':tbl><' + drawing + ':tblPr firstRow="1"/>').encode('ascii') + grid + row_xml + \
        ('</' + drawing + ':tbl>').encode('ascii')


def frame_xml(shape_id='9', table=None, presentation='p', drawing='a'):
    table = table_xml(drawing=drawing) if table is None else table
    prefix = ('<' + presentation + ':graphicFrame><' + presentation + ':nvGraphicFramePr>'
        '<' + presentation + ':cNvPr id="' + shape_id + '" name="Duplicate &gt; > table" title=""/>'
        '<' + presentation + ':cNvGraphicFramePr/><' + presentation + ':nvPr/></' + presentation + ':nvGraphicFramePr>'
        '<' + presentation + ':xfrm><' + drawing + ':off x="360000" y="540000"/>'
        '<' + drawing + ':ext cx="7200001" cy="2520000"/></' + presentation + ':xfrm>'
        '<' + drawing + ':graphic><' + drawing + ':graphicData uri="' + TABLE + '">').encode('utf-8')
    return prefix + table + ('</' + drawing + ':graphicData></' + drawing + ':graphic></' +
        presentation + ':graphicFrame>').encode('ascii')


def slide_xml(frames=(), presentation='p', drawing='a'):
    start = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\r\n'
        '<!-- 한글 😀 before frame bytes -->\r\n<?retained source?>\r\n'
        '<' + presentation + ':sld xmlns:' + presentation + '="' + P + '" xmlns:' + drawing + '="' + A + '" '
        'xmlns:r="' + R + '"><' + presentation + ':cSld name="한글 é"><' + presentation + ':spTree>'
        '<' + presentation + ':nvGrpSpPr><' + presentation + ':cNvPr id="1" name=""/>'
        '<' + presentation + ':cNvGrpSpPr/><' + presentation + ':nvPr/></' + presentation + ':nvGrpSpPr>'
        '<' + presentation + ':grpSpPr/>\r\n').encode('utf-8')
    separator = b'\r\n<!-- between exact frames --><?kept boundary?>\r\n'
    return start + separator.join(frames) + ('\r\n</' + presentation + ':spTree></' + presentation +
        ':cSld></' + presentation + ':sld>').encode('ascii')


def presentation_xml(order):
    ids = ''.join('<p:sldId id="' + str(256 + index) + '" r:id="' + identifier + '"/>'
        for index, identifier in enumerate(order))
    return ('<?xml version="1.0" encoding="UTF-8"?><p:presentation xmlns:p="' + P + '" xmlns:r="' + R +
        '"><p:sldIdLst>' + ids + '</p:sldIdLst></p:presentation>').encode('utf-8')


def relationships_xml(entries):
    contents = ''.join('<Relationship Id="' + identifier + '" Type="' + kind + '" Target="' + target + '"' +
        ('' if mode is None else ' TargetMode="' + mode + '"') + '/>'
        for identifier, target, kind, mode in entries)
    return ('<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="' + PKG + '">' +
        contents + '</Relationships>').encode('utf-8')


def package_members(slides=None, order=None, relationships=None):
    slides = {'ppt/slides/slide1.xml': slide_xml([frame_xml()])} if slides is None else slides
    order = ['rId1'] if order is None else order
    relationships = [('rId1', 'slides/slide1.xml', SLIDE, None)] if relationships is None else relationships
    content_types = ('<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>' +
        ''.join('<Override PartName="/' + part + '" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>'
            for part in slides) + '</Types>').encode('utf-8')
    return [('[Content_Types].xml', content_types),
        ('_rels/.rels', relationships_xml([('root', 'ppt/presentation.xml', R + '/officeDocument', None)])),
        ('ppt/presentation.xml', presentation_xml(order)),
        ('ppt/_rels/presentation.xml.rels', relationships_xml(relationships)),
        *slides.items(), ('ppt/media/unrelated.bin', b'UNCHANGED MEDIA\x00\xff')]


def write_package(path, members):
    with warnings.catch_warnings():
        warnings.simplefilter('ignore', UserWarning)
        with zipfile.ZipFile(path, 'w') as archive:
            archive.comment = b'PRESERVE ORIGINAL ZIP COMMENT'
            for name, data in members:
                information = zipfile.ZipInfo(name, (2024, 3, 2, 11, 12, 14))
                information.compress_type = zipfile.ZIP_STORED
                information.comment = b'PRESERVE MEMBER COMMENT'
                information.external_attr = 0o100600 << 16
                archive.writestr(information, data)


def declared_size(path, member, size):
    data = bytearray(path.read_bytes())
    position = 0
    while True:
        position = data.find(b'PK\x01\x02', position)
        if position < 0:
            raise AssertionError('The synthetic central-directory member was not found')
        name_length, extra_length, comment_length = struct.unpack_from('<HHH', data, position + 28)
        name = bytes(data[position + 46:position + 46 + name_length]).decode('utf-8')
        if name == member:
            struct.pack_into('<I', data, position + 24, size)
            path.write_bytes(data)
            return
        position += 46 + name_length + extra_length + comment_length


class PresentationSourceReaderTest(unittest.TestCase):
    def reader(self):
        api = getattr(MODULE, 'read_pptx_tables', None)
        self.assertTrue(callable(api),
            'BOOTSTRAP: office_presentation_source.read_pptx_tables has not been implemented; this is not XML parsing evidence')
        return api

    def read_valid(self, members):
        reader = self.reader()
        with TemporaryDirectory(prefix='piv-ppt-source-') as directory:
            path = Path(directory) / 'original.pptx'
            write_package(path, members)
            original, modified = path.read_bytes(), path.stat().st_mtime_ns
            result = reader(path)
            self.assertIsInstance(result, dict)
            self.assertEqual(result['sourceSha256'], hashlib.sha256(original).hexdigest())
            self.assertIsInstance(result['parts'], dict)
            self.assertIsInstance(result['tables'], list)
            self.assertEqual(path.read_bytes(), original)
            self.assertEqual(path.stat().st_mtime_ns, modified)
            self.assertEqual(list(Path(directory).iterdir()), [path])
            return result

    def rejected(self, members):
        reader = self.reader()
        with TemporaryDirectory(prefix='piv-ppt-source-reject-') as directory:
            path = Path(directory) / 'original.pptx'
            write_package(path, members)
            original = path.read_bytes()
            with self.assertRaises(ValueError):
                reader(path)
            self.assertEqual(path.read_bytes(), original)
            self.assertEqual(list(Path(directory).iterdir()), [path])

    def assert_span(self, xml, span, expected):
        self.assertIsInstance(span, (tuple, list))
        self.assertEqual(len(span), 2)
        start, end = span
        self.assertIs(type(start), int)
        self.assertIs(type(end), int)
        self.assertTrue(0 <= start < end <= len(xml))
        self.assertEqual(xml[start:end], expected)

    def test_read_pptx_tables_api_is_explicit(self):
        self.reader()

    def test_duplicate_names_and_bodies_keep_part_and_source_shape_identity(self):
        first, second = frame_xml('9'), frame_xml('10')
        xml = slide_xml([first, second])
        catalog = self.read_valid(package_members({'ppt/slides/slide1.xml': xml}))
        self.assertEqual([(item['sourcePart'], item['shapeId']) for item in catalog['tables']],
            [('ppt/slides/slide1.xml', '9'), ('ppt/slides/slide1.xml', '10')])
        self.assertEqual(catalog['parts']['ppt/slides/slide1.xml'], xml)
        for item, frame in zip(catalog['tables'], [first, second]):
            self.assertEqual(item['positionEmu'], {'x': 360000, 'y': 540000})
            self.assertEqual(item['extentEmu'], {'width': 7200001, 'height': 2520000})
            self.assertEqual(item['columnWidthsEmu'], [3600000, 3600000])
            self.assertEqual(item['rowHeightsEmu'], [1260000, 1260000])
            self.assertNotEqual(item['extentEmu']['width'], sum(item['columnWidthsEmu']))
            self.assertNotIn('nativeBoundsHmm', item)
            self.assert_span(xml, item['frameSpan'], frame)
            self.assert_span(xml, item['tableSpan'], table_xml())
            self.assertTrue(item['frameSpan'][0] < item['tableSpan'][0] < item['tableSpan'][1] < item['frameSpan'][1])
            self.assertEqual(item['tableSpan'][0], item['frameSpan'][0] + frame.index(table_xml()))
            previous_cell_end = item['tableSpan'][0]
            self.assertEqual([(cell['row'], cell['column']) for cell in item['cells']],
                [(0, 0), (0, 1), (1, 0), (1, 1)])
            for cell in item['cells']:
                self.assertEqual((cell['rowSpan'], cell['columnSpan'], cell['covered'], cell['anchor']),
                    (1, 1, False, None))
                self.assert_span(xml, cell['cellSpan'], cell_xml())
                self.assertTrue(previous_cell_end <= cell['cellSpan'][0] < cell['cellSpan'][1] < item['tableSpan'][1])
                previous_cell_end = cell['cellSpan'][1]
        self.assertNotEqual(catalog['tables'][0]['frameSpan'], catalog['tables'][1]['frameSpan'])

    def test_slide_relationship_order_controls_membership_without_zip_or_name_fallback(self):
        slides = {'ppt/slides/slide1.xml': slide_xml([frame_xml('9')]),
            'ppt/slides/slide2.xml': slide_xml([frame_xml('9')]),
            'ppt/slides/orphan.xml': slide_xml([frame_xml('77')])}
        relationships = [('rIdA', 'slides/slide1.xml', SLIDE, None),
            ('rIdB', 'slides/slide2.xml', SLIDE, None)]
        catalog = self.read_valid(package_members(slides, ['rIdB', 'rIdA'], relationships))
        self.assertEqual([(item['sourcePart'], item['shapeId']) for item in catalog['tables']],
            [('ppt/slides/slide2.xml', '9'), ('ppt/slides/slide1.xml', '9')])
        self.assertFalse(any(item['sourcePart'].endswith('orphan.xml') for item in catalog['tables']))

    def test_unicode_crlf_prefixes_comments_and_processing_instructions_keep_exact_byte_slices(self):
        for presentation, drawing in [('p', 'a'), ('pres', 'draw')]:
            with self.subTest(presentation=presentation, drawing=drawing):
                texts = [
                    '<' + drawing + ':t xml:space="preserve">한글 😀 é &amp; &lt; &gt;</' + drawing + ':t>',
                    '<' + drawing + ':t><![CDATA[ literal > < ]]></' + drawing + ':t>',
                    '<' + drawing + ':t/>', '<' + drawing + ':t></' + drawing + ':t>']
                cells = [cell_xml(text, drawing=drawing) for text in texts]
                table = table_xml([cells[:2], cells[2:]], drawing)
                frame = frame_xml('009', table, presentation, drawing)
                xml = slide_xml([frame], presentation, drawing)
                catalog = self.read_valid(package_members({'ppt/slides/slide1.xml': xml}))
                item = catalog['tables'][0]
                self.assertEqual(item['shapeId'], '009')
                self.assertEqual(catalog['parts'][item['sourcePart']], xml)
                self.assert_span(xml, item['frameSpan'], frame)
                self.assertEqual(item['frameSpan'][0], xml.index(frame))
                self.assertNotEqual(item['frameSpan'][0], xml.decode('utf-8').index(frame.decode('utf-8')))
                self.assert_span(xml, item['tableSpan'], table)
                for cell, expected_cell, expected_text in zip(item['cells'], cells, texts):
                    self.assert_span(xml, cell['cellSpan'], expected_cell)
                    self.assertEqual(len(cell['textSpans']), 1)
                    self.assert_span(xml, cell['textSpans'][0], expected_text.encode('utf-8'))
                    self.assertTrue(cell['cellSpan'][0] < cell['textSpans'][0][0] < cell['textSpans'][0][1] < cell['cellSpan'][1])

    def test_verified_empty_referenced_slide_is_an_empty_catalog(self):
        xml = slide_xml()
        catalog = self.read_valid(package_members({'ppt/slides/slide1.xml': xml}))
        self.assertEqual(catalog['tables'], [])
        self.assertEqual(catalog['parts']['ppt/slides/slide1.xml'], xml)

    def test_explicit_merged_anchor_and_covered_cell_keep_the_complete_partition(self):
        rows = [[cell_xml(attributes=' gridSpan="2"'), cell_xml(attributes=' hMerge="1"')],
            [cell_xml(), cell_xml()]]
        catalog = self.read_valid(package_members({'ppt/slides/slide1.xml': slide_xml([frame_xml(table=table_xml(rows))])}))
        cells = catalog['tables'][0]['cells']
        self.assertEqual((cells[0]['rowSpan'], cells[0]['columnSpan'], cells[0]['covered'], cells[0]['anchor']),
            (1, 2, False, None))
        self.assertEqual((cells[1]['rowSpan'], cells[1]['columnSpan'], cells[1]['covered'], cells[1]['anchor']),
            (1, 1, True, {'row': 0, 'column': 0}))
        self.assertEqual(len(cells[1]['textSpans']), 1, 'Covered source text must not be discarded')
        self.assertEqual([(cell['row'], cell['column']) for cell in cells], [(0, 0), (0, 1), (1, 0), (1, 1)])

    def test_duplicate_zip_members_are_rejected_even_for_unrelated_media(self):
        original = package_members()
        for name in ('ppt/slides/slide1.xml', 'ppt/media/unrelated.bin'):
            with self.subTest(member=name):
                self.rejected([*original, (name, dict(original)[name])])

    def test_nonvisual_ids_are_unique_numerically_across_the_entire_slide_scope(self):
        ordinary = b'<p:sp><p:nvSpPr><p:cNvPr id="9" name="Ordinary"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr/></p:sp>'
        group = b'<p:grpSp><p:nvGrpSpPr><p:cNvPr id="9" name="Group"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/></p:grpSp>'
        for label, frames in [('table', [frame_xml('9'), frame_xml('9')]),
                ('numeric-alias', [frame_xml('9'), frame_xml('09')]),
                ('ordinary-shape', [ordinary, frame_xml('9')]), ('group', [group, frame_xml('9')])]:
            with self.subTest(scope=label):
                self.rejected(package_members({'ppt/slides/slide1.xml': slide_xml(frames)}))

    def test_ambiguous_external_or_escaping_slide_relationships_are_rejected(self):
        cases = [
            ('external', ['rId1'], [('rId1', 'https://invalid.test/slide.xml', SLIDE, 'External')]),
            ('file-uri', ['rId1'], [('rId1', 'file:///private/slide.xml', SLIDE, None)]),
            ('escape', ['rId1'], [('rId1', '../../outside.xml', SLIDE, None)]),
            ('encoded-escape', ['rId1'], [('rId1', '%2e%2e/%2e%2e/outside.xml', SLIDE, None)]),
            ('backslash', ['rId1'], [('rId1', '..\\..\\outside.xml', SLIDE, None)]),
            ('missing-id', ['absent'], [('rId1', 'slides/slide1.xml', SLIDE, None)]),
            ('wrong-type', ['rId1'], [('rId1', 'slides/slide1.xml', R + '/image', None)]),
            ('missing-part', ['rId1'], [('rId1', 'slides/missing.xml', SLIDE, None)]),
            ('duplicate-rel-id', ['rId1'], [('rId1', 'slides/slide1.xml', SLIDE, None), ('rId1', 'slides/slide1.xml', SLIDE, None)]),
            ('duplicate-part', ['rId1', 'rId2'], [('rId1', 'slides/slide1.xml', SLIDE, None), ('rId2', 'slides/slide1.xml', SLIDE, None)]),
        ]
        for label, order, relationships in cases:
            with self.subTest(case=label):
                self.rejected(package_members(order=order, relationships=relationships))

    def test_malformed_non_utf8_doctype_and_ambiguous_table_xml_are_rejected(self):
        valid = slide_xml([frame_xml()])
        variants = {
            'malformed': valid.replace(b'</a:tbl>', b'</a:unknown>', 1),
            'invalid-utf8': valid.replace('한글'.encode('utf-8'), b'\xff\xfe', 1),
            'utf16': valid.decode('utf-8').replace('encoding="UTF-8"', 'encoding="UTF-16"').encode('utf-16'),
            'doctype': valid.replace(b'?>\r\n', b'?>\r\n<!DOCTYPE p:sld [<!ENTITY declared "unsafe">]>', 1),
            'external-entity': valid.replace(b'?>\r\n', b'?>\r\n<!DOCTYPE p:sld SYSTEM "file:///private/never-read">', 1),
            'wrong-table-uri': valid.replace(TABLE.encode('ascii'), b'urn:unknown-table', 1),
            'two-tables-one-frame': valid.replace(b'</a:graphicData>', table_xml() + b'</a:graphicData>', 1),
            'unknown-text-markup': valid.replace(b'<a:t xml:space="preserve">', b'<a:t xml:space="preserve"><a:unknown/>', 1),
        }
        for label, xml in variants.items():
            with self.subTest(case=label):
                self.rejected(package_members({'ppt/slides/slide1.xml': xml}))

    def test_missing_duplicate_or_noninteger_authored_geometry_is_not_invented(self):
        valid = slide_xml([frame_xml()])
        variants = [valid.replace(b'<a:off x="360000" y="540000"/>', b'', 1),
            valid.replace(b'<a:ext cx="7200001" cy="2520000"/>', b'<a:ext cx="7200001"/>', 1),
            valid.replace(b'<a:off x="360000" y="540000"/>', b'<a:off x="1" y="2"/><a:off x="360000" y="540000"/>', 1),
            valid.replace(b'cx="7200001"', b'cx="7200001.5"', 1),
            valid.replace(b'w="3600000"', b'w="unknown"', 1),
            valid.replace(b'h="1260000"', b'h=""', 1)]
        for index, xml in enumerate(variants):
            with self.subTest(variant=index):
                self.rejected(package_members({'ppt/slides/slide1.xml': xml}))

    def test_unknown_or_inconsistent_cell_span_topology_is_rejected(self):
        cases = [
            ('missing-coordinate', [[cell_xml()], [cell_xml(), cell_xml()]]),
            ('dangling-covered', [[cell_xml(), cell_xml(attributes=' hMerge="1"')], [cell_xml(), cell_xml()]]),
            ('out-of-bounds', [[cell_xml(attributes=' gridSpan="3"'), cell_xml(attributes=' hMerge="1"')], [cell_xml(), cell_xml()]]),
            ('missing-covered-flag', [[cell_xml(attributes=' gridSpan="2"'), cell_xml()], [cell_xml(), cell_xml()]]),
            ('zero-span', [[cell_xml(attributes=' rowSpan="0"'), cell_xml()], [cell_xml(), cell_xml()]]),
            ('noninteger-span', [[cell_xml(attributes=' gridSpan="1.5"'), cell_xml()], [cell_xml(), cell_xml()]]),
            ('unknown-merge', [[cell_xml(attributes=' hMerge="unknown"'), cell_xml()], [cell_xml(), cell_xml()]]),
            ('overlapping-anchors', [[cell_xml(attributes=' gridSpan="2"'), cell_xml(attributes=' rowSpan="2"')], [cell_xml(), cell_xml(attributes=' vMerge="1"')]]),
        ]
        for label, rows in cases:
            with self.subTest(case=label):
                self.rejected(package_members({'ppt/slides/slide1.xml': slide_xml([frame_xml(table=table_xml(rows))])}))

    def test_unrelated_media_is_not_decompressed_by_the_source_reader(self):
        reader = self.reader()
        with TemporaryDirectory(prefix='piv-ppt-source-media-') as directory:
            path = Path(directory) / 'original.pptx'
            write_package(path, package_members())
            original = path.read_bytes()
            opened = []
            original_open = zipfile.ZipFile.open

            def observed_open(archive, name, *args, **kwargs):
                member = name.filename if isinstance(name, zipfile.ZipInfo) else name
                opened.append(member)
                if member == 'ppt/media/unrelated.bin':
                    raise AssertionError('Unrelated media must not be decompressed')
                return original_open(archive, name, *args, **kwargs)

            with patch.object(zipfile.ZipFile, 'open', observed_open):
                catalog = reader(path)
            self.assertEqual(len(catalog['tables']), 1)
            self.assertNotIn('ppt/media/unrelated.bin', opened)
            self.assertEqual(path.read_bytes(), original)

    def test_declared_oversize_xml_is_rejected_before_opening_its_payload(self):
        reader = self.reader()
        with TemporaryDirectory(prefix='piv-ppt-source-size-') as directory:
            path = Path(directory) / 'original.pptx'
            write_package(path, package_members())
            declared_size(path, 'ppt/slides/slide1.xml', XML_PART_BYTES + 1)
            original, attempted = path.read_bytes(), []
            original_open = zipfile.ZipFile.open

            def observed_open(archive, name, *args, **kwargs):
                member = name.filename if isinstance(name, zipfile.ZipInfo) else name
                if member == 'ppt/slides/slide1.xml':
                    attempted.append(member)
                    raise AssertionError('Declared oversize XML must close before payload read')
                return original_open(archive, name, *args, **kwargs)

            with patch.object(zipfile.ZipFile, 'open', observed_open):
                with self.assertRaises(ValueError):
                    reader(path)
            self.assertEqual(attempted, [])
            self.assertEqual(path.read_bytes(), original)

    def test_small_declared_size_does_not_authorize_an_unbounded_xml_read(self):
        reader = self.reader()
        with TemporaryDirectory(prefix='piv-ppt-source-stream-') as directory:
            path = Path(directory) / 'original.pptx'
            write_package(path, package_members())
            declared_size(path, 'ppt/slides/slide1.xml', 1)
            original, requests = path.read_bytes(), []
            original_open = zipfile.ZipFile.open
            case = self

            class BoundedRead:
                def __init__(self, inner):
                    self.inner = inner

                def __enter__(self):
                    self.inner.__enter__()
                    return self

                def __exit__(self, *arguments):
                    return self.inner.__exit__(*arguments)

                def read(self, size=-1):
                    requests.append(size)
                    case.assertIs(type(size), int)
                    case.assertTrue(0 <= size <= XML_PART_BYTES + 1,
                        'The XML stream requires an explicit cap+1 read even when ZIP metadata lies')
                    return self.inner.read(size)

                def __getattr__(self, name):
                    return getattr(self.inner, name)

            def observed_open(archive, name, *args, **kwargs):
                member = name.filename if isinstance(name, zipfile.ZipInfo) else name
                stream = original_open(archive, name, *args, **kwargs)
                return BoundedRead(stream) if member == 'ppt/slides/slide1.xml' else stream

            with patch.object(zipfile.ZipFile, 'open', observed_open):
                with self.assertRaises(ValueError):
                    reader(path)
            self.assertTrue(requests)
            self.assertTrue(all(type(size) is int and 0 <= size <= XML_PART_BYTES + 1 for size in requests))
            self.assertEqual(path.read_bytes(), original)

    def test_crc_corruption_of_otherwise_valid_xml_is_rejected(self):
        reader = self.reader()
        with TemporaryDirectory(prefix='piv-ppt-source-crc-') as directory:
            path = Path(directory) / 'original.pptx'
            write_package(path, package_members())
            corrupted = path.read_bytes().replace(b'SAME', b'TAME', 1)
            path.write_bytes(corrupted)
            with self.assertRaises(ValueError):
                reader(path)
            self.assertEqual(path.read_bytes(), corrupted)

    def test_zip_member_count_is_bounded_without_large_member_payloads(self):
        members = package_members()
        members.extend(('ppt/media/empty-' + str(index) + '.bin', b'') for index in range(4097 - len(members)))
        self.rejected(members)

    def test_referenced_xml_total_is_bounded_before_large_payload_reads(self):
        reader = self.reader()
        slides = {'ppt/slides/slide' + str(index) + '.xml': slide_xml([frame_xml()]) for index in range(1, 6)}
        order = ['rId' + str(index) for index in range(1, 6)]
        relationships = [(identifier, 'slides/slide' + str(index) + '.xml', SLIDE, None)
            for index, identifier in enumerate(order, 1)]
        with TemporaryDirectory(prefix='piv-ppt-source-total-') as directory:
            path = Path(directory) / 'original.pptx'
            write_package(path, package_members(slides, order, relationships))
            for member in slides:
                declared_size(path, member, 7 * 1024 * 1024)
            original, attempted = path.read_bytes(), []
            original_open = zipfile.ZipFile.open

            def observed_open(archive, name, *args, **kwargs):
                member = name.filename if isinstance(name, zipfile.ZipInfo) else name
                if member in slides:
                    attempted.append(member)
                    raise AssertionError('The referenced XML total must close before declared-large payload reads')
                return original_open(archive, name, *args, **kwargs)

            with patch.object(zipfile.ZipFile, 'open', observed_open):
                with self.assertRaises(ValueError):
                    reader(path)
            self.assertEqual(attempted, [])
            self.assertEqual(path.read_bytes(), original)


    def test_valid_source_is_readable_when_fd_ctime_alone_differs_from_path_metadata(self):
        reader = self.reader()
        with TemporaryDirectory(prefix='piv-ppt-source-ctime-') as directory:
            path = Path(directory) / 'original.pptx'
            write_package(path, package_members())
            original, modified = path.read_bytes(), path.stat().st_mtime_ns
            original_fstat = os.fstat
            observed = []

            def fd_creation_time_facade(descriptor):
                actual = original_fstat(descriptor)
                fields = {name: getattr(actual, name) for name in dir(actual) if name.startswith('st_')}
                fields['st_ctime_ns'] = actual.st_ctime_ns + 123456789
                observed.append((actual.st_ctime_ns, fields['st_ctime_ns']))
                return SimpleNamespace(**fields)

            failure = None
            with patch.object(MODULE.os, 'fstat', side_effect=fd_creation_time_facade):
                try:
                    catalog = reader(path)
                except ValueError as error:
                    failure = str(error)
            if failure is not None:
                self.fail('The valid immutable source was rejected only because fd ctime differed: ' + failure)
            self.assertTrue(observed)
            self.assertTrue(all(actual != facaded for actual, facaded in observed))
            self.assertEqual(catalog['sourceSha256'], hashlib.sha256(original).hexdigest())
            self.assertEqual(len(catalog['tables']), 1)
            self.assertEqual(catalog['tables'][0]['shapeId'], '9')
            self.assertEqual(catalog['parts']['ppt/slides/slide1.xml'], dict(package_members())['ppt/slides/slide1.xml'])
            self.assertEqual(path.read_bytes(), original)
            self.assertEqual(path.stat().st_mtime_ns, modified)

    def test_late_same_size_media_change_with_restored_mtime_is_rejected_by_source_binding(self):
        reader = self.reader()
        with TemporaryDirectory(prefix='piv-ppt-source-late-change-') as directory:
            path = Path(directory) / 'original.pptx'
            write_package(path, package_members())
            original, before = path.read_bytes(), path.stat()
            payload, replacement = b'UNCHANGED MEDIA\x00\xff', b'MODIFIED! MEDIA\x00\xff'
            self.assertEqual(len(payload), len(replacement))
            self.assertEqual(original.count(payload), 1)
            offset = original.index(payload)
            expected = original[:offset] + replacement + original[offset + len(payload):]
            changed, media_opened = [], []
            original_open = zipfile.ZipFile.open

            def change_owned_fixture_during_slide_open(archive, name, *args, **kwargs):
                member = name.filename if isinstance(name, zipfile.ZipInfo) else name
                if member == 'ppt/media/unrelated.bin':
                    media_opened.append(member)
                    raise AssertionError('The unrelated media must remain uninflated')
                if member == 'ppt/slides/slide1.xml' and not changed:
                    # The test changes its own synthetic ZIP; the reader never writes it.
                    with path.open('r+b') as owned_fixture:
                        owned_fixture.seek(offset)
                        owned_fixture.write(replacement)
                    os.utime(path, ns=(before.st_atime_ns, before.st_mtime_ns))
                    changed.append(member)
                return original_open(archive, name, *args, **kwargs)

            with patch.object(zipfile.ZipFile, 'open', change_owned_fixture_during_slide_open):
                with self.assertRaises(ValueError):
                    reader(path)
            self.assertEqual(changed, ['ppt/slides/slide1.xml'],
                'The read must reach the late mutation instead of failing its initial identity check')
            self.assertEqual(media_opened, [])
            after = path.stat()
            self.assertEqual((after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns),
                (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns))
            self.assertEqual(path.read_bytes(), expected)
            self.assertNotEqual(hashlib.sha256(expected).hexdigest(), hashlib.sha256(original).hexdigest())

    def test_same_inode_aba_cannot_pair_original_hash_with_another_valid_xml_view(self):
        reader = self.reader()
        part = 'ppt/slides/slide1.xml'
        members_a = package_members()
        expected_parts = dict(members_a)
        xml_a = expected_parts[part]
        xml_b = xml_a.replace(b'cx="7200001"', b'cx="7200002"', 1)
        self.assertNotEqual(xml_a, xml_b)
        with TemporaryDirectory(prefix='piv-ppt-source-aba-') as directory, \
                TemporaryDirectory(prefix='piv-ppt-source-aba-b-') as alternate_directory:
            path = Path(directory) / 'original.pptx'
            alternate = Path(alternate_directory) / 'alternate.pptx'
            write_package(path, members_a)
            write_package(alternate, package_members({part: xml_b}))
            original, replacement = path.read_bytes(), alternate.read_bytes()
            before = path.stat()
            source_hash = hashlib.sha256(original).hexdigest()
            self.assertEqual(len(original), len(replacement))
            self.assertNotEqual(source_hash, hashlib.sha256(replacement).hexdigest())
            for package, expected_xml in ((path, xml_a), (alternate, xml_b)):
                with zipfile.ZipFile(package) as archive:
                    self.assertIsNone(archive.testzip())
                    self.assertEqual(archive.read(part), expected_xml)
            mutations, parsed_views, restored_hashes = [], [], []
            original_envelope, original_catalog = MODULE._zip_envelope, MODULE._catalog

            def overwrite_owned_source(payload, restore_mtime=False):
                with path.open('r+b', buffering=0) as owned_fixture:
                    self.assertEqual(owned_fixture.write(payload), len(payload))
                    owned_fixture.flush()
                    os.fsync(owned_fixture.fileno())
                if restore_mtime:
                    os.utime(path, ns=(before.st_atime_ns, before.st_mtime_ns))
                current = path.stat()
                self.assertEqual((current.st_dev, current.st_ino, current.st_size),
                    (before.st_dev, before.st_ino, before.st_size))

            def change_original_after_envelope(*args, **kwargs):
                result = original_envelope(*args, **kwargs)
                if not mutations:
                    self.assertEqual(path.read_bytes(), original)
                    overwrite_owned_source(replacement)
                    self.assertEqual(path.read_bytes(), replacement)
                    mutations.append('B-after-envelope')
                return result

            def restore_original_after_catalog(*args, **kwargs):
                result = original_catalog(*args, **kwargs)
                parsed_views.append(result['parts'][part])
                if mutations == ['B-after-envelope']:
                    self.assertEqual(path.read_bytes(), replacement)
                    overwrite_owned_source(original, restore_mtime=True)
                    restored_hashes.append(hashlib.sha256(path.read_bytes()).hexdigest())
                    mutations.append('A-after-catalog')
                return result

            catalog, rejected = None, None
            try:
                with patch.object(MODULE, '_zip_envelope', change_original_after_envelope), \
                        patch.object(MODULE, '_catalog', restore_original_after_catalog):
                    try:
                        catalog = reader(path)
                    except ValueError as error:
                        rejected = error
            finally:
                if path.read_bytes() != original or path.stat().st_mtime_ns != before.st_mtime_ns:
                    overwrite_owned_source(original, restore_mtime=True)
            self.assertEqual(mutations, ['B-after-envelope', 'A-after-catalog'],
                'Both late hooks must complete; an initial reader rejection is not an ABA guard')
            self.assertTrue(parsed_views)
            self.assertTrue(all(view in (xml_a, xml_b) for view in parsed_views))
            self.assertEqual(restored_hashes, [source_hash], 'The catalog hook itself must restore A before the final source check')
            after = path.stat()
            self.assertEqual((after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns),
                (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns))
            self.assertEqual(path.read_bytes(), original)
            self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), source_hash)
            if rejected is None:
                self.assertEqual(catalog['sourceSha256'], source_hash)
                parts_a = catalog['parts'].get(part) == xml_a and all(
                    name in expected_parts and data == expected_parts[name]
                    for name, data in catalog['parts'].items())
                geometry_a = len(catalog['tables']) == 1 and catalog['tables'][0]['extentEmu'] == {
                    'width': 7200001, 'height': 2520000}
                self.assertTrue(parts_a and geometry_a,
                    'ABA source binding returned hash(A) with XML parts or geometry from another valid view')
            else:
                self.assertIsNone(catalog)


if __name__ == '__main__':
    unittest.main()
