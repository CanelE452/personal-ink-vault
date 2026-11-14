import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:markdown/markdown.dart' as markdown;
import 'package:saber/data/vault/block_page_document.dart';
import 'package:saber/data/vault/block_page_media.dart';
import 'package:saber/data/vault/block_page_snapshot.dart';
import 'package:saber/data/vault/database_media_snapshot.dart';
import 'package:saber/data/vault/database_query.dart';
import 'package:saber/data/vault/portable_document_export.dart';
import 'package:saber/data/vault/workspace_database.dart';

final _note = newId(), _body = newId(), _metadata = newId();

void main() {
  test(
    'Markdown ZIP preserves exact source, media, nesting and edition identity',
    () {
      final attachment = BlockPageMediaAsset.attachment(
        name: '강의.pptx',
        bytes: [80, 75, 3, 4, 0, 255],
      );
      final picture = BlockPageMediaAsset.image(
        name: '그림.png',
        bytes: image.encodePng(image.Image(width: 2, height: 2)),
      );
      final file = BlockPageBlock.create(type: 'attachment', text: '자료');
      final photo = BlockPageBlock.create(type: 'image', text: '그림 설명');
      final child = BlockPageBlock.create(
        type: 'todo',
        text: '하위 작업',
      ).copyWith(checked: true);
      final parent = BlockPageBlock.create(
        type: 'toggle',
        text: '접기',
      ).copyWith(children: [child]);
      final page = const BlockPageDocument.empty().copyWith(
        blocks: [parent, file, photo],
        media: {file.id: attachment.reference, photo.id: picture.reference},
      );
      final snapshot = BlockPageMediaSnapshot.prepare(
        page,
        addedFiles: {
          attachment.reference.path: attachment.bytes,
          picture.reference.path: picture.bytes,
        },
      );
      final source = _page(snapshot);
      final bundle = buildPortableDocumentExport(
        source,
        PortableExportFormat.markdown,
      );
      final files = _unzip(bundle.toZip());
      expect(_text(files, bundle.entrypoint), contains('  - [x] 하위 작업'));
      expect(
        _text(files, bundle.entrypoint),
        contains('(${attachment.reference.path})'),
      );
      expect(
        _text(files, bundle.entrypoint),
        contains('![그림 설명](${picture.reference.path})'),
      );
      expect(files[attachment.reference.path], attachment.bytes);
      expect(files[picture.reference.path], picture.bytes);
      for (final entry in snapshot.files.entries) {
        expect(files['source/${entry.key}'], entry.value);
      }
      final report = jsonDecode(_text(files, 'export-report.json')) as Map;
      expect(report['noteId'], _note);
      expect(report['bodyRevisionId'], _body);
      expect(report['metadataRevisionIds'], [_metadata]);
      expect(report['format'], 'markdown');
      expect(report['entrypoint'], bundle.entrypoint);
    },
  );

  test(
    'output names cannot escape a ZIP folder or become Windows reserved names',
    () {
      final source = _page(
        BlockPageMediaSnapshot.prepare(const BlockPageDocument.empty()),
        title: '../../CON:<한글>\\a\u0000.',
      );
      final bundle = buildPortableDocumentExport(
        source,
        PortableExportFormat.html,
      );
      expect(bundle.entrypoint, contains(_note));
      expect(bundle.entrypoint, isNot(contains('/')));
      expect(bundle.entrypoint, isNot(contains('\\')));
      expect(bundle.entrypoint, isNot(contains(RegExp(r'[<>:"\x00-\x1f]'))));
      expect(bundle.entrypoint, endsWith('.html'));
      expect(
        _unzip(bundle.toZip()).keys,
        everyElement(isNot(startsWith('../'))),
      );
    },
  );

  test(
    'HTML escapes untrusted body, title, labels and attribute-shaped text',
    () {
      final page = const BlockPageDocument.empty().copyWith(
        blocks: [
          BlockPageBlock.create(text: '<script>alert(1)</script> & "quote"'),
          BlockPageBlock.create(type: 'link', text: 'javascript:alert(2)'),
          BlockPageBlock.create(
            type: 'code',
            text: '</code><img src=x onerror=alert(3)>',
          ),
        ],
      );
      final bundle = buildPortableDocumentExport(
        _page(
          BlockPageMediaSnapshot.prepare(page),
          title: '<img onerror=evil>',
        ),
        PortableExportFormat.html,
      );
      final html = _text(bundle.files, bundle.entrypoint);
      expect(html, contains('&lt;script&gt;alert(1)&lt;/script&gt;'));
      expect(html, contains('&lt;img onerror=evil&gt;'));
      expect(html, isNot(contains('<script>')));
      expect(html, isNot(contains('href="javascript:')));
      expect(html, isNot(contains('<img src=x')));
      expect(html, contains('<meta charset="utf-8">'));
    },
  );

  test('structured tables export every cell and header semantics', () {
    final block = BlockPageBlock.createTable(rows: 2, columns: 2);
    var table = block.table!;
    table = table.setCellText(table.rows.first.id, table.columns.first, '열|제목');
    table = table.setCellText(
      table.rows.last.id,
      table.columns.last,
      '한글\n둘째 줄',
    );
    table = table.copyWith(headerRow: true);
    final source = _page(
      BlockPageMediaSnapshot.prepare(
        const BlockPageDocument.empty().copyWith(
          blocks: [block.copyWith(table: table)],
        ),
      ),
    );
    final markdown = buildPortableDocumentExport(
      source,
      PortableExportFormat.markdown,
    );
    final html = buildPortableDocumentExport(source, PortableExportFormat.html);
    expect(_text(markdown.files, markdown.entrypoint), contains(r'열\|제목'));
    expect(_text(html.files, html.entrypoint), contains('<th'));
    expect(_text(html.files, html.entrypoint), contains('한글'));
    expect(_text(html.files, html.entrypoint), contains('둘째 줄'));
  });

  test(
    'self links become portable while missing external documents are reported',
    () {
      final outside = newId();
      final page = const BlockPageDocument.empty().copyWith(
        blocks: [
          BlockPageBlock.create(
            type: 'documentLink',
            text: '이 문서',
            noteId: _note,
          ),
          BlockPageBlock.create(
            type: 'documentLink',
            text: '다른 문서',
            noteId: outside,
          ),
        ],
      );
      final bundle = buildPortableDocumentExport(
        _page(BlockPageMediaSnapshot.prepare(page)),
        PortableExportFormat.markdown,
      );
      final markdown = _text(bundle.files, bundle.entrypoint);
      final self = _hrefs(
        markdown,
        PortableExportFormat.markdown,
      ).where((href) => Uri.parse(href).scheme.isEmpty).single;
      expect(Uri.decodeComponent(Uri.parse(self).path), bundle.entrypoint);
      expect(Uri.parse(self).fragment, isEmpty);
      expect(markdown, contains(outside));
      expect(
        bundle.warnings.any(
          (warning) =>
              warning.contains('external-document') &&
              warning.contains(outside),
        ),
        isTrue,
      );
    },
  );

  test(
    'unknown block data and opaque files remain exact in the source package',
    () {
      final raw = {
        'version': 1,
        'futurePage': {'secret': 7},
        'blocks': [
          {
            'id': newId(),
            'type': 'future-board',
            'text': '원문',
            'future': ['x', 9],
          },
        ],
      };
      final pageBytes = Uint8List.fromList(utf8.encode(jsonEncode(raw)));
      final opaque = Uint8List.fromList([3, 0, 255, 89]);
      final snapshot = BlockPageMediaSnapshot.fromFiles({
        'page.json': pageBytes,
        'future/blob.bin': opaque,
      });
      final bundle = buildPortableDocumentExport(
        _page(snapshot),
        PortableExportFormat.html,
      );
      expect(bundle.files['source/page.json'], pageBytes);
      expect(bundle.files['source/future/blob.bin'], opaque);
      expect(
        bundle.warnings.any((warning) => warning.contains('unknown-block')),
        isTrue,
      );
      expect(_text(bundle.files, bundle.entrypoint), contains('원문'));
    },
  );

  test('database CSV is RFC4180, preserves raw data and reports spreadsheet quoting', () {
    final title = DatabaseProperty.create(name: '이름', type: 'title');
    final text = DatabaseProperty.create(name: '설명', type: 'text');
    final row = DatabaseRow.create(
      values: {title.id: '=SUM(1,2)', text.id: '줄1,"따옴표"\r\n줄2'},
    );
    final archived = DatabaseRow.create(values: {title.id: '보관됨'})
        .copyWith(archived: true);
    final db = WorkspaceDatabase.empty().copyWith(
      properties: [title, text],
      rows: [row, archived],
    );
    final snapshot = DatabaseMediaSnapshot.prepare(db);
    final bundle = buildPortableDocumentExport(
      _database(snapshot),
      PortableExportFormat.csv,
    );
    final csv = _text(bundle.files, bundle.entrypoint);
    expect(csv, contains('"\'=SUM(1,2)"'));
    expect(csv, contains('"줄1,""따옴표""\r\n줄2"'));
    expect(csv, contains('_row_id'));
    expect(csv, contains('_archived'));
    expect(csv, contains('_row_page'));
    expect(csv, contains('보관됨'));
    expect(
      bundle.warnings.any((warning) => warning.contains('spreadsheet')),
      isTrue,
    );
    expect(
      bundle.files['source/database.json'],
      snapshot.files['database.json'],
    );
  });

  test('database row pages include all bodies and relative media even when archived', () {
    final title = DatabaseProperty.create(name: '이름', type: 'title');
    final asset = BlockPageMediaAsset.attachment(
      name: '자료.bin',
      bytes: [9, 4, 8],
    );
    final file = BlockPageBlock.create(type: 'attachment', text: '첨부');
    final page = const BlockPageDocument.empty().copyWith(
      blocks: [file],
      media: {file.id: asset.reference},
    );
    final row = DatabaseRow.create(
      values: {title.id: '행 이름'},
      body: page.toJson(),
    ).copyWith(archived: true);
    final db = WorkspaceDatabase.empty().copyWith(
      properties: [title],
      rows: [row],
    );
    final snapshot = DatabaseMediaSnapshot.prepare(
      db,
      addedFiles: {asset.reference.path: asset.bytes},
    );
    for (final format in [
      PortableExportFormat.markdown,
      PortableExportFormat.html,
      PortableExportFormat.csv,
    ]) {
      final bundle = buildPortableDocumentExport(_database(snapshot), format);
      final extension = format == PortableExportFormat.html ? 'html' : 'md';
      final path = 'rows/${row.id}.$extension';
      expect(bundle.files, contains(path));
      expect(_text(bundle.files, path), contains('../${asset.reference.path}'));
      expect(_text(bundle.files, bundle.entrypoint), contains(path));
      expect(bundle.files[asset.reference.path], asset.bytes);
    }
  });

  test('computed values and calculation errors are visible instead of silent blanks', () {
    final title = DatabaseProperty.create(name: '이름', type: 'title');
    final computed = DatabaseProperty.create(
      name: '계산',
      type: 'formula',
      config: {'expression': '1 + 2'},
    );
    final failed = DatabaseProperty.create(name: '실패', type: 'rollup');
    final row = DatabaseRow.create(values: {title.id: '행'});
    final db = WorkspaceDatabase.empty().copyWith(
      properties: [title, computed, failed],
      rows: [row],
    );
    final source = _database(
      DatabaseMediaSnapshot.prepare(db),
      values: {
        row.id: {
          computed.id: const DatabaseValue(3),
          failed.id: const DatabaseValue(
            null,
            error: DatabaseCalculationError('missing_relation', '관계 없음'),
          ),
        },
      },
    );
    final bundle = buildPortableDocumentExport(
      source,
      PortableExportFormat.csv,
    );
    expect(_text(bundle.files, bundle.entrypoint), contains('3'));
    expect(
      _text(bundle.files, bundle.entrypoint),
      contains('missing_relation'),
    );
    expect(
      bundle.warnings.any((warning) => warning.contains('missing_relation')),
      isTrue,
    );
    final missing = buildPortableDocumentExport(
      _database(DatabaseMediaSnapshot.prepare(db)),
      PortableExportFormat.markdown,
    );
    expect(
      missing.warnings.any((warning) => warning.contains('computed')),
      isTrue,
    );
  });

  test(
    'relations retain fixed identifiers and report targets outside this export',
    () {
      final relation = DatabaseProperty.create(name: '연결', type: 'relation');
      final targetDb = newId(), targetRow = newId();
      final row = DatabaseRow.create(
        values: {
          relation.id: [
            {'databaseId': targetDb, 'rowId': targetRow},
          ],
        },
      );
      final db = WorkspaceDatabase.empty().copyWith(
        properties: [relation],
        rows: [row],
      );
      final bundle = buildPortableDocumentExport(
        _database(DatabaseMediaSnapshot.prepare(db)),
        PortableExportFormat.csv,
      );
      expect(_text(bundle.files, bundle.entrypoint), contains(targetRow));
      expect(
        bundle.warnings.any(
          (warning) =>
              warning.contains('relation') && warning.contains(targetDb),
        ),
        isTrue,
      );
    },
  );

  test(
    'PDF bundle keeps original bytes, linked attachments and renderer warnings',
    () {
      final snapshot = BlockPageMediaSnapshot.prepare(
        const BlockPageDocument.empty(),
      );
      final bytes = Uint8List.fromList(
        utf8.encode('%PDF-1.7\nsynthetic transport bytes'),
      );
      final bundle = buildPortableDocumentExport(
        _page(snapshot),
        PortableExportFormat.pdf,
        pdfBytes: bytes,
        pdfWarnings: ['test-renderer-warning'],
      );
      expect(bundle.entrypoint, endsWith('.pdf'));
      expect(bundle.files[bundle.entrypoint], bytes);
      expect(bundle.warnings, contains('test-renderer-warning'));
      expect(bundle.files['source/page.json'], snapshot.files['page.json']);
      expect(
        () => buildPortableDocumentExport(
          _page(snapshot),
          PortableExportFormat.pdf,
        ),
        throwsFormatException,
      );
      expect(
        () => buildPortableDocumentExport(
          _page(snapshot),
          PortableExportFormat.csv,
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'bundle returned byte copies cannot mutate source or later archive calls',
    () {
      final snapshot = BlockPageMediaSnapshot.prepare(
        const BlockPageDocument.empty(),
      );
      final source = _page(snapshot);
      final original = snapshot.files['page.json']!;
      final bundle = buildPortableDocumentExport(
        source,
        PortableExportFormat.markdown,
      );
      bundle.files['source/page.json']![0] = 0;
      expect(snapshot.files['page.json'], original);
      expect(_unzip(bundle.toZip())['source/page.json'], original);
    },
  );

  test(
    'computed export pins related editions, UTC clock and defensive values',
    () {
      final computed = DatabaseProperty.create(name: '계산', type: 'formula');
      final row = DatabaseRow.create();
      final db = WorkspaceDatabase.empty().copyWith(
        properties: [computed],
        rows: [row],
      );
      final payload = <Object?>['처음', 7];
      final values = {
        row.id: {computed.id: DatabaseValue(payload)},
      };
      final related = <String, String>{newId(): newId()};
      final pinned = Map<String, String>.of(related);
      final source = PortableExportSource.database(
        noteId: _note,
        title: '계산',
        bodyRevisionId: _body,
        metadataRevisionIds: [_metadata],
        snapshot: DatabaseMediaSnapshot.prepare(db),
        values: values,
        relatedRevisionIds: related,
        evaluatedAtUtc: DateTime.parse('2026-11-06T09:00:00+09:00'),
      );
      payload[0] = '바뀜';
      values.clear();
      related.clear();
      final bundle = buildPortableDocumentExport(
        source,
        PortableExportFormat.csv,
      );
      final report =
          jsonDecode(_text(bundle.files, 'export-report.json')) as Map;
      expect(report['relatedRevisionIds'], pinned);
      expect(report['evaluatedAtUtc'], '2026-11-06T00:00:00.000Z');
      expect(report['archivedRowsIncluded'], isTrue);
      expect(_text(bundle.files, bundle.entrypoint), contains('처음'));
      expect(_text(bundle.files, bundle.entrypoint), isNot(contains('바뀜')));
      expect(
        bundle.warnings.any(
          (warning) => warning.contains('computed-static-snapshot'),
        ),
        isTrue,
      );
    },
  );

  test('negative numeric CSV cells stay numeric while executable prefixes are escaped', () {
    final property = DatabaseProperty.create(name: '수', type: 'number');
    final text = DatabaseProperty.create(name: '문자', type: 'text');
    final row = DatabaseRow.create(
      values: {property.id: -2, text.id: ' \t+cmd|evil'},
    );
    final db = WorkspaceDatabase.empty().copyWith(
      properties: [property, text],
      rows: [row],
    );
    final bundle = buildPortableDocumentExport(
      _database(DatabaseMediaSnapshot.prepare(db)),
      PortableExportFormat.csv,
    );
    final csv = _text(bundle.files, bundle.entrypoint);
    expect(csv, contains('"-2"'));
    expect(csv, contains('"\' \t+cmd|evil"'));
  });

  test('case-insensitive output collisions are rejected before an archive is emitted', () {
    expect(
      () => PortableExportBundle(
        files: {'a.md': Uint8List(0), 'A.md': Uint8List(0)},
        entrypoint: 'a.md',
        warnings: const [],
      ),
      throwsFormatException,
    );
  });

  test('opaque Windows names and case collisions preserve bytes through reported portable paths', () {
    final originals = <String, Uint8List>{
      'page.json': Uint8List.fromList(
        utf8.encode(jsonEncode(const BlockPageDocument.empty().toJson())),
      ),
      'future/Case.bin': Uint8List.fromList([1, 0, 255]),
      'future/case.bin': Uint8List.fromList([2, 0, 254]),
      'future/CON?.dat': Uint8List.fromList([3, 0, 253]),
      'future/CON': Uint8List.fromList([4]),
      'future/NUL.txt': Uint8List.fromList([5]),
      'future/trailing. ': Uint8List.fromList([6]),
    };
    final bundle = buildPortableDocumentExport(
      _page(BlockPageMediaSnapshot.fromFiles(originals)),
      PortableExportFormat.markdown,
    );
    final unpacked = _unzip(bundle.toZip());
    final report = jsonDecode(_text(unpacked, 'export-report.json')) as Map;
    final entries = {
      for (final value in report['sourceFiles'] as List)
        (value as Map)['originalPath'] as String: value,
    };
    expect(entries.keys.toSet(), originals.keys.toSet());
    expect(entries['page.json']!['exportedPath'], 'source/page.json');
    for (final original in originals.entries) {
      final record = entries[original.key] as Map;
      final path = record['exportedPath'] as String;
      expect(unpacked[path], original.value);
      expect(record['bytes'], original.value.length);
      expect(
        record['sha256'],
        crypto.sha256.convert(original.value).toString(),
      );
      if (original.key != 'page.json') {
        expect(
          path,
          'source/opaque/${crypto.sha256.convert(utf8.encode(original.key))}.bin',
        );
      }
    }
    expect(
      unpacked.keys.map((path) => path.toLowerCase()).toSet().length,
      unpacked.length,
    );
    expect(
      bundle.warnings.any(
        (warning) => warning.contains('source-path-remapped'),
      ),
      isTrue,
    );
    final reversed = {
      for (final key in originals.keys.toList().reversed) key: originals[key]!,
    };
    final second = buildPortableDocumentExport(
      _page(BlockPageMediaSnapshot.fromFiles(reversed)),
      PortableExportFormat.markdown,
    );
    final secondReport =
        jsonDecode(_text(second.files, 'export-report.json')) as Map;
    final secondEntries = {
      for (final value in secondReport['sourceFiles'] as List)
        (value as Map)['originalPath'] as String: value['exportedPath'],
    };
    expect(secondEntries, {
      for (final entry in entries.entries)
        entry.key: entry.value['exportedPath'],
    });
  });

  test('opaque remap never replaces a legitimate source file occupying its hashed path', () {
    const unusual = 'future/CON?.dat';
    final hash = crypto.sha256.convert(utf8.encode(unusual)).toString();
    final occupied = 'opaque/$hash.bin';
    final originals = <String, Uint8List>{
      'page.json': Uint8List.fromList(
        utf8.encode(jsonEncode(const BlockPageDocument.empty().toJson())),
      ),
      unusual: Uint8List.fromList([7, 0, 255]),
      occupied: Uint8List.fromList([8, 0, 254]),
    };
    final bundle = buildPortableDocumentExport(
      _page(BlockPageMediaSnapshot.fromFiles(originals)),
      PortableExportFormat.html,
    );
    final unpacked = _unzip(bundle.toZip());
    final report = jsonDecode(_text(unpacked, 'export-report.json')) as Map;
    final entries = {
      for (final value in report['sourceFiles'] as List)
        (value as Map)['originalPath'] as String: value,
    };
    expect(entries[occupied]!['exportedPath'], 'source/$occupied');
    final remapped = entries[unusual]!['exportedPath'] as String;
    expect(remapped, startsWith('source/opaque/$hash'));
    expect(remapped, isNot('source/$occupied'));
    expect(unpacked[remapped], originals[unusual]);
    expect(unpacked['source/$occupied'], originals[occupied]);
  });

  test('Markdown and HTML self links resolve filenames containing hash percent and spaces', () {
    final page = const BlockPageDocument.empty().copyWith(
      blocks: [
        BlockPageBlock.create(type: 'documentLink', text: '문서로', noteId: _note),
      ],
    );
    final source = _page(
      BlockPageMediaSnapshot.prepare(page),
      title: '연구#초안 %2F 공백',
    );
    for (final format in [
      PortableExportFormat.markdown,
      PortableExportFormat.html,
    ]) {
      final bundle = buildPortableDocumentExport(source, format);
      expect(bundle.entrypoint, contains('연구#초안 %2F 공백'));
      final href = _hrefs(
        _text(bundle.files, bundle.entrypoint),
        format,
      ).single;
      final target = Uri.parse(href);
      final decodedPath = Uri.decodeComponent(target.path);
      expect(decodedPath, bundle.entrypoint);
      expect(decodedPath, contains('%2F'));
      expect(target.fragment, isEmpty);
      expect(target.query, isEmpty);
      final anchored = Uri.parse('$href#block-anchor');
      expect(Uri.decodeComponent(anchored.path), bundle.entrypoint);
      expect(anchored.fragment, 'block-anchor');
    }
  });

  test(
    'database row self links and HTML backlinks resolve exact ZIP members',
    () {
      final page = const BlockPageDocument.empty().copyWith(
        blocks: [
          BlockPageBlock.create(
            type: 'documentLink',
            text: '상위 문서',
            noteId: _note,
          ),
        ],
      );
      final row = DatabaseRow.create(body: page.toJson());
      final db = WorkspaceDatabase.empty().copyWith(rows: [row]);
      final source = PortableExportSource.database(
        noteId: _note,
        title: '연구#초안 %2F 공백',
        bodyRevisionId: _body,
        metadataRevisionIds: [_metadata],
        snapshot: DatabaseMediaSnapshot.prepare(db),
      );
      for (final format in [
        PortableExportFormat.markdown,
        PortableExportFormat.html,
      ]) {
        final bundle = buildPortableDocumentExport(source, format);
        final extension = format == PortableExportFormat.html ? 'html' : 'md';
        final path = 'rows/${row.id}.$extension';
        final hrefs = _hrefs(_text(bundle.files, path), format);
        expect(hrefs, isNotEmpty);
        for (final href in hrefs) {
          final target = Uri(
            scheme: 'file',
            path: '/export/$path',
          ).resolve(href);
          expect(target.fragment, isEmpty);
          expect(target.query, isEmpty);
          final decodedPath = Uri.decodeComponent(target.path);
          expect(decodedPath, '/export/${bundle.entrypoint}');
          expect(decodedPath, contains('%2F'));
          expect(
            bundle.files,
            contains(decodedPath.substring('/export/'.length)),
          );
        }
      }
    },
  );

  test('database Markdown table escapes literal HTML in headers and cells without escaping line breaks', () {
    final property = DatabaseProperty.create(
      name: '<b>열</b> & 이름',
      type: 'text',
    );
    final row = DatabaseRow.create(
      values: {property.id: '<b>원문</b> & <img src=x>\n둘째 줄'},
    );
    final db = WorkspaceDatabase.empty().copyWith(
      properties: [property],
      rows: [row],
    );
    final bundle = buildPortableDocumentExport(
      _database(DatabaseMediaSnapshot.prepare(db)),
      PortableExportFormat.markdown,
    );
    final text = _text(bundle.files, bundle.entrypoint);
    expect(text, contains('&lt;b&gt;열&lt;/b&gt; &amp; 이름'));
    expect(
      text,
      contains('&lt;b&gt;원문&lt;/b&gt; &amp; &lt;img src=x&gt;<br>둘째 줄'),
    );
    final html = markdown.markdownToHtml(
      text,
      extensionSet: markdown.ExtensionSet.gitHubFlavored,
    );
    expect(html, isNot(contains('<b>열</b>')));
    expect(html, isNot(contains('<b>원문</b>')));
    expect(html, isNot(contains('<img src=x>')));
    expect(html, contains('<br>'));
  });
}

PortableExportSource _page(
  BlockPageMediaSnapshot snapshot, {
  String title = '한글 페이지',
}) => PortableExportSource.page(
  noteId: _note,
  title: title,
  bodyRevisionId: _body,
  metadataRevisionIds: [_metadata],
  snapshot: snapshot,
);

PortableExportSource _database(
  DatabaseMediaSnapshot snapshot, {
  Map<String, Map<String, DatabaseValue>> values = const {},
}) => PortableExportSource.database(
  noteId: _note,
  title: '데이터베이스',
  bodyRevisionId: _body,
  metadataRevisionIds: [_metadata],
  snapshot: snapshot,
  values: values,
);

Map<String, Uint8List> _unzip(Uint8List bytes) => {
  for (final file in ZipDecoder().decodeBytes(bytes, verify: true))
    if (file.isFile) file.name: Uint8List.fromList(file.content),
};
String _text(Map<String, Uint8List> files, String path) =>
    utf8.decode(files[path]!);

List<String> _hrefs(String content, PortableExportFormat format) {
  final html = format == PortableExportFormat.html
      ? content
      : markdown.markdownToHtml(
          content,
          extensionSet: markdown.ExtensionSet.gitHubFlavored,
        );
  return [
    for (final match in RegExp('href="([^"]*)"').allMatches(html))
      match.group(1)!,
  ];
}
