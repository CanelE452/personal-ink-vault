import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:markdown/markdown.dart' as markdown;
import 'package:saber/data/vault/block_inline_text.dart';
import 'package:saber/data/vault/block_page_document.dart';
import 'package:saber/data/vault/block_page_history.dart';
import 'package:saber/data/vault/block_page_snapshot.dart';
import 'package:saber/data/vault/database_media_snapshot.dart';
import 'package:saber/data/vault/note_link.dart';
import 'package:saber/data/vault/structured_document_text.dart';
import 'package:saber/data/vault/workspace_database.dart';

Map<String, dynamic> _page({String text = 'alphabet 한글😀', int version = 3}) =>
    {
      'version': version,
      'futurePage': {'keep': true},
      'blocks': [
        {
          'id': newId(),
          'type': 'paragraph',
          'text': text,
          'inlineData': {
            'format': 'personal-ink-inline-1',
            'textSha256': sha256.convert(utf8.encode(text)).toString(),
            'futureInline': ['retained'],
            'runs': [
              {
                'start': 2,
                'end': 5,
                'marks': ['bold', 'underline'],
              },
            ],
          },
        },
      ],
    };

Map<String, dynamic> _inline(Map<String, dynamic> page) =>
    ((page['blocks'] as List).single as Map)['inlineData']
        as Map<String, dynamic>;

Uint8List _bytes(Map<String, dynamic> json) =>
    Uint8List.fromList(utf8.encode(jsonEncode(json)));

