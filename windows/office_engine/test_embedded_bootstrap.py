"""Trusted embedded dispatch with real package stages and fake native references.

Root alone executes. These tests do not establish native document/process success.
Missing bootstrap or worker APIs are explicit BOOTSTRAP failures.
"""
import builtins
from contextlib import contextmanager, ExitStack
import copy
import ctypes
from ctypes import wintypes
import hashlib
import importlib.util
import inspect
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
from urllib.request import url2pathname
from urllib.parse import urlsplit, unquote

import office_presentation_binding as binding
import office_presentation_package_patch as package_patch
import office_presentation_source as source_reader
import office_presentation_source_edit as source_edit
import office_presentation_stage_wire as wire
from office_presentation_text_source import cell_text_map
import office_worker as worker
import prepare_runtime
import test_presentation_binding as binding_fixtures
import test_presentation_source_edit as source_fixtures
import test_worker_presentation_binding as worker_binding_fixtures


MODULE = Path(__file__).resolve().parent
BOOTSTRAP = MODULE / 'office_embedded_bootstrap.py'
HELPERS = frozenset({
    'office_images.py', 'office_presentation.py', 'office_presentation_binding.py',
    'office_presentation_duplicate.py',
    'office_presentation_package_patch.py', 'office_presentation_source.py',
    'office_presentation_source_edit.py', 'office_presentation_stage_wire.py',
    'office_presentation_structure.py', 'office_presentation_structure_edit.py',
    'office_presentation_structure_wire.py',
    'office_presentation_tables.py', 'office_presentation_text_patch.py',
    'office_presentation_text_source.py', 'office_text.py', 'office_word.py',
    'office_word_export.py', 'office_word_fidelity.py', 'office_word_images.py',
    'office_word_image_mutations.py', 'office_word_inline.py', 'office_word_layout.py',
    'office_word_objects.py', 'office_worker.py', 'prepare_runtime.py',
    'process_ownership.py', 'run-office.ps1', 'worker_job.ps1',
    'office_embedded_bootstrap.py',
})
JOB_TOKEN = 'a' * 32
PHASE_TOKENS = dict(plan='1' * 32, render='2' * 32, observe='3' * 32, inspect='4' * 32)
PHASE_FILES = dict(profile='profile', request='request.json', response='response.json',
    proof='embedded-proof.json', progress='embedded-progress.json', complete='embedded-complete',
    callbackProof='embedded-callback-proof.json', pdfReady='pdf-ready.json', pdfAck='pdf-ack.json')
REAL_PLAN = source_edit.plan_source_text_edit
REAL_RENDER = source_edit.render_source_candidate
REAL_OBSERVE = source_edit.observe_source_candidate
REAL_RUN_REQUEST = worker.run_request


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def json_file(path):
    return json.loads(Path(path).read_text(encoding='utf-8'))


def write_json(path, value):
    with Path(path).open('w', encoding='utf-8', newline='\n') as stream:
        json.dump(value, stream, ensure_ascii=False, allow_nan=False, separators=(',', ':'))
        stream.write('\n')
        stream.flush()
        os.fsync(stream.fileno())


class Veto(Exception):
    pass


class NativeBase:
    pass


class EventInterface:
    pass


class TerminateInterface:
    pass


class CallbackInterface:
    pass


NATIVE_TYPES = SimpleNamespace(Base=NativeBase, XEventListener=EventInterface,
    XTerminateListener=TerminateInterface, XCallback=CallbackInterface,
    TerminationVetoException=Veto)


class FakeAsyncCallback:
    def __init__(self, state):
        self.state, self.callbacks = state, []

    def addCallback(self, callback, data):
        self.state.events.append('callback-post')
        self.callbacks.append((callback, data))
        self.state.test.assertEqual(len(self.callbacks), 1)
        root = self.state.phase_root
        for name in ('response', 'proof', 'progress'):
            self.state.test.assertTrue((root / PHASE_FILES[name]).is_file())
        self.state.test.assertFalse((root / PHASE_FILES['complete']).exists())
        proof = json_file(root / PHASE_FILES['proof'])
        self.state.test.assertEqual(proof['responseSha256'], digest(root / PHASE_FILES['response']))
        self.state.desktop.query()
        if self.state.immediate:
            callback.notify(data)
            self.state.proof_at_callback_return = (root / PHASE_FILES['proof']).read_bytes()

    def deliver(self):
        self.state.test.assertEqual(len(self.callbacks), 1)
        callback, data = self.callbacks[0]
        callback.notify(data)


class FakeDesktop:
    def __init__(self, state):
        self.state, self.listeners = state, []
        self.loader = binding_fixtures.Loader()

    def addTerminateListener(self, listener):
        self.listeners.append(listener)
        self.state.events.append('listener-registered')

    def query(self):
        for listener in self.listeners:
            listener.queryTermination(SimpleNamespace(Source=self))

    def terminate(self):
        self.state.events.append('terminate')
        try:
            self.query()
        except Veto:
            return False
        if self.state.terminate_false:
            return False
        for listener in self.listeners:
            listener.notifyTermination(SimpleNamespace(Source=self))
        return True

    def loadComponentFromURL(self, url, target, flags, properties):
        path = Path(url2pathname(unquote(urlsplit(url).path)))
        values = {item.Name: item.Value for item in properties}
        self.state.test.assertEqual((target, flags), ('_blank', 0))
        self.state.test.assertEqual({key: values[key] for key in
            ('Hidden', 'ReadOnly', 'MacroExecutionMode', 'UpdateDocMode')},
            dict(Hidden=True, ReadOnly=True, MacroExecutionMode=0, UpdateDocMode=0))
        self.state.test.assertIs(values['InteractionHandler'], self.state.abort_handler)
        self.state.test.assertTrue(path.resolve().is_relative_to(self.state.root.resolve()))
        self.state.loads.append(path)
        self.state.events.append('load')
        document = self.loader(path)
        catalog = source_reader.read_pptx_tables(path)
        source_fixtures.prepare_native_document(document, catalog, self.loader)
        document._piv_page_count_before_close = document.DrawPages.Count
        listeners, original_close = [], document.close
        document.addEventListener = listeners.append

        class DisposedPages:
            @property
            def Count(self):
                raise AssertionError('A disposed native document must not supply a new page-count observation')

        def close(ownership):
            self.state.events.append('document-close')
            original_close(ownership)
            document.DrawPages = DisposedPages()
            if not self.state.omit_disposal:
                for observer in listeners:
                    observer.disposing(SimpleNamespace(Source=document))

        document.close = close
        self.state.documents.append(document)
        return document


