import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/vault/block_page_document.dart';
import 'package:saber/data/vault/block_page_table.dart';
import 'package:saber/pages/workspace/block_page_editor.dart';
import 'package:saber/pages/workspace/block_table_editor.dart';

void main() {
  Future<GlobalKey<BlockPageEditorState>> mount(
    WidgetTester tester, {
    BlockPageDocument initial = const BlockPageDocument.empty(),
    Future<void> Function(BlockPageDocument)? save,
  }) async {
    final key = GlobalKey<BlockPageEditorState>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BlockPageEditor(
            key: key,
            initialDocument: initial,
            onSave: save ?? (_) async {},
            onBack: () {},
            autosaveDelay: const Duration(hours: 1),
          ),
        ),
      ),
    );
    return key;
  }

  Future<void> addTable(WidgetTester tester) async {
    await tester.tap(find.byTooltip('블록 추가'));
    await tester.pumpAndSettle();
    expect(find.text('표'), findsOneWidget);
    await tester.tap(find.text('표'));
    await tester.pumpAndSettle();
  }

  BlockPageTable table(GlobalKey<BlockPageEditorState> key) =>
      key.currentState!.document.blocks.single.table!;

  Finder cell(String blockId, String cellId) =>
      find.byKey(ValueKey('block-table-cell-$blockId-$cellId'));

  Finder menuItem(String label) => find.byWidgetPredicate(
    (widget) =>
        widget is PopupMenuItem<Object?> &&
        widget.child is Text &&
        (widget.child as Text).data == label,
  );

  Future<void> chooseAction(
    WidgetTester tester,
    String key,
    String action,
  ) async {
    await tester.ensureVisible(find.byKey(ValueKey(key)));
    await tester.tap(find.byKey(ValueKey(key)));
    await tester.pumpAndSettle();
    await tester.tap(find.text(action).last);
    await tester.pumpAndSettle();
  }

  Future<void> changeType(WidgetTester tester, String id, String label) async {
    await chooseAction(tester, 'block-actions-$id', '종류 바꾸기');
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  testWidgets('add menu creates a real editable two by two table', (
    tester,
  ) async {
    final key = await mount(tester);
    await addTable(tester);
    final block = key.currentState!.document.blocks.single;
    expect(block.type, 'table');
    final data = block.toJson()['tableData'] as Map;
    expect(data['format'], 'personal-ink-table-1');
    expect(data['columns'], hasLength(2));
    expect(data['rows'], hasLength(2));
    expect(find.byType(TextField), findsNWidgets(5));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'Unicode cells row column deletion undo and reloading preserve identities',
    (tester) async {
      BlockPageDocument? saved;
      final key = await mount(tester, save: (doc) async => saved = doc);
      await addTable(tester);
      final id = key.currentState!.document.blocks.single.id;
      final original = table(key);
      final first = original.rows.first.cells.first.id;
      await tester.enterText(cell(id, first), '연구 | 한글😀\n둘째 줄');
      await tester.pump();
      await tester.tap(find.byKey(ValueKey('block-table-add-row-$id')));
      await tester.pump();
      await tester.tap(find.byKey(ValueKey('block-table-add-column-$id')));
      await tester.pump();
      final added = table(key);
      final addedRow = added.rows.last.id;
      final addedColumn = added.columns.last;
      final lastCell = added.rows.last.cells.last.id;
      await tester.ensureVisible(cell(id, lastCell));
      await tester.enterText(cell(id, lastCell), '새 셀 🖊️');
      await tester.pump();
      await chooseAction(
        tester,
        'block-table-row-$id-${original.rows.last.id}',
        '행 삭제',
      );
      await chooseAction(
        tester,
        'block-table-column-$id-${original.columns.last}',
        '열 삭제',
      );
      expect(table(key).rowCount, 2);
      expect(table(key).columnCount, 2);
      expect(table(key).rows.last.id, addedRow);
      expect(table(key).columns.last, addedColumn);
      expect(table(key).rows.last.cells.last.id, lastCell);
      expect(table(key).rows.last.cells.last.text, '새 셀 🖊️');
      await tester.tap(find.byTooltip('실행 취소'));
      await tester.pump();
      expect(table(key).columnCount, 3);
      await tester.tap(find.byTooltip('다시 실행'));
      await tester.pump();
      expect(table(key).columnCount, 2);
      await key.currentState!.save();
      await tester.pump();
      final persisted =
          jsonDecode(jsonEncode(saved!.toJson())) as Map<String, dynamic>;
      await tester.pumpWidget(const SizedBox());
      final reopened = await mount(
        tester,
        initial: BlockPageDocument.fromJson(persisted),
      );
      expect(table(reopened).rows.first.cells.first.id, first);
      expect(table(reopened).rows.first.cells.first.text, '연구 | 한글😀\n둘째 줄');
      expect(table(reopened).rows.last.cells.last.id, lastCell);
      expect(table(reopened).rows.last.cells.last.text, '새 셀 🖊️');
      expect(
        tester.widget<TextField>(cell(id, first)).controller!.text,
        '연구 | 한글😀\n둘째 줄',
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'multiple input events before a frame use the latest immutable draft',
    (tester) async {
      final key = await mount(tester);
      await addTable(tester);
      final id = key.currentState!.document.blocks.single.id;
      final first = table(key).rows.first.cells.first.id;
      final field = tester.widget<TextField>(cell(id, first));
      field.controller!.text = '입력1';
      field.onChanged!('입력1');
      field.controller!.text = '입력12😀';
      field.onChanged!('입력12😀');
      expect(table(key).rows.first.cells.first.text, '입력12😀');
      await tester.pump();
      expect(
        tester.widget<TextField>(cell(id, first)).controller!.text,
        '입력12😀',
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('headers toggle persist and undo without moving cell text', (
    tester,
  ) async {
    final key = await mount(tester);
    await addTable(tester);
    final id = key.currentState!.document.blocks.single.id;
    final first = table(key).rows.first.cells.first.id;
    await tester.enterText(cell(id, first), '제목😀');
    await tester.pump();
    await tester.tap(find.byKey(ValueKey('block-table-header-row-$id')));
    await tester.pump();
    await tester.tap(find.byKey(ValueKey('block-table-header-column-$id')));
    await tester.pump();
    expect(table(key).headerRow, isTrue);
    expect(table(key).headerColumn, isTrue);
    expect(
      tester.widget<TextField>(cell(id, first)).style!.fontWeight,
      FontWeight.w600,
    );
    await tester.tap(find.byTooltip('실행 취소'));
    await tester.pump();
    expect(table(key).headerRow, isTrue);
    expect(table(key).headerColumn, isFalse);
    expect(table(key).rows.first.cells.first.text, '제목😀');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('type conversion retains caption cells and raw table payload', (
    tester,
  ) async {
    final paragraph = BlockPageBlock.create(text: '원래 설명');
    final key = await mount(
      tester,
      initial: const BlockPageDocument.empty().copyWith(blocks: [paragraph]),
    );
    await changeType(tester, paragraph.id, '표');
    expect(key.currentState!.document.blocks.single.id, paragraph.id);
    expect(key.currentState!.document.blocks.single.text, '원래 설명');
    final first = table(key).rows.first.cells.first.id;
    await tester.enterText(cell(paragraph.id, first), '보관할 셀😀');
    await tester.pump();
    final payload = table(key).toJson();
    await changeType(tester, paragraph.id, '문단');
    final converted = key.currentState!.document.blocks.single;
    expect(converted.type, 'paragraph');
    expect(converted.text, contains('원래 설명'));
    expect(converted.text, contains('보관할 셀😀'));
    expect(converted.toJson()['tableData'], payload);
    expect(converted.table, isNull);
    await tester.tap(find.byTooltip('실행 취소'));
    await tester.pump();
    expect(table(key).toJson(), payload);
    expect(
      tester.widget<TextField>(cell(paragraph.id, first)).controller!.text,
      '보관할 셀😀',
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'unknown table payload remains opaque through unrelated editing',
    (tester) async {
      final legacy = BlockPageBlock.create(type: 'table');
      final legacyRaw = {
        ...legacy.toJson(),
        'tableData': {
          'format': 'future-99',
          'cells': [
            ['원본😀'],
          ],
          'opaque': true,
        },
      };
      final paragraph = BlockPageBlock.create(text: '별도 문단');
      final key = await mount(
        tester,
        initial: const BlockPageDocument.empty().copyWith(
          blocks: [BlockPageBlock.fromJson(legacyRaw), paragraph],
        ),
      );
      expect(find.byType(BlockTableEditor), findsNothing);
      expect(find.text('지원하지 않는 블록 · 원본 보관됨'), findsOneWidget);
      await tester.enterText(
        find.byKey(ValueKey('block-text-${paragraph.id}')),
        '수정한 문단',
      );
      await tester.pump();
      expect(key.currentState!.document.blocks.first.toJson(), legacyRaw);
      await chooseAction(tester, 'block-actions-${legacy.id}', '종류 바꾸기');
      final tableTile = tester.widget<ListTile>(
        find.widgetWithText(ListTile, '표'),
      );
      expect(tableTile.enabled, isFalse);
      await tester.tap(find.text('문단').last);
      await tester.pumpAndSettle();
      expect(
        key.currentState!.document.blocks.first.toJson()['tableData'],
        legacyRaw['tableData'],
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'an opaque payload on a paragraph is not overwritten by table conversion',
    (tester) async {
      final paragraph = BlockPageBlock.create(text: '본문');
      final original = {
        ...paragraph.toJson(),
        'tableData': {
          'format': 'someone-else',
          'rows': ['유지'],
        },
      };
      final key = await mount(
        tester,
        initial: const BlockPageDocument.empty().copyWith(
          blocks: [BlockPageBlock.fromJson(original)],
        ),
      );
      await chooseAction(tester, 'block-actions-${paragraph.id}', '종류 바꾸기');
      expect(
        tester.widget<ListTile>(find.widgetWithText(ListTile, '표')).enabled,
        isFalse,
      );
      Navigator.of(tester.element(find.text('표'))).pop();
      await tester.pumpAndSettle();
      expect(key.currentState!.document.blocks.single.toJson(), original);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('failed save retries the same table draft and cell identities', (
    tester,
  ) async {
    var attempts = 0;
    BlockPageDocument? saved;
    final key = await mount(
      tester,
      save: (doc) async {
        if (++attempts == 1) throw StateError('disk unavailable');
        saved = doc;
      },
    );
    await addTable(tester);
    final block = key.currentState!.document.blocks.single;
    final first = table(key).rows.first.cells.first.id;
    await tester.enterText(cell(block.id, first), '실패해도 보관😀');
    await tester.pump();
    final draft = table(key).toJson();
    await expectLater(key.currentState!.save(), throwsStateError);
    await tester.pump();
    expect(table(key).toJson(), draft);
    expect(find.text('다시 시도'), findsOneWidget);
    await tester.tap(find.text('다시 시도'));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(saved!.blocks.single.table!.toJson(), draft);
    expect(find.text('다시 시도'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'a row menu from before undo cannot overwrite the restored table',
    (tester) async {
      final key = await mount(tester);
      await addTable(tester);
      final block = key.currentState!.document.blocks.single;
      final first = table(key).rows.first.cells.first.id;
      await tester.enterText(cell(block.id, first), '나중 변경');
      await tester.pump();
      final rowId = table(key).rows.first.id;
      await tester.tap(
        find.byKey(ValueKey('block-table-row-${block.id}-$rowId')),
      );
      await tester.pumpAndSettle();
      tester
          .widget<IconButton>(
            find.descendant(
              of: find.byType(BlockPageEditor),
              matching: find.byWidgetPredicate(
                (widget) => widget is IconButton && widget.tooltip == '실행 취소',
              ),
            ),
          )
          .onPressed!();
      await tester.pump();
      expect(table(key).rows.first.cells.first.text, '');
      await tester.tap(find.text('행 삭제'));
      await tester.pumpAndSettle();
      expect(table(key).rowCount, 2);
      expect(table(key).rows.first.cells.first.text, '');
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'read only table disables writes while preserving selectable text',
    (tester) async {
      final original = BlockPageTable.create(rows: 1, columns: 1);
      final value = original.setCellText(
        original.rows.single.id,
        original.columns.single,
        '읽기 전용',
      );
      var writes = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BlockTableEditor(
              blockId: 'readonly',
              table: value,
              enabled: false,
              onChanged: (_, next) {
                writes++;
                return next;
              },
            ),
          ),
        ),
      );
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.readOnly, isTrue);
      expect(field.controller!.text, '읽기 전용');
      field.onChanged!('다른 값');
      expect(writes, 0);
      expect(field.controller!.text, '읽기 전용');
      expect(
        tester
            .widget<TextButton>(
              find.byKey(const ValueKey('block-table-add-row-readonly')),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<Checkbox>(
              find.byKey(const ValueKey('block-table-header-row-readonly')),
            )
            .onChanged,
        isNull,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('one by one table cannot delete its last row or column', (
    tester,
  ) async {
    final block = BlockPageBlock.createTable(rows: 1, columns: 1);
    final key = await mount(
      tester,
      initial: const BlockPageDocument.empty().copyWith(blocks: [block]),
    );
    final value = table(key);
    await tester.tap(
      find.byKey(
        ValueKey('block-table-row-${block.id}-${value.rows.single.id}'),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<PopupMenuItem<Object?>>(menuItem('행 삭제')).enabled,
      isFalse,
    );
    Navigator.of(tester.element(find.text('행 삭제'))).pop();
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(
        ValueKey('block-table-column-${block.id}-${value.columns.single}'),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<PopupMenuItem<Object?>>(menuItem('열 삭제')).enabled,
      isFalse,
    );
    Navigator.of(tester.element(find.text('열 삭제'))).pop();
    await tester.pumpAndSettle();
    expect(table(key).rowCount, 1);
    expect(table(key).columnCount, 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('narrow phone scrolls table columns without layout overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final key = await mount(tester);
    await addTable(tester);
    final block = key.currentState!.document.blocks.single;
    expect(tester.takeException(), isNull);
    final scroll = find.descendant(
      of: find.byKey(ValueKey('block-table-${block.id}')),
      matching: find.byType(SingleChildScrollView),
    );
    final tableFinder = find.byKey(ValueKey('block-table-${block.id}'));
    final lastCell = cell(block.id, table(key).rows.first.cells.last.id);
    Map<String, double> rect(Rect value) => {
      'left': value.left,
      'top': value.top,
      'right': value.right,
      'bottom': value.bottom,
      'width': value.width,
      'height': value.height,
    };
    void geometry(String phase) {
      final scrollables = find.descendant(
        of: tableFinder,
        matching: find.byType(Scrollable),
      );
      debugPrint(
        'table-narrow-$phase ${jsonEncode({
          'table': rect(tester.getRect(tableFinder)),
          'horizontalViewport': rect(tester.getRect(scroll)),
          'lastCell': rect(tester.getRect(lastCell)),
          'lastCellHitTestable': lastCell.hitTestable().evaluate().length,
          'physicalSize': tester.view.physicalSize.toString(),
          'devicePixelRatio': tester.view.devicePixelRatio,
          'viewInsets': MediaQuery.of(tester.element(tableFinder)).viewInsets.toString(),
          'scrollPositions': [
            for (var i = 0; i < scrollables.evaluate().length; i++) {'axisDirection': tester.state<ScrollableState>(scrollables.at(i)).widget.axisDirection.name, 'pixels': tester.state<ScrollableState>(scrollables.at(i)).position.pixels, 'minScrollExtent': tester.state<ScrollableState>(scrollables.at(i)).position.minScrollExtent, 'maxScrollExtent': tester.state<ScrollableState>(scrollables.at(i)).position.maxScrollExtent, 'viewportDimension': tester.state<ScrollableState>(scrollables.at(i)).position.viewportDimension},
          ],
        })}',
      );
    }

    geometry('before');
    final viewport = tester.getRect(scroll);
    await tester.dragFrom(
      Offset(viewport.center.dx, viewport.top + 20),
      const Offset(-240, 0),
    );
    await tester.pumpAndSettle();
    geometry('after');
    final horizontal = tester.state<ScrollableState>(
      find
          .descendant(
            of: scroll,
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is Scrollable &&
                  widget.axisDirection == AxisDirection.right,
            ),
          )
          .first,
    );
    expect(horizontal.position.pixels, greaterThan(0));

    expect(
      cell(block.id, table(key).rows.first.cells.last.id).hitTestable(),
      findsOneWidget,
    );
    await tester.enterText(lastCell, '폰 표 입력😀');
    await tester.pump();
    expect(table(key).rows.first.cells.last.text, '폰 표 입력😀');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'large table creates only visible row fields and disposes after scrolling',
    (tester) async {
      final block = BlockPageBlock.createTable(rows: 128, columns: 32);
      await mount(
        tester,
        initial: const BlockPageDocument.empty().copyWith(blocks: [block]),
      );
      await tester.pump();
      expect(find.byType(TextField).evaluate().length, lessThan(128 * 32));
      final rows = find.descendant(
        of: find.byKey(ValueKey('block-table-${block.id}')),
        matching: find.byType(ListView),
      );
      await tester.drag(rows, const Offset(0, -800));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'three table text round trips restore the caption after JSON reopening',
    (tester) async {
      final original = BlockPageBlock.createTable(text: '원래 설명');
      var key = await mount(
        tester,
        initial: const BlockPageDocument.empty().copyWith(blocks: [original]),
      );
      final first = table(key).rows.first.cells.first.id;
      await tester.enterText(cell(original.id, first), '셀은 한 번😀');
      await tester.pump();
      final payload = table(key).toJson();
      for (var round = 0; round < 3; round++) {
        final projected = table(key).toPlainText();
        await changeType(tester, original.id, '문단');
        expect(
          key.currentState!.document.blocks.single.text,
          '원래 설명\n$projected',
        );
        final persisted = jsonDecode(
          jsonEncode(key.currentState!.document.toJson()),
        ) as Map<String, dynamic>;
        await tester.pumpWidget(const SizedBox());
        key = await mount(
          tester,
          initial: BlockPageDocument.fromJson(persisted),
        );
        await changeType(tester, original.id, '표');
        expect(
          key.currentState!.document.blocks.single.text,
          '원래 설명',
          reason: 'round $round caption',
        );
        expect(table(key).toJson(), payload);
        expect(
          RegExp('셀은 한 번😀')
              .allMatches(key.currentState!.document.toMarkdown()),
          hasLength(1),
        );
      }
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('edited paragraph text is kept exactly when restoring a table', (
    tester,
  ) async {
    final block = BlockPageBlock.createTable(text: '원래 설명');
    final key = await mount(
      tester,
      initial: const BlockPageDocument.empty().copyWith(blocks: [block]),
    );
    final first = table(key).rows.first.cells.first.id;
    await tester.enterText(cell(block.id, first), '표 내용😀');
    await tester.pump();
    final payload = table(key).toJson();
    await changeType(tester, block.id, '문단');
    await tester.enterText(
      find.byKey(ValueKey('block-text-${block.id}')),
      '직접 바꾼 설명\n표 내용😀도 언급',
    );
    await tester.pump();
    await changeType(tester, block.id, '표');
    expect(
      key.currentState!.document.blocks.single.text,
      '직접 바꾼 설명\n표 내용😀도 언급',
    );
    expect(table(key).toJson(), payload);
    expect(
      key.currentState!.document.blocks.single.toJson().containsKey(
        'tableTextConversion',
      ),
      isFalse,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'future or extended conversion metadata is preserved without overwriting it',
    (tester) async {
      for (final metadata in [
        <String, Object?>{
          'format': 'future-conversion',
          'opaque': ['유지😀'],
        },
        <String, Object?>{
          'format': 'personal-ink-table-text-1',
          'tableSha256': '0' * 64,
          'caption': '원래 설명',
          'projectedText': '이전 내용',
          'future': ['유지😀'],
        },
      ]) {
        final block = BlockPageBlock.createTable(text: '설명');
        final raw = {...block.toJson(), 'tableTextConversion': metadata};
        final key = await mount(
          tester,
          initial: const BlockPageDocument.empty().copyWith(
            blocks: [BlockPageBlock.fromJson(raw)],
          ),
        );
        await chooseAction(tester, 'block-actions-${block.id}', '종류 바꾸기');
        expect(
          tester.widget<ListTile>(find.widgetWithText(ListTile, '문단')).enabled,
          isFalse,
        );
        Navigator.of(tester.element(find.widgetWithText(ListTile, '표'))).pop();
        await tester.pumpAndSettle();
        expect(key.currentState!.document.blocks.single.toJson(), raw);
        await tester.pumpWidget(const SizedBox());
      }
    },
  );

  testWidgets(
    'a changed table payload cannot use an old caption restoration receipt',
    (tester) async {
      final block = BlockPageBlock.createTable(text: '원래 설명');
      var key = await mount(
        tester,
        initial: const BlockPageDocument.empty().copyWith(blocks: [block]),
      );
      final first = table(key).rows.first.cells.first.id;
      await tester.enterText(cell(block.id, first), '원래 셀');
      await tester.pump();
      await changeType(tester, block.id, '문단');
      final paragraphText = key.currentState!.document.blocks.single.text;
      final raw = jsonDecode(
        jsonEncode(key.currentState!.document.toJson()),
      ) as Map<String, dynamic>;
      final rawBlock = (raw['blocks'] as List).single as Map;
      final rawTable = rawBlock['tableData'] as Map;
      (((rawTable['rows'] as List).first as Map)['cells'] as List)
              .first['text'] =
          '바뀐 셀😀';
      await tester.pumpWidget(const SizedBox());
      key = await mount(tester, initial: BlockPageDocument.fromJson(raw));
      await changeType(tester, block.id, '표');
      expect(key.currentState!.document.blocks.single.text, paragraphText);
      expect(table(key).rows.first.cells.first.text, '바뀐 셀😀');
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'a forged caption with a matching table hash cannot discard current text',
    (tester) async {
      final block = BlockPageBlock.createTable(text: '보존할 설명');
      var key = await mount(
        tester,
        initial: const BlockPageDocument.empty().copyWith(blocks: [block]),
      );
      await changeType(tester, block.id, '문단');
      final paragraphText = key.currentState!.document.blocks.single.text;
      final raw = jsonDecode(
        jsonEncode(key.currentState!.document.toJson()),
      ) as Map<String, dynamic>;
      final rawBlock = (raw['blocks'] as List).single as Map;
      (rawBlock['tableTextConversion'] as Map)['caption'] = '출처가 다른 설명';
      await tester.pumpWidget(const SizedBox());
      key = await mount(tester, initial: BlockPageDocument.fromJson(raw));
      await changeType(tester, block.id, '표');
      expect(key.currentState!.document.blocks.single.text, paragraphText);
      expect(key.currentState!.document.blocks.single.table, isNotNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'a column menu from before undo cannot overwrite the restored table',
    (tester) async {
      final key = await mount(tester);
      await addTable(tester);
      final block = key.currentState!.document.blocks.single;
      final first = table(key).rows.first.cells.first.id;
      await tester.enterText(cell(block.id, first), '열 변경😀');
      await tester.pump();
      final columnId = table(key).columns.first;
      await tester.tap(
        find.byKey(ValueKey('block-table-column-${block.id}-$columnId')),
      );
      await tester.pumpAndSettle();
      tester
          .widget<IconButton>(
            find.descendant(
              of: find.byType(BlockPageEditor),
              matching: find.byWidgetPredicate(
                (widget) => widget is IconButton && widget.tooltip == '실행 취소',
              ),
            ),
          )
          .onPressed!();
      await tester.pump();
      expect(table(key).rows.first.cells.first.text, '');
      await tester.tap(find.text('열 삭제'));
      await tester.pumpAndSettle();
      expect(table(key).columnCount, 2);
      expect(table(key).rows.first.cells.first.text, '');
      await tester.pumpWidget(const SizedBox());
    },
  );
}
