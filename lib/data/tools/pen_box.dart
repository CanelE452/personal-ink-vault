import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:saber/components/kit/kit_pen_art.dart';
import 'package:saber/data/ink/ink_tool_state.dart';
import 'package:saber/data/ink/pen_kind.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/tools/pen.dart';
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
    this.kind,
  });

  /// The pen in hand. The colour is kept opaque: the editor adds the
  /// highlighter's transparency back when the entry is picked.
  factory of(Pen pen) => PenBoxEntry(
    toolId: pen.toolId,
    color: pen.color.withValues(alpha: 1).toARGB32(),
    size: pen.options.size,
    streamline: pen.options.streamline,
    kind: penKindOf(pen),
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
        kind: KitPenKind.values
            .where((k) => k.previewId == map['kind'])
            .firstOrNull,
      );
    } catch (_) {
      return null;
    }
  }

  final ToolId toolId;
  final int color;
  final double size;
  final double streamline;

  /// The pen window's pen by its name (`previewId`), as given.
  final KitPenKind? kind;

  /// The pen window's pen of this entry: the one given, else the first with
  /// its tool (entries written before the round highlighter are the flat
  /// one); null for the shape pen.
  KitPenKind? get penKind {
    if (kind != null) return kind;
    for (final k in KitPenKind.values) {
      if (k.toolId == toolId) return k;
    }
    return null;
  }

  String toJson() => jsonEncode({
    'tool': toolId.name,
    'color': color,
    'size': size,
    'streamline': streamline,
    if (penKind case final kind?) 'kind': kind.previewId,
  });

  /// A new pen of this kind with this entry's width and stabilisation, kept
  /// within the pen's range. The colour goes through the editor's setColor.
  Pen createPen() {
    final pen = switch (penKind) {
      // picked up, so it gets its own values like one from the pen panel
      KitPenKind.highlighterRound => InkToolState.roundHighlighter(),
      final kind? => newPenOf(kind),
      null => toolId == .shapePen ? ShapePen() : Pen.fountainPen(),
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
      other.streamline == streamline &&
      other.penKind == penKind;

  @override
  int get hashCode => Object.hash(toolId, color, size, streamline, penKind);
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
