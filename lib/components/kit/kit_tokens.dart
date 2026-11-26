import 'package:flutter/painting.dart';

/// Screen rule values (design doc "화면 규칙" table). Logical pixels.
/// Every kit widget reads only these; nothing else hard-codes a color or size.
abstract final class KitTokens {
  // Toolbar
  static const toolbarHeight = 46.0;
  static const toolbarBg = Color(0xff2b4b8c);
  static const toolbarButton = 34.0;
  static const toolbarButtonRadius = 10.0;
  // Icon stroke = on-screen line x 24 / size (preview CSS line 88): an icon
  // is drawn on a 24 grid, so the line the eye sees stays the same at any size.
  static const toolbarIconSize = 26.0; // `#editor .tb .b`, `.fbar .pb`, line 89
  static const toolbarIconLine = 1.558;
  static const toolbarIconStroke = toolbarIconLine * 24 / toolbarIconSize;
  static const toolbarDividerWidth = 1.0;
  static const toolbarDividerHeight = 22.0;
  static const toolbarDividerColor = Color(0x47ffffff); // white 28%

  // Floating bar (pill)
  static const pillBg = Color(0xfff2f2f4);
  static const pillBorder = Color(0xffe4e4e8);
  static const pillRadius = 12.0;
  static const pillButton = 32.0;
  static const pillButtonRadius = 9.0;
  static const selectedFill = Color(0xffb7e2ea);
  static const selBarOnFill = Color(0xffe3e3e7); // `.kbar .b.on`, line 452
  static const disabledOpacity = 0.35;
  static const colorDot = 22.0;

  // Text box / lasso selection bar
  static const selBarBg = Color(0xfff2f2f4);
  static const selBarInk = Color(0xff141416);
  static const selBarRadius = 20.0;
  static const selBarButton = 44.0;
  static const selBarButtonRadius = 12.0;
  static const selBarIconSize = 26.0; // `.kz .kbar .b`, line 450
  static const selBarIconLine = 2.1667;
  static const selBarIconStroke = selBarIconLine * 24 / selBarIconSize;
  static const selBarDivider = Color(0xffd6d6db);
  static const selBarDividerHeight = 28.0;

  // Menu
  static const menuInk = Color(0xff1b2231);
  static const menuSub = Color(0xff646c79); // `--k-sub`, line 446; 5.30:1
  static const menuLine = Color(0xffeceef2);
  static const menuBg = Color(0xfff6f6f7);
  static const danger = Color(0xffc43a3a); // `--k-red`, line 446; 5.23:1 on white
  static const accent = Color(0xff2f6ae0);

  /// A state that is well (preview `--app-ok`: 「동기화됨」 in ⋯ 문서 정보).
  static const ok = Color(0xff1d8a52);
  static const menuFontSize = 13.0;

  // Pen panel
  static const penPanelWidth = 300.0;
  static const penPanelRadius = 18.0;
  static const penPanelBorder = Color(0xffeceef2);
  // `.snp .hd svg.ic` (the plain `svg.ic`, line 88) and `.snp .sncolors .eye
  // svg.ic`: the head icons and the swatch row's eyedropper
  static const penPanelIconSize = 22.0;
  static const penPanelIconLine = 1.558;
  static const penPanelIconStroke = penPanelIconLine * 24 / penPanelIconSize;
  static const penRowHeight = 112.0;

  // Pen panel layout. Source: preview CSS lines 153-158 and 568-607 of the
  // 2026-11-19 file (`.snp`), JavaScript lines 1994-2141 for the pen drawings.
  static const penPanelBg = Color(0xffffffff); // `--sn-panel`, line 153
  static const penPanelBorderWidth = 1.0; // line 153
  static const penPanelPadTop = 20.0; // padding 20px 14px 29px, line 153
  static const penPanelPadH = 14.0;
  static const penPanelPadBottom = 29.0;
  static const penPanelHeadHeight = 22.0; // `.snp .hd`, line 154
  static const penPanelHeadGap = 14.0; // line 154
  static const penPanelHeadInk = Color(0xff4a4f59); // line 154
  // `.snp .hd .xbtn` (line 156): the X in a light circle; X `--ics:24` (157)
  static const penPanelCloseSize = 24.0;
  static const penPanelCloseBg = Color(0xfff2f2f2);
  static const penPanelCloseInk = Color(0xff2a2c31);
  static const penPanelCloseIconSize = 24.0;
  static const penPanelCloseIconLine = 1.558;
  static const penPanelCloseIconStroke =
      penPanelCloseIconLine * 24 / penPanelCloseIconSize;
  // code review M7: each head button is pressed in 44 x 44 from the panel's
  // top edge, the icons where the preview draws them
  static const penPanelHeadHit = 44.0;
  // `.snp .pensrow` (line 158): 2 under the head, 4 wider than the rows on
  // each side, a 1px line at its foot that the pens are cut above
  static const penRowTop = 2.0;
  static const penRowInset = 4.0;
  static const penRowLine = 1.0;
  static const penColumnWidth = 40.0; // `.pcol`, line 569
  static const penColumnGap = 9.0; // line 158
  static const penColumnGapHighlighter = 58.0; // `.pensrow.two`, line 568
  static const penRise = 13.0; // `.pcol.on .pw`, line 571
  // `svg.pa` (line 572): the 48 x 200 drawing, 40 below the column's top
  static const penArtTop = 40.0;
  static const penArtWidth = 40.0;
  static const penArtHeight = 167.0;
  // The sheets the pens and their samples are drawn on (`penArt` viewBox
  // 0 0 48 200, `penSampleInner` 0 0 60 34), as in kit_pen_art.dart.
  static const penArtSheetWidth = 48.0;
  static const penArtSheetHeight = 200.0;
  static const penSampleSheetHeight = 34.0;
  static const penSampleWidth = 54.0; // `.psmp`, line 575
  static const penSampleHeight = 31.0;
  static const penSampleScale = 0.9; // `smpPos(..., .9)`, line 2240
  // The write-in after a pen switch opens a clip from the tip to the right,
  // 16 past the sample box on every side (`drawOn`, lines 2408-2410).
  static const penSampleRevealReach = 16.0;
  // The sample strokes fit x 0-35, y 20-34 of their 60 x 34 sheet (line
  // 1999); the pen box centres that part in its cards.
  static const penSampleStrokeRight = 35.0;
  static const penSampleStrokeTop = 20.0;
  // Each pen's tip on its 48 x 200 drawing, where the sample stroke starts
  // (`SAMPLE_AT`, line 1995), by `KitPenKind.previewId`.
  static const penSampleTips = <String, Offset>{
    'fountain': Offset(24, .8),
    'calli': Offset(24, 1.93),
    'pen': Offset(24, .8),
    'pencil': Offset(24, .8),
    'brush': Offset(24, .6),
    'hlchisel': Offset(19.52, 11.5),
    'hlround': Offset(24, 10.3),
  };
  // The dot in the held size pill is the pen's width at that value:
  // max(2, min(24, width x k x .9)) (`SMP_W` and `dotW`, lines 2140-2141).
  static const penMarkWidths = <String, double>{
    'fountain': 4.4,
    'pen': 3.6,
    'pencil': 1.7,
    'brush': 4.2,
    'hlchisel': 10,
    'hlround': 10,
  };
  static const penMarkScale = 0.9;
  static const penMarkMin = 2.0;
  static const penMarkMax = 24.0;
  static const penPanelRowsTop = 16.0; // `.snp .snrows`, line 577
  static const penPanelRowHeight = 46.0; // `.snp .srow`, line 578
  static const penPanelColorsTop = 4.0; // `.snp .sncolors` margin, line 589
  // design review I-3: two greys (max - min channel up to 8 of 255) whose
  // luma (Rec. 709, 0-255) is within 33 count as one colour when the colour
  // row picks the page to open and the dot to ring; #000000 and the basic
  // page's #1f2023 are 32.0 apart, #1f2023 and #424242 34.0
  static const penColorSameGreyLuma = 33.0;
  static const penColorSameGreyChroma = 8.0;
  // Colour pages 1-3 (`CPAGES`, lines 2116-2119): the basic eight
  // (`SP_COLORS`, line 2112), the old colour bar's pastels and its greys
  // (black, grey[800], grey, grey[200], white).
  static const penPanelColorPages = <List<Color>>[
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
  ];

