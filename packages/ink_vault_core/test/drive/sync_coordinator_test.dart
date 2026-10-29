import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ink_vault_core/drive.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:test/test.dart';

Uint8List data(String s) => Uint8List.fromList(utf8.encode(s));

class MemoryRemote implements RemoteStore {
  @override
  final String vaultId;
  @override
  String get remoteId => 'test-folder';
  final blobs = <String, Uint8List>{};
  final records = <String, RevisionRecord>{};
  final log = <String>[];
  final events = <RemoteChange>[];
  bool offline = false, losePublishResponse = false, authFailure = false;
  bool invalidateCursor = false;
  int pageSize = 1000, scans = 0;
  int generated = 0;
  final publishIds = <String>[];
  MemoryRemote(this.vaultId);
  void check() {
    if (authFailure) throw RemoteException.authentication();
    if (offline) throw RemoteException.retryable('offline');
  }

  @override
  Future<String> generateId() async {
    check();
    return 'file-${generated++}';
  }

  @override
  Future<String?> findBlob(BlobRef ref) async {
    check();
    return blobs.containsKey(ref.hash) ? ref.hash : null;
  }

  @override
  Future<void> putBlob(
    BlobRef ref,
    Uint8List bytes,
    String intentFileId,
  ) async {
    check();
    log.add('blob');
    blobs[ref.hash] = bytes;
  }

  @override
  Future<void> publishRevision(
    RevisionRecord record,
    String intentFileId,
  ) async {
    check();
    publishIds.add(intentFileId);
    log.add('manifest');
    if (!records.containsKey(intentFileId)) {
      records[intentFileId] = record;
      events.add(RemoteChange(intentFileId));
    }
    if (losePublishResponse) {
      losePublishResponse = false;
      throw RemoteException.retryable('response lost');
    }
  }

  @override
  Future<RevisionRecord> readManifest(String fileId) async {
    check();
    final record = records[fileId];
    if (record == null) throw RemoteException.missing('manifest absent');
    return record;
  }

  @override
  Future<Uint8List> readBlob(BlobRef ref) async {
    check();
    final bytes = blobs[ref.hash];
    if (bytes == null) throw RemoteException.missing('blob absent');
    return bytes;
  }

  @override
  Future<String> startPageToken() async {
    check();
    return '${events.length}';
  }

  @override
  Future<RemotePage> listManifests({String? pageToken}) async {
    check();
    scans++;
    final offset = int.parse(pageToken ?? '0');
    final ids = records.keys.skip(offset).take(pageSize).toList();
    return RemotePage(
      ids.map((id) => RemoteChange(id)).toList(),
      nextPageToken: offset + ids.length < records.length
          ? '${offset + ids.length}'
          : null,
    );
  }

  @override
  Future<RemotePage> readChanges(String pageToken) async {
    check();
    final offset = int.tryParse(pageToken);
    if (offset == null || invalidateCursor) {
      invalidateCursor = false;
      throw RemoteException.invalidCursor();
    }
    final changes = events.skip(offset).take(pageSize).toList();
    return RemotePage(
      changes,
      nextPageToken: offset + changes.length < events.length
          ? '${offset + changes.length}'
          : null,
      newStartPageToken: '${events.length}',
    );
  }

  @override
  void close() {}
}

