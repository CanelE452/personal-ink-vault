"""Normal inspect consumes the private PPTX binding before publishing any view.

Real source ZIP/prepare/Presentation/catalog/snapshot are used with the existing
UNO ref doubles. Root alone executes; this suite does not grant table writes.
"""
from contextlib import contextmanager
import hashlib
import os
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import office_presentation_binding as binding
import office_presentation_tables as tables
import office_worker as worker
import test_presentation_binding as fixtures
from test_presentation_source import write_package
from test_presentation_tables import Properties


REAL_PREPARE = binding.prepare_pptx_binding
REAL_SNAPSHOT = worker.snapshot
REAL_ATTACH = tables.PresentationTables.attach_source


def write_is_blocked(path):
    try:
        with Path(path).open('r+b'):
            return False
    except PermissionError:
        return True


class Server:
    def __init__(self, case, job, state, reference):
        self.case, self.job, self.state, self.reference = case, job, state, reference
        self.context = object()
        self.loaded, self.document = [], None

    def __enter__(self):
        self.state.events.append('server-enter')
        return self

    def load(self, path, read_only=False):
        path = Path(path)
        self.state.events.append('load')
        self.loaded.append((path, read_only, path.read_bytes()))
        if self.state.fault == 'native':
            raise self.state.primary
        actual_path = self.reference if self.state.unsupported or self.state.suffix != '.pptx' else path
        doc = self.document = self.case.loader(actual_path)
        service = ('com.sun.star.text.TextDocument' if self.state.suffix == '.docx'
            else 'com.sun.star.presentation.PresentationDocument')
        doc.supportsService = lambda name: name == service
        for page in doc.DrawPages.items:
            properties = Properties({'Layout': 20, 'Visible': True, 'IsBackgroundObjectsVisible': True,
                'Background': None})
            page.Width, page.Height = 28000, 15750
            page.getPropertySetInfo = properties.getPropertySetInfo
            page.getPropertyValue = properties.getPropertyValue
            page.getMasterPage = lambda: None
        for shape in self.case.loader.by_source.values():
            shape.Size.Width = 19999
        close = doc.close
        if self.state.fault in ('close', 'snapshot_and_close'):
            doc.close_error = self.state.closing

        def close_document(ownership):
            self.state.events.append('document-close')
            self.state.tagged_exists_at_close = bool(self.loaded) and self.loaded[-1][0].is_file()
            self.state.lease_at_close = write_is_blocked(self.loaded[-1][0])
            return close(ownership)

        doc.close = close_document
        return doc

    def __exit__(self, error_type, error, traceback):
        self.state.events.append('server-exit')
        self.state.exit_error = error
        self.state.job_exists_at_server_exit = self.job.exists()
        self.state.loaded_exists_at_server_exit = [path.exists() for path, _, _ in self.loaded]
        return False


