import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:saber/components/toolbar/pen_drawings.dart';
import 'package:saber/components/toolbar/toolbar_layout.dart';
import 'package:saber/data/extensions/color_extensions.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/tools/eraser.dart';
import 'package:saber/data/tools/pen.dart';
import 'package:saber/data/tools/pen_box.dart';
import 'package:saber/data/tools/pencil.dart';
import 'package:saber/data/tools/shape_pen.dart';
import 'package:sbn/tool_id.dart';
import 'package:stow_plain/stow_plain.dart';

/// Shown when a control the engine cannot do yet is tapped.
const comingSoonMessage = '다음 업데이트에서 추가됩니다';

/// Page units in millimetres: a page is 1000 units across an A4 sheet.
String millimetres(double units) => '${(units * 0.21).toStringAsFixed(2)}mm';

/// Whether ink shows inverted (dark theme with the editor's auto invert), as
/// the toolbar's colours and the page show it.
bool _inverted(BuildContext context) =>
    stows.editorAutoInvert.value &&
    Theme.brightnessOf(context) == Brightness.dark;

/// The pen kinds' names in the panels' titles and the pen box.
String penKindName(ToolId toolId) => switch (toolId) {
  .ballpointPen => '볼펜',
  .pencil => '연필',
  .shapePen => '도형 펜',
  .highlighter => '형광펜',
  _ => '만년필',
};

/// A tool's options, shown under the toolbar when the chosen tool is tapped
/// again, laid out like StarNote's tool panels: a centred title over a
/// divider, then named rows with their values.
class ToolPanel extends StatelessWidget {
  const new({super.key, required this.title, required this.children});

  final String title;
  final List<Widget> children;

  static const width = 328.0;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Text(
            title,
            textAlign: TextAlign.center,
            style: TextTheme.of(context).titleMedium,
          ),
        ),
        Divider(height: 1, color: ColorScheme.of(context).outlineVariant),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: children,
            ),
          ),
        ),
      ],
    ),
  );
}

/// A row's name, with its value (for example 0.35mm) at the right.
class PanelLabel extends StatelessWidget {
  const new(this.text, {super.key, this.value, this.valueKey, this.help});

  final String text;
  final String? value;
  final Key? valueKey;
  final String? help;

  @override
  Widget build(BuildContext context) {
    final textTheme = TextTheme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 8),
      child: Row(
        children: [
          Text(text, style: textTheme.bodyLarge),
          if (help != null) _HelpIcon(help!),
          const Spacer(),
          if (value != null)
            Text(
              value!,
              key: valueKey,
              style: textTheme.bodyLarge?.copyWith(
                color: ColorScheme.of(context).onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }
}

/// The light rounded box StarNote puts around sliders and colour rows.
class PanelBox extends StatelessWidget {
  const new({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      border: Border.all(color: ColorScheme.of(context).outlineVariant),
      borderRadius: BorderRadius.circular(12),
    ),
    child: child,
  );
}

class _HelpIcon extends StatelessWidget {
  const new(this.message);

  final String message;

  @override
  Widget build(BuildContext context) => Tooltip(
    triggerMode: TooltipTriggerMode.tap,
    message: message,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      child: Icon(
        Icons.help_outline,
        size: 18,
        color: ColorScheme.of(context).onSurfaceVariant,
      ),
    ),
  );
}

/// A named switch row; tapping anywhere on the row flips it. Without
/// [onChanged] the row is faded and a tap says the option is coming.
class PanelSwitch extends StatelessWidget {
  const new({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.help,
    this.comingSoon = false,
  });

  final String label;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final String? help;
  final bool comingSoon;

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.of(context);
    final enabled = onChanged != null;
    final row = InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: enabled ? () => onChanged!(!value) : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Text(
              label,
              style: TextTheme.of(context).bodyLarge?.copyWith(
                color: enabled
                    ? null
                    : colorScheme.onSurface.withValues(alpha: 0.38),
              ),
            ),
            if (help != null) _HelpIcon(help!),
            const Spacer(),
            Switch(value: value, onChanged: onChanged),
          ],
        ),
      ),
    );
    if (!comingSoon) return row;
    return Tooltip(
      triggerMode: TooltipTriggerMode.tap,
      message: comingSoonMessage,
      child: row,
    );
  }
}

