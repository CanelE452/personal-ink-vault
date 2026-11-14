"""Native embedded photo edits and no-op roundtrip preservation; synthetic inputs."""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import posixpath
import shutil
import struct
import sys
import traceback
import xml.etree.ElementTree as ET
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import office_worker as worker

PNG_ID = '11111111-1111-4111-8111-111111111111'
JPEG_ID = '22222222-2222-4222-8222-222222222222'


def graphic(server, path):
    stream = server.context.ServiceManager.createInstanceWithContext('com.sun.star.io.SequenceInputStream', server.context)
    stream.initialize((worker.uno.ByteSequence(path.read_bytes()),))
    provider = server.context.ServiceManager.createInstanceWithContext('com.sun.star.graphic.GraphicProvider', server.context)
    return provider.queryGraphic((worker.prop('InputStream', stream),))


def photo_state(shape):
    crop = shape.GraphicCrop
    return {'position': [shape.Position.X, shape.Position.Y], 'size': [shape.Size.Width, shape.Size.Height],
        'rotation': shape.RotateAngle, 'zOrder': shape.ZOrder,
        'crop': [crop.Top, crop.Bottom, crop.Left, crop.Right], 'mimeType': shape.Graphic.MimeType,
        'pixelSize': [shape.Graphic.SizePixel.Width, shape.Graphic.SizePixel.Height]}


def native_state(runtime, path, directory, expected_image_count):
    directory.mkdir()
    with worker.OfficeServer(runtime, directory) as server:
        document = server.load(path)
        try:
            page = document.DrawPages.getByIndex(0)
            shapes = [page.getByIndex(i) for i in range(page.Count)]
            diagnostics = []
            for index, shape in enumerate(shapes):
                value = worker.optional_property(shape, 'Graphic')
                diagnostics.append({'index': index, 'type': shape.ShapeType,
                    'supportsGraphicService': shape.supportsService('com.sun.star.drawing.GraphicObjectShape'),
                    'hasGraphic': value is not None,
                    'mimeType': None if value is None else value.MimeType})
            (directory / 'shape-observations.json').write_text(json.dumps(diagnostics, indent=2), encoding='utf-8')
            photos = [shape for shape in shapes if shape.ShapeType == 'com.sun.star.drawing.GraphicObjectShape']
            assert len(photos) == expected_image_count, diagnostics
            assert all(shape.Graphic is not None for shape in photos), diagnostics
            return [photo_state(shape) for shape in photos]
        finally:
            document.close(True)


def media(path):
    with zipfile.ZipFile(path) as archive:
        return sorted(hashlib.sha256(archive.read(name)).hexdigest()
            for name in archive.namelist() if name.startswith('ppt/media/'))


def package_photos(path):
    ns = {'p': 'http://schemas.openxmlformats.org/presentationml/2006/main',
        'a': 'http://schemas.openxmlformats.org/drawingml/2006/main',
        'r': 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'}
    with zipfile.ZipFile(path) as archive:
        slide = ET.fromstring(archive.read('ppt/slides/slide1.xml'))
        relationships = {item.get('Id'): item for item in ET.fromstring(archive.read('ppt/slides/_rels/slide1.xml.rels'))}
        photos = []
        for picture in slide.findall('p:cSld/p:spTree/p:pic', ns):
            blip = picture.find('p:blipFill/a:blip', ns)
            relation = relationships[blip.get('{' + ns['r'] + '}embed')]
            assert relation.get('Type') == ns['r'] + '/image' and relation.get('TargetMode') != 'External'
            member = posixpath.normpath('ppt/slides/' + relation.get('Target'))
            assert member.startswith('ppt/media/')
            photos.append({'member': member, 'sha256': hashlib.sha256(archive.read(member)).hexdigest()})
        return photos


def picture_geometry(path, index):
    ns = {'p': 'http://schemas.openxmlformats.org/presentationml/2006/main',
        'a': 'http://schemas.openxmlformats.org/drawingml/2006/main'}
    with zipfile.ZipFile(path) as archive:
        slide = ET.fromstring(archive.read('ppt/slides/slide1.xml'))
        picture = slide.findall('p:cSld/p:spTree/p:pic', ns)[index]
        transform = picture.find('p:spPr/a:xfrm', ns)
        offset, size = transform.find('a:off', ns), transform.find('a:ext', ns)
        return {'x': int(offset.get('x')), 'y': int(offset.get('y')),
            'width': int(size.get('cx')), 'height': int(size.get('cy'))}


def create_source(runtime, output, png):
    with worker.OfficeServer(runtime, output) as server:
        document = server.desktop.loadComponentFromURL('private:factory/simpress', '_blank', 0,
            (worker.prop('Hidden', True), worker.prop('MacroExecutionMode', 0)))
        try:
            page = document.DrawPages.getByIndex(0)
            while page.Count:
                page.remove(page.getByIndex(0))
            for index in range(2):
                shape = document.createInstance('com.sun.star.drawing.GraphicObjectShape')
                page.add(shape)
                shape.Graphic = graphic(server, png)
                shape.Position = worker.uno.createUnoStruct('com.sun.star.awt.Point', 2000 + index * 9000, 3000)
                shape.Size = worker.uno.createUnoStruct('com.sun.star.awt.Size', 7000, 4000)
                shape.RotateAngle = 1200
                shape.GraphicCrop = worker.uno.createUnoStruct('com.sun.star.text.GraphicCrop', 100, 200, 300, 400)
            text = document.createInstance('com.sun.star.drawing.TextShape')
            page.add(text)
            text.String = 'Untouched caption'
            text.Position = worker.uno.createUnoStruct('com.sun.star.awt.Point', 1000, 10000)
            text.Size = worker.uno.createUnoStruct('com.sun.star.awt.Size', 10000, 2000)
            source = output / 'original.pptx'
            document.storeToURL(source.as_uri(), (worker.prop('FilterName', worker.FILTERS['pptx']),))
        finally:
            document.close(True)
    return source


def stage(root, identifier, source, mime, width, height):
    target = root / 'assets' / (identifier + source.suffix)
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, target)
    return {'id': identifier, 'fileName': 'assets/' + target.name, 'mimeType': mime,
        'byteLength': target.stat().st_size, 'sha256': worker.digest(target), 'width': width, 'height': height}


