import 'package:collection/collection.dart';
import 'package:ink_vault_core/ink_vault_core.dart' show validateId;
import 'package:saber/data/native/ink_vault_native.dart';
import 'package:saber/data/vault/workspace_database.dart';

const databaseActionPropertyTypes = [
  'title',
  'text',
  'number',
  'status',
  'select',
  'multiSelect',
  'date',
  'checkbox',
  'url',
  'email',
  'phone',
];

class DatabaseActionException implements Exception {
  const new(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => 'DatabaseActionException($code): $message';
}

class DatabaseActionPrepared {
  const new({
    required this.database,
    required this.receipts,
    required this.duplicate,
    required this.changed,
    required this.request,
  });
  final WorkspaceDatabase database;
  final List<Map<String, dynamic>> receipts;
  final bool duplicate;
  final bool changed;
  final Map<String, dynamic> request;
}

class DatabaseActionDue {
  const new({
    required this.events,
    required this.hasMore,
    required this.cursor,
    required this.capturedAtUtcMs,
  });
  final List<Map<String, dynamic>> events;
  final bool hasMore;
  final Map<String, dynamic>? cursor;
  final int capturedAtUtcMs;
}

List<Map<String, dynamic>> databaseActionReceipts(WorkspaceDatabase database) =>
    _freezeList(
      _list(database.toJson()['automationExecutions'])
          .map((value) {
            final receipt = _map(value);
            _receipt(receipt);
            return _frozenMap(receipt);
          })
          .toList(growable: false),
    );

class DatabaseActionRuntime {
  const new({required this.deviceId, required this.invoke});
  final String deviceId;
  final Map<String, dynamic> Function(Map<String, Object?>) invoke;
  List<Map<String, dynamic>> rules(WorkspaceDatabase database) =>
      _rules(database);
  WorkspaceDatabase setTaskLinks(
    WorkspaceDatabase database, {
    required String rowId,
    required String? parentId,
    required List<String> predecessorIds,
  }) {
    if (!database.supportsTaskLinks) {
      throw const DatabaseActionException(
        'unsupported_task_links',
        '이 데이터베이스의 작업 연결 형식을 편집할 수 없습니다.',
      );
    }
    final result = _call({
      'op': 'workspace_task_links',
      'rows': [
        for (final row in database.rows)
          {'id': row.id, 'archived': row.archived},
      ],
      'taskLinks': database.taskLinksEnvelope,
      'rowId': _id(rowId),
      'parentId': parentId == null ? null : _id(parentId),
      'predecessorIds': [for (final id in predecessorIds) _id(id)],
    });
    if (result.length != 1) _badResponse();
    final WorkspaceDatabase changed;
    try {
      changed = database.withTaskLinks(_map(result['taskLinks']));
    } on FormatException {
      _badResponse();
    }
    final links = changed.taskLinks[rowId];
    if (links?.parentId != parentId ||
        !const UnorderedIterableEquality<String>().equals(
          links?.predecessorIds ?? const <String>[],
          predecessorIds,
        )) {
      _badResponse();
    }
    return changed;
  }

  List<Map<String, dynamic>> receipts(WorkspaceDatabase database) =>
      databaseActionReceipts(database);
  void validate(WorkspaceDatabase database) {
    final result = _call({
      'op': 'workspace_actions',
      'mode': 'validate',
      'database': database.toJson(),
      'deviceId': deviceId,
    });
    if (result['valid'] != true) _badResponse();
  }

  void validateRule(WorkspaceDatabase database, Map<String, dynamic> rule) =>
      validate(
        WorkspaceDatabase.fromJson({
          ...database.toJson(),
          'automationRules': [_copyMap(rule)],
        }),
      );
  WorkspaceDatabase putRule(
    WorkspaceDatabase database,
    Map<String, dynamic> rule,
  ) {
    final id = _id(rule['id']);
    final existing = rules(database);
    final old = existing.where((item) => item['id'] == id).singleOrNull;
    final next = _merge(old ?? {}, rule)..['version'] = _nextVersion(old);
    if (rule['trigger'] is Map && old?['trigger'] is Map) {
      next['trigger'] = _merge(_map(old!['trigger']), _map(rule['trigger']));
    }
    if (rule['actions'] is List) {
      final oldActions = _list(old?['actions']).map(_map).toList();
      next['actions'] = [
        for (final value in rule['actions'] as List)
          _mergeAction(
            oldActions
                    .where((item) => item['id'] == _map(value)['id'])
                    .singleOrNull ??
                {},
            _map(value),
          ),
      ];
    }
    validateRule(database, next);
    final all = [
      for (final item in existing)
        if (item['id'] != id) _copyMap(item) else next,
      if (old == null) next,
    ];
    if (all.length > 64)
      throw const DatabaseActionException('rule_limit', '규칙은 64개까지 만들 수 있습니다.');
    return WorkspaceDatabase.fromJson({
      ...database.toJson(),
      'automationRules': all,
    });
  }

