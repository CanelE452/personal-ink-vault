import 'dart:convert';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/vault/block_page_document.dart';
import 'package:saber/data/vault/discussion_anchor.dart';

const pageId = '10000000-0000-4000-8000-000000000001';
const otherPageId = '10000000-0000-4000-8000-000000000002';
const blockId = '10000000-0000-4000-8000-000000000003';
const copyId = '10000000-0000-4000-8000-000000000004';
const parentId = '10000000-0000-4000-8000-000000000005';

BlockPageBlock block(
  String text, {
  String id = blockId,
  String type = 'paragraph',
}) => BlockPageBlock.fromJson({'id': id, 'type': type, 'text': text});
BlockPageDocument document(List<BlockPageBlock> blocks) =>
    const BlockPageDocument.empty().copyWith(blocks: blocks);
DiscussionAnchor whole(BlockPageDocument source) =>
    DiscussionAnchor.block(pageId: pageId, document: source, blockId: blockId);
DiscussionAnchor quote(BlockPageDocument source, int start, int end) =>
    DiscussionAnchor.quote(
      pageId: pageId,
      document: source,
      blockId: blockId,
      startUtf16: start,
      endUtf16: end,
    );
DiscussionAnchorStatus status(
  DiscussionAnchor anchor,
  BlockPageDocument? source, {
  String page = pageId,
}) => anchor.resolve(pageId: page, document: source);
DiscussionAnchor reload(DiscussionAnchor anchor) =>
    DiscussionAnchor.fromJson(jsonDecode(jsonEncode(anchor.toJson())));

void checkEqual(Object? actual, Object? expected) => expect(actual, expected);

void throwsFormat(void Function() body) => expect(body, throwsFormatException);

