import 'package:flutter/material.dart';

import 'package:saber/components/kit/kit_controls.dart';
import 'package:saber/components/kit/kit_icon.dart';
import 'package:saber/components/kit/kit_popover.dart';
import 'package:saber/components/kit/kit_text.dart';
import 'package:saber/components/kit/kit_tokens.dart';

part 'kit_menu_rows.dart';

/// The room above a row with [KitMenuRow.toggle]'s `lineAbove`.
const _lineGap = 4.0;

/// The editor toolbar's windows (preview 9th draft c `.c9o`): rows 44, lines
/// 1.35 (`.kz`), the title 13/1.3 grey (`.ttl`), submenus 206 (`.kpanel.w2`).
const _windowRow = 44.0;
const _windowLine = 1.35;
const _windowSubWidth = 206.0;
const _windowTitleStyle = TextStyle(
  fontSize: 13,
  height: 1.3,
  fontWeight: FontWeight.w600,
  color: KitTokens.menuSub,
  decoration: TextDecoration.none,
);

const _groupTitleStyle = TextStyle(
  fontSize: KitTokens.menuGroupTitleSize,
  fontWeight: FontWeight.w600,
  color: KitTokens.menuInk,
  decoration: TextDecoration.none,
);

/// Opens a menu under [anchor]; it grows from there (a [showKitPopover]).
///
/// Pass [menu] for a menu that never changes. Pass [builder] for one whose
/// rows show a value: it is called again after every toggle or segment press,
/// so the rows always show what the caller holds (a change the caller refused
/// shows the old value). The truth stays with the caller; the menu keeps no
/// copy.
///
/// With [within] (the screen) a menu longer than the room under [anchor]
/// stays in that room and slides inside, its foot fading while there is
/// more.
Future<void> showKitMenu({
  required BuildContext context,
  required GlobalKey anchor,
  KitMenu? menu,
  KitMenu Function()? builder,
  RenderBox? within,
}) {
  assert((menu == null) != (builder == null), 'give menu or builder');
  return showKitPopover<void>(
    context: context,
    anchor: anchor,
    shadows: KitTokens.menuShadow,
    border: false,
    within: within,
    builder: (_) => builder == null ? menu! : _LiveMenu(builder: builder),
  );
}

/// Builds the menu again after a row changed a value.
class _LiveMenu extends StatefulWidget {
  const new({required this.builder});

  final KitMenu Function() builder;

  @override
  State<_LiveMenu> createState() => _LiveMenuState();
}

class _LiveMenuState extends State<_LiveMenu> {
  @override
  Widget build(BuildContext context) {
    final menu = widget.builder();
    return KitMenu(
      title: menu.title,
      quick: menu.quick,
      quickAfter: menu.quickAfter,
      groups: menu.groups,
      width: menu.width,
      window: menu.window,
      isSubmenu: menu.isSubmenu,
      afterChange: () => setState(() {}),
    );
  }
}

/// The body of a menu window: optional title, quick buttons, then groups.
class KitMenu extends StatefulWidget {
  const new({
    super.key,
    this.title,
    this.quick = const [],
    this.quickAfter = 0,
    required this.groups,
    this.width = KitTokens.menuWidth,
    this.window = false,
    this.isSubmenu = false,
    this.afterChange,
  });

  final String? title;
  final List<KitMenuQuick> quick;

  /// How many of [groups] come before the quick buttons (the ⋯ document
  /// menu keeps its first group above them).
  final int quickAfter;

  final List<KitMenuGroup> groups;
  final double width;

  /// A window of the editor toolbar (preview 9th draft c `.c9o`): rows 44, no
  /// line over a first group under no title, a small grey title and group
  /// titles on fixed lines; its submenus are windows too (`.kpanel.w2`), and
  /// the row that opened one is not marked.
  final bool window;

  double get rowHeight => window ? _windowRow : KitTokens.menuRowHeight;

  /// The small window a submenu row opens (its own width and row size).
  final bool isSubmenu;

  /// Called after a toggle or segment row sent its change.
  final VoidCallback? afterChange;

  @override
  State<KitMenu> createState() => _KitMenuState();
}

class _KitMenuState extends State<KitMenu> {
  final _menuKey = GlobalKey();

  // Two invisible zero-width anchors per submenu row, one beside each edge of
  // the menu; the submenu window grows from the one on the side with room.
  final _left = <Object, GlobalKey>{};
  final _right = <Object, GlobalKey>{};

  Object? _openRow;

  // For a submenu row with a window top: beside the whole menu at that
  // height.
  final _menuLeft = <Object, GlobalKey>{};
  final _menuRight = <Object, GlobalKey>{};

  // Bumped when the caller hands in a new menu; an open submenu reads its
  // rows again from the current groups.
  final _tick = ValueNotifier<int>(0);

  double get _width => widget.isSubmenu ? KitTokens.subMenuWidth : widget.width;