  // Pen box window. No preview draws it: it is the pen panel's box (`.snp`
  // padding and line) with a group title like `.snp .gt` (line 627) and cards
  // like `.snp .mode` (line 623), three to a row 10 apart like `.moderow`
  // (line 622). The card height and the columns are our choice.
  static const penBoxColumns = 3;
  static const penBoxGap = 10.0; // `.moderow` gap, line 622
  static const penBoxCardHeight = 64.0; // our choice: sample 31 + name
  static const penBoxCardBg = Color(0xfff6f7f9); // `.snp .mode`, line 623
  static const penBoxCardRadius = 14.0; // line 623
  static const penBoxCardPadTop = 6.0; // padding 6px 4px 7px, line 623
  static const penBoxCardPadBottom = 7.0;
  static const penBoxCardTextSize = 12.0; // line 623
  static const penBoxCardTextHeight = 1.3; // `.snp .mode span`, line 626
  static const penBoxTitleSize = 12.0; // `.snp .gt` 11, 12 by design M-1
  static const penBoxTitleWeight = FontWeight.w600;
  static const penBoxTitleHeight = 1.4; // the `.snp` line height, 18.2 / 13
  static const penBoxEmptyPadV = 12.0; // our choice

  // The rows the 229 tool panels had and the eraser and lasso panels (8th
  // draft, line numbers of preview-v8d.html). `.snp .stab` (line 621): 16
  // under the page dots, a 1px line as wide as the pen row's, 4 padding; its
  // title row (`.stab .tg.sub`, preview-v8f line 621) has 6 above its line
  // and the value at its end, then the note 2 under it (`.sth`).
  static const penPanelStabTop = 16.0;
  static const penPanelStabPadTop = 4.0;
  static const penPanelStabTitlePadTop = 6.0;
  // `.snp .gt` (line 628): the lasso's 「선택 대상」, 11 px 600 on the panel's
  // 1.4 line (15.4, kept in a box: Flutter would round the line to 15)
  static const penPanelGroupTitleSize = 11.0;
  static const penPanelGroupTitleWeight = FontWeight.w600;
  static const penPanelGroupTitleHeight = 1.4;
  static const penPanelGroupTitlePadTop = 4.0;
  static const penPanelGroupTitlePadBottom = 2.0;
  // `.snp .hint` (preview-v8g line 619): a note under a panel's rows, 11 px
  // on the panel's 1.4 line; the lasso's (`.hint.la`) 2 under the last row
  static const penPanelHintTop = 2.0;
  // `.snp .moderow` (line 623): two cards where the pens stand, 10 apart,
  // padding 8 4 12 inside the pen row's 112 and its line; `.snp .mode`
  // (lines 624-627): radius 14, padding 6 4 7, the sample on top and the
  // name at the foot, 12 px on a 1.3 line
  static const penPanelModeRowPadTop = 8.0;
  static const penPanelModeRowPadBottom = 12.0;
  static const penPanelModeGap = 10.0;
  static const penPanelModeRadius = 14.0;
  static const penPanelModePadTop = 6.0;
  static const penPanelModePadH = 4.0;
  static const penPanelModePadBottom = 7.0;
  static const penPanelModeBg = Color(0xfff6f7f9);
  static const penPanelModeOnBg = Color(0xffe8e9ed); // `--sn-pill`
  static const penPanelModeTextSize = 12.0;
  static const penPanelModeTextHeight = 1.3;
  static const penPanelModeOnWeight = FontWeight.w600;
  // The eraser keeps its radius 4-60 (the 229 panel's slider); the panel
  // shows it on the pen panel's 1-100
  // scale (line 2127). Its held dot is 4 + value x .14 in the eraser's pink
  // at .85 (`esize`, line 2157).
  static const eraserSizeMin = 4.0;
  static const eraserSizeMax = 60.0;
  static const eraserMarkBase = 4.0;
  static const eraserMarkPerLevel = 0.14;
  static const eraserMarkInk = Color.fromRGBO(255, 122, 162, 0.85);

  // Pen panel slider (Samsung values)
  static const sliderHeight = 14.0;
  static const sliderThumb = 28.0;
  static const sliderTrackColor = Color(0xfff2f2f2);
  static const sliderTickColor = Color(0xffc4c4c4);
  static const sliderTicks = 11;
  static const sliderTickDiameter = 2.1;
  static const sliderPillWidth = 28.6;
  static const sliderPillHeight = 53.5;
  static const sliderValueSize = 13.0;
  static const sliderHitHeight = 44.0;
  static const stepperDisabled = Color(0xffd6d6d6);

  // Pen tip badge (`.badge`, `.hoverdot`, lines 116-117, placed at 804-805):
  // the dot (430, 640) has the tip (436, 646) in its middle, the badge
  // (446, 612) its bottom-left corner 10 right of the tip
  static const badgeSize = 34.0;
  static const badgeRadius = 10.0;
  static const badgeGap = 10.0;
  static const badgeBg = Color(0xffffffff); // `--app-surface`, line 11
  static const badgeLine = Color(0xffe2e6ec); // `--app-line`, 1px
  static const badgeInk = Color(0xff1b2231); // `--app-ink`
  // the plain `svg.ic` (line 88): 22, line 1.558 on screen (computed 1.69964)
  static const badgeIconSize = 22.0;
  static const badgeIconStroke = toolbarIconLine * 24 / badgeIconSize;
  static const badgeShadow = [
    BoxShadow(
      color: Color.fromRGBO(12, 22, 44, 0.26),
      offset: Offset(0, 6),
      blurRadius: (14 / 2 - 0.5) / 0.57735,
      spreadRadius: -8,
    ),
  ]; // `0 6px 14px -8px var(--shadow)`
  static const hoverDot = 12.0;
  static const hoverDotBorder = Color(0xff9fb6e8);
  static const hoverDotBorderWidth = 1.5;
  static const hoverDotFill = Color.fromRGBO(255, 255, 255, 0.6);

