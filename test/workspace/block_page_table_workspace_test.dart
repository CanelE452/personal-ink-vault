import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/vault/block_page_document.dart';
import 'package:saber/data/vault/block_page_snapshot.dart';
import 'package:saber/data/vault/block_page_table.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/workspace/block_page_editor.dart';
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

  void stage(String value) => debugPrintSynchronously('PIV_TABLE_STUDY $value');

  setUp(() async {
    directoryCreated = false;
    repositoryOpen = false;
    previousPicker = FilePickerPlatform.instance;
    stage('setup.file-manager.start');
    await FileManager.init(shouldWatchRootDirectory: false)
        .timeout(const Duration(seconds: 20));
    stage('setup.directory.start');
    directory = await Directory.systemTemp
        .createTemp('page-table-workspace-')
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
      'The table page did not finish saving',
    );
  }

  BlockPageBlock currentBlock(WidgetTester tester) => tester
      .state<BlockPageEditorState>(find.byType(BlockPageEditor))
      .document
      .blocks
      .singleWhere((block) => block.type == 'table');
  BlockPageTable currentTable(WidgetTester tester) =>
      currentBlock(tester).table!;

  Future<void> tapKey(WidgetTester tester, String key) async {
    final target = find.byKey(ValueKey(key));
    await tester.ensureVisible(target);
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  Future<void> chooseMenu(WidgetTester tester, String key, String label) async {
    await tapKey(tester, key);
    final choice = find.text(label).last;
    await tester.ensureVisible(choice);
    await tester.tap(choice);
    await tester.pumpAndSettle();
  }

  Future<void> editCell(
    WidgetTester tester,
    String blockId,
    String cellId,
    String text,
  ) async {
    final field = find.byKey(ValueKey('block-table-cell-$blockId-$cellId'));
    await tester.ensureVisible(field);
    await tester.enterText(field, text);
    await tester.pump();
  }

  testWidgets(
    'Flutter host StudyWorkspace saves table edits and stable cell identities through library navigation and a cold vault reopen',
    (tester) async {
      tester.view.physicalSize = const Size(1100, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(() => tester.pumpWidget(const SizedBox()));
      const summary = '별도 Markdown 정리 😀\n표 내용과 독립된 요약';
      const firstText = '한글 😀\n첫 행 | 원문';
      const addedText = '추가 셀 ②\n保存 café';
      const caption = '강의 비교 표';
      final opaque = Uint8List.fromList([0, 255, 99, 13, 10, 7]);
      final futureMetadata = <String, Object?>{
        'keep': '미래 데이터 😀',
        'flags': [1, true, null],
      };
      late VaultNote note;
      late RevisionRecord seedEdition, markdownHead;
      late Map<String, Uint8List> seedFiles, markdownFiles;
      try {
        await readWhilePumping<void>(tester, 'fixture.prepare', () async {
          note = await controller.createNote(
            '표 작업공간 검증',
            documentKind: VaultDocumentKind.page,
          );
          final session = controller.activeSession!;
          final empty = await controller.loadBlockPage(session: session);
          await session.saveInk({
            'page.json': Uint8List.fromList(
              utf8.encode(
                jsonEncode({
                  ...empty.toJson(),
                  'futurePageMetadata': futureMetadata,
                }),
              ),
            ),
            'future/original.bin': opaque,
          });
          controller.editMarkdown(summary);
          await controller.flush();
          seedEdition = (await controller.repository.heads(note.inkEntityId))
              .single;
          seedFiles = await controller.repository.readFiles(seedEdition);
          markdownHead = (await controller.repository.heads(
            note.markdownEntityId,
          )).single;
          markdownFiles = await controller.repository.readFiles(markdownHead);
        });
        await mount(tester);
        await waitFor(
          tester,
          () => find.byType(BlockPageEditor).evaluate().length == 1,
          'The empty page did not open in StudyWorkspace',
        );
        await tester.tap(find.byTooltip('블록 추가'));
        await tester.pumpAndSettle();
        final createTable = find.text('표').last;
        await tester.ensureVisible(createTable);
        await tester.tap(createTable);
        await waitFor(
          tester,
          () =>
              tester
                  .state<BlockPageEditorState>(find.byType(BlockPageEditor))
                  .document
                  .blocks
                  .where((block) => block.type == 'table')
                  .length ==
              1,
          'Creating a table did not reach the real page editor',
        );
        final blockId = currentBlock(tester).id;
        final originalTable = currentTable(tester);
        expect(originalTable.rowCount, 2);
        expect(originalTable.columnCount, 2);
        final firstRowId = originalTable.rows.first.id;
        final removedRowId = originalTable.rows.last.id;
        final firstColumnId = originalTable.columns.first;
        final removedColumnId = originalTable.columns.last;
        final firstCellId = originalTable.rows.first.cells.first.id;
        final otherCellId = originalTable.rows.first.cells.last.id;
        await editCell(tester, blockId, firstCellId, firstText);
        await editCell(tester, blockId, otherCellId, '이전 판본의 셀');
        await tapKey(tester, 'block-table-header-row-$blockId');
        await tapKey(tester, 'block-table-header-column-$blockId');
        expect(currentTable(tester).headerRow, isTrue);
        expect(currentTable(tester).headerColumn, isTrue);
        await saveFromUi(tester);
        final firstSaved = await readWhilePumping(
          tester,
          'snapshot.first-table',
          () async {
            final edition = (await controller.repository.heads(
              note.inkEntityId,
            )).single;
            final files = await controller.repository.readFiles(edition);
            return (
              edition: edition,
              files: files,
              snapshot: BlockPageMediaSnapshot.fromFiles(files),
            );
          },
        );
        final firstTable = firstSaved.snapshot.document.blocks.single.table!;
        expect(firstTable.rows.first.cells.first.id, firstCellId);
        expect(firstTable.rows.first.cells.first.text, firstText);
        expect(firstTable.rows.first.cells.last.text, '이전 판본의 셀');
        expect(firstSaved.files['future/original.bin'], orderedEquals(opaque));
        expect(
          firstSaved.snapshot.document.toJson()['futurePageMetadata'],
          futureMetadata,
        );

        await tapKey(tester, 'block-table-add-row-$blockId');
        expect(currentTable(tester).rowCount, 3);
        expect(currentTable(tester).rows.first.id, firstRowId);
        final addedRowId = currentTable(tester).rows.last.id;
        await tapKey(tester, 'block-table-add-column-$blockId');
        expect(currentTable(tester).columnCount, 3);
        expect(currentTable(tester).columns.first, firstColumnId);
        final addedColumnId = currentTable(tester).columns.last;
        final addedCellId = currentTable(tester).rows.last.cells.last.id;
        await editCell(tester, blockId, addedCellId, addedText);
        await chooseMenu(
          tester,
          'block-table-row-$blockId-$removedRowId',
          '행 삭제',
        );
        expect(currentTable(tester).rowCount, 2);
        await chooseMenu(
          tester,
          'block-table-column-$blockId-$removedColumnId',
          '열 삭제',
        );
        final editedTable = currentTable(tester);
        expect(editedTable.columnCount, 2);
        expect(editedTable.rows.map((row) => row.id), [firstRowId, addedRowId]);
        expect(editedTable.columns, [firstColumnId, addedColumnId]);
        expect(editedTable.rows.first.cells.first.id, firstCellId);
        expect(editedTable.rows.first.cells.first.text, firstText);
        expect(editedTable.rows.last.cells.last.id, addedCellId);
        expect(editedTable.rows.last.cells.last.text, addedText);
        expect(
          editedTable.rows.expand((row) => row.cells).map((cell) => cell.id),
          isNot(contains(otherCellId)),
        );
        final captionField = find.byKey(ValueKey('block-text-$blockId'));
        await tester.ensureVisible(captionField);
        await tester.enterText(captionField, caption);
        final expectedTableJson = currentTable(tester).toJson();
        await saveFromUi(tester);
        final finalSaved = await readWhilePumping(
          tester,
          'snapshot.final-table',
          () async {
            final edition = (await controller.repository.heads(
              note.inkEntityId,
            )).single;
            final files = await controller.repository.readFiles(edition);
            return (
              edition: edition,
              files: files,
              snapshot: BlockPageMediaSnapshot.fromFiles(files),
              firstEditionFiles: await controller.repository.readFiles(
                firstSaved.edition,
              ),
            );
          },
        );
        expect(
          finalSaved.edition.revisionId,
          isNot(firstSaved.edition.revisionId),
        );
        expect(
          finalSaved.snapshot.document.blocks.single.table!.toJson(),
          expectedTableJson,
        );
        expect(finalSaved.snapshot.document.blocks.single.text, caption);
        expect(finalSaved.files['future/original.bin'], orderedEquals(opaque));
        expect(finalSaved.firstEditionFiles, firstSaved.files);

        await tester.tap(editorButton('문서 목록으로'));
        await waitFor(
          tester,
          () =>
              controller.activeSession == null &&
              find.byType(BlockPageEditor).evaluate().isEmpty &&
              find.byType(LibraryHome).evaluate().isNotEmpty,
          'The saved table page did not return to its library',
        );
        await tester.pumpWidget(const SizedBox());
        await readWhilePumping<void>(
          tester,
          'repository.cold-restart',
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
          'The cold repository did not show its library',
        );
        final reopenedNote = await readWhilePumping(
          tester,
          'library.read-note',
          () async => (await controller.store.list()).singleWhere(
            (entry) => entry.id == note.id,
          ),
        );
        final tile = find.byKey(
          ValueKey('library-note-${reopenedNote.revision.revisionId}'),
        );
        await tester.ensureVisible(tile);
        await tester.tap(tile);
        await waitFor(
          tester,
          () =>
              find.byType(BlockPageEditor).evaluate().length == 1 &&
              find.byKey(ValueKey('block-table-$blockId')).evaluate().length ==
                  1 &&
              find.byType(CircularProgressIndicator).evaluate().isEmpty,
          'The persisted table did not reopen through StudyWorkspace',
        );
        final reopenedTable = currentTable(tester);
        expect(currentBlock(tester).id, blockId);
        expect(reopenedTable.toJson(), expectedTableJson);
        expect(reopenedTable.headerRow, isTrue);
        expect(reopenedTable.headerColumn, isTrue);
        expect(reopenedTable.rows.first.cells.first.id, firstCellId);
        expect(reopenedTable.rows.last.cells.last.id, addedCellId);
        expect(
          tester
              .widget<Checkbox>(
                find.byKey(ValueKey('block-table-header-row-$blockId')),
              )
              .value,
          isTrue,
        );
        expect(
          tester
              .widget<Checkbox>(
                find.byKey(ValueKey('block-table-header-column-$blockId')),
              )
              .value,
          isTrue,
        );
        expect(
          tester
              .widget<TextField>(
                find.byKey(ValueKey('block-table-cell-$blockId-$firstCellId')),
              )
              .controller!
              .text,
          firstText,
        );
        expect(
          tester
              .widget<TextField>(
                find.byKey(ValueKey('block-table-cell-$blockId-$addedCellId')),
              )
              .controller!
              .text,
          addedText,
        );
        expect(
          tester.widget<TextField>(captionField).controller!.text,
          caption,
        );
        final cold = await readWhilePumping(tester, 'snapshot.cold', () async {
          final snapshot = await controller.loadBlockPageSnapshot(
            session: controller.activeSession!,
          );
          final current = (await controller.repository.heads(note.inkEntityId))
              .single;
          final summaryEdition = (await controller.repository.heads(
            note.markdownEntityId,
          )).single;
          final editions = await controller.repository.revisions();
          final oldTable = editions.singleWhere(
            (edition) => edition.revisionId == firstSaved.edition.revisionId,
          );
          final oldSeed = editions.singleWhere(
            (edition) => edition.revisionId == seedEdition.revisionId,
          );
          return (
            snapshot: snapshot,
            revisionId: current.revisionId,
            markdown: controller.markdown,
            summaryRevisionId: summaryEdition.revisionId,
            summaryFiles: await controller.repository.readFiles(summaryEdition),
            firstEditionFiles: await controller.repository.readFiles(oldTable),
            seedFiles: await controller.repository.readFiles(oldSeed),
          );
        });
        expect(cold.revisionId, finalSaved.edition.revisionId);
        expect(
          cold.snapshot.document.blocks.single.table!.toJson(),
          expectedTableJson,
        );
        expect(
          cold.snapshot.document.toJson()['futurePageMetadata'],
          futureMetadata,
        );
        expect(
          cold.snapshot.files['future/original.bin'],
          orderedEquals(opaque),
        );
        expect(cold.markdown, summary);
        expect(cold.summaryRevisionId, markdownHead.revisionId);
        expect(cold.summaryFiles, markdownFiles);
        expect(cold.firstEditionFiles, firstSaved.files);
        expect(cold.seedFiles, seedFiles);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        if (repositoryOpen) {
          await readWhilePumping<void>(tester, 'repository.finish', () async {
            try {
              await controller.flush();
            } finally {
              controller.dispose();
              await controller.repository.close();
              repositoryOpen = false;
            }
          });
        }
      }
    },
    // Flutter host widget behavior with disk storage; this is not S9+/JNI execution.
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );
}
