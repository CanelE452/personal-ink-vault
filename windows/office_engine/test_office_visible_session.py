import ctypes
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

import office_worker as worker
import process_ownership as ownership


class FakeKernel:
    def __init__(self, *, assignment_fails=False, resume_fails=False):
        self.events = []
        self.launch = None
        self.assignment_fails = assignment_fails
        self.resume_fails = resume_fails
        self.CreateJobObjectW = Mock(side_effect=self.create_job)
        self.SetInformationJobObject = Mock(side_effect=self.set_limits)
        self.CreateProcessW = Mock(side_effect=self.create_process)
        self.AssignProcessToJobObject = Mock(side_effect=self.assign)
        self.ResumeThread = Mock(side_effect=self.resume)
        self.CloseHandle = Mock(side_effect=lambda handle: self.events.append(('close', handle)) or True)
        self.WaitForSingleObject = Mock(side_effect=lambda handle, timeout: self.events.append(('wait', handle, timeout)) or 0)
        self.TerminateProcess = Mock(side_effect=lambda handle, code: self.events.append(('terminate', handle, code)) or True)
        self.TerminateJobObject = Mock(return_value=True)
        self.GetExitCodeProcess = Mock(return_value=True)

    def create_job(self, *_):
        self.events.append(('job', 100))
        return 100

    def set_limits(self, job, kind, pointer, size):
        limits = ctypes.cast(pointer, ctypes.POINTER(ownership._ExtendedLimits)).contents
        self.events.append(('limits', job, kind, limits.basic.flags))
        return True

    def create_process(self, executable, command, process_attributes, thread_attributes,
            inherit, flags, environment, directory, startup_pointer, info_pointer):
        startup = ctypes.cast(startup_pointer, ctypes.POINTER(ownership._StartupInfo)).contents
        self.launch = {'executable': executable, 'command': command.value,
            'inherit': inherit, 'flags': flags, 'directory': directory,
            'startupFlags': startup.flags, 'show': startup.show}
        info = ctypes.cast(info_pointer, ctypes.POINTER(ownership._ProcessInfo)).contents
        info.process, info.thread, info.pid, info.threadId = 101, 102, 201, 202
        self.events.append(('create', 101))
        return True

    def assign(self, job, process):
        self.events.append(('assign', job, process))
        return not self.assignment_fails

    def resume(self, thread):
        self.events.append(('resume', thread))
        return 0xffffffff if self.resume_fails else 0


class VisibleOwnedProcessTest(unittest.TestCase):
    def launch(self, kernel, **options):
        with patch.object(ownership.ctypes, 'WinDLL', return_value=kernel):
            try:
                return ownership.OwnedOfficeProcess(
                    Path('C:/private runtime/program/soffice.com'),
                    ['--nodefault', '-env:UserInstallation=file:///C:/private%20profile'],
                    Path('C:/private runtime/program'), **options)
            except TypeError as error:
                if options.get('show_window') is True:
                    self.fail('The visible owned-process path must accept show_window=True: ' + str(error))
                raise

    def assert_owned_launch(self, kernel):
        self.assertEqual(kernel.launch['startupFlags'], 1)
        self.assertFalse(kernel.launch['inherit'])
        self.assertEqual(kernel.launch['flags'], 0x4 | 0x08000000)
        self.assertIn(('limits', 100, 9, 0x2000), kernel.events)
        self.assertLess(kernel.events.index(('create', 101)), kernel.events.index(('assign', 100, 101)))
        self.assertLess(kernel.events.index(('assign', 100, 101)), kernel.events.index(('resume', 102)))
        self.assertIn('"C:\\private runtime\\program\\soffice.com"', kernel.launch['command'])

    def test_default_launch_remains_hidden_and_job_owned_before_resume(self):
        kernel = FakeKernel()
        process = self.launch(kernel)
        self.assertEqual(kernel.launch['show'], 0)
        self.assert_owned_launch(kernel)
        process.close()
        process.close()
        self.assertEqual(kernel.events.count(('close', 100)), 1)
        self.assertEqual(kernel.events.count(('close', 101)), 1)
        self.assertEqual(kernel.events.count(('close', 102)), 1)
        self.assertIn(('wait', 101, 5000), kernel.events)

    def test_visible_launch_shows_the_office_window_with_the_same_job_boundary(self):
        kernel = FakeKernel()
        process = self.launch(kernel, show_window=True)
        try:
            self.assertEqual(kernel.launch['show'], 1)
            self.assert_owned_launch(kernel)
        finally:
            process.close()
        self.assertEqual(kernel.events.count(('close', 100)), 1)
        self.assertEqual(kernel.events.count(('close', 101)), 1)
        self.assertEqual(kernel.events.count(('close', 102)), 1)

    def test_visible_process_is_never_resumed_when_job_assignment_fails(self):
        kernel = FakeKernel(assignment_fails=True)
        with patch.object(ownership.ctypes, 'get_last_error', return_value=5):
            with self.assertRaises(OSError):
                self.launch(kernel, show_window=True)
        self.assertEqual(kernel.launch['show'], 1)
        self.assertNotIn(('resume', 102), kernel.events)
        self.assertIn(('terminate', 101, 1), kernel.events)
        for handle in (100, 101, 102):
            self.assertEqual(kernel.events.count(('close', handle)), 1)

    def test_visible_resume_failure_closes_all_owned_handles(self):
        kernel = FakeKernel(resume_fails=True)
        with patch.object(ownership.ctypes, 'get_last_error', return_value=5):
            with self.assertRaises(OSError):
                self.launch(kernel, show_window=True)
        self.assertEqual(kernel.launch['show'], 1)
        self.assertIn(('assign', 100, 101), kernel.events)
        self.assertIn(('resume', 102), kernel.events)
        for handle in (100, 101, 102):
            self.assertEqual(kernel.events.count(('close', handle)), 1)

    def test_visibility_requires_an_exact_boolean_before_allocating_a_job(self):
        for value in (0, 1, None, 'yes', []):
            with self.subTest(value=value):
                kernel = FakeKernel()
                with self.assertRaises(TypeError):
                    self.launch(kernel, show_window=value)
                self.assertEqual(kernel.events, [])


