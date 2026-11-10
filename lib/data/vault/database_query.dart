import 'dart:convert';
import 'dart:math' as math;

import 'package:saber/data/vault/workspace_database.dart';

typedef DatabaseResolver = WorkspaceDatabase? Function(String databaseId);

class DatabaseCalculationError {
  const new(this.code, this.message, [this.path = const []]);
  final String code, message;
  final List<String> path;
  Map<String, dynamic> toJson() => {
    'code': code,
    'message': message,
    'path': List.of(path),
  };
}

class DatabaseValue {
  const new(this.value, {this.error});
  final Object? value;
  final DatabaseCalculationError? error;
  bool get isError => error != null;
  Map<String, dynamic> toJson() => {
    'value': _copy(value),
    if (error != null) 'error': error!.toJson(),
  };
}

class DatabaseQueryResult {
  new({
    required List<DatabaseRow> rows,
    Map<String, List<DatabaseRow>> groups = const {},
    List<DatabaseCalculationError> errors = const [],
  }) : rows = List.unmodifiable(rows),
       groups = Map.unmodifiable({
         for (final e in groups.entries)
           e.key: List<DatabaseRow>.unmodifiable(e.value),
       }),
       errors = List.unmodifiable(errors);
  final List<DatabaseRow> rows;
  final Map<String, List<DatabaseRow>> groups;
  final List<DatabaseCalculationError> errors;
}

class DatabaseChartPoint {
  new({
    required this.key,
    required this.label,
    required this.value,
    required List<String> rowIds,
  }) : rowIds = List.unmodifiable(rowIds);
  final String key, label;
  final num value;
  final List<String> rowIds;
}

class DatabaseCalendarItem {
  const new({
    required this.rowId,
    required this.start,
    required this.end,
    required this.allDay,
  });
  final String rowId;
  final DateTime start;
  final DateTime? end;
  final bool allDay;
}

class _Fault implements Exception {
  const new(this.code, this.message, [this.path = const []]);
  final String code, message;
  final List<String> path;
  DatabaseCalculationError get error =>
      DatabaseCalculationError(code, message, List.unmodifiable(path));
}

Never _fail(String code, [String message = '계산 입력이나 연산을 확인해 주세요.']) =>
    throw _Fault(code, message);

class DatabaseQuery {
  new(
    this.database, {
    this.resolver,
    this.now,
    this.maxDepth = 32,
    this.budget = 10000,
  }) {
    if (maxDepth < 1 || budget < 1)
      throw ArgumentError('Expected positive calculation limits');
    _databases[database.id] = database;
  }
  final WorkspaceDatabase database;
  final DatabaseResolver? resolver;
  final DateTime? now;
  final int maxDepth, budget;
  late int _remaining = budget;
  final _databases = <String, WorkspaceDatabase>{};
  final _cache = <String, Object?>{};
  final _parsed = <String, _Node>{};
  final _active = <String>[];
  final _errors = <DatabaseCalculationError>[];
  List<DatabaseCalculationError> get errors => List.unmodifiable(_errors);
  void _tick() {
    if (--_remaining < 0) _fail('budget_exceeded', '계산 작업 한도를 넘었습니다.');
  }

  void _record(DatabaseCalculationError error) {
    if (!_errors.any(
      (e) => e.code == error.code && e.path.join('/') == error.path.join('/'),
    ))
      _errors.add(error);
  }

  DatabaseValue value(DatabaseRow row, String propertyId) {
    try {
      final current = _row(database, row.id, false);
      return DatabaseValue(_freeze(_read(database, current, propertyId)));
    } on _Fault catch (e) {
      _record(e.error);
      return DatabaseValue(null, error: e.error);
    } on FormatException {
      final error = DatabaseCalculationError(
        'type_error',
        '계산 값의 형식이 올바르지 않습니다.',
        [database.id, row.id, propertyId],
      );
      _record(error);
      return DatabaseValue(null, error: error);
    }
  }

  DatabaseProperty _property(WorkspaceDatabase db, String id) {
    final byId = db.properties.where((p) => p.id == id).toList();
    if (byId.isNotEmpty) return byId.single;
    final names = db.properties.where((p) => p.name == id).toList();
    if (names.isEmpty) _fail('missing_property', '참조한 속성을 찾지 못했습니다.');
    if (names.length != 1)
      _fail('ambiguous_property', '같은 이름의 속성이 여러 개입니다. 속성 ID를 사용해 주세요.');
    return names.single;
  }

  DatabaseRow _row(WorkspaceDatabase db, String id, bool relation) {
    final rows = db.rows.where((r) => r.id == id && !r.archived).toList();
    if (rows.isEmpty)
      _fail(
        relation ? 'missing_relation' : 'missing_row',
        '참조한 항목이 없거나 보관 처리되었습니다.',
      );
    return rows.single;
  }