  WorkspaceDatabase archiveRule(WorkspaceDatabase database, String id) =>
      _archive(database, id);

  WorkspaceDatabase _archive(WorkspaceDatabase database, String id) {
    _id(id);
    final all = rules(database);
    final old = all.where((rule) => rule['id'] == id).singleOrNull;
    if (old == null)
      throw const DatabaseActionException('missing_rule', '규칙을 찾지 못했습니다.');
    validate(
      WorkspaceDatabase.fromJson({...database.toJson(), 'automationRules': []}),
    );
    return WorkspaceDatabase.fromJson({
      ...database.toJson(),
      'automationRules': [
        for (final rule in all)
          if (rule['id'] == id)
            {
              ..._copyMap(rule),
              'version': _nextVersion(old),
              'enabled': false,
              'archived': true,
            }
          else
            _copyMap(rule),
      ],
    });
  }

  DatabaseActionPrepared prepare(
    WorkspaceDatabase database, {
    required Map<String, dynamic> event,
    String? ruleId,
    required String inputRevision,
    required int capturedAtUtcMs,
  }) {
    _id(inputRevision);
    if (ruleId != null) _id(ruleId);
    for (final key in ['id', 'rowId', 'propertyId']) {
      if (event[key] != null) _id(event[key]);
    }
    final request = <String, dynamic>{
      'op': 'workspace_actions',
      'mode': 'apply',
      'database': database.toJson(),
      'deviceId': deviceId,
      'event': _copyMap(event),
      if (event['type'] == 'schedule') 'materializeTemplates': true,
      'ruleId': ?ruleId,
      'inputRevision': inputRevision,
      'capturedAtUtcMs': capturedAtUtcMs,
    };
    final result = _call(_copyMap(request));
    if (result['duplicate'] is! bool ||
        result['changed'] is! bool ||
        result['duplicate'] == true && result['changed'] == true)
      _badResponse();
    final returned = _map(result['database']);
    if (returned['id'] != database.id) _badResponse();
    final items = _list(result['receipts'], optional: false).map(_map).toList();
    final ledger = _list(returned['automationExecutions']).map(_map).toList();
    for (final receipt in items) {
      _receipt(receipt);
      if (ruleId != null && receipt['ruleId'] != ruleId) _badResponse();
      if (!ledger.any(
        (item) => const DeepCollectionEquality().equals(item, receipt),
      ))
        _badResponse();
      if (result['duplicate'] == false &&
          (receipt['inputRevision'] != inputRevision ||
              receipt['deviceId'] != deviceId ||
              receipt['capturedAtUtcMs'] != capturedAtUtcMs))
        _badResponse();
      if (['manual', 'propertyChanged'].contains(event['type']) &&
          receipt['eventId'] != event['id'])
        _badResponse();
    }
    WorkspaceDatabase updated;
    try {
      updated = WorkspaceDatabase.fromJson(returned);
    } on Object {
      _badResponse();
    }
    if (event['type'] == 'schedule' && result['duplicate'] == false) {
      updated = _materializeScheduledRows(database, updated, items);
    }
    return DatabaseActionPrepared(
      database: updated,
      receipts: _freezeList(items),
      duplicate: result['duplicate'] as bool,
      changed: result['changed'] as bool,
      request: _frozenMap(request),
    );
  }

  WorkspaceDatabase _materializeScheduledRows(
    WorkspaceDatabase original,
    WorkspaceDatabase candidate,
    List<Map<String, dynamic>> receipts,
  ) {
    if (receipts.isEmpty) return candidate;
    final definitions = {for (final rule in rules(original)) rule['id']: rule};
    final placeholders = {for (final row in candidate.rows) row.id: row};
    final replacements = <String, DatabaseRow>{};
    for (final receipt in receipts) {
      if (receipt['status'] != 'completed') continue;
      final rule = definitions[receipt['ruleId']];
      if (rule == null) _badResponse();
      final templates = {
        for (final action in _list(rule['actions']).map(_map))
          if (action['type'] == 'addRowFromTemplate') action['id']: action,
      };
      for (final result in _list(receipt['actionResults']).map(_map)) {
        final action = templates.remove(result['actionId']);
        if (action == null) {
          if (result['templateId'] != null) _badResponse();
          continue;
        }
        final rowId = _id(result['rowId']);
        final templateId = _id(action['templateId']);
        final overrides = _map(action['values']);
        if (result['type'] != 'addRow' ||
            result['templateId'] != templateId ||
            replacements.containsKey(rowId) ||
            !const DeepCollectionEquality().equals(
              placeholders[rowId]?.values,
              overrides,
            )) {
          _badResponse();
        }
        replacements[rowId] = original.instantiateRowTemplate(
          templateId: templateId,
          rowId: rowId,
          overrides: overrides,
        );
      }
      if (templates.isNotEmpty) _badResponse();
    }
    if (replacements.isEmpty) return candidate;
    final updated = candidate.copyWith(
      rows: [for (final row in candidate.rows) replacements[row.id] ?? row],
    );
    final check = _call({
      'op': 'workspace_actions',
      'mode': 'validateSnapshot',
      'database': updated.toJson(),
      'deviceId': deviceId,
    });
    if (check['valid'] != true) _badResponse();
    return updated;
  }

