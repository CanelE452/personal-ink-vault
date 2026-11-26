import 'package:flutter/material.dart';

import 'package:saber/components/ink_ui/pen_panel/kit_pen_color_row.dart';
import 'package:saber/components/ink_ui/pen_panel/pen_panel_common.dart';
import 'package:saber/components/ink_ui/selection_bars/selection_bar_anchor.dart';
import 'package:saber/components/ink_ui/selection_bars/selection_bar_parts.dart';
import 'package:saber/components/kit/kit_icon.dart';
import 'package:saber/components/kit/kit_selection_bar.dart';
import 'package:saber/components/kit/kit_tokens.dart';

/// The lasso's bar (preview-v9c 1-2, line 906) under the lassoed area at
/// [selectionRect] (in this widget's coordinates; it fills the area it is
/// given). Stage 1 draws only what the lasso can do now: the colour chip |
/// duplicate · delete | ⋯ (duplicate · link · delete). The AI slot, resize,
/// cut and the menu's other rows wait for the pen engine stage.
class KitLassoBar extends StatefulWidget {
  const new({
    super.key,
    required this.duplicateSelection,
    required this.deleteSelection,
    required this.recolorSelection,
    this.linkSelection,
    required this.selectionRect,
    this.selectionColor,
  });

  final VoidCallback duplicateSelection;
  final VoidCallback deleteSelection;

  /// Gives the lassoed strokes the colour chosen at the chip.
  final ValueChanged<Color> recolorSelection;
  final VoidCallback? linkSelection;
  final Rect selectionRect;

  /// The lassoed strokes' colour for the chip; null when the lasso holds
  /// no strokes (pictures only), which dims the chip.
  final Color? selectionColor;

  @override
  State<KitLassoBar> createState() => _KitLassoBarState();
}

class _KitLassoBarState extends State<KitLassoBar> {
  final _colourAnchor = GlobalKey();
  final _moreAnchor = GlobalKey();
  String? _open;

  Future<void> _openWindow(String name, Future<void> Function() open) async {
    setState(() => _open = name);
    await open();
    if (mounted) setState(() => _open = null);
  }

  Future<void> _openColours() => _openWindow(
    'colour',
    () => showSelectionColours(
      context: context,
      anchor: _colourAnchor,
      row: (window) => KitPenColorRow(
        key: const ValueKey('lasso-bar-colours'),
        selected: widget.selectionColor,
        onSelected: (colour) {
          Navigator.of(window).pop();
          widget.recolorSelection(colour);
        },
      ),
    ),
  );

  Future<void> _openMore() => _openWindow(
    'more',
    () => showSelectionMenu(
      context: context,
      anchor: _moreAnchor,
      width: KitTokens.objMenuLassoWidth,
      groups: [
        [
          SelectionMenuRow(
            key: const ValueKey('lasso-menu-duplicate'),
            label: '복제',
            icon: KitIconName.dup,
            onTap: widget.duplicateSelection,
          ),
        ],
        if (widget.linkSelection case final link?)
          [
            SelectionMenuRow(
              key: const ValueKey('selection-link'),
              label: '링크',
              icon: KitIconName.link,
              onTap: link,
            ),
          ],
        [
          SelectionMenuRow(
            key: const ValueKey('lasso-menu-delete'),
            label: '삭제',
            icon: KitIconName.trash,
            danger: true,
            onTap: widget.deleteSelection,
          ),
        ],
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final colour = widget.selectionColor;
    final bar = KitSelectionBar(
      groups: [
        [
          selectionWindowAnchor(
            anchor: _colourAnchor,
            left: -KitTokens.selPopShift,
            button: SelectionColourChip(
              key: const ValueKey('lasso-bar-colour'),
              label: '색 바꾸기',
              // as the page shows the strokes
              colour: colour == null
                  ? KitTokens.textBarDefaultInk
                  : visibleInk(colour, inkInverted(context)),
              selected: _open == 'colour',
              onPressed: colour == null ? null : _openColours,
            ),
          ),
        ],
        [
          KitSelectionBarButton(
            key: const ValueKey('lasso-bar-duplicate'),
            icon: KitIconName.dup,
            tooltip: '복제',
            onPressed: widget.duplicateSelection,
          ),
          KitSelectionBarButton(
            key: const ValueKey('lasso-bar-delete'),
            icon: KitIconName.trash,
            tooltip: '삭제',
            danger: true,
            onPressed: widget.deleteSelection,
          ),
        ],
        [
          selectionWindowAnchor(
            anchor: _moreAnchor,
            left: -KitTokens.lassoMenuShift,
            button: KitSelectionBarButton(
              key: const ValueKey('lasso-bar-more'),
              icon: KitIconName.more,
              tooltip: '더 보기',
              selected: _open == 'more',
              onPressed: _openMore,
            ),
          ),
        ],
      ],
    );
    return SelectionBarAnchor(target: widget.selectionRect, child: bar);
  }
}
