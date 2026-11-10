import 'dart:convert';

import 'package:crypto/crypto.dart' show sha256;
import 'package:ink_vault_core/ink_vault_core.dart' show newId, validateId;

import 'package:saber/data/vault/block_page_document.dart';

part 'workspace_database_row_template.dart';
part 'workspace_database_task_links.dart';

const _rowTemplatesKey = 'pivRowTemplates';
const _taskLinksKey = 'pivTaskLinks';

const databasePropertyTypes = [
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
  'people',
  'files',
  'relation',
  'formula',
  'rollup',
];
const databaseViewTypes = [
  'table',
  'board',
  'list',
  'gallery',
  'calendar',
  'timeline',
  'chart',
];
const databaseDashboardViewType = 'dashboard';

class WorkspaceDatabase {
  new _(
    this.id,
    List<DatabaseProperty> properties,
    List<DatabaseRow> rows,
    List<DatabaseView> views,
    List<DatabaseRowTemplate> rowTemplates,
    Map<String, dynamic> extra,
  ) : properties = List.unmodifiable(properties),
      rows = List.unmodifiable(rows),
      views = List.unmodifiable(views),
      rowTemplates = List.unmodifiable(rowTemplates),
      _extra = _freezeMap(extra) {
    _unique(properties.map((p) => p.id));
    _unique(rows.map((r) => r.id));
    _unique(views.map((v) => v.id));
    _unique(rowTemplates.map((template) => template.id));
    if (rowTemplates.length > maxRowTemplates) {
      throw const FormatException('Too many database row templates');
    }
    if (rowTemplates.isNotEmpty && _extra.containsKey(_rowTemplatesKey)) {
      throw const FormatException(
        'The row template namespace contains opaque data',
      );
    }
    final fields = {for (final property in properties) property.id: property};
    for (final row in rows) {
      for (final entry in row.values.entries) {
        fields[entry.key]?.validateValue(entry.value);
      }
    }
  }
  factory empty({String? id}) => WorkspaceDatabase._(
    _id(id ?? newId()),
    [DatabaseProperty.create(name: '이름', type: 'title')],
    [],
    [DatabaseView.create()],
    [],
    {},
  );
  factory fromJson(Map<String, dynamic> json) {
    final root = Map<String, dynamic>.of(json);
    final envelope = root[_rowTemplatesKey];
    final List<dynamic> templates;
    if (envelope is Map &&
        envelope.length == 2 &&
        identical(envelope['schemaVersion'], 1) &&
        envelope['items'] is List) {
      templates = _list(envelope['items']);
      // The new envelope must not consume the existing row body's nesting budget.
      root.remove(_rowTemplatesKey);
    } else {
      templates = const [];
    }
    if (templates.length > maxRowTemplates) {
      throw const FormatException('Too many database row templates');
    }
    final raw = _copyMap(root);
    final version = raw.remove('schemaVersion') ?? 1;
    if (version != 1)
      throw const FormatException('Unsupported database schema');
    final id = _id(raw.remove('id'));
    final properties = _list(raw.remove('properties') ?? []),
        rows = _list(raw.remove('rows') ?? []),
        views = _list(raw.remove('views') ?? []);
    return WorkspaceDatabase._(
      id,
      [for (final p in properties) DatabaseProperty.fromJson(_object(p))],
      [for (final r in rows) DatabaseRow.fromJson(_object(r))],
      [for (final v in views) DatabaseView.fromJson(_object(v))],
      [for (final t in templates) DatabaseRowTemplate.fromJson(_object(t))],
      raw,
    );
  }
  final String id;
  final List<DatabaseProperty> properties;
  final List<DatabaseRow> rows;
  final List<DatabaseView> views;
  final List<DatabaseRowTemplate> rowTemplates;
  static const maxRowTemplates = 100;
  final Map<String, dynamic> _extra;
  late final _taskLinks = _extra.containsKey(_taskLinksKey)
      ? _readTaskLinks(_extra[_taskLinksKey])
      : const <String, DatabaseTaskLink>{};
  bool get supportsTaskLinks => _taskLinks != null;
  Map<String, DatabaseTaskLink> get taskLinks => _taskLinks ?? const {};
  Map<String, dynamic>? get taskLinksEnvelope {
    final raw = _extra[_taskLinksKey];
    return supportsTaskLinks && raw is Map<String, dynamic>
        ? _copyMap(raw)
        : null;
  }

