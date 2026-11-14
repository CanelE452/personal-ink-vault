"""Public Writer image catalog/replacement contracts; root alone executes tests."""
import copy
import hashlib
from types import SimpleNamespace
import unittest

from office_word_images import WordImages
from test_word_fidelity import FormattedParagraph, FormattedPortion
from test_word_images import (GraphicProvider, Image, NativeText, PAYLOAD, Range,
    ServiceManager, image_model)
from test_word_owners import Element


SOURCE_BYTES = b'CHECKED ASSET INPUT BYTES'
NEW_NATIVE_BYTES = PAYLOAD[:-1] + b'B'
OLD_HASH = hashlib.sha256(PAYLOAD).hexdigest()
NEW_HASH = hashlib.sha256(NEW_NATIVE_BYTES).hexdigest()
ASSET = {'id': '11111111-1111-4111-8111-111111111111', 'mimeType': 'image/png',
    'fileName': 'assets/11111111-1111-4111-8111-111111111111.png',
    'width': 37, 'height': 29, 'bytes': SOURCE_BYTES,
    'sha256': hashlib.sha256(SOURCE_BYTES).hexdigest(), 'byteLength': len(SOURCE_BYTES)}


class InputStream:
    def initialize(self, arguments):
        self.payload = bytes(arguments[0])


class DecoderProvider(GraphicProvider):
    def queryGraphic(self, arguments):
        values = {item.Name: item.Value for item in arguments}
        if values['InputStream'].payload != SOURCE_BYTES:
            raise ValueError('Controlled decoder rejected an unknown asset')
        return SimpleNamespace(MimeType='image/png', SizePixel=SimpleNamespace(Width=37, Height=29),
            Size100thMM=SimpleNamespace(Width=0, Height=0), payload=NEW_NATIVE_BYTES)


class DecoderManager(ServiceManager):
    def createInstanceWithContext(self, name, context):
        if name == 'com.sun.star.io.SequenceInputStream':
            return InputStream()
        if name == 'com.sun.star.graphic.GraphicProvider':
            return DecoderProvider()
        return super().createInstanceWithContext(name, context)


class EditableImage:
    def __init__(self, image):
        self.base = image
        self.graphic = image.Graphic
        self.readonly = False
        self.side_effect = None

    def __getattr__(self, name):
        return getattr(self.base, name)

    @property
    def Graphic(self):
        return self.graphic

    @Graphic.setter
    def Graphic(self, value):
        if self.readonly:
            raise ValueError('Controlled image Graphic is read-only')
        self.graphic = value
        self.base.Graphic = value
        self.base.properties['Graphic'] = value
        if self.side_effect is not None:
            self.side_effect(self)

    def getPropertyValue(self, name):
        return self.Graphic if name == 'Graphic' else self.base.getPropertyValue(name)

    def setPropertyValue(self, name, value):
        if name != 'Graphic':
            raise AssertionError('Writer replacement may assign only Graphic')
        self.Graphic = value

    def getPropertySetInfo(self):
        return SimpleNamespace(hasPropertyByName=lambda name: name in self.properties,
            getPropertyByName=lambda name: SimpleNamespace(Attributes=16 if name == 'Graphic' and self.readonly else 0))


class OpaqueObject:
    def __init__(self, owner, offset):
        self.anchor = Range(owner, offset)

    def getAnchor(self):
        return self.anchor

    def supportsService(self, name):
        return name == 'com.sun.star.drawing.CustomShape'

    def getSupportedServiceNames(self):
        return ('com.sun.star.drawing.CustomShape',)

    def getPropertySetInfo(self):
        return SimpleNamespace(hasPropertyByName=lambda name: False)


def catalog_model():
    fixture = image_model()
    fixture.images = [EditableImage(image) for image in fixture.images]
    for frame, image in zip(fixture.frames, fixture.images):
        frame.references = [image]
    fixture.document.DrawPage.values = list(fixture.images)
    fixture.document.GraphicObjects.entries = [('Alias ' + str(index), image)
        for index, image in enumerate(fixture.images)]
    fixture.context.ServiceManager = DecoderManager()
    fixture.word.context = fixture.context
    fixture.word.uno = SimpleNamespace(ByteSequence=lambda payload: bytes(payload))
    return fixture


