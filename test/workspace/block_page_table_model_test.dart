import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/vault/block_page_document.dart';
import 'package:saber/data/vault/block_page_table.dart';

Map<String, dynamic> tablePage() => {
  'version': 1,
  'blocks': [
    {
      'id': newId(),
      'type': 'table',
      'text': '연구 비교',
      'tableData': {
        'format': 'personal-ink-table-1',
        'columns': [newId(), newId()],
        'rows': [
          {
            'id': newId(),
            'cells': [
              <String, dynamic>{'id': newId(), 'text': '모델 A'},
              <String, dynamic>{'id': newId(), 'text': '한글 😀'},
            ],
          },
          {
            'id': newId(),
            'cells': [
              <String, dynamic>{'id': newId(), 'text': '두 줄\n다음 | 항목'},
              <String, dynamic>{
                'id': newId(),
                'text': '<script>unsafe</script>',
              },
            ],
          },
        ],
        'headerRow': false,
        'headerColumn': false,
      },
    },
  ],
};

Map<String, dynamic> dataOf(Map<String, dynamic> page) =>
    ((page['blocks'] as List).single as Map<String, dynamic>)['tableData']
        as Map<String, dynamic>;

void main() {
  test('known table marker rejects nonrectangular rows before publication', () {
    final page = tablePage();
    final data = dataOf(page);
    (((data['rows'] as List).last as Map)['cells'] as List).removeLast();
    expect(() => BlockPageDocument.fromJson(page), throwsFormatException);
  });

  test(
    'known table marker rejects duplicate row cell and column identities',
    () {
      for (final kind in ['row', 'cell', 'column', 'cross-kind']) {
        final page = tablePage(), data = dataOf(page);
        final columns = data['columns'] as List;
        final rows = data['rows'] as List;
        final first = rows.first as Map, last = rows.last as Map;
        final firstCell = (first['cells'] as List).first as Map;
        switch (kind) {
          case 'row':
            last['id'] = first['id'];
          case 'cell':
            ((last['cells'] as List).last as Map)['id'] = firstCell['id'];
          case 'column':
            columns[1] = columns.first;
          case 'cross-kind':
            firstCell['id'] = columns.first;
        }
        expect(
          () => BlockPageDocument.fromJson(page),
          throwsFormatException,
          reason: 'Duplicated $kind identity must not name an editable target',
        );
      }
    },
  );

  test(
    'known table projects every real row and safely escapes Markdown cells',
    () {
      final page = BlockPageDocument.fromJson(tablePage());
      final text = page.toMarkdown();
      expect(text, contains('연구 비교'));
      expect(text, contains('모델 A'));
      expect(text, contains('한글 😀'));
      expect(text, contains(r'두 줄<br>다음 \| 항목'));
      expect(text, contains('&lt;script&gt;unsafe&lt;/script&gt;'));
      expect(text, isNot(contains('<script>')));
      expect(text.split('\n').where((line) => line.startsWith('|')).length, 4);
    },
  );

  test(
    'opaque old and future tables survive an unrelated page edit unchanged',
    () {
      for (final opaque in [
        {
          'rows': ['legacy'],
          'foreign': {'preserve': true},
        },
        {
          'format': 'future-table-9',
          'rows': ['future'],
        },
      ]) {
        final raw = tablePage();
        final block = (raw['blocks'] as List).single as Map<String, dynamic>;
        block['tableData'] = opaque;
        block['unknown'] = {
          'keep': [1, 2],
        };
        final document = BlockPageDocument.fromJson(raw);
        final changed = document.copyWith(
          blocks: [
            document.blocks.single,
            BlockPageBlock.create(text: '별도 문단'),
          ],
        );
        expect((changed.toJson()['blocks'] as List).first, block);
        expect(
          BlockPageDocument.fromJson(jsonDecode(jsonEncode(changed.toJson())))
              .toJson(),
          changed.toJson(),
        );
        expect(changed.toMarkdown(), contains('연구 비교'));
        expect(changed.toMarkdown(), isNot(contains('|')));
      }
    },
  );
  test(
    'table edits preserve stable targets metadata and detached snapshots',
    () {
      final source = dataOf(tablePage());
      source['futureTable'] = {
        'keep': [1, 2],
      };
      final firstRow = (source['rows'] as List).first as Map;
      firstRow['futureRow'] = {'height': 3};
      final firstCell = (firstRow['cells'] as List).first as Map;
      firstCell['futureCell'] = {'color': 'retain'};
      final table = BlockPageTable.fromJson(source);
      final rowId = table.rows.first.id, columnId = table.columns.first;
      var changed = table.setCellText(rowId, columnId, '수정 😀');
      changed = changed.insertRow(index: 0).insertColumn(index: 1);
      final insertedRow = changed.rows.first.id;
      final insertedColumn = changed.columns[1];
      changed = changed.removeRow(insertedRow).removeColumn(insertedColumn);
      final expected = jsonDecode(jsonEncode(source)) as Map<String, dynamic>;
      ((((expected['rows'] as List).first as Map)['cells'] as List).first
              as Map)['text'] =
          '수정 😀';
      expect(changed.toJson(), expected);
      expect(table.rows.first.cells.first.text, '모델 A');
      expect(changed.rows.first.id, rowId);
      expect(changed.columns.first, columnId);
      expect(
        changed.rows.first.cells.first.id,
        table.rows.first.cells.first.id,
      );
      final output = changed.toJson();
      (output['futureTable'] as Map)['keep'].clear();
      expect(changed.toJson()['futureTable'], {
        'keep': [1, 2],
      });
      expect(() => changed.columns.add(newId()), throwsUnsupportedError);
      expect(() => changed.rows.clear(), throwsUnsupportedError);
      expect(() => changed.rows.first.cells.clear(), throwsUnsupportedError);
    },
  );

  test(
    'table creation and updates keep the block caption children and identity',
    () {
      final child = BlockPageBlock.create(text: '관련 설명');
      final block = BlockPageBlock.createTable(text: '표 제목')
          .copyWith(children: [child]);
      expect(block.type, 'table');
      expect(block.table!.rowCount, 2);
      expect(block.table!.columnCount, 2);
      expect(identical(block.table, block.table), isTrue);
      final table = block.table!;
      final edited = block.copyWith(
        table: table.setCellText(
          table.rows.last.id,
          table.columns.last,
          '실제 값',
        ),
      );
      expect(edited.id, block.id);
      expect(edited.text, '표 제목');
      expect(edited.children.single.id, child.id);
      expect(edited.table!.rows.last.cells.last.text, '실제 값');
      final reloaded = BlockPageBlock.fromJson(
        jsonDecode(jsonEncode(edited.toJson())),
      );
      expect(reloaded.toJson(), edited.toJson());
      final document = const BlockPageDocument.empty().copyWith(
        blocks: [reloaded],
      );
      expect(document.toMarkdown(), contains('표 제목'));
      expect(document.toMarkdown(), contains('실제 값'));
      expect(document.toMarkdown(), contains('관련 설명'));
      final paragraph = edited.copyWith(
        type: 'paragraph',
        text: table.toPlainText(),
      );
      expect(paragraph.table, isNull);
      expect(paragraph.toJson()['tableData'], edited.toJson()['tableData']);
    },
  );

  test(
    'header flags preserve the first actual row and every cell in Markdown',
    () {
      final table = BlockPageTable.fromJson(dataOf(tablePage()));
      final header = table.copyWith(headerRow: true, headerColumn: true);
      expect(header.headerRow, isTrue);
      expect(header.headerColumn, isTrue);
      expect(table.headerRow, isFalse);
      expect(header.toMarkdown().split('\n').length, 3);
      expect(table.toMarkdown().split('\n').length, 4);
      expect(header.toMarkdown(), startsWith('| 모델 A | 한글 😀 |'));
      expect(header.toMarkdown(), contains(r'두 줄<br>다음 \| 항목'));
      expect(
        header.toPlainText(),
        '모델 A\t한글 😀\n두 줄\n다음 | 항목\t<script>unsafe</script>',
      );
    },
  );

  test('row and column limits retain at least one cell and reject stale identities', () {
    final one = BlockPageTable.create(rows: 1, columns: 1);
    expect(() => one.removeRow(one.rows.single.id), throwsFormatException);
    expect(() => one.removeColumn(one.columns.single), throwsFormatException);
    expect(
      () => one.setCellText(newId(), one.columns.single, ''),
      throwsArgumentError,
    );
    expect(
      () => one.setCellText(one.rows.single.id, newId(), ''),
      throwsArgumentError,
    );
    expect(() => one.insertRow(index: -1), throwsRangeError);
    expect(() => one.insertColumn(index: 2), throwsRangeError);
    expect(() => BlockPageTable.create(rows: 0), throwsFormatException);
    expect(() => BlockPageTable.create(rows: 129), throwsFormatException);
    expect(() => BlockPageTable.create(columns: 33), throwsFormatException);
    final manyRows = BlockPageTable.create(rows: 128, columns: 1);
    final manyColumns = BlockPageTable.create(rows: 1, columns: 32);
    expect(() => manyRows.insertRow(), throwsFormatException);
    expect(() => manyColumns.insertColumn(), throwsFormatException);
  });

  test(
    'declared table schema enforces scalar flags text size and UTF8 budget',
    () {
      for (final field in ['headerRow', 'headerColumn']) {
        final data = dataOf(tablePage());
        data[field] = 'false';
        expect(() => BlockPageTable.fromJson(data), throwsFormatException);
      }
      final table = BlockPageTable.create(rows: 1, columns: 1);
      expect(
        () => table.setCellText(
          table.rows.single.id,
          table.columns.single,
          'x' * 16385,
        ),
        throwsFormatException,
      );
      final data = BlockPageTable.create(rows: 3, columns: 8).toJson();
      for (final row in data['rows'] as List) {
        for (final cell in (row as Map)['cells'] as List) {
          (cell as Map)['text'] = '한' * 16384;
        }
      }
      expect(() => BlockPageTable.fromJson(data), throwsFormatException);
      final raw = tablePage();
      dataOf(raw)['columns'] = ['../../foreign'];
      expect(() => BlockPageDocument.fromJson(raw), throwsFormatException);
    },
  );
}
