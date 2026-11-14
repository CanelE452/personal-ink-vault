import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/vault/database_actions.dart';
import 'package:saber/data/vault/workspace_database.dart';
import 'package:saber/pages/workspace/block_page_editor.dart';
import 'package:saber/pages/workspace/database_editor.dart';

const titleId = '00000000-0000-4000-8000-000000000001';
const hoursId = '00000000-0000-4000-8000-000000000002';
const statusId = '00000000-0000-4000-8000-000000000003';
const dateId = '00000000-0000-4000-8000-000000000004';
const formulaId = '00000000-0000-4000-8000-000000000005';
const firstRow = '00000000-0000-4000-8000-000000000011';
const secondRow = '00000000-0000-4000-8000-000000000012';
const blockId = '00000000-0000-4000-8000-000000000031';
String viewId(int index) =>
    '00000000-0000-4000-8000-${(21 + index).toString().padLeft(12, '0')}';

WorkspaceDatabase databaseFixture() {
  final empty = WorkspaceDatabase.empty();
  return empty.copyWith(
    properties: [
      DatabaseProperty.create(id: titleId, name: '이름', type: 'title'),
      DatabaseProperty.create(id: hoursId, name: '시간', type: 'number'),
      DatabaseProperty.create(
        id: statusId,
        name: '상태',
        type: 'status',
        config: {
          'options': [
            {'id': 'todo', 'name': '할 일'},
            {'id': 'done', 'name': '완료'},
          ],
        },
      ),
      DatabaseProperty.create(id: dateId, name: '일정', type: 'date'),
      DatabaseProperty.create(
        id: formulaId,
        name: '두 배',
        type: 'formula',
        config: {'expression': 'prop("$hoursId") * 2'},
      ),
    ],
    rows: [
      DatabaseRow.create(
        id: firstRow,
        values: {
          titleId: '논문 읽기',
          hoursId: 2,
          statusId: 'todo',
          dateId: '2026-10-30',
        },
        body: {
          'version': 1,
          'blocks': [
            {'id': blockId, 'type': 'paragraph', 'text': '행의 실제 본문'},
          ],
        },
      ),
      DatabaseRow.create(
        id: secondRow,
        values: {
          titleId: '실험',
          hoursId: 3,
          statusId: 'done',
          dateId: '2026-10-31',
        },
      ),
    ],
    views: [
      for (var i = 0; i < databaseViewTypes.length; i++)
        DatabaseView.create(
          id: viewId(i),
          name: ['표', '보드', '목록', '갤러리', '캘린더', '타임라인', '차트'][i],
          type: databaseViewTypes[i],
          groupBy: statusId,
          config: {
            'datePropertyId': dateId,
            'chartGroupBy': statusId,
            'chartValuePropertyId': hoursId,
            'chartCalculation': 'sum',
            'chartType': 'bar',
          },
        ),
    ],
  );
}

WorkspaceDatabase taskLinksFixture() {
  final database = databaseFixture();
  final views = database.views;
  return WorkspaceDatabase.fromJson({
    ...database
        .copyWith(
          rows: database.rows.reversed.toList(),
          views: [
            for (final view in views)
              if (view.type == 'list')
                view.copyWith(
                  filter: {'propertyId': hoursId, 'operator': 'gt', 'value': 2},
                )
              else
                view,
            DatabaseView.create(
              id: viewId(7),
              name: '선택한 일정',
              type: 'timeline',
              filter: {'propertyId': hoursId, 'operator': 'gt', 'value': 2},
              config: {'datePropertyId': dateId},
            ),
          ],
        )
        .toJson(),
    'pivTaskLinks': {
      'schemaVersion': 1,
      'items': {
        secondRow: {
          'parentId': firstRow,
          'predecessorIds': [firstRow],
        },
      },
    },
  });
}