  WorkspaceDatabase _database(String id) {
    final cached = _databases[id];
    if (cached != null) return cached;
    final found = resolver?.call(id);
    if (found == null || found.id != id)
      _fail('missing_relation', '관계 대상 데이터베이스를 불러오지 못했습니다.');
    _databases[id] = found;
    return found;
  }

  Object? _read(WorkspaceDatabase db, DatabaseRow row, String id) {
    _tick();
    final property = _property(db, id);
    final key = '${db.id}/${row.id}/${property.id}';
    if (_cache.containsKey(key)) return _cache[key];
    if (_active.contains(key)) _fail('cycle', '수식이나 롤업 참조가 순환합니다.');
    if (_active.length >= maxDepth) _fail('depth_limit', '계산 참조 깊이 한도를 넘었습니다.');
    _active.add(key);
    try {
      Object? result;
      if (property.type == 'formula') {
        final expression = property.config['expression'];
        if (expression == null ||
            expression is String && expression.trim().isEmpty) {
          result = null;
        } else if (expression is! String) {
          _fail('parse_error', '수식을 읽지 못했습니다.');
        } else {
          final node = _parsed.putIfAbsent(
            expression,
            () => _Parser(expression, _tick, maxDepth).parse(),
          );
          result = _eval(node, db, row, 0);
        }
      } else if (property.type == 'rollup') {
        final relationId = property.config['relationPropertyId'];
        if (relationId is! String)
          _fail('missing_property', '롤업의 관계 속성을 선택해 주세요.');
        final relation = _property(db, relationId);
        if (relation.type != 'relation')
          _fail('type_error', '롤업에는 관계 속성이 필요합니다.');
        final refs = _relations(_read(db, row, relation.id));
        final target = property.config['targetPropertyId'];
        final calculation = property.config['calculation'] ?? 'count';
        if (calculation is! String) _fail('type_error', '롤업 집계 방식이 올바르지 않습니다.');
        if (target == null && ['count', 'countAll'].contains(calculation)) {
          result = refs.length;
        } else {
          if (target is! String)
            _fail('missing_property', '롤업의 대상 속성을 선택해 주세요.');
          result = _aggregate([
            for (final ref in refs) _read(ref.$1, ref.$2, target),
          ], calculation);
        }
      } else {
        result = row.values[property.id];
        if (property.type == 'relation') _relations(result);
      }
      _bounded(result);
      _cache[key] = result;
      return result;
    } on _Fault catch (e) {
      if (e.path.isEmpty) throw _Fault(e.code, e.message, List.of(_active));
      rethrow;
    } finally {
      _active.removeLast();
    }
  }

  List<(WorkspaceDatabase, DatabaseRow)> _relations(Object? raw) {
    if (raw == null) return [];
    final items = raw is List ? raw : [raw];
    final result = <(WorkspaceDatabase, DatabaseRow)>[];
    for (final item in items) {
      _tick();
      if (item is! Map ||
          item['databaseId'] is! String ||
          item['rowId'] is! String)
        _fail('type_error', '관계 값의 형식이 올바르지 않습니다.');
      final db = _database(item['databaseId'] as String);
      result.add((db, _row(db, item['rowId'] as String, true)));
    }
    return result;
  }

