import 'package:flutter/material.dart';
import 'package:saber/components/canvas/hud/zoom_pill.dart';

/// The zoom pill over a page canvas. It appears only while the zoom changes;
/// the pan locks live in the toolbar settings.
class CanvasHud extends StatefulWidget {
  const new({
    super.key,
    required this.transformationController,
    required this.zoomLock,
    required this.setZoomLock,
    required this.setScale,
    this.shouldShow,
  });

  final TransformationController transformationController;
  final bool zoomLock;
  final ValueChanged<bool> setZoomLock;

  /// Null while zoom is locked.
  final ValueChanged<double>? setScale;

  /// See [ZoomPillOverlay.shouldShow].
  final bool Function()? shouldShow;

  @override
  State<CanvasHud> createState() => _CanvasHudState();
}

class _CanvasHudState extends State<CanvasHud> {
  late var _scale = ControllerScale(widget.transformationController);

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
    _scale.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ZoomPillOverlay(
    scale: _scale,
    onSelectScale: widget.setScale,
    fitLabel: '100% (폭 맞춤)',
    zoomLocked: widget.zoomLock,
    onZoomLockChanged: widget.setZoomLock,
    shouldShow: widget.shouldShow,
  );
}
