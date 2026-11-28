import 'package:saber/components/kit/kit_pen_art.dart';
import 'package:saber/data/ink/ink_tool_state.dart';
import 'package:saber/data/ink/stroke_style.dart';
import 'package:saber/data/tools/_tool.dart';
import 'package:saber/data/tools/highlighter.dart';
import 'package:saber/data/tools/pen.dart';
import 'package:saber/data/tools/pencil.dart';
import 'package:sbn/tool_id.dart';

/// The pen panel's pen for [tool], null for tools that are not one of its
/// pens (shape pen, eraser, lasso, ...). The two highlighters are one tool:
/// a [Highlighter] with a round nib is the round one, any other the flat one
/// (the infinite note's highlighter too).
KitPenKind? penKindOf(Tool tool) {
  if (tool.toolId == ToolId.highlighter) {
    return tool is Highlighter && tool.nib == InkNib.round
        ? KitPenKind.highlighterRound
        : KitPenKind.highlighterChisel;
  }
  for (final kind in KitPenKind.values) {
    if (kind.toolId != null && kind.toolId == tool.toolId) return kind;
  }
  return null;
}

/// The tool to pick up for [kind], the one [state] keeps for it
/// ([InkToolState.penFor]).
Tool toolForPenKind(KitPenKind kind, InkToolState state) => state.penFor(kind);

/// A new pen of [kind], with the settings its kind keeps.
Pen newPenOf(KitPenKind kind) => switch (kind) {
  KitPenKind.fountain => Pen.fountainPen(),
  KitPenKind.calligraphy => Pen.calligraphyPen(),
  KitPenKind.finePen => Pen.ballpointPen(),
  KitPenKind.pencil => Pencil(),
  KitPenKind.brush => Pen.brush(),
  KitPenKind.highlighterChisel => Highlighter(),
  KitPenKind.highlighterRound => Highlighter.round(),
};

/// Whether [tool] writes ink with one of the pen panel's pens.
bool isInkTool(Tool tool) => penKindOf(tool) != null;

/// What the engine needs to draw a pen of the pen window: its tool (null for
/// none), its nib, and the thinnest and thickest width in px.
typedef InkPenSpec = ({
  ToolId? toolId,
  InkNib nib,
  double minSize,
  double maxSize,
});

/// The tool, nib and width range of [kind]. Only the calligraphy pen and the
/// flat highlighter have a chisel nib; the flat highlighter has a fixed
/// angle, so only the calligraphy pen saves a nib angle with its strokes.
InkPenSpec specOf(KitPenKind kind) => switch (kind) {
  KitPenKind.fountain => (
    toolId: ToolId.fountainPen,
    nib: InkNib.round,
    minSize: 1,
    maxSize: 25,
  ),
  KitPenKind.calligraphy => (
    toolId: ToolId.calligraphyPen,
    nib: InkNib.chisel,
    minSize: 2,
    maxSize: 30,
  ),
  KitPenKind.finePen => (
    toolId: ToolId.ballpointPen,
    nib: InkNib.round,
    minSize: 1,
    maxSize: 25,
  ),
  KitPenKind.pencil => (
    toolId: ToolId.pencil,
    nib: InkNib.round,
    minSize: 1,
    maxSize: 15,
  ),
  KitPenKind.brush => (
    toolId: ToolId.brush,
    nib: InkNib.round,
    minSize: 2,
    maxSize: 50,
  ),
  KitPenKind.highlighterChisel => (
    toolId: ToolId.highlighter,
    nib: InkNib.chisel,
    minSize: 10,
    maxSize: 100,
  ),
  KitPenKind.highlighterRound => (
    toolId: ToolId.highlighter,
    nib: InkNib.round,
    minSize: 10,
    maxSize: 100,
  ),
};

/// The pen that wrote a stroke of [tool] with [style]. The flat and the round
/// highlighter are one tool; the nib tells them apart.
KitPenKind kindOfStroke(ToolId tool, StrokeStyle style) => switch (tool) {
  ToolId.highlighter =>
    style.nib == InkNib.chisel
        ? KitPenKind.highlighterChisel
        : KitPenKind.highlighterRound,
  ToolId.calligraphyPen => KitPenKind.calligraphy,
  ToolId.brush => KitPenKind.brush,
  ToolId.ballpointPen => KitPenKind.finePen,
  ToolId.pencil => KitPenKind.pencil,
  // everything else, the eraser, the lasso and unknown ids too, reads as
  // the fountain pen: callers ask about strokes of ink tools only
  _ => KitPenKind.fountain,
};
