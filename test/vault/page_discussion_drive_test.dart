import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/drive.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path/path.dart' as p;
import 'package:pdf/widgets.dart' as pw;
import 'package:perfect_freehand/perfect_freehand.dart';
import 'package:saber/components/canvas/_stroke.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/native/ink_vault_native.dart';
import 'package:saber/data/office/office_annotation_store.dart';
import 'package:saber/data/office/office_document_store.dart';
import 'package:saber/data/office/office_templates.dart';
import 'package:saber/data/vault/block_page_document.dart';
import 'package:saber/data/vault/dataview.dart';
import 'package:saber/data/vault/dataview_query.dart';
import 'package:saber/data/vault/dataview_result.dart';
import 'package:saber/data/vault/discussion_anchor.dart';
import 'package:saber/data/vault/discussion_store.dart';
import 'package:saber/data/vault/library_store.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/pages/workspace/workspace_controller.dart';
import 'package:sbn/tool_id.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();
  final nativeLibrary = Platform.environment['INK_VAULT_NATIVE_LIBRARY'];
  late NoteRepository first, second;
  late DiscussionStore a, b;
  late SyncCoordinator syncA, syncB;
  late _MemoryRemoteStore remote;

  setUp(() async {
    final owner = Directory.systemTemp;
    final temp = await owner.createTemp('piv-discussion-drive-');
    addTearDown(() async {
      final resolved = await temp.resolveSymbolicLinks();
      expect(p.dirname(resolved), await owner.resolveSymbolicLinks());
      expect(p.basename(resolved), startsWith('piv-discussion-drive-'));
      await Directory(resolved).delete(recursive: true);
    });
    first = await NoteRepository.open(
      Directory(p.join(temp.path, 'first')),
      createFormatVersion: 2,
    );
    addTearDown(first.close);
    second = await NoteRepository.open(
      Directory(p.join(temp.path, 'second')),
      vaultId: first.vaultId,
      createFormatVersion: 2,
    );
    addTearDown(second.close);
    a = DiscussionStore(first);
    b = DiscussionStore(second);
    remote = _MemoryRemoteStore(first.vaultId);
    addTearDown(remote.close);
    syncA = SyncCoordinator(
      repository: first,
      remote: remote,
      stateDirectory: Directory(p.join(temp.path, 'first-sync')),
      debounce: const Duration(milliseconds: 10),
      pollInterval: const Duration(days: 1),
    );
    addTearDown(syncA.close);
    syncB = SyncCoordinator(
      repository: second,
      remote: remote,
      stateDirectory: Directory(p.join(temp.path, 'second-sync')),
    );
    addTearDown(syncB.close);
  });

  Future<VaultNote> createPage({String? folderId}) => WorkspaceStore(
    first,
  ).create('토론 페이지', documentKind: VaultDocumentKind.page, folderId: folderId);

  Future<String> startThread(VaultNote page) => a.createThread(
    page: page.revision,
    anchor: DiscussionAnchor.page(pageId: page.id),
    body: '처음 남긴 댓글',
  );

  test(
    'repository changes upload a comment and its page to the same remote',
    () async {
      final page = await createPage();
      final block = BlockPageBlock.create(type: 'paragraph', text: '인용할 문장');
      final document = const BlockPageDocument.empty().copyWith(
        blocks: [block],
      );
      final session = await WorkspaceStore(first).open(page);
      final bytes = Uint8List.fromList(
        utf8.encode(jsonEncode(document.toJson())),
      );
      await session.saveInk({'page.json': bytes});
      final body = (await first.heads(page.inkEntityId)).single;

      final started = syncA.statuses.firstWhere(
        (s) => s.phase == SyncPhase.synced,
      );
      syncA.start();
      await started.timeout(const Duration(seconds: 5));
      expect(await second.heads(page.id), isEmpty);

      final uploaded = syncA.statuses.firstWhere(
        (s) => s.phase == SyncPhase.synced,
      );
      final threadId = await a.createThread(
        page: page.revision,
        anchor: DiscussionAnchor.quote(
          pageId: page.id,
          document: document,
          blockId: block.id,
          startUtf16: 0,
          endUtf16: 3,
        ),
        body: '한글 😀\n댓글',
      );
      await uploaded.timeout(const Duration(seconds: 5));

      expect(
        remote.records.values.where((r) => r.entityId == threadId),
        hasLength(1),
      );
      await syncB.syncOnce();
      expect(syncB.status.phase, SyncPhase.synced);
      final received = (await WorkspaceStore(second).list()).single;
      expect(received.id, page.id);
      expect(received.revision.revisionId, page.revision.revisionId);
      expect(
        (await second.heads(page.inkEntityId)).single.revisionId,
        body.revisionId,
      );
      final thread = (await b.listThreads(page.id)).single;
      expect(thread.root.id, threadId);
      expect(thread.root.authorDeviceId, first.deviceId);
      expect(thread.root.body, '한글 😀\n댓글');
      expect(thread.anchor.quoteText, '인용할');
      expect(thread.anchorStatus, DiscussionAnchorStatus.attached);
    },
  );

  test(
    'two peers receive both independent replies and divergent status heads',
    () async {
      final page = await createPage();
      final threadId = await startThread(page);
      await syncA.syncOnce();
      await syncB.syncOnce();
      final peer = (await second.heads(page.id)).single;
      final left = await a.reply(
        page: page.revision,
        threadId: threadId,
        replyToId: threadId,
        body: '첫 보관함의 답글',
      );
      final right = await b.reply(
        page: peer,
        threadId: threadId,
        replyToId: threadId,
        body: '둘째 보관함의 답글',
      );
      final resolved = await a.setResolved(
        page: page.revision,
        threadId: threadId,
        resolved: true,
        expectedStatusIds: [threadId],
      );
      final reopened = await b.setResolved(
        page: peer,
        threadId: threadId,
        resolved: false,
        expectedStatusIds: [threadId],
      );
      expect((await a.listThreads(page.id)).single.replies.single.id, left);
      expect((await b.listThreads(page.id)).single.replies.single.id, right);

      await syncA.syncOnce();
      await syncB.syncOnce();
      await syncA.syncOnce();
      for (final (store, sync) in [(a, syncA), (b, syncB)]) {
        expect(sync.status.phase, SyncPhase.synced);
        final thread = (await store.listThreads(page.id)).single;
        expect(
          {for (final reply in thread.replies) reply.id: reply.authorDeviceId},
          {left: first.deviceId, right: second.deviceId},
        );
        expect(thread.status, DiscussionThreadStatus.conflict);
        expect(thread.statusHeadIds, unorderedEquals([resolved, reopened]));
        expect(store.repository.pendingRevisionCount, 0);
      }

      final merged = await a.setResolved(
        page: page.revision,
        threadId: threadId,
        resolved: true,
        expectedStatusIds: [resolved, reopened],
      );
      await syncA.syncOnce();
      await syncB.syncOnce();
      final received = (await b.listThreads(page.id)).single;
      expect(received.status, DiscussionThreadStatus.resolved);
      expect(received.statusHeadIds, [merged]);
      expect(
        received.replies.map((reply) => reply.id),
        unorderedEquals([left, right]),
      );
    },
  );

  test(
    'a reply unseen by a folder trash operation remains a sync conflict',
    () async {
      final library = LibraryStore(first);
      final folder = await library.createFolder('댓글 보관 폴더');
      final page = await createPage(folderId: folder.id);
      final threadId = await startThread(page);
      await syncA.syncOnce();
      await syncB.syncOnce();

      await library.setDeleted(folder, true);
      final deletion = (await first.heads(folder.id)).single;
      expect(deletion.baseRefs, contains(threadId));
      final reply = await b.reply(
        page: (await second.heads(page.id)).single,
        threadId: threadId,
        replyToId: threadId,
        body: '폴더를 휴지통에 보낼 때 아직 받지 못한 답글',
      );
      expect(deletion.baseRefs, isNot(contains(reply)));
      await syncA.syncOnce();
      await syncB.syncOnce();
      await syncA.syncOnce();

      for (final (store, sync) in [(a, syncA), (b, syncB)]) {
        expect(sync.status.phase, SyncPhase.conflict);
        expect(
          (await store.listThreads(page.id)).single.replies.single.id,
          reply,
        );
        expect(
          (await store.repository.heads(folder.id)).single.deleted,
          isTrue,
        );
      }
    },
  );

  test(
    'Dataview TASK auto-syncs both ways without changing PPTX, PDF, or ink',
    () async {
      final native = InkVaultNative.open(libraryPath: nativeLibrary!);
      final left = WorkspaceController(first, native: native);
      final right = WorkspaceController(second, native: native);
      SyncCoordinator automaticSync(NoteRepository repo) => SyncCoordinator(
        repository: repo,
        remote: remote,
        stateDirectory: Directory(
          p.join(repo.root.parent.path, 'auto-${repo.deviceId}'),
        ),
        debounce: const Duration(milliseconds: 10),
        pollInterval: const Duration(milliseconds: 75),
      );
      final autoLeft = automaticSync(first);
      final autoRight = automaticSync(second);
      addTearDown(() async {
        await autoLeft.close();
        await autoRight.close();
        left.dispose();
        right.dispose();
      });
      expect(first.deviceId, isNot(second.deviceId));

      const source = '\uFEFF# 한글 🧪\r\n\r\n- [ ]  할 일\r\n';
      final originalBytes = utf8.encode(source);
      final completedBytes = utf8.encode(source.replaceFirst('[ ]', '[x]'));
      final taskNote = await left.store.createMarkdown(
        '할 일 원본',
        Uint8List.fromList(originalBytes),
      );
      final dashboard = await left.store.createMarkdown(
        '할 일 대시보드',
        Uint8List.fromList(utf8.encode('```dataview\nTASK\n```\n')),
      );
      final original = (await first.heads(taskNote.markdownEntityId)).single;

      final documents = OfficeDocumentStore(first);
      final starter = OfficeTemplates.create(
        OfficeTemplateKind.presentation,
        title: '발표 원본',
      );
      final office = await documents.importDocument(
        title: '발표 자료',
        fileName: starter.fileName,
        bytes: starter.bytes,
      );
      final pdf = pw.Document()
        ..addPage(pw.Page(build: (_) => pw.SizedBox(width: 40, height: 20)));
      final pdfBytes = await pdf.save();
      final edition = await documents.commitEdited(
        await documents.beginEdit(office),
        originalBytes: starter.bytes,
        pdfBytes: pdfBytes,
        engineVersion: 'Drive fixture',
        pageCount: 1,
      );
      final core = EditorCoreInfo(filePath: '/dataview-drive');
      addTearDown(core.dispose);
      final page = EditorPage();
      core.pages.add(page);
      page.strokes.add(
        Stroke(
          color: Colors.blue,
          pressureEnabled: false,
          options: StrokeOptions(size: 4, thinning: 0),
          pageIndex: 0,
          page: page,
          toolId: ToolId.ballpointPen,
        )..addPoints(const [Offset(10, 10), Offset(25, 25)]),
      );
      final annotation = await OfficeAnnotationStore(first)
          .open(office, edition);
      await annotation.saveSnapshot(core, 0);
      final ink = annotation.revision!;
      final inkFiles = await first.readFiles(ink);

      await left.openNote(dashboard);
      await left.refresh();
      List<DataviewRow> query(WorkspaceController controller, String source) =>
          evaluateDataview(
            controller.knowledge!,
            native,
            DataviewQuery.parse(source),
          ).rows;

      Future<void> waitForSyncedHead(
        SyncCoordinator sync,
        RevisionRecord expected,
      ) async {
        final deadline = Stopwatch()..start();
        while (deadline.elapsed < const Duration(seconds: 10)) {
          if (sync.status.phase == SyncPhase.synced &&
              remote.records.values.any(
                (record) => record.revisionId == expected.revisionId,
              )) {
            final heads = await sync.repository.heads(expected.entityId);
            if (heads.singleOrNull?.revisionId == expected.revisionId) return;
          }
          await Future<void>.delayed(const Duration(milliseconds: 15));
        }
        fail(
          'Expected synced revision ${expected.revisionId} on '
          '${sync.repository.deviceId}; got ${sync.status.phase} ${sync.status.message ?? ''}',
        );
      }

      autoLeft.start();
      autoRight.start();
      await waitForSyncedHead(autoRight, original);
      await waitForSyncedHead(autoRight, dashboard.revision);
      await right.refresh();
      await right.openNote(
        right.notes.singleWhere((n) => n.id == dashboard.id),
      );
      expect(
        query(right, 'TASK WHERE !completed').single.task!.revisionId,
        original.revisionId,
      );

      final row = query(left, 'TASK WHERE !completed').single;
      expect(row.noteId, taskNote.id);
      await left.setDataviewTask(
        row,
        true,
        isCurrent: () => left.knowledgeCurrent,
      );
      final completed = (await first.heads(taskNote.markdownEntityId)).single;
      expect(completed.parentRevisionIds, [original.revisionId]);
      await waitForSyncedHead(autoLeft, completed);
      await waitForSyncedHead(autoRight, completed);
      await right.refresh();
      expect(query(right, 'TASK WHERE !completed'), isEmpty);
      final received = query(right, 'TASK WHERE completed').single;
      expect(received.task!.revisionId, completed.revisionId);
      expect(
        await second.readRevisionFile(completed, 'summary.md'),
        completedBytes,
      );

      await right.setDataviewTask(
        received,
        false,
        isCurrent: () => right.knowledgeCurrent,
      );
      final reopened = (await second.heads(taskNote.markdownEntityId)).single;
      expect(reopened.parentRevisionIds, [completed.revisionId]);
      await waitForSyncedHead(autoRight, reopened);
      await waitForSyncedHead(autoLeft, reopened);
      await autoLeft.close();
      await autoRight.close();
      await left.refresh();
      expect(query(left, 'TASK WHERE completed'), isEmpty);
      expect(
        query(left, 'TASK WHERE !completed').single.task!.revisionId,
        reopened.revisionId,
      );

      for (final repo in [first, second]) {
        expect(repo.pendingRevisionCount, 0);
        expect(
          (await repo.revisions())
              .where(
                (revision) => revision.entityId == taskNote.markdownEntityId,
              )
              .map((revision) => revision.revisionId),
          unorderedEquals([
            original.revisionId,
            completed.revisionId,
            reopened.revisionId,
          ]),
        );
        expect(
          (await repo.heads(taskNote.markdownEntityId)).single.revisionId,
          reopened.revisionId,
        );
        expect(
          await repo.readRevisionFile(original, 'summary.md'),
          originalBytes,
        );
        expect(
          await repo.readRevisionFile(completed, 'summary.md'),
          completedBytes,
        );
        expect(
          await repo.readRevisionFile(reopened, 'summary.md'),
          originalBytes,
        );
        final sameOffice = (await WorkspaceStore(
          repo,
        ).list()).singleWhere((n) => n.id == office.id);
        final sameEdition = await OfficeDocumentStore(repo)
            .readLatest(sameOffice);
        expect(sameEdition.revision.revisionId, edition.revision.revisionId);
        expect(sameEdition.originalBytes, starter.bytes);
        expect(sameEdition.pdfBytes, pdfBytes);
        final sameAnnotation = await OfficeAnnotationStore(repo)
            .open(sameOffice, sameEdition);
        expect(sameAnnotation.revision!.revisionId, ink.revisionId);
        expect(await repo.readFiles(sameAnnotation.revision!), inkFiles);
      }
    },
    skip: nativeLibrary == null
        ? 'Set INK_VAULT_NATIVE_LIBRARY for Dataview'
        : false,
  );
}

