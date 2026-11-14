import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:pdf/widgets.dart' as pdf;
import 'package:pdfrx/pdfrx.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/imports/android_document_source.dart';
import 'package:saber/data/vault/thumbnail_cache.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/editor/editor.dart';
import 'package:saber/pages/workspace/study_workspace.dart';

import '../utils/test_mock_channel_handlers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();
  setupMockWindowManager();
  final pdfiumPath = Platform.environment['PIV_PDF_ANCHOR_TEST_PDFIUM'];
  const platforms = TargetPlatformVariant({
    TargetPlatform.android,
    TargetPlatform.windows,
  });

  testWidgets(
    'StarNote imports a PDF to a separate selected vault and opens its canvas',
    (tester) async {
      final pdfBytes =
          await (pdf.Document()
                ..addPage(pdf.Page(build: (context) => pdf.SizedBox())))
              .save();
      const id = 'fe86eca2-b4c7-4d06-a0e9-e93282b7016c';
      final archive = Archive()
        ..addFile(ArchiveFile.string('$id/note/pb/note_info', 'fixture'))
        ..addFile(
          ArchiveFile.bytes('$id/resource/content/Handout.pdf', pdfBytes),
        );
      final file = _PickedFile('Handout.NOTE', ZipEncoder().encode(archive));
      await _withWorkspace(tester, file, (c, support, native) async {
        final previous = c.repository;
        final oldPdfium = Pdfrx.pdfiumModulePath;
        addTearDown(() => Pdfrx.pdfiumModulePath = oldPdfium);
        Pdfrx.pdfiumModulePath = File(pdfiumPath!).absolute.path;
        await _whilePumping(
          tester,
          () => pdfrxInitialize(tmpPath: support.parent.path),
        );
        await _openImport(tester);
        expect(file.streamRead, isFalse);
        if (native != null) expect(native.calls, ['choose']);
        await tester.runAsync(() => tester.tap(find.text('PDF 가져오기')));
        await _waitUntil(tester, () {
          return find.text('StarNote 원본 PDF 1개를 가져왔습니다.').evaluate().length ==
              1;
        });
        expect(c.repository, isNot(same(previous)));
        expect(file.streamRead, native == null);
        if (native != null) {
          expect(native.calls, ['choose', 'stage', 'release']);
          expect(native.staged.existsSync(), isFalse);
        }
        final note = c.notes.single;
        expect(note.documentKind, VaultDocumentKind.pdf);
        final selection = File(p.join(support.path, 'vault-selection.json'));
        expect(jsonDecode(selection.readAsStringSync()), {
          'root': c.repository.root.path,
        });
        await _whilePumping(tester, () async {
          final source = (await c.repository.heads(note.sourceEntityId!))
              .single;
          expect(
            await c.repository.readRevisionFile(source, 'Handout.pdf'),
            pdfBytes,
          );
          final old = await NoteRepository.open(previous.root);
          try {
            expect((await WorkspaceStore(old).list()).single.title, 'Original');
          } finally {
            await old.close();
          }
        });
        await tester.runAsync(
          () => tester.tap(find.text(note.title).hitTestable()),
        );
        final raster = find.descendant(
          of: find.byType(PdfPageView),
          matching: find.byWidgetPredicate(
            (widget) => widget is RawImage && widget.image != null,
          ),
        );
        await _waitUntil(tester, () => raster.evaluate().isNotEmpty);
        expect(c.activeSession?.note.id, note.id);
        expect(
          tester.widget<Editor>(find.byType(Editor)).workspaceReadOnly,
          isFalse,
        );
      });
    },
    skip: pdfiumPath == null || !File(pdfiumPath).existsSync(),
    variant: platforms,
  );

  testWidgets('StarNote confirmation can be cancelled before reading', (
    tester,
  ) async {
    final file = _PickedFile('large.note', [], length: 129 * 1024 * 1024);
    await _withWorkspace(tester, file, (c, support, native) async {
      final previous = c.repository;
      await _openImport(tester);
      if (native != null) expect(native.calls, ['choose']);
      await tester.tap(find.text('취소'));
      await tester.pumpAndSettle();
      expect(file.streamRead, isFalse);
      if (native != null) expect(native.calls, ['choose', 'release']);
      expect(c.repository, same(previous));
      expect(c.notes.single.title, 'Original');
      expect(Directory(p.join(support.path, 'vaults')).existsSync(), isFalse);
    });
  }, variant: platforms);

  testWidgets('StarNote refuses oversized and misnamed inputs before reading', (
    tester,
  ) async {
    final file = _PickedFile('unsupported.zip', [], length: 129 * 1024 * 1024);
    await _withWorkspace(tester, file, (c, support, native) async {
      final previous = c.repository;
      await _chooseStarNote(tester);
      await _waitUntil(tester, () {
        return find
            .textContaining('StarNote .note 파일을 선택하세요.')
            .evaluate()
            .isNotEmpty;
      });
      if (native != null) expect(native.calls, ['choose', 'release']);
      file.name = 'large.note';
      await _openImport(tester);
      await tester.runAsync(() => tester.tap(find.text('PDF 가져오기')));
      await _waitUntil(tester, () {
        return find.textContaining('128 MiB').evaluate().isNotEmpty;
      });
      expect(file.streamRead, isFalse);
      if (native != null) {
        expect(native.calls, [
          'choose',
          'release',
          'choose',
          'stage',
          'release',
        ]);
        expect(native.staged.existsSync(), isFalse);
      }
      expect(c.repository, same(previous));
      expect(c.notes.single.title, 'Original');
      expect(Directory(p.join(support.path, 'vaults')).existsSync(), isFalse);
    });
  }, variant: platforms);

  testWidgets('Android releases failed StarNote staging before a retry', (
    tester,
  ) async {
    final file = _PickedFile('retry.note', [1, 2, 3], length: 4);
    await _withWorkspace(tester, file, (c, support, native) async {
      final previous = c.repository;
      final picker = native!;
      picker.cancelled = true;
      await _chooseStarNote(tester);
      await tester.pump();
      await _waitUntil(
        tester,
        () =>
            picker.calls.isNotEmpty &&
            find.byType(LinearProgressIndicator).evaluate().isEmpty,
      );
      expect(picker.calls, ['choose']);
      expect(find.byType(AlertDialog), findsNothing);

      picker.cancelled = false;
      picker.failure = PlatformException(
        code: 'read_failed',
        message: '선택한 파일을 읽을 수 없습니다.',
      );
      await _openImport(tester);
      await tester.runAsync(() => tester.tap(find.text('PDF 가져오기')));
      await _waitUntil(
        tester,
        () => find.textContaining('선택한 파일을 읽을 수 없습니다.').evaluate().isNotEmpty,
      );
      expect(picker.calls, ['choose', 'choose', 'stage', 'release']);

      picker.failure = null;
      await _openImport(tester);
      await tester.runAsync(() => tester.tap(find.text('PDF 가져오기')));
      await _waitUntil(
        tester,
        () => find
            .textContaining('선택한 문서의 파일 크기를 확인하지 못했습니다.')
            .evaluate()
            .isNotEmpty,
      );
      expect(picker.calls, [
        'choose',
        'choose',
        'stage',
        'release',
        'choose',
        'stage',
        'release',
      ]);
      expect(picker.staged.existsSync(), isFalse);
      expect(c.repository, same(previous));
      expect(Directory(p.join(support.path, 'vaults')).existsSync(), isFalse);
    });
  }, variant: const TargetPlatformVariant({TargetPlatform.android}));
}

