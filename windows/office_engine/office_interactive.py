import argparse
from contextlib import nullcontext
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys
import threading

sys.path.insert(0, str(Path(__file__).resolve().parent))
import office_worker as office
from office_interactive_lifetime import Lifetime, SessionLease


ENGINE = 'LibreOffice26.8.2.2'
MAX_FILE = 128 * 1024 * 1024
MAX_JSON = 64 * 1024
UUID = re.compile(r'^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$')
HASH = re.compile(r'^[a-f0-9]{64}$')
FIELDS = {'version', 'sessionId', 'controlNonce', 'workingFileName', 'inputSourceSha256',
    'expectedWorkingSha256', 'workingLength', 'parentProcessId', 'parentExecutablePath'}
COMMON = {'version', 'sessionId', 'controlNonce', 'inputSourceSha256', 'status', 'engineVersion'}
SAVED = COMMON | {'sourcePath', 'pdfPath', 'sourceSha256', 'pdfSha256', 'pdfPageCount'}


class InteractiveError(ValueError):
    def __init__(self, code):
        self.code = code
        super().__init__(code)


@dataclass(frozen=True)
class Request:
    data: dict
    working: Path
    launch: Path
    session: Path
    path: Path
    extension: str


def _plain_directory(path):
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or path.is_symlink() or path.is_junction():
        raise InteractiveError('interactive_invalid_path')


def _plain_file(path, maximum=MAX_FILE):
    info = path.lstat()
    if (not stat.S_ISREG(info.st_mode) or path.is_symlink() or
            info.st_file_attributes & 0x400 or info.st_nlink != 1 or not 0 < info.st_size <= maximum):
        raise InteractiveError('interactive_invalid_file')
    return info


def _identity(info):
    return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns)


def file_hash(path):
    try:
        before = _plain_file(path)
        result = hashlib.sha256()
        with path.open('rb') as stream:
            while value := stream.read(65536):
                result.update(value)
        if _identity(_plain_file(path)) != _identity(before):
            raise InteractiveError('interactive_working_changed')
        return result.hexdigest(), before.st_size
    except OSError as error:
        raise InteractiveError('interactive_file_unavailable') from error


def _pairs(values):
    result = {}
    for key, value in values:
        if key in result:
            raise InteractiveError('interactive_invalid_json')
        result[key] = value
    return result


def _read_json(path):
    try:
        before = _plain_file(path, MAX_JSON)
        raw = path.read_bytes()
        if len(raw) != before.st_size or _identity(_plain_file(path, MAX_JSON)) != _identity(before):
            raise InteractiveError('interactive_invalid_json')
        return json.loads(raw.decode('utf-8'), object_pairs_hook=_pairs)
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise InteractiveError('interactive_invalid_json') from error


def _request(path, *, historical=False):
    try:
        path = Path(path).absolute()
        if path.name != 'request.json':
            raise InteractiveError('interactive_invalid_path')
        launch, session = path.parent, path.parent.parent
        _plain_directory(session)
        _plain_directory(launch)
        if not UUID.fullmatch(session.name) or not launch.name.startswith('interactive-'):
            raise InteractiveError('interactive_invalid_path')
        nonce = launch.name[len('interactive-'):]
        if not UUID.fullmatch(nonce):
            raise InteractiveError('interactive_invalid_path')
        if launch.resolve() != launch or session.resolve() != session:
            raise InteractiveError('interactive_invalid_path')
        data = _read_json(path)
        if (type(data) is not dict or set(data) != FIELDS or type(data['version']) is not int or
                data['version'] != 1 or data['sessionId'] != session.name or data['controlNonce'] != nonce):
            raise InteractiveError('interactive_invalid_request')
        name = data['workingFileName']
        if not isinstance(name, str) or not re.fullmatch(r'original\.(docx?|pptx?|od[tp])', name, re.IGNORECASE):
            raise InteractiveError('interactive_invalid_request')
        for key in ('inputSourceSha256', 'expectedWorkingSha256'):
            if type(data[key]) is not str or not HASH.fullmatch(data[key]):
                raise InteractiveError('interactive_invalid_request')
        if (type(data['workingLength']) is not int or not 0 < data['workingLength'] <= MAX_FILE or
                type(data['parentProcessId']) is not int or not 0 < data['parentProcessId'] < 2 ** 32 or
                type(data['parentExecutablePath']) is not str or not Path(data['parentExecutablePath']).is_absolute()):
            raise InteractiveError('interactive_invalid_request')
        if not historical:
            _plain_file(Path(data['parentExecutablePath']))
        return Request(data, session / name, launch, session, path, name.rsplit('.', 1)[1].lower())
    except OSError as error:
        raise InteractiveError('interactive_invalid_path') from error


