"""Explicit native-stage routing with real package/phase logic and fake native refs.

Root alone executes. Missing injection parameters are BOOTSTRAP failures, not
native-process or embedded-transport behavior evidence. Fixture modules are
imported as modules so unittest does not discover their TestCase classes twice.
"""
import copy
import inspect
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import office_presentation_package_patch as package_patch
import office_presentation_source as source_reader
import office_presentation_source_edit as source_edit
import office_worker as worker
import test_presentation_binding as binding_fixtures
import test_worker_presentation_binding as binding_worker_fixtures
import test_worker_source_text_edit as source_worker_fixtures


REAL_RUN_REQUEST = worker.run_request
REAL_PLAN = source_edit.plan_source_text_edit
REAL_RENDER = source_edit.render_source_candidate
REAL_OBSERVE = source_edit.observe_source_candidate


class RecordingStages:
    """Fixed stage interface; all returned values come from existing product code."""

    def __init__(self, test):
        self.test = test
        self.calls = []
        self.plan_result = None
        self.pdf_lease = None
        self.pdf_state = None

    def plan(self, runtime, source, source_hash, operations, input_job, *, allow_empty_fallback=False):
        self.calls.append('plan')
        self.plan_source = source
        self.plan_bytes = Path(source).read_bytes()
        self.plan_hash = source_hash
        self.operations = copy.deepcopy(operations)
        self.input_job = input_job
        self.allow_empty_fallback = allow_empty_fallback
        self.plan_result = REAL_PLAN(runtime, source, source_hash, operations, input_job,
            server_factory=worker.OfficeServer, objects=worker.objects, snapshot=worker.snapshot,
            allow_empty_fallback=allow_empty_fallback)
        return self.plan_result

    def render(self, runtime, edited, candidate_hash, pdf, clean_job, owner_ledger, owned, pdf_state):
        self.calls.append('render')
        self.test.assertIs(owner_ledger, self.plan_result['owner_ledger'])
        self.edited, self.candidate_hash = edited, candidate_hash
        self.pdf_path, self.clean_job, self.owned, self.pdf_state = pdf, clean_job, owned, pdf_state
        result = REAL_RENDER(runtime, edited, candidate_hash, pdf, clean_job, owner_ledger, owned, pdf_state,
            server_factory=worker.OfficeServer, objects=worker.objects, snapshot=worker.snapshot,
            export_pdf=worker.export_pdf)
        self.pdf_lease = pdf_state['lease']
        self.test.assertIsNotNone(self.pdf_lease._handle)
        self.test.assertTrue(binding_worker_fixtures.write_is_blocked(pdf))
        return result

    def observe(self, runtime, edited, candidate_hash, observer_job, expected_native, expected_core):
        self.calls.append('observe')
        self.observer_job = observer_job
        self.test.assertEqual((edited, candidate_hash), (self.edited, self.candidate_hash))
        self.test.assertIs(expected_native, self.plan_result['expected_native'])
        self.test.assertIs(expected_core, self.plan_result['expected_core'])
        self.test.assertIs(self.pdf_state['lease'], self.pdf_lease)
        self.test.assertIsNotNone(self.pdf_lease._handle)
        self.test.assertTrue(binding_worker_fixtures.write_is_blocked(self.pdf_path))
        result = REAL_OBSERVE(runtime, edited, candidate_hash, observer_job, expected_native, expected_core,
            server_factory=worker.OfficeServer, objects=worker.objects, snapshot=worker.snapshot)
        self.test.assertIs(self.pdf_state['lease'], self.pdf_lease)
        self.test.assertIsNotNone(self.pdf_lease._handle)
        self.test.assertTrue(binding_worker_fixtures.write_is_blocked(self.pdf_path))
        return result

    def inspect(self, runtime, source, source_hash, request, directory):
        self.test.fail('A source apply must not enter the inspect stage')


class ForbiddenStages:
    def __init__(self):
        self.calls = []

    def reject(self, name):
        self.calls.append(name)
        raise AssertionError('The legacy route must not enter native stage ' + name)

    def plan(self, *arguments, **keywords):
        self.reject('plan')

    def render(self, *arguments, **keywords):
        self.reject('render')

    def observe(self, *arguments, **keywords):
        self.reject('observe')

    def inspect(self, *arguments, **keywords):
        self.reject('inspect')


class LocalInspectStages(ForbiddenStages):
    """Models the child's local dispatch without implementing a process runner."""

    def __init__(self, test, local_factory):
        super().__init__()
        self.test, self.local_factory = test, local_factory

    def inspect(self, runtime, source, source_hash, request, directory):
        self.calls.append('inspect')
        self.source, self.source_hash, self.directory = source, source_hash, directory
        self.test.assertEqual(source_worker_fixtures.sha(Path(source).read_bytes()), source_hash)
        return REAL_RUN_REQUEST(runtime, request, directory,
            native_stages=None, server_factory=self.local_factory)