Future<void> _withWorkspace(
  WidgetTester tester,
  _PickedFile file,
  Future<void> Function(WorkspaceController, Directory, _AndroidPicker?) body,
) async {
  final previousPicker = FilePickerPlatform.instance;
  final previousPaths = PathProviderPlatform.instance;
  final caches = <ThumbnailCache>[];
  Directory? temp;
  _AndroidPicker? native;
  late Directory support;
  WorkspaceController? controller;
  try {
    await tester.runAsync(() async {
      final root = temp = await Directory.systemTemp.createTemp('starnote-ui-');
      support = Directory(p.join(root.path, 'support'));
      final repository = await NoteRepository.open(
        Directory(p.join(root.path, 'original')),
        createFormatVersion: 2,
      );
      final c = controller = WorkspaceController(
        repository,
        directoryProvider: () async => support,
      );
      await c.store.createMarkdown('Original', Uint8List(0));
      await c.refresh();
      await FileManager.init(
        documentsDirectory: p.join(root.path, 'documents'),
        shouldWatchRootDirectory: false,
      );
      final cache = Directory(p.join(root.path, 'cache'));
      FilePickerPlatform.instance = _Picker(file);
      PathProviderPlatform.instance = _Paths(support.path, cache.path);
      if (defaultTargetPlatform == TargetPlatform.android) {
        native = _AndroidPicker(file, cache);
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              AndroidDocumentSource.starNote.channel,
              native!.handle,
            );
      }
    });
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: StudyWorkspace(
            controller: controller!,
            thumbnailCacheFactory: (root) {
              final cache = ThumbnailCache(root);
              caches.add(cache);
              return cache;
            },
          ),
        ),
      ),
    );
    await body(controller!, support, native);
  } finally {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 6));
    FilePickerPlatform.instance = previousPicker;
    PathProviderPlatform.instance = previousPaths;
    if (native != null) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            AndroidDocumentSource.starNote.channel,
            null,
          );
    }
    await _whilePumping(tester, () async {
      await Future.wait(caches.map((cache) => cache.retire()));
      if (controller case final c?) {
        await c.flush();
        c.dispose();
        await c.repository.close();
      }
      if (temp case final directory?) {
        final resolved = await directory.resolveSymbolicLinks();
        final system = await Directory.systemTemp.resolveSymbolicLinks();
        expect(p.isWithin(system, resolved), isTrue);
        expect(p.basename(resolved), startsWith('starnote-ui-'));
        await Directory(resolved).delete(recursive: true);
      }
    });
  }
}

