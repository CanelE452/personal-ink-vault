"""Root-run real UNO failures with explicit, bounded in-memory fault injection.

The worker function and on-disk products stay unchanged. Each fault delegates
real native work, confirms its own trigger/readback, and requires the identified
ValueError guard plus owned output and native handle cleanup.
"""
import argparse
from contextlib import contextmanager, ExitStack
from pathlib import Path
import sys
import time
import traceback

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
import office_worker as worker
import test_word_image_mutations_native as positive


CASES = ('post-setter', 'inventory-delta', 'source-metadata', 'reopen-metadata')
MESSAGES = {
    'post-setter': 'Injected identified failure after the real finite native setter batch',
    'inventory-delta': 'Insertion did not preserve every source and exactly one actual new image',
    'source-metadata': 'Word source image native values, states or metadata changed during editing',
    'reopen-metadata': 'Saved Word image native values, states or metadata changed',
}


@contextmanager
def replace(target, name, value):
    original = getattr(target, name)
    setattr(target, name, value)
    try:
        yield
    finally:
        setattr(target, name, original)


def tracked_server_class(original, report):
    class TrackedServer(original):
        def __enter__(self):
            self.observation = {'directory': str(self.directory), 'entered': False,
                'exitCompleted': False, 'ownedLoaderHandleClosed': False, 'ownedJobHandleClosed': False}
            report['workerServers'].append(self.observation)
            try:
                result = super().__enter__()
                self.observation['entered'] = True
                return result
            finally:
                observe(self)

        def __exit__(self, *arguments):
            self.observation['exitExceptionType'] = None if arguments[0] is None else arguments[0].__name__
            try:
                result = super().__exit__(*arguments)
                self.observation['exitCompleted'] = True
                return result
            finally:
                observe(self)

    def observe(server):
        process = getattr(server, 'process', None)
        server.observation['ownedLoaderHandleClosed'] = process is not None and process.process is None
        server.observation['ownedJobHandleClosed'] = process is not None and process.job is None
        profile = getattr(server, 'profile', None)
        server.observation['profile'] = None if profile is None else str(profile)
        server.observation['ownedProfileRemoved'] = profile is not None and not profile.exists()
    return TrackedServer


def add_second_actual(catalog, first, event):
    document = catalog.word.document
    candidates = [paragraph for paragraph in catalog.word.body.paragraphs.values()
        if paragraph.String.replace('\ufffc', '') == positive.LABELS[5]]
    positive.require(len(candidates) == 1, 'The second real insertion needs its exact other body paragraph')
    paragraph = candidates[0]
    offset = worker.office_text.utf16_length(paragraph.String.split('|')[0])
    point, _, _, _ = worker.office_text.selection(paragraph,
        {'startUtf16': offset, 'endUtf16': offset,
            'expectedTextSha256': worker.office_text.text_hash(paragraph.String)},
        paragraph=True, scalar_cursor=True, replacing=True)
    descriptor = document.createInstance('com.sun.star.text.TextGraphicObject')
    for name in ('Graphic', 'AnchorType', 'Width', 'Height', 'LeftMargin', 'RightMargin', 'TopMargin', 'BottomMargin'):
        descriptor.setPropertyValue(name, first.getPropertyValue(name))
    before = len(catalog.current())
    document.Text.insertTextContent(point, descriptor, False)
    after = len(catalog.current())
    positive.require(after == before + 1, 'The injected second native image was not actually inserted')
    event.update(secondInsertionBeforeCount=before, secondInsertionAfterCount=after,
        secondInsertionParagraph=paragraph.String, secondInsertionOffsetUtf16=offset,
        realNativeChangeReadBack=True, faultTriggered=True)


