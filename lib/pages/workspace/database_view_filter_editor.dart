import 'package:flutter/material.dart';
import 'package:saber/data/vault/workspace_database.dart';

typedef DatabaseViewFilterDraft = ({Map<String, dynamic>? filter, bool valid});

class DatabaseViewFilterEditor extends StatefulWidget {
  const new({
    required this.database,
    required this.filter,
    required this.onChanged,
    super.key,
  });

  final WorkspaceDatabase database;
  final Map<String, dynamic>? filter;
  final ValueChanged<DatabaseViewFilterDraft> onChanged;

  @override
  State<DatabaseViewFilterEditor> createState() =>
      _DatabaseViewFilterEditorState();
}

const _maxDepth = 16;
const _maxNodes = 128;
const _operators = {
  'equals': '같음',
  'notEquals': '같지 않음',
  'contains': '포함',
  'notContains': '포함 안 함',
  'gt': '보다 큼',
  'gte': '이상',
  'lt': '보다 작음',
  'lte': '이하',
  'isEmpty': '비어 있음',
  'isNotEmpty': '비어 있지 않음',
  'startsWith': '다음으로 시작',
  'endsWith': '다음으로 끝남',
  'after': '이후',
  'onOrAfter': '같거나 이후',
  'before': '이전',
  'onOrBefore': '같거나 이전',
};
const _withoutValue = {'isEmpty', 'isNotEmpty'};
const _stringOperators = {'contains', 'notContains', 'startsWith', 'endsWith'};

sealed class _FilterNode {
  new(this.id);

  final int id;
}

final class _FilterGroup extends _FilterNode {
  new(super.id, this.operator, this.children, {this.keptEmpty = false});

  String operator;
  final List<_FilterNode> children;
  bool keptEmpty;
}

final class _FilterCondition extends _FilterNode {
  new(
    super.id, {
    this.original,
    this.propertyId,
    this.operator = 'equals',
    this.text = '',
  });

  final Map<String, dynamic>? original;
  String? propertyId;
  String operator;
  String text;
  var edited = false;
}

final class _StoredFilter extends _FilterNode {
  new(super.id, this.raw);

  final Map<String, dynamic> raw;
}

class _DatabaseViewFilterEditorState extends State<DatabaseViewFilterEditor> {
  late _FilterNode _root;
  var _nextId = 0;
  var _atImportLimit = false;

  @override
  void initState() {
    super.initState();
    final raw = widget.filter;
    if (raw == null) {
      _root = _newCondition();
      return;
    }
    try {
      _root = _decode(raw, 0);
    } on FormatException {
      _root = _StoredFilter(_nextId++, raw);
      _atImportLimit = true;
    }
  }

  DatabaseProperty? _property(String? id) => widget.database.properties
      .where((property) => property.id == id)
      .firstOrNull;

  DatabaseProperty? _resolveProperty(String reference) =>
      _property(reference) ??
      widget.database.properties
          .where((property) => property.name == reference)
          .singleOrNull;

  _FilterCondition _newCondition() => _FilterCondition(_nextId++);

  _FilterNode _decode(Map<String, dynamic> raw, int depth) {
    if (depth > _maxDepth || _nextId >= _maxNodes) {
      throw const FormatException('Filter draft exceeds the editor limit');
    }
    final id = _nextId++;
    if (raw.containsKey('and') || raw.containsKey('or')) {
      if (raw.length != 1) return _StoredFilter(id, raw);
      final operator = raw.keys.single;
      final nodes = raw[operator];
      if (nodes is! List ||
          nodes.any((node) => node is! Map<String, dynamic>)) {
        return _StoredFilter(id, raw);
      }
      return _FilterGroup(id, operator, [
        for (final node in nodes)
          _decode(node as Map<String, dynamic>, depth + 1),
      ], keptEmpty: nodes.isEmpty);
    }
    final reference = raw['propertyId'] ?? raw['property'];
    final property = reference is String ? _resolveProperty(reference) : null;
    final operator = raw['operator'] ?? raw['op'];
    final value = raw['value'];
    if (property == null ||
        operator is! String ||
        !_operators.containsKey(operator) ||
        (!_withoutValue.contains(operator) &&
            value != null &&
            value is! String &&
            value is! num &&
            value is! bool)) {
      return _StoredFilter(id, raw);
    }
    return _FilterCondition(
      id,
      original: raw,
      propertyId: property.id,
      operator: operator,
      text: value?.toString() ?? '',
    );
  }

