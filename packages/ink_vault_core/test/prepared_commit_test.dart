import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:test/test.dart';

Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));

void main() {
  late Directory directory;
  final opened = <NoteRepository>[];
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('prepared-commit-');
  });
  tearDown(() async {
    for (final repository in opened) {
      await repository.close();
    }
    opened.clear();
    await directory.delete(recursive: true);
  });
  Future<NoteRepository> open(
    String name, {
    int format = 1,
    NoteRepository? copy,
  }) async {
    final repository = await NoteRepository.open(
      Directory('${directory.path}/$name'),
      createFormatVersion: format,
      vaultId: copy?.vaultId,
      deviceId: copy?.deviceId,
    );
    opened.add(repository);
    return repository;
  }

  for (final format in [1, 2]) {
    test(
      'format $format prepared identity and snapshot survive mutation and repeated commit',
      () async {
        final repository = await open('vault', format: format);
        final bytes = _bytes('original');
        final files = {'main.sbn2': bytes};
        final parents = <String>[];
        final bases = <String, List<String>>{};
        final prepared = repository.prepareCommit(
          entityId: newId(),
          kind: EntityKind.ink,
          ownerNoteId: newId(),
          files: files,
          parentRevisionIds: parents,
          baseRefs: bases,
        );
        expect(await repository.revisions(), isEmpty);
        expect(
          prepared.matchesFiles({'main.sbn2': _bytes('original')}),
          isTrue,
        );
        bytes.fillRange(0, bytes.length, 0);
        files['other'] = _bytes('later');
        parents.add(newId());
        bases[newId()] = [newId()];
        expect(prepared.matchesFiles(files), isFalse);
        final committed = await repository.commitPrepared(prepared);
        final repeated = await repository.commitPrepared(prepared);
        expect(repeated.revisionId, committed.revisionId);
        expect(repeated.revisionId, prepared.record.revisionId);
        expect(await repository.revisions(), hasLength(1));
        expect(
          (await repository.readFiles(committed))['main.sbn2'],
          _bytes('original'),
        );
        expect(committed.parentRevisionIds, isEmpty);
        expect(committed.baseRefs, isEmpty);
        expect(committed.formatVersion, format);
      },
    );
  }

  test('failure before publication retries the same prepared ID', () async {
    final repository = await open('vault');
    final prepared = repository.prepareCommit(
      entityId: newId(),
      kind: EntityKind.ink,
      files: {'main.sbn2': _bytes('blocked')},
      parentRevisionIds: [],
    );
    final blocked = Directory(
      '${repository.root.path}/blobs/${prepared.record.blobs.values.single.hash}',
    );
    await blocked.create();
    await expectLater(
      repository.commitPrepared(prepared),
      throwsA(isA<FileSystemException>()),
    );
    expect(await repository.revisions(), isEmpty);
    await blocked.delete();
    final result = await repository.commitPrepared(prepared);
    expect(result.revisionId, prepared.record.revisionId);
    expect(await repository.revisions(), hasLength(1));
  });

  test('manifest rename response loss recovers one exact disk revision', () async {
    final repository = await open('vault');
    final prepared = repository.prepareCommit(
      entityId: newId(),
      kind: EntityKind.markdown,
      files: {'summary.md': _bytes('published')},
      parentRevisionIds: [],
    );
    final faults = _AtomicFaults(loseManifestRename: true);
    await IOOverrides.runWithIOOverrides(() async {
      await expectLater(
        repository.commitPrepared(prepared),
        throwsA(isA<StateError>()),
      );
      expect(await repository.revisions(), isEmpty);
      expect(
        await File(
          '${repository.root.path}/revisions/${prepared.record.revisionId}.json',
        ).exists(),
        isTrue,
      );
      final retried = await repository.commitPrepared(prepared);
      expect(retried.revisionId, prepared.record.revisionId);
      expect(await repository.revisions(), hasLength(1));
    }, faults);
    await repository.close();
    final reopened = await open('vault');
    expect(
      (await reopened.heads(prepared.record.entityId)).single.revisionId,
      prepared.record.revisionId,
    );
  });

  test(
    'same prepared token can complete after reopening its own repository',
    () async {
      final repository = await open('vault');
      final prepared = repository.prepareCommit(
        entityId: newId(),
        kind: EntityKind.ink,
        files: {'main.sbn2': _bytes('stable')},
        parentRevisionIds: [],
      );
      await repository.commitPrepared(prepared);
      await repository.close();
      final reopened = await open('vault');
      expect(prepared.belongsTo(reopened), isTrue);
      await reopened.commitPrepared(prepared);
      expect(await reopened.revisions(), hasLength(1));
    },
  );

  test(
    'a cloned vault in another directory cannot consume a prepared token',
    () async {
      final repository = await open('vault');
      final clone = await open('clone', copy: repository);
      final prepared = repository.prepareCommit(
        entityId: newId(),
        kind: EntityKind.ink,
        files: {'main.sbn2': _bytes('private')},
        parentRevisionIds: [],
      );
      expect(prepared.belongsTo(clone), isFalse);
      await expectLater(clone.commitPrepared(prepared), throwsFormatException);
      expect(await clone.revisions(), isEmpty);
      expect(await Directory('${clone.root.path}/blobs').list().length, 0);
    },
  );

  test(
    'a missing cached manifest is restored with the exact prepared identity',
    () async {
      final repository = await open('vault');
      final prepared = repository.prepareCommit(
        entityId: newId(),
        kind: EntityKind.ink,
        files: {'main.sbn2': _bytes('restore')},
        parentRevisionIds: [],
      );
      await repository.commitPrepared(prepared);
      final manifest = File(
        '${repository.root.path}/revisions/${prepared.record.revisionId}.json',
      );
      await manifest.delete();
      expect(await repository.revisions(), hasLength(1));
      await repository.commitPrepared(prepared);
      expect(
        jsonDecode(await manifest.readAsString()),
        prepared.record.toJson(),
      );
      await repository.close();
      final reopened = await open('vault');
      expect(
        (await reopened.heads(prepared.record.entityId)).single.revisionId,
        prepared.record.revisionId,
      );
      expect(
        (await reopened.readFiles(prepared.record))['main.sbn2'],
        _bytes('restore'),
      );
    },
  );

  for (final malformed in [false, true]) {
    test(
      'cached prepared retry preserves ${malformed ? 'malformed' : 'different'} manifest bytes and refuses success',
      () async {
        final repository = await open('vault');
        final prepared = repository.prepareCommit(
          entityId: newId(),
          kind: EntityKind.ink,
          files: {'main.sbn2': _bytes('protected')},
          parentRevisionIds: [],
        );
        await repository.commitPrepared(prepared);
        final manifest = File(
          '${repository.root.path}/revisions/${prepared.record.revisionId}.json',
        );
        final changed = malformed
            ? '{'
            : jsonEncode({...prepared.record.toJson(), 'deviceId': newId()});
        await manifest.writeAsString(changed);
        await expectLater(
          repository.commitPrepared(prepared),
          throwsFormatException,
        );
        expect(await manifest.readAsString(), changed);
        expect(
          (await repository.readFiles(prepared.record))['main.sbn2'],
          _bytes('protected'),
        );
      },
    );
  }

  test('a disk-only collision is preserved rather than overwritten by a retry', () async {
    final repository = await open('vault');
    final prepared = repository.prepareCommit(
      entityId: newId(),
      kind: EntityKind.markdown,
      files: {'summary.md': _bytes('mine')},
      parentRevisionIds: [],
    );
    final other = repository.prepareCommit(
      entityId: prepared.record.entityId,
      kind: EntityKind.markdown,
      files: {'summary.md': _bytes('other')},
      parentRevisionIds: [],
    );
    final collision = RevisionRecord(
      vaultId: repository.vaultId,
      entityId: prepared.record.entityId,
      kind: EntityKind.markdown,
      revisionId: prepared.record.revisionId,
      parentRevisionIds: [],
      deviceId: repository.deviceId,
      blobs: other.record.blobs,
    );
    final manifest = File(
      '${repository.root.path}/revisions/${collision.revisionId}.json',
    );
    final encoded = jsonEncode(collision.toJson());
    await File(
      '${repository.root.path}/blobs/${collision.blobs.values.single.hash}',
    ).writeAsBytes(_bytes('other'));
    await manifest.writeAsString(encoded);
    await expectLater(
      repository.commitPrepared(prepared),
      throwsFormatException,
    );
    expect(await manifest.readAsString(), encoded);
    expect(
      await File(
        '${repository.root.path}/blobs/${prepared.record.blobs.values.single.hash}',
      ).exists(),
      isFalse,
    );
  });

  test(
    'successful atomic rename performs no fallible cleanup afterward',
    () async {
      final repository = await open('vault');
      final faults = _AtomicFaults(failCleanupAfterRename: true);
      await IOOverrides.runWithIOOverrides(() async {
        await repository.commit(
          entityId: newId(),
          kind: EntityKind.ink,
          files: {'main.sbn2': _bytes('valid')},
          parentRevisionIds: [],
        );
      }, faults);
      expect(faults.postRenameChecks, 0);
      expect(await repository.revisions(), hasLength(1));
    },
  );

  test(
    'failed write retains its original error even when cleanup also fails',
    () async {
      final repository = await open('vault');
      final faults = _AtomicFaults(failWriteAndCleanup: true);
      await IOOverrides.runWithIOOverrides(() async {
        await expectLater(
          repository.commit(
            entityId: newId(),
            kind: EntityKind.ink,
            files: {'main.sbn2': _bytes('never published')},
            parentRevisionIds: [],
          ),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'original failure',
              'Synthetic write failure',
            ),
          ),
        );
      }, faults);
      expect(await repository.revisions(), isEmpty);
    },
  );
}

