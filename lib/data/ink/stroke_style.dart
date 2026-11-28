import 'package:flutter/foundation.dart';
import 'package:saber/components/kit/kit_pen_art.dart';
import 'package:saber/data/tools/highlighter.dart';
import 'package:sbn/tool_id.dart';

/// The tip of a pen: a round dot, or a flat chisel held at an angle.
enum InkNib { round, chisel }

/// The opacity a stroke of [tool] has when nothing sets it: a whole number
/// from 0 to 255. Only the highlighter is see-through.
int defaultAlphaOf(ToolId tool) =>
    tool == ToolId.highlighter ? Highlighter.alpha : 255;

/// What a stroke looks like beyond its pen, colour and width. Each value is
/// written to the note only when it differs from what an older app draws, so
/// a note without them keeps its version and its bytes.
///
/// The opacity is a whole number so that moving the opacity arc and putting it
/// back on the default does not leave a rounding error that would make the
/// note version 21.
@immutable
class StrokeStyle {
  const new({
    this.alpha,
    this.lineStyle = KitPenDash.solid,
    this.nib = InkNib.round,
    this.nibAngle,
  });

  /// Opacity 0 to 255, or null for the pen's default ([defaultAlphaOf]).
  final int? alpha;
  final KitPenDash lineStyle;
  final InkNib nib;

  /// The chisel's angle in degrees, or null when none was set.
  final double? nibAngle;

  /// Reads the keys `op`, `ls`, `nb`, `na`. A missing or unknown value is the
  /// default.
  // ignore: prefer_constructors_over_static_methods
  static StrokeStyle fromJson(Map<String, dynamic> json) {
    final op = json['op'];
    final ls = json['ls'];
    final nb = json['nb'];
    final na = json['na'];
    return StrokeStyle(
      alpha: op is num ? op.round().clamp(0, 255) : null,
      lineStyle: ls is String
          ? KitPenDash.values.asNameMap()[ls] ?? KitPenDash.solid
          : KitPenDash.solid,
      nib: nb == 'chisel' ? InkNib.chisel : InkNib.round,
      nibAngle: na is num ? na.toDouble() : null,
    );
  }

  /// Adds the keys of the values that differ from the default of [tool].
  void writeTo(Map<String, dynamic> json, {required ToolId tool}) {
    final alpha = this.alpha;
    if (alpha != null && alpha != defaultAlphaOf(tool)) json['op'] = alpha;
    if (lineStyle != KitPenDash.solid) json['ls'] = lineStyle.name;
    if (nib == InkNib.chisel) json['nb'] = 'chisel';
    final nibAngle = this.nibAngle;
    if (nibAngle != null) json['na'] = nibAngle;
  }

  /// Whether a stroke of [tool] with this style writes a key that apps before
  /// version 21 do not know.
  bool needsV21({required ToolId tool}) {
    final json = <String, dynamic>{};
    writeTo(json, tool: tool);
    return json.isNotEmpty;
  }

  @override
  bool operator ==(Object other) =>
      other is StrokeStyle &&
      other.alpha == alpha &&
      other.lineStyle == lineStyle &&
      other.nib == nib &&
      other.nibAngle == nibAngle;

  @override
  int get hashCode => Object.hash(alpha, lineStyle, nib, nibAngle);
}

/// The keys of a stroke in a version 19 or 20 note. A stroke with a key
/// outside this set makes the note version 21.
const v20StrokeKeys = {
  'shape', 'p', 'i', 'ty', 'pe', 'c', 'ox', 'oy', 's', 't', 'sm', 'sl', 'sp', //
  'ts', 'te', 'cs', 'ce', 'f', 'cx', 'cy', 'r', 'rl', 'rt', 'rw', 'rh',
};

/// The keys of a page in a version 19 or 20 note. A page with a key outside
/// this set makes the note version 21.
const v20PageKeys = {'pageId', 'w', 'h', 's', 'i', 'b', 'q', 'lk', 'bp'};
