"""Private source/actual binding lifecycle; root alone executes this suite.

Missing production API is a bootstrap assertion, distinct from parser/native
behavior. Reuse the existing small source and UNO-interface fixtures.
"""
from contextlib import contextmanager
import copy
import hashlib
import importlib
import importlib.util
import io
import os
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET
import zipfile

import office_presentation_source as source_reader
from test_presentation_source import (P, A, frame_xml, slide_xml, table_xml, cell_xml,
    package_members, write_package, declared_size, SLIDE)
from test_presentation_tables import Properties, Collection, TableModel, TableShape, Cell

MODULE = (importlib.import_module('office_presentation_binding')
    if importlib.util.find_spec('office_presentation_binding') is not None
    else SimpleNamespace(prepare_pptx_binding=None))
TABLE_TYPE = 'com.sun.star.drawing.TableShape'
CONNECTOR_TYPE = 'com.sun.star.drawing.ConnectorShape'


class Shape(Properties):
    def __init__(self, name, kind, target=None):
        super().__init__({'Name': name, 'Description': '', 'Visible': True,
            **({'StartShape': target} if kind == CONNECTOR_TYPE else {})})
        self.kind = kind

    def getName(self):
        return self.values['Name']

    def getShapeType(self):
        return self.kind


class OriginalTable(TableShape):
    def __init__(self, name, description, model, mutations):
        super().__init__(model)
        self.values.update(Name=name, Description=description)
        self.types['Description'] = 'string'
        self.states.update(Name='DEFAULT_VALUE', Description='DIRECT_VALUE')
        self.mutations = mutations

    def setName(self, value):
        self.mutations.append(('Name', value))
        raise AssertionError('The binding must not set original metadata')

    def setPropertyValue(self, name, value):
        self.mutations.append((name, value))
        raise AssertionError('The binding must not set original metadata')


class Page:
    def __init__(self, document, shapes):
        self.document, self.shapes = document, list(shapes)

    @property
    def Count(self):
        return len(self.shapes)

    def getByIndex(self, index):
        return self.shapes[index]

    def remove(self, shape):
        self.document.events.append(('remove', shape))
        if self.document.remove_error is not None:
            raise self.document.remove_error
        if self.document.mode != 'remove_noop':
            self.shapes.remove(shape)
        if not self.document.after_remove_ran:
            self.document.after_remove_ran = True
            self.document.after_remove()


class Document:
    def __init__(self, mode):
        self.mode, self.events, self.mutations = mode, [], []
        self.closed, self.close_calls, self.after_remove_ran = False, 0, False
        self.remove_error = RuntimeError('controlled marker removal failure') if mode == 'remove_error' else None
        self.close_error = None
        self.after_remove = lambda: None
        self.DrawPages, self.MasterPages = Collection([]), Collection([])

    def close(self, deliver_ownership):
        self.close_calls += 1
        self.closed = True
        if self.close_error is not None:
            raise self.close_error

    def storeToURL(self, *arguments):
        raise AssertionError('Binding must not save a native document')