  WorkspaceDatabase withTaskLinks(Map<String, dynamic> envelope) {
    if (!supportsTaskLinks)
      throw const FormatException('Unsupported task links envelope');
    if (_readTaskLinks(envelope) == null)
      throw const FormatException('Invalid task links envelope');
    return _replaceTaskLinks(envelope, rows);
  }

  WorkspaceDatabase _replaceTaskLinks(
    Map<String, dynamic> envelope,
    List<DatabaseRow> rows,
  ) {
    final extra = {..._extra};
    if ((envelope['items'] as Map).isEmpty) {
      extra.remove(_taskLinksKey);
    } else {
      extra[_taskLinksKey] = envelope;
    }
    return WorkspaceDatabase._(
      id,
      properties,
      rows,
      views,
      rowTemplates,
      extra,
    );
  }

  int get schemaVersion => 1;
  Map<String, dynamic> toJson() => {
    ..._copyMap(_extra),
    'schemaVersion': 1,
    'id': id,
    'properties': [for (final p in properties) p.toJson()],
    'rows': [for (final r in rows) r.toJson()],
    'views': [for (final v in views) v.toJson()],
    if (rowTemplates.isNotEmpty)
      _rowTemplatesKey: {
        'schemaVersion': 1,
        'items': [for (final template in rowTemplates) template.toJson()],
      },
  };
  WorkspaceDatabase copyWith({
    List<DatabaseProperty>? properties,
    List<DatabaseRow>? rows,
    List<DatabaseView>? views,
    List<DatabaseRowTemplate>? rowTemplates,
  }) => WorkspaceDatabase._(
    id,
    properties ?? this.properties,
    rows ?? this.rows,
    views ?? this.views,
    rowTemplates ?? this.rowTemplates,
    _extra,
  );
  WorkspaceDatabase addProperty(DatabaseProperty property) =>
      copyWith(properties: [...properties, property]);
  WorkspaceDatabase updateProperty(DatabaseProperty property) {
    _exists(properties.map((p) => p.id), property.id);
    return copyWith(
      properties: [
        for (final p in properties)
          if (p.id == property.id) property else p,
      ],
    );
  }

  WorkspaceDatabase renameProperty(String id, String name) => updateProperty(
    properties
        .firstWhere(
          (p) => p.id == id,
          orElse: () => throw const FormatException('Missing property'),
        )
        .copyWith(name: name),
  );
  WorkspaceDatabase removeProperty(String id) {
    _exists(properties.map((p) => p.id), id);
    return copyWith(properties: properties.where((p) => p.id != id).toList());
  }

  WorkspaceDatabase addRow(DatabaseRow row) => copyWith(rows: [...rows, row]);

  WorkspaceDatabase captureRowTemplate({
    required String rowId,
    required String templateId,
    required String name,
  }) {
    final source = rows
        .where((row) => row.id == rowId && !row.archived)
        .singleOrNull;
    if (source == null)
      throw const FormatException('Missing active template source row');
    final fields = [
      for (final property in properties)
        if (_editableTemplateField(property) &&
            source.values.containsKey(property.id))
          property,
    ];
    final template = DatabaseRowTemplate.fromJson({
      'id': templateId,
      'name': name,
      'values': {for (final field in fields) field.id: source.values[field.id]},
      'propertyTypes': {for (final field in fields) field.id: field.type},
      'body': _copyTemplateBody(source.body),
    });
    return copyWith(rowTemplates: [...rowTemplates, template]);
  }

