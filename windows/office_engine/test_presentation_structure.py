"""Request-derived PPTX table insertion and raw-package preservation tests.

These tests provide source/XML/ZIP evidence only. Root alone executes them;
actual TableShape binding, rendering, and publication require separate gates.
"""
from contextlib import contextmanager
from copy import deepcopy
import hashlib
import importlib
import importlib.util
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace
import unittest
import zipfile

import office_presentation_source as source_reader
from office_presentation_text_patch import patch_cell_text
from office_presentation_text_source import cell_text_map
from test_presentation_package_patch import archive_bytes, central_records, physical_records
from test_presentation_source import A, P, SLIDE, cell_xml, frame_xml, package_members, slide_xml


MODULE = (importlib.import_module('office_presentation_structure')
    if importlib.util.find_spec('office_presentation_structure') is not None
    else SimpleNamespace(add_table_part=None, add_tables_pptx=None))
PART = 'ppt/slides/slide1.xml'
SECOND = 'ppt/slides/slide2.xml'


def sha(data):
    return hashlib.sha256(data).hexdigest()


def operation(part, source_part=PART, **changes):
    return {'sourcePart': source_part, 'expectedSourcePartSha256': sha(part),
        'xMm': 10, 'yMm': 20, 'columnWidthsMm': [30, 40], 'rowHeightsMm': [15, 25],
        **changes}


def tables(part, source_part=PART):
    return source_reader._slide(source_reader._xml(part, {'nodes': 0}), source_part)


def ordinary(shape_id):
    return ('<p:sp><p:nvSpPr><p:cNvPr id="' + shape_id + '" name="same"/>'
        '<p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr/></p:sp>').encode('ascii')


def grid_frame(shape_id, rows=1, columns=1):
    grid = b'<a:tblGrid>' + b'<a:gridCol w="36000"/>' * columns + b'</a:tblGrid>'
    row = b'<a:tr h="36000">' + cell_xml() * columns + b'</a:tr>'
    return frame_xml(shape_id, b'<a:tbl><a:tblPr/>' + grid + row * rows + b'</a:tbl>')


