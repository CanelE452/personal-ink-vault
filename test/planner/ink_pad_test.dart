import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/planner/planner_models.dart';
import 'package:saber/pages/planner/ink_pad.dart';

void main() {
  const padKey = ValueKey('pad');
  late List<InkStroke> strokes;
  late ScrollController scroll;

  /// A 400×200 pad at the top of a long list; [strokes] follows every change
  /// the pad reports.
  Future<void> mount(
    WidgetTester tester, {
    List<InkStroke> initial = const [],
    bool erasing = false,
    bool enabled = true,
  }) async {
    strokes = initial;
    scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            controller: scroll,
            children: [
              Center(
                child: SizedBox(
                  width: 400,
                  height: 200,
                  child: StatefulBuilder(
                    builder: (context, setState) => InkPad(
                      key: padKey,
                      strokes: strokes,
                      erasing: erasing,
                      enabled: enabled,
                      onChanged: (next) => setState(() => strokes = next),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 2000),
            ],
          ),
        ),
      ),
    );
  }

  Matcher pointsNear(List<double> expected) =>
      orderedEquals([for (final value in expected) closeTo(value, 1e-4)]);

  testWidgets(
    'a drag draws one stroke in 0..1 of the pad and does not scroll',
    (tester) async {
      await mount(tester);
      final origin = tester.getTopLeft(find.byKey(padKey));
      // Upwards: a list that took the drag would scroll.
      final gesture = await tester.startGesture(origin + const Offset(40, 150));
      await gesture.moveTo(origin + const Offset(200, 100));
      await gesture.moveTo(origin + const Offset(360, 50));
      await gesture.up();
      await tester.pump();

      expect(scroll.offset, 0);
      final stroke = strokes.single;
      expect(stroke.points, pointsNear([0.1, 0.75, 0.5, 0.5, 0.9, 0.25]));
      expect(stroke.color, 0xFF202124);
      expect(stroke.width, 0.006);
      // The store stamps the id and the time when it writes the stroke.
      expect(stroke.id, isEmpty);
      expect(stroke.changedAt, 0);
    },
  );

  testWidgets('the eraser removes the stroke it touches and keeps the rest', (
    tester,
  ) async {
    const top = InkStroke(
      points: [0.1, 0.25, 0.9, 0.25],
      color: 0xFF000000,
      width: 0.01,
    );
    const bottom = InkStroke(
      points: [0.1, 0.75, 0.9, 0.75],
      color: 0xFF000000,
      width: 0.01,
    );
    await mount(tester, initial: const [top, bottom], erasing: true);
    final origin = tester.getTopLeft(find.byKey(padKey));
    // Crosses the top stroke (y = 50) and stays far from the bottom one.
    final gesture = await tester.startGesture(origin + const Offset(200, 20));
    await gesture.moveTo(origin + const Offset(200, 80));
    await gesture.up();
    await tester.pump();

    expect(strokes, [bottom]);
  });

  testWidgets('a pen landing while a finger draws takes over the stroke', (
    tester,
  ) async {
    await mount(tester);
    final origin = tester.getTopLeft(find.byKey(padKey));
    final palm = await tester.startGesture(
      origin + const Offset(20, 20),
      pointer: 1,
    );
    await palm.moveTo(origin + const Offset(60, 60));
    final pen = await tester.startGesture(
      origin + const Offset(100, 100),
      pointer: 2,
      kind: PointerDeviceKind.stylus,
    );
    await pen.moveTo(origin + const Offset(300, 100));
    await pen.up();
    await palm.moveTo(origin + const Offset(80, 80));
    await palm.up();
    await tester.pump();

    expect(strokes.single.points, pointsNear([0.25, 0.5, 0.75, 0.5]));
  });

  testWidgets(
    'switching the pad off mid-stroke drops that stroke and frees it',
    (tester) async {
      strokes = const [];
      final enabled = ValueNotifier(true);
      addTearDown(enabled.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 400,
              height: 200,
              child: ValueListenableBuilder<bool>(
                valueListenable: enabled,
                builder: (context, on, _) => StatefulBuilder(
                  builder: (context, setState) => InkPad(
                    key: padKey,
                    strokes: strokes,
                    enabled: on,
                    onChanged: (next) => setState(() => strokes = next),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final origin = tester.getTopLeft(find.byKey(padKey));
      // A finger (or a resting palm) is drawing when the pad is switched off
      // and on again, as the calendar does when its mode changes.
      final palm = await tester.startGesture(
        origin + const Offset(20, 20),
        pointer: 1,
      );
      await palm.moveTo(origin + const Offset(60, 60));
      enabled.value = false;
      await tester.pump();
      enabled.value = true;
      await tester.pump();
      final finger = await tester.startGesture(
        origin + const Offset(100, 100),
        pointer: 2,
      );
      await finger.moveTo(origin + const Offset(300, 100));
      await finger.up();
      await palm.moveTo(origin + const Offset(80, 80));
      await palm.up();
      await tester.pump();

      expect(strokes.single.points, pointsNear([0.25, 0.5, 0.75, 0.5]));
    },
  );

  testWidgets('a disabled pad shows its strokes and lets touches through', (
    tester,
  ) async {
    const line = InkStroke(
      points: [0.1, 0.5, 0.9, 0.5],
      color: 0xFF000000,
      width: 0.01,
    );
    await mount(tester, initial: const [line], enabled: false);
    await tester.dragFrom(
      tester.getCenter(find.byKey(padKey)),
      const Offset(100, -80),
    );
    await tester.pump();

    expect(strokes, [line]);
    expect(scroll.offset, greaterThan(0));
  });
}
