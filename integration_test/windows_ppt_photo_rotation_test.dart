import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:saber/data/office/office_document_store.dart';
import 'package:saber/main.dart' as app;
import 'package:saber/pages/office/office_original_preview.dart';
import 'package:saber/pages/office/office_workspace.dart';
import 'package:saber/pages/office/windows_office_editor.dart';
import 'package:saber/pages/workspace/library_home.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:xml/xml.dart';

const _title = '사진 회전 시험';
const _fixtureSha =
    '50988c68b12cf0d90a5d1d19c53381f952e47ee121abed65af317f0671731108';
const _officeTimeout = Duration(seconds: 90);
final _library = find.byType(LibraryHome);
final _workspace = find.byType(OfficeWorkspace);
final _editor = find.byType(WindowsOfficeEditor);
final _edit = find.byKey(const ValueKey('office-edit-structured'));
final _angle = find.byKey(const ValueKey('office-image-rotation-angle'));

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Windows PPT photo rotation saves and reopens a real edition', (
    tester,
  ) async {
    final run = await _OwnedRun.load();
    final created = run.phase == 'create'
        ? null
        : jsonDecode(await run.created.readAsString()) as Map<String, dynamic>;
    if (created != null) {
      expect(created['phase'], 'create');
      expect(created['pid'], isA<int>());
      expect(created['pid'], isNot(pid));
      expect(created['profile'], run.profile.path);
      expect(created['workerSha256'], run.workerSha);
      expect(created['fixtureSha256'], _fixtureSha);
    }
    final originalPaths = PathProviderPlatform.instance;
    final originalPreferences = SharedPreferencesStorePlatform.instance;
    final originalPicker = FilePickerPlatform.instance;
    const legacyStorage = MethodChannel(
      'plugins.it_nomads.com/flutter_secure_storage',
    );
    final messenger = tester.binding.defaultBinaryMessenger;
    addTearDown(() {
      PathProviderPlatform.instance = originalPaths;
      SharedPreferencesStorePlatform.instance = originalPreferences;
      FilePickerPlatform.instance = originalPicker;
      messenger.setMockMethodCallHandler(legacyStorage, null);
    });
    PathProviderPlatform.instance = _RejectDefaultPaths();
    SharedPreferencesStorePlatform.instance = _RejectDefaultPreferences();
    messenger.setMockMethodCallHandler(
      legacyStorage,
      (_) async => throw StateError('Unexpected legacy secure storage access'),
    );
    final picker = _FixturePicker(run.fixture);
    FilePickerPlatform.instance = picker;

    final flow = _Flow(tester);
    await app.main(['--profile-directory', run.profile.path, '--verbose']);
    await flow.wait('workspace startup', () => _library.evaluate().length == 1);

    if (created == null) {
      await flow.tap(
        find.byKey(const ValueKey('library-create-button')),
        'open create menu',
      );
      await flow.tap(find.text('Office·한글 가져오기').last, 'import PPTX');
    } else {
      final library = tester.widget<LibraryHome>(_library);
      final note = library.notes.singleWhere((note) => note.title == _title);
      await flow.tap(
        find.descendant(
          of: find.byKey(ValueKey('library-note-${note.revision.revisionId}')),
          matching: find.text(_title),
        ),
        'open saved PPTX from the library',
      );
    }
    await flow.wait(
      'PPTX workspace ready',
      () => _workspace.evaluate().length == 1 && flow.enabled(_edit),
    );
    final workspace = tester.widget<OfficeWorkspace>(_workspace);
    expect(workspace.note.title, _title);
    expect(picker.requests, created == null ? 1 : 0);
    final store = OfficeDocumentStore(workspace.repository);
    final current = await store.readLatest(workspace.note);

    final OfficeEdition edited;
    final OfficeEdition original;
    if (created == null) {
      original = current;
      expect(original.originalSha256, _fixtureSha);
      expect(original.pdfBytes, isNull);
      await flow.openAndSelectPhoto(original, 34800);
      final rotate = find.byKey(const ValueKey('office-image-rotate-right'));
      await flow.wait(
        'rotation enabled',
        () =>
            rotate.evaluate().length == 1 &&
            tester.widget<IconButton>(rotate).onPressed != null,
      );
      await flow.tap(rotate, 'rotate clockwise 90 degrees');
      await flow.wait(
        'draft shows 78 degrees',
        () =>
            _angle.evaluate().length == 1 &&
            tester.widget<Text>(_angle).data == '회전 78°',
      );
      final save = find.descendant(
        of: _editor,
        matching: find.widgetWithText(FilledButton, '저장하고 닫기'),
      );
      await flow.wait('save enabled', () => flow.enabled(save));
      await flow.tap(save, 'save and close editor');
      await flow.wait(
        'editor saved and closed',
        () => _editor.evaluate().isEmpty && _workspace.evaluate().length == 1,
      );
      edited = await store.readLatest(workspace.note);
    } else {
      edited = current;
      original = await store.readLatest(
        workspace.note,
        revisionId: created['initialRevision'] as String,
      );
    }

    final originalPictures = _pictureAngles(original.originalBytes);
    expect(originalPictures, hasLength(2));
    expect(originalPictures.first, 34800 * 600);
    final rotatedPictures = _pictureAngles(edited.originalBytes);
    expect(rotatedPictures, [7800 * 600, originalPictures.last]);
    expect(edited.revision.revisionId, isNot(original.revision.revisionId));
    expect(edited.revision.parentRevisionIds, [original.revision.revisionId]);
    expect(_digest(edited.originalBytes), edited.originalSha256);
    expect(edited.originalSha256, isNot(_fixtureSha));
    expect(edited.engineVersion, contains('LibreOffice'));
    expect(edited.pageCount, 1);
    final retained = await store.readLatest(
      workspace.note,
      revisionId: original.revision.revisionId,
    );
    expect(retained.originalSha256, _fixtureSha);
    expect(_digest(retained.originalBytes), _fixtureSha);
    expect(_digest(await run.fixture.readAsBytes()), _fixtureSha);
    expect(retained.pdfBytes, isNull);
    await flow.expectRenderedPdf(edited);

    if (created != null) {
      expect(workspace.note.id, created['noteId']);
      expect(edited.revision.revisionId, created['editedRevision']);
      expect(edited.originalSha256, created['editedSha256']);
      expect(edited.pdfSha256, created['pdfSha256']);
      await flow.openAndSelectPhoto(edited, 7800);
      await flow.tap(
        find.byWidgetPredicate(
          (widget) => widget is IconButton && widget.tooltip == '문서로 돌아가기',
        ),
        'close reopened editor',
      );
      await flow.wait(
        'reopened editor closed',
        () => _editor.evaluate().isEmpty && _workspace.evaluate().length == 1,
      );
      expect(
        (await store.readLatest(workspace.note)).revision.revisionId,
        edited.revision.revisionId,
      );
    }
    final backToLibrary = find.byWidgetPredicate(
      (widget) => widget is IconButton && widget.tooltip == '문서 목록으로',
    );
    await flow.wait(
      'back to library enabled',
      () =>
          backToLibrary.evaluate().length == 1 &&
          tester.widget<IconButton>(backToLibrary).onPressed != null,
    );
    await flow.tap(backToLibrary, 'return to the library');
    await flow.wait(
      'saved PPTX in library',
      () =>
          _library.evaluate().length == 1 &&
          tester
              .widget<LibraryHome>(_library)
              .notes
              .any((note) => note.id == workspace.note.id),
    );
    final proof = run.proof;
    await proof.create(exclusive: true);
    await proof.writeAsString(
      jsonEncode({
        'phase': run.phase,
        'pid': pid,
        'executable': Platform.resolvedExecutable,
        'profile': run.profile.path,
        'workerSha256': run.workerSha,
        'fixtureSha256': _fixtureSha,
        'noteId': workspace.note.id,
        'initialRevision': original.revision.revisionId,
        'editedRevision': edited.revision.revisionId,
        'editedSha256': edited.originalSha256,
        'pdfSha256': edited.pdfSha256,
        'drawingMlAngles': rotatedPictures,
        'pdfPages': edited.pageCount,
        'nativeInspectedAngle': created == null ? 34800 : 7800,
      }),
      flush: true,
    );
  }, timeout: const Timeout(Duration(minutes: 8)));
}

