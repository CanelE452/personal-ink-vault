"""Actual synthetic PPT design edits, live aliases, ownership and preservation."""
import argparse
from contextlib import contextmanager
import hashlib
import json
from pathlib import Path
import struct
import sys
import traceback
import zipfile
import zlib

sys.path.insert(0, str(Path(__file__).resolve().parent))
import office_worker as worker

ASSET_ID = '11111111-1111-4111-8111-111111111111'
def text_hash(value):
    return hashlib.sha256(value.encode('utf-8')).hexdigest()


def design_hash(master_id, layout):
    return text_hash(json.dumps({'layoutCode': layout, 'masterId': master_id},
        sort_keys=True, separators=(',', ':')))


def png_bytes():
    def chunk(kind, content):
        return struct.pack('>I', len(content)) + kind + content + struct.pack('>I', zlib.crc32(kind + content))
    pixels = b'\x00\xff\x00\x00\x00\xff\x00\x00\x00\x00\xff\xff\xff\x00'
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 2, 2, 8, 2, 0, 0, 0)) +
        chunk(b'IDAT', zlib.compress(pixels)) + chunk(b'IEND', b''))


def close_document(document, errors, label):
    if document is None:
        return
    original = sys.exc_info()
    try:
        document.close(True)
    except BaseException as error:
        errors.append({'label': label, 'message': str(error), 'traceback': traceback.format_exc(),
            'duringOriginalException': original[0] is not None})


@contextmanager
def short_server(runtime, directory, report, label):
    directory.mkdir(parents=True, exist_ok=False)
    observation = {'label': label, 'entered': False, 'exitCompleted': False}
    report['helperServers'].append(observation)
    owner = worker.OfficeServer(runtime, directory)
    try:
        server = owner.__enter__()
        observation['entered'] = True
        yield server
    finally:
        original = sys.exc_info()
        cleanup_error = None
        if observation['entered']:
            try:
                owner.__exit__(*original)
                observation['exitCompleted'] = True
            except BaseException as error:
                cleanup_error = error
                report['cleanupErrors'].append({'label': label + '_server_close', 'message': str(error),
                    'traceback': traceback.format_exc(), 'duringOriginalException': original[0] is not None})
        try:
            profile, process = getattr(owner, 'profile', None), getattr(owner, 'process', None)
            observation['ownedProfileRemoved'] = None if profile is None else not profile.exists()
            for attribute, name in (('process', 'ownedLoaderHandleClosed'), ('job', 'ownedJobHandleClosed')):
                observation[name] = (not bool(getattr(process, attribute))) if (
                    process is not None and hasattr(process, attribute)) else None
        except BaseException as error:
            report['cleanupErrors'].append({'label': label + '_ownership_observation', 'message': str(error),
                'traceback': traceback.format_exc(), 'duringOriginalException': original[0] is not None})
        if original[0] is None:
            if cleanup_error is not None:
                raise cleanup_error
            if any(observation.get(name) is False for name in ('ownedLoaderHandleClosed', 'ownedJobHandleClosed')):
                raise RuntimeError('Previous helper Office process handles are still open')


def graph(server, content):
    stream = server.context.ServiceManager.createInstanceWithContext('com.sun.star.io.SequenceInputStream', server.context)
    stream.initialize((worker.uno.ByteSequence(content),))
    provider = server.context.ServiceManager.createInstanceWithContext('com.sun.star.graphic.GraphicProvider', server.context)
    return provider.queryGraphic((worker.prop('InputStream', stream),))


def add_text(document, owner, content, x, y, width, height):
    shape = document.createInstance('com.sun.star.drawing.TextShape')
    owner.add(shape)
    shape.Position = worker.uno.createUnoStruct('com.sun.star.awt.Point', x, y)
    shape.Size = worker.uno.createUnoStruct('com.sun.star.awt.Size', width, height)
    shape.String = content
    return shape