class Loader:
    def __init__(self, mode=None, close_error=False):
        self.mode, self.close_error = mode, close_error
        self.calls, self.paths, self.by_source, self.pages_by_source = 0, [], {}, {}
        self.document, self.members, self.information, self.comment = None, {}, {}, None

    def __call__(self, path):
        self.calls += 1
        path = Path(path)
        self.paths.append(path)
        with zipfile.ZipFile(path) as archive:
            self.comment = archive.comment
            self.members = {item.filename: archive.read(item) for item in archive.infolist()}
            self.information = {item.filename: (item.date_time, item.comment, item.external_attr, item.compress_type)
                for item in archive.infolist()}
        catalog = source_reader.read_pptx_tables(path)
        doc = self.document = Document(self.mode)
        if self.close_error:
            doc.close_error = RuntimeError('secondary close failure')
        connectors, markers, originals = [], [], []
        for part in reversed(list(catalog['parts'])):
            root = ET.fromstring(self.members[part])
            tree = root.find('{' + P + '}cSld/{' + P + '}spTree')
            actual, table_ids = [], {}
            for node in tree:
                if node.tag != '{' + P + '}graphicFrame':
                    continue
                identity = node.find('{' + P + '}nvGraphicFramePr/{' + P + '}cNvPr')
                source = next(item for item in catalog['tables']
                    if (item['sourcePart'], item['shapeId']) == (part, identity.attrib['id']))
                model = TableModel(len(source['rowHeightsEmu']), len(source['columnWidthsEmu']))
                for cell in source['cells']:
                    native = model.cells[cell['row']][cell['column']]
                    native.row_span, native.column_span, native.covered = cell['rowSpan'], cell['columnSpan'], cell['covered']
                    if self.mode in ('normalized_merge', 'invalid_covered_span') and native.covered:
                        native.row_span = native.column_span = 1
                        if self.mode == 'invalid_covered_span' and (cell['row'], cell['column']) == (0, 1):
                            native.column_span = 2
                shape = OriginalTable(identity.attrib['name'], identity.attrib.get('descr', ''), model, doc.mutations)
                table_ids[identity.attrib['id']] = shape
                self.by_source[(part, identity.attrib['id'])] = shape
                originals.append(shape)
                actual.append(shape)
            for node in tree:
                if node.tag not in ('{' + P + '}sp', '{' + P + '}cxnSp'):
                    continue
                identity = next(item for item in node.iter() if item.tag == '{' + P + '}cNvPr')
                if node.tag == '{' + P + '}cxnSp':
                    start = node.find('{' + P + '}nvCxnSpPr/{' + P + '}cNvCxnSpPr/{' + A + '}stCxn')
                    marker = Shape(identity.attrib['name'], CONNECTOR_TYPE, table_ids.get(start.attrib['id']))
                    connectors.append(marker)
                else:
                    marker = Shape(identity.attrib['name'], 'com.sun.star.drawing.CustomShape')
                markers.append(marker)
                actual.append(marker)
            page = Page(doc, reversed(actual))
            self.pages_by_source[part] = page
            doc.DrawPages.items.append(page)
        owners = [shape for shape in markers if shape.kind != CONNECTOR_TYPE]
        page_for = lambda shape: next(page for page in doc.DrawPages.items if shape in page.shapes)
        if self.mode in ('missing_owner', 'missing_connector'):
            missing = owners[0] if self.mode == 'missing_owner' else connectors[0]
            page_for(missing).shapes.remove(missing)
        elif self.mode in ('duplicate_owner', 'duplicate_connector'):
            previous = owners[0] if self.mode == 'duplicate_owner' else connectors[0]
            page_for(previous).shapes.append(Shape(previous.getName(), previous.kind, previous.values.get('StartShape')))
        elif self.mode == 'foreign_connector':
            owner = page_for(connectors[0])
            connectors[0].values['StartShape'] = next(shape for shape in originals if shape not in owner.shapes)
        elif self.mode == 'duplicate_target':
            connectors[1].values['StartShape'] = connectors[0].values['StartShape']
        elif self.mode == 'missing_model':
            originals[0].values['Model'] = None
        elif self.mode == 'shared_model':
            originals[1].values['Model'] = originals[0].values['Model']
        elif self.mode == 'shared_cell':
            originals[1].values['Model'].cells[0][0] = originals[0].values['Model'].cells[0][0]
        elif self.mode == 'grid':
            originals[0].values['Model'].rows.items.pop()
        elif self.mode == 'span':
            originals[0].values['Model'].cells[0][0].column_span = 2
        elif self.mode == 'covered':
            originals[0].values['Model'].cells[0][0].covered = True

        def after_remove():
            original = originals[0]
            model = original.values['Model']
            page = page_for(original)
            if self.mode == 'stale_owner':
                doc.DrawPages.items[doc.DrawPages.items.index(page)] = Page(doc, page.shapes)
            elif self.mode == 'stale_table':
                page.shapes[page.shapes.index(original)] = OriginalTable(original.values['Name'],
                    original.values['Description'], model, doc.mutations)
            elif self.mode == 'stale_model':
                original.values['Model'] = TableModel(2, 2)
            elif self.mode == 'stale_cell':
                model.cells[0][0] = Cell()
            elif self.mode == 'metadata_state':
                original.states['Name'] = 'DIRECT_VALUE'
        doc.after_remove = after_remove
        self.markers = markers
        return doc


