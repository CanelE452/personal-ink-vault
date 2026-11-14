"""Exact authored PPTX duplication, before the separate native save gate."""
import hashlib
import importlib.util
from pathlib import Path
import re
import struct
from tempfile import TemporaryDirectory
import unittest
from xml.etree import ElementTree as ET
import zipfile

from test_presentation_source import (
    P, R, PKG, package_members, relationships_xml, slide_xml, write_package,
)


CT = 'http://schemas.openxmlformats.org/package/2006/content-types'
P14 = 'http://schemas.microsoft.com/office/powerpoint/2010/main'
A16 = 'http://schemas.microsoft.com/office/drawing/2014/main'
SLIDE = 'ppt/slides/slide7.xml'
SECOND = 'ppt/slides/slide2.xml'
NOTES = 'ppt/notesSlides/notesSlide4.xml'
LAYOUT = 'ppt/slideLayouts/slideLayout1.xml'
MASTER = 'ppt/notesMasters/notesMaster1.xml'
PHOTO = 'ppt/media/image1.png'
SHAPE_ID = '{8BDF17BA-07B6-4CF6-A50B-89B6079F368A}'
MODULE = importlib.import_module('office_presentation_duplicate') if importlib.util.find_spec(
    'office_presentation_duplicate') is not None else None


def make_source(modern=False, hidden_reference=False, note_backref=SLIDE, chart=False, signed=False):
    slides = {SLIDE: slide_xml(), SECOND: slide_xml().replace('한글 é'.encode(), b'SECOND')}
    if modern:
        slide = slides[SLIDE]
        shape = (
            '<p:sp><p:nvSpPr><p:cNvPr id="2" name="Box"><a:extLst><a:ext uri="creation">'
            '<a16:creationId xmlns:a16="' + A16 + '" id="' + SHAPE_ID + '"/>'
            '</a:ext></a:extLst></p:cNvPr><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr/></p:sp>'
        ).encode()
        if hidden_reference:
            shape += ('<p:extLst><p:ext uri="unsafe" custom="' + SHAPE_ID + '"/></p:extLst>').encode()
        slides[SLIDE] = slide.replace(b'</p:spTree>', shape + b'</p:spTree>').replace(
            b'</p:cSld>', ('<p:extLst><p:ext uri="slide-creation"><p14:creationId xmlns:p14="' +
                           P14 + '" val="78"/></p:ext></p:extLst></p:cSld>').encode())
        slides[SECOND] = slides[SECOND].replace(
            b'</p:cSld>', ('<p:extLst><p:ext uri="slide-creation"><p14:creationId xmlns:p14="' +
                           P14 + '" val="79"/></p:ext></p:extLst></p:cSld>').encode())
    result = dict(package_members(slides, ['rId8', 'rId2'], [
        ('rId8', 'slides/slide7.xml', R + '/slide', None),
        ('rId2', 'slides/slide2.xml', R + '/slide', None),
    ]))
    result['ppt/presentation.xml'] = result['ppt/presentation.xml'].replace(
        b'<p:sldIdLst>', b'\r\n<!-- Retain exact authored prefix -->\r\n<p:sldIdLst>')
    slide_relationships = [
        ('rId1', '../slideLayouts/slideLayout1.xml', R + '/slideLayout', None),
        ('rId2', '../notesSlides/notesSlide4.xml', R + '/notesSlide', None),
        ('rId3', '../media/image1.png', R + '/image', None),
        ('rId4', 'https://example.com/research?a=1&amp;b=2', R + '/hyperlink', 'External'),
        ('rId5', 'slide2.xml', R + '/slide', None),
    ]
    if chart:
        slide_relationships.append(('rId6', '../charts/chart1.xml', R + '/chart', None))
        result['ppt/charts/chart1.xml'] = b'<chart/>'
    result['ppt/slides/_rels/slide7.xml.rels'] = relationships_xml(slide_relationships)
    result['ppt/slides/_rels/slide2.xml.rels'] = relationships_xml(slide_relationships[:1])
    result['ppt/notesSlides/_rels/notesSlide4.xml.rels'] = relationships_xml([
        ('rId1', '../notesMasters/notesMaster1.xml', R + '/notesMaster', None),
        ('rId2', '../slides/' + Path(note_backref).name, R + '/slide', None),
    ])
    result[NOTES] = (f'<p:notes xmlns:p="{P}"><p:cSld name="노트 📝"/></p:notes>').encode()
    result[PHOTO] = b'IMMUTABLE PHOTO\x00\xff'
    result[LAYOUT], result[MASTER] = b'<layout/>', b'<master/>'
    types = [(NOTES, 'notesSlide'), (LAYOUT, 'slideLayout'), (MASTER, 'notesMaster')]
    result['[Content_Types].xml'] = result['[Content_Types].xml'].replace(
        b'</Types>', b'<Default Extension="png" ContentType="image/png"/>' + b''.join(
            (f'<Override PartName="/{part}" ContentType="application/'
             f'vnd.openxmlformats-officedocument.presentationml.{kind}+xml"/>').encode()
            for part, kind in types
        ) + b'</Types>')
    if signed:
        result['_xmlsignatures/sig1.xml'] = b'<Signature/>'
    return result