def create_source(server, source, image, errors):
    document = server.desktop.loadComponentFromURL('private:factory/simpress', '_blank', 0,
        (worker.prop('Hidden', True), worker.prop('MacroExecutionMode', 0)))
    if document is None:
        raise ValueError('Synthetic PPT fixture could not be created')
    try:
        while document.MasterPages.Count < 2:
            document.MasterPages.insertNewByIndex(document.MasterPages.Count)
        masters = [document.MasterPages.getByIndex(index) for index in range(2)]
        masters[1].Width, masters[1].Height = masters[0].Width, masters[0].Height
        for index, master in enumerate(masters):
            master.setName('MASTER_' + ('A' if index == 0 else 'B'))
            background = document.createInstance('com.sun.star.drawing.Background')
            worker.apply_fill(background, {'fillStyle': 'solid', 'fillColor': 0xFFF6E0 if index == 0 else 0xE0F0FF})
            master.Background = background
            add_text(document, master, 'COMMON_MASTER_' + ('A' if index == 0 else 'B'), 1200, 300, 16000, 1500)
        while document.DrawPages.Count < 3:
            document.DrawPages.insertNewByIndex(document.DrawPages.Count)
        observations = []
        for index in range(3):
            page = document.DrawPages.getByIndex(index)
            page.setMasterPage(masters[1 if index == 1 else 0])
            page.Layout = 1
            information = page.getPropertySetInfo()
            assert information.hasPropertyByName('Visible'), 'Fixture requires actual Visible property'
            assert information.getPropertyByName('Visible').Type.typeName == 'boolean'
            page.Visible = index != 2
            page.IsBackgroundObjectsVisible = True
            native_shapes = [page.getByIndex(position) for position in range(page.Count)]
            found = []
            for shape in native_shapes:
                kind = shape.getShapeType().rsplit('.', 1)[-1]
                if kind not in ('TitleTextShape', 'OutlinerShape'):
                    continue
                empty = index == 1 if kind == 'TitleTextShape' else index == 2
                if not empty:
                    shape.String = ('TITLE_' if kind == 'TitleTextShape' else 'BODY_') + str(index)
                found.append({'type': kind, 'requestedEmpty': empty, 'text': shape.String,
                    'presentation': shape.IsPresentationObject, 'empty': shape.IsEmptyPresentationObject})
            observations.append({'slide': index, 'placeholders': found})
            add_text(document, page, 'DIRECT_SLIDE_' + str(index), 1400, 8000, 12000, 1600)
            rectangle = document.createInstance('com.sun.star.drawing.RectangleShape')
            page.add(rectangle)
            rectangle.Position = worker.uno.createUnoStruct('com.sun.star.awt.Point', 18000, 8000)
            rectangle.Size = worker.uno.createUnoStruct('com.sun.star.awt.Size', 5000, 2000)
            rectangle.String = 'RECT_' + str(index)
            notes = page.getNotesPage()
            bodies = [notes.getByIndex(i) for i in range(notes.Count)
                if notes.getByIndex(i).getShapeType().endswith('.NotesShape')]
            if bodies:
                bodies[0].String = 'NOTES_SPEAKER_' + str(index)
            else:
                add_text(document, notes, 'NOTES_SPEAKER_' + str(index), 1000, 10000, 16000, 3000)
            if index == 0:
                rich = add_text(document, page, 'A😀B', 1200, 11000, 14000, 1600)
                cursor = rich.Text.createTextCursor()
                cursor.gotoEnd(True)
                cursor.CharHeight, cursor.CharColor = 12, 0xCC2200
                cursor.gotoStart(False)
                cursor.goRight(1, False)
                cursor.gotoEnd(True)
                cursor.CharHeight, cursor.CharWeight, cursor.CharColor = 24, 150, 0x0033CC
                photo = document.createInstance('com.sun.star.drawing.GraphicObjectShape')
                page.add(photo)
                photo.Graphic = graph(server, image)
                photo.Position = worker.uno.createUnoStruct('com.sun.star.awt.Point', 21000, 11000)
                photo.Size = worker.uno.createUnoStruct('com.sun.star.awt.Size', 3500, 2200)
                photo.RotateAngle = 1200
                crop = photo.GraphicCrop
                crop.Left, crop.Top = 20, 30
                photo.GraphicCrop = crop
        source.with_name('fixture-observations.json').write_text(json.dumps(observations, ensure_ascii=False, indent=2), encoding='utf-8')
        document.storeToURL(source.as_uri(), (worker.prop('FilterName', worker.FILTERS['pptx']),))
    finally:
        close_document(document, errors, 'fixture_close')


