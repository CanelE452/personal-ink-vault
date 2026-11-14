"""Separate bounded source text authority and source-only PPTX save pipeline."""
from contextlib import ExitStack, contextmanager
import copy
import hashlib
import json
from pathlib import Path
import re

import office_presentation_source as source_reader
from office_presentation_text_source import MAX_UTF16, cell_text_map
from office_presentation_text_patch import patch_cell_text
import office_presentation_package_patch as package_patch
import office_presentation_binding as binding


SOURCE_FIELDS = frozenset(('op', 'authorityVersion', 'ownerId', 'tableId', 'cellId',
    'expectedSourceSha256', 'sourcePart', 'shapeId', 'expectedSourceFrameSha256',
    'expectedTextSha256', 'startUtf16', 'endUtf16', 'text'))
REASONS = frozenset(('field', 'hyperlink', 'comment', 'processingInstruction', 'lineBreak', 'paragraphBoundary'))


def _require(condition, message):
    if not condition:
        raise ValueError(message)


def _sha(data):
    return hashlib.sha256(data).hexdigest()


def _file_hash(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def _canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':'), allow_nan=False)


def _nodes(value):
    if type(value) is dict:
        return 1 + sum(1 + _nodes(child) for child in value.values())
    if type(value) is list:
        return 1 + sum(map(_nodes, value))
    return 1


class SourcePatchBudget:
    BYTE_LIMIT, NODE_LIMIT = 1024 * 1024, 32768

    def __init__(self):
        self.bytes, self.nodes, self.exhausted = 0, 0, False
        from office_presentation_tables import DocBudget

        self.native_budget = DocBudget()

    def take(self, value):
        if self.exhausted:
            return False
        size = len(_canonical(value).encode('utf-8'))
        nodes = _nodes(value)
        if self.bytes + size > self.BYTE_LIMIT or self.nodes + nodes > self.NODE_LIMIT:
            self.exhausted = True
            return False
        self.bytes += size
        self.nodes += nodes
        return True


def native_core_text(cell, budget=None):
    from office_presentation_tables import DocBudget, bounded_string

    try:
        text = cell.Text
        content, complete = bounded_string(text, text, 32768, budget or DocBudget())
        return content if complete else None
    except Exception:
        return None


def source_proof(mapping, covered=False):
    protected = [{'startUtf16': item['startUtf16'], 'endUtf16': item['endUtf16'], 'reason': item['reason']}
        for item in mapping['protectedRanges'] if item['reason'] in REASONS]
    for segment in mapping['segments']:
        if segment['kind'] in ('lineBreak', 'paragraphBreak'):
            protected.append({'startUtf16': segment['startUtf16'], 'endUtf16': segment['endUtf16'],
                'reason': segment['protectedReason']})
    protected.sort(key=lambda item: (item['startUtf16'], item['endUtf16'], item['reason']))
    _require(len(mapping['segments']) <= 4096 and len(protected) <= 4096, 'The source proof range budget is exceeded')
    return {'canReplace': not covered and any(item['editable'] for item in mapping['segments']),
        'truncated': False, 'text': mapping['text'], 'utf16Length': mapping['utf16Length'],
        'textSha256': _sha(mapping['text'].encode('utf-8')),
        'segments': [{name: item[name] for name in ('startUtf16', 'endUtf16', 'editable')}
            for item in mapping['segments']], 'protectedRanges': protected}


def build_source_state(catalog, prepared, owners):
    refs = prepared._bound_refs
    source = copy.deepcopy(prepared._catalog)
    state = {'catalog': source, 'tables': {}, 'resolvers': {}}
    for table in source['tables']:
        key = table['sourcePart'], table['shapeId']
        shape = refs['table_refs'][key]
        matches = [identifier for identifier, actual in catalog.presentation.shapes.items() if actual == shape]
        _require(len(matches) == 1, 'The exact source table has no actual registry identity')
        identifier = matches[0]
        native = next(item for items in owners.values() if items is not None for item in items if item['id'] == identifier)
        entry = {'source': table, 'shape': shape, 'model': refs['model_refs'][key], 'cells': {},
            'ownerId': native['ownerId'], 'tableId': identifier, 'frameSha256': _sha(source['parts'][key[0]][slice(*table['frameSpan'])])}
        for cell in table['cells']:
            coordinate = cell['row'], cell['column']
            actual = next(item for item in native['cells'] if (item['row'], item['column']) == coordinate)
            record = {'source': cell, 'actual': refs['cell_refs'][(*key, *coordinate)], 'cellId': actual['id']}
            entry['cells'][coordinate] = record
            state['resolvers'][(native['ownerId'], identifier, actual['id'])] = (entry, record)
        state['tables'][identifier] = entry
    return state


