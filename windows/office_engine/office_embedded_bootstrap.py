"""Fixed trusted PythonScriptProvider entry for one local Office phase.

The manifest is an owned, data-only rendezvous. It cannot select Python code,
UNO services, or a transport. Native references remain inside this process.
"""
from contextlib import ExitStack
import ctypes
from ctypes import wintypes
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import stat
import sys
import threading
import time
from types import SimpleNamespace
from urllib.parse import urlsplit, unquote
from urllib.request import url2pathname

sys.dont_write_bytecode = True

_HELPERS = frozenset({
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
_PHASE_FILES = dict(profile='profile', request='request.json', response='response.json',
    proof='embedded-proof.json', progress='embedded-progress.json', complete='embedded-complete',
    callbackProof='embedded-callback-proof.json', pdfReady='pdf-ready.json', pdfAck='pdf-ack.json')
_MANIFEST_KEYS = set(_PHASE_FILES) | {'schema', 'jobToken', 'phaseToken', 'phase', 'jobRoot',
    'helpers', 'runtime', 'source', 'candidate', 'pdf', 'plan', 'sourceSha256',
    'candidateSha256', 'requestSha256', 'parentPid', 'bootstrapSha256', 'helperSha256',
    'runtimeSha256', 'planEnvelope', 'planPhaseToken'}
_PHASE_WORK = dict(plan='source-binding', render='clean-native', observe='bound-observer', inspect='inspect-work')
_active_jobs = []
_ACK_SECONDS = 30.0


def _require(condition, message):
    if not condition:
        raise ValueError(message)


def _hex(value, length, label):
    _require(type(value) is str and re.fullmatch('[0-9a-f]{%d}' % length, value) is not None,
        'Invalid embedded ' + label)
    return value


def _phase_directory(root, token):
    # LibreOffice adds deep registry paths below this directory. Keep the full
    # token in the manifest and owner record, with a shorter directory name.
    return root / 'phases' / token[:12]


def _closed(value, keys, label):
    _require(type(value) is dict and set(value) == keys and all(type(key) is str for key in value),
        'Invalid embedded ' + label + ' schema')


def _object(pairs):
    result = {}
    for key, value in pairs:
        _require(key not in result, 'Duplicate embedded JSON key')
        result[key] = value
    return result


def _constant(value):
    raise ValueError('Nonfinite embedded JSON number')


def _json(path):
    return json.loads(Path(path).read_text(encoding='utf-8'), object_pairs_hook=_object, parse_constant=_constant)


def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def _replace_existing(pending, destination):
    _entry(pending, False)
    _entry(destination, False)
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.ReplaceFileW.argtypes = [wintypes.LPCWSTR, wintypes.LPCWSTR, wintypes.LPCWSTR,
        wintypes.DWORD, ctypes.c_void_p, ctypes.c_void_p]
    kernel.ReplaceFileW.restype = wintypes.BOOL
    if not kernel.ReplaceFileW(str(destination), str(pending), None, 0, None, None):
        raise ctypes.WinError(ctypes.get_last_error())


def write_json(filename, value):
    filename = Path(filename)
    pending = filename.with_name(filename.name + '.writing')
    identity = None
    try:
        with pending.open('x', encoding='utf-8', newline='\n') as stream:
            identity = _stamp(os.fstat(stream.fileno()))[:2]
            json.dump(value, stream, ensure_ascii=False, allow_nan=False, separators=(',', ':'))
            stream.write('\n')
            stream.flush()
            os.fsync(stream.fileno())
        if os.path.lexists(filename):
            _replace_existing(pending, filename)
        else:
            os.replace(pending, filename)
    except BaseException as error:
        if identity is not None:
            try:
                _require(_stamp(_entry(pending, False))[:2] == identity,
                    'Preserve a foreign embedded pending replacement')
                pending.unlink()
            except FileNotFoundError:
                pass
            except Exception as cleanup_error:
                error.add_note('Removing owned embedded pending file: ' + str(cleanup_error))
        raise


def current_image_path():
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.GetModuleFileNameW.argtypes = [wintypes.HMODULE, wintypes.LPWSTR, wintypes.DWORD]
    kernel.GetModuleFileNameW.restype = wintypes.DWORD
    image = ctypes.create_unicode_buffer(32768)
    length = kernel.GetModuleFileNameW(None, image, len(image))
    if length == 0 or length >= len(image):
        raise ctypes.WinError(ctypes.get_last_error() or 122)
    return Path(image.value).resolve(strict=True)


def _stamp(information):
    return information.st_dev, information.st_ino, information.st_size, information.st_mtime_ns


def _entry(path, directory):
    information = Path(path).lstat()
    _require(not stat.S_ISLNK(information.st_mode) and
        not getattr(information, 'st_file_attributes', 0) & 0x400,
        'Embedded paths must not contain links or reparse points')
    _require(stat.S_ISDIR(information.st_mode) if directory else stat.S_ISREG(information.st_mode),
        'Invalid embedded filesystem entry type')
    if not directory:
        _require(information.st_nlink == 1, 'Embedded files must not have external hard links')
    return information


class _TrustedLease:
    """Pin trust inputs before importing any helper, including the wire helper."""
    def __init__(self, path, directory):
        self.path, self.directory = Path(path), directory
        self.before, self.handle = _entry(path, directory), None
        _require(os.name == 'nt', 'The embedded Office bootstrap requires Windows file leases')

        class Information(ctypes.Structure):
            _fields_ = [('attributes', wintypes.DWORD), ('created', wintypes.FILETIME),
                ('accessed', wintypes.FILETIME), ('written', wintypes.FILETIME),
                ('volume', wintypes.DWORD), ('sizeHigh', wintypes.DWORD),
                ('sizeLow', wintypes.DWORD), ('links', wintypes.DWORD),
                ('indexHigh', wintypes.DWORD), ('indexLow', wintypes.DWORD)]

        self.kernel = ctypes.WinDLL('kernel32', use_last_error=True)
        self.kernel.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
            ctypes.c_void_p, wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE]
        self.kernel.CreateFileW.restype = wintypes.HANDLE
        self.kernel.CloseHandle.argtypes = [wintypes.HANDLE]
        self.kernel.CloseHandle.restype = wintypes.BOOL
        self.kernel.GetFileInformationByHandle.argtypes = [wintypes.HANDLE, ctypes.POINTER(Information)]
        self.kernel.GetFileInformationByHandle.restype = wintypes.BOOL
        flags = 0x00200000 | (0x02000000 if directory else 0x80)
        share = 0x00000003 if directory else 0x00000001
        self.handle = self.kernel.CreateFileW(str(path), 0x80000000, share, None, 3, flags, None)
        if self.handle in (None, ctypes.c_void_p(-1).value):
            self.handle = None
            raise ctypes.WinError(ctypes.get_last_error())
        try:
            information = Information()
            if not self.kernel.GetFileInformationByHandle(self.handle, ctypes.byref(information)):
                raise ctypes.WinError(ctypes.get_last_error())
            _require(not information.attributes & 0x400 and
                bool(information.attributes & 0x10) == directory and (directory or information.links == 1),
                'The embedded trust handle differs from its path')
            self.verify()
        except BaseException:
            self.close()
            raise

    def verify(self):
        before, after = _stamp(self.before), _stamp(_entry(self.path, self.directory))
        _require(before[:2] == after[:2] if self.directory else before == after,
            'An embedded trust input identity changed')

    def close(self):
        if self.handle is not None:
            if not self.kernel.CloseHandle(self.handle):
                raise ctypes.WinError(ctypes.get_last_error())
            self.handle = None


def _hold(path, directory, job):
    path = Path(path)
    for parent in (*reversed(path.parents), *((path,) if directory else ())):
        if parent not in job['heldDirectories']:
            lease = _TrustedLease(parent, True)
            job['cleanup'].callback(lease.close)
            job['leases'].append(lease)
            job['heldDirectories'].add(parent)
    if not directory:
        lease = _TrustedLease(path, False)
        job['cleanup'].callback(lease.close)
        job['leases'].append(lease)
    return path


def _pinned_file(path, expected_hash, job):
    path = _hold(path, False, job)
    _require(digest(path) == expected_hash, 'Pinned embedded input bytes changed: ' + path.name)
    job['pins'][path] = expected_hash
    return path


def _absolute(value, label):
    _require(type(value) is str and Path(value).is_absolute(), 'Invalid absolute embedded ' + label)
    path = Path(os.path.abspath(value))
    _require(path == Path(value), 'Noncanonical embedded ' + label)
    return path


def _runtime_name(value):
    _require(type(value) is str and value.startswith('program/') and '\\' not in value and
        ':' not in value and all(part not in ('', '.', '..') for part in value.split('/')),
        'Invalid embedded runtime pin path')


def _origin(module, helpers, filename):
    _require(Path(module.__file__).resolve(strict=True) == helpers / filename,
        'Unexpected embedded helper import origin: ' + filename)


def _validate_request(request, manifest, source):
    _require(type(request) is dict and all(type(key) is str for key in request), 'Invalid embedded request')
    if manifest['phase'] == 'inspect':
        required = {'mode', 'sourcePath'}
        allowed = required | {'preview', 'expectedSourceSha256'}
        _require(required <= set(request) <= allowed and request['mode'] == 'inspect' and
            type(request.get('preview', False)) is bool and
            request.get('expectedSourceSha256') in (None, manifest['sourceSha256']),
            'Invalid fixed embedded inspect request')
    else:
        empty_preview = (type(request.get('operations')) is list and request['operations'] == [] and
            request.get('includeDraftSnapshot', False) is True)
        required = {'mode', 'sourcePath', 'sessionId', 'operations'}
        if not empty_preview:
            required.add('expectedSourceSha256')
        allowed = required | {'expectedSourceSha256', 'includeDraftSnapshot', 'preview', 'imageAssets'}
        source_hash_matches = (request.get('expectedSourceSha256') in (None, manifest['sourceSha256'])
            if empty_preview else request.get('expectedSourceSha256') == manifest['sourceSha256'])
        _require(required <= set(request) <= allowed and request['mode'] == 'apply' and
            type(request['sessionId']) is str and bool(request['sessionId']) and
            type(request['operations']) is list and type(request.get('includeDraftSnapshot', False)) is bool and
            source_hash_matches and
            request.get('preview', False) is False and
            ('imageAssets' not in request or type(request['imageAssets']) is list and request['imageAssets'] == []),
            'Invalid fixed embedded source request')
    _require(type(request['sourcePath']) is str and Path(request['sourcePath']) == source,
        'The embedded request differs from its owned source')


def _is_structure_request(request):
    operations = request.get('operations')
    structure = type(operations) is list and any(type(operation) is dict and
        operation.get('op') == 'presentationSourceTableAdd' for operation in operations)
    if structure:
        _require(all(type(operation) is dict and operation.get('op') == 'presentationSourceTableAdd'
            for operation in operations), 'Mixed embedded source plan families are unsupported')
    return structure


def _validate_plan_envelope(manifest, *, expected_schema='piv.source-plan/1'):
    _require(type(expected_schema) is str and expected_schema in ('piv.source-plan/1', 'piv.structure-plan/1'),
        'Unsupported fixed plan family')
    envelope = manifest['planEnvelope']
    _closed(envelope, {'schema', 'jobToken', 'phaseToken', 'requestSha256', 'sourceSha256', 'payload'},
        'source-plan envelope')
    _require(envelope['schema'] == expected_schema and
        envelope['jobToken'] == manifest['jobToken'] and envelope['phaseToken'] == manifest['planPhaseToken'] and
        envelope['requestSha256'] == manifest['requestSha256'] and
        envelope['sourceSha256'] == manifest['sourceSha256'], 'The source-plan envelope provenance differs')
    payload = envelope['payload']
    _closed(payload, {'fileName', 'byteLength', 'sha256', 'nodeCount'}, 'source-plan payload')
    _require(payload['fileName'] == 'plan.json' and type(payload['byteLength']) is int and
        payload['byteLength'] >= 0 and type(payload['nodeCount']) is int and payload['nodeCount'] >= 1,
        'Invalid source-plan payload integrity metadata')
    _hex(payload['sha256'], 64, 'source-plan payload hash')
    if expected_schema == 'piv.structure-plan/1':
        _require(0 < payload['byteLength'] <= 16 * 1024 * 1024 and payload['nodeCount'] <= 524288,
            'The structure-plan payload exceeds its fixed byte or node budget')


def _load_job():
    parsed = urlsplit(__file__)
    _require(parsed.scheme == 'file' and not parsed.netloc and not parsed.query and not parsed.fragment,
        'The trusted embedded script must have its own file URI')
    script = Path(os.path.abspath(url2pathname(unquote(parsed.path))))
    _require(script.name == 'office_embedded_bootstrap.py', 'Unexpected embedded script name')
    phase_root, root = script.parents[4], script.parents[6]
    job = dict(root=root, phaseRoot=phase_root, script=script, cleanup=ExitStack(),
        leases=[], heldDirectories=set(), pins={})
    try:
        _hold(script, False, job)
        _hold(phase_root / 'manifest.json', False, job)
        manifest = _json(phase_root / 'manifest.json')
        _closed(manifest, _MANIFEST_KEYS, 'manifest')
        _require(manifest['schema'] == 'piv.embedded-office/1' and
            type(manifest['phase']) is str and manifest['phase'] in _PHASE_WORK, 'Unsupported embedded manifest version or phase')
        _hex(manifest['jobToken'], 32, 'job token')
        _hex(manifest['phaseToken'], 32, 'phase token')
        _hex(manifest['sourceSha256'], 64, 'source hash')
        _hex(manifest['requestSha256'], 64, 'request hash')
        _hex(manifest['bootstrapSha256'], 64, 'bootstrap hash')
        _require(type(manifest['parentPid']) is int and manifest['parentPid'] > 0,
            'Invalid embedded parent process identity')
        _require(_absolute(manifest['jobRoot'], 'job root') == root and
            phase_root == _phase_directory(root, manifest['phaseToken']) and
            script == phase_root / 'profile/user/Scripts/python/office_embedded_bootstrap.py',
            'Unexpected owned embedded root or profile')
        for name, filename in _PHASE_FILES.items():
            _require(type(manifest[name]) is str and manifest[name] == filename,
                'Unexpected embedded phase artifact path: ' + name)
        for name, filename in dict(helpers='helpers', source='source.pptx', candidate='edited.pptx',
                pdf='preview.pdf', plan='source-plan').items():
            _require(type(manifest[name]) is str and manifest[name] == filename,
                'Unexpected embedded job artifact path: ' + name)
        _hold(phase_root / 'owner.json', False, job)
        owner = _json(phase_root / 'owner.json')
        expected_owner = {key: manifest[key] for key in ('schema', 'jobToken', 'phaseToken', 'jobRoot', 'parentPid')}
        _closed(owner, set(expected_owner), 'owner')
        _require(all(type(owner[key]) is type(value) and owner[key] == value
            for key, value in expected_owner.items()), 'Embedded owner marker differs')
        job.update(manifest=manifest, source=root / 'source.pptx', candidate=root / 'edited.pptx',
            pdf=root / 'preview.pdf', helpers=root / 'helpers', runtime=_absolute(manifest['runtime'], 'runtime'),
            work=phase_root / _PHASE_WORK[manifest['phase']])
        _pinned_file(script, manifest['bootstrapSha256'], job)
        _closed(manifest['helperSha256'], _HELPERS, 'helper pins')
        _require(manifest['helperSha256']['office_embedded_bootstrap.py'] == manifest['bootstrapSha256'],
            'The helper bootstrap and fixed entry bytes differ')
        for name, expected in manifest['helperSha256'].items():
            _pinned_file(job['helpers'] / name, _hex(expected, 64, 'helper hash'), job)
        _require(type(manifest['runtimeSha256']) is dict and len(manifest['runtimeSha256']) == 18,
            'Incomplete embedded runtime pins')
        for name, expected in manifest['runtimeSha256'].items():
            _runtime_name(name)
            _pinned_file(job['runtime'] / name, _hex(expected, 64, 'runtime hash'), job)
        _pinned_file(job['source'], manifest['sourceSha256'], job)
        _pinned_file(phase_root / 'request.json', manifest['requestSha256'], job)
        request = _json(phase_root / 'request.json')
        _validate_request(request, manifest, job['source'])
        job['request'] = request
        job['structure'] = _is_structure_request(request)
        if manifest['phase'] in ('plan', 'inspect'):
            _require(manifest['candidateSha256'] is None and manifest['planEnvelope'] is None and
                manifest['planPhaseToken'] is None, 'Unexpected later-phase inputs')
        else:
            _hex(manifest['candidateSha256'], 64, 'candidate hash')
            _hex(manifest['planPhaseToken'], 32, 'plan phase token')
            _require(manifest['planPhaseToken'] != manifest['phaseToken'] and
                type(manifest['planEnvelope']) is dict, 'Missing prior source-plan provenance')
            _validate_plan_envelope(manifest,
                expected_schema='piv.structure-plan/1' if job['structure'] else 'piv.source-plan/1')
            _pinned_file(job['candidate'], manifest['candidateSha256'], job)
        for name in ('response', 'proof', 'progress', 'complete', 'callbackProof', 'pdfReady', 'pdfAck'):
            _require(not os.path.lexists(phase_root / _PHASE_FILES[name]),
                'Preserve an existing embedded phase output: ' + name)
        _require(not os.path.lexists(job['work']), 'Preserve an existing embedded phase work directory')
        # The prepare helper is already pinned; its one definition owns runtime membership.
        sys.path.insert(0, str(job['helpers']))
        import prepare_runtime
        _origin(prepare_runtime, job['helpers'], 'prepare_runtime.py')
        _require(set(manifest['runtimeSha256']) == set(prepare_runtime.CRITICAL_FILES),
            'Embedded runtime pin membership differs')
        import office_worker
        _origin(office_worker, job['helpers'], 'office_worker.py')
        import office_presentation_source_edit
        import office_presentation_stage_wire
        import office_presentation_binding
        import office_presentation_duplicate
        import office_presentation_source
        import office_presentation_structure
        import office_presentation_structure_edit
        import office_presentation_structure_wire
        modules = (office_worker, office_presentation_source_edit, office_presentation_stage_wire,
            office_presentation_binding, office_presentation_duplicate, office_presentation_source, office_presentation_structure,
            office_presentation_structure_edit, office_presentation_structure_wire)
        for module in modules:
            _origin(module, job['helpers'], module.__name__ + '.py')
        job.update(worker=office_worker, sourceEdit=office_presentation_source_edit,
            wire=office_presentation_stage_wire, binding=office_presentation_binding,
            sourceReader=office_presentation_source, structureEdit=office_presentation_structure_edit,
            structureWire=office_presentation_structure_wire)
        if manifest['phase'] != 'inspect':
            if request['operations'] == []:
                _require(request.get('includeDraftSnapshot', False), 'An empty source phase requires the existing draft-preview route')
            else:
                validator = (office_presentation_structure_edit.validate_batch if job['structure'] else
                    office_presentation_source_edit.validate_batch)
                validator(request['operations'], manifest['sourceSha256'])
        if manifest['phase'] in ('render', 'observe'):
            job['planData'] = _read_plan(job)
            _verify_candidate(job, job['planData'])
        image = current_image_path()
        _require(image == job['runtime'] / 'program/soffice.bin' and
            digest(image) == manifest['runtimeSha256']['program/soffice.bin'],
            'The embedded Windows process image differs from the pinned runtime')
        job['image'] = image
        _verify_inputs(job)
        return job
    except BaseException as error:
        try:
            job['cleanup'].close()
        except Exception as cleanup_error:
            error.add_note('Closing embedded trust leases: ' + str(cleanup_error))
        raise


def _verify_inputs(job):
    for lease in job['leases']:
        lease.verify()
    for path, expected in job['pins'].items():
        _require(digest(path) == expected, 'An embedded input changed before completion: ' + path.name)


def _initialize_uno(runtime, worker):
    worker.initialize(runtime)
    import unohelper
    from com.sun.star.document import XEventListener
    from com.sun.star.frame import XTerminateListener, TerminationVetoException
    from com.sun.star.awt import XCallback

    return SimpleNamespace(Base=unohelper.Base, XEventListener=XEventListener,
        XTerminateListener=XTerminateListener, TerminationVetoException=TerminationVetoException,
        XCallback=XCallback)


def _error(worker, error):
    return dict(type=type(error).__name__[:128], message=str(error)[:4096],
        diagnostics=worker.error_diagnostics(error))


def _cleanup_error(state, label, error, primary=None):
    state['proof']['cleanupErrors'].append(dict(action=label, **_error(state['job']['worker'], error)))
    if primary is not None:
        primary.add_note(label + ': ' + str(error))


def _progress(state, stage):
    state['proof']['stage'] = stage
    write_json(state['job']['phaseRoot'] / _PHASE_FILES['progress'], state['proof'])


def _documents_complete(proof):
    if proof['unsupportedBeforeLoad']:
        return proof['documents'] == [] and proof['loadAttemptCount'] == 0
    return bool(proof['documents']) and all(record['disposed'] for record in proof['documents'])


def _native_boundary(job, state, native):
    proof, local_context, desktop = state['proof'], state['context'], state['desktop']
    worker = job['worker']

    class DisposalObserver(native.Base, native.XEventListener):
        def __init__(self, record):
            self.record = record

        def notifyEvent(self, event):
            pass

        def disposing(self, event):
            self.record['disposed'] = True
            self.record['disposingNativeThreadId'] = threading.get_native_id()

    class LocalFactory(worker.OfficeServer):
        def __enter__(self):
            proof['serverEnterCount'] += 1
            _require(proof['serverEnterCount'] == 1 and Path(self.runtime) == job['runtime'] and
                Path(self.directory) == job['work'], 'One fixed local context may serve only one phase')
            self.context, self.desktop, self.process = local_context, desktop, None
            _progress(state, 'local-server-entered')
            return self

        def load(self, filename, read_only=False):
            proof['loadAttemptCount'] += 1
            filename = Path(os.path.abspath(filename))
            _entry(filename, False)
            for parent in filename.parents:
                _entry(parent, True)
            allowed_copy = filename.is_relative_to(job['work'])
            allowed_candidate = job['manifest']['phase'] == 'render' and filename == job['candidate']
            _require(allowed_copy or allowed_candidate, 'Only the fixed candidate or phase-owned copies may load')
            record = dict(path=str(filename), readOnly=True, hidden=True, macroExecutionMode=0,
                updateDocMode=0, abortInteraction=True, disposed=False)
            proof['documents'].append(record)
            _progress(state, 'loading-owned-read-only-copy')
            document = super().load(filename, read_only=True)
            try:
                observer = DisposalObserver(record)
                state['refs'].append(observer)
                document.addEventListener(observer)
                record['observerRegistered'] = True
                return document
            except BaseException as error:
                try:
                    document.close(True)
                except Exception as cleanup_error:
                    _cleanup_error(state, 'Closing document after disposal observer failure', cleanup_error, error)
                raise

        def __exit__(self, error_type, error, traceback):
            proof['serverExitCount'] += 1
            proof['serverExitHadError'] = error is not None
            proof['allDocumentsDisposedAtServerExit'] = bool(proof['documents']) and all(
                record['disposed'] for record in proof['documents'])
            try:
                _progress(state, 'local-server-exited')
            except Exception as progress_error:
                if error is None:
                    raise
                _cleanup_error(state, 'Writing server exit progress', progress_error, error)
            if error is None and proof['documents']:
                _require(proof['allDocumentsDisposedAtServerExit'], 'A loaded document has no observed disposal')
            return False

    class TerminationObserver(native.Base, native.XTerminateListener):
        def queryTermination(self, event):
            proof['terminationQueryCount'] += 1
            if not state['ready']:
                proof['terminationVetoCount'] += 1
                raise native.TerminationVetoException('The owned response and proof are still in flight', None)

        def notifyTermination(self, event):
            if proof['terminationNotificationObserved']:
                return
            proof['terminationNotificationObserved'] = True
            try:
                _require(state['ready'] and not state['fatal'] and proof['readyForNaturalCliShutdown'] and
                    proof['shutdownReadyPublished'] and proof['responseFlushedBeforeCliReturn'] and
                    proof['serverEnterCount'] == 1 and proof['serverExitCount'] == 1 and
                    _documents_complete(proof) and proof['integrityConfirmed'] and not proof['cleanupErrors'],
                    'Termination did not verify a completed fixed phase')
                response_path = job['phaseRoot'] / _PHASE_FILES['response']
                _require(digest(response_path) == proof['responseSha256'] and _json(response_path).get('ok') is True,
                    'The original phase response changed before termination')
                _verify_inputs(job)
                job['cleanup'].close()
                proof['terminationNotificationVerified'] = True
                proof['terminationResponseSha256'] = proof['responseSha256']
                proof['stage'] = 'complete-after-termination-notification'
                write_json(job['phaseRoot'] / _PHASE_FILES['proof'], proof)
                with (job['phaseRoot'] / _PHASE_FILES['complete']).open('x', encoding='ascii', newline='\n') as stream:
                    stream.write(proof['responseSha256'] + '\n')
                    stream.flush()
                    os.fsync(stream.fileno())
            except Exception as error:
                state['fatal'] = True
                proof['terminationNotificationVerified'] = False
                proof['terminationNotificationError'] = _error(worker, error)
                proof['stage'] = 'termination-notification-failed'
                try:
                    job['cleanup'].close()
                except Exception as cleanup_error:
                    _cleanup_error(state, 'Closing termination trust leases', cleanup_error, error)
                write_json(job['phaseRoot'] / _PHASE_FILES['proof'], proof)

        def disposing(self, event):
            proof['desktopTerminationObserverDisposed'] = True

    def callback_evidence(stage, error=None):
        evidence = dict(schema='piv.embedded-office-callback/1', jobToken=proof['jobToken'],
            phaseToken=proof['phaseToken'], stage=stage, postCount=proof['shutdownCallbackPostCount'],
            invokeCount=proof['shutdownCallbackInvokeCount'], ready=state['ready'], fatal=state['fatal'],
            terminateRequested=proof['shutdownCallbackTerminateRequested'],
            terminateReturned=proof['shutdownCallbackTerminateReturned'])
        if error is not None:
            evidence['error'] = _error(worker, error)
        write_json(job['phaseRoot'] / _PHASE_FILES['callbackProof'], evidence)

    class ShutdownCallback(native.Base, native.XCallback):
        def notify(self, data):
            proof['shutdownCallbackInvokeCount'] += 1
            if proof['terminationNotificationObserved']:
                return
            try:
                _require(state['ready'] and not state['fatal'] and proof['shutdownCallbackInvokeCount'] == 1,
                    'The one-shot shutdown callback ran outside its ready boundary')
                proof['shutdownCallbackTerminateRequested'] = True
                returned = bool(desktop.terminate())
                proof['shutdownCallbackTerminateReturned'] = returned
                if not returned:
                    callback_evidence('single-terminate-request-returned-false')
            except Exception as error:
                state['fatal'] = True
                callback_evidence('single-terminate-request-raised', error)

    observer = TerminationObserver()
    state['refs'].append(observer)
    desktop.addTerminateListener(observer)
    proof['terminationObserverRegistered'] = True
    service = local_context.ServiceManager.createInstanceWithContext('com.sun.star.awt.AsyncCallback', local_context)
    _require(service is not None, 'The fixed AsyncCallback service is unavailable')
    callback = ShutdownCallback()
    state.update(factory=LocalFactory, callbackService=service, callback=callback, callbackEvidence=callback_evidence)
    state['refs'].extend((service, callback))


def _read_plan(job):
    manifest = job['manifest']
    read = job['structureWire'].read_structure_plan if job.get('structure', False) else job['wire'].read_source_plan
    return read(job['root'] / 'source-plan', manifest['planEnvelope'],
        expected_job_token=manifest['jobToken'], expected_phase_token=manifest['planPhaseToken'],
        expected_request_sha256=manifest['requestSha256'], expected_source_sha256=manifest['sourceSha256'])


def _verify_candidate(job, plan):
    current = job['sourceReader'].read_pptx_tables(job['candidate'])
    _require(current['parts'] == plan['parts'] and list(current['parts']) == plan['source_order'] and
        current['sourceSha256'] == job['manifest']['candidateSha256'],
        'The embedded candidate differs from the original request-derived source plan')


def _same_json(left, right):
    if type(left) is not type(right):
        return False
    if type(left) is dict:
        return set(left) == set(right) and all(_same_json(left[key], right[key]) for key in left)
    if type(left) is list:
        return len(left) == len(right) and all(_same_json(one, two) for one, two in zip(left, right))
    return left == right


def _handoff_pdf(job, state):
    manifest, pdf_state = job['manifest'], state['pdfState']
    _require(pdf_state['lease'] is not None and type(pdf_state['page_count']) is int and
        pdf_state['page_count'] > 0, 'The original renderer did not retain a verified PDF lease')
    job['binding']._verify_file(job['pdf'], pdf_state['stamp'], pdf_state['sha256'])
    _require(_documents_complete(state['proof']), 'PDF handoff requires an observed document close')
    ready = dict(schema='piv.pdf-handoff/1', jobToken=manifest['jobToken'], phaseToken=manifest['phaseToken'],
        phase=manifest['phase'], requestSha256=manifest['requestSha256'],
        candidateSha256=manifest['sourceSha256'] if manifest['phase'] == 'inspect' else manifest['candidateSha256'],
        pdf='preview.pdf', pdfSha256=pdf_state['sha256'], pdfPageCount=pdf_state['page_count'],
        pdfStamp=list(pdf_state['stamp']), nonce=secrets.token_hex(16))
    ready_path = job['phaseRoot'] / _PHASE_FILES['pdfReady']
    write_json(ready_path, ready)
    ready_hash = digest(ready_path)
    expected = {**ready, 'readySha256': ready_hash}
    deadline = time.monotonic() + _ACK_SECONDS
    ack_path = job['phaseRoot'] / _PHASE_FILES['pdfAck']
    while not ack_path.exists():
        _require(time.monotonic() < deadline, 'Timed out waiting for the exact owned PDF lease acknowledgement')
        time.sleep(.025)
    with ExitStack() as ack_cleanup:
        ack_lease = _TrustedLease(ack_path, False)
        ack_cleanup.callback(ack_lease.close)
        observed = _json(ack_path)
        _require(_same_json(observed, expected), 'The PDF lease acknowledgement differs from the exact ready record')
        ack_lease.verify()
        job['binding']._verify_file(job['pdf'], pdf_state['stamp'], pdf_state['sha256'])
        _require(digest(ready_path) == ready_hash, 'The PDF ready record changed before acknowledgement')
        state['proof']['pdfHandoff'] = dict(readySha256=ready_hash, ackSha256=digest(ack_path),
            pdfSha256=pdf_state['sha256'], pdfStamp=list(pdf_state['stamp']),
            pdfPageCount=pdf_state['page_count'], nonce=ready['nonce'])
    pdf_state['lease'].close()
    pdf_state['lease'] = None


def _inspect(job, state):
    worker, captured = job['worker'], []
    original_export = worker.export_pdf

    def export(document, destination, kind):
        destination = Path(destination)
        _require(job['request'].get('preview', False) and destination.parent == job['phaseRoot'] and
            re.fullmatch('preview-[0-9a-f]{32}\\.pdf', destination.name) is not None and
            kind == 'presentation' and not os.path.lexists(destination),
            'The original inspect renderer selected an unexpected owned PDF path')
        _require(not captured, 'Only one original inspect PDF may be exported')
        page_count = original_export(document, destination, kind)
        before = _stamp(_entry(destination, False))
        lease = job['binding']._WindowsReadLease(destination)
        state['originalPdfLease'] = lease
        pdf_hash = digest(destination)
        job['binding']._verify_file(destination, before, pdf_hash)
        state['owned'][destination] = before[:2]
        captured.append(dict(path=destination, stamp=before, sha256=pdf_hash, pageCount=page_count))
        return page_count

    worker.export_pdf = export
    try:
        result = worker.run_request(job['runtime'], job['request'], job['work'],
            native_stages=None, server_factory=state['factory'])
    finally:
        worker.export_pdf = original_export
        state['proof']['workerExportRestored'] = worker.export_pdf is original_export
    if not job['request'].get('preview', False):
        _require(not captured, 'A read-only inspect unexpectedly exported a PDF')
        return result
    _require(len(captured) == 1 and _documents_complete(state['proof']),
        'The original inspect did not export and close exactly one document')
    original = captured[0]
    snapshot = result['snapshot']
    _require(type(snapshot) is dict and type(snapshot.get('previewPdfPath')) is str and
        Path(snapshot['previewPdfPath']) == original['path'] and
        snapshot.get('sourceSha256') == job['manifest']['sourceSha256'] and
        snapshot.get('kind') == 'presentation' and type(snapshot.get('slides')) is list and
        type(snapshot.get('previewPageCount')) is int and
        type(original['pageCount']) is int and original['pageCount'] > 0 and
        snapshot['previewPageCount'] == original['pageCount'] == len(snapshot['slides']),
        'The inspect preview result differs from its original exported document')
    _require(not os.path.lexists(job['pdf']), 'Preserve an existing fixed inspect PDF')
    _require(original['stamp'][2] <= 128 * 1024 * 1024, 'The inspect PDF exceeds the existing output-file limit')
    job['binding']._verify_file(original['path'], original['stamp'], original['sha256'])
    with original['path'].open('rb') as source, job['pdf'].open('xb') as target:
        state['owned'][job['pdf']] = _stamp(os.fstat(target.fileno()))[:2]
        copied = 0
        while True:
            chunk = source.read(1024 * 1024)
            if not chunk:
                break
            copied += len(chunk)
            _require(copied <= 128 * 1024 * 1024, 'The inspect PDF exceeds the existing output-file limit')
            _require(target.write(chunk) == len(chunk), 'The fixed inspect PDF copy is incomplete')
        target.flush()
        os.fsync(target.fileno())
    pdf_state = state['pdfState']
    pdf_state['stamp'] = _stamp(_entry(job['pdf'], False))
    pdf_state['lease'] = job['binding']._WindowsReadLease(job['pdf'])
    pdf_state['sha256'] = digest(job['pdf'])
    pdf_state['page_count'] = original['pageCount']
    _require(pdf_state['sha256'] == original['sha256'] and copied == original['stamp'][2],
        'The fixed inspect PDF differs from the original exported bytes')
    job['binding']._verify_file(job['pdf'], pdf_state['stamp'], pdf_state['sha256'])
    job['binding']._verify_file(original['path'], original['stamp'], original['sha256'])
    _verify_inputs(job)
    state['originalPdfLease'].close()
    state['originalPdfLease'] = None
    _require(_stamp(_entry(original['path'], False))[:2] == original['stamp'][:2],
        'Preserve a foreign original inspect PDF replacement')
    original['path'].unlink()
    snapshot['previewPdfPath'] = str(job['pdf'])
    _handoff_pdf(job, state)
    return result


def _render(job, state, plan, common):
    original_export, captured, primary = job['worker'].export_pdf, None, None

    def export(document, destination, kind):
        nonlocal captured
        _require(Path(destination) == job['pdf'] and kind == 'presentation' and captured is None,
            'The fixed candidate renderer selected an unexpected PDF destination')
        page_count = original_export(document, destination, kind)
        before = _stamp(_entry(job['pdf'], False))
        state['exportPdfLease'] = job['binding']._WindowsReadLease(job['pdf'])
        captured = before[:2]
        state['owned'][job['pdf']] = captured
        job['binding']._verify_file(job['pdf'], before, digest(job['pdf']))
        return page_count

    try:
        render = (job['structureEdit'].render_source_structure_candidate if job.get('structure', False) else
            job['sourceEdit'].render_source_candidate)
        render(job['runtime'], job['candidate'],
            job['manifest']['candidateSha256'], job['pdf'], job['work'],
            plan if job.get('structure', False) else plan['owner_ledger'],
            state['owned'], state['pdfState'], export_pdf=export, **common,
            **({'export_owns_output': True} if job.get('structure', False) else {}))
    except BaseException as error:
        primary = error
        # Never adopt a new identity from the renderer's exceptional cleanup branch.
        if captured is None:
            state['owned'].pop(job['pdf'], None)
        else:
            state['owned'][job['pdf']] = captured
        raise
    finally:
        if state['exportPdfLease'] is not None:
            try:
                state['exportPdfLease'].close()
                state['exportPdfLease'] = None
            except Exception as error:
                if primary is None:
                    raise
                _cleanup_error(state, 'Closing export-time PDF read lease', error, primary)


def _dispatch(job, state):
    manifest, worker, source_edit = job['manifest'], job['worker'], job['sourceEdit']
    phase = manifest['phase']
    if phase == 'inspect':
        return _inspect(job, state)
    job['work'].mkdir()
    common = dict(server_factory=state['factory'], objects=worker.objects, snapshot=worker.snapshot)
    if phase == 'plan':
        operations = job['request']['operations']
        allow_empty = operations == [] and job['request'].get('includeDraftSnapshot', False)
        if job.get('structure', False):
            plan = job['structureEdit'].plan_source_structure_edit(job['runtime'], job['source'],
                manifest['sourceSha256'], operations, job['work'], **common)
        else:
            plan = source_edit.plan_source_text_edit(job['runtime'], job['source'], manifest['sourceSha256'],
                operations, job['work'], allow_empty_fallback=allow_empty, **common)
        if plan is None:
            proof = state['proof']
            _verify_inputs(job)
            _require(allow_empty and operations == [] and proof['serverEnterCount'] == 1 and
                proof['serverExitCount'] == 1 and proof['loadAttemptCount'] == 0 and proof['documents'] == [],
                'Only an entered unsupported empty plan may complete before loading')
            proof['unsupportedBeforeLoad'] = True
            proof['allDocumentsDisposedAtServerExit'] = True
            return dict(status='unsupportedBeforeLoad')
        write = job['structureWire'].write_structure_plan if job.get('structure', False) else job['wire'].write_source_plan
        envelope = write(job['root'] / 'source-plan', plan,
            job_token=manifest['jobToken'], phase_token=manifest['phaseToken'],
            request_sha256=manifest['requestSha256'], source_sha256=manifest['sourceSha256'])
        return dict(status='planned', planEnvelope=envelope)
    plan = job['planData']
    _verify_candidate(job, plan)
    if phase == 'render':
        _require(not os.path.lexists(job['pdf']), 'Preserve an existing PDF destination')
        _render(job, state, plan, common)
        _handoff_pdf(job, state)
        pdf_state = state['pdfState']
        return dict(status='rendered', candidateSha256=manifest['candidateSha256'],
            pdfSha256=pdf_state['sha256'], pdfPageCount=pdf_state['page_count'], pdfStamp=list(pdf_state['stamp']))
    if job.get('structure', False):
        final = job['structureEdit'].observe_source_structure_candidate(job['runtime'], job['candidate'],
            manifest['candidateSha256'], job['work'], plan, **common)
    else:
        final = source_edit.observe_source_candidate(job['runtime'], job['candidate'], manifest['candidateSha256'],
            job['work'], plan['expected_native'], plan['expected_core'], **common)
    return dict(status='observed', snapshot=final)


def _failed_outputs(state, primary):
    job = state['job']
    lease = state['pdfState']['lease']
    if lease is not None:
        try:
            lease.close()
            state['pdfState']['lease'] = None
        except Exception as error:
            _cleanup_error(state, 'Closing failed PDF read lease', error, primary)
    if state['exportPdfLease'] is not None:
        try:
            state['exportPdfLease'].close()
            state['exportPdfLease'] = None
        except Exception as error:
            _cleanup_error(state, 'Closing failed export-time PDF read lease', error, primary)
    if state['originalPdfLease'] is not None:
        try:
            state['originalPdfLease'].close()
            state['originalPdfLease'] = None
        except Exception as error:
            _cleanup_error(state, 'Closing original inspect PDF read lease', error, primary)
    for path, identity in state['owned'].items():
        try:
            if os.path.lexists(path):
                _require(_stamp(_entry(path, False))[:2] == identity,
                    'Preserve a foreign failed output replacement')
                path.unlink()
        except Exception as error:
            _cleanup_error(state, 'Removing owned failed PDF', error, primary)


def run(*_arguments):
    job = _load_job()
    manifest, worker = job['manifest'], job['worker']
    proof = dict(schema='piv.embedded-office-proof/1', jobToken=manifest['jobToken'],
        phaseToken=manifest['phaseToken'], phase=manifest['phase'], jobRoot=str(job['root']),
        phaseRoot=str(job['phaseRoot']), parentPid=manifest['parentPid'], pid=os.getpid(),
        nativeThreadId=threading.get_native_id(), requestSha256=manifest['requestSha256'],
        sourceSha256=manifest['sourceSha256'], candidateSha256=manifest['candidateSha256'],
        bootstrapPath=str(job['script']), windowsProcessImage=str(job['image']),
        windowsProcessImageSha256=manifest['runtimeSha256']['program/soffice.bin'],
        windowsImageIdentityVerified=True, contextKind='XSCRIPTCONTEXT local component context and desktop',
        remoteResolverCreated=False, serverEnterCount=0, serverExitCount=0, loadAttemptCount=0,
        documents=[], unsupportedBeforeLoad=False, allDocumentsDisposedAtServerExit=False,
        integrityConfirmed=False, cleanupErrors=[], responseFlushedBeforeCliReturn=False,
        readyForNaturalCliShutdown=False, shutdownReadyPublished=False,
        terminationObserverRegistered=False, terminationQueryCount=0, terminationVetoCount=0,
        terminationNotificationObserved=False, terminationNotificationVerified=False,
        shutdownCallbackPostCount=0, shutdownCallbackInvokeCount=0,
        shutdownCallbackTerminateRequested=False, shutdownCallbackTerminateReturned=None)
    state = dict(job=job, proof=proof, ready=False, fatal=False, refs=[], owned={},
        pdfState=dict(lease=None), originalPdfLease=None, exportPdfLease=None)
    _active_jobs.append(state)
    primary = None
    try:
        native = _initialize_uno(job['runtime'], worker)
        state.update(context=XSCRIPTCONTEXT.getComponentContext(), desktop=XSCRIPTCONTEXT.getDesktop())
        _native_boundary(job, state, native)
        _progress(state, 'calling-fixed-phase')
        result = _dispatch(job, state)
        _require(proof['serverEnterCount'] == 1 and proof['serverExitCount'] == 1 and
            _documents_complete(proof), 'The fixed phase did not close its one local context and documents')
        _verify_inputs(job)
        proof['integrityConfirmed'] = True
        response = dict(ok=True, result=result)
    except BaseException as error:
        primary = error
        state['fatal'] = True
        _failed_outputs(state, error)
        try:
            _verify_inputs(job)
            proof['integrityConfirmed'] = True
        except Exception as integrity_error:
            error.add_note('Verifying failed embedded input pins: ' + str(integrity_error))
        response = dict(ok=False, error=dict(code='office_operation_failed',
            message=str(error)[:4096], diagnostics=worker.error_diagnostics(error)))
        proof['exceptionNotes'] = [str(note)[:1024] for note in getattr(error, '__notes__', [])[:8]]
    if primary is not None:
        try:
            job['cleanup'].close()
        except Exception as cleanup_error:
            _cleanup_error(state, 'Closing failed embedded trust leases', cleanup_error, primary)
    response_path = job['phaseRoot'] / _PHASE_FILES['response']
    write_json(response_path, response)
    proof['responseFlushedBeforeCliReturn'] = True
    proof['responseSha256'] = digest(response_path)
    proof['readyForNaturalCliShutdown'] = primary is None and not state['fatal'] and not proof['cleanupErrors']
    proof['shutdownReadyPublished'] = proof['readyForNaturalCliShutdown']
    proof['shutdownCallbackPostCount'] = 1 if proof['readyForNaturalCliShutdown'] else 0
    proof['stage'] = 'awaiting-termination-notification' if primary is None else 'failed-before-ready'
    write_json(job['phaseRoot'] / _PHASE_FILES['proof'], proof)
    _progress(state, proof['stage'])
    if not proof['readyForNaturalCliShutdown']:
        return None
    # No macro proof writes follow publication: addCallback may synchronously reenter notifyTermination.
    state['ready'] = True
    try:
        state['callbackService'].addCallback(state['callback'], None)
    except Exception as error:
        state['fatal'] = True
        state['callbackEvidence']('single-callback-post-raised', error)
    return None


g_exportedScripts = (run,)
