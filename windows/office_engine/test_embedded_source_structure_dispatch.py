"""Structure family selection must remain explicit in each owned embedded stage."""
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import office_embedded_bootstrap as bootstrap
from office_embedded_stages import EmbeddedPresentationStages


def source_request():
    return {'operations': [{'op': 'presentationSourceTableAdd'}]}


class EmbeddedSourceStructureDispatchTest(unittest.TestCase):
    def selector(self):
        function = getattr(bootstrap, '_is_structure_request', None)
        self.assertTrue(callable(function), 'BOOTSTRAP: explicit structure family selector is absent')
        return function

    def test_family_selector_keeps_inspect_empty_and_source_text_on_their_existing_path(self):
        select = self.selector()
        self.assertTrue(select(source_request()))
        for request in ({'mode': 'inspect'}, {'operations': []},
                {'operations': [{'op': 'presentationCellTextPatch'}]},
                {'operations': [{'op': 'slideDisplay'}]}):
            with self.subTest(request=request):
                self.assertFalse(select(request))

    def test_mixed_family_is_not_classified_as_legacy_or_structure(self):
        select = self.selector()
        for other in (None, {'op': 'presentationCellTextPatch'}, {'op': 'slideDisplay'}):
            with self.subTest(other=other):
                with self.assertRaises(ValueError):
                    select({'operations': [*source_request()['operations'], other]})

    def stage(self, name):
        function = getattr(EmbeddedPresentationStages, name, None)
        self.assertTrue(callable(function), 'BOOTSTRAP: explicit owned stage is absent: ' + name)
        stage = object.__new__(EmbeddedPresentationStages)
        stage._original_request = source_request()
        stage._plan = {'owner_ledger': [], 'expected_native': {}, 'expected_core': {}}
        calls = []
        stage.plan = lambda *a, **k: calls.append(('plan', a, k)) or stage._plan
        stage.render = lambda *a, **k: calls.append(('render', a, k))
        stage.observe = lambda *a, **k: calls.append(('observe', a, k)) or {'sourceSha256': 'candidate'}
        return function, stage, calls

    def test_structure_stage_wrappers_cannot_be_used_with_a_text_frozen_request(self):
        for name in ('plan_structure', 'render_structure', 'observe_structure'):
            with self.subTest(name=name):
                function, stage, calls = self.stage(name)
                stage._original_request = {'operations': [{'op': 'presentationCellTextPatch'}]}
                with self.assertRaises(ValueError):
                    if name == 'plan_structure':
                        function(stage, 'runtime', 'source', 'hash', [], 'work')
                    elif name == 'render_structure':
                        function(stage, 'runtime', 'edited', 'hash', 'pdf', 'work', stage._plan, {}, {})
                    else:
                        function(stage, 'runtime', 'edited', 'hash', 'work', stage._plan)
                self.assertEqual(calls, [])

    def test_render_and_observer_refuse_a_different_detached_plan_before_any_phase(self):
        for name in ('render_structure', 'observe_structure'):
            with self.subTest(name=name):
                function, stage, calls = self.stage(name)
                foreign = {**stage._plan, 'owner_ledger': [{'foreign': True}]}
                with self.assertRaises(ValueError):
                    if name == 'render_structure':
                        function(stage, 'runtime', 'edited', 'hash', 'pdf', 'work', foreign, {}, {})
                    else:
                        function(stage, 'runtime', 'edited', 'hash', 'work', foreign)
                self.assertEqual(calls, [])

    def dispatch(self, phase):
        with TemporaryDirectory(prefix='piv-structure-dispatch-') as temporary:
            root = Path(temporary)
            calls = []
            plan = {'marker': 'detached structure plan'}
            envelope = {'schema': 'piv.structure-plan/1'}

            def legacy(*args, **kwargs):
                raise AssertionError('A structural phase reached the legacy text planner/observer')

            def plan_structure(*args, **kwargs):
                calls.append(('plan', args))
                return plan

            def observe_structure(*args, **kwargs):
                self.assertIs(args[4], plan)
                calls.append(('observe', args))
                return {'sourceSha256': 'candidate'}

            def write_structure(*args, **kwargs):
                self.assertIs(args[1], plan)
                calls.append(('wire', args))
                return envelope

            job = {'structure': True, 'manifest': {'phase': phase, 'sourceSha256': 'a' * 64,
                    'candidateSha256': 'b' * 64, 'jobToken': 'c' * 32, 'phaseToken': 'd' * 32,
                    'requestSha256': 'e' * 64},
                'root': root, 'work': root / 'work', 'runtime': root / 'runtime',
                'source': root / 'source.pptx', 'candidate': root / 'edited.pptx',
                'request': source_request(), 'planData': plan,
                'worker': SimpleNamespace(objects=object(), snapshot=object()),
                'sourceEdit': SimpleNamespace(plan_source_text_edit=legacy, observe_source_candidate=legacy),
                'wire': SimpleNamespace(write_source_plan=legacy),
                'structureEdit': SimpleNamespace(plan_source_structure_edit=plan_structure,
                    observe_source_structure_candidate=observe_structure),
                'structureWire': SimpleNamespace(write_structure_plan=write_structure)}
            with patch.object(bootstrap, '_verify_candidate', lambda j, p: calls.append(('candidate', p))):
                try:
                    result = bootstrap._dispatch(job, {'factory': object()})
                except BaseException as error:
                    self.fail('Structural dispatch must use its explicit family: ' + str(error))
            return result, calls, envelope

    def test_plan_dispatch_uses_structure_planner_and_structure_wire(self):
        result, calls, envelope = self.dispatch('plan')
        self.assertEqual(result, {'status': 'planned', 'planEnvelope': envelope})
        self.assertEqual([call[0] for call in calls], ['plan', 'wire'])

    def test_observer_dispatch_receives_the_full_structure_plan(self):
        result, calls, _ = self.dispatch('observe')
        self.assertEqual(result, {'status': 'observed', 'snapshot': {'sourceSha256': 'candidate'}})
        self.assertEqual([call[0] for call in calls], ['candidate', 'observe'])


if __name__ == '__main__':
    unittest.main()