Future<void> _chooseStarNote(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('library-create-button')));
  await tester.pumpAndSettle();
  final action = find.byKey(const ValueKey('library-create-starnote'));
  await tester.ensureVisible(action);
  await tester.pumpAndSettle();
  expect(action.hitTestable(), findsOneWidget);
  await tester.runAsync(() => tester.tap(action.hitTestable()));
}

Future<void> _openImport(WidgetTester tester) async {
  await _chooseStarNote(tester);
  await _waitUntil(
    tester,
    () => find.byType(AlertDialog).evaluate().length == 1,
  );
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _waitUntil(WidgetTester tester, bool Function() done) async {
  final elapsed = Stopwatch()..start();
  while (!done() && elapsed.elapsed < const Duration(seconds: 12)) {
    await tester.pump(const Duration(milliseconds: 20));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 15)),
    );
  }
  expect(
    done(),
    isTrue,
    reason: tester
        .widgetList<SnackBar>(find.byType(SnackBar))
        .map((bar) => bar.content)
        .whereType<Text>()
        .map((message) => message.data)
        .join('\n'),
  );
}

Future<void> _whilePumping(
  WidgetTester tester,
  Future<void> Function() operation,
) async {
  var complete = false;
  (Object, StackTrace)? failure;
  await tester.runAsync(() async {
    unawaited(
      operation().then<void>(
        (_) => complete = true,
        onError: (Object error, StackTrace stack) {
          failure = (error, stack);
          complete = true;
        },
      ),
    );
  });
  await _waitUntil(tester, () => complete);
  if (failure case (final error, final stack)) {
    Error.throwWithStackTrace(error, stack);
  }
}

final class _Paths extends PathProviderPlatform {
  new(this.support, this.cache);
  final String support;
  final String cache;

  @override
  Future<String?> getApplicationSupportPath() async => support;

  @override
  Future<String?> getTemporaryPath() async => cache;
}

final class _Picker extends FilePickerPlatform {
  new(this.file);
  final PlatformFile file;

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
    expect(defaultTargetPlatform, TargetPlatform.windows);
    expect(dialogTitle, 'StarNote .note 파일 선택');
    expect(type, FileType.custom);
    expect(allowedExtensions, ['note']);
    return file;
  }
}

final class _AndroidPicker {
  new(this.file, Directory cache)
    : staged = File(
        p.join(cache.path, 'starnote-picker', 'starnote-${_process}_$_id.note'),
      );

  static const _id = '6f11a720-c530-4510-8353-5c97edcf643c';
  static const _process = '72f8b8a1-243c-4c9f-bb89-dab69c257281';
  final _PickedFile file;
  final File staged;
  final calls = <String>[];
  var cancelled = false;
  PlatformException? failure;

  Future<Object?> handle(MethodCall call) async {
    calls.add(call.method);
    if (call.method == 'choose') {
      expect(call.arguments, isNull);
      return cancelled ? null : {'id': _id, 'name': file.name};
    }
    expect(call.arguments, {'id': _id});
    if (call.method == 'stage') {
      if (failure case final error?) throw error;
      staged.parent.createSync(recursive: true);
      staged.writeAsBytesSync(file.contents);
      return {
        'path': staged.path,
        'bytes': file.reportedLength ?? file.contents.length,
      };
    }
    expect(call.method, 'release');
    if (staged.existsSync()) staged.deleteSync();
    return null;
  }
}

final class _PickedFile extends PlatformFile {
  new(this.name, this.contents, {int? length}) : reportedLength = length;

  @override
  String name;
  final List<int> contents;
  final int? reportedLength;
  var streamRead = false;

  @override
  Future<int?> length() async => reportedLength;

  @override
  Stream<Uint8List> readAsByteStream() {
    streamRead = true;
    return Stream.value(Uint8List.fromList(contents));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected picker access: ${invocation.memberName}');
}
