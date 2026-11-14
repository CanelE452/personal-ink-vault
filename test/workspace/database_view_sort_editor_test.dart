import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/vault/workspace_database.dart';
import 'package:saber/pages/workspace/database_view_sort_editor.dart';

const _titleId = '00000000-0000-4000-8000-000000000001';
const _hoursId = '00000000-0000-4000-8000-000000000002';
const _dateId = '00000000-0000-4000-8000-000000000003';

WorkspaceDatabase _database() => WorkspaceDatabase.empty().copyWith(
  properties: [
    DatabaseProperty.create(id: _titleId, name: '이름', type: 'title'),
    DatabaseProperty.create(id: _hoursId, name: '시간', type: 'number'),
    DatabaseProperty.create(id: _dateId, name: '일정', type: 'date'),
  ],
);

Finder _sort(String suffix) =>
    find.byKey(ValueKey('database-view-sort-$suffix'));

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<ValueNotifier<List<Map<String, Object?>>>> _mount(
  WidgetTester tester,
  WorkspaceDatabase database,
  List<Map<String, Object?>> initial,
) async {
  final sort = ValueNotifier(initial);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    sort.dispose();
  });
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ValueListenableBuilder(
            valueListenable: sort,
            builder: (context, value, child) => DatabaseViewSortEditor(
              database: database,
              sort: value,
              onChanged: (next) => sort.value = next,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return sort;
}

void main() {
  testWidgets('adds, edits, reorders and removes ordered criteria', (
    tester,
  ) async {
    final sort = await _mount(tester, _database(), []);

    await _tap(tester, _sort('add'));
    await _tap(tester, _sort('add'));
    expect(sort.value, [
      {'propertyId': _titleId, 'direction': 'ascending'},
      {'propertyId': _hoursId, 'direction': 'ascending'},
    ]);

    await _tap(tester, _sort('direction-1'));
    await _tap(tester, find.text('내림차순').last);
    await _tap(tester, _sort('up-1'));
    expect(sort.value, [
      {'propertyId': _hoursId, 'direction': 'descending'},
      {'propertyId': _titleId, 'direction': 'ascending'},
    ]);

    await _tap(tester, _sort('property-1'));
    await _tap(tester, find.text('일정').last);
    await _tap(tester, _sort('down-0'));
    await _tap(tester, _sort('remove-1'));
    expect(sort.value, [
      {'propertyId': _dateId, 'direction': 'ascending'},
    ]);
  });

  testWidgets('keeps legacy and opaque criteria until explicitly edited', (
    tester,
  ) async {
    const legacy = <String, Object?>{
      'property': _hoursId,
      'direction': 'desc',
      'unknown': {'keep': true},
    };
    const opaque = <String, Object?>{
      'propertyId': _titleId,
      'direction': 'future-order',
      'unknown': [1, 2],
    };
    final initial = [legacy, opaque];
    final sort = await _mount(tester, _database(), initial);
    expect(sort.value, same(initial));
    expect(find.text('지원하지 않는 정렬 기준'), findsOneWidget);

    await _tap(tester, _sort('up-1'));
    expect(sort.value, [opaque, legacy]);
    expect(sort.value.first, same(opaque));
    expect(sort.value.last, same(legacy));

    await _tap(tester, _sort('direction-1'));
    await _tap(tester, find.text('오름차순').last);
    expect(sort.value, [
      opaque,
      {...legacy, 'direction': 'ascending'},
    ]);

    await _tap(tester, _sort('remove-0'));
    expect(sort.value, [
      {...legacy, 'direction': 'ascending'},
    ]);
  });

  testWidgets('disables adding when every property already has a criterion', (
    tester,
  ) async {
    final database = _database();
    final sort = await _mount(tester, database, [
      for (final property in database.properties) {'propertyId': property.id},
    ]);
    expect(tester.widget<OutlinedButton>(_sort('add')).onPressed, isNull);
    await _tap(tester, _sort('remove-1'));
    expect(tester.widget<OutlinedButton>(_sort('add')).onPressed, isNotNull);
    await _tap(tester, _sort('add'));
    expect(sort.value.last, {'propertyId': _hoursId, 'direction': 'ascending'});
  });
}
