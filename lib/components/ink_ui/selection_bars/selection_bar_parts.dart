import 'package:flutter/material.dart';

import 'package:saber/components/ink_ui/pen_panel/pen_panel_common.dart';
import 'package:saber/components/kit/kit_icon.dart';
import 'package:saber/components/kit/kit_popover.dart';
import 'package:saber/components/kit/kit_text.dart';
import 'package:saber/components/kit/kit_tokens.dart';

/// The parts the text box bar and the lasso bar share (preview-v9c 1-2): the
/// colour chip, the windows that open under the bar and the object menu.

/// A zero-size box at the foot of the bar, [left] from the left edge of the
/// button it stands in, for a window to open under the bar from there.
/// [foot] is how far the bar's foot is under the button's own foot.
Widget selectionWindowAnchor({
  required GlobalKey anchor,
  required Widget button,
  required double left,
  double foot = KitTokens.selBarPaddingV,
}) => Stack(
  clipBehavior: Clip.none,
  children: [
    button,
    Positioned(
      left: left,
      bottom: -foot,
      width: 0,
      height: 0,
      child: SizedBox(key: anchor),
    ),
  ],
);

/// The colour chip (`.kbar .b` with `.cc`, lines 451 and 457): a 30 dot of
/// [colour] with a ▾ in a 44 button. No [onPressed]: dimmed.
class SelectionColourChip extends StatelessWidget {
  const new({
    super.key,
    required this.colour,
    required this.label,
    this.onPressed,
    this.selected = false,
  });

