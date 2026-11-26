import 'package:flutter/foundation.dart';
import 'package:saber/components/kit/kit_icons.g.dart';
import 'package:saber/data/actions/app_action_ids.dart';
import 'package:saber/data/tools/_tool.dart';
import 'package:saber/data/tools/eraser.dart';
import 'package:saber/data/tools/laser_pointer.dart';
import 'package:saber/data/tools/select.dart';
import 'package:saber/data/tools/shape_pen.dart';

/// One tool of the editor toolbar's middle (preview 9th draft c `TOOLS`):
/// its id in the saved layout, its button name, its icon and the action it
/// runs.
@immutable
class ToolbarTool {
  const new(this.id, this.label, this.icon, this.action);

  final String id;
  final String label;
  final KitIconName icon;
  final String action;
}

/// The tools in their default order. The emoji tool of the preview has no
/// feature in stage 1, so it is not in the list yet (a saved layout gets it
/// at the end, hidden, when a later stage adds it).
const toolbarTools = <ToolbarTool>[
  ToolbarTool('lasso', '올가미', KitIconName.lassoFree, AppActionIds.toolLasso),
  ToolbarTool('pen', '펜', KitIconName.pen, AppActionIds.toolPen),
  ToolbarTool('eraser', '지우개', KitIconName.eraser, AppActionIds.toolEraser),
  ToolbarTool('text', '텍스트', KitIconName.text, AppActionIds.toolText),
  ToolbarTool('shapes', '모양', KitIconName.shapes, AppActionIds.toolShapes),
  ToolbarTool('image', '사진', KitIconName.image, AppActionIds.pickPhoto),
  ToolbarTool('laser', '레이저 펜', KitIconName.laser, AppActionIds.toolLaser),
];

/// Hidden until the user puts it on the bar (preview `DEF`).
const _hiddenByDefault = {'laser'};

/// What switching a tool on or off did.
enum ToolbarToolSwitch {
  done,

  /// Refused: six tools are on the bar already.
  tooMany,

  /// Refused: it is the last tool on the bar.
  tooFew,
}

/// The editor toolbar's tools in the user's order, each on the bar or in
/// the ⌄ window. Stored as a list of ids, a leading `!` for a tool in the
/// window. The bar holds 1 to [maxShown] tools.
@immutable
class ToolbarToolsLayout {
  const new _(this.ids, this.shown);

  static const maxShown = 6;

  /// The tools as saved. A layout that cannot be read (an empty entry, `!`
  /// alone, an unknown or repeated id, no tool or more than [maxShown] on
  /// the bar) gives the default. Tools the list does not name follow in
  /// their default order and place; on the bar only while it has room.
  factory decode(List<String> stored) {
    final known = {for (final tool in toolbarTools) tool.id};
    final ids = <String>[];
    final shown = <String>{};
    for (final entry in stored) {
      final hidden = entry.startsWith('!');
      final id = hidden ? entry.substring(1) : entry;
      if (!known.contains(id) || ids.contains(id)) return _default;
      ids.add(id);
      if (!hidden) shown.add(id);
    }
    for (final tool in toolbarTools) {
      if (ids.contains(tool.id)) continue;
      ids.add(tool.id);
      if (!_hiddenByDefault.contains(tool.id) && shown.length < maxShown) {
        shown.add(tool.id);
      }
    }
    if (shown.isEmpty || shown.length > maxShown) return _default;
    return ToolbarToolsLayout._(List.unmodifiable(ids), Set.unmodifiable(shown));
  }

  static final _default = ToolbarToolsLayout._(
    List.unmodifiable([for (final tool in toolbarTools) tool.id]),
    Set.unmodifiable({
      for (final tool in toolbarTools)
        if (!_hiddenByDefault.contains(tool.id)) tool.id,
    }),
  );

  /// The 229 page toolbar's layout (`pageToolbarLayout`) in the new tools:
  /// `select` is the lasso, `photo` the picture; ids the new bar has no
  /// button for (the pencil, the highlighter, the 228 page actions) are
  /// dropped.
  factory migrate(List<String> stored229) {
    final known = {for (final tool in toolbarTools) tool.id};
    final seen = <String>{};
    return ToolbarToolsLayout.decode([
      for (final entry in stored229)
        if (_migrated(entry) case final e?)
          if (known.contains(e.replaceFirst('!', '')) &&
              seen.add(e.replaceFirst('!', '')))
            e,
    ]);
  }

  static String? _migrated(String entry) {
    final hidden = entry.startsWith('!');
    final id = hidden ? entry.substring(1) : entry;
    if (id.isEmpty) return null;
    final now = switch (id) {
      'select' => 'lasso',
      'photo' => 'image',
      _ => id,
    };
    return hidden ? '!$now' : now;
  }

  /// The layout to show: the saved one, or, while the toolbar was never
  /// customized ([stored] empty), the 229 one.
  factory read({
    required List<String> stored,
    required List<String> stored229,
  }) => stored.isEmpty
      ? ToolbarToolsLayout.migrate(stored229)
      : ToolbarToolsLayout.decode(stored);

  /// Every tool id in order.
  final List<String> ids;

  /// The ids on the bar.
  final Set<String> shown;

  List<String> get shownIds => [
    for (final id in ids)
      if (shown.contains(id)) id,
  ];

  List<String> get hiddenIds => [
    for (final id in ids)
      if (!shown.contains(id)) id,
  ];

  /// Puts [id] on the bar or in the ⌄ window; refused (null layout) past
  /// [maxShown] or for the last tool on the bar.
  (ToolbarToolSwitch, ToolbarToolsLayout) withShown(String id, bool value) {
    if (value == shown.contains(id)) return (ToolbarToolSwitch.done, this);
    if (value && shown.length >= maxShown) {
      return (ToolbarToolSwitch.tooMany, this);
    }
    if (!value && shown.length <= 1) return (ToolbarToolSwitch.tooFew, this);
    return (
      ToolbarToolSwitch.done,
      ToolbarToolsLayout._(
        ids,
        Set.unmodifiable(value ? {...shown, id} : ({...shown}..remove(id))),
      ),
    );
  }

  /// The tool at [from] moved to end at [to] (the index after the move).
  ToolbarToolsLayout moved(int from, int to) {
    final next = [...ids];
    next.insert(to, next.removeAt(from));
    return ToolbarToolsLayout._(List.unmodifiable(next), shown);
  }

  /// Every tool, never empty: an empty list means 「not customized yet」.
  List<String> encode() => [
    for (final id in ids)
      if (shown.contains(id)) id else '!$id',
  ];
}

ToolbarTool toolbarToolOf(String id) =>
    toolbarTools.firstWhere((tool) => tool.id == id);

/// The icon of [tool]'s button: the lasso's shows its kind, rectangle when
/// [lassoRect] (`stows.selectRectangle`).
KitIconName toolbarToolIcon(ToolbarTool tool, {required bool lassoRect}) =>
    tool.id == 'lasso' && lassoRect ? KitIconName.lassoRect : tool.icon;

/// The icon of the tool in hand: its toolbar button's, so the pen tip badge
/// and the bar show the same. The pen button stands for every pen (the
/// highlighter and the pencil too).
KitIconName kitIconForTool(Tool tool, {required bool lassoRect}) {
  final id = switch (tool) {
    Select() => 'lasso',
    Eraser() => 'eraser',
    ShapePen() => 'shapes',
    LaserPointer() => 'laser',
    _ when tool == Tool.textEditing => 'text',
    _ => 'pen',
  };
  return toolbarToolIcon(toolbarToolOf(id), lassoRect: lassoRect);
}
