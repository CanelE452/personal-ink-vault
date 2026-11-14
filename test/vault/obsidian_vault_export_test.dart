import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/native/ink_vault_native.dart';
import 'package:saber/data/vault/library_store.dart';
import 'package:saber/data/vault/obsidian_vault_export.dart';
import 'package:saber/data/vault/obsidian_vault_source.dart';
import 'package:saber/data/vault/workspace_store.dart';

void main() {
  final nativePath = Platform.environment['INK_VAULT_NATIVE_LIBRARY'];

  test(
    'exports an entire folder tree, edited Markdown and original files',
    () async {
      final native = InkVaultNative.open(libraryPath: nativePath);
      final temporaryRoot = await Directory.systemTemp.resolveSymbolicLinks();
      final temp = await Directory.systemTemp.createTemp(
        'piv-obsidian-export-',
      );
      addTearDown(() async {
        final owned = await temp.resolveSymbolicLinks();
        expect(p.dirname(owned), temporaryRoot);
        expect(p.basename(owned), startsWith('piv-obsidian-export-'));
        await Directory(owned).delete(recursive: true);
      });
      final repository = await NoteRepository.open(
        temp,
        createFormatVersion: 2,
      );
      addTearDown(repository.close);
      final store = WorkspaceStore(repository);
      final library = LibraryStore(repository);
      final course = await library.createFolder('수업');
      await library.createFolder('빈 폴더', parentId: course.id);
      final other = await library.createFolder('읽을 자료');
      final disallowed = await library.createFolder('해시#폴더');
      final collision = await library.createFolder('해시_폴더');
      final note = await store.createMarkdown(
        '강의',
        utf8.encode('처음 내용'),
        folderId: course.id,
      );
      final session = await store.open(note);
      await session.saveMarkdown('편집한 내용');
      await store.createMarkdown(
        '강의',
        utf8.encode('별개 노트'),
        folderId: other.id,
      );
      await store.createMarkdown(
        '기호[제목]',
        utf8.encode('안전한 이름'),
        folderId: disallowed.id,
      );
      await store.createMarkdown(
        '기호[제목]',
        utf8.encode('다른 폴더'),
        folderId: collision.id,
      );
      final original = utf8.encode('%PDF-1.7\nsynthetic original\n%%EOF\n');
      final pdf = await store.createWithSource(
        'PDF 표시 이름',
        fileName: '원본.pdf',
        bytes: original,
        documentKind: VaultDocumentKind.pdf,
        folderId: other.id,
        fromObsidian: true,
      );
      await (await store.open(pdf)).saveMarkdown('PDF와 함께 저장한 요약');
      final handwritten = await store.create('필기', folderId: course.id);
      await (await store.open(handwritten)).saveMarkdown('필기의 Markdown 요약');
      final board = await store.createWithSource(
        'Canvas 표시 이름',
        fileName: '원본.canvas',
        bytes: utf8.encode('{"nodes":[],"edges":[]}'),
        documentKind: VaultDocumentKind.canvas,
        folderId: course.id,
        fromObsidian: true,
      );
      final editedBoard = utf8.encode(
        jsonEncode({
          'nodes': [
            {
              'id': 'note',
              'type': 'text',
              'x': 0,
              'y': 0,
              'width': 200,
              'height': 100,
              'text': '편집한 Canvas',
            },
          ],
          'edges': [],
        }),
      );
      await (await store.open(board)).saveInk({'board.canvas': editedBoard});
      await store.create('앱 전용 페이지', documentKind: VaultDocumentKind.page);

      final export = await buildObsidianVaultExport(
        repository: repository,
        native: native,
      );
      expect(export.folders, contains('수업/빈 폴더'));
      expect(export.files['읽을 자료/원본.pdf'], original);
      expect(
        utf8.decode(export.files['수업/원본.canvas']!),
        contains('편집한 Canvas'),
      );
      expect(
        export.files.keys.any((path) => path.contains('앱 전용 페이지')),
        isFalse,
      );
      expect(
        export.warnings.any((warning) => warning.contains('앱 전용 페이지')),
        isTrue,
      );
      expect(export.folders.any((path) => path.contains('#')), isFalse);
      expect(export.files.keys.any((path) => path.contains('[')), isFalse);
      final report = jsonDecode(
        utf8.decode(export.files[obsidianVaultExportReportPath]!),
      ) as Map;
      expect(report['omissions'], contains(containsPair('title', '앱 전용 페이지')));

      final zip = encodeObsidianVaultZip(
        files: export.files,
        folders: export.folders,
      );
      final restored = await readObsidianVaultZip(
        zip,
        normalizeSegments: (parts) {
          final result = native.invoke({
            'op': 'normalize_workspace_segments',
            'segments': parts,
          });
          return (result['segments'] as List).cast<String>();
        },
      );
      expect(restored.folders, contains(equals(['수업', '빈 폴더'])));
      final noteBodies = {
        for (final note in restored.notes)
          [...note.folders, note.title].join('/'): utf8.decode(note.markdown),
      };
      expect(noteBodies['수업/강의'], '편집한 내용');
      expect(noteBodies['읽을 자료/강의'], '별개 노트');
      expect(noteBodies['읽을 자료/원본'], 'PDF와 함께 저장한 요약');
      expect(noteBodies['수업/필기'], '필기의 Markdown 요약');
      expect(
        noteBodies.entries
            .where((entry) => entry.key.startsWith('해시_폴더'))
            .map((entry) => entry.value),
        unorderedEquals(['안전한 이름', '다른 폴더']),
      );
      expect(restored.skippedFiles, 0);
      expect(
        restored.attachments
            .singleWhere((item) => item.fileName == '원본.pdf')
            .bytes,
        original,
      );

      await session.saveMarkdown('내보낸 뒤 수정');
      await expectLater(export.ensureCurrent(), throwsStateError);
    },
    skip: nativePath == null ? 'Set INK_VAULT_NATIVE_LIBRARY' : false,
  );
}