class WorkerPresentationBindingTest(unittest.TestCase):
    def run_case(self, *, preview=False, unsupported=False, suffix='.pptx', fault=None,
            working_drift=False, source_drift=False, apply=False, wrong_expected_hash=False,
            mode=None):
        with fixtures.PresentationBindingTest.fixture(self, mode) as case:
            members = {name: data.replace(b'cx="7200001"', b'cx="7200000"')
                if name.startswith('ppt/slides/') else data for name, data in case.members.items()}
            write_package(case.source, members.items())
            reference = case.source.parent / 'native-reference.pptx'
            reference.write_bytes(case.source.read_bytes())
            if unsupported:
                # The fake native accepts a grouped table that the strict source reader rejects.
                grouped = dict(members)
                part = 'ppt/slides/slide1.xml'
                grouped[part] = grouped[part].replace(b'<p:graphicFrame>', b'<p:grpSp><p:graphicFrame>', 1)
                grouped[part] = grouped[part].replace(b'</p:graphicFrame>', b'</p:graphicFrame></p:grpSp>', 1)
                write_package(case.source, grouped.items())
            if suffix != '.pptx':
                renamed = case.source.with_suffix(suffix)
                renamed.write_bytes(b'LEGACY FORMAT FIXTURE')
                case.source = renamed
            case.original = case.source.read_bytes()
            case.stamp = case.source.stat().st_mtime_ns
            case.sha = hashlib.sha256(case.original).hexdigest()
            job = case.source.parent / 'owned-worker-job'
            state = SimpleNamespace(events=[], primary=RuntimeError('controlled ' + str(fault) + ' failure'),
                closing=RuntimeError('controlled document close failure'), fault=fault, unsupported=unsupported,
                suffix=suffix, prepared=None, prepare_calls=[], snapshot_presentations=[], snapshot_paths=[],
                snapshot_marker_free=[], snapshot_leases=[], pdf_leases=[], result=None, caught=None,
                exit_error=None, source_drift_fired=False, tagged_exists_at_close=False, lease_at_close=False,
                prepared_file_removed=None)
            server = state.server = Server(case, job, state, reference)

            @contextmanager
            def prepare(source, directory, expected_sha256):
                state.events.append('prepare-enter')
                state.prepare_calls.append((Path(source), Path(directory), expected_sha256))
                try:
                    with REAL_PREPARE(source, directory, expected_sha256) as prepared:
                        state.prepared = prepared
                        yield prepared
                except BaseException:
                    if source_drift and state.prepared is None:
                        state.source_drift_fired = True
                        case.source.write_bytes(case.original + b'OWN TEST SOURCE DRIFT')
                    raise
                finally:
                    state.events.append('prepare-exit')
                    if state.prepared is not None and server.loaded:
                        state.prepared_file_removed = not server.loaded[-1][0].exists()
                    if fault == 'prepare_exit':
                        raise state.primary

            def snapshot(document, source_hash, context=None, presentation=None, word=None, source_path=None):
                state.events.append('snapshot')
                state.snapshot_presentations.append(presentation)
                state.snapshot_paths.append(source_path)
                state.snapshot_marker_free.append(not any(marker in page.shapes
                    for marker in case.loader.markers for page in document.DrawPages.items))
                state.snapshot_leases.append(write_is_blocked(server.loaded[-1][0]))
                if fault in ('snapshot', 'snapshot_and_close'):
                    raise state.primary
                if suffix != '.pptx':
                    return {'kind': 'word' if suffix == '.docx' else 'presentation',
                        'sourceSha256': source_hash,
                        'paragraphs': [], 'tables': [], 'slides': []}
                return REAL_SNAPSHOT(document, source_hash, context, presentation, word, source_path)

            def attach(catalog, prepared):
                state.events.append('attach')
                if fault == 'attachment':
                    raise state.primary
                return REAL_ATTACH(catalog, prepared)

            def pdf(document, path, kind):
                state.events.append('pdf')
                state.pdf_leases.append(write_is_blocked(server.loaded[-1][0]))
                self.assertTrue(all(state.snapshot_marker_free))
                if fault == 'pdf':
                    raise state.primary
                Path(path).write_bytes(b'PRIVATE TEST PDF')
                state.pdf = Path(path)
                return len(document.DrawPages.items)

            real_copy = worker.shutil.copyfile

            def copy_source(source, destination, *arguments, **keywords):
                result = real_copy(source, destination, *arguments, **keywords)
                if working_drift:
                    Path(destination).write_bytes(Path(destination).read_bytes() + b'OWN TEST WORKING DRIFT')
                return result

            request = {'mode': 'apply' if apply else 'inspect', 'sourcePath': str(case.source)}
            if preview:
                request['preview'] = True
            if apply:
                request.update(operations=[], sessionId='preserved-legacy-apply')
            if wrong_expected_hash:
                request['expectedSourceSha256'] = '0' * 64
            with patch.object(worker, 'OfficeServer', return_value=server), \
                    patch.object(binding, 'prepare_pptx_binding', new=prepare), \
                    patch.object(tables.PresentationTables, 'attach_source', new=attach), \
                    patch.object(worker, 'snapshot', new=snapshot), \
                    patch.object(worker, 'export_pdf', new=pdf), \
                    patch.object(worker.shutil, 'copyfile', new=copy_source), \
                    patch.object(worker, 'apply_operations', side_effect=state.primary) as apply_operations:
                try:
                    state.result = worker.run_request(case.source.parent / 'unused-runtime', request, job)
                except BaseException as error:
                    state.caught = error
            state.apply_calls = apply_operations.call_count
            if source_drift:
                # Restore only this test-owned mutation after observing the worker result.
                case.source.write_bytes(case.original)
                os.utime(case.source, ns=(case.source.stat().st_atime_ns, case.stamp))
            self.assertEqual(case.source.read_bytes(), case.original)
            self.assertEqual(case.source.stat().st_mtime_ns, case.stamp)
            self.assertEqual(case.sentinel.read_bytes(), b'DO NOT DELETE')
            if not apply:
                self.assertFalse(job.exists())
            state.original_source = case.source
            state.original_hash = case.sha
            return state

    def assert_prepared_lifetime(self, state):
        self.assertEqual(len(state.prepare_calls), 1)
        self.assertIsNotNone(state.prepared)
        self.assertFalse(state.prepared._active)
        self.assertEqual(state.prepare_calls[0][0], state.original_source)
        self.assertEqual(state.prepare_calls[0][1], state.server.job)
        self.assertEqual(state.prepare_calls[0][2], state.original_hash)
        self.assertEqual(len(state.server.loaded), 1)
        loaded, read_only, _ = state.server.loaded[0]
        self.assertNotEqual(loaded.name, 'working.pptx')
        self.assertTrue(read_only)
        self.assertEqual(state.server.document.close_calls, 1)
        self.assertTrue(state.tagged_exists_at_close)
        self.assertTrue(state.lease_at_close)
        self.assertTrue(state.prepared_file_removed)
        self.assertTrue(state.job_exists_at_server_exit)
        self.assertEqual(state.loaded_exists_at_server_exit, [False])
        for one, two in (('server-enter', 'load'), ('load', 'document-close'),
                ('document-close', 'prepare-exit'), ('prepare-exit', 'server-exit')):
            self.assertLess(state.events.index(one), state.events.index(two))

    def test_supported_pptx_real_snapshot_attaches_authored_geometry_before_preview_and_clean_exit(self):
        state = self.run_case(preview=True)
        self.assertIsNone(state.caught)
        self.assert_prepared_lifetime(state)
        self.assertEqual(state.snapshot_paths, [state.original_source])
        self.assertTrue(all(state.snapshot_marker_free))
        self.assertEqual(state.snapshot_leases, [True])
        self.assertEqual(state.pdf_leases, [True])
        self.assertIsNotNone(state.snapshot_presentations[0])
        snapshot = state.result['snapshot']
        self.assertEqual(snapshot['sourceSha256'], state.original_hash)
        self.assertEqual(snapshot['tables'], [])
        tables_by_id = {table['id']: table for slide in snapshot['slides'] for table in slide['presentationTables']}
        self.assertEqual(len(tables_by_id), 4)
        presentation = state.snapshot_presentations[0]
        for source in state.prepared.source_catalog['tables']:
            key = source['sourcePart'], source['shapeId']
            identifier = next(identifier for identifier, shape in presentation.shapes.items()
                if shape is state.prepared.table_refs[key])
            table = tables_by_id[identifier]
            self.assertEqual(table['authoredGeometry'], {name: source[name] for name in (
                'sourcePart', 'shapeId', 'positionEmu', 'extentEmu', 'columnWidthsEmu', 'rowHeightsEmu')})
            self.assertEqual(table['nativeBoundsHmm']['width'], 19999)
            self.assertTrue(all(value is False for value in table['capabilities'].values()))
        self.assertLess(state.events.index('attach'), state.events.index('snapshot'))
        self.assertLess(state.events.index('snapshot'), state.events.index('pdf'))
        self.assertLess(state.events.index('pdf'), state.events.index('document-close'))

    def test_supported_pptx_without_preview_uses_same_prepared_snapshot_route(self):
        state = self.run_case()
        self.assertIsNone(state.caught)
        self.assert_prepared_lifetime(state)
        self.assertNotIn('pdf', state.events)
        self.assertTrue(all(table['authoredGeometry'] is not None
            for slide in state.result['snapshot']['slides'] for table in slide['presentationTables']))

    def test_pptx_preview_preserves_merge_topology_when_uno_normalizes_covered_spans(self):
        state = self.run_case(preview=True, mode='normalized_merge')
        self.assertIsNone(state.caught)
        self.assert_prepared_lifetime(state)
        self.assertEqual(state.pdf_leases, [True])
        tables = [table for slide in state.result['snapshot']['slides'] for table in slide['presentationTables']]
        self.assertEqual(len(tables), 4)
        for table in tables:
            self.assertIsNotNone(table['authoredGeometry'])
            anchor, *covered = table['cells']
            self.assertEqual((anchor['rowSpan'], anchor['columnSpan'], anchor['covered']), (2, 2, False))
            self.assertEqual(len(covered), 3)
            for cell in covered:
                self.assertEqual((cell['rowSpan'], cell['columnSpan'], cell['covered']), (1, 1, True))
                self.assertEqual(cell['anchorCellId'], anchor['id'])

    def test_unsupported_grouped_source_falls_back_only_before_native_load_without_authored_rights(self):
        state = self.run_case(unsupported=True)
        self.assertIsNone(state.caught)
        self.assertEqual(len(state.prepare_calls), 1)
        self.assertIsNone(state.prepared)
        self.assertEqual(len(state.server.loaded), 1)
        path, read_only, data = state.server.loaded[0]
        self.assertEqual(path.name, 'working.pptx')
        self.assertFalse(read_only)
        self.assertEqual(hashlib.sha256(data).hexdigest(), state.original_hash)
        self.assertNotIn('attach', state.events)
        for slide in state.result['snapshot']['slides']:
            for table in slide['presentationTables']:
                self.assertIsNone(table['authoredGeometry'])
                self.assertTrue(all(value is False for value in table['capabilities'].values()))

    def test_unsupported_source_cannot_fallback_after_working_copy_hash_drift(self):
        state = self.run_case(unsupported=True, working_drift=True)
        self.assertIsInstance(state.caught, ValueError)
        self.assertIsNone(state.result)
        self.assertEqual(len(state.prepare_calls), 1)
        self.assertEqual(state.server.loaded, [])

    def test_unsupported_source_cannot_fallback_after_original_source_hash_drift(self):
        state = self.run_case(unsupported=True, source_drift=True)
        self.assertTrue(state.source_drift_fired)
        self.assertIsInstance(state.caught, ValueError)
        self.assertIsNone(state.result)
        self.assertEqual(state.server.loaded, [])

    def test_prepared_native_failure_is_not_retried_as_legacy_load(self):
        state = self.run_case(fault='native')
        self.assertIs(state.caught, state.primary)
        self.assertIsNone(state.result)
        self.assertIsNotNone(state.prepared)
        self.assertEqual(len(state.server.loaded), 1)
        self.assertTrue(state.server.loaded[0][1])
        self.assertTrue(state.prepared_file_removed)
        self.assertNotIn('snapshot', state.events)

    def test_attachment_failure_closes_before_prepared_exit_and_never_publishes_snapshot(self):
        state = self.run_case(fault='attachment')
        self.assertIs(state.caught, state.primary)
        self.assertIsNone(state.result)
        self.assert_prepared_lifetime(state)
        self.assertNotIn('snapshot', state.events)

    def test_snapshot_failure_keeps_original_error_and_does_not_fallback(self):
        state = self.run_case(fault='snapshot')
        self.assertIs(state.caught, state.primary)
        self.assertIsNone(state.result)
        self.assert_prepared_lifetime(state)
        self.assertNotIn('pdf', state.events)

    def test_preview_failure_keeps_original_error_and_does_not_fallback(self):
        state = self.run_case(fault='pdf', preview=True)
        self.assertIs(state.caught, state.primary)
        self.assertIsNone(state.result)
        self.assert_prepared_lifetime(state)
        # Existing inspect-preview cleanup is not claimed to remove every failed PDF here.

    def test_successful_snapshot_cannot_return_success_after_owned_document_close_failure(self):
        state = self.run_case(fault='close')
        self.assertIs(state.caught, state.closing)
        self.assertIsNone(state.result)
        self.assert_prepared_lifetime(state)

    def test_snapshot_primary_error_survives_secondary_document_close_failure(self):
        state = self.run_case(fault='snapshot_and_close')
        self.assertIs(state.caught, state.primary)
        self.assertIsNone(state.result)
        self.assert_prepared_lifetime(state)
        self.assertTrue(any('controlled document close failure' in note
            for note in getattr(state.caught, '__notes__', [])))

    def test_prepared_context_exit_failure_cannot_become_success_or_trigger_fallback(self):
        state = self.run_case(fault='prepare_exit')
        self.assertIs(state.caught, state.primary)
        self.assertIsNone(state.result)
        self.assert_prepared_lifetime(state)

    def test_wrong_requested_source_hash_is_rejected_before_binding_or_native_load(self):
        state = self.run_case(wrong_expected_hash=True)
        self.assertIsInstance(state.caught, ValueError)
        self.assertIsNone(state.result)
        self.assertEqual(state.prepare_calls, [])
        self.assertEqual(state.server.loaded, [])

    def test_other_formats_preserve_default_native_load_without_pptx_binding(self):
        for suffix in ('.docx', '.ppt', '.odp'):
            with self.subTest(suffix=suffix):
                state = self.run_case(suffix=suffix)
                self.assertIsNone(state.caught)
                self.assertEqual(state.prepare_calls, [])
                self.assertEqual(len(state.server.loaded), 1)
                self.assertFalse(state.server.loaded[0][1])
                self.assertIsNone(state.snapshot_presentations[0])

    def test_pptx_apply_keeps_legacy_default_load_and_existing_operation_dispatch(self):
        state = self.run_case(apply=True)
        self.assertIs(state.caught, state.primary)
        self.assertIsNone(state.result)
        self.assertEqual(state.prepare_calls, [])
        self.assertEqual(len(state.server.loaded), 1)
        self.assertFalse(state.server.loaded[0][1])
        self.assertEqual(state.apply_calls, 1)


if __name__ == '__main__':
    unittest.main()
