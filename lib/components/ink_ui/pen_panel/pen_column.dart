import 'dart:ui' show lerpDouble;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:saber/components/kit/kit_motion.dart';
import 'package:saber/components/kit/kit_pen_art.dart';
import 'package:saber/components/kit/kit_tokens.dart';

/// One pen of the pen row: the drawing (the chosen one raised 13 and filled
/// with ink, in penRise) and, on its tip, the sample stroke at the panel's
/// size. After a switch the old sample fades in penSampleOut and the new one
/// writes itself on after penSampleDelay, in penSampleDraw.
class PenPanelColumn extends StatefulWidget {
  const new({
    super.key,
    required this.kind,
    required this.chosen,
    required this.ink,
    required this.ruler,
    required this.level,
    required this.onTap,
    this.alpha = 1,
    this.dash = KitPenDash.solid,
  });

  final KitPenKind kind;
  final bool chosen;

  /// The pen's ink as the page shows it.
  final Color ink;

  /// Straight-line correction is on: ruler ticks and a straight sample.
  final bool ruler;
  final ValueListenable<int> level;
  final VoidCallback onTap;

  /// The sample's opacity (1 is the pen's own) and line.
  final double alpha;
  final KitPenDash dash;

  @override
  State<PenPanelColumn> createState() => _PenPanelColumnState();
}

class _PenPanelColumnState extends State<PenPanelColumn>
    with TickerProviderStateMixin {
  late final AnimationController _shown;
  late final AnimationController _write;

  /// The size the sample showed last while chosen: an old sample fades out
  /// as it was, not at the new pen's size.
  late int _lastLevel;

  @override
  void initState() {
    super.initState();
    _shown = AnimationController(
      vsync: this,
      duration: KitMotion.penSampleOut,
      value: widget.chosen ? 1 : 0,
    );
    _write = AnimationController(
      vsync: this,
      duration: KitMotion.penSampleDelay + KitMotion.penSampleDraw,
      value: 1,
    );
    _lastLevel = widget.level.value;
  }

  bool get _reduce => MediaQuery.disableAnimationsOf(context);

  @override
  void didUpdateWidget(PenPanelColumn old) {
    super.didUpdateWidget(old);
    if (widget.chosen == old.chosen) return;
    if (widget.chosen) {
      _shown.value = 1;
      if (_reduce) {
        _write.value = 1;
      } else {
        _write.forward(from: 0);
      }
    } else if (_reduce) {
      _shown.value = 0;
    } else {
      _shown.reverse(from: 1);
    }
  }

  @override
  void dispose() {
    _shown.dispose();
    _write.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final kind = widget.kind;
    final tip = KitTokens.penSampleTips[kind.previewId] ?? Offset.zero;
    const toPanelX = KitTokens.penArtWidth / KitTokens.penArtSheetWidth;
    const toPanelY = KitTokens.penArtHeight / KitTokens.penArtSheetHeight;
    final base = KitPenArt(kind, widget.ink, ruler: widget.ruler);
    final fill = KitPenArt(
      kind,
      widget.ink,
      selected: true,
      ruler: widget.ruler,
    );
    return Semantics(
      button: true,
      selected: widget.chosen,
      label: kind.label,
      onTap: widget.onTap,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: SizedBox(
          width: KitTokens.penColumnWidth,
          height: KitTokens.penRowHeight,
          child: TweenAnimationBuilder<double>(
            tween: Tween(end: widget.chosen ? 1 : 0),
            duration: _reduce ? Duration.zero : KitMotion.penRise,
            curve: KitMotion.samsungDecel,
            builder: (context, t, sample) => Transform.translate(
              offset: Offset(0, -KitTokens.penRise * t),
              child: Stack(
                key: ValueKey('pen-panel-pen-body-${kind.previewId}'),
                clipBehavior: Clip.none,
                // the sample under the pen, as in the preview's `.pw`
                children: [
                  Positioned(
                    left: tip.dx * toPanelX,
                    top:
                        KitTokens.penArtTop +
                        tip.dy * toPanelY -
                        KitTokens.penSampleSheetHeight *
                            KitTokens.penSampleScale,
                    width: KitTokens.penSampleWidth,
                    height: KitTokens.penSampleHeight,
                    child: sample!,
                  ),
                  Positioned(
                    left: 0,
                    top: KitTokens.penArtTop,
                    width: KitTokens.penArtWidth,
                    height: KitTokens.penArtHeight,
                    child: base,
                  ),
                  if (t > 0)
                    Positioned(
                      left: 0,
                      top: KitTokens.penArtTop,
                      width: KitTokens.penArtWidth,
                      height: KitTokens.penArtHeight,
                      child: Opacity(opacity: t, child: fill),
                    ),
                ],
              ),
            ),
            child: _sample(),
          ),
        ),
      ),
    );
  }

  Widget _sample() => AnimatedBuilder(
    animation: Listenable.merge([_shown, _write]),
    builder: (context, _) {
      if (_shown.value == 0) return const SizedBox.shrink();
      final Widget sample;
      if (widget.chosen) {
        // Written on from the tip to the right, the whole sample at once, so
        // the drawn pencil and the svg pens open the same way.
        final delay = KitMotion.penSampleDelay.inMicroseconds;
        final t = Interval(
          delay / (delay + KitMotion.penSampleDraw.inMicroseconds),
          1,
        ).transform(_write.value);
        sample = ClipRect(
          key: const ValueKey('pen-panel-sample-reveal'),
          clipper: _Reveal(t),
          child: ValueListenableBuilder(
            valueListenable: widget.level,
            builder: (context, level, _) {
              _lastLevel = level;
              return _stroke(level);
            },
          ),
        );
      } else {
        sample = _stroke(_lastLevel);
      }
      return Opacity(opacity: _shown.value, child: sample);
    },
  );

  Widget _stroke(int level) => KitPenSample(
    widget.kind,
    widget.ink,
    level: level,
    alpha: widget.alpha,
    straight: widget.ruler,
    dash: widget.dash,
  );
}

/// Shows the sample from its left edge to [t] of the way past its right edge.
class _Reveal extends CustomClipper<Rect> {
  const new(this.t);

  final double t;

  @override
  Rect getClip(Size size) {
    const reach = KitTokens.penSampleRevealReach;
    return Rect.fromLTRB(
      -reach,
      -reach,
      lerpDouble(0, size.width + reach, t)!,
      size.height + reach,
    );
  }

  @override
  bool shouldReclip(_Reveal old) => old.t != t;
}
