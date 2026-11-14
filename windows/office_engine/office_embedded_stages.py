"""Fresh owned embedded Office phases with fixed manifests and verified handoff."""
import copy
import ctypes
from ctypes import wintypes
import hashlib
import json
import math
import os
from pathlib import Path
import secrets
import shutil
import time

import office_embedded_bootstrap as bootstrap
import office_presentation_binding as binding
import office_presentation_source as source_reader
import office_presentation_stage_wire as wire
import prepare_runtime
from process_ownership import OwnedOfficeProcess


_HELPERS = bootstrap._HELPERS
_PHASE_FILES = bootstrap._PHASE_FILES
_SCRIPT_URL = 'vnd.sun.star.script:office_embedded_bootstrap.py$run?language=Python&location=user'
_COPY_LIMIT = 128 * 1024 * 1024
_CLEANUP_SECONDS = 5
_CAPTURE_KEYS = {'pid', 'imagePath', 'imageSha256', 'creationFileTime64', 'inOwnedJob'}
_WAIT_KEYS = {'actualExitCode', 'loaderExitCode', 'activeProcesses'}
_CLEANUP_KEYS = {'activeProcesses', 'actualHandleClosed', 'loaderHandleClosed', 'jobHandleClosed', 'forced', 'errors'}
_READY_KEYS = {'schema', 'jobToken', 'phaseToken', 'phase', 'requestSha256', 'candidateSha256',
    'pdf', 'pdfSha256', 'pdfPageCount', 'pdfStamp', 'nonce'}
_PROOF_KEYS = {'schema', 'jobToken', 'phaseToken', 'phase', 'jobRoot', 'phaseRoot', 'parentPid', 'pid',
    'nativeThreadId', 'requestSha256', 'sourceSha256', 'candidateSha256', 'bootstrapPath',
    'windowsProcessImage', 'windowsProcessImageSha256', 'windowsImageIdentityVerified', 'contextKind',
    'remoteResolverCreated', 'serverEnterCount', 'serverExitCount', 'loadAttemptCount', 'documents',
    'unsupportedBeforeLoad', 'allDocumentsDisposedAtServerExit', 'integrityConfirmed', 'cleanupErrors',
    'responseFlushedBeforeCliReturn', 'readyForNaturalCliShutdown', 'shutdownReadyPublished',
    'terminationObserverRegistered', 'terminationQueryCount', 'terminationVetoCount',
    'terminationNotificationObserved', 'terminationNotificationVerified', 'shutdownCallbackPostCount',
    'shutdownCallbackInvokeCount', 'shutdownCallbackTerminateRequested', 'shutdownCallbackTerminateReturned',
    'stage', 'serverExitHadError', 'responseSha256', 'terminationResponseSha256', 'workerExportRestored',
    'pdfHandoff', 'exceptionNotes', 'terminationNotificationError', 'desktopTerminationObserverDisposed'}
_WORK_NAMES = dict(plan='source-binding', render='clean-native', observe='bound-observer', inspect='inspect-work')


def _require(condition, message):
    if not condition:
        raise ValueError(message)


def _closed(value, keys, label):
    _require(type(value) is dict and set(value) == keys and all(type(key) is str for key in value),
        'Invalid embedded parent ' + label + ' schema')


def _hex(value, length, label):
    return bootstrap._hex(value, length, label)


def _entry(path, directory=False):
    return bootstrap._entry(path, directory)


def _stamp(information):
    return source_reader._stamp(information)


def _digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def _integer(value, minimum=0):
    return type(value) is int and value >= minimum


def _same(left, right):
    return bootstrap._same_json(left, right)


class _Accounting(ctypes.Structure):
    _fields_ = [(name, ctypes.c_longlong) for name in ('totalUser', 'totalKernel', 'periodUser', 'periodKernel')] + [
        (name, wintypes.DWORD) for name in ('pageFaults', 'totalProcesses', 'activeProcesses', 'terminatedProcesses')]


def _kernel(owner):
    kernel = owner.kernel
    declarations = {
        'OpenProcess': ([wintypes.DWORD, wintypes.BOOL, wintypes.DWORD], wintypes.HANDLE),
        'IsProcessInJob': ([wintypes.HANDLE, wintypes.HANDLE, ctypes.POINTER(wintypes.BOOL)], wintypes.BOOL),
        'QueryFullProcessImageNameW': ([wintypes.HANDLE, wintypes.DWORD, wintypes.LPWSTR,
            ctypes.POINTER(wintypes.DWORD)], wintypes.BOOL),
        'QueryInformationJobObject': ([wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD,
            ctypes.POINTER(wintypes.DWORD)], wintypes.BOOL),
        'GetProcessTimes': ([wintypes.HANDLE, *([ctypes.POINTER(wintypes.FILETIME)] * 4)], wintypes.BOOL),
        'WaitForSingleObject': ([wintypes.HANDLE, wintypes.DWORD], wintypes.DWORD),
        'GetExitCodeProcess': ([wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD)], wintypes.BOOL),
        'GetHandleInformation': ([wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD)], wintypes.BOOL),
        'CloseHandle': ([wintypes.HANDLE], wintypes.BOOL),
        'TerminateJobObject': ([wintypes.HANDLE, wintypes.UINT], wintypes.BOOL),
    }
    for name, (arguments, result) in declarations.items():
        function = getattr(kernel, name)
        function.argtypes, function.restype = arguments, result
    return kernel


def _active(owner):
    _kernel(owner)
    information = _Accounting()
    if not owner.kernel.QueryInformationJobObject(owner.job, 1, ctypes.byref(information), ctypes.sizeof(information), None):
        raise ctypes.WinError(ctypes.get_last_error())
    return int(information.activeProcesses)


