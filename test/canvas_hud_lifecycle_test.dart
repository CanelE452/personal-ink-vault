import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/canvas/hud/canvas_hud.dart';
import 'package:saber/i18n/strings.g.dart';

void main() {
  Widget hud(TransformationController controller) => TranslationProvider(
    child: MaterialApp(
      home: Scaffold(
        body: CanvasHud(transformationController: controller, setScale: (_) {}),
      ),
    ),
  );

  /// How much of the zoom badge shows (0 once it is gone).
  double opacity(WidgetTester tester) {
    final fades = find.descendant(
      of: find.byKey(const ValueKey('zoom-badge')),
      matching: find.byType(FadeTransition),
    );
    if (fades.evaluate().isEmpty) return 0;
    return tester.widget<FadeTransition>(fades.first).opacity.value;
  }

  testWidgets(
    'unmount cancels the latest HUD timer after transforms without rebuilding',
    (tester) async {
      final controller = TransformationController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(hud(controller));
      controller.value = Matrix4.diagonal3Values(2, 2, 1);
      await tester.pump();
      controller.value = Matrix4.diagonal3Values(3, 3, 1);
      controller.value = Matrix4.diagonal3Values(4, 4, 1);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('HUD hides a second after its most recent zoom', (tester) async {
    final controller = TransformationController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(hud(controller));
    controller.value = Matrix4.diagonal3Values(2, 2, 1);
    await tester.pump(const Duration(milliseconds: 700));
    controller.value = Matrix4.diagonal3Values(3, 3, 1);
    await tester.pump(const Duration(milliseconds: 700));
    expect(opacity(tester), 1);
    await tester.pump(const Duration(milliseconds: 301));
    await tester.pump(const Duration(milliseconds: 106));
    await tester.pump();
    expect(opacity(tester), 0);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('a press on the badge goes back to 100% over 250 ms', (
    tester,
  ) async {
    final controller = TransformationController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: CanvasHud(
              transformationController: controller,
              setScale: (s) => controller.value = Matrix4.diagonal3Values(s, s, 1),
            ),
          ),
        ),
      ),
    );
    double scale() => controller.value.getMaxScaleOnAxis();
    controller.value = Matrix4.diagonal3Values(2, 2, 1);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    await tester.tap(find.byKey(const ValueKey('zoom-badge-pill')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 125));
    // `1 - (1 - k)^3` at half the time: 87.5 % of the way
    expect(scale(), moreOrLessEquals(2 - 0.875, epsilon: 0.01));
    await tester.pump(const Duration(milliseconds: 126));
    expect(scale(), 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('scrolling without zooming keeps the HUD hidden', (tester) async {
    final controller = TransformationController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(hud(controller));
    controller.value = Matrix4.translationValues(0, -300, 0);
    await tester.pump();
    expect(opacity(tester), 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('zooms the app makes by itself keep the pill hidden', (
    tester,
  ) async {
    final controller = TransformationController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: CanvasHud(
              transformationController: controller,
              setScale: (_) {},
              shouldShow: () => false,
            ),
          ),
        ),
      ),
    );
    controller.value = Matrix4.diagonal3Values(1.5, 1.5, 1);
    await tester.pump();
    expect(opacity(tester), 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a small scale drift from a two-finger pan keeps the pill hidden', (
    tester,
  ) async {
    final controller = TransformationController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(hud(controller));
    controller.value = Matrix4.diagonal3Values(1.01, 1.01, 1);
    await tester.pump();
    expect(opacity(tester), 0);
    controller.value = Matrix4.diagonal3Values(1.2, 1.2, 1);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(opacity(tester), 1);
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
  });

  // Moved with ControllerScale from the deleted zoom pill (Task 19).
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
}
