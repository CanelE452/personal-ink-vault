import 'package:flutter/material.dart';

import 'package:saber/components/kit/kit_icon.dart';
import 'package:saber/components/kit/kit_pill.dart';
import 'package:saber/components/kit/kit_tokens.dart';

/// The menu over a selected text box or lasso selection: buttons in groups
/// with a thin line between groups.
class KitSelectionBar extends StatelessWidget {
  const new({super.key, required this.groups});

  final List<List<Widget>> groups;

  @override
  Widget build(BuildContext context) {
    final items = <Widget>[];
    for (var i = 0; i < groups.length; i++) {
      if (i > 0) {
        items.add(
          const Padding(
            padding: EdgeInsets.symmetric(
              horizontal: KitTokens.selBarDividerMargin,
            ),
            child: SizedBox(
              key: ValueKey('kit-selection-bar-divider'),
              width: KitTokens.toolbarDividerWidth,
              height: KitTokens.selBarDividerHeight,
              child: ColoredBox(color: KitTokens.selBarDivider),
            ),
          ),
        );
      }
      items.add(
        Row(
          mainAxisSize: MainAxisSize.min,
          spacing: KitTokens.selBarGap,
          children: groups[i],
        ),
      );
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        color: KitTokens.selBarBg,
        borderRadius: BorderRadius.circular(KitTokens.selBarRadius),
        boxShadow: KitTokens.selBarShadow,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: KitTokens.selBarPaddingH,
          vertical: KitTokens.selBarPaddingV,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: KitTokens.selBarGap,
          children: items,
        ),
      ),
    );
  }
}

class KitSelectionBarButton extends StatelessWidget {
  const new({
    super.key,
    required this.icon,
    required this.tooltip,
    this.onPressed,
    this.danger = false,
    this.selected = false,
  });

  final KitIconName icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool danger;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final ink = danger ? KitTokens.danger : KitTokens.selBarInk;
    return KitSquareButton(
      icon: icon,
      tooltip: tooltip,
      size: KitTokens.selBarButton,
      radius: KitTokens.selBarButtonRadius,
      iconSize: KitTokens.selBarIconSize,
      iconStroke: KitTokens.selBarIconStroke,
      iconColor: ink,
      selectedFill: KitTokens.selBarOnFill,
      selectedIconColor: ink,
      onPressed: onPressed,
      selected: selected,
    );
  }
}
