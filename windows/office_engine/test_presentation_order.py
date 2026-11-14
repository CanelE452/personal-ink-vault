import hashlib
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch
from xml.etree import ElementTree as ET
import zipfile

from test_presentation_source import P, R, package_members, slide_xml, write_package
import office_presentation_source as reader
from office_presentation_package_patch import read_slide_sections, write_reordered_pptx


P14 = 'http://schemas.microsoft.com/office/powerpoint/2010/main'
PRESENTATION = 'ppt/presentation.xml'
SECTION_URI = '{521415D9-36F7-43E2-AB2F-B90AF26B5E84}'
FIRST = '{00000000-0000-4000-8000-000000000001}'
SECOND = '{00000000-0000-4000-8000-000000000002}'
OTHER = b'<p:ext uri="retain"><custom:example xmlns:custom="urn:retained" v="keep"/></p:ext>'


def fixture(path, sections=True, *, first='256', ids=(256, 257, 258), unknown='', protected=False, signed=False):
    slides = {f'ppt/slides/slide{n}.xml': slide_xml() for n in range(1, len(ids) + 1)}
    rels = [f'rId{n}' for n in range(1, len(ids) + 1)]
    parts = dict(package_members(slides, rels, [(rid, part[4:], R + '/slide', None)
        for rid, part in zip(rels, slides)]))
    xml = parts[PRESENTATION]
    for index, identity in enumerate(ids):
        xml = xml.replace(f'<p:sldId id="{256 + index}"'.encode(), f'<p:sldId id="{identity}"'.encode())
    extension = (
        f'<p:ext uri="{SECTION_URI}"><s:sectionLst xmlns:s="{P14}">'
        f'<s:section name="연구 &amp; 발표" id="{FIRST}"{unknown}>'
        f'<s:sldIdLst><s:sldId id="{first}"/></s:sldIdLst></s:section>'
        f'<s:section name="부록" id="{SECOND}"><s:sldIdLst>'
        '<s:sldId id="257"/><s:sldId id="258"/></s:sldIdLst></s:section>'
        '</s:sectionLst></p:ext>').encode() if sections else b''
    protection = b'<p:modifyVerifier/>' if protected else b''
    parts[PRESENTATION] = xml.replace(b'</p:presentation>', protection + b'<p:extLst>' +
        OTHER + extension + b'</p:extLst></p:presentation>')
    if signed:
        parts['_xmlsignatures/sig1.xml'] = b'<Signature/>'
    write_package(path, parts.items())
    return hashlib.sha256(path.read_bytes()).hexdigest()


def topology(path):
    with zipfile.ZipFile(path) as archive:
        data = archive.read(PRESENTATION)
    root = ET.fromstring(data)
    order = tuple(int(slide.get('id')) for slide in root.find(f'{{{P}}}sldIdLst'))
    sections = [(group.get('name'), group.get('id'),
        tuple(int(slide.get('id')) for slide in group.find(f'{{{P14}}}sldIdLst')))
        for group in root.findall(f'.//{{{P14}}}section')]
    return order, sections, data


