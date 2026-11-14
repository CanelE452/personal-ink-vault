from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import Mock, patch

import office_worker as worker


class FakeDocument:
    def __init__(self, events, close_error, service='com.sun.star.presentation.PresentationDocument'):
        self.events = events
        self.close_error = close_error
        self.service = service
        self.close_calls = []

    def supportsService(self, service):
        return self.service == service

    def close(self, ownership):
        self.events.append('document-close')
        self.close_calls.append(ownership)
        if self.close_error is not None:
            raise self.close_error


class FakeServer:
    def __init__(self, directory, document, events):
        self.directory, self.document, self.events = directory, document, events
        self.context = object()
        self.loaded = []
        self.loaded_bytes = []
        self.exit_error = None
        self.directory_existed_at_exit = False
        self.copy_existed_at_exit = False

    def __enter__(self):
        self.events.append('server-enter')
        return self

    def load(self, path):
        self.events.append('server-load')
        self.loaded.append(Path(path))
        self.loaded_bytes.append(Path(path).read_bytes())
        return self.document

    def __exit__(self, error_type, error, traceback):
        self.events.append('server-exit')
        self.exit_error = error
        self.directory_existed_at_exit = self.directory.is_dir()
        self.copy_existed_at_exit = bool(self.loaded) and self.loaded[0].is_file()
        return False


