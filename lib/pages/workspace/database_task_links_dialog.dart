import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter/material.dart';
import 'package:saber/data/vault/database_actions.dart';
import 'package:saber/data/vault/workspace_database.dart';

typedef DatabaseTaskLinkChoice = ({String id, String title, bool archived});

class DatabaseTaskLinksDialog extends StatefulWidget {
  const new({
    super.key,
    required this.title,
    required this.choices,
    required this.parentId,
    required this.predecessorIds,
    required this.onApply,
  });

  final String title;
  final List<DatabaseTaskLinkChoice> choices;
  final String? parentId;
  final List<String> predecessorIds;
  final WorkspaceDatabase Function(String?, List<String>) onApply;

  @override
  State<DatabaseTaskLinksDialog> createState() =>
      _DatabaseTaskLinksDialogState();
}

class _DatabaseTaskLinksDialogState extends State<DatabaseTaskLinksDialog> {
  late String? _parentId = widget.parentId;
  late final _initialPredecessors = widget.predecessorIds.toSet();
  late final _predecessors = _initialPredecessors.toSet();
  var _editingPredecessors = false;
  var _search = '';
  String? _error;

  bool get _changed =>
      _parentId != widget.parentId ||
      !setEquals(_predecessors, _initialPredecessors);

  void _apply() {
    try {
      final database = widget.onApply(_parentId, _predecessors.toList());
      Navigator.of(context).pop(database);
    } on DatabaseActionException catch (error) {
      setState(() => _error = databaseTaskLinkError(error));
    } on FormatException catch (_) {
      setState(() => _error = '작업 연결의 내용을 확인해 주세요.');
    } on StateError catch (error) {
      setState(() => _error = error.message);
    }
  }

  void _selectParent(String? id) => setState(() {
    _parentId = id;
    _error = null;
  });

  @override
  Widget build(BuildContext context) {
    final choices = [
      for (final choice in widget.choices)
        if (choice.title.toLowerCase().contains(_search) &&
            (!choice.archived ||
                (_editingPredecessors
                    ? _predecessors.contains(choice.id)
                    : _parentId == choice.id)))
          choice,
    ];
    return AlertDialog(
      title: Text('작업 연결 · ${widget.title}', maxLines: 2),
      content: SizedBox(
        width: 480,
        height: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 8,
              children: [
                ChoiceChip(
                  label: const Text('상위 작업'),
                  selected: !_editingPredecessors,
                  onSelected: (_) =>
                      setState(() => _editingPredecessors = false),
                ),
                ChoiceChip(
                  label: Text('선행 작업 ${_predecessors.length}'),
                  selected: _editingPredecessors,
                  onSelected: (_) =>
                      setState(() => _editingPredecessors = true),
                ),
              ],
            ),
            TextField(
              key: const ValueKey('db-task-search'),
              decoration: const InputDecoration(labelText: '작업 이름으로 검색'),
              onChanged: (value) =>
                  setState(() => _search = value.trim().toLowerCase()),
            ),
            if (_editingPredecessors && _predecessors.isNotEmpty)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () => setState(() {
                    _predecessors.clear();
                    _error = null;
                  }),
                  child: const Text('선행 작업 모두 해제'),
                ),
              ),
            Expanded(
              child: ListView.builder(
                key: ValueKey(_editingPredecessors),
                itemCount: choices.length + (_editingPredecessors ? 0 : 1),
                itemBuilder: (_, index) {
                  if (!_editingPredecessors && index == 0) {
                    return ListTile(
                      key: const ValueKey('db-task-parent-none'),
                      title: const Text('상위 작업 없음'),
                      selected: _parentId == null,
                      onTap: () => _selectParent(null),
                    );
                  }
                  final choice =
                      choices[index - (_editingPredecessors ? 0 : 1)];
                  final label = choice.archived
                      ? '${choice.title} · 보관됨'
                      : choice.title;
                  if (_editingPredecessors) {
                    return CheckboxListTile(
                      key: ValueKey('db-task-predecessor-${choice.id}'),
                      title: Text(
                        label,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      value: _predecessors.contains(choice.id),
                      onChanged: (checked) => setState(() {
                        if (checked == true) {
                          _predecessors.add(choice.id);
                        } else {
                          _predecessors.remove(choice.id);
                        }
                        _error = null;
                      }),
                    );
                  }
                  return ListTile(
                    key: ValueKey('db-task-parent-${choice.id}'),
                    title: Text(
                      label,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    selected: _parentId == choice.id,
                    onTap: choice.archived
                        ? null
                        : () => _selectParent(choice.id),
                  );
                },
              ),
            ),
            if (_error case final error?)
              Text(
                error,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        FilledButton(
          key: const ValueKey('db-task-links-save'),
          onPressed: _changed ? _apply : null,
          child: const Text('적용'),
        ),
      ],
    );
  }
}

String databaseTaskLinkError(DatabaseActionException error) =>
    switch (error.code) {
      'task_link_cycle' => '작업 연결이 순환합니다. 상위 작업과 선행 작업을 확인하세요.',
      'missing_task' || 'archived_task' => '연결할 작업이 삭제되었거나 보관되었습니다.',
      'self_task_link' => '자기 자신에게 작업을 연결할 수 없습니다.',
      'duplicate_task_link' => '같은 선행 작업을 여러 번 연결할 수 없습니다.',
      'task_links_limit' => '연결할 수 있는 작업 수를 넘었습니다.',
      _ => '작업 연결을 적용하지 못했습니다.',
    };
