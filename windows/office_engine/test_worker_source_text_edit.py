"""Actual public source-only apply: pure writer, clean readonly PDF and fresh refs.

Root alone executes. Doubles use real package bytes and product source binding;
no fake result replaces the worker or package writer being tested.
"""
import copy
import hashlib
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import office_presentation as presentation_module
import office_presentation_package_patch as package_patch
import office_presentation_source as source_reader
import office_presentation_source_edit as source_edit
from office_presentation_text_source import cell_text_map
import office_worker as worker
import test_presentation_binding as binding_fixtures
import test_presentation_source_edit as source_fixtures
import test_worker_presentation_binding as worker_binding_fixtures
from test_presentation_source_edit import prepare_native_document, sha, BASELINE
from test_worker_presentation_binding import write_is_blocked


REAL_SNAPSHOT = worker.snapshot
REAL_PATCH = package_patch.patch_pptx


class SourceServer:
    def __init__(self, state, directory):
        self.state, self.directory = state, Path(directory)
        self.index = len(state.servers)
        state.servers.append(self)
        self.loader, self.context, self.document = binding_fixtures.Loader(), object(), None
        self.loaded = []

    def __enter__(self):
        self.state.events.append(('enter', self.index))
        return self

    def load(self, path, read_only=False):
        path = Path(path)
        self.state.events.append(('load', self.index))
        self.loaded.append((path, read_only))
        if self.index == 1 and self.state.fault == 'clean_native':
            self.state.fault_fired = True
            raise self.state.primary
        document = self.document = self.loader(path)
        catalog = source_reader.read_pptx_tables(path)
        prepare_native_document(document, catalog, self.loader)
        if self.index == 1 and self.state.fault == 'clean_owner_swap':
            self.state.fault_fired = True
            nonempty = [index for index, page in enumerate(document.DrawPages.items) if page.Count]
            if len(nonempty) != 2:
                raise AssertionError('The owner-swap control needs exactly two nonempty pages')
            one, two = nonempty
            document.DrawPages.items[one], document.DrawPages.items[two] = (
                document.DrawPages.items[two], document.DrawPages.items[one])
            target = self.loader.by_source[(self.state.operation['sourcePart'], self.state.operation['shapeId'])]
            self.state.clean_target_owner_index = next(index for index, page in enumerate(document.DrawPages.items)
                if any(shape is target for shape in page.shapes))
        if self.index == 2 and self.state.fault == 'pdf_replacement':
            self.state.fault_fired = True
            pdf = self.directory.parent / 'preview.pdf'
            self.state.pdf_before_replacement = pdf.read_bytes()
            try:
                self.state.foreign_pdf.replace(pdf)
                self.state.pdf_replaced = True
            except PermissionError:
                self.state.pdf_replacement_blocked = True
        if self.index == 1 and self.state.fault == 'clean_core_drift':
            self.state.fault_fired = True
            source = catalog['tables'][0]
            self.loader.by_source[(source['sourcePart'], source['shapeId'])].values['Model'].cells[0][0].paragraphs[0].portions[0].String = 'UNREQUESTED'
        if self.index == 2 and self.state.fault == 'observer_core_drift':
            self.state.fault_fired = True
            source = catalog['tables'][0]
            self.loader.by_source[(source['sourcePart'], source['shapeId'])].values['Model'].cells[0][0].paragraphs[0].portions[0].String = 'UNREQUESTED'
        close = document.close

        def close_document(ownership):
            self.state.events.append(('close', self.index))
            self.state.close_leases.append((self.index, write_is_blocked(path)))
            result = close(ownership)
            if self.index == 1 and self.state.fault == 'close':
                self.state.fault_fired = True
                raise self.state.primary
            return result

        document.close = close_document
        return document

    def __exit__(self, error_type, error, traceback):
        self.state.events.append(('exit', self.index))
        return False


