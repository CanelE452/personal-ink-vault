import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:saber/data/extensions/matrix4_extensions.dart';

/// The scales the pill offers. 1.0 is the editor's fit-width scale.
const zoomPillSteps = [0.5, 0.75, 1.0, 1.5, 2.0, 3.0];

/// How long the pill stays after the last zoom change.
const zoomPillHideDelay = Duration(seconds: 2);

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

/// A small pill at the top centre that appears while the scale changes and
/// hides [zoomPillHideDelay] after the last change. It stays while touched
/// or while its scale list is open.
class ZoomPillOverlay extends StatefulWidget {
  const new({
    super.key,
    required this.scale,
    this.onSelectScale,
    this.fitLabel = '100%',
    this.zoomLocked,
    this.onZoomLockChanged,
    this.shouldShow,
  });

  final ValueListenable<double> scale;

  /// Whether a scale change should show the pill; false keeps zooms the app
  /// makes by itself (the fit when a note opens) quiet.
  final bool Function()? shouldShow;

  /// Null disables the scale list (for example while zoom is locked).
  final ValueChanged<double>? onSelectScale;

  /// The label of the 1.0 entry in the scale list.
  final String fitLabel;

  /// Null hides the lock button.
  final bool? zoomLocked;
  final ValueChanged<bool>? onZoomLockChanged;

  @override
  State<ZoomPillOverlay> createState() => _ZoomPillOverlayState();
}

class _ZoomPillOverlayState extends State<ZoomPillOverlay> {
  var _visible = false;
  var _holds = 0;
  Timer? _hideTimer;

  /// The scale when the pill last hid; it shows again only after a 2 % change,
  /// so the slight scale drift of a two-finger pan stays quiet.
  late double _baseline;

  @override
  void initState() {
    super.initState();
    // Read now: a lazy read in _show would see the scale after the change.
    _baseline = widget.scale.value;
    widget.scale.addListener(_show);
  }

  @override
  void didUpdateWidget(ZoomPillOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scale != widget.scale) {
      oldWidget.scale.removeListener(_show);
      widget.scale.addListener(_show);
      _baseline = widget.scale.value;
    }
  }

  @override
  void dispose() {
    widget.scale.removeListener(_show);
    _hideTimer?.cancel();
    super.dispose();
  }

  void _show() {
    if (!mounted) return;
    final scale = widget.scale.value;
    if (widget.shouldShow?.call() == false) {
      if (!_visible) _baseline = scale;
      return;
    }
    if (!_visible && (scale - _baseline).abs() < _baseline.abs() * .02) return;
    setState(() => _visible = true);
    _scheduleHide();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    if (_holds > 0) return;
    _hideTimer = Timer(zoomPillHideDelay, () {
      if (!mounted) return;
      setState(() {
        _visible = false;
        _baseline = widget.scale.value;
      });
    });
  }

  void _hold() {
    _holds++;
    _hideTimer?.cancel();
  }

  void _release() {
    if (_holds > 0) _holds--;
    _scheduleHide();
  }

  String _percent(double scale) => '${(scale * 100).round()}%';

  @override
  Widget build(BuildContext context) {
    final colors = ColorScheme.of(context);
    final scale = widget.scale.value;
    final locked = widget.zoomLocked;
    final onSelectScale = widget.onSelectScale;
    return Align(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: const EdgeInsets.only(top: 12),
        child: IgnorePointer(
          ignoring: !_visible,
          child: AnimatedOpacity(
            key: const ValueKey('zoom-pill'),
            opacity: _visible ? 1 : 0,
            duration: const Duration(milliseconds: 180),
            child: Listener(
              onPointerDown: (_) => _hold(),
              onPointerUp: (_) => _release(),
              onPointerCancel: (_) => _release(),
              child: Material(
                color: colors.surfaceContainerHigh.withValues(alpha: .96),
                elevation: 2,
                shape: const StadiumBorder(),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (locked != null)
                        IconButton(
                          tooltip: locked ? '확대 잠금 풀기' : '확대 잠금',
                          isSelected: locked,
                          visualDensity: VisualDensity.compact,
                          onPressed: widget.onZoomLockChanged == null
                              ? null
                              : () => widget.onZoomLockChanged!(!locked),
                          icon: const Icon(Icons.lock_open, size: 19),
                          selectedIcon: const Icon(Icons.lock, size: 19),
                        ),
                      PopupMenuButton<double>(
                        tooltip: '배율',
                        enabled: onSelectScale != null,
                        onOpened: _hold,
                        onCanceled: _release,
                        onSelected: (value) {
                          _release();
                          onSelectScale?.call(value);
                        },
                        itemBuilder: (_) => [
                          for (final step in zoomPillSteps)
                            CheckedPopupMenuItem(
                              value: step,
                              checked: (scale - step).abs() < .005,
                              child: Text(
                                step == 1 ? widget.fitLabel : _percent(step),
                              ),
                            ),
                        ],
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(8, 8, 2, 8),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                _percent(scale),
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: colors.onSurface,
                                ),
                              ),
                              Icon(
                                Icons.arrow_drop_down,
                                size: 20,
                                color: onSelectScale == null
                                    ? colors.onSurface.withValues(alpha: .38)
                                    : colors.onSurface,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
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
