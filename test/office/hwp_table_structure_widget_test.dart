import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/office/hwp_office_engine.dart';
import 'package:saber/data/office/windows_office_engine.dart';
import 'package:saber/pages/office/windows_office_editor.dart';

const _tableId = 's0:p1:t0';
const _button = ValueKey('office-hwpx-edit-structure-$_tableId');
const _cell = ValueKey('office-cell-$_tableId-0,0');
const _action = ValueKey('office-hwpx-structure-action');
const _position = ValueKey('office-hwpx-structure-position');
const _confirm = ValueKey('office-hwpx-structure-confirm');
const _cancel = ValueKey('office-hwpx-structure-cancel');
const _stagedCancel = ValueKey('office-hwpx-cancel-structure-$_tableId');
final _save = find.text('저장하고 닫기');

WindowsOfficeSnapshot _snapshot({bool hasStructure = true}) =>
    WindowsOfficeSnapshot.fromJson({
      'kind': 'word',
      'sourceSha256': 'a' * 64,
      'paragraphs': [],
      'tables': [
        {
          'id': _tableId,
          'cells': {'0,0': '첫 셀', '1,0': '둘째 셀'},
          if (hasStructure)
            'structure': {
              'rows': 2,
              'columns': 1,
              'canInsertRow': true,
              'canDeleteRow': true,
              'canInsertColumn': false,
              'canDeleteColumn': false,
            },
        },
      ],
      'slides': [],
    });

Future<void> _choose(WidgetTester tester, Key field, String label) async {
  await tester.tap(find.byKey(field));
  await tester.pumpAndSettle();
  final choice = find.text(label).last;
  await tester.ensureVisible(choice);
  await tester.tap(choice);
  await tester.pumpAndSettle();
}

void main() {
  test(
    'HWPX table structure rejects malformed operations before file I/O',
    () async {
      final engine = HwpOfficeEngine();
      final valid = WindowsOfficeOperation.hwpTableStructure(
        id: _tableId,
        action: 'insertRow',
        index: 0,
      ).toJson();
      for (final ops in [
        [
          {...valid, 'index': -1},
        ],
        [
          {...valid, 'action': 'unknown'},
        ],
        [
          {...valid, 'id': 's0:p0'},
        ],
        [
          {...valid, 'unexpected': 'extra'},
        ],
        [
          valid,
          WindowsOfficeOperation.tableCellText(_tableId, '0,0', '값').toJson(),
        ],
      ]) {
        await expectLater(
          engine.apply(
            'unopened.hwpx',
            operations: ops,
            sessionId: 'table-structure',
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
      for (final action in ['insertColumn', 'deleteColumn']) {
        await expectLater(
          engine.apply(
            'unopened.hwp',
            operations: [
              {...valid, 'action': action},
            ],
            sessionId: 'table-structure',
            expectedSourceSha256: 'a' * 64,
          ),
          throwsA(
            isA<HwpOfficeException>().having(
              (error) => error.code,
              'code',
              'unsupported_operation',
            ),
          ),
        );
      }
    },
  );

  for (final width in [320.0, 1000.0]) {
    testWidgets('HWPX table structure stages one row insertion at $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final saved = <List<Map<String, Object?>>>[];
      await tester.pumpWidget(
        MaterialApp(
          home: WindowsOfficeEditor(
            snapshot: _snapshot(),
            allowFormatting: false,
            allowHwpTableStructure: true,
            onCommit: (operations) async {
              saved.add(operations.map((op) => op.toJson()).toList());
              if (saved.length == 1) throw StateError('retry');
            },
            onBack: () {},
          ),
        ),
      );
      await tester.tap(find.byKey(_button));
      await tester.pumpAndSettle();
      final actions = tester
          .widget<DropdownButton<HwpTableStructureAction>>(
            find.byWidgetPredicate(
              (widget) => widget is DropdownButton<HwpTableStructureAction>,
            ),
          )
          .items!;
      expect(actions.where((item) => item.enabled).map((item) => item.value), [
        HwpTableStructureAction.insertRow,
        HwpTableStructureAction.deleteRow,
      ]);
      await _choose(tester, _action, '행 추가');
      expect(
        tester
            .widget<DropdownButton<int>>(find.byKey(_position))
            .items!
            .map((item) => item.value),
        [0, 1, 2],
      );
      await _choose(tester, _position, '2행 뒤');
      await tester.tap(find.byKey(_confirm));
      await tester.pumpAndSettle();
      expect(find.text('행 추가 · 2행 뒤'), findsOneWidget);
      expect(tester.widget<TextField>(find.byKey(_cell)).readOnly, isTrue);
      expect(saved, isEmpty);

      await tester.tap(_save);
      await tester.pumpAndSettle();
      expect(find.text('행 추가 · 2행 뒤'), findsOneWidget);
      await tester.tap(find.text('저장 재시도'));
      await tester.pumpAndSettle();
      const operation = {
        'op': 'tableStructure',
        'id': _tableId,
        'action': 'insertRow',
        'index': 2,
      };
      expect(saved, [
        [operation],
        [operation],
      ]);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'HWPX table structure cancels delete and preserves a cell draft',
    (tester) async {
      final saved = <Map<String, Object?>>[];
      await tester.pumpWidget(
        MaterialApp(
          home: WindowsOfficeEditor(
            snapshot: _snapshot(),
            allowFormatting: false,
            allowHwpTableStructure: true,
            onCommit: (operations) async =>
                saved.addAll(operations.map((op) => op.toJson())),
            onBack: () {},
          ),
        ),
      );
      await tester.tap(find.byKey(_button));
      await tester.pumpAndSettle();
      await _choose(tester, _action, '행 삭제');
      await _choose(tester, _position, '1행');
      await tester.tap(find.byKey(_confirm));
      await tester.pumpAndSettle();
      expect(find.text('1행을 삭제할까요?'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('office-hwpx-structure-delete-cancel')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(_stagedCancel), findsNothing);
      await tester.tap(find.byKey(_confirm));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('office-hwpx-structure-delete-confirm')),
      );
      await tester.pumpAndSettle();
      expect(find.text('행 삭제 · 1행'), findsOneWidget);
      await tester.tap(find.byKey(_stagedCancel));
      await tester.pumpAndSettle();
      expect(saved, isEmpty);

      await tester.enterText(find.byKey(_cell), '보존할 셀 변경');
      await tester.tap(find.byKey(_button));
      await tester.pumpAndSettle();
      expect(find.byKey(_cancel), findsNothing);
      expect(find.text('보존할 셀 변경'), findsOneWidget);
      await tester.tap(_save);
      await tester.pumpAndSettle();
      expect(saved, [
        {
          'op': 'tableCellText',
          'tableId': _tableId,
          'cell': '0,0',
          'text': '보존할 셀 변경',
        },
      ]);
    },
  );

  testWidgets('HWPX table structure requires capability and a current source', (
    tester,
  ) async {
    for (final (capability, current) in [(false, true), (true, false)]) {
      await tester.pumpWidget(
        MaterialApp(
          home: WindowsOfficeEditor(
            snapshot: _snapshot(hasStructure: capability),
            allowFormatting: false,
            allowHwpTableStructure: current,
            onCommit: (_) async {},
            onBack: () {},
          ),
        ),
      );
      expect(find.byKey(_button), findsNothing);
      expect(tester.widget<TextField>(find.byKey(_cell)).readOnly, isFalse);
    }
  });
}