def read_output(path):
    with zipfile.ZipFile(path) as archive:
        return {name: archive.read(name) for name in archive.namelist()}


def slide_order(parts):
    relationships = {node.get('Id'): node.get('Target') for node in
        ET.fromstring(parts['ppt/_rels/presentation.xml.rels'])}
    listing = ET.fromstring(parts['ppt/presentation.xml']).find(f'{{{P}}}sldIdLst')
    return ['ppt/' + relationships[node.get(f'{{{R}}}id')] for node in listing]


class PresentationDuplicateTest(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(MODULE, 'PPTX slide duplication is not implemented')
        temporary = TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.source = Path(temporary.name) / 'original.pptx'
        self.output = Path(temporary.name) / 'candidate.pptx'

    def write_source(self, members):
        write_package(self.source, members.items())
        return hashlib.sha256(self.source.read_bytes()).hexdigest()

    def test_copies_slide_notes_and_links_without_changing_other_parts(self):
        source = make_source()
        digest = self.write_source(source)
        self.assertEqual(MODULE.duplicable_slides(self.source, digest), {0, 1})
        MODULE.duplicate_pptx(self.source, self.output, 0, digest)
        output = read_output(self.output)
        self.assertEqual(hashlib.sha256(self.source.read_bytes()).hexdigest(), digest)
        clone, = set(slide_order(output)) - {SLIDE, SECOND}
        self.assertEqual(slide_order(output), [SLIDE, clone, SECOND])
        self.assertEqual(output[clone], source[SLIDE])
        self.assertEqual({name for name, data in source.items() if output[name] != data}, {
            '[Content_Types].xml', 'ppt/presentation.xml', 'ppt/_rels/presentation.xml.rels',
        })
        self.assertIn(b'<!-- Retain exact authored prefix -->', output['ppt/presentation.xml'])
        clone_rels = ET.fromstring(output['ppt/slides/_rels/' + Path(clone).name + '.rels'])
        by_id = {node.get('Id'): node for node in clone_rels}
        self.assertEqual(by_id['rId3'].get('Target'), '../media/image1.png')
        self.assertEqual(by_id['rId4'].get('Target'), 'https://example.com/research?a=1&b=2')
        self.assertEqual(by_id['rId5'].get('Target'), 'slide2.xml')
        notes = 'ppt/notesSlides/' + Path(by_id['rId2'].get('Target')).name
        self.assertNotEqual(notes, NOTES)
        self.assertEqual(output[notes], source[NOTES])
        notes_rels = ET.fromstring(output['ppt/notesSlides/_rels/' + Path(notes).name + '.rels'])
        self.assertEqual(next(node.get('Target') for node in notes_rels
            if node.get('Type') == R + '/slide'), '../slides/' + Path(clone).name)
        self.assertEqual(ET.fromstring(output['[Content_Types].xml']).find(
            f'{{{CT}}}Override[@PartName="/{notes}"]').get('ContentType').rsplit('.', 1)[1],
            'notesSlide+xml')

    def test_modern_creation_ids_are_refreshed_only_in_copy(self):
        source = make_source(modern=True)
        digest = self.write_source(source)
        self.assertEqual(MODULE.duplicable_slides(self.source, digest), {0, 1})
        MODULE.duplicate_pptx(self.source, self.output, 0, digest)
        output = read_output(self.output)
        clone = output[slide_order(output)[1]]
        clone_xml = ET.fromstring(clone)
        page_id = clone_xml.find(f'.//{{{P14}}}creationId').get('val')
        shape_id = clone_xml.find(f'.//{{{A16}}}creationId').get('id')
        self.assertNotIn(page_id, ('78', '79'))
        self.assertNotEqual(shape_id.upper(), SHAPE_ID)
        self.assertRegex(shape_id, r'^\{[A-Fa-f0-9-]{36}\}$')
        restored = re.sub(rb'(<p14:creationId[^>]* val=")[0-9]+', rb'\g<1>78', clone)
        self.assertEqual(restored.replace(shape_id.encode(), SHAPE_ID.encode()), source[SLIDE])

    def test_remaps_a16_connections_only_when_the_copy_defines_the_endpoints(self):
        connector = (f'<p:extLst><p:ext uri="connections"><a16:cxnDERefs xmlns:a16="{A16}" '
                     f'st="{SHAPE_ID}" end="{SHAPE_ID}"/></p:ext></p:extLst>').encode()
        source = make_source(modern=True)
        source[SLIDE] = source[SLIDE].replace(b'</p:sld>', connector + b'</p:sld>')
        digest = self.write_source(source)
        MODULE.duplicate_pptx(self.source, self.output, 0, digest)
        output = read_output(self.output)
        clone = ET.fromstring(output[slide_order(output)[1]])
        shape_id = clone.find(f'.//{{{A16}}}creationId').get('id')
        connection = clone.find(f'.//{{{A16}}}cxnDERefs')
        self.assertEqual((connection.get('st'), connection.get('end')), (shape_id, shape_id))
        self.output.unlink()
        source = make_source()
        source[SLIDE] = source[SLIDE].replace(b'</p:sld>', connector + b'</p:sld>')
        digest = self.write_source(source)
        self.assertEqual(MODULE.duplicable_slides(self.source, digest), {1})

    def test_rejects_unknown_slide_relationship_or_creation_id_reference(self):
        for options in ({'chart': True}, {'note_backref': SECOND},
                        {'modern': True, 'hidden_reference': True}):
            with self.subTest(options=options):
                digest = self.write_source(make_source(**options))
                self.assertEqual(MODULE.duplicable_slides(self.source, digest), {1})
                with self.assertRaises(ValueError):
                    MODULE.duplicate_pptx(self.source, self.output, 0, digest)
                self.assertFalse(self.output.exists())
        source = make_source()
        rels = 'ppt/slides/_rels/slide7.xml.rels'
        source[rels] = source[rels].replace((R + '/image').encode(), b'image')
        digest = self.write_source(source)
        self.assertEqual(MODULE.duplicable_slides(self.source, digest), {1})

    def test_refuses_stale_signed_or_aliased_package_and_preserves_destination(self):
        digest = self.write_source(make_source())
        self.output.write_bytes(b'foreign')
        with self.assertRaises(FileExistsError):
            MODULE.duplicate_pptx(self.source, self.output, 0, digest)
        self.assertEqual(self.output.read_bytes(), b'foreign')
        self.output.unlink()
        for index, expected in ((0, '0' * 64), (2, digest), (True, digest)):
            with self.subTest(index=index):
                with self.assertRaises(ValueError):
                    MODULE.duplicate_pptx(self.source, self.output, index, expected)
                self.assertFalse(self.output.exists())
        for members in (make_source(signed=True), {**make_source(), SLIDE.upper(): b'alias'}):
            digest = self.write_source(members)
            with self.assertRaises(ValueError):
                MODULE.duplicate_pptx(self.source, self.output, 0, digest)
            self.assertFalse(self.output.exists())

    def test_repeat_duplicate_preserves_utf8_flags_on_raw_ascii_named_members(self):
        original = make_source()
        self.write_source(original)
        data = bytearray(self.source.read_bytes())
        with zipfile.ZipFile(self.source) as archive:
            central = archive.start_dir
            for member in archive.infolist():
                for offset in (member.header_offset + 6, central + 8):
                    flags = struct.unpack_from('<H', data, offset)[0]
                    struct.pack_into('<H', data, offset, flags | 0x800)
                central += 46 + sum(struct.unpack_from('<3H', data, central + 28))
        self.source.write_bytes(data)
        digest = hashlib.sha256(data).hexdigest()
        MODULE.duplicate_pptx(self.source, self.output, 0, digest)
        output_digest = hashlib.sha256(self.output.read_bytes()).hexdigest()
        self.assertEqual(MODULE.duplicable_slides(self.output, output_digest), {0, 1, 2})
        repeated = self.output.with_name('second-candidate.pptx')
        MODULE.duplicate_pptx(self.output, repeated, 1, output_digest)
        with zipfile.ZipFile(repeated) as archive:
            self.assertEqual(archive.getinfo(PHOTO).flag_bits & 0x800, 0x800)
            self.assertEqual(archive.read(PHOTO), original[PHOTO])


if __name__ == '__main__':
    unittest.main()
