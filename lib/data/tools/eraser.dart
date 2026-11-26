import 'dart:ui';

import 'package:saber/components/canvas/_stroke.dart';

import 'package:saber/data/prefs.dart';
import 'package:saber/data/tools/_tool.dart';
import 'package:saber/data/tools/eraser_targets.dart';
import 'package:saber/data/tools/select.dart';
import 'package:sbn/tool_id.dart';

double square(double x) => x * x;
double sqrDistanceBetween(Offset p1, Offset p2) =>
    square(p1.dx - p2.dx) + square(p1.dy - p2.dy);

/// How the eraser picks strokes: the ones it touches, or (StarNote's
/// circle-select erase) the ones inside a loop drawn around them.
///
/// Saved by position (stows.eraserMode): add new modes at the end.
enum EraserMode { stroke, lasso }

class Eraser extends Tool {
  /// Without an explicit size the eraser follows the eraser panel, so a change
  /// there applies to the eraser already in hand.
  double get size => _size ?? stows.eraserSize.value;
  final double? _size;
  double get sqrSize => square(size);

  List<Stroke> _erased = [];

  new({this._size});

  @override
  ToolId get toolId => .eraser;

  /// Returns any [strokes] that are close to the given [eraserPos], of the
  /// kinds the eraser rubs out ([EraserTargets]).
  List<Stroke> checkForOverlappingStrokes(
    Offset eraserPos,
    List<Stroke> strokes,
  ) {
    final List<Stroke> overlapping = [];
    final sqrSize = this.sqrSize;
    final targets = EraserTargets.value;
    for (int i = 0; i < strokes.length; i++) {
      final stroke = strokes[i];
      if (!targets.contains(StrokeKind.of(stroke))) continue;
      if (_shouldStrokeBeErased(eraserPos, stroke, sqrSize)) {
        overlapping.add(stroke);
        _erased.add(stroke);
      }
    }
    return overlapping;
  }

  /// The loop drawn in [EraserMode.lasso], on page [lassoPageIndex]; null
  /// when no loop is being drawn.
  Path? lassoPath;
  int? lassoPageIndex;

  void startLasso(Offset position, int pageIndex) {
    lassoPageIndex = pageIndex;
    lassoPath = Path()..moveTo(position.dx, position.dy);
  }

  void extendLasso(Offset position) =>
      lassoPath?.lineTo(position.dx, position.dy);

  /// Forgets the loop without erasing anything.
  void cancelLasso() {
    lassoPath = null;
    lassoPageIndex = null;
  }

  /// Closes the loop and returns the [strokes] mostly inside it, by the
  /// lasso's own rule ([Select.minPercentInside]), of the kinds the eraser
  /// rubs out ([EraserTargets]). The caller removes them; [onDragEnd]
  /// reports them like rubbed-out strokes.
  List<Stroke> finishLasso(List<Stroke> strokes) {
    final path = lassoPath?..close();
    lassoPath = null;
    lassoPageIndex = null;
    if (path == null) return const [];
    final targets = EraserTargets.value;
    final inside = [
      for (final stroke in strokes)
        if (targets.contains(StrokeKind.of(stroke)) &&
            Select.polygonPercentInside(path, stroke.lowQualityPolygon) >
                Select.minPercentInside)
          stroke,
    ];
    _erased.addAll(inside);
    return inside;
  }

  /// Returns the strokes that have been erased during this drag.
  List<Stroke> onDragEnd() {
    final List<Stroke> erased = _erased;
    _erased = [];
    return erased;
  }

  static bool _shouldStrokeBeErased(
    Offset eraserPos,
    Stroke stroke,
    double sqrSize,
  ) {
    if (stroke.length <= 3) {
      if (stroke.lowQualityPath.contains(eraserPos)) return true;
    }

    /// skip checking every few vertices for performance
    final int verticesToSkip = switch (stroke.lowQualityPolygon.length) {
      < 100 => 0,
      < 1000 => 1,
      _ => 2,
    };

    for (
      int i = 0;
      i < stroke.lowQualityPolygon.length;
      i += verticesToSkip + 1
    ) {
      final Offset strokeVertex = stroke.lowQualityPolygon[i];
      if (sqrDistanceBetween(strokeVertex, eraserPos) <= sqrSize) return true;
    }
    return false;
  }
}