def decorate_source_table(catalog, table, budget, state):
    entry = state['tables'].get(table['id'])
    if entry is None:
        return
    source = entry['source']
    _require(catalog.presentation.shapes.get(table['id']) == entry['shape'] and
        entry['shape'].getPropertyValue('Model') == entry['model'], 'An exact source table or Model changed')
    authority = {'kind': 'sourceTextPatch', 'version': 1, 'sourceSha256': state['catalog']['sourceSha256'],
        'sourcePart': source['sourcePart'], 'shapeId': source['shapeId'], 'frameSha256': entry['frameSha256']}
    table['sourceTextPatchAuthority'] = authority if budget.take(authority) else None
    for cell in table['cells']:
        coordinate = cell['row'], cell['column']
        record = entry['cells'][coordinate]
        _require(entry['model'].getCellByPosition(coordinate[1], coordinate[0]) == record['actual'],
            'An exact source cell ref changed')
        proof = None
        core = native_core_text(record['actual'], budget.native_budget)
        record['coreText'] = core
        if table['sourceTextPatchAuthority'] is not None:
            try:
                mapping = cell_text_map(state['catalog']['parts'][source['sourcePart']], record['source'])
                if core is not None and _sha(core.encode('utf-8')) == _sha(mapping['text'].encode('utf-8')):
                    proof = source_proof(mapping, record['source']['covered'])
            except ValueError:
                pass
        _require(entry['model'].getCellByPosition(coordinate[1], coordinate[0]) == record['actual'],
            'An actual source cell ref changed during core text observation')
        cell['sourceTextPatch'] = proof if proof is not None and budget.take(proof) else None
    if table['tableSha256'] is not None:
        table['tableSha256'] = None
        table['tableSha256'] = _sha(_canonical(table).encode('utf-8'))