class PresentationBindingTest(unittest.TestCase):
    def api(self):
        prepare = getattr(MODULE, 'prepare_pptx_binding', None)
        self.assertTrue(callable(prepare),
            'BOOTSTRAP: prepare_pptx_binding is not implemented; this is not binding behavior evidence')
        return prepare

    @contextmanager
    def fixture(self, mode=None, *, merged=False, close_error=False):
        with TemporaryDirectory(prefix='piv-ppt-binding-') as temporary:
            root = Path(temporary)
            work = root / 'private'
            work.mkdir()
            sentinel = work / 'unrelated.keep'
            sentinel.write_bytes(b'DO NOT DELETE')
            table = (table_xml([[cell_xml(attributes=' gridSpan="2"'), cell_xml(attributes=' hMerge="1"')],
                [cell_xml(), cell_xml()]]) if merged else None)
            if mode in ('normalized_merge', 'invalid_covered_span'):
                table = table_xml([
                    [cell_xml(attributes=' rowSpan="2" gridSpan="2"'), cell_xml(attributes=' rowSpan="2" hMerge="1"')],
                    [cell_xml(attributes=' gridSpan="2" vMerge="1"'), cell_xml(attributes=' hMerge="1" vMerge="1"')],
                ])
            frames = [frame_xml('9', table), frame_xml('10', table)]
            slides = {'ppt/slides/slide1.xml': slide_xml(frames),
                'ppt/slides/slide2.xml': slide_xml(frames), 'ppt/slides/slide3.xml': slide_xml()}
            members = package_members(slides, ['rIdB', 'rIdA', 'rIdC'], [
                ('rIdA', 'slides/slide1.xml', SLIDE, None), ('rIdB', 'slides/slide2.xml', SLIDE, None),
                ('rIdC', 'slides/slide3.xml', SLIDE, None)])
            source = root / 'original.pptx'
            write_package(source, members)
            original, stamp = source.read_bytes(), source.stat().st_mtime_ns
            loader = Loader(mode, close_error)
            try:
                yield SimpleNamespace(source=source, work=work, original=original, stamp=stamp,
                    sha=hashlib.sha256(original).hexdigest(), loader=loader, members=dict(members), sentinel=sentinel)
            finally:
                self.assertEqual(sentinel.read_bytes(), b'DO NOT DELETE')

    def reject_load(self, mode, *, close_error=False):
        prepare = self.api()
        with self.fixture(mode, close_error=close_error) as case:
            with prepare(case.source, case.work, case.sha) as prepared:
                with self.assertRaises((ValueError, RuntimeError)) as failure:
                    prepared.load(case.loader)
                self.assertTrue(case.loader.document.closed)
                self.assertEqual(case.loader.document.close_calls, 1)
                self.assertEqual(case.loader.document.mutations, [])
                self.assertEqual(case.source.read_bytes(), case.original)
                if mode == 'remove_error':
                    self.assertIs(failure.exception, case.loader.document.remove_error)
                with self.assertRaises((ValueError, RuntimeError)):
                    prepared.load(case.loader)
                self.assertEqual(case.loader.calls, 1)
            self.assertTrue(all(not path.exists() for path in case.loader.paths))
            self.assertEqual(list(case.work.iterdir()), [case.sentinel])

    def test_prepare_api_is_explicit(self):
        self.api()

    def test_duplicate_two_owners_and_empty_owner_bind_only_exact_refs_after_markers_removed(self):
        prepare = self.api()
        with self.fixture() as case:
            expected = source_reader.read_pptx_tables(case.source)
            with prepare(case.source, case.work, case.sha) as prepared:
                self.assertEqual(prepared.source_catalog, expected)
                doc = prepared.load(case.loader)
                self.assertIs(doc, case.loader.document)
                self.assertFalse(doc.closed)
                self.assertEqual(prepared.owner_refs, case.loader.pages_by_source)
                self.assertEqual(prepared.table_refs, case.loader.by_source)
                self.assertEqual(len(prepared.model_refs), 4)
                self.assertEqual(len(prepared.cell_refs), 16)
                for key, shape in case.loader.by_source.items():
                    self.assertIs(prepared.model_refs[key], shape.values['Model'])
                    for row in range(2):
                        for column in range(2):
                            self.assertIs(prepared.cell_refs[(*key, row, column)], shape.values['Model'].cells[row][column])
                self.assertEqual(sorted(page.Count for page in doc.DrawPages.items), [0, 2, 2])
                self.assertEqual(len([event for event in doc.events if event[0] == 'remove']), 7)
                self.assertTrue(all(marker.values['Visible'] is True for marker in case.loader.markers))
                self.assertTrue(all(marker not in page.shapes for marker in case.loader.markers for page in doc.DrawPages.items))
                self.assertEqual(doc.mutations, [])
                self.assertTrue(case.loader.paths[0].exists())
                doc.close(True)
            self.assertFalse(case.loader.paths[0].exists())
            self.assertEqual(case.source.read_bytes(), case.original)
            self.assertEqual(case.source.stat().st_mtime_ns, case.stamp)

    def test_same_image_unrelated_members_and_source_table_bytes_are_preserved_for_owned_lifetime(self):
        prepare = self.api()
        with self.fixture() as case:
            with zipfile.ZipFile(case.source) as source:
                information = {item.filename: (item.date_time, item.comment, item.external_attr, item.compress_type)
                    for item in source.infolist()}
                comment = source.comment
            original_catalog = source_reader.read_pptx_tables(case.source)
            with prepare(case.source, case.work, case.sha) as prepared:
                doc = prepared.load(case.loader)
                tagged = case.loader.paths[0]
                self.assertNotEqual(tagged, case.source)
                self.assertEqual(set(case.loader.members), set(case.members))
                self.assertEqual(case.loader.comment, comment)
                self.assertEqual(case.loader.information, information)
                for name, original in case.members.items():
                    if name not in original_catalog['parts']:
                        self.assertEqual(case.loader.members[name], original)
                tagged_catalog = source_reader.read_pptx_tables(tagged)
                for original, after in zip(original_catalog['tables'], tagged_catalog['tables']):
                    self.assertEqual((after['sourcePart'], after['shapeId']), (original['sourcePart'], original['shapeId']))
                    self.assertEqual(original_catalog['parts'][original['sourcePart']][slice(*original['frameSpan'])],
                        tagged_catalog['parts'][after['sourcePart']][slice(*after['frameSpan'])])
                doc.close(True)
            self.assertEqual(list(case.work.iterdir()), [case.sentinel])
            self.assertEqual(case.source.read_bytes(), case.original)

    def test_load_is_exactly_once_even_after_success(self):
        prepare = self.api()
        with self.fixture() as case:
            with prepare(case.source, case.work, case.sha) as prepared:
                doc = prepared.load(case.loader)
                with self.assertRaises((ValueError, RuntimeError)):
                    prepared.load(case.loader)
                self.assertEqual(case.loader.calls, 1)
                doc.close(True)

    def test_missing_and_duplicate_exact_tokens_reject_without_returning_doc(self):
        for mode in ('missing_owner', 'missing_connector', 'duplicate_owner', 'duplicate_connector'):
            with self.subTest(mode=mode):
                self.reject_load(mode)

    def test_start_shape_must_be_unique_actual_table_in_exact_bound_owner(self):
        for mode in ('foreign_connector', 'duplicate_target', 'missing_model'):
            with self.subTest(mode=mode):
                self.reject_load(mode)

    def test_models_and_cells_must_not_alias_between_source_tables(self):
        for mode in ('shared_model', 'shared_cell'):
            with self.subTest(mode=mode):
                self.reject_load(mode)

    def test_actual_grid_anchor_and_covered_topology_must_match_source(self):
        for mode in ('grid', 'span', 'covered', 'invalid_covered_span'):
            with self.subTest(mode=mode):
                self.reject_load(mode)

    def test_source_merged_anchor_and_distinct_covered_cell_refs_are_supported(self):
        prepare = self.api()
        with self.fixture(merged=True) as case:
            with prepare(case.source, case.work, case.sha) as prepared:
                doc = prepared.load(case.loader)
                for key, model in prepared.model_refs.items():
                    self.assertEqual(model.cells[0][0].getColumnSpan(), 2)
                    self.assertFalse(model.cells[0][0].isMerged())
                    self.assertTrue(model.cells[0][1].isMerged())
                    self.assertIsNot(prepared.cell_refs[(*key, 0, 0)], prepared.cell_refs[(*key, 0, 1)])
                doc.close(True)

    def test_stale_actual_refs_or_metadata_state_during_marker_removal_close_without_publication(self):
        for mode in ('stale_owner', 'stale_table', 'stale_model', 'stale_cell', 'metadata_state', 'remove_noop'):
            with self.subTest(mode=mode):
                self.reject_load(mode)

    def test_failed_remove_preserves_primary_error_even_if_owned_close_also_fails(self):
        for close_error in (False, True):
            with self.subTest(close_error=close_error):
                self.reject_load('remove_error', close_error=close_error)

    def test_wrong_source_hash_never_invokes_loader_or_changes_source_or_unrelated_files(self):
        prepare = self.api()
        with self.fixture() as case:
            with self.assertRaises(ValueError):
                with prepare(case.source, case.work, '0' * 64) as prepared:
                    prepared.load(case.loader)
            self.assertEqual(case.loader.calls, 0)
            self.assertEqual(list(case.work.iterdir()), [case.sentinel])
            self.assertEqual(case.source.read_bytes(), case.original)

    def test_source_path_changed_after_prepare_is_rejected_before_native_load(self):
        prepare = self.api()
        with self.fixture() as case:
            with self.assertRaises(ValueError):
                with prepare(case.source, case.work, case.sha) as prepared:
                    case.source.write_bytes(case.original + b'OWN FIXTURE CHANGE')
                    try:
                        with self.assertRaises(ValueError):
                            prepared.load(case.loader)
                    finally:
                        case.source.write_bytes(case.original)
            self.assertEqual(case.loader.calls, 0)
            self.assertEqual(list(case.work.iterdir()), [case.sentinel])

    def test_context_body_failure_removes_only_owned_tagged_file(self):
        prepare = self.api()
        with self.fixture() as case:
            with self.assertRaisesRegex(RuntimeError, 'caller failed after closing'):
                with prepare(case.source, case.work, case.sha) as prepared:
                    doc = prepared.load(case.loader)
                    doc.close(True)
                    raise RuntimeError('caller failed after closing')
            self.assertTrue(all(not path.exists() for path in case.loader.paths))
            self.assertEqual(list(case.work.iterdir()), [case.sentinel])
            self.assertEqual(case.source.read_bytes(), case.original)

    def reject_copy_budget_before_media_or_output_members(self, case):
        prepare = self.api()
        original = case.source.read_bytes()
        modified = case.source.stat().st_mtime_ns
        opened_media, written_members = [], []
        native_open = zipfile.ZipFile.open

        def observed_open(archive, member, mode='r', *arguments, **keywords):
            name = member.filename if isinstance(member, zipfile.ZipInfo) else member
            if mode == 'r' and str(name).startswith('ppt/media/'):
                opened_media.append(name)
            if mode == 'w':
                written_members.append(name)
            return native_open(archive, member, mode, *arguments, **keywords)

        with patch.object(zipfile.ZipFile, 'open', new=observed_open):
            with self.assertRaises((ValueError, zipfile.BadZipFile)):
                with prepare(case.source, case.work, hashlib.sha256(original).hexdigest()) as prepared:
                    prepared.load(case.loader)
        self.assertEqual(opened_media, [], 'Expanded-copy budget must reject before any media inflation')
        self.assertEqual(written_members, [], 'Expanded-copy budget must reject before writing tagged ZIP members')
        self.assertEqual(case.loader.calls, 0)
        self.assertEqual(case.source.read_bytes(), original)
        self.assertEqual(case.source.stat().st_mtime_ns, modified)
        self.assertEqual(list(case.work.iterdir()), [case.sentinel])

    def test_unrelated_media_over_private_expanded_copy_cap_rejects_before_inflation(self):
        with self.fixture() as case:
            declared_size(case.source, 'ppt/media/unrelated.bin', 128 * 1024 * 1024 + 1)
            self.assertLess(case.source.stat().st_size, 32768)
            self.reject_copy_budget_before_media_or_output_members(case)

    def test_aggregate_expanded_copy_cap_rejects_members_individually_under_cap_before_writes(self):
        with self.fixture() as case:
            write_package(case.source, [*case.members.items(), ('ppt/media/second.bin', b'SMALL SECOND MEDIA')])
            size = 64 * 1024 * 1024 + 1
            declared_size(case.source, 'ppt/media/unrelated.bin', size)
            declared_size(case.source, 'ppt/media/second.bin', size)
            with zipfile.ZipFile(case.source) as archive:
                self.assertTrue(all(item.file_size < 128 * 1024 * 1024 for item in archive.infolist()))
                self.assertGreater(sum(item.file_size for item in archive.infolist()), 128 * 1024 * 1024)
            self.assertLess(case.source.stat().st_size, 32768)
            self.reject_copy_budget_before_media_or_output_members(case)

    def test_tagged_same_length_aba_during_loader_cannot_publish_doc_from_different_bytes(self):
        prepare = self.api()
        with self.fixture() as case:
            state = {'blocked': False, 'swapped': False, 'wrong_document': False, 'rejected': False}

            def aba_loader(path):
                path = Path(path)
                stamp, original = path.stat(), path.read_bytes()
                rewritten = io.BytesIO()
                replacements = 0
                with zipfile.ZipFile(io.BytesIO(original)) as source, zipfile.ZipFile(rewritten, 'w') as output:
                    output.comment = source.comment
                    for information in source.infolist():
                        payload = source.read(information)
                        if information.filename.startswith('ppt/slides/') and information.filename.endswith('.xml'):
                            replacements += payload.count(b'name="Duplicate')
                            payload = payload.replace(b'name="Duplicate', b'name="WRONGNAME')
                        output.writestr(copy.copy(information), payload)
                different = rewritten.getvalue()
                self.assertEqual(replacements, 4)
                self.assertEqual(len(different), len(original))
                self.assertNotEqual(hashlib.sha256(different).digest(), hashlib.sha256(original).digest())
                try:
                    try:
                        path.write_bytes(different)
                        state['swapped'] = True
                    except OSError as error:
                        if not isinstance(error, PermissionError) and getattr(error, 'winerror', None) != 32:
                            raise
                        state['blocked'] = True
                        self.assertEqual(path.read_bytes(), original)
                    doc = case.loader(path)
                    state['wrong_document'] = any(shape.values['Name'].startswith('WRONGNAME')
                        for shape in case.loader.by_source.values())
                    return doc
                finally:
                    if state['swapped']:
                        path.write_bytes(original)
                        os.utime(path, ns=(stamp.st_atime_ns, stamp.st_mtime_ns))
                        self.assertEqual(path.read_bytes(), original)
                        self.assertEqual(path.stat().st_mtime_ns, stamp.st_mtime_ns)

            with prepare(case.source, case.work, case.sha) as prepared:
                try:
                    doc = prepared.load(aba_loader)
                except (ValueError, PermissionError):
                    state['rejected'] = True
                    if case.loader.document is not None:
                        self.assertTrue(case.loader.document.closed)
                else:
                    doc.close(True)
            self.assertEqual(case.loader.calls, 1, 'The valid control must reach the native-consumption boundary')
            self.assertTrue(state['blocked'] or state['rejected'],
                'Restoring tagged bytes/hash/mtime must not authorize a document consumed from different bytes')
            if state['swapped']:
                self.assertTrue(state['wrong_document'], 'The ABA control must actually consume the changed valid ZIP')
            self.assertEqual(case.source.read_bytes(), case.original)
            self.assertEqual(case.source.stat().st_mtime_ns, case.stamp)
            self.assertEqual(list(case.work.iterdir()), [case.sentinel])


if __name__ == '__main__':
    unittest.main()
