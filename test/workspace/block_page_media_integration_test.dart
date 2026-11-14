import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as im;
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/vault/block_page_document.dart';
import 'package:saber/data/vault/block_page_media.dart';
import 'package:saber/data/vault/block_page_snapshot.dart';
import 'package:saber/data/vault/discussion_anchor.dart';
import 'package:saber/data/vault/discussion_store.dart';
import 'package:saber/data/vault/workspace_database.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/pages/workspace/workspace_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'ordinary v1 page text save preserves an existing opaque snapshot file',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'page-media-preservation-',
      );
      final controller = WorkspaceController(
        await NoteRepository.open(directory, createFormatVersion: 2),
      );
      try {
        await controller.createNote(
          'Page',
          documentKind: VaultDocumentKind.page,
        );
        final session = controller.activeSession!;
        final page = const BlockPageDocument.empty().copyWith(
          blocks: [BlockPageBlock.create(text: 'Original')],
        );
        final original = Uint8List.fromList([0, 255, 3, 7]);
        await session.saveInk({
          'page.json': Uint8List.fromList(
            utf8.encode(jsonEncode(page.toJson())),
          ),
          'future/original.bin': original,
        });
        final before = (await controller.repository.heads(
          session.note.inkEntityId,
        )).single;
        final edited = page.copyWith(
          blocks: [page.blocks.single.copyWith(text: 'Edited')],
        );
        await controller.saveBlockPage(edited, session: session);
        final after = (await controller.repository.heads(
          session.note.inkEntityId,
        )).single;
        final files = await controller.repository.readFiles(after);
        expect(files['future/original.bin'], original);
        expect(
          BlockPageDocument.fromJson(
            jsonDecode(utf8.decode(files['page.json']!)),
          ).blocks.single.text,
          'Edited',
        );
        expect(
          (await controller.repository.readFiles(
            before,
          ))['future/original.bin'],
          original,
        );
        await controller.flush();
      } finally {
        controller.dispose();
        await controller.repository.close();
        await directory.delete(recursive: true);
      }
    },
  );
  test('PNG and attachment survive text save reopen with old editions and separate Markdown', () async {
    await _withController((controller, _) async {
      final note = await controller.createNote(
        'Media',
        documentKind: VaultDocumentKind.page,
      );
      final session = controller.activeSession!;
      final image = _mediaImage();
      final attachment = BlockPageMediaAsset.attachment(
        name: '강의.pptx',
        bytes: [80, 75, 3, 4, 7],
        mimeType: 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
      );
      final picture = BlockPageBlock.create(type: 'image', text: '그림 설명');
      final file = BlockPageBlock.create(type: 'attachment', text: '강의 자료');
      final page = const BlockPageDocument.empty().copyWith(
        blocks: [picture, file],
        media: {picture.id: image.reference, file.id: attachment.reference},
      );
      final previous = await controller.loadBlockPage(session: session);
      await session.saveInk({
        'page.json': _pageBytes(previous),
        'future/data.bin': Uint8List.fromList([99, 0, 255]),
      });
      controller.editMarkdown('개인 정리는 그대로');
      await controller.flush();
      final summary = (await controller.repository.heads(note.markdownEntityId))
          .single;
      await controller.saveBlockPage(
        page,
        session: session,
        mediaFiles: {
          image.reference.path: image.bytes,
          attachment.reference.path: attachment.bytes,
        },
      );
      final first = (await controller.repository.heads(note.inkEntityId))
          .single;
      final firstFiles = await controller.repository.readFiles(first);
      final edited = page.copyWith(
        blocks: [
          picture.copyWith(text: '수정된 설명'),
          file,
        ],
      );
      await controller.saveBlockPage(edited, session: session);
      await controller.closeNote(session: session);
      await controller.openNote(
        (await controller.store.list()).singleWhere((n) => n.id == note.id),
      );
      final reopened = controller.activeSession!;
      final snapshot = await controller.loadBlockPageSnapshot(
        session: reopened,
      );
      expect(snapshot.document.toJson(), edited.toJson());
      expect(snapshot.mediaBytes(picture.id), image.bytes);
      expect(snapshot.mediaBytes(file.id), attachment.bytes);
      expect(snapshot.files['future/data.bin'], [99, 0, 255]);
      expect(
        await controller.readBlockPageMedia(image.reference, session: reopened),
        image.bytes,
      );
      final exposed = await controller.readBlockPageMedia(
        image.reference,
        session: reopened,
      );
      exposed.fillRange(0, exposed.length, 0);
      expect(
        await controller.readBlockPageMedia(image.reference, session: reopened),
        image.bytes,
      );
      expect(await controller.repository.readFiles(first), firstFiles);
      expect(
        (await controller.repository.heads(note.markdownEntityId))
            .single
            .revisionId,
        summary.revisionId,
      );
      expect(controller.markdown, '개인 정리는 그대로');
      await controller.flush();
    });
  });

  test('duplicating a block tree keeps shared media and the original discussion through reopen', () async {
    await _withController((controller, _) async {
      final note = await controller.createNote(
        'Duplicate media tree',
        documentKind: VaultDocumentKind.page,
      );
      final session = controller.activeSession!;
      final asset = _mediaImage();
      final image = BlockPageBlock.create(type: 'image', text: '사진 설명');
      final original = BlockPageBlock.create(
        type: 'bullet',
        text: '원본',
      ).copyWith(children: [image]);
      final page = const BlockPageDocument.empty().copyWith(
        blocks: [original],
        media: {image.id: asset.reference},
      );
      await controller.saveBlockPage(
        page,
        session: session,
        mediaFiles: {asset.reference.path: asset.bytes},
      );
      final repo = controller.repository;
      final prior = (await repo.heads(note.inkEntityId)).single;
      final priorFiles = await repo.readFiles(prior);
      final discussions = DiscussionStore(repo);
      final thread = await discussions.createThread(
        page: note.revision,
        anchor: DiscussionAnchor.block(
          pageId: note.id,
          document: page,
          blockId: image.id,
        ),
        body: '원본 사진에 남긴 댓글',
      );
      final duplicated = page.duplicateBlock(original.id);
      final copy = duplicated.blocks.last;
      final copyId = copy.children.single.id;
      expect(copy.id, isNot(original.id));
      expect(copyId, isNot(image.id));
      await controller.saveBlockPage(duplicated, session: session);
      final copiedRevision = (await repo.heads(note.inkEntityId)).single;
      expect(copiedRevision.parentRevisionIds, [prior.revisionId]);
      await controller.closeNote(session: session);
      await controller.openNote((await controller.store.list()).single);
      final reopenedSession = controller.activeSession!;
      final reopened = await controller.loadBlockPageSnapshot(
        session: reopenedSession,
      );
      expect(reopened.document.toJson(), duplicated.toJson());
      expect(reopened.mediaBytes(image.id), asset.bytes);
      expect(reopened.mediaBytes(copyId), asset.bytes);
      expect(
        reopened.files.keys.where((path) => path == asset.reference.path),
        hasLength(1),
      );
      final comment = (await discussions.listThreads(note.id)).single;
      expect(comment.id, thread);
      expect(comment.anchor.blockId, image.id);
      expect(comment.anchorStatus, DiscussionAnchorStatus.attached);

      await controller.saveBlockPage(
        reopened.document.copyWith(blocks: [copy.copyWith(text: '독립적으로 수정')]),
        session: reopenedSession,
      );
      final current = await controller.loadBlockPageSnapshot(
        session: reopenedSession,
      );
      expect(current.document.blocks.single.text, '독립적으로 수정');
      expect(current.document.media.keys, [copyId]);
      expect(current.mediaBytes(copyId), asset.bytes);
      expect(await repo.readFiles(prior), priorFiles);
      expect(
        (await discussions.listThreads(note.id)).single.anchorStatus,
        DiscussionAnchorStatus.missingBlock,
      );
    });
  });

  test(
    'removed media remains readable in its owned snapshot for undo',
    () async {
      await _withController((controller, _) async {
        await controller.createNote(
          'Undo',
          documentKind: VaultDocumentKind.page,
        );
        final session = controller.activeSession!, asset = _mediaImage();
        final (page, blockId) = _mediaPage(asset);
        await controller.saveBlockPage(
          page,
          session: session,
          mediaFiles: {asset.reference.path: asset.bytes},
        );
        await controller.saveBlockPage(
          page.copyWith(blocks: []),
          session: session,
        );
        final removed = await controller.loadBlockPageSnapshot(
          session: session,
        );
        expect(removed.document.version, 2);
        expect(removed.document.media, isEmpty);
        expect(
          await controller.readBlockPageMedia(
            asset.reference,
            session: session,
          ),
          asset.bytes,
        );
        await controller.saveBlockPage(page, session: session);
        expect(
          (await controller.loadBlockPageSnapshot(session: session))
              .mediaBytes(blockId),
          asset.bytes,
        );
      });
    },
  );

  test(
    'missing bytes and ordinary v2 downgrade do not publish any revision',
    () async {
      await _withController((controller, _) async {
        final note = await controller.createNote(
          'Guarded',
          documentKind: VaultDocumentKind.page,
        );
        final session = controller.activeSession!, asset = _mediaImage();
        final (page, _) = _mediaPage(asset);
        final before = (await controller.repository.heads(note.inkEntityId))
            .single;
        final count = (await controller.repository.revisions()).length;
        await expectLater(
          controller.saveBlockPage(page, session: session),
          throwsFormatException,
        );
        expect((await controller.repository.revisions()).length, count);
        expect(
          (await controller.repository.heads(note.inkEntityId))
              .single
              .revisionId,
          before.revisionId,
        );
        await controller.saveBlockPage(
          page,
          session: session,
          mediaFiles: {asset.reference.path: asset.bytes},
        );
        final current = (await controller.repository.heads(note.inkEntityId))
            .single;
        await expectLater(
          controller.saveBlockPage(
            const BlockPageDocument.empty(),
            session: session,
          ),
          throwsFormatException,
        );
        expect(
          (await controller.repository.heads(note.inkEntityId))
              .single
              .revisionId,
          current.revisionId,
        );
      });
    },
  );

  test('loading and saving damaged registered media is rejected without replacing it', () async {
    await _withController((controller, _) async {
      final note = await controller.createNote(
        'Damaged',
        documentKind: VaultDocumentKind.page,
      );
      final session = controller.activeSession!, asset = _mediaImage();
      final (page, _) = _mediaPage(asset);
      await session.saveInk({
        'page.json': _pageBytes(page),
        asset.reference.path: Uint8List.fromList([1, 2, 3]),
      });
      final before = (await controller.repository.heads(note.inkEntityId))
          .single;
      final count = (await controller.repository.revisions()).length;
      await expectLater(
        controller.loadBlockPage(session: session),
        throwsFormatException,
      );
      await expectLater(
        controller.loadBlockPageSnapshot(session: session),
        throwsFormatException,
      );
      await expectLater(
        controller.readBlockPageMedia(asset.reference, session: session),
        throwsFormatException,
      );
      await expectLater(
        controller.saveBlockPage(page, session: session),
        throwsFormatException,
      );
      expect((await controller.repository.revisions()).length, count);
      expect(
        (await controller.repository.heads(note.inkEntityId)).single.revisionId,
        before.revisionId,
      );
    });
  });

  test(
    'another note blob or selected revision cannot grant page media ownership',
    () async {
      await _withController((controller, _) async {
        final current = await controller.createNote(
          'Current',
          documentKind: VaultDocumentKind.page,
        );
        final session = controller.activeSession!, asset = _mediaImage();
        final other = await controller.store.create(
          'Other',
          documentKind: VaultDocumentKind.page,
        );
        final otherSession = await controller.store.open(other);
        final (otherPage, _) = _mediaPage(asset);
        await otherSession.saveInk(
          BlockPageMediaSnapshot.prepare(
            otherPage,
            addedFiles: {asset.reference.path: asset.bytes},
          ).files,
        );
        final foreign = (await controller.repository.heads(other.inkEntityId))
            .single;
        final before = List<String>.of(session.inkParents);
        await expectLater(
          controller.readBlockPageMedia(asset.reference, session: session),
          throwsFormatException,
        );
        await expectLater(
          controller.saveBlockPage(otherPage, session: session),
          throwsFormatException,
        );
        expect(
          (await controller.repository.heads(current.inkEntityId))
              .single
              .revisionId,
          before.single,
        );
        session.inkParents = [foreign.revisionId];
        await expectLater(
          controller.loadBlockPageSnapshot(session: session),
          throwsFormatException,
        );
        session.inkParents = before;
      });
    },
  );

  test(
    'read started before close rejects its late result and old-session writes',
    () async {
      await _withController((controller, _) async {
        await controller.createNote(
          'Late',
          documentKind: VaultDocumentKind.page,
        );
        final session = controller.activeSession!, asset = _mediaImage();
        final (page, _) = _mediaPage(asset);
        await controller.saveBlockPage(
          page,
          session: session,
          mediaFiles: {asset.reference.path: asset.bytes},
        );
        await controller.refresh();
        final proxy = _PageRepository(controller.repository);
        controller.repository = proxy;
        session.repository = proxy;
        proxy.pauseEntity = session.note.inkEntityId;
        final reading = controller.readBlockPageMedia(
          asset.reference,
          session: session,
        );
        await proxy.readEntered.future.timeout(const Duration(seconds: 5));
        await controller.closeNote(session: session);
        proxy.releaseRead.complete();
        await expectLater(reading, throwsStateError);
        await expectLater(
          controller.saveBlockPage(page, session: session),
          throwsStateError,
        );
        await expectLater(
          controller.loadBlockPageSnapshot(session: session),
          throwsStateError,
        );
      });
    },
  );

  test('selected-revision change while a snapshot is being read rejects its late result', () async {
    await _withController((controller, _) async {
      await controller.createNote(
        'Selection',
        documentKind: VaultDocumentKind.page,
      );
      final session = controller.activeSession!;
      final old = session.inkParents.single;
      final page = const BlockPageDocument.empty().copyWith(
        blocks: [BlockPageBlock.create(text: 'Current')],
      );
      await controller.saveBlockPage(page, session: session);
      await controller.refresh();
      final selected = session.inkParents.single;
      final proxy = _PageRepository(controller.repository);
      controller.repository = proxy;
      session.repository = proxy;
      proxy.pauseEntity = session.note.inkEntityId;
      final reading = controller.loadBlockPageSnapshot(session: session);
      await proxy.readEntered.future.timeout(const Duration(seconds: 5));
      session.inkParents = [old];
      proxy.releaseRead.complete();
      await expectLater(reading, throwsStateError);
      session.inkParents = [selected];
    });
  });

  for (final operation in ['load', 'read', 'save']) {
    test(
      'selected revision change after bytes arrive rejects media $operation',
      () async {
        await _withController((controller, _) async {
          await controller.createNote(
            'Worker boundary',
            documentKind: VaultDocumentKind.page,
          );
          final session = controller.activeSession!, asset = _mediaImage();
          final old = session.inkParents.single;
          final (page, _) = _mediaPage(asset);
          await controller.saveBlockPage(
            page,
            session: session,
            mediaFiles: {asset.reference.path: asset.bytes},
          );
          await controller.refresh();
          final selected = List<String>.of(session.inkParents);
          final proxy = _PageRepository(controller.repository);
          controller.repository = proxy;
          session.repository = proxy;
          final changed = Completer<void>();
          proxy.afterRead = () => Timer.run(() {
            session.inkParents = [old];
            changed.complete();
          });
          final pending = switch (operation) {
            'load' =>
              controller
                  .loadBlockPageSnapshot(session: session)
                  .then<void>((_) {}),
            'read' =>
              controller
                  .readBlockPageMedia(asset.reference, session: session)
                  .then<void>((_) {}),
            _ => controller.saveBlockPage(page, session: session),
          };
          try {
            await expectLater(pending, throwsStateError);
            await changed.future.timeout(const Duration(seconds: 5));
            expect(
              (await proxy.inner.heads(session.note.inkEntityId))
                  .single
                  .revisionId,
              selected.single,
            );
          } finally {
            await changed.future.timeout(const Duration(seconds: 5));
            session.inkParents = selected;
          }
        });
      },
    );
  }

  test('repository replacement while reading never returns the old page as current', () async {
    await _withController((controller, directory) async {
      await controller.createNote(
        'Switch',
        documentKind: VaultDocumentKind.page,
      );
      final session = controller.activeSession!;
      await controller.refresh();
      final proxy = _PageRepository(controller.repository);
      controller.repository = proxy;
      session.repository = proxy;
      proxy.pauseEntity = session.note.inkEntityId;
      final reading = controller.loadBlockPageSnapshot(session: session);
      await proxy.readEntered.future.timeout(const Duration(seconds: 5));
      final next = await NoteRepository.open(
        Directory('${directory.path}/next'),
        createFormatVersion: 2,
      );
      await controller.replaceRepository(next);
      proxy.releaseRead.complete();
      await expectLater(reading, throwsStateError);
      expect(controller.repository, same(next));
      expect(controller.activeSession, isNull);
    });
  });

  test('explicit history restoration restores media and keeps old editions and summary', () async {
    await _withController((controller, _) async {
      final note = await controller.createNote(
        'History',
        documentKind: VaultDocumentKind.page,
      );
      final session = controller.activeSession!, asset = _mediaImage();
      final (page, blockId) = _mediaPage(asset);
      await controller.saveBlockPage(
        page,
        session: session,
        mediaFiles: {asset.reference.path: asset.bytes},
      );
      final chosen = (await controller.repository.heads(note.inkEntityId))
          .single;
      final originalFiles = await controller.repository.readFiles(chosen);
      controller.editMarkdown('Summary stays independent');
      await controller.flush();
      await controller.saveBlockPage(
        page.copyWith(blocks: []),
        session: session,
      );
      final current = (await controller.repository.heads(note.inkEntityId))
          .single;
      final history = await controller.blockPageHistory(session: session);
      await controller.restoreBlockPageRevision(
        history,
        chosen,
        session: session,
      );
      final restored = (await controller.repository.heads(note.inkEntityId))
          .single;
      expect(restored.revisionId, isNot(chosen.revisionId));
      expect(restored.parentRevisionIds, [current.revisionId]);
      expect(
        (await controller.loadBlockPageSnapshot(session: session))
            .mediaBytes(blockId),
        asset.bytes,
      );
      expect(await controller.repository.readFiles(chosen), originalFiles);
      expect(await controller.repository.readFiles(restored), originalFiles);
      expect(controller.markdown, 'Summary stays independent');
    });
  });

  for (final failBefore in [true, false]) {
    test(
      'media retry reuses its exact prepared revision after ${failBefore ? 'pre-publication failure' : 'lost response'}',
      () async {
        await _withController((controller, _) async {
          final note = await controller.createNote(
            'Retry',
            documentKind: VaultDocumentKind.page,
          );
          final session = controller.activeSession!, asset = _mediaImage();
          final before = (await controller.repository.heads(note.inkEntityId))
              .single;
          final beforeFiles = await controller.repository.readFiles(before);
          final (page, blockId) = _mediaPage(asset);
          await controller.refresh();
          final proxy = _PageRepository(controller.repository)
            ..failBefore = failBefore;
          controller.repository = proxy;
          session.repository = proxy;
          proxy.failNextInk = true;
          await expectLater(
            controller.saveBlockPage(
              page,
              session: session,
              mediaFiles: {asset.reference.path: asset.bytes},
            ),
            throwsStateError,
          );
          final attempted = proxy.attemptedIds.single;
          expect(await proxy.inner.readFiles(before), beforeFiles);
          await controller.saveBlockPage(
            page,
            session: session,
            mediaFiles: {asset.reference.path: asset.bytes},
          );
          final after = (await proxy.inner.heads(note.inkEntityId)).single;
          expect(after.revisionId, attempted);
          expect(proxy.attemptedIds.toSet(), {attempted});
          expect(
            (await proxy.inner.revisions()).where(
              (r) => r.entityId == note.inkEntityId,
            ),
            hasLength(2),
          );
          expect(
            (await controller.loadBlockPageSnapshot(session: session))
                .mediaBytes(blockId),
            asset.bytes,
          );
        });
      },
    );
  }

  test('a remote writer arriving before publication remains as an independent head', () async {
    await _withController((controller, _) async {
      final note = await controller.createNote(
        'Concurrent',
        documentKind: VaultDocumentKind.page,
      );
      final session = controller.activeSession!, asset = _mediaImage();
      final selected = List<String>.of(session.inkParents);
      final (page, blockId) = _mediaPage(asset);
      await controller.refresh();
      final proxy = _PageRepository(controller.repository);
      controller.repository = proxy;
      session.repository = proxy;
      RevisionRecord? remote;
      proxy.beforeInkPublish = () async {
        proxy.beforeInkPublish = null;
        remote = await proxy.inner.commit(
          entityId: note.inkEntityId,
          kind: EntityKind.ink,
          ownerNoteId: note.id,
          files: {
            'page.json': _pageBytes(
              const BlockPageDocument.empty().copyWith(
                blocks: [BlockPageBlock.create(text: 'Remote writer')],
              ),
            ),
          },
          parentRevisionIds: selected,
        );
      };
      await controller.saveBlockPage(
        page,
        session: session,
        mediaFiles: {asset.reference.path: asset.bytes},
      );
      final heads = await proxy.inner.heads(note.inkEntityId);
      expect(heads, hasLength(2));
      expect(heads.map((r) => r.revisionId), contains(remote!.revisionId));
      final local = heads.singleWhere(
        (r) => r.revisionId != remote!.revisionId,
      );
      expect(
        BlockPageMediaSnapshot.fromFiles(await proxy.inner.readFiles(local))
            .mediaBytes(blockId),
        asset.bytes,
      );
      expect(
        utf8.decode((await proxy.inner.readFiles(remote!))['page.json']!),
        contains('Remote writer'),
      );
    });
  });

  test('DB row media requires its binary storage and loads once the complete snapshot is present', () async {
    await _withController((controller, _) async {
      final note = await controller.createNote(
        'DB',
        documentKind: VaultDocumentKind.database,
      );
      final session = controller.activeSession!, asset = _mediaImage();
      final original = await controller.loadDatabase(session: session);
      final (page, _) = _mediaPage(asset);
      final row = DatabaseRow.create().copyWith(body: page.toJson());
      final candidate = original.addRow(row);
      final before = (await controller.repository.heads(note.inkEntityId))
          .single;
      await expectLater(
        controller.saveDatabase(candidate, session: session),
        throwsFormatException,
      );
      expect(
        (await controller.repository.heads(note.inkEntityId)).single.revisionId,
        before.revisionId,
      );
      await session.saveInk({
        'database.json': Uint8List.fromList(
          utf8.encode(jsonEncode(candidate.toJson())),
        ),
        asset.reference.path: asset.bytes,
      });
      final registered = (await controller.repository.heads(note.inkEntityId))
          .single;
      expect(
        (await controller.loadDatabase(session: session)).toJson(),
        candidate.toJson(),
      );
      expect(
        (await controller.repository.heads(note.inkEntityId)).single.revisionId,
        registered.revisionId,
      );
    });
  });
}

