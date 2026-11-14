import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:pdf/pdf.dart' show PdfPageFormat;
import 'package:pdf/widgets.dart' as pdf;
import 'package:pdfrx/pdfrx.dart';
import 'package:saber/components/canvas/canvas_gesture_detector.dart';
import 'package:saber/components/canvas/image/editor_image.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/native/ink_vault_native.dart';
import 'package:saber/data/office/office_templates.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/editor/editor.dart';
import 'package:saber/pages/office/office_workspace.dart';
import 'package:saber/pages/workspace/card_canvas.dart';
import 'package:saber/pages/workspace/markdown_editor.dart';
import 'package:saber/pages/workspace/study_workspace.dart';

import '../office/office_original_preview_test.dart'
    show OfficePreviewDocumentTracker, officePreviewDocumentsClosed;
import '../utils/test_mock_channel_handlers.dart';
import '../vault/pdf_import_transaction_test.dart'
    show DelayedPdfBackend, TestPdfDocument, TestPdfPage;

const _androidFolder = MethodChannel('personal_ink_vault/obsidian_folder');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();
  setupMockWindowManager();
  final libraryPath = Platform.environment['INK_VAULT_NATIVE_LIBRARY'];
  final hasNative = libraryPath != null && File(libraryPath).existsSync();
  final pdfiumPath = Platform.environment['PIV_PDF_ANCHOR_TEST_PDFIUM'];
  late Directory temp;
  late Directory support;
  late WorkspaceController controller;
  const ioTimeout = Duration(seconds: 12);

  Future<void> completeWhilePumping(
    WidgetTester tester,
    String phase,
    Future<void> Function() operation,
  ) async {
    var complete = false;
    (Object, StackTrace)? failure;
    await tester.runAsync(() async {
      unawaited(
        operation()
            .timeout(
              ioTimeout,
              onTimeout: () => throw TimeoutException(phase, ioTimeout),
            )
            .then<void>(
              (_) {
                complete = true;
              },
              onError: (Object error, StackTrace stack) {
                failure = (error, stack);
                complete = true;
              },
            ),
      );
    });
    final timer = Stopwatch()..start();
    while (!complete &&
        timer.elapsed < ioTimeout + const Duration(seconds: 1)) {
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 15)),
      );
    }
    if (!complete) {
      throw TimeoutException(phase, ioTimeout);
    }
    final error = failure;
    if (error != null) Error.throwWithStackTrace(error.$1, error.$2);
  }

  void testImport(
    String name,
    TargetPlatform platform,
    Future<void> Function(WidgetTester) body, {
    bool withNative = false,
    Future<void> Function(WidgetTester)? beforeFixtureDeletion,
  }) {
    testWidgets(
      name,
      (tester) async {
        final originalPicker = FilePickerPlatform.instance;
        final originalPaths = PathProviderPlatform.instance;
        Directory? owned;
        WorkspaceController? opened;
        debugPrint('Obsidian UI setup: $name');
        try {
          final ready = await tester.runAsync(() async {
            temp = owned = await Directory.systemTemp
                .createTemp('obsidian-import-ui-')
                .timeout(ioTimeout);
            support = Directory(p.join(temp.path, 'support'));
            final repo = await NoteRepository.open(
              Directory(p.join(temp.path, 'original')),
              createFormatVersion: 2,
            ).timeout(ioTimeout);
            controller = opened = WorkspaceController(
              repo,
              native: withNative
                  ? InkVaultNative.open(libraryPath: libraryPath)
                  : null,
              directoryProvider: () async => support,
            );
            await controller.refresh().timeout(ioTimeout);
            PathProviderPlatform.instance = _OwnedPaths(support.path);
            await FileManager.init(
              documentsDirectory: p.join(temp.path, 'documents'),
              shouldWatchRootDirectory: false,
            ).timeout(ioTimeout);
            return true;
          });
          expect(ready, isTrue);
          debugPrint('Obsidian UI workspace ready');
          await body(tester);
        } finally {
          debugPrint('Obsidian UI cleanup');
          await tester.pumpWidget(const SizedBox());
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            _androidFolder,
            null,
          );
          FilePickerPlatform.instance = originalPicker;
          PathProviderPlatform.instance = originalPaths;
          final c = opened;
          try {
            if (c != null) {
              try {
                await completeWhilePumping(tester, 'Workspace flush', c.flush);
              } finally {
                await completeWhilePumping(
                  tester,
                  'Repository close',
                  () async {
                    c.dispose();
                    await c.repository.close();
                  },
                );
              }
            }
          } finally {
            await tester.pump(const Duration(seconds: 6));
            await beforeFixtureDeletion?.call(tester);
            await tester.runAsync(() async {
              final directory = owned;
              if (directory != null) {
                final resolved = await directory.resolveSymbolicLinks().timeout(
                  ioTimeout,
                );
                final root = await Directory.systemTemp
                    .resolveSymbolicLinks()
                    .timeout(ioTimeout);
                expect(p.isWithin(root, resolved), isTrue);
                expect(p.basename(resolved), startsWith('obsidian-import-ui-'));
                await Directory(resolved)
                    .delete(recursive: true)
                    .timeout(ioTimeout);
              }
            });
          }
          debugPrint('Obsidian UI cleanup complete');
        }
      },
      timeout: const Timeout(Duration(seconds: 75)),
      skip: withNative && !hasNative,
      variant: TargetPlatformVariant({platform}),
    );
  }

  Future<void> openImport(WidgetTester tester) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(home: StudyWorkspace(controller: controller)),
      ),
    );
    await tester.pump();
    debugPrint('Obsidian UI library mounted');
    await tester.runAsync(
      () => tester.tap(find.byKey(const ValueKey('library-create-button'))),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final option = find.text('Obsidian 보관함 가져오기').hitTestable();
    expect(option, findsOneWidget);
    debugPrint('Obsidian UI create menu open');
    await tester.runAsync(() => tester.tap(option));
    debugPrint('Obsidian UI import selected');
  }

  Future<void> waitUntil(
    WidgetTester tester,
    bool Function() done, {
    String Function()? diagnostics,
  }) async {
    final timer = Stopwatch()..start();
    while (!done() && timer.elapsed < ioTimeout) {
      await tester.pump(const Duration(milliseconds: 20));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 15)),
      );
    }
    final completed = done();
    expect(
      completed,
      isTrue,
      reason: completed ? null : diagnostics?.call() ?? controller.error,
    );
  }

  Future<void> chooseImportSource(WidgetTester tester, String label) async {
    final option = find.text(label).hitTestable();
    await waitUntil(tester, () => option.evaluate().length == 1);
    await tester.runAsync(() => tester.tap(option));
  }

  Future<void> tapMarkdownLink(WidgetTester tester, String label) async {
    final text = find.byWidgetPredicate(
      (widget) =>
          widget is SelectableText &&
          (widget.data ?? widget.textSpan?.toPlainText()) == label,
    );
    final link = find.descendant(of: text, matching: find.byType(EditableText));
    await waitUntil(tester, () => link.evaluate().length == 1);
    await tester.ensureVisible(text);
    await tester.pump();
    final renderer = tester.state<EditableTextState>(link).renderEditable;
    final box = renderer
        .getBoxesForSelection(
          const TextSelection(baseOffset: 0, extentOffset: 1),
        )
        .first;
    final point = renderer.localToGlobal(box.toRect().center);
    final hits = tester.hitTestOnBinding(point).path;
    expect(
      hits.any((entry) => identical(entry.target, renderer)),
      isTrue,
      reason: 'Markdown link $label at $point was blocked by $hits',
    );
    await tester.runAsync(() => tester.tapAt(point));
  }

  testImport(
    'Android import rejects oversized ZIP before reading the stream',
    TargetPlatform.android,
    (tester) async {
      final file = _OversizedZip();
      final picker = _Picker(file);
      FilePickerPlatform.instance = picker;
      final original = controller.repository;
      await openImport(tester);
      await chooseImportSource(tester, 'ZIP 파일 선택');
      await waitUntil(
        tester,
        () => find.textContaining('128 MiB').evaluate().isNotEmpty,
      );
      expect(picker.fileRequests, 1);
      expect(picker.folderRequests, 0);
      expect(file.streamRead, isFalse);
      expect(controller.repository, same(original));
    },
  );

  testImport(
    'Android folder selection cancels without opening another vault',
    TargetPlatform.android,
    (tester) async {
      var picks = 0;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        _androidFolder,
        (call) async {
          expect(call.method, 'pickFolder');
          expect(call.arguments, isNull);
          picks++;
          return null;
        },
      );
      final original = controller.repository;
      await openImport(tester);
      await chooseImportSource(tester, '폴더 선택');
      await waitUntil(tester, () => picks == 1);
      expect(controller.repository, same(original));
    },
  );

  testImport(
    'Android folder import reads a staged vault and releases it after saving',
    TargetPlatform.android,
    (tester) async {
      const id = '9df7df2f-e094-4d49-b339-dfb26cd44967';
      const contents = '[[References/Target|링크]]\n';
      final cache = Directory(p.join(temp.path, 'cache'));
      final staged = Directory(p.join(cache.path, 'obsidian-picker', id));
      PathProviderPlatform.instance = _OwnedPaths(support.path, cache: cache.path);
      await tester.runAsync(() async {
        await staged.create(recursive: true);
        await File(p.join(staged.path, 'Start.md')).writeAsString(contents);
        final child = Directory(p.join(staged.path, 'References'));
        await child.create();
        await File(p.join(child.path, 'Target.md')).writeAsString('## 대상\n');
      });
      final calls = <String>[];
      final original = controller.repository;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        _androidFolder,
        (call) async {
          calls.add(call.method);
          if (call.method == 'pickFolder') {
            expect(call.arguments, isNull);
            return {'id': id, 'name': '모바일 보관함'};
          }
          expect(call.method, 'release');
          expect(call.arguments, {'id': id});
          await staged.delete(recursive: true);
          return null;
        },
      );
      await openImport(tester);
      await chooseImportSource(tester, '폴더 선택');
      await waitUntil(
        tester,
        () => calls.length == 2 &&
            !identical(controller.repository, original) &&
            controller.notes.any((note) => note.title == 'Start') &&
            controller.folders.any((folder) => folder.title == 'References'),
      );
      final start = controller.notes.singleWhere((note) => note.title == 'Start');
      final referenceFolder = controller.folders.singleWhere(
        (folder) => folder.title == 'References',
      );
      expect(controller.notes.singleWhere((note) => note.title == 'Target').folderId,
          referenceFolder.id);
      await tester.runAsync(() async {
        expect(await (await controller.store.open(start)).readMarkdown(), contents);
        expect(staged.existsSync(), isFalse);
        expect(p.basename(controller.repository.root.path), startsWith('obsidian-모바일 보관함-'));
      });
      expect(calls, ['pickFolder', 'release']);
    },
    withNative: true,
  );

  testImport(
    'Windows folder selection can be canceled without switching vaults',
    TargetPlatform.windows,
    (tester) async {
      final picker = _Picker(null);
      FilePickerPlatform.instance = picker;
      final original = controller.repository;
      await openImport(tester);
      final folder = find.text('폴더 선택');
      await waitUntil(tester, () => folder.evaluate().length == 1);
      expect(find.text('ZIP 파일 선택'), findsOneWidget);
      await tester.runAsync(() => tester.tap(folder));
      await waitUntil(tester, () => picker.folderRequests == 1);
      expect(picker.fileRequests, 0);
      expect(controller.repository, same(original));
    },
  );

  testImport(
    'Android workspace opens an imported Canvas, saves an edit and follows its file card',
    TargetPlatform.android,
    (tester) async {
      tester.view.physicalSize = const Size(1000, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final originalBoard = jsonEncode({
        'nodes': [
          {
            'id': 'cover',
            'type': 'group',
            'label': 'Board group',
            'background': 'Media/Cover.png',
            'backgroundStyle': 'ratio',
            'x': 4970,
            'y': -8030,
            'width': 700,
            'height': 200,
          },
          {
            'id': 'text',
            'type': 'text',
            'text': 'Board draft',
            'x': 5000,
            'y': -8000,
            'width': 190,
            'height': 100,
          },
          {
            'id': 'file',
            'type': 'file',
            'file': 'Notes/Reading.md',
            'subpath': '#Target section',
            'x': 5250,
            'y': -8000,
            'width': 190,
            'height': 100,
          },
          {
            'id': 'cover-file',
            'type': 'file',
            'file': 'Media/Cover.png',
            'x': 5470,
            'y': -8000,
            'width': 150,
            'height': 100,
          },
        ],
        'edges': [
          {'id': 'link', 'fromNode': 'text', 'toNode': 'file', 'label': 'Read'},
        ],
      });
      const reading = '# Target section\n\n[[Boards/Plan.canvas|Open board]]';
      final cover = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEUlEQVR4nGNQKNj3H4QZYAwATRAJNQkgY7wAAAAASUVORK5CYII=',
      );
      final zip = ZipEncoder().encode(
        Archive()
          ..addFile(ArchiveFile.string('Boards/Plan.canvas', originalBoard))
          ..addFile(ArchiveFile.string('Notes/Reading.md', reading))
          ..addFile(ArchiveFile('Media/Cover.png', cover.length, cover)),
      );
      FilePickerPlatform.instance = _Picker(_PickedZip(zip));
      await openImport(tester);
      await chooseImportSource(tester, 'ZIP 파일 선택');
      await waitUntil(
        tester,
        () => controller.notes.any((note) => note.title == 'Plan.canvas'),
      );
      await waitUntil(
        tester,
        () => find.textContaining('캔버스 1개').evaluate().length == 1,
      );

      final notesFolder = controller.folders.singleWhere(
        (folder) => folder.title == 'Notes',
      );
      final folder = find
          .byKey(ValueKey('library-folder-${notesFolder.id}'))
          .hitTestable();
      await waitUntil(tester, () => folder.evaluate().length == 1);
      await tester.runAsync(() => tester.tap(folder));
      final note = controller.notes.singleWhere(
        (note) => note.title == 'Reading',
      );
      final title = find
          .descendant(
            of: find.byKey(
              ValueKey('library-note-${note.revision.revisionId}'),
            ),
            matching: find.text('Reading'),
          )
          .hitTestable();
      await waitUntil(tester, () => title.evaluate().length == 1);
      await tester.runAsync(() => tester.tap(title));
      await tapMarkdownLink(tester, 'Open board');

      final canvas = find.byType(CardCanvas);
      Finder inBoard(Finder inner) =>
          find.descendant(of: canvas, matching: inner);
      final originalText = inBoard(find.text('Board draft'));
      await waitUntil(tester, () => originalText.evaluate().length == 1);
      final decoded = inBoard(find.byWidgetPredicate(
        (widget) => widget is RawImage && widget.image != null,
      ));
      await waitUntil(
        tester,
        () => decoded.evaluate().length == 2,
        diagnostics: () => 'Decoded Canvas images ${decoded.evaluate().length}',
      );
      expect(
        controller.activeSession?.note.documentKind,
        VaultDocumentKind.canvas,
      );
      await tester.tapAt(tester.getCenter(originalText));
      await tester.pump();
      final input = inBoard(find.byKey(const ValueKey('card-canvas-text')));
      await waitUntil(tester, () => input.evaluate().length == 1);
      await tester.enterText(input, 'Board updated');
      await tester.pump();
      final card = inBoard(find.text('Reading'));
      await tester.tapAt(tester.getCenter(card));
      await tester.pump();
      final open = inBoard(find.text('문서 열기')).hitTestable();
      await waitUntil(tester, () => open.evaluate().length == 1);
      await tester.runAsync(() => tester.tap(open));
      final readyToNavigate = find.byWidgetPredicate(
        (widget) =>
            widget is IconButton &&
            widget.tooltip == '문서 연결 · 태그 · 그래프' &&
            widget.onPressed != null,
      );
      await waitUntil(
        tester,
        () =>
            controller.activeSession?.note.id == note.id &&
            controller.navigation.current.markdownAnchor == 'Target section' &&
            readyToNavigate.evaluate().length == 1,
      );
      await tapMarkdownLink(tester, 'Open board');
      await waitUntil(
        tester,
        () => inBoard(find.text('Board updated')).evaluate().length == 1,
        diagnostics: () =>
            'Active ${controller.activeSession?.note.title}, '
            'canvas ${canvas.evaluate().length}, error ${controller.error}, '
            'texts ${tester.widgetList<Text>(inBoard(find.byType(Text))).map((w) => w.data).toList()}',
      );

      final board = controller.activeSession!.note;
      late List<int> bytes;
      await completeWhilePumping(tester, 'read the original Canvas', () async {
        final repository = controller.repository;
        final head = (await repository.heads(board.sourceEntityId!)).single;
        bytes = await repository.readRevisionFile(head, 'Plan.canvas');
      });
      expect(bytes, utf8.encode(originalBoard));
      await completeWhilePumping(tester, 'close the Canvas', () async {
        await tester.binding.handlePopRoute();
      });
      await waitUntil(tester, () => controller.activeSession == null);
    },
    withNative: true,
  );

  testImport(
    'Windows folder import opens a separate vault and follows a rendered wiki link',
    TargetPlatform.windows,
    (tester) async {
      const source = '[[Notes/Target#Destination|Cross-folder link]]\n';
      const target = '# Destination\n\nImported target text.\n';
      final fixture = Directory(p.join(temp.path, 'Obsidian'));
      final startingNote = File(p.join(fixture.path, 'Reading', 'Start.md'));
      final targetNote = File(p.join(fixture.path, 'Notes', 'Target.md'));
      final original = controller.repository;
      final manifest = File(p.join(original.root.path, 'vault.json'));
      final oldManifest = await tester.runAsync(() async {
        await startingNote.parent.create(recursive: true);
        await targetNote.parent.create(recursive: true);
        await startingNote.writeAsString(source);
        await targetNote.writeAsString(target);
        await File(p.join(targetNote.parent.path, 'attachment.txt'))
            .writeAsBytes([0]);
        return manifest.readAsBytes();
      });
      final picker = _Picker(null, folder: fixture.path);
      FilePickerPlatform.instance = picker;
      await openImport(tester);
      final chooseFolder = find.text('폴더 선택').hitTestable();
      await waitUntil(tester, () => chooseFolder.evaluate().length == 1);
      await tester.runAsync(() => tester.tap(chooseFolder));
      await waitUntil(
        tester,
        () => find
            .textContaining('Markdown 2개와 폴더 2개를 가져왔습니다.')
            .evaluate()
            .isNotEmpty,
      );
      expect(find.textContaining('건너뛴 비Markdown 파일 1개'), findsOneWidget);
      expect(picker.folderRequests, 1);
      expect(controller.repository, isNot(same(original)));
      final destination = controller.repository.root.path;
      expect(p.isWithin(p.join(support.path, 'vaults'), destination), isTrue);
      expect(controller.repository.formatVersion, 2);
      debugPrint('Obsidian UI imported vault selected');

      final reading = controller.folders.singleWhere(
        (folder) => folder.title == 'Reading',
      );
      final folderCard = find.byKey(ValueKey('library-folder-${reading.id}'));
      await tester.runAsync(
        () => tester.tap(
          find.descendant(of: folderCard, matching: find.text('Reading')),
        ),
      );
      final note = controller.notes.singleWhere(
        (note) => note.title == 'Start',
      );
      expect(note.folderId, reading.id);
      final card = find.byKey(
        ValueKey('library-note-${note.revision.revisionId}'),
      );
      final cover = find.descendant(
        of: card,
        matching: find.byWidgetPredicate(
          (widget) => widget is RawImage && widget.image != null,
        ),
      );
      // Let the library finish its asynchronous thumbnail write before leaving.
      await waitUntil(
        tester,
        () =>
            card.hitTestable().evaluate().length == 1 &&
            cover.evaluate().length == 1,
      );
      debugPrint('Obsidian UI imported Markdown cover rendered');
      await tester.runAsync(
        () =>
            tester.tap(find.descendant(of: card, matching: find.text('Start'))),
      );

      final editor = find.byType(MarkdownEditor);
      await waitUntil(tester, () => editor.evaluate().length == 1);
      expect(tester.widget<MarkdownEditor>(editor).source, source);
      await tapMarkdownLink(tester, 'Cross-folder link');
      await waitUntil(
        tester,
        () =>
            controller.activeSession?.note.title == 'Target' &&
            controller.navigation.current.markdownAnchor == 'Destination' &&
            editor.evaluate().length == 1 &&
            tester.widget<MarkdownEditor>(editor).source == target,
      );
      final notes = controller.folders.singleWhere(
        (folder) => folder.title == 'Notes',
      );
      expect(controller.activeSession!.note.folderId, notes.id);
      debugPrint('Obsidian UI wiki destination opened');
      await tester.runAsync(() async {
        final selection = File(p.join(support.path, 'vault-selection.json'));
        expect(jsonDecode(await selection.readAsString()), {
          'root': destination,
        });
        expect(await manifest.readAsBytes(), oldManifest);
        expect(await startingNote.readAsString(), source);
        expect(await targetNote.readAsString(), target);
      });
    },
    withNative: true,
  );

  testImport(
    'Obsidian attachment links open their viewers and embedded images use vault bytes',
    TargetPlatform.windows,
    (tester) async {
      tester.view.physicalSize = const Size(920, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const source =
          '[[Media/Deck.pptx|Slides]]\n\n'
          '[[Media/Handout.pdf#page=2|Handout wiki]]\n\n'
          '[Handout Markdown](Media/Handout.pdf#page=2)\n\n'
          '[Handout missing page](Media/Handout.pdf#page=99)\n\n'
          '[Picture](Media/Pixel.png)\n\n'
          '![[Media/Pixel.png]]\n\n'
          '![Local image](Media/Pixel.png)\n\n'
          '![Remote image](https://example.invalid/tracker.png)\n\n'
          '[[Media/Lecture.canvas|Handout board]]';
      final fixture = Directory(p.join(temp.path, 'Obsidian'));
      final start = File(p.join(fixture.path, 'Start.md'));
      final originals = <String, List<int>>{};
      await tester.runAsync(() async {
        final media = await Directory(p.join(fixture.path, 'Media'))
            .create(recursive: true);
        await start.writeAsString(source);
        final handout = pdf.Document();
        for (var page = 1; page <= 3; page++) {
          handout.addPage(
            pdf.Page(
              pageFormat: const PdfPageFormat(300, 600),
              build: (_) => pdf.Text('Imported PDF $page'),
            ),
          );
        }
        originals.addAll({
          'Handout.pdf': await handout.save(),
          'Lecture.canvas': utf8.encode(
            jsonEncode({
              'nodes': [
                {
                  'id': 'page',
                  'type': 'file',
                  'file': 'Media/Handout.pdf',
                  'subpath': '#page=2',
                  'x': 0,
                  'y': 0,
                  'width': 300,
                  'height': 200,
                },
              ],
              'edges': [],
            }),
          ),
          'Deck.pptx': OfficeTemplates.create(
            OfficeTemplateKind.presentation,
            title: 'Imported presentation',
          ).bytes,
          'Pixel.png': base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEUlEQVR4nGNQKNj3H4QZYAwATRAJNQkgY7wAAAAASUVORK5CYII=',
          ),
        });
        for (final entry in originals.entries) {
          await File(p.join(media.path, entry.key)).writeAsBytes(entry.value);
        }
      });
      FilePickerPlatform.instance = _Picker(null, folder: fixture.path);
      final previous = controller.repository;
      await openImport(tester);
      final folder = find.text('폴더 선택').hitTestable();
      await waitUntil(tester, () => folder.evaluate().length == 1);
      await tester.runAsync(() => tester.tap(folder));
      await waitUntil(
        tester,
        () => !identical(controller.repository, previous),
      );
      debugPrint('Attachment UI imported vault selected');
      await waitUntil(
        tester,
        () => controller.notes.any((n) => n.title == 'Start'),
      );
      final note = controller.notes.singleWhere((n) => n.title == 'Start');
      final card = find.byKey(
        ValueKey('library-note-${note.revision.revisionId}'),
      );
      final cover = find.descendant(
        of: card,
        matching: find.byWidgetPredicate(
          (widget) => widget is RawImage && widget.image != null,
        ),
      );
      await waitUntil(tester, () => cover.evaluate().length == 1);
      debugPrint('Attachment UI Markdown cover rendered');
      final startTitle = find.descendant(
        of: card,
        matching: find.text('Start'),
      );
      await tester.ensureVisible(startTitle);
      await waitUntil(
        tester,
        () => startTitle.hitTestable().evaluate().length == 1,
      );
      debugPrint('Attachment UI Start card visible');
      await tester.runAsync(() => tester.tap(startTitle.hitTestable()));
      final markdown = find.byType(MarkdownEditor);
      final renderedImages = find.descendant(
        of: markdown,
        matching: find.byWidgetPredicate(
          (widget) => widget is RawImage && widget.image != null,
        ),
      );
      await waitUntil(tester, () => renderedImages.evaluate().length == 2);
      expect(tester.widget<MarkdownEditor>(markdown).source, source);
      debugPrint('Attachment UI Start and both raster embeds visible');

      Future<void> returnToStart() async {
        final history = find
            .byWidgetPredicate(
              (widget) =>
                  widget is IconButton &&
                  widget.tooltip == '이전 위치' &&
                  widget.onPressed != null,
            )
            .hitTestable();
        await waitUntil(
          tester,
          () =>
              !controller.dirty &&
              controller.canCreateDocument &&
              history.evaluate().length == 1,
        );
        await tester.runAsync(() => tester.tap(history));
        await waitUntil(
          tester,
          () => controller.activeSession?.note.id == note.id,
        );
        final forward = find.byWidgetPredicate(
          (widget) =>
              widget is IconButton &&
              widget.tooltip == '다음 위치' &&
              widget.onPressed != null,
        );
        await waitUntil(
          tester,
          () =>
              markdown.evaluate().length == 1 &&
              forward.evaluate().length == 1 &&
              controller.knowledge != null,
        );
        debugPrint('Attachment UI returned to Start');
      }

      debugPrint('Attachment UI tapping Slides');
      await tapMarkdownLink(tester, 'Slides');
      final office = find.byType(OfficeWorkspace);
      await waitUntil(tester, () => office.evaluate().length == 1);
      expect(tester.widget<OfficeWorkspace>(office).note.title, 'Deck.pptx');
      expect(controller.navigation.current.markdown, isFalse);
      debugPrint('Attachment UI Office viewer opened');
      await returnToStart();
      debugPrint('Attachment UI tapping Picture');
      await tapMarkdownLink(tester, 'Picture');
      await waitUntil(
        tester,
        () =>
            controller.activeSession?.note.documentKind ==
                VaultDocumentKind.image &&
            find.byType(Editor).evaluate().length == 1,
      );
      expect(controller.navigation.current.markdown, isFalse);
      debugPrint('Attachment UI image editor opened');
      await returnToStart();

      final oldBackend = PdfrxEntryFunctions.instance;
      final oldPdfiumPath = Pdfrx.pdfiumModulePath;
      final fakeBackend = pdfiumPath == null ? _MultiPagePdfBackend() : null;
      addTearDown(() {
        PdfrxEntryFunctions.instance = oldBackend;
        Pdfrx.pdfiumModulePath = oldPdfiumPath;
      });
      if (fakeBackend != null) {
        PdfrxEntryFunctions.instance = fakeBackend;
      } else {
        expect(Platform.isWindows, isTrue);
        final dll = File(pdfiumPath!).absolute;
        expect(dll.existsSync(), isTrue, reason: dll.path);
        Pdfrx.pdfiumModulePath = dll.path;
        await completeWhilePumping(
          tester,
          'Initialize real PDFium',
          () => pdfrxInitialize(tmpPath: temp.path),
        );
        PdfrxEntryFunctions.instance = OfficePreviewDocumentTracker(oldBackend);
      }
      addTearDown(CanvasTransformCache.clear);
      final editor = find.byType(Editor);
      final canvas = find.byType(CanvasGestureDetector);
      EditorState editorState() => tester.state<EditorState>(editor);
      Future<void> waitForHandout(int pageCount) => waitUntil(
        tester,
        () =>
            controller.activeSession?.note.title == 'Handout.pdf' &&
            !controller.dirty &&
            canvas.evaluate().length == 1 &&
            editorState().coreInfo.pages.length == pageCount,
        diagnostics: () {
          final hasEditor = editor.evaluate().length == 1;
          final messages = tester
              .widgetList<Text>(find.byType(Text))
              .map((text) => text.data)
              .whereType<String>()
              .where((text) => text.contains('실패') || text.contains('없습니다'));
          return 'Handout editor did not show $pageCount pages. '
              'Active note: ${controller.activeSession?.note.title}. '
              'Dirty: ${controller.dirty}. '
              'Pages: ${hasEditor ? editorState().coreInfo.pages.length : null}. '
              'Canvas: ${canvas.evaluate().length}. '
              'Workspace error: ${controller.error}. Messages: $messages.';
        },
      );

      Future<void> verifyRealRaster(EditorPage page) async {
        if (fakeBackend != null) return;
        final pageView = find.descendant(
          of: find.byKey(page.innerCanvasKey),
          matching: find.byType(PdfPageView),
        );
        final raster = find.descendant(
          of: pageView,
          matching: find.byType(RawImage),
        );
        await waitUntil(tester, () {
          if (raster.evaluate().length != 1) return false;
          final image = tester.widget<RawImage>(raster).image;
          return image != null && image.width > 0 && image.height > 0;
        }, diagnostics: () => 'PDFium must draw the linked original page');
        final visible = tester.widget<PdfPageView>(pageView);
        expect(visible.pageNumber, 2);
        expect(visible.document!.pages.length, 3);
      }

      await tapMarkdownLink(tester, 'Handout wiki');
      if (fakeBackend != null) {
        await waitUntil(tester, () => fakeBackend.opened);
        final importPath = tester.widget<Editor>(editor).pdfPath!;
        fakeBackend.release.complete(_MultiPagePdfDocument(importPath));
      }
      await waitForHandout(4);
      expect(controller.navigation.current.markdown, isFalse);
      final initialEditor = editorState();
      final originalBackground =
          initialEditor.coreInfo.pages[0].backgroundImage as PdfEditorImage;
      final pdfPath = originalBackground.pdfFile!.path;
      final originalPage1 = initialEditor.coreInfo.pages[0].pageId;
      final originalPage2 = initialEditor.coreInfo.pages[1].pageId;
      await waitUntil(
        tester,
        () => controller.navigation.current.pageId == originalPage2,
      );
      expect(initialEditor.currentPageIndex, 1, reason: 'Wiki PDF page 2');
      expect(
        initialEditor.coreInfo.pages[initialEditor.currentPageIndex].pageId,
        originalPage2,
      );
      await verifyRealRaster(initialEditor.coreInfo.pages[1]);
      expect(File(pdfPath).readAsBytesSync(), originals['Handout.pdf']);
      expect(start.readAsStringSync(), source);
      expect(controller.notes, hasLength(5));

      final session = controller.activeSession!;
      final firstInkRevision = session.inkParents.single;
      initialEditor.insertPageAfter(0);
      expect(initialEditor.coreInfo.pages[1].backgroundImage, isNull);
      expect(initialEditor.coreInfo.pages[2].pageId, originalPage2);
      await completeWhilePumping(
        tester,
        'Save PDF with an inserted note page',
        initialEditor.saveToFile,
      );
      final savedInkRevision = session.inkParents.single;
      expect(savedInkRevision, isNot(firstInkRevision));
      final restoredPath =
          '/.working/${session.note.inkEntityId}/$savedInkRevision/main';
      await returnToStart();

      void cacheFirstPage() => CanvasTransformCache.add(
        restoredPath,
        Matrix4.translationValues(0, 50, 0),
      );
      cacheFirstPage();
      await tapMarkdownLink(tester, 'Handout Markdown');
      await waitForHandout(5);
      final restoredEditor = editorState();
      expect(restoredEditor.coreInfo.filePath, restoredPath);
      expect(tester.widget<Editor>(editor).pdfPath, isNull);
      await waitUntil(
        tester,
        () => controller.navigation.current.pageId == originalPage2,
      );
      expect(restoredEditor.currentPageIndex, 2, reason: 'Markdown PDF page 2');
      final restoredTarget =
          restoredEditor.coreInfo.pages[restoredEditor.currentPageIndex];
      expect(restoredTarget.pageId, originalPage2);
      expect((restoredTarget.backgroundImage as PdfEditorImage).pdfPage, 1);
      await verifyRealRaster(restoredTarget);
      await returnToStart();

      cacheFirstPage();
      await tapMarkdownLink(tester, 'Handout missing page');
      await waitForHandout(5);
      final missing = find.text('원본 PDF의 지정 페이지를 찾을 수 없습니다.');
      await waitUntil(tester, () => missing.evaluate().length == 1);
      final fallbackEditor = editorState();
      expect(
        fallbackEditor.coreInfo.pages[fallbackEditor.currentPageIndex].pageId,
        originalPage1,
      );
      await returnToStart();

      cacheFirstPage();
      await tapMarkdownLink(tester, 'Handout board');
      final board = find.byType(CardCanvas);
      final pageCard = find.descendant(
        of: board,
        matching: find.text('Handout.pdf'),
      );
      await waitUntil(
        tester,
        () =>
            pageCard.evaluate().length == 1 &&
            tester.state<CardCanvasState>(board).viewport.offset != Offset.zero,
      );
      final state = tester.state<CardCanvasState>(board);
      final surface = find.descendant(
        of: board,
        matching: find.byKey(const ValueKey('card-canvas-surface')),
      );
      final pageNode = state.document.nodes.single;
      final point =
          tester.getTopLeft(surface) +
          state.viewport.worldToScreen(pageNode.bounds.center);
      expect(tester.getRect(surface).contains(point), isTrue);
      await tester.tapAt(point);
      await tester.pump();
      final open = find.descendant(of: board, matching: find.text('문서 열기'));
      await waitUntil(
        tester,
        () => open.evaluate().length == 1,
        diagnostics: () =>
            'File card ${pageNode.linkedNoteId} at $point, '
            'texts ${tester.widgetList<Text>(find.descendant(of: board, matching: find.byType(Text))).map((text) => text.data).toList()}',
      );
      await tester.ensureVisible(open);
      await tester.runAsync(() => tester.tap(open.hitTestable()));
      await waitForHandout(5);
      await waitUntil(
        tester,
        () => controller.navigation.current.pageId == originalPage2,
      );
      final fromBoard = editorState();
      expect(fromBoard.currentPageIndex, 2, reason: 'Canvas PDF page 2');
      await verifyRealRaster(fromBoard.coreInfo.pages[2]);
    },
    withNative: true,
    beforeFixtureDeletion: (tester) async {
      if (PdfrxEntryFunctions.instance is OfficePreviewDocumentTracker) {
        await officePreviewDocumentsClosed(tester);
      }
    },
  );
}

