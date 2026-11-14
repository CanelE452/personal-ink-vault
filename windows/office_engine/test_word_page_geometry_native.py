"""Production Word page geometry and source-bound draft evidence.

Each independently selectable case uses fresh owned servers and the unchanged
run_request entry point. The geometry and draft cases fail independently on the
previous product, after a real fixed-source inspect, rather than on imports.
"""
import argparse
import copy
import hashlib
import json
import math
from pathlib import Path
import sys
import traceback
import xml.etree.ElementTree as ET
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import office_worker as worker
from test_word_owners_native import SOURCE_SHA256, NS, W, independent_server, package_evidence
from test_word_structure_native import insert, split, text_hash

FIELDS = {'width': 'Width', 'height': 'Height', 'landscape': 'IsLandscape',
    'leftMargin': 'LeftMargin', 'rightMargin': 'RightMargin', 'topMargin': 'TopMargin', 'bottomMargin': 'BottomMargin'}
RAW_KEYS = tuple(FIELDS.values()) + ('HeaderIsOn', 'FooterIsOn', 'HeaderIsShared', 'FooterIsShared', 'FirstIsShared', 'PageStyleLayout')
CASES = ('geometry', 'reverse', 'draft', 'margin', 'identity', 'journal', 'reflow', 'rejections')