  Object? _eval(_Node node, WorkspaceDatabase db, DatabaseRow row, int depth) {
    _tick();
    if (depth > maxDepth) _fail('depth_limit', '수식 깊이 한도를 넘었습니다.');
    Object? at(int i) => _eval(node.children[i], db, row, depth + 1);
    if (node.kind == 'literal') return node.value;
    if (node.kind == 'list')
      return [for (var i = 0; i < node.children.length; i++) at(i)];
    if (node.kind == 'unary') {
      final v = at(0);
      return switch (node.value) {
        '!' => !_bool(v),
        '-' => _negate(_number(v)),
        '+' => _number(v),
        _ => _fail('parse_error'),
      };
    }
    if (node.kind == 'binary') {
      final a = at(0);
      if (node.value == '&&') return _bool(a) && _bool(at(1));
      if (node.value == '||') return _bool(a) || _bool(at(1));
      final b = at(1);
      return switch (node.value) {
        '+' => _arithmetic(_number(a), _number(b), '+'),
        '-' => _arithmetic(_number(a), _number(b), '-'),
        '*' => _arithmetic(_number(a), _number(b), '*'),
        '/' =>
          _number(b) == 0
              ? _fail('division_by_zero', '0으로 나눌 수 없습니다.')
              : _finite(_number(a) / _number(b)),
        '%' =>
          _number(b) == 0
              ? _fail('division_by_zero', '0으로 나눌 수 없습니다.')
              : _finite(_number(a) % _number(b)),
        '==' => _equal(a, b),
        '!=' => !_equal(a, b),
        '<' => _compare(a, b) < 0,
        '<=' => _compare(a, b) <= 0,
        '>' => _compare(a, b) > 0,
        '>=' => _compare(a, b) >= 0,
        _ => _fail('parse_error'),
      };
    }
    final name = (node.value as String).toLowerCase();
    final length = node.children.length;
    void arity(int min, [int? max]) {
      if (length < min || length > (max ?? min))
        _fail('argument_error', '수식 함수의 인자 수가 올바르지 않습니다.');
    }

    if (name == 'if') {
      arity(3);
      return _bool(at(0)) ? at(1) : at(2);
    }
    if (name == 'and' || name == 'or') {
      for (var i = 0; i < length; i++) {
        final v = _bool(at(i));
        if (name == 'and' && !v) return false;
        if (name == 'or' && v) return true;
      }
      return name == 'and';
    }
    if (name == 'prop') {
      arity(1);
      final id = at(0);
      if (id is! String) _fail('type_error');
      return _read(db, row, id);
    }
    if (name == 'now' || name == 'today') {
      arity(0);
      if (now == null)
        _fail('clock_required', '현재 시각을 사용하는 수식에는 캡처한 시각이 필요합니다.');
      final utc = now!.toUtc();
      return name == 'now' ? utc.toIso8601String() : _day(utc);
    }
    final args = [for (var i = 0; i < length; i++) at(i)];
    Object? arg(int i) => args[i];
    switch (name) {
      case 'concat':
        return _join(args, '');
      case 'empty':
        arity(1);
        return _empty(arg(0));
      case 'length':
        arity(1);
        final v = arg(0);
        if (v is String) return v.runes.length;
        if (v is List || v is Map) return (v as dynamic).length as int;
        _fail('type_error');
      case 'sum':
      case 'average':
      case 'min':
      case 'max':
      case 'count':
        return _aggregate([
          for (final v in args)
            if (v is List) ...v else v,
        ], name);
      case 'not':
        arity(1);
        return !_bool(arg(0));
      case 'abs':
        arity(1);
        final v = _number(arg(0));
        return v < 0 ? _negate(v) : v;
      case 'floor':
        arity(1);
        return _number(arg(0)).floorToDouble();
      case 'ceil':
        arity(1);
        return _number(arg(0)).ceilToDouble();
      case 'round':
        arity(1, 2);
        final places = length == 2 ? _number(arg(1)) : 0;
        if (places < -12 || places > 12 || places != places.truncate())
          _fail('argument_error');
        final digits = places.toInt();
        final scale = math.pow(10, digits).toDouble();
        return _finite(
          _finite(_number(arg(0)) * scale).roundToDouble() / scale,
        );
      case 'lower':
        arity(1);
        return _text(arg(0)).toLowerCase();
      case 'upper':
        arity(1);
        return _text(arg(0)).toUpperCase();
      case 'trim':
        arity(1);
        return _text(arg(0)).trim();
      case 'contains':
        arity(2);
        final v = arg(0);
        if (v is List) return v.any((e) => _equal(e, arg(1)));
        return _text(v).contains(_text(arg(1)));
      case 'replace':
        arity(3);
        final source = _text(arg(0)),
            pattern = _text(arg(1)),
            replacement = _text(arg(2));
        final matches = _matchesCount(source, pattern, _tick);
        if (source.length + matches * (replacement.length - pattern.length) >
            _maxResultUnits)
          _fail('result_limit', '수식 결과 크기 한도를 넘었습니다.');
        return source.replaceAll(pattern, replacement);
      case 'split':
        arity(2);
        final source = _text(arg(0)), pattern = _text(arg(1));
        if (_matchesCount(source, pattern, _tick) > 10000)
          _fail('result_limit', '수식 목록 길이 한도를 넘었습니다.');
        return source.split(pattern);
      case 'join':
        arity(2);
        if (arg(0) is! List) _fail('type_error');
        return _join(arg(0) as List, _text(arg(1)));
      case 'date':
      case 'datestart':
        arity(1);
        return _date(arg(0)).toIso8601String();
      case 'dateend':
        arity(1);
        final range = _range(arg(0));
        return (range.end ?? range.start).toIso8601String();
      case 'dateadd':
        arity(3);
        return _dateAdd(
          _date(arg(0)),
          _number(arg(1)),
          _text(arg(2)),
        ).toIso8601String();
      case 'datebetween':
        arity(3);
        final duration = _date(arg(0)).difference(_date(arg(1)));
        return switch (_text(arg(2)).toLowerCase()) {
          'seconds' => duration.inSeconds,
          'minutes' => duration.inMinutes,
          'hours' => duration.inHours,
          'days' => duration.inDays,
          'weeks' => duration.inDays ~/ 7,
          _ => _fail('argument_error', '지원하지 않는 날짜 단위입니다.'),
        };
      case 'year':
        arity(1);
        return _date(arg(0)).year;
      case 'month':
        arity(1);
        return _date(arg(0)).month;
      case 'day':
        arity(1);
        return _date(arg(0)).day;
      case 'weekday':
        arity(1);
        return _date(arg(0)).weekday;
      case 'formatdate':
        arity(2);
        final date = _date(arg(0));
        var pattern = _text(arg(1));
        if (pattern.length > 128) _fail('argument_error');
        for (final e in {
          'YYYY': date.year.toString().padLeft(4, '0'),
          'MM': date.month.toString().padLeft(2, '0'),
          'DD': date.day.toString().padLeft(2, '0'),
          'HH': date.hour.toString().padLeft(2, '0'),
          'mm': date.minute.toString().padLeft(2, '0'),
          'ss': date.second.toString().padLeft(2, '0'),
        }.entries) {
          pattern = pattern.replaceAll(e.key, e.value);
        }
        return pattern;
      default:
        _fail('unsupported_function', '이 수식 함수는 지원하지 않습니다.');
    }
  }

