import hashlib
import importlib
import io
import json
import os
import ctypes
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch
import zipfile


SESSION = '7c9d8e12-a56b-4f30-b901-672a8d9c50e1'
NONCE = '24eb9346-2aa0-4eab-bde5-af9b164d5608'
NEXT_NONCE = '881b9765-593d-473d-86f5-0c695d2ac184'
CRASH_NONCE = 'ca2c29e3-69bf-4c42-8b52-5567faf5e948'
PDF = b'%PDF-1.4\nfixed isolated exporter boundary\n%%EOF\n'


def sha(value):
    return hashlib.sha256(value).hexdigest()


def office_bytes(text):
    stream = io.BytesIO()
    with zipfile.ZipFile(stream, 'w') as archive:
        archive.writestr(zipfile.ZipInfo('payload.txt', date_time=(2020, 1, 1, 0, 0, 0)), text)
    return stream.getvalue()


class FakeLease:
    def __init__(self, events, failure=None):
        self.events, self.failure = events, failure

    def __enter__(self):
        self.events.append('lease-enter')
        if self.failure:
            raise self.failure
        return self

    def __exit__(self, *_):
        self.events.append('lease-exit')


class FakeLifetime:
    def __init__(self, events, steps):
        self.events, self.steps = events, list(steps)
        self.cancelled = False
        self.phases = []

    def __enter__(self):
        self.events.append('parent-enter')
        return self

    def __exit__(self, *_):
        self.events.append('parent-exit')

    def stage(self, name, seconds):
        self.phases.append((name, seconds))

    def check(self):
        return None

    def wait(self, _seconds):
        if not self.steps:
            raise AssertionError('The session kept waiting after all controlled native steps')
        self.steps.pop(0)()


class FakeDocument:
    def __init__(self, path, events, *, kind='presentation'):
        self.path, self.events, self.kind = path, events, kind
        self.uri = path.as_uri()
        self.closed = False
        self.close_listener = self.event_listener = None

    def addCloseListener(self, listener):
        self.close_listener = listener

    def addDocumentEventListener(self, listener):
        self.event_listener = listener

    def removeCloseListener(self, _listener):
        pass

    def removeDocumentEventListener(self, _listener):
        pass

    def getURL(self):
        if self.closed:
            raise RuntimeError('controlled disposed document')
        return self.uri

    def supportsService(self, name):
        return name == ('com.sun.star.presentation.PresentationDocument'
            if self.kind == 'presentation' else 'com.sun.star.text.TextDocument')

    def isReadonly(self):
        return False

    def getDrawPages(self):
        return SimpleNamespace(getCount=lambda: 1)

    def save(self, data):
        self.path.write_bytes(data)
        self.events.append('native-save')
        self.event_listener.documentEventOccured(SimpleNamespace(EventName='OnSaveDone', Source=self))

    def save_as(self, path):
        self.uri = path.as_uri()
        self.event_listener.documentEventOccured(SimpleNamespace(EventName='OnSaveAsDone', Source=self))

    def native_close(self, *, notify=True):
        if notify:
            self.close_listener.queryClosing(SimpleNamespace(Source=self), True)
            self.close_listener.notifyClosing(SimpleNamespace(Source=self))
        self.closed = True
        self.close_listener.disposing(SimpleNamespace(Source=self))
        self.events.append('native-close' if notify else 'native-dispose-only')

    def close(self, _ownership):
        self.closed = True
        self.events.append('validator-close')


class FakeServer:
    def __init__(self, owner, directory, interactive):
        self.owner, self.directory, self.interactive = owner, directory, interactive
        self.document = None
        self.profile = directory / ('piv-lo-gui' if interactive else 'piv-lo-validator')
        self.process = SimpleNamespace(exit_code=lambda: None, pid=123)
        self.desktop = SimpleNamespace(getComponents=self.components)

    def __enter__(self):
        self.owner.events.append('gui-enter' if self.interactive else 'validator-enter')
        return self

    def __exit__(self, *_):
        self.owner.events.append('gui-exit' if self.interactive else 'validator-exit')

    def load(self, path, read_only=False):
        self.owner.events.append(('load', self.interactive, read_only, Path(path)))
        kind = 'presentation' if Path(path).suffix.lower() in ('.ppt', '.pptx', '.odp') else 'word'
        self.document = FakeDocument(Path(path), self.owner.events, kind=kind)
        if self.interactive:
            self.owner.document = self.document
        else:
            self.owner.validation_bytes.append(Path(path).read_bytes())
        return self.document

    def components(self):
        remaining = int(self.document is not None and not self.document.closed) + self.owner.other_documents
        items = [object()] * remaining
        return SimpleNamespace(createEnumeration=lambda: SimpleNamespace(
            hasMoreElements=lambda: bool(items), nextElement=lambda: items.pop()))

    def release_profile(self):
        self.owner.events.append('gui-profile-release')


