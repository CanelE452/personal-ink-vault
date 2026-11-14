import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as im;
import 'package:ink_vault_core/drive.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/vault/block_page_document.dart';
import 'package:saber/data/vault/block_page_media.dart';
import 'package:saber/data/vault/block_page_snapshot.dart';
import 'package:saber/data/vault/database_media_snapshot.dart';
import 'package:saber/data/vault/workspace_database.dart';
import 'package:saber/data/vault/workspace_store.dart';

void main() {
  late Directory directory;
  late NoteRepository a, b;
  late _DiskRemote remote;
  late SyncCoordinator sa, sb;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('block-media-disk-sync-');
    a = await NoteRepository.open(
      Directory('${directory.path}/a'),
      createFormatVersion: 2,
    );
    b = await NoteRepository.open(
      Directory('${directory.path}/b'),
      vaultId: a.vaultId,
      createFormatVersion: 2,
    );
    remote = _DiskRemote(Directory('${directory.path}/remote'), a.vaultId);
    await remote.initialize();
    sa = SyncCoordinator(
      repository: a,
      remote: remote,
      stateDirectory: Directory('${directory.path}/sa'),
    );
    sb = SyncCoordinator(
      repository: b,
      remote: remote,
      stateDirectory: Directory('${directory.path}/sb'),
    );
  });
  tearDown(() async {
    await sa.close();
    await sb.close();
    remote.close();
    await a.close();
    await b.close();
    await directory.delete(recursive: true);
  });

  Future<_Seed> seed() async {
    final store = WorkspaceStore(a);
    final note = await store.create(
      'Media page',
      documentKind: VaultDocumentKind.page,
    );
    final session = await store.open(note);
    final image = BlockPageMediaAsset.image(
      name: '필기 사진.png',
      bytes: im.encodePng(im.Image(width: 3, height: 2)),
    );
    final file = BlockPageMediaAsset.attachment(
      name: '자료.pptx',
      bytes: [80, 75, 3, 4, 8, 9],
      mimeType: 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    );
    final picture = BlockPageBlock.create(type: 'image', text: '사진 설명');
    final attachment = BlockPageBlock.create(type: 'attachment', text: '발표 자료');
    final page = const BlockPageDocument.empty().copyWith(
      blocks: [picture, attachment],
      media: {picture.id: image.reference, attachment.id: file.reference},
    );
    final snapshot = BlockPageMediaSnapshot.prepare(
      page,
      existingFiles: {
        'page.json': Uint8List.fromList(
          utf8.encode(jsonEncode(const BlockPageDocument.empty().toJson())),
        ),
        'future/opaque.bin': Uint8List.fromList([0, 255, 7]),
      },
      addedFiles: {
        image.reference.path: image.bytes,
        file.reference.path: file.bytes,
      },
    );
    await session.saveInk(snapshot.files);
    await session.saveMarkdown('별도 Markdown');
    return _Seed(
      note,
      (await a.heads(note.inkEntityId)).single,
      page,
      picture.id,
      attachment.id,
      image,
      file,
    );
  }

  test('a duplicated attachment syncs and remains readable when the original is removed', () async {
    final source = await seed();
    final session = await WorkspaceStore(a).open(source.note);
    final duplicated = source.document.duplicateBlock(source.fileId);
    final copy = duplicated.blocks.last;
    expect(copy.id, isNot(source.fileId));
    final duplicatedFiles = BlockPageMediaSnapshot.prepare(
      duplicated,
      existingFiles: await a.readFiles(source.revision),
    ).files;
    await session.saveInk(duplicatedFiles);
    await sa.syncOnce();
    await sb.syncOnce();
    expect(sa.status.phase, SyncPhase.synced);
    expect(sb.status.phase, SyncPhase.synced);
    final bStore = WorkspaceStore(b);
    final incoming = await bStore.open((await bStore.list()).single);
    final received = BlockPageMediaSnapshot.fromFiles(
      await b.readFiles((await b.heads(incoming.note.inkEntityId)).single),
    );
    expect(received.document.toJson(), duplicated.toJson());
    expect(received.mediaBytes(copy.id), source.file.bytes);
    final edited = received.document.copyWith(
      blocks: [
        received.document.blocks.first,
        received.document.blocks.last.copyWith(text: 'Windows에서 변경'),
      ],
    );
    await incoming.saveInk(
      BlockPageMediaSnapshot.prepare(
        edited,
        existingFiles: received.files,
      ).files,
    );
    await sb.syncOnce();
    await sa.syncOnce();
    expect(sa.status.phase, SyncPhase.synced);
    expect(sb.status.phase, SyncPhase.synced);
    final returned = BlockPageMediaSnapshot.fromFiles(
      await a.readFiles((await a.heads(source.note.inkEntityId)).single),
    );
    expect(returned.document.blocks.last.id, copy.id);
    expect(returned.document.blocks.last.text, 'Windows에서 변경');
    expect(returned.document.media.containsKey(source.fileId), isFalse);
    expect(returned.mediaBytes(copy.id), source.file.bytes);
    expect(returned.files['future/opaque.bin'], [0, 255, 7]);
    expect(
      await (await WorkspaceStore(a).open(source.note)).readMarkdown(),
      '별도 Markdown',
    );
  });

  for (final databaseKind in [false, true]) {
    test(
      'two disk repositories preserve inline ${databaseKind ? 'row' : 'page'} styles through cold reopen and reverse edits',
      () async {
        final source = await seed();
        final store = WorkspaceStore(a);
        final note = databaseKind
            ? await store.create(
                '서식 DB',
                documentKind: VaultDocumentKind.database,
              )
            : source.note;
        final session = await store.open(note);
        const text = 'foobar 한글 😀';
        final blockId = newId();
        final page = BlockPageDocument.fromJson({
          ...source.document.toJson(),
          'version': 3,
          'blocks': [
            {
              'id': blockId,
              'type': 'paragraph',
              'text': text,
              'inlineData': {
                'format': 'personal-ink-inline-1',
                'textSha256': crypto.sha256
                    .convert(utf8.encode(text))
                    .toString(),
                'runs': [
                  {
                    'start': 3,
                    'end': 6,
                    'marks': ['bold', 'underline'],
                  },
                ],
                'futureInline': [1, 2, 3],
              },
            },
            for (final block in source.document.blocks) block.toJson(),
          ],
        });
        final empty = WorkspaceDatabase.empty();
        final row = DatabaseRow.create(body: page.toJson());
        final database = empty.addRow(row);
        final originalFiles = databaseKind
            ? DatabaseMediaSnapshot.prepare(
                database,
                existingFiles: {
                  'database.json': Uint8List.fromList(
                    utf8.encode(jsonEncode(empty.toJson())),
                  ),
                  'future/opaque.bin': Uint8List.fromList([0, 255, 7]),
                },
                addedFiles: {
                  source.image.reference.path: source.image.bytes,
                  source.file.reference.path: source.file.bytes,
                },
              ).files
            : BlockPageMediaSnapshot.prepare(
                page,
                existingFiles: await a.readFiles(source.revision),
              ).files;
        await session.saveInk(originalFiles);
        await session.saveMarkdown('서식과 독립적인 직접 요약');
        final original = (await a.heads(note.inkEntityId)).single;
        await sa.syncOnce();
        await sb.syncOnce();
        expect(sa.status.phase, SyncPhase.synced);
        expect(sb.status.phase, SyncPhase.synced);
        await sb.close();
        await b.close();
        b = await NoteRepository.open(Directory('${directory.path}/b'));
        sb = SyncCoordinator(
          repository: b,
          remote: remote,
          stateDirectory: Directory('${directory.path}/sb'),
        );
        final received = (await b.heads(note.inkEntityId)).single;
        final files = await b.readFiles(received);
        final receivedPage = databaseKind
            ? BlockPageDocument.fromJson(
                DatabaseMediaSnapshot.fromFiles(files)
                    .database
                    .rows
                    .single
                    .body,
              )
            : BlockPageMediaSnapshot.fromFiles(files).document;
        expect(receivedPage.toJson(), page.toJson());
        expect(files[source.image.reference.path], source.image.bytes);
        expect(files[source.file.reference.path], source.file.bytes);
        final remoteNote = (await WorkspaceStore(
          b,
        ).list()).singleWhere((n) => n.id == note.id);
        final remoteSession = await WorkspaceStore(b).open(remoteNote);
        expect(await remoteSession.readMarkdown(), '서식과 독립적인 직접 요약');
        final updated = receivedPage.copyWith(
          blocks: [
            receivedPage.blocks.first.copyWith(text: 'Windows $text'),
            ...receivedPage.blocks.skip(1),
          ],
        );
        final updatedDatabase = database.updateRow(
          row.copyWith(body: updated.toJson()),
        );
        final updatedFiles = databaseKind
            ? DatabaseMediaSnapshot.prepare(
                updatedDatabase,
                existingFiles: files,
              ).files
            : BlockPageMediaSnapshot.prepare(
                updated,
                existingFiles: files,
              ).files;
        await remoteSession.saveInk(updatedFiles);
        await sb.syncOnce();
        await sa.syncOnce();
        final returned = await a.readFiles(
          (await a.heads(note.inkEntityId)).single,
        );
        final returnedPage = databaseKind
            ? BlockPageDocument.fromJson(
                DatabaseMediaSnapshot.fromFiles(returned)
                    .database
                    .rows
                    .single
                    .body,
              )
            : BlockPageMediaSnapshot.fromFiles(returned).document;
        expect(returnedPage.toJson(), updated.toJson());
        final inline = returnedPage.blocks.first.toJson()['inlineData'] as Map;
        expect(inline['futureInline'], [1, 2, 3]);
        expect((inline['runs'] as List).single, {
          'start': 11,
          'end': 14,
          'marks': ['bold', 'underline'],
        });
        expect(returned['future/opaque.bin'], [0, 255, 7]);
        expect(returned[source.image.reference.path], source.image.bytes);
        expect(returned[source.file.reference.path], source.file.bytes);
        final oldFiles = await a.readFiles(original);
        final oldPage = databaseKind
            ? BlockPageDocument.fromJson(
                DatabaseMediaSnapshot.fromFiles(oldFiles)
                    .database
                    .rows
                    .single
                    .body,
              )
            : BlockPageMediaSnapshot.fromFiles(oldFiles).document;
        expect(oldPage.toJson(), page.toJson());
        expect(remote.everyPublishedManifestHadBlobs, isTrue);
        expect(await session.readMarkdown(), '서식과 독립적인 직접 요약');
      },
    );
  }

  test('two disk repositories retain DB row media across cold reopen and caption edits', () async {
    final store = WorkspaceStore(a);
    final note = await store.create(
      'DB media',
      documentKind: VaultDocumentKind.database,
    );
    final session = await store.open(note);
    final image = BlockPageMediaAsset.image(
      name: '자료.png',
      bytes: im.encodePng(im.Image(width: 3, height: 2)),
    );
    final file = BlockPageMediaAsset.attachment(
      name: '첨부.txt',
      bytes: utf8.encode('자료 😀'),
    );
    final picture = BlockPageBlock.create(type: 'image', text: '처음 캡션');
    final attachment = BlockPageBlock.create(type: 'attachment', text: '첨부 설명');
    final body = const BlockPageDocument.empty().copyWith(
      blocks: [picture, attachment],
      media: {picture.id: image.reference, attachment.id: file.reference},
    );
    final empty = WorkspaceDatabase.empty();
    final row = DatabaseRow.create(body: body.toJson());
    final database = empty.addRow(row);
    await session.saveInk(
      DatabaseMediaSnapshot.prepare(
        database,
        existingFiles: {
          'database.json': Uint8List.fromList(
            utf8.encode(jsonEncode(empty.toJson())),
          ),
          'future/opaque.bin': Uint8List.fromList([1, 0, 255]),
          'page.json': Uint8List.fromList([255, 7]),
        },
        addedFiles: {
          image.reference.path: image.bytes,
          file.reference.path: file.bytes,
        },
      ).files,
    );
    await session.saveMarkdown('별도 DB 요약');
    final original = (await a.heads(note.inkEntityId)).single;
    await sa.syncOnce();
    await sb.syncOnce();
    expect(sa.status.phase, SyncPhase.synced);
    expect(sb.status.phase, SyncPhase.synced);
    expect(remote.everyPublishedManifestHadBlobs, isTrue);
    final imageUploads = remote.log
        .where((entry) => entry == 'blob:${image.reference.sha256}')
        .length;
    await sb.close();
    await b.close();
    b = await NoteRepository.open(Directory('${directory.path}/b'));
    sb = SyncCoordinator(
      repository: b,
      remote: remote,
      stateDirectory: Directory('${directory.path}/sb'),
    );
    final received = (await b.heads(note.inkEntityId)).single;
    final snapshot = DatabaseMediaSnapshot.fromFiles(
      await b.readFiles(received),
    );
    expect(snapshot.database.toJson(), database.toJson());
    expect(snapshot.mediaBytes(row.id, picture.id), image.bytes);
    expect(snapshot.mediaBytes(row.id, attachment.id), file.bytes);
    expect(snapshot.files['page.json'], [255, 7]);
    final remoteNote = (await WorkspaceStore(
      b,
    ).list()).singleWhere((value) => value.id == note.id);
    final remoteSession = await WorkspaceStore(b).open(remoteNote);
    expect(await remoteSession.readMarkdown(), '별도 DB 요약');
    final changed = database.updateRow(
      row.copyWith(
        body: body
            .copyWith(
              blocks: [
                picture.copyWith(text: 'Windows에서 고친 캡션'),
                attachment,
              ],
            )
            .toJson(),
      ),
    );
    await remoteSession.saveInk(
      DatabaseMediaSnapshot.prepare(
        changed,
        existingFiles: snapshot.files,
      ).files,
    );
    await sb.syncOnce();
    await sa.syncOnce();
    expect(sa.status.phase, SyncPhase.synced);
    final updated = DatabaseMediaSnapshot.fromFiles(
      await a.readFiles((await a.heads(note.inkEntityId)).single),
    );
    expect(updated.database.toJson(), changed.toJson());
    expect(updated.mediaBytes(row.id, picture.id), image.bytes);
    expect(updated.mediaBytes(row.id, attachment.id), file.bytes);
    expect(updated.files['future/opaque.bin'], [1, 0, 255]);
    expect(updated.files['page.json'], [255, 7]);
    expect(
      remote.log
          .where((entry) => entry == 'blob:${image.reference.sha256}')
          .length,
      imageUploads,
    );
    expect(
      DatabaseMediaSnapshot.fromFiles(await a.readFiles(original)).database
          .toJson(),
      database.toJson(),
    );
  });

  test('two disk repositories exchange tables and retain cell identities after receiver restart', () async {
    final source = await seed();
    final seedFiles = await a.readFiles(source.revision);
    var block = BlockPageBlock.createTable(text: '동기화 표 설명');
    final blank = block.table!;
    block = block.copyWith(
      table: blank.setCellText(
        blank.rows.first.id,
        blank.columns.first,
        'Android 표 내용 😀\n다음 | 줄',
      ),
    );
    final page = BlockPageDocument.fromJson({
      ...source.document.toJson(),
      'futureTablePage': {'preserved': true},
    }).copyWith(blocks: [...source.document.blocks, block]);
    final sessionA = await WorkspaceStore(a).open(source.note);
    await sessionA.saveInk(
      BlockPageMediaSnapshot.prepare(page, existingFiles: seedFiles).files,
    );
    final firstTable = (await a.heads(source.note.inkEntityId)).single;
    final firstFiles = await a.readFiles(firstTable);
    await sa.syncOnce();
    await sb.syncOnce();
    expect(sa.status.phase, SyncPhase.synced);
    expect(sb.status.phase, SyncPhase.synced);
    expect(remote.everyPublishedManifestHadBlobs, isTrue);
    final received = (await b.heads(source.note.inkEntityId)).single;
    expect(received.revisionId, firstTable.revisionId);
    final receivedSnapshot = BlockPageMediaSnapshot.fromFiles(
      await b.readFiles(received),
    );
    expect(receivedSnapshot.document.toJson(), page.toJson());
    expect(
      receivedSnapshot.document.blocks.last.table!.toJson(),
      block.table!.toJson(),
    );
    await sb.close();
    await b.close();
    b = await NoteRepository.open(Directory('${directory.path}/b'));
    sb = SyncCoordinator(
      repository: b,
      remote: remote,
      stateDirectory: Directory('${directory.path}/sb'),
    );
    final cold = BlockPageMediaSnapshot.fromFiles(
      await b.readFiles((await b.heads(source.note.inkEntityId)).single),
    );
    expect(cold.document.toJson(), page.toJson());
    final originalTable = cold.document.blocks.last.table!;
    var changedTable = originalTable.insertRow().insertColumn();
    final newRow = changedTable.rows.last.id,
        newColumn = changedTable.columns.last;
    changedTable = changedTable.setCellText(
      newRow,
      newColumn,
      'Windows 새 셀 한글😀',
    );
    final newCell = changedTable.rows.last.cells.last.id;
    changedTable = changedTable
        .removeRow(originalTable.rows.last.id)
        .removeColumn(originalTable.columns.last)
        .copyWith(headerRow: true, headerColumn: true);
    final edited = cold.document.copyWith(
      blocks: [
        for (final value in cold.document.blocks)
          if (value.id == block.id)
            value.copyWith(table: changedTable)
          else
            value,
      ],
    );
    final noteB = (await WorkspaceStore(
      b,
    ).list()).singleWhere((n) => n.id == source.note.id);
    final sessionB = await WorkspaceStore(b).open(noteB);
    expect(await sessionB.readMarkdown(), '별도 Markdown');
    await sessionB.saveInk(
      BlockPageMediaSnapshot.prepare(edited, existingFiles: cold.files).files,
    );
    await sb.syncOnce();
    await sa.syncOnce();
    expect(sa.status.phase, SyncPhase.synced);
    expect(sb.status.phase, SyncPhase.synced);
    final returned = BlockPageMediaSnapshot.fromFiles(
      await a.readFiles((await a.heads(source.note.inkEntityId)).single),
    );
    expect(returned.document.toJson(), edited.toJson());
    final table = returned.document.blocks.last.table!;
    expect(table.rowCount, 2);
    expect(table.columnCount, 2);
    expect(table.rows.last.id, newRow);
    expect(table.columns.last, newColumn);
    expect(table.rows.last.cells.last.id, newCell);
    expect(table.rows.last.cells.last.text, 'Windows 새 셀 한글😀');
    expect(
      table.rows.first.cells.first.id,
      originalTable.rows.first.cells.first.id,
    );
    expect(table.rows.first.cells.first.text, 'Android 표 내용 😀\n다음 | 줄');
    expect(returned.document.toMarkdown(), contains('Windows 새 셀 한글😀'));
    expect(returned.files['future/opaque.bin'], [0, 255, 7]);
    expect(returned.mediaBytes(source.pictureId), source.image.bytes);
    expect(returned.mediaBytes(source.fileId), source.file.bytes);
    expect(
      await (await WorkspaceStore(a).open(source.note)).readMarkdown(),
      '별도 Markdown',
    );
    expect(await a.readFiles(source.revision), seedFiles);
    expect(await a.readFiles(firstTable), firstFiles);
    expect(await b.readFiles(firstTable), firstFiles);
    expect(remote.everyPublishedManifestHadBlobs, isTrue);
  });

  test(
    'two disk repositories exchange complete page media and later text edits',
    () async {
      final source = await seed();
      await sa.syncOnce();
      expect(sa.status.phase, SyncPhase.synced);
      expect(remote.everyPublishedManifestHadBlobs, isTrue);
      expect(await remote.hasRevision(source.revision.revisionId), isTrue);
      final manifestIndex = remote.log.indexOf(
        'manifest:${source.revision.revisionId}',
      );
      expect(
        remote.log.indexOf('blob:${source.image.reference.sha256}'),
        lessThan(manifestIndex),
      );
      expect(
        remote.log.indexOf('blob:${source.file.reference.sha256}'),
        lessThan(manifestIndex),
      );
      await sb.syncOnce();
      expect(sb.status.phase, SyncPhase.synced);
      final received = (await b.heads(source.note.inkEntityId)).single;
      expect(received.revisionId, source.revision.revisionId);
      final snapshot = BlockPageMediaSnapshot.fromFiles(
        await b.readFiles(received),
      );
      expect(snapshot.document.toJson(), source.document.toJson());
      expect(snapshot.mediaBytes(source.pictureId), source.image.bytes);
      expect(snapshot.mediaBytes(source.fileId), source.file.bytes);
      expect(snapshot.files['future/opaque.bin'], [0, 255, 7]);
      final note = (await WorkspaceStore(
        b,
      ).list()).singleWhere((n) => n.id == source.note.id);
      final session = await WorkspaceStore(b).open(note);
      expect(await session.readMarkdown(), '별도 Markdown');
      final imageUploads = remote.log
          .where((entry) => entry == 'blob:${source.image.reference.sha256}')
          .length;
      final edited = snapshot.document.copyWith(
        blocks: [
          snapshot.document.blocks.first.copyWith(text: 'Windows에서 수정한 설명'),
          snapshot.document.blocks.last,
        ],
      );
      await session.saveInk(
        BlockPageMediaSnapshot.prepare(
          edited,
          existingFiles: snapshot.files,
        ).files,
      );
      await sb.syncOnce();
      await sa.syncOnce();
      expect(sa.status.phase, SyncPhase.synced);
      final updated = (await a.heads(source.note.inkEntityId)).single;
      final updatedSnapshot = BlockPageMediaSnapshot.fromFiles(
        await a.readFiles(updated),
      );
      expect(updatedSnapshot.document.blocks.first.text, 'Windows에서 수정한 설명');
      expect(updatedSnapshot.mediaBytes(source.pictureId), source.image.bytes);
      expect(updatedSnapshot.mediaBytes(source.fileId), source.file.bytes);
      expect(
        remote.log
            .where((entry) => entry == 'blob:${source.image.reference.sha256}')
            .length,
        imageUploads,
      );
      expect(await a.readFiles(source.revision), isNotEmpty);
      expect(
        (await a.readFiles(source.revision))[source.image.reference.path],
        source.image.bytes,
      );
    },
  );

  test('missing media stays pending across receiver restart and activates only after repair', () async {
    final source = await seed();
    await sa.syncOnce();
    final remoteFile = remote.blobFile(source.image.reference.sha256);
    final payload = await remoteFile.readAsBytes();
    await remoteFile.delete();
    await sb.syncOnce();
    expect(sb.status.phase, SyncPhase.retryWaiting);
    expect(sb.status.pendingDownloads, greaterThanOrEqualTo(1));
    expect(
      (await b.heads(source.note.inkEntityId)).map((r) => r.revisionId),
      isNot(contains(source.revision.revisionId)),
    );
    expect(
      (await b.revisions()).map((r) => r.revisionId),
      isNot(contains(source.revision.revisionId)),
    );
    await sb.close();
    await b.close();
    b = await NoteRepository.open(Directory('${directory.path}/b'));
    sb = SyncCoordinator(
      repository: b,
      remote: remote,
      stateDirectory: Directory('${directory.path}/sb'),
    );
    await remoteFile.writeAsBytes(payload, flush: true);
    await sb.syncOnce(force: true);
    expect(sb.status.phase, SyncPhase.synced);
    final received = (await b.heads(source.note.inkEntityId)).single;
    expect(received.revisionId, source.revision.revisionId);
    expect(
      BlockPageMediaSnapshot.fromFiles(await b.readFiles(received))
          .mediaBytes(source.pictureId),
      source.image.bytes,
    );
  });

  test('corrupt remote media cannot activate its page manifest', () async {
    final source = await seed();
    await sa.syncOnce();
    final remoteFile = remote.blobFile(source.file.reference.sha256);
    final original = await remoteFile.readAsBytes();
    final corrupt = Uint8List.fromList(original)..[0] ^= 1;
    await remoteFile.writeAsBytes(corrupt, flush: true);
    await sb.syncOnce();
    expect(sb.status.phase, SyncPhase.error);
    expect(
      (await b.heads(source.note.inkEntityId)).map((r) => r.revisionId),
      isNot(contains(source.revision.revisionId)),
    );
    expect(
      (await b.revisions()).map((r) => r.revisionId),
      isNot(contains(source.revision.revisionId)),
    );
    await remoteFile.writeAsBytes(original, flush: true);
    sb.resume();
    await sb.syncOnce(force: true);
    expect(sb.status.phase, SyncPhase.synced);
    final received = (await b.heads(source.note.inkEntityId)).single;
    expect(
      BlockPageMediaSnapshot.fromFiles(await b.readFiles(received))
          .mediaBytes(source.fileId),
      source.file.bytes,
    );
  });

  test(
    'a media upload failure publishes no incomplete page manifest',
    () async {
      final source = await seed();
      remote.failBlobHash = source.image.reference.sha256;
      await sa.syncOnce();
      expect(sa.status.phase, SyncPhase.retryWaiting);
      expect(await remote.hasRevision(source.revision.revisionId), isFalse);
      expect(
        remote.log,
        isNot(contains('manifest:${source.revision.revisionId}')),
      );
      expect(remote.everyPublishedManifestHadBlobs, isTrue);
      remote.failBlobHash = null;
      await sa.syncOnce(force: true);
      expect(sa.status.phase, SyncPhase.synced);
      expect(await remote.hasRevision(source.revision.revisionId), isTrue);
      await sb.syncOnce();
      expect(sb.status.phase, SyncPhase.synced);
      final received = (await b.heads(source.note.inkEntityId)).single;
      expect(
        BlockPageMediaSnapshot.fromFiles(await b.readFiles(received))
            .mediaBytes(source.pictureId),
        source.image.bytes,
      );
    },
  );
}

