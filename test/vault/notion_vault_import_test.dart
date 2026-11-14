import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/native/ink_vault_native.dart';
import 'package:saber/data/vault/block_page_document.dart';
import 'package:saber/data/vault/database_media_snapshot.dart';
import 'package:saber/data/vault/knowledge_index.dart';
import 'package:saber/data/vault/library_store.dart';
import 'package:saber/data/vault/obsidian_vault_import.dart';
import 'package:saber/data/vault/workspace_store.dart';

const _id = '11111111111111111111111111111111';
const _rowId = '22222222222222222222222222222222';
const _otherRowId = '33333333333333333333333333333333';
const _partId = '44444444444444444444444444444444';
const _wrapper = 'Export-44444444-4444-4444-4444-444444444444';
const _table = '작업 $_id';
const _row = '연구 $_rowId';

Uint8List _zip(
  Map<String, List<int>> files, {
  List<String> folders = const [],
}) {
  final archive = Archive();
  for (final folder in folders) {
    archive.addFile(ArchiveFile.directory(folder));
  }
  for (final entry in files.entries) {
    archive.addFile(ArchiveFile.bytes(entry.key, entry.value));
  }
  return ZipEncoder().encodeBytes(archive);
}

void main() {
  final nativeLibrary = Platform.environment['INK_VAULT_NATIVE_LIBRARY'];
  final skip = nativeLibrary == null
      ? 'Set INK_VAULT_NATIVE_LIBRARY to the common engine'
      : false;
  late Directory directory;
  late Directory vaults;
  late InkVaultNative native;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('piv-notion-');
    vaults = Directory(p.join(directory.path, 'vaults'));
    if (nativeLibrary != null) {
      native = InkVaultNative.open(libraryPath: nativeLibrary);
    }
  });
  tearDown(() async {
    final parent = await Directory.systemTemp.resolveSymbolicLinks();
    final owned = await directory.resolveSymbolicLinks();
    expect(p.dirname(owned), parent);
    expect(p.basename(owned), startsWith('piv-notion-'));
    await Directory(owned).delete(recursive: true);
  });

  Future<ObsidianVaultImportResult> runImport(Uint8List zip) =>
      importNotionVault(
        vaultsDirectory: vaults,
        sourceZip: zip,
        sourceName: 'Export',
        native: native,
      );

  test('separate vault reopens with CSV rows, raw Markdown and typed attachment links', () async {
    final dbHref = Uri.encodeComponent('$_table.csv');
    final rowHref =
        '${Uri.encodeComponent(_table)}/${Uri.encodeComponent('$_row.md')}#본문';
    final pdfHref =
        '${Uri.encodeComponent(_table)}/${Uri.encodeComponent('부록 100%.pdf')}';
    final homeText = utf8.encode(
      '# 홈\r\n[작업]($dbHref)\r\n[하위]($rowHref)\r\n[부록]($pdfHref)\r\n',
    );
    final rowText = utf8.encode('## 본문\n**편집할 수 있는 원본**\n');
    final attachment = utf8.encode('%PDF-1.7\nNotion source\n%%EOF');
    final imported = await runImport(
      _zip({
        '홈 $_partId.md': homeText,
        '$_table.csv': utf8.encode('이름,코드,상태\r\n연구,0007,필터됨\r\n'),
        '${_table}_all.csv': utf8.encode(
          '이름,코드,상태\r\n연구,0007,"검토, 완료"\r\n'
          '중복,0008,"다음\n주"\r\n중복,,\r\n',
        ),
        '$_table/$_row.md': rowText,
        '$_table/중복 $_otherRowId.md': utf8.encode('# 중복\n'),
        '$_table/부록 100%.pdf': attachment,
        '$_table/지원하지않음.bin': [1, 2],
      }),
    );
    expect(imported.noteCount, 3);
    expect(imported.databaseCount, 1);
    expect(imported.attachmentCount, 1);
    expect(imported.skippedFiles, 1);
    expect(p.basename(imported.repository.root.path), startsWith('notion-'));
    final root = imported.repository.root;
    await imported.repository.close();
    final reopened = await NoteRepository.open(root);
    addTearDown(reopened.close);
    expect(reopened.integrityIssues, isEmpty);
    final notes = await WorkspaceStore(reopened).list();
    final home = notes.singleWhere((note) => note.title == '홈');
    final rowPage = notes.singleWhere((note) => note.title == '연구');
    final pdf = notes.singleWhere(
      (note) => note.documentKind == VaultDocumentKind.pdf,
    );
    final db = notes.singleWhere(
      (note) => note.documentKind == VaultDocumentKind.database,
    );
    expect(db.title, '작업');
    final homeRevision = (await reopened.heads(home.markdownEntityId)).single;
    final rowRevision = (await reopened.heads(rowPage.markdownEntityId)).single;
    final pdfRevision = (await reopened.heads(pdf.sourceEntityId!)).single;
    expect((await reopened.readFiles(homeRevision))['summary.md'], homeText);
    expect((await reopened.readFiles(rowRevision))['summary.md'], rowText);
    expect((await reopened.readFiles(pdfRevision))['부록 100%.pdf'], attachment);
    final dbRevision = (await reopened.heads(db.inkEntityId)).single;
    final table = DatabaseMediaSnapshot.fromFiles(
      await reopened.readFiles(dbRevision),
    ).database;
    expect(table.id, db.id);
    expect(table.properties.map((property) => property.name), [
      '이름',
      '코드',
      '상태',
    ]);
    expect(
      table.rows.map(
        (row) => table.properties
            .map((property) => row.values[property.id])
            .toList(),
      ),
      [
        ['연구', '0007', '검토, 완료'],
        ['중복', '0008', '다음\n주'],
        ['중복', '', ''],
      ],
    );
    expect(
      BlockPageDocument.fromJson(table.rows.first.body).blocks.single.noteId,
      rowPage.id,
    );
    expect(
      table.rows
          .skip(1)
          .every((row) => BlockPageDocument.fromJson(row.body).blocks.isEmpty),
      isTrue,
    );
    final index = await KnowledgeIndex.build(reopened, native);
    expect(
      index.resolveMarkdownLink(dbHref, fromNoteId: home.id)?.noteId,
      db.id,
    );
    expect(
      index.resolveMarkdownLink(rowHref, fromNoteId: home.id)?.anchor,
      '본문',
    );
    expect(
      index.resolveMarkdownLink(rowHref, fromNoteId: home.id)?.noteId,
      rowPage.id,
    );
    expect(
      index.resolveMarkdownLink(pdfHref, fromNoteId: home.id)?.noteId,
      pdf.id,
    );
    expect(index.backlinks(db.id).map((note) => note.id), contains(home.id));

    final folder = await LibraryStore(reopened).createFolder('옮긴 곳');
    final workspace = WorkspaceStore(reopened, native: native);
    await workspace.moveNote(db, folder.id);
    final movedLink = 'inkwiki:${db.id}';
    final updated = await (await workspace.open(home)).readMarkdown();
    expect(updated, contains('[작업]($movedLink)'));
    expect(updated, contains('[하위]($rowHref)'));
    final movedIndex = await KnowledgeIndex.build(reopened, native);
    expect(
      movedIndex.resolveWikiLink(movedLink, fromNoteId: home.id)?.noteId,
      db.id,
    );
    expect(
      movedIndex.backlinks(db.id).map((note) => note.id),
      contains(home.id),
    );
  }, skip: skip);

  test(
    'recognized split archive shares folders and preserves a cross-part link',
    () async {
      final imported = await runImport(
        _zip({
          '$_wrapper/Export-$_partId-Part-1.zip': _zip(
            {'$_wrapper/과제/첫.md': utf8.encode('[둘](%EB%91%98.md)')},
            folders: ['$_wrapper/과제/'],
          ),
          '$_wrapper/Export-$_partId-Part-2.zip': _zip(
            {'과제/둘.md': utf8.encode('# 둘')},
            folders: ['과제/'],
          ),
        }),
      );
      addTearDown(imported.repository.close);
      expect(imported.folderCount, 1);
      final notes = await WorkspaceStore(imported.repository).list();
      final first = notes.singleWhere((note) => note.title == '첫');
      final second = notes.singleWhere((note) => note.title == '둘');
      final index = await KnowledgeIndex.build(imported.repository, native);
      expect(
        index.resolveMarkdownLink('%EB%91%98.md', fromNoteId: first.id)?.noteId,
        second.id,
      );
    },
    skip: skip,
  );

  test('invalid CSV never publishes a partial vault', () async {
    await expectLater(
      runImport(
        _zip({
          '페이지.md': utf8.encode('# 페이지'),
          '작업.csv': utf8.encode('이름,상태\n누락\n'),
        }),
      ),
      throwsFormatException,
    );
    expect(await vaults.list().map((item) => p.basename(item.path)).toList(), [
      '.imports',
    ]);
    expect(
      await Directory(p.join(vaults.path, '.imports')).list().isEmpty,
      isTrue,
    );
  }, skip: skip);
}