class EmbeddedBootstrapTest(unittest.TestCase):
    def api(self):
        self.assertTrue(BOOTSTRAP.is_file(),
            'BOOTSTRAP: office_embedded_bootstrap.py is missing; this is not native behavior evidence')
        spec = importlib.util.spec_from_file_location('_piv_bootstrap_test', BOOTSTRAP)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        for name in ('run', '_initialize_uno', 'current_image_path', 'write_json'):
            self.assertTrue(callable(getattr(module, name, None)), 'BOOTSTRAP: missing ' + name)
        self.assertEqual(module.g_exportedScripts, (module.run,))
        return module

    @contextmanager
    def fixture(self, *, operations=None, immediate=False):
        bootstrap = self.api()
        with source_fixtures.PresentationSourceEditTest.loaded(self) as (case, prepared, presentation):
            origin = worker.snapshot(presentation.document, case.sha, object(),
                presentation=presentation, source_path=case.source)
            source = next(table for table in prepared.source_catalog['tables']
                if (table['sourcePart'], table['shapeId']) == ('ppt/slides/slide1.xml', '10'))
            owner_id = next(key for key, owner in presentation.slides.items()
                if owner is prepared.owner_refs[source['sourcePart']])
            table_id = next(key for key, table in presentation.shapes.items()
                if table is prepared.table_refs[(source['sourcePart'], source['shapeId'])])
            native = next(table for slide in origin['slides'] for table in slide['presentationTables']
                if table['id'] == table_id)
            cell = next(cell for cell in native['cells'] if (cell['row'], cell['column']) == (1, 1))
            source_cell = next(cell for cell in source['cells'] if (cell['row'], cell['column']) == (1, 1))
            text = cell_text_map(prepared.source_catalog['parts'][source['sourcePart']], source_cell)['text']
            operation = dict(op='presentationCellTextPatch', authorityVersion=1,
                ownerId=owner_id, tableId=table_id, cellId=cell['id'], expectedSourceSha256=case.sha,
                sourcePart=source['sourcePart'], shapeId=source['shapeId'],
                expectedSourceFrameSha256=hashlib.sha256(
                    prepared.source_catalog['parts'][source['sourcePart']][slice(*source['frameSpan'])]).hexdigest(),
                expectedTextSha256=hashlib.sha256(text.encode('utf-8')).hexdigest(),
                startUtf16=0, endUtf16=4, text='UPDATED 한글😀')
            job_root = case.source.parent / ('piv-embedded-' + JOB_TOKEN)
            job_root.mkdir()
            source_path = job_root / 'source.pptx'
            source_path.write_bytes(case.original)
            helpers = job_root / 'helpers'
            helpers.mkdir()
            for name in HELPERS:
                shutil.copyfile(BOOTSTRAP if name == 'office_embedded_bootstrap.py' else MODULE / name,
                    helpers / name)
            runtime = job_root / 'runtime'
            for name in prepare_runtime.CRITICAL_FILES:
                path = runtime / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(('fake pinned runtime ' + name).encode('ascii'))
            request = dict(mode='apply', sourcePath=str(source_path), sessionId='embedded-unit',
                operations=[operation] if operations is None else operations,
                expectedSourceSha256=case.sha, includeDraftSnapshot=True)
            state = SimpleNamespace(test=self, bootstrap=bootstrap, root=job_root, source=source_path,
                source_hash=case.sha, original=case.original, runtime=runtime, helpers=helpers,
                request=request, operation=operation, text='UPDATED 한글😀' + text[4:],
                immediate=immediate, terminate_false=False, omit_disposal=False,
                events=[], loads=[], documents=[], contexts=[], native_initializations=[],
                phase_root=None, desktop=None, callback=None, parent_lease=None,
                abort_handler=object(), proof_at_callback_return=None, plan_envelope=None,
                plan_token=None, candidate_hash=None)
            with ExitStack() as patches:
                patches.enter_context(patch.object(sys, 'path', list(sys.path)))
                for name in HELPERS:
                    imported = sys.modules.get(Path(name).stem)
                    if imported is not None and hasattr(imported, '__file__'):
                        patches.enter_context(patch.object(imported, '__file__', str(helpers / name)))
                patches.enter_context(patch.object(worker, 'prop', side_effect=lambda name, value:
                    SimpleNamespace(Name=name, Value=value)))
                patches.enter_context(patch.object(worker, 'AbortInteraction',
                    create=True, side_effect=lambda: state.abort_handler))
                patches.enter_context(patch.object(bootstrap, '_initialize_uno',
                    side_effect=lambda runtime, imported_worker:
                        (state.native_initializations.append((runtime, imported_worker)) or NATIVE_TYPES)))
                patches.enter_context(patch.object(bootstrap, 'current_image_path',
                    side_effect=lambda: runtime / 'program/soffice.bin'))
                try:
                    yield state
                finally:
                    if state.parent_lease is not None:
                        state.parent_lease.close()
            self.assertEqual(source_path.read_bytes(), state.original)

    def phase(self, state, phase, *, directory_name=None):
        token = PHASE_TOKENS[phase]
        phase_root = state.root / 'phases' / (token[:12] if directory_name is None else directory_name)
        script = phase_root / 'profile/user/Scripts/python/office_embedded_bootstrap.py'
        script.parent.mkdir(parents=True)
        shutil.copyfile(BOOTSTRAP, script)
        request = copy.deepcopy(state.request)
        if phase == 'inspect':
            request = dict(mode='inspect', sourcePath=str(state.source), preview=state.request.get('preview', False),
                expectedSourceSha256=state.source_hash)
        write_json(phase_root / 'request.json', request)
        manifest = dict(schema='piv.embedded-office/1', jobToken=JOB_TOKEN, phaseToken=token,
            phase=phase, jobRoot=str(state.root), helpers='helpers', runtime=str(state.runtime),
            source='source.pptx', candidate='edited.pptx', pdf='preview.pdf', plan='source-plan',
            sourceSha256=state.source_hash, candidateSha256=state.candidate_hash,
            requestSha256=digest(phase_root / 'request.json'), parentPid=os.getpid(),
            bootstrapSha256=digest(script),
            helperSha256={name: digest(state.helpers / name) for name in HELPERS},
            runtimeSha256={name: digest(state.runtime / name) for name in prepare_runtime.CRITICAL_FILES},
            planEnvelope=state.plan_envelope, planPhaseToken=state.plan_token, **PHASE_FILES)
        write_json(phase_root / 'manifest.json', manifest)
        write_json(phase_root / 'owner.json', {key: manifest[key]
            for key in ('schema', 'jobToken', 'phaseToken', 'jobRoot', 'parentPid')})
        state.phase_root = phase_root
        state.bootstrap.__file__ = script.as_uri()
        state.desktop = FakeDesktop(state)
        state.callback = FakeAsyncCallback(state)

        def service(name, context):
            self.assertEqual(name, 'com.sun.star.awt.AsyncCallback')
            self.assertIs(context, local_context)
            return state.callback

        local_context = SimpleNamespace(ServiceManager=SimpleNamespace(createInstanceWithContext=service))
        state.contexts.append(local_context)
        state.bootstrap.XSCRIPTCONTEXT = SimpleNamespace(getDesktop=lambda: state.desktop,
            getComponentContext=lambda: local_context)
        return manifest

    def invoke(self, state, *, notify=True):
        self.assertIsNone(state.bootstrap.run())
        response = json_file(state.phase_root / PHASE_FILES['response'])
        if notify:
            if not state.immediate:
                state.callback.deliver()
            proof = json_file(state.phase_root / PHASE_FILES['proof'])
            self.assertTrue(proof['terminationNotificationVerified'])
            self.assertEqual((state.phase_root / PHASE_FILES['complete']).read_bytes(),
                (digest(state.phase_root / PHASE_FILES['response']) + '\n').encode('ascii'))
        return response

    def prepare_plan(self, state):
        self.phase(state, 'plan')
        response = self.invoke(state)
        self.assertTrue(response['ok'], response)
        self.assertEqual(response['result']['status'], 'planned')
        state.plan_envelope = response['result']['planEnvelope']
        state.plan_token = PHASE_TOKENS['plan']
        manifest = json_file(state.phase_root / 'manifest.json')
        plan = wire.read_source_plan(state.root / 'source-plan', state.plan_envelope,
            expected_job_token=JOB_TOKEN, expected_phase_token=state.plan_token,
            expected_request_sha256=manifest['requestSha256'], expected_source_sha256=state.source_hash)
        result = package_patch.patch_pptx(state.source, state.root / 'edited.pptx',
            plan['converted'], state.source_hash)
        state.candidate_hash = result['resultSha256']
        self.assertEqual(source_reader.read_pptx_tables(state.root / 'edited.pptx')['parts'], plan['parts'])
        return plan

    def install_ack(self, state, *, corrupt=None, phase='render'):
        real_write = state.bootstrap.write_json

        def record(path, value):
            result = real_write(path, value)
            if Path(path) == state.phase_root / PHASE_FILES['pdfReady']:
                ready = json_file(path)
                self.assertEqual(set(ready), {'schema', 'jobToken', 'phaseToken', 'phase',
                    'requestSha256', 'candidateSha256', 'pdf', 'pdfSha256', 'pdfPageCount', 'pdfStamp', 'nonce'})
                self.assertEqual((ready['schema'], ready['jobToken'], ready['phaseToken'], ready['phase']),
                    ('piv.pdf-handoff/1', JOB_TOKEN, PHASE_TOKENS[phase], phase))
                self.assertEqual(ready['candidateSha256'],
                    state.candidate_hash if phase == 'render' else state.source_hash)
                self.assertEqual(ready['requestSha256'], json_file(state.phase_root / 'manifest.json')['requestSha256'])
                self.assertEqual(ready['pdf'], 'preview.pdf')
                self.assertRegex(ready['nonce'], '^[0-9a-f]{32}$')
                pdf = state.root / 'preview.pdf'
                self.assertTrue(worker_binding_fixtures.write_is_blocked(pdf))
                self.assertTrue(state.documents[-1].closed, 'The document must close before the handoff')
                state.parent_lease = binding._WindowsReadLease(pdf)
                self.assertEqual(list(source_reader._stamp(pdf.stat())), ready['pdfStamp'])
                self.assertEqual(digest(pdf), ready['pdfSha256'])
                self.assertEqual(ready['pdfPageCount'], state.documents[-1]._piv_page_count_before_close)
                ack = {**ready, 'readySha256': digest(path)}
                if corrupt is not None:
                    ack[corrupt] = '0' * (32 if corrupt == 'nonce' else 64)
                write_json(state.phase_root / PHASE_FILES['pdfAck'], ack)
            return result

        return patch.object(state.bootstrap, 'write_json', side_effect=record)

    def test_closed_manifest_owner_tokens_and_fixed_paths_reject_before_native_initialization(self):
        mutations = [lambda value: value.update(module='evil'),
            lambda value: value.update(phase='arbitrary'),
            lambda value: value.update(jobToken='A' * 32),
            lambda value: value.update(parentPid=True),
            lambda value: value.update(response='../foreign.json'),
            lambda value: value.update(profile=str(Path(value['jobRoot']) / 'profile'))]
        for mutate in mutations:
            with self.subTest(mutate=mutate), self.fixture() as state:
                manifest = self.phase(state, 'plan')
                mutate(manifest)
                write_json(state.phase_root / 'manifest.json', manifest)
                with self.assertRaises((ValueError, RuntimeError)):
                    state.bootstrap.run()
                self.assertEqual(state.native_initializations, [])
                self.assertEqual(state.loads, [])
                self.assertFalse((state.phase_root / PHASE_FILES['complete']).exists())
        for selector in ('module', 'function', 'scriptURL', 'service'):
            with self.subTest(selector=selector), self.fixture() as state:
                state.request[selector] = 'untrusted-choice'
                self.phase(state, 'plan')
                with self.assertRaises((ValueError, RuntimeError)):
                    state.bootstrap.run()
                self.assertEqual(state.native_initializations, [])
                self.assertEqual(state.loads, [])
        with self.fixture() as state:
            self.phase(state, 'plan')
            marker = json_file(state.phase_root / 'owner.json')
            marker['phaseToken'] = 'f' * 32
            write_json(state.phase_root / 'owner.json', marker)
            with self.assertRaises((ValueError, RuntimeError)):
                state.bootstrap.run()
            self.assertEqual(state.native_initializations, [])
        with self.fixture() as state:
            self.phase(state, 'plan')
            path = state.phase_root / 'manifest.json'
            raw = path.read_text(encoding='utf-8')
            path.write_text(raw.rstrip()[:-1] + ',"phase":"inspect"}', encoding='utf-8')
            with self.assertRaises((ValueError, RuntimeError)):
                state.bootstrap.run()
            self.assertEqual(state.native_initializations, [])

    def test_compact_phase_directory_keeps_the_full_authenticated_token(self):
        token = PHASE_TOKENS['plan']
        for directory_name in ('f' * 12, token):
            with self.subTest(directory_name=directory_name), self.fixture() as state:
                self.phase(state, 'plan', directory_name=directory_name)
                with self.assertRaisesRegex(ValueError, 'Unexpected owned embedded root or profile'):
                    state.bootstrap.run()
                self.assertEqual(state.native_initializations, [])
                self.assertEqual(state.loads, [])
        with self.fixture() as state:
            manifest = self.phase(state, 'plan')
            manifest['phaseToken'] = token[:12]
            write_json(state.phase_root / 'manifest.json', manifest)
            with self.assertRaisesRegex(ValueError, 'Invalid embedded phase token'):
                state.bootstrap.run()
            self.assertEqual(state.native_initializations, [])
            self.assertEqual(state.loads, [])
        with self.fixture() as state:
            self.phase(state, 'plan')
            owner_path = state.phase_root / 'owner.json'
            marker = json_file(owner_path)
            marker['phaseToken'] = token[:12] + 'f' * 20
            write_json(owner_path, marker)
            with self.assertRaisesRegex(ValueError, 'Embedded owner marker differs'):
                state.bootstrap.run()
            self.assertEqual(state.native_initializations, [])
            self.assertEqual(state.loads, [])

    def test_atomic_writer_preserves_primary_and_removes_only_its_own_pending(self):
        bootstrap = self.api()
        with tempfile.TemporaryDirectory(prefix='piv-embedded-writer-') as temporary:
            destination = Path(temporary) / 'proof.json'
            pending = destination.with_name(destination.name + '.writing')
            destination.write_bytes(b'PRESERVE OLD PUBLISHED RECORD')
            primary = OSError('controlled first publication failure')
            with patch.object(bootstrap.os, 'replace', side_effect=primary), \
                    patch.object(bootstrap, '_replace_existing', side_effect=primary, create=True):
                with self.assertRaises(OSError) as failure:
                    bootstrap.write_json(destination, {'valid': True})
            self.assertIs(failure.exception, primary)
            self.assertFalse(pending.exists())
            self.assertEqual(destination.read_bytes(), b'PRESERVE OLD PUBLISHED RECORD')
            pending.write_bytes(b'FOREIGN PENDING: DO NOT DELETE')
            with self.assertRaises(FileExistsError):
                bootstrap.write_json(destination, {'valid': True})
            self.assertEqual(pending.read_bytes(), b'FOREIGN PENDING: DO NOT DELETE')
            self.assertEqual(destination.read_bytes(), b'PRESERVE OLD PUBLISHED RECORD')

    def test_existing_optional_request_defaults_remain_compatible(self):
        cases = [('inspect', ('preview', 'expectedSourceSha256'), {}, False),
            ('plan', ('includeDraftSnapshot',), {'preview': False, 'imageAssets': []}, False),
            ('plan', ('expectedSourceSha256',), {}, True)]
        for phase, omitted, additions, empty in cases:
            with self.subTest(phase=phase, empty=empty), self.fixture(operations=[] if empty else None) as state:
                manifest = self.phase(state, phase)
                request_path = state.phase_root / 'request.json'
                request = json_file(request_path)
                for key in omitted:
                    request.pop(key)
                request.update(additions)
                write_json(request_path, request)
                manifest['requestSha256'] = digest(request_path)
                write_json(state.phase_root / 'manifest.json', manifest)
                response = self.invoke(state)
                self.assertTrue(response['ok'], response)
                self.assertEqual(len(state.documents), 1)
                self.assertTrue(state.documents[0].closed)
                if phase == 'inspect':
                    self.assertNotIn('previewPdfPath', response['result']['snapshot'])
                else:
                    self.assertEqual(response['result']['status'], 'planned')

    def test_atomic_publication_keeps_an_open_reader_on_its_previous_record(self):
        bootstrap = self.api()
        with tempfile.TemporaryDirectory(prefix='piv-embedded-publish-') as temporary:
            root = Path(temporary).resolve(strict=True)
            self.assertEqual(root.parent, Path(tempfile.gettempdir()).resolve(strict=True))
            self.assertTrue(root.name.startswith('piv-embedded-publish-'))
            destination = root / '상태.json'
            bootstrap.write_json(destination, {'version': 1})
            original = destination.read_bytes()
            kernel = ctypes.WinDLL('kernel32', use_last_error=True)
            kernel.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
                ctypes.c_void_p, wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE]
            kernel.CreateFileW.restype = wintypes.HANDLE
            kernel.ReadFile.argtypes = [wintypes.HANDLE, ctypes.c_void_p, wintypes.DWORD,
                ctypes.POINTER(wintypes.DWORD), ctypes.c_void_p]
            kernel.ReadFile.restype = wintypes.BOOL
            kernel.CloseHandle.argtypes, kernel.CloseHandle.restype = [wintypes.HANDLE], wintypes.BOOL
            handle = kernel.CreateFileW(str(destination), 0x80000000, 7, None, 3, 0x00200080, None)
            if handle in (None, ctypes.c_void_p(-1).value):
                raise ctypes.WinError(ctypes.get_last_error())
            try:
                bootstrap.write_json(destination, {'version': 2})
                buffer, count = ctypes.create_string_buffer(256), wintypes.DWORD()
                if not kernel.ReadFile(handle, buffer, len(buffer), ctypes.byref(count), None):
                    raise ctypes.WinError(ctypes.get_last_error())
                self.assertEqual(buffer.raw[:count.value], original)
                self.assertEqual(json_file(destination), {'version': 2})
                self.assertFalse(destination.with_name(destination.name + '.writing').exists())
            finally:
                if not kernel.CloseHandle(handle):
                    raise ctypes.WinError(ctypes.get_last_error())

    def test_protected_input_reader_still_blocks_atomic_publication(self):
        bootstrap = self.api()
        with tempfile.TemporaryDirectory(prefix='piv-embedded-protected-') as temporary:
            destination = Path(temporary) / 'protected.json'
            bootstrap.write_json(destination, {'version': 1})
            original = destination.read_bytes()
            lease = bootstrap._TrustedLease(destination, False)
            try:
                with self.assertRaises(PermissionError):
                    bootstrap.write_json(destination, {'version': 2})
                self.assertEqual(destination.read_bytes(), original)
                self.assertFalse(destination.with_name(destination.name + '.writing').exists())
                lease.verify()
            finally:
                lease.close()

    def test_all_code_runtime_and_request_pins_precede_source_helper_import_and_origin_is_checked(self):
        for kind in ('helper', 'runtime', 'request', 'bootstrap', 'helper-missing', 'runtime-missing', 'origin'):
            with self.subTest(kind=kind), self.fixture() as state:
                self.phase(state, 'plan')
                if kind == 'helper':
                    with (state.helpers / 'office_presentation_source_edit.py').open('ab') as stream:
                        stream.write(b'\n# changed pinned helper\n')
                elif kind == 'runtime':
                    (state.runtime / prepare_runtime.CRITICAL_FILES[-1]).write_bytes(b'changed')
                elif kind == 'request':
                    with (state.phase_root / 'request.json').open('ab') as stream:
                        stream.write(b' ')
                elif kind == 'bootstrap':
                    script = state.phase_root / 'profile/user/Scripts/python/office_embedded_bootstrap.py'
                    with script.open('ab') as stream:
                        stream.write(b'\n# changed bootstrap\n')
                elif kind in ('helper-missing', 'runtime-missing'):
                    manifest = json_file(state.phase_root / 'manifest.json')
                    pins = manifest['helperSha256' if kind == 'helper-missing' else 'runtimeSha256']
                    pins.pop(next(iter(pins)))
                    write_json(state.phase_root / 'manifest.json', manifest)
                else:
                    worker.__file__ = str(MODULE / 'office_worker.py')
                imports, real_import = [], builtins.__import__

                def imported(name, *arguments, **keywords):
                    if name.startswith('office_'):
                        imports.append(name)
                    return real_import(name, *arguments, **keywords)

                with patch.object(builtins, '__import__', side_effect=imported):
                    with self.assertRaises((ValueError, RuntimeError)):
                        state.bootstrap.run()
                if kind != 'origin':
                    self.assertEqual(imports, [], 'Source helpers must not import before every byte pin verifies')
                self.assertEqual(state.native_initializations, [])
                self.assertEqual(state.loads, [])

    def test_fixed_dispatch_uses_real_plan_wire_render_and_observe_with_fresh_local_contexts(self):
        with self.fixture() as state:
            with patch.object(source_edit, 'plan_source_text_edit', wraps=REAL_PLAN) as planned:
                plan = self.prepare_plan(state)
            planned.assert_called_once()
            self.assertEqual(len(state.contexts), 1)
            self.phase(state, 'render')
            pdf_calls = []

            def pdf(document, destination, kind):
                pdf_calls.append((document, kind))
                Path(destination).write_bytes(b'%PDF-REAL-FILE-FAKE-NATIVE')
                return document.DrawPages.Count

            with patch.object(source_edit, 'render_source_candidate', wraps=REAL_RENDER) as rendered, \
                    patch.object(worker, 'export_pdf', side_effect=pdf), self.install_ack(state):
                response = self.invoke(state)
            self.assertTrue(response['ok'], response)
            rendered.assert_called_once()
            self.assertEqual(response['result']['status'], 'rendered')
            self.assertEqual(response['result']['pdfSha256'], digest(state.root / 'preview.pdf'))
            self.assertEqual(pdf_calls[0][1], 'presentation')
            self.phase(state, 'observe')
            with patch.object(source_edit, 'observe_source_candidate', wraps=REAL_OBSERVE) as observed:
                response = self.invoke(state)
            self.assertTrue(response['ok'], response)
            observed.assert_called_once()
            self.assertEqual(response['result']['status'], 'observed')
            snapshot = response['result']['snapshot']
            table = next(table for slide in snapshot['slides'] for table in slide['presentationTables']
                if table['id'] == state.operation['tableId'])
            cell = next(cell for cell in table['cells'] if cell['id'] == state.operation['cellId'])
            self.assertEqual(cell['text'], state.text)
            self.assertEqual(table['sourceTextPatchAuthority']['sourceSha256'], state.candidate_hash)
            self.assertTrue(all(value is False for value in table['capabilities'].values()))
            self.assertEqual(len({id(context) for context in state.contexts}), 3)
            self.assertEqual(len(state.documents), 3)
            self.assertTrue(all(document.closed and document.close_calls == 1 for document in state.documents))
            self.assertEqual(state.source.read_bytes(), state.original)
            self.assertEqual(plan['source_order'], list(plan['parts']))

    def test_unsupported_before_load_is_the_only_success_with_zero_documents(self):
        with self.fixture(operations=[]) as state:
            # The real source preflight rejects this grouped shape before any native load.
            import zipfile
            with zipfile.ZipFile(state.source) as archive:
                members = {name: archive.read(name) for name in archive.namelist()}
            part = 'ppt/slides/slide1.xml'
            members[part] = members[part].replace(b'<p:graphicFrame>', b'<p:grpSp><p:graphicFrame>', 1)
            members[part] = members[part].replace(b'</p:graphicFrame>', b'</p:graphicFrame></p:grpSp>', 1)
            binding_fixtures.write_package(state.source, members.items())
            state.original = state.source.read_bytes()
            state.source_hash = digest(state.source)
            state.request['expectedSourceSha256'] = state.source_hash
            self.phase(state, 'plan')
            response = self.invoke(state)
            self.assertEqual(response, {'ok': True, 'result': {'status': 'unsupportedBeforeLoad'}})
            proof = json_file(state.phase_root / PHASE_FILES['proof'])
            self.assertEqual((proof['serverEnterCount'], proof['serverExitCount'], proof['loadAttemptCount']), (1, 1, 0))
            self.assertEqual(proof['documents'], [])
            self.assertTrue(proof['unsupportedBeforeLoad'])
            self.assertFalse((state.root / 'source-plan').exists())
        with self.fixture(operations=[]) as state:
            self.phase(state, 'plan')
            with patch.object(source_edit, 'plan_source_text_edit', return_value=None):
                response = self.invoke(state, notify=False)
            self.assertFalse(response['ok'], 'None without the actual entered zero-load phase is not unsupported success')
            self.assertFalse((state.phase_root / PHASE_FILES['complete']).exists())

    def test_pdf_handoff_keeps_real_lease_until_exact_ack_and_preserves_wrong_ack_failure(self):
        for corrupt in (None, 'nonce', 'readySha256'):
            with self.subTest(corrupt=corrupt), self.fixture() as state:
                self.prepare_plan(state)
                self.phase(state, 'render')

                def pdf(document, destination, kind):
                    Path(destination).write_bytes(b'%PDF-HANDOFF-LEASE')
                    return document.DrawPages.Count

                with patch.object(worker, 'export_pdf', side_effect=pdf), self.install_ack(state, corrupt=corrupt):
                    response = self.invoke(state, notify=corrupt is None)
                self.assertIs(response['ok'], corrupt is None)
                if corrupt is not None:
                    self.assertFalse((state.phase_root / PHASE_FILES['complete']).exists())
                    self.assertEqual(len(state.callback.callbacks), 0)
                    proof = json_file(state.phase_root / PHASE_FILES['proof'])
                    self.assertFalse(proof['readyForNaturalCliShutdown'])
                    self.assertIn('error', response)
                if state.parent_lease is not None:
                    self.assertTrue(worker_binding_fixtures.write_is_blocked(state.root / 'preview.pdf'))
                    state.parent_lease.close()
                    state.parent_lease = None
                self.assertFalse(worker_binding_fixtures.write_is_blocked(state.root / 'preview.pdf'))

    def test_inspect_preview_uses_real_worker_and_fixed_leased_pdf_outside_profile(self):
        for foreign_result in (False, True):
            with self.subTest(foreign_result=foreign_result), self.fixture() as state:
                state.request['preview'] = True
                self.phase(state, 'inspect')
                foreign = state.root / 'foreign-sentinel.pdf'
                foreign.write_bytes(b'FOREIGN PDF: DO NOT CHANGE')
                original_foreign = foreign.read_bytes()
                exported = []

                def pdf(document, destination, kind):
                    self.assertTrue(Path(destination).parent == state.phase_root)
                    Path(destination).write_bytes(b'%PDF-INSPECT-REAL-FILE-FAKE-NATIVE')
                    exported.append(Path(destination))
                    return document.DrawPages.Count

                def inspect_request(*arguments, **keywords):
                    result = REAL_RUN_REQUEST(*arguments, **keywords)
                    if foreign_result:
                        result['snapshot']['previewPdfPath'] = str(foreign)
                    return result

                with patch.object(worker, 'export_pdf', side_effect=pdf), \
                        patch.object(worker, 'run_request', side_effect=inspect_request), \
                        self.install_ack(state, phase='inspect'):
                    response = self.invoke(state, notify=not foreign_result)
                self.assertIs(response['ok'], not foreign_result)
                self.assertEqual(len(exported), 1)
                self.assertEqual(len(state.documents), 1)
                self.assertTrue(state.documents[0].closed)
                self.assertEqual(foreign.read_bytes(), original_foreign)
                if foreign_result:
                    self.assertFalse((state.root / 'preview.pdf').exists())
                    self.assertFalse((state.phase_root / PHASE_FILES['complete']).exists())
                else:
                    preview = Path(response['result']['snapshot']['previewPdfPath'])
                    self.assertEqual(preview, state.root / 'preview.pdf')
                    self.assertFalse(preview.is_relative_to(state.phase_root / 'profile'))
                    self.assertEqual(preview.read_bytes(), b'%PDF-INSPECT-REAL-FILE-FAKE-NATIVE')
                    self.assertEqual(response['result']['snapshot']['previewPageCount'],
                        state.documents[0]._piv_page_count_before_close)
                    self.assertTrue(worker_binding_fixtures.write_is_blocked(preview))
                    state.parent_lease.close()
                    state.parent_lease = None
                    self.assertFalse(worker_binding_fixtures.write_is_blocked(preview))

    def test_ready_gate_vetoes_during_flush_and_final_notify_is_authoritative_under_reentrancy(self):
        self.assertIn('native_stages', inspect.signature(worker.run_request).parameters,
            'BOOTSTRAP: worker.run_request lacks native_stages; this is not native behavior evidence')
        self.assertIn('server_factory', inspect.signature(worker.run_request).parameters,
            'BOOTSTRAP: worker.run_request lacks server_factory; this is not native behavior evidence')
        with self.fixture(immediate=True) as state:
            self.phase(state, 'inspect')
            original_write = state.bootstrap.write_json
            early_queries, fsync_counts = [], []
            real_fsync = os.fsync

            def flushing(path, value):
                if state.desktop.listeners and 'callback-post' not in state.events:
                    with self.assertRaises(Veto):
                        state.desktop.query()
                    early_queries.append(str(path))
                before = fsynced.call_count
                result = original_write(path, value)
                self.assertGreater(fsynced.call_count, before, 'Every critical JSON publication must fsync')
                fsync_counts.append(fsynced.call_count)
                return result

            with patch.object(os, 'fsync', wraps=real_fsync) as fsynced, \
                    patch.object(state.bootstrap, 'write_json', side_effect=flushing), \
                    patch.object(worker, 'run_request', wraps=REAL_RUN_REQUEST) as dispatched:
                response = self.invoke(state)
            self.assertTrue(response['ok'], response)
            dispatched.assert_called_once()
            self.assertIsNone(dispatched.call_args.kwargs['native_stages'])
            self.assertTrue(callable(dispatched.call_args.kwargs['server_factory']))
            self.assertTrue(early_queries)
            self.assertTrue(fsync_counts)
            self.assertEqual(state.proof_at_callback_return,
                (state.phase_root / PHASE_FILES['proof']).read_bytes(),
                'Macro code must return without replacing final notify proof')
            proof = json_file(state.phase_root / PHASE_FILES['proof'])
            self.assertEqual(proof['shutdownCallbackPostCount'], 1)
            self.assertTrue(proof['terminationNotificationVerified'])
            self.assertTrue(all(document['disposed'] for document in proof['documents']))
        with self.fixture() as state:
            self.phase(state, 'inspect')
            self.invoke(state, notify=False)
            state.terminate_false = True
            state.callback.deliver()
            self.assertEqual(state.events.count('terminate'), 1)
            self.assertFalse((state.phase_root / PHASE_FILES['complete']).exists())
            self.assertTrue((state.phase_root / PHASE_FILES['callbackProof']).is_file())
            # Natural CLI notification may later be authoritative even after a false callback.
            state.terminate_false = False
            for listener in state.desktop.listeners:
                listener.notifyTermination(SimpleNamespace(Source=state.desktop))
            self.assertTrue(json_file(state.phase_root / PHASE_FILES['proof'])['terminationNotificationVerified'])

    def test_missing_disposal_notification_never_publishes_ready_or_completion(self):
        with self.fixture() as state:
            state.omit_disposal = True
            self.phase(state, 'inspect')
            response = self.invoke(state, notify=False)
            self.assertFalse(response['ok'])
            self.assertTrue(state.documents[0].closed)
            proof = json_file(state.phase_root / PHASE_FILES['proof'])
            self.assertFalse(proof['allDocumentsDisposedAtServerExit'])
            self.assertFalse(proof['readyForNaturalCliShutdown'])
            self.assertEqual(state.callback.callbacks, [])
            self.assertFalse((state.phase_root / PHASE_FILES['complete']).exists())

    def test_final_notification_rejects_response_bytes_changed_after_publication(self):
        with self.fixture() as state:
            self.phase(state, 'inspect')
            response = self.invoke(state, notify=False)
            self.assertTrue(response['ok'], response)
            with (state.phase_root / PHASE_FILES['response']).open('ab') as stream:
                stream.write(b' ')
            state.callback.deliver()
            proof = json_file(state.phase_root / PHASE_FILES['proof'])
            self.assertFalse(proof['terminationNotificationVerified'])
            self.assertIn('terminationNotificationError', proof)
            self.assertFalse((state.phase_root / PHASE_FILES['complete']).exists())

    def test_delayed_ack_preserves_child_lease_and_missing_ack_cannot_complete(self):
        for acknowledged in (True, False):
            with self.subTest(acknowledged=acknowledged), self.fixture() as state:
                self.prepare_plan(state)
                self.phase(state, 'render')
                clock = {'now': 0.0, 'sleeps': 0}

                def pdf(document, destination, kind):
                    Path(destination).write_bytes(b'%PDF-DELAYED-ACK')
                    return document.DrawPages.Count

                def sleeping(seconds):
                    clock['sleeps'] += 1
                    self.assertTrue(state.documents[-1].closed)
                    self.assertTrue(worker_binding_fixtures.write_is_blocked(state.root / 'preview.pdf'))
                    self.assertFalse((state.phase_root / PHASE_FILES['response']).exists())
                    if acknowledged and clock['sleeps'] == 2:
                        ready_path = state.phase_root / PHASE_FILES['pdfReady']
                        ready = json_file(ready_path)
                        state.parent_lease = binding._WindowsReadLease(state.root / 'preview.pdf')
                        self.assertEqual(digest(state.root / 'preview.pdf'), ready['pdfSha256'])
                        write_json(state.phase_root / PHASE_FILES['pdfAck'],
                            {**ready, 'readySha256': digest(ready_path)})
                    clock['now'] += .025 if acknowledged else 31.0

                controlled_time = SimpleNamespace(monotonic=lambda: clock['now'], sleep=sleeping)
                with patch.object(worker, 'export_pdf', side_effect=pdf), \
                        patch.object(state.bootstrap, 'time', controlled_time):
                    response = self.invoke(state, notify=acknowledged)
                self.assertIs(response['ok'], acknowledged)
                self.assertGreater(clock['sleeps'], 0)
                if not acknowledged:
                    self.assertFalse((state.phase_root / PHASE_FILES['complete']).exists())
                    self.assertEqual(state.callback.callbacks, [])

    def test_failed_export_cannot_adopt_an_unattested_pdf_for_deletion(self):
        with self.fixture() as state:
            self.prepare_plan(state)
            self.phase(state, 'render')
            unattested = b'UNATTESTED PDF: PRESERVE THIS IDENTITY'

            def failed_export(document, destination, kind):
                Path(destination).write_bytes(unattested)
                raise RuntimeError('controlled export failure before creation could be attested')

            with patch.object(worker, 'export_pdf', side_effect=failed_export):
                response = self.invoke(state, notify=False)
            self.assertFalse(response['ok'])
            self.assertIn('controlled export failure', response['error']['message'])
            self.assertTrue((state.root / 'preview.pdf').exists(),
                'An exceptional exporter must not make a newly observed identity deletion authority')
            self.assertEqual((state.root / 'preview.pdf').read_bytes(), unattested)
            self.assertEqual(state.callback.callbacks, [])
            self.assertFalse((state.phase_root / PHASE_FILES['complete']).exists())

    def test_export_time_pdf_identity_is_verified_against_the_first_lease(self):
        with self.fixture() as state:
            self.prepare_plan(state)
            self.phase(state, 'render')
            original_lease = binding._WindowsReadLease
            foreign_bytes = b'%PDF-FOREIGN-REPLACEMENT-MUST-SURVIVE'
            replaced = []

            def pdf(document, destination, kind):
                Path(destination).write_bytes(b'%PDF-ORIGINAL-EXPORTED-BYTES')
                return document.DrawPages.Count

            def acquire(filename):
                if Path(filename) == state.root / 'preview.pdf' and not replaced:
                    replacement = state.root / 'foreign-replacement.pdf'
                    replacement.write_bytes(foreign_bytes)
                    before = source_reader._stamp(Path(filename).stat())
                    replacement.replace(filename)
                    after = source_reader._stamp(Path(filename).stat())
                    self.assertNotEqual(before[:2], after[:2])
                    replaced.append((before, after))
                return original_lease(filename)

            with patch.object(worker, 'export_pdf', side_effect=pdf), \
                    patch.object(binding, '_WindowsReadLease', side_effect=acquire), self.install_ack(state):
                response = self.invoke(state, notify=False)
                if response['ok']:
                    state.callback.deliver()
            self.assertEqual(len(replaced), 1)
            self.assertFalse(response['ok'],
                'The original export identity must not be replaced by the later leased file')
            self.assertEqual((state.root / 'preview.pdf').read_bytes(), foreign_bytes)
            self.assertEqual(state.callback.callbacks, [])
            self.assertFalse((state.phase_root / PHASE_FILES['complete']).exists())


if __name__ == '__main__':
    unittest.main()
