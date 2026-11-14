"""Fixed data-only transport for the source-edit planner's detached result.

Integrity validation here preserves the planner's data. It does not grant source
edit authority or establish acceptance by a native document engine.
"""
from contextlib import ExitStack
import hashlib
import io
import json
import math
import os
from pathlib import Path
import re
import stat

import office_presentation_source as source_reader


_PLAN_KEYS = {'converted', 'parts', 'expected_native', 'expected_core', 'draft',
    'source_order', 'owner_ledger'}
_ENVELOPE_KEYS = {'schema', 'jobToken', 'phaseToken', 'requestSha256', 'sourceSha256', 'payload'}
_PAYLOAD_KEYS = {'fileName', 'byteLength', 'sha256', 'nodeCount'}
_PART_KEYS = {'sourcePart', 'fileName', 'byteLength', 'sha256'}
_CHUNK_BYTES = 1024 * 1024
_REPARSE_POINT = 0x400


def _require(condition, message):
    if not condition:
        raise ValueError(message)


def _closed(value, keys, label):
    _require(type(value) is dict and set(value) == keys and all(type(key) is str for key in value),
        'Invalid ' + label + ' schema')


def _hex(value, size, label):
    _require(type(value) is str and re.fullmatch('[0-9a-f]{%d}' % size, value) is not None,
        'Invalid ' + label)
    return value


def _integer(value, minimum, label):
    _require(type(value) is int and value >= minimum, 'Invalid ' + label)
    return value


def _plain(value):
    kind = type(value)
    if kind in (str, int, bool, type(None)):
        return value
    if kind is float:
        _require(math.isfinite(value), 'Nonfinite source-plan number')
        return value
    if kind is list:
        return [_plain(child) for child in value]
    if kind is dict:
        _require(all(type(key) is str for key in value), 'Source-plan object keys must be strings')
        return {key: _plain(child) for key, child in value.items()}
    raise ValueError('Unsupported source-plan value type')


def _anchor(value, encode):
    if value is None:
        return None
    expected = tuple if encode else list
    _require(type(value) is expected and len(value) == 2 and all(type(item) is int for item in value),
        'A native anchor must contain exactly two integers')
    return list(value) if encode else tuple(value)


def _native_table(value, encode):
    _require(type(value) is dict and all(type(key) is str for key in value) and
        type(value.get('cells')) is list, 'Invalid native source-plan table')
    result = {key: _plain(child) for key, child in value.items() if key != 'cells'}
    result['cells'] = []
    for cell in value['cells']:
        _require(type(cell) is dict and all(type(key) is str for key in cell) and 'anchorCellId' in cell,
            'Invalid native source-plan cell')
        result['cells'].append({key: _anchor(child, encode) if key == 'anchorCellId' else _plain(child)
            for key, child in cell.items()})
    return result


def _native_tables(value, encode):
    _require(type(value) is dict and all(type(key) is str for key in value),
        'Invalid expected native table inventory')
    return {key: _native_table(table, encode) for key, table in value.items()}


def _owners(value, encode):
    _require(type(value) is list, 'Invalid source owner ledger')
    result = []
    for owner in value:
        _require(type(owner) is dict and all(type(key) is str for key in owner) and
            type(owner.get('pairs')) is list, 'Invalid source owner record')
        copied = {key: _plain(child) for key, child in owner.items() if key != 'pairs'}
        copied['pairs'] = []
        for pair in owner['pairs']:
            _require(type(pair) is (tuple if encode else list) and len(pair) == 2,
                'A source owner pair must contain exactly two values')
            table, core = _native_table(pair[0], encode), _plain(pair[1])
            copied['pairs'].append([table, core] if encode else (table, core))
        result.append(copied)
    return result


def _node_count(value):
    if type(value) is dict:
        return 1 + sum(_node_count(child) for child in value.values())
    if type(value) is list:
        return 1 + sum(map(_node_count, value))
    return 1


def _bytes_hash(data):
    digest = hashlib.sha256()
    for start in range(0, len(data), _CHUNK_BYTES):
        digest.update(data[start:start + _CHUNK_BYTES])
    return digest.hexdigest()


def _source_order(value, names):
    _require(type(value) is list and all(type(name) is str for name in value) and
        len(value) == len(set(value)) and value == names,
        'Source-plan part order or coverage differs')
    return list(value)


def _encode_plan(plan):
    _closed(plan, _PLAN_KEYS, 'source-plan')
    parts = plan['parts']
    _require(type(parts) is dict and all(type(name) is str and type(data) is bytes
        for name, data in parts.items()), 'Source-plan parts must be ordered XML bytes')
    order = _source_order(plan['source_order'], list(parts))
    _require(all(len(data) <= source_reader.PART_BYTES for data in parts.values()) and
        sum(map(len, parts.values())) <= source_reader.TOTAL_XML_BYTES,
        'Source-plan XML component limit exceeded')
    records = [dict(sourcePart=name, fileName='parts/p%06d.bin' % index,
        byteLength=len(data), sha256=_bytes_hash(data)) for index, (name, data) in enumerate(parts.items())]
    return {'converted': _plain(plan['converted']), 'parts': records,
        'expected_native': _native_tables(plan['expected_native'], True),
        'expected_core': _plain(plan['expected_core']), 'draft': _plain(plan['draft']),
        'source_order': order, 'owner_ledger': _owners(plan['owner_ledger'], True)}


