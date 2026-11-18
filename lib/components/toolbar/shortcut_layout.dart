import 'package:flutter/material.dart';

/// Where a shortcut of a note's function row sits, as in StarNote's shortcut
/// bar: its left or right part, or the ⋯ "더 많은 기능" menu.
enum ShortcutSide { left, right, more }

/// One shortcut the user can place in the function row.
@immutable
class ShortcutItem {
  const new(this.id, this.label, this.side, this.icon);

  final String id;
  final String label;

  /// Its place until the user moves it.
  final ShortcutSide side;

  /// The icon in the shortcut editor's lists.
  final IconData icon;
}

/// StarNote allows ten shortcuts besides "문서 개요" and "기타 설정".
const maxBarShortcuts = 10;

/// Every shortcut of the note function row, in its default order. The workspace
/// and the editor each provide the ones that apply to the open document.
const noteShortcutItems = <ShortcutItem>[
  ShortcutItem('prev', '이전 위치', .left, Icons.arrow_back_ios_new),
  ShortcutItem('next', '다음 위치', .left, Icons.arrow_forward_ios),
  ShortcutItem('save', '기기에 저장', .left, Icons.save_outlined),
  ShortcutItem('pdfSearch', 'PDF 본문 검색', .left, Icons.search),
  ShortcutItem('documentExport', '문서 내보내기', .left, Icons.file_download_outlined),
  ShortcutItem('insertPage', '페이지 추가', .left, Icons.insert_page_break),
  ShortcutItem('pageMode', '연속 스크롤 / 한 쪽씩 보기', .left, Icons.view_agenda_outlined),
  ShortcutItem('finger', '손가락 필기', .left, Icons.back_hand_outlined),
  ShortcutItem('viewToggle', 'PDF·필기 / Markdown', .right, Icons.notes),
  ShortcutItem('fullscreen', '전체 화면', .right, Icons.fullscreen),
  ShortcutItem('export', '파일 내보내기', .more, Icons.share),
  ShortcutItem('pdfRemake', '새 엔진으로 PDF 다시 만들기', .more, Icons.autorenew),
  ShortcutItem('quickSwitch', '빠른 문서 전환', .more, Icons.manage_search),
  ShortcutItem('bookmarks', '북마크', .more, Icons.format_list_bulleted),
  ShortcutItem('knowledge', '문서 연결 · 태그 · 그래프', .more, Icons.hub_outlined),
  ShortcutItem('mcp', '다른 AI 연결 · MCP', .more, Icons.smart_toy_outlined),
  ShortcutItem('copyPageLink', '현재 페이지 링크 복사', .more, Icons.link),
  ShortcutItem('openNoteLink', '노트 링크 열기', .more, Icons.open_in_new),
  ShortcutItem('vaultExport', 'Obsidian 보관함 ZIP', .more, Icons.archive_outlined),
  // Last, so the rows above keep their places in 더 많은 기능.
  ShortcutItem('linkAdd', '링크 추가', .more, Icons.add_link),
];

/// The page actions that were switches of the 228 pen toolbar and are
/// shortcuts now, by their shared id.
const _formerToolbarActions = {'insertPage', 'pageMode', 'finger', 'fullscreen'};

/// The function row's shortcuts in the user's order.
///
/// Stored as a list: `L:id` and `R:id` sit in the bar's left and right parts,
/// `!id` in "더 많은 기능". Shortcuts the stored list does not name take their
/// default place, so a later version can add shortcuts.
@immutable
class ShortcutLayout {
  const new _(this.left, this.right, this.more);

  /// [legacyToolbar] is the 228 toolbar layout: until the user arranges the bar,
  /// a page action they hid there starts in "더 많은 기능", and the export button
  /// they showed starts on the bar.
  factory decode(
    List<ShortcutItem> registry,
    List<String> stored, {
    List<String> legacyToolbar = const [],
  }) {
    final known = {for (final item in registry) item.id};
    final left = <String>[];
    final right = <String>[];
    final more = <String>[];
    List<String> listOf(ShortcutSide side) => switch (side) {
      .left => left,
      .right => right,
      .more => more,
    };
    final placed = <String>{};
    for (final entry in stored) {
      final (side, id) = entry.startsWith('!')
          ? (ShortcutSide.more, entry.substring(1))
          : entry.startsWith('L:')
          ? (ShortcutSide.left, entry.substring(2))
          : entry.startsWith('R:')
          ? (ShortcutSide.right, entry.substring(2))
          : (null, entry);
      if (side == null || !known.contains(id) || !placed.add(id)) continue;
      listOf(side).add(id);
    }
    final legacy = <String, ShortcutSide>{
      if (stored.isEmpty) ...{
        for (final id in _formerToolbarActions)
          if (legacyToolbar.contains('!$id')) id: ShortcutSide.more,
        if (legacyToolbar.contains('export')) 'export': ShortcutSide.left,
      },
    };
    for (final item in registry) {
      if (placed.contains(item.id)) continue;
      listOf(legacy[item.id] ?? item.side).add(item.id);
    }
    return ShortcutLayout._(
      List.unmodifiable(left),
      List.unmodifiable(right),
      List.unmodifiable(more),
    );
  }

  final List<String> left;
  final List<String> right;
  final List<String> more;

  /// The shortcuts on the bar (StarNote's limit is [maxBarShortcuts]).
  int get barCount => left.length + right.length;

  ShortcutSide sideOf(String id) => left.contains(id)
      ? .left
      : right.contains(id)
      ? .right
      : .more;

  /// [id] moved to [side], at [index] there or at its end.
  ShortcutLayout placed(String id, ShortcutSide side, {int? index}) {
    List<String> without(List<String> ids) => [
      for (final other in ids)
        if (other != id) other,
    ];
    final lists = {
      ShortcutSide.left: without(left),
      ShortcutSide.right: without(right),
      ShortcutSide.more: without(more),
    };
    final target = lists[side]!;
    target.insert((index ?? target.length).clamp(0, target.length), id);
    return ShortcutLayout._(
      List.unmodifiable(lists[ShortcutSide.left]!),
      List.unmodifiable(lists[ShortcutSide.right]!),
      List.unmodifiable(lists[ShortcutSide.more]!),
    );
  }

  List<String> encode() => [
    for (final id in left) 'L:$id',
    for (final id in right) 'R:$id',
    for (final id in more) '!$id',
  ];
}

/// What to store as the shortcut layout before the 228 toolbar layout is
/// rewritten (사용자 지정 도구 모음 keeps only the tools): while [stored] is
/// empty the bar still follows [legacyToolbar]'s page-action switches. Null
/// when those switches change nothing.
List<String>? keptShortcutLayout(
  List<String> stored,
  List<String> legacyToolbar,
) {
  if (stored.isNotEmpty) return null;
  final kept = ShortcutLayout.decode(
    noteShortcutItems,
    stored,
    legacyToolbar: legacyToolbar,
  ).encode();
  final defaults = ShortcutLayout.decode(noteShortcutItems, const []).encode();
  return kept.join('\n') == defaults.join('\n') ? null : kept;
}
