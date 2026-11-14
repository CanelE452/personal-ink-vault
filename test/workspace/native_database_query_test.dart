import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/native/ink_vault_native.dart';
import 'package:saber/data/vault/database_query_native.dart';
import 'package:saber/data/vault/workspace_database.dart';
import 'package:saber/pages/workspace/database_editor.dart';

const _db = '10000000-0000-4000-8000-000000000001';
const _title = '10000000-0000-4000-8000-000000000002';
const _amount = '10000000-0000-4000-8000-000000000003';
const _formula = '10000000-0000-4000-8000-000000000004';
const _date = '10000000-0000-4000-8000-000000000005';
const _first = '10000000-0000-4000-8000-000000000011';
const _second = '10000000-0000-4000-8000-000000000012';

WorkspaceDatabase _fixture() => WorkspaceDatabase.fromJson({
  'schemaVersion': 1,
  'id': _db,
  'future': {'preserved': true},
  'properties': [
    {'id': _title, 'name': '제목', 'type': 'title'},
    {'id': _amount, 'name': '수량', 'type': 'number'},
    {
      'id': _formula,
      'name': '계산',
      'type': 'formula',
      'config': {'expression': 'prop("$_amount") * 2'},
    },
    {'id': _date, 'name': '날짜', 'type': 'date'},
  ],
  'rows': [
    {
      'id': _first,
      'values': {_title: '첫 행', _amount: 2, _date: '2026-10-30'},
    },
    {
      'id': _second,
      'values': {_title: '둘째 행', _amount: 3, _date: '2026-10-31'},
    },
  ],
  'views': [
    for (var i = 0; i < databaseViewTypes.length; i++)
      {
        'id': '10000000-0000-4000-8000-${(21 + i).toString().padLeft(12, '0')}',
        'name': databaseViewTypes[i],
        'type': databaseViewTypes[i],
        'groupBy': _title,
        'config': {
          'datePropertyId': _date,
          'chartGroupBy': _title,
          'chartCalculation': 'count',
        },
      },
  ],
});

Map<String, dynamic> _query(Map<String, Object?> request) =>
    Map<String, dynamic>.from(
      request['encoding'] == 'utf16-v1'
          ? DatabaseQueryCodec.unpack(request['payload']) as Map
          : request,
    );

Map<String, dynamic> _responseValue(Map<String, Object?> request) {
  final query = _query(request);
  final database = WorkspaceDatabase.fromJson(
    Map<String, dynamic>.from(query['database'] as Map),
  );
  return {
    'results': [
      for (final raw in query['operations'] as List)
        switch ((raw as Map)['type']) {
          'apply' => {
            'rowIds': [_second, _first],
            'groups': [
              {
                'key': 'z',
                'rowIds': [_second],
              },
              {
                'key': 'a',
                'rowIds': [_first],
              },
            ],
            'errors': [],
          },
          'values' => [
            for (final id in [_second, _first])
              {
                'rowId': id,
                'values': [
                  for (final property in raw['propertyIds'] as List)
                    {
                      'propertyId': property,
                      'value': property == _formula
                          ? 900
                          : database.rows
                                .singleWhere((row) => row.id == id)
                                .values[property],
                    },
                ],
              },
          ],
          'calendar' => [
            {
              'rowId': _second,
              'start': '2026-10-31T00:00:00.000Z',
              'end': null,
              'allDay': true,
            },
          ],
          'chart' => [
            {
              'key': 'native',
              'label': '공통 엔진 결과',
              'value': 77,
              'rowIds': [_second],
            },
          ],
          _ => throw StateError('Unexpected operation'),
        },
    ],
    'errors': [],
    'remainingBudget': 9000,
  };
}

Map<String, dynamic> _response(Map<String, Object?> request) => {
  'encoding': 'utf16-v1',
  'payload': DatabaseQueryCodec.pack(_responseValue(request)),
};

