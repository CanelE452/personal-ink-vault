"""Owned DOCX inline-spacing presence contract; root alone executes tests.

Only exact one-shot generated bookmark names authorize a patch. These fixtures
exercise package bytes and XML semantics, not image names or image hashes.
Observed inline-effects1 case C restores native LR319 by removing distL/distR;
no arbitrary native-distance-to-EMU conversion is part of this contract.
"""
from pathlib import Path
import re
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch
import warnings
import xml.etree.ElementTree as ET
import zipfile

from office_word_export import restore_inline_spacing


W = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main'
WP = 'http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing'
R = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
A = 'http://schemas.openxmlformats.org/drawingml/2006/main'
MARKER_A = 'PIV_11111111111141118111111111111111'
MARKER_B = 'PIV_22222222222242228222222222222222'
AUTHORED = MARKER_A[:-1] + '3'
MARGINS = {'LeftMargin': 319, 'RightMargin': 319, 'TopMargin': 0, 'BottomMargin': 0}
OTHER_MEMBERS = {
    '[Content_Types].xml': b'<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>',
    'word/media/image1.png': b'UNCHANGED SAME IMAGE PAYLOAD\x00\xff',
    'word/_rels/document.xml.rels': b'<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"/>',
    'docProps/core.xml': '<core>바이트 그대로 😀 e\u0301</core>'.encode('utf-8'),
}


def inline(wp='wp', distances=True, qualified=False):
    attrs = ' distL="0" distR=\'0\' distT="0" distB=\'0\'' if distances else ''
    if qualified:
        attrs += ' other:distL="777"'
    start = '<' + wp + ':inline' + attrs + ' data-preserve="quoted &gt; > stays">'
    body = '<' + wp + ':extent cx="972360" cy="684000"/><a:graphic><a:blip r:embed="rIdSameImage"/></a:graphic>'
    return (start + body + '</' + wp + ':inline>').encode('utf-8')


def bookmark(name, identifier, word='w'):
    start = ('<' + word + ':bookmarkStart ' + word + ':id="' + identifier + '" ' + word + ':name="' + name + '"/>').encode('utf-8')
    end = ('<' + word + ':bookmarkEnd ' + word + ':id="' + identifier + '"/>').encode('utf-8')
    return start, end


def document(fragments, word='w', wp='wp'):
    start = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
        '<' + word + ':document xmlns:' + word + '="' + W + '" xmlns:' + wp + '="' + WP + '" '
        'xmlns:r="' + R + '" xmlns:a="' + A + '" '
        'xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" '
        'xmlns:w14="http://schemas.microsoft.com/office/word/2010/wordml" '
        'xmlns:other="urn:keep-attribute" mc:Ignorable="w14"><' + word + ':body>\n'
        '<' + word + ':p><' + word + ':r><' + word + ':t xml:space="preserve">'
        '한글 😀 e\u0301 &amp; retained &gt; </' + word + ':t></' + word + ':r></' + word + ':p>\n'
        '<' + word + ':p>').encode('utf-8')
    end = ('</' + word + ':p>\n</' + word + ':body></' + word + ':document>').encode('utf-8')
    return start + b''.join(fragments) + end


def fixture(markers=(MARKER_A,), word='w', wp='wp', distances=True, qualified=False):
    fragments, tags = [], []
    for index, name in enumerate(markers):
        start, end = bookmark(name, str(100 + index), word)
        fragments.extend([start, inline(wp, distances, qualified), end])
        tags.extend([start, end])
    return document(fragments, word, wp), tags


def write_package(path, xml, duplicate_member=None):
    with warnings.catch_warnings():
        warnings.simplefilter('ignore', UserWarning)
        with zipfile.ZipFile(path, 'w') as package:
            package.comment = b'PRESERVE PACKAGE COMMENT'
            members = {**OTHER_MEMBERS, 'word/document.xml': xml}
            for name, payload in members.items():
                info = zipfile.ZipInfo(name, (2024, 3, 2, 11, 12, 14))
                info.compress_type = zipfile.ZIP_DEFLATED
                info.comment = ('entry:' + name).encode('utf-8')
                info.external_attr = 0o100600 << 16
                package.writestr(info, payload)
            if duplicate_member is not None:
                package.writestr(duplicate_member, members[duplicate_member])


