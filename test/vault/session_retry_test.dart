import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/vault/workspace_store.dart';

Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));

void main() {
  late Directory directory;
  late NoteRepository repository;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('session-retry-');
    repository = await NoteRepository.open(directory);
  });
  tearDown(() async {
    await repository.close();
    await directory.delete(recursive: true);
  });

  for (final kind in [EntityKind.markdown, EntityKind.ink]) {
    test(
      '$kind retry keeps the exact published revision after a lost response',
      () async {
        final store = WorkspaceStore(repository);
        final note = await store.create('Retry');
        final guarded = _ResponseLossRepository(repository, kind);
        final session = await WorkspaceStore(guarded).open(note);
        Future<void> save(String value) => kind == EntityKind.markdown
            ? session.saveMarkdown(value)
            : session.saveInk({'main.sbn2': _bytes(value)});
        await expectLater(save('first'), throwsStateError);
        final published = guarded.published.single;
        await save('first');
        final entity = kind == EntityKind.markdown
            ? note.markdownEntityId
            : note.inkEntityId;
        expect(
          (await repository.heads(entity)).single.revisionId,
          published.revisionId,
        );
        expect(
          (await repository.revisions()).where((r) => r.entityId == entity),
          hasLength(kind == EntityKind.markdown ? 2 : 1),
        );
        await repository.close();
        repository = await NoteRepository.open(directory);
        expect(
          (await repository.heads(entity)).single.revisionId,
          published.revisionId,
        );
      },
    );

    test(
      '$kind changed input follows the exact pending revision and preserves a remote branch',
      () async {
        final store = WorkspaceStore(repository);
        final note = await store.create('Changed retry');
        final guarded = _ResponseLossRepository(repository, kind);
        final session = await WorkspaceStore(guarded).open(note);
        final originalParents = kind == EntityKind.markdown
            ? List.of(session.markdownParents)
            : List.of(session.inkParents);
        Future<void> save(String value) => kind == EntityKind.markdown
            ? session.saveMarkdown(value)
            : session.saveInk({'main.sbn2': _bytes(value)});
        await expectLater(save('first'), throwsStateError);
        final pending = guarded.published.single;
        final entity = kind == EntityKind.markdown
            ? note.markdownEntityId
            : note.inkEntityId;
        final remote = await repository.commit(
          entityId: entity,
          kind: kind,
          ownerNoteId: note.id,
          parentRevisionIds: originalParents,
          files: {
            kind == EntityKind.markdown ? 'summary.md' : 'main.sbn2': _bytes(
              'remote',
            ),
          },
        );
        await save('second');
        final heads = await repository.heads(entity);
        expect(heads, hasLength(2));
        expect(heads.map((r) => r.revisionId), contains(remote.revisionId));
        final local = heads.singleWhere(
          (r) => r.revisionId != remote.revisionId,
        );
        expect(local.parentRevisionIds, [pending.revisionId]);
        expect(
          utf8.decode(
            (await repository.readFiles(local))[kind == EntityKind.markdown
                ? 'summary.md'
                : 'main.sbn2']!,
          ),
          'second',
        );
      },
    );
  }

  test(
    'concurrent session saves serialize their parents rather than fork',
    () async {
      final note = await WorkspaceStore(repository).create('Concurrent');
      final session = await WorkspaceStore(repository).open(note);
      await Future.wait([
        session.saveMarkdown('first'),
        session.saveMarkdown('second'),
      ]);
      expect(await repository.heads(note.markdownEntityId), hasLength(1));
      expect(await session.readMarkdown(), 'second');
    },
  );

  test(
    'a pre-publication failure retries the exact original attempt',
    () async {
      final note = await WorkspaceStore(repository)
          .create('Before publication');
      final guarded = _ResponseLossRepository(
        repository,
        EntityKind.ink,
        failBefore: true,
      );
      final session = await WorkspaceStore(guarded).open(note);
      await expectLater(
        session.saveInk({'main.sbn2': _bytes('ink')}),
        throwsStateError,
      );
      expect(await repository.heads(note.inkEntityId), isEmpty);
      await session.saveInk({'main.sbn2': _bytes('ink')});
      expect(guarded.attemptedIds, hasLength(2));
      expect(guarded.attemptedIds.toSet(), hasLength(1));
      expect(
        (await repository.heads(note.inkEntityId)).single.revisionId,
        guarded.attemptedIds.first,
      );
    },
  );

  test(
    'caller byte mutation after enqueue does not change the pending snapshot',
    () async {
      final note = await WorkspaceStore(repository).create('Mutable input');
      final guarded = _ResponseLossRepository(repository, EntityKind.ink);
      final session = await WorkspaceStore(guarded).open(note);
      final incoming = _bytes('original ink');
      final files = {'main.sbn2': incoming};
      final saving = session.saveInk(files);
      incoming.fillRange(0, incoming.length, 0);
      files.clear();
      await expectLater(saving, throwsStateError);
      final first = guarded.published.single;
      expect(
        (await repository.readFiles(first))['main.sbn2'],
        _bytes('original ink'),
      );
      await session.saveInk({'main.sbn2': _bytes('original ink')});
      expect(
        (await repository.heads(note.inkEntityId)).single.revisionId,
        first.revisionId,
      );
    },
  );

  test('queued changed input drains a failed predecessor before creating its child', () async {
    final note = await WorkspaceStore(repository).create('Queued retry');
    final guarded = _ResponseLossRepository(repository, EntityKind.markdown);
    final session = await WorkspaceStore(guarded).open(note);
    final first = session.saveMarkdown('first');
    final second = session.saveMarkdown('second');
    await expectLater(first, throwsStateError);
    await second;
    final head = (await repository.heads(note.markdownEntityId)).single;
    expect(head.parentRevisionIds, [guarded.published.single.revisionId]);
    expect(await session.readMarkdown(), 'second');
  });

  test('a pending snapshot resumes after the same vault is reopened', () async {
    final note = await WorkspaceStore(repository).create('Reopen');
    final guarded = _ResponseLossRepository(repository, EntityKind.markdown);
    final session = await WorkspaceStore(guarded).open(note);
    await expectLater(session.saveMarkdown('saved'), throwsStateError);
    final originalId = guarded.published.single.revisionId;
    await repository.close();
    repository = await NoteRepository.open(directory);
    session.repository = repository;
    await session.saveMarkdown('saved');
    expect(
      (await repository.heads(note.markdownEntityId)).single.revisionId,
      originalId,
    );
    expect(await session.readMarkdown(), 'saved');
  });

  test(
    'changing to a cloned vault cannot replay private pending bytes there',
    () async {
      final note = await WorkspaceStore(repository).create('Scope');
      final guarded = _ResponseLossRepository(repository, EntityKind.ink);
      final session = await WorkspaceStore(guarded).open(note);
      await expectLater(
        session.saveInk({'main.sbn2': _bytes('private ink')}),
        throwsStateError,
      );
      final clone = await NoteRepository.open(
        Directory('${directory.path}/clone'),
        vaultId: repository.vaultId,
        deviceId: repository.deviceId,
      );
      try {
        session.repository = clone;
        await expectLater(
          session.saveInk({'main.sbn2': _bytes('private ink')}),
          throwsStateError,
        );
        expect(await clone.revisions(), isEmpty);
        expect(await Directory('${clone.root.path}/blobs').list().length, 0);
        session.repository = guarded;
        await session.saveInk({'main.sbn2': _bytes('private ink')});
        expect(
          (await repository.heads(note.inkEntityId)).single.revisionId,
          guarded.published.single.revisionId,
        );
      } finally {
        await clone.close();
      }
    },
  );

  test('a failed merge retries its exact captured parents and preserves a later remote branch', () async {
    final store = WorkspaceStore(repository);
    final note = await store.create('Merge retry');
    final left = await store.open(note);
    final right = await store.open(note);
    await left.saveMarkdown('left');
    await right.saveMarkdown('right');
    final guarded = _ResponseLossRepository(repository, EntityKind.markdown);
    final session = await WorkspaceStore(guarded).open(note);
    await expectLater(session.mergeMarkdown('both'), throwsStateError);
    final merged = guarded.published.single;
    final remote = await repository.commit(
      entityId: note.markdownEntityId,
      kind: EntityKind.markdown,
      ownerNoteId: note.id,
      files: {'summary.md': _bytes('later remote')},
      parentRevisionIds: [right.markdownParents.single],
    );
    await session.mergeMarkdown('both');
    expect(session.markdownParents, [merged.revisionId]);
    expect(
      (await repository.heads(note.markdownEntityId)).map((r) => r.revisionId),
      unorderedEquals([merged.revisionId, remote.revisionId]),
    );
  });

  test(
    'repository replacement during a commit cannot advance the foreign session',
    () async {
      final note = await WorkspaceStore(repository).create('In-flight scope');
      final guarded = _ResponseLossRepository(repository, EntityKind.ink)
        ..failed = true;
      final session = await WorkspaceStore(guarded).open(note);
      final clone = await NoteRepository.open(
        Directory('${directory.path}/clone'),
        vaultId: repository.vaultId,
        deviceId: repository.deviceId,
      );
      try {
        guarded.afterCommit = (_) => session.repository = clone;
        await expectLater(
          session.saveInk({'main.sbn2': _bytes('private')}),
          throwsStateError,
        );
        final published = (await repository.heads(note.inkEntityId)).single;
        expect(session.inkParents, isEmpty);
        expect(await clone.revisions(), isEmpty);
        guarded.afterCommit = null;
        session.repository = guarded;
        await session.saveInk({'main.sbn2': _bytes('private')});
        expect(session.inkParents, [published.revisionId]);
        expect(
          (await repository.heads(note.inkEntityId)).single.revisionId,
          published.revisionId,
        );
      } finally {
        await clone.close();
      }
    },
  );

  test('a failed resolution reuses the exact chosen revision result', () async {
    final store = WorkspaceStore(repository);
    final note = await store.create('Resolve retry');
    final left = await store.open(note);
    final right = await store.open(note);
    await left.saveInk({'main.sbn2': _bytes('left')});
    await right.saveInk({'main.sbn2': _bytes('right')});
    final chosen = (await repository.heads(note.inkEntityId))
        .singleWhere((r) => r.revisionId == left.inkParents.single);
    final guarded = _ResponseLossRepository(repository, EntityKind.ink);
    final session = await WorkspaceStore(guarded).open(note);
    await expectLater(session.resolve(chosen), throwsStateError);
    final resolved = guarded.published.single;
    await session.resolve(chosen);
    expect(session.inkParents, [resolved.revisionId]);
    expect(
      (await repository.heads(note.inkEntityId)).single.revisionId,
      resolved.revisionId,
    );
    expect((await repository.readFiles(resolved))['main.sbn2'], _bytes('left'));
  });
}

