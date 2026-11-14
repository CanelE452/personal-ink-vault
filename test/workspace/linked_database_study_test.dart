import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/native/ink_vault_native.dart';
import 'package:saber/data/vault/block_page_document.dart';
import 'package:saber/data/vault/workspace_database.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/workspace/block_page_editor.dart';
import 'package:saber/pages/workspace/database_editor.dart';
import 'package:saber/pages/workspace/linked_database_block.dart';
import 'package:saber/pages/workspace/study_workspace.dart';

import '../utils/test_mock_channel_handlers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();
  setupMockPathProvider();
  setupMockPrinting();
  setupMockWindowManager();

  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    testWidgets(
      'Study dashboard saves then opens the exact foreign view on $platform',
      (tester) async {
        tester.view.physicalSize = const Size(1100, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final fixture = await _io(tester, 'dashboard-fixture', () async {
          final study = await _StudyFixture.create(useNative: true);
          final c = study.controller;
          await c.openNote(study.source);
          final sourceSession = c.activeSession!;
          final database = await c.loadDatabase(session: sourceSession);
          final sourceView = DatabaseView.create(
            name: '선택한 외부 목록',
            type: 'list',
          );
          await c.saveDatabase(
            database.addView(sourceView),
            session: sourceSession,
          );
          final sourceHead = (await study.repository.heads(
            study.source.inkEntityId,
          )).single;
          final owner = await c.createNote(
            '통합 DB',
            documentKind: VaultDocumentKind.database,
          );
          final ownerSession = c.activeSession!;
          final ownerDatabase = await c.loadDatabase(session: ownerSession);
          final dashboard = DatabaseView.create(
            name: '통합 보기',
            type: databaseDashboardViewType,
          );
          await c.saveDatabase(
            ownerDatabase.copyWith(
              views: [ownerDatabase.views.single, dashboard],
            ),
            session: ownerSession,
          );
          c.query = owner.title;
          await c.refresh();
          return (
            study: study,
            owner: owner,
            sourceView: sourceView,
            dashboard: dashboard,
            sourceHead: sourceHead,
          );
        });
        final study = fixture.study;
        final c = study.controller;
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
          await _io(tester, 'dashboard-cleanup', study.dispose);
        });
        await tester.pumpWidget(
          TranslationProvider(
            child: MaterialApp(home: StudyWorkspace(controller: c)),
          ),
        );
        final editor = find.byType(DatabaseEditor);
        Finder historyButton(String tooltip) => find.byWidgetPredicate(
          (widget) => widget is IconButton && widget.tooltip == tooltip,
        );
        bool enabled(Finder button) =>
            button.evaluate().length == 1 &&
            tester.widget<IconButton>(button).onPressed != null;
        await _waitFor(
          tester,
          () =>
              editor.evaluate().length == 1 &&
              tester
                  .widget<DatabaseEditor>(editor)
                  .databases
                  .containsKey(study.source.id),
          'The canonical foreign database did not load',
        );
        await tester.tap(
          find.byKey(ValueKey('db-view-${fixture.dashboard.id}')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('대시보드 위젯 추가'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(
            ValueKey(
              'db-dashboard-add-${study.source.id}-${fixture.sourceView.id}',
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 350));
        expect(find.text('원본 자료 행'), findsOneWidget);
        expect(c.dirty, isTrue);
        await tester.tap(find.text('원본 보기 열기'));
        await _waitFor(
          tester,
          () =>
              c.activeSession?.note.id == study.source.id &&
              find
                      .byKey(const ValueKey('db-view-body-list'))
                      .evaluate()
                      .length ==
                  1,
          'Opening the dashboard card did not select the exact foreign list',
        );
        expect(c.navigation.current.databaseViewId, fixture.sourceView.id);
        expect(c.navigation.peekBack?.databaseViewId, fixture.dashboard.id);
        final back = historyButton('이전 위치');
        final forward = historyButton('다음 위치');
        await _waitFor(tester, () => enabled(back), 'Back stayed disabled');
        await tester.tap(back);
        await _waitFor(
          tester,
          () =>
              c.activeSession?.note.id == fixture.owner.id && enabled(forward),
          'Back did not return to the dashboard document',
        );
        expect(c.navigation.current.databaseViewId, fixture.dashboard.id);
        await _waitFor(
          tester,
          () =>
              c.activeSession?.note.id == fixture.owner.id &&
              find
                      .byKey(const ValueKey('db-view-body-dashboard'))
                      .evaluate()
                      .length ==
                  1 &&
              find.text('원본 자료 행').evaluate().length == 1,
          'Back did not restore the saved dashboard and its external reference',
        );
        await tester.tap(forward);
        await _waitFor(
          tester,
          () =>
              c.activeSession?.note.id == study.source.id &&
              find
                      .byKey(const ValueKey('db-view-body-list'))
                      .evaluate()
                      .length ==
                  1,
          'Forward did not restore the exact foreign list',
        );
        final sourceHead = await _io(
          tester,
          'dashboard-source-head',
          () async =>
              (await study.repository.heads(study.source.inkEntityId)).single,
        );
        expect(sourceHead.revisionId, fixture.sourceHead.revisionId);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(platform),
    );
    testWidgets(
      'Study linked DB selection ignores library search on $platform',
      (tester) async {
        tester.view.physicalSize = const Size(1100, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final fixture = await _io(tester, 'fixture', _StudyFixture.create);
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
          await _io(tester, 'cleanup', fixture.dispose);
        });
        expect(fixture.controller.query, '선택한 대시보드');
        expect(fixture.controller.notes.map((note) => note.id), [
          fixture.page.id,
        ]);
        await tester.pumpWidget(
          TranslationProvider(
            child: MaterialApp(
              home: StudyWorkspace(controller: fixture.controller),
            ),
          ),
        );
        await _waitFor(
          tester,
          () => find.byType(BlockPageEditor).evaluate().length == 1,
          'The real Study page did not finish loading',
        );
        final pageWidget = tester.widget<BlockPageEditor>(
          find.byType(BlockPageEditor),
        );
        expect(
          pageWidget.databaseNotes.map((note) => note.id),
          contains(fixture.source.id),
          reason: 'The current library search must not hide a valid DB from the linked-block picker',
        );
        expect(
          pageWidget.databaseNotes
              .singleWhere((note) => note.id == fixture.source.id)
              .title,
          fixture.source.title,
        );
        expect(pageWidget.linkedDatabaseAccess, isNotNull);
        await tester.tap(find.byTooltip('블록 추가'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('연결된 데이터베이스').last);
        await _waitFor(
          tester,
          () => find.text('연결할 데이터베이스').evaluate().isNotEmpty,
          'The linked DB menu did not open its source picker',
        );
        final sourceChoice = find.descendant(
          of: find.byType(SimpleDialog),
          matching: find.text(fixture.source.title),
        );
        expect(sourceChoice, findsOneWidget);
        await tester.tap(sourceChoice);
        await _waitFor(
          tester,
          () =>
              find.byType(LinkedDatabaseBlock).evaluate().length == 1 &&
              find.byType(CircularProgressIndicator).evaluate().isEmpty,
          'Selecting the hidden library source did not create a live linked DB',
        );
        final pageState = tester.state<BlockPageEditorState>(
          find.byType(BlockPageEditor),
        );
        final linked = pageState.document.blocks.singleWhere(
          (block) => block.type == 'linkedDatabase',
        );
        expect(linked.linkedDatabase!.noteId, fixture.source.id);
        expect(find.text('원본 자료 행'), findsOneWidget);
        final save = find
            .descendant(
              of: find.byType(BlockPageEditor),
              matching: find.byWidgetPredicate(
                (widget) => widget is IconButton && widget.tooltip == '저장',
              ),
            )
            .first;
        await _waitFor(
          tester,
          () => tester.widget<IconButton>(save).onPressed != null,
          'The page save action did not become available',
        );
        await tester.tap(save);
        await _waitFor(
          tester,
          () =>
              !fixture.controller.dirty &&
              find.byType(CircularProgressIndicator).evaluate().isEmpty,
          'The real Study linked reference did not finish saving',
        );
        final snapshot = await _io(tester, 'saved-reference', () async {
          final pageHead = (await fixture.repository.heads(
            fixture.page.inkEntityId,
          )).single;
          final files = await fixture.repository.readFiles(pageHead);
          final sourceHead = (await fixture.repository.heads(
            fixture.source.inkEntityId,
          )).single;
          return (
            page: BlockPageDocument.fromJson(
              Map<String, dynamic>.from(
                jsonDecode(utf8.decode(files['page.json']!)) as Map,
              ),
            ),
            sourceHead: sourceHead,
            sourceFiles: await fixture.repository.readFiles(sourceHead),
          );
        });
        expect(
          snapshot.page.blocks.single.linkedDatabase!.noteId,
          fixture.source.id,
        );
        expect(
          snapshot.page.blocks.single.linkedDatabase!.view.name,
          '이 페이지 보기',
        );
        expect(snapshot.sourceHead.revisionId, fixture.sourceHead.revisionId);
        expect(snapshot.sourceFiles, fixture.sourceFiles);
        expect(fixture.controller.activeSession!.note.id, fixture.page.id);
        expect(fixture.controller.notes.map((note) => note.id), [
          fixture.page.id,
        ]);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(platform),
    );
  }
}

Future<T> _io<T>(
  WidgetTester tester,
  String phase,
  Future<T> Function() action,
) async {
  debugPrintSynchronously('PIV_LINKED_STUDY $phase.before');
  var done = false;
  T? value;
  Object? failure;
  StackTrace? trace;
  await tester.runAsync(() async {
    unawaited(
      Future<T>.sync(action)
          .timeout(const Duration(seconds: 20))
          .then<void>(
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
  final elapsed = Stopwatch()..start();
  while (!done) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1)),
    );
    await tester.pump(const Duration(milliseconds: 20));
    if (elapsed.elapsed > const Duration(seconds: 25))
      fail('Study linked DB IO did not complete');
  }
  if (failure != null) Error.throwWithStackTrace(failure!, trace!);
  debugPrintSynchronously('PIV_LINKED_STUDY $phase.after');
  return value as T;
}

Future<void> _waitFor(
  WidgetTester tester,
  bool Function() ready,
  String reason,
) async {
  final elapsed = Stopwatch()..start();
  while (!ready()) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1)),
    );
    await tester.pump(const Duration(milliseconds: 20));
    if (elapsed.elapsed > const Duration(seconds: 20)) fail(reason);
  }
  await tester.pump();
}

