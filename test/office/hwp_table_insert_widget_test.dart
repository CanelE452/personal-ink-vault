import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/office/hwp_office_engine.dart';
import 'package:saber/data/office/windows_office_engine.dart';
import 'package:saber/pages/office/windows_office_editor.dart';

const _reference = 's0:p0';
const _original = '원본 제목 😀';
const _addTable = ValueKey('office-hwpx-add-table-$_reference');
const _rows = ValueKey('office-hwpx-table-rows');
const _columns = ValueKey('office-hwpx-table-columns');
const _confirm = ValueKey('office-hwpx-table-confirm');
const _cancel = ValueKey('office-hwpx-cancel-table-$_reference');
const _paragraph = ValueKey('office-paragraph-$_reference');
final _save = find.text('저장하고 닫기');

WindowsOfficeSnapshot _snapshot({bool capable = true, bool anchor = true}) =>
    WindowsOfficeSnapshot.fromJson({
      'kind': 'word',
      'sourceSha256': 'a' * 64,
      'supportsHwpTableInsert': capable,
      'paragraphs': [
        {'id': _reference, 'text': _original, 'tableInsertAnchor': anchor},
        {'id': 's0:p1', 'text': '다음 문단'},
      ],
      'tables': [],
      'slides': [],
    });

Future<void> _openTable(WidgetTester tester) async {
  await tester.tap(find.byKey(_addTable));
  await tester.pumpAndSettle();
}

Future<void> _choose(WidgetTester tester, Key field, String value) async {
  await tester.tap(find.byKey(field));
  await tester.pumpAndSettle();
  final option = find.text(value).last;
  await tester.ensureVisible(option);
  await tester.tap(option);
  await tester.pumpAndSettle();
}

