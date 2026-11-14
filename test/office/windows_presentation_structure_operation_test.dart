import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/office/windows_office_engine.dart';

import 'windows_presentation_structure_test.dart';

WindowsOfficeOperation structureOperation({
  Map<String, Object?> changes = const {},
}) {
  final fields = <String, Object?>{
    'authorityVersion': 1,
    'id': 'new-table-fixture',
    'ownerId': 'slide-0',
    'expectedSourceSha256': sourceStructureHash,
    'sourcePart': 'ppt/slides/slide1.xml',
    'expectedSourcePartSha256': sourceStructurePartHash,
    'expectedShapeIdInventorySha256': sourceStructureInventoryHash,
    'xMm': 0.29,
    'yMm': -0.29,
    'columnWidthsMm': <num>[30, 40.01],
    'rowHeightsMm': <num>[12, 12],
    ...changes,
  };
  return Function.apply(
    WindowsOfficeOperation.presentationSourceTableAdd,
    const [],
    {for (final entry in fields.entries) Symbol(entry.key): entry.value},
  ) as WindowsOfficeOperation;
}

void main() {
  test('table creation factory retains exact source guards and finite hundredth values', () {
    expect(structureOperation().toJson(), {
      'op': 'presentationSourceTableAdd',
      'authorityVersion': 1,
      'id': 'new-table-fixture',
      'ownerId': 'slide-0',
      'expectedSourceSha256': sourceStructureHash,
      'sourcePart': 'ppt/slides/slide1.xml',
      'expectedSourcePartSha256': sourceStructurePartHash,
      'expectedShapeIdInventorySha256': sourceStructureInventoryHash,
      'xMm': 0.29,
      'yMm': -0.29,
      'columnWidthsMm': <num>[30, 40.01],
      'rowHeightsMm': <num>[12, 12],
    });
  });

  test('creation operation arrays and serialization cannot mutate the recorded request', () {
    final widths = <num>[0.29, 1.01];
    final heights = <num>[12];
    final operation = structureOperation(
      changes: {'columnWidthsMm': widths, 'rowHeightsMm': heights},
    );
    widths[0] = 88;
    heights[0] = 99;
    final encoded = operation.toJson();
    (encoded['columnWidthsMm'] as List)[0] = 77;
    (encoded['rowHeightsMm'] as List).add(22);
    expect(operation.toJson()['columnWidthsMm'], <num>[0.29, 1.01]);
    expect(operation.toJson()['rowHeightsMm'], <num>[12]);
  });

  test(
    'factory rejects bad aliases owner IDs original guards and package paths',
    () {
      for (final change in <Map<String, Object?>>[
        {'authorityVersion': 2},
        {'id': 'slide-0/shape-1'},
        {'id': 'new-table-'},
        {'id': 'new-table-한글'},
        {'id': 'new-table-${'x' * 65}'},
        {'ownerId': ''},
        {'ownerId': 'x' * 257},
        {'ownerId': 'slide-\u0001'},
        {'expectedSourceSha256': 'A' * 64},
        {'expectedSourcePartSha256': 'bad'},
        {'expectedShapeIdInventorySha256': 'c' * 63},
        {'sourcePart': '../slide.xml'},
        {'sourcePart': r'ppt\slides\slide1.xml'},
      ]) {
        expect(
          () => structureOperation(changes: change),
          throwsFormatException,
          reason: change.toString(),
        );
      }
    },
  );

  test(
    'factory rejects nonfinite non-hundredth and out-of-bounds geometry',
    () {
      for (final key in ['xMm', 'yMm']) {
        for (final value in [
          double.nan,
          double.infinity,
          -double.infinity,
          0.001,
          -1000.01,
          1000.01,
        ]) {
          expect(
            () => structureOperation(changes: {key: value}),
            throwsFormatException,
          );
        }
      }
      for (final key in ['columnWidthsMm', 'rowHeightsMm']) {
        for (final value in <List<num>>[
          [],
          [0],
          [-1],
          [0.001],
          [double.nan],
          [500, 500.01],
        ]) {
          expect(
            () => structureOperation(changes: {key: value}),
            throwsFormatException,
          );
        }
      }
    },
  );

  test('factory accepts exact extent and cell limits while rejecting oversized grids', () {
    final exact = structureOperation(
      changes: {
        'xMm': -1000,
        'yMm': 1000,
        'columnWidthsMm': <num>[0.01, 999.99],
        'rowHeightsMm': <num>[1000],
      },
    );
    expect(exact.toJson()['columnWidthsMm'], <num>[0.01, 999.99]);
    expect(
      structureOperation(
        changes: {
          'columnWidthsMm': List<num>.filled(10, 1),
          'rowHeightsMm': List<num>.filled(10, 1),
        },
      ).toJson()['rowHeightsMm'],
      hasLength(10),
    );
    expect(
      () => structureOperation(
        changes: {
          'columnWidthsMm': List<num>.filled(101, 1),
          'rowHeightsMm': <num>[1],
        },
      ),
      throwsFormatException,
    );
  });
}
