import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:saber/data/native/ink_vault_native.dart';
import 'package:saber/data/vault/database_query.dart';
import 'package:saber/data/vault/database_query_codec.dart';
import 'package:saber/data/vault/workspace_database.dart';

export 'database_query_codec.dart';

class DatabaseQueryNativeException implements Exception {
  const new(this.code, this.message);
  final String code, message;
  @override
  String toString() => 'DatabaseQueryNativeException($code): $message';
}

class DatabaseQueryBatch {
  new _({
    required List<Object?> results,
    required List<DatabaseCalculationError> errors,
    required this.remainingBudget,
  }) : results = List.unmodifiable(results),
       errors = List.unmodifiable(errors);
  final List<Object?> results;
  final List<DatabaseCalculationError> errors;
  final int remainingBudget;
}

class DatabaseQueryRuntime {
  const new({required this.invoke});
  final Map<String, dynamic> Function(Map<String, Object?>) invoke;
  static const maxOperations = 512;
  static const maxCells = 10000;
  static const maxRequestBytes = 32 * 1024 * 1024;
  static const maxResponseBytes = 8 * 1024 * 1024;

  DatabaseQueryBatch evaluate(
    WorkspaceDatabase database, {
    required List<Map<String, Object?>> operations,
    Map<String, WorkspaceDatabase> databases = const {},
    DateTime? now,
    int maxDepth = 32,
    int budget = 10000,
  }) {
    var sent = false;
    try {
      if (maxDepth < 1 || maxDepth > 128 || budget < 1 || budget > 1000000)
        _invalid();
      if (operations.length > maxOperations) _invalid();
      _validateOperations(operations);
      final related = <Map<String, Object?>>[];
      for (final entry in databases.entries) {
        if (entry.key != entry.value.id) _invalid();
        if (entry.key != database.id) related.add(_snapshot(entry.value));
      }
      final logical = <String, Object?>{
        'op': 'workspace_query',
        'schemaVersion': 1,
        'database': _snapshot(database),
        'databases': related,
        if (now != null) 'capturedAtUtc': now.toUtc().toIso8601String(),
        'maxDepth': maxDepth,
        'budget': budget,
        'operations': operations,
      };
      final request = <String, Object?>{
        'op': 'workspace_query',
        'schemaVersion': 1,
        'encoding': 'utf16-v1',
        'payload': DatabaseQueryCodec.pack(logical),
      };
      if (_bytes(request) > maxRequestBytes)
        throw const DatabaseQueryNativeException(
          'query_too_large',
          '계산 입력이 공통 엔진의 크기 한도를 넘었습니다. 원본은 보존됩니다.',
        );
      sent = true;
      final response = invoke(request);
      if (_bytes(response) > maxResponseBytes) _invalid();
      if (response.length != 2 || response['encoding'] != 'utf16-v1')
        _invalid();
      final decoded = _map(DatabaseQueryCodec.unpack(response['payload']));
      final results = _list(decoded['results']);
      final remaining = decoded['remainingBudget'];
      if (remaining is! int ||
          remaining > budget ||
          results.length != operations.length)
        _invalid();
      final errors = _errors(decoded['errors']);
      _validateResults(database, operations, results, errors);
      return DatabaseQueryBatch._(
        results: results,
        errors: errors,
        remainingBudget: remaining,
      );
    } on DatabaseQueryNativeException {
      rethrow;
    } on InkVaultNativeException catch (error) {
      throw DatabaseQueryNativeException(
        error.code,
        '공통 계산을 완료하지 못했습니다. 원본은 보존되며 편집할 수 있습니다.',
      );
    } on FormatException {
      throw DatabaseQueryNativeException(
        sent ? 'invalid_response' : 'invalid_arguments',
        sent
            ? '공통 계산 엔진의 응답을 확인하지 못했습니다. 원본은 보존됩니다.'
            : '계산에 사용할 데이터베이스와 보기를 확인해 주세요.',
      );
    } on Object {
      throw const DatabaseQueryNativeException(
        'native_query_failed',
        '공통 계산을 완료하지 못했습니다. 원본은 보존되며 편집할 수 있습니다.',
      );
    }
  }