def _capture_owned_pid(owner, pid, runtime, expected_sha):
    """Hold the actual live process before trusting any completion record."""
    _require(type(pid) is int and 0 < pid <= 0xffffffff, 'Invalid actual embedded process PID')
    _require(getattr(owner, '_piv_actual_handle', None) is None, 'The actual process was already captured')
    kernel = _kernel(owner)
    handle = kernel.OpenProcess(0x00100000 | 0x1000, False, pid)
    if not handle:
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        waited = int(kernel.WaitForSingleObject(handle, 0))
        if waited == 0xffffffff:
            raise ctypes.WinError(ctypes.get_last_error())
        _require(waited == 258, 'An already exited PID cannot establish actual embedded process identity')
        in_job = wintypes.BOOL()
        if not kernel.IsProcessInJob(handle, owner.job, ctypes.byref(in_job)):
            raise ctypes.WinError(ctypes.get_last_error())
        _require(bool(in_job.value), 'The actual embedded process is outside the owned Job')
        image_buffer = ctypes.create_unicode_buffer(32768)
        length = wintypes.DWORD(len(image_buffer))
        if not kernel.QueryFullProcessImageNameW(handle, 0, image_buffer, ctypes.byref(length)):
            raise ctypes.WinError(ctypes.get_last_error())
        _require(0 < length.value < len(image_buffer), 'Invalid actual embedded process image path')
        image = Path(image_buffer.value).resolve(strict=True)
        _require(image == Path(runtime) / 'program/soffice.bin' and _digest(image) == expected_sha,
            'The actual owned process is not the exact pinned soffice.bin')
        created, exited, kernel_time, user_time = (wintypes.FILETIME() for _ in range(4))
        if not kernel.GetProcessTimes(handle, ctypes.byref(created), ctypes.byref(exited),
                ctypes.byref(kernel_time), ctypes.byref(user_time)):
            raise ctypes.WinError(ctypes.get_last_error())
        creation = (int(created.dwHighDateTime) << 32) | int(created.dwLowDateTime)
        _require(creation > 0, 'Missing actual embedded process creation FILETIME')
        result = dict(pid=pid, imagePath=str(image), imageSha256=expected_sha,
            creationFileTime64=creation, inOwnedJob=True)
        owner._piv_actual_handle, owner._piv_actual_pid = handle, pid
        return result
    except BaseException:
        kernel.CloseHandle(handle)
        raise


def _wait_handle(owner, handle, deadline):
    clock = getattr(owner, '_piv_monotonic', time.monotonic)
    while True:
        remaining = max(0, deadline - clock())
        waited = int(owner.kernel.WaitForSingleObject(handle, min(100, int(remaining * 1000))))
        if waited == 0xffffffff:
            raise ctypes.WinError(ctypes.get_last_error())
        if waited == 0:
            code = wintypes.DWORD()
            if not owner.kernel.GetExitCodeProcess(handle, ctypes.byref(code)):
                raise ctypes.WinError(ctypes.get_last_error())
            return int(code.value)
        _require(waited == 258, 'Unexpected owned process wait result')
        if remaining <= 0:
            raise TimeoutError('Owned Office process did not exit within the shared deadline')


def _wait_owned(owner, deadline):
    _kernel(owner)
    _require(getattr(owner, '_piv_actual_handle', None) is not None, 'No held actual embedded process was captured')
    cutoff = deadline - _CLEANUP_SECONDS
    actual = _wait_handle(owner, owner._piv_actual_handle, cutoff)
    loader = _wait_handle(owner, owner.process, cutoff)
    clock, sleep = getattr(owner, '_piv_monotonic', time.monotonic), getattr(owner, '_piv_sleep', time.sleep)
    active = _active(owner)
    while active:
        if clock() >= cutoff:
            raise TimeoutError('The owned Office Job did not become empty within the shared deadline')
        sleep(min(.025, max(0, cutoff - clock())))
        active = _active(owner)
    return dict(actualExitCode=actual, loaderExitCode=loader, activeProcesses=active)


def _closed_handle(kernel, handle):
    if not kernel.CloseHandle(handle):
        raise ctypes.WinError(ctypes.get_last_error())
    flags = wintypes.DWORD()
    ctypes.set_last_error(0)
    _require(not kernel.GetHandleInformation(handle, ctypes.byref(flags)) and ctypes.get_last_error() == 6,
        'An owned Windows handle did not become invalid after CloseHandle')


def _close_owned(owner, deadline):
    """Terminate only this Job on failure, then prove exit and handle closure."""
    result = dict(activeProcesses=None, actualHandleClosed=False, loaderHandleClosed=False,
        jobHandleClosed=False, forced=False, errors=[])
    kernel = _kernel(owner)
    clock, sleep = getattr(owner, '_piv_monotonic', time.monotonic), getattr(owner, '_piv_sleep', time.sleep)
    try:
        result['activeProcesses'] = _active(owner)
        if result['activeProcesses']:
            result['forced'] = True
            if not kernel.TerminateJobObject(owner.job, 1):
                raise ctypes.WinError(ctypes.get_last_error())
        for handle in (getattr(owner, '_piv_actual_handle', None), getattr(owner, 'process', None)):
            if handle is not None:
                _wait_handle(owner, handle, deadline)
        active = _active(owner)
        while active and clock() < deadline:
            sleep(min(.025, max(0, deadline - clock())))
            active = _active(owner)
        result['activeProcesses'] = active
        _require(active == 0, 'Owned Office processes remained active during cleanup')
    except Exception as error:
        result['errors'].append('Waiting for owned process cleanup: ' + str(error))
    for attribute, key in (('_piv_actual_handle', 'actualHandleClosed'), ('process', 'loaderHandleClosed'), ('job', 'jobHandleClosed')):
        handle = getattr(owner, attribute, None)
        if handle is None:
            result[key] = True
            continue
        try:
            _closed_handle(kernel, handle)
            setattr(owner, attribute, None)
            result[key] = True
        except Exception as error:
            result['errors'].append('Closing owned ' + attribute + ': ' + str(error))
    return result


