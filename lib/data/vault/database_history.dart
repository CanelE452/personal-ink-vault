import 'package:collection/collection.dart';
import 'package:ink_vault_core/ink_vault_core.dart' show BlobRef;
import 'package:saber/data/vault/database_actions.dart';
import 'package:saber/data/vault/database_forms.dart';
import 'package:saber/data/vault/workspace_database.dart';

enum DatabaseHistoryChangeKind { added, removed, changed, moved }

final class DatabaseHistoryItemChange {
  new _(this.id, this.label, Set<DatabaseHistoryChangeKind> kinds)
    : kinds = Set.unmodifiable(kinds);

  final String id;
  final String label;
  final Set<DatabaseHistoryChangeKind> kinds;
}

final class DatabaseHistoryChanges {
  new _(List<DatabaseHistoryItemChange> items)
    : items = List.unmodifiable(items);

  final List<DatabaseHistoryItemChange> items;
  late final int added = _count(DatabaseHistoryChangeKind.added);
  late final int removed = _count(DatabaseHistoryChangeKind.removed);
  late final int changed = _count(DatabaseHistoryChangeKind.changed);
  late final int moved = _count(DatabaseHistoryChangeKind.moved);

  int _count(DatabaseHistoryChangeKind kind) =>
      items.where((item) => item.kinds.contains(kind)).length;
}

final class DatabaseHistoryDiff {
  const new _({
    required this.rows,
    required this.properties,
    required this.views,
    required this.templates,
    required this.attachments,
    required this.settingsChanged,
    required this.executionRecordsChanged,
  });

  factory compare(
    WorkspaceDatabase before,
    WorkspaceDatabase after, {
    Map<String, BlobRef> beforeFiles = const {},
    Map<String, BlobRef> afterFiles = const {},
  }) {
    _requireSameDatabase(before, after);
    final beforeSettings = _databaseSettings(before);
    final afterSettings = _databaseSettings(after);
    final beforeRecords = _takeExecutionRecords(beforeSettings);
    final afterRecords = _takeExecutionRecords(afterSettings);
    return ._(
      rows: _compareItems(_rows(before), _rows(after)),
      properties: _compareItems(_properties(before), _properties(after)),
      views: _compareItems(_views(before), _views(after)),
      templates: _compareItems(_templates(before), _templates(after)),
      attachments: _compareItems(
        _attachments(beforeFiles),
        _attachments(afterFiles),
        ordered: false,
      ),
      settingsChanged: !_json.equals(beforeSettings, afterSettings),
      executionRecordsChanged: !_json.equals(beforeRecords, afterRecords),
    );
  }

  final DatabaseHistoryChanges rows;
  final DatabaseHistoryChanges properties;
  final DatabaseHistoryChanges views;
  final DatabaseHistoryChanges templates;
  final DatabaseHistoryChanges attachments;
  final bool settingsChanged;
  final bool executionRecordsChanged;
}

/// Restores the chosen editable content with the current operational records.
/// The caller validates retained rules against the candidate before publishing.
WorkspaceDatabase databaseContentForRestore({
  required WorkspaceDatabase current,
  required WorkspaceDatabase chosen,
}) {
  _requireSameDatabase(current, chosen);
  final latest = current.toJson();
  final restored = chosen.toJson();
  for (final key in _executionFields) {
    for (final snapshot in [latest, restored]) {
      if (!snapshot.containsKey(key)) continue;
      final records = snapshot[key];
      if (records is! List || records.length > 10000) {
        throw const FormatException('저장된 실행 기록의 형식을 확인할 수 없습니다.');
      }
    }
  }
  _requireReceiptSubset(_automationLedger(current), _automationLedger(chosen));
  _requireReceiptSubset(_formLedger(current), _formLedger(chosen));
  for (final key in [..._executionFields, 'automationRules']) {
    if (latest.containsKey(key)) {
      restored[key] = latest[key];
    } else {
      restored.remove(key);
    }
  }
  return WorkspaceDatabase.fromJson(restored);
}

const _executionFields = ['automationExecutions', 'formSubmissions'];
const _json = DeepCollectionEquality(_JsonScalarEquality());

class _JsonScalarEquality extends DefaultEquality<Object?> {
  const new();

  @override
  bool equals(Object? left, Object? right) {
    if (left is num && right is num) {
      return left.runtimeType == right.runtimeType &&
          left.isNegative == right.isNegative &&
          left == right;
    }
    return super.equals(left, right);
  }
}

void _requireSameDatabase(WorkspaceDatabase before, WorkspaceDatabase after) {
  if (before.id != after.id || before.schemaVersion != after.schemaVersion) {
    throw const FormatException('같은 데이터베이스의 판본을 선택해 주세요.');
  }
}

Map<String, dynamic> _databaseSettings(WorkspaceDatabase database) {
  final fields = database.toJson();
  for (final key in const [
    'id',
    'schemaVersion',
    'rows',
    'properties',
    'views',
  ]) {
    fields.remove(key);
  }
  if (database.rowTemplates.isNotEmpty) fields.remove('pivRowTemplates');
  return fields;
}

