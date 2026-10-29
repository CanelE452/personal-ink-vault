import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:test/test.dart';

Uint8List bytes(String value) => Uint8List.fromList(utf8.encode(value));

final class BlobReadCounter extends IOOverrides {
  final reads = <String, int>{};
  @override
  File createFile(String path) {
    final file = super.createFile(path);
    if (!RegExp(r'/blobs/[a-f0-9]{64}$').hasMatch(path.replaceAll('\\', '/'))) {
      return file;
    }
    return CountingBlobFile(
      file,
      () => reads.update(path, (n) => n + 1, ifAbsent: () => 1),
    );
  }
}

class CountingBlobFile implements File {
  final File file;
  final void Function() count;
  CountingBlobFile(this.file, this.count);
  @override
  String get path => file.path;
  @override
  Future<bool> exists() => file.exists();
  @override
  Future<Uint8List> readAsBytes() {
    count();
    return file.readAsBytes();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory temp;
  late NoteRepository repo;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('ink-core-test-');
    repo = await NoteRepository.open(Directory('${temp.path}/vault'));
  });
  tearDown(() async {
    await repo.close();
    await temp.delete(recursive: true);
  });

  test('committed PDF and ink reopen byte-for-byte with stable IDs', () async {
    final entityId = newId();
    final first = await repo.commit(
      entityId: entityId,
      kind: EntityKind.ink,
      files: {
        'main.sbn2': bytes('abc'),
        'assets/source.pdf': bytes('%PDF-original'),
      },
      parentRevisionIds: [],
    );
    final originalVault = repo.vaultId;
    final originalDevice = repo.deviceId;
    await repo.close();
    repo = await NoteRepository.open(repo.root);
    expect(repo.vaultId, originalVault);
    expect(repo.deviceId, originalDevice);
    expect((await repo.heads(entityId)).single.revisionId, first.revisionId);
    final files = await repo.readFiles(first);
    expect(utf8.decode(files['main.sbn2']!), 'abc');
    expect(utf8.decode(files['assets/source.pdf']!), '%PDF-original');
    expect(
      first.blobs['main.sbn2']!.hash,
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    );
  });

  test(
    'same base forks survive and explicit merge consumes both heads',
    () async {
      final id = newId();
      final base = await repo.commit(
        entityId: id,
        kind: EntityKind.markdown,
        files: {'summary.md': bytes('base')},
        parentRevisionIds: [],
      );
      final branches = await Future.wait([
        repo.commit(
          entityId: id,
          kind: EntityKind.markdown,
          files: {'summary.md': bytes('left')},
          parentRevisionIds: [base.revisionId],
        ),
        repo.commit(
          entityId: id,
          kind: EntityKind.markdown,
          files: {'summary.md': bytes('right')},
          parentRevisionIds: [base.revisionId],
        ),
      ]);
      expect(
        (await repo.heads(id)).map((r) => r.revisionId),
        unorderedEquals(branches.map((r) => r.revisionId)),
      );
      final merge = await repo.commit(
        entityId: id,
        kind: EntityKind.markdown,
        files: {'summary.md': bytes('both')},
        parentRevisionIds: branches.map((r) => r.revisionId).toList(),
      );
      expect((await repo.heads(id)).single.revisionId, merge.revisionId);
      expect(await repo.revisions(), hasLength(4));
    },
  );

  test(
    'failed blob write leaves previous complete revision active after reopen',
    () async {
      final id = newId();
      final base = await repo.commit(
        entityId: id,
        kind: EntityKind.ink,
        files: {'main.sbn2': bytes('old')},
        parentRevisionIds: [],
      );
      final hash = sha256.convert(bytes('new')).toString();
      // A directory occupying the immutable blob destination is a real IO failure.
      await Directory('${repo.root.path}/blobs/$hash').create(recursive: true);
      await expectLater(
        repo.commit(
          entityId: id,
          kind: EntityKind.ink,
          files: {'main.sbn2': bytes('new')},
          parentRevisionIds: [base.revisionId],
        ),
        throwsA(anything),
      );
      await repo.close();
      repo = await NoteRepository.open(repo.root);
      expect((await repo.heads(id)).single.revisionId, base.revisionId);
      expect(utf8.decode((await repo.readFiles(base))['main.sbn2']!), 'old');
    },
  );

  test(
    'imports child before parent persist pending across reopen then activate',
    () async {
      final other = await NoteRepository.open(
        Directory('${temp.path}/other'),
        vaultId: repo.vaultId,
      );
      final id = newId();
      final base = await other.commit(
        entityId: id,
        kind: EntityKind.ink,
        files: {'main.sbn2': bytes('base')},
        parentRevisionIds: [],
      );
      final child = await other.commit(
        entityId: id,
        kind: EntityKind.ink,
        files: {'main.sbn2': bytes('child')},
        parentRevisionIds: [base.revisionId],
      );
      await repo.importRevision(
        child,
        blobsByHash: {child.blobs.values.single.hash: bytes('child')},
      );
      expect(await repo.heads(id), isEmpty);
      await repo.close();
      repo = await NoteRepository.open(repo.root);
      expect(await repo.heads(id), isEmpty);
      await repo.importRevision(
        base,
        blobsByHash: {base.blobs.values.single.hash: bytes('base')},
      );
      await repo.importRevision(child, blobsByHash: {});
      expect((await repo.heads(id)).single.revisionId, child.revisionId);
      expect(await repo.revisions(), hasLength(2));
      await other.close();
    },
  );

  test(
    'hash mismatch and missing attachment never publish a manifest',
    () async {
      final other = await NoteRepository.open(
        Directory('${temp.path}/other'),
        vaultId: repo.vaultId,
      );
      final r = await other.commit(
        entityId: newId(),
        kind: EntityKind.ink,
        files: {'main.sbn2': bytes('ink'), 'assets/image': bytes('image')},
        parentRevisionIds: [],
      );
      await expectLater(
        repo.importRevision(
          r,
          blobsByHash: {
            r.blobs['main.sbn2']!.hash: bytes('corrupt'),
            r.blobs['assets/image']!.hash: bytes('image'),
          },
        ),
        throwsFormatException,
      );
      await expectLater(
        repo.importRevision(
          r,
          blobsByHash: {r.blobs['main.sbn2']!.hash: bytes('ink')},
        ),
        throwsA(anything),
      );
      expect(await repo.revisions(), isEmpty);
      await other.close();
    },
  );

  test(
    'duplicate blobs in one snapshot deduplicate and all logical files reopen',
    () async {
      final r = await repo.commit(
        entityId: newId(),
        kind: EntityKind.ink,
        files: {'main.sbn2': bytes('same'), 'assets/copy': bytes('same')},
        parentRevisionIds: [],
      );
      expect(r.blobs.values.map((b) => b.hash).toSet(), hasLength(1));
      expect(
        await Directory('${repo.root.path}/blobs')
            .list()
            .where((f) => f is File)
            .length,
        1,
      );
      expect(
        (await repo.readFiles(r)).values,
        everyElement(orderedEquals(bytes('same'))),
      );
    },
  );

  test(
    'invalid logical paths and foreign parents cannot mutate repository',
    () async {
      for (final path in [
        '../escape',
        '/absolute',
        r'assets\bad',
        'C:/evil',
        'a/../b',
        'a//b',
      ]) {
        await expectLater(
          repo.commit(
            entityId: newId(),
            kind: EntityKind.ink,
            files: {path: bytes('bad')},
            parentRevisionIds: [],
          ),
          throwsFormatException,
        );
      }
      final r = await repo.commit(
        entityId: newId(),
        kind: EntityKind.ink,
        files: {'main.sbn2': bytes('valid')},
        parentRevisionIds: [],
      );
      await expectLater(
        repo.commit(
          entityId: newId(),
          kind: EntityKind.ink,
          files: {'main.sbn2': bytes('invalid')},
          parentRevisionIds: [r.revisionId],
        ),
        throwsFormatException,
      );
      expect(await repo.revisions(), hasLength(1));
      expect(await File('${temp.path}/escape').exists(), isFalse);
    },
  );

  test(
    'immutable model prevents caller list and map mutation after construction',
    () {
      final parents = <String>[];
      final blobs = <String, BlobRef>{};
      final baseRefs = <String, List<String>>{};
      final r = RevisionRecord(
        vaultId: repo.vaultId,
        entityId: newId(),
        kind: EntityKind.metadata,
        revisionId: newId(),
        parentRevisionIds: parents,
        deviceId: repo.deviceId,
        blobs: blobs,
        baseRefs: baseRefs,
      );
      parents.add(newId());
      blobs['../evil'] = BlobRef(hash: 'a' * 64, length: 1);
      baseRefs[newId()] = [newId()];
      expect(r.parentRevisionIds, isEmpty);
      expect(r.blobs, isEmpty);
      expect(r.baseRefs, isEmpty);
      expect(() => r.parentRevisionIds.add(newId()), throwsUnsupportedError);
      expect(
        () => RevisionRecord.fromJson({...r.toJson(), 'formatVersion': 999}),
        throwsFormatException,
      );
      expect(
        () => RevisionRecord.fromJson({...r.toJson(), 'entityId': '../evil'}),
        throwsFormatException,
      );
    },
  );

  test(
    'note tombstone keeps child payload and offline descendant intact',
    () async {
      final noteId = newId();
      final childId = newId();
      final note = await repo.commit(
        entityId: noteId,
        kind: EntityKind.metadata,
        files: {'note.json': bytes('{"title":"n"}')},
        parentRevisionIds: [],
      );
      final child = await repo.commit(
        entityId: childId,
        kind: EntityKind.markdown,
        ownerNoteId: noteId,
        files: {'summary.md': bytes('before')},
        parentRevisionIds: [],
      );
      final tombstone = await repo.commit(
        entityId: noteId,
        kind: EntityKind.metadata,
        files: {},
        parentRevisionIds: [note.revisionId],
        deleted: true,
        baseRefs: {
          childId: [child.revisionId],
        },
      );
      final offline = await repo.commit(
        entityId: childId,
        kind: EntityKind.markdown,
        ownerNoteId: noteId,
        files: {'summary.md': bytes('offline')},
        parentRevisionIds: [child.revisionId],
      );
      expect((await repo.heads(noteId)).single.deleted, isTrue);
      expect(tombstone.baseRefs[childId], [child.revisionId]);
      expect((await repo.heads(childId)).single.revisionId, offline.revisionId);
      expect(
        utf8.decode((await repo.readFiles(child))['summary.md']!),
        'before',
      );
      expect(
        utf8.decode((await repo.readFiles(offline))['summary.md']!),
        'offline',
      );
    },
  );

  test('truncated newest manifest and abandoned temporary write recover prior generation', () async {
    final id = newId();
    final base = await repo.commit(
      entityId: id,
      kind: EntityKind.ink,
      files: {'main.sbn2': bytes('complete')},
      parentRevisionIds: [],
    );
    final next = await repo.commit(
      entityId: id,
      kind: EntityKind.ink,
      files: {'main.sbn2': bytes('newest')},
      parentRevisionIds: [base.revisionId],
    );
    await repo.close();
    await File('${repo.root.path}/revisions/${next.revisionId}.json')
        .writeAsString('{');
    await File('${repo.root.path}/revisions/abandoned.json.pending.tmp')
        .writeAsString('{');
    repo = await NoteRepository.open(repo.root);
    expect((await repo.heads(id)).single.revisionId, base.revisionId);
    expect(utf8.decode((await repo.readFiles(base))['main.sbn2']!), 'complete');
  });

  test('corrupt newest blob is inactive after restart and verified reimport repairs it', () async {
    final id = newId();
    final base = await repo.commit(
      entityId: id,
      kind: EntityKind.ink,
      files: {'main.sbn2': bytes('old')},
      parentRevisionIds: [],
    );
    final next = await repo.commit(
      entityId: id,
      kind: EntityKind.ink,
      files: {'main.sbn2': bytes('new')},
      parentRevisionIds: [base.revisionId],
    );
    await File('${repo.root.path}/blobs/${next.blobs.values.single.hash}')
        .writeAsString('bad');
    await expectLater(
      repo.readBlob(next.blobs.values.single.hash),
      throwsFormatException,
    );
    await repo.close();
    repo = await NoteRepository.open(repo.root);
    expect((await repo.heads(id)).single.revisionId, base.revisionId);
    await repo.importRevision(
      next,
      blobsByHash: {next.blobs.values.single.hash: bytes('new')},
    );
    expect((await repo.heads(id)).single.revisionId, next.revisionId);
    expect(utf8.decode((await repo.readFiles(next))['main.sbn2']!), 'new');
    expect(repo.integrityIssues, isEmpty);
  });

  test('manifest publish IO failure never acknowledges or exposes imported generation', () async {
    final other = await NoteRepository.open(
      Directory('${temp.path}/other'),
      vaultId: repo.vaultId,
    );
    final r = await other.commit(
      entityId: newId(),
      kind: EntityKind.ink,
      files: {'main.sbn2': bytes('complete')},
      parentRevisionIds: [],
    );
    await Directory('${repo.root.path}/revisions/${r.revisionId}.json')
        .create();
    await expectLater(
      repo.importRevision(
        r,
        blobsByHash: {r.blobs.values.single.hash: bytes('complete')},
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(await repo.revisions(), isEmpty);
    await repo.close();
    repo = await NoteRepository.open(repo.root);
    expect(await repo.revisions(), isEmpty);
    await other.close();
  });

  test('same revision ID with different payload is rejected without overwriting original', () async {
    final id = newId();
    final original = await repo.commit(
      entityId: id,
      kind: EntityKind.markdown,
      files: {'summary.md': bytes('original')},
      parentRevisionIds: [],
    );
    final changed = RevisionRecord.fromJson({
      ...original.toJson(),
      'deleted': true,
    });
    await expectLater(
      repo.importRevision(changed, blobsByHash: {}),
      throwsFormatException,
    );
    expect((await repo.heads(id)).single.deleted, isFalse);
    expect(
      utf8.decode((await repo.readFiles(original))['summary.md']!),
      'original',
    );
  });

  test(
    'reordered duplicate imports converge to one immutable merge revision',
    () async {
      final id = newId();
      final a = await repo.commit(
        entityId: id,
        kind: EntityKind.markdown,
        files: {},
        parentRevisionIds: [],
      );
      final b = await repo.commit(
        entityId: id,
        kind: EntityKind.markdown,
        files: {},
        parentRevisionIds: [],
      );
      final merge = await repo.commit(
        entityId: id,
        kind: EntityKind.markdown,
        files: {},
        parentRevisionIds: [a.revisionId, b.revisionId],
      );
      final reordered = RevisionRecord.fromJson({
        ...merge.toJson(),
        'parentRevisionIds': [b.revisionId, a.revisionId],
      });
      await repo.importRevision(reordered, blobsByHash: {});
      expect(await repo.revisions(), hasLength(3));
      expect((await repo.heads(id)).single.revisionId, merge.revisionId);
    },
  );

  test('unknown local parent and changed kind or owner are rejected', () async {
    final id = newId();
    final owner = newId();
    await expectLater(
      repo.commit(
        entityId: id,
        kind: EntityKind.ink,
        files: {},
        parentRevisionIds: [newId()],
      ),
      throwsFormatException,
    );
    final r = await repo.commit(
      entityId: id,
      kind: EntityKind.ink,
      ownerNoteId: owner,
      files: {},
      parentRevisionIds: [],
    );
    await expectLater(
      repo.commit(
        entityId: id,
        kind: EntityKind.markdown,
        ownerNoteId: owner,
        files: {},
        parentRevisionIds: [r.revisionId],
      ),
      throwsFormatException,
    );
    await expectLater(
      repo.commit(
        entityId: id,
        kind: EntityKind.ink,
        ownerNoteId: newId(),
        files: {},
        parentRevisionIds: [r.revisionId],
      ),
      throwsFormatException,
    );
    expect(await repo.revisions(), hasLength(1));
  });

  test(
    'remote cycle and foreign vault are rejected before writing manifests',
    () async {
      final id = newId();
      final aId = newId();
      final bId = newId();
      final a = RevisionRecord(
        vaultId: repo.vaultId,
        entityId: id,
        kind: EntityKind.ink,
        revisionId: aId,
        parentRevisionIds: [bId],
        deviceId: newId(),
        blobs: {},
      );
      final b = RevisionRecord(
        vaultId: repo.vaultId,
        entityId: id,
        kind: EntityKind.ink,
        revisionId: bId,
        parentRevisionIds: [aId],
        deviceId: newId(),
        blobs: {},
      );
      await repo.importRevision(a, blobsByHash: {});
      await expectLater(
        repo.importRevision(b, blobsByHash: {}),
        throwsFormatException,
      );
      expect(
        await File('${repo.root.path}/revisions/$bId.json').exists(),
        isFalse,
      );
      final foreign = RevisionRecord.fromJson({
        ...a.toJson(),
        'vaultId': newId(),
      });
      await expectLater(
        repo.importRevision(foreign, blobsByHash: {}),
        throwsFormatException,
      );
      expect(await repo.revisions(), isEmpty);
    },
  );

  test('mutable input bytes are captured before queued IO starts', () async {
    final data = bytes('safe');
    final pending = repo.commit(
      entityId: newId(),
      kind: EntityKind.ink,
      files: {'main.sbn2': data},
      parentRevisionIds: [],
    );
    data.fillRange(0, data.length, 0);
    final r = await pending;
    expect(utf8.decode((await repo.readFiles(r))['main.sbn2']!), 'safe');
  });
  test(
    'shared immutable payload IO stays bounded through autosaves and reopen',
    () async {
      final counter = BlobReadCounter();
      await IOOverrides.runWithIOOverrides(() async {
        final entityId = newId();
        final payload = Uint8List(1024 * 1024);
        var parents = <String>[];
        for (var n = 0; n < 5; n++) {
          final revision = await repo.commit(
            entityId: entityId,
            kind: EntityKind.ink,
            files: {
              'original.pdf': payload,
              'main.sbn2': Uint8List.fromList([n]),
            },
            parentRevisionIds: parents,
          );
          parents = [revision.revisionId];
        }
        final pdfPath = '${repo.root.path}/blobs/${sha256.convert(payload)}';
        // Each later autosave may check its existing PDF once, regardless of history.
        expect(counter.reads[pdfPath] ?? 0, lessThanOrEqualTo(4));
        await repo.close();
        counter.reads.clear();
        repo = await NoteRepository.open(repo.root);
        expect(counter.reads[pdfPath], 1);
        expect(await repo.revisions(), hasLength(5));
      }, counter);
    },
  );
  test(
    'explicit file read invalidates a damaged cached payload until repaired',
    () async {
      final revision = await repo.commit(
        entityId: newId(),
        kind: EntityKind.ink,
        files: {'main.sbn2': bytes('valid')},
        parentRevisionIds: [],
      );
      final hash = revision.blobs.values.single.hash;
      await File('${repo.root.path}/blobs/$hash').writeAsString('wrong');
      await expectLater(repo.readFiles(revision), throwsFormatException);
      expect(await repo.revisions(), isEmpty);
      expect(repo.pendingRevisionCount, 1);
      expect(repo.integrityIssues, hasLength(1));
      await repo.importRevision(revision, blobsByHash: {hash: bytes('valid')});
      expect((await repo.revisions()).single.revisionId, revision.revisionId);
      expect(repo.integrityIssues, isEmpty);
    },
  );
  test(
    'verified reimport repairs external damage despite cached hash length',
    () async {
      final revision = await repo.commit(
        entityId: newId(),
        kind: EntityKind.ink,
        files: {'main.sbn2': bytes('valid')},
        parentRevisionIds: [],
      );
      final hash = revision.blobs.values.single.hash;
      await File('${repo.root.path}/blobs/$hash').writeAsString('wrong');
      await repo.importRevision(revision, blobsByHash: {hash: bytes('valid')});
      expect(await repo.readBlob(hash), orderedEquals(bytes('valid')));
      await expectLater(
        repo.importRevision(revision, blobsByHash: {hash: bytes('wrong')}),
        throwsFormatException,
      );
      expect(await repo.readBlob(hash), orderedEquals(bytes('valid')));
    },
  );
}