def _base(request, status):
    return {'version': 1, 'sessionId': request.data['sessionId'],
        'controlNonce': request.data['controlNonce'], 'inputSourceSha256': request.data['inputSourceSha256'],
        'status': status, 'engineVersion': ENGINE}


def pdf_page_count(path):
    return len(office.PdfReader(str(path), strict=True).pages)


def _pdf(path, expected_hash=None, expected_pages=None):
    digest, length = file_hash(path)
    with path.open('rb') as stream:
        if stream.read(5) != b'%PDF-':
            raise InteractiveError('interactive_invalid_pdf')
        stream.seek(max(0, length - 4096))
        if b'%%EOF' not in stream.read():
            raise InteractiveError('interactive_invalid_pdf')
    pages = pdf_page_count(path)
    if type(pages) is not int or pages < 1 or pages > 100000:
        raise InteractiveError('interactive_invalid_pdf')
    if expected_pages is not None and expected_pages != pages or expected_hash is not None and expected_hash != digest:
        raise InteractiveError('interactive_invalid_pdf')
    if file_hash(path) != (digest, length):
        raise InteractiveError('interactive_invalid_pdf')
    return digest, pages


def _terminal(request):
    path = request.launch / 'response.json'
    if not path.exists():
        return None
    result = _read_json(path)
    if type(result) is not dict or result.get('status') not in ('saved', 'cancelled', 'error'):
        raise InteractiveError('interactive_invalid_receipt')
    expected = _base(request, result['status'])
    if any(type(result.get(key)) is not type(value) or result.get(key) != value for key, value in expected.items()):
        raise InteractiveError('interactive_invalid_receipt')
    if result['status'] == 'cancelled':
        if set(result) != COMMON:
            raise InteractiveError('interactive_invalid_receipt')
        return result
    if result['status'] == 'error':
        error = result.get('error')
        if (set(result) != COMMON | {'error'} or type(error) is not dict or
                set(error) != {'code', 'message'} or type(error['code']) is not str or
                not re.fullmatch(r'[a-z0-9_]{1,96}', error['code']) or
                type(error['message']) is not str or not 0 < len(error['message']) <= 512):
            raise InteractiveError('interactive_invalid_receipt')
        return result
    if set(result) != SAVED:
        raise InteractiveError('interactive_invalid_receipt')
    source, pdf = request.launch / ('edited.' + request.extension), request.launch / 'preview.pdf'
    if (result['sourcePath'] != str(source) or result['pdfPath'] != str(pdf) or
            type(result['pdfPageCount']) is not int or result['pdfPageCount'] < 1):
        raise InteractiveError('interactive_invalid_receipt')
    if file_hash(source)[0] != result['sourceSha256']:
        raise InteractiveError('interactive_invalid_receipt')
    _pdf(pdf, result['pdfSha256'], result['pdfPageCount'])
    return result


def _prior(request):
    matches = []
    folders = list(request.session.iterdir())
    if len(folders) > 256:
        raise InteractiveError('interactive_recovery_limit')
    for folder in sorted(folders):
        if folder == request.launch or not folder.name.startswith('interactive-'):
            continue
        if not UUID.fullmatch(folder.name[len('interactive-'):]):
            continue
        _plain_directory(folder)
        try:
            (folder / 'request.json').lstat()
        except FileNotFoundError:
            with os.scandir(folder) as entries:
                first, extra = next(entries, None), next(entries, None)
            if first is None:
                continue
            if extra is not None or first.name != 'request.pending':
                raise InteractiveError('interactive_invalid_receipt')
            pending = Path(first.path)
            info = pending.lstat()
            if (not stat.S_ISREG(info.st_mode) or pending.is_symlink() or
                    info.st_file_attributes & 0x400 or info.st_nlink != 1 or not 0 <= info.st_size <= MAX_JSON):
                raise InteractiveError('interactive_invalid_receipt')
            continue
        previous = _request(folder / 'request.json', historical=True)
        if (previous.data['sessionId'] != request.data['sessionId'] or
                previous.data['inputSourceSha256'] != request.data['inputSourceSha256'] or
                previous.data['workingFileName'] != request.data['workingFileName']):
            raise InteractiveError('interactive_invalid_receipt')
        matches.append(previous)
    return matches


def _verify_working(request, terminal=None):
    actual, length = file_hash(request.working)
    if terminal is None:
        if actual != request.data['expectedWorkingSha256'] or length != request.data['workingLength']:
            raise InteractiveError('interactive_working_changed')
        if actual != request.data['inputSourceSha256'] and not _prior(request):
            raise InteractiveError('interactive_working_changed')
    elif terminal['status'] == 'saved' and actual != terminal['sourceSha256']:
        raise InteractiveError('interactive_working_changed')
    elif terminal['status'] == 'error':
        raise InteractiveError(terminal['error']['code'])
    return actual