  final Color colour;
  final String label;
  final VoidCallback? onPressed;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final luma =
        255 * (0.2126 * colour.r + 0.7152 * colour.g + 0.0722 * colour.b);
    final ink = luma > KitTokens.selChipLightLuma
        ? Color.alphaBlend(KitTokens.selChipShade, colour)
        : KitTokens.selChipInkOnDark;
    final shape = BorderRadius.circular(KitTokens.selBarButtonRadius);
    return Semantics(
      button: true,
      enabled: onPressed != null,
      selected: selected,
      label: label,
      onTap: onPressed,
      excludeSemantics: true,
      child: Tooltip(
        message: label,
        child: Opacity(
          opacity: onPressed == null ? KitTokens.disabledOpacity : 1,
          child: SizedBox.square(
            dimension: KitTokens.selBarButton,
            child: Material(
              color: selected ? KitTokens.selBarOnFill : Colors.transparent,
              borderRadius: shape,
              child: InkWell(
                borderRadius: shape,
                onTap: onPressed,
                child: Center(
                  child: SizedBox.square(
                    dimension: KitTokens.selChip,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: colour,
                        shape: BoxShape.circle,
                        border: Border.all(color: KitTokens.selChipEdge),
                      ),
                      child: Center(
                        child: KitIcon(
                          KitIconName.chev,
                          size: KitTokens.selChipIconSize,
                          strokeWidth: KitTokens.selChipIconStroke,
                          color: ink,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Opens a colour row in a pen panel window under [anchor], as the floating
/// bar's colour window, as narrow as a row without the eyedropper.
Future<void> showSelectionColours({
  required BuildContext context,
  required GlobalKey anchor,
  required WidgetBuilder row,
}) => showKitPopover<void>(
  context: context,
  anchor: anchor,
  builder: (context) => TextFieldTapRegion(
    child: PenPanelSurface(
      width: KitTokens.selColourWindowWidth,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          KitTokens.penPanelPadH,
          KitTokens.penPanelRowsTop,
          KitTokens.penPanelPadH,
          KitTokens.penPanelPadBottom -
              (KitTokens.pageDotHitZone - KitTokens.pageDot) / 2,
        ),
        child: row(context),
      ),
    ),
  ),
);

/// Opens a small row of buttons under [anchor] (`.kpop`, lines 479-481).
Future<void> showSelectionPop({
  required BuildContext context,
  required GlobalKey anchor,
  required WidgetBuilder buttons,
}) => showKitPopover<void>(
  context: context,
  anchor: anchor,
  radius: BorderRadius.circular(KitTokens.selPopRadius),
  shadows: KitTokens.selPopShadow,
  border: false,
  builder: (context) => TextFieldTapRegion(
    child: ColoredBox(
      color: KitTokens.selPopBg,
      child: Padding(
        padding: const EdgeInsets.all(KitTokens.selPopPadding),
        child: buttons(context),
      ),
    ),
  ),
);

/// A button of a [showSelectionPop] window: 40 x 36, a letter or an icon.
class SelectionPopButton extends StatelessWidget {
  const new({
    super.key,
    required this.label,
    required this.on,
    required this.onPressed,
    this.letter,
    this.letterStyle,
    this.icon,
  });

  final String label;
  final bool on;
  final VoidCallback onPressed;
  final String? letter;
  final TextStyle? letterStyle;
  final KitIconName? icon;

  @override
  Widget build(BuildContext context) {
    final shape = BorderRadius.circular(KitTokens.selPopButtonRadius);
    return Semantics(
      button: true,
      selected: on,
      label: label,
      onTap: onPressed,
      excludeSemantics: true,
      child: SizedBox(
        width: KitTokens.selPopButtonWidth,
        height: KitTokens.selPopButtonHeight,
        child: Material(
          color: on ? KitTokens.selPopOnFill : Colors.transparent,
          borderRadius: shape,
          child: InkWell(
            borderRadius: shape,
            onTap: onPressed,
            child: Center(
              child: icon != null
                  ? KitIcon(
                      icon!,
                      size: KitTokens.menuIconSize,
                      strokeWidth: KitTokens.menuIconStroke,
                      color: KitTokens.selBarInk,
                    )
                  : _PopLetter(
                      letter ?? '',
                      const TextStyle(
                        fontSize: KitTokens.selPopFontSize,
                        fontWeight: FontWeight.w700,
                        color: KitTokens.selBarInk,
                        letterSpacing: 0,
                        decoration: TextDecoration.none,
                      ).merge(letterStyle),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A letter of a [showSelectionPop] window. Its underline or strike line is
/// drawn here at the preview's place (the font's own lines sit elsewhere in
/// each font): 1.5 thick and as wide as the letter, the underline 1 under
/// the baseline, the strike line 6.5 over it.
class _PopLetter extends StatelessWidget {
  const new(this.letter, this.style);

  final String letter;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final decoration = style.decoration ?? TextDecoration.none;
    final plain = style.copyWith(decoration: TextDecoration.none);
    final text = Text(letter, style: plain);
    final under = decoration.contains(TextDecoration.underline);
    final through = decoration.contains(TextDecoration.lineThrough);
    if (!under && !through) return text;
    final painter = TextPainter(
      text: TextSpan(
        text: letter,
        style: DefaultTextStyle.of(context).style.merge(plain),
      ),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    final baseline = painter.computeDistanceToActualBaseline(
      TextBaseline.alphabetic,
    );
    final width = painter.width;
    painter.dispose();
    Widget line(double top) => Positioned(
      left: 0,
      top: top,
      width: width,
      height: KitTokens.selPopLetterLine,
      child: ColoredBox(color: style.color ?? KitTokens.selBarInk),
    );
    return Stack(
      clipBehavior: Clip.none,
      children: [
        text,
        if (under) line(baseline + KitTokens.selPopUnderlineGap),
        if (through) line(baseline - KitTokens.selPopStrikeRise),
      ],
    );
  }
}

/// A row of an object menu (`.kmenu .it`): the name at the left, the icon at
/// the right. [note] is a line under the name (`.it.ps`); [opens] puts a ›
/// after the icon and [submenu] opens those rows beside the menu; [checked]
/// is the choice in use (bold, a blue check). No [onTap] and no [submenu]:
/// dimmed.
class SelectionMenuRow {
  const new({
    required this.label,
    this.icon,
    this.note,
    this.onTap,
    this.submenu,
    this.danger = false,
    this.checked = false,
    this.key,
  });

  final String label;
  final KitIconName? icon;
  final String? note;
  final VoidCallback? onTap;
  final List<SelectionMenuRow>? submenu;
  final bool danger;
  final bool checked;
  final Key? key;

  bool get enabled => onTap != null || submenu != null;
}

/// Opens an object menu under [anchor] (`.kmenu`, lines 482-505): white
/// groups 7 apart on grey. A row's action runs after the menu (and an open
/// submenu) closed.
Future<void> showSelectionMenu({
  required BuildContext context,
  required GlobalKey anchor,
  required List<List<SelectionMenuRow>> groups,
  double width = KitTokens.objMenuWidth,
  double rowHeight = KitTokens.objMenuRowHeight,
  double fontSize = KitTokens.objMenuFontSize,
  double? maxHeight,
  double initialScroll = 0,
}) => showKitPopover<void>(
  context: context,
  anchor: anchor,
  radius: BorderRadius.circular(KitTokens.objMenuRadius),
  shadows: KitTokens.objMenuShadow,
  border: false,
  builder: (context) => TextFieldTapRegion(
    child: SelectionMenu(
      groups: groups,
      width: width,
      rowHeight: rowHeight,
      fontSize: fontSize,
      maxHeight: maxHeight,
      initialScroll: initialScroll,
    ),
  ),
);

/// The body of [showSelectionMenu].
class SelectionMenu extends StatefulWidget {
  const new({
    super.key,
    required this.groups,
    this.width = KitTokens.objMenuWidth,
    this.rowHeight = KitTokens.objMenuRowHeight,
    this.fontSize = KitTokens.objMenuFontSize,
    this.maxHeight,
    this.initialScroll = 0,
    this.isSubmenu = false,
  });

  final List<List<SelectionMenuRow>> groups;
  final double width;
  final double rowHeight;
  final double fontSize;

  /// The list scrolls inside this height (the size list).
  final double? maxHeight;
  final double initialScroll;

  /// The window a › row opens (`.ksub`): one white list, rows 40.
  final bool isSubmenu;

  @override
  State<SelectionMenu> createState() => _SelectionMenuState();
}

class _SelectionMenuState extends State<SelectionMenu> {
  late final _scroll = ScrollController(
    initialScrollOffset: widget.initialScroll,
  );
  final _subAnchors = <(int, int), GlobalKey>{};

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Closes this window (and the menu under a submenu), then acts.
  void _run(SelectionMenuRow row) {
    final navigator = Navigator.of(context);
    navigator.pop();
    if (widget.isSubmenu) navigator.pop();
    row.onTap!();
  }

  void _openSubmenu(SelectionMenuRow row, GlobalKey anchor) {
    // opens to the left of the menu, its first row level with this one
    // (preview `placeSub`, line 2941)
    showKitPopover<void>(
      context: context,
      anchor: anchor,
      grow: AxisDirection.left,
      radius: BorderRadius.circular(KitTokens.subMenuRadius),
      shadows: KitTokens.subMenuShadow,
      border: false,
      builder: (context) => TextFieldTapRegion(
        child: SelectionMenu(
          groups: [row.submenu!],
          width: KitTokens.subMenuWidth,
          rowHeight: KitTokens.subMenuRowHeight,
          isSubmenu: true,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final groups = <Widget>[];
    for (final (g, rows) in widget.groups.indexed) {
      if (rows.isEmpty) continue;
      if (groups.isNotEmpty) {
        groups.add(const SizedBox(height: KitTokens.objMenuGroupGap));
      }
      groups.add(
        ColoredBox(
          color: KitTokens.menuGroupBg,
          child: Padding(
            padding: EdgeInsets.symmetric(
              vertical: widget.isSubmenu ? KitTokens.subMenuPadV : 0,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (i, row) in rows.indexed)
                  _row(row, (g, i), line: i > 0 && !widget.isSubmenu),
              ],
            ),
          ),
        ),
      );
    }
    Widget body = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: groups,
    );
    if (widget.maxHeight != null) {
      body = ConstrainedBox(
        constraints: BoxConstraints(maxHeight: widget.maxHeight!),
        child: SingleChildScrollView(controller: _scroll, child: body),
      );
    }
    return ColoredBox(
      color: widget.isSubmenu ? KitTokens.menuGroupBg : KitTokens.objMenuBg,
      child: SizedBox(width: widget.width, child: body),
    );
  }

  Widget _row(SelectionMenuRow row, (int, int) at, {required bool line}) {
    final enabled = row.enabled;
    final ink = !enabled
        ? KitTokens.objMenuDisabledInk
        : row.danger
        ? KitTokens.danger
        : KitTokens.objMenuInk;
    final iconInk = !enabled
        ? KitTokens.objMenuDisabledIcon
        : row.danger
        ? KitTokens.danger
        : row.checked
        ? KitTokens.accent
        : KitTokens.objMenuIconInk;
    KitIcon icon(KitIconName name) => KitIcon(
      name,
      size: KitTokens.objMenuIconSize,
      strokeWidth: KitTokens.objMenuIconStroke,
      color: iconInk,
    );
    final name = KitText(
      row.label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: widget.fontSize,
        height: KitTokens.objMenuLineHeight,
        fontWeight: row.checked ? FontWeight.w600 : FontWeight.w400,
        color: ink,
        letterSpacing: 0,
        decoration: TextDecoration.none,
      ),
    );
    final icons = [
      if (row.checked) icon(KitIconName.check),
      if (row.icon case final shown?) icon(shown),
      if (row.submenu != null) icon(KitIconName.chevR),
    ];
    final body = ConstrainedBox(
      constraints: BoxConstraints(minHeight: widget.rowHeight),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: line
              ? const Border(
                  top: BorderSide(
                    color: KitTokens.menuLine,
                    width: KitTokens.menuLineWidth,
                  ),
                )
              : null,
        ),
        child: Padding(
          // a CSS border takes room; a Flutter one does not
          padding: EdgeInsets.fromLTRB(
            widget.isSubmenu
                ? KitTokens.subMenuPaddingH
                : KitTokens.objMenuPadH,
            (line ? KitTokens.menuLineWidth : 0) +
                (row.note == null ? 0 : KitTokens.objMenuNotePadV),
            widget.isSubmenu
                ? KitTokens.subMenuPaddingH
                : KitTokens.objMenuPadH,
            row.note == null ? 0 : KitTokens.objMenuNotePadV,
          ),
          child: Row(
            spacing: KitTokens.objMenuGap,
            children: [
              Expanded(
                child: row.note == null
                    ? name
                    // on the CSS lines (13 x 1.35, 11 x 1.35), not rounded
                    // to whole pixels: the row is 65.25 high as in CSS
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        spacing: KitTokens.objMenuNoteGap,
                        children: [
                          KitLines(row.label, style: name.style),
                          KitLines(
                            row.note!,
                            style: TextStyle(
                              fontSize: KitTokens.menuSubSize,
                              height: KitTokens.objMenuLineHeight,
                              color: enabled
                                  ? KitTokens.menuSub
                                  : KitTokens.objMenuDisabledIcon,
                              letterSpacing: 0,
                              decoration: TextDecoration.none,
                            ),
                          ),
                        ],
                      ),
              ),
              if (icons.isNotEmpty)
                ExcludeSemantics(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    spacing: KitTokens.objMenuIconGap,
                    children: icons,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    final anchor = row.submenu == null
        ? null
        : _subAnchors.putIfAbsent(at, GlobalKey.new);
    final VoidCallback? tap = row.submenu != null
        ? () => _openSubmenu(row, anchor!)
        : row.onTap == null
        ? null
        : () => _run(row);
    final cell = Semantics(
      key: row.key,
      button: true,
      enabled: enabled,
      selected: row.checked ? true : null,
      label: row.label,
      onTap: tap,
      excludeSemantics: true,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(onTap: tap, child: body),
      ),
    );
    if (anchor == null) return cell;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        cell,
        Positioned(
          left: -KitTokens.submenuGap,
          top: -KitTokens.subMenuPadV,
          width: 0,
          height: 0,
          child: SizedBox(key: anchor),
        ),
      ],
    );
  }
}