class _Seed {
  new(
    this.note,
    this.revision,
    this.document,
    this.pictureId,
    this.fileId,
    this.image,
    this.file,
  );
  final VaultNote note;
  final RevisionRecord revision;
  final BlockPageDocument document;
  final String pictureId, fileId;
  final BlockPageMediaAsset image, file;
}

/// A filesystem transport fixture; these tests do not contact Google Drive.
class _DiskRemote implements RemoteStore {
  new(this.root, this.vaultId);
  final Directory root;
  @override
  final String vaultId;
  @override
  String get remoteId => 'disk-media-fixture';
  final log = <String>[];
  var everyPublishedManifestHadBlobs = true;
  String? failBlobHash;

  Future<void> initialize() async {
    await Directory('${root.path}/blobs').create(recursive: true);
    await Directory('${root.path}/manifests').create(recursive: true);
    await File('${root.path}/events.json').writeAsString('[]', flush: true);
  }

  File blobFile(String hash) {
    validateHash(hash);
    return File('${root.path}/blobs/$hash');
  }

  File _manifest(String id) {
    if (!RegExp(r'^remote-[0-9a-f-]+$').hasMatch(id)) {
      throw const FormatException('Invalid fixture file ID');
    }
    return File('${root.path}/manifests/$id.json');
  }