  // Spacing and ring values of the bars. Source: preview CSS
  // (docs/superpowers/specs/2026-11-18-next-batch-preview.html), line numbers
  // of the 2026-11-19 file.
  static const toolbarOnBar = Color(0xffffffff); // `--app-on`, line 11
  static const toolbarPadding = 8.0; // `.tb` padding 0 8px, line 96
  static const toolbarGroupGap = 3.0; // `.tb .g` gap, line 97
  // Dropdown button (`.tb .b.dd`, line 100): 40 wide, icon then an 8px column
  // (`grid-template-columns:auto 8px`, gap 0), the pair centred in the button.
  // The mark (`.tb .b.dd::after`, line 101) is a 5px box with right and bottom
  // borders of 1.6px, turned 45 degrees and moved (-2, -2) in the turned
  // frame, which is straight up by 2 x sqrt(2); opacity .9.
  static const toolbarDropdownWidth = 40.0;
  static const toolbarDropdownColumn = 8.0;
  static const toolbarDropdownMarkArm = 5.0;
  static const toolbarDropdownMarkLine = 1.6;
  static const toolbarDropdownMarkOpacity = 0.9;
  static const toolbarDropdownMarkRise = 2 * 1.4142135623730951;
  static const toolbarDropdownIconShift =
      (toolbarDropdownWidth - (toolbarIconSize + toolbarDropdownColumn)) / 2 +
      toolbarIconSize / 2 -
      toolbarDropdownWidth / 2; // icon centre relative to the button centre
  static const toolbarDropdownMarkCentre =
      (toolbarDropdownWidth - (toolbarIconSize + toolbarDropdownColumn)) / 2 +
      toolbarIconSize +
      toolbarDropdownColumn / 2; // from the button's left edge
  static const pillGap = 2.0; // `.fbar .pill` gap, line 106
  static const pillPaddingAlong = 6.0; // padding 3px 6px, line 106
  static const pillPaddingAcross = 3.0; // line 106
  static const pillVerticalPaddingAlong =
      3.0; // `.fbar.vert .pill` 6px 3px, line 114
  static const pillVerticalPaddingAcross = 6.0; // line 114
  static const colorDotMargin = 3.0; // `.fbar .cd` margin 0 3px, line 110
  static const colorDotEdge = Color(
    0x1f000000,
  ); // inset 1px rgba(0,0,0,.12), line 110
  static const colorDotRingGap = 3.0; // `.cd.on` 0 0 0 3px, line 111
  static const colorDotRingWidth = 3.0; // 0 0 0 6px, line 111
  static const selBarPaddingH = 8.0; // `.kbar` padding 6px 8px, line 449
  static const selBarPaddingV = 6.0; // line 449
  static const selBarGap = 3.0; // `.kbar` gap, line 449
  static const selBarDividerMargin = 5.0; // `.kbar .sep` margin 0 5px, line 455
  // No preview source: smallest gap kept between a popover and the screen edge.
  static const popoverEdgeGap = 8.0;

  // The floating bar (`.fbar`, line numbers of preview-v8f.html; values in
  // task-12-values.md). `.fbar .pill` has a 1px border that takes room
  // (line 106) and `.vsep` 3 on each side along the pill (lines 112, 115).
  static const pillBorderWidth = 1.0;
  static const pillDividerMargin = 3.0;
  // The pill parts' own colours: `.fbar .pb` ink `--app-ink` (line 107),
  // `.vsep` `--app-line` (line 112) and the chosen dot's outer ring (`.cd.on`
  // 0 0 0 6px, line 111). The selection bar keeps `selBarInk` and
  // `selBarDivider`.
  static const pillInk = Color(0xff1b2231);
  static const pillDivider = Color(0xffe2e6ec);
  static const colorDotRing = Color(0xffdcdce1);
  // `#fbar` left 10, top 10 in the canvas area (line 798), across the top or
  // upright at the left; its two pills 6 apart (`.fbar` gap, line 105)
  static const floatingBarInset = 10.0;
  static const floatingBarGroupGap = 6.0;
  // Let go with its left edge this near the canvas area's left, the bar
  // stands upright there (plan Task 12).
  static const floatingBarDockSnap = 96.0;
  // The four dots before there are recent colours: the preview's dots
  // (design doc 「떠 있는 막대」)
  static const floatingBarDefaultColors = [
    Color(0xff1f2329),
    Color(0xff2f80ed),
    Color(0xffffffff),
    Color(0xffe5484d),
  ];
  // A window opened from the bar starts at its button, 8 under the bar, or
  // 20 beside it upright: where the preview opens the pen panel (line 2418,
  // top 58 under the bar's foot at 50, left 70 beside its edge at 50)
  static const floatingBarPanelGap = 8.0;
  static const floatingBarPanelGapUpright = 20.0;
  // The eraser's size ring (`.fbar .pb.esz i`, lines 629, 2484):
  // 8 + level x .14 across, a 1.7 line inside, in the button's ink
  static const eraserRingBase = 8.0;
  static const eraserRingPerLevel = 0.14;
  static const eraserRingLine = 1.7;
  // The bar's on/off buttons, the lasso targets and 「형광펜만 지우기」
  // (`.fbar .pb.tgt`, lines 633-637 and 2492 of preview-v8h.html): on, a 1.5
  // line inside and a 12 check badge in the accent 2 past the bottom right
  // corner, ringed 1.5 in the pill's colour, its check drawn 9 x 9 from a
  // 12 grid with a 1.6 line; off, the whole button at .50 (v8h line 636),
  // apart from the .35 of a button that cannot be pressed now
  static const pillSwitchEdge = Color(0xffc4c9d1);
  static const pillSwitchEdgeWidth = 1.5;
  static const pillSwitchOffOpacity = 0.5;
  static const pillCheckSize = 12.0;
  static const pillCheckOut = 2.0;
  static const pillCheckRing = 1.5;
  static const pillCheckMark = 9.0;
  static const pillCheckGrid = 12.0;
  static const pillCheckLine = 1.6;
  // A colour dot's keyboard focus ring (`.cd:focus-visible`, v8h line 111):
  // 2 wide in the accent, 2 out from the dot, or 6 out past the chosen
  // dot's two rings
  static const colorDotFocusWidth = 2.0;
  static const colorDotFocusGap = 2.0;
  // The held bar (preview-v8k line 115, task-12-values.md §13): its pills'
  // shadow a step up, `0 16px 30px -10px rgba(12,22,44,.42)`; a hold is let
  // go by a move of more than 10 (across plus down) before it is picked up
  // (line 2532)
  static const pillShadowRaised = [
    BoxShadow(
      color: Color.fromRGBO(12, 22, 44, 0.42),
      offset: Offset(0, 16),
      blurRadius: (30 / 2 - 0.5) / 0.57735,
      spreadRadius: -10,
    ),
  ];
  static const floatingBarGrabSlop = 10.0;
  // The width icon's middle line on the 24 grid for the size number (1-100)
  // in steps of 20 (`barWidth`, v8k line 2315): 1-20, 21-40, ... 81-100
  static const widthIconLines = [1.4, 2.1, 2.8, 3.5, 4.2];
  static const widthIconLevelsPerLine = 20;

