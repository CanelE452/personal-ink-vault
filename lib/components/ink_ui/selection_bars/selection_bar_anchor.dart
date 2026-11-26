import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'package:saber/components/kit/kit_tokens.dart';

/// Where a selection bar of size [bar] goes for [target] in [viewport] (both
/// in the same coordinates): [gap] under the target and centred on it; above
/// it when the bar would run past the bottom; pushed inside the screen at the
/// sides, keeping the popover edge gap when there is room for it.
Offset selectionBarPosition({
  required Rect target,
  required Size bar,
  required Size viewport,
  double gap = 12,
}) {
  var y = target.bottom + gap;
  if (y + bar.height > viewport.height) {
    y = target.top - gap - bar.height;
    // no room above either: as low as the screen allows
    if (y < 0) y = math.max(0, viewport.height - bar.height);
  }
  final x = target.center.dx - bar.width / 2;
  const edge = KitTokens.popoverEdgeGap;
  final double left = bar.width + 2 * edge >= viewport.width
      ? (viewport.width - bar.width) / 2
      : x.clamp(edge, viewport.width - bar.width - edge);
  return Offset(left, y);
}

/// Fills the area it is given and puts [child] where [selectionBarPosition]
/// says for [target] (in this widget's coordinates). Touches outside the
/// child go through to what lies under it.
class SelectionBarAnchor extends StatelessWidget {
  const new({super.key, required this.target, required this.child});

  final Rect target;
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      CustomSingleChildLayout(delegate: _BarLayout(target), child: child);
}

class _BarLayout extends SingleChildLayoutDelegate {
  const new(this.target);

  final Rect target;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      constraints.loosen();

  @override
  Offset getPositionForChild(Size size, Size childSize) =>
      selectionBarPosition(target: target, bar: childSize, viewport: size);

  @override
  bool shouldRelayout(_BarLayout old) => target != old.target;
}
