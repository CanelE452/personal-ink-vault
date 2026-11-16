import 'package:flutter/foundation.dart';

/// One button or group in a pen toolbar that the user can show, hide and move.
@immutable
class ToolbarItem {
  const ToolbarItem(this.id, this.label, {this.shownByDefault = true});

  final String id;

  /// The Korean name, used for the tooltip and in the toolbar editor.
  final String label;
  final bool shownByDefault;
}

/// The pen toolbar of PDF and page notes, in StarNote's order: undo, writing
/// tools, insert tools, colours, widths, then page and screen actions.
const pageToolbarItems = <ToolbarItem>[
  ToolbarItem('undo', '실행 취소'),
  ToolbarItem('redo', '다시 실행'),
  ToolbarItem('pen', '펜'),
  // The pen panel holds the pencil, as StarNote's does; this button is
  // for people who want it apart.
  ToolbarItem('pencil', '연필', shownByDefault: false),
  ToolbarItem('highlighter', '형광펜'),
  ToolbarItem('eraser', '지우개'),
  ToolbarItem('select', '올가미'),
  ToolbarItem('photo', '사진'),
  ToolbarItem('text', '글상자'),
  ToolbarItem('colors', '색'),
  ToolbarItem('penBox', '펜박스'),
  ToolbarItem('widths', '굵기'),
  ToolbarItem('pageMode', '쪽 보기 방식'),
  ToolbarItem('insertPage', '쪽 추가'),
  ToolbarItem('pages', '쪽 관리'),
  ToolbarItem('pageMenu', '쪽 메뉴'),
  ToolbarItem('finger', '손가락 필기'),
  ToolbarItem('fullscreen', '전체 화면'),
  ToolbarItem('laser', '레이저 포인터', shownByDefault: false),
  ToolbarItem('export', '내보내기', shownByDefault: false),
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

/// The five colours shown in the toolbars without opening the palette. The
/// first is the pens' default black, so a new pen shows as chosen.
const toolbarQuickColors = [
  0xff000000,
  0xffb63a3a,
  0xff315fa0,
  0xff237d82,
  0xffd7a51c,
];

/// The highlighter's five colours (drawn see-through), shown in its panel and
/// in the toolbar while it is in hand. The first is the highlighter's default.
const highlighterQuickColors = [
  0xffffeb3b,
  0xffffa94d,
  0xff7be07b,
  0xff8db8f2,
  0xffc39bf0,
];

/// A toolbar's items in the user's order with their visibility.
///
/// It is stored as a list of ids; a leading `!` hides the item. Items the
/// stored list does not know (unknown ids are dropped) follow in their default
/// order and visibility, so a later version can add tools.
@immutable
class ToolbarLayout {
  const ToolbarLayout._(this.items, this.shown);

  factory ToolbarLayout.decode(List<ToolbarItem> registry, List<String> stored) {
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
  ToolbarLayout moved(int oldIndex, int newIndex) {
    final next = [...items];
    final item = next.removeAt(oldIndex);
    next.insert(newIndex > oldIndex ? newIndex - 1 : newIndex, item);
    return ToolbarLayout._(List.unmodifiable(next), shown);
  }

  List<String> encode() => [
    for (final item in items) shown.contains(item.id) ? item.id : '!${item.id}',
  ];
}