void main() {
  test(
    'HWPX rejects malformed supplied cell data before opening the file',
    () async {
      final engine = HwpOfficeEngine();
      final operation = WindowsOfficeOperation.hwpTableInsert(
        id: 'table-draft',
        referenceId: _reference,
        expectedTextSha256: sha256.convert(utf8.encode(_original)).toString(),
        rows: 1,
        columns: 1,
      ).toJson();
      expect(operation.containsKey('cells'), isFalse);
      expect(
        HwpOfficeEngine.isValidTableInsertCells(
          [
            ['😀' * 60],
          ],
          1,
          1,
        ),
        isTrue,
      );
      for (final cells in [
        null,
        [],
        [[]],
        [
          [42],
        ],
        for (final text in [
          '가' * 121,
          '\n',
          '\u007f',
          '\u0085',
          '\u2028',
          '\u2029',
          '\ufffe',
          '\uffff',
          String.fromCharCode(0xd800),
        ])
          [
            [text],
          ],
      ]) {
        await expectLater(
          engine.apply(
            'unopened.hwpx',
            operations: [
              {...operation, 'cells': cells},
            ],
            sessionId: 'table-test',
            expectedSourceSha256: 'a' * 64,
          ),
          throwsA(
            isA<HwpOfficeException>().having(
              (error) => error.code,
              'code',
              'invalid_request',
            ),
          ),
        );
      }
    },
  );

  test('HWPX snapshots nested cell data when making an operation', () {
    final cells = [
      ['  내용  ', ''],
    ];
    final operation = WindowsOfficeOperation.hwpTableInsert(
      id: 'table-draft',
      referenceId: _reference,
      expectedTextSha256: sha256.convert(utf8.encode(_original)).toString(),
      rows: 1,
      columns: 2,
      cells: cells,
    );
    cells.first[0] = '변경';
    cells.add(['', '']);
    expect(operation.toJson()['cells'], [
      ['  내용  ', ''],
    ]);
    final snapshot = operation.toJson()['cells']! as List<List<String>>;
    expect(() => snapshot.first[0] = '변경', throwsUnsupportedError);
    expect(() => snapshot.add(['', '']), throwsUnsupportedError);
  });

  for (final (width, rows, columns) in [(1000.0, 2, 2), (320.0, 8, 6)]) {
    testWidgets('HWPX stages and retries a $rows × $columns table at $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final commits = <List<Map<String, Object?>>>[];
      final dirty = <bool>[];
      var closed = false;
      await tester.pumpWidget(
        MaterialApp(
          home: WindowsOfficeEditor(
            snapshot: _snapshot(),
            allowFormatting: false,
            onDirtyChanged: dirty.add,
            onCommit: (operations) async {
              commits.add(
                operations.map((operation) => operation.toJson()).toList(),
              );
              if (commits.length == 1) throw StateError('transient save');
            },
            onBack: () {
              closed = true;
            },
          ),
        ),
      );
      expect(find.text('표 추가'), findsOneWidget);
      await _openTable(tester);
      if (rows != 2) await _choose(tester, _rows, '$rows');
      if (columns != 2) await _choose(tester, _columns, '$columns');
      await tester.tap(find.byKey(_confirm));
      await tester.pumpAndSettle();

      final pendingLabel = find.text('빈 표 $rows행 × $columns열');
      expect(pendingLabel, findsOneWidget);
      expect(tester.widget<TextField>(find.byKey(_paragraph)).readOnly, isTrue);
      expect(commits, isEmpty);
      expect(dirty, [true]);
      await tester.tap(_save);
      await tester.pumpAndSettle();
      expect(closed, isFalse);
      expect(pendingLabel, findsOneWidget);
      await tester.tap(find.text('저장 재시도'));
      await tester.pumpAndSettle();

      expect(commits, hasLength(2));
      final operation = commits.first.single;
      expect(
        operation['id'],
        isA<String>().having((id) => id.isNotEmpty, 'non-empty', true),
      );
      expect(operation, {
        'op': 'tableInsert',
        'id': operation['id'],
        'referenceId': _reference,
        'position': 'after',
        'expectedTextSha256': sha256.convert(utf8.encode(_original)).toString(),
        'rows': rows,
        'columns': columns,
      });
      expect(commits.last, commits.first);
      expect(dirty, [true, false]);
      expect(closed, isTrue);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('HWPX stages cell text across rows and retries one operation', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final commits = <List<Map<String, Object?>>>[];
    await tester.pumpWidget(
      MaterialApp(
        home: WindowsOfficeEditor(
          snapshot: _snapshot(),
          allowFormatting: false,
          onCommit: (operations) async {
            commits.add(
              operations.map((operation) => operation.toJson()).toList(),
            );
            if (commits.length == 1) throw StateError('transient save');
          },
          onBack: () {},
        ),
      ),
    );
    await _openTable(tester);
    final firstCell = find.byKey(const ValueKey('office-hwpx-table-cell-1-1'));
    final secondRow = find.byKey(const ValueKey('office-hwpx-table-row-2'));
    final secondCell = find.byKey(const ValueKey('office-hwpx-table-cell-2-2'));
    final confirm = find.byKey(_confirm);
    await tester.enterText(firstCell, '${'😀' * 60}x');
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(confirm).onPressed, isNull);

    const firstText = ' 앞 & < > 뒤 ';
    const secondText = '두 번째 행';
    await tester.enterText(firstCell, firstText);
    await tester.tap(secondRow);
    await tester.pumpAndSettle();
    await tester.enterText(secondCell, secondText);
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    expect(find.text('표 2행 × 2열'), findsOneWidget);
    expect(commits, isEmpty);

    await tester.tap(_save);
    await tester.pumpAndSettle();
    await tester.tap(find.text('저장 재시도'));
    await tester.pumpAndSettle();
    expect(commits, hasLength(2));
    expect(commits.last, commits.first);
    expect(commits.first.single, {
      'op': 'tableInsert',
      'id': commits.first.single['id'],
      'referenceId': _reference,
      'position': 'after',
      'expectedTextSha256': sha256.convert(utf8.encode(_original)).toString(),
      'rows': 2,
      'columns': 2,
      'cells': [
        [firstText, ''],
        ['', secondText],
      ],
    });
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'HWPX preserves prior text and cancels a table draft independently',
    (tester) async {
      final commits = <List<Map<String, Object?>>>[];
      final dirty = <bool>[];
      await tester.pumpWidget(
        MaterialApp(
          home: WindowsOfficeEditor(
            snapshot: _snapshot(),
            allowFormatting: false,
            onDirtyChanged: dirty.add,
            onCommit: (operations) async {
              commits.add(
                operations.map((operation) => operation.toJson()).toList(),
              );
            },
            onBack: () {},
          ),
        ),
      );
      await _openTable(tester);
      await tester.tap(find.byKey(_confirm));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(_cancel));
      await tester.pumpAndSettle();
      expect(find.text('빈 표 2행 × 2열'), findsNothing);
      expect(
        tester.widget<TextField>(find.byKey(_paragraph)).readOnly,
        isFalse,
      );
      expect(commits, isEmpty);

      await tester.enterText(find.byKey(_paragraph), '기존 문단 수정');
      await _openTable(tester);
      expect(find.byKey(_confirm), findsNothing);
      expect(find.text('기존 문단 수정'), findsOneWidget);
      expect(find.text('기존 편집을 저장한 뒤 표를 추가하세요.'), findsOneWidget);
      await tester.tap(_save);
      await tester.pumpAndSettle();

      expect(commits, [
        [
          {'op': 'paragraphText', 'id': _reference, 'text': '기존 문단 수정'},
        ],
      ]);
      expect(dirty, [true, false, true, false]);
    },
  );

  testWidgets('HWPX requires snapshot and paragraph table capabilities', (
    tester,
  ) async {
    for (final snapshot in [
      _snapshot(capable: false),
      _snapshot(anchor: false),
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          home: WindowsOfficeEditor(
            snapshot: snapshot,
            allowFormatting: false,
            onCommit: (_) async {},
            onBack: () {},
          ),
        ),
      );
      expect(find.text('표 추가'), findsNothing);
    }
  });
}