Widget _stowSwitch(
  PlainStow<bool> stow,
  String label, {
  Key? key,
  String? help,
  bool enabled = true,
}) => ValueListenableBuilder(
  valueListenable: stow,
  builder: (context, value, _) => PanelSwitch(
    key: key,
    label: label,
    value: value,
    help: help,
    onChanged: enabled ? (next) => stow.value = next : null,
  ),
);

Widget _comingSoonSwitch(String label, {String? help}) => PanelSwitch(
  label: label,
  value: false,
  onChanged: null,
  help: help,
  comingSoon: true,
);

/// A slider in its box, with the colours and size of StarNote's.
Widget _boxedSlider({
  required Key key,
  required double value,
  required double min,
  required double max,
  int? divisions,
  required ValueChanged<double>? onChanged,
}) => PanelBox(
  child: Slider(
    key: key,
    value: value.clamp(min, max).toDouble(),
    min: min,
    max: max,
    divisions: divisions,
    onChanged: onChanged,
  ),
);

enum _LineType { solid, dashed, dotted }

/// 선 종류: solid, dashed and dotted lines. Only the solid line exists in
/// the engine so far; the other two are faded and say they are coming.
class _LineTypeRow extends StatelessWidget {
  const new();

  @override
  Widget build(BuildContext context) => Row(
    children: [
      for (final type in _LineType.values)
        Expanded(
          child: Padding(
            padding: EdgeInsets.only(left: type == _LineType.solid ? 0 : 8),
            child: _lineBox(context, type),
          ),
        ),
    ],
  );