  DatabaseQueryResult apply(DatabaseView view) {
    final selected = <DatabaseRow>[];
    for (final row in database.rows.where((r) => !r.archived)) {
      try {
        if (view.filter == null || _matches(row, view.filter!, 0))
          selected.add(row);
      } on _Fault catch (e) {
        _record(e.error);
      }
    }
    final order = {for (var i = 0; i < selected.length; i++) selected[i].id: i};
    final keys = <String, List<Object?>>{};
    try {
      for (final row in selected) {
        keys[row.id] = [for (final sort in view.sorts) _sortValue(row, sort)];
      }
      selected.sort((a, b) {
        for (var i = 0; i < view.sorts.length; i++) {
          final av = keys[a.id]![i], bv = keys[b.id]![i];
          if (av == null && bv == null) continue;
          if (av == null) return 1;
          if (bv == null) return -1;
          final result = _sortCompare(av, bv);
          if (result != 0) {
            final direction = view.sorts[i]['direction'] ?? 'ascending';
            return ['descending', 'desc'].contains(direction)
                ? -result
                : result;
          }
        }
        return order[a.id]!.compareTo(order[b.id]!);
      });
    } on _Fault catch (e) {
      _record(e.error);
    }
    final groups = <String, List<DatabaseRow>>{};
    if (view.groupBy != null) {
      for (final row in selected) {
        final result = value(row, view.groupBy!);
        if (result.isError) continue;
        final isDate = _property(database, view.groupBy!).type == 'date';
        final items = result.value is List
            ? result.value as List
            : [result.value];
        for (final key
            in (items.isEmpty
                    ? ['']
                    : items.map(
                        (v) => isDate && v != null ? _day(_date(v)) : _key(v),
                      ))
                .toSet()) {
          groups.putIfAbsent(key, () => []).add(row);
        }
      }
    }
    return DatabaseQueryResult(rows: selected, groups: groups, errors: _errors);
  }

  Object? _sortValue(DatabaseRow row, Map<String, dynamic> sort) {
    _tick();
    final id = sort['propertyId'] ?? sort['property'];
    if (id is! String) _fail('invalid_sort', '정렬 속성이 올바르지 않습니다.');
    final direction = sort['direction'] ?? 'ascending';
    if (!['ascending', 'descending', 'asc', 'desc'].contains(direction))
      _fail('invalid_sort');
    final result = value(row, id);
    if (result.isError) return null;
    if (result.value == null) return null;
    return _property(database, id).type == 'date'
        ? _date(result.value)
        : result.value;
  }