  WorkspaceDatabase removeRowTemplate(String templateId) {
    _exists(rowTemplates.map((template) => template.id), templateId);
    final rules = _extra['automationRules'];
    if (rules is List &&
        rules.whereType<Map>().any((rule) {
          if (rule['archived'] == true && rule['enabled'] == false)
            return false;
          final actions = rule['actions'];
          return actions is List &&
              actions.whereType<Map>().any(
                (action) =>
                    action['type'] == 'addRowFromTemplate' &&
                    action['templateId'] == templateId,
              );
        })) {
      throw const FormatException('이 템플릿을 사용하는 반복 일정을 먼저 보관하거나 변경하세요.');
    }
    return copyWith(
      rowTemplates: [
        for (final template in rowTemplates)
          if (template.id != templateId) template,
      ],
    );
  }

  DatabaseRow instantiateRowTemplate({
    required String templateId,
    required String rowId,
    Map<String, dynamic> overrides = const {},
  }) {
    validateId(rowId);
    if (rows.any((row) => row.id == rowId)) {
      throw const FormatException('Duplicate database identity');
    }
    final template = rowTemplates
        .where((item) => item.id == templateId)
        .singleOrNull;
    if (template == null)
      throw const FormatException('Missing database row template');
    final fields = {
      for (final property in properties)
        if (_editableTemplateField(property)) property.id: property,
    };
    final values = <String, Object?>{};
    for (final entry in template.values.entries) {
      final field = fields[entry.key];
      if (field == null || field.type != template._propertyTypes[entry.key])
        continue;
      try {
        field.validateValue(entry.value);
        values[entry.key] = entry.value;
      } on FormatException {
        // The captured default may reference a selection or relation that changed.
      }
    }
    for (final entry in overrides.entries) {
      final field = fields[entry.key];
      if (field == null)
        throw const FormatException('Missing or read-only template field');
      field.validateValue(entry.value);
      values[entry.key] = entry.value;
    }
    return DatabaseRow.create(
      id: rowId,
      values: values,
      body: _copyTemplateBody(template.body, rowId: rowId),
    );
  }

  WorkspaceDatabase updateRow(DatabaseRow row) {
    _exists(rows.map((r) => r.id), row.id);
    return copyWith(
      rows: [
        for (final r in rows)
          if (r.id == row.id) row else r,
      ],
    );
  }

  WorkspaceDatabase removeRow(String id) {
    _exists(rows.map((r) => r.id), id);
    final remaining = rows.where((row) => row.id != id).toList();
    final pruned = _pruneTaskLinksForRow(this, id);
    return pruned == null
        ? copyWith(rows: remaining)
        : _replaceTaskLinks(pruned, remaining);
  }

  WorkspaceDatabase archiveRow(String id, {bool archived = true}) => updateRow(
    rows
        .firstWhere(
          (r) => r.id == id,
          orElse: () => throw const FormatException('Missing row'),
        )
        .copyWith(archived: archived),
  );
  WorkspaceDatabase setCell(String rowId, String propertyId, Object? value) {
    final property = properties.firstWhere(
      (p) => p.id == propertyId,
      orElse: () => throw const FormatException('Missing property'),
    );
    property.validateValue(value);
    if (!databasePropertyTypes.contains(property.type) || property.isComputed)
      throw const FormatException('Property is read-only');
    final row = rows.firstWhere(
      (r) => r.id == rowId,
      orElse: () => throw const FormatException('Missing row'),
    );
    return updateRow(row.copyWith(values: {...row.values, propertyId: value}));
  }

  WorkspaceDatabase addView(DatabaseView view) =>
      copyWith(views: [...views, view]);
  WorkspaceDatabase updateView(DatabaseView view) {
    _exists(views.map((v) => v.id), view.id);
    return copyWith(
      views: [
        for (final v in views)
          if (v.id == view.id) view else v,
      ],
    );
  }

  WorkspaceDatabase removeView(String id) {
    _exists(views.map((v) => v.id), id);
    return copyWith(views: views.where((v) => v.id != id).toList());
  }
}