class WorkerEmbeddedRoutesTest(unittest.TestCase):
    def require_injection_api(self):
        contracts = ((worker.run_request, 'native_stages'), (worker.run_request, 'server_factory'),
            (source_edit.apply_source_text_edit, 'native_stages'))
        for function, parameter in contracts:
            parameters = inspect.signature(function).parameters
            self.assertIn(parameter, parameters,
                'BOOTSTRAP: ' + function.__name__ + ' lacks explicit ' + parameter +
                ' injection; this is not native behavior evidence')
            self.assertIsNone(parameters[parameter].default,
                'BOOTSTRAP: explicit injection must default to None and preserve the current fake/native route')

    def run_fixture(self, stages, fixture, *, request_changes=None, **options):
        self.require_injection_api()

        def injected_request(runtime, request, directory, *arguments, **keywords):
            request = {**request, **(request_changes or {})}
            return REAL_RUN_REQUEST(runtime, request, directory, *arguments,
                native_stages=stages, **keywords)

        with patch.object(worker, 'run_request', new=injected_request):
            return fixture(self, **options)

    def test_explicit_source_apply_runs_real_three_phases_with_fresh_contexts_and_one_pdf_lease(self):
        stages = RecordingStages(self)
        state = self.run_fixture(stages, source_worker_fixtures.WorkerSourceTextEditTest.run_case)
        self.assertIsNone(state.caught)
        self.assertEqual(stages.calls, ['plan', 'render', 'observe'])
        self.assertFalse(stages.allow_empty_fallback)
        self.assertEqual(stages.plan_bytes, state.original)
        self.assertEqual(stages.plan_hash, state.original_hash)
        self.assertEqual(stages.operations, [state.operation])
        self.assertEqual(len(state.servers), 3)
        self.assertEqual(len({id(server.context) for server in state.servers}), 3)
        self.assertEqual([stages.input_job.name, stages.clean_job.name, stages.observer_job.name],
            ['source-binding', 'clean-native', 'bound-observer'])
        self.assertTrue(all(read_only for server in state.servers for _, read_only in server.loaded))
        self.assertTrue(all(server.document.close_calls == 1 for server in state.servers))
        self.assertLess(state.events.index(('exit', 0)), state.events.index(('enter', 1)))
        self.assertLess(state.events.index(('exit', 1)), state.events.index(('enter', 2)))
        self.assertEqual(state.pdf_calls, [(1, True, 0)])
        self.assertTrue(all(leased for _, leased in state.close_leases))
        self.assertNotEqual(state.candidate_bytes, state.original)
        self.assertEqual(state.result['sourceSha256'], source_worker_fixtures.sha(state.candidate_bytes))
        self.assertEqual(state.result['pdfSha256'], source_worker_fixtures.sha(state.returned_pdf_bytes))
        self.assertIsNone(stages.pdf_lease._handle)
        self.assertIsNone(stages.pdf_state['lease'])
        table, cell = source_worker_fixtures.WorkerSourceTextEditTest.target_snapshot(
            self, state.result['snapshot'], state.operation)
        self.assertEqual(cell['text'], state.expected_text)
        self.assertEqual(table['sourceTextPatchAuthority']['sourceSha256'], state.result['sourceSha256'])

    def test_mixed_and_missing_or_stale_root_hash_requests_fail_before_any_stage(self):
        cases = ({'mixed': True}, {'root_hash': False},
            {'request_changes': {'expectedSourceSha256': '0' * 64}})
        for options in cases:
            with self.subTest(options=options):
                stages = RecordingStages(self)
                state = self.run_fixture(stages, source_worker_fixtures.WorkerSourceTextEditTest.run_case, **options)
                self.assertIsInstance(state.caught, ValueError)
                self.assertEqual(stages.calls, [])
                self.assertEqual(state.servers, [])
                self.assertEqual(state.patch_calls, [])
                self.assertEqual(state.legacy_effects, [])
                self.assertIsNone(state.result)

    def test_supported_empty_preview_uses_injected_phases_and_preserves_exact_source_zip(self):
        stages = RecordingStages(self)
        state = self.run_fixture(stages, source_worker_fixtures.WorkerSourceTextEditTest.run_case,
            operation_count=0, include_draft=True)
        self.assertIsNone(state.caught)
        self.assertEqual(stages.calls, ['plan', 'render', 'observe'])
        self.assertTrue(stages.allow_empty_fallback)
        self.assertEqual(stages.operations, [])
        self.assertEqual(state.patch_calls, [[]])
        self.assertEqual(state.candidate_bytes, state.original)
        self.assertEqual(state.result['sourceSha256'], state.original_hash)
        self.assertEqual(state.result['draftSnapshot'], state.baseline)
        self.assertEqual(state.pdf_calls, [(1, True, 0)])
        self.assertTrue(all(read_only for server in state.servers for _, read_only in server.loaded))
        self.assertIsNone(stages.pdf_lease._handle)

    def test_grouped_empty_preview_falls_back_only_after_injected_prepare_returns_none(self):
        self.require_injection_api()
        stages = RecordingStages(self)
        with binding_fixtures.PresentationBindingTest.fixture(self) as case:
            reference = case.source.parent / 'native-reference.pptx'
            reference.write_bytes(case.original)
            grouped = dict(case.members)
            part = 'ppt/slides/slide1.xml'
            grouped[part] = grouped[part].replace(b'<p:graphicFrame>', b'<p:grpSp><p:graphicFrame>', 1)
            grouped[part] = grouped[part].replace(b'</p:graphicFrame>', b'</p:graphicFrame></p:grpSp>', 1)
            binding_fixtures.write_package(case.source, grouped.items())
            original = case.source.read_bytes()
            pinned = source_worker_fixtures.sha(original)
            with self.assertRaises(ValueError):
                source_reader.read_pptx_tables(case.source)
            primary = RuntimeError('controlled legacy empty preview dispatch')
            state = SimpleNamespace(events=[], primary=primary, fault=None, unsupported=True, suffix='.pptx')
            servers = []
            job = case.source.parent / 'grouped-empty-preview'

            def server_factory(runtime, directory):
                server = binding_worker_fixtures.Server(case, Path(directory), state, reference)
                servers.append(server)
                return server

            request = {'mode': 'apply', 'sourcePath': str(case.source), 'sessionId': 'legacy-empty',
                'operations': [], 'includeDraftSnapshot': True, 'expectedSourceSha256': pinned}
            with patch.object(worker, 'OfficeServer', side_effect=server_factory), \
                    patch.object(worker, 'apply_operations', side_effect=primary) as legacy, \
                    patch.object(package_patch, 'patch_pptx') as writer, \
                    patch.object(worker, 'export_pdf') as pdf:
                with self.assertRaises(RuntimeError) as failure:
                    REAL_RUN_REQUEST(case.source.parent / 'unused-runtime', request, job, native_stages=stages)
            self.assertIs(failure.exception, primary)
            self.assertEqual(stages.calls, ['plan'])
            self.assertTrue(stages.allow_empty_fallback)
            self.assertIsNone(stages.plan_result)
            self.assertEqual(len(servers), 2)
            self.assertEqual(servers[0].loaded, [])
            self.assertIsNone(servers[0].document)
            self.assertEqual(len(servers[1].loaded), 1)
            loaded, read_only, loaded_bytes = servers[1].loaded[0]
            self.assertEqual(loaded, job / 'working.pptx')
            self.assertFalse(read_only)
            self.assertEqual(loaded_bytes, original)
            self.assertTrue(servers[1].document.closed)
            legacy.assert_called_once()
            writer.assert_not_called()
            pdf.assert_not_called()
            self.assertEqual(case.source.read_bytes(), original)
            self.assertEqual(case.sentinel.read_bytes(), b'DO NOT DELETE')
            self.assertFalse((job / 'edited.pptx').exists())
            self.assertFalse((job / 'preview.pdf').exists())

    def test_pptx_inspect_delegates_once_then_original_worker_uses_explicit_local_factory(self):
        local_calls = []

        def local_factory(runtime, directory):
            server = worker.OfficeServer(runtime, directory)
            local_calls.append((runtime, directory, server))
            return server

        stages = LocalInspectStages(self, local_factory)
        state = self.run_fixture(stages, binding_worker_fixtures.WorkerPresentationBindingTest.run_case,
            preview=True)
        self.assertIsNone(state.caught)
        self.assertEqual(stages.calls, ['inspect'], 'Local native_stages=None must prevent recursive delegation')
        self.assertEqual(len(local_calls), 1)
        self.assertIs(local_calls[0][2], state.server)
        self.assertEqual(local_calls[0][1], stages.directory)
        self.assertEqual(stages.source, state.original_source)
        self.assertEqual(stages.source_hash, state.original_hash)
        self.assertEqual(state.result['snapshot']['sourceSha256'], state.original_hash)
        self.assertEqual(state.snapshot_paths, [state.original_source])
        self.assertEqual(state.snapshot_leases, [True])
        self.assertEqual(state.pdf_leases, [True])
        binding_worker_fixtures.WorkerPresentationBindingTest.assert_prepared_lifetime(self, state)

    def test_generic_docx_ppt_odp_and_ordinary_pptx_apply_keep_original_dispatch(self):
        for suffix in ('.docx', '.ppt', '.odp', '.pptx'):
            with self.subTest(suffix=suffix):
                stages = ForbiddenStages()
                state = self.run_fixture(stages, binding_worker_fixtures.WorkerPresentationBindingTest.run_case,
                    suffix=suffix, apply=True)
                self.assertIs(state.caught, state.primary)
                self.assertEqual(state.apply_calls, 1)
                self.assertEqual(stages.calls, [])
                self.assertEqual(state.prepare_calls, [])
                self.assertEqual(len(state.server.loaded), 1)
                loaded, read_only, _ = state.server.loaded[0]
                self.assertEqual(loaded.name, 'working' + suffix)
                self.assertFalse(read_only)
                self.assertTrue(state.server.document.closed)
                self.assertIsNone(state.result)


if __name__ == '__main__':
    unittest.main()
