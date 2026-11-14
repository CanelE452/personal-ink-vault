import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/native/ink_vault_native.dart';
import 'package:saber/data/vault/block_page_document.dart';
import 'package:saber/data/vault/database_actions.dart';
import 'package:saber/data/vault/database_query_native.dart';
import 'package:saber/data/vault/workspace_database.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/pages/workspace/block_page_editor.dart';
import 'package:saber/pages/workspace/database_editor.dart';
import 'package:saber/pages/workspace/linked_database_block.dart';
import 'package:saber/pages/workspace/workspace_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Fixture f;
  Future<void> prepare(WidgetTester tester) async {
    _stage('fixture.prepare.before');
    f = await _io(tester, _Fixture.create, phase: 'fixture.prepare');
    final ownedFixture = f;
    addTearDown(() async {
      _stage('fixture.cleanup.unmount.before');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      _stage('fixture.cleanup.unmount.after');
      await _io(tester, () async {
        ownedFixture.closed = true;
        ownedFixture.controller.dispose();
        _stage('fixture.cleanup.repository.before');
        await ownedFixture.repository.close();
        _stage('fixture.cleanup.repository.after');
        final temporaryRoot = await Directory.systemTemp.resolveSymbolicLinks();
        final owned = await ownedFixture.directory.resolveSymbolicLinks();
        expect(p.isWithin(temporaryRoot, owned), isTrue);
        expect(p.basename(owned), startsWith('linked-db-live-'));
        _stage('fixture.cleanup.directory.before');
        await ownedFixture.directory.delete(recursive: true);
        _stage('fixture.cleanup.directory.after');
      }, phase: 'fixture.cleanup');
    });
    _stage('fixture.prepare.after');
  }

  Future<void> mount(
    WidgetTester tester, {
    double width = 1100,
    double height = 900,
  }) async {
    tester.view.physicalSize = Size(width, height);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BlockPageEditor(
            key: f.pageKey,
            initialDocument: f.document,
            databaseNotes: [BlockPageNote(f.source.id, f.source.title)],
            linkedDatabaseAccess: f.access,
            onSave: (document) =>
                f.controller.saveBlockPage(document, session: f.owner),
            onDirtyChanged: (value) =>
                f.controller.setInkDirty(value, session: f.owner),
            onBusyChanged: (value) =>
                f.controller.setInkBusy(value, session: f.owner),
            onBack: () => f.backs++,
            autosaveDelay: const Duration(hours: 1),
          ),
        ),
      ),
    );
    await _waitFor(
      tester,
      () =>
          find.byType(CircularProgressIndicator).evaluate().isEmpty &&
          find.byType(LinkedDatabaseBlock).evaluate().isNotEmpty,
      'Linked source did not finish loading',
    );
  }

  Finder editorFor(String blockId) => find.descendant(
    of: find.byKey(ValueKey('page-block-$blockId')),
    matching: find.byType(DatabaseEditor),
  );

  DatabaseEditorState editor(WidgetTester tester, [int reference = 0]) =>
      tester.state<DatabaseEditorState>(editorFor(f.references[reference].id));

  Finder cell(String blockId, String rowId, String propertyId) =>
      find.descendant(
        of: editorFor(blockId),
        matching: find.byKey(ValueKey('db-cell-$rowId-$propertyId')),
      );

  Future<void> editScore(
    WidgetTester tester,
    int reference,
    int row,
    String text,
  ) async {
    final target = cell(
      f.references[reference].id,
      f.initial.rows[row].id,
      f.scoreId,
    );
    await tester.ensureVisible(target);
    await tester.tap(target);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('db-cell-input')), text);
    await tester.tap(find.text('닫기'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'parent Back flushes a linked row to the original DB before navigation',
    (tester) async {
      await prepare(tester);
      final oldSource = await _io(
        tester,
        () async => (await f.repository.heads(f.source.inkEntityId)).single,
      );
      final oldFiles = await _io(
        tester,
        () => f.repository.readFiles(oldSource),
      );
      await mount(tester);
      await editScore(tester, 0, 0, '8');
      await tester.tap(find.byTooltip('문서 목록으로'));
      await _waitFor(
        tester,
        () => f.backs == 1,
        'Parent Back did not finish its child source save',
      );
      final saved = await _io(tester, f.readSource);
      expect(saved.rows.first.id, f.initial.rows.first.id);
      expect(saved.rows.first.values[f.scoreId], 8);
      expect(
        saved.views.map((view) => view.toJson()).toList(),
        f.initial.views.map((view) => view.toJson()).toList(),
      );
      expect(
        await _io(tester, () => f.repository.readFiles(oldSource)),
        oldFiles,
      );
      expect(f.controller.activeSession, same(f.owner));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'linked type and filter persist in the page without publishing source data or views',
    (tester) async {
      await prepare(tester);
      final sourceHead = await _io(
        tester,
        () async =>
            (await f.repository.heads(f.source.inkEntityId)).single.revisionId,
      );
      await mount(tester);
      await tester.tap(find.byTooltip('보기 설정'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('db-filter-property')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('시간').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('db-filter-operator')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('보다 큼'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('db-filter-value')),
        '2',
      );
      await tester.tap(find.text('적용'));
      await tester.pumpAndSettle();
      expect(
        cell(f.references.single.id, f.initial.rows.first.id, f.titleId),
        findsNothing,
      );
      expect(
        cell(f.references.single.id, f.initial.rows.last.id, f.titleId),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('보기 형식'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('목록').last);
      await tester.pumpAndSettle();
      await _io(tester, () => f.pageKey.currentState!.save());
      final source = await _io(tester, f.readSource);
      final page = await _io(tester, f.readPage);
      expect(source.toJson(), f.initial.toJson());
      expect(
        (await _io(
          tester,
          () => f.repository.heads(f.source.inkEntityId),
        )).single.revisionId,
        sourceHead,
      );
      expect(page.blocks.single.linkedDatabase!.noteId, f.source.id);
      expect(page.blocks.single.linkedDatabase!.view.type, 'list');
      expect(page.blocks.single.linkedDatabase!.view.filter, {
        'propertyId': f.scoreId,
        'operator': 'gt',
        'value': 2,
      });
      expect(f.sourceSaveAttempts, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'saving one reference refreshes an idle sibling but preserves its later unsaved draft',
    (tester) async {
      await prepare(tester);
      await _io(tester, () => f.configure(referenceCount: 2));
      await mount(tester, height: 1900);
      expect(find.byType(DatabaseEditor), findsNWidgets(2));
      await editScore(tester, 0, 0, '4');
      await _io(tester, () => editor(tester, 0).save());
      await _waitFor(
        tester,
        () =>
            editorFor(f.references[1].id).evaluate().length == 1 &&
            editor(tester, 1).database.rows.first.values[f.scoreId] == 4,
        'Idle sibling kept its stale source snapshot after refresh',
      );
      f.rejectSave = (candidate) => candidate.rows.first.values[f.scoreId] == 7;
      await editScore(tester, 1, 0, '7');
      final dirtySibling = editor(tester, 1);
      await editScore(tester, 0, 1, '5');
      await _io(tester, () => editor(tester, 0).save());
      await tester.pump();
      expect(editor(tester, 1), same(dirtySibling));
      expect(dirtySibling.database.rows.first.values[f.scoreId], 7);
      final published = await _io(tester, f.readSource);
      expect(published.rows.first.values[f.scoreId], 4);
      expect(published.rows.last.values[f.scoreId], 5);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'manual refresh installs a new original DB snapshot in the live editor',
    (tester) async {
      await prepare(tester);
      await mount(tester);
      final previous = editor(tester);
      await _io(tester, () async {
        final outside = await f.controller.openLinkedDatabase(
          f.source.id,
          owner: f.owner,
        );
        await f.controller.saveLinkedDatabase(
          outside,
          outside.database.setCell(f.initial.rows.first.id, f.scoreId, 9),
        );
        outside.close();
      });
      expect(previous.database.rows.first.values[f.scoreId], 1);
      await tester.tap(find.byTooltip('연결된 데이터베이스 새로 고침'));
      await _waitFor(
        tester,
        () =>
            editorFor(f.references.single.id).evaluate().length == 1 &&
            editor(tester).database.rows.first.values[f.scoreId] == 9,
        'Reloaded source did not replace the database editor snapshot',
      );
      expect(editor(tester), isNot(same(previous)));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'missing and deleted sources stay unavailable without creating empty databases',
    (tester) async {
      await prepare(tester);
      await _io(tester, () async {
        final missing = BlockPageBlock.createLinkedDatabase(
          noteId: newId(),
          view: f.localView,
        );
        final deleted = f.references.single;
        await f.setBlocks([missing, deleted]);
        final head = (await f.repository.heads(f.source.id)).single;
        await f.repository.commit(
          entityId: f.source.id,
          kind: EntityKind.metadata,
          files: await f.repository.readFiles(head),
          parentRevisionIds: [head.revisionId],
          deleted: true,
        );
      });
      final before = await _io(tester, () => f.repository.revisions());
      await mount(tester, height: 1400);
      expect(find.textContaining('연결된 데이터베이스를 열 수 없습니다:'), findsNWidgets(2));
      expect(find.byType(DatabaseEditor), findsNothing);
      await _io(tester, () => f.pageKey.currentState!.save());
      final after = await _io(tester, () => f.repository.revisions());
      expect(
        after.map((r) => r.revisionId).toList(),
        before.map((r) => r.revisionId).toList(),
      );
      expect(
        (await _io(
          tester,
          f.readPage,
        )).blocks.map((b) => b.linkedDatabase!.noteId).toList(),
        f.document.blocks.map((b) => b.linkedDatabase!.noteId).toList(),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'failed source save keeps the page and draft until an explicit retry succeeds',
    (tester) async {
      await prepare(tester);
      f.failSaves = true;
      await mount(tester);
      await editScore(tester, 0, 0, '8');
      await tester.tap(find.byTooltip('문서 목록으로'));
      await _waitFor(
        tester,
        () => find
            .textContaining('저장하지 못했습니다. 작업 내용은 열려 있습니다.')
            .evaluate()
            .isNotEmpty,
        'Parent did not report its failed child save',
      );
      expect(f.backs, 0);
      expect(editor(tester).database.rows.first.values[f.scoreId], 8);
      expect((await _io(tester, f.readSource)).rows.first.values[f.scoreId], 1);
      f.failSaves = false;
      await tester.tap(find.text('다시 시도'));
      await _waitFor(
        tester,
        () =>
            find
                .textContaining('저장하지 못했습니다. 작업 내용은 열려 있습니다.')
                .evaluate()
                .isEmpty &&
            !f.controller.dirty,
        'Retry did not finish the child source write',
      );
      expect((await _io(tester, f.readSource)).rows.first.values[f.scoreId], 8);
      await tester.tap(find.byTooltip('문서 목록으로'));
      await _waitFor(
        tester,
        () => f.backs == 1,
        'Successful retry did not release Back',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('pending child edits block collapsing the containing toggle', (
    tester,
  ) async {
    await prepare(tester);
    await _io(tester, () => f.configure(inToggle: true));
    f.failSaves = true;
    await mount(tester);
    final toggleId = f.document.blocks.single.id;
    await editScore(tester, 0, 0, '8');
    final pending = editor(tester);
    await tester.tap(find.byKey(ValueKey('block-toggle-$toggleId')));
    await tester.pumpAndSettle();
    expect(f.pageKey.currentState!.document.blocks.single.collapsed, isFalse);
    expect(editor(tester), same(pending));
    expect(pending.database.rows.first.values[f.scoreId], 8);
    f.failSaves = false;
    await _io(tester, () => f.pageKey.currentState!.save());
    await tester.tap(find.byKey(ValueKey('block-toggle-$toggleId')));
    await tester.pumpAndSettle();
    expect(f.pageKey.currentState!.document.blocks.single.collapsed, isTrue);
    await _io(tester, () => f.pageKey.currentState!.save());
    expect((await _io(tester, f.readSource)).rows.first.values[f.scoreId], 8);
    expect(
      (await _io(
        tester,
        f.readPage,
      )).blocks.single.children.single.linkedDatabase!.noteId,
      f.source.id,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'scrolling a dirty linked block offscreen retains its editor and draft at 320px',
    (tester) async {
      await prepare(tester);
      await _io(tester, () => f.configure(trailingParagraphs: 60));
      f.failSaves = true;
      await mount(tester, width: 320, height: 900);
      await editScore(tester, 0, 0, '8');
      final pending = editor(tester);
      final list = find
          .descendant(
            of: find.byType(BlockPageEditor),
            matching: find.byType(ListView),
          )
          .first;
      final scroll = find
          .descendant(of: list, matching: find.byType(Scrollable))
          .first;
      final position = tester.state<ScrollableState>(scroll).position;
      position.jumpTo(position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(position.pixels, greaterThan(600));
      expect(
        pending.mounted,
        isTrue,
        reason: 'Sliver recycling must not discard an unsaved DB editor',
      );
      position.jumpTo(0);
      await tester.pumpAndSettle();
      expect(editor(tester), same(pending));
      expect(pending.database.rows.first.values[f.scoreId], 8);
      expect((await _io(tester, f.readSource)).rows.first.values[f.scoreId], 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'discarding a stale linked draft requires confirmation and reloads the saved original',
    (tester) async {
      await prepare(tester);
      await mount(tester);
      f.failSaves = true;
      await editScore(tester, 0, 0, '8');
      final pending = editor(tester);
      final savedHead = await _io(tester, () async {
        final outside = await f.controller.openLinkedDatabase(
          f.source.id,
          owner: f.owner,
        );
        await f.controller.saveLinkedDatabase(
          outside,
          outside.database.setCell(f.initial.rows.first.id, f.scoreId, 9),
        );
        outside.close();
        return (await f.repository.heads(f.source.inkEntityId))
            .single
            .revisionId;
      });
      f.failSaves = false;
      await tester.tap(find.byTooltip('문서 목록으로'));
      await _waitFor(
        tester,
        () =>
            find.text('초안 버리고 다시 읽기').evaluate().isNotEmpty &&
            find
                .textContaining('저장하지 못했습니다. 작업 내용은 열려 있습니다.')
                .evaluate()
                .isNotEmpty,
        'Stale source failure did not offer an explicit discard and reload path',
      );
      expect(f.backs, 0);
      await tester.tap(find.text('초안 버리고 다시 읽기'));
      await tester.pumpAndSettle();
      expect(find.text('원본 DB 다시 읽기'), findsOneWidget);
      await tester.tap(find.text('취소').last);
      await tester.pumpAndSettle();
      expect(editor(tester), same(pending));
      expect(pending.database.rows.first.values[f.scoreId], 8);
      expect((await _io(tester, f.readSource)).rows.first.values[f.scoreId], 9);
      await tester.tap(find.text('초안 버리고 다시 읽기'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('초안 버리기'));
      await _waitFor(
        tester,
        () =>
            editorFor(f.references.single.id).evaluate().length == 1 &&
            editor(tester).database.rows.first.values[f.scoreId] == 9,
        'Confirmed discard did not install the saved source snapshot',
      );
      expect(
        f.pageKey.currentState!.document.blocks.single.linkedDatabase!.view
            .toJson(),
        f.document.blocks.single.linkedDatabase!.view.toJson(),
      );
      expect(
        (await _io(
          tester,
          () => f.repository.heads(f.source.inkEntityId),
        )).single.revisionId,
        savedHead,
      );
      await tester.tap(find.byTooltip('문서 목록으로'));
      await _waitFor(
        tester,
        () => f.backs == 1,
        'Discarded stale draft still blocked Back',
      );
      expect(tester.takeException(), isNull);
    },
  );

  final nativePath = Platform.environment['PIV_LINKED_DATABASE_TEST_DLL'];
  testWidgets(
    'live linked DB uses actual Rust query and action operations before disk save',
    (tester) async {
      await prepare(tester);
      final native = InkVaultNative.open(libraryPath: nativePath!);
      final operations = <String>[];
      f.nativeInvoke = (request) {
        operations.add(request['op'] as String);
        return native.invoke(request);
      };
      await mount(tester);
      await editScore(tester, 0, 0, '9');
      await _io(tester, () => f.pageKey.currentState!.save());
      expect(operations, containsAll(['workspace_query', 'workspace_actions']));
      final computed = cell(
        f.references.single.id,
        f.initial.rows.first.id,
        f.formulaId,
      );
      expect(
        find.descendant(of: computed, matching: find.text('18')),
        findsOneWidget,
      );
      expect((await _io(tester, f.readSource)).rows.first.values[f.scoreId], 9);
      final parent = f.initial.rows.first.id;
      final menu = find.byKey(ValueKey('db-row-menu-$parent'));
      await tester.ensureVisible(menu);
      await tester.tap(menu);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.tap(find.text('하위 작업 추가'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await _io(tester, () => f.pageKey.currentState!.save());
      final sourceWithSubtask = await _io(tester, f.readSource);
      final child = sourceWithSubtask.rows.singleWhere(
        (row) => sourceWithSubtask.taskLinks[row.id]?.parentId == parent,
      );
      expect(child.id, isNot(parent));
      expect(operations, contains('workspace_task_links'));
      expect(tester.takeException(), isNull);
    },
    skip: nativePath == null,
  );
}

var _ioSequence = 0;

void _stage(String name) => debugPrintSynchronously('PIV_LINKED_LIVE $name');

Future<T> _io<T>(
  WidgetTester tester,
  Future<T> Function() action, {
  String phase = 'repository',
}) async {
  final stage = '$phase.${++_ioSequence}';
  _stage('$stage.before');
  var done = false;
  T? value;
  Object? failure;
  StackTrace? trace;
  await tester.runAsync(() async {
    _stage('$stage.real-async.enter');
    unawaited(
      Future<T>.sync(() {
            _stage('$stage.action.enter');
            return action();
          })
          .timeout(const Duration(seconds: 20))
          .then<void>(
            (result) {
              _stage('$stage.action.complete');
              value = result;
              done = true;
            },
            onError: (Object error, StackTrace stack) {
              _stage('$stage.action.failed: $error');
              failure = error;
              trace = stack;
              done = true;
            },
          ),
    );
    _stage('$stage.real-async.submitted');
  });
  _stage('$stage.real-async.returned');
  final elapsed = Stopwatch()..start();
  var firstPump = true;
  var reportedSecond = 0;
  while (!done) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1)),
    );
    if (firstPump) _stage('$stage.first-pump.before');
    await tester.pump(const Duration(milliseconds: 20));
    if (firstPump) {
      _stage('$stage.first-pump.after');
      firstPump = false;
    }
    if (elapsed.elapsed.inSeconds > reportedSecond) {
      reportedSecond = elapsed.elapsed.inSeconds;
      _stage('$stage.waiting.$reportedSecond');
    }
    if (elapsed.elapsed > const Duration(seconds: 25))
      fail('Real linked database IO did not complete: $stage');
  }
  if (failure != null) {
    _stage('$stage.failed');
    Error.throwWithStackTrace(failure!, trace!);
  }
  _stage('$stage.after');
  return value as T;
}

Future<void> _waitFor(
  WidgetTester tester,
  bool Function() ready,
  String reason,
) async {
  _stage('ui.wait.before: $reason');
  final elapsed = Stopwatch()..start();
  while (!ready()) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 1)),
    );
    await tester.pump(const Duration(milliseconds: 20));
    if (elapsed.elapsed > const Duration(seconds: 20)) fail(reason);
  }
  await tester.pump();
  _stage('ui.wait.after: $reason');
}

class _Fixture {
  new(
    this.directory,
    this.repository,
    this.controller,
    this.source,
    this.owner,
    this.initial,
    this.document,
    this.references,
    this.scoreId,
    this.formulaId,
  );
  final Directory directory;
  final NoteRepository repository;
  final WorkspaceController controller;
  final VaultNote source;
  final NoteSession owner;
  final WorkspaceDatabase initial;
  BlockPageDocument document;
  List<BlockPageBlock> references;
  final String scoreId, formulaId;
  String get titleId => initial.properties.first.id;
  final pageKey = GlobalKey<BlockPageEditorState>();
  var failSaves = false, closed = false;
  var sourceSaveAttempts = 0, backs = 0;
  Map<String, dynamic> Function(Map<String, Object?>)? nativeInvoke;
  bool Function(WorkspaceDatabase)? rejectSave;

  DatabaseView get localView =>
      DatabaseView.create(name: '페이지의 자료 보기', groupBy: titleId);
  LinkedDatabaseAccess get access {
    final invoke = nativeInvoke;
    return LinkedDatabaseAccess(
      owner: owner,
      open: (noteId) => controller.openLinkedDatabase(noteId, owner: owner),
      save: (session, database, files) async {
        sourceSaveAttempts++;
        if (failSaves || rejectSave?.call(database) == true) {
          throw StateError('Synthetic linked source save failure');
        }
        await controller.saveLinkedDatabase(
          session,
          database,
          mediaFiles: files,
        );
      },
      readMedia: controller.readLinkedDatabaseRowMedia,
      isCurrent: () =>
          !closed &&
          identical(controller.activeSession, owner) &&
          identical(controller.repository, repository),
      queryRuntime: invoke == null
          ? null
          : DatabaseQueryRuntime(invoke: invoke),
      actionRuntime: invoke == null
          ? null
          : DatabaseActionRuntime(
              deviceId: repository.deviceId,
              invoke: invoke,
            ),
    );
  }

  static Future<_Fixture> create() async {
    _stage('fixture.directory.before');
    final directory = await Directory.systemTemp.createTemp('linked-db-live-');
    _stage('fixture.directory.after');
    _stage('fixture.repository.before');
    final repository = await NoteRepository.open(
      Directory(p.join(directory.path, 'vault')),
      createFormatVersion: 2,
    );
    _stage('fixture.repository.after');
    final controller = WorkspaceController(
      repository,
      directoryProvider: () async =>
          Directory(p.join(directory.path, 'support')),
    );
    _stage('fixture.source-create.before');
    final source = await controller.createNote(
      '공유 연구 자료',
      documentKind: VaultDocumentKind.database,
    );
    _stage('fixture.source-create.after');
    _stage('fixture.source-load.before');
    final empty = await controller.loadDatabase(
      session: controller.activeSession!,
    );
    _stage('fixture.source-load.after');
    final score = DatabaseProperty.create(name: '시간', type: 'number');
    final formula = DatabaseProperty.create(
      name: '두 배',
      type: 'formula',
      config: {'expression': 'prop("${score.id}") * 2'},
    );
    final initial = empty.copyWith(
      properties: [...empty.properties, score, formula],
      rows: [
        DatabaseRow.create(
          values: {empty.properties.first.id: '논문 읽기', score.id: 1},
        ),
        DatabaseRow.create(
          values: {empty.properties.first.id: '실험', score.id: 3},
        ),
      ],
    );
    _stage('fixture.source-save.before');
    await controller.saveDatabase(initial, session: controller.activeSession!);
    _stage('fixture.source-save.after');
    _stage('fixture.page-create.before');
    await controller.createNote(
      '연구 대시보드',
      documentKind: VaultDocumentKind.page,
    );
    _stage('fixture.page-create.after');
    final owner = controller.activeSession!;
    final reference = BlockPageBlock.createLinkedDatabase(
      noteId: source.id,
      view: DatabaseView.create(
        name: '페이지의 자료 보기',
        groupBy: empty.properties.first.id,
      ),
    );
    final document = const BlockPageDocument.empty().copyWith(
      blocks: [reference],
    );
    _stage('fixture.page-save.before');
    await controller.saveBlockPage(document, session: owner);
    _stage('fixture.page-save.after');
    return _Fixture(
      directory,
      repository,
      controller,
      source,
      owner,
      initial,
      document,
      [reference],
      score.id,
      formula.id,
    );
  }

  Future<void> configure({
    int referenceCount = 1,
    bool inToggle = false,
    int trailingParagraphs = 0,
  }) async {
    references = [
      for (var i = 0; i < referenceCount; i++)
        BlockPageBlock.createLinkedDatabase(noteId: source.id, view: localView),
    ];
    await setBlocks([
      if (inToggle)
        BlockPageBlock.create(
          type: 'toggle',
          text: '연구 자료',
        ).copyWith(children: references)
      else
        ...references,
      for (var i = 0; i < trailingParagraphs; i++)
        BlockPageBlock.create(type: 'paragraph', text: '계속 작성하는 문단 $i'),
    ]);
  }

  Future<void> setBlocks(List<BlockPageBlock> blocks) async {
    document = const BlockPageDocument.empty().copyWith(blocks: blocks);
    await controller.saveBlockPage(document, session: owner);
  }

  Future<WorkspaceDatabase> readSource() async {
    final head = (await repository.heads(source.inkEntityId)).single;
    final files = await repository.readFiles(head);
    return WorkspaceDatabase.fromJson(
      Map<String, dynamic>.from(
        jsonDecode(utf8.decode(files['database.json']!)) as Map,
      ),
    );
  }

  Future<BlockPageDocument> readPage() =>
      controller.loadBlockPage(session: owner);
}