  // Menu, switch, segment, swatches and slider parts. Source: preview CSS
  // (docs/superpowers/specs/2026-11-18-next-batch-preview.html), line numbers
  // of the 2026-11-19 file, and video-reanalysis-report.md for the slider.
  // "Our choice" marks values no preview line or photo gives.
  static const onAccent = Color(0xffffffff); // `--accent-ink`, line 7
  static const controlThumb = Color(0xffffffff); // `.sw::after`, line 143
  // Flutter's blurRadius r gives sigma 0.57735 r + 0.5 while a CSS blur b is
  // sigma b / 2, so each blur below is r = (b / 2 - 0.5) / 0.57735.
  // `.kpanel` window shadow, line 506: no border, the 1px ring is in the shadow
  static const menuShadow = [
    BoxShadow(
      color: Color(0x73142032),
      offset: Offset(0, 18),
      blurRadius: (40 / 2 - 0.5) / 0.57735,
      spreadRadius: -18,
    ),
    BoxShadow(color: Color(0x0f142032), spreadRadius: 1),
  ]; // `0 18px 40px -18px rgba(20,32,50,.45), 0 0 0 1px rgba(20,32,50,.06)`
  static const menuWidth = 280.0; // plan Task 6 default
  static const submenuGap = 8.0; // plan Task 6: sub right = menu left - 8
  // Menu window (preview `.kpanel`, lines 506-517 of the 2026-11-19 file)
  static const menuRowHeight = 38.0; // `.kpanel .it` min-height, line 512
  static const menuPaddingH = 16.0; // `.kpanel .it` padding, line 512
  // `.kz svg.ic`, line 447 (also the quick cards and the `.ksub .it` rows)
  static const menuIconSize = 22.0;
  static const menuIconLine = 1.4875;
  static const menuIconStroke = menuIconLine * 24 / menuIconSize;
  static const menuIconGap = 12.0; // `.kpanel .it` gap, line 512
  static const menuSubSize = 11.0; // `.kmenu .it .pst small`, line 504
  static const menuValue = Color(0xff8a909b); // `.kpanel .it .v`, line 513
  static const menuValueSize = 12.0; // line 513
  // `.kpanel .it .v svg.ic`, line 514
  static const menuValueIconSize = 18.0;
  static const menuValueIconLine = 1.0625;
  static const menuValueIconStroke = menuValueIconLine * 24 / menuValueIconSize;
  static const menuGroupBg = Color(0xffffffff); // `.kpanel .grp`, line 510
  static const menuGroupPad = 3.0; // `.kpanel .grp` padding 3px 0, line 510
  static const menuLineWidth = 1.0; // `border-top:1px`, line 510
  static const menuOpenRow = Color(0xfff1f3f6); // `.it[data-sub].open`, 517
  static const menuTitleSize = 15.0; // `.kpanel .ttl`, line 507
  static const menuTitlePadTop = 14.0; // line 507
  static const menuTitlePadH = 16.0; // line 507
  static const menuTitlePadBottom = 10.0; // line 507
  static const menuGroupTitleSize = 12.5; // `.kpanel .gt`, line 511
  static const menuGroupTitlePadTop = 10.0; // line 511
  static const menuGroupTitlePadBottom = 3.0; // line 511
  static const menuQuickPadH = 12.0; // `.kpanel .quick` padding, line 508
  static const menuQuickPadBottom = 12.0; // line 508
  static const menuQuickGap = 8.0; // line 508
  static const menuQuickRadius = 12.0; // `.quick span`, line 509
  static const menuQuickPadV = 10.0; // line 509
  static const menuQuickInnerGap = 4.0; // line 509
  static const menuQuickTextSize = 12.0; // line 509
  // computed in the 7th draft ⋯ (Task 14 fix 1): the grid's icon row and
  // the name's line height (`.kz` 1.35)
  static const menuQuickIconRow = 42.0;
  static const menuQuickLine = 1.35;

  // Submenu window (preview `.ksub`, lines 518-521)
  static const subMenuWidth = 206.0; // `.ksub` width, line 518
  static const subMenuPadV = 4.0; // `.ksub` padding 4px 0, line 518
  static const subMenuRowHeight = 40.0; // `.ksub .it` height, line 520
  static const subMenuPaddingH = 14.0; // `.ksub .it` padding, line 520
  static const subMenuIconGap = 10.0; // `.ksub .it` gap, line 520
  static const subMenuRadius = 14.0; // `.ksub` border-radius, line 518
  static const subMenuShadow = [
    BoxShadow(
      color: Color(0x73142032),
      offset: Offset(0, 14),
      blurRadius: (30 / 2 - 0.5) / 0.57735,
      spreadRadius: -14,
    ),
    BoxShadow(color: Color(0x0f142032), spreadRadius: 1),
  ]; // `0 14px 30px -14px rgba(20,32,50,.45), 0 0 0 1px rgba(20,32,50,.06)`

  // Switch
  static const switchWidth = 32.0; // `.sw`, line 142
  static const switchHeight = 18.0; // line 142
  static const switchThumb = 14.0; // `.sw::after`, line 143
  static const switchInset = 2.0; // top 2px left 2px, line 143
  static const switchOff = Color(0xffe2e6ec); // `--app-line`, line 11
  static const switchThumbShadow = [
    BoxShadow(
      color: Color.fromRGBO(12, 22, 44, 0.26),
      offset: Offset(0, 1),
      blurRadius: (2 / 2 - 0.5) / 0.57735,
    ),
  ]; // `0 1px 2px var(--shadow)`, line 143

  // Toggle row
  static const toggleRowHeight = 46.0; // `.snp .tg` min-height, line 566
  static const toggleLabelSize = 12.5; // `.tg` font-size, line 141
  // the panel's line height (`.snp` 13 px / 18.2 px) that `.tg` inherits: 17.5
  static const toggleLabelLineHeight = 1.4;
  static const toggleTextPadV = 11.0; // `.tg.tx` padding, line 585
  static const toggleTextGap = 14.0; // `.tg.tx>span` padding-right, line 586
  static const toggleSubLineHeight = 1.4; // `.tg small` line-height, line 588
  // A row with a note (`.snp .tg.tx`, preview-v8d lines 615-618) keeps the
  // name and the switch at its top: the switch 1 lower, each note line 2
  // under the line before.
  static const toggleSwitchTop = 1.0;
  static const toggleSubTop = 2.0;

  // Segment
  static const segmentRadius = 8.0; // `.seg`, line 68
  static const segmentPaddingH = 11.0; // `.seg button`, line 69
  static const segmentPaddingV = 5.0; // line 69
  static const segmentDividerWidth = 1.0; // line 70

  // Swatches
  static const swatchRowHeight = 46.0; // `.snp .sncolors`, line 575
  static const swatchGap = 6.0; // `.sncolors` gap, line 202
  static const swatchRingGapColor = Color(0xffffffff); // line 577
  static const swatchRingGap = 2.0; // `0 0 0 2px #fff`, line 577
  static const swatchRingWidth = 1.5; // `0 0 0 3.5px`, line 577
  static const swatchRing = Color(0xff9aa0aa); // line 577
  static const swatchHitPad = 3.0; // our choice: half of the gap, round
  static const swatchToolInk = Color(0xff4a4f59); // `.sncolors .eye`, line 205
  static const swatchPaletteRing = Color(0xffe05a5a); // `.pal` ring, line 204
  static const swatchPaletteColors = [
    Color(0xffff5d5d),
    Color(0xffffd84a),
    Color(0xff5bd38b),
    Color(0xff4aa8ff),
    Color(0xff9a6bff),
    Color(0xffff5d5d),
  ]; // conic-gradient, line 204
  // The pen panel's colour row (`.snp .sncolors`, lines 589-602): a page area
  // 218 wide (`.snp .cpv`, line 597: 8 dots, 7 gaps) from the row's left edge.
  static const swatchPageWidth = 218.0;
  // `.lt`, line 600: dots lighter than this luma (0-255, `lightC`, line 2267)
  // get an inset 1px line rgba(20,32,50,.2)
  static const swatchLightLuma = 225.0;
  static const swatchLightEdge = Color(0x33142032);
  // `button.pin::after`, line 602: 7 round, 3 out from the top right corner,
  // with a 1.5 white ring
  static const swatchPinBadge = 7.0;
  static const swatchPinInk = Color(0xff2a2c31);
  static const swatchPinRing = 1.5;
  static const swatchPinOffset = 3.0;
  // design review M-4: on a dark colour (luma under 80, our choice) the
  // badge's white ring is 2 so the dark badge stays apart from the dot
  static const swatchPinRingDark = 2.0;
  static const swatchDarkLuma = 80.0;
  // design review M-6: the eyedropper and the palette 4 apart (the preview's
  // 6 made the row 274 in 270), so the row ends on the content edge
  static const swatchToolGap = 4.0;
  static const pageDot = 5.0; // `.pdots i`, line 149
  static const pageDotGap = 6.0; // `.pdots` gap, line 148
  static const pageDotTop = 13.0; // `.snp .pdots` margin, line 592
  // `.snp .pdots button`, line 604: each dot is pressed in an 11 x 22 box
  static const pageDotHitWidth = 11.0;
  static const pageDotHitHeight = 22.0;
  static const pageDotOff = Color(0xffe2e6ec); // `--app-line`, line 149
  static const pageDotOn = Color(0xff687286); // `--app-muted`, line 150
  // `.snp .pdots .pname`, line 607: the page's name at the dots' left
  static const pageNameSize = 11.0;
  static const pageNameInset = 4.0;
  // code review M7: the dots are pressed in a band 44 high around them, up
  // to 22 past the end dots, the nearest dot winning; they still look 5 wide
  // and 11 apart
  static const pageDotHitZone = 44.0;