String _digest(List<int> bytes) => sha256.convert(bytes).toString();

List<int> _pictureAngles(Uint8List bytes) {
  final archive = ZipDecoder().decodeBytes(bytes, verify: true);
  try {
    final slide = archive.findFile('ppt/slides/slide1.xml')!;
    final document = XmlDocument.parse(utf8.decode(slide.content));
    return [
      for (final picture in document.descendantElements.where(
        (e) => e.name.local == 'pic',
      ))
        int.parse(
          picture.descendantElements
                  .singleWhere((e) => e.name.local == 'xfrm')
                  .getAttribute('rot') ??
              '0',
        ),
    ];
  } finally {
    archive.clearSync();
  }
}

final class _Flow {
  new(this.tester);

  final WidgetTester tester;

  Future<void> wait(String step, bool Function() done) async {
    final timer = Stopwatch()..start();
    while (true) {
      await tester.pump(const Duration(milliseconds: 50));
      final error = tester.takeException();
      if (error != null) throw StateError('$step: $error');
      if (done()) return;
      if (timer.elapsed >= _officeTimeout) {
        throw StateError('$step timed out after $_officeTimeout');
      }
    }
  }

  bool enabled(Finder button) =>
      button.evaluate().length == 1 &&
      tester.widget<ButtonStyleButton>(button).onPressed != null;