def serializable(value):
    if isinstance(value, dict):
        return {key: serializable(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [serializable(item) for item in value]
    if isinstance(value, float) and not math.isfinite(value):
        return {'nonFinite': repr(value)}
    return value


def flush(report, output):
    (output / 'result.json').write_text(json.dumps(serializable(report), ensure_ascii=False,
        indent=2, allow_nan=False), encoding='utf-8')


def direct(value, name):
    try:
        result = value.getPropertyValue(name)
        return getattr(result, 'value', result)
    except Exception:
        return None


def layout_hash(raw):
    return hashlib.sha256(json.dumps(raw, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode('utf-8')).hexdigest()


def native_bindings(document, snapshot):
    """Native PageStyleName is a family key within this open document only.

    SwXStyle getters may create distinct wrappers, so wrapper equality is an
    observation rather than authority. Across saves only body usage groups bind
    corresponding styles; no saved name or wrapper identity crosses that edge.
    """
    family = document.StyleFamilies.getByName('PageStyles')
    handles = [(row, family.getByName(row['name'])) for row in snapshot['pageStyles']]
    groups = {}
    elements = list(worker.office_word.body_elements(document))
    assert len(elements) == len(snapshot['blocks'])
    for position, ((kind, _, paragraph), block) in enumerate(zip(elements, snapshot['blocks'])):
        assert kind == block['kind']
        if kind != 'paragraph':
            continue
        name = direct(paragraph, 'PageStyleName')
        assert isinstance(name, str) and family.hasByName(name), 'Unverifiable actual body style usage'
        actual_style = family.getByName(name)
        matches = [row for row, _ in handles if row['name'] == name]
        wrapper_matches = [row['id'] for row, candidate in handles if candidate == actual_style]
        try:
            native_get_name = actual_style.getName()
        except Exception as error:
            native_get_name = {'exceptionType': type(error).__name__, 'message': str(error)}
        assert len(matches) == 1, {'message': 'Native PageStyleName must identify one current snapshot family key',
            'nativePageStyleName': name, 'snapshotFamilyKeys': [row['name'] for row, _ in handles],
            'wrapperEqualityMatches': wrapper_matches, 'nativeGetName': native_get_name}
        row, style = matches[0], actual_style
        if row['id'] not in groups:
            raw = {key: direct(style, key) for key in RAW_KEYS}
            assert row['layoutSha256'] == layout_hash(raw)
            info = style.getPropertySetInfo()
            writable = {key: info.hasPropertyByName(key) and not bool(info.getPropertyByName(key).Attributes & 16)
                for key in FIELDS.values()}
            groups[row['id']] = {'id': row['id'], 'nameWithinThisDocument': row['name'], 'blockPositions': [],
                'nativePageStyleName': name, 'nativeGetName': native_get_name,
                'wrapperEqualityMatches': wrapper_matches,
                'raw': raw, 'layoutSha256': layout_hash(raw), 'writable': writable,
                'inUse': bool(style.isInUse()), 'canEditGeometry': row.get('canEditGeometry')}
        groups[row['id']]['blockPositions'].append(position)
    return list(groups.values())


def pdf_evidence(path):
    pages = worker.PdfReader(str(path), strict=True).pages
    result = []
    for index, page in enumerate(pages):
        rotation = int(page.get('/Rotate', 0)) % 360
        width, height = float(page.mediabox.width), float(page.mediabox.height)
        physical = (height, width) if rotation in (90, 270) else (width, height)
        result.append({'page': index + 1, 'mediaBox': [float(value) for value in page.mediabox],
            'rotation': rotation, 'physicalWidthPt': physical[0], 'physicalHeightPt': physical[1],
            'text': page.extract_text() or ''})
    assert result
    return {'path': str(path), 'sha256': worker.digest(Path(path)), 'pageCount': len(result), 'pages': result}


def section_evidence(path):
    with zipfile.ZipFile(path) as archive:
        root = ET.fromstring(archive.read('word/document.xml'))
        return [ET.tostring(section, encoding='unicode') for section in root.findall('.//w:sectPr', NS)]


def request(runtime, source, output, name, report, operations=None, draft=False, expected_source=True):
    value = {'mode': 'inspect' if operations is None else 'apply', 'sourcePath': str(source)}
    if operations is not None:
        value.update(sessionId=name, operations=operations)
        if expected_source:
            value['expectedSourceSha256'] = worker.digest(source) if expected_source is True else expected_source
        if draft:
            value['includeDraftSnapshot'] = True
    event = {'name': name, 'request': copy.deepcopy(value), 'sourceBeforeSha256': worker.digest(source)}
    report['requests'].append(event)
    try:
        event['result'] = worker.run_request(runtime, value, output / name)
        return event['result']
    except BaseException:
        event['exception'] = traceback.format_exc()
        raise
    finally:
        event['sourceHashUnchanged'] = worker.digest(source) == event['sourceBeforeSha256']
        flush(report, output)
        assert event['sourceHashUnchanged']


def inspect_bindings(runtime, source, snapshot, output, name, report):
    with independent_server(runtime, output / name, report) as server:
        document = server.load(source)
        try:
            bindings = native_bindings(document, snapshot)
        finally:
            document.close(True)
    return bindings


def geometry(target, **values):
    return {'op': 'pageGeometry', 'id': target['id'], 'expectedLayoutSha256': target['layoutSha256'], **values}


def independent_saved(runtime, result, output, name, report):
    source, pdf = Path(result['sourcePath']), Path(result['pdfPath'])
    assert result['status'] == 'saved' and worker.digest(source) == result['sourceSha256']
    assert worker.digest(pdf) == result['pdfSha256']
    exported = pdf_evidence(pdf)
    assert exported['pageCount'] == result['pdfPageCount']
    with independent_server(runtime, output / name, report) as server:
        document = server.load(source)
        try:
            fresh = worker.snapshot(document, worker.digest(source), server.context)
            bindings = native_bindings(document, fresh)
            canonical_bindings = native_bindings(document, result['snapshot'])
            independent_pdf = output / (name + '.pdf')
            actual_count = worker.export_pdf(document, independent_pdf, 'word')
            independently = pdf_evidence(independent_pdf)
            assert actual_count == independently['pageCount'] == exported['pageCount']
        finally:
            document.close(True)
    assert [(item['blockPositions'], item['raw']) for item in bindings] == [
        (item['blockPositions'], item['raw']) for item in canonical_bindings]
    assert [(item['physicalWidthPt'], item['physicalHeightPt'], item['text']) for item in independently['pages']] == [
        (item['physicalWidthPt'], item['physicalHeightPt'], item['text']) for item in exported['pages']]
    return {'bindings': bindings, 'pdf': independently, 'sections': section_evidence(source),
        'package': package_evidence(source), 'freshSnapshot': fresh}


def by_usage(bindings):
    result = {tuple(item['blockPositions']): item for item in bindings}
    assert len(result) == len(bindings)
    return result


def compare_target(initial, observed, target, expected_changes):
    before, after = by_usage(initial), by_usage(observed)
    assert set(before) == set(after), 'Actual body style usage groups changed unexpectedly'
    selected_usage = tuple(target['blockPositions'])
    for usage, old in before.items():
        expected = dict(old['raw'])
        if usage == selected_usage:
            expected.update(expected_changes)
        assert after[usage]['raw'] == expected, (usage, expected, after[usage]['raw'])


def first_header(snapshot):
    return next(owner for owner in snapshot['wordOwners'] if owner['kind'] == 'header'
        and any(paragraph['text'] == '' and paragraph['structure']['canInsertBefore'] for paragraph in owner['paragraphs']))


def no_publish(runtime, source, output, name, report, operations, expected_source=True):
    try:
        result = request(runtime, source, output, name, report, operations, expected_source=expected_source)
    except (ValueError, KeyError) as error:
        report['rejections'].append({'name': name, 'exceptionType': type(error).__name__, 'message': str(error)})
    else:
        raise AssertionError('Invalid geometry batch accepted: ' + name + ' ' + repr(result))
    assert not (output / name / 'edited.docx').exists() and not (output / name / 'preview.pdf').exists()


def create_twins(runtime, output, report):
    source = output / 'same-layout-distinct-styles.docx'
    with independent_server(runtime, output / 'twin-fixture-server', report) as server:
        document = server.desktop.loadComponentFromURL('private:factory/swriter', '_blank', 0,
            (worker.prop('Hidden', True), worker.prop('MacroExecutionMode', 0), worker.prop('UpdateDocMode', 0)))
        try:
            family = document.StyleFamilies.getByName('PageStyles')
            for index in range(2):
                name = 'PIVGeometryTwin' + str(index)
                family.insertByName(name, document.createInstance('com.sun.star.style.PageStyle'))
                style = family.getByName(name)
                for key, value in [('Width', 21000), ('Height', 29700), ('IsLandscape', False),
                    ('LeftMargin', 1800), ('RightMargin', 1800), ('TopMargin', 1800), ('BottomMargin', 1800),
                    ('HeaderIsOn', True), ('FooterIsOn', False), ('HeaderIsShared', True), ('FirstIsShared', True)]:
                    style.setPropertyValue(key, value)
                style.HeaderText.String = 'TWIN_HEADER_' + str(index)
                style.FollowStyle = name
            document.Text.String = 'TWIN_BODY_0'
            cursor = document.Text.createTextCursor()
            cursor.gotoEnd(False)
            document.Text.insertControlCharacter(cursor, 0, False)
            cursor.gotoEnd(False)
            document.Text.insertString(cursor, 'TWIN_BODY_1', False)
            paragraphs = list(worker.objects(document)[1].values())
            assert len(paragraphs) == 2, 'Twin fixture requires two actual native paragraphs'
            for index, paragraph in enumerate(paragraphs):
                if index:
                    paragraph.BreakType = worker.uno.Enum('com.sun.star.style.BreakType', 'PAGE_BEFORE')
                paragraph.PageDescName = 'PIVGeometryTwin' + str(index)
            document.storeToURL(source.as_uri(), (worker.prop('FilterName', worker.FILTERS['docx']),))
        finally:
            document.close(True)
    report['derivedSources'][str(source)] = worker.digest(source)
    with zipfile.ZipFile(source) as archive:
        body = ET.fromstring(archive.read('word/document.xml')).find('w:body', NS)
        assert len(body.findall('w:p', NS)) == 2
        sections = body.findall('.//w:sectPr', NS)
        assert len(sections) == 2, 'Twin fixture requires two independently saved sections'
        relationships = ET.fromstring(archive.read('word/_rels/document.xml.rels'))
        targets = {item.get('Id'): item.get('Target') for item in relationships}
        saved = []
        for index, section in enumerate(sections):
            reference = next(item for item in section.findall('w:headerReference', NS) if item.get(W + 'type') == 'default')
            relationship = reference.get('{http://schemas.openxmlformats.org/officeDocument/2006/relationships}id')
            part = 'word/' + targets[relationship]
            content = ''.join(item.text or '' for item in ET.fromstring(archive.read(part)).findall('.//w:t', NS))
            assert content == 'TWIN_HEADER_' + str(index)
            saved.append({'defaultHeaderRelationship': relationship, 'targetPart': part, 'authoredHeader': content})
        assert len({row['targetPart'] for row in saved}) == 2
        report['twinFixtureSections'] = saved
    return source


def create_reflow(source, destination):
    with zipfile.ZipFile(source) as original, zipfile.ZipFile(destination, 'w', zipfile.ZIP_DEFLATED) as target:
        for member in original.infolist():
            data = original.read(member.filename)
            if member.filename == 'word/document.xml':
                root = ET.fromstring(data)
                body = root.find('w:body', NS)
                section = body.find('w:sectPr', NS)
                assert section is not None
                position = list(body).index(section)
                for index in range(36):
                    paragraph = ET.Element(W + 'p')
                    ET.SubElement(ET.SubElement(paragraph, W + 'r'), W + 't').text = (
                        'REFLOW_' + str(index) + ' ' + 'preserved document words ' * 16)
                    body.insert(position + index, paragraph)
                data = ET.tostring(root, encoding='utf-8', xml_declaration=True)
            target.writestr(member, data)


def run_case(case, runtime, source, output, report, previous_result=None):
    initial = request(runtime, source, output, 'inspect-fixed-source', report)['snapshot']
    assert initial['sourceSha256'] == SOURCE_SHA256
    if case == 'draft':
        owner = first_header(initial)
        reference = next(item for item in owner['paragraphs'] if item['text'] == '' and item['structure']['canInsertBefore'])
        result = request(runtime, source, output, 'draft-positive', report,
            [insert('geometry-draft-created', reference['id'], '', 'before', 'DRAFT_CREATED')], draft=True)
        draft = result['draftSnapshot']
        assert draft['sourceSha256'] == SOURCE_SHA256 and result['snapshot']['sourceSha256'] == result['sourceSha256']
        assert [row['id'] for row in draft['pageStyles']] == [row['id'] for row in initial['pageStyles']]
        current = next(row for row in draft['wordOwners'] if row['id'] == owner['id'])
        assert next(row for row in current['paragraphs'] if row['id'] == 'geometry-draft-created')['text'] == 'DRAFT_CREATED'
        assert current['references'] == owner['references']
        report['draftEvidence'] = independent_saved(runtime, result, output, 'draft-reopen', report)
        return
    bindings = inspect_bindings(runtime, source, initial, output, 'source-native-binding', report)
    report['sourceBindings'] = bindings
    assert len(bindings) >= 2, 'Fixed source needs distinct actual body-style usage groups'
    target = bindings[0]
    if case == 'reverse':
        assert previous_result is not None, 'Use --previous-result pointing to the completed geometry case result.json'
        previous = json.loads(previous_result.read_text(encoding='utf-8'))
        assert previous['case'] == 'geometry' and previous['sourceOriginalSha256'] == SOURCE_SHA256
        forward = previous['feature']
        source = Path(forward['sourcePath'])
        assert worker.digest(source) == forward['sourceSha256']
        report['previousEvidence'] = {'path': str(previous_result), 'sha256': worker.digest(previous_result)}
        report['derivedSources'][str(source)] = worker.digest(source)
        initial = request(runtime, source, output, 'inspect-forward-original', report)['snapshot']
        bindings = inspect_bindings(runtime, source, initial, output, 'reverse-source-binding', report)
        target = by_usage(bindings)[tuple(target['blockPositions'])]
        assert target['raw']['IsLandscape'] is True and target['raw']['Width'] > target['raw']['Height']
    if case == 'rejections':
        valid = geometry(target, leftMargin=25.4)
        invalid = [
            ('missing-source-hash', valid, False), ('stale-source-hash', valid, '0' * 64),
            ('stale-layout', dict(valid, expectedLayoutSha256='0' * 64), True),
            ('body-id', dict(valid, id=initial['paragraphs'][0]['id']), True),
            ('owner-id', dict(valid, id=initial['wordOwners'][0]['id']), True),
            ('table-id', dict(valid, id=initial['tables'][0]['id']), True),
            ('unknown-style', dict(valid, id='unknown-style'), True),
            ('boolean-mm', dict(valid, leftMargin=True), True), ('null-mm', dict(valid, leftMargin=None), True),
            ('nan-mm', dict(valid, leftMargin=float('nan')), True), ('infinite-mm', dict(valid, leftMargin=float('inf')), True),
            ('negative-margin', dict(valid, leftMargin=-1), True), ('excess-precision', dict(valid, leftMargin=1.001), True),
            ('zero-width', geometry(target, width=0, height=297, landscape=False), True),
            ('negative-size', geometry(target, width=-1, height=297, landscape=False), True),
            ('overflow-size', geometry(target, width=1000.01, height=210, landscape=True), True),
            ('partial-size', geometry(target, width=297), True), ('orientation-only', geometry(target, landscape=True), True),
            ('square', geometry(target, width=210, height=210, landscape=False), True),
            ('orientation-mismatch', geometry(target, width=210, height=297, landscape=True), True),
            ('no-values', geometry(target), True), ('no-body-space', dict(valid, leftMargin=200, rightMargin=200), True),
            ('forbidden-on', dict(valid, headerIsOn=False), True), ('forbidden-shared', dict(valid, headerIsShared=True), True),
            ('forbidden-first', dict(valid, firstIsShared=True), True), ('forbidden-layout', dict(valid, pageLayout='ALL'), True),
            ('unknown-key', dict(valid, nativeCommand='.uno:Landscape'), True),
        ]
        unused = next((row for row in initial['pageStyles'] if row['inUse'] is False
            and row['id'] not in {item['id'] for item in bindings}), None)
        if unused is not None:
            invalid.append(('unused-unbound-style', geometry(unused, leftMargin=0), True))
        report['unusedUnboundStyleObserved'] = None if unused is None else unused['id']
        for name, operation, source_hash in invalid:
            no_publish(runtime, source, output, 'rejected-' + name, report, [operation], source_hash)
        no_publish(runtime, source, output, 'rejected-late-batch', report, [valid, dict(valid, expectedLayoutSha256='0' * 64)])
        report['readonlyNativeCase'] = 'Not synthesized: actual descriptor evidence retained; controlled invariant belongs in pure test'
        return
    if case == 'identity':
        source = create_twins(runtime, output, report)
        initial = request(runtime, source, output, 'inspect-twins', report)['snapshot']
        bindings = inspect_bindings(runtime, source, initial, output, 'twin-native-binding', report)
        assert len(bindings) == 2 and bindings[0]['id'] != bindings[1]['id']
        assert bindings[0]['raw'] == bindings[1]['raw'] and bindings[0]['layoutSha256'] == bindings[1]['layoutSha256'], bindings
        target = bindings[1]
        report['twinBindings'] = bindings
    elif case == 'reflow':
        derived = output / 'reflow-with-owners.docx'
        create_reflow(source, derived)
        source = derived
        report['derivedSources'][str(source)] = worker.digest(source)
        initial = request(runtime, source, output, 'inspect-reflow', report)['snapshot']
        bindings = inspect_bindings(runtime, source, initial, output, 'reflow-native-binding', report)
        target = bindings[-1]
    baseline = request(runtime, source, output, 'no-op-control', report, [])
    baseline_package = package_evidence(baseline['sourcePath'])
    if case in ('geometry', 'identity'):
        operation = geometry(target, width=297, height=210.01, landscape=True,
            leftMargin=25.4, rightMargin=18, topMargin=20, bottomMargin=21)
        expected = {'Width': 29700, 'Height': 21001, 'IsLandscape': True,
            'LeftMargin': 2540, 'RightMargin': 1799, 'TopMargin': 2000, 'BottomMargin': 2101}
    elif case == 'margin':
        operation, expected = geometry(target, leftMargin=0, rightMargin=0), {'LeftMargin': 0, 'RightMargin': 0}
    elif case == 'reverse':
        operation, expected = geometry(target, width=210.01, height=297, landscape=False), {
            'Width': 21001, 'Height': 29700, 'IsLandscape': False}
    elif case == 'reflow':
        # One and five inches are exact native/twip conversions. This fixture
        # avoids relying on the still separately probed rounding boundaries.
        operation, expected = geometry(target, leftMargin=25.4, rightMargin=127), {'LeftMargin': 2540, 'RightMargin': 12700}
    else:
        operation = geometry(target, width=297, height=210.01, landscape=True)
        expected = {'Width': 29700, 'Height': 21001, 'IsLandscape': True}
    operations = [operation]
    if case == 'journal':
        owner = first_header(initial)
        reference = next(item for item in owner['paragraphs'] if item['text'] == '' and item['structure']['canInsertBefore'])
        header_table = next(item for item in initial['tables'] if item['id'] == owner['tableIds'][0])
        header_cell = next(iter(header_table['cells']))
        original_cell = header_table['cells'][header_cell]
        assert header_table['ownerId'] == owner['id']
        assert {(ref['pageStyleId'], ref['variant']) for ref in owner['references']} == {
            (target['id'], 'default'), (target['id'], 'right')}
        assert any(paragraph['text'].split('\n')[-1].startswith('A_HeaderText PAGE=') for paragraph in owner['paragraphs'])
        selected_bookmark = 'PIV_A_HeaderText'
        operations += [{'op': 'tableCellText', 'tableId': header_table['id'], 'cell': header_cell,
                'text': original_cell + ' JOURNAL_CELL_EDIT'},
            insert('geometry-created', reference['id'], '', 'before', 'LEFT RIGHT'),
            split('geometry-created', 'geometry-created-right', 'LEFT RIGHT', 4),
            {'op': 'textReplace', 'targetKind': 'paragraph', 'id': 'geometry-created-right',
             'startUtf16': 1, 'endUtf16': 6, 'expectedTextSha256': text_hash(' RIGHT'), 'text': 'EDITED'}]
    result = request(runtime, source, output, 'geometry-positive', report, operations, draft=case == 'journal')
    report['feature'] = result
    observed = independent_saved(runtime, result, output, 'independent-reopen', report)
    report['observed'] = observed
    if expected is not None:
        compare_target(bindings, observed['bindings'], target, expected)
    assert all(row['canEditGeometry'] is True for row in observed['bindings']), 'Native capability must be explicit for bound writable used styles'
    if case != 'journal':
        assert observed['package'] == baseline_package, 'Geometry lost authored text/fields/bookmarks/tables/media beyond no-op control'
    else:
        expected_package = copy.deepcopy(baseline_package)
        touched_parts = []
        for name, part in expected_package['parts'].items():
            if selected_bookmark in part['bookmarks']:
                assert part['authored'].count(original_cell) == 1
                part['authored'] = part['authored'].replace(original_cell, original_cell + ' JOURNAL_CELL_EDIT', 1) + 'LEFT EDITED'
                touched_parts.append(name)
        assert len(touched_parts) == 1, touched_parts
        report['journalExpectedPart'] = {'part': touched_parts[0], 'bookmark': selected_bookmark,
            'ownerId': owner['id'], 'references': owner['references'], 'tableId': header_table['id'], 'cell': header_cell}
        assert observed['package'] == expected_package, 'Geometry journal lost unrelated authored content/fields/bookmarks/tables/media'
    if case in ('geometry', 'identity', 'reverse'):
        target_pages = [page for page in observed['pdf']['pages'] if ('TWIN_BODY_1' in page['text'] if case == 'identity'
            else any(marker in page['text'] for marker in ['BODY_PAGE_2', 'BODY_PAGE_3']) or ('BODY PAGE=' in page['text']))]
        assert target_pages
        for page in target_pages:
            width, height = (210.01, 297) if case == 'reverse' else (297, 210.01)
            assert abs(page['physicalWidthPt'] - width / 25.4 * 72) < 0.01
            assert abs(page['physicalHeightPt'] - height / 25.4 * 72) < 0.01
        report['physicalTargetPages'] = target_pages
    if case == 'reflow':
        before_pdf = pdf_evidence(baseline['pdfPath'])
        assert before_pdf['pageCount'] != observed['pdf']['pageCount'], 'Reflow fixture did not exercise a page-count change'
        visible = ''.join(page['text'] for page in observed['pdf']['pages'])
        assert all('REFLOW_' + str(index) in visible for index in range(36))
        for page in observed['pdf']['pages']:
            compact = ''.join(page['text'].split())
            assert 'NUMPAGES=' + str(observed['pdf']['pageCount']) in compact
            assert 'PAGE=' + str(page['page']) in compact
        report['reflowBeforePdf'] = before_pdf
    if case == 'journal':
        draft = result['draftSnapshot']
        assert draft['sourceSha256'] == worker.digest(source)
        assert [row['id'] for row in draft['pageStyles']] == [row['id'] for row in initial['pageStyles']]
        live_owner = next(row for row in draft['wordOwners'] if row['id'] == owner['id'])
        assert live_owner['references'] == owner['references']
        assert {row['id']: row['text'] for row in live_owner['paragraphs']}['geometry-created-right'] == ' EDITED'
        live_style = next(row for row in draft['pageStyles'] if row['id'] == target['id'])
        follow = operations + [geometry(live_style, leftMargin=0)]
        replay = request(runtime, source, output, 'journal-replay-next-geometry', report, follow, draft=True)
        assert next(row for row in replay['draftSnapshot']['pageStyles'] if row['id'] == target['id'])['leftMargin'] == 0
        assert next(row for row in replay['draftSnapshot']['wordOwners'] if row['id'] == owner['id'])['references'] == owner['references']
        report['journalReplay'] = independent_saved(runtime, replay, output, 'replay-reopen', report)


def run(runtime, source, output, selected_case, previous_result=None):
    output.mkdir(parents=True, exist_ok=False)
    native_paths = [Path(__file__).with_name(name) for name in ['office_worker.py', 'office_word.py', 'office_word_layout.py', 'office_text.py']]
    report = {'passed': False, 'case': selected_case, 'source': str(source), 'sourceOriginalSha256': worker.digest(source),
        'testSha256': worker.digest(Path(__file__)), 'productSourceSha256': {path.name: worker.digest(path) for path in native_paths},
        'requests': [], 'rejections': [], 'independentServers': [], 'derivedSources': {},
        'execution': 'Fresh real run_request per request; fresh owned independent servers; no factory patch or timeout override',
        'canonicalBinding': 'Ordered actual body paragraph block usage groups across saves; native PageStyleName family keys within one document only; wrapper equality is diagnostic',
        'requestLifecycleObservations': None}
    factory = worker.OfficeServer
    try:
        assert report['sourceOriginalSha256'] == SOURCE_SHA256, 'Use fixed owner-probe1/no-op-resaved.docx'
        worker.initialize(runtime)
        run_case(selected_case, runtime, source, output, report, previous_result)
        report['passed'] = True
    except BaseException:
        report['exception'] = traceback.format_exc()
        raise
    finally:
        report['sourceHashUnchanged'] = worker.digest(source) == report['sourceOriginalSha256']
        report['testHashUnchanged'] = worker.digest(Path(__file__)) == report['testSha256']
        report['productSourcesUnchanged'] = all(worker.digest(path) == report['productSourceSha256'][path.name] for path in native_paths)
        report['derivedSourcesUnchanged'] = all(worker.digest(Path(path)) == value for path, value in report['derivedSources'].items())
        report['officeServerFactoryUnchanged'] = worker.OfficeServer is factory
        if not all(report[key] for key in ['sourceHashUnchanged', 'testHashUnchanged', 'productSourcesUnchanged', 'derivedSourcesUnchanged', 'officeServerFactoryUnchanged']):
            report['passed'] = False
        flush(report, output)
    assert report['passed']
    print(json.dumps({'passed': True, 'case': selected_case, 'requests': len(report['requests'])}))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--runtime', type=Path, required=True)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--case', choices=CASES, default='geometry')
    parser.add_argument('--previous-result', type=Path)
    args = parser.parse_args()
    run(args.runtime.resolve(), args.source.resolve(), args.output.resolve(), args.case,
        args.previous_result.resolve() if args.previous_result is not None else None)
