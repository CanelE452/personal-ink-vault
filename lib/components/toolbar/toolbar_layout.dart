import 'package:flutter/foundation.dart';

/// One button or group in a pen toolbar that the user can show, hide and move.
@immutable
class ToolbarItem {
  const new(this.id, this.label, {this.shownByDefault = true});

  final String id;

  /// The Korean name, used for the tooltip and in the toolbar editor.
  final String label;
  final bool shownByDefault;
}

/// The tools of the PDF and page notes' toolbar, its middle part, in StarNote's
/// order. Undo and redo sit before them and the chosen tool's colours and widths
/// after them; page and screen actions are function-row shortcuts
/// (shortcut_layout.dart).
const pageToolbarItems = <ToolbarItem>[
  ToolbarItem('pen', '펜'),
  // The pen panel holds the pencil, as StarNote's does; this button is
  // for people who want it apart.
  ToolbarItem('pencil', '연필', shownByDefault: false),
  ToolbarItem('highlighter', '형광펜'),
  ToolbarItem('eraser', '지우개'),
  ToolbarItem('select', '올가미'),
  ToolbarItem('photo', '사진'),
  ToolbarItem('text', '글상자'),
  ToolbarItem('laser', '레이저 포인터', shownByDefault: false),
];

/// The infinite note toolbar, in the same order of groups except that the
/// width sits next to the pens, so a phone-width toolbar shows it without
/// scrolling.
const infiniteToolbarItems = <ToolbarItem>[
  ToolbarItem('undo', '실행 취소'),
  ToolbarItem('redo', '다시 실행'),
  ToolbarItem('pen', '펜'),
  ToolbarItem('widths', '굵기'),
  ToolbarItem('highlighter', '형광펜'),
  ToolbarItem('eraser', '지우개'),
  ToolbarItem('lasso', '올가미'),
  ToolbarItem('pan', '이동'),
  ToolbarItem('origin', '원점으로'),
  ToolbarItem('colors', '색'),
  ToolbarItem('finger', '손가락 필기'),
  ToolbarItem('save', '저장'),
];

/// The five colours shown in the toolbars without opening the palette,
/// StarNote's `shape_color_list_default`. The first is the pens' default
/// black, so a new pen shows as chosen.
const toolbarQuickColors = [
  0xff000000,
  0xffb33333,
  0xff2b4faf,
  0xff007355,
  0xffdaa001,
];

/// The highlighter's five colours, StarNote's `shape_color_list_mark_pen`
/// without its transparency (the canvas draws every highlighter stroke with
/// one transparency), shown in its panel and in the toolbar while it is in
/// hand. The first is the highlighter's default.
const highlighterQuickColors = [
  0xffffe60f,
  0xffffa047,
  0xff60f748,
  0xffa0c6fe,
  0xffbe9aff,
];

/// The eraser's three toolbar sizes (radius). StarNote's
/// shape_eraser_size_list_default is 30, 60 and 100 across, in the unit of its
/// pen widths, which this app's widths share; half of each is the radius here,
/// capped by the panel slider's 60.
const eraserSizePresets = <double>[15, 30, 50];

/// A toolbar's items in the user's order with their visibility.
///
/// It is stored as a list of ids; a leading `!` hides the item. Items the
/// stored list does not know (unknown ids are dropped) follow in their default
/// order and visibility, so a later version can add tools.
@immutable
class ToolbarLayout {
  const new _(this.items, this.shown);

  factory decode(List<ToolbarItem> registry, List<String> stored) {
    final unplaced = {for (final item in registry) item.id: item};
    final items = <ToolbarItem>[];
    final shown = <String>{};
    for (final entry in stored) {
      final hidden = entry.startsWith('!');
      final item = unplaced.remove(hidden ? entry.substring(1) : entry);
      if (item == null) continue;
      items.add(item);
      if (!hidden) shown.add(item.id);
    }
    for (final item in registry) {
      if (unplaced.remove(item.id) == null) continue;
      items.add(item);
      if (item.shownByDefault) shown.add(item.id);
    }
    return ToolbarLayout._(List.unmodifiable(items), Set.unmodifiable(shown));
  }

  final List<ToolbarItem> items;
  final Set<String> shown;

  List<String> get shownIds => [
    for (final item in items)
      if (shown.contains(item.id)) item.id,
  ];

  String labelOf(String id) =>
      items.firstWhere((item) => item.id == id, orElse: () => ToolbarItem(id, id)).label;

  ToolbarLayout withShown(String id, bool value) =>
      ToolbarLayout._(items, Set.unmodifiable(value ? {...shown, id} : ({...shown}..remove(id))));

  /// Moves an item the way [ReorderableListView.onReorder] reports it.
  /// The item at [from] moved so that it ends at [to] (the index after the move, as
  /// ReorderableListView.onReorderItem reports it).
  ToolbarLayout moved(int from, int to) {
    final next = [...items];
    next.insert(to, next.removeAt(from));
    return ToolbarLayout._(List.unmodifiable(next), shown);
  }

  List<String> encode() => [
    for (final item in items)
      if (shown.contains(item.id)) item.id else '!${item.id}',
  ];
}
