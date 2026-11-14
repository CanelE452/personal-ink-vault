"""Real Word/Impress selected text edits against synthetic mixed OOXML fixtures."""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import sys
import traceback
import xml.etree.ElementTree as ET
import zipfile
import zlib

sys.path.insert(0, str(Path(__file__).resolve().parent))
import office_worker as worker

W = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main'
A = 'http://schemas.openxmlformats.org/drawingml/2006/main'
P = 'http://schemas.openxmlformats.org/presentationml/2006/main'
NS = {'w': W, 'a': A, 'p': P}


def text_hash(value):
    return hashlib.sha256(value.encode('utf-8')).hexdigest()


def fixture_png():
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 2, 2, 8, 2, 0, 0, 0)) +
            chunk(b'IDAT', zlib.compress(b'\x00\xff\x00\x00\x00\xff\x00\x00\x00\x00\xff\xff\xff\x00')) + chunk(b'IEND', b''))


def rich_word(source, target):
    for prefix, namespace in [('w', W), ('a', A),
        ('wp', 'http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing'),
        ('pic', 'http://schemas.openxmlformats.org/drawingml/2006/picture'),
        ('r', 'http://schemas.openxmlformats.org/officeDocument/2006/relationships')]:
        ET.register_namespace(prefix, namespace)
    image = fixture_png()
    drawing = ET.fromstring('''<w:r xmlns:w="''' + W + '''" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"
        xmlns:a="''' + A + '''" xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
      <w:drawing><wp:inline><wp:extent cx="190500" cy="190500"/><wp:docPr id="91" name="Untouched inline photo"/>
       <a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic>
        <pic:nvPicPr><pic:cNvPr id="91" name="inline.png"/><pic:cNvPicPr/></pic:nvPicPr>
        <pic:blipFill><a:blip r:embed="rIdRichImage"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>
        <pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="190500" cy="190500"/></a:xfrm>
          <a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>
       </pic:pic></a:graphicData></a:graphic>
      </wp:inline></w:drawing></w:r>''')
    with zipfile.ZipFile(source) as original, zipfile.ZipFile(target, 'w', zipfile.ZIP_DEFLATED) as output:
        for member in original.infolist():
            data = original.read(member.filename)
            if member.filename == 'word/document.xml':
                xml = ET.fromstring(data)
                xml.attrib.pop('{http://schemas.openxmlformats.org/markup-compatibility/2006}Ignorable', None)
                paragraph = xml.find('w:body/w:p', NS)
                for child in list(paragraph):
                    if child.tag != '{' + W + '}pPr':
                        paragraph.remove(child)
                for content, color, size in [('A', 'CC2200', '22'), ('😀éB', '0033CC', '32')]:
                    run = ET.SubElement(paragraph, '{' + W + '}r')
                    props = ET.SubElement(run, '{' + W + '}rPr')
                    ET.SubElement(props, '{' + W + '}color', {'{' + W + '}val': color})
                    ET.SubElement(props, '{' + W + '}sz', {'{' + W + '}val': size})
                    ET.SubElement(run, '{' + W + '}t').text = content
                field = ET.SubElement(paragraph, '{' + W + '}fldSimple', {'{' + W + '}instr': ' PAGE '})
                run = ET.SubElement(field, '{' + W + '}r')
                ET.SubElement(run, '{' + W + '}t').text = '1'
                ET.SubElement(paragraph, '{' + W + '}bookmarkStart', {'{' + W + '}id': '7', '{' + W + '}name': 'KeepBookmark'})
                run = ET.SubElement(paragraph, '{' + W + '}r')
                props = ET.SubElement(run, '{' + W + '}rPr')
                ET.SubElement(props, '{' + W + '}b')
                ET.SubElement(props, '{' + W + '}color', {'{' + W + '}val': '884499'})
                ET.SubElement(props, '{' + W + '}sz', {'{' + W + '}val': '38'})
                ET.SubElement(run, '{' + W + '}t').text = 'TAIL'
                ET.SubElement(paragraph, '{' + W + '}bookmarkEnd', {'{' + W + '}id': '7'})
                paragraph.append(drawing)
                data = ET.tostring(xml, encoding='utf-8', xml_declaration=True)
            elif member.filename == 'word/_rels/document.xml.rels':
                relationship = (b'<Relationship Id="rIdRichImage" '
                    b'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" '
                    b'Target="media/rich-inline.png"/>')
                data = data.replace(b'</Relationships>', relationship + b'</Relationships>')
            elif member.filename == '[Content_Types].xml':
                if not any(item.attrib.get('Extension') == 'png' for item in ET.fromstring(data)):
                    data = data.replace(b'</Types>', b'<Default Extension="png" ContentType="image/png"/></Types>')
            output.writestr(member, data)
        output.writestr('word/media/rich-inline.png', image)


