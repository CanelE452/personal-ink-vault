"""Source-authorized real PPT table additions with independent bound observers."""
import copy
import os
from pathlib import Path
import re

import office_presentation_binding as binding
import office_presentation_package_patch as package_writer
import office_presentation_source as source_reader
import office_presentation_source_edit as text_edit
import office_presentation_structure as structure
from office_presentation_tables import matches_source_cell_topology
from office_presentation_text_source import cell_text_map


FIELDS = frozenset(('op', 'authorityVersion', 'id', 'ownerId', 'expectedSourceSha256', 'sourcePart',
    'expectedSourcePartSha256', 'expectedShapeIdInventorySha256', 'xMm', 'yMm', 'columnWidthsMm', 'rowHeightsMm'))
PLAN_KEYS = frozenset(('converted', 'parts', 'expected_native', 'expected_core', 'source_order',
    'owner_ledger', 'additions', 'base_snapshot'))
OWNER_FIELDS = frozenset(('shapes', 'presentationTables', 'presentationTableCount', 'presentationTablesTruncated',
    'presentationTablesUnknownReason', 'canAddTable', 'sourceStructureAuthority'))
GEOMETRY = ('sourcePart', 'shapeId', 'positionEmu', 'extentEmu', 'columnWidthsEmu', 'rowHeightsEmu')
_require = text_edit._require
_sha = text_edit._sha


def _inventory(data):
    root = source_reader._xml(data, {'nodes': 0})
    identifiers = sorted(source_reader._identity(node.attributes.get('id')) for node in source_reader._walk(root)
        if node.name == source_reader.P + 'cNvPr')
    _require(len(identifiers) == len(set(identifiers)), 'The source shape identity inventory is ambiguous')
    return _sha(text_edit._canonical(identifiers).encode('utf-8')), len(identifiers)


def _source_binding(catalog):
    state = getattr(catalog, '_source_text_state', None)
    parts = getattr(catalog, '_source_owner_parts', {})
    if state is None or not parts:
        return None
    source = state['catalog']
    _require(source['sourceSha256'] == catalog.source_sha256 == catalog._source_digest(),
        'The attached structure source changed')
    expected_parts = set(source['parts'])
    _require(set(parts) == set(catalog.presentation.logical) and set(parts.values()) == expected_parts and
        len(parts) == len(expected_parts), 'The attached structure owner coverage is incomplete')
    catalog._live_source_owners(catalog._source_owner_refs)
    for owner_id, part in parts.items():
        owner = catalog.owner_refs.get(owner_id)
        _require(owner is not None and catalog.presentation.owner(owner_id) == owner and
            catalog._source_owner_refs.get(owner_id) == owner, 'An attached structure owner was replaced')
        actual = [item for item in source['tables'] if item['sourcePart'] == part]
        references = catalog.table_refs.get(owner_id)
        observed = catalog.owners.get(owner_id)
        _require(references is not None and observed is not None and len(references) == len(actual) == len(observed),
            'The attached structure table inventory is incomplete')
        from office_presentation_tables import actual_tables
        current = actual_tables(catalog.presentation, owner_id)
        _require(len(current) == len(references) and all(identifier == old_id and shape == old_shape
            for (identifier, shape), (old_id, old_shape) in zip(current, references)),
            'An attached structure table inventory changed')
    return state


def _complete_core(catalog, state):
    budget = text_edit.SourcePatchBudget().native_budget
    complete = True
    for identifier, entry in state['tables'].items():
        shape, model = entry['shape'], entry['model']
        _require(catalog.presentation.shapes.get(identifier) == shape and shape.getPropertyValue('Model') == model,
            'An attached structure table or Model was replaced')
        source = entry['source']
        _require(model.getRows().getCount() == len(source['rowHeightsEmu']) and
            model.getColumns().getCount() == len(source['columnWidthsEmu']), 'An attached structure grid changed')
        for coordinate, record in entry['cells'].items():
            actual = model.getCellByPosition(coordinate[1], coordinate[0])
            _require(actual == record['actual'], 'An attached structure cell was replaced')
            expected = record['source']
            _require(matches_source_cell_topology(actual.getRowSpan(), actual.getColumnSpan(),
                actual.isMerged(), expected), 'An attached structure partition changed')
            core = text_edit.native_core_text(actual, budget)
            try:
                mapped = cell_text_map(state['catalog']['parts'][source['sourcePart']], expected)['text']
            except ValueError:
                complete = False
            else:
                complete = complete and core is not None and core == mapped
    return complete


