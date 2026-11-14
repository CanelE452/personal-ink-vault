import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/native/ink_vault_native.dart';
import 'package:saber/data/vault/database_query_native.dart';
import 'package:saber/data/vault/workspace_database.dart';
import 'package:saber/pages/workspace/database_editor.dart';

const titleId = '00000000-0000-4000-8000-000000000001';
const hoursId = '00000000-0000-4000-8000-000000000002';
const statusId = '00000000-0000-4000-8000-000000000003';
const dateId = '00000000-0000-4000-8000-000000000004';
const firstRow = '00000000-0000-4000-8000-000000000011';
const secondRow = '00000000-0000-4000-8000-000000000012';
const sourceViewId = '00000000-0000-4000-8000-000000000021';
const linkedViewId = '00000000-0000-4000-8000-000000000031';

WorkspaceDatabase sourceDatabase() => WorkspaceDatabase.empty().copyWith(
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
    DatabaseView.fromJson({
      ...DatabaseView.create(id: sourceViewId, name: '원본 전체 보기').toJson(),
      'futureSourceSettings': {'keep': true},
    }),
  ],
);

DatabaseView localView({String type = 'table', bool filtered = false}) =>
    DatabaseView.create(
      id: linkedViewId,
      name: '이 페이지 보기',
      type: type,
      filter: filtered
          ? {'propertyId': hoursId, 'operator': 'gt', 'value': 2}
          : null,
      groupBy: statusId,
      config: {
        'datePropertyId': dateId,
        'chartGroupBy': statusId,
        'chartValuePropertyId': hoursId,
        'chartCalculation': 'sum',
        'chartType': 'bar',
      },
    );

