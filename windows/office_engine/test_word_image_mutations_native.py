"""Root-run synthetic DOCX photo mutations through the unchanged worker path.

Each published worker result is opened by a separate owned native server. Public
IDs come from inspection; paragraph labels are fixture assertions, not product
identity. Equal payloads remain separate Frame locations in the multiple case.
"""
import argparse
from contextlib import contextmanager
import copy
import json
from pathlib import Path
import sys
import time
import traceback

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
import office_worker as worker
from office_word_fidelity import saved_reopen_state
from test_images_native import graphic, stage
from test_rich_native import fixture_png, rich_word

ASSET_ID = '11111111-1111-4111-8111-111111111111'
LABELS = [name + ': before A😀éB | after ' + name for name in
    ('SOURCE_FIRST', 'GAP_FIRST', 'SOURCE_MIDDLE', 'GAP_MIDDLE', 'SOURCE_LAST', 'GAP_LAST')]


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def dump(path, value):
    def portable(item):
        if isinstance(item, dict):
            if all(isinstance(key, str) for key in item):
                return {key: portable(value) for key, value in item.items()}
            return {'semanticMapEntries': [[portable(key), portable(value)]
                for key, value in item.items()]}
        if isinstance(item, (tuple, list)):
            return [portable(value) for value in item]
        return item
    path.write_text(json.dumps(portable(value), ensure_ascii=False, indent=2), encoding='utf-8')


@contextmanager
def native_server(runtime, directory, report):
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
        process = getattr(owner, 'process', None)
        event['ownedLoaderHandleClosed'] = process is not None and process.process is None
        event['ownedJobHandleClosed'] = process is not None and process.job is None
        profile = getattr(owner, 'profile', None)
        event['profile'] = None if profile is None else str(profile)
        event['ownedProfileRemoved'] = profile is not None and not profile.exists()


def canonical_fixture(runtime, output, png, count, report, protected=False):
    raw = output / 'raw.docx'
    with native_server(runtime, output / 'fixture-native', report) as server:
        document = server.desktop.loadComponentFromURL('private:factory/swriter', '_blank', 0,
            (worker.prop('Hidden', True), worker.prop('MacroExecutionMode', 0)))
        try:
            requested_graphic = graphic(server, png)
            report['requestedAssetNativeGraphicSha256'] = worker.office_presentation.graphic_digest(
                server.context, requested_graphic, worker.uno, worker.prop)
            for value in [*LABELS, 'DUPLICATE BODY', 'DUPLICATE BODY', 'TAIL KEEP']:
                cursor = document.Text.createTextCursor()
                cursor.gotoEnd(False)
                if document.Text.String:
                    document.Text.insertControlCharacter(cursor, worker.uno.getConstantByName(
                        'com.sun.star.text.ControlCharacter.PARAGRAPH_BREAK'), False)
                    cursor.gotoEnd(False)
                document.Text.insertString(cursor, value, False)
            cursor = document.Text.createTextCursor()
            cursor.gotoEnd(True)
            cursor.CharHeight = 10.0
            _, paragraphs, _ = worker.objects(document)
            for index in range(count):
                paragraph = list(paragraphs.values())[index * 2]
                offset = worker.office_text.utf16_length(paragraph.String.split('|')[0])
                point, _, _, _ = worker.office_text.selection(paragraph,
                    {'startUtf16': offset, 'endUtf16': offset,
                     'expectedTextSha256': worker.office_text.text_hash(paragraph.String)},
                    paragraph=True, scalar_cursor=True, replacing=True)
                descriptor = document.createInstance('com.sun.star.text.TextGraphicObject')
                descriptor.Graphic = requested_graphic
                descriptor.AnchorType = worker.uno.Enum('com.sun.star.text.TextContentAnchorType', 'AS_CHARACTER')
                descriptor.Width, descriptor.Height = 2540, 1905
                descriptor.LeftMargin = descriptor.RightMargin = 0
                descriptor.TopMargin = descriptor.BottomMargin = 0
                before_refs = [document.GraphicObjects.getByName(name)
                    for name in document.GraphicObjects.ElementNames]
                document.Text.insertTextContent(point, descriptor, False)
                attached = [document.GraphicObjects.getByName(name)
                    for name in document.GraphicObjects.ElementNames]
                added = [image for image in attached if not any(image == old for old in before_refs)]
                require(len(attached) == len(before_refs) + 1 and len(added) == 1 and
                    all(sum(image == old for image in attached) == 1 for old in before_refs),
                    'Fixture creation must bind exactly one new actual native photo')
                actual = added[0]
                actual.setName('Authored source photo ' + str(index))
                actual.setPropertyValue('Title', 'Authored title ' + str(index))
                actual.setPropertyValue('Description', 'Authored description 😀 ' + str(index))
                actual.setPropertyValue('HyperLinkURL', 'https://example.invalid/source-' + str(index))
            table = document.createInstance('com.sun.star.text.TextTable')
            table.initialize(1, 1)
            document.Text.insertTextContent(document.Text.End, table, False)
            table.getCellByName('A1').String = 'TABLE KEEP 😀é'
            document.storeToURL(raw.as_uri(), (worker.prop('FilterName', worker.FILTERS['docx']),))
        finally:
            document.close(True)
    candidate = raw
    if protected:
        candidate = output / 'protected-raw.docx'
        rich_word(raw, candidate)
    source = output / 'canonical.docx'
    with native_server(runtime, output / 'canonical-native', report) as server:
        document = server.load(candidate)
        try:
            document.storeToURL(source.as_uri(), (worker.prop('FilterName', worker.FILTERS['docx']),))
        finally:
            document.close(True)
    return source