  DatabaseQuery project(
    WorkspaceDatabase database, {
    required DatabaseView view,
    Map<String, WorkspaceDatabase> databases = const {},
    DateTime? now,
    List<String>? valuePropertyIds,
    int maxDepth = 32,
    int budget = 10000,
  }) {
    try {
      final plan = _plan(database, view, valuePropertyIds);
      final batch = evaluate(
        database,
        databases: databases,
        operations: plan,
        now: now,
        maxDepth: maxDepth,
        budget: budget,
      );
      return _DatabaseProjection(
        database,
        view: view,
        plan: plan,
        batch: batch,
        now: now,
        maxDepth: maxDepth,
        budget: budget,
      );
    } on DatabaseQueryNativeException catch (error) {
      return _DatabaseProjection.failed(
        database,
        view: view,
        error: DatabaseCalculationError(error.code, error.message),
      );
    } on Object {
      return _DatabaseProjection.failed(
        database,
        view: view,
        error: const DatabaseCalculationError(
          'invalid_arguments',
          '계산에 사용할 데이터베이스와 보기를 확인해 주세요.',
        ),
      );
    }
  }

  Map<String, Object?> _snapshot(WorkspaceDatabase database) => {
    'schemaVersion': database.schemaVersion,
    'id': database.id,
    'properties': [
      for (final property in database.properties)
        {
          'id': property.id,
          'name': property.name,
          'type': property.type,
          'config': property.config,
        },
    ],
    'rows': [
      for (final row in database.rows)
        {'id': row.id, 'values': row.values, 'archived': row.archived},
    ],
  };

  List<Map<String, Object?>> _plan(
    WorkspaceDatabase database,
    DatabaseView view,
    List<String>? requestedProperties,
  ) {
    final plan = <Map<String, Object?>>[
      {'type': 'apply', 'view': view.toJson()},
    ];
    if (const {'table', 'board', 'list', 'gallery'}.contains(view.type)) {
      final visible = view.visibleProperties.isEmpty
          ? database.properties
          : [
              for (final id in view.visibleProperties)
                ...database.properties.where((property) => property.id == id),
            ];
      final title = database.properties
          .where((property) => property.type == 'title')
          .firstOrNull
          ?.id;
      final properties =
          (requestedProperties ??
                  (view.type == 'table'
                      ? visible.map((property) => property.id).toList()
                      : visible
                            .where((property) => property.id != title)
                            .take(3)
                            .map((property) => property.id)
                            .toList()))
              .toSet()
              .toList(growable: false);
      if (properties.isNotEmpty)
        plan.add({'type': 'values', 'from': 0, 'propertyIds': properties});
    } else if (view.type == 'calendar' || view.type == 'timeline') {
      final id = view.config['datePropertyId'];
      final property = database.properties
          .where(
            (property) =>
                property.type == 'date' &&
                (!view.config.containsKey('datePropertyId') ||
                    property.id == id),
          )
          .firstOrNull;
      if (property != null)
        plan.add({
          'type': 'calendar',
          'propertyId': property.id,
          'view': view.toJson(),
        });
    } else if (view.type == 'chart') {
      const keys = {
        'chartGroupBy',
        'chartValuePropertyId',
        'chartCalculation',
        'chartType',
      };
      if (!keys.any(
        (key) => view.config[key] != null && view.config[key] is! String,
      )) {
        final group = view.config.containsKey('chartGroupBy')
            ? view.config['chartGroupBy'] as String?
            : view.groupBy;
        if (group != null)
          plan.add({
            'type': 'chart',
            'groupBy': group,
            if (view.config['chartValuePropertyId'] != null)
              'valuePropertyId': view.config['chartValuePropertyId'],
            'calculation': view.config['chartCalculation'] ?? 'count',
            'view': view.toJson(),
          });
      }
    }
    return plan;
  }
}

