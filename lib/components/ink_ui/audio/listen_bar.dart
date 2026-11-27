import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show KeyDownEvent, KeyRepeatEvent, LogicalKeyboardKey;
import 'package:saber/components/ink_ui/side_panel/audio_tab.dart';
import 'package:saber/components/kit/kit_icon.dart';
import 'package:saber/components/kit/kit_text.dart';
import 'package:saber/components/kit/kit_tokens.dart';

/// The speed as the speed button writes it (`SPD`): 「1×」, 「1.25×」.
String kitSpeedLabel(double speed) =>
    '${speed == speed.roundToDouble() ? speed.toInt() : speed}×';

/// The listening bar over the page area (12th draft `.r1play`, `playHtml`):
/// play or pause, [title] (not on a [phone]), the [position] and the track
/// to drag or press ([onSeek]), the [length], the [speed] ([onSpeed] steps
/// it) and close ([onClose]). It fills its parent and stands in the middle,
/// [KitTokens.listenBarBottom] over its foot, drawn on its own (a new
/// position paints the bar only). Where the device cannot play, the play
/// button is dim and does nothing.
class KitListenBar extends StatefulWidget {
  const new({
    super.key,
    required this.title,
    required this.position,
    required this.length,
    required this.playing,
    required this.speed,
    required this.phone,
    this.enabled = true,
    required this.onPlayPause,
    required this.onSeek,
    required this.onSpeed,
    required this.onClose,
  });

  final String title;
  final Duration position;
  final Duration length;
  final bool playing;
  final double speed;
  final bool phone;
  final bool enabled;
  final VoidCallback onPlayPause;
  final ValueChanged<Duration> onSeek;
  final VoidCallback onSpeed;
  final VoidCallback onClose;

  @override
  State<KitListenBar> createState() => _KitListenBarState();
}

class _KitListenBarState extends State<KitListenBar> {
  /// Where the track is being dragged to, as a share of the length.
  double? _dragging;

  Duration _at(double share) => widget.length * share.clamp(0.0, 1.0);

  double get _share {
    if (_dragging case final share?) return share;
    final length = widget.length.inMilliseconds;
    return length <= 0
        ? 0
        : (widget.position.inMilliseconds / length).clamp(0.0, 1.0);
  }

  /// The position [by] from where it is, inside the recording.
  Duration _from(Duration by) => Duration(
    milliseconds: (widget.position + by).inMilliseconds.clamp(
      0,
      widget.length.inMilliseconds,
    ),
  );

  /// How the track reads [at] out: 「09:02 / 41:05」.
  String _clock(Duration at) =>
      '${kitAudioClock(at)} / ${kitAudioClock(widget.length)}';