def evidence(server, path, errors):
    document = server.load(path)
    try:
        slides = []
        for index in range(document.DrawPages.Count):
            page = document.DrawPages.getByIndex(index)
            notes = page.getNotesPage()
            texts, photos = [], []
            for position in range(page.Count):
                shape = page.getByIndex(position)
                if hasattr(shape, 'String'):
                    texts.append(shape.String)
                if shape.getShapeType() == 'com.sun.star.drawing.GraphicObjectShape':
                    crop = shape.GraphicCrop
                    photos.append({'position': [shape.Position.X, shape.Position.Y],
                        'size': [shape.Size.Width, shape.Size.Height], 'rotation': shape.RotateAngle,
                        'crop': [crop.Left, crop.Top, crop.Right, crop.Bottom],
                        'pixels': [shape.Graphic.SizePixel.Width, shape.Graphic.SizePixel.Height]})
            slides.append({'directMarkers': [value for value in texts if value.startswith('DIRECT_SLIDE_')],
                'visible': page.Visible, 'showMasterObjects': page.IsBackgroundObjectsVisible,
                'notes': [notes.getByIndex(i).String for i in range(notes.Count)
                    if hasattr(notes.getByIndex(i), 'String') and notes.getByIndex(i).String.startswith('NOTES_SPEAKER_')],
                'photos': photos})
        return slides
    finally:
        close_document(document, errors, 'evidence_close')


def media_hashes(path):
    with zipfile.ZipFile(path) as archive:
        return sorted(hashlib.sha256(archive.read(name)).hexdigest() for name in archive.namelist()
            if name.startswith('ppt/media/'))


def find_shape(snapshot, text):
    return next(shape for slide in snapshot['slides'] for shape in slide['shapes'] if shape['text'] == text)


def projection(snapshot):
    return {'slides': [{'id': slide['id'], 'masterId': slide['masterId'], 'layoutCode': slide['layoutCode'],
        'visible': slide['visible'], 'showMasterObjects': slide['showMasterObjects'],
        'shapes': [(shape['id'], shape['ownerKind'], shape['ownerId'], shape['text']) for shape in slide['shapes']]}
        for slide in snapshot['slides']], 'masters': [{'id': master['id'],
            'shapes': [(shape['id'], shape['ownerKind'], shape['ownerId'], shape['text']) for shape in master['shapes']]}
            for master in snapshot['masters']]}


