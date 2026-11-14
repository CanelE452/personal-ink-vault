"""Route source table additions before any legacy native document mutation."""
import hashlib
import inspect
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import office_embedded_bootstrap as bootstrap
import office_worker as worker


class WorkerSourceStructureDispatchTest(unittest.TestCase):
    def request(self, source, **changes):
        source_hash = hashlib.sha256(source.read_bytes()).hexdigest()
        operation = dict(op='presentationSourceTableAdd', authorityVersion=1, id='new-table-first',
            ownerId='slide-0', expectedSourceSha256=source_hash, sourcePart='ppt/slides/slide1.xml',
            expectedSourcePartSha256='b' * 64, expectedShapeIdInventorySha256='c' * 64,
            xMm=10, yMm=20, columnWidthsMm=[30, 40], rowHeightsMm=[15, 25])
        return dict(mode='apply', sourcePath=str(source), sessionId='source-structure-session',
            expectedSourceSha256=source_hash, operations=[operation], includeDraftSnapshot=True, **changes)

    def execute(self, request_change=None, *, extension='pptx', validation_error=None):
        with TemporaryDirectory(prefix='piv-structure-route-') as directory:
            root = Path(directory).resolve()
            source = root / ('source.' + extension)
            source.write_bytes(b'Actual immutable route fixture; package semantics belong to the planner tests')
            request = self.request(source)
            if request_change is not None:
                request_change(request)
            target = root / 'never-created-before-source-dispatch'
            state = SimpleNamespace(validation=[], applications=[], legacy=[], result=None, error=None)
            stages = object()

            def validate(operations, source_hash):
                state.validation.append((operations, source_hash))
                if validation_error is not None:
                    raise validation_error

            def apply(*arguments, **keywords):
                self.assertFalse(target.exists(), 'The source pipeline owns directory creation')
                state.applications.append((arguments, keywords))
                return {'marker': 'structure source pipeline'}

            def legacy(*arguments, **keywords):
                state.legacy.append((arguments, keywords))
                raise AssertionError('The source structure route reached a legacy native loader')

            module = SimpleNamespace(validate_batch=validate, apply_source_structure_edit=apply)
            with patch.dict('sys.modules', {'office_presentation_structure_edit': module}):
                try:
                    state.result = worker.run_request(root / 'runtime', request, target,
                        native_stages=stages, server_factory=legacy)
                except BaseException as error:
                    state.error = error
            self.assertEqual(source.read_bytes(),
                b'Actual immutable route fixture; package semantics belong to the planner tests')
            state.request, state.target_created, state.stages = request, target.exists(), stages
            return state

    def test_source_add_uses_its_own_validator_and_pipeline_before_directory_or_native_effects(self):
        result = self.execute()
        self.assertIsNone(result.error, str(result.error))
        self.assertEqual(result.result, {'marker': 'structure source pipeline'})
        self.assertEqual(result.legacy, [])
        self.assertEqual(len(result.validation), 1)
        self.assertEqual(result.validation[0],
            (result.request['operations'], result.request['expectedSourceSha256']))
        self.assertEqual(len(result.applications), 1)
        args, kwargs = result.applications[0]
        self.assertEqual(args[3], result.request['operations'])
        self.assertEqual(args[5:7], ('source-structure-session', True))
        self.assertIs(kwargs['native_stages'], result.stages)

    def test_mixed_native_and_legacy_source_text_batches_fail_before_any_dispatch(self):
        for operation in ({'op': 'slideDisplay', 'id': 'slide-0', 'visible': False},
                {'op': 'presentationCellTextPatch'}, None):
            with self.subTest(operation=operation):
                result = self.execute(lambda request: request['operations'].append(operation))
                self.assertIsInstance(result.error, ValueError)
                self.assertEqual((result.validation, result.applications, result.legacy), ([], [], []))
                self.assertFalse(result.target_created)

    def test_wrong_format_missing_root_guard_and_image_assets_fail_before_validator_or_native_effects(self):
        for label, extension, change in (
                ('format', 'docx', None),
                ('guard', 'pptx', lambda request: request.pop('expectedSourceSha256')),
                ('images', 'pptx', lambda request: request.update(imageAssets=[{'id': 'unissued'}]))):
            with self.subTest(label=label):
                result = self.execute(change, extension=extension)
                self.assertIsInstance(result.error, ValueError)
                self.assertEqual((result.validation, result.applications, result.legacy), ([], [], []))
                self.assertFalse(result.target_created)

    def test_semantic_validation_failure_cannot_create_working_directory_or_enter_legacy_loader(self):
        fault = ValueError('closed source structure operation rejected')
        result = self.execute(validation_error=fault)
        self.assertIs(result.error, fault)
        self.assertEqual(len(result.validation), 1)
        self.assertEqual((result.applications, result.legacy), ([], []))
        self.assertFalse(result.target_created)


class StructureEnvelopeFamilyTest(unittest.TestCase):
    def validate(self, manifest, expected_schema):
        function = bootstrap._validate_plan_envelope
        self.assertIn('expected_schema', inspect.signature(function).parameters,
            'BOOTSTRAP: the embedded structure plan requires an explicit family selector')
        return function(manifest, expected_schema=expected_schema)

    def manifest(self, schema):
        return dict(jobToken='a' * 32, planPhaseToken='b' * 32, requestSha256='c' * 64,
            sourceSha256='d' * 64, planEnvelope=dict(schema=schema, jobToken='a' * 32,
                phaseToken='b' * 32, requestSha256='c' * 64, sourceSha256='d' * 64,
                payload=dict(fileName='plan.json', byteLength=50, sha256='e' * 64, nodeCount=20)))

    def test_structure_plan_requires_its_explicit_closed_schema(self):
        self.validate(self.manifest('piv.structure-plan/1'), 'piv.structure-plan/1')

    def test_each_family_rejects_the_other_family_envelope(self):
        for expected, observed in (('piv.structure-plan/1', 'piv.source-plan/1'),
                ('piv.source-plan/1', 'piv.structure-plan/1')):
            with self.subTest(expected=expected):
                with self.assertRaises(ValueError):
                    self.validate(self.manifest(observed), expected)

    def test_unknown_family_is_not_an_arbitrary_schema_override(self):
        with self.assertRaises(ValueError):
            self.validate(self.manifest('untrusted-plan/99'), 'untrusted-plan/99')


if __name__ == '__main__':
    unittest.main()
