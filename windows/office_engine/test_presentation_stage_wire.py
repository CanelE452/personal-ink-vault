"""Data-only source-plan wire contract; root alone executes this suite.

The real worker fixture captures the actual covered-cell product plan. Large
metadata cases exercise the codec format, not native document acceptance.
"""
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
from unittest.mock import patch

import office_presentation_source_edit as source_edit
import test_presentation_source_edit as source_fixtures
import test_worker_source_text_edit as worker_fixtures


MODULE = (importlib.import_module('office_presentation_stage_wire')
    if importlib.util.find_spec('office_presentation_stage_wire') is not None
    else SimpleNamespace(write_source_plan=None, read_source_plan=None))
PLAN_KEYS = {'converted', 'parts', 'expected_native', 'expected_core', 'draft',
    'source_order', 'owner_ledger'}
ENVELOPE_KEYS = {'schema', 'jobToken', 'phaseToken', 'requestSha256', 'sourceSha256', 'payload'}
PAYLOAD_KEYS = {'fileName', 'byteLength', 'sha256', 'nodeCount'}
PART_KEYS = {'sourcePart', 'fileName', 'byteLength', 'sha256'}
PART_BYTES, TOTAL_XML_BYTES = 8 * 1024 * 1024, 32 * 1024 * 1024
JOB, PHASE, REQUEST = '1' * 32, '2' * 32, '3' * 64


def sha(data):
    return hashlib.sha256(data).hexdigest()


def json_nodes(value):
    """Wire nodes count containers/values per position, without object keys."""
    if type(value) is dict:
        return 1 + sum(json_nodes(child) for child in value.values())
    if type(value) is list:
        return 1 + sum(map(json_nodes, value))
    return 1


