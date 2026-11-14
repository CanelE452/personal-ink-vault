"""Real Writer owner metadata, scoped edits and publication rejection.

The source is the frozen owner-probe1 no-op control, not the first export whose
hidden duplicated first-page parts normalize on import. Every request uses the
unmodified run_request/OfficeServer path. This file does not set page flags.
"""
import argparse
from contextlib import contextmanager
import hashlib
import json
from pathlib import Path
import sys
import traceback
import xml.etree.ElementTree as ET
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import office_worker as worker
from test_word_structure_native import delete, insert, join, split, text_hash

SOURCE_SHA256 = '47dbf7c5d7f7c77dfac11cb4f0ec863966476f71587ae15eb8d80dea9b2feeac'
NS = {'w': 'http://schemas.openxmlformats.org/wordprocessingml/2006/main'}
W = '{' + NS['w'] + '}'
REGIONS = {'default': '', 'left': 'Left', 'right': 'Right', 'first': 'First'}
LAYOUT = {'width': 'Width', 'height': 'Height', 'leftMargin': 'LeftMargin',
    'rightMargin': 'RightMargin', 'topMargin': 'TopMargin', 'bottomMargin': 'BottomMargin',
    'landscape': 'IsLandscape', 'headerIsOn': 'HeaderIsOn', 'footerIsOn': 'FooterIsOn',
    'headerIsShared': 'HeaderIsShared', 'footerIsShared': 'FooterIsShared',
    'firstIsShared': 'FirstIsShared', 'pageLayout': 'PageStyleLayout'}
MEASUREMENTS = {'width', 'height', 'leftMargin', 'rightMargin', 'topMargin', 'bottomMargin'}


def flush(report, output):
    (output / 'result.json').write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')


def optional(value, name):
    try:
        return value.getPropertyValue(name)
    except Exception:
        return None


def raw_property(value, name):
    result = optional(value, name)
    return getattr(result, 'value', result)


def enumerate_text(text):
    enumeration = text.createEnumeration()
    while enumeration.hasMoreElements():
        yield enumeration.nextElement()


@contextmanager
def independent_server(runtime, directory, report):
    directory.mkdir()
    owner = worker.OfficeServer(runtime, directory)
    event = {'directory': str(directory), 'entered': False, 'exitCompleted': False}
    report['independentServers'].append(event)
    try:
        with owner as server:
            event['entered'] = True
            yield server
        event['exitCompleted'] = True
    finally:
        profile, process = getattr(owner, 'profile', None), getattr(owner, 'process', None)
        event['ownedProfileRemoved'] = None if profile is None else not profile.exists()
        for attribute, label in [('process', 'ownedLoaderHandleClosed'), ('job', 'ownedJobHandleClosed')]:
            event[label] = None if process is None else not bool(getattr(process, attribute, None))


