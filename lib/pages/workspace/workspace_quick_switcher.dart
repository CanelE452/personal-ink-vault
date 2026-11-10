import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class WorkspaceQuickSwitchEntry {
  const new({
    required this.id,
    required this.title,
    required this.path,
    this.icon,
  });

  final String id;
  final String title;
  final String path;
  final IconData? icon;
}

Future<String?> showWorkspaceQuickSwitcher(
  BuildContext context, {
  required List<WorkspaceQuickSwitchEntry> entries,
  required List<String> recentIds,
  String? activeId,
}) => showDialog<String>(
  context: context,
  builder: (context) => _WorkspaceQuickSwitcher(
    entries: entries,
    recentIds: recentIds,
    activeId: activeId,
  ),
);

final _spaces = RegExp(r'\s+');

int _quality(String field, String query, List<int> fuzzy) {
  if (field == query) return 4;
  if (field.startsWith(query)) return 3;
  if (field.contains(query)) return 2;
  if (fuzzy.isEmpty) return 0;
  var index = 0;
  for (final unit in field.codeUnits) {
    if (unit != fuzzy[index]) continue;
    index++;
    if (index == fuzzy.length) return 1;
  }
  return 0;
}

List<WorkspaceQuickSwitchEntry> _rank(
  Map<String, WorkspaceQuickSwitchEntry> entries,
  List<String> recentIds,
  String query,
) {
  if (query.isEmpty) {
    return [for (final id in recentIds.toSet()) ?entries[id]].take(10).toList();
  }

  final fuzzy = query.replaceAll(_spaces, '').codeUnits;
  final matches =
      <
        ({
          WorkspaceQuickSwitchEntry entry,
          String title,
          String path,
          int score,
        })
      >[];
  for (final entry in entries.values) {
    final title = entry.title.toLowerCase();
    final path = entry.path.toLowerCase();
    final titleQuality = _quality(title, query, fuzzy);
    final titleScore = titleQuality == 0 ? 0 : titleQuality * 2 + 1;
    final pathScore = _quality(path, query, fuzzy) * 2;
    final score = titleScore > pathScore ? titleScore : pathScore;
    if (score > 0) {
      matches.add((entry: entry, title: title, path: path, score: score));
    }
  }
  matches.sort((a, b) {
    final score = b.score.compareTo(a.score);
    if (score != 0) return score;
    final title = a.title.compareTo(b.title);
    if (title != 0) return title;
    final path = a.path.compareTo(b.path);
    if (path != 0) return path;
    return a.entry.id.compareTo(b.entry.id);
  });
  return [for (final match in matches.take(50)) match.entry];
}

class _WorkspaceQuickSwitcher extends StatefulWidget {
  const new({
    required this.entries,
    required this.recentIds,
    required this.activeId,
  });

  final List<WorkspaceQuickSwitchEntry> entries;
  final List<String> recentIds;
  final String? activeId;

  @override
  State<_WorkspaceQuickSwitcher> createState() =>
      _WorkspaceQuickSwitcherState();
}

class _WorkspaceQuickSwitcherState extends State<_WorkspaceQuickSwitcher> {
  final _query = TextEditingController();
  final _searchFocus = FocusNode();
  final _scroll = ScrollController();
  final _selectedTile = GlobalKey();
  late final _entries = {for (final entry in widget.entries) entry.id: entry};
  late var _results = _rank(_entries, widget.recentIds, '');
  var _selected = 0;
  var _searching = false;

  bool get _isComposing {
    final composing = _query.value.composing;
    return composing.isValid && !composing.isCollapsed;
  }

  void _edit(String value) {
    final query = value.trim().toLowerCase();
    setState(() {
      _results = _rank(_entries, widget.recentIds, query);
      _searching = query.isNotEmpty;
      _selected = 0;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  void _close([String? id]) {
    if (ModalRoute.of(context)?.isCurrent == true) {
      Navigator.pop(context, id);
    }
  }

  void _submit() {
    if (!_isComposing && _results.isNotEmpty) {
      _close(_results[_selected].id);
    }
  }

  void _move(int delta) {
    if (_results.isEmpty) return;
    setState(() => _selected = (_selected + delta) % _results.length);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final selectedContext = _selectedTile.currentContext;
      if (selectedContext != null) {
        for (final policy in const [
          ScrollPositionAlignmentPolicy.keepVisibleAtStart,
          ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
        ]) {
          unawaited(
            Scrollable.ensureVisible(selectedContext, alignmentPolicy: policy),
          );
        }
      }
    });
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (_isComposing || (event is! KeyDownEvent && event is! KeyRepeatEvent)) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape && event is KeyDownEvent) {
      _close();
      return KeyEventResult.handled;
    }
    if (!_searchFocus.hasFocus) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.arrowUp) {
      _move(key == LogicalKeyboardKey.arrowDown ? 1 : -1);
      return KeyEventResult.handled;
    }
    if ((key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.numpadEnter) &&
        event is KeyDownEvent) {
      _submit();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  void dispose() {
    _query.dispose();
    _searchFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Dialog(
    insetPadding: const EdgeInsets.all(16),
    child: SizedBox(
      width: 480,
      height: 460,
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: _onKeyEvent,
        child: LayoutBuilder(
          builder: (context, constraints) {
            const minimumHeight = 216.0;
            if (constraints.maxHeight >= minimumHeight) return _body(context);
            return SingleChildScrollView(
              child: SizedBox(height: minimumHeight, child: _body(context)),
            );
          },
        ),
      ),
    ),
  );

  Widget _body(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '빠른 문서 전환',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            IconButton(
              onPressed: _close,
              icon: const Icon(Icons.close),
              tooltip: '닫기',
            ),
          ],
        ),
        TextField(
          key: const ValueKey('workspace-quick-switch-query'),
          autofocus: true,
          controller: _query,
          focusNode: _searchFocus,
          maxLength: 160,
          textInputAction: TextInputAction.go,
          decoration: const InputDecoration(
            labelText: '제목 또는 경로',
            prefixIcon: Icon(Icons.search),
            counterText: '',
            border: OutlineInputBorder(),
          ),
          onChanged: _edit,
          onSubmitted: (_) => _submit(),
        ),
        const SizedBox(height: 12),
        Text(
          _searching ? '검색 결과' : '최근 문서',
          style: Theme.of(context).textTheme.labelLarge,
        ),
        const SizedBox(height: 4),
        Expanded(child: _resultList()),
      ],
    ),
  );

  Widget _resultList() {
    if (_results.isEmpty) {
      return Center(
        child: Semantics(
          liveRegion: true,
          child: Text(_searching ? '일치하는 문서가 없습니다.' : '최근 문서가 없습니다.'),
        ),
      );
    }
    final colors = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      controller: _scroll,
      child: Column(
        children: [
          for (var index = 0; index < _results.length; index++)
            _resultTile(_results[index], index == _selected, colors),
        ],
      ),
    );
  }

  Widget _resultTile(
    WorkspaceQuickSwitchEntry entry,
    bool selected,
    ColorScheme colors,
  ) {
    final tile = ListTile(
      key: ValueKey('workspace-quick-switch-result-${entry.id}'),
      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      selected: selected,
      selectedTileColor: colors.secondaryContainer,
      selectedColor: colors.onSecondaryContainer,
      leading: Icon(entry.icon ?? Icons.description_outlined, size: 20),
      title: Text(entry.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(entry.path, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: entry.id == widget.activeId ? const Text('현재') : null,
      onTap: () => _close(entry.id),
    );
    return selected ? KeyedSubtree(key: _selectedTile, child: tile) : tile;
  }
}
