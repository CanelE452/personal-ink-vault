import 'package:flutter/gestures.dart'
    show PointerDeviceKind, kLongPressTimeout;
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart'
    show FlutterQuillLocalizations;
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/canvas/interactive_canvas.dart';
import 'package:saber/components/ink_ui/floating_bar/kit_floating_bar.dart';
import 'package:saber/components/ink_ui/pen_panel/kit_pen_panel.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/editor/editor.dart';
import 'package:sbn/tool_id.dart';

import '../utils/shown.dart';
import '../utils/test_mock_channel_handlers.dart';

/// The things over the editor's page (Task 13B-2): the floating bar growing
/// from the toolbar button, hiding while a stroke passes under it, its one
/// row on a phone, and the writing/gesture mode pill.
void main() {
  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    setupMockPathProvider();
    setupMockPrinting();
    setupMockWindowManager();
    FlavorConfig.setup();
    await FileManager.init();
    final saved = (
      stows.lastTool.value,
      stows.lastPenFamily.value,
      stows.editorToolbarTools.value,
      stows.pageToolbarLayout.value,
      stows.floatingBarPosition.value,
    );
    stows.lastTool.value = ToolId.fountainPen;
    stows.lastPenFamily.value = ToolId.fountainPen;
    stows.editorToolbarTools.value = const [];
    stows.pageToolbarLayout.value = const [];
    stows.floatingBarPosition.value = 'top';
    stows.editorGestureMode.value = false;
    addTearDown(() {
      stows.lastTool.value = saved.$1;
      stows.lastPenFamily.value = saved.$2;
      stows.editorToolbarTools.value = saved.$3;
      stows.pageToolbarLayout.value = saved.$4;
      stows.floatingBarPosition.value = saved.$5;
      stows.editorGestureMode.value = false;
    });
  });

  Future<EditorState> mountEditor(
    WidgetTester tester, {
    Size size = const Size(1000, 1400),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MediaQuery(
        data: MediaQueryData(size: size),
        child: TranslationProvider(
          child: MaterialApp(
            localizationsDelegates: const [FlutterQuillLocalizations.delegate],
            home: Editor(
              path: '/editor-floating',
              onSaveSnapshot: (_, _) async {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return tester.state<EditorState>(find.byType(Editor));
  }

  Finder key(String k) => find.byKey(ValueKey(k));
  final bar = key('kit-floating-bar');

  /// The page area under the toolbar: the floating bar fills it.
  Rect pageArea(WidgetTester tester) =>
      tester.getRect(find.byType(KitFloatingBar));

  int strokes(EditorState editor) =>
      editor.coreInfo.pages.expand((page) => page.strokes).length;

  /// Where a stroke may start on the first page, below the bar's place.
  Offset onPage(WidgetTester tester, EditorState editor, double dy) {
    final page = editor.coreInfo.pages.first;
    final box = page.renderBox!;
    final rect = Rect.fromPoints(
      box.localToGlobal(Offset.zero),
      box.localToGlobal(page.size.bottomRight(Offset.zero)),
    ).intersect(tester.getRect(find.byType(InteractiveCanvasViewer)));
    return Offset(rect.left + 300, pageArea(tester).top + dy);
  }

  testWidgets('the floating bar grows from the button that shows it', (
    tester,
  ) async {
    await mountEditor(tester);
    final area = pageArea(tester);
    final full = tester.getRect(bar);
    expect(full.topLeft, area.topLeft + const Offset(10, 10));

    // Where the bar is while it grows or goes, scaled about the top of the
    // toolbar button's middle (values §14-4).
    void expectAbout(Finder button, double width, String why) {
      final now = tester.getRect(bar);
      final s = now.width / width;
      expect(s, inExclusiveRange(0.92, 1), reason: why);
      final ox = tester.getCenter(button).dx - full.left;
      expect(now.left, moreOrLessEquals(full.left + ox * (1 - s)), reason: why);
      expect(now.top, moreOrLessEquals(full.top), reason: why);
    }

    // the pen button hides it: it goes into the pen button
    await tester.tap(key('editor-tool-pen'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expectAbout(key('editor-tool-pen'), full.width, 'going into the pen');
    await tester.pump(const Duration(milliseconds: 141));
    await tester.pump();
    expect(bar, findsNothing, reason: 'gone after 200 ms');

    // the eraser shows it: it grows from the eraser button
    await tester.tap(key('editor-tool-eraser'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    // the eraser's bar (10th draft): the undo pill 80, 6, the tool pill 226
    // with the test font (its chip 67: 「획」 13 wide)
    const eraserBar = 80 + 6 + 226.0;
    expectAbout(
      key('editor-tool-eraser'),
      eraserBar,
      'growing from the eraser',
    );
    expect(shownOf(tester, bar), inExclusiveRange(0, 1));
    await tester.pump(const Duration(milliseconds: 141));
    expect(
      tester.getRect(bar),
      Rect.fromLTWH(full.left, full.top, eraserBar, 40),
    );
    expect(shownOf(tester, bar), 1);
  });

  testWidgets('a stroke under the bar hides it until the pen is lifted', (
    tester,
  ) async {
    final editor = await mountEditor(tester);
    final undo = key('floating-bar-undo');
    final barRect = tester.getRect(bar);
    final from = onPage(tester, editor, 140);

    // a pen hovering over the bar leaves it (its buttons take the pen)
    final hover = await tester.createGesture(kind: PointerDeviceKind.stylus);
    await hover.addPointer(location: from);
    await hover.moveTo(barRect.center);
    await tester.pump(const Duration(milliseconds: 200));
    expect(shownOf(tester, bar), 1);
    expect(takesPresses(tester, undo), isTrue);
    await hover.removePointer();

    // a stroke from below into the bar's place (its box and 12 around)
    final pen = await tester.createGesture(kind: PointerDeviceKind.stylus);
    await pen.down(from);
    await pen.moveTo(from - const Offset(0, 40));
    await tester.pump();
    // 70 below the bar's foot: still outside
    expect(shownOf(tester, bar), 1);
    await pen.moveTo(Offset(from.dx, barRect.bottom + 11));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(shownOf(tester, bar), 0, reason: 'faded in 120 ms');
    expect(takesPresses(tester, undo), isFalse);
    await pen.moveTo(Offset(from.dx, barRect.center.dy));
    await pen.up();
    await tester.pump();
    expect(strokes(editor), 1, reason: 'the stroke went on the page');

    // back 600 ms after the pen is lifted
    await tester.pump(const Duration(milliseconds: 599));
    expect(shownOf(tester, bar), 0);
    expect(takesPresses(tester, undo), isFalse);
    // writing again in the wait keeps it hidden and waits again
    await pen.down(from);
    await pen.moveTo(from + const Offset(30, 5));
    await pen.moveTo(from + const Offset(60, 10));
    await pen.up();
    await tester.pump(const Duration(milliseconds: 300));
    expect(shownOf(tester, bar), 0);
    expect(strokes(editor), 2);
    await tester.pump(const Duration(milliseconds: 299));
    expect(takesPresses(tester, undo), isFalse);
    await tester.pump(const Duration(milliseconds: 2));
    expect(takesPresses(tester, undo), isTrue);
    await tester.pump(const Duration(milliseconds: 200));
    expect(shownOf(tester, bar), 1, reason: 'shown again in 200 ms');

    // a press that starts on the bar is the bar's
    await tester.tap(undo, kind: PointerDeviceKind.stylus);
    await tester.pump(const Duration(milliseconds: 150));
    expect(strokes(editor), 1);
    expect(shownOf(tester, bar), 1);
    editor.cancelAutosaveAndMarkSaved();
  });

  testWidgets('at phone width the bar is one row and only its tools slide', (
    tester,
  ) async {
    await mountEditor(tester, size: const Size(360, 640));
    expect(tester.takeException(), isNull);
    final area = pageArea(tester);
    final undoPill = key('floating-bar-undo-pill');
    final toolPill = key('floating-bar-tool-pill');
    // values §13-2: undo pill 80 at 10, the tools 254 from 96 (page − 20)
    expect(
      tester.getRect(undoPill),
      Rect.fromLTWH(area.left + 10, area.top + 10, 80, 40),
    );
    expect(
      tester.getRect(toolPill),
      Rect.fromLTWH(area.left + 96, area.top + 10, 254, 40),
    );
    final pencil = tester.getRect(key('floating-bar-pen-pencil'));
    await tester.drag(toolPill, const Offset(-300, 0));
    await tester.pumpAndSettle();
    expect(tester.getRect(undoPill).left, area.left + 10, reason: 'undo stays');
    expect(tester.getRect(toolPill).left, area.left + 96);
    expect(
      tester.getRect(key('floating-bar-pen-pencil')).left,
      lessThan(pencil.left),
      reason: 'the tools slid',
    );
    // the colour wheel at the end is all in view
    expect(
      tester.getRect(key('floating-bar-custom-colour')).right,
      lessThanOrEqualTo(area.left + 350),
    );
    await tester.drag(toolPill, const Offset(300, 0));
    await tester.pumpAndSettle();

    // the pen panel it opens stays on the page, under the bar; taller than
    // the room there, it scrolls inside (design doc: phone row)
    final barRect = tester.getRect(bar);
    await tester.tap(key('floating-bar-pen-fountain'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    // the window: what of the panel shows
    final window = find
        .ancestor(
          of: find.byType(KitPenPanel),
          matching: find.byType(SingleChildScrollView),
        )
        .first;
    final panel = tester.getRect(window);
    // 8 under the bar, as a window that fits (floatingBarPanelGap)
    expect(panel.top - barRect.bottom, 8, reason: '$panel');
    final inside = tester.getRect(find.byType(KitPenPanel));
    expect(inside.height, greaterThan(panel.height), reason: 'taller');
    // from the panel's head (the middle may be the slider, which keeps the
    // touch)
    await tester.dragFrom(
      panel.topLeft + const Offset(20, 20),
      const Offset(0, -200),
    );
    await tester.pumpAndSettle();
    expect(
      tester.getRect(find.byType(KitPenPanel)).top,
      lessThan(inside.top),
      reason: 'it slides up inside',
    );
    // the width slider dragged up and down along the way keeps the window
    // where it is (the slider takes the touch)
    final scroll = tester
        .state<ScrollableState>(
          find.descendant(of: window, matching: find.byType(Scrollable)).first,
        )
        .position;
    final slid = scroll.pixels;
    final track = find
        .descendant(
          of: window,
          matching: find.byKey(const Key('kit-slider-track')),
        )
        .first;
    final g = await tester.startGesture(tester.getCenter(track));
    for (var i = 0; i < 6; i++) {
      // 60 down in all: a window that took the drag would move
      await g.moveBy(Offset(8, i < 3 ? 40 : -20));
      await tester.pump();
    }
    await g.up();
    await tester.pumpAndSettle();
    expect(scroll.pixels, slid);
    expect(area.contains(panel.topLeft), isTrue, reason: '$panel in $area');
    expect(
      area.inflate(0.01).contains(panel.bottomRight),
      isTrue,
      reason: '$panel in $area',
    );
  });

  testWidgets('the zoom badge stays while two fingers rest on the page', (
    tester,
  ) async {
    // the real path: the canvas's contacts -> CanvasHud -> the badge
    await mountEditor(tester);
    final pill = key('zoom-badge-pill');
    final centre = tester.getCenter(find.byType(InteractiveCanvasViewer));
    final a = await tester.startGesture(centre - const Offset(60, 0));
    final b = await tester.startGesture(centre + const Offset(60, 0));
    for (var i = 0; i < 6; i++) {
      await a.moveBy(const Offset(-15, 0));
      await b.moveBy(const Offset(15, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pump(const Duration(milliseconds: 150));
    expect(shownOf(tester, pill), 1, reason: 'zooming');
    // fingers still down, no change for 1.5 s
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    expect(shownOf(tester, pill), 1, reason: 'fingers still down');
    await a.up();
    await b.up();
    await tester.pump(const Duration(milliseconds: 999));
    expect(shownOf(tester, pill), 1);
    await tester.pump(const Duration(milliseconds: 2));
    await tester.pump(const Duration(milliseconds: 106));
    await tester.pump();
    expect(shownOf(tester, pill), 0, reason: 'gone a second after the lift');
    await tester.pumpAndSettle();
  });

  testWidgets('a hold without a move leaves the bar where it is', (
    tester,
  ) async {
    await mountEditor(tester);
    final undo = key('floating-bar-undo');
    for (final move in const [Offset.zero, Offset(4, 6)]) {
      final g = await tester.startGesture(tester.getCenter(undo));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      if (move != Offset.zero) {
        await g.moveBy(move);
        await tester.pump();
      }
      await g.up();
      await tester.pumpAndSettle();
      expect(stows.floatingBarPosition.value, 'top', reason: '$move');
      expect(
        tester.getTopLeft(bar),
        pageArea(tester).topLeft + const Offset(10, 10),
      );
    }
  });

  // Final review B-4: a note opened in gesture mode says so once.
  testWidgets('a note opened in gesture mode shows the mode pill once', (
    tester,
  ) async {
    final pill = key('kit-mode-pill');
    String? said() => tester
        .widgetList<Text>(
          find.descendant(of: pill, matching: find.byType(Text)),
        )
        .firstOrNull
        ?.data;
    stows.editorGestureMode.value = true;
    await mountEditor(tester);
    expect(said(), '제스처 모드');
    expect(shownOf(tester, pill), 1);
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(said(), isNull, reason: 'gone after 2 s');

    // in writing mode a note opens without it
    await tester.pumpWidget(const SizedBox());
    stows.editorGestureMode.value = false;
    await mountEditor(tester);
    expect(said(), isNull);
  });

  testWidgets('switching writing and gesture mode shows the mode pill', (
    tester,
  ) async {
    await mountEditor(tester);
    final pill = key('kit-mode-pill');
    String? said() => tester
        .widgetList<Text>(
          find.descendant(of: pill, matching: find.byType(Text)),
        )
        .firstOrNull
        ?.data;

    await tester.tap(key('editor-mode'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(said(), '제스처 모드');
    expect(shownOf(tester, pill), 1);
    final area = pageArea(tester);
    final rect = tester.getRect(pill);
    expect(rect.bottom, area.bottom - 64);
    expect(rect.center.dx, moreOrLessEquals(area.center.dx));
    expect(rect.height, 30);
    expect(rect.width, lessThan(150), reason: 'as wide as its words');
    expect(
      tester
          .widget<Text>(find.descendant(of: pill, matching: find.byType(Text)))
          .style!
          .letterSpacing,
      0,
    );
    await tester.pump(const Duration(milliseconds: 1849));
    expect(shownOf(tester, pill), 1, reason: 'two seconds');
    await tester.pump(const Duration(milliseconds: 2));
    await tester.pump(const Duration(milliseconds: 106));
    await tester.pump();
    expect(said(), isNull, reason: 'gone after 2 s');

    // a tool button goes back to writing
    await tester.tap(key('editor-tool-pen'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(said(), '필기 모드');
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(said(), isNull);
  });
}
