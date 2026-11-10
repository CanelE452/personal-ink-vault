import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:ink_vault_core/ink_vault_core.dart' show newId;
import 'package:saber/data/vault/block_page_document.dart';
import 'package:saber/data/vault/block_page_media.dart';
import 'package:saber/data/vault/database_actions.dart';
import 'package:saber/data/vault/database_query.dart';
import 'package:saber/data/vault/database_query_native.dart';
import 'package:saber/data/vault/workspace_database.dart';
import 'package:saber/pages/workspace/block_page_editor.dart';
import 'package:saber/pages/workspace/database_automations_panel.dart';
import 'package:saber/pages/workspace/database_forms_editor.dart';
import 'package:saber/pages/workspace/database_task_links_dialog.dart';
import 'package:saber/pages/workspace/database_view_filter_editor.dart';
import 'package:saber/pages/workspace/database_view_sort_editor.dart';

part 'database_dashboard.dart';

enum _RowTemplateAction { apply, schedule, remove }

typedef _TaskRow = ({DatabaseRow row, int depth, int childCount});
typedef _TimelineLink = ({
  int predecessorLane,
  int dependentLane,
  double startX,
  double endX,
  bool forward,
});

class DatabaseEditor extends StatefulWidget {
  const new({
    super.key,
    required this.initialDatabase,
    required this.onSave,
    required this.onBack,
    this.onHistory,
    this.onDirtyChanged,
    this.onBusyChanged,
    this.currentRevision,
    this.actionRuntime,
    this.queryRuntime,
    this.databases = const {},
    this.dashboardDatabaseTitles = const {},
    this.dashboardSourcesReady = true,
    this.onOpenDashboardView,
    this.initialViewId,
    this.notes = const [],
    this.onOpenNote,
    this.onSaveWithMedia,
    this.onReadRowMedia,
    this.viewOverride,
    this.onViewOverrideChanged,
    this.embedded = false,
    this.onDiscardChanges,
    this.autosaveDelay = const Duration(milliseconds: 700),
  });
  final WorkspaceDatabase initialDatabase;
  final Future<void> Function(WorkspaceDatabase) onSave;
  final Future<void> Function(WorkspaceDatabase, Map<String, Uint8List>)?
  onSaveWithMedia;
  final Future<Uint8List> Function(String rowId, BlockPageMedia)?
  onReadRowMedia;
  final VoidCallback onBack;
  final VoidCallback? onHistory;
  final ValueChanged<bool>? onDirtyChanged;
  final ValueChanged<bool>? onBusyChanged;
  final String Function()? currentRevision;
  final DatabaseActionRuntime? actionRuntime;
  final DatabaseQueryRuntime? queryRuntime;
  final Map<String, WorkspaceDatabase> databases;
  final Map<String, String> dashboardDatabaseTitles;
  final bool dashboardSourcesReady;
  final Future<void> Function(String databaseId, String viewId)?
  onOpenDashboardView;
  final String? initialViewId;
  final List<BlockPageNote> notes;
  final ValueChanged<String>? onOpenNote;
  final DatabaseView? viewOverride;
  final ValueChanged<DatabaseView>? onViewOverrideChanged;
  final bool embedded;
  final VoidCallback? onDiscardChanges;
  final Duration autosaveDelay;
  @override
  State<DatabaseEditor> createState() => DatabaseEditorState();
}

class DatabaseEditorState extends State<DatabaseEditor> {
  static const _teal = Color(0xff237d82);
  static const _duplicateViewAction = 'database-view-duplicate';
  late WorkspaceDatabase _database;
  late DatabaseView _fallbackView;
  String? _selectedView;
  DateTime? _calendarMonth;
  var _generation = 0;
  var _savedGeneration = 0;
  var _saving = false;
  var _dragging = false;
  var _bodyDirty = false;
  var _bodyBusy = false;
  var _reportedDirty = false;
  var _reportedBusy = false;
  var _saveFailed = false;
  var _configurationOpen = false;
  String? _error;
  String? _draftError;
  Timer? _autosave;
  Future<void>? _saveFuture;
  Future<void>? _writer;
  final _pendingMedia = <String, Uint8List>{};
  final _collapsedTasks = <String>{};
  final _timelineScroll = ScrollController();
  Completer<void>? _dragDone;
  GlobalKey<BlockPageEditorState>? _bodyKey;
  String? _bodyRowId;
  MaterialPageRoute<void>? _bodyRoute;
  DialogRoute<bool>? _cellRoute;
  DialogRoute<WorkspaceDatabase>? _taskLinksRoute;
  GlobalKey<DatabaseFormsPanelState>? _formsKey;
  MaterialPageRoute<void>? _formsRoute;
  var _formsOpening = false;
  var _formsDirty = false;
  var _formsBusy = false;
  GlobalKey<DatabaseAutomationsPanelState>? _actionsKey;
  MaterialPageRoute<void>? _actionsRoute;
  var _actionsOpening = false;
  var _actionsDirty = false;
  var _actionsBusy = false;
  bool Function()? _cellCommit;

  WorkspaceDatabase get database => _database;
  String? get selectedViewId =>
      _database.views.where((view) => view.id == _selectedView).firstOrNull?.id;
  bool get canDiscardDraft =>
      !_saving &&
      !_dragging &&
      _writer == null &&
      _saveFuture == null &&
      !_bodyBusy &&
      !_formsBusy &&
      !_actionsBusy &&
      !_formsOpening &&
      !_actionsOpening;

  void discardDraft() {
    if (!canDiscardDraft) throw StateError('저장 중인 작업을 먼저 마치세요.');
    _autosave?.cancel();
    _cellCommit = null;
  }

  bool get _dirty =>
      _generation != _savedGeneration ||
      _bodyDirty ||
      _formsDirty ||
      _actionsDirty ||
      _draftError != null ||
      _configurationOpen;
  DatabaseView get _view =>
      widget.viewOverride ??
      _database.views.where((view) => view.id == _selectedView).firstOrNull ??
      _database.views.firstOrNull ??
      _fallbackView;
  DatabaseProperty? get _titleProperty => _database.properties
      .where((property) => property.type == 'title')
      .firstOrNull;
  bool get _canEditTaskLinks =>
      widget.actionRuntime != null && _database.supportsTaskLinks;
  DatabaseQuery _query({
    DatabaseView? view,
    WorkspaceDatabase? database,
    List<String>? valuePropertyIds,
    DateTime? capturedAt,
  }) {
    final now = capturedAt ?? DateTime.now().toUtc();
    final runtime = widget.queryRuntime;
    final primary = database ?? _database;
    if (runtime != null)
      return runtime.project(
        primary,
        view: view ?? _view,
        databases: primary.id == _database.id
            ? widget.databases
            : {...widget.databases, _database.id: _database},
        now: now,
        valuePropertyIds: valuePropertyIds,
      );
    return DatabaseQuery(
      primary,
      resolver: (id) => id == primary.id
          ? primary
          : id == _database.id
          ? _database
          : widget.databases[id],
      now: now,
    );
  }

  @override
  void initState() {
    super.initState();
    _database = widget.initialDatabase;
    _fallbackView = DatabaseView.create();
    _selectedView =
        _database.views
            .firstWhereOrNull((view) => view.id == widget.initialViewId)
            ?.id ??
        _database.views.firstOrNull?.id;
  }

