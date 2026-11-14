"""Replay a field-bearing text edit rebased on an actual geometry draft."""
import argparse
import json
from pathlib import Path
import sys
import traceback

sys.path.insert(0, str(Path(__file__).resolve().parent))
import office_worker as worker
from test_word_page_geometry_native import (SOURCE_SHA256, create_reflow, geometry,
    independent_saved, inspect_bindings, request, serializable)
from test_word_structure_native import text_hash


def run(runtime, fixed_source, output):
    output.mkdir(parents=True, exist_ok=False)
    paths = [Path(__file__).with_name(name) for name in ['office_worker.py', 'office_word.py', 'office_word_layout.py', 'office_text.py']]
    factory = worker.OfficeServer
    report = {'passed': False, 'case': 'field-bearing-source-bound-journal-replay', 'requests': [],
        'independentServers': [], 'sourceOriginalSha256': worker.digest(fixed_source),
        'testSha256': worker.digest(Path(__file__)), 'productSourceSha256': {path.name: worker.digest(path) for path in paths},
        'execution': 'Fresh production run_request and owned independent servers; no cache text substitution or server patch',
        'requestLifecycleObservations': None}
    derived = output / 'field-replay-reflow.docx'
    try:
        assert worker.digest(fixed_source) == SOURCE_SHA256
        worker.initialize(runtime)
        request(runtime, fixed_source, output, 'inspect-fixed-source', report)
        create_reflow(fixed_source, derived)
        report['derivedSourceSha256'] = worker.digest(derived)
        initial = request(runtime, derived, output, 'inspect-reflow-source', report)['snapshot']
        bindings = inspect_bindings(runtime, derived, initial, output, 'replay-native-binding', report)
        target = bindings[-1]
        owner = next(row for row in initial['wordOwners'] if row['kind'] == 'header' and any(
            ref['pageStyleId'] == target['id'] and ref['variant'] == 'default' for ref in row['references']))
        paragraph = next(row for row in owner['paragraphs'] if 'NUMPAGES=' in row['text']
            and any(value['type'] == 'TextField' for value in row['textDetails']['protectedRanges']))
        operations = [geometry(target, leftMargin=25.4, rightMargin=127)]
        preview = request(runtime, derived, output, 'geometry-field-preview', report, operations, draft=True)
        live_owner = next(row for row in preview['draftSnapshot']['wordOwners'] if row['id'] == owner['id'])
        live = next(row for row in live_owner['paragraphs'] if row['id'] == paragraph['id'])
        report['cacheObservation'] = {'sourceText': paragraph['text'], 'liveText': live['text'],
            'canonicalPdfPageCount': preview['pdfPageCount'], 'sourceRawFieldCachesWereSix': True}
        assert preview['pdfPageCount'] > 6, 'Fixture needs actual reflow beyond the original explicit six pages'
        assert 'NUMPAGES=' + str(preview['pdfPageCount']) in ''.join(live['text'].split())
        assert live['text'] != paragraph['text'], 'Fixture must exercise an actual field-cache change before rebasing'
        prefix = 'DUPLICATE_OWNER_TEXT'
        assert live['text'].startswith(prefix)
        operations.append({'op': 'textReplace', 'targetKind': 'paragraph', 'id': live['id'],
            'startUtf16': 0, 'endUtf16': len(prefix), 'expectedTextSha256': text_hash(live['text']),
            'text': 'REPLAYED_HEADER'})
        replay = request(runtime, derived, output, 'replay-full-journal', report, operations, draft=True)
        replay_owner = next(row for row in replay['draftSnapshot']['wordOwners'] if row['id'] == owner['id'])
        replay_paragraph = next(row for row in replay_owner['paragraphs'] if row['id'] == live['id'])
        assert replay_paragraph['text'] == 'REPLAYED_HEADER' + live['text'][len(prefix):]
        assert replay_owner['references'] == owner['references']
        assert replay['draftSnapshot']['sourceSha256'] == report['derivedSourceSha256']
        report['independentReopen'] = independent_saved(runtime, replay, output, 'replay-independent-reopen', report)
        assert any('REPLAYED_HEADER' in page['text'] for page in report['independentReopen']['pdf']['pages'])
        report['passed'] = True
    except BaseException:
        report['exception'] = traceback.format_exc()
        raise
    finally:
        report['sourceHashUnchanged'] = worker.digest(fixed_source) == report['sourceOriginalSha256']
        report['testHashUnchanged'] = worker.digest(Path(__file__)) == report['testSha256']
        report['productSourcesUnchanged'] = all(worker.digest(path) == report['productSourceSha256'][path.name] for path in paths)
        report['factoryUnchanged'] = worker.OfficeServer is factory
        report['derivedSourceUnchanged'] = not derived.exists() or worker.digest(derived) == report.get('derivedSourceSha256')
        if not all(report[key] for key in ['sourceHashUnchanged', 'testHashUnchanged', 'productSourcesUnchanged', 'factoryUnchanged', 'derivedSourceUnchanged']):
            report['passed'] = False
        (output / 'result.json').write_text(json.dumps(serializable(report), ensure_ascii=False,
            indent=2, allow_nan=False), encoding='utf-8')
    assert report['passed']
    print(json.dumps({'passed': True, 'case': report['case']}))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--runtime', type=Path, required=True)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    run(args.runtime.resolve(), args.source.resolve(), args.output.resolve())
