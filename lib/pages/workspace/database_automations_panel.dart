import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:ink_vault_core/ink_vault_core.dart' show newId;
import 'package:saber/data/vault/database_actions.dart';
import 'package:saber/data/vault/workspace_database.dart';

class DatabaseAutomationsPanel extends StatefulWidget {
  const new({
    super.key,
    required this.initialDatabase,
    required this.runtime,
    required this.currentRevision,
    required this.onSave,
    required this.onBack,
    this.initialTemplateId,
    this.onDirtyChanged,
    this.onBusyChanged,
  });
  final WorkspaceDatabase initialDatabase;
  final DatabaseActionRuntime runtime;
  final String Function() currentRevision;
  final Future<void> Function(WorkspaceDatabase) onSave;
  final VoidCallback onBack;
  final String? initialTemplateId;
  final ValueChanged<bool>? onDirtyChanged;
  final ValueChanged<bool>? onBusyChanged;
  @override
  State<DatabaseAutomationsPanel> createState() =>
      DatabaseAutomationsPanelState();
}

class DatabaseAutomationsPanelState extends State<DatabaseAutomationsPanel> {
  late WorkspaceDatabase _database;
  Map<String, dynamic>? _draft;
  String? _selected, _eventRow, _error, _unsupported, _message;
  var _tab = 'rules', _draftTouched = false, _saving = false;
  var _generation = 0, _savedGeneration = 0;
  var _reportedDirty = false, _reportedBusy = false;
  Future<void>? _saveFuture;
  (WorkspaceDatabase, int)? _definitionPending;
  DatabaseActionPrepared? _prepared;
  DatabaseActionDue? _due;
  var _dueEvents = <Map<String, dynamic>>[];

  WorkspaceDatabase get database => _database;
  DatabaseActionRuntime get _runtime => widget.runtime;
  bool get _locked => _prepared != null;
  bool get _editable => !_locked && _unsupported == null;
  bool get _dirty => _generation != _savedGeneration || _prepared != null;
  List<DatabaseProperty> get _properties => _database.properties
      .where((p) => databaseActionPropertyTypes.contains(p.type))
      .toList();
  List<DatabaseRow> get _rows =>
      _database.rows.where((r) => !r.archived).toList();
  List<Map<String, dynamic>> get _rules => _runtime.rules(_database);
  Map<String, String> get _actionTypes => {
    'addRow': '행 추가',
    if ((_draft?['trigger'] as Map?)?['type'] == 'schedule' &&
        _database.rowTemplates.isNotEmpty)
      'addRowFromTemplate': '템플릿에서 행 추가',
    'setProperty': '속성 변경',
    'setStatus': '상태 변경',
  };

  @override
  void initState() {
    super.initState();
    _database = widget.initialDatabase;
    _eventRow = _rows.firstOrNull?.id;
    try {
      final templateId = widget.initialTemplateId;
      if (templateId != null) {
        final template = _database.rowTemplates
            .where((item) => item.id == templateId)
            .firstOrNull;
        if (template == null) throw StateError('선택한 템플릿을 찾을 수 없습니다.');
        _newDraft(template);
        WidgetsBinding.instance.addPostFrameCallback((_) => _report());
        return;
      }
      final first =
          _rules.where((r) => r['archived'] != true).firstOrNull ??
          _rules.firstOrNull;
      if (first != null) _loadDraft(first);
    } catch (error) {
      _error = _errorText(error);
    }
  }

  void _loadDraft(Map<String, dynamic> rule) {
    _selected = rule['id'] as String;
    _draft = _copy(rule);
    _draftTouched = false;
    _unsupported = null;
    try {
      _runtime.validateRule(_database, rule);
    } on DatabaseActionException catch (error) {
      if ([
        'unsupported_trigger',
        'unsupported_action',
        'unsupported_condition',
        'unsupported_property',
        'unsupported_schedule',
      ].contains(error.code)) {
        _unsupported = '이 규칙의 고급 설정은 현재 편집할 수 없습니다. 원문을 보존합니다.';
      }
    }
  }

  String _errorText(Object error) {
    if (error is DatabaseActionException) {
      return switch (error.code) {
        'invalid_value' => '속성에 맞는 값을 입력해 주세요.',
        'missing_row' => '규칙에 사용할 대상 행을 선택해 주세요.',
        'missing_template' => '규칙에서 사용할 템플릿을 선택해 주세요.',
        'unsupported_timezone' => '지원하는 IANA 시간대를 입력해 주세요. 예: Asia/Seoul',
        'invalid_schedule' => '일정의 시작일, 시간과 반복 간격을 확인해 주세요.',
        'disabled_rule' => '꺼진 규칙은 실행할 수 없습니다.',
        'not_execution_owner' => '이 일정은 다른 기기가 실행을 담당합니다.',
        'unsupported_action' ||
        'unsupported_trigger' ||
        'unsupported_condition' ||
        'unsupported_property' => '이 고급 설정은 현재 실행할 수 없습니다. 원문은 보존됩니다.',
        _ => error.message,
      };
    }
    return error is StateError ? error.message : '$error';
  }

