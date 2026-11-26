import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/ink_ui/pen_panel/kit_pen_color_row.dart';
import 'package:saber/components/ink_ui/pen_panel/kit_pen_panel.dart';
import 'package:saber/components/ink_ui/pen_panel/pen_kinds.dart';
import 'package:saber/components/ink_ui/pen_panel/size_level.dart';
import 'package:saber/components/kit/kit_controls.dart';
import 'package:saber/components/kit/kit_icon.dart';
import 'package:saber/components/kit/kit_motion.dart';
import 'package:saber/components/kit/kit_pen_art.dart';
import 'package:saber/components/kit/kit_text.dart';
import 'package:saber/components/kit/kit_tokens.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/tools/highlighter.dart';
import 'package:saber/data/tools/pen.dart';
import 'package:saber/data/tools/pen_box.dart';
import 'package:sbn/tool_id.dart';

import 'pen_panel_harness.dart';

void main() {
  FlavorConfig.setup();
  tearDown(resetPenPanelState);

  testWidgets('pen panel shows only engine pens', (tester) async {
    final host = await pumpHost(tester, Pen.currentPen);
    await openPanel(tester, host);
    const shown = [KitPenKind.fountain, KitPenKind.finePen, KitPenKind.pencil];
    for (final k in shown) {
      expect(penColumn(k), findsOneWidget, reason: k.label);
    }
    for (final k in [
      KitPenKind.calligraphy,
      KitPenKind.brush,
      KitPenKind.highlighterChisel,
      KitPenKind.highlighterRound,
    ]) {
      expect(penColumn(k), findsNothing, reason: k.label);
    }
    // left to right in the preview's order
    final xs = [for (final k in shown) tester.getTopLeft(penColumn(k)).dx];
    expect(xs[0], lessThan(xs[1]));
    expect(xs[1], lessThan(xs[2]));
    // the size and stabiliser sliders, the straight-line switch, the colour
    // row: no line type, no horizontal/vertical row
    expect(find.byType(KitSlider), findsNWidgets(2));
    expect(find.byType(KitToggleRow), findsOneWidget);
    expect(find.byType(KitPenColorRow), findsOneWidget);
    expect(find.byKey(const ValueKey('tool-panel-stabiliser')), findsOneWidget);
  });

  testWidgets('highlighter panel has one pen and no opacity, line or T rows', (
    tester,
  ) async {
    final host = await pumpHost(tester, Highlighter.currentHighlighter);
    await openPanel(tester, host, kind: KitPenPanelKind.highlighters);
    expect(penColumn(KitPenKind.highlighterChisel), findsOneWidget);
    expect(penColumn(KitPenKind.highlighterRound), findsNothing);
    expect(penColumn(KitPenKind.fountain), findsNothing);
    // the straight-line and horizontal/vertical switches; no stabiliser
    expect(find.byType(KitSlider), findsOneWidget);
    expect(find.byType(KitToggleRow), findsNWidgets(2));
    expect(find.text('직선 자동 보정'), findsOneWidget);
    expect(find.text('수평/수직 그리기'), findsOneWidget);
    expect(find.text('투명도'), findsNothing);
    expect(find.text('글자 크기에 맞춰 두께 조절'), findsNothing);
    expect(find.text('T'), findsNothing);
    expect(find.byKey(const ValueKey('tool-panel-stabiliser')), findsNothing);
  });

  testWidgets('the chosen pen rises and its sample follows the size', (
    tester,
  ) async {
    final pen = levelled(Pen.ballpointPen(), 37);
    Pen.currentPen = pen;
    final host = await pumpHost(tester, pen);
    await openPanel(tester, host);
    final up = bodyTop(tester, KitPenKind.finePen);
    final down = bodyTop(tester, KitPenKind.fountain);
    expect(down - up, closeTo(KitTokens.penRise, 0.01));
    expect(bodyTop(tester, KitPenKind.pencil), down);
    expect(penSample(tester).kind, KitPenKind.finePen);
    expect(penSample(tester).level, 37);
    expect(penSample(tester).ink, pen.color.withValues(alpha: 1));
    expect(sliderNumber(tester), '37');
    await tester.tap(inSizeRow(iconNamed(KitIconName.plus)));
    await tester.pumpAndSettle();
    expect(penSample(tester).level, 42);
    expect(sliderNumber(tester), '42');
  });

  testWidgets('dragging the size slider redraws only the sample', (
    tester,
  ) async {
    final pen = levelled(CountingPen(Pen.fountainPen()), 37);
    Pen.currentPen = pen;
    final host = await pumpHost(tester, pen);
    await openPanel(tester, host);
    final builds = host.builds;
    final thumb = tester.getCenter(
      inSizeRow(find.byKey(const Key('kit-slider-thumb'))),
    );
    final gesture = await tester.startGesture(thumb);
    await tester.pump();
    for (var i = 0; i < 3; i++) {
      await gesture.moveBy(const Offset(10, 0));
      await tester.pump();
    }
    final dragged = penSample(tester).level;
    expect(dragged, greaterThan(37));
    expect(sliderNumber(tester), '$dragged');
    expect(pen.sizes, isEmpty);
    expect(host.tools, isEmpty);
    expect(host.colors, isEmpty);
    expect(host.builds, builds);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(pen.sizes, [levelToSize(dragged, min: 1, max: 25)]);
    expect(sliderNumber(tester), '$dragged');
    expect(host.tools, isEmpty);
    expect(host.colors, isEmpty);
    expect(host.builds, builds);
    // closed and opened again it reads the same number back
    await closePanel(tester);
    await openPanel(tester, host);
    expect(sliderNumber(tester), '$dragged');
    expect(penSample(tester).level, dragged);
  });

  testWidgets('plus and minus commit the size once each', (tester) async {
    final pen = levelled(CountingPen(Pen.fountainPen()), 50);
    Pen.currentPen = pen;
    final host = await pumpHost(tester, pen);
    await openPanel(tester, host);
    await tester.tap(inSizeRow(iconNamed(KitIconName.plus)));
    await tester.pumpAndSettle();
    expect(pen.sizes, [levelToSize(55, min: 1, max: 25)]);
    expect(sliderNumber(tester), '55');
    await tester.tap(inSizeRow(iconNamed(KitIconName.minus)));
    await tester.pumpAndSettle();
    expect(pen.sizes, [
      levelToSize(55, min: 1, max: 25),
      levelToSize(50, min: 1, max: 25),
    ]);
    expect(sliderNumber(tester), '50');
    expect(stows.lastFountainPenOptions.value.size, pen.options.size);
  });

  testWidgets('a tap on the thumb keeps a size kept before', (tester) async {
    // 5 (the old default) sits between the numbers 17 and 18
    final pen = CountingPen(Pen.fountainPen());
    pen.options = pen.options.copyWith(size: 5);
    Pen.currentPen = pen;
    final host = await pumpHost(tester, pen);
    await openPanel(tester, host);
    expect(sliderNumber(tester), '18');
    await tester.tap(inSizeRow(find.byKey(const Key('kit-slider-thumb'))));
    await tester.pumpAndSettle();
    expect(pen.sizes, isEmpty);
    expect(pen.options.size, 5);
  });

  testWidgets('switching pens updates the panel without the host rebuilding it', (
    tester,
  ) async {
    Pen.currentPen = levelled(Pen.fountainPen(), 30);
    final host = await pumpHost(tester, Pen.currentPen);
    await openPanel(tester, host);
    expect(sliderNumber(tester), '30');
    final builds = host.builds;
    await tester.tap(penColumn(KitPenKind.finePen));
    await tester.pump();
    expect(host.tools, hasLength(1));
    expect(penKindOf(host.tools.single), KitPenKind.finePen);
    expect(host.builds, builds);
    // the new pen rises in penRise
    await tester.pump(KitMotion.penRise);
    await tester.pump();
    expect(
      bodyTop(tester, KitPenKind.fountain) -
          bodyTop(tester, KitPenKind.finePen),
      closeTo(KitTokens.penRise, 0.01),
    );
    // its sample writes itself on after penSampleDelay, in penSampleDraw
    Rect reveal() => tester
        .widget<ClipRect>(find.byKey(const ValueKey('pen-panel-sample-reveal')))
        .clipper!
        .getClip(
          const Size(KitTokens.penSampleWidth, KitTokens.penSampleHeight),
        );
    expect(reveal().right, lessThanOrEqualTo(0));
    await tester.pump(
      KitMotion.penSampleDelay +
          KitMotion.penSampleDraw ~/ 2 -
          KitMotion.penRise,
    );
    expect(reveal().right, greaterThan(0));
    expect(reveal().right, lessThan(KitTokens.penSampleWidth));
    await tester.pump(KitMotion.penSampleDraw);
    await tester.pump();
    expect(reveal().right, greaterThanOrEqualTo(KitTokens.penSampleWidth));
    expect(penSample(tester).kind, KitPenKind.finePen);
    // the rows now read the new pen
    final fine = host.tools.single as Pen;
    await tester.pumpAndSettle();
    expect(
      sliderNumber(tester),
      '${sizeToLevel(fine.options.size, min: fine.sizeMin, max: fine.sizeMax)}',
    );
    expect(host.builds, builds);
  });

  testWidgets('pen box opens, applies a saved pen and removes on long press', (
    tester,
  ) async {
    stows.penBox.value = [
      const PenBoxEntry(
        toolId: ToolId.ballpointPen,
        color: 0xff2f55d4,
        size: 8,
        streamline: .5,
      ).toJson(),
      const PenBoxEntry(
        toolId: ToolId.shapePen,
        color: 0xff1f2023,
        size: 3,
        streamline: 0,
      ).toJson(),
    ];
    final host = await pumpHost(tester, Pen.currentPen);
    await openPanel(tester, host);
    final open = find.byKey(const ValueKey('pen-panel-pen-box-open'));
    final box = find.byKey(const ValueKey('kit-pen-box'));
    Finder entry(int i) => find.byKey(ValueKey('pen-box-entry-$i'));
    await tester.tap(open);
    await tester.pumpAndSettle();
    expect(box, findsOneWidget);
    // it lies on the pen row, edge to edge with the panel, clear of the
    // close circle (design M-1, screen review)
    final panel = tester.getRect(find.byKey(const ValueKey('kit-pen-panel')));
    final boxRect = tester.getRect(box);
    expect(boxRect.left, panel.left);
    expect(boxRect.width, panel.width);
    expect(boxRect.top, panel.top + 45);
    expect(
      boxRect.top,
      greaterThan(
        tester
            .getRect(find.byKey(const ValueKey('pen-panel-close-mark')))
            .bottom,
      ),
    );
    // its title is 12 px, and the hint for taking a pen out is beside it
    expect(tester.widget<Text>(find.text('펜 상자')).style?.fontSize, 12);
    expect(find.text('길게 눌러 빼기'), findsOneWidget);
    // a sample's stroke (x 0-35, y 20-34 of its sheet) is centred in the card
    final stroke = tester.getRect(
      find.descendant(
        of: entry(0),
        matching: find.byKey(const ValueKey('pen-box-stroke')),
      ),
    );
    final card = tester.getRect(entry(0));
    expect(stroke.center.dx, closeTo(card.center.dx, 0.01));
    expect(
      find.descendant(of: entry(0), matching: find.text('가는 펜')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: entry(1), matching: find.text('도형 펜')),
      findsOneWidget,
    );
    // the shape pen shows the fine pen's sample
    expect(
      tester
          .widget<KitPenSample>(
            find.descendant(of: entry(1), matching: find.byType(KitPenSample)),
          )
          .kind,
      KitPenKind.finePen,
    );
    await tester.tap(entry(0));
    await tester.pumpAndSettle();
    expect(host.calls, ['tool', 'color']);
    expect(host.tools.single.toolId, ToolId.ballpointPen);
    expect((host.tools.single as Pen).options.size, 8);
    expect(host.colors, [const Color(0xff2f55d4)]);
    expect(box, findsNothing);
    expect(find.byType(KitPenPanel), findsOneWidget);
    expect(
      bodyTop(tester, KitPenKind.finePen),
      lessThan(bodyTop(tester, KitPenKind.fountain)),
    );
    // the pen in hand now is the first one: its card shows it
    await tester.tap(open);
    await tester.pumpAndSettle();
    Color? cardFill(int i) =>
        (tester
                    .widget<DecoratedBox>(
                      find
                          .descendant(
                            of: entry(i),
                            matching: find.byType(DecoratedBox),
                          )
                          .first,
                    )
                    .decoration
                as BoxDecoration)
            .color;
    expect(cardFill(0), KitTokens.selectedFill);
    expect(cardFill(1), KitTokens.penBoxCardBg);
    // a long press takes a pen out of the box
    await tester.longPress(entry(0));
    await tester.pumpAndSettle();
    expect([for (final e in PenBox.entries) e.toolId], [ToolId.shapePen]);
    expect(entry(1), findsNothing);
    expect(
      find.descendant(of: entry(0), matching: find.text('도형 펜')),
      findsOneWidget,
    );
    await tester.longPress(entry(0));
    await tester.pumpAndSettle();
    expect(PenBox.entries, isEmpty);
    expect(find.text('자주 쓰는 펜은 ☆ 단추로 이 상자에 담아 두세요.'), findsOneWidget);
    expect(find.text('길게 눌러 빼기'), findsNothing);
    expect(host.tools, hasLength(1));
  });

  testWidgets('a full pen box shows all twenty pens', (tester) async {
    stows.penBox.value = [
      for (var i = 0; i < PenBox.maxEntries; i++)
        PenBoxEntry(
          toolId: ToolId.pencil,
          color: 0xff000000 + i,
          size: 3,
          streamline: .1,
        ).toJson(),
    ];
    final host = await pumpHost(tester, Pen.currentPen);
    await openPanel(tester, host);
    await tester.tap(find.byKey(const ValueKey('pen-panel-pen-box-open')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    for (var i = 0; i < PenBox.maxEntries; i++) {
      expect(
        find.byKey(ValueKey('pen-box-entry-$i'), skipOffstage: false),
        findsOneWidget,
        reason: '$i',
      );
    }
    await tester.tap(find.byKey(const ValueKey('pen-box-entry-19')));
    await tester.pumpAndSettle();
    expect(host.colors, [const Color(0xff000013)]);
  });

  testWidgets('star adds the pen to the box and removes it again', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final pen = Pen.currentPen;
    final host = await pumpHost(tester, pen);
    await openPanel(tester, host);
    final star = find.byKey(const ValueKey('toolbar-pen-box'));
    bool lit() => tester
        .widget<KitIcon>(
          find.descendant(of: star, matching: find.byType(KitIcon)),
        )
        .selected;
    expect(lit(), isFalse);
    await tester.tap(star);
    await tester.pump();
    expect(PenBox.contains(PenBoxEntry.of(pen)), isTrue);
    expect(lit(), isTrue);
    await tester.tap(star);
    await tester.pump();
    expect(PenBox.contains(PenBoxEntry.of(pen)), isFalse);
    expect(lit(), isFalse);
    // a full box takes no new pen, and the star says it cannot be pressed
    stows.penBox.value = [
      for (var i = 0; i < PenBox.maxEntries; i++)
        PenBoxEntry(
          toolId: ToolId.pencil,
          color: 0xff000000 + i,
          size: 3,
          streamline: .1,
        ).toJson(),
    ];
    await tester.pump();
    await tester.tap(star);
    await tester.pump();
    expect(PenBox.entries, hasLength(PenBox.maxEntries));
    expect(PenBox.contains(PenBoxEntry.of(pen)), isFalse);
    expect(
      tester.getSemantics(star).getSemanticsData().flagsCollection.isEnabled,
      Tristate.isFalse,
    );
    handle.dispose();
  });

  testWidgets('straighten toggle drives the setting of its panel', (
    tester,
  ) async {
    stows.autoStraightenLines.value = false;
    stows.highlighterStraightLine.value = false;
    final host = await pumpHost(tester, Pen.currentPen);
    await openPanel(tester, host);
    final toggle = find.byKey(const ValueKey('toolbar-auto-straighten'));
    bool shown() => tester.widget<KitToggleRow>(toggle).value;
    bool rulers() => tester
        .widgetList<KitPenArt>(find.byType(KitPenArt))
        .every((a) => a.ruler);
    expect(shown(), isFalse);
    await tester.tap(toggle);
    await tester.pump();
    expect(stows.autoStraightenLines.value, isTrue);
    expect(stows.highlighterStraightLine.value, isFalse);
    expect(shown(), isTrue);
    expect(rulers(), isTrue);
    expect(penSample(tester).straight, isTrue);
    // turned off elsewhere (the settings page or the settings table)
    stows.autoStraightenLines.value = false;
    await tester.pump();
    expect(shown(), isFalse);
    expect(
      tester.widgetList<KitPenArt>(find.byType(KitPenArt)).any((a) => a.ruler),
      isFalse,
    );
    expect(penSample(tester).straight, isFalse);
    // the highlighter panel drives the highlighter's own straight line
    await closePanel(tester);
    host.tool = Highlighter.currentHighlighter;
    await openPanel(tester, host, kind: KitPenPanelKind.highlighters);
    await tester.tap(toggle);
    await tester.pump();
    expect(stows.highlighterStraightLine.value, isTrue);
    expect(stows.autoStraightenLines.value, isFalse);
    expect(shown(), isTrue);
  });

  testWidgets('collapse keeps only the pen row and is remembered', (
    tester,
  ) async {
    final collapsed = ValueNotifier(false);
    addTearDown(collapsed.dispose);
    final host = await pumpHost(tester, Pen.currentPen);
    await openPanel(tester, host, collapsed: collapsed);
    final button = find.byKey(const ValueKey('pen-panel-collapse'));
    expect(find.byType(KitSlider), findsNWidgets(2));
    expect(iconNamed(KitIconName.collapse), findsOneWidget);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(collapsed.value, isTrue);
    expect(find.byType(KitSlider), findsNothing);
    expect(find.byType(KitToggleRow), findsNothing);
    expect(find.byType(KitPenColorRow), findsNothing);
    expect(penColumn(KitPenKind.fountain), findsOneWidget);
    expect(iconNamed(KitIconName.expand), findsOneWidget);
    final handle = tester.ensureSemantics();
    expect(tester.getSemantics(button).label, KitIconName.expand.label);
    handle.dispose();
    // a new panel with the same notifier opens collapsed
    await closePanel(tester);
    await openPanel(tester, host, collapsed: collapsed);
    expect(find.byType(KitSlider), findsNothing);
    expect(penColumn(KitPenKind.fountain), findsOneWidget);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(collapsed.value, isFalse);
    expect(find.byType(KitSlider), findsNWidgets(2));
  });

  testWidgets('the app setting keeps the panel collapsed between panels', (
    tester,
  ) async {
    // Task 12 hands stows.penPanelCollapsed to each panel it opens
    addTearDown(() => stows.penPanelCollapsed.value = false);
    final host = await pumpHost(tester, Pen.currentPen);
    await openPanel(tester, host, collapsed: stows.penPanelCollapsed);
    await tester.tap(find.byKey(const ValueKey('pen-panel-collapse')));
    await tester.pumpAndSettle();
    expect(stows.penPanelCollapsed.value, isTrue);
    await closePanel(tester);
    await openPanel(tester, host, collapsed: stows.penPanelCollapsed);
    expect(find.byType(KitSlider), findsNothing);
    expect(iconNamed(KitIconName.expand), findsOneWidget);
  });

  testWidgets('the size slider names its ends', (tester) async {
    final handle = tester.ensureSemantics();
    final host = await pumpHost(tester, Pen.currentPen);
    await openPanel(tester, host);
    expect(find.bySemanticsLabel('가늘게'), findsOneWidget);
    expect(find.bySemanticsLabel('굵게'), findsOneWidget);
    expect(find.byTooltip('가늘게'), findsOneWidget);
    expect(
      tester
          .getSemantics(inSizeRow(find.byKey(const Key('kit-slider-track'))))
          .label,
      '굵기',
    );
    handle.dispose();
  });

  testWidgets('a short screen scrolls the rows under the pens', (tester) async {
    // split screen: less room than the 471 the panel needs
    final host = await pumpHost(tester, Pen.currentPen);
    tester.view.physicalSize = const Size(800, 300);
    await tester.pumpAndSettle();
    await openPanel(tester, host);
    expect(tester.takeException(), isNull);
    final panel = tester.getRect(find.byKey(const ValueKey('kit-pen-panel')));
    expect(panel.height, lessThanOrEqualTo(300));
    expect(penColumn(KitPenKind.fountain), findsOneWidget);
    await tester.drag(
      find.byKey(const ValueKey('toolbar-auto-straighten')),
      const Offset(0, -200),
    );
    await tester.pumpAndSettle();
    expect(pageDot(0), findsOneWidget);
    expect(tester.getRect(pageDot(0)).bottom, lessThanOrEqualTo(panel.bottom));
  });

  testWidgets('the panel lays out like the preview', (tester) async {
    final pen = levelled(Pen.ballpointPen(), 37)
      ..color = const Color(0xffe5323e);
    Pen.currentPen = pen;
    final host = await pumpHost(tester, pen);
    await openPanel(tester, host);
    final panel = tester.getRect(find.byKey(const ValueKey('kit-pen-panel')));
    // stage 1 rows: size, straight line, colours, page dots (no line type),
    // then the stabiliser 16 under the dots (91.9 high with its note on one
    // line, as with the app's fonts; the test font may break it in two)
    final stabNoteLines = find
        .descendant(
          of: find.byWidgetPredicate(
            (w) => w is KitLines && w.data == '높을수록 선이 부드럽고 약간 늦게 따라갑니다.',
          ),
          matching: find.byType(Text),
        )
        .evaluate()
        .length;
    expect(panel.width, 300);
    expect(panel.height, closeTo(455.5 + 15.4 * stabNoteLines, 1e-9));
    Offset at(Finder f) => tester.getTopLeft(f) - panel.topLeft;
    // head (`.snp .hd`): icons 22 at y 21, the close circle 24 at y 20
    expect(at(iconNamed(KitIconName.penbox)), const Offset(15, 21));
    expect(at(iconNamed(KitIconName.star)), const Offset(51, 21));
    expect(at(iconNamed(KitIconName.collapse)), const Offset(225, 21));
    expect(
      at(find.byKey(const ValueKey('pen-panel-close-mark'))),
      const Offset(261, 20),
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('pen-panel-close-mark'))),
      const Size(24, 24),
    );
    // three pens 40 wide and 9 apart, centred in the 278 wide row at y 45
    expect(at(penColumn(KitPenKind.fountain)), const Offset(81, 45));
    expect(at(penColumn(KitPenKind.finePen)), const Offset(130, 45));
    expect(at(penColumn(KitPenKind.pencil)), const Offset(179, 45));
    // the head buttons are pressed in 44 x 44 or more, icons unmoved
    for (final k in [
      'pen-panel-pen-box-open',
      'toolbar-pen-box',
      'pen-panel-collapse',
      'pen-panel-close',
    ]) {
      final size = tester.getSize(find.byKey(ValueKey(k)));
      expect(size.width, greaterThanOrEqualTo(44), reason: k);
      expect(size.height, greaterThanOrEqualTo(44), reason: k);
    }
    // the size track at x 62, centred in the first row (173..219), the minus
    // and plus 7 away like `.snp .srow` (icons at 21 and 247)
    final track = tester.getRect(
      inSizeRow(find.byKey(const Key('kit-slider-track'))),
    );
    expect(track.left - panel.left, 62);
    expect(track.center.dy - panel.top, 196);
    expect(at(inSizeRow(iconNamed(KitIconName.minus))), const Offset(21, 180));
    expect(at(inSizeRow(iconNamed(KitIconName.plus))), const Offset(247, 180));
    final toggle = tester.getRect(
      find.byKey(const ValueKey('toolbar-auto-straighten')),
    );
    expect(toggle.topLeft - panel.topLeft, const Offset(15, 219));
    expect(toggle.size, const Size(270, 46));
    // colours 4 below (269..315), dots 13 below the colour row
    expect(at(swatchDot(const Color(0xffe5323e))), const Offset(15, 281));
    expect(at(swatchDot(const Color(0xff1f2023))), const Offset(211, 281));
    expect(
      tester.getCenter(pageDot(0)).dy - panel.top,
      315 + 13 + KitTokens.pageDot / 2,
    );
    expect(at(find.text('기본 색')).dx, 19);
  });
}
