import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/ink_ui/pen_panel/pen_kinds.dart';
import 'package:saber/components/kit/kit_pen_art.dart';
import 'package:saber/data/flavor_config.dart';
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
    // The pen kind in hand is reused, another kind is a new pen of that kind.
    final fountain = Pen.fountainPen();
    Pen.currentPen = fountain;
    expect(identical(toolForPenKind(KitPenKind.fountain), fountain), isTrue);
    final fine = toolForPenKind(KitPenKind.finePen);
    expect(fine, isA<Pen>());
    expect(fine.toolId, ToolId.ballpointPen);
    expect(identical(fine, fountain), isFalse);

    final ballpoint = Pen.ballpointPen();
    Pen.currentPen = ballpoint;
    expect(identical(toolForPenKind(KitPenKind.finePen), ballpoint), isTrue);
    final fresh = toolForPenKind(KitPenKind.fountain);
    expect(fresh.toolId, ToolId.fountainPen);
    expect(identical(fresh, ballpoint), isFalse);

    // A shape pen in hand is not reused for either nib.
    Pen.currentPen = ShapePen();
    expect(toolForPenKind(KitPenKind.fountain).toolId, ToolId.fountainPen);
    expect(toolForPenKind(KitPenKind.finePen).toolId, ToolId.ballpointPen);

    expect(
      identical(toolForPenKind(KitPenKind.pencil), Pencil.currentPencil),
      isTrue,
    );
    expect(
      identical(
        toolForPenKind(KitPenKind.highlighterChisel),
        Highlighter.currentHighlighter,
      ),
      isTrue,
    );

    for (final kind in KitPenKind.values.where((k) => k.inEngine)) {
      expect(penKindOf(toolForPenKind(kind)), kind, reason: kind.previewId);
    }
    expect(penKindOf(ShapePen()), isNull);
    expect(penKindOf(Eraser()), isNull);
    expect(isInkTool(Pen.fountainPen()), isTrue);
    expect(isInkTool(Pen.ballpointPen()), isTrue);
    expect(isInkTool(Pencil()), isTrue);
    expect(isInkTool(Highlighter()), isTrue);
    expect(isInkTool(ShapePen()), isFalse);
    expect(isInkTool(Eraser()), isFalse);
  });
}
