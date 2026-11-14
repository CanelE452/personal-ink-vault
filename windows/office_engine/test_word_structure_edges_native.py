"""Real Writer edge cases: list levels, insertion inheritance, aliases and owners."""
import argparse
from contextlib import nullcontext
import json
from pathlib import Path
import sys
import traceback
from unittest.mock import patch
import xml.etree.ElementTree as ET
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import office_worker as worker
from test_rich_native import rich_word, word_evidence
from test_word_structure_native import apply, delete, insert, join, ordered_text, rejected_in_server, rewrite_body, split, text_hash

W = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main'
NS = {'w': W}


def canonical(element):
    if element is None:
        return None
    attributes = tuple(sorted((key, value) for key, value in element.attrib.items()
        if not key.startswith('{' + W + '}rsid')))
    return (element.tag, attributes, element.text or '', tuple(canonical(child) for child in element))


def paragraph_xml(path, ordinal):
    with zipfile.ZipFile(path) as archive:
        root = ET.fromstring(archive.read('word/document.xml'))
        value = root.find('w:body', NS).findall('w:p', NS)[ordinal]
        properties = value.find('w:pPr', NS)
        numbering = value.find('w:pPr/w:numPr/w:numId', NS)
        if numbering is not None:
            definitions = ET.fromstring(archive.read('word/numbering.xml'))
            number = next(item for item in definitions.findall('w:num', NS)
                if item.get('{' + W + '}numId') == numbering.get('{' + W + '}val'))
            abstract_id = number.find('w:abstractNumId', NS).get('{' + W + '}val')
            abstract = next(item for item in definitions.findall('w:abstractNum', NS)
                if item.get('{' + W + '}abstractNumId') == abstract_id)
            # Package-local numbering IDs are references, not a numbering rule's identity.
            abstract.attrib.pop('{' + W + '}abstractNumId', None)
            number.attrib.pop('{' + W + '}numId', None)
            number.remove(number.find('w:abstractNumId', NS))
            numbering.attrib.clear()
            numbering.text = json.dumps((canonical(abstract), canonical(number)))
        return {'pPr': canonical(properties), 'runs': [canonical(run) for run in value.findall('w:r', NS)]}


def assign_list(document, paragraph, kind, level):
    rules = document.createInstance('com.sun.star.text.NumberingRules')
    entries = {entry.Name: entry for entry in rules.getByIndex(level)}
    entries['NumberingType'] = worker.prop('NumberingType', worker.uno.getConstantByName(
        'com.sun.star.style.NumberingType.' + ('CHAR_SPECIAL' if kind == 'bullet' else 'ARABIC')))
    entries['BulletChar'] = worker.prop('BulletChar', '•')
    rules.replaceByIndex(level, worker.uno.Any('[]com.sun.star.beans.PropertyValue', tuple(entries.values())))
    paragraph.NumberingRules = rules
    paragraph.NumberingLevel = level
    paragraph.NumberingIsNumber = True


def new_document(server, specifications):
    document = server.desktop.loadComponentFromURL('private:factory/swriter', '_blank', 0,
        (worker.prop('Hidden', True), worker.prop('MacroExecutionMode', 0)))
    for index, (content, color, size, bold) in enumerate(specifications):
        cursor = document.Text.createTextCursor()
        cursor.gotoEnd(False)
        if index:
            document.Text.insertControlCharacter(cursor, 0, False)
        document.Text.insertString(cursor, content, False)
    paragraphs = list(worker.objects(document)[1].values())
    for paragraph, (_, color, size, bold) in zip(paragraphs, specifications):
        cursor = worker.text_cursor(paragraph, True)
        cursor.CharColor = color
        cursor.CharHeight = float(size)
        cursor.CharWeight = 150.0 if bold else 100.0
        cursor.CharFontName = 'Liberation Serif'
    return document


def save_document(document, path):
    document.storeToURL(path.as_uri(), (worker.prop('FilterName', worker.FILTERS['docx']),))


