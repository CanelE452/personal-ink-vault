import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:saber/components/ink_ui/side_panel/audio_tab.dart';
import 'package:saber/components/kit/kit_icon.dart';
import 'package:saber/components/kit/kit_motion.dart';
import 'package:saber/components/kit/kit_text.dart';
import 'package:saber/components/kit/kit_tokens.dart';

/// Whether a recording runs: not, on, paused, or stopped and being saved.
enum KitRecording { off, on, paused, saving }

/// The recording pill over the page area's top right (12th draft `.r1rec`,
/// `recHtml`): the dot, 「녹음 중」 or 「일시 정지」, the time recorded
/// ([elapsed], in whole seconds), pause or resume ([onPauseResume]) and
/// stop ([onStop]). It fills its parent and is drawn on its own: the time
/// moving paints the pill only, and builds its time alone. On, the dot
/// blinks in two steps (a timer, not a frame each tick); [paused], it is
/// grey and still. [boxKey] marks the pill itself (others keep out of its
/// way).
class KitRecordPill extends StatelessWidget {
  const new({
    super.key,
    required this.paused,
    required this.elapsed,
    required this.onPauseResume,
    required this.onStop,
    this.boxKey,
  });

  final bool paused;
  final ValueListenable<Duration> elapsed;
  final VoidCallback onPauseResume;
  final VoidCallback onStop;
  final GlobalKey? boxKey;