def validate_batch(operations, source_hash):
    _require(type(operations) is list and 1 <= len(operations) <= 100, 'A bounded source-only batch is required')
    for operation in operations:
        _require(type(operation) is dict and set(operation) == SOURCE_FIELDS and
            operation['op'] == 'presentationCellTextPatch' and type(operation['authorityVersion']) is int and
            operation['authorityVersion'] == 1, 'Invalid closed source text operation/version')
        for name in ('ownerId', 'tableId', 'cellId', 'sourcePart', 'shapeId'):
            _require(type(operation[name]) is str and 0 < len(operation[name]) <= 1024, 'Invalid source text identity')
        for name in ('expectedSourceSha256', 'expectedSourceFrameSha256', 'expectedTextSha256'):
            _require(type(operation[name]) is str and re.fullmatch(r'[0-9a-f]{64}', operation[name]) is not None,
                'An exact source text hash is required')
        _require(operation['expectedSourceSha256'] == source_hash, 'The operation source SHA is stale')
        _require(type(operation['startUtf16']) is int and type(operation['endUtf16']) is int and
            0 <= operation['startUtf16'] <= operation['endUtf16'] <= MAX_UTF16 and
            type(operation['text']) is str and len(operation['text']) <= MAX_UTF16,
            'Invalid source text range or replacement')
        _require(len(operation['text'].encode('utf-16-le')) // 2 <= MAX_UTF16, 'The source replacement UTF-16 budget is exceeded')


def resolve_operations(catalog, operations):
    catalog._revalidate(False)
    state = catalog._source_text_state
    _require(state is not None, 'A complete actual source binding is required')
    converted = []
    for operation in operations:
        key = operation['ownerId'], operation['tableId'], operation['cellId']
        _require(key in state['resolvers'], 'The source operation has foreign actual owner/table/cell IDs')
        entry, cell = state['resolvers'][key]
        source = entry['source']
        _require(operation['sourcePart'] == source['sourcePart'] and operation['shapeId'] == source['shapeId'] and
            operation['expectedSourceFrameSha256'] == entry['frameSha256'], 'The source frame binding is stale or foreign')
        native = next(item for item in catalog.owners[entry['ownerId']] if item['id'] == entry['tableId'])
        actual = next(item for item in native['cells'] if item['id'] == cell['cellId'])
        _require(actual.get('sourceTextPatch') is not None and actual['sourceTextPatch']['canReplace'] and
            not actual['sourceTextPatch']['truncated'], 'The complete source/native core proof is unavailable')
        converted.append({name: operation[name] for name in ('sourcePart', 'shapeId',
            'expectedSourceFrameSha256', 'expectedTextSha256', 'startUtf16', 'endUtf16', 'text')} |
            {'row': cell['source']['row'], 'column': cell['source']['column']})
    return converted


def _current_cell(parts, operation):
    part = operation['sourcePart']
    tables = source_reader._slide(source_reader._xml(parts[part], {'nodes': 0}), part)
    table = next(table for table in tables if table['shapeId'] == operation['shapeId'])
    return next(cell for cell in table['cells'] if (cell['row'], cell['column']) ==
        (operation['row'], operation['column']))


def _replace_semantic(text, start, end, replacement):
    data = text.encode('utf-16-le')
    try:
        return (data[:start * 2] + replacement.encode('utf-16-le') + data[end * 2:]).decode('utf-16-le')
    except UnicodeError as error:
        raise ValueError('The source edit splits a Unicode scalar') from error


def _merge_runs(runs):
    result = []
    for run in runs:
        item = copy.deepcopy(run)
        if result and result[-1]['endUtf16'] == item['startUtf16'] and {
                key: value for key, value in result[-1].items() if key not in ('startUtf16', 'endUtf16')} == {
                key: value for key, value in item.items() if key not in ('startUtf16', 'endUtf16')}:
            result[-1]['endUtf16'] = item['endUtf16']
        else:
            result.append(item)
    return result


def _native_table(table):
    result = copy.deepcopy(table)
    anchors = {cell['id']: (cell['row'], cell['column']) for cell in result['cells']}
    for key in ('id', 'ownerId', 'tableSha256', 'authoredGeometry', 'sourceTextPatchAuthority', 'truncated'):
        result.pop(key, None)
    for cell in result['cells']:
        cell.pop('id')
        cell.pop('sourceTextPatch', None)
        cell['anchorCellId'] = anchors.get(cell['anchorCellId'])
        if cell['textDetails'] is not None:
            cell['textDetails']['runs'] = _merge_runs(cell['textDetails']['runs'])
        paragraphs = cell['rawStyle'].get('_paragraphs')
        if isinstance(paragraphs, list):
            for paragraph in paragraphs:
                portions = []
                for portion in paragraph['portions']:
                    if portions and portions[-1]['rawStyle'] == portion['rawStyle']:
                        portions[-1]['text'] += portion['text']
                    else:
                        portions.append(portion)
                paragraph['portions'] = portions
    return result


def _replace_runs(runs, start, end, replacement_length):
    positive = [run for run in runs if max(start, run['startUtf16']) < min(end, run['endUtf16'])]
    first = positive[0] if positive else next((run for run in runs
        if run['startUtf16'] <= start <= run['endUtf16']), None)
    _require(first is not None, 'The requested native style interval is unknown')
    delta, result = replacement_length - (end - start), []
    for run in runs:
        a, b = run['startUtf16'], run['endUtf16']
        if a < start:
            result.append({**run, 'endUtf16': min(b, start)})
        if run is first and replacement_length:
            result.append({**run, 'startUtf16': start, 'endUtf16': start + replacement_length})
        if b > end:
            result.append({**run, 'startUtf16': max(a, end) + delta, 'endUtf16': b + delta})
    return _merge_runs([run for run in result if run['startUtf16'] < run['endUtf16']])


def _update_native_cell(cell, original, start, end, replacement):
    updated = _replace_semantic(original, start, end, replacement)
    length = len(replacement.encode('utf-16-le')) // 2
    delta = length - (end - start)
    if cell['text'] is not None:
        _require(cell['text'] == original, 'The origin native text differs from the source request')
        cell['text'] = updated
    details = cell['textDetails']
    if details is not None:
        details['utf16Length'], details['textSha256'] = len(updated.encode('utf-16-le')) // 2, _sha(updated.encode('utf-8'))
        if not details['truncated'] and details['protectedRanges'] == []:
            details['runs'] = _replace_runs(details['runs'], start, end, length)
        else:
            cell['textDetails'] = {'unknown': True, 'error': 'incomplete_native_text_style'}
    paragraphs = cell['rawStyle'].get('_paragraphs')
    if isinstance(paragraphs, list):
        positions, offset = [], 0
        for paragraph_index, paragraph in enumerate(paragraphs):
            if paragraph_index:
                offset += 1
            for portion in paragraph['portions']:
                stop = offset + len(portion['text'].encode('utf-16-le')) // 2
                positions.append((portion, offset, stop))
                offset = stop
        selected = [(portion, max(start, a) - a, min(end, b) - a) for portion, a, b in positions
            if max(start, a) < min(end, b)]
        if start == end:
            selected = [(portion, start - a, start - a) for portion, a, b in positions if a <= start <= b][:1]
        _require(selected, 'The requested raw native text portion is unknown')
        for index, (portion, left, right) in enumerate(selected):
            portion['text'] = _replace_semantic(portion['text'], left, right, replacement if index == 0 else '')
    return updated


def _compatible(expected, observed):
    if isinstance(expected, dict) and expected.get('unknown') is True:
        return True
    if isinstance(observed, dict) and observed.get('unknown') is True:
        return observed.get('error') == 'read_budget_exhausted'
    if isinstance(expected, dict) and ('_budget' in expected or '_mapping' in expected):
        return True
    if type(expected) is not type(observed):
        return False
    if isinstance(expected, dict):
        return expected.keys() == observed.keys() and all(_compatible(value, observed[key]) for key, value in expected.items())
    if isinstance(expected, list):
        return len(expected) == len(observed) and all(_compatible(one, two) for one, two in zip(expected, observed))
    return expected == observed


def _native_by_source(catalog, snapshot):
    tables = {table['id']: table for slide in snapshot['slides'] for table in slide['presentationTables'] or []}
    return {entry['source']['sourcePart'] + '#' + entry['source']['shapeId']: _native_table(tables[identifier])
        for identifier, entry in catalog._source_text_state['tables'].items()}


def _core_by_source(catalog):
    return {entry['source']['sourcePart'] + '#' + entry['source']['shapeId']:
        [record.get('coreText') for _, record in sorted(entry['cells'].items())]
        for entry in catalog._source_text_state['tables'].values()}


def _request_plan(catalog, snapshot, public_operations, converted):
    state, draft = catalog._source_text_state, copy.deepcopy(snapshot)
    parts = dict(state['catalog']['parts'])
    expected_native, expected_core = _native_by_source(catalog, snapshot), _core_by_source(catalog)
    for public, operation in zip(public_operations, converted):
        record = _current_cell(parts, operation)
        mapped = cell_text_map(parts[operation['sourcePart']], record)
        patched = patch_cell_text(parts[operation['sourcePart']], record, operation['startUtf16'], operation['endUtf16'],
            operation['text'], operation['expectedTextSha256'])
        key = operation['sourcePart'] + '#' + operation['shapeId']
        native = next(cell for cell in expected_native[key]['cells'] if (cell['row'], cell['column']) ==
            (operation['row'], operation['column']))
        current = _update_native_cell(native, mapped['text'], operation['startUtf16'], operation['endUtf16'], operation['text'])
        index = next(index for index, item in enumerate(expected_native[key]['cells']) if item is native)
        _require(expected_core[key][index] == mapped['text'], 'The complete origin native core text is unavailable')
        expected_core[key][index] = current
        parts[operation['sourcePart']] = patched['partBytes']
        updated = cell_text_map(parts[operation['sourcePart']], _current_cell(parts, operation))
        table = next(table for slide in draft['slides'] for table in slide['presentationTables'] if table['id'] == public['tableId'])
        cell = next(cell for cell in table['cells'] if cell['id'] == public['cellId'])
        cell['sourceTextPatch'] = source_proof(updated, record['covered'])
    budget = SourcePatchBudget()
    for slide in draft['slides']:
        for table in slide['presentationTables'] or []:
            if table.get('sourceTextPatchAuthority') is not None and not budget.take(table['sourceTextPatchAuthority']):
                table['sourceTextPatchAuthority'] = None
            for cell in table['cells']:
                proof = cell.get('sourceTextPatch')
                if proof is not None and (table.get('sourceTextPatchAuthority') is None or not budget.take(proof)):
                    cell['sourceTextPatch'] = None
    return parts, expected_native, expected_core, draft


@contextmanager
def _leased_candidate(path, expected_hash):
    lease, primary = binding._WindowsReadLease(path), None
    try:
        _require(_file_hash(path) == expected_hash, 'The candidate changed before native consumption')
        yield
        _require(_file_hash(path) == expected_hash, 'The candidate changed during native consumption')
    except BaseException as error:
        primary = error
        raise
    finally:
        try:
            lease.close()
        except Exception as error:
            if primary is None:
                raise
            primary.add_note('Closing source candidate lease: ' + type(error).__name__)


def _close(document, primary):
    try:
        document.close(True)
    except Exception as error:
        if primary is None:
            raise
        primary.add_note('Closing source text document: ' + str(error))


def _with_presentation(document, source, objects):
    from office_presentation import Presentation

    kind, slides, shapes = objects(document)
    _require(kind == 'presentation', 'Source text edits require an actual presentation')
    return Presentation(document, slides, shapes, source_path=source)



def _owner_ledger(presentation, prepared, snapshot, expected_native, expected_core):
    ordered_parts = list(prepared._catalog['parts'])
    owners = prepared._bound_refs['owner_refs']
    _require(len(presentation.logical) == len(ordered_parts) and
        presentation.document.DrawPages.Count == len(ordered_parts), 'The original source owner coverage changed')
    ledger = []
    for part in ordered_parts:
        matches = [index for index, owner_id in enumerate(presentation.logical)
            if presentation.slides[owner_id] == owners[part]]
        _require(len(matches) == 1, 'An original source owner has no unique native page ordinal')
        ordinal = matches[0]
        _require(presentation.document.DrawPages.getByIndex(ordinal) == owners[part],
            'The bound native page order changed before source planning completed')
        metadata = copy.deepcopy(snapshot['slides'][ordinal])
        metadata.pop('presentationTables')
        metadata.pop('sourceStructureAuthority', None)
        keys = [source['sourcePart'] + '#' + source['shapeId'] for source in prepared._catalog['tables']
            if source['sourcePart'] == part]
        ledger.append({'sourcePart': part, 'ordinal': ordinal, 'metadata': metadata,
            'pairs': [(expected_native[key], expected_core[key]) for key in keys]})
    _require(sorted(item['ordinal'] for item in ledger) == list(range(len(ordered_parts))),
        'The original source owners do not cover the actual page order')
    return ordered_parts, sorted(ledger, key=lambda item: item['ordinal'])


def _verify_clean_owners(presentation, snapshot, ledger):
    _require(len(snapshot['slides']) == len(ledger), 'The clean source page count differs')
    core_budget = SourcePatchBudget().native_budget
    for expected_owner in ledger:
        owner = snapshot['slides'][expected_owner['ordinal']]
        metadata = {key: value for key, value in owner.items()
            if key not in ('presentationTables', 'sourceStructureAuthority')}
        _require(_compatible(expected_owner['metadata'], metadata), 'Clean native owner metadata or order differs')
        tables = owner['presentationTables']
        _require(tables is not None and len(tables) == len(expected_owner['pairs']),
            'The clean source owner table inventory differs')
        owner_id = owner['id']
        bindings = {identifier: bound for (identifier, _), bound in zip(
            presentation.table_catalog.table_refs[owner_id] or [], presentation.table_catalog.bindings[owner_id] or [])}
        observed = []
        for table in tables:
            _require(table['id'] in bindings, 'A clean table has no actual native cell bindings')
            core = [native_core_text(cell, core_budget) for cell in bindings[table['id']]['cells']]
            observed.append((_native_table(table), core))
        for expected_table, expected_core in expected_owner['pairs']:
            match = next((index for index, (table, core) in enumerate(observed)
                if _compatible(expected_table, table) and expected_core == core), None)
            _require(match is not None, 'Clean native table/core values differ on the expected source page')
            observed.pop(match)


def plan_source_text_edit(runtime, source, source_hash, operations, input_job,
        *, server_factory, objects, snapshot, allow_empty_fallback=False):
    with server_factory(runtime, input_job) as server:
        with ExitStack() as input_cleanup:
            try:
                prepared = input_cleanup.enter_context(binding.prepare_pptx_binding(source, input_job, source_hash))
            except ValueError:
                if allow_empty_fallback and operations == []:
                    _require(_file_hash(source) == source_hash, 'The unsupported no-op source changed before fallback')
                    return None
                raise
            document, phase_error = None, None
            try:
                document = prepared.load(lambda path: server.load(path, read_only=True))
                presentation = _with_presentation(document, source, objects)
                presentation.table_catalog.attach_source(prepared)
                origin = snapshot(document, source_hash, server.context, presentation=presentation, source_path=source)
                converted = resolve_operations(presentation.table_catalog, operations)
                parts, expected_native, expected_core, draft = _request_plan(presentation.table_catalog, origin, operations, converted)
                source_order, owner_ledger = _owner_ledger(presentation, prepared, origin, expected_native, expected_core)
            except BaseException as error:
                phase_error = error
                raise
            finally:
                if document is not None:
                    _close(document, phase_error)
    return {'converted': converted, 'parts': parts, 'expected_native': expected_native,
        'expected_core': expected_core, 'draft': draft, 'source_order': source_order,
        'owner_ledger': owner_ledger}


def render_source_candidate(runtime, edited, candidate_hash, pdf, clean_job, owner_ledger, owned, pdf_state,
        *, server_factory, objects, snapshot, export_pdf):
    with server_factory(runtime, clean_job) as server:
        with _leased_candidate(edited, candidate_hash):
            document, phase_error = None, None
            try:
                document = server.load(edited, read_only=True)
                presentation = _with_presentation(document, edited, objects)
                clean = snapshot(document, candidate_hash, server.context, presentation=presentation, source_path=edited)
                _verify_clean_owners(presentation, clean, owner_ledger)
                _require(not pdf.exists(), 'Preserve an existing PDF destination')
                pdf_state['page_count'] = export_pdf(document, pdf, 'presentation')
                if pdf.exists():
                    owned[pdf] = source_reader._stamp(pdf.stat())[:2]
                _require(pdf_state['page_count'] > 0 and pdf_state['page_count'] == len(clean['slides']),
                    'Source text PDF page verification failed')
                pdf_state['stamp'] = source_reader._stamp(pdf.stat())
                pdf_state['lease'] = binding._WindowsReadLease(pdf)
                pdf_state['sha256'] = _file_hash(pdf)
                binding._verify_file(pdf, pdf_state['stamp'], pdf_state['sha256'])
            except BaseException as error:
                phase_error = error
                if pdf.exists() and pdf not in owned:
                    owned[pdf] = source_reader._stamp(pdf.stat())[:2]
                raise
            finally:
                if document is not None:
                    _close(document, phase_error)


def observe_source_candidate(runtime, edited, candidate_hash, observer_job, expected_native, expected_core,
        *, server_factory, objects, snapshot):
    with server_factory(runtime, observer_job) as server:
        with binding.prepare_pptx_binding(edited, observer_job, candidate_hash) as prepared:
            document, phase_error = None, None
            try:
                document = prepared.load(lambda path: server.load(path, read_only=True))
                presentation = _with_presentation(document, edited, objects)
                presentation.table_catalog.attach_source(prepared)
                final = snapshot(document, candidate_hash, server.context, presentation=presentation, source_path=edited)
                actual = _native_by_source(presentation.table_catalog, final)
                _require(set(actual) == set(expected_native) and all(_compatible(expected_native[key], actual[key]) for key in actual),
                    'The exact source-bound native candidate differs from the requested delta')
                _require(_core_by_source(presentation.table_catalog) == expected_core,
                    'The exact source-bound full native core text differs')
            except BaseException as error:
                phase_error = error
                raise
            finally:
                if document is not None:
                    _close(document, phase_error)
    return final


def apply_source_text_edit(runtime, source, source_hash, operations, directory, session_id, include_draft,
        *, server_factory, objects, snapshot, export_pdf, allow_empty_fallback=False, native_stages=None):
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=False)
    edited, pdf = directory / 'edited.pptx', directory / 'preview.pdf'
    owned, primary, pdf_state = {}, None, {'lease': None}
    try:
        input_job = directory / 'source-binding'
        input_job.mkdir()
        if native_stages is None:
            plan = plan_source_text_edit(runtime, source, source_hash, operations, input_job,
                server_factory=server_factory, objects=objects, snapshot=snapshot,
                allow_empty_fallback=allow_empty_fallback)
        else:
            plan = native_stages.plan(runtime, source, source_hash, operations, input_job,
                allow_empty_fallback=allow_empty_fallback)
        if plan is None:
            return None
        result = package_patch.patch_pptx(source, edited, plan['converted'], source_hash)
        owned[edited] = source_reader._stamp(edited.stat())[:2]
        candidate_hash = result['resultSha256']
        current = source_reader.read_pptx_tables(edited)
        _require(current['parts'] == plan['parts'] and list(current['parts']) == plan['source_order'] and
            current['sourceSha256'] == candidate_hash, 'The candidate differs from the exact request-derived source parts')
        clean_job = directory / 'clean-native'
        clean_job.mkdir()
        if native_stages is None:
            render_source_candidate(runtime, edited, candidate_hash, pdf, clean_job, plan['owner_ledger'], owned, pdf_state,
                server_factory=server_factory, objects=objects, snapshot=snapshot, export_pdf=export_pdf)
        else:
            native_stages.render(runtime, edited, candidate_hash, pdf, clean_job, plan['owner_ledger'], owned, pdf_state)
        observer_job = directory / 'bound-observer'
        observer_job.mkdir()
        if native_stages is None:
            final = observe_source_candidate(runtime, edited, candidate_hash, observer_job,
                plan['expected_native'], plan['expected_core'], server_factory=server_factory, objects=objects, snapshot=snapshot)
        else:
            final = native_stages.observe(runtime, edited, candidate_hash, observer_job,
                plan['expected_native'], plan['expected_core'])
        _require(_file_hash(source) == source_hash and _file_hash(edited) == candidate_hash,
            'The source or verified candidate changed before returning')
        binding._verify_file(pdf, pdf_state['stamp'], pdf_state['sha256'])
        pdf_state['lease'].close()
        pdf_state['lease'] = None
        return {'status': 'saved', 'sessionId': session_id, 'sourcePath': str(edited), 'pdfPath': str(pdf),
            'sourceSha256': candidate_hash, 'pdfSha256': pdf_state['sha256'], 'pdfPageCount': pdf_state['page_count'],
            'engineVersion': 'LibreOffice26.8.2.2', 'snapshot': final,
            **({'draftSnapshot': plan['draft']} if include_draft else {})}
    except BaseException as error:
        primary = error
        if pdf_state['lease'] is not None:
            try:
                pdf_state['lease'].close()
            except Exception as cleanup_error:
                primary.add_note('Closing owned PDF read lease: ' + str(cleanup_error))
        for path, identity in owned.items():
            try:
                if path.exists():
                    _require(source_reader._stamp(path.stat())[:2] == identity, 'Preserve a foreign failed output replacement')
                    path.unlink()
            except Exception as cleanup_error:
                primary.add_note('Removing owned failed source output: ' + str(cleanup_error))
        raise
