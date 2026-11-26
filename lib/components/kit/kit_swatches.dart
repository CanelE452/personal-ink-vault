import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:saber/components/kit/kit_icon.dart';
import 'package:saber/components/kit/kit_motion.dart';
import 'package:saber/components/kit/kit_text.dart';
import 'package:saber/components/kit/kit_tokens.dart';

/// Colour dots in pages, with page dots under them, laid out like the pen
/// panel's colour row (preview `.snp .sncolors` and `.pdots`, lines 589-607):
/// a page holds up to eight dots in a 218 wide area from the left edge, then
/// the eyedropper and the palette, 4 apart, so the row is 270 wide. The
/// chosen ring may reach 3.5 past the left edge. The pages may differ in size.
/// One page: no page dots. A tool button is drawn only when its callback is
/// given.
class KitSwatches extends StatefulWidget {
  const new({
    super.key,
    required this.pages,
    required this.selected,
    required this.onSelected,
    this.onLongPressColor,
    this.onEyedropper,
    this.onPalette,
    this.initialPage = 0,
    this.pageNames,
    this.pageHints,
    this.note,
    this.pinned = const {},
    this.isSelected,
    this.colourLabel,
  });

  final List<List<Color>> pages;
  final Color? selected;
  final ValueChanged<Color> onSelected;
  final ValueChanged<Color>? onLongPressColor;
  final VoidCallback? onEyedropper;
  final VoidCallback? onPalette;

  /// The page shown first.
  final int initialPage;

  /// One name per page, shown at the left of the page dots.
  final List<String>? pageNames;

  /// A short line per page (or null), shown at the right of the page dots.
  final List<String?>? pageHints;

  /// Shown for a moment in the page name's place (preview `cpNote`).
  final String? note;

  /// Colours drawn with the pinned badge.
  final Set<Color> pinned;

  /// Which dots of a page get the chosen ring; by default the one equal to
  /// [selected].
  final bool Function(int page, Color colour)? isSelected;

  /// A dot's name for screen readers; by default its colour as #rrggbb.
  final String Function(int page, int index, Color colour)? colourLabel;

  @override
  State<KitSwatches> createState() => _KitSwatchesState();
}

class _KitSwatchesState extends State<KitSwatches> {
  /// How far the chosen ring reaches past a dot.
  static const _ring = KitTokens.swatchRingGap + KitTokens.swatchRingWidth;

  /// From the row's foot to the centre of the page dots.
  static const _dotsCentre = KitTokens.pageDotTop + KitTokens.pageDot / 2;

  late PageController _pages;
  late int _page;

  @override
  void initState() {
    super.initState();
    final last = widget.pages.length - 1;
    _page = last < 0 ? 0 : widget.initialPage.clamp(0, last);
    _pages = PageController(initialPage: _page);
  }

  @override
  void didUpdateWidget(KitSwatches old) {
    super.didUpdateWidget(old);
    final count = widget.pages.length;
    if (count == old.pages.length) return;
    // A page view keeps its old scroll extent when pages come or go (it is
    // measured again only on its next layout), so turning to a new page would
    // stop short. Start a new one on the page in view, or the last one.
    _page = count == 0 ? 0 : _page.clamp(0, count - 1);
    final previous = _pages;
    _pages = PageController(initialPage: _page);
    WidgetsBinding.instance.addPostFrameCallback((_) => previous.dispose());
  }

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  void _goTo(int page) {
    final d = KitMotion.of(context, KitMotionStep.normal);
    if (d == Duration.zero) {
      _pages.jumpToPage(page);
    } else {
      _pages.animateToPage(page, duration: d, curve: KitMotion.openCurve);
    }
  }