def read_request(path):
    request = _request(path)
    _verify_working(request, _terminal(request))
    return request


def _publish(request, result):
    pending, destination = request.launch / 'response.pending', request.launch / 'response.json'
    raw = (json.dumps(result, ensure_ascii=False, separators=(',', ':'), allow_nan=False) + '\n').encode('utf-8')
    if len(raw) > MAX_JSON or destination.exists():
        raise InteractiveError('interactive_existing_output')
    with pending.open('xb') as stream:
        stream.write(raw)
        stream.flush()
        os.fsync(stream.fileno())
    if os.name == 'nt':
        os.rename(pending, destination)
    else:
        os.link(pending, destination)
        pending.unlink()


def _copy(source, destination, expected_hash):
    if destination.exists():
        raise InteractiveError('interactive_existing_output')
    before, _ = file_hash(source)
    if before != expected_hash:
        raise InteractiveError('interactive_working_changed')
    with source.open('rb') as stream, destination.open('xb') as output:
        while value := stream.read(65536):
            output.write(value)
        output.flush()
        os.fsync(output.fileno())
    if file_hash(source)[0] != expected_hash or file_hash(destination)[0] != expected_hash:
        raise InteractiveError('interactive_working_changed')


class DocumentState:
    def __init__(self, working, initial_hash):
        self.working, self.saved_hash = working, initial_hash
        self.normal_close = self.disposed = self.save_as_pending = self.foreign_url = False
        self.failure = None
        self._lock = threading.Lock()

    def queryClosing(self, _event, _ownership):
        return None

    def notifyClosing(self, _event):
        with self._lock:
            self.normal_close = True

    def disposing(self, _event):
        with self._lock:
            self.disposed = True

    def documentEventOccured(self, event):
        if event.EventName == 'OnSaveAsDone':
            with self._lock:
                self.save_as_pending = True
        elif event.EventName == 'OnSaveDone':
            try:
                digest = file_hash(self.working)[0]
                with self._lock:
                    self.saved_hash = digest
            except BaseException:
                with self._lock:
                    self.failure = 'interactive_save_unverified'

    def observe_uri(self, uri):
        with self._lock:
            if uri != self.working.as_uri():
                self.foreign_url = True
            elif self.save_as_pending:
                self.save_as_pending = False

    def verify(self, digest):
        with self._lock:
            if not self.normal_close or not self.disposed:
                raise InteractiveError('interactive_closed_unexpectedly')
            if self.foreign_url or self.save_as_pending:
                raise InteractiveError('interactive_save_as_unbound')
            if self.failure:
                raise InteractiveError(self.failure)
            if self.saved_hash != digest:
                raise InteractiveError('interactive_working_changed')


def native_listener(state):
    import unohelper
    from com.sun.star.document import XDocumentEventListener
    from com.sun.star.util import XCloseListener

    class Listener(unohelper.Base, XDocumentEventListener, XCloseListener):
        def queryClosing(self, event, ownership):
            state.queryClosing(event, ownership)

        def notifyClosing(self, event):
            state.notifyClosing(event)

        def disposing(self, event):
            state.disposing(event)

        def documentEventOccured(self, event):
            state.documentEventOccured(event)

    return Listener()


class DeferredOfficeServer(office.OfficeServer):
    def cleanup_profile(self):
        return None

    def release_profile(self):
        super().cleanup_profile()


def make_server(runtime, directory, *, interactive=False):
    return (DeferredOfficeServer(runtime, directory, interactive=True)
        if interactive else office.OfficeServer(runtime, directory))


def _components_empty(server):
    values = server.desktop.getComponents().createEnumeration()
    return not values.hasMoreElements()


def _kind(document, extension):
    try:
        return office.require_document_kind(document, extension)
    except office.DocumentFamilyMismatch as error:
        raise InteractiveError('interactive_invalid_document') from error


def _recover(request, actual):
    candidates = []
    for previous in _prior(request):
        terminal = _terminal(previous)
        if terminal is not None and terminal['status'] == 'saved' and terminal['sourceSha256'] == actual:
            candidates.append((previous, terminal))
    if not candidates:
        return None
    previous, terminal = candidates[-1]
    source, pdf = request.launch / ('edited.' + request.extension), request.launch / 'preview.pdf'
    _copy(Path(terminal['sourcePath']), source, terminal['sourceSha256'])
    _copy(Path(terminal['pdfPath']), pdf, terminal['pdfSha256'])
    return {**_base(request, 'saved'), 'sourcePath': str(source), 'pdfPath': str(pdf),
        'sourceSha256': terminal['sourceSha256'], 'pdfSha256': terminal['pdfSha256'],
        'pdfPageCount': terminal['pdfPageCount']}


