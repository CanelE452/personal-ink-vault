import 'package:flutter/material.dart';

/// Three quick choices for the active ink tool, shown in order of thickness.
class InkWidthPresets extends StatelessWidget {
  const new({
    super.key,
    required this.widths,
    required this.selectedWidth,
    required this.onSelected,
    required this.widthLabel,
  }) : assert(widths.length == 3);

  final List<double> widths;
  final double selectedWidth;
  final ValueChanged<double>? onSelected;
  final String widthLabel;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final select = onSelected;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var index = 0; index < widths.length; index++)
          Semantics(
            selected: widths[index] == selectedWidth,
            child: IconButton(
              key: ValueKey('ink-width-preset-$index'),
              tooltip: '$widthLabel ${_widthText(widths[index])}',
              onPressed: select == null ? null : () => select(widths[index]),
              style: IconButton.styleFrom(
                fixedSize: const Size.square(44),
                minimumSize: const Size.square(44),
                padding: EdgeInsets.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              icon: _WidthDot(
                diameter: 3 + index * 3.0,
                selected: widths[index] == selectedWidth,
                color: select == null
                    ? colors.onSurface.withValues(alpha: 0.38)
                    : colors.onSurface,
                selectionColor: colors.primary,
              ),
            ),
          ),
      ],
    );
  }

  static String _widthText(double value) => value == value.roundToDouble()
      ? value.toStringAsFixed(0)
      : value.toString();
}

class _WidthDot extends StatelessWidget {
  const new({
    required this.diameter,
    required this.selected,
    required this.color,
    required this.selectionColor,
  });

  final double diameter;
  final bool selected;
  final Color color;
  final Color selectionColor;

  @override
  Widget build(BuildContext context) => Container(
    width: 23,
    height: 23,
    alignment: Alignment.center,
    decoration: selected
        ? BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: selectionColor, width: 1.5),
          )
        : null,
    child: Container(
      width: diameter,
      height: diameter,
      decoration: BoxDecoration(shape: BoxShape.circle, color: color),
    ),
  );
}