def oriented_jpeg(source, target, orientation):
    original = source.read_bytes()
    assert original.startswith(b'\xff\xd8')
    tiff = (b'II\x2a\x00' + struct.pack('<I', 8) + struct.pack('<H', 1) +
        struct.pack('<HHI', 0x112, 3, 1) + struct.pack('<H', orientation) + b'\x00\x00' + struct.pack('<I', 0))
    payload = b'Exif\x00\x00' + tiff
    segment = b'\xff\xe1' + struct.pack('>H', len(payload) + 2) + payload
    target.write_bytes(original[:2] + segment + original[2:])
    assert target.read_bytes()[2 + len(segment):] == original[2:], 'EXIF fixture rewrote compressed raster bytes'


def apply(runtime, source, output, name, operations, assets=None, asset_root=None):
    return worker.run_request(runtime, {'mode': 'apply', 'sourcePath': str(source), 'sessionId': name,
        'expectedSourceSha256': worker.digest(source), 'operations': operations,
        **({'imageAssets': assets} if assets is not None else {})}, output / name, asset_root=asset_root)


def run(runtime, output, png, jpeg):
    worker.initialize(runtime)
    output.mkdir(parents=True, exist_ok=False)
    source = create_source(runtime, output, png)
    original_hash = worker.digest(source)
    initial = worker.run_request(runtime, {'mode': 'inspect', 'sourcePath': str(source)}, output / 'inspect')['snapshot']
    (output / 'initial-snapshot.json').write_text(json.dumps(initial, indent=2), encoding='utf-8')
    images = initial['slides'][0]['shapes'][:2]
    assert all(item['shapeKind'] == 'image' for item in images), 'Native photos are missing from the editable image snapshot'
    assert all(not item['editableText'] for item in images), 'Native photos must not advertise the rejected text-edit API'
    for item in images:
        details = item['image']
        assert details['mimeType'] == 'image/png' and details['canReplace']
        assert details['pixelWidth'] > 0 and details['pixelHeight'] > 0
        thumbnail = base64.b64decode(details['thumbnailBase64'], validate=True)
        assert len(thumbnail) <= 256 * 1024
        assert hashlib.sha256(thumbnail).hexdigest() == details['thumbnailSha256']
        assert thumbnail.startswith(b'\x89PNG\r\n\x1a\n')
    root = output / 'request-assets'
    png_graphic = images[0]['image']
    assets = [stage(root, PNG_ID, png, 'image/png', png_graphic['pixelWidth'], png_graphic['pixelHeight'])]
    # A native read of the JPEG supplies actual dimensions; the test arguments remain synthetic files.
    with worker.OfficeServer(runtime, output) as server:
        value = graphic(server, jpeg)
        assets.append(stage(root, JPEG_ID, jpeg, 'image/jpeg', value.SizePixel.Width, value.SizePixel.Height))
        exif_cases = []
        for orientation in (6, 8):
            path = output / ('orientation-' + str(orientation) + '.jpg')
            oriented_jpeg(jpeg, path, orientation)
            oriented = graphic(server, path)
            identifier = str(orientation) * 8 + '-3333-4333-8333-333333333333'
            descriptor = stage(root, identifier, path, 'image/jpeg', assets[1]['width'], assets[1]['height'])
            exif_cases.append({'orientation': orientation, 'asset': descriptor,
                'rawPixelSize': [assets[1]['width'], assets[1]['height']],
                'nativePixelSize': [oriented.SizePixel.Width, oriented.SizePixel.Height]})
    (output / 'exif-observations.json').write_text(json.dumps(exif_cases, indent=2), encoding='utf-8')
    baseline = apply(runtime, source, output, 'no-op', [])
    baseline_photos = package_photos(baseline['sourcePath'])
    assert len(baseline_photos) == 2 and all(item['sha256'] == worker.digest(png) for item in baseline_photos), baseline_photos
    before_state = native_state(runtime, Path(baseline['sourcePath']), output / 'baseline-state', 2)
    operations = [
        {'op': 'imageReplace', 'id': images[0]['id'], 'assetId': JPEG_ID},
        {'op': 'imageAdd', 'id': 'discarded-photo', 'slideId': 'slide-0', 'assetId': PNG_ID,
         'x': 5, 'y': 5, 'width': 20, 'height': 20},
        {'op': 'shapeDelete', 'id': 'discarded-photo'},
        {'op': 'imageAdd', 'id': 'created-photo', 'slideId': 'slide-0', 'assetId': PNG_ID,
         'x': 20, 'y': 100, 'width': 40, 'height': 30},
    ]
    result = apply(runtime, source, output, 'images-edited', operations, assets, root)
    (output / 'edit-result.json').write_text(json.dumps(result, indent=2), encoding='utf-8')
    after_state = native_state(runtime, Path(result['sourcePath']), output / 'edited-state', 3)
    assert len(package_photos(result['sourcePath'])) == 3
    for name in ['position', 'size', 'rotation', 'zOrder', 'crop']:
        assert after_state[0][name] == before_state[0][name], (name, before_state, after_state)
    assert after_state[1] == before_state[1], {'baseline': before_state, 'edited': after_state}
    assert after_state[0]['mimeType'] == 'image/jpeg' and len(after_state) == 3
    baseline_caption = next(shape for shape in baseline['snapshot']['slides'][0]['shapes'] if shape['text'] == 'Untouched caption')
    edited_caption = next(shape for shape in result['snapshot']['slides'][0]['shapes'] if shape['text'] == 'Untouched caption')
    assert edited_caption == baseline_caption
    assert set(media(result['sourcePath'])) == {worker.digest(png), worker.digest(jpeg)}
    assert result['pdfPageCount'] == 1 and 'Untouched caption' in worker.PdfReader(result['pdfPath']).pages[0].extract_text()
    for case in exif_cases:
        name = 'exif-' + str(case['orientation'])
        try:
            oriented_result = apply(runtime, source, output, name, [
                {'op': 'imageReplace', 'id': images[0]['id'], 'assetId': case['asset']['id']}], [case['asset']], root)
        except ValueError as error:
            assert str(error) == 'Native Office photo decoder did not match the verified asset', str(error)
            assert case['rawPixelSize'] != case['nativePixelSize'], case
            case['outcome'] = 'rejected_native_dimension_difference'
        else:
            assert case['nativePixelSize'] == case['rawPixelSize'], case
            assert case['asset']['sha256'] in media(oriented_result['sourcePath'])
            assert oriented_result['pdfPageCount'] == 1
            reopened_image = oriented_result['snapshot']['slides'][0]['shapes'][0]['image']
            case['reopenedPixelSize'] = [reopened_image['pixelWidth'], reopened_image['pixelHeight']]
            case['outcome'] = 'embedded_and_reopened'
        assert worker.digest(source) == original_hash
    (output / 'exif-observations.json').write_text(json.dumps(exif_cases, indent=2), encoding='utf-8')
    created = result['snapshot']['slides'][0]['shapes'][-1]['id']
    moved = apply(runtime, Path(result['sourcePath']), output, 'image-moved', [
        {'op': 'shapeGeometry', 'id': created, 'x': 32, 'y': 41, 'width': 50, 'height': 35}])
    (output / 'moved-result.json').write_text(json.dumps(moved, indent=2), encoding='utf-8')
    moved_image = moved['snapshot']['slides'][0]['shapes'][-1]
    source_geometry = picture_geometry(result['sourcePath'], 2)
    moved_geometry = picture_geometry(moved['sourcePath'], 2)
    requested_emu = {'x': 1152000, 'y': 1476000, 'width': 1800000, 'height': 1260000}
    assert moved_geometry == requested_emu, {'requestedEmu': requested_emu, 'persistedEmu': moved_geometry}
    source_image = result['snapshot']['slides'][0]['shapes'][-1]
    import_delta_hmm = {name: round(source_image[name] * 100) - source_geometry[name] // 360 for name in requested_emu}
    expected_import_hmm = {name: requested_emu[name] // 360 + import_delta_hmm[name] for name in requested_emu}
    actual_import_hmm = {name: round(moved_image[name] * 100) for name in requested_emu}
    geometry_observation = {'sourcePersistedEmu': source_geometry,
        'sourceReopenedHmm': {name: round(source_image[name] * 100) for name in requested_emu},
        'nativeImportDeltaHmm': import_delta_hmm, 'requestedEmu': requested_emu,
        'persistedEmu': moved_geometry, 'expectedReopenedHmm': expected_import_hmm,
        'actualReopenedHmm': actual_import_hmm}
    (output / 'geometry-observations.json').write_text(json.dumps(geometry_observation, indent=2), encoding='utf-8')
    assert actual_import_hmm == expected_import_hmm, geometry_observation
    deleted = apply(runtime, Path(moved['sourcePath']), output, 'image-deleted', [{'op': 'shapeDelete', 'id': moved_image['id']}])
    assert len([shape for shape in deleted['snapshot']['slides'][0]['shapes'] if shape['shapeKind'] == 'image']) == 2
    invalid_cases = [
        ([{'op': 'imageReplace', 'id': images[0]['id'], 'assetId': 'unknown'}], assets),
        ([{'op': 'imageReplace', 'id': 'slide-0/shape-2', 'assetId': JPEG_ID}], assets),
        ([{'op': 'imageAdd', 'id': images[0]['id'], 'slideId': 'slide-0', 'assetId': PNG_ID,
           'x': 0, 'y': 0, 'width': 10, 'height': 10}], assets),
        ([{'op': 'imageAdd', 'id': 'wrong-owner', 'slideId': 'slide-7', 'assetId': PNG_ID,
           'x': 0, 'y': 0, 'width': 10, 'height': 10}], assets),
        ([{'op': 'imageReplace', 'id': images[0]['id'], 'assetId': JPEG_ID}], [dict(assets[1], sha256='0' * 64)]),
        ([{'op': 'imageReplace', 'id': images[0]['id'], 'assetId': JPEG_ID}], [dict(assets[1], fileName='../probe.jpg')]),
        ([{'op': 'imageReplace', 'id': images[0]['id'], 'assetId': JPEG_ID}], [dict(assets[1], mimeType='image/gif')]),
        ([{'op': 'imageReplace', 'id': images[0]['id'], 'assetId': JPEG_ID}], [dict(assets[1], width=400000, height=400000)]),
    ]
    for index, (operations, bad_assets) in enumerate(invalid_cases):
        name = 'rejected-' + str(index)
        try:
            apply(runtime, source, output, name, operations, bad_assets, root)
        except (ValueError, KeyError):
            pass
        else:
            raise AssertionError('Unsafe photo operation accepted: ' + str(index))
        assert not (output / name / 'edited.pptx').exists()
    assert worker.digest(source) == original_hash
    report = {'passed': True, 'sourceSha256': original_hash, 'originalHashUnchanged': True,
        'noOpBaseline': baseline, 'feature': result, 'originalImageState': before_state,
        'editedImageState': after_state, 'untouchedPhotoEqualsNoOp': True,
        'replacementGeometryCropRotationZOrderEqualsNoOp': True, 'invalidRequestsRejected': len(invalid_cases)}
    report['exifOrientationObservations'] = exif_cases
    report['baselineEmbeddedPhotoRelationships'] = baseline_photos
    report['moveGeometryObservations'] = geometry_observation
    (output / 'result.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
    print(json.dumps({'passed': True, 'invalidRequestsRejected': len(invalid_cases)}))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--runtime', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--png', type=Path, required=True)
    parser.add_argument('--jpeg', type=Path, required=True)
    args = parser.parse_args()
    try:
        run(args.runtime.resolve(), args.output.resolve(), args.png.resolve(), args.jpeg.resolve())
    except BaseException:
        Path(str(args.output) + '.error.txt').write_text(traceback.format_exc(), encoding='utf-8')
        raise