final class _AtomicFaults extends IOOverrides {
  _AtomicFaults({
    this.loseManifestRename = false,
    this.failCleanupAfterRename = false,
    this.failWriteAndCleanup = false,
  });
  bool loseManifestRename;
  final bool failCleanupAfterRename;
  final bool failWriteAndCleanup;
  int postRenameChecks = 0;
  @override
  File createFile(String path) {
    final file = super.createFile(path);
    return path.endsWith('.tmp') ? _FaultFile(file, this) : file;
  }
}

class _FaultFile implements File {
  _FaultFile(this.inner, this.faults);
  final File inner;
  final _AtomicFaults faults;
  bool renamed = false;
  @override
  String get path => inner.path;
  @override
  Future<File> writeAsBytes(
    List<int> bytes, {
    FileMode mode = FileMode.write,
    bool flush = false,
  }) async {
    final result = await inner.writeAsBytes(bytes, mode: mode, flush: flush);
    if (faults.failWriteAndCleanup) throw StateError('Synthetic write failure');
    return result;
  }

  @override
  Future<File> rename(String newPath) async {
    final result = await inner.rename(newPath);
    renamed = true;
    if (faults.loseManifestRename &&
        newPath.replaceAll('\\', '/').contains('/revisions/')) {
      faults.loseManifestRename = false;
      throw StateError('Synthetic manifest rename response loss');
    }
    return result;
  }

  @override
  Future<bool> exists() {
    if (renamed && faults.failCleanupAfterRename) {
      faults.postRenameChecks++;
      return Future.error(StateError('Cleanup called after successful rename'));
    }
    return inner.exists();
  }

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) {
    if (faults.failWriteAndCleanup)
      return Future.error(StateError('Synthetic cleanup failure'));
    return inner.delete(recursive: recursive);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