  Widget _lineBox(BuildContext context, _LineType type) {
    final colorScheme = ColorScheme.of(context);
    final selected = type == _LineType.solid;
    final box = Container(
      key: ValueKey('tool-panel-line-${type.name}'),
      height: 44,
      decoration: BoxDecoration(
        border: Border.all(
          color: selected ? colorScheme.primary : colorScheme.outlineVariant,
          width: selected ? 2 : 1,
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: CustomPaint(
        painter: _LinePainter(
          type,
          selected
              ? colorScheme.onSurface
              : colorScheme.onSurface.withValues(alpha: 0.3),
        ),
      ),
    );
    if (selected) return box;
    return Tooltip(
      triggerMode: TooltipTriggerMode.tap,
      message: comingSoonMessage,
      child: box,
    );
  }
}

class _LinePainter extends CustomPainter {
  const new(this.type, this.color);

  final _LineType type;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    final y = size.height / 2;
    final (dash, gap) = switch (type) {
      _LineType.solid => (size.width, 0.0),
      _LineType.dashed => (8.0, 5.0),
      _LineType.dotted => (0.5, 4.5),
    };
    for (var x = 20.0; x < size.width - 20; x += dash + gap) {
      canvas.drawLine(
        Offset(x, y),
        Offset(math.min(x + dash, size.width - 20), y),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_LinePainter oldDelegate) =>
      oldDelegate.type != type || oldDelegate.color != color;
}

/// The colour row: five swatches in a box. The chosen one has a ring and a
/// small chevron; tapping it again opens the full palette.
class _ColorSwatches extends StatelessWidget {
  const new({
    required this.colors,
    required this.selected,
    required this.onTap,
    this.translucent = false,
  });

  final List<int> colors;
  final Color selected;
  final void Function(Color color, bool wasSelected) onTap;

  /// Highlighter colours: half of each swatch shows a checkerboard.
  final bool translucent;

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.of(context);
    final chosen = selected.withValues(alpha: 1).toARGB32();
    final invert = _inverted(context);
    return PanelBox(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            for (final (index, value) in colors.indexed)
              Semantics(
                button: true,
                selected: value == chosen,
                label: '색 ${index + 1}',
                child: GestureDetector(
                  key: ValueKey('tool-panel-color-$index'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onTap(Color(value), value == chosen),
                  child: Container(
                    width: 40,
                    height: 40,
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(11),
                      border: Border.all(
                        color: value == chosen
                            ? colorScheme.primary
                            : Colors.transparent,
                        width: 2,
                      ),
                    ),
                    child: CustomPaint(
                      painter: _SwatchPainter(
                        Color(value).withInversion(invert),
                        translucent,
                      ),
                      child: value == chosen
                          ? Icon(
                              Icons.expand_more,
                              size: 18,
                              color:
                                  Color(
                                        value,
                                      ).withInversion(invert).computeLuminance() >
                                      0.5
                                  ? Colors.black87
                                  : Colors.white,
                            )
                          : null,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _SwatchPainter extends CustomPainter {
  const new(this.color, this.translucent);

  final Color color;
  final bool translucent;

  @override
  void paint(Canvas canvas, Size size) {
    final shape = RRect.fromRectAndRadius(
      Offset.zero & size,
      const Radius.circular(8),
    );
    canvas.save();
    canvas.clipRRect(shape);
    canvas.drawRect(Offset.zero & size, Paint()..color = color);
    if (translucent) {
      // The right half shows how see-through the highlighter is.
      const cell = 5.0;
      final light = Paint()..color = Colors.white;
      final grey = Paint()..color = const Color(0xFFDDDDDD);
      for (var y = 0.0; y < size.height; y += cell) {
        for (var x = size.width / 2; x < size.width; x += cell) {
          final odd = ((x / cell).floor() + (y / cell).floor()).isOdd;
          canvas.drawRect(
            Rect.fromLTWH(x, y, cell, cell),
            odd ? grey : light,
          );
        }
      }
      canvas.drawRect(
        Rect.fromLTRB(size.width / 2, 0, size.width, size.height),
        Paint()..color = color.withValues(alpha: 0.45),
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_SwatchPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.translucent != translucent;
}

/// "펜박스에 추가": keeps the pen in hand in the pen box, once.
class _AddToPenBoxButton extends StatelessWidget {
  const new({required this.pen});

  final Pen pen;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: stows.penBox,
    builder: (context, _, _) {
      final entry = PenBoxEntry.of(pen);
      final entries = PenBox.entries;
      final kept = entries.contains(entry);
      final full = !kept && entries.length >= PenBox.maxEntries;
      final colorScheme = ColorScheme.of(context);
      return Padding(
        padding: const EdgeInsets.only(top: 20),
        child: OutlinedButton(
          key: const ValueKey('tool-panel-add-to-pen-box'),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(46),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            side: BorderSide(
              color: kept || full
                  ? colorScheme.outlineVariant
                  : colorScheme.primary,
            ),
          ),
          onPressed: kept || full ? null : () => PenBox.add(entry),
          child: Text(
            kept
                ? '펜박스에 있음'
                : full
                ? '펜박스가 가득 찼습니다(${PenBox.maxEntries}개)'
                : '펜박스에 추가',
          ),
        ),
      );
    },
  );
}

/// The pen button's panel: the pen kinds in a tray, line type, width in
/// millimetres, stabilisation in percent, colours and the pen box button,
/// in the order of StarNote's ballpoint panel.
class PenPanel extends StatefulWidget {
  const new({
    super.key,
    required this.getPen,
    required this.setTool,
    required this.setSize,
    required this.setColor,
    required this.openColors,
  });

  /// The pen in hand (one of the pen button's kinds).
  final Pen Function() getPen;
  final ValueChanged<Pen> setTool;
  final void Function(Pen, double) setSize;
  final ValueChanged<Color> setColor;

  /// Opens the full palette, for the chosen swatch's second tap.
  final VoidCallback openColors;

  @override
  State<PenPanel> createState() => _PenPanelState();
}

class _PenPanelState extends State<PenPanel> {
  static const _kinds = [
    PenTrayItem(PenShape.fountainPen, '만년필'),
    PenTrayItem(PenShape.ballpointPen, '볼펜'),
    PenTrayItem(PenShape.pencil, '연필'),
    PenTrayItem(PenShape.shapePen, '도형 펜'),
  ];

  void _choose(PenShape shape) {
    if (PenShape.of(widget.getPen().toolId) == shape) return;
    final current = Pen.currentPen;
    widget.setTool(switch (shape) {
      PenShape.ballpointPen =>
        current.toolId == .ballpointPen ? current : Pen.ballpointPen(),
      PenShape.pencil => Pencil.currentPencil,
      PenShape.shapePen =>
        current.toolId == .shapePen ? current : ShapePen(),
      _ => current.toolId == .fountainPen ? current : Pen.fountainPen(),
    });
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final pen = widget.getPen();
    return ToolPanel(
      title: penKindName(pen.toolId),
      children: [
        PenTray(
          items: _kinds,
          selected: PenShape.of(pen.toolId),
          color: pen.color.withInversion(_inverted(context)),
          onSelected: _choose,
          comingSoonMessage: comingSoonMessage,
        ),
        const PanelLabel('선 종류'),
        const _LineTypeRow(),
        PanelLabel(
          '두께',
          value: millimetres(pen.options.size),
          valueKey: const ValueKey('tool-panel-size-value'),
        ),
        _boxedSlider(
          key: const ValueKey('tool-panel-size'),
          value: pen.options.size,
          min: pen.sizeMin,
          max: pen.sizeMax,
          onChanged: (value) {
            final size = (value / pen.sizeStep).round() * pen.sizeStep;
            widget.setSize(
              pen,
              size.clamp(pen.sizeMin, pen.sizeMax).toDouble(),
            );
            setState(() {});
          },
        ),
        // The shape pen draws clean shapes; smoothing does not apply.
        if (pen is! ShapePen) ...[
          PanelLabel(
            '스트로크 안정화',
            value: '${(pen.options.streamline * 100).round()}%',
          ),
          _boxedSlider(
            key: const ValueKey('tool-panel-stabiliser'),
            value: pen.options.streamline,
            min: 0,
            max: 1,
            divisions: 10,
            onChanged: (value) => setState(() => pen.setStreamline(value)),
          ),
        ],
        const PanelLabel('색상'),
        _ColorSwatches(
          colors: toolbarQuickColors,
          selected: pen.color,
          onTap: (color, wasSelected) {
            if (wasSelected) return widget.openColors();
            widget.setColor(color);
            setState(() {});
          },
        ),
        _AddToPenBoxButton(pen: pen),
      ],
    );
  }
}

/// The highlighter's panel, in the order of StarNote's: tips, width,
/// straight line, horizontal/vertical, colours, pen box.
class HighlighterPanel extends StatefulWidget {
  const new({
    super.key,
    required this.getPen,
    required this.setSize,
    required this.setColor,
    required this.openColors,
  });

  final Pen Function() getPen;
  final void Function(Pen, double) setSize;
  final ValueChanged<Color> setColor;
  final VoidCallback openColors;

  @override
  State<HighlighterPanel> createState() => _HighlighterPanelState();
}

class _HighlighterPanelState extends State<HighlighterPanel> {
  static const _tips = [
    PenTrayItem(PenShape.highlighterChisel, '납작한 끝'),
    // A round tip needs a new stroke shape in the engine.
    PenTrayItem(PenShape.highlighterRound, '둥근 끝', enabled: false),
  ];

  @override
  Widget build(BuildContext context) {
    final pen = widget.getPen();
    return ToolPanel(
      title: '형광펜',
      children: [
        PenTray(
          items: _tips,
          selected: PenShape.highlighterChisel,
          color: pen.color.withInversion(_inverted(context)),
          onSelected: (_) {},
          comingSoonMessage: comingSoonMessage,
        ),
        PanelLabel(
          '두께',
          value: millimetres(pen.options.size),
          valueKey: const ValueKey('tool-panel-size-value'),
        ),
        _boxedSlider(
          key: const ValueKey('tool-panel-size'),
          value: pen.options.size,
          min: pen.sizeMin,
          max: pen.sizeMax,
          onChanged: (value) {
            final size = (value / pen.sizeStep).round() * pen.sizeStep;
            widget.setSize(
              pen,
              size.clamp(pen.sizeMin, pen.sizeMax).toDouble(),
            );
            setState(() {});
          },
        ),
        const SizedBox(height: 8),
        _stowSwitch(
          stows.highlighterStraightLine,
          '직선 그리기',
          key: const ValueKey('tool-panel-straight-line'),
        ),
        ValueListenableBuilder(
          valueListenable: stows.highlighterStraightLine,
          builder: (context, straight, _) => _stowSwitch(
            stows.highlighterAxisLock,
            '수평/수직 그리기',
            key: const ValueKey('tool-panel-axis-lock'),
            help: '직선 그리기가 켜져 있을 때, 선을 수평이나 수직 중 가까운 쪽으로 맞춥니다.',
            enabled: straight,
          ),
        ),
        const PanelLabel('색상'),
        _ColorSwatches(
          colors: highlighterQuickColors,
          selected: pen.color,
          translucent: true,
          onTap: (color, wasSelected) {
            if (wasSelected) return widget.openColors();
            widget.setColor(color);
            setState(() {});
          },
        ),
        _AddToPenBoxButton(pen: pen),
      ],
    );
  }
}

/// The eraser's panel, in the order of StarNote's: the three erasers, size,
/// then the switches.
class EraserPanel extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: stows.eraserMode,
    builder: (context, mode, _) => ToolPanel(
      title: '지우개',
      children: [
        const SizedBox(height: 8),
        Row(
          children: [
            const Expanded(
              child: _EraserCard(
                id: 'pixel',
                kind: _EraserKind.pixel,
                label: '픽셀 지우기',
                selected: false,
                onTap: null,
              ),
            ),
            Expanded(
              child: _EraserCard(
                id: 'stroke',
                kind: _EraserKind.stroke,
                label: '스트로크 지우기',
                selected: mode == EraserMode.stroke,
                onTap: () => stows.eraserMode.value = EraserMode.stroke,
              ),
            ),
            Expanded(
              child: _EraserCard(
                id: 'lasso',
                kind: _EraserKind.lasso,
                label: '원형 선택 지우기',
                selected: mode == EraserMode.lasso,
                onTap: () => stows.eraserMode.value = EraserMode.lasso,
              ),
            ),
          ],
        ),
        ValueListenableBuilder(
          valueListenable: stows.eraserSize,
          builder: (context, size, _) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // The eraser is a circle of radius size: show its width.
              PanelLabel('크기', value: millimetres(size * 2)),
              _boxedSlider(
                key: const ValueKey('tool-panel-eraser-size'),
                value: size,
                min: 4,
                max: 60,
                // A loop erases what it holds, whatever the size.
                onChanged: mode == EraserMode.lasso
                    ? null
                    : (value) => stows.eraserSize.value = value.roundToDouble(),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        _comingSoonSwitch('압력 감지 지우개'),
        _comingSoonSwitch(
          '문질러서 지우기',
          help: '펜을 문지르면 그 자리의 필기를 지웁니다. 암기 테이프와 함께 추가됩니다.',
        ),
        _stowSwitch(
          stows.eraseHighlighterOnly,
          '형광펜만 지우기',
          key: const ValueKey('tool-panel-highlighter-only'),
        ),
        _comingSoonSwitch('테이프만 지우기'),
        Divider(height: 17, color: ColorScheme.of(context).outlineVariant),
        _stowSwitch(
          stows.disableEraserAfterUse,
          '자동 해제',
          help: '지우고 나면 전에 쓰던 도구로 돌아갑니다.',
          key: const ValueKey('tool-panel-auto-release'),
        ),
      ],
    ),
  );
}

class _EraserCard extends StatelessWidget {
  const new({
    required this.id,
    required this.kind,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String id;
  final _EraserKind kind;
  final String label;
  final bool selected;

  /// Null for the eraser the engine cannot do yet.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.of(context);
    final enabled = onTap != null;
    final card = GestureDetector(
      key: ValueKey('tool-panel-eraser-mode-$id'),
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Column(
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerLowest,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: selected
                      ? colorScheme.primary
                      : colorScheme.outlineVariant,
                  width: selected ? 2 : 1,
                ),
              ),
              child: CustomPaint(
                painter: _EraserIconPainter(kind, colorScheme.onSurface),
              ),
            ),
            const SizedBox(height: 6),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                label,
                maxLines: 1,
                style: TextTheme.of(context).bodySmall?.copyWith(fontSize: 11),
              ),
            ),
          ],
        ),
      ),
    );
    if (enabled) {
      return Semantics(button: true, selected: selected, child: card);
    }
    return Tooltip(
      triggerMode: TooltipTriggerMode.tap,
      message: comingSoonMessage,
      child: Opacity(opacity: 0.38, child: card),
    );
  }
}

enum _EraserKind { pixel, stroke, lasso }

/// The eraser cards' pictures, drawn here rather than taken from an icon
/// font: the Android build ships 209's icon fonts, which keep only the
/// glyphs used then, so a newer icon would show as some other character.
class _EraserIconPainter extends CustomPainter {
  const new(this.kind, this.color);

  final _EraserKind kind;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final ink = Paint()
      ..isAntiAlias = true
      ..color = color.withValues(alpha: 0.75)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round;

    switch (kind) {
      case _EraserKind.pixel:
        // A trail of rubbed-out dots behind the eraser.
        final dot = Paint()..color = color.withValues(alpha: 0.45);
        for (var row = 0; row < 3; row++) {
          for (var column = 0; column < 3 - row; column++) {
            canvas.drawCircle(
              c + Offset(-13 + column * 4.5, 3 + row * 4.5),
              1.3,
              dot,
            );
          }
        }
      case _EraserKind.stroke:
        // The line the eraser takes away.
        canvas.drawPath(
          Path()
            ..moveTo(c.dx - 15, c.dy + 6)
            ..cubicTo(c.dx - 8, c.dy - 4, c.dx - 3, c.dy + 12, c.dx + 4, c.dy + 3)
            ..cubicTo(c.dx + 8, c.dy - 2, c.dx + 11, c.dy + 4, c.dx + 15, c.dy),
          ink,
        );
      case _EraserKind.lasso:
        // The loop drawn around what goes.
        const dashes = 14;
        for (var i = 0; i < dashes; i++) {
          final start = i * 2 * math.pi / dashes;
          canvas.drawArc(
            Rect.fromCircle(center: c, radius: 13),
            start,
            math.pi / dashes,
            false,
            ink,
          );
        }
    }

    // The eraser itself, tilted like one in a hand.
    canvas.save();
    final at = switch (kind) {
      _EraserKind.lasso => c + const Offset(3, 3),
      _EraserKind.pixel => c + const Offset(3, -2),
      _EraserKind.stroke => c + const Offset(0, -3),
    };
    canvas.translate(at.dx, at.dy);
    canvas.rotate(-math.pi / 5);
    const body = Rect.fromLTWH(-9, -5, 18, 10);
    canvas.drawRRect(
      RRect.fromRectAndRadius(body, const Radius.circular(2.5)),
      Paint()..color = const Color(0xFFF2F2F2),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(-9, -5, 7, 10),
        const Radius.circular(2.5),
      ),
      Paint()..color = const Color(0xFFE57373),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(body, const Radius.circular(2.5)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = color.withValues(alpha: 0.7),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_EraserIconPainter oldDelegate) =>
      oldDelegate.kind != kind || oldDelegate.color != color;
}

class SelectPanel extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) => ToolPanel(
    title: '올가미',
    children: [
      const SizedBox(height: 8),
      ValueListenableBuilder(
        valueListenable: stows.selectRectangle,
        builder: (context, rectangle, _) => SegmentedButton<bool>(
          key: const ValueKey('tool-panel-lasso-shape'),
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: false, label: Text('자유 올가미')),
            ButtonSegment(value: true, label: Text('사각형 올가미')),
          ],
          selected: {rectangle},
          onSelectionChanged: (selection) =>
              stows.selectRectangle.value = selection.single,
        ),
      ),
      const PanelLabel('선택 대상'),
      _stowSwitch(
        stows.selectInk,
        '손글씨',
        key: const ValueKey('tool-panel-select-ink'),
      ),
      _stowSwitch(
        stows.selectHighlighter,
        '형광펜',
        key: const ValueKey('tool-panel-select-highlighter'),
      ),
      _stowSwitch(
        stows.selectImages,
        '사진',
        key: const ValueKey('tool-panel-select-images'),
      ),
    ],
  );
}

