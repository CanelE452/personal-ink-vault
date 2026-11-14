"""Ordinary Writer text saves must preserve verified source pictures too."""
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch
from urllib.parse import unquote, urlparse

import office_worker as worker
from test_word_image_catalog import ASSET, NEW_NATIVE_BYTES, OpaqueObject, catalog_model
from test_word_images import image_model


class WordImageSaveTest(unittest.TestCase):
    def test_ordinary_edit_requires_reopen_for_verified_source_pictures(self):
        fixture = catalog_model()
        catalog = fixture.word.image_catalog()
        self.assertFalse(catalog.image_changed)
        self.assertFalse(fixture.word.has_geometry)
        self.assertTrue(fixture.word.requires_reopen_verification())

    def test_verified_source_cannot_disable_reopen_after_later_object_damage(self):
        fixture = catalog_model()
        fixture.word.image_catalog()
        fixture.images[0].properties['SurroundContour'] = True
        self.assertTrue(fixture.word.requires_reopen_verification())
        with self.assertRaises(ValueError):
            fixture.word.verification_state()

    def test_text_save_rejects_supported_source_width_or_margin_damage(self):
        for name, value in (('Width', 4000), ('LeftMargin', 319)):
            with self.subTest(property=name):
                fixture = catalog_model()
                fixture.word.image_catalog()
                fixture.images[0].properties[name] = value
                with self.assertRaises(ValueError):
                    fixture.word.verification_state()

    def test_text_save_rejects_source_payload_changed_without_image_replace(self):
        fixture = catalog_model()
        fixture.word.image_catalog()
        fixture.images[0].Graphic.payload = NEW_NATIVE_BYTES
        with self.assertRaises(ValueError):
            fixture.word.verification_state()

    def test_text_save_rejects_source_image_removed_from_frame_and_complete_inventory(self):
        fixture = catalog_model()
        fixture.word.image_catalog()
        fixture.paragraph.portions.remove(fixture.frames[0])
        fixture.document.DrawPage.values.remove(fixture.images[0])
        fixture.document.GraphicObjects.entries = [('Remaining image', fixture.images[1])]
        with self.assertRaises(ValueError):
            fixture.word.verification_state()

    def test_verified_replacement_accepts_later_text_anchor_movement(self):
        fixture = catalog_model()
        catalog = fixture.word.image_catalog()
        target = catalog.snapshot([0])[1]['id']
        catalog.replace(target, dict(ASSET))
        fixture.paragraph.portions[0].String = 'PREFIX PRE='
        for image, frame in zip(fixture.images, fixture.frames):
            image.anchor.offset += 7
            frame.Start.offset += 7
        fixture.paragraph.End.offset += 7
        fixture.word.verification_state()
        self.assertEqual(fixture.images[1].Graphic.payload, NEW_NATIVE_BYTES)
        self.assertEqual(catalog.snapshot([0])[1]['id'], target)
        self.assertTrue(fixture.word.requires_reopen_verification())

    def test_verified_empty_source_also_requires_reopen_on_a_later_text_save(self):
        fixture = image_model(count=0)
        catalog = fixture.word.image_catalog()
        self.assertEqual(catalog.source_bindings, [])
        self.assertFalse(catalog.image_changed)
        self.assertTrue(fixture.word.requires_reopen_verification())

    def test_unsupported_originals_keep_the_existing_text_save_path(self):
        for reason in ('unknown-frame', 'spacing', 'format', 'context'):
            with self.subTest(reason=reason):
                fixture = catalog_model()
                if reason == 'unknown-frame':
                    opaque = OpaqueObject(fixture.text, fixture.frames[0].Start.offset)
                    fixture.frames[0].references = [opaque]
                elif reason == 'spacing':
                    fixture.images[0].properties['LeftMargin'] = 320
                elif reason == 'format':
                    fixture.word.geometry_format = 'odt'
                elif reason == 'context':
                    fixture.word.context = None
                fixture.word.image_catalog()
                self.assertFalse(fixture.word.requires_reopen_verification())
                if reason == 'spacing':
                    fixture.images[0].properties['LeftMargin'] = 0
                    fixture.word.image_catalog().snapshot([0])
                    self.assertFalse(fixture.word.requires_reopen_verification())

    def test_failed_text_only_canonical_check_removes_private_outputs(self):
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            source, job = root / 'source.docx', root / 'job'
            source.write_bytes(b'controlled source')

            def store(url, options):
                parsed = unquote(urlparse(url).path)
                Path(parsed.lstrip('/') if len(parsed) > 2 and parsed[2] == ':' else parsed).write_bytes(b'private edited')
                (job / 'preview.pdf').write_bytes(b'private preview')

            document = SimpleNamespace(storeToURL=store, close=Mock())
            server = SimpleNamespace(load=lambda path: document, context=object())
            word = SimpleNamespace(requires_reopen_verification=lambda: True,
                verification_state=lambda: {'expected': 'authored source state'},
                reopen_verification_state=lambda: {'expected': 'authored source state'}, export_bindings=[])
            reopened = SimpleNamespace(verify_reopened=Mock(side_effect=ValueError('Controlled picture fidelity loss')))

            def apply(document, operations, assets, context, state):
                state.update(word=word, presentation=None)
                return 'word', [], []

            with patch.object(worker, 'OfficeServer') as factory, \
                    patch.object(worker, 'apply_operations', side_effect=apply), \
                    patch.object(worker, 'objects', return_value=('word', {}, {})), \
                    patch.object(worker.office_word_layout, 'WordDocument', return_value=reopened), \
                    patch.object(worker.office_word_inline, 'prepare_inline_spacing', return_value={}), \
                    patch.object(worker, 'uno', object(), create=True), \
                    patch.object(worker, 'prop', lambda name, value: (name, value)):
                factory.return_value.__enter__.return_value = server
                with self.assertRaisesRegex(ValueError, 'Controlled picture fidelity loss'):
                    worker.run_request(root, {'mode': 'apply', 'sourcePath': str(source),
                        'sessionId': 'text-only', 'operations': []}, job)
            reopened.verify_reopened.assert_called_once()
            self.assertFalse((job / 'edited.docx').exists())
            self.assertFalse((job / 'preview.pdf').exists())
            self.assertEqual(source.read_bytes(), b'controlled source')

    def test_final_canonical_close_failure_removes_private_outputs_once(self):
        with TemporaryDirectory() as temporary:
            root = Path(temporary)
            source, job = root / 'source.docx', root / 'job'
            source.write_bytes(b'controlled source')

            def store(url, options):
                parsed = unquote(urlparse(url).path)
                Path(parsed.lstrip('/') if len(parsed) > 2 and parsed[2] == ':' else parsed).write_bytes(b'private edited')

            def export(document, path, kind):
                path.write_bytes(b'private preview')
                return 1

            original = SimpleNamespace(storeToURL=store, close=Mock())
            canonical = SimpleNamespace(close=Mock(side_effect=RuntimeError('Controlled final close failure')))
            server = SimpleNamespace(load=Mock(side_effect=[original, canonical]), context=object())
            word = SimpleNamespace(requires_reopen_verification=lambda: True,
                verification_state=lambda: {'expected': 'authored source state'},
                reopen_verification_state=lambda: {'expected': 'authored source state'}, export_bindings=[])
            reopened = SimpleNamespace(verify_reopened=lambda expected: None)

            def apply(document, operations, assets, context, state):
                state.update(word=word, presentation=None)
                return 'word', [], []

            with patch.object(worker, 'OfficeServer') as factory, \
                    patch.object(worker, 'apply_operations', side_effect=apply), \
                    patch.object(worker, 'objects', return_value=('word', {}, {})), \
                    patch.object(worker.office_word_layout, 'WordDocument', return_value=reopened), \
                    patch.object(worker.office_word_inline, 'prepare_inline_spacing', return_value={}), \
                    patch.object(worker, 'snapshot', return_value={'kind': 'word'}), \
                    patch.object(worker, 'export_pdf', side_effect=export), \
                    patch.object(worker, 'uno', object(), create=True), \
                    patch.object(worker, 'prop', lambda name, value: (name, value)):
                factory.return_value.__enter__.return_value = server
                with self.assertRaisesRegex(RuntimeError, 'Controlled final close failure'):
                    worker.run_request(root, {'mode': 'apply', 'sourcePath': str(source),
                        'sessionId': 'text-only-close', 'operations': []}, job)
            self.assertFalse((job / 'edited.docx').exists())
            self.assertFalse((job / 'preview.pdf').exists())
            self.assertEqual(canonical.close.call_count, 1)
            self.assertEqual(source.read_bytes(), b'controlled source')


if __name__ == '__main__':
    unittest.main()