def run_case(runtime, output, source, initial, assets, asset_root, case, report):
    import office_word_image_mutations as mutations
    from office_word_layout import WordDocument
    source_hash = worker.digest(source)
    directory = output / ('failed-' + case)
    operation = positive.target(initial, positive.LABELS[1], identifier='fault-photo-' + case)
    request = {'mode': 'apply', 'sourcePath': str(source), 'sessionId': 'fault-' + case,
        'expectedSourceSha256': source_hash, 'operations': [operation], 'imageAssets': assets}
    event = {'case': case, 'faultTriggered': False, 'callbacks': [],
        'realNativeChangeReadBack': False, 'expectedValueError': MESSAGES[case],
        'directory': str(directory), 'sourceSha256Before': source_hash,
        'inMemoryFaultInjection': True}
    report['faultCases'].append(event)
    original_materialize, original_added = mutations.materialize_new, mutations.actual_added
    original_reopened = WordDocument.verify_reopened
    original_server, original_run_request = worker.OfficeServer, worker.run_request

    def materialized(catalog, image, before):
        event['callbacks'].append('materialize_new:delegate-real-native-batch')
        original_materialize(catalog, image, before)
        raw = mutations.raw_image_state(image)
        positive.require(all(raw[name]['state'][-1] == 'DIRECT_VALUE' for name in mutations.NEW_DEFAULT_FIELDS),
            'The real finite setter batch did not finish before the injected failure')
        event['materializedActualNewRawState'] = raw
        event['realNativeChangeReadBack'] = True
        if case == 'post-setter':
            event['faultTriggered'] = True
            raise ValueError(MESSAGES[case])
        positive.require(case == 'source-metadata' and len(catalog.source_bindings) == 3,
            'The source metadata fault requires three verified original native Frames')
        source_image = catalog.source_bindings[0]['image']
        prior = source_image.getPropertyValue('Title')
        changed = 'FAULT: unapproved actual source Title'
        positive.require(prior != changed, 'The source metadata fault value must differ')
        source_image.setPropertyValue('Title', changed)
        actual = source_image.getPropertyValue('Title')
        positive.require(actual == changed, 'The actual source Title fault did not read back')
        event.update(sourceTitleBefore=prior, sourceTitleAfter=actual,
            sourceAnchorStillInActualBody=source_image.getAnchor().getText() == catalog.word.body.text,
            faultTriggered=True)

    def added(catalog, before):
        event['callbacks'].append('actual_added:delegate-real-native-delta-guard')
        first = original_added(catalog, before)
        if event['faultTriggered']:
            return first
        event['firstActualImageRawState'] = mutations.raw_image_state(first)
        add_second_actual(catalog, first, event)
        event['callbacks'].append('actual_added:delegate-original-guard-after-second-real-insertion')
        return original_added(catalog, before)

    def reopened(word, expected):
        event['callbacks'].append('verify_reopened:actual-saved-document-opened')
        if event['faultTriggered']:
            return original_reopened(word, expected)
        edited = directory / 'edited.docx'
        positive.require(edited.is_file() and edited.stat().st_size > 0,
            'The reopened metadata fault must run after an actual saved source exists')
        positive.require(isinstance(expected, dict) and set(expected) == {'semantic', 'imageRawStates'}
            and len(expected['imageRawStates']) == 4,
            'The real saved reopen must receive the exact four-image raw preservation envelope')
        word.verification_state()
        positive.require(len(word.export_bindings) == 4, 'The actual reopened DOCX must contain all four native Frames')
        image = word.export_bindings[0]['image']
        prior = image.getPropertyValue('Title')
        changed = 'FAULT: metadata changed only on actual saved reopen'
        image.setPropertyValue('Title', changed)
        readback = image.getPropertyValue('Title')
        positive.require(prior != changed and readback == changed,
            'The actual reopened native Title fault did not read back')
        event.update(savedEditedExistedBeforeFault=True, savedEditedSha256BeforeFault=worker.digest(edited),
            reopenedTitleBefore=prior, reopenedTitleAfter=readback,
            realNativeChangeReadBack=True, faultTriggered=True)
        event['callbacks'].append('verify_reopened:delegate-original-raw-guard')
        return original_reopened(word, expected)

    with ExitStack() as patches:
        patches.enter_context(replace(worker, 'OfficeServer', tracked_server_class(original_server, report)))
        if case in ('post-setter', 'source-metadata'):
            patches.enter_context(replace(mutations, 'materialize_new', materialized))
        elif case == 'inventory-delta':
            patches.enter_context(replace(mutations, 'actual_added', added))
        else:
            patches.enter_context(replace(WordDocument, 'verify_reopened', reopened))
        try:
            worker.run_request(runtime, request, directory, asset_root=asset_root)
        except ValueError as error:
            event['observedValueError'] = str(error)
            positive.require(event['faultTriggered'] and event['realNativeChangeReadBack'],
                'A baseline unsupported path must not count as the requested native fault rejection')
            positive.require(str(error) == MESSAGES[case], 'An unrelated ValueError must not count as the identified guard')
        else:
            raise AssertionError('The worker accepted the actual native fault: ' + case)
    positive.require(worker.run_request is original_run_request and worker.OfficeServer is original_server
        and mutations.materialize_new is original_materialize and mutations.actual_added is original_added
        and WordDocument.verify_reopened is original_reopened,
        'An in-memory test hook was not restored')
    positive.require(not (directory / 'edited.docx').exists() and not (directory / 'preview.pdf').exists(),
        'The failed native worker left a saved source or PDF result')
    positive.require(worker.digest(source) == source_hash, 'A rejected native mutation changed its immutable source')
    event.update(privateEditedAbsent=True, privatePdfAbsent=True, hooksRestored=True,
        sourceSha256After=worker.digest(source), passed=True)
    positive.dump(output / (case + '-fault.json'), event)


