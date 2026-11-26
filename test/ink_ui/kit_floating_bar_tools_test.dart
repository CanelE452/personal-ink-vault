import 'dart:ui' show GestureSettings;

import 'package:flutter/gestures.dart'
    show PointerDeviceKind, kLongPressTimeout;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RendererBinding;
import 'package:flutter/services.dart'
    show LogicalKeyboardKey, SystemChannels, SystemMouseCursors;
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/kit/kit_motion.dart';
import 'package:saber/components/kit/kit_tokens.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/tools/_tool.dart';
import 'package:saber/data/tools/eraser.dart';
import 'package:saber/data/tools/highlighter.dart';
import 'package:saber/data/tools/laser_pointer.dart';
import 'package:saber/data/tools/pen.dart';
import 'package:saber/data/tools/shape_pen.dart';

import 'floating_bar_harness.dart';
import 'pen_panel_harness.dart' show colourString;

/// Records the haptic feedback asked of the platform.
List<Object?> _recordHaptics(WidgetTester tester) {
  final calls = <Object?>[];
  final messenger = tester.binding.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'HapticFeedback.vibrate') calls.add(call.arguments);
    return null;
  });
  addTearDown(
    () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
  );
  return calls;
}

/// The shadow [pill] casts now.
List<BoxShadow>? _shadowOf(WidgetTester tester, Finder pill) =>
    (tester
                .widget<DecoratedBox>(
                  inside(pill, find.byType(DecoratedBox)).first,
                )
                .decoration
            as BoxDecoration)
        .boxShadow;

/// The grabbing hand a mouse shows while the bar is held.
final _grabbing = find.byWidgetPredicate(
  (w) => w is MouseRegion && w.cursor == SystemMouseCursors.grabbing,
);