  Object _comparison(_FilterCondition leaf) {
    final type = _property(leaf.propertyId)?.type;
    if (type == 'number') {
      final value = num.tryParse(leaf.text);
      if (value == null || !value.isFinite) {
        throw const FormatException('유한한 숫자를 입력하세요.');
      }
      return value;
    }
    if (type == 'checkbox') {
      if (leaf.text == 'true') return true;
      if (leaf.text == 'false') return false;
      throw const FormatException('true 또는 false를 입력하세요.');
    }
    if (type == 'date' && !_stringOperators.contains(leaf.operator)) {
      try {
        parseDatabaseDate(leaf.text);
      } on FormatException {
        throw const FormatException('날짜를 YYYY-MM-DD 형식으로 입력하세요.');
      }
    }
    return leaf.text;
  }

  Map<String, dynamic>? _encode(_FilterNode node, {bool root = false}) {
    switch (node) {
      case _StoredFilter(:final raw):
        return raw;
      case _FilterGroup(:final operator, :final children, :final keptEmpty):
        if (children.isEmpty && !keptEmpty) {
          throw const FormatException('그룹에 조건을 추가하세요.');
        }
        return {
          operator: [for (final child in children) _encode(child)],
        };
      case _FilterCondition(:final original, :final propertyId):
        if (!node.edited && original != null) return original;
        if (propertyId == null) {
          if (root) return null;
          throw const FormatException('필터 속성을 선택하세요.');
        }
        final propertyKey =
            original?['propertyId'] == null && original?['property'] != null
            ? 'property'
            : 'propertyId';
        final operatorKey =
            original?['operator'] == null && original?['op'] != null
            ? 'op'
            : 'operator';
        final oldReference = original?[propertyKey];
        final result = {
          ...?original,
          propertyKey:
              oldReference is String &&
                  _resolveProperty(oldReference)?.id == propertyId
              ? oldReference
              : propertyId,
          operatorKey: node.operator,
        };
        if (_withoutValue.contains(node.operator)) {
          result.remove('value');
        } else {
          result['value'] = _comparison(node);
        }
        return result;
    }
  }

  int _count(_FilterNode node) => switch (node) {
    _FilterGroup(:final children) =>
      1 + children.fold<int>(0, (count, child) => count + _count(child)),
    _ => 1,
  };

  void _change(VoidCallback mutate) {
    setState(mutate);
    DatabaseViewFilterDraft draft;
    try {
      draft = (filter: _encode(_root, root: true), valid: true);
    } on FormatException {
      draft = (filter: null, valid: false);
    }
    widget.onChanged(draft);
  }

  void _add(_FilterNode node, {required bool group}) {
    _change(() {
      final id = group ? _nextId++ : null;
      final condition = _newCondition();
      final added = id == null
          ? condition
          : _FilterGroup(id, 'and', [condition]);
      if (node is _FilterGroup) {
        node.children.add(added);
        node.keptEmpty = false;
      } else {
        _root = _FilterGroup(_nextId++, 'and', [node, added]);
      }
    });
  }

  void _clear() => _change(() {
    _root = _newCondition();
    _atImportLimit = false;
  });

