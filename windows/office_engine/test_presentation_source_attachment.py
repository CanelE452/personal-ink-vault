"""Source geometry attachment through real prepared binding and actual refs.

Root alone executes. This suite grants no text write or full-native raw authority.
"""
from contextlib import contextmanager
import copy
import hashlib
import json
import unittest

from office_presentation import Presentation
from office_presentation_binding import prepare_pptx_binding
import office_worker as worker
import test_presentation_binding as binding_fixtures
from test_presentation_source import write_package
from test_presentation_tables import Cell, TableModel


GEOMETRY_FIELDS = (
    'sourcePart', 'shapeId', 'positionEmu', 'extentEmu',
    'columnWidthsEmu', 'rowHeightsEmu',
)


class PresentationSourceAttachmentTest(unittest.TestCase):
    def attach(self, catalog, prepared):
        method = getattr(catalog, 'attach_source', None)
        self.assertTrue(callable(method),
            'BOOTSTRAP: PresentationTables.attach_source is absent; '
            'this is not attachment/native/writer evidence')
        return method(prepared)

    @contextmanager
    def loaded(self, *, unknown=False, no_source=False):
        with binding_fixtures.PresentationBindingTest.fixture(self) as case:
            case.members = {name: data.replace(b'cx="7200001"', b'cx="7200000"')
                if name.startswith('ppt/slides/') else data
                for name, data in case.members.items()}
            write_package(case.source, case.members.items())
            case.original = case.source.read_bytes()
            case.sha = hashlib.sha256(case.original).hexdigest()
            with prepare_pptx_binding(case.source, case.work, case.sha) as prepared:
                document = prepared.load(case.loader)
                try:
                    document.supportsService = lambda name: (
                        name == 'com.sun.star.presentation.PresentationDocument')
                    for shape in prepared.table_refs.values():
                        shape.Size.Width = 19999
                        if unknown:
                            shape.values['Model'].cells[0][0].unreadable_states.add('CharFontName')
                    _, slides, shapes = worker.objects(document)
                    presentation = Presentation(document, slides, shapes,
                        source_path=None if no_source else case.source)
                    yield case, prepared, presentation
                finally:
                    document.close(True)
                self.assertEqual(case.source.read_bytes(), case.original)
                self.assertEqual(document.mutations, [])

    def expected_geometry(self, source):
        return {name: copy.deepcopy(source[name]) for name in GEOMETRY_FIELDS}

    def assert_read_only(self, table):
        self.assertTrue(all(value is False for value in table['capabilities'].values()))

    def assert_atomic_rejection(self, catalog, prepared):
        before = copy.deepcopy(catalog.owners)
        with self.assertRaises(ValueError):
            self.attach(catalog, prepared)
        self.assertEqual(catalog.owners, before,
            'No earlier table may be hydrated before a later binding failure')

    def test_duplicate_tables_across_owners_attach_by_actual_refs_and_keep_width_difference(self):
        with self.loaded() as (_, prepared, presentation):
            catalog = presentation.table_catalog
            self.assertEqual(len(prepared.table_refs), 4)
            self.assertEqual(len({shape.getName() for shape in prepared.table_refs.values()}), 1)
            before = catalog.snapshot_all()
            self.assertTrue(all(item['authoredGeometry'] is None
                for items in before.values() for item in items))
            source_tables = copy.deepcopy(prepared.source_catalog['tables'])
            self.attach(catalog, prepared)
            snapshot = catalog.snapshot_all()
            for source in source_tables:
                key = source['sourcePart'], source['shapeId']
                owner_id = next(identifier for identifier, owner in presentation.slides.items()
                    if owner is prepared.owner_refs[source['sourcePart']])
                table_id = next(identifier for identifier, shape in presentation.shapes.items()
                    if shape is prepared.table_refs[key])
                table = next(item for item in snapshot[owner_id] if item['id'] == table_id)
                self.assertEqual(table['ownerId'], owner_id)
                self.assertEqual(table['authoredGeometry'], self.expected_geometry(source))
                self.assertEqual(set(table['authoredGeometry']), set(GEOMETRY_FIELDS))
                self.assertEqual(table['authoredGeometry']['extentEmu']['width'], 7200000)
                self.assertEqual(table['nativeBoundsHmm']['width'], 19999)
                for cell in table['cells']:
                    self.assertIs(prepared.cell_refs[(*key, cell['row'], cell['column'])],
                        prepared.model_refs[key].getCellByPosition(cell['column'], cell['row']))
                self.assert_read_only(table)
            empty_owner = next(identifier for identifier, owner in presentation.slides.items()
                if owner is prepared.owner_refs['ppt/slides/slide3.xml'])
            self.assertEqual(snapshot[empty_owner], [])
            self.assertEqual(snapshot, catalog.snapshot_all(),
                'Fresh capture must compare with the attached authored baseline')

    def test_known_raw_fingerprint_is_recomputed_after_geometry_attachment(self):
        with self.loaded() as (_, prepared, presentation):
            catalog = presentation.table_catalog
            before = {item['id']: item['tableSha256']
                for items in catalog.snapshot_all().values() for item in items}
            self.assertTrue(all(value is not None for value in before.values()))
            self.attach(catalog, prepared)
            for items in catalog.snapshot_all().values():
                for table in items:
                    expected = copy.deepcopy(table)
                    expected['tableSha256'] = None
                    digest = hashlib.sha256(json.dumps(expected, sort_keys=True,
                        separators=(',', ':'), ensure_ascii=False,
                        allow_nan=False).encode('utf-8')).hexdigest()
                    self.assertEqual(table['tableSha256'], digest)
                    self.assertNotEqual(table['tableSha256'], before[table['id']])
                    self.assert_read_only(table)

    def test_unknown_raw_fingerprint_stays_null_while_geometry_becomes_known(self):
        with self.loaded(unknown=True) as (_, prepared, presentation):
            catalog = presentation.table_catalog
            before = catalog.snapshot_all()
            self.assertTrue(all(item['tableSha256'] is None
                for items in before.values() for item in items))
            self.attach(catalog, prepared)
            after = catalog.snapshot_all()
            for owner_id, items in after.items():
                for index, table in enumerate(items):
                    self.assertIsNotNone(table['authoredGeometry'])
                    self.assertIsNone(table['tableSha256'])
                    self.assertEqual(table['rawStyle'], before[owner_id][index]['rawStyle'])
                    self.assertEqual(table['cells'], [{**cell, 'sourceTextPatch': None}
                        for cell in before[owner_id][index]['cells']])
                    self.assert_read_only(table)

    def test_public_catalog_and_returned_snapshot_mutation_cannot_change_attached_expectations(self):
        with self.loaded() as (_, prepared, presentation):
            catalog = presentation.table_catalog
            self.attach(catalog, prepared)
            frozen = catalog.snapshot_all()
            prepared.source_catalog['tables'][-1]['extentEmu']['width'] = 17
            prepared.source_catalog['tables'][0]['columnWidthsEmu'][0] = 18
            prepared.source_catalog['tables'].reverse()
            returned = catalog.snapshot_all()
            next(item for items in returned.values() for item in items)[
                'authoredGeometry']['rowHeightsEmu'][0] = 19
            self.assertEqual(catalog.snapshot_all(), frozen)

    def test_missing_source_and_second_attachment_are_denied(self):
        with self.loaded(no_source=True) as (_, prepared, presentation):
            self.assert_atomic_rejection(presentation.table_catalog, prepared)
        with self.loaded() as (_, prepared, presentation):
            catalog = presentation.table_catalog
            self.attach(catalog, prepared)
            self.assert_atomic_rejection(catalog, prepared)
        with self.loaded() as (_, _, presentation):
            self.assert_atomic_rejection(presentation.table_catalog, None)

    def test_ref_swap_during_revalidation_cannot_change_frozen_attachment_authority(self):
        with self.loaded() as (_, prepared, presentation):
            catalog = presentation.table_catalog
            before = copy.deepcopy(catalog.owners)
            initial_refs = dict(prepared.table_refs)
            keys = list(initial_refs)
            first = keys[0]
            second = next(key for key in keys if key != first and key[0] == first[0])
            sources = {(item['sourcePart'], item['shapeId']): item
                for item in prepared.source_catalog['tables']}
            expected = {
                next(identifier for identifier, actual in presentation.shapes.items()
                    if actual is shape): self.expected_geometry(sources[key])
                for key, shape in initial_refs.items()}
            shape = initial_refs[first]
            original_getter = shape.getPropertyValue
            fired = [False]

            def get_property(name):
                if name == 'Model' and not fired[0]:
                    fired[0] = True
                    for references in (prepared.table_refs, prepared.model_refs):
                        references[first], references[second] = references[second], references[first]
                    for row in range(2):
                        for column in range(2):
                            one, two = (*first, row, column), (*second, row, column)
                            prepared.cell_refs[one], prepared.cell_refs[two] = (
                                prepared.cell_refs[two], prepared.cell_refs[one])
                return original_getter(name)

            shape.getPropertyValue = get_property
            try:
                self.attach(catalog, prepared)
            except ValueError:
                self.assertEqual(catalog.owners, before,
                    'A rejected reference drift must leave every owner unhydrated')
            else:
                for items in catalog.snapshot_all().values():
                    for table in items:
                        self.assertEqual(table['authoredGeometry'], expected[table['id']],
                            'Post-getter public maps must not replace frozen source identity')
            self.assertTrue(fired[0], 'The controlled swap must reach real revalidation')

    def test_coherent_public_table_model_cell_ref_swap_cannot_rebind_duplicate_tables(self):
        with self.loaded() as (_, prepared, presentation):
            keys = list(prepared.table_refs)
            first = keys[0]
            second = next(key for key in keys if key != first and key[0] == first[0])
            original_source = copy.deepcopy(prepared.source_catalog)
            for references in (prepared.table_refs, prepared.model_refs):
                references[first], references[second] = references[second], references[first]
            for row in range(2):
                for column in range(2):
                    one, two = (*first, row, column), (*second, row, column)
                    prepared.cell_refs[one], prepared.cell_refs[two] = (
                        prepared.cell_refs[two], prepared.cell_refs[one])
            self.assertEqual(prepared.source_catalog, original_source)
            self.assert_atomic_rejection(presentation.table_catalog, prepared)

    def test_prepared_foreign_refs_and_inactive_state_are_rejected_atomically(self):
        for kind in ('owner', 'table', 'model', 'cell', 'inactive'):
            with self.subTest(kind=kind), self.loaded() as (_, prepared, presentation):
                keys = list(prepared.table_refs)
                selected, foreign = keys[-1], next(key for key in keys if key[0] != keys[-1][0])
                if kind == 'owner':
                    prepared.owner_refs[selected[0]] = prepared.owner_refs[foreign[0]]
                elif kind == 'table':
                    prepared.table_refs[selected] = prepared.table_refs[foreign]
                elif kind == 'model':
                    prepared.model_refs[selected] = prepared.model_refs[foreign]
                elif kind == 'cell':
                    prepared.cell_refs[(*selected, 1, 1)] = prepared.cell_refs[(*foreign, 1, 1)]
                else:
                    prepared._active = False
                self.assert_atomic_rejection(presentation.table_catalog, prepared)

    def test_live_owner_table_model_cell_and_topology_drift_are_rejected_before_hydration(self):
        for kind in ('owner', 'table', 'model', 'cell', 'topology'):
            with self.subTest(kind=kind), self.loaded() as (_, prepared, presentation):
                key = list(prepared.table_refs)[-1]
                shape, owner = prepared.table_refs[key], prepared.owner_refs[key[0]]
                model = prepared.model_refs[key]
                if kind == 'owner':
                    index = presentation.document.DrawPages.items.index(owner)
                    presentation.document.DrawPages.items[index] = binding_fixtures.Page(
                        presentation.document, owner.shapes)
                elif kind == 'table':
                    owner.shapes[owner.shapes.index(shape)] = binding_fixtures.OriginalTable(
                        shape.getName(), shape.values['Description'], model, [])
                elif kind == 'model':
                    shape.values['Model'] = TableModel(2, 2)
                elif kind == 'cell':
                    model.cells[1][1] = Cell()
                else:
                    model.cells[1][1].column_span = 2
                self.assert_atomic_rejection(presentation.table_catalog, prepared)

    def test_registry_source_hash_mismatch_is_rejected_atomically(self):
        with self.loaded() as (_, prepared, presentation):
            catalog = presentation.table_catalog
            catalog.source_sha256 = '0' * 64
            self.assert_atomic_rejection(catalog, prepared)


if __name__ == '__main__':
    unittest.main()
