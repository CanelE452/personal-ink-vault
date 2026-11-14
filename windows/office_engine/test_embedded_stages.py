"""Parent embedded stages: real bootstrap/wire/phases, fake process boundary only.

Root alone executes. Fake PIDs and OS observations do not establish real owned
process success; that remains a separate native gate. A missing parent module is
an explicit BOOTSTRAP failure, not native behavior evidence.
"""
from contextlib import contextmanager, ExitStack
import copy
import ctypes
from ctypes import wintypes
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import threading
import time
from types import SimpleNamespace
import unittest
import zipfile
from unittest.mock import patch

import office_presentation_binding as binding
import office_presentation_package_patch as package_patch
import office_presentation_source_edit as source_edit
import office_worker as worker
import prepare_runtime
import test_embedded_bootstrap as bootstrap_fixtures
import test_worker_presentation_binding as binding_worker_fixtures


MODULE = Path(__file__).resolve().parent
PARENT = MODULE / 'office_embedded_stages.py'
REAL_RUN_REQUEST = worker.run_request
REAL_OFFICE_SERVER = worker.OfficeServer
REAL_PLAN = source_edit.plan_source_text_edit
REAL_RENDER = source_edit.render_source_candidate
REAL_OBSERVE = source_edit.observe_source_candidate
REAL_LEASE = binding._WindowsReadLease
SCRIPT_URL = 'vnd.sun.star.script:office_embedded_bootstrap.py$run?language=Python&location=user'
MANIFEST_KEYS = set(bootstrap_fixtures.PHASE_FILES) | {
    'schema', 'jobToken', 'phaseToken', 'phase', 'jobRoot', 'helpers', 'runtime',
    'source', 'candidate', 'pdf', 'plan', 'sourceSha256', 'candidateSha256',
    'requestSha256', 'parentPid', 'bootstrapSha256', 'helperSha256', 'runtimeSha256',
    'planEnvelope', 'planPhaseToken',
}
CAPTURE_KEYS = {'pid', 'imagePath', 'imageSha256', 'creationFileTime64', 'inOwnedJob'}
WAIT_KEYS = {'actualExitCode', 'loaderExitCode', 'activeProcesses'}
CLEANUP_KEYS = {'activeProcesses', 'actualHandleClosed', 'loaderHandleClosed',
    'jobHandleClosed', 'forced', 'errors'}
PARENT_PROOF_KEYS = {'schema', 'jobToken', 'phaseToken', 'phase', 'capture', 'wait', 'cleanup'}


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def json_file(path):
    return json.loads(Path(path).read_text(encoding='utf-8'))


def write_json(path, value):
    bootstrap_fixtures.write_json(path, value)


class OsProxy:
    def __init__(self, pid):
        self.pid = pid

    def getpid(self):
        return self.pid

    def __getattr__(self, name):
        return getattr(os, name)


class ChildTime:
    def __init__(self, owner):
        self.owner = owner

    def monotonic(self):
        return time.monotonic()

    def sleep(self, seconds):
        if self.owner.cancelled.is_set():
            raise TimeoutError('The fake owned process was stopped at its process boundary')
        time.sleep(min(seconds, .005))


class ParentAwareCallback(bootstrap_fixtures.FakeAsyncCallback):
    def __init__(self, native, harness, owner):
        super().__init__(native)
        self.harness, self.owner = harness, owner

    def addCallback(self, callback, data):
        phase = self.owner.manifest['phase']
        if phase == 'render' or phase == 'inspect' and self.harness.request.get('preview', False):
            self.harness.assert_parent_pdf_lease_before_ack(self.owner)
        return super().addCallback(callback, data)


