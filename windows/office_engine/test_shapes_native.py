"""Synthetic PPT authoring through the actual private Office worker."""
import argparse
import json
from pathlib import Path
import sys
import traceback
import xml.etree.ElementTree as ET
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import office_worker as worker


def second_slide_fill(path):
    ns = {'p': 'http://schemas.openxmlformats.org/presentationml/2006/main',
          'a': 'http://schemas.openxmlformats.org/drawingml/2006/main'}
    with zipfile.ZipFile(path) as archive:
        slide = ET.fromstring(archive.read('ppt/slides/slide2.xml'))
    shape = slide.find('p:cSld/p:spTree/p:sp', ns)
    result = {}
    for name, query in (('solidFill', 'p:spPr/a:solidFill'), ('fillReference', 'p:style/a:fillRef')):
        node = shape.find(query, ns)
        result[name] = None if node is None else ET.tostring(node, encoding='unicode')
    return result


def create_source(runtime, output):
    with worker.OfficeServer(runtime, output) as server:
        profile = server.profile
        document = server.desktop.loadComponentFromURL('private:factory/simpress', '_blank', 0,
            (worker.prop('Hidden', True), worker.prop('MacroExecutionMode', 0)))
        try:
            page = document.DrawPages.getByIndex(0)
            while page.Count:
                page.remove(page.getByIndex(0))
            for index, label in enumerate(('Remove original', 'Keep original')):
                shape = document.createInstance('com.sun.star.drawing.TextShape')
                page.add(shape)
                shape.String = label
                shape.Position = worker.uno.createUnoStruct('com.sun.star.awt.Point', 1000, 1000 + index * 2500)
                shape.Size = worker.uno.createUnoStruct('com.sun.star.awt.Size', 8000, 2000)
            second = document.DrawPages.insertNewByIndex(1)
            shape = document.createInstance('com.sun.star.drawing.RectangleShape')
            second.add(shape)
            shape.String = 'Unchanged second slide'
            shape.Position = worker.uno.createUnoStruct('com.sun.star.awt.Point', 1000, 1000)
            shape.Size = worker.uno.createUnoStruct('com.sun.star.awt.Size', 8000, 3000)
            source = output / 'original.pptx'
            document.storeToURL(source.as_uri(), (worker.prop('FilterName', worker.FILTERS['pptx']),))
            document.close(True)
            document = server.load(source)
            metadata = []
            for page_index in range(document.DrawPages.Count):
                page = document.DrawPages.getByIndex(page_index)
                for index in range(page.Count):
                    shape = page.getByIndex(index)
                    properties = shape.getPropertySetInfo()
                    geometry = shape.getPropertyValue('CustomShapeGeometry') if properties.hasPropertyByName('CustomShapeGeometry') else ()
                    metadata.append({'id': 'slide-' + str(page_index) + '/shape-' + str(index),
                        'type': shape.ShapeType,
                        'geometryType': next((entry.Value for entry in geometry if entry.Name == 'Type'), None)})
        finally:
            document.close(True)
    return source, {'path': str(profile), 'removed': not profile.exists()}, metadata