def inspect(runtime, source, output, label):
    result = worker.run_request(runtime, {'mode': 'inspect', 'sourcePath': str(source)}, output / label)
    dump(output / (label + '.json'), result)
    return result['snapshot']


def paragraph(snapshot, label):
    matches = [row for row in snapshot['paragraphs'] if row['text'].replace('\ufffc', '') == label]
    require(len(matches) == 1, 'The fixture paragraph must have one exact authored label')
    return matches[0]


def target(snapshot, label, kind='wordImageAdd', identifier='added-a', offset=None):
    row = paragraph(snapshot, label)
    if offset is None:
        offset = worker.office_text.utf16_length(row['text'].split('|')[0])
    value = {'op': kind, 'id': identifier, 'ownerId': 'body', 'paragraphId': row['id'],
        'offsetUtf16': offset, 'expectedTextSha256': worker.office_text.text_hash(row['text'])}
    if kind == 'wordImageAdd':
        value.update(assetId=ASSET_ID, width=25.4, height=19.05)
    capability = 'canAdd' if kind == 'wordImageAdd' else 'canMoveHere'
    targets = snapshot.get('wordImageTargets')
    require(isinstance(targets, list), 'Public inspection must expose known Word image targets')
    matches = [target for target in targets
        if target.get('ownerId') == value['ownerId'] and target.get('paragraphId') == value['paragraphId']]
    require(len(matches) == 1 and matches[0].get(capability) is True,
        'The exact public body paragraph must explicitly enable ' + capability)
    return value


def require_photo_capabilities(rows):
    require(bool(rows) and all(row.get('canMove') is True and row.get('canDelete') is True
        for row in rows), 'Every selected public source photo must explicitly enable move and delete')


def requested_position(snapshot, operation):
    require(operation['ownerId'] == 'body', 'The request must name the real body owner')
    identifiers = [row['id'] for row in snapshot['paragraphs']]
    require(operation['paragraphId'] in identifiers and type(operation['offsetUtf16']) is int,
        'The request must name an inspected paragraph and exact UTF-16 offset')
    return identifiers.index(operation['paragraphId']), operation['offsetUtf16']


def inspected_position(snapshot, identifier):
    rows = [row for row in snapshot['wordImages'] if row['id'] == identifier]
    require(len(rows) == 1, 'The logical source identity must bind to exactly one inspected photo')
    return requested_position(snapshot, rows[0])


def exact_photo(state, position):
    rows = [row for row in state['photos']
        if (row['paragraph'], row['offsetUtf16']) == position]
    require(len(rows) == 1, 'The exact requested native Frame position must contain one photo')
    return rows[0]


def predicted_saved_order(photos):
    result = copy.deepcopy(photos)
    result.sort(key=lambda row: (row['paragraph'], row['offsetUtf16']))
    require(len({(row['paragraph'], row['offsetUtf16']) for row in result}) == len(result),
        'The fixture must not silently order ambiguous same-point Frames')
    for index, row in enumerate(result):
        row['raw']['ZOrder']['value'] = ('integer', index)
    return result