  DatabaseActionPrepared prepareManual(
    WorkspaceDatabase database, {
    required String ruleId,
    required String eventId,
    String? rowId,
    required String inputRevision,
    required int capturedAtUtcMs,
  }) => prepare(
    database,
    event: {
      'id': eventId,
      'type': 'manual',
      'rowId': ?rowId,
      'origin': 'button',
    },
    ruleId: ruleId,
    inputRevision: inputRevision,
    capturedAtUtcMs: capturedAtUtcMs,
  );
  DatabaseActionPrepared prepareRowAdded(
    WorkspaceDatabase database, {
    required String rowId,
    String origin = 'user',
    required String inputRevision,
    required int capturedAtUtcMs,
  }) => prepare(
    database,
    event: {'type': 'rowAdded', 'rowId': rowId, 'origin': origin},
    inputRevision: inputRevision,
    capturedAtUtcMs: capturedAtUtcMs,
  );
  DatabaseActionPrepared preparePropertyChanged(
    WorkspaceDatabase database, {
    required String eventId,
    required String rowId,
    required String propertyId,
    required Object? oldValue,
    required Object? value,
    String origin = 'user',
    required String inputRevision,
    required int capturedAtUtcMs,
  }) => prepare(
    database,
    event: {
      'id': eventId,
      'type': 'propertyChanged',
      'rowId': rowId,
      'propertyId': propertyId,
      'oldValue': _copy(oldValue),
      'value': _copy(value),
      'origin': origin,
    },
    inputRevision: inputRevision,
    capturedAtUtcMs: capturedAtUtcMs,
  );
  DatabaseActionPrepared prepareScheduled(
    WorkspaceDatabase database, {
    required String ruleId,
    required int scheduledForUtcMs,
    required String inputRevision,
    required int capturedAtUtcMs,
  }) => prepare(
    database,
    event: {
      'type': 'schedule',
      'scheduledForUtcMs': scheduledForUtcMs,
      'origin': 'user',
    },
    ruleId: ruleId,
    inputRevision: inputRevision,
    capturedAtUtcMs: capturedAtUtcMs,
  );
  DatabaseActionDue due(
    WorkspaceDatabase database, {
    required int capturedAtUtcMs,
    Map<String, dynamic>? cursor,
    int? sinceUtcMs,
  }) {
    final result = _call({
      'op': 'workspace_actions',
      'mode': 'due',
      'database': database.toJson(),
      'deviceId': deviceId,
      'capturedAtUtcMs': capturedAtUtcMs,
      'sinceUtcMs': ?sinceUtcMs,
      if (cursor != null) 'cursor': _copyMap(cursor),
    });
    if (result['hasMore'] is! bool) _badResponse();
    final events = _list(result['events'], optional: false).map(_map).toList();
    if (events.length > 32) _badResponse();
    final defined = rules(database).map((rule) => rule['id']).toSet();
    for (final entry in events) {
      final ruleId = _id(entry['ruleId']);
      final event = _map(entry['event']);
      _id(event['id']);
      if (!defined.contains(ruleId) ||
          event['type'] != 'schedule' ||
          event['scheduledForUtcMs'] is! int)
        _badResponse();
      if (event['rowId'] != null) _id(event['rowId']);
    }
    final next = result['cursor'] == null ? null : _map(result['cursor']);
    if (result['hasMore'] == true && next == null) _badResponse();
    return DatabaseActionDue(
      events: _freezeList(events),
      hasMore: result['hasMore'] as bool,
      cursor: next == null ? null : _frozenMap(next),
      capturedAtUtcMs: capturedAtUtcMs,
    );
  }

