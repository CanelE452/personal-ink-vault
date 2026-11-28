import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:stow_codecs/stow_codecs.dart';

/// An enum of all available tools.
/// Settings store a tool as its position in this list, so a new tool is only
/// ever added at the end.
enum ToolId(final String id) {
  highlighter('Highlighter'),
  fountainPen('fountainPen'),
  ballpointPen('ballpointPen'),
  pencil('Pencil'),
  shapePen('ShapePen'),
  eraser('Eraser'),
  select('Select'),
  textEditing('TextEditingTool'),
  laserPointer('LaserPointer'),
  calligraphyPen('calligraphyPen'),
  brush('brush');

  static const codec = EnumCodec(values);

  static final _log = Logger('ToolId');

  /// Before using this enum, we used the (runtimeType).toString()
  /// as the identifier for pens.
  /// This function converts those old identifiers to the new [ToolId]s.
  static ToolId parsePenType(String? penType, {required ToolId fallback}) {
    if (penType == null) {
      return fallback;
    }
    if (penType == 'Pen') {
      return .fountainPen;
    }
    for (final toolId in ToolId.values) {
      if (penType == toolId.id) {
        return toolId;
      }
    }
    if (kDebugMode) {
      throw ArgumentError.value(
        penType,
        'penType',
        'Unknown pen type: `$penType`.',
      );
    }
    _log.warning(
      'Unknown pen type: `$penType`, using fallback `${fallback.id}`.',
    );
    return fallback;
  }
}
