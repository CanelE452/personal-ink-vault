import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/office/docx_table_structure.dart';
import 'package:saber/pages/office/docx_table_structure_dialog.dart';

const _oneCell = DocxTableStructureTable(
  tableIndex: 0,
  rowCount: 1,
  columnCount: 1,
  preview: '한 셀',
);
const _rows = DocxTableStructureTable(
  tableIndex: 2,
  rowCount: 2,
  columnCount: 2,
  preview: '연구 자료',
);
const _open = ValueKey('open-table-structure');
Finder _control(String name) =>
    find.byKey(ValueKey('docx-table-structure-$name'));

DocxTableStructurePlan _plan(List<DocxTableStructureTable> tables) =>
    DocxTableStructurePlan(sourceSha256: 'a' * 64, tables: tables);

Future<void> _openDialog(
  WidgetTester tester,
  DocxTableStructurePlan plan,
  ValueChanged<DocxTableStructureDraft?> onResult,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            key: _open,
            onPressed: () async =>
                onResult(await chooseDocxTableStructure(context, plan)),
            child: const Text('열기'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(_open));
  await tester.pumpAndSettle();
}

Future<void> _choose(WidgetTester tester, String picker, String label) async {
  final field = _control(picker);
  await tester.ensureVisible(field);
  await tester.tap(field);
  await tester.pumpAndSettle();
  final item = find.text(label).last;
  await tester.ensureVisible(item);
  await tester.tap(item);
  await tester.pumpAndSettle();
}

void main() {
  test(
    'DOCX table structure validates axis endpoints and dimension limits',
    () {
      const insertRow = DocxTableStructureAction.insertRow;
      const deleteRow = DocxTableStructureAction.deleteRow;
      const insertColumn = DocxTableStructureAction.insertColumn;
      const deleteColumn = DocxTableStructureAction.deleteColumn;
      expect(_oneCell.allows(deleteRow), isFalse);
      expect(_oneCell.allows(deleteColumn), isFalse);
      expect(_oneCell.allowsPosition(insertRow, 0, anchorIndex: 0), isTrue);
      expect(_oneCell.allowsPosition(insertRow, 1, anchorIndex: 0), isTrue);
      expect(_oneCell.allowsPosition(insertRow, 2, anchorIndex: 0), isFalse);
      expect(_rows.allowsPosition(deleteRow, 1), isTrue);
      expect(_rows.allowsPosition(deleteRow, 2), isFalse);
      expect(_rows.allowsPosition(deleteRow, -1), isFalse);
      const full = DocxTableStructureTable(
        tableIndex: 4,
        rowCount: 16,
        columnCount: 32,
        preview: '',
      );
      expect(full.allows(insertRow), isFalse);
      expect(full.allows(insertColumn), isFalse);
      expect(full.allows(deleteRow), isTrue);
      expect(full.allows(deleteColumn), isTrue);
    },
  );

  test(
    'DOCX table structure rejects invalid draft before native file access',
    () async {
      const engine = DocxTableStructureEngine();
      final source = p.join(
        Directory.systemTemp.absolute.path,
        'unopened.docx',
      );
      final destination = p.join(p.dirname(source), 'edited.docx');
      final plan = _plan(const [_oneCell, _rows]);
      for (final (table, action, index, anchorIndex) in [
        (0, DocxTableStructureAction.deleteColumn, 0, null),
        (1, DocxTableStructureAction.insertRow, 0, 0),
        (2, DocxTableStructureAction.insertColumn, 3, 1),
        (2, DocxTableStructureAction.insertRow, 0, null),
        (2, DocxTableStructureAction.insertRow, 2, 2),
        (2, DocxTableStructureAction.insertColumn, 0, -1),
        (2, DocxTableStructureAction.deleteRow, 0, 0),
      ]) {
        await expectLater(
          engine.edit(
            sourcePath: source,
            plan: plan,
            outputPath: destination,
            tableIndex: table,
            action: action,
            index: index,
            anchorIndex: anchorIndex,
          ),
          throwsArgumentError,
        );
      }
      await expectLater(
        engine.edit(
          sourcePath: source,
          plan: plan,
          outputPath: source,
          tableIndex: 2,
          action: DocxTableStructureAction.insertColumn,
          index: 0,
          anchorIndex: 0,
        ),
        throwsArgumentError,
      );
    },
  );

  testWidgets(
    'compact DOCX table structure selects a column and inserts after it',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final results = <DocxTableStructureDraft?>[];
      await _openDialog(tester, _plan(const [_oneCell, _rows]), results.add);
      await _choose(tester, 'table', '표 3 · 2행×2열 · 연구 자료');
      await _choose(tester, 'action', '열 추가');
      await _choose(tester, 'position', '2열');
      await tester.ensureVisible(_control('after'));
      await tester.tap(_control('after'));
      await tester.pumpAndSettle();
      expect(tester.widget<ChoiceChip>(_control('after')).selected, isTrue);
      await tester.tap(_control('confirm'));
      await tester.pumpAndSettle();
      expect(results, [
        (
          tableIndex: 2,
          action: DocxTableStructureAction.insertColumn,
          index: 2,
          anchorIndex: 1,
        ),
      ]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'DOCX table structure requires confirmation and allows delete cancellation',
    (tester) async {
      final results = <DocxTableStructureDraft?>[];
      await _openDialog(tester, _plan(const [_rows]), results.add);
      await _choose(tester, 'action', '행 삭제');
      await _choose(tester, 'position', '1행');
      expect(_control('before'), findsNothing);
      await tester.tap(_control('confirm'));
      await tester.pumpAndSettle();
      expect(find.text('1행을 삭제할까요?'), findsOneWidget);
      await tester.tap(_control('delete-cancel'));
      await tester.pumpAndSettle();
      expect(results, isEmpty);
      expect(_control('position'), findsOneWidget);
      await tester.tap(_control('confirm'));
      await tester.pumpAndSettle();
      await tester.tap(_control('delete-confirm'));
      await tester.pumpAndSettle();
      expect(results, [
        (
          tableIndex: 2,
          action: DocxTableStructureAction.deleteRow,
          index: 0,
          anchorIndex: null,
        ),
      ]);
    },
  );

  testWidgets(
    'DOCX table structure explains unsupported tables and protects last cells',
    (tester) async {
      final results = <DocxTableStructureDraft?>[];
      await _openDialog(tester, _plan(const []), results.add);
      expect(find.textContaining('행·열을 편집할 수 있는 표가 없습니다.'), findsOneWidget);
      expect(
        tester.widget<FilledButton>(_control('confirm')).onPressed,
        isNull,
      );
      await tester.tap(_control('cancel'));
      await tester.pumpAndSettle();
      expect(results, [null]);

      await _openDialog(tester, _plan(const [_oneCell]), results.add);
      final items = tester
          .widget<DropdownButton<DocxTableStructureAction>>(_control('action'))
          .items!;
      expect(items.where((item) => item.enabled).map((item) => item.value), [
        DocxTableStructureAction.insertRow,
        DocxTableStructureAction.insertColumn,
      ]);
    },
  );
}