def check_native(snapshot, document):
    """Resolve snapshot IDs through native references, never paragraph text."""
    assert snapshot['bodyOwnerId'] == 'body'
    styles, owners = snapshot['pageStyles'], snapshot['wordOwners']
    family = document.StyleFamilies.getByName('PageStyles')
    assert {item['name'] for item in styles} == set(family.ElementNames)
    owner_rows = {item['id']: item for item in owners}
    assert len(owner_rows) == len(owners) and 'body' not in owner_rows
    texts, references, false_values, zero_values = {'body': document.Text}, {}, [], []
    declared = {'body'}

    def reserve(identifier):
        assert isinstance(identifier, str) and identifier and identifier not in declared, identifier
        declared.add(identifier)

    for table in snapshot['tables']:
        reserve(table['id'])
    for paragraph in snapshot['paragraphs']:
        reserve(paragraph['id'])
    for owner in owners:
        reserve(owner['id'])
        assert owner['kind'] in ('header', 'footer')
        for paragraph in owner['paragraphs']:
            reserve(paragraph['id'])
    for row in styles:
        reserve(row['id'])
        native = family.getByName(row['name'])
        assert row['displayName'] == (optional(native, 'DisplayName') or row['name'])
        assert row['inUse'] is native.isInUse()
        raw = {name: raw_property(native, name) for name in LAYOUT.values()}
        expected_hash = hashlib.sha256(json.dumps(raw, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode('utf-8')).hexdigest()
        assert row['layoutSha256'] == expected_hash, (row['name'], raw, row)
        for key, name in LAYOUT.items():
            expected = raw[name]
            if key in MEASUREMENTS and expected is not None:
                expected /= 100
            assert row[key] == expected, (row['name'], key, row[key], expected)
            if expected is False:
                false_values.append((row['name'], key))
            elif type(expected) in (int, float) and expected == 0:
                zero_values.append((row['name'], key))
        for kind, prefix in [('header', 'HeaderText'), ('footer', 'FooterText')]:
            assert set(row['regions'][kind]) == set(REGIONS)
            for variant, suffix in REGIONS.items():
                actual = optional(native, prefix + suffix)
                identifier = row['regions'][kind][variant]
                if actual is None:
                    assert identifier is None
                    continue
                assert identifier in owner_rows and owner_rows[identifier]['kind'] == kind
                if identifier in texts:
                    assert texts[identifier] == actual, 'Different XText objects were merged'
                else:
                    assert all(previous != actual for previous in texts.values()), 'One XText was emitted twice'
                    texts[identifier] = actual
                references.setdefault(identifier, []).append({'pageStyleId': row['id'], 'variant': variant})
    assert false_values, 'The fixture must exercise false, not omit it as unknown'
    assert set(texts) == {'body'} | set(owner_rows)
    tables = {item['id']: item for item in snapshot['tables']}
    assert set(tables) == set(document.TextTables.ElementNames)
    block_tables, duplicate_text_owners = {}, []
    for identifier, native in texts.items():
        row = snapshot if identifier == 'body' else owner_rows[identifier]
        if identifier != 'body':
            assert sorted(row['references'], key=lambda item: (item['pageStyleId'], item['variant'])) == sorted(
                references[identifier], key=lambda item: (item['pageStyleId'], item['variant']))
        paragraphs = iter(row['paragraphs'])
        actual = list(enumerate_text(native))
        assert len(row['blocks']) == len(actual)
        for block, value in zip(row['blocks'], actual):
            if value.supportsService('com.sun.star.text.Paragraph'):
                paragraph = next(paragraphs)
                assert block == {'kind': 'paragraph', 'id': paragraph['id']}
                assert paragraph['ownerId'] == identifier and paragraph['text'] == value.String
                assert value.getText() == native
                assert 'textDetails' in paragraph and 'structure' in paragraph and 'paragraphFormat' in paragraph
                if paragraph['text'].startswith('DUPLICATE_OWNER_TEXT'):
                    duplicate_text_owners.append(identifier)
            elif value.supportsService('com.sun.star.text.TextTable'):
                assert block == {'kind': 'table', 'id': value.Name}
                assert value.Name not in block_tables
                assert value == document.TextTables.getByName(value.Name), 'Owner enumeration must bind the actual global table proxy'
                block_tables[value.Name] = identifier
            else:
                assert block['kind'] == 'opaque'
                reserve(block['id'])
        assert next(paragraphs, None) is None
        if identifier != 'body':
            assert row['tableIds'] == [block['id'] for block in row['blocks'] if block['kind'] == 'table']
    assert len(set(duplicate_text_owners)) >= 5, 'Equal authored prefixes need separate native owners'
    assert [row['id'] for row in snapshot['paragraphs']] == [
        'paragraph-' + str(index) for index in range(len(snapshot['paragraphs']))]
    unknown_anchors = []
    for name, row in tables.items():
        table = document.TextTables.getByName(name)
        anchor_text = table.getAnchor().getText()
        if anchor_text is None:
            # owner-probe1 observed null anchor.getText(); native enumeration is
            # separate evidence and must not be described as an anchor result.
            unknown_anchors.append(name)
            assert row['ownerId'] == block_tables.get(name)
        else:
            actual_id = next((key for key, text in texts.items() if text == anchor_text), None)
            assert row['ownerId'] == actual_id
        for cell_name in table.CellNames:
            assert table.getCellByName(cell_name) != texts.get(row['ownerId'])
    return {'owners': len(owners), 'styles': len(styles), 'falseValues': false_values,
        'zeroValues': zero_values, 'zeroValueCoverageObserved': bool(zero_values), 'nullNativeTableAnchorText': unknown_anchors,
        'tableOwnersFromEnumeration': block_tables}


def package_evidence(path):
    """Exclude only field result text; retain authored text and field commands."""
    result = {'parts': {}, 'media': {}}
    with zipfile.ZipFile(path) as archive:
        assert archive.testzip() is None
        for name in sorted(archive.namelist()):
            if name.startswith('word/media/'):
                result['media'][name] = hashlib.sha256(archive.read(name)).hexdigest()
            if name != 'word/document.xml' and not (name.startswith(('word/header', 'word/footer')) and name.endswith('.xml')):
                continue
            root, depth, authored, commands = ET.fromstring(archive.read(name)), 0, [], []
            for element in root.iter():
                if element.tag == W + 'fldChar':
                    if element.get(W + 'fldCharType') == 'begin':
                        depth += 1
                    elif element.get(W + 'fldCharType') == 'end':
                        depth -= 1
                        assert depth >= 0
                elif element.tag == W + 't' and not depth:
                    authored.append(element.text or '')
                elif element.tag == W + 'instrText':
                    commands.append(' '.join((element.text or '').split()))
                elif element.tag == W + 'fldSimple':
                    commands.append(' '.join((element.get(W + 'instr') or '').split()))
            assert depth == 0
            result['parts'][name] = {'authored': ''.join(authored), 'fieldCommands': commands,
                'bookmarks': sorted(item.get(W + 'name') for item in root.findall('.//w:bookmarkStart', NS)),
                'tables': len(root.findall('.//w:tbl', NS))}
    return result


def apply(runtime, source, directory, operations):
    return worker.run_request(runtime, {'mode': 'apply', 'sourcePath': str(source),
        'sessionId': directory.name, 'expectedSourceSha256': worker.digest(source), 'operations': operations}, directory)


def find_owner(snapshot, marker):
    return next(item for item in snapshot['wordOwners'] if any(marker in paragraph['text'] for paragraph in item['paragraphs']))


def saved(result):
    assert result['status'] == 'saved'
    assert worker.digest(Path(result['sourcePath'])) == result['sourceSha256']
    assert worker.digest(Path(result['pdfPath'])) == result['pdfSha256']
    pages = worker.PdfReader(result['pdfPath'], strict=True).pages
    assert len(pages) == result['pdfPageCount'] == 6
    return ''.join(''.join((page.extract_text() or '').split()) for page in pages)


def reject(runtime, source, output, name, operations, report):
    directory, source_hash = output / name, worker.digest(source)
    event = {'name': name, 'sourceSha256': source_hash, 'accepted': None}
    report['rejections'].append(event)
    try:
        result = apply(runtime, source, directory, operations)
    except (ValueError, KeyError) as error:
        event.update(accepted=False, exceptionType=type(error).__name__, message=str(error))
    else:
        event.update(accepted=True, result=result)
        raise AssertionError('Unsafe owner operation was published: ' + name)
    finally:
        event['sourceHashUnchanged'] = worker.digest(source) == source_hash
        event['publishedOriginal'] = (directory / 'edited.docx').exists()
        event['publishedPdf'] = (directory / 'preview.pdf').exists()
        flush(report, output)
    assert event['sourceHashUnchanged'] and not event['publishedOriginal'] and not event['publishedPdf']


def sole_body(source, destination):
    with zipfile.ZipFile(source) as original, zipfile.ZipFile(destination, 'w', zipfile.ZIP_DEFLATED) as target:
        for member in original.infolist():
            data = original.read(member.filename)
            if member.filename == 'word/document.xml':
                root = ET.fromstring(data)
                body = root.find('w:body', NS)
                section = body.find('w:sectPr', NS)
                assert section is not None
                paragraph = ET.Element(W + 'p')
                ET.SubElement(ET.SubElement(paragraph, W + 'r'), W + 't').text = 'ONLY_BODY'
                body[:] = [paragraph, section]
                data = ET.tostring(root, encoding='utf-8', xml_declaration=True)
            target.writestr(member, data)


def run(runtime, source, output):
    output.mkdir(parents=True, exist_ok=False)
    report = {'passed': False, 'source': str(source), 'sourceOriginalSha256': worker.digest(source),
        'testSha256': worker.digest(Path(__file__)), 'independentServers': [], 'rejections': [],
        'execution': 'Unmodified run_request; fresh owned OfficeServer for every request and independent evidence phase',
        'requestLifecycleObservations': None, 'scope': 'Owner metadata and existing scoped operations; no page-setting write contract'}
    factory = worker.OfficeServer
    native_sources = [path for name in ['office_worker.py', 'office_word.py', 'office_word_layout.py', 'office_text.py']
        if (path := Path(__file__).with_name(name)).exists()]
    report['productSourceSha256'] = {path.name: worker.digest(path) for path in native_sources}
    try:
        assert report['sourceOriginalSha256'] == SOURCE_SHA256, 'Use the fixed owner-probe1/no-op-resaved.docx'
        worker.initialize(runtime)
        initial = worker.run_request(runtime, {'mode': 'inspect', 'sourcePath': str(source)}, output / 'inspect')['snapshot']
        report['initialSnapshot'] = initial
        flush(report, output)
        assert 'wordOwners' in initial and 'pageStyles' in initial, 'Writer inspect lacks actual header/footer owners and page styles'
        with independent_server(runtime, output / 'native-inventory', report) as server:
            document = server.load(source)
            try:
                report['nativeInventory'] = check_native(initial, document)
            finally:
                document.close(True)
        baseline = apply(runtime, source, output / 'no-op-control', [])
        report['noOp'] = baseline
        saved(baseline)
        header, footer = find_owner(initial, 'A_HeaderTextFirst'), find_owner(initial, 'A_FooterTextFirst')
        hp = next(item for item in header['paragraphs'] if 'A_HeaderTextFirst' in item['text'])
        ht = header['paragraphs'][-1]
        ft = footer['paragraphs'][-1]
        assert ht['text'] == ft['text'] == '' and ht['structure']['canSplit'] and ft['structure']['canSplit']
        table_id = header['tableIds'][0]
        table = next(item for item in initial['tables'] if item['id'] == table_id)
        cell = next(iter(table['cells']))
        operations = [
            {'op': 'textReplace', 'targetKind': 'paragraph', 'id': hp['id'], 'startUtf16': 0,
             'endUtf16': len('DUPLICATE_OWNER_TEXT'), 'expectedTextSha256': text_hash(hp['text']), 'text': 'HEADER_EDIT'},
            {'op': 'textStyle', 'targetKind': 'paragraph', 'id': hp['id'], 'startUtf16': 0, 'endUtf16': 11,
             'expectedTextSha256': text_hash(hp['text'].replace('DUPLICATE_OWNER_TEXT', 'HEADER_EDIT', 1)), 'bold': True},
            {'op': 'paragraphText', 'id': ht['id'], 'text': 'LEFT RIGHT'},
            {'op': 'paragraphStyle', 'id': ht['id'], 'color': 0x225588},
            split(ht['id'], 'owner-new-right', 'LEFT RIGHT', 4),
            insert('owner-inserted', 'owner-new-right', ' RIGHT', 'after', 'INSERTED'),
            {'op': 'textReplace', 'targetKind': 'paragraph', 'id': 'owner-inserted', 'startUtf16': 8,
             'endUtf16': 8, 'expectedTextSha256': text_hash('INSERTED'), 'text': '!'},
            join(ht['id'], 'owner-new-right', 'LEFT', ' RIGHT'),
            insert('owner-disposable', 'owner-inserted', 'INSERTED!', 'before', 'DELETE'),
            delete('owner-disposable', 'DELETE'),
            {'op': 'paragraphText', 'id': ft['id'], 'text': 'FOOTER_EDIT'},
            {'op': 'paragraphFormat', 'id': ft['id'], 'expectedTextSha256': text_hash('FOOTER_EDIT'), 'alignment': 'center'},
            {'op': 'tableCellText', 'tableId': table_id, 'cell': cell, 'text': 'HEADER_CELL_EDIT'},
            {'op': 'textReplace', 'targetKind': 'cell', 'id': table_id, 'cell': cell, 'startUtf16': 12,
             'endUtf16': 16, 'expectedTextSha256': text_hash('HEADER_CELL_EDIT'), 'text': 'DONE'},
        ]
        result = apply(runtime, source, output / 'owner-edited', operations)
        report['edited'] = result
        pdf_text = saved(result)
        assert all(token in pdf_text for token in ['HEADER_EDIT', 'LEFTRIGHT', 'INSERTED!', 'FOOTER_EDIT', 'HEADER_CELL_DONE'])
        independently = worker.run_request(runtime, {'mode': 'inspect', 'sourcePath': result['sourcePath'], 'preview': True}, output / 'independent-inspect')['snapshot']
        independent_pdf = independently.pop('previewPdfPath')
        independent_pages = independently.pop('previewPageCount')
        assert independently == result['snapshot'], 'Saved original independent reopen differs from canonical snapshot'
        baseline_pages = worker.PdfReader(baseline['pdfPath'], strict=True).pages
        edited_pages = worker.PdfReader(result['pdfPath'], strict=True).pages
        reopened_pages = worker.PdfReader(independent_pdf, strict=True).pages
        visible = lambda pages: [''.join((page.extract_text() or '').split()) for page in pages]
        baseline_visible, edited_visible, reopened_visible = visible(baseline_pages), visible(edited_pages), visible(reopened_pages)
        report['independentPdf'] = {'path': independent_pdf, 'sha256': worker.digest(Path(independent_pdf)),
            'pageCount': independent_pages, 'visibleText': reopened_visible}
        assert len(reopened_pages) == independent_pages == 6 and reopened_visible == edited_visible
        assert [index + 1 for index, text in enumerate(reopened_visible) if 'HEADER_CELL_DONE' in text] == [1]
        assert [index + 1 for index, text in enumerate(reopened_visible) if 'FOOTER_EDIT' in text] == [1]
        assert baseline_visible[1:] == edited_visible[1:], 'First-owner edits changed another visible page'
        with independent_server(runtime, output / 'independent-native', report) as server:
            document = server.load(Path(result['sourcePath']))
            try:
                report['editedNativeInventory'] = check_native(independently, document)
            finally:
                document.close(True)
        before, after = package_evidence(baseline['sourcePath']), package_evidence(result['sourcePath'])
        report['preservation'] = {'noOp': before, 'edited': after, 'fieldResultCachesExcluded': True,
            'mediaPresentInFixture': bool(before['media'])}
        assert before['media'] == after['media'] and set(before['parts']) == set(after['parts'])
        touched = []
        for name, original in before['parts'].items():
            expected = dict(original)
            if 'A_HeaderTextFirst' in original['authored']:
                expected['authored'] = original['authored'].replace('DUPLICATE_OWNER_TEXT', 'HEADER_EDIT', 1).replace(
                    table['cells'][cell], 'HEADER_CELL_DONE', 1) + 'LEFT RIGHTINSERTED!'
                touched.append(name)
            elif 'A_FooterTextFirst' in original['authored']:
                expected['authored'] += 'FOOTER_EDIT'
                touched.append(name)
            assert after['parts'][name] == expected, (name, expected, after['parts'][name])
        assert len(touched) == 2, touched
        edited_footer = find_owner(independently, 'A_FooterTextFirst')
        assert next(item for item in edited_footer['paragraphs'] if item['text'] == 'FOOTER_EDIT')['paragraphFormat']['alignment'] == 'center'
        edited_header = find_owner(independently, 'A_HeaderTextFirst')
        whole_styled = next(item for item in edited_header['paragraphs'] if item['text'] == 'LEFT RIGHT')
        assert whole_styled['color'] == 0x225588, 'Whole-paragraph style reached another owner or disappeared'
        range_styled = next(item for item in edited_header['paragraphs'] if item['text'].startswith('HEADER_EDIT'))
        prefix_runs = [item for item in range_styled['textDetails']['runs'] if item['startUtf16'] < 11 and item['endUtf16'] > 0]
        assert prefix_runs and all(item['bold'] is True for item in prefix_runs), 'Selected header style did not survive reopen'
        body = next(item for item in initial['paragraphs'] if item['structure']['canSplit'])
        other_header = find_owner(initial, 'A_HeaderTextLeft')
        other = other_header['paragraphs'][-1]
        protected = next(item for item in hp['textDetails']['protectedRanges'] if item['endUtf16'] > item['startUtf16'])
        invalid = [
            ('body-header-join', [join(body['id'], ht['id'], body['text'], '')]),
            ('header-footer-join', [join(ht['id'], ft['id'], '', '')]),
            ('different-header-join', [join(ht['id'], other['id'], '', other['text'])]),
            ('reuse-body-id', [split(ht['id'], body['id'], '', 0)]),
            ('reuse-table-id', [insert(table_id, ht['id'], '', 'after', 'COLLISION')]),
            ('reuse-style-id', [insert(initial['pageStyles'][0]['id'], ht['id'], '', 'after', 'COLLISION')]),
            ('reuse-owner-id', [split(ht['id'], footer['id'], '', 0)]),
            ('reuse-retired-in-other-owner', [insert('retired-owner-id', ht['id'], '', 'before', 'TEMP'),
                delete('retired-owner-id', 'TEMP'), insert('retired-owner-id', ft['id'], '', 'before', 'REUSED')]),
            ('header-page-break', [{'op': 'paragraphFormat', 'id': ht['id'], 'expectedTextSha256': text_hash(''), 'pageBreakBefore': True}]),
            ('footer-page-break-false', [{'op': 'paragraphFormat', 'id': ft['id'], 'expectedTextSha256': text_hash(''), 'pageBreakBefore': False}]),
            ('header-field-range', [{'op': 'textReplace', 'targetKind': 'paragraph', 'id': hp['id'],
                'startUtf16': protected['startUtf16'], 'endUtf16': protected['endUtf16'],
                'expectedTextSha256': text_hash(hp['text']), 'text': 'LOST_FIELD'}]),
            ('table-as-paragraph', [insert('wrong-table-owner', table_id, '', 'after', 'WRONG')]),
        ]
        for name, batch in invalid:
            reject(runtime, source, output, 'rejected-' + name, batch, report)
        sole = output / 'sole-body-with-owners.docx'
        sole_body(source, sole)
        sole_snapshot = worker.run_request(runtime, {'mode': 'inspect', 'sourcePath': str(sole)}, output / 'sole-inspect')['snapshot']
        assert len(sole_snapshot['paragraphs']) == 1 and sole_snapshot['wordOwners']
        assert sole_snapshot['paragraphs'][0]['structure']['canDelete'] is False
        reject(runtime, sole, output, 'rejected-required-last-body', [delete('paragraph-0', 'ONLY_BODY')], report)
        report['passed'] = True
    except BaseException:
        report['exception'] = traceback.format_exc()
        raise
    finally:
        report['sourceHashUnchanged'] = worker.digest(source) == report['sourceOriginalSha256']
        report['testHashUnchanged'] = worker.digest(Path(__file__)) == report['testSha256']
        report['productSourcesUnchanged'] = all(worker.digest(path) == report['productSourceSha256'][path.name] for path in native_sources)
        report['officeServerFactoryUnchanged'] = worker.OfficeServer is factory
        if not all(report[key] for key in ['sourceHashUnchanged', 'testHashUnchanged', 'productSourcesUnchanged', 'officeServerFactoryUnchanged']):
            report['passed'] = False
        flush(report, output)
    assert report['passed']
    print(json.dumps({'passed': True, 'rejections': len(report['rejections']), 'sourceHashUnchanged': report['sourceHashUnchanged']}))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--runtime', type=Path, required=True)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    run(args.runtime.resolve(), args.source.resolve(), args.output.resolve())