void main() {
  Future<
    ({GlobalKey<DatabaseEditorState> key, ValueNotifier<DatabaseView> view})
  >
  mount(
    WidgetTester tester, {
    required WorkspaceDatabase source,
    required DatabaseView view,
    Future<void> Function(WorkspaceDatabase)? onSave,
    ValueChanged<DatabaseView>? onViewChanged,
    ValueChanged<bool>? onDirtyChanged,
    DatabaseQueryRuntime? queryRuntime,
    double width = 1100,
    bool embedded = true,
  }) async {
    tester.view.physicalSize = Size(width, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final key = GlobalKey<DatabaseEditorState>();
    final current = ValueNotifier(view);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      current.dispose();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<DatabaseView>(
            valueListenable: current,
            builder: (_, local, _) => DatabaseEditor(
              key: key,
              initialDatabase: source,
              viewOverride: local,
              queryRuntime: queryRuntime,
              onViewOverrideChanged: (next) {
                current.value = next;
                onViewChanged?.call(next);
              },
              embedded: embedded,
              onSave: onSave ?? (_) async {},
              onDirtyChanged: onDirtyChanged,
              onBack: () {},
              autosaveDelay: const Duration(hours: 1),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (key: key, view: current);
  }

  Future<void> filterHoursAboveTwo(WidgetTester tester) async {
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
    await tester.enterText(find.byKey(const ValueKey('db-filter-value')), '2');
    await tester.tap(find.text('적용'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'linked filter projects original rows without replacing source views',
    (tester) async {
      final source = sourceDatabase();
      final original = source.toJson();
      final linked = await mount(
        tester,
        source: source,
        view: localView(filtered: true),
      );
      expect(
        find.byKey(const ValueKey('db-cell-$firstRow-$titleId')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('db-cell-$secondRow-$titleId')),
        findsOneWidget,
      );
      expect(linked.key.currentState!.database.toJson(), original);
      expect(find.byKey(const ValueKey('db-view-$sourceViewId')), findsNothing);
      expect(find.byTooltip('문서 목록으로'), findsNothing);
    },
  );

  testWidgets('linked view exposes compound filters and ordered sorts', (
    tester,
  ) async {
    const thirdRow = '00000000-0000-4000-8000-000000000013';
    final base = sourceDatabase();
    final source = base.copyWith(
      rows: [
        ...base.rows,
        DatabaseRow.create(
          id: thirdRow,
          values: {titleId: '추가 실험', hoursId: 4, statusId: 'done'},
        ),
      ],
    );
    final unchanged = source.toJson();
    final saved = <DatabaseView>[];
    final sourceSaves = <WorkspaceDatabase>[];
    final library = Platform.environment['INK_VAULT_NATIVE_LIBRARY'];
    var nativeCalls = 0;
    final native = library == null
        ? null
        : InkVaultNative.open(libraryPath: library);
    final view = localView().copyWith(
      clearGroupBy: true,
      filter: {
        'and': [
          {
            'or': [
              {
                'property': '상태',
                'op': 'equals',
                'value': 'todo',
                'future': {'keep': true},
              },
              {'propertyId': hoursId, 'operator': 'gt', 'value': 2},
            ],
          },
          {'propertyId': hoursId, 'operator': 'gte', 'value': 2},
        ],
      },
      sorts: [
        {'propertyId': hoursId, 'direction': 'ascending'},
        {'property': '이름', 'direction': 'desc'},
      ],
    );
    final linked = await mount(
      tester,
      source: source,
      view: view,
      onSave: (db) async => sourceSaves.add(db),
      onViewChanged: saved.add,
      queryRuntime: native == null
          ? null
          : DatabaseQueryRuntime(
              invoke: (request) {
                nativeCalls++;
                return native.invoke(request);
              },
            ),
    );
    await tester.tap(find.byTooltip('보기 설정'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('database-view-filter-add')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('database-view-sort-up-1')),
      findsOneWidget,
    );
    final value = find.byKey(const ValueKey('db-filter-value-3'));
    await tester.ensureVisible(value);
    await tester.enterText(value, 'NaN');
    await tester.tap(find.text('적용'));
    await tester.pumpAndSettle();
    expect(saved, isEmpty);
    expect(find.text('필터 조건과 비교할 값을 확인해 주세요.'), findsOneWidget);
    await tester.enterText(value, '3');
    final promote = find.byKey(const ValueKey('database-view-sort-up-1'));
    await tester.ensureVisible(promote);
    await tester.tap(promote);
    await tester.pumpAndSettle();
    await tester.tap(find.text('적용'));
    await tester.pumpAndSettle();

    expect(saved, hasLength(1));
    expect(saved.single.filter, {
      'and': [
        {
          'or': [
            {
              'property': '상태',
              'op': 'equals',
              'value': 'todo',
              'future': {'keep': true},
            },
            {'propertyId': hoursId, 'operator': 'gt', 'value': 3},
          ],
        },
        {'propertyId': hoursId, 'operator': 'gte', 'value': 2},
      ],
    });
    expect(saved.single.sorts, view.sorts.reversed.toList());
    expect(sourceSaves, isEmpty);
    expect(linked.key.currentState!.database.toJson(), unchanged);
    final first = find.byKey(const ValueKey('db-cell-$firstRow-$titleId'));
    final third = find.byKey(const ValueKey('db-cell-$thirdRow-$titleId'));
    expect(find.byKey(const ValueKey('db-cell-$secondRow-$titleId')), findsNothing);
    expect(tester.getTopLeft(third).dy, lessThan(tester.getTopLeft(first).dy));
    if (native != null) expect(nativeCalls, greaterThan(0));

    await tester.tap(find.byTooltip('보기 설정'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<EditableText>(find.descendant(
        of: value,
        matching: find.byType(EditableText),
      )).controller.text,
      '3',
    );
    linked.view.value = saved.single.copyWith(name: '외부에서 바뀐 보기');
    await tester.pumpAndSettle();
    await tester.tap(find.text('적용'));
    await tester.pumpAndSettle();
    expect(find.text('보기가 바뀌었습니다. 다시 열어 주세요.'), findsOneWidget);
    expect(saved, hasLength(1));
    expect(linked.view.value.name, '외부에서 바뀐 보기');
    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();

    tester.view.physicalSize = const Size(320, 850);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('보기 설정'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(promote);
    await tester.pumpAndSettle();
    expect(promote.hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();
  });

  testWidgets(
    'local filter settings save only the page view and keep source clean',
    (tester) async {
      final source = sourceDatabase();
      final original = source.toJson();
      final saves = <WorkspaceDatabase>[];
      final changes = <DatabaseView>[];
      final dirty = <bool>[];
      final linked = await mount(
        tester,
        source: source,
        view: localView(),
        onSave: (database) async => saves.add(database),
        onViewChanged: changes.add,
        onDirtyChanged: dirty.add,
      );
      await filterHoursAboveTwo(tester);
      expect(changes, hasLength(1));
      expect(changes.single.id, linkedViewId);
      expect(changes.single.filter, {
        'propertyId': hoursId,
        'operator': 'gt',
        'value': 2,
      });
      expect(linked.key.currentState!.database.toJson(), original);
      expect(
        find.byKey(const ValueKey('db-cell-$firstRow-$titleId')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('db-cell-$secondRow-$titleId')),
        findsOneWidget,
      );
      await linked.key.currentState!.save();
      await tester.pumpAndSettle();
      expect(saves, isEmpty);
      expect(dirty.last, false);
    },
  );

  testWidgets(
    'local view type changes reuse seven projections without adding source views',
    (tester) async {
      final source = sourceDatabase();
      final saves = <WorkspaceDatabase>[];
      final linked = await mount(
        tester,
        source: source,
        view: localView(),
        onSave: (database) async => saves.add(database),
      );
      await tester.tap(find.byTooltip('보기 형식'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('보드').last);
      await tester.pumpAndSettle();
      expect(linked.view.value.type, 'board');
      expect(linked.view.value.id, linkedViewId);
      expect(find.byKey(const ValueKey('db-view-body-board')), findsOneWidget);
      expect(
        linked.key.currentState!.database.views.single.toJson(),
        source.views.single.toJson(),
      );
      await linked.key.currentState!.save();
      expect(saves, isEmpty);
    },
  );

  testWidgets(
    'editing a visible linked row persists the same row and original source views',
    (tester) async {
      final source = sourceDatabase();
      final saved = <WorkspaceDatabase>[];
      final linked = await mount(
        tester,
        source: source,
        view: localView(filtered: true),
        onSave: (database) async => saved.add(database),
      );
      await tester.tap(
        find.byKey(const ValueKey('db-cell-$secondRow-$hoursId')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('db-cell-input')),
        '7.5',
      );
      await tester.tap(find.text('닫기'));
      await tester.pumpAndSettle();
      await linked.key.currentState!.save();
      expect(saved, hasLength(1));
      expect(saved.single.rows.first.toJson(), source.rows.first.toJson());
      expect(saved.single.rows.last.id, secondRow);
      expect(saved.single.rows.last.values[hoursId], 7.5);
      expect(
        saved.single.views.map((v) => v.toJson()).toList(),
        source.views.map((v) => v.toJson()).toList(),
      );
      expect(linked.view.value.filter, localView(filtered: true).filter);
    },
  );

  testWidgets(
    'parent view replacement updates projection while retaining a pending source edit',
    (tester) async {
      final source = sourceDatabase();
      final saved = <WorkspaceDatabase>[];
      final linked = await mount(
        tester,
        source: source,
        view: localView(),
        onSave: (database) async => saved.add(database),
      );
      await tester.tap(
        find.byKey(const ValueKey('db-cell-$firstRow-$hoursId')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('db-cell-input')), '8');
      await tester.tap(find.text('닫기'));
      await tester.pumpAndSettle();
      linked.view.value = localView(type: 'list', filtered: true);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('db-view-body-list')), findsOneWidget);
      expect(linked.key.currentState!.database.rows.first.values[hoursId], 8);
      await linked.key.currentState!.save();
      expect(saved.single.rows.first.values[hoursId], 8);
      expect(saved.single.views.single.toJson(), source.views.single.toJson());
    },
  );

  testWidgets(
    'all seven linked views remain usable at 320px without a document back control',
    (tester) async {
      final source = sourceDatabase();
      final linked = await mount(
        tester,
        source: source,
        view: localView(),
        width: 320,
      );
      for (final type in databaseViewTypes) {
        linked.view.value = localView(type: type);
        await tester.pumpAndSettle();
        expect(find.byKey(ValueKey('db-view-body-$type')), findsOneWidget);
        expect(find.byTooltip('문서 목록으로'), findsNothing);
        expect(linked.key.currentState!.database.rows.map((row) => row.id), [
          firstRow,
          secondRow,
        ]);
        expect(tester.takeException(), isNull);
      }
    },
  );
}
