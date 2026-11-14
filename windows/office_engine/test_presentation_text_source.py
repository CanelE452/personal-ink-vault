"""Pure source text-to-byte maps; root alone executes these tests.

Missing production API yields an explicit bootstrap assertion. No writer,
native object binding, or edit authority is established by this suite.
"""
from copy import deepcopy
import importlib
import importlib.util
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace
import unittest

from office_presentation_source import read_pptx_tables
from test_presentation_source import (
    frame_xml, package_members, slide_xml, table_xml, write_package,
)


MODULE = (importlib.import_module('office_presentation_text_source')
    if importlib.util.find_spec('office_presentation_text_source') is not None
    else SimpleNamespace(cell_text_map=None))


def source_cell(paragraphs, drawing='a'):
    return ('<' + drawing + ':tc><' + drawing + ':txBody><' + drawing + ':bodyPr/>'
        '<' + drawing + ':lstStyle/>' + paragraphs + '</' + drawing + ':txBody>'
        '<' + drawing + ':tcPr marL="123"><' + drawing + ':solidFill>'
        '<' + drawing + ':srgbClr val="102030"/></' + drawing + ':solidFill>'
        '</' + drawing + ':tcPr></' + drawing + ':tc>').encode('utf-8')


def paragraph(contents='', properties='', drawing='a'):
    return '<' + drawing + ':p>' + properties + contents + '<' + drawing + \
        ':endParaRPr lang="ko-KR"/></' + drawing + ':p>'


def run(text, properties='<a:rPr lang="ko-KR" b="1"/>', drawing='a'):
    return '<' + drawing + ':r>' + properties + text + '</' + drawing + ':r>'


