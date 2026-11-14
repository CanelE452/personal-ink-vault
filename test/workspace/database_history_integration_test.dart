import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/vault/workspace_database.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/workspace/database_editor.dart';
import 'package:saber/pages/workspace/study_workspace.dart';

import '../utils/test_mock_channel_handlers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();
  setupMockPathProvider();
  setupMockPrinting();
  setupMockWindowManager();

  testWidgets('database toolbar compares and restores a saved version', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 820));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final fixture = (await tester.runAsync(() async {
      await FileManager.init(shouldWatchRootDirectory: false);
      final root = await Directory.systemTemp.createTemp(
        'database-history-ui-',
      );
      final repository = await NoteRepository.open(
        root,
        createFormatVersion: 2,
      );
      final controller = WorkspaceController(repository);
      final note = await controller.createNote(
        'History database',
        documentKind: VaultDocumentKind.database,
      );
      final session = controller.activeSession!;
      final initial = await controller.loadDatabase(session: session);
      final title = initial.properties.single.id;
      final original = initial.addRow(
        DatabaseRow.create(values: {title: '원래 행'}),
      );
      await controller.saveDatabase(original, session: session);
      final old = (await repository.heads(note.inkEntityId)).single;
      final latest = original.addRow(
        DatabaseRow.create(values: {title: '추가한 행'}),
      );
      await controller.saveDatabase(latest, session: session);
      final current = (await repository.heads(note.inkEntityId)).single;
      return (root, repository, controller, note, old, current);
    }))!;
    final (root, repository, controller, note, old, current) = fixture;
    try {
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(home: StudyWorkspace(controller: controller)),
        ),
      );
      final open = find.byTooltip('데이터베이스 이력');
      await _until(tester, () => find.text('추가한 행').evaluate().isNotEmpty);

      expect(
        tester.takeException(),
        isNull,
        reason: 'The workspace actions must fit in the 320px app bar.',
      );
      final appBar = find.byType(AppBar);
      final title = find.descendant(
        of: appBar,
        matching: find.text(note.title),
      );
      final back = find.byKey(const ValueKey('workspace-back-to-library'));
      final save = find.byTooltip('기기에 저장');
      final export = find.byKey(const ValueKey('portable-export-menu'));
      final more = find.byKey(const ValueKey('workspace-more-actions'));
      expect(title, findsOneWidget);
      expect(tester.getSize(title).width, greaterThan(0));
      expect(find.byTooltip('더 많은 작업'), findsOneWidget);
      for (final action in [back, save, export, more]) {
        expect(action.hitTestable(), findsOneWidget);
        final bounds = tester.getRect(action);
        expect(bounds.left, greaterThanOrEqualTo(0));
        expect(bounds.right, lessThanOrEqualTo(320));
      }

      await tester.runAsync(() => tester.tap(save));
      await tester.pump();
      await _until(
        tester,
        () => find.byType(LinearProgressIndicator).evaluate().isEmpty,
      );
      expect(controller.activeSession?.note.id, note.id);

      await tester.tap(export);
      await tester.pumpAndSettle();
      expect(find.text('CSV'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('CSV'), findsNothing);

      await tester.tap(more);
      await tester.pumpAndSettle();
      for (final label in [
        '빠른 문서 전환',
        '북마크',
        '다른 AI 연결 · MCP',
        '현재 페이지 링크 복사',
        '노트 링크 열기',
      ]) {
        expect(find.text(label), findsOneWidget);
      }
      await tester.binding.setSurfaceSize(const Size(700, 820));
      await tester.pumpAndSettle();
      expect(more, findsNothing);
      await tester.tap(find.text('노트 링크 열기'));
      final linkDialog = find.text('inkvault 링크 열기');
      final cancelLink = find.widgetWithText(TextButton, '취소');
      await _until(tester, () => cancelLink.hitTestable().evaluate().isNotEmpty);
      expect(linkDialog, findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        ),
        findsOneWidget,
      );
      await tester.tap(cancelLink);
      await _until(tester, () => linkDialog.evaluate().isEmpty);
      await tester.binding.setSurfaceSize(const Size(320, 820));
      await tester.pump();

      expect(open, findsOneWidget);
      await tester.tap(open);
      final selected = find.byKey(
        ValueKey('database-history-revision-${old.revisionId}'),
      );
      await _until(tester, () => selected.evaluate().isNotEmpty);
      final restore = find.byKey(const ValueKey('database-history-restore'));
      expect(tester.widget<FilledButton>(restore).onPressed, isNull);
      await tester.ensureVisible(selected);
      await tester.tap(selected);
      await _until(
        tester,
        () => tester.widget<FilledButton>(restore).onPressed != null,
      );
      expect(find.text('선택한 판본 → 현재 저장본'), findsOneWidget);
      expect(
        find.descendant(of: find.byType(Dialog), matching: find.text('추가한 행')),
        findsOneWidget,
      );

      await tester.tap(restore);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text('판본 복원'), findsOneWidget);
      expect(find.textContaining('새 판본'), findsOneWidget);
      await tester.tap(find.text('취소'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(controller.activeSession!.inkParents, [current.revisionId]);

      await tester.tap(restore);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.tap(find.byKey(const ValueKey('database-history-confirm')));
      await _until(tester, () => restore.evaluate().isEmpty);
      await _until(tester, () => find.text('원래 행').evaluate().isNotEmpty);
      expect(find.text('추가한 행'), findsNothing);
      final head = (await _readWhilePumping(
        tester,
        () => repository.heads(note.inkEntityId),
      )).single;
      expect(head.revisionId, isNot(old.revisionId));
      expect(head.parentRevisionIds, [current.revisionId]);
      await tester.runAsync(() => tester.tap(back));
      await _until(tester, () => controller.activeSession == null);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      await _readWhilePumping(tester, () async {
        await repository.close();
        await root.delete(recursive: true);
        return true;
      });
    }
  });

  testWidgets(
    'history action is reserved for a database owner with a handler',
    (tester) async {
      final database = WorkspaceDatabase.empty();
      var opened = 0;
      void openHistory() => opened++;
      Future<void> mount({bool embedded = false, VoidCallback? onHistory}) =>
          tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: DatabaseEditor(
                  initialDatabase: database,
                  onSave: (_) async {},
                  onBack: () {},
                  embedded: embedded,
                  onHistory: onHistory,
                ),
              ),
            ),
          );

      final button = find.byTooltip('데이터베이스 이력');
      await mount();
      expect(button, findsNothing);
      await mount(embedded: true, onHistory: openHistory);
      expect(button, findsNothing);
      await mount(onHistory: openHistory);
      await tester.tap(button);
      expect(opened, 1);
    },
  );
}

Future<T> _readWhilePumping<T>(
  WidgetTester tester,
  Future<T> Function() read,
) async {
  var done = false;
  T? value;
  Object? failure;
  StackTrace? trace;
  await tester.runAsync(() async {
    read().then(
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
  await _until(tester, () => done);
  if (failure != null) Error.throwWithStackTrace(failure!, trace!);
  return value as T;
}

Future<void> _until(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 150 && !ready(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 12)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(ready(), isTrue);
}
