import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/vault/workspace_database.dart';
import 'package:saber/pages/workspace/database_view_filter_editor.dart';

const _titleId = '00000000-0000-4000-8000-000000000001';
const _numberId = '00000000-0000-4000-8000-000000000002';
const _checkboxId = '00000000-0000-4000-8000-000000000003';

WorkspaceDatabase _database() => WorkspaceDatabase.empty().copyWith(
  properties: [
    DatabaseProperty.create(id: _titleId, name: '이름', type: 'title'),
    DatabaseProperty.create(id: _numberId, name: '우선순위', type: 'number'),
    DatabaseProperty.create(id: _checkboxId, name: '완료 여부', type: 'checkbox'),
  ],
);

typedef _Draft = ({Map<String, dynamic>? filter, bool valid});

Future<void> _mount(
  WidgetTester tester,
  Map<String, dynamic>? filter,
  List<_Draft> changes,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topCenter,
          child: SizedBox(
            width: 320,
            child: SingleChildScrollView(
              child: DatabaseViewFilterEditor(
                database: _database(),
                filter: filter,
                onChanged: changes.add,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

Finder _key(String value) => find.byKey(ValueKey(value));

Future<void> _tap(WidgetTester tester, String key) async {
  final target = _key(key);
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Future<void> _pick(WidgetTester tester, String key, String label) async {
  await _tap(tester, key);
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

Future<void> _type(WidgetTester tester, String key, String value) async {
  final target = _key(key);
  await tester.ensureVisible(target);
  await tester.enterText(target, value);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('keeps untouched imported nodes and legacy aliases on edits', (
    tester,
  ) async {
    const future = {
      'propertyId': _titleId,
      'operator': 'futureOperator',
      'value': ['원문', 3],
      'extra': {'mode': 'saved'},
    };
    const known = {
      'property': _numberId,
      'op': 'gte',
      'value': 4,
      'futureFlag': true,
    };
    const other = {
      'propertyId': _checkboxId,
      'operator': 'equals',
      'value': false,
    };
    final changes = <_Draft>[];
    await _mount(tester, {
      'and': [
        future,
        {
          'or': [known, other],
        },
      ],
    }, changes);

    expect(changes, isEmpty);
    expect(_key('database-view-filter-group-mode-root'), findsOneWidget);
    expect(_key('database-view-filter-group-mode-2'), findsOneWidget);
    expect(_key('db-filter-property-1'), findsNothing);
    await _type(tester, 'db-filter-value-3', 'NaN');
    expect(changes.last.valid, isFalse);
    await _type(tester, 'db-filter-value-3', '5.5');
    expect(changes.last.valid, isTrue);
    expect(changes.last.filter, {
      'and': [
        future,
        {
          'or': [
            {...known, 'value': 5.5},
            other,
          ],
        },
      ],
    });
    await _tap(tester, 'database-view-filter-remove-1');
    expect(changes.last.filter?['and'], [
      {
        'or': [
          {...known, 'value': 5.5},
          other,
        ],
      },
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('creates a nested OR group and clears the full filter', (
    tester,
  ) async {
    final changes = <_Draft>[];
    await _mount(tester, null, changes);
    expect(changes, isEmpty);
    await _pick(tester, 'db-filter-property', '이름');
    await _type(tester, 'db-filter-value', '검토');
    expect(changes.last.filter, {
      'propertyId': _titleId,
      'operator': 'equals',
      'value': '검토',
    });

    await _tap(tester, 'database-view-filter-add-group');
    expect(changes.last.valid, isFalse);
    final nestedMode = find.byWidgetPredicate((widget) {
      final key = widget.key;
      return key is ValueKey<String> &&
          key.value.startsWith('database-view-filter-group-mode-') &&
          key.value != 'database-view-filter-group-mode-root';
    });
    expect(nestedMode, findsOneWidget);
    final nestedKey =
        (tester.widget(nestedMode).key! as ValueKey<String>).value;
    await _pick(tester, nestedKey, '하나 이상 일치 (OR)');

    final nestedLeaf = find.byWidgetPredicate((widget) {
      final key = widget.key;
      return key is ValueKey<String> &&
          key.value.startsWith('db-filter-property-') &&
          key.value != 'db-filter-property-0';
    });
    expect(nestedLeaf, findsOneWidget);
    final propertyKey =
        (tester.widget(nestedLeaf).key! as ValueKey<String>).value;
    final id = propertyKey.split('-').last;
    await _pick(tester, propertyKey, '완료 여부');
    await _type(tester, 'db-filter-value-$id', 'maybe');
    expect(changes.last.valid, isFalse);
    await _type(tester, 'db-filter-value-$id', 'false');
    expect(changes.last.valid, isTrue);
    expect(changes.last.filter, {
      'and': [
        {'propertyId': _titleId, 'operator': 'equals', 'value': '검토'},
        {
          'or': [
            {'propertyId': _checkboxId, 'operator': 'equals', 'value': false},
          ],
        },
      ],
    });
    await _tap(tester, 'database-view-filter-clear');
    expect(changes.last, (filter: null, valid: true));
    expect(_key('db-filter-property'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
