import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:saber/components/kit/kit_motion.dart';

/// Brings [child] in while [shown] and takes it away after: it fades and
/// moves [shift] (negative from above, positive from below) in [open], back
/// in [close], both on [KitMotion.samsungDecel], quick first and slow at the
/// end either way (the preview's CSS transitions). [linearFade] fades evenly
/// while it moves on the curve (the dark pills). It takes no presses while it
/// goes, is not built once gone, and comes and goes at once with less motion.
/// The save chip, the zoom badge and the mode pill share it.
class KitPopIn extends StatefulWidget {
  const new({
    super.key,
    required this.shown,
    required this.open,
    required this.close,
    required this.shift,
    required this.child,
    this.linearFade = false,
  });

  final bool shown;
  final Duration open;
  final Duration close;
  final double shift;
  final bool linearFade;
  final Widget child;

  @override
  State<KitPopIn> createState() => _KitPopInState();
}

class _KitPopInState extends State<KitPopIn>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(vsync: this);
  late final _move = CurvedAnimation(
    parent: _controller,
    curve: KitMotion.samsungDecel,
    reverseCurve: KitMotion.samsungDecel.flipped,
  );

  @override
  void initState() {
    super.initState();
    _controller.addStatusListener((status) {
      if (status == .dismissed && mounted) setState(() {});
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final still = MediaQuery.disableAnimationsOf(context);
    _controller
      ..duration = still ? Duration.zero : widget.open
      ..reverseDuration = still ? Duration.zero : widget.close;
    if (widget.shown && !_controller.isForwardOrCompleted) {
      unawaited(_controller.forward());
    }
  }

  @override
  void didUpdateWidget(KitPopIn old) {
    super.didUpdateWidget(old);
    if (widget.shown == old.shown) return;
    // forward() again while it opens would start it over
    if (widget.shown) {
      if (!_controller.isForwardOrCompleted) unawaited(_controller.forward());
    } else {
      unawaited(_controller.reverse());
    }
  }

  @override
  void dispose() {
    _move.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_controller.isDismissed && !widget.shown) {
      return const SizedBox.shrink();
    }
    return IgnorePointer(
      ignoring: !widget.shown,
      child: FadeTransition(
        opacity: widget.linearFade ? _controller : _move,
        child: AnimatedBuilder(
          animation: _move,
          builder: (context, child) => Transform.translate(
            offset: Offset(0, widget.shift * (1 - _move.value)),
            child: child,
          ),
          child: widget.child,
        ),
      ),
    );
  }
}
