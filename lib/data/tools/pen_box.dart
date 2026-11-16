import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/tools/highlighter.dart';
import 'package:saber/data/tools/pen.dart';
import 'package:saber/data/tools/pencil.dart';
import 'package:saber/data/tools/shape_pen.dart';
import 'package:sbn/tool_id.dart';

/// One pen kept with the pen panel's "펜박스에 추가": its kind, colour, width
/// and stabilisation, enough to pick the same pen again from the pen box.
@immutable
class PenBoxEntry {
  const new({
    required this.toolId,
    required this.color,
    required this.size,
    required this.streamline,
  });

  /// The pen in hand. The colour is kept opaque: the editor adds the
  /// highlighter's transparency back when the entry is picked.
  factory of(Pen pen) => PenBoxEntry(
    toolId: pen.toolId,
    color: pen.color.withValues(alpha: 1).toARGB32(),
    size: pen.options.size,
    streamline: pen.options.streamline,
  );

  /// Null for anything the pen box did not write.
  static PenBoxEntry? fromJson(String json) {
    try {
      final map = jsonDecode(json) as Map<String, dynamic>;
      return PenBoxEntry(
        toolId: ToolId.values.byName(map['tool'] as String),
        color: map['color'] as int,
        size: (map['size'] as num).toDouble(),
        streamline: (map['streamline'] as num).toDouble(),
      );
    } catch (_) {
      return null;
    }
  }

  final ToolId toolId;
  final int color;
  final double size;
  final double streamline;

  String toJson() => jsonEncode({
    'tool': toolId.name,
    'color': color,
    'size': size,
    'streamline': streamline,
  });

  /// A new pen of this kind with this entry's width and stabilisation, kept
  /// within the pen's range. The colour goes through the editor's setColor.
  Pen createPen() {
    final pen = switch (toolId) {
      .ballpointPen => Pen.ballpointPen(),
      .pencil => Pencil(),
      .shapePen => ShapePen(),
      .highlighter => Highlighter(),
      _ => Pen.fountainPen(),
    };
    pen.setSize(size.clamp(pen.sizeMin, pen.sizeMax).toDouble());
    pen.setStreamline(streamline.clamp(0, 1).toDouble());
    return pen;
  }

  @override
  bool operator ==(Object other) =>
      other is PenBoxEntry &&
      other.toolId == toolId &&
      other.color == color &&
      other.size == size &&
      other.streamline == streamline;

  @override
  int get hashCode => Object.hash(toolId, color, size, streamline);
}

/// The pens kept with "펜박스에 추가", oldest first.
abstract final class PenBox {
  static const maxEntries = 20;

  static List<PenBoxEntry> get entries => [
    for (final json in stows.penBox.value) ?PenBoxEntry.fromJson(json),
  ];

  static bool contains(PenBoxEntry entry) => entries.contains(entry);

  /// Adds [entry] unless the box already holds it or is full.
  static bool add(PenBoxEntry entry) {
    final current = entries;
    if (current.contains(entry) || current.length >= maxEntries) return false;
    stows.penBox.value = [...stows.penBox.value, entry.toJson()];
    return true;
  }

  static void remove(PenBoxEntry entry) => stows.penBox.value = [
    for (final json in stows.penBox.value)
      if (PenBoxEntry.fromJson(json) != entry) json,
  ];
}