class FakeOwnedProcess:
    """Runs the actual child code; only the external process/OS boundary is fake."""

    def __init__(self, harness, executable, arguments, directory):
        self.harness = harness
        self.index = len(harness.processes)
        self.pid, self.actual_pid = 10000 + self.index, 20000 + self.index
        self.process, self.job = object(), object()
        self.cancelled, self.captured, self.finished = threading.Event(), threading.Event(), threading.Event()
        self.error, self.thread, self.capture = None, None, None
        self.arguments = list(arguments)
        harness.test.assertEqual(Path(executable), harness.runtime / 'program/soffice.com')
        harness.test.assertEqual(Path(directory), harness.runtime / 'program')
        harness.test.assertFalse(any('--accept' in argument for argument in self.arguments))
        harness.test.assertEqual(self.arguments.count(SCRIPT_URL), 1)
        profile_arguments = [argument for argument in self.arguments if argument.startswith('-env:UserInstallation=')]
        harness.test.assertEqual(len(profile_arguments), 1)
        from urllib.request import url2pathname
        from urllib.parse import urlsplit, unquote
        profile = profile_arguments[0].split('=', 1)[1]
        self.profile = Path(url2pathname(unquote(urlsplit(profile).path)))
        self.phase_root = self.profile.parent
        self.manifest = json_file(self.phase_root / 'manifest.json')
        self.phase = self.manifest['phase']
        self.request_bytes = (self.phase_root / 'request.json').read_bytes()
        harness.processes.append(self)
        if harness.fault != 'timeout':
            self.thread = threading.Thread(target=self.run, name='fake-embedded-' + self.phase, daemon=True)
            self.thread.start()

    def run(self):
        harness, native = self.harness, self.harness.native
        try:
            native.root = Path(self.manifest['jobRoot'])
            native.source = native.root / 'source.pptx'
            native.source_hash = self.manifest['sourceSha256']
            native.helpers = native.root / 'helpers'
            native.phase_root = self.phase_root
            native.desktop = bootstrap_fixtures.FakeDesktop(native)
            native.callback = ParentAwareCallback(native, harness, self)

            def service(name, context):
                harness.test.assertEqual(name, 'com.sun.star.awt.AsyncCallback')
                harness.test.assertIs(context, local_context)
                return native.callback

            local_context = SimpleNamespace(ServiceManager=SimpleNamespace(createInstanceWithContext=service))
            native.contexts.append(local_context)
            script = self.profile / 'user/Scripts/python/office_embedded_bootstrap.py'
            original_write = native.bootstrap.write_json

            def publishing(filename, value):
                value = copy.deepcopy(value)
                path = Path(filename)
                if path.name == 'pdf-ready.json' and harness.fault.startswith('ready-'):
                    key = harness.fault[6:]
                    if key == 'extra':
                        value['extra'] = True
                    elif key == 'pdf':
                        value['pdf'] = '../foreign.pdf'
                    elif key == 'pdfStamp':
                        value['pdfStamp'][2] += 1
                    elif key == 'nonce':
                        value['nonce'] = 'A' * 32
                    else:
                        value[key] = '0' * (32 if key == 'phaseToken' else 64)
                if path.name == 'embedded-proof.json' and value.get('terminationNotificationVerified') is True:
                    if harness.fault == 'proof-token':
                        value['phaseToken'] = 'f' * 32
                    elif harness.fault == 'proof-pid':
                        value['pid'] = self.pid
                    elif harness.fault == 'proof-disposal':
                        value['documents'][0]['disposed'] = False
                    elif harness.fault == 'proof-cleanup':
                        value['cleanupErrors'] = ['controlled child cleanup error']
                    elif harness.fault == 'response-hash':
                        with (self.phase_root / 'response.json').open('ab') as stream:
                            stream.write(b' ')
                return original_write(filename, value)

            with ExitStack() as patches:
                patches.enter_context(patch.object(sys, 'path', list(sys.path)))
                patches.enter_context(patch.object(worker, 'OfficeServer', REAL_OFFICE_SERVER))
                for name in bootstrap_fixtures.HELPERS:
                    imported = sys.modules.get(Path(name).stem)
                    if imported is not None and hasattr(imported, '__file__'):
                        patches.enter_context(patch.object(imported, '__file__', str(native.helpers / name)))
                patches.enter_context(patch.object(native.bootstrap, '__file__', script.as_uri()))
                patches.enter_context(patch.object(native.bootstrap, 'os', OsProxy(self.actual_pid)))
                patches.enter_context(patch.object(native.bootstrap, 'time', ChildTime(self)))
                patches.enter_context(patch.object(native.bootstrap, 'write_json', side_effect=publishing))
                native.bootstrap.XSCRIPTCONTEXT = SimpleNamespace(getDesktop=lambda: native.desktop,
                    getComponentContext=lambda: local_context)
                native.bootstrap.run()
                if native.callback.callbacks:
                    if not self.captured.wait(3):
                        raise AssertionError('Parent must hold the actual process before final notification')
                    if harness.fault != 'missing-notify':
                        native.callback.deliver()
        except BaseException as error:
            self.error = error
        finally:
            self.finished.set()

    def exit_code(self):
        if not self.finished.is_set():
            return None
        return 1 if self.error is not None else 0

    def close(self):
        self.cancelled.set()
        if self.thread is not None:
            self.thread.join(3)
            if not self.thread.is_alive():
                for state in self.harness.native.bootstrap._active_jobs:
                    if state['proof']['phaseToken'] != self.manifest['phaseToken']:
                        continue
                    for key in ('originalPdfLease', 'exportPdfLease'):
                        lease = state.get(key)
                        if lease is not None:
                            lease.close()
                            state[key] = None
                    lease = state['pdfState'].get('lease')
                    if lease is not None:
                        lease.close()
                        state['pdfState']['lease'] = None
                    state['job']['cleanup'].close()
        self.process, self.job = None, None


class ProcessHarness:
    def __init__(self, test, module, native, request, directory, fault):
        self.test, self.module, self.native = test, module, native
        self.request, self.directory, self.runtime = request, directory, native.runtime
        self.fault, self.processes, self.wait_deadlines, self.close_deadlines = fault or '', [], [], []
        self.offset, self.sleep_count = 0, 0
        self.parent_pdf_leases, self.parent_source_leases, self.ack_checks = [], [], []
        self.foreign_replaced, self.foreign_blocked = False, False
        self.main_thread = threading.get_ident()

    def monotonic(self):
        return time.monotonic() + self.offset

    def sleep(self, seconds):
        self.sleep_count += 1
        if self.fault == 'timeout':
            self.offset += 181
        time.sleep(min(seconds, .005))

    def launch(self, executable, arguments, directory):
        return FakeOwnedProcess(self, executable, arguments, directory)

    def lease(self, filename):
        path = Path(filename)
        owner = self.processes[-1] if self.processes else None
        if threading.get_ident() == self.main_thread and path == self.directory / 'preview.pdf':
            self.test.assertIsNotNone(owner)
            self.test.assertFalse((owner.phase_root / 'pdf-ack.json').exists(),
                'The parent must acquire the exact PDF lease before publishing ACK')
        result = REAL_LEASE(filename)
        if threading.get_ident() == self.main_thread:
            if path == self.directory / 'preview.pdf':
                self.parent_pdf_leases.append(result)
            elif path == self.directory / 'source.pptx':
                self.parent_source_leases.append(result)
        return result

    def assert_parent_pdf_lease_before_ack(self, owner):
        self.test.assertEqual(len(self.parent_pdf_leases), 1)
        lease = self.parent_pdf_leases[0]
        self.test.assertIsNotNone(lease._handle)
        self.test.assertTrue(binding_worker_fixtures.write_is_blocked(self.directory / 'preview.pdf'))
        ready = json_file(owner.phase_root / 'pdf-ready.json')
        ack = json_file(owner.phase_root / 'pdf-ack.json')
        self.test.assertEqual(ack, {**ready, 'readySha256': digest(owner.phase_root / 'pdf-ready.json')})
        self.test.assertEqual(ready['pdfSha256'], digest(self.directory / 'preview.pdf'))
        self.ack_checks.append((owner.phase, lease))

    def capture_owned_pid(self, owner, pid, runtime, expected_sha):
        self.test.assertEqual(pid, owner.actual_pid)
        self.test.assertNotEqual(pid, owner.pid, 'Actual embedded PID is intentionally different from loader PID')
        self.test.assertFalse(owner.finished.is_set())
        self.test.assertFalse((owner.phase_root / 'embedded-complete').exists(),
            'Capture must precede completion and cannot infer identity from an already exited PID')
        self.test.assertEqual(Path(runtime), self.runtime)
        image = self.runtime / 'program/soffice.bin'
        self.test.assertEqual(expected_sha, digest(image))
        owner.capture = dict(pid=pid, imagePath=str(image), imageSha256=digest(image),
            creationFileTime64=100000 + pid, inOwnedJob=True)
        owner.captured.set()
        return copy.deepcopy(owner.capture)

    def wait_owned(self, owner, deadline):
        self.wait_deadlines.append(deadline)
        if owner.thread is not None:
            owner.thread.join(3)
        self.test.assertTrue(owner.finished.is_set())
        if self.fault == 'observe-foreign' and owner.phase == 'observe':
            foreign = self.directory / 'foreign-candidate.pptx'
            foreign.write_bytes(b'FOREIGN REPLACEMENT MUST SURVIVE')
            try:
                foreign.replace(self.directory / 'edited.pptx')
                self.foreign_replaced = True
            except PermissionError:
                self.foreign_blocked = True
        if self.fault == 'budget-after-plan' and owner.phase == 'plan':
            self.offset += 179
        return dict(actualExitCode=9 if self.fault == 'nonzero-exit' else 0,
            loaderExitCode=0, activeProcesses=0)

    def close_owned(self, owner, deadline):
        self.close_deadlines.append(deadline)
        forced = not owner.finished.is_set()
        owner.close()
        errors = ['controlled OS cleanup error'] if self.fault == 'native-and-cleanup' and owner.phase == 'render' else []
        return dict(activeProcesses=0, actualHandleClosed=True, loaderHandleClosed=True,
            jobHandleClosed=True, forced=forced, errors=errors)

    def pdf(self, document, destination, kind):
        self.test.assertEqual(kind, 'presentation')
        if self.fault in ('native-error', 'native-and-cleanup'):
            raise RuntimeError('controlled native PDF failure')
        Path(destination).write_bytes(b'%PDF-REAL-BOOTSTRAP-FAKE-NATIVE')
        return document.DrawPages.Count

    def join(self):
        for owner in self.processes:
            owner.close()
            if owner.thread is not None:
                self.test.assertFalse(owner.thread.is_alive(), 'A fake process boundary must not leak its worker thread')


