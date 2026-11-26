import 'package:flutter/material.dart';
import 'package:saber/components/kit/kit_icon.dart';
import 'package:saber/components/kit/kit_tokens.dart';
import 'package:saber/data/actions/app_action_ids.dart';
import 'package:saber/data/actions/app_action_registry.dart';
import 'package:saber/data/extensions/color_extensions.dart';
import 'package:saber/data/prefs.dart';

/// Whether ink shows inverted, as the page shows it: the dark theme with the
/// editor's auto invert (the old toolbar's rule).
bool inkInverted(BuildContext context) =>
    stows.editorAutoInvert.value &&
    Theme.brightnessOf(context) == Brightness.dark;

/// [colour] as the page shows it: opaque, inverted when [invert].
Color visibleInk(Color colour, bool invert) =>
    colour.withValues(alpha: 1).withInversion(invert);

/// The eyedropper of a colour row in a window (the pen panel, the floating
/// bar's colour window), or null when [actions] has none. A press closes
/// the window with [close]. The window is gone by then, so the action gets
/// the navigator's overlay of [window], which stays (as the settings page
/// runs its actions), on the frame after, if it is still there.
VoidCallback? colourRowEyedropper(
  AppActionRegistry? actions,
  BuildContext window, {
  required VoidCallback close,
}) {
  if (actions == null || !actions.has(AppActionIds.eyedropper)) return null;
  return () {
    final target = Navigator.of(window).overlay!.context;
    close();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (target.mounted) actions.run(AppActionIds.eyedropper, target);
    });
  };
}

/// The pen panel's box (preview `.snp`): white with a thin line on top of
/// the content, round corners, 300 wide. The pen panel and the pen box are
/// drawn on it, so a host only has to open it with `showKitPopover`.
class PenPanelSurface extends StatelessWidget {
  const new({
    super.key,
    required this.child,
    this.width = KitTokens.penPanelWidth,
  });

  final Widget child;

  /// A window with less in it than the pen panel (the selection bars'
  /// colour windows) is narrower.
  final double width;

  @override
  Widget build(BuildContext context) => Material(
    color: KitTokens.penPanelBg,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(KitTokens.penPanelRadius),
      side: const BorderSide(
        color: KitTokens.penPanelBorder,
        width: KitTokens.penPanelBorderWidth,
      ),
    ),
    clipBehavior: Clip.antiAlias,
    child: SizedBox(
      width: width,
      child: Padding(
        padding: const EdgeInsets.all(KitTokens.penPanelBorderWidth),
        child: child,
      ),
    ),
  );
}

/// A head icon (`.snp .hd svg.ic`): 22, in the head's ink.
Widget penPanelHeadIcon(KitIconName name, {bool selected = false}) => KitIcon(
  name,
  size: KitTokens.penPanelIconSize,
  strokeWidth: KitTokens.penPanelIconStroke,
  color: KitTokens.penPanelHeadInk,
  selected: selected,
);

/// The head's right end (`.snp .hd`), the same on every panel: the collapse
/// button and the close circle, pressed in 44 x 44 from the panel's top edge
/// with the icons where the preview draws them (22 at x 225, the circle at
/// x 261). Put it after a spacer in a head row 44 high.
class PenPanelHeadEnd extends StatelessWidget {
  const new({
    super.key,
    required this.collapsed,
    required this.onCollapse,
    required this.onClose,
  });

  final bool collapsed;
  final VoidCallback onCollapse;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    const inner = KitTokens.penPanelHeadHit - KitTokens.penPanelPadH;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        PenPanelHeadButton(
          key: const ValueKey('pen-panel-collapse'),
          left: KitTokens.penPanelPadH,
          label: collapsed
              ? KitIconName.expand.label
              : KitIconName.collapse.label,
          onTap: onCollapse,
          child: penPanelHeadIcon(
            collapsed ? KitIconName.expand : KitIconName.collapse,
          ),
        ),
        PenPanelHeadButton(
          key: const ValueKey('pen-panel-close'),
          left: inner - KitTokens.penPanelCloseSize,
          label: KitIconName.close.label,
          onTap: onClose,
          size: KitTokens.penPanelCloseSize,
          child: const PenPanelCloseMark(key: ValueKey('pen-panel-close-mark')),
        ),
      ],
    );
  }
}

/// A head button, 44 x 44 from the panel's top edge, its icon [left] in from
/// its own left edge and as high as the preview draws it.
class PenPanelHeadButton extends StatelessWidget {
  const new({
    super.key,
    required this.left,
    required this.label,
    required this.onTap,
    required this.child,
    this.size = KitTokens.penPanelIconSize,
    this.selected,
  });

  final double left;
  final String label;
  final VoidCallback? onTap;
  final Widget child;

  /// The drawn height of [child]: the 22 icons stand 1 above the close circle.
  final double size;
  final bool? selected;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    enabled: onTap != null,
    selected: selected,
    label: label,
    onTap: onTap,
    excludeSemantics: true,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        width: KitTokens.penPanelHeadHit,
        height: KitTokens.penPanelHeadHit,
        child: Padding(
          padding: EdgeInsets.only(
            left: left,
            top:
                KitTokens.penPanelPadTop -
                (size - KitTokens.penPanelHeadHeight) / 2,
          ),
          child: Align(alignment: Alignment.topLeft, child: child),
        ),
      ),
    ),
  );
}

/// Samsung's close button: the X in a light grey circle (`.xbtn`).
class PenPanelCloseMark extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) => const SizedBox.square(
    dimension: KitTokens.penPanelCloseSize,
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: KitTokens.penPanelCloseBg,
        shape: BoxShape.circle,
      ),
      child: Center(
        child: KitIcon(
          KitIconName.close,
          size: KitTokens.penPanelCloseIconSize,
          strokeWidth: KitTokens.penPanelCloseIconStroke,
          color: KitTokens.penPanelCloseInk,
        ),
      ),
    ),
  );
}