def expected_move(before, snapshot, operation):
    expected = copy.deepcopy(before)
    source = exact_photo(expected, inspected_position(snapshot, operation['id']))
    source['paragraph'], source['offsetUtf16'] = requested_position(snapshot, operation)
    expected['photos'] = predicted_saved_order(expected['photos'])
    return expected


def verify_added(before, after, snapshot, operation, native_graphic_sha):
    require(after['authored'] == before['authored'], 'Add changed unrelated authored content or runs')
    require(len(after['photos']) == len(before['photos']) + 1,
        'Add did not create exactly one native Frame')
    destination = requested_position(snapshot, operation)
    added = exact_photo(after, destination)
    require((added['width'], added['height'], added['nativeGraphicSha256']) ==
        (operation['width'], operation['height'], native_graphic_sha),
        'The added native photo differs from the requested PNG, exact offset or dimensions')
    require(added['raw']['AnchorType']['value'][-1] == 'AS_CHARACTER' and
        added['raw']['Width']['value'] == ('integer', round(operation['width'] * 100)) and
        added['raw']['Height']['value'] == ('integer', round(operation['height'] * 100)) and
        all(added['raw'][name]['value'] == ('integer', 0)
            for name in ('LeftMargin', 'RightMargin', 'TopMargin', 'BottomMargin')),
        'The added raw native anchor, dimensions or margins differ from the request')
    positions = sorted([(row['paragraph'], row['offsetUtf16']) for row in before['photos']] + [destination])
    require(len(set(positions)) == len(positions), 'Add must target a distinct native Frame point')
    require(added['raw']['ZOrder']['value'] == ('integer', positions.index(destination)),
        'The added saved ZOrder differs from the request-derived Frame permutation')
    for original in before['photos']:
        position = original['paragraph'], original['offsetUtf16']
        expected = copy.deepcopy(original)
        expected['raw']['ZOrder']['value'] = ('integer', positions.index(position))
        require(exact_photo(after, position) == expected,
            'Add changed a source photo raw state, payload, dimensions or exact Frame')


def authored_state(state):
    value = copy.deepcopy(saved_reopen_state(state))
    def blocks(items):
        for kind, payload in items:
            if kind == 'table':
                for _, cell in payload:
                    blocks(cell)
                continue
            portions = []
            for token in payload['portions']:
                if token[0] == 'object':
                    continue
                if token[0] == 'text' and portions and portions[-1][0] == 'text' and portions[-1][2] == token[2]:
                    portions[-1][1] += token[1]
                else:
                    portions.append(token)
            payload['portions'] = portions
    blocks(value['body'])
    for items in value['ownersByReferences'].values():
        blocks(items)
    return value


def independent(runtime, source, output, name, report):
    from office_word_image_mutations import raw_image_state
    before_hash = worker.digest(source)
    with native_server(runtime, output / name, report) as server:
        document = server.load(source)
        try:
            kind, paragraphs, tables = worker.objects(document)
            require(kind == 'word', 'The reopened result must be Writer')
            word = worker.office_word_layout.WordDocument(document, paragraphs, tables,
                worker.uno, worker.prop, context=server.context)
            catalog = word.image_catalog()
            rows = catalog.snapshot([0])
            require(rows is not None and len(rows) == document.GraphicObjects.Count,
                'Every reopened native photo must have an explicit actual Frame binding')
            photos = []
            for row in rows:
                require(row['paragraphId'] in paragraphs and type(row['offsetUtf16']) is int,
                    'The reopened photo must have an exact body paragraph and native prefix')
                image = catalog.images[row['id']]
                photos.append({'paragraph': list(paragraphs).index(row['paragraphId']),
                    'offsetUtf16': row['offsetUtf16'], 'width': row['width'], 'height': row['height'],
                    'nativeGraphicSha256': row['nativeGraphicSha256'], 'raw': raw_image_state(image)})
            photos.sort(key=lambda row: (row['paragraph'], row['offsetUtf16']))
            result = {'authored': authored_state(word.verification_state()), 'photos': photos}
            dump(output / (name + '-photos.json'), photos)
        finally:
            document.close(True)
    require(worker.digest(source) == before_hash, 'Independent native reopen changed the immutable file')
    return result


