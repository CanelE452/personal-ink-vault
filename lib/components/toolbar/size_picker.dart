import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:saber/data/tools/pen.dart';
import 'package:saber/i18n/strings.g.dart';

class SizePicker extends StatelessWidget {
  const new({
    super.key,
    required this.axis,
    required this.pen,
    required this.onChanged,
  });

  final Axis axis;
  final Pen pen;
  final ValueChanged<double> onChanged;

  static const double smallLength = 25;
  static const double largeLength = 150;
  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.of(context);
    return Flex(
      direction: axis,
      mainAxisSize: .min,
      children: [
        Column(
          children: [
            Text(
              t.editor.penOptions.size,
              style: TextStyle(
                color: colorScheme.onSurface.withValues(alpha: 0.8),
                fontSize: 10,
                height: 1,
              ),
            ),
            Text(_prettyNum(pen.options.size)),
          ],
        ),
        const SizedBox(width: 8),
        Padding(
          padding: const .symmetric(vertical: 8),
          child: _SizeSlider(pen: pen, axis: axis, onChanged: onChanged),
        ),
      ],
    );
  }
}

/// Returns an integer when possible and uses one decimal place otherwise.
String _prettyNum(double num) {
  final rounded = num.round();
  if (num == rounded) return rounded.toString();
  return num.toStringAsFixed(1);
}

class _SizeSlider extends StatelessWidget {
  const new({required this.pen, required this.axis, required this.onChanged});

  final Pen pen;
  final Axis axis;
  final ValueChanged<double> onChanged;

  /// [percent] is a value between 0 and 1
  /// where 0 is the start of the slider and 1 is the end.
  ///
  /// Values outside of this range are allowed but will be clamped.
  void onDrag(double percent) {
    percent = clampDouble(percent, 0, 1);
    final stepsFromMin = (percent * pen.sizeStepsBetweenMinAndMax).round();
    final newSize = pen.sizeMin + stepsFromMin * pen.sizeStep;
    if (newSize == pen.options.size) return;
    onChanged(newSize);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.of(context);
    return GestureDetector(
      key: const ValueKey('pen-size-slider'),
      onHorizontalDragStart: axis == Axis.horizontal
          ? (details) =>
                onDrag(details.localPosition.dx / SizePicker.largeLength)
          : null,
      onHorizontalDragUpdate: axis == Axis.horizontal
          ? (details) =>
                onDrag(details.localPosition.dx / SizePicker.largeLength)
          : null,
      onVerticalDragStart: axis == Axis.vertical
          ? (details) =>
                onDrag(details.localPosition.dy / SizePicker.largeLength)
          : null,
      onVerticalDragUpdate: axis == Axis.vertical
          ? (details) =>
                onDrag(details.localPosition.dy / SizePicker.largeLength)
          : null,
      child: RotatedBox(
        quarterTurns: axis == Axis.horizontal ? 0 : 1,
        child: CustomPaint(
          size: const Size(SizePicker.largeLength, SizePicker.smallLength),
          painter: _SizeSliderPainter(
            axis: axis,
            minSize: pen.sizeMin,
            maxSize: pen.sizeMax,
            currentSize: pen.options.size,
            trackColor: colorScheme.onSurface.withValues(alpha: 0.2),
            thumbColor: colorScheme.primary,
          ),
        ),
      ),
    );
  }
}

class _SizeSliderPainter extends CustomPainter {
  new({
    required this.axis,
    required this.minSize,
    required this.maxSize,
    required this.currentSize,
    required this.trackColor,
    required this.thumbColor,
  });

  final Axis axis;
  final double minSize;
  final double maxSize;
  final double currentSize;
  final Color trackColor;
  final Color thumbColor;

  @override
  void paint(Canvas canvas, Size size) {
    /// The smallest height the track can be
    final leftHeight = size.height * minSize / maxSize;
    final topLeft = Offset(0, (size.height - leftHeight) / 2);
    final bottomLeft = Offset(0, topLeft.dy + leftHeight);
    final topRight = Offset(size.width, 0);
    final bottomRight = Offset(size.width, size.height);

    // track
    canvas.drawPath(
      Path()
        ..moveTo(topLeft.dx, topLeft.dy)
        ..lineTo(bottomLeft.dx, bottomLeft.dy)
        ..lineTo(bottomRight.dx, bottomRight.dy)
        ..lineTo(topRight.dx, topRight.dy)
        ..close(),
      Paint()
        ..color = trackColor
        ..style = .fill,
    );

    // thumb
    final ratio = (currentSize - minSize) / (maxSize - minSize);
    final thumbHeight = size.height * ratio;
    final thumbRight = size.width * ratio;
    final thumbTop = (size.height - thumbHeight) / 2;
    canvas.drawPath(
      Path()
        ..moveTo(topLeft.dx, topLeft.dy)
        ..lineTo(bottomLeft.dx, bottomLeft.dy)
        ..lineTo(thumbRight, thumbTop + thumbHeight)
        ..lineTo(thumbRight, thumbTop)
        ..close(),
      Paint()
        ..color = thumbColor
        ..style = .fill,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    return oldDelegate is! _SizeSliderPainter ||
        oldDelegate.axis != axis ||
        oldDelegate.minSize != minSize ||
        oldDelegate.maxSize != maxSize ||
        oldDelegate.currentSize != currentSize ||
        oldDelegate.trackColor != trackColor ||
        oldDelegate.thumbColor != thumbColor;
  }
}