def run(runtime, output):
    output.mkdir(parents=True, exist_ok=False)
    worker.initialize(runtime)
    report = {'passed': False, 'cleanupErrors': [], 'helperServers': [],
        'lifecycleMode': 'unmodified-production-server-per-request; serial-short-owned-helper-servers',
        'requestServerStartupObserved': None, 'requestServerCleanupObserved': None}
    source = output / 'original.pptx'
    asset_root = output / 'asset-root'
    asset_dir = asset_root / 'assets'
    asset_dir.mkdir(parents=True)
    image = png_bytes()
    (asset_dir / (ASSET_ID + '.png')).write_bytes(image)
    descriptor = {'id': ASSET_ID, 'fileName': 'assets/' + ASSET_ID + '.png', 'mimeType': 'image/png',
        'byteLength': len(image), 'sha256': hashlib.sha256(image).hexdigest(), 'width': 2, 'height': 2}
    original_server = worker.OfficeServer
    try:
        with short_server(runtime, output / 'fixture-engine', report, 'fixture') as server:
            create_source(server, source, image, report['cleanupErrors'])
        source_hash = worker.digest(source)
        report['sourceSha256'] = source_hash
        initial = worker.run_request(runtime, {'mode': 'inspect', 'sourcePath': str(source)}, output / 'inspect')['snapshot']
        (output / 'initial-snapshot.json').write_text(json.dumps(initial, ensure_ascii=False, indent=2), encoding='utf-8')
        assert initial.get('masters'), 'Actual presentation masters and design metadata are missing'
        assert {item['code'] for item in initial['layoutOptions']} == {0, 1, 19, 20}
        assert len(initial['slides']) == 3 and len(initial['masters']) >= 2
        for slide in initial['slides']:
            assert slide['designSha256'] == design_hash(slide['masterId'], slide['layoutCode'])
            assert all(shape['ownerKind'] == 'slide' and shape['ownerId'] == slide['id'] for shape in slide['shapes'])
        for master in initial['masters']:
            assert all(shape['ownerKind'] == 'master' and shape['ownerId'] == master['id'] for shape in master['shapes'])
        master_b = next(master for master in initial['masters'] if any(shape['text'] == 'COMMON_MASTER_B' for shape in master['shapes']))
        decoration = next(shape for shape in master_b['shapes'] if shape['text'] == 'COMMON_MASTER_B')
        template = next(shape for master in initial['masters'] for shape in master['shapes'] if shape['presentationObject'] is True)
        assert all(template[key] is False for key in ('editableText', 'canEditGeometry', 'canDelete', 'canEditTextStyle', 'canEditFill', 'canEditLine'))
        first, empty_slide = initial['slides'][0], initial['slides'][2]
        empty_body = next(shape for shape in empty_slide['shapes'] if shape['type'].endswith('.OutlinerShape'))
        (output / 'imported-empty-placeholder.json').write_text(json.dumps(empty_body,
            ensure_ascii=False, indent=2), encoding='utf-8')
        assert empty_body['presentationObject'] is True and empty_body['emptyPresentationObject'] is False
        empty_details = empty_body['textDetails']
        assert empty_body['text'] == '' and empty_details['utf16Length'] == 0
        assert empty_details['textSha256'] == text_hash('')
        assert all(run['startUtf16'] == run['endUtf16'] == 0 for run in empty_details['runs'])
        assert empty_details['protectedRanges'] == [] and empty_details['truncated'] is False
        rich = find_shape(initial, 'A😀B')
        def apply(name, operations, draft=False, assets=False, **extra):
            request = {'mode': 'apply', 'sourcePath': str(source), 'sessionId': name,
                'expectedSourceSha256': source_hash, 'operations': operations, **extra}
            if draft:
                request['includeDraftSnapshot'] = True
            if assets:
                request['imageAssets'] = [descriptor]
            return worker.run_request(runtime, request, output / name, asset_root=asset_root)
        # The mixed edit performs one native save. Its photo control must use the same pass.
        baseline = apply('no-op', [])
        assert baseline.get('draftSnapshot') is None
        with short_server(runtime, output / 'baseline-evidence-engine', report, 'baseline-evidence') as server:
            baseline_evidence = evidence(server, Path(baseline['sourcePath']), report['cleanupErrors'])
        operations = [
            {'op': 'textReplace', 'targetKind': 'shape', 'id': rich['id'], 'startUtf16': 3,
                'endUtf16': 4, 'expectedTextSha256': text_hash('A😀B'), 'text': 'Q'},
            {'op': 'slideDesign', 'id': first['id'], 'changeId': 'design-main',
                'expectedDesignSha256': first['designSha256'], 'masterId': master_b['id'], 'layoutCode': 19},
            {'op': 'textStyle', 'targetKind': 'shape', 'id': rich['id'], 'startUtf16': 1,
                'endUtf16': 3, 'expectedTextSha256': text_hash('A😀Q'), 'italic': True},
            {'op': 'shapeText', 'id': decoration['id'], 'text': 'COMMON_MASTER_B_EDITED'},
            {'op': 'shapeStyle', 'id': decoration['id'], 'fontSize': 18, 'bold': True, 'color': 0x883355},
            {'op': 'shapeGeometry', 'id': decoration['id'], 'x': 12, 'y': 3, 'width': 180, 'height': 18},
            {'op': 'slideBackground', 'id': master_b['id'], 'fillStyle': 'solid', 'fillColor': 0xDDEEAA},
            {'op': 'shapeAdd', 'id': 'new-master-text', 'slideId': master_b['id'], 'shapeKind': 'text',
                'x': 12, 'y': 23, 'width': 100, 'height': 15, 'text': 'MASTER_EXTRA'},
            {'op': 'imageAdd', 'id': 'master-photo', 'slideId': master_b['id'], 'assetId': ASSET_ID,
                'x': 220, 'y': 3, 'width': 15, 'height': 15},
            {'op': 'slideDisplay', 'id': first['id'], 'showMasterObjects': False},
            {'op': 'slideDisplay', 'id': empty_slide['id'], 'visible': True},
            {'op': 'slideMove', 'id': empty_slide['id'], 'index': 0},
        ]
        edited = apply('main', operations, draft=True, assets=True)
        (output / 'main-result.json').write_text(json.dumps(edited,
            ensure_ascii=False, indent=2), encoding='utf-8')
        live = edited['draftSnapshot']
        assert live['sourceSha256'] == source_hash and edited['snapshot']['sourceSha256'] == edited['sourceSha256']
        assert [slide['id'] for slide in live['slides']] == ['slide-2', 'slide-0', 'slide-1']
        assert find_shape(live, 'A😀Q')['id'] == rich['id']
        live_first = next(slide for slide in live['slides'] if slide['id'] == first['id'])
        assert (live_first['masterId'], live_first['layoutCode'], live_first['showMasterObjects']) == (master_b['id'], 19, False)
        assert live_first['designSha256'] == design_hash(master_b['id'], 19)
        assert live['slides'][0]['visible'] is True
        live_master = next(master for master in live['masters'] if master['id'] == master_b['id'])
        assert any(shape['id'] == 'master-photo' and shape['ownerId'] == master_b['id'] for shape in live_master['shapes'])
        assert any(shape['id'] == 'new-master-text' for shape in live_master['shapes'])
        assert live_master['backgroundColor'] == 0xDDEEAA
        assert edited['pdfPageCount'] == 3
        pdf_text = [''.join((page.extract_text() or '').split()) for page in worker.PdfReader(edited['pdfPath']).pages]
        assert 'COMMON_MASTER_A' in pdf_text[0]
        assert 'COMMON_MASTER_B_EDITED' not in pdf_text[1] and 'MASTER_EXTRA' not in pdf_text[1]
        assert 'COMMON_MASTER_B_EDITED' in pdf_text[2] and 'MASTER_EXTRA' in pdf_text[2]
        assert not any('NOTES_SPEAKER_' in value for value in pdf_text)
        with short_server(runtime, output / 'main-evidence-engine', report, 'main-evidence') as server:
            actual_evidence = evidence(server, Path(edited['sourcePath']), report['cleanupErrors'])
        assert [item['notes'] for item in actual_evidence] == [['NOTES_SPEAKER_2'], ['NOTES_SPEAKER_0'], ['NOTES_SPEAKER_1']]
        assert actual_evidence[1]['photos'] == baseline_evidence[0]['photos'], 'Original photo geometry/crop/rotation changed'
        assert set(media_hashes(Path(baseline['sourcePath']))).issubset(media_hashes(Path(edited['sourcePath'])))
        replay = apply('main-replay', operations, draft=True, assets=True)
        assert projection(replay['draftSnapshot']) == projection(live), 'Original journal replay changed live aliases or owners'
        empty_operation = {'op': 'slideDesign', 'id': empty_slide['id'], 'changeId': 'design-empty',
            'expectedDesignSha256': empty_slide['designSha256'], 'layoutCode': 0}
        empty_result = apply('empty-design', [empty_operation], draft=True)
        (output / 'empty-result.json').write_text(json.dumps(empty_result,
            ensure_ascii=False, indent=2), encoding='utf-8')
        empty_live = next(slide for slide in empty_result['draftSnapshot']['slides'] if slide['id'] == empty_slide['id'])
        original_empty_shapes = {shape['id']: shape for shape in empty_slide['shapes']}
        current_empty_shapes = {shape['id']: shape for shape in empty_live['shapes']}
        assert set(original_empty_shapes).issubset(current_empty_shapes), 'Layout removed an observed surviving original shape'
        assert current_empty_shapes[empty_body['id']]['text'] == ''
        assert all(current_empty_shapes[identifier]['text'] == shape['text']
            for identifier, shape in original_empty_shapes.items()), 'Layout changed surviving original content'
        assert all(shape['ownerKind'] == 'slide' and shape['ownerId'] == empty_slide['id']
            for shape in empty_live['shapes']), 'Layout changed original or generated shape ownership'
        generated = [shape for shape in empty_live['shapes'] if shape['id'].startswith('design-empty/shape-')]
        assert generated and all(shape['ownerId'] == empty_slide['id'] for shape in generated)
        assert all(shape['id'] not in original_empty_shapes for shape in generated)
        report['emptyPlaceholderEvidence'] = {
            'survivingOriginalIds': list(original_empty_shapes),
            'originalEmptyBodyId': empty_body['id'],
            'originalEmptyBodyText': current_empty_shapes[empty_body['id']]['text'],
            'allSurvivingTextUnchanged': True,
            'generated': [{name: shape[name] for name in
                ('id', 'type', 'text', 'ownerKind', 'ownerId')} for shape in generated]}
        fresh = next(shape for shape in generated if shape['editableText'])
        followup = apply('empty-followup', [empty_operation,
            {'op': 'shapeText', 'id': fresh['id'], 'text': 'NEW_PLACEHOLDER_TEXT'}], draft=True)
        assert find_shape(followup['draftSnapshot'], 'NEW_PLACEHOLDER_TEXT')['id'] == fresh['id']
        assert find_shape(followup['snapshot'], 'NEW_PLACEHOLDER_TEXT')['ownerKind'] == 'slide'
        existing_followup = apply('existing-placeholder-followup', [empty_operation,
            {'op': 'shapeText', 'id': empty_body['id'], 'text': 'EXISTING_PLACEHOLDER_TEXT'}], draft=True)
        existing_live = find_shape(existing_followup['draftSnapshot'], 'EXISTING_PLACEHOLDER_TEXT')
        existing_canonical = find_shape(existing_followup['snapshot'], 'EXISTING_PLACEHOLDER_TEXT')
        assert existing_live['id'] == empty_body['id']
        assert existing_live['ownerKind'] == existing_canonical['ownerKind'] == 'slide'
        assert existing_live['ownerId'] == existing_canonical['ownerId'] == empty_slide['id']
        assert existing_followup['draftSnapshot']['sourceSha256'] == source_hash
        assert worker.digest(source) == source_hash
        report['existingPlaceholderFollowup'] = {
            'originalId': empty_body['id'], 'text': existing_live['text'],
            'liveOwnerId': existing_live['ownerId'], 'canonicalOwnerId': existing_canonical['ownerId'],
            'originalHashUnchanged': True}
        other_formats = []
        for extension in ('ppt', 'odp'):
            imported_path = output / ('format-source.' + extension)
            with short_server(runtime, output / ('format-' + extension + '-engine'), report,
                    'format-' + extension) as server:
                document = server.load(source)
                try:
                    document.storeToURL(imported_path.as_uri(), (worker.prop('FilterName', worker.FILTERS[extension]),))
                finally:
                    close_document(document, report['cleanupErrors'], extension + '_fixture_close')
            imported_hash = worker.digest(imported_path)
            inspected = worker.run_request(runtime, {'mode': 'inspect', 'sourcePath': str(imported_path)},
                output / ('inspect-' + extension))['snapshot']
            target = inspected['slides'][0]
            selected = next(master for master in inspected['masters']
                if any(shape['text'] == 'COMMON_MASTER_B' for shape in master['shapes']))
            saved = worker.run_request(runtime, {'mode': 'apply', 'sourcePath': str(imported_path),
                'sessionId': 'format-' + extension, 'expectedSourceSha256': imported_hash,
                'includeDraftSnapshot': True, 'operations': [
                    {'op': 'slideDesign', 'id': target['id'], 'changeId': 'format-design',
                        'expectedDesignSha256': target['designSha256'], 'masterId': selected['id'], 'layoutCode': 19},
                    {'op': 'slideDisplay', 'id': target['id'], 'visible': False, 'showMasterObjects': False}]},
                output / ('format-' + extension))
            canonical = saved['snapshot']['slides'][0]
            assert canonical['layoutCode'] == 19 and canonical['visible'] is False
            assert canonical['showMasterObjects'] is False and saved['pdfPageCount'] == 3
            assert saved['draftSnapshot']['sourceSha256'] == imported_hash
            assert worker.digest(imported_path) == imported_hash
            other_formats.append({'extension': extension, 'saved': saved})
        invalid = [
            [{'op': 'slideDesign', 'id': first['id'], 'changeId': 'full-replace', 'expectedDesignSha256': first['designSha256'], 'layoutCode': 0}],
            [{'op': 'slideDesign', 'id': first['id'], 'changeId': 'missing-master', 'expectedDesignSha256': first['designSha256'], 'masterId': 'unknown'}],
            [{'op': 'slideDesign', 'id': first['id'], 'changeId': 'bad-hash', 'expectedDesignSha256': '0' * 64, 'layoutCode': 19}],
            [{'op': 'slideDesign', 'id': first['id'], 'changeId': first['id'], 'expectedDesignSha256': first['designSha256'], 'layoutCode': 19}],
            [{'op': 'slideDesign', 'id': first['id'], 'changeId': 'x' * 129, 'expectedDesignSha256': first['designSha256'], 'layoutCode': 19}],
            [{'op': 'slideDesign', 'id': first['id'], 'changeId': 'empty-request', 'expectedDesignSha256': first['designSha256']}],
            [{'op': 'slideDesign', 'id': master_b['id'], 'changeId': 'foreign-kind', 'expectedDesignSha256': first['designSha256'], 'layoutCode': 19}],
            [{'op': 'slideDesign', 'id': first['id'], 'changeId': 'wrong-master-kind', 'expectedDesignSha256': first['designSha256'], 'masterId': first['id']}],
            [{'op': 'slideDesign', 'id': first['id'], 'changeId': 'unsupported-layout', 'expectedDesignSha256': first['designSha256'], 'layoutCode': 3}],
            [{'op': 'slideDesign', 'id': first['id'], 'changeId': 'boolean-layout', 'expectedDesignSha256': first['designSha256'], 'layoutCode': False}],
            [{'op': 'slideDisplay', 'id': first['id']}],
            [{'op': 'slideDisplay', 'id': first['id'], 'visible': 0}],
            [{'op': 'slideDisplay', 'id': first['id'], 'showMasterObjects': 'false'}],
            [{'op': 'slideDisplay', 'id': master_b['id'], 'visible': True}],
            [{'op': 'slideDisplay', 'id': first['id'], 'showMasterBackground': False}],
            [{'op': 'shapeDelete', 'id': empty_body['id']}, empty_operation,
                {'op': 'shapeText', 'id': empty_body['id'], 'text': 'Deleted ID'}],
            [empty_operation, {'op': 'shapeAdd', 'id': empty_body['id'], 'slideId': empty_slide['id'], 'shapeKind': 'text', 'x': 1, 'y': 1, 'width': 10, 'height': 10}],
            [empty_operation, {'op': 'slideDesign', 'id': empty_slide['id'], 'changeId': 'design-empty', 'expectedDesignSha256': design_hash(empty_slide['masterId'], 0), 'layoutCode': 1}],
            [{'op': 'masterDuplicate', 'id': 'new-master', 'sourceId': master_b['id'], 'name': 'Unsupported'}],
            [{'op': 'shapeAdd', 'id': master_b['id'], 'slideId': first['id'], 'shapeKind': 'text', 'x': 1, 'y': 1, 'width': 10, 'height': 10}],
            [empty_operation, {'op': 'shapeAdd', 'id': 'design-empty/shape-999', 'slideId': empty_slide['id'], 'shapeKind': 'text', 'x': 1, 'y': 1, 'width': 10, 'height': 10}],
        ]
        for operation in [
            {'op': 'shapeText', 'text': 'Must not alter template'},
            {'op': 'shapeStyle', 'fontSize': 24},
            {'op': 'shapeGeometry', 'x': 1, 'y': 1, 'width': 10, 'height': 10},
            {'op': 'shapeDelete'}, {'op': 'shapeAppearance', 'fillColor': 0x112233},
            {'op': 'shapeAppearance', 'lineColor': 0x112233},
            {'op': 'textStyle', 'targetKind': 'shape', 'startUtf16': 0, 'endUtf16': 0,
                'expectedTextSha256': text_hash(template['text']), 'bold': True},
            {'op': 'textReplace', 'targetKind': 'shape', 'startUtf16': 0, 'endUtf16': 0,
                'expectedTextSha256': text_hash(template['text']), 'text': 'Inserted'}]:
            invalid.append([{**operation, 'id': template['id']}])
        for index, operations in enumerate(invalid):
            name = 'rejected-' + str(index)
            try:
                apply(name, operations)
            except (ValueError, KeyError):
                pass
            else:
                raise AssertionError('Unsafe presentation design operation accepted: ' + str(index))
            assert not (output / name / 'edited.pptx').exists() and not (output / name / 'preview.pdf').exists()
            assert worker.digest(source) == source_hash
        for name, request in [('bad-draft-type', {'mode': 'apply', 'operations': [], 'sessionId': 'bad', 'includeDraftSnapshot': 1}),
                ('inspect-with-draft', {'mode': 'inspect', 'includeDraftSnapshot': True})]:
            try:
                worker.run_request(runtime, {'sourcePath': str(source), **request}, output / name)
            except ValueError:
                pass
            else:
                raise AssertionError('Invalid draft snapshot request accepted: ' + name)
        report.update({'passed': True, 'originalHashUnchanged': worker.digest(source) == source_hash,
            'invalidRequestsRejected': len(invalid) + 2, 'main': edited, 'emptyDesign': empty_result,
            'followup': followup, 'aliasReplayEqual': True, 'photoPreservedAgainstNoOp': True,
            'additionalFormatRoundtrips': other_formats,
            'notesByFinalOrder': [item['notes'] for item in actual_evidence]})
    except BaseException:
        report['exception'] = traceback.format_exc()
        raise
    finally:
        report['officeServerClassUnchanged'] = worker.OfficeServer is original_server
        if report['cleanupErrors']:
            report['passed'] = False
        (output / 'result.json').write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
    assert report['passed'], report
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--runtime', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    try:
        result = run(args.runtime.resolve(), args.output.resolve())
    except BaseException:
        Path(str(args.output) + '.error.txt').write_text(traceback.format_exc(), encoding='utf-8')
        raise
    print(json.dumps({'passed': result['passed'], 'invalidRequestsRejected': result['invalidRequestsRejected'],
        'aliasReplayEqual': result['aliasReplayEqual']}))
