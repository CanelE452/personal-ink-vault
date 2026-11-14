"""Independent source structure authority and add-plan lifecycle contracts.

Root alone executes. These tests use real source bytes, writer and exact private
binding with small native-interface doubles; they do not establish native gates.
"""
from contextlib import contextmanager, nullcontext
import copy
import hashlib
import importlib
import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from office_presentation import Presentation
from office_presentation_binding import prepare_pptx_binding
import office_presentation_source as source_reader
import office_presentation_source_edit as text_edit
import office_presentation_structure as structure
import office_presentation_tables as table_module
import office_worker as worker
import test_presentation_binding as binding_fixtures
from test_presentation_source import frame_xml, package_members, slide_xml, write_package, SLIDE
from test_presentation_source_edit import prepare_native_document
from test_presentation_structure import grid_frame
from test_worker_presentation_binding import write_is_blocked


EXPORTS = ('validate_batch', 'source_authority', 'plan_source_structure_edit',
    'render_source_structure_candidate', 'observe_source_structure_candidate', 'apply_source_structure_edit')
MODULE = (importlib.import_module('office_presentation_structure_edit')
    if importlib.util.find_spec('office_presentation_structure_edit') is not None
    else SimpleNamespace(**{name: None for name in EXPORTS}))
AUTHORITY_KEYS = {'kind', 'version', 'sourceSha256', 'sourcePart', 'partSha256',
    'shapeIdInventorySha256', 'shapeIdCount', 'canAddTable'}
OPERATION_KEYS = {'op', 'authorityVersion', 'id', 'ownerId', 'expectedSourceSha256', 'sourcePart',
    'expectedSourcePartSha256', 'expectedShapeIdInventorySha256', 'xMm', 'yMm', 'columnWidthsMm', 'rowHeightsMm'}
PLAN_KEYS = {'converted', 'parts', 'expected_native', 'expected_core', 'source_order',
    'owner_ledger', 'additions', 'base_snapshot'}
ADDITION_KEYS = {'alias', 'sourcePart', 'shapeId', 'positionEmu', 'extentEmu',
    'columnWidthsEmu', 'rowHeightsEmu', 'cells'}
OWNER_KEYS = {'sourcePart', 'ordinal', 'metadata', 'nonTableShapes', 'keys', 'pairs', 'additions'}
PREVIEW_KEYS = {'kind', 'version', 'baseSourceSha256', 'candidateSourceSha256',
    'operationsSha256', 'additions', 'snapshot'}
PREVIEW_ADDITION_KEYS = {'alias', 'ownerId', 'tableId', 'sourcePart', 'shapeId', 'frameSha256'}
PART = 'ppt/slides/slide1.xml'
EMPTY_PART = 'ppt/slides/slide3.xml'


def sha(data):
    return hashlib.sha256(data).hexdigest()


def canonical(value):
    return json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(',', ':'), allow_nan=False)


def inventory(part):
    root = source_reader._xml(part, {'nodes': 0})
    ids = sorted(int(node.attributes['id']) for node in source_reader._walk(root)
        if node.name == source_reader.P + 'cNvPr')
    return sha(canonical(ids).encode('utf-8')), len(ids)


def annotate_owner_parts(presentation, prepared):
    presentation.table_catalog._source_owner_parts = {
        owner_id: part for part, reference in prepared._bound_refs['owner_refs'].items()
        for owner_id, actual in presentation.slides.items() if actual == reference}


