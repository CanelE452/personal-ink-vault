import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/vault/database_query.dart';
import 'package:saber/data/vault/workspace_database.dart';

String _id(int value) =>
    '20000000-0000-4000-8000-${value.toString().padLeft(12, '0')}';

WorkspaceDatabase _formula(String expression) => WorkspaceDatabase.fromJson({
  'schemaVersion': 1,
  'id': _id(1),
  'properties': [
    {
      'id': _id(2),
      'name': 'Formula',
      'type': 'formula',
      'config': {'expression': expression},
    },
  ],
  'rows': [
    {'id': _id(3), 'values': {}},
  ],
  'views': [],
});

void main() {
  for (final (number, places) in [
    (9223372036854775807, 12),
    (123456789012345, 5),
  ]) {
    test(
      'round does not wrap integer multiplication for $number at $places places',
      () {
        final db = _formula('round($number, $places)');
        final result = DatabaseQuery(db).value(db.rows.single, _id(2));
        expect(result.error, isNull);
        expect(result.value, isA<double>());
        expect(
          result.value as double,
          closeTo(number.toDouble(), number.abs() * 1e-14),
        );
      },
    );
  }
  for (final expression in [
    r'"\u+041"',
    r'"\u 041"',
    r'"\u0x41"',
    r'"\u-001"',
  ]) {
    test(
      'Unicode escape requires exactly four hexadecimal digits: $expression',
      () {
        final db = _formula(expression);
        final result = DatabaseQuery(db).value(db.rows.single, _id(2));
        expect(result.error?.code, 'parse_error');
      },
    );
  }
  test('calendar equal start times retain canonical row order across larger groups', () {
    final rows = [
      for (var index = 0; index < 90; index++)
        {
          'id': _id(100 + index),
          'values': {
            _id(2): '2026-10-${(index % 3 + 1).toString().padLeft(2, '0')}',
          },
        },
    ];
    final db = WorkspaceDatabase.fromJson({
      'schemaVersion': 1,
      'id': _id(1),
      'properties': [
        {'id': _id(2), 'name': 'Date', 'type': 'date'},
      ],
      'rows': rows,
      'views': [],
    });
    final result = DatabaseQuery(db).calendar(propertyId: _id(2));
    expect(result.map((item) => item.rowId).toList(), [
      for (var day = 0; day < 3; day++)
        for (var index = day; index < 90; index += 3) _id(100 + index),
    ]);
  });
}