  Future<void> tap(Finder finder, String step) async {
    await wait(step, () => finder.evaluate().length == 1);
    await tester.ensureVisible(finder);
    await wait(
      '$step is tappable',
      () => finder.hitTestable().evaluate().length == 1,
    );
    await tester.tap(finder);
  }

  Future<void> openAndSelectPhoto(OfficeEdition edition, int rotation) async {
    await wait('structured editor entry enabled', () => enabled(_edit));
    await tap(_edit, 'open actual structured editor');
    await wait(
      'native PPT inspection complete',
      () => _editor.evaluate().length == 1,
    );
    final snapshot = tester.widget<WindowsOfficeEditor>(_editor).snapshot;
    expect(snapshot.sourceSha256, edition.originalSha256);
    expect(snapshot.kind, 'presentation');
    final photos = snapshot.slides.single.shapes.where(
      (shape) => shape.shapeKind == 'image',
    );
    expect(photos, hasLength(2));
    final photo = photos.first;
    expect(photo.image?.canRotate, isTrue);
    expect(photo.image?.rotationHundredths, rotation);
    await tap(
      find.byWidgetPredicate(
        (widget) =>
            widget is GestureDetector &&
            widget.key == ValueKey('office-shape-${photo.id}'),
      ),
      'select the first photo',
    );
    await wait('photo angle visible', () => _angle.evaluate().length == 1);
    expect(tester.widget<Text>(_angle).data, '회전 ${rotation ~/ 100}°');
  }

  Future<void> expectRenderedPdf(OfficeEdition edition) async {
    final bytes = edition.pdfBytes!;
    expect(ascii.decode(bytes.sublist(0, 5)), '%PDF-');
    expect(_digest(bytes), edition.pdfSha256);
    final preview = find.descendant(
      of: _workspace,
      matching: find.byType(OfficeOriginalPreview),
    );
    await wait(
      'saved PDF preview mounted',
      () => preview.evaluate().length == 1,
    );
    await tester.ensureVisible(preview);
    final page = find.descendant(
      of: preview,
      matching: find.byType(PdfPageView),
    );
    final raster = find.descendant(of: page, matching: find.byType(RawImage));
    await wait(
      'saved PDF page rendered',
      () =>
          raster.evaluate().length == 1 &&
          tester.widget<RawImage>(raster).image != null,
    );
    expect(tester.widget<OfficeOriginalPreview>(preview).pdfBytes, bytes);
    expect(tester.widget<PdfPageView>(page).document!.pages.length, 1);
  }
}

final class _OwnedRun {
  new(this.stage, this.profile, this.fixture, this.phase, this.workerSha);

  final Directory stage, profile;
  final File fixture;
  final String phase, workerSha;
  File get created => File(path.join(stage.path, 'create-completed.json'));
  File get proof => File(path.join(stage.path, '$phase-completed.json'));

