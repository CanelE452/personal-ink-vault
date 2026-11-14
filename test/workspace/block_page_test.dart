import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/vault/block_page_document.dart';
import 'package:saber/pages/workspace/block_page_editor.dart';

void main() {
  test('typed blocks preserve nested unknown data and Unicode through edit and Markdown projection', () {
    final id = newId(), child = newId(), target = newId();
    final raw = <String, dynamic>{
      'version': 1,
      'future': {
        'keep': [1, 2],
      },
      'blocks': [
        {
          'id': id,
          'type': 'heading1',
          'text': '연구 정리',
          'future': {
            'style': ['keep'],
          },
          'children': [
            {'id': child, 'type': 'todo', 'text': '검증', 'checked': true},
          ],
        },
        {
          'id': newId(),
          'type': 'documentLink',
          'text': '관련 노트',
          'noteId': target,
        },
        {
          'id': newId(),
          'type': 'futureBlock',
          'opaque': {
            'data': [3],
          },
        },
      ],
    };
    final doc = BlockPageDocument.fromJson(raw);
    final edited = doc.copyWith(
      blocks: [
        doc.blocks.first.copyWith(text: '수정된 제목'),
        ...doc.blocks.skip(1),
      ],
    );
    final output = edited.toJson();
    expect(output['future'], raw['future']);
    expect((output['blocks'] as List).first['future'], {
      'style': ['keep'],
    });
    expect((output['blocks'] as List).last, (raw['blocks'] as List).last);
    (output['future'] as Map)['keep'].clear();
    expect(doc.toJson()['future'], {
      'keep': [1, 2],
    });
    expect(edited.blocks.first.id, id);
    expect(edited.toMarkdown(), contains('# 수정된 제목'));
    expect(edited.toMarkdown(), contains('- [x] 검증'));
    expect(edited.toMarkdown(), contains('inkvault://note/$target'));
    expect(
      BlockPageDocument.fromJson(jsonDecode(jsonEncode(edited.toJson())))
          .toJson(),
      edited.toJson(),
    );
  });

  test(
    'duplicate nested IDs unsafe identities and cyclic depth are rejected',
    () {
      final id = newId();
      final node = {'id': id, 'type': 'paragraph', 'text': ''};
      expect(
        () => BlockPageDocument.fromJson({
          'version': 1,
          'blocks': [node, node],
        }),
        throwsFormatException,
      );
      expect(
        () => BlockPageBlock.fromJson({...node, 'id': '../../private'}),
        throwsFormatException,
      );
      expect(
        () => BlockPageBlock.fromJson({
          ...node,
          'type': 'documentLink',
          'noteId': 'javascript:alert(1)',
        }),
        throwsFormatException,
      );
      expect(
        () => BlockPageDocument.fromJson({'version': 99, 'blocks': []}),
        throwsFormatException,
      );
      Map<String, dynamic> nested = node;
      for (var i = 0; i < 70; i++) {
        nested = {
          'id': newId(),
          'type': 'toggle',
          'children': [nested],
        };
      }
      expect(
        () => BlockPageDocument.fromJson({
          'version': 1,
          'blocks': [nested],
        }),
        throwsFormatException,
      );
    },
  );

  test('all four templates create independent blocks and meaningful editable outlines', () {
    for (final name in ['lecture', 'research', 'meeting', 'project']) {
      final a = BlockPageDocument.template(name),
          b = BlockPageDocument.template(name);
      expect(a.blocks.length, greaterThanOrEqualTo(4));
      expect(a.blocks.first.type, 'heading1');
      expect(a.blocks.first.text, isNotEmpty);
      expect(
        a.blocks
            .map((block) => block.id)
            .toSet()
            .intersection(b.blocks.map((block) => block.id).toSet()),
        isEmpty,
      );
      expect(a.toMarkdown(), isNotEmpty);
    }
  });

  test(
    'Markdown retains code fences equations list and quote semantics as text',
    () {
      final doc = const BlockPageDocument.empty().copyWith(
        blocks: [
          BlockPageBlock.create(type: 'heading2', text: '개념'),
          BlockPageBlock.create(type: 'bullet', text: '항목'),
          BlockPageBlock.create(type: 'numbered', text: '첫째'),
          BlockPageBlock.create(type: 'quote', text: '인용\n두 줄'),
          BlockPageBlock.create(type: 'code', text: 'print("```");'),
          BlockPageBlock.create(type: 'equation', text: 'x^2'),
          BlockPageBlock.create(type: 'divider'),
        ],
      );
      final markdown = doc.toMarkdown();
      expect(markdown, contains('## 개념'));
      expect(markdown, contains('- 항목'));
      expect(markdown, contains('1. 첫째'));
      expect(markdown, contains('> 인용\n> 두 줄'));
      expect(markdown, contains('````\nprint("```");\n````'));
      expect(
        markdown,
        contains(
          r'$$'
          '\nx^2\n'
          r'$$',
        ),
      );
      expect(markdown, contains('---'));
    },
  );

  Future<GlobalKey<BlockPageEditorState>> mount(
    WidgetTester tester, {
    BlockPageDocument initial = const BlockPageDocument.empty(),
    Future<void> Function(BlockPageDocument)? save,
    ValueChanged<bool>? dirty,
    ValueChanged<bool>? busy,
    VoidCallback? back,
    List<BlockPageNote> notes = const [],
    ValueChanged<String>? open,
  }) async {
    final key = GlobalKey<BlockPageEditorState>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BlockPageEditor(
            key: key,
            initialDocument: initial,
            onSave: save ?? (_) async {},
            onBack: back ?? () {},
            onDirtyChanged: dirty,
            onBusyChanged: busy,
            notes: notes,
            onOpenNote: open,
            autosaveDelay: const Duration(hours: 1),
          ),
        ),
      ),
    );
    return key;
  }

  Future<void> add(WidgetTester tester, String label) async {
    await tester.tap(find.byTooltip('블록 추가'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'independent block editing saving and reloading keeps content and IDs',
    (tester) async {
      BlockPageDocument? saved;
      final key = await mount(
        tester,
        save: (document) async => saved = document,
      );
      await add(tester, '문단');
      final id = key.currentState!.document.blocks.single.id;
      await tester.enterText(find.byKey(ValueKey('block-text-$id')), '기록한 내용');
      await key.currentState!.save();
      expect(saved!.blocks.single.text, '기록한 내용');
      await tester.pumpWidget(const SizedBox());
      final reopened = await mount(
        tester,
        initial: BlockPageDocument.fromJson(saved!.toJson()),
      );
      expect(reopened.currentState!.document.blocks.single.id, id);
      expect(
        tester
            .widget<TextField>(find.byKey(ValueKey('block-text-$id')))
            .controller!
            .text,
        '기록한 내용',
      );
    },
  );

  testWidgets(
    'slash menu changes only the selected block kind and undo redo restore it',
    (tester) async {
      final key = await mount(tester);
      await add(tester, '문단');
      final id = key.currentState!.document.blocks.single.id;
      await tester.enterText(find.byKey(ValueKey('block-text-$id')), '/');
      await tester.pumpAndSettle();
      await tester.tap(find.text('제목 1').last);
      await tester.pumpAndSettle();
      expect(key.currentState!.document.blocks.single.type, 'heading1');
      expect(key.currentState!.document.blocks.single.id, id);
      await tester.tap(find.byTooltip('실행 취소'));
      await tester.pump();
      expect(key.currentState!.document.blocks.single.type, 'paragraph');
      await tester.tap(find.byTooltip('다시 실행'));
      await tester.pump();
      expect(key.currentState!.document.blocks.single.type, 'heading1');
    },
  );

  testWidgets(
    'block menu duplicates the adjacent subtree as one undoable edit',
    (tester) async {
      final child = BlockPageBlock.create(text: '하위 문단');
      final source = BlockPageBlock.create(
        type: 'toggle',
        text: '원본 블록',
      ).copyWith(children: [child]);
      final tail = BlockPageBlock.create(text: '다음 블록');
      BlockPageDocument? saved;
      final key = await mount(
        tester,
        initial: const BlockPageDocument.empty().copyWith(
          blocks: [source, tail],
        ),
        save: (document) async => saved = document,
      );

      await tester.tap(find.byKey(ValueKey('block-actions-${source.id}')));
      await tester.pumpAndSettle();
      expect(find.text('블록 복제'), findsOneWidget);
      await tester.tap(find.text('블록 복제'));
      await tester.pumpAndSettle();
      final blocks = key.currentState!.document.blocks;
      expect(blocks, hasLength(3));
      final duplicate = blocks[1];
      expect(blocks.map((block) => block.id), [
        source.id,
        duplicate.id,
        tail.id,
      ]);
      expect(duplicate.id, isNot(source.id));
      expect(duplicate.children.single.id, isNot(child.id));
      expect(duplicate.children.single.text, child.text);

      await tester.tap(find.byTooltip('실행 취소'));
      await tester.pumpAndSettle();
      expect(key.currentState!.document.blocks.map((b) => b.id), [
        source.id,
        tail.id,
      ]);
      await tester.tap(find.byTooltip('다시 실행'));
      await tester.pumpAndSettle();
      expect(key.currentState!.document.blocks[1].id, duplicate.id);

      final duplicateInput = find.byKey(ValueKey('block-text-${duplicate.id}'));
      await tester.ensureVisible(duplicateInput);
      await tester.enterText(duplicateInput, '복제본만 수정');
      await key.currentState!.save();
      expect(saved!.blocks.first.text, source.text);
      expect(saved!.blocks[1].text, '복제본만 수정');
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'block menu leaves duplication disabled while Korean input is composing',
    (tester) async {
      final block = BlockPageBlock.create(text: '한글');
      final key = await mount(
        tester,
        initial: const BlockPageDocument.empty().copyWith(blocks: [block]),
      );
      final field = find.byKey(ValueKey('block-text-${block.id}'));
      final controller = tester.widget<TextField>(field).controller!;
      controller.value = const TextEditingValue(
        text: '한글',
        selection: TextSelection.collapsed(offset: 1),
        composing: TextRange(start: 0, end: 1),
      );
      await tester.pump();

      final menu = find.byKey(ValueKey('block-actions-${block.id}'));
      await tester.tap(menu);
      await tester.pumpAndSettle();
      final action = find.widgetWithText(PopupMenuItem<String>, '블록 복제');
      expect(action, findsOneWidget);
      expect(tester.widget<PopupMenuItem<String>>(action).enabled, isFalse);
      expect(key.currentState!.document.blocks.single.id, block.id);

      await tester.tapAt(const Offset(1, 1));
      await tester.pumpAndSettle();
      controller.clearComposing();
      await tester.pump();
      await tester.tap(menu);
      await tester.pumpAndSettle();
      expect(tester.widget<PopupMenuItem<String>>(action).enabled, isTrue);
      await tester.tap(action);
      await tester.pumpAndSettle();
      expect(key.currentState!.document.blocks.map((b) => b.text), [
        '한글',
        '한글',
      ]);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'block menu guards an active Korean composition in a table cell',
    (tester) async {
      final block = BlockPageBlock.createTable();
      final cell = block.table!.rows.first.cells.first;
      final key = await mount(
        tester,
        initial: const BlockPageDocument.empty().copyWith(blocks: [block]),
      );
      final field = find.byKey(
        ValueKey('block-table-cell-${block.id}-${cell.id}'),
      );
      await tester.showKeyboard(field);
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '한',
          selection: TextSelection.collapsed(offset: 1),
          composing: TextRange(start: 0, end: 1),
        ),
      );
      await tester.pump();
      final controller = tester.widget<TextField>(field).controller!;
      expect(controller.value.composing, const TextRange(start: 0, end: 1));

      final menu = find.byKey(ValueKey('block-actions-${block.id}'));
      await tester.tap(menu);
      await tester.pumpAndSettle();
      final action = find.byKey(const ValueKey('block-duplicate-action'));
      expect(tester.widget<PopupMenuItem<String>>(action).enabled, isFalse);
      expect(key.currentState!.document.blocks.single.id, block.id);

      await tester.tapAt(const Offset(1, 1));
      await tester.pumpAndSettle();
      controller.clearComposing();
      await tester.pump();
      await tester.tap(menu);
      await tester.pumpAndSettle();
      expect(tester.widget<PopupMenuItem<String>>(action).enabled, isTrue);
      await tester.tap(action);
      await tester.pumpAndSettle();
      expect(
        key.currentState!.document.blocks.map(
          (b) => b.table!.rows.first.cells.first.text,
        ),
        ['한', '한'],
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'todo toggle nested text and reorder preserve the real block tree',
    (tester) async {
      final todo = BlockPageBlock.create(type: 'todo', text: '완료할 일');
      final child = BlockPageBlock.create(text: '접히는 본문');
      final toggle = BlockPageBlock.create(
        type: 'toggle',
        text: '설명',
      ).copyWith(children: [child]);
      final key = await mount(
        tester,
        initial: const BlockPageDocument.empty().copyWith(
          blocks: [todo, toggle],
        ),
      );
      await tester.tap(find.byKey(ValueKey('block-check-${todo.id}')));
      await tester.pump();
      expect(key.currentState!.document.blocks.first.checked, isTrue);
      expect(find.byKey(ValueKey('block-text-${child.id}')), findsOneWidget);
      await tester.tap(find.byKey(ValueKey('block-toggle-${toggle.id}')));
      await tester.pump();
      expect(find.byKey(ValueKey('block-text-${child.id}')), findsNothing);
      expect(
        key.currentState!.document.blocks.last.children.single.text,
        '접히는 본문',
      );
      await tester.tap(find.byKey(ValueKey('block-actions-${toggle.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('위로 이동'));
      await tester.pumpAndSettle();
      expect(key.currentState!.document.blocks.first.id, toggle.id);
      await tester.tap(find.byKey(ValueKey('block-actions-${todo.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('삭제'));
      await tester.pumpAndSettle();
      expect(key.currentState!.document.blocks.map((b) => b.id), [toggle.id]);
    },
  );

  testWidgets(
    'equation displays math and document link uses only a known note callback',
    (tester) async {
      final id = newId();
      final math = BlockPageBlock.create(type: 'equation', text: r'\int x dx');
      final link = BlockPageBlock.create(
        type: 'documentLink',
        text: '관련 자료',
        noteId: id,
      );
      final opened = <String>[];
      await mount(
        tester,
        initial: const BlockPageDocument.empty().copyWith(blocks: [math, link]),
        notes: [BlockPageNote(id, '자료')],
        open: opened.add,
      );
      expect(find.byType(Math), findsOneWidget);
      await tester.tap(find.byKey(ValueKey('block-open-${link.id}')));
      expect(opened, [id]);
      await tester.pumpWidget(const SizedBox());
      await mount(
        tester,
        initial: const BlockPageDocument.empty().copyWith(blocks: [link]),
        open: opened.add,
      );
      await tester.tap(find.byKey(ValueKey('block-open-${link.id}')));
      await tester.pump();
      expect(opened, [id]);
      expect(find.text('연결된 문서를 찾을 수 없습니다.'), findsOneWidget);
    },
  );

  testWidgets(
    'templates append useful blocks without replacing existing text',
    (tester) async {
      final old = BlockPageBlock.create(text: '기존 기록');
      final key = await mount(
        tester,
        initial: const BlockPageDocument.empty().copyWith(blocks: [old]),
      );
      await tester.tap(find.byTooltip('템플릿'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('강의 노트'));
      await tester.pumpAndSettle();
      expect(key.currentState!.document.blocks.first.text, '기존 기록');
      expect(
        key.currentState!.document.blocks.any(
          (b) => b.type == 'heading1' && b.text == '강의 노트',
        ),
        isTrue,
      );
    },
  );

  testWidgets(
    'failed save keeps draft and prevents back until a successful retry',
    (tester) async {
      var fail = true, backs = 0;
      final key = await mount(
        tester,
        save: (_) async {
          if (fail) throw StateError('disk full');
        },
        back: () => backs++,
      );
      await add(tester, '문단');
      final id = key.currentState!.document.blocks.single.id;
      await tester.enterText(
        find.byKey(ValueKey('block-text-$id')),
        '잃으면 안 되는 내용',
      );
      await tester.tap(find.byTooltip('문서 목록으로'));
      await tester.pumpAndSettle();
      expect(backs, 0);
      expect(key.currentState!.document.blocks.single.text, '잃으면 안 되는 내용');
      expect(find.text('저장하지 못했습니다. 작업 내용은 열려 있습니다.'), findsOneWidget);
      fail = false;
      await tester.tap(find.byTooltip('문서 목록으로'));
      await tester.pumpAndSettle();
      expect(backs, 1);
    },
  );

  testWidgets(
    'save shares its pending writer and drains edits made while it is saving',
    (tester) async {
      final entered = Completer<void>(), release = Completer<void>();
      final writes = <BlockPageDocument>[];
      final block = BlockPageBlock.create(text: '원래');
      final busy = <bool>[];
      final key = await mount(
        tester,
        initial: const BlockPageDocument.empty().copyWith(blocks: [block]),
        busy: busy.add,
        save: (document) async {
          writes.add(document);
          if (writes.length == 1) {
            entered.complete();
            await release.future;
          }
        },
      );
      await tester.enterText(
        find.byKey(ValueKey('block-text-${block.id}')),
        '첫 입력',
      );
      final a = key.currentState!.save();
      final b = key.currentState!.save();
      expect(identical(a, b), isTrue);
      await entered.future;
      await tester.enterText(
        find.byKey(ValueKey('block-text-${block.id}')),
        '저장 중 추가 입력',
      );
      release.complete();
      await a;
      expect(writes.map((d) => d.blocks.single.text), ['첫 입력', '저장 중 추가 입력']);
      expect(busy, [true, false]);
    },
  );

  for (final width in [320.0, 800.0, 1400.0]) {
    testWidgets('block editor fits a $width pixel surface', (tester) async {
      tester.view.physicalSize = Size(width, 950);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final blocks = [
        for (final type in [
          'heading1',
          'paragraph',
          'todo',
          'toggle',
          'quote',
          'callout',
          'code',
          'equation',
          'divider',
          'documentLink',
        ])
          BlockPageBlock.create(type: type, text: '문서'),
      ];
      await mount(
        tester,
        initial: const BlockPageDocument.empty().copyWith(blocks: blocks),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.byTooltip('블록 추가'), findsOneWidget);
    });
  }
}