class WorkerSourceTextEditTest(unittest.TestCase):
    def run_case(self, *, include_draft=True, mutations=None, sequential=False, mixed=False,
            fault=None, root_hash=True, operation_count=None):
        with source_fixtures.PresentationSourceEditTest.loaded(self) as (case, prepared, presentation):
            baseline = REAL_SNAPSHOT(presentation.document, case.sha, object(), presentation=presentation, source_path=case.source)
            source = next(item for item in prepared.source_catalog['tables']
                if (item['sourcePart'], item['shapeId']) == ('ppt/slides/slide1.xml', '10'))
            key = source['sourcePart'], source['shapeId']
            owner_id = next(key for key, owner in presentation.slides.items() if owner is prepared.owner_refs[source['sourcePart']])
            table_id = next(key for key, shape in presentation.shapes.items() if shape is prepared.table_refs[(source['sourcePart'], source['shapeId'])])
            table = next(table for slide in baseline['slides'] for table in slide['presentationTables'] if table['id'] == table_id)
            cell = next(cell for cell in table['cells'] if (cell['row'], cell['column']) == (1, 1))
            source_cell = next(cell for cell in source['cells'] if (cell['row'], cell['column']) == (1, 1))
            original_map = cell_text_map(prepared.source_catalog['parts'][source['sourcePart']], source_cell)
            op = {'op': 'presentationCellTextPatch', 'authorityVersion': 1, 'ownerId': owner_id,
                'tableId': table_id, 'cellId': cell['id'], 'expectedSourceSha256': case.sha,
                'sourcePart': source['sourcePart'], 'shapeId': source['shapeId'],
                'expectedSourceFrameSha256': sha(prepared.source_catalog['parts'][source['sourcePart']][slice(*source['frameSpan'])]),
                'expectedTextSha256': sha(original_map['text'].encode('utf-8')),
                'startUtf16': 0, 'endUtf16': 4, 'text': 'UPDATED 한글😀'}
            expected_text = op['text'] + original_map['text'][4:]
            operations = [{**op, **(mutations or {})}]
            if sequential:
                operations.append({**op, 'expectedTextSha256': sha(expected_text.encode('utf-8')),
                    'startUtf16': 0, 'endUtf16': 7, 'text': 'FINAL'})
                expected_text = 'FINAL' + expected_text[7:]
            if mixed:
                operations.insert(0, {'op': 'slideDisplay', 'id': owner_id, 'visible': False})
            if operation_count is not None:
                operations = [copy.deepcopy(op) for _ in range(operation_count)]
                if operation_count == 0:
                    expected_text = original_map['text']
            state = SimpleNamespace(servers=[], events=[], close_leases=[], patch_calls=[], legacy_effects=[],
                primary=RuntimeError('controlled source ' + str(fault) + ' failure'), fault=fault, fault_fired=False,
                pdf_calls=[], snapshot_calls=[], result=None, caught=None, baseline=copy.deepcopy(baseline),
                original=case.original, original_hash=case.sha, operation=copy.deepcopy(op), expected_text=expected_text,
                candidate_bytes=None, candidate_catalog=None, output_files=[],
                clean_target_owner_index=None, expected_owner_index=next(index for index, slide in enumerate(baseline['slides']) if slide['id'] == owner_id),
                pdf_replaced=False, pdf_replacement_blocked=False, pdf_before_replacement=None,
                returned_pdf_bytes=None, foreign_replacement_preserved=False,
                foreign_pdf=case.source.parent / 'foreign-pdf-replacement.pdf', foreign_pdf_bytes=b'%PDF-FOREIGN-REPLACEMENT')
            if fault == 'pdf_replacement':
                state.foreign_pdf.write_bytes(state.foreign_pdf_bytes)
            job = case.source.parent / 'source-apply-job'

            def server_factory(runtime, directory):
                return SourceServer(state, directory)

            def patch_package(source, destination, requests, expected_sha256):
                state.patch_calls.append(copy.deepcopy(requests))
                return REAL_PATCH(source, destination, requests, expected_sha256)

            def snapshot(document, *arguments, **keywords):
                server = next(server for server in state.servers if server.document is document)
                state.snapshot_calls.append(server.index)
                self.assertTrue(all(marker not in page.shapes for marker in server.loader.markers for page in document.DrawPages.items))
                return REAL_SNAPSHOT(document, *arguments, **keywords)

            def pdf(document, destination, kind):
                server = next(server for server in state.servers if server.document is document)
                state.events.append(('pdf', server.index))
                state.pdf_calls.append((server.index, write_is_blocked(server.loaded[0][0]), len(server.loader.markers)))
                if fault == 'pdf':
                    state.fault_fired = True
                    raise state.primary
                Path(destination).write_bytes(b'%PDF-OWNED-CLEAN-TEST')
                return document.DrawPages.Count

            def legacy_effect(presentation, operation):
                state.legacy_effects.append(operation)

            request = {'mode': 'apply', 'sourcePath': str(case.source), 'sessionId': 'source-only-session',
                'operations': operations, 'includeDraftSnapshot': include_draft}
            if root_hash:
                request['expectedSourceSha256'] = case.sha
            with patch.object(worker, 'OfficeServer', side_effect=server_factory), \
                    patch.object(worker, 'snapshot', new=snapshot), \
                    patch.object(worker, 'export_pdf', new=pdf), \
                    patch.object(package_patch, 'patch_pptx', new=patch_package), \
                    patch.object(presentation_module.Presentation, 'display', new=legacy_effect):
                try:
                    state.result = worker.run_request(case.source.parent / 'unused-runtime', request, job)
                except BaseException as error:
                    state.caught = error
            self.assertEqual(case.source.read_bytes(), case.original)
            self.assertEqual(case.sentinel.read_bytes(), b'DO NOT DELETE')
            if state.result is not None:
                candidate = Path(state.result['sourcePath'])
                state.candidate_bytes = candidate.read_bytes()
                state.candidate_catalog = source_reader.read_pptx_tables(candidate)
                self.assertTrue(Path(state.result['pdfPath']).is_file())
                state.returned_pdf_bytes = Path(state.result['pdfPath']).read_bytes()
            state.output_files = [path.name for path in job.rglob('*') if path.is_file()] if job.exists() else []
            if state.caught is not None:
                self.assertFalse((job / 'edited.pptx').exists())
                if fault == 'pdf_replacement' and state.pdf_replaced:
                    state.foreign_replacement_preserved = ((job / 'preview.pdf').is_file() and
                        (job / 'preview.pdf').read_bytes() == state.foreign_pdf_bytes)
                    self.assertTrue(state.foreign_replacement_preserved, 'Foreign replacement bytes must not be deleted as owned PDF')
                else:
                    self.assertFalse((job / 'preview.pdf').exists())
            if fault == 'pdf_replacement' and state.pdf_replacement_blocked:
                self.assertEqual(state.foreign_pdf.read_bytes(), state.foreign_pdf_bytes)
            return state

    def target_snapshot(self, snapshot, operation):
        table = next(table for slide in snapshot['slides'] for table in slide['presentationTables']
            if table['id'] == operation['tableId'])
        return table, next(cell for cell in table['cells'] if cell['id'] == operation['cellId'])

    def test_public_source_only_apply_uses_product_writer_clean_pdf_and_separate_fresh_bound_snapshot(self):
        state = self.run_case()
        self.assertIsNone(state.caught)
        result = state.result
        self.assertEqual(result['status'], 'saved')
        self.assertEqual(result['sessionId'], 'source-only-session')
        self.assertEqual(result['sourceSha256'], sha(state.candidate_bytes))
        self.assertNotEqual(state.candidate_bytes, state.original)
        self.assertEqual(len(state.patch_calls), 1)
        self.assertEqual(len(state.servers), 3)
        self.assertTrue(all(read_only for server in state.servers for _, read_only in server.loaded))
        self.assertEqual(state.pdf_calls, [(1, True, 0)], 'Only exact clean candidate may render the PDF')
        self.assertTrue(all(document.document.close_calls == 1 for document in state.servers))
        self.assertTrue(all(leased for _, leased in state.close_leases))
        self.assertLess(state.events.index(('close', 0)), state.events.index(('enter', 1)))
        self.assertLess(state.events.index(('close', 1)), state.events.index(('enter', 2)))
        table, cell = self.target_snapshot(result['snapshot'], state.operation)
        self.assertEqual(cell['text'], state.expected_text)
        self.assertEqual(cell['sourceTextPatch']['text'], state.expected_text)
        self.assertEqual(table['sourceTextPatchAuthority']['sourceSha256'], result['sourceSha256'])
        self.assertNotEqual(table['sourceTextPatchAuthority']['frameSha256'], state.operation['expectedSourceFrameSha256'])
        self.assertTrue(all(value is False for value in table['capabilities'].values()))
        target = next(table for table in state.candidate_catalog['tables'] if table['shapeId'] == '10' and table['sourcePart'] == 'ppt/slides/slide1.xml')
        self.assertEqual(cell_text_map(state.candidate_catalog['parts'][target['sourcePart']], target['cells'][3])['text'], state.expected_text)

    def test_draft_preserves_origin_native_baseline_and_guards_while_only_source_semantic_map_changes(self):
        state = self.run_case()
        self.assertIsNone(state.caught)
        draft = state.result['draftSnapshot']
        self.assertEqual(draft['sourceSha256'], state.original_hash)
        old_table, old_cell = self.target_snapshot(state.baseline, state.operation)
        table, cell = self.target_snapshot(draft, state.operation)
        self.assertEqual(table['sourceTextPatchAuthority'], old_table['sourceTextPatchAuthority'])
        for key in ('text', 'textDetails', 'rawStyle'):
            self.assertEqual(cell[key], old_cell[key])
        for key in ('tableSha256', 'rawStyle', 'nativeBoundsHmm', 'authoredGeometry', 'capabilities'):
            self.assertEqual(table[key], old_table[key])
        self.assertEqual(cell['sourceTextPatch']['text'], state.expected_text)
        self.assertEqual(cell['sourceTextPatch']['textSha256'], sha(state.expected_text.encode('utf-8')))
        self.assertEqual(cell['sourceTextPatch']['utf16Length'], len(state.expected_text.encode('utf-16-le')) // 2)
        self.assertTrue(cell['sourceTextPatch']['canReplace'])
        self.assertFalse(cell['sourceTextPatch']['truncated'])
        left, right = copy.deepcopy(state.baseline), copy.deepcopy(draft)
        self.target_snapshot(left, state.operation)[1].pop('sourceTextPatch')
        self.target_snapshot(right, state.operation)[1].pop('sourceTextPatch')
        self.assertEqual(right, left, 'A candidate raw/native state must not become the draft baseline')

    def test_sequential_text_hashes_and_ranges_keep_origin_source_and_frame_guards(self):
        state = self.run_case(sequential=True, include_draft=False)
        self.assertIsNone(state.caught)
        self.assertNotIn('draftSnapshot', state.result)
        self.assertEqual(len(state.patch_calls[0]), 2)
        self.assertEqual({op['expectedSourceFrameSha256'] for op in state.patch_calls[0]}, {state.operation['expectedSourceFrameSha256']})
        self.assertEqual(self.target_snapshot(state.result['snapshot'], state.operation)[1]['text'], state.expected_text)

    def test_mixed_native_source_batch_rejects_before_any_effect_or_native_load(self):
        state = self.run_case(mixed=True)
        self.assertIsInstance(state.caught, ValueError)
        self.assertIn('mixed', str(state.caught).lower())
        self.assertEqual(state.servers, [])
        self.assertEqual(state.legacy_effects, [])
        self.assertEqual(state.patch_calls, [])
        self.assertIsNone(state.result)

    def test_origin_root_hash_is_required_for_source_only_apply_before_native_effects(self):
        state = self.run_case(root_hash=False)
        self.assertIsInstance(state.caught, ValueError)
        self.assertEqual(state.servers, [])
        self.assertEqual(state.patch_calls, [])

    def test_closed_version_origin_and_actual_owner_table_cell_guards_reject_without_candidate(self):
        for mutation in ({'authorityVersion': True}, {'authorityVersion': 2}, {'extra': 1},
                {'expectedSourceSha256': '0' * 64}, {'ownerId': 'foreign'}, {'tableId': 'foreign'},
                {'cellId': 'foreign'}, {'sourcePart': 'ppt/slides/slide2.xml'}, {'shapeId': '9'},
                {'expectedSourceFrameSha256': '0' * 64}, {'expectedTextSha256': '0' * 64},
                {'startUtf16': 6, 'endUtf16': 6}):
            with self.subTest(mutation=mutation):
                state = self.run_case(mutations=mutation)
                self.assertIsInstance(state.caught, ValueError)
                self.assertIsNone(state.result)
                self.assertEqual(state.pdf_calls, [])
                if 'expectedTextSha256' not in mutation and 'startUtf16' not in mutation:
                    self.assertEqual(state.patch_calls, [])

    def test_source_only_batch_limit_is_checked_before_native_effects(self):
        state = self.run_case(operation_count=101)
        self.assertIsInstance(state.caught, ValueError)
        self.assertEqual(state.servers, [])
        self.assertEqual(state.patch_calls, [])

    def test_clean_and_private_observer_failures_never_return_saved_or_leave_edited_pdf(self):
        for fault in ('clean_native', 'clean_core_drift', 'observer_core_drift', 'pdf', 'close'):
            with self.subTest(fault=fault):
                state = self.run_case(fault=fault)
                self.assertTrue(state.fault_fired, 'The injected post-writer boundary must actually be reached')
                self.assertIsNotNone(state.caught)
                self.assertIsNone(state.result)
                self.assertEqual(len(state.patch_calls), 1)
                self.assertTrue(all(server.document is None or server.document.closed for server in state.servers))


    def test_clean_nonempty_owner_swap_cannot_render_requested_text_on_another_page(self):
        state = self.run_case(fault='clean_owner_swap')
        self.assertTrue(state.fault_fired, 'The controlled swap must reach the clean native load')
        self.assertNotEqual(state.clean_target_owner_index, state.expected_owner_index)
        self.assertIsInstance(state.caught, ValueError)
        self.assertIsNone(state.result)
        self.assertEqual(len(state.patch_calls), 1)
        self.assertEqual(state.pdf_calls, [], 'A private observer cannot authorize a reordered clean PDF input')

    def test_pdf_replacement_during_bound_observer_cannot_become_the_saved_hash_baseline(self):
        state = self.run_case(fault='pdf_replacement')
        self.assertTrue(state.fault_fired, 'The replacement must occur after clean PDF export')
        self.assertTrue(state.pdf_replaced or state.pdf_replacement_blocked)
        self.assertEqual(state.pdf_before_replacement, b'%PDF-OWNED-CLEAN-TEST')
        self.assertTrue(state.pdf_replacement_blocked or state.caught is not None,
            'Observer-time foreign PDF bytes must not be accepted as a new result baseline')
        if state.result is not None:
            self.assertTrue(state.pdf_replacement_blocked)
            self.assertEqual(state.returned_pdf_bytes, state.pdf_before_replacement)
            self.assertEqual(state.result['pdfSha256'], sha(state.pdf_before_replacement))
        elif state.pdf_replaced:
            self.assertTrue(state.foreign_replacement_preserved)



    def test_supported_empty_preview_keeps_exact_zip_and_origin_bound_draft_without_native_export(self):
        state = self.run_case(operation_count=0, include_draft=True)
        loads = [loaded for server in state.servers for loaded in server.loaded]
        self.assertTrue(loads, 'The actual worker must reach a native-consumption route')
        self.assertTrue(all(read_only for _, read_only in loads),
            'Supported empty source preview must use readonly loads; a legacy writable load is already an observed route violation')
        self.assertIsNone(state.caught)
        self.assertEqual(state.result['status'], 'saved')
        self.assertEqual(state.candidate_bytes, state.original)
        self.assertEqual(state.result['sourceSha256'], state.original_hash)
        self.assertEqual(state.patch_calls, [[]], 'No synthetic source cell operation may stand in for an empty preview')
        self.assertEqual(state.result['draftSnapshot'], state.baseline)
        self.assertTrue(all(read_only for server in state.servers for _, read_only in server.loaded))
        self.assertEqual(state.pdf_calls, [(1, True, 0)])
        for slide in state.result['draftSnapshot']['slides']:
            for table in slide['presentationTables']:
                self.assertEqual(table['sourceTextPatchAuthority']['sourceSha256'], state.original_hash)
                self.assertTrue(all(cell['sourceTextPatch']['canReplace'] for cell in table['cells']))



    def test_unsupported_grouped_empty_preview_reaches_legacy_dispatch_only_after_entry_rejection(self):
        with binding_fixtures.PresentationBindingTest.fixture(self) as case:
            reference = case.source.parent / 'native-reference.pptx'
            reference.write_bytes(case.original)
            grouped = dict(case.members)
            part = 'ppt/slides/slide1.xml'
            grouped[part] = grouped[part].replace(b'<p:graphicFrame>', b'<p:grpSp><p:graphicFrame>', 1)
            grouped[part] = grouped[part].replace(b'</p:graphicFrame>', b'</p:graphicFrame></p:grpSp>', 1)
            binding_fixtures.write_package(case.source, grouped.items())
            original, pinned = case.source.read_bytes(), sha(case.source.read_bytes())
            with self.assertRaises(ValueError):
                source_reader.read_pptx_tables(case.source)
            primary = RuntimeError('legacy empty preview dispatch reached')
            state = SimpleNamespace(events=[], primary=primary, fault=None, unsupported=True, suffix='.pptx')
            servers = []
            job = case.source.parent / 'grouped-empty-preview'

            def server_factory(runtime, directory):
                server = worker_binding_fixtures.Server(case, Path(directory), state, reference)
                servers.append(server)
                return server

            request = {'mode': 'apply', 'sourcePath': str(case.source), 'sessionId': 'legacy-noop-session',
                'operations': [], 'includeDraftSnapshot': True, 'expectedSourceSha256': pinned}
            with patch.object(worker, 'OfficeServer', side_effect=server_factory), \
                    patch.object(worker, 'apply_operations', side_effect=primary) as legacy_dispatch, \
                    patch.object(package_patch, 'patch_pptx') as source_writer, \
                    patch.object(worker, 'export_pdf') as pdf:
                with self.assertRaises(RuntimeError) as failure:
                    worker.run_request(case.source.parent / 'unused-runtime', request, job)
            self.assertIs(failure.exception, primary)
            self.assertEqual(len(servers), 2)
            self.assertEqual(servers[0].loaded, [], 'Unsupported prepare entry must fail before a native load')
            self.assertIsNone(servers[0].document)
            self.assertEqual(len(servers[1].loaded), 1)
            path, read_only, data = servers[1].loaded[0]
            self.assertEqual(path, job / 'working.pptx')
            self.assertFalse(read_only, 'The existing unsupported preview route keeps its default native dispatch')
            self.assertEqual(sha(data), pinned)
            legacy_dispatch.assert_called_once()
            self.assertEqual(legacy_dispatch.call_args.args[1], [])
            source_writer.assert_not_called()
            pdf.assert_not_called()
            self.assertEqual(case.source.read_bytes(), original)
            self.assertEqual((job / 'working.pptx').read_bytes(), original)
            self.assertFalse((job / 'edited.pptx').exists())
            self.assertTrue(servers[1].document.closed)
            self.assertEqual(case.sentinel.read_bytes(), b'DO NOT DELETE')


    def native_phase_api(self):
        names = ('plan_source_text_edit', 'render_source_candidate', 'observe_source_candidate')
        functions = {name: getattr(source_edit, name, None) for name in names}
        self.assertTrue(all(callable(function) for function in functions.values()),
            'BOOTSTRAP: three source-native phase entry points are missing; this is not native behavior evidence')
        return functions

    def assert_plan_data_only(self, value, location='plan'):
        if type(value) is dict:
            self.assertTrue(all(type(key) is str for key in value), location)
            for key, child in value.items():
                self.assert_plan_data_only(child, location + '.' + key)
        elif type(value) in (list, tuple):
            for index, child in enumerate(value):
                self.assert_plan_data_only(child, location + '[' + str(index) + ']')
        else:
            self.assertIn(type(value), (str, bytes, int, float, bool, type(None)),
                location + ' must not retain a document, native reference, context, or lease')

    def test_native_phase_plan_detaches_refs_and_preserves_ordered_xml_bytes_and_covered_anchor_tuples(self):
        api = self.native_phase_api()
        observed = []
        original_table_xml = source_fixtures.table_xml

        def merged_table_xml(rows):
            rows = copy.deepcopy(rows)
            rows[0][0] = rows[0][0].replace(b'<a:tc>', b'<a:tc gridSpan="2">', 1)
            rows[0][1] = rows[0][1].replace(b'<a:tc>', b'<a:tc hMerge="1">', 1)
            return original_table_xml(rows)

        def plan(*arguments, **keywords):
            result = api['plan_source_text_edit'](*arguments, **keywords)
            self.assertEqual(set(result), {'converted', 'parts', 'expected_native', 'expected_core',
                'draft', 'source_order', 'owner_ledger'})
            self.assert_plan_data_only(result)
            self.assertEqual(result['source_order'], ['ppt/slides/slide2.xml',
                'ppt/slides/slide1.xml', 'ppt/slides/slide3.xml'])
            self.assertEqual(list(result['parts']), result['source_order'])
            self.assertTrue(all(type(part) is bytes for part in result['parts'].values()))
            anchors = [cell['anchorCellId'] for table in result['expected_native'].values()
                for cell in table['cells'] if cell['covered']]
            self.assertEqual(len(anchors), 4, 'The real package/control must contain covered cells')
            self.assertTrue(all(type(anchor) is tuple and anchor == (0, 0) for anchor in anchors))
            self.assertEqual([owner['ordinal'] for owner in result['owner_ledger']], [0, 1, 2])
            observed.append(result)
            return result

        with patch.object(source_fixtures, 'table_xml', new=merged_table_xml), \
                patch.object(source_edit, 'plan_source_text_edit', new=plan), \
                patch.object(source_edit, 'render_source_candidate', wraps=api['render_source_candidate']) as render, \
                patch.object(source_edit, 'observe_source_candidate', wraps=api['observe_source_candidate']) as observe:
            state = self.run_case()
        self.assertIsNone(state.caught)
        self.assertEqual(len(observed), 1)
        render.assert_called_once()
        observe.assert_called_once()
        self.assertEqual(observed[0]['parts'], state.candidate_catalog['parts'])
        self.assertEqual(len(state.servers), 3)
        self.assertLess(state.events.index(('exit', 0)), state.events.index(('enter', 1)))
        self.assertLess(state.events.index(('exit', 1)), state.events.index(('enter', 2)))

    def test_clean_phase_transfers_the_same_live_pdf_lease_to_outer_observer_and_final_verification(self):
        api = self.native_phase_api()
        retained = {}

        def render(runtime, edited, candidate_hash, pdf, clean_job, owner_ledger, owned, pdf_state, **keywords):
            result = api['render_source_candidate'](runtime, edited, candidate_hash, pdf,
                clean_job, owner_ledger, owned, pdf_state, **keywords)
            retained.update(state=pdf_state, lease=pdf_state['lease'], path=pdf)
            self.assertIsNotNone(retained['lease']._handle)
            self.assertTrue(write_is_blocked(pdf), 'The clean phase must return with its PDF lease still held')
            self.assertEqual(pdf_state['sha256'], sha(pdf.read_bytes()))
            return result

        def observe(*arguments, **keywords):
            self.assertIs(retained['state']['lease'], retained['lease'])
            self.assertIsNotNone(retained['lease']._handle)
            self.assertTrue(write_is_blocked(retained['path']))
            result = api['observe_source_candidate'](*arguments, **keywords)
            self.assertIs(retained['state']['lease'], retained['lease'])
            self.assertIsNotNone(retained['lease']._handle)
            self.assertTrue(write_is_blocked(retained['path']))
            return result

        with patch.object(source_edit, 'render_source_candidate', new=render), \
                patch.object(source_edit, 'observe_source_candidate', new=observe):
            state = self.run_case()
        self.assertIsNone(state.caught)
        self.assertEqual(state.result['pdfSha256'], retained['state']['sha256'])
        self.assertIsNone(retained['lease']._handle, 'The original held PDF lease must be closed after final checks')
        self.assertIsNone(retained['state']['lease'])

    def test_clean_close_failure_does_not_run_observer_and_releases_the_already_owned_pdf_lease(self):
        api = self.native_phase_api()
        retained = {}

        def render(runtime, edited, candidate_hash, pdf, clean_job, owner_ledger, owned, pdf_state, **keywords):
            try:
                return api['render_source_candidate'](runtime, edited, candidate_hash, pdf,
                    clean_job, owner_ledger, owned, pdf_state, **keywords)
            finally:
                retained.update(state=pdf_state, lease=pdf_state.get('lease'))

        with patch.object(source_edit, 'plan_source_text_edit', wraps=api['plan_source_text_edit']) as plan, \
                patch.object(source_edit, 'render_source_candidate', new=render), \
                patch.object(source_edit, 'observe_source_candidate', wraps=api['observe_source_candidate']) as observe:
            state = self.run_case(fault='close')
        plan.assert_called_once()
        observe.assert_not_called()
        self.assertIs(state.caught, state.primary)
        self.assertEqual(len(state.servers), 2)
        self.assertTrue(state.fault_fired)
        self.assertIsNotNone(retained['lease'], 'The failure control must reach PDF acquisition before close fails')
        self.assertIsNone(retained['lease']._handle, 'Outer cleanup must close the same lease on a clean close failure')
        self.assertTrue(all(server.document is None or server.document.closed for server in state.servers))



if __name__ == '__main__':
    unittest.main()