List<Object?> _takeExecutionRecords(Map<String, dynamic> fields) => [
  for (final key in _executionFields)
    if (fields.containsKey(key)) fields.remove(key) else const [],
];

Map<String, Map<String, dynamic>> _automationLedger(
  WorkspaceDatabase database,
) {
  final records = <String, Map<String, dynamic>>{};
  final events = <(String, String)>{};
  try {
    for (final receipt in databaseActionReceipts(database)) {
      final id = receipt['id'] as String;
      final event = (receipt['ruleId'] as String, receipt['eventId'] as String);
      if (records.containsKey(id) || !events.add(event)) {
        throw const FormatException('중복된 자동화 실행 기록이 있습니다.');
      }
      records[id] = receipt;
    }
  } on DatabaseActionException {
    throw const FormatException('저장된 자동화 실행 기록을 확인할 수 없습니다.');
  }
  return records;
}

Map<String, Map<String, dynamic>> _formLedger(WorkspaceDatabase database) {
  try {
    return {
      for (final receipt in DatabaseForms(database).submissions)
        receipt.requestId: receipt.toJson(),
    };
  } on DatabaseFormException {
    throw const FormatException('저장된 폼 제출 기록을 확인할 수 없습니다.');
  }
}

void _requireReceiptSubset(
  Map<String, Map<String, dynamic>> current,
  Map<String, Map<String, dynamic>> chosen,
) {
  for (final entry in chosen.entries) {
    if (!_json.equals(current[entry.key], entry.value)) {
      throw const FormatException('현재 판본에 선택한 판본의 실행 기록이 모두 남아 있어야 합니다.');
    }
  }
}

typedef _HistoryValue = ({String label, Object content});

Map<String, _HistoryValue> _rows(WorkspaceDatabase database) {
  final title = database.properties.firstWhereOrNull(
    (property) => property.type == 'title',
  );
  String label(DatabaseRow row) {
    final value = row.values[title?.id];
    return value is String && value.trim().isNotEmpty ? value : row.id;
  }

  return {
    for (final row in database.rows)
      row.id: (label: label(row), content: row.toJson()),
  };
}

Map<String, _HistoryValue> _properties(WorkspaceDatabase database) => {
  for (final property in database.properties)
    property.id: (label: property.name, content: property.toJson()),
};

Map<String, _HistoryValue> _views(WorkspaceDatabase database) => {
  for (final view in database.views)
    view.id: (label: view.name, content: view.toJson()),
};

Map<String, _HistoryValue> _templates(WorkspaceDatabase database) => {
  for (final template in database.rowTemplates)
    template.id: (label: template.name, content: template.toJson()),
};

Map<String, _HistoryValue> _attachments(Map<String, BlobRef> files) => {
  for (final entry in files.entries)
    if (entry.key != 'database.json')
      entry.key: (label: entry.key, content: entry.value.toJson()),
};

DatabaseHistoryChanges _compareItems(
  Map<String, _HistoryValue> before,
  Map<String, _HistoryValue> after, {
  bool ordered = true,
}) {
  final moved = ordered ? _movedIds(before.keys, after.keys) : const <String>{};
  final changes = <DatabaseHistoryItemChange>[];
  for (final id in {...after.keys, ...before.keys}) {
    final old = before[id], next = after[id];
    final kinds = {
      if (old == null) DatabaseHistoryChangeKind.added,
      if (next == null) DatabaseHistoryChangeKind.removed,
      if (old != null &&
          next != null &&
          !_json.equals(old.content, next.content))
        DatabaseHistoryChangeKind.changed,
      if (moved.contains(id)) DatabaseHistoryChangeKind.moved,
    };
    if (kinds.isNotEmpty) {
      changes.add(DatabaseHistoryItemChange._(id, (next ?? old!).label, kinds));
    }
  }
  return DatabaseHistoryChanges._(changes);
}

Set<String> _movedIds(Iterable<String> before, Iterable<String> after) {
  final order = {for (final (index, id) in before.indexed) id: index};
  final common = after.where(order.containsKey).toList(growable: false);
  // Keep the longest subsequence that retained its relative order.
  final tails = <int>[];
  final previous = List.filled(common.length, -1);
  for (var index = 0; index < common.length; index++) {
    final rank = order[common[index]]!;
    var low = 0, high = tails.length;
    while (low < high) {
      final middle = (low + high) ~/ 2;
      if (order[common[tails[middle]]]! < rank) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    if (low > 0) previous[index] = tails[low - 1];
    if (low == tails.length) {
      tails.add(index);
    } else {
      tails[low] = index;
    }
  }
  final moved = common.toSet();
  for (
    var index = tails.lastOrNull ?? -1;
    index >= 0;
    index = previous[index]
  ) {
    moved.remove(common[index]);
  }
  return moved;
}
