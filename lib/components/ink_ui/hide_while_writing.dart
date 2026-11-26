import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:saber/components/kit/kit_motion.dart';
import 'package:saber/components/kit/kit_tokens.dart';

/// Gets [child] out of the way of the page's strokes (task-13B-values.md
/// §13-3, user 2026-11-20): when the tip of a stroke ([strokeAt]) comes
/// within [KitTokens.floatingBarHideMargin] of the drawn part, it fades out
/// in [KitMotion.floatingBarHide] and takes no presses, so the page under
/// it can be written on; [KitMotion.floatingBarHideWait] after the pen is
/// lifted it fades in again in [show] on [showCurve]. A stroke started in
/// the wait keeps it hidden and the wait starts over. A pen only hovering is
/// no stroke, so it never hides it. With less motion it goes and comes at
/// once. It changes its own fade and nothing else.
class HideWhileWriting extends StatefulWidget {
  const new({
    super.key,
    required this.strokeAt,
    required this.child,
    this.drawnInside = EdgeInsets.zero,
    this.show = KitMotion.floatingBarShow,
    this.showCurve = KitMotion.normalCurve,
  });

  /// The stroke's tip on the screen, null while there is no stroke.
  final ValueListenable<Offset?>? strokeAt;
  final Widget child;

  /// How far inside the child's box the drawn part sits (a press area
  /// larger than what is seen).
  final EdgeInsets drawnInside;
  final Duration show;
  final Curve showCurve;

  @override
  State<HideWhileWriting> createState() => _HideWhileWritingState();
}

class _HideWhileWritingState extends State<HideWhileWriting>
    with SingleTickerProviderStateMixin {
  late final _fade = AnimationController(vsync: this, value: 1);
  final _hidden = ValueNotifier(false);
  Timer? _wait;

  @override
  void initState() {
    super.initState();
    widget.strokeAt?.addListener(_follow);
  }

  @override
  void didUpdateWidget(HideWhileWriting old) {
    super.didUpdateWidget(old);
    if (old.strokeAt != widget.strokeAt) {
      old.strokeAt?.removeListener(_follow);
      widget.strokeAt?.addListener(_follow);
    }
  }

  @override
  void dispose() {
    widget.strokeAt?.removeListener(_follow);
    _wait?.cancel();
    _fade.dispose();
    _hidden.dispose();
    super.dispose();
  }

  /// The drawn part with the margin around it, on the screen.
  Rect? _area() {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.attached || !box.hasSize) return null;
    final drawn = widget.drawnInside.deflateRect(Offset.zero & box.size);
    return MatrixUtils.transformRect(
      box.getTransformTo(null),
      drawn,
    ).inflate(KitTokens.floatingBarHideMargin);
  }

  bool get _still => MediaQuery.disableAnimationsOf(context);

  void _follow() {
    if (!mounted) return;
    final tip = widget.strokeAt!.value;
    if (tip == null) {
      if (_hidden.value) {
        _wait?.cancel();
        _wait = Timer(KitMotion.floatingBarHideWait, _comeBack);
      }
      return;
    }
    if (_hidden.value) {
      // writing again in the wait: stay hidden, wait again after this one
      _wait?.cancel();
      return;
    }
    if (_area()?.contains(tip) ?? false) {
      _hidden.value = true;
      unawaited(
        _fade.animateTo(
          0,
          duration: _still ? Duration.zero : KitMotion.floatingBarHide,
          curve: KitMotion.fastCurve,
        ),
      );
    }
  }

  void _comeBack() {
    if (!mounted) return;
    _hidden.value = false;
    unawaited(
      _fade.animateTo(
        1,
        duration: _still ? Duration.zero : widget.show,
        curve: widget.showCurve,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: _fade,
    child: ValueListenableBuilder(
      valueListenable: _hidden,
      // hidden, it takes no presses and screen readers do not reach it
      builder: (context, hidden, child) => IgnorePointer(
        ignoring: hidden,
        child: ExcludeSemantics(excluding: hidden, child: child),
      ),
      child: widget.child,
    ),
  );
}