  static Future<_OwnedRun> load() async {
    const ownerPath = String.fromEnvironment('PIV_PPT_ROTATION_OWNER');
    const ownerSha = String.fromEnvironment('PIV_PPT_ROTATION_OWNER_SHA');
    final owner = File(ownerPath);
    final stage = owner.parent;
    if (!Platform.isWindows ||
        !path.isAbsolute(ownerPath) ||
        !RegExp(r'^pr1-[0-9a-f]{16}$').hasMatch(path.basename(stage.path)) ||
        !path.equals(stage.parent.path, r'E:\CodexBuilds\personal-ink-vault') ||
        !path.equals(await stage.resolveSymbolicLinks(), stage.path) ||
        !path.equals(await owner.resolveSymbolicLinks(), owner.path)) {
      throw StateError('Use an owned Windows PPT rotation stage');
    }
    final data = await owner.readAsBytes();
    if (_digest(data) != ownerSha)
      throw StateError('Owned test receipt changed');
    final receipt = jsonDecode(utf8.decode(data)) as Map<String, dynamic>;
    final phase = receipt['phase'];
    final workerSha = receipt['workerSha256'];
    if (receipt['schemaVersion'] != 1 ||
        receipt['purpose'] != 'windows-ppt-photo-rotation' ||
        (phase != 'create' && phase != 'reopen') ||
        workerSha is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(workerSha)) {
      throw StateError('Unexpected PPT rotation receipt');
    }
    final profile = Directory(path.join(stage.path, 'p'));
    final fixture = File(path.join(stage.path, 'fixture.pptx'));
    final run = _OwnedRun(stage, profile, fixture, phase as String, workerSha);
    if (!path.equals(await profile.resolveSymbolicLinks(), profile.path) ||
        !path.equals(await fixture.resolveSymbolicLinks(), fixture.path) ||
        _digest(await fixture.readAsBytes()) != _fixtureSha ||
        FileSystemEntity.typeSync(run.proof.path, followLinks: false) !=
            FileSystemEntityType.notFound ||
        (phase == 'create' && !await profile.list().isEmpty) ||
        (phase == 'reopen' &&
            FileSystemEntity.typeSync(run.created.path, followLinks: false) !=
                FileSystemEntityType.file)) {
      throw StateError('Unexpected fixture, test profile or phase evidence');
    }
    final office = path.join(
      path.dirname(Platform.resolvedExecutable),
      'office_engine',
    );
    final worker = File(path.join(office, 'office_worker.py'));
    if (_digest(await worker.readAsBytes()) != workerSha ||
        !File(path.join(office, 'run-office.ps1')).existsSync() ||
        !File(path.join(office, 'runtime', 'program', 'python.exe'))
            .existsSync()) {
      throw StateError(
        'The Windows runner must use the bound bundled Office worker',
      );
    }
    return run;
  }
}

final class _FixturePicker extends FilePickerPlatform {
  new(this.fixture);
  final File fixture;
  var requests = 0;

  @override
  Future<PlatformFile?> pickFile({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    requests++;
    expect(requests, 1);
    expect(type, FileType.custom);
    expect(allowedExtensions, contains('pptx'));
    return _PickedFile(fixture);
  }
}

final class _PickedFile extends PlatformFile {
  new(this.file);
  final File file;

  @override
  String get name => '$_title.pptx';

  @override
  Future<Uint8List> readAsBytes() => file.readAsBytes();

  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError(
    'Unexpected picker result access: ${invocation.memberName}',
  );
}

final class _RejectDefaultPaths extends PathProviderPlatform {
  Never _reject() => throw StateError('App requested a default user directory');

  @override
  Future<String?> getApplicationSupportPath() async => _reject();
  @override
  Future<String?> getApplicationDocumentsPath() async => _reject();
  @override
  Future<String?> getApplicationCachePath() async => _reject();
  @override
  Future<String?> getDownloadsPath() async => _reject();
  @override
  Future<String?> getTemporaryPath() async => _reject();
}

final class _RejectDefaultPreferences extends SharedPreferencesStorePlatform {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError(
    'App requested default preferences: ${invocation.memberName}',
  );
}