class WordImageCatalogContractTest(unittest.TestCase):
    def test_snapshot_exposes_source_bound_images_and_overrides_generic_capability(self):
        fixture = catalog_model()
        catalog = WordImages(fixture.word)
        rows = catalog.snapshot([0])
        self.assertEqual(len(rows), 2)
        self.assertEqual(len({row['id'] for row in rows}), 2)
        for row in rows:
            self.assertEqual(row['ownerId'], 'body')
            self.assertEqual(row['paragraphId'], 'paragraph-0')
            self.assertIsNone(row['tableId'])
            self.assertIsNone(row['cell'])
            self.assertEqual((row['width'], row['height']), (27.01, 19.0))
            self.assertEqual(row['nativeGraphicSha256'], OLD_HASH)
            self.assertEqual(row['image']['mimeType'], 'image/png')
            self.assertEqual((row['image']['pixelWidth'], row['image']['pixelHeight']), (37, 29))
            self.assertIs(row['image']['canReplace'], True)
        self.assertEqual([row['anchorType'] for row in rows], ['AS_CHARACTER', 'AT_CHARACTER'])
        self.assertIs(catalog.image_changed, False)

    def test_ids_are_reserved_once_and_snapshot_does_not_allocate_more_ids(self):
        fixture = catalog_model()
        fixture.word.used_ids.add('word-image-0')
        catalog = WordImages(fixture.word)
        counters = copy.deepcopy(fixture.word._counters)
        identifiers = set(fixture.word.used_ids)
        first = catalog.snapshot([0])
        second = catalog.snapshot([0])
        self.assertEqual([row['id'] for row in first], [row['id'] for row in second])
        self.assertNotIn('word-image-0', [row['id'] for row in first])
        self.assertTrue(all(row['id'] in identifiers for row in first))
        self.assertEqual(fixture.word._counters, counters)
        self.assertEqual(fixture.word.used_ids, identifiers)

    def test_source_ids_follow_structural_frames_instead_of_collection_order(self):
        before = catalog_model()
        rows = WordImages(before.word).snapshot([0])
        reopened_source = catalog_model()
        reopened_source.document.DrawPage.values.reverse()
        reopened_source.document.GraphicObjects.entries.reverse()
        other_rows = WordImages(reopened_source.word).snapshot([0])
        self.assertEqual([(row['id'], row['anchorType']) for row in other_rows],
            [(row['id'], row['anchorType']) for row in rows])

    def test_snapshot_re_resolves_native_wrappers_without_changing_ids(self):
        fixture = catalog_model()
        catalog = WordImages(fixture.word)
        rows = catalog.snapshot([0])
        fixture.document.DrawPage.values.reverse()
        fixture.document.GraphicObjects.entries = [('Renamed B', fixture.images[1]), ('Renamed A', fixture.images[0])]
        self.assertEqual([row['id'] for row in catalog.snapshot([0])], [row['id'] for row in rows])

    def test_replacing_second_equal_payload_image_targets_its_native_object_only(self):
        fixture = catalog_model()
        catalog = WordImages(fixture.word)
        rows = catalog.snapshot([0])
        before_format = [copy.deepcopy({name: value for name, value in image.properties.items()
            if name != 'Graphic'}) for image in fixture.images]
        self.assertNotEqual(ASSET['sha256'], NEW_HASH)
        catalog.replace(rows[1]['id'], dict(ASSET))
        self.assertEqual(fixture.images[0].Graphic.payload, PAYLOAD)
        self.assertEqual(fixture.images[1].Graphic.payload, NEW_NATIVE_BYTES)
        self.assertEqual([row['nativeGraphicSha256'] for row in catalog.snapshot([0])], [OLD_HASH, NEW_HASH])
        self.assertEqual([row['id'] for row in catalog.snapshot([0])], [row['id'] for row in rows])
        for image, expected in zip(fixture.images, before_format):
            self.assertEqual({name: value for name, value in image.properties.items() if name != 'Graphic'}, expected)
        self.assertIs(catalog.image_changed, True)

    def test_replace_rechecks_current_frame_after_field_cache_length_change(self):
        fixture = catalog_model()
        catalog = WordImages(fixture.word)
        target = catalog.snapshot([0])[1]['id']
        fixture.paragraph.portions[1].String = '123456'
        for image, frame in zip(fixture.images, fixture.frames):
            image.anchor.offset += 5
            frame.Start.offset += 5
        catalog.replace(target, dict(ASSET))
        self.assertEqual(fixture.images[1].Graphic.payload, NEW_NATIVE_BYTES)
        self.assertEqual(fixture.images[0].Graphic.payload, PAYLOAD)

    def test_replace_keeps_target_after_paragraph_insertion_before_its_source_location(self):
        fixture = catalog_model()
        catalog = WordImages(fixture.word)
        target = catalog.snapshot([0])[1]['id']
        inserted = FormattedParagraph('A', [FormattedPortion('INSERTED')])
        inserted.Start, inserted.End = Range(fixture.text, 0), Range(fixture.text, 8)
        fixture.text.values.insert(0, inserted)
        fixture.word.body.order.insert(0, {'kind': 'paragraph', 'id': 'inserted-p'})
        fixture.word.body.paragraphs['inserted-p'] = inserted
        fixture.paragraph.Start.offset += 9
        fixture.paragraph.End.offset += 9
        for image, frame in zip(fixture.images, fixture.frames):
            image.anchor.offset += 9
            frame.Start.offset += 9
        catalog.replace(target, dict(ASSET))
        self.assertEqual(fixture.images[1].Graphic.payload, NEW_NATIVE_BYTES)
        self.assertEqual(catalog.snapshot([0])[1]['paragraphId'], 'paragraph-0')

    def test_setter_side_effect_on_margin_crop_or_width_rejects_full_word_state(self):
        for name, value in [('LeftMargin', 319), ('Width', 999),
                ('GraphicCrop', SimpleNamespace(Top=0, Bottom=0, Left=100, Right=0))]:
            with self.subTest(property=name):
                fixture = catalog_model()
                catalog = WordImages(fixture.word)
                target = catalog.snapshot([0])[1]['id']
                fixture.images[1].side_effect = lambda image: image.properties.__setitem__(name, copy.deepcopy(value))
                with self.assertRaises(ValueError):
                    catalog.replace(target, dict(ASSET))
                self.assertIs(catalog.image_changed, False)

    def test_readonly_graphic_is_not_replaceable_even_when_thumbnail_metadata_exists(self):
        fixture = catalog_model()
        fixture.images[1].readonly = True
        catalog = WordImages(fixture.word)
        rows = catalog.snapshot([0])
        self.assertIs(rows[1]['image']['canReplace'], False)
        with self.assertRaises(ValueError):
            catalog.replace(rows[1]['id'], dict(ASSET))
        self.assertEqual(fixture.images[1].Graphic.payload, PAYLOAD)
        self.assertIs(catalog.image_changed, False)

    def test_missing_context_and_non_docx_keep_readonly_catalog_available(self):
        for condition in ('context', 'format'):
            with self.subTest(condition=condition):
                fixture = catalog_model()
                if condition == 'context':
                    fixture.word.context = None
                else:
                    fixture.word.geometry_format = 'odt'
                catalog = WordImages(fixture.word)
                rows = catalog.snapshot([0])
                self.assertEqual(len(rows), 2)
                self.assertTrue(all(row['image']['canReplace'] is not True for row in rows))
                with self.assertRaises(ValueError):
                    catalog.replace(rows[0]['id'], dict(ASSET))
                self.assertIs(catalog.image_changed, False)

    def test_unknown_frame_does_not_break_catalog_but_blocks_replacement_capability(self):
        fixture = catalog_model()
        opaque = OpaqueObject(fixture.text, fixture.frames[1].Start.offset)
        fixture.frames[1].references = [opaque]
        fixture.document.DrawPage.values[1] = opaque
        fixture.document.GraphicObjects.entries = [('Known image', fixture.images[0])]
        catalog = WordImages(fixture.word)
        rows = catalog.snapshot([0])
        self.assertEqual(len(rows), 2)
        self.assertTrue(any(row['nativeGraphicSha256'] == OLD_HASH for row in rows))
        self.assertTrue(any(row['nativeGraphicSha256'] is None for row in rows))
        self.assertTrue(all(row['image']['canReplace'] is not True for row in rows))
        self.assertEqual(fixture.paragraph.String, 'PRE=6AFTERAFTER')

    def test_unbound_native_image_is_readonly_and_is_not_matched_by_equal_payload(self):
        fixture = catalog_model()
        unbound = EditableImage(Image(fixture.text, 999, 1))
        fixture.document.DrawPage.values.append(unbound)
        fixture.document.GraphicObjects.entries.append(('Unbound same image', unbound))
        rows = WordImages(fixture.word).snapshot([0])
        self.assertEqual(len(rows), 3)
        unbound_rows = [row for row in rows if row['paragraphId'] is None]
        self.assertEqual(len(unbound_rows), 1)
        self.assertIsNone(unbound_rows[0]['ownerId'])
        self.assertIs(unbound_rows[0]['image']['canReplace'], False)
        self.assertTrue(all(row['image']['canReplace'] is not True for row in rows))

    def test_deleted_source_target_does_not_rebind_to_another_equal_image(self):
        fixture = catalog_model()
        catalog = WordImages(fixture.word)
        target = catalog.snapshot([0])[0]['id']
        fixture.paragraph.portions.remove(fixture.frames[0])
        fixture.document.DrawPage.values.remove(fixture.images[0])
        fixture.document.GraphicObjects.entries = [('Remaining equal image', fixture.images[1])]
        with self.assertRaises(ValueError):
            catalog.replace(target, dict(ASSET))
        self.assertEqual(fixture.images[1].Graphic.payload, PAYLOAD)
        self.assertIs(catalog.image_changed, False)

    def test_wrong_anchor_owner_keeps_metadata_readonly_and_rejects_replacement(self):
        fixture = catalog_model()
        fixture.images[1].anchor.owner = NativeText()
        catalog = WordImages(fixture.word)
        rows = catalog.snapshot([0])
        self.assertTrue(all(row['image']['canReplace'] is not True for row in rows))
        with self.assertRaises(ValueError):
            catalog.replace(rows[1]['id'], dict(ASSET))
        self.assertIs(catalog.image_changed, False)

    def test_table_cell_location_uses_only_actual_registered_table_identity(self):
        fixture = catalog_model()
        cell_text = NativeText()
        frame, image = fixture.frames[0], fixture.images[0]
        fixture.paragraph.portions.remove(frame)
        frame.Start = frame.End = Range(cell_text, 4)
        image.anchor.owner, image.anchor.offset = cell_text, 4
        cell_paragraph = FormattedParagraph('A', [FormattedPortion('CELL'), frame])
        cell_text.values = [cell_paragraph]
        table = Element('TextTable', 'table-0')
        table.CellNames = ('A1',)
        table.getCellByName = lambda name: SimpleNamespace(Text=cell_text) if name == 'A1' else None
        fixture.text.values.append(table)
        fixture.word.body.order.append({'kind': 'table', 'id': 'table-0'})
        fixture.word.tables['table-0'] = table
        fixture.word.table_owners['table-0'] = 'body'
        rows = WordImages(fixture.word).snapshot([0])
        cell_rows = [row for row in rows if row['tableId'] == 'table-0']
        self.assertEqual(len(cell_rows), 1)
        self.assertEqual(cell_rows[0]['ownerId'], 'body')
        self.assertIsNone(cell_rows[0]['paragraphId'])
        self.assertEqual(cell_rows[0]['cell'], 'A1')

    def test_unknown_public_id_never_uses_native_name_or_paragraph_id_as_fallback(self):
        for identifier in ('SAME AUTHORED IMAGE NAME', 'paragraph-0', 'missing-image'):
            with self.subTest(identifier=identifier):
                fixture = catalog_model()
                catalog = WordImages(fixture.word)
                with self.assertRaises(ValueError):
                    catalog.replace(identifier, dict(ASSET))
                self.assertTrue(all(image.Graphic.payload == PAYLOAD for image in fixture.images))
                self.assertIs(catalog.image_changed, False)

    def test_unobserved_inline_spacing_blocks_replacement_before_graphic_changes(self):
        fixture = catalog_model()
        fixture.images[0].properties['LeftMargin'] = 320
        catalog = WordImages(fixture.word)
        rows = catalog.snapshot([0])
        self.assertTrue(all(row['image']['canReplace'] is not True for row in rows))
        with self.assertRaises(ValueError):
            catalog.replace(rows[1]['id'], dict(ASSET))
        self.assertTrue(all(image.Graphic.payload == PAYLOAD for image in fixture.images))
        self.assertIs(catalog.image_changed, False)

    def test_unreadable_graphic_writability_keeps_readonly_metadata_available(self):
        fixture = catalog_model()
        original = fixture.images[1].getPropertySetInfo

        def unreadable():
            information = original()

            def descriptor(name):
                raise RuntimeError('Controlled native property descriptor failure')

            information.getPropertyByName = descriptor
            return information

        fixture.images[1].getPropertySetInfo = unreadable
        catalog = WordImages(fixture.word)
        rows = catalog.snapshot([0])
        self.assertEqual(len(rows), 2)
        self.assertIsNot(rows[1]['image']['canReplace'], True)
        with self.assertRaises(ValueError):
            catalog.replace(rows[1]['id'], dict(ASSET))
        self.assertEqual(fixture.images[1].Graphic.payload, PAYLOAD)

    def test_sequential_replacements_preserve_each_source_native_identity(self):
        fixture = catalog_model()
        catalog = WordImages(fixture.word)
        rows = catalog.snapshot([0])
        catalog.replace(rows[1]['id'], dict(ASSET))
        catalog.replace(rows[0]['id'], dict(ASSET))
        self.assertEqual([row['id'] for row in catalog.snapshot([0])], [row['id'] for row in rows])
        self.assertEqual([row['nativeGraphicSha256'] for row in catalog.snapshot([0])], [NEW_HASH, NEW_HASH])
        self.assertTrue(all(image.Graphic.payload == NEW_NATIVE_BYTES for image in fixture.images))
        self.assertIs(catalog.image_changed, True)


if __name__ == '__main__':
    unittest.main()
