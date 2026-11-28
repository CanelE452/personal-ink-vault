import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/kit/kit_pen_art.dart';
import 'package:saber/data/ink/stroke_style.dart';
import 'package:saber/data/tools/highlighter.dart';
import 'package:sbn/tool_id.dart';

/// A stroke's own look beyond the pen: opacity, line style, nib. Each value is
/// written only when it differs from what an older app draws, so notes without
/// them keep their bytes.
void main() {
  Map<String, dynamic> written(StrokeStyle style, ToolId tool) {
    final json = <String, dynamic>{};
    style.writeTo(json, tool: tool);
    return json;
  }

  test('a highlighter at the default opacity writes no op', () {
    expect(defaultAlphaOf(ToolId.highlighter), Highlighter.alpha);
    expect(defaultAlphaOf(ToolId.fountainPen), 255);
    expect(written(const StrokeStyle(), ToolId.highlighter), isEmpty);
    expect(
      written(
        const StrokeStyle(alpha: Highlighter.alpha),
        ToolId.highlighter,
      ),
      isEmpty,
    );
    expect(const StrokeStyle().needsV21(tool: ToolId.highlighter), isFalse);
  });

  test('alpha 128 is written as op 128 and read back', () {
    const style = StrokeStyle(alpha: 128);
    final json = written(style, ToolId.fountainPen);
    expect(json, {'op': 128});
    expect(json['op'], isA<int>());
    expect(StrokeStyle.fromJson(json).alpha, 128);
    expect(style.needsV21(tool: ToolId.fountainPen), isTrue);
    // 128 is not the highlighter's default either
    expect(written(style, ToolId.highlighter), {'op': 128});
  });

  test('alpha 100 on a highlighter after the arc was moved writes no op', () {
    // the arc was moved and put back: 100 is a whole number again
    const style = StrokeStyle(alpha: Highlighter.alpha);
    expect(written(style, ToolId.highlighter), isEmpty);
    expect(style.needsV21(tool: ToolId.highlighter), isFalse);
    // the same 100 on another pen is not its default (255)
    expect(written(style, ToolId.ballpointPen), {'op': 100});
    // an opaque stroke of a pen whose default is opaque writes nothing
    expect(
      written(const StrokeStyle(alpha: 255), ToolId.ballpointPen),
      isEmpty,
    );
  });

  test("solid writes no ls; dash writes 'dash'", () {
    expect(written(const StrokeStyle(), ToolId.ballpointPen), isEmpty);
    expect(
      written(
        const StrokeStyle(lineStyle: KitPenDash.dash),
        ToolId.ballpointPen,
      ),
      {'ls': 'dash'},
    );
    expect(
      written(const StrokeStyle(lineStyle: KitPenDash.dot), ToolId.pencil),
      {'ls': 'dot'},
    );
    expect(
      written(const StrokeStyle(lineStyle: KitPenDash.thin), ToolId.pencil),
      {'ls': 'thin'},
    );
    expect(
      StrokeStyle.fromJson(const {'ls': 'dash'}).lineStyle,
      KitPenDash.dash,
    );
    expect(
      StrokeStyle.fromJson(const {'ls': 'nonsense'}).lineStyle,
      KitPenDash.solid,
    );
  });

  test("round writes no nb; chisel writes 'chisel'", () {
    expect(written(const StrokeStyle(), ToolId.highlighter), isEmpty);
    final json = written(
      const StrokeStyle(nib: InkNib.chisel),
      ToolId.highlighter,
    );
    expect(json, {'nb': 'chisel'});
    expect(StrokeStyle.fromJson(json).nib, InkNib.chisel);
    expect(StrokeStyle.fromJson(const {}).nib, InkNib.round);
    expect(
      const StrokeStyle(nib: InkNib.chisel).needsV21(tool: ToolId.highlighter),
      isTrue,
    );
  });

  test('nibAngle 30 writes na 30', () {
    final json = written(const StrokeStyle(nibAngle: 30), ToolId.fountainPen);
    expect(json, {'na': 30.0});
    expect(StrokeStyle.fromJson(json).nibAngle, 30);
    expect(StrokeStyle.fromJson(const {}).nibAngle, isNull);
    expect(
      const StrokeStyle(nibAngle: 30).needsV21(tool: ToolId.fountainPen),
      isTrue,
    );
  });
}