void main() {
  FlavorConfig.setup();
  tearDown(resetBarState);

  testWidgets('undo and redo stay with the eraser', (tester) async {
    final host = await pumpBar(tester, Eraser());
    expect(tester.getRect(undoPill), const Rect.fromLTWH(10, 10, 80, 40));
    await tester.tap(barKey('floating-bar-undo'));
    await tester.pump();
    expect(host.undoRuns, 1);
    expect(opacityOf(tester, 'floating-bar-redo'), KitTokens.disabledOpacity);
  });

  testWidgets('the bar has the value sheet sizes and places', (tester) async {
    for (final (tool, place, sheet) in <(Tool, String, String)>[
      (Pen.ballpointPen(), 'top', 'pen-h'),
      (Pen.ballpointPen(), 'left', 'pen-v'),
    ]) {
      stows.floatingBarPosition.value = place;
      await pumpBar(tester, tool);
      expectSheet(tester, sheet);
    }
  });

  testWidgets('taps beside the pills reach the canvas', (tester) async {
    final host = await pumpBar(tester, Pen.fountainPen());
    await tester.tapAt(const Offset(600, 300));
    // the 6 between the two pills belongs to the canvas too
    await tester.tapAt(Offset(tester.getRect(undoPill).right + 3, 30));
    await tester.pump();
    expect(host.canvasTaps, 2);
    // the pills keep taps on their own background; a dot is pressed only in
    // its own 22, not in the 3 beside it (ruling 2)
    await tester.tapAt(tester.getTopLeft(undoPill) + const Offset(3, 20));
    final dot = tester.getRect(dotCircle(1));
    await tester.tapAt(Offset(dot.left - 1.5, dot.center.dy));
    await tester.pump();
    expect(host.canvasTaps, 2);
    expect(host.colors, isEmpty);
    await tester.tapAt(dot.center);
    await tester.pump();
    expect(host.colors, hasLength(1));
  });

  testWidgets('it grows in from .92 in 200 ms when it appears', (tester) async {
    // values §14-4: from .92 and clear to whole, 200 ms both ways
    final host = await pumpBar(tester, ShapePen());
    expect(floatingBar, findsNothing);
    final half = KitMotion.floatingBarGrow ~/ 2;
    host.pick(Pen.fountainPen());
    await tester.pump();
    expect(barScale(tester), 0.92);
    await tester.pump(half);
    expect(barScale(tester), inExclusiveRange(0.92, 1));
    await tester.pump(half + const Duration(milliseconds: 1));
    expect(barScale(tester), 1);
    // another ink tool or the eraser: it stays as it is
    for (final tool in <Tool>[Highlighter.currentHighlighter, Eraser()]) {
      host.pick(tool);
      await tester.pump();
      expect(barScale(tester), 1, reason: '${tool.toolId}');
    }
    // with the laser pointer it goes in the same 200 ms (the preview's one
    // transition), still showing the eraser's pill and taking no tap
    final halfClose = KitMotion.floatingBarGrow ~/ 2;
    host.pick(LaserPointer.currentLaserPointer);
    await tester.pump();
    expect(barScale(tester), 1);
    await tester.pump(halfClose);
    // closing is quick first and slow at the end, as the preview's CSS
    // (`.c9fb` transition, the same curve both ways)
    expect(barScale(tester), inExclusiveRange(0.92, 0.93));
    expect(barKey('floating-bar-eraser-kind'), findsOneWidget);
    final size = stows.eraserSize.value;
    await tester.tap(
      barKey('floating-bar-eraser-size-80'),
      warnIfMissed: false,
    );
    expect(stows.eraserSize.value, size);
    await tester.pump(halfClose + const Duration(milliseconds: 1));
    expect(floatingBar, findsNothing);
    // and it grows again after
    host.pick(Pen.fountainPen());
    await tester.pump();
    expect(barScale(tester), 0.92);
    await tester.pumpAndSettle();
    expect(barScale(tester), 1);
  });

  testWidgets('it is there at once when first drawn and with less motion', (
    tester,
  ) async {
    // the editor opened with a pen in hand: no growing (ruling 3)
    await pumpBar(tester, Pen.fountainPen(), settle: false);
    expect(barScale(tester), 1);
    expect(tester.getRect(floatingBar), const Rect.fromLTWH(10, 10, 440, 40));
    // 「움직임 줄이기」: shown again and gone at once too
    final host = await pumpBar(tester, ShapePen(), reduceMotion: true);
    host.pick(Eraser());
    await tester.pump();
    expect(barScale(tester), 1);
    host.pick(LaserPointer.currentLaserPointer);
    await tester.pump();
    expect(floatingBar, findsNothing);
  });

  testWidgets('colour dots take focus with a ring and pick with Enter', (
    tester,
  ) async {
    // the keyboard's focus ring (`:focus-visible`, v8h line 111): 2 wide in
    // #2f6ae0, 2 out from a dot, 6 out from the chosen one's two rings
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
    addTearDown(
      () => FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.automatic,
    );
    const defaults = KitTokens.floatingBarDefaultColors;
    // all four among the recent colours, so a pick does not move them
    final recent = [for (final c in defaults) colourString(c)];
    stows.recentColorsPositioned.value = recent;
    stows.recentColorsChronological.value = [...recent];
    final host = await pumpBar(tester, Pen.fountainPen()..color = defaults[0]);
    List<BoxShadow>? rings(int i) =>
        (tester.widget<Container>(dotCircle(i)).decoration! as BoxDecoration)
            .boxShadow;
    Future<void> focus(int i) async {
      Focus.of(
        tester.element(
          inside(
            barKey('floating-bar-colour-$i'),
            find.byType(GestureDetector),
          ),
        ),
      ).requestFocus();
      // the focus moves in a microtask; the dot draws its ring a frame after
      await tester.pumpAndSettle();
    }

    const chosenRings = [
      BoxShadow(color: Color(0xffdcdce1), spreadRadius: 6),
      BoxShadow(color: Color(0xfff2f2f4), spreadRadius: 3),
    ];
    const blue = Color(0xff2f6ae0);
    expect(rings(0), chosenRings);
    expect(rings(1), isNull);
    await focus(1);
    expect(rings(1), const [
      BoxShadow(color: blue, spreadRadius: 4),
      BoxShadow(color: Color(0xfff2f2f4), spreadRadius: 2),
    ]);
    expect(rings(0), chosenRings);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(host.colors, [defaults[1]]);
    // now chosen and still focused: the ring just past the two rings
    expect(rings(1), const [
      BoxShadow(color: blue, spreadRadius: 8),
      ...chosenRings,
    ]);
    expect(rings(0), isNull);
    await focus(0);
    expect(rings(1), chosenRings);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(host.colors, [defaults[1], defaults[0]]);
  });

  testWidgets('held half a second it is picked up: a light tap of the hand '
      'and a deeper shadow, the bar no bigger', (tester) async {
    // task-12-values.md §13: picked up at 500 ms anywhere, buttons too
    final haptics = _recordHaptics(tester);
    final host = await pumpBar(tester, Pen.fountainPen());
    final size = tester.getSize(floatingBar);
    final g = await tester.startGesture(
      tester.getCenter(barKey('floating-bar-redo')),
    );
    await tester.pump(const Duration(milliseconds: 450));
    expect(haptics, isEmpty);
    expect(_shadowOf(tester, toolPill), KitTokens.pillShadow);
    expect(_grabbing, findsNothing);
    await tester.pump(const Duration(milliseconds: 60));
    expect(haptics, ['HapticFeedbackType.lightImpact']);
    // the shadow eases a step up in the fast step (.12 s), on both pills
    final step = KitMotion.open(KitMotionStep.fast);
    await tester.pump(step + const Duration(milliseconds: 1));
    for (final pill in [undoPill, toolPill]) {
      expect(_shadowOf(tester, pill), KitTokens.pillShadowRaised);
    }
    expect(tester.getSize(floatingBar), size);
    expect(_grabbing, findsOneWidget);
    // dragged and let go across the top: the shadow comes back
    await g.moveBy(const Offset(190, 0));
    await tester.pump();
    await g.up();
    // the frame that lets it down starts the step
    await tester.pump();
    await tester.pump(step + const Duration(milliseconds: 1));
    for (final pill in [undoPill, toolPill]) {
      expect(_shadowOf(tester, pill), KitTokens.pillShadow);
    }
    expect(_grabbing, findsNothing);
    expect(haptics, hasLength(1));
    expect(stows.floatingBarPosition.value, 'top');
    expect(host.redoRuns, 0);
  });

  testWidgets('the eraser pill goes up too', (tester) async {
    for (final tool in [Eraser()]) {
      await pumpBar(tester, tool);
      final g = await tester.startGesture(
        tester.getCenter(barKey('floating-bar-redo')),
      );
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 20));
      await tester.pump(
        KitMotion.open(KitMotionStep.fast) + const Duration(milliseconds: 1),
      );
      expect(
        _shadowOf(tester, toolPill),
        KitTokens.pillShadowRaised,
        reason: '$tool',
      );
      await g.moveBy(const Offset(190, 0));
      await g.up();
      await tester.pumpAndSettle();
      expect(_shadowOf(tester, toolPill), KitTokens.pillShadow);
    }
  });

  testWidgets('a mouse holding the bar shows the grabbing hand, over its '
      'buttons too', (tester) async {
    await pumpBar(tester, Pen.fountainPen());
    final pencil = tester.getCenter(barKey('floating-bar-pen-pencil'));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: pencil);
    await tester.pump();
    // a mouse's device is 1 in tests
    MouseCursor? cursor() =>
        RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1);
    // the button's own arrow (Flutter's buttons show it off the web), which
    // would win over the bar's hand while the button is under the mouse
    expect(cursor(), SystemMouseCursors.basic);
    await mouse.down(pencil);
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 20));
    expect(cursor(), SystemMouseCursors.grabbing);
    await mouse.moveBy(const Offset(30, 0));
    await tester.pump();
    expect(cursor(), SystemMouseCursors.grabbing);
    await mouse.up();
    await tester.pumpAndSettle();
    expect(cursor(), isNot(SystemMouseCursors.grabbing));
  });

  testWidgets('a desktop has no motor: the hold asks for no haptic', (
    tester,
  ) async {
    // its engine answers no haptic call (flutter_windows.dll has none), so
    // asking would only raise an error each time the bar is picked up
    final haptics = _recordHaptics(tester);
    await pumpBar(tester, Pen.fountainPen());
    await dragBar(tester, const Offset(190, 0));
    expect(haptics, isEmpty);
    expect(stows.floatingBarPosition.value, 'top');
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('a move of more than 10 before then does not pick it up', (
    tester,
  ) async {
    // across plus down, as the preview counts it: 6 and 6 is 12, though
    // only 8.5 straight (Flutter's own long press lets 18 straight pass)
    final haptics = _recordHaptics(tester);
    await pumpBar(tester, Pen.fountainPen());
    final start = tester.getTopLeft(floatingBar);
    final g = await tester.startGesture(
      tester.getCenter(barKey('floating-bar-redo')),
    );
    await tester.pump(const Duration(milliseconds: 200));
    await g.moveBy(const Offset(6, 6));
    await tester.pump(const Duration(milliseconds: 400));
    expect(haptics, isEmpty);
    expect(_shadowOf(tester, toolPill), KitTokens.pillShadow);
    await g.moveBy(const Offset(100, 100));
    await tester.pump();
    expect(tester.getTopLeft(floatingBar), start);
    await g.up();
    await tester.pumpAndSettle();
    expect(stows.floatingBarPosition.value, 'top');
    // 5 and 5 is 10, not more: picked up
    final h = await tester.startGesture(
      tester.getCenter(barKey('floating-bar-redo')),
    );
    await tester.pump(const Duration(milliseconds: 200));
    await h.moveBy(const Offset(5, 5));
    await tester.pump(const Duration(milliseconds: 400));
    expect(haptics, hasLength(1));
    await h.moveBy(const Offset(190, 0));
    await h.up();
    await tester.pumpAndSettle();
    // the next hold counts afresh: 6 and 6 lets it go again
    final i = await tester.startGesture(
      tester.getCenter(barKey('floating-bar-redo')),
    );
    await tester.pump(const Duration(milliseconds: 200));
    await i.moveBy(const Offset(6, 6));
    await tester.pump(const Duration(milliseconds: 400));
    expect(haptics, hasLength(1));
    await i.up();
    await tester.pumpAndSettle();
  });

  testWidgets('a tablet touch slop of 8 does not let it go sooner: 9 across '
      'is not more than 10', (tester) async {
    // Android tells Flutter its own slop (8 dp by default), which a long
    // press counts straight once it is handed on
    tester.view.gestureSettings = const GestureSettings(physicalTouchSlop: 8);
    addTearDown(tester.view.resetGestureSettings);
    final haptics = _recordHaptics(tester);
    await pumpBar(tester, Pen.fountainPen());
    final g = await tester.startGesture(
      tester.getCenter(barKey('floating-bar-redo')),
    );
    await tester.pump(const Duration(milliseconds: 200));
    await g.moveBy(const Offset(9, 0));
    await tester.pump(const Duration(milliseconds: 400));
    expect(haptics, hasLength(1));
    await g.moveBy(const Offset(190, 0));
    await g.up();
    await tester.pumpAndSettle();
  });

  testWidgets('let go, taps on the bar are swallowed for 80 ms', (
    tester,
  ) async {
    final host = await pumpBar(tester, Pen.fountainPen());
    // held on the pencil: the hold takes the touch, so no pen is picked
    final g = await tester.startGesture(
      tester.getCenter(barKey('floating-bar-pen-pencil')),
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 20));
    await g.moveBy(const Offset(190, 0));
    await tester.pump();
    await g.up();
    await tester.pump();
    expect(host.tools, isEmpty);
    // a tap right after is swallowed (preview: the click the release makes)
    await tester.tap(barKey('floating-bar-pen-pencil'), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 40));
    expect(host.tools, isEmpty);
    expect(host.canvasTaps, 0);
    // from 80 ms on the bar takes taps again
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(barKey('floating-bar-pen-pencil'));
    await tester.pump();
    expect(host.tools, hasLength(1));
  });
}