  static const _text = TextStyle(
    fontSize: KitTokens.recFontSize,
    height: KitTokens.lineHeightOne,
    letterSpacing: 0,
    fontWeight: FontWeight.w600,
    color: KitTokens.recInk,
  );

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topRight,
    child: Padding(
      padding: const EdgeInsets.only(
        top: KitTokens.recPillInset,
        right: KitTokens.recPillInset,
      ),
      child: RepaintBoundary(
        key: boxKey,
        child: Semantics(
          container: true,
          label: '녹음',
          explicitChildNodes: true,
          child: Container(
            key: const ValueKey('kit-record-pill'),
            height: KitTokens.recPillHeight,
            // the last button takes the padding after it
            padding: EdgeInsets.only(left: KitTokens.recPillPadding.left),
            decoration: BoxDecoration(
              color: KitTokens.recPillBg,
              borderRadius: BorderRadius.circular(KitTokens.recPillRadius),
              boxShadow: KitTokens.recPillShadow,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _Dot(paused: paused),
                const SizedBox(
                  width: KitTokens.recDotGap + KitTokens.recPillGap,
                ),
                KitText(
                  paused ? '일시 정지' : '녹음 중',
                  maxLines: 1,
                  style: _text.copyWith(
                    fontWeight: FontWeight.w400,
                    color: KitTokens.recLabelInk,
                  ),
                ),
                const SizedBox(
                  width: KitTokens.recLabelGap + KitTokens.recPillGap,
                ),
                ConstrainedBox(
                  constraints: const BoxConstraints(
                    minWidth: KitTokens.recTimeMinWidth,
                  ),
                  child: _Time(elapsed: elapsed, style: _text),
                ),
                // the gaps beside the buttons are theirs to press: the gap
                // before, half the gap between, and the padding after
                _Button(
                  circleKey: const ValueKey('kit-record-pause'),
                  label: paused ? '이어서 녹음' : '일시 정지',
                  icon: paused ? KitIconName.recDot : KitIconName.pause,
                  ink: paused ? KitTokens.recRed : KitTokens.recInk,
                  reach: const EdgeInsets.fromLTRB(
                    KitTokens.recPillGap,
                    KitTokens.recButtonReach,
                    KitTokens.recPillGap / 2,
                    KitTokens.recButtonReach,
                  ),
                  onTap: onPauseResume,
                ),
                _Button(
                  circleKey: const ValueKey('kit-record-stop'),
                  label: '녹음 멈춤',
                  icon: KitIconName.stopSq,
                  ink: KitTokens.recInk,
                  reach: EdgeInsets.fromLTRB(
                    KitTokens.recPillGap / 2,
                    KitTokens.recButtonReach,
                    KitTokens.recPillPadding.right,
                    KitTokens.recButtonReach,
                  ),
                  onTap: onStop,
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// The dot: red, at full and then [KitTokens.recDotDim] for half of
/// [KitMotion.recBlink] each (`steps(2, jump-none)`); paused, grey and
/// whole. Without animations it stays whole.
class _Dot extends StatefulWidget {
  const new({required this.paused});

  final bool paused;

  @override
  State<_Dot> createState() => _DotState();
}

class _DotState extends State<_Dot> {
  Timer? _timer;
  var _dim = false;

  void _blink(bool on) {
    _timer?.cancel();
    _timer = null;
    _dim = false;
    if (!on) return;
    _timer = Timer.periodic(
      KitMotion.recBlink ~/ 2,
      (_) => setState(() => _dim = !_dim),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _blink(!widget.paused && !MediaQuery.disableAnimationsOf(context));
  }

  @override
  void didUpdateWidget(_Dot old) {
    super.didUpdateWidget(old);
    if (old.paused != widget.paused) {
      _blink(!widget.paused && !MediaQuery.disableAnimationsOf(context));
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Opacity(
    opacity: _dim ? KitTokens.recDotDim : 1,
    child: SizedBox.square(
      dimension: KitTokens.recDotSize,
      child: DecoratedBox(
        key: const ValueKey('kit-record-dot'),
        decoration: BoxDecoration(
          color: widget.paused ? KitTokens.recDotPaused : KitTokens.recRed,
          shape: BoxShape.circle,
        ),
      ),
    ),
  );
}

/// The time recorded, built again only when its whole seconds change.
class _Time extends StatefulWidget {
  const new({required this.elapsed, required this.style});

  final ValueListenable<Duration> elapsed;
  final TextStyle style;

  @override
  State<_Time> createState() => _TimeState();
}

class _TimeState extends State<_Time> {
  late int _seconds = widget.elapsed.value.inSeconds;

  void _changed() {
    final seconds = widget.elapsed.value.inSeconds;
    if (seconds != _seconds) setState(() => _seconds = seconds);
  }

  @override
  void initState() {
    super.initState();
    widget.elapsed.addListener(_changed);
  }

  @override
  void didUpdateWidget(_Time old) {
    super.didUpdateWidget(old);
    if (old.elapsed != widget.elapsed) {
      old.elapsed.removeListener(_changed);
      widget.elapsed.addListener(_changed);
      _changed();
    }
  }

  @override
  void dispose() {
    widget.elapsed.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => KitText(
    kitAudioClock(Duration(seconds: _seconds)),
    maxLines: 1,
    style: widget.style.copyWith(
      fontFeatures: const [FontFeature.tabularFigures()],
    ),
  );
}

/// A round button of the pill ([circleKey] on its circle), with [icon] in
/// [ink]; it takes presses over [reach] round the circle too.
class _Button extends StatelessWidget {
  const new({
    required this.circleKey,
    required this.label,
    required this.icon,
    required this.ink,
    required this.reach,
    required this.onTap,
  });

  final Key circleKey;
  final String label;
  final KitIconName icon;
  final Color ink;
  final EdgeInsets reach;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    button: true,
    label: label,
    excludeSemantics: true,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: reach,
        child: SizedBox.square(
          key: circleKey,
          dimension: KitTokens.recButtonSize,
          child: DecoratedBox(
            decoration: const BoxDecoration(
              color: KitTokens.recButtonBg,
              shape: BoxShape.circle,
            ),
            child: Center(
              child: KitIcon(
                icon,
                size: KitTokens.recIconSize,
                strokeWidth: KitTokens.recIconStroke,
                color: ink,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
