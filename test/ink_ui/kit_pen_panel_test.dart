import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/ink_ui/pen_panel/kit_pen_color_row.dart';
import 'package:saber/components/ink_ui/pen_panel/kit_pen_panel.dart';
import 'package:saber/components/ink_ui/pen_panel/pen_column.dart';
import 'package:saber/components/ink_ui/pen_panel/size_level.dart';
import 'package:saber/components/kit/kit_controls.dart';
import 'package:saber/components/kit/kit_icon.dart';
import 'package:saber/components/kit/kit_motion.dart';
import 'package:saber/components/kit/kit_pen_art.dart';
import 'package:saber/components/kit/kit_text.dart';
import 'package:saber/components/kit/kit_tokens.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/ink/pen_kind.dart';
import 'package:saber/data/ink/pen_prefs.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/settings/app_settings.dart';
import 'package:saber/data/tools/highlighter.dart';
import 'package:saber/data/tools/pen.dart';
import 'package:saber/data/tools/pen_box.dart';
import 'package:saber/data/tools/pencil.dart';
import 'package:saber/data/tools/shape_pen.dart';
import 'package:sbn/tool_id.dart';

import 'pen_panel_harness.dart';

void main() {
  FlavorConfig.setup();
  tearDown(resetPenPanelState);

  testWidgets('the pen panel offers all seven pens in PEN_NAME order', (
    tester,
  ) async {
    final host = await pumpHost(tester, Pen.currentPen);
    await openPanel(tester, host);
    const pens = [
      KitPenKind.fountain,
      KitPenKind.calligraphy,
      KitPenKind.finePen,
      KitPenKind.pencil,
      KitPenKind.brush,
    ];
    const highlighters = [
      KitPenKind.highlighterChisel,
      KitPenKind.highlighterRound,
    ];
    void expectRow(List<KitPenKind> shown) {
      for (final k in KitPenKind.values) {
        expect(
          penColumn(k),
          shown.contains(k) ? findsOneWidget : findsNothing,
          reason: k.label,
        );
      }
      // left to right in the preview's order, each named as the preview
      final xs = [for (final k in shown) tester.getTopLeft(penColumn(k)).dx];
      for (var i = 1; i < xs.length; i++) {
        expect(xs[i - 1], lessThan(xs[i]), reason: shown[i].label);
      }
      for (final k in shown) {
        expect(
          tester.getSemantics(penColumn(k)).label,
          k.label,
          reason: k.previewId,
        );
      }
    }

    expectRow(pens);
    await closePanel(tester);
    host.tool = Highlighter.currentHighlighter;
    await openPanel(tester, host, kind: KitPenPanelKind.highlighters);
    expectRow(highlighters);
    expect([...pens, ...highlighters], KitPenKind.values);
    expect(
      [for (final k in KitPenKind.values) k.label],
      const ['펜(가는 촉)', '만년필(넓은 촉)', '가는 펜', '연필', '붓', '납작 형광펜', '둥근 형광펜'],
    );
  });

  testWidgets('the opacity row shows for highlighters and the pencil only', (
    tester,
  ) async {
    final opacity = find.byKey(const ValueKey('pen-panel-opacity'));
    Finder inOpacity(Finder f) => find.descendant(of: opacity, matching: f);
    final host = await pumpHost(tester, Pen.fountainPen());
    await openPanel(tester, host);
    for (final k in const [
      KitPenKind.calligraphy,
      KitPenKind.finePen,
      KitPenKind.pencil,
      KitPenKind.brush,
      KitPenKind.fountain,
    ]) {
      await tester.tap(penColumn(k));
      await tester.pumpAndSettle();
      expect(penKindOf(host.tool), k);
      expect(
        opacity,
        k == KitPenKind.pencil ? findsOneWidget : findsNothing,
        reason: k.label,
      );
    }
    // the pencil's opacity: 100 is its full 255, a step down is 90%
    await tester.tap(penColumn(KitPenKind.pencil));
    await tester.pumpAndSettle();
    expect(sliderNumber(tester, opacity), '100');
    await tester.tap(inOpacity(iconNamed(KitIconName.minus)));
    await tester.pumpAndSettle();
    expect(stows.pencilOpacity.value, 230);
    expect(host.toolState.alpha, 230);
    expect(sliderNumber(tester, opacity), '90');
    expect(penSample(tester).alpha, closeTo(.9, 1e-9));
    await closePanel(tester);

    // both highlighters: 100 is the highlighter's own 100 of 255
    host.tool = Highlighter.currentHighlighter;
    await openPanel(tester, host, kind: KitPenPanelKind.highlighters);
    expect(opacity, findsOneWidget);
    expect(sliderNumber(tester, opacity), '100');
    await tester.tap(penColumn(KitPenKind.highlighterRound));
    await tester.pumpAndSettle();
    expect(penKindOf(host.tool), KitPenKind.highlighterRound);
    expect(opacity, findsOneWidget);
    await tester.tap(inOpacity(iconNamed(KitIconName.minus)));
    await tester.pumpAndSettle();
    expect(stows.roundHighlighterOpacity.value, 90);
    expect(stows.highlighterOpacity.value, 100);
    expect(host.toolState.alpha, 90);

    // while the opacity slider moves (before it is let go), the size dots
    // already carry the opacity it shows
    KitSlider slider(String key) => tester.widget<KitSlider>(
      find.descendant(
        of: find.byKey(ValueKey(key)),
        matching: find.byType(KitSlider),
      ),
    );
    expect(slider('pen-panel-size').markColor!.a, closeTo(.9, 1e-3));
    slider('pen-panel-opacity').onChanged(40);
    await tester.pump();
    expect(slider('pen-panel-size').markColor!.a, closeTo(.4, 1e-3));
    expect(stows.roundHighlighterOpacity.value, 90, reason: 'not let go');
  });

  testWidgets('the line style row shows for 가는 펜 only', (tester) async {
    final row = find.byKey(const ValueKey('pen-panel-line-style'));
    Finder pill(KitPenDash d) =>
        find.byKey(ValueKey('pen-panel-line-${d.name}'));
    final host = await pumpHost(tester, Pen.fountainPen());
    await openPanel(tester, host);
    expect(row, findsNothing);
    for (final k in const [
      KitPenKind.calligraphy,
      KitPenKind.pencil,
      KitPenKind.brush,
      KitPenKind.finePen,
    ]) {
      await tester.tap(penColumn(k));
      await tester.pumpAndSettle();
      expect(
        row,
        k == KitPenKind.finePen ? findsOneWidget : findsNothing,
        reason: k.label,
      );
    }
    // four pills in the preview's order (`SP_LINES`), the solid one chosen
    const order = [
      KitPenDash.solid,
      KitPenDash.thin,
      KitPenDash.dash,
      KitPenDash.dot,
    ];
    final xs = [for (final d in order) tester.getTopLeft(pill(d)).dx];
    for (var i = 1; i < xs.length; i++) {
      expect(xs[i - 1], lessThan(xs[i]), reason: order[i].name);
    }
    expect(
      tester
          .getSemantics(pill(KitPenDash.solid))
          .getSemanticsData()
          .flagsCollection
          .isSelected,
      Tristate.isTrue,
    );
    await tester.tap(pill(KitPenDash.dash));
    await tester.pumpAndSettle();
    expect(stows.finePenLineStyle.value, KitPenDash.dash);
    expect(host.toolState.lineStyle, KitPenDash.dash);
    expect(penSample(tester).dash, KitPenDash.dash);
    expect(
      tester
          .getSemantics(pill(KitPenDash.dash))
          .getSemanticsData()
          .flagsCollection
          .isSelected,
      Tristate.isTrue,
    );
    expect(
      tester
          .getSemantics(pill(KitPenDash.solid))
          .getSemanticsData()
          .flagsCollection
          .isSelected,
      Tristate.isFalse,
    );
    // the fine pen draws dashed strokes from now on
    expect((host.tool as Pen).style.lineStyle, KitPenDash.dash);
  });

  testWidgets('picking 붓 selects the brush through the host', (tester) async {
    final host = await pumpHost(tester, Pen.fountainPen());
    await openPanel(tester, host);
    await tester.tap(penColumn(KitPenKind.brush));
    await tester.pumpAndSettle();
    expect(host.calls, ['tool']);
    final brush = host.tools.single;
    expect(brush.toolId, ToolId.brush);
    expect(penKindOf(brush), KitPenKind.brush);
    // the brush in hand is the one kept for it: picked again, it comes back
    expect(identical(host.toolState.penFor(KitPenKind.brush), brush), isTrue);
    expect(penSample(tester).kind, KitPenKind.brush);
    expect(
      bodyTop(tester, KitPenKind.fountain) - bodyTop(tester, KitPenKind.brush),
      closeTo(KitTokens.penRise, 0.01),
    );
  });

  testWidgets(
    'the panel shows 둥근 형광펜 as chosen while the round highlighter is in hand',
    (tester) async {
      final round = Highlighter.round();
      final host = await pumpHost(tester, round);
      await openPanel(tester, host, kind: KitPenPanelKind.highlighters);
      expect(penKindOf(round), KitPenKind.highlighterRound);
      expect(penSample(tester).kind, KitPenKind.highlighterRound);
      expect(
        bodyTop(tester, KitPenKind.highlighterChisel) -
            bodyTop(tester, KitPenKind.highlighterRound),
        closeTo(KitTokens.penRise, 0.01),
      );
      expect(
        tester
            .getSemantics(penColumn(KitPenKind.highlighterRound))
            .getSemanticsData()
            .flagsCollection
            .isSelected,
        Tristate.isTrue,
      );
      expect(
        tester
            .getSemantics(penColumn(KitPenKind.highlighterChisel))
            .getSemanticsData()
            .flagsCollection
            .isSelected,
        Tristate.isFalse,
      );
      // tapping the chosen one asks nothing of the host
      await tester.tap(penColumn(KitPenKind.highlighterRound));
      await tester.pumpAndSettle();
      expect(host.tools, isEmpty);
    },
  );

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
    final host = await pumpHost(tester, Pen.currentPen);
    final kind = penKindOf(Pen.currentPen)!;
    await openPanel(tester, host);
    final toggle = find.byKey(const ValueKey('toolbar-auto-straighten'));
    bool shown() => tester.widget<KitToggleRow>(toggle).value;
    bool ruler(KitPenKind k) =>
        tester.widget<PenPanelColumn>(penColumn(k)).ruler;
    expect(shown(), isFalse);
    await tester.tap(toggle);
    await tester.pump();
    // the pen in hand's own straight line, no other pen's
    expect(straightLineOf(kind), isTrue);
    for (final other in KitPenKind.values.where((k) => k != kind)) {
      expect(straightLineOf(other), isFalse, reason: other.label);
    }
    expect(stows.highlighterStraightLine.value, isFalse);
    expect(shown(), isTrue);
    expect(ruler(kind), isTrue);
    expect(ruler(KitPenKind.pencil), isFalse);
    expect(penSample(tester).straight, isTrue);
    // turned off elsewhere (the settings page or the settings table)
    setStraightLine(kind, false);
    await tester.pump();
    expect(shown(), isFalse);
    expect(
      tester.widgetList<KitPenArt>(find.byType(KitPenArt)).any((a) => a.ruler),
      isFalse,
    );
    expect(penSample(tester).straight, isFalse);
    // the highlighter panel drives the highlighter in hand's straight line
    await closePanel(tester);
    host.tool = Highlighter.currentHighlighter;
    await openPanel(tester, host, kind: KitPenPanelKind.highlighters);
    await tester.tap(toggle);
    await tester.pump();
    expect(straightLineOf(KitPenKind.highlighterChisel), isTrue);
    expect(straightLineOf(KitPenKind.highlighterRound), isFalse);
    expect(straightLineOf(kind), isFalse);
    expect(shown(), isTrue);
  });

  testWidgets(
    "turning the highlighter straight line off dims 수평/수직 with the table's reason",
    (tester) async {
      setStraightLine(KitPenKind.highlighterChisel, true);
      final host = await pumpHost(tester, Highlighter.currentHighlighter);
      await openPanel(tester, host, kind: KitPenPanelKind.highlighters);
      final axis = find.byKey(const ValueKey('tool-panel-axis-lock'));
      KitToggleRow row() => tester.widget<KitToggleRow>(axis);
      String? reason(bool straight) => settingsRegistry.unusableReason(
        axisLockInHandKey,
        values: {straightLineInHandKey: straight},
      );
      expect(reason(true), isNull);
      expect(row().onChanged, isNotNull);
      await tester.tap(find.byKey(const ValueKey('toolbar-auto-straighten')));
      await tester.pump();
      expect(straightLineOf(KitPenKind.highlighterChisel), isFalse);
      expect(reason(false), '먼저 위의 ‘직선 자동 보정’을 켜세요.');
      expect(row().description, reason(false));
      expect(row().onChanged, isNull);
    },
  );

  testWidgets("turning the flat highlighter's straight line on from the panel "
      "leaves the round highlighter's value and ruler off", (tester) async {
    final host = await pumpHost(tester, Highlighter.currentHighlighter);
    await openPanel(tester, host, kind: KitPenPanelKind.highlighters);
    bool ruler(KitPenKind k) =>
        tester.widget<PenPanelColumn>(penColumn(k)).ruler;
    expect(ruler(KitPenKind.highlighterChisel), isFalse);
    expect(ruler(KitPenKind.highlighterRound), isFalse);
    await tester.tap(find.byKey(const ValueKey('toolbar-auto-straighten')));
    await tester.pump();
    expect(straightLineOf(KitPenKind.highlighterChisel), isTrue);
    expect(ruler(KitPenKind.highlighterChisel), isTrue);
    expect(straightLineOf(KitPenKind.highlighterRound), isFalse);
    expect(ruler(KitPenKind.highlighterRound), isFalse);
    expect(stows.straightLineByPen.value, {'hlchisel': true});
    // nor the old shared key, which both highlighters read until set
    expect(stows.highlighterStraightLine.value, isFalse);
    // the round one in hand shows its own, off
    await tester.tap(penColumn(KitPenKind.highlighterRound));
    await tester.pump();
    expect(
      tester
          .widget<KitToggleRow>(
            find.byKey(const ValueKey('toolbar-auto-straighten')),
          )
          .value,
      isFalse,
    );
    expect(ruler(KitPenKind.highlighterRound), isFalse);
    expect(ruler(KitPenKind.highlighterChisel), isTrue);
  });

  testWidgets("turning one highlighter's straight line off dims its 수평/수직 "
      'only', (tester) async {
    setStraightLine(KitPenKind.highlighterChisel, true);
    setStraightLine(KitPenKind.highlighterRound, true);
    final host = await pumpHost(tester, Highlighter.currentHighlighter);
    await openPanel(tester, host, kind: KitPenPanelKind.highlighters);
    final axis = find.byKey(const ValueKey('tool-panel-axis-lock'));
    KitToggleRow row() => tester.widget<KitToggleRow>(axis);
    await tester.tap(axis);
    await tester.pump();
    expect(axisLockOf(KitPenKind.highlighterChisel), isTrue);
    expect(axisLockOf(KitPenKind.highlighterRound), isFalse);
    // the flat one's straight line off: its row dims, its lock is kept
    await tester.tap(find.byKey(const ValueKey('toolbar-auto-straighten')));
    await tester.pump();
    expect(row().onChanged, isNull);
    expect(row().value, isTrue);
    // the round one in hand: its own straight line is on, its row is usable
    await tester.tap(penColumn(KitPenKind.highlighterRound));
    await tester.pump();
    expect(penKindOf(host.tool), KitPenKind.highlighterRound);
    expect(row().onChanged, isNotNull);
    expect(row().value, isFalse);
    expect(
      tester
          .widget<KitToggleRow>(
            find.byKey(const ValueKey('toolbar-auto-straighten')),
          )
          .value,
      isTrue,
    );
    expect(straightLineOf(KitPenKind.highlighterChisel), isFalse);
    expect(axisLockOf(KitPenKind.highlighterChisel), isTrue);
  });

  testWidgets('every ink pen has its own 수평/수직 row, dimmed while its straight '
      'line is off', (tester) async {
    final host = await pumpHost(tester, Pencil.currentPencil);
    await openPanel(tester, host);
    final axis = find.byKey(const ValueKey('tool-panel-axis-lock'));
    KitToggleRow row() => tester.widget<KitToggleRow>(axis);
    expect(axis, findsOneWidget);
    expect(row().onChanged, isNull);
    expect(row().description, '먼저 위의 ‘직선 자동 보정’을 켜세요.');
    await tester.tap(find.byKey(const ValueKey('toolbar-auto-straighten')));
    await tester.pump();
    expect(row().onChanged, isNotNull);
    await tester.tap(axis);
    await tester.pump();
    expect(axisLockOf(KitPenKind.pencil), isTrue);
    expect(straightLineOf(KitPenKind.pencil), isTrue);
    for (final other in KitPenKind.values.where(
      (k) => k != KitPenKind.pencil,
    )) {
      expect(axisLockOf(other), isFalse, reason: other.label);
    }
    // another pen in hand: its own, off
    await tester.tap(penColumn(KitPenKind.fountain));
    await tester.pump();
    expect(row().value, isFalse);
    expect(row().onChanged, isNull);
  });

  testWidgets('the shape pen shows no straight line switches', (tester) async {
    setStraightLine(KitPenKind.fountain, true);
    final host = await pumpHost(tester, ShapePen());
    await openPanel(tester, host);
    expect(find.byKey(const ValueKey('kit-pen-panel')), findsOneWidget);
    expect(find.byKey(const ValueKey('toolbar-auto-straighten')), findsNothing);
    expect(find.byKey(const ValueKey('tool-panel-axis-lock')), findsNothing);
    // nor does a pen not in hand show its ruler as the one in hand
    expect(
      tester.widget<PenPanelColumn>(penColumn(KitPenKind.fountain)).ruler,
      isTrue,
    );
    expect(
      tester.widget<PenPanelColumn>(penColumn(KitPenKind.pencil)).ruler,
      isFalse,
    );
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
    // rows: size, the fine pen's line styles, straight line, 수평/수직 (every
    // ink pen's, the controller's ruling), colours, page dots, then the
    // stabiliser 16 under the dots (91.9 high with its note on one line, as
    // with the app's fonts; the test font may break it in two)
    final stabNoteLines = find
        .descendant(
          of: find.byWidgetPredicate(
            (w) => w is KitLines && w.data == '높을수록 선이 부드럽고 약간 늦게 따라갑니다.',
          ),
          matching: find.byType(Text),
        )
        .evaluate()
        .length;
    final axis = tester.getRect(
      find.byKey(const ValueKey('tool-panel-axis-lock')),
    );
    // what is under the 수평/수직 row moves down by its height
    final down = axis.height;
    expect(panel.width, 300);
    expect(panel.height, closeTo(501.5 + down + 15.4 * stabNoteLines, 1e-9));
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
    // five pens 40 wide and 9 apart, centred in the 278 wide row at y 45
    expect(at(penColumn(KitPenKind.fountain)), const Offset(32, 45));
    expect(at(penColumn(KitPenKind.calligraphy)), const Offset(81, 45));
    expect(at(penColumn(KitPenKind.finePen)), const Offset(130, 45));
    expect(at(penColumn(KitPenKind.pencil)), const Offset(179, 45));
    expect(at(penColumn(KitPenKind.brush)), const Offset(228, 45));
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
    // the line styles (`.snp .pills`): 9 above and below four 28 high pills
    // 7 apart across the 270 of the rows
    final lines = tester.getRect(
      find.byKey(const ValueKey('pen-panel-line-style')),
    );
    expect(lines.topLeft - panel.topLeft, const Offset(15, 219));
    expect(lines.size, const Size(270, 46));
    final solid = tester.getRect(
      find.byKey(const ValueKey('pen-panel-line-solid')),
    );
    expect(solid.topLeft - panel.topLeft, const Offset(15, 228));
    expect(solid.size, const Size((270 - 3 * 7) / 4, 28));
    expect(
      at(find.byKey(const ValueKey('pen-panel-line-dot'))).dx,
      15 + 3 * ((270 - 3 * 7) / 4 + 7),
    );
    final toggle = tester.getRect(
      find.byKey(const ValueKey('toolbar-auto-straighten')),
    );
    expect(toggle.topLeft - panel.topLeft, const Offset(15, 265));
    expect(toggle.size, const Size(270, 46));
    expect(axis.topLeft - panel.topLeft, const Offset(15, 311));
    expect(axis.width, 270);
    // colours 4 below (315..361 without it), dots 13 below the colour row
    expect(at(swatchDot(const Color(0xffe5323e))), Offset(15, 327 + down));
    expect(at(swatchDot(const Color(0xff1f2023))), Offset(211, 327 + down));
    expect(
      tester.getCenter(pageDot(0)).dy - panel.top,
      closeTo(361 + down + 13 + KitTokens.pageDot / 2, 1e-9),
    );
    expect(at(find.text('기본 색')).dx, 19);
  });
}
