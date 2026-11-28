import 'package:flex_color_picker/flex_color_picker.dart' show ColorPicker;
import 'package:flutter/gestures.dart' show kLongPressTimeout;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/ink_ui/pen_panel/kit_pen_color_row.dart';
import 'package:saber/components/ink_ui/pen_panel/kit_pen_panel.dart';
import 'package:saber/components/ink_ui/pen_panel/pen_panel_common.dart';
import 'package:saber/components/ink_ui/pen_panel/size_level.dart';
import 'package:saber/components/kit/kit_controls.dart';
import 'package:saber/components/kit/kit_icon.dart';
import 'package:saber/components/kit/kit_pen_art.dart';
import 'package:saber/components/kit/kit_pill.dart';
import 'package:saber/components/kit/kit_swatches.dart';
import 'package:saber/components/kit/kit_tokens.dart';
import 'package:saber/data/actions/app_action.dart';
import 'package:saber/data/actions/app_action_ids.dart';
import 'package:saber/data/extensions/color_extensions.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/ink/pen_kind.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/tools/_tool.dart';
import 'package:saber/data/tools/eraser.dart';
import 'package:saber/data/tools/highlighter.dart';
import 'package:saber/data/tools/laser_pointer.dart';
import 'package:saber/data/tools/pen.dart';
import 'package:saber/data/tools/pencil.dart';
import 'package:saber/data/tools/select.dart';
import 'package:saber/data/tools/shape_pen.dart';

import 'floating_bar_harness.dart';
import 'pen_panel_harness.dart'
    show CountingPen, colourString, inSizeRow, sliderNumber, swatch;

/// The palette (「색 만들기」) of the pen panel's colour row: its colour wheel
/// (the bar's 「색 만들기」 is one too).
final _palette = find.descendant(
  of: find.byType(KitPenPanel),
  matching: find.byWidgetPredicate(
    (w) =>
        w is DecoratedBox &&
        w.decoration is BoxDecoration &&
        (w.decoration as BoxDecoration).gradient is SweepGradient,
  ),
);

