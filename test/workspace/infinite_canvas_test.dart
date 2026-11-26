import 'dart:async';
import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/ink_ui/editor_toolbar/kit_editor_toolbar.dart';
import 'package:saber/components/ink_ui/kit_zoom_badge.dart';
import 'package:saber/components/ink_ui/pen_panel/size_level.dart';
import 'package:saber/components/kit/kit_icon.dart';
import 'package:saber/components/kit/kit_motion.dart';
import 'package:saber/components/kit/kit_pill.dart';
import 'package:saber/components/kit/kit_tokens.dart';
import 'package:saber/data/actions/app_action_ids.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/vault/infinite_document.dart';

import '../utils/paint_counts.dart';
import '../utils/shown.dart';
import 'infinite_canvas_harness.dart';

/// The infinite note's engine: its document, the view, ink, saving, undo,
/// the eraser and the lasso, the zoom badge. Its kit toolbar and floating
/// bar (Task 18) are in infinite_canvas_kit_test.dart.
void main() {
  setUp(() {
    FlavorConfig.setup();
    resetInkSettings();
  });

  test('infinite document roundtrips negative and distant world coordinates with pressure', () {
    final source = InfiniteDocument(
      strokes: [
        stroke(),
        stroke(id: 'far', x: 1e12, y: -1e12),
      ],
    );
    final encoded = jsonEncode(source.toJson());
    final restored = InfiniteDocument.fromJson(jsonDecode(encoded));
    expect(restored.toJson(), source.toJson());
    expect(restored.strokes.first.points.first.x, -1000000);
    expect(restored.strokes.first.points.first.pressure, .4);
    expect(source.toJson().containsKey('viewport'), isFalse);
  });

  test('viewport transforms invert, zoom retains focal world point, and pan has no page bounds', () {
    const viewport = InfiniteViewport(offset: Offset(150, 200), scale: 2);
    const world = Offset(-100, 53);
    expect(viewport.screenToWorld(viewport.worldToScreen(world)), world);
    const focal = Offset(80, 100);
    final zoomed = viewport.zoomAt(focal, 3);
    expect(zoomed.screenToWorld(focal), viewport.screenToWorld(focal));
    expect(
      viewport.pan(const Offset(1e10, -1e10)).offset,
      const Offset(1e10 + 150, -1e10 + 200),
    );
  });

  test('invalid document schema and nonfinite points are rejected', () {
    expect(
      () => InfiniteDocument.fromJson({'version': 2, 'strokes': []}),
      throwsFormatException,
    );
    final json = InfiniteDocument(strokes: [stroke()]).toJson();
    (json['strokes'] as List).first['points'][0]['x'] = double.infinity;
    expect(() => InfiniteDocument.fromJson(json), throwsFormatException);
  });

  testWidgets('save retains a moved view even when ink content is unchanged', (
    tester,
  ) async {
    InfiniteViewport? saved;
    final key = await mount(
      tester,
      initialViewport: const InfiniteViewport(
        offset: Offset(-1000000, 80),
        scale: 2,
      ),
      onSaveViewport: (view) async => saved = view,
    );
    await tester.tap(find.byTooltip('원점으로'));
    await tester.pump();
    await key.currentState!.save();
    expect(saved!.scale, 1);
    expect(saved!.offset, Offset.zero);
    await tester.pumpWidget(const SizedBox());
    final reopened = await mount(tester, initialViewport: saved!);
    expect(reopened.currentState!.viewport.offset, saved!.offset);
    expect(reopened.currentState!.viewport.scale, saved!.scale);
    expect(reopened.currentState!.document.strokes, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'stylus ink persists as world data and marks interaction busy until up',
    (tester) async {
      final saved = <InfiniteDocument>[];
      final dirty = <bool>[];
      final busy = <bool>[];
      final key = await mount(
        tester,
        onSave: (doc) async => saved.add(doc),
        onDirty: dirty.add,
        onBusy: busy.add,
      );
      await draw(tester, [const Offset(80, 90), const Offset(100, 110)]);
      expect(key.currentState!.document.strokes, hasLength(1));
      await key.currentState!.save();
      expect(saved, hasLength(1));
      expect(
        InfiniteDocument.fromJson(saved.single.toJson())
            .strokes
            .single
            .points
            .last
            .offset,
        const Offset(100, 110),
      );
      expect(dirty, [true, false]);
      expect(busy.take(2), [true, false]);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('narrow canvas keeps the widths in reach on the pen panel', (
    tester,
  ) async {
    final key = await mount(tester, size: const Size(360, 640));
    await press(tester, byKey('floating-bar-pen-fountain'));
    // + to the end: the old menu's widest, 8
    for (var i = 0; i < 20; i++) {
      final plus = find.byTooltip('굵게');
      await tester.ensureVisible(plus);
      await tester.tap(plus);
      await tester.pump();
    }
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(350, 630));
    await tester.pumpAndSettle();
    await draw(tester, [const Offset(60, 300), const Offset(90, 300)]);
    await press(tester, byKey('floating-bar-pen-hlchisel'));
    await draw(tester, [const Offset(60, 400), const Offset(90, 400)]);
    expect(key.currentState!.document.strokes.map((stroke) => stroke.width), [
      8,
      40,
    ]);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('one-tap width presets save exact pen and marker geometry', (
    tester,
  ) async {
    final old = InfiniteStroke(
      id: 'legacy-marker',
      tool: InfiniteInkTool.highlighter,
      color: 0xffc68627,
      width: 40,
      points: const [InfinitePoint(300, 200)],
    );
    InfiniteDocument? saved;
    final key = await mount(
      tester,
      initial: InfiniteDocument(strokes: [old]),
      onSave: (value) async => saved = value,
    );

    /// Picks the width labelled [level] in the floating bar's width window.
    Future<void> width(int level) async {
      await press(tester, byKey('toolbar-quick-ink-widths'));
      await tester.tap(
        find.descendant(
          of: byKey('floating-bar-widths'),
          matching: find.text('$level'),
        ),
      );
      await tester.pumpAndSettle();
    }

    // the old quick widths 1 · 2.5 · 5, highlighter five times
    await width(sizeToLevel(1, min: 1, max: 8));
    await draw(tester, [const Offset(40, 160), const Offset(90, 160)]);
    await press(tester, byKey('floating-bar-pen-hlchisel'));
    await draw(tester, [const Offset(40, 190), const Offset(90, 190)]);
    await width(sizeToLevel(25, min: 5, max: 40));

    final origin = tester.getTopLeft(surface);
    final gesture = await tester.createGesture(
      kind: PointerDeviceKind.stylus,
      pointer: 17,
    );
    await gesture.down(origin + const Offset(40, 220));
    await tester.pump();
    await gesture.moveTo(origin + const Offset(90, 220));
    await tester.pump();
    // the finished marker on the strokes' layer, the one being drawn over it
    CustomPainter painter(String layer) => tester
        .widget<CustomPaint>(
          find.descendant(
            of: byKey(layer),
            matching: find.byType(CustomPaint),
            matchRoot: true,
          ),
        )
        .painter!;
    expect(
      (Canvas target) =>
          painter('infinite-strokes').paint(target, const Size(800, 500)),
      paints..path(strokeWidth: 5),
    );
    expect(
      (Canvas target) =>
          painter('infinite-active').paint(target, const Size(800, 500)),
      paints..path(strokeWidth: 25),
    );
    await gesture.up();
    await tester.pump();

    await press(tester, byKey('floating-bar-pen-fountain'));
    await draw(tester, [const Offset(40, 250), const Offset(90, 250)]);
    await key.currentState!.save();
    final reopened = InfiniteDocument.fromJson(saved!.toJson()).strokes;
    expect(reopened.map((stroke) => stroke.width), [40, 1, 5, 25, 5]);
    expect(reopened.first.toJson(), old.toJson());
    await tester.pumpWidget(const SizedBox());
  });

  // Final review C (structure #1): the finished strokes have their own
  // layer, painted again only when the document or the view changes, as
  // the editor's pages are.
  testWidgets('colour, width and tool changes do not paint the strokes again', (
    tester,
  ) async {
    final key = await mount(
      tester,
      initial: InfiniteDocument(strokes: [stroke(x: 100, y: 300)]),
    );
    final layer = tester.renderObject<RenderRepaintBoundary>(
      byKey('infinite-strokes'),
    );
    final before = paintCounts(layer);

    await press(tester, byKey('floating-bar-colour-1'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<KitColorDot>(byKey('floating-bar-colour-1')).selected,
      isTrue,
      reason: 'the bar shows the new colour',
    );
    await press(tester, byKey('toolbar-quick-ink-widths'));
    await tester.tap(
      find.descendant(
        of: byKey('floating-bar-widths'),
        matching: find.text('${sizeToLevel(5, min: 1, max: 8)}'),
      ),
    );
    await tester.pumpAndSettle();
    await press(tester, byKey('floating-bar-pen-hlchisel'));
    await press(tester, byKey('editor-tool-eraser'));
    await press(tester, byKey('editor-tool-pen'));
    expectNotPainted(layer, before);

    // a stroke with them: the new colour and width (highlighter five times
    // as wide), and the layer painted again for it
    await draw(tester, [const Offset(100, 200), const Offset(160, 200)]);
    final drawn = key.currentState!.document.strokes.last;
    expect(drawn.color, KitTokens.floatingBarDefaultColors[1].toARGB32());
    expect(drawn.width, 25);
    expect(drawn.tool, InfiniteInkTool.highlighter);
    expect(
      identical(paintCounts(layer).layers.first, before.layers.first),
      isFalse,
      reason: 'painted again (alone, new layers) for the new stroke',
    );

    // the view moved (a wheel pan): painted again too (final fix review
    // Minor 1)
    final unmoved = paintCounts(layer);
    final offset = key.currentState!.viewport.offset;
    final mouse = TestPointer(9, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(mouse.hover(tester.getCenter(surface)));
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, 40)));
    await tester.pump();
    expect(key.currentState!.viewport.offset, isNot(offset));
    expect(
      identical(paintCounts(layer).layers.first, unmoved.layers.first),
      isFalse,
      reason: 'painted again for the moved view',
    );
    await tester.pumpWidget(const SizedBox());
  });

  // Final review design call 3: the saving clock had the disabled look (35 %
  // from KitEditorToolbar's _BarButton, because 「저장 중」 is not enabled).
  testWidgets('the saving clock is white and whole, and takes no press', (
    tester,
  ) async {
    final write = Completer<void>();
    var saves = 0;
    await mount(
      tester,
      onSave: (_) {
        saves++;
        return write.future;
      },
    );
    final save = byKey('editor-canvas-save');
    KitIcon icon() => tester.widget<KitIcon>(
      find.descendant(of: save, matching: find.byType(KitIcon)),
    );
    double opacity() => tester
        .widget<Opacity>(
          find.ancestor(of: find.byWidget(icon()), matching: find.byType(Opacity))
              .first,
        )
        .opacity;
    final saved = icon();
    expect(saved.name, KitIconName.checkCircle);
    await draw(tester, [const Offset(100, 200), const Offset(160, 200)]);
    await tester.tap(save);
    await tester.pump();
    await tester.pump();
    expect(icon().name, KitIconName.clock);
    expect(opacity(), 1, reason: 'not dimmed');
    expect(icon().color, saved.color);
    expect(icon().size, saved.size);
    expect(icon().strokeWidth, saved.strokeWidth);
    // still not a button that works while it saves
    expect(
      tester.getSemantics(save).flagsCollection.isEnabled.toBoolOrNull(),
      isFalse,
    );
    await tester.tap(save);
    await tester.pump();
    expect(saves, 1);
    write.complete();
    await tester.pump();
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
  });

  // Final review design call 5: 원점으로 had the tab row's home; it is a
  // crosshair of its own now.
  testWidgets('원점으로 shows the origin crosshair, not the home', (
    tester,
  ) async {
    await mount(tester);
    final icon = tester.widget<KitIcon>(
      find.descendant(
        of: byKey('editor-canvas-origin'),
        matching: find.byType(KitIcon),
      ),
    );
    expect(icon.name.id, 'origin');
    expect(icon.name.label, '원점으로');
    // a small ring in the middle and four ticks, no outer ring
    expect(icon.name.svg, contains('<circle cx="12" cy="12" r="3.4"/>'));
    expect(RegExp('<circle').allMatches(icon.name.svg), hasLength(1));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'failed save keeps ink dirty and retry persists the same document',
    (tester) async {
      var fail = true;
      final dirty = <bool>[];
      final key = await mount(
        tester,
        onDirty: dirty.add,
        onSave: (_) async {
          if (fail) throw StateError('disk full');
        },
      );
      await draw(tester, [const Offset(100, 100), const Offset(120, 120)]);
      await expectLater(key.currentState!.save(), throwsStateError);
      await tester.pump();
      expect(find.text('저장하지 못했습니다. 다시 시도하세요.'), findsOneWidget);
      expect(key.currentState!.document.strokes, hasLength(1));
      expect(dirty, [true]);
      fail = false;
      await tester.tap(byKey('infinite-retry-save'));
      await tester.pumpAndSettle();
      expect(dirty, [true, false]);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('undo redo and eraser preserve explicit document history', (
    tester,
  ) async {
    final key = await mount(tester);
    await draw(tester, [const Offset(100, 100), const Offset(160, 100)]);
    await tester.tap(byKey('floating-bar-undo'));
    await tester.pump();
    expect(key.currentState!.document.strokes, isEmpty);
    await tester.tap(byKey('floating-bar-redo'));
    await tester.pump();
    expect(key.currentState!.document.strokes, hasLength(1));
    await press(tester, byKey('editor-tool-eraser'));
    await draw(tester, [const Offset(130, 100)]);
    expect(key.currentState!.document.strokes, isEmpty);
    await tester.tap(byKey('floating-bar-undo'));
    await tester.pump();
    expect(key.currentState!.document.strokes, hasLength(1));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('lasso selects and translates world strokes with undo', (
    tester,
  ) async {
    final key = await mount(
      tester,
      initial: InfiniteDocument(strokes: [stroke(x: 100, y: 100)]),
    );
    await press(tester, byKey('editor-tool-lasso'));
    await draw(tester, [
      const Offset(80, 80),
      const Offset(150, 80),
      const Offset(150, 140),
      const Offset(80, 140),
      const Offset(80, 80),
    ]);
    await draw(tester, [const Offset(110, 105), const Offset(160, 135)]);
    expect(
      key.currentState!.document.strokes.single.points.first.offset,
      const Offset(150, 130),
    );
    final context = tester.element(find.byType(KitEditorToolbar));
    actionsOf(tester).run(AppActionIds.undo, context);
    await tester.pump();
    expect(
      key.currentState!.document.strokes.single.points.first.offset,
      const Offset(100, 100),
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'touch pans infinitely and makes no ink with finger writing off',
    (tester) async {
      final key = await mount(tester);
      final origin = tester.getTopLeft(surface);
      final gesture = await tester.createGesture(
        kind: PointerDeviceKind.touch,
        pointer: 3,
      );
      await gesture.down(origin + const Offset(50, 150));
      await gesture.moveTo(origin + const Offset(350, 250));
      await gesture.up();
      expect(key.currentState!.document.strokes, isEmpty);
      expect(
        key.currentState!.viewport.screenToWorld(Offset.zero).dx,
        lessThan(0),
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('save serializes pending changes before completing', (
    tester,
  ) async {
    final writes = <InfiniteDocument>[];
    final firstWrite = Completer<void>();
    final key = await mount(
      tester,
      onSave: (doc) async {
        writes.add(doc);
        if (writes.length == 1) await firstWrite.future;
      },
    );
    await draw(tester, [const Offset(40, 140), const Offset(60, 160)]);
    final saving = key.currentState!.save();
    await tester.pump();
    await draw(tester, [
      const Offset(100, 200),
      const Offset(130, 240),
    ], pointer: 2);
    firstWrite.complete();
    await saving;
    expect(writes.map((doc) => doc.strokes.length), [1, 2]);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'pointer cancellation retains the valid ink received before interruption',
    (tester) async {
      final key = await mount(tester);
      final origin = tester.getTopLeft(surface);
      final gesture = await tester.createGesture(
        kind: PointerDeviceKind.stylus,
        pointer: 7,
      );
      await gesture.down(origin + const Offset(50, 150));
      await gesture.moveTo(origin + const Offset(75, 180));
      await gesture.cancel();
      await tester.pump();
      expect(
        key.currentState!.document.strokes.single.points.last.offset,
        const Offset(75, 180),
      );
      await key.currentState!.save();
      await tester.pumpWidget(const SizedBox());
    },
  );

  final zoomBadge = byKey('zoom-badge-pill');

  Future<void> ctrlScroll(WidgetTester tester, double dy) async {
    final center = tester.getCenter(surface);
    final mouse = TestPointer(9, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(mouse.hover(center));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendEventToBinding(mouse.scroll(Offset(0, dy)));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
  }

  testWidgets(
    'the zoom pill is the kit zoom badge and shows only when the scale changes',
    (tester) async {
      final key = await mount(tester);
      expect(find.byType(KitZoomBadge), findsOneWidget);
      expect(shownOf(tester, zoomBadge), 0);
      final center = tester.getCenter(surface);
      final mouse = TestPointer(8, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(mouse.hover(center));
      await tester.sendEventToBinding(mouse.scroll(const Offset(0, 40)));
      await tester.pumpAndSettle();
      expect(shownOf(tester, zoomBadge), 0, reason: 'a pan keeps the scale');
      await ctrlScroll(tester, -60);
      await tester.pump(const Duration(milliseconds: 300));
      expect(shownOf(tester, zoomBadge), 1);
      final scaled = key.currentState!.viewport.scale;
      expect(find.text('${(scaled * 100).round()}%'), findsOneWidget);
      // a press goes back to 100 %
      await tester.tap(zoomBadge);
      await tester.pump();
      expect(key.currentState!.viewport.scale, closeTo(1, 1e-9));
      await tester.pump(KitMotion.zoomBadgeHide);
      await tester.pumpAndSettle();
      expect(shownOf(tester, zoomBadge), 0);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
