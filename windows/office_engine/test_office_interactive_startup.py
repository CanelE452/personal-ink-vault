import base64
import importlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import test_office_interactive as fixtures


class StartupOwner:
    def __init__(self):
        self.entered = False
        self.enters = self.exits = 0
        self.deadline = None
        self.events = []

    def __enter__(self):
        self.entered = True
        self.enters += 1
        self.events.append('parent-enter')
        return self

    def __exit__(self, *_):
        self.entered = False
        self.exits += 1
        self.events.append('parent-exit')

    def stage(self, _name, seconds):
        self.deadline = seconds


class InteractiveStartupTest(unittest.TestCase):
    def fixture(self):
        return fixtures.InteractiveBackendTest.fixture(self)

    def main(self, backend, state, owner, initialize, run):
        runtime = state.root / 'runtime'
        runtime.mkdir()
        arguments = ['office_interactive.py', '--runtime', str(runtime), '--request', str(state.request)]
        with patch.object(sys, 'argv', arguments), \
                patch.object(backend, 'Lifetime', return_value=owner), \
                patch.object(backend.office, 'initialize', side_effect=initialize), \
                patch.object(backend, 'run_session', side_effect=run):
            backend.main()

    def test_parent_guard_is_active_before_native_uno_initialization(self):
        backend, state, owner = importlib.import_module('office_interactive'), self.fixture(), StartupOwner()

        def initialize(_runtime):
            self.assertTrue(owner.entered, 'Native DLL initialization must already have a live parent guard')
            owner.events.append('initialize')

        try:
            self.main(backend, state, owner, initialize, lambda *_args, **_kwargs: None)
        except SystemExit as error:
            self.fail('The startup parent guard was not installed before native initialization: ' + str(error))
        self.assertEqual(owner.events, ['parent-enter', 'initialize', 'parent-exit'])
        self.assertEqual((owner.enters, owner.exits), (1, 1))

    def test_gui_session_borrows_the_same_guard_without_leaving_an_outer_startup_deadline(self):
        backend, state, owner = importlib.import_module('office_interactive'), self.fixture(), StartupOwner()

        def run(*_args, **options):
            self.assertTrue(owner.entered)
            factory = options.get('lifetime_factory')
            self.assertIsNotNone(factory, 'The pre-initialize guard must be passed into the edit session')
            with factory(SimpleNamespace()) as borrowed:
                self.assertIs(borrowed, owner)
                borrowed.stage('editing', None)
            self.assertTrue(owner.entered, 'Leaving the borrowed edit scope must not close the real owner guard')
            self.assertIsNone(owner.deadline)

        try:
            self.main(backend, state, owner, lambda _: None, run)
        except SystemExit as error:
            self.fail('The GUI edit did not borrow its startup guard: ' + str(error))
        self.assertEqual((owner.enters, owner.exits), (1, 1))

    def test_initialize_failure_preserves_input_and_closes_the_owner_without_exposing_exception_text(self):
        backend, state, owner = importlib.import_module('office_interactive'), self.fixture(), StartupOwner()
        secret = 'DO_NOT_EXPOSE_PRIVATE_EXCEPTION_CREDENTIAL_OR_PATH'

        def initialize(_runtime):
            raise RuntimeError(secret)

        with self.assertRaises(SystemExit) as error:
            self.main(backend, state, owner, initialize, lambda *_args, **_kwargs: None)
        self.assertEqual(error.exception.code, 1)
        self.assertEqual((owner.enters, owner.exits), (1, 1))
        response = (state.launch / 'response.json').read_bytes()
        self.assertNotIn(secret.encode(), response)
        value = json.loads(response)
        self.assertEqual(value['status'], 'error')
        self.assertEqual(set(value['error']), {'code', 'message'})
        self.assertEqual(state.working.read_bytes(), state.original)

    def test_cancelled_startup_does_not_open_an_unwanted_gui_window(self):
        backend, state = importlib.import_module('office_interactive'), self.fixture()
        options, exporter = fixtures.InteractiveBackendTest.setup_flow(self, state, [])
        lifetime = fixtures.FakeLifetime(self.events, [])
        lifetime.cancelled = True
        options['lifetime_factory'] = lambda _: lifetime
        with patch.object(backend.office, 'export_pdf', side_effect=exporter), \
                patch.object(backend, 'pdf_page_count', return_value=1):
            try:
                result = backend.run_session(state.root / 'runtime', state.request, **options)
            except AssertionError as error:
                self.fail('A cancelled startup must not launch and wait for a new GUI: ' + str(error))
        self.assertEqual(result['status'], 'cancelled')
        self.assertEqual(self.servers, [])
        self.assertEqual(state.working.read_bytes(), state.original)

    def test_saved_recovery_survives_removing_the_old_application_executable_after_an_update(self):
        backend, state = importlib.import_module('office_interactive'), self.fixture()

        def save_close(owner, current):
            owner.document.save(fixtures.office_bytes('native save before application update'))
            owner.document.native_close()

        options, exporter = fixtures.InteractiveBackendTest.setup_flow(self, state, [save_close])
        with patch.object(backend.office, 'export_pdf', side_effect=exporter), \
                patch.object(backend, 'pdf_page_count', return_value=1):
            original = backend.run_session(state.root / 'runtime', state.request, **options)
        Path(state.data['parentExecutablePath']).unlink()
        new_parent = state.root / 'updated-parent.exe'
        new_parent.write_bytes(b'MZ fixed updated application boundary')
        next_launch = state.session / ('interactive-' + fixtures.NEXT_NONCE)
        next_launch.mkdir()
        next_request = next_launch / 'request.json'
        next_request.write_text(json.dumps({**state.data, 'controlNonce': fixtures.NEXT_NONCE,
            'parentExecutablePath': str(new_parent),
            'expectedWorkingSha256': fixtures.sha(state.working.read_bytes()),
            'workingLength': state.working.stat().st_size}), encoding='utf-8')
        options, exporter = fixtures.InteractiveBackendTest.setup_flow(self, state, [])
        with patch.object(backend.office, 'export_pdf', side_effect=exporter), \
                patch.object(backend, 'pdf_page_count', return_value=1):
            recovered = backend.run_session(state.root / 'runtime', next_request, **options)
        self.assertEqual(recovered['status'], 'saved')
        self.assertEqual(recovered['sourceSha256'], original['sourceSha256'])
        self.assertEqual(recovered['pdfSha256'], original['pdfSha256'])
        self.assertEqual(self.servers, [])
        new_parent.unlink()
        with self.assertRaises(backend.InteractiveError):
            backend.read_request(next_request)