void main() {
  test('v3 inline styles and opaque data survive snapshot save and reopen', () {
    final json = _page();
    final document = BlockPageDocument.fromJson(json);
    final saved = BlockPageMediaSnapshot.prepare(
      document,
      existingFiles: {
        'page.json': _bytes(json),
        'future/payload.bin': Uint8List.fromList([0, 255, 17]),
      },
    );
    final reopened = BlockPageMediaSnapshot.fromFiles(saved.files);
    expect(_inline(reopened.document.toJson()), _inline(json));
    expect(reopened.document.version, 3);
    expect(reopened.files['future/payload.bin'], [0, 255, 17]);
    expect(reopened.document.toMarkdown(), contains('**'));
  });

  test('v3 known inline digest, marks and grapheme ranges are validated', () {
    BlockPageDocument.fromJson(_page());
    for (final mutate in <void Function(Map<String, dynamic>)>[
      (data) => data['textSha256'] = '0' * 64,
      (data) => ((data['runs'] as List).single as Map)['end'] = 999,
      (data) => ((data['runs'] as List).single as Map)['marks'] = ['future'],
    ]) {
      final json = _page();
      mutate(_inline(json));
      expect(() => BlockPageDocument.fromJson(json), throwsFormatException);
    }
    final emoji = _page(text: 'ab👩‍💻cd');
    _inline(emoji)['runs'] = [
      {
        'start': 2,
        'end': 3,
        'marks': ['bold'],
      },
    ];
    expect(() => BlockPageDocument.fromJson(emoji), throwsFormatException);
  });

  test('ordinary text copy rebases styles and refreshes the digest', () {
    final page = BlockPageDocument.fromJson(_page());
    final changed = page.copyWith(
      blocks: [page.blocks.single.copyWith(text: 'XXalphabet 한글😀')],
    );
    final data = _inline(changed.toJson());
    expect(
      data['textSha256'],
      sha256.convert(utf8.encode('XXalphabet 한글😀')).toString(),
    );
    expect(data['runs'], [
      {
        'start': 4,
        'end': 7,
        'marks': ['bold', 'underline'],
      },
    ]);
    expect(data['futureInline'], ['retained']);
  });

  test(
    'v1 and v2 inlineData stays opaque even with a familiar format marker',
    () {
      for (final version in [1, 2]) {
        final json = _page(version: version);
        _inline(json)['textSha256'] = 'old opaque digest';
        _inline(json)['runs'] = 'old opaque runs';
        final page = BlockPageDocument.fromJson(json);
        final edited = page.copyWith(
          blocks: [page.blocks.single.copyWith(text: 'changed')],
        );
        expect(_inline(edited.toJson()), _inline(json));
        expect(edited.version, version);
      }
    },
  );

  test(
    'page v3 downgrade refuses publication and leaves source files intact',
    () {
      final json = _page();
      final old = BlockPageDocument.fromJson(json);
      final files = BlockPageMediaSnapshot.prepare(old).files;
      final downgraded = {...json, 'version': 2};
      expect(
        () => BlockPageMediaSnapshot.prepare(
          BlockPageDocument.fromJson(downgraded),
          existingFiles: files,
        ),
        throwsFormatException,
      );
      expect(
        BlockPageMediaSnapshot.fromFiles(files).document.toJson(),
        old.toJson(),
      );
    },
  );

  test('database row v3 downgrade refuses an ordinary database save', () {
    final page = _page();
    final row = DatabaseRow.create(body: page);
    final database = WorkspaceDatabase.empty().addRow(row);
    final files = DatabaseMediaSnapshot.prepare(database).files;
    final changed = database.updateRow(
      row.copyWith(body: {...page, 'version': 2}),
    );
    expect(
      () => DatabaseMediaSnapshot.prepare(changed, existingFiles: files),
      throwsFormatException,
    );
    expect(
      DatabaseMediaSnapshot.fromFiles(files).database.toJson(),
      database.toJson(),
    );
  });

  test(
    'structured search keeps whole words and projects inline note links',
    () {
      final json = _page();
      final linkedId = newId();
      ((_inline(json)['runs'] as List).single as Map)['link'] =
          'inkvault://note/$linkedId';
      final text = structuredDocumentText('page', {'page.json': _bytes(json)});
      expect(text, contains('alphabet 한글😀'));
      expect(text, contains('inkvault://note/$linkedId'));
      expect(text, contains('inkvault://note/$linkedId?view=markdown'));
      expect(text, contains('[inline-document]('));
      expect(text, isNot(contains('**')));
    },
  );

  test(
    'overlap toggles preserve mixed marks and merge matching adjacent ranges',
    () {
      var inline = BlockInlineText.plain('abcdef');
      inline = inline.toggleMark(0, 4, InlineMark.bold);
      inline = inline.toggleMark(2, 6, InlineMark.italic);
      expect(inline.runs.map((run) => [run.start, run.end, run.marks]), [
        [
          0,
          2,
          {InlineMark.bold},
        ],
        [
          2,
          4,
          {InlineMark.bold, InlineMark.italic},
        ],
        [
          4,
          6,
          {InlineMark.italic},
        ],
      ]);
      expect(inline.hasMark(0, 6, InlineMark.bold), false);
      inline = inline.toggleMark(0, 6, InlineMark.bold);
      expect(inline.hasMark(0, 6, InlineMark.bold), true);
      expect(inline.runs.length, 2);
      inline = inline.toggleMark(0, 6, InlineMark.bold);
      expect(inline.runs.single.start, 2);
      expect(inline.runs.single.end, 6);
      expect(inline.runs.single.marks, {InlineMark.italic});
    },
  );

  test('format selections expand to whole emoji and combining graphemes', () {
    const text = '가👩‍💻e\u0301한끝';
    final inline = BlockInlineText.plain(text)
        .toggleMark(2, 3, InlineMark.bold);
    expect(inline.runs.single.start, 1);
    expect(inline.runs.single.end, 6);
    expect(inline.segments.map((segment) => segment.text).join(), text);
    final combined = inline.toggleMark(7, 8, InlineMark.underline);
    expect(combined.runs.last.start, 6);
    expect(combined.runs.last.end, 8);
    expect(
      () => BlockInlineText.fromJson(combined.toJson(), text: text),
      returnsNormally,
    );
  });

  test('insertion inherits left marks or initial right marks without expanding link boundaries', () {
    final inline = BlockInlineText.plain('word')
        .toggleMark(0, 4, InlineMark.bold)
        .setLink(0, 4, 'https://example.com/a');
    final start = inline.replaceText(
      'Xword',
      selectionStart: 0,
      selectionEnd: 0,
    );
    expect(start.hasMark(0, 1, InlineMark.bold), true);
    expect(start.runs.first.link, null);
    expect(start.runs.last.link, 'https://example.com/a');
    final end = inline.replaceText('wordX', selectionStart: 4, selectionEnd: 4);
    expect(end.runs.last.link, null);
    expect(end.runs.last.marks, {InlineMark.bold});
    final middle = inline.replaceText(
      'woXrd',
      selectionStart: 2,
      selectionEnd: 2,
    );
    expect(middle.runs.single.link, 'https://example.com/a');
    expect(middle.runs.single.end, 5);
  });

  test('selection disambiguates repeated text insertions and deletions', () {
    final inline = BlockInlineText.plain('aaaa')
        .toggleMark(1, 2, InlineMark.bold);
    final inserted = inline.replaceText(
      'aaaaa',
      selectionStart: 0,
      selectionEnd: 0,
    );
    expect(inserted.runs.single.start, 2);
    expect(inserted.runs.single.end, 3);
    final deleted = inline.replaceText(
      'aaa',
      selectionStart: 0,
      selectionEnd: 1,
    );
    expect(deleted.runs.single.start, 0);
    expect(deleted.runs.single.end, 1);
    final unstyled = inline.replaceText(
      'aaa',
      selectionStart: 1,
      selectionEnd: 2,
    );
    expect(unstyled.runs, isEmpty);
  });

  test(
    'independent edits retain formatting on unchanged middle and tail text',
    () {
      final inline = BlockInlineText.plain('abc DEF ghi JKL')
          .toggleMark(4, 7, InlineMark.bold)
          .toggleMark(12, 15, InlineMark.italic);
      final changed = inline.replaceText('Xbc DEF ghY JKL');
      expect(changed.hasMark(4, 7, InlineMark.bold), true);
      expect(changed.hasMark(12, 15, InlineMark.italic), true);
      expect(
        changed.segments.map((segment) => segment.text).join(),
        'Xbc DEF ghY JKL',
      );
      final repeated = BlockInlineText.plain('XaaaaaY')
          .toggleMark(1, 6, InlineMark.underline)
          .replaceText('ZaaaaaW');
      expect(repeated.hasMark(1, 6, InlineMark.underline), true);
    },
  );

  test('Hangul IME grapheme replacement preserves marks and valid runs', () {
    final inline = BlockInlineText.plain('ㅎ 끝')
        .toggleMark(0, 1, InlineMark.bold)
        .toggleMark(2, 3, InlineMark.underline);
    final changed = inline.replaceText(
      '한 끝',
      selectionStart: 0,
      selectionEnd: 1,
    );
    expect(changed.hasMark(0, 1, InlineMark.bold), true);
    expect(changed.hasMark(2, 3, InlineMark.underline), true);
    final zwj = BlockInlineText.plain('👩X')
        .toggleMark(0, 2, InlineMark.bold)
        .replaceText('👩‍💻X', selectionStart: 0, selectionEnd: 2);
    expect(zwj.runs.single.end, 5);
    expect(
      () => BlockInlineText.fromJson(zwj.toJson(), text: zwj.text),
      returnsNormally,
    );
  });

  test('caret combining insertion preserves marks on the merged grapheme', () {
    final inline = BlockInlineText.plain('aX')
        .toggleMark(0, 1, InlineMark.bold);
    final changed = inline.replaceText(
      'a\u0301X',
      selectionStart: 1,
      selectionEnd: 1,
    );
    expect(changed.text, 'a\u0301X');
    expect(changed.runs.single.start, 0);
    expect(changed.runs.single.end, 2);
    expect(changed.hasMark(0, 2, InlineMark.bold), true);
    expect(
      () => BlockInlineText.fromJson(changed.toJson(), text: changed.text),
      returnsNormally,
    );
  });

  test('caret ZWJ insertion preserves marks on the complete joined emoji', () {
    final inline = BlockInlineText.plain('👩X')
        .toggleMark(0, 2, InlineMark.bold);
    final changed = inline.replaceText(
      '👩‍💻X',
      selectionStart: 2,
      selectionEnd: 2,
    );
    expect(changed.text, '👩‍💻X');
    expect(changed.runs.single.start, 0);
    expect(changed.runs.single.end, 5);
    expect(changed.hasMark(0, 5, InlineMark.bold), true);
    expect(
      () => BlockInlineText.fromJson(changed.toJson(), text: changed.text),
      returnsNormally,
    );
  });

  test('middle combining insertion keeps the replaced grapheme style', () {
    final inline = BlockInlineText.plain('XaY')
        .toggleMark(1, 2, InlineMark.bold);
    final changed = inline.replaceText(
      'Xa\u0301Y',
      selectionStart: 2,
      selectionEnd: 2,
    );
    expect(changed.text, 'Xa\u0301Y');
    expect(changed.runs.single.start, 1);
    expect(changed.runs.single.end, 3);
    expect(changed.runs.single.marks, {InlineMark.bold});
    expect(
      () => BlockInlineText.fromJson(changed.toJson(), text: changed.text),
      returnsNormally,
    );
  });

  test('middle ZWJ insertion keeps emoji style between plain neighbors', () {
    final inline = BlockInlineText.plain('X👩Y')
        .toggleMark(1, 3, InlineMark.italic);
    final changed = inline.replaceText(
      'X👩‍💻Y',
      selectionStart: 3,
      selectionEnd: 3,
    );
    expect(changed.text, 'X👩‍💻Y');
    expect(changed.runs.single.start, 1);
    expect(changed.runs.single.end, 6);
    expect(changed.runs.single.marks, {InlineMark.italic});
    expect(
      () => BlockInlineText.fromJson(changed.toJson(), text: changed.text),
      returnsNormally,
    );
  });

  test('middle Hangul composing replacement inherits its own style', () {
    final inline = BlockInlineText.plain('XㅎY')
        .toggleMark(1, 2, InlineMark.underline);
    final changed = inline.replaceText(
      'X한Y',
      selectionStart: 1,
      selectionEnd: 2,
    );
    expect(changed.text, 'X한Y');
    expect(changed.runs.single.start, 1);
    expect(changed.runs.single.end, 2);
    expect(changed.runs.single.marks, {InlineMark.underline});
    expect(changed.hasMark(0, 1, InlineMark.underline), false);
    expect(changed.hasMark(2, 3, InlineMark.underline), false);
  });

  test(
    'replacing a complete linked selection preserves its marks and link',
    () {
      final inline = BlockInlineText.plain('XwordY')
          .toggleMark(1, 5, InlineMark.bold)
          .setLink(1, 5, 'https://example.com/selection');
      final changed = inline.replaceText(
        'XnewY',
        selectionStart: 1,
        selectionEnd: 5,
      );
      expect(changed.text, 'XnewY');
      expect(changed.runs.single.start, 1);
      expect(changed.runs.single.end, 4);
      expect(changed.runs.single.marks, {InlineMark.bold});
      expect(changed.runs.single.link, 'https://example.com/selection');
      expect(changed.segments.first.text, 'X');
      expect(changed.segments.last.text, 'Y');
      final crossing = inline.replaceText(
        'Xnew',
        selectionStart: 1,
        selectionEnd: 6,
      );
      expect(crossing.runs.single.link, null);
      expect(crossing.runs.single.marks, {InlineMark.bold});
    },
  );

  test(
    'clear formatting preserves unrelated runs and original literal text',
    () {
      final inline = BlockInlineText.plain('ab\ncd <script>&*tail')
          .toggleMark(0, 7, InlineMark.bold)
          .toggleMark(7, 15, InlineMark.code)
          .setLink(0, 2, 'https://example.com/?a=1&b=2');
      final changed = inline.clearFormatting(1, 5);
      expect(changed.text, inline.text);
      expect(changed.hasMark(0, 1, InlineMark.bold), true);
      expect(changed.hasMark(1, 5, InlineMark.bold), false);
      expect(changed.hasMark(7, 15, InlineMark.code), true);
      expect(changed.toHtml(), isNot(contains('<script>')));
      expect(changed.toHtml(), contains('&amp;'));
      expect(changed.toMarkdown(), contains('tail'));
      expect(changed.toMarkdown().split('\n').length, 2);
    },
  );

  test('unsafe input links and unsafe export callback destinations never become active', () {
    final inline = BlockInlineText.plain('<x>tail');
    for (final link in [
      'javascript:alert(1)',
      'file:///tmp/x',
      'data:text/html,a',
      'https://user:pass@example.com',
      'https://example.com/\nfoo',
      'inkvault://note/no',
    ]) {
      expect(
        () => inline.setLink(0, 3, link),
        throwsFormatException,
        reason: link,
      );
    }
    final linked = inline.setLink(0, 3, 'https://example.com');
    expect(
      linked.toHtml(linkDestination: (_) => 'javascript:alert(1)'),
      isNot(contains('href=')),
    );
    expect(
      linked.toMarkdown(linkDestination: (_) => 'data:text/html,x'),
      isNot(contains('](')),
    );
    expect(
      linked.toHtml(linkDestination: (_) => '../rows/a%20b.html'),
      contains('../rows/a%20b.html'),
    );
  });

  test('typed metadata survives block kind changes while opaque contexts cannot be overwritten', () {
    final page = BlockPageDocument.fromJson(_page());
    final changed = page.blocks.single.copyWith(type: 'code');
    expect(
      changed.inlineText?.toJson(),
      page.blocks.single.inlineText?.toJson(),
    );
    expect(changed.copyWith(type: 'paragraph').inlineText, isNotNull);
    for (final version in [1, 2]) {
      final old = BlockPageDocument.fromJson(_page(version: version));
      expect(old.blocks.single.inlineText, null);
      expect(
        () => old.blocks.single.copyWith(
          inlineText: BlockInlineText.plain(old.blocks.single.text),
        ),
        throwsFormatException,
      );
      final added = BlockPageBlock.create(text: 'new')
          .copyWith(inlineText: BlockInlineText.plain('new'));
      expect(
        () => old.copyWith(blocks: [...old.blocks, added]),
        throwsFormatException,
      );
    }
  });

  test('unknown v3 metadata stays exact on text change and refuses formatting overwrite', () {
    final json = _page();
    _inline(json)['format'] = 'future-format';
    final page = BlockPageDocument.fromJson(json);
    final changed = page.blocks.single.copyWith(text: 'other');
    expect(changed.inlineText, null);
    expect(changed.toJson()['inlineData'], _inline(json));
    expect(
      () => changed.copyWith(inlineText: BlockInlineText.plain('other')),
      throwsFormatException,
    );
  });

  test(
    'formatting promotes plain pages to v3 and history labels it separately',
    () {
      final block = BlockPageBlock.create(text: 'word');
      final before = const BlockPageDocument.empty().copyWith(blocks: [block]);
      final after = before.copyWith(
        blocks: [
          block.copyWith(
            inlineText: BlockInlineText.plain('word')
                .toggleMark(1, 3, InlineMark.bold),
          ),
        ],
      );
      expect(after.version, 3);
      expect(
        BlockPageDocument.fromJson(after.toJson()).blocks.single.inlineText,
        isNotNull,
      );
      final changes = BlockPageHistoryDiff.compare(
        before,
        after,
      ).changes.single.kinds;
      expect(changes, contains(BlockPageChangeKind.formatting));
      expect(changes, isNot(contains(BlockPageChangeKind.unknown)));
      expect(changes, isNot(contains(BlockPageChangeKind.content)));
      expect(
        () => block.copyWith(inlineText: BlockInlineText.plain('mismatch')),
        throwsFormatException,
      );
    },
  );

  test(
    'known adjacent runs save canonically while legacy opaque runs stay exact',
    () {
      final json = _page();
      _inline(json)['runs'] = [
        {
          'start': 0,
          'end': 2,
          'marks': ['bold'],
        },
        {
          'start': 2,
          'end': 5,
          'marks': ['bold'],
        },
      ];
      final saved = BlockPageMediaSnapshot.prepare(
        BlockPageDocument.fromJson(json),
      );
      expect(_inline(saved.document.toJson())['runs'], [
        {
          'start': 0,
          'end': 5,
          'marks': ['bold'],
        },
      ]);
      final old = {...json, 'version': 1};
      expect(_inline(BlockPageDocument.fromJson(old).toJson()), _inline(old));
    },
  );

  test('schema floor keeps undo documents publishable without reinterpreting legacy metadata', () {
    final plain = const BlockPageDocument.empty().copyWith(
      blocks: [BlockPageBlock.create(text: 'original')],
    );
    expect(plain.copyWith(minimumVersion: 3).version, 3);
    expect(plain.copyWith(minimumVersion: 2).version, 2);
    expect(
      plain.copyWith(minimumVersion: 3).copyWith(minimumVersion: 1).version,
      3,
    );
    expect(() => plain.copyWith(minimumVersion: 0), throwsFormatException);
    expect(() => plain.copyWith(minimumVersion: 4), throwsFormatException);
    final old = BlockPageDocument.fromJson(_page(version: 1));
    expect(() => old.copyWith(minimumVersion: 3), throwsFormatException);
    expect(old.blocks.single.inlineText, null);
  });

  test('inline note projections use a constant label and canonical graph destination', () {
    const rawText = '[unsafe]\n<div>\n```';
    final json = _page(text: rawText);
    final linkedId = newId();
    _inline(json)['runs'] = [
      {
        'start': 0,
        'end': rawText.length,
        'marks': [],
        'link': NoteLink.markdown(linkedId, '세부 제목').toString(),
      },
    ];
    final page = BlockPageDocument.fromJson(json);
    expect(
      page.toLinkProjection(),
      '[inline-document](${NoteLink.markdown(linkedId, '세부 제목')})',
    );
    expect(page.toLinkProjection(), isNot(contains(rawText)));
    expect(
      structuredDocumentLinkText('page', {'page.json': _bytes(json)}),
      page.toLinkProjection(),
    );
    expect(page.toSearchText(), contains(rawText));
    expect(page.toSearchText(), contains(page.toLinkProjection()));
  });

  test(
    'structured database link projection includes live row inline notes only',
    () {
      final liveId = newId(), archivedId = newId();
      Map<String, dynamic> linkedPage(String id) {
        final json = _page();
        ((_inline(json)['runs'] as List).single as Map)['link'] = NoteLink(id)
            .toString();
        return json;
      }

      final database = WorkspaceDatabase.empty()
          .addRow(DatabaseRow.create(body: linkedPage(liveId)))
          .addRow(
            DatabaseRow.create(body: linkedPage(archivedId))
                .copyWith(archived: true),
          );
      final projection = structuredDocumentLinkText('database', {
        'database.json': _bytes(database.toJson()),
      });
      expect(projection, '[inline-document](${NoteLink.markdown(liveId)})');
      expect(projection, isNot(contains(archivedId)));
      expect(
        structuredDocumentLinkText('page', {
          'page.json': _bytes(_page(version: 1)),
        }),
        isEmpty,
      );
    },
  );

  test('Markdown literal quote entities decode exactly once', () {
    const text = '''O'Brian "quoted" & #tag [brackets] `ticks` &amp; &#39;''';
    final inline = BlockInlineText.plain(text);
    // Markdown's default AST re-encodes decoded entities for its HTML renderer.
    final nodes = markdown.Document(encodeHtml: false)
        .parseInline(inline.toMarkdown());
    expect(nodes.map((node) => node.textContent).join(), text);
    expect(
      markdown.markdownToHtml(inline.toMarkdown()),
      '<p>O&#39;Brian &quot;quoted&quot; &amp; #tag [brackets] `ticks` &amp;amp; &amp;#39;</p>\n',
    );
  });

  test('unsupported block kinds keep inline metadata dormant in Markdown', () {
    for (final type in [
      'code',
      'equation',
      'divider',
      'documentLink',
      'link',
      'future-block',
    ]) {
      final json = _page(text: 'plain caption');
      final block = (json['blocks'] as List).single as Map<String, dynamic>;
      block['type'] = type;
      if (type == 'documentLink') block['noteId'] = newId();
      final page = BlockPageDocument.fromJson(json);
      final output = page.toMarkdown();
      expect(output, isNot(contains('**')), reason: type);
      expect(output, isNot(contains('<u>')), reason: type);
      expect(_inline(page.toJson()), _inline(json), reason: type);
      expect(page.blocks.single.inlineText, isNotNull, reason: type);
    }
    final json = _page();
    expect(BlockPageDocument.fromJson(json).toMarkdown(), contains('**'));
  });

  test('Markdown parser retains selected whitespace and adjacent strong and emphasis', () {
    final spaced = BlockInlineText.plain('one two')
        .toggleMark(0, 4, InlineMark.bold);
    final spaceHtml = markdown.markdownToHtml(spaced.toMarkdown());
    expect(spaceHtml, contains('<strong>one </strong>two'));
    final leading = BlockInlineText.plain(' x ')
        .toggleMark(0, 3, InlineMark.italic);
    expect(
      markdown.markdownToHtml(leading.toMarkdown()),
      contains('<em> x </em>'),
    );
    final adjacent = BlockInlineText.plain('foobar')
        .toggleMark(0, 6, InlineMark.bold)
        .toggleMark(3, 6, InlineMark.italic);
    final html = markdown.markdownToHtml(adjacent.toMarkdown());
    expect(html, contains('<strong>foo</strong><em><strong>bar</strong></em>'));
    expect(html.replaceAll(RegExp('<[^>]*>'), '').trim(), 'foobar');
  });

  test(
    'Markdown parser keeps literal backticks and styles crossing newlines',
    () {
      const text = '`x` <script>\n*tail*';
      final inline = BlockInlineText.plain(text)
          .toggleMark(0, text.length, InlineMark.bold)
          .toggleMark(0, 3, InlineMark.code);
      final rendered = markdown.markdownToHtml(inline.toMarkdown());
      expect(rendered, contains('<strong><code>`x`</code></strong>'));
      expect(rendered, contains('&lt;script&gt;'));
      expect(rendered, isNot(contains('<script>')));
      expect(rendered, contains('<strong>*tail*</strong>'));
      final plain = rendered
          .replaceAll(RegExp('<[^>]*>'), '')
          .trim()
          .replaceAll('&lt;', '<')
          .replaceAll('&gt;', '>')
          .replaceAll('&amp;', '&');
      expect(plain, text);
      final backticks = BlockInlineText.plain('`x`')
          .toggleMark(0, 3, InlineMark.code);
      expect(
        markdown.markdownToHtml(backticks.toMarkdown()),
        contains('<code>`x`</code>'),
      );
    },
  );
}
