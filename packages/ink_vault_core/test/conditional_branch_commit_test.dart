import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:test/test.dart';

Uint8List _bytes(String value) => Uint8List.fromList(utf8.encode(value));

Future<RevisionRecord> _conditionalBranch(
  NoteRepository repository,
  PreparedCommit prepared,
  Map<String, List<String>> heads, {
  List<String>? revisions,
  void Function()? beforePublish,
}) async {
  try {
    return await (repository as dynamic).commitPreparedIfHeads(
      prepared,
      expectedHeads: heads,
      expectedRevisionIds: revisions,
      beforePublish: beforePublish,
      allowHistoricalParents: true,
    ) as RevisionRecord;
  } on NoSuchMethodError {
    throw TestFailure(
      'commitPreparedIfHeads is missing the allowHistoricalParents API',
    );
  }
}

void main() {
  late Directory directory;
  late NoteRepository repository;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('conditional-branch-');
    repository = await NoteRepository.open(directory, createFormatVersion: 2);
  });
  tearDown(() async {
    await repository.close();
    final path = await directory.resolveSymbolicLinks();
    expect(
      path,
      startsWith(
        '${await Directory.systemTemp.resolveSymbolicLinks()}${Platform.pathSeparator}conditional-branch-',
      ),
    );
    await Directory(path).delete(recursive: true);
  });

  PreparedCommit prepare(
    String id,
    String text,
    List<String> parents, {
    EntityKind kind = EntityKind.markdown,
    String? owner,
  }) => repository.prepareCommit(
    entityId: id,
    kind: kind,
    ownerNoteId: owner ?? id,
    files: {'summary.md': _bytes(text)},
    parentRevisionIds: parents,
  );

  Future<RevisionRecord> seed(String id, String text) =>
      repository.commitPrepared(prepare(id, text, []));

  Future<List<String>> snapshot() async => (await repository.revisions())
      .map((record) => record.revisionId)
      .toList();

  Future<void> expectUnpublished(PreparedCommit prepared) async {
    expect(
      await File(
        '${directory.path}/revisions/${prepared.record.revisionId}.json',
      ).exists(),
      false,
    );
    expect(
      await File(
        '${directory.path}/blobs/${prepared.record.blobs.values.single.hash}',
      ).exists(),
      false,
    );
    expect(repository.pendingRevisionCount, 0);
  }

  test('historical publication preserves the captured branch and retries after reopen', () async {
    final id = newId();
    final first = await seed(id, 'original');
    final current = await repository.commitPrepared(
      prepare(id, 'current branch', [first.revisionId]),
    );
    final planned = prepare(id, 'parallel branch', [first.revisionId]);
    final heads = {
      id: [current.revisionId],
    };
    final revisions = [first.revisionId, current.revisionId];

    expect(
      (await _conditionalBranch(
        repository,
        planned,
        heads,
        revisions: revisions,
      )).revisionId,
      planned.record.revisionId,
    );
    expect(
      (await repository.heads(id)).map((record) => record.revisionId),
      unorderedEquals([current.revisionId, planned.record.revisionId]),
    );
    expect(planned.record.parentRevisionIds, [first.revisionId]);
    await repository.close();
    repository = await NoteRepository.open(directory);
    await _conditionalBranch(repository, planned, heads, revisions: revisions);
    await _conditionalBranch(repository, planned, heads, revisions: revisions);
    expect(await repository.revisions(), hasLength(3));
    expect(
      (await repository.heads(id)).map((record) => record.revisionId),
      unorderedEquals([current.revisionId, planned.record.revisionId]),
    );
    expect(
      (await repository.readFiles(current))['summary.md'],
      orderedEquals(_bytes('current branch')),
    );
  });

  test('mixed historical and current parents consume only the captured direct parents', () async {
    final id = newId();
    final first = await seed(id, 'original');
    final left = await repository.commitPrepared(
      prepare(id, 'left branch', [first.revisionId]),
    );
    final right = await repository.commitPrepared(
      prepare(id, 'right branch', [first.revisionId]),
    );
    final planned = prepare(id, 'joined left branch', [
      first.revisionId,
      left.revisionId,
    ]);
    final heads = {
      id: [left.revisionId, right.revisionId],
    };
    final revisions = [first.revisionId, left.revisionId, right.revisionId];

    await _conditionalBranch(repository, planned, heads, revisions: revisions);
    await _conditionalBranch(repository, planned, heads, revisions: revisions);
    expect(
      (await repository.heads(id)).map((record) => record.revisionId),
      unorderedEquals([right.revisionId, planned.record.revisionId]),
    );
    expect(await repository.revisions(), hasLength(4));
  });

  test(
    'the default conditional API still rejects historical parents',
    () async {
      final id = newId();
      final first = await seed(id, 'original');
      final current = await repository.commitPrepared(
        prepare(id, 'current', [first.revisionId]),
      );
      final planned = prepare(id, 'default rejected payload', [
        first.revisionId,
      ]);
      await expectLater(
        repository.commitPreparedIfHeads(
          planned,
          expectedHeads: {
            id: [current.revisionId],
          },
          expectedRevisionIds: [first.revisionId, current.revisionId],
        ),
        throwsFormatException,
      );
      await expectUnpublished(planned);
      expect(
        (await repository.heads(id)).single.revisionId,
        current.revisionId,
      );
    },
  );

  test('historical publication requires a whole snapshot and an explicit nonroot write guard', () async {
    final id = newId(), otherId = newId();
    final first = await seed(id, 'original');
    final current = await repository.commitPrepared(
      prepare(id, 'current', [first.revisionId]),
    );
    final other = await seed(otherId, 'unrelated');
    final planned = prepare(id, 'requires complete conditions', [
      first.revisionId,
    ]);
    final heads = {
      id: [current.revisionId],
    };
    final revisions = [first.revisionId, current.revisionId, other.revisionId];
    await expectLater(
      _conditionalBranch(repository, planned, heads),
      throwsFormatException,
    );
    await expectLater(
      _conditionalBranch(
        repository,
        planned,
        heads,
        revisions: [first.revisionId, current.revisionId],
      ),
      throwsStateError,
    );
    await expectLater(
      _conditionalBranch(repository, planned, {
        otherId: [other.revisionId],
      }, revisions: revisions),
      throwsFormatException,
    );
    final root = prepare(newId(), 'root publication must use normal API', []);
    await expectLater(
      _conditionalBranch(repository, root, {
        root.record.entityId: <String>[],
      }, revisions: revisions),
      throwsFormatException,
    );
    await expectUnpublished(planned);
    await expectUnpublished(root);
    expect(await repository.revisions(), hasLength(3));
  });

  test('unknown foreign kind and owner parents are rejected before payload creation', () async {
    final id = newId(), foreignId = newId();
    final first = await seed(id, 'original');
    final current = await repository.commitPrepared(
      prepare(id, 'current', [first.revisionId]),
    );
    final foreign = await seed(foreignId, 'foreign entity');
    final heads = {
      id: [current.revisionId],
    };
    final revisions = [
      first.revisionId,
      current.revisionId,
      foreign.revisionId,
    ];
    final invalid = [
      prepare(id, 'unknown parent payload', [newId()]),
      prepare(id, 'foreign parent payload', [foreign.revisionId]),
      prepare(id, 'changed kind payload', [
        first.revisionId,
      ], kind: EntityKind.ink),
      prepare(id, 'changed owner payload', [first.revisionId], owner: newId()),
    ];
    for (final planned in invalid) {
      await expectLater(
        _conditionalBranch(repository, planned, heads, revisions: revisions),
        throwsFormatException,
        reason: planned.record.blobs.values.single.hash,
      );
      await expectUnpublished(planned);
    }
    expect(await repository.revisions(), hasLength(3));
    expect((await repository.heads(id)).single.revisionId, current.revisionId);
  });

  test(
    'a queued remote change invalidates the captured historical branch',
    () async {
      final id = newId();
      final first = await seed(id, 'original');
      final current = await repository.commitPrepared(
        prepare(id, 'captured branch', [first.revisionId]),
      );
      final remote = prepare(id, 'queued remote', [current.revisionId]);
      final planned = prepare(id, 'queued stale payload', [first.revisionId]);
      final arriving = repository.commitPrepared(remote);
      final publishing = _conditionalBranch(
        repository,
        planned,
        {
          id: [current.revisionId],
        },
        revisions: [first.revisionId, current.revisionId],
      );
      final rejected = expectLater(publishing, throwsStateError);
      await arriving;
      await rejected;
      await expectUnpublished(planned);
      expect(
        (await repository.heads(id)).single.revisionId,
        remote.record.revisionId,
      );
    },
  );

  test('historical retries reject added branches descendants and unrelated revisions', () async {
    for (final change in ['branch', 'descendant', 'unrelated']) {
      final id = newId();
      final first = await seed(id, 'original $change');
      final current = await repository.commitPrepared(
        prepare(id, 'current $change', [first.revisionId]),
      );
      final planned = prepare(id, 'published $change', [first.revisionId]);
      final heads = {
        id: [current.revisionId],
      };
      final revisions = await snapshot();
      await _conditionalBranch(
        repository,
        planned,
        heads,
        revisions: revisions,
      );
      if (change == 'branch') {
        await repository.commitPrepared(
          prepare(id, 'later remote branch', [first.revisionId]),
        );
      } else if (change == 'descendant') {
        await repository.commitPrepared(
          prepare(id, 'later descendant', [planned.record.revisionId]),
        );
      } else {
        await seed(newId(), 'new source outside captured head map');
      }
      final beforeHeads = (await repository.heads(id))
          .map((record) => record.revisionId)
          .toList();
      final beforeRevisions = await snapshot();
      final manifest = File(
        '${directory.path}/revisions/${planned.record.revisionId}.json',
      );
      final beforeBytes = await manifest.readAsBytes();
      await expectLater(
        _conditionalBranch(repository, planned, heads, revisions: revisions),
        throwsStateError,
        reason: change,
      );
      expect(
        (await repository.heads(id)).map((record) => record.revisionId),
        unorderedEquals(beforeHeads),
        reason: change,
      );
      expect(
        await snapshot(),
        unorderedEquals(beforeRevisions),
        reason: change,
      );
      expect(await manifest.readAsBytes(), beforeBytes, reason: change);
    }
  });

  test(
    'historical publication and exact retries both enforce authorization',
    () async {
      final id = newId();
      final first = await seed(id, 'original');
      final current = await repository.commitPrepared(
        prepare(id, 'current', [first.revisionId]),
      );
      final planned = prepare(id, 'permission guarded branch', [
        first.revisionId,
      ]);
      final heads = {
        id: [current.revisionId],
      };
      final revisions = [first.revisionId, current.revisionId];
      var allowed = true;
      final revoked = StateError('Edit permission was revoked');
      void authorize() {
        if (!allowed) throw revoked;
      }

      final publishing = _conditionalBranch(
        repository,
        planned,
        heads,
        revisions: revisions,
        beforePublish: authorize,
      );
      allowed = false;
      await expectLater(publishing, throwsA(same(revoked)));
      await expectUnpublished(planned);
      allowed = true;
      await _conditionalBranch(
        repository,
        planned,
        heads,
        revisions: revisions,
        beforePublish: authorize,
      );
      allowed = false;
      await expectLater(
        _conditionalBranch(
          repository,
          planned,
          heads,
          revisions: revisions,
          beforePublish: authorize,
        ),
        throwsA(same(revoked)),
      );
      expect(await repository.revisions(), hasLength(3));
      expect(
        (await repository.heads(id)).map((record) => record.revisionId),
        unorderedEquals([current.revisionId, planned.record.revisionId]),
      );
    },
  );

  test(
    'a lost historical manifest response retries the exact published branch',
    () async {
      final id = newId();
      final first = await seed(id, 'original');
      final current = await repository.commitPrepared(
        prepare(id, 'retained branch', [first.revisionId]),
      );
      final planned = prepare(id, 'lost response branch', [first.revisionId]);
      final heads = {
        id: [current.revisionId],
      };
      final revisions = [first.revisionId, current.revisionId];
      final manifest = File(
        '${directory.path}/revisions/${planned.record.revisionId}.json',
      );
      final faults = _ManifestResponseLoss(manifest.path);
      await IOOverrides.runWithIOOverrides(() async {
        await expectLater(
          _conditionalBranch(repository, planned, heads, revisions: revisions),
          throwsA(same(faults.failure)),
        );
        expect(await repository.revisions(), hasLength(2));
        expect(
          (await repository.heads(id)).single.revisionId,
          current.revisionId,
        );
        expect(
          jsonDecode(await manifest.readAsString()),
          planned.record.toJson(),
        );
        await _conditionalBranch(
          repository,
          planned,
          heads,
          revisions: revisions,
        );
      }, faults);
      final publishedBytes = await manifest.readAsBytes();
      await repository.close();
      repository = await NoteRepository.open(directory);
      await _conditionalBranch(
        repository,
        planned,
        heads,
        revisions: revisions,
      );
      expect(await repository.revisions(), hasLength(3));
      expect(
        (await repository.heads(id)).map((record) => record.revisionId),
        unorderedEquals([current.revisionId, planned.record.revisionId]),
      );
      expect(await manifest.readAsBytes(), publishedBytes);
      expect(
        (await repository.readFiles(planned.record))['summary.md'],
        orderedEquals(_bytes('lost response branch')),
      );
    },
  );
}

final class _ManifestResponseLoss extends IOOverrides {
  _ManifestResponseLoss(this.manifestPath);
  final String manifestPath;
  final failure = StateError('Synthetic manifest rename response loss');
  var armed = true;

  @override
  File createFile(String path) {
    final file = super.createFile(path);
    return path.endsWith('.tmp') ? _ManifestResponseFile(file, this) : file;
  }
}

class _ManifestResponseFile implements File {
  _ManifestResponseFile(this.inner, this.faults);
  final File inner;
  final _ManifestResponseLoss faults;

  @override
  String get path => inner.path;

  @override
  Future<File> writeAsBytes(
    List<int> bytes, {
    FileMode mode = FileMode.write,
    bool flush = false,
  }) => inner.writeAsBytes(bytes, mode: mode, flush: flush);

  @override
  Future<File> rename(String newPath) async {
    final result = await inner.rename(newPath);
    if (faults.armed && newPath == faults.manifestPath) {
      faults.armed = false;
      throw faults.failure;
    }
    return result;
  }

  @override
  Future<bool> exists() => inner.exists();

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) =>
      inner.delete(recursive: recursive);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
