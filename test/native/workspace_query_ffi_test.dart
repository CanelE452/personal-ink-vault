import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/native/ink_vault_native.dart';

Map<String, Object?> packQueryValue(Object? value) {
  final nodes = <Object?>[];
  int add(Object? item) {
    final Object? node;
    if (item is String) {
      node = ['s', item.codeUnits];
    } else if (item is List) {
      node = [
        'a',
        [for (final child in item) add(child)],
      ];
    } else if (item is Map) {
      node = [
        'o',
        [
          for (final entry in item.entries)
            [(entry.key as String).codeUnits, add(entry.value)],
        ],
      ];
    } else {
      node = item;
    }
    nodes.add(node);
    return nodes.length - 1;
  }

  final root = add(value);
  return {'root': root, 'nodes': nodes};
}

Object? unpackQueryValue(Map<String, dynamic> packed) {
  final values = <Object?>[];
  for (final node in packed['nodes'] as List) {
    if (node is! List) {
      values.add(node);
      continue;
    }
    values.add(switch (node[0]) {
      's' => String.fromCharCodes(List<int>.from(node[1] as List)),
      'a' => [for (final id in node[1] as List) values[id as int]],
      'o' => {
        for (final pair in node[1] as List)
          String.fromCharCodes(List<int>.from(pair[0] as List)):
              values[pair[1] as int],
      },
      _ => throw const FormatException('Unexpected fixture node'),
    });
  }
  return values[packed['root'] as int];
}

Object? observe(Object? value, {bool raw = false, bool top = true}) {
  if (value is num) {
    return [if (value is int) 'int' else 'double', value, value.isNegative];
  }
  if (value is String) return ['utf16', value.codeUnits];
  if (value is List) {
    return [for (final child in value) observe(child, raw: raw, top: false)];
  }
  if (value is Map) {
    final keys = value.keys
        .cast<String>()
        .where((key) => !top || key != 'remainingBudget')
        .toList();
    if (!raw) keys.sort();
    return [
      for (final key in keys)
        [
          key.codeUnits,
          observe(value[key], raw: raw || key == 'value', top: false),
        ],
    ];
  }
  return value;
}

void main() {
  final path =
      Platform.environment['INK_VAULT_NATIVE_LIBRARY'] ??
      File('build/native/windows/ink_vault_native.dll').absolute.path;
  final available = Platform.isWindows && File(path).existsSync();
  final reason = !available
      ? 'Build the actual Windows native library first'
      : false;
  test('actual native query evaluates a lazy formula with Dart negative remainder semantics', () {
    const databaseId = '00000000-0000-4000-8000-000000000001';
    const propertyId = '00000000-0000-4000-8000-000000000002';
    const rowId = '00000000-0000-4000-8000-000000000003';
    final result = InkVaultNative.open(libraryPath: path).invoke({
      'op': 'workspace_query',
      'schemaVersion': 1,
      'encoding': 'utf16-v1',
      'payload': packQueryValue({
        'op': 'workspace_query',
        'schemaVersion': 1,
        'database': {
          'schemaVersion': 1,
          'id': databaseId,
          'properties': [
            {
              'id': propertyId,
              'name': '계산',
              'type': 'formula',
              'config': {
                'expression': 'if(true, sum([1,2,3]) + (-7 % 4), 1 / 0)',
              },
            },
          ],
          'rows': [
            {
              'id': rowId,
              'values': {},
              'archived': false,
              'body': {'version': 1, 'blocks': []},
            },
          ],
          'views': [],
        },
        'databases': [],
        'operations': [
          {'type': 'value', 'rowId': rowId, 'propertyId': propertyId},
        ],
      }),
    });
    expect(result['encoding'], 'utf16-v1');
    final decoded = unpackQueryValue(
      Map<String, dynamic>.from(result['payload'] as Map),
    ) as Map;
    expect((decoded['results'] as List).single, {'value': 7});
    expect(decoded['errors'], isEmpty);
  }, skip: reason);
  test('actual DLL agrees with every shared Dart query oracle', () {
    final native = InkVaultNative.open(libraryPath: path);
    final fixture = jsonDecode(
      File(
        'packages/ink_vault_native/tests/fixtures/workspace_query_vectors.json',
      ).readAsStringSync(),
    ) as Map;
    final cases = fixture['cases'] as List;
    expect(cases.length, greaterThanOrEqualTo(125));
    for (final item in cases.cast<Map>()) {
      final response = native.invoke(
        Map<String, Object?>.from(item['request'] as Map),
      );
      final actual = unpackQueryValue(
        Map<String, dynamic>.from(response['payload'] as Map),
      );
      final expected = unpackQueryValue(
        Map<String, dynamic>.from(item['expected'] as Map),
      );
      expect(
        observe(actual),
        observe(expected),
        reason: item['name'] as String,
      );
    }
  }, skip: reason);
  test(
    'actual DLL casing matches the pinned Dart VM for every Unicode scalar',
    () {
      final native = InkVaultNative.open(libraryPath: path);
      const db = '30000000-0000-4000-8000-000000000001';
      const row = '30000000-0000-4000-8000-000000000002';
      const text = '30000000-0000-4000-8000-000000000003';
      const lower = '30000000-0000-4000-8000-000000000004';
      const upper = '30000000-0000-4000-8000-000000000005';
      var checked = 0;
      for (var start = 0; start <= 0x10ffff; start += 4096) {
        final scalars = [
          for (
            var scalar = start;
            scalar < start + 4096 && scalar <= 0x10ffff;
            scalar++
          )
            if (scalar < 0xd800 || scalar > 0xdfff) scalar,
        ];
        final input = String.fromCharCodes(scalars);
        final logical = <String, Object?>{
          'op': 'workspace_query',
          'schemaVersion': 1,
          'database': {
            'schemaVersion': 1,
            'id': db,
            'properties': [
              {'id': text, 'name': 'Text', 'type': 'text', 'config': {}},
              {
                'id': lower,
                'name': 'Lower',
                'type': 'formula',
                'config': {'expression': 'lower(prop("Text"))'},
              },
              {
                'id': upper,
                'name': 'Upper',
                'type': 'formula',
                'config': {'expression': 'upper(prop("Text"))'},
              },
            ],
            'rows': [
              {
                'id': row,
                'values': {text: input},
                'archived': false,
              },
            ],
          },
          'operations': [
            {'type': 'value', 'rowId': row, 'propertyId': lower},
            {'type': 'value', 'rowId': row, 'propertyId': upper},
          ],
        };
        final response = native.invoke({
          'op': 'workspace_query',
          'schemaVersion': 1,
          'encoding': 'utf16-v1',
          'payload': packQueryValue(logical),
        });
        final result = unpackQueryValue(
          Map<String, dynamic>.from(response['payload'] as Map),
        ) as Map;
        expect(
          result['errors'],
          isEmpty,
          reason: 'Scalar chunk beginning at $start',
        );
        final values = result['results'] as List;
        expect(
          (values[0] as Map)['value'],
          input.toLowerCase(),
          reason: 'lower chunk $start',
        );
        expect(
          (values[1] as Map)['value'],
          input.toUpperCase(),
          reason: 'upper chunk $start',
        );
        checked += scalars.length;
      }
      expect(checked, 1112064);
    },
    skip: reason,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