  void _report() {
    if (!mounted) return;
    if (_reportedDirty != _dirty) {
      _reportedDirty = _dirty;
      widget.onDirtyChanged?.call(_dirty);
    }
    if (_reportedBusy != _saving) {
      _reportedBusy = _saving;
      widget.onBusyChanged?.call(_saving);
    }
  }

  void _run(void Function() operation) {
    try {
      operation();
    } catch (error) {
      if (mounted) setState(() => _error = _errorText(error));
    }
  }

  void _touch(void Function() operation) {
    if (!_editable) return;
    setState(() {
      operation();
      _draftTouched = true;
      _generation++;
      _error = null;
      _message = null;
      _due = null;
      _dueEvents = [];
    });
    _report();
  }

  void _applyDraft() {
    if (!_draftTouched || _draft == null) return;
    _database = _runtime.putRule(_database, _draft!);
    _draft!['version'] = _runtime
        .rules(_database)
        .singleWhere((rule) => rule['id'] == _selected)['version'];
    _draftTouched = false;
  }

  void _select(String id) {
    if (_locked || _saving) return;
    _applyDraft();
    setState(() {
      _loadDraft(_rules.singleWhere((r) => r['id'] == id));
      _error = null;
      _message = null;
    });
  }

  void _create() {
    if (_locked || _saving) return;
    _applyDraft();
    setState(_newDraft);
    _report();
  }

  void _newDraft([DatabaseRowTemplate? template]) {
    final title = _properties.where((p) => p.type == 'title').firstOrNull;
    _selected = newId();
    _draft = {
      'id': _selected,
      'version': 1,
      'name': template == null ? '새 규칙' : '${template.name} 반복 일정',
      'enabled': true,
      'trigger': template == null
          ? {'type': 'manual'}
          : _scheduleTrigger({'type': 'schedule'}),
      if (template != null) 'ownerDeviceId': _runtime.deviceId,
      'actions': [
        {
          'id': newId(),
          if (template != null) ...{
            'type': 'addRowFromTemplate',
            'templateId': template.id,
            'values': <String, dynamic>{},
          } else ...{
            'type': 'addRow',
            'values': {if (title != null) title.id: '새 항목'},
          },
        },
      ],
    };
    _unsupported = null;
    _draftTouched = true;
    _generation++;
    _tab = 'rules';
    _error = null;
    _message = null;
  }

  void _archive() {
    if (_locked || _saving || _selected == null) return;
    _applyDraft();
    _database = _runtime.archiveRule(_database, _selected!);
    setState(() {
      _loadDraft(_rules.singleWhere((rule) => rule['id'] == _selected));
      _generation++;
      _due = null;
      _dueEvents = [];
      _error = null;
    });
    _report();
  }

  Future<void> save() {
    final current = _saveFuture;
    if (current != null) return current;
    late Future<void> tracked;
    tracked = _flush().whenComplete(() {
      if (identical(_saveFuture, tracked)) _saveFuture = null;
    });
    _saveFuture = tracked;
    return tracked;
  }

  Future<void> _flush() async {
    _saving = true;
    if (mounted) {
      setState(() => _error = null);
      _report();
    }
    try {
      while (_dirty || _definitionPending != null) {
        final prepared = _prepared;
        if (prepared == null && _definitionPending == null) {
          _applyDraft();
          _definitionPending = (_database, _generation);
        }
        final snapshot = prepared?.database ?? _definitionPending!.$1;
        final generation = prepared == null
            ? _definitionPending!.$2
            : _generation;
        await widget.onSave(snapshot);
        _database = snapshot;
        _savedGeneration = generation;
        if (prepared != null) {
          _prepared = null;
          _message = prepared.receipts.isEmpty
              ? '실행할 동작이 없습니다.'
              : prepared.receipts.any((r) => r['status'] == 'completed')
              ? '실행 결과를 저장했습니다.'
              : '조건에 맞지 않아 실행을 건너뛰고 기록했습니다.';
        }
        _definitionPending = null;
        _report();
      }
    } catch (error) {
      if (mounted) setState(() => _error = _errorText(error));
      rethrow;
    } finally {
      _saving = false;
      if (mounted) {
        setState(() {});
        _report();
      }
    }
  }

  Future<void> _saveUi() async {
    try {
      await save();
    } catch (_) {}
  }

  Future<void> _back() async {
    try {
      await save();
      if (mounted) widget.onBack();
    } catch (_) {}
  }

