"""Real ordered Word body edits with alias, rich-content and table boundaries."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import sys
import traceback
import xml.etree.ElementTree as ET
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import office_worker as worker
from test_rich_native import create_sources, word_evidence

W = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main'
NS = {'w': W}


def text_hash(value):
    return hashlib.sha256(value.encode('utf-8')).hexdigest()


def paragraph(text, mixed=False):
    element = ET.Element('{' + W + '}p')
    properties = ET.SubElement(element, '{' + W + '}pPr')
    ET.SubElement(properties, '{' + W + '}pStyle', {'{' + W + '}val': 'Normal'})
    pieces = [('LEFT', 'CC2200', '24', False), ('😀RIGHT', '0033CC', '48', True)] if mixed else [(text, '336633', '28', False)]
    for content, color, size, bold in pieces:
        run = ET.SubElement(element, '{' + W + '}r')
        style = ET.SubElement(run, '{' + W + '}rPr')
        ET.SubElement(style, '{' + W + '}color', {'{' + W + '}val': color})
        ET.SubElement(style, '{' + W + '}sz', {'{' + W + '}val': size})
        if bold:
            ET.SubElement(style, '{' + W + '}b')
        ET.SubElement(run, '{' + W + '}t').text = content
    return element


def rewrite_body(source, destination, transform):
    with zipfile.ZipFile(source) as original, zipfile.ZipFile(destination, 'w', zipfile.ZIP_DEFLATED) as output:
        for member in original.infolist():
            data = original.read(member.filename)
            if member.filename == 'word/document.xml':
                document = ET.fromstring(data)
                transform(document.find('w:body', NS))
                data = ET.tostring(document, encoding='utf-8', xml_declaration=True)
            output.writestr(member, data)


def create_structure_source(output):
    def enrich(body):
        table = body.find('w:tbl', NS)
        body.insert(list(body).index(table), paragraph('BEFORE TABLE'))
        old_tail = body.findall('w:p', NS)[-1]
        body.remove(old_tail)
        section = body.find('w:sectPr', NS)
        position = list(body).index(section)
        for value in [paragraph('LEFT😀RIGHT', mixed=True), paragraph('SECOND'), paragraph('DELETE ME'), paragraph('')]:
            body.insert(position, value)
            position += 1
    source = output / 'structure.docx'
    rewrite_body(output / 'rich.docx', source, enrich)
    def sole(body):
        section = body.find('w:sectPr', NS)
        body[:] = [paragraph('ONLY'), section]
    rewrite_body(source, output / 'sole.docx', sole)
    return source


def apply(runtime, source, output, name, operations):
    return worker.run_request(runtime, {'mode': 'apply', 'sourcePath': str(source),
        'sessionId': name, 'expectedSourceSha256': worker.digest(source), 'operations': operations}, output / name)


def ordered_text(snapshot):
    values = {item['id']: item['text'] for item in snapshot['paragraphs']}
    return [values[item['id']] if item['kind'] == 'paragraph' else '<' + item['kind'].upper() + '>' for item in snapshot['blocks']]


def split(identifier, new_id, content, offset):
    return {'op': 'paragraphSplit', 'id': identifier, 'newId': new_id,
        'offsetUtf16': offset, 'expectedTextSha256': text_hash(content)}


def insert(identifier, reference, content, position, text):
    return {'op': 'paragraphInsert', 'id': identifier, 'referenceId': reference,
        'position': position, 'expectedTextSha256': text_hash(content), 'text': text}


def delete(identifier, content):
    return {'op': 'paragraphDelete', 'id': identifier, 'expectedTextSha256': text_hash(content)}


def join(identifier, following, left_text, right_text):
    return {'op': 'paragraphJoin', 'id': identifier, 'nextId': following,
        'expectedTextSha256': text_hash(left_text), 'expectedNextTextSha256': text_hash(right_text)}


def rejected_in_server(server, source, operations, directory):
    directory.mkdir()
    working = directory / 'working.docx'
    shutil.copyfile(source, working)
    document = server.load(working)
    try:
        try:
            worker.apply_operations(document, operations, context=server.context)
        except (ValueError, KeyError):
            return
        raise AssertionError('Unsafe Word structure operation was accepted: ' + directory.name)
    finally:
        document.close(True)


def run(runtime, output):
    worker.initialize(runtime)
    output.mkdir(parents=True, exist_ok=False)
    create_sources(runtime, output)
    source = create_structure_source(output)
    original_hash = worker.digest(source)
    initial = worker.run_request(runtime, {'mode': 'inspect', 'sourcePath': str(source)}, output / 'inspect')['snapshot']
    (output / 'initial-snapshot.json').write_text(json.dumps(initial, ensure_ascii=False, indent=2), encoding='utf-8')
    assert 'blocks' in initial, 'Word native snapshot does not expose the actual paragraph/table body order'
    assert ordered_text(initial) == ['A😀éB1TAIL', 'BEFORE TABLE', '<TABLE>', 'LEFT😀RIGHT', 'SECOND', 'DELETE ME', '']
    assert all('paragraphFormat' in item and 'structure' in item for item in initial['paragraphs'])
    by_text = {item['text']: item for item in initial['paragraphs']}
    rich = by_text['A😀éB1TAIL']
    before = by_text['BEFORE TABLE']
    middle = by_text['LEFT😀RIGHT']
    second = by_text['SECOND']
    removed = by_text['DELETE ME']
    assert rich['structure']['canDelete'] is False
    assert before['structure']['canJoinNext'] is False, 'A table is not an adjacent paragraph'
    assert middle['structure']['canSplit'] and removed['structure']['canDelete']
    heading = next(item['name'] for item in initial['paragraphStyles'] if item['name'].replace(' ', '') == 'Heading1')
    baseline = apply(runtime, source, output, 'no-op', [])
    baseline_evidence = word_evidence(baseline['sourcePath'])
    operations = [
        insert('created-before', before['id'], before['text'], 'before', 'INSERTED'),
        {'op': 'textReplace', 'targetKind': 'paragraph', 'id': 'created-before',
         'startUtf16': 8, 'endUtf16': 8, 'expectedTextSha256': text_hash('INSERTED'), 'text': '!'},
        split(middle['id'], 'split-right', middle['text'], 6),
        {'op': 'paragraphFormat', 'id': middle['id'], 'expectedTextSha256': text_hash('LEFT😀'),
         'styleName': heading, 'alignment': 'center', 'listKind': 'number', 'listLevel': 0, 'pageBreakBefore': True},
        split(rich['id'], 'field-right', rich['text'], 3),
        join('split-right', second['id'], 'RIGHT', second['text']),
        delete(removed['id'], removed['text']),
        insert('created-after', before['id'], before['text'], 'after', 'AFTER'),
        {'op': 'paragraphFormat', 'id': 'created-after', 'expectedTextSha256': text_hash('AFTER'),
         'alignment': 'right', 'listKind': 'bullet', 'listLevel': 1, 'pageBreakBefore': False},
    ]
    result = apply(runtime, source, output, 'structure-edited', operations)
    (output / 'edit-result.json').write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
    current = result['snapshot']
    assert ordered_text(current) == ['A😀', 'éB1TAIL', 'INSERTED!', 'BEFORE TABLE', 'AFTER', '<TABLE>', 'LEFT😀', 'RIGHTSECOND', '']
    assert word_evidence(result['sourcePath']) == baseline_evidence, 'Structure editing changed untouched field/bookmark/image or TAIL formatting'
    final = {item['text']: item for item in current['paragraphs']}
    assert final['LEFT😀']['paragraphFormat'] == {'styleName': heading, 'alignment': 'center',
        'listKind': 'number', 'listLevel': 0, 'pageBreakBefore': True}, final['LEFT😀']
    assert final['AFTER']['paragraphFormat']['alignment'] == 'right'
    assert final['AFTER']['paragraphFormat']['listKind'] == 'bullet'
    assert final['AFTER']['paragraphFormat']['listLevel'] == 1
    assert final['RIGHTSECOND']['paragraphFormat']['styleName'] == middle['paragraphFormat']['styleName']
    assert current['tables'][0]['cells'] == baseline['snapshot']['tables'][0]['cells']
    assert result['pdfPageCount'] >= 2
    pdf_text = ''.join(''.join(page.extract_text().split()) for page in worker.PdfReader(result['pdfPath']).pages)
    assert 'INSERTED!' in pdf_text and 'RIGHTSECOND' in pdf_text and 'DELETEME' not in pdf_text
    invalid = [
        [join(before['id'], middle['id'], before['text'], middle['text'])],
        [split(middle['id'], 'half-surrogate', middle['text'], 5)],
        [split(rich['id'], 'field-affinity', rich['text'], 6)],
        [split(rich['id'], 'bookmark-affinity', rich['text'], 7)],
        [delete(rich['id'], rich['text'])],
        [split(middle['id'], second['id'], middle['text'], 6)],
        [delete(removed['id'], removed['text']), insert(removed['id'], before['id'], before['text'], 'before', 'reuse')],
        [split(middle['id'], 'retired', middle['text'], 6), join(middle['id'], 'retired', 'LEFT😀', 'RIGHT'),
         insert('retired', before['id'], before['text'], 'after', 'reuse')],
        [split(middle['id'], 'right', middle['text'], 6), delete(middle['id'], middle['text'])],
        [{'op': 'paragraphFormat', 'id': middle['id'], 'expectedTextSha256': text_hash(middle['text']), 'styleName': 'DOES NOT EXIST'}],
        [{'op': 'paragraphFormat', 'id': middle['id'], 'expectedTextSha256': text_hash(middle['text']), 'alignment': 'other'}],
        [{'op': 'paragraphFormat', 'id': middle['id'], 'expectedTextSha256': text_hash(middle['text']), 'listKind': 'number', 'listLevel': 9}],
        [{'op': 'paragraphFormat', 'id': middle['id'], 'expectedTextSha256': text_hash(middle['text'])}],
        [{'op': 'paragraphFormat', 'id': middle['id'], 'expectedTextSha256': text_hash(middle['text']), 'alignment': None}],
        [insert('newline', before['id'], before['text'], 'before', 'two\nparagraphs')],
        [dict(delete(removed['id'], removed['text']), expectedTextSha256='0' * 64)],
        [dict(split(middle['id'], 'extra-key', middle['text'], 6), nativeCommand='.uno:Delete')],
        [insert('table-owner', initial['tables'][0]['id'], '', 'after', 'wrong scope')],
    ]
    with worker.OfficeServer(runtime, output) as server:
        for index, batch in enumerate(invalid):
            rejected_in_server(server, source, batch, output / ('rejected-' + str(index)))
        sole = output / 'sole.docx'
        rejected_in_server(server, sole, [delete('paragraph-0', 'ONLY')], output / 'rejected-sole')
        rejected_in_server(server, output / 'rich.docx', [delete('paragraph-1', '')], output / 'rejected-table-tail')
    rejected = output / 'rejected-publication'
    try:
        apply(runtime, source, output, rejected.name, [split(middle['id'], middle['id'], middle['text'], 6)])
    except ValueError:
        pass
    else:
        raise AssertionError('Reused paragraph ID was published by the real worker')
    assert not (rejected / 'edited.docx').exists() and not (rejected / 'preview.pdf').exists()
    assert worker.digest(source) == original_hash
    report = {'passed': True, 'originalSourceHashUnchanged': True, 'fieldBookmarkMediaAndUntouchedRunsPreserved': True,
        'mixedBodyOrderPreserved': True, 'sequentialAliasesAndProtectedTables': True,
        'invalidNativeBatchesRejected': len(invalid) + 2, 'noOpBaseline': baseline, 'feature': result}
    (output / 'result.json').write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps({'passed': True, 'invalidNativeBatchesRejected': len(invalid) + 2}))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--runtime', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    try:
        run(args.runtime.resolve(), args.output.resolve())
    except BaseException:
        Path(str(args.output) + '.error.txt').write_text(traceback.format_exc(), encoding='utf-8')
        raise