def run(runtime, output, selected):
    output.mkdir(parents=True, exist_ok=False)
    started = time.monotonic()
    cases = CASES if selected == 'all' else (selected,)
    report = {'completed': False, 'case': selected, 'faultCases': [], 'independentServers': [],
        'workerServers': [], 'checks': {}, 'inMemoryFaultInjection': True,
        'scope': 'Real UNO mutations followed by explicit in-memory faults. Product files and run_request remain unchanged.'}
    product = sorted(Path(worker.__file__).parent.glob('office_*.py'))
    product.extend([Path(worker.__file__).with_name('process_ownership.py'), Path(__file__).resolve(),
        Path(positive.__file__).resolve(), Path(worker.__file__).with_name('test_images_native.py'),
        Path(worker.__file__).with_name('test_rich_native.py')])
    product.extend(runtime / 'program' / name for name in
        ('soffice.com', 'soffice.bin', 'python.exe', 'pyuno.pyd', 'mergedlo.dll', 'swlo.dll', 'mswordlo.dll', 'version.ini'))
    product = [path for path in product if path.is_file()]
    report['sourceHashesBefore'] = {str(path): worker.digest(path) for path in product}
    fixture_files = []
    try:
        worker.initialize(runtime)
        png = output / 'photo.png'
        png.write_bytes(positive.fixture_png())
        source = positive.canonical_fixture(runtime, output, png, 3, report)
        asset_root = output / 'request-assets'
        assets = [positive.stage(asset_root, positive.ASSET_ID, png, 'image/png', 2, 2)]
        fixture_files = [png, source, output / 'raw.docx', *(asset_root / 'assets').iterdir()]
        report['fixtureHashesBefore'] = {str(path): worker.digest(path) for path in fixture_files}
        initial = positive.inspect(runtime, source, output, 'inspect-source')
        positive.require(len(initial['wordImages']) == 3, 'Every failure requires its real canonical three-image source')
        positive.require_photo_capabilities(initial['wordImages'])
        baseline = positive.independent(runtime, source, output, 'baseline-independent', report)
        positive.require(len(baseline['photos']) == 3, 'The canonical source needs three independently bound actual Frames')
        positive.dump(output / 'baseline-independent-state.json', baseline)
        for case in cases:
            run_case(runtime, output, source, initial, assets, asset_root, case, report)
        report['fixtureHashesAfter'] = {str(path): worker.digest(path) for path in fixture_files}
        positive.require(report['fixtureHashesBefore'] == report['fixtureHashesAfter'], 'A fixture source or sealed asset changed')
        positive.require(len(report['workerServers']) == len(cases), 'Each fault must use exactly one distinct owned worker server')
        positive.require(all(row['entered'] and row['exitCompleted'] and row['ownedLoaderHandleClosed']
            and row['ownedJobHandleClosed'] for row in report['workerServers']), 'A failed worker left an owned native handle open')
        positive.require(all(row['exitCompleted'] and row['ownedLoaderHandleClosed'] and row['ownedJobHandleClosed']
            for row in report['independentServers']), 'A fixture or independent server left an owned native handle open')
        report['sourceHashesAfter'] = {str(path): worker.digest(path) for path in product}
        positive.require(report['sourceHashesBefore'] == report['sourceHashesAfter'], 'A frozen product/runtime/helper changed')
        report.update(completed=True, integrityConfirmed=True,
            allRequestedFaultsTriggeredAndRejected=True, allPrivateSavedOutputsRemoved=True)
    except BaseException as error:
        report['error'] = {'type': type(error).__name__, 'message': str(error), 'traceback': traceback.format_exc()}
        raise
    finally:
        report['elapsedSeconds'] = time.monotonic() - started
        report['ownedWorkerHandlesClosed'] = bool(report['workerServers']) and all(
            row['exitCompleted'] and row['ownedLoaderHandleClosed'] and row['ownedJobHandleClosed']
            for row in report['workerServers'])
        report['ownedIndependentHandlesClosed'] = bool(report['independentServers']) and all(
            row['exitCompleted'] and row['ownedLoaderHandleClosed'] and row['ownedJobHandleClosed']
            for row in report['independentServers'])
        positive.dump(output / 'result.json', report)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--runtime', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--case', choices=('all', *CASES), default='all')
    arguments = parser.parse_args()
    run(arguments.runtime.resolve(), arguments.output.resolve(), arguments.case)