  @override
  void didUpdateWidget(KitMenu old) {
    super.didUpdateWidget(old);
    // not now: the open submenu is built elsewhere in this same frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _tick.value++;
    });
  }

  @override
  void dispose() {
    _tick.dispose();
    super.dispose();
  }

  KitMenuRow? _current(Object id) {
    if (id case (final int g, final int r)) {
      if (g < widget.groups.length && r < widget.groups[g].rows.length) {
        return widget.groups[g].rows[r];
      }
    }
    return null;
  }

  void _openSubmenu(KitMenuRow row, Object id) {
    final menuBox = _menuKey.currentContext?.findRenderObject() as RenderBox?;
    final nav = Navigator.of(context).context.findRenderObject() as RenderBox?;
    if (menuBox == null || nav == null || row is! _KitMenuSubmenu) return;
    final left = menuBox.localToGlobal(Offset.zero, ancestor: nav).dx;
    final window = widget.window;
    final fitsLeft =
        left -
            KitTokens.submenuGap -
            (window ? _windowSubWidth : KitTokens.subMenuWidth) >=
        KitTokens.popoverEdgeGap;
    setState(() => _openRow = id);
    final byMenu = row.windowTop != null;
    showKitPopover<void>(
      context: context,
      anchor: (byMenu
          ? (fitsLeft ? _menuLeft : _menuRight)
          : (fitsLeft ? _left : _right))[id]!,
      grow: fitsLeft ? AxisDirection.left : AxisDirection.right,
      radius: BorderRadius.circular(
        window ? KitTokens.penPanelRadius : KitTokens.subMenuRadius,
      ),
      shadows: window ? KitTokens.menuShadow : KitTokens.subMenuShadow,
      border: false,
      builder: (_) => ValueListenableBuilder<int>(
        valueListenable: _tick,
        builder: (_, _, _) {
          final now = _current(id);
          return KitMenu(
            isSubmenu: !window,
            window: window,
            width: _windowSubWidth,
            afterChange: widget.afterChange,
            groups: [
              KitMenuGroup(
                rows: now is _KitMenuSubmenu ? now.children : row.children,
              ),
            ],
          );
        },
      ),
    ).whenComplete(() {
      if (mounted && _openRow == id) setState(() => _openRow = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    if (widget.title != null) {
      children.add(
        Padding(
          padding: widget.window
              ? const EdgeInsets.fromLTRB(16, 12, 16, 6)
              : const EdgeInsets.fromLTRB(
                  KitTokens.menuTitlePadH,
                  KitTokens.menuTitlePadTop,
                  KitTokens.menuTitlePadH,
                  KitTokens.menuTitlePadBottom,
                ),
          // a window's lines keep CSS heights whatever fonts draw them
          child: widget.window
              ? KitText(
                  widget.title!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _windowTitleStyle,
                )
              : Text(
                  widget.title!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: KitTokens.menuTitleSize,
                    fontWeight: FontWeight.w600,
                    color: KitTokens.menuInk,
                    decoration: TextDecoration.none,
                  ),
                ),
        ),
      );
    }
    // under a group, the quick row keeps the grey room above it that it
    // keeps below
    Widget quickRow(bool underGroup) => Padding(
      padding: EdgeInsets.fromLTRB(
        KitTokens.menuQuickPadH,
        underGroup ? KitTokens.menuQuickPadBottom : 0,
        KitTokens.menuQuickPadH,
        KitTokens.menuQuickPadBottom,
      ),
      child: Column(
        spacing: KitTokens.menuQuickGap,
        children: [
          for (var i = 0; i < widget.quick.length; i += 2)
            Row(
              spacing: KitTokens.menuQuickGap,
              children: [
                Expanded(
                  child: _QuickButton(
                    widget.quick[i],
                    key: widget.quick[i].key,
                  ),
                ),
                Expanded(
                  child: i + 1 < widget.quick.length
                      ? _QuickButton(
                          widget.quick[i + 1],
                          key: widget.quick[i + 1].key,
                        )
                      : const SizedBox.shrink(),
                ),
              ],
            ),
        ],
      ),
    );
    var quickDone = widget.quick.isEmpty;
    var first = true;
    // submenu rows whose window sits at a set height beside the menu
    final pinned = <(Object, double)>[];
    for (var g = 0; g < widget.groups.length; g++) {
      if (!quickDone && g >= widget.quickAfter) {
        children.add(quickRow(!first));
        quickDone = true;
      }
      final group = widget.groups[g];
      if (group.rows.isEmpty) continue;
      for (var r = 0; r < group.rows.length; r++) {
        if (group.rows[r] case _KitMenuSubmenu(:final windowTop?)) {
          pinned.add(((g, r), windowTop));
        }
      }
      // a window's first group has no line over it (`.grp:first-child`)
      // unless the title or the quick row stands above it
      final top = first && children.isEmpty;
      final line = !widget.isSubmenu && !(widget.window && top);
      first = false;
      children.add(
        DecoratedBox(
          decoration: BoxDecoration(
            color: KitTokens.menuGroupBg,
            border: !line
                ? null
                : const Border(
                    top: BorderSide(
                      color: KitTokens.menuLine,
                      width: KitTokens.menuLineWidth,
                    ),
                  ),
          ),
          child: Padding(
            // a window's line takes its room as in CSS; a border alone
            // takes none
            padding: EdgeInsets.only(
              top:
                  (widget.isSubmenu
                      ? KitTokens.subMenuPadV
                      : KitTokens.menuGroupPad) +
                  (widget.window && line ? KitTokens.menuLineWidth : 0),
              bottom: widget.isSubmenu
                  ? KitTokens.subMenuPadV
                  : KitTokens.menuGroupPad,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (group.title != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      KitTokens.menuPaddingH,
                      KitTokens.menuGroupTitlePadTop,
                      KitTokens.menuPaddingH,
                      KitTokens.menuGroupTitlePadBottom,
                    ),
                    child: widget.window
                        ? KitText(
                            group.title!,
                            style: _groupTitleStyle.copyWith(
                              height: _windowLine,
                            ),
                          )
                        : Text(group.title!, style: _groupTitleStyle),
                  ),
                for (var r = 0; r < group.rows.length; r++)
                  _row(group.rows[r], (g, r)),
              ],
            ),
          ),
        ),
      );
    }
    if (!quickDone) children.add(quickRow(!first));
    final menu = SizedBox(
      key: _menuKey,
      width: _width,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    );
    if (pinned.isEmpty) return menu;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        menu,
        for (final (id, top) in pinned) ...[
          Positioned(
            left: -KitTokens.submenuGap,
            top: top,
            width: 0,
            height: 0,
            child: SizedBox(key: _menuLeft.putIfAbsent(id, GlobalKey.new)),
          ),
          Positioned(
            right: -KitTokens.submenuGap,
            top: top,
            width: 0,
            height: 0,
            child: SizedBox(key: _menuRight.putIfAbsent(id, GlobalKey.new)),
          ),
        ],
      ],
    );
  }

  /// A window's row (44 high) has room for a name on two lines.
  int get _labelLines => widget.window ? 2 : 1;

  Widget _row(KitMenuRow row, Object id) {
    switch (row) {
      case _KitMenuAction():
        return _RowShell(
          dense: widget.isSubmenu,
          height: widget.rowHeight,
          labelLines: _labelLines,
          key: row.key,
          icon: row.icon,
          label: row.label,
          ink: row.danger ? KitTokens.danger : KitTokens.menuInk,
          value: row.value,
          valueColor: row.valueColor,
          enabled: row.enabled,
          semanticsSelected: row.checked ? true : null,
          trailing: row.checked
              ? const KitIcon(
                  KitIconName.check,
                  size: KitTokens.menuValueIconSize,
                  strokeWidth: KitTokens.menuValueIconStroke,
                  color: KitTokens.accent,
                )
              : row.opens
              ? const KitIcon(
                  KitIconName.chevR,
                  size: KitTokens.menuValueIconSize,
                  strokeWidth: KitTokens.menuValueIconStroke,
                  color: KitTokens.menuValue,
                )
              : null,
          onTap: row.onTap,
        );
      case _KitMenuSubmenu():
        _left.putIfAbsent(id, GlobalKey.new);
        _right.putIfAbsent(id, GlobalKey.new);
        return Stack(
          key: row.key,
          clipBehavior: Clip.none,
          children: [
            _RowShell(
              dense: widget.isSubmenu,
              height: widget.rowHeight,
              icon: row.icon,
              label: row.label,
              ink: KitTokens.menuInk,
              value: row.value,
              open: !widget.window && _openRow == id,
              trailing: const KitIcon(
                KitIconName.chevR,
                size: KitTokens.menuValueIconSize,
                strokeWidth: KitTokens.menuValueIconStroke,
                color: KitTokens.menuValue,
              ),
              onTap: () => _openSubmenu(row, id),
            ),
            Positioned(
              left: -KitTokens.submenuGap,
              top: 0,
              bottom: 0,
              width: 0,
              child: SizedBox(key: _left[id]),
            ),
            Positioned(
              right: -KitTokens.submenuGap,
              top: 0,
              bottom: 0,
              width: 0,
              child: SizedBox(key: _right[id]),
            ),
          ],
        );
      case _KitMenuToggle():
        final on = row.value;
        final shell = _RowShell(
          dense: widget.isSubmenu,
          height: widget.rowHeight,
          labelLines: _labelLines,
          key: row.key,
          icon: row.icon,
          label: row.label,
          ink: KitTokens.menuInk,
          trailing: KitSwitch(value: on),
          semanticsToggled: on,
          onTap: () {
            row.onChanged(!on);
            widget.afterChange?.call();
          },
        );
        if (!row.lineAbove) return shell;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: _lineGap),
            const SizedBox(
              key: ValueKey('kit-menu-line-above'),
              height: KitTokens.menuLineWidth,
              child: ColoredBox(color: KitTokens.menuLine),
            ),
            shell,
          ],
        );
      case _KitMenuSegment():
        return _RowShell(
          dense: widget.isSubmenu,
          height: widget.rowHeight,
          key: row.key,
          icon: row.icon,
          label: row.label,
          ink: KitTokens.menuInk,
          trailing: KitSegment<Object?>(
            options: row.options,
            value: row.value,
            onChanged: (v) {
              row.onChanged(v);
              widget.afterChange?.call();
            },
          ),
        );
    }
  }
}