def source_authority(catalog, owner_id):
    if owner_id not in getattr(catalog, '_source_owner_parts', {}) or owner_id not in catalog.presentation.logical:
        return None
    state = _source_binding(catalog)
    if state is None:
        return None
    part = catalog._source_owner_parts[owner_id]
    data = state['catalog']['parts'][part]
    inventory_hash, count = _inventory(data)
    tables = state['catalog']['tables']
    complete = _complete_core(catalog, state)
    for identifier in [*catalog.presentation.logical, *catalog.presentation.masters]:
        observed = catalog.owners.get(identifier)
        complete = complete and observed is not None and len(observed) == catalog.counts.get(identifier)
        if identifier not in catalog._source_owner_parts and observed:
            complete = False
    return {'kind': 'sourceStructure', 'version': 1, 'sourceSha256': catalog.source_sha256,
        'sourcePart': part, 'partSha256': _sha(data), 'shapeIdInventorySha256': inventory_hash,
        'shapeIdCount': count, 'canAddTable': complete and len(tables) < structure.MAX_TABLES and
            sum(len(table['cells']) for table in tables) < structure.MAX_CELLS}


def validate_batch(operations, source_hash):
    _require(package_writer._hash_value(source_hash) and type(operations) is list and 1 <= len(operations) <= 100,
        'A bounded source structure-only batch and exact original source hash are required')
    aliases = set()
    for operation in operations:
        _require(type(operation) is dict and set(operation) == FIELDS and
            operation['op'] == 'presentationSourceTableAdd' and type(operation['authorityVersion']) is int and
            operation['authorityVersion'] == 1, 'Invalid closed source table addition operation/version')
        alias, owner, part = operation['id'], operation['ownerId'], operation['sourcePart']
        _require(type(alias) is str and re.fullmatch(r'new-table-[A-Za-z0-9_-]{1,64}', alias) is not None and
            alias not in aliases, 'A source table addition requires a unique bounded alias')
        aliases.add(alias)
        _require(type(owner) is str and 0 < len(owner) <= 256 and all(ord(value) >= 32 for value in owner),
            'Invalid actual source owner identity')
        _require(type(part) is str and len(part) <= 1024 and not part.endswith('/') and
            source_reader._member_name(part) == part,
            'Invalid exact source slide part')
        _require(all(package_writer._hash_value(operation[name]) for name in
            ('expectedSourceSha256', 'expectedSourcePartSha256', 'expectedShapeIdInventorySha256')) and
            operation['expectedSourceSha256'] == source_hash, 'The source table addition guards are stale')
        structure._mm(operation['xMm'])
        structure._mm(operation['yMm'])
        widths, heights = structure._sizes(operation['columnWidthsMm']), structure._sizes(operation['rowHeightsMm'])
        _require(len(widths) * len(heights) <= structure.MAX_CELLS, 'The new source cell grid exceeds its budget')


def _owner_metadata(owner):
    return copy.deepcopy({key: value for key, value in owner.items() if key not in OWNER_FIELDS})


def _non_table_shapes(owner):
    return copy.deepcopy([shape for shape in owner['shapes'] if shape['type'] != 'com.sun.star.drawing.TableShape'])