def run(runtime, output, *, require_profile_cleanup=True):
    worker.initialize(runtime)
    output.mkdir(parents=True, exist_ok=False)
    source, source_profile, metadata = create_source(runtime, output)
    (output / 'fixture-metadata.json').write_text(json.dumps(metadata, indent=2), encoding='utf-8')
    original_hash = worker.digest(source)
    initial = worker.run_request(runtime, {'mode': 'inspect', 'sourcePath': str(source)}, output / 'inspect')['snapshot']
    (output / 'initial-snapshot.json').write_text(json.dumps(initial, indent=2), encoding='utf-8')
    baseline = worker.run_request(runtime, {'mode': 'apply', 'sourcePath': str(source), 'sessionId': 'no-op-proof',
        'expectedSourceSha256': original_hash, 'operations': []}, output / 'no-op')
    (output / 'baseline-result.json').write_text(json.dumps(baseline, indent=2), encoding='utf-8')
    operations = [
        {'op': 'shapeAdd', 'id': 'created-text', 'slideId': 'slide-0', 'shapeKind': 'text',
         'x': 10, 'y': 60, 'width': 90, 'height': 20, 'text': 'Created literal macro://text'},
        {'op': 'shapeAdd', 'id': 'created-rectangle', 'slideId': 'slide-0', 'shapeKind': 'rectangle',
         'x': 120, 'y': 40, 'width': 35, 'height': 25, 'text': 'Created rectangle'},
        {'op': 'shapeAppearance', 'id': 'created-rectangle', 'fillStyle': 'solid', 'fillColor': 0x112233,
         'lineStyle': 'solid', 'lineColor': 0x445566, 'lineWidth': .75},
        {'op': 'shapeAdd', 'id': 'created-ellipse', 'slideId': 'slide-0', 'shapeKind': 'ellipse',
         'x': 120, 'y': 80, 'width': 35, 'height': 25, 'text': 'Created ellipse'},
        {'op': 'shapeAppearance', 'id': 'created-ellipse', 'fillStyle': 'none', 'lineStyle': 'none'},
        {'op': 'shapeAdd', 'id': 'created-line', 'slideId': 'slide-0', 'shapeKind': 'line',
         'x': 10, 'y': 110, 'width': 70, 'height': 0},
        {'op': 'shapeAppearance', 'id': 'created-line', 'lineStyle': 'solid', 'lineColor': 0x2299aa, 'lineWidth': .4},
        {'op': 'shapeAdd', 'id': 'created-vertical-line', 'slideId': 'slide-0', 'shapeKind': 'line',
         'x': 100, 'y': 80, 'width': 0, 'height': 40},
        {'op': 'shapeAdd', 'id': 'discarded', 'slideId': 'slide-0', 'shapeKind': 'text',
         'x': 20, 'y': 30, 'width': 50, 'height': 20, 'text': 'Must not survive deletion'},
        {'op': 'shapeDelete', 'id': 'discarded'},
        {'op': 'shapeDelete', 'id': 'slide-0/shape-0'},
        {'op': 'shapeText', 'id': 'slide-0/shape-1', 'text': 'Still the same original object'},
        {'op': 'slideBackground', 'id': 'slide-0', 'fillStyle': 'solid', 'fillColor': 0xF0E0D0},
    ]
    result = worker.run_request(runtime, {'mode': 'apply', 'sourcePath': str(source), 'sessionId': 'shapes-proof',
        'expectedSourceSha256': original_hash, 'operations': operations}, output / 'edit')
    (output / 'edit-result.json').write_text(json.dumps(result, indent=2), encoding='utf-8')
    slides = result['snapshot']['slides']
    shapes = slides[0]['shapes']
    by_text = {shape['text']: shape for shape in shapes}
    assert 'Remove original' not in by_text
    assert 'Must not survive deletion' not in by_text
    assert 'Still the same original object' in by_text
    assert len(shapes) == 6, shapes
    assert slides[0]['backgroundStyle'] == 'solid'
    assert slides[0]['backgroundColor'] == 0xF0E0D0
    created_text = by_text['Created literal macro://text']
    assert created_text['fontSize'] == 18 and created_text['bold'] is False and created_text['color'] == 0
    assert created_text['fillStyle'] == created_text['lineStyle'] == 'none'
    rectangle = by_text['Created rectangle']
    assert rectangle['shapeKind'] == 'rectangle'
    assert (rectangle['fillStyle'], rectangle['fillColor'], rectangle['lineStyle'], rectangle['lineColor']) == (
        'solid', 0x112233, 'solid', 0x445566)
    assert abs(rectangle['lineWidth'] - .75) < .02
    assert rectangle['canEditFill'] and rectangle['canEditLine']
    ellipse = by_text['Created ellipse']
    assert ellipse['shapeKind'] == 'ellipse'
    assert ellipse['fillStyle'] == ellipse['lineStyle'] == 'none'
    line = next(shape for shape in shapes if shape['shapeKind'] == 'line' and shape['width'] > 1)
    assert line['lineColor'] == 0x2299aa and abs(line['lineWidth'] - .4) < .02
    assert abs(line['height']) <= .02 and abs(line['width'] - 70) < .02
    assert not line['canEditFill'] and line['canEditLine']
    vertical = next(shape for shape in shapes if shape['shapeKind'] == 'line' and shape['height'] > 1)
    assert abs(vertical['width']) <= .02 and abs(vertical['height'] - 40) < .02
    assert slides[1]['shapes'] == baseline['snapshot']['slides'][1]['shapes'], {
        'baseline': baseline['snapshot']['slides'][1]['shapes'], 'edited': slides[1]['shapes']}
    assert result['pdfPageCount'] == 2
    pdf = worker.PdfReader(result['pdfPath'])
    pdf_text = [page.extract_text() for page in pdf.pages]
    compact_pdf_text = [''.join(value.split()) for value in pdf_text]
    (output / 'pdf-extracted-text.json').write_text(json.dumps({
        'pages': pdf_text, 'withoutWhitespace': compact_pdf_text}, indent=2), encoding='utf-8')
    for expected in ('Created literal macro://text', 'Created rectangle', 'Created ellipse', 'Still the same original object'):
        assert ''.join(expected.split()) in compact_pdf_text[0], expected
    assert 'Mustnotsurvivedeletion' not in compact_pdf_text[0]
    assert 'Unchangedsecondslide' in compact_pdf_text[1]
    with zipfile.ZipFile(result['sourcePath']) as archive:
        ns = {'p': 'http://schemas.openxmlformats.org/presentationml/2006/main',
              'a': 'http://schemas.openxmlformats.org/drawingml/2006/main'}
        slide = ET.fromstring(archive.read('ppt/slides/slide1.xml'))
        explicit = []
        for shape in slide.findall('p:cSld/p:spTree/p:sp', ns):
            content = ''.join(node.text or '' for node in shape.findall('.//a:t', ns))
            if content == 'Created rectangle':
                props = shape.find('p:spPr', ns)
                explicit = [props.find('a:solidFill/a:srgbClr', ns).get('val'),
                            props.find('a:ln/a:solidFill/a:srgbClr', ns).get('val')]
        assert explicit == ['112233', '445566'], explicit
    original_edit = Path(result['sourcePath'])
    line_baseline = worker.run_request(runtime, {'mode': 'apply', 'sourcePath': str(original_edit),
        'sessionId': 'line-only-no-op-proof', 'expectedSourceSha256': result['sourceSha256'],
        'operations': []}, output / 'line-only-no-op')
    line_only = worker.run_request(runtime, {'mode': 'apply', 'sourcePath': str(original_edit),
        'sessionId': 'line-only-proof', 'expectedSourceSha256': result['sourceSha256'],
        'operations': [{'op': 'shapeAppearance', 'id': 'slide-1/shape-0', 'lineColor': 0xA13B69}]}, output / 'line-only')
    (output / 'line-only-results.json').write_text(json.dumps({
        'baseline': line_baseline, 'feature': line_only}, indent=2), encoding='utf-8')
    expected_second = dict(line_baseline['snapshot']['slides'][1]['shapes'][0], lineColor=0xA13B69)
    assert line_only['snapshot']['slides'][1]['shapes'][0] == expected_second, {
        'expected': expected_second, 'actual': line_only['snapshot']['slides'][1]['shapes'][0]}
    assert worker.digest(original_edit) == result['sourceSha256']
    fills = {label: second_slide_fill(path) for label, path in (
        ('initial', source), ('noOp', Path(baseline['sourcePath'])), ('feature', original_edit),
        ('lineNoOp', Path(line_baseline['sourcePath'])), ('lineFeature', Path(line_only['sourcePath'])))}
    assert 'schemeClr' in fills['initial']['solidFill'], fills
    assert fills['initial']['solidFill'] == fills['noOp']['solidFill'] == fills['feature']['solidFill'], fills
    assert fills['noOp']['fillReference'] == fills['feature']['fillReference'], fills
    assert fills['lineNoOp'] == fills['lineFeature'], fills
    rejected = [
        [{'op': 'shapeDelete', 'id': 'unknown'}],
        [{'op': 'shapeAdd', 'id': 'slide-0/shape-0', 'slideId': 'slide-0', 'shapeKind': 'rectangle',
          'x': 0, 'y': 0, 'width': 10, 'height': 10}],
        [{'op': 'shapeDelete', 'id': 'slide-0/shape-0'},
         {'op': 'shapeAdd', 'id': 'slide-0/shape-0', 'slideId': 'slide-0', 'shapeKind': 'rectangle',
          'x': 0, 'y': 0, 'width': 10, 'height': 10}],
        [{'op': 'shapeAdd', 'id': 'bad-kind', 'slideId': 'slide-0', 'shapeKind': 'image',
          'x': 0, 'y': 0, 'width': 10, 'height': 10}],
        [{'op': 'shapeAdd', 'id': 'bad-size', 'slideId': 'slide-0', 'shapeKind': 'rectangle',
          'x': 0, 'y': 0, 'width': 0, 'height': 0}],
        [{'op': 'shapeAppearance', 'id': 'slide-0/shape-1', 'fillStyle': 'gradient'}],
        [{'op': 'shapeAppearance', 'id': 'slide-0/shape-1', 'lineWidth': float('nan')}],
        [{'op': 'shapeAppearance', 'id': 'slide-0/shape-1', 'fillColor': True}],
        [{'op': 'shapeAppearance', 'id': 'slide-0/shape-1', 'fillColor': 1.5}],
        [{'op': 'slideBackground', 'id': 'slide-0', 'fillStyle': 'bitmap'}],
        [{'op': 'shapeDelete', 'id': 'slide-0/shape-0', 'sourcePath': 'untrusted'}],
        [{'op': 'slideAdd', 'id': 'temporary-slide', 'index': 2, 'text': ''},
         {'op': 'shapeAdd', 'id': 'custom-on-temporary', 'slideId': 'temporary-slide', 'shapeKind': 'rectangle',
          'x': 0, 'y': 0, 'width': 10, 'height': 10},
         {'op': 'slideDelete', 'id': 'temporary-slide'},
         {'op': 'shapeDelete', 'id': 'custom-on-temporary'}],
        [{'op': 'shapeAdd', 'id': 'future-slide/shape-0', 'slideId': 'slide-0', 'shapeKind': 'rectangle',
          'x': 0, 'y': 0, 'width': 10, 'height': 10},
         {'op': 'slideAdd', 'id': 'future-slide', 'index': 2, 'text': ''}],
    ]
    for index, invalid in enumerate(rejected):
        directory = output / ('rejected-' + str(index))
        try:
            worker.run_request(runtime, {'mode': 'apply', 'sourcePath': str(source), 'sessionId': 'rejected',
                'expectedSourceSha256': original_hash, 'operations': invalid}, directory)
        except ValueError:
            pass
        else:
            raise AssertionError('Invalid shape operation accepted: ' + str(index))
        assert not (directory / 'edited.pptx').exists() and not (directory / 'preview.pdf').exists()
    assert worker.digest(source) == original_hash
    source_profile['removed'] = not Path(source_profile['path']).exists()
    if require_profile_cleanup:
        assert source_profile['removed'], source_profile
    report = {'passed': True, 'sourceProfileCleanupRequired': require_profile_cleanup,
        'originalHashUnchanged': True, 'sourceSha256': original_hash,
        'sourceFixtureProfile': source_profile,
        'originalShapeMetadata': metadata, 'lineColorOnlyPreservesThemedFill': True,
        'noOpBaseline': baseline, 'lineOnlyNoOpBaseline': line_baseline, 'fillXml': fills,
        'roundtripNormalization': {key: {'initial': left, 'noOpBaseline': baseline['snapshot']['slides'][1]['shapes'][0][key]}
            for key, left in initial['slides'][1]['shapes'][0].items()
            if left != baseline['snapshot']['slides'][1]['shapes'][0][key]},
        'presentation': result, 'invalidRequestsRejected': len(rejected), 'explicitRgbXml': explicit}
    (output / 'result.json').write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding='utf-8')
    print(json.dumps({'passed': True, 'presentationPdfPages': result['pdfPageCount'], 'invalidRequestsRejected': len(rejected)}))


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