class _ResponseLossRepository implements NoteRepository {
  new(this.inner, this.kind, {this.failBefore = false});
  final NoteRepository inner;
  final EntityKind kind;
  final bool failBefore;
  var failed = false;
  final published = <RevisionRecord>[];
  final attemptedIds = <String>[];
  void Function(RevisionRecord)? afterCommit;
  @override
  Directory get root => inner.root;
  @override
  String get vaultId => inner.vaultId;
  @override
  String get deviceId => inner.deviceId;
  @override
  int get formatVersion => inner.formatVersion;
  @override
  Future<List<RevisionRecord>> heads(String id) => inner.heads(id);
  @override
  Future<List<RevisionRecord>> revisions() => inner.revisions();
  @override
  Future<Map<String, Uint8List>> readFiles(RevisionRecord record) =>
      inner.readFiles(record);
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
    attemptedIds.add(prepared.record.revisionId);
    if (prepared.record.kind == kind && failBefore && !failed) {
      failed = true;
      throw StateError('Synthetic failure before publication');
    }
    final result = await inner.commitPrepared(prepared);
    afterCommit?.call(result);
    if (prepared.record.kind == kind && !failed) {
      failed = true;
      published.add(result);
      throw StateError('Synthetic response lost after publication');
    }
    return result;
  }

  @override
  Future<RevisionRecord> commit({
    required String entityId,
    required EntityKind kind,
    required Map<String, Uint8List> files,
    required List<String> parentRevisionIds,
    String? ownerNoteId,
    bool deleted = false,
    Map<String, List<String>> baseRefs = const {},
  }) => commitPrepared(
    prepareCommit(
      entityId: entityId,
      kind: kind,
      files: files,
      parentRevisionIds: parentRevisionIds,
      ownerNoteId: ownerNoteId,
      deleted: deleted,
      baseRefs: baseRefs,
    ),
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
