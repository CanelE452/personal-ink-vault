import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/vault/block_inline_text.dart';
import 'package:saber/data/vault/block_page_document.dart';
import 'package:saber/data/vault/block_page_media.dart';
import 'package:saber/data/vault/block_page_synced_reference.dart';
import 'package:saber/data/vault/library_store.dart';
import 'package:saber/data/vault/note_link.dart';
import 'package:saber/data/vault/synced_block_store.dart';
import 'package:saber/data/vault/workspace_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late NoteRepository repo;
  late WorkspaceStore workspace;
  late SyncedBlockStore synced;
  late BlockPageBlock original;
  late BlockPageBlock child;
  late NoteSession source;

  Future<NoteSession> createPage(
    String title,
    List<BlockPageBlock> blocks, {
    Map<String, Uint8List> other = const {},
  }) async {
    final note = await workspace.create(
      title,
      documentKind: VaultDocumentKind.page,
    );
    final session = await workspace.open(note);
    await writePage(session, blocks, other: other);
    return session;
  }

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('piv-synced-');
    repo = await NoteRepository.open(
      Directory(p.join(temp.path, 'vault')),
      createFormatVersion: 2,
    );
    workspace = WorkspaceStore(repo);
    synced = SyncedBlockStore(repo);
    child = BlockPageBlock.create(type: 'paragraph', text: '자식은 그대로');
    original = BlockPageBlock.create(
      type: 'heading2',
      text: '원래 문장',
    ).copyWith(children: [child]);
    source = await createPage(
      '원본',
      [original],
      other: {
        'future/binary.bin': Uint8List.fromList([0, 51, 255]),
      },
    );
  });
  tearDown(() async {
    await repo.close();
    final root = await Directory.systemTemp.resolveSymbolicLinks();
    final path = await temp.resolveSymbolicLinks();
    expect(p.dirname(path), root);
    expect(p.basename(path), startsWith('piv-synced-'));
    await Directory(path).delete(recursive: true);
  });

  BlockSyncedReference reference() => BlockSyncedReference.create(
    sourceNoteId: source.note.id,
    sourceBlockId: original.id,
  );

  test('two saved links edit the same original block and keep both host revisions unchanged', () async {
    final ref = reference();
    final firstLink = BlockPageBlock.createSyncedBlock(reference: ref);
    final secondLink = BlockPageBlock.createSyncedBlock(reference: ref);
    final first = await createPage('첫 페이지', [firstLink]);
    final second = await createPage('둘째 페이지', [secondLink]);
    final sourceBefore = source.inkParents.single;
    final firstBefore = first.inkParents.single;
    final secondBefore = second.inkParents.single;
    expect(
      (await synced.listSources(source.note.id)).map((item) => item.block.id),
      [original.id, child.id],
    );
    final readA = await synced.open(ref);
    final readB = await synced.open(ref);
    expect(readA.block.text, '원래 문장');
    await synced.saveText(
      readA,
      owner: first,
      ownerBlockId: firstLink.id,
      text: '어느 쪽에서든 편집 😀',
      requireWrite: () {},
    );
    expect((await synced.open(ref)).block.text, '어느 쪽에서든 편집 😀');
    expect((await synced.open(ref)).block.children.single.id, child.id);
    expect(
      (await repo.heads(first.note.inkEntityId)).single.revisionId,
      firstBefore,
    );
    expect(
      (await repo.heads(second.note.inkEntityId)).single.revisionId,
      secondBefore,
    );
    final sourceHead = (await repo.heads(source.note.inkEntityId)).single;
    expect(sourceHead.parentRevisionIds, [sourceBefore]);
    expect((await repo.readFiles(sourceHead))['future/binary.bin'], [
      0,
      51,
      255,
    ]);
    await expectLater(
      synced.saveText(
        readB,
        owner: second,
        ownerBlockId: secondLink.id,
        text: '오래된 편집',
        requireWrite: () {},
      ),
      throwsStateError,
    );
    final fresh = await SyncedBlockStore(repo).open(ref);
    await synced.saveText(
      fresh,
      owner: second,
      ownerBlockId: secondLink.id,
      text: '둘째에서도 저장',
      requireWrite: () {},
    );
    expect((await synced.open(ref)).block.text, '둘째에서도 저장');
    final current = await synced.open(ref);
    final unchanged = (await repo.heads(source.note.inkEntityId))
        .single
        .revisionId;
    await synced.saveText(
      current,
      owner: first,
      ownerBlockId: firstLink.id,
      text: current.block.text,
      requireWrite: () {},
    );
    expect(
      (await repo.heads(source.note.inkEntityId)).single.revisionId,
      unchanged,
    );
  });

  test(
    'unsaved, removed, switched and dangling references cannot publish',
    () async {
      final ref = reference();
      final link = BlockPageBlock.createSyncedBlock(reference: ref);
      final host = await createPage('페이지', [link]);
      final target = await synced.open(ref);
      final base = (await repo.heads(source.note.inkEntityId))
          .single
          .revisionId;
      await expectLater(
        synced.saveText(
          target,
          owner: host,
          ownerBlockId: newId(),
          text: '없는 참조',
          requireWrite: () {},
        ),
        throwsStateError,
      );
      await expectLater(
        synced.saveText(
          target,
          owner: host,
          ownerBlockId: link.id,
          text: '다른 페이지',
          requireWrite: () => throw StateError('owner switched'),
        ),
        throwsStateError,
      );
      await writePage(host, []);
      await expectLater(
        synced.saveText(
          target,
          owner: host,
          ownerBlockId: link.id,
          text: '지워진 참조',
          requireWrite: () {},
        ),
        throwsStateError,
      );
      expect(
        (await repo.heads(source.note.inkEntityId)).single.revisionId,
        base,
      );
      await writePage(source, []);
      await expectLater(synced.open(ref), throwsStateError);
    },
  );

  test('a second vault copy resolves the same source after receiving its only new revision', () async {
    const text = '원래 문장';
    final styled = original.copyWith(
      inlineText: BlockInlineText.plain(text).toggleMark(0, 2, InlineMark.bold),
    );
    await writePage(source, [styled]);
    final link = BlockPageBlock.createSyncedBlock(reference: reference());
    final host = await createPage('받는 페이지', [link]);
    final peer = await NoteRepository.open(
      Directory(p.join(temp.path, 'peer')),
      vaultId: repo.vaultId,
      createFormatVersion: 2,
    );
    addTearDown(peer.close);
    for (final revision in await repo.revisions()) {
      final sourceFiles = await repo.readFiles(revision);
      await peer.importRevision(
        revision,
        blobsByHash: {
          for (final entry in revision.blobs.entries)
            entry.value.hash: sourceFiles[entry.key]!,
        },
      );
    }
    expect(peer.pendingRevisionCount, 0);
    expect(peer.integrityIssues, isEmpty);
    final peerStore = SyncedBlockStore(peer);
    final hostHead = (await peer.heads(host.note.inkEntityId)).single;
    final peerPage = BlockPageDocument.fromJson(
      jsonObject(
        jsonDecode(
          utf8.decode(await peer.readRevisionFile(hostHead, 'page.json')),
        ),
      ),
    );
    final peerRef = peerPage.blocks.single.syncedBlock!;
    expect((await peerStore.open(peerRef)).block.text, text);
    await synced.saveText(
      await synced.open(reference()),
      owner: host,
      ownerBlockId: link.id,
      text: '원래 문장 그리고 추가 😀',
      requireWrite: () {},
    );
    final newRevision = (await repo.heads(source.note.inkEntityId)).single;
    final bytes = await repo.readFiles(newRevision);
    await peer.importRevision(
      newRevision,
      blobsByHash: {
        for (final entry in newRevision.blobs.entries)
          entry.value.hash: bytes[entry.key]!,
      },
    );
    final received = await peerStore.open(peerRef);
    expect(received.block.text, '원래 문장 그리고 추가 😀');
    expect(received.block.inlineText?.hasMark(0, 2, InlineMark.bold), isTrue);
    expect(received.block.children.single.id, child.id);
    expect(
      (await peer.heads(host.note.inkEntityId)).single.revisionId,
      hostHead.revisionId,
    );
    await peer.close();
  });

  test('detach copies a formatted subtree and its media into just the chosen occurrence', () async {
    final attachment = BlockPageBlock.create(type: 'attachment', text: '자료');
    final asset = BlockPageMediaAsset.attachment(
      name: '자료.txt',
      bytes: utf8.encode('확인할 첨부'),
    );
    final table = BlockPageBlock.createTable(rows: 1, columns: 1);
    final noteLink = NoteLink(source.note.id).toString();
    final styled = original.copyWith(
      inlineText: BlockInlineText.plain(original.text)
          .toggleMark(0, 2, InlineMark.bold)
          .setLink(0, 2, noteLink),
      children: [child, attachment, table],
    );
    final sourcePage = const BlockPageDocument.empty().copyWith(
      blocks: [styled],
      media: {attachment.id: asset.reference},
    );
    await source.saveInk({
      'page.json': Uint8List.fromList(
        utf8.encode(jsonEncode(sourcePage.toJson())),
      ),
      asset.reference.path: asset.bytes,
      'future/binary.bin': Uint8List.fromList([0, 51, 255]),
    });
    final ref = reference();
    final link = BlockPageBlock.createSyncedBlock(reference: ref);
    final sibling = BlockPageBlock.createSyncedBlock(reference: ref);
    final another = BlockPageBlock.createSyncedBlock(reference: ref);
    final first = await createPage(
      '독립시킬 페이지',
      [link, sibling],
      other: {
        'future/host.bin': Uint8List.fromList([8]),
      },
    );
    final second = await createPage('다른 연결 페이지', [another]);
    final sourceBefore = (await repo.heads(source.note.inkEntityId)).single;
    final sourceFiles = await repo.readFiles(sourceBefore);
    final hostBefore = first.inkParents.single;
    final secondBefore = second.inkParents.single;
    final next = await synced.detach(
      await synced.open(ref),
      owner: first,
      ownerBlockId: link.id,
      requireWrite: () {},
    );
    final hostHead = (await repo.heads(first.note.inkEntityId)).single;
    final files = await repo.readFiles(hostHead);
    final persisted = BlockPageDocument.fromJson(
      jsonObject(jsonDecode(utf8.decode(files['page.json']!))),
    );
    expect(first.inkParents, [hostHead.revisionId]);
    expect(hostHead.parentRevisionIds, [hostBefore]);
    expect(next.toJson(), persisted.toJson());
    expect(persisted.version, 3);
    final copied = persisted.blocks.first;
    expect(copied.id, link.id);
    expect(copied.syncedBlock, isNull);
    expect(copied.type, original.type);
    expect(copied.text, original.text);
    expect(copied.inlineText?.hasMark(0, 2, InlineMark.bold), isTrue);
    expect(copied.inlineText?.runs.single.link, noteLink);
    expect(copied.children[0].id, isNot(child.id));
    expect(copied.children[0].text, child.text);
    expect(copied.children[1].id, isNot(attachment.id));
    expect(copied.children[2].id, isNot(table.id));
    expect(copied.children[2].table?.toJson(), table.table!.toJson());
    expect(persisted.media.keys, [copied.children[1].id]);
    expect(persisted.media.values.single.toJson(), asset.reference.toJson());
    expect(files[asset.reference.path], asset.bytes);
    expect(files['future/host.bin'], [8]);
    expect(files, isNot(contains('future/binary.bin')));
    expect(persisted.blocks.last.toJson(), sibling.toJson());
    expect(
      (await repo.heads(source.note.inkEntityId)).single.revisionId,
      sourceBefore.revisionId,
    );
    expect(await repo.readFiles(sourceBefore), sourceFiles);
    expect(
      (await repo.heads(second.note.inkEntityId)).single.revisionId,
      secondBefore,
    );
    await synced.saveText(
      await synced.open(ref),
      owner: second,
      ownerBlockId: another.id,
      text: '원본에만 추가',
      requireWrite: () {},
    );
    expect((await synced.open(ref)).block.text, '원본에만 추가');
    expect(
      (await repo.heads(first.note.inkEntityId)).single.revisionId,
      hostHead.revisionId,
    );
    expect((await repo.readFiles(hostHead))['page.json'], files['page.json']);
    await repo.close();
    repo = await NoteRepository.open(Directory(p.join(temp.path, 'vault')));
    final reopened = (await repo.heads(first.note.inkEntityId)).single;
    expect(reopened.revisionId, hostHead.revisionId);
    expect(await repo.readFiles(reopened), files);
    expect(
      (await SyncedBlockStore(repo).open(persisted.blocks.last.syncedBlock!))
          .block
          .text,
      '원본에만 추가',
    );
    expect(copied.text, original.text);
  });

  test('detach rejects stale source ancestry, host revisions and opaque descendants', () async {
    final folder = await LibraryStore(repo).createFolder('자료');
    final note = await workspace.create(
      '폴더 원본',
      folderId: folder.id,
      documentKind: VaultDocumentKind.page,
    );
    final inFolder = await workspace.open(note);
    await writePage(inFolder, [original]);
    final ref = BlockSyncedReference.create(
      sourceNoteId: note.id,
      sourceBlockId: original.id,
    );
    final link = BlockPageBlock.createSyncedBlock(reference: ref);
    final host = await createPage('독립시킬 페이지', [link]);
    final prior = host.inkParents.single;
    final stale = await synced.open(ref);
    await repo.commit(
      entityId: folder.id,
      kind: EntityKind.folder,
      files: {
        'folder.json': Uint8List.fromList(utf8.encode('{"title":"이름 변경"}')),
      },
      parentRevisionIds: [folder.revision.revisionId],
    );
    Future<BlockPageDocument> detach(
      SyncedBlockTarget target,
      NoteSession owner,
    ) => synced.detach(
      target,
      owner: owner,
      ownerBlockId: link.id,
      requireWrite: () {},
    );
    await expectLater(detach(stale, host), throwsStateError);
    expect((await repo.heads(host.note.inkEntityId)).single.revisionId, prior);
    final fresh = await synced.open(ref);
    final peer = await workspace.open(host.note);
    await writePage(peer, [link, BlockPageBlock.create(text: '새 저장')]);
    await expectLater(detach(fresh, host), throwsStateError);
    final unknown = BlockPageBlock.create(type: 'futureBlock', text: 'opaque');
    await writePage(inFolder, [
      original.copyWith(children: [unknown]),
    ]);
    await expectLater(detach(fresh, peer), throwsStateError);
    await expectLater(detach(await synced.open(ref), peer), throwsStateError);
    expect(
      (await repo.heads(host.note.inkEntityId)).single.revisionId,
      peer.inkParents.single,
    );
  });

  for (final editBetweenAttempts in [false, true]) {
    test(
      'failed publication can ${editBetweenAttempts ? 'leave room for an ordinary edit' : 'retry the same detach'}',
      () async {
        final link = BlockPageBlock.createSyncedBlock(reference: reference());
        final host = await createPage('다시 시도할 페이지', [link]);
        final prior = host.inkParents.single;
        final selected = await synced.open(reference());
        var failedBeforeRename = false;
        void failAtManifest() {
          final revisions = Directory(p.join(repo.root.path, 'revisions'));
          if (revisions.listSync().any(
            (file) =>
                p.basename(file.path).contains('.json.') &&
                file.path.endsWith('.tmp'),
          )) {
            failedBeforeRename = true;
            throw StateError('simulated failure before publish');
          }
        }

        await expectLater(
          synced.detach(
            selected,
            owner: host,
            ownerBlockId: link.id,
            requireWrite: failAtManifest,
          ),
          throwsStateError,
        );
        expect(failedBeforeRename, isTrue);
        expect(host.inkParents, [prior]);
        expect(
          (await repo.heads(host.note.inkEntityId)).single.revisionId,
          prior,
        );
        if (editBetweenAttempts) {
          await writePage(host, [link, BlockPageBlock.create(text: '별도 수정')]);
        }
        final retried = await synced.detach(
          selected,
          owner: host,
          ownerBlockId: link.id,
          requireWrite: () {},
        );
        expect(retried.blocks.first.syncedBlock, isNull);
        expect(retried.blocks.first.id, link.id);
        expect(retried.blocks.length, editBetweenAttempts ? 2 : 1);
      },
    );
  }

  test(
    'model preserves unknown synced formats and rejects invalid known IDs',
    () {
      final ref = reference();
      final link = BlockPageBlock.createSyncedBlock(
        reference: ref,
        text: '표시 이름',
      );
      final roundTrip = BlockPageBlock.fromJson(link.toJson());
      expect(roundTrip.syncedBlock?.toJson(), ref.toJson());
      expect(roundTrip.noteId, source.note.id);
      final page = const BlockPageDocument.empty().copyWith(
        blocks: [roundTrip],
      );
      expect(page.toLinkProjection(), contains('inkwiki:${source.note.id}'));
      final future = {
        ...link.toJson(),
        'syncedBlockData': {
          'format': 'later-2',
          'future': [1],
        },
      };
      expect(BlockPageBlock.fromJson(future).syncedBlock, isNull);
      expect(BlockPageBlock.fromJson(future).toJson(), future);
      expect(
        () => BlockPageBlock.fromJson({
          ...link.toJson(),
          'syncedBlockData': {...ref.toJson(), 'sourceBlockId': 'broken'},
        }),
        throwsFormatException,
      );
    },
  );
}

Future<void> writePage(
  NoteSession session,
  List<BlockPageBlock> blocks, {
  Map<String, Uint8List> other = const {},
}) async {
  final page = const BlockPageDocument.empty().copyWith(blocks: blocks);
  await session.saveInk({
    ...other,
    'page.json': Uint8List.fromList(utf8.encode(jsonEncode(page.toJson()))),
  });
}