def create_fixtures(runtime, output):
    specifications = [('SENTINEL', 0x336633, 14, False), ('REFERENCE', 0xCC2200, 17, True),
        ('AFTER', 0x0033CC, 14, False), ('END', 0x334455, 14, False)]
    with worker.OfficeServer(runtime, output) as server:
        document = new_document(server, specifications)
        try:
            reference = worker.objects(document)[1]['paragraph-1']
            heading = next(name for name in document.StyleFamilies.getByName('ParagraphStyles').ElementNames
                if name.replace(' ', '') == 'Heading1')
            reference.ParaStyleName = heading
            reference.ParaAdjust = 3
            assign_list(document, reference, 'number', 2)
            reference.BreakType = worker.uno.Enum('com.sun.star.style.BreakType', 'PAGE_BEFORE')
            save_document(document, output / 'format-plain.docx')
        finally:
            document.close(True)
        document = new_document(server, [('LIST', 0x336633, 14, False), ('END', 0x334455, 14, False)])
        try:
            assign_list(document, worker.objects(document)[1]['paragraph-0'], 'bullet', 1)
            save_document(document, output / 'list.docx')
        finally:
            document.close(True)
        document = new_document(server, [('DUP😀DUP', 0xCC2200, 12, False),
            ('DUP😀DUP', 0x0033CC, 24, True), ('', 0x118811, 18, False),
            ('', 0x884499, 19, True), ('END', 0x334455, 14, False)])
        try:
            save_document(document, output / 'duplicates.docx')
        finally:
            document.close(True)
        for mode in ('section', 'AT_PARAGRAPH', 'AT_CHARACTER'):
            document = new_document(server, [('BEFORE', 0x336633, 14, False),
                ('OWNER', 0xCC2200, 17, True), ('AFTER', 0x0033CC, 14, False)])
            try:
                paragraph = worker.objects(document)[1]['paragraph-1']
                if mode == 'section':
                    section = document.createInstance('com.sun.star.text.TextSection')
                    section.Name = 'ProtectedEdge'
                    document.Text.insertTextContent(worker.text_cursor(paragraph, True), section, True)
                    section.IsProtected = True
                else:
                    frame = document.createInstance('com.sun.star.text.TextFrame')
                    frame.Name = 'FloatingEdge'
                    frame.AnchorType = worker.uno.Enum('com.sun.star.text.TextContentAnchorType', mode)
                    frame.Width, frame.Height = 1800, 900
                    cursor = document.Text.createTextCursorByRange(paragraph.Start)
                    if mode == 'AT_CHARACTER':
                        assert cursor.goRight(2, False)
                    document.Text.insertTextContent(cursor, frame, False)
                    frame.Text.String = 'FLOAT'
                save_document(document, output / ('owner-' + mode + '.docx'))
            finally:
                document.close(True)
    rich_word(output / 'format-plain.docx', output / 'format-rich.docx')

    def reference_page_break(body):
        reference = body.findall('w:p', NS)[1]
        assert ''.join(item.text or '' for item in reference.findall('.//w:t', NS)) == 'REFERENCE'
        properties = reference.find('w:pPr', NS)
        assert properties is not None
        page_break = properties.find('w:pageBreakBefore', NS)
        if page_break is None:
            page_break = ET.SubElement(properties, '{' + W + '}pageBreakBefore')
        page_break.set('{' + W + '}val', 'true')

    rewrite_body(output / 'format-rich.docx', output / 'format.docx', reference_page_break)


def inspect(runtime, source, output, name):
    return worker.run_request(runtime, {'mode': 'inspect', 'sourcePath': str(source)}, output / name)['snapshot']


def saved(result, needle):
    assert worker.digest(Path(result['sourcePath'])) == result['sourceSha256']
    assert worker.digest(Path(result['pdfPath'])) == result['pdfSha256']
    with zipfile.ZipFile(result['sourcePath']) as archive:
        assert archive.testzip() is None
    pages = worker.PdfReader(result['pdfPath']).pages
    assert len(pages) == result['pdfPageCount'] and len(pages) > 0
    assert needle in ''.join(''.join(page.extract_text().split()) for page in pages)