  // Slider parts (the rest is in "Pen panel slider")
  static const sliderTrackWidth = 176.0; // `.dtrack` width, line 162
  static const sliderPillRadius = 14.3; // `.th` radius, line 168
  static const sliderThumbColor = Color(0xffffffff); // `.th`, line 168
  static const sliderValueInk = Color(0xff202226); // `.th .tn`, line 169
  static const sliderValueTopInset = 11.0; // report 3-2: 11 below the top
  static const sliderMarkShowAt = 0.6; // report 3-1: dot shows at ~60% grown
  static const sliderGrabMargin = 6.0; // report 3-4: radius + 6 grabs
  // `.th .tn.lg` (preview-v8d line 171): a value of four or more characters
  // (100%) is 11 px
  static const sliderValueSizeLong = 11.0;
  // `.th .td` (preview-v8d line 172): the dot a slider without one of its own
  // shows while held (the stabiliser's)
  static const sliderMarkSize = 6.0;
  static const sliderMarkInk = Color(0xff1f2329);
  static const sliderNumberBoxWidth = 48.0; // our choice: room for 4 digits
  static const sliderNumberBoxHeight = 20.0; // our choice: 13 px text
  static const sliderStepperBox = 36.0; // `.slb`, line 181
  // `.snp .srow .slb svg.ic` (--ics 32, line 579): the icon box is 32, and the
  // minus/plus path spans 12.8 of its 24 grid, so the line the eye sees is
  // 32 x 12.8 / 24 long (report 3-2 "17.8" is that line length).
  static const sliderStepperIconSize = 32.0;
  static const sliderStepperIconLine = 1.558;
  static const sliderStepperIconStroke =
      sliderStepperIconLine * 24 / sliderStepperIconSize;
  static const sliderStepperLineLength = sliderStepperIconSize * 12.8 / 24;
  static const sliderStepperInk = Color(0xff25272c); // `.slb`, line 181
  // `.snp .srow` (line 578): minus 36, track 176, plus 36 spread over the 262
  // inside its 4 px padding, so 7 apart
  static const sliderStepperSpace = 7.0;
  // `0 1px 3px rgba(0,0,0,.18), 0 0 0 .5px rgba(0,0,0,.07)`, line 168. A CSS
  // blur b is a Gaussian of sigma b / 2; Flutter's blurRadius r gives sigma
  // 0.57735 r + 0.5, so blur 3 is r = (3 / 2 - 0.5) / 0.57735.
  static const sliderThumbShadow = [
    BoxShadow(
      color: Color.fromRGBO(0, 0, 0, 0.18),
      offset: Offset(0, 1),
      blurRadius: (3 / 2 - 0.5) / 0.57735,
    ),
    BoxShadow(color: Color.fromRGBO(0, 0, 0, 0.07), spreadRadius: 0.5),
  ];

  // Shadows (preview 6th draft CSS, --shadow = rgba(12,22,44,.26))
  static const pillShadow = [
    BoxShadow(
      color: Color.fromRGBO(12, 22, 44, 0.26),
      offset: Offset(0, 6),
      blurRadius: (16 / 2 - 0.5) / 0.57735,
      spreadRadius: -10,
    ),
  ];
  static const selBarShadow = [
    BoxShadow(
      color: Color.fromRGBO(0, 0, 0, 0.22),
      offset: Offset(0, 6),
      blurRadius: (16 / 2 - 0.5) / 0.57735,
      spreadRadius: -8,
    ),
    BoxShadow(color: Color.fromRGBO(0, 0, 0, 0.07), spreadRadius: 0.5),
  ];
  static const panelShadow = [
    BoxShadow(
      color: Color.fromRGBO(12, 22, 44, 0.26),
      offset: Offset(0, 14),
      blurRadius: (34 / 2 - 0.5) / 0.57735,
      spreadRadius: -16,
    ),
  ];

  // Settings page, 9구역 of the 2026-11-18 preview (7판 확정판), computed values
  // in logical px. Icon stroke = screen line x 24 / size: 1.3458 at 19 and
  // 1.1333 at 16 both give 1.70004.
  static const settingsIconStroke = 1.70004;
  // `.srow .i` (line 294) and `.snav div svg` (line 342): row and list icons
  static const settingsIconSize = 19.0;
  // `.srow .v svg.ic`, the arrow of a value chip (line 295)
  static const settingsChipIconSize = 16.0;
  // back arrow in the top bar (line 1390)
  static const settingsBackIconSize = 20.0;
  // magnifier of the search box (line 1390)
  static const settingsSearchIconSize = 17.0;
  static const settingsBg = Color(0xffedf0f4); // `--app-bg`, line 11
  static const settingsSurface = Color(0xffffffff); // `--app-surface`
  static const settingsMuted = Color(0xff687286); // `--app-muted`
  static const settingsLine = Color(0xffe2e6ec); // `--app-line`
  static const settingsSoft = Color(0xffeef3fd); // `--app-soft`
  static const settingsDanger = Color(0xffcf3a3a); // `--app-danger`
  static const settingsTopBarHeight = 48.0; // line 1390
  static const settingsTopBarPadH = 14.0;
  static const settingsSearchWidth = 240.0;
  static const settingsSearchRadius = 9.0;
  static const settingsNavWidth = 230.0; // `.snav`, line 341
  static const settingsNavPadV = 10.0;
  static const settingsNavPadH = 8.0;
  static const settingsNavItemPadV = 8.0; // `.snav div`, line 342
  static const settingsNavItemPadH = 10.0;
  static const settingsNavItemGap = 9.0;
  static const settingsNavItemRadius = 9.0;
  static const settingsNavFontSize = 12.5;
  static const settingsHeadFontSize = 11.0; // `.shead`, line 298
  static const settingsRowPadV = 9.0; // `.srow`, lines 293-298
  static const settingsRowPadH = 12.0;
  static const settingsRowGap = 10.0;
  static const settingsRowFontSize = 12.5;
  static const settingsNoteFontSize = 11.0; // `.note`, line 297
  static const settingsDimOpacity = 0.45; // `.srow.dis`, line 296
  static const settingsChipFontSize = 12.0; // `.srow .v`, line 295
  static const settingsChipRadius = 7.0;
  static const settingsWideBreakpoint = 720.0; // below it the list hides
  // Top bar (line 1390): arrow at x 14, title at x 44 (arrow 20 + gap 10). The
  // arrow's press area adds 12 around it, so the bar starts 12 earlier.
  static const settingsTopBarGap = 10.0;
  static const settingsBackTapPad = 12.0;
  static const settingsTitleSize = 14.0; // `<b>` title
  static const settingsTitleWeight = FontWeight.w700;
  // Search box (line 1390): border 1, padding 5 / 10, gap 6, text 12; the line
  // height 17.1 makes the box 29.1 high (Flutter rounds the line to 17: 29).
  static const settingsSearchPadH = 10.0;
  static const settingsSearchPadV = 5.0;
  static const settingsSearchGap = 6.0;
  static const settingsSearchFontSize = 12.0;
  static const settingsSearchLineHeight = 1.425;
  // Row text lines. Label 19 + note 14 + padding 18 + line 1 = 52 (38 without
  // the note); the chip is 22.8 high (16.8 text + 3 + 3), so a chip row is 41.8
  // (the chip line rounds to 17 in Flutter: 42). settings_text.dart holds each
  // line at its height whatever fonts draw it.
  static const settingsLabelLineHeight = 1.52; // 12.5 x 1.52 = 19
  static const settingsNoteLineHeight = 1.2727; // 11 x 1.2727 = 14
  static const settingsChipLineHeight = 1.4; // 12 x 1.4 = 16.8
  static const settingsChipPadding = EdgeInsets.fromLTRB(9, 3, 4, 3); // line 295
  static const settingsChipGap = 2.0;
  // Group header `.shead` (line 298): padding 12 12 12 6, text 11 x 1.409; the
  // 15.5 line would round to 15, so the header keeps a 15.5 box (33.5).
  static const settingsHeadPadding = EdgeInsets.fromLTRB(12, 12, 12, 6);
  static const settingsHeadLineHeight = 1.409;
  static const settingsHeadWeight = FontWeight.w600;
  static const settingsNavOnWeight = FontWeight.w600; // `.snav div.on`, line 343
  static const settingsListBottomPad = 24.0; // room under the last row