class VisibleOfficeServerTest(unittest.TestCase):
    def open_session(self, *, interactive=None, pass_interactive=False, read_only=False,
            missing_document=False, startup_error=None):
        events, launches, loaded = [], [], []
        document = object()
        abort_handler = object()
        profile = None

        def terminate():
            events.append('desktop-terminate')

        def load(url, target, flags, properties):
            values = {item.Name: item.Value for item in properties}
            loaded.append((url, target, flags, values))
            events.append('load')
            return None if missing_document else document

        desktop = SimpleNamespace(loadComponentFromURL=load, terminate=terminate)
        context = SimpleNamespace()
        context.ServiceManager = SimpleNamespace(createInstanceWithContext=lambda name, current: desktop)
        resolver = SimpleNamespace(resolve=lambda url: context)
        local = SimpleNamespace(ServiceManager=SimpleNamespace(createInstanceWithContext=lambda name, current: resolver))
        fake_uno = SimpleNamespace(getComponentContext=lambda: local,
            createUnoStruct=lambda name: SimpleNamespace())

        class Process:
            def close(self):
                events.append('process-close')

            def exit_code(self):
                return None

        def start(executable, arguments, directory, **options):
            launches.append((executable, arguments, directory, options))
            events.append('process-start')
            if startup_error is not None:
                raise startup_error
            return Process()

        with tempfile.TemporaryDirectory(prefix='piv-visible-session-test-') as temporary:
            root = Path(temporary)
            runtime, directory, source = root / 'private runtime', root / 'job', root / '한글 문서.pptx'
            arguments = {'interactive': interactive} if pass_interactive else {}
            with patch.object(worker, 'OwnedOfficeProcess', side_effect=start), \
                    patch.object(worker, 'uno', fake_uno, create=True), \
                    patch.object(worker, 'AbortInteraction', return_value=abort_handler, create=True):
                owner = None
                error = None
                try:
                    owner = worker.OfficeServer(runtime, directory, **arguments)
                    with owner as server:
                        profile = server.profile
                        self.assertTrue(profile.is_dir())
                        self.assertEqual(profile.parent, Path(tempfile.gettempdir()).resolve())
                        self.assertTrue(profile.name.startswith('piv-lo-'))
                        actual = server.load(source, read_only=read_only)
                        self.assertIs(actual, document)
                except Exception as caught:
                    error = caught
                    profile = getattr(owner, 'profile', None)
            if profile is not None:
                self.assertFalse(profile.exists())
            return SimpleNamespace(events=events, launches=launches, loaded=loaded,
                profile=profile, error=error, runtime=runtime, directory=directory,
                source=source, handler=abort_handler)

    def assert_load_contract(self, state, *, hidden, read_only):
        self.assertIsNone(state.error)
        self.assertEqual(len(state.launches), 1)
        executable, arguments, directory, _ = state.launches[0]
        self.assertEqual(executable, state.runtime / 'program/soffice.com')
        self.assertEqual(directory, state.runtime / 'program')
        self.assertIn('--nodefault', arguments)
        self.assertIn('--norestore', arguments)
        self.assertIn('-env:UserInstallation=' + state.profile.as_uri(), arguments)
        self.assertIn('--pidfile=' + str(state.directory / 'office.pid'), arguments)
        self.assertEqual(len([argument for argument in arguments
            if argument.startswith('--accept=pipe,name=piv_office_')
            and argument.endswith(';urp;StarOffice.ComponentContext')]), 1)
        self.assertEqual(len(state.loaded), 1)
        url, target, flags, values = state.loaded[0]
        self.assertEqual((url, target, flags), (state.source.as_uri(), '_blank', 0))
        self.assertEqual(set(values), {'Hidden', 'ReadOnly', 'MacroExecutionMode',
            'UpdateDocMode', 'InteractionHandler'})
        self.assertIs(values['Hidden'], hidden)
        self.assertIs(values['ReadOnly'], read_only)
        self.assertEqual(values['MacroExecutionMode'], 0)
        self.assertEqual(values['UpdateDocMode'], 0)
        self.assertIs(values['InteractionHandler'], state.handler)
        self.assertEqual(state.events, ['process-start', 'load', 'desktop-terminate', 'process-close'])

    def test_default_server_preserves_headless_hidden_load_and_security_properties(self):
        state = self.open_session()
        self.assert_load_contract(state, hidden=True, read_only=False)
        self.assertEqual(state.launches[0][1][0], '--headless')
        self.assertEqual(state.launches[0][3], {})

    def test_explicit_false_preserves_the_default_headless_path(self):
        state = self.open_session(interactive=False, pass_interactive=True, read_only=True)
        self.assert_load_contract(state, hidden=True, read_only=True)
        self.assertEqual(state.launches[0][1][0], '--headless')
        self.assertEqual(state.launches[0][3], {})

    def test_interactive_server_uses_a_visible_job_owned_window_and_safe_load(self):
        state = self.open_session(interactive=True, pass_interactive=True)
        self.assert_load_contract(state, hidden=False, read_only=False)
        self.assertNotIn('--headless', state.launches[0][1])
        self.assertEqual(state.launches[0][3], {'show_window': True})

    def test_interactive_read_only_load_does_not_enable_source_editing(self):
        state = self.open_session(interactive=True, pass_interactive=True, read_only=True)
        self.assert_load_contract(state, hidden=False, read_only=True)

    def test_interactive_mode_requires_an_exact_boolean_before_startup(self):
        for value in (0, 1, 'yes', None, []):
            with self.subTest(value=value), patch.object(worker, 'OwnedOfficeProcess') as start:
                with self.assertRaises(TypeError):
                    worker.OfficeServer(Path('unused-runtime'), Path('unused-job'), interactive=value)
                start.assert_not_called()

    def test_interactive_failed_load_closes_the_process_and_removes_its_profile(self):
        state = self.open_session(interactive=True, pass_interactive=True, missing_document=True)
        self.assertIsInstance(state.error, ValueError)
        self.assertIn('could not be opened', str(state.error))
        self.assertEqual(state.events, ['process-start', 'load', 'desktop-terminate', 'process-close'])

    def test_interactive_startup_failure_removes_the_private_profile(self):
        primary = RuntimeError('controlled private GUI startup failure')
        state = self.open_session(interactive=True, pass_interactive=True, startup_error=primary)
        self.assertIs(state.error, primary)
        self.assertIsNotNone(state.profile)
        self.assertEqual(state.events, ['process-start'])

    def test_interactive_sessions_have_distinct_profiles_and_pipes(self):
        first = self.open_session(interactive=True, pass_interactive=True)
        second = self.open_session(interactive=True, pass_interactive=True)
        self.assertIsNone(first.error)
        self.assertIsNone(second.error)
        self.assertNotEqual(first.profile, second.profile)
        first_pipe = next(argument for argument in first.launches[0][1] if argument.startswith('--accept='))
        second_pipe = next(argument for argument in second.launches[0][1] if argument.startswith('--accept='))
        self.assertNotEqual(first_pipe, second_pipe)


