import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:saber/components/ink_ui/doc_menu/kit_doc_menu.dart'
    show DocZoom, closeMenuThen, zoomSubmenu;
import 'package:saber/components/kit/kit_icon.dart';
import 'package:saber/components/kit/kit_menu.dart';
import 'package:saber/components/kit/kit_tokens.dart';
import 'package:saber/components/kit/kit_toolbar.dart';
import 'package:saber/components/toolbar/shortcut_layout.dart';
import 'package:saber/data/actions/app_action.dart';

/// An on/off row at the top of the function row's ⋯: its action and how to
/// read whether it is on now (the window shows it as it changes, not as the
/// action was published).
typedef NoteSwitch = ({AppAction action, bool Function() on});

/// The function row of the open documents that are not the ink editor
/// (블록 페이지, 데이터베이스, 카드 캔버스, Office·한글, the Markdown view;
/// design 「다른 문서와 무한 노트」): StarNote's layout_function_tool items
/// in the kit tool bar's look. [back] and [leading] start it, then the
/// shortcut bar's left part; its right part, the [fixed] shortcuts and ⋯
/// "더 많은 기능" end it. The two parts scroll on their own on a narrow row.
///
/// The shortcuts are the open document's actions, placed by [layout] (an
/// id with no action is not shown). A button runs its action with its own
/// context; a row of ⋯ closes the window and runs it with ⋯'s, in the same
/// frame (as the editor's ⋯).
///
/// A document whose own bar has no ⋯ (the infinite note, Task 18 fix 1)
/// puts its settings at the top of ⋯: [switches] (손가락 필기) and 확대 비율
/// ([zoom], the editor's list of scales and 확대 잠금).
class NoteFunctionRow extends StatefulWidget {
  const new({
    super.key,
    this.back,
    this.leading = const [],
    required this.shortcuts,
    this.fixed = const [],
    required this.layout,
    required this.onCustomize,
    this.switches = const [],
    this.zoom,
  });

  /// A tool bar button, as each of [leading] (the button that shows a
  /// hidden tab row).
  final Widget? back;
  final List<Widget> leading;
  final List<AppAction> shortcuts;

  /// Always at the right end (an Office PDF's 문서 개요).
  final List<AppAction> fixed;
  final ShortcutLayout layout;
  final VoidCallback onCustomize;

  /// On/off actions shown as switches at the top of ⋯ (they stay open).
  final List<NoteSwitch> switches;

  /// The document's zoom, for 「확대 비율」 at the top of ⋯.
  final DocZoom? zoom;

  static const height = KitTokens.toolbarHeight;

  /// The ⋯ window: as wide as the editor's ⋯.
  static const moreWidth = 224.0;

  @override
  State<NoteFunctionRow> createState() => _NoteFunctionRowState();
}

class _NoteFunctionRowState extends State<NoteFunctionRow> {
  final _moreButton = GlobalKey();
  final _moreAnchor = GlobalKey();

  List<AppAction> _placed(List<String> ids) {
    final byId = {for (final action in widget.shortcuts) action.id: action};
    return [for (final id in ids) ?byId[id]];
  }

  Widget _button(AppAction action) => Builder(
    builder: (context) => KitToolbarButton(
      key: action.widgetKey,
      icon: action.icon,
      tooltip: action.label,
      selected: action.checked ?? false,
      onPressed: action.enabled ? () => action.run(context) : null,
    ),
  );

