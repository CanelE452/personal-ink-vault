import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:saber/components/kit/kit_icon.dart';
import 'package:saber/components/kit/kit_tokens.dart';

/// Where the S Pen hovers now, in the coordinates of the
/// [HoverBadgeListener] that hears it; null while it does not. Only a pen
/// counts ([PointerDeviceKind.stylus], and [PointerDeviceKind.invertedStylus]
/// for its eraser end): its touch down and its leaving clear it.
class HoverBadgeController extends ValueNotifier<Offset?> {
  new() : super(null);

  void handle(PointerEvent event) {
    if (event.kind != PointerDeviceKind.stylus &&
        event.kind != PointerDeviceKind.invertedStylus) {
      return;
    }
    switch (event) {
      // Flutter makes one up where a touch lands, just before the down.
      case PointerHoverEvent(synthesized: false):
        value = event.localPosition;
      case PointerDownEvent() || PointerExitEvent():
        value = null;
    }
  }
}

/// Hears the pen hovering over [child] (the page) for [controller]. Its
/// leaving comes from the [MouseRegion]: out of range, or onto what lies
/// over the page (the floating bar).
class HoverBadgeListener extends StatelessWidget {
  const new({super.key, required this.controller, required this.child});

  final HoverBadgeController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) => MouseRegion(
    opaque: false,
    onExit: controller.handle,
    child: Listener(
      onPointerHover: controller.handle,
      onPointerDown: controller.handle,
      child: child,
    ),
  );
}

/// The pen tip badge (preview `.badge`, `.hoverdot`): while the S Pen
/// hovers, a dot at its tip and, up and right of it, the tool a touch
/// would use ([toolIcon]). It shows, moves and goes at once. With no room
/// on the right it goes to the tip's left, with none above below the tip,
/// always clear of the tip.
///
/// The host lays it over the [HoverBadgeListener]'s area with
/// `Positioned.fill`. It takes no touches, and it paints in its own layer:
/// a hover moves it without painting the page again.
class KitHoverBadge extends StatelessWidget {
  const new({super.key, required this.controller, required this.toolIcon});

  final HoverBadgeController controller;
  final KitIconName toolIcon;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: ExcludeSemantics(
      child: RepaintBoundary(
        child: LayoutBuilder(
          builder: (context, box) => ValueListenableBuilder(
            valueListenable: controller,
            builder: (context, tip, _) {
              if (tip == null) return const SizedBox.shrink();
              const dot = KitTokens.hoverDot;
              return Stack(
                children: [
                  Positioned(
                    left: tip.dx - dot / 2,
                    top: tip.dy - dot / 2,
                    child: const DecoratedBox(
                      key: ValueKey('kit-hover-dot'),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: KitTokens.hoverDotFill,
                        border: Border.fromBorderSide(
                          BorderSide(
                            color: KitTokens.hoverDotBorder,
                            width: KitTokens.hoverDotBorderWidth,
                          ),
                        ),
                      ),
                      child: SizedBox.square(dimension: dot),
                    ),
                  ),
                  Positioned.fromRect(
                    rect: _badgeAt(tip, box.biggest),
                    child: _Badge(
                      key: const ValueKey('kit-hover-badge'),
                      icon: toolIcon,
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    ),
  );
}

/// The badge's place for a pen at [tip] over [area].
Rect _badgeAt(Offset tip, Size area) {
  const size = KitTokens.badgeSize;
  const gap = KitTokens.badgeGap;
  var left = tip.dx + gap;
  if (left + size > area.width) left = tip.dx - gap - size;
  var top = tip.dy - size;
  if (top < 0) top = tip.dy;
  return Rect.fromLTWH(
    left.clamp(0.0, math.max(0.0, area.width - size)),
    top.clamp(0.0, math.max(0.0, area.height - size)),
    size,
    size,
  );
}

class _Badge extends StatelessWidget {
  const new({super.key, required this.icon});

  final KitIconName icon;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: KitTokens.badgeBg,
      border: Border.all(color: KitTokens.badgeLine),
      borderRadius: BorderRadius.circular(KitTokens.badgeRadius),
      boxShadow: KitTokens.badgeShadow,
    ),
    child: Center(
      child: KitIcon(
        icon,
        size: KitTokens.badgeIconSize,
        strokeWidth: KitTokens.badgeIconStroke,
        color: KitTokens.badgeInk,
      ),
    ),
  );
}