void main() {
  FlavorConfig.setup();
  tearDown(resetBarState);

  testWidgets('tapping the chosen pen again opens the panel', (tester) async {
    Pen.currentPen = Pen.fountainPen();
    final host = await pumpBar(tester, Pen.currentPen);
    expect(isOn(tester, 'floating-bar-pen-fountain'), isTrue);
    await tester.tap(barKey('floating-bar-pen-fountain'));
    await tester.pumpAndSettle();
    final panel = tester.widget<KitPenPanel>(find.byType(KitPenPanel));
    expect(panel.kind, KitPenPanelKind.pens);
    expect(panel.host, same(host));
    expect(panel.collapsed, same(host.collapsed));
    expect(panel.actions, same(host.actions));
    expect(host.tools, isEmpty);
    // it opens at the button, under the bar
    final window = find.byKey(const ValueKey('kit-pen-panel'));
    expect(
      tester.getTopLeft(window),
      windowAt(tester, 'floating-bar-pen-fountain'),
    );
    await tester.tap(find.byKey(const ValueKey('pen-panel-close')));
    await tester.pumpAndSettle();
    expect(find.byType(KitPenPanel), findsNothing);
    // the highlighter opens the highlighter panel; upright, beside the bar
    host.pick(Highlighter.currentHighlighter);
    stows.floatingBarPosition.value = 'left';
    await tester.pumpAndSettle();
    await tester.tap(barKey('floating-bar-pen-hlchisel'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<KitPenPanel>(find.byType(KitPenPanel)).kind,
      KitPenPanelKind.highlighters,
    );
    expect(
      tester.getTopLeft(window),
      windowAt(tester, 'floating-bar-pen-hlchisel', upright: true),
    );
    expect(host.tools, isEmpty);
  });

  testWidgets('tapping another pen switches the tool without a panel', (
    tester,
  ) async {
    Pen.currentPen = Pen.fountainPen();
    final host = await pumpBar(tester, Pen.currentPen);
    for (final (key, kind) in const [
      ('floating-bar-pen-pen', KitPenKind.finePen),
      ('floating-bar-pen-brush', KitPenKind.brush),
      ('floating-bar-pen-pencil', KitPenKind.pencil),
      ('floating-bar-pen-hlchisel', KitPenKind.highlighterChisel),
      ('floating-bar-pen-fountain', KitPenKind.fountain),
    ]) {
      final before = host.tools.length;
      await tester.tap(barKey(key));
      await tester.pumpAndSettle();
      expect(host.tools, hasLength(before + 1), reason: key);
      expect(penKindOf(host.tools.last), kind);
      expect(find.byType(KitPenPanel), findsNothing, reason: key);
      // the bar follows the tool the host hands back
      expect(isOn(tester, key), isTrue, reason: key);
      expect(tooltipOf(tester, key), kind.label);
    }
    expect(isOn(tester, 'floating-bar-pen-pen'), isFalse);
    expect(host.colors, isEmpty);
  });

  testWidgets('the bar offers the brush and one highlighter button', (
    tester,
  ) async {
    Pen.currentPen = Pen.fountainPen();
    final host = await pumpBar(tester, Pen.currentPen);
    // the preview's `#toolPill`: fountain, ball, brush, pencil, marker
    const order = ['fountain', 'pen', 'brush', 'pencil', 'hlchisel'];
    final xs = [
      for (final id in order)
        tester.getTopLeft(barKey('floating-bar-pen-$id')).dx,
    ];
    for (var i = 1; i < xs.length; i++) {
      expect(xs[i - 1], lessThan(xs[i]), reason: order[i]);
    }
    expect(barKey('floating-bar-pen-calli'), findsNothing);
    expect(barKey('floating-bar-pen-hlround'), findsNothing);
    expect(tooltipOf(tester, 'floating-bar-pen-brush'), KitPenKind.brush.label);
    // with the round highlighter in hand the highlighter button is on, and
    // pressed again it opens the highlighter panel on that pen
    host.pick(host.toolState.penFor(KitPenKind.highlighterRound));
    await tester.pumpAndSettle();
    expect(isOn(tester, 'floating-bar-pen-hlchisel'), isTrue);
    await tester.tap(barKey('floating-bar-pen-hlchisel'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<KitPenPanel>(find.byType(KitPenPanel)).kind,
      KitPenPanelKind.highlighters,
    );
    expect(host.tools, isEmpty);
  });

  testWidgets('undo and redo come from the action registry', (tester) async {
    final host = await pumpBar(tester, Pen.fountainPen());
    final builds = host.builds;
    final undo = tester.widget<KitPillButton>(barKey('floating-bar-undo'));
    expect((undo.icon, undo.tooltip), (KitIconName.undo, '실행 취소'));
    expect(
      tester.widget<KitPillButton>(barKey('floating-bar-redo')).onPressed,
      isNull,
    );
    expect(opacityOf(tester, 'floating-bar-redo'), KitTokens.disabledOpacity);
    await tester.tap(barKey('floating-bar-undo'));
    await tester.tap(barKey('floating-bar-redo'));
    await tester.pump();
    expect((host.undoRuns, host.redoRuns), (1, 0));
    // the bar follows the registry by itself
    host.actions.publish(host, [host.undo(), host.redo()]);
    await tester.pumpAndSettle();
    await tester.tap(barKey('floating-bar-redo'));
    await tester.pump();
    expect(host.redoRuns, 1);
    // without undo its button goes; without both the pill goes
    host.actions.publish(host, [host.redo()]);
    await tester.pumpAndSettle();
    expect(barKey('floating-bar-undo'), findsNothing);
    expect(barKey('floating-bar-redo'), findsOneWidget);
    host.actions.withdraw(host);
    await tester.pumpAndSettle();
    expect(undoPill, findsNothing);
    expect(tester.getTopLeft(toolPill), const Offset(10, 10));
    expect(host.builds, builds);
  });

  testWidgets('width shows the pen presets and marks the nearest', (
    tester,
  ) async {
    final pen = CountingPen(Pen.ballpointPen());
    pen.options = pen.options.copyWith(size: 8.03);
    final host = await pumpBar(tester, pen);
    KitSegment<double?> widths() => tester.widget(widthsPopover);
    Future<void> open() async {
      await tester.tap(barKey('toolbar-quick-ink-widths'));
      await tester.pumpAndSettle();
    }

    String number(double p) => '${sizeToLevel(p, min: 1, max: 25)}';
    // named with the pen panel's number for its width, as 「크기 N」 (design
    // review 8-7): 8.03 is 30
    const widthButton = 'toolbar-quick-ink-widths';
    expect(tooltipOf(tester, widthButton), '굵기 30');
    await open();
    expect([for (final o in widths().options) o.$1], [3, 8, 15]);
    // each shows the number the pen panel gives that width
    expect(
      [for (final o in widths().options) o.$2],
      [
        for (final p in const [3.0, 8.0, 15.0]) number(p),
      ],
    );
    expect(widths().value, 8);
    await tester.tap(find.text(number(15)));
    await tester.pumpAndSettle();
    expect(pen.sizes, [15]);
    expect(widthsPopover, findsNothing);
    expect(tooltipOf(tester, widthButton), '굵기 ${number(15)}');
    await open();
    expect(widths().value, 15);
    await tester.tapAt(outside);
    await tester.pumpAndSettle();
    // none is near: none is chosen
    pen.options = pen.options.copyWith(size: 11.5);
    await open();
    expect(widths().value, isNull);
    await tester.tapAt(outside);
    await tester.pumpAndSettle();
    // the highlighter's own three
    host.pick(Highlighter.currentHighlighter);
    await tester.pumpAndSettle();
    await open();
    expect([for (final o in widths().options) o.$1], [25, 35, 50]);
    expect(pen.sizes, [15]);
    expect(host.tools, isEmpty);
    expect(host.colors, isEmpty);
  });

  testWidgets('the width icon follows the width in hand', (tester) async {
    // task-12-values.md §13: the middle line 1.4 + min(4, floor((size - 1)
    // / 20)) x 0.7 by the pen panel's size number
    String middle() => RegExp(r'stroke-width="([^"]*)"')
        .allMatches(
          tester
              .widget<KitIcon>(
                find.descendant(
                  of: barKey('toolbar-quick-ink-widths'),
                  matching: find.byType(KitIcon),
                ),
              )
              .drawing!,
        )
        .map((m) => m[1]!)
        .toList()[1];
    T at<T extends Pen>(T pen, int level) =>
        pen
          ..options = pen.options.copyWith(
            size: levelToSize(level, min: pen.sizeMin, max: pen.sizeMax),
          );
    final pen = at(CountingPen(Pen.ballpointPen()), 7);
    Pen.currentPen = pen;
    final host = await pumpBar(tester, pen);
    expect(middle(), '1.4');
    for (final (level, line) in const [(37, '2.1'), (52, '2.8'), (97, '4.2')]) {
      host.pick(at(pen, level));
      await tester.pump();
      expect(middle(), line, reason: '$level');
    }
    // another pen brings its own width
    host.pick(at(Pencil.currentPencil, 70));
    await tester.pump();
    expect(middle(), '3.5');
    // the pen panel's slider: followed at once, before it is let go
    host.pick(at(pen, 37));
    await tester.pumpAndSettle();
    expect(middle(), '2.1');
    await tester.tap(barKey('floating-bar-pen-pen'));
    await tester.pumpAndSettle();
    final g = await tester.startGesture(
      tester.getCenter(inSizeRow(find.byKey(const Key('kit-slider-thumb')))),
    );
    await tester.pump();
    for (var i = 0; i < 3; i++) {
      await g.moveBy(const Offset(10, 0));
      await tester.pump();
    }
    final shown = int.parse(sliderNumber(tester));
    expect(shown, greaterThan(40));
    expect(pen.sizes, isEmpty);
    expect(
      middle(),
      KitTokens.widthIconLines[(shown - 1) ~/ 20].toStringAsFixed(1),
    );
    await g.up();
    await tester.pumpAndSettle();
    await tester.tapAt(outside);
    await tester.pumpAndSettle();
    expect(
      middle(),
      KitTokens.widthIconLines[(shown - 1) ~/ 20].toStringAsFixed(1),
    );
    // closed, the pen's own width again
    host.pick(at(pen, 97));
    await tester.pump();
    expect(middle(), '4.2');
  });

  testWidgets('colour dots keep their slots', (tester) async {
    const a = Color(0xff123456), b = Color(0xff3d8b6e), c = Color(0xffd94f30);
    const d = Color(0xffe7a92b), e = Color(0xff24304a);
    final recent = [
      for (final x in const [a, b, c, d, e]) colourString(x),
    ];
    stows.recentColorsPositioned.value = recent;
    stows.recentColorsChronological.value = [...recent];
    final host = await pumpBar(tester, Pen.fountainPen()..color = b);
    expect(dotColours(tester), [a, b, c, d]);
    expect(chosenDots(tester), [false, true, false, false]);
    await tester.tap(barKey('floating-bar-colour-2'));
    await tester.pumpAndSettle();
    expect(host.colors, [c]);
    expect(dotColours(tester), [a, b, c, d]);
    expect(chosenDots(tester), [false, false, true, false]);
    // the bar follows the list by itself
    final builds = host.builds;
    const defaults = KitTokens.floatingBarDefaultColors;
    stows.recentColorsPositioned.value = [];
    await tester.pump();
    expect(dotColours(tester), defaults);
    stows.recentColorsPositioned.value = [
      colourString(defaults[1]),
      'not a colour',
      colourString(a),
    ];
    await tester.pump();
    expect(dotColours(tester), [defaults[1], a, defaults[0], defaults[2]]);
    expect(host.builds, builds);
  });

  testWidgets('custom colour opens the colour row', (tester) async {
    const red = Color(0xffe5323e), blue = Color(0xff2f9bf0);
    final host = await pumpBar(tester, Pen.fountainPen()..color = red);
    expect(
      tooltipOf(tester, 'floating-bar-custom-colour'),
      KitIconName.custom.label,
    );
    // 「색 만들기」 is the pen panel's colour wheel, 22 in the middle of its
    // 32 button with a thin line inside and no ring; the custom icon is gone
    // from the bar (task-12-values.md §13)
    final wheelButton = barKey('floating-bar-custom-colour');
    expect(
      find.descendant(
        of: floatingBar,
        matching: find.byWidgetPredicate(
          (w) => w is KitIcon && w.name == KitIconName.custom,
        ),
      ),
      findsNothing,
    );
    final wheel = find.descendant(
      of: wheelButton,
      matching: find.byWidgetPredicate(
        (w) =>
            w is DecoratedBox &&
            w.decoration is BoxDecoration &&
            (w.decoration as BoxDecoration).gradient != null,
      ),
    );
    final look = tester.widget<DecoratedBox>(wheel).decoration as BoxDecoration;
    expect(look.gradient, same(kitColourWheel));
    expect(look.border, Border.all(color: const Color(0x1f000000)));
    expect(look.boxShadow, isNull);
    expect(
      tester.getRect(wheel),
      Rect.fromCenter(
        center: tester.getCenter(wheelButton),
        width: 22,
        height: 22,
      ),
    );
    await tester.tap(barKey('floating-bar-custom-colour'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<KitPenColorRow>(find.byType(KitPenColorRow)).selected,
      red,
    );
    expect(
      tester.getTopLeft(
        find.ancestor(
          of: find.byType(KitPenColorRow),
          matching: find.byType(PenPanelSurface),
        ),
      ),
      windowAt(tester, 'floating-bar-custom-colour'),
    );
    // without an eyedropper in the document's actions there is none
    final eyedropper = find.byWidgetPredicate(
      (w) => w is KitIcon && w.name == KitIconName.eyedrop,
    );
    expect(eyedropper, findsNothing);
    await tester.tap(swatch(blue));
    await tester.pumpAndSettle();
    expect(host.colors, [blue]);
    expect(find.byType(KitPenColorRow), findsNothing);
    // with one, it shows as in the pen panel (design review 8-2); it closes
    // the window and runs on the frame after
    var drops = 0;
    host.actions.publish(host, [
      host.undo(),
      host.redo(enabled: false),
      AppAction(
        id: AppActionIds.eyedropper,
        label: '스포이트',
        icon: KitIconName.eyedrop,
        run: (_) => drops++,
      ),
    ]);
    await tester.pumpAndSettle();
    await tester.tap(barKey('floating-bar-custom-colour'));
    await tester.pumpAndSettle();
    expect(eyedropper, findsOneWidget);
    await tester.tap(eyedropper);
    await tester.pumpAndSettle();
    expect(find.byType(KitPenColorRow), findsNothing);
    expect(drops, 1);
    expect(host.colors, [blue]);
    expect(host.tools, isEmpty);
  });

  testWidgets('dropping near the left edge makes it vertical and remembers', (
    tester,
  ) async {
    final host = await pumpBar(tester, Pen.fountainPen());
    expect(stows.floatingBarPosition.value, 'top');
    expect(tester.widget<KitPill>(toolPill).direction, Axis.horizontal);
    // let go with its left edge at 40
    await dragBar(tester, const Offset(30, 140));
    expect(stows.floatingBarPosition.value, 'left');
    expect(tester.widget<KitPill>(toolPill).direction, Axis.vertical);
    // the four pens' bar (416 x 40) and one pen more, the brush
    Offset slot() =>
        tester.getTopLeft(barKey('floating-bar-pen-pencil')) -
        tester.getTopLeft(barKey('floating-bar-pen-brush'));
    expect(slot().dy, greaterThan(KitTokens.pillButton));
    expect(
      tester.getRect(floatingBar),
      Rect.fromLTWH(10, 10, 40, 416 + slot().dy),
    );
    // at 200 it goes back across the top
    await dragBar(tester, const Offset(190, 0));
    expect(stows.floatingBarPosition.value, 'top');
    final across = Rect.fromLTWH(10, 10, 440 + slot().dx, 40);
    expect(slot().dx, greaterThan(KitTokens.pillButton));
    expect(tester.getRect(floatingBar), across);
    // a value it does not know is the top
    stows.floatingBarPosition.value = 'right';
    await tester.pumpAndSettle();
    expect(tester.widget<KitPill>(toolPill).direction, Axis.horizontal);
    expect(tester.getRect(floatingBar), across);
    // holding the undo button did not press it
    expect(host.undoRuns, 0);
  });

  testWidgets('dragging moves only the bar', (tester) async {
    final host = await pumpBar(tester, Pen.fountainPen());
    var writes = 0;
    void count() => writes++;
    stows.floatingBarPosition.addListener(count);
    addTearDown(() => stows.floatingBarPosition.removeListener(count));
    final builds = host.builds, paints = host.paints;
    final g = await tester.startGesture(
      tester.getCenter(barKey('floating-bar-pen-pencil')),
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    for (var i = 0; i < 3; i++) {
      await g.moveBy(const Offset(10, 20));
      await tester.pump();
    }
    expect(tester.getTopLeft(floatingBar), const Offset(40, 70));
    expect((host.builds, host.paints, writes), (builds, paints, 0));
    await g.up();
    await tester.pumpAndSettle();
    expect(writes, 1);
    expect(stows.floatingBarPosition.value, 'left');
    expect((host.builds, host.paints), (builds, paints));
    // the long press picked no pen
    expect(host.tools, isEmpty);
  });

  testWidgets('a pen panel kept on a short page fades while more is below', (
    tester,
  ) async {
    // the panel's own rows scroll too (kit_pen_panel.dart): its view's
    // notices must not turn the window's fade off
    await pumpBar(tester, Pen.fountainPen(), screen: const Size(360, 480));
    await tester.tap(barKey('floating-bar-pen-fountain'));
    await tester.pumpAndSettle();
    final outer = find
        .ancestor(
          of: find.byKey(const ValueKey('kit-pen-panel')),
          matching: find.byType(Scrollable),
        )
        .first;
    final view = tester.state<ScrollableState>(outer).position;
    expect(view.extentAfter, greaterThan(0), reason: 'the window slides');
    final fade = find.byKey(const ValueKey('kit-popover-fade'));
    expect(fade, findsOneWidget);
    // a view inside the panel tells it is at its end (the pen rows' own
    // scroll view): the window's fade stays
    ScrollMetricsNotification(
      metrics: FixedScrollMetrics(
        minScrollExtent: 0,
        maxScrollExtent: 40,
        pixels: 40,
        viewportDimension: 100,
        axisDirection: AxisDirection.down,
        devicePixelRatio: 1,
      ),
      context: tester.element(find.byKey(const ValueKey('kit-pen-panel'))),
    ).dispatch(tester.element(find.byKey(const ValueKey('kit-pen-panel'))));
    await tester.pump();
    expect(fade, findsOneWidget);
    // the window at its end: no fade
    view.jumpTo(view.maxScrollExtent);
    await tester.pump();
    expect(fade, findsNothing);
  });

  testWidgets('tap outside closes only the top popup', (tester) async {
    final host = await pumpBar(
      tester,
      Pen.fountainPen()..color = const Color(0xffe5323e),
    );
    await tester.tap(barKey('floating-bar-pen-fountain'));
    await tester.pumpAndSettle();
    await tester.tap(_palette);
    await tester.pumpAndSettle();
    expect(find.byType(ColorPicker), findsOneWidget);
    await tester.tapAt(outside);
    await tester.pumpAndSettle();
    expect(find.byType(ColorPicker), findsNothing);
    expect(find.byType(KitPenPanel), findsOneWidget);
    await tester.tapAt(outside);
    await tester.pumpAndSettle();
    expect(find.byType(KitPenPanel), findsNothing);
    expect(floatingBar, findsOneWidget);
    expect(host.canvasTaps, 0);
    // the bar is no popup: the next tap reaches the canvas, the bar stays
    await tester.tapAt(outside);
    await tester.pump();
    expect(host.canvasTaps, 1);
    expect(floatingBar, findsOneWidget);
    expect(host.colors, isEmpty);
  });

  testWidgets('quick popups do not repaint the canvas next to the bar', (
    tester,
  ) async {
    final host = await pumpBar(tester, Pen.fountainPen());
    final paints = host.paints, builds = host.builds;
    expect(paints, greaterThan(0));
    for (final (button, window) in [
      ('floating-bar-pen-fountain', find.byType(KitPenPanel)),
      ('toolbar-quick-ink-widths', widthsPopover),
      ('floating-bar-custom-colour', find.byType(KitPenColorRow)),
    ]) {
      await tester.tap(barKey(button));
      await tester.pumpAndSettle();
      expect(window, findsOneWidget, reason: button);
      await tester.tapAt(outside);
      await tester.pumpAndSettle();
      expect(window, findsNothing, reason: button);
    }
    expect((host.paints, host.builds), (paints, builds));
    expect(host.tools, isEmpty);
    expect(host.colors, isEmpty);
    expect(host.canvasTaps, 0);
  });

  testWidgets('hidden for the shape pen, the text box and the laser pointer', (
    tester,
  ) async {
    for (final tool in <Tool>[
      ShapePen(),
      Tool.textEditing,
      LaserPointer.currentLaserPointer,
      // the lasso's window hangs from its toolbar button (10th draft)
      Select.currentSelect,
    ]) {
      await pumpBar(tester, tool);
      expect(find.byType(KitPill), findsNothing, reason: '${tool.toolId}');
      expect(
        find.byType(KitPillButton),
        findsNothing,
        reason: '${tool.toolId}',
      );
    }
    for (final tool in <Tool>[
      Pen.fountainPen(),
      Pen.ballpointPen(),
      Pencil.currentPencil,
      Highlighter.currentHighlighter,
      Eraser(),
    ]) {
      await pumpBar(tester, tool);
      expect(toolPill, findsOneWidget, reason: '${tool.toolId}');
    }
  });

  testWidgets('dark ink dots show inverted', (tester) async {
    stows.editorAutoInvert.value = true;
    const colours = [
      Color(0xff1f2329),
      Color(0xffffffff),
      Color(0xff2f80ed),
      Color(0x80e5484d),
    ];
    stows.recentColorsPositioned.value = [
      for (final c in colours) colourString(c),
    ];
    final host = await pumpBar(
      tester,
      Pen.fountainPen(),
      brightness: Brightness.dark,
    );
    expect(dotColours(tester), [
      for (final c in colours) c.withValues(alpha: 1).withInversion(),
    ]);
    await tester.tap(barKey('floating-bar-colour-3'));
    await tester.pump();
    expect(host.colors, [colours[3]]);
  });
}