def run(runtime, output):
    worker.initialize(runtime)
    output.mkdir(parents=True, exist_ok=False)
    create_fixtures(runtime, output)
    original_hashes = {path.name: worker.digest(path) for path in output.glob('*.docx')}
    report = {'cases': [], 'errors': [], 'execution': {
        'mode': 'edge-semantics-with-one-private-owned-server',
        'fixtureCreation': 'separate-real-OfficeServer',
        'requestLifecycle': 'real-worker-run_request-with-separate-working-directories-and-documents',
        'borrowedContext': 'contextlib.nullcontext-only-inside-scoped-OfficeServer-patch',
        'productionStartupTeardownAcceptance': 'separate-main-native-test-not-this-edge-loop',
    }}

    def record(name, value):
        report['cases'].append({'name': name, 'value': value})
        (output / 'result.json').write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')

    def check(condition, message, value=None):
        if not condition:
            report['errors'].append({'message': message, 'value': value})

    def variant(name, operation):
        previous_errors = len(report['errors'])
        try:
            operation()
        except Exception:
            report['errors'].append({'message': name, 'traceback': traceback.format_exc()})
        record(name + '-completed', len(report['errors']) == previous_errors)

    def list_levels():
        source = output / 'list.docx'
        initial = inspect(runtime, source, output, 'list-inspect')
        check(initial['paragraphs'][0]['paragraphFormat']['listKind'] == 'bullet', 'fixture is not a bullet list', initial)
        check(initial['paragraphs'][0]['paragraphFormat']['listLevel'] == 1, 'fixture does not begin at level1', initial)
        for index, (changes, expected_kind, expected_level) in enumerate([
            ({'listLevel': 2}, 'bullet', 2),
            ({'listKind': 'number'}, 'number', 2),
            ({'listKind': 'none'}, 'none', None),
        ]):
            source_hash = worker.digest(source)
            baseline = apply(runtime, source, output, 'list-no-op-' + str(index), [])
            result = apply(runtime, source, output, 'list-feature-' + str(index), [{
                'op': 'paragraphFormat', 'id': 'paragraph-0', 'expectedTextSha256': text_hash('LIST'), **changes}])
            saved(baseline, 'LIST')
            saved(result, 'LIST')
            current = result['snapshot']['paragraphs'][0]
            record('list-stage-' + str(index), {'requested': changes, 'format': current['paragraphFormat'], 'result': result})
            check(current['paragraphFormat']['listKind'] == expected_kind,
                'listKind changed when only level was requested, or explicit kind was not applied', current)
            check(current['paragraphFormat']['listLevel'] == expected_level,
                'listLevel was changed without a request or explicit off did not clear it', current)
            check(paragraph_xml(result['sourcePath'], 1) == paragraph_xml(baseline['sourcePath'], 1),
                'list edit changed untouched END pPr/runs')
            check(worker.digest(source) == source_hash, 'list edit mutated its captured input')
            source = Path(result['sourcePath'])

    def insertion(position):
        source = output / 'format.docx'
        baseline = apply(runtime, source, output, 'insert-' + position + '-no-op', [])
        original = baseline['snapshot']['paragraphs'][1]
        check(original['paragraphFormat']['alignment'] == 'center' and
            original['paragraphFormat']['listKind'] == 'number' and
            original['paragraphFormat']['listLevel'] == 2 and
            original['paragraphFormat']['pageBreakBefore'] is True,
            'reference fixture lost its explicit formatting', original)
        result = apply(runtime, source, output, 'insert-' + position + '-feature', [
            insert('inserted-' + position, 'paragraph-1', 'REFERENCE', position, 'INSERTED')])
        saved(baseline, 'REFERENCE')
        saved(result, 'REFERENCE')
        baseline_pages = worker.PdfReader(baseline['pdfPath']).pages
        feature_pages = worker.PdfReader(result['pdfPath']).pages
        baseline_locations = [index + 1 for index, page in enumerate(baseline_pages)
            if 'REFERENCE' in ''.join(page.extract_text().split())]
        feature_locations = [index + 1 for index, page in enumerate(feature_pages)
            if 'REFERENCE' in ''.join(page.extract_text().split())]
        inserted_locations = [index + 1 for index, page in enumerate(feature_pages)
            if 'INSERTED' in ''.join(page.extract_text().split())]
        record('insert-' + position + '-pdf-pagination', {
            'baselinePages': len(baseline_pages), 'featurePages': len(feature_pages),
            'baselineReferencePages': baseline_locations, 'featureReferencePages': feature_locations,
            'insertedPages': inserted_locations})
        check(len(baseline_pages) == len(feature_pages),
            'insertion lost or duplicated a page break in the small fixture')
        check(len(baseline_locations) == 1 and feature_locations == baseline_locations,
            'insertion moved REFERENCE to a different actual PDF page')
        check(len(inserted_locations) == 1, 'the inserted paragraph was not unique in the actual PDF')
        if len(feature_locations) == 1 and len(inserted_locations) == 1:
            check(inserted_locations[0] < feature_locations[0] if position == 'before'
                else inserted_locations[0] == feature_locations[0],
                'new paragraph BreakNONE did not keep the intended side of the reference page break')
        ordinal = 2 if position == 'before' else 1
        current = result['snapshot']['paragraphs'][ordinal]
        record('insert-' + position, {'reference': current, 'result': result})
        check(current['text'] == 'REFERENCE', 'insertion remapped the original reference to another paragraph', current)
        check(current['paragraphFormat'] == original['paragraphFormat'], 'insertion changed the reference paragraphFormat', current)
        check(current['textDetails']['runs'] == original['textDetails']['runs'], 'insertion changed reference character runs')
        check(paragraph_xml(result['sourcePath'], ordinal) == paragraph_xml(baseline['sourcePath'], 1),
            'insertion changed original reference pPr/runs XML beyond no-op normalization')
        check(word_evidence(result['sourcePath']) == word_evidence(baseline['sourcePath']),
            'insertion changed untouched field/bookmark/inline image')

    def duplicate_aliases():
        source = output / 'duplicates.docx'
        baseline = apply(runtime, source, output, 'duplicate-no-op', [])
        operations = [split('paragraph-0', 'new-right', 'DUP😀DUP', 5),
            {'op': 'textReplace', 'targetKind': 'paragraph', 'id': 'new-right',
             'startUtf16': 0, 'endUtf16': 3, 'text': 'CHANGED', 'expectedTextSha256': text_hash('DUP')},
            join('paragraph-0', 'new-right', 'DUP😀', 'CHANGED'), delete('paragraph-2', ''),
            {'op': 'textReplace', 'targetKind': 'paragraph', 'id': 'paragraph-3',
             'startUtf16': 0, 'endUtf16': 0, 'text': 'PURPLE', 'expectedTextSha256': text_hash('')}]
        result = apply(runtime, source, output, 'duplicate-feature', operations)
        saved(baseline, 'END')
        saved(result, 'CHANGED')
        record('duplicate-aliases', result)
        check(ordered_text(result['snapshot']) == ['DUP😀CHANGED', 'DUP😀DUP', 'PURPLE', 'END'],
            'logical ordinal changed across duplicate text or empty paragraphs', result['snapshot'])
        check(paragraph_xml(result['sourcePath'], 1) == paragraph_xml(baseline['sourcePath'], 1),
            'the untouched second duplicate lost its distinct blue character style')
        check(paragraph_xml(result['sourcePath'], 3) == paragraph_xml(baseline['sourcePath'], 4),
            'the untouched END paragraph changed after ordinal remapping')
        runs = result['snapshot']['paragraphs'][2]['textDetails']['runs']
        original_runs = baseline['snapshot']['paragraphs'][3]['textDetails']['runs']
        check(bool(runs) and bool(original_runs) and all(run['color'] == original_runs[0]['color'] == 0x884499 for run in runs),
            'an empty paragraph was recovered by duplicate text instead of its purple logical ordinal', runs)

    def unsafe_owner(mode):
        source = output / ('owner-' + mode + '.docx')
        baseline = apply(runtime, source, output, 'owner-' + mode + '-no-op', [])
        saved(baseline, 'OWNER')
        with worker.OfficeServer(runtime, output) as server:
            document = server.load(source)
            try:
                if mode == 'section':
                    sections = document.TextSections
                    states = [(name, sections.getByName(name).IsProtected) for name in sections.ElementNames]
                    record('owner-section-fixture', states)
                    assert any(protected is True for _, protected in states), 'Protected TextSection fixture did not survive DOCX reopen'
                else:
                    values = document.DrawPage
                    states = [getattr(worker.office_word.optional(values.getByIndex(index), 'AnchorType'), 'value', None)
                        for index in range(values.Count)]
                    record('owner-' + mode + '-fixture', states)
                    assert any(state in ('AT_PARAGRAPH', 'AT_CHARACTER') for state in states), \
                        'A paragraph/character floating anchor did not survive DOCX reopen'
                paragraphs = worker.objects(document)[1]
                assert paragraphs['paragraph-1'].String == 'OWNER'
                capabilities = worker.snapshot(document, worker.digest(source), server.context)['paragraphs'][1]['structure']
                record('owner-' + mode + '-capabilities', capabilities)
                check(not any(capabilities.values()), 'Unsafe owner advertised structural edits', capabilities)
            finally:
                document.close(True)
            invalid = [split('paragraph-1', 'forbidden', 'OWNER', 2),
                insert('forbidden-before', 'paragraph-1', 'OWNER', 'before', 'NEW'),
                insert('forbidden-after', 'paragraph-1', 'OWNER', 'after', 'NEW'),
                join('paragraph-1', 'paragraph-2', 'OWNER', 'AFTER'), delete('paragraph-1', 'OWNER')]
            for index, operation in enumerate(invalid):
                directory = output / ('owner-' + mode + '-rejected-' + str(index))
                rejected_in_server(server, source, [operation], directory)
                check(not (directory / 'edited.docx').exists() and not (directory / 'preview.pdf').exists(),
                    'Unsafe owner published an edited file')
        unchanged = apply(runtime, source, output, 'owner-' + mode + '-after-rejection', [])
        saved(unchanged, 'OWNER')
        check([paragraph_xml(unchanged['sourcePath'], index) for index in range(3)] ==
            [paragraph_xml(baseline['sourcePath'], index) for index in range(3)],
            'owner rejection changed body pPr/runs compared to its independent no-op baseline')

    shared_directory = output / 'shared-office-server'
    shared_directory.mkdir()
    actual_server_factory = worker.OfficeServer
    record('execution-mode', report['execution'])
    with actual_server_factory(runtime, shared_directory) as shared_server:
        def borrow_server(requested_runtime, _directory):
            assert requested_runtime == runtime, 'An EDGE request changed the native runtime'
            return nullcontext(shared_server)

        with patch.object(worker, 'OfficeServer', borrow_server):
            variant('list-level-chain', list_levels)
            for position in ('before', 'after'):
                variant('insert-' + position, lambda position=position: insertion(position))
            variant('duplicate-logical-ordinals', duplicate_aliases)
            for mode in ('section', 'AT_PARAGRAPH', 'AT_CHARACTER'):
                variant('unsafe-' + mode, lambda mode=mode: unsafe_owner(mode))
    report['execution']['patchRestored'] = worker.OfficeServer is actual_server_factory
    report['execution']['ownedProfileRemoved'] = not shared_server.profile.exists()
    check(all(worker.digest(output / name) == digest for name, digest in original_hashes.items()),
        'an original synthetic fixture was mutated')
    report['passed'] = not report['errors']
    (output / 'result.json').write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
    assert report['passed'], json.dumps(report['errors'], ensure_ascii=False)
    print(json.dumps({'passed': True, 'cases': len(report['cases'])}))


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