Uint8List _pageBytes(BlockPageDocument document) =>
    Uint8List.fromList(utf8.encode(jsonEncode(document.toJson())));
BlockPageMediaAsset _mediaImage() => BlockPageMediaAsset.image(
  name: '태블릿.png',
  bytes: im.encodePng(im.Image(width: 2, height: 3)),
);
(BlockPageDocument, String) _mediaPage(BlockPageMediaAsset asset) {
  final block = BlockPageBlock.create(type: 'image', text: 'Caption');
  return (
    const BlockPageDocument.empty().copyWith(
      blocks: [block],
      media: {block.id: asset.reference},
    ),
    block.id,
  );
}

Future<void> _withController(
  Future<void> Function(WorkspaceController, Directory) action,
) async {
  final directory = await Directory.systemTemp.createTemp(
    'block-media-integration-',
  );
  final controller = WorkspaceController(
    await NoteRepository.open(
      Directory('${directory.path}/vault'),
      createFormatVersion: 2,
    ),
    directoryProvider: () async => Directory('${directory.path}/support'),
  );
  try {
    await action(controller, directory);
    await controller.flush();
  } finally {
    controller.dispose();
    await controller.repository.close();
    await directory.delete(recursive: true);
  }
}

class _PageRepository implements NoteRepository {
  new(this.inner);
  final NoteRepository inner;
  String? pauseEntity;
  final readEntered = Completer<void>();
  final releaseRead = Completer<void>();
  var failNextInk = false, failBefore = false;
  Future<void> Function()? beforeInkPublish;
  void Function()? afterRead;
  final attemptedIds = <String>[];
  @override
  Directory get root => inner.root;
  @override
  String get vaultId => inner.vaultId;
  @override
  String get deviceId => inner.deviceId;
  @override
  int get formatVersion => inner.formatVersion;
  @override
  Stream<void> get changes => inner.changes;
  @override
  List<String> get integrityIssues => inner.integrityIssues;
  @override
  int get pendingRevisionCount => inner.pendingRevisionCount;
  @override
  Future<List<RevisionRecord>> heads(String id) => inner.heads(id);
  @override
  Future<List<RevisionRecord>> revisions() => inner.revisions();
  @override
  Future<Uint8List> readBlob(String hash) => inner.readBlob(hash);
  @override
  Future<Map<String, Uint8List>> readFiles(RevisionRecord record) async {
    if (pauseEntity == record.entityId) {
      pauseEntity = null;
      readEntered.complete();
      await releaseRead.future;
    }
    final files = await inner.readFiles(record);
    final callback = afterRead;
    afterRead = null;
    callback?.call();
    return files;
  }

  @override
  PreparedCommit prepareCommit({
    required String entityId,
    required EntityKind kind,
    required Map<String, Uint8List> files,
    required List<String> parentRevisionIds,
    String? ownerNoteId,
    bool deleted = false,
    Map<String, List<String>> baseRefs = const {},
  }) => inner.prepareCommit(
    entityId: entityId,
    kind: kind,
    files: files,
    parentRevisionIds: parentRevisionIds,
    ownerNoteId: ownerNoteId,
    deleted: deleted,
    baseRefs: baseRefs,
  );
  @override
  Future<RevisionRecord> commitPrepared(PreparedCommit prepared) async {
    if (prepared.record.kind == EntityKind.ink) {
      attemptedIds.add(prepared.record.revisionId);
      await beforeInkPublish?.call();
      if (failNextInk && failBefore) {
        failNextInk = false;
        throw StateError('Synthetic page failure before publication');
      }
    }
    final result = await inner.commitPrepared(prepared);
    if (prepared.record.kind == EntityKind.ink && failNextInk) {
      failNextInk = false;
      throw StateError('Synthetic page publication response loss');
    }
    return result;
  }

  @override
  Future<void> close() => inner.close();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