  Future<List<String>> _events() async => (jsonDecode(
    await File('${root.path}/events.json').readAsString(),
  ) as List).cast<String>();

  Future<bool> hasRevision(String revisionId) async =>
      (await _manifests()).values.any((r) => r.revisionId == revisionId);

  Future<Map<String, RevisionRecord>> _manifests() async {
    final result = <String, RevisionRecord>{};
    await for (final file in Directory(
      '${root.path}/manifests',
    ).list(followLinks: false)) {
      if (file is! File || !file.path.endsWith('.json')) continue;
      final id = file.uri.pathSegments.last.substring(
        0,
        file.uri.pathSegments.last.length - 5,
      );
      result[id] = RevisionRecord.fromJson(
        jsonObject(jsonDecode(await file.readAsString())),
      );
    }
    return result;
  }

  @override
  Future<String> generateId() async => 'remote-${newId()}';

  @override
  Future<String?> findBlob(BlobRef ref) async =>
      blobFile(ref.hash).existsSync() ? ref.hash : null;

  @override
  Future<void> putBlob(
    BlobRef ref,
    Uint8List bytes,
    String intentFileId,
  ) async {
    if (ref.hash == failBlobHash) {
      throw RemoteException.retryable('Synthetic media upload failure');
    }
    if (bytes.length != ref.length ||
        crypto.sha256.convert(bytes).toString() != ref.hash) {
      throw const FormatException('Invalid fixture blob upload');
    }
    final file = blobFile(ref.hash);
    if (file.existsSync()) {
      if (crypto.sha256.convert(await file.readAsBytes()).toString() !=
          ref.hash) {
        throw const FormatException('Immutable fixture blob collision');
      }
      return;
    }
    await file.writeAsBytes(bytes, flush: true);
    log.add('blob:${ref.hash}');
  }

