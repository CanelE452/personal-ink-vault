part of 'database_editor.dart';

class _DashboardLayout {
  const new(this.rows);

  static const maxWidgets = 12;
  static const _readLimit = 24;
  final List<_DashboardRow> rows;

  static _DashboardLayout? read(Object? raw) {
    if (raw == null) return const _DashboardLayout([]);
    if (raw is! List || raw.length > _readLimit) return null;
    final rows = <_DashboardRow>[];
    final rowIds = <String>{}, widgetIds = <String>{};
    for (final value in raw) {
      if (value is! Map<String, dynamic>) return null;
      final id = value['id'], children = value['widgets'];
      if (id is! String ||
          id.isEmpty ||
          !rowIds.add(id) ||
          children is! List ||
          widgetIds.length + children.length > _readLimit) {
        return null;
      }
      final widgets = <_DashboardWidget>[];
      for (final child in children) {
        if (child is! Map<String, dynamic>) return null;
        final id = child['id'];
        final databaseId = child['databaseId'], viewId = child['viewId'];
        if (id is! String ||
            id.isEmpty ||
            !widgetIds.add(id) ||
            databaseId is! String ||
            databaseId.isEmpty ||
            viewId is! String ||
            viewId.isEmpty) {
          return null;
        }
        widgets.add(_DashboardWidget(child));
      }
      rows.add(_DashboardRow(value, widgets));
    }
    return _DashboardLayout(rows);
  }

  int get count => rows.fold(0, (total, row) => total + row.widgets.length);
  bool get canAdd =>
      count < maxWidgets &&
      (rows.length < _readLimit || rows.last.widgets.length < 2);

  _DashboardLayout add(String databaseId, String viewId) {
    if (!canAdd) return this;
    final added = _DashboardWidget({
      'id': newId(),
      'databaseId': databaseId,
      'viewId': viewId,
    });
    final last = rows.lastOrNull;
    if (last != null && last.widgets.length < 2) {
      return _DashboardLayout([
        ...rows.take(rows.length - 1),
        _DashboardRow(last.raw, [...last.widgets, added]),
      ]);
    }
    return _DashboardLayout([
      ...rows,
      _DashboardRow({'id': newId()}, [added]),
    ]);
  }

  _DashboardLayout remove(String id) {
    final index = rows.indexWhere(
      (row) => row.widgets.any((item) => item.id == id),
    );
    if (index < 0) return this;
    final row = rows[index];
    final remaining = row.widgets.where((item) => item.id != id).toList();
    return _DashboardLayout([
      ...rows.take(index),
      if (remaining.isNotEmpty) _DashboardRow(row.raw, remaining),
      ...rows.skip(index + 1),
    ]);
  }

  _DashboardLayout move(String id, int direction) {
    final ordered = [for (final row in rows) ...row.widgets];
    final index = ordered.indexWhere((item) => item.id == id);
    final destination = index + direction;
    if (index < 0 || destination < 0 || destination >= ordered.length) {
      return this;
    }
    ordered.insert(destination, ordered.removeAt(index));
    final moved = <_DashboardRow>[];
    var start = 0;
    for (final row in rows) {
      final end = start + row.widgets.length;
      moved.add(_DashboardRow(row.raw, ordered.sublist(start, end)));
      start = end;
    }
    return _DashboardLayout(moved);
  }

  _DashboardLayout duplicate() => _DashboardLayout([
    for (final row in rows)
      _DashboardRow(
        {...row.raw, 'id': newId()},
        [
          for (final item in row.widgets)
            _DashboardWidget({...item.raw, 'id': newId()}),
        ],
      ),
  ]);

  List<Map<String, dynamic>> toJson() => [
    for (final row in rows)
      {
        ...row.raw,
        'widgets': [for (final item in row.widgets) item.raw],
      },
  ];
}

class _DashboardRow {
  const new(this.raw, this.widgets);
  final Map<String, dynamic> raw;
  final List<_DashboardWidget> widgets;
}

class _DashboardWidget {
  const new(this.raw);
  final Map<String, dynamic> raw;
  String get id => raw['id'] as String;
  String get databaseId => raw['databaseId'] as String;
  String get viewId => raw['viewId'] as String;
}

typedef _DashboardSourceKey = (String, String);

