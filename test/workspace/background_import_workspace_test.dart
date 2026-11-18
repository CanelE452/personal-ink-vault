import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/vault/thumbnail_cache.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/editor/editor.dart';
import 'package:saber/pages/workspace/library_cards.dart';
import 'package:saber/pages/workspace/study_workspace.dart';

import '../utils/test_editor.dart';
import '../utils/test_mock_channel_handlers.dart';

/// Imports run beside the library (설계 4절): the import is a card with its
/// progress while the rest of the screen stays usable, and the finished
/// document is listed in its folder without opening.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();
  setupMockPathProvider();
  setupMockPrinting();
  setupMockWindowManager();
  late Directory temp;
  late _HeldWritesController controller;
  late bool closed;
  late FilePickerPlatform previousPicker;
  // Any bytes do for the original: nothing reads a PDF until it is opened.
  final pdf = Uint8List.fromList([
    ...utf8.encode('%PDF-1.7\n'),
    ...List.filled(4087, 0x20),
  ]);

  setUp(() async {
    await FileManager.init(shouldWatchRootDirectory: false);
    temp = await Directory.systemTemp.createTemp('background-import-');
    controller = _HeldWritesController(
      await NoteRepository.open(
        Directory(p.join(temp.path, 'vault')),
        createFormatVersion: 2,
      ),
      directoryProvider: () async => Directory(p.join(temp.path, 'support')),
    );
    await controller.refresh();
    closed = false;
    previousPicker = FilePickerPlatform.instance;
    stows.libraryPanelOpen.value = null;
    stows.libraryGrid.value = true;
    stows.librarySort.value = 'default';
  });

  tearDown(() async {
    FilePickerPlatform.instance = previousPicker;
    if (!closed) {
      await controller.flush();
      controller.dispose();
      await controller.repository.close();
    }
    stows.libraryPanelOpen.value = null;
    for (var attempt = 0; ; attempt++) {
      try {
        await temp.delete(recursive: true);
        break;
      } on PathAccessException {
        if (!Platform.isWindows || attempt == 19) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  Future<void> drain(WidgetTester tester) async {
    for (var i = 0; i < 16; i++) {
      await tester.runAsync(() async {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 15));
      });
    }
    await tester.pump(const Duration(milliseconds: 350));
  }

  Future<void> until(
    WidgetTester tester,
    bool Function() ready,
    String reason,
  ) async {
    for (var i = 0; i < 40 && !ready(); i++) {
      await drain(tester);
    }
    expect(ready(), isTrue, reason: reason);
  }

  Future<T> read<T>(WidgetTester tester, Future<T> Function() operation) async {
    var done = false;
    T? value;
    Object? failure;
    StackTrace? trace;
    await tester.runAsync(() async {
      unawaited(
        operation().then(
          (result) {
            value = result;
            done = true;
          },
          onError: (Object error, StackTrace stack) {
            failure = error;
            trace = stack;
            done = true;
          },
        ),
      );
    });
    await until(tester, () => done, 'The read must finish.');
    if (failure != null) Error.throwWithStackTrace(failure!, trace!);
    return value as T;
  }

  Future<void> closeWhilePumping(WidgetTester tester) async {
    var done = false;
    await tester.runAsync(() async {
      unawaited(
        () async {
          await controller.flush();
          controller.dispose();
          await controller.repository.close();
        }().whenComplete(() => done = true),
      );
    });
    for (var i = 0; i < 80 && !done; i++) {
      await drain(tester);
    }
    closed = done;
  }

  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: StudyWorkspace(
            controller: controller,
            thumbnailCacheFactory: _NoCovers.new,
          ),
        ),
      ),
    );
    await drain(tester);
  }

  /// An Android tablet held sideways: the side panel is open beside the
  /// documents.
  void tabletTest(String name, Future<void> Function(WidgetTester) body) {
    testWidgets(name, (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        await body(tester);
      } finally {
        await tester.pumpWidget(const SizedBox());
        if (!closed) await closeWhilePumping(tester);
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  Finder key(String value) => find.byKey(ValueKey(value));
  final importCard = find.byType(LibraryImportCard);
  LibraryImportJobView job(WidgetTester tester) =>
      tester.widget<LibraryImportCard>(importCard).job;
  VaultNote listed(String id) =>
      controller.notes.singleWhere((note) => note.id == id);
  Finder card(VaultNote note) =>
      key('library-note-${note.revision.revisionId}');
  Iterable<VaultNote> pdfs() => controller.notes.where(
    (note) => note.documentKind == VaultDocumentKind.pdf,
  );

  /// + › PDF 가져오기; the picker answers with the next of its files.
  Future<void> importPdf(WidgetTester tester) async {
    await tester.tap(key('library-create-button'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(key('library-add-pdf'));
    await drain(tester);
  }

  /// The open note's back button, pressed in real time as the editor saves.
  Future<void> back(WidgetTester tester) async {
    final button = key('workspace-back-to-library');
    await until(
      tester,
      () =>
          button.evaluate().isNotEmpty &&
          tester.widget<IconButton>(button).onPressed != null,
      'The open note can go back to the library.',
    );
    await tester.runAsync(() async {
      tester.widget<IconButton>(button).onPressed!();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await until(
      tester,
      () => controller.activeSession == null,
      'Back returns to the library.',
    );
  }

  tabletTest(
    'while a slow pdf import runs the library stays usable and another note opens',
    (tester) async {
      final other = (await tester.runAsync(() async {
        final note = await controller.store.create(
          '다른 노트',
          documentKind: VaultDocumentKind.markdown,
        );
        await controller.refresh();
        return note;
      }))!;
      final slow = _SlowFile(File(p.join(temp.path, '느린 자료.pdf')), pdf);
      final picker = _Picker([slow]);
      FilePickerPlatform.instance = picker;
      await mount(tester);
      await importPdf(tester);
      // Half of the file is read: the card at the front of the folder shows
      // how far the import is.
      await until(
        tester,
        () => importCard.evaluate().isNotEmpty && job(tester).progress != null,
        'The import shows as a card with its progress.',
      );
      expect(picker.extensions, [
        ['pdf'],
      ]);
      expect(job(tester).title, '느린 자료');
      expect(job(tester).progress, closeTo(0.425, 1e-9));
      expect(
        find.descendant(
          of: importCard,
          matching: find.text('${(job(tester).progress! * 100).round()}%'),
        ),
        findsOneWidget,
      );
      expect(controller.activeSession, isNull);

      // Meanwhile the library answers: another note opens, and back returns.
      await tester.tap(card(listed(other.id)));
      await until(
        tester,
        () => controller.activeSession?.note.id == other.id,
        'Another note opens while the import runs.',
      );
      await back(tester);
      await until(
        tester,
        () => importCard.evaluate().isNotEmpty,
        'The import is still running when the library comes back.',
      );
      expect(job(tester).progress, closeTo(0.425, 1e-9));
      expect(pdfs(), isEmpty);

      // The rest arrives: the card makes way for the document, which does
      // not open.
      slow.rest.complete();
      await until(
        tester,
        () => importCard.evaluate().isEmpty && pdfs().isNotEmpty,
        'The finished import is listed.',
      );
      final imported = pdfs().single;
      expect(imported.title, '느린 자료');
      expect(card(imported), findsOneWidget);
      expect(controller.activeSession, isNull);
      // Only the original is stored; the pages are made when it is first
      // opened (설계 13절).
      final (files, ink) = await read(tester, () async {
        final repository = controller.repository;
        final source = (await repository.heads(imported.sourceEntityId!))
            .single;
        return (
          await repository.readFiles(source),
          await repository.heads(imported.inkEntityId),
        );
      });
      expect(files, {'느린 자료.pdf': pdf});
      expect(ink, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  tabletTest(
    'an import finishing while a note is open keeps that note open and dirty',
    (tester) async {
      // Only leaving the note saves it here.
      final autosave = stows.autosaveDelay.value;
      addTearDown(() => stows.autosaveDelay.value = autosave);
      stows.autosaveDelay.value = -1;
      final open = (await tester.runAsync(() async {
        final note = await controller.createNote('열린 노트');
        await controller.closeNote(session: controller.activeSession!);
        await controller.refresh();
        return note;
      }))!;
      final slow = _SlowFile(File(p.join(temp.path, '느린 자료.pdf')), pdf);
      FilePickerPlatform.instance = _Picker([slow]);
      await mount(tester);
      await importPdf(tester);
      await until(
        tester,
        () => importCard.evaluate().isNotEmpty,
        'The import shows as a card.',
      );

      // A note opens and gets a stroke that is not saved yet.
      await tester.tap(card(listed(open.id)));
      final editors = find.byType(Editor);
      await until(
        tester,
        () =>
            controller.activeSession?.note.id == open.id &&
            editors.evaluate().isNotEmpty &&
            tester.state<EditorState>(editors).coreInfo.pages.isNotEmpty &&
            !tester.state<EditorState>(editors).coreInfo.readOnly,
        'The note opens in the editor.',
      );
      final session = controller.activeSession!;
      final editor = tester.state<EditorState>(editors);
      await tester.runAsync(() async => editor.drawTestStroke());
      await tester.pump();
      expect(controller.dirty, isTrue);

      // The import finishes behind it and says so.
      slow.rest.complete();
      final message = find.text('‘느린 자료’를 가져왔습니다');
      await until(
        tester,
        () => message.evaluate().isNotEmpty,
        'The finished import is announced.',
      );
      expect(find.widgetWithText(SnackBarAction, '열기'), findsOneWidget);
      // The note stays open in the same editor, its stroke still unsaved.
      expect(controller.activeSession, same(session));
      expect(tester.state<EditorState>(editors), same(editor));
      expect(editor.coreInfo.pages.first.strokes, hasLength(1));
      expect(controller.dirty, isTrue);
      expect(controller.remoteConflict, isFalse);
      final notes = await read(tester, controller.store.list);
      expect(
        notes
            .where((note) => note.documentKind == VaultDocumentKind.pdf)
            .single
            .title,
        '느린 자료',
      );

      // Leaving the note saves the stroke.
      await back(tester);
      final saved = await read(
        tester,
        () => controller.loadInk(session: session),
      );
      expect(saved.pages.first.strokes, hasLength(1));
      saved.dispose();
      expect(tester.takeException(), isNull);
    },
  );

  tabletTest(
    'switching the vault cancels running imports without writing',
    (tester) async {
      final slow = _SlowFile(File(p.join(temp.path, '느린 자료.pdf')), pdf);
      FilePickerPlatform.instance = _Picker([slow]);
      await mount(tester);
      await importPdf(tester);
      await until(
        tester,
        () => importCard.evaluate().isNotEmpty,
        'The import shows as a card.',
      );

      final next = (await tester.runAsync(
        () => NoteRepository.open(
          Directory(p.join(temp.path, 'other')),
          createFormatVersion: 2,
        ),
      ))!;
      await read(tester, () => controller.replaceRepository(next));
      await until(
        tester,
        () => importCard.evaluate().isEmpty,
        'The import ends with the vault it was going into.',
      );

      // The rest of the file still arrives; neither vault gets the document.
      slow.rest.complete();
      for (var i = 0; i < 4; i++) {
        await drain(tester);
      }
      expect(importCard, findsNothing);
      expect(
        await read(tester, () => controller.store.list(includeDeleted: true)),
        isEmpty,
      );
      final first = await read(
        tester,
        () => NoteRepository.open(Directory(p.join(temp.path, 'vault'))),
      );
      try {
        expect(
          await read(
            tester,
            () => WorkspaceStore(first).list(includeDeleted: true),
          ),
          isEmpty,
        );
      } finally {
        await read(tester, first.close);
      }
      expect(tester.takeException(), isNull);
    },
  );

  tabletTest(
    'the finished import appears as a card in its folder without opening',
    (tester) async {
      final folder = (await tester.runAsync(() async {
        final folder = await controller.library.createFolder('강의');
        await controller.openFolder(folder.id);
        await controller.refresh();
        return folder;
      }))!;
      final slow = _SlowFile(File(p.join(temp.path, '강의 자료.pdf')), pdf);
      FilePickerPlatform.instance = _Picker([slow]);
      await mount(tester);
      await importPdf(tester);
      await until(
        tester,
        () => importCard.evaluate().isNotEmpty,
        'The import shows as a card in the folder.',
      );

      // Its card shows in its folder only.
      await tester.tap(key('library-up'));
      await until(
        tester,
        () =>
            controller.currentFolderId == null &&
            key('library-folder-${folder.id}').evaluate().isNotEmpty,
        'The library goes up to the top.',
      );
      expect(importCard, findsNothing);
      await tester.tap(key('library-folder-${folder.id}'));
      await until(
        tester,
        () =>
            controller.currentFolderId == folder.id &&
            importCard.evaluate().isNotEmpty,
        'The folder shows the import again.',
      );

      slow.rest.complete();
      final message = find.text('‘강의 자료’를 가져왔습니다');
      await until(
        tester,
        () =>
            importCard.evaluate().isEmpty &&
            pdfs().isNotEmpty &&
            message.evaluate().isNotEmpty,
        'The finished import is listed and announced.',
      );
      final imported = pdfs().single;
      expect(imported.folderId, folder.id);
      expect(card(imported), findsOneWidget);
      expect(find.widgetWithText(SnackBarAction, '열기'), findsOneWidget);
      expect(controller.activeSession, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  tabletTest('an imported image opens only from 열기 on its message', (
    tester,
  ) async {
    final png = Uint8List.fromList(
      image.encodePng(image.Image(width: 4, height: 3)),
    );
    final picked = _SlowFile(File(p.join(temp.path, '칠판.png')), png)
      ..rest.complete();
    final picker = _Picker([picked]);
    FilePickerPlatform.instance = picker;
    await mount(tester);
    await tester.tap(key('library-create-button'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(key('library-add-image'));
    await drain(tester);
    final message = find.text('‘칠판’을 가져왔습니다');
    Iterable<VaultNote> images() => controller.notes.where(
      (note) => note.documentKind == VaultDocumentKind.image,
    );
    await until(
      tester,
      () =>
          message.evaluate().isNotEmpty &&
          images().isNotEmpty &&
          card(images().single).evaluate().isNotEmpty,
      'The image is listed and announced.',
    );
    expect(picker.extensions, [
      ['png', 'jpg', 'jpeg', 'webp'],
    ]);
    final imported = images().single;
    expect(controller.activeSession, isNull);

    await tester.tap(find.widgetWithText(SnackBarAction, '열기'));
    await until(
      tester,
      () =>
          controller.activeSession?.note.id == imported.id &&
          find.byType(Editor).evaluate().isNotEmpty,
      '열기 opens the imported image in the editor.',
    );
    // Back closes the editor; its image unloads a few seconds later.
    await back(tester);
    await tester.pump(const Duration(seconds: 6));
    expect(tester.takeException(), isNull);
  });

  tabletTest('열기 tapped while another note opens opens the import after it', (
    tester,
  ) async {
    final other = (await tester.runAsync(() async {
      final note = await controller.store.create(
        '다른 노트',
        documentKind: VaultDocumentKind.markdown,
      );
      await controller.refresh();
      return note;
    }))!;
    final png = Uint8List.fromList(
      image.encodePng(image.Image(width: 4, height: 3)),
    );
    final picked = _SlowFile(File(p.join(temp.path, '칠판.png')), png)
      ..rest.complete();
    FilePickerPlatform.instance = _Picker([picked]);
    await mount(tester);
    await tester.tap(key('library-create-button'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(key('library-add-image'));
    await drain(tester);
    Iterable<VaultNote> images() => controller.notes.where(
      (note) => note.documentKind == VaultDocumentKind.image,
    );
    await until(
      tester,
      () =>
          find.text('‘칠판’을 가져왔습니다').evaluate().isNotEmpty &&
          images().isNotEmpty,
      'The image is listed and announced.',
    );
    final imported = images().single;

    // The other note starts opening, and 열기 comes while it does.
    await tester.tap(card(listed(other.id)));
    await tester.tap(find.widgetWithText(SnackBarAction, '열기'));
    await until(
      tester,
      () =>
          controller.activeSession?.note.id == imported.id &&
          find.byType(Editor).evaluate().isNotEmpty,
      '열기 waits for the note being opened, then opens the import.',
    );
    // Back closes the editor; its image unloads a few seconds later.
    await back(tester);
    await tester.pump(const Duration(seconds: 6));
    expect(tester.takeException(), isNull);
  });

  tabletTest(
    'an import cancelled while it is stored goes to the trash beside an unsaved note',
    (tester) async {
      // Only leaving the note saves it here.
      final autosave = stows.autosaveDelay.value;
      addTearDown(() => stows.autosaveDelay.value = autosave);
      stows.autosaveDelay.value = -1;
      final open = (await tester.runAsync(() async {
        final note = await controller.createNote('열린 노트');
        await controller.closeNote(session: controller.activeSession!);
        await controller.refresh();
        return note;
      }))!;
      final hold = controller.holdWrites = Completer<void>();
      final picked = _SlowFile(File(p.join(temp.path, '취소할 자료.pdf')), pdf)
        ..rest.complete();
      FilePickerPlatform.instance = _Picker([picked]);
      await mount(tester);
      await importPdf(tester);
      await until(
        tester,
        () => controller.writesStarted == 1 && importCard.evaluate().isNotEmpty,
        'The import is being stored.',
      );
      // Storing holds the bar at 85 %; × cancels it, and the card goes at once.
      expect(job(tester).progress, closeTo(0.85, 1e-9));
      await tester.tap(key('library-import-cancel-${job(tester).id}'));
      await tester.pump();
      expect(importCard, findsNothing);

      // A note opens and gets a stroke that is not saved yet.
      await tester.tap(card(listed(open.id)));
      final editors = find.byType(Editor);
      await until(
        tester,
        () =>
            controller.activeSession?.note.id == open.id &&
            editors.evaluate().isNotEmpty &&
            tester.state<EditorState>(editors).coreInfo.pages.isNotEmpty &&
            !tester.state<EditorState>(editors).coreInfo.readOnly,
        'The note opens in the editor.',
      );
      final session = controller.activeSession!;
      final editor = tester.state<EditorState>(editors);
      await tester.runAsync(() async => editor.drawTestStroke());
      await tester.pump();
      expect(controller.dirty, isTrue);

      // The storing ends: the cancelled PDF goes to the trash, unsaved note or not.
      hold.complete();
      VaultNote? stored;
      for (var i = 0; i < 20 && stored?.trashed != true; i++) {
        await drain(tester);
        stored = (await read(
          tester,
          () => controller.store.list(includeDeleted: true),
        )).where((note) => note.documentKind == VaultDocumentKind.pdf).singleOrNull;
      }
      expect(stored?.title, '취소할 자료');
      expect(stored?.trashed, isTrue);
      expect(find.textContaining('휴지통으로 옮기지 못했습니다'), findsNothing);
      // The note stays open, its stroke still unsaved.
      expect(controller.activeSession, same(session));
      expect(controller.dirty, isTrue);
      await back(tester);
      expect(tester.takeException(), isNull);
    },
  );

  tabletTest(
    'a vault switch waits for an import being stored, which stays whole in the vault it left',
    (tester) async {
      final hold = controller.holdWrites = Completer<void>();
      final picked = _SlowFile(File(p.join(temp.path, '옮기기 전 자료.pdf')), pdf)
        ..rest.complete();
      FilePickerPlatform.instance = _Picker([picked]);
      await mount(tester);
      await importPdf(tester);
      await until(
        tester,
        () => controller.writesStarted == 1,
        'The import is being stored.',
      );
      final first = controller.repository;
      final next = (await tester.runAsync(
        () => NoteRepository.open(
          Directory(p.join(temp.path, 'other')),
          createFormatVersion: 2,
        ),
      ))!;
      var switched = false;
      Object? switchFailure;
      await tester.runAsync(() async {
        unawaited(
          controller.replaceRepository(next).then(
            (_) => switched = true,
            onError: (Object error) {
              switchFailure = error;
              switched = true;
            },
          ),
        );
      });
      // The switch waits while the PDF is stored, and no other import starts
      // storing into the vault being left.
      for (var i = 0; i < 3; i++) {
        await drain(tester);
      }
      expect(switched, isFalse);
      expect(controller.repository, same(first));
      Object? refused;
      await tester.runAsync(() async {
        try {
          await controller.createDocumentQuietly(
            expectedRepository: first,
            title: '늦은 자료',
            fileName: '늦은 자료.pdf',
            bytes: pdf,
            kind: VaultDocumentKind.pdf,
            folderId: null,
          );
        } catch (error) {
          refused = error;
        }
      });
      expect(
        refused,
        isA<StateError>().having(
          (error) => error.message,
          'message',
          '가져오기 대상 보관함이 바뀌었습니다.',
        ),
      );
      expect(controller.writesStarted, 1);

      // The PDF is stored whole and announced; then the switch ends.
      hold.complete();
      await until(
        tester,
        () => find.text('‘옮기기 전 자료’를 가져왔습니다').evaluate().isNotEmpty,
        'The import finishes before the vault switches.',
      );
      await until(tester, () => switched, 'The vault switches afterwards.');
      expect(switchFailure, isNull);
      expect(controller.repository, same(next));
      expect(importCard, findsNothing);
      expect(
        await read(tester, () => controller.store.list(includeDeleted: true)),
        isEmpty,
      );
      final old = await read(
        tester,
        () => NoteRepository.open(Directory(p.join(temp.path, 'vault'))),
      );
      try {
        final notes = await read(
          tester,
          () => WorkspaceStore(old).list(includeDeleted: true),
        );
        expect(notes.single.title, '옮기기 전 자료');
        expect(notes.single.trashed, isFalse);
      } finally {
        await read(tester, old.close);
      }
      expect(tester.takeException(), isNull);
    },
  );
}

/// The workspace's controller, whose import writes can be held: while
/// [holdWrites] is not complete, storing an original waits for it.
final class _HeldWritesController extends WorkspaceController {
  new(super.repository, {super.directoryProvider});

  Completer<void>? holdWrites;
  var writesStarted = 0;

  @override
  WorkspaceStore get store => _HeldWritesStore(repository, this);
}

final class _HeldWritesStore extends WorkspaceStore {
  new(super.repository, this.owner);

  final _HeldWritesController owner;

  @override
  Future<VaultNote> createWithSource(
    String title, {
    required String fileName,
    required Uint8List bytes,
    required VaultDocumentKind documentKind,
    String? folderId,
    bool fromObsidian = false,
    String? sharedRequestId,
    SharedOfficeOriginal? sharedOfficeOriginal,
  }) async {
    owner.writesStarted++;
    await owner.holdWrites?.future;
    return super.createWithSource(
      title,
      fileName: fileName,
      bytes: bytes,
      documentKind: documentKind,
      folderId: folderId,
      fromObsidian: fromObsidian,
      sharedRequestId: sharedRequestId,
      sharedOfficeOriginal: sharedOfficeOriginal,
    );
  }
}

final class _NoCovers extends ThumbnailCache {
  new(super.root);

  @override
  Future<String?> coverKey(NoteRepository repository, VaultNote note) async =>
      null;
}

/// The picker: each pick answers with the next file, and the extensions it
/// was asked for are kept.
final class _Picker extends FilePickerPlatform {
  new(this.files);
  final List<PlatformFile> files;
  final extensions = <List<String>?>[];

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
    extensions.add(allowedExtensions);
    return files.isEmpty ? null : files.removeAt(0);
  }
}

/// A file the picker chose. Its first half reads at once; the rest waits for
/// [rest], so the import stays in its reading step until the test lets it go.
final class _SlowFile extends PlatformFile {
  new(this.file, this.bytes);

  /// Where the picker says the file is; what it holds is [bytes].
  final File file;
  final Uint8List bytes;
  final rest = Completer<void>();

  @override
  String get name => p.basename(file.path);
  @override
  Uri get uri => file.uri;
  @override
  Never get xFile => throw UnsupportedError('The import reads the stream.');
  @override
  int lengthSync() => bytes.length;
  @override
  Future<int?> length() async => bytes.length;
  @override
  Future<Uint8List> readAsBytes() =>
      throw UnsupportedError('The import reads in chunks to show progress.');
  @override
  Stream<Uint8List> readAsByteStream() async* {
    final half = bytes.length ~/ 2;
    yield Uint8List.sublistView(bytes, 0, half);
    await rest.future;
    yield Uint8List.sublistView(bytes, half);
  }
}