  @override
  Widget build(BuildContext context) {
    final count = widget.pages.length;
    final tools = <(KitIconName, VoidCallback, Widget)>[
      if (widget.onEyedropper != null)
        (
          KitIconName.eyedrop,
          widget.onEyedropper!,
          const KitIcon(
            KitIconName.eyedrop,
            size: KitTokens.penPanelIconSize,
            strokeWidth: KitTokens.penPanelIconStroke,
            color: KitTokens.swatchToolInk,
          ),
        ),
      if (widget.onPalette != null)
        (KitIconName.custom, widget.onPalette!, const _PaletteMark()),
    ];
    final row = SizedBox(
      height: KitTokens.swatchRowHeight,
      // The page area is drawn _ring wider on each side so the chosen ring is
      // not cut, and starts _ring before the left edge.
      child: OverflowBox(
        alignment: Alignment.centerLeft,
        minWidth: 0,
        maxWidth: double.infinity,
        child: Transform.translate(
          offset: const Offset(-_ring, 0),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: KitTokens.swatchPageWidth + 2 * _ring,
                child: PageView.builder(
                  key: ValueKey(count),
                  controller: _pages,
                  itemCount: count,
                  onPageChanged: (i) => setState(() => _page = i),
                  itemBuilder: (context, page) => Padding(
                    padding: const EdgeInsets.only(
                      left: _ring - KitTokens.swatchGap / 2,
                    ),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final (i, c) in widget.pages[page].indexed)
                            _Swatch(
                              color: c,
                              label:
                                  widget.colourLabel?.call(page, i, c) ??
                                  '#${_hex(c).substring(2)}',
                              selected:
                                  widget.isSelected?.call(page, c) ??
                                  widget.selected == c,
                              pinned: widget.pinned.contains(c),
                              onTap: () => widget.onSelected(c),
                              onLongPress: widget.onLongPressColor == null
                                  ? null
                                  : () => widget.onLongPressColor!(c),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              for (final (i, (icon, onTap, child)) in tools.indexed)
                _ToolButton(
                  icon: icon,
                  onTap: onTap,
                  // 4 after the page area (whose last _ring is ring room) or
                  // after the tool before it; the last one ends on the edge
                  left: i == 0
                      ? KitTokens.swatchToolGap - _ring
                      : KitTokens.swatchToolGap / 2,
                  right: i == tools.length - 1
                      ? 0
                      : KitTokens.swatchToolGap / 2,
                  child: child,
                ),
            ],
          ),
        ),
      ),
    );
    if (count < 2) return row;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            row,
            const SizedBox(height: _dotsCentre + KitTokens.pageDotHitZone / 2),
          ],
        ),
        Positioned(
          left: 0,
          right: 0,
          top:
              KitTokens.swatchRowHeight +
              _dotsCentre -
              KitTokens.pageDotHitZone / 2,
          height: KitTokens.pageDotHitZone,
          child: _dots(count),
        ),
      ],
    );
  }

  /// The page dots with the page's name (or the note) at their left and the
  /// page's hint at their right, all on the dots' centre line.
  Widget _dots(int count) {
    String? at(List<String?>? list) =>
        list != null && _page < list.length ? list[_page] : null;
    final names = widget.pageNames;
    String nameOf(int i) => names != null && i < names.length ? names[i] : '';
    final name = widget.note ?? at(names);
    final hint = at(widget.pageHints);
    const lineStyle = TextStyle(
      fontSize: KitTokens.pageNameSize,
      height: 1,
      color: KitTokens.menuSub,
      decoration: TextDecoration.none,
      fontWeight: FontWeight.w400,
    );
    // Presses up to half the band past the end dots count; the nearest dot
    // wins, so the dots keep their 11 px spacing.
    const reach = KitTokens.pageDotHitZone / 2 - KitTokens.pageDotHitWidth / 2;
    return Stack(
      alignment: Alignment.center,
      children: [
        if (name != null)
          Positioned(
            left: KitTokens.pageNameInset,
            top: 0,
            bottom: 0,
            child: Align(
              alignment: Alignment.centerLeft,
              child: KitText(
                name,
                maxLines: 1,
                softWrap: false,
                style: lineStyle,
              ),
            ),
          ),
        if (hint != null)
          Positioned(
            right: KitTokens.pageNameInset,
            top: 0,
            bottom: 0,
            child: Align(
              alignment: Alignment.centerRight,
              child: KitText(
                hint,
                maxLines: 1,
                softWrap: false,
                style: lineStyle,
              ),
            ),
          ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < count; i++)
              Semantics(
                key: Key('kit-swatch-page-dot-$i'),
                button: true,
                selected: i == _page,
                label: '색 ${i + 1}/$count쪽 ${nameOf(i)}'.trim(),
                onTap: () => _goTo(i),
                excludeSemantics: true,
                child: SizedBox(
                  width: KitTokens.pageDotHitWidth,
                  height: KitTokens.pageDotHitHeight,
                  child: Center(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: i == _page
                            ? KitTokens.pageDotOn
                            : KitTokens.pageDotOff,
                      ),
                      child: const SizedBox.square(
                        dimension: KitTokens.pageDot,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
        ExcludeSemantics(
          child: SizedBox(
            width: count * KitTokens.pageDotHitWidth + 2 * reach,
            height: KitTokens.pageDotHitZone,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (d) => _goTo(
                ((d.localPosition.dx - reach) / KitTokens.pageDotHitWidth)
                    .floor()
                    .clamp(0, count - 1),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

String _hex(Color c) => c.toARGB32().toRadixString(16).padLeft(8, '0');

/// The ring around a chosen dot: a gap in [gap], then [ring]. Box shadows are
/// painted in list order, so the outer ring comes first and the gap over it.
List<BoxShadow> _chosenRing(Color gap, Color ring) => [
  BoxShadow(
    color: ring,
    spreadRadius: KitTokens.swatchRingGap + KitTokens.swatchRingWidth,
  ),
  BoxShadow(color: gap, spreadRadius: KitTokens.swatchRingGap),
];

/// Rec. 709 luma of [c] on 0-255, as the preview's `lightC` (line 2267).
double _luma(Color c) => 255 * (0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b);

class _Swatch extends StatelessWidget {
  const new({
    required this.color,
    required this.label,
    required this.selected,
    required this.pinned,
    required this.onTap,
    required this.onLongPress,
  });

  final Color color;
  final String label;
  final bool selected;
  final bool pinned;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final luma = _luma(color);
    return Semantics(
      key: Key('kit-swatch-${_hex(color)}'),
      button: true,
      selected: selected,
      label: '$label${pinned ? ', 고정함' : ''}',
      onTap: onTap,
      onLongPress: onLongPress,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: KitTokens.swatchGap / 2,
            vertical: KitTokens.swatchHitPad,
          ),
          child: SizedBox.square(
            dimension: KitTokens.colorDot,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                      border: luma > KitTokens.swatchLightLuma
                          ? Border.all(color: KitTokens.swatchLightEdge)
                          : null,
                      boxShadow: selected
                          ? _chosenRing(
                              KitTokens.swatchRingGapColor,
                              KitTokens.swatchRing,
                            )
                          : null,
                    ),
                  ),
                ),
                if (pinned)
                  Positioned(
                    key: Key('kit-swatch-pin-${_hex(color)}'),
                    right: -KitTokens.swatchPinOffset,
                    top: -KitTokens.swatchPinOffset,
                    width: KitTokens.swatchPinBadge,
                    height: KitTokens.swatchPinBadge,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: KitTokens.swatchPinInk,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: KitTokens.swatchRingGapColor,
                            spreadRadius: luma < KitTokens.swatchDarkLuma
                                ? KitTokens.swatchPinRingDark
                                : KitTokens.swatchPinRing,
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ToolButton extends StatelessWidget {
  const new({
    required this.icon,
    required this.onTap,
    required this.left,
    required this.right,
    required this.child,
  });

  final KitIconName icon;
  final VoidCallback onTap;

  /// Room inside the button beside its mark.
  final double left;
  final double right;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: icon.label,
      onTap: onTap,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            left,
            KitTokens.swatchHitPad,
            right,
            KitTokens.swatchHitPad,
          ),
          child: child,
        ),
      ),
    );
  }
}

/// The colour wheel of 「색 만들기」 (`.pal`, the palette colours round from
/// 12 o'clock). CSS's conic-gradient starts at 12 o'clock, a sweep gradient
/// at 3 o'clock, so the wheel is turned back a quarter.
const kitColourWheel = SweepGradient(
  colors: KitTokens.swatchPaletteColors,
  transform: GradientRotation(-math.pi / 2),
);

/// The "make a colour" mark: the colour wheel with a red ring.
class _PaletteMark extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) {
    // the label is read from the button, not from here
    return ExcludeSemantics(
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: kitColourWheel,
          boxShadow: _chosenRing(
            KitTokens.swatchRingGapColor,
            KitTokens.swatchPaletteRing,
          ),
        ),
        child: const SizedBox.square(dimension: KitTokens.colorDot),
      ),
    );
  }
}