class InteractiveBackendTest(unittest.TestCase):
    def backend(self):
        try:
            return importlib.import_module('office_interactive')
        except ModuleNotFoundError as error:
            if error.name != 'office_interactive':
                raise
            self.fail('The interactive Office backend has not been implemented')

    def fixture(self):
        temporary = tempfile.TemporaryDirectory(prefix='piv-interactive-test-')
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        session = root / SESSION
        launch = session / ('interactive-' + NONCE)
        launch.mkdir(parents=True)
        working = session / 'original.pptx'
        original = office_bytes('original 한글 😀')
        working.write_bytes(original)
        parent = root / 'parent.exe'
        parent.write_bytes(b'MZ fixed parent boundary')
        data = {'version': 1, 'sessionId': SESSION, 'controlNonce': NONCE,
            'workingFileName': working.name, 'inputSourceSha256': sha(original),
            'expectedWorkingSha256': sha(original), 'workingLength': len(original),
            'parentProcessId': os.getpid(), 'parentExecutablePath': str(parent)}
        request = launch / 'request.json'
        request.write_text(json.dumps(data), encoding='utf-8')
        return SimpleNamespace(root=root, session=session, launch=launch, working=working,
            request=request, data=data, original=original)

    def setup_flow(self, state, actions):
        self.events, self.document, self.other_documents = [], None, 0
        self.validation_bytes, self.servers = [], []
        self.lifetime = FakeLifetime(self.events, [lambda action=action: action(self, state) for action in actions])

        def factory(_runtime, directory, *, interactive=False):
            server = FakeServer(self, Path(directory), interactive)
            self.servers.append(server)
            return server

        def export(document, path, kind):
            self.events.append(('export', kind))
            Path(path).write_bytes(PDF)
            return 1

        return dict(server_factory=factory, lifetime_factory=lambda _request: self.lifetime,
            lease_factory=lambda _request: FakeLease(self.events), listener_factory=lambda value: value), export

    def run_flow(self, backend, state, actions, **options):
        arguments, exporter = self.setup_flow(state, actions)
        arguments.update(options)
        with patch.object(backend.office, 'export_pdf', side_effect=exporter), \
                patch.object(backend, 'pdf_page_count', return_value=1):
            return backend.run_session(state.root / 'runtime', state.request, **arguments)

    def close_only(self, owner, state):
        owner.document.native_close()

    def save_close(self, owner, state):
        owner.document.save(office_bytes('saved 한글 😀'))
        owner.document.native_close()

    def test_closed_request_binds_the_actual_working_file_to_the_session_and_launch(self):
        backend, state = self.backend(), self.fixture()
        request = backend.read_request(state.request)
        self.assertEqual(request.working, state.working)
        self.assertEqual(request.launch, state.launch)
        self.assertEqual(request.session, state.session)
        self.assertEqual(request.data, state.data)

    def test_unknown_fields_boolean_versions_and_invalid_parent_ids_are_rejected_before_gui(self):
        backend, state = self.backend(), self.fixture()
        mutations = [dict(extra=True), dict(version=True), dict(parentProcessId=True),
            dict(parentProcessId=0), dict(parentProcessId=2 ** 32), dict(workingLength=True)]
        for changes in mutations:
            with self.subTest(changes=changes):
                value = {**state.data, **changes}
                state.request.write_text(json.dumps(value), encoding='utf-8')
                with self.assertRaises(backend.InteractiveError):
                    backend.read_request(state.request)

    def test_working_names_nonce_roots_hashes_and_lengths_are_not_accepted_by_convention(self):
        backend, state = self.backend(), self.fixture()
        for changes in (dict(workingFileName='../original.pptx'), dict(controlNonce=NEXT_NONCE),
                dict(sessionId=NEXT_NONCE), dict(expectedWorkingSha256='0' * 64),
                dict(workingLength=len(state.original) + 1), dict(parentExecutablePath='relative.exe')):
            with self.subTest(changes=changes):
                state.request.write_text(json.dumps({**state.data, **changes}), encoding='utf-8')
                with self.assertRaises(backend.InteractiveError):
                    backend.read_request(state.request)

    def test_duplicate_json_keys_and_over_budget_requests_are_rejected(self):
        backend, state = self.backend(), self.fixture()
        text = json.dumps(state.data)
        state.request.write_text(text[:-1] + ',"version":1}', encoding='utf-8')
        with self.assertRaises(backend.InteractiveError):
            backend.read_request(state.request)
        state.request.write_bytes(b' ' * (64 * 1024 + 1))
        with self.assertRaises(backend.InteractiveError):
            backend.read_request(state.request)

    def test_normal_close_without_saved_changes_does_not_create_a_new_edition_or_pdf(self):
        backend, state = self.backend(), self.fixture()
        result = self.run_flow(backend, state, [self.close_only])
        self.assertEqual(result, {'version': 1, 'sessionId': SESSION, 'controlNonce': NONCE,
            'inputSourceSha256': sha(state.original), 'status': 'cancelled',
            'engineVersion': 'LibreOffice26.8.2.2'})
        self.assertEqual(state.working.read_bytes(), state.original)
        self.assertFalse((state.launch / 'preview.pdf').exists())
        self.assertEqual([server.interactive for server in self.servers], [True])

    def test_saved_private_working_file_is_reopened_read_only_and_exported_as_one_bound_pair(self):
        backend, state = self.backend(), self.fixture()
        result = self.run_flow(backend, state, [self.save_close])
        saved = office_bytes('saved 한글 😀')
        self.assertEqual(result['status'], 'saved')
        self.assertEqual(result['inputSourceSha256'], sha(state.original))
        self.assertEqual(result['controlNonce'], NONCE)
        self.assertEqual(Path(result['sourcePath']), state.launch / 'edited.pptx')
        self.assertEqual(Path(result['pdfPath']), state.launch / 'preview.pdf')
        self.assertEqual(Path(result['sourcePath']).read_bytes(), saved)
        self.assertEqual(result['sourceSha256'], sha(saved))
        self.assertEqual(result['pdfSha256'], sha(PDF))
        self.assertEqual(result['pdfPageCount'], 1)
        self.assertEqual(self.validation_bytes, [saved])
        self.assertEqual([server.interactive for server in self.servers], [True, False])
        self.assertIn(('load', False, True, state.launch / 'edited.pptx'), self.events)
        self.assertEqual(json.loads((state.launch / 'response.json').read_text(encoding='utf-8')), result)
        editing = [seconds for name, seconds in self.lifetime.phases if name == 'editing']
        self.assertEqual(editing, [None])
        self.assertTrue(all(seconds is not None and seconds > 0 for name, seconds in self.lifetime.phases if name != 'editing'))
        self.assertLess(self.events.index('lease-enter'), self.events.index('gui-enter'))
        self.assertLess(self.events.index('gui-exit'), self.events.index('validator-enter'))

    def test_save_then_discard_unsaved_memory_keeps_only_the_last_saved_file(self):
        backend, state = self.backend(), self.fixture()

        def action(owner, current):
            owner.document.save(office_bytes('saved first'))
            owner.document.unsaved_memory = 'discarded second'
            owner.document.native_close()

        result = self.run_flow(backend, state, [action])
        self.assertEqual(Path(result['sourcePath']).read_bytes(), office_bytes('saved first'))

    def test_cancelled_publication_waits_for_native_close_and_preserves_the_last_saved_working_copy(self):
        backend, state = self.backend(), self.fixture()

        def cancel(owner, current):
            owner.document.save(office_bytes('saved but not published'))
            owner.lifetime.cancelled = True
            owner.events.append('publication-cancelled')

        result = self.run_flow(backend, state, [cancel, self.close_only])
        self.assertEqual(result['status'], 'cancelled')
        self.assertEqual(state.working.read_bytes(), office_bytes('saved but not published'))
        self.assertLess(self.events.index('publication-cancelled'), self.events.index('native-close'))
        self.assertEqual([server.interactive for server in self.servers], [True])

    def test_closing_bound_document_does_not_kill_another_document_opened_in_the_owned_gui(self):
        backend, state = self.backend(), self.fixture()

        def first(owner, current):
            owner.other_documents = 1
            owner.document.native_close()

        def second(owner, current):
            owner.events.append('other-document-closed-by-user')
            owner.other_documents = 0

        self.run_flow(backend, state, [first, second])
        self.assertLess(self.events.index('other-document-closed-by-user'), self.events.index('gui-exit'))

    def test_disposal_without_normal_close_notification_is_not_a_successful_save(self):
        backend, state = self.backend(), self.fixture()

        def action(owner, current):
            owner.document.save(office_bytes('saved before engine crash'))
            owner.document.native_close(notify=False)

        with self.assertRaises(backend.InteractiveError) as error:
            self.run_flow(backend, state, [action])
        self.assertEqual(error.exception.code, 'interactive_closed_unexpectedly')
        self.assertEqual([server.interactive for server in self.servers], [True])
        self.assertNotIn('gui-profile-release', self.events)

    def test_foreign_working_bytes_after_native_save_are_not_published(self):
        backend, state = self.backend(), self.fixture()

        def action(owner, current):
            owner.document.save(office_bytes('real native save'))
            current.working.write_bytes(office_bytes('foreign replacement'))
            owner.document.native_close()

        with self.assertRaises(backend.InteractiveError) as error:
            self.run_flow(backend, state, [action])
        self.assertEqual(error.exception.code, 'interactive_working_changed')
        self.assertFalse((state.launch / 'edited.pptx').exists())
        self.assertEqual(state.working.read_bytes(), office_bytes('foreign replacement'))

    def test_save_as_outside_the_session_is_not_read_deleted_or_automatically_adopted(self):
        backend, state = self.backend(), self.fixture()
        outside = state.root / 'user-save-as.pptx'
        external = office_bytes('user owned Save As')
        outside.write_bytes(external)

        def action(owner, current):
            owner.document.save_as(outside)
            owner.document.native_close()

        with self.assertRaises(backend.InteractiveError) as error:
            self.run_flow(backend, state, [action])
        self.assertEqual(error.exception.code, 'interactive_save_as_unbound')
        self.assertEqual(outside.read_bytes(), external)
        self.assertEqual(state.working.read_bytes(), state.original)
        self.assertEqual(self.validation_bytes, [])

    def test_busy_session_lease_rejects_before_any_gui_or_file_mutation(self):
        backend, state = self.backend(), self.fixture()
        failure = backend.InteractiveError('interactive_session_busy')
        with self.assertRaises(backend.InteractiveError) as error:
            self.run_flow(backend, state, [], lease_factory=lambda _: FakeLease(self.events, failure))
        self.assertEqual(error.exception.code, failure.code)
        self.assertEqual(self.servers, [])
        self.assertEqual(state.working.read_bytes(), state.original)

    def test_preexisting_output_is_preserved_instead_of_becoming_the_native_candidate(self):
        backend, state = self.backend(), self.fixture()
        candidate = state.launch / 'edited.pptx'
        foreign = office_bytes('foreign output')
        candidate.write_bytes(foreign)
        with self.assertRaises(backend.InteractiveError):
            self.run_flow(backend, state, [self.save_close])
        self.assertEqual(candidate.read_bytes(), foreign)

    def test_completed_saved_response_is_revalidated_and_reused_without_opening_a_second_gui(self):
        backend, state = self.backend(), self.fixture()
        original = self.run_flow(backend, state, [self.save_close])
        next_launch = state.session / ('interactive-' + NEXT_NONCE)
        next_launch.mkdir()
        next_data = {**state.data, 'controlNonce': NEXT_NONCE,
            'expectedWorkingSha256': sha(state.working.read_bytes()),
            'workingLength': state.working.stat().st_size}
        next_request = next_launch / 'request.json'
        next_request.write_text(json.dumps(next_data), encoding='utf-8')
        next_state = SimpleNamespace(**{**vars(state), 'request': next_request, 'launch': next_launch, 'data': next_data})
        result = self.run_flow(backend, next_state, [])
        self.assertEqual(result['status'], 'saved')
        self.assertEqual(result['controlNonce'], NEXT_NONCE)
        self.assertEqual(result['sourceSha256'], original['sourceSha256'])
        self.assertEqual(result['pdfSha256'], original['pdfSha256'])
        self.assertEqual(Path(result['sourcePath']).parent, next_launch)
        self.assertEqual(self.servers, [])

    def test_corrupt_saved_receipt_is_not_used_as_authority_for_recovery(self):
        backend, state = self.backend(), self.fixture()
        original = self.run_flow(backend, state, [self.save_close])
        Path(original['pdfPath']).write_bytes(b'foreign PDF bytes')
        next_launch = state.session / ('interactive-' + NEXT_NONCE)
        next_launch.mkdir()
        next_request = next_launch / 'request.json'
        next_request.write_text(json.dumps({**state.data, 'controlNonce': NEXT_NONCE,
            'expectedWorkingSha256': sha(state.working.read_bytes()),
            'workingLength': state.working.stat().st_size}), encoding='utf-8')
        next_state = SimpleNamespace(**{**vars(state), 'request': next_request, 'launch': next_launch})
        with self.assertRaises(backend.InteractiveError):
            self.run_flow(backend, next_state, [])
        self.assertEqual(self.servers, [])
        self.assertEqual(Path(original['pdfPath']).read_bytes(), b'foreign PDF bytes')

    def test_duplicate_exact_request_reuses_the_same_terminal_response_and_does_not_clobber_it(self):
        backend, state = self.backend(), self.fixture()
        result = self.run_flow(backend, state, [self.save_close])
        response = (state.launch / 'response.json').read_bytes()
        repeated = self.run_flow(backend, state, [])
        self.assertEqual(repeated, result)
        self.assertEqual((state.launch / 'response.json').read_bytes(), response)
        self.assertEqual(self.servers, [])

    def test_a_previous_closed_error_receipt_allows_resuming_the_retained_working_file(self):
        backend, state = self.backend(), self.fixture()
        previous_error = {'version': 1, 'sessionId': SESSION, 'controlNonce': NONCE,
            'inputSourceSha256': sha(state.original), 'status': 'error',
            'engineVersion': 'LibreOffice26.8.2.2',
            'error': {'code': 'interactive_operation_failed', 'message': 'Private edit retained.'}}
        previous_bytes = json.dumps(previous_error).encode('utf-8')
        (state.launch / 'response.json').write_bytes(previous_bytes)
        saved = office_bytes('last native save before interrupted finalization')
        state.working.write_bytes(saved)
        next_launch = state.session / ('interactive-' + NEXT_NONCE)
        next_launch.mkdir()
        next_request = next_launch / 'request.json'
        next_request.write_text(json.dumps({**state.data, 'controlNonce': NEXT_NONCE,
            'expectedWorkingSha256': sha(saved), 'workingLength': len(saved)}), encoding='utf-8')
        resumed = SimpleNamespace(**{**vars(state), 'request': next_request, 'launch': next_launch})
        result = self.run_flow(backend, resumed, [self.close_only])
        self.assertEqual(result['status'], 'saved')
        self.assertEqual(Path(result['sourcePath']).read_bytes(), saved)
        self.assertEqual((state.launch / 'response.json').read_bytes(), previous_bytes)

    def test_error_receipts_with_foreign_fields_are_not_silently_skipped_during_resume(self):
        backend, state = self.backend(), self.fixture()
        invalid = {'version': 1, 'sessionId': SESSION, 'controlNonce': NONCE,
            'inputSourceSha256': sha(state.original), 'status': 'error',
            'engineVersion': 'LibreOffice26.8.2.2',
            'error': {'code': 'interactive_operation_failed', 'message': 'retained', 'sourcePath': 'foreign'}}
        raw = json.dumps(invalid).encode('utf-8')
        (state.launch / 'response.json').write_bytes(raw)
        with self.assertRaises(backend.InteractiveError):
            self.run_flow(backend, state, [])
        self.assertEqual((state.launch / 'response.json').read_bytes(), raw)
        self.assertEqual(self.servers, [])

    def retry_request(self, state):
        launch = state.session / ('interactive-' + NEXT_NONCE)
        launch.mkdir()
        request = launch / 'request.json'
        data = {**state.data, 'controlNonce': NEXT_NONCE,
            'expectedWorkingSha256': sha(state.working.read_bytes()),
            'workingLength': state.working.stat().st_size}
        request.write_text(json.dumps(data), encoding='utf-8')
        return SimpleNamespace(**{**vars(state), 'launch': launch, 'request': request, 'data': data})

    def test_empty_unpublished_launch_is_preserved_without_blocking_saved_recovery(self):
        backend, state = self.backend(), self.fixture()
        original = self.run_flow(backend, state, [self.save_close])
        original_receipt = (state.launch / 'response.json').read_bytes()
        unpublished = state.session / ('interactive-' + CRASH_NONCE)
        unpublished.mkdir()
        resumed = self.retry_request(state)
        result = self.run_flow(backend, resumed, [])
        self.assertEqual(result['status'], 'saved')
        self.assertEqual(result['sourceSha256'], original['sourceSha256'])
        self.assertEqual(result['pdfSha256'], original['pdfSha256'])
        self.assertEqual(self.servers, [])
        self.assertTrue(unpublished.is_dir())
        self.assertEqual(list(unpublished.iterdir()), [])
        self.assertEqual((state.launch / 'response.json').read_bytes(), original_receipt)

    def test_only_unpublished_request_pending_is_preserved_without_becoming_recovery_authority(self):
        backend = self.backend()
        for partial in (b'', b'{"version":1,"sessionId":"unfinished', b'\xff\x00not published JSON'):
            with self.subTest(partial=partial):
                state = self.fixture()
                original = self.run_flow(backend, state, [self.save_close])
                unpublished = state.session / ('interactive-' + CRASH_NONCE)
                unpublished.mkdir()
                pending = unpublished / 'request.pending'
                pending.write_bytes(partial)
                resumed = self.retry_request(state)
                result = self.run_flow(backend, resumed, [])
                self.assertEqual(result['sourceSha256'], original['sourceSha256'])
                self.assertEqual(result['pdfSha256'], original['pdfSha256'])
                self.assertEqual(self.servers, [])
                self.assertEqual(list(unpublished.iterdir()), [pending])
                self.assertEqual(pending.read_bytes(), partial)

    def test_unpublished_launches_do_not_authorize_working_bytes_that_differ_from_the_captured_original(self):
        backend = self.backend()
        for pending in (False, True):
            with self.subTest(pending=pending):
                state = self.fixture()
                unpublished = state.session / ('interactive-' + CRASH_NONCE)
                unpublished.mkdir()
                if pending:
                    (unpublished / 'request.pending').write_bytes(b'{"version":1')
                foreign = office_bytes('not attested by any published request')
                state.working.write_bytes(foreign)
                state.request.write_text(json.dumps({**state.data,
                    'expectedWorkingSha256': sha(foreign), 'workingLength': len(foreign)}), encoding='utf-8')
                with self.assertRaises(backend.InteractiveError):
                    backend.read_request(state.request)
                self.assertEqual(state.working.read_bytes(), foreign)
                self.assertTrue(unpublished.is_dir())

    def test_nonempty_foreign_or_malformed_final_launch_evidence_remains_a_strict_rejection(self):
        backend = self.backend()
        cases = ('foreign', 'request-pending-with-extra', 'request-pending-directory',
            'malformed-final-request', 'response-without-request', 'foreign-final-request')
        for case in cases:
            with self.subTest(case=case):
                state = self.fixture()
                self.run_flow(backend, state, [self.save_close])
                invalid = state.session / ('interactive-' + CRASH_NONCE)
                invalid.mkdir()
                if case == 'foreign':
                    (invalid / 'keep-user-bytes.bin').write_bytes(b'PRESERVE')
                elif case == 'request-pending-with-extra':
                    (invalid / 'request.pending').write_bytes(b'{"version":1')
                    (invalid / 'keep-user-bytes.bin').write_bytes(b'PRESERVE')
                elif case == 'request-pending-directory':
                    (invalid / 'request.pending').mkdir()
                elif case == 'malformed-final-request':
                    (invalid / 'request.json').write_bytes(b'{"version":1,')
                elif case == 'response-without-request':
                    (invalid / 'response.json').write_bytes(b'{"status":"saved"}')
                else:
                    (invalid / 'request.json').write_text(json.dumps({**state.data,
                        'controlNonce': CRASH_NONCE, 'inputSourceSha256': '0' * 64}), encoding='utf-8')
                files = {path.name: path.read_bytes() for path in invalid.iterdir() if path.is_file()}
                directories = {path.name for path in invalid.iterdir() if path.is_dir()}
                resumed = self.retry_request(state)
                with self.assertRaises(backend.InteractiveError):
                    self.run_flow(backend, resumed, [])
                self.assertEqual(self.servers, [])
                self.assertEqual({path.name: path.read_bytes() for path in invalid.iterdir() if path.is_file()}, files)
                self.assertEqual({path.name for path in invalid.iterdir() if path.is_dir()}, directories)


