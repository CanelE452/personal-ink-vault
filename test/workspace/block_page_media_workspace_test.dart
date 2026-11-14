import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as im;
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/vault/block_page_snapshot.dart';
import 'package:saber/data/vault/database_media_snapshot.dart';
import 'package:saber/data/vault/workspace_database.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/workspace/block_page_editor.dart';
import 'package:saber/pages/workspace/database_editor.dart';
import 'package:saber/pages/workspace/library_home.dart';
import 'package:saber/pages/workspace/study_workspace.dart';

import '../utils/test_mock_channel_handlers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();
  setupMockPathProvider();
  setupMockPrinting();
  setupMockWindowManager();

  late Directory directory;
  late Directory vaultDirectory;
  late WorkspaceController controller;
  late FilePickerPlatform previousPicker;
  var repositoryOpen = false;

  var directoryCreated = false;

  void stage(String value) => debugPrintSynchronously('PIV_MEDIA_STUDY $value');

  setUp(() async {
    previousPicker = FilePickerPlatform.instance;
    stage('setup.file-manager.start');
    await FileManager.init(shouldWatchRootDirectory: false)
        .timeout(const Duration(seconds: 20));
    stage('setup.directory.start');
    directory = await Directory.systemTemp
        .createTemp('page-media-workspace-')
        .timeout(const Duration(seconds: 20));
    directoryCreated = true;
    vaultDirectory = await Directory('${directory.path}/vault')
        .create()
        .timeout(const Duration(seconds: 20));
    stage('setup.repository.open');
    controller = WorkspaceController(
      await NoteRepository.open(
        vaultDirectory,
        createFormatVersion: 2,
      ).timeout(const Duration(seconds: 20)),
    );
    repositoryOpen = true;
    stage('setup.controller.refresh');
    await controller.refresh().timeout(const Duration(seconds: 20));
    stage('setup.complete');
  });

  tearDown(() async {
    stage('teardown.start');
    FilePickerPlatform.instance = previousPicker;
    try {
      if (repositoryOpen) {
        stage('teardown.flush');
        await controller.flush().timeout(const Duration(seconds: 20));
      }
    } finally {
      if (repositoryOpen) {
        stage('teardown.close');
        controller.dispose();
        await controller.repository.close().timeout(
          const Duration(seconds: 20),
        );
        repositoryOpen = false;
      }
      if (directoryCreated) {
        final parent = Directory.systemTemp.absolute.path;
        expect(
          directory.absolute.path,
          startsWith('$parent${Platform.pathSeparator}'),
        );
        stage('teardown.delete-owned-fixture');
        await directory
            .delete(recursive: true)
            .timeout(const Duration(seconds: 20));
      }
      stage('teardown.complete');
    }
  });

  Future<T> readWhilePumping<T>(
    WidgetTester tester,
    String phase,
    Future<T> Function() read,
  ) async {
    stage('$phase.start');
    var done = false;
    T? result;
    Object? failure;
    StackTrace? trace;
    await tester.runAsync(() async {
      unawaited(
        Future<T>.sync(read)
            .timeout(const Duration(seconds: 20))
            .then<void>(
              (value) {
                result = value;
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
    final elapsed = Stopwatch()..start();
    while (!done) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1)),
      );
      await tester.pump(const Duration(milliseconds: 20));
      if (elapsed.elapsed > const Duration(seconds: 25)) {
        fail('$phase did not finish; controller error=${controller.error}');
      }
    }
    if (failure != null) {
      stage('$phase.failed');
      Error.throwWithStackTrace(failure!, trace!);
    }
    stage('$phase.complete');
    return result as T;
  }

  Future<void> waitFor(
    WidgetTester tester,
    bool Function() ready,
    String description,
  ) async {
    final elapsed = Stopwatch()..start();
    while (true) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump(const Duration(milliseconds: 20));
      if (ready()) return;
      if (elapsed.elapsed > const Duration(seconds: 20)) {
        fail('$description; controller error=${controller.error}');
      }
    }
  }

  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(home: StudyWorkspace(controller: controller)),
      ),
    );
  }

  Finder editorButton(String tooltip) => find.descendant(
    of: find.byType(BlockPageEditor),
    matching: find.byWidgetPredicate(
      (widget) => widget is IconButton && widget.tooltip == tooltip,
    ),
  );

  Future<void> saveFromUi(WidgetTester tester) async {
    await waitFor(
      tester,
      () =>
          editorButton('저장').evaluate().isNotEmpty &&
          tester.widget<IconButton>(editorButton('저장')).onPressed != null,
      'The page save action did not become available',
    );
    await tester.tap(editorButton('저장'));
    await waitFor(
      tester,
      () =>
          !controller.dirty &&
          find.byType(LinearProgressIndicator).evaluate().isEmpty &&
          find.byType(CircularProgressIndicator).evaluate().isEmpty,
      'The page and its media did not finish saving',
    );
  }

  Future<void> addFromPicker(
    WidgetTester tester,
    String label,
    int expectedMediaCount,
  ) async {
    await tester.tap(find.byTooltip('블록 추가'));
    await tester.pumpAndSettle();
    final item = find.text(label).last;
    await tester.ensureVisible(item);
    await tester.tap(item);
    await waitFor(tester, () {
      final state = tester.state<BlockPageEditorState>(
        find.byType(BlockPageEditor),
      );
      return state.document.media.length == expectedMediaCount &&
          find.byType(LinearProgressIndicator).evaluate().isEmpty &&
          find.byType(CircularProgressIndicator).evaluate().isEmpty;
    }, 'The selected $label did not reach the real page editor');
  }

  testWidgets(
    'StudyWorkspace database switch replaces the row editor after the next database future completes',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(() => tester.pumpWidget(const SizedBox()));
      try {
        late VaultNote firstNote;
        late VaultNote secondNote;
        late String firstDatabaseId;
        late String secondDatabaseId;
        late String firstRowId;
        late String secondRowId;
        await readWhilePumping<void>(tester, 'db-switch.prepare', () async {
          firstNote = await controller.createNote(
            '첫 번째 DB',
            documentKind: VaultDocumentKind.database,
          );
          final firstSession = controller.activeSession!;
          final firstDatabase = await controller.loadDatabase(
            session: firstSession,
          );
          final firstRow = DatabaseRow.create(
            values: {firstDatabase.properties.single.id: '첫 번째 행'},
          );
          firstDatabaseId = firstDatabase.id;
          firstRowId = firstRow.id;
          await controller.saveDatabase(
            firstDatabase.addRow(firstRow),
            session: firstSession,
          );
          secondNote = await controller.createNote(
            '두 번째 DB',
            documentKind: VaultDocumentKind.database,
          );
          final secondSession = controller.activeSession!;
          final secondDatabase = await controller.loadDatabase(
            session: secondSession,
          );
          final secondRow = DatabaseRow.create(
            values: {secondDatabase.properties.single.id: '두 번째 행'},
          );
          secondDatabaseId = secondDatabase.id;
          secondRowId = secondRow.id;
          await controller.saveDatabase(
            secondDatabase.addRow(secondRow),
            session: secondSession,
          );
          await controller.openNote(firstNote);
        });
        await mount(tester);
        await waitFor(
          tester,
          () =>
              find.byType(DatabaseEditor).evaluate().length == 1 &&
              tester
                      .state<DatabaseEditorState>(find.byType(DatabaseEditor))
                      .database
                      .id ==
                  firstDatabaseId,
          'The first database did not finish opening',
        );
        expect(
          tester
              .state<DatabaseEditorState>(find.byType(DatabaseEditor))
              .database
              .rows
              .map((row) => row.id),
          [firstRowId],
        );

        await readWhilePumping<void>(
          tester,
          'db-switch.open-second',
          () => controller.openNote(secondNote),
        );
        await waitFor(
          tester,
          () =>
              controller.activeSession?.note.id == secondNote.id &&
              find
                      .byWidgetPredicate(
                        (widget) =>
                            widget
                                is FutureBuilder<
                                  (WorkspaceDatabase, List<BlockPageNote>)
                                >,
                      )
                      .evaluate()
                      .length ==
                  1,
          'The next database future was not installed in StudyWorkspace',
        );
        final contents = tester
            .widget<FutureBuilder<(WorkspaceDatabase, List<BlockPageNote>)>>(
              find.byWidgetPredicate(
                (widget) =>
                    widget
                        is FutureBuilder<
                          (WorkspaceDatabase, List<BlockPageNote>)
                        >,
              ),
            );
        final next = await readWhilePumping(
          tester,
          'db-switch.await-second-body',
          () => contents.future!,
        );
        expect(next.$1.id, secondDatabaseId);
        expect(next.$1.rows.map((row) => row.id), [secondRowId]);
        await tester.pump();
        final editor = tester.state<DatabaseEditorState>(
          find.byType(DatabaseEditor),
        );
        expect(
          editor.database.id,
          secondDatabaseId,
          reason:
              'Completed DB B data must replace the prior DB A editor state',
        );
        expect(editor.database.rows.map((row) => row.id), [secondRowId]);
        expect(find.byKey(ValueKey('db-row-open-$firstRowId')), findsNothing);
        expect(
          find.byKey(ValueKey('db-row-open-$secondRowId')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        if (repositoryOpen) {
          await readWhilePumping<void>(
            tester,
            'db-switch.repository.finish',
            () async {
              try {
                await controller.flush();
              } finally {
                controller.dispose();
                await controller.repository.close();
                repositoryOpen = false;
              }
            },
          );
        }
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );

  testWidgets(
    'StudyWorkspace imports real picker files and preserves media captions and separate Markdown after a cold reopen',
    (tester) async {
      stage('body.start');
      tester.view.physicalSize = const Size(800, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(() => tester.pumpWidget(const SizedBox()));

      final image = im.Image(width: 12, height: 8)
        ..setPixelRgba(3, 2, 12, 200, 80, 255);
      final png = Uint8List.fromList(im.encodePng(image));
      final attachment = Uint8List.fromList([
        0xEC,
        0xB2,
        0xA8,
        0xEB,
        0xB6,
        0x80,
        0x0D,
        0x0A,
        0x00,
        0xFF,
      ]);
      late File imageFile;
      late File attachmentFile;
      late VaultNote note;
      late RevisionRecord markdownHead;
      late Map<String, Uint8List> markdownFiles;
      await readWhilePumping<void>(tester, 'fixture.prepare', () async {
        final input = await Directory('${directory.path}/picker-input')
            .create();
        imageFile = await File('${input.path}/도표.png').writeAsBytes(png);
        attachmentFile = await File('${input.path}/강의 자료.txt')
            .writeAsBytes(attachment);
        stage('fixture.create-note');
        note = await controller.createNote(
          '미디어 작업공간 검증',
          documentKind: VaultDocumentKind.page,
        );
        controller.editMarkdown('별도 Markdown 정리 😀');
        stage('fixture.flush-markdown');
        await controller.flush();
        stage('fixture.read-markdown');
        markdownHead = (await controller.repository.heads(
          note.markdownEntityId,
        )).single;
        markdownFiles = await controller.repository.readFiles(markdownHead);
      });
      final picker = _DiskPicker([
        _PickedDiskFile(imageFile, '도표.png'),
        _PickedDiskFile(attachmentFile, '강의 자료.txt'),
      ]);
      FilePickerPlatform.instance = picker;
      stage('ui.mount-active-page');
      await mount(tester);
      await waitFor(
        tester,
        () => find.byType(BlockPageEditor).evaluate().length == 1,
        'The page body did not open in StudyWorkspace',
      );

      stage('ui.pick-image');
      await addFromPicker(tester, '이미지', 1);
      final firstState = tester.state<BlockPageEditorState>(
        find.byType(BlockPageEditor),
      );
      final imageId = firstState.document.blocks.single.id;
      final imageCaption = find.byKey(ValueKey('block-text-$imageId'));
      await tester.ensureVisible(imageCaption);
      await tester.enterText(imageCaption, '처음 그림 설명');
      stage('ui.save-image');
      await saveFromUi(tester);
      final firstSnapshot = await readWhilePumping(
        tester,
        'snapshot.image',
        () async {
          final edition = (await controller.repository.heads(note.inkEntityId))
              .single;
          final snapshot = BlockPageMediaSnapshot.fromFiles(
            await controller.repository.readFiles(edition),
          );
          return (edition: edition, snapshot: snapshot);
        },
      );
      final imageEdition = firstSnapshot.edition;
      expect(firstSnapshot.snapshot.document.blocks.single.text, '처음 그림 설명');
      expect(firstSnapshot.snapshot.mediaBytes(imageId), orderedEquals(png));

      stage('ui.pick-attachment');
      await addFromPicker(tester, '파일 첨부', 2);
      final state = tester.state<BlockPageEditorState>(
        find.byType(BlockPageEditor),
      );
      final attachmentId = state.document.blocks
          .singleWhere((block) => block.type == 'attachment')
          .id;
      final attachmentCaption = find.byKey(
        ValueKey('block-text-$attachmentId'),
      );
      await tester.ensureVisible(attachmentCaption);
      await tester.enterText(attachmentCaption, '강의 원본 첨부');
      await tester.ensureVisible(imageCaption);
      await tester.enterText(imageCaption, '수정한 그림 설명');
      await saveFromUi(tester);

      final storedPages = await readWhilePumping(
        tester,
        'snapshot.both',
        () async {
          final latest = (await controller.repository.heads(note.inkEntityId))
              .single;
          final snapshot = BlockPageMediaSnapshot.fromFiles(
            await controller.repository.readFiles(latest),
          );
          final previous = BlockPageMediaSnapshot.fromFiles(
            await controller.repository.readFiles(imageEdition),
          );
          return (
            revisionId: latest.revisionId,
            snapshot: snapshot,
            previous: previous,
          );
        },
      );
      final savedBodyRevision = storedPages.revisionId;
      expect(storedPages.snapshot.document.version, 2);
      expect(storedPages.snapshot.document.media[imageId]!.name, '도표.png');
      expect(
        storedPages.snapshot.document.media[attachmentId]!.name,
        '강의 자료.txt',
      );
      expect(storedPages.snapshot.document.blocks.map((block) => block.text), [
        '수정한 그림 설명',
        '강의 원본 첨부',
      ]);
      expect(storedPages.snapshot.mediaBytes(imageId), orderedEquals(png));
      expect(
        storedPages.snapshot.mediaBytes(attachmentId),
        orderedEquals(attachment),
      );
      expect(storedPages.previous.document.blocks.single.text, '처음 그림 설명');
      expect(storedPages.previous.mediaBytes(imageId), orderedEquals(png));

      stage('ui.close-page');
      await tester.tap(editorButton('문서 목록으로'));
      await waitFor(
        tester,
        () =>
            controller.activeSession == null &&
            find.byType(BlockPageEditor).evaluate().isEmpty &&
            find.byType(LibraryHome).evaluate().isNotEmpty,
        'The saved media page did not return to its library',
      );
      await tester.pumpWidget(const SizedBox());
      await readWhilePumping<void>(tester, 'repository.restart', () async {
        stage('repository.restart.flush');
        await controller.flush();
        controller.dispose();
        stage('repository.restart.close');
        await controller.repository.close();
        repositoryOpen = false;
        stage('repository.restart.open');
        controller = WorkspaceController(
          await NoteRepository.open(vaultDirectory),
        );
        repositoryOpen = true;
        stage('repository.restart.refresh');
        await controller.refresh();
      });

      await mount(tester);
      await waitFor(
        tester,
        () => find.byType(LibraryHome).evaluate().isNotEmpty,
        'The cold repository did not show its library',
      );
      late VaultNote reopenedNote;
      await readWhilePumping<void>(tester, 'library.read-note', () async {
        reopenedNote = (await controller.store.list()).singleWhere(
          (entry) => entry.id == note.id,
        );
      });
      final tile = find.byKey(
        ValueKey('library-note-${reopenedNote.revision.revisionId}'),
      );
      await tester.ensureVisible(tile);
      stage('ui.reopen-library-tile');
      await tester.tap(tile);
      await waitFor(
        tester,
        () =>
            find.byType(BlockPageEditor).evaluate().length == 1 &&
            find
                    .byKey(ValueKey('block-media-image-$imageId'))
                    .evaluate()
                    .length ==
                1 &&
            find.byType(CircularProgressIndicator).evaluate().isEmpty,
        'The persisted image did not reopen through StudyWorkspace',
      );

      expect(
        tester
            .widget<TextField>(find.byKey(ValueKey('block-text-$imageId')))
            .controller!
            .text,
        '수정한 그림 설명',
      );
      expect(
        tester
            .widget<TextField>(find.byKey(ValueKey('block-text-$attachmentId')))
            .controller!
            .text,
        '강의 원본 첨부',
      );
      final displayed = tester.widget<Image>(
        find.byKey(ValueKey('block-media-image-$imageId')),
      );
      expect(displayed.image, isA<MemoryImage>());
      expect((displayed.image as MemoryImage).bytes, orderedEquals(png));
      final coldSnapshot = await readWhilePumping(
        tester,
        'snapshot.cold',
        () async {
          final session = controller.activeSession!;
          final snapshot = await controller.loadBlockPageSnapshot(
            session: session,
          );
          final current = (await controller.repository.heads(note.inkEntityId))
              .single;
          final summary = (await controller.repository.heads(
            note.markdownEntityId,
          )).single;
          return (
            snapshot: snapshot,
            revisionId: current.revisionId,
            markdown: controller.markdown,
            summaryRevisionId: summary.revisionId,
            summaryFiles: await controller.repository.readFiles(summary),
          );
        },
      );
      expect(coldSnapshot.revisionId, savedBodyRevision);
      expect(coldSnapshot.snapshot.mediaBytes(imageId), orderedEquals(png));
      expect(
        coldSnapshot.snapshot.mediaBytes(attachmentId),
        orderedEquals(attachment),
      );
      expect(coldSnapshot.markdown, '별도 Markdown 정리 😀');
      expect(coldSnapshot.summaryRevisionId, markdownHead.revisionId);
      expect(coldSnapshot.summaryFiles, markdownFiles);
      expect(picker.requests, 2);
      expect(picker.remaining, isEmpty);
      await tester.pumpWidget(const SizedBox());
      await readWhilePumping<void>(tester, 'repository.finish', () async {
        stage('repository.finish.flush');
        await controller.flush();
        controller.dispose();
        stage('repository.finish.close');
        await controller.repository.close();
        repositoryOpen = false;
      });
      expect(tester.takeException(), isNull);
      stage('body.complete');
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
  testWidgets(
    'Flutter host StudyWorkspace imports DB row picker media and preserves captions and separate Markdown after a cold reopen',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(() => tester.pumpWidget(const SizedBox()));
      try {
        final image = im.Image(width: 12, height: 8)
          ..setPixelRgba(3, 2, 200, 12, 80, 255);
        final png = Uint8List.fromList(im.encodePng(image));
        final attachment = Uint8List.fromList([0x44, 0x42, 0x0D, 0x0A, 0, 255]);
        late File imageFile;
        late File attachmentFile;
        late VaultNote note;
        late String rowId;
        late RevisionRecord seedEdition;
        late Map<String, Uint8List> seedFiles;
        late RevisionRecord markdownHead;
        late Map<String, Uint8List> markdownFiles;
        await readWhilePumping<void>(
          tester,
          'db-row.fixture.prepare',
          () async {
            final input = await Directory.fromUri(
              directory.uri.resolve('db-picker-input/'),
            ).create();
            imageFile = await File.fromUri(
              input.uri.resolve(Uri.encodeComponent('DB 도표.png')),
            ).writeAsBytes(png);
            attachmentFile = await File.fromUri(
              input.uri.resolve(Uri.encodeComponent('DB 자료.txt')),
            ).writeAsBytes(attachment);
            note = await controller.createNote(
              'DB 미디어 작업공간 검증',
              documentKind: VaultDocumentKind.database,
            );
            final session = controller.activeSession!;
            final initial = await controller.loadDatabase(session: session);
            final row = DatabaseRow.create(
              values: {initial.properties.single.id: '자료 행'},
            );
            rowId = row.id;
            await controller.saveDatabase(
              initial.addRow(row),
              session: session,
            );
            controller.editMarkdown('DB와 별도 Markdown 정리 😀');
            await controller.flush();
            seedEdition = (await controller.repository.heads(note.inkEntityId))
                .single;
            seedFiles = await controller.repository.readFiles(seedEdition);
            markdownHead = (await controller.repository.heads(
              note.markdownEntityId,
            )).single;
            markdownFiles = await controller.repository.readFiles(markdownHead);
          },
        );
        final picker = _DiskPicker([
          _PickedDiskFile(imageFile, 'DB 도표.png'),
          _PickedDiskFile(attachmentFile, 'DB 자료.txt'),
        ]);
        FilePickerPlatform.instance = picker;
        await mount(tester);
        final rowButton = find.byKey(ValueKey('db-row-open-$rowId'));
        await waitFor(
          tester,
          () =>
              find.byType(DatabaseEditor).evaluate().length == 1 &&
              rowButton.evaluate().length == 1,
          'The seeded DB row did not open in StudyWorkspace',
        );
        await tester.ensureVisible(rowButton);
        await tester.tap(rowButton);
        await waitFor(
          tester,
          () => find.byType(BlockPageEditor).evaluate().length == 1,
          'The DB row body did not open',
        );
        Future<void> saveRowFromUi() async {
          await waitFor(
            tester,
            () =>
                editorButton('저장').evaluate().isNotEmpty &&
                tester.widget<IconButton>(editorButton('저장')).onPressed != null,
            'The DB row save action did not become available',
          );
          await tester.tap(editorButton('저장'));
          // An open row retains DB busy ownership until its route closes.
          await waitFor(
            tester,
            () =>
                !controller.inkDirty &&
                !controller.markdownDirty &&
                find.byType(LinearProgressIndicator).evaluate().isEmpty &&
                find.byType(CircularProgressIndicator).evaluate().isEmpty,
            'The DB row and its media did not finish saving',
          );
        }

        await addFromPicker(tester, '이미지', 1);
        final imageId = tester
            .state<BlockPageEditorState>(find.byType(BlockPageEditor))
            .document
            .blocks
            .single
            .id;
        final imageCaption = find.byKey(ValueKey('block-text-$imageId'));
        await tester.ensureVisible(imageCaption);
        await tester.enterText(imageCaption, '처음 DB 그림 설명');
        await saveRowFromUi();
        final firstSaved = await readWhilePumping(
          tester,
          'db-row.snapshot.image',
          () async {
            final edition = (await controller.repository.heads(
              note.inkEntityId,
            )).single;
            final files = await controller.repository.readFiles(edition);
            return (
              edition: edition,
              files: files,
              snapshot: DatabaseMediaSnapshot.fromFiles(files),
            );
          },
        );
        final imageEdition = firstSaved.edition;
        expect(
          firstSaved.snapshot.mediaBytes(rowId, imageId),
          orderedEquals(png),
        );
        expect(
          (firstSaved.snapshot.database.rows.single.body['blocks'] as List)
              .single['text'],
          '처음 DB 그림 설명',
        );

        await addFromPicker(tester, '파일 첨부', 2);
        final attachmentId = tester
            .state<BlockPageEditorState>(find.byType(BlockPageEditor))
            .document
            .blocks
            .singleWhere((block) => block.type == 'attachment')
            .id;
        final attachmentCaption = find.byKey(
          ValueKey('block-text-$attachmentId'),
        );
        await tester.ensureVisible(attachmentCaption);
        await tester.enterText(attachmentCaption, '행 원본 첨부');
        await tester.ensureVisible(imageCaption);
        await tester.enterText(imageCaption, '수정한 DB 그림 설명');
        await saveRowFromUi();
        final stored = await readWhilePumping(
          tester,
          'db-row.snapshot.both',
          () async {
            final latest = (await controller.repository.heads(note.inkEntityId))
                .single;
            final files = await controller.repository.readFiles(latest);
            return (
              revisionId: latest.revisionId,
              snapshot: DatabaseMediaSnapshot.fromFiles(files),
              previousFiles: await controller.repository.readFiles(
                imageEdition,
              ),
            );
          },
        );
        final savedBodyRevision = stored.revisionId;
        expect(savedBodyRevision, isNot(imageEdition.revisionId));
        expect(stored.snapshot.database.rows.single.id, rowId);
        expect(
          (stored.snapshot.database.rows.single.body['blocks'] as List).map(
            (block) => (block as Map)['text'],
          ),
          ['수정한 DB 그림 설명', '행 원본 첨부'],
        );
        expect(stored.snapshot.mediaBytes(rowId, imageId), orderedEquals(png));
        expect(
          stored.snapshot.mediaBytes(rowId, attachmentId),
          orderedEquals(attachment),
        );
        expect(stored.previousFiles, firstSaved.files);

        await tester.tap(editorButton('문서 목록으로'));
        await waitFor(
          tester,
          () =>
              find.byType(BlockPageEditor).evaluate().isEmpty &&
              find.byType(DatabaseEditor).evaluate().length == 1 &&
              !controller.dirty,
          'The saved row did not return to its database',
        );
        expect(controller.activeSession?.note.id, note.id);
        final databaseBack = find.descendant(
          of: find.byType(DatabaseEditor),
          matching: find.byWidgetPredicate(
            (widget) => widget is IconButton && widget.tooltip == '문서 목록으로',
          ),
        );
        await tester.tap(databaseBack);
        await waitFor(
          tester,
          () =>
              controller.activeSession == null &&
              find.byType(DatabaseEditor).evaluate().isEmpty &&
              find.byType(LibraryHome).evaluate().isNotEmpty,
          'The saved database did not return to its library',
        );
        await tester.pumpWidget(const SizedBox());
        await readWhilePumping<void>(
          tester,
          'db-row.repository.restart',
          () async {
            await controller.flush();
            controller.dispose();
            await controller.repository.close();
            repositoryOpen = false;
            controller = WorkspaceController(
              await NoteRepository.open(vaultDirectory),
            );
            repositoryOpen = true;
            await controller.refresh();
          },
        );
        await mount(tester);
        await waitFor(
          tester,
          () => find.byType(LibraryHome).evaluate().isNotEmpty,
          'The reopened repository did not show its library',
        );
        final reopened = await readWhilePumping(
          tester,
          'db-row.library.read-note',
          () async => (await controller.store.list()).singleWhere(
            (entry) => entry.id == note.id,
          ),
        );
        final metadataRevision = reopened.revision.revisionId;
        final tile = find.byKey(ValueKey('library-note-$metadataRevision'));
        await tester.ensureVisible(tile);
        await tester.tap(tile);
        await waitFor(
          tester,
          () =>
              find.byType(DatabaseEditor).evaluate().length == 1 &&
              rowButton.evaluate().length == 1,
          'The database did not reopen from its library tile',
        );
        await tester.ensureVisible(rowButton);
        await tester.tap(rowButton);
        await waitFor(
          tester,
          () =>
              find.byType(BlockPageEditor).evaluate().length == 1 &&
              find
                      .byKey(ValueKey('block-media-image-$imageId'))
                      .evaluate()
                      .length ==
                  1 &&
              find.byType(CircularProgressIndicator).evaluate().isEmpty,
          'The persisted DB row image did not reopen',
        );
        expect(
          tester.widget<TextField>(imageCaption).controller!.text,
          '수정한 DB 그림 설명',
        );
        expect(
          tester.widget<TextField>(attachmentCaption).controller!.text,
          '행 원본 첨부',
        );
        final displayed = tester.widget<Image>(
          find.byKey(ValueKey('block-media-image-$imageId')),
        );
        expect(displayed.image, isA<MemoryImage>());
        expect((displayed.image as MemoryImage).bytes, orderedEquals(png));
        final cold = await readWhilePumping(
          tester,
          'db-row.snapshot.cold',
          () async {
            final snapshot = await controller.loadDatabaseSnapshot(
              session: controller.activeSession!,
            );
            final current = (await controller.repository.heads(
              note.inkEntityId,
            )).single;
            final summary = (await controller.repository.heads(
              note.markdownEntityId,
            )).single;
            final imageRecord = (await controller.repository.revisions())
                .singleWhere(
                  (record) => record.revisionId == imageEdition.revisionId,
                );
            return (
              snapshot: snapshot,
              revisionId: current.revisionId,
              markdown: controller.markdown,
              summaryRevisionId: summary.revisionId,
              summaryFiles: await controller.repository.readFiles(summary),
              imageEditionFiles: await controller.repository.readFiles(
                imageRecord,
              ),
              seedFiles: await controller.repository.readFiles(seedEdition),
            );
          },
        );
        expect(cold.revisionId, savedBodyRevision);
        expect(cold.snapshot.database.rows.single.id, rowId);
        expect(cold.snapshot.mediaBytes(rowId, imageId), orderedEquals(png));
        expect(
          cold.snapshot.mediaBytes(rowId, attachmentId),
          orderedEquals(attachment),
        );
        expect(cold.markdown, 'DB와 별도 Markdown 정리 😀');
        expect(cold.summaryRevisionId, markdownHead.revisionId);
        expect(cold.summaryFiles, markdownFiles);
        expect(cold.imageEditionFiles, firstSaved.files);
        expect(cold.seedFiles, seedFiles);
        expect(picker.requests, 2);
        expect(picker.remaining, isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        if (repositoryOpen) {
          await readWhilePumping<void>(
            tester,
            'db-row.repository.finish',
            () async {
              try {
                await controller.flush();
              } finally {
                controller.dispose();
                await controller.repository.close();
                repositoryOpen = false;
              }
            },
          );
        }
      }
    },
    // Widget behavior on the Flutter host, not S9+ or native Windows GUI execution.
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );
}

final class _DiskPicker extends FilePickerPlatform {
  new(this.remaining);
  final List<PlatformFile> remaining;
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
    if (remaining.isEmpty)
      throw StateError('Unexpected additional picker request');
    return remaining.removeAt(0);
  }
}

final class _PickedDiskFile extends PlatformFile {
  new(this.file, this.name);
  final File file;
  @override
  final String name;
  @override
  Uri get uri => file.uri;
  @override
  Never get xFile =>
      throw UnsupportedError('This picker uses its bounded disk stream');
  @override
  int lengthSync() => file.lengthSync();
  @override
  Future<int?> length() async => file.length();
  @override
  Future<Uint8List> readAsBytes() => file.readAsBytes();
  @override
  Stream<Uint8List> readAsByteStream() =>
      file.openRead().map(Uint8List.fromList);
}
