from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import office_worker as worker


class WorkerSlideDuplicateTest(unittest.TestCase):
    def setUp(self):
        temporary = TemporaryDirectory(prefix='piv-slide-duplicate-worker-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.source = self.root / 'source.pptx'
        self.source.write_bytes(b'Original fixture')
        self.directory = self.root / 'job'
        self.request = {
            'mode': 'apply', 'sourcePath': str(self.source), 'sessionId': 'duplicate',
            'expectedSourceSha256': worker.digest(self.source),
            'operations': [{'op': 'slideDuplicate', 'id': 'slide-1'}],
        }

    def run_worker(self, native_count=4, pdf_count=4):
        loaded, closed, cloned = [], [], []

        def duplicate(source, candidate, index, expected):
            self.assertEqual((source, index, expected), (
                self.source, 1, self.request['expectedSourceSha256']))
            self.assertFalse(candidate.exists())
            candidate.write_bytes(b'Candidate fixture')
            cloned.append(candidate)

        class Server:
            context = object()

            def __init__(self, runtime, directory):
                self.directory = directory

            def __enter__(self):
                return self

            def __exit__(self, *exception):
                return False

            def load(self, path, *, read_only=False):
                loaded.append((path, read_only))
                return SimpleNamespace(
                    path=path, close=lambda _: closed.append(path))

        def snapshot(document, digest, context, *, source_path):
            self.assertEqual(document.path, source_path)
            self.assertEqual(worker.digest(source_path), digest)
            return {'kind': 'presentation', 'sourceSha256': digest,
                    'slides': [{'id': f'slide-{index}'} for index in range(native_count)]}

        def render(document, pdf, kind):
            self.assertEqual((document.path, kind), (cloned[0], 'presentation'))
            pdf.write_bytes(b'Rendered PDF fixture')
            return pdf_count

        package = SimpleNamespace(duplicate_pptx=duplicate)
        self.calls = (loaded, closed, cloned)
        with patch.dict('sys.modules', {'office_presentation_duplicate': package}), \
                patch.object(worker, 'objects', return_value=('presentation', list(range(3)), {})), \
                patch.object(worker, 'apply_operations',
                    side_effect=ValueError('Unsupported Office operation')), \
                patch.object(worker, 'snapshot', side_effect=snapshot), \
                patch.object(worker, 'export_pdf', side_effect=render):
            return worker.run_request(
                self.root / 'runtime', self.request, self.directory, server_factory=Server)

    def test_saved_duplicate_uses_read_only_reopen_and_verified_pdf(self):
        result = self.run_worker()
        loaded, closed, cloned = self.calls
        self.assertEqual(loaded, [(self.source, True), (cloned[0], True)])
        self.assertEqual(closed, [self.source, cloned[0]])
        self.assertEqual(result['status'], 'saved')
        self.assertEqual(result['sessionId'], 'duplicate')
        self.assertEqual(result['sourcePath'], str(cloned[0]))
        self.assertEqual(result['sourceSha256'], worker.digest(cloned[0]))
        self.assertEqual(result['pdfSha256'], worker.digest(Path(result['pdfPath'])))
        self.assertEqual(result['pdfPageCount'], 4)
        self.assertEqual(self.source.read_bytes(), b'Original fixture')

    def test_no_saved_result_when_reopened_slide_or_pdf_page_count_disagrees(self):
        for native_count, pdf_count in ((3, 4), (4, 3)):
            with self.subTest(native_count=native_count, pdf_count=pdf_count):
                self.directory = self.root / f'job-{native_count}-{pdf_count}'
                with self.assertRaisesRegex(ValueError, 'verification'):
                    self.run_worker(native_count, pdf_count)
                loaded, closed, cloned = self.calls
                self.assertEqual(loaded, [(self.source, True), (cloned[0], True)])
                self.assertEqual(closed, [self.source, cloned[0]])

    def test_unpinned_mixed_or_noncanonical_requests_stop_before_file_writes(self):
        operation = self.request['operations'][0]
        for index, change in enumerate((
            {'expectedSourceSha256': None},
            {'operations': [operation, {'op': 'slideMove', 'id': 'slide-1', 'index': 0}]},
            {'operations': [dict(operation, id='slide-01')]},
            {'operations': [dict(operation, path='elsewhere.pptx')]},
            {'imageAssets': [{'id': 'alien'}]},
            {'includeDraftSnapshot': True},
        )):
            with self.subTest(change=change):
                self.directory = self.root / f'job-rejected-{index}'
                baseline = self.request
                self.request = dict(baseline, **change)
                try:
                    with self.assertRaisesRegex(ValueError, 'Slide duplication'):
                        self.run_worker()
                    self.assertEqual(self.calls, ([], [], []))
                    self.assertFalse(self.directory.exists())
                finally:
                    self.request = baseline