extension on DatabaseEditorState {
  Widget _dashboardBody(DatabaseView view) {
    if (widget.embedded || widget.viewOverride != null) {
      return const Center(child: Text('원본 데이터베이스에서 대시보드를 열어 주세요.'));
    }
    final layout = _DashboardLayout.read(view.config['dashboardRows']);
    if (layout == null) {
      return const Center(child: Text('대시보드 배치를 읽을 수 없습니다. 원본 설정은 보존됩니다.'));
    }
    final owner = widget.initialDatabase;
    final sources = [
      _database,
      for (final entry in widget.databases.entries)
        if (widget.dashboardSourcesReady &&
            entry.key == entry.value.id &&
            entry.key != _database.id)
          entry.value,
    ];
    final sourceViews = {
      for (final database in sources)
        for (final candidate in database.views)
          if (databaseViewTypes.contains(candidate.type))
            (database.id, candidate.id): (database: database, view: candidate),
    };
    final total = layout.count;
    final populated = layout.rows
        .where((row) => row.widgets.isNotEmpty)
        .toList();
    final positions = {
      for (final (index, item) in [
        for (final row in populated) ...row.widgets,
      ].indexed)
        item.id: index,
    };
    final capturedAt = DateTime.now().toUtc();
    final previews = <_DashboardSourceKey, Widget>{};
    bool isCurrent() =>
        mounted &&
        identical(widget.initialDatabase, owner) &&
        identical(_view, view) &&
        !_dragging &&
        !_configurationOpen;
    void change(_DashboardLayout next) {
      if (!isCurrent() || identical(next, layout)) return;
      _run(
        () => _updateView(
          view.copyWith(
            config: {...view.config, 'dashboardRows': next.toJson()},
          ),
        ),
      );
    }

    void open(_DashboardSourceKey key) {
      if (!isCurrent()) return;
      if (key.$1 == _database.id) {
        _selectView(sourceViews[key]!.view);
      } else if (widget.dashboardSourcesReady) {
        unawaited(widget.onOpenDashboardView?.call(key.$1, key.$2));
      }
    }

    Widget card(_DashboardWidget item, int index) {
      final key = (item.databaseId, item.viewId);
      final source = sourceViews[key];
      final foreign = item.databaseId != _database.id;
      final databaseTitle = widget.dashboardDatabaseTitles[item.databaseId];
      return Card(
        key: ValueKey('db-dashboard-widget-${item.id}'),
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                source?.view.name ?? '사용할 수 없는 보기',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              if (source != null && foreign && databaseTitle != null)
                Text(
                  databaseTitle,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              const SizedBox(height: 6),
              if (source == null && foreign && !widget.dashboardSourcesReady)
                const Text('연결된 보기를 확인하고 있습니다.')
              else if (source == null)
                const Text('연결된 보기를 찾지 못했습니다. 위젯 참조는 유지됩니다.')
              else
                previews.putIfAbsent(
                  key,
                  () => _dashboardPreview(
                    source.database,
                    source.view,
                    capturedAt,
                  ),
                ),
              const SizedBox(height: 4),
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (source != null &&
                      (!foreign || widget.onOpenDashboardView != null))
                    TextButton(
                      key: ValueKey('db-dashboard-open-${item.id}'),
                      onPressed: _dragging ? null : () => open(key),
                      child: const Text('원본 보기 열기'),
                    ),
                  IconButton(
                    key: ValueKey('db-dashboard-earlier-${item.id}'),
                    tooltip: '위젯 앞으로 이동',
                    onPressed: _dragging || index == 0
                        ? null
                        : () => change(layout.move(item.id, -1)),
                    icon: const Icon(Icons.arrow_upward),
                  ),
                  IconButton(
                    key: ValueKey('db-dashboard-later-${item.id}'),
                    tooltip: '위젯 뒤로 이동',
                    onPressed: _dragging || index == total - 1
                        ? null
                        : () => change(layout.move(item.id, 1)),
                    icon: const Icon(Icons.arrow_downward),
                  ),
                  IconButton(
                    key: ValueKey('db-dashboard-remove-${item.id}'),
                    tooltip: '대시보드에서 위젯 제거',
                    onPressed: _dragging
                        ? null
                        : () => change(layout.remove(item.id)),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        const margin = 12.0;
        final width = math.max(0.0, constraints.maxWidth - 2 * margin);
        return ListView.builder(
          padding: const EdgeInsets.all(margin),
          itemCount: populated.length + 1,
          itemBuilder: (context, index) {
            if (index == 0) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  PopupMenuButton<_DashboardSourceKey>(
                    tooltip: '대시보드 위젯 추가',
                    enabled:
                        !_dragging && layout.canAdd && sourceViews.isNotEmpty,
                    onSelected: (key) {
                      final source = sourceViews[key];
                      if (source != null &&
                          (key.$1 == _database.id ||
                              widget.dashboardSourcesReady &&
                                  identical(
                                    widget.databases[key.$1],
                                    source.database,
                                  ))) {
                        change(layout.add(key.$1, key.$2));
                      }
                    },
                    itemBuilder: (_) => [
                      for (final entry in sourceViews.entries)
                        PopupMenuItem(
                          key: ValueKey(
                            entry.key.$1 == _database.id
                                ? 'db-dashboard-add-${entry.key.$2}'
                                : 'db-dashboard-add-${entry.key.$1}-${entry.key.$2}',
                          ),
                          value: entry.key,
                          child: Text(
                            entry.key.$1 == _database.id
                                ? entry.value.view.name
                                : '${widget.dashboardDatabaseTitles[entry.key.$1] ?? entry.key.$1} · ${entry.value.view.name}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    icon: const Icon(Icons.add_box_outlined),
                  ),
                  if (total == 0) const Text('보관함의 데이터베이스 보기를 위젯으로 추가하세요.'),
                  if (sourceViews.isEmpty)
                    const Text('먼저 보관함의 데이터베이스에 다른 보기를 만드세요.'),
                  if (!layout.canAdd) const Text('대시보드 위젯 추가 한도에 도달했습니다.'),
                ],
              );
            }
            final row = populated[index - 1];
            final cardWidth = width >= 696 && row.widgets.length > 1
                ? (width - margin) / 2
                : width;
            return Padding(
              key: ValueKey('db-dashboard-row-${row.raw['id']}'),
              padding: const EdgeInsets.only(top: margin),
              child: Wrap(
                spacing: margin,
                runSpacing: margin,
                children: [
                  for (final item in row.widgets)
                    SizedBox(
                      width: cardWidth,
                      child: card(item, positions[item.id]!),
                    ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _dashboardPreview(
    WorkspaceDatabase database,
    DatabaseView view,
    DateTime capturedAt,
  ) {
    const limit = 6;
    final titleId = database.properties
        .firstWhereOrNull((property) => property.type == 'title')
        ?.id;
    final visible = view.visibleProperties.isEmpty
        ? database.properties
        : [
            for (final id in view.visibleProperties)
              ...database.properties.where((property) => property.id == id),
          ];
    final fields = visible
        .where((property) => property.id != titleId)
        .take(2)
        .toList();
    final query = _query(
      view: view,
      database: database,
      valuePropertyIds: fields.map((property) => property.id).toList(),
      capturedAt: capturedAt,
    );
    final result = query.apply(view);
    final entries = <Widget>[];
    if (view.type == 'chart') {
      final group = view.config.containsKey('chartGroupBy')
          ? _string(view.config['chartGroupBy'])
          : view.groupBy;
      if (group == null) {
        return const Text('원본 보기에서 차트의 묶을 속성을 선택하세요.');
      }
      final points = query.chart(
        groupBy: group,
        valuePropertyId: _string(view.config['chartValuePropertyId']),
        calculation: _string(view.config['chartCalculation']) ?? 'count',
        view: view,
      );
      for (final point in points.take(limit)) {
        entries.add(_dashboardEntry(point.label, _number(point.value)));
      }
    } else if (view.type == 'calendar' || view.type == 'timeline') {
      final property = _datePropertyFor(view, database: database);
      if (property == null) {
        return const Text('원본 보기에서 날짜 속성을 선택하세요.');
      }
      final items = query.calendar(propertyId: property.id, view: view);
      for (final item in items.take(limit)) {
        final row = database.rows.firstWhere((row) => row.id == item.rowId);
        final date = _date(item.start);
        entries.add(
          _dashboardEntry(
            _rowTitle(row, titleId),
            item.end == null ? date : '$date – ${_date(item.end!)}',
          ),
        );
      }
    } else {
      final group = view.type == 'board'
          ? database.properties
                .where((property) => property.id == view.groupBy)
                .firstOrNull
          : null;
      if (view.type == 'board' && group == null) {
        return const Text('원본 보기에서 묶을 속성을 선택하세요.');
      }
      var shown = 0;
      void addRows(Iterable<DatabaseRow> rows) {
        for (final row in rows.take(limit - shown)) {
          final detail = fields
              .map(
                (property) =>
                    '${property.name} ${_display(property, query.value(row, property.id))}',
              )
              .join(' · ');
          entries.add(_dashboardEntry(_rowTitle(row, titleId), detail));
          shown++;
        }
      }

      if (group == null) {
        addRows(result.rows);
      } else {
        for (final entry in result.groups.entries) {
          if (shown == limit) break;
          entries.add(
            Text('${_option(group, entry.key)} · ${entry.value.length}'),
          );
          addRows(entry.value);
        }
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('${_viewLabels[view.type]} · ${result.rows.length}개 항목'),
        if (query.errors.isNotEmpty) Text(query.errors.first.message),
        if (entries.isEmpty && query.errors.isEmpty)
          const Text('표시할 항목이 없습니다.'),
        ...entries,
      ],
    );
  }

  Widget _dashboardEntry(String title, String detail) => Padding(
    padding: const EdgeInsets.only(top: 6),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        if (detail.isNotEmpty)
          Text(
            detail,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
      ],
    ),
  );
}
