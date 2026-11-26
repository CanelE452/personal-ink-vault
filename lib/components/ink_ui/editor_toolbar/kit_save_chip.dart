import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:saber/components/ink_ui/hide_while_writing.dart';
import 'package:saber/components/kit/kit_motion.dart';
import 'package:saber/components/kit/kit_pop_in.dart';
import 'package:saber/components/kit/kit_text.dart';
import 'package:saber/components/kit/kit_tokens.dart';
import 'package:saber/data/actions/app_action_ids.dart';
import 'package:saber/data/actions/app_action_registry.dart';
import 'package:saber/data/editor/saving_state.dart';
import 'package:saber/data/is_this_a_test.dart';
import 'package:saber/data/prefs.dart';

/// What the chip says.
enum _Say { saving, failed, waiting }

/// The save chip at the page area's top right, under the floating bar
/// (preview `.savechip`, task-13B-values.md §7, 7th draft part 2): nothing
/// while saved; 「저장 중…」 once a save has taken
/// [KitMotion.saveChipDelay]; 「저장 안 됨 · 다시 시도」 at once when a save
/// failed; 「저장 대기 · 지금 저장」 [KitMotion.saveChipDelay] after a change
/// while 「자동 저장」 is 「안 함」 (with auto save on, the save comes by
/// itself, and the chip would stay up through long writing). Waiting and
/// failed, a press runs the document's `save` (without one, the chip only
/// tells). It keeps its own timers, so the editor is not built again, and
/// gets out of a stroke's way as the floating bar does.
///
/// It fills the page area and places itself.
class KitSaveChip extends StatefulWidget {
  const new({
    super.key,
    required this.state,
    required this.actions,
    this.strokeAt,
  });

  final ValueListenable<SavingState> state;
  final AppActionRegistry actions;

  /// The tip of the stroke on the page now ([HideWhileWriting]).
  final ValueListenable<Offset?>? strokeAt;

  @override
  State<KitSaveChip> createState() => _KitSaveChipState();
}

class _KitSaveChipState extends State<KitSaveChip> {
  Timer? _timer;

  /// What it says, or said while it goes ([KitPopIn] keeps it until gone).
  _Say? _say;