class DatabaseProperty {
  new _(Map<String, dynamic> raw) : _raw = _freezeMap(raw);
  factory create({
    String? id,
    required String name,
    String type = 'text',
    Map<String, dynamic> config = const {},
  }) => DatabaseProperty.fromJson({
    'id': id ?? newId(),
    'name': name,
    'type': type,
    'config': config,
  });
  factory fromJson(Map<String, dynamic> json) {
    final raw = _copyMap(json);
    _id(raw['id']);
    _nonempty(raw['name']);
    _nonempty(raw['type']);
    raw['config'] = _object(raw['config'] ?? {});
    return DatabaseProperty._(raw);
  }
  final Map<String, dynamic> _raw;
  String get id => _raw['id'] as String;
  String get name => _raw['name'] as String;
  String get type => _raw['type'] as String;
  Map<String, dynamic> get config => _raw['config'] as Map<String, dynamic>;
  bool get isComputed => type == 'formula' || type == 'rollup';
  DatabaseProperty copyWith({
    String? name,
    String? type,
    Map<String, dynamic>? config,
  }) => DatabaseProperty.fromJson({
    ...toJson(),
    'name': ?name,
    'type': ?type,
    'config': ?config,
  });
  Map<String, dynamic> toJson() => _copyMap(_raw);
  void validateValue(Object? value) {
    if (value == null || !databasePropertyTypes.contains(type)) return;
    switch (type) {
      case 'title':
      case 'text':
      case 'phone':
        if (value is! String) throw const FormatException('Expected text');
      case 'number':
        if (value is! num || !value.isFinite)
          throw const FormatException('Expected finite number');
      case 'checkbox':
        if (value is! bool) throw const FormatException('Expected checkbox');
      case 'status':
      case 'select':
        _option(value);
      case 'multiSelect':
        if (value is! List ||
            value.any((v) => v is! String) ||
            value.toSet().length != value.length)
          throw const FormatException('Expected unique selections');
        for (final item in value) {
          _option(item);
        }
      case 'date':
        parseDatabaseDate(value);
      case 'url':
        _url(value);
      case 'email':
        if (value is! String ||
            value.isNotEmpty &&
                !RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(value))
          throw const FormatException('Expected email');
      case 'people':
        if (value is! List) throw const FormatException('Expected people');
        for (final person in value) {
          if (person is String) continue;
          final map = _object(person);
          _nonempty(map['id']);
          if (map['name'] != null && map['name'] is! String)
            throw const FormatException('Invalid person');
        }
      case 'files':
        if (value is! List) throw const FormatException('Expected files');
        for (final file in value) {
          final map = _object(file);
          _nonempty(map['name']);
          if (map['url'] != null) _url(map['url']);
        }
      case 'relation':
        final refs = value is List ? value : [value];
        final seen = <String>{};
        for (final ref in refs) {
          final map = _object(ref);
          final db = _id(map['databaseId']), row = _id(map['rowId']);
          if (!seen.add('$db/$row'))
            throw const FormatException('Duplicate relation');
          if (config['databaseId'] != null && config['databaseId'] != db)
            throw const FormatException('Wrong relation database');
        }
      case 'formula':
      case 'rollup':
        throw const FormatException(
          'Computed values cannot overwrite raw values',
        );
    }
  }

  void _option(Object? value) {
    if (value is! String) throw const FormatException('Expected selection');
    final options = config['options'];
    if (options == null || value.isEmpty) return;
    if (options is! List) throw const FormatException('Invalid options');
    if (!options.any(
      (o) => o is String
          ? o == value
          : o is Map && (o['id'] == value || o['name'] == value),
    ))
      throw const FormatException('Missing selection option');
  }
}

