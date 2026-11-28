import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/kit/kit_tokens.dart';

void main() {
  test('tokens match the design table', () {
    expect(KitTokens.toolbarHeight, 46);
    expect(KitTokens.penRowHeight, 112);
    expect(KitTokens.selectedFill, const Color(0xffb7e2ea));
    expect(KitTokens.sliderThumb, 28);
    expect(KitTokens.sliderHitHeight, 44);
  });

  test('icon sizes and screen lines follow the approved 7th draft', () {
    expect(KitTokens.toolbarIconSize, 26);
    expect(KitTokens.toolbarIconLine, 1.558);
    expect(KitTokens.toolbarIconStroke, closeTo(1.43815, 1e-4));
    expect(KitTokens.selBarIconSize, 26);
    expect(KitTokens.selBarIconLine, 2.1667);
    expect(KitTokens.selBarIconStroke, closeTo(2.00003, 1e-4));
    expect(KitTokens.menuIconSize, 22);
    expect(KitTokens.menuIconLine, 1.4875);
    expect(KitTokens.menuIconStroke, closeTo(1.62273, 1e-4));
    expect(KitTokens.menuValueIconSize, 18);
    expect(KitTokens.menuValueIconLine, 1.0625);
    expect(KitTokens.menuValueIconStroke, closeTo(1.41667, 1e-4));
    for (final (size, line, stroke) in [
      (
        KitTokens.toolbarIconSize,
        KitTokens.toolbarIconLine,
        KitTokens.toolbarIconStroke,
      ),
      (
        KitTokens.selBarIconSize,
        KitTokens.selBarIconLine,
        KitTokens.selBarIconStroke,
      ),
      (
        KitTokens.menuIconSize,
        KitTokens.menuIconLine,
        KitTokens.menuIconStroke,
      ),
      (
        KitTokens.menuValueIconSize,
        KitTokens.menuValueIconLine,
        KitTokens.menuValueIconStroke,
      ),
    ]) {
      expect(stroke, line * 24 / size);
    }
  });

  test(
    'swatch tool, slider stepper and dropdown mark follow the 7th draft',
    () {
      expect(KitTokens.penPanelIconSize, 22);
      expect(KitTokens.penPanelIconLine, 1.558);
      expect(KitTokens.penPanelIconStroke, closeTo(1.69964, 1e-4));
      expect(KitTokens.sliderStepperIconSize, 32);
      expect(KitTokens.sliderStepperIconLine, 1.558);
      expect(KitTokens.sliderStepperIconStroke, closeTo(1.1685, 1e-4));
      expect(KitTokens.sliderStepperIconStroke, 1.558 * 24 / 32);
      expect(KitTokens.sliderStepperLineLength, closeTo(17.0667, 1e-3));
      expect(KitTokens.toolbarDropdownWidth, 40);
      expect(KitTokens.toolbarDropdownMarkArm, 5);
      expect(KitTokens.toolbarDropdownMarkLine, 1.6);
      expect(KitTokens.toolbarDropdownMarkOpacity, 0.9);
    },
  );

  test('pen panel layout follows the approved 7th draft', () {
    // `.snp` (line 153): white, 1px line, padding 20 14 29
    expect(KitTokens.penPanelBg, const Color(0xffffffff));
    expect(KitTokens.penPanelBorderWidth, 1);
    expect(KitTokens.penPanelPadTop, 20);
    expect(KitTokens.penPanelPadH, 14);
    expect(KitTokens.penPanelPadBottom, 29);
    // `.hd` (line 154), the close button and its X (lines 156-157)
    expect(KitTokens.penPanelHeadHeight, 22);
    expect(KitTokens.penPanelHeadGap, 14);
    expect(KitTokens.penPanelHeadInk, const Color(0xff4a4f59));
    expect(KitTokens.penPanelCloseSize, 24);
    expect(KitTokens.penPanelCloseBg, const Color(0xfff2f2f2));
    expect(KitTokens.penPanelCloseInk, const Color(0xff2a2c31));
    expect(KitTokens.penPanelCloseIconSize, 24);
    expect(KitTokens.penPanelCloseIconLine, 1.558);
    expect(KitTokens.penPanelCloseIconStroke, 1.558 * 24 / 24);
    expect(KitTokens.penPanelIconStroke, 1.558 * 24 / 22);
    // the pen row (lines 158, 568-576)
    expect(KitTokens.penRowTop, 2);
    expect(KitTokens.penRowInset, 4);
    expect(KitTokens.penRowLine, 1);
    expect(KitTokens.penColumnWidth, 40);
    expect(KitTokens.penColumnGap, 9);
    expect(KitTokens.penColumnGapHighlighter, 58);
    expect(KitTokens.penRise, 13);
    expect(KitTokens.penArtTop, 40);
    expect(KitTokens.penArtWidth, 40);
    expect(KitTokens.penArtHeight, 167);
    expect(KitTokens.penSampleWidth, 54);
    expect(KitTokens.penSampleHeight, 31);
    expect(KitTokens.penSampleScale, 0.9);
    expect(KitTokens.penSampleTips['pen'], const Offset(24, .8));
    // 8th draft: the highlighter nibs are shorter (`SAMPLE_AT`, line 1995)
    expect(KitTokens.penSampleTips['hlchisel'], const Offset(19.52, 11.5));
    expect(KitTokens.penSampleTips['hlround'], const Offset(24, 10.3));
    expect(KitTokens.penMarkWidths['fountain'], 4.4);
    expect(KitTokens.penMarkWidths['hlchisel'], 10);
    // rows (lines 577-589)
    expect(KitTokens.penPanelRowsTop, 16);
    expect(KitTokens.penPanelRowHeight, 46);
    expect(KitTokens.penPanelColorsTop, 4);
    // colour row (lines 597-607)
    expect(KitTokens.swatchPageWidth, 218);
    expect(KitTokens.swatchLightEdge, const Color(0x33142032));
    expect(KitTokens.swatchPinBadge, 7);
    expect(KitTokens.swatchPinInk, const Color(0xff2a2c31));
    expect(KitTokens.pageDotHitWidth, 11);
    expect(KitTokens.pageDotHitHeight, 22);
    expect(KitTokens.pageNameSize, 11);
    expect(KitTokens.pageNameInset, 4);
  });

  test('fix round 1 values', () {
    // colour row 270 wide: eyedropper and palette 4 apart (design M-6)
    expect(KitTokens.swatchToolGap, 4);
    expect(
      KitTokens.swatchPageWidth + 2 * KitTokens.swatchToolGap + 2 * 22,
      270,
    );
    // pins on dark colours get a wider white ring (design M-4)
    expect(KitTokens.swatchPinRingDark, 2);
    expect(KitTokens.swatchDarkLuma, 80);
    // 44 to press, the look unchanged (code review M7)
    expect(KitTokens.pageDotHitZone, 44);
    expect(KitTokens.penPanelHeadHit, 44);
    // greys this close are one colour when the row opens (design I-3)
    expect(KitTokens.penColorSameGreyLuma, 33);
    expect(KitTokens.penColorSameGreyChroma, 8);
    // the sample strokes fit x 0-35, y 20-34 of their sheet (line 1999)
    expect(KitTokens.penSampleStrokeRight, 35);
    expect(KitTokens.penSampleStrokeTop, 20);
    // `.snp .tg` 12.5 px on the panel's 1.4 line
    expect(KitTokens.toggleLabelLineHeight, 1.4);
    // pen box title 12 px (design M-1)
    expect(KitTokens.penBoxTitleSize, 12);
  });

  test('pen panel colour pages are the preview CPAGES', () {
    expect(KitTokens.penPanelColorPages, const [
      [
        Color(0xffe5323e),
        Color(0xffffc83d),
        Color(0xfff7e43a),
        Color(0xff2ccfc4),
        Color(0xff2f9bf0),
        Color(0xff2f55d4),
        Color(0xff8a3ee6),
        Color(0xff1f2023),
      ],
      [
        Color(0xffffadad),
        Color(0xffffd6a5),
        Color(0xfffdffb6),
        Color(0xffcaffbf),
        Color(0xff9bf6ff),
        Color(0xffa0c4ff),
        Color(0xffbdb2ff),
        Color(0xffffc6ff),
      ],
      [
        Color(0xff000000),
        Color(0xff424242),
        Color(0xff9e9e9e),
        Color(0xffeeeeee),
        Color(0xffffffff),
      ],
    ]);
    // the greys are the old colour bar's (grey[800], grey, grey[200])
    expect(KitTokens.penPanelColorPages[2][1], Colors.grey[800]);
    expect(KitTokens.penPanelColorPages[2][2], Colors.grey.shade500);
    expect(KitTokens.penPanelColorPages[2][3], Colors.grey[200]);
  });

  test('selection bar pressed fill and submenu window', () {
    expect(KitTokens.selBarOnFill, const Color(0xffe3e3e7));
    expect(KitTokens.selectedFill, const Color(0xffb7e2ea));
    expect(KitTokens.subMenuRadius, 14);
    const menu = KitTokens.menuShadow;
    expect(menu, hasLength(2));
    expect(menu[0].color, const Color(0x73142032));
    expect(menu[0].offset, const Offset(0, 18));
    expect(menu[0].blurSigma, closeTo(20, 1e-9));
    expect(menu[0].spreadRadius, -18);
    expect(menu[1].color, const Color(0x0f142032));
    expect(menu[1].offset, Offset.zero);
    expect(menu[1].blurRadius, 0);
    expect(menu[1].spreadRadius, 1);
    const sub = KitTokens.subMenuShadow;
    expect(sub, hasLength(2));
    expect(sub[0].color, const Color(0x73142032));
    expect(sub[0].offset, const Offset(0, 14));
    expect(sub[0].blurSigma, closeTo(15, 1e-9));
    expect(sub[0].spreadRadius, -14);
    expect(sub[1].color, const Color(0x0f142032));
    expect(sub[1].offset, Offset.zero);
    expect(sub[1].blurRadius, 0);
    expect(sub[1].spreadRadius, 1);
  });

  test('toolbar and floating bar values', () {
    expect(KitTokens.toolbarBg, const Color(0xff2b4b8c));
    expect(KitTokens.toolbarButton, 34);
    expect(KitTokens.toolbarButtonRadius, 10);
    expect(KitTokens.toolbarDividerWidth, 1.0);
    expect(KitTokens.toolbarDividerHeight, 22.0);
    expect(KitTokens.toolbarDividerColor, const Color(0x47ffffff));
    expect(KitTokens.pillBg, const Color(0xfff2f2f4));
    expect(KitTokens.pillBorder, const Color(0xffe4e4e8));
    expect(KitTokens.pillRadius, 12);
    expect(KitTokens.pillButton, 32);
    expect(KitTokens.pillButtonRadius, 9);
    expect(KitTokens.disabledOpacity, 0.35);
    expect(KitTokens.colorDot, 22);
  });

  test('selection bar and menu values', () {
    expect(KitTokens.selBarBg, const Color(0xfff2f2f4));
    expect(KitTokens.selBarInk, const Color(0xff141416));
    expect(KitTokens.selBarRadius, 20);
    expect(KitTokens.selBarButton, 44);
    expect(KitTokens.selBarButtonRadius, 12);
    expect(KitTokens.selBarDivider, const Color(0xffd6d6db));
    expect(KitTokens.selBarDividerHeight, 28.0);
    expect(KitTokens.menuInk, const Color(0xff1b2231));
    expect(KitTokens.menuSub, const Color(0xff646c79));
    expect(KitTokens.menuLine, const Color(0xffeceef2));
    expect(KitTokens.menuBg, const Color(0xfff6f6f7));
    expect(KitTokens.danger, const Color(0xffc43a3a));
    expect(KitTokens.accent, const Color(0xff2f6ae0));
    expect(KitTokens.menuFontSize, 13);
  });

  test('pen panel and slider values', () {
    expect(KitTokens.penPanelWidth, 300);
    expect(KitTokens.penPanelRadius, 18);
    expect(KitTokens.penPanelBorder, const Color(0xffeceef2));
    expect(KitTokens.sliderHeight, 14);
    expect(KitTokens.sliderTrackColor, const Color(0xfff2f2f2));
    expect(KitTokens.sliderTickColor, const Color(0xffc4c4c4));
    expect(KitTokens.sliderTicks, 11);
    expect(KitTokens.sliderTickDiameter, 2.1);
    expect(KitTokens.sliderPillWidth, 28.6);
    expect(KitTokens.sliderPillHeight, 53.5);
    expect(KitTokens.sliderValueSize, 13);
    expect(KitTokens.stepperDisabled, const Color(0xffd6d6d6));
    expect(KitTokens.badgeSize, 34);
    expect(KitTokens.badgeRadius, 10);
    expect(KitTokens.hoverDot, 12);
    expect(KitTokens.hoverDotBorder, const Color(0xff9fb6e8));
    expect(KitTokens.hoverDotBorderWidth, 1.5);
  });

  test('shadows follow the design table', () {
    final pill = KitTokens.pillShadow.single;
    expect(pill.offset, const Offset(0, 6));
    expect(pill.blurSigma, closeTo(8, 1e-9));
    expect(pill.spreadRadius, -10);

    final panel = KitTokens.panelShadow.single;
    expect(panel.offset, const Offset(0, 14));
    expect(panel.blurSigma, closeTo(17, 1e-9));
    expect(panel.spreadRadius, -16);

    const sel = KitTokens.selBarShadow;
    expect(sel, hasLength(2));
    expect(sel[0].offset, const Offset(0, 6));
    expect(sel[0].blurSigma, closeTo(8, 1e-9));
    expect(sel[0].spreadRadius, -8);
    expect(sel[1].offset, Offset.zero);
    expect(sel[1].blurRadius, 0);
    expect(sel[1].spreadRadius, 0.5);
  });

  test('bar spacing, ring and edge values', () {
    expect(KitTokens.toolbarOnBar, const Color(0xffffffff));
    expect(KitTokens.toolbarPadding, 8);
    expect(KitTokens.toolbarGroupGap, 3);
    expect(KitTokens.pillGap, 2);
    expect(KitTokens.pillPaddingAlong, 6);
    expect(KitTokens.pillPaddingAcross, 3);
    expect(KitTokens.pillVerticalPaddingAlong, 3);
    expect(KitTokens.pillVerticalPaddingAcross, 6);
    expect(KitTokens.colorDotMargin, 3);
    expect(KitTokens.colorDotEdge, const Color(0x1f000000));
    expect(KitTokens.colorDotRingGap, 3);
    expect(KitTokens.colorDotRingWidth, 3);
    expect(KitTokens.selBarPaddingH, 8);
    expect(KitTokens.selBarPaddingV, 6);
    expect(KitTokens.selBarGap, 3);
    expect(KitTokens.selBarDividerMargin, 5);
    expect(KitTokens.popoverEdgeGap, 8);
  });

  test('floating bar values (8th draft f, task-12-values.md)', () {
    expect(KitTokens.floatingBarDefaultColors, const [
      Color(0xff1f2329),
      Color(0xff2f80ed),
      Color(0xffffffff),
      Color(0xffe5484d),
    ]);
    expect(KitTokens.floatingBarDockSnap, 96);
    expect(KitTokens.floatingBarInset, 10);
    expect(KitTokens.floatingBarGroupGap, 6);
    expect(KitTokens.floatingBarPanelGap, 8);
    expect(KitTokens.floatingBarPanelGapUpright, 20);
    expect(KitTokens.pillBorderWidth, 1);
    expect(KitTokens.pillDividerMargin, 3);
    // the pill parts' own colours (values lines 40, 48, 55); the selection
    // bar keeps #141416 and #d6d6db (design doc line 94, checked above)
    expect(KitTokens.pillInk, const Color(0xff1b2231));
    expect(KitTokens.pillDivider, const Color(0xffe2e6ec));
    expect(KitTokens.colorDotRing, const Color(0xffdcdce1));
    expect(KitTokens.eraserRingBase, 8);
    expect(KitTokens.eraserRingPerLevel, 0.14);
    expect(KitTokens.eraserRingLine, 1.7);
    // the on/off buttons (lasso targets, 「형광펜만 지우기」, v8h lines 633-637,
    // 2492): off is .50 (v8h line 636), apart from the .35 of a button that
    // cannot be pressed now
    expect(KitTokens.pillSwitchEdge, const Color(0xffc4c9d1));
    expect(KitTokens.pillSwitchEdgeWidth, 1.5);
    expect(KitTokens.pillSwitchOffOpacity, 0.5);
    expect(KitTokens.disabledOpacity, 0.35);
    expect(KitTokens.pillCheckSize, 12);
    expect(KitTokens.pillCheckOut, 2);
    expect(KitTokens.pillCheckRing, 1.5);
    expect(KitTokens.pillCheckMark, 9);
    expect(KitTokens.pillCheckGrid, 12);
    expect(KitTokens.pillCheckLine, 1.6);
    // a colour dot's focus ring (v8h line 111): 2 wide, 2 out, or 6 out past
    // the chosen dot's rings
    expect(KitTokens.colorDotFocusWidth, 2);
    expect(KitTokens.colorDotFocusGap, 2);
    // user change 1 (task-12-values.md §13): the held bar's shadow a step up,
    // `0 16px 30px -10px rgba(12,22,44,.42)`; a hold let go by a move of
    // more than 10; the width icon's middle line by the size number
    final held = KitTokens.pillShadowRaised.single;
    expect(held.color, const Color.fromRGBO(12, 22, 44, 0.42));
    expect(held.offset, const Offset(0, 16));
    expect(Shadow.convertRadiusToSigma(held.blurRadius), closeTo(15, 1e-9));
    expect(held.spreadRadius, -10);
    expect(KitTokens.floatingBarGrabSlop, 10);
    expect(KitTokens.widthIconLines, [1.4, 2.1, 2.8, 3.5, 4.2]);
    expect(KitTokens.widthIconLevelsPerLine, 20);
  });

  test('menu, switch, segment, swatch and slider part values', () {
    expect(KitTokens.onAccent, const Color(0xffffffff));
    expect(KitTokens.menuWidth, 280);
    expect(KitTokens.submenuGap, 8);
    expect(KitTokens.menuSubSize, 11);
    expect(KitTokens.menuRowHeight, 38);
    expect(KitTokens.menuPaddingH, 16);
    expect(KitTokens.menuTitleSize, 15);
    expect(KitTokens.menuValue, const Color(0xff8a909b));
    expect(KitTokens.menuValueSize, 12);
    expect(KitTokens.menuGroupPad, 3);
    expect(KitTokens.menuGroupTitleSize, 12.5);
    expect(KitTokens.menuQuickGap, 8);
    expect(KitTokens.menuQuickRadius, 12);
    expect(KitTokens.menuQuickTextSize, 12);
    expect(KitTokens.menuOpenRow, const Color(0xfff1f3f6));
    expect(KitTokens.sliderGrabMargin, 6);
    expect(KitTokens.subMenuWidth, 206);
    expect(KitTokens.subMenuPadV, 4);
    expect(KitTokens.subMenuRowHeight, 40);
    expect(KitTokens.subMenuPaddingH, 14);
    expect(KitTokens.subMenuIconGap, 10);
    expect(KitTokens.switchWidth, 32);
    expect(KitTokens.switchHeight, 18);
    expect(KitTokens.switchThumb, 14);
    expect(KitTokens.switchInset, 2);
    expect(KitTokens.switchOff, const Color(0xffe2e6ec));
    expect(KitTokens.toggleRowHeight, 46);
    expect(KitTokens.toggleLabelSize, 12.5);
    expect(KitTokens.toggleTextPadV, 11);
    expect(KitTokens.toggleSubLineHeight, 1.4);
    expect(KitTokens.segmentRadius, 8);
    expect(KitTokens.segmentPaddingH, 11);
    expect(KitTokens.segmentPaddingV, 5);
    expect(KitTokens.swatchRowHeight, 46);
    expect(KitTokens.swatchGap, 6);
    expect(KitTokens.swatchRingGap, 2);
    expect(KitTokens.swatchRingWidth, 1.5);
    expect(KitTokens.swatchRing, const Color(0xff9aa0aa));
    expect(KitTokens.swatchPaletteColors, hasLength(6));
    expect(KitTokens.pageDot, 5);
    expect(KitTokens.pageDotGap, 6);
    expect(KitTokens.pageDotTop, 13);
    expect(KitTokens.pageDotOff, const Color(0xffe2e6ec));
    expect(KitTokens.pageDotOn, const Color(0xff687286));
    expect(KitTokens.sliderTrackWidth, 176);
    expect(KitTokens.sliderPillRadius, 14.3);
    expect(KitTokens.sliderValueInk, const Color(0xff202226));
    expect(KitTokens.sliderValueTopInset, 11);
    expect(KitTokens.sliderMarkShowAt, 0.6);
    expect(KitTokens.sliderStepperBox, 36);
    expect(KitTokens.sliderStepperInk, const Color(0xff25272c));
    expect(KitTokens.sliderStepperSpace, 7);
    expect(KitTokens.sliderThumbShadow, hasLength(2));
    // CSS blur 3 is a Gaussian of sigma 1.5; Flutter's blurRadius r gives
    // sigma 0.57735 r + 0.5
    expect(
      Shadow.convertRadiusToSigma(
        KitTokens.sliderThumbShadow[0].blurRadius,
      ),
      closeTo(1.5, 1e-4),
    );
  });

  test('floating things of Task 13B-2 (values §7, §8, §13, §14-4)', () {
    // hide while writing: the bar's or the chip's box and 12 around it;
    // the phone bar's edge fade
    expect(KitTokens.floatingBarHideMargin, 12);
    expect(KitTokens.floatingBarEdgeFade, 18);
    // save chip: right 12, top 58, 30 high (taps over 44), round 15,
    // padding 12, 7 between mark and words, words 12 / 16.8
    expect(KitTokens.saveChipTop, 58);
    expect(KitTokens.saveChipRight, 12);
    expect(KitTokens.saveChipHeight, 30);
    expect(KitTokens.saveChipHitHeight, 44);
    expect(KitTokens.saveChipPadH, 12);
    expect(KitTokens.saveChipGap, 7);
    expect(KitTokens.saveChipFontSize, 12);
    expect(KitTokens.saveChipLineHeight, 16.8);
    expect(KitTokens.saveChipShift, 6);
    expect(KitTokens.saveChipBg, const Color(0xffffffff));
    expect(KitTokens.saveChipInk, const Color(0xff1b2231));
    expect(KitTokens.saveChipFailInk, const Color(0xffb3261e));
    expect(KitTokens.saveChipActionInk, const Color(0xff2f6ae0));
    expect(KitTokens.saveChipWaitRing, const Color(0xff646c79));
    expect(KitTokens.saveChipWaitRingWidth, 1.6);
    expect(KitTokens.saveChipMark, 8);
    expect(KitTokens.saveChipSpin, 11);
    expect(KitTokens.saveChipSpinLine, 1.5);
    expect(KitTokens.saveChipSpinTrack, const Color(0xffc9ced6));
    expect(KitTokens.saveChipWarn, const Color(0xffc43a3a));
    expect(KitTokens.saveChipShadow, hasLength(2));
    expect(
      Shadow.convertRadiusToSigma(KitTokens.saveChipShadow[0].blurRadius),
      closeTo(8, 1e-4),
    );
    expect(KitTokens.saveChipShadow[0].spreadRadius, -8);
    expect(KitTokens.saveChipShadow[0].offset, const Offset(0, 6));
    expect(KitTokens.saveChipShadow[1].spreadRadius, 0.5);
    // zoom badge: top 100, centred, 30 high, at least 64, padding 14; the
    // mode pill 64 above the page's foot, the same dark pill
    expect(KitTokens.zoomBadgeTop, 100);
    expect(KitTokens.zoomBadgeMinWidth, 64);
    expect(KitTokens.zoomBadgePadH, 14);
    expect(KitTokens.zoomBadgeShift, 4);
    expect(KitTokens.darkPillHeight, 30);
    expect(KitTokens.darkPillBg, const Color.fromRGBO(32, 34, 38, .86));
    expect(KitTokens.darkPillFontSize, 13);
    expect(KitTokens.modePillBottom, 64);
  });

  test('the supplement values: side panel, quick note, sheet, speeds', () {
    expect(KitTokens.sidePanelWidth, 272);
    expect(KitTokens.quickNoteWidth, 360);
    expect(KitTokens.quickNoteHeight, 460);
    expect(KitTokens.quickNoteMinWidth, 260);
    expect(KitTokens.quickNoteMinHeight, 220);
    expect(KitTokens.quickNotePageMargin, 24);
    expect(KitTokens.noteSheetFractions, [0.4, 0.6, 0.9]);
    expect(KitTokens.addPagePanelWidth, 300);
    expect(KitTokens.audioSpeeds, [1, 1.25, 1.5, 2, 0.75]);
    expect(KitTokens.recRed, const Color(0xffc43a3a));
    expect(KitTokens.recPillHeight, 44);
    expect(KitTokens.playerBarHeight, 54);
    expect(KitTokens.playerBarBg, const Color(0xfff2f2f4));
  });

  test('the opacity number has the preview 1 px shadow', () {
    // CSS `text-shadow: 0 0 1px` is a blur of sigma .5; a blur radius of 0
    // draws no blur, and with no offset the shadow then hides under the text
    final shadow = KitTokens.opacityNumberShadow.single;
    expect(shadow.blurSigma, closeTo(.5, .01));
    expect(shadow.offset, Offset.zero);
  });
}