  // The editor toolbar of the 9th draft c (task-13B-values.md §14)
  static const editorToolbarSelectedInk = Color(0xff23407b); // `--app-bar`
  static const editorToolbarOpenFill = Color(0x2effffff); // white 18 %
  static const editorToolbarModeRing = Color(0x80ffffff); // inset 1.5, white 50 %
  // its note window (`.c9note`, §14-4)
  static const noteSheetHeadInk = Color(0xff5b6270);
  static const noteSheetPaper = Color(0xfffffdf4);
  static const noteSheetPaperLine = Color(0xffe3dfc9);
  static const noteSheetShadow = [
    BoxShadow(
      color: Color(0x73142032), // rgba(20,32,50,.45)
      offset: Offset(0, 18),
      blurRadius: 40,
      spreadRadius: -18,
    ),
    BoxShadow(color: Color(0x14142032), spreadRadius: 1), // .08
  ];
  // its 「도구 막대 사용자화」 (`.plscrim`, `.t13r`, §12-3 D)
  static const customizeScrim = Color(0x38142032); // rgba(20,32,50,.22)
  static const customizeHandleInk = Color(0xff9aa0aa);
  static const customizeLift = [
    BoxShadow(
      color: Color(0x66142032), // rgba(20,32,50,.4)
      offset: Offset(0, 8),
      blurRadius: 18,
      spreadRadius: -8,
    ),
  ];

  // Task 13B-2. A stroke within this of the floating bar or the save chip
  // hides it (task-13B-values.md §13-3); the phone bar's tools fade over
  // this at an end they run past (§13-2).
  static const floatingBarHideMargin = 12.0;
  static const floatingBarEdgeFade = 18.0;
  // The save chip (`.savechip`, §7): right 12, top 58 in the page area,
  // 30 high and round, taking presses over 44 (§12-4 #9)
  static const saveChipTop = 58.0;
  static const saveChipRight = 12.0;
  static const saveChipHeight = 30.0;
  static const saveChipHitHeight = 44.0;
  static const saveChipPadH = 12.0;
  static const saveChipGap = 7.0;
  static const saveChipFontSize = 12.0;
  static const saveChipLineHeight = 16.8;
  static const saveChipShift = 6.0; // hidden, 6 up
  static const saveChipBg = Color(0xffffffff);
  static const saveChipInk = Color(0xff1b2231);
  static const saveChipFailInk = Color(0xffb3261e);
  static const saveChipActionInk = Color(0xff2f6ae0);
  // its marks (§7-3): waiting, an 8 ring 1.6 inside; failed, an 8 dot;
  // saving, an 11 ring of 1.5 (CSS 1.6) with its top quarter in the accent
  static const saveChipMark = 8.0;
  static const saveChipWaitRing = Color(0xff646c79);
  static const saveChipWaitRingWidth = 1.6;
  static const saveChipWarn = Color(0xffc43a3a);
  static const saveChipSpin = 11.0;
  static const saveChipSpinLine = 1.5;
  static const saveChipSpinTrack = Color(0xffc9ced6);
  // `0 6px 16px -8px rgba(0,0,0,.28), 0 0 0 .5px rgba(0,0,0,.08)`
  static const saveChipShadow = [
    BoxShadow(
      color: Color.fromRGBO(0, 0, 0, 0.28),
      offset: Offset(0, 6),
      blurRadius: (16 / 2 - 0.5) / 0.57735,
      spreadRadius: -8,
    ),
    BoxShadow(color: Color.fromRGBO(0, 0, 0, 0.08), spreadRadius: 0.5),
  ];
  // The dark pills: the zoom badge (`.zoompill`, §8), top 100 and centred,
  // at least 64 wide, 4 up while hidden; the mode pill (`.c9toast`,
  // §14-4) 64 above the page area's foot
  static const darkPillHeight = 30.0;
  static const darkPillBg = Color.fromRGBO(32, 34, 38, .86);
  static const darkPillInk = Color(0xffffffff);
  static const darkPillFontSize = 13.0;
  static const zoomBadgeTop = 100.0;
  static const zoomBadgeMinWidth = 64.0;
  static const zoomBadgePadH = 14.0;
  static const zoomBadgeShift = 4.0;
  static const modePillBottom = 64.0;