def _path_stat(path, directory):
    value = path.lstat()
    _require(not stat.S_ISLNK(value.st_mode) and not getattr(value, 'st_file_attributes', 0) & _REPARSE_POINT,
        'Source-plan links and reparse points are forbidden')
    _require(stat.S_ISDIR(value.st_mode) if directory else stat.S_ISREG(value.st_mode),
        'Invalid source-plan filesystem entry')
    if not directory:
        _require(value.st_nlink == 1, 'Source-plan files must not have external hard links')
    return value


class _PathLease:
    """Hold no-write/no-delete Windows handles without following reparse points."""
    def __init__(self, path, directory):
        self.path, self.directory = path, directory
        self.before = _path_stat(path, directory)
        self.handle, self.fd = None, None
        if os.name == 'nt':
            import ctypes
            from ctypes import wintypes

            class FileInformation(ctypes.Structure):
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
            self.kernel.GetFileInformationByHandle.argtypes = [wintypes.HANDLE, ctypes.POINTER(FileInformation)]
            self.kernel.GetFileInformationByHandle.restype = wintypes.BOOL
            flags = 0x00200000 | (0x02000000 if directory else 0x80)
            self.handle = self.kernel.CreateFileW(str(path), 0x80000000, 0x00000001, None, 3, flags, None)
            if self.handle in (None, ctypes.c_void_p(-1).value):
                self.handle = None
                raise ctypes.WinError(ctypes.get_last_error())
            try:
                information = FileInformation()
                if not self.kernel.GetFileInformationByHandle(self.handle, ctypes.byref(information)):
                    raise ctypes.WinError(ctypes.get_last_error())
                _require(not information.attributes & _REPARSE_POINT and
                    bool(information.attributes & 0x10) == directory,
                    'A source-plan handle resolves to an invalid entry')
                if not directory:
                    _require(information.links == 1, 'Source-plan files must not have external hard links')
                self.verify()
            except BaseException:
                self.close()
                raise
        else:
            flags = os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0)
            if directory:
                flags |= getattr(os, 'O_DIRECTORY', 0)
            self.fd = os.open(path, flags)
            try:
                self.verify()
                _require(source_reader._stamp(os.fstat(self.fd)) == source_reader._stamp(self.before),
                    'The opened source-plan identity differs')
            except BaseException:
                self.close()
                raise

    def verify(self):
        observed = _path_stat(self.path, self.directory)
        before, after = source_reader._stamp(self.before), source_reader._stamp(observed)
        _require(before[:2] == after[:2] if self.directory else before == after,
            'The source-plan filesystem identity changed')

    def close(self):
        if self.handle is not None:
            import ctypes
            if not self.kernel.CloseHandle(self.handle):
                raise ctypes.WinError(ctypes.get_last_error())
            self.handle = None
        if self.fd is not None:
            os.close(self.fd)
            self.fd = None


def _lease(path, directory, cleanup, leases):
    lease = _PathLease(path, directory)
    cleanup.callback(lease.close)
    leases.append(lease)
    return lease


def _directories(path, cleanup, leases):
    for directory in (*reversed(path.parents), path):
        _lease(directory, True, cleanup, leases)


def _read_file(path, byte_length, expected_hash, cleanup, leases):
    _integer(byte_length, 0, 'source-plan file size')
    _hex(expected_hash, 64, 'source-plan file hash')
    lease = _lease(path, False, cleanup, leases)
    _require(lease.before.st_size == byte_length, 'The source-plan file length differs')
    flags = os.O_RDONLY | getattr(os, 'O_BINARY', 0) | getattr(os, 'O_NOFOLLOW', 0)
    with os.fdopen(os.open(path, flags), 'rb', buffering=0) as stream:
        before = source_reader._stamp(lease.before)
        _require(source_reader._stamp(os.fstat(stream.fileno())) == before,
            'The opened source-plan file identity differs')
        view = io.BytesIO()
        _require(source_reader._digest(stream, byte_length, view) == expected_hash,
            'The source-plan file hash differs')
        _require(source_reader._stamp(os.fstat(stream.fileno())) == before,
            'The source-plan file changed during reading')
        lease.verify()
        return view.getvalue()


def _write_file(path, data, expected_hash, cleanup, leases):
    with path.open('x+b', buffering=0) as stream:
        for start in range(0, len(data), _CHUNK_BYTES):
            chunk = data[start:start + _CHUNK_BYTES]
            _require(stream.write(chunk) == len(chunk), 'The source-plan file write is incomplete')
        stream.flush()
        _require(source_reader._digest(stream, len(data)) == expected_hash,
            'The written source-plan bytes differ')
        before = source_reader._stamp(os.fstat(stream.fileno()))
    lease = _lease(path, False, cleanup, leases)
    _require(source_reader._stamp(lease.before) == before, 'The written source-plan identity changed')
    _read_file(path, len(data), expected_hash, cleanup, leases)


