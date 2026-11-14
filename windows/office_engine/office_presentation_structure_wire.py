"""Data-only detached structure plans, separate from the source-text wire schema."""
from contextlib import ExitStack
import json
import os
from pathlib import Path

import office_presentation_source as source_reader
import office_presentation_stage_wire as wire


_SCHEMA = 'piv.structure-plan/1'
_PLAN_KEYS = {'converted', 'parts', 'expected_native', 'expected_core', 'source_order',
    'owner_ledger', 'additions', 'base_snapshot'}
_PAYLOAD_BYTES, _PAYLOAD_NODES, _PART_LIMIT = 16 * 1024 * 1024, 524288, 4096


def _part_name(name):
    wire._require(type(name) is str and source_reader._member_name(name) == name and
        not name.endswith('/'), 'Invalid structure-plan source part name')
    return name


def _encode_plan(plan):
    wire._closed(plan, _PLAN_KEYS, 'structure-plan')
    parts = plan['parts']
    wire._require(type(parts) is dict and len(parts) <= _PART_LIMIT and
        all(type(name) is str and type(data) is bytes for name, data in parts.items()),
        'Structure-plan parts must be bounded ordered XML bytes')
    for name in parts:
        _part_name(name)
    order = wire._source_order(plan['source_order'], list(parts))
    wire._require(all(len(data) <= source_reader.PART_BYTES for data in parts.values()) and
        sum(map(len, parts.values())) <= source_reader.TOTAL_XML_BYTES,
        'Structure-plan XML component limit exceeded')
    records = [dict(sourcePart=name, fileName='parts/p%06d.bin' % index,
        byteLength=len(data), sha256=wire._bytes_hash(data)) for index, (name, data) in enumerate(parts.items())]
    return {'converted': wire._plain(plan['converted']), 'parts': records,
        'expected_native': wire._native_tables(plan['expected_native'], True),
        'expected_core': wire._plain(plan['expected_core']), 'source_order': order,
        'owner_ledger': wire._owners(plan['owner_ledger'], True),
        'additions': wire._plain(plan['additions']), 'base_snapshot': wire._plain(plan['base_snapshot'])}


def _payload_bounds(payload):
    wire._integer(payload['byteLength'], 1, 'structure-plan payload size')
    wire._integer(payload['nodeCount'], 1, 'structure-plan payload node count')
    wire._require(payload['byteLength'] <= _PAYLOAD_BYTES and payload['nodeCount'] <= _PAYLOAD_NODES,
        'Structure-plan payload byte or node limit exceeded')


def _part_records(value):
    wire._require(type(value['parts']) is list and len(value['parts']) <= _PART_LIMIT,
        'Structure-plan XML component count limit exceeded')
    records = wire._part_records(value)
    for record in records:
        _part_name(record['sourcePart'])
    return records


def write_structure_plan(directory, plan, *, job_token, phase_token, request_sha256, source_sha256):
    """Write an exclusive structure-plan directory without granting native edit rights."""
    job_token, phase_token, request_sha256, source_sha256 = wire._tokens(
        job_token, phase_token, request_sha256, source_sha256)
    value = _encode_plan(plan)
    node_count = wire._node_count(value)
    wire._require(node_count <= _PAYLOAD_NODES, 'Structure-plan payload node limit exceeded')
    raw = json.dumps(value, ensure_ascii=False, allow_nan=False, separators=(',', ':')).encode('utf-8')
    payload = dict(fileName='plan.json', byteLength=len(raw), sha256=wire._bytes_hash(raw), nodeCount=node_count)
    _payload_bounds(payload)
    directory = Path(os.path.abspath(directory))
    with ExitStack() as cleanup:
        leases = []
        wire._directories(directory.parent, cleanup, leases)
        directory.mkdir()
        wire._lease(directory, True, cleanup, leases)
        parts = directory / 'parts'
        parts.mkdir()
        wire._lease(parts, True, cleanup, leases)
        for record, data in zip(value['parts'], plan['parts'].values()):
            wire._write_file(directory / record['fileName'], data, record['sha256'], cleanup, leases)
        wire._write_file(directory / 'plan.json', raw, payload['sha256'], cleanup, leases)
        for lease in leases:
            lease.verify()
    return dict(schema=_SCHEMA, jobToken=job_token, phaseToken=phase_token,
        requestSha256=request_sha256, sourceSha256=source_sha256, payload=payload)


def read_structure_plan(directory, envelope, *, expected_job_token, expected_phase_token,
        expected_request_sha256, expected_source_sha256):
    """Return detached data only after exact provenance, type, and artifact checks."""
    expected = wire._tokens(expected_job_token, expected_phase_token,
        expected_request_sha256, expected_source_sha256)
    wire._closed(envelope, wire._ENVELOPE_KEYS, 'structure-plan envelope')
    wire._require(type(envelope['schema']) is str and envelope['schema'] == _SCHEMA,
        'Unsupported structure-plan wire version')
    observed = wire._tokens(envelope['jobToken'], envelope['phaseToken'],
        envelope['requestSha256'], envelope['sourceSha256'])
    wire._require(observed == expected, 'Structure-plan envelope provenance differs')
    payload = envelope['payload']
    wire._closed(payload, wire._PAYLOAD_KEYS, 'structure-plan payload')
    wire._require(type(payload['fileName']) is str and payload['fileName'] == 'plan.json',
        'Invalid structure-plan payload path')
    _payload_bounds(payload)
    wire._hex(payload['sha256'], 64, 'structure-plan payload hash')
    directory = Path(os.path.abspath(directory))
    with ExitStack() as cleanup:
        leases = []
        wire._directories(directory, cleanup, leases)
        raw = wire._read_file(directory / 'plan.json', payload['byteLength'], payload['sha256'], cleanup, leases)
        value = json.loads(raw.decode('utf-8'), object_pairs_hook=wire._object, parse_constant=wire._constant)
        wire._closed(value, _PLAN_KEYS, 'structure-plan')
        wire._require(wire._node_count(value) == payload['nodeCount'], 'Structure-plan JSON node count differs')
        records = _part_records(value)
        result = {'converted': wire._plain(value['converted']), 'parts': {},
            'expected_native': wire._native_tables(value['expected_native'], False),
            'expected_core': wire._plain(value['expected_core']), 'source_order': list(value['source_order']),
            'owner_ledger': wire._owners(value['owner_ledger'], False),
            'additions': wire._plain(value['additions']), 'base_snapshot': wire._plain(value['base_snapshot'])}
        wire._lease(directory / 'parts', True, cleanup, leases)
        for record in records:
            result['parts'][record['sourcePart']] = wire._read_file(directory / record['fileName'],
                record['byteLength'], record['sha256'], cleanup, leases)
        for lease in leases:
            lease.verify()
        return result