  @override
  Widget build(BuildContext context) {
    final share = _share;
    final shown = _dragging == null ? widget.position : _at(share);
    const time = TextStyle(
      fontSize: KitTokens.listenTimeFontSize,
      height: KitTokens.sideLineHeight,
      letterSpacing: 0,
      color: KitTokens.listenTimeInk,
      fontFeatures: [FontFeature.tabularFigures()],
    );
    const step = KitTokens.listenKeyStep;
    final row = Row(
      children: [
        _Button(
          key: const ValueKey('kit-listen-play'),
          label: widget.playing ? '일시 정지' : '재생',
          onTap: widget.enabled ? widget.onPlayPause : null,
          child: Opacity(
            opacity: widget.enabled ? 1 : KitTokens.disabledOpacity,
            child: SizedBox.square(
              dimension: KitTokens.listenPlaySize,
              child: DecoratedBox(
                decoration: const BoxDecoration(
                  color: KitTokens.listenPlayBg,
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: KitIcon(
                    widget.playing ? KitIconName.pause : KitIconName.play,
                    size: KitTokens.listenIconSize,
                    strokeWidth: KitTokens.listenIconStroke,
                    color: KitTokens.listenPlayInk,
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: KitTokens.listenBarGap),
        if (!widget.phone) ...[
          ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: KitTokens.listenNameMaxWidth,
            ),
            child: KitText(
              widget.title,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: KitTokens.listenNameFontSize,
                height: KitTokens.sideLineHeight,
                letterSpacing: 0,
                fontWeight: FontWeight.w600,
                color: KitTokens.listenNameInk,
              ),
            ),
          ),
          const SizedBox(width: KitTokens.listenBarGap),
        ],
        ExcludeSemantics(
          child: KitText(kitAudioClock(shown), maxLines: 1, style: time),
        ),
        const SizedBox(width: KitTokens.listenBarGap),
        Expanded(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minWidth: KitTokens.listenTrackMinWidth,
            ),
            child: _Track(
              share: share,
              value: _clock(shown),
              increased: _clock(_from(step)),
              decreased: _clock(_from(-step)),
              onDrag: (s) => setState(() => _dragging = s),
              onLet: (s) {
                setState(() => _dragging = null);
                widget.onSeek(_at(s));
              },
              onDrop: () => setState(() => _dragging = null),
              onStep: (forward) => widget.onSeek(_from(forward ? step : -step)),
            ),
          ),
        ),
        const SizedBox(width: KitTokens.listenBarGap),
        ExcludeSemantics(
          child: KitText(
            kitAudioClock(widget.length),
            maxLines: 1,
            style: time,
          ),
        ),
        const SizedBox(width: KitTokens.listenBarGap - KitTokens.listenReachH),
        _Button(
          key: const ValueKey('kit-listen-speed'),
          label: '재생 속도 ${kitSpeedLabel(widget.speed)}',
          onTap: widget.onSpeed,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: KitTokens.listenReachH,
              vertical: KitTokens.listenReachV,
            ),
            child: Container(
              height: KitTokens.listenSpeedHeight,
              constraints: const BoxConstraints(
                minWidth: KitTokens.listenSpeedMinWidth,
              ),
              padding: const EdgeInsets.symmetric(
                horizontal: KitTokens.listenSpeedPadH,
              ),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: KitTokens.listenSpeedBg,
                borderRadius: BorderRadius.circular(
                  KitTokens.listenSpeedRadius,
                ),
                border: Border.all(
                  color: KitTokens.listenBarLine,
                  width: KitTokens.listenBarLineWidth,
                ),
              ),
              child: KitText(
                kitSpeedLabel(widget.speed),
                maxLines: 1,
                style: const TextStyle(
                  fontSize: KitTokens.listenSpeedFontSize,
                  height: KitTokens.listenSpeedLineHeight,
                  letterSpacing: 0,
                  fontWeight: FontWeight.w600,
                  color: KitTokens.menuInk,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: KitTokens.listenCloseGap),
        _Button(
          key: const ValueKey('kit-listen-close'),
          label: '듣기 닫기',
          onTap: widget.onClose,
          child: const Padding(
            padding: EdgeInsets.symmetric(
              horizontal: KitTokens.listenReachH,
              vertical: KitTokens.listenReachV,
            ),
            child: SizedBox.square(
              dimension: KitTokens.listenCloseSize,
              child: Center(
                child: KitIcon(
                  KitIconName.close,
                  size: KitTokens.listenIconSize,
                  strokeWidth: KitTokens.listenIconStroke,
                  color: KitTokens.listenCloseInk,
                ),
              ),
            ),
          ),
        ),
      ],
    );
    return LayoutBuilder(
      builder: (context, box) => Align(
        alignment: Alignment.bottomCenter,
        child: Padding(
          padding: const EdgeInsets.only(bottom: KitTokens.listenBarBottom),
          child: SizedBox(
            key: const ValueKey('kit-listen-bar'),
            width: math.min(
              KitTokens.listenBarMaxWidth,
              box.maxWidth - KitTokens.listenBarMargin,
            ),
            height: KitTokens.playerBarHeight,
            child: RepaintBoundary(
              child: Semantics(
                container: true,
                label: '듣기',
                explicitChildNodes: true,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: KitTokens.playerBarBg,
                    borderRadius: BorderRadius.circular(
                      KitTokens.listenBarRadius,
                    ),
                    border: Border.all(
                      color: KitTokens.listenBarLine,
                      width: KitTokens.listenBarLineWidth,
                    ),
                    boxShadow: KitTokens.listenBarShadow,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.only(
                      left:
                          KitTokens.listenBarLineWidth +
                          KitTokens.listenBarPadH,
                      right:
                          KitTokens.listenBarLineWidth +
                          KitTokens.listenBarPadH -
                          KitTokens.listenReachH,
                    ),
                    child: row,
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

/// A button of the bar: [child] is what is pressed.
class _Button extends StatelessWidget {
  const new({
    super.key,
    required this.label,
    required this.onTap,
    required this.child,
  });

  final String label;
  final VoidCallback? onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    button: true,
    enabled: onTap != null,
    label: label,
    excludeSemantics: true,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: child,
    ),
  );
}

/// `.trk`: the line, the played part to [share] and the thumb on it, read
/// out as [value] ([increased], [decreased] a step on). A press or a drag
/// moves it ([onDrag] as it goes, [onLet] where it is let go; [onDrop] when
/// a drag is given up, as when it turns out a press); an arrow key steps it
/// ([onStep], forward or back).
class _Track extends StatelessWidget {
  const new({
    required this.share,
    required this.value,
    required this.increased,
    required this.decreased,
    required this.onDrag,
    required this.onLet,
    required this.onDrop,
    required this.onStep,
  });

  final double share;
  final String value;
  final String increased;
  final String decreased;
  final ValueChanged<double> onDrag;
  final ValueChanged<double> onLet;
  final VoidCallback onDrop;
  final ValueChanged<bool> onStep;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final width = box.maxWidth;
      double at(Offset local) => width <= 0 ? 0 : local.dx / width;
      var last = share;
      return Semantics(
        key: const ValueKey('kit-listen-track'),
        slider: true,
        label: '재생 위치',
        value: value,
        increasedValue: increased,
        decreasedValue: decreased,
        onIncrease: () => onStep(true),
        onDecrease: () => onStep(false),
        child: Focus(
          onKeyEvent: (node, event) {
            if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
              return KeyEventResult.ignored;
            }
            if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
              onStep(true);
            } else if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
              onStep(false);
            } else {
              return KeyEventResult.ignored;
            }
            return KeyEventResult.handled;
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (details) => onLet(at(details.localPosition)),
            onHorizontalDragStart: (details) =>
                onDrag(last = at(details.localPosition).clamp(0.0, 1.0)),
            onHorizontalDragUpdate: (details) =>
                onDrag(last = at(details.localPosition).clamp(0.0, 1.0)),
            onHorizontalDragEnd: (_) => onLet(last),
            onHorizontalDragCancel: onDrop,
            child: SizedBox(
              height: KitTokens.listenTrackHeight,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  const Positioned(
                    left: 0,
                    right: 0,
                    top: KitTokens.listenTrackLineTop,
                    height: KitTokens.listenTrackLine,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: KitTokens.listenTrackBg,
                        borderRadius: BorderRadius.all(
                          Radius.circular(KitTokens.listenTrackRadius),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 0,
                    width: width * share,
                    top: KitTokens.listenTrackLineTop,
                    height: KitTokens.listenTrackLine,
                    child: const DecoratedBox(
                      decoration: BoxDecoration(
                        color: KitTokens.listenTrackFill,
                        borderRadius: BorderRadius.all(
                          Radius.circular(KitTokens.listenTrackRadius),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: width * share - KitTokens.listenThumbSize / 2,
                    top: KitTokens.listenThumbTop,
                    width: KitTokens.listenThumbSize,
                    height: KitTokens.listenThumbSize,
                    child: const DecoratedBox(
                      decoration: BoxDecoration(
                        color: KitTokens.listenThumbBg,
                        shape: BoxShape.circle,
                        boxShadow: KitTokens.listenThumbShadow,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}