class DatabaseRow {
  new _(Map<String, dynamic> raw) : _raw = _freezeMap(raw);
  factory create({
    String? id,
    Map<String, Object?> values = const {},
    Map<String, dynamic>? body,
  }) => DatabaseRow.fromJson({
    'id': id ?? newId(),
    'values': values,
    'body': body ?? {'version': 1, 'blocks': []},
    'archived': false,
  });
  factory fromJson(Map<String, dynamic> json) {
    final raw = _copyMap(json);
    _id(raw['id']);
    raw['values'] = _object(raw['values'] ?? {});
    raw['body'] = _object(raw['body'] ?? {'version': 1, 'blocks': []});
    // Validate with the page model while retaining the exact original body map.
    BlockPageDocument.fromJson(raw['body'] as Map<String, dynamic>);
    raw['archived'] ??= false;
    if (raw['archived'] is! bool)
      throw const FormatException('Invalid archived row');
    return DatabaseRow._(raw);
  }
  final Map<String, dynamic> _raw;
  String get id => _raw['id'] as String;
  bool get archived => _raw['archived'] as bool;
  Map<String, Object?> get values => _raw['values'] as Map<String, dynamic>;
  Map<String, dynamic> get body => _raw['body'] as Map<String, dynamic>;
  DatabaseRow copyWith({
    Map<String, Object?>? values,
    Map<String, dynamic>? body,
    bool? archived,
  }) => DatabaseRow.fromJson({
    ...toJson(),
    'values': ?values,
    'body': ?body,
    'archived': ?archived,
  });
  Map<String, dynamic> toJson() => _copyMap(_raw);
}

class DatabaseView {
  new _(Map<String, dynamic> raw) : _raw = _freezeMap(raw);
  factory create({
    String? id,
    String name = '표',
    String type = 'table',
    Map<String, dynamic>? filter,
    List<Map<String, dynamic>> sorts = const [],
    String? groupBy,
    List<String> visibleProperties = const [],
    Map<String, dynamic> config = const {},
  }) => DatabaseView.fromJson({
    'id': id ?? newId(),
    'name': name,
    'type': type,
    'filter': filter,
    'sorts': sorts,
    'groupBy': groupBy,
    'visibleProperties': visibleProperties,
    'config': config,
  });
  factory fromJson(Map<String, dynamic> json) {
    final raw = _copyMap(json);
    _id(raw['id']);
    _nonempty(raw['name']);
    _nonempty(raw['type']);
    if (raw['filter'] != null) raw['filter'] = _object(raw['filter']);
    raw['sorts'] = [
      for (final item in _list(raw['sorts'] ?? [])) _object(item),
    ];
    if (raw['groupBy'] != null && raw['groupBy'] is! String)
      throw const FormatException('Invalid grouping');
    raw['visibleProperties'] = [
      for (final id in _list(raw['visibleProperties'] ?? [])) _id(id),
    ];
    raw['config'] = _object(raw['config'] ?? {});
    return DatabaseView._(raw);
  }
  final Map<String, dynamic> _raw;
  String get id => _raw['id'] as String;
  String get name => _raw['name'] as String;
  String get type => _raw['type'] as String;
  Map<String, dynamic>? get filter => _raw['filter'] as Map<String, dynamic>?;
  List<Map<String, dynamic>> get sorts =>
      List.unmodifiable((_raw['sorts'] as List).cast<Map<String, dynamic>>());
  String? get groupBy => _raw['groupBy'] as String?;
  List<String> get visibleProperties =>
      List.unmodifiable((_raw['visibleProperties'] as List).cast<String>());
  Map<String, dynamic> get config => _raw['config'] as Map<String, dynamic>;
  DatabaseView copyWith({
    String? name,
    String? type,
    Map<String, dynamic>? filter,
    bool clearFilter = false,
    List<Map<String, dynamic>>? sorts,
    String? groupBy,
    bool clearGroupBy = false,
    List<String>? visibleProperties,
    Map<String, dynamic>? config,
  }) => DatabaseView.fromJson({
    ...toJson(),
    'name': ?name,
    'type': ?type,
    if (filter != null || clearFilter) 'filter': clearFilter ? null : filter,
    'sorts': ?sorts,
    if (groupBy != null || clearGroupBy)
      'groupBy': clearGroupBy ? null : groupBy,
    'visibleProperties': ?visibleProperties,
    'config': ?config,
  });
  Map<String, dynamic> toJson() => _copyMap(_raw);
}