void main() {
  Future<GlobalKey<DatabaseEditorState>> mount(
    WidgetTester tester, {
    Future<void> Function(WorkspaceDatabase)? save,
    VoidCallback? back,
    ValueChanged<bool>? dirty,
    double width = 1100,
    WorkspaceDatabase? initial,
    Map<String, WorkspaceDatabase> databases = const {},
    DatabaseActionRuntime? runtime,
    DatabaseView? viewOverride,
    Duration autosaveDelay = const Duration(hours: 1),
  }) async {
    tester.view.physicalSize = Size(width, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final key = GlobalKey<DatabaseEditorState>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DatabaseEditor(
            key: key,
            initialDatabase: initial ?? databaseFixture(),
            databases: databases,
            onSave: save ?? (_) async {},
            onBack: back ?? () {},
            onDirtyChanged: dirty,
            actionRuntime: runtime,
            viewOverride: viewOverride,
            onViewOverrideChanged: viewOverride == null ? null : (_) {},
            embedded: viewOverride != null,
            currentRevision: () => blockId,
            autosaveDelay: autosaveDelay,
          ),
        ),
      ),
    );
    return key;
  }

  Future<void> view(WidgetTester tester, int index) async {
    await tester.ensureVisible(
      find.byKey(ValueKey('db-view-${viewId(index)}')),
    );
    await tester.tap(find.byKey(ValueKey('db-view-${viewId(index)}')));
    await tester.pumpAndSettle();
  }

  Future<void> editHours(WidgetTester tester, String value) async {
    await tester.tap(find.byKey(const ValueKey('db-cell-$firstRow-$hoursId')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('db-cell-input')), value);
    await tester.tap(find.text('닫기'));
    await tester.pumpAndSettle();
  }

  testWidgets('saved dashboard composes filtered views without editing them', (
    tester,
  ) async {
    final fixture = databaseFixture();
    final pending = fixture.views[0].copyWith(
      name: '진행 중 보기',
      filter: {'propertyId': statusId, 'operator': 'equals', 'value': 'todo'},
    );
    final done = fixture.views[2].copyWith(
      name: '완료 보기',
      filter: {'propertyId': statusId, 'operator': 'equals', 'value': 'done'},
    );
    final initial = fixture.copyWith(views: [pending, done]);
    WorkspaceDatabase? saved;
    final editor = await mount(
      tester,
      initial: initial,
      width: 380,
      save: (database) async {
        saved = WorkspaceDatabase.fromJson(
          jsonDecode(jsonEncode(database.toJson())),
        );
      },
    );
    await tester.tap(find.byTooltip('보기 추가'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('대시보드'));
    await tester.pumpAndSettle();
    const body = ValueKey('db-view-body-dashboard');
    expect(find.byKey(body), findsOneWidget);

    Future<void> addWidget(DatabaseView view) async {
      await tester.tap(find.byTooltip('대시보드 위젯 추가'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('db-dashboard-add-${view.id}')));
      await tester.pumpAndSettle();
    }

    await addWidget(pending);
    await addWidget(done);
    final dashboard = editor.currentState!.database.views.last;
    final rows = dashboard.config['dashboardRows'] as List;
    final row = rows.single as Map;
    final widgets = row['widgets'] as List;
    final pendingId = (widgets.first as Map)['id'];
    final doneId = (widgets.last as Map)['id'];
    Finder card(Object? id) => find.byKey(ValueKey('db-dashboard-widget-$id'));
    Finder inCard(Object? id, String text) =>
        find.descendant(of: card(id), matching: find.text(text));
    expect(row['id'], isNotEmpty);
    expect(widgets.map((widget) => widget['databaseId']), [
      initial.id,
      initial.id,
    ]);
    expect(widgets.map((widget) => widget['viewId']), [pending.id, done.id]);
    expect(inCard(pendingId, '논문 읽기'), findsOneWidget);
    expect(inCard(pendingId, '실험'), findsNothing);
    expect(inCard(doneId, '실험'), findsOneWidget);
    expect(inCard(doneId, '논문 읽기'), findsNothing);
    expect(
      tester.getTopLeft(card(pendingId)).dy,
      lessThan(tester.getTopLeft(card(doneId)).dy),
    );

    await tester.tap(find.byKey(ValueKey('db-dashboard-open-$pendingId')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('db-view-body-table')), findsOneWidget);
    expect(find.text('논문 읽기'), findsOneWidget);
    expect(find.text('실험'), findsNothing);
    final tab = find.byKey(ValueKey('db-view-${dashboard.id}'));
    await tester.ensureVisible(tab);
    await tester.tap(tab);
    await tester.pumpAndSettle();

    final move = find.byKey(ValueKey('db-dashboard-earlier-$doneId'));
    await tester.ensureVisible(move);
    await tester.tap(move);
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(card(doneId)).dy,
      lessThan(tester.getTopLeft(card(pendingId)).dy),
    );
    await tester.tap(find.byTooltip('저장'));
    await tester.pumpAndSettle();
    final persisted = saved!;
    expect(
      persisted.rows.map((row) => row.toJson()),
      initial.rows.map((row) => row.toJson()),
    );
    expect(
      persisted.views.take(2).map((view) => view.toJson()),
      initial.views.map((view) => view.toJson()),
    );
    expect(
      (persisted.views.last.config['dashboardRows'] as List).single['id'],
      row['id'],
    );

    await tester.pumpWidget(const SizedBox.shrink());
    final reopened = await mount(tester, initial: persisted, width: 1100);
    await tester.ensureVisible(tab);
    await tester.tap(tab);
    await tester.pumpAndSettle();
    expect(inCard(pendingId, '논문 읽기'), findsOneWidget);
    expect(inCard(doneId, '실험'), findsOneWidget);
    expect(
      tester.getTopLeft(card(doneId)).dy,
      tester.getTopLeft(card(pendingId)).dy,
    );
    expect(
      tester.getTopLeft(card(doneId)).dx,
      lessThan(tester.getTopLeft(card(pendingId)).dx),
    );

    await tester.tap(find.byKey(ValueKey('db-dashboard-remove-$doneId')));
    await tester.pumpAndSettle();
    expect(card(doneId), findsNothing);
    expect(card(pendingId), findsOneWidget);
    expect(
      reopened.currentState!.database.views
          .take(2)
          .map((view) => view.toJson()),
      initial.views.map((view) => view.toJson()),
    );
  });

  testWidgets('dashboard uses the exact foreign schema, rows and saved view', (
    tester,
  ) async {
    final owner = databaseFixture();
    final foreignTitle = viewId(18);
    final foreignScore = viewId(19);
    final foreignView = DatabaseView.create(
      id: owner.views.first.id,
      name: '외부 필터 보기',
      type: 'list',
      filter: {'propertyId': foreignScore, 'operator': 'gt', 'value': 1},
      visibleProperties: [foreignScore],
    );
    final foreign = WorkspaceDatabase.empty().copyWith(
      properties: [
        DatabaseProperty.create(id: foreignTitle, name: '외부 제목', type: 'title'),
        DatabaseProperty.create(
          id: foreignScore,
          name: '외부 점수',
          type: 'number',
        ),
      ],
      rows: [
        DatabaseRow.create(values: {foreignTitle: '외부 통과 행', foreignScore: 4}),
        DatabaseRow.create(values: {foreignTitle: '외부 제외 행', foreignScore: 0}),
      ],
      views: [foreignView],
    );
    final dashboard = DatabaseView.create(
      name: '통합 대시보드',
      type: databaseDashboardViewType,
      config: {
        'dashboardRows': [
          {
            'id': 'combined',
            'widgets': [
              {'id': 'local', 'databaseId': owner.id, 'viewId': foreignView.id},
              {
                'id': 'foreign',
                'databaseId': foreign.id,
                'viewId': foreignView.id,
              },
            ],
          },
        ],
      },
    );
    final editor = await mount(
      tester,
      initial: owner.copyWith(views: [dashboard, owner.views.first]),
      databases: {foreign.id: foreign},
    );
    expect(find.text('논문 읽기'), findsOneWidget);
    expect(find.text('외부 통과 행'), findsOneWidget);
    expect(find.text('외부 제외 행'), findsNothing);
    expect(find.text('외부 점수 4'), findsOneWidget);
    await tester.tap(find.byTooltip('대시보드 위젯 추가'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(ValueKey('db-dashboard-add-${foreign.id}-${foreignView.id}')),
    );
    await tester.pumpAndSettle();
    final rows =
        editor.currentState!.database.views.first.config['dashboardRows']
            as List;
    final added = (rows.last['widgets'] as List).single as Map;
    expect(added['databaseId'], foreign.id);
    expect(added['viewId'], foreignView.id);
    expect(foreign.views.single.toJson(), foreignView.toJson());
  });

  testWidgets('dashboard retains unavailable and unrecognized widget data', (
    tester,
  ) async {
    final fixture = databaseFixture();
    final source = fixture.views.first;
    final dashboardId = viewId(7);
    const external = {
      'id': 'external',
      'databaseId': 'another-database',
      'viewId': 'another-view',
      'futureWidgetSetting': {'width': 3},
    };
    final local = {
      'id': 'local',
      'databaseId': fixture.id,
      'viewId': source.id,
    };
    final missing = {
      'id': 'missing',
      'databaseId': fixture.id,
      'viewId': viewId(10),
    };
    final recursive = {
      'id': 'recursive',
      'databaseId': fixture.id,
      'viewId': dashboardId,
    };
    final rows = [
      {
        'id': 'first',
        'futureRowSetting': true,
        'widgets': [local, external],
      },
      {
        'id': 'second',
        'widgets': [missing, recursive],
      },
    ];
    final dashboard = DatabaseView.create(
      id: dashboardId,
      name: '개요',
      type: databaseDashboardViewType,
      config: {'dashboardRows': rows, 'futureLayoutSetting': 12},
    );
    final editor = await mount(
      tester,
      initial: fixture.copyWith(views: [dashboard, source]),
    );
    expect(find.text('사용할 수 없는 보기'), findsNWidgets(3));
    expect(
      find.byKey(const ValueKey('db-dashboard-open-local')),
      findsOneWidget,
    );
    expect(find.text('원본 보기 열기'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('db-dashboard-earlier-external')),
    );
    await tester.pumpAndSettle();
    final moved = editor.currentState!.database.views.first;
    expect(moved.config, {
      'futureLayoutSetting': 12,
      'dashboardRows': [
        {
          ...rows.first,
          'widgets': [external, local],
        },
        rows.last,
      ],
    });

    await tester.tap(find.byTooltip('보기 추가'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('현재 보기 복제'));
    await tester.pumpAndSettle();
    final duplicated = editor.currentState!.database.views.last;
    final copiedRow = (duplicated.config['dashboardRows'] as List).first as Map;
    final copiedWidget = (copiedRow['widgets'] as List).first as Map;
    expect(copiedRow['id'], isNot(rows.first['id']));
    expect(copiedWidget['id'], isNot(external['id']));
    expect(copiedWidget, {...external, 'id': copiedWidget['id']});
    expect(editor.currentState!.database.views.first.toJson(), moved.toJson());

    await tester.pumpWidget(const SizedBox.shrink());
    await mount(tester, initial: fixture, viewOverride: dashboard);
    expect(find.text('원본 데이터베이스에서 대시보드를 열어 주세요.'), findsOneWidget);
    expect(find.byTooltip('대시보드 위젯 추가'), findsNothing);
    await tester.tap(find.byTooltip('보기 형식'));
    await tester.pumpAndSettle();
    expect(find.text('대시보드'), findsNothing);
  });

  testWidgets(
    'task children can collapse and a filtered parent does not hide its child',
    (tester) async {
      await mount(tester, initial: taskLinksFixture(), width: 320);
      final parent = find.byKey(const ValueKey('db-row-open-$firstRow'));
      final child = find.byKey(const ValueKey('db-row-open-$secondRow'));
      final toggle = find.byKey(const ValueKey('db-task-children-$firstRow'));
      expect(
        tester.getTopLeft(parent).dy,
        lessThan(tester.getTopLeft(child).dy),
      );
      await tester.ensureVisible(toggle);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(child, findsNothing);
      await view(tester, 2);
      expect(find.byKey(const ValueKey('db-list-row-$firstRow')), findsNothing);
      expect(
        find.byKey(const ValueKey('db-list-row-$secondRow')),
        findsOneWidget,
      );
      expect(toggle, findsNothing);
      await view(tester, 0);
      await tester.ensureVisible(toggle);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(child, findsOneWidget);
    },
  );

  testWidgets(
    'timeline connects only task bars that survive the date view filter',
    (tester) async {
      await mount(tester, initial: taskLinksFixture(), width: 1100);
      const overlay = ValueKey('db-timeline-task-links');
      final predecessor = find.byKey(
        const ValueKey('db-timeline-row-$firstRow'),
      );
      final dependent = find.byKey(
        const ValueKey('db-timeline-row-$secondRow'),
      );
      Tooltip tooltip() => tester.widget<Tooltip>(
        find.ancestor(of: dependent, matching: find.byType(Tooltip)).first,
      );
      await view(tester, 5);
      expect(find.byKey(overlay), findsOneWidget);
      expect(tooltip().message, contains('선행 작업: 논문 읽기'));
      expect(
        tester.getTopLeft(predecessor).dy,
        lessThan(tester.getTopLeft(dependent).dy),
      );
      await view(tester, 7);
      expect(predecessor, findsNothing);
      expect(dependent, findsOneWidget);
      expect(find.byKey(overlay), findsNothing);
      expect(tooltip().message, isNot(contains('선행 작업:')));
    },
  );

  testWidgets(
    'task menus save a linked child and leave invalid links in the dialog',
    (tester) async {
      final operations = <String>[];
      WorkspaceDatabase? saved;
      final runtime = DatabaseActionRuntime(
        deviceId: blockId,
        invoke: (request) {
          operations.add(request['op'] as String);
          if (request['op'] == 'workspace_actions') {
            final database = request['database'] as Map<String, dynamic>;
            final event = request['event'] as Map<String, dynamic>;
            expect(event['type'], 'rowAdded');
            expect(
              WorkspaceDatabase.fromJson(database)
                  .taskLinks[event['rowId']]
                  ?.parentId,
              firstRow,
            );
            return {
              'database': database,
              'receipts': [],
              'duplicate': false,
              'changed': false,
            };
          }
          expect(request['op'], 'workspace_task_links');
          final rowId = request['rowId'] as String;
          final parentId = request['parentId'] as String?;
          final predecessors = request['predecessorIds'] as List;
          if (rowId == firstRow && parentId == secondRow) {
            return {
              'error': {
                'code': 'task_link_cycle',
                'message': 'Invalid parent cycle',
              },
            };
          }
          final existing = request['taskLinks'] as Map?;
          return {
            'taskLinks': {
              'schemaVersion': 1,
              'items': {
                ...?existing?['items'] as Map<String, dynamic>?,
                rowId: {'parentId': ?parentId, 'predecessorIds': predecessors},
              },
            },
          };
        },
      );
      final key = await mount(
        tester,
        runtime: runtime,
        save: (value) async {
          saved = value;
        },
      );
      Future<void> menu(String id, String title) async {
        final button = find.byKey(ValueKey('db-row-menu-$id'));
        await tester.ensureVisible(button);
        await tester.tap(button);
        await tester.pumpAndSettle();
        await tester.tap(find.text(title));
        await tester.pumpAndSettle();
      }

      await menu(firstRow, '하위 작업 추가');
      final database = key.currentState!.database;
      final child = database.rows.last;
      expect(child.values[titleId], '새 하위 작업');
      expect(database.taskLinks[child.id]?.parentId, firstRow);
      expect(operations, ['workspace_task_links', 'workspace_actions']);
      await key.currentState!.save();
      await tester.pumpAndSettle();
      expect(saved!.taskLinks[child.id]?.parentId, firstRow);

      await menu(secondRow, '작업 연결');
      await tester.tap(find.byKey(const ValueKey('db-task-parent-$firstRow')));
      await tester.tap(find.text('선행 작업 0'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('db-task-predecessor-$firstRow')),
      );
      await tester.pumpAndSettle();
      const apply = ValueKey('db-task-links-save');
      await tester.tap(find.byKey(apply));
      await tester.pumpAndSettle();
      expect(
        key.currentState!.database.taskLinks[secondRow]?.parentId,
        firstRow,
      );
      expect(key.currentState!.database.taskLinks[secondRow]?.predecessorIds, [
        firstRow,
      ]);
      expect(saved!.taskLinks[secondRow], isNull);

      await menu(firstRow, '작업 연결');
      await tester.tap(find.byKey(const ValueKey('db-task-parent-$secondRow')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(apply));
      await tester.pumpAndSettle();
      expect(find.textContaining('작업 연결이 순환합니다.'), findsOneWidget);
      expect(key.currentState!.database.taskLinks[firstRow], isNull);
      await tester.tap(find.text('취소'));
      await tester.pumpAndSettle();
      await key.currentState!.save();
      await tester.pumpAndSettle();
      expect(saved!.taskLinks[child.id]?.parentId, firstRow);
      expect(saved!.taskLinks[secondRow]?.predecessorIds, [firstRow]);
    },
  );

  testWidgets(
    'table edits typed raw values and computed cells never overwrite their source',
    (tester) async {
      WorkspaceDatabase? saved;
      final key = await mount(
        tester,
        save: (db) async {
          saved = db;
        },
      );
      await editHours(tester, '7.5');
      expect(key.currentState!.database.rows.first.values[hoursId], 7.5);
      expect(
        key.currentState!.database.rows.first.values.containsKey(formulaId),
        false,
      );
      expect(find.text('15'), findsOneWidget);
      await key.currentState!.save();
      final restored = WorkspaceDatabase.fromJson(
        jsonDecode(jsonEncode(saved!.toJson())),
      );
      expect(restored.rows.first.id, firstRow);
      expect(restored.rows.first.values[hoursId], 7.5);
      expect(
        restored.properties.last.config['expression'],
        'prop("$hoursId") * 2',
      );
    },
  );

  testWidgets('board drag changes the same row status shown by the table', (
    tester,
  ) async {
    final key = await mount(tester);
    await view(tester, 1);
    final card = find.byKey(const ValueKey('db-board-row-$firstRow'));
    final column = find.byKey(const ValueKey('db-board-target-done'));
    await tester.drag(card, tester.getCenter(column) - tester.getCenter(card));
    await tester.pumpAndSettle();
    expect(key.currentState!.database.rows.first.id, firstRow);
    expect(key.currentState!.database.rows.first.values[statusId], 'done');
    expect(key.currentState!.database.rows, hasLength(2));
    await view(tester, 0);
    final status = tester.widget<TextButton>(
      find.byKey(const ValueKey('db-cell-$firstRow-$statusId')),
    );
    expect((status.child! as Text).data, '완료');
  });

  testWidgets(
    'calendar date moves and chart aggregates share the actual edited rows',
    (tester) async {
      final key = await mount(tester);
      await editHours(tester, '7.5');
      await view(tester, 6);
      expect(find.byKey(const ValueKey('db-chart-value-todo')), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('db-chart-value-todo')))
            .data,
        '7.5',
      );
      await view(tester, 4);
      final event = find.byKey(const ValueKey('db-calendar-row-$firstRow'));
      final date = find.byKey(const ValueKey('db-calendar-day-2026-10-31'));
      await tester.drag(
        event,
        tester.getCenter(date) - tester.getCenter(event),
      );
      await tester.pumpAndSettle();
      expect(
        key.currentState!.database.rows.first.values[dateId],
        '2026-10-31',
      );
      await view(tester, 5);
      expect(
        find.byKey(const ValueKey('db-timeline-row-$firstRow')),
        findsOneWidget,
      );
      expect(key.currentState!.database.rows.first.id, firstRow);
    },
  );

  testWidgets(
    'all seven views render the same source rows at phone tablet and desktop widths',
    (tester) async {
      for (final width in [320.0, 800.0, 1400.0]) {
        final key = await mount(tester, width: width);
        for (var index = 0; index < databaseViewTypes.length; index++) {
          await view(tester, index);
          expect(
            find.byKey(ValueKey('db-view-body-${databaseViewTypes[index]}')),
            findsOneWidget,
          );
          expect(key.currentState!.database.rows.map((row) => row.id), [
            firstRow,
            secondRow,
          ]);
          expect(tester.takeException(), isNull);
        }
      }
    },
  );

  testWidgets(
    'saved view settings filter the underlying rows without copying them',
    (tester) async {
      final key = await mount(tester);
      await tester.tap(find.byTooltip('보기 설정'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('db-filter-property')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('시간').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('db-filter-operator')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('보다 큼'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('db-filter-value')),
        '2',
      );
      await tester.tap(find.text('적용'));
      await tester.pumpAndSettle();
      expect(key.currentState!.database.views.first.filter, {
        'propertyId': hoursId,
        'operator': 'gt',
        'value': 2,
      });
      expect(
        find.byKey(const ValueKey('db-cell-$firstRow-$titleId')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('db-cell-$secondRow-$titleId')),
        findsOneWidget,
      );
      expect(key.currentState!.database.rows, hasLength(2));
    },
  );

  testWidgets('failed back keeps the edited database and retry can close it', (
    tester,
  ) async {
    var attempts = 0, backs = 0;
    final dirty = <bool>[];
    final key = await mount(
      tester,
      dirty: dirty.add,
      back: () {
        backs++;
      },
      save: (_) async {
        if (++attempts == 1) throw StateError('disk');
      },
    );
    await editHours(tester, '9');
    await tester.tap(find.byTooltip('문서 목록으로'));
    await tester.pump();
    expect(backs, 0);
    expect(dirty.last, true);
    expect(find.textContaining('저장하지 못했습니다'), findsOneWidget);
    expect(key.currentState!.database.rows.first.values[hoursId], 9);
    await tester.tap(find.text('저장 재시도'));
    await tester.pump();
    await tester.tap(find.byTooltip('문서 목록으로'));
    await tester.pump();
    expect(backs, 1);
  });

  testWidgets(
    'parent save drains row block editing and shares a pending database writer',
    (tester) async {
      final pending = Completer<void>();
      addTearDown(() {
        if (!pending.isCompleted) pending.complete();
      });
      final saved = <WorkspaceDatabase>[];
      final key = await mount(
        tester,
        save: (db) {
          saved.add(db);
          return pending.future;
        },
      );
      await tester.tap(find.byKey(const ValueKey('db-row-open-$firstRow')));
      await tester.pumpAndSettle();
      expect(find.byType(BlockPageEditor), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('block-text-$blockId')),
        '행 본문 수정',
      );
      final first = key.currentState!.save();
      final second = key.currentState!.save();
      expect(identical(first, second), true);
      await tester.pump();
      var done = false;
      first.then((_) {
        done = true;
      });
      expect(done, false);
      expect(saved, hasLength(1));
      expect(saved.single.rows.first.body['blocks'][0]['text'], '행 본문 수정');
      pending.complete();
      for (var i = 0; i < 30 && !done; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(done, true);
      expect(find.byType(BlockPageEditor), findsNothing);
    },
  );

  testWidgets(
    'cell and configuration controllers survive their closing route transitions',
    (tester) async {
      await mount(tester);
      await editHours(tester, '4.5');
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('보기 설정'));
      await tester.pumpAndSettle();
      final name = find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.labelText == '보기 이름',
      );
      await tester.enterText(name, '새 보기 이름');
      await tester.tap(find.text('적용'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'malformed property configuration is displayed safely and preserved on a name edit',
    (tester) async {
      var initial = databaseFixture();
      initial = initial.updateProperty(
        initial.properties.last.copyWith(
          config: {
            'expression': 12,
            'future': {'keep': true},
          },
        ),
      );
      final key = await mount(tester, initial: initial);
      await tester.tap(find.text('두 배'));
      await tester.pumpAndSettle();
      expect(find.textContaining('원본 설정을 유지'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('db-property-name')),
        '계산 필드',
      );
      await tester.tap(find.text('적용'));
      await tester.pumpAndSettle();
      expect(key.currentState!.database.properties.last.name, '계산 필드');
      expect(key.currentState!.database.properties.last.config, {
        'expression': 12,
        'future': {'keep': true},
      });
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'malformed chart configuration does not crash and survives a view name edit',
    (tester) async {
      var initial = databaseFixture();
      final original = initial.views.last.copyWith(
        config: {
          ...initial.views.last.config,
          'chartCalculation': 12,
          'future': {'keep': true},
        },
      );
      initial = initial.updateView(original);
      final key = await mount(tester, initial: initial);
      await view(tester, 6);
      expect(find.textContaining('차트 설정을 읽을 수 없습니다'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('보기 설정'));
      await tester.pumpAndSettle();
      expect(find.textContaining('원본 설정을 유지'), findsOneWidget);
      final name = find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.labelText == '보기 이름',
      );
      await tester.enterText(name, '원본 차트');
      await tester.tap(find.text('적용'));
      await tester.pumpAndSettle();
      expect(key.currentState!.database.views.last.name, '원본 차트');
      expect(key.currentState!.database.views.last.config, original.config);
    },
  );

  testWidgets(
    'duplicates the selected view settings and shares only the existing rows',
    (tester) async {
      final fixture = databaseFixture();
      final original = DatabaseView.fromJson({
        ...fixture.views.first
            .copyWith(
              name: '검토 중',
              filter: {
                'and': [
                  {'propertyId': hoursId, 'operator': 'gt', 'value': 2},
                  {
                    'propertyId': statusId,
                    'operator': 'equals',
                    'value': 'done',
                  },
                ],
              },
              sorts: [
                {'propertyId': hoursId, 'direction': 'descending'},
                {'propertyId': titleId, 'direction': 'ascending'},
              ],
              visibleProperties: [titleId, hoursId],
            )
            .toJson(),
        'id': viewId(1),
        'futureViewSettings': {
          'keep': [true, 'opaque'],
        },
      });
      final initial = fixture.copyWith(views: [fixture.views.first, original]);
      final saved = <WorkspaceDatabase>[];
      await mount(
        tester,
        width: 380,
        initial: initial,
        save: (value) async => saved.add(
          WorkspaceDatabase.fromJson(jsonDecode(jsonEncode(value.toJson()))),
        ),
      );
      await view(tester, 1);
      await tester.tap(find.byTooltip('보기 추가'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('현재 보기 복제'));
      await tester.pumpAndSettle();
      expect(find.text('검토 중 복사본'), findsOneWidget);
      expect(find.text('1개 항목'), findsOneWidget);
      await tester.tap(find.byTooltip('저장'));
      await tester.pumpAndSettle();

      final persisted = saved.single;
      final copy = persisted.views.last;
      expect(copy.id, isNot(original.id));
      expect(copy.toJson(), {
        ...original.toJson(),
        'id': copy.id,
        'name': '검토 중 복사본',
      });
      expect(persisted.toJson(), {
        ...initial.toJson(),
        'views': [...initial.views.map((view) => view.toJson()), copy.toJson()],
      });

      await tester.pumpWidget(const SizedBox.shrink());
      final editor = await mount(tester, initial: persisted);
      await tester.tap(find.byKey(ValueKey('db-view-${copy.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('보기 설정'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byWidgetPredicate(
          (widget) =>
              widget is TextField && widget.decoration?.labelText == '보기 이름',
        ),
        '복사한 보기만 변경',
      );
      await tester.tap(find.text('적용'));
      await tester.pumpAndSettle();
      final views = editor.currentState!.database.views;
      expect(views[1].toJson(), original.toJson());
      expect(views.last.name, '복사한 보기만 변경');
    },
  );

  testWidgets(
    'removes only the selected source view and keeps the draft if saving fails',
    (tester) async {
      final fixture = databaseFixture();
      final surviving = DatabaseView.fromJson({
        ...fixture.views[2].toJson(),
        'filter': {'propertyId': hoursId, 'operator': 'gt', 'value': 2},
        'futureViewSettings': {
          'keep': [true, 'opaque'],
        },
      });
      final initial = fixture.copyWith(
        views: [fixture.views[0], fixture.views[1], surviving],
      );
      final saved = <WorkspaceDatabase>[];
      var attempts = 0;
      final editor = await mount(
        tester,
        width: 380,
        initial: initial,
        save: (value) async {
          if (++attempts == 1) throw StateError('disk');
          saved.add(
            WorkspaceDatabase.fromJson(jsonDecode(jsonEncode(value.toJson()))),
          );
        },
      );
      await view(tester, 1);
      await tester.tap(find.byTooltip('보기 설정'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('db-delete-view')));
      await tester.pumpAndSettle();
      expect(find.textContaining('행과 속성은 유지됩니다'), findsOneWidget);
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('db-delete-view-dialog')),
          matching: find.text('취소'),
        ),
      );
      await tester.pumpAndSettle();
      expect(editor.currentState!.database.toJson(), initial.toJson());
      expect(attempts, 0);
      expect(find.text('보기 설정'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('db-delete-view')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('db-confirm-delete-view')));
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('db-view-${viewId(1)}')), findsNothing);
      expect(find.byKey(const ValueKey('db-view-body-list')), findsOneWidget);
      expect(find.text('1개 항목'), findsOneWidget);
      final expected = {
        ...initial.toJson(),
        'views': [fixture.views[0].toJson(), surviving.toJson()],
      };
      expect(editor.currentState!.database.toJson(), expected);

      await tester.tap(find.byTooltip('저장'));
      await tester.pumpAndSettle();
      expect(find.textContaining('저장하지 못했습니다'), findsOneWidget);
      expect(editor.currentState!.database.toJson(), expected);
      await tester.tap(find.text('저장 재시도'));
      await tester.pumpAndSettle();
      expect(attempts, 2);
      expect(saved.single.toJson(), expected);

      await tester.pumpWidget(const SizedBox.shrink());
      await mount(tester, initial: saved.single);
      expect(find.byKey(ValueKey('db-view-${viewId(1)}')), findsNothing);
      await view(tester, 2);
      expect(find.text('1개 항목'), findsOneWidget);
      await tester.tap(find.byTooltip('보기 설정'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('db-delete-view')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('db-confirm-delete-view')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('db-view-body-table')), findsOneWidget);
    },
  );

  testWidgets('omits deletion from the last or an embedded view', (
    tester,
  ) async {
    final fixture = databaseFixture();
    final last = fixture.copyWith(views: [fixture.views.first]);
    await mount(tester, initial: last);
    await tester.tap(find.byTooltip('보기 설정'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('db-delete-view')), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await mount(tester, initial: fixture, viewOverride: fixture.views[1]);
    await tester.tap(find.byTooltip('보기 설정'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('db-delete-view')), findsNothing);
  });

  testWidgets('view deletion confirmation cannot outlive the editor owner', (
    tester,
  ) async {
    final original = databaseFixture();
    final owner = ValueNotifier(original);
    addTearDown(owner.dispose);
    final key = GlobalKey<DatabaseEditorState>();
    var writes = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder(
            valueListenable: owner,
            builder: (_, database, _) => DatabaseEditor(
              key: key,
              initialDatabase: database,
              onSave: (_) async {
                writes++;
              },
              onBack: () {},
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('보기 설정'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('db-delete-view')));
    await tester.pumpAndSettle();
    owner.value = WorkspaceDatabase.fromJson(original.toJson());
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('db-confirm-delete-view')));
    await tester.pumpAndSettle();
    expect(key.currentState!.database.toJson(), original.toJson());
    expect(writes, 0);
  });

  testWidgets(
    'renaming a view preserves every existing sort and its unknown fields',
    (tester) async {
      var initial = databaseFixture();
      final sorts = <Map<String, dynamic>>[
        {
          'propertyId': hoursId,
          'direction': 'ascending',
          'future': {'keep': true},
        },
        {
          'propertyId': titleId,
          'direction': 'descending',
          'unknown': [1, 2],
        },
      ];
      initial = initial.updateView(initial.views.first.copyWith(sorts: sorts));
      final key = await mount(tester, initial: initial);
      await tester.tap(find.byTooltip('보기 설정'));
      await tester.pumpAndSettle();
      final name = find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.labelText == '보기 이름',
      );
      await tester.enterText(name, '이름만 변경');
      await tester.tap(find.text('적용'));
      expect(key.currentState!.database.views.first.sorts, sorts);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('autosave persists row body without closing the row editor', (
    tester,
  ) async {
    final saved = <WorkspaceDatabase>[];
    await mount(
      tester,
      autosaveDelay: const Duration(milliseconds: 100),
      save: (database) async => saved.add(database),
    );
    await tester.tap(find.byKey(const ValueKey('db-row-open-$firstRow')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('block-text-$blockId')),
      '자동 저장 후에도 계속 쓰는 본문',
    );
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(saved, isNotEmpty);
    expect(
      saved.last.rows.first.body['blocks'][0]['text'],
      '자동 저장 후에도 계속 쓰는 본문',
    );
    expect(find.byType(BlockPageEditor), findsOneWidget);
    expect(find.byKey(const ValueKey('block-text-$blockId')), findsOneWidget);
  });
}