@unittest.skipUnless(os.name == 'nt', 'The parent-bound worker job is Windows-only')
class ParentBoundWorkerJobContractTest(unittest.TestCase):
    def powershell(self, body):
        helper = Path(__file__).resolve().parent / 'worker_job.ps1'
        script = ("$ErrorActionPreference = 'Stop'\n"
            "[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)\n"
            "$OutputEncoding = [Console]::OutputEncoding\n. $env:PIV_TEST_WORKER_JOB\n") + body
        encoded = base64.b64encode(script.encode('utf-16-le')).decode('ascii')
        environment = {**os.environ, 'PIV_TEST_WORKER_JOB': str(helper)}
        result = subprocess.run(['powershell.exe', '-NoProfile', '-WindowStyle', 'Hidden',
            '-EncodedCommand', encoded], capture_output=True, timeout=30, env=environment,
            creationflags=subprocess.CREATE_NO_WINDOW)
        stderr = result.stderr.decode('utf-8', errors='replace')
        self.assertEqual(result.returncode, 0, stderr[-4000:])
        return json.loads(result.stdout.decode('utf-8-sig').strip())

    def test_parent_bound_api_is_available_without_changing_the_headless_four_argument_contract(self):
        result = self.powershell(r'''
$headless = [PivOfficeWorkerJob].GetMethod('Run')
$parent = [PivOfficeWorkerJob].GetMethod('RunParentBound')
@{
    headless = @($headless.GetParameters() | ForEach-Object { $_.ParameterType.FullName })
    parent = @(if ($null -ne $parent) { $parent.GetParameters() | ForEach-Object { $_.ParameterType.FullName } })
} | ConvertTo-Json -Compress
''')
        self.assertEqual(result['headless'], ['System.String', 'System.String', 'System.String', 'System.UInt32'])
        self.assertEqual(result['parent'], ['System.String', 'System.String', 'System.String',
            'System.UInt32', 'System.String'])

    def test_wrong_parent_image_is_rejected_before_any_child_executable_is_started(self):
        result = self.powershell(r'''
try {
    [PivOfficeWorkerJob]::RunParentBound('C:\__piv_child_must_not_start__.exe', '', 'C:\',
        [uint32]$env:PIV_TEST_PARENT_ID, 'C:\__piv_wrong_parent_image__.exe') | Out-Null
    @{ rejected = $false } | ConvertTo-Json -Compress
} catch {
    $cause = $_.Exception
    while ($null -ne $cause.InnerException) { $cause = $cause.InnerException }
    @{ rejected = $true; type = $cause.GetType().FullName } | ConvertTo-Json -Compress
}
'''.replace('$env:PIV_TEST_PARENT_ID', str(os.getpid())))
        self.assertTrue(result['rejected'])
        self.assertEqual(result['type'], 'System.InvalidOperationException')

    def test_interactive_wrapper_preserves_the_inherited_private_short_temp_directory(self):
        engine = Path(__file__).resolve().parent
        with tempfile.TemporaryDirectory(prefix='piv-i-') as directory:
            root = Path(directory)
            inherited_temp, wrapper_directory = root / 'cache', root / 'wrapper'
            inherited_temp.mkdir()
            wrapper_directory.mkdir()
            runtime = root / 'runtime'
            (runtime / 'program').mkdir(parents=True)
            launch = root / 'session' / 'interactive-launch'
            launch.mkdir(parents=True)
            request = launch / 'request.json'
            request.write_text(json.dumps({'parentProcessId': os.getpid(),
                'parentExecutablePath': sys.executable}), encoding='utf-8')
            wrapper = wrapper_directory / 'run-office-interactive.ps1'
            wrapper.write_bytes((engine / wrapper.name).read_bytes())
            (wrapper_directory / 'worker_job.ps1').write_text(r'''
Add-Type -TypeDefinition @'
public static class PivOfficeWorkerJob {
    public static int RunParentBound(string executable, string arguments, string cwd,
            uint parentId, string parentExecutable) {
        System.IO.File.WriteAllLines(System.Environment.GetEnvironmentVariable("PIV_TEST_TEMP_CAPTURE"),
            new string[] { System.Environment.GetEnvironmentVariable("TEMP"),
                System.Environment.GetEnvironmentVariable("TMP") });
        return 0;
    }
}
'@
''', encoding='utf-8')
            captured = root / 'captured.txt'
            environment = {**os.environ, 'TEMP': str(inherited_temp), 'TMP': str(inherited_temp),
                'PIV_TEST_TEMP_CAPTURE': str(captured)}
            result = subprocess.run(['powershell.exe', '-NoProfile', '-WindowStyle', 'Hidden',
                '-File', str(wrapper), '-RuntimePath', str(runtime), '-RequestPath', str(request)],
                capture_output=True, timeout=30, env=environment,
                creationflags=subprocess.CREATE_NO_WINDOW)
            self.assertEqual(result.returncode, 0, result.stderr.decode('utf-8', errors='replace')[-4000:])
            self.assertEqual(captured.read_text(encoding='utf-8-sig').splitlines(),
                [str(inherited_temp), str(inherited_temp)])


if __name__ == '__main__':
    unittest.main()