void main() {
  test('page and block JSON round trip and stay on their original page', () {
    final source = document([block('before')]);
    final page = DiscussionAnchor.page(pageId: pageId);
    final anchored = whole(source);
    checkEqual(
      jsonEncode(page.toJson()),
      jsonEncode({'version': 1, 'kind': 'page', 'pageId': pageId}),
    );
    checkEqual(
      jsonEncode(anchored.toJson()),
      jsonEncode({
        'version': 1,
        'kind': 'block',
        'pageId': pageId,
        'blockId': blockId,
      }),
    );
    for (final anchor in [page, anchored]) {
      final loaded = reload(anchor);
      checkEqual(jsonEncode(loaded.toJson()), jsonEncode(anchor.toJson()));
      checkEqual(status(loaded, source), DiscussionAnchorStatus.attached);
      checkEqual(
        status(loaded, source, page: otherPageId),
        DiscussionAnchorStatus.missingPage,
      );
      checkEqual(status(loaded, null), DiscussionAnchorStatus.missingPage);
    }
    checkEqual(
      status(anchored, document([block('after')])),
      DiscussionAnchorStatus.attached,
    );
    checkEqual(status(page, document([])), DiscussionAnchorStatus.attached);
  });

  test(
    'both block anchors follow actual two-column moves and nested children',
    () {
      final layout = BlockPageBlock.createColumns();
      final source = document([block('한국어 댓글'), layout]);
      final moved = source.moveBlockToColumn(
        blockId: blockId,
        columnId: layout.children.last.id,
      );
      checkEqual(moved.blocks.length, 1);
      checkEqual(moved.blocks.single.children.last.children.single.id, blockId);
      final nested = document([
        block('parent', id: parentId).copyWith(children: [moved.blocks.single]),
      ]);
      for (final anchor in [whole(source), quote(source, 0, 3)]) {
        checkEqual(status(anchor, moved), DiscussionAnchorStatus.attached);
        checkEqual(status(anchor, nested), DiscussionAnchorStatus.attached);
      }
    },
  );

  test('a same-text copy cannot inherit a deleted block anchor', () {
    final source = document([block('repeat')]);
    for (final anchor in [whole(source), quote(source, 0, 6)]) {
      checkEqual(
        status(anchor, document([])),
        DiscussionAnchorStatus.missingBlock,
      );
      checkEqual(
        status(anchor, document([block('repeat', id: copyId)])),
        DiscussionAnchorStatus.missingBlock,
      );
    }
    throwsFormat(() => whole(document([])));
    throwsFormat(() => quote(document([]), 0, 1));
  });

  test('the real model rejects duplicate IDs across nested containers', () {
    throwsFormat(
      () => document([
        block('first'),
        block('parent', id: parentId).copyWith(children: [block('second')]),
      ]),
    );
  });

  test('table, image and code permit whole-block anchors', () {
    for (final type in ['table', 'image', 'code']) {
      final source = document([block('caption', type: type)]);
      checkEqual(
        status(whole(source), source),
        DiscussionAnchorStatus.attached,
      );
      throwsFormat(() => quote(source, 0, 1));
    }
  });

  test('Korean and multi-unit graphemes preserve exact repeated selection and hash', () {
    const selected = '한🙂e\u0301👩‍👩‍👧‍👦';
    const prefix = '$selected | ';
    const text = '$prefix$selected';
    final source = document([block(text)]);
    final anchor = quote(source, prefix.length, text.length);
    checkEqual(
      jsonEncode(anchor.toJson()),
      jsonEncode({
        'version': 1,
        'kind': 'quote',
        'pageId': pageId,
        'blockId': blockId,
        'startUtf16': prefix.length,
        'endUtf16': text.length,
        'quote': selected,
        'blockTextSha256': sha256.convert(utf8.encode(text)).toString(),
      }),
    );
    checkEqual(
      jsonEncode(reload(anchor).toJson()),
      jsonEncode(anchor.toJson()),
    );
    checkEqual(status(reload(anchor), source), DiscussionAnchorStatus.attached);
  });

  test('selection cannot split surrogate, accent, ZWJ or CRLF clusters', () {
    const text = '한🙂e\u0301👩‍👩‍👧‍👦\r\n';
    final source = document([block(text)]);
    for (final (start, end) in [
      (0, 2),
      (2, 3),
      (3, 4),
      (5, 7),
      (0, text.length - 1),
    ]) {
      throwsFormat(() => quote(source, start, end));
    }
    checkEqual(quote(source, 1, 3).toJson()['quote'], '🙂');
  });

  test('invalid selection bounds are rejected', () {
    final source = document([block('한글')]);
    for (final (start, end) in [(-1, 1), (2, 1), (1, 1), (1, 3), (3, 4)]) {
      throwsFormat(() => quote(source, start, end));
    }
  });

  test('quote length is bounded in both creation and decoding', () {
    const max = DiscussionAnchor.maxQuoteUtf16;
    final text = List.filled(max + 1, '한').join();
    final source = document([block(text)]);
    final atLimit = quote(source, 0, max).toJson();
    checkEqual((atLimit['quote'] as String).length, max);
    throwsFormat(() => quote(source, 0, max + 1));
    throwsFormat(
      () => DiscussionAnchor.fromJson({
        ...atLimit,
        'endUtf16': max + 1,
        'quote': text,
      }),
    );
  });

  test(
    'text edits detach the quote until the exact original block text returns',
    () {
      const text = '앞 | 인용 | 인용';
      final source = document([block(text)]);
      final anchor = quote(source, text.lastIndexOf('인용'), text.length);
      for (final changed in ['뒤 | 인용 | 인용', '인용', '$text!']) {
        checkEqual(
          status(anchor, document([block(changed)])),
          DiscussionAnchorStatus.changedQuote,
        );
      }
      checkEqual(
        status(anchor, document([block(text)])),
        DiscussionAnchorStatus.attached,
      );
      final malformed = document([block(text + String.fromCharCode(0xd800))]);
      throwsFormat(() => quote(malformed, 0, 1));
      checkEqual(
        status(anchor, malformed),
        DiscussionAnchorStatus.changedQuote,
      );
      final forged = DiscussionAnchor.fromJson({
        ...anchor.toJson(),
        'startUtf16': 0,
        'endUtf16': 2,
      });
      checkEqual(status(forged, source), DiscussionAnchorStatus.changedQuote);
    },
  );

  test(
    'wire objects reject invalid variant, UUID, type, range, hash and UTF-16',
    () {
      final good = quote(document([block('한글')]), 0, 2).toJson();
      for (final bad in <Object?>[
        null,
        ['not an object'],
        {...good, 'version': 1.0},
        {...good, 'version': 2},
        {...good, 'kind': 'other'},
        {...good, 'pageId': '../other'},
        {...good, 'blockId': null},
        {...good, 'startUtf16': 0.0},
        {...good, 'startUtf16': -1},
        {...good, 'endUtf16': 1},
        {...good, 'endUtf16': 0, 'quote': ''},
        {...good, 'quote': true},
        {...good, 'quote': '한${String.fromCharCode(0xd800)}'},
        {
          ...good,
          'blockTextSha256': (good['blockTextSha256'] as String).toUpperCase(),
        },
        {...good, 'blockTextSha256': 'ab'},
        {...good, 'extra': null},
        {...good}..remove('quote'),
        {...good, 'kind': 'page'},
        {'version': 1, 'kind': 'block', 'pageId': pageId},
      ]) {
        throwsFormat(() => DiscussionAnchor.fromJson(bad));
      }
      throwsFormat(() => DiscussionAnchor.page(pageId: 'invalid'));
    },
  );

  test(
    'creation rejects a whitespace-only quote and keeps the block anchor',
    () {
      const whitespace = ' \t\n\u00a0';
      final source = document([block(whitespace)]);
      checkEqual(
        status(whole(source), source),
        DiscussionAnchorStatus.attached,
      );
      throwsFormat(() => quote(source, 0, whitespace.length));
      const visible = ' 한 ';
      checkEqual(
        quote(document([block(visible)]), 0, visible.length).toJson()['quote'],
        visible,
      );
    },
  );

  test('wire decoder rejects a whitespace-only quote', () {
    final valid = quote(document([block('한글')]), 0, 2).toJson();
    throwsFormat(() => DiscussionAnchor.fromJson({...valid, 'quote': ' \t'}));
  });
}
