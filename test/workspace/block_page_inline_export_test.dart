import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:markdown/markdown.dart' as markdown;
import 'package:saber/data/vault/block_page_media.dart';
import 'package:saber/data/vault/block_page_snapshot.dart';
import 'package:saber/data/vault/database_media_snapshot.dart';
import 'package:saber/data/vault/note_link.dart';
import 'package:saber/data/vault/portable_document_export.dart';
import 'package:saber/data/vault/portable_document_pdf.dart';
import 'package:saber/data/vault/workspace_database.dart';

final _noteId = newId(), _outsideId = newId();
const _external = 'https://example.com/path?q=one&other=two';
const _literal = '<script>alert(1)</script> & < >';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('version 3 Markdown exports real inline styles, safe links and exact source', () async {
    final fixture = _fixture();
    final bundle = buildPortableDocumentExport(
      _page(fixture.snapshot),
      PortableExportFormat.markdown,
    );
    final value = _text(bundle, bundle.entrypoint);
    final html = markdown.markdownToHtml(
      value,
      extensionSet: markdown.ExtensionSet.gitHubWeb,
    );
    expect(html, contains('<strong>굵게</strong>'));
    expect(html, contains('<em>기울임</em>'));
    expect(html, contains('<u>밑줄</u>'));
    expect(html, contains('<del>취소선</del>'));
    expect(html, contains('<code>코드</code>'));
    expect(html, contains('<mark>강조</mark>'));
    expect(html, contains('&lt;script&gt;alert(1)&lt;/script&gt;'));
    expect(html, isNot(contains('<script>')));
    expect(html, contains('INLINE-TAIL-끝 🧪'));
    expect(value, contains('🧪'));
    expect(html, contains('href="${_relative(bundle.entrypoint)}"'));
    final webLink = html_parser
        .parse(html)
        .querySelectorAll('a')
        .singleWhere((element) => element.text == '웹 링크');
    expect(webLink.attributes['href'], _external);
    expect(value, contains(NoteLink(_outsideId).toString()));
    expect(
      bundle.warnings,
      contains(allOf(contains('external-document'), contains(_outsideId))),
    );
    expect(
      bundle.warnings.where((value) => value.contains('opaque-block-fields')),
      isEmpty,
    );
    expect(bundle.files['source/page.json'], fixture.pageBytes);
    expect(bundle.files[fixture.asset.reference.path], fixture.asset.bytes);
    expect(bundle.files['source/future.bin'], orderedEquals([0, 255, 19]));
    await _retain('inline-markdown.zip', bundle.toZip());
  });

  test('HTML and rendered Markdown preserve entity-shaped link query values exactly', () {
    for (final destination in [
      _external,
      'https://example.com/path?q=&copy;&quot;&amp;&lt;&gt;&v=one',
      'https://example.com/path?q=%26copy%3B&next=%22quoted%22',
    ]) {
      const text = '원래 링크';
      final pageBytes = Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'version': 3,
            'blocks': [
              {
                'id': newId(),
                'type': 'paragraph',
                'text': text,
                'inlineData': {
                  'format': 'personal-ink-inline-1',
                  'textSha256': crypto.sha256
                      .convert(utf8.encode(text))
                      .toString(),
                  'runs': [
                    {
                      'start': 0,
                      'end': text.length,
                      'marks': ['bold'],
                      'link': destination,
                    },
                  ],
                },
              },
            ],
          }),
        ),
      );
      final snapshot = BlockPageMediaSnapshot.fromFiles({
        'page.json': pageBytes,
      });
      for (final format in [
        PortableExportFormat.html,
        PortableExportFormat.markdown,
      ]) {
        final bundle = buildPortableDocumentExport(_page(snapshot), format);
        final value = _text(bundle, bundle.entrypoint);
        final html = format == PortableExportFormat.html
            ? value
            : markdown.markdownToHtml(
                value,
                extensionSet: markdown.ExtensionSet.gitHubWeb,
              );
        final document = html_parser.parse(html);
        final link = document.querySelectorAll('a').single;
        final actual = link.attributes['href'];
        expect(actual, destination, reason: '$format destination roundtrip');
        expect(
          Uri.parse(actual!).queryParametersAll,
          Uri.parse(destination).queryParametersAll,
          reason: '$format query values',
        );
        expect(link.text, text);
        expect(link.querySelector('strong')?.text, text);
        expect(document.querySelector('script'), isNull);
        expect(bundle.files['source/page.json'], pageBytes);
      }
    }
  });

  test(
    'version 3 HTML keeps semantic inline styles and disables active content',
    () async {
      final fixture = _fixture();
      final bundle = buildPortableDocumentExport(
        _page(fixture.snapshot),
        PortableExportFormat.html,
      );
      final value = _text(bundle, bundle.entrypoint);
      for (final styled in [
        '<strong>굵게</strong>',
        '<em>기울임</em>',
        '<u>밑줄</u>',
        '<code>코드</code>',
        '<mark>강조</mark>',
      ]) {
        expect(value, contains(styled));
      }
      expect(value, contains(RegExp(r'<(del|s)>취소선</\1>')));
      expect(value, contains('&lt;script&gt;alert(1)&lt;/script&gt;'));
      expect(value, contains('&amp; &lt; &gt;'));
      expect(value, isNot(contains('<script>')));
      expect(value, isNot(contains('href="javascript:')));
      expect(value, contains('Content-Security-Policy'));
      expect(value, contains("default-src 'none'"));
      expect(value, contains('href="${_relative(bundle.entrypoint)}"'));
      expect(value, contains('https://example.com/path?q=one&amp;other=two'));
      expect(value, contains('INLINE-TAIL-끝'));
      expect(value, contains('🧪'));
      expect(bundle.files['source/page.json'], fixture.pageBytes);
      await _retain('inline-html.zip', bundle.toZip());
    },
  );

  test('dormant document link inline data cannot nest HTML anchors and stays exact in source', () {
    final blockId = newId();
    const label = '<script>literal</script> & document';
    final pageBytes = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'version': 3,
          'blocks': [
            {
              'id': blockId,
              'type': 'documentLink',
              'text': label,
              'noteId': _noteId,
              'inlineData': {
                'format': 'personal-ink-inline-1',
                'textSha256': crypto.sha256
                    .convert(utf8.encode(label))
                    .toString(),
                'runs': [
                  {
                    'start': 0,
                    'end': label.length,
                    'marks': ['bold'],
                    'link': _external,
                  },
                ],
              },
            },
          ],
        }),
      ),
    );
    final snapshot = BlockPageMediaSnapshot.fromFiles({'page.json': pageBytes});
    final bundle = buildPortableDocumentExport(
      _page(snapshot),
      PortableExportFormat.html,
    );
    final html = _text(bundle, bundle.entrypoint);
    expect(
      html,
      isNot(contains(RegExp(r'<a\b[^>]*>(?:(?!</a>).)*<a\b', dotAll: true))),
    );
    expect(RegExp(r'<a\b').allMatches(html), hasLength(1));
    expect(
      html,
      contains('&lt;script&gt;literal&lt;/script&gt; &amp; document'),
    );
    expect(html, isNot(contains('<script>')));
    expect(html, isNot(contains('<strong>')));
    expect(html, isNot(contains(_external)));
    expect(
      bundle.warnings,
      contains(
        allOf(
          contains('dormant-inline'),
          contains(blockId),
          contains('documentLink'),
        ),
      ),
    );
    expect(bundle.files['source/page.json'], pageBytes);
  });

  test('nontext and unknown block inline styles stay dormant in portable presentations', () {
    for (final type in [
      'code',
      'equation',
      'divider',
      'link',
      'future-widget',
    ]) {
      final blockId = newId();
      const text = '<script>literal</script> & dormant';
      final pageBytes = Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'version': 3,
            'blocks': [
              {
                'id': blockId,
                'type': type,
                'text': text,
                'inlineData': {
                  'format': 'personal-ink-inline-1',
                  'textSha256': crypto.sha256
                      .convert(utf8.encode(text))
                      .toString(),
                  'runs': [
                    {
                      'start': 0,
                      'end': text.length,
                      'marks': ['bold'],
                      'link': _external,
                    },
                  ],
                },
              },
            ],
          }),
        ),
      );
      final snapshot = BlockPageMediaSnapshot.fromFiles({
        'page.json': pageBytes,
      });
      for (final format in [
        PortableExportFormat.html,
        PortableExportFormat.markdown,
      ]) {
        final bundle = buildPortableDocumentExport(_page(snapshot), format);
        final value = _text(bundle, bundle.entrypoint);
        final html = format == PortableExportFormat.html
            ? value
            : markdown.markdownToHtml(
                value,
                extensionSet: markdown.ExtensionSet.gitHubWeb,
              );
        expect(html, isNot(contains('<strong>')), reason: '$type/$format');
        expect(html, isNot(contains(_external)), reason: '$type/$format');
        expect(html, isNot(contains('<script>')), reason: '$type/$format');
        expect(
          bundle.warnings,
          contains(
            allOf(
              contains('dormant-inline'),
              contains(blockId),
              contains(type),
            ),
          ),
          reason: '$type/$format',
        );
        expect(bundle.files['source/page.json'], pageBytes);
      }
    }
  });

  test(
    'database row inline self links resolve relative to the exported database',
    () {
      final fixture = _fixture();
      final title = DatabaseProperty.create(name: '이름', type: 'title');
      final row = DatabaseRow.create(
        values: {title.id: '서식 있는 행'},
        body: fixture.snapshot.document.toJson(),
      );
      final database = WorkspaceDatabase.empty().copyWith(
        properties: [title],
        rows: [row],
      );
      final snapshot = DatabaseMediaSnapshot.prepare(
        database,
        addedFiles: {fixture.asset.reference.path: fixture.asset.bytes},
      );
      final source = PortableExportSource.database(
        noteId: _noteId,
        title: '서식 DB',
        bodyRevisionId: newId(),
        metadataRevisionIds: [newId()],
        snapshot: snapshot,
      );
      for (final format in [
        PortableExportFormat.markdown,
        PortableExportFormat.html,
      ]) {
        final bundle = buildPortableDocumentExport(source, format);
        final suffix = format == PortableExportFormat.html ? 'html' : 'md';
        final value = _text(bundle, 'rows/${row.id}.$suffix');
        final html = format == PortableExportFormat.html
            ? value
            : markdown.markdownToHtml(
                value,
                extensionSet: markdown.ExtensionSet.gitHubWeb,
              );
        expect(value, contains('../${_relative(bundle.entrypoint)}'));
        expect(value, contains('굵게'));
        expect(html, contains('INLINE-TAIL-끝 🧪'));
        expect(
          value,
          contains(format == PortableExportFormat.html ? '<strong>' : '**'),
        );
      }
    },
  );

  test('version 3 rich PDF is searchable, paginates long runs and reports only missing meanings', () async {
    final fixture = _fixture();
    final result = await renderPortableDocumentPdf(
      _page(fixture.snapshot),
      fontData: ByteData.sublistView(
        await File('build/native/fonts/NotoSansKR-Portable.ttf').readAsBytes(),
      ),
    );
    final bytes = latin1.decode(result.bytes);
    expect(bytes, startsWith('%PDF-'));
    expect(bytes, contains('/ToUnicode'));
    expect(bytes, contains('/FontFile2'));
    expect(bytes, contains(RegExp(r'/Subtype\s*/Link\b')));
    expect(bytes, contains('https://example.com/path?q=one&other=two'));
    expect(bytes, contains('note-$_noteId'));
    final programs = _pdfStreams(result.bytes);
    expect(programs, contains(RegExp(r'2\s+Tr\b')));
    expect(
      programs,
      contains(RegExp(r'1\s+0\s+0?\.18\s+1\s+[-\d.]+\s+[-\d.]+\s+cm\b')),
    );
    expect(RegExp(r'/Type\s*/Page\b').allMatches(bytes).length, greaterThan(2));
    expect(result.warnings, contains('pdf.unsupported_glyph:U+1F9EA'));
    expect(
      result.warnings,
      contains(
        allOf(contains('unresolved_document_link'), contains(_outsideId)),
      ),
    );
    expect(
      result.warnings.where(
        (value) => value.contains('inline') && value.contains('unsupported'),
      ),
      isEmpty,
    );
    final bundle = buildPortableDocumentExport(
      _page(fixture.snapshot),
      PortableExportFormat.pdf,
      pdfBytes: result.bytes,
      pdfWarnings: result.warnings,
    );
    expect(bundle.files['source/page.json'], fixture.pageBytes);
    expect(bundle.files[fixture.asset.reference.path], fixture.asset.bytes);
    await _retain('inline-rich.pdf', result.bytes);
    await _retain('inline-pdf.zip', bundle.toZip());
  });
}