class _StudyFixture {
  new(
    this.directory,
    this.repository,
    this.controller,
    this.source,
    this.page,
    this.sourceHead,
    this.sourceFiles,
  );
  final Directory directory;
  final NoteRepository repository;
  final WorkspaceController controller;
  final VaultNote source, page;
  final RevisionRecord sourceHead;
  final Map<String, Uint8List> sourceFiles;

  Future<void> dispose() async {
    controller.dispose();
    await repository.close();
    final temporaryRoot = await Directory.systemTemp.resolveSymbolicLinks();
    final owned = await directory.resolveSymbolicLinks();
    expect(p.isWithin(temporaryRoot, owned), isTrue);
    expect(p.basename(owned), startsWith('linked-db-study-'));
    await directory.delete(recursive: true);
  }

  static Future<_StudyFixture> create({bool useNative = false}) async {
    await FileManager.init(shouldWatchRootDirectory: false);
    final directory = await Directory.systemTemp.createTemp('linked-db-study-');
    final repository = await NoteRepository.open(
      Directory(p.join(directory.path, 'vault')),
      createFormatVersion: 2,
    );
    final libraryPath = Platform.environment['INK_VAULT_NATIVE_LIBRARY'];
    final controller = WorkspaceController(
      repository,
      native: useNative && libraryPath != null
          ? InkVaultNative.open(libraryPath: libraryPath)
          : null,
      directoryProvider: () async =>
          Directory(p.join(directory.path, 'support')),
    );
    final source = await controller.createNote(
      '공유 자료 DB',
      documentKind: VaultDocumentKind.database,
    );
    final database = await controller.loadDatabase(
      session: controller.activeSession!,
    );
    await controller.saveDatabase(
      database.addRow(
        DatabaseRow.create(values: {database.properties.single.id: '원본 자료 행'}),
      ),
      session: controller.activeSession!,
    );
    final sourceHead = (await repository.heads(source.inkEntityId)).single;
    final sourceFiles = await repository.readFiles(sourceHead);
    final page = await controller.createNote(
      '선택한 대시보드',
      documentKind: VaultDocumentKind.page,
    );
    controller.query = '선택한 대시보드';
    await controller.refresh();
    return _StudyFixture(
      directory,
      repository,
      controller,
      source,
      page,
      sourceHead,
      sourceFiles,
    );
  }
}