def _plan(catalog, prepared, origin, operations):
    catalog._revalidate(False)
    state = _source_binding(catalog)
    _require(state is not None, 'A complete actual source-owner binding is required for table addition')
    source = state['catalog']
    structure._budget(source['tables'])
    parts, converted = dict(source['parts']), []
    for public in operations:
        authority = source_authority(catalog, public['ownerId'])
        _require(authority is not None and authority['canAddTable'] and
            public['expectedSourceSha256'] == authority['sourceSha256'] and
            public['sourcePart'] == authority['sourcePart'] and
            public['expectedSourcePartSha256'] == authority['partSha256'] and
            public['expectedShapeIdInventorySha256'] == authority['shapeIdInventorySha256'],
            'A source table addition has stale or foreign original owner/part/inventory guards')
        part = public['sourcePart']
        operation = {name: copy.deepcopy(public[name]) for name in ('sourcePart', 'xMm', 'yMm', 'columnWidthsMm', 'rowHeightsMm')}
        operation['expectedSourcePartSha256'] = _sha(parts[part])
        inserted = structure.add_table_part(parts[part], part, operation)
        parts[part] = inserted['partBytes']
        converted.append(operation)
    changed, _, writer_ledger = structure._plan(source, converted)
    _require(parts == {part: changed.get(part, data) for part, data in source['parts'].items()},
        'The sequential structure plan differs from the exact writer ledger')
    additions = []
    for public, record in zip(operations, writer_ledger):
        _require(record['sourcePart'] == public['sourcePart'] and record['shapeId'] == record['table']['shapeId'],
            'The source writer addition identity is inconsistent')
        additions.append({'alias': public['id'], **copy.deepcopy(record['table'])})
    expected_native = text_edit._native_by_source(catalog, origin)
    expected_core = text_edit._core_by_source(catalog)
    _require(all(type(core) is str for cells in expected_core.values() for core in cells),
        'The complete original native core text is unavailable')
    for addition in additions:
        key = addition['sourcePart'] + '#' + addition['shapeId']
        _require(key not in expected_core, 'The writer reused an existing exact source table identity')
        expected_core[key] = [''] * len(addition['cells'])
    ledger = []
    for part in source['parts']:
        reference = prepared._bound_refs['owner_refs'][part]
        indices = [index for index, owner_id in enumerate(catalog.presentation.logical)
            if catalog.presentation.slides[owner_id] == reference]
        _require(len(indices) == 1, 'A bound original source owner has no unique actual ordinal')
        ordinal = indices[0]
        _require(catalog.document.DrawPages.getByIndex(ordinal) == reference, 'The original source owner order changed')
        owner = origin['slides'][ordinal]
        keys = [table['sourcePart'] + '#' + table['shapeId'] for table in source['tables'] if table['sourcePart'] == part]
        ledger.append({'sourcePart': part, 'ordinal': ordinal, 'metadata': _owner_metadata(owner),
            'nonTableShapes': _non_table_shapes(owner), 'keys': keys,
            'pairs': [(copy.deepcopy(expected_native[key]), copy.deepcopy(expected_core[key])) for key in keys],
            'additions': [copy.deepcopy(addition) for addition in additions if addition['sourcePart'] == part]})
    _require(sorted(owner['ordinal'] for owner in ledger) == list(range(len(source['parts']))),
        'The original owner ledger does not cover every actual page')
    return {'converted': converted, 'parts': parts, 'expected_native': expected_native, 'expected_core': expected_core,
        'source_order': list(source['parts']), 'owner_ledger': sorted(ledger, key=lambda item: item['ordinal']),
        'additions': additions, 'base_snapshot': copy.deepcopy(origin)}


def plan_source_structure_edit(runtime, source, source_hash, operations, input_job,
        *, server_factory, objects, snapshot):
    validate_batch(operations, source_hash)
    with server_factory(runtime, input_job) as server:
        with binding.prepare_pptx_binding(source, input_job, source_hash) as prepared:
            document, primary = None, None
            try:
                document = prepared.load(lambda path: server.load(path, read_only=True))
                presentation = text_edit._with_presentation(document, source, objects)
                presentation.table_catalog.attach_source(prepared)
                origin = snapshot(document, source_hash, server.context, presentation=presentation, source_path=source)
                plan = _plan(presentation.table_catalog, prepared, origin, operations)
            except BaseException as error:
                primary = error
                raise
            finally:
                if document is not None:
                    text_edit._close(document, primary)
    return plan


def _plan_keys(plan):
    _require(type(plan) is dict and set(plan) == PLAN_KEYS and type(plan['parts']) is dict and
        list(plan['parts']) == plan['source_order'], 'Invalid closed source structure plan')
    additions = {item['sourcePart'] + '#' + item['shapeId']: item for item in plan['additions']}
    _require(len(additions) == len(plan['additions']) and
        len({item['alias'] for item in plan['additions']}) == len(additions) and
        set(plan['expected_core']) == set(plan['expected_native']) | set(additions) and
        not set(plan['expected_native']) & set(additions), 'The source structure plan table coverage is inconsistent')
    return additions