  bool _matches(DatabaseRow row, Map<String, dynamic> filter, int depth) {
    _tick();
    if (depth > maxDepth) _fail('depth_limit');
    for (final key in ['and', 'or']) {
      if (filter.containsKey(key)) {
        if (filter.length != 1 || filter[key] is! List) _fail('invalid_filter');
        final items = filter[key] as List;
        if (key == 'and') {
          for (final item in items) {
            if (item is! Map) _fail('invalid_filter', '필터 조건을 읽지 못했습니다.');
            if (!_matches(row, Map<String, dynamic>.from(item), depth + 1))
              return false;
          }
          return true;
        }
        for (final item in items) {
          if (item is! Map) _fail('invalid_filter');
          if (_matches(row, Map<String, dynamic>.from(item), depth + 1))
            return true;
        }
        return false;
      }
    }
    final id = filter['propertyId'] ?? filter['property'];
    final op = filter['operator'] ?? filter['op'];
    if (id is! String || op is! String) _fail('invalid_filter');
    final a = _read(database, row, id), b = filter['value'];
    if (op == 'isEmpty') return _empty(a);
    if (op == 'isNotEmpty') return !_empty(a);
    if (op == 'contains' || op == 'notContains') {
      final contains = a is List
          ? a.any((v) => _equal(v, b))
          : a is String &&
                b is String &&
                a.toLowerCase().contains(b.toLowerCase());
      return op == 'contains' ? contains : !contains;
    }
    if (op == 'startsWith' || op == 'endsWith') {
      if (a == null) return false;
      return op == 'startsWith'
          ? _text(a).toLowerCase().startsWith(_text(b).toLowerCase())
          : _text(a).toLowerCase().endsWith(_text(b).toLowerCase());
    }
    if (op == 'in' || op == 'notIn') {
      if (b is! List) _fail('invalid_filter');
      final found = b.any((v) => _equal(v, a));
      return op == 'in' ? found : !found;
    }
    final date = _property(database, id).type == 'date';
    if (op == 'equals' || op == 'notEquals') {
      final same = date && a != null && b != null
          ? _date(a).isAtSameMomentAs(_date(b))
          : _equal(a, b);
      return op == 'equals' ? same : !same;
    }
    if (a == null || b == null) return false;
    final av = date ? _date(a) : a, bv = date ? _date(b) : b;
    final cmp = _compare(av, bv);
    return switch (op) {
      'gt' || 'after' => cmp > 0,
      'gte' || 'onOrAfter' => cmp >= 0,
      'lt' || 'before' => cmp < 0,
      'lte' || 'onOrBefore' => cmp <= 0,
      _ => _fail('invalid_filter', '지원하지 않는 필터 조건입니다.'),
    };
  }

  DatabaseValue aggregate(
    String propertyId, {
    String calculation = 'sum',
    List<DatabaseRow>? rows,
    DatabaseView? view,
  }) {
    try {
      final selected =
          rows ??
          (view == null
              ? database.rows.where((r) => !r.archived).toList()
              : apply(view).rows);
      return DatabaseValue(
        _freeze(
          _aggregate([
            for (final row in selected)
              _read(database, _row(database, row.id, false), propertyId),
          ], calculation),
        ),
      );
    } on _Fault catch (e) {
      _record(e.error);
      return DatabaseValue(null, error: e.error);
    }
  }

  List<DatabaseChartPoint> chart({
    required String groupBy,
    String? valuePropertyId,
    String calculation = 'count',
    DatabaseView? view,
  }) {
    try {
      final selected = apply(
        (view ?? DatabaseView.create()).copyWith(groupBy: groupBy),
      );
      final points = <DatabaseChartPoint>[];
      for (final group in selected.groups.entries) {
        final result = valuePropertyId == null && calculation == 'count'
            ? DatabaseValue(group.value.length)
            : aggregate(
                valuePropertyId ?? '',
                rows: group.value,
                calculation: calculation,
              );
        if (result.isError) continue;
        final v = result.value;
        if (v != null && v is! num) _fail('type_error', '차트에는 숫자 집계가 필요합니다.');
        points.add(
          DatabaseChartPoint(
            key: group.key,
            label: _label(_property(database, groupBy), group.key),
            value: (v as num?) ?? 0,
            rowIds: group.value.map((r) => r.id).toList(),
          ),
        );
      }
      return List.unmodifiable(points);
    } on _Fault catch (e) {
      _record(e.error);
      return [];
    }
  }

  List<DatabaseCalendarItem> calendar({
    required String propertyId,
    DatabaseView? view,
  }) {
    final selected = view == null
        ? database.rows.where((r) => !r.archived).toList()
        : apply(view).rows;
    final result = <DatabaseCalendarItem>[];
    for (final row in selected) {
      try {
        final raw = _read(database, row, propertyId);
        if (raw == null) continue;
        final date = _range(raw);
        result.add(
          DatabaseCalendarItem(
            rowId: row.id,
            start: date.start,
            end: date.end,
            allDay: date.allDay,
          ),
        );
      } on _Fault catch (e) {
        _record(e.error);
      }
    }
    final order = {
      for (var index = 0; index < selected.length; index++)
        selected[index].id: index,
    };
    result.sort((a, b) {
      final start = a.start.compareTo(b.start);
      return start != 0 ? start : order[a.rowId]!.compareTo(order[b.rowId]!);
    });
    return List.unmodifiable(result);
  }
}

num _number(Object? value) {
  if (value is! num || !value.isFinite) _fail('type_error', '숫자가 필요한 계산입니다.');
  return value;
}

num _finite(num value) {
  if (!value.isFinite) _fail('numeric_overflow', '계산 값이 숫자 범위를 넘습니다.');
  return value;
}

bool _bool(Object? value) {
  if (value is! bool) _fail('type_error', '논리 값이 필요한 계산입니다.');
  return value;
}