void _validateOperations(List<Map<String, Object?>> operations) {
  for (var index = 0; index < operations.length; index++) {
    final operation = operations[index];
    final type = operation['type'];
    final allowed = switch (type) {
      'value' => {'type', 'rowId', 'propertyId'},
      'apply' => {'type', 'view'},
      'values' => {'type', 'from', 'propertyIds'},
      'aggregate' => {
        'type',
        'propertyId',
        'calculation',
        'rowIds',
        'from',
        'view',
      },
      'calendar' => {'type', 'propertyId', 'view'},
      'chart' => {'type', 'groupBy', 'valuePropertyId', 'calculation', 'view'},
      _ => _invalid(),
    };
    if (operation.keys.any((key) => !allowed.contains(key))) _invalid();
    for (final key in switch (type) {
      'value' => ['rowId', 'propertyId'],
      'aggregate' || 'calendar' => ['propertyId'],
      'chart' => ['groupBy'],
      _ => <String>[],
    }) {
      _string(operation[key]);
    }
    for (final key in ['calculation', 'valuePropertyId']) {
      if (operation.containsKey(key)) _string(operation[key]);
    }
    if (type == 'apply' || operation.containsKey('view')) {
      final view = DatabaseView.fromJson(_map(operation['view']));
      if (view.type == databaseDashboardViewType) _invalid();
    }
    if (type == 'values' || operation.containsKey('from')) {
      final from = operation['from'];
      if (from is! int ||
          from < 0 ||
          from >= index ||
          operations[from]['type'] != 'apply')
        _invalid();
    }
    if (type == 'values') {
      final properties = _strings(operation['propertyIds']);
      if (properties.length > DatabaseQueryRuntime.maxCells) _invalid();
    }
    if (operation.containsKey('rowIds')) _strings(operation['rowIds']);
  }
}

void _validateResults(
  WorkspaceDatabase database,
  List<Map<String, Object?>> operations,
  List<Object?> results,
  List<DatabaseCalculationError> errors,
) {
  final active = {
    for (final row in database.rows.where((row) => !row.archived)) row.id,
  };
  final selections = <int, List<String>>{};
  var cells = 0;
  void value(Object? raw) {
    final parsed = _value(raw);
    if (parsed.error != null && !_containsError(errors, parsed.error!))
      _invalid();
  }

  for (var index = 0; index < operations.length; index++) {
    final operation = operations[index], raw = results[index];
    switch (operation['type']) {
      case 'apply':
        final result = _map(raw);
        final rows = _rowIds(result['rowIds'], active);
        selections[index] = rows;
        final keys = <String>{};
        for (final rawGroup in _list(result['groups'])) {
          final group = _map(rawGroup), key = _string(group['key']);
          if (!keys.add(key)) _invalid();
          _rowIds(group['rowIds'], rows.toSet());
        }
        for (final error in _errors(result['errors'])) {
          if (!_containsError(errors, error)) _invalid();
        }
      case 'value' || 'aggregate':
        value(raw);
      case 'values':
        final rows = selections[operation['from']]!;
        final properties = _strings(operation['propertyIds']);
        cells += rows.length * properties.length;
        if (cells > DatabaseQueryRuntime.maxCells) _invalid();
        final entries = _list(raw);
        if (entries.length != rows.length) _invalid();
        for (var rowIndex = 0; rowIndex < rows.length; rowIndex++) {
          final entry = _map(entries[rowIndex]);
          if (entry['rowId'] != rows[rowIndex]) _invalid();
          final values = _list(entry['values']);
          if (values.length != properties.length) _invalid();
          for (
            var propertyIndex = 0;
            propertyIndex < properties.length;
            propertyIndex++
          ) {
            final cell = _map(values[propertyIndex]);
            if (cell['propertyId'] != properties[propertyIndex]) _invalid();
            value(cell);
          }
        }
      case 'calendar':
        final seen = <String>{};
        DateTime? previous;
        for (final rawItem in _list(raw)) {
          final item = _calendarItem(rawItem);
          if (!active.contains(item.rowId) ||
              !seen.add(item.rowId) ||
              previous != null && item.start.isBefore(previous))
            _invalid();
          previous = item.start;
        }
      case 'chart':
        final keys = <String>{};
        for (final rawPoint in _list(raw)) {
          final point = _chartPoint(rawPoint);
          if (!keys.add(point.key)) _invalid();
          _rowIds(point.rowIds, active);
        }
    }
  }
}