def apply(runtime, source, output, name, operations, assets, asset_root, report):
    before = worker.digest(source)
    result = worker.run_request(runtime, {'mode': 'apply', 'sourcePath': str(source),
        'sessionId': name, 'expectedSourceSha256': before, 'operations': operations,
        'imageAssets': assets}, output / name, asset_root=asset_root)
    require(worker.digest(source) == before, 'A product mutation changed its source file')
    dump(output / (name + '-result.json'), result)
    edited = Path(result['sourcePath'])
    require(edited.is_file() and worker.digest(edited) == result['sourceSha256'], 'Saved source hash mismatch')
    pdf = Path(result['pdfPath'])
    require(pdf.is_file() and worker.digest(pdf) == result['pdfSha256'] and
        result['pdfPageCount'] > 0 and
        len(worker.PdfReader(str(pdf), strict=True).pages) == result['pdfPageCount'],
        'The saved edition needs the exact hashed PDF and independently read page count')
    report['workerResults'].append({'name': name, 'sourceSha256': result['sourceSha256'],
        'pdfSha256': result['pdfSha256'], 'pageCount': result['pdfPageCount']})
    return edited


def run(runtime, output, case):
    output.mkdir(parents=True, exist_ok=False)
    started = time.monotonic()
    report = {'completed': False, 'case': case, 'independentServers': [], 'workerResults': [], 'checks': {},
        'nativeFaultInjectionCovered': False}
    product = sorted(Path(__file__).resolve().parent.glob('office_*.py'))
    product.append(Path(worker.__file__).with_name('process_ownership.py'))
    product.extend([Path(__file__).resolve(), Path(worker.__file__).with_name('test_images_native.py'),
        Path(worker.__file__).with_name('test_rich_native.py')])
    product.extend(runtime / 'program' / name for name in
        ('soffice.com', 'soffice.bin', 'python.exe', 'pyuno.pyd', 'mergedlo.dll', 'swlo.dll', 'mswordlo.dll', 'version.ini'))
    product = [path for path in product if path.is_file()]
    report['sourceHashesBefore'] = {str(path): worker.digest(path) for path in product}
    try:
        worker.initialize(runtime)
        png = output / 'photo.png'
        png.write_bytes(fixture_png())
        source = canonical_fixture(runtime, output, png, 3 if case == 'multiple' else 0, report,
            protected=case == 'protected')
        source_hash = worker.digest(source)
        asset_root = output / 'request-assets'
        assets = [stage(asset_root, ASSET_ID, png, 'image/png', 2, 2)]
        initial = inspect(runtime, source, output, 'inspect-initial')
        baseline = independent(runtime, source, output, 'before-independent', report)
        if case == 'basic':
            require(initial['wordImages'] == [] and baseline['photos'] == [] and
                initial.get('wordImageTargets') is not None,
                'The basic source must have a verified empty image catalog and known add targets')
            report['checks']['verifiedEmptySource'] = True
        if case == 'multiple':
            require(len(baseline['photos']) == 3, 'The source must contain three separate actual native Frames')
            require(len({row['nativeGraphicSha256'] for row in baseline['photos']}) == 1,
                'The source must exercise identical payloads in distinct Frames')
            require(all(row['nativeGraphicSha256'] == report['requestedAssetNativeGraphicSha256']
                for row in baseline['photos']), 'The source photos must retain the requested native PNG payload')
            require_photo_capabilities(initial['wordImages'])
            for index, photo in enumerate(baseline['photos']):
                for name, authored in [('Title', 'Authored title ' + str(index)),
                        ('Description', 'Authored description 😀 ' + str(index)),
                        ('HyperLinkURL', 'https://example.invalid/source-' + str(index))]:
                    require(photo['raw'][name]['value'] == ('string', authored),
                        'The canonical fixture lost its nonempty authored ' + name)
            report['checks']['distinctFramesSamePayloadAndNonemptyMetadata'] = True
        if case in ('basic', 'multiple'):
            add_request = target(initial, LABELS[1])
            add_destination = requested_position(initial, add_request)
            dump(output / 'add-intent.json', {'operation': add_request,
                'destination': add_destination, 'nativeGraphicSha256': report['requestedAssetNativeGraphicSha256'],
                'sourcePhotosBefore': baseline['photos']})
            added = apply(runtime, source, output, 'add', [add_request], assets, asset_root, report)
            after_add = independent(runtime, added, output, 'after-add-independent', report)
            verify_added(baseline, after_add, initial, add_request, report['requestedAssetNativeGraphicSha256'])
            saved = inspect(runtime, added, output, 'inspect-added')
            selected = [row for row in saved['wordImages']
                if requested_position(saved, row) == add_destination]
            require(len(selected) == 1, 'The added photo must bind to its exact requested native Frame')
            require_photo_capabilities(selected)
            added_id = selected[0]['id']
            move_request = target(saved, LABELS[5], 'wordImageMove', added_id)
            move_expected = expected_move(after_add, saved, move_request)
            dump(output / 'move-expected-before.json', {'operation': move_request, 'expected': move_expected})
            moved = apply(runtime, added, output, 'move',
                [move_request], [], asset_root, report)
            after_move = independent(runtime, moved, output, 'after-move-independent', report)
            require(after_move == move_expected,
                'Move differs from its exact requested Frame, preserved raw state, payload or dimensions')
            moved_snapshot = inspect(runtime, moved, output, 'inspect-moved')
            destination = requested_position(saved, move_request)
            selected = [row for row in moved_snapshot['wordImages']
                if requested_position(moved_snapshot, row) == destination]
            require(len(selected) == 1, 'The moved photo must bind to the requested native Frame')
            require_photo_capabilities(selected)
            deleted = apply(runtime, moved, output, 'delete',
                [{'op': 'wordImageDelete', 'id': selected[0]['id']}], [], asset_root, report)
            final = independent(runtime, deleted, output, 'after-delete-independent', report)
            require(final == baseline, 'Deleting only the added photo must restore all authored content and source photo raw state')
            report['checks'].update(add=True, move=True, delete=True, exactFinalBaseline=True)
            if case == 'basic':
                require(final['photos'] == [], 'Deleting the last photo must preserve a verified empty native catalog')
                report['checks']['lastPhotoDeleteToVerifiedEmpty'] = True
                same_source, same_snapshot, same_state = added, saved, after_add
                current_position = add_destination
                for offset in (1, 8):
                    selected = [row for row in same_snapshot['wordImages']
                        if requested_position(same_snapshot, row) == current_position]
                    require(len(selected) == 1, 'The same-paragraph source Frame must remain exact')
                    require_photo_capabilities(selected)
                    same_request = target(same_snapshot, LABELS[1], 'wordImageMove', selected[0]['id'], offset=offset)
                    expected = expected_move(same_state, same_snapshot, same_request)
                    name = 'same-paragraph-move-' + str(offset)
                    dump(output / (name + '-expected-before.json'), {'operation': same_request, 'expected': expected})
                    same_source = apply(runtime, same_source, output, name, [same_request], [], asset_root, report)
                    actual = independent(runtime, same_source, output, name + '-independent', report)
                    require(actual == expected,
                        'Same-paragraph move did not preserve every raw property at its exact requested UTF-16 point')
                    report['checks']['sameParagraphMoveOffset' + str(offset)] = True
                    same_state = expected
                    current_position = requested_position(same_snapshot, same_request)
                    same_snapshot = inspect(runtime, same_source, output, name + '-inspect')
                operations = [target(initial, LABELS[1], identifier='batch-photo'),
                    target(initial, LABELS[1], 'wordImageMove', 'batch-photo', offset=1),
                    target(initial, LABELS[1], 'wordImageMove', 'batch-photo', offset=8),
                    target(initial, LABELS[5], 'wordImageMove', 'batch-photo'),
                    {'op': 'imageReplace', 'id': 'batch-photo', 'assetId': ASSET_ID},
                    {'op': 'wordImageDelete', 'id': 'batch-photo'}]
                batch = apply(runtime, source, output, 'batch-add-move-replace-delete', operations,
                    assets, asset_root, report)
                require(independent(runtime, batch, output, 'after-batch-independent', report) == baseline,
                    'A single alias batch must restore the verified empty source after its final delete')
                report['checks']['sameBatchAliasFinalEmptyPreserved'] = True
                report['sameBatchScope'] = ('Final alias dispatch and exact empty source restoration only; '
                    'same-paragraph movement intents are independently checked in separate worker results')
            else:
                source_id = paragraph(initial, LABELS[0])['id']
                selected = [row for row in initial['wordImages'] if row['paragraphId'] == source_id]
                require(len(selected) == 1, 'The first authored source Frame must be unique')
                require_photo_capabilities(selected)
                original_request = target(initial, LABELS[5], 'wordImageMove', selected[0]['id'])
                expected = expected_move(baseline, initial, original_request)
                dump(output / 'cross-original-expected-before.json', {'operation': original_request, 'expected': expected})
                crossed = apply(runtime, source, output, 'move-original-across-same-photos',
                    [original_request], [], asset_root, report)
                require(independent(runtime, crossed, output, 'after-cross-original-independent', report) == expected,
                    'Move must preserve every exact source raw state with only the request-derived saved Frame ZOrder permutation')
                crossed_snapshot = inspect(runtime, crossed, output, 'inspect-cross-original')
                middle_id = paragraph(crossed_snapshot, LABELS[2])['id']
                selected = [row for row in crossed_snapshot['wordImages'] if row['paragraphId'] == middle_id]
                require(len(selected) == 1, 'The middle original must still bind to its native Frame')
                require_photo_capabilities(selected)
                middle_index = list(row['id'] for row in crossed_snapshot['paragraphs']).index(middle_id)
                expected['photos'] = [row for row in expected['photos'] if row['paragraph'] != middle_index]
                expected['photos'] = predicted_saved_order(expected['photos'])
                delete_request = {'op': 'wordImageDelete', 'id': selected[0]['id']}
                dump(output / 'delete-original-expected-before.json', {'operation': delete_request, 'expected': expected})
                removed = apply(runtime, crossed, output, 'delete-middle-original-same-payload',
                    [delete_request], [], asset_root, report)
                require(independent(runtime, removed, output, 'after-delete-original-independent', report) == expected,
                    'Delete must remove only the selected duplicate payload Frame and preserve each source survivor')
                report['checks'].update(sourceCrossMove=True, exactDuplicateSourceDelete=True)
        else:
            cases = []
            if case == 'protected':
                rich = initial['paragraphs'][0]
                base = {'op': 'wordImageAdd', 'id': 'bad-photo', 'ownerId': 'body',
                    'paragraphId': rich['id'], 'offsetUtf16': 2,
                    'expectedTextSha256': worker.office_text.text_hash(rich['text']),
                    'assetId': ASSET_ID, 'width': 25.4, 'height': 19.05}
                cases.append(('surrogate-middle', base))
                for index, row in enumerate(rich['textDetails']['protectedRanges']):
                    cases.append(('protected-' + str(index), {**base, 'offsetUtf16': row['startUtf16']}))
            valid = target(initial, LABELS[1])
            cases.extend([('foreign-owner', {**valid, 'ownerId': 'unrelated-owner'}),
                ('stale-text', {**valid, 'expectedTextSha256': 'f' * 64}),
                ('negative-width', {**valid, 'width': -1}),
                ('unknown-field', {**valid, 'url': 'https://example.invalid/photo.png'})])
            for name, operation in cases:
                directory = output / ('rejected-' + name)
                try:
                    worker.run_request(runtime, {'mode': 'apply', 'sourcePath': str(source),
                        'sessionId': name, 'expectedSourceSha256': source_hash, 'operations': [operation],
                        'imageAssets': assets}, directory, asset_root=asset_root)
                except ValueError as error:
                    require(not (directory / 'edited.docx').exists() and not (directory / 'preview.pdf').exists(),
                        'Rejected operation left a saved edition')
                    report['checks'][name] = True
                    report.setdefault('preflightRejections', []).append({'name': name,
                        'type': type(error).__name__, 'message': str(error)})
                else:
                    raise AssertionError('The unsafe mutation was accepted: ' + name)
        require(worker.digest(source) == source_hash, 'The canonical fixture changed')
        report['sourceHashesAfter'] = {str(path): worker.digest(path) for path in product}
        require(report['sourceHashesBefore'] == report['sourceHashesAfter'], 'Product sources changed during the native run')
        require(bool(report['independentServers']) and all(row['exitCompleted'] and
            row['ownedLoaderHandleClosed'] and row['ownedJobHandleClosed']
            for row in report['independentServers']),
            'A native independent server did not complete its owned handle closure')
        report['completed'] = True
        report['integrityConfirmed'] = True
    except BaseException as error:
        report['error'] = {'type': type(error).__name__, 'message': str(error), 'traceback': traceback.format_exc()}
        raise
    finally:
        report['elapsedSeconds'] = time.monotonic() - started
        report['ownedIndependentHandlesClosed'] = all(row['exitCompleted'] and row['ownedLoaderHandleClosed']
            and row['ownedJobHandleClosed'] for row in report['independentServers'])
        dump(output / 'result.json', report)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--runtime', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--case', choices=('basic', 'multiple', 'protected', 'preflight'), required=True)
    arguments = parser.parse_args()
    run(arguments.runtime.resolve(), arguments.output.resolve(), arguments.case)
