import 'package:flutter/material.dart';

/// The edge of a [size] box closest to [local].
AxisDirection nearestToolbarEdge(Offset local, Size size) {
  final distances = {
    AxisDirection.up: local.dy,
    AxisDirection.down: size.height - local.dy,
    AxisDirection.left: local.dx,
    AxisDirection.right: size.width - local.dx,
  };
  return distances.entries
      .reduce((best, next) => next.value < best.value ? next : best)
      .key;
}

/// Lays out a note surface with its pen toolbar on one edge.
///
/// Dragging a [ToolbarDockHandle] inside [toolbar] shows the four edges as
/// places to drop it; dropping reports the edge nearest to the finger.
class ToolbarDock extends StatefulWidget {
  const new({
    super.key,
    required this.alignment,
    required this.onAlignmentChanged,
    required this.toolbar,
    required this.child,
  });

  final AxisDirection alignment;
  final ValueChanged<AxisDirection> onAlignmentChanged;

  /// The toolbar, already built for the axis of [alignment].
  final Widget toolbar;

  /// The note surface.
  final Widget child;

  @override
  State<ToolbarDock> createState() => _ToolbarDockState();
}

class _ToolbarDockState extends State<ToolbarDock> {
  static const _zoneThickness = 56.0;

  /// The finger position while the toolbar is being dragged.
  Offset? _drag;

  Offset? _toLocal(Offset global) {
    final box = context.findRenderObject();
    return box is RenderBox && box.hasSize ? box.globalToLocal(global) : null;
  }

  Size? get _size {
    final box = context.findRenderObject();
    return box is RenderBox && box.hasSize ? box.size : null;
  }

  void _start(Offset global) => setState(() => _drag = _toLocal(global));

  void _update(Offset global) => setState(() => _drag = _toLocal(global));

  void _end() {
    final drag = _drag;
    final size = _size;
    setState(() => _drag = null);
    if (drag == null || size == null) return;
    final edge = nearestToolbarEdge(drag, size);
    if (edge != widget.alignment) widget.onAlignmentChanged(edge);
  }

  void _cancel() => setState(() => _drag = null);

  Widget _zone(AxisDirection side, AxisDirection? target, ColorScheme colors) {
    final active = side == target;
    final horizontal = side == AxisDirection.up || side == AxisDirection.down;
    return Positioned(
      key: ValueKey('toolbar-dock-zone-${side.name}'),
      top: side == AxisDirection.down ? null : 0,
      bottom: side == AxisDirection.up ? null : 0,
      left: side == AxisDirection.right ? null : 0,
      right: side == AxisDirection.left ? null : 0,
      height: horizontal ? _zoneThickness : null,
      width: horizontal ? null : _zoneThickness,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        margin: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: active
              ? colors.primary.withValues(alpha: .22)
              : colors.onSurface.withValues(alpha: .06),
          border: Border.all(
            color: active ? colors.primary : colors.outlineVariant,
            width: active ? 2 : 1,
          ),
          borderRadius: BorderRadius.circular(12),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final alignment = widget.alignment;
    final vertical =
        alignment == AxisDirection.left || alignment == AxisDirection.right;
    // One Flex for every edge: switching between a row and a column would
    // rebuild the toolbar's state and drop its keyboard shortcuts.
    final layout = Flex(
      direction: vertical ? Axis.horizontal : Axis.vertical,
      textDirection: alignment == AxisDirection.right
          ? TextDirection.rtl
          : TextDirection.ltr,
      verticalDirection: alignment == AxisDirection.down
          ? VerticalDirection.up
          : VerticalDirection.down,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        widget.toolbar,
        Expanded(child: widget.child),
      ],
    );
    final drag = _drag;
    final size = _size;
    final colors = ColorScheme.of(context);
    final target = drag == null || size == null
        ? null
        : nearestToolbarEdge(drag, size);
    return _DockScope(
      dock: this,
      child: Stack(
        children: [
          Positioned.fill(child: layout),
          if (drag != null) ...[
            // Blocks other pointers (a pen touching the note) while dragging;
            // the dragging finger keeps its own hit path.
            Positioned.fill(
              child: AbsorbPointer(
                child: ColoredBox(color: colors.scrim.withValues(alpha: .08)),
              ),
            ),
            for (final side in AxisDirection.values) _zone(side, target, colors),
            Positioned(
              left: drag.dx - 24,
              top: drag.dy - 24,
              child: IgnorePointer(
                child: Material(
                  color: colors.primaryContainer,
                  shape: const CircleBorder(),
                  elevation: 4,
                  child: SizedBox.square(
                    dimension: 48,
                    child: Icon(Icons.edit, color: colors.onPrimaryContainer),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _DockScope extends InheritedWidget {
  const new({required this.dock, required super.child});

  final _ToolbarDockState dock;

  @override
  bool updateShouldNotify(_DockScope oldWidget) => dock != oldWidget.dock;
}

/// The grip that moves the toolbar. It draws nothing outside a [ToolbarDock].
class ToolbarDockHandle extends StatelessWidget {
  const new({super.key, this.axis = Axis.horizontal});

  /// The axis of the toolbar the handle sits in.
  final Axis axis;

  @override
  Widget build(BuildContext context) {
    final dock = context.dependOnInheritedWidgetOfExactType<_DockScope>()?.dock;
    if (dock == null) return const SizedBox.shrink();
    // A tooltip's long press would win over a press-and-hold drag, so the
    // handle only carries a semantics label.
    return Semantics(
      label: '끌어서 툴바 옮기기',
      button: true,
      child: GestureDetector(
        key: const ValueKey('toolbar-dock-handle'),
        behavior: HitTestBehavior.opaque,
        onPanStart: (details) => dock._start(details.globalPosition),
        onPanUpdate: (details) => dock._update(details.globalPosition),
        onPanEnd: (_) => dock._end(),
        onPanCancel: dock._cancel,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Icon(
            axis == Axis.horizontal ? Icons.drag_indicator : Icons.drag_handle,
            color: ColorScheme.of(context).onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