class _DatabaseProjection extends DatabaseQuery {
  new(
    super.database, {
    required this.view,
    required List<Map<String, Object?>> plan,
    required DatabaseQueryBatch batch,
    super.now,
    super.maxDepth,
    super.budget,
  }) : _projectionErrors = batch.errors {
    final first = _map(batch.results.first);
    final rows = {for (final row in database.rows) row.id: row};
    _result = DatabaseQueryResult(
      rows: [for (final id in _strings(first['rowIds'])) rows[id]!],
      groups: {
        for (final rawGroup in _list(first['groups']))
          _string(_map(rawGroup)['key']): [
            for (final id in _strings(_map(rawGroup)['rowIds'])) rows[id]!,
          ],
      },
      errors: _errors(first['errors']),
    );
    if (plan.length == 1) return;
    final operation = plan[1];
    switch (operation['type']) {
      case 'values':
        for (final rawRow in _list(batch.results[1])) {
          final row = _map(rawRow);
          _values[_string(row['rowId'])] = Map.unmodifiable({
            for (final rawCell in _list(row['values']))
              _string(_map(rawCell)['propertyId']): _value(rawCell),
          });
        }
      case 'calendar':
        _calendarProperty = _string(operation['propertyId']);
        _calendarItems = List.unmodifiable(
          _list(batch.results[1]).map(_calendarItem),
        );
      case 'chart':
        _chartOperation = operation;
        _chartPoints = List.unmodifiable(
          _list(batch.results[1]).map(_chartPoint),
        );
    }
  }

  new failed(
    super.database, {
    required this.view,
    required DatabaseCalculationError error,
  }) : _projectionErrors = List.unmodifiable([error]),
       _failure = error {
    _result = DatabaseQueryResult(
      rows: database.rows.where((row) => !row.archived).toList(),
      errors: _projectionErrors,
    );
  }

  final DatabaseView view;
  final List<DatabaseCalculationError> _projectionErrors;
  DatabaseCalculationError? _failure;
  late final DatabaseQueryResult _result;
  final _values = <String, Map<String, DatabaseValue>>{};
  String? _calendarProperty;
  List<DatabaseCalendarItem> _calendarItems = const [];
  Map<String, Object?>? _chartOperation;
  List<DatabaseChartPoint> _chartPoints = const [];

  @override
  List<DatabaseCalculationError> get errors => _projectionErrors;

  bool _matches(DatabaseView? view) =>
      view != null &&
      const DeepCollectionEquality().equals(view.toJson(), this.view.toJson());

  @override
  DatabaseQueryResult apply(DatabaseView view) => _matches(view)
      ? _result
      : DatabaseQueryResult(rows: [], errors: [_unavailable]);

  @override
  DatabaseValue value(DatabaseRow row, String propertyId) {
    if (_failure != null) {
      final current = database.rows
          .where((item) => item.id == row.id && !item.archived)
          .firstOrNull;
      final property = database.properties
          .where((item) => item.id == propertyId)
          .firstOrNull;
      if (current != null && property != null && !property.isComputed)
        return DatabaseValue(current.values[propertyId]);
      return DatabaseValue(null, error: _failure);
    }
    return _values[row.id]?[propertyId] ??
        const DatabaseValue(null, error: _unavailable);
  }

  @override
  DatabaseValue aggregate(
    String propertyId, {
    String calculation = 'sum',
    List<DatabaseRow>? rows,
    DatabaseView? view,
  }) => DatabaseValue(null, error: _failure ?? _unavailable);

  @override
  List<DatabaseCalendarItem> calendar({
    required String propertyId,
    DatabaseView? view,
  }) {
    if (_failure != null) return const [];
    if (!_matches(view) || propertyId != _calendarProperty) _notPrepared();
    return _calendarItems;
  }