  // The text box and lasso bars (preview-v9c 1-2, lines 449-505 and
  // 887-912; Task 15). The bar itself uses the selBar values above.
  // `.kbar .cc` (line 457): the colour chip, 30 round with a 1 px inner edge
  // rgba(0,0,0,.08) and the ▾ at 16 / 1.7333 (line 458). On a light colour
  // the ▾ is the colour under 64 % black (the lasso's #f7d708 gives the
  // drawn #5b4b00, line 908); the light limit is our choice.
  static const selChip = 30.0;
  static const selChipEdge = Color.fromRGBO(0, 0, 0, .08);
  static const selChipIconSize = 16.0;
  static const selChipIconLine = 1.7333;
  static const selChipIconStroke = selChipIconLine * 24 / selChipIconSize;
  static const selChipInkOnDark = Color(0xffffffff);
  static const selChipShade = Color.fromRGBO(0, 0, 0, .64);
  static const selChipLightLuma = 150.0;
  // The text colour shown while the text has none. The preview draws the
  // chip #1f2329 (`.cc`, line 889, the floating bar's dot black) but its
  // colour pages' black is #1f2023, so no dot of the colour window matched
  // the chip; the chip takes the pages' black (3 apart in green and blue).
  static const textBarDefaultInk = Color(0xff1f2023);
  // `.kbar .num` (line 456): the size box, 50 x 40 white r11, 17 px, 3 on
  // each side; open, a 1.5 blue inner ring (`.num.on`, line 495)
  static const selNumWidth = 50.0;
  static const selNumHeight = 40.0;
  static const selNumRadius = 11.0;
  static const selNumBg = Color(0xffffffff);
  static const selNumFontSize = 17.0;
  static const selNumMargin = 3.0;
  static const selNumOnRing = 1.5;
  // `.kpop` (lines 479-481): the format and list windows
  static const selPopBg = Color(0xfff2f2f4);
  static const selPopRadius = 14.0;
  static const selPopPadding = 5.0;
  static const selPopGap = 2.0;
  static const selPopButtonWidth = 40.0;
  static const selPopButtonHeight = 36.0;
  static const selPopButtonRadius = 10.0;
  static const selPopFontSize = 15.0;
  static const selPopOnFill = Color(0xffeef0f3);
  // `0 10px 24px -12px rgba(20,32,50,.4), 0 0 0 1px rgba(20,32,50,.06)`
  static const selPopShadow = [
    BoxShadow(
      color: Color.fromRGBO(20, 32, 50, .4),
      offset: Offset(0, 10),
      blurRadius: (24 / 2 - 0.5) / 0.57735,
      spreadRadius: -12,
    ),
    BoxShadow(color: Color.fromRGBO(20, 32, 50, .06), spreadRadius: 1),
  ];
  // `.kmenu` (lines 482-505): the object menus (name left, icon right),
  // groups 7 apart on the grey; the lasso's is 250 wide (line 912)
  static const objMenuWidth = 240.0;
  static const objMenuLassoWidth = 250.0;
  static const objMenuBg = Color(0xffececef);
  static const objMenuRadius = 16.0;
  static const objMenuGroupGap = 7.0;
  static const objMenuRowHeight = 42.0;
  static const objMenuPadH = 14.0;
  static const objMenuGap = 10.0;
  static const objMenuIconGap = 4.0;
  static const objMenuFontSize = 13.0;
  static const objMenuLineHeight = 1.35;
  static const objMenuInk = Color(0xff141416);
  static const objMenuIconInk = Color(0xff2a2f3a);
  static const objMenuDisabledInk = Color(0xffb7bcc5);
  static const objMenuDisabledIcon = Color(0xffc6cad1);
  // `.kmenu svg.ic` 26 at `.kz`'s 1.4875 (lines 447-448)
  static const objMenuIconSize = 26.0;
  static const objMenuIconLine = 1.4875;
  static const objMenuIconStroke = objMenuIconLine * 24 / objMenuIconSize;
  // `.kmenu .it.ps` (lines 502-504): a row with a line under its name
  static const objMenuNotePadV = 8.0;
  static const objMenuNoteGap = 2.0;
  // `0 16px 36px -16px rgba(20,32,50,.45), 0 0 0 1px rgba(20,32,50,.06)`
  static const objMenuShadow = [
    BoxShadow(
      color: Color.fromRGBO(20, 32, 50, .45),
      offset: Offset(0, 16),
      blurRadius: (36 / 2 - 0.5) / 0.57735,
      spreadRadius: -16,
    ),
    BoxShadow(color: Color.fromRGBO(20, 32, 50, .06), spreadRadius: 1),
  ];
  // `.kmenu.fsz` (lines 496-500): the size list, 128 wide, rows 35 at 15 px,
  // at most 280 high
  static const sizeListWidth = 128.0;
  static const sizeListMaxHeight = 280.0;
  static const sizeListRowHeight = 35.0;
  static const sizeListFontSize = 15.0;
  // Where the windows open under the bar, from the button's left edge, as
  // drawn: format and list 35 to the left (lines 893-894), the text ⋯ 27
  // (line 896), the lasso ⋯ 61 (line 912); the size list centred on the box
  // (line 2950).
  static const selPopShift = 35.0;
  static const textMenuShift = 27.0;
  static const lassoMenuShift = 61.0;
  // 「글자 하이라이트」 when the text has none: the pastel yellow of the colour
  // pages (no preview value; our choice)
  static const textHighlight = Color(0xfffdffb6);
  // The colour windows of the two bars: the pen panel's colour row without
  // the eyedropper (one 22 slot and its 4 gap), so the space right of the
  // palette is the pen panel's
  static const selColourWindowWidth =
      penPanelWidth - swatchToolGap - colorDot;
  // The format window's U and S (`.kpop .b` underline / line-through, Noto
  // Sans KR 700 15 px measured in the 1-2 capture at scale 2): a 1.5 line as
  // wide as the letter, the underline 1 under the baseline, the strike line
  // 6.5 over it
  static const selPopLetterLine = 1.5;
  static const selPopUnderlineGap = 1.0;
  static const selPopStrikeRise = 6.5;
  // The link window (preview `.pmlk`, line 470): 300 wide, 12 and 14 in, the
  // title by the link icon 8 apart, the field and the buttons 10 under,
  // a #f3f4f6 field 42 high with #2b3140 text, buttons 36 high 16 in
  static const linkWindowWidth = 300.0;
  static const linkWindowRadius = 18.0;
  static const linkWindowPadH = 14.0;
  static const linkWindowPadV = 12.0;
  static const linkWindowGap = 10.0;
  static const linkWindowHeadGap = 8.0;
  static const linkFieldHeight = 42.0;
  static const linkFieldRadius = 12.0;
  static const linkFieldPadH = 12.0;
  static const linkFieldBg = Color(0xfff3f4f6);
  static const linkFieldInk = Color(0xff2b3140);
  static const linkButtonHeight = 36.0;
  static const linkButtonPadH = 16.0;
  static const linkButtonRadius = 12.0;
  static const linkButtonGap = 8.0;
  // `0 16px 34px -16px rgba(20,32,50,.45), 0 0 0 1px rgba(20,32,50,.06)`
  static const linkWindowShadow = [
    BoxShadow(
      color: Color.fromRGBO(20, 32, 50, .45),
      offset: Offset(0, 16),
      blurRadius: (34 / 2 - 0.5) / 0.57735,
      spreadRadius: -16,
    ),
    BoxShadow(color: Color.fromRGBO(20, 32, 50, .06), spreadRadius: 1),
  ];

