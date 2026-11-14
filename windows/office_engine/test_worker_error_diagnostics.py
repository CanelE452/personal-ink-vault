import json
from pathlib import Path
import sys
from tempfile import TemporaryDirectory
from types import FunctionType
import unittest
from unittest.mock import patch

import office_worker as worker


def captured_exception(error):
    try:
        raise error
    except Exception as caught:
        return caught


class WorkerErrorDiagnosticsTest(unittest.TestCase):
    def invoke_main(self, operation, initialize=None):
        with TemporaryDirectory(prefix='piv-worker-error-') as directory:
            root = Path(directory)
            request = root / 'request.json'
            response = root / 'response.json'
            request.write_text(json.dumps({'mode': 'inspect',
                'sourcePath': str(root / 'private-source.pptx')}), encoding='utf-8')
            arguments = ['office_worker.py', '--runtime', str(root / 'runtime'),
                '--request', str(request), '--response', str(response)]

            def dispatch(runtime, selected_request, selected_directory, *, native_stages=None):
                return operation(runtime, selected_request, selected_directory)

            with patch.object(sys, 'argv', arguments), \
                    patch.object(worker, 'initialize', side_effect=initialize), \
                    patch.object(worker, 'run_request', side_effect=dispatch):
                worker.main()
            return json.loads(response.read_text(encoding='utf-8'))

    def assert_frame_summary(self, summary):
        self.assertEqual(set(summary), {'type', 'frames', 'framesTruncated'})
        self.assertIsInstance(summary['type'], str)
        self.assertTrue(0 < len(summary['type']) <= 128)
        self.assertIs(type(summary['framesTruncated']), bool)
        self.assertIsInstance(summary['frames'], list)
        self.assertLessEqual(len(summary['frames']), 16)
        for frame in summary['frames']:
            self.assertEqual(set(frame), {'file', 'function', 'line'})
            for field in ('file', 'function'):
                self.assertIsInstance(frame[field], str)
                self.assertTrue(0 < len(frame[field]) <= 128)
            self.assertNotIn('/', frame['file'])
            self.assertNotIn('\\', frame['file'])
            self.assertNotIn(':', frame['file'])
            self.assertIs(type(frame['line']), int)
            self.assertGreater(frame['line'], 0)

    def assert_error(self, response, message):
        self.assertIs(response['ok'], False)
        error = response['error']
        self.assertEqual(error['code'], 'office_operation_failed')
        self.assertEqual(error['message'], message)
        self.assertIn('diagnostics', error)
        diagnostics = error['diagnostics']
        self.assertEqual(set(diagnostics), {'type', 'frames', 'framesTruncated',
            'causes', 'causesTruncated'})
        self.assert_frame_summary({key: diagnostics[key]
            for key in ('type', 'frames', 'framesTruncated')})
        self.assertIsInstance(diagnostics['causes'], list)
        self.assertLessEqual(len(diagnostics['causes']), 2)
        self.assertIs(type(diagnostics['causesTruncated']), bool)
        for cause in diagnostics['causes']:
            self.assert_frame_summary(cause)
        return diagnostics

    def test_success_response_remains_exact_without_error_diagnostics(self):
        result = {'snapshot': {'kind': 'presentation', 'sourceSha256': 'a' * 64,
            'slides': []}, 'engineVersion': 'controlled test version'}
        response = self.invoke_main(lambda *_: result)
        self.assertEqual(response, {'ok': True, 'result': result})

    def test_cli_failure_preserves_code_and_message_with_its_innermost_frame(self):
        def read_cell(*_):
            raise RuntimeError('illegal object given!')

        diagnostics = self.assert_error(self.invoke_main(read_cell), 'illegal object given!')
        self.assertEqual(diagnostics['type'], 'RuntimeError')
        self.assertEqual(diagnostics['frames'][-1]['file'], 'test_worker_error_diagnostics.py')
        self.assertEqual(diagnostics['frames'][-1]['function'], 'read_cell')
        self.assertIs(diagnostics['framesTruncated'], False)
        self.assertEqual(diagnostics['causes'], [])
        self.assertIs(diagnostics['causesTruncated'], False)

    def test_initialization_failure_uses_the_same_bounded_error_response(self):
        def initialize_runtime(*_):
            raise OSError('controlled runtime initialization failed')

        def unexpected_operation(*_):
            raise AssertionError('The request must not run after initialization failed')

        response = self.invoke_main(unexpected_operation, initialize=initialize_runtime)
        diagnostics = self.assert_error(response, 'controlled runtime initialization failed')
        self.assertEqual(diagnostics['type'], 'OSError')
        self.assertEqual(diagnostics['frames'][-1]['function'], 'initialize_runtime')
        self.assertEqual(diagnostics['causes'], [])

    def test_long_stack_keeps_the_innermost_sixteen_frames_in_call_order(self):
        blocks = []
        for index in range(24):
            statement = "raise RuntimeError('deep controlled failure')" if index == 23 else \
                'return frame_' + str(index + 1).zfill(2) + '()'
            blocks.append('def frame_' + str(index).zfill(2) + '():\n    ' + statement + '\n')
        namespace = {}
        exec(compile(''.join(blocks), '/private/hidden/deep_catalog.py', 'exec'), namespace)
        response = self.invoke_main(lambda *_: namespace['frame_00']())
        diagnostics = self.assert_error(response, 'deep controlled failure')
        self.assertEqual([frame['function'] for frame in diagnostics['frames']],
            ['frame_08', 'frame_09', 'frame_10', 'frame_11', 'frame_12', 'frame_13',
             'frame_14', 'frame_15', 'frame_16', 'frame_17', 'frame_18', 'frame_19',
             'frame_20', 'frame_21', 'frame_22', 'frame_23'])
        self.assertTrue(all(frame['file'] == 'deep_catalog.py' for frame in diagnostics['frames']))
        self.assertIs(diagnostics['framesTruncated'], True)

    def test_finally_close_failure_retains_the_original_read_failure_separately(self):
        def snapshot_read():
            raise LookupError('original private snapshot read failure')

        def close_document():
            raise RuntimeError('illegal object given!')

        def inspect_document(*_):
            try:
                return snapshot_read()
            finally:
                close_document()

        diagnostics = self.assert_error(self.invoke_main(inspect_document), 'illegal object given!')
        self.assertEqual(diagnostics['type'], 'RuntimeError')
        self.assertEqual(diagnostics['frames'][-1]['function'], 'close_document')
        self.assertEqual(len(diagnostics['causes']), 1)
        self.assertEqual(diagnostics['causes'][0]['type'], 'LookupError')
        self.assertEqual(diagnostics['causes'][0]['frames'][-1]['function'], 'snapshot_read')
        self.assertIs(diagnostics['causesTruncated'], False)
        self.assertNotIn('original private snapshot read failure', json.dumps(diagnostics))

    def test_explicit_cause_takes_precedence_over_an_unrelated_implicit_context(self):
        explicit = captured_exception(LookupError('explicit private cause'))

        def inspect_document(*_):
            try:
                raise TypeError('implicit private context')
            except TypeError:
                raise RuntimeError('controlled public failure') from explicit

        diagnostics = self.assert_error(self.invoke_main(inspect_document), 'controlled public failure')
        self.assertEqual([cause['type'] for cause in diagnostics['causes']], ['LookupError'])
        self.assertIs(diagnostics['causesTruncated'], False)
        serialized = json.dumps(diagnostics)
        self.assertNotIn('explicit private cause', serialized)
        self.assertNotIn('implicit private context', serialized)

    def test_from_none_keeps_suppressed_context_out_of_the_diagnostics(self):
        def inspect_document(*_):
            try:
                raise LookupError('suppressed private context')
            except LookupError:
                raise RuntimeError('controlled public failure') from None

        diagnostics = self.assert_error(self.invoke_main(inspect_document), 'controlled public failure')
        self.assertEqual(diagnostics['causes'], [])
        self.assertIs(diagnostics['causesTruncated'], False)
        self.assertNotIn('suppressed private context', json.dumps(diagnostics))

    def test_long_cause_chain_retains_only_the_two_nearest_causes(self):
        outer = RuntimeError('outer failure')
        first = captured_exception(ValueError('first private cause'))
        second = captured_exception(LookupError('second private cause'))
        third = captured_exception(OSError('third private cause'))
        outer.__cause__, first.__cause__, second.__cause__ = first, second, third

        def inspect_document(*_):
            raise outer

        diagnostics = self.assert_error(self.invoke_main(inspect_document), 'outer failure')
        self.assertEqual([cause['type'] for cause in diagnostics['causes']],
            ['ValueError', 'LookupError'])
        self.assertTrue(all(cause['frames'] for cause in diagnostics['causes']))
        self.assertIs(diagnostics['causesTruncated'], True)

    def test_cyclic_cause_chain_stops_before_repeating_the_root(self):
        outer = RuntimeError('outer cycle failure')
        cause = captured_exception(LookupError('private cycle cause'))
        outer.__cause__, cause.__cause__ = cause, outer

        def inspect_document(*_):
            raise outer

        diagnostics = self.assert_error(self.invoke_main(inspect_document), 'outer cycle failure')
        self.assertEqual([item['type'] for item in diagnostics['causes']], ['LookupError'])
        self.assertIs(diagnostics['causesTruncated'], True)

    def test_virtual_absolute_paths_source_locals_and_messages_are_not_duplicated(self):
        for filename in (r'C:\PRIVATE_CUSTOMER\SECRET_DOCUMENT\capture.py',
                '/PRIVATE_CUSTOMER/SECRET_DOCUMENT/capture.py'):
            with self.subTest(filename=filename):
                namespace = {}
                source = (
                    'def read_cell(*arguments):\n'
                    "    document_text = 'SECRET_BODY_CONTENT_42'\n"
                    "    password = 'SECRET_LOCAL_PASSWORD_73'\n"
                    "    error = RuntimeError('SECRET_MESSAGE_91')\n"
                    "    error.add_note('SECRET_NOTE_18')\n"
                    '    raise error\n')
                exec(compile(source, filename, 'exec'), namespace)
                response = self.invoke_main(namespace['read_cell'])
                diagnostics = self.assert_error(response, 'SECRET_MESSAGE_91')
                self.assertEqual(diagnostics['frames'][-1]['file'], 'capture.py')
                self.assertEqual(diagnostics['frames'][-1]['function'], 'read_cell')
                self.assertEqual(diagnostics['frames'][-1]['line'], 6)
                serialized = json.dumps(diagnostics)
                for secret in ('PRIVATE_CUSTOMER', 'SECRET_DOCUMENT', 'SECRET_BODY_CONTENT_42',
                        'SECRET_LOCAL_PASSWORD_73', 'SECRET_MESSAGE_91', 'SECRET_NOTE_18',
                        'document_text', 'password', 'raise error'):
                    self.assertNotIn(secret, serialized)

    def test_long_exception_frame_file_and_function_names_are_bounded(self):
        type_name = 'ControlledError_' + 'T' * 180
        function_name = 'read_cell_' + 'F' * 180
        file_name = 'catalog_' + 'N' * 180 + '.py'
        exception_type = type(type_name, (RuntimeError,), {})
        namespace = {'exception_type': exception_type}
        exec(compile('def ' + function_name + '(*arguments):\n'
            "    raise exception_type('controlled bounded name failure')\n",
            '/PRIVATE_CUSTOMER/' + file_name, 'exec'), namespace)
        response = self.invoke_main(namespace[function_name])
        diagnostics = self.assert_error(response, 'controlled bounded name failure')
        self.assertTrue(type_name.startswith(diagnostics['type']))
        self.assertTrue(function_name.startswith(diagnostics['frames'][-1]['function']))
        self.assertTrue(file_name.startswith(diagnostics['frames'][-1]['file']))


    def test_missing_traceback_location_is_omitted_without_masking_the_original_failure(self):
        cause = captured_exception(LookupError('controlled original read cause'))

        def missing_location_failure(cause):
            raise RuntimeError('controlled missing location failure') from cause

        unlocated = FunctionType(
            missing_location_failure.__code__.replace(co_linetable=b''), globals())
        try:
            unlocated(cause)
        except RuntimeError as error:
            leaf = error.__traceback__
            while leaf.tb_next is not None:
                leaf = leaf.tb_next
            self.assertIsNone(leaf.tb_lineno)
        else:
            self.fail('The missing-location fixture did not raise its original RuntimeError')

        def inspect_document(*_):
            unlocated(cause)

        failure = None
        try:
            response = self.invoke_main(inspect_document)
        except Exception as error:
            failure = (type(error).__name__, str(error))
        if failure is not None:
            self.fail('worker.main failed to write the original error response: ' +
                failure[0] + ': ' + failure[1])
        diagnostics = self.assert_error(response, 'controlled missing location failure')
        self.assertEqual(diagnostics['type'], 'RuntimeError')
        self.assertIs(diagnostics['framesTruncated'], True)
        self.assertTrue(any(frame['function'] == 'inspect_document' for frame in diagnostics['frames']))
        self.assertFalse(any(frame['function'] == 'missing_location_failure'
            for frame in diagnostics['frames']))
        self.assertEqual([item['type'] for item in diagnostics['causes']], ['LookupError'])
        self.assertTrue(diagnostics['causes'][0]['frames'])
        self.assertIs(diagnostics['causesTruncated'], False)

    def test_zero_traceback_location_is_omitted_instead_of_fabricating_line_one(self):
        cause = captured_exception(LookupError('controlled original read cause'))
        namespace = {}
        exec(compile("def zero_location_failure(cause): raise RuntimeError('controlled zero location failure') from cause\n",
            '/private/zero_location.py', 'exec'), namespace)
        zero_location = FunctionType(
            namespace['zero_location_failure'].__code__.replace(co_firstlineno=0), globals())
        try:
            zero_location(cause)
        except RuntimeError as error:
            leaf = error.__traceback__
            while leaf.tb_next is not None:
                leaf = leaf.tb_next
            self.assertIs(type(leaf.tb_lineno), int)
            self.assertEqual(leaf.tb_lineno, 0)
        else:
            self.fail('The zero-location fixture did not raise its original RuntimeError')

        def inspect_document(*_):
            zero_location(cause)

        failure = None
        try:
            response = self.invoke_main(inspect_document)
        except Exception as error:
            failure = (type(error).__name__, str(error))
        if failure is not None:
            self.fail('worker.main failed to write the original error response: ' +
                failure[0] + ': ' + failure[1])
        diagnostics = self.assert_error(response, 'controlled zero location failure')
        self.assertEqual(diagnostics['type'], 'RuntimeError')
        self.assertIs(diagnostics['framesTruncated'], True)
        self.assertTrue(any(frame['function'] == 'inspect_document' for frame in diagnostics['frames']))
        self.assertFalse(any(frame['function'] == 'zero_location_failure'
            for frame in diagnostics['frames']))
        self.assertEqual([item['type'] for item in diagnostics['causes']], ['LookupError'])
        self.assertTrue(diagnostics['causes'][0]['frames'])
        self.assertIs(diagnostics['causesTruncated'], False)


if __name__ == '__main__':
    unittest.main()