  /// One part of the shortcut bar, at most [width] wide.
  Widget _part(String key, List<AppAction> actions, double width) =>
      ConstrainedBox(
        constraints: BoxConstraints(maxWidth: width),
        child: SingleChildScrollView(
          key: ValueKey(key),
          scrollDirection: Axis.horizontal,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            spacing: KitTokens.toolbarGroupGap,
            children: [for (final action in actions) _button(action)],
          ),
        ),
      );

  /// ⋯'s window, right under the row with its right edge on ⋯'s, inside
  /// the screen (a long one slides inside).
  Future<void> _openMore() => showKitMenu(
    context: context,
    anchor: _moreAnchor,
    within: Navigator.of(context).context.findRenderObject() as RenderBox?,
    builder: _moreMenu,
  );

  KitMenu _moreMenu() {
    final at = _moreButton.currentContext ?? context;
    final zoom = widget.zoom;
    final scale = zoom?.scale();
    return KitMenu(
      width: NoteFunctionRow.moreWidth,
      window: true,
      groups: [
        if (widget.switches.isNotEmpty || zoom != null)
          KitMenuGroup(
            rows: [
              for (final (:action, :on) in widget.switches)
                KitMenuRow.toggle(
                  key: action.widgetKey ?? ValueKey('note-more-${action.id}'),
                  icon: action.icon,
                  label: action.label,
                  value: on(),
                  onChanged: (_) => action.run(at),
                ),
              if (zoom != null && scale != null)
                zoomSubmenu(
                  context: at,
                  keyPrefix: 'note-more-zoom',
                  zoom: zoom,
                  scale: scale,
                ),
            ],
          ),
        KitMenuGroup(
          rows: [
            for (final action in _placed(widget.layout.more))
              KitMenuRow.action(
                key: action.widgetKey ?? ValueKey('note-more-${action.id}'),
                icon: action.icon,
                label: action.label,
                checked: action.checked ?? false,
                enabled: action.enabled,
                onTap: () => closeMenuThen(at, () => action.run(at)),
              ),
          ],
        ),
        KitMenuGroup(
          rows: [
            KitMenuRow.action(
              key: const ValueKey('shortcut-bar-customize'),
              icon: KitIconName.tune,
              label: '사용자 지정 바로가기 막대',
              onTap: () => closeMenuThen(at, widget.onCustomize),
            ),
          ],
        ),
      ],
    );
  }

  Widget _more() => Stack(
    clipBehavior: Clip.none,
    children: [
      KeyedSubtree(
        key: _moreButton,
        child: KitToolbarButton(
          key: const ValueKey('workspace-more-actions'),
          icon: KitIconName.more,
          tooltip: '더 많은 기능',
          onPressed: () => unawaited(_openMore()),
        ),
      ),
      Positioned(
        left: KitTokens.toolbarButton - NoteFunctionRow.moreWidth,
        top:
            (KitTokens.toolbarHeight + KitTokens.toolbarButton) / 2 +
            KitTokens.toolWindowGapToolbar,
        width: 0,
        height: 0,
        child: SizedBox(key: _moreAnchor),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final left = _placed(widget.layout.left);
    final right = _placed(widget.layout.right);
    final back = widget.back;
    return KeyedSubtree(
      key: const ValueKey('note-function-row'),
      child: LayoutBuilder(
        builder: (context, box) {
          // the room the two parts share: each takes up to half of what
          // the buttons that never scroll leave
          const button = KitTokens.toolbarButton + KitTokens.toolbarGroupGap;
          final still =
              (back == null ? 0 : 1) +
              widget.leading.length +
              widget.fixed.length +
              1;
          final divider = left.isEmpty
              ? 0.0
              : KitTokens.toolbarDividerWidth + KitTokens.toolbarGroupGap;
          final half =
              math.max(
                0.0,
                box.maxWidth -
                    2 * KitTokens.toolbarPadding -
                    still * button -
                    divider -
                    2 * KitTokens.toolbarGroupGap,
              ) /
              2;
          return KitToolbar(
            start: [
              ?back,
              ...widget.leading,
              _part('note-function-left', left, half),
              if (left.isNotEmpty) const KitToolbarDivider(),
            ],
            middle: const [],
            end: [
              _part('note-function-right', right, half),
              for (final action in widget.fixed) _button(action),
              _more(),
            ],
          );
        },
      ),
    );
  }
}
