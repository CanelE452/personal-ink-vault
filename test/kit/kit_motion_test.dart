import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/kit/kit_motion.dart';

void main() {
  test('open durations sit inside the spec ranges', () {
    expect(KitMotion.open(KitMotionStep.instant), Duration.zero);
    expect(
      KitMotion.open(KitMotionStep.fast),
      const Duration(milliseconds: 120),
    );
    expect(
      KitMotion.open(KitMotionStep.normal),
      const Duration(milliseconds: 220),
    );
    expect(
      KitMotion.open(KitMotionStep.slow),
      const Duration(milliseconds: 320),
    );
  });

  test('close is 70% of open', () {
    expect(
      KitMotion.close(KitMotionStep.normal),
      const Duration(milliseconds: 154),
    );
    expect(
      KitMotion.close(KitMotionStep.fast),
      const Duration(milliseconds: 84),
    );
    expect(
      KitMotion.close(KitMotionStep.slow),
      const Duration(milliseconds: 224),
    );
    expect(KitMotion.close(KitMotionStep.instant), Duration.zero);
  });

  test('a held bar let go swallows taps for 80 ms', () {
    // preview v8k line 2532: the tap the release makes is swallowed
    expect(KitMotion.barDropTapSwallow, const Duration(milliseconds: 80));
  });

  test('open and close curves', () {
    expect(KitMotion.openCurve, Curves.easeOutCubic);
    expect(KitMotion.closeCurve, Curves.easeInCubic);
  });

  test('Samsung pen-panel motion uses the measured values', () {
    expect(KitMotion.samsungDecel, const Cubic(0.22, 0.32, 0.02, 1.0));
    expect(KitMotion.sliderJump, const Duration(milliseconds: 410));
    expect(KitMotion.sliderGrow, const Duration(milliseconds: 450));
    expect(KitMotion.sliderShrink, const Duration(milliseconds: 280));
    expect(KitMotion.sliderValueBack, const Duration(milliseconds: 130));
    expect(KitMotion.sliderValueIn, const Duration(milliseconds: 35));
    expect(KitMotion.penRise, const Duration(milliseconds: 290));
    expect(KitMotion.penSampleOut, const Duration(milliseconds: 70));
    expect(KitMotion.penSampleDelay, const Duration(milliseconds: 365));
    expect(KitMotion.penSampleDraw, const Duration(milliseconds: 250));
  });

  testWidgets('disableAnimations makes every step instant', (tester) async {
    late BuildContext context;
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: Builder(
          builder: (c) {
            context = c;
            return const SizedBox();
          },
        ),
      ),
    );
    for (final step in KitMotionStep.values) {
      expect(KitMotion.of(context, step), Duration.zero);
      expect(KitMotion.of(context, step, closing: true), Duration.zero);
    }
  });

  testWidgets('animations on: of() gives the open or close duration', (
    tester,
  ) async {
    late BuildContext context;
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(),
        child: Builder(
          builder: (c) {
            context = c;
            return const SizedBox();
          },
        ),
      ),
    );
    expect(
      KitMotion.of(context, KitMotionStep.slow),
      const Duration(milliseconds: 320),
    );
    expect(
      KitMotion.of(context, KitMotionStep.normal, closing: true),
      const Duration(milliseconds: 154),
    );
  });

  test('a note in the pen panel stays for the preview zoomHide', () {
    expect(KitMotion.noteShow, const Duration(milliseconds: 1000));
  });

  test('save chip and zoom badge times (values §7-5, §8, §12-3 I)', () {
    expect(KitMotion.saveChipDelay, const Duration(milliseconds: 1000));
    expect(KitMotion.zoomBadgeHide, const Duration(milliseconds: 1000));
    expect(KitMotion.saveChipOpen, const Duration(milliseconds: 180));
    expect(KitMotion.saveChipClose, const Duration(milliseconds: 126));
    expect(KitMotion.saveChipSpin, const Duration(milliseconds: 800));
    expect(KitMotion.zoomBadgeOpen, const Duration(milliseconds: 150));
    expect(KitMotion.zoomBadgeClose, const Duration(milliseconds: 105));
    expect(KitMotion.zoomBadgeReset, const Duration(milliseconds: 250));
  });

  test('the floating bar grows and hides while writing (§13-3, §14-4)', () {
    expect(KitMotion.floatingBarGrow, const Duration(milliseconds: 200));
    expect(KitMotion.floatingBarGrowFrom, 0.92);
    expect(KitMotion.floatingBarHide, const Duration(milliseconds: 120));
    expect(KitMotion.floatingBarShow, const Duration(milliseconds: 200));
    expect(KitMotion.floatingBarHideWait, const Duration(milliseconds: 600));
    // the preview's `M` table: fast and normal
    expect(KitMotion.fastCurve, const Cubic(0.2, 0, 0, 1));
    expect(KitMotion.normalCurve, const Cubic(0, 0, 0, 1));
  });

  test('the mode pill shows two seconds (§14-4)', () {
    expect(KitMotion.modePillShow, const Duration(milliseconds: 2000));
    expect(KitMotion.modePillOpen, const Duration(milliseconds: 150));
    expect(KitMotion.modePillClose, const Duration(milliseconds: 105));
  });
}
