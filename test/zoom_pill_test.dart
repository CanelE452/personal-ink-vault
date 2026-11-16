import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/canvas/hud/zoom_pill.dart';

void main() {
  double pillOpacity(WidgetTester tester) => tester
      .widget<AnimatedOpacity>(find.byKey(const ValueKey('zoom-pill')))
      .opacity;

  Future<ValueNotifier<double>> mount(
    WidgetTester tester, {
    ValueChanged<double>? onSelectScale,
    bool? zoomLocked,
    ValueChanged<bool>? onZoomLockChanged,
  }) async {
    final scale = ValueNotifier<double>(1);
    addTearDown(scale.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ZoomPillOverlay(
            scale: scale,
            onSelectScale: onSelectScale,
            zoomLocked: zoomLocked,
            onZoomLockChanged: onZoomLockChanged,
          ),
        ),
      ),
    );
    return scale;
  }

  testWidgets(
    'zoom pill appears when the scale changes and hides two seconds later',
    (tester) async {
      final scale = await mount(tester, onSelectScale: (_) {});
      expect(pillOpacity(tester), 0);
      scale.value = 1.5;
      await tester.pump();
      expect(pillOpacity(tester), 1);
      expect(find.text('150%'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 1900));
      expect(pillOpacity(tester), 1);
      await tester.pump(const Duration(milliseconds: 200));
      expect(pillOpacity(tester), 0);
    },
  );

  test('controller scale ignores pans and reports zooms', () {
    final controller = TransformationController();
    final scale = ControllerScale(controller);
    var notified = 0;
    scale.addListener(() => notified++);
    controller.value = Matrix4.translationValues(40, -30, 0);
    expect(notified, 0);
    controller.value = Matrix4.diagonal3Values(2, 2, 1);
    expect(notified, 1);
    expect(scale.value, 2);
    scale.dispose();
    controller.dispose();
  });

  testWidgets('choosing 200% reports scale 2', (tester) async {
    double? chosen;
    final scale = await mount(tester, onSelectScale: (value) => chosen = value);
    scale.value = 1.25;
    await tester.pump();
    await tester.tap(find.text('125%'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('200%').last);
    await tester.pumpAndSettle();
    expect(chosen, 2);
  });

  testWidgets('lock disables the scale list', (tester) async {
    bool? locked;
    final scale = await mount(
      tester,
      zoomLocked: true,
      onZoomLockChanged: (value) => locked = value,
    );
    scale.value = 1.25;
    await tester.pump();
    await tester.tap(find.text('125%'));
    await tester.pumpAndSettle();
    expect(find.text('200%'), findsNothing);
    await tester.tap(find.byTooltip('확대 잠금 풀기'));
    expect(locked, isFalse);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('touching the pill keeps it past two seconds', (tester) async {
    final scale = await mount(tester, onSelectScale: (_) {});
    scale.value = 1.5;
    await tester.pump();
    final pill = find.descendant(
      of: find.byKey(const ValueKey('zoom-pill')),
      matching: find.byType(Material),
    );
    final gesture = await tester.startGesture(
      tester.getTopLeft(pill.first) + Offset(4, tester.getSize(pill.first).height / 2),
    );
    await tester.pump(const Duration(seconds: 3));
    expect(pillOpacity(tester), 1);
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 2100));
    expect(pillOpacity(tester), 0);
  });
}