void main() {
  late Directory temp;
  late NoteRepository a, b;
  late MemoryRemote remote;
  late SyncCoordinator sa, sb;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('ink-drive-test-');
    a = await NoteRepository.open(Directory('${temp.path}/a'));
    b = await NoteRepository.open(
      Directory('${temp.path}/b'),
      vaultId: a.vaultId,
    );
    remote = MemoryRemote(a.vaultId);
    sa = SyncCoordinator(
      repository: a,
      remote: remote,
      stateDirectory: Directory('${temp.path}/sa'),
    );
    sb = SyncCoordinator(
      repository: b,
      remote: remote,
      stateDirectory: Directory('${temp.path}/sb'),
    );
  });
  tearDown(() async {
    await sa.close();
    await sb.close();
    await a.close();
    await b.close();
    await temp.delete(recursive: true);
  });
  Future<RevisionRecord> write(
    NoteRepository r,
    String id,
    String text, [
    List<String> parents = const [],
  ]) => r.commit(
    entityId: id,
    kind: EntityKind.markdown,
    files: {'summary.md': data(text)},
    parentRevisionIds: parents,
  );

  test('two disk repositories receive complete snapshots with blobs before manifests', () async {
    final revision = await write(a, newId(), 'first');
    await sa.syncOnce();
    await sb.syncOnce();
    expect(remote.log, ['blob', 'manifest']);
    expect(
      (await b.heads(revision.entityId)).single.revisionId,
      revision.revisionId,
    );
    expect(utf8.decode((await b.readFiles(revision))['summary.md']!), 'first');
    expect(sb.status.phase, SyncPhase.synced);
  });
  test(
    'offline branches survive and explicit merge reaches both repositories',
    () async {
      final id = newId();
      final base = await write(a, id, 'base');
      await sa.syncOnce();
      await sb.syncOnce();
      final left = await write(a, id, 'left', [base.revisionId]);
      final right = await write(b, id, 'right', [base.revisionId]);
      await sa.syncOnce();
      await sb.syncOnce();
      await sa.syncOnce();
      expect(
        (await a.heads(id)).map((r) => r.revisionId),
        unorderedEquals([left.revisionId, right.revisionId]),
      );
      expect(sa.status.phase, SyncPhase.conflict);
      final merged = await write(a, id, 'both', [
        left.revisionId,
        right.revisionId,
      ]);
      await sa.syncOnce();
      await sb.syncOnce();
      expect((await b.heads(id)).single.revisionId, merged.revisionId);
    },
  );
  test(
    'lost publish response reuses persisted file ID after coordinator restart',
    () async {
      final revision = await write(a, newId(), 'durable');
      remote.losePublishResponse = true;
      await sa.syncOnce();
      expect(sa.status.phase, SyncPhase.retryWaiting);
      await sa.close();
      await a.close();
      a = await NoteRepository.open(a.root);
      sa = SyncCoordinator(
        repository: a,
        remote: remote,
        stateDirectory: Directory('${temp.path}/sa'),
      );
      await sa.syncOnce(force: true);
      expect(remote.publishIds.toSet(), hasLength(1));
      expect(
        remote.records.values.where((r) => r.revisionId == revision.revisionId),
        hasLength(1),
      );
      expect(sa.status.phase, SyncPhase.synced);
    },
  );
  test(
    'missing blob remains queued after advancing cursor and restart',
    () async {
      final revision = await write(a, newId(), 'later');
      await sa.syncOnce();
      final hash = revision.blobs.values.single.hash;
      final payload = remote.blobs.remove(hash)!;
      await sb.syncOnce();
      expect(await b.heads(revision.entityId), isEmpty);
      expect(sb.status.phase, SyncPhase.retryWaiting);
      await sb.close();
      await b.close();
      b = await NoteRepository.open(b.root);
      sb = SyncCoordinator(
        repository: b,
        remote: remote,
        stateDirectory: Directory('${temp.path}/sb'),
      );
      remote.blobs[hash] = payload;
      await sb.syncOnce(force: true);
      expect(
        (await b.heads(revision.entityId)).single.revisionId,
        revision.revisionId,
      );
    },
  );
  test('corrupt blob never activates incomplete remote revision', () async {
    final revision = await write(a, newId(), 'safe');
    await sa.syncOnce();
    remote.blobs[revision.blobs.values.single.hash] = data('evil');
    await sb.syncOnce();
    expect(await b.revisions(), isEmpty);
    expect(sb.status.phase, SyncPhase.error);
  });
  test(
    'missing ancestor stays pending instead of reporting sync complete',
    () async {
      final base = await write(a, newId(), 'base');
      final child = await write(a, base.entityId, 'child', [base.revisionId]);
      remote.records['child'] = child;
      remote.blobs[child.blobs.values.single.hash] = data('child');
      await sb.syncOnce();
      expect(await b.heads(base.entityId), isEmpty);
      expect(sb.status.phase, SyncPhase.retryWaiting);
      remote.records['base'] = base;
      remote.events.add(const RemoteChange('base'));
      remote.blobs[base.blobs.values.single.hash] = data('base');
      await sb.syncOnce(force: true);
      expect(
        (await b.heads(base.entityId)).single.revisionId,
        child.revisionId,
      );
      expect(sb.status.phase, SyncPhase.synced);
    },
  );
  test(
    'all fullscan and changes pages survive an invalid cursor reset',
    () async {
      remote.pageSize = 1;
      final first = await write(a, newId(), 'one');
      final second = await write(a, newId(), 'two');
      await sa.syncOnce();
      await sb.syncOnce();
      expect(await b.revisions(), hasLength(2));
      expect(remote.scans, greaterThan(2));
      final third = await write(a, newId(), 'three');
      await sa.syncOnce();
      remote.invalidateCursor = true;
      await sb.syncOnce();
      expect(
        (await b.revisions()).map((r) => r.revisionId),
        unorderedEquals([
          first.revisionId,
          second.revisionId,
          third.revisionId,
        ]),
      );
      expect(sb.status.phase, SyncPhase.synced);
    },
  );
  test('external manifest deletion reports recovery issue without deleting local content', () async {
    final r = await write(a, newId(), 'keep');
    await sa.syncOnce();
    await sb.syncOnce();
    final fileId = remote.records.keys.single;
    remote.records.remove(fileId);
    remote.events.add(RemoteChange(fileId, removed: true));
    await sb.syncOnce();
    expect(sb.status.phase, SyncPhase.error);
    expect((await b.heads(r.entityId)).single.revisionId, r.revisionId);
    expect(utf8.decode((await b.readFiles(r))['summary.md']!), 'keep');
  });
  test('authentication stops automatic retry until explicit resume', () async {
    await write(a, newId(), 'local');
    remote.authFailure = true;
    await sa.syncOnce();
    expect(sa.status.phase, SyncPhase.authenticationRequired);
    remote.authFailure = false;
    await sa.syncOnce(force: true);
    expect(remote.records, isEmpty);
    sa.resume();
    await sa.syncOnce(force: true);
    expect(remote.records, hasLength(1));
  });
  for (final damage in ['blob', 'manifest']) {
    test(
      'unchanged remote repairs reopened local $damage with cached cursor',
      () async {
        final base = await write(a, newId(), 'base');
        final tip = await write(a, base.entityId, 'tip', [base.revisionId]);
        await sa.syncOnce();
        await sb.syncOnce();
        await sb.close();
        await b.close();
        final target = damage == 'blob'
            ? File('${b.root.path}/blobs/${tip.blobs.values.single.hash}')
            : File('${b.root.path}/revisions/${tip.revisionId}.json');
        await target.writeAsString('{');
        b = await NoteRepository.open(b.root);
        expect(
          (await b.heads(base.entityId)).single.revisionId,
          base.revisionId,
        );
        expect(b.integrityIssues, isNotEmpty);
        sb = SyncCoordinator(
          repository: b,
          remote: remote,
          stateDirectory: Directory('${temp.path}/sb'),
        );
        await sb.syncOnce(force: true);
        expect(
          (await b.heads(base.entityId)).single.revisionId,
          tip.revisionId,
        );
        expect(utf8.decode((await b.readFiles(tip))['summary.md']!), 'tip');
        expect(b.integrityIssues, isEmpty);
        expect(sb.status.phase, SyncPhase.synced);
      },
    );
  }
  test(
    'unrecoverable local blob stays queued across authentication and restart',
    () async {
      final revision = await write(a, newId(), 'recover');
      await sa.syncOnce();
      await sb.syncOnce();
      await sb.close();
      await b.close();
      final hash = revision.blobs.values.single.hash;
      await File('${b.root.path}/blobs/$hash').writeAsString('bad');
      final good = remote.blobs.remove(hash)!;
      b = await NoteRepository.open(b.root);
      sb = SyncCoordinator(
        repository: b,
        remote: remote,
        stateDirectory: Directory('${temp.path}/sb'),
      );
      remote.authFailure = true;
      await sb.syncOnce(force: true);
      expect(sb.status.phase, SyncPhase.authenticationRequired);
      remote.authFailure = false;
      sb.resume();
      await sb.syncOnce(force: true);
      expect(sb.status.phase, SyncPhase.retryWaiting);
      expect(sb.status.pendingDownloads, 1);
      expect(b.integrityIssues, isNotEmpty);
      await sb.close();
      sb = SyncCoordinator(
        repository: b,
        remote: remote,
        stateDirectory: Directory('${temp.path}/sb'),
      );
      remote.blobs[hash] = good;
      await sb.syncOnce(force: true);
      expect(sb.status.phase, SyncPhase.synced);
      expect((await b.revisions()).single.revisionId, revision.revisionId);
    },
  );
  test(
    'same remote file restoration clears removal after verified recovery',
    () async {
      final revision = await write(a, newId(), 'keep');
      await sa.syncOnce();
      await sb.syncOnce();
      final fileId = remote.records.keys.single;
      remote.records.remove(fileId);
      remote.events.add(RemoteChange(fileId, removed: true));
      await sb.syncOnce();
      expect(sb.status.phase, SyncPhase.error);
      remote.records[fileId] = revision;
      remote.events.add(RemoteChange(fileId));
      sb.resume();
      await sb.syncOnce(force: true);
      expect(sb.status.phase, SyncPhase.synced);
      expect((await b.revisions()).single.revisionId, revision.revisionId);
    },
  );
  test(
    'removed file replaced with another valid revision remains an error',
    () async {
      await write(a, newId(), 'keep');
      await sa.syncOnce();
      await sb.syncOnce();
      final fileId = remote.records.keys.single;
      remote.records.remove(fileId);
      remote.events.add(RemoteChange(fileId, removed: true));
      await sb.syncOnce();
      final replacement = await write(a, newId(), 'unrelated');
      remote.records[fileId] = replacement;
      remote.events.add(RemoteChange(fileId));
      sb.resume();
      await sb.syncOnce(force: true);
      expect(sb.status.phase, SyncPhase.error);
      expect(await b.revisions(), hasLength(1));
    },
  );
  test(
    'tombstone and offline child remain recoverable with note conflict',
    () async {
      final note = await a.commit(
        entityId: newId(),
        kind: EntityKind.metadata,
        files: {},
        parentRevisionIds: [],
      );
      final child = await a.commit(
        entityId: newId(),
        kind: EntityKind.markdown,
        ownerNoteId: note.entityId,
        files: {'summary.md': data('base')},
        parentRevisionIds: [],
      );
      await sa.syncOnce();
      await sb.syncOnce();
      await a.commit(
        entityId: note.entityId,
        kind: EntityKind.metadata,
        files: {},
        parentRevisionIds: [note.revisionId],
        deleted: true,
        baseRefs: {
          child.entityId: [child.revisionId],
        },
      );
      final edit = await b.commit(
        entityId: child.entityId,
        kind: EntityKind.markdown,
        ownerNoteId: note.entityId,
        files: {'summary.md': data('offline')},
        parentRevisionIds: [child.revisionId],
      );
      await sa.syncOnce();
      await sb.syncOnce();
      await sa.syncOnce();
      expect(
        (await a.heads(child.entityId)).single.revisionId,
        edit.revisionId,
      );
      expect(sa.status.phase, SyncPhase.conflict);
      expect((await b.heads(note.entityId)).single.deleted, isTrue);
    },
  );
  test(
    'automatic listener and polling deliver a commit without manual sync',
    () async {
      await sa.close();
      await sb.close();
      sa = SyncCoordinator(
        repository: a,
        remote: remote,
        stateDirectory: Directory('${temp.path}/sa'),
        debounce: const Duration(milliseconds: 5),
        pollInterval: const Duration(milliseconds: 20),
      );
      sb = SyncCoordinator(
        repository: b,
        remote: remote,
        stateDirectory: Directory('${temp.path}/sb'),
        debounce: const Duration(milliseconds: 5),
        pollInterval: const Duration(milliseconds: 20),
      );
      sa.start();
      sb.start();
      final r = await write(a, newId(), 'automatic');
      for (var n = 0; n < 150 && (await b.heads(r.entityId)).isEmpty; n++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect((await b.heads(r.entityId)).single.revisionId, r.revisionId);
    },
  );
}
