import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:saber/data/vault/block_page_document.dart';
import 'package:saber/data/vault/block_page_history.dart';
import 'package:saber/data/vault/block_page_media.dart';

void main() {
  test(
    'column boundaries preserve root heading, links and independent lists',
    () {
      final target = newId();
      final page = BlockPageDocument.fromJson({
        'version': 1,
        'blocks': [
          _block('numbered', text: 'Before'),
          _layout(
            [
              _block('numbered', text: 'Left first'),
              _block('numbered', text: 'Left second'),
            ],
            [_block('paragraph'), _block('numbered', text: 'Right first')],
          ),
          _block('numbered', text: 'After'),
          _layout(
            [_block('heading2', text: 'Heading inside a column')],
            [_block('documentLink', text: 'A [source]', noteId: target)],
          ),
        ],
      });

      final markdown = page.toMarkdown();
      final html = md.markdownToHtml(markdown);
      expect(html, contains('<h2>Heading inside a column</h2>'));
      expect(
        html,
        contains('<a href="inkvault://note/$target">A [source]</a>'),
      );
      expect(html, isNot(contains('<pre><code>')));
      expect(RegExp(r'<ol>').allMatches(html), hasLength(4));
      expect(markdown, contains('2. Left second'));
      expect(markdown, contains('1. Right first'));
      expect(markdown, contains('1. After'));
      expect(
        page.toSearchText(),
        contains('[A \\[source\\]](inkvault://note/$target)'),
      );
    },
  );

  test(
    'empty marked columns survive save and reopen with stable identities',
    () {
      final columns = BlockPageBlock.createColumns();
      final page = const BlockPageDocument.empty().copyWith(blocks: [columns]);
      final restored = BlockPageDocument.fromJson(page.toJson());

      expect(columns.isColumnLayout, isTrue);
      expect(restored.toJson(), page.toJson());
      expect(restored.blocks.single.isColumnLayout, isTrue);
      expect(columns.children.map((column) => column.type), [
        'column',
        'column',
      ]);
      expect(
        columns.children.every((column) => column.children.isEmpty),
        isTrue,
      );
      expect({
        columns.id,
        ...columns.children.map((column) => column.id),
      }, hasLength(3));
      expect(restored.toMarkdown(), isEmpty);
    },
  );

  test(
    'moving across columns and back retains the full subtree and history',
    () {
      final attachment = BlockPageBlock.create(
        type: 'attachment',
        text: 'Data',
      );
      final media = BlockPageMediaAsset.attachment(
        name: 'table.csv',
        bytes: [1, 2],
      );
      final container = BlockPageBlock.create(
        type: 'toggle',
        text: 'Evidence',
      ).copyWith(children: [attachment]);
      final before = BlockPageBlock.create(text: 'Before');
      final after = BlockPageBlock.create(text: 'After');
      final group = BlockPageBlock.createColumns();
      final other = BlockPageBlock.createColumns();
      final left = group.children.first.id;
      final right = other.children.last.id;
      final original = const BlockPageDocument.empty().copyWith(
        blocks: [before, container, group, other, after],
        media: {attachment.id: media.reference},
      );

      final inLeft = original.moveBlockToColumn(
        blockId: container.id,
        columnId: left,
      );
      final inRight = inLeft.moveBlockToColumn(
        blockId: container.id,
        columnId: right,
      );
      final back = inRight.moveBlockToColumn(
        blockId: container.id,
        columnId: null,
      );

      expect(inLeft.blocks[1].children.first.children.single, same(container));
      expect(inRight.blocks[1].children.first.children, isEmpty);
      expect(inRight.blocks[2].children.last.children.single, same(container));
      expect(back.blocks, [
        before,
        inRight.blocks[1],
        back.blocks[2],
        container,
        after,
      ]);
      expect(back.blocks[2].children.last.children, isEmpty);
      expect(original.blocks, [before, container, group, other, after]);
      for (final page in [inLeft, inRight, back]) {
        expect(page.media[attachment.id], same(media.reference));
        expect(page.version, original.version);
        final reopened = BlockPageDocument.fromJson(page.toJson());
        expect(reopened.toJson(), page.toJson());
        reopened.media[attachment.id]!.verifyBytes(media.bytes);
      }
      final diff = BlockPageHistoryDiff.compare(inLeft, inRight);
      final moved = diff.changes.singleWhere(
        (change) => change.blockId == container.id,
      );
      expect(moved.beforeParentId, left);
      expect(moved.afterParentId, right);
      expect(moved.kinds, {BlockPageChangeKind.moved});
      expect(
        diff.changes.any((change) => change.blockId == attachment.id),
        isFalse,
      );
      expect(diff.pageMetadataChanged, isFalse);
    },
  );

  test('unwrapping keeps stable content IDs in visual order', () {
    final first = BlockPageBlock.create(text: 'First');
    final second = BlockPageBlock.create(text: 'Second');
    final group = BlockPageBlock.createColumns();
    final filled = group.copyWith(
      children: [
        group.children.first.copyWith(children: [first]),
        group.children.last.copyWith(children: [second]),
      ],
    );
    final trailing = BlockPageBlock.create(text: 'Trailing');
    final page = const BlockPageDocument.empty().copyWith(
      blocks: [filled, trailing],
    );

    expect(page.unwrapColumns(filled.id).blocks, [first, second, trailing]);
    expect(page.unwrapColumns(trailing.id), same(page));
    expect(page.blocks, [filled, trailing]);
  });

  test(
    'legacy and malformed wrappers keep their original meaning and data',
    () {
      final legacy = _layout([_block('paragraph', text: 'Legacy child')], [])
        ..remove('columnLayout')
        ..['text'] = 'Legacy container';
      final extra = _layout([], [])..['vendor'] = {'state': 7};
      final invalidVersion = _layout([], [])..['columnLayout'] = 1.0;
      final nestedWrappers = _layout([_layout([], [])], []);
      final unmarkedPane = _layout([], []);
      ((unmarkedPane['children'] as List).last as Map).remove('columnLayout');
      final normal = BlockPageBlock.create(text: 'Normal');
      final json = {
        'version': 1,
        'blocks': [
          normal.toJson(),
          legacy,
          extra,
          invalidVersion,
          nestedWrappers,
          unmarkedPane,
        ],
      };
      final page = BlockPageDocument.fromJson(json);
      final wrappers = page.blocks.skip(1);

      expect(wrappers.every((block) => !block.isColumnLayout), isTrue);
      expect(
        page.toMarkdown(),
        contains('Legacy container\n  \n    Legacy child'),
      );
      expect(BlockPageDocument.fromJson(page.toJson()).toJson(), page.toJson());
      for (final wrapper in wrappers) {
        expect(page.unwrapColumns(wrapper.id), same(page));
        expect(
          page.moveBlockToColumn(
            blockId: normal.id,
            columnId: wrapper.children.first.id,
          ),
          same(page),
        );
      }
      expect(page.blocks[2].toJson()['vendor'], {'state': 7});
    },
  );

  test('stale, nested and structurally invalid moves are identity no-ops', () {
    final group = BlockPageBlock.createColumns();
    final direct = BlockPageBlock.create(text: 'Direct');
    final nested = BlockPageBlock.create(text: 'Nested');
    final parent = BlockPageBlock.create(type: 'toggle')
        .copyWith(children: [nested]);
    final left = group.children.first.copyWith(children: [direct]);
    final right = group.children.last;
    final page = const BlockPageDocument.empty().copyWith(
      blocks: [
        group.copyWith(children: [left, right]),
        parent,
      ],
    );

    for (final (source, destination) in [
      (direct.id, left.id),
      (nested.id, right.id),
      (group.id, right.id),
      (left.id, right.id),
      (direct.id, group.id),
      (direct.id, newId()),
      (newId(), right.id),
      (parent.id, null),
    ]) {
      expect(
        page.moveBlockToColumn(blockId: source, columnId: destination),
        same(page),
      );
    }
  });

  test('moving an existing deep subtree cannot create an invalid page', () {
    var tree = BlockPageBlock.create(text: 'Depth 64');
    for (var depth = 0; depth < 64; depth++) {
      tree = BlockPageBlock.create(type: 'toggle').copyWith(children: [tree]);
    }
    final group = BlockPageBlock.createColumns();
    final page = const BlockPageDocument.empty().copyWith(
      blocks: [tree, group],
    );

    expect(
      page.moveBlockToColumn(
        blockId: tree.id,
        columnId: group.children.first.id,
      ),
      same(page),
    );
  });
}

Map<String, dynamic> _block(String type, {String text = '', String? noteId}) =>
    {'id': newId(), 'type': type, 'text': text, 'noteId': ?noteId};

Map<String, dynamic> _layout(
  List<Map<String, dynamic>> first,
  List<Map<String, dynamic>> second,
) => {
  ..._block('columnList'),
  'columnLayout': 1,
  'children': [
    for (final blocks in [first, second])
      {..._block('column'), 'columnLayout': 1, 'children': blocks},
  ],
};