  @override
  Future<void> publishRevision(
    RevisionRecord record,
    String intentFileId,
  ) async {
    for (final ref in record.blobs.values) {
      final file = blobFile(ref.hash);
      if (!file.existsSync()) {
        everyPublishedManifestHadBlobs = false;
        throw const FormatException('Fixture manifest preceded its blob');
      }
      final bytes = await file.readAsBytes();
      if (bytes.length != ref.length ||
          crypto.sha256.convert(bytes).toString() != ref.hash) {
        everyPublishedManifestHadBlobs = false;
        throw const FormatException(
          'Fixture manifest referenced a damaged blob',
        );
      }
    }
    final file = _manifest(intentFileId);
    final encoded = jsonEncode(record.toJson());
    if (file.existsSync()) {
      if (await file.readAsString() != encoded) {
        throw const FormatException('Immutable fixture manifest collision');
      }
      return;
    }
    await file.writeAsString(encoded, flush: true);
    final events = await _events();
    events.add(intentFileId);
    await File('${root.path}/events.json')
        .writeAsString(jsonEncode(events), flush: true);
    log.add('manifest:${record.revisionId}');
  }

  @override
  Future<RevisionRecord> readManifest(String fileId) async {
    final file = _manifest(fileId);
    if (!file.existsSync())
      throw RemoteException.missing('Fixture manifest absent');
    return RevisionRecord.fromJson(
      jsonObject(jsonDecode(await file.readAsString())),
    );
  }

  @override
  Future<Uint8List> readBlob(BlobRef ref) async {
    final file = blobFile(ref.hash);
    if (!file.existsSync())
      throw RemoteException.missing('Fixture blob absent');
    return file.readAsBytes();
  }

  @override
  Future<String> startPageToken() async => (await _events()).length.toString();

  @override
  Future<RemotePage> listManifests({String? pageToken}) async {
    final ids = (await _manifests()).keys.toList()..sort();
    final offset = int.parse(pageToken ?? '0');
    return RemotePage(ids.skip(offset).map(RemoteChange.new).toList());
  }

  @override
  Future<RemotePage> readChanges(String pageToken) async {
    final events = await _events();
    final offset = int.tryParse(pageToken);
    if (offset == null || offset < 0 || offset > events.length) {
      throw RemoteException.invalidCursor();
    }
    return RemotePage(
      events.skip(offset).map(RemoteChange.new).toList(),
      newStartPageToken: events.length.toString(),
    );
  }

  @override
  void close() {}
}
