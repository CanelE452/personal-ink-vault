import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/ink_ui/editor_toolbar/kit_editor_toolbar.dart';
import 'package:saber/components/ink_ui/floating_bar/kit_floating_bar.dart';
import 'package:saber/components/ink_ui/pen_panel/kit_pen_panel.dart';
import 'package:saber/components/ink_ui/pen_panel/size_level.dart';
import 'package:saber/components/kit/kit_controls.dart';
import 'package:saber/components/kit/kit_icon.dart';
import 'package:saber/components/kit/kit_pill.dart';
import 'package:saber/components/kit/kit_tokens.dart';
import 'package:saber/data/actions/app_action.dart';
import 'package:saber/data/actions/app_action_ids.dart';
import 'package:saber/data/actions/app_action_registry.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/tools/eraser_targets.dart';
import 'package:saber/data/tools/pen.dart';
import 'package:saber/data/vault/infinite_document.dart';

import '../utils/shown.dart';
import 'infinite_canvas_harness.dart';

/// The infinite note on the editor's toolbar, floating bar, pen panel and
/// windows (Task 18): the tools its engine has in order, 원점으로 · 저장,
/// what the engine lacks hidden, the windows' values on the engine, its own
/// actions, gesture mode, the pen tip badge and the bar out of a stroke's
/// way. The old dock is gone.
void main() {
  setUp(() {
    FlavorConfig.setup();
    resetInkSettings();
  });

  testWidgets('infinite canvas uses the kit toolbar in order', (tester) async {
    await mount(tester);
    expect(find.byType(KitEditorToolbar), findsOneWidget);
    // 필기/제스처, then the tools the engine has in the editor's order
    // (올가미 · 펜 · 지우개), then 이동
    final xs = [
      for (final key in [
        'editor-mode',
        'editor-tool-lasso',
        'editor-tool-pen',
        'editor-tool-eraser',
        'editor-tool-move',
      ])
        tester.getCenter(byKey(key)).dx,
    ];
    for (var i = 1; i < xs.length; i++) {
      expect(xs[i], greaterThan(xs[i - 1]), reason: 'button $i');
    }
    expect(find.byTooltip('이동'), findsOneWidget);
    expect(
      tester
          .widget<KitIcon>(
            find.descendant(
              of: byKey('editor-tool-move'),
              matching: find.byType(KitIcon),
            ),
          )
          .name,
      KitIconName.move,
    );
    // what the engine lacks, the accessories, the note window, ⌄ and ⋯
    for (final key in [
      'editor-tool-text',
      'editor-tool-shapes',
      'editor-tool-image',
      'editor-tool-laser',
      'editor-page-list',
      'editor-note-sheet',
      'editor-tools-more',
      'editor-insert-page',
      'editor-fullscreen',
      'editor-doc-menu',
    ]) {
      expect(byKey(key), findsNothing, reason: key);
    }
    // the pen is in hand; the bar lies over the page's top
    expect(selected(tester, byKey('editor-tool-pen')), isTrue);
    final bar = tester.getRect(find.byType(KitEditorToolbar));
    expect(bar.height, KitTokens.toolbarHeight);
    expect(tester.getTopLeft(surface).dy, bar.bottom);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('origin and save sit in the right slots', (tester) async {
    final saved = <InfiniteDocument>[];
    final key = await mount(
      tester,
      initialViewport: const InfiniteViewport(
        offset: Offset(-500, 80),
        scale: 2,
      ),
      onSave: (doc) async => saved.add(doc),
    );
    final origin = byKey('editor-canvas-origin');
    final save = byKey('editor-canvas-save');
    expect(find.byTooltip('원점으로'), findsOneWidget);
    expect(find.byTooltip('저장'), findsOneWidget);
    // after the sliding middle, origin before save, at the bar's end
    final middle = tester.getRect(byKey('editor-tools-scroll'));
    expect(tester.getRect(origin).left, greaterThanOrEqualTo(middle.right));
    expect(
      tester.getRect(save).left,
      greaterThanOrEqualTo(tester.getRect(origin).right),
    );
    expect(tester.getRect(save).right, greaterThan(800 - 20));
    await tester.tap(origin);
    await tester.pump();
    expect(key.currentState!.viewport.offset, Offset.zero);
    expect(key.currentState!.viewport.scale, 1);
    await draw(tester, [const Offset(100, 200), const Offset(140, 220)]);
    await tester.tap(save);
    await tester.pump();
    await tester.pump();
    expect(saved, hasLength(1));
    expect(saved.single.strokes, hasLength(1));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('pen panel size changes the infinite canvas pen', (tester) async {
    final key = await mount(tester);
    // the floating bar is up with the pen; its chosen pen opens the panel
    await press(tester, byKey('floating-bar-pen-fountain'));
    expect(find.byType(KitPenPanel), findsOneWidget);
    // the old width (2.5 of 1 to 8) on the panel's 1-100
    final before = sizeToLevel(2.5, min: 1, max: 8);
    expect(
      tester
          .widget<KitSlider>(
            find.descendant(
              of: byKey('pen-panel-size'),
              matching: find.byType(KitSlider),
            ),
          )
          .value,
      before,
    );
    await tester.tap(find.byTooltip('굵게'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(780, 580));
    await tester.pumpAndSettle();
    expect(find.byType(KitPenPanel), findsNothing);
    await draw(tester, [const Offset(100, 300), const Offset(160, 300)]);
    final written = key.currentState!.document.strokes.single;
    expect(written.tool, InfiniteInkTool.pen);
    expect(
      written.width,
      closeTo(levelToSize(before + 5, min: 1, max: 8), 1e-9),
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('old dock is gone', (tester) async {
    await mount(tester);
    expect(find.byTooltip('툴바 설정'), findsNothing);
    expect(byKey('infinite-toolbar'), findsNothing);
    // the bar is on top, whole (229's dock could sit on any side)
    final bar = tester.getRect(find.byType(KitEditorToolbar));
    expect(bar.topLeft, Offset.zero);
    expect(bar.width, 800);
    expect(byKey('editor-tool-move'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'pens the engine lacks stay hidden; the floating bar highlighter writes the infinite highlighter',
    (tester) async {
      final key = await mount(tester);
      expect(byKey('floating-bar-pen-fountain'), findsOneWidget);
      expect(byKey('floating-bar-pen-hlchisel'), findsOneWidget);
      for (final kind in ['pen', 'pencil', 'calli', 'brush', 'hlround']) {
        expect(byKey('floating-bar-pen-$kind'), findsNothing, reason: kind);
      }
      // the pen panel: its one pen, none of the editor's own rows
      await press(tester, byKey('floating-bar-pen-fountain'));
      expect(byKey('pen-panel-pen-fountain'), findsOneWidget);
      for (final row in [
        'pen-panel-pen-pen',
        'pen-panel-pen-pencil',
        'pen-panel-pen-box-open',
        'toolbar-pen-box',
        'toolbar-auto-straighten',
        'tool-panel-stabiliser',
      ]) {
        expect(byKey(row), findsNothing, reason: row);
      }
      await tester.tapAt(const Offset(780, 580));
      await tester.pumpAndSettle();

      await press(tester, byKey('floating-bar-pen-hlchisel'));
      expect(checked(tester, AppActionIds.toolHighlighter), isTrue);
      expect(selected(tester, byKey('editor-tool-pen')), isTrue);
      // the bar's highlighter has the engine's widths: 5 to 40, 12.5 now
      final inHand =
          tester
                  .widget<KitFloatingBar>(find.byType(KitFloatingBar))
                  .host
                  .toolState
                  .tool
              as Pen;
      expect((inHand.sizeMin, inHand.sizeMax), (5, 40));
      expect(inHand.options.size, 12.5);
      expect(inHand.sizePresets, [5, 12.5, 25]);
      await draw(tester, [const Offset(100, 300), const Offset(160, 300)]);
      final marker = key.currentState!.document.strokes.single;
      expect(marker.tool, InfiniteInkTool.highlighter);
      // the engine's highlighter: five times the pen width
      expect(marker.width, 12.5);
      // the highlighter panel: the flat highlighter alone, no switches
      await press(tester, byKey('floating-bar-pen-hlchisel'));
      expect(byKey('pen-panel-pen-hlchisel'), findsOneWidget);
      expect(byKey('pen-panel-pen-hlround'), findsNothing);
      expect(byKey('toolbar-auto-straighten'), findsNothing);
      expect(byKey('tool-panel-axis-lock'), findsNothing);
      await tester.tapAt(const Offset(780, 580));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'eraser and lasso windows show only what the infinite note can do',
    (tester) async {
      await mount(tester);
      await press(tester, byKey('editor-tool-eraser'));
      await press(tester, byKey('floating-bar-eraser-kind'));
      expect(byKey('eraser-kind-stroke'), findsOneWidget);
      expect(byKey('eraser-kind-lasso'), findsNothing);
      await tester.tapAt(const Offset(780, 580));
      await tester.pumpAndSettle();
      await press(tester, byKey('floating-bar-eraser-advanced'));
      expect(byKey('eraser-advanced-size'), findsOneWidget);
      expect(byKey('eraser-target-pen'), findsOneWidget);
      expect(byKey('eraser-target-highlighter'), findsOneWidget);
      expect(byKey('eraser-target-pencil'), findsNothing);
      expect(byKey('eraser-target-shape'), findsNothing);
      expect(byKey('eraser-auto-release'), findsOneWidget);
      expect(byKey('eraser-clear-page'), findsNothing);
      await tester.tapAt(const Offset(780, 580));
      await tester.pumpAndSettle();

      await press(tester, byKey('editor-tool-lasso'));
      await press(tester, byKey('editor-tool-lasso'));
      expect(byKey('lasso-kind-free'), findsOneWidget);
      expect(byKey('lasso-kind-rect'), findsOneWidget);
      expect(byKey('lasso-target-ink'), findsOneWidget);
      expect(byKey('lasso-target-highlighter'), findsOneWidget);
      expect(byKey('lasso-target-shape'), findsNothing);
      expect(byKey('lasso-target-images'), findsNothing);
      await tester.tapAt(const Offset(780, 580));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('the eraser follows its size, targets and auto release', (
    tester,
  ) async {
    final key = await mount(
      tester,
      initial: InfiniteDocument(
        strokes: [
          stroke(id: 'ink', x: 100, y: 200),
          stroke(
            id: 'marker',
            x: 100,
            y: 400,
            tool: InfiniteInkTool.highlighter,
          ),
        ],
      ),
    );
    List<String> ids() => [
      for (final s in key.currentState!.document.strokes) s.id,
    ];
    await press(tester, byKey('editor-tool-eraser'));
    // 20 from the pen stroke: out of the default size's reach
    await draw(tester, [const Offset(100, 180)]);
    expect(ids(), ['ink', 'marker']);
    await press(tester, byKey('floating-bar-eraser-size-40'));
    await draw(tester, [const Offset(100, 180)]);
    expect(ids(), ['marker']);
    // the highlighter off: the eraser passes over it
    await press(tester, byKey('floating-bar-eraser-advanced'));
    await tester.tap(byKey('eraser-target-highlighter'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(780, 580));
    await tester.pumpAndSettle();
    await draw(tester, [const Offset(105, 402)]);
    expect(ids(), ['marker']);
    // auto release: after a stroke the pen is back in hand
    stows.disableEraserAfterUse.value = true;
    await draw(tester, [const Offset(500, 500)]);
    await tester.pump();
    expect(checked(tester, AppActionIds.toolPen), isTrue);
    expect(checked(tester, AppActionIds.toolEraser), isFalse);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the lasso follows its kind and targets', (tester) async {
    final key = await mount(
      tester,
      initial: InfiniteDocument(strokes: [stroke(x: 100, y: 100)]),
    );
    Offset first() =>
        key.currentState!.document.strokes.single.points.first.offset;
    await press(tester, byKey('editor-tool-lasso'));
    // free: two points are no loop, so the drag after it moves nothing
    await draw(tester, [const Offset(80, 80), const Offset(150, 140)]);
    await draw(tester, [const Offset(110, 105), const Offset(160, 135)]);
    expect(first(), const Offset(100, 100));
    // rectangle: the same two points span a box
    stows.selectRectangle.value = true;
    await tester.pump();
    await draw(tester, [const Offset(80, 80), const Offset(150, 140)]);
    await draw(tester, [const Offset(110, 105), const Offset(160, 135)]);
    expect(first(), const Offset(150, 130));
    // handwriting off: the box picks nothing up
    stows.selectInk.value = false;
    await draw(tester, [const Offset(130, 110), const Offset(200, 170)]);
    await draw(tester, [const Offset(160, 135), const Offset(210, 165)]);
    expect(first(), const Offset(150, 130));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'undo, redo, the move tool, origin and save run through the registry',
    (tester) async {
      final saved = <InfiniteDocument>[];
      final key = await mount(tester, onSave: (doc) async => saved.add(doc));
      final actions = actionsOf(tester);
      expect(actions.parent, isNull);
      for (final id in [
        AppActionIds.undo,
        AppActionIds.redo,
        AppActionIds.toolPen,
        AppActionIds.toolHighlighter,
        AppActionIds.toolEraser,
        AppActionIds.toolLasso,
        AppActionIds.toolMove,
        AppActionIds.canvasOrigin,
        AppActionIds.canvasSave,
      ]) {
        expect(actions.lookup(id), isNotNull, reason: id);
      }
      for (final id in [
        AppActionIds.toolText,
        AppActionIds.toolShapes,
        AppActionIds.toolPencil,
        AppActionIds.toolLaser,
        AppActionIds.pickPhoto,
      ]) {
        expect(actions.lookup(id), isNull, reason: id);
      }
      final context = tester.element(find.byType(KitEditorToolbar));
      await draw(tester, [const Offset(100, 200), const Offset(160, 200)]);
      expect(actions.run(AppActionIds.undo, context), isTrue);
      await tester.pump();
      expect(key.currentState!.document.strokes, isEmpty);
      expect(actions.run(AppActionIds.redo, context), isTrue);
      await tester.pump();
      expect(key.currentState!.document.strokes, hasLength(1));

      expect(actions.run(AppActionIds.toolMove, context), isTrue);
      await tester.pump();
      await tester.pump();
      expect(checked(tester, AppActionIds.toolMove), isTrue);
      expect(selected(tester, byKey('editor-tool-move')), isTrue);
      // the pen moves the view and writes nothing
      await draw(tester, [const Offset(300, 300), const Offset(350, 340)]);
      expect(key.currentState!.document.strokes, hasLength(1));
      expect(key.currentState!.viewport.offset, const Offset(50, 40));

      expect(actions.run(AppActionIds.canvasOrigin, context), isTrue);
      await tester.pump();
      expect(key.currentState!.viewport.offset, Offset.zero);
      expect(actions.run(AppActionIds.canvasSave, context), isTrue);
      await tester.pump();
      await tester.pump();
      expect(saved, hasLength(1));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('gesture mode moves the view with the pen and writes nothing', (
    tester,
  ) async {
    final key = await mount(tester);
    await press(tester, byKey('editor-mode'));
    expect(stows.editorGestureMode.value, isTrue);
    expect(byKey('kit-floating-bar'), findsNothing);
    await draw(tester, [const Offset(300, 300), const Offset(330, 320)]);
    expect(key.currentState!.document.strokes, isEmpty);
    expect(key.currentState!.viewport.offset, const Offset(30, 20));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the pen tip badge shows the infinite tool in hand', (
    tester,
  ) async {
    await mount(tester);
    final badge = byKey('kit-hover-badge');
    KitIconName icon() => tester
        .widget<KitIcon>(
          find.descendant(of: badge, matching: find.byType(KitIcon)),
        )
        .name;
    final tip = tester.getTopLeft(surface) + const Offset(300, 300);
    final pen = await tester.createGesture(kind: PointerDeviceKind.stylus);
    await pen.addPointer(location: tip - const Offset(4, 4));
    await pen.moveTo(tip);
    await tester.pump();
    expect(icon(), KitIconName.pen);
    expect(tester.getCenter(byKey('kit-hover-dot')), tip);
    final context = tester.element(find.byType(KitEditorToolbar));
    actionsOf(tester).run(AppActionIds.toolMove, context);
    await tester.pump();
    expect(icon(), KitIconName.move);
    // gesture mode: a touch would not use the tool
    stows.editorGestureMode.value = true;
    await tester.pump();
    expect(badge, findsNothing);
    await pen.removePointer();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a stroke near the floating bar fades it out of the way', (
    tester,
  ) async {
    await mount(tester);
    final bar = byKey('kit-floating-bar');
    expect(shownOf(tester, bar), 1);
    final page = tester.getTopLeft(surface);
    final under = tester.getRect(bar).bottom - page.dy + 6;
    final gesture = await tester.createGesture(
      kind: PointerDeviceKind.stylus,
      pointer: 4,
    );
    await gesture.down(page + Offset(200, under));
    await tester.pump();
    await gesture.moveTo(page + Offset(240, under));
    await tester.pump(const Duration(milliseconds: 200));
    expect(shownOf(tester, bar), 0);
    expect(takesPresses(tester, byKey('floating-bar-undo')), isFalse);
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();
    expect(shownOf(tester, bar), 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the first colour is the floating bar\'s first dot', (
    tester,
  ) async {
    final key = await mount(
      tester,
      initial: InfiniteDocument(strokes: [stroke(x: 100, y: 400)]),
    );
    final first = byKey('floating-bar-colour-0');
    expect(tester.widget<KitColorDot>(first).selected, isTrue);
    await draw(tester, [const Offset(100, 200), const Offset(160, 200)]);
    final strokes = key.currentState!.document.strokes;
    expect(
      strokes.last.color,
      KitTokens.floatingBarDefaultColors.first.toARGB32(),
    );
    expect(strokes.first.color, 0xff112233, reason: 'a kept stroke stays');
    await tester.pumpWidget(const SizedBox());
    // with recent colours the first dot is the first of them
    const blue = Color(0xff2f80ed);
    stows.recentColorsPositioned.value = ['${blue.toARGB32()}'];
    final again = await mount(tester);
    expect(tester.widget<KitColorDot>(first).selected, isTrue);
    await draw(tester, [const Offset(100, 200), const Offset(160, 200)]);
    expect(again.currentState!.document.strokes.single.color, blue.toARGB32());
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the editor\'s keys: undo, redo, eraser, finger, the bar', (
    tester,
  ) async {
    final key = await mount(tester);
    Future<void> keys(
      List<LogicalKeyboardKey> held,
      LogicalKeyboardKey k,
    ) async {
      for (final h in held) {
        await tester.sendKeyDownEvent(h);
      }
      await tester.sendKeyEvent(k);
      for (final h in held.reversed) {
        await tester.sendKeyUpEvent(h);
      }
      await tester.pumpAndSettle();
    }

    const ctrl = LogicalKeyboardKey.controlLeft;
    const shift = LogicalKeyboardKey.shiftLeft;
    await draw(tester, [const Offset(100, 200), const Offset(160, 200)]);
    int strokes() => key.currentState!.document.strokes.length;
    await keys([ctrl], LogicalKeyboardKey.keyZ);
    expect(strokes(), 0);
    await keys([ctrl], LogicalKeyboardKey.keyY);
    expect(strokes(), 1);
    await keys([ctrl], LogicalKeyboardKey.keyZ);
    await keys([ctrl, shift], LogicalKeyboardKey.keyZ);
    expect(strokes(), 1);
    // Ctrl+C hides and shows the floating bar
    await keys([ctrl], LogicalKeyboardKey.keyC);
    expect(byKey('kit-floating-bar'), findsNothing);
    await keys([ctrl], LogicalKeyboardKey.keyC);
    expect(byKey('kit-floating-bar'), findsOneWidget);
    // Ctrl+E: the eraser with its bar, out of gesture mode
    stows.editorGestureMode.value = true;
    await keys([ctrl], LogicalKeyboardKey.keyE);
    expect(checked(tester, AppActionIds.toolEraser), isTrue);
    expect(stows.editorGestureMode.value, isFalse);
    expect(byKey('floating-bar-eraser-kind'), findsOneWidget);
    // Ctrl+F: finger writing
    await keys([ctrl], LogicalKeyboardKey.keyF);
    expect(stows.editorFingerDrawing.value, isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('nothing changes the pen while a stroke goes on', (tester) async {
    final key = await mount(tester);
    final page = tester.getTopLeft(surface);
    final pen = await tester.createGesture(
      kind: PointerDeviceKind.stylus,
      pointer: 5,
    );
    await pen.down(page + const Offset(400, 400));
    await pen.moveTo(page + const Offset(450, 420));
    await tester.pump();
    // the bar is clear of the stroke: its pens and widths take taps
    await tester.tap(byKey('floating-bar-pen-hlchisel'));
    await tester.pump();
    expect(checked(tester, AppActionIds.toolPen), isTrue);
    // nor the width (a window would end the stroke first: opening one
    // cancels the pointers under it)
    (tester
                .widget<KitFloatingBar>(find.byType(KitFloatingBar))
                .host
                .toolState
                .tool
            as Pen)
        .setSize(5);
    await tester.pump();
    await pen.up();
    await tester.pump();
    await draw(tester, [const Offset(100, 300), const Offset(160, 300)]);
    final strokes = key.currentState!.document.strokes;
    expect(strokes.map((s) => (s.tool, s.width)), [
      (InfiniteInkTool.pen, 2.5),
      (InfiniteInkTool.pen, 2.5),
    ]);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'with only kinds it cannot see on, the eraser rubs out pens and the lasso '
    'picks up handwriting',
    (tester) async {
      // the editor left only the pencil and shapes on
      stows.eraserTargets.value = const ['pencil', 'shape'];
      stows.selectInk.value = false;
      stows.selectHighlighter.value = false;
      final key = await mount(
        tester,
        initial: InfiniteDocument(
          strokes: [
            stroke(id: 'ink', x: 100, y: 200),
            stroke(id: 'kept', x: 300, y: 300),
          ],
        ),
      );
      await press(tester, byKey('editor-tool-eraser'));
      await draw(tester, [const Offset(105, 202)]);
      expect(key.currentState!.document.strokes.map((s) => s.id), ['kept']);
      // its window keeps the first row it shows on, and that one stays
      await press(tester, byKey('floating-bar-eraser-advanced'));
      expect(EraserTargets.value, contains(StrokeKind.pen));
      expect(byKey('eraser-target-message'), findsNothing);
      await tester.tap(byKey('eraser-target-pen'));
      await tester.pumpAndSettle();
      expect(EraserTargets.value, contains(StrokeKind.pen));
      await tester.tapAt(const Offset(780, 580));
      await tester.pumpAndSettle();
      // the lasso: handwriting, as if it were on
      await press(tester, byKey('editor-tool-lasso'));
      await draw(tester, [
        const Offset(280, 280),
        const Offset(340, 280),
        const Offset(340, 330),
        const Offset(280, 330),
      ]);
      await draw(tester, [const Offset(305, 305), const Offset(325, 325)]);
      expect(
        key.currentState!.document.strokes.single.points.first.offset,
        const Offset(320, 320),
      );
      // (the eraser's window kept handwriting on too; off again here)
      stows.selectInk.value = false;
      await press(tester, byKey('editor-tool-lasso'));
      expect(stows.selectInk.value, isTrue);
      expect(byKey('lasso-target-hint'), findsOneWidget);
      await tester.tapAt(const Offset(780, 580));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('finger writing follows the editor\'s setting', (tester) async {
    final key = await mount(tester);
    Future<void> swipe() async {
      final page = tester.getTopLeft(surface);
      final finger = await tester.createGesture(
        kind: PointerDeviceKind.touch,
        pointer: 6,
      );
      await finger.down(page + const Offset(100, 300));
      await finger.moveTo(page + const Offset(160, 320));
      await finger.up();
      await tester.pump();
    }

    await swipe();
    expect(key.currentState!.document.strokes, isEmpty);
    expect(key.currentState!.viewport.offset, const Offset(60, 20));
    // turned on (the editor's ⋯, the workspace row or Ctrl+F): a finger writes
    actionsOf(
      tester,
    ).run(AppActionIds.finger, tester.element(find.byType(KitEditorToolbar)));
    expect(stows.editorFingerDrawing.value, isTrue);
    await tester.pump();
    await swipe();
    expect(key.currentState!.document.strokes, hasLength(1));
    expect(checked(tester, AppActionIds.finger), isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('saving shows a clock and 저장 중 on the save button', (
    tester,
  ) async {
    final write = Completer<void>();
    await mount(tester, onSave: (_) => write.future);
    final save = byKey('editor-canvas-save');
    KitIconName icon() => tester
        .widget<KitIcon>(
          find.descendant(of: save, matching: find.byType(KitIcon)),
        )
        .name;
    await draw(tester, [const Offset(100, 200), const Offset(160, 200)]);
    await tester.pump();
    expect(icon(), KitIconName.saved);
    expect(find.byTooltip('저장'), findsOneWidget);
    await tester.tap(save);
    await tester.pump();
    await tester.pump();
    expect(icon(), KitIconName.clock);
    expect(find.byTooltip('저장 중'), findsOneWidget);
    write.complete();
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(icon(), KitIconName.checkCircle);
    expect(find.byTooltip('저장'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('with the editor\'s setting untouched a finger writes', (
    tester,
  ) async {
    stows.editorFingerDrawing.value = stows.editorFingerDrawing.defaultValue;
    final key = await mount(tester);
    final finger = await tester.createGesture(
      kind: PointerDeviceKind.touch,
      pointer: 6,
    );
    final page = tester.getTopLeft(surface);
    await finger.down(page + const Offset(100, 300));
    await finger.moveTo(page + const Offset(160, 320));
    await finger.up();
    await tester.pump();
    expect(key.currentState!.document.strokes, hasLength(1));
    await tester.pumpWidget(const SizedBox());
  });

  // the editor shows 노트 창 where its vault keeps the quick note (format 2)
  for (final (width, format2) in [
    (800.0, false),
    (360.0, false),
    (800.0, true),
    (360.0, true),
  ]) {
    testWidgets('the tools sit where the editor\'s do at $width'
        '${format2 ? ' in a format 2 vault' : ''}', (tester) async {
      List<double> xs() => [
        for (final id in ['lasso', 'pen', 'eraser'])
          tester.getCenter(byKey('editor-tool-$id')).dx,
      ];
      await mount(
        tester,
        size: Size(width, 600),
        vaultKeepsAttachments: format2,
      );
      final infinite = xs();
      await tester.pumpWidget(const SizedBox());
      // the editor's bar with its default tools
      stows.editorToolbarTools.value = const [];
      stows.pageToolbarLayout.value = const [];
      final actions = AppActionRegistry();
      addTearDown(actions.dispose);
      AppAction a(String id, KitIconName icon, {bool? on}) =>
          AppAction(id: id, label: id, icon: icon, checked: on, run: (_) {});
      actions.publish(Object(), [
        a(AppActionIds.pageList, KitIconName.sidebar),
        for (final id in AppActionIds.tools)
          a(id, KitIconName.pen, on: id == AppActionIds.toolPen),
        a(AppActionIds.pickPhoto, KitIconName.image),
        a(AppActionIds.insertPageMenu, KitIconName.pageAdd),
        a(AppActionIds.fullscreen, KitIconName.expand, on: false),
      ]);
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(size: Size(width, 600)),
          child: MaterialApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.topCenter,
                child: KitEditorToolbar(
                  actions: actions,
                  title: '',
                  floatingBarOpen: ValueNotifier(true),
                  noteSheetOpen: format2 ? ValueNotifier(false) : null,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(infinite, xs());
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('zoom lock keeps the scale under two fingers and the wheel', (
    tester,
  ) async {
    final key = await mount(tester);
    final page = tester.getTopLeft(surface);
    Future<void> spread() async {
      final a = await tester.createGesture(
        kind: PointerDeviceKind.touch,
        pointer: 11,
      );
      final b = await tester.createGesture(
        kind: PointerDeviceKind.touch,
        pointer: 12,
      );
      await a.down(page + const Offset(300, 300));
      await b.down(page + const Offset(400, 300));
      await a.moveTo(page + const Offset(250, 300));
      await b.moveTo(page + const Offset(450, 300));
      await a.up();
      await b.up();
      await tester.pump();
    }

    stows.lastZoomLock.value = true;
    await tester.pump();
    await spread();
    expect(key.currentState!.viewport.scale, 1);
    final mouse = TestPointer(9, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(mouse.hover(page + const Offset(300, 300)));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, -60)));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(key.currentState!.viewport.scale, 1);
    stows.lastZoomLock.value = false;
    await tester.pump();
    await spread();
    expect(key.currentState!.viewport.scale, closeTo(2, 1e-9));
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpWidget(const SizedBox());
  });
}