  // The eraser and lasso windows of the 10th draft (preview-v10.html 1-d,
  // `#eraser10`, lines 4518-4550): the pen panel's width and corner on the
  // menu window's colour and shadow (`.e10o`), the text in `.kz`'s 1.35
  // lines. A nub, 14 square turned 45 degrees, rides 6 over the top edge
  // with its middle at the opening button's, at least 24 from the window's
  // sides, a 3 corner at its tip and a -1 -1 line in rgba(20,32,50,.06).
  static const toolWindowNub = 14.0;
  static const toolWindowNubOver = 6.0;
  static const toolWindowNubCorner = 3.0;
  static const toolWindowNubInset = 24.0;
  static const toolWindowNubEdge = Color.fromRGBO(20, 32, 50, .06);
  // A window sliding inside its room fades its last 28 while there is more
  // below (10th draft fix 1, `.e10in.more` mask)
  static const popoverScrollFade = 28.0;
  // opened 10 under the floating bar button (`mount(…, 10)`), 6 under the
  // toolbar button, which is the toolbar's foot (`mount(…, 6)`)
  static const toolWindowGapBar = 10.0;
  static const toolWindowGapToolbar = 6.0;
  static const toolWindowLine = 1.35;
  static const toolWindowPadH = 16.0;
  static const toolWindowPadBottom = 8.0; // `.e10in` padding 0 0 8px
  // `.ttl`: 600 15 on 1.3, padding 16 16 6
  static const toolWindowTitleSize = 15.0;
  static const toolWindowTitleHeight = 1.3;
  static const toolWindowTitlePadTop = 16.0;
  static const toolWindowTitlePadBottom = 6.0;
  // `.gt`: 600 12 in `--k-sub`, padding 10 16 2
  static const toolWindowGroupSize = 12.0;
  static const toolWindowGroupPadTop = 10.0;
  static const toolWindowGroupPadBottom = 2.0;
  // `.e10cards` padding 6 12 4, 6 apart; `.e10card` 76 high at least,
  // padding 10 4 8, its icon 28 (on screen 1.6) 6 over its 12.5 name on
  // 1.3, corner 14; chosen: white, `--k-ink`, 600, `0 1px 3px
  // rgba(20,32,50,.1)`; else no fill and `--k-sub`
  static const toolCardsPadTop = 6.0;
  static const toolCardsPadH = 12.0;
  static const toolCardsPadBottom = 4.0;
  static const toolCardsGap = 6.0;
  static const toolCardHeight = 76.0;
  static const toolCardPadTop = 10.0;
  static const toolCardPadH = 4.0;
  static const toolCardPadBottom = 8.0;
  static const toolCardGap = 6.0;
  static const toolCardRadius = 14.0;
  static const toolCardIconSize = 28.0;
  static const toolCardIconStroke = 1.6 * 24 / toolCardIconSize;
  static const toolCardTextSize = 12.5;
  static const toolCardTextHeight = 1.3;
  static const toolCardOnBg = Color(0xffffffff);
  static const toolCardShadow = [
    BoxShadow(
      color: Color.fromRGBO(20, 32, 50, .1),
      offset: Offset(0, 1),
      blurRadius: (3 / 2 - 0.5) / 0.57735,
    ),
  ];
  // `.e10help` 12 on 1.45 in `--k-sub`, padding 6 16 6 centred, or 6 16 10
  // from the left (`.l`)
  static const toolHelpSize = 12.0;
  static const toolHelpHeight = 1.45;
  static const toolHelpPadTop = 6.0;
  static const toolHelpPadBottom = 6.0;
  static const toolHelpPadBottomLeft = 10.0;
  // `.e10row` 44 high, 16 in, 12 between the icon (`.kz svg.ic` 22), the
  // name in 14 and the switch
  static const toolRowHeight = 44.0;
  static const toolRowGap = 12.0;
  static const toolRowTextSize = 14.0;
  // `.e10line` a 1 #e1e3e8 line, 6 over and 2 under
  static const toolLineColor = Color(0xffe1e3e8);
  static const toolLineTop = 6.0;
  static const toolLineBottom = 2.0;
  // `.e10msg` 12 on 1.4 in `--k-red`, padding 2 16 8; `.e10note` 12 in
  // `--k-sub`, padding 0 16 4; `.e10red` 44 high, 400 14 on 1
  static const toolMsgHeight = 1.4;
  static const toolMsgPadTop = 2.0;
  static const toolMsgPadBottom = 8.0;
  static const toolNotePadBottom = 4.0;

  // The eraser bar of the 10th draft (`.fbar .e10chip`, `.e10adv`,
  // `.e10sz`, lines 4517-4527). The kind chip: 32 high, 64 wide at least,
  // white, corner 9, a 1 #e4e4e8 line inside (1.5 #aab0ba while its window is
  // open), 6 in before and 8 after, 4 between its icon (22 at 1.4875), its
  // name (600 13) and its caret, an 8 x 5 triangle at .75 after 2 more.
  static const eraserChipHeight = 32.0;
  static const eraserChipMinWidth = 64.0;
  static const eraserChipRadius = 9.0;
  static const eraserChipBg = Color(0xffffffff);
  static const eraserChipEdge = Color(0xffe4e4e8);
  static const eraserChipOpenEdge = Color(0xffaab0ba);
  static const eraserChipOpenEdgeWidth = 1.5;
  static const eraserChipPadStart = 6.0;
  static const eraserChipPadEnd = 8.0;
  static const eraserChipGap = 4.0;
  static const eraserChipIconSize = 22.0;
  static const eraserChipIconStroke = 1.4875 * 24 / eraserChipIconSize;
  static const eraserChipTextSize = 13.0;
  static const eraserChipCaretWidth = 8.0;
  static const eraserChipCaretHeight = 5.0;
  static const eraserChipCaretGap = 2.0;
  static const eraserChipCaretOpacity = 0.75;
  // 「고급 설정」 while its window is open: #e4e4e8
  static const eraserAdvancedOpenFill = Color(0xffe4e4e8);
  // The three sizes, shortcuts to the slider's 10, 40 and 80: circles 10,
  // 15 and 20 across with a 1.7 #8a909b line inside on a checker of 3
  // squares #fff and #ececef; the size in hand ringed 2 #f2f2f4 then 2
  // in the accent outside it
  static const eraserSizePresets = [10, 40, 80];
  static const eraserSizeCircles = [10.0, 15.0, 20.0];
  static const eraserSizeEdge = Color(0xff8a909b);
  static const eraserSizeEdgeWidth = 1.7;
  static const eraserSizeChecker = Color(0xffececef);
  static const eraserSizeCheckerSquare = 3.0;
  static const eraserSizeRingGap = 2.0;
  static const eraserSizeRingWidth = 2.0;

  // The tab row of the 9th draft c (`#c9tabs`; CSS `.tabs`, lines 90-95 of
  // the 2026-11-18 preview): home · the tabs (⌄ on the open one, × on
  // each) · +, 36 high on `--app-bar`.
  static const tabRowHeight = 36.0;
  static const tabRowBg = Color(0xff23407b); // `--app-bar`
  static const tabRowPadding = 6.0; // padding 0 6px
  static const tabRowGap = 2.0; // gap 2px
  // `.tabs .t`: 5 under the row's top, rounded 8 on top, padding 0 10,
  // 12px text at .72, children 6 apart, at most 190 wide; the open one on
  // `--app-bar-2` (the toolbar's blue), its text 600 and full
  static const tabTop = 5.0;
  static const tabRadius = 8.0;
  static const tabPaddingH = 10.0;
  static const tabGap = 6.0;
  static const tabMaxWidth = 190.0;
  static const tabFontSize = 12.0;
  static const tabIdleOpacity = 0.72;
  static const tabOnFill = toolbarBg;
  // `.tabs .t svg.ic`: 16 with a 1.0625 line; × at .7
  static const tabIconSize = 16.0;
  static const tabIconLine = 1.0625;
  static const tabIconStroke = tabIconLine * 24 / tabIconSize;
  static const tabCloseOpacity = 0.7;
  // ⌄ and × are drawn at 16 but pressed over 36 x the tab (code review
  // Minor 10; no preview value: the row's height, as near the kit 44 as
  // the 36 row allows)
  static const tabHit = 36.0;
  // `.tcv` (line 4227 on): rounded 6, white 18 % while its window is open
  static const tabMenuRadius = 6.0;
  static const tabMenuOpenFill = editorToolbarOpenFill;
  // its window: 4 under the ⌄, 236 wide (`.c9o .kpanel`)
  static const tabMenuGap = 4.0;
  static const tabMenuWidth = 236.0;
  // `.tabs>span` (home, +): the plain 22 icon with its 1.558 line, padding
  // 0 6, at .9
  static const tabEndIconSize = 22.0;
  static const tabEndIconLine = 1.558;
  static const tabEndIconStroke = tabEndIconLine * 24 / tabEndIconSize;
  static const tabEndPaddingH = 6.0;
  static const tabEndOpacity = 0.9;
}