class PresentationStructurePartTest(unittest.TestCase):
    def api(self):
        function = getattr(MODULE, 'add_table_part', None)
        self.assertTrue(callable(function),
            'BOOTSTRAP: add_table_part is absent; this is not source/native creation evidence')
        return function

    def insert(self, part, supplied=None, source_part=PART):
        supplied = operation(part, source_part) if supplied is None else supplied
        before = deepcopy(supplied)
        result = self.api()(part, source_part, supplied)
        self.assertEqual(supplied, before, 'The caller-owned request must remain unchanged')
        self.assertIsInstance(result, dict)
        self.assertTrue({'partBytes', 'sourcePartSha256', 'resultPartSha256', 'shapeId',
            'frameSha256', 'insertionByte', 'insertedBytes'} <= result.keys())
        candidate = result['partBytes']
        self.assertIs(type(candidate), bytes)
        self.assertIs(type(result['shapeId']), str)
        self.assertTrue(result['shapeId'].isascii() and result['shapeId'].isdecimal())
        self.assertTrue(1 <= int(result['shapeId']) <= 0xFFFFFFFF)
        position, length = result['insertionByte'], result['insertedBytes']
        self.assertIs(type(position), int)
        self.assertIs(type(length), int)
        self.assertTrue(0 <= position <= len(part))
        self.assertGreater(length, 0)
        self.assertEqual(len(candidate), len(part) + length)
        self.assertEqual(candidate[:position] + candidate[position + length:], part,
            'Removing exactly the inserted interval must recover every original XML byte')
        self.assertEqual(result['sourcePartSha256'], sha(part))
        self.assertEqual(result['resultPartSha256'], sha(candidate))
        found = [table for table in tables(candidate, source_part) if table['shapeId'] == result['shapeId']]
        self.assertEqual(len(found), 1)
        table = found[0]
        frame_start, frame_end = table['frameSpan']
        self.assertTrue(position <= frame_start < frame_end <= position + length)
        self.assertEqual(result['frameSha256'], sha(candidate[frame_start:frame_end]))
        return result, table

    def rejected(self, part, supplied=None, source_part=PART):
        supplied = operation(part, source_part) if supplied is None else supplied
        with self.assertRaises(ValueError):
            self.api()(part, source_part, supplied)

    def test_api_is_explicit(self):
        self.api()

    def test_adds_actual_top_level_table_with_exact_geometry_and_original_bytes(self):
        part = slide_xml([ordinary('9'), frame_xml('10')])
        result, table = self.insert(part, operation(part, xMm=.29, yMm=-.29,
            columnWidthsMm=[.29, 1.01], rowHeightsMm=[2.5, .29]))
        self.assertEqual(result['shapeId'], '2')
        self.assertEqual(table['positionEmu'], {'x': 10440, 'y': -10440})
        self.assertEqual(table['columnWidthsEmu'], [10440, 36360])
        self.assertEqual(table['rowHeightsEmu'], [90000, 10440])
        self.assertEqual(table['extentEmu'], {'width': 46800, 'height': 100440})
        self.assertEqual(len(table['cells']), 4)
        self.assertTrue(all((cell['rowSpan'], cell['columnSpan'], cell['covered'], cell['anchor']) ==
            (1, 1, False, None) for cell in table['cells']))
        root = source_reader._xml(result['partBytes'], {'nodes': 0})
        tree = source_reader._one(source_reader._one(root, source_reader.P + 'cSld'), source_reader.P + 'spTree')
        self.assertEqual(sum(child.name == source_reader.P + 'graphicFrame' and child.start == table['frameSpan'][0]
            for child in tree.children), 1)
        before = {item['shapeId']: part[slice(*item['frameSpan'])] for item in tables(part)}
        after = {item['shapeId']: result['partBytes'][slice(*item['frameSpan'])] for item in tables(result['partBytes'])}
        for identity, original_frame in before.items():
            self.assertEqual(after[identity], original_frame)

    def test_all_empty_cells_have_paired_text_and_accept_existing_unicode_patch(self):
        result, table = self.insert(slide_xml())
        candidate = result['partBytes']
        for cell in table['cells']:
            mapped = cell_text_map(candidate, cell)
            self.assertEqual(mapped['text'], '')
            self.assertTrue(any(segment['editable'] for segment in mapped['segments']))
            text_nodes = [node for node in source_reader._walk(source_reader._xml(candidate, {'nodes': 0}))
                if node.name == source_reader.A + 't' and cell['cellSpan'][0] <= node.start < cell['cellSpan'][1]]
            self.assertEqual(len(text_nodes), 1)
            self.assertFalse(text_nodes[0].empty, 'Self-closing a:t cannot grant insertion authority')
            patched = patch_cell_text(candidate, cell, 0, 0, '한글 😀 é &<>', sha(b''))
            updated = next(item for item in tables(patched['partBytes'])[0]['cells']
                if (item['row'], item['column']) == (cell['row'], cell['column']))
            self.assertEqual(cell_text_map(patched['partBytes'], updated)['text'], '한글 😀 é &<>')

    def test_prefix_shadowing_cannot_redirect_generated_presentation_or_drawing_elements(self):
        part = slide_xml([frame_xml('9', presentation='deck', drawing='draw')], 'deck', 'draw')
        part = part.replace(b'<deck:sld ', b'<deck:sld xmlns:p="urn:foreign-p" xmlns:a="urn:foreign-a" '
            b'xmlns:pivp="urn:foreign-pivp" xmlns:piva="urn:foreign-piva" ', 1)
        result, table = self.insert(part)
        start = table['frameSpan'][0]
        tag = result['partBytes'][start:source_reader._tag_end(result['partBytes'], start)]
        self.assertIn(P.encode('ascii'), tag)
        self.assertIn(A.encode('ascii'), tag)
        self.assertEqual(len(tables(result['partBytes'])), 2)

    def test_first_unused_positive_id_checks_ordinary_grouped_and_uint32_max_shapes(self):
        group = (b'<p:grpSp><p:nvGrpSpPr><p:cNvPr id="4" name="group"/>'
            b'<p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>' + ordinary('3') + b'</p:grpSp>')
        part = slide_xml([ordinary('0002'), group, ordinary('4294967295')])
        result, _ = self.insert(part)
        self.assertEqual(result['shapeId'], '5', 'A sparse maximum ID must not cause allocation overflow')
        duplicate = slide_xml([ordinary('01')])
        self.rejected(duplicate)
        zero_group = slide_xml().replace(b'id="1"', b'id="0"', 1)
        result, _ = self.insert(zero_group)
        self.assertEqual(result['shapeId'], '1')

    def test_new_frame_is_inserted_before_last_extlst_without_touching_extension_bytes(self):
        extension = b'<p:extLst><p:ext uri="retained"><v:data xmlns:v="urn:opaque"/></p:ext></p:extLst>'
        part = slide_xml([ordinary('2')]).replace(b'</p:spTree>', extension + b'<!-- trailing comment -->\r\n</p:spTree>')
        result, _ = self.insert(part)
        self.assertEqual(result['insertionByte'], part.index(b'<p:extLst>'))
        self.assertIn(extension, result['partBytes'])

    def test_malformed_shape_tree_headers_extensions_and_trailing_shapes_reject(self):
        part = slide_xml()
        header_start, header_stop = part.index(b'<p:nvGrpSpPr>'), part.index(b'</p:nvGrpSpPr>') + len(b'</p:nvGrpSpPr>')
        header = part[header_start:header_stop]
        cases = [part[:header_start] + part[header_stop:],
            part.replace(header, header + header, 1), part.replace(b'<p:grpSpPr/>', b'', 1),
            part.replace(b'<p:grpSpPr/>', b'<p:grpSpPr/><p:grpSpPr/>', 1),
            part.replace(header + b'<p:grpSpPr/>', b'<p:grpSpPr/>' + header, 1),
            part.replace(b'</p:spTree>', b'<p:extLst/><p:extLst/></p:spTree>', 1),
            part.replace(b'</p:spTree>', b'<p:extLst/>' + ordinary('2') + b'</p:spTree>', 1)]
        for malformed in cases:
            with self.subTest(part=malformed):
                self.rejected(malformed)

    def test_closed_operation_rejects_unknown_missing_foreign_or_stale_fields(self):
        part = slide_xml()
        valid = operation(part)
        cases = [{**valid, 'unexpected': 1}, {**valid, 'shapeId': '2'},
            {**valid, 'sourcePart': SECOND}, {**valid, 'expectedSourcePartSha256': '0' * 64},
            {**valid, 'expectedSourcePartSha256': sha(part).upper()},
            {**valid, 'expectedSourcePartSha256': 1}]
        cases.extend({key: value for key, value in valid.items() if key != missing} for missing in valid)
        for supplied in cases:
            with self.subTest(supplied=supplied):
                self.rejected(part, supplied)

    def test_geometry_rejects_booleans_nonfinite_wrong_types_and_more_than_two_decimal_places(self):
        part = slide_xml()
        invalid_numbers = [True, False, float('nan'), float('inf'), -float('inf'), '1', None, .001, 1.234]
        for value in invalid_numbers:
            for field in ('xMm', 'yMm', 'columnWidthsMm', 'rowHeightsMm'):
                supplied = operation(part, **{field: [value] if field.endswith('sMm') else value})
                with self.subTest(field=field, value=value):
                    self.rejected(part, supplied)
        for field in ('columnWidthsMm', 'rowHeightsMm'):
            for value in ([], [0], [-1], [1000.01], [500, 500.01], (1, 2), 10, None):
                with self.subTest(field=field, value=value):
                    self.rejected(part, operation(part, **{field: value}))
        for field in ('xMm', 'yMm'):
            for value in (-1000.01, 1000.01):
                with self.subTest(field=field, value=value):
                    self.rejected(part, operation(part, **{field: value}))

    def test_geometry_boundaries_and_exact_hundredth_millimetres_are_allowed(self):
        result, table = self.insert(slide_xml(), operation(slide_xml(), xMm=-1000, yMm=1000,
            columnWidthsMm=[.01, 999.99], rowHeightsMm=[1000]))
        self.assertEqual(table['positionEmu'], {'x': -36000000, 'y': 36000000})
        self.assertEqual(table['columnWidthsEmu'], [360, 35999640])
        self.assertEqual(table['extentEmu'], {'width': 36000000, 'height': 36000000})

    def test_logical_cell_budget_accepts_100_and_rejects_101(self):
        part = slide_xml()
        _, table = self.insert(part, operation(part, columnWidthsMm=[1] * 10, rowHeightsMm=[1] * 10))
        self.assertEqual(len(table['cells']), 100)
        self.rejected(part, operation(part, columnWidthsMm=[1] * 101, rowHeightsMm=[1]))
        self.rejected(part, operation(part, columnWidthsMm=[1] * 11, rowHeightsMm=[1] * 10))

    def test_part_table_budget_accepts_20_and_rejects_21(self):
        part = slide_xml([grid_frame(str(index)) for index in range(2, 21)])
        result, _ = self.insert(part, operation(part, columnWidthsMm=[1], rowHeightsMm=[1]))
        self.assertEqual(len(tables(result['partBytes'])), 20)
        self.rejected(result['partBytes'], operation(result['partBytes'], columnWidthsMm=[1], rowHeightsMm=[1]))

    def test_source_part_must_be_immutable_bounded_valid_xml(self):
        self.rejected(bytearray(slide_xml()))
        self.rejected(b'<not-a-slide/>')
        self.rejected(slide_xml() + b'garbage')
        self.rejected(b'<!DOCTYPE p:sld [<!ENTITY x "bad">]>' + slide_xml())
        part = slide_xml().replace(b'</p:spTree>', b'<!--' + b'x' * source_reader.PART_BYTES + b'--></p:spTree>')
        self.rejected(part)


