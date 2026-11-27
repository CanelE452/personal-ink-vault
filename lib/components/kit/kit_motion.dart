import 'package:flutter/widgets.dart';

/// Motion steps from the design doc: instant, fast, normal, slow.
enum KitMotionStep { instant, fast, normal, slow }

abstract final class KitMotion {
  /// Opening time. Values inside the design ranges, fixed by the plan.
  static Duration open(KitMotionStep s) => switch (s) {
    KitMotionStep.instant => Duration.zero,
    KitMotionStep.fast => const Duration(milliseconds: 120),
    KitMotionStep.normal => const Duration(milliseconds: 220),
    KitMotionStep.slow => const Duration(milliseconds: 320),
  };

  /// Closing time: 70% of opening, rounded to whole milliseconds.
  static Duration close(KitMotionStep s) =>
      Duration(milliseconds: (open(s).inMilliseconds * 0.7).round());

  /// Zero when the system asks for no animations.
  static Duration of(
    BuildContext context,
    KitMotionStep s, {
    bool closing = false,
  }) {
    if (MediaQuery.disableAnimationsOf(context)) return Duration.zero;
    return closing ? close(s) : open(s);
  }

  static const Curve openCurve = Curves.easeOutCubic;
  static const Curve closeCurve = Curves.easeInCubic;

  // Samsung pen panel (design doc "삼성 기준 움직임", stage 1 only)
  static const Curve samsungDecel = Cubic(0.22, 0.32, 0.02, 1.0);
  static const sliderJump = Duration(milliseconds: 410);
  static const sliderGrow = Duration(milliseconds: 450);
  static const sliderShrink = Duration(milliseconds: 280);
  static const sliderValueBack = Duration(milliseconds: 130);
  // Fade of the number at the end of sliderValueBack (preview `sliderValueIn`,
  // line 1521 of the preview file).
  static const sliderValueIn = Duration(milliseconds: 35);
  static const penRise = Duration(milliseconds: 290);
  static const penSampleOut = Duration(milliseconds: 70);
  static const penSampleDelay = Duration(milliseconds: 365);
  static const penSampleDraw = Duration(milliseconds: 250);
  // How long a note stays in the colour row's page-name place (preview
  // `cpNote` with `KM.zoomHide`, line 1547).
  static const noteShow = Duration(milliseconds: 1000);
  // A held floating bar let go swallows the taps on it this long: the tap
  // the release makes (preview-v8k line 2532).
  static const barDropTapSwallow = Duration(milliseconds: 80);

  // The preview's `M` table (line 3127): the fast and the normal curve.
  static const Curve fastCurve = Cubic(0.2, 0, 0, 1);
  static const Curve normalCurve = Cubic(0, 0, 0, 1);

  // The save chip (task-13B-values.md §7-5, §12-3 I): a save shows after it
  // has taken this long, and a waiting one this long after the change when
  // auto save is off; it opens in 180 and closes in 126 (70 %) on
  // [samsungDecel]; its mark turns once in 800.
  static const saveChipDelay = Duration(milliseconds: 1000);
  static const saveChipOpen = Duration(milliseconds: 180);
  static const saveChipClose = Duration(milliseconds: 126);
  static const saveChipSpin = Duration(milliseconds: 800);

  // The zoom badge (§8, §12-3 I): it hides this long after the fingers lift,
  // opening in 150 and closing in 105; pressed, it goes back to 100 % in
  // [zoomBadgeReset] (the preview's `KM.zoomReset`, line 3168).
  static const zoomBadgeHide = Duration(milliseconds: 1000);
  static const zoomBadgeReset = Duration(milliseconds: 250);
  static const zoomBadgeOpen = Duration(milliseconds: 150);
  static const zoomBadgeClose = Duration(milliseconds: 105);

  // The floating bar grows from the toolbar button that shows it and goes
  // back into it (§14-4): from this size and clear, both ways in this time
  // on [samsungDecel].
  static const floatingBarGrow = Duration(milliseconds: 200);
  static const floatingBarGrowFrom = 0.92;

  // A stroke under the floating bar (§13-3): it fades out on [fastCurve],
  // and this long after the pen is lifted fades in on [normalCurve].
  static const floatingBarHide = Duration(milliseconds: 120);
  static const floatingBarShow = Duration(milliseconds: 200);
  static const floatingBarHideWait = Duration(milliseconds: 600);

  // 「필기 모드」/「제스처 모드」 (§14-4): shown this long, opening and
  // closing as the zoom badge.
  static const modePillShow = Duration(milliseconds: 2000);
  static const modePillOpen = Duration(milliseconds: 150);
  static const modePillClose = Duration(milliseconds: 105);

  // The left panel slides in over 160 on [samsungDecel] (`.r1side.show`);
  // the recording dot blinks in 1200 (`r1blink`, two steps).
  static const sidePanelSlide = Duration(milliseconds: 160);
  static const recBlink = Duration(milliseconds: 1200);

  // The quick note rises into place over 160 on [samsungDecel] as it opens
  // (the 9th draft c note window's rise; the 12th draft shows no motion).
  static const quickNoteRise = Duration(milliseconds: 160);

  // The undo notice (`makeToast`, `.r1toast`): it stays 4000 with an action,
  // 2000 without; it comes in 150 and goes in 105 (its fade linear, its
  // rise on [samsungDecel]).
  static const undoNoticeShow = Duration(milliseconds: 4000);
  static const undoNoticeShowSolo = Duration(milliseconds: 2000);
  static const undoNoticeIn = Duration(milliseconds: 150);
  static const undoNoticeOut = Duration(milliseconds: 105);
}
