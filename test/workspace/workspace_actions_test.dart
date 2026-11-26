import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/actions/app_action_ids.dart';
import 'package:saber/data/actions/app_action_registry.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/editor/editor.dart';
import 'package:saber/pages/workspace/study_workspace.dart';

import '../utils/kit_menu_finders.dart';
import '../utils/test_mock_channel_handlers.dart';

/// The open document's actions: the editor and the workspace each publish
/// their own in the editor host's registry, the app's come through its
/// parent; the other documents' function row draws them (Task 17).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();
  setupMockPathProvider();
  setupMockPrinting();
  setupMockWindowManager();
  late Directory directory;
  late WorkspaceController controller;
  late bool closed;

  setUp(() async {
    await FileManager.init(shouldWatchRootDirectory: false);
    directory = await Directory.systemTemp.createTemp('workspace-actions-');
    controller = WorkspaceController(
      await NoteRepository.open(directory, createFormatVersion: 2),
    );
    closed = false;
    final hidden = stows.noteTabBarHidden.value;
    final shortcuts = stows.noteShortcutLayout.value;
    stows.noteTabBarHidden.value = false;
    stows.noteShortcutLayout.value = const [];
    addTearDown(() {
      stows.noteTabBarHidden.value = hidden;
      stows.noteShortcutLayout.value = shortcuts;
    });
  });

  tearDown(() async {
    if (!closed) {
      await controller.flush();
      controller.dispose();
      await controller.repository.close().timeout(const Duration(seconds: 20));
    }
    await directory.delete(recursive: true);
  });

  /// Lets the vault's file work run between frames.
  Future<void> drain(WidgetTester tester, [int cycles = 12]) async {
    await tester.runAsync(() async {
      for (var i = 0; i < cycles; i++) {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 15));
      }
    });
    await tester.pump(const Duration(milliseconds: 350));
  }

  Future<void> drainUntil(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 20 && !done(); i++) {
      await drain(tester);
    }
    expect(done(), isTrue);
  }

  Future<void> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(home: StudyWorkspace(controller: controller)),
      ),
    );
    await drain(tester, 40);
    expect(tester.takeException(), isNull);
  }

  /// Closes the vault while the test's fake time runs (the editor's last
  /// save starts when the screen goes).
  Future<void> closeWhilePumping(WidgetTester tester) async {
    var done = false;
    await tester.runAsync(() async {
      unawaited(
        () async {
          await controller.flush();
          controller.dispose();
          await controller.repository.close().timeout(
            const Duration(seconds: 20),
          );
        }().whenComplete(() => done = true),
      );
    });
    for (var i = 0; i < 80 && !done; i++) {
      await drain(tester);
    }
    closed = done;
  }

  void androidTest(String name, Future<void> Function(WidgetTester) body) {
    testWidgets(name, (tester) async {
      final previous = debugDefaultTargetPlatformOverride;
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        await body(tester);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await closeWhilePumping(tester);
        debugDefaultTargetPlatformOverride = previous;
      }
    });
  }

  Future<String> createNote(
    WidgetTester tester,
    String title, {
    VaultDocumentKind kind = VaultDocumentKind.handwriting,
  }) async => (await tester.runAsync(() async {
    await controller.createNote(title, documentKind: kind);
    return controller.activeSession!.note.id;
  }))!;

  /// The registry the open editor publishes in (the editor host's).
  AppActionRegistry documentActions(WidgetTester tester) =>
      tester.widget<AppActionScope>(find.byType(AppActionScope)).notifier!;

  Finder inRow(Finder matching) => find.descendant(
    of: find.byKey(const ValueKey('note-function-row')),
    matching: matching,
  );

  androidTest('editor and workspace publish disjoint ids', (tester) async {
    await createNote(tester, '필기');
    await mount(tester);
    final actions = documentActions(tester);
    final editor = tester.state<EditorState>(find.byType(Editor));
    final workspace = tester.state(find.byType(StudyWorkspace));
    final editorIds = actions.debugPublishedIds[editor]!;
    final workspaceIds = actions.debugPublishedIds[workspace]!;
    expect(actions.debugPublishedIds.keys, unorderedEquals([editor, workspace]));
    expect(editorIds, containsAll([AppActionIds.undo, AppActionIds.insertPage]));
    expect(
      workspaceIds,
      containsAll([AppActionIds.save, AppActionIds.quickSwitch]),
    );
    expect(editorIds.intersection(workspaceIds), isEmpty);
    expect(AppActionIds.all, containsAll(editorIds));
    expect(AppActionIds.all, containsAll(workspaceIds));
    // The app's own stay in the app registry (Task 9).
    for (final id in const [
      AppActionIds.mcp,
      AppActionIds.openNoteLink,
      AppActionIds.vaultExport,
    ]) {
      expect(workspaceIds, isNot(contains(id)), reason: id);
    }
  });

  androidTest('workspace shortcuts are registered for the open ink document', (
    tester,
  ) async {
    await createNote(tester, '필기');
    await mount(tester);
    final actions = documentActions(tester);
    expect(actions.has(AppActionIds.quickSwitch), isTrue);
    expect(
      actions.lookup(AppActionIds.quickSwitch)!.widgetKey,
      const ValueKey('workspace-quick-switch'),
    );
    expect(actions.has(AppActionIds.undo), isTrue, reason: 'the editor');
    // The app's through the parent: the workspace has its MCP access.
    expect(actions.has(AppActionIds.mcp), isTrue);
    expect(actions.parent!.has(AppActionIds.mcp), isTrue);

    await tester.tap(find.byKey(const ValueKey('workspace-back-to-library')));
    await drainUntil(tester, () => controller.activeSession == null);
    expect(find.byType(Editor), findsNothing);
    expect(actions.has(AppActionIds.quickSwitch), isFalse);
    expect(actions.has(AppActionIds.undo), isFalse);
    expect(actions.debugPublishedIds, isEmpty);
    expect(actions.has(AppActionIds.mcp), isTrue);
  });

  Future<void> openWindow(WidgetTester tester, String button) async {
    await tester.tap(find.byKey(ValueKey(button)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  androidTest('a page keeps the function row; the ink note has its items in the toolbar and ⋯', (
    tester,
  ) async {
    final ink = await createNote(tester, '필기');
    await createNote(tester, '쪽', kind: VaultDocumentKind.page);
    await mount(tester);

    // A page's 「문서 내보내기」 opens its formats on the button.
    final export = find.byKey(const ValueKey('portable-export-menu'));
    expect(inRow(export), findsOneWidget);
    await tester.tap(export);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    for (final format in const ['Markdown', 'HTML', 'PDF']) {
      expect(find.text(format), findsOneWidget, reason: format);
    }
    final button = tester.getRect(export);
    final first = tester.getRect(find.text('Markdown'));
    expect(first.left, inInclusiveRange(button.left, button.left + 48));
    expect(first.top, inInclusiveRange(button.top, button.top + 48));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await drain(tester);
    expect(find.text('HTML'), findsNothing);

    // The page's row: the workspace's shortcuts, the rest under ⋯.
    for (final tooltip in const ['이전 위치', '다음 위치', '기기에 저장', 'Markdown']) {
      expect(inRow(find.byTooltip(tooltip)), findsOneWidget, reason: tooltip);
    }
    expect(inRow(find.byKey(const ValueKey('note-view-toggle'))), findsOneWidget);
    await openWindow(tester, 'workspace-more-actions');
    for (final label in const [
      '빠른 문서 전환',
      '북마크',
      '다른 AI 연결 · MCP',
      '현재 페이지 링크 복사',
      '노트 링크 열기',
      '사용자 지정 바로가기 막대',
    ]) {
      expect(findMenuText(label), findsOneWidget, reason: label);
    }
    for (final key in const ['workspace-quick-switch', 'workspace-bookmarks']) {
      expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
    }
    // Without the engine the vault ZIP and the PDF search are not offered.
    expect(findMenuText('Obsidian 보관함 ZIP'), findsNothing);
    expect(findMenuText('PDF 본문 검색'), findsNothing);
    // A row of 더 많은 기능 runs as the window closes (this one is the
    // app's, found through the parent).
    await tester.tap(findMenuText('노트 링크 열기'));
    final cancel = find.widgetWithText(TextButton, '취소');
    await drainUntil(tester, () => cancel.hitTestable().evaluate().isNotEmpty);
    expect(find.text('inkvault 링크 열기'), findsOneWidget);
    await tester.tap(cancel);
    await drainUntil(
      tester,
      () => find.text('inkvault 링크 열기').evaluate().isEmpty,
    );

    // The ink note: no row; the editor's toolbar and ⋯ hold its items.
    await tester.runAsync(
      () => tester.tap(find.byKey(ValueKey('document-tab-$ink'))),
    );
    await drainUntil(tester, () => controller.activeSession?.note.id == ink);
    await drainUntil(tester, () => find.byType(Editor).evaluate().isNotEmpty);
    // The workspace takes no new work while the switch still runs.
    await drainUntil(
      tester,
      () => find.byType(LinearProgressIndicator).evaluate().isEmpty,
    );
    expect(find.byKey(const ValueKey('note-function-row')), findsNothing);
    for (final key in const [
      'editor-insert-page',
      'editor-fullscreen',
      'editor-page-list',
    ]) {
      expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
    }
    await openWindow(tester, 'editor-doc-menu');
    for (final key in const [
      'editor-doc-prev',
      'editor-doc-next',
      'note-view-toggle',
      'editor-doc-layout',
      'editor-doc-finger',
      'editor-doc-save',
      // 파일 내보내기, the editor's export, in 더 보기
      'editor-doc-export',
      'workspace-quick-switch',
      'workspace-bookmarks',
      'editor-link-add',
    ]) {
      expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
    }

    // Under the Markdown view the row is back, without the editor's
    // shortcuts.
    await tester.tap(find.byKey(const ValueKey('note-view-toggle')));
    await drain(tester);
    expect(inRow(find.byTooltip('페이지 추가')), findsNothing);
    expect(inRow(find.byTooltip('기기에 저장')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('note-view-toggle')));
    await drain(tester);
    expect(find.byKey(const ValueKey('note-function-row')), findsNothing);

    // The toolbar's 노트 추가 and ⋯ 기기에 저장 run their actions.
    final editor = tester.state<EditorState>(find.byType(Editor));
    final pages = editor.coreInfo.pages.length;
    await tester.tap(find.byKey(const ValueKey('editor-insert-page')));
    await drain(tester);
    expect(editor.coreInfo.pages, hasLength(pages + 1));
    await openWindow(tester, 'editor-doc-menu');
    await tester.ensureVisible(find.byKey(const ValueKey('editor-doc-save')));
    await tester.pump();
    await tester.runAsync(
      () => tester.tap(find.byKey(const ValueKey('editor-doc-save'))),
    );
    await drainUntil(tester, () => !controller.dirty);
    expect(controller.dirty, isFalse);
  });
}
