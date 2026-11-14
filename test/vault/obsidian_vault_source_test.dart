import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/vault/obsidian_vault_source.dart';

void main() {
  test('reads only exact, bounded root template settings', () async {
    final settings = utf8.encode(
      '{"folder":"Course/Templates","dateFormat":"DD.MM.YYYY",'
      '"timeFormat":"h:mm A"}',
    );
    final wrapped = await _readZip(
      _zip({
        'Vault/.obsidian/templates.json': settings,
        'Vault/Course/.obsidian/templates.json': [0xff],
        'Vault/Course/Templates/Lesson.md': utf8.encode('# {{title}}'),
      }),
    );
    expect(wrapped.templateSettings?.folderPath, ['Course', 'Templates']);
    expect(wrapped.templateSettings?.dateFormat, 'DD.MM.YYYY');
    expect(wrapped.templateSettings?.timeFormat, 'h:mm A');
    expect(wrapped.notes.single.folders, ['Course', 'Templates']);
    final root = await Directory.systemTemp.createTemp('obsidian-templates-');
    addTearDown(() => root.delete(recursive: true));
    await File(p.join(root.path, 'Read.md')).writeAsString('# Read');
    final hidden = await Directory(p.join(root.path, '.obsidian')).create();
    final file = File(p.join(hidden.path, 'templates.json'));
    await file.writeAsBytes(settings);
    expect((await _readFolder(root)).templateSettings?.timeFormat, 'h:mm A');
    for (final invalid in [
      utf8.encode('{"folder":"../Templates"}'),
      utf8.encode('{"folder":"Templates","dateFormat":7}'),
      List<int>.filled(17 * 1024, 0x20),
      [0xff],
    ]) {
      await file.writeAsBytes(invalid);
      final source = await _readFolder(root);
      expect(source.templateSettings, isNull);
      expect(source.notes.single.title, 'Read');
    }
  });

  test(
    'reads only root bookmark metadata without adding hidden notes',
    () async {
      final bookmarks = utf8.encode('{"items":[]}');
      final wrapped = await _readZip(
        _zip({
          'Vault/.obsidian/bookmarks.json': bookmarks,
          'Vault/.obsidian/private.md': [0xff],
          'Vault/course/.obsidian/bookmarks.json': [0xff],
          'Vault/course/Read.md': utf8.encode('# Read'),
        }),
      );
      expect(wrapped.bookmarkBytes, bookmarks);
      expect(wrapped.bookmarksUnreadable, isFalse);
      expect(wrapped.notes.single.folders, ['course']);
      expect(wrapped.skippedFiles, 0);

      final root = await Directory.systemTemp.createTemp('obsidian-bookmarks-');
      addTearDown(() => root.delete(recursive: true));
      await File(p.join(root.path, 'Read.md')).writeAsString('# Read');
      final settings = await Directory(p.join(root.path, '.obsidian')).create();
      await File(p.join(settings.path, 'bookmarks.json'))
          .writeAsBytes(bookmarks);
      expect((await _readFolder(root)).bookmarkBytes, bookmarks);
    },
  );

  test(
    'preserves UTF-8 bytes, nested paths and safe frontmatter aliases',
    () async {
      final root = await Directory.systemTemp.createTemp('obsidian-source-');
      addTearDown(() => root.delete(recursive: true));
      final markdown = Uint8List.fromList([
        0xef,
        0xbb,
        0xbf,
        ...utf8.encode(
          '---\r\naliases: ["별칭 하나", "Other Name", "별칭 하나"]\r\n---\r\n'
          '# 주제\r\n[[과목/목표]]\r\n[목표](../목표.md#주제)\r\n',
        ),
      ]);
      final week = await Directory(p.join(root.path, '과목', '주차'))
          .create(recursive: true);
      await File(p.join(week.path, '수업.md')).writeAsBytes(markdown);
      await File(p.join(root.path, '과목', '목표.MD')).writeAsString('# 주제');
      await Directory(p.join(root.path, '빈 폴더')).create();
      await File(p.join(root.path, '첨부.txt')).writeAsBytes([0xff]);
      final settings = await Directory(p.join(root.path, '.obsidian')).create();
      await File(p.join(settings.path, 'plugin.md')).writeAsBytes([0xff]);
      await File(p.join(root.path, '.private.md')).writeAsBytes([0xff]);

      final source = await _readFolder(root);

      expect(source.skippedFiles, 1);
      expect(
        source.notes.map((note) => note.title),
        unorderedEquals(['수업', '목표']),
      );
      final note = source.notes.singleWhere((note) => note.title == '수업');
      expect(note.folders, ['과목', '주차']);
      expect(note.markdown, orderedEquals(markdown));
      expect(note.aliases, ['별칭 하나', 'Other Name']);
      expect(
        source.folders,
        containsAllInOrder([
          ['과목'],
          ['과목', '주차'],
        ]),
      );
      expect(source.folders, contains(equals(['빈 폴더'])));
    },
  );

  test('rejects a Markdown file with invalid UTF-8', () async {
    final root = await Directory.systemTemp.createTemp('obsidian-invalid-');
    addTearDown(() => root.delete(recursive: true));
    await File(p.join(root.path, 'broken.md')).writeAsBytes([0xc3, 0x28]);

    await expectLater(_readFolder(root), throwsFormatException);
  });

  test(
    'copies original attachments from a folder with case and bytes intact',
    () async {
      final root = await Directory.systemTemp.createTemp('obsidian-assets-');
      addTearDown(() => root.delete(recursive: true));
      final folder = await Directory(p.join(root.path, '참고 자료')).create();
      await File(p.join(root.path, 'Note.md'))
          .writeAsString('![[참고 자료/그림.PNG]]');
      await File(p.join(folder.path, '그림.PNG'))
          .writeAsBytes([0x89, 0xff, 0x00]);
      await File(p.join(root.path, '문서.PDF')).writeAsBytes([0x25, 0x50]);
      await File(p.join(root.path, '불러오지 않음.svg')).writeAsBytes([0xff]);
      final settings = await Directory(p.join(root.path, '.obsidian')).create();
      await File(p.join(settings.path, 'private.PDF')).writeAsBytes([0xff]);

      final source = await _readFolder(root);

      expect(source.skippedFiles, 1);
      expect(
        source.attachments.map((asset) => asset.fileName),
        unorderedEquals(['그림.PNG', '문서.PDF']),
      );
      final image = source.attachments.singleWhere(
        (asset) => asset.documentKind == 'image',
      );
      expect(image.folders, ['참고 자료']);
      expect(image.bytes, orderedEquals([0x89, 0xff, 0x00]));
      final pdf = source.attachments.singleWhere(
        (asset) => asset.documentKind == 'pdf',
      );
      expect(pdf.folders, isEmpty);
      expect(pdf.bytes, orderedEquals([0x25, 0x50]));
      expect(utf8.decode(source.notes.single.markdown), '![[참고 자료/그림.PNG]]');
    },
  );

  test(
    'opens ZIP root paths and a vault wrapper marked by .obsidian',
    () async {
      final source = await _readZip(
        _zip({
          '내 보관함/.obsidian/app.json': utf8.encode('{}'),
          '내 보관함/과목/노트.md': utf8.encode('[[과목/노트]]'),
          '내 보관함/과목/audio.mp3': [1, 2, 3],
        }),
      );
      expect(source.notes.single.folders, ['과목']);
      expect(source.notes.single.title, '노트');
      expect(source.skippedFiles, 1);

      final rooted = await _readZip(
        _zip({'과목/노트.md': utf8.encode('[[과목/노트]]')}),
      );
      expect(rooted.notes.single.folders, ['과목']);
    },
  );

  test(
    'imports binary originals from an Obsidian ZIP without Markdown',
    () async {
      final source = await _readZip(
        _zip({
          'Vault/.obsidian/app.json': [0xff],
          'Vault/수업/자료/발표.PpTx': [0x50, 0x4b, 0xff],
          'Vault/수업/정리.HWPX': [0x50, 0x4b, 0x00],
          'Vault/audio.mp3': [0xff],
        }),
      );

      expect(source.notes, isEmpty);
      expect(source.skippedFiles, 1);
      final office = source.attachments.singleWhere(
        (asset) => asset.fileName == '발표.PpTx',
      );
      expect(
        source.attachments.map((asset) => asset.documentKind),
        everyElement('office'),
      );
      expect(office.folders, ['수업', '자료']);
      expect(office.bytes, orderedEquals([0x50, 0x4b, 0xff]));
    },
  );

  test(
    'keeps Canvas originals and folder paths from folders and ZIP',
    () async {
      final root = await Directory.systemTemp.createTemp('obsidian-canvas-');
      addTearDown(() => root.delete(recursive: true));
      final folder = await Directory(p.join(root.path, '수업')).create();
      final board = [0xff, 0x20, 0x00];
      await File(p.join(folder.path, '노트.CaNvAs')).writeAsBytes(board);

      final sources = [
        await _readFolder(root),
        await _readZip(_zip({'수업/노트.CaNvAs': board})),
      ];
      for (final source in sources) {
        expect(source.notes, isEmpty);
        expect(source.skippedFiles, 0);
        final canvas = source.attachments.single;
        expect(canvas.documentKind, 'canvas');
        expect(canvas.fileName, '노트.CaNvAs');
        expect(canvas.folders, ['수업']);
        expect(canvas.bytes, orderedEquals(board));
      }
    },
  );

  test('classifies only supported attachment filenames', () {
    for (final entry in {
      'pdf': ['PDF'],
      'image': ['png', 'JPG', 'jpeg', 'WebP'],
      'office': ['doc', 'DOCX', 'odt', 'PPT', 'pptx', 'ODP', 'hwp', 'HWPX'],
      'canvas': ['CaNvAs'],
    }.entries) {
      for (final extension in entry.value) {
        expect(obsidianAttachmentKind('File.$extension'), entry.key);
      }
    }
    for (final name in [
      '.PDF',
      'file',
      'clip.svg',
      'note.MD',
      'folder/file.pdf',
      r'folder\file.pdf',
    ]) {
      expect(obsidianAttachmentKind(name), isNull, reason: name);
    }
  });

  test(
    'preflights per-file and aggregate attachment sizes before expanding ZIP',
    () async {
      final single = _zip({'큰 파일.PDF': List<int>.filled(256, 65)});
      _setExpandedZipSizes(single, 64 * 1024 * 1024 + 1);
      final combined = _zip({
        for (var index = 0; index < 4; index++)
          '$index.docx': List<int>.filled(256, 65),
      });
      _setExpandedZipSizes(combined, 64 * 1024 * 1024);
      for (final bytes in [single, combined]) {
        await expectLater(
          _readZip(bytes),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              contains('64 MiB, 전체 192 MiB'),
            ),
          ),
        );
      }
    },
  );

  test('preflights Canvas size and shared attachment budget', () async {
    const maxBoardBytes = 8 * 1024 * 1024;
    final oversized = _zip({'Board.canvas': List<int>.filled(256, 65)});
    _setExpandedZipSizes(oversized, maxBoardBytes + 1);
    final combined = _zip({
      for (var index = 0; index < 24; index++)
        '$index.canvas': List<int>.filled(256, 65),
      'source.pdf': List<int>.filled(256, 65),
    });
    _setExpandedZipSizes(combined, maxBoardBytes);

    await expectLater(
      _readZip(oversized),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('8 MiB'),
        ),
      ),
    );
    await expectLater(
      _readZip(combined),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('전체 192 MiB'),
        ),
      ),
    );
  });

  test(
    'keeps Markdown when YAML is malformed or aliases are unsupported',
    () async {
      const markdown = '---\naliases: [unterminated\n---\n# Body\n';
      final source = await _readZip(
        _zip({
          'Note.md': utf8.encode(markdown),
          'Other.md': utf8.encode('---\naliases: { key: value }\n---\n# Body'),
        }),
      );
      expect(source.notes.every((note) => note.aliases.isEmpty), isTrue);
      expect(
        utf8.decode(
          source.notes.singleWhere((note) => note.title == 'Note').markdown,
        ),
        markdown,
      );
    },
  );

  test(
    'rejects traversal, Windows-reserved and whitespace-changing paths',
    () async {
      for (final name in [
        '../Outside.md',
        '/Root.md',
        'C:/Drive.md',
        'Con.md',
        ' a.md',
      ]) {
        await expectLater(
          _readZip(
            _zip({
              name: [65],
            }),
          ),
          throwsFormatException,
          reason: name,
        );
      }
    },
  );

  test('rejects conflicting file and folder spellings', () async {
    await expectLater(
      _readZip(
        _zip({
          'A.md': [65],
          'a.MD': [66],
        }),
      ),
      throwsFormatException,
    );
    await expectLater(
      _readZip(
        _zip({
          'Folder/One.md': [65],
          'folder/Two.md': [66],
        }),
      ),
      throwsFormatException,
    );
    await expectLater(
      _readZip(
        _zip({
          'café.md': [65],
          'cafe\u0301.md': [66],
        }),
      ),
      throwsFormatException,
    );
    await expectLater(
      _readZip(
        _zip({
          'Course/File.PDF': [65],
          'Course/file.pdf': [66],
        }),
      ),
      throwsFormatException,
    );
  });

  test(
    'verifies CRC rather than trusting the ZIP library verify flag',
    () async {
      final bytes = _zip({
        'Note.md': [65],
      }, store: true);
      final local = ByteData.sublistView(bytes);
      final dataOffset =
          30 +
          local.getUint16(26, Endian.little) +
          local.getUint16(28, Endian.little);
      bytes[dataOffset] = 66;

      await expectLater(_readZip(bytes), throwsFormatException);
    },
  );

  test('bounds DEFLATE output when both headers advertise less data', () async {
    final bytes = _zip({'Note.md': List<int>.filled(65536, 65)});
    final data = ByteData.sublistView(bytes);
    final central = _centralOffset(bytes);
    expect(data.getUint16(8, Endian.little), 8);
    data.setUint32(22, 1, Endian.little);
    data.setUint32(central + 24, 1, Endian.little);

    await expectLater(_readZip(bytes), throwsFormatException);
  });

  test(
    'rejects ZIP symbolic links and encrypted entries before decoding',
    () async {
      final symbolic = _zip({
        'Note.md': [65],
      });
      final symbolicData = ByteData.sublistView(symbolic);
      symbolicData.setUint32(
        _centralOffset(symbolic) + 38,
        0xa1ff0000,
        Endian.little,
      );
      await expectLater(_readZip(symbolic), throwsFormatException);

      final encrypted = _zip({
        'Note.md': [65],
      });
      final encryptedData = ByteData.sublistView(encrypted);
      final centralFlags = _centralOffset(encrypted) + 8;
      for (final offset in [6, centralFlags]) {
        encryptedData.setUint16(
          offset,
          encryptedData.getUint16(offset, Endian.little) | 1,
          Endian.little,
        );
      }
      await expectLater(_readZip(encrypted), throwsFormatException);
    },
  );
}

