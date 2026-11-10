import 'dart:async';

import 'package:flutter/material.dart';
import 'package:saber/data/vault/workspace_bookmarks.dart';
import 'package:saber/pages/workspace/markdown_editor.dart';

Future<void> showWorkspaceBookmarkSheet(
  BuildContext context, {
  required Future<List<WorkspaceBookmark>> Function() load,
  required List<WorkspaceBookmarkSpec> currentTargets,
  required String Function(WorkspaceBookmarkSpec) label,
  required Future<void> Function(WorkspaceBookmarkSpec) add,
  required Future<void> Function(WorkspaceBookmark, WorkspaceBookmarkSpec)
  update,
  required Future<void> Function(WorkspaceBookmark) remove,
  required Future<void> Function(WorkspaceBookmark) resolve,
  required ValueChanged<WorkspaceBookmarkSpec> open,
  Future<WorkspaceBookmarkSpec?> Function(BuildContext)? chooseMarkdownLocation,
  Stream<void>? changes,
}) async {
  final selected = await showModalBottomSheet<WorkspaceBookmarkSpec>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    constraints: const BoxConstraints(maxWidth: 720),
    builder: (context) => FractionallySizedBox(
      heightFactor: .88,
      child: _BookmarkSheet(
        load: load,
        currentTargets: currentTargets,
        label: label,
        add: add,
        update: update,
        remove: remove,
        resolve: resolve,
        chooseMarkdownLocation: chooseMarkdownLocation,
        changes: changes,
      ),
    ),
  );
  if (selected != null && context.mounted) open(selected);
}

Future<String?> showMarkdownBookmarkAnchorChooser(
  BuildContext context, {
  required String source,
  required MarkdownAnchorResolver resolveAnchor,
}) {
  final locations = MarkdownBookmarkLocations.parse(source);
  return showDialog<String>(
    context: context,
    builder: (context) => _MarkdownLocationDialog(
      locations: locations,
      resolveAnchor: resolveAnchor,
    ),
  );
}

class _MarkdownLocationDialog extends StatefulWidget {
  const new({required this.locations, required this.resolveAnchor});

  final MarkdownBookmarkLocations locations;
  final MarkdownAnchorResolver resolveAnchor;

  @override
  State<_MarkdownLocationDialog> createState() =>
      _MarkdownLocationDialogState();
}

class _MarkdownLocationDialogState extends State<_MarkdownLocationDialog> {
  var _unavailable = false;

  void _choose(MarkdownBookmarkLocation item) {
    String? fragment;
    try {
      fragment = widget.locations.resolve(item, widget.resolveAnchor);
    } catch (_) {
      // An invalid or unavailable resolver result cannot become a bookmark.
    }
    if (fragment == null) {
      setState(() => _unavailable = true);
      return;
    }
    Navigator.pop(context, fragment);
  }

