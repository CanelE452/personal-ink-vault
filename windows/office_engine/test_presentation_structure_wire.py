"""Detached structure-plan transport tests; root alone executes filesystem leases."""
import copy
import hashlib
import importlib
import importlib.util
import json
import os
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace
import unittest

import office_presentation_stage_wire as legacy_wire
import test_presentation_stage_wire as legacy_fixtures


MODULE = (importlib.import_module('office_presentation_structure_wire')
    if importlib.util.find_spec('office_presentation_structure_wire') is not None
    else SimpleNamespace(write_structure_plan=None, read_structure_plan=None))
PLAN_KEYS = {'converted', 'parts', 'expected_native', 'expected_core', 'source_order',
    'owner_ledger', 'additions', 'base_snapshot'}
ENVELOPE_KEYS = {'schema', 'jobToken', 'phaseToken', 'requestSha256', 'sourceSha256', 'payload'}
PAYLOAD_KEYS = {'fileName', 'byteLength', 'sha256', 'nodeCount'}
PART_KEYS = {'sourcePart', 'fileName', 'byteLength', 'sha256'}
JOB, PHASE, REQUEST = '1' * 32, '2' * 32, '3' * 64
PART_BYTES, TOTAL_XML_BYTES = 8 * 1024 * 1024, 32 * 1024 * 1024
PAYLOAD_BYTES, PAYLOAD_NODES, PART_LIMIT = 16 * 1024 * 1024, 524288, 4096


def sha(data):
    return hashlib.sha256(data).hexdigest()


def nodes(value):
    if type(value) is dict:
        return 1 + sum(nodes(child) for child in value.values())
    if type(value) is list:
        return 1 + sum(map(nodes, value))
    return 1