({
  BlockPageMediaSnapshot snapshot,
  Uint8List pageBytes,
  BlockPageMediaAsset asset,
})
_fixture() {
  final asset = BlockPageMediaAsset.attachment(
    name: '원본.bin',
    bytes: [7, 0, 255],
  );
  final mediaId = newId();
  const text = '굵게 기울임 밑줄 취소선 코드 강조 내 문서 외부 문서 웹 링크\n$_literal';
  Map<String, Object?> run(String part, List<String> marks, [String? link]) => {
    'start': text.indexOf(part),
    'end': text.indexOf(part) + part.length,
    'marks': marks,
    'link': ?link,
  };
  final tail = '${'서식 있는 긴 문장 ' * 1800} INLINE-TAIL-끝 🧪';
  final raw = {
    'version': 3,
    'blocks': [
      {
        'id': newId(),
        'type': 'paragraph',
        'text': text,
        'inlineData': {
          'format': 'personal-ink-inline-1',
          'textSha256': crypto.sha256.convert(utf8.encode(text)).toString(),
          'runs': [
            run('굵게', ['bold']),
            run('기울임', ['italic']),
            run('밑줄', ['underline']),
            run('취소선', ['strikethrough']),
            run('코드', ['code']),
            run('강조', ['highlight']),
            run('내 문서', [], NoteLink(_noteId).toString()),
            run('외부 문서', [], NoteLink(_outsideId).toString()),
            run('웹 링크', [], _external),
          ],
        },
      },
      {
        'id': newId(),
        'type': 'paragraph',
        'text': tail,
        'inlineData': {
          'format': 'personal-ink-inline-1',
          'textSha256': crypto.sha256.convert(utf8.encode(tail)).toString(),
          'runs': [
            {
              'start': 0,
              'end': tail.length,
              'marks': ['bold', 'underline'],
            },
          ],
        },
      },
      {'id': mediaId, 'type': 'attachment', 'text': '보존되는 첨부'},
    ],
    'blockMedia': {mediaId: asset.reference.toJson()},
  };
  final pageBytes = Uint8List.fromList(utf8.encode(jsonEncode(raw)));
  return (
    snapshot: BlockPageMediaSnapshot.fromFiles({
      'page.json': pageBytes,
      asset.reference.path: asset.bytes,
      'future.bin': Uint8List.fromList([0, 255, 19]),
    }),
    pageBytes: pageBytes,
    asset: asset,
  );
}

