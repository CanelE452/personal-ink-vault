"""CLI wiring/lifetime only; document and process behavior is tested separately."""
from contextlib import chdir
import json
from pathlib import Path
import sys
import tempfile
from types import ModuleType, SimpleNamespace
import unittest
from unittest.mock import patch

import office_worker as worker


class WorkerEmbeddedMainTest(unittest.TestCase):
    def invoke(self, primary=None, *, relative=False):
        with tempfile.TemporaryDirectory(prefix='piv-embedded-main-') as temporary:
            root = Path(temporary)
            runtime = root / 'runtime'
            request = {'mode': 'inspect', 'sourcePath': str(root / 'fixture.pptx')}
            input_path, output_path = root / 'request.json', root / 'response.json'
            input_path.write_text(json.dumps(request), encoding='utf-8')
            state = SimpleNamespace(events=[], stages=[], request=request, primary=primary)
            test = self

            class Stages:
                def __init__(self, selected_runtime, selected_request, directory, *, helpers):
                    test.assertEqual(selected_runtime, runtime)
                    test.assertEqual(selected_request, request)
                    test.assertEqual(Path(directory).parent, root)
                    test.assertTrue(Path(directory).name.startswith('job-'))
                    test.assertEqual(Path(helpers), Path(worker.__file__).resolve().parent)
                    self.runtime, self.request, self.directory = selected_runtime, selected_request, directory
                    self.active, self.closed, self.error = False, False, None
                    state.stages.append(self)
                    state.events.append('construct')

                def __enter__(self):
                    self.active = True
                    state.events.append('enter')
                    return self

                def __exit__(self, error_type, error, traceback):
                    self.active, self.closed, self.error = False, True, error
                    state.events.append('exit')
                    return False

            def dispatch(selected_runtime, selected_request, directory, *, native_stages=None):
                state.events.append('run')
                if native_stages is None:
                    return {'missingExplicitStageInjection': True}
                test.assertIs(native_stages, state.stages[0])
                test.assertTrue(native_stages.active)
                test.assertEqual((selected_runtime, selected_request, directory),
                    (native_stages.runtime, native_stages.request, native_stages.directory))
                if primary is not None:
                    raise primary
                return {'entrypointDispatch': 'observed'}

            module = ModuleType('office_embedded_stages')
            module.EmbeddedPresentationStages = Stages
            arguments = ['office_worker.py', '--runtime', 'runtime' if relative else str(runtime), '--request',
                'request.json' if relative else str(input_path), '--response',
                'response.json' if relative else str(output_path)]
            with chdir(root), patch.dict(sys.modules, {'office_embedded_stages': module}), \
                    patch.object(sys, 'argv', arguments), \
                    patch.object(worker, 'initialize', side_effect=lambda _: state.events.append('initialize')), \
                    patch.object(worker, 'run_request', side_effect=dispatch):
                worker.main()
            state.response = json.loads(output_path.read_text(encoding='utf-8'))
            return state

    def test_cli_explicitly_dispatches_with_one_live_stages_context(self):
        state = self.invoke()
        self.assertEqual(state.response, {'ok': True, 'result': {'entrypointDispatch': 'observed'}})
        self.assertEqual(state.events, ['initialize', 'construct', 'enter', 'run', 'exit'])
        self.assertEqual(len(state.stages), 1)
        self.assertTrue(state.stages[0].closed)
        self.assertFalse(state.stages[0].active)
        self.assertIsNone(state.stages[0].error)

    def test_cli_closes_the_stages_context_and_preserves_the_original_dispatch_error(self):
        primary = RuntimeError('controlled original stage failure')
        state = self.invoke(primary)
        self.assertFalse(state.response['ok'])
        self.assertEqual(state.response['error']['code'], 'office_operation_failed')
        self.assertEqual(state.response['error']['message'], str(primary))
        self.assertEqual(state.response['error']['diagnostics']['type'], 'RuntimeError')
        self.assertEqual(state.events, ['initialize', 'construct', 'enter', 'run', 'exit'])
        self.assertEqual(len(state.stages), 1)
        self.assertTrue(state.stages[0].closed)
        self.assertIs(state.stages[0].error, primary)

    def test_relative_cli_output_uses_the_same_absolute_job_root_for_dispatch_and_stages(self):
        state = self.invoke(relative=True)
        self.assertEqual(state.response, {'ok': True, 'result': {'entrypointDispatch': 'observed'}})
        self.assertEqual(state.events, ['initialize', 'construct', 'enter', 'run', 'exit'])
        self.assertEqual(len(state.stages), 1)
        self.assertTrue(state.stages[0].closed)


if __name__ == '__main__':
    unittest.main()