  /// Whether it is up (or coming).
  var _up = false;

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_follow);
    // a state other than saved when the chip comes: follow it after the
    // first frame (setState is not allowed before)
    if (widget.state.value != .saved) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _follow();
      });
    }
  }

  @override
  void didUpdateWidget(KitSaveChip old) {
    super.didUpdateWidget(old);
    if (old.state != widget.state) {
      old.state.removeListener(_follow);
      widget.state.addListener(_follow);
      _follow();
    }
  }

  @override
  void dispose() {
    widget.state.removeListener(_follow);
    _timer?.cancel();
    super.dispose();
  }

  void _follow() {
    _timer?.cancel();
    switch (widget.state.value) {
      case .saved:
        _hide();
      case .failed:
        _show(.failed);
      case .saving:
        // a chip that is up turns into 「저장 중…」 at once
        if (_up) {
          _show(.saving);
        } else {
          _later(.saving);
        }
      case .waitingToSave:
        if (stows.autosaveDelay.value >= 0) {
          _hide();
        } else if (_up) {
          _show(.waiting);
        } else {
          _later(.waiting);
        }
    }
  }

  void _later(_Say say) =>
      _timer = Timer(KitMotion.saveChipDelay, () => _show(say));

  void _show(_Say say) {
    if (!mounted) return;
    setState(() {
      _say = say;
      _up = true;
    });
  }

  void _hide() {
    if (_up) setState(() => _up = false);
  }

  void _press() => widget.actions.run(AppActionIds.save, context);

  @override
  Widget build(BuildContext context) {
    final say = _say;
    if (say == null) return const SizedBox.shrink();
    final pressable =
        say != .saving && _up && widget.actions.has(AppActionIds.save);
    // no letter spacing (the theme's body text has .25)
    const style = TextStyle(
      fontSize: KitTokens.saveChipFontSize,
      height: KitTokens.saveChipLineHeight / KitTokens.saveChipFontSize,
      letterSpacing: 0,
      color: KitTokens.saveChipInk,
    );
    // the words and the pressed words are the chip's own flex items, 7
    // apart as the mark is (`.savechip` gap); the words end in a space
    final words = switch (say) {
      .saving => [const KitText('저장 중…', style: style)],
      .failed => [
        KitText(
          '저장 안 됨 · ',
          style: style.copyWith(color: KitTokens.saveChipFailInk),
        ),
        KitText('다시 시도', style: _actionStyle(style)),
      ],
      .waiting => [
        const KitText('저장 대기 · ', style: style),
        KitText('지금 저장', style: _actionStyle(style)),
      ],
    };
    const lift = (KitTokens.saveChipHitHeight - KitTokens.saveChipHeight) / 2;
    return Align(
      alignment: Alignment.topRight,
      child: Padding(
        padding: const EdgeInsets.only(
          top: KitTokens.saveChipTop - lift,
          right: KitTokens.saveChipRight,
        ),
        child: HideWhileWriting(
          strokeAt: widget.strokeAt,
          drawnInside: const EdgeInsets.symmetric(vertical: lift),
          show: KitMotion.saveChipOpen,
          showCurve: KitMotion.samsungDecel,
          child: KitPopIn(
            shown: _up,
            open: KitMotion.saveChipOpen,
            close: KitMotion.saveChipClose,
            shift: -KitTokens.saveChipShift,
            // read out as it changes (`role="status"`)
            child: Semantics(
              liveRegion: true,
              button: pressable,
              onTap: pressable ? _press : null,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                excludeFromSemantics: true,
                onTap: pressable ? _press : null,
                child: MouseRegion(
                  cursor: pressable
                      ? SystemMouseCursors.click
                      : MouseCursor.defer,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: lift),
                    child: _box(say, words),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  TextStyle _actionStyle(TextStyle style) => style.copyWith(
    color: KitTokens.saveChipActionInk,
    fontWeight: FontWeight.w600,
  );

  Widget _box(_Say say, List<Widget> words) => DecoratedBox(
    key: const ValueKey('kit-save-chip'),
    decoration: BoxDecoration(
      color: KitTokens.saveChipBg,
      borderRadius: BorderRadius.circular(KitTokens.saveChipHeight / 2),
      boxShadow: KitTokens.saveChipShadow,
    ),
    child: SizedBox(
      height: KitTokens.saveChipHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: KitTokens.saveChipPadH),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: KitTokens.saveChipGap,
          children: [
            switch (say) {
              .saving => const _Spinner(key: ValueKey('save-chip-spin')),
              .failed => const _Dot(
                key: ValueKey('save-chip-warn'),
                filled: true,
              ),
              .waiting => const _Dot(
                key: ValueKey('save-chip-wait'),
                filled: false,
              ),
            },
            ...words,
          ],
        ),
      ),
    ),
  );
}

/// The failed chip's red dot, or the waiting chip's grey ring (8).
class _Dot extends StatelessWidget {
  const new({super.key, required this.filled});

  final bool filled;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: KitTokens.saveChipMark,
    child: DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: filled ? KitTokens.saveChipWarn : null,
        border: filled
            ? null
            : Border.all(
                color: KitTokens.saveChipWaitRing,
                width: KitTokens.saveChipWaitRingWidth,
              ),
      ),
    ),
  );
}

/// The saving chip's ring (11): grey with its top quarter in the accent,
/// turning once in [KitMotion.saveChipSpin]. In tests it stands still, as
/// the old save indicator's switch did: a test pumping until the screen is
/// still would never end while a save waits on the disk.
class _Spinner extends StatefulWidget {
  const new({super.key});

  @override
  State<_Spinner> createState() => _SpinnerState();
}

class _SpinnerState extends State<_Spinner>
    with SingleTickerProviderStateMixin {
  late final _turn = AnimationController(
    vsync: this,
    duration: KitMotion.saveChipSpin,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (isThisATest || MediaQuery.disableAnimationsOf(context)) {
      _turn.stop();
    } else if (!_turn.isAnimating) {
      unawaited(_turn.repeat());
    }
  }

  @override
  void dispose() {
    _turn.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RotationTransition(
    turns: _turn,
    child: const SizedBox.square(
      dimension: KitTokens.saveChipSpin,
      child: CustomPaint(painter: _SpinnerPainter()),
    ),
  );
}

class _SpinnerPainter extends CustomPainter {
  const new();

  @override
  void paint(Canvas canvas, Size size) {
    // a CSS border: the line inside the 11 box
    const line = KitTokens.saveChipSpinLine;
    final ring = (Offset.zero & size).deflate(line / 2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = line;
    canvas.drawOval(ring, paint..color = KitTokens.saveChipSpinTrack);
    // `border-top-color`: the top quarter, from 45° left of the top
    canvas.drawArc(
      ring,
      -math.pi * 3 / 4,
      math.pi / 2,
      false,
      paint..color = KitTokens.saveChipActionInk,
    );
  }

  @override
  bool shouldRepaint(_SpinnerPainter old) => false;
}
