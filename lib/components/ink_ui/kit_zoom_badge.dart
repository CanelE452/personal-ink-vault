import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:saber/components/kit/kit_motion.dart';
import 'package:saber/components/kit/kit_pop_in.dart';
import 'package:saber/components/kit/kit_text.dart';
import 'package:saber/components/kit/kit_tokens.dart';

/// The scales one can pick: the ⋯ 「확대 비율」 list and the infinite note's
/// zoom pill. 1.0 fits the page to the width.
const zoomSteps = [0.5, 0.75, 1.0, 1.5, 2.0, 3.0];

/// The zoom badge at the top middle of the page area (preview `.zoompill`,
/// task-13B-values.md §8): while the scale changes by more than 2 % it
/// shows the scale, 「150%」. It stays while fingers are on the page
/// ([touching]) and goes [KitMotion.zoomBadgeHide] after they lift, or after
/// the last change when nothing touches (a wheel, the reset) — the preview's
/// `zoomRelease`. A press goes back to 100 % ([onReset]; null while zoom is
/// locked, and then it cannot be pressed). The scale list and the lock are
/// not here (Task 14 「확대 비율」).
///
/// It fills the page area and places itself.
class KitZoomBadge extends StatefulWidget {
  const new({
    super.key,
    required this.scale,
    required this.shouldShow,
    this.onReset,
    this.touching,
  });

  final ValueListenable<double> scale;

  /// Whether a change shows it: false keeps the zooms the app makes by
  /// itself (the fit when a note opens) quiet.
  final bool Function() shouldShow;
  final VoidCallback? onReset;

  /// Whether fingers are on the page now.
  final ValueListenable<bool>? touching;

  @override
  State<KitZoomBadge> createState() => _KitZoomBadgeState();
}

class _KitZoomBadgeState extends State<KitZoomBadge> {
  Timer? _hideTimer;

  /// The scale when it last went; it comes again only after a 2 % change,
  /// so the slight drift of a two-finger pan stays quiet.
  late double _baseline;

  /// Up (or coming).
  var _up = false;

  bool get _touching => widget.touching?.value ?? false;

  @override
  void initState() {
    super.initState();
    // read now: a lazy read in [_follow] would see the scale after the change
    _baseline = widget.scale.value;
    widget.scale.addListener(_follow);
    widget.touching?.addListener(_lifted);
  }

  @override
  void didUpdateWidget(KitZoomBadge old) {
    super.didUpdateWidget(old);
    if (old.scale != widget.scale) {
      old.scale.removeListener(_follow);
      widget.scale.addListener(_follow);
      _baseline = widget.scale.value;
    }
    if (old.touching != widget.touching) {
      old.touching?.removeListener(_lifted);
      widget.touching?.addListener(_lifted);
    }
  }

  @override
  void dispose() {
    widget.scale.removeListener(_follow);
    widget.touching?.removeListener(_lifted);
    _hideTimer?.cancel();
    super.dispose();
  }

  void _follow() {
    if (!mounted) return;
    final scale = widget.scale.value;
    if (!widget.shouldShow()) {
      if (!_up) _baseline = scale;
      return;
    }
    if (!_up && (scale - _baseline).abs() < _baseline.abs() * .02) return;
    setState(() => _up = true);
    _hideLater();
  }

  /// Counts the hide from now, unless fingers are still on the page.
  void _hideLater() {
    _hideTimer?.cancel();
    if (_touching) return;
    _hideTimer = Timer(KitMotion.zoomBadgeHide, () {
      if (!mounted) return;
      _baseline = widget.scale.value;
      setState(() => _up = false);
    });
  }

  void _lifted() {
    if (_up && !_touching) _hideLater();
    if (_touching) _hideTimer?.cancel();
  }

  @override
  Widget build(BuildContext context) {
    final onReset = widget.onReset;
    const lift = (KitTokens.saveChipHitHeight - KitTokens.darkPillHeight) / 2;
    final percent = '${(widget.scale.value * 100).round()}%';
    return Align(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: const EdgeInsets.only(top: KitTokens.zoomBadgeTop - lift),
        // opacity linear, the move on the deceleration (`.zoompill`)
        child: KitPopIn(
          shown: _up,
          open: KitMotion.zoomBadgeOpen,
          close: KitMotion.zoomBadgeClose,
          shift: -KitTokens.zoomBadgeShift,
          linearFade: true,
          child: Semantics(
            button: true,
            enabled: onReset != null,
            label: '100%로 되돌리기',
            value: percent,
            onTap: onReset,
            excludeSemantics: true,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              excludeFromSemantics: true,
              onTap: onReset,
              child: MouseRegion(
                cursor: onReset == null
                    ? MouseCursor.defer
                    : SystemMouseCursors.click,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: lift),
                  child: KitDarkPill(
                    key: const ValueKey('zoom-badge-pill'),
                    text: percent,
                    minWidth: KitTokens.zoomBadgeMinWidth,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The dark pill the zoom badge and the mode pill share: 30 high and round,
/// 14 either side of white 13 semibold words, at least [minWidth] wide.
class KitDarkPill extends StatelessWidget {
  const new({super.key, required this.text, this.minWidth = 0});

  final String text;
  final double minWidth;

  @override
  Widget build(BuildContext context) => Container(
    height: KitTokens.darkPillHeight,
    constraints: BoxConstraints(minWidth: minWidth),
    padding: const EdgeInsets.symmetric(horizontal: KitTokens.zoomBadgePadH),
    decoration: BoxDecoration(
      color: KitTokens.darkPillBg,
      borderRadius: BorderRadius.circular(KitTokens.darkPillHeight / 2),
    ),
    // as wide as the words
    child: Center(
      widthFactor: 1,
      child: KitText(
        text,
        maxLines: 1,
        // no letter spacing (the theme's body text has .25)
        style: const TextStyle(
          fontSize: KitTokens.darkPillFontSize,
          fontWeight: FontWeight.w600,
          letterSpacing: 0,
          color: KitTokens.darkPillInk,
        ),
      ),
    ),
  );
}