def _tokens(job_token, phase_token, request_sha256, source_sha256):
    return (_hex(job_token, 32, 'job token'), _hex(phase_token, 32, 'phase token'),
        _hex(request_sha256, 64, 'request hash'), _hex(source_sha256, 64, 'source hash'))


def write_source_plan(directory, plan, *, job_token, phase_token, request_sha256, source_sha256):
    """Write an exclusive fresh child directory and return its closed envelope."""
    job_token, phase_token, request_sha256, source_sha256 = _tokens(
        job_token, phase_token, request_sha256, source_sha256)
    value = _encode_plan(plan)
    raw = json.dumps(value, ensure_ascii=False, allow_nan=False, separators=(',', ':')).encode('utf-8')
    payload = dict(fileName='plan.json', byteLength=len(raw), sha256=_bytes_hash(raw), nodeCount=_node_count(value))
    directory = Path(os.path.abspath(directory))
    with ExitStack() as cleanup:
        leases = []
        _directories(directory.parent, cleanup, leases)
        directory.mkdir()
        _lease(directory, True, cleanup, leases)
        parts = directory / 'parts'
        parts.mkdir()
        _lease(parts, True, cleanup, leases)
        for record, data in zip(value['parts'], plan['parts'].values()):
            _write_file(directory / record['fileName'], data, record['sha256'], cleanup, leases)
        _write_file(directory / 'plan.json', raw, payload['sha256'], cleanup, leases)
        for lease in leases:
            lease.verify()
    return dict(schema='piv.source-plan/1', jobToken=job_token, phaseToken=phase_token,
        requestSha256=request_sha256, sourceSha256=source_sha256, payload=payload)


def _object(pairs):
    result = {}
    for key, value in pairs:
        _require(key not in result, 'Duplicate source-plan JSON key')
        result[key] = value
    return result


def _constant(value):
    raise ValueError('Nonfinite source-plan JSON number')


def _part_records(value):
    _require(type(value['parts']) is list, 'Invalid source-plan part records')
    names, total = [], 0
    for index, record in enumerate(value['parts']):
        _closed(record, _PART_KEYS, 'source-plan part')
        _require(type(record['sourcePart']) is str and record['sourcePart'] not in names,
            'Duplicate or invalid source-plan part name')
        _require(record['fileName'] == 'parts/p%06d.bin' % index and type(record['fileName']) is str,
            'Invalid ordinal source-plan artifact path')
        length = _integer(record['byteLength'], 0, 'source-plan part size')
        _hex(record['sha256'], 64, 'source-plan part hash')
        _require(length <= source_reader.PART_BYTES, 'Source-plan XML component limit exceeded')
        total += length
        _require(total <= source_reader.TOTAL_XML_BYTES, 'Source-plan total XML limit exceeded')
        names.append(record['sourcePart'])
    _source_order(value['source_order'], names)
    return value['parts']


def read_source_plan(directory, envelope, *, expected_job_token, expected_phase_token,
        expected_request_sha256, expected_source_sha256):
    """Return the same detached plan after verifying its exact owned artifacts."""
    expected = _tokens(expected_job_token, expected_phase_token, expected_request_sha256, expected_source_sha256)
    _closed(envelope, _ENVELOPE_KEYS, 'source-plan envelope')
    _require(type(envelope['schema']) is str and envelope['schema'] == 'piv.source-plan/1',
        'Unsupported source-plan wire version')
    observed = _tokens(envelope['jobToken'], envelope['phaseToken'], envelope['requestSha256'], envelope['sourceSha256'])
    _require(observed == expected, 'Source-plan envelope provenance differs')
    payload = envelope['payload']
    _closed(payload, _PAYLOAD_KEYS, 'source-plan payload')
    _require(type(payload['fileName']) is str and payload['fileName'] == 'plan.json',
        'Invalid source-plan payload path')
    _integer(payload['nodeCount'], 1, 'source-plan node count')
    directory = Path(os.path.abspath(directory))
    with ExitStack() as cleanup:
        leases = []
        _directories(directory, cleanup, leases)
        raw = _read_file(directory / 'plan.json', payload['byteLength'], payload['sha256'], cleanup, leases)
        value = json.loads(raw.decode('utf-8'), object_pairs_hook=_object, parse_constant=_constant)
        _closed(value, _PLAN_KEYS, 'source-plan')
        _require(_node_count(value) == payload['nodeCount'], 'Source-plan JSON node count differs')
        records = _part_records(value)
        result = {'converted': _plain(value['converted']), 'parts': {},
            'expected_native': _native_tables(value['expected_native'], False),
            'expected_core': _plain(value['expected_core']), 'draft': _plain(value['draft']),
            'source_order': list(value['source_order']), 'owner_ledger': _owners(value['owner_ledger'], False)}
        _lease(directory / 'parts', True, cleanup, leases)
        for record in records:
            result['parts'][record['sourcePart']] = _read_file(directory / record['fileName'],
                record['byteLength'], record['sha256'], cleanup, leases)
        for lease in leases:
            lease.verify()
        return result
