import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/canvas/hud/canvas_hud.dart';
import 'package:saber/i18n/strings.g.dart';

void main() {
  Widget hud(TransformationController controller) => TranslationProvider(
    child: MaterialApp(
      home: Scaffold(
        body: CanvasHud(
          transformationController: controller,
          zoomLock: false,
          setZoomLock: (_) {},
          setScale: (_) {},
        ),
      ),
    ),
  );

  double opacity(WidgetTester tester) => tester
      .widget<AnimatedOpacity>(find.byKey(const ValueKey('zoom-pill')))
      .opacity;

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

  testWidgets('HUD hides two seconds after its most recent zoom', (
    tester,
  ) async {
    final controller = TransformationController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(hud(controller));
    controller.value = Matrix4.diagonal3Values(2, 2, 1);
    await tester.pump(const Duration(milliseconds: 1500));
    controller.value = Matrix4.diagonal3Values(3, 3, 1);
    await tester.pump(const Duration(milliseconds: 1500));
    expect(opacity(tester), 1);
    await tester.pump(const Duration(milliseconds: 600));
    expect(opacity(tester), 0);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
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
              zoomLock: false,
              setZoomLock: (_) {},
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
    expect(opacity(tester), 1);
    await tester.pumpWidget(const SizedBox());
  });
}