class PresentationStageWireTest(unittest.TestCase):
    _captured = None

    def api(self):
        functions = {name: getattr(MODULE, name, None)
            for name in ('write_source_plan', 'read_source_plan')}
        self.assertTrue(all(callable(value) for value in functions.values()),
            'BOOTSTRAP: source-plan wire API missing; this is not codec or native behavior evidence')
        return functions

    def actual_plan(self):
        if type(self)._captured is None:
            observed = []
            original_plan, original_table_xml = source_edit.plan_source_text_edit, source_fixtures.table_xml
            fixture = worker_fixtures.WorkerSourceTextEditTest(methodName='runTest')

            def merged_table_xml(rows):
                rows = copy.deepcopy(rows)
                rows[0][0] = rows[0][0].replace(b'<a:tc>', b'<a:tc gridSpan="2">', 1)
                rows[0][1] = rows[0][1].replace(b'<a:tc>', b'<a:tc hMerge="1">', 1)
                return original_table_xml(rows)

            def capture(*arguments, **keywords):
                result = original_plan(*arguments, **keywords)
                observed.append(copy.deepcopy(result))
                return result

            with patch.object(source_fixtures, 'table_xml', new=merged_table_xml), \
                    patch.object(source_edit, 'plan_source_text_edit', new=capture):
                state = fixture.run_case()
            self.assertIsNone(state.caught, 'Actual public worker control must succeed before using its plan')
            self.assertEqual(len(observed), 1)
            plan = observed[0]
            self.assertEqual(set(plan), PLAN_KEYS)
            self.assertEqual(list(plan['parts']), plan['source_order'])
            self.assertEqual(plan['source_order'], ['ppt/slides/slide2.xml',
                'ppt/slides/slide1.xml', 'ppt/slides/slide3.xml'])
            anchors = [cell['anchorCellId'] for table in plan['expected_native'].values()
                for cell in table['cells'] if cell['covered']]
            self.assertEqual(len(anchors), 4, 'The actual source package must retain four merged covered cells')
            self.assertTrue(all(type(anchor) is tuple and anchor == (0, 0) for anchor in anchors))
            self.assertEqual(plan['parts'], state.candidate_catalog['parts'])
            type(self)._captured = plan, state.original_hash
        plan, source_sha = type(self)._captured
        return copy.deepcopy(plan), source_sha

    def write(self, directory, plan, source_sha):
        return self.api()['write_source_plan'](directory, plan, job_token=JOB, phase_token=PHASE,
            request_sha256=REQUEST, source_sha256=source_sha)

    def read(self, directory, envelope, source_sha, **changes):
        expected = dict(expected_job_token=JOB, expected_phase_token=PHASE,
            expected_request_sha256=REQUEST, expected_source_sha256=source_sha)
        expected.update(changes)
        return self.api()['read_source_plan'](directory, envelope, **expected)

    def assert_exact(self, expected, actual, location='plan'):
        self.assertIs(type(actual), type(expected), location + ' must retain its exact Python type')
        if type(expected) is dict:
            self.assertEqual(set(actual), set(expected), location)
            for key, value in expected.items():
                self.assert_exact(value, actual[key], location + '.' + key)
        elif type(expected) in (tuple, list):
            self.assertEqual(len(actual), len(expected), location)
            for index, (one, two) in enumerate(zip(expected, actual)):
                self.assert_exact(one, two, location + '[' + str(index) + ']')
        else:
            self.assertEqual(actual, expected, location)
            if type(expected) is float and expected == 0:
                self.assertEqual(str(actual), str(expected), location + ' signed float zero')

    def payload(self, directory):
        return json.loads((directory / 'plan.json').read_text(encoding='utf-8'))

    def rewrite(self, directory, envelope, mutate=None, *, raw=None):
        """Rehash structural tampering so read must reach its domain validator."""
        value = self.payload(directory)
        if mutate is not None:
            mutate(value)
        data = (json.dumps(value, ensure_ascii=False, separators=(',', ':'), allow_nan=True).encode('utf-8')
            if raw is None else raw)
        (directory / 'plan.json').write_bytes(data)
        envelope['payload'].update(byteLength=len(data), sha256=sha(data),
            nodeCount=json_nodes(value if raw is None else json.loads(data)))
        return value

    def covered(self, value):
        return next(cell for table in value['expected_native'].values()
            for cell in table['cells'] if cell['covered'])

    def owner_pair(self, value):
        return next(owner['pairs'] for owner in value['owner_ledger'] if owner['pairs'])

    def test_actual_covered_plan_roundtrip_preserves_types_bytes_order_and_exclusive_directory(self):
        self.api()
        plan, source_sha = self.actual_plan()
        probe = {'unknown': True, 'error': 'read_budget_exhausted', '_budget': None,
            'values': [None, False, True, 0, 1, -3, 0.0, -0.0, 1.25, '한글😀'],
            'objectTag': {'__type__': 'tuple', 'items': [0, 0]}, 'anchorCellId': 'public-cell-id'}
        plan['draft']['wireProbe'] = copy.deepcopy(probe)
        plan['owner_ledger'][0]['metadata']['wireProbe'] = copy.deepcopy(probe)
        with TemporaryDirectory() as temporary:
            base = Path(temporary)
            directory = base / 'wire'
            envelope = self.write(directory, plan, source_sha)
            self.assertEqual(set(envelope), ENVELOPE_KEYS)
            self.assertEqual(envelope['schema'], 'piv.source-plan/1')
            self.assertEqual((envelope['jobToken'], envelope['phaseToken'], envelope['requestSha256'],
                envelope['sourceSha256']), (JOB, PHASE, REQUEST, source_sha))
            self.assertEqual(set(envelope['payload']), PAYLOAD_KEYS)
            self.assertEqual(envelope['payload']['fileName'], 'plan.json')
            raw = (directory / 'plan.json').read_bytes()
            payload = json.loads(raw)
            self.assertEqual(set(payload), PLAN_KEYS)
            self.assertEqual(envelope['payload']['byteLength'], len(raw))
            self.assertEqual(envelope['payload']['sha256'], sha(raw))
            self.assertEqual(envelope['payload']['nodeCount'], json_nodes(payload))
            self.assertIs(type(envelope['payload']['byteLength']), int)
            self.assertIs(type(envelope['payload']['nodeCount']), int)
            self.assertIs(type(payload['parts']), list)
            self.assertEqual([record['sourcePart'] for record in payload['parts']], plan['source_order'])
            for index, (source_part, part_bytes) in enumerate(plan['parts'].items()):
                record = payload['parts'][index]
                self.assertEqual(set(record), PART_KEYS)
                self.assertEqual(record, dict(sourcePart=source_part,
                    fileName='parts/p%06d.bin' % index, byteLength=len(part_bytes), sha256=sha(part_bytes)))
                self.assertEqual((directory / record['fileName']).read_bytes(), part_bytes)
            self.assertIs(type(self.covered(payload)['anchorCellId']), list)
            self.assertIs(type(self.owner_pair(payload)[0]), list)
            self.assert_exact(plan, self.read(directory, envelope, source_sha))
            self.assertEqual(list(self.read(directory, envelope, source_sha)['parts']), plan['source_order'])
            existing = base / 'existing'
            existing.mkdir()
            sentinel = existing / 'foreign-sentinel'
            sentinel.write_bytes(b'FOREIGN-DO-NOT-CHANGE')
            with self.assertRaises((ValueError, OSError)):
                self.write(existing, plan, source_sha)
            self.assertEqual(sentinel.read_bytes(), b'FOREIGN-DO-NOT-CHANGE')
            self.assertEqual(list(existing.iterdir()), [sentinel])

    def test_writer_rejects_real_directory_substitution_after_mkdir_without_touching_foreign_files(self):
        self.api()
        plan, source_sha = self.actual_plan()
        original_mkdir = Path.mkdir
        for kind in ('root', 'parts'):
            with self.subTest(directory=kind), TemporaryDirectory() as temporary:
                base = Path(temporary).resolve()
                directory = base / 'wire'
                target = directory if kind == 'root' else directory / 'parts'
                moved = base / ('created-' + kind + '-renamed-away')
                foreign = base / ('foreign-' + kind)
                foreign.mkdir()
                (foreign / 'foreign-sentinel').write_bytes(b'FOREIGN-DO-NOT-CHANGE')
                (foreign / 'nested').mkdir()
                (foreign / 'nested/foreign-bytes').write_bytes(b'OTHER-FOREIGN-\x00\xff')
                before = {entry.relative_to(foreign).as_posix():
                    None if entry.is_dir() else entry.read_bytes() for entry in foreign.rglob('*')}
                state = dict(boundaries=0, swapCompleted=False, blockedAt=None,
                    renameError=None, writerError=None, writerReturned=False, unleasedRenameControl=False)

                def owned(*paths):
                    for candidate in paths:
                        resolved = candidate.resolve()
                        self.assertNotEqual(resolved, base)
                        resolved.relative_to(base)
                        self.assertEqual(resolved, Path(os.path.abspath(candidate)),
                            'This regression may move only ordinary paths inside its own TemporaryDirectory')

                control_fresh = base / ('unleased-' + kind + '-fresh')
                control_foreign = base / ('unleased-' + kind + '-foreign')
                control_moved = base / ('unleased-' + kind + '-renamed-away')
                control_fresh.mkdir()
                control_foreign.mkdir()
                (control_foreign / 'foreign-sentinel').write_bytes(b'UNLEASED-FOREIGN-UNCHANGED')
                control_identity = control_fresh.stat().st_dev, control_fresh.stat().st_ino
                owned(control_fresh, control_moved, control_foreign)
                self.assertFalse(control_moved.exists())
                control_fresh.rename(control_moved)
                self.assertFalse(control_fresh.exists())
                self.assertEqual((control_moved.stat().st_dev, control_moved.stat().st_ino), control_identity)
                owned(control_foreign, control_fresh)
                control_foreign.rename(control_fresh)
                self.assertFalse(control_foreign.exists())
                self.assertEqual(list(control_moved.iterdir()), [])
                self.assertEqual({entry.name: entry.read_bytes() for entry in control_fresh.iterdir()},
                    {'foreign-sentinel': b'UNLEASED-FOREIGN-UNCHANGED'})
                state['unleasedRenameControl'] = True

                def blocked(error, phase):
                    self.assertEqual(os.name, 'nt', 'Unexpected filesystem rename failure is not lock evidence')
                    self.assertIn(getattr(error, 'winerror', None), (5, 32),
                        'Only actual Windows access/share denial can establish a blocked rename')
                    state.update(blockedAt=phase, renameError=dict(type=type(error).__name__,
                        winerror=error.winerror, errno=error.errno))

                def mkdir(candidate, *arguments, **keywords):
                    result = original_mkdir(candidate, *arguments, **keywords)
                    if Path(os.path.abspath(candidate)) != target:
                        return result
                    state['boundaries'] += 1
                    self.assertEqual(state['boundaries'], 1)
                    created_identity = target.stat().st_dev, target.stat().st_ino
                    owned(target, moved, foreign)
                    self.assertFalse(moved.exists())
                    try:
                        target.rename(moved)
                    except OSError as error:
                        blocked(error, 'move-created-away')
                        self.assertEqual((target.stat().st_dev, target.stat().st_ino), created_identity)
                        self.assertFalse(moved.exists())
                        return result
                    owned(foreign, target)
                    self.assertFalse(target.exists())
                    try:
                        foreign.rename(target)
                    except OSError as error:
                        blocked(error, 'move-foreign-into-place')
                        owned(moved, target)
                        self.assertFalse(target.exists())
                        moved.rename(target)
                        self.assertEqual((target.stat().st_dev, target.stat().st_ino), created_identity)
                        return result
                    state['swapCompleted'] = True
                    self.assertFalse(foreign.exists())
                    self.assertEqual((target / 'foreign-sentinel').read_bytes(), b'FOREIGN-DO-NOT-CHANGE')
                    return result

                envelope = None
                try:
                    with patch.object(Path, 'mkdir', new=mkdir):
                        try:
                            envelope = self.write(directory, plan, source_sha)
                            state['writerReturned'] = True
                        except (ValueError, OSError) as error:
                            state['writerError'] = dict(type=type(error).__name__,
                                winerror=getattr(error, 'winerror', None), errno=getattr(error, 'errno', None))
                    self.assertEqual(state['boundaries'], 1, 'The actual writer must reach the real mkdir boundary')
                    observed_foreign = target if state['swapCompleted'] else foreign
                    after = {entry.relative_to(observed_foreign).as_posix():
                        None if entry.is_dir() else entry.read_bytes() for entry in observed_foreign.rglob('*')}
                    state['foreignEntriesAfter'] = sorted(after)
                    self.assertEqual(set(after), set(before),
                        'A substituted preexisting foreign directory must not receive source-plan artifacts')
                    for name, data in before.items():
                        self.assertEqual(after[name], data, 'Foreign file bytes changed: ' + name)
                    if state['swapCompleted']:
                        self.assertIsNotNone(state['writerError'],
                            'The writer must reject an ordinary foreign directory substituted after its mkdir')
                        self.assertFalse(state['writerReturned'])
                    else:
                        self.assertIsNotNone(state['blockedAt'], 'No swap is evidence only when the real rename was denied')
                        self.assertIsNone(state['writerError'])
                        self.assertTrue(state['writerReturned'])
                        self.assert_exact(plan, self.read(directory, envelope, source_sha))
                finally:
                    print('SOURCE_PLAN_REAL_DIRECTORY_SWAP ' + json.dumps(dict(directory=kind, **state),
                        sort_keys=True), flush=True)

    def test_closed_envelope_tokens_json_duplicates_and_integrity_witnesses_reject(self):
        self.api()
        plan, source_sha = self.actual_plan()
        envelope_cases = [
            ('extra-envelope-key', lambda value: value.update(extra=1)),
            ('missing-envelope-key', lambda value: value.pop('jobToken')),
            ('wrong-schema', lambda value: value.update(schema='piv.source-plan/2')),
            ('extra-payload-key', lambda value: value['payload'].update(extra=1)),
            ('missing-payload-key', lambda value: value['payload'].pop('nodeCount')),
            ('payload-path-escape', lambda value: value['payload'].update(fileName='../plan.json')),
            ('bad-job-token', lambda value: value.update(jobToken='A' * 32)),
            ('bad-phase-token', lambda value: value.update(phaseToken='2' * 31)),
            ('uppercase-request-sha', lambda value: value.update(requestSha256='A' * 64)),
            ('uppercase-source-sha', lambda value: value.update(sourceSha256='B' * 64)),
            ('wrong-byte-length', lambda value: value['payload'].update(byteLength=value['payload']['byteLength'] + 1)),
            ('boolean-byte-length', lambda value: value['payload'].update(byteLength=True)),
            ('wrong-sha', lambda value: value['payload'].update(sha256='0' * 64)),
            ('wrong-node-count', lambda value: value['payload'].update(nodeCount=value['payload']['nodeCount'] + 1)),
            ('boolean-node-count', lambda value: value['payload'].update(nodeCount=True)),
        ]
        for label, mutate in envelope_cases:
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
        for label in ('duplicate-root-key', 'duplicate-nested-key', 'nan', 'trailing-data', 'missing-plan-key', 'extra-plan-key'):
            with self.subTest(case=label), TemporaryDirectory() as temporary:
                directory = Path(temporary) / 'wire'
                envelope = self.write(directory, plan, source_sha)
                raw = (directory / 'plan.json').read_bytes()
                if label == 'duplicate-root-key':
                    self.rewrite(directory, envelope, raw=b'{"converted":[],' + raw[1:])
                elif label == 'duplicate-nested-key':
                    self.rewrite(directory, envelope, lambda value: value['draft'].update(wireProbe={'k': 1}))
                    raw = (directory / 'plan.json').read_bytes().replace(b'"wireProbe":{"k":1}', b'"wireProbe":{"k":1,"k":2}')
                    self.rewrite(directory, envelope, raw=raw)
                elif label == 'nan':
                    self.rewrite(directory, envelope, lambda value: value['draft'].update(wireProbe=float('nan')))
                elif label == 'trailing-data':
                    (directory / 'plan.json').write_bytes(raw + b'X')
                else:
                    self.rewrite(directory, envelope, (lambda value: value.pop('draft'))
                        if label == 'missing-plan-key' else (lambda value: value.update(extra={})))
                with self.assertRaises((ValueError, OSError)):
                    self.read(directory, envelope, source_sha)

    def test_parts_order_duplicate_paths_reparse_size_hash_and_eof_reject(self):
        self.api()
        plan, source_sha = self.actual_plan()
        cases = [
            ('record-order', lambda value: value['parts'].reverse()),
            ('source-order', lambda value: value['source_order'].reverse()),
            ('duplicate-source-part', lambda value: value['parts'][1].update(sourcePart=value['parts'][0]['sourcePart'])),
            ('duplicate-source-order', lambda value: value['source_order'].__setitem__(1, value['source_order'][0])),
            ('missing-source-order', lambda value: value['source_order'].pop()),
            ('duplicate-artifact', lambda value: value['parts'][1].update(fileName=value['parts'][0]['fileName'])),
            ('record-extra-key', lambda value: value['parts'][0].update(extra=1)),
            ('boolean-part-size', lambda value: value['parts'][0].update(byteLength=True)),
            ('declared-part-size', lambda value: value['parts'][0].update(byteLength=value['parts'][0]['byteLength'] + 1)),
            ('declared-part-hash', lambda value: value['parts'][0].update(sha256='0' * 64)),
        ]
        cases.extend(('artifact-path-' + str(index), lambda value, name=name:
            value['parts'][0].update(fileName=name)) for index, name in enumerate(
                ['../foreign.bin', '/foreign.bin', 'C:/foreign.bin', r'parts\p000000.bin',
                    'parts/p000000.bin:alternate', 'ppt/slides/slide2.xml', 'parts/p000099.bin']))
        for label, mutate in cases:
            with self.subTest(case=label), TemporaryDirectory() as temporary:
                directory = Path(temporary) / 'wire'
                envelope = self.write(directory, plan, source_sha)
                self.rewrite(directory, envelope, mutate)
                with self.assertRaises((ValueError, OSError)):
                    self.read(directory, envelope, source_sha)
        for label in ('same-size-corruption', 'appended-eof', 'truncated', 'missing'):
            with self.subTest(case=label), TemporaryDirectory() as temporary:
                directory = Path(temporary) / 'wire'
                envelope = self.write(directory, plan, source_sha)
                target = directory / 'parts/p000000.bin'
                data = target.read_bytes()
                if label == 'same-size-corruption':
                    target.write_bytes(bytes([data[0] ^ 1]) + data[1:])
                elif label == 'appended-eof':
                    target.write_bytes(data + b'X')
                elif label == 'truncated':
                    target.write_bytes(data[:-1])
                else:
                    target.unlink()
                with self.assertRaises((ValueError, OSError)):
                    self.read(directory, envelope, source_sha)
        with self.subTest(case='actual-owned-junction-escape'), TemporaryDirectory() as temporary:
            base = Path(temporary).resolve()
            directory = base / 'wire'
            envelope = self.write(directory, plan, source_sha)
            parts, foreign = directory / 'parts', base / 'foreign-sibling'
            self.assertEqual(parts.resolve().relative_to(base), Path('wire/parts'))
            self.assertEqual(foreign.resolve().relative_to(base), Path('foreign-sibling'))
            self.assertFalse(foreign.exists())
            parts.rename(foreign)
            sentinel = foreign / 'foreign-sentinel'
            sentinel.write_bytes(b'PRESERVE-FOREIGN')
            before = {item.name: item.read_bytes() for item in foreign.iterdir()}
            linked = False
            try:
                if os.name == 'nt':
                    import _winapi
                    _winapi.CreateJunction(str(foreign), str(parts))
                else:
                    os.symlink(foreign, parts, target_is_directory=True)
                linked = True
                with self.assertRaises((ValueError, OSError)):
                    self.read(directory, envelope, source_sha)
                self.assertEqual({item.name: item.read_bytes() for item in foreign.iterdir()}, before)
            finally:
                if linked:
                    if os.name == 'nt':
                        os.rmdir(parts)
                    else:
                        parts.unlink()
            self.assertEqual(sentinel.read_bytes(), b'PRESERVE-FOREIGN')
            self.assertEqual({item.name: item.read_bytes() for item in foreign.iterdir()}, before)

    def test_only_native_anchors_and_owner_pairs_allow_special_types(self):
        self.api()
        plan, source_sha = self.actual_plan()
        writer_cases = [
            ('anchor-list', lambda value: self.covered(value).update(anchorCellId=[0, 0])),
            ('anchor-short', lambda value: self.covered(value).update(anchorCellId=(0,))),
            ('anchor-long', lambda value: self.covered(value).update(anchorCellId=(0, 0, 0))),
            ('anchor-bool', lambda value: self.covered(value).update(anchorCellId=(False, 0))),
            ('anchor-float', lambda value: self.covered(value).update(anchorCellId=(0.0, 0))),
            ('anchor-string', lambda value: self.covered(value).update(anchorCellId='public-cell-id')),
            ('owner-pair-list', lambda value: self.owner_pair(value).__setitem__(0, list(self.owner_pair(value)[0]))),
            ('owner-pair-short', lambda value: self.owner_pair(value).__setitem__(0, (self.owner_pair(value)[0][0],))),
            ('owner-pair-long', lambda value: self.owner_pair(value).__setitem__(0, (*self.owner_pair(value)[0], None))),
            ('tuple-elsewhere', lambda value: value['draft'].update(wireProbe=(1, 2))),
            ('bytes-elsewhere', lambda value: value['draft'].update(wireProbe=b'not-an-XML-part')),
            ('object-elsewhere', lambda value: value['draft'].update(wireProbe=object())),
            ('nan-elsewhere', lambda value: value['draft'].update(wireProbe=float('nan'))),
            ('infinity-elsewhere', lambda value: value['draft'].update(wireProbe=float('inf'))),
            ('non-string-key', lambda value: value['draft'].update({1: 'invalid-key'})),
            ('tuple-in-owner-metadata', lambda value: value['owner_ledger'][0]['metadata'].update(anchorCellId=(0, 0))),
        ]
        for label, mutate in writer_cases:
            with self.subTest(writer=label), TemporaryDirectory() as temporary:
                invalid = copy.deepcopy(plan)
                mutate(invalid)
                with self.assertRaises((ValueError, TypeError)):
                    self.write(Path(temporary) / 'wire', invalid, source_sha)
        reader_cases = [
            ('anchor-short', lambda value: self.covered(value).update(anchorCellId=[0])),
            ('anchor-long', lambda value: self.covered(value).update(anchorCellId=[0, 0, 0])),
            ('anchor-bool', lambda value: self.covered(value).update(anchorCellId=[False, 0])),
            ('anchor-float', lambda value: self.covered(value).update(anchorCellId=[0.0, 0])),
            ('anchor-object-tag', lambda value: self.covered(value).update(anchorCellId={'__type__': 'tuple', 'items': [0, 0]})),
            ('owner-anchor-bool', lambda value: next(cell for cell in self.owner_pair(value)[0][0]['cells']
                if cell['covered']).update(anchorCellId=[0, True])),
            ('owner-pair-short', lambda value: self.owner_pair(value).__setitem__(0, [self.owner_pair(value)[0][0]])),
            ('owner-pair-long', lambda value: self.owner_pair(value)[0].append(None)),
            ('owner-pair-object-tag', lambda value: self.owner_pair(value).__setitem__(0, {'__type__': 'tuple', 'items': []})),
        ]
        for label, mutate in reader_cases:
            with self.subTest(reader=label), TemporaryDirectory() as temporary:
                directory = Path(temporary) / 'wire'
                envelope = self.write(directory, plan, source_sha)
                self.rewrite(directory, envelope, mutate)
                with self.assertRaises(ValueError):
                    self.read(directory, envelope, source_sha)
        plan['draft']['anchorCellId'] = 'public-cell-id'
        plan['owner_ledger'][0]['metadata']['anchorCellId'] = None
        plan['draft']['objectTag'] = {'__type__': 'bytes', 'data': 'not-decoded'}
        with TemporaryDirectory() as temporary:
            directory = Path(temporary) / 'wire'
            envelope = self.write(directory, plan, source_sha)
            self.assert_exact(plan, self.read(directory, envelope, source_sha))

    def test_large_json_metadata_roundtrips_without_new_global_cap_and_xml_limits_remain(self):
        self.api()
        plan, source_sha = self.actual_plan()
        plan['draft']['wireLargeMetadata'] = {'text': '한' * (3 * 1024 * 1024),
            'values': [None] * 131073, 'unknown': True, 'error': 'read_budget_exhausted',
            '_budget': {'truncated': True}, '_mapping': None}
        with TemporaryDirectory() as temporary:
            directory = Path(temporary) / 'wire'
            envelope = self.write(directory, plan, source_sha)
            self.assertGreater(envelope['payload']['byteLength'], 8 * 1024 * 1024)
            self.assertGreater(envelope['payload']['nodeCount'], 131072)
            self.assert_exact(plan, self.read(directory, envelope, source_sha))
        original, source_sha = self.actual_plan()
        for label, parts in [('per-part', {'one.xml': b'X' * (PART_BYTES + 1)}),
                ('total-xml', {'part%d.xml' % index: b'X' * PART_BYTES for index in range(5)})]:
            with self.subTest(writer=label), TemporaryDirectory() as temporary:
                invalid = copy.deepcopy(original)
                invalid['parts'], invalid['source_order'] = parts, list(parts)
                self.assertTrue(label == 'per-part' or sum(map(len, parts.values())) > TOTAL_XML_BYTES)
                with self.assertRaises((ValueError, TypeError)):
                    self.write(Path(temporary) / 'wire', invalid, source_sha)
        for label in ('per-part', 'total-xml'):
            with self.subTest(reader=label), TemporaryDirectory() as temporary:
                directory = Path(temporary) / 'wire'
                envelope = self.write(directory, original, source_sha)
                data = b'X' * (PART_BYTES + 1 if label == 'per-part' else PART_BYTES)
                count = 1 if label == 'per-part' else 5
                records = []
                for index in range(count):
                    name = 'parts/p%06d.bin' % index
                    (directory / name).write_bytes(data)
                    records.append(dict(sourcePart='part%d.xml' % index, fileName=name,
                        byteLength=len(data), sha256=sha(data)))
                self.rewrite(directory, envelope, lambda value: value.update(parts=records,
                    source_order=[record['sourcePart'] for record in records]))
                with self.assertRaises(ValueError):
                    self.read(directory, envelope, source_sha)


if __name__ == '__main__':
    unittest.main()
