import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/vault/block_page_document.dart';
import 'package:saber/data/vault/block_page_synced_reference.dart';
import 'package:saber/data/vault/synced_block_store.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/pages/workspace/block_page_editor.dart';
import 'package:saber/pages/workspace/synced_block_view.dart';
import 'package:saber/pages/workspace/workspace_controller.dart';

Finder _field(String id) => find.byKey(ValueKey('block-text-$id'));

Future<void> _selectMenuItem(
  WidgetTester tester,
  Finder menu,
  String label,
) async {
  await tester.tap(menu);
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'keeps left and right pane editors in reading order at both widths',
    (tester) async {
      final leftId = newId(), rightId = newId();
      final doc = BlockPageDocument.fromJson({
        'version': 1,
        'blocks': [
          {
            'id': newId(),
            'type': 'columnList',
            'columnLayout': 1,
            'children': [
              for (final (id, text) in [(leftId, '왼쪽 내용'), (rightId, '오른쪽 내용')])
                {
                  'id': newId(),
                  'type': 'column',
                  'columnLayout': 1,
                  'children': [
                    {'id': id, 'type': 'paragraph', 'text': text},
                  ],
                },
            ],
          },
        ],
      });
      await tester.binding.setSurfaceSize(const Size(1000, 850));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BlockPageEditor(
              initialDocument: doc,
              onSave: (_) async {},
              onBack: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final leftWide = tester.getTopLeft(_field(leftId));
      final rightWide = tester.getTopLeft(_field(rightId));
      expect(leftWide.dy, closeTo(rightWide.dy, 1));
      expect(rightWide.dx, greaterThan(leftWide.dx + 250));

      final rightController = tester
          .widget<TextField>(_field(rightId))
          .controller;
      await tester.binding.setSurfaceSize(const Size(420, 850));
      await tester.pumpAndSettle();
      final leftNarrow = tester.getTopLeft(_field(leftId));
      final rightNarrow = tester.getTopLeft(_field(rightId));
      expect(leftNarrow.dx, closeTo(rightNarrow.dx, 1));
      expect(rightNarrow.dy, greaterThan(leftNarrow.dy));
      expect(
        tester.widget<TextField>(_field(rightId)).controller,
        same(rightController),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('2단'), findsOneWidget);
      expect(find.byTooltip('단 작업'), findsNothing);
      await tester.tap(find.byTooltip('블록 추가'));
      await tester.pumpAndSettle();
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is PopupMenuItem<String> && widget.value == 'columns',
        ),
        findsNothing,
      );
    },
  );

  testWidgets('adds and edits both panes, moves an existing block and saves', (
    tester,
  ) async {
    final source = BlockPageBlock.fromJson({
      'id': newId(),
      'type': 'paragraph',
      'text': '옮길 문단',
      'extension': {'keep': true},
    });
    final tail = BlockPageBlock.create(text: '다음 문단');
    final initial = const BlockPageDocument.empty().copyWith(
      blocks: [source, tail],
    );
    final key = GlobalKey<BlockPageEditorState>();
    BlockPageDocument current() => key.currentState!.document;
    BlockPageDocument? saved;
    await tester.binding.setSurfaceSize(const Size(1000, 850));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BlockPageEditor(
            key: key,
            initialDocument: initial,
            enableColumns: true,
            autosaveDelay: const Duration(hours: 1),
            onSave: (document) async => saved = document,
            onBack: () {},
          ),
        ),
      ),
    );

    await _selectMenuItem(tester, find.byTooltip('블록 추가'), '2단');
    final group = current().blocks.last;
    expect(group.isColumnLayout, isTrue);
    final [left, right] = group.children;
    Future<String> addParagraph(
      BlockPageBlock column,
      int index,
      String text,
    ) async {
      await tester.tap(find.byKey(ValueKey('column-add-${column.id}')));
      await tester.pumpAndSettle();
      final id = current().blocks.last.children[index].children.single.id;
      await tester.enterText(_field(id), text);
      await tester.pumpAndSettle();
      return id;
    }

    final leftText = await addParagraph(left, 0, '왼쪽에서 작성');
    final rightText = await addParagraph(right, 1, '오른쪽에서 작성');
    final sourceAction = find.byKey(ValueKey('block-actions-${source.id}'));
    Future<void> moveTo(String columnId) async {
      await _selectMenuItem(tester, sourceAction, '다른 단으로 이동');
      await tester.tap(find.byKey(ValueKey('column-move-target-$columnId')));
      await tester.pumpAndSettle();
    }

    await moveTo(left.id);
    expect(
      current().blocks.last.children.first.children.last.toJson(),
      source.toJson(),
    );
    await moveTo(right.id);
    expect(
      current().blocks.last.children.last.children.last.toJson(),
      source.toJson(),
    );
    await _selectMenuItem(tester, sourceAction, '본문으로 이동');
    expect(current().blocks.map((block) => block.id), [
      tail.id,
      group.id,
      source.id,
    ]);

    await _selectMenuItem(tester, find.byTooltip('단 작업'), '단 나누기 해제');
    expect(current().blocks.map((block) => block.id), [
      tail.id,
      leftText,
      rightText,
      source.id,
    ]);
    await tester.tap(find.byTooltip('실행 취소'));
    await tester.pumpAndSettle();
    expect(current().blocks[1].id, group.id);
    expect(current().blocks[1].children.first.children.single.text, '왼쪽에서 작성');
    expect(current().blocks[1].children.last.children.single.text, '오른쪽에서 작성');
    expect(current().blocks.last.toJson(), source.toJson());

    await tester.tap(find.byTooltip('저장'));
    await tester.pumpAndSettle();
    expect(saved?.toJson(), current().toJson());
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'duplicates an ordinary block within its column and copies the whole group',
    (tester) async {
      final source = BlockPageBlock.create(text: '왼쪽 내용');
      final rightText = BlockPageBlock.create(text: '오른쪽 내용');
      final empty = BlockPageBlock.createColumns();
      final [left, right] = empty.children;
      final group = empty.copyWith(
        children: [
          left.copyWith(children: [source]),
          right.copyWith(children: [rightText]),
        ],
      );
      final key = GlobalKey<BlockPageEditorState>();
      await tester.binding.setSurfaceSize(const Size(1000, 850));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BlockPageEditor(
              key: key,
              initialDocument: const BlockPageDocument.empty().copyWith(
                blocks: [group],
              ),
              enableColumns: true,
              autosaveDelay: const Duration(hours: 1),
              onSave: (_) async {},
              onBack: () {},
            ),
          ),
        ),
      );
      final sourceMenu = find.byKey(ValueKey('block-actions-${source.id}'));
      await _selectMenuItem(tester, sourceMenu, '블록 복제');
      final original = key.currentState!.document.blocks.single;
      final leftBlocks = original.children.first.children;
      expect(leftBlocks.map((block) => block.text), [source.text, source.text]);
      expect(leftBlocks.last.id, isNot(source.id));
      expect(original.children.last.children.single.id, rightText.id);

      final groupMenu = find.byKey(ValueKey('column-actions-${group.id}'));
      await _selectMenuItem(tester, groupMenu, '블록 복제');
      final [originalGroup, copy] = key.currentState!.document.blocks;
      expect(originalGroup.id, group.id);
      expect(copy.id, isNot(group.id));
      expect(copy.isColumnLayout, isTrue);
      expect(
        copy.children.map((pane) => pane.children.map((block) => block.text)),
        [
          [source.text, source.text],
          [rightText.text],
        ],
      );
      expect(copy.children.first.id, isNot(left.id));
      expect(copy.children.last.id, isNot(right.id));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('discards an open move chooser when the document changes', (
    tester,
  ) async {
    final source = BlockPageBlock.create(text: '이전 문서');
    final group = BlockPageBlock.createColumns();
    final initial = const BlockPageDocument.empty().copyWith(
      blocks: [source, group],
    );
    final changed = initial.copyWith(
      blocks: [
        source.copyWith(text: '다시 읽은 문서'),
        group,
      ],
    );
    final active = ValueNotifier(initial);
    addTearDown(active.dispose);
    final key = GlobalKey<BlockPageEditorState>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder(
            valueListenable: active,
            builder: (_, document, _) => BlockPageEditor(
              key: key,
              initialDocument: document,
              enableColumns: true,
              onSave: (_) async {},
              onBack: () {},
            ),
          ),
        ),
      ),
    );

    await _selectMenuItem(
      tester,
      find.byKey(ValueKey('block-actions-${source.id}')),
      '다른 단으로 이동',
    );
    active.value = changed;
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(ValueKey('column-move-target-${group.children.first.id}')),
    );
    await tester.pumpAndSettle();

    expect(key.currentState!.document, same(changed));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a nested marked shape retains the ordinary legacy rendering', (
    tester,
  ) async {
    final text = BlockPageBlock.create(text: '보관할 내용');
    final layout = BlockPageBlock.createColumns();
    final [left, right] = layout.children;
    final nested = layout.copyWith(
      children: [
        left.copyWith(children: [text]),
        right,
      ],
    );
    final initial = const BlockPageDocument.empty().copyWith(
      blocks: [
        BlockPageBlock.create(type: 'toggle').copyWith(children: [nested]),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BlockPageEditor(
            initialDocument: initial,
            enableColumns: true,
            onSave: (_) async {},
            onBack: () {},
          ),
        ),
      ),
    );
    expect(find.byKey(ValueKey('column-pane-${left.id}')), findsNothing);
    expect(_field(text.id), findsOneWidget);
  });

  for (final insideColumn in [false, true]) {
    testWidgets(
      'shows a notice when ${insideColumn ? 'adding a pane paragraph' : 'creating two columns'} reaches the block limit',
      (tester) async {
        final group = insideColumn ? BlockPageBlock.createColumns() : null;
        final initial = BlockPageDocument.fromJson({
          'version': 1,
          'blocks': [
            {
              'id': newId(),
              'type': 'toggle',
              'collapsed': true,
              'children': [
                for (var i = 0; i < (insideColumn ? 9996 : 9997); i++)
                  {
                    'id':
                        '10000000-0000-4000-8000-${i.toString().padLeft(12, '0')}',
                    'type': 'paragraph',
                  },
              ],
            },
            if (group != null) group.toJson(),
          ],
        });
        final key = GlobalKey<BlockPageEditorState>();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: BlockPageEditor(
                key: key,
                initialDocument: initial,
                enableColumns: true,
                onSave: (_) async =>
                    fail('An over-limit addition must not save'),
                onBack: () {},
              ),
            ),
          ),
        );

        if (group == null) {
          await _selectMenuItem(tester, find.byTooltip('블록 추가'), '2단');
        } else {
          await tester.tap(
            find.byKey(ValueKey('column-add-${group.children.first.id}')),
          );
          await tester.pumpAndSettle();
        }

        expect(tester.takeException(), isNull);
        expect(key.currentState!.document, same(initial));
        expect(find.text('블록 수 제한에 도달했습니다.'), findsOneWidget);
      },
    );
  }

  testWidgets(
    'dirty synced content inside a pane blocks relocation and unwrap',
    (tester) async {
      final sourceBlock = BlockPageBlock.create(text: '원본 내용');
      final fixture = (await tester.runAsync(() async {
        final root = await Directory.systemTemp.createTemp(
          'column-synced-test-',
        );
        final repo = await NoteRepository.open(root, createFormatVersion: 2);
        final controller = WorkspaceController(repo);
        final note = await controller.createNote(
          'Source',
          documentKind: VaultDocumentKind.page,
        );
        await controller.saveBlockPage(
          const BlockPageDocument.empty().copyWith(blocks: [sourceBlock]),
          session: controller.activeSession!,
        );
        final reference = BlockSyncedReference.create(
          sourceNoteId: note.id,
          sourceBlockId: sourceBlock.id,
        );
        final target = await SyncedBlockStore(repo).open(reference);
        return (root: root, repo: repo, controller: controller, target: target);
      }))!;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(() async {
          fixture.controller.dispose();
          await fixture.repo.close();
          await fixture.root.delete(recursive: true);
        });
      });
      final synced = BlockPageBlock.createSyncedBlock(
        reference: fixture.target.reference,
      );
      final sibling = BlockPageBlock.create(text: '같은 단 문단');
      final group = BlockPageBlock.createColumns();
      final [left, right] = group.children;
      final initial = const BlockPageDocument.empty().copyWith(
        blocks: [
          group.copyWith(
            children: [
              left.copyWith(children: [synced, sibling]),
              right,
            ],
          ),
        ],
      );
      final key = GlobalKey<BlockPageEditorState>();
      await tester.binding.setSurfaceSize(const Size(1000, 850));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BlockPageEditor(
              key: key,
              initialDocument: initial,
              enableColumns: true,
              syncedBlockAccess: SyncedBlockAccess(
                owner: Object(),
                ownerNoteId: newId(),
                isCurrent: () => true,
                changes: const Stream<void>.empty(),
                listPages: () async => [],
                listSources: (_) async => [],
                open: (_) async => fixture.target,
                save: (_, _, _) async =>
                    fail('Blocked actions must not save the draft'),
              ),
              onSave: (_) async {},
              onBack: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('원본 블록 편집'));
      await tester.pumpAndSettle();
      final draft = find.byKey(ValueKey('synced-block-input-${synced.id}'));
      await tester.enterText(draft, '보존할 초안');
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<PopupMenuButton<String>>(
              find.byKey(ValueKey('column-actions-${group.id}')),
            )
            .enabled,
        isFalse,
      );
      final siblingMenu = find.byKey(ValueKey('block-actions-${sibling.id}'));
      await tester.tap(siblingMenu);
      await tester.pumpAndSettle();
      for (final action in ['다른 단으로 이동', '본문으로 이동']) {
        final item = find.ancestor(
          of: find.text(action),
          matching: find.byType(PopupMenuItem<String>),
        );
        expect(tester.widget<PopupMenuItem<String>>(item).enabled, isFalse);
      }
      expect(tester.widget<TextField>(draft).controller!.text, '보존할 초안');
      expect(key.currentState!.document, same(initial));
      expect(tester.takeException(), isNull);
    },
  );
}