def _verify_new_table(catalog, prepared, table, addition, core):
    key = addition['sourcePart'], addition['shapeId']
    reference = prepared._bound_refs['table_refs'][key]
    model = prepared._bound_refs['model_refs'][key]
    _require(catalog.presentation.shapes.get(table['id']) == reference and reference.getPropertyValue('Model') == model,
        'The new source table has no exact actual TableShape/Model binding')
    rows, columns = len(addition['rowHeightsEmu']), len(addition['columnWidthsEmu'])
    _require(table['rowCount'] == rows and table['columnCount'] == columns and
        table['totalCellCount'] == rows * columns and len(table['cells']) == rows * columns and
        model.getRows().getCount() == rows and model.getColumns().getCount() == columns,
        'The complete new actual native table grid is unavailable')
    _require(table['authoredGeometry'] == {name: addition[name] for name in GEOMETRY},
        'The new authored geometry differs from the request-derived source frame')
    _require(table['columnWidthsHmm'] == [value // 360 for value in addition['columnWidthsEmu']] and
        table['rowHeightsHmm'] == [value // 360 for value in addition['rowHeightsEmu']],
        'The new actual table Model did not retain the exact requested row/column dimensions')
    _require(all(value is False for value in table['capabilities'].values()),
        'Source table construction must not grant native full-RAW mutation rights')
    actual = {(cell['row'], cell['column']): cell for cell in table['cells']}
    _require(len(actual) == rows * columns and len(core) == rows * columns and all(value == '' for value in core),
        'The complete new native cell coordinates or full empty core text differ')
    for expected in addition['cells']:
        coordinate = expected['row'], expected['column']
        _require(coordinate in actual, 'A new actual native source cell is missing')
        cell = actual[coordinate]
        reference = prepared._bound_refs['cell_refs'][(*key, *coordinate)]
        _require(model.getCellByPosition(coordinate[1], coordinate[0]) == reference and
            (reference.getRowSpan(), reference.getColumnSpan(), reference.isMerged()) ==
                (expected['rowSpan'], expected['columnSpan'], expected['covered']) and
            (cell['rowSpan'], cell['columnSpan'], cell['covered'], cell['anchorCellId']) == (1, 1, False, None),
            'The new exact actual native anchor/covered cell partition differs')
        proof = cell.get('sourceTextPatch')
        _require(type(proof) is dict and proof.get('text') == '' and proof.get('utf16Length') == 0 and
            proof.get('textSha256') == _sha(b'') and proof.get('truncated') is False and proof.get('canReplace') is True,
            'The new actual-native full core/source text proof is unavailable')


def _verify_bound_candidate(presentation, prepared, observed, plan):
    additions = _plan_keys(plan)
    source = prepared._catalog
    _require(source['parts'] == plan['parts'] and list(source['parts']) == plan['source_order'],
        'The bound candidate bytes differ from the original request-derived source plan')
    expected_keys = set(plan['expected_core'])
    source_keys = {table['sourcePart'] + '#' + table['shapeId'] for table in source['tables']}
    _require(source_keys == expected_keys and len(source_keys) == len(source['tables']),
        'The bound candidate source table inventory differs')
    catalog = presentation.table_catalog
    actual_native = text_edit._native_by_source(catalog, observed)
    actual_core = text_edit._core_by_source(catalog)
    _require(set(actual_native) == expected_keys and actual_core == plan['expected_core'],
        'The exact source-bound full native core table inventory differs')
    for key, expected in plan['expected_native'].items():
        _require(text_edit._compatible(expected, actual_native[key]), 'An unchanged native source table/raw projection changed')
    _require(len(observed['slides']) == len(plan['owner_ledger']) == len(source['parts']),
        'The bound candidate owner count changed')
    by_source = {entry['source']['sourcePart'] + '#' + entry['source']['shapeId']: (identifier, entry)
        for identifier, entry in catalog._source_text_state['tables'].items()}
    tables = {table['id']: table for owner in observed['slides'] for table in owner['presentationTables'] or []}
    covered, aliases = set(), set()
    for owner in plan['owner_ledger']:
        ordinal, part = owner['ordinal'], owner['sourcePart']
        reference = prepared._bound_refs['owner_refs'][part]
        _require(presentation.document.DrawPages.getByIndex(ordinal) == reference and
            presentation.slides[observed['slides'][ordinal]['id']] == reference,
            'The exact bound native source owner order changed')
        current = observed['slides'][ordinal]
        _require(_owner_metadata(current) == owner['metadata'] and
            text_edit._compatible(owner['nonTableShapes'], _non_table_shapes(current)),
            'An unchanged owner setting or ordinary native object changed')
        _require(len(owner['keys']) == len(set(owner['keys'])) and owner['pairs'] ==
            [(plan['expected_native'][key], plan['expected_core'][key]) for key in owner['keys']],
            'The unchanged owner table/core ledger differs from the complete source plan')
        keys = set(owner['keys']) | {item['sourcePart'] + '#' + item['shapeId'] for item in owner['additions']}
        _require(len(current['presentationTables'] or []) == len(keys) and
            current['presentationTableCount'] == len(keys) and not current['presentationTablesTruncated'],
            'The complete actual candidate owner table inventory differs')
        for key in keys:
            _require(key in by_source and by_source[key][1]['ownerId'] == current['id'] and key not in covered,
                'An exact source table is foreign, repeated, or missing from its native owner')
            covered.add(key)
        for addition in owner['additions']:
            key = addition['sourcePart'] + '#' + addition['shapeId']
            _require(key in additions and addition == additions[key] and addition['alias'] not in aliases,
                'The owner addition ledger differs from the closed request-derived additions')
            aliases.add(addition['alias'])
            identifier = by_source[key][0]
            _require(identifier in tables, 'A bound new actual table is absent from the public snapshot')
            _verify_new_table(catalog, prepared, tables[identifier], addition, actual_core[key])
    _require(covered == expected_keys and aliases == {item['alias'] for item in plan['additions']},
        'The bound source owner ledger does not cover the complete request')
    _require(text_edit._compatible(plan['base_snapshot'].get('masters'), observed.get('masters')) and
        plan['base_snapshot'].get('layoutOptions') == observed.get('layoutOptions'),
        'Unchanged presentation masters or layout options changed')


def render_source_structure_candidate(runtime, edited, candidate_hash, pdf, clean_job, plan, owned, pdf_state,
        *, server_factory, objects, snapshot, export_pdf, export_owns_output=False):
    _require(type(export_owns_output) is bool, 'The private PDF export ownership flag must be boolean')
    edited, pdf = Path(edited), Path(pdf)
    with server_factory(runtime, clean_job) as server:
        with binding.prepare_pptx_binding(edited, clean_job, candidate_hash) as prepared:
            document, primary = None, None
            try:
                document = prepared.load(lambda path: server.load(path, read_only=True))
                presentation = text_edit._with_presentation(document, edited, objects)
                presentation.table_catalog.attach_source(prepared)
                clean = snapshot(document, candidate_hash, server.context, presentation=presentation, source_path=edited)
                _verify_bound_candidate(presentation, prepared, clean, plan)
                _require(not pdf.exists(), 'Preserve an existing structural preview PDF')
                created_identity = None
                if not export_owns_output:
                    with pdf.open('xb') as output:
                        created_identity = source_reader._stamp(os.fstat(output.fileno()))[:2]
                        owned[pdf] = created_identity
                pdf_state['page_count'] = export_pdf(document, pdf, 'presentation')
                if export_owns_output:
                    created_identity = owned.get(pdf)
                _require(created_identity is not None and pdf.exists() and
                    source_reader._stamp(pdf.stat())[:2] == created_identity,
                    'Preserve a foreign structural PDF replacement during export')
                _require(pdf_state['page_count'] > 0 and pdf_state['page_count'] == len(clean['slides']),
                    'The source structure PDF page count differs')
                pdf_state['stamp'] = source_reader._stamp(pdf.stat())
                pdf_state['lease'] = binding._WindowsReadLease(pdf)
                pdf_state['sha256'] = text_edit._file_hash(pdf)
                binding._verify_file(pdf, pdf_state['stamp'], pdf_state['sha256'])
            except BaseException as error:
                primary = error
                raise
            finally:
                if document is not None:
                    text_edit._close(document, primary)


def observe_source_structure_candidate(runtime, edited, candidate_hash, observer_job, plan,
        *, server_factory, objects, snapshot):
    with server_factory(runtime, observer_job) as server:
        with binding.prepare_pptx_binding(edited, observer_job, candidate_hash) as prepared:
            document, primary = None, None
            try:
                document = prepared.load(lambda path: server.load(path, read_only=True))
                presentation = text_edit._with_presentation(document, edited, objects)
                presentation.table_catalog.attach_source(prepared)
                final = snapshot(document, candidate_hash, server.context, presentation=presentation, source_path=edited)
                _verify_bound_candidate(presentation, prepared, final, plan)
            except BaseException as error:
                primary = error
                raise
            finally:
                if document is not None:
                    text_edit._close(document, primary)
    return final


def _preview(plan, final, source_hash, candidate_hash, operations):
    receipts = []
    actual = {(table['sourceTextPatchAuthority']['sourcePart'], table['sourceTextPatchAuthority']['shapeId']): table
        for slide in final['slides'] for table in slide['presentationTables'] or []
        if table.get('sourceTextPatchAuthority') is not None}
    for addition in plan['additions']:
        table = actual[(addition['sourcePart'], addition['shapeId'])]
        receipts.append({'alias': addition['alias'], 'ownerId': table['ownerId'], 'tableId': table['id'],
            'sourcePart': addition['sourcePart'], 'shapeId': addition['shapeId'],
            'frameSha256': table['sourceTextPatchAuthority']['frameSha256']})
    return {'kind': 'presentationSourceStructure', 'version': 1, 'baseSourceSha256': source_hash,
        'candidateSourceSha256': candidate_hash, 'operationsSha256': _sha(text_edit._canonical(operations).encode('utf-8')),
        'additions': receipts, 'snapshot': copy.deepcopy(final)}


def apply_source_structure_edit(runtime, source, source_hash, operations, directory, session_id, include_draft,
        *, server_factory, objects, snapshot, export_pdf, native_stages=None):
    operations = copy.deepcopy(operations)
    validate_batch(operations, source_hash)
    _require(type(include_draft) is bool and text_edit._file_hash(source) == source_hash,
        'The captured structure source hash or preview request differs')
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=False)
    edited, pdf = directory / 'edited.pptx', directory / 'preview.pdf'
    owned, pdf_state = {}, {'lease': None}
    try:
        input_job = directory / 'source-binding'
        input_job.mkdir()
        if native_stages is None:
            plan = plan_source_structure_edit(runtime, source, source_hash, operations, input_job,
                server_factory=server_factory, objects=objects, snapshot=snapshot)
        else:
            plan = native_stages.plan_structure(runtime, source, source_hash, operations, input_job)
        _plan_keys(plan)
        result = structure.add_tables_pptx(source, edited, plan['converted'], source_hash)
        owned[edited] = source_reader._stamp(edited.stat())[:2]
        candidate_hash = result['resultSha256']
        current = source_reader.read_pptx_tables(edited)
        _require(current['parts'] == plan['parts'] and list(current['parts']) == plan['source_order'] and
            current['sourceSha256'] == candidate_hash, 'The exact structure writer result differs from its frozen source plan')
        _require(len(result['operationLedger']) == len(plan['additions']) and
            all(record['shapeId'] == addition['shapeId'] and record['sourcePart'] == addition['sourcePart']
                for record, addition in zip(result['operationLedger'], plan['additions'])),
            'The final structure writer reused or changed an addition identity')
        clean_job = directory / 'clean-native'
        clean_job.mkdir()
        if native_stages is None:
            render_source_structure_candidate(runtime, edited, candidate_hash, pdf, clean_job, plan, owned, pdf_state,
                server_factory=server_factory, objects=objects, snapshot=snapshot, export_pdf=export_pdf)
        else:
            native_stages.render_structure(runtime, edited, candidate_hash, pdf, clean_job, plan, owned, pdf_state)
        observer_job = directory / 'bound-observer'
        observer_job.mkdir()
        if native_stages is None:
            final = observe_source_structure_candidate(runtime, edited, candidate_hash, observer_job, plan,
                server_factory=server_factory, objects=objects, snapshot=snapshot)
        else:
            final = native_stages.observe_structure(runtime, edited, candidate_hash, observer_job, plan)
        _require(text_edit._file_hash(source) == source_hash and text_edit._file_hash(edited) == candidate_hash,
            'The original source or verified structure candidate changed before publication')
        binding._verify_file(pdf, pdf_state['stamp'], pdf_state['sha256'])
        pdf_state['lease'].close()
        pdf_state['lease'] = None
        return {'status': 'saved', 'sessionId': session_id, 'sourcePath': str(edited), 'pdfPath': str(pdf),
            'sourceSha256': candidate_hash, 'pdfSha256': pdf_state['sha256'], 'pdfPageCount': pdf_state['page_count'],
            'engineVersion': 'LibreOffice26.8.2.2', 'snapshot': final,
            **({'structuralPreview': _preview(plan, final, source_hash, candidate_hash, operations)} if include_draft else {})}
    except BaseException as primary:
        if pdf_state['lease'] is not None:
            try:
                pdf_state['lease'].close()
            except Exception as cleanup_error:
                primary.add_note('Closing owned structural PDF lease: ' + str(cleanup_error))
        for path, identity in owned.items():
            try:
                if path.exists():
                    _require(source_reader._stamp(path.stat())[:2] == identity, 'Preserve a foreign failed structural output replacement')
                    path.unlink()
            except Exception as cleanup_error:
                primary.add_note('Removing owned failed structural output: ' + str(cleanup_error))
        raise