({DateTime start, DateTime? end, bool allDay}) parseDatabaseDate(
  Object? value,
) {
  final map = value is String ? {'start': value} : _object(value);
  final start = map['start'] ?? map['dateISO'];
  if (start is! String) throw const FormatException('Expected ISO date');
  final first = _isoDate(start);
  final end = map['end'];
  if (end != null && end is! String)
    throw const FormatException('Invalid date end');
  final last = end == null ? null : _isoDate(end as String);
  if (last != null && last.isBefore(first))
    throw const FormatException('Date end precedes start');
  if (map['timeZone'] != null && map['timeZone'] is! String)
    throw const FormatException('Invalid time zone label');
  return (start: first, end: last, allDay: !start.contains('T'));
}

DateTime _isoDate(String value) {
  final match = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})(?:T(\d{2}):(\d{2})(?::(\d{2})(?:\.(\d{1,6}))?)?(Z|[+-]\d{2}:\d{2})?)?$',
  ).firstMatch(value);
  if (match == null) throw const FormatException('Invalid ISO date');
  final year = int.parse(match[1]!),
      month = int.parse(match[2]!),
      day = int.parse(match[3]!);
  final date = DateTime.utc(year, month, day);
  if (date.year != year || date.month != month || date.day != day)
    throw const FormatException('Invalid calendar date');
  if (match[4] == null) return date;
  if (int.parse(match[4]!) > 23 ||
      int.parse(match[5]!) > 59 ||
      int.parse(match[6] ?? '0') > 59)
    throw const FormatException('Invalid clock time');
  final offset = match[8];
  if (offset != null &&
      offset != 'Z' &&
      (int.parse(offset.substring(1, 3)) > 23 ||
          int.parse(offset.substring(4, 6)) > 59))
    throw const FormatException('Invalid UTC offset');
  return DateTime.parse(offset == null ? '${value}Z' : value).toUtc();
}

void _url(Object? value) {
  if (value is! String) throw const FormatException('Expected URL');
  if (value.isEmpty) return;
  final uri = Uri.tryParse(value);
  if (uri == null ||
      !['https', 'http'].contains(uri.scheme) ||
      uri.host.isEmpty)
    throw const FormatException('Invalid URL');
}

void _nonempty(Object? value) {
  if (value is! String || value.trim().isEmpty)
    throw const FormatException('Expected nonempty text');
}

String _id(Object? value) {
  if (value is! String ||
      !RegExp(
        r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
      ).hasMatch(value))
    throw const FormatException('Expected UUID');
  return value;
}

void _unique(Iterable<String> ids) {
  final list = ids.toList();
  if (list.toSet().length != list.length)
    throw const FormatException('Duplicate database identity');
}

void _exists(Iterable<String> ids, String id) {
  if (!ids.contains(id))
    throw const FormatException('Missing database identity');
}

List<dynamic> _list(Object? value) {
  if (value is! List) throw const FormatException('Expected array');
  return value;
}

Map<String, dynamic> _object(Object? value) {
  if (value is! Map || value.keys.any((k) => k is! String))
    throw const FormatException('Expected JSON object');
  return Map<String, dynamic>.from(value);
}

Map<String, dynamic> _copyMap(Map<String, dynamic> value) =>
    _json(value, 0) as Map<String, dynamic>;
Object? _json(Object? value, int depth) {
  if (depth > 64) throw const FormatException('JSON nesting limit');
  if (value == null || value is String || value is bool) return value;
  if (value is num) {
    if (!value.isFinite)
      throw const FormatException('Expected finite JSON number');
    return value;
  }
  if (value is List) return [for (final item in value) _json(item, depth + 1)];
  if (value is Map)
    return {
      for (final e in _object(value).entries) e.key: _json(e.value, depth + 1),
    };
  throw const FormatException('Expected JSON value');
}

Map<String, dynamic> _freezeMap(Map<String, dynamic> value) =>
    Map<String, dynamic>.unmodifiable({
      for (final e in value.entries) e.key: _freeze(e.value),
    });
Object? _freeze(Object? value) {
  if (value is List) return List<Object?>.unmodifiable(value.map(_freeze));
  if (value is Map) return _freezeMap(_object(value));
  return value;
}
