import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/vault/block_inline_text.dart';
import 'package:saber/data/vault/block_page_document.dart';
import 'package:saber/data/vault/block_page_media.dart';
import 'package:saber/data/vault/note_link.dart';

Map<String, dynamic> withoutIds(BlockPageBlock block) => {
  ...block.toJson()..remove('id'),
  if (block.children.isNotEmpty)
    'children': block.children.map(withoutIds).toList(),
};

Iterable<String> ids(BlockPageBlock block) sync* {
  yield block.id;
  for (final child in block.children) {
    yield* ids(child);
  }
}

void main() {
  test('duplicates a nested block beside its source with fresh IDs', () {
    final target = BlockPageBlock.create(type: 'toggle', text: 'target');
    final link = NoteLink.markdown(target.id).toString();
    final styled = BlockPageBlock.create(text: '서식과 링크').copyWith(
      inlineText: BlockInlineText.plain('서식과 링크')
          .toggleMark(0, 2, InlineMark.bold)
          .setLink(4, 6, link),
    );
    final attachment = BlockPageBlock.create(type: 'attachment', text: '자료');
    final descriptor = BlockPageMediaAsset.attachment(
      name: 'example.txt',
      bytes: [11, 22, 33],
    ).reference;
    final table = BlockPageBlock.createTable(text: '표');
    final source = target.copyWith(children: [styled, attachment, table]);
    final before = BlockPageBlock.create(text: 'before');
    final after = BlockPageBlock.create(text: 'after');
    final container = BlockPageBlock.create(type: 'toggle')
        .copyWith(children: [before, source, after]);
    final other = BlockPageBlock.create(text: 'outside');
    final page = const BlockPageDocument.empty().copyWith(
      blocks: [container, other],
      media: {attachment.id: descriptor},
    );
    final original = page.toJson();

    expect(source.canDuplicate, isTrue);
    final duplicated = page.duplicateBlock(source.id);
    final siblings = duplicated.blocks.first.children;
    final copy = siblings[2];
    expect(siblings, [before, source, copy, after]);
    expect(duplicated.blocks.last, same(other));
    expect(withoutIds(copy), withoutIds(source));
    expect(ids(copy).toSet(), hasLength(4));
    expect(ids(copy).toSet().intersection(ids(container).toSet()), isEmpty);
    expect(copy.children.first.inlineText!.runs.last.link, link);
    expect(copy.children.first.copyWith(text: '별개').text, '별개');
    expect(styled.text, '서식과 링크');
    expect(duplicated.media[attachment.id], same(descriptor));
    expect(duplicated.media[copy.children[1].id], same(descriptor));
    final reopened = BlockPageDocument.fromJson(duplicated.toJson());
    expect(reopened.version, 3);
    expect(reopened.toJson(), duplicated.toJson());
    expect(page.toJson(), original);
  });

  test(
    'duplicates a whole column layout and permits copies inside a column',
    () {
      final columns = BlockPageBlock.createColumns();
      final child = BlockPageBlock.create(text: 'inside');
      final group = columns.copyWith(
        children: [
          columns.children.first.copyWith(children: [child]),
          columns.children.last,
        ],
      );
      final page = const BlockPageDocument.empty().copyWith(blocks: [group]);

      expect(group.canDuplicate, isTrue);
      expect(group.children.first.canDuplicate, isFalse);
      expect(
        () => page.duplicateBlock(group.children.first.id),
        throwsFormatException,
      );
      final layout = page.duplicateBlock(group.id).blocks.last;
      expect(layout.isColumnLayout, isTrue);
      expect(withoutIds(layout), withoutIds(group));
      expect(ids(layout).toSet().intersection(ids(group).toSet()), isEmpty);

      final inner = page.duplicateBlock(child.id).blocks.single;
      expect(inner.children.first.children.map((block) => block.text), [
        'inside',
        'inside',
      ]);
      expect(inner.children.last, same(group.children.last));
    },
  );

  test(
    'retains unrelated opaque metadata and refuses ambiguous copied references',
    () {
      final rootId = newId(), childId = newId(), otherId = newId();
      BlockPageDocument page(Object? extra, {String childType = 'paragraph'}) =>
          BlockPageDocument.fromJson({
            'version': 1,
            'blocks': [
              {
                'id': rootId,
                'type': 'toggle',
                'text': childId,
                'future': extra,
                'children': [
                  {'id': childId, 'type': childType},
                ],
              },
              {'id': otherId, 'type': 'paragraph'},
            ],
          });

      final supported = page({'unrelated': otherId});
      final duplicate = supported.duplicateBlock(rootId);
      expect(duplicate.blocks[1].toJson()['future'], {'unrelated': otherId});
      expect(duplicate.blocks[1].text, childId);
      for (final unsupported in [
        page({'pointer': 'future:${childId.toUpperCase()}'}),
        page({childId: true}),
        page(null, childType: 'linkedDatabase'),
        page(null, childType: 'syncedBlock'),
      ]) {
        final original = unsupported.toJson();
        expect(unsupported.blocks.first.canDuplicate, isFalse);
        expect(() => unsupported.duplicateBlock(rootId), throwsFormatException);
        expect(unsupported.toJson(), original);
      }
      expect(() => supported.duplicateBlock(newId()), throwsFormatException);
    },
  );

  test(
    'refuses opaque identities nested in typed data or media descriptors',
    () {
      final original = BlockPageBlock.create(text: 'sample');
      final inline = BlockInlineText.plain(original.text)
          .toggleMark(0, 2, InlineMark.bold)
          .toJson();
      final run = (inline['runs'] as List).single as Map;
      run['futureReference'] = original.id;
      final inlinePage = BlockPageDocument.fromJson({
        'version': 3,
        'blocks': [
          {...original.toJson(), 'inlineData': inline},
        ],
      });
      expect(inlinePage.blocks.single.canDuplicate, isFalse);
      expect(
        () => inlinePage.duplicateBlock(original.id),
        throwsFormatException,
      );

      final table = BlockPageBlock.createTable();
      final tableData = table.table!.toJson();
      final row = (tableData['rows'] as List).first as Map;
      final cell = (row['cells'] as List).first as Map;
      cell['futureReference'] = [table.id];
      final tablePage = BlockPageDocument.fromJson({
        'version': 1,
        'blocks': [
          {...table.toJson(), 'tableData': tableData},
        ],
      });
      expect(tablePage.blocks.single.canDuplicate, isFalse);
      expect(() => tablePage.duplicateBlock(table.id), throwsFormatException);

      final attachment = BlockPageBlock.create(type: 'attachment');
      final descriptor = BlockPageMediaAsset.attachment(
        name: 'document.txt',
        bytes: [1, 2],
      ).reference.toJson();
      final mediaPage = const BlockPageDocument.empty().copyWith(
        blocks: [attachment],
        media: {
          attachment.id: BlockPageMedia.fromJson({
            ...descriptor,
            'futureReference': {attachment.id: 'metadata'},
          }),
        },
      );
      expect(
        () => mediaPage.duplicateBlock(attachment.id),
        throwsFormatException,
      );
      expect(mediaPage.media[attachment.id]!.toJson()['futureReference'], {
        attachment.id: 'metadata',
      });
    },
  );

  test('fails atomically at the existing page size limit', () {
    final blocks = List.generate(10000, (i) => BlockPageBlock.create());
    final page = const BlockPageDocument.empty().copyWith(blocks: blocks);
    expect(() => page.duplicateBlock(blocks.first.id), throwsFormatException);
    expect(page.blocks, blocks);
  });
}