def create_sources(runtime, output):
    with worker.OfficeServer(runtime, output) as server:
        writer = server.desktop.loadComponentFromURL('private:factory/swriter', '_blank', 0,
            (worker.prop('Hidden', True), worker.prop('MacroExecutionMode', 0)))
        try:
            writer.Text.String = 'A😀éBTAIL'
            table = writer.createInstance('com.sun.star.text.TextTable')
            table.initialize(1, 1)
            writer.Text.insertTextContent(writer.Text.End, table, False)
            table.getCellByName('A1').String = 'A😀éB'
            base = output / 'plain.docx'
            writer.storeToURL(base.as_uri(), (worker.prop('FilterName', worker.FILTERS['docx']),))
        finally:
            writer.close(True)
        slides = server.desktop.loadComponentFromURL('private:factory/simpress', '_blank', 0,
            (worker.prop('Hidden', True), worker.prop('MacroExecutionMode', 0)))
        try:
            page = slides.DrawPages.getByIndex(0)
            while page.Count:
                page.remove(page.getByIndex(0))
            shape = slides.createInstance('com.sun.star.drawing.TextShape')
            page.add(shape)
            shape.Position = worker.uno.createUnoStruct('com.sun.star.awt.Point', 1000, 1000)
            shape.Size = worker.uno.createUnoStruct('com.sun.star.awt.Size', 18000, 4000)
            shape.String = 'A😀éB'
            cursor = shape.Text.createTextCursor()
            cursor.gotoStart(False)
            cursor.goRight(1, True)
            cursor.CharColor = 0xCC2200
            cursor.gotoEnd(False)
            slides.storeToURL((output / 'rich.pptx').as_uri(), (worker.prop('FilterName', worker.FILTERS['pptx']),))
        finally:
            slides.close(True)
    rich_word(output / 'plain.docx', output / 'rich.docx')


def word_evidence(path):
    with zipfile.ZipFile(path) as archive:
        xml = ET.fromstring(archive.read('word/document.xml'))
        tail = next(run for run in xml.findall('.//w:r', NS) if ''.join(item.text or '' for item in run.findall('w:t', NS)) == 'TAIL')
        field_instructions = [item.text or '' for item in xml.findall('.//w:instrText', NS)]
        field_instructions += [item.get('{' + W + '}instr', '') for item in xml.findall('.//w:fldSimple', NS)]
        return {
            'fields': field_instructions,
            'bookmarkNames': [item.get('{' + W + '}name') for item in xml.findall('.//w:bookmarkStart', NS)],
            'drawings': len(xml.findall('.//w:drawing', NS)),
            'media': sorted(hashlib.sha256(archive.read(name)).hexdigest() for name in archive.namelist() if name.startswith('word/media/')),
            'tailProperties': ET.tostring(tail.find('w:rPr', NS), encoding='unicode'),
        }


def apply(runtime, source, output, name, operations):
    return worker.run_request(runtime, {'mode': 'apply', 'sourcePath': str(source), 'sessionId': name,
        'expectedSourceSha256': worker.digest(source), 'operations': operations}, output / name)


def range_op(op, kind, identifier, content, start, end, **changes):
    return {'op': op, 'targetKind': kind, 'id': identifier, 'startUtf16': start, 'endUtf16': end,
            'expectedTextSha256': text_hash(content), **changes}