class _MemoryRemoteStore implements RemoteStore {
  new(this.vaultId);

  @override
  final String vaultId;
  @override
  final remoteId = 'page-discussion-test';
  final records = <String, RevisionRecord>{};
  final _blobs = <String, Uint8List>{};
  var _nextId = 0;

  @override
  Future<String> generateId() async => 'file-${_nextId++}';

  @override
  Future<String?> findBlob(BlobRef ref) async =>
      _blobs.containsKey(ref.hash) ? ref.hash : null;

  @override
  Future<void> putBlob(
    BlobRef ref,
    Uint8List bytes,
    String intentFileId,
  ) async {
    _blobs[ref.hash] = Uint8List.fromList(bytes);
  }

  @override
  Future<void> publishRevision(
    RevisionRecord record,
    String intentFileId,
  ) async {
    if (record.vaultId != vaultId ||
        record.blobs.values.any((ref) => !_blobs.containsKey(ref.hash))) {
      throw StateError('A manifest must follow its own vault payloads');
    }
    records.putIfAbsent(intentFileId, () => record);
  }

  @override
  Future<RevisionRecord> readManifest(String fileId) async =>
      records[fileId] ?? (throw RemoteException.missing('manifest absent'));

  @override
  Future<Uint8List> readBlob(BlobRef ref) async => Uint8List.fromList(
    _blobs[ref.hash] ?? (throw RemoteException.missing('blob absent')),
  );

  @override
  Future<String> startPageToken() async => records.length.toString();

  @override
  Future<RemotePage> listManifests({String? pageToken}) async =>
      RemotePage(records.keys.map(RemoteChange.new).toList());

  @override
  Future<RemotePage> readChanges(String pageToken) async => RemotePage(
    records.keys.skip(int.parse(pageToken)).map(RemoteChange.new).toList(),
    newStartPageToken: records.length.toString(),
  );

  @override
  void close() {}
}
