import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/kit/kit_pen_art.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/ink/ink_tool_state.dart';
import 'package:saber/data/ink/pen_kind.dart';
import 'package:saber/data/tools/eraser.dart';
import 'package:saber/data/tools/highlighter.dart';
import 'package:saber/data/tools/pen.dart';
import 'package:saber/data/tools/pencil.dart';
import 'package:saber/data/tools/shape_pen.dart';
import 'package:sbn/tool_id.dart';

void main() {
  FlavorConfig.setup();

  tearDown(() {
    Pen.currentPen = Pen.fountainPen();
    Pencil.currentPencil = Pencil();
    Highlighter.currentHighlighter = Highlighter();
  });

  test('pen kinds map to tools and back', () {
    final state = InkToolState(Pen.fountainPen());
    addTearDown(state.dispose);
    // The pen kind in hand is reused, another kind is a new pen of that kind.
    final fountain = Pen.fountainPen();
    Pen.currentPen = fountain;
    expect(
      identical(toolForPenKind(KitPenKind.fountain, state), fountain),
      isTrue,
    );
    final fine = toolForPenKind(KitPenKind.finePen, state);
    expect(fine, isA<Pen>());
    expect(fine.toolId, ToolId.ballpointPen);
    expect(identical(fine, fountain), isFalse);

    final ballpoint = Pen.ballpointPen();
    Pen.currentPen = ballpoint;
    expect(
      identical(toolForPenKind(KitPenKind.finePen, state), ballpoint),
      isTrue,
    );
    final fresh = toolForPenKind(KitPenKind.fountain, state);
    expect(fresh.toolId, ToolId.fountainPen);
    expect(identical(fresh, ballpoint), isFalse);

    // A shape pen in hand is not reused for either nib.
    Pen.currentPen = ShapePen();
    expect(
      toolForPenKind(KitPenKind.fountain, state).toolId,
      ToolId.fountainPen,
    );
    expect(
      toolForPenKind(KitPenKind.finePen, state).toolId,
      ToolId.ballpointPen,
    );

    expect(
      identical(toolForPenKind(KitPenKind.pencil, state), Pencil.currentPencil),
      isTrue,
    );
    expect(
      identical(
        toolForPenKind(KitPenKind.highlighterChisel, state),
        Highlighter.currentHighlighter,
      ),
      isTrue,
    );

    // every pen of the pen window has an engine pen now
    expect(KitPenKind.values.where((k) => !k.inEngine), isEmpty);
    for (final kind in KitPenKind.values) {
      expect(
        penKindOf(toolForPenKind(kind, state)),
        kind,
        reason: kind.previewId,
      );
    }
    // the new pens are kept in the tool state, made the first time
    for (final kind in const [
      KitPenKind.calligraphy,
      KitPenKind.brush,
      KitPenKind.highlighterRound,
    ]) {
      expect(
        identical(toolForPenKind(kind, state), state.penFor(kind)),
        isTrue,
        reason: kind.previewId,
      );
    }
    expect(
      toolForPenKind(KitPenKind.calligraphy, state).toolId,
      ToolId.calligraphyPen,
    );
    expect(toolForPenKind(KitPenKind.brush, state).toolId, ToolId.brush);
    // the two highlighters share a tool id; the nib tells them apart
    expect(penKindOf(Highlighter()), KitPenKind.highlighterChisel);
    expect(penKindOf(Highlighter.round()), KitPenKind.highlighterRound);
    expect(
      identical(
        toolForPenKind(KitPenKind.highlighterRound, state),
        Highlighter.currentHighlighter,
      ),
      isFalse,
    );
    expect(penKindOf(ShapePen()), isNull);
    expect(penKindOf(Eraser()), isNull);
    expect(isInkTool(Pen.fountainPen()), isTrue);
    expect(isInkTool(Pen.ballpointPen()), isTrue);
    expect(isInkTool(Pencil()), isTrue);
    expect(isInkTool(Highlighter()), isTrue);
    expect(isInkTool(Highlighter.round()), isTrue);
    expect(isInkTool(Pen.brush()), isTrue);
    expect(isInkTool(Pen.calligraphyPen()), isTrue);
    expect(isInkTool(ShapePen()), isFalse);
    expect(isInkTool(Eraser()), isFalse);
  });
}
