import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:test/test.dart';

Uint8List bytes(String value) => Uint8List.fromList(utf8.encode(value));

Future<RevisionRecord> conditional(
  NoteRepository repository,
  PreparedCommit prepared,
  Map<String, List<String>> heads, {
  List<String>? revisions,
}) {
  return repository.commitPreparedIfHeads(
    prepared,
    expectedHeads: heads,
    expectedRevisionIds: revisions,
  );
}

void main() {
  late Directory directory;
  late NoteRepository repository;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('conditional-commit-');
    repository = await NoteRepository.open(directory, createFormatVersion: 2);
  });
  tearDown(() async {
    await repository.close();
    final path = await directory.resolveSymbolicLinks();
    expect(
      path,
      startsWith(
        '${await Directory.systemTemp.resolveSymbolicLinks()}${Platform.pathSeparator}conditional-commit-',
      ),
    );
    await Directory(path).delete(recursive: true);
  });

  PreparedCommit prepare(String id, String text, List<String> parents) =>
      repository.prepareCommit(
        entityId: id,
        kind: EntityKind.markdown,
        ownerNoteId: id,
        files: {'summary.md': bytes(text)},
        parentRevisionIds: parents,
      );

  Future<RevisionRecord> seed(String id, String text) =>
      repository.commitPrepared(prepare(id, text, []));

  test(
    'guarded publication refuses a changed write head before creating payloads',
    () async {
      final id = newId();
      final first = await seed(id, 'original');
      final planned = prepare(id, 'planned', [first.revisionId]);
      final remote = await repository.commitPrepared(
        prepare(id, 'remote', [first.revisionId]),
      );
      await expectLater(
        conditional(repository, planned, {
          id: [first.revisionId],
        }),
        throwsStateError,
      );
      expect((await repository.heads(id)).map((record) => record.revisionId), [
        remote.revisionId,
      ]);
      expect(
        await File(
          '${directory.path}/revisions/${planned.record.revisionId}.json',
        ).exists(),
        false,
      );
      expect(
        await File(
          '${directory.path}/blobs/${planned.record.blobs.values.single.hash}',
        ).exists(),
        false,
      );
    },
  );

  test(
    'guarded metadata publication also checks a previously normalized source',
    () async {
      final targetId = newId(), sourceId = newId();
      final target = await seed(targetId, 'old title');
      final source = await seed(sourceId, 'old link');
      final planned = prepare(targetId, 'new title', [target.revisionId]);
      await repository.commitPrepared(
        prepare(sourceId, 'concurrent link', [source.revisionId]),
      );
      await expectLater(
        conditional(repository, planned, {
          targetId: [target.revisionId],
          sourceId: [source.revisionId],
        }),
        throwsStateError,
      );
      expect(
        (await repository.heads(targetId)).single.revisionId,
        target.revisionId,
      );
    },
  );

  test(
    'repository snapshot detects a new source omitted from the head map',
    () async {
      final id = newId();
      final first = await seed(id, 'old');
      final planned = prepare(id, 'new', [first.revisionId]);
      await seed(newId(), 'new inbound link');
      await expectLater(
        conditional(
          repository,
          planned,
          {
            id: [first.revisionId],
          },
          revisions: [first.revisionId],
        ),
        throwsStateError,
      );
      expect((await repository.heads(id)).single.revisionId, first.revisionId);
    },
  );

  test(
    'a queued preceding writer is observed inside the same serial publication',
    () async {
      final id = newId();
      final first = await seed(id, 'old');
      final remote = prepare(id, 'remote', [first.revisionId]);
      final planned = prepare(id, 'planned', [first.revisionId]);
      final arriving = repository.commitPrepared(remote);
      final publishing = conditional(repository, planned, {
        id: [first.revisionId],
      });
      await arriving;
      await expectLater(publishing, throwsStateError);
      expect(
        (await repository.heads(id)).single.revisionId,
        remote.record.revisionId,
      );
    },
  );

  test('guard inputs are copied before the queued callback executes', () async {
    final id = newId();
    final first = await seed(id, 'old');
    final planned = prepare(id, 'new', [first.revisionId]);
    final heads = {
      id: [first.revisionId],
    };
    final revisions = [first.revisionId];
    final publishing = conditional(
      repository,
      planned,
      heads,
      revisions: revisions,
    );
    heads[id]!.clear();
    heads.clear();
    revisions.clear();
    expect((await publishing).revisionId, planned.record.revisionId);
  });

  test('the exact guarded token retries after reopen without adding another version', () async {
    final id = newId();
    final first = await seed(id, 'old');
    final planned = prepare(id, 'new', [first.revisionId]);
    final heads = {
      id: [first.revisionId],
    };
    await conditional(
      repository,
      planned,
      heads,
      revisions: [first.revisionId],
    );
    await repository.close();
    repository = await NoteRepository.open(directory);
    expect(
      (await conditional(
        repository,
        planned,
        heads,
        revisions: [first.revisionId],
      )).revisionId,
      planned.record.revisionId,
    );
    expect(await repository.revisions(), hasLength(2));
  });

  test('a guarded retry cannot ignore an additional remote branch', () async {
    final id = newId();
    final first = await seed(id, 'old');
    final planned = prepare(id, 'new', [first.revisionId]);
    final heads = {
      id: [first.revisionId],
    };
    await conditional(
      repository,
      planned,
      heads,
      revisions: [first.revisionId],
    );
    await repository.commitPrepared(prepare(id, 'remote', [first.revisionId]));
    await expectLater(
      conditional(repository, planned, heads, revisions: [first.revisionId]),
      throwsStateError,
    );
    expect(await repository.heads(id), hasLength(2));
  });

  test(
    'guarding only another entity never authorizes an unguarded target write',
    () async {
      final target = newId(), other = newId();
      final original = await seed(target, 'old');
      final unrelated = await seed(other, 'other');
      final planned = prepare(target, 'new', [original.revisionId]);
      await expectLater(
        conditional(repository, planned, {
          other: [unrelated.revisionId],
        }),
        throwsFormatException,
      );
      expect(
        (await repository.heads(target)).single.revisionId,
        original.revisionId,
      );
    },
  );

  test(
    'authorization is checked when the guarded write reaches the writer queue',
    () async {
      final id = newId();
      final first = await seed(id, 'old');
      final planned = prepare(id, 'new', [first.revisionId]);
      var allowed = true;
      void authorize() {
        if (!allowed) throw StateError('Edit permission was revoked');
      }

      Future<RevisionRecord> publish() {
        return repository.commitPreparedIfHeads(
          planned,
          expectedHeads: {
            id: [first.revisionId],
          },
          beforePublish: authorize,
        );
      }

      final publishing = publish();
      allowed = false;
      await expectLater(publishing, throwsStateError);
      expect((await repository.heads(id)).single.revisionId, first.revisionId);
      expect(
        await File(
          '${directory.path}/revisions/${planned.record.revisionId}.json',
        ).exists(),
        false,
      );
    },
  );

  for (final phase in ['blob', 'manifest']) {
    test(
      'revocation during $phase IO prevents canonical publication and permits retry',
      () async {
        final id = newId();
        final first = await seed(id, 'original');
        final planned = prepare(id, 'authorized replacement', [
          first.revisionId,
        ]);
        final hash = planned.record.blobs.values.single.hash;
        final manifest = File(
          '${directory.path}/revisions/${planned.record.revisionId}.json',
        );
        final barrier = _PublicationWriteBarrier(
          phase == 'blob'
              ? '${directory.path}/blobs/$hash.'
              : '${directory.path}/revisions/${planned.record.revisionId}.json.',
        );
        var allowed = true;
        final revoked = StateError(
          'Edit permission was revoked during file IO',
        );
        void authorize() {
          if (!allowed) throw revoked;
        }

        Future<RevisionRecord> publish() => repository.commitPreparedIfHeads(
          planned,
          expectedHeads: {
            id: [first.revisionId],
          },
          beforePublish: authorize,
        );

        await IOOverrides.runWithIOOverrides(() async {
          final publishing = publish();
          final rejected = expectLater(publishing, throwsA(same(revoked)));
          await barrier.started.future;
          allowed = false;
          barrier.resume.complete();
          await rejected;
          expect(await manifest.exists(), false);
          expect(
            (await repository.heads(id)).single.revisionId,
            first.revisionId,
          );
          expect(await repository.revisions(), hasLength(1));
          expect(repository.pendingRevisionCount, 0);
          expect(
            await File('${directory.path}/blobs/$hash').readAsBytes(),
            orderedEquals(bytes('authorized replacement')),
          );
          allowed = true;
          expect((await publish()).revisionId, planned.record.revisionId);
          expect(
            (await repository.heads(id)).single.revisionId,
            planned.record.revisionId,
          );
          expect(await repository.revisions(), hasLength(2));
        }, barrier);
      },
    );
  }
}

final class _PublicationWriteBarrier extends IOOverrides {
  _PublicationWriteBarrier(this.prefix);
  final String prefix;
  final started = Completer<void>();
  final resume = Completer<void>();
  var intercepted = false;

  @override
  File createFile(String path) {
    final file = super.createFile(path);
    if (!intercepted &&
        path.endsWith('.tmp') &&
        path.replaceAll('\\', '/').startsWith(prefix.replaceAll('\\', '/'))) {
      intercepted = true;
      return _PublicationPendingFile(file, this);
    }
    return file;
  }
}

class _PublicationPendingFile implements File {
  _PublicationPendingFile(this.inner, this.barrier);
  final File inner;
  final _PublicationWriteBarrier barrier;

  @override
  String get path => inner.path;

  @override
  Future<File> writeAsBytes(
    List<int> bytes, {
    FileMode mode = FileMode.write,
    bool flush = false,
  }) async {
    final written = await inner.writeAsBytes(bytes, mode: mode, flush: flush);
    barrier.started.complete();
    await barrier.resume.future;
    return written;
  }

  @override
  Future<File> rename(String newPath) => inner.rename(newPath);

  @override
  Future<bool> exists() => inner.exists();

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) =>
      inner.delete(recursive: recursive);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