  @override
  List<DatabaseChartPoint> chart({
    required String groupBy,
    String? valuePropertyId,
    String calculation = 'count',
    DatabaseView? view,
  }) {
    if (_failure != null) return const [];
    if (!_matches(view) ||
        _chartOperation?['groupBy'] != groupBy ||
        _chartOperation?['valuePropertyId'] != valuePropertyId ||
        _chartOperation?['calculation'] != calculation)
      _notPrepared();
    return _chartPoints;
  }
}

const _unavailable = DatabaseCalculationError(
  'projection_unavailable',
  '이 계산은 준비된 보기에 포함되지 않았습니다. 새 계산 요청이 필요합니다.',
);
Never _notPrepared() => throw const DatabaseQueryNativeException(
  'projection_unavailable',
  '이 계산은 준비된 보기에 포함되지 않았습니다.',
);
Never _invalid() =>
    throw const FormatException('Invalid native database query');
int _bytes(Object? value) => utf8.encode(jsonEncode(value)).length;
Map<String, dynamic> _map(Object? value) {
  if (value is! Map || value.keys.any((key) => key is! String)) _invalid();
  return Map<String, dynamic>.from(value);
}

List<Object?> _list(Object? value) {
  if (value is! List) _invalid();
  return List<Object?>.from(value);
}

String _string(Object? value) {
  if (value is! String) _invalid();
  return value;
}

List<String> _strings(Object? value) =>
    _list(value).map(_string).toList(growable: false);
List<String> _rowIds(Object? value, Set<String> allowed) {
  final ids = _strings(value);
  if (ids.toSet().length != ids.length ||
      ids.any((id) => !allowed.contains(id)))
    _invalid();
  return ids;
}

DatabaseCalculationError _error(Object? raw) {
  final value = _map(raw);
  final code = _string(value['code']), message = _string(value['message']);
  final path = _strings(value['path']);
  if (code.isEmpty || code.length > 128 || message.isEmpty || path.length > 128)
    _invalid();
  return DatabaseCalculationError(code, message, List.unmodifiable(path));
}

List<DatabaseCalculationError> _errors(Object? raw) {
  final result = _list(raw).map(_error).toList(growable: false);
  final keys = <String>{};
  for (final error in result) {
    if (!keys.add(jsonEncode([error.code, error.path]))) _invalid();
  }
  return List.unmodifiable(result);
}

bool _containsError(
  List<DatabaseCalculationError> errors,
  DatabaseCalculationError error,
) => errors.any(
  (item) =>
      item.code == error.code &&
      const ListEquality<String>().equals(item.path, error.path),
);

DatabaseValue _value(Object? raw) {
  final value = _map(raw);
  if (!value.containsKey('value')) _invalid();
  if (value.containsKey('error')) {
    if (value['value'] != null) _invalid();
    return DatabaseValue(null, error: _error(value['error']));
  }
  return DatabaseValue(value['value']);
}

DatabaseCalendarItem _calendarItem(Object? raw) {
  final item = _map(raw);
  final id = _string(item['rowId']), start = _utc(item['start']);
  if (!item.containsKey('end') || item['allDay'] is! bool) _invalid();
  final end = item['end'] == null ? null : _utc(item['end']);
  if (end != null && end.isBefore(start)) _invalid();
  return DatabaseCalendarItem(
    rowId: id,
    start: start,
    end: end,
    allDay: item['allDay'] as bool,
  );
}

DateTime _utc(Object? raw) {
  final text = _string(raw);
  if (!text.contains('T') || !text.endsWith('Z')) _invalid();
  return parseDatabaseDate(text).start;
}

DatabaseChartPoint _chartPoint(Object? raw) {
  final point = _map(raw), value = point['value'];
  if (value is! num || !value.isFinite) _invalid();
  return DatabaseChartPoint(
    key: _string(point['key']),
    label: _string(point['label']),
    value: value,
    rowIds: _strings(point['rowIds']),
  );
}