  @override
  Widget build(BuildContext context) {
    final remaining = _maxNodes - _count(_root);
    final empty = switch (_root) {
      _FilterCondition(propertyId: null) => true,
      _ => false,
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _node(_root, remaining, depth: 0),
        if (_root is! _FilterGroup) _actions(_root, remaining, depth: 0),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            key: const ValueKey('database-view-filter-clear'),
            onPressed: empty ? null : _clear,
            child: const Text('필터 모두 지우기'),
          ),
        ),
      ],
    );
  }

  Widget _node(_FilterNode node, int remaining, {required int depth}) {
    final root = depth == 0;
    return KeyedSubtree(
      key: ValueKey(node.id),
      child: switch (node) {
        _FilterCondition() => _condition(node, root: root),
        _StoredFilter() => Text(
          _atImportLimit
              ? '저장된 필터가 편집 한도를 넘었습니다.'
              : '저장된 조건을 이 화면에서 편집할 수 없습니다.',
        ),
        _FilterGroup() => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButtonFormField<String>(
              key: ValueKey(
                'database-view-filter-group-mode-${root ? 'root' : node.id}',
              ),
              initialValue: node.operator,
              isExpanded: true,
              decoration: const InputDecoration(labelText: '조건 그룹'),
              items: const [
                DropdownMenuItem(value: 'and', child: Text('모두 일치 (AND)')),
                DropdownMenuItem(value: 'or', child: Text('하나 이상 일치 (OR)')),
              ],
              onChanged: (operator) {
                if (operator == null || operator == node.operator) return;
                _change(() {
                  node.operator = operator;
                  node.keptEmpty = false;
                });
              },
            ),
            Padding(
              padding: EdgeInsets.only(left: depth < 3 ? 8 : 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final child in node.children)
                    KeyedSubtree(
                      key: ValueKey(child.id),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const SizedBox(height: 8),
                          _node(child, remaining, depth: depth + 1),
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton(
                              key: ValueKey(
                                'database-view-filter-remove-${child.id}',
                              ),
                              onPressed: () => _change(() {
                                node.children.remove(child);
                                node.keptEmpty = false;
                              }),
                              child: Text(
                                child is _FilterGroup ? '그룹 제거' : '조건 제거',
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (node.children.isEmpty && !node.keptEmpty)
                    const Text('그룹에 조건을 추가하세요.'),
                ],
              ),
            ),
            _actions(node, remaining, depth: depth),
          ],
        ),
      },
    );
  }

  Widget _actions(_FilterNode node, int remaining, {required int depth}) {
    final suffix = depth == 0 ? '' : '-${node.id}';
    final wrapsRoot = node is! _FilterGroup;
    final available = !_atImportLimit && widget.database.properties.isNotEmpty;
    return Wrap(
      children: [
        TextButton.icon(
          key: ValueKey('database-view-filter-add$suffix'),
          onPressed:
              available && depth < _maxDepth && remaining >= (wrapsRoot ? 2 : 1)
              ? () => _add(node, group: false)
              : null,
          icon: const Icon(Icons.add, size: 18),
          label: const Text('조건 추가'),
        ),
        TextButton.icon(
          key: ValueKey('database-view-filter-add-group$suffix'),
          onPressed:
              available &&
                  depth < _maxDepth - 1 &&
                  remaining >= (wrapsRoot ? 3 : 2)
              ? () => _add(node, group: true)
              : null,
          icon: const Icon(Icons.add, size: 18),
          label: const Text('그룹 추가'),
        ),
      ],
    );
  }

  Widget _condition(_FilterCondition leaf, {required bool root}) {
    final suffix = root ? '' : '-${leaf.id}';
    final properties = widget.database.properties;
    final selected = _property(leaf.propertyId);
    String? error;
    if (leaf.edited &&
        selected != null &&
        !_withoutValue.contains(leaf.operator)) {
      try {
        _comparison(leaf);
      } on FormatException catch (invalid) {
        error = invalid.message;
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<String>(
          key: ValueKey('db-filter-property$suffix'),
          initialValue: selected?.id ?? '',
          isExpanded: true,
          decoration: const InputDecoration(labelText: '필터 속성'),
          items: [
            const DropdownMenuItem(value: '', child: Text('선택 안 함')),
            for (final property in properties)
              DropdownMenuItem(value: property.id, child: Text(property.name)),
          ],
          onChanged: (id) => _change(() {
            leaf.propertyId = id == '' ? null : id;
            leaf.edited = true;
          }),
        ),
        DropdownButtonFormField<String>(
          key: ValueKey('db-filter-operator$suffix'),
          initialValue: leaf.operator,
          isExpanded: true,
          decoration: const InputDecoration(labelText: '조건'),
          items: [
            for (final option in _operators.entries)
              DropdownMenuItem(value: option.key, child: Text(option.value)),
          ],
          onChanged: (operator) {
            if (operator == null) return;
            _change(() {
              leaf.operator = operator;
              leaf.edited = true;
            });
          },
        ),
        if (!_withoutValue.contains(leaf.operator))
          TextFormField(
            key: ValueKey('db-filter-value$suffix'),
            initialValue: leaf.text,
            onChanged: (value) => _change(() {
              leaf.text = value;
              leaf.edited = true;
            }),
            decoration: InputDecoration(
              labelText: '비교할 값',
              hintText: switch (selected?.type) {
                'checkbox' => 'true 또는 false',
                'date' when !_stringOperators.contains(leaf.operator) =>
                  'YYYY-MM-DD',
                _ => null,
              },
              errorText: error,
            ),
          ),
      ],
    );
  }
}
