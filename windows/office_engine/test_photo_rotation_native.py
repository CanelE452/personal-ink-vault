"""Exercise picture rotation through the real Windows Office worker."""
import argparse
import json
from pathlib import Path
import sys
import xml.etree.ElementTree as ET
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import office_worker as worker
from test_images_native import apply, package_photos, picture_geometry


def transforms(path):
    ns = {'p': 'http://schemas.openxmlformats.org/presentationml/2006/main',
          'a': 'http://schemas.openxmlformats.org/drawingml/2006/main'}
    with zipfile.ZipFile(path) as archive:
        slide = ET.fromstring(archive.read('ppt/slides/slide1.xml'))
        return [int(picture.find('p:spPr/a:xfrm', ns).get('rot', 0))
                for picture in slide.findall('p:cSld/p:spTree/p:pic', ns)]


def run(runtime, source, output):
    worker.initialize(runtime)
    output.mkdir()
    source_hash = worker.digest(source)
    baseline = apply(runtime, source, output, 'baseline', [])
    plain = baseline['snapshot']['slides'][0]['shapes']
    photos = [shape for shape in plain if shape['shapeKind'] == 'image']
    first, second = photos
    assert first['image']['canRotate'] is True
    original = first['image']['rotationHundredths']
    rotation = (original + 9000) % 36000
    request = {'op': 'imageRotate', 'id': first['id'],
               'expectedRotationHundredths': original, 'rotationHundredths': rotation}
    result = apply(runtime, source, output, 'rotated', [request])
    edited = result['snapshot']['slides'][0]['shapes']
    assert edited[0]['image']['rotationHundredths'] == rotation, edited[0]['image']
    assert edited[1] == second and edited[2:] == plain[2:], 'Unselected slide objects changed'
    baseline_path, edited_path = Path(baseline['sourcePath']), Path(result['sourcePath'])
    assert package_photos(edited_path) == package_photos(baseline_path)
    assert transforms(baseline_path)[0] == original * 600
    assert transforms(edited_path) == [rotation * 600, *transforms(baseline_path)[1:]]
    before, after = picture_geometry(baseline_path, 0), picture_geometry(edited_path, 0)
    assert all(before[key] == after[key] for key in ('width', 'height'))
    assert all(abs(before[key] - after[key]) <= 360 for key in ('x', 'y')), (before, after)
    assert result['pdfPageCount'] == 1
    pdf = worker.PdfReader(result['pdfPath'])
    assert 'Untouched caption' in pdf.pages[0].extract_text()

    invalid = {
        'stale-angle': (dict(request, expectedRotationHundredths=(original - 9000) % 36000),
                        'rotation changed since inspection'),
        'non-photo': (dict(request, id=plain[2]['id']), 'photo cannot be rotated'),
        'not-quarter-turn': (dict(request, rotationHundredths=(original + 1) % 36000),
                             'nonzero quarter turn'),
    }
    for name, (operation, expected) in invalid.items():
        try:
            apply(runtime, source, output, name, [operation])
        except ValueError as error:
            assert expected in str(error), error
        else:
            raise AssertionError(f'Unsafe photo rotation was accepted: {name}')
        assert not (output / name / 'edited.pptx').exists()
    assert worker.digest(source) == source_hash
    report = {'passed': True, 'sourceSha256': source_hash, 'from': original, 'to': rotation,
              'serializedRotation': transforms(edited_path), 'geometryBefore': before,
              'geometryAfter': after, 'pdfPages': result['pdfPageCount'],
              'rejected': list(invalid), 'originalPreserved': True,
              'baseline': str(baseline_path), 'rotated': str(edited_path), 'pdf': result['pdfPath']}
    with (output / 'result.json').open('x', encoding='utf-8') as stream:
        json.dump(report, stream, indent=2)
    print(json.dumps(report))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    for option in ('runtime', 'source', 'output'):
        parser.add_argument('--' + option, required=True, type=Path)
    args = parser.parse_args()
    run(args.runtime.resolve(), args.source.resolve(), args.output.resolve())