class EmbeddedStagesTest(unittest.TestCase):
    def api(self):
        self.assertTrue(PARENT.is_file(),
            'BOOTSTRAP: office_embedded_stages.py is missing; this is not native behavior evidence')
        spec = importlib.util.spec_from_file_location('_piv_parent_stages_test', PARENT)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        for name in ('EmbeddedPresentationStages', '_capture_owned_pid', '_wait_owned', '_close_owned'):
            self.assertTrue(callable(getattr(module, name, None)), 'BOOTSTRAP: missing parent API ' + name)
        return module

    @contextmanager
    def fixture(self, *, inspect_preview=None, empty_grouped=False, fault=None, timeout_seconds=180):
        module = self.api()
        bootstrap_case = bootstrap_fixtures.EmbeddedBootstrapTest()
        with bootstrap_case.fixture() as native:
            if empty_grouped:
                with zipfile.ZipFile(native.source) as archive:
                    members = {name: archive.read(name) for name in archive.namelist()}
                part = 'ppt/slides/slide1.xml'
                members[part] = members[part].replace(b'<p:graphicFrame>', b'<p:grpSp><p:graphicFrame>', 1)
                members[part] = members[part].replace(b'</p:graphicFrame>', b'</p:graphicFrame></p:grpSp>', 1)
                bootstrap_fixtures.binding_fixtures.write_package(native.source, members.items())
                native.original = native.source.read_bytes()
                native.source_hash = digest(native.source)
                native.request.update(operations=[], expectedSourceSha256=native.source_hash)
            original_source = native.source
            request = copy.deepcopy(native.request)
            if inspect_preview is not None:
                request = dict(mode='inspect', sourcePath=str(original_source), preview=inspect_preview)
            directory = native.root.parent / 'parent-stage-job'
            harness = ProcessHarness(self, module, native, request, directory, fault)
            stages = module.EmbeddedPresentationStages(native.runtime, request, directory,
                helpers=MODULE, timeout_seconds=timeout_seconds, process_factory=harness.launch,
                monotonic=harness.monotonic, sleep=harness.sleep)
            state = SimpleNamespace(module=module, native=native, request=request, directory=directory,
                original_source=original_source, harness=harness, stages=stages,
                result=None, caught=None, pdf_state=None, transferred_lease=None)
            with ExitStack() as patches:
                patches.enter_context(patch.object(module, '_capture_owned_pid', side_effect=harness.capture_owned_pid))
                patches.enter_context(patch.object(module, '_wait_owned', side_effect=harness.wait_owned))
                patches.enter_context(patch.object(module, '_close_owned', side_effect=harness.close_owned))
                patches.enter_context(patch.object(module, '_active', side_effect=lambda owner:
                    1 if owner.thread is None else int(owner.thread.is_alive())))
                patches.enter_context(patch.object(binding, '_WindowsReadLease', side_effect=harness.lease))
                patches.enter_context(patch.object(worker, 'export_pdf', side_effect=harness.pdf))
                try:
                    yield state
                finally:
                    stages.close()
                    harness.join()
            self.assertEqual(original_source.read_bytes(), native.original)

    def drive(self, state):
        try:
            with state.stages as entered:
                self.assertIs(entered, state.stages)
                state.result = REAL_RUN_REQUEST(state.native.runtime, state.request, state.directory,
                    native_stages=state.stages)
        except BaseException as error:
            state.caught = error
        return state

    def assert_manifest(self, state, owner):
        manifest = owner.manifest
        self.assertEqual(set(manifest), MANIFEST_KEYS)
        self.assertEqual(manifest['schema'], 'piv.embedded-office/1')
        self.assertEqual(Path(manifest['jobRoot']), state.directory)
        self.assertEqual(Path(manifest['runtime']), state.native.runtime)
        self.assertEqual(manifest['helpers'], 'helpers')
        self.assertEqual((manifest['source'], manifest['candidate'], manifest['pdf'], manifest['plan']),
            ('source.pptx', 'edited.pptx', 'preview.pdf', 'source-plan'))
        self.assertEqual(manifest['parentPid'], os.getpid())
        self.assertRegex(manifest['jobToken'], '^[0-9a-f]{32}$')
        self.assertRegex(manifest['phaseToken'], '^[0-9a-f]{32}$')
        self.assertEqual(owner.phase_root, state.directory / 'phases' / manifest['phaseToken'][:12])
        self.assertEqual(set(manifest['helperSha256']), bootstrap_fixtures.HELPERS)
        self.assertEqual(set(manifest['runtimeSha256']), set(prepare_runtime.CRITICAL_FILES))
        self.assertEqual(manifest['requestSha256'], hashlib.sha256(owner.request_bytes).hexdigest())
        self.assertEqual(json.loads(owner.request_bytes),
            {**state.request, 'sourcePath': str(state.directory / 'source.pptx')})
        for key, value in bootstrap_fixtures.PHASE_FILES.items():
            self.assertEqual(manifest[key], value)

    def assert_parent_proof(self, owner):
        proof = json_file(owner.phase_root / 'parent-proof.json')
        self.assertEqual(set(proof), PARENT_PROOF_KEYS)
        self.assertEqual(proof['schema'], 'piv.embedded-parent-proof/1')
        for key in ('jobToken', 'phaseToken', 'phase'):
            self.assertEqual(proof[key], owner.manifest[key])
        self.assertEqual(set(proof['capture']), CAPTURE_KEYS)
        self.assertEqual(proof['capture'], owner.capture)
        self.assertEqual(set(proof['wait']), WAIT_KEYS)
        self.assertEqual(proof['wait'], dict(actualExitCode=0, loaderExitCode=0, activeProcesses=0))
        self.assertEqual(set(proof['cleanup']), CLEANUP_KEYS)
        self.assertEqual(proof['cleanup'], dict(activeProcesses=0, actualHandleClosed=True,
            loaderHandleClosed=True, jobHandleClosed=True, forced=False, errors=[]))

    def test_constructor_context_and_close_do_not_touch_files_processes_or_deadline_when_unused(self):
        module = self.api()
        with tempfile.TemporaryDirectory(prefix='piv-parent-unused-') as temporary:
            root = Path(temporary)
            forbidden = unittest.mock.Mock(side_effect=AssertionError('Unused stages must have no side effects'))
            stages = module.EmbeddedPresentationStages(root / 'missing-runtime', {'mode': 'inspect'},
                root / 'not-created', helpers=root / 'missing-helpers', process_factory=forbidden,
                monotonic=forbidden, sleep=forbidden)
            with stages as entered:
                self.assertIs(entered, stages)
                self.assertEqual(list(root.iterdir()), [])
            stages.close()
            forbidden.assert_not_called()
            self.assertEqual(list(root.iterdir()), [])

    def test_real_three_phase_apply_preserves_frozen_request_wire_and_same_parent_pdf_lease(self):
        with self.fixture() as state:
            original_plan, original_render, original_observe = state.stages.plan, state.stages.render, state.stages.observe

            def plan(*arguments, **keywords):
                result = original_plan(*arguments, **keywords)
                self.assertTrue(binding_worker_fixtures.write_is_blocked(state.directory / 'source.pptx'))
                return result

            def render(*arguments, **keywords):
                result = original_render(*arguments, **keywords)
                state.pdf_state = arguments[7]
                state.transferred_lease = state.pdf_state['lease']
                self.assertIs(state.transferred_lease, state.harness.parent_pdf_leases[0])
                self.assertIsNotNone(state.transferred_lease._handle)
                return result

            def observe(*arguments, **keywords):
                self.assertIs(state.pdf_state['lease'], state.transferred_lease)
                self.assertIsNotNone(state.transferred_lease._handle)
                result = original_observe(*arguments, **keywords)
                self.assertIs(state.pdf_state['lease'], state.transferred_lease)
                self.assertIsNotNone(state.transferred_lease._handle)
                return result

            with patch.object(state.stages, 'plan', side_effect=plan), \
                    patch.object(state.stages, 'render', side_effect=render), \
                    patch.object(state.stages, 'observe', side_effect=observe), \
                    patch.object(source_edit, 'plan_source_text_edit', wraps=REAL_PLAN) as planned, \
                    patch.object(source_edit, 'render_source_candidate', wraps=REAL_RENDER) as rendered, \
                    patch.object(source_edit, 'observe_source_candidate', wraps=REAL_OBSERVE) as observed:
                self.drive(state)
            self.assertIsNone(state.caught)
            planned.assert_called_once()
            rendered.assert_called_once()
            observed.assert_called_once()
            owners = state.harness.processes
            self.assertEqual([owner.phase for owner in owners], ['plan', 'render', 'observe'])
            self.assertEqual(len({owner.actual_pid for owner in owners}), 3)
            self.assertEqual(len({owner.profile for owner in owners}), 3)
            self.assertEqual(len({owner.manifest['jobToken'] for owner in owners}), 1)
            self.assertEqual(len({owner.manifest['phaseToken'] for owner in owners}), 3)
            self.assertEqual(len({owner.request_bytes for owner in owners}), 1)
            for owner in owners:
                self.assert_manifest(state, owner)
                self.assert_parent_proof(owner)
                self.assertFalse(owner.profile.exists())
                self.assertIsNone(owner.error)
            self.assertEqual(len(set(state.harness.wait_deadlines + state.harness.close_deadlines)), 1)
            self.assertEqual(state.harness.ack_checks, [('render', state.transferred_lease)])
            self.assertIsNone(state.transferred_lease._handle)
            self.assertIsNone(state.pdf_state['lease'])
            self.assertEqual(state.result['status'], 'saved')
            self.assertEqual(Path(state.result['sourcePath']), state.directory / 'edited.pptx')
            self.assertEqual(Path(state.result['pdfPath']), state.directory / 'preview.pdf')
            self.assertEqual(state.result['sourceSha256'], digest(state.directory / 'edited.pptx'))
            self.assertEqual(state.result['pdfSha256'], digest(state.directory / 'preview.pdf'))
            self.assertEqual(state.result['draftSnapshot']['sourceSha256'], state.native.source_hash)
            table = next(table for slide in state.result['snapshot']['slides'] for table in slide['presentationTables']
                if table['id'] == state.native.operation['tableId'])
            cell = next(cell for cell in table['cells'] if cell['id'] == state.native.operation['cellId'])
            self.assertEqual(cell['text'], state.native.text)
            self.assertTrue(all(document.closed for document in state.native.documents))
            self.assertTrue((state.directory / 'edited.pptx').is_file())
            self.assertTrue((state.directory / 'preview.pdf').is_file())

    def test_metadata_reader_does_not_reuse_the_pdf_output_byte_limit(self):
        module = self.api()
        with tempfile.TemporaryDirectory(prefix='piv-parent-metadata-') as temporary:
            root = Path(temporary).resolve(strict=True)
            self.assertEqual(root.parent, Path(tempfile.gettempdir()).resolve(strict=True))
            self.assertTrue(root.name.startswith('piv-parent-metadata-'))
            payload = root / 'large-metadata.json'
            expected = hashlib.sha256()
            length = 0
            with payload.open('xb') as stream:
                for chunk in (b'{"metadata":"', *([b'x' * (1024 * 1024)] * 129), b'"}'):
                    self.assertEqual(stream.write(chunk), len(chunk))
                    expected.update(chunk)
                    length += len(chunk)
            raw = module._shared_bytes(payload)
            self.assertEqual(len(raw), length)
            self.assertEqual(hashlib.sha256(raw).hexdigest(), expected.hexdigest())
            self.assertTrue(raw.startswith(b'{"metadata":"') and raw.endswith(b'"}'))
            del raw
            with self.assertRaises(ValueError):
                module._shared_bytes(payload, 65)

    def test_inspect_preview_handoff_retains_fixed_output_and_preview_false_creates_no_pdf(self):
        for preview in (True, False):
            with self.subTest(preview=preview), self.fixture(inspect_preview=preview) as state:
                self.drive(state)
                self.assertIsNone(state.caught)
                self.assertEqual([owner.phase for owner in state.harness.processes], ['inspect'])
                owner = state.harness.processes[0]
                self.assert_manifest(state, owner)
                self.assert_parent_proof(owner)
                self.assertFalse(owner.profile.exists())
                self.assertEqual(state.result['snapshot']['sourceSha256'], state.native.source_hash)
                self.assertEqual(state.result['engineVersion'], 'LibreOffice26.8.2.2')
                if preview:
                    pdf = Path(state.result['snapshot']['previewPdfPath'])
                    self.assertEqual(pdf, state.directory / 'preview.pdf')
                    self.assertTrue(pdf.is_file())
                    self.assertTrue(pdf.is_relative_to(state.directory.parent))
                    self.assertEqual(len(state.harness.parent_pdf_leases), 1)
                    self.assertIsNone(state.harness.parent_pdf_leases[0]._handle)
                    self.assertEqual(state.harness.ack_checks[0][0], 'inspect')
                else:
                    self.assertNotIn('previewPdfPath', state.result['snapshot'])
                    self.assertEqual(state.harness.parent_pdf_leases, [])
                    self.assertFalse((state.directory / 'preview.pdf').exists())
                    self.assertFalse((owner.phase_root / 'pdf-ready.json').exists())

    def test_actual_grouped_empty_prepare_is_the_only_parent_none_then_legacy_fallback(self):
        with self.fixture(empty_grouped=True) as state:
            primary = RuntimeError('controlled original legacy fallback reached')
            with patch.object(worker, 'OfficeServer', side_effect=primary) as legacy, \
                    patch.object(package_patch, 'patch_pptx', wraps=package_patch.patch_pptx) as writer:
                self.drive(state)
            self.assertIs(state.caught, primary)
            self.assertIsNone(state.result)
            self.assertEqual([owner.phase for owner in state.harness.processes], ['plan'])
            owner = state.harness.processes[0]
            response = json_file(owner.phase_root / 'response.json')
            proof = json_file(owner.phase_root / 'embedded-proof.json')
            self.assertEqual(response, {'ok': True, 'result': {'status': 'unsupportedBeforeLoad'}})
            self.assertTrue(proof['unsupportedBeforeLoad'])
            self.assertEqual((proof['serverEnterCount'], proof['serverExitCount'], proof['loadAttemptCount']), (1, 1, 0))
            self.assertEqual(proof['documents'], [])
            self.assert_parent_proof(owner)
            legacy.assert_called_once()
            writer.assert_not_called()
            self.assertEqual((state.directory / 'working.pptx').read_bytes(), state.native.original)
            self.assertFalse((state.directory / 'edited.pptx').exists())
            self.assertFalse((state.directory / 'preview.pdf').exists())

    def test_corrupt_child_response_token_pid_disposal_or_cleanup_proof_is_never_success(self):
        for fault in ('response-hash', 'proof-token', 'proof-pid', 'proof-disposal', 'proof-cleanup'):
            with self.subTest(fault=fault), self.fixture(fault=fault) as state:
                self.drive(state)
                self.assertIsNotNone(state.caught)
                self.assertIsNone(state.result)
                self.assertEqual([owner.phase for owner in state.harness.processes], ['plan'])
                self.assertTrue(state.harness.processes[0].profile.is_dir(), 'Failure profiles must remain for diagnosis')
                self.assertFalse((state.directory / 'edited.pptx').exists())
                self.assertFalse((state.directory / 'preview.pdf').exists())

    def test_invalid_pdf_ready_is_rejected_without_ack_or_releasing_a_foreign_file(self):
        for field in ('phaseToken', 'requestSha256', 'pdfSha256', 'pdfStamp', 'pdf', 'nonce', 'extra'):
            with self.subTest(field=field), self.fixture(fault='ready-' + field) as state:
                self.drive(state)
                self.assertIsNotNone(state.caught)
                self.assertIsNone(state.result)
                self.assertEqual([owner.phase for owner in state.harness.processes], ['plan', 'render'])
                owner = state.harness.processes[-1]
                self.assertTrue((owner.phase_root / 'pdf-ready.json').is_file())
                self.assertFalse((owner.phase_root / 'pdf-ack.json').exists())
                self.assertFalse((state.directory / 'foreign.pdf').exists())
                self.assertFalse((state.directory / 'edited.pptx').exists())

    def test_early_loader_exit_waits_for_live_owned_child_but_empty_job_never_succeeds(self):
        for actual_alive in (True, False):
            with self.subTest(actual_alive=actual_alive), self.fixture() as state:
                gates, active_observations, loader_observations = {}, [], []
                original_run = FakeOwnedProcess.run
                original_write = state.native.bootstrap.write_json

                def gate(owner):
                    return gates.setdefault(owner.index, SimpleNamespace(
                        before_progress=threading.Event(), release=threading.Event()))

                def actual_process_boundary(owner):
                    if actual_alive:
                        return original_run(owner)
                    owner.finished.set()

                def pause_before_first_progress(filename, value):
                    path = Path(filename)
                    if path.name == 'embedded-progress.json':
                        owner = next(item for item in state.harness.processes if item.phase_root == path.parent)
                        current = gate(owner)
                        if not current.before_progress.is_set():
                            self.assertFalse(path.exists())
                            current.before_progress.set()
                            self.assertTrue(current.release.wait(5), 'The real child must leave its bounded pre-progress pause')
                            if owner.cancelled.is_set():
                                raise TimeoutError('The owned test process stopped before its first progress publication')
                    return original_write(filename, value)

                def loader_exited_zero(owner):
                    loader_observations.append((owner.index, owner.finished.is_set(),
                        owner.thread is not None and owner.thread.is_alive()))
                    return 0

                def active_owned_threads(owner):
                    self.assertIsNotNone(owner.job)
                    self.assertIsNotNone(owner.thread)
                    if actual_alive:
                        current = gate(owner)
                        self.assertTrue(current.before_progress.wait(5),
                            'The live owned child must reach its actual bootstrap publication boundary')
                        if not current.release.is_set():
                            self.assertTrue(owner.thread.is_alive())
                            self.assertFalse(owner.finished.is_set())
                            self.assertIsNone(owner.capture)
                            self.assertFalse((owner.phase_root / 'embedded-progress.json').exists())
                            active_observations.append((owner.index, 1, state.stages._deadline))
                            current.release.set()
                            return 1
                        active = int(owner.thread.is_alive() and not owner.finished.is_set())
                    else:
                        self.assertTrue(owner.finished.wait(5), 'The empty owned Job must have a terminated actual thread')
                        owner.thread.join(1)
                        self.assertFalse(owner.thread.is_alive())
                        self.assertFalse((owner.phase_root / 'embedded-progress.json').exists())
                        active = 0
                    active_observations.append((owner.index, active, state.stages._deadline))
                    return active

                def close_process_boundary(owner, deadline):
                    if not owner.finished.is_set():
                        owner.cancelled.set()
                    gate(owner).release.set()
                    return state.harness.close_owned(owner, deadline)

                try:
                    with patch.object(FakeOwnedProcess, 'run', new=actual_process_boundary), \
                            patch.object(FakeOwnedProcess, 'exit_code', new=loader_exited_zero), \
                            patch.object(state.native.bootstrap, 'write_json', side_effect=pause_before_first_progress), \
                            patch.object(state.module, '_active', side_effect=active_owned_threads), \
                            patch.object(state.module, '_close_owned', side_effect=close_process_boundary), \
                            patch.object(source_edit, 'plan_source_text_edit', wraps=REAL_PLAN) as planned, \
                            patch.object(source_edit, 'render_source_candidate', wraps=REAL_RENDER) as rendered, \
                            patch.object(source_edit, 'observe_source_candidate', wraps=REAL_OBSERVE) as watched:
                        self.drive(state)
                finally:
                    for current in gates.values():
                        current.release.set()
                self.assertTrue(loader_observations, 'The separate zero-exit loader boundary must actually be observed')
                if actual_alive:
                    self.assertIsNone(state.caught)
                    planned.assert_called_once()
                    rendered.assert_called_once()
                    watched.assert_called_once()
                    self.assertEqual([owner.phase for owner in state.harness.processes], ['plan', 'render', 'observe'])
                    self.assertEqual(len({owner.actual_pid for owner in state.harness.processes}), 3)
                    self.assertEqual({index for index, active, _ in active_observations if active == 1}, {0, 1, 2})
                    self.assertEqual(len({deadline for _, _, deadline in active_observations} |
                        set(state.harness.wait_deadlines + state.harness.close_deadlines)), 1)
                    self.assertTrue(all(owner.captured.is_set() and owner.error is None for owner in state.harness.processes))
                    self.assertTrue(all(not owner.thread.is_alive() for owner in state.harness.processes))
                    for owner in state.harness.processes:
                        self.assert_parent_proof(owner)
                    self.assertEqual(state.result['status'], 'saved')
                    self.assertEqual(state.result['sourceSha256'], digest(state.directory / 'edited.pptx'))
                    self.assertEqual(state.result['pdfSha256'], digest(state.directory / 'preview.pdf'))
                    self.assertEqual((state.directory / 'preview.pdf').read_bytes(), b'%PDF-REAL-BOOTSTRAP-FAKE-NATIVE')
                    self.assertEqual(state.original_source.read_bytes(), state.native.original)
                    table = next(table for slide in state.result['snapshot']['slides'] for table in slide['presentationTables']
                        if table['id'] == state.native.operation['tableId'])
                    cell = next(cell for cell in table['cells'] if cell['id'] == state.native.operation['cellId'])
                    self.assertEqual(cell['text'], state.native.text)
                else:
                    self.assertIsNotNone(state.caught)
                    self.assertIsNone(state.result)
                    self.assertTrue(any(active == 0 for _, active, _ in active_observations),
                        'The empty owned Job must be observed independently of the loader exit')
                    self.assertLess(state.harness.sleep_count, 10)
                    planned.assert_not_called()
                    rendered.assert_not_called()
                    watched.assert_not_called()
                    self.assertEqual([owner.phase for owner in state.harness.processes], ['plan'])
                    owner = state.harness.processes[0]
                    self.assertTrue(owner.finished.is_set())
                    self.assertFalse(owner.thread.is_alive())
                    self.assertIsNone(owner.capture)
                    self.assertFalse(owner.captured.is_set())
                    self.assertFalse((owner.phase_root / 'embedded-progress.json').exists())
                    self.assertFalse((owner.phase_root / 'embedded-complete').exists())
                    proof = json_file(owner.phase_root / 'parent-proof.json')
                    self.assertIsNone(proof['capture'])
                    self.assertIsNone(proof['wait'])
                    self.assertFalse((state.directory / 'edited.pptx').exists())
                    self.assertFalse((state.directory / 'preview.pdf').exists())

    def test_first_progress_file_gap_repolls_the_same_owned_phase_without_restart(self):
        with self.fixture() as state:
            published, resume = threading.Event(), threading.Event()
            original_write = state.native.bootstrap.write_json
            original_reader = state.module._shared_bytes
            observed = dict(injected=False, missing=False, restored=False, path=None)

            def pause_first_progress(filename, value):
                result = original_write(filename, value)
                path = Path(filename)
                if path.name == 'embedded-progress.json' and not published.is_set():
                    observed['path'] = path
                    published.set()
                    self.assertTrue(resume.wait(5), 'The first progress producer must be released within a bounded wait')
                return result

            def read_with_real_first_gap(filename, limit=None):
                path = Path(filename)
                if path.name != 'embedded-progress.json' or observed['injected']:
                    return original_reader(filename, limit)
                self.assertTrue(published.wait(5), 'The real first progress publication must finish before the gap')
                self.assertEqual(path, observed['path'])
                owner = state.harness.processes[0]
                self.assertEqual(owner.phase, 'plan')
                self.assertIsNone(owner.capture, 'The real gap must occur before the first actual-PID capture')
                self.assertFalse(owner.captured.is_set())
                original = path.read_bytes()
                before = path.stat()
                away = path.with_name('owned-first-progress-away.json')
                self.assertFalse(away.exists())
                path.rename(away)
                observed['injected'] = True
                try:
                    self.assertFalse(path.exists())
                    try:
                        return original_reader(filename, limit)
                    except FileNotFoundError:
                        observed['missing'] = True
                        raise
                finally:
                    try:
                        self.assertFalse(path.exists(), 'The paused producer must not replace the temporarily absent slot')
                        away.rename(path)
                        after = path.stat()
                        self.assertEqual((after.st_dev, after.st_ino), (before.st_dev, before.st_ino))
                        self.assertEqual(path.read_bytes(), original)
                        observed['restored'] = True
                    finally:
                        resume.set()

            try:
                with patch.object(state.native.bootstrap, 'write_json', side_effect=pause_first_progress), \
                        patch.object(state.module, '_shared_bytes', side_effect=read_with_real_first_gap), \
                        patch.object(source_edit, 'plan_source_text_edit', wraps=REAL_PLAN) as planned, \
                        patch.object(source_edit, 'render_source_candidate', wraps=REAL_RENDER) as rendered, \
                        patch.object(source_edit, 'observe_source_candidate', wraps=REAL_OBSERVE) as watched:
                    self.drive(state)
            finally:
                resume.set()
            self.assertTrue(observed['injected'])
            self.assertTrue(observed['missing'], 'The actual reader must observe the real missing path')
            self.assertTrue(observed['restored'])
            self.assertIsNone(state.caught)
            planned.assert_called_once()
            rendered.assert_called_once()
            watched.assert_called_once()
            self.assertEqual([owner.phase for owner in state.harness.processes], ['plan', 'render', 'observe'])
            self.assertEqual(len({owner.actual_pid for owner in state.harness.processes}), 3)
            self.assertTrue(all(owner.error is None for owner in state.harness.processes))
            self.assertTrue(all(owner.captured.is_set() for owner in state.harness.processes))
            self.assertEqual(state.result['status'], 'saved')
            self.assertEqual(state.result['sourceSha256'], digest(state.directory / 'edited.pptx'))
            self.assertEqual(state.result['pdfSha256'], digest(state.directory / 'preview.pdf'))
            self.assertEqual((state.directory / 'preview.pdf').read_bytes(), b'%PDF-REAL-BOOTSTRAP-FAKE-NATIVE')
            self.assertEqual(state.original_source.read_bytes(), state.native.original)
            table = next(table for slide in state.result['snapshot']['slides'] for table in slide['presentationTables']
                if table['id'] == state.native.operation['tableId'])
            cell = next(cell for cell in table['cells'] if cell['id'] == state.native.operation['cellId'])
            self.assertEqual(cell['text'], state.native.text)

    def test_progress_share_lock_after_capture_repolls_the_same_owned_inspect(self):
        with self.fixture(inspect_preview=True) as state:
            published, resume = threading.Event(), threading.Event()
            write_json = state.native.bootstrap.write_json
            read_bytes = state.module._shared_bytes
            blocked_pid = None
            kernel = ctypes.WinDLL('kernel32', use_last_error=True)
            kernel.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
                ctypes.c_void_p, wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE]
            kernel.CreateFileW.restype = wintypes.HANDLE
            kernel.CloseHandle.argtypes = [wintypes.HANDLE]
            kernel.CloseHandle.restype = wintypes.BOOL

            def pause_progress(path, value):
                result = write_json(path, value)
                if Path(path).name == 'embedded-progress.json':
                    owner = state.harness.processes[0]
                    if value['stage'] == 'calling-fixed-phase':
                        self.assertTrue(owner.captured.wait(3))
                    elif not published.is_set():
                        published.set()
                        self.assertTrue(resume.wait(5))
                return result

            def read_progress(path, limit=None):
                nonlocal blocked_pid
                owner = state.harness.processes[0]
                if (Path(path).name != 'embedded-progress.json' or not owner.captured.is_set()
                        or blocked_pid is not None):
                    return read_bytes(path, limit)
                self.assertTrue(published.wait(5))
                handle = kernel.CreateFileW(str(path), 0x80000000, 0, None, 3, 0x00200080, None)
                if handle in (None, ctypes.c_void_p(-1).value):
                    raise ctypes.WinError(ctypes.get_last_error())
                try:
                    return read_bytes(path, limit)
                except OSError as error:
                    self.assertEqual(error.winerror, 32)
                    blocked_pid = owner.capture['pid']
                    raise
                finally:
                    try:
                        if not kernel.CloseHandle(handle):
                            raise ctypes.WinError(ctypes.get_last_error())
                    finally:
                        resume.set()

            try:
                with patch.object(state.native.bootstrap, 'write_json', side_effect=pause_progress), \
                        patch.object(state.module, '_shared_bytes', side_effect=read_progress):
                    self.drive(state)
            finally:
                resume.set()
            self.assertIsNotNone(blocked_pid, 'The real reader must encounter the Win32 sharing violation')
            self.assertIsNone(state.caught)
            self.assertEqual([owner.phase for owner in state.harness.processes], ['inspect'])
            owner = state.harness.processes[0]
            self.assertEqual(blocked_pid, owner.actual_pid)
            self.assert_parent_proof(owner)
            self.assertFalse(owner.profile.exists())
            self.assertEqual(state.result['snapshot']['sourceSha256'], state.native.source_hash)
            self.assertEqual(state.result['snapshot']['previewPageCount'], 3)
            pdf = Path(state.result['snapshot']['previewPdfPath'])
            self.assertEqual(pdf.read_bytes(), b'%PDF-REAL-BOOTSTRAP-FAKE-NATIVE')
            self.assertIsNone(state.harness.parent_pdf_leases[0]._handle)

    def test_progress_lock_uses_the_shared_deadline_and_other_errors_fail_immediately(self):
        for name, code, expected_reads in (
                ('embedded-progress.json', 32, 3), ('embedded-progress.json', 33, 3),
                ('embedded-progress.json', 5, 1), ('response.json', 32, 1)):
            with self.subTest(name=name, code=code), self.fixture(inspect_preview=False) as state:
                reads = 0
                read_bytes = state.module._shared_bytes

                def reject(path, limit=None):
                    nonlocal reads
                    if Path(path).name != name:
                        return read_bytes(path, limit)
                    reads += 1
                    self.assertLessEqual(reads, expected_reads, 'The read exceeded its expected retry budget')
                    state.harness.offset += 60
                    raise ctypes.WinError(code)

                with patch.object(state.module, '_shared_bytes', side_effect=reject):
                    self.drive(state)
                self.assertEqual(reads, expected_reads)
                if expected_reads > 1:
                    self.assertIsInstance(state.caught, TimeoutError)
                    self.assertIn('shared deadline', str(state.caught))
                else:
                    self.assertIsInstance(state.caught, OSError)
                    self.assertEqual(state.caught.winerror, code)
                self.assertIsNone(state.result)
                self.assertEqual([owner.phase for owner in state.harness.processes], ['inspect'])
                owner = state.harness.processes[0]
                proof = json_file(owner.phase_root / 'parent-proof.json')
                self.assertEqual(proof['cleanup']['activeProcesses'], 0)
                self.assertTrue(proof['cleanup']['jobHandleClosed'])
                self.assertEqual(state.harness.close_deadlines, [state.stages._deadline])
                self.assertFalse((state.directory / 'preview.pdf').exists())

    def test_native_error_missing_notify_nonzero_actual_exit_and_timeout_fail_closed(self):
        for fault in ('native-error', 'missing-notify', 'nonzero-exit', 'timeout'):
            with self.subTest(fault=fault), self.fixture(fault=fault) as state:
                self.drive(state)
                self.assertIsNotNone(state.caught)
                self.assertIsNone(state.result)
                self.assertFalse((state.directory / 'edited.pptx').exists())
                self.assertFalse((state.directory / 'preview.pdf').exists())
                if fault == 'native-error':
                    self.assertIn('controlled native PDF failure', str(state.caught))
                    self.assertEqual([owner.phase for owner in state.harness.processes], ['plan', 'render'])
                elif fault == 'timeout':
                    self.assertIsInstance(state.caught, TimeoutError)
                    self.assertLess(state.harness.sleep_count, 10)
                else:
                    self.assertEqual([owner.phase for owner in state.harness.processes], ['plan'])
                if fault == 'missing-notify':
                    self.assertIsInstance(state.caught, ValueError)
                    self.assertIn('Office exited without the final termination notification', str(state.caught))
                self.assertTrue(all(owner.profile.is_dir() for owner in state.harness.processes))
                self.assertTrue(all(document.closed for document in state.native.documents))

    def test_total_deadline_is_not_restarted_after_successful_plan(self):
        with self.fixture(fault='budget-after-plan') as state:
            self.drive(state)
            self.assertIsInstance(state.caught, TimeoutError)
            self.assertIsNone(state.result)
            self.assertEqual([owner.phase for owner in state.harness.processes], ['plan'])
            self.assertEqual(len(set(state.harness.wait_deadlines + state.harness.close_deadlines)), 1)
            self.assertFalse((state.directory / 'edited.pptx').exists())
            self.assertFalse((state.directory / 'preview.pdf').exists())

    def test_foreign_candidate_replacement_is_blocked_or_preserved_and_cleanup_keeps_primary(self):
        with self.fixture(fault='observe-foreign') as state:
            self.drive(state)
            self.assertTrue(state.harness.foreign_replaced or state.harness.foreign_blocked)
            if state.harness.foreign_replaced:
                self.assertIsNotNone(state.caught)
                self.assertIsNone(state.result)
                self.assertEqual((state.directory / 'edited.pptx').read_bytes(), b'FOREIGN REPLACEMENT MUST SURVIVE')
            else:
                self.assertIsNone(state.caught)
                self.assertEqual(state.result['sourceSha256'], digest(state.directory / 'edited.pptx'))
        with self.fixture(fault='native-and-cleanup') as state:
            self.drive(state)
            self.assertIsNotNone(state.caught)
            self.assertIn('controlled native PDF failure', str(state.caught))
            notes = '\n'.join(getattr(state.caught, '__notes__', []))
            self.assertIn('controlled OS cleanup error', notes)
            self.assertIsNone(state.result)


if __name__ == '__main__':
    unittest.main()