final class _MultiPagePdfBackend extends DelayedPdfBackend {
  @override
  Future<PdfDocument> openFile(
    String filePath, {
    PdfPasswordProvider? passwordProvider,
    bool firstAttemptByEmptyPassword = true,
    bool useProgressiveLoading = false,
  }) {
    if (opened) return Future.value(_MultiPagePdfDocument(filePath));
    opened = true;
    return release.future;
  }
}

final class _MultiPagePdfDocument extends TestPdfDocument {
  new(super.path);

  @override
  late final List<PdfPage> pages = [
    for (var number = 1; number <= 3; number++) _NumberedPdfPage(this, number),
  ];
}

final class _NumberedPdfPage extends TestPdfPage {
  new(super.document, this.pageNumber);

  @override
  final int pageNumber;
}

final class _OwnedPaths extends PathProviderPlatform {
  new(this.support, {this.cache});

  final String support;
  final String? cache;

  @override
  Future<String?> getApplicationSupportPath() async => support;

  @override
  Future<String?> getTemporaryPath() async => cache;
}

final class _Picker extends FilePickerPlatform {
  new(this.file, {this.folder});

  final PlatformFile? file;
  final String? folder;
  var fileRequests = 0;
  var folderRequests = 0;

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
    fileRequests++;
    expect(type, FileType.custom);
    expect(allowedExtensions, ['zip']);
    return file;
  }

  @override
  Future<String?> getDirectoryPath({
    String? dialogTitle,
    String? initialDirectory,
    AndroidOptions androidOptions = const AndroidOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    folderRequests++;
    return folder;
  }
}

final class _OversizedZip extends PlatformFile {
  var streamRead = false;

  @override
  String get name => 'oversized.zip';

  @override
  Future<int?> length() async => 129 * 1024 * 1024;

  @override
  Stream<Uint8List> readAsByteStream() {
    streamRead = true;
    throw StateError('Oversized stream must not be read');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected picker access: ${invocation.memberName}');
}

final class _PickedZip extends PlatformFile {
  new(this.bytes);

  final List<int> bytes;

  @override
  String get name => 'notes.zip';

  @override
  Future<int?> length() async => bytes.length;

  @override
  Stream<Uint8List> readAsByteStream() =>
      Stream.value(Uint8List.fromList(bytes));

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected picker access: ${invocation.memberName}');
}