/// The pens kept with "펜박스에 추가". Tapping one picks it up; × takes it
/// out of the box.
class PenBoxPanel extends StatelessWidget {
  const new({super.key, required this.apply});

  final ValueChanged<PenBoxEntry> apply;

  @override
  Widget build(BuildContext context) => ToolPanel(
    title: '펜박스',
    children: [
      ValueListenableBuilder(
        valueListenable: stows.penBox,
        builder: (context, _, _) {
          final entries = PenBox.entries;
          if (entries.isEmpty) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Text(
                '펜 패널의 "펜박스에 추가"로 자주 쓰는 펜을 모아 두세요.',
                textAlign: TextAlign.center,
                style: TextTheme.of(context).bodyMedium?.copyWith(
                  color: ColorScheme.of(context).onSurfaceVariant,
                ),
              ),
            );
          }
          return Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final (index, entry) in entries.indexed)
                  _PenBoxTile(
                    index: index,
                    entry: entry,
                    onTap: () => apply(entry),
                  ),
              ],
            ),
          );
        },
      ),
    ],
  );
}

class _PenBoxTile extends StatelessWidget {
  const new({required this.index, required this.entry, required this.onTap});

  final int index;
  final PenBoxEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.of(context);
    final name = penKindName(entry.toolId);
    final size = millimetres(entry.size);
    return Container(
      width: 64,
      height: 116,
      decoration: BoxDecoration(
        border: Border.all(color: colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          // Its own row, so the button never covers the pen's tip.
          Align(
            alignment: Alignment.centerRight,
            child: InkResponse(
              key: ValueKey('pen-box-remove-$index'),
              radius: 14,
              onTap: () => PenBox.remove(entry),
              child: Tooltip(
                message: '$name 빼기',
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(
                    Icons.close,
                    size: 14,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: Semantics(
              button: true,
              label: '$name $size',
              child: InkWell(
                key: ValueKey('pen-box-entry-$index'),
                borderRadius: BorderRadius.circular(12),
                onTap: onTap,
                child: Column(
                  children: [
                    Expanded(
                      child: ClipRect(
                        child: CustomPaint(
                          size: Size.infinite,
                          painter: PenDrawingPainter(
                            shape: PenShape.of(entry.toolId),
                            color: Color(entry.color),
                            highlighted: true,
                            top: 2,
                          ),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Text(
                        size,
                        style: TextTheme.of(context).labelSmall,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Shows [panel] next to [child] while [openPanel] holds [id]. Taps inside
/// [groupId] (the toolbar wraps itself in the same group) keep it open; any
/// other tap closes it and is not passed on, so it never starts a stroke.
class ToolPanelAnchor extends StatefulWidget {
  const new({
    super.key,
    required this.id,
    required this.openPanel,
    required this.edge,
    required this.groupId,
    required this.panel,
    required this.child,
  });

  final String id;
  final ValueNotifier<String?> openPanel;

  /// The screen edge the toolbar sits on; the panel opens away from it.
  final AxisDirection edge;
  final Object groupId;
  final WidgetBuilder panel;
  final Widget child;

  @override
  State<ToolPanelAnchor> createState() => _ToolPanelAnchorState();
}

class _ToolPanelAnchorState extends State<ToolPanelAnchor> {
  final _portal = OverlayPortalController();

  /// Closes the panel a moment after a tap outside it, so a second finger
  /// landing right after (a pinch) is swallowed too instead of drawing.
  Timer? _closing;

  @override
  void initState() {
    super.initState();
    widget.openPanel.addListener(_sync);
    _syncAfterFrame();
  }

  @override
  void didUpdateWidget(ToolPanelAnchor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.openPanel, widget.openPanel)) {
      oldWidget.openPanel.removeListener(_sync);
      widget.openPanel.addListener(_sync);
    }
    if (oldWidget.id != widget.id) _syncAfterFrame();
  }

  @override
  void dispose() {
    _closing?.cancel();
    widget.openPanel.removeListener(_sync);
    super.dispose();
  }

  void _syncAfterFrame() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (mounted) _sync();
  });

  void _sync() {
    final open = widget.openPanel.value == widget.id;
    if (!open) {
      _closing?.cancel();
      _closing = null;
    }
    if (open == _portal.isShowing) return;
    if (open) {
      _portal.show();
    } else {
      _portal.hide();
    }
  }

  Rect? _anchorRect(BuildContext overlayContext) {
    final anchor = context.findRenderObject() as RenderBox?;
    final overlay = Overlay.maybeOf(overlayContext)?.context.findRenderObject();
    if (anchor == null || !anchor.hasSize || overlay == null) return null;
    return anchor.localToGlobal(Offset.zero, ancestor: overlay) & anchor.size;
  }

  @override
  Widget build(BuildContext context) => OverlayPortal(
    controller: _portal,
    overlayChildBuilder: (overlayContext) {
      final anchor = _anchorRect(overlayContext);
      if (anchor == null) return const SizedBox.shrink();
      // The button can move without this panel rebuilding (the toolbar is
      // moved to another edge, the tablet turns): place it again then.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_portal.isShowing) return;
        final now = _anchorRect(overlayContext);
        if (now != null && (now.topLeft - anchor.topLeft).distance > 0.5) {
          setState(() {});
        }
      });
      return CustomSingleChildLayout(
        delegate: _PanelLayout(
          anchor: anchor,
          edge: widget.edge,
          padding: MediaQuery.paddingOf(overlayContext),
        ),
        child: TapRegion(
          groupId: widget.groupId,
          consumeOutsideTaps: true,
          onTapOutside: (_) {
            if (widget.openPanel.value != widget.id || _closing != null) {
              return;
            }
            _closing = Timer(const Duration(milliseconds: 150), () {
              _closing = null;
              if (widget.openPanel.value == widget.id) {
                widget.openPanel.value = null;
              }
            });
          },
          child: Material(
            key: ValueKey('tool-panel-${widget.id}'),
            elevation: 6,
            borderRadius: BorderRadius.circular(16),
            clipBehavior: Clip.antiAlias,
            child: widget.panel(overlayContext),
          ),
        ),
      );
    },
    child: widget.child,
  );
}

/// Places the panel away from the toolbar's edge. Under or over a toolbar
/// on the top or bottom edge it is centred on its button, like StarNote's;
/// beside a side toolbar it starts level with the button. It never leaves
/// the screen.
class _PanelLayout extends SingleChildLayoutDelegate {
  new({
    required this.anchor,
    required this.edge,
    required this.padding,
  });

  final Rect anchor;
  final AxisDirection edge;
  final EdgeInsets padding;

  static const _margin = 8.0;

  /// Only the room on the panel's side of the button: a taller panel scrolls
  /// instead of being pushed back over the toolbar (a tablet held sideways).
  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final screen = constraints.biggest;
    final width = screen.width - padding.horizontal - 2 * _margin;
    final height = screen.height - padding.vertical - 2 * _margin;
    final (maxWidth, maxHeight) = switch (edge) {
      AxisDirection.up => (
        width,
        screen.height - padding.bottom - _margin - (anchor.bottom + 4),
      ),
      AxisDirection.down => (
        width,
        anchor.top - 4 - padding.top - _margin,
      ),
      AxisDirection.left => (
        screen.width - padding.right - _margin - (anchor.right + 4),
        height,
      ),
      AxisDirection.right => (
        anchor.left - 4 - padding.left - _margin,
        height,
      ),
    };
    return BoxConstraints.loose(
      Size(math.max(0, maxWidth), math.max(0, maxHeight)),
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final centredX = anchor.center.dx - childSize.width / 2;
    final (x, y) = switch (edge) {
      AxisDirection.up => (centredX, anchor.bottom + 4),
      AxisDirection.down => (centredX, anchor.top - childSize.height - 4),
      AxisDirection.left => (anchor.right + 4, anchor.top),
      AxisDirection.right => (anchor.left - childSize.width - 4, anchor.top),
    };
    final left = padding.left + _margin;
    final top = padding.top + _margin;
    final right = size.width - padding.right - _margin - childSize.width;
    final bottom = size.height - padding.bottom - _margin - childSize.height;
    return Offset(
      x.clamp(left, math.max(left, right)).toDouble(),
      y.clamp(top, math.max(top, bottom)).toDouble(),
    );
  }

  @override
  bool shouldRelayout(_PanelLayout oldDelegate) =>
      oldDelegate.anchor != anchor ||
      oldDelegate.edge != edge ||
      oldDelegate.padding != padding;
}
