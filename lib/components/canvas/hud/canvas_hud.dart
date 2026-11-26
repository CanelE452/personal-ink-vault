import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:saber/components/ink_ui/kit_zoom_badge.dart';
import 'package:saber/components/kit/kit_motion.dart';
import 'package:saber/data/extensions/matrix4_extensions.dart';

/// The scale of a [TransformationController] that notifies only when the
/// scale changes, so scrolling and panning leave it quiet.
class ControllerScale extends ValueNotifier<double> {
  new(this.controller) : super(controller.value.approxScale) {
    controller.addListener(_sync);
  }

  final TransformationController controller;

  void _sync() => value = controller.value.approxScale;

  @override
  void dispose() {
    controller.removeListener(_sync);
    super.dispose();
  }
}

/// The zoom badge over a page canvas (Task 13B). It appears only while the
/// zoom changes and, pressed, goes back to 100 % in
/// [KitMotion.zoomBadgeReset] (the preview's `zoomReset`, slowing to the
/// end, `1 - (1 - k)^3`); the zoom lock lives in the toolbar settings.
class CanvasHud extends StatefulWidget {
  const new({
    super.key,
    required this.transformationController,
    required this.setScale,
    this.shouldShow,
    this.touching,
  });

  final TransformationController transformationController;

  /// Null while zoom is locked.
  final ValueChanged<double>? setScale;

  /// See [KitZoomBadge.shouldShow]; null shows every change.
  final bool Function()? shouldShow;

  /// See [KitZoomBadge.touching].
  final ValueListenable<bool>? touching;

  @override
  State<CanvasHud> createState() => _CanvasHudState();
}

class _CanvasHudState extends State<CanvasHud>
    with SingleTickerProviderStateMixin {
  late var _scale = ControllerScale(widget.transformationController);
  late final _reset = AnimationController(vsync: this);
  double _resetFrom = 1;

  @override
  void initState() {
    super.initState();
    _reset.addListener(() {
      final setScale = widget.setScale;
      if (setScale == null) return _reset.stop();
      final k = _reset.value;
      setScale(_resetFrom + (1 - _resetFrom) * (1 - math.pow(1 - k, 3)));
    });
  }

  @override
  void didUpdateWidget(CanvasHud oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.transformationController != widget.transformationController) {
      _scale.dispose();
      _scale = ControllerScale(widget.transformationController);
    }
  }

  @override
  void dispose() {
    _reset.dispose();
    _scale.dispose();
    super.dispose();
  }

  void _goBack() {
    _resetFrom = _scale.value;
    _reset.duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : KitMotion.zoomBadgeReset;
    unawaited(_reset.forward(from: 0));
  }

  @override
  Widget build(BuildContext context) => KitZoomBadge(
    key: const ValueKey('zoom-badge'),
    scale: _scale,
    shouldShow: widget.shouldShow ?? () => true,
    onReset: widget.setScale == null ? null : _goBack,
    touching: widget.touching,
  );
}
