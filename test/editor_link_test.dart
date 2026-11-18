import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/canvas/canvas_gesture_detector.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/editor/page_link.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/tools/pen.dart';
import 'package:saber/data/tools/select.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/editor/editor.dart';
import 'package:saber/pages/editor/editor_chrome.dart';

import 'utils/test_mock_channel_handlers.dart';

/// Notein's hyperlinks in a handwritten note: a lassoed area, or a spot the
/// user taps, links to a page of the note, another note or a web address.
void main() {
  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    setupMockPathProvider();
    setupMockPrinting();
    setupMockWindowManager();
    FlavorConfig.setup();
    await FileManager.init();
  });

  const noteId = '0f9e8d7c-6b5a-4c3d-9e2f-1a0b9c8d7e6f';
  const webArea = Rect.fromLTWH(200, 300, 400, 150);
  // Each test opens its own path: the canvas remembers where a path was
  // scrolled to (CanvasTransformCache).
  var mounts = 0;

  Future<EditorState> mountEditor(
    WidgetTester tester, {
    EditorChromeController? chrome,
    Size size = const Size(1200, 2000),
    Widget Function(Widget editor)? around,
  }) async {
    final previousAlignment = stows.workspaceToolbarAlignment.value;
    final previousShortcuts = stows.noteShortcutLayout.value;
    final previousFinger = stows.editorFingerDrawing.value;
    final previousRectangle = stows.selectRectangle.value;
    final previousTool = stows.lastTool.value;
    stows.workspaceToolbarAlignment.value = AxisDirection.up;
    stows.noteShortcutLayout.value = const [];
    stows.editorFingerDrawing.value = true;
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      stows.workspaceToolbarAlignment.value = previousAlignment;
      stows.noteShortcutLayout.value = previousShortcuts;
      stows.editorFingerDrawing.value = previousFinger;
      stows.selectRectangle.value = previousRectangle;
      stows.lastTool.value = previousTool;
      Select.currentSelect.unselect();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final editor = Editor(
      path: '/editor-links-${mounts++}',
      onSaveSnapshot: (_, _) async {},
      chrome: chrome,
    );
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(home: around?.call(editor) ?? editor),
      ),
    );
    await tester.pumpAndSettle();
    return tester.state<EditorState>(find.byType(Editor));
  }

  /// Puts the pen in hand (the lasso turns links off) and refreshes the page.
  Future<void> holdPen(WidgetTester tester, EditorState editor) async {
    editor.currentTool = Pen.currentPen;
    // ignore: invalid_use_of_protected_member
    editor.setState(() {});
    await tester.pumpAndSettle();
  }

  Future<void> putLink(
    WidgetTester tester,
    EditorState editor,
    PageLink link,
  ) async {
    editor.coreInfo.pages.first.links.add(link);
    await holdPen(tester, editor);
  }

  Future<void> drag(
    WidgetTester tester,
    EditorPage page,
    Offset from,
    Offset to, {
    PointerDeviceKind kind = PointerDeviceKind.stylus,
  }) async {
    final box = page.renderBox!;
    final gesture = await tester.startGesture(
      box.localToGlobal(from),
      kind: kind,
    );
    for (var step = 1; step <= 8; step++) {
      await gesture.moveTo(box.localToGlobal(Offset.lerp(from, to, step / 8)!));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();
  }

  Future<void> pressLinkAdd(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('workspace-more-actions')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('링크 추가'));
    await tester.pumpAndSettle();
  }

  Future<void> chooseWeb(WidgetTester tester, String address) async {
    await tester.tap(find.byKey(const ValueKey('link-tab-web')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('link-web-url')), address);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('link-dialog-add')));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'the selection bar links the selection to another page and tapping the badge jumps there',
    (tester) async {
      final editor = await mountEditor(tester);
      editor.createPage(2);
      await holdPen(tester, editor);
      expect(editor.coreInfo.pages.length, greaterThanOrEqualTo(3));
      final page = editor.coreInfo.pages.first;
      final target = editor.coreInfo.pages[2];

      await drag(tester, page, const Offset(200, 300), const Offset(500, 380));
      expect(page.strokes, hasLength(1));
      stows.selectRectangle.value = true;
      editor.currentTool = Select.currentSelect;
      // ignore: invalid_use_of_protected_member
      editor.setState(() {});
      await tester.pumpAndSettle();
      await drag(tester, page, const Offset(150, 250), const Offset(560, 440));
      expect(Select.currentSelect.selectResult.strokes, page.strokes);

      await tester.tap(find.byKey(const ValueKey('selection-link')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('link-dialog')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('link-page-3')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('link-dialog-add')));
      await tester.pumpAndSettle();

      final link = page.links.single;
      expect(link.target, 'page:${target.pageId}');
      expect(link.kind, PageLinkKind.page);
      // The strokes' own bounds, not the lasso's loop.
      expect(link.rect, page.strokes.single.lowQualityPath.getBounds());
      expect(
        find.byKey(ValueKey('page-link-underline-${link.id}')),
        findsOneWidget,
      );

      await holdPen(tester, editor);
      expect(editor.currentPageIndex, 0);
      await tester.tap(find.byKey(ValueKey('page-link-badge-${link.id}')));
      await tester.pumpAndSettle();
      expect(editor.currentPageIndex, 2);
      editor.cancelAutosaveAndMarkSaved();
    },
  );

  testWidgets('a finger tap inside the area opens a web link through the chrome', (
    tester,
  ) async {
    final opened = <String>[];
    final chrome = EditorChromeController()
      ..openLink = (link) async => opened.add(link);
    addTearDown(chrome.dispose);
    final editor = await mountEditor(tester, chrome: chrome);
    final page = editor.coreInfo.pages.first;
    await putLink(
      tester,
      editor,
      const PageLink(id: 'web', rect: webArea, target: 'https://example.com/notes'),
    );

    await tester.tapAt(page.renderBox!.localToGlobal(const Offset(300, 400)));
    await tester.pumpAndSettle();
    expect(opened, ['https://example.com/notes']);
    expect(page.strokes, isEmpty, reason: 'the tap opened the link, not a dot');
    editor.cancelAutosaveAndMarkSaved();
  });

  testWidgets('a pen stroke over the area still draws', (tester) async {
    final opened = <String>[];
    final chrome = EditorChromeController()
      ..openLink = (link) async => opened.add(link);
    addTearDown(chrome.dispose);
    final editor = await mountEditor(tester, chrome: chrome);
    final page = editor.coreInfo.pages.first;
    await putLink(
      tester,
      editor,
      const PageLink(id: 'web', rect: webArea, target: 'https://example.com/notes'),
    );

    await drag(tester, page, const Offset(250, 380), const Offset(520, 400));
    expect(page.strokes, hasLength(1));
    // It starts where the pen touched down: the area did not hold the pen back.
    expect(page.strokes.single.lowQualityPath.getBounds().left, lessThan(255));
    expect(opened, isEmpty);
    editor.cancelAutosaveAndMarkSaved();
  });

  testWidgets('undo removes a new link', (tester) async {
    final editor = await mountEditor(tester);
    final page = editor.coreInfo.pages.first;
    await holdPen(tester, editor);
    await pressLinkAdd(tester);
    await tester.tapAt(page.renderBox!.localToGlobal(const Offset(400, 500)));
    await tester.pumpAndSettle();
    await chooseWeb(tester, 'https://example.com/undo');
    final link = page.links.single;
    expect(find.byKey(ValueKey('page-link-badge-${link.id}')), findsOneWidget);

    await tester.tap(find.byTooltip('실행 취소'));
    await tester.pumpAndSettle();
    expect(page.links, isEmpty);
    expect(find.byKey(ValueKey('page-link-badge-${link.id}')), findsNothing);

    await tester.tap(find.byTooltip('다시 실행'));
    await tester.pumpAndSettle();
    expect(page.links, [link]);
    editor.cancelAutosaveAndMarkSaved();
  });

  testWidgets(
    'link add without a selection places an icon link where the page is tapped',
    (tester) async {
      final editor = await mountEditor(tester);
      final page = editor.coreInfo.pages.first;
      await holdPen(tester, editor);

      // Cancelling the dialog makes nothing.
      await pressLinkAdd(tester);
      expect(find.text('링크를 둘 곳을 누르세요'), findsOneWidget);
      await tester.tapAt(page.renderBox!.localToGlobal(const Offset(300, 300)));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('link-dialog')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('link-dialog-cancel')));
      await tester.pumpAndSettle();
      expect(page.links, isEmpty);
      expect(find.byKey(const ValueKey('page-link-place')), findsNothing);
      expect(page.strokes, isEmpty, reason: 'the placing tap did not draw');

      await pressLinkAdd(tester);
      expect(find.byKey(const ValueKey('page-link-place')), findsWidgets);
      await tester.tapAt(page.renderBox!.localToGlobal(const Offset(420, 640)));
      await tester.pumpAndSettle();
      await chooseWeb(tester, 'example.com/spot');

      final link = page.links.single;
      expect(link.target, 'https://example.com/spot');
      expect(link.rect.size, Size.zero);
      expect(link.rect.left, moreOrLessEquals(420, epsilon: 0.5));
      expect(link.rect.top, moreOrLessEquals(640, epsilon: 0.5));
      expect(find.byKey(ValueKey('page-link-badge-${link.id}')), findsOneWidget);
      expect(find.byKey(ValueKey('page-link-underline-${link.id}')), findsNothing);
      expect(find.byKey(const ValueKey('page-link-place')), findsNothing);
      expect(find.text('링크를 둘 곳을 누르세요'), findsNothing);
      expect(page.strokes, isEmpty);
      editor.cancelAutosaveAndMarkSaved();
    },
  );

  testWidgets('the badge menu edits and deletes a link, and undo brings both back', (
    tester,
  ) async {
    final opened = <String>[];
    final chrome = EditorChromeController()
      ..openLink = (link) async => opened.add(link);
    addTearDown(chrome.dispose);
    final editor = await mountEditor(tester, chrome: chrome);
    final page = editor.coreInfo.pages.first;
    await putLink(
      tester,
      editor,
      const PageLink(id: 'menu', rect: webArea, target: 'https://example.com/a'),
    );
    final badge = find.byKey(const ValueKey('page-link-badge-menu'));

    await tester.longPress(badge);
    await tester.pumpAndSettle();
    for (final item in const ['open', 'edit', 'copy', 'delete']) {
      expect(find.byKey(ValueKey('page-link-menu-$item')), findsOneWidget);
    }
    await tester.tap(find.byKey(const ValueKey('page-link-menu-open')));
    await tester.pumpAndSettle();
    expect(opened, ['https://example.com/a']);

    await tester.longPress(badge);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('page-link-menu-edit')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('link-dialog-delete')), findsOneWidget);
    expect(find.text('https://example.com/a'), findsOneWidget);
    await chooseWeb(tester, 'https://example.com/b');
    expect(page.links.single.target, 'https://example.com/b');
    expect(page.links.single.id, 'menu');

    await tester.longPress(badge);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('page-link-menu-delete')));
    await tester.pumpAndSettle();
    expect(page.links, isEmpty);

    editor.undo();
    await tester.pumpAndSettle();
    expect(page.links.single.target, 'https://example.com/b');
    editor.undo();
    await tester.pumpAndSettle();
    expect(page.links.single.target, 'https://example.com/a');
    editor.redo();
    await tester.pumpAndSettle();
    expect(page.links.single.target, 'https://example.com/b');
    editor.cancelAutosaveAndMarkSaved();
  });

  testWidgets('with the lasso the links let every tap through', (tester) async {
    final opened = <String>[];
    final chrome = EditorChromeController()
      ..openLink = (link) async => opened.add(link);
    addTearDown(chrome.dispose);
    final editor = await mountEditor(tester, chrome: chrome);
    final page = editor.coreInfo.pages.first;
    await putLink(
      tester,
      editor,
      const PageLink(id: 'web', rect: webArea, target: 'https://example.com/notes'),
    );
    editor.currentTool = Select.currentSelect;
    // ignore: invalid_use_of_protected_member
    editor.setState(() {});
    await tester.pumpAndSettle();

    await tester.tapAt(page.renderBox!.localToGlobal(const Offset(300, 400)));
    await tester.tap(
      find.byKey(const ValueKey('page-link-badge-web')),
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();
    expect(opened, isEmpty);
    editor.cancelAutosaveAndMarkSaved();
  });

  testWidgets('emptying the page before a linked page keeps the linked page', (
    tester,
  ) async {
    final editor = await mountEditor(tester);
    await holdPen(tester, editor);
    final first = editor.coreInfo.pages.first;
    await drag(tester, first, const Offset(200, 300), const Offset(400, 320));
    expect(editor.coreInfo.pages, hasLength(2));
    // A link on the empty page after the writing, then the writing undone.
    final linked = editor.coreInfo.pages[1];
    linked.links.add(
      const PageLink(
        id: 'kept',
        rect: Rect.fromLTWH(100, 100, 0, 0),
        target: 'https://example.com',
      ),
    );
    editor.undo();
    await tester.pumpAndSettle();
    expect(first.strokes, isEmpty);
    expect(editor.coreInfo.pages, contains(linked));
    expect(linked.links.single.id, 'kept');
    editor.cancelAutosaveAndMarkSaved();
  });

  testWidgets('undo and redo past a tidied page bring the link back', (
    tester,
  ) async {
    final editor = await mountEditor(tester);
    await holdPen(tester, editor);
    final first = editor.coreInfo.pages.first;
    await drag(tester, first, const Offset(200, 300), const Offset(400, 320));
    await pressLinkAdd(tester);
    await tester.tapAt(
      editor.coreInfo.pages[1].renderBox!.localToGlobal(const Offset(300, 200)),
    );
    await tester.pumpAndSettle();
    await chooseWeb(tester, 'https://example.com/next');
    expect(editor.coreInfo.pages[1].links, hasLength(1));

    // Undo the link, then the writing: the second page is empty and goes.
    editor.undo();
    editor.undo();
    await tester.pumpAndSettle();
    expect(first.strokes, isEmpty);
    expect(editor.coreInfo.pages, hasLength(1));

    editor.redo();
    editor.redo();
    await tester.pumpAndSettle();
    expect(first.strokes, hasLength(1));
    expect(editor.coreInfo.pages, hasLength(2));
    expect(editor.coreInfo.pages[1].links.single.target, 'https://example.com/next');
    editor.cancelAutosaveAndMarkSaved();
  });

  testWidgets('at phone width the badge and underline keep their size on screen', (
    tester,
  ) async {
    final editor = await mountEditor(tester, size: const Size(360, 640));
    await putLink(
      tester,
      editor,
      const PageLink(
        id: 'size',
        rect: Rect.fromLTWH(300, 300, 300, 120),
        target: 'https://example.com/size',
      ),
    );
    void expectScreenSizes(String when) {
      Rect onScreen(String key) => tester.getRect(find.byKey(ValueKey(key)));
      expect(
        onScreen('page-link-badge-size').width,
        moreOrLessEquals(22, epsilon: 0.5),
        reason: when,
      );
      expect(
        onScreen('page-link-underline-size').height,
        moreOrLessEquals(2, epsilon: 0.2),
        reason: when,
      );
      expect(
        onScreen('page-link-badge-touch-size').width,
        greaterThanOrEqualTo(47.5),
        reason: when,
      );
    }

    expectScreenSizes('a 1000-wide page fitted into 360');
    tester
        .state<CanvasGestureDetectorState>(find.byType(CanvasGestureDetector))
        .zoomTo(2);
    await tester.pumpAndSettle();
    expectScreenSizes('zoomed in twice');
    editor.cancelAutosaveAndMarkSaved();
  });

  testWidgets('a palm resting on an area while the pen writes opens nothing', (
    tester,
  ) async {
    final opened = <String>[];
    final chrome = EditorChromeController()
      ..openLink = (link) async => opened.add(link);
    addTearDown(chrome.dispose);
    final editor = await mountEditor(tester, chrome: chrome);
    final page = editor.coreInfo.pages.first;
    await putLink(
      tester,
      editor,
      const PageLink(id: 'web', rect: webArea, target: 'https://example.com/notes'),
    );
    final inArea = page.renderBox!.localToGlobal(const Offset(300, 400));

    // The palm lands on the link, the pen writes below it, then both lift.
    final palm = await tester.startGesture(inArea);
    await drag(tester, page, const Offset(250, 800), const Offset(500, 820));
    await palm.up();
    await tester.pumpAndSettle();
    expect(page.strokes, hasLength(1));
    expect(opened, isEmpty);

    // A long hold without the pen is not a tap either.
    final hold = await tester.createGesture();
    await hold.down(inArea, timeStamp: const Duration(seconds: 10));
    await tester.pump(const Duration(milliseconds: 700));
    await hold.up(timeStamp: const Duration(milliseconds: 10700));
    await tester.pumpAndSettle();
    expect(opened, isEmpty);

    await tester.tapAt(inArea);
    await tester.pumpAndSettle();
    expect(opened, ['https://example.com/notes']);
    editor.cancelAutosaveAndMarkSaved();
  });

  testWidgets('the pen opens a link on the badge circle only, a finger in a larger box', (
    tester,
  ) async {
    final opened = <String>[];
    final chrome = EditorChromeController()
      ..openLink = (link) async => opened.add(link);
    addTearDown(chrome.dispose);
    final editor = await mountEditor(tester, chrome: chrome);
    await putLink(
      tester,
      editor,
      const PageLink(
        id: 'icon',
        rect: Rect.fromLTWH(400, 500, 0, 0),
        target: 'https://example.com/icon',
      ),
    );
    final circle = tester.getRect(find.byKey(const ValueKey('page-link-badge-icon')));
    final box = tester.getRect(
      find.byKey(const ValueKey('page-link-badge-touch-icon')),
    );
    final aside = circle.centerRight + const Offset(8, 0);
    expect(box.contains(aside), isTrue);

    final penAside = await tester.startGesture(
      aside,
      kind: PointerDeviceKind.stylus,
    );
    await penAside.up();
    await tester.pumpAndSettle();
    expect(opened, isEmpty, reason: 'the pen writes next to the circle');

    await tester.tapAt(aside);
    await tester.pumpAndSettle();
    expect(opened, ['https://example.com/icon']);

    final penOn = await tester.startGesture(
      circle.center,
      kind: PointerDeviceKind.stylus,
    );
    await penOn.up();
    await tester.pumpAndSettle();
    expect(opened, hasLength(2));
    editor.cancelAutosaveAndMarkSaved();
  });

  testWidgets('링크 추가 leaves another message alone and its hint closes with the editor', (
    tester,
  ) async {
    final shown = ValueNotifier(true);
    addTearDown(shown.dispose);
    final editor = await mountEditor(
      tester,
      around: (editor) => Scaffold(
        body: ValueListenableBuilder(
          valueListenable: shown,
          builder: (context, on, _) => on ? editor : const SizedBox(),
        ),
      ),
    );
    await holdPen(tester, editor);
    final messenger = ScaffoldMessenger.of(tester.element(find.byType(Editor)));
    messenger.showSnackBar(
      const SnackBar(content: Text('다른 알림'), duration: Duration(minutes: 1)),
    );
    await tester.pumpAndSettle();

    // Waiting for a tap does not push the other message away.
    await pressLinkAdd(tester);
    expect(find.text('다른 알림'), findsOneWidget);
    expect(find.byKey(const ValueKey('page-link-place')), findsWidgets);
    // Nor does ending the wait while its hint is still queued.
    await pressLinkAdd(tester);
    expect(find.byKey(const ValueKey('page-link-place')), findsNothing);
    expect(find.text('다른 알림'), findsOneWidget);
    // The stale hint closes itself when its turn comes.
    messenger.hideCurrentSnackBar();
    await tester.pumpAndSettle();
    expect(find.text('링크를 둘 곳을 누르세요'), findsNothing);

    await pressLinkAdd(tester);
    expect(find.text('링크를 둘 곳을 누르세요'), findsOneWidget);
    editor.cancelAutosaveAndMarkSaved();
    shown.value = false;
    await tester.pumpAndSettle();
    expect(find.byType(Editor), findsNothing);
    expect(find.text('링크를 둘 곳을 누르세요'), findsNothing);
  });

  testWidgets('without a host a note link says it cannot open other notes', (
    tester,
  ) async {
    final editor = await mountEditor(tester);
    await putLink(
      tester,
      editor,
      const PageLink(id: 'note', rect: webArea, target: 'inkvault://note/$noteId'),
    );
    await tester.tap(find.byKey(const ValueKey('page-link-badge-note')));
    await tester.pump();
    expect(find.text('이 화면에서는 다른 노트를 열 수 없습니다'), findsOneWidget);
    await tester.pumpAndSettle();
    editor.cancelAutosaveAndMarkSaved();
  });
}