class PresentationStructureWireTest(unittest.TestCase):
    def api(self):
        functions = {name: getattr(MODULE, name, None)
            for name in ('write_structure_plan', 'read_structure_plan')}
        self.assertTrue(all(callable(value) for value in functions.values()),
            'BOOTSTRAP: detached structure-plan API absent; no transport/native acceptance evidence')
        return functions

    def plan(self):
        fixture = legacy_fixtures.PresentationStageWireTest(methodName='runTest')
        original, source_sha = fixture.actual_plan()
        part = original['source_order'][0]
        addition = {'alias': 'new-table', 'sourcePart': part, 'shapeId': '99',
            'positionEmu': {'x': 360000, 'y': 720000},
            'extentEmu': {'width': 2160000, 'height': 864000},
            'columnWidthsEmu': [720000, 720000, 720000], 'rowHeightsEmu': [432000, 432000],
            'cells': [{'row': row, 'column': column, 'rowSpan': 1, 'columnSpan': 1,
                'covered': False, 'anchor': None} for row in range(2) for column in range(3)]}
        expected_core = copy.deepcopy(original['expected_core'])
        expected_core[part + '#99'] = [''] * 6
        owners = []
        for owner in original['owner_ledger']:
            owners.append({'sourcePart': owner['sourcePart'], 'ordinal': owner['ordinal'],
                'metadata': copy.deepcopy(owner['metadata']), 'nonTableShapes': [],
                'keys': [key for key in original['expected_native'] if key.startswith(owner['sourcePart'] + '#')],
                'pairs': copy.deepcopy(owner['pairs']),
                'additions': [copy.deepcopy(addition)] if owner['sourcePart'] == part else []})
        return {'converted': [{'op': 'presentationTableAdd', 'alias': 'new-table', 'sourcePart': part}],
            'parts': original['parts'], 'expected_native': original['expected_native'],
            'expected_core': expected_core, 'source_order': original['source_order'],
            'owner_ledger': owners, 'additions': [addition], 'base_snapshot': original['draft']}, source_sha

    def write(self, directory, plan, source_sha, **changes):
        arguments = dict(job_token=JOB, phase_token=PHASE, request_sha256=REQUEST, source_sha256=source_sha)
        arguments.update(changes)
        return self.api()['write_structure_plan'](directory, plan, **arguments)

    def read(self, directory, envelope, source_sha, **changes):
        expected = dict(expected_job_token=JOB, expected_phase_token=PHASE,
            expected_request_sha256=REQUEST, expected_source_sha256=source_sha)
        expected.update(changes)
        return self.api()['read_structure_plan'](directory, envelope, **expected)

    def rewrite(self, directory, envelope, mutate=None, *, raw=None):
        value = json.loads((directory / 'plan.json').read_bytes())
        if mutate is not None:
            mutate(value)
        data = (json.dumps(value, ensure_ascii=False, separators=(',', ':'), allow_nan=True).encode('utf-8')
            if raw is None else raw)
        (directory / 'plan.json').write_bytes(data)
        try:
            decoded = json.loads(data)
        except json.JSONDecodeError:
            decoded = value
        envelope['payload'].update(byteLength=len(data), sha256=sha(data), nodeCount=nodes(decoded))
        return value

    def assert_exact(self, expected, actual):
        legacy_fixtures.PresentationStageWireTest(methodName='runTest').assert_exact(expected, actual)

    def covered(self, plan):
        return next(cell for table in plan['expected_native'].values()
            for cell in table['cells'] if cell['covered'])

    def pairs(self, plan):
        return next(owner['pairs'] for owner in plan['owner_ledger'] if owner['pairs'])

    def test_api_is_explicit(self):
        self.api()

    def test_actual_covered_records_and_new_plain_ledger_roundtrip_exactly(self):
        self.api()
        plan, source_sha = self.plan()
        probe = {'unknown': True, 'error': 'read_budget_exhausted', '_mapping': None,
            'values': [None, False, True, 0, -3, 0.0, -0.0, 1.25, '한글😀'],
            'objectTag': {'__type__': 'tuple', 'items': [0, 0]}, 'anchorCellId': 'ordinary-public-id'}
        plan['base_snapshot']['wireProbe'] = copy.deepcopy(probe)
        plan['owner_ledger'][0]['metadata']['wireProbe'] = copy.deepcopy(probe)
        plan['owner_ledger'][0]['extraPlainMetadata'] = copy.deepcopy(probe)
        before = copy.deepcopy(plan)
        with TemporaryDirectory() as temporary:
            directory = Path(temporary) / 'structure'
            envelope = self.write(directory, plan, source_sha)
            self.assertEqual(set(envelope), ENVELOPE_KEYS)
            self.assertEqual(envelope['schema'], 'piv.structure-plan/1')
            self.assertEqual((envelope['jobToken'], envelope['phaseToken'], envelope['requestSha256'],
                envelope['sourceSha256']), (JOB, PHASE, REQUEST, source_sha))
            self.assertEqual(set(envelope['payload']), PAYLOAD_KEYS)
            self.assertEqual(envelope['payload']['fileName'], 'plan.json')
            raw = (directory / 'plan.json').read_bytes()
            value = json.loads(raw)
            self.assertEqual(set(value), PLAN_KEYS)
            self.assertEqual(envelope['payload'], dict(fileName='plan.json', byteLength=len(raw),
                sha256=sha(raw), nodeCount=nodes(value)))
            for index, (name, data) in enumerate(plan['parts'].items()):
                record = value['parts'][index]
                self.assertEqual(set(record), PART_KEYS)
                self.assertEqual(record, dict(sourcePart=name, fileName='parts/p%06d.bin' % index,
                    byteLength=len(data), sha256=sha(data)))
                self.assertEqual((directory / record['fileName']).read_bytes(), data)
            loaded = self.read(directory, envelope, source_sha)
            self.assert_exact(plan, loaded)
            self.assertEqual(list(loaded['parts']), plan['source_order'])
            self.assertTrue(type(self.covered(loaded)['anchorCellId']) is tuple)
            self.assertTrue(type(self.pairs(loaded)[0]) is tuple)
            self.assert_exact(before, plan)

    def test_neither_wire_schema_falls_back_to_the_other(self):
        self.api()
        plan, source_sha = self.plan()
        legacy_plan, _ = legacy_fixtures.PresentationStageWireTest(methodName='runTest').actual_plan()
        with TemporaryDirectory() as temporary:
            old_directory, new_directory = Path(temporary) / 'legacy', Path(temporary) / 'structure'
            old = legacy_wire.write_source_plan(old_directory, legacy_plan, job_token=JOB,
                phase_token=PHASE, request_sha256=REQUEST, source_sha256=source_sha)
            with self.assertRaises(ValueError):
                self.read(old_directory, old, source_sha)
            new = self.write(new_directory, plan, source_sha)
            with self.assertRaises(ValueError):
                legacy_wire.read_source_plan(new_directory, new, expected_job_token=JOB,
                    expected_phase_token=PHASE, expected_request_sha256=REQUEST, expected_source_sha256=source_sha)

    def test_writer_rejects_wrong_plan_kind_and_missing_extra_or_legacy_fields(self):
        self.api()
        original, source_sha = self.plan()
        invalid = [[], None, {**original, 'draft': {}}, {**original, 'extra': None}]
        invalid.extend({key: value for key, value in original.items() if key != missing} for missing in original)
        for index, value in enumerate(invalid):
            with self.subTest(case=index), TemporaryDirectory() as temporary:
                directory = Path(temporary) / 'wire'
                with self.assertRaises((ValueError, TypeError)):
                    self.write(directory, value, source_sha)
                self.assertFalse(directory.exists())

    def test_writer_rejects_invalid_tokens_and_hashes_before_creating_directory(self):
        self.api()
        plan, source_sha = self.plan()
        cases = [('job_token', 'A' * 32), ('job_token', True), ('phase_token', '2' * 31),
            ('request_sha256', 'A' * 64), ('source_sha256', '0' * 63)]
        for field, value in cases:
            with self.subTest(field=field, value=value), TemporaryDirectory() as temporary:
                directory = Path(temporary) / 'wire'
                with self.assertRaises(ValueError):
                    self.write(directory, plan, source_sha, **{field: value})
                self.assertFalse(directory.exists())

    def test_reader_rejects_closed_envelope_payload_and_provenance_tampering(self):
        self.api()
        plan, source_sha = self.plan()
        cases = [('extra', lambda v: v.update(extra=1)), ('missing', lambda v: v.pop('phaseToken')),
            ('schema', lambda v: v.update(schema='piv.structure-plan/2')),
            ('legacy-schema', lambda v: v.update(schema='piv.source-plan/1')),
            ('payload-extra', lambda v: v['payload'].update(offset=0)),
            ('payload-missing', lambda v: v['payload'].pop('nodeCount')),
            ('payload-path', lambda v: v['payload'].update(fileName='../plan.json')),
            ('job-token', lambda v: v.update(jobToken='A' * 32)),
            ('phase-token', lambda v: v.update(phaseToken='2' * 31)),
            ('request-hash', lambda v: v.update(requestSha256='A' * 64)),
            ('source-hash', lambda v: v.update(sourceSha256='A' * 64)),
            ('length', lambda v: v['payload'].update(byteLength=v['payload']['byteLength'] + 1)),
            ('bool-length', lambda v: v['payload'].update(byteLength=True)),
            ('hash', lambda v: v['payload'].update(sha256='0' * 64)),
            ('nodes', lambda v: v['payload'].update(nodeCount=v['payload']['nodeCount'] + 1)),
            ('bool-nodes', lambda v: v['payload'].update(nodeCount=True))]
        for label, mutate in cases:
            with self.subTest(case=label), TemporaryDirectory() as temporary:
                directory = Path(temporary) / 'wire'
                envelope = self.write(directory, plan, source_sha)
                mutate(envelope)
                with self.assertRaises((ValueError, OSError)):
                    self.read(directory, envelope, source_sha)
        for field, value in [('expected_job_token', '4' * 32), ('expected_phase_token', '5' * 32),
                ('expected_request_sha256', '6' * 64), ('expected_source_sha256', '7' * 64)]:
            with self.subTest(case=field), TemporaryDirectory() as temporary:
                directory = Path(temporary) / 'wire'
                envelope = self.write(directory, plan, source_sha)
                with self.assertRaises(ValueError):
                    self.read(directory, envelope, source_sha, **{field: value})

    def test_reader_rejects_rehashed_duplicate_keys_wrong_plan_kind_and_nonfinite_json(self):
        self.api()
        plan, source_sha = self.plan()
        for label in ('duplicate-root', 'duplicate-nested', 'missing', 'extra', 'legacy-draft',
                'wrong-kind', 'nan', 'infinity', 'exponent-overflow', 'trailing-data'):
            with self.subTest(case=label), TemporaryDirectory() as temporary:
                directory = Path(temporary) / 'wire'
                envelope = self.write(directory, plan, source_sha)
                raw = (directory / 'plan.json').read_bytes()
                if label == 'duplicate-root':
                    self.rewrite(directory, envelope, raw=b'{"converted":[],' + raw[1:])
                elif label == 'duplicate-nested':
                    self.rewrite(directory, envelope, lambda v: v['base_snapshot'].update(probe={'k': 1}))
                    raw = (directory / 'plan.json').read_bytes().replace(b'"probe":{"k":1}', b'"probe":{"k":1,"k":2}')
                    self.rewrite(directory, envelope, raw=raw)
                elif label in ('nan', 'infinity'):
                    self.rewrite(directory, envelope, lambda v: v['base_snapshot'].update(
                        probe=float('nan') if label == 'nan' else float('inf')))
                elif label == 'exponent-overflow':
                    self.rewrite(directory, envelope, lambda v: v['base_snapshot'].update(probe=987654321))
                    raw = (directory / 'plan.json').read_bytes().replace(b'"probe":987654321', b'"probe":1e10000')
                    self.rewrite(directory, envelope, raw=raw)
                elif label == 'missing':
                    self.rewrite(directory, envelope, lambda v: v.pop('additions'))
                elif label == 'extra':
                    self.rewrite(directory, envelope, lambda v: v.update(extra={}))
                elif label == 'legacy-draft':
                    self.rewrite(directory, envelope, lambda v: v.update(draft=v.pop('base_snapshot')))
                elif label == 'wrong-kind':
                    self.rewrite(directory, envelope, raw=b'[]')
                else:
                    self.rewrite(directory, envelope, raw=raw + b'X')
                with self.assertRaises((ValueError, OSError)):
                    self.read(directory, envelope, source_sha)

    def test_writer_rejects_invalid_part_values_names_and_coverage_order(self):
        self.api()
        original, source_sha = self.plan()
        cases = [('parts-list', lambda v: v.update(parts=[])),
            ('mutable-bytes', lambda v: v['parts'].__setitem__(v['source_order'][0], bytearray(b'<p/>'))),
            ('string-part', lambda v: v['parts'].__setitem__(v['source_order'][0], '<p/>')),
            ('reversed-order', lambda v: v['source_order'].reverse()),
            ('duplicate-order', lambda v: v['source_order'].__setitem__(1, v['source_order'][0])),
            ('missing-order', lambda v: v['source_order'].pop())]
        for name in ('../slide.xml', '/slide.xml', 'C:/slide.xml', 'ppt//slide.xml',
                'ppt/./slide.xml', 'ppt/../slide.xml', 'ppt/slide.xml:ads', 'ppt/slides/'):
            cases.append(('name-' + name, lambda v, name=name: v.update(parts={name: b'<p/>'}, source_order=[name])))
        for label, mutate in cases:
            with self.subTest(case=label), TemporaryDirectory() as temporary:
                plan = copy.deepcopy(original)
                mutate(plan)
                directory = Path(temporary) / 'wire'
                with self.assertRaises((ValueError, TypeError)):
                    self.write(directory, plan, source_sha)
                self.assertFalse(directory.exists())

    def test_reader_rejects_part_alias_paths_offsets_and_rehashed_order_changes(self):
        self.api()
        plan, source_sha = self.plan()
        cases = [('record-order', lambda v: v['parts'].reverse()),
            ('source-order', lambda v: v['source_order'].reverse()),
            ('source-alias', lambda v: v['parts'][1].update(sourcePart=v['parts'][0]['sourcePart'])),
            ('artifact-alias', lambda v: v['parts'][1].update(fileName=v['parts'][0]['fileName'])),
            ('record-offset', lambda v: v['parts'][0].update(offset=0)),
            ('bool-size', lambda v: v['parts'][0].update(byteLength=True)),
            ('size', lambda v: v['parts'][0].update(byteLength=v['parts'][0]['byteLength'] + 1)),
            ('hash', lambda v: v['parts'][0].update(sha256='0' * 64))]
        for name in ('../foreign.bin', '/foreign.bin', 'C:/foreign.bin', r'parts\p000000.bin',
                'parts/p000000.bin:ads', 'parts/p000099.bin'):
            cases.append(('artifact-' + name, lambda v, name=name: v['parts'][0].update(fileName=name)))
        for name in ('../slide.xml', 'ppt//slide.xml', 'ppt/./slide.xml', 'ppt/slides/'):
            def change_name(value, name=name):
                value['parts'][0]['sourcePart'] = name
                value['source_order'][0] = name
            cases.append(('source-' + name, change_name))
        for label, mutate in cases:
            with self.subTest(case=label), TemporaryDirectory() as temporary:
                directory = Path(temporary) / 'wire'
                envelope = self.write(directory, plan, source_sha)
                self.rewrite(directory, envelope, mutate)
                with self.assertRaises((ValueError, OSError)):
                    self.read(directory, envelope, source_sha)

    def test_actual_part_tampering_missing_files_and_hardlink_alias_are_rejected(self):
        self.api()
        plan, source_sha = self.plan()
        for label in ('same-size', 'truncated', 'appended', 'missing', 'hardlink'):
            with self.subTest(case=label), TemporaryDirectory() as temporary:
                directory = Path(temporary) / 'wire'
                envelope = self.write(directory, plan, source_sha)
                target = directory / 'parts/p000000.bin'
                data = target.read_bytes()
                if label == 'same-size':
                    target.write_bytes(bytes([data[0] ^ 1]) + data[1:])
                elif label == 'truncated':
                    target.write_bytes(data[:-1])
                elif label == 'appended':
                    target.write_bytes(data + b'X')
                elif label == 'missing':
                    target.unlink()
                else:
                    alias = Path(temporary) / 'foreign-part-alias.bin'
                    os.link(target, alias)
                    self.assertEqual(target.stat().st_ino, alias.stat().st_ino)
                    self.assertEqual(alias.read_bytes(), data)
                with self.assertRaises((ValueError, OSError)):
                    self.read(directory, envelope, source_sha)
                if label == 'hardlink':
                    self.assertEqual(alias.read_bytes(), data)

    def test_only_native_anchor_and_owner_pair_positions_accept_tuples(self):
        self.api()
        original, source_sha = self.plan()
        cases = [('anchor-list', lambda v: self.covered(v).update(anchorCellId=[0, 0])),
            ('anchor-short', lambda v: self.covered(v).update(anchorCellId=(0,))),
            ('anchor-bool', lambda v: self.covered(v).update(anchorCellId=(False, 0))),
            ('owner-pair-list', lambda v: self.pairs(v).__setitem__(0, list(self.pairs(v)[0]))),
            ('owner-pair-short', lambda v: self.pairs(v).__setitem__(0, (self.pairs(v)[0][0],))),
            ('tuple-elsewhere', lambda v: v['base_snapshot'].update(probe=(0, 0))),
            ('tuple-addition', lambda v: v['additions'][0].update(probe=(0, 0))),
            ('bytes-elsewhere', lambda v: v['base_snapshot'].update(probe=b'not-part-bytes')),
            ('object-elsewhere', lambda v: v['base_snapshot'].update(probe=object())),
            ('nan', lambda v: v['base_snapshot'].update(probe=float('nan'))),
            ('infinity', lambda v: v['base_snapshot'].update(probe=float('inf'))),
            ('non-string-key', lambda v: v['base_snapshot'].update({1: 'invalid-key'}))]
        for label, mutate in cases:
            with self.subTest(case=label), TemporaryDirectory() as temporary:
                plan = copy.deepcopy(original)
                mutate(plan)
                with self.assertRaises((ValueError, TypeError)):
                    self.write(Path(temporary) / 'wire', plan, source_sha)
        reader_cases = [('anchor-short', lambda v: self.covered(v).update(anchorCellId=[0])),
            ('anchor-bool', lambda v: self.covered(v).update(anchorCellId=[False, 0])),
            ('anchor-object-tag', lambda v: self.covered(v).update(anchorCellId={'__type__': 'tuple', 'items': [0, 0]})),
            ('owner-pair-short', lambda v: self.pairs(v).__setitem__(0, [self.pairs(v)[0][0]])),
            ('owner-pair-object-tag', lambda v: self.pairs(v).__setitem__(0, {'__type__': 'tuple', 'items': []}))]
        for label, mutate in reader_cases:
            with self.subTest(case=label), TemporaryDirectory() as temporary:
                directory = Path(temporary) / 'wire'
                envelope = self.write(directory, original, source_sha)
                self.rewrite(directory, envelope, mutate)
                with self.assertRaises(ValueError):
                    self.read(directory, envelope, source_sha)

    def test_payload_byte_and_node_budgets_reject_writer_and_reader(self):
        self.api()
        original, source_sha = self.plan()
        for label in ('bytes', 'nodes'):
            plan = copy.deepcopy(original)
            plan['base_snapshot']['probe'] = 'X' * PAYLOAD_BYTES if label == 'bytes' else [None] * PAYLOAD_NODES
            with self.subTest(writer=label), TemporaryDirectory() as temporary:
                directory = Path(temporary) / 'wire'
                with self.assertRaises(ValueError):
                    self.write(directory, plan, source_sha)
                self.assertFalse(directory.exists())
            with self.subTest(reader=label), TemporaryDirectory() as temporary:
                directory = Path(temporary) / 'wire'
                envelope = self.write(directory, original, source_sha)
                self.rewrite(directory, envelope, lambda v: v['base_snapshot'].update(
                    probe='X' * PAYLOAD_BYTES if label == 'bytes' else [None] * PAYLOAD_NODES))
                with self.assertRaises(ValueError):
                    self.read(directory, envelope, source_sha)

    def test_xml_and_part_count_limits_reject_before_writer_creates_artifacts(self):
        self.api()
        original, source_sha = self.plan()
        cases = [('component', {'one.xml': b'X' * (PART_BYTES + 1)}),
            ('aggregate', {'part%d.xml' % i: b'X' * PART_BYTES for i in range(5)}),
            ('count', {'part%d.xml' % i: b'<p/>' for i in range(PART_LIMIT + 1)})]
        for label, parts in cases:
            with self.subTest(case=label), TemporaryDirectory() as temporary:
                plan = copy.deepcopy(original)
                plan['parts'], plan['source_order'] = parts, list(parts)
                directory = Path(temporary) / 'wire'
                with self.assertRaises(ValueError):
                    self.write(directory, plan, source_sha)
                self.assertFalse(directory.exists())

    def test_rehashed_declared_xml_and_part_count_limits_are_rejected_by_reader(self):
        self.api()
        original, source_sha = self.plan()
        for label, length, count in [('component', PART_BYTES + 1, 1),
                ('aggregate', PART_BYTES, 5), ('count', 0, PART_LIMIT + 1)]:
            with self.subTest(case=label), TemporaryDirectory() as temporary:
                directory = Path(temporary) / 'wire'
                envelope = self.write(directory, original, source_sha)
                records = [dict(sourcePart='part%d.xml' % i, fileName='parts/p%06d.bin' % i,
                    byteLength=length, sha256=sha(b'')) for i in range(count)]
                self.rewrite(directory, envelope, lambda v: v.update(parts=records,
                    source_order=[record['sourcePart'] for record in records]))
                with self.assertRaises(ValueError):
                    self.read(directory, envelope, source_sha)

    def test_existing_foreign_directory_is_preserved(self):
        self.api()
        plan, source_sha = self.plan()
        with TemporaryDirectory() as temporary:
            directory = Path(temporary) / 'foreign'
            directory.mkdir()
            sentinel = directory / 'foreign.bin'
            sentinel.write_bytes(b'FOREIGN MUST SURVIVE')
            with self.assertRaises((ValueError, OSError)):
                self.write(directory, plan, source_sha)
            self.assertEqual(list(directory.iterdir()), [sentinel])
            self.assertEqual(sentinel.read_bytes(), b'FOREIGN MUST SURVIVE')


if __name__ == '__main__':
    unittest.main()