void main() {
  testWidgets(
    'dashboard projects its exact source view through native queries',
    (tester) async {
      final fixture = _fixture();
      final source = fixture.views.first.copyWith(
        filter: {'propertyId': _amount, 'operator': 'gt', 'value': 1},
        visibleProperties: [_title, _formula],
      );
      final dashboard = DatabaseView.create(
        type: databaseDashboardViewType,
        config: {
          'dashboardRows': [
            {
              'id': 'overview',
              'widgets': [
                {'id': 'main', 'databaseId': fixture.id, 'viewId': source.id},
              ],
            },
          ],
        },
      );
      final views = <Object?>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DatabaseEditor(
              initialDatabase: fixture.copyWith(views: [dashboard, source]),
              onSave: (_) async {},
              onBack: () {},
              queryRuntime: DatabaseQueryRuntime(
                invoke: (request) {
                  final operations = _query(request)['operations'] as List;
                  views.add(operations.first['view']);
                  return _response(request);
                },
              ),
            ),
          ),
        ),
      );
      expect(views, isNotEmpty);
      expect(views, everyElement(source.toJson()));
      expect(find.text('계산 900'), findsNWidgets(2));
      expect(find.text('수량 3'), findsNothing);
    },
  );

  test(
    'dashboard views are rejected before sending native query operations',
    () {
      final database = _fixture();
      final dashboard = DatabaseView.create(type: databaseDashboardViewType);
      final runtime = DatabaseQueryRuntime(
        invoke: (_) =>
            throw StateError('Dashboard must not reach native query'),
      );
      expect(
        () => runtime.evaluate(
          database,
          operations: [
            {'type': 'apply', 'view': dashboard.toJson()},
          ],
        ),
        throwsA(
          isA<DatabaseQueryNativeException>().having(
            (error) => error.code,
            'code',
            'invalid_arguments',
          ),
        ),
      );
    },
  );

  test('UTF16 wire retains lone surrogates supplementary units and object insertion order', () {
    final lone = String.fromCharCodes([0xd800]);
    final source = <String, Object?>{
      'z': lone,
      'a': [
        '😀',
        String.fromCharCodes([0xdc00]),
        null,
        false,
        1.5,
      ],
    };
    final packed = DatabaseQueryCodec.pack(source);
    final decoded = Map<String, dynamic>.from(
      DatabaseQueryCodec.unpack(jsonDecode(jsonEncode(packed))) as Map,
    );
    expect(decoded.keys, ['z', 'a']);
    expect((decoded['z'] as String).codeUnits, [0xd800]);
    expect((decoded['a'] as List)[0], '😀');
    expect(((decoded['a'] as List)[1] as String).codeUnits, [0xdc00]);
    expect(decoded, source);
  });

  test('UTF16 wire rejects forward references duplicate keys shared DAGs and invalid units', () {
    for (final payload in [
      {
        'root': 0,
        'nodes': [
          [
            'a',
            [0],
          ],
        ],
      },
      {
        'root': 0,
        'nodes': [
          [
            's',
            [65536],
          ],
        ],
      },
      {
        'root': 1,
        'nodes': [
          null,
          [
            'a',
            [0, 0],
          ],
        ],
      },
      {
        'root': 2,
        'nodes': [
          null,
          false,
          [
            'o',
            [
              [
                [97],
                0,
              ],
              [
                [97],
                1,
              ],
            ],
          ],
        ],
      },
      {
        'root': 0,
        'nodes': [null, false],
      },
    ]) {
      expect(() => DatabaseQueryCodec.unpack(payload), throwsFormatException);
    }
  });

  test('one native batch captures the snapshot clock plan and reusable immutable values', () {
    final database = _fixture(), view = database.views.first;
    final original = database.toJson();
    var calls = 0;
    late Map<String, dynamic> sent;
    late Map<String, dynamic> returned;
    final runtime = DatabaseQueryRuntime(
      invoke: (request) {
        calls++;
        sent = _query(request);
        return returned = _response(request);
      },
    );
    final query = runtime.project(
      database,
      view: view,
      now: DateTime.parse('2026-10-30T09:00:00+09:00'),
      valuePropertyIds: [_formula],
    );
    expect(sent['op'], 'workspace_query');
    expect(sent['capturedAtUtc'], '2026-10-30T00:00:00.000Z');
    expect(sent['database'], {
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
    });
    expect(sent['operations'], [
      {'type': 'apply', 'view': view.toJson()},
      {
        'type': 'values',
        'from': 0,
        'propertyIds': [_formula],
      },
    ]);
    expect(query.apply(view).rows.map((row) => row.id), [_second, _first]);
    expect(query.apply(view).groups.keys, ['z', 'a']);
    for (var i = 0; i < 10; i++) {
      expect(query.value(database.rows.first, _formula).value, 900);
    }
    (returned['payload'] as Map)['nodes'] = [];
    expect(query.value(database.rows.first, _formula).value, 900);
    expect(calls, 1);
    expect(database.toJson(), original);
  });

  test(
    'projection reads native calendar and chart results without extra calls',
    () {
      final database = _fixture();
      var calls = 0;
      final runtime = DatabaseQueryRuntime(
        invoke: (request) {
          calls++;
          return _response(request);
        },
      );
      final calendarView = database.views.firstWhere(
        (view) => view.type == 'calendar',
      );
      final calendar = runtime.project(database, view: calendarView);
      expect(
        calendar.calendar(propertyId: _date, view: calendarView).single.rowId,
        _second,
      );
      expect(
        calendar.calendar(propertyId: _date, view: calendarView).single.allDay,
        true,
      );
      final chartView = database.views.last;
      final chart = runtime.project(database, view: chartView);
      expect(chart.chart(groupBy: _title, view: chartView).single.value, 77);
      expect(calls, 2);
    },
  );

  test('foreign duplicate missing values and malformed responses become explicit errors', () {
    final database = _fixture(), original = database.toJson();
    for (final corrupt in <void Function(Map<String, dynamic>)>[
      (response) => (response['results'] as List).clear(),
      (response) => ((response['results'] as List)[0] as Map)['rowIds'] = [
        _first,
        _first,
      ],
      (response) => ((response['results'] as List)[0] as Map)['rowIds'] = [
        '10000000-0000-4000-8000-999999999999',
      ],
      (response) =>
          (((response['results'] as List)[1] as List).first as Map)['values'] =
              [],
      (response) => response['remainingBudget'] = 'unknown',
    ]) {
      final query =
          DatabaseQueryRuntime(
            invoke: (request) {
              final response = _responseValue(request);
              corrupt(response);
              return {
                'encoding': 'utf16-v1',
                'payload': DatabaseQueryCodec.pack(response),
              };
            },
          ).project(
            database,
            view: database.views.first,
            valuePropertyIds: [_formula],
          );
      expect(query.errors, isNotEmpty);
      expect(query.value(database.rows.first, _formula).isError, true);
      expect(database.toJson(), original);
    }
  });

  test('native failure is visible and never recomputes the Dart formula', () {
    final database = _fixture();
    final query = DatabaseQueryRuntime(
      invoke: (_) =>
          throw const InkVaultNativeException('unsupported', 'synthetic'),
    ).project(database, view: database.views.first);
    expect(query.errors.single.code, 'unsupported');
    expect(query.value(database.rows.first, _formula).isError, true);
    expect(query.value(database.rows.first, _formula).value, isNull);
  });

  test('a related database with mismatched lookup identity is rejected before native work', () {
    final database = _fixture();
    var calls = 0;
    final query =
        DatabaseQueryRuntime(
          invoke: (request) {
            calls++;
            return _response(request);
          },
        ).project(
          database,
          view: database.views.first,
          databases: {'wrong-database': database},
        );
    expect(query.errors, isNotEmpty);
    expect(calls, 0);
  });

  testWidgets(
    'all seven views consume native results while raw data and save stay unchanged',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final database = _fixture(), original = database.toJson();
      final requests = <Map<String, dynamic>>[];
      var saves = 0;
      final runtime = DatabaseQueryRuntime(
        invoke: (request) {
          requests.add(_query(request));
          return _response(request);
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DatabaseEditor(
              initialDatabase: database,
              queryRuntime: runtime,
              onSave: (_) async {
                saves++;
              },
              onBack: () {},
            ),
          ),
        ),
      );
      expect(find.text('900'), findsNWidgets(2));
      expect(
        tester
            .getTopLeft(find.byKey(const ValueKey('db-cell-$_second-$_title')))
            .dy,
        lessThan(
          tester
              .getTopLeft(find.byKey(const ValueKey('db-cell-$_first-$_title')))
              .dy,
        ),
      );
      for (final view in database.views.skip(1)) {
        await tester.tap(find.byKey(ValueKey('db-view-${view.id}')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(
          find.byKey(ValueKey('db-view-body-${view.type}')),
          findsOneWidget,
        );
      }
      expect(
        find.byKey(const ValueKey('db-chart-value-native')),
        findsOneWidget,
      );
      expect(find.text('77'), findsOneWidget);
      expect(
        requests
            .where(
              (request) =>
                  (request['operations'] as List).last['type'] == 'values',
            )
            .length,
        greaterThanOrEqualTo(4),
      );
      expect(
        requests
            .where(
              (request) =>
                  (request['operations'] as List).last['type'] == 'calendar',
            )
            .length,
        2,
      );
      expect(
        requests
            .where(
              (request) =>
                  (request['operations'] as List).last['type'] == 'chart',
            )
            .length,
        1,
      );
      expect(saves, 0);
      expect(database.toJson(), original);
      await tester.pumpWidget(const SizedBox());
    },
  );

  test('generic batch keeps from aggregate and cumulative negative-budget errors in one call', () {
    final database = _fixture();
    var calls = 0;
    final operations = <Map<String, Object?>>[
      {'type': 'apply', 'view': database.views.first.toJson()},
      {
        'type': 'aggregate',
        'from': 0,
        'propertyId': _amount,
        'calculation': 'sum',
      },
      {'type': 'value', 'rowId': _first, 'propertyId': _formula},
    ];
    final error = {
      'code': 'budget_exceeded',
      'message': '계산 작업 한도를 넘었습니다.',
      'path': ['$_db/$_first/$_formula'],
    };
    final runtime = DatabaseQueryRuntime(
      invoke: (request) {
        calls++;
        expect(_query(request)['operations'], operations);
        return {
          'encoding': 'utf16-v1',
          'payload': DatabaseQueryCodec.pack({
            'results': [
              {
                'rowIds': [_second, _first],
                'groups': [],
                'errors': [],
              },
              {'value': 51},
              {'value': null, 'error': error},
            ],
            'errors': [error],
            'remainingBudget': -2,
          }),
        };
      },
    );
    final batch = runtime.evaluate(database, operations: operations, budget: 3);
    expect((batch.results[1] as Map)['value'], 51);
    expect(batch.remainingBudget, -2);
    expect(batch.errors.single.code, 'budget_exceeded');
    expect(batch.errors.single.path, ['$_db/$_first/$_formula']);
    expect(
      () => (batch.results[1] as Map)['value'] = 0,
      throwsUnsupportedError,
    );
    expect(() => batch.results.clear(), throwsUnsupportedError);
    expect(calls, 1);
  });

  test('derived query omits long page bodies while retaining raw cell order and UTF16 units', () {
    final raw = _fixture().toJson();
    final longText = ''.padRight(DatabaseQueryCodec.maxCodeUnits + 1, 'x');
    raw['future'] = {'long': longText};
    final first = (raw['rows'] as List).first as Map;
    final values = first['values'] as Map;
    final lone = String.fromCharCodes([0xd800]);
    values[_title] = lone;
    values['future-cell'] = {
      'z': lone,
      'a': ['😀', -0.0],
    };
    first['body'] = {'version': 1, 'blocks': [], 'futureLongPage': longText};
    final database = WorkspaceDatabase.fromJson(raw);
    late Map<String, dynamic> sent;
    final query = DatabaseQueryRuntime(
      invoke: (request) {
        sent = _query(request);
        return _response(request);
      },
    ).project(database, view: database.views.first, valuePropertyIds: [_title]);
    expect(query.errors, isEmpty);
    final snapshot = sent['database'] as Map;
    expect(snapshot.containsKey('future'), false);
    expect(snapshot.containsKey('views'), false);
    final transmitted = (snapshot['rows'] as List).first as Map;
    expect(transmitted.containsKey('body'), false);
    final retained = (transmitted['values'] as Map)['future-cell'] as Map;
    expect(retained.keys, ['z', 'a']);
    expect((retained['z'] as String).codeUnits, [0xd800]);
    expect(((retained['a'] as List)[1] as double).isNegative, true);
    expect(
      (query.value(database.rows.first, _title).value as String).codeUnits,
      [0xd800],
    );
    expect((database.toJson()['future'] as Map)['long'], longText);
    expect(database.rows.first.body['futureLongPage'], longText);
    expect(database.toJson(), raw);
  });

  testWidgets(
    'native failure keeps original table cells editable without calculating in Dart',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final database = _fixture(), original = database.toJson();
      final key = GlobalKey<DatabaseEditorState>();
      WorkspaceDatabase? saved;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DatabaseEditor(
              key: key,
              initialDatabase: database,
              queryRuntime: DatabaseQueryRuntime(
                invoke: (_) => throw const InkVaultNativeException(
                  'unsupported',
                  'synthetic',
                ),
              ),
              autosaveDelay: const Duration(hours: 1),
              onSave: (value) async {
                saved = value;
              },
              onBack: () {},
            ),
          ),
        ),
      );
      expect(find.textContaining('공통 계산을 완료하지 못했습니다'), findsOneWidget);
      expect(find.text('계산 오류'), findsNWidgets(2));
      expect(find.text('첫 행'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('db-cell-$_first-$_amount')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('db-cell-input')), '8');
      await tester.tap(find.widgetWithText(FilledButton, '닫기'));
      await tester.pumpAndSettle();
      expect(key.currentState!.database.rows.first.values[_amount], 8);
      expect(find.text('계산 오류'), findsNWidgets(2));
      expect(find.text('16'), findsNothing);
      await tester.runAsync(key.currentState!.save);
      expect(saved!.rows.first.values[_amount], 8);
      expect(saved!.rows.first.values.containsKey(_formula), false);
      expect(database.toJson(), original);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