def run(runtime, output):
    worker.initialize(runtime)
    output.mkdir(parents=True, exist_ok=False)
    create_sources(runtime, output)
    word, ppt = output / 'rich.docx', output / 'rich.pptx'
    hashes = [worker.digest(word), worker.digest(ppt)]
    initial = worker.run_request(runtime, {'mode': 'inspect', 'sourcePath': str(word)}, output / 'inspect-word')['snapshot']
    (output / 'initial-word.json').write_text(json.dumps(initial, ensure_ascii=False, indent=2), encoding='utf-8')
    paragraph = initial['paragraphs'][0]
    assert 'textDetails' in paragraph, 'Selected text safety/runs are missing from the native snapshot'
    content = paragraph['text']
    assert content.startswith('A😀éB1') and 'TAIL' in content, content
    details = paragraph['textDetails']
    assert details['utf16Length'] == len(content.encode('utf-16-le')) // 2
    assert details['textSha256'] == text_hash(content)
    assert any(item['type'] == 'TextField' and item['startUtf16'] == 6 and item['endUtf16'] == 7 for item in details['protectedRanges']), details
    assert any(item['type'] == 'Frame' for item in details['protectedRanges']), details
    assert details['canReplace'] and details['canStyle'], details
    baseline = apply(runtime, word, output, 'word-no-op', [])
    baseline_evidence = word_evidence(baseline['sourcePath'])
    assert baseline_evidence['drawings'] == 1 and any('PAGE' in item for item in baseline_evidence['fields']), baseline_evidence
    changed = 'Z' + content[1:]
    table = initial['tables'][0]
    assert 'A1' in table['cellTextDetails'], table
    operations = [
        range_op('textReplace', 'paragraph', 'paragraph-0', content, 0, 1, text='Z'),
        range_op('textStyle', 'paragraph', 'paragraph-0', changed, 1, 3,
                 fontSize=27, bold=True, italic=True, underline=True, color=0x008855, fontFamily='Liberation Serif'),
        range_op('textReplace', 'cell', table['id'], table['cells']['A1'], 1, 3, cell='A1', text='emoji'),
    ]
    result = apply(runtime, word, output, 'word-selected', operations)
    assert result['snapshot']['paragraphs'][0]['text'] == changed
    assert result['snapshot']['tables'][0]['cells']['A1'] == 'AemojiéB'
    after_evidence = word_evidence(result['sourcePath'])
    assert after_evidence == baseline_evidence, {'baseline': baseline_evidence, 'changed': after_evidence}
    selected = result['snapshot']['paragraphs'][0]['textDetails']['runs']
    emoji = next(item for item in selected if item['startUtf16'] <= 1 and item['endUtf16'] >= 3)
    for name, expected in {'fontSize': 27, 'bold': True, 'italic': True, 'underline': True, 'color': 0x008855, 'fontFamily': 'Liberation Serif'}.items():
        assert emoji[name] == expected, (name, emoji)
    legacy = apply(runtime, word, output, 'legacy-preserve', [{'op': 'paragraphText', 'id': 'paragraph-0', 'text': changed}])
    assert word_evidence(legacy['sourcePath']) == baseline_evidence, 'Legacy text edit flattened untouched field/bookmark/photo/runs'
    styled_bookmark = apply(runtime, word, output, 'style-bookmark', [
        range_op('textStyle', 'paragraph', 'paragraph-0', content, 7, 11, italic=True)])
    bookmark_evidence = word_evidence(styled_bookmark['sourcePath'])
    assert {key: value for key, value in bookmark_evidence.items() if key != 'tailProperties'} == {
        key: value for key, value in baseline_evidence.items() if key != 'tailProperties'}, bookmark_evidence
    ppt_initial = worker.run_request(runtime, {'mode': 'inspect', 'sourcePath': str(ppt)}, output / 'inspect-ppt')['snapshot']
    shape = ppt_initial['slides'][0]['shapes'][0]
    ppt_result = apply(runtime, ppt, output, 'ppt-selected', [
        range_op('textReplace', 'shape', shape['id'], shape['text'], 1, 3, text='😀😀'),
        range_op('textStyle', 'shape', shape['id'], 'A😀😀éB', 1, 5, italic=True, underline=True, color=0x445566),
    ])
    ppt_shape = ppt_result['snapshot']['slides'][0]['shapes'][0]
    assert ppt_shape['text'] == 'A😀😀éB', ppt_shape
    assert ppt_shape['textDetails']['runs'][0]['color'] == 0xCC2200
    rejects = [
        range_op('textReplace', 'paragraph', 'paragraph-0', content, 2, 3, text='half surrogate'),
        range_op('textReplace', 'paragraph', 'paragraph-0', content, 5, 8, text='field removal'),
        range_op('textReplace', 'paragraph', 'paragraph-0', content, 6, 6, text='field affinity'),
        range_op('textReplace', 'paragraph', 'paragraph-0', content, 7, 8, text='bookmark boundary'),
        range_op('textReplace', 'paragraph', 'paragraph-0', content, 10, 11, text='frame boundary'),
        range_op('textReplace', 'paragraph', 'paragraph-0', content, 0, 1, text='x', expectedTextSha256='0' * 64),
        range_op('textReplace', 'paragraph', 'paragraph-0', content, -1, 0, text='negative'),
        range_op('textStyle', 'paragraph', 'paragraph-0', content, 0, 1, bold='yes'),
        range_op('textStyle', 'paragraph', 'paragraph-0', content, 0, 1, fontFamily=''),
        range_op('textReplace', 'shape', 'paragraph-0', content, 0, 1, text='wrong owner'),
        range_op('textReplace', 'cell', table['id'], table['cells']['A1'], 0, 1, cell='A9', text='wrong cell'),
    ]
    for index, operation in enumerate(rejects):
        directory = output / ('rejected-' + str(index))
        try:
            apply(runtime, word, output, directory.name, [operation])
        except (ValueError, KeyError):
            pass
        else:
            raise AssertionError('Unsafe selected text operation was accepted: ' + str(index))
        assert not (directory / 'edited.docx').exists() and not (directory / 'preview.pdf').exists()
    assert [worker.digest(word), worker.digest(ppt)] == hashes
    assert result['pdfPageCount'] >= 1 and ppt_result['pdfPageCount'] == 1
    report = {'passed': True, 'originalHashesUnchanged': True, 'wordSelected': result,
        'presentationSelected': ppt_result, 'legacyPreservesProtectedContent': True,
        'outsideSelectionEqualsNoOpBaseline': True, 'protectedEvidence': after_evidence,
        'invalidRequestsRejected': len(rejects)}
    (output / 'result.json').write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps({'passed': True, 'invalidRequestsRejected': len(rejects)}))


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