class InteractiveLifetimeTest(unittest.TestCase):
    def module(self):
        return importlib.import_module('office_interactive_lifetime')

    def request(self):
        value = InteractiveBackendTest.fixture(self)
        return SimpleNamespace(data=value.data, launch=value.launch, session=value.session)

    def fake_parent_kernel(self, actual_path='C:\\piv\\parent.exe', *, query_succeeds=True):
        def query(_handle, _flags, buffer, _size):
            buffer.value = actual_path
            return query_succeeds

        return SimpleNamespace(OpenProcess=Mock(return_value=101),
            QueryFullProcessImageNameW=Mock(side_effect=query),
            WaitForSingleObject=Mock(side_effect=[258, 0]), CloseHandle=Mock(),
            TerminateProcess=Mock(side_effect=AssertionError('Never terminate a parent or a PID')))

    def test_parent_identity_uses_one_readonly_handle_and_cannot_follow_pid_reuse(self):
        module = self.module()
        kernel = self.fake_parent_kernel()
        with patch.object(module, 'kernel', return_value=kernel):
            parent = module.ParentProcess(1234, 'C:\\piv\\parent.exe')
            self.assertTrue(parent.alive())
            self.assertFalse(parent.alive())
            parent.close()
            parent.close()
        kernel.OpenProcess.assert_called_once_with(0x100000 | 0x1000, False, 1234)
        self.assertEqual(kernel.WaitForSingleObject.call_args_list,
            [unittest.mock.call(101, 0), unittest.mock.call(101, 0)])
        kernel.QueryFullProcessImageNameW.assert_called_once()
        kernel.CloseHandle.assert_called_once_with(101)
        kernel.TerminateProcess.assert_not_called()

    def test_parent_image_mismatch_and_failed_query_close_the_only_acquired_handle(self):
        module = self.module()
        for kernel in (self.fake_parent_kernel('C:\\other\\parent.exe'),
                self.fake_parent_kernel(query_succeeds=False)):
            with self.subTest(query=kernel.QueryFullProcessImageNameW), \
                    patch.object(module, 'kernel', return_value=kernel), \
                    patch.object(module.ctypes, 'get_last_error', return_value=5):
                with self.assertRaises((ValueError, OSError)):
                    module.ParentProcess(1234, 'C:\\piv\\parent.exe')
                kernel.CloseHandle.assert_called_once_with(101)
                kernel.WaitForSingleObject.assert_not_called()
                kernel.TerminateProcess.assert_not_called()

    def lease_kernel(self, module, *, lock_error=False, attributes=0, links=1, size=0):
        handles, events = {}, []

        def create(path, access, sharing, _security, creation, flags, _template):
            events.append(('open', Path(path).name, access, sharing, creation, flags))
            if Path(path).name == 'interactive-editor.lock' and lock_error:
                return ctypes.c_void_p(-1).value
            handle = 200 + len(handles)
            handles[handle] = Path(path).name == 'interactive-editor.lock'
            return handle

        def information(handle, pointer):
            value = ctypes.cast(pointer, ctypes.POINTER(module._FileInfo)).contents
            value.attributes = attributes if handles[handle] else 0x10
            value.links = links
            value.sizeLow = size if handles[handle] else 0
            return True

        kernel = SimpleNamespace(CreateFileW=Mock(side_effect=create),
            GetFileInformationByHandle=Mock(side_effect=information),
            CloseHandle=Mock(side_effect=lambda handle: events.append(('close', handle))))
        return kernel, events

    def test_session_lease_pins_both_directories_and_exclusively_opens_only_the_owned_lock(self):
        module, request = self.module(), self.request()
        kernel, events = self.lease_kernel(module)
        with patch.object(module, 'kernel', return_value=kernel):
            with module.SessionLease(request):
                self.assertEqual(len([event for event in events if event[0] == 'open']), 3)
            for handle in (200, 201, 202):
                self.assertEqual(events.count(('close', handle)), 1)
        opens = [event for event in events if event[0] == 'open']
        self.assertEqual(opens[0][3:5], (3, 3))
        self.assertEqual(opens[1][3:5], (3, 3))
        self.assertEqual(opens[2][1], 'interactive-editor.lock')
        self.assertEqual(opens[2][3:5], (0, 4))

    def test_busy_reparse_hardlinked_and_nonempty_lock_targets_release_every_owned_handle(self):
        module = self.module()
        for options in ({'lock_error': True}, {'attributes': 0x400}, {'links': 2}, {'size': 1}):
            with self.subTest(options=options):
                kernel, events = self.lease_kernel(module, **options)
                with patch.object(module, 'kernel', return_value=kernel), \
                        patch.object(module.ctypes, 'get_last_error', return_value=32):
                    with self.assertRaises((ValueError, OSError)):
                        with module.SessionLease(self.request()):
                            self.fail('An invalid lock target must not become an owned editor')
                self.assertEqual(events.count(('close', 200)), 1)
                self.assertEqual(events.count(('close', 201)), 1)
                self.assertEqual(events.count(('close', 202)), 0 if options.get('lock_error') else 1)

    def test_editing_has_no_deadline_but_startup_and_finalize_are_bounded(self):
        module = self.module()
        with patch.object(module.time, 'monotonic', return_value=100):
            lifetime = module.Lifetime(self.request())
            lifetime.stage('startup', 90)
            self.assertEqual(lifetime._deadline, 190)
            lifetime.stage('editing', None)
            self.assertIsNone(lifetime._deadline)
            lifetime.stage('finalizing', 180)
            self.assertEqual(lifetime._deadline, 280)

    def watch_once(self, module, lifetime, *, alive, now):
        lifetime._parent = SimpleNamespace(alive=Mock(return_value=alive))
        lifetime._stop = SimpleNamespace(wait=Mock(side_effect=[False, True]))
        with patch.object(module.os, '_exit') as exit_worker, \
                patch.object(module.time, 'monotonic', return_value=now):
            lifetime._watch()
        return exit_worker

    def test_dead_parent_or_expired_phase_exits_only_the_guarded_worker(self):
        module = self.module()
        for alive, deadline, now in ((False, None, 100), (True, 90, 100)):
            with self.subTest(alive=alive, deadline=deadline):
                lifetime = module.Lifetime(self.request())
                lifetime._deadline = deadline
                exit_worker = self.watch_once(module, lifetime, alive=alive, now=now)
                exit_worker.assert_called_once_with(1)

    def test_long_user_edit_does_not_exit_a_live_parent_session(self):
        module = self.module()
        lifetime = module.Lifetime(self.request())
        lifetime.stage('editing', None)
        exit_worker = self.watch_once(module, lifetime, alive=True, now=10 ** 12)
        exit_worker.assert_not_called()

    def test_cancel_is_a_bound_request_for_nonpublication_not_a_process_kill(self):
        module, request = self.module(), self.request()
        lifetime = module.Lifetime(request)
        (request.launch / 'cancel.json').write_text(json.dumps({'version': 1,
            'sessionId': request.data['sessionId'], 'controlNonce': request.data['controlNonce']}), encoding='utf-8')
        with patch.object(module.os, '_exit') as exit_worker:
            lifetime._read_control()
        self.assertTrue(lifetime.cancelled)
        self.assertIsNone(lifetime._control_error)
        exit_worker.assert_not_called()

    def test_duplicate_foreign_and_over_budget_controls_defer_an_error_without_killing_the_editor(self):
        module = self.module()
        for raw in ('{"version":false,"version":1,"sessionId":"' + SESSION + '","controlNonce":"' + NONCE + '"}',
                json.dumps({'version': 1, 'sessionId': SESSION, 'controlNonce': NEXT_NONCE}),
                ' ' * 2049):
            with self.subTest(raw=raw[:80]):
                request = self.request()
                lifetime = module.Lifetime(request)
                (request.launch / 'cancel.json').write_text(raw, encoding='utf-8')
                with patch.object(module.os, '_exit') as exit_worker:
                    lifetime._read_control()
                self.assertTrue(lifetime.cancelled)
                self.assertEqual(lifetime._control_error, 'interactive_invalid_control')
                exit_worker.assert_not_called()

    def test_control_read_sharing_errors_preserve_the_editor_until_the_user_closes_it(self):
        module, request = self.module(), self.request()
        lifetime = module.Lifetime(request)
        control = request.launch / 'cancel.json'
        error = OSError('controlled Windows metadata sharing error')
        error.winerror = 32
        original = Path.lstat

        def metadata(path, *args, **kwargs):
            if path == control:
                raise error
            return original(path, *args, **kwargs)

        with patch.object(Path, 'lstat', new=metadata), patch.object(module.os, '_exit') as exit_worker:
            try:
                lifetime._read_control()
            except OSError:
                self.fail('A control-file sharing error must not terminate a live GUI session')
        self.assertTrue(lifetime.cancelled)
        self.assertEqual(lifetime._control_error, 'interactive_invalid_control')
        exit_worker.assert_not_called()


if __name__ == '__main__':
    unittest.main()
