"""Normal source authority on actual refs, independent of native RAW output loss.

Use real prepare/attach/snapshot APIs; root alone executes all tests.
"""
from contextlib import contextmanager, nullcontext
import copy
import hashlib
import json
import unittest
from unittest.mock import patch

from office_presentation import Presentation
from office_presentation_binding import prepare_pptx_binding
from office_presentation_text_source import cell_text_map
import office_presentation_tables as table_module
import office_worker as worker
import test_presentation_binding as binding_fixtures
from test_presentation_source import frame_xml, slide_xml, table_xml, package_members, write_package
from test_presentation_text_source import paragraph, run, source_cell
from test_presentation_tables import Paragraph, Portion, Text, Properties


BASELINE = 'SAME 😀 한글'
AUTHORITY_KEYS = {'kind', 'version', 'sourceSha256', 'sourcePart', 'shapeId', 'frameSha256'}
PROOF_KEYS = {'canReplace', 'truncated', 'text', 'utf16Length', 'textSha256', 'segments', 'protectedRanges'}
REASONS = {'field', 'hyperlink', 'comment', 'processingInstruction', 'lineBreak', 'paragraphBoundary'}


def sha(data):
    return hashlib.sha256(data).hexdigest()


def json_nodes(value):
    if isinstance(value, dict):
        return 1 + sum(1 + json_nodes(child) for child in value.values())
    if isinstance(value, list):
        return 1 + sum(map(json_nodes, value))
    return 1


def plain_body(text):
    escaped = text.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')
    return paragraph(run('<a:t>' + escaped + '</a:t>'))


def prepare_native_document(document, catalog, loader, *, core_fault=None):
    document.supportsService = lambda name: name == 'com.sun.star.presentation.PresentationDocument'
    for page in document.DrawPages.items:
        properties = Properties({'Layout': 20, 'Visible': True, 'IsBackgroundObjectsVisible': True, 'Background': None})
        page.Width, page.Height = 28000, 15750
        page.getPropertySetInfo, page.getPropertyValue = properties.getPropertySetInfo, properties.getPropertyValue
        page.getMasterPage = lambda: None
    for source in catalog['tables']:
        shape = loader.by_source[(source['sourcePart'], source['shapeId'])]
        shape.Size.Width = 19999
        for cell in source['cells']:
            native = shape.values['Model'].getCellByPosition(cell['column'], cell['row'])
            text = cell_text_map(catalog['parts'][source['sourcePart']], cell)['text']
            native.paragraphs = [Paragraph([Portion(text)])]
            native.Text = Text(native.paragraphs)
    if core_fault is not None:
        source = catalog['tables'][-1]
        cell = loader.by_source[(source['sourcePart'], source['shapeId'])].values['Model'].cells[1][1]
        if core_fault == 'mismatch':
            cell.paragraphs[0].portions[0].String = 'OTHER SAME-LENGTH TEXT'
        elif core_fault == 'unavailable':
            def unavailable(*arguments):
                raise RuntimeError('controlled native core endpoint failure')
            cell.Text.createTextCursorByRange = unavailable
    return document