class PresentationStructurePackageTest(unittest.TestCase):
    def api(self):
        function = getattr(MODULE, 'add_tables_pptx', None)
        self.assertTrue(callable(function),
            'BOOTSTRAP: add_tables_pptx is absent; this is not package/native save evidence')
        return function

    @contextmanager
    def fixture(self, *, slides=None, streamed=False, compression=zipfile.ZIP_DEFLATED, signed=False):
        slides = {PART: slide_xml([frame_xml('9')])} if slides is None else slides
        names = list(slides)
        relations = [('rId' + str(index + 1), 'slides/' + name.rsplit('/', 1)[1], SLIDE, None)
            for index, name in enumerate(names)]
        members = package_members(slides, [entry[0] for entry in relations], relations)
        if signed:
            members.append(('_xmlsignatures/sig1.xml', b'<Signature/>'))
        with TemporaryDirectory(prefix='piv-ppt-structure-') as directory:
            source = Path(directory) / 'source.pptx'
            original = archive_bytes(members, streamed, compression)
            source.write_bytes(original)
            case = SimpleNamespace(source=source, destination=Path(directory) / 'candidate.pptx',
                original=original, sha=sha(original), parts=slides)
            try:
                yield case
            finally:
                self.assertEqual(source.read_bytes(), original, 'The immutable package input must remain exact')

    def invoke(self, case, supplied):
        return self.api()(case.source, case.destination, supplied, case.sha)

    def test_package_api_is_explicit(self):
        self.api()

    def test_empty_batch_is_a_byte_exact_package_noop(self):
        with self.fixture(streamed=True) as case:
            self.invoke(case, [])
            self.assertEqual(case.destination.read_bytes(), case.original)

    def test_only_target_slide_changes_and_every_unaffected_local_record_is_exact(self):
        for streamed, compression in ((False, zipfile.ZIP_DEFLATED), (True, zipfile.ZIP_DEFLATED),
                (False, zipfile.ZIP_STORED)):
            with self.subTest(streamed=streamed, compression=compression), self.fixture(
                    slides={PART: slide_xml([frame_xml('9')]), SECOND: slide_xml()},
                    streamed=streamed, compression=compression) as case:
                self.invoke(case, [operation(case.parts[PART])])
                candidate = case.destination.read_bytes()
                before, after = physical_records(case.original), physical_records(candidate)
                self.assertEqual(list(before), list(after))
                self.assertNotEqual(before[PART], after[PART])
                for member, record in before.items():
                    if member != PART:
                        self.assertEqual(after[member], record)
                with zipfile.ZipFile(case.destination) as archive:
                    self.assertIsNone(archive.testzip())
                    self.assertEqual(archive.read(SECOND), case.parts[SECOND])
                    self.assertEqual(len(tables(archive.read(PART))), 2)
                    self.assertTrue(all(item.compress_type == compression for item in archive.infolist()))
                for (name, original), (changed_name, current) in zip(central_records(case.original), central_records(candidate)):
                    self.assertEqual(changed_name, name)
                    if name == PART:
                        self.assertEqual(original[:16] + original[28:42] + original[46:],
                            current[:16] + current[28:42] + current[46:])
                    else:
                        self.assertEqual(original[:42] + original[46:], current[:42] + current[46:])

    def test_sequential_operations_require_the_current_part_hash_and_keep_distinct_new_ids(self):
        self.api()
        with self.fixture(slides={PART: slide_xml()}) as case:
            first = operation(case.parts[PART], columnWidthsMm=[1], rowHeightsMm=[1])
            first_result = getattr(MODULE, 'add_table_part')(case.parts[PART], PART, first)
            second = operation(first_result['partBytes'], columnWidthsMm=[2], rowHeightsMm=[2])
            self.invoke(case, [first, second])
            current = source_reader.read_pptx_tables(case.destination)
            self.assertEqual([table['shapeId'] for table in current['tables']], ['2', '3'])
        with self.fixture(slides={PART: slide_xml()}) as case:
            first = operation(case.parts[PART], columnWidthsMm=[1], rowHeightsMm=[1])
            with self.assertRaises(ValueError):
                self.invoke(case, [first, first])
            self.assertFalse(case.destination.exists())

    def test_package_hash_unknown_part_and_closed_operations_reject_before_output(self):
        for kind in ('package-hash', 'part-hash', 'part-name', 'unknown-field', 'too-many-operations', 'not-list'):
            with self.subTest(kind=kind), self.fixture() as case:
                supplied = operation(case.parts[PART])
                if kind == 'part-hash':
                    supplied['expectedSourcePartSha256'] = '0' * 64
                elif kind == 'part-name':
                    supplied['sourcePart'] = 'ppt/slides/missing.xml'
                elif kind == 'unknown-field':
                    supplied['extra'] = True
                batch = [supplied] * 101 if kind == 'too-many-operations' else [supplied]
                if kind == 'not-list':
                    batch = tuple(batch)
                with self.assertRaises(ValueError):
                    self.api()(case.source, case.destination, batch, '0' * 64 if kind == 'package-hash' else case.sha)
                self.assertFalse(case.destination.exists())

    def test_existing_destination_and_source_are_never_overwritten(self):
        with self.fixture() as case:
            case.destination.write_bytes(b'FOREIGN DESTINATION')
            with self.assertRaises((ValueError, FileExistsError)):
                self.invoke(case, [operation(case.parts[PART])])
            self.assertEqual(case.destination.read_bytes(), b'FOREIGN DESTINATION')
            with self.assertRaises((ValueError, FileExistsError)):
                self.api()(case.source, case.source, [operation(case.parts[PART])], case.sha)

    def test_signed_package_edit_rejects_without_publishing_candidate(self):
        with self.fixture(signed=True) as case:
            with self.assertRaises(ValueError):
                self.invoke(case, [operation(case.parts[PART])])
            self.assertFalse(case.destination.exists())

    def test_global_table_budget_is_checked_across_source_slides_before_and_after(self):
        for counts, batch in (((10, 10), True), ((11, 10), False)):
            slides = {PART: slide_xml([grid_frame(str(index + 2)) for index in range(counts[0])]),
                SECOND: slide_xml([grid_frame(str(index + 2)) for index in range(counts[1])])}
            with self.subTest(counts=counts), self.fixture(slides=slides) as case:
                operations = [operation(case.parts[PART], columnWidthsMm=[1], rowHeightsMm=[1])] if batch else []
                with self.assertRaises(ValueError):
                    self.invoke(case, operations)
                self.assertFalse(case.destination.exists())

    def test_global_cell_budget_is_checked_across_source_slides_before_and_after(self):
        for rows, columns, batch in (((6, 4), (10, 10), True), ((6, 5), (10, 10), False)):
            slides = {PART: slide_xml([grid_frame('2', rows[0], columns[0])]),
                SECOND: slide_xml([grid_frame('2', rows[1], columns[1])])}
            with self.subTest(rows=rows, columns=columns), self.fixture(slides=slides) as case:
                operations = [operation(case.parts[PART], columnWidthsMm=[1], rowHeightsMm=[1])] if batch else []
                with self.assertRaises(ValueError):
                    self.invoke(case, operations)
                self.assertFalse(case.destination.exists())

    def test_exact_global_cell_boundary_can_be_created_without_touching_source(self):
        with self.fixture(slides={PART: slide_xml()}) as case:
            self.invoke(case, [operation(case.parts[PART], columnWidthsMm=[1] * 10, rowHeightsMm=[1] * 10)])
            catalog = source_reader.read_pptx_tables(case.destination)
            self.assertEqual(sum(len(table['cells']) for table in catalog['tables']), 100)


if __name__ == '__main__':
    unittest.main()
