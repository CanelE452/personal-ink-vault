import 'package:flutter/material.dart';

import 'package:saber/components/kit/kit_icon.dart';
import 'package:saber/components/kit/kit_pill.dart';
import 'package:saber/components/kit/kit_tokens.dart';

/// The top tool bar: three groups, the space between them stretches.
class KitToolbar extends StatelessWidget {
  const new({
    super.key,
    required this.start,
    required this.middle,
    required this.end,
  });

  final List<Widget> start;
  final List<Widget> middle;
  final List<Widget> end;

  Widget _group(List<Widget> children) => Row(
    mainAxisSize: MainAxisSize.min,
    spacing: KitTokens.toolbarGroupGap,
    children: children,
  );

  @override
  Widget build(BuildContext context) {
    return Material(
      color: KitTokens.toolbarBg,
      child: SizedBox(
        height: KitTokens.toolbarHeight,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: KitTokens.toolbarPadding,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [_group(start), _group(middle), _group(end)],
          ),
        ),
      ),
    );
  }
}

class KitToolbarButton extends StatelessWidget {
  const new({
    super.key,
    required this.icon,
    required this.tooltip,
    this.onPressed,
    this.selected = false,
    this.dropdown = false,
  });

  final KitIconName icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool selected;
  final bool dropdown;

  @override
  Widget build(BuildContext context) {
    final ink = selected ? KitTokens.toolbarBg : KitTokens.toolbarOnBar;
    return KitSquareButton(
      icon: icon,
      tooltip: tooltip,
      size: KitTokens.toolbarButton,
      radius: KitTokens.toolbarButtonRadius,
      iconSize: KitTokens.toolbarIconSize,
      iconStroke: KitTokens.toolbarIconStroke,
      iconColor: KitTokens.toolbarOnBar,
      selectedFill: KitTokens.toolbarOnBar,
      selectedIconColor: KitTokens.toolbarBg,
      onPressed: onPressed,
      selected: selected,
      width: dropdown ? KitTokens.toolbarDropdownWidth : null,
      iconShift: dropdown ? KitTokens.toolbarDropdownIconShift : 0,
      corner: dropdown
          ? Positioned(
              left:
                  KitTokens.toolbarDropdownMarkCentre -
                  KitDropdownMark.width / 2,
              top:
                  KitTokens.toolbarButton / 2 -
                  KitTokens.toolbarDropdownMarkRise +
                  KitDropdownMark.arm * KitDropdownMark.half / 2 -
                  KitDropdownMark.height / 2,
              child: KitDropdownMark(color: ink),
            )
          : null,
    );
  }
}

/// The small down chevron of a dropdown tool bar button: two lines of
/// [KitTokens.toolbarDropdownMarkArm] at 45 degrees, drawn with a line.
class KitDropdownMark extends StatelessWidget {
  const new({super.key, required this.color});

  final Color color;

  static const arm = KitTokens.toolbarDropdownMarkArm;
  static const half = 0.7071067811865476; // sin / cos of 45 degrees
  static const width = 2 * arm * half + KitTokens.toolbarDropdownMarkLine;
  static const height = arm * half + KitTokens.toolbarDropdownMarkLine;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Opacity(
      opacity: KitTokens.toolbarDropdownMarkOpacity,
      child: CustomPaint(
        size: const Size(width, height),
        painter: KitDropdownMarkPainter(
          color: color,
          lineWidth: KitTokens.toolbarDropdownMarkLine,
          arm: arm,
        ),
      ),
    ),
  );
}

class KitDropdownMarkPainter extends CustomPainter {
  const new({required this.color, required this.lineWidth, required this.arm});

  final Color color;
  final double lineWidth;
  final double arm;

  @override
  void paint(Canvas canvas, Size size) {
    final a = arm * KitDropdownMark.half;
    final top = (size.height - a) / 2;
    final cx = size.width / 2;
    final path = Path()
      ..moveTo(cx - a, top)
      ..lineTo(cx, top + a)
      ..lineTo(cx + a, top);
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = lineWidth
        ..strokeJoin = StrokeJoin.miter,
    );
  }

  @override
  bool shouldRepaint(KitDropdownMarkPainter old) =>
      old.color != color || old.lineWidth != lineWidth || old.arm != arm;
}

/// A thin light line between tool bar groups.
class KitToolbarDivider extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) => const SizedBox(
    width: KitTokens.toolbarDividerWidth,
    height: KitTokens.toolbarDividerHeight,
    child: ColoredBox(color: KitTokens.toolbarDividerColor),
  );
}