class PresentationOrderTest(unittest.TestCase):
    def assert_unrelated_package_bytes(self, source, candidate):
        with zipfile.ZipFile(source) as old, zipfile.ZipFile(candidate) as new:
            self.assertEqual(old.comment, new.comment)
            self.assertEqual(old.namelist(), new.namelist())
            self.assertIsNone(new.testzip())
            for name in old.namelist():
                if name != PRESENTATION:
                    self.assertEqual(old.read(name), new.read(name), name)
                    self.assertEqual(old.getinfo(name).comment, new.getinfo(name).comment, name)

    def test_cross_section_move_preserves_empty_group_and_unrelated_package(self):
        with TemporaryDirectory() as directory:
            source, output = (Path(directory) / name for name in ('source.pptx', 'output.pptx'))
            sha = fixture(source)
            sections = read_slide_sections(source, sha)
            sections.assign('slide-0', 'slide-2')
            result = write_reordered_pptx(source, output, sha,
                ['slide-0', 'slide-1', 'slide-2'], ['slide-1', 'slide-2', 'slide-0'], sections)
            order, groups, data = topology(output)
            self.assertEqual(order, (257, 258, 256))
            self.assertEqual(groups, [('연구 & 발표', FIRST, ()), ('부록', SECOND, (257, 258, 256))])
            self.assertIn(OTHER, data)
            self.assertEqual(hashlib.sha256(source.read_bytes()).hexdigest(), sha)
            self.assertEqual(hashlib.sha256(output.read_bytes()).hexdigest(), result)
            self.assert_unrelated_package_bytes(source, output)

    def test_mixed_batch_restores_lost_sections_using_stage_slide_ids(self):
        with TemporaryDirectory() as directory:
            source, staged, output = (Path(directory) / name for name in (
                'source.pptx', 'staging.pptx', 'output.pptx'))
            original = fixture(source)
            serialized = fixture(staged, False, ids=(301, 302, 303))
            sections = read_slide_sections(source, original)
            sections.remove('slide-0')
            sections.assign('new-slide', 'slide-2')
            write_reordered_pptx(staged, output, serialized,
                ['slide-1', 'slide-2', 'new-slide'], ['slide-1', 'new-slide', 'slide-2'], sections)
            order, groups, data = topology(output)
            self.assertEqual(order, (301, 303, 302))
            self.assertEqual(groups, [('연구 & 발표', FIRST, ()), ('부록', SECOND, (301, 303, 302))])
            self.assertIn(OTHER, data)
            self.assert_unrelated_package_bytes(staged, output)
            self.assertEqual(hashlib.sha256(staged.read_bytes()).hexdigest(), serialized)

    def test_rejects_ambiguous_protected_signed_and_stale_source(self):
        for options in ({'first': '257'}, {'unknown': ' unknown="keep"'}, {'protected': True}, {'signed': True}):
            with self.subTest(options=options), TemporaryDirectory() as directory:
                source = Path(directory) / 'source.pptx'
                sha = fixture(source, **options)
                with self.assertRaises(ValueError):
                    read_slide_sections(source, sha)
                self.assertEqual(hashlib.sha256(source.read_bytes()).hexdigest(), sha)
        with TemporaryDirectory() as directory:
            source, output = (Path(directory) / name for name in ('source.pptx', 'output.pptx'))
            sha = fixture(source, False)
            self.assertIsNone(read_slide_sections(source, sha))
            with self.assertRaises(ValueError):
                read_slide_sections(source, '0' * 64)
            with self.assertRaises(ValueError):
                write_reordered_pptx(source, output, sha,
                    ['slide-0', 'slide-1', 'slide-2'], ['slide-0', 'slide-0', 'slide-2'], None)
            self.assertFalse(output.exists())

    def test_candidate_change_after_package_verification_cannot_publish(self):
        with TemporaryDirectory() as directory:
            source, output = (Path(directory) / name for name in ('source.pptx', 'output.pptx'))
            sha = fixture(source, False)
            catalog = reader._catalog

            def tamper(archive, count):
                result = catalog(archive, count)
                if output.is_file():
                    # Change only the ZIP comment, so member checksums still pass.
                    with output.open('r+b', buffering=0) as stream:
                        stream.seek(-1, 2)
                        stream.write(b'!')
                return result

            with patch.object(reader, '_catalog', side_effect=tamper), self.assertRaises(ValueError):
                write_reordered_pptx(source, output, sha,
                    ['slide-0', 'slide-1', 'slide-2'], ['slide-1', 'slide-2', 'slide-0'], None)
            self.assertFalse(output.exists())
            self.assertEqual(hashlib.sha256(source.read_bytes()).hexdigest(), sha)


if __name__ == '__main__':
    unittest.main()
