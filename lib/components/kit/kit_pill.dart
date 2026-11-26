import 'package:flutter/material.dart';

import 'package:saber/components/kit/kit_icon.dart';
import 'package:saber/components/kit/kit_motion.dart';
import 'package:saber/components/kit/kit_tokens.dart';

/// The one square icon button the bars share (toolbar, pill, selection bar).
/// Callers pass the size, radius, icon size and colours from [KitTokens].
class KitSquareButton extends StatelessWidget {
  const new({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.size,
    required this.radius,
    required this.iconSize,
    required this.iconStroke,
    required this.iconColor,
    required this.selectedFill,
    required this.selectedIconColor,
    this.onPressed,
    this.selected = false,
    this.corner,
    this.width,
    this.iconShift = 0,
  });

  final KitIconName icon;
  final String tooltip;
  final double size;
  final double radius;
  final double iconSize;
  final double iconStroke;
  final Color iconColor;
  final Color selectedFill;
  final Color selectedIconColor;
  final VoidCallback? onPressed;
  final bool selected;

  /// Drawn over the bottom-right corner (the dropdown mark).
  final Widget? corner;

  /// Width when it differs from [size] (a dropdown button), and how far the
  /// icon sits from the centre then.
  final double? width;
  final double iconShift;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final ink = selected ? selectedIconColor : iconColor;
    final shape = BorderRadius.circular(radius);
    return Semantics(
      button: true,
      enabled: enabled,
      selected: selected,
      label: tooltip,
      onTap: onPressed,
      excludeSemantics: true,
      child: Tooltip(
        message: tooltip,
        child: Opacity(
          opacity: enabled ? 1 : KitTokens.disabledOpacity,
          child: SizedBox(
            width: width ?? size,
            height: size,
            child: Material(
              color: selected ? selectedFill : Colors.transparent,
              borderRadius: shape,
              child: InkWell(
                borderRadius: shape,
                onTap: onPressed,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Transform.translate(
                      offset: Offset(iconShift, 0),
                      child: KitIcon(
                        icon,
                        size: iconSize,
                        strokeWidth: iconStroke,
                        color: ink,
                        selected: selected,
                      ),
                    ),
                    ?corner,
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PillScope extends InheritedWidget {
  const new({required this.direction, required super.child});

  final Axis direction;

  static Axis of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_PillScope>()?.direction ??
      Axis.horizontal;

  @override
  bool updateShouldNotify(_PillScope old) => direction != old.direction;
}

/// The grouped floating bar: rounded, bordered, with a soft shadow.
class KitPill extends StatelessWidget {
  const new({
    super.key,
    required this.children,
    this.direction = Axis.horizontal,
    this.raised = false,
    this.scrollController,
  });

  final List<Widget> children;
  final Axis direction;

  /// Picked up (the floating bar held to move it): the shadow a step up.
  final bool raised;

  /// Given, the buttons slide inside the pill when it is shorter than they
  /// are (the floating bar on a phone); the pill itself stays.
  final ScrollController? scrollController;

  @override
  Widget build(BuildContext context) {
    // `.fbar .pill` padding 3px 6px, upright `6px 3px` (lines 106, 114),
    // inside its border, which takes room as in CSS
    final padding = direction == Axis.vertical
        ? const EdgeInsets.symmetric(
            horizontal: KitTokens.pillVerticalPaddingAlong,
            vertical: KitTokens.pillVerticalPaddingAcross,
          )
        : const EdgeInsets.symmetric(
            horizontal: KitTokens.pillPaddingAlong,
            vertical: KitTokens.pillPaddingAcross,
          );
    return _PillScope(
      direction: direction,
      // held, the shadow goes a step up in the fast step with CSS's `ease`
      // (`.pill{transition:box-shadow .12s ease}`); the size stays
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: raised ? 1 : 0),
        duration: KitMotion.of(context, KitMotionStep.fast),
        curve: Curves.ease,
        builder: (context, lift, child) => DecoratedBox(
          decoration: BoxDecoration(
            color: KitTokens.pillBg,
            border: Border.all(
              color: KitTokens.pillBorder,
              width: KitTokens.pillBorderWidth,
            ),
            borderRadius: BorderRadius.circular(KitTokens.pillRadius),
            boxShadow: BoxShadow.lerpList(
              KitTokens.pillShadow,
              KitTokens.pillShadowRaised,
              lift,
            ),
          ),
          child: child,
        ),
        child: _inside(padding),
      ),
    );
  }

  Widget _inside(EdgeInsets padding) {
    final row = Flex(
      direction: direction,
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      spacing: KitTokens.pillGap,
      children: children,
    );
    final controller = scrollController;
    if (controller == null) {
      return Padding(
        padding: padding + const EdgeInsets.all(KitTokens.pillBorderWidth),
        child: row,
      );
    }
    // inside the border, its padding sliding with the buttons; the view
    // clips only while the buttons run past it (no rounded clip: it would
    // soften the buttons' edges when nothing runs past)
    return Padding(
      padding: const EdgeInsets.all(KitTokens.pillBorderWidth),
      child: SingleChildScrollView(
        controller: controller,
        scrollDirection: direction,
        child: Padding(padding: padding, child: row),
      ),
    );
  }
}

class KitPillButton extends StatelessWidget {
  const new({
    super.key,
    required this.icon,
    required this.tooltip,
    this.onPressed,
    this.selected = false,
  });

  final KitIconName icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool selected;

  @override
  Widget build(BuildContext context) => KitSquareButton(
    icon: icon,
    tooltip: tooltip,
    size: KitTokens.pillButton,
    radius: KitTokens.pillButtonRadius,
    iconSize: KitTokens.toolbarIconSize,
    iconStroke: KitTokens.toolbarIconStroke,
    iconColor: KitTokens.pillInk,
    selectedFill: KitTokens.selectedFill,
    selectedIconColor: KitTokens.pillInk,
    onPressed: onPressed,
    selected: selected,
  );
}

/// A thin line between pill groups; turns with the pill's direction.
class KitPillDivider extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) {
    final vertical = _PillScope.of(context) == Axis.vertical;
    const thick = KitTokens.toolbarDividerWidth;
    const long = KitTokens.toolbarDividerHeight;
    return SizedBox(
      width: vertical ? long : thick,
      height: vertical ? thick : long,
      child: const ColoredBox(color: KitTokens.pillDivider),
    );
  }
}

/// A round colour swatch; the chosen one gets a double ring. It takes the
/// keyboard focus, shows a ring while it has it (`:focus-visible`) and is
/// picked with Enter or Space.
class KitColorDot extends StatefulWidget {
  const new({
    super.key,
    required this.color,
    required this.label,
    this.selected = false,
    this.onPressed,
  });

  final Color color;

  /// Read out by screen readers.
  final String label;
  final bool selected;
  final VoidCallback? onPressed;

  @override
  State<KitColorDot> createState() => _KitColorDotState();
}

/// How far the chosen dot's two rings reach past it.
const _chosenReach = KitTokens.colorDotRingGap + KitTokens.colorDotRingWidth;

class _KitColorDotState extends State<KitColorDot> {
  /// Whether the keyboard focus is here and shows.
  var _focused = false;

  @override
  Widget build(BuildContext context) {
    final onPressed = widget.onPressed;
    final selected = widget.selected;
    // the focus ring 2 out, or just past the chosen dot's rings (v8h 111)
    final focusAt = selected ? _chosenReach : KitTokens.colorDotFocusGap;
    // Box shadows are painted in list order (CSS paints the first shadow on
    // top), so each ring comes before the gap or ring painted over it.
    final rings = [
      if (_focused) ...[
        BoxShadow(
          color: KitTokens.accent,
          spreadRadius: focusAt + KitTokens.colorDotFocusWidth,
        ),
        if (!selected)
          const BoxShadow(
            color: KitTokens.pillBg,
            spreadRadius: KitTokens.colorDotFocusGap,
          ),
      ],
      if (selected) ...const [
        BoxShadow(color: KitTokens.colorDotRing, spreadRadius: _chosenReach),
        BoxShadow(
          color: KitTokens.pillBg,
          spreadRadius: KitTokens.colorDotRingGap,
        ),
      ],
    ];
    return Semantics(
      button: true,
      label: widget.label,
      selected: selected,
      enabled: onPressed != null,
      onTap: onPressed,
      excludeSemantics: true,
      // `.fbar .cd` margin 0 3px in both directions (line 110, no upright
      // rule), outside the press area: the dot is pressed in its own 22
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: KitTokens.colorDotMargin,
        ),
        child: FocusableActionDetector(
          enabled: onPressed != null,
          onShowFocusHighlight: (on) => setState(() => _focused = on),
          actions: {
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (_) {
                onPressed?.call();
                return null;
              },
            ),
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onPressed,
            child: Container(
              width: KitTokens.colorDot,
              height: KitTokens.colorDot,
              decoration: BoxDecoration(
                color: widget.color,
                shape: BoxShape.circle,
                // the chosen one's rings take the place of its thin line
                // (`.cd.on` replaces the whole box-shadow, line 111)
                border: selected
                    ? null
                    : Border.all(color: KitTokens.colorDotEdge),
                boxShadow: rings.isEmpty ? null : rings,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