int _centralOffset(Uint8List bytes) =>
    ByteData.sublistView(bytes)
        .getUint32(bytes.length - 22 + 16, Endian.little);

void _setExpandedZipSizes(Uint8List bytes, int size) {
  final data = ByteData.sublistView(bytes);
  final end = bytes.length - 22;
  for (var central = _centralOffset(bytes); central < end;) {
    final local = data.getUint32(central + 42, Endian.little);
    expect(data.getUint16(local + 8, Endian.little), 8);
    data.setUint32(local + 22, size, Endian.little);
    data.setUint32(central + 24, size, Endian.little);
    central +=
        46 +
        data.getUint16(central + 28, Endian.little) +
        data.getUint16(central + 30, Endian.little) +
        data.getUint16(central + 32, Endian.little);
  }
}

Future<ObsidianVaultSource> _readFolder(Directory root) =>
    readObsidianVaultFolder(root, normalizeSegments: _normalizeSegments);

Future<ObsidianVaultSource> _readZip(Uint8List bytes) =>
    readObsidianVaultZip(bytes, normalizeSegments: _normalizeSegments);

List<String> _normalizeSegments(List<String> segments) => [
  for (final segment in segments)
    segment.toLowerCase().replaceAll('e\u0301', 'é'),
];

Uint8List _zip(Map<String, List<int>> files, {bool store = false}) {
  final archive = Archive();
  for (final entry in files.entries) {
    final file = ArchiveFile.bytes(entry.key, entry.value);
    if (store) file.compression = CompressionType.none;
    archive.addFile(file);
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}