  void _execute(String ruleId, {int? scheduledForUtcMs}) {
    if (_saving || _prepared != null) return;
    if (_definitionPending != null) throw StateError('이전 규칙 저장을 먼저 재시도해 주세요.');
    _applyDraft();
    final captured = DateTime.now().toUtc().millisecondsSinceEpoch;
    final revision = widget.currentRevision();
    final prepared = scheduledForUtcMs == null
        ? _runtime.prepareManual(
            _database,
            ruleId: ruleId,
            eventId: newId(),
            rowId: _eventRow,
            inputRevision: revision,
            capturedAtUtcMs: captured,
          )
        : _runtime.prepareScheduled(
            _database,
            ruleId: ruleId,
            scheduledForUtcMs: scheduledForUtcMs,
            inputRevision: revision,
            capturedAtUtcMs: captured,
          );
    setState(() {
      _prepared = prepared;
      _generation++;
      _message = null;
      _error = null;
      if (scheduledForUtcMs != null)
        _dueEvents = _dueEvents
            .where(
              (entry) =>
                  entry['ruleId'] != ruleId ||
                  (entry['event'] as Map)['scheduledForUtcMs'] !=
                      scheduledForUtcMs,
            )
            .toList();
    });
    _report();
    unawaited(_saveUi());
  }

  void _checkDue({bool more = false}) {
    if (_saving || _locked) return;
    _applyDraft();
    final batch = _runtime.due(
      _database,
      capturedAtUtcMs: more && _due != null
          ? _due!.capturedAtUtcMs
          : DateTime.now().toUtc().millisecondsSinceEpoch,
      cursor: more ? _due?.cursor : null,
    );
    setState(() {
      _due = batch;
      _dueEvents = [if (more) ..._dueEvents, ...batch.events];
      _error = null;
      _tab = 'schedule';
    });
  }

  Object? _defaultValue(DatabaseProperty property) => switch (property.type) {
    'checkbox' => false,
    'number' => 0,
    'multiSelect' => <String>[],
    'date' => DateTime.now().toIso8601String().substring(0, 10),
    'status' || 'select' => _options(property).keys.firstOrNull ?? '',
    _ => '',
  };
  Map<String, String> _options(DatabaseProperty property) => {
    for (final value
        in (property.config['options'] is List
            ? property.config['options'] as List
            : []))
      if (value is String)
        value: value
      else if (value is Map && value['id'] is String)
        value['id'] as String: '${value['name'] ?? value['id']}',
  };
  String _rowName(DatabaseRow row) {
    final title = _properties.where((p) => p.type == 'title').firstOrNull;
    final value = title == null ? null : row.values[title.id];
    return value is String && value.isNotEmpty ? value : '이름 없는 행';
  }

  List<Map<String, dynamic>> get _actions => [
    for (final item in (_draft?['actions'] as List? ?? []))
      _copy(Map<String, dynamic>.from(item as Map)),
  ];
  void _action(String id, void Function(Map<String, dynamic>) update) =>
      _touch(() {
        final actions = _actions;
        for (final action in actions) {
          if (action['id'] == id) update(action);
        }
        _draft!['actions'] = actions;
      });
  void _addAction(String type) {
    final addsRow = type == 'addRow' || type == 'addRowFromTemplate';
    final property = _properties
        .where((p) => type != 'setStatus' || p.type == 'status')
        .firstOrNull;
    if (!addsRow && property == null)
      throw StateError('이 동작에 사용할 속성을 먼저 만들어 주세요.');
    _touch(() {
      _draft!['actions'] = [
        ..._actions,
        {
          'id': newId(),
          'type': type,
          if (type == 'addRowFromTemplate')
            'templateId': _database.rowTemplates.first.id,
          if (addsRow)
            'values': {
              if (type == 'addRow')
                for (final title
                    in _properties.where((p) => p.type == 'title').take(1))
                  title.id: '새 항목',
            }
          else ...{
            'propertyId': property!.id,
            'value': _defaultValue(property),
            if ((_draft!['trigger'] as Map)['type'] == 'schedule' &&
                _rows.isNotEmpty)
              'rowId': _rows.first.id,
          },
        },
      ];
    });
  }

  void _trigger(String type) => _touch(() {
    final old = Map<String, dynamic>.from(_draft!['trigger'] as Map);
    final trigger = {...old, 'type': type};
    if (type == 'propertyChanged')
      trigger['propertyId'] ??= _properties.firstOrNull?.id;
    if (type == 'schedule') {
      _draft!['ownerDeviceId'] ??= _runtime.deviceId;
    }
    _draft!['trigger'] = type == 'schedule'
        ? _scheduleTrigger(trigger)
        : trigger;
  });

  Map<String, dynamic> _scheduleTrigger(Map<String, dynamic> trigger) => trigger
    ..['timeZone'] ??= 'Asia/Seoul'
    ..['time'] ??= '09:00'
    ..['startDate'] ??= DateTime.now().toIso8601String().substring(0, 10)
    ..['frequency'] ??= 'daily'
    ..['interval'] ??= 1
    ..['ambiguous'] ??= 'earlier'
    ..['gap'] ??= 'skip';

  void _setTrigger(String key, Object? value) => _touch(
    () => _draft!['trigger'] = {
      ...Map<String, dynamic>.from(_draft!['trigger'] as Map),
      key: value,
    },
  );

