import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/vault/block_page_document.dart';
import 'package:saber/data/vault/discussion_anchor.dart';
import 'package:saber/data/vault/discussion_store.dart';
import 'package:saber/data/vault/library_store.dart';
import 'package:saber/data/vault/workspace_store.dart';

Uint8List bytes(Object value) =>
    Uint8List.fromList(utf8.encode(jsonEncode(value)));

void check(bool condition, String reason) =>
    expect(condition, isTrue, reason: reason);

Future<void> reject(Future<Object?> Function() action, String reason) =>
    expectLater(
      action,
      throwsA(anyOf(isA<FormatException>(), isA<StateError>())),
      reason: reason,
    );

Future<void> replicate(
  NoteRepository source,
  NoteRepository target,
  RevisionRecord revision,
) async {
  await target.importRevision(
    revision,
    blobsByHash: {
      for (final ref in revision.blobs.values)
        ref.hash: await source.readBlob(ref.hash),
    },
  );
}

Future<void> sendEntity(
  NoteRepository source,
  NoteRepository target,
  String id,
) async => replicate(source, target, (await source.heads(id)).single);

Future<RevisionRecord> folder(
  NoteRepository repo,
  String title, {
  String? parentId,
}) async =>
    (await LibraryStore(repo).createFolder(title, parentId: parentId)).revision;

Future<({RevisionRecord revision, String id, String inkEntityId})> createPage(
  NoteRepository repo,
  String title, {
  VaultDocumentKind kind = VaultDocumentKind.page,
  String? folderId,
}) async {
  final note = await WorkspaceStore(repo)
      .create(title, documentKind: kind, folderId: folderId);
  return (revision: note.revision, id: note.id, inkEntityId: note.inkEntityId);
}

Future<void> setPage(
  NoteRepository repo,
  ({RevisionRecord revision, String id, String inkEntityId}) note,
  BlockPageDocument document,
) async {
  await repo.commit(
    entityId: note.inkEntityId,
    kind: EntityKind.ink,
    ownerNoteId: note.id,
    files: {'page.json': bytes(document.toJson())},
    parentRevisionIds: [
      for (final head in await repo.heads(note.inkEntityId)) head.revisionId,
    ],
  );
}

Future<void> tombstone(NoteRepository repo, RevisionRecord current) async {
  await repo.commit(
    entityId: current.entityId,
    kind: current.kind,
    ownerNoteId: current.ownerNoteId,
    files: await repo.readFiles(current),
    parentRevisionIds: [current.revisionId],
    deleted: true,
  );
}