String _text(Object? value) {
  if (value is! String) _fail('type_error', '문자 값이 필요한 계산입니다.');
  return value;
}

String _string(Object? value) => value == null
    ? ''
    : value is String
    ? value
    : jsonEncode(value);
bool _empty(Object? value) =>
    value == null ||
    value == '' ||
    value is List && value.isEmpty ||
    value is Map && value.isEmpty;
bool _equal(Object? a, Object? b) {
  if (a is List && b is List)
    return a.length == b.length &&
        List.generate(a.length, (i) => i).every((i) => _equal(a[i], b[i]));
  if (a is Map && b is Map)
    return a.length == b.length &&
        a.keys.every((k) => b.containsKey(k) && _equal(a[k], b[k]));
  return a == b;
}

int _compare(Object? a, Object? b) {
  if (a is num && b is num) return a.compareTo(b);
  if (a is String && b is String) return a.compareTo(b);
  if (a is bool && b is bool) return (a ? 1 : 0).compareTo(b ? 1 : 0);
  if (a is DateTime && b is DateTime) return a.compareTo(b);
  _fail('type_error', '서로 비교할 수 없는 값입니다.');
}

int _sortCompare(Object a, Object b) {
  int rank(Object v) => v is num
      ? 0
      : v is bool
      ? 1
      : v is String
      ? 2
      : v is DateTime
      ? 3
      : 4;
  final r = rank(a).compareTo(rank(b));
  if (r != 0) return r;
  if (a is String && b is String)
    return a.toLowerCase().compareTo(b.toLowerCase());
  if (rank(a) == 4) return jsonEncode(a).compareTo(jsonEncode(b));
  return _compare(a, b);
}

Object? _aggregate(List<Object?> values, String calculation) {
  if (![
    'showOriginal',
    'showUnique',
    'countAll',
    'count',
    'countEmpty',
    'sum',
    'average',
    'min',
    'max',
  ].contains(calculation))
    _fail('unsupported_aggregate', '지원하지 않는 집계입니다.');
  _bounded(values);
  if (calculation == 'showOriginal') return List.unmodifiable(values);
  if (calculation == 'showUnique') {
    final result = <Object?>[], seen = <String>{};
    for (final v in values) {
      if (seen.add(_uniqueKey(v))) result.add(v);
    }
    return result;
  }
  if (calculation == 'countAll') return values.length;
  final nonempty = values.where((v) => !_empty(v)).toList();
  if (calculation == 'count') return nonempty.length;
  if (calculation == 'countEmpty') return values.length - nonempty.length;
  final numbers = nonempty.map(_number).toList();
  if (calculation == 'sum')
    return numbers.fold<num>(0, (a, b) => _arithmetic(a, b, '+'));
  if (numbers.isEmpty) return null;
  return switch (calculation) {
    'average' => _finite(
      numbers.fold<num>(0, (a, b) => _arithmetic(a, b, '+')) / numbers.length,
    ),
    'min' => numbers.reduce(math.min),
    'max' => numbers.reduce(math.max),
    _ => _fail('unsupported_aggregate', '지원하지 않는 집계입니다.'),
  };
}

({DateTime start, DateTime? end, bool allDay}) _range(Object? value) {
  try {
    return parseDatabaseDate(value);
  } on FormatException {
    _fail('type_error', '올바른 ISO 날짜가 필요합니다.');
  }
}

