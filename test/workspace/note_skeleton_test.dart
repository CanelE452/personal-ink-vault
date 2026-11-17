import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/components/theming/dynamic_material_app.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/editor/editor.dart';
import 'package:saber/pages/workspace/study_workspace.dart';

import '../utils/test_mock_channel_handlers.dart';

/// StarNote's note screen (229): a tab row with only the tabs, the function
/// row under it (back, shortcuts, 문서 개요, 기타 설정, ⋯), and the 기타 설정
/// panel.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();
  setupMockPathProvider();
  setupMockPrinting();
  setupMockWindowManager();
  late Directory directory;
  late WorkspaceController controller;
  late bool closed;
  GoRouter? router;

  setUp(() async {
    await FileManager.init(shouldWatchRootDirectory: false);
    directory = await Directory.systemTemp.createTemp('note-skeleton-');
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
    router?.dispose();
    router = null;
    if (!closed) {
      await controller.flush();
      controller.dispose();
      await controller.repository.close();
    }
    await directory.delete(recursive: true);
  });

  Future<void> drain(WidgetTester tester, [int cycles = 12]) async {
    await tester.runAsync(() async {
      for (var i = 0; i < cycles; i++) {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 15));
      }
    });
    await tester.pump(const Duration(milliseconds: 350));
  }

  Future<void> mount(WidgetTester tester) async {
    router = GoRouter(
      initialLocation: '/workspace',
      routes: [
        GoRoute(
          path: '/workspace',
          builder: (_, _) => StudyWorkspace(controller: controller),
        ),
        GoRoute(path: '/home/:subpage', redirect: (_, _) => '/workspace'),
      ],
    );
    await tester.pumpWidget(
      TranslationProvider(child: MaterialApp.router(routerConfig: router)),
    );
    await drain(tester, 40);
    expect(tester.takeException(), isNull);
  }

  /// Pumps until [done] holds (at most about 20 drains): a save and the tab
  /// closes behind it take real time.
  Future<void> drainUntil(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 20 && !done(); i++) {
      await drain(tester);
    }
  }

  /// Closes the vault while the test's fake time runs: the editor's last save
  /// starts in it when the screen goes, and would never finish in the
  /// tear-down.
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

  Future<List<String>> createNotes(WidgetTester tester, List<String> titles) async =>
      (await tester.runAsync(() async {
        final ids = <String>[];
        for (final title in titles) {
          await controller.createNote(title);
          ids.add(controller.activeSession!.note.id);
        }
        return ids;
      }))!;

  Finder inPart(String part, Finder matching) =>
      find.descendant(of: find.byKey(ValueKey(part)), matching: matching);

  androidTest('the tab row holds only tabs; back and shortcuts sit in the function row', (
    tester,
  ) async {
    final ids = await createNotes(tester, ['첫 노트']);
    await mount(tester);
    expect(inPart('note-tab-row', find.byKey(ValueKey('document-tab-${ids.single}'))), findsOneWidget);
    expect(inPart('note-tab-row', find.byKey(const ValueKey('workspace-back-to-library'))), findsNothing);
    expect(inPart('note-tab-row', find.byTooltip('이전 위치')), findsNothing);
    expect(inPart('note-function-row', find.byKey(const ValueKey('workspace-back-to-library'))), findsOneWidget);
    expect(inPart('note-function-row', find.byTooltip('이전 위치')), findsOneWidget);
    expect(inPart('note-function-row', find.byKey(const ValueKey('note-other-settings'))), findsOneWidget);
    expect(inPart('note-function-row', find.byKey(const ValueKey('note-overview'))), findsOneWidget);
  });

  androidTest('long-pressing a tab offers 닫기 and 다른 탭 닫기; 다른 탭 닫기 keeps the open document', (
    tester,
  ) async {
    final ids = await createNotes(tester, ['하나', '둘', '셋']);
    await mount(tester);
    expect(controller.navigation.tabs, hasLength(3));
    await tester.longPress(find.byKey(ValueKey('document-tab-${ids.last}')));
    // Menus open in fake time; the workspace's progress bar never settles.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('document-tab-menu-close')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('document-tab-menu-close-others')));
    await drainUntil(tester, () => controller.navigation.tabs.length == 1);
    expect(controller.navigation.tabs.map((tab) => tab.noteId), [ids.last]);
    expect(controller.activeSession?.note.id, ids.last);
  });

  androidTest('다른 탭 닫기 in the tab list saves the open note first', (tester) async {
    final ids = await createNotes(tester, ['하나', '둘']);
    await mount(tester);
    await tester.tap(inPart('note-function-row', find.byTooltip('페이지 추가')));
    await drain(tester);
    expect(controller.dirty, isTrue);
    await tester.tap(find.byKey(const ValueKey('workspace-tab-switcher')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(const ValueKey('workspace-tab-close-others')));
    await drainUntil(tester, () => controller.navigation.tabs.length == 1);
    expect(controller.navigation.tabs.map((tab) => tab.noteId), [ids.last]);
    expect(controller.dirty, isFalse);
  });

  androidTest('hiding the tab row leaves a button to bring it back', (tester) async {
    await createNotes(tester, ['첫 노트']);
    await mount(tester);
    await tester.tap(find.byKey(const ValueKey('workspace-tab-switcher')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(const ValueKey('workspace-tab-bar-hide')));
    await drain(tester);
    expect(stows.noteTabBarHidden.value, isTrue);
    expect(find.byKey(const ValueKey('note-tab-row')), findsNothing);
    expect(find.byKey(const ValueKey('note-tab-bar-show')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('note-tab-bar-show')));
    await drain(tester);
    expect(stows.noteTabBarHidden.value, isFalse);
    expect(find.byKey(const ValueKey('note-tab-row')), findsOneWidget);
  });

  androidTest('기타 설정 opens the panel with page, export and general sections', (
    tester,
  ) async {
    await createNotes(tester, ['설정 노트']);
    await mount(tester);
    await tester.tap(find.byKey(const ValueKey('note-other-settings')));
    await drain(tester);
    final panel = find.byKey(const ValueKey('other-settings-panel'));
    expect(panel, findsOneWidget);
    for (final text in const ['설정 노트', '페이지 설정', '문서 내보내기', '일반 설정']) {
      expect(find.descendant(of: panel, matching: find.text(text)), findsOneWidget, reason: text);
    }
    await tester.tap(find.byKey(const ValueKey('other-settings-close')));
    await drain(tester);
    expect(panel, findsNothing);
    // Closing the panel is not leaving the note.
    expect(controller.activeSession?.note.title, '설정 노트');
    expect(find.byType(Editor), findsOneWidget);
    // Nor is the system back while the panel is open: it closes the panel.
    await tester.tap(find.byKey(const ValueKey('note-other-settings')));
    await drain(tester);
    expect(panel, findsOneWidget);
    await tester.binding.handlePopRoute();
    await drain(tester);
    expect(panel, findsNothing);
    expect(controller.activeSession?.note.title, '설정 노트');
  });

  androidTest('full screen hides both rows and the toolbar offers the way back', (tester) async {
    addTearDown(() => DynamicMaterialApp.setFullscreen(false, updateSystem: false));
    await createNotes(tester, ['전체 노트']);
    await mount(tester);
    await tester.tap(inPart('note-function-row', find.byTooltip('전체 화면')));
    await drain(tester);
    expect(DynamicMaterialApp.isFullscreen, isTrue);
    expect(find.byKey(const ValueKey('note-function-row')), findsNothing);
    expect(find.byKey(const ValueKey('note-tab-row')), findsNothing);
    await tester.tap(find.byTooltip('전체 화면 끝내기'));
    await drain(tester);
    expect(DynamicMaterialApp.isFullscreen, isFalse);
    expect(find.byKey(const ValueKey('note-function-row')), findsOneWidget);
  });

  androidTest('the shortcut 페이지 추가 adds a page to the open note', (tester) async {
    await createNotes(tester, ['쪽 노트']);
    await mount(tester);
    final editor = tester.state<EditorState>(find.byType(Editor));
    final pages = editor.coreInfo.pages.length;
    await tester.tap(inPart('note-function-row', find.byTooltip('페이지 추가')));
    await drain(tester);
    expect(editor.coreInfo.pages, hasLength(pages + 1));
    expect(controller.dirty, isTrue);
    await tester.tap(inPart('note-function-row', find.byTooltip('기기에 저장')));
    await drain(tester, 30);
    expect(controller.dirty, isFalse);
  });

  androidTest('the Markdown view keeps the function row', (tester) async {
    await createNotes(tester, ['보기 노트']);
    await mount(tester);
    await tester.tap(find.byKey(const ValueKey('note-view-toggle')));
    await drain(tester);
    expect(find.byKey(const ValueKey('note-function-row')), findsOneWidget);
    expect(find.byKey(const ValueKey('note-view-toggle')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('note-view-toggle')));
    await drain(tester);
    expect(find.byKey(const ValueKey('note-other-settings')), findsOneWidget);
  });
}
