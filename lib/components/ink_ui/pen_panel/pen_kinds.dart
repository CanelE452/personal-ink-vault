import 'package:saber/components/kit/kit_pen_art.dart';
import 'package:saber/data/tools/_tool.dart';
import 'package:saber/data/tools/highlighter.dart';
import 'package:saber/data/tools/pen.dart';
import 'package:saber/data/tools/pencil.dart';
import 'package:sbn/tool_id.dart';

/// The pen panel's pen for [tool], null for tools that are not one of its
/// pens (shape pen, eraser, lasso, ...).
KitPenKind? penKindOf(Tool tool) {
  for (final kind in KitPenKind.values) {
    if (kind.toolId != null && kind.toolId == tool.toolId) return kind;
  }
  return null;
}

/// The tool to pick up for [kind]. The pens in hand are used again, so each
/// keeps its own size and colour: the fine-nib pen and the fine pen reuse
/// [Pen.currentPen] when it is that kind, the pencil and the highlighter are
/// their own pens in hand.
Tool toolForPenKind(KitPenKind kind) {
  assert(kind.inEngine, '${kind.label} has no engine pen');
  final current = Pen.currentPen;
  return switch (kind) {
    KitPenKind.finePen =>
      current.toolId == ToolId.ballpointPen ? current : Pen.ballpointPen(),
    KitPenKind.pencil => Pencil.currentPencil,
    KitPenKind.highlighterChisel => Highlighter.currentHighlighter,
    // the fine-nib pen (the pens the engine lacks are never offered)
    _ => current.toolId == ToolId.fountainPen ? current : Pen.fountainPen(),
  };
}

/// Whether [tool] writes ink with one of the pen panel's pens (fine-nib pen,
/// fine pen, pencil, highlighter).
bool isInkTool(Tool tool) => penKindOf(tool) != null;