  @override
  void didUpdateWidget(covariant DatabaseEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialViewId != widget.initialViewId &&
        _database.views.any((view) => view.id == widget.initialViewId)) {
      _selectedView = widget.initialViewId;
      _calendarMonth = null;
    }
    final previous = oldWidget.viewOverride, current = widget.viewOverride;
    if (previous?.id != current?.id ||
        previous?.type != current?.type ||
        previous?.config['datePropertyId'] !=
            current?.config['datePropertyId']) {
      _calendarMonth = null;
    }
  }

  void _report() {
    if (!mounted) return;
    final busy =
        _saving ||
        _dragging ||
        _bodyBusy ||
        _formsOpening ||
        _formsBusy ||
        _formsRoute != null ||
        _actionsOpening ||
        _actionsBusy ||
        _actionsRoute != null ||
        _cellRoute != null ||
        _taskLinksRoute != null ||
        _bodyRoute != null;
    if (_reportedDirty != _dirty) {
      _reportedDirty = _dirty;
      widget.onDirtyChanged?.call(_dirty);
    }
    if (_reportedBusy != busy) {
      _reportedBusy = busy;
      widget.onBusyChanged?.call(busy);
    }
  }

  void _change(WorkspaceDatabase next) {
    setState(() {
      _database = next;
      _generation++;
      _error = null;
    });
    _report();
    _scheduleAutosave();
  }

  void _scheduleAutosave() {
    _autosave?.cancel();
    if (_cellRoute != null) return;
    _autosave = Timer(widget.autosaveDelay, () {
      if (mounted) unawaited(_saveAutomatically());
    });
  }

  void _updateView(DatabaseView view) {
    if (widget.viewOverride != null) {
      final changed = widget.onViewOverrideChanged;
      if (changed == null) return;
      changed(view);
      setState(() {
        _calendarMonth = null;
        _error = null;
      });
      return;
    }
    _change(
      _database.views.any((item) => item.id == view.id)
          ? _database.updateView(view)
          : _database.addView(view),
    );
  }

  void _selectView(DatabaseView view) => setState(() {
    _selectedView = view.id;
    _calendarMonth = null;
  });

  void _addView(String type) {
    final DatabaseView view;
    if (type == _duplicateViewAction) {
      final source = _view;
      final layout = source.type == databaseDashboardViewType
          ? _DashboardLayout.read(source.config['dashboardRows'])
          : null;
      final names = _database.views.map((view) => view.name).toSet();
      final base = '${source.name} 복사본';
      var name = base;
      for (var number = 2; names.contains(name); number++) {
        name = '$base $number';
      }
      view = DatabaseView.fromJson({
        ...source.toJson(),
        'id': newId(),
        'name': name,
        if (layout != null)
          'config': {
            ...source.config,
            'dashboardRows': layout.duplicate().toJson(),
          },
      });
    } else {
      view = DatabaseView.create(
        name: _viewLabels[type] ?? type,
        type: type,
        groupBy: type == databaseDashboardViewType
            ? null
            : _database.properties
                  .where(
                    (property) =>
                        property.type == 'status' || property.type == 'select',
                  )
                  .firstOrNull
                  ?.id,
      );
    }
    _change(_database.addView(view));
    _selectView(view);
  }

  String _currentRevision() {
    final read = widget.currentRevision;
    if (read == null) throw StateError('이 데이터베이스의 저장 판본을 확인할 수 없습니다.');
    return read();
  }

  WorkspaceDatabase _prepareCell(
    WorkspaceDatabase base,
    String rowId,
    DatabaseProperty property,
    Object? value, {
    required String eventId,
    required String inputRevision,
    required int capturedAtUtcMs,
  }) {
    final old = base.rows
        .firstWhere((row) => row.id == rowId)
        .values[property.id];
    final changed = base.setCell(rowId, property.id, value);
    final runtime = widget.actionRuntime;
    if (runtime == null ||
        !databaseActionPropertyTypes.contains(property.type)) {
      return changed;
    }
    return runtime
        .preparePropertyChanged(
          changed,
          eventId: eventId,
          rowId: rowId,
          propertyId: property.id,
          oldValue: old,
          value: value,
          inputRevision: inputRevision,
          capturedAtUtcMs: capturedAtUtcMs,
        )
        .database;
  }

  void _setCell(DatabaseRow row, DatabaseProperty property, Object? value) {
    final old = _database.rows
        .firstWhere((item) => item.id == row.id)
        .values[property.id];
    if (const DeepCollectionEquality().equals(old, value)) return;
    if (widget.actionRuntime == null ||
        !databaseActionPropertyTypes.contains(property.type)) {
      _change(_database.setCell(row.id, property.id, value));
      return;
    }
    final next = _prepareCell(
      _database,
      row.id,
      property,
      value,
      eventId: newId(),
      inputRevision: _currentRevision(),
      capturedAtUtcMs: DateTime.now().toUtc().millisecondsSinceEpoch,
    );
    _change(next);
  }

  Future<void> save() {
    _autosave?.cancel();
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
    try {
      if (_formsOpening) throw StateError('입력 폼을 여는 중입니다. 잠시 후 다시 시도하세요.');
      if (_actionsOpening) throw StateError('자동화 설정을 여는 중입니다. 잠시 후 다시 시도하세요.');
      if (_configurationOpen) throw StateError('열려 있는 설정에서 적용하거나 취소해 주세요.');
      if (_draftError != null) throw StateError(_draftError!);
      await _dragDone?.future;
      await _bodyKey?.currentState?.save();
      await _formsKey?.currentState?.save();
      await _actionsKey?.currentState?.save();
      final cellRoute = _cellRoute;
      if (cellRoute != null && cellRoute.isActive) {
        if (!cellRoute.isCurrent) throw StateError('열려 있는 날짜 선택을 먼저 닫아 주세요.');
        if (_cellCommit?.call() == false)
          throw StateError(_draftError ?? '입력을 확인해 주세요.');
        cellRoute.navigator?.pop(true);
        await cellRoute.completed;
      }
      await _persist();
      if (_configurationOpen) throw StateError('열려 있는 설정에서 적용하거나 취소해 주세요.');
      if (_draftError != null) throw StateError(_draftError!);
      final actionsRoute = _actionsRoute;
      if (actionsRoute != null && actionsRoute.isActive) {
        if (!actionsRoute.isCurrent) throw StateError('자동화의 열린 설정을 먼저 닫아 주세요.');
        actionsRoute.navigator?.pop();
        await actionsRoute.completed;
      }
      final formsRoute = _formsRoute;
      if (formsRoute != null && formsRoute.isActive) {
        if (!formsRoute.isCurrent) throw StateError('입력 폼의 열린 설정을 먼저 닫아 주세요.');
        formsRoute.navigator?.pop();
        await formsRoute.completed;
      }
      final bodyRoute = _bodyRoute;
      if (bodyRoute != null && bodyRoute.isActive) {
        if (!bodyRoute.isCurrent) throw StateError('행 본문의 열린 설정을 먼저 닫아 주세요.');
        bodyRoute.navigator?.pop();
        await bodyRoute.completed;
      }
      if (mounted && _saveFailed) setState(() => _saveFailed = false);
    } catch (_) {
      if (mounted) setState(() => _saveFailed = true);
      rethrow;
    }
  }

  Future<void> _persist() {
    final current = _writer;
    if (current != null) return current;
    late Future<void> tracked;
    tracked = _persistNow().whenComplete(() {
      if (identical(_writer, tracked)) _writer = null;
    });
    _writer = tracked;
    return tracked;
  }

  Map<String, Uint8List> _filesFor(WorkspaceDatabase database) => {
    for (final body in [
      for (final row in database.rows) row.body,
      for (final template in database.rowTemplates) template.body,
    ])
      for (final media in BlockPageDocument.fromJson(body).media.values)
        if (_pendingMedia[media.path] case final Uint8List bytes)
          media.path: bytes,
  };

  Future<void> _writeSnapshot(
    WorkspaceDatabase database,
    Map<String, Uint8List> pending,
  ) async {
    final saveMedia = widget.onSaveWithMedia;
    if (saveMedia == null) {
      if (pending.isNotEmpty) throw StateError('첨부 파일을 함께 저장할 수 없습니다.');
      await widget.onSave(database);
    } else {
      await saveMedia(
        database,
        Map.unmodifiable({
          for (final entry in pending.entries)
            entry.key: Uint8List.fromList(entry.value),
        }),
      );
    }
    for (final entry in pending.entries) {
      if (identical(_pendingMedia[entry.key], entry.value)) {
        _pendingMedia.remove(entry.key);
      }
    }
  }

  Future<void> _persistNow() async {
    _saving = true;
    _report();
    if (mounted) setState(() {});
    final owner = widget.initialDatabase;
    try {
      while (_generation != _savedGeneration) {
        if (!mounted || !identical(widget.initialDatabase, owner)) {
          throw StateError('데이터베이스 편집 세션이 바뀌었습니다.');
        }
        final generation = _generation;
        final database = _database;
        final pending = _filesFor(database);
        await _writeSnapshot(database, pending);
        if (!mounted || !identical(widget.initialDatabase, owner)) {
          throw StateError('데이터베이스 편집 세션이 바뀌었습니다.');
        }
        _savedGeneration = generation;
        _saveFailed = false;
        _report();
      }
    } catch (_) {
      _saveFailed = true;
      rethrow;
    } finally {
      _saving = false;
      if (mounted) {
        _report();
        setState(() {});
      }
    }
  }

  Future<void> _saveFromUi() async {
    try {
      await save();
    } catch (_) {}
  }

  Future<void> _saveAutomatically() async {
    try {
      await _persist();
    } catch (_) {}
  }

  Future<void> _back() async {
    try {
      await save();
      if (mounted) widget.onBack();
    } catch (_) {}
  }

  Future<T?> _showOwnedDialog<T>({
    required WidgetBuilder builder,
    bool barrierDismissible = true,
    ValueChanged<DialogRoute<T>>? onRoute,
  }) async {
    final route = DialogRoute<T>(
      context: context,
      builder: builder,
      barrierDismissible: barrierDismissible,
    );
    onRoute?.call(route);
    final result = await Navigator.of(context).push<T>(route);
    await route.completed;
    return result;
  }

  void _run(void Function() action) {
    try {
      action();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  void _startDrag() {
    _dragging = true;
    _dragDone ??= Completer<void>();
    _report();
    setState(() {});
  }

  void _finishDrag() {
    _dragging = false;
    final done = _dragDone;
    _dragDone = null;
    done?.complete();
    _report();
    if (mounted) setState(() {});
  }

  String _title(DatabaseRow row) => _rowTitle(row, _titleProperty?.id);

  String _rowTitle(DatabaseRow row, String? titlePropertyId) {
    final title = row.values[titlePropertyId];
    return title is String && title.trim().isNotEmpty ? title : '이름 없는 항목';
  }

  String _number(num value) => value == value.roundToDouble()
      ? value.toStringAsFixed(0)
      : value.toString();
  String _date(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';
  String _option(DatabaseProperty property, Object? raw) {
    if (raw == null || raw == '') return '비어 있음';
    final options = property.config['options'];
    if (options is List) {
      for (final option in options) {
        if (option is Map && (option['id'] == raw || option['name'] == raw))
          return '${option['name']}';
      }
    }
    return '$raw';
  }

  String _display(DatabaseProperty property, DatabaseValue result) {
    if (result.error != null) return '계산 오류';
    final value = result.value;
    if (value == null) return '—';
    if (value is num) return _number(value);
    if (property.type == 'checkbox') return value == true ? '선택됨' : '선택 안 됨';
    if (property.type == 'date') {
      try {
        final date = parseDatabaseDate(value);
        return date.allDay
            ? _date(date.start)
            : '${date.start.toIso8601String().replaceFirst('.000Z', 'Z')} (UTC)';
      } catch (_) {
        return '날짜 확인';
      }
    }
    if (property.type == 'status' || property.type == 'select')
      return _option(property, value);
    if (property.type == 'multiSelect' && value is List)
      return value.map((item) => _option(property, item)).join(', ');
    if (property.type == 'relation' && value is List)
      return '${value.length}개 연결';
    if (property.type == 'relation' && value is Map) return '1개 연결';
    if (property.type == 'files' && value is List)
      return value
          .map((file) => file is Map ? '${file['name']}' : '')
          .join(', ');
    if (property.type == 'people' && value is List)
      return value
          .map(
            (person) =>
                person is Map ? '${person['name'] ?? person['id']}' : '$person',
          )
          .join(', ');
    return '$value';
  }

  List<DatabaseProperty> get _visible => _view.visibleProperties.isEmpty
      ? _database.properties
      : [
          for (final id in _view.visibleProperties)
            ..._database.properties.where((property) => property.id == id),
        ];
  Widget _cell(
    DatabaseRow row,
    DatabaseProperty property,
    DatabaseQuery query,
  ) {
    final value = query.value(row, property.id);
    return Tooltip(
      message:
          value.error?.message ??
          (property.isComputed ? '계산된 값은 직접 바꿀 수 없습니다.' : property.name),
      child: TextButton(
        key: ValueKey('db-cell-${row.id}-${property.id}'),
        onPressed:
            property.isComputed ||
                !databasePropertyTypes.contains(property.type) ||
                _dragging
            ? null
            : () => unawaited(_editCell(row, property)),
        child: Text(_display(property, value), overflow: TextOverflow.ellipsis),
      ),
    );
  }

  Widget _rowMenu(DatabaseRow row) => PopupMenuButton<String>(
    key: ValueKey('db-row-menu-${row.id}'),
    tooltip: '항목 메뉴',
    enabled: !_dragging,
    onSelected: (value) {
      switch (value) {
        case 'addSubtask':
          _addRow(parentTaskId: row.id);
        case 'taskLinks':
          unawaited(_editTaskLinks(row));
        case 'template':
          unawaited(_saveRowTemplate(row));
        case 'archive':
          _change(_database.archiveRow(row.id));
      }
    },
    itemBuilder: (_) => [
      if (!row.archived && _canEditTaskLinks) ...[
        const PopupMenuItem(value: 'addSubtask', child: Text('하위 작업 추가')),
        const PopupMenuItem(value: 'taskLinks', child: Text('작업 연결')),
      ],
      if (!row.archived)
        const PopupMenuItem(value: 'template', child: Text('템플릿으로 저장')),
      const PopupMenuItem(value: 'archive', child: Text('보관')),
    ],
    icon: const Icon(Icons.more_horiz),
  );

  Widget _rowActions(DatabaseRow row) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      IconButton(
        key: ValueKey('db-row-open-${row.id}'),
        tooltip: '행 본문 열기',
        onPressed: _dragging ? null : () => unawaited(_openRow(row)),
        icon: const Icon(Icons.open_in_full, size: 18),
      ),
      _rowMenu(row),
    ],
  );

  List<_TaskRow> _taskRows(List<DatabaseRow> rows) {
    final links = _database.taskLinks;
    final active = {
      for (final row in rows)
        if (!row.archived) row.id,
    };
    final children = <String, List<DatabaseRow>>{};
    final roots = <DatabaseRow>[];
    for (final row in rows) {
      final parent = links[row.id]?.parentId;
      if (!row.archived &&
          parent != null &&
          parent != row.id &&
          active.contains(parent)) {
        children.putIfAbsent(parent, () => []).add(row);
      } else {
        roots.add(row);
      }
    }

    final result = <_TaskRow>[];
    final visited = <String>{};
    void walk(DatabaseRow root) {
      final stack = [(root, 0, true)];
      while (stack.isNotEmpty) {
        final (row, depth, visible) = stack.removeLast();
        if (!visited.add(row.id)) continue;
        final descendants = children[row.id] ?? const [];
        if (visible) {
          result.add((row: row, depth: depth, childCount: descendants.length));
        }
        final showChildren = visible && !_collapsedTasks.contains(row.id);
        for (final child in descendants.reversed) {
          stack.add((child, depth + 1, showChildren));
        }
      }
    }

    for (final root in roots) {
      walk(root);
    }
    for (final row in rows) {
      if (!visited.contains(row.id)) walk(row);
    }
    return result;
  }

  List<Widget> _taskIndent(_TaskRow task) => [
    if (task.depth > 0) SizedBox(width: math.min(task.depth, 4) * 12.0),
    if (task.childCount > 0)
      IconButton(
        key: ValueKey('db-task-children-${task.row.id}'),
        tooltip: _collapsedTasks.contains(task.row.id)
            ? '하위 작업 ${task.childCount}개 펼치기'
            : '하위 작업 ${task.childCount}개 접기',
        onPressed: () => setState(() {
          if (!_collapsedTasks.add(task.row.id)) {
            _collapsedTasks.remove(task.row.id);
          }
        }),
        icon: Icon(
          _collapsedTasks.contains(task.row.id)
              ? Icons.chevron_right
              : Icons.expand_more,
          size: 20,
        ),
        constraints: const BoxConstraints.tightFor(width: 32, height: 40),
        padding: EdgeInsets.zero,
      ),
  ];

  Widget _table(List<DatabaseRow> rows, DatabaseQuery query) {
    final properties = _visible;
    final titleId = _titleProperty?.id;
    final hasTitle = properties.any((property) => property.id == titleId);
    return SingleChildScrollView(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          columnSpacing: 20,
          horizontalMargin: 16,
          columns: [
            const DataColumn(label: Text('본문')),
            for (final property in properties)
              DataColumn(
                label: TextButton(
                  onPressed: _dragging
                      ? null
                      : () => unawaited(_editProperty(property)),
                  child: Text(property.name),
                ),
              ),
          ],
          rows: [
            for (final task in _taskRows(rows))
              DataRow(
                key: ValueKey('db-table-row-${task.row.id}'),
                cells: [
                  DataCell(
                    hasTitle
                        ? _rowActions(task.row)
                        : Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              ..._taskIndent(task),
                              _rowActions(task.row),
                            ],
                          ),
                  ),
                  for (final property in properties)
                    DataCell(
                      property.id == titleId
                          ? Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                ..._taskIndent(task),
                                _cell(task.row, property, query),
                              ],
                            )
                          : _cell(task.row, property, query),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _card(
    DatabaseRow row,
    DatabaseQuery query, {
    String? keyPrefix,
  }) => Card(
    key: keyPrefix == null ? null : ValueKey('$keyPrefix${row.id}'),
    margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _title(row),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              _rowActions(row),
            ],
          ),
          for (final property
              in _visible
                  .where((property) => property.id != _titleProperty?.id)
                  .take(3))
            Text(
              '${property.name}: ${_display(property, query.value(row, property.id))}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
        ],
      ),
    ),
  );
  Widget _draggable(DatabaseRow row, Widget child) => Draggable<String>(
    data: row.id,
    onDragStarted: _startDrag,
    onDragEnd: (_) => _finishDrag(),
    feedback: Material(
      elevation: 6,
      child: SizedBox(
        width: 220,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Text(_title(row)),
        ),
      ),
    ),
    childWhenDragging: Opacity(opacity: .3, child: child),
    child: child,
  );
  Widget _board(DatabaseQueryResult result, DatabaseQuery query) {
    final property = _database.properties
        .where((property) => property.id == _view.groupBy)
        .firstOrNull;
    if (property == null)
      return const Center(child: Text('보기 설정에서 묶을 속성을 선택하세요.'));
    final keys = <String>{
      if (property.config['options'] is List)
        for (final option in property.config['options'] as List)
          if (option is Map) '${option['id'] ?? option['name']}' else '$option',
      ...result.groups.keys,
    };
    if (keys.isEmpty) keys.add('');
    final movable =
        const {
          'title',
          'text',
          'status',
          'select',
          'number',
          'checkbox',
        }.contains(property.type) &&
        !property.isComputed;
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          height: constraints.maxHeight,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final key in keys)
                SizedBox(
                  width: 260,
                  child: DragTarget<String>(
                    key: ValueKey('db-board-target-$key'),
                    onWillAcceptWithDetails: (_) => movable,
                    onAcceptWithDetails: (details) => _run(() {
                      final row = _database.rows.firstWhere(
                        (row) => row.id == details.data,
                      );
                      final Object? value = key.isEmpty
                          ? null
                          : property.type == 'number'
                          ? num.parse(key)
                          : property.type == 'checkbox'
                          ? key == 'true'
                          : key;
                      _setCell(row, property, value);
                    }),
                    builder: (context, candidates, rejected) => DecoratedBox(
                      decoration: BoxDecoration(
                        color: candidates.isNotEmpty
                            ? const Color(0xffdff0ed)
                            : const Color(0xfff3f6f0),
                        border: Border.all(color: const Color(0xffd7dfd8)),
                      ),
                      child: Column(
                        children: [
                          Padding(
                            padding: const EdgeInsets.all(14),
                            child: Text(
                              '${_option(property, key)} · ${result.groups[key]?.length ?? 0}',
                            ),
                          ),
                          Expanded(
                            child: ListView(
                              children: [
                                for (final row
                                    in result.groups[key] ?? <DatabaseRow>[])
                                  if (movable)
                                    _draggable(
                                      row,
                                      _card(
                                        row,
                                        query,
                                        keyPrefix: 'db-board-row-',
                                      ),
                                    )
                                  else
                                    _card(
                                      row,
                                      query,
                                      keyPrefix: 'db-board-row-',
                                    ),
                              ],
                            ),
                          ),
                          if (!movable)
                            const Padding(
                              padding: EdgeInsets.all(8),
                              child: Text('이 속성은 묶음 표시만 지원합니다.'),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _list(List<DatabaseRow> rows, DatabaseQuery query) => ListView(
    children: [
      for (final task in _taskRows(rows))
        ListTile(
          key: ValueKey('db-list-row-${task.row.id}'),
          title: Row(
            children: [
              ..._taskIndent(task),
              Expanded(child: Text(_title(task.row))),
            ],
          ),
          subtitle: Text(
            [
              for (final property
                  in _visible
                      .where((property) => property.id != _titleProperty?.id)
                      .take(3))
                '${property.name}: ${_display(property, query.value(task.row, property.id))}',
            ].join(' · '),
          ),
          trailing: _rowActions(task.row),
          onTap: () => unawaited(_openRow(task.row)),
        ),
    ],
  );
  Widget _gallery(List<DatabaseRow> rows, DatabaseQuery query) =>
      GridView.builder(
        padding: const EdgeInsets.all(12),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 340,
          mainAxisExtent: 210,
          crossAxisSpacing: 8,
          mainAxisSpacing: 8,
        ),
        itemCount: rows.length,
        itemBuilder: (_, index) =>
            _card(rows[index], query, keyPrefix: 'db-gallery-row-'),
      );

  DatabaseProperty? get _dateProperty => _datePropertyFor(_view);

  DatabaseProperty? _datePropertyFor(
    DatabaseView view, {
    WorkspaceDatabase? database,
  }) {
    final properties = (database ?? _database).properties;
    final id = view.config['datePropertyId'];
    if (view.config.containsKey('datePropertyId')) {
      return properties
          .where((property) => property.id == id && property.type == 'date')
          .firstOrNull;
    }
    return properties.where((property) => property.type == 'date').firstOrNull;
  }

  void _moveDate(String rowId, DateTime day) {
    final property = _dateProperty;
    if (property == null) return;
    final row = _database.rows.firstWhere((row) => row.id == rowId);
    final raw = row.values[property.id];
    final old = parseDatabaseDate(raw);
    final delta = day.difference(
      DateTime.utc(old.start.year, old.start.month, old.start.day),
    );
    final start = old.start.add(delta), end = old.end?.add(delta);
    Object next;
    if (raw is String && old.allDay)
      next = _date(start);
    else
      next = {
        if (raw is Map) ...Map<String, dynamic>.from(raw),
        'start': old.allDay ? _date(start) : start.toIso8601String(),
        if (end != null) 'end': old.allDay ? _date(end) : end.toIso8601String(),
      };
    _setCell(row, property, next);
  }

  Widget _calendar(DatabaseQuery query) {
    final property = _dateProperty;
    if (property == null)
      return const Center(child: Text('보기 설정에서 날짜 속성을 선택하세요.'));
    final items = query.calendar(propertyId: property.id, view: _view);
    final initial = items.firstOrNull?.start ?? DateTime.now().toUtc();
    final month = _calendarMonth ?? DateTime.utc(initial.year, initial.month);
    final first = DateTime.utc(month.year, month.month, 1);
    final offset = first.weekday - 1;
    final days = DateTime.utc(month.year, month.month + 1, 0).day;
    final weeks = ((offset + days) / 7).ceil();
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = math.max(700.0, constraints.maxWidth);
        return SingleChildScrollView(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: width,
              child: Column(
                children: [
                  Row(
                    children: [
                      IconButton(
                        tooltip: '이전 달',
                        onPressed: () => setState(
                          () => _calendarMonth = DateTime.utc(
                            month.year,
                            month.month - 1,
                          ),
                        ),
                        icon: const Icon(Icons.chevron_left),
                      ),
                      Text('${month.year}년 ${month.month}월'),
                      IconButton(
                        tooltip: '다음 달',
                        onPressed: () => setState(
                          () => _calendarMonth = DateTime.utc(
                            month.year,
                            month.month + 1,
                          ),
                        ),
                        icon: const Icon(Icons.chevron_right),
                      ),
                      const Text('날짜와 시각은 UTC 기준'),
                    ],
                  ),
                  Row(
                    children: [
                      for (final name in ['월', '화', '수', '목', '금', '토', '일'])
                        SizedBox(
                          width: width / 7,
                          child: Center(child: Text(name)),
                        ),
                    ],
                  ),
                  for (var week = 0; week < weeks; week++)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (var weekday = 0; weekday < 7; weekday++)
                          Builder(
                            builder: (context) {
                              final day = week * 7 + weekday - offset + 1;
                              if (day < 1 || day > days)
                                return SizedBox(width: width / 7, height: 104);
                              final date = DateTime.utc(
                                month.year,
                                month.month,
                                day,
                              );
                              final dateText = _date(date);
                              final dayItems = items
                                  .where(
                                    (item) => _date(item.start) == dateText,
                                  )
                                  .toList();
                              return SizedBox(
                                width: width / 7,
                                height: 104,
                                child: DragTarget<String>(
                                  key: ValueKey('db-calendar-day-$dateText'),
                                  onAcceptWithDetails: (details) =>
                                      _run(() => _moveDate(details.data, date)),
                                  builder: (context, candidates, rejected) =>
                                      DecoratedBox(
                                        decoration: BoxDecoration(
                                          color: candidates.isEmpty
                                              ? Colors.white
                                              : const Color(0xffdff0ed),
                                          border: Border.all(
                                            color: const Color(0xffe0e5de),
                                          ),
                                        ),
                                        child: Padding(
                                          padding: const EdgeInsets.all(6),
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text('$day'),
                                              for (final item in dayItems.take(
                                                dayItems.length > 2 ? 1 : 2,
                                              ))
                                                _draggable(
                                                  _database.rows.firstWhere(
                                                    (row) =>
                                                        row.id == item.rowId,
                                                  ),
                                                  Container(
                                                    key: ValueKey(
                                                      'db-calendar-row-${item.rowId}',
                                                    ),
                                                    padding:
                                                        const EdgeInsets.all(4),
                                                    color: const Color(
                                                      0xffdff0ed,
                                                    ),
                                                    child: Text(
                                                      _title(
                                                        _database.rows
                                                            .firstWhere(
                                                              (row) =>
                                                                  row.id ==
                                                                  item.rowId,
                                                            ),
                                                      ),
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                    ),
                                                  ),
                                                ),
                                              if (dayItems.length > 2)
                                                TextButton(
                                                  style: TextButton.styleFrom(
                                                    padding: EdgeInsets.zero,
                                                    minimumSize: const Size(
                                                      24,
                                                      20,
                                                    ),
                                                    tapTargetSize:
                                                        MaterialTapTargetSize
                                                            .shrinkWrap,
                                                  ),
                                                  onPressed: () => unawaited(
                                                    _showRows(
                                                      items
                                                          .where(
                                                            (item) =>
                                                                _date(
                                                                  item.start,
                                                                ) ==
                                                                dateText,
                                                          )
                                                          .map(
                                                            (item) =>
                                                                item.rowId,
                                                          )
                                                          .toList(),
                                                    ),
                                                  ),
                                                  child: const Text('더 보기'),
                                                ),
                                            ],
                                          ),
                                        ),
                                      ),
                                ),
                              );
                            },
                          ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _timeline(DatabaseQuery query) {
    final property = _dateProperty;
    if (property == null)
      return const Center(child: Text('보기 설정에서 날짜 속성을 선택하세요.'));
    final items = query.calendar(propertyId: property.id, view: _view);
    if (items.isEmpty) return const Center(child: Text('일정이 없습니다.'));
    final start = DateTime.utc(
      items.first.start.year,
      items.first.start.month,
      items.first.start.day,
    );
    final last = items
        .map((item) => item.end ?? item.start)
        .reduce((a, b) => a.isAfter(b) ? a : b);
    final days = math.max(1, last.difference(start).inDays + 1);
    final axisWidth = math.min(4800.0, math.max(900.0, days * 40.0));
    final unit = axisWidth / days;
    const labelWidth = 180.0, laneHeight = 60.0, barCenter = 26.0;
    final rows = {for (final row in _database.rows) row.id: row};
    final lanes = {for (final (i, item) in items.indexed) item.rowId: i};
    final bars = [
      for (final item in items)
        (
          left: item.start.difference(start).inDays * unit,
          right: math.min(
            axisWidth,
            item.start.difference(start).inDays * unit +
                math.max(
                  24.0,
                  ((item.end ?? item.start).difference(item.start).inDays + 1) *
                      unit,
                ),
          ),
        ),
    ];
    final links = <_TimelineLink>[];
    final predecessors = <String, List<String>>{};
    final taskLinks = _database.taskLinks;
    for (final (index, item) in items.indexed) {
      for (final id
          in taskLinks[item.rowId]?.predecessorIds ?? const <String>[]) {
        final predecessorLane = lanes[id];
        if (predecessorLane == null || predecessorLane == index) continue;
        final source = bars[predecessorLane], destination = bars[index];
        final forward = source.right <= destination.left;
        links.add((
          predecessorLane: predecessorLane,
          dependentLane: index,
          startX: labelWidth + (forward ? source.right : source.left),
          endX: labelWidth + (forward ? destination.left : destination.right),
          forward: forward,
        ));
        predecessors.putIfAbsent(item.rowId, () => []).add(_title(rows[id]!));
      }
    }
    Widget lane(int index) {
      final item = items[index], bar = bars[index];
      final row = rows[item.rowId]!;
      final title = _title(row);
      final before = predecessors[item.rowId] ?? const <String>[];
      final summary = [
        ...before.take(3),
        if (before.length > 3) '외 ${before.length - 3}개',
      ].join(', ');
      return SizedBox(
        height: laneHeight,
        child: Row(
          children: [
            SizedBox(
              width: labelWidth,
              child: Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () => unawaited(_openRow(row)),
                      child: Text(title, overflow: TextOverflow.ellipsis),
                    ),
                  ),
                  if (_canEditTaskLinks) _rowMenu(row),
                ],
              ),
            ),
            SizedBox(
              width: axisWidth,
              child: Stack(
                children: [
                  Positioned(
                    left: bar.left,
                    top: 8,
                    width: bar.right - bar.left,
                    height: 36,
                    child: Tooltip(
                      message: [
                        '${item.start.toIso8601String()}${item.end == null ? '' : ' ~ ${item.end!.toIso8601String()}'} UTC',
                        if (before.isNotEmpty) '선행 작업: $summary',
                      ].join('\n'),
                      child: ColoredBox(
                        key: ValueKey('db-timeline-row-${item.rowId}'),
                        color: const Color(0xff83b9b3),
                        child: Center(
                          child: Text(title, overflow: TextOverflow.ellipsis),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: labelWidth + axisWidth,
          height: constraints.maxHeight,
          child: Column(
            children: [
              SizedBox(
                height: 44,
                child: Row(
                  children: [
                    const SizedBox(width: labelWidth),
                    for (var i = 0; i < 6; i++)
                      SizedBox(
                        width: axisWidth / 6,
                        child: Text(
                          _date(
                            start.add(Duration(days: (days * i / 6).floor())),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: Stack(
                  children: [
                    ListView.builder(
                      controller: _timelineScroll,
                      itemCount: items.length,
                      itemExtent: laneHeight,
                      itemBuilder: (_, index) => lane(index),
                    ),
                    if (links.isNotEmpty)
                      Positioned.fill(
                        child: IgnorePointer(
                          child: CustomPaint(
                            key: const ValueKey('db-timeline-task-links'),
                            painter: _TimelineTaskLinksPainter(
                              links: links,
                              scroll: _timelineScroll,
                              laneHeight: laneHeight,
                              barCenter: barCenter,
                              labelWidth: labelWidth,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _chart(DatabaseQuery query) {
    if (_hasInvalidStringSettings(_view.config, const {
      'chartGroupBy',
      'chartValuePropertyId',
      'chartCalculation',
      'chartType',
    })) {
      return const Center(child: Text('차트 설정을 읽을 수 없습니다. 원본 설정은 보존됩니다.'));
    }
    final group = _view.config.containsKey('chartGroupBy')
        ? _string(_view.config['chartGroupBy'])
        : _view.groupBy;
    if (group == null)
      return const Center(child: Text('보기 설정에서 차트를 묶을 속성을 선택하세요.'));
    final points = query.chart(
      groupBy: group,
      valuePropertyId: _string(_view.config['chartValuePropertyId']),
      calculation: _string(_view.config['chartCalculation']) ?? 'count',
      view: _view,
    );
    if (points.isEmpty) return const Center(child: Text('차트에 표시할 값이 없습니다.'));
    final type = _string(_view.config['chartType']) ?? 'bar';
    if (!const {'bar', 'pie', 'line'}.contains(type))
      return const Center(child: Text('이 차트 모양은 아직 지원하지 않습니다. 원본 설정은 보존됩니다.'));
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        if (type != 'bar')
          SizedBox(
            height: 230,
            child: CustomPaint(painter: _DatabaseChartPainter(points, type)),
          ),
        for (final point in points)
          InkWell(
            onTap: () => unawaited(_showRows(point.rowIds)),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(child: Text(point.label)),
                      Text(
                        _number(point.value),
                        key: ValueKey('db-chart-value-${point.key}'),
                      ),
                    ],
                  ),
                  if (type == 'bar')
                    SizedBox(
                      height: 28,
                      width: double.infinity,
                      child: CustomPaint(
                        painter: _DatabaseChartPainter(
                          [point],
                          'bar',
                          range: points
                              .map((point) => point.value.toDouble())
                              .toList(),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        if (type == 'pie' && points.any((point) => point.value < 0))
          const Text('음수가 있는 값은 막대 또는 선 차트로 확인하세요.'),
      ],
    );
  }

  Future<void> _showRows(List<String> ids) async {
    final chosen = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('차트·일정의 항목'),
        content: SizedBox(
          width: 480,
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final row in _database.rows.where(
                (row) => ids.contains(row.id),
              ))
                ListTile(
                  title: Text(_title(row)),
                  onTap: () => Navigator.pop(context, row.id),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('닫기'),
          ),
        ],
      ),
    );
    if (chosen != null && mounted)
      await _openRow(_database.rows.firstWhere((row) => row.id == chosen));
  }

  Future<void> _openRow(DatabaseRow row) async {
    if (_bodyRoute != null ||
        _formsRoute != null ||
        _actionsRoute != null ||
        _formsOpening ||
        _actionsOpening ||
        _cellRoute != null ||
        _dragging)
      return;
    BlockPageDocument body;
    try {
      body = BlockPageDocument.fromJson(row.body);
    } catch (error) {
      setState(() => _error = '이 행의 본문을 열 수 없습니다. 원본은 보존됩니다. $error');
      return;
    }
    final owner = widget.initialDatabase;
    final key = GlobalKey<BlockPageEditorState>();
    _bodyKey = key;
    _bodyRowId = row.id;
    late MaterialPageRoute<void> route;
    DatabaseRow ownedRow() {
      final current = _database.rows
          .where((item) => item.id == row.id)
          .firstOrNull;
      if (!mounted ||
          !identical(widget.initialDatabase, owner) ||
          !identical(_bodyKey, key) ||
          !identical(_bodyRoute, route) ||
          _bodyRowId != row.id ||
          !route.isActive ||
          current == null ||
          current.archived) {
        throw StateError('이전 행의 늦은 작업을 거부했습니다.');
      }
      return current;
    }

    Future<void> saveRow(
      BlockPageDocument document,
      Map<String, Uint8List> files,
    ) async {
      final current = ownedRow();
      _pendingMedia.addAll({
        for (final entry in files.entries)
          entry.key: Uint8List.fromList(entry.value),
      });
      _change(_database.updateRow(current.copyWith(body: document.toJson())));
      await _persist();
      ownedRow();
    }

    Future<Uint8List> readRowMedia(BlockPageMedia media) async {
      bool registered() {
        ownedRow();
        return key.currentState?.document.media.values.any(
              (value) => const DeepCollectionEquality().equals(
                value.toJson(),
                media.toJson(),
              ),
            ) ??
            false;
      }

      if (!registered()) throw StateError('현재 행에 등록된 첨부가 아닙니다.');
      final pending = _pendingMedia[media.path];
      final reader = widget.onReadRowMedia;
      if (pending == null && reader == null)
        throw StateError('첨부 파일을 읽을 수 없습니다.');
      if (pending == null && _generation != _savedGeneration) {
        await WidgetsBinding.instance.endOfFrame;
        if (!registered()) throw StateError('행의 첨부가 바뀌었습니다.');
        if (_generation != _savedGeneration) await _persist();
        if (!registered()) throw StateError('행의 첨부가 바뀌었습니다.');
      }
      final bytes = Uint8List.fromList(pending ?? await reader!(row.id, media));
      if (!registered()) throw StateError('행의 첨부가 바뀌었습니다.');
      return bytes;
    }

    route = MaterialPageRoute<void>(
      builder: (_) => PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) unawaited(_closeRow());
        },
        child: Scaffold(
          body: BlockPageEditor(
            key: key,
            initialDocument: body,
            notes: widget.notes,
            autosaveDelay: widget.autosaveDelay,
            onSave: (document) => saveRow(document, const {}),
            onSaveWithMedia: widget.onSaveWithMedia == null ? null : saveRow,
            onReadMedia: widget.onReadRowMedia == null ? null : readRowMedia,
            onDirtyChanged: (dirty) {
              if (mounted && identical(_bodyKey, key)) {
                _bodyDirty = dirty;
                _report();
              }
            },
            onBusyChanged: (busy) {
              if (mounted && identical(_bodyKey, key)) {
                _bodyBusy = busy;
                _report();
              }
            },
            onBack: () => unawaited(_closeRow()),
            onDiscardChanges: widget.onDiscardChanges,
            onOpenNote: (id) => unawaited(_openLinkedNote(id)),
          ),
        ),
      ),
    );
    _bodyRoute = route;
    _report();
    Navigator.of(context).push<void>(route);
    await route.completed;
    if (mounted && identical(_bodyRoute, route)) {
      _bodyRoute = null;
      _bodyKey = null;
      _bodyRowId = null;
      _bodyDirty = false;
      _bodyBusy = false;
      _report();
      setState(() {});
    }
  }

  Future<void> _openForms() async {
    if (_formsRoute != null ||
        _formsOpening ||
        _actionsRoute != null ||
        _actionsOpening ||
        _bodyRoute != null ||
        _cellRoute != null ||
        _dragging)
      return;
    _formsOpening = true;
    _autosave?.cancel();
    _report();
    try {
      await _persist();
      if (!mounted) return;
      final key = GlobalKey<DatabaseFormsPanelState>();
      _formsKey = key;
      late MaterialPageRoute<void> route;
      route = MaterialPageRoute<void>(
        builder: (_) => PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) unawaited(_closeForms());
          },
          child: Scaffold(
            body: DatabaseFormsPanel(
              key: key,
              initialDatabase: _database,
              prepareSubmission: (submission) {
                final runtime = widget.actionRuntime;
                if (runtime == null) return submission;
                final prepared = runtime.prepareRowAdded(
                  submission.database,
                  rowId: submission.rowId,
                  origin: 'form',
                  inputRevision: submission.receipt.inputRevision,
                  capturedAtUtcMs:
                      submission.receipt.submittedAt.millisecondsSinceEpoch,
                );
                return submission.withDatabase(prepared.database);
              },
              currentRevision: () {
                final read = widget.currentRevision;
                if (read == null)
                  throw StateError('이 데이터베이스의 저장 판본을 확인할 수 없습니다.');
                return read();
              },
              onSave: (value) async {
                if (!mounted || !identical(_formsKey, key))
                  throw StateError('이미 닫힌 입력 폼의 저장을 거부했습니다.');
                await _writeSnapshot(value, _filesFor(value));
                if (mounted && identical(_formsKey, key)) {
                  setState(() => _database = value);
                }
              },
              onDirtyChanged: (value) {
                if (mounted && identical(_formsKey, key)) {
                  _formsDirty = value;
                  _report();
                }
              },
              onBusyChanged: (value) {
                if (mounted && identical(_formsKey, key)) {
                  _formsBusy = value;
                  _report();
                }
              },
              onBack: () => unawaited(_closeForms()),
            ),
          ),
        ),
      );
      _formsRoute = route;
      _formsOpening = false;
      _report();
      Navigator.of(context).push<void>(route);
      await route.completed;
      if (mounted && identical(_formsRoute, route)) {
        _formsRoute = null;
        _formsKey = null;
        _formsDirty = false;
        _formsBusy = false;
        _report();
        setState(() {});
      }
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      _formsOpening = false;
      _report();
    }
  }

  Future<void> _closeForms() async {
    try {
      await save();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  Future<void> _openActions({String? templateId}) async {
    final runtime = widget.actionRuntime;
    if (runtime == null ||
        _actionsRoute != null ||
        _actionsOpening ||
        _formsRoute != null ||
        _formsOpening ||
        _bodyRoute != null ||
        _cellRoute != null ||
        _configurationOpen ||
        _dragging)
      return;
    _actionsOpening = true;
    _autosave?.cancel();
    _report();
    try {
      await _persist();
      if (!mounted) return;
      final key = GlobalKey<DatabaseAutomationsPanelState>();
      _actionsKey = key;
      late MaterialPageRoute<void> route;
      route = MaterialPageRoute<void>(
        builder: (_) => PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) unawaited(_closeActions());
          },
          child: Scaffold(
            body: DatabaseAutomationsPanel(
              key: key,
              initialDatabase: _database,
              initialTemplateId: templateId,
              runtime: runtime,
              currentRevision: _currentRevision,
              onSave: (value) async {
                if (!mounted || !identical(_actionsKey, key)) {
                  throw StateError('이미 닫힌 자동화 설정의 저장을 거부했습니다.');
                }
                await _writeSnapshot(value, _filesFor(value));
                if (mounted && identical(_actionsKey, key)) {
                  setState(() => _database = value);
                }
              },
              onDirtyChanged: (value) {
                if (mounted && identical(_actionsKey, key)) {
                  _actionsDirty = value;
                  _report();
                }
              },
              onBusyChanged: (value) {
                if (mounted && identical(_actionsKey, key)) {
                  _actionsBusy = value;
                  _report();
                }
              },
              onBack: () => unawaited(_closeActions()),
            ),
          ),
        ),
      );
      _actionsRoute = route;
      _actionsOpening = false;
      _report();
      Navigator.of(context).push<void>(route);
      await route.completed;
      if (mounted && identical(_actionsRoute, route)) {
        _actionsRoute = null;
        _actionsKey = null;
        _actionsDirty = false;
        _actionsBusy = false;
        _report();
        setState(() {});
      }
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      _actionsOpening = false;
      _report();
    }
  }

  Future<void> _closeActions() async {
    try {
      await save();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  Future<void> _closeRow() async {
    try {
      await save();
    } catch (_) {
      if (mounted) setState(() => _saveFailed = true);
    }
  }

  Future<void> _openLinkedNote(String id) async {
    try {
      await save();
      if (mounted) widget.onOpenNote?.call(id);
    } catch (_) {}
  }

  Future<void> _editTaskLinks(DatabaseRow row) async {
    final runtime = widget.actionRuntime;
    if (_dragging ||
        _configurationOpen ||
        row.archived ||
        runtime == null ||
        !_database.supportsTaskLinks) {
      return;
    }
    final owner = widget.initialDatabase;
    final database = _database;
    bool ownsDraft() =>
        mounted &&
        identical(widget.initialDatabase, owner) &&
        identical(_database, database);
    final choices = <DatabaseTaskLinkChoice>[
      for (final choice in database.rows)
        if (choice.id != row.id)
          (id: choice.id, title: _title(choice), archived: choice.archived),
    ];
    final choiceIds = choices.map((choice) => choice.id).toSet();
    final original = database.taskLinks[row.id];
    _configurationOpen = true;
    _report();
    WorkspaceDatabase? result;
    try {
      result = await _showOwnedDialog<WorkspaceDatabase>(
        onRoute: (route) {
          _taskLinksRoute = route;
          _report();
        },
        builder: (_) => DatabaseTaskLinksDialog(
          title: _title(row),
          choices: choices,
          parentId: choiceIds.contains(original?.parentId)
              ? original!.parentId
              : null,
          predecessorIds: [
            for (final id in original?.predecessorIds ?? const <String>[])
              if (choiceIds.contains(id)) id,
          ],
          onApply: (parentId, predecessorIds) {
            if (!ownsDraft()) {
              throw StateError('항목이 바뀌었습니다. 다시 열어 주세요.');
            }
            return runtime.setTaskLinks(
              database,
              rowId: row.id,
              parentId: parentId,
              predecessorIds: predecessorIds,
            );
          },
        ),
      );
    } finally {
      _taskLinksRoute = null;
      _configurationOpen = false;
      _report();
    }
    if (result != null && ownsDraft() && !identical(result, database)) {
      _change(result);
    }
  }

  Future<void> _saveRowTemplate(DatabaseRow row) async {
    if (_dragging || _configurationOpen || row.archived) return;
    final owner = widget.initialDatabase;
    final database = _database;
    final name = TextEditingController(text: _title(row));
    String? error;
    _configurationOpen = true;
    _report();
    try {
      await _showOwnedDialog<void>(
        builder: (context) => StatefulBuilder(
          builder: (context, refresh) => AlertDialog(
            title: const Text('항목 템플릿'),
            content: TextField(
              key: const ValueKey('db-row-template-name'),
              controller: name,
              maxLength: 120,
              decoration: InputDecoration(
                labelText: '템플릿 이름',
                errorText: error,
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('취소'),
              ),
              FilledButton(
                onPressed: () {
                  if (!mounted ||
                      !identical(widget.initialDatabase, owner) ||
                      !identical(_database, database)) {
                    Navigator.pop(context);
                    return;
                  }
                  if (name.text.trim().isEmpty) {
                    refresh(() => error = '템플릿 이름을 입력하세요.');
                    return;
                  }
                  try {
                    _change(
                      database.captureRowTemplate(
                        rowId: row.id,
                        templateId: newId(),
                        name: name.text,
                      ),
                    );
                    Navigator.pop(context);
                  } on FormatException catch (failure) {
                    refresh(
                      () => error = '템플릿을 저장할 수 없습니다. ${failure.message}',
                    );
                  }
                },
                child: const Text('템플릿 저장'),
              ),
            ],
          ),
        ),
      );
    } finally {
      _configurationOpen = false;
      _report();
      name.dispose();
    }
  }

  Future<void> _chooseRowTemplate() async {
    if (_dragging || _configurationOpen) return;
    final owner = widget.initialDatabase;
    final database = _database;
    if (database.rowTemplates.isEmpty) {
      _addRow();
      return;
    }
    _configurationOpen = true;
    _report();
    String? scheduledTemplateId;
    try {
      final choice =
          await _showOwnedDialog<
            ({String? templateId, _RowTemplateAction action})
          >(
            builder: (context) => SimpleDialog(
              title: const Text('항목 추가'),
              children: [
                SimpleDialogOption(
                  onPressed: () => Navigator.pop(context, (
                    templateId: null,
                    action: _RowTemplateAction.apply,
                  )),
                  child: const Text('빈 항목'),
                ),
                for (final template in database.rowTemplates)
                  ListTile(
                    title: Text(template.name, overflow: TextOverflow.ellipsis),
                    onTap: () => Navigator.pop(context, (
                      templateId: template.id,
                      action: _RowTemplateAction.apply,
                    )),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (widget.actionRuntime != null)
                          IconButton(
                            tooltip: '반복 일정 설정',
                            icon: const Icon(Icons.update),
                            onPressed: () => Navigator.pop(context, (
                              templateId: template.id,
                              action: _RowTemplateAction.schedule,
                            )),
                          ),
                        IconButton(
                          tooltip: '템플릿 삭제',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () => Navigator.pop(context, (
                            templateId: template.id,
                            action: _RowTemplateAction.remove,
                          )),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          );
      if (choice == null ||
          !mounted ||
          !identical(widget.initialDatabase, owner) ||
          !identical(_database, database))
        return;
      if (choice.action == _RowTemplateAction.apply) {
        _addRow(templateId: choice.templateId);
        return;
      }
      if (choice.action == _RowTemplateAction.schedule) {
        scheduledTemplateId = choice.templateId;
      } else {
        final remove = await _showOwnedDialog<bool>(
          builder: (context) => AlertDialog(
            title: const Text('항목 템플릿을 삭제할까요?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('취소'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('삭제'),
              ),
            ],
          ),
        );
        if (remove == true &&
            mounted &&
            identical(widget.initialDatabase, owner) &&
            identical(_database, database)) {
          _run(() => _change(database.removeRowTemplate(choice.templateId!)));
        }
      }
    } finally {
      _configurationOpen = false;
      _report();
    }
    if (scheduledTemplateId != null &&
        mounted &&
        identical(widget.initialDatabase, owner) &&
        identical(_database, database)) {
      await _openActions(templateId: scheduledTemplateId);
    }
  }

  void _addRow({String? templateId, String? parentTaskId}) {
    if (_dragging ||
        (parentTaskId != null && (_configurationOpen || !_canEditTaskLinks))) {
      return;
    }
    _run(() {
      final row = templateId == null
          ? DatabaseRow.create(
              values: {
                if (_titleProperty case final title?)
                  title.id: parentTaskId == null ? '새 항목' : '새 하위 작업',
              },
            )
          : _database.instantiateRowTemplate(
              templateId: templateId,
              rowId: newId(),
            );
      var next = _database.addRow(row);
      final runtime = widget.actionRuntime;
      if (runtime != null) {
        if (parentTaskId != null) {
          try {
            next = runtime.setTaskLinks(
              next,
              rowId: row.id,
              parentId: parentTaskId,
              predecessorIds: const [],
            );
          } on DatabaseActionException catch (error) {
            throw StateError(databaseTaskLinkError(error));
          }
        }
        next = runtime
            .prepareRowAdded(
              next,
              rowId: row.id,
              inputRevision: _currentRevision(),
              capturedAtUtcMs: DateTime.now().toUtc().millisecondsSinceEpoch,
            )
            .database;
      }
      if (parentTaskId != null) _collapsedTasks.remove(parentTaskId);
      _change(next);
    });
  }

  Future<void> _archive() async {
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, refresh) => AlertDialog(
          title: const Text('보관한 항목'),
          content: SizedBox(
            width: 480,
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final row in _database.rows.where((row) => row.archived))
                  ListTile(
                    title: Text(_title(row)),
                    trailing: TextButton(
                      onPressed: () {
                        _change(_database.archiveRow(row.id, archived: false));
                        refresh(() {});
                      },
                      child: const Text('복원'),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('닫기'),
            ),
          ],
        ),
      ),
    );
  }

  List<(String, String)> _options(DatabaseProperty property) => [
    if (property.config['options'] is List)
      for (final option in property.config['options'] as List)
        if (option is String)
          (option, option)
        else if (option is Map && option['name'] is String)
          ('${option['id'] ?? option['name']}', '${option['name']}'),
  ];
  String _rowName(WorkspaceDatabase database, DatabaseRow row) {
    final property = database.properties
        .where((property) => property.type == 'title')
        .firstOrNull;
    final value = row.values[property?.id];
    return value is String && value.isNotEmpty ? value : '이름 없는 항목';
  }

  Future<void> _editCell(DatabaseRow row, DatabaseProperty property) async {
    if (property.isComputed ||
        _dragging ||
        _saving ||
        _writer != null ||
        _cellRoute != null ||
        _formsRoute != null ||
        _actionsRoute != null)
      return;
    _autosave?.cancel();
    final base = _database;
    final baseGeneration = _generation;
    final original = row.values[property.id];
    final text = TextEditingController(
      text: original is String
          ? original
          : original is num
          ? _number(original)
          : '',
    );
    final start = TextEditingController(
      text: original is Map
          ? '${original['start'] ?? original['dateISO'] ?? ''}'
          : original is String
          ? original
          : '',
    );
    final end = TextEditingController(
      text: original is Map ? '${original['end'] ?? ''}' : '',
    );
    final people = original is List ? original : <Object?>[];
    if (property.type == 'people')
      text.text = [
        for (var i = 0; i < people.length; i++)
          if (people[i] is Map)
            '${(people[i] as Map)['name'] ?? '사용자 ${i + 1}'}'
          else
            '${people[i]}',
      ].join(', ');
    if (property.type == 'multiSelect' && original is List)
      text.text = original.join(', ');
    Object? selected = property.type == 'relation' && original is Map
        ? [original]
        : original;
    final fileDrafts = <Map<String, dynamic>>[
      if (property.type == 'files' && original is List)
        for (final item in original)
          if (item is Map) Map<String, dynamic>.from(item),
    ];
    final available = {...widget.databases, _database.id: _database};
    var relationDatabase =
        _string(property.config['databaseId']) ?? _database.id;
    String? error;
    var active = true;
    var committed = false;
    var touched = false;
    String? eventId;
    String? inputRevision;
    int? capturedAtUtcMs;
    StateSetter? refreshCell;
    void restore() {
      if (!mounted) return;
      setState(() {
        _database = base;
        _generation = baseGeneration;
      });
      _report();
    }

    bool commit() {
      if (committed) return true;
      if (error != null) return false;
      if (!touched ||
          const DeepCollectionEquality().equals(original, selected)) {
        restore();
        committed = true;
        return true;
      }
      try {
        WorkspaceDatabase next;
        if (widget.actionRuntime == null ||
            !databaseActionPropertyTypes.contains(property.type)) {
          next = base.setCell(row.id, property.id, selected);
        } else {
          eventId ??= newId();
          inputRevision ??= _currentRevision();
          capturedAtUtcMs ??= DateTime.now().toUtc().millisecondsSinceEpoch;
          next = _prepareCell(
            base,
            row.id,
            property,
            selected,
            eventId: eventId!,
            inputRevision: inputRevision!,
            capturedAtUtcMs: capturedAtUtcMs!,
          );
        }
        _change(next);
        committed = true;
        _draftError = null;
        return true;
      } catch (_) {
        restore();
        error = '자동화 규칙과 입력값을 확인하거나 입력을 취소해 주세요.';
        _draftError = error;
        _report();
        refreshCell?.call(() {});
        return false;
      }
    }

    _cellCommit = commit;
    void apply(Object? value, StateSetter refresh) {
      try {
        if (committed) return;
        _change(base.setCell(row.id, property.id, value));
        touched = true;
        selected = value;
        error = null;
        _draftError = null;
        _report();
      } catch (_) {
        error = '입력한 값의 형식을 확인해 주세요.';
        _draftError = error;
        _report();
      }
      refresh(() {});
    }

    bool? accepted;
    try {
      accepted = await _showOwnedDialog<bool>(
        onRoute: (route) {
          _cellRoute = route;
          _report();
        },
        barrierDismissible: false,
        builder: (context) => StatefulBuilder(
          builder: (context, refresh) {
            refreshCell = refresh;
            Widget editor;
            final options = _options(property);
            if (property.type == 'checkbox')
              editor = CheckboxListTile(
                title: const Text('선택'),
                value: selected == true,
                onChanged: (value) => apply(value ?? false, refresh),
              );
            else if ((property.type == 'status' || property.type == 'select') &&
                options.isNotEmpty)
              editor = DropdownButtonFormField<String>(
                initialValue: options.any((option) => option.$1 == selected)
                    ? selected as String
                    : '',
                items: [
                  const DropdownMenuItem(value: '', child: Text('비어 있음')),
                  for (final option in options)
                    DropdownMenuItem(value: option.$1, child: Text(option.$2)),
                ],
                onChanged: (value) =>
                    apply(value == '' ? null : value, refresh),
              );
            else if (property.type == 'multiSelect' && options.isNotEmpty)
              editor = Wrap(
                spacing: 8,
                children: [
                  for (final option in options)
                    FilterChip(
                      label: Text(option.$2),
                      selected:
                          selected is List &&
                          (selected as List).contains(option.$1),
                      onSelected: (checked) {
                        final values = <String>[
                          if (selected is List)
                            ...(selected as List).cast<String>(),
                        ];
                        if (checked)
                          values.add(option.$1);
                        else
                          values.remove(option.$1);
                        apply(values, refresh);
                      },
                    ),
                ],
              );
            else if (property.type == 'date')
              editor = Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    key: const ValueKey('db-cell-input'),
                    controller: start,
                    decoration: const InputDecoration(
                      labelText: '시작 날짜(YYYY-MM-DD 또는 UTC 시각)',
                    ),
                    onChanged: (_) {
                      final value = <String, dynamic>{
                        if (original is Map)
                          ...Map<String, dynamic>.from(original),
                        'start': start.text,
                      };
                      value.remove('dateISO');
                      if (end.text.isNotEmpty)
                        value['end'] = end.text;
                      else
                        value.remove('end');
                      apply(
                        original is String && end.text.isEmpty
                            ? start.text
                            : value,
                        refresh,
                      );
                    },
                  ),
                  TextField(
                    controller: end,
                    decoration: const InputDecoration(labelText: '종료 날짜(선택)'),
                    onChanged: (_) {
                      final value = <String, dynamic>{
                        if (original is Map)
                          ...Map<String, dynamic>.from(original),
                        'start': start.text,
                      };
                      value.remove('dateISO');
                      if (end.text.isNotEmpty)
                        value['end'] = end.text;
                      else
                        value.remove('end');
                      apply(
                        end.text.isEmpty && original is String
                            ? start.text
                            : value,
                        refresh,
                      );
                    },
                  ),
                  TextButton.icon(
                    onPressed: () async {
                      DateTime initial;
                      try {
                        initial = parseDatabaseDate(start.text).start;
                      } catch (_) {
                        initial = DateTime.now().toUtc();
                      }
                      final date = await showDatePicker(
                        context: context,
                        initialDate: DateTime(
                          initial.year,
                          initial.month,
                          initial.day,
                        ),
                        firstDate: DateTime(1),
                        lastDate: DateTime(9999, 12, 31),
                      );
                      if (date != null && active) {
                        start.text = _date(date);
                        final value = <String, dynamic>{
                          if (original is Map)
                            ...Map<String, dynamic>.from(original),
                          'start': start.text,
                        };
                        if (end.text.isNotEmpty)
                          value['end'] = end.text;
                        else
                          value.remove('end');
                        apply(
                          original is String && end.text.isEmpty
                              ? start.text
                              : value,
                          refresh,
                        );
                      }
                    },
                    icon: const Icon(Icons.calendar_month),
                    label: const Text('날짜 선택'),
                  ),
                  const Text('날짜만 입력하면 하루 일정입니다. 시각을 함께 입력하면 UTC 기준으로 계산합니다.'),
                ],
              );
            else if (property.type == 'relation') {
              final target = available[relationDatabase];
              editor = Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<String>(
                    initialValue: available.containsKey(relationDatabase)
                        ? relationDatabase
                        : null,
                    decoration: const InputDecoration(labelText: '연결할 데이터베이스'),
                    items: [
                      for (var i = 0; i < available.length; i++)
                        DropdownMenuItem(
                          value: available.keys.elementAt(i),
                          child: Text(
                            available.keys.elementAt(i) == _database.id
                                ? '현재 데이터베이스'
                                : '연결된 데이터베이스 ${i + 1}',
                          ),
                        ),
                    ],
                    onChanged: property.config['databaseId'] != null
                        ? null
                        : (id) {
                            if (id != null)
                              refresh(() => relationDatabase = id);
                          },
                  ),
                  if (target == null)
                    const Text('연결할 데이터베이스를 먼저 앱에서 열어 주세요.')
                  else
                    for (final related in target.rows.where(
                      (row) => !row.archived,
                    ))
                      CheckboxListTile(
                        title: Text(_rowName(target, related)),
                        value:
                            selected is List &&
                            (selected as List).any(
                              (ref) =>
                                  ref is Map &&
                                  ref['databaseId'] == target.id &&
                                  ref['rowId'] == related.id,
                            ),
                        onChanged: (checked) {
                          final refs = <Object?>[
                            if (selected is List) ...selected as List,
                          ];
                          refs.removeWhere(
                            (ref) =>
                                ref is Map &&
                                ref['databaseId'] == target.id &&
                                ref['rowId'] == related.id,
                          );
                          if (checked == true)
                            refs.add({
                              'databaseId': target.id,
                              'rowId': related.id,
                            });
                          apply(refs, refresh);
                        },
                      ),
                ],
              );
            } else if (property.type == 'files')
              editor = Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('파일 이름과 웹 주소를 기록합니다. 파일 본문을 업로드하는 기능은 별도입니다.'),
                  for (var i = 0; i < fileDrafts.length; i++)
                    Column(
                      children: [
                        TextFormField(
                          initialValue: fileDrafts[i]['name'] as String?,
                          decoration: const InputDecoration(labelText: '파일 이름'),
                          onChanged: (value) {
                            fileDrafts[i]['name'] = value;
                            apply([
                              for (final file in fileDrafts)
                                Map<String, dynamic>.from(file),
                            ], refresh);
                          },
                        ),
                        TextFormField(
                          initialValue: fileDrafts[i]['url'] as String?,
                          decoration: const InputDecoration(
                            labelText: '주소(선택)',
                          ),
                          onChanged: (value) {
                            fileDrafts[i]['url'] = value;
                            apply([
                              for (final file in fileDrafts)
                                Map<String, dynamic>.from(file),
                            ], refresh);
                          },
                        ),
                        TextButton(
                          onPressed: () {
                            fileDrafts.removeAt(i);
                            apply([
                              for (final file in fileDrafts)
                                Map<String, dynamic>.from(file),
                            ], refresh);
                          },
                          child: const Text('이 파일 정보 삭제'),
                        ),
                      ],
                    ),
                  TextButton(
                    onPressed: () {
                      fileDrafts.add({'name': '새 파일', 'url': ''});
                      apply([
                        for (final file in fileDrafts)
                          Map<String, dynamic>.from(file),
                      ], refresh);
                    },
                    child: const Text('파일 정보 추가'),
                  ),
                ],
              );
            else
              editor = TextField(
                key: const ValueKey('db-cell-input'),
                controller: text,
                minLines: 1,
                maxLines: property.type == 'text' ? 5 : 1,
                keyboardType: property.type == 'number'
                    ? const TextInputType.numberWithOptions(
                        decimal: true,
                        signed: true,
                      )
                    : TextInputType.text,
                decoration: InputDecoration(
                  labelText: property.type == 'people'
                      ? '이름을 쉼표로 구분'
                      : property.type == 'multiSelect'
                      ? '선택값을 쉼표로 구분'
                      : property.name,
                  errorText: error,
                ),
                onChanged: (value) {
                  if (property.type == 'number') {
                    if (value.trim().isEmpty)
                      apply(null, refresh);
                    else {
                      final number = num.tryParse(value);
                      if (number == null) {
                        error = '숫자를 입력하세요.';
                        _draftError = error;
                        _report();
                        refresh(() {});
                      } else
                        apply(number, refresh);
                    }
                  } else if (property.type == 'people') {
                    final names = value
                        .split(',')
                        .map((name) => name.trim())
                        .where((name) => name.isNotEmpty)
                        .toList();
                    final previous = <String, Object?>{
                      for (var i = 0; i < people.length; i++)
                        people[i] is Map
                                ? '${(people[i] as Map)['name'] ?? '사용자 ${i + 1}'}'
                                : '${people[i]}':
                            people[i],
                    };
                    apply([
                      for (final name in names) previous[name] ?? name,
                    ], refresh);
                  } else if (property.type == 'multiSelect')
                    apply(
                      value
                          .split(',')
                          .map((name) => name.trim())
                          .where((name) => name.isNotEmpty)
                          .toSet()
                          .toList(),
                      refresh,
                    );
                  else
                    apply(value, refresh);
                },
              );
            return AlertDialog(
              title: Text(property.name),
              content: SizedBox(
                width: 500,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      editor,
                      if (error != null && property.type != 'number')
                        Text(
                          error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('입력 취소'),
                ),
                FilledButton(
                  onPressed: error == null
                      ? () {
                          if (commit()) Navigator.pop(context, true);
                        }
                      : null,
                  child: const Text('닫기'),
                ),
              ],
            );
          },
        ),
      );
    } finally {
      active = false;
      _cellRoute = null;
      _cellCommit = null;
      _draftError = null;
      _report();
      text.dispose();
      start.dispose();
      end.dispose();
    }
    if (accepted != true && mounted) restore();
    if (mounted && _dirty && _saveFuture == null) _scheduleAutosave();
  }

  String? _string(Object? value) => value is String ? value : null;

  bool _hasInvalidStringSettings(
    Map<String, dynamic> config,
    Set<String> keys,
  ) => keys.any((key) => config[key] != null && config[key] is! String);

  Future<void> _renameWithPreservedSettings({
    required String title,
    required String label,
    required String initialName,
    required ValueChanged<String> onApply,
    Key? key,
    WidgetBuilder? leadingAction,
    String? description,
  }) async {
    final name = TextEditingController(text: initialName);
    String? error;
    _configurationOpen = true;
    _report();
    try {
      await _showOwnedDialog<void>(
        builder: (context) => StatefulBuilder(
          builder: (context, refresh) => AlertDialog(
            title: Text(title),
            content: SizedBox(
              width: 500,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    description ??
                        '이 설정 형식은 편집할 수 없어 원본 설정을 유지합니다. 이름만 바꿀 수 있습니다.',
                  ),
                  TextField(
                    key: key,
                    controller: name,
                    decoration: InputDecoration(
                      labelText: label,
                      errorText: error,
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              if (leadingAction != null) leadingAction(context),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('취소'),
              ),
              FilledButton(
                onPressed: () {
                  try {
                    onApply(name.text.trim());
                    Navigator.pop(context);
                  } catch (_) {
                    refresh(() => error = '이름을 확인해 주세요.');
                  }
                },
                child: const Text('적용'),
              ),
            ],
          ),
        ),
      );
    } finally {
      _configurationOpen = false;
      _report();
      name.dispose();
    }
  }

  Future<void> _editProperty(DatabaseProperty? original) async {
    if (_dragging) return;
    final base = original ?? DatabaseProperty.create(name: '새 속성');
    if (_hasInvalidStringSettings(base.config, const {
      'expression',
      'databaseId',
      'relationPropertyId',
      'targetPropertyId',
      'calculation',
    })) {
      await _renameWithPreservedSettings(
        title: '속성 설정',
        label: '속성 이름',
        initialName: base.name,
        key: const ValueKey('db-property-name'),
        onApply: (name) =>
            _change(_database.updateProperty(base.copyWith(name: name))),
      );
      return;
    }
    final name = TextEditingController(text: base.name);
    final expression = TextEditingController(
      text: _string(base.config['expression']) ?? '',
    );
    final options = TextEditingController(
      text: _options(base).map((option) => option.$2).join('\n'),
    );
    var type = base.type;
    var databaseId = _string(base.config['databaseId']) ?? _database.id;
    String? relationId = _string(base.config['relationPropertyId']);
    String? targetId = _string(base.config['targetPropertyId']);
    var calculation = _string(base.config['calculation']) ?? 'count';
    String? error;
    final databases = {...widget.databases, _database.id: _database};
    _configurationOpen = true;
    _report();
    try {
      await _showOwnedDialog<void>(
        builder: (context) => StatefulBuilder(
          builder: (context, refresh) {
            final relation = _database.properties
                .where(
                  (property) =>
                      property.id == relationId && property.type == 'relation',
                )
                .firstOrNull;
            final target = databases[relation?.config['databaseId']];
            Widget choose<T>(
              String label,
              T? value,
              Iterable<(T, String)> items,
              ValueChanged<T?> changed, {
              Key? key,
            }) => DropdownButtonFormField<T>(
              key: key,
              initialValue: items.any((item) => item.$1 == value)
                  ? value
                  : null,
              decoration: InputDecoration(labelText: label),
              items: [
                for (final item in items)
                  DropdownMenuItem(value: item.$1, child: Text(item.$2)),
              ],
              onChanged: changed,
            );
            return AlertDialog(
              title: Text(original == null ? '속성 추가' : '속성 설정'),
              content: SizedBox(
                width: 540,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextField(
                        key: const ValueKey('db-property-name'),
                        controller: name,
                        decoration: const InputDecoration(labelText: '속성 이름'),
                      ),
                      choose(
                        '종류',
                        type,
                        [
                          for (final kind in {...databasePropertyTypes, type})
                            (kind, _propertyLabels[kind] ?? '지원하지 않는 종류'),
                        ],
                        (value) {
                          if (value != null) refresh(() => type = value);
                        },
                        key: const ValueKey('db-property-type'),
                      ),
                      if (const {
                        'status',
                        'select',
                        'multiSelect',
                      }.contains(type))
                        TextField(
                          controller: options,
                          minLines: 3,
                          maxLines: 7,
                          decoration: const InputDecoration(
                            labelText: '선택지(한 줄에 하나)',
                          ),
                        ),
                      if (type == 'formula') ...[
                        TextField(
                          key: const ValueKey('db-property-expression'),
                          controller: expression,
                          minLines: 2,
                          maxLines: 5,
                          decoration: const InputDecoration(
                            labelText: '계산식',
                            hintText: '예: 1 + 2',
                          ),
                        ),
                        PopupMenuButton<String>(
                          tooltip: '수식에 속성 넣기',
                          onSelected: (id) {
                            final value = 'prop("$id")';
                            final selection = expression.selection;
                            final start = selection.isValid
                                ? selection.start
                                : expression.text.length;
                            final end = selection.isValid
                                ? selection.end
                                : expression.text.length;
                            expression.value = TextEditingValue(
                              text: expression.text.replaceRange(
                                start,
                                end,
                                value,
                              ),
                              selection: TextSelection.collapsed(
                                offset: start + value.length,
                              ),
                            );
                          },
                          itemBuilder: (_) => [
                            for (final property in _database.properties.where(
                              (property) => property.id != base.id,
                            ))
                              PopupMenuItem(
                                value: property.id,
                                child: Text(property.name),
                              ),
                          ],
                          child: const Padding(
                            padding: EdgeInsets.all(12),
                            child: Text('속성 넣기'),
                          ),
                        ),
                        const Text(
                          '산술·비교, if, concat, sum, 날짜 함수 등의 지원 연산을 사용합니다. 전체 Notion 수식과 동일하지 않습니다.',
                        ),
                      ],
                      if (type == 'relation')
                        choose(
                          '연결할 데이터베이스',
                          databaseId,
                          [
                            for (var i = 0; i < databases.length; i++)
                              (
                                databases.keys.elementAt(i),
                                databases.keys.elementAt(i) == _database.id
                                    ? '현재 데이터베이스'
                                    : '연결된 데이터베이스 ${i + 1}',
                              ),
                          ],
                          (id) {
                            if (id != null) refresh(() => databaseId = id);
                          },
                        ),
                      if (type == 'rollup') ...[
                        choose(
                          '관계 속성',
                          relationId,
                          [
                            for (final property in _database.properties.where(
                              (property) => property.type == 'relation',
                            ))
                              (property.id, property.name),
                          ],
                          (id) => refresh(() {
                            relationId = id;
                            targetId = null;
                          }),
                        ),
                        if (target != null)
                          choose('가져올 속성', targetId, [
                            for (final property in target.properties)
                              (property.id, property.name),
                          ], (id) => refresh(() => targetId = id)),
                        choose(
                          '집계',
                          calculation,
                          const [
                            ('count', '개수'),
                            ('sum', '합계'),
                            ('average', '평균'),
                            ('min', '최솟값'),
                            ('max', '최댓값'),
                            ('showOriginal', '원래 값'),
                          ],
                          (value) {
                            if (value != null)
                              refresh(() => calculation = value);
                          },
                        ),
                      ],
                      if (error != null)
                        Text(
                          error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
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
                  onPressed: () {
                    try {
                      final config = <String, dynamic>{...base.config};
                      if (const {
                        'status',
                        'select',
                        'multiSelect',
                      }.contains(type)) {
                        if (options.text !=
                            _options(base)
                                .map((option) => option.$2)
                                .join('\n')) {
                          config['options'] = _editedOptions(
                            base,
                            options.text,
                          );
                        }
                      }
                      if (type == 'formula')
                        config['expression'] = expression.text;
                      if (type == 'relation') config['databaseId'] = databaseId;
                      if (type == 'rollup') {
                        config['relationPropertyId'] = relationId;
                        config['targetPropertyId'] = targetId;
                        config['calculation'] = calculation;
                      }
                      final property = base.copyWith(
                        name: name.text.trim(),
                        type: type,
                        config: config,
                      );
                      final next = original == null
                          ? _database.addProperty(property)
                          : _database.updateProperty(property);
                      _change(next);
                      Navigator.pop(context);
                    } catch (_) {
                      refresh(
                        () => error =
                            '속성 이름·종류·설정을 확인하세요. 기존 값과 맞지 않는 종류로 바꾸지 않았습니다.',
                      );
                    }
                  },
                  child: const Text('적용'),
                ),
              ],
            );
          },
        ),
      );
    } finally {
      _configurationOpen = false;
      _report();
      name.dispose();
      expression.dispose();
      options.dispose();
    }
  }

  List<Object?> _editedOptions(DatabaseProperty property, String text) {
    final labels = text
        .split('\n')
        .map((label) => label.trim())
        .where((label) => label.isNotEmpty)
        .toList();
    if (labels.toSet().length != labels.length)
      throw const FormatException('선택지 이름은 중복될 수 없습니다.');
    final original = <Map<String, dynamic>>[
      if (property.config['options'] is List)
        for (final option in property.config['options'] as List)
          if (option is String)
            {'id': option, 'name': option}
          else if (option is Map)
            Map<String, dynamic>.from(option),
    ];
    final used = <String>{};
    final result = <Object?>[];
    for (var i = 0; i < labels.length; i++) {
      final label = labels[i];
      var prior = original
          .where((option) => option['name'] == label)
          .firstOrNull;
      prior ??= original
          .where(
            (option) =>
                !labels.contains(option['name']) &&
                !used.contains('${option['id'] ?? option['name']}') &&
                option['name'] is String,
          )
          .firstOrNull;
      var id = '${prior?['id'] ?? prior?['name'] ?? newId()}';
      if (!used.add(id)) {
        id = newId();
        used.add(id);
      }
      result.add({...?prior, 'id': id, 'name': label});
    }
    result.addAll(original.where((option) => option['name'] is! String));
    return result;
  }

  Future<void> _viewSettings() async {
    if (_dragging || _configurationOpen) return;
    final owner = widget.initialDatabase;
    final original = _view;
    final filter = original.filter;
    final malformed = _hasInvalidStringSettings(original.config, const {
      'datePropertyId',
      'chartGroupBy',
      'chartValuePropertyId',
      'chartCalculation',
      'chartType',
    });
    bool isCurrent() =>
        mounted &&
        const DeepCollectionEquality().equals(
          _view.toJson(),
          original.toJson(),
        );
    bool canRemoveView() =>
        !widget.embedded &&
        widget.viewOverride == null &&
        _database.views.length > 1;

    Future<void> removeView(BuildContext settings) async {
      bool canApply() =>
          mounted &&
          settings.mounted &&
          ModalRoute.of(settings)?.isCurrent == true &&
          _configurationOpen &&
          identical(widget.initialDatabase, owner) &&
          canRemoveView() &&
          canDiscardDraft &&
          isCurrent();
      if (!canApply()) return;
      final confirmed = await _showOwnedDialog<bool>(
        builder: (context) => AlertDialog(
          key: const ValueKey('db-delete-view-dialog'),
          title: const Text('보기를 삭제할까요?'),
          content: Text('“${original.name}” 보기를 삭제합니다. 데이터베이스의 행과 속성은 유지됩니다.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('취소'),
            ),
            FilledButton(
              key: const ValueKey('db-confirm-delete-view'),
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
                foregroundColor: Theme.of(context).colorScheme.onError,
              ),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('삭제'),
            ),
          ],
        ),
      );
      if (confirmed != true || !canApply()) return;
      final index = _database.views.indexWhere(
        (view) => view.id == original.id,
      );
      final next = _database.removeView(original.id);
      _selectedView =
          next.views[index < next.views.length ? index : index - 1].id;
      _calendarMonth = null;
      _change(next);
      if (settings.mounted) Navigator.pop(settings);
    }

    Widget removeAction(BuildContext context) => TextButton(
      key: const ValueKey('db-delete-view'),
      style: TextButton.styleFrom(
        foregroundColor: Theme.of(context).colorScheme.error,
      ),
      onPressed: canDiscardDraft ? () => unawaited(removeView(context)) : null,
      child: const Text('보기 삭제'),
    );
    if (malformed || original.type == databaseDashboardViewType) {
      await _renameWithPreservedSettings(
        title: '보기 설정',
        label: '보기 이름',
        initialName: original.name,
        description: original.type == databaseDashboardViewType
            ? '위젯은 대시보드 화면에서 배치할 수 있습니다.'
            : null,
        onApply: (name) {
          if (!isCurrent()) {
            throw StateError('보기가 바뀌었습니다. 다시 열어 주세요.');
          }
          _updateView(original.copyWith(name: name));
        },
        leadingAction: canRemoveView() ? removeAction : null,
      );
      return;
    }
    final name = TextEditingController(text: original.name);
    var draftFilter = filter;
    var draftSorts = original.sorts;
    var filterValid = true;
    String? group = original.groupBy;
    String? date = original.config.containsKey('datePropertyId')
        ? _string(original.config['datePropertyId'])
        : _dateProperty?.id;
    String? chartGroup = original.config.containsKey('chartGroupBy')
        ? _string(original.config['chartGroupBy'])
        : original.groupBy;
    String? chartValue = _string(original.config['chartValuePropertyId']);
    var chartCalculation =
        _string(original.config['chartCalculation']) ?? 'count';
    var chartType = _string(original.config['chartType']) ?? 'bar';
    var configChanged = false;
    final visible = original.visibleProperties.toSet();
    String? error;
    _configurationOpen = true;
    _report();
    try {
      await _showOwnedDialog<void>(
        builder: (context) => StatefulBuilder(
          builder: (context, refresh) {
            Widget propertyChoice(
              String label,
              String? value,
              Iterable<DatabaseProperty> fields,
              ValueChanged<String?> changed, {
              Key? key,
            }) => DropdownButtonFormField<String>(
              key: key,
              initialValue: fields.any((property) => property.id == value)
                  ? value
                  : '',
              decoration: InputDecoration(labelText: label),
              items: [
                const DropdownMenuItem(value: '', child: Text('선택 안 함')),
                for (final property in fields)
                  DropdownMenuItem(
                    value: property.id,
                    child: Text(property.name),
                  ),
              ],
              onChanged: (id) => changed(id == '' ? null : id),
            );
            Widget choice(
              String label,
              String value,
              Map<String, String> choices,
              ValueChanged<String> changed, {
              Key? key,
            }) => DropdownButtonFormField<String>(
              key: key,
              initialValue: choices.containsKey(value)
                  ? value
                  : choices.keys.first,
              decoration: InputDecoration(labelText: label),
              items: [
                for (final item in choices.entries)
                  DropdownMenuItem(value: item.key, child: Text(item.value)),
              ],
              onChanged: (value) {
                if (value != null) changed(value);
              },
            );
            return AlertDialog(
              title: const Text('보기 설정'),
              content: SizedBox(
                width: 560,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextField(
                        controller: name,
                        decoration: const InputDecoration(labelText: '보기 이름'),
                      ),
                      propertyChoice(
                        '묶을 속성',
                        group,
                        _database.properties,
                        (id) => refresh(() => group = id),
                      ),
                      const SizedBox(height: 16),
                      const Text('필터'),
                      DatabaseViewFilterEditor(
                        database: _database,
                        filter: filter,
                        onChanged: (draft) => refresh(() {
                          draftFilter = draft.filter;
                          filterValid = draft.valid;
                          error = null;
                        }),
                      ),
                      const SizedBox(height: 16),
                      const Text('정렬'),
                      DatabaseViewSortEditor(
                        database: _database,
                        sort: draftSorts,
                        onChanged: (sorts) => refresh(() {
                          draftSorts = [
                            for (final sort in sorts) {...sort},
                          ];
                        }),
                      ),
                      if (original.type == 'calendar' ||
                          original.type == 'timeline')
                        propertyChoice(
                          '날짜 속성',
                          date,
                          _database.properties.where(
                            (property) => property.type == 'date',
                          ),
                          (id) => refresh(() {
                            date = id;
                            configChanged = true;
                          }),
                        ),
                      if (original.type == 'chart') ...[
                        propertyChoice(
                          '차트를 묶을 속성',
                          chartGroup,
                          _database.properties,
                          (id) => refresh(() {
                            chartGroup = id;
                            configChanged = true;
                          }),
                        ),
                        propertyChoice(
                          '집계할 숫자 속성',
                          chartValue,
                          _database.properties.where(
                            (property) => const {
                              'number',
                              'formula',
                              'rollup',
                            }.contains(property.type),
                          ),
                          (id) => refresh(() {
                            chartValue = id;
                            configChanged = true;
                          }),
                        ),
                        choice(
                          '집계',
                          chartCalculation,
                          const {
                            'count': '개수',
                            'sum': '합계',
                            'average': '평균',
                            'min': '최솟값',
                            'max': '최댓값',
                          },
                          (value) => refresh(() {
                            chartCalculation = value;
                            configChanged = true;
                          }),
                        ),
                        choice(
                          '차트 모양',
                          chartType,
                          const {'bar': '막대', 'pie': '원', 'line': '선'},
                          (value) => refresh(() {
                            chartType = value;
                            configChanged = true;
                          }),
                        ),
                      ],
                      const SizedBox(height: 16),
                      const Text('표시할 속성(선택하지 않으면 모두 표시)'),
                      for (final property in _database.properties)
                        CheckboxListTile(
                          dense: true,
                          title: Text(property.name),
                          value: visible.contains(property.id),
                          onChanged: (checked) => refresh(() {
                            if (checked == true)
                              visible.add(property.id);
                            else
                              visible.remove(property.id);
                          }),
                        ),
                      if (error != null)
                        Text(
                          error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              actions: [
                if (canRemoveView()) removeAction(context),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('취소'),
                ),
                FilledButton(
                  onPressed: () {
                    if (!isCurrent()) {
                      refresh(() => error = '보기가 바뀌었습니다. 다시 열어 주세요.');
                      return;
                    }
                    if (!filterValid) {
                      refresh(() => error = '필터 조건과 비교할 값을 확인해 주세요.');
                      return;
                    }
                    try {
                      final config = <String, dynamic>{...original.config};
                      if (configChanged) {
                        if (original.type == 'calendar' ||
                            original.type == 'timeline')
                          config['datePropertyId'] = date;
                        if (original.type == 'chart') {
                          config['chartGroupBy'] = chartGroup;
                          config['chartValuePropertyId'] = chartValue;
                          config['chartCalculation'] = chartCalculation;
                          config['chartType'] = chartType;
                        }
                      }
                      _updateView(
                        original.copyWith(
                          name: name.text.trim(),
                          filter: draftFilter,
                          clearFilter: filter != null && draftFilter == null,
                          sorts: draftSorts,
                          groupBy: group,
                          clearGroupBy: group == null,
                          visibleProperties: visible.toList(),
                          config: config,
                        ),
                      );
                      Navigator.pop(context);
                    } catch (_) {
                      refresh(() => error = '필터 값과 보기 이름을 확인해 주세요.');
                    }
                  },
                  child: const Text('적용'),
                ),
              ],
            );
          },
        ),
      );
    } finally {
      _configurationOpen = false;
      _report();
      name.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final dashboard = _view.type == databaseDashboardViewType;
    final query = dashboard ? null : _query();
    final result = query?.apply(_view);
    final body = switch (_view.type) {
      'table' => _table(result!.rows, query!),
      'board' => _board(result!, query!),
      'list' => _list(result!.rows, query!),
      'gallery' => _gallery(result!.rows, query!),
      'calendar' => _calendar(query!),
      'timeline' => _timeline(query!),
      'chart' => _chart(query!),
      databaseDashboardViewType => _dashboardBody(_view),
      _ => const Center(child: Text('이 보기 유형은 아직 편집할 수 없습니다. 원본 정의는 보존됩니다.')),
    };
    return Column(
      children: [
        Row(
          children: [
            if (!widget.embedded)
              IconButton(
                tooltip: '문서 목록으로',
                onPressed: () => unawaited(_back()),
                icon: const Icon(Icons.arrow_back),
              ),
            Expanded(
              child: Text(
                widget.embedded ? '연결된 데이터베이스' : '데이터베이스',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: widget.embedded
                    ? Theme.of(context).textTheme.titleMedium
                    : Theme.of(context).textTheme.titleLarge,
              ),
            ),
            if (_saving)
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            if (!widget.embedded &&
                widget.viewOverride == null &&
                widget.onHistory != null)
              IconButton(
                key: const ValueKey('database-history'),
                tooltip: '데이터베이스 이력',
                onPressed: _saving || _dragging ? null : widget.onHistory,
                icon: const Icon(Icons.history),
              ),
            IconButton(
              tooltip: '저장',
              onPressed: () => unawaited(_saveFromUi()),
              icon: const Icon(Icons.save_outlined),
            ),
          ],
        ),
        SizedBox(
          height: 48,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                if (widget.viewOverride != null) ...[
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Text(_view.name),
                  ),
                  PopupMenuButton<String>(
                    tooltip: '보기 형식',
                    enabled: !_dragging && widget.onViewOverrideChanged != null,
                    onSelected: (type) =>
                        _run(() => _updateView(_view.copyWith(type: type))),
                    itemBuilder: (_) => [
                      for (final type in databaseViewTypes)
                        PopupMenuItem(
                          value: type,
                          child: Text(_viewLabels[type]!),
                        ),
                    ],
                    icon: const Icon(Icons.view_module_outlined),
                  ),
                ] else ...[
                  for (final view in _database.views)
                    TextButton(
                      key: ValueKey('db-view-${view.id}'),
                      onPressed: _dragging ? null : () => _selectView(view),
                      style: TextButton.styleFrom(
                        foregroundColor: view.id == _view.id ? _teal : null,
                      ),
                      child: Text(view.name),
                    ),
                  PopupMenuButton<String>(
                    tooltip: '보기 추가',
                    enabled: !_dragging,
                    onSelected: (type) => _run(() => _addView(type)),
                    itemBuilder: (_) => [
                      if (!widget.embedded && _database.views.isNotEmpty) ...[
                        const PopupMenuItem(
                          value: _duplicateViewAction,
                          child: Text('현재 보기 복제'),
                        ),
                        const PopupMenuDivider(),
                      ],
                      for (final type in databaseViewTypes)
                        PopupMenuItem(
                          value: type,
                          child: Text(_viewLabels[type]!),
                        ),
                      if (!widget.embedded)
                        const PopupMenuItem(
                          value: databaseDashboardViewType,
                          child: Text('대시보드'),
                        ),
                    ],
                    icon: const Icon(Icons.add),
                  ),
                ],
              ],
            ),
          ),
        ),
        SizedBox(
          height: 46,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                TextButton.icon(
                  onPressed: _dragging
                      ? null
                      : () => unawaited(_chooseRowTemplate()),
                  icon: const Icon(Icons.add),
                  label: const Text('항목 추가'),
                ),
                TextButton.icon(
                  onPressed: _dragging
                      ? null
                      : () => unawaited(_editProperty(null)),
                  icon: const Icon(Icons.add_chart),
                  label: const Text('속성 추가'),
                ),
                IconButton(
                  tooltip: '보기 설정',
                  onPressed:
                      _dragging ||
                          widget.viewOverride != null &&
                              widget.onViewOverrideChanged == null
                      ? null
                      : () => unawaited(_viewSettings()),
                  icon: const Icon(Icons.tune),
                ),
                IconButton(
                  tooltip: '보관함',
                  onPressed: _dragging ? null : () => unawaited(_archive()),
                  icon: const Icon(Icons.inventory_2_outlined),
                ),
                IconButton(
                  tooltip: '입력 폼',
                  onPressed: _dragging || _formsOpening
                      ? null
                      : () => unawaited(_openForms()),
                  icon: const Icon(Icons.dynamic_form_outlined),
                ),
                if (widget.actionRuntime != null)
                  IconButton(
                    tooltip: '버튼·자동화',
                    onPressed: _dragging || _actionsOpening || _formsOpening
                        ? null
                        : () => unawaited(_openActions()),
                    icon: const Icon(Icons.bolt_outlined),
                  ),
                if (result != null) Text('${result.rows.length}개 항목'),
              ],
            ),
          ),
        ),
        if (_saveFailed)
          Material(
            color: Theme.of(context).colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('저장하지 못했습니다. 편집 내용은 남아 있습니다.'),
                  Wrap(
                    alignment: WrapAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => unawaited(_saveFromUi()),
                        child: const Text('저장 재시도'),
                      ),
                      if (widget.onDiscardChanges != null)
                        TextButton(
                          onPressed: canDiscardDraft
                              ? widget.onDiscardChanges
                              : null,
                          child: const Text('초안 버리고 다시 읽기'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        if (_error != null)
          Padding(padding: const EdgeInsets.all(8), child: Text(_error!)),
        if (query != null && query.errors.isNotEmpty)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(query.errors.first.message),
          ),
        Expanded(
          child: KeyedSubtree(
            key: ValueKey('db-view-body-${_view.type}'),
            child: body,
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _autosave?.cancel();
    _timelineScroll.dispose();
    _pendingMedia.clear();
    _dragDone?.complete();
    _dragDone = null;
    _cellCommit = null;
    final routes = <Route<dynamic>>[
      ?_cellRoute,
      ?_taskLinksRoute,
      ?_actionsRoute,
      ?_formsRoute,
      ?_bodyRoute,
    ];
    final releaseBusy = _reportedBusy ? widget.onBusyChanged : null;
    if (routes.isNotEmpty || releaseBusy != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        for (final route in routes) {
          final navigator = route.navigator;
          if (navigator != null && navigator.mounted && route.isActive) {
            navigator.removeRoute(route);
          }
        }
        releaseBusy?.call(false);
      });
    }
    super.dispose();
  }
}

class _TimelineTaskLinksPainter extends CustomPainter {
  new({
    required this.links,
    required this.scroll,
    required this.laneHeight,
    required this.barCenter,
    required this.labelWidth,
    required this.color,
  }) : super(repaint: scroll);

  final List<_TimelineLink> links;
  final ScrollController scroll;
  final double laneHeight, barCenter, labelWidth;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final offset = scroll.positions.firstOrNull?.pixels ?? 0.0;
    final line = Paint()
      ..color = color.withValues(alpha: 0.8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeJoin = StrokeJoin.round;
    canvas.save();
    canvas.clipRect(Rect.fromLTRB(labelWidth, 0, size.width, size.height));
    for (final link in links) {
      final startY = link.predecessorLane * laneHeight + barCenter - offset;
      final endY = link.dependentLane * laneHeight + barCenter - offset;
      if ((startY < 0 && endY < 0) ||
          (startY > size.height && endY > size.height)) {
        continue;
      }
      final direction = link.forward ? 1.0 : -1.0;
      final endX = link.endX.clamp(labelWidth + 2.0, size.width - 2.0);
      final bendX = (endX - 8.0 * direction).clamp(labelWidth, size.width);
      canvas.drawPath(
        Path()
          ..moveTo(link.startX, startY)
          ..lineTo(bendX, startY)
          ..lineTo(bendX, endY)
          ..lineTo(endX, endY),
        line,
      );
      canvas.drawPath(
        Path()
          ..moveTo(endX - 5.0 * direction, endY - 3)
          ..lineTo(endX, endY)
          ..lineTo(endX - 5.0 * direction, endY + 3),
        line,
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _TimelineTaskLinksPainter oldDelegate) =>
      color != oldDelegate.color ||
      laneHeight != oldDelegate.laneHeight ||
      barCenter != oldDelegate.barCenter ||
      labelWidth != oldDelegate.labelWidth ||
      !const ListEquality<_TimelineLink>().equals(links, oldDelegate.links);
}

const _viewLabels = {
  'table': '표',
  'board': '보드',
  'list': '목록',
  'gallery': '갤러리',
  'calendar': '캘린더',
  'timeline': '타임라인',
  'chart': '차트',
  databaseDashboardViewType: '대시보드',
};

const _propertyLabels = {
  'title': '이름',
  'text': '텍스트',
  'number': '숫자',
  'status': '상태',
  'select': '선택',
  'multiSelect': '여러 개 선택',
  'date': '날짜',
  'checkbox': '체크박스',
  'url': '웹 주소',
  'email': '이메일',
  'phone': '전화번호',
  'people': '사람',
  'files': '파일 정보',
  'relation': '관계',
  'formula': '수식',
  'rollup': '롤업',
};

class _DatabaseChartPainter extends CustomPainter {
  const new(this.points, this.type, {this.range});
  final List<DatabaseChartPoint> points;
  final String type;
  final List<double>? range;
  static const _colors = [
    Color(0xff237d82),
    Color(0xffb77b4f),
    Color(0xff8671a9),
    Color(0xff759851),
    Color(0xffbd6268),
  ];
  @override
  void paint(Canvas canvas, Size size) {
    if (type == 'pie') {
      if (points.any((point) => point.value < 0)) return;
      final total = points.fold<double>(
        0,
        (sum, point) => sum + point.value.toDouble(),
      );
      if (total <= 0) return;
      var angle = -math.pi / 2;
      final rect = Rect.fromCenter(
        center: size.center(Offset.zero),
        width: math.min(size.width, size.height) - 12,
        height: math.min(size.width, size.height) - 12,
      );
      for (var i = 0; i < points.length; i++) {
        final sweep = points[i].value / total * 2 * math.pi;
        canvas.drawArc(
          rect,
          angle,
          sweep,
          true,
          Paint()..color = _colors[i % _colors.length],
        );
        angle += sweep;
      }
      return;
    }
    final values =
        range ?? points.map((point) => point.value.toDouble()).toList();
    final low = math.min(0.0, values.reduce(math.min)),
        high = math.max(0.0, values.reduce(math.max));
    final span = high == low ? 1.0 : high - low;
    if (type == 'bar') {
      final zero = (0 - low) / span * size.width,
          value = (points.single.value - low) / span * size.width;
      canvas.drawLine(
        Offset(zero, 0),
        Offset(zero, size.height),
        Paint()..color = const Color(0xffaabbb0),
      );
      canvas.drawRect(
        Rect.fromLTRB(
          math.min(zero, value),
          6,
          math.max(zero, value),
          size.height - 6,
        ),
        Paint()..color = _colors.first,
      );
    } else {
      final path = Path();
      for (var i = 0; i < points.length; i++) {
        final x = points.length == 1
            ? size.width / 2
            : i / (points.length - 1) * (size.width - 24) + 12;
        final y =
            size.height -
            12 -
            (points[i].value - low) / span * (size.height - 24);
        if (i == 0)
          path.moveTo(x, y);
        else
          path.lineTo(x, y);
        canvas.drawCircle(Offset(x, y), 4, Paint()..color = _colors.first);
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = _colors.first
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
  }

  @override
  bool shouldRepaint(_DatabaseChartPainter oldDelegate) =>
      oldDelegate.points != points ||
      oldDelegate.type != type ||
      oldDelegate.range != range;
}