def _shared_bytes(path, limit=None):
    """Read atomically published progress without blocking its next replacement."""
    _entry(path)
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
        ctypes.c_void_p, wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE]
    kernel.CreateFileW.restype = wintypes.HANDLE
    kernel.ReadFile.argtypes = [wintypes.HANDLE, ctypes.c_void_p, wintypes.DWORD,
        ctypes.POINTER(wintypes.DWORD), ctypes.c_void_p]
    kernel.ReadFile.restype = wintypes.BOOL
    kernel.CloseHandle.argtypes, kernel.CloseHandle.restype = [wintypes.HANDLE], wintypes.BOOL
    handle = kernel.CreateFileW(str(path), 0x80000000, 7, None, 3, 0x00200080, None)
    if handle in (None, ctypes.c_void_p(-1).value):
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        chunks, total = [], 0
        buffer = ctypes.create_string_buffer(1024 * 1024)
        while True:
            count = wintypes.DWORD()
            if not kernel.ReadFile(handle, buffer, len(buffer), ctypes.byref(count), None):
                raise ctypes.WinError(ctypes.get_last_error())
            if not count.value:
                break
            total += count.value
            if limit is not None:
                _require(total <= limit, 'An embedded phase record exceeds its file limit')
            chunks.append(buffer.raw[:count.value])
        return b''.join(chunks)
    finally:
        if not kernel.CloseHandle(handle):
            raise ctypes.WinError(ctypes.get_last_error())


def _json_bytes(raw):
    return json.loads(raw.decode('utf-8'), object_pairs_hook=bootstrap._object, parse_constant=bootstrap._constant)


