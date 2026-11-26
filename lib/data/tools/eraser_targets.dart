import 'package:saber/components/canvas/_circle_stroke.dart';
import 'package:saber/components/canvas/_rectangle_stroke.dart';
import 'package:saber/components/canvas/_stroke.dart';
import 'package:saber/data/prefs.dart';
import 'package:sbn/tool_id.dart';

/// What a stroke on the page is, for the eraser's 「지울 대상」 and the
/// lasso's 「선택 대상」. Read from what the file already keeps, so the save
/// format stays as it is.
enum StrokeKind {
  /// The fountain pen and the ballpoint pen (펜(가는 촉), 가는 펜).
  pen,
  pencil,
  highlighter,

  /// The shape pen's strokes: the ones it left as drawn or made straight, and
  /// the circles and rectangles it turned them into.
  shape;

  /// [stroke]'s kind. A circle or a rectangle is a shape whatever tool it
  /// names (they are kept without one and read back as the shape pen's);
  /// a tool with no kind of its own (none draws on a page now) counts as a
  /// pen, so with every kind on everything is erased, as before.
  static StrokeKind of(Stroke stroke) {
    if (stroke is CircleStroke || stroke is RectangleStroke) return shape;
    return switch (stroke.toolId) {
      ToolId.highlighter => highlighter,
      ToolId.pencil => pencil,
      ToolId.shapePen => shape,
      _ => pen,
    };
  }
}

/// What the eraser rubs out (「지울 대상」): any of the four kinds, at least one.
/// Kept by name in `stows.eraserTargets`. Until that is first set, the old
/// 「형광펜만 지우기」 (`stows.eraseHighlighterOnly`) decides: on, the
/// highlighter alone, off, all four. A value that cannot be read gives all
/// four. The eraser's advanced settings change it through here, so the last
/// kind on cannot be turned off.
abstract final class EraserTargets {
  /// The kinds the eraser rubs out now.
  static Set<StrokeKind> get value {
    final stored = stows.eraserTargets.value;
    if (stored.isEmpty) {
      return stows.eraseHighlighterOnly.value
          ? {StrokeKind.highlighter}
          : StrokeKind.values.toSet();
    }
    final byName = StrokeKind.values.asNameMap();
    final kinds = <StrokeKind>{};
    for (final name in stored) {
      final kind = byName[name];
      if (kind == null) return StrokeKind.values.toSet();
      kinds.add(kind);
    }
    return kinds;
  }

  /// Whether the eraser rubs out [stroke].
  static bool erases(Stroke stroke) => value.contains(StrokeKind.of(stroke));

  /// Whether [kind] is the only one on, so it cannot be turned off now.
  static bool isLocked(StrokeKind kind) {
    final on = value;
    return on.length == 1 && on.contains(kind);
  }

  /// Sets [kind] to [on], unless that would turn the last one off: then
  /// nothing changes and this returns false.
  static bool set(StrokeKind kind, bool on) {
    if (!on && isLocked(kind)) return false;
    final kinds = value..remove(kind);
    if (on) kinds.add(kind);
    stows.eraserTargets.value = [
      for (final k in StrokeKind.values)
        if (kinds.contains(k)) k.name,
    ];
    return true;
  }
}
