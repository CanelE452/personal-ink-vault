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
          resetZoom: () {},
          singleFingerPanLock: false,
          setSingleFingerPanLock: (_) {},
          axisAlignedPanLock: false,
          setAxisAlignedPanLock: (_) {},
        ),
      ),
    ),
  );

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

  testWidgets('HUD hides five seconds after its most recent transform', (
    tester,
  ) async {
    final controller = TransformationController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(hud(controller));
    controller.value = Matrix4.diagonal3Values(2, 2, 1);
    await tester.pump(const Duration(seconds: 4));
    controller.value = Matrix4.diagonal3Values(3, 3, 1);
    await tester.pump(const Duration(seconds: 4));
    expect(
      tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
      1,
    );
    await tester.pump(const Duration(seconds: 1));
    expect(
      tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
      0,
    );
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });
}
