"""Verify native preset shapes through the installed Windows Office worker."""
import argparse
import json
from pathlib import Path
from unittest.mock import patch
import xml.etree.ElementTree as ET
import zipfile

import office_worker as worker
from test_shapes_native import create_source


P = '{http://schemas.openxmlformats.org/presentationml/2006/main}'
A = '{http://schemas.openxmlformats.org/drawingml/2006/main}'
CASES = {
    'roundedRectangle': ('roundRect', 'Rounded & editable'),
    'rightArrow': ('rightArrow', 'A<B'),
}


def find_shape(snapshot, slide, text):
    return next(shape for shape in snapshot['slides'][slide]['shapes'] if shape['text'] == text)


def check_preset(path, label, preset):
    with zipfile.ZipFile(path) as package:
        found = []
        for name in package.namelist():
            if not name.startswith('ppt/slides/slide') or not name.endswith('.xml'):
                continue
            slide = ET.fromstring(package.read(name))
            for shape in slide.findall(f'./{P}cSld/{P}spTree/{P}sp'):
                body = shape.find(P + 'txBody')
                if body is None or ''.join(node.text or '' for node in body.iter(A + 't')) != label:
                    continue
                geometry = shape.find(f'./{P}spPr/{A}prstGeom')
                assert geometry is not None and geometry.get('prst') == preset
                nonvisual = shape.find(f'./{P}nvSpPr/{P}cNvSpPr')
                assert nonvisual.get('txBox') not in ('1', 'true')
                found.append(name)
        assert len(found) == 1, (label, found)


def request(runtime, output, source, source_hash, operations):
    return worker.run_request(runtime, {
        'mode': 'apply', 'sourcePath': str(source), 'sessionId': output.name,
        'expectedSourceSha256': source_hash, 'operations': operations,
        'includeDraftSnapshot': True,
    }, output)


def add_shape(identifier, owner, kind):
    return {'op': 'shapeAdd', 'id': identifier, 'slideId': owner, 'shapeKind': kind,
            'x': 20, 'y': 80, 'width': 66, 'height': 31}


def edits(identifier, label):
    return [
        {'op': 'shapeText', 'id': identifier, 'text': label},
        {'op': 'shapeGeometry', 'id': identifier, 'x': 88, 'y': 57, 'width': 83, 'height': 26},
        {'op': 'shapeAppearance', 'id': identifier, 'fillStyle': 'solid', 'fillColor': 0x123456,
         'lineStyle': 'solid', 'lineColor': 0xABCD01, 'lineWidth': .75},
    ]


def check_shape(shape, kind):
    assert shape['shapeKind'] == kind, shape
    assert all(shape[name] for name in ('editableText', 'canEditGeometry', 'canEditFill', 'canEditLine'))
    assert all(abs(shape[name] - expected) <= .02 for name, expected in
               [('x', 88), ('y', 57), ('width', 83), ('height', 26), ('lineWidth', .75)])
    assert (shape['fillColor'], shape['lineColor']) == (0x123456, 0xABCD01)


def check_output(result, source, expected_hash, pages):
    assert result['status'] == 'saved' and result['pdfPageCount'] == pages
    assert worker.digest(source) == expected_hash
    assert worker.digest(Path(result['sourcePath'])) == result['sourceSha256']
    assert worker.digest(Path(result['pdfPath'])) == result['pdfSha256']
    assert Path(result['pdfPath']).read_bytes().startswith(b'%PDF-')


def run(runtime, output, android_sources):
    worker.initialize(runtime)
    output.mkdir(parents=True, exist_ok=False)
    evidence = {'imported': [], 'created': [], 'masterRejected': []}
    for (kind, (preset, source_label)), source in zip(CASES.items(), android_sources, strict=True):
        source_hash = worker.digest(source)
        original = worker.run_request(runtime, {'mode': 'inspect', 'sourcePath': str(source)}, output / ('inspect-' + kind))
        shape = find_shape(original['snapshot'], 1, source_label)
        assert shape['shapeKind'] == kind, (kind, shape['shapeKind'])
        label = 'Windows edit ' + kind
        result = request(runtime, output / ('edit-' + kind), source, source_hash, edits(shape['id'], label))
        check_output(result, source, source_hash, 3)
        check_shape(find_shape(result['snapshot'], 1, label), kind)
        check_preset(Path(result['sourcePath']), label, preset)
        evidence['imported'].append({'kind': kind, 'sourceSha256': source_hash, 'output': result})

    fixture_dir = output / 'fixture'
    fixture_dir.mkdir()
    source, _, _ = create_source(runtime, fixture_dir)
    source_hash = worker.digest(source)
    operations = []
    for kind in CASES:
        operations += [add_shape('new-' + kind, 'slide-0', kind), *edits('new-' + kind, 'Windows new ' + kind)]
    operations += [add_shape('temporary', 'slide-0', 'rightArrow'), {'op': 'shapeDelete', 'id': 'temporary'}]
    operations.append({'op': 'slideMove', 'id': 'slide-0', 'index': 1})
    result = request(runtime, output / 'created', source, source_hash, operations)
    check_output(result, source, source_hash, 2)
    for kind, (preset, _) in CASES.items():
        label = 'Windows new ' + kind
        draft = find_shape(result['draftSnapshot'], 1, label)
        assert draft['id'] == 'new-' + kind
        check_shape(draft, kind)
        check_shape(find_shape(result['snapshot'], 1, label), kind)
        check_preset(Path(result['sourcePath']), label, preset)
        evidence['created'].append(kind)
        rejected = output / ('reject-master-' + kind)
        try:
            request(runtime, rejected, source, source_hash, [add_shape('master-preset', 'master-0', kind)])
        except ValueError as error:
            assert 'slide' in str(error).lower(), str(error)
        else:
            raise AssertionError('Preset shape accepted on a master: ' + kind)
        assert not (rejected / 'edited.pptx').exists() and not (rejected / 'preview.pdf').exists()
        evidence['masterRejected'].append(kind)

    rejected = output / 'reject-reopen'
    snapshot = worker.snapshot

    def missing_reopened_preset(*args, **kwargs):
        actual = snapshot(*args, **kwargs)
        if kwargs.get('source_path') == rejected / 'edited.pptx':
            find_shape(actual, 0, 'Readback failure fixture')['shapeKind'] = None
        return actual

    operation = add_shape('bad-reopen', 'slide-0', 'rightArrow')
    operation['text'] = 'Readback failure fixture'
    with patch.object(worker, 'snapshot', missing_reopened_preset):
        try:
            request(runtime, rejected, source, source_hash, [operation])
        except ValueError as error:
            assert 'did not retain the requested preset shape' in str(error), str(error)
        else:
            raise AssertionError('Saved presentation accepted a missing preset')
    assert not (rejected / 'edited.pptx').exists() and not (rejected / 'preview.pdf').exists()
    evidence['failedReadbackRemovedOutput'] = True

    assert worker.digest(source) == source_hash
    evidence['creationOutput'] = result
    evidence['completed'] = True
    (output / 'proof.json').write_text(json.dumps(evidence, indent=2, ensure_ascii=False), encoding='utf-8')
    print(json.dumps({'completed': True, 'imported': len(evidence['imported']),
                      'created': len(evidence['created']), 'masterRejected': len(evidence['masterRejected'])}))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--runtime', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--android-round', type=Path, required=True)
    parser.add_argument('--android-arrow', type=Path, required=True)
    args = parser.parse_args()
    run(args.runtime.resolve(strict=True), args.output.resolve(),
        [args.android_round.resolve(strict=True), args.android_arrow.resolve(strict=True)])