PortableExportSource _page(BlockPageMediaSnapshot snapshot) =>
    PortableExportSource.page(
      noteId: _noteId,
      title: '선택 글자 서식',
      bodyRevisionId: newId(),
      metadataRevisionIds: [newId()],
      snapshot: snapshot,
    );

String _text(PortableExportBundle bundle, String path) =>
    utf8.decode(bundle.files[path]!);

String _relative(String path) =>
    path.split('/').map(Uri.encodeComponent).join('/');

String _pdfStreams(Uint8List bytes) {
  final result = StringBuffer();
  final raw = latin1.decode(bytes);
  for (final match in RegExp(
    r'<<(.*?)>>\s*stream\r?\n(.*?)\r?\nendstream',
    dotAll: true,
  ).allMatches(raw)) {
    final value = latin1.encode(match[2]!);
    result.write(
      latin1.decode(
        match[1]!.contains('/FlateDecode') ? zlib.decode(value) : value,
      ),
    );
  }
  return result.toString();
}

Future<void> _retain(String name, Uint8List bytes) async {
  final directory = Platform.environment['INK_VAULT_INLINE_EXPORT_PROOF_DIR'];
  if (directory == null) return;
  await Directory(directory).create(recursive: true);
  await File('$directory/$name').writeAsBytes(bytes);
}
