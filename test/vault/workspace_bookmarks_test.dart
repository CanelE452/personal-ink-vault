import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/drive.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/vault/note_link.dart';
import 'package:saber/data/vault/workspace_bookmarks.dart';

void main() {
  late Directory temporary;
  late NoteRepository repository;
  late WorkspaceBookmarkStore bookmarks;

  setUp(() async {
    final owner = Directory.systemTemp;
    temporary = await owner.createTemp('piv-bookmarks-');
    addTearDown(() async {
      final resolved = await temporary.resolveSymbolicLinks();
      expect(p.dirname(resolved), await owner.resolveSymbolicLinks());
      expect(p.basename(resolved), startsWith('piv-bookmarks-'));
      await Directory(resolved).delete(recursive: true);
    });
    repository = await NoteRepository.open(
      Directory(p.join(temporary.path, 'first')),
      createFormatVersion: 2,
    );
    addTearDown(repository.close);
    bookmarks = WorkspaceBookmarkStore(repository);
  });

  test('reopens nested groups and exact note targets in vault order', () async {
    final group = await bookmarks.add(
      const WorkspaceBookmarkSpec(
        kind: WorkspaceBookmarkKind.group,
        title: '강의',
        order: 1,
      ),
    );
    final child = await bookmarks.add(
      WorkspaceBookmarkSpec(
        kind: WorkspaceBookmarkKind.group,
        groupId: group.id,
        title: '복습',
        order: 2,
      ),
    );
    final link = NoteLink.markdown(newId(), '^anchor');
    final note = await bookmarks.add(
      WorkspaceBookmarkSpec(
        kind: WorkspaceBookmarkKind.note,
        groupId: child.id,
        target: link.toString(),
        order: 4,
      ),
    );
    final page = await bookmarks.add(
      WorkspaceBookmarkSpec(
        kind: WorkspaceBookmarkKind.note,
        target: NoteLink(newId()).toString(),
        pdfPageNumber: 3,
        order: 3,
      ),
    );
    final record = (await repository.heads(note.id)).single;
    expect(record.kind, EntityKind.attachment);
    expect(record.ownerNoteId, isNull);
    expect(record.blobs.keys, ['workspace-bookmark.json']);
    await repository.close();
    final reopened = await NoteRepository.open(repository.root);
    addTearDown(reopened.close);
    final saved = await WorkspaceBookmarkStore(reopened).list();
    expect(saved.map((item) => item.id), [
      group.id,
      child.id,
      page.id,
      note.id,
    ]);
    expect(saved[2].spec.pdfPageNumber, 3);
    expect(saved[3].spec.groupId, child.id);
    expect(saved[3].spec.target, link.toString());
  });

  test(
    'stores an Office page target without an extra PDF page number',
    () async {
      final target = (
        sourceRevisionId: newId(),
        pdfBindingId: newId(),
        pageId: newId(),
      );
      final link = NoteLink.officePage(newId(), target).toString();
      await bookmarks.add(
        WorkspaceBookmarkSpec(kind: WorkspaceBookmarkKind.note, target: link),
      );
      final saved = (await bookmarks.list()).single.spec;
      expect(saved.target, link);
      expect(NoteLink.parse(saved.target!)?.officePageTarget, target);
      await expectLater(
        bookmarks.add(
          WorkspaceBookmarkSpec(
            kind: WorkspaceBookmarkKind.note,
            target: link,
            pdfPageNumber: 1,
          ),
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'guards stale mutations and keeps children after group removal',
    () async {
      final group = await bookmarks.add(
        const WorkspaceBookmarkSpec(
          kind: WorkspaceBookmarkKind.group,
          title: '책',
        ),
      );
      final initial = await bookmarks.add(
        WorkspaceBookmarkSpec(
          kind: WorkspaceBookmarkKind.search,
          target: 'lecture',
          groupId: group.id,
        ),
      );
      final latest = await bookmarks.update(
        initial,
        WorkspaceBookmarkSpec(
          kind: WorkspaceBookmarkKind.search,
          title: '강의 검색',
          target: 'lecture',
          groupId: group.id,
        ),
      );
      expect(latest.spec.order, initial.spec.order);
      await expectLater(bookmarks.remove(initial), throwsStateError);
      await bookmarks.remove(group);
      expect((await bookmarks.list()).single.revisionId, latest.revisionId);
      await expectLater(
        bookmarks.add(
          WorkspaceBookmarkSpec(
            kind: WorkspaceBookmarkKind.folder,
            groupId: group.id,
            target: newId(),
          ),
        ),
        throwsStateError,
      );
    },
  );

  test('refuses ambiguous page locations and unsafe URLs', () async {
    await expectLater(
      bookmarks.add(
        WorkspaceBookmarkSpec(
          kind: WorkspaceBookmarkKind.note,
          target: NoteLink(newId(), newId()).toString(),
          pdfPageNumber: 4,
        ),
      ),
      throwsFormatException,
    );
    await expectLater(
      bookmarks.add(
        const WorkspaceBookmarkSpec(
          kind: WorkspaceBookmarkKind.url,
          target: 'javascript:alert(1)',
        ),
      ),
      throwsFormatException,
    );
    expect(await repository.revisions(), isEmpty);
  });

  test(
    'two repositories exchange independent additions and keep conflicts',
    () async {
      final second = await NoteRepository.open(
        Directory(p.join(temporary.path, 'second')),
        vaultId: repository.vaultId,
        createFormatVersion: 2,
      );
      addTearDown(second.close);
      final remote = _MemoryRemote(repository.vaultId);
      final syncA = SyncCoordinator(
        repository: repository,
        remote: remote,
        stateDirectory: Directory(p.join(temporary.path, 'syncA')),
      );
      addTearDown(syncA.close);
      final syncB = SyncCoordinator(
        repository: second,
        remote: remote,
        stateDirectory: Directory(p.join(temporary.path, 'syncB')),
      );
      addTearDown(syncB.close);
      final peer = WorkspaceBookmarkStore(second);
      final original = await bookmarks.add(
        const WorkspaceBookmarkSpec(
          kind: WorkspaceBookmarkKind.search,
          target: 'Original',
        ),
      );
      await syncA.syncOnce();
      await syncB.syncOnce();
      final firstEdit = await bookmarks.update(
        original,
        const WorkspaceBookmarkSpec(
          kind: WorkspaceBookmarkKind.search,
          target: 'First',
        ),
      );
      final secondEdit = await peer.update(
        (await peer.list()).single,
        const WorkspaceBookmarkSpec(
          kind: WorkspaceBookmarkKind.search,
          target: 'Second',
        ),
      );
      final leftOnly = await bookmarks.add(
        const WorkspaceBookmarkSpec(
          kind: WorkspaceBookmarkKind.url,
          target: 'https://example.com/a',
        ),
      );
      final rightOnly = await peer.add(
        const WorkspaceBookmarkSpec(
          kind: WorkspaceBookmarkKind.url,
          target: 'https://example.com/b',
        ),
      );
      await syncA.syncOnce();
      await syncB.syncOnce();
      await syncA.syncOnce();
      for (final store in [bookmarks, peer]) {
        final merged = await store.list();
        expect(merged.map((item) => item.id).toSet(), {
          original.id,
          leftOnly.id,
          rightOnly.id,
        });
        final variants = merged.where((item) => item.id == original.id);
        expect(
          variants.map((item) => item.revisionId),
          unorderedEquals([firstEdit.revisionId, secondEdit.revisionId]),
        );
        expect(variants.every((item) => item.conflicted), isTrue);
      }
      final choice = (await bookmarks.list()).singleWhere(
        (item) => item.revisionId == secondEdit.revisionId,
      );
      final resolution = await bookmarks.resolve(choice);
      await syncA.syncOnce();
      await syncB.syncOnce();
      final received = (await peer.list()).singleWhere(
        (item) => item.id == original.id,
      );
      expect(received.revisionId, resolution.revisionId);
      expect(received.spec.target, 'Second');
      expect(received.conflicted, isFalse);
    },
  );
}

class _MemoryRemote implements RemoteStore {
  new(this.vaultId);

  @override
  final String vaultId;
  @override
  final remoteId = 'workspace-bookmarks-test';
  final _records = <String, RevisionRecord>{};
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
    expect(record.vaultId, vaultId);
    expect(
      record.blobs.values.every((ref) => _blobs.containsKey(ref.hash)),
      isTrue,
    );
    _records.putIfAbsent(intentFileId, () => record);
  }

  @override
  Future<RevisionRecord> readManifest(String fileId) async => _records[fileId]!;

  @override
  Future<Uint8List> readBlob(BlobRef ref) async => _blobs[ref.hash]!;

  @override
  Future<String> startPageToken() async => _records.length.toString();

  @override
  Future<RemotePage> listManifests({String? pageToken}) async =>
      RemotePage(_records.keys.map(RemoteChange.new).toList());

  @override
  Future<RemotePage> readChanges(String pageToken) async => RemotePage(
    _records.keys.skip(int.parse(pageToken)).map(RemoteChange.new).toList(),
    newStartPageToken: _records.length.toString(),
  );

  @override
  void close() {}
}
