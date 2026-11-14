"""Pure request-derived XML text patches; root alone runs this suite."""
import copy
import hashlib
import importlib
import importlib.util
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace
import unittest

import office_presentation_source as source
from office_presentation_text_source import cell_text_map
from test_presentation_source import (
    frame_xml, package_members, slide_xml, table_xml, write_package,
)
from test_presentation_text_source import paragraph, run, source_cell


MODULE = (importlib.import_module('office_presentation_text_patch')
    if importlib.util.find_spec('office_presentation_text_patch') is not None
    else SimpleNamespace(patch_cell_text=None))


def sha(data):
    return hashlib.sha256(data).hexdigest()


class PresentationTextPatchTest(unittest.TestCase):
    def api(self):
        api = getattr(MODULE, 'patch_cell_text', None)
        self.assertTrue(callable(api),
            'BOOTSTRAP: patch_cell_text is absent; this is not patch/native/writer evidence')
        return api

    def fixture(self, cell, *, frames=None, index=0):
        other = source_cell(paragraph(run('<a:t>UNRELATED</a:t>')))
        if frames is None:
            frames = [frame_xml(table=table_xml([[cell, other], [other, other]]))]
        part = slide_xml(frames)
        with TemporaryDirectory(prefix='piv-ppt-text-patch-') as directory:
            path = Path(directory) / 'source.pptx'
            write_package(path, package_members({'ppt/slides/slide1.xml': part}))
            original = path.read_bytes()
            catalog = source.read_pptx_tables(path)
            self.assertEqual(path.read_bytes(), original)
        records = [item for table in catalog['tables'] for item in table['cells']]
        record = records[index]
        self.assertEqual(part[record['cellSpan'][0]:record['cellSpan'][1]], cell)
        return part, record

    def location(self, part, record, raw, text_index=0):
        left, right = record['textSpans'][text_index]
        start = part.index(raw, left, right)
        return start, start + len(raw)

    def checked(self, part, record, start, end, replacement, expected_text, patches):
        before = copy.deepcopy(record)
        original_text = cell_text_map(part, record)['text']
        result = self.api()(part, record, start, end, replacement,
            sha(original_text.encode('utf-8')))
        self.assertEqual(set(result), {'partBytes', 'text', 'textSha256',
            'sourcePartSha256', 'resultPartSha256', 'patches'})
        expected_patches = [{'startByte': left, 'endByte': right,
            'replacementBytes': data} for left, right, data in patches]
        self.assertEqual(result['patches'], expected_patches)
        chunks, cursor = [], 0
        for left, right, data in patches:
            self.assertTrue(cursor <= left <= right <= len(part))
            chunks.extend((part[cursor:left], data))
            cursor = right
        expected_bytes = b''.join(chunks) + part[cursor:]
        self.assertIs(type(result['partBytes']), bytes)
        self.assertEqual(result['partBytes'], expected_bytes,
            'The entire part must equal independently requested byte edits')
        self.assertEqual(result['text'], expected_text)
        self.assertEqual(result['textSha256'], sha(expected_text.encode('utf-8')))
        self.assertEqual(result['sourcePartSha256'], sha(part))
        self.assertEqual(result['resultPartSha256'], sha(expected_bytes))
        root = source._xml(expected_bytes, {'nodes': 0})
        candidates = [cell for table in source._slide(root, '') for cell in table['cells']
            if cell['cellSpan'][0] == record['cellSpan'][0]]
        self.assertEqual(len(candidates), 1)
        reparsed = candidates[0]
        self.assertEqual(cell_text_map(expected_bytes, reparsed)['text'], expected_text)
        for name in ('row', 'column', 'rowSpan', 'columnSpan', 'covered', 'anchor'):
            self.assertEqual(reparsed[name], record[name])
        self.assertEqual(record, before)
        return result

    def rejected(self, part, record, start, end, replacement, expected_sha=None):
        before = copy.deepcopy(record)
        if expected_sha is None:
            expected_sha = sha(cell_text_map(part, record)['text'].encode('utf-8'))
        with self.assertRaises(ValueError):
            self.api()(part, record, start, end, replacement, expected_sha)
        self.assertEqual(record, before)

    def test_patch_api_is_explicit(self):
        self.api()

    def test_literal_patch_preserves_all_tags_properties_unknown_attributes_and_other_cells(self):
        cell = source_cell(paragraph(run(
            '<a:t xml:space="preserve" kept="x > y">ABCDE</a:t>',
            '<a:rPr b="1" kumimoji="1"><a:solidFill><a:srgbClr val="AABBCC"/>'
            '</a:solidFill></a:rPr>'), '<a:pPr algn="r"/>'))
        part, record = self.fixture(cell)
        left, right = self.location(part, record, b'BCD')
        self.checked(part, record, 1, 4, 'Q"\'', 'AQ"\'E',
            [(left, right, b'Q"\'')])

    def test_entities_and_supplementary_scalars_use_whole_legal_raw_intervals(self):
        raw = 'A&amp;😀&#x1F600;éZ'.encode('utf-8')
        part, record = self.fixture(source_cell(paragraph(run(
            '<a:t>' + raw.decode('utf-8') + '</a:t>'))))
        left, right = self.location(part, record, '&amp;😀&#x1F600;'.encode('utf-8'))
        self.checked(part, record, 1, 6, '한<&>', 'A한<&>éZ',
            [(left, right, '한&lt;&amp;&gt;'.encode('utf-8'))])

    def test_duplicate_frames_and_equal_cell_text_keep_the_exact_selected_source_location(self):
        cell = source_cell(paragraph(run('<a:t>DUP</a:t>')))
        table = table_xml([[cell, cell], [cell, cell]])
        part, record = self.fixture(cell,
            frames=[frame_xml('9', table), frame_xml('10', table)], index=4)
        left, _ = self.location(part, record, b'DUP')
        result = self.checked(part, record, 0, 1, 'X', 'XUP',
            [(left, left + 1, b'X')])
        self.assertEqual(result['partBytes'].count(b'>DUP</a:t>'), 7)

    def test_multi_run_replacement_uses_first_selected_style_and_keeps_later_empty_runs(self):
        cell = source_cell(paragraph(
            run('<a:t>ABCD</a:t>', '<a:rPr b="1"/>') +
            run('<a:t>EFGH</a:t>', '<a:rPr i="1"/>')))
        part, record = self.fixture(cell)
        first = self.location(part, record, b'CD', 0)
        second = self.location(part, record, b'EF', 1)
        self.checked(part, record, 2, 6, 'XYZ', 'ABXYZGH',
            [(*first, b'XYZ'), (*second, b'')])
        all_first = self.location(part, record, b'ABCD', 0)
        all_second = self.location(part, record, b'EFGH', 1)
        self.checked(part, record, 0, 8, 'N', 'N',
            [(*all_first, b'N'), (*all_second, b'')])

    def test_selection_across_comment_and_pi_fragments_preserves_their_exact_bytes(self):
        cell = source_cell(paragraph(run(
            '<a:t>A<!--kept 😀--><?retain p?>B<!--end-->C</a:t>')))
        part, record = self.fixture(cell)
        positions = [self.location(part, record, raw) for raw in (b'>A', b'?>B', b'-->C')]
        patches = [(positions[0][0] + 1, positions[0][1], b'XY'),
            (positions[1][1] - 1, positions[1][1], b''),
            (positions[2][1] - 1, positions[2][1], b'')]
        self.checked(part, record, 0, 3, 'XY', 'XY', patches)

    def test_insertion_at_shared_run_boundary_has_left_affinity(self):
        part, record = self.fixture(source_cell(paragraph(
            run('<a:t>AB</a:t>', '<a:rPr b="1"/>') +
            run('<a:t>CD</a:t>', '<a:rPr i="1"/>'))))
        _, offset = self.location(part, record, b'AB', 0)
        self.checked(part, record, 2, 2, 'X', 'ABXCD', [(offset, offset, b'X')])

    def test_insertion_at_comment_split_chooses_left_content_boundary(self):
        part, record = self.fixture(source_cell(paragraph(run(
            '<a:t>AB<!--keep--><?keep q?>CD</a:t>'))))
        _, offset = self.location(part, record, b'AB')
        self.checked(part, record, 2, 2, 'X', 'ABXCD', [(offset, offset, b'X')])

    def test_insertion_into_paired_empty_and_at_cell_edges_uses_existing_content_only(self):
        for text, position in (('', 0), ('ABC', 0), ('ABC', 3)):
            with self.subTest(text=text, position=position):
                part, record = self.fixture(source_cell(paragraph(run(
                    '<a:t>' + text + '</a:t>'))))
                offset = record['textSpans'][0][0] + len(b'<a:t>') + position
                expected = text[:position] + 'X' + text[position:]
                self.checked(part, record, position, position, 'X', expected,
                    [(offset, offset, b'X')])

    def test_semantic_noop_keeps_entity_spelling_run_distribution_and_identical_part(self):
        part, record = self.fixture(source_cell(paragraph(
            run('<a:t>A&#65;</a:t>') + run('<a:t>&amp;</a:t>'))))
        self.checked(part, record, 1, 3, 'A&', 'AA&', [])
        self.checked(part, record, 1, 1, '', 'AA&', [])

    def test_newline_tab_and_semantic_cr_have_exact_xml_source_encoding(self):
        part, record = self.fixture(source_cell(paragraph(run('<a:t>AB</a:t>'))))
        left, right = self.location(part, record, b'B')
        self.checked(part, record, 1, 2, '\n\t\r\n', 'A\n\t\r\n',
            [(left, right, b'\n\t&#13;\n')])

    def test_safe_cdata_replacement_preserves_original_delimiters(self):
        part, record = self.fixture(source_cell(paragraph(run(
            '<a:t>A<![CDATA[BC]]>D</a:t>'))))
        left, right = self.location(part, record, b'BC')
        replacement = '😀<&\n\t'
        self.checked(part, record, 1, 3, replacement, 'A' + replacement + 'D',
            [(left, right, replacement.encode('utf-8'))])

    def test_unsupported_cdata_terminator_and_cr_are_explicitly_rejected(self):
        part, record = self.fixture(source_cell(paragraph(run(
            '<a:t>A<![CDATA[B]]>C</a:t>'))))
        for replacement in (']]>', 'x]]>y', '\r', 'x\r\ny'):
            with self.subTest(replacement=repr(replacement)):
                self.rejected(part, record, 1, 2, replacement)

    def test_normal_text_destination_can_delete_later_cdata_fragment_without_touching_delimiters(self):
        part, record = self.fixture(source_cell(paragraph(run(
            '<a:t>A<![CDATA[BC]]>D</a:t>'))))
        first = self.location(part, record, b'>A')
        second = self.location(part, record, b'BC')
        self.checked(part, record, 0, 3, '\r<&]]>', '\r<&]]>D',
            [(first[0] + 1, first[1], b'&#13;&lt;&amp;]]&gt;'), (*second, b'')])

    def test_fields_hyperlinks_linebreaks_and_paragraph_boundaries_reject_selected_or_inserted_edits(self):
        field = '<a:fld id="f" type="slidenum"><a:rPr/><a:t>F</a:t></a:fld>'
        hyperlink = run('<a:t>F</a:t>', '<a:rPr><a:hlinkClick r:id="rId1"/></a:rPr>')
        cases = [
            paragraph(run('<a:t>A</a:t>') + field + run('<a:t>Z</a:t>')),
            paragraph(run('<a:t>A</a:t>') + hyperlink + run('<a:t>Z</a:t>')),
            paragraph(run('<a:t>A</a:t>') + '<a:br/>' + run('<a:t>Z</a:t>')),
            paragraph(run('<a:t>A</a:t>')) + paragraph(run('<a:t>Z</a:t>')),
        ]
        for index, body in enumerate(cases):
            with self.subTest(kind=index):
                part, record = self.fixture(source_cell(body))
                self.rejected(part, record, 0, 3, 'X')
                self.rejected(part, record, 1, 2, 'X')
                self.rejected(part, record, 1, 1, 'X')
                self.rejected(part, record, 2, 2, 'X')

    def test_ordinary_selection_can_end_before_protected_content_without_widening(self):
        field = '<a:fld id="f" type="slidenum"><a:t>F</a:t></a:fld>'
        part, record = self.fixture(source_cell(paragraph(
            run('<a:t>A</a:t>') + field + run('<a:t>Z</a:t>'))))
        left, right = self.location(part, record, b'A', 0)
        self.checked(part, record, 0, 1, 'B', 'BFZ', [(left, right, b'B')])

    def test_covered_cells_selfclosing_text_and_absent_text_do_not_gain_insertion_rights(self):
        covered = source_cell(paragraph(run('<a:t>COVERED</a:t>'))).replace(
            b'<a:tc>', b'<a:tc hMerge="1">', 1)
        anchor = source_cell(paragraph(run('<a:t>ANCHOR</a:t>'))).replace(
            b'<a:tc>', b'<a:tc gridSpan="2">', 1)
        plain = source_cell(paragraph(run('<a:t>OTHER</a:t>')))
        table = table_xml([[anchor, covered], [plain, plain]])
        part, record = self.fixture(covered, frames=[frame_xml(table=table)], index=1)
        self.rejected(part, record, 0, 1, 'X')
        for body in (paragraph(run('<a:t/>')), paragraph(run('', '<a:rPr/>')),
                paragraph(), paragraph(run('<a:t><!--only--></a:t>'))):
            with self.subTest(body=body):
                part, record = self.fixture(source_cell(body))
                self.rejected(part, record, 0, 0, 'X')

    def test_invalid_types_ranges_and_stale_text_hash_are_rejected_before_patching(self):
        part, record = self.fixture(source_cell(paragraph(run('<a:t>ABC</a:t>'))))
        expected = sha(b'ABC')
        for start, end in ((True, 1), (0, False), (-1, 1), (2, 1), (0, 4),
                (0.0, 1), ('0', 1)):
            with self.subTest(start=start, end=end):
                self.rejected(part, record, start, end, 'X', expected)
        for replacement in (None, b'X', 1):
            with self.subTest(replacement=repr(replacement)):
                self.rejected(part, record, 0, 1, replacement, expected)
        for value in ('0' * 64, expected.upper(), '', None, b'a' * 64):
            with self.subTest(expected_hash=repr(value)):
                with self.assertRaises(ValueError):
                    self.api()(part, record, 0, 1, 'X', value)

    def test_surrogate_midpoints_and_xml10_forbidden_replacement_scalars_are_rejected(self):
        part, record = self.fixture(source_cell(paragraph(run('<a:t>A😀B</a:t>'))))
        for start, end in ((2, 2), (1, 2), (2, 3)):
            with self.subTest(start=start, end=end):
                self.rejected(part, record, start, end, 'X')
        for replacement in ('\x00', '\x01', '\x0b', '\ud800', '\udfff', '\ufffe', '\uffff'):
            with self.subTest(replacement=repr(replacement)):
                self.rejected(part, record, 1, 3, replacement)

    def test_forged_reader_record_and_invalid_complete_part_are_rejected(self):
        part, record = self.fixture(source_cell(paragraph(run('<a:t>ABC</a:t>'))))
        expected = sha(b'ABC')
        bad = copy.deepcopy(record)
        bad['column'] = 1
        self.rejected(part, bad, 0, 1, 'X', expected)
        self.rejected(part + b'<other/>', record, 0, 1, 'X', expected)
        for data in (bytearray(part), memoryview(part), 'xml'):
            with self.subTest(part_type=type(data).__name__):
                self.rejected(data, record, 0, 1, 'X', expected)

    def test_replacement_and_result_utf16_budgets_reject_without_partial_output(self):
        part, record = self.fixture(source_cell(paragraph(run('<a:t>A</a:t>'))))
        self.rejected(part, record, 0, 1, 'A' * 131073)
        self.rejected(part, record, 0, 1, '😀' * 65537)
        part, record = self.fixture(source_cell(paragraph(run(
            '<a:t>' + 'A' * 131072 + '</a:t>'))))
        self.rejected(part, record, 0, 0, 'X')


if __name__ == '__main__':
    unittest.main()