void main() {
  late Directory temp;
  late List<NoteRepository> openRepos;
  late NoteRepository repo;

  Future<NoteRepository> open(String name, {String? vaultId}) async {
    final opened = await NoteRepository.open(
      Directory(p.join(temp.path, name)),
      createFormatVersion: 2,
      vaultId: vaultId,
    );
    openRepos.add(opened);
    return opened;
  }

  setUp(() async {
    final owner = Directory.systemTemp;
    temp = await owner.createTemp('piv-discussion-store-');
    openRepos = [];
    addTearDown(() async {
      for (final opened in openRepos.reversed) {
        await opened.close();
      }
      final safeOwner = await owner.resolveSymbolicLinks();
      final resolved = await temp.resolveSymbolicLinks();
      expect(p.dirname(resolved), safeOwner);
      expect(p.basename(resolved), startsWith('piv-discussion-store-'));
      await Directory(resolved).delete(recursive: true);
    });
    repo = await open('vault');
  });

  test(
    'blank page commits immutable owned events and no page rewrite',
    () async {
      final page = await createPage(repo, '페이지');
      final store = DiscussionStore(repo);
      check((await store.listThreads(page.id)).isEmpty, 'new page is empty');
      final id = await store.createThread(
        page: page.revision,
        anchor: DiscussionAnchor.page(pageId: page.id),
        body: ' 원문 😀\n보존 ',
      );
      final record = (await repo.heads(id)).single;
      check(record.kind == EntityKind.attachment, 'attachment kind');
      check(record.ownerNoteId == page.id, 'real page owner');
      check(record.parentRevisionIds.isEmpty, 'independent event');
      check(record.blobs.keys.single == 'discussion-event.json', 'wire file');
      final thread = (await store.listThreads(page.id)).single;
      check(thread.id == id && thread.root.id == id, 'root identity');
      check(thread.root.body == ' 원문 😀\n보존 ', 'exact body');
      check(thread.root.authorDeviceId == repo.deviceId, 'actual author');
      check(thread.anchorStatus == DiscussionAnchorStatus.attached, 'anchor');
      check(thread.status == DiscussionThreadStatus.open, 'open by default');
      check(thread.statusHeadIds.single == id, 'root status head');
      check(
        (await repo.heads(page.id)).single.revisionId ==
                page.revision.revisionId &&
            (await repo.heads(page.inkEntityId)).isEmpty,
        'page metadata and ink must remain untouched',
      );
      for (final body in ['   ', 'x' * 8193, 'nul\u0000body', '\uD800']) {
        await reject(
          () => store.createThread(
            page: page.revision,
            anchor: DiscussionAnchor.page(pageId: page.id),
            body: body,
          ),
          'malformed comment body',
        );
      }
      check((await store.listThreads(page.id)).length == 1, 'no bad writes');
    },
  );

  test(
    'changed quotes cannot publish and old anchors remain readable',
    () async {
      final page = await createPage(repo, '인용');
      final block = BlockPageBlock.create(type: 'paragraph', text: '원래 문장');
      final original = const BlockPageDocument.empty().copyWith(
        blocks: [block],
      );
      await setPage(repo, page, original);
      final anchor = DiscussionAnchor.quote(
        pageId: page.id,
        document: original,
        blockId: block.id,
        startUtf16: 0,
        endUtf16: 2,
      );
      final store = DiscussionStore(repo);
      final id = await store.createThread(
        page: page.revision,
        anchor: anchor,
        body: '인용 토론',
      );
      await setPage(
        repo,
        page,
        original.copyWith(blocks: [block.copyWith(text: '바뀐 문장')]),
      );
      check(
        (await store.listThreads(page.id)).single.anchorStatus ==
            DiscussionAnchorStatus.changedQuote,
        'no silent reattachment',
      );
      await reject(
        () => store.createThread(
          page: page.revision,
          anchor: anchor,
          body: 'stale',
        ),
        'stale quote',
      );
      await setPage(repo, page, const BlockPageDocument.empty());
      check(
        (await store.listThreads(page.id)).single.anchorStatus ==
            DiscussionAnchorStatus.missingBlock,
        'page replacement must preserve orphan thread',
      );
      await store.reply(
        page: page.revision,
        threadId: id,
        replyToId: id,
        body: '후속',
      );
      check(
        (await store.listThreads(page.id)).single.replies.length == 1,
        'orphan replies remain available',
      );
      await repo.commit(
        entityId: page.inkEntityId,
        kind: EntityKind.ink,
        ownerNoteId: page.id,
        files: {'page.json': bytes('malformed block page')},
        parentRevisionIds: [
          (await repo.heads(page.inkEntityId)).single.revisionId,
        ],
      );
      final unreadable = (await store.listThreads(page.id)).single;
      check(
        unreadable.anchorStatus == DiscussionAnchorStatus.missingPage &&
            unreadable.replies.length == 1,
        'unreadable page body retains discussion',
      );
      await reject(
        () => store.reply(
          page: page.revision,
          threadId: id,
          replyToId: id,
          body: '금지',
        ),
        'unreadable current page body cannot publish',
      );
    },
  );

  test('invalid destinations and stale metadata cannot publish', () async {
    final parent = await folder(repo, '상위');
    final child = await folder(repo, '하위', parentId: parent.entityId);
    final page = await createPage(repo, '페이지', folderId: child.entityId);
    final other = await createPage(
      repo,
      '필기',
      kind: VaultDocumentKind.handwriting,
    );
    final foreign = await open('foreign');
    final foreignPage = await createPage(foreign, '외부');
    final store = DiscussionStore(repo);
    Future<String> create(RevisionRecord note, String anchorPageId) =>
        store.createThread(
          page: note,
          anchor: DiscussionAnchor.page(pageId: anchorPageId),
          body: '메시지',
        );
    await reject(() => create(other.revision, other.id), 'non-page');
    await reject(
      () => create(foreignPage.revision, foreignPage.id),
      'foreign vault',
    );
    await reject(() => create(page.revision, foreignPage.id), 'foreign anchor');
    final metadata = await repo.commit(
      entityId: page.id,
      kind: EntityKind.metadata,
      files: await repo.readFiles(page.revision),
      parentRevisionIds: [page.revision.revisionId],
    );
    await reject(
      () => create(page.revision, page.id),
      'stale metadata snapshot',
    );
    final current = (await repo.heads(page.id)).single;
    final thread = await create(current, page.id);
    await tombstone(repo, parent);
    await reject(
      () => store.reply(
        page: current,
        threadId: thread,
        replyToId: thread,
        body: '금지',
      ),
      'ancestor was deleted with old page handle',
    );
    await tombstone(repo, metadata);
    await reject(
      () async => create((await repo.heads(page.id)).single, page.id),
      'page now in trash',
    );
    check(
      (await store.listThreads(page.id)).single.id == thread,
      'trash retains history',
    );
  });

  test(
    'independent device replies and conflicting status heads merge',
    () async {
      final first = repo;
      final second = await open('peer', vaultId: first.vaultId);
      final pageA = await createPage(first, '동기화');
      for (final revision in await first.revisions()) {
        await replicate(first, second, revision);
      }
      final pageB = (await second.heads(pageA.id)).single;
      final a = DiscussionStore(first);
      final b = DiscussionStore(second);
      final thread = await a.createThread(
        page: pageA.revision,
        anchor: DiscussionAnchor.page(pageId: pageA.id),
        body: '첫 댓글',
      );
      await sendEntity(first, second, thread);
      final left = await a.reply(
        page: pageA.revision,
        threadId: thread,
        replyToId: thread,
        body: '왼쪽',
      );
      final right = await b.reply(
        page: pageB,
        threadId: thread,
        replyToId: thread,
        body: '오른쪽',
      );
      final nested = await b.reply(
        page: pageB,
        threadId: thread,
        replyToId: right,
        body: '답글의 답글',
      );
      final statusA = await a.setResolved(
        page: pageA.revision,
        threadId: thread,
        resolved: true,
        expectedStatusIds: [thread],
      );
      final statusB = await b.setResolved(
        page: pageB,
        threadId: thread,
        resolved: false,
        expectedStatusIds: [thread],
      );
      await sendEntity(second, first, nested);
      check(
        (await a.listThreads(pageA.id)).single.replies.length == 1,
        'out-of-order nested reply must wait for its parent',
      );
      await sendEntity(second, first, right);
      await sendEntity(second, first, statusB);
      await sendEntity(first, second, left);
      await sendEntity(first, second, statusA);
      for (final store in [a, b]) {
        final found = (await store.listThreads(pageA.id)).single;
        final ids = found.replies.map((r) => r.id).toSet();
        check(
          ids.length == 3 && ids.containsAll([left, right, nested]),
          'all independent replies must survive',
        );
        final child = found.replies.singleWhere((r) => r.id == nested);
        check(
          child.replyToId == right && child.authorDeviceId == second.deviceId,
          'nested target and author must survive',
        );
        check(
          found.status == DiscussionThreadStatus.conflict,
          'divergent status cannot be hidden',
        );
        check(
          found.statusHeadIds.toSet().containsAll([statusA, statusB]),
          'retain both branches',
        );
      }
      await reject(
        () => a.setResolved(
          page: pageA.revision,
          threadId: thread,
          resolved: false,
          expectedStatusIds: [statusA],
        ),
        'a stale status observer cannot overwrite the other branch',
      );
      final resolved = await a.setResolved(
        page: pageA.revision,
        threadId: thread,
        resolved: true,
        expectedStatusIds: [statusB, statusA],
      );
      await sendEntity(first, second, resolved);
      final found = (await b.listThreads(pageB.entityId)).single;
      check(
        found.status == DiscussionThreadStatus.resolved &&
            found.statusHeadIds.single == resolved,
        'explicit reconciliation',
      );
      check(
        (await first.heads(statusA)).length == 1 &&
            (await first.heads(statusB)).length == 1,
        'keep immutable branch events',
      );
      final late = await open('status-late', vaultId: first.vaultId);
      for (final revision in await first.revisions()) {
        if (revision.kind != EntityKind.attachment) {
          await replicate(first, late, revision);
        }
      }
      final lateStore = DiscussionStore(late);
      await sendEntity(first, late, resolved);
      check(
        (await lateStore.listThreads(pageA.id)).isEmpty,
        'a status is not a root even when received first',
      );
      await sendEntity(first, late, thread);
      check(
        (await lateStore.listThreads(pageA.id)).single.statusHeadIds.single ==
            thread,
        'merge waits for both causal parents',
      );
      await sendEntity(first, late, statusA);
      check(
        (await lateStore.listThreads(pageA.id)).single.statusHeadIds.single ==
            statusA,
        'one missing causal parent still blocks the merge',
      );
      await sendEntity(first, late, statusB);
      check(
        (await lateStore.listThreads(pageA.id)).single.statusHeadIds.single ==
            resolved,
        'late branches unlock the existing merge',
      );
    },
  );

  test('wrong-thread and malformed attachment targets stay isolated', () async {
    final page = await createPage(repo, '스코프');
    final store = DiscussionStore(repo);
    Future<String> root(String body) => store.createThread(
      page: page.revision,
      anchor: DiscussionAnchor.page(pageId: page.id),
      body: body,
    );
    final a = await root('A');
    final b = await root('B');
    final target = await store.reply(
      page: page.revision,
      threadId: b,
      replyToId: b,
      body: 'B 답글',
    );
    await reject(
      () => store.reply(
        page: page.revision,
        threadId: a,
        replyToId: target,
        body: 'cross',
      ),
      'other thread reply',
    );
    await reject(
      () => store.reply(
        page: page.revision,
        threadId: a,
        replyToId: 'invalid',
        body: 'bad',
      ),
      'invalid ID',
    );
    final forged = newId();
    await repo.commit(
      entityId: forged,
      kind: EntityKind.attachment,
      ownerNoteId: page.id,
      files: {
        'discussion-event.json': bytes({
          'version': 1,
          'kind': 'reply',
          'pageId': page.id,
          'eventId': forged,
          'threadId': a,
          'authorDeviceId': newId(),
          'replyToId': a,
          'body': 'forged',
        }),
      },
      parentRevisionIds: [],
    );
    final rows = await store.listThreads(page.id);
    check(
      rows.length == 2 &&
          rows.singleWhere((row) => row.id == a).replies.isEmpty,
      'forged record must not affect the valid threads',
    );
  });

  test(
    'stable event IDs retry once and bind exact scope and payload',
    () async {
      final first = await createPage(repo, '재시도');
      final second = await createPage(repo, '다른 페이지');
      final store = DiscussionStore(repo);
      final id = newId();
      Future<String> create({RevisionRecord? target, String body = '고정'}) =>
          store.createThread(
            page: target ?? first.revision,
            anchor: DiscussionAnchor.page(
              pageId: (target ?? first.revision).entityId,
            ),
            eventId: id,
            body: body,
          );
      check(await create() == id && await create() == id, 'same root event');
      await reject(() => create(body: '달라짐'), 'same ID changed body');
      await reject(() => create(target: second.revision), 'same ID other page');
      final replyId = newId();
      Future<String> reply(String body) => store.reply(
        page: first.revision,
        threadId: id,
        replyToId: id,
        body: body,
        eventId: replyId,
      );
      check(
        await reply('답글') == replyId && await reply('답글') == replyId,
        'same reply event',
      );
      await reject(() => reply('변경'), 'same ID changed reply');
      final statusId = newId();
      Future<String> resolve(bool value) => store.setResolved(
        page: first.revision,
        threadId: id,
        resolved: value,
        expectedStatusIds: [id],
        eventId: statusId,
      );
      check(await resolve(true) == statusId, 'resolved');
      final newer = await store.setResolved(
        page: first.revision,
        threadId: id,
        resolved: false,
        expectedStatusIds: [statusId],
      );
      check(
        await resolve(true) == statusId,
        'stable retry after heads advance',
      );
      await reject(() => resolve(false), 'same ID different status action');
      final row = (await store.listThreads(first.id)).single;
      check(
        row.statusHeadIds.single == newer && row.replies.single.id == replyId,
        'retry never creates another reply or status head',
      );
      final eventCount = (await repo.revisions())
          .where(
            (revision) =>
                revision.ownerNoteId == first.id &&
                revision.kind == EntityKind.attachment,
          )
          .length;
      check(eventCount == 4, 'four exact persisted events');
      check(
        (await store.listThreads(second.id)).isEmpty,
        'no other page write',
      );

      final otherDevice = await open('retry-peer', vaultId: repo.vaultId);
      for (final revision in await repo.revisions()) {
        await replicate(repo, otherDevice, revision);
      }
      await reject(
        () => DiscussionStore(otherDevice).createThread(
          page: first.revision,
          anchor: DiscussionAnchor.page(pageId: first.id),
          body: '고정',
          eventId: id,
        ),
        'same event ID is bound to the original author',
      );
    },
  );

  test(
    'page trash racing the append fails the atomic snapshot guard',
    () async {
      final page = await createPage(repo, '동시 휴지통');
      final eventId = newId();
      final deletion = repo.prepareCommit(
        entityId: page.id,
        kind: EntityKind.metadata,
        files: await repo.readFiles(page.revision),
        parentRevisionIds: [page.revision.revisionId],
        deleted: true,
      );
      final append = DiscussionStore(repo).createThread(
        page: page.revision,
        anchor: DiscussionAnchor.page(pageId: page.id),
        body: '동시 저장',
        eventId: eventId,
      );
      final failure = append.then<Object?>(
        (_) => null,
        onError: (Object e) => e,
      );
      await repo.commitPreparedIfHeads(
        deletion,
        expectedHeads: {
          page.id: [page.revision.revisionId],
        },
      );
      final caught = await failure;
      check(
        caught is StateError &&
            caught.message ==
                'Revision heads changed before conditional publication',
        'old metadata snapshot must reach and fail at the atomic commit guard',
      );
      check(
        (await repo.heads(eventId)).isEmpty,
        'no partial event publication',
      );
    },
  );

  test('full vault clone keeps discussions but page copies do not', () async {
    final page = await createPage(repo, '원본');
    final block = BlockPageBlock.create(type: 'paragraph', text: '원문');
    final document = const BlockPageDocument.empty().copyWith(blocks: [block]);
    await setPage(repo, page, document);
    final store = DiscussionStore(repo);
    final event = await store.createThread(
      page: page.revision,
      anchor: DiscussionAnchor.block(
        pageId: page.id,
        document: document,
        blockId: block.id,
      ),
      body: '원본 메모',
    );
    final copy = await createPage(repo, '복제');
    await setPage(repo, copy, document);
    check(
      (await store.listThreads(copy.id)).isEmpty,
      'copying even exact page bytes must not copy the discussion',
    );
    final clone = await BackupService.cloneToEmpty(
      repo,
      Directory(p.join(temp.path, 'cloned-vault')),
    );
    openRepos.add(clone);
    check(clone.vaultId != repo.vaultId, 'clone uses fresh vault identity');
    final clonedStore = DiscussionStore(clone);
    final old = (await clonedStore.listThreads(page.id)).single;
    check(
      old.id == event && old.root.authorDeviceId == repo.deviceId,
      'vault-level clone retains thread and original author',
    );
    await reject(
      () => clonedStore.reply(
        page: page.revision,
        threadId: event,
        replyToId: event,
        body: '원본 핸들',
      ),
      'same entity ID with foreign vault snapshot',
    );
    final current = (await clone.heads(page.id)).single;
    await clonedStore.reply(
      page: current,
      threadId: event,
      replyToId: event,
      body: '복제 vault 답글',
    );
    check(
      (await clonedStore.listThreads(page.id))
              .single
              .replies
              .single
              .authorDeviceId ==
          clone.deviceId,
      'new clone events use new author',
    );
  });
}