class PresentationSourceEditTest(unittest.TestCase):
    @contextmanager
    def loaded(self, *, body=None, raw_lost=False, core_fault=None):
        with binding_fixtures.PresentationBindingTest.fixture(self) as case:
            body = plain_body(BASELINE) if body is None else body
            cell = source_cell(body)
            frames = [frame_xml('9', table_xml([[cell, cell], [cell, cell]])),
                frame_xml('10', table_xml([[cell, cell], [cell, cell]]))]
            slides = {'ppt/slides/slide1.xml': slide_xml(frames).replace(b'cx="7200001"', b'cx="7200000"'),
                'ppt/slides/slide2.xml': slide_xml(frames).replace(b'cx="7200001"', b'cx="7200000"'),
                'ppt/slides/slide3.xml': slide_xml()}
            members = package_members(slides, ['rIdB', 'rIdA', 'rIdC'], [
                ('rIdA', 'slides/slide1.xml', 'http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide', None),
                ('rIdB', 'slides/slide2.xml', 'http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide', None),
                ('rIdC', 'slides/slide3.xml', 'http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide', None)])
            write_package(case.source, members)
            case.original, case.stamp = case.source.read_bytes(), case.source.stat().st_mtime_ns
            case.sha = sha(case.original)
            with prepare_pptx_binding(case.source, case.work, case.sha) as prepared:
                document = prepared.load(case.loader)
                try:
                    prepare_native_document(document, prepared.source_catalog, case.loader, core_fault=core_fault)
                    raw_budget = patch.object(table_module.DocBudget, 'RAW_BYTES',
                        table_module.DocBudget.BYTE_RESERVE + 2048) if raw_lost else nullcontext()
                    with raw_budget:
                        _, slides, shapes = worker.objects(document)
                        presentation = Presentation(document, slides, shapes, source_path=case.source)
                        presentation.table_catalog.attach_source(prepared)
                        yield case, prepared, presentation
                finally:
                    document.close(True)
            self.assertEqual(case.source.read_bytes(), case.original)
            self.assertEqual(case.source.stat().st_mtime_ns, case.stamp)

    def tables(self, presentation):
        return [table for items in presentation.table_catalog.snapshot_all().values()
            if items is not None for table in items]

    def assert_authority(self, table, prepared, source):
        authority = table.get('sourceTextPatchAuthority')
        self.assertIsNotNone(authority, 'Actual attached source authority is missing')
        self.assertEqual(set(authority), AUTHORITY_KEYS)
        self.assertEqual(authority, {'kind': 'sourceTextPatch', 'version': 1,
            'sourceSha256': prepared.source_catalog['sourceSha256'], 'sourcePart': source['sourcePart'],
            'shapeId': source['shapeId'], 'frameSha256': sha(
                prepared.source_catalog['parts'][source['sourcePart']][slice(*source['frameSpan'])])})
        self.assertTrue(all(value is False for value in table['capabilities'].values()))
        return authority

    def test_attached_duplicate_tables_emit_closed_exact_source_authority_and_safe_cell_maps(self):
        with self.loaded() as (_, prepared, presentation):
            observed = {table['id']: table for table in self.tables(presentation)}
            self.assertEqual(len(observed), 4)
            for source in prepared.source_catalog['tables']:
                actual = prepared.table_refs[(source['sourcePart'], source['shapeId'])]
                table_id = next(key for key, shape in presentation.shapes.items() if shape is actual)
                table = observed[table_id]
                self.assert_authority(table, prepared, source)
                for cell in table['cells']:
                    proof = cell.get('sourceTextPatch')
                    self.assertIsNotNone(proof)
                    self.assertEqual(set(proof), PROOF_KEYS)
                    self.assertTrue(proof['canReplace'])
                    self.assertFalse(proof['truncated'])
                    self.assertEqual(proof['text'], BASELINE)
                    self.assertEqual(proof['utf16Length'], len(BASELINE.encode('utf-16-le')) // 2)
                    self.assertEqual(proof['textSha256'], sha(BASELINE.encode('utf-8')))
                    self.assertTrue(all(set(segment) == {'startUtf16', 'endUtf16', 'editable'} for segment in proof['segments']))
                    self.assertEqual(proof['protectedRanges'], [])
                    self.assertLessEqual(len(proof['segments']), 4096)

    def test_raw_output_budget_loss_does_not_grant_native_rights_or_remove_independent_complete_source_proof(self):
        with self.loaded(raw_lost=True) as (_, prepared, presentation):
            tables = self.tables(presentation)
            self.assertTrue(all(table['truncated'] and table['tableSha256'] is None for table in tables))
            self.assertTrue(all(not any(table['capabilities'].values()) for table in tables))
            self.assertTrue(any((cell.get('sourceTextPatch') or {}).get('canReplace') is True
                for table in tables for cell in table['cells']),
                'Native RAW output exhaustion must be independent of a complete short core/source text proof')

    def test_native_core_text_mismatch_or_endpoint_failure_never_becomes_raw_only_source_permission(self):
        for fault in ('mismatch', 'unavailable'):
            with self.subTest(fault=fault):
                try:
                    with self.loaded(core_fault=fault) as (_, prepared, presentation):
                        source = prepared.source_catalog['tables'][-1]
                        actual = prepared.table_refs[(source['sourcePart'], source['shapeId'])]
                        table_id = next(key for key, shape in presentation.shapes.items() if shape is actual)
                        table = next(table for table in self.tables(presentation) if table['id'] == table_id)
                        proof = next(cell for cell in table['cells'] if (cell['row'], cell['column']) == (1, 1)).get('sourceTextPatch')
                        self.assertTrue(proof is None or proof['canReplace'] is False)
                except ValueError:
                    pass

    def test_source_map_exposes_only_ranges_and_preserves_protected_reasons_without_byte_offsets(self):
        body = paragraph(run('<a:t>A<!--kept--><?kept p?>B</a:t>') +
            '<a:fld id="f" type="slidenum"><a:t>F</a:t></a:fld>' + '<a:br/>' + run('<a:t>Z</a:t>'))
        with self.loaded(body=body) as (_, _, presentation):
            proof = self.tables(presentation)[0]['cells'][0].get('sourceTextPatch')
            self.assertIsNotNone(proof)
            self.assertEqual(set(proof), PROOF_KEYS)
            self.assertTrue({'comment', 'processingInstruction', 'field', 'lineBreak'} <=
                {item['reason'] for item in proof['protectedRanges']})
            self.assertTrue(all(set(item) == {'startUtf16', 'endUtf16', 'reason'} and item['reason'] in REASONS
                for item in proof['protectedRanges']))
            self.assertTrue(all(set(item) == {'startUtf16', 'endUtf16', 'editable'} for item in proof['segments']))
            for forbidden in ('sourceSpan', 'boundaries', 'textSpan', 'runSpan', 'paragraphSpan', 'actualRef'):
                self.assertNotIn(forbidden, json.dumps(proof))

    def assert_source_budget(self, tables):
        emitted = [table['sourceTextPatchAuthority'] for table in tables if table.get('sourceTextPatchAuthority') is not None]
        proofs = [cell.get('sourceTextPatch') for table in tables for cell in table['cells']]
        emitted.extend(proof for proof in proofs if proof is not None)
        self.assertLessEqual(sum(len(json.dumps(value, ensure_ascii=False, separators=(',', ':')).encode('utf-8'))
            for value in emitted), 1024 * 1024)
        self.assertLessEqual(sum(map(json_nodes, emitted)), 32768)
        self.assertTrue(any(proof is not None and proof['canReplace'] for proof in proofs), 'The supported short core control must remain observable')
        self.assertTrue(any(proof is None or proof['truncated'] for proof in proofs), 'The full repeated output cannot bypass the shared source budget')
        self.assertTrue(all(proof is None or not proof['truncated'] or proof['canReplace'] is False for proof in proofs))

    def test_shared_source_json_byte_budget_counts_equal_text_at_each_output_location(self):
        with self.loaded(body=plain_body('한' * 24000)) as (_, _, presentation):
            self.assert_source_budget(self.tables(presentation))

    def test_shared_source_json_node_budget_bounds_many_comment_fragments_without_object_dedup(self):
        with self.loaded(body=paragraph(run('<a:t>' + 'A<!--kept-->' * 512 + 'Z</a:t>'))) as (_, _, presentation):
            self.assert_source_budget(self.tables(presentation))

    def test_returned_proof_or_public_catalog_mutation_cannot_change_frozen_source_authority(self):
        with self.loaded() as (_, prepared, presentation):
            before = presentation.table_catalog.snapshot_all()
            returned = presentation.table_catalog.snapshot_all()
            table = next(table for items in returned.values() if items for table in items)
            self.assertIsNotNone(table.get('sourceTextPatchAuthority'))
            table['sourceTextPatchAuthority']['frameSha256'] = '0' * 64
            table['cells'][0]['sourceTextPatch']['segments'].clear()
            table['cells'][0]['sourceTextPatch']['text'] = 'foreign'
            prepared.source_catalog['tables'][0]['shapeId'] = '999'
            self.assertEqual(presentation.table_catalog.snapshot_all(), before)

    def test_long_source_without_proven_complete_native_core_stays_closed(self):
        with self.loaded(body=plain_body('A' * 40000)) as (_, _, presentation):
            proof = self.tables(presentation)[0]['cells'][0].get('sourceTextPatch')
            self.assertTrue(proof is None or proof['canReplace'] is False)


if __name__ == '__main__':
    unittest.main()