  @override
  Widget build(BuildContext context) {
    final items = widget.locations.items;
    return AlertDialog(
      title: const Text('제목 또는 블록 선택'),
      content: items.isEmpty
          ? const Text('이 문서에는 선택할 수 있는 제목이나 블록 ID가 없습니다.')
          : SizedBox(
              width: 440,
              height: MediaQuery.sizeOf(context).height * .48,
              child: Column(
                children: [
                  if (_unavailable)
                    const Text('이 위치를 정확히 구분할 수 없습니다. 다른 제목이나 블록을 선택하세요.'),
                  Expanded(
                    child: ListView.builder(
                      itemCount: items.length,
                      itemBuilder: (context, index) {
                        final item = items[index];
                        return ListTile(
                          key: ValueKey(
                            'workspace-bookmark-markdown-anchor-${item.index}',
                          ),
                          leading: Icon(
                            item.isBlock
                                ? Icons.link
                                : Icons.description_outlined,
                          ),
                          title: Text(
                            item.label,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: item.subtitle == null
                              ? null
                              : Text(
                                  item.subtitle!,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                          onTap: () => _choose(item),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('취소'),
        ),
      ],
    );
  }
}

enum _BookmarkAction { edit, remove, resolve }

typedef _BookmarkRow = ({WorkspaceBookmark item, int depth});

class _BookmarkSheet extends StatefulWidget {
  const new({
    required this.load,
    required this.currentTargets,
    required this.label,
    required this.add,
    required this.update,
    required this.remove,
    required this.resolve,
    required this.chooseMarkdownLocation,
    required this.changes,
  });

  final Future<List<WorkspaceBookmark>> Function() load;
  final List<WorkspaceBookmarkSpec> currentTargets;
  final String Function(WorkspaceBookmarkSpec) label;
  final Future<void> Function(WorkspaceBookmarkSpec) add;
  final Future<void> Function(WorkspaceBookmark, WorkspaceBookmarkSpec) update;
  final Future<void> Function(WorkspaceBookmark) remove, resolve;
  final Future<WorkspaceBookmarkSpec?> Function(BuildContext)?
  chooseMarkdownLocation;
  final Stream<void>? changes;

  @override
  State<_BookmarkSheet> createState() => _BookmarkSheetState();
}

class _BookmarkSheetState extends State<_BookmarkSheet> {
  final _collapsed = <String>{};
  StreamSubscription<void>? _subscription;
  Timer? _reloadTimer;
  late Future<List<WorkspaceBookmark>> _items;
  var _saving = false;
  var _failed = false;

  @override
  void initState() {
    super.initState();
    _items = Future.sync(widget.load);
    _subscription = widget.changes?.listen((_) {
      _reloadTimer?.cancel();
      _reloadTimer = Timer(const Duration(milliseconds: 80), _reload);
    });
  }

  @override
  void dispose() {
    _reloadTimer?.cancel();
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  void _reload() {
    if (mounted && !_saving) {
      setState(() {
        _items = Future.sync(widget.load);
      });
    }
  }

  Future<void> _write(Future<void> Function() write) async {
    if (!mounted || _saving) return;
    setState(() {
      _saving = true;
      _failed = false;
    });
    try {
      await write();
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) {
        setState(() => _saving = false);
        _reload();
      }
    }
  }

  List<_BookmarkRow> _rows(
    List<WorkspaceBookmark> items,
    List<WorkspaceBookmark> groups,
  ) {
    final parents = {for (final group in groups) group.id: group.spec.groupId};
    final children = <String?, List<WorkspaceBookmark>>{};
    for (final item in items) {
      final groupId = item.spec.groupId;
      String? parent = groupId != null && parents.containsKey(groupId)
          ? groupId
          : null;
      final seen = {item.id};
      for (
        var ancestor = parent;
        ancestor != null;
        ancestor = parents[ancestor]
      ) {
        if (!seen.add(ancestor)) {
          parent = null;
          break;
        }
      }
      (children[parent] ??= []).add(item);
    }
    final rows = <_BookmarkRow>[];
    final pending = <_BookmarkRow>[
      for (final item
          in (children[null] ?? const <WorkspaceBookmark>[]).reversed)
        (item: item, depth: 0),
    ];
    while (pending.isNotEmpty) {
      final row = pending.removeLast();
      rows.add(row);
      final id = row.item.id;
      if (row.item.spec.kind == .group && !_collapsed.contains(id)) {
        for (final item
            in (children[id] ?? const <WorkspaceBookmark>[]).reversed) {
          pending.add((item: item, depth: row.depth + 1));
        }
      }
    }
    return rows;
  }

  Future<void> _addCurrent(List<WorkspaceBookmark> groups) async {
    final target = await showDialog<WorkspaceBookmarkSpec>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('북마크할 대상'),
        children: [
          for (final (index, spec) in widget.currentTargets.indexed)
            SimpleDialogOption(
              key: ValueKey('workspace-bookmark-target-$index'),
              onPressed: () => Navigator.pop(context, spec),
              child: Text(
                widget.label(spec),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ),
    );
    if (target != null && mounted) await _edit(target, groups);
  }

  Future<void> _addMarkdown(List<WorkspaceBookmark> groups) async {
    try {
      final target = await widget.chooseMarkdownLocation!(context);
      if (target != null && mounted) await _edit(target, groups);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  Future<void> _edit(
    WorkspaceBookmarkSpec spec,
    List<WorkspaceBookmark> groups, {
    WorkspaceBookmark? existing,
  }) async {
    final edited = await showDialog<WorkspaceBookmarkSpec>(
      context: context,
      builder: (context) => _BookmarkEditDialog(
        initial: spec,
        groups: groups,
        isExisting: existing != null,
        label: widget.label,
      ),
    );
    if (edited == null || !mounted) return;
    await _write(
      () => existing == null
          ? widget.add(edited)
          : widget.update(existing, edited),
    );
  }

  Future<void> _confirm(WorkspaceBookmark item, {required bool resolve}) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(resolve ? '이 북마크 버전을 유지할까요?' : '북마크를 삭제할까요?'),
        content: Text(
          resolve
              ? '다른 기기에서 변경한 내용과 충돌했습니다. 선택한 버전을 현재 버전으로 저장합니다.'
              : item.spec.kind == .group
              ? '그룹 안의 북마크는 목록에 남습니다.'
              : widget.label(item.spec),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          FilledButton(
            key: ValueKey(
              resolve
                  ? 'workspace-bookmark-resolve-confirm'
                  : 'workspace-bookmark-delete-confirm',
            ),
            onPressed: () => Navigator.pop(context, true),
            child: Text(resolve ? '이 버전 유지' : '삭제'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await _write(() => resolve ? widget.resolve(item) : widget.remove(item));
    }
  }

  Widget _tile(
    _BookmarkRow row,
    List<WorkspaceBookmark> groups,
    bool canWrite,
  ) {
    final item = row.item;
    final spec = item.spec;
    final suffix = '${item.id}-${item.revisionId}';
    final isGroup = spec.kind == .group;
    final collapsed = _collapsed.contains(item.id);
    return Padding(
      padding: EdgeInsets.only(left: row.depth.clamp(0, 5).toDouble() * 12),
      child: ListTile(
        key: ValueKey(
          isGroup
              ? 'workspace-bookmark-group-$suffix'
              : 'workspace-bookmark-open-$suffix',
        ),
        leading: Icon(switch (spec.kind) {
          .group => collapsed ? Icons.chevron_right : Icons.expand_more,
          .note => Icons.description_outlined,
          .folder => Icons.folder_outlined,
          .search => Icons.search,
          .url => Icons.link,
        }),
        title: Text(
          widget.label(spec),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: item.conflicted ? const Text('동기화 충돌') : null,
        onTap: isGroup
            ? item.conflicted
                  ? null
                  : () => setState(() {
                      if (collapsed) {
                        _collapsed.remove(item.id);
                      } else {
                        _collapsed.add(item.id);
                      }
                    })
            : () => Navigator.pop(context, spec),
        trailing: PopupMenuButton<_BookmarkAction>(
          key: ValueKey('workspace-bookmark-menu-$suffix'),
          enabled: canWrite,
          tooltip: '북마크 관리',
          onSelected: (action) => unawaited(switch (action) {
            .edit => _edit(spec, groups, existing: item),
            .remove => _confirm(item, resolve: false),
            .resolve => _confirm(item, resolve: true),
          }),
          itemBuilder: (context) => item.conflicted
              ? const [PopupMenuItem(value: .resolve, child: Text('이 버전 유지'))]
              : [
                  PopupMenuItem(
                    value: .edit,
                    child: Text(isGroup ? '그룹 이름 변경' : '이름·그룹 변경'),
                  ),
                  const PopupMenuItem(value: .remove, child: Text('삭제')),
                ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Column(
    key: const ValueKey('workspace-bookmark-sheet'),
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.only(left: 20, top: 8, right: 8),
        child: Row(
          children: [
            Expanded(
              child: Text('북마크', style: Theme.of(context).textTheme.titleLarge),
            ),
            IconButton(
              onPressed: () => Navigator.pop(context),
              tooltip: '닫기',
              icon: const Icon(Icons.close),
            ),
          ],
        ),
      ),
      if (_failed)
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 20),
          child: Text('북마크를 변경하지 못했습니다. 최신 목록을 확인하고 다시 시도하세요.'),
        ),
      Expanded(
        child: FutureBuilder<List<WorkspaceBookmark>>(
          future: _items,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Center(
                child: TextButton(
                  onPressed: _reload,
                  child: const Text('북마크를 다시 불러오기'),
                ),
              );
            }
            final items = snapshot.data;
            if (items == null)
              return const Center(child: CircularProgressIndicator());
            final groups = [
              for (final item in items)
                if (item.spec.kind == .group && !item.conflicted) item,
            ];
            final rows = _rows(items, groups);
            final canWrite =
                !_saving && snapshot.connectionState == ConnectionState.done;
            return ListView.builder(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
              itemCount: rows.isEmpty ? 2 : rows.length + 1,
              itemBuilder: (context, index) {
                if (index == 0) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Wrap(
                      spacing: 4,
                      children: [
                        if (widget.currentTargets.isNotEmpty)
                          TextButton.icon(
                            key: const ValueKey(
                              'workspace-bookmark-add-current',
                            ),
                            onPressed: canWrite
                                ? () => _addCurrent(groups)
                                : null,
                            icon: const Icon(Icons.add),
                            label: const Text('북마크 추가'),
                          ),
                        if (widget.chooseMarkdownLocation != null)
                          TextButton.icon(
                            key: const ValueKey(
                              'workspace-bookmark-add-markdown-location',
                            ),
                            onPressed: canWrite
                                ? () => _addMarkdown(groups)
                                : null,
                            icon: const Icon(Icons.link),
                            label: const Text('Markdown 위치 추가'),
                          ),
                        TextButton.icon(
                          key: const ValueKey('workspace-bookmark-add-group'),
                          onPressed: canWrite
                              ? () => _edit(
                                  const WorkspaceBookmarkSpec(kind: .group),
                                  groups,
                                )
                              : null,
                          icon: const Icon(Icons.create_new_folder_outlined),
                          label: const Text('새 그룹'),
                        ),
                      ],
                    ),
                  );
                }
                if (rows.isEmpty) {
                  return const Padding(
                    padding: EdgeInsets.all(20),
                    child: Text('저장한 북마크가 없습니다.'),
                  );
                }
                return _tile(rows[index - 1], groups, canWrite);
              },
            );
          },
        ),
      ),
    ],
  );
}

class _BookmarkEditDialog extends StatefulWidget {
  const new({
    required this.initial,
    required this.groups,
    required this.isExisting,
    required this.label,
  });

  final WorkspaceBookmarkSpec initial;
  final List<WorkspaceBookmark> groups;
  final bool isExisting;
  final String Function(WorkspaceBookmarkSpec) label;

  @override
  State<_BookmarkEditDialog> createState() => _BookmarkEditDialogState();
}

class _BookmarkEditDialogState extends State<_BookmarkEditDialog> {
  final _form = GlobalKey<FormState>();
  late final _title = TextEditingController(text: widget.initial.title);
  late String? _group =
      widget.groups.any((item) => item.id == widget.initial.groupId)
      ? widget.initial.groupId
      : null;

  bool get _isGroup => widget.initial.kind == .group;
  bool get _canMove => !_isGroup || !widget.isExisting;

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  void _save() {
    if (!_form.currentState!.validate()) return;
    final title = _title.text.trim();
    Navigator.pop(
      context,
      WorkspaceBookmarkSpec(
        kind: widget.initial.kind,
        title: title.isEmpty ? null : title,
        groupId: _canMove ? _group : widget.initial.groupId,
        target: widget.initial.target,
        pdfPageNumber: widget.initial.pdfPageNumber,
        literalSearch: widget.initial.literalSearch,
        expressionSearch: widget.initial.expressionSearch,
        order: widget.initial.order,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: Text(_isGroup ? '북마크 그룹' : '북마크'),
    content: SizedBox(
      width: 420,
      child: Form(
        key: _form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              key: const ValueKey('workspace-bookmark-title'),
              controller: _title,
              maxLength: 256,
              decoration: InputDecoration(
                labelText: _isGroup ? '그룹 이름' : '북마크 이름 (선택)',
                hintText: _isGroup ? null : widget.label(widget.initial),
              ),
              validator: (value) => _isGroup && (value ?? '').trim().isEmpty
                  ? '그룹 이름을 입력하세요.'
                  : null,
            ),
            if (_canMove && widget.groups.isNotEmpty)
              DropdownButtonFormField<String>(
                key: const ValueKey('workspace-bookmark-group-picker'),
                initialValue: _group ?? '',
                isExpanded: true,
                decoration: const InputDecoration(labelText: '그룹'),
                items: [
                  const DropdownMenuItem(value: '', child: Text('그룹 없음')),
                  for (final group in widget.groups)
                    DropdownMenuItem(
                      value: group.id,
                      child: Text(
                        widget.label(group.spec),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (value) => _group = value == '' ? null : value,
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('취소'),
      ),
      FilledButton(
        key: const ValueKey('workspace-bookmark-confirm'),
        onPressed: _save,
        child: const Text('저장'),
      ),
    ],
  );
}