def mask_inline_distances(xml, prefix='wp'):
    # This independent byte comparison masks only the four authorized attributes;
    # namespace-aware XML assertions below separately inspect their values.
    tag = rb'<' + prefix.encode('ascii') + rb':inline\b(?:"[^"]*"|\x27[^\x27]*\x27|[^\x27">])*>'
    distances = rb'\s+dist[LRBT]\s*=\s*(?:"[^"]*"|\x27[^\x27]*\x27)'
    return re.sub(tag, lambda match: re.sub(distances, b'', match.group()), xml)


class WordExportContractTest(unittest.TestCase):
    def test_marker_must_enclose_the_complete_inline_element(self):
        xml, tags = fixture()
        xml = xml.replace(tags[1], b'', 1).replace(b'</wp:inline>', tags[1] + b'</wp:inline>', 1)
        self.rejected(xml)

    def test_temporary_write_or_replace_failure_preserves_export_and_cleans_owned_file(self):
        xml, _ = fixture()
        for target in ('office_word_export.zipfile.ZipFile.writestr', 'office_word_export.os.replace'):
            with self.subTest(target=target), TemporaryDirectory() as temporary:
                path = Path(temporary) / 'owned.docx'
                write_package(path, xml)
                original = path.read_bytes()
                with patch(target, side_effect=OSError('Controlled export failure')):
                    with self.assertRaises(ValueError):
                        restore_inline_spacing(path, {MARKER_A: dict(MARGINS)})
                self.assertEqual(path.read_bytes(), original)
                self.assertEqual(list(Path(temporary).iterdir()), [path])

    def restored(self, source, mapping, removed_tags, wp='wp'):
        with TemporaryDirectory() as temporary:
            path = Path(temporary) / 'owned-edited.docx'
            write_package(path, source)
            with zipfile.ZipFile(path) as package:
                metadata = {item.filename: (item.date_time, item.compress_type, item.comment,
                    item.external_attr, item.create_system) for item in package.infolist()}
            restore_inline_spacing(path, mapping)
            with zipfile.ZipFile(path) as package:
                self.assertIsNone(package.testzip())
                self.assertEqual(package.comment, b'PRESERVE PACKAGE COMMENT')
                self.assertEqual(len(package.infolist()), len(OTHER_MEMBERS) + 1)
                for name, payload in OTHER_MEMBERS.items():
                    self.assertEqual(package.read(name), payload)
                for item in package.infolist():
                    self.assertEqual((item.date_time, item.compress_type, item.comment,
                        item.external_attr, item.create_system), metadata[item.filename])
                output = package.read('word/document.xml')
        expected = source
        for tag in removed_tags:
            self.assertEqual(expected.count(tag), 1)
            expected = expected.replace(tag, b'', 1)
        self.assertEqual(mask_inline_distances(output, wp), mask_inline_distances(expected, wp))
        root = ET.fromstring(output)
        self.assertFalse(any(item.get('{' + W + '}name') in mapping
            for item in root.iter('{' + W + '}bookmarkStart')))
        return output, list(root.iter('{' + WP + '}inline'))

    def rejected(self, xml, mapping=None, duplicate_member=None):
        with TemporaryDirectory() as temporary:
            path = Path(temporary) / 'owned-edited.docx'
            write_package(path, xml, duplicate_member)
            original = path.read_bytes()
            with self.assertRaises(ValueError):
                restore_inline_spacing(path, {MARKER_A: dict(MARGINS)} if mapping is None else mapping)
            self.assertEqual(path.read_bytes(), original)
            self.assertEqual(sorted(item.name for item in Path(temporary).iterdir()), ['owned-edited.docx'])

    def test_restores_observed_default_spacing_by_absence_and_removes_only_controlled_markers(self):
        xml, tags = fixture()
        output, images = self.restored(xml, {MARKER_A: dict(MARGINS)}, tags)
        self.assertEqual(len(images), 1)
        self.assertEqual({name: images[0].get(name) for name in ('distL', 'distR', 'distT', 'distB')},
            {'distL': None, 'distR': None, 'distT': '0', 'distB': '0'})
        self.assertIn('한글 😀 e\u0301'.encode('utf-8'), output)
        self.assertIn(b'mc:Ignorable="w14"', output)
        self.assertIn(b'data-preserve="quoted &gt; > stays"', output)

    def test_two_identical_image_payloads_use_exact_marker_provenance(self):
        xml, tags = fixture((MARKER_A, MARKER_B))
        _, images = self.restored(xml, {MARKER_B: {'LeftMargin': 0, 'RightMargin': 319,
            'TopMargin': 0, 'BottomMargin': 0}, MARKER_A: dict(MARGINS)}, tags)
        self.assertEqual([(image.get('distL'), image.get('distR'), image.get('distT'), image.get('distB'))
            for image in images], [(None, None, '0', '0'), ('0', None, '0', '0')])

    def test_missing_distance_attributes_and_different_namespace_prefixes(self):
        xml, tags = fixture(word='doc', wp='picp', distances=False, qualified=True)
        output, images = self.restored(xml, {MARKER_A: dict(MARGINS)}, tags, wp='picp')
        self.assertIsNone(images[0].get('distL'))
        self.assertEqual(images[0].get('{urn:keep-attribute}distL'), '777')
        self.assertIn(b'<doc:document', output)
        self.assertIn(b'<picp:inline', output)

    def test_authored_similar_marker_name_and_unmarked_image_are_byte_preserved(self):
        start, end = bookmark(MARKER_A, '100')
        authored_start, authored_end = bookmark(AUTHORED, '999')
        unmarked = inline().replace(b'distL="0"', b'distL="77"')
        xml = document([authored_start, b'<w:r><w:t>AUTHORED</w:t></w:r>', authored_end,
            start, inline(), end, unmarked])
        output, images = self.restored(xml, {MARKER_A: dict(MARGINS)}, [start, end])
        self.assertIn(authored_start, output)
        self.assertIn(authored_end, output)
        self.assertIn(unmarked, output)
        self.assertEqual(len(images), 2)

    def test_missing_controlled_start_or_end_does_not_modify_export(self):
        xml, tags = fixture()
        for tag in tags:
            with self.subTest(tag=tag):
                self.rejected(xml.replace(tag, b'', 1))

    def test_mapping_for_a_marker_absent_from_package_is_rejected(self):
        xml, _ = fixture()
        self.rejected(xml, {MARKER_A: dict(MARGINS), MARKER_B: dict(MARGINS)})

    def test_duplicate_controlled_start_or_end_does_not_modify_export(self):
        xml, tags = fixture()
        for tag in tags:
            with self.subTest(tag=tag):
                self.rejected(xml.replace(tag, tag + tag, 1))

    def test_same_generated_name_with_two_ids_is_ambiguous(self):
        xml, _ = fixture((MARKER_A, MARKER_A))
        self.rejected(xml)

    def test_generated_start_and_end_ids_must_match(self):
        xml, tags = fixture()
        self.rejected(xml.replace(tags[1], b'<w:bookmarkEnd w:id="999"/>'))

    def test_generated_ids_cannot_be_reused_by_an_authored_bookmark(self):
        start, end = bookmark(MARKER_A, '100')
        other_start, other_end = bookmark(AUTHORED, '100')
        self.rejected(document([start, inline(), end, other_start, other_end]))

    def test_controlled_span_must_enclose_exactly_one_inline(self):
        start, end = bookmark(MARKER_A, '100')
        for contents in (b'', inline() + inline()):
            with self.subTest(count=contents.count(b'<wp:inline')):
                self.rejected(document([start, contents, end]))

    def test_controlled_spans_cannot_overlap_or_nest(self):
        start_a, end_a = bookmark(MARKER_A, '100')
        start_b, end_b = bookmark(MARKER_B, '101')
        for ends in ([end_a, end_b], [end_b, end_a]):
            with self.subTest(ends=ends):
                self.rejected(document([start_a, start_b, inline(), *ends]),
                    {MARKER_A: dict(MARGINS), MARKER_B: dict(MARGINS)})

    def test_generated_bookmark_element_cannot_contain_authored_content(self):
        xml, tags = fixture()
        nonempty = tags[0][:-2] + b'><w:r><w:t>DO NOT DELETE</w:t></w:r></w:bookmarkStart>'
        self.rejected(xml.replace(tags[0], nonempty))

    def test_duplicate_inline_distance_attributes_are_rejected(self):
        xml, _ = fixture()
        self.rejected(xml.replace(b'<wp:inline ', b'<wp:inline distL="9" ', 1))

    def test_duplicate_expanded_bookmark_attributes_are_rejected(self):
        xml, _ = fixture()
        duplicate = ('xmlns:n="' + W + '" n:id="100" ').encode('utf-8')
        self.rejected(xml.replace(b'<w:bookmarkStart ', b'<w:bookmarkStart ' + duplicate, 1))

    def test_doctype_and_entity_declarations_are_rejected(self):
        xml, _ = fixture()
        declaration = b'<!DOCTYPE w:document [<!ENTITY unwanted "DECLARED">]>'
        self.rejected(xml.replace(b'?>\n', b'?>\n' + declaration, 1))

    def test_duplicate_package_members_are_rejected(self):
        xml, _ = fixture()
        for member in ('word/document.xml', 'word/media/image1.png'):
            with self.subTest(member=member):
                self.rejected(xml, duplicate_member=member)

    def test_non_utf8_xml_and_invalid_utf8_bytes_are_rejected(self):
        xml, _ = fixture()
        self.rejected(xml.decode('utf-8').replace('encoding="UTF-8"',
            'encoding="UTF-16"').encode('utf-16'))
        self.rejected(xml.replace('한글'.encode('utf-8'), b'\xff\xfe'))

    def test_unobserved_left_or_right_spacing_values_are_rejected(self):
        xml, _ = fixture()
        for side in ('LeftMargin', 'RightMargin'):
            for invalid in (True, -1, 0.5, 1, 318, 320, 11930465, None):
                with self.subTest(side=side, value=invalid):
                    self.rejected(xml, {MARKER_A: {**MARGINS, side: invalid}})

    def test_only_observed_zero_top_and_bottom_spacing_is_supported(self):
        xml, _ = fixture()
        for side in ('TopMargin', 'BottomMargin'):
            for invalid in (True, -1, 0.5, 1, 319, None):
                with self.subTest(side=side, value=invalid):
                    self.rejected(xml, {MARKER_A: {**MARGINS, side: invalid}})

    def test_zero_and_default_left_right_spacing_are_independent_presence_rules(self):
        for left, right in [(0, 0), (0, 319), (319, 0), (319, 319)]:
            with self.subTest(left=left, right=right):
                xml, tags = fixture(distances=False)
                _, images = self.restored(xml, {MARKER_A: {**MARGINS,
                    'LeftMargin': left, 'RightMargin': right}}, tags)
                self.assertEqual(images[0].get('distL'), None if left == 319 else '0')
                self.assertEqual(images[0].get('distR'), None if right == 319 else '0')
                self.assertEqual(images[0].get('distT'), '0')
                self.assertEqual(images[0].get('distB'), '0')

    def test_explicit_zero_spacing_overwrites_existing_attributes_without_converting_hmm(self):
        xml, tags = fixture()
        xml = xml.replace(b'distL="0"', b'distL="114840"').replace(b"distR='0'", b"distR='555'")
        xml = xml.replace(b'distT="0"', b'distT="6"').replace(b"distB='0'", b"distB='7'")
        _, images = self.restored(xml, {MARKER_A: {name: 0 for name in MARGINS}}, tags)
        self.assertEqual({name: images[0].get(name) for name in ('distL', 'distR', 'distT', 'distB')},
            {'distL': '0', 'distR': '0', 'distT': '0', 'distB': '0'})

    def test_mapping_marker_names_must_be_exact_controlled_uuid_names(self):
        for invalid in ('PIV_short', 'PIV_' + 'g' * 32, 'AUTHORED_NAME', MARKER_A + '_suffix'):
            with self.subTest(name=invalid):
                start, end = bookmark(invalid, '100')
                self.rejected(document([start, inline(), end]), {invalid: dict(MARGINS)})

    def test_missing_margin_component_rejects_without_partial_patch(self):
        xml, _ = fixture()
        incomplete = dict(MARGINS)
        del incomplete['BottomMargin']
        self.rejected(xml, {MARKER_A: incomplete})

    def test_one_bad_mapping_prevents_any_of_multiple_inline_patches(self):
        xml, _ = fixture((MARKER_A, MARKER_B))
        self.rejected(xml, {MARKER_A: dict(MARGINS), MARKER_B: {**MARGINS, 'TopMargin': -1}})


if __name__ == '__main__':
    unittest.main()
