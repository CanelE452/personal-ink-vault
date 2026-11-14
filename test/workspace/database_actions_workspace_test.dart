import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/native/ink_vault_native.dart';
import 'package:saber/data/vault/database_actions.dart';
import 'package:saber/data/vault/workspace_database.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/workspace/database_automations_panel.dart';
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
  final libraryPath =
      Platform.environment['INK_VAULT_NATIVE_LIBRARY'] ??
      File('build/native/windows/ink_vault_native.dll').absolute.path;
  final available = Platform.isWindows && File(libraryPath).existsSync();

  Future<void> drain(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(() async {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 15));
      });
    }
    await tester.pump(const Duration(milliseconds: 350));
  }

  Future<void> waitFor(
    WidgetTester tester,
    bool Function() ready,
    String reason,
  ) async {
    for (var i = 0; i < 80 && !ready(); i++) {
      await drain(tester);
    }
    expect(ready(), isTrue, reason: reason);
  }

  Future<T> readWhilePumping<T>(
    WidgetTester tester,
    Future<T> Function() read,
  ) async {
    var done = false;
    T? value;
    Object? failure;
    StackTrace? trace;
    await tester.runAsync(() async {
      read()
          .timeout(const Duration(seconds: 15))
          .then(
            (result) {
              value = result;
              done = true;
            },
            onError: (Object error, StackTrace stack) {
              failure = error;
              trace = stack;
              done = true;
            },
          );
    });
    await waitFor(
      tester,
      () => done,
      'Repository IO must finish while frames run.',
    );
    if (failure != null) Error.throwWithStackTrace(failure!, trace!);
    return value as T;
  }

  Future<void> tap(WidgetTester tester, Finder finder) async {
    expect(finder, findsOneWidget);
    await tester.ensureVisible(finder);
    await tester.pump(const Duration(milliseconds: 350));
    expect(finder.hitTestable(), findsOneWidget);
    await tester.runAsync(() => tester.tap(finder.hitTestable()));
    await drain(tester);
  }

  testWidgets(
    'Study home creates a database whose Rust button row and receipt survive parent back and reopen',
    (tester) async {
      Directory? root;
      WorkspaceController? owner;
      tester.view.physicalSize = const Size(1280, 1000);
      tester.view.devicePixelRatio = 1;
      try {
        await tester.runAsync(() async {
          await FileManager.init(shouldWatchRootDirectory: false);
          root = await Directory.systemTemp.createTemp('actions-workspace-');
          owner = WorkspaceController(
            await NoteRepository.open(root!, createFormatVersion: 2),
            native: InkVaultNative.open(libraryPath: libraryPath),
          );
          await owner!.refresh();
        });
        final controller = owner!;
        final runtime = DatabaseActionRuntime(
          deviceId: controller.repository.deviceId,
          invoke: controller.native!.invoke,
        );
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        await tester.pumpWidget(
          TranslationProvider(
            child: MaterialApp(home: StudyWorkspace(controller: controller)),
          ),
        );
        await waitFor(
          tester,
          () => find.byType(LibraryHome).evaluate().length == 1,
          'Study must show its real document home.',
        );
        await tap(tester, find.byKey(const ValueKey('library-create-button')));
        await tap(
          tester,
          find.descendant(
            of: find.byType(PopupMenuItem<LibraryCreateAction>),
            matching: find.text('데이터베이스'),
          ),
        );
        await waitFor(
          tester,
          () => find.byType(AlertDialog).evaluate().length == 1,
          'Database creation must request a document name.',
        );
        await tester.enterText(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(TextField),
          ),
          '연구 작업',
        );
        await tap(tester, find.text('확인'));
        await waitFor(
          tester,
          () => find.byType(DatabaseEditor).evaluate().length == 1,
          'Study must mount its database editor after home creation. error=${controller.error}',
        );
        final parentBack = find
            .ancestor(
              of: find.descendant(
                of: find.byType(AppBar),
                matching: find.byTooltip('문서 목록으로'),
              ),
              matching: find.byType(IconButton),
            )
            .first;
        await waitFor(
          tester,
          () =>
              parentBack.evaluate().length == 1 &&
              tester.widget<IconButton>(parentBack).onPressed != null,
          'The home creation operation must finish before opening child tools.',
        );
        final note = controller.activeSession!.note;
        expect(note.documentKind, VaultDocumentKind.database);
        expect(note.title, '연구 작업');
        final initialRevision = controller.activeSession!.inkParents.single;
        final editor = tester.widget<DatabaseEditor>(
          find.byType(DatabaseEditor),
        );
        expect(editor.actionRuntime, isNotNull);
        expect(editor.queryRuntime, isNotNull);
        await tap(tester, find.byTooltip('버튼·자동화'));
        await waitFor(
          tester,
          () => find.byType(DatabaseAutomationsPanel).evaluate().length == 1,
          'Study must make its actual native automation panel reachable.',
        );
        await tap(tester, find.byKey(const ValueKey('actions-create-rule')));
        await tester.enterText(
          find.byKey(const ValueKey('actions-rule-name')),
          '연구 항목 추가',
        );
        await tap(tester, find.byKey(const ValueKey('actions-save')));
        await waitFor(
          tester,
          () =>
              controller.activeSession!.inkParents.single != initialRevision &&
              find.byType(LinearProgressIndicator).evaluate().isEmpty,
          'The rule definition must be committed before execution.',
        );
        final definition = await readWhilePumping(
          tester,
          () => controller.loadDatabase(session: controller.activeSession!),
        );
        final rule = runtime.rules(definition).single;
        final ruleId = rule['id'] as String;
        final action = (rule['actions'] as List).cast<Map>().single;
        final titleId = definition.properties.single.id;
        expect(definition.id, note.id);
        expect(definition.rows, isEmpty);
        expect(rule['name'], '연구 항목 추가');
        expect(rule['trigger'], {'type': 'manual'});
        expect(action['type'], 'addRow');
        expect(runtime.receipts(definition), isEmpty);
        final inputRevision = controller.activeSession!.inkParents.single;
        await tap(tester, find.byKey(ValueKey('actions-run-$ruleId')));
        await waitFor(
          tester,
          () => find.text('실행 결과를 저장했습니다.').evaluate().length == 1,
          'The real Rust execution must finish its canonical save. error=${controller.error}',
        );
        final resultRevision = controller.activeSession!.inkParents.single;
        expect(resultRevision, isNot(inputRevision));
        final executed = await readWhilePumping(tester, () async {
          final heads = await controller.repository.heads(note.inkEntityId);
          expect(heads, hasLength(1));
          expect(heads.single.revisionId, resultRevision);
          final files = await controller.repository.readFiles(heads.single);
          return WorkspaceDatabase.fromJson(
            jsonDecode(utf8.decode(files['database.json']!))
                as Map<String, dynamic>,
          );
        });
        expect(executed.rows, hasLength(1));
        final row = executed.rows.single;
        expect(row.values[titleId], '새 항목');
        final computed = editor.queryRuntime!.evaluate(
          executed,
          operations: [
            {'type': 'value', 'rowId': row.id, 'propertyId': titleId},
          ],
        );
        expect(computed.results, [
          {'value': '새 항목'},
        ]);
        expect(computed.errors, isEmpty);
        final receipt = runtime.receipts(executed).single;
        expect(receipt['ruleId'], ruleId);
        expect(receipt['inputRevision'], inputRevision);
        expect(receipt['deviceId'], controller.repository.deviceId);
        expect(receipt['status'], 'completed');
        expect(receipt['actionResults'], [
          {'actionId': action['id'], 'type': 'addRow', 'rowId': row.id},
        ]);
        await tap(tester, find.byTooltip('데이터베이스로'));
        await waitFor(
          tester,
          () =>
              find.byType(DatabaseAutomationsPanel).evaluate().isEmpty &&
              !controller.inkBusy,
          'Closing the panel must release its parent database owner.',
        );
        expect(
          tester
              .state<DatabaseEditorState>(find.byType(DatabaseEditor))
              .database
              .toJson(),
          executed.toJson(),
        );
        await tap(tester, parentBack);
        await waitFor(
          tester,
          () =>
              controller.activeSession == null &&
              find.byType(LibraryHome).evaluate().length == 1 &&
              find.byType(LinearProgressIndicator).evaluate().isEmpty,
          'The Study parent back button must save and return to the real home.',
        );
        expect(controller.dirty, isFalse);
        final savedNote = controller.notes.singleWhere((n) => n.id == note.id);
        await tap(
          tester,
          find.byKey(ValueKey('library-note-${savedNote.revision.revisionId}')),
        );
        await waitFor(
          tester,
          () =>
              controller.activeSession?.note.id == note.id &&
              find.byType(DatabaseEditor).evaluate().length == 1,
          'The saved home card must reopen the same database.',
        );
        final reopened = tester
            .state<DatabaseEditorState>(find.byType(DatabaseEditor))
            .database;
        expect(reopened.toJson(), executed.toJson());
        expect(controller.activeSession!.inkParents.single, resultRevision);
        expect(runtime.receipts(reopened).single, receipt);
        expect(reopened.rows.single.id, row.id);
        expect(tester.takeException(), isNull);
      } finally {
        try {
          await tester.pumpWidget(const SizedBox());
          await drain(tester);
          if (owner != null) {
            final controller = owner!;
            try {
              await readWhilePumping(tester, controller.flush);
            } finally {
              controller.dispose();
              await tester.runAsync(controller.repository.close);
            }
          }
          if (root != null) {
            await tester.runAsync(() => root!.delete(recursive: true));
          }
        } finally {
          debugDefaultTargetPlatformOverride = null;
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        }
      }
    },
    skip: !available,
  );
}