class EmbeddedPresentationStages:
    def __init__(self, runtime, request, directory, *, helpers=None, timeout_seconds=180,
            process_factory=None, monotonic=None, sleep=None):
        _require(type(timeout_seconds) in (int, float) and math.isfinite(timeout_seconds) and
            timeout_seconds > _CLEANUP_SECONDS, 'Invalid embedded operation timeout')
        self.runtime, self.directory = Path(runtime), Path(directory)
        self._original_request = copy.deepcopy(request)
        self._helpers_argument, self._timeout, self._process_factory = helpers, timeout_seconds, process_factory
        self._clock, self._sleep = monotonic or time.monotonic, sleep or time.sleep
        self._deadline, self._job_token, self._source_hash = None, None, None
        self._pins, self._directories, self._owned, self._profiles, self._phases = {}, {}, {}, [], []
        self._plan, self._envelope, self._plan_token, self._candidate_hash = None, None, None, None
        self._pdf_state, self._closed, self._failed = None, False, False

    def __enter__(self):
        _require(not self._closed, 'Embedded stages were already closed')
        return self

    def __exit__(self, error_type, error, traceback):
        if error is not None:
            self._failed = True
        try:
            self.close()
        except Exception as cleanup_error:
            if error is None:
                raise
            error.add_note('Closing embedded parent stages: ' + str(cleanup_error))
        return False

    def _time(self):
        _require(not self._closed, 'Embedded stages were already closed')
        if self._deadline is None:
            self._deadline = self._clock() + self._timeout
        if self._clock() >= self._deadline - _CLEANUP_SECONDS:
            raise TimeoutError('The embedded operation exhausted its shared deadline')

    def _hold_directory(self, path):
        path = Path(path)
        for parent in (*reversed(path.parents), path):
            if parent not in self._directories:
                self._directories[parent] = bootstrap._TrustedLease(parent, True)

    def _new_directory(self, path):
        self._time()
        self._hold_directory(path.parent)
        guard = wire._PathLease(path.parent, True)
        primary = None
        try:
            path.mkdir()
            self._owned[path] = _stamp(path.stat())[:2]
            self._hold_directory(path)
        except BaseException as error:
            primary = error
            raise
        finally:
            try:
                guard.close()
            except Exception as cleanup_error:
                if primary is None:
                    raise
                primary.add_note('Closing embedded directory creation guard: ' + str(cleanup_error))

    def _pin(self, path, expected_hash):
        path = Path(path)
        self._hold_directory(path.parent)
        _hex(expected_hash, 64, 'parent file hash')
        if path not in self._pins:
            before = _stamp(_entry(path))
            lease = binding._WindowsReadLease(path)
            self._pins[path] = (lease, before, expected_hash)
        lease, before, expected = self._pins[path]
        _require(expected == expected_hash and _stamp(_entry(path)) == before and _digest(path) == expected,
            'A pinned embedded parent input changed: ' + path.name)
        return lease

    def _verify_pins(self):
        for lease in self._directories.values():
            lease.verify()
        for path, (_, before, expected) in self._pins.items():
            _require(_stamp(_entry(path)) == before and _digest(path) == expected,
                'A pinned embedded parent input changed: ' + path.name)
        self._verify_pdf()

    def _write(self, path, data):
        self._time()
        self._hold_directory(path.parent)
        _require(not os.path.lexists(path), 'Preserve an existing embedded parent artifact: ' + path.name)
        with path.open('xb') as stream:
            self._owned[path] = _stamp(os.fstat(stream.fileno()))[:2]
            _require(stream.write(data) == len(data), 'Incomplete embedded parent artifact write')
            stream.flush()
            os.fsync(stream.fileno())
        return hashlib.sha256(data).hexdigest()

    def _write_json(self, path, value, *, final=False):
        raw = (json.dumps(value, ensure_ascii=False, allow_nan=False, separators=(',', ':')) + '\n').encode('utf-8')
        if final:
            # Cleanup evidence must still be published after the operation cutoff.
            _require(not os.path.lexists(path), 'Preserve an existing parent cleanup proof')
            with path.open('xb') as stream:
                self._owned[path] = _stamp(os.fstat(stream.fileno()))[:2]
                _require(stream.write(raw) == len(raw), 'Incomplete parent cleanup proof')
                stream.flush()
                os.fsync(stream.fileno())
            return hashlib.sha256(raw).hexdigest()
        return self._write(path, raw)

    def _copy(self, source, destination, expected):
        self._pin(source, expected)
        self._hold_directory(destination.parent)
        _require(not os.path.lexists(destination), 'Preserve an existing embedded copy destination')
        copied = 0
        with source.open('rb') as stream, destination.open('xb') as target:
            self._owned[destination] = _stamp(os.fstat(target.fileno()))[:2]
            while True:
                self._time()
                chunk = stream.read(1024 * 1024)
                if not chunk:
                    break
                copied += len(chunk)
                _require(copied <= _COPY_LIMIT, 'An embedded owned copy exceeds the Office file limit')
                _require(target.write(chunk) == len(chunk), 'Incomplete embedded owned copy')
            target.flush()
            os.fsync(target.fileno())
        self._pin(destination, expected)
        return copied

    def _initialize(self, runtime, source, source_hash):
        self._time()
        runtime, source = Path(runtime).resolve(strict=True), Path(source).resolve(strict=True)
        _hex(source_hash, 64, 'parent source hash')
        _require(runtime == self.runtime.resolve(strict=True), 'The embedded stage runtime differs from its constructor')
        _require(type(self._original_request) is dict and
            Path(self._original_request['sourcePath']).resolve(strict=True) == source,
            'The embedded stage source differs from its frozen request')
        if self._job_token is not None:
            _require(source_hash == self._source_hash and source == self._original_source,
                'The embedded stage source changed between phases')
            self._verify_pins()
            return
        self.runtime = runtime
        self.directory = Path(os.path.abspath(self.directory))
        self._original_source, self._source_hash = source, source_hash
        self._job_token = secrets.token_hex(16)
        if not os.path.lexists(self.directory):
            self._new_directory(self.directory)
        else:
            self._hold_directory(self.directory)
        self._helpers = self.directory / 'helpers'
        self._new_directory(self._helpers)
        self._new_directory(self.directory / 'phases')
        helper_root = Path(self._helpers_argument) if self._helpers_argument is not None else Path(__file__).parent
        helper_root = helper_root.resolve(strict=True)
        self._helper_hashes = {}
        for name in sorted(_HELPERS):
            original = helper_root / name
            expected = _digest(original)
            self._copy(original, self._helpers / name, expected)
            self._helper_hashes[name] = expected
        self._runtime_hashes = {}
        for name in prepare_runtime.CRITICAL_FILES:
            filename = runtime / name
            expected = _digest(filename)
            self._pin(filename, expected)
            self._runtime_hashes[name] = expected
        self._copy(source, self.directory / 'source.pptx', source_hash)
        request = copy.deepcopy(self._original_request)
        request['sourcePath'] = str(self.directory / 'source.pptx')
        self._request_bytes = (json.dumps(request, ensure_ascii=False, allow_nan=False, separators=(',', ':')) + '\n').encode('utf-8')
        self._request_hash = hashlib.sha256(self._request_bytes).hexdigest()
        self._verify_pins()

    def _identity(self, proof, phase_root, manifest):
        _require(type(proof) is dict and set(proof) <= _PROOF_KEYS, 'Invalid closed embedded proof fields')
        required = {'schema', 'jobToken', 'phaseToken', 'phase', 'jobRoot', 'phaseRoot', 'parentPid', 'pid',
            'nativeThreadId', 'requestSha256', 'sourceSha256', 'candidateSha256', 'bootstrapPath',
            'windowsProcessImage', 'windowsProcessImageSha256', 'windowsImageIdentityVerified', 'remoteResolverCreated'}
        _require(required <= set(proof), 'Incomplete embedded process identity proof')
        expected = dict(schema='piv.embedded-office-proof/1', jobToken=self._job_token,
            phaseToken=manifest['phaseToken'], phase=manifest['phase'], jobRoot=str(self.directory),
            phaseRoot=str(phase_root), parentPid=os.getpid(), requestSha256=self._request_hash,
            sourceSha256=self._source_hash, candidateSha256=manifest['candidateSha256'],
            bootstrapPath=str(phase_root / 'profile/user/Scripts/python/office_embedded_bootstrap.py'),
            windowsProcessImage=str(self.runtime / 'program/soffice.bin'),
            windowsProcessImageSha256=self._runtime_hashes['program/soffice.bin'],
            windowsImageIdentityVerified=True, remoteResolverCreated=False)
        _require(all(_same(proof[key], value) for key, value in expected.items()),
            'The embedded identity proof differs from its fixed manifest')
        _require(_integer(proof['pid'], 1) and proof['pid'] <= 0xffffffff and
            _integer(proof['nativeThreadId'], 1), 'Invalid embedded PID or native thread identity')

    def _capture(self, owner, proof, phase_root, manifest):
        self._identity(proof, phase_root, manifest)
        evidence = _capture_owned_pid(owner, proof['pid'], self.runtime, self._runtime_hashes['program/soffice.bin'])
        _closed(evidence, _CAPTURE_KEYS, 'OS capture')
        _require(type(evidence['pid']) is int and evidence['pid'] == proof['pid'] and
            evidence['imagePath'] == str(self.runtime / 'program/soffice.bin') and
            evidence['imageSha256'] == self._runtime_hashes['program/soffice.bin'] and
            _integer(evidence['creationFileTime64'], 1) and evidence['inOwnedJob'] is True,
            'The held OS process identity differs from the embedded producer')
        return evidence

    def _handoff(self, phase_root, manifest, owned, pdf_state):
        path = phase_root / 'pdf-ready.json'
        raw = _shared_bytes(path)
        ready = _json_bytes(raw)
        _closed(ready, _READY_KEYS, 'PDF ready')
        expected = dict(schema='piv.pdf-handoff/1', jobToken=self._job_token,
            phaseToken=manifest['phaseToken'], phase=manifest['phase'], requestSha256=self._request_hash,
            candidateSha256=self._source_hash if manifest['phase'] == 'inspect' else self._candidate_hash,
            pdf='preview.pdf')
        _require(all(_same(ready[key], value) for key, value in expected.items()),
            'The PDF ready record differs from the fixed phase')
        _hex(ready['nonce'], 32, 'PDF handoff nonce')
        _hex(ready['pdfSha256'], 64, 'PDF handoff hash')
        _require(_integer(ready['pdfPageCount'], 1) and type(ready['pdfStamp']) is list and
            len(ready['pdfStamp']) == 4 and all(_integer(value) for value in ready['pdfStamp']),
            'Invalid PDF handoff page count or file stamp')
        pdf = self.directory / 'preview.pdf'
        before = _stamp(_entry(pdf))
        _require(list(before) == ready['pdfStamp'] and before[2] <= _COPY_LIMIT,
            'The exact exported PDF identity differs from its ready record')
        _require(pdf_state.get('lease') is None, 'Preserve an existing parent PDF lease')
        lease = binding._WindowsReadLease(pdf)
        pdf_state['lease'] = lease
        self._pdf_state = pdf_state
        owned[pdf] = tuple(ready['pdfStamp'][:2])
        pdf_state.update(stamp=tuple(ready['pdfStamp']), sha256=ready['pdfSha256'], page_count=ready['pdfPageCount'])
        self._verify_pdf()
        ready_hash = hashlib.sha256(raw).hexdigest()
        self._pin(path, ready_hash)
        ack = {**ready, 'readySha256': ready_hash}
        ack_path = phase_root / 'pdf-ack.json'
        pending = phase_root / 'pdf-ack.pending.json'
        ack_hash = self._write_json(pending, ack)
        identity = self._owned[pending]
        _require(_stamp(_entry(pending))[:2] == identity, 'The owned PDF acknowledgement was replaced')
        _require(not os.path.lexists(ack_path), 'Preserve an existing PDF acknowledgement')
        pending.rename(ack_path)
        self._owned[ack_path] = self._owned.pop(pending)
        self._pin(ack_path, ack_hash)
        _require(self._pins[ack_path][1][:2] == identity, 'The published PDF acknowledgement was replaced')
        return dict(ready=ready, readySha256=ready_hash, ackSha256=ack_hash)

    def _verify_pdf(self):
        if self._pdf_state is not None and self._pdf_state.get('lease') is not None:
            binding._verify_file(self.directory / 'preview.pdf', self._pdf_state['stamp'], self._pdf_state['sha256'])

    def _response(self, phase_root):
        raw = _shared_bytes(phase_root / 'response.json')
        response = _json_bytes(raw)
        _require(type(response) is dict and type(response.get('ok')) is bool, 'Invalid embedded phase response')
        if response['ok']:
            _closed(response, {'ok', 'result'}, 'successful response')
            _require(type(response['result']) is dict, 'Invalid embedded phase result')
        else:
            _closed(response, {'ok', 'error'}, 'failed response')
            _closed(response['error'], {'code', 'message', 'diagnostics'}, 'phase error')
            _require(response['error']['code'] == 'office_operation_failed' and type(response['error']['message']) is str,
                'Invalid embedded phase error')
            raise RuntimeError(response['error']['message'])
        return response, hashlib.sha256(raw).hexdigest()

    def _final(self, phase_root, manifest, capture, handoff, response, response_hash):
        proof = _json_bytes(_shared_bytes(phase_root / 'embedded-proof.json'))
        self._identity(proof, phase_root, manifest)
        _require(proof['pid'] == capture['pid'], 'The final proof PID differs from the held actual process')
        complete = _shared_bytes(phase_root / 'embedded-complete', 65).decode('ascii')
        _require(complete == response_hash + '\n' and proof.get('responseSha256') == response_hash and
            proof.get('terminationResponseSha256') == response_hash,
            'The completed embedded response bytes differ from the original notification')
        for key in ('integrityConfirmed', 'responseFlushedBeforeCliReturn', 'readyForNaturalCliShutdown',
                'shutdownReadyPublished', 'terminationObserverRegistered', 'terminationNotificationObserved',
                'terminationNotificationVerified', 'allDocumentsDisposedAtServerExit'):
            _require(proof.get(key) is True, 'Missing completed embedded boundary: ' + key)
        _require(proof.get('contextKind') == 'XSCRIPTCONTEXT local component context and desktop' and
            type(proof.get('serverEnterCount')) is int and proof['serverEnterCount'] == 1 and
            type(proof.get('serverExitCount')) is int and proof['serverExitCount'] == 1 and
            proof.get('serverExitHadError') is False and proof.get('cleanupErrors') == [] and
            type(proof.get('shutdownCallbackPostCount')) is int and proof['shutdownCallbackPostCount'] == 1 and
            proof.get('stage') == 'complete-after-termination-notification', 'Invalid completed embedded native context proof')
        documents = proof.get('documents')
        _require(type(documents) is list and type(proof.get('unsupportedBeforeLoad')) is bool,
            'Invalid completed embedded document proof')
        unsupported = proof['unsupportedBeforeLoad']
        if unsupported:
            _require(manifest['phase'] == 'plan' and self._original_request.get('operations') == [] and
                self._original_request.get('includeDraftSnapshot', False) and documents == [] and
                type(proof.get('loadAttemptCount')) is int and proof['loadAttemptCount'] == 0,
                'Only a real empty prepare rejection may complete without loading')
        else:
            _require(bool(documents) and type(proof.get('loadAttemptCount')) is int and
                proof['loadAttemptCount'] == len(documents), 'The embedded phase did not load its exact documents')
        for document in documents:
            _closed(document, {'path', 'readOnly', 'hidden', 'macroExecutionMode', 'updateDocMode',
                'abortInteraction', 'disposed', 'observerRegistered', 'disposingNativeThreadId'}, 'document disposal')
            path = Path(document['path'])
            work = phase_root / _WORK_NAMES[manifest['phase']]
            _require(path.is_absolute() and (path.is_relative_to(work) or
                manifest['phase'] == 'render' and path == self.directory / 'edited.pptx'),
                'The embedded phase loaded outside its fixed owned paths')
            _require(all(document[key] is True for key in ('readOnly', 'hidden', 'abortInteraction', 'disposed', 'observerRegistered')) and
                type(document['macroExecutionMode']) is int and document['macroExecutionMode'] == 0 and
                type(document['updateDocMode']) is int and document['updateDocMode'] == 0 and
                _integer(document['disposingNativeThreadId'], 1), 'An embedded native document was not safely disposed')
        if handoff is not None:
            ready = handoff['ready']
            expected = dict(readySha256=handoff['readySha256'], ackSha256=handoff['ackSha256'],
                pdfSha256=ready['pdfSha256'], pdfStamp=ready['pdfStamp'],
                pdfPageCount=ready['pdfPageCount'], nonce=ready['nonce'])
            _closed(proof.get('pdfHandoff'), set(expected), 'PDF handoff proof')
            _require(_same(proof['pdfHandoff'], expected), 'The child did not verify the exact parent PDF acknowledgement')
            self._verify_pdf()
        else:
            _require('pdfHandoff' not in proof, 'Unexpected PDF handoff proof')
        if manifest['phase'] == 'inspect':
            _require(proof.get('workerExportRestored') is True, 'The inspect exporter was not restored')
        callback = phase_root / 'embedded-callback-proof.json'
        if callback.exists():
            value = _json_bytes(_shared_bytes(callback))
            _closed(value, {'schema', 'jobToken', 'phaseToken', 'stage', 'postCount', 'invokeCount',
                'ready', 'fatal', 'terminateRequested', 'terminateReturned'}, 'callback evidence')
            _require(value['schema'] == 'piv.embedded-office-callback/1' and value['jobToken'] == self._job_token and
                value['phaseToken'] == manifest['phaseToken'] and value['fatal'] is False and value['ready'] is True,
                'The callback evidence contradicts final termination')
        result = response['result']
        phase = manifest['phase']
        if phase == 'plan':
            _closed(result, {'status'} if unsupported else {'status', 'planEnvelope'}, 'plan result')
            _require(result['status'] == ('unsupportedBeforeLoad' if unsupported else 'planned'), 'Unexpected embedded plan status')
        elif phase == 'render':
            _closed(result, {'status', 'candidateSha256', 'pdfSha256', 'pdfPageCount', 'pdfStamp'}, 'render result')
            _require(handoff is not None and result['status'] == 'rendered' and
                result['candidateSha256'] == self._candidate_hash and
                all(_same(result[key], handoff['ready'][key]) for key in ('pdfSha256', 'pdfPageCount', 'pdfStamp')),
                'The rendered result differs from the exact leased PDF')
        else:
            _closed(result, {'status', 'snapshot'} if phase == 'observe' else {'snapshot', 'engineVersion'}, phase + ' result')
            if phase == 'observe':
                _require(result['status'] == 'observed', 'Unexpected embedded observer status')
            else:
                _require(result['engineVersion'] == 'LibreOffice26.8.2.2', 'Unexpected embedded engine version')
            snapshot = result['snapshot']
            expected_hash = self._candidate_hash if phase == 'observe' else self._source_hash
            _require(type(snapshot) is dict and snapshot.get('kind') == 'presentation' and
                snapshot.get('sourceSha256') == expected_hash and type(snapshot.get('slides')) is list,
                'The embedded snapshot differs from the exact source revision')
            if phase == 'inspect' and self._original_request.get('preview', False):
                _require(handoff is not None and snapshot.get('previewPdfPath') == str(self.directory / 'preview.pdf') and
                    type(snapshot.get('previewPageCount')) is int and snapshot['previewPageCount'] ==
                    handoff['ready']['pdfPageCount'] == len(snapshot['slides']), 'The inspected preview differs from its leased PDF')
            elif phase == 'inspect':
                _require(handoff is None and 'previewPdfPath' not in snapshot and 'previewPageCount' not in snapshot,
                    'An inspect without preview produced a PDF')
        return result

    def _phase(self, phase, *, owned=None, pdf_state=None):
        self._time()
        self._verify_pins()
        token = secrets.token_hex(16)
        _require(token not in {item['phaseToken'] for item in self._phases}, 'Repeated embedded phase token')
        root = bootstrap._phase_directory(self.directory, token)
        self._new_directory(root)
        profile = root / 'profile'
        self._new_directory(profile)
        self._profiles.append((profile, self._owned[profile]))
        for path in (profile / 'user', profile / 'user/Scripts', profile / 'user/Scripts/python'):
            self._new_directory(path)
        script = profile / 'user/Scripts/python/office_embedded_bootstrap.py'
        self._copy(self._helpers / script.name, script, self._helper_hashes[script.name])
        request_hash = self._write(root / 'request.json', self._request_bytes)
        self._pin(root / 'request.json', request_hash)
        manifest = dict(schema='piv.embedded-office/1', jobToken=self._job_token, phaseToken=token, phase=phase,
            jobRoot=str(self.directory), helpers='helpers', runtime=str(self.runtime), source='source.pptx',
            candidate='edited.pptx', pdf='preview.pdf', plan='source-plan', sourceSha256=self._source_hash,
            candidateSha256=self._candidate_hash if phase in ('render', 'observe') else None,
            requestSha256=self._request_hash, parentPid=os.getpid(), bootstrapSha256=self._helper_hashes[script.name],
            helperSha256=dict(self._helper_hashes), runtimeSha256=dict(self._runtime_hashes),
            planEnvelope=self._envelope if phase in ('render', 'observe') else None,
            planPhaseToken=self._plan_token if phase in ('render', 'observe') else None, **_PHASE_FILES)
        owner_marker = {key: manifest[key] for key in ('schema', 'jobToken', 'phaseToken', 'jobRoot', 'parentPid')}
        for filename, value in (('owner.json', owner_marker), ('manifest.json', manifest)):
            value_hash = self._write_json(root / filename, value)
            self._pin(root / filename, value_hash)
        self._phases.append(manifest)
        evidence = dict(schema='piv.embedded-parent-proof/1', jobToken=self._job_token,
            phaseToken=token, phase=phase, capture=None, wait=None, cleanup=None)
        owner, handoff, result, primary = None, None, None, None
        try:
            self._time()
            arguments = ['--headless', '--nologo', '--nodefault', '--norestore',
                '-env:UserInstallation=' + profile.as_uri(), '--pidfile=' + str(root / 'office.pid'), _SCRIPT_URL]
            factory = OwnedOfficeProcess if self._process_factory is None else self._process_factory
            owner = factory(self.runtime / 'program/soffice.com', arguments, self.runtime / 'program')
            owner._piv_monotonic, owner._piv_sleep = self._clock, self._sleep
            expects_pdf = phase == 'render' or phase == 'inspect' and self._original_request.get('preview', False)
            while True:
                self._time()
                progress_path = root / 'embedded-progress.json'
                if progress_path.exists():
                    try:
                        progress_raw = _shared_bytes(progress_path)
                    except OSError as error:
                        if (not isinstance(error, FileNotFoundError) and
                                getattr(error, 'winerror', None) not in (32, 33)):
                            raise
                        # A progress replacement can briefly be unavailable. Poll the same phase.
                        self._sleep(.025)
                        continue
                    progress = _json_bytes(progress_raw)
                    self._identity(progress, root, manifest)
                    if evidence['capture'] is None:
                        _require(not (root / 'embedded-complete').exists(),
                            'Completion arrived before an actual live process handle was captured')
                        evidence['capture'] = self._capture(owner, progress, root, manifest)
                    else:
                        _require(progress['pid'] == evidence['capture']['pid'], 'The actual embedded PID changed within a phase')
                ready_path = root / 'pdf-ready.json'
                if ready_path.exists() and handoff is None:
                    _require(expects_pdf and evidence['capture'] is not None, 'Unexpected PDF ready before actual process capture')
                    handoff = self._handoff(root, manifest, owned, pdf_state)
                response_path = root / 'response.json'
                if response_path.exists():
                    self._response(root)
                if (root / 'embedded-complete').exists():
                    _require(evidence['capture'] is not None, 'No actual process was held before completion')
                    break
                if owner.exit_code() is not None:
                    if _active(owner) > 0:
                        self._sleep(.025)
                        continue
                    _require(evidence['capture'] is not None, 'The Office loader exited before actual process capture')
                    evidence['wait'] = _wait_owned(owner, self._deadline)
                    _require((root / 'embedded-complete').exists(), 'Office exited without the final termination notification')
                    break
                self._sleep(.025)
            if evidence['wait'] is None:
                evidence['wait'] = _wait_owned(owner, self._deadline)
            _closed(evidence['wait'], _WAIT_KEYS, 'natural exit')
            _require(all(type(value) is int and value == 0 for value in evidence['wait'].values()),
                'The actual process, loader, and owned Job did not all exit naturally with zero status')
            response, response_hash = self._response(root)
            result = self._final(root, manifest, evidence['capture'], handoff, response, response_hash)
            self._verify_pins()
        except BaseException as error:
            primary, self._failed = error, True
        finally:
            if owner is not None:
                try:
                    evidence['cleanup'] = _close_owned(owner, self._deadline)
                    _closed(evidence['cleanup'], _CLEANUP_KEYS, 'OS cleanup')
                    cleanup = evidence['cleanup']
                    _require(type(cleanup['activeProcesses']) is int and cleanup['activeProcesses'] == 0 and
                        all(cleanup[key] is True for key in ('actualHandleClosed', 'loaderHandleClosed', 'jobHandleClosed')) and
                        type(cleanup['forced']) is bool and type(cleanup['errors']) is list and
                        all(type(value) is str for value in cleanup['errors']), 'Invalid owned process cleanup proof')
                    _require(not cleanup['errors'], 'Owned Office cleanup: ' + '; '.join(cleanup['errors']))
                    if primary is None:
                        _require(cleanup['forced'] is False, 'A forced owned Job termination cannot authorize success')
                except BaseException as error:
                    self._failed = True
                    if primary is None:
                        primary = error
                    else:
                        primary.add_note('Cleaning owned embedded process: ' + str(error))
            try:
                self._write_json(root / 'parent-proof.json', evidence, final=True)
            except BaseException as error:
                self._failed = True
                if primary is None:
                    primary = error
                else:
                    primary.add_note('Publishing parent process cleanup proof: ' + str(error))
        if primary is not None:
            self._release(primary)
            raise primary
        return result

    def plan(self, runtime, source, source_hash, operations, input_job, *, allow_empty_fallback=False):
        _require(Path(input_job).parent == self.directory, 'The source plan work directory differs from the outer job')
        self._initialize(runtime, source, source_hash)
        _require(self._plan is None and self._plan_token is None and
            _same(operations, self._original_request.get('operations')), 'The native plan differs from the frozen source batch')
        result = self._phase('plan')
        if result['status'] == 'unsupportedBeforeLoad':
            _require(allow_empty_fallback is True and operations == [], 'Unsupported plan outside the existing empty fallback')
            return None
        self._envelope, self._plan_token = result['planEnvelope'], self._phases[-1]['phaseToken']
        if bootstrap._is_structure_request(self._original_request):
            from office_presentation_structure_wire import read_structure_plan
            read = read_structure_plan
        else:
            read = wire.read_source_plan
        self._plan = read(self.directory / 'source-plan', self._envelope,
            expected_job_token=self._job_token, expected_phase_token=self._plan_token,
            expected_request_sha256=self._request_hash, expected_source_sha256=self._source_hash)
        self._pin(self.directory / 'source-plan/plan.json', self._envelope['payload']['sha256'])
        for index, data in enumerate(self._plan['parts'].values()):
            self._pin(self.directory / ('source-plan/parts/p%06d.bin' % index), hashlib.sha256(data).hexdigest())
        self._verify_pins()
        return self._plan

    def plan_structure(self, runtime, source, source_hash, operations, input_job):
        _require(bootstrap._is_structure_request(self._original_request),
            'A structure planner requires the frozen structure request family')
        return self.plan(runtime, source, source_hash, operations, input_job)

    def render_structure(self, runtime, edited, candidate_hash, pdf, clean_job, plan, owned, pdf_state):
        _require(bootstrap._is_structure_request(self._original_request) and plan == self._plan,
            'The structure renderer differs from its complete frozen plan')
        return self.render(runtime, edited, candidate_hash, pdf, clean_job, plan['owner_ledger'], owned, pdf_state)

    def observe_structure(self, runtime, edited, candidate_hash, observer_job, plan):
        _require(bootstrap._is_structure_request(self._original_request) and plan == self._plan,
            'The structure observer differs from its complete frozen plan')
        return self.observe(runtime, edited, candidate_hash, observer_job, plan['expected_native'], plan['expected_core'])

    def render(self, runtime, edited, candidate_hash, pdf, clean_job, owner_ledger, owned, pdf_state):
        self._time()
        _require(self._plan is not None and self._candidate_hash is None and Path(runtime) == self.runtime and
            Path(edited) == self.directory / 'edited.pptx' and Path(pdf) == self.directory / 'preview.pdf' and
            Path(clean_job) == self.directory / 'clean-native' and owner_ledger == self._plan['owner_ledger'],
            'The clean render differs from its exact original plan and outer output paths')
        _hex(candidate_hash, 64, 'parent candidate hash')
        self._candidate_hash = candidate_hash
        self._pin(Path(edited), candidate_hash)
        self._phase('render', owned=owned, pdf_state=pdf_state)

    def observe(self, runtime, edited, candidate_hash, observer_job, expected_native, expected_core):
        self._time()
        _require(Path(runtime) == self.runtime and Path(edited) == self.directory / 'edited.pptx' and
            candidate_hash == self._candidate_hash and Path(observer_job) == self.directory / 'bound-observer' and
            expected_native == self._plan['expected_native'] and expected_core == self._plan['expected_core'] and
            self._pdf_state is not None and self._pdf_state.get('lease') is not None,
            'The bound observer differs from its exact plan or retained PDF lease')
        self._verify_pins()
        result = self._phase('observe')
        self._verify_pins()
        return result['snapshot']

    def inspect(self, runtime, source, source_hash, request, directory):
        _require(Path(directory) == self.directory and _same(request, self._original_request),
            'The inspect request differs from its frozen outer request')
        self._initialize(runtime, source, source_hash)
        owned, pdf_state = {}, {'lease': None}
        try:
            result = self._phase('inspect', owned=owned, pdf_state=pdf_state)
            self._verify_pins()
            if pdf_state['lease'] is not None:
                pdf_state['lease'].close()
                pdf_state['lease'] = None
            return result
        except BaseException as error:
            self._failed = True
            self._release(error)
            for path, identity in owned.items():
                try:
                    if os.path.lexists(path):
                        _require(_stamp(_entry(path))[:2] == identity, 'Preserve a foreign failed inspect PDF replacement')
                        path.unlink()
                except Exception as cleanup_error:
                    error.add_note('Removing owned failed inspect PDF: ' + str(cleanup_error))
            raise

    def _release(self, primary=None):
        errors = []
        if self._pdf_state is not None and self._pdf_state.get('lease') is not None:
            try:
                self._pdf_state['lease'].close()
                self._pdf_state['lease'] = None
            except Exception as error:
                errors.append('Closing parent PDF lease: ' + str(error))
        for lease, _, _ in reversed(list(self._pins.values())):
            try:
                lease.close()
            except Exception as error:
                errors.append('Closing parent input lease: ' + str(error))
        self._pins.clear()
        for lease in reversed(list(self._directories.values())):
            try:
                lease.close()
            except Exception as error:
                errors.append('Closing parent directory lease: ' + str(error))
        self._directories.clear()
        if errors:
            if primary is not None:
                for error in errors:
                    primary.add_note(error)
            else:
                raise RuntimeError('; '.join(errors))

    def _remove_tree(self, path, identity):
        _require(_stamp(_entry(path, True))[:2] == identity, 'Preserve a foreign owned-directory replacement')
        for root, directories, files in os.walk(path, followlinks=False):
            _entry(Path(root), True)
            for name in directories:
                child = Path(root) / name
                information = _entry(child, True)
                if child in self._owned:
                    _require(_stamp(information)[:2] == self._owned[child], 'Preserve a foreign profile directory replacement')
            for name in files:
                child = Path(root) / name
                information = _entry(child)
                if child in self._owned:
                    _require(_stamp(information)[:2] == self._owned[child], 'Preserve a foreign owned-file replacement')
                elif path == self._helpers:
                    raise ValueError('Preserve an unowned helper file')
        _require(_stamp(_entry(path, True))[:2] == identity, 'The owned directory changed before cleanup')
        shutil.rmtree(path)

    def close(self):
        if self._closed:
            return
        self._closed = True
        self._release()
        if self._deadline is None or self._failed:
            return
        for profile, identity in self._profiles:
            if os.path.lexists(profile):
                self._remove_tree(profile, identity)
        helpers = getattr(self, '_helpers', None)
        if helpers is not None and os.path.lexists(helpers):
            self._remove_tree(helpers, self._owned[helpers])