def prepare_structure_document(document, catalog, loader):
    if not catalog['tables']:
        document.after_remove = lambda: None
    prepare_native_document(document, catalog, loader)
    for source in catalog['tables']:
        shape = loader.by_source[(source['sourcePart'], source['shapeId'])]
        model = shape.values['Model']
        for index, height in enumerate(source['rowHeightsEmu']):
            model.rows.items[index].values['Height'] = height // 360
        for index, width in enumerate(source['columnWidthsEmu']):
            model.columns.items[index].values['Width'] = width // 360
        shape.Position.X, shape.Position.Y = source['positionEmu']['x'] // 360, source['positionEmu']['y'] // 360
        shape.Size.Width = max(1, source['extentEmu']['width'] // 360 - 1)
        shape.Size.Height = max(1, source['extentEmu']['height'] // 360)
    return document


class StructureServer:
    def __init__(self, state, directory):
        self.state, self.directory = state, Path(directory)
        self.index = len(state.servers)
        state.servers.append(self)
        self.loader, self.context, self.document, self.loaded = binding_fixtures.Loader(), object(), None, []

    def __enter__(self):
        self.state.events.append(('enter', self.index))
        return self

    def load(self, path, read_only=False):
        path = Path(path)
        self.loaded.append((path, read_only))
        self.state.events.append(('load', self.index))
        document = self.document = self.loader(path)
        catalog = source_reader.read_pptx_tables(path)
        prepare_structure_document(document, catalog, self.loader)
        phase = 'render' if self.index == 1 else 'observe' if self.index == 2 else 'plan'
        additions = [item for item in catalog['tables']
            if (item['sourcePart'], item['shapeId']) not in self.state.original_keys]
        if additions and self.state.fault in (phase + '_new_core', phase + '_new_width', phase + '_new_height'):
            self.state.fault_fired = True
            item = additions[0]
            model = self.loader.by_source[(item['sourcePart'], item['shapeId'])].values['Model']
            if self.state.fault.endswith('_core'):
                model.cells[0][0].paragraphs[0].portions[0].String = 'UNREQUESTED'
            elif self.state.fault.endswith('_width'):
                model.columns.items[0].values['Width'] += 1
            else:
                model.rows.items[0].values['Height'] += 1
        if self.state.fault == phase + '_old_core':
            original = next(item for item in catalog['tables']
                if (item['sourcePart'], item['shapeId']) in self.state.original_keys)
            self.loader.by_source[(original['sourcePart'], original['shapeId'])].values['Model'].cells[0][0].paragraphs[0].portions[0].String = 'FOREIGN'
            self.state.fault_fired = True
        if self.state.fault == phase + '_owner_metadata':
            document.DrawPages.items[0].Width += 1
            self.state.fault_fired = True
        close = document.close

        def close_document(ownership):
            self.state.events.append(('close', self.index))
            self.state.close_leases.append((self.index, write_is_blocked(path)))
            result = close(ownership)
            if self.state.fault == phase + '_close':
                self.state.fault_fired = True
                raise self.state.primary
            return result

        document.close = close_document
        return document

    def __exit__(self, error_type, error, traceback):
        self.state.events.append(('exit', self.index))
        return False


class PresentationStructureEditTest(unittest.TestCase):
    def api(self, name):
        function = getattr(MODULE, name, None)
        self.assertTrue(callable(function),
            'BOOTSTRAP: ' + name + ' is absent; this is not source/native structure-edit evidence')
        return function

    @contextmanager
    def loaded(self, *, raw_lost=False, frames=None, extra_empty=True):
        with binding_fixtures.PresentationBindingTest.fixture(self) as case:
            if frames is not None:
                slides = {PART: slide_xml(frames)}
                if extra_empty:
                    slides[EMPTY_PART] = slide_xml()
                names = list(slides)
                relations = [('rId' + str(index + 1), 'slides/' + part.rsplit('/', 1)[1], SLIDE, None)
                    for index, part in enumerate(names)]
                write_package(case.source, package_members(slides, [item[0] for item in relations], relations))
                case.original, case.sha = case.source.read_bytes(), sha(case.source.read_bytes())
            case.stamp = case.source.stat().st_mtime_ns
            with prepare_pptx_binding(case.source, case.work, case.sha) as prepared:
                def loader(path):
                    document = case.loader(path)
                    return prepare_structure_document(document, prepared.source_catalog, case.loader)
                document = prepared.load(loader)
                try:
                    raw_budget = patch.object(table_module.DocBudget, 'RAW_BYTES',
                        table_module.DocBudget.BYTE_RESERVE + 2048) if raw_lost else nullcontext()
                    with raw_budget:
                        _, slides, shapes = worker.objects(document)
                        presentation = Presentation(document, slides, shapes, source_path=case.source)
                        presentation.table_catalog.attach_source(prepared)
                        annotate_owner_parts(presentation, prepared)
                        yield case, prepared, presentation
                finally:
                    document.close(True)
            self.assertEqual(case.source.read_bytes(), case.original)
            self.assertEqual(case.source.stat().st_mtime_ns, case.stamp)

    def operation(self, case, prepared, presentation, *, part=PART, alias='new-table-alpha', **changes):
        owner = next(owner_id for owner_id, actual in presentation.slides.items() if actual == prepared.owner_refs[part])
        part_hash, _ = inventory(prepared._catalog['parts'][part])
        return {'op': 'presentationSourceTableAdd', 'authorityVersion': 1, 'id': alias, 'ownerId': owner,
            'expectedSourceSha256': case.sha, 'sourcePart': part,
            'expectedSourcePartSha256': sha(prepared._catalog['parts'][part]),
            'expectedShapeIdInventorySha256': part_hash, 'xMm': 15, 'yMm': 120,
            'columnWidthsMm': [30, 30, 30], 'rowHeightsMm': [12, 12], **changes}

    def state(self, prepared, fault=None):
        return SimpleNamespace(servers=[], events=[], close_leases=[], pdf_calls=[], snapshot_calls=[],
            stages=[], fault=fault, fault_fired=False, primary=RuntimeError('controlled structural ' + str(fault)),
            original_keys={(item['sourcePart'], item['shapeId']) for item in prepared._catalog['tables']})

    def services(self, state):
        def server_factory(runtime, directory):
            return StructureServer(state, directory)
        def snapshot(document, *args, **kwargs):
            server = next(server for server in state.servers if server.document is document)
            self.assertTrue(all(marker not in page.shapes for marker in server.loader.markers for page in document.DrawPages.items),
                'Private markers must be removed before observation or export')
            state.snapshot_calls.append(server.index)
            return worker.snapshot(document, *args, **kwargs)
        def export_pdf(document, destination, kind):
            server = next(server for server in state.servers if server.document is document)
            self.assertTrue(all(marker not in page.shapes for marker in server.loader.markers for page in document.DrawPages.items))
            self.assertEqual(kind, 'presentation')
            self.assertTrue(server.loaded[0][1])
            state.pdf_calls.append(server.index)
            if state.fault == 'pdf':
                state.fault_fired = True
                raise state.primary
            Path(destination).write_bytes(b'%PDF-STRUCTURAL-DOUBLE')
            return document.DrawPages.Count
        return dict(server_factory=server_factory, objects=worker.objects, snapshot=snapshot, export_pdf=export_pdf)

    def planned(self, case, prepared, presentation, operations, state=None):
        state = self.state(prepared) if state is None else state
        services = self.services(state)
        services.pop('export_pdf')
        work = case.source.parent / 'structure-plan'
        work.mkdir()
        plan = self.api('plan_source_structure_edit')(case.source.parent / 'unused-runtime', case.source, case.sha,
            operations, work, **services)
        return plan, state

    def test_all_public_backend_exports_are_explicit(self):
        for name in EXPORTS:
            self.api(name)

    def test_closed_public_batch_accepts_exact_geometry_and_alias_guard_fields(self):
        validate = self.api('validate_batch')
        with self.loaded() as (case, prepared, presentation):
            operation = self.operation(case, prepared, presentation)
            self.assertEqual(set(operation), OPERATION_KEYS)
            validate([operation], case.sha)
            invalid = [{**operation, 'extra': 1}, {**operation, 'id': 'alpha'},
                {**operation, 'id': 'new-table-'}, {**operation, 'id': 'new-table-' + 'x' * 65},
                {**operation, 'id': 'new-table-bad/name'}, {**operation, 'authorityVersion': True},
                {**operation, 'authorityVersion': 2}, {**operation, 'xMm': True},
                {**operation, 'yMm': float('nan')}, {**operation, 'columnWidthsMm': [.001]},
                {**operation, 'rowHeightsMm': [0]}, {**operation, 'expectedSourceSha256': '0' * 64}]
            invalid.extend({key: value for key, value in operation.items() if key != missing} for missing in operation)
            for supplied in invalid:
                with self.subTest(supplied=supplied), self.assertRaises(ValueError):
                    validate([supplied], case.sha)
            for batch in ([], [operation] * 101, [operation, operation],
                    [operation, {'op': 'presentationCellTextPatch'}], [operation, {'op': 'slideDisplay'}], (operation,)):
                with self.subTest(batch=batch), self.assertRaises(ValueError):
                    validate(batch, case.sha)

    def test_source_authority_includes_every_numeric_shape_id_and_is_independent_of_full_raw(self):
        authority_api = self.api('source_authority')
        with self.loaded(raw_lost=True, frames=[frame_xml('0009'), frame_xml('10')]) as (case, prepared, presentation):
            owner = next(key for key, part in presentation.table_catalog._source_owner_parts.items() if part == PART)
            authority = authority_api(presentation.table_catalog, owner)
            self.assertEqual(set(authority), AUTHORITY_KEYS)
            self.assertEqual(authority, dict(kind='sourceStructure', version=1, sourceSha256=case.sha, sourcePart=PART,
                partSha256=sha(prepared._catalog['parts'][PART]),
                shapeIdInventorySha256=sha(canonical([1, 9, 10]).encode('utf-8')), shapeIdCount=3, canAddTable=True))
            tables = presentation.table_catalog.snapshot(owner)
            self.assertTrue(any(table['tableSha256'] is None for table in tables))
            self.assertTrue(all(not any(table['capabilities'].values()) for table in tables))
            authority['partSha256'] = '0' * 64
            self.assertEqual(authority_api(presentation.table_catalog, owner)['partSha256'], sha(prepared._catalog['parts'][PART]))

    def test_zero_table_slide_receives_source_authority_only_after_actual_owner_binding(self):
        authority_api = self.api('source_authority')
        with self.loaded(frames=[]) as (case, prepared, presentation):
            owner = next(key for key, part in presentation.table_catalog._source_owner_parts.items() if part == EMPTY_PART)
            authority = authority_api(presentation.table_catalog, owner)
            self.assertTrue(authority['canAddTable'])
            self.assertEqual(authority['shapeIdCount'], 1)
            self.assertEqual(presentation.table_catalog.snapshot(owner), [])
            _, slides, shapes = worker.objects(presentation.document)
            unbound = Presentation(presentation.document, slides, shapes, source_path=case.source)
            self.assertIsNone(authority_api(unbound.table_catalog, owner))
            self.assertIsNone(authority_api(presentation.table_catalog, 'foreign-owner'))

    def test_equal_looking_owner_replacement_and_source_byte_drift_cannot_retain_add_authority(self):
        authority_api = self.api('source_authority')
        for fault in ('owner', 'source'):
            with self.subTest(fault=fault), self.loaded() as (case, prepared, presentation):
                owner = next(key for key, part in presentation.table_catalog._source_owner_parts.items() if part == PART)
                self.assertTrue(authority_api(presentation.table_catalog, owner)['canAddTable'])
                if fault == 'owner':
                    previous = presentation.slides[owner]
                    replacement = binding_fixtures.Page(previous.document, previous.shapes)
                    index = presentation.document.DrawPages.items.index(previous)
                    presentation.document.DrawPages.items[index] = replacement
                else:
                    with patch.object(presentation.table_catalog, '_source_digest', return_value='0' * 64):
                        with self.assertRaises(ValueError):
                            authority_api(presentation.table_catalog, owner)
                    continue
                with self.assertRaises(ValueError):
                    authority_api(presentation.table_catalog, owner)

    def test_global_table_or_cell_capacity_closes_add_without_inventing_raw_capabilities(self):
        authority_api = self.api('source_authority')
        for frames in ([grid_frame(str(index + 2)) for index in range(20)], [grid_frame('2', 10, 10)]):
            with self.subTest(tables=len(frames)), self.loaded(frames=frames) as (_, prepared, presentation):
                owner = next(key for key, part in presentation.table_catalog._source_owner_parts.items() if part == EMPTY_PART)
                authority = authority_api(presentation.table_catalog, owner)
                self.assertTrue(authority is None or authority['canAddTable'] is False)
                self.assertTrue(all(not any(table['capabilities'].values())
                    for entries in presentation.table_catalog.owners.values() for table in entries or []))

    def test_complete_original_native_core_is_required_even_when_source_xml_is_readable(self):
        authority_api = self.api('source_authority')
        with self.loaded() as (_, _, presentation):
            owner = next(key for key, part in presentation.table_catalog._source_owner_parts.items() if part == EMPTY_PART)
            with patch.object(text_edit, 'native_core_text', return_value=None):
                try:
                    authority = authority_api(presentation.table_catalog, owner)
                except ValueError:
                    pass
                else:
                    self.assertTrue(authority is None or authority['canAddTable'] is False)

    def test_plan_converts_base_guards_to_sequential_current_part_sha_and_exact_writer_ids(self):
        self.api('plan_source_structure_edit')
        with self.loaded() as (case, prepared, presentation):
            first = self.operation(case, prepared, presentation)
            second = self.operation(case, prepared, presentation, alias='new-table-beta', xMm=20)
            operations = [first, second]
            plan, state = self.planned(case, prepared, presentation, operations)
            self.assertEqual(set(plan), PLAN_KEYS)
            internal = plan['converted']
            self.assertEqual(len(internal), 2)
            self.assertEqual(internal[0]['expectedSourcePartSha256'], first['expectedSourcePartSha256'])
            after_first = structure.add_table_part(prepared._catalog['parts'][PART], PART, internal[0])
            self.assertEqual(internal[1]['expectedSourcePartSha256'], after_first['resultPartSha256'])
            after_second = structure.add_table_part(after_first['partBytes'], PART, internal[1])
            self.assertEqual(plan['parts'][PART], after_second['partBytes'])
            self.assertEqual([addition['alias'] for addition in plan['additions']], ['new-table-alpha', 'new-table-beta'])
            self.assertEqual([addition['shapeId'] for addition in plan['additions']], [after_first['shapeId'], after_second['shapeId']])
            existing = {item['sourcePart'] + '#' + item['shapeId'] for item in prepared._catalog['tables']}
            additions = {item['sourcePart'] + '#' + item['shapeId'] for item in plan['additions']}
            self.assertEqual(set(plan['expected_native']), existing)
            self.assertEqual(set(plan['expected_core']), existing | additions)
            for key in additions:
                self.assertEqual(plan['expected_core'][key], [''] * 6)
            self.assertEqual(plan['base_snapshot']['sourceSha256'], case.sha)
            self.assertEqual(plan['source_order'], list(prepared._catalog['parts']))
            self.assertTrue(all(set(addition) == ADDITION_KEYS for addition in plan['additions']))
            self.assertTrue(all(set(owner) == OWNER_KEYS for owner in plan['owner_ledger']))
            for owner in plan['owner_ledger']:
                self.assertFalse({'shapes', 'presentationTables', 'presentationTableCount', 'presentationTablesTruncated',
                    'presentationTablesUnknownReason', 'canAddTable', 'sourceStructureAuthority'} & owner['metadata'].keys())
            frozen = copy.deepcopy(plan)
            operations[0]['columnWidthsMm'][0] = 999
            self.assertEqual(plan, frozen, 'The detached source plan must not retain mutable public request values')
            self.assertEqual(len(state.servers), 1)
            self.assertTrue(state.servers[0].document.closed)

    def test_plan_rejects_foreign_owner_part_or_original_inventory_hash(self):
        self.api('plan_source_structure_edit')
        for changes in ({'ownerId': 'foreign-owner'}, {'expectedSourcePartSha256': '0' * 64},
                {'expectedShapeIdInventorySha256': '0' * 64}, {'sourcePart': EMPTY_PART}):
            with self.subTest(changes=changes), self.loaded() as (case, prepared, presentation):
                with self.assertRaises(ValueError):
                    self.planned(case, prepared, presentation, [self.operation(case, prepared, presentation, **changes)])

    def applied(self, *, fault=None, include_draft=True, empty_owner=False, native_stages=False):
        self.api('apply_source_structure_edit')
        with self.loaded() as (case, prepared, presentation):
            operation = self.operation(case, prepared, presentation, part=EMPTY_PART if empty_owner else PART)
            state = self.state(prepared, fault)
            services = self.services(state)
            job = case.source.parent / 'structural-apply'
            operations = [copy.deepcopy(operation)]
            backend = self.api('apply_source_structure_edit')
            stages = None
            if native_stages:
                class Stages:
                    def plan_structure(inner, runtime, source, source_hash, public, input_job):
                        state.stages.append('plan_structure')
                        arguments = {key: value for key, value in services.items() if key != 'export_pdf'}
                        return MODULE.plan_source_structure_edit(runtime, source, source_hash, public, input_job, **arguments)
                    def render_structure(inner, runtime, edited, candidate_hash, pdf, clean_job, plan, owned, pdf_state):
                        state.stages.append('render_structure')
                        return MODULE.render_source_structure_candidate(runtime, edited, candidate_hash, pdf,
                            clean_job, plan, owned, pdf_state, **services)
                    def observe_structure(inner, runtime, edited, candidate_hash, observer_job, plan):
                        state.stages.append('observe_structure')
                        arguments = {key: value for key, value in services.items() if key != 'export_pdf'}
                        return MODULE.observe_source_structure_candidate(runtime, edited, candidate_hash,
                            observer_job, plan, **arguments)
                stages = Stages()
            result, caught = None, None
            try:
                result = backend(case.source.parent / 'unused-runtime', case.source, case.sha, operations, job,
                    'structure-session', include_draft, native_stages=stages, **services)
            except BaseException as error:
                caught = error
            self.assertEqual(case.source.read_bytes(), case.original)
            self.assertEqual(case.sentinel.read_bytes(), b'DO NOT DELETE')
            candidate = source_reader.read_pptx_tables(Path(result['sourcePath'])) if result is not None else None
            if caught is not None:
                self.assertFalse((job / 'edited.pptx').exists())
                self.assertFalse((job / 'preview.pdf').exists())
            return SimpleNamespace(result=result, caught=caught, candidate=candidate, state=state,
                source_sha=case.sha, operations=operations, original_keys=state.original_keys)

    def test_apply_uses_three_fresh_bound_documents_and_cleans_markers_before_pdf(self):
        value = self.applied()
        self.assertIsNone(value.caught)
        result, state = value.result, value.state
        self.assertEqual(result['status'], 'saved')
        self.assertEqual(result['sessionId'], 'structure-session')
        self.assertEqual(result['sourceSha256'], value.candidate['sourceSha256'])
        self.assertEqual(state.pdf_calls, [1])
        self.assertEqual(len(state.servers), 3)
        self.assertTrue(all(read_only for server in state.servers for _, read_only in server.loaded))
        self.assertTrue(all(server.document.close_calls == 1 for server in state.servers))
        self.assertTrue(all(leased for _, leased in state.close_leases))
        self.assertLess(state.events.index(('close', 0)), state.events.index(('enter', 1)))
        self.assertLess(state.events.index(('close', 1)), state.events.index(('enter', 2)))
        self.assertTrue(all(not any(table['capabilities'].values())
            for slide in result['snapshot']['slides'] for table in slide['presentationTables']))

    def test_structural_preview_has_candidate_identity_and_exact_alias_ledger_without_legacy_draft(self):
        value = self.applied(empty_owner=True)
        self.assertIsNone(value.caught)
        result = value.result
        self.assertNotIn('draftSnapshot', result)
        preview = result['structuralPreview']
        self.assertEqual(set(preview), PREVIEW_KEYS)
        self.assertEqual(preview['kind'], 'presentationSourceStructure')
        self.assertEqual(preview['version'], 1)
        self.assertEqual(preview['baseSourceSha256'], value.source_sha)
        self.assertEqual(preview['candidateSourceSha256'], result['sourceSha256'])
        self.assertNotEqual(preview['candidateSourceSha256'], preview['baseSourceSha256'])
        self.assertEqual(preview['operationsSha256'], sha(canonical(value.operations).encode('utf-8')))
        self.assertEqual(preview['snapshot'], result['snapshot'])
        self.assertEqual(len(preview['additions']), 1)
        addition = preview['additions'][0]
        self.assertEqual(set(addition), PREVIEW_ADDITION_KEYS)
        self.assertEqual(addition['alias'], 'new-table-alpha')
        self.assertEqual(addition['ownerId'], value.operations[0]['ownerId'])
        self.assertEqual(addition['sourcePart'], EMPTY_PART)
        table = next(table for slide in result['snapshot']['slides'] for table in slide['presentationTables']
            if table['id'] == addition['tableId'])
        self.assertEqual(table['sourceTextPatchAuthority']['shapeId'], addition['shapeId'])
        self.assertEqual(table['sourceTextPatchAuthority']['frameSha256'], addition['frameSha256'])
        self.assertEqual((table['rowCount'], table['columnCount'], table['totalCellCount']), (2, 3, 6))
        self.assertEqual(table['columnWidthsHmm'], [3000] * 3)
        self.assertEqual(table['rowHeightsHmm'], [1200] * 2)
        self.assertEqual(table['nativeBoundsHmm']['width'], 8999,
            'Native bounds are recorded independently of exact requested model dimensions')

    def test_include_draft_false_omits_both_preview_payloads(self):
        value = self.applied(include_draft=False)
        self.assertIsNone(value.caught)
        self.assertNotIn('draftSnapshot', value.result)
        self.assertNotIn('structuralPreview', value.result)

    def test_new_explicit_native_stage_methods_are_used_without_legacy_text_dispatch(self):
        value = self.applied(native_stages=True)
        self.assertIsNone(value.caught)
        self.assertEqual(value.state.stages, ['plan_structure', 'render_structure', 'observe_structure'])

    def test_new_core_and_exact_requested_model_dimensions_are_mandatory_in_both_candidate_phases(self):
        for phase in ('render', 'observe'):
            for suffix in ('new_core', 'new_width', 'new_height'):
                with self.subTest(phase=phase, suffix=suffix):
                    value = self.applied(fault=phase + '_' + suffix)
                    self.assertTrue(value.state.fault_fired)
                    self.assertIsNotNone(value.caught)
                    self.assertTrue(all(server.document.closed for server in value.state.servers if server.document is not None))

    def test_unchanged_core_and_owner_metadata_are_checked_in_both_candidate_phases(self):
        for phase in ('render', 'observe'):
            for suffix in ('old_core', 'owner_metadata'):
                with self.subTest(phase=phase, suffix=suffix):
                    value = self.applied(fault=phase + '_' + suffix)
                    self.assertTrue(value.state.fault_fired)
                    self.assertIsNotNone(value.caught)

    def test_pdf_or_document_close_failure_cannot_publish_an_edition_and_preserves_primary_error(self):
        for fault in ('pdf', 'render_close', 'observe_close'):
            with self.subTest(fault=fault):
                value = self.applied(fault=fault)
                self.assertTrue(value.state.fault_fired)
                self.assertIs(value.caught, value.state.primary)
                self.assertTrue(all(server.document.close_calls == 1 for server in value.state.servers if server.document is not None))

    def ownership_apply(self, mode):
        self.api('apply_source_structure_edit')
        with self.loaded() as (case, prepared, presentation):
            operation = self.operation(case, prepared, presentation)
            state = self.state(prepared)
            services = self.services(state)
            real_render = MODULE.render_source_structure_candidate
            observations = {'mode': mode, 'exportCalls': 0, 'ownedByRenderer': None,
                'ownedAtExport': None, 'writtenIdentity': None, 'foreignIdentity': None}
            job = case.source.parent / ('structure-ownership-' + mode)
            pdf = job / 'preview.pdf'
            foreign_bytes = b'%PDF-FOREIGN-UNCHANGED' if mode == 'existing' else b'%PDF-SAME-REPLACEMENT-BYTES'

            def render(runtime, edited, candidate_hash, destination, clean_job, plan, owned, pdf_state, **arguments):
                if mode == 'existing':
                    Path(destination).write_bytes(foreign_bytes)
                    observations['foreignIdentity'] = source_reader._stamp(Path(destination).stat())[:2]

                def export(document, target, kind):
                    observations['exportCalls'] += 1
                    target = Path(target)
                    observations['ownedAtExport'] = owned.get(target)
                    target.write_bytes(b'%PDF-PARTIAL' if mode == 'partial' else foreign_bytes)
                    observations['writtenIdentity'] = source_reader._stamp(target.stat())[:2]
                    if mode == 'partial':
                        raise state.primary
                    replacement = case.source.parent / 'same-bytes-foreign-pdf.pdf'
                    replacement.write_bytes(foreign_bytes)
                    observations['foreignIdentity'] = source_reader._stamp(replacement.stat())[:2]
                    self.assertNotEqual(observations['writtenIdentity'], observations['foreignIdentity'])
                    replacement.replace(target)
                    self.assertEqual(source_reader._stamp(target.stat())[:2], observations['foreignIdentity'])
                    return document.DrawPages.Count

                arguments['export_pdf'] = export
                try:
                    return real_render(runtime, edited, candidate_hash, destination, clean_job, plan, owned, pdf_state,
                        **arguments)
                finally:
                    observations['ownedByRenderer'] = Path(destination) in owned
                    observations['ownedIdentity'] = owned.get(Path(destination))

            caught, result = None, None
            with patch.object(MODULE, 'render_source_structure_candidate', new=render):
                try:
                    result = MODULE.apply_source_structure_edit(case.source.parent / 'unused-runtime', case.source,
                        case.sha, [operation], job, 'structure-ownership', False, **services)
                except BaseException as error:
                    caught = error
            observations.update(caught=caught, result=result, primary=state.primary, pdfExists=pdf.exists(),
                pdfBytes=pdf.read_bytes() if pdf.exists() else None,
                finalPdfIdentity=source_reader._stamp(pdf.stat())[:2] if pdf.exists() else None,
                candidateExists=(job / 'edited.pptx').exists(), foreignBytes=foreign_bytes,
                allDocumentsClosed=all(server.document.closed for server in state.servers if server.document is not None))
            self.assertEqual(case.source.read_bytes(), case.original)
            self.assertEqual(case.sentinel.read_bytes(), b'DO NOT DELETE')
            return observations

    def test_preexisting_foreign_pdf_is_never_adopted_or_removed_by_direct_renderer(self):
        observed = self.ownership_apply('existing')
        self.assertIsNotNone(observed['caught'])
        self.assertEqual(observed['exportCalls'], 0)
        self.assertFalse(observed['ownedByRenderer'], 'Rejecting an existing PDF cannot turn it into an owned output')
        self.assertTrue(observed['pdfExists'], 'Direct apply removed a foreign PDF after rejecting its existence')
        self.assertEqual(observed['pdfBytes'], observed['foreignBytes'])
        self.assertEqual(observed['finalPdfIdentity'], observed['foreignIdentity'])
        self.assertFalse(observed['candidateExists'])
        self.assertTrue(observed['allDocumentsClosed'])

    def test_partial_export_failure_removes_only_pretracked_actual_output_and_preserves_primary(self):
        observed = self.ownership_apply('partial')
        self.assertIs(observed['caught'], observed['primary'])
        self.assertEqual(observed['exportCalls'], 1)
        self.assertEqual(observed['ownedAtExport'], observed['writtenIdentity'],
            'The direct renderer must capture its own exclusive creation identity before exporter execution')
        self.assertTrue(observed['ownedByRenderer'])
        self.assertFalse(observed['pdfExists'])
        self.assertFalse(observed['candidateExists'])
        self.assertTrue(observed['allDocumentsClosed'])

    def test_same_bytes_foreign_inode_replacement_during_export_is_preserved_and_never_published(self):
        observed = self.ownership_apply('replacement')
        self.assertIsNotNone(observed['caught'], 'A foreign same-byte output replacement cannot become a saved edition')
        self.assertIsNone(observed['result'])
        self.assertEqual(observed['exportCalls'], 1)
        self.assertTrue(observed['pdfExists'])
        self.assertEqual(observed['pdfBytes'], observed['foreignBytes'])
        self.assertEqual(observed['finalPdfIdentity'], observed['foreignIdentity'])
        self.assertNotEqual(observed['ownedIdentity'], observed['foreignIdentity'])
        self.assertFalse(observed['candidateExists'])
        self.assertTrue(observed['allDocumentsClosed'])

    def test_directory_source_part_is_rejected_by_closed_public_validation(self):
        validate = self.api('validate_batch')
        with self.loaded() as (case, prepared, presentation):
            operation = self.operation(case, prepared, presentation, sourcePart='ppt/slides/')
            with self.assertRaises(ValueError):
                validate([operation], case.sha)

    def test_directory_source_part_is_rejected_before_any_native_apply_effect(self):
        apply = self.api('apply_source_structure_edit')
        with self.loaded() as (case, prepared, presentation):
            operation = self.operation(case, prepared, presentation, sourcePart='ppt/slides/')
            native_effects = []
            def forbidden_server(*arguments):
                native_effects.append(arguments)
                raise AssertionError('Directory sourcePart reached native server creation')
            job = case.source.parent / 'directory-part-apply'
            with self.assertRaises(ValueError):
                apply(case.source.parent / 'unused-runtime', case.source, case.sha, [operation], job,
                    'directory-part', False, server_factory=forbidden_server, objects=worker.objects,
                    snapshot=worker.snapshot, export_pdf=lambda *arguments: None)
            self.assertEqual(native_effects, [])
            self.assertFalse(job.exists())


if __name__ == '__main__':
    unittest.main()