class WorkerInspectCleanupTest(unittest.TestCase):
    def setUp(self):
        owned = TemporaryDirectory(prefix='worker-inspect-cleanup-')
        self.addCleanup(owned.cleanup)
        self.root = Path(owned.name)
        self.source = self.root / 'original.pptx'
        self.original = b'immutable original; the fake loader does not parse this package'
        self.source.write_bytes(self.original)
        self.original_mtime = self.source.stat().st_mtime_ns
        self.job = self.root / 'owned-inspect-job'
        self.expected_snapshot = {'kind': 'presentation',
            'sourceSha256': worker.digest(self.source), 'paragraphs': [],
            'tables': [], 'slides': []}

    def inspect(self, primary_error=None, close_error=None):
        events = []
        document = FakeDocument(events, close_error)
        server = FakeServer(self.job, document, events)

        def take_snapshot(*args, **kwargs):
            events.append('snapshot')
            if primary_error is not None:
                raise primary_error
            return self.expected_snapshot

        snapshot = Mock(side_effect=take_snapshot)
        result, caught = None, None
        with patch.object(worker, 'OfficeServer', return_value=server), \
                patch.object(worker, 'snapshot', snapshot):
            try:
                result = worker.run_request(self.root / 'unused-runtime',
                    {'mode': 'inspect', 'sourcePath': str(self.source)}, self.job)
            except BaseException as error:
                caught = error
        self.assertEqual(document.close_calls, [True])
        self.assertEqual(events.count('server-enter'), 1)
        self.assertEqual(events.count('server-exit'), 1)
        self.assertLess(events.index('document-close'), events.index('server-exit'))
        self.assertEqual(len(server.loaded), 1)
        self.assertNotEqual(server.loaded[0], self.source)
        self.assertEqual(server.loaded[0].parent, self.job)
        self.assertEqual(server.loaded_bytes, [self.original])
        self.assertTrue(server.directory_existed_at_exit)
        self.assertTrue(server.copy_existed_at_exit)
        self.assertFalse(self.job.exists())
        self.assertEqual(self.source.read_bytes(), self.original)
        self.assertEqual(self.source.stat().st_mtime_ns, self.original_mtime)
        snapshot.assert_called_once()
        self.assertIs(snapshot.call_args.args[0], document)
        return result, caught, server

    def primary_failure(self):
        cause = ValueError('controlled snapshot root cause')
        primary = RuntimeError('controlled snapshot primary failure')
        primary.__cause__ = cause
        primary.add_note('preexisting snapshot note')
        return primary, cause

    def test_snapshot_failure_survives_close_failure_with_original_cause_and_cleanup_note(self):
        primary, cause = self.primary_failure()
        closing = RuntimeError('controlled close failure')
        result, caught, server = self.inspect(primary, closing)
        self.assertIsNone(result)
        self.assertIs(caught, primary)
        self.assertIs(caught.__cause__, cause)
        self.assertIs(server.exit_error, primary)
        notes = getattr(caught, '__notes__', [])
        self.assertIn('preexisting snapshot note', notes)
        self.assertTrue(any('controlled close failure' in note for note in notes), notes)

    def test_successful_snapshot_cannot_return_success_when_document_close_fails(self):
        closing = RuntimeError('controlled close failure')
        result, caught, server = self.inspect(close_error=closing)
        self.assertIsNone(result)
        self.assertIs(caught, closing)
        self.assertIs(server.exit_error, closing)

    def test_successful_snapshot_and_close_keep_the_existing_result_and_cleanup(self):
        result, caught, server = self.inspect()
        self.assertIsNone(caught)
        self.assertIsNone(server.exit_error)
        self.assertEqual(result, {'snapshot': self.expected_snapshot,
            'engineVersion': 'LibreOffice26.8.2.2'})

    def test_cross_family_legacy_preview_stops_before_snapshot_and_pdf(self):
        source = self.root / 'misnamed.doc'
        source.write_bytes(self.original)
        events = []
        document = FakeDocument(events, None)
        server = FakeServer(self.job, document, events)
        with patch.object(worker, 'snapshot') as snapshot, patch.object(worker, 'export_pdf') as export_pdf:
            with self.assertRaises(worker.DocumentFamilyMismatch):
                worker.run_request(
                    self.root / 'unused-runtime',
                    {'mode': 'inspect', 'sourcePath': str(source), 'preview': True},
                    self.job,
                    server_factory=lambda *_: server,
                )
            snapshot.assert_not_called()
            export_pdf.assert_not_called()
        self.assertEqual(document.close_calls, [True])
        self.assertFalse(self.job.exists())
        self.assertEqual(source.read_bytes(), self.original)

    def test_save_reopen_with_wrong_family_discards_private_output_before_pdf(self):
        source = self.root / 'original.doc'
        source.write_bytes(self.original)
        events = []
        original = FakeDocument(events, None, 'com.sun.star.text.TextDocument')
        wrong = FakeDocument(events, None)
        server = FakeServer(self.job, original, events)
        edited = self.job / 'edited.doc'
        original.storeToURL = Mock(side_effect=lambda *_: edited.write_bytes(b'wrong family output'))
        server.load = Mock(side_effect=[original, wrong])

        def apply(document, operations, assets, context, state, **kwargs):
            state.update(presentation=None, word=None)
            return 'word', [], []

        with patch.object(worker, 'apply_operations', side_effect=apply), \
                patch.object(worker, 'prop'), patch.object(worker, 'export_pdf') as export_pdf:
            with self.assertRaises(worker.DocumentFamilyMismatch):
                worker.run_request(self.root / 'unused-runtime', {
                    'mode': 'apply', 'sourcePath': str(source), 'sessionId': 'test',
                    'operations': [],
                }, self.job, server_factory=lambda *_: server)
            export_pdf.assert_not_called()
        original.storeToURL.assert_called_once()
        self.assertEqual(original.close_calls, [True])
        self.assertEqual(wrong.close_calls, [True])
        self.assertFalse(edited.exists())
        self.assertEqual(source.read_bytes(), self.original)

    def test_snapshot_failure_without_close_failure_remains_the_identical_exception(self):
        primary, cause = self.primary_failure()
        result, caught, server = self.inspect(primary_error=primary)
        self.assertIsNone(result)
        self.assertIs(caught, primary)
        self.assertIs(caught.__cause__, cause)
        self.assertIs(server.exit_error, primary)
        self.assertIn('preexisting snapshot note', caught.__notes__)

    def test_handled_caller_exception_does_not_absorb_a_new_inspect_close_failure(self):
        outer = ValueError('already handled caller failure')
        closing = RuntimeError('controlled close failure')
        try:
            raise outer
        except ValueError:
            result, caught, server = self.inspect(close_error=closing)
        self.assertIsNone(result)
        self.assertIs(caught, closing)
        self.assertIs(server.exit_error, closing)
        self.assertEqual(getattr(outer, '__notes__', []), [])


if __name__ == '__main__':
    unittest.main()
