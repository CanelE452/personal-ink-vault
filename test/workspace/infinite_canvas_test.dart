import 'dart:async';
import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/vault/infinite_document.dart';
import 'package:saber/pages/workspace/infinite_canvas.dart';

InfiniteStroke stroke({
  String id = 'stroke-1',
  double x = -1000000,
  double y = -50,
}) => InfiniteStroke(
  id: id,
  tool: InfiniteInkTool.pen,
  color: 0xff112233,
  width: 3,
  points: [
    InfinitePoint(x, y, pressure: .4),
    InfinitePoint(x + 20, y + 10, pressure: .9),
  ],
);

void main() {
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

  Future<GlobalKey<InfiniteCanvasState>> mount(
    WidgetTester tester, {
    InfiniteDocument initial = const InfiniteDocument.empty(),
    Future<void> Function(InfiniteDocument)? onSave,
    ValueChanged<bool>? onDirty,
    ValueChanged<bool>? onBusy,
    InfiniteViewport initialViewport = const InfiniteViewport(),
    Future<void> Function(InfiniteViewport)? onSaveViewport,
  }) async {
    final key = GlobalKey<InfiniteCanvasState>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InfiniteCanvas(
            key: key,
            initialDocument: initial,
            onSave: onSave ?? (_) async {},
            initialViewport: initialViewport,
            onSaveViewport: onSaveViewport,
            onDirtyChanged: onDirty,
            onBusyChanged: onBusy,
            onBack: () {},
            autosaveDelay: const Duration(hours: 1),
          ),
        ),
      ),
    );
    return key;
  }

  Future<void> draw(
    WidgetTester tester,
    List<Offset> localPoints, {
    int pointer = 1,
  }) async {
    final origin = tester.getTopLeft(
      find.byKey(const ValueKey('infinite-surface')),
    );
    final gesture = await tester.createGesture(
      kind: PointerDeviceKind.stylus,
      pointer: pointer,
    );
    await gesture.down(origin + localPoints.first);
    for (final point in localPoints.skip(1)) {
      await gesture.moveTo(origin + point);
    }
    await gesture.up();
    await tester.pump();
  }

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
    await tester.tap(find.byTooltip('확대'));
    await tester.pump();
    await key.currentState!.save();
    expect(saved!.scale, 2.5);
    expect(saved!.offset.dx, -1250000);
    await tester.pumpWidget(const SizedBox());
    final reopened = await mount(tester, initialViewport: saved!);
    expect(reopened.currentState!.viewport.offset, saved!.offset);
    expect(reopened.currentState!.viewport.scale, saved!.scale);
    expect(reopened.currentState!.document.strokes, isEmpty);
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
    Finder width(int index) => find.byKey(ValueKey('ink-width-preset-$index'));
    await tester.tap(width(0));
    await tester.pump();
    await draw(tester, [const Offset(40, 60), const Offset(90, 60)]);
    await tester.tap(find.byKey(const ValueKey('infinite-tool-highlighter')));
    await tester.pump();
    await draw(tester, [const Offset(40, 90), const Offset(90, 90)]);
    await tester.tap(width(2));
    await tester.pump();

    final origin = tester.getTopLeft(
      find.byKey(const ValueKey('infinite-surface')),
    );
    final gesture = await tester.createGesture(
      kind: PointerDeviceKind.stylus,
      pointer: 17,
    );
    await gesture.down(origin + const Offset(40, 120));
    await tester.pump();
    expect(tester.widget<IconButton>(width(1)).onPressed, isNull);
    await tester.tap(width(1), warnIfMissed: false);
    await gesture.moveTo(origin + const Offset(90, 120));
    await tester.pump();
    final canvas = tester.widget<CustomPaint>(
      find.descendant(
        of: find.byKey(const ValueKey('infinite-surface')),
        matching: find.byType(CustomPaint),
      ),
    );
    expect(
      (Canvas target) => canvas.painter!.paint(target, const Size(800, 500)),
      paints
        ..path(strokeWidth: 5)
        ..path(strokeWidth: 25),
    );
    await gesture.up();
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('infinite-tool-pen')));
    await tester.pump();
    await draw(tester, [const Offset(40, 150), const Offset(90, 150)]);
    await key.currentState!.save();
    final reopened = InfiniteDocument.fromJson(saved!.toJson()).strokes;
    expect(reopened.map((stroke) => stroke.width), [40, 1, 5, 25, 5]);
    expect(reopened.first.toJson(), old.toJson());
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('narrow canvas keeps the four legacy widths in reach', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final key = await mount(tester);
    expect(find.byKey(const ValueKey('ink-width-preset-0')), findsNothing);
    final widthMenu = find.byKey(const ValueKey('infinite-width-menu'));
    await tester.tap(widthMenu);
    await tester.pumpAndSettle();
    await tester.tap(find.text('8.0 px'));
    await tester.pumpAndSettle();
    await draw(tester, [const Offset(60, 90), const Offset(90, 90)]);
    await tester.tap(find.byKey(const ValueKey('infinite-tool-highlighter')));
    await tester.pump();
    expect(find.text('40.0 px'), findsOneWidget);
    await draw(tester, [const Offset(60, 150), const Offset(90, 150)]);
    expect(key.currentState!.document.strokes.map((stroke) => stroke.width), [
      8,
      40,
    ]);
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
      await tester.tap(find.byKey(const ValueKey('infinite-retry-save')));
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
    await tester.tap(find.byKey(const ValueKey('infinite-undo')));
    await tester.pump();
    expect(key.currentState!.document.strokes, isEmpty);
    await tester.tap(find.byKey(const ValueKey('infinite-redo')));
    await tester.pump();
    expect(key.currentState!.document.strokes, hasLength(1));
    await tester.tap(find.byKey(const ValueKey('infinite-tool-eraser')));
    await draw(tester, [const Offset(130, 100)]);
    expect(key.currentState!.document.strokes, isEmpty);
    await tester.tap(find.byKey(const ValueKey('infinite-undo')));
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
    await tester.tap(find.byKey(const ValueKey('infinite-tool-lasso')));
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
    await tester.tap(find.byKey(const ValueKey('infinite-undo')));
    await tester.pump();
    expect(
      key.currentState!.document.strokes.single.points.first.offset,
      const Offset(100, 100),
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('touch pans infinitely and does not make ink by default', (
    tester,
  ) async {
    final key = await mount(tester);
    final origin = tester.getTopLeft(
      find.byKey(const ValueKey('infinite-surface')),
    );
    final gesture = await tester.createGesture(
      kind: PointerDeviceKind.touch,
      pointer: 3,
    );
    await gesture.down(origin + const Offset(50, 50));
    await gesture.moveTo(origin + const Offset(350, 150));
    await gesture.up();
    expect(key.currentState!.document.strokes, isEmpty);
    expect(
      key.currentState!.viewport.screenToWorld(Offset.zero).dx,
      lessThan(0),
    );
    await tester.pumpWidget(const SizedBox());
  });

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
    await draw(tester, [const Offset(40, 40), const Offset(60, 60)]);
    final saving = key.currentState!.save();
    await tester.pump();
    await draw(tester, [
      const Offset(100, 100),
      const Offset(130, 140),
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
      final origin = tester.getTopLeft(
        find.byKey(const ValueKey('infinite-surface')),
      );
      final gesture = await tester.createGesture(
        kind: PointerDeviceKind.stylus,
        pointer: 7,
      );
      await gesture.down(origin + const Offset(50, 50));
      await gesture.moveTo(origin + const Offset(75, 80));
      await gesture.cancel();
      await tester.pump();
      expect(
        key.currentState!.document.strokes.single.points.last.offset,
        const Offset(75, 80),
      );
      await key.currentState!.save();
      await tester.pumpWidget(const SizedBox());
    },
  );
}
