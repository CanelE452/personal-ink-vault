import 'dart:async';
import 'dart:io';

import 'package:bson/bson.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/components/canvas/interactive_canvas.dart';
import 'package:saber/components/ink_ui/editor_toolbar/kit_editor_toolbar.dart';
import 'package:saber/components/ink_ui/kit_tab_row.dart';
import 'package:saber/components/kit/kit_tokens.dart';
import 'package:saber/components/kit/kit_toolbar.dart';
import 'package:saber/components/theming/dynamic_material_app.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/vault/block_page_document.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/editor/editor.dart';
import 'package:saber/pages/workspace/infinite_canvas.dart';
import 'package:saber/pages/workspace/library_home.dart';
import 'package:saber/pages/workspace/study_workspace.dart';
import 'package:sbn/read_only_reason.dart';

import '../utils/kit_menu_finders.dart';
import '../utils/test_editor.dart';
import '../utils/test_mock_channel_handlers.dart';

/// The tab row and the other documents' function row (Task 17, 9th draft
/// c): home · tabs (⌄ on the open one, × on each) · +; the ink editor has
/// no function row (its toolbar and ⋯ hold those things), the other
/// documents keep theirs in the kit toolbar's look.
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
    directory = await Directory.systemTemp.createTemp('tab-row-');
    controller = WorkspaceController(
      await NoteRepository.open(directory, createFormatVersion: 2),
    );
    closed = false;
    final hidden = stows.noteTabBarHidden.value;
    final shortcuts = stows.noteShortcutLayout.value;
    final finger = stows.editorFingerDrawing.value;
    stows.noteTabBarHidden.value = false;
    stows.noteShortcutLayout.value = const [];
    addTearDown(() {
      stows.noteTabBarHidden.value = hidden;
      stows.noteShortcutLayout.value = shortcuts;
      stows.editorFingerDrawing.value = finger;
    });
  });

  tearDown(() async {
    router?.dispose();
    router = null;
    if (!closed) {
      await controller.flush();
      controller.dispose();
      await controller.repository.close().timeout(const Duration(seconds: 20));
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

  Future<void> drainUntil(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 20 && !done(); i++) {
      await drain(tester);
    }
  }

  /// Shows the workspace; without [settle] only its first frame is drawn
  /// (nothing read from the vault yet).
  Future<void> mount(
    WidgetTester tester, {
    Size size = const Size(1280, 800),
    bool settle = true,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
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
    if (!settle) return;
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

  Future<List<String>> createNotes(
    WidgetTester tester,
    List<String> titles, {
    VaultDocumentKind kind = VaultDocumentKind.handwriting,
  }) async => (await tester.runAsync(() async {
    final ids = <String>[];
    for (final title in titles) {
      await controller.createNote(title, documentKind: kind);
      ids.add(controller.activeSession!.note.id);
    }
    return ids;
  }))!;

  Finder key(String name) => find.byKey(ValueKey(name));
  Finder inPart(String part, Finder matching) =>
      find.descendant(of: key(part), matching: matching);
  final row = key('note-function-row');
  final tabRow = key('note-tab-row');

  /// Opens the ink editor's ⋯ (menus open in fake time; the workspace's
  /// progress bar never settles).
  Future<void> openDocMenu(WidgetTester tester) async {
    await tester.tap(key('editor-doc-menu'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// Taps a window row; what it starts reads and writes the vault, so it
  /// starts in real time.
  Future<void> tapRow(WidgetTester tester, String rowKey) async {
    await tester.ensureVisible(key(rowKey));
    await tester.pump();
    await tester.runAsync(() => tester.tap(key(rowKey)));
    await drain(tester);
  }

  Future<void> hideTabRow(WidgetTester tester) async {
    await tester.tap(key('workspace-tab-switcher'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(key('workspace-tab-bar-hide'));
    await drain(tester);
    expect(stows.noteTabBarHidden.value, isTrue);
    expect(tabRow, findsNothing);
  }

  androidTest('ink editor has no function row; other documents keep it', (
    tester,
  ) async {
    final ink = (await createNotes(tester, ['필기'])).single;
    final page = (await createNotes(tester, [
      '페이지',
    ], kind: VaultDocumentKind.page)).single;
    await mount(tester);
    expect(controller.activeSession?.note.id, page);
    expect(row, findsOneWidget);
    expect(
      find.descendant(of: row, matching: find.byType(KitToolbar)),
      findsOneWidget,
    );
    await tester.runAsync(() => tester.tap(key('document-tab-$ink')));
    await drainUntil(tester, () => controller.activeSession?.note.id == ink);
    await drain(tester);
    expect(find.byType(Editor), findsOneWidget);
    expect(row, findsNothing);
    expect(tabRow, findsOneWidget);
    // its toolbar holds what the row held
    expect(key('editor-doc-menu').hitTestable(), findsOneWidget);
    expect(inPart('note-tab-row', key('workspace-back-to-library')), findsOneWidget);
    await tester.runAsync(() => tester.tap(key('document-tab-$page')));
    await drainUntil(tester, () => controller.activeSession?.note.id == page);
    await drain(tester);
    expect(controller.activeSession?.note.id, page);
    expect(row, findsOneWidget);
  });

  androidTest('the tab row: home, the tabs with ⌄ on the open one, +', (
    tester,
  ) async {
    final ids = await createNotes(tester, ['하나', '둘']);
    await mount(tester);
    expect(tester.getSize(tabRow).height, KitTokens.tabRowHeight);
    final home = inPart('note-tab-row', key('workspace-back-to-library'));
    final plus = inPart('note-tab-row', key('workspace-new-tab'));
    final first = key('document-tab-${ids.first}');
    final second = key('document-tab-${ids.last}');
    expect(home, findsOneWidget);
    expect(plus, findsOneWidget);
    // home, then the tabs in order, then +
    expect(tester.getCenter(home).dx, lessThan(tester.getCenter(first).dx));
    expect(tester.getCenter(first).dx, lessThan(tester.getCenter(second).dx));
    expect(tester.getCenter(second).dx, lessThan(tester.getCenter(plus).dx));
    // ⌄ only on the open tab (the second, made last); × on each
    expect(key('document-tab-info'), findsOneWidget);
    expect(
      find.descendant(of: second, matching: key('document-tab-info')),
      findsOneWidget,
    );
    expect(find.byTooltip('하나 탭 닫기'), findsOneWidget);
    expect(find.byTooltip('둘 탭 닫기'), findsOneWidget);
    // a tab is at most 190 wide
    expect(tester.getSize(first).width, lessThanOrEqualTo(190));
    // home: back to the library
    await tester.tap(home);
    await drainUntil(tester, () => controller.activeSession == null);
    expect(controller.activeSession, isNull);
    expect(tabRow, findsNothing);
  });

  androidTest('status bar icons are light over the dark rows', (tester) async {
    await createNotes(tester, ['상태 막대']);
    await mount(tester);
    Brightness icons() => tester
        .widget<AnnotatedRegion<SystemUiOverlayStyle>>(
          find
              .byWidgetPredicate(
                (widget) => widget is AnnotatedRegion<SystemUiOverlayStyle>,
              )
              .first,
        )
        .value
        .statusBarIconBrightness!;
    expect(icons(), Brightness.light);
    // the ink editor without the tab row: nothing of the workspace on top
    await hideTabRow(tester);
    expect(icons(), Brightness.dark);
  });

  androidTest('the tab ⌄ window: last edit, sync, offline, rename', (
    tester,
  ) async {
    await createNotes(tester, ['정보 노트']);
    await mount(tester);
    await tester.tap(key('document-tab-info'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    for (final (rowKey, label) in const [
      ('document-tab-info-edited', '마지막 편집'),
      ('document-tab-info-sync', '동기화 상태'),
      ('document-tab-info-offline', '오프라인용으로 저장'),
      ('document-tab-info-rename', '이름 변경'),
    ]) {
      expect(
        find.descendant(of: key(rowKey), matching: findMenuText(label)),
        findsOneWidget,
        reason: label,
      );
    }
    // the rows in that order
    final tops = [
      for (final rowKey in const [
        'document-tab-info-edited',
        'document-tab-info-sync',
        'document-tab-info-offline',
        'document-tab-info-rename',
      ])
        tester.getTopLeft(key(rowKey)).dy,
    ];
    expect([...tops]..sort(), tops);
    // the values ⋯ 「문서 정보」 shows (Task 14 DocInfo): no Drive here
    expect(
      find.descendant(
        of: key('document-tab-info-sync'),
        matching: find.text('연결 안 됨'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: key('document-tab-info-offline'),
        matching: find.text('준비됨'),
      ),
      findsOneWidget,
    );
    final edited = tester
        .widgetList<Text>(
          find.descendant(
            of: key('document-tab-info-edited'),
            matching: find.byType(Text),
          ),
        )
        .map((text) => text.data)
        .toList();
    expect(edited, hasLength(2));
    expect(
      edited.last,
      anyOf('알 수 없음', matches(RegExp(r'(전|^\d{4}-\d{2}-\d{2})$'))),
    );
    // 이름 변경 closes the window and asks for the name
    await tester.runAsync(() => tester.tap(key('document-tab-info-rename')));
    await drainUntil(tester, () => find.text('문서 이름').evaluate().isNotEmpty);
    expect(key('document-tab-info-sync'), findsNothing);
    expect(find.text('문서 이름'), findsOneWidget);
  });

  /// What the 「마지막 편집」 row of the window [rowKey] shows beside its
  /// name (the ⌄ row, or the ⋯ 「문서 정보」 dialog's row).
  String? lastEditedIn(WidgetTester tester, Finder scope) => tester
      .widgetList<Text>(find.descendant(of: scope, matching: find.byType(Text)))
      .map((text) => text.data)
      .lastOrNull;

  Future<String?> tabMenuLastEdited(WidgetTester tester) async {
    await tester.tap(key('document-tab-info'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final value = lastEditedIn(tester, key('document-tab-info-edited'));
    await tester.binding.handlePopRoute();
    await drain(tester);
    return value;
  }

  androidTest('the tab ⌄ last edit is ⋯ 문서 정보\'s after a stroke', (
    tester,
  ) async {
    await createNotes(tester, ['정보 노트']);
    await mount(tester);
    final editor = tester.state<EditorState>(find.byType(Editor));
    await tester.runAsync(() async => editor.drawTestStroke());
    await drain(tester);
    // ⋯ 「문서 정보」
    await openDocMenu(tester);
    await tester.tap(key('editor-doc-info'));
    await drain(tester);
    final row = find.ancestor(
      of: find.text('마지막 편집'),
      matching: find.byType(Row),
    ).first;
    final info = lastEditedIn(tester, row);
    expect(info, '방금 전');
    await tester.tap(find.text('닫기'));
    await drain(tester);
    final tab = await tabMenuLastEdited(tester);
    editor.cancelAutosaveAndMarkSaved();
    await drain(tester);
    expect(tab, info);
  });

  androidTest('another document\'s save shows in the tab ⌄ last edit', (
    tester,
  ) async {
    final block = BlockPageBlock.create(text: '처음 본문');
    await tester.runAsync(() async {
      await controller.createNote('페이지', documentKind: VaultDocumentKind.page);
      await controller.saveBlockPage(
        const BlockPageDocument.empty().copyWith(blocks: [block]),
        session: controller.activeSession!,
      );
    });
    await mount(tester);
    expect(await tabMenuLastEdited(tester), '알 수 없음');
    // typing marks the page changed; its autosave (700 ms) saves it
    final field = key('block-text-${block.id}');
    await drainUntil(tester, () => field.evaluate().isNotEmpty);
    await tester.enterText(field, '고친 본문');
    await drainUntil(tester, () => controller.dirty);
    expect(controller.dirty, isTrue);
    for (var i = 0; i < 20 && controller.dirty; i++) {
      await tester.pump(const Duration(milliseconds: 400));
      await drain(tester);
    }
    expect(controller.dirty, isFalse);
    expect(await tabMenuLastEdited(tester), '방금 전');
  });

  androidTest('이름 변경 in the tab ⌄ renames the note', (tester) async {
    await createNotes(tester, ['옛 이름']);
    await mount(tester);
    await tester.tap(key('document-tab-info'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.runAsync(() => tester.tap(key('document-tab-info-rename')));
    await drainUntil(tester, () => find.text('문서 이름').evaluate().isNotEmpty);
    await tester.enterText(find.byType(TextField).last, '새 이름');
    await tester.runAsync(() => tester.tap(find.text('확인').last));
    await drainUntil(
      tester,
      () => controller.activeSession?.note.title == '새 이름',
    );
    expect(controller.activeSession?.note.title, '새 이름');
    await drain(tester);
    expect(inPart('note-tab-row', find.text('새 이름')), findsOneWidget);
  });

  androidTest('a note read-only by its version keeps the row and the way to Markdown', (
    tester,
  ) async {
    // a phone's status bar
    tester.view.padding = const FakeViewPadding(top: 48);
    addTearDown(tester.view.resetPadding);
    await createNotes(tester, ['새 판본 노트']);
    await mount(tester);
    expect(row, findsNothing);
    final editor = tester.state<EditorState>(find.byType(Editor));
    // ignore: invalid_use_of_protected_member
    editor.setState(
      () => editor.coreInfo.readOnlyReason = ReadOnlyReason.versionTooNew,
    );
    await drain(tester);
    // the toolbar is folded away with its ⋯: the row holds the way
    expect(key('editor-doc-menu').hitTestable(), findsNothing);
    expect(row, findsOneWidget);
    expect(inPart('note-function-row', find.byTooltip('이전 위치')), findsOneWidget);
    expect(inPart('note-function-row', key('workspace-more-actions')), findsOneWidget);
    // the tab row hidden too: the row stays, the page under it, below the status bar
    await hideTabRow(tester);
    expect(row, findsOneWidget);
    expect(tester.getTopLeft(row).dy, greaterThanOrEqualTo(48));
    expect(
      tester.getTopLeft(find.byType(InteractiveCanvasViewer)).dy,
      greaterThanOrEqualTo(48),
    );
    final toggle = inPart('note-function-row', key('note-view-toggle'));
    await tester.tap(toggle);
    await drain(tester);
    expect(find.byTooltip('PDF·필기'), findsOneWidget, reason: 'the Markdown view');
    await tester.tap(inPart('note-function-row', key('note-view-toggle')));
    await drain(tester);
    expect(row, findsOneWidget, reason: 'still read-only');
  });

  androidTest('an ink note still loading: no function row, 이름 변경 on', (
    tester,
  ) async {
    await createNotes(tester, ['불러오는 노트']);
    await mount(tester, settle: false);
    // the tab row's first frame already has 이름 변경
    expect(
      tester.widget<KitTabRow>(find.byType(KitTabRow)).onRename,
      isNotNull,
    );
    await tester.pump();
    final editor = tester.state<EditorState>(find.byType(Editor));
    // the placeholder: read-only until the note is read
    expect(editor.coreInfo.readOnlyReason, ReadOnlyReason.placeholder);
    expect(row, findsNothing);
    await drain(tester, 40);
    expect(editor.coreInfo.readOnlyReason, isNull);
    expect(row, findsNothing);
  });

  androidTest('an ink note saved by a newer app opens with the function row', (
    tester,
  ) async {
    await createNotes(tester, ['새 판본 노트']);
    // its saved snapshot says a version this app does not know
    await tester.runAsync(() async {
      final core = EditorCoreInfo(filePath: '/newer')..pages.add(EditorPage());
      final (json, _) = core.toJson();
      core.dispose();
      json['v'] = EditorCoreInfo.newestSbnVersion + 1;
      await controller.activeSession!.saveInk({
        'main.sbn2': BsonCodec.serialize(json).byteList,
      });
    });
    await mount(tester);
    // the editor cannot open it: the row keeps the ways out
    expect(find.byType(Editor), findsOneWidget);
    expect(key('editor-doc-menu').hitTestable(), findsNothing);
    expect(row, findsOneWidget);
    expect(
      inPart('note-function-row', key('workspace-more-actions')),
      findsOneWidget,
    );
    expect(
      inPart('note-function-row', key('note-view-toggle')),
      findsOneWidget,
    );
  });

  androidTest('a head change that is no save keeps the tab ⌄ last edit', (
    tester,
  ) async {
    await createNotes(tester, ['페이지'], kind: VaultDocumentKind.page);
    await mount(tester);
    expect(await tabMenuLastEdited(tester), '알 수 없음');
    final session = controller.activeSession!;
    final heads = session.markdownParents;
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    void notify() => controller.notifyListeners();
    notify(); // the heads as they are, then new ones with nothing unsaved
    session.markdownParents = [...heads, 'elsewhere'];
    notify();
    await drain(tester);
    expect(await tabMenuLastEdited(tester), '알 수 없음');
    session.markdownParents = heads;
  });

  androidTest('the library keeps the status bar inset in full screen', (
    tester,
  ) async {
    tester.view.padding = const FakeViewPadding(top: 48);
    addTearDown(tester.view.resetPadding);
    DynamicMaterialApp.setFullscreen(true, updateSystem: false);
    addTearDown(
      () => DynamicMaterialApp.setFullscreen(false, updateSystem: false),
    );
    await mount(tester);
    expect(controller.activeSession, isNull);
    expect(
      tester.getTopLeft(find.byType(LibraryHome)).dy,
      greaterThanOrEqualTo(48),
    );
  });

  androidTest(
    'the infinite note: the function row over its kit toolbar, no ⋯',
    (tester) async {
      await createNotes(tester, ['무한 노트'], kind: VaultDocumentKind.infinite);
      await mount(tester);
      await drainUntil(
        tester,
        () => find.byType(InfiniteCanvas).evaluate().isNotEmpty,
      );
      expect(row, findsOneWidget);
      expect(
        inPart('note-function-row', key('workspace-more-actions')),
        findsOneWidget,
      );
      final bar = find.byType(KitEditorToolbar);
      expect(bar, findsOneWidget);
      expect(
        tester.getRect(bar).top,
        greaterThanOrEqualTo(tester.getRect(row).bottom),
      );
      expect(key('editor-doc-menu'), findsNothing);
      expect(key('editor-canvas-origin'), findsOneWidget);
    },
  );

  androidTest('+ at phone width opens the new tab in view', (tester) async {
    final other = (await tester.runAsync(
      () => controller.store.create(
        '새로 열 노트',
        documentKind: VaultDocumentKind.markdown,
      ),
    ))!;
    await createNotes(tester, [
      '첫째 문서',
      '둘째 문서',
      '셋째 문서',
      '넷째 문서',
    ], kind: VaultDocumentKind.markdown);
    await mount(tester, size: const Size(360, 760));
    await tester.runAsync(() => tester.tap(key('workspace-new-tab')));
    await drain(tester);
    await tester.enterText(key('workspace-quick-switch-query'), '새로 열 노트');
    await tester.pump();
    await tester.tap(key('workspace-quick-switch-result-${other.id}'));
    await drainUntil(
      tester,
      () => controller.activeSession?.note.id == other.id,
    );
    await drain(tester);
    final tab = key('document-tab-${other.id}');
    expect(tab.hitTestable(), findsOneWidget);
    expect(tester.getRect(tab).left, greaterThanOrEqualTo(0));
    expect(tester.getRect(tab).right, lessThanOrEqualTo(360));
  });

  androidTest('plus opens quick switch and adds a tab', (tester) async {
    final other = (await tester.runAsync(
      () => controller.store.create(
        '새로 열 노트',
        documentKind: VaultDocumentKind.markdown,
      ),
    ))!;
    final open = (await createNotes(tester, ['열린 노트'])).single;
    await mount(tester);
    expect(controller.navigation.tabs.map((tab) => tab.noteId), [open]);
    await tester.runAsync(() => tester.tap(key('workspace-new-tab')));
    await drain(tester);
    final query = key('workspace-quick-switch-query');
    expect(query, findsOneWidget);
    await tester.enterText(query, '새로 열 노트');
    await tester.pump();
    await tester.tap(key('workspace-quick-switch-result-${other.id}'));
    await drainUntil(
      tester,
      () => controller.activeSession?.note.id == other.id,
    );
    await drain(tester);
    expect(controller.activeSession?.note.id, other.id);
    expect(controller.navigation.tabs.map((tab) => tab.noteId), [
      open,
      other.id,
    ]);
    expect(key('document-tab-${other.id}'), findsOneWidget);
    expect(key('document-tab-$open'), findsOneWidget);
  });

  androidTest('markdown view can switch back to ink', (tester) async {
    await createNotes(tester, ['보기 노트']);
    await mount(tester);
    expect(row, findsNothing);
    await openDocMenu(tester);
    await tapRow(tester, 'note-view-toggle');
    // the Markdown view: the ink editor goes behind, the row is back
    expect(row, findsOneWidget);
    expect(key('editor-doc-menu').hitTestable(), findsNothing);
    final toggle = inPart('note-function-row', key('note-view-toggle'));
    expect(toggle, findsOneWidget);
    expect(find.byTooltip('PDF·필기'), findsOneWidget);
    await tester.tap(toggle);
    await drain(tester);
    expect(row, findsNothing);
    expect(key('editor-doc-menu').hitTestable(), findsOneWidget);
  });

  androidTest('hidden tab row can be restored from the ink doc menu', (
    tester,
  ) async {
    await createNotes(tester, ['숨김 노트']);
    await mount(tester);
    await hideTabRow(tester);
    expect(row, findsNothing, reason: 'the ink editor has no row');
    await openDocMenu(tester);
    final restore = key('editor-doc-tabBarHide');
    expect(
      find.descendant(of: restore, matching: findMenuText('탭 줄 보이기')),
      findsOneWidget,
    );
    await tapRow(tester, 'editor-doc-tabBarHide');
    expect(stows.noteTabBarHidden.value, isFalse);
    expect(tabRow, findsOneWidget);
    await openDocMenu(tester);
    expect(
      find.descendant(
        of: key('editor-doc-tabBarHide'),
        matching: findMenuText('탭 줄 숨기기'),
      ),
      findsOneWidget,
    );
  });

  androidTest('another document\'s row brings a hidden tab row back', (
    tester,
  ) async {
    await createNotes(tester, ['페이지'], kind: VaultDocumentKind.page);
    await mount(tester);
    // with the tab row, home is there and the row has no back of its own
    expect(inPart('note-function-row', key('workspace-back-to-library')),
        findsNothing);
    await hideTabRow(tester);
    // without it, the row keeps the way back and the way to show it
    expect(inPart('note-function-row', key('workspace-back-to-library')),
        findsOneWidget);
    final show = inPart('note-function-row', key('note-tab-bar-show'));
    expect(show, findsOneWidget);
    await tester.tap(show);
    await drain(tester);
    expect(stows.noteTabBarHidden.value, isFalse);
    expect(tabRow, findsOneWidget);
    expect(key('note-tab-bar-show'), findsNothing);
  });

  androidTest('block page keeps its function row with the same keys', (
    tester,
  ) async {
    await createNotes(tester, ['블록 페이지'], kind: VaultDocumentKind.page);
    await mount(tester);
    expect(row, findsOneWidget);
    for (final name in const [
      'note-view-toggle',
      'portable-export-menu',
      'workspace-more-actions',
    ]) {
      expect(inPart('note-function-row', key(name)), findsOneWidget,
          reason: name);
    }
    for (final label in const ['이전 위치', '다음 위치', '기기에 저장']) {
      expect(inPart('note-function-row', find.byTooltip(label)), findsOneWidget,
          reason: label);
    }
    // the kit toolbar's buttons and height
    expect(tester.getSize(row).height, KitTokens.toolbarHeight);
    expect(
      find.descendant(
        of: row,
        matching: find.byWidgetPredicate(
          (w) => w is KitToolbarButton && w.key == const ValueKey('note-view-toggle'),
        ),
      ),
      findsOneWidget,
    );
    // ⋯: the rest under the same keys, and 사용자 지정 바로가기 막대
    await tester.tap(key('workspace-more-actions'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    for (final name in const [
      'workspace-quick-switch',
      'workspace-bookmarks',
      'shortcut-bar-customize',
    ]) {
      expect(key(name), findsOneWidget, reason: name);
    }
    await tester.runAsync(() => tester.tap(key('workspace-quick-switch')));
    await drain(tester);
    expect(key('workspace-more-actions'), findsOneWidget);
    expect(key('workspace-bookmarks'), findsNothing, reason: 'closed first');
    expect(key('workspace-quick-switch-query'), findsOneWidget);
  });

  androidTest('⋯ holds the old row\'s 이전·다음 위치, 기기에 저장, 손가락 필기', (
    tester,
  ) async {
    final ids = await createNotes(tester, ['하나', '둘']);
    await mount(tester);
    expect(controller.navigation.peekBack, isNotNull);
    // 이전 위치 and 다음 위치 in 보기
    await openDocMenu(tester);
    await tapRow(tester, 'editor-doc-prev');
    await drainUntil(tester, () => controller.activeSession?.note.id == ids.first);
    expect(controller.activeSession?.note.id, ids.first);
    await drain(tester);
    await openDocMenu(tester);
    await tapRow(tester, 'editor-doc-next');
    await drainUntil(tester, () => controller.activeSession?.note.id == ids.last);
    expect(controller.activeSession?.note.id, ids.last);
    await drain(tester);
    // 손가락 필기 in 정렬·설정: a switch
    stows.editorFingerDrawing.value = false;
    await drain(tester);
    await openDocMenu(tester);
    await tester.ensureVisible(key('editor-doc-finger'));
    await tester.pump();
    await tester.tap(key('editor-doc-finger'));
    await tester.pump();
    expect(stows.editorFingerDrawing.value, isTrue);
    await tester.tapAt(const Offset(640, 780));
    await drain(tester);
    // 기기에 저장 in 더 보기
    await tester.tap(key('editor-insert-page'));
    await drain(tester);
    await tester.tap(key('add-page-card-lined'));
    await drain(tester);
    expect(controller.dirty, isTrue);
    await openDocMenu(tester);
    await tapRow(tester, 'editor-doc-save');
    await drainUntil(tester, () => !controller.dirty);
    expect(controller.dirty, isFalse);
  });
}