def run_session(runtime, request_path, *, server_factory=None, lifetime_factory=None,
        lease_factory=None, listener_factory=None):
    request = _request(request_path)
    server_factory = make_server if server_factory is None else server_factory
    lifetime_factory = Lifetime if lifetime_factory is None else lifetime_factory
    lease_factory = SessionLease if lease_factory is None else lease_factory
    listener_factory = native_listener if listener_factory is None else listener_factory
    try:
        lease = lease_factory(request)
        lease.__enter__()
    except OSError as error:
        raise InteractiveError('interactive_session_busy') from error
    try:
        terminal = _terminal(request)
        actual = _verify_working(request, terminal)
        if terminal is not None:
            return terminal
        for name in ('edited.' + request.extension, 'preview.pdf', 'response.pending'):
            if (request.launch / name).exists():
                raise InteractiveError('interactive_existing_output')
        recovered = _recover(request, actual)
        if recovered is not None:
            _publish(request, recovered)
            return recovered
        with lifetime_factory(request) as lifetime:
            lifetime.stage('startup', 90)
            lifetime.check()
            if getattr(lifetime, '_control_error', None):
                raise InteractiveError(lifetime._control_error)
            if lifetime.cancelled:
                lifetime.stage('finalizing', 180)
                result = _base(request, 'cancelled')
                _publish(request, result)
                return result
            gui = server_factory(runtime, request.launch, interactive=True)
            with gui as server:
                lifetime.check()
                document = server.load(request.working, read_only=False)
                _kind(document, request.extension)
                if document.isReadonly():
                    raise InteractiveError('interactive_read_only')
                state = DocumentState(request.working, actual)
                listener = listener_factory(state)
                document.addCloseListener(listener)
                document.addDocumentEventListener(listener)
                state.observe_uri(document.getURL())
                lifetime.stage('editing', None)
                while True:
                    lifetime.check()
                    if state.disposed:
                        if not state.normal_close:
                            raise InteractiveError('interactive_closed_unexpectedly')
                        try:
                            if _components_empty(server):
                                break
                        except Exception as error:
                            if server.process.exit_code() == 0:
                                break
                            raise InteractiveError('interactive_closed_unexpectedly') from error
                    else:
                        try:
                            state.observe_uri(document.getURL())
                        except Exception as error:
                            if not state.disposed:
                                raise InteractiveError('interactive_closed_unexpectedly') from error
                    lifetime.wait(.1)
                lifetime.stage('finalizing', 180)
            if getattr(lifetime, '_control_error', None):
                raise InteractiveError(lifetime._control_error)
            if lifetime.cancelled:
                result = _base(request, 'cancelled')
            else:
                saved_hash, _ = file_hash(request.working)
                state.verify(saved_hash)
                if saved_hash == request.data['inputSourceSha256']:
                    result = _base(request, 'cancelled')
                else:
                    source, pdf = request.launch / ('edited.' + request.extension), request.launch / 'preview.pdf'
                    _copy(request.working, source, saved_hash)
                    with server_factory(runtime, request.launch, interactive=False) as validator:
                        document = validator.load(source, read_only=True)
                        try:
                            kind = _kind(document, request.extension)
                            pages = office.export_pdf(document, pdf, kind)
                            if kind == 'presentation' and pages != document.getDrawPages().getCount():
                                raise InteractiveError('interactive_invalid_pdf')
                        finally:
                            document.close(True)
                    pdf_hash, pages = _pdf(pdf, expected_pages=pages)
                    if file_hash(source)[0] != saved_hash or file_hash(request.working)[0] != saved_hash:
                        raise InteractiveError('interactive_working_changed')
                    result = {**_base(request, 'saved'), 'sourcePath': str(source), 'pdfPath': str(pdf),
                        'sourceSha256': saved_hash, 'pdfSha256': pdf_hash, 'pdfPageCount': pages}
            lifetime.check()
            gui.release_profile()
            _publish(request, result)
            return result
    finally:
        lease.__exit__(None, None, None)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--runtime', type=Path, required=True)
    parser.add_argument('--request', type=Path, required=True)
    args = parser.parse_args()
    request = None
    try:
        request = _request(args.request)
        with Lifetime(request) as lifetime:
            lifetime.stage('startup', 90)
            office.initialize(args.runtime.resolve(strict=True))
            run_session(args.runtime.resolve(strict=True), args.request,
                lifetime_factory=lambda _request: nullcontext(lifetime))
    except BaseException as error:
        if request is not None and not (request.launch / 'response.json').exists():
            code = error.code if isinstance(error, InteractiveError) else 'interactive_operation_failed'
            response = {**_base(request, 'error'), 'error': {'code': code,
                'message': 'The private Office edit could not be completed. The working file is retained.'}}
            try:
                _publish(request, response)
            except BaseException:
                pass
        raise SystemExit(1)


if __name__ == '__main__':
    main()
