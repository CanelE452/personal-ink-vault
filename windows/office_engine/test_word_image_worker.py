from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

import office_worker as worker


class WordImageWorkerTest(unittest.TestCase):
    def test_inspect_and_live_draft_snapshot_publish_verified_zero_image_body_targets(self):
        from test_word_image_mutations import empty_catalog_model
        for draft in (False, True):
            with self.subTest(draft=draft):
                fixture = empty_catalog_model()
                with patch.object(worker, 'objects', return_value=('word', fixture.word.body.paragraphs, {})), \
                        patch.object(worker, 'uno', fixture.word.uno, create=True), \
                        patch.object(worker.office_word_layout, 'WordDocument', return_value=fixture.word), \
                        patch.object(worker.office_word, 'paragraph_styles', return_value=[]), \
                        patch.object(worker, 'style', return_value={'fontSize': None, 'bold': None, 'color': None}):
                    snapshot = worker.snapshot(fixture.document, 'a' * 64, fixture.context,
                        word=fixture.word if draft else None)
                self.assertEqual(snapshot['wordImages'], [])
                self.assertEqual(snapshot['wordImageTargets'], [{'ownerId': 'body',
                    'paragraphId': 'paragraph-0', 'canAdd': True, 'canMoveHere': True}])

    def test_snapshot_preserves_known_empty_targets_separately_from_unknown_catalog(self):
        from test_word_context import word_model
        for catalog, expected in [(None, None),
                (SimpleNamespace(snapshot=Mock(return_value=[]), snapshot_targets=Mock(return_value=[])), [])]:
            with self.subTest(expected=expected):
                word = word_model()
                word.image_catalog = lambda: catalog
                with patch.object(worker.office_word, 'paragraph_styles', return_value=[]):
                    snapshot = worker.snapshot(object(), 'a' * 64, word=word)
                self.assertEqual(snapshot['wordImageTargets'], expected)

    def test_target_catalog_failure_does_not_hide_a_verified_empty_image_catalog(self):
        from test_word_context import word_model
        word = word_model()
        catalog = SimpleNamespace(snapshot=Mock(return_value=[]),
            snapshot_targets=Mock(side_effect=ValueError('Controlled target capability failure')))
        word.image_catalog = lambda: catalog
        with patch.object(worker.office_word, 'paragraph_styles', return_value=[]):
            snapshot = worker.snapshot(object(), 'a' * 64, word=word)
        self.assertEqual(snapshot['wordImages'], [])
        self.assertIsNone(snapshot['wordImageTargets'])

    def test_word_mutations_require_exact_docx_source_binding_before_startup(self):
        for op in ('wordImageAdd', 'wordImageMove', 'wordImageDelete'):
            for extension in ('docx', 'doc', 'odt', 'pptx'):
                with self.subTest(op=op, extension=extension), TemporaryDirectory() as directory:
                    root = Path(directory)
                    source = root / ('source.' + extension)
                    source.write_bytes(b'controlled source-bound Word mutation')
                    request = {'mode': 'apply', 'sourcePath': str(source), 'sessionId': 'checked',
                        'operations': [{'op': op, 'id': 'photo'}]}
                    if extension != 'docx':
                        request['expectedSourceSha256'] = worker.digest(source)
                    with patch.object(worker, 'OfficeServer', side_effect=AssertionError('Must reject before startup')):
                        with self.assertRaises(ValueError):
                            worker.run_request(root, request, root / 'job')

    def test_word_mutation_dispatch_preserves_closed_operation_and_sealed_asset(self):
        asset = {'bytes': b'already verified sealed asset'}
        common = {'id': 'photo', 'ownerId': 'body', 'paragraphId': 'paragraph-0',
            'offsetUtf16': 1, 'expectedTextSha256': 'a' * 64}
        operations = [dict(common, op='wordImageAdd', assetId='asset', width=25.4, height=19.05),
            dict(common, op='wordImageMove'), {'op': 'wordImageDelete', 'id': 'photo'}]
        catalog = SimpleNamespace(add=Mock(), move=Mock(), delete=Mock())
        word = SimpleNamespace(image_catalog=lambda: catalog)
        with patch.object(worker, 'objects', return_value=('word', {}, {})), \
                patch.object(worker, 'uno', object(), create=True), \
                patch.object(worker.office_word_layout, 'WordDocument', return_value=word):
            worker.apply_operations(object(), operations, image_assets={'asset': asset})
        catalog.add.assert_called_once_with(operations[0], asset)
        catalog.move.assert_called_once_with(operations[1])
        catalog.delete.assert_called_once_with(operations[2])

    def test_word_mutation_unknown_fields_and_unsealed_assets_never_reach_catalog(self):
        common = {'op': 'wordImageAdd', 'id': 'photo', 'ownerId': 'body', 'paragraphId': 'paragraph-0',
            'offsetUtf16': 1, 'expectedTextSha256': 'a' * 64, 'assetId': 'asset', 'width': 25.4, 'height': 19.05}
        for operation, assets in [(dict(common, sourcePath='arbitrary.png'), {'asset': object()}),
                (dict(common), {}), ({'op': 'wordImageDelete', 'id': 'photo', 'assetId': 'foreign'}, {})]:
            with self.subTest(operation=operation):
                catalog = SimpleNamespace(add=Mock(), move=Mock(), delete=Mock())
                word = SimpleNamespace(image_catalog=lambda: catalog)
                with patch.object(worker, 'objects', return_value=('word', {}, {})), \
                        patch.object(worker, 'uno', object(), create=True), \
                        patch.object(worker.office_word_layout, 'WordDocument', return_value=word):
                    with self.assertRaises(ValueError):
                        worker.apply_operations(object(), [operation], image_assets=assets)
                catalog.add.assert_not_called()
                catalog.move.assert_not_called()
                catalog.delete.assert_not_called()

    def test_word_replacement_requires_its_inspected_source_hash_before_startup(self):
        for extension, expected in [('docx', None), ('doc', 'current')]:
            with self.subTest(extension=extension), TemporaryDirectory() as directory:
                root = Path(directory)
                source = root / ('source.' + extension)
                source.write_bytes(b'controlled pre-start source')
                request = {'mode': 'apply', 'sourcePath': str(source), 'sessionId': 'controlled',
                    'operations': [{'op': 'imageReplace', 'id': 'word-image-0', 'assetId': 'asset'}]}
                if expected:
                    request['expectedSourceSha256'] = worker.digest(source)
                with patch.object(worker, 'OfficeServer', side_effect=AssertionError('Must reject before startup')):
                    with self.assertRaises(ValueError):
                        worker.run_request(root, request, root / 'job')

    def test_dispatch_passes_the_verified_asset_to_the_word_native_catalog(self):
        asset = {'bytes': b'controlled already verified image'}
        catalog = SimpleNamespace(images={'word-image-0': object()}, replace=Mock())
        word = SimpleNamespace(image_catalog=lambda: catalog)
        with patch.object(worker, 'objects', return_value=('word', {}, {})), \
                patch.object(worker, 'uno', object(), create=True), \
                patch.object(worker.office_word_layout, 'WordDocument', return_value=word):
            worker.apply_operations(object(), [{'op': 'imageReplace', 'id': 'word-image-0', 'assetId': 'asset'}],
                image_assets={'asset': asset})
        catalog.replace.assert_called_once_with('word-image-0', asset)


if __name__ == '__main__':
    unittest.main()