  Widget _field(
    String key,
    String initial,
    String label,
    ValueChanged<String> changed, {
    bool? enabled,
    TextInputType? keyboard,
  }) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: TextFormField(
      key: ValueKey(key),
      initialValue: initial,
      enabled: enabled ?? _editable,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
      onChanged: changed,
      keyboardType: keyboard,
    ),
  );
  Widget _choice(
    String key,
    String? value,
    Map<String, String> options,
    String label,
    ValueChanged<String> changed, {
    bool? enabled,
  }) {
    final items = {
      ...options,
      if (value != null && !options.containsKey(value)) value: '$value (현재 값)',
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: DropdownButtonFormField<String>(
        key: ValueKey(key),
        initialValue: value,
        isExpanded: true,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
        ),
        items: [
          for (final entry in items.entries)
            DropdownMenuItem(
              value: entry.key,
              child: Text(entry.value, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: (enabled ?? _editable)
            ? (value) {
                if (value != null) changed(value);
              }
            : null,
      ),
    );
  }

  Widget _value(
    String key,
    DatabaseProperty property,
    Object? value,
    ValueChanged<Object?> changed,
  ) {
    final label = property.name;
    final options = _options(property);
    if (property.type == 'checkbox')
      return SwitchListTile(
        key: ValueKey(key),
        title: Text(label),
        value: value == true,
        onChanged: _editable ? changed : null,
        contentPadding: EdgeInsets.zero,
      );
    if (['status', 'select'].contains(property.type) && options.isNotEmpty) {
      return _choice(
        key,
        value is String ? value : null,
        options,
        label,
        changed,
      );
    }
    if (property.type == 'multiSelect' && options.isNotEmpty) {
      final selected = value is List
          ? value.whereType<String>().toSet()
          : <String>{};
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label),
          Wrap(
            spacing: 6,
            children: [
              for (final option in {
                ...options,
                for (final item in selected)
                  if (!options.containsKey(item)) item: item,
              }.entries)
                FilterChip(
                  label: Text(option.value),
                  selected: selected.contains(option.key),
                  onSelected: !_editable
                      ? null
                      : (on) {
                          final next = {...selected};
                          if (on)
                            next.add(option.key);
                          else
                            next.remove(option.key);
                          changed(next.toList());
                        },
                ),
            ],
          ),
        ],
      );
    }
    if (property.type == 'date') {
      final range = value is Map
          ? Map<String, dynamic>.from(value)
          : <String, dynamic>{};
      final start = value is String
          ? value
          : '${range['start'] ?? range['dateISO'] ?? ''}';
      return Column(
        children: [
          _field(key, start, '$label (ISO 날짜)', (text) {
            changed(
              range.isEmpty
                  ? (text.isEmpty ? null : text)
                  : {...range, 'start': text},
            );
          }),
          ExpansionTile(
            title: const Text('날짜 범위·시간대'),
            children: [
              _field(
                '$key-end',
                '${range['end'] ?? ''}',
                '종료 날짜',
                (text) => changed({
                  ...range,
                  'start': start,
                  'end': text.isEmpty ? null : text,
                }),
              ),
              _field(
                '$key-zone',
                '${range['timeZone'] ?? ''}',
                '시간대',
                (text) => changed({
                  ...range,
                  'start': start,
                  'timeZone': text.isEmpty ? null : text,
                }),
              ),
            ],
          ),
        ],
      );
    }
    final text = value == null
        ? ''
        : value is List
        ? value.join(', ')
        : '$value';
    return _field(
      key,
      text,
      property.type == 'multiSelect' ? '$label (쉼표로 구분)' : label,
      (text) {
        changed(
          property.type == 'number'
              ? (text.isEmpty ? null : num.tryParse(text) ?? text)
              : property.type == 'multiSelect'
              ? text
                    .split(',')
                    .map((s) => s.trim())
                    .where((s) => s.isNotEmpty)
                    .toList()
              : text,
        );
      },
      keyboard: property.type == 'number'
          ? const TextInputType.numberWithOptions(decimal: true, signed: true)
          : TextInputType.text,
    );
  }

  Widget _actionEditor(Map<String, dynamic> action, int index) {
    final id = action['id'] as String;
    final type = action['type'] as String;
    final fromTemplate = type == 'addRowFromTemplate';
    final candidates = _properties
        .where((p) => type != 'setStatus' || p.type == 'status')
        .toList();
    final property = candidates
        .where((p) => p.id == action['propertyId'])
        .firstOrNull;
    final values = action['values'] is Map
        ? Map<String, dynamic>.from(action['values'] as Map)
        : <String, dynamic>{};
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '동작 ${index + 1}',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                IconButton(
                  tooltip: '동작 위로',
                  onPressed: !_editable || index == 0
                      ? null
                      : () => _touch(() {
                          final list = _actions;
                          final item = list.removeAt(index);
                          list.insert(index - 1, item);
                          _draft!['actions'] = list;
                        }),
                  icon: const Icon(Icons.arrow_upward, size: 18),
                ),
                IconButton(
                  tooltip: '동작 제거',
                  onPressed: !_editable || _actions.length == 1
                      ? null
                      : () => _touch(
                          () => _draft!['actions'] = _actions
                              .where((a) => a['id'] != id)
                              .toList(),
                        ),
                  icon: const Icon(Icons.remove_circle_outline),
                ),
              ],
            ),
            _choice(
              'actions-type-$id',
              type,
              _actionTypes,
              '동작',
              (next) => _run(
                () => _action(id, (raw) {
                  final addsRow =
                      next == 'addRow' || next == 'addRowFromTemplate';
                  final p = _properties
                      .where((p) => next != 'setStatus' || p.type == 'status')
                      .firstOrNull;
                  if (!addsRow && p == null)
                    throw StateError('사용할 속성을 먼저 만들어 주세요.');
                  raw['type'] = next;
                  if (next == 'addRowFromTemplate') {
                    raw['templateId'] ??= _database.rowTemplates.first.id;
                  } else {
                    raw.remove('templateId');
                  }
                  if (addsRow) {
                    raw['values'] ??= <String, dynamic>{};
                  } else {
                    raw['propertyId'] = p!.id;
                    raw['value'] = _defaultValue(p);
                  }
                }),
              ),
            ),
            if (fromTemplate)
              _choice(
                'actions-template-$id',
                action['templateId'] as String?,
                {
                  for (final template in _database.rowTemplates)
                    template.id: template.name,
                },
                '원본 템플릿',
                (templateId) =>
                    _action(id, (raw) => raw['templateId'] = templateId),
              ),
            if (type == 'addRow' || fromTemplate) ...[
              for (final entry in values.entries)
                if (_properties.any((p) => p.id == entry.key))
                  Row(
                    children: [
                      Expanded(
                        child: _value(
                          'actions-value-$id-${entry.key}',
                          _properties.singleWhere((p) => p.id == entry.key),
                          entry.value,
                          (next) => _action(
                            id,
                            (raw) => raw['values'] = {
                              ...Map<String, dynamic>.from(
                                raw['values'] as Map,
                              ),
                              entry.key: next,
                            },
                          ),
                        ),
                      ),
                      if (fromTemplate)
                        IconButton(
                          tooltip: '템플릿 기본값 사용',
                          icon: const Icon(Icons.refresh),
                          onPressed: !_editable
                              ? null
                              : () => _action(
                                  id,
                                  (raw) => raw['values'] = {
                                    for (final value in values.entries)
                                      if (value.key != entry.key)
                                        value.key: value.value,
                                  },
                                ),
                        ),
                    ],
                  ),
              _choice(
                'actions-add-property-$id',
                null,
                {
                  for (final p in _properties)
                    if (!values.containsKey(p.id)) p.id: p.name,
                },
                fromTemplate ? '덮어쓸 속성' : '추가할 속성',
                (propertyId) => _action(
                  id,
                  (raw) => raw['values'] = {
                    ...Map<String, dynamic>.from(raw['values'] as Map),
                    propertyId: _defaultValue(
                      _properties.singleWhere((p) => p.id == propertyId),
                    ),
                  },
                ),
              ),
            ] else ...[
              _choice(
                'actions-property-$id',
                property?.id,
                {for (final p in candidates) p.id: p.name},
                '변경할 속성',
                (propertyId) => _action(id, (raw) {
                  final p = candidates.singleWhere((p) => p.id == propertyId);
                  raw['propertyId'] = p.id;
                  raw['value'] = _defaultValue(p);
                }),
              ),
              if (property != null)
                _value(
                  'actions-value-$id-${property.id}',
                  property,
                  action['value'],
                  (next) => _action(id, (raw) => raw['value'] = next),
                ),
              _choice(
                'actions-row-$id',
                action['rowId'] as String? ?? '',
                {'': '현재 대상 행', for (final row in _rows) row.id: _rowName(row)},
                '변경할 행',
                (rowId) => _action(id, (raw) {
                  if (rowId.isEmpty)
                    raw.remove('rowId');
                  else
                    raw['rowId'] = rowId;
                }),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Map<String, dynamic> _defaultCondition() => {
    'propertyId': _properties.first.id,
    'operator': 'isNotEmpty',
  };
  Widget _condition(
    Map<String, dynamic> node,
    String path,
    ValueChanged<Map<String, dynamic>> changed,
  ) {
    final group = ['and', 'or', 'not'].where(node.containsKey).firstOrNull;
    final property = _properties
        .where((p) => p.id == node['propertyId'])
        .firstOrNull;
    final op = node['operator'] as String?;
    final known =
        group != null ||
        property != null &&
            ['eq', 'notEq', 'contains', 'isEmpty', 'isNotEmpty'].contains(op);
    if (!known) return const Text('현재 편집할 수 없는 고급 조건입니다. 원문을 보존합니다.');
    final kind = group ?? 'leaf';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _choice(
              'actions-condition-kind-$path',
              kind,
              {'leaf': '속성 조건', 'and': '모두 만족', 'or': '하나 이상 만족', 'not': '반대'},
              '조건 방식',
              (next) {
                final extras = {...node}
                  ..removeWhere(
                    (key, _) => [
                      'and',
                      'or',
                      'not',
                      'propertyId',
                      'operator',
                      'value',
                    ].contains(key),
                  );
                changed({
                  ...extras,
                  if (next == 'leaf')
                    ..._defaultCondition()
                  else if (next == 'not')
                    'not': node
                  else
                    next: [node],
                });
              },
            ),
            if (kind == 'and' || kind == 'or') ...[
              if (node[kind] is List)
                for (final (index, child) in (node[kind] as List).indexed)
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _condition(
                        Map<String, dynamic>.from(child as Map),
                        '$path-$index',
                        (next) {
                          final list = List<dynamic>.from(node[kind] as List);
                          list[index] = next;
                          changed({...node, kind: list});
                        },
                      ),
                      TextButton(
                        onPressed:
                            !_editable || (node[kind] as List).length <= 1
                            ? null
                            : () {
                                final list = List<dynamic>.from(
                                  node[kind] as List,
                                )..removeAt(index);
                                changed({...node, kind: list});
                              },
                        child: const Text('하위 조건 제거'),
                      ),
                    ],
                  ),
              TextButton.icon(
                key: ValueKey('actions-condition-add-$path'),
                onPressed: !_editable
                    ? null
                    : () => changed({
                        ...node,
                        kind: [...node[kind] as List, _defaultCondition()],
                      }),
                icon: const Icon(Icons.add),
                label: const Text('하위 조건 추가'),
              ),
            ] else if (kind == 'not')
              _condition(
                Map<String, dynamic>.from(node['not'] as Map),
                '$path-not',
                (next) => changed({...node, 'not': next}),
              )
            else ...[
              _choice(
                'actions-condition-property-$path',
                property!.id,
                {for (final p in _properties) p.id: p.name},
                '속성',
                (id) => changed({
                  ...node,
                  'propertyId': id,
                  'value': _defaultValue(
                    _properties.singleWhere((p) => p.id == id),
                  ),
                }),
              ),
              _choice(
                'actions-condition-op-$path',
                op,
                {
                  'isNotEmpty': '비어 있지 않음',
                  'isEmpty': '비어 있음',
                  'eq': '같음',
                  'notEq': '다름',
                  'contains': '포함',
                },
                '비교',
                (next) => changed({
                  ...node,
                  'operator': next,
                  if (!['isEmpty', 'isNotEmpty'].contains(next) &&
                      !node.containsKey('value'))
                    'value': _defaultValue(property),
                }),
              ),
              if (!['isEmpty', 'isNotEmpty'].contains(op))
                _value(
                  'actions-condition-value-$path',
                  op == 'contains' && property.type == 'multiSelect'
                      ? property.copyWith(type: 'select')
                      : property,
                  node['value'],
                  (next) => changed({...node, 'value': next}),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _ruleEditor() {
    final raw = _draft!;
    final trigger = Map<String, dynamic>.from(raw['trigger'] as Map);
    final type = trigger['type'] as String;
    final usesTemplate = _actions.any(
      (action) => action['type'] == 'addRowFromTemplate',
    );
    return KeyedSubtree(
      key: ValueKey('actions-editor-$_selected'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_unsupported != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(_unsupported!),
            ),
          _field(
            'actions-rule-name',
            '${raw['name'] ?? ''}',
            '규칙 이름',
            (text) => _touch(() => raw['name'] = text),
          ),
          SwitchListTile(
            key: const ValueKey('actions-enabled'),
            contentPadding: EdgeInsets.zero,
            title: const Text('규칙 켜기'),
            value: raw['enabled'] == true,
            onChanged: _editable
                ? (value) => _touch(() => raw['enabled'] = value)
                : null,
          ),
          _choice(
            'actions-trigger',
            type,
            {
              if (!usesTemplate) ...{
                'manual': '수동 버튼',
                'rowAdded': '행이 추가될 때',
                'propertyChanged': '속성이 바뀔 때',
              },
              'schedule': '반복 일정',
            },
            '실행 시점',
            _trigger,
            enabled: _editable && !usesTemplate,
          ),
          if (usesTemplate) const Text('템플릿 동작을 바꾸거나 제거하면 실행 시점을 변경할 수 있습니다.'),
          if (type == 'propertyChanged')
            _choice(
              'actions-trigger-property',
              trigger['propertyId'] as String?,
              {for (final p in _properties) p.id: p.name},
              '변경을 감지할 속성',
              (id) => _setTrigger('propertyId', id),
            ),
          if (type == 'schedule') ...[
            const Text('앱이 열려 있을 때 이 기기가 맡은 일정을 실행합니다.'),
            _choice(
              'actions-schedule-frequency',
              trigger['frequency'] as String?,
              {'daily': '매일', 'weekly': '매주', 'monthly': '매월', 'yearly': '매년'},
              '반복',
              (text) => _setTrigger('frequency', text),
            ),
            _field(
              'actions-schedule-interval',
              '${trigger['interval'] ?? 1}',
              '반복 간격',
              (text) => _setTrigger('interval', int.tryParse(text) ?? text),
              keyboard: TextInputType.number,
            ),
            _field(
              'actions-schedule-startDate',
              '${trigger['startDate'] ?? ''}',
              '시작일 (YYYY-MM-DD)',
              (text) => _setTrigger('startDate', text),
            ),
            _field(
              'actions-schedule-endDate',
              '${trigger['endDate'] ?? ''}',
              '종료일 (선택)',
              (text) => _setTrigger('endDate', text.isEmpty ? null : text),
            ),
            _field(
              'actions-schedule-time',
              '${trigger['time'] ?? ''}',
              '실행 시간 (HH:mm)',
              (text) => _setTrigger('time', text),
            ),
            _field(
              'actions-schedule-timeZone',
              '${trigger['timeZone'] ?? ''}',
              'IANA 시간대',
              (text) => _setTrigger('timeZone', text),
            ),
            _choice(
              'actions-schedule-ambiguous',
              trigger['ambiguous'] as String? ?? 'earlier',
              {'earlier': '앞선 시각', 'later': '뒤의 시각'},
              '일광 절약 종료로 시각이 겹치면',
              (text) => _setTrigger('ambiguous', text),
            ),
            const Text(
              '매주는 시작일의 요일, 매월은 일자, 매년은 월과 일을 기준으로 반복합니다. 해당 날짜나 현지 시각이 없으면 건너뜁니다.',
            ),
            Text(
              raw['ownerDeviceId'] == _runtime.deviceId
                  ? '이 기기가 일정 실행을 담당합니다.'
                  : '다른 기기가 일정 실행을 담당합니다.',
            ),
            OutlinedButton.icon(
              key: const ValueKey('actions-take-owner'),
              onPressed: !_editable
                  ? null
                  : () =>
                        _touch(() => raw['ownerDeviceId'] = _runtime.deviceId),
              icon: const Icon(Icons.devices),
              label: const Text('이 기기에서 일정 실행'),
            ),
            if (raw['condition'] != null) ...[
              _choice(
                'actions-schedule-row',
                trigger['rowId'] as String?,
                {for (final row in _rows) row.id: _rowName(row)},
                '일정 조건의 대상 행 (필수)',
                (id) => _setTrigger('rowId', id),
              ),
              if (trigger['rowId'] == null)
                const Text('조건을 평가할 대상 행을 선택해 주세요.'),
            ],
          ],
          const SizedBox(height: 12),
          if (raw['condition'] is Map) ...[
            _condition(
              Map<String, dynamic>.from(raw['condition'] as Map),
              'root',
              (next) => _touch(() => raw['condition'] = next),
            ),
            TextButton(
              onPressed: !_editable
                  ? null
                  : () => _touch(() => raw.remove('condition')),
              child: const Text('조건 제거'),
            ),
          ] else
            OutlinedButton(
              key: const ValueKey('actions-add-condition'),
              onPressed: !_editable || _properties.isEmpty
                  ? null
                  : () => _touch(() => raw['condition'] = _defaultCondition()),
              child: const Text('조건 추가'),
            ),
          if (_unsupported == null)
            for (final (index, action) in _actions.indexed)
              _actionEditor(action, index),
          if (_unsupported == null)
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final entry in _actionTypes.entries)
                  OutlinedButton(
                    key: ValueKey('actions-add-${entry.key}'),
                    onPressed: !_editable
                        ? null
                        : () => _run(() => _addAction(entry.key)),
                    child: Text('${entry.value} 동작'),
                  ),
              ],
            ),
          const SizedBox(height: 14),
          if (type == 'manual' && _unsupported == null) ...[
            _choice(
              'actions-event-row',
              _eventRow,
              {for (final row in _rows) row.id: _rowName(row)},
              '현재 대상 행',
              (id) => setState(() => _eventRow = id),
              enabled: !_locked && !_saving,
            ),
            FilledButton.icon(
              key: ValueKey('actions-run-$_selected'),
              onPressed: _saving || _locked || raw['enabled'] != true
                  ? null
                  : () => _run(() => _execute(_selected!)),
              icon: const Icon(Icons.play_arrow),
              label: const Text('지금 실행'),
            ),
          ],
          TextButton.icon(
            key: const ValueKey('actions-archive-rule'),
            onPressed: _locked || _saving || raw['archived'] == true
                ? null
                : () => _run(_archive),
            icon: const Icon(Icons.archive_outlined),
            label: const Text('규칙 보관'),
          ),
        ],
      ),
    );
  }

  Widget _scheduleList() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Text('앱이 열려 있을 때 이 기기가 맡은 일정을 확인하고 실행합니다.'),
      FilledButton.icon(
        key: const ValueKey('actions-check-due'),
        onPressed: _saving || _locked ? null : () => _run(() => _checkDue()),
        icon: const Icon(Icons.update),
        label: const Text('일정 확인'),
      ),
      if (_due != null && _dueEvents.isEmpty)
        const Padding(
          padding: EdgeInsets.all(14),
          child: Text('지금 실행할 일정이 없습니다.'),
        ),
      for (final entry in _dueEvents)
        Builder(
          builder: (context) {
            final event = Map<String, dynamic>.from(entry['event'] as Map);
            final id = entry['ruleId'] as String;
            final rule = _rules.where((r) => r['id'] == id).firstOrNull;
            final slot = event['scheduledForUtcMs'] as int;
            return Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '${rule?['name'] ?? '규칙'} · ${DateTime.fromMillisecondsSinceEpoch(slot, isUtc: true).toLocal()}',
                    ),
                    OutlinedButton(
                      key: ValueKey('actions-run-due-$id-$slot'),
                      onPressed: _saving || _locked
                          ? null
                          : () => _run(
                              () => _execute(id, scheduledForUtcMs: slot),
                            ),
                      child: const Text('이 일정 실행'),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      if (_due?.hasMore == true)
        OutlinedButton(
          onPressed: _saving || _locked
              ? null
              : () => _run(() => _checkDue(more: true)),
          child: const Text('이전 일정 더 확인'),
        ),
    ],
  );
  Widget _history() {
    try {
      final records = _runtime.receipts(_database).reversed.toList();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (records.isEmpty) const Text('아직 실행 기록이 없습니다.'),
          for (final record in records)
            Card(
              child: ListTile(
                title: Text(
                  '${_rules.where((r) => r['id'] == record['ruleId']).firstOrNull?['name'] ?? '규칙'} · ${record['status'] == 'completed' ? '완료' : '건너뜀'}',
                ),
                subtitle: Text(
                  '${DateTime.fromMillisecondsSinceEpoch(record['capturedAtUtcMs'] as int, isUtc: true).toLocal()}\n${(record['actionResults'] as List).length}개 동작',
                ),
                trailing: Text(record['status'] == 'completed' ? '완료' : '건너뜀'),
              ),
            ),
        ],
      );
    } catch (error) {
      return Text(_errorText(error));
    }
  }

  @override
  Widget build(BuildContext context) {
    List<Map<String, dynamic>> rules;
    try {
      rules = _rules;
    } catch (_) {
      rules = [];
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(10),
          child: Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              IconButton(
                tooltip: '데이터베이스로',
                onPressed: _saving ? null : () => unawaited(_back()),
                icon: const Icon(Icons.arrow_back),
              ),
              const Text(
                '버튼과 자동화',
                style: TextStyle(fontSize: 19, fontWeight: FontWeight.w600),
              ),
              FilledButton.icon(
                key: const ValueKey('actions-create-rule'),
                onPressed: _saving || _locked ? null : () => _run(_create),
                icon: const Icon(Icons.add),
                label: const Text('새 규칙'),
              ),
              IconButton(
                key: const ValueKey('actions-save'),
                tooltip: '규칙 저장',
                onPressed: _saving ? null : () => unawaited(_saveUi()),
                icon: const Icon(Icons.save_outlined),
              ),
            ],
          ),
        ),
        Wrap(
          spacing: 6,
          children: [
            for (final entry in {
              'rules': '규칙',
              'schedule': '일정',
              'history': '실행 기록',
            }.entries)
              ChoiceChip(
                key: ValueKey('actions-${entry.key}-tab'),
                label: Text(entry.value),
                selected: _tab == entry.key,
                onSelected: _locked
                    ? null
                    : (_) => setState(() => _tab = entry.key),
              ),
          ],
        ),
        if (_saving) const LinearProgressIndicator(),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(10),
            child: Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        if (_message != null)
          Padding(padding: const EdgeInsets.all(10), child: Text(_message!)),
        if (_prepared != null || _definitionPending != null && !_saving)
          TextButton.icon(
            key: const ValueKey('actions-retry'),
            onPressed: _saving ? null : () => unawaited(_saveUi()),
            icon: const Icon(Icons.refresh),
            label: const Text('같은 결과 저장 재시도'),
          ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(14),
            children: [
              if (_tab == 'rules') ...[
                if (rules.isNotEmpty || _draft != null)
                  _choice(
                    'actions-rule-selector',
                    _selected,
                    {
                      for (final rule in rules)
                        rule['id'] as String:
                            '${rule['name'] ?? '규칙'}${rule['archived'] == true ? ' (보관됨)' : ''}',
                      if (_draft != null &&
                          !rules.any((r) => r['id'] == _selected))
                        _selected!: '${_draft!['name']}',
                    },
                    '규칙 선택',
                    (id) => _run(() => _select(id)),
                    enabled: !_locked && !_saving,
                  ),
                if (_draft == null)
                  const Text('새 규칙을 만들어 버튼과 반복 작업을 설정하세요.')
                else
                  _ruleEditor(),
              ] else if (_tab == 'schedule')
                _scheduleList()
              else
                _history(),
            ],
          ),
        ),
      ],
    );
  }
}

Map<String, dynamic> _copy(Map<String, dynamic> value) =>
    jsonDecode(jsonEncode(value)) as Map<String, dynamic>;