  Map<String, dynamic> _call(Map<String, Object?> request) {
    _id(deviceId);
    Map<String, dynamic> result;
    try {
      result = invoke(request);
    } on InkVaultNativeException catch (error) {
      throw DatabaseActionException(error.code, error.message);
    }
    if (result['error'] is Map) {
      final error = _map(result['error']);
      throw DatabaseActionException(
        error['code'] is String ? error['code'] as String : 'engine_error',
        error['message'] is String
            ? error['message'] as String
            : '공통 엔진이 요청을 처리하지 못했습니다.',
      );
    }
    return result;
  }
}

List<Map<String, dynamic>> _rules(WorkspaceDatabase database) {
  final items = _list(database.toJson()['automationRules']).map(_map).toList();
  final ids = <String>{};
  if (items.length > 64)
    throw const DatabaseActionException('rule_limit', '규칙 수가 지원 범위를 넘습니다.');
  for (final rule in items) {
    if (!ids.add(_id(rule['id'])))
      throw const DatabaseActionException('duplicate_rule', '규칙 ID가 중복됩니다.');
  }
  return _freezeList(items);
}

int _nextVersion(Map<String, dynamic>? old) {
  if (old == null) return 1;
  final version = old['version'];
  if (version is! int || version < 1 || version >= 2147483647) {
    throw const DatabaseActionException('invalid_rule', '규칙 버전을 갱신할 수 없습니다.');
  }
  return version + 1;
}

void _receipt(Map<String, dynamic> receipt) {
  for (final key in ['id', 'ruleId', 'eventId', 'inputRevision', 'deviceId']) {
    _id(receipt[key]);
  }
  for (final key in ['eventDigest', 'ruleDigest']) {
    if (receipt[key] is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(receipt[key] as String))
      _badResponse();
  }
  if (receipt['ruleVersion'] is! int ||
      (receipt['ruleVersion'] as int) < 1 ||
      receipt['capturedAtUtcMs'] is! int ||
      !['completed', 'skipped'].contains(receipt['status']))
    _badResponse();
  for (final result in _list(
    receipt['actionResults'],
    optional: false,
  ).map(_map)) {
    _id(result['actionId']);
    _id(result['rowId']);
    if (result['propertyId'] != null) _id(result['propertyId']);
    if (!['addRow', 'setProperty', 'setStatus'].contains(result['type']))
      _badResponse();
    if (result['templateId'] != null) {
      if (result['type'] != 'addRow') _badResponse();
      _id(result['templateId']);
    }
  }
}

String _id(Object? value) {
  if (value is! String) _badResponse();
  try {
    validateId(value);
  } on Object {
    throw const DatabaseActionException(
      'invalid_identity',
      '항목 ID가 올바르지 않습니다.',
    );
  }
  return value;
}

Never _badResponse() => throw const DatabaseActionException(
  'invalid_response',
  '자동화 엔진의 결과를 확인하지 못했습니다.',
);
Map<String, dynamic> _map(Object? value) {
  if (value is! Map || value.keys.any((key) => key is! String)) _badResponse();
  return Map<String, dynamic>.from(value);
}

List<dynamic> _list(Object? value, {bool optional = true}) {
  if (value == null && optional) return [];
  if (value is! List) _badResponse();
  return value;
}

Object? _copy(Object? value) => value is Map
    ? {for (final entry in _map(value).entries) entry.key: _copy(entry.value)}
    : value is List
    ? value.map(_copy).toList()
    : value;
Map<String, dynamic> _copyMap(Map<String, dynamic> value) => _map(_copy(value));
Map<String, dynamic> _merge(
  Map<String, dynamic> old,
  Map<String, dynamic> value,
) => {..._copyMap(old), ..._copyMap(value)};
Map<String, dynamic> _mergeAction(
  Map<String, dynamic> old,
  Map<String, dynamic> value,
) {
  final merged = _merge(old, value);
  if (old['type'] == 'addRowFromTemplate' &&
      merged['type'] != 'addRowFromTemplate') {
    merged.remove('templateId');
  }
  return merged;
}

Object? _freeze(Object? value) => value is Map
    ? Map<String, dynamic>.unmodifiable({
        for (final entry in _map(value).entries)
          entry.key: _freeze(entry.value),
      })
    : value is List
    ? List<Object?>.unmodifiable(value.map(_freeze))
    : value;
Map<String, dynamic> _frozenMap(Map<String, dynamic> value) =>
    _mapFrozen(_freeze(value));
Map<String, dynamic> _mapFrozen(Object? value) => value as Map<String, dynamic>;
List<Map<String, dynamic>> _freezeList(List<Map<String, dynamic>> value) =>
    List<Map<String, dynamic>>.unmodifiable(value.map(_frozenMap));