DateTime _date(Object? value) => _range(value).start;
String _day(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
DateTime _dateAdd(DateTime date, num amount, String unit) {
  if (amount < -1000000 || amount > 1000000 || amount != amount.truncate())
    _fail('argument_error', '날짜 이동에는 한도 안의 정수가 필요합니다.');
  final n = amount.toInt();
  try {
    switch (unit.toLowerCase()) {
      case 'seconds':
        return date.add(Duration(seconds: n));
      case 'minutes':
        return date.add(Duration(minutes: n));
      case 'hours':
        return date.add(Duration(hours: n));
      case 'days':
        return date.add(Duration(days: n));
      case 'weeks':
        return date.add(Duration(days: n * 7));
      case 'months':
      case 'years':
        final month = date.month + (unit.toLowerCase() == 'years' ? n * 12 : n);
        final anchor = DateTime.utc(date.year, month, 1);
        final day = math.min(
          date.day,
          DateTime.utc(anchor.year, anchor.month + 1, 0).day,
        );
        return DateTime.utc(
          anchor.year,
          anchor.month,
          day,
          date.hour,
          date.minute,
          date.second,
          date.millisecond,
          date.microsecond,
        );
      default:
        _fail('argument_error', '지원하지 않는 날짜 단위입니다.');
    }
  } on RangeError {
    _fail('numeric_overflow', '날짜 범위를 넘었습니다.');
  }
}

String _key(Object? v) {
  if (v == null) return '';
  if (v is String) return v;
  if (v is Map && v['databaseId'] is String && v['rowId'] is String)
    return '${v['databaseId']}/${v['rowId']}';
  return jsonEncode(v);
}

String _label(DatabaseProperty property, String key) {
  if (key.isEmpty) return '비어 있음';
  final options = property.config['options'];
  if (options is List) {
    for (final option in options) {
      if (option is Map && option['id'] == key && option['name'] is String)
        return option['name'] as String;
    }
  }
  return key;
}

Object? _copy(Object? v) {
  if (v is List) return v.map(_copy).toList();
  if (v is Map) return {for (final e in v.entries) e.key: _copy(e.value)};
  return v;
}

Object? _freeze(Object? v) {
  if (v is List) return List.unmodifiable(v.map(_freeze));
  if (v is Map)
    return Map.unmodifiable({
      for (final e in v.entries) e.key: _freeze(e.value),
    });
  return v;
}

class _Node {
  const new(this.kind, this.value, [this.children = const []]);
  final String kind;
  final Object? value;
  final List<_Node> children;
}

class _Token {
  const new(this.kind, this.value);
  final String kind;
  final Object? value;
}

class _Parser {
  new(this.source, this.tick, this.limit) {
    if (source.length > 8192) _fail('budget_exceeded', '수식 길이 한도를 넘었습니다.');
    _scan();
  }
  final String source;
  final void Function() tick;
  final int limit;
  final tokens = <_Token>[];
  var position = 0, depth = 0;
  void _scan() {
    var i = 0;
    while (i < source.length) {
      tick();
      final c = source[i];
      if (RegExp(r'\s').hasMatch(c)) {
        i++;
        continue;
      }
      if (c == '"' || c == "'") {
        final quote = c;
        final buffer = StringBuffer();
        i++;
        var closed = false;
        while (i < source.length) {
          var ch = source[i++];
          if (ch == quote) {
            closed = true;
            break;
          }
          if (ch == '\\') {
            if (i >= source.length) _fail('parse_error');
            ch = source[i++];
            switch (ch) {
              case 'n':
                buffer.write('\n');
              case 'r':
                buffer.write('\r');
              case 't':
                buffer.write('\t');
              case 'b':
                buffer.write('\b');
              case 'f':
                buffer.write('\f');
              case 'u':
                if (i + 4 > source.length) _fail('parse_error');
                final escaped = source.substring(i, i + 4);
                if (!RegExp(r'^[0-9a-fA-F]{4}$').hasMatch(escaped))
                  _fail('parse_error');
                final code = int.parse(escaped, radix: 16);
                buffer.writeCharCode(code);
                i += 4;
              case '"':
              case "'":
              case '\\':
              case '/':
                buffer.write(ch);
              default:
                _fail('parse_error');
            }
          } else {
            buffer.write(ch);
          }
        }
        if (!closed) _fail('parse_error', '문자열 따옴표가 닫히지 않았습니다.');
        tokens.add(_Token('literal', buffer.toString()));
        continue;
      }
      final number = RegExp(r'(?:\d+(?:\.\d+)?|\.\d+)(?:[eE][+-]?\d+)?')
          .matchAsPrefix(source, i);
      if (number != null) {
        final value = num.tryParse(number[0]!);
        if (value == null || !value.isFinite) _fail('numeric_overflow');
        tokens.add(_Token('literal', value));
        i = number.end;
        continue;
      }
      final identifier = RegExp(r'[A-Za-z_][A-Za-z0-9_]*')
          .matchAsPrefix(source, i);
      if (identifier != null) {
        final name = identifier[0]!;
        tokens.add(switch (name) {
          'true' => const _Token('literal', true),
          'false' => const _Token('literal', false),
          'null' => const _Token('literal', null),
          _ => _Token('identifier', name),
        });
        i = identifier.end;
        continue;
      }
      final pair = i + 1 < source.length ? source.substring(i, i + 2) : '';
      if (['&&', '||', '==', '!=', '<=', '>='].contains(pair)) {
        tokens.add(_Token(pair, pair));
        i += 2;
        continue;
      }
      if ('+-*/%<>()[],!'.contains(c)) {
        tokens.add(_Token(c, c));
        i++;
        continue;
      }
      _fail('parse_error', '허용하지 않는 수식 문자가 있습니다.');
    }
    tokens.add(const _Token('eof', null));
  }

  _Token get current => tokens[position];
  bool take(String kind) {
    if (current.kind != kind) return false;
    position++;
    return true;
  }

  void require(String kind) {
    if (!take(kind)) _fail('parse_error', '수식 괄호나 구분자가 올바르지 않습니다.');
  }

  _Node parse() {
    final node = expression(0);
    if (current.kind != 'eof') _fail('parse_error');
    return node;
  }

  static const precedence = {
    '||': 1,
    '&&': 2,
    '==': 3,
    '!=': 3,
    '<': 4,
    '<=': 4,
    '>': 4,
    '>=': 4,
    '+': 5,
    '-': 5,
    '*': 6,
    '/': 6,
    '%': 6,
  };
  _Node expression(int min) {
    tick();
    if (++depth > limit) _fail('depth_limit');
    try {
      _Node left;
      if (['!', '-', '+'].contains(current.kind)) {
        final op = current.kind;
        position++;
        left = _Node('unary', op, [expression(7)]);
      } else if (current.kind == 'literal') {
        left = _Node('literal', current.value);
        position++;
      } else if (take('(')) {
        left = expression(0);
        require(')');
      } else if (take('[')) {
        final children = <_Node>[];
        if (!take(']')) {
          do {
            children.add(expression(0));
          } while (take(','));
          require(']');
        }
        left = _Node('list', null, children);
      } else if (current.kind == 'identifier') {
        final name = current.value;
        position++;
        require('(');
        final args = <_Node>[];
        if (!take(')')) {
          do {
            args.add(expression(0));
          } while (take(','));
          require(')');
        }
        left = _Node('call', name, args);
      } else {
        _fail('parse_error', '수식 값을 읽지 못했습니다.');
      }
      while ((precedence[current.kind] ?? -1) >= min) {
        final op = current.kind, level = precedence[current.kind]!;
        position++;
        left = _Node('binary', op, [left, expression(level + 1)]);
      }
      return left;
    } finally {
      depth--;
    }
  }
}

const _maxResultUnits = 1000000;
final _maxInteger = BigInt.parse('9223372036854775807');
final _minInteger = -_maxInteger - BigInt.one;
num _integerResult(BigInt value) {
  if (value > _maxInteger || value < _minInteger)
    _fail('numeric_overflow', '정수 계산 범위를 넘었습니다.');
  return value.toInt();
}

num _arithmetic(num a, num b, String operator) {
  if (a is int && b is int) {
    final x = BigInt.from(a), y = BigInt.from(b);
    return _integerResult(switch (operator) {
      '+' => x + y,
      '-' => x - y,
      '*' => x * y,
      _ => _fail('argument_error'),
    });
  }
  return _finite(switch (operator) {
    '+' => a + b,
    '-' => a - b,
    '*' => a * b,
    _ => _fail('argument_error'),
  });
}

num _negate(num value) =>
    value is int ? _integerResult(-BigInt.from(value)) : _finite(-value);
void _bounded(Object? value) {
  var units = 0, nodes = 0;
  void visit(Object? v, int depth) {
    if (++nodes > 10000 || depth > 64)
      _fail('result_limit', '계산 결과 구조 한도를 넘었습니다.');
    if (v is String) {
      units += v.length;
    } else if (v is List) {
      for (final item in v) {
        visit(item, depth + 1);
      }
    } else if (v is Map) {
      for (final entry in v.entries) {
        units += entry.key.toString().length;
        visit(entry.value, depth + 1);
      }
    } else if (v is num && !v.isFinite) {
      _fail('numeric_overflow');
    }
    if (units > _maxResultUnits) _fail('result_limit', '계산 결과 크기 한도를 넘었습니다.');
  }

  visit(value, 0);
}

String _join(List<Object?> values, String separator) {
  final strings = <String>[];
  var length = 0;
  for (final value in values) {
    _bounded(value);
    final string = _string(value);
    length += string.length + (strings.isEmpty ? 0 : separator.length);
    if (length > _maxResultUnits) _fail('result_limit', '계산 결과 크기 한도를 넘었습니다.');
    strings.add(string);
  }
  return strings.join(separator);
}

int _matchesCount(String source, String pattern, [void Function()? tick]) {
  for (var i = 0; i < source.length; i += 64) {
    tick?.call();
  }
  if (pattern.isEmpty) return source.length + 1;
  var count = 0, position = 0;
  while (true) {
    final match = source.indexOf(pattern, position);
    if (match < 0) return count;
    count++;
    tick?.call();
    position = match + pattern.length;
  }
}

String _uniqueKey(Object? value) => jsonEncode(_uniqueStructure(value));
Object? _uniqueStructure(Object? value) {
  if (value == null) return ['null'];
  if (value is num && value == value.truncateToDouble())
    return ['number', BigInt.from(value).toString()];
  if (value is num) return ['number', value.toString()];
  if (value is bool) return ['bool', value];
  if (value is String) return ['string', value];
  if (value is List)
    return [
      'list',
      [for (final item in value) _uniqueStructure(item)],
    ];
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return [
      'map',
      [
        for (final key in keys) [key, _uniqueStructure(value[key])],
      ],
    ];
  }
  _fail('type_error');
}
