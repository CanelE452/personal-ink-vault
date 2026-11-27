import 'package:flutter/material.dart';
import 'package:saber/components/ink_ui/side_panel/side_row_parts.dart';
import 'package:saber/components/kit/kit_icon.dart';
import 'package:saber/components/kit/kit_popover.dart';
import 'package:saber/components/kit/kit_tokens.dart';

/// What the thumbnail's menu offers, in the order it shows them.
enum KitPageAction {
  insertBefore,
  insertAfter,
  duplicate,
  copy,
  cut,
  paste,
  clear,
  delete,
}

/// The menu of the page whose ⋮ button is [context]: the actions in groups
/// (add before and after; duplicate; copy, cut and paste; clear; delete),
/// under the button or over it where it would come too near the window's
/// foot, its right edge 8 inside the grid's (the panel's). What was picked,
/// once it is closed; null when it was closed without one.
///
/// Without [canEdit] (a note that may not change) only 「복사」 is on.
/// Without [canPaste] (nothing copied) 「붙여넣기」 is off; without
/// [canDelete] (the only page, or the spare empty one at the end) 「잘라내기」
/// and 「쪽 삭제」 are off; without [canClear] (nothing on the page) 「쪽 비우기」
/// is off. An item that is off is dimmed and does nothing.
Future<KitPageAction?> showKitPageMenu(
  BuildContext context, {
  required bool canEdit,
  required bool canPaste,
  required bool canDelete,
  required bool canClear,
}) {
  final box = context.findRenderObject()! as RenderBox;
  final navigator =
      Navigator.of(context).context.findRenderObject()! as RenderBox;
  final foot = box.localToGlobal(
    box.size.bottomLeft(Offset.zero),
    ancestor: navigator,
  );
  // each row is sideMenuRow high, its group line (if any) inside it
  final height = KitTokens.sideMenuRow * KitPageAction.values.length;
  final up = foot.dy + height > navigator.size.height - KitTokens.sideMenuFoot;
  // as a row's menu, it ends 8 inside the panel (the grid that scrolls)
  final panel = Scrollable.maybeOf(context)?.context.findRenderObject();
  return showKitPopover<KitPageAction>(
    context: context,
    anchorContext: context,
    rightTo: panel is RenderBox ? panel : null,
    rightInset: KitTokens.sideMenuRight,
    grow: up ? AxisDirection.up : AxisDirection.down,
    radius: BorderRadius.circular(KitTokens.sideMenuRadius),
    shadows: KitTokens.sideMenuShadow,
    border: false,
    builder: (context) {
      Widget item(
        KitPageAction action,
        KitIconName icon,
        String label, {
        bool on = true,
        bool lineAbove = false,
        bool danger = false,
      }) => KitSideMenuItem(
        key: ValueKey('kit-page-menu-$label'),
        icon: icon,
        label: label,
        enabled: on,
        lineAbove: lineAbove,
        danger: danger,
        onTap: () => Navigator.of(context).pop(action),
      );
      return SizedBox(
        width: KitTokens.sideMenuWidth,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            item(
              KitPageAction.insertBefore,
              KitIconName.pageAddBefore,
              '앞에 쪽 추가',
              on: canEdit,
            ),
            item(
              KitPageAction.insertAfter,
              KitIconName.pageAddAfter,
              '뒤에 쪽 추가',
              on: canEdit,
            ),
            item(
              KitPageAction.duplicate,
              KitIconName.dup,
              '복제',
              on: canEdit,
              lineAbove: true,
            ),
            item(
              KitPageAction.copy,
              KitIconName.pageCopy,
              '복사',
              lineAbove: true,
            ),
            item(
              KitPageAction.cut,
              KitIconName.scissors,
              '잘라내기',
              on: canEdit && canDelete,
            ),
            item(
              KitPageAction.paste,
              KitIconName.paste,
              '붙여넣기',
              on: canEdit && canPaste,
            ),
            item(
              KitPageAction.clear,
              // the page stays: an eraser, not the page crossed out
              KitIconName.eraser,
              '쪽 비우기',
              on: canEdit && canClear,
              lineAbove: true,
            ),
            item(
              KitPageAction.delete,
              KitIconName.trash,
              '쪽 삭제',
              on: canEdit && canDelete,
              lineAbove: true,
              danger: true,
            ),
          ],
        ),
      );
    },
  );
}