class PresentationSourceTextMapTest(unittest.TestCase):
    def mapper(self):
        api = getattr(MODULE, 'cell_text_map', None)
        self.assertTrue(callable(api),
            'BOOTSTRAP: office_presentation_text_source.cell_text_map is absent; '
            'this is not text parsing or write-authority evidence')
        return api

    def verified(self, cell, drawing='a', frames=None):
        filler = source_cell(paragraph(run('<a:t>OTHER</a:t>')))
        table = table_xml([[cell, filler], [filler, filler]], drawing=drawing)
        xml = slide_xml([frame_xml(table=table, drawing=drawing)] if frames is None else frames,
            drawing=drawing)
        with TemporaryDirectory(prefix='piv-ppt-text-map-') as directory:
            source = Path(directory) / 'original.pptx'
            write_package(source, package_members({'ppt/slides/slide1.xml': xml}))
            original, modified = source.read_bytes(), source.stat().st_mtime_ns
            catalog = read_pptx_tables(source)
            self.assertEqual(source.read_bytes(), original)
            self.assertEqual(source.stat().st_mtime_ns, modified)
            self.assertEqual(list(Path(directory).iterdir()), [source])
        part = catalog['parts']['ppt/slides/slide1.xml']
        record = catalog['tables'][0]['cells'][0]
        self.assertEqual(part[record['cellSpan'][0]:record['cellSpan'][1]], cell)
        return part, record

    def mapped(self, cell, drawing='a'):
        part, record = self.verified(cell, drawing)
        before = deepcopy(record)
        result = self.mapper()(part, record)
        self.assertEqual(record, before, 'The reader-owned record must remain unchanged')
        self.assertEqual(result['cellSpan'], record['cellSpan'])
        self.assertEqual(result['utf16Length'],
            len(result['text'].encode('utf-16-le')) // 2)
        self.assertIsInstance(result['segments'], list)
        self.assertIsInstance(result['protectedRanges'], list)
        self.assertFalse(any(name in result for name in
            ('canEditText', 'canReplace', 'authority', 'tableSha256')),
            'A source-only map cannot issue native/package/write authority')
        return part, record, result

    def assert_content(self, part, segment, raw, tokens, start_utf16=0,
            lexical='text', editable=True, reason=None):
        start, end = segment['sourceSpan']
        self.assertEqual(part[start:end], raw)
        self.assertEqual(segment['kind'], 'text')
        self.assertEqual(segment['lexicalKind'], lexical)
        self.assertEqual(segment['editable'], editable)
        self.assertEqual(segment['protectedReason'], reason)
        text = ''.join(semantic for semantic, _ in tokens)
        self.assertEqual(segment['text'], text)
        self.assertEqual(segment['startUtf16'], start_utf16)
        byte_offset, utf16_offset = start, start_utf16
        expected = [[utf16_offset, byte_offset]]
        for semantic, source in tokens:
            byte_offset += len(source)
            utf16_offset += len(semantic.encode('utf-16-le')) // 2
            expected.append([utf16_offset, byte_offset])
        self.assertEqual(byte_offset, end)
        self.assertEqual(segment['endUtf16'], utf16_offset)
        self.assertEqual(segment['boundaries'], expected)
        for name in ('paragraphSpan', 'runSpan', 'textSpan'):
            outer_start, outer_end = segment[name]
            self.assertTrue(outer_start <= start <= end <= outer_end)

    def test_cell_text_map_api_is_explicit(self):
        self.mapper()

    def test_literals_named_numeric_entities_and_surrogate_boundaries_are_exact(self):
        raw = 'A&amp;&lt;&gt;&quot;&apos;&#65;&#x1F600;😀é한'.encode('utf-8')
        cell = source_cell(paragraph(run('<a:t xml:space="preserve">' +
            raw.decode('utf-8') + '</a:t>')))
        part, record, result = self.mapped(cell)
        self.assertEqual(result['text'], 'A&<>"\'A😀😀é한')
        self.assertEqual(len(result['segments']), 1)
        tokens = [('A', b'A'), ('&', b'&amp;'), ('<', b'&lt;'), ('>', b'&gt;'),
            ('"', b'&quot;'), ("'", b'&apos;'), ('A', b'&#65;'),
            ('😀', b'&#x1F600;'), ('😀', '😀'.encode('utf-8')),
            ('e', b'e'), ('́', '́'.encode('utf-8')), ('한', '한'.encode('utf-8'))]
        self.assert_content(part, result['segments'][0], raw, tokens)
        segment = result['segments'][0]
        self.assertEqual(segment['textSpan'], record['textSpans'][0])
        self.assertEqual((segment['paragraphIndex'], segment['runIndex']), (0, 0))
        self.assertEqual(result['protectedRanges'], [])

    def test_xml_crlf_cr_and_numeric_cr_have_distinct_legal_raw_boundaries(self):
        raw = b'A\r\nB\rC&#13;&#xD;&#10;\nZ'
        part, _, result = self.mapped(source_cell(paragraph(run(
            '<a:t>' + raw.decode('ascii') + '</a:t>'))))
        self.assertEqual(result['text'], 'A\nB\nC\r\r\n\nZ')
        self.assert_content(part, result['segments'][0], raw,
            [('A', b'A'), ('\n', b'\r\n'), ('B', b'B'), ('\n', b'\r'),
             ('C', b'C'), ('\r', b'&#13;'), ('\r', b'&#xD;'),
             ('\n', b'&#10;'), ('\n', b'\n'), ('Z', b'Z')])

    def test_cdata_comments_and_pi_split_exact_content_without_widening(self):
        middle = 'B\r\n😀<&'.encode('utf-8')
        text_xml = '<a:t>A<![CDATA[' + middle.decode('utf-8') + \
            ']]><!--retained > 😀--><?kept preserve?>C</a:t>'
        part, record, result = self.mapped(source_cell(paragraph(run(text_xml))))
        self.assertEqual(result['text'], 'AB\n😀<&C')
        self.assertEqual(len(result['segments']), 3)
        self.assert_content(part, result['segments'][0], b'A', [('A', b'A')])
        self.assert_content(part, result['segments'][1], middle,
            [('B', b'B'), ('\n', b'\r\n'), ('😀', '😀'.encode('utf-8')),
             ('<', b'<'), ('&', b'&')], start_utf16=1, lexical='cdata')
        self.assert_content(part, result['segments'][2], b'C', [('C', b'C')],
            start_utf16=7)
        protected = result['protectedRanges']
        self.assertEqual([item['reason'] for item in protected],
            ['comment', 'processingInstruction'])
        self.assertEqual([part[item['sourceSpan'][0]:item['sourceSpan'][1]]
            for item in protected], ['<!--retained > 😀-->'.encode('utf-8'),
                b'<?kept preserve?>'])
        self.assertEqual([(item['startUtf16'], item['endUtf16'])
            for item in protected], [(7, 7), (7, 7)])
        for segment in result['segments']:
            self.assertEqual(segment['textSpan'], record['textSpans'][0])
            data_start, data_end = segment['sourceSpan']
            for item in protected:
                protected_start, protected_end = item['sourceSpan']
                self.assertTrue(data_end <= protected_start or protected_end <= data_start)

    def test_identical_runs_keep_separate_locations_and_property_ownership(self):
        first = run('<a:t>SAME</a:t>', '<a:rPr b="1"><a:solidFill>'
            '<a:srgbClr val="AABBCC"/></a:solidFill></a:rPr>')
        second = run('<a:t>SAME</a:t>', '<a:rPr i="1"/>')
        cell = source_cell(paragraph(first + second, '<a:pPr algn="r"/>'))
        part, record, result = self.mapped(cell)
        self.assertEqual(result['text'], 'SAMESAME')
        self.assertEqual(len(result['segments']), 2)
        one, two = result['segments']
        self.assert_content(part, one, b'SAME', [(x, x.encode()) for x in 'SAME'])
        self.assert_content(part, two, b'SAME', [(x, x.encode()) for x in 'SAME'],
            start_utf16=4)
        self.assertEqual([one['textSpan'], two['textSpan']], record['textSpans'])
        self.assertNotEqual(one['runSpan'], two['runSpan'])
        self.assertEqual(one['paragraphSpan'], two['paragraphSpan'])
        self.assertEqual([one['runIndex'], two['runIndex']], [0, 1])
        for segment in result['segments']:
            raw = part[segment['sourceSpan'][0]:segment['sourceSpan'][1]]
            self.assertNotIn(b'rPr', raw)
            self.assertNotIn(b'pPr', raw)
        self.assertEqual(part[record['cellSpan'][0]:record['cellSpan'][1]], cell)

    def test_paired_empty_selfclosing_absent_text_and_empty_paragraphs_are_distinct(self):
        cell = source_cell(paragraph(run('<a:t></a:t>')) +
            paragraph() + paragraph(run('<a:t/>')) +
            paragraph(run('', '<a:rPr/>')))
        part, _, result = self.mapped(cell)
        self.assertEqual(result['text'], '\n\n\n')
        texts = [item for item in result['segments'] if item['kind'] == 'text']
        breaks = [item for item in result['segments'] if item['kind'] == 'paragraphBreak']
        self.assertEqual(len(texts), 2, 'An absent a:t has no synthesized insertion point')
        self.assertEqual(len(breaks), 3)
        self.assert_content(part, texts[0], b'', [], start_utf16=0)
        self.assertEqual((texts[0]['paragraphIndex'], texts[0]['runIndex']), (0, 0))
        self.assertEqual(texts[1]['text'], '')
        self.assertEqual((texts[1]['startUtf16'], texts[1]['endUtf16']), (2, 2))
        self.assertIsNone(texts[1]['sourceSpan'])
        self.assertEqual(texts[1]['boundaries'], [])
        self.assertFalse(texts[1]['editable'])
        self.assertEqual(texts[1]['protectedReason'], 'selfClosingText')
        for item in breaks:
            self.assertEqual(item['text'], '\n')
            self.assertIsNone(item['sourceSpan'])
            self.assertEqual(item['boundaries'], [])
            self.assertFalse(item['editable'])
            self.assertEqual(item['protectedReason'], 'paragraphBoundary')

    def test_line_break_is_structural_protected_text_with_exact_xml_interval(self):
        br = '<a:br><a:rPr lang="en-US"/></a:br>'
        part, _, result = self.mapped(source_cell(paragraph(
            run('<a:t>BEFORE</a:t>') + br + run('<a:t>AFTER</a:t>'))))
        self.assertEqual(result['text'], 'BEFORE\nAFTER')
        self.assertEqual([item['kind'] for item in result['segments']],
            ['text', 'lineBreak', 'text'])
        item = result['segments'][1]
        self.assertEqual(part[item['sourceSpan'][0]:item['sourceSpan'][1]], br.encode())
        self.assertEqual((item['startUtf16'], item['endUtf16']), (6, 7))
        self.assertEqual(item['boundaries'], [])
        self.assertFalse(item['editable'])
        self.assertEqual(item['protectedReason'], 'lineBreak')
        self.assert_content(part, result['segments'][2], b'AFTER',
            [(x, x.encode()) for x in 'AFTER'], start_utf16=7)

    def test_field_visible_text_and_entire_field_boundary_remain_protected(self):
        field = '<a:fld id="{12345678-1234-1234-1234-123456789012}" type="slidenum">' \
            '<a:rPr lang="en-US"/><a:pPr/><a:t>12&#51;</a:t></a:fld>'
        part, _, result = self.mapped(source_cell(paragraph(
            run('<a:t>A</a:t>') + field + run('<a:t>Z</a:t>'))))
        self.assertEqual(result['text'], 'A123Z')
        self.assert_content(part, result['segments'][1], b'12&#51;',
            [('1', b'1'), ('2', b'2'), ('3', b'&#51;')], start_utf16=1,
            editable=False, reason='field')
        protected = [item for item in result['protectedRanges'] if item['reason'] == 'field']
        self.assertEqual(len(protected), 1)
        self.assertEqual(part[protected[0]['sourceSpan'][0]:protected[0]['sourceSpan'][1]],
            field.encode())
        self.assertEqual((protected[0]['startUtf16'], protected[0]['endUtf16']), (1, 4))

    def test_click_and_mouseover_hyperlink_run_boundaries_remain_protected(self):
        for hyperlink in ('hlinkClick', 'hlinkMouseOver'):
            with self.subTest(hyperlink=hyperlink):
                linked = run('<a:t>LINK</a:t>', '<a:rPr><a:' + hyperlink +
                    ' r:id="rId55" action="ppaction://hlinksldjump"/></a:rPr>')
                part, _, result = self.mapped(source_cell(paragraph(linked +
                    run('<a:t>PLAIN</a:t>'))))
                self.assertEqual(result['text'], 'LINKPLAIN')
                self.assert_content(part, result['segments'][0], b'LINK',
                    [(x, x.encode()) for x in 'LINK'], editable=False, reason='hyperlink')
                self.assertTrue(result['segments'][1]['editable'])
                protected = [item for item in result['protectedRanges']
                    if item['reason'] == 'hyperlink']
                self.assertEqual(len(protected), 1)
                self.assertEqual(part[protected[0]['sourceSpan'][0]:protected[0]['sourceSpan'][1]],
                    linked.encode())

    def test_inherited_hyperlink_defaults_are_explicitly_unsupported(self):
        mapper = self.mapper()
        for hyperlink in ('hlinkClick', 'hlinkMouseOver'):
            default = '<a:defRPr><a:' + hyperlink + \
                ' r:id="rId55"/></a:defRPr>'
            for style in ('paragraph', 'defPPr', 'lvl1pPr', 'lvl9pPr'):
                with self.subTest(hyperlink=hyperlink, style=style):
                    contents = paragraph(run('<a:t>LINK</a:t>', properties=''),
                        '<a:pPr>' + default + '</a:pPr>' if style == 'paragraph' else '')
                    cell = source_cell(contents)
                    if style != 'paragraph':
                        cell = cell.replace(b'<a:lstStyle/>',
                            ('<a:lstStyle><a:' + style + '>' + default +
                                '</a:' + style + '></a:lstStyle>').encode('utf-8'))
                    part, record = self.verified(cell)
                    with self.assertRaises(ValueError):
                        mapper(part, record)

    def test_namespace_prefixes_do_not_determine_text_identity(self):
        cell = source_cell(paragraph(run('<d:t>한&#x1F600;</d:t>',
            '<d:rPr/>', drawing='d'), drawing='d'), drawing='d')
        # All helper-produced filler cells must use the same bound drawing prefix.
        filler = cell
        table = table_xml([[cell, filler], [filler, filler]], drawing='d')
        frames = [frame_xml(table=table, drawing='d')]
        part, record = self.verified(cell, drawing='d', frames=frames)
        result = self.mapper()(part, record)
        self.assertEqual(result['text'], '한😀')
        self.assert_content(part, result['segments'][0], '한&#x1F600;'.encode('utf-8'),
            [('한', '한'.encode('utf-8')), ('😀', b'&#x1F600;')])

    def test_complete_reader_record_is_required_with_exact_types_and_topology(self):
        part, record = self.verified(source_cell(paragraph(run('<a:t>TEXT</a:t>'))))
        mapper = self.mapper()
        cases = []
        for key in record:
            bad = deepcopy(record)
            del bad[key]
            cases.append(('missing-' + key, bad))
        for key, value in (
            ('row', True), ('row', -1), ('row', 1), ('column', 1),
            ('rowSpan', 2), ('columnSpan', 2), ('covered', True),
            ('covered', 0), ('anchor', {'row': 0, 'column': 0}),
            ('cellSpan', (True, record['cellSpan'][1])),
            ('cellSpan', (-1, record['cellSpan'][1])),
            ('cellSpan', (record['cellSpan'][0], len(part) + 1)),
            ('cellSpan', (record['cellSpan'][0] + 1, record['cellSpan'][1])),
            ('textSpans', []),
            ('textSpans', [(record['textSpans'][0][0] + 1, record['textSpans'][0][1])]),
            ('textSpans', [record['textSpans'][0], record['textSpans'][0]]),
        ):
            bad = deepcopy(record)
            bad[key] = value
            cases.append(('changed-' + key + '-' + repr(value), bad))
        bad = deepcopy(record)
        bad['unknownAuthority'] = True
        cases.append(('extra-key', bad))
        for label, bad in cases:
            with self.subTest(label=label):
                with self.assertRaises(ValueError):
                    mapper(part, bad)
        self.assertEqual(mapper(part, record)['text'], 'TEXT')

    def test_another_valid_cell_record_cannot_reuse_selected_cell_spans(self):
        selected = source_cell(paragraph(run('<a:t>SAME</a:t>')))
        other = source_cell(paragraph(run('<a:t>SAME</a:t>')))
        table = table_xml([[selected, other], [selected, other]])
        part, record = self.verified(selected, frames=[frame_xml(table=table)])
        bad = deepcopy(record)
        bad['column'] = 1
        with self.assertRaises(ValueError):
            self.mapper()(part, bad)

    def test_entire_part_is_strictly_reparsed_instead_of_isolated_cell_only(self):
        part, record = self.verified(source_cell(paragraph(run('<a:t>TEXT</a:t>'))))
        mapper = self.mapper()
        invalid = [
            part + b'<duplicate/>',
            part.replace(b'</p:sld>', b'<broken></p:sld>'),
            part.replace(b'id="1" name=""', b'id="9" name=""', 1),
            b'<!DOCTYPE p:sld [<!ENTITY custom "TEXT">]>' + part,
            part.replace(b'<?xml version="1.0"', b'<?xml version="1.1"', 1),
            part[:record['cellSpan'][0]] + b'\xff' + part[record['cellSpan'][0] + 1:],
        ]
        for index, xml in enumerate(invalid):
            with self.subTest(case=index):
                with self.assertRaises(ValueError):
                    mapper(xml, record)
        for data in (None, 'text', bytearray(part), memoryview(part)):
            with self.subTest(input_type=type(data).__name__):
                with self.assertRaises(ValueError):
                    mapper(data, record)

    def test_unknown_or_ambiguous_paragraph_run_text_grammar_is_rejected(self):
        unsupported = [
            paragraph('<a:tab/>'),
            paragraph(run('<a:t>A</a:t><a:t>B</a:t>')),
            paragraph(run('<a:t>A</a:t>', '<a:rPr/><a:rPr/>')),
            paragraph(run('<a:t>A</a:t><a:unknown/>')),
            paragraph(run('<a:t>A</a:t>'), '<a:pPr/><a:pPr/>'),
            '<a:p><a:r><a:t>A</a:t></a:r><a:endParaRPr/><a:endParaRPr/></a:p>',
            '<a:p><a:r><a:t>A</a:t></a:r><a:rPr/></a:p>',
        ]
        mapper = self.mapper()
        for index, body in enumerate(unsupported):
            with self.subTest(case=index):
                part, record = self.verified(source_cell(body))
                with self.assertRaises(ValueError):
                    mapper(part, record)

    def test_protected_range_budget_is_independent_of_text_and_segment_budgets(self):
        retained = '<!--kept--><?keep value?>' * 2048
        mapper = self.mapper()
        part, record = self.verified(source_cell(paragraph(run(
            '<a:t>A' + retained + 'B</a:t>'))))
        result = mapper(part, record)
        self.assertEqual(result['text'], 'AB')
        self.assertEqual(result['utf16Length'], 2)
        self.assertEqual(len(result['segments']), 2)
        self.assertEqual(len(result['protectedRanges']), 4096)
        part, record = self.verified(source_cell(paragraph(run(
            '<a:t>A' + retained + '<!--overflow-->B</a:t>'))))
        with self.assertRaises(ValueError):
            mapper(part, record)

    def test_utf16_and_segment_budgets_fail_without_partial_or_silent_truncation(self):
        mapper = self.mapper()
        for label, body in (
            ('utf16-literal', paragraph(run('<a:t>' + 'A' * 131073 + '</a:t>'))),
            ('utf16-surrogates', paragraph(run('<a:t>' + '😀' * 65537 + '</a:t>'))),
            ('segments', paragraph(run('<a:t/>') * 4097)),
        ):
            with self.subTest(label=label):
                part, record = self.verified(source_cell(body))
                with self.assertRaises(ValueError):
                    mapper(part, record)
        part, record = self.verified(source_cell(paragraph(run(
            '<a:t>' + 'A' * 131072 + '</a:t>'))))
        result = mapper(part, record)
        self.assertEqual(result['utf16Length'], 131072)
        self.assertEqual(result['text'], 'A' * 131072)


if __name__ == '__main__':
    unittest.main()