class OfficeProfileCleanupTest(unittest.TestCase):
    def owned_profile(self):
        temporary = tempfile.TemporaryDirectory(prefix='piv-lo-')
        self.addCleanup(temporary.cleanup)
        profile = Path(temporary.name)
        residual = profile / 'user/extensions/bundled/extensions.pmap'
        residual.parent.mkdir(parents=True)
        residual.write_bytes(b'owned extension index retained by a transient Windows sharing error')
        owner = worker.OfficeServer(Path('unused-runtime'), Path('unused-job'))
        owner.profile = profile
        return owner, residual

    def removal(self, *, failures=None, winerror=32):
        original_remove = worker.shutil.rmtree
        attempts, sleeps = [], []

        def remove(target, ignore_errors=False, **options):
            attempts.append(Path(target))
            if failures is None or len(attempts) <= failures:
                if ignore_errors:
                    return
                error = OSError('controlled retained extension index')
                error.winerror = winerror
                raise error
            original_remove(target, **options)

        return remove, attempts, sleeps

    def assert_bounded_delays(self, sleeps):
        self.assertLessEqual(len(sleeps), 19)
        self.assertTrue(all(0 < delay <= .05 for delay in sleeps), sleeps)
        self.assertLessEqual(sum(sleeps), 1)

    def test_transient_sharing_errors_retry_and_remove_the_owned_profile(self):
        for winerror in (32, 33, 5):
            for failures in (1, 2):
                with self.subTest(winerror=winerror, failures=failures):
                    owner, residual = self.owned_profile()
                    remove, attempts, sleeps = self.removal(failures=failures, winerror=winerror)
                    with patch.object(worker.shutil, 'rmtree', side_effect=remove), \
                            patch.object(worker.time, 'sleep', side_effect=sleeps.append):
                        owner.cleanup_profile()
                    self.assertFalse(owner.profile.exists(), 'a transient retained extension index must be retried')
                    self.assertFalse(residual.exists())
                    self.assertEqual(attempts, [owner.profile] * (failures + 1))
                    self.assertEqual(len(sleeps), failures)
                    self.assert_bounded_delays(sleeps)

    def test_persistent_sharing_errors_are_bounded_and_do_not_replace_a_caller_result_or_failure(self):
        for winerror in (32, 33, 5):
            for fail_caller in (False, True):
                with self.subTest(winerror=winerror, fail_caller=fail_caller):
                    owner, residual = self.owned_profile()
                    original_bytes = residual.read_bytes()
                    remove, attempts, sleeps = self.removal(winerror=winerror)
                    primary, result, caught = RuntimeError('original document operation failed'), object(), None
                    with patch.object(worker.shutil, 'rmtree', side_effect=remove), \
                            patch.object(worker.time, 'sleep', side_effect=sleeps.append):
                        try:
                            try:
                                if fail_caller:
                                    raise primary
                                actual = result
                            finally:
                                owner.__exit__(RuntimeError if fail_caller else None,
                                    primary if fail_caller else None, primary.__traceback__)
                        except BaseException as error:
                            caught = error
                    if fail_caller:
                        self.assertIs(caught, primary)
                    else:
                        self.assertIsNone(caught)
                        self.assertIs(actual, result)
                    self.assertTrue(owner.profile.is_dir())
                    self.assertEqual(residual.read_bytes(), original_bytes)
                    self.assertGreaterEqual(len(attempts), 2, 'sharing violations require a bounded retry')
                    self.assertLessEqual(len(attempts), 20)
                    self.assertTrue(all(target == owner.profile for target in attempts))
                    self.assert_bounded_delays(sleeps)

    def test_profiles_outside_the_exact_temporary_parent_and_prefix_are_never_removed(self):
        temporary = tempfile.TemporaryDirectory(prefix='piv-visible-unowned-')
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        nested = root / 'piv-lo-not-an-immediate-temporary-child'
        nested.mkdir()
        for target in (root, nested):
            with self.subTest(target=target), patch.object(worker.shutil, 'rmtree') as remove, \
                    patch.object(worker.time, 'sleep') as sleep:
                owner = worker.OfficeServer(Path('unused-runtime'), Path('unused-job'))
                owner.profile = target
                owner.cleanup_profile()
                remove.assert_not_called()
                sleep.assert_not_called()
                self.assertTrue(target.is_dir())

    def test_non_sharing_errors_preserve_the_profile_without_retries_or_propagation(self):
        owner, residual = self.owned_profile()
        original_bytes = residual.read_bytes()
        remove, attempts, sleeps = self.removal(winerror=87)
        with patch.object(worker.shutil, 'rmtree', side_effect=remove), \
                patch.object(worker.time, 'sleep', side_effect=sleeps.append):
            owner.cleanup_profile()
        self.assertEqual(attempts, [owner.profile])
        self.assertEqual(sleeps, [])
        self.assertEqual(residual.read_bytes(), original_bytes)


if __name__ == '__main__':
    unittest.main()
