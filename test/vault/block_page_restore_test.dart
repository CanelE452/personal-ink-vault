import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/vault/library_store.dart';
import 'package:saber/data/vault/workspace_store.dart';

Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));
Map<String, Uint8List> _page(String id, String text) => {
  'page.json': _bytes(
    jsonEncode({
      'version': 1,
      'futurePage': {'keep': true},
      'blocks': [
        {
          'id': id,
          'type': 'paragraph',
          'text': text,
          'future': [1, 2],
        },
      ],
    }),
  ),
};

void main() {
  late Directory directory;
  late NoteRepository repository;
  late WorkspaceStore store;
  late VaultNote note;
  late NoteSession session;
  late String blockId;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('block-restore-');
    repository = await NoteRepository.open(directory, createFormatVersion: 2);
    store = WorkspaceStore(repository);
    note = await store.create('Page', documentKind: VaultDocumentKind.page);
    session = await store.open(note);
    blockId = newId();
  });
  tearDown(() async {
    await repository.close();
    await directory.delete(recursive: true);
  });

  test('restore appends whole chosen files to the observed head, preserving summary and originals', () async {
    final sourceId = newId(), sourceRevision = newId();
    final oldFiles = {
      ..._page(blockId, 'Old'),
      'assets/old.bin': Uint8List.fromList([0, 255, 3]),
    };
    final old = await repository.commit(
      entityId: note.inkEntityId,
      kind: EntityKind.ink,
      ownerNoteId: note.id,
      files: oldFiles,
      parentRevisionIds: [],
      baseRefs: {
        sourceId: [sourceRevision],
      },
    );
    session.inkParents = [old.revisionId];
    await session.saveInk({
      ..._page(blockId, 'Current'),
      'assets/new.bin': _bytes('new'),
    });
    await session.saveMarkdown('Keep this separate summary');
    final observed = (await repository.heads(note.inkEntityId)).single;
    final summary = (await repository.heads(note.markdownEntityId)).single;
    final count = (await repository.revisions()).length;
    await session.restoreInkRevision(
      old,
      expectedHeadRevisionIds: [observed.revisionId],
    );
    final restored = (await repository.heads(note.inkEntityId)).single;
    expect(restored.revisionId, isNot(old.revisionId));
    expect(restored.revisionId, isNot(observed.revisionId));
    expect(restored.parentRevisionIds, [observed.revisionId]);
    expect(restored.baseRefs, old.baseRefs);
    expect(restored.ownerNoteId, note.id);
    expect(restored.deleted, isFalse);
    expect(await repository.readFiles(restored), oldFiles);
    expect(await repository.readFiles(old), oldFiles);
    expect(
      (await repository.readFiles(observed)).keys,
      contains('assets/new.bin'),
    );
    expect(
      (await repository.heads(note.markdownEntityId)).single.revisionId,
      summary.revisionId,
    );
    expect(await session.readMarkdown(), 'Keep this separate summary');
    expect(session.inkParents, [restored.revisionId]);
    expect((await repository.revisions()).length, count + 1);
  });

  test(
    'stale comparison and ambiguous heads reject without publishing',
    () async {
      await session.saveInk(_page(blockId, 'Old'));
      final chosen = (await repository.heads(note.inkEntityId)).single;
      await session.saveInk(_page(blockId, 'Observed'));
      final observed = session.inkParents.single;
      await session.saveInk(_page(blockId, 'Newer'));
      final count = (await repository.revisions()).length;
      await expectLater(
        session.restoreInkRevision(chosen, expectedHeadRevisionIds: [observed]),
        throwsStateError,
      );
      expect((await repository.revisions()).length, count);
      final current = session.inkParents.single;
      await repository.commit(
        entityId: note.inkEntityId,
        kind: EntityKind.ink,
        ownerNoteId: note.id,
        files: _page(blockId, 'Remote'),
        parentRevisionIds: [observed],
      );
      await expectLater(
        session.restoreInkRevision(chosen, expectedHeadRevisionIds: [current]),
        throwsStateError,
      );
      await expectLater(
        session.restoreInkRevision(
          chosen,
          expectedHeadRevisionIds: [current, observed],
        ),
        throwsStateError,
      );
    },
  );

  test('foreign, forged, deleted, wrong kind and malformed chosen records are refused', () async {
    await session.saveInk(_page(blockId, 'Current'));
    final current = (await repository.heads(note.inkEntityId)).single;
    final other = await store.create(
      'Other',
      documentKind: VaultDocumentKind.page,
    );
    final foreign = await repository.commit(
      entityId: other.inkEntityId,
      kind: EntityKind.ink,
      ownerNoteId: other.id,
      files: _page(blockId, 'Other'),
      parentRevisionIds: [],
    );
    final summary = (await repository.heads(note.markdownEntityId)).single;
    for (final chosen in [
      foreign,
      summary,
      RevisionRecord.fromJson({...current.toJson(), 'ownerNoteId': other.id}),
      RevisionRecord.fromJson({...current.toJson(), 'deleted': true}),
      RevisionRecord.fromJson({...current.toJson(), 'vaultId': newId()}),
    ]) {
      await expectLater(
        session.restoreInkRevision(
          chosen,
          expectedHeadRevisionIds: [current.revisionId],
        ),
        throwsFormatException,
      );
    }
    final malformed = await repository.commit(
      entityId: note.inkEntityId,
      kind: EntityKind.ink,
      ownerNoteId: note.id,
      files: {'page.json': _bytes('{"version":99,"blocks":[]}')},
      parentRevisionIds: [current.revisionId],
    );
    await expectLater(
      session.restoreInkRevision(
        malformed,
        expectedHeadRevisionIds: [malformed.revisionId],
      ),
      throwsFormatException,
    );
  });

  test('non-page session cannot restore block history', () async {
    await session.saveInk(_page(blockId, 'Page'));
    final chosen = (await repository.heads(note.inkEntityId)).single;
    final other = await store.create('Ink');
    final inkSession = await store.open(other);
    await expectLater(
      inkSession.restoreInkRevision(
        chosen,
        expectedHeadRevisionIds: [chosen.revisionId],
      ),
      throwsStateError,
    );
  });

  for (final failBefore in [false, true]) {
    test(
      '${failBefore ? 'pre-publication' : 'publish-then-throw'} retry reuses its exact prepared revision',
      () async {
        await session.saveInk(_page(blockId, 'Old'));
        final chosen = (await repository.heads(note.inkEntityId)).single;
        await session.saveInk(_page(blockId, 'Current'));
        final expected = List.of(session.inkParents);
        final guarded = _RestoreRepository(repository)..failBefore = failBefore;
        session.repository = guarded;
        await expectLater(
          session.restoreInkRevision(chosen, expectedHeadRevisionIds: expected),
          throwsStateError,
        );
        final attempted = guarded.attempts.single.revisionId;
        await session.restoreInkRevision(
          chosen,
          expectedHeadRevisionIds: expected,
        );
        expect(guarded.attempts.map((r) => r.revisionId), [
          attempted,
          if (failBefore) attempted,
        ]);
        expect(
          (await repository.heads(note.inkEntityId)).single.revisionId,
          attempted,
        );
        expect(session.inkParents, [attempted]);
        expect(
          (await repository.revisions()).where(
            (r) => r.entityId == note.inkEntityId,
          ),
          hasLength(3),
        );
      },
    );
  }

  test(
    'a head arriving immediately before conditional publication is preserved',
    () async {
      await session.saveInk(_page(blockId, 'Old'));
      final chosen = (await repository.heads(note.inkEntityId)).single;
      await session.saveInk(_page(blockId, 'Current'));
      final expected = List.of(session.inkParents);
      final guarded = _RestoreRepository(repository)..fail = false;
      guarded.beforePublish = () async {
        guarded.beforePublish = null;
        await repository.commit(
          entityId: note.inkEntityId,
          kind: EntityKind.ink,
          ownerNoteId: note.id,
          files: _page(blockId, 'Arrived'),
          parentRevisionIds: expected,
        );
      };
      session.repository = guarded;
      await expectLater(
        session.restoreInkRevision(chosen, expectedHeadRevisionIds: expected),
        throwsStateError,
      );
      final head = (await repository.heads(note.inkEntityId)).single;
      expect(
        utf8.decode((await repository.readFiles(head))['page.json']!),
        contains('Arrived'),
      );
      expect(
        (await repository.revisions()).where(
          (r) => r.entityId == note.inkEntityId,
        ),
        hasLength(3),
      );
      await session.restoreInkRevision(
        chosen,
        expectedHeadRevisionIds: [head.revisionId],
      );
      expect(
        (await repository.heads(note.inkEntityId)).single.parentRevisionIds,
        [head.revisionId],
      );
    },
  );

  test('a pending restore remains bound to its selection and can recover after a later remote head', () async {
    await session.saveInk(_page(blockId, 'Old'));
    final chosen = (await repository.heads(note.inkEntityId)).single;
    await session.saveInk(_page(blockId, 'Current'));
    final current = (await repository.heads(note.inkEntityId)).single;
    final guarded = _RestoreRepository(repository)..failBefore = true;
    session.repository = guarded;
    await expectLater(
      session.restoreInkRevision(
        chosen,
        expectedHeadRevisionIds: [current.revisionId],
      ),
      throwsStateError,
    );
    await expectLater(
      session.restoreInkRevision(
        current,
        expectedHeadRevisionIds: [current.revisionId],
      ),
      throwsStateError,
    );
    expect(guarded.attempts, hasLength(1));
    final remote = await repository.commit(
      entityId: note.inkEntityId,
      kind: EntityKind.ink,
      ownerNoteId: note.id,
      files: _page(blockId, 'Remote'),
      parentRevisionIds: [current.revisionId],
    );
    await session.restoreInkRevision(
      chosen,
      expectedHeadRevisionIds: [remote.revisionId],
    );
    final restored = (await repository.heads(note.inkEntityId)).single;
    expect(restored.parentRevisionIds, [remote.revisionId]);
    expect(guarded.attempts, hasLength(2));
    expect(guarded.attempts.first.revisionId, isNot(restored.revisionId));
    expect(
      (await repository.revisions()).any(
        (r) => r.revisionId == guarded.attempts.first.revisionId,
      ),
      isFalse,
    );
  });

  group('folder ancestry guards', () {
    late LibraryStore library;
    late VaultFolder ancestor;
    late VaultFolder parent;
    late RevisionRecord chosen;
    late RevisionRecord current;

    setUp(() async {
      library = LibraryStore(repository);
      ancestor = await library.createFolder('Ancestor');
      parent = await library.createFolder('Parent', parentId: ancestor.id);
      await store.moveNote(note, parent.id);
      note = (await store.list()).single;
      session = await store.open(note);
      await session.saveInk(_page(blockId, 'Old'));
      chosen = (await repository.heads(note.inkEntityId)).single;
      await session.saveInk(_page(blockId, 'Current'));
      current = (await repository.heads(note.inkEntityId)).single;
    });

    test(
      'an already trashed ancestor invalidates a stale live page session',
      () async {
        await library.setDeleted(ancestor, true);
        expect(session.note.trashed, isFalse);
        expect((await store.list(includeDeleted: true)).single.trashed, isTrue);
        final count = (await repository.revisions()).length;
        await expectLater(
          session.restoreInkRevision(
            chosen,
            expectedHeadRevisionIds: [current.revisionId],
          ),
          throwsFormatException,
        );
        expect((await repository.revisions()).length, count);
        expect(
          (await repository.heads(note.inkEntityId)).single.revisionId,
          current.revisionId,
        );
      },
    );

    test('ancestor deletion immediately before publication cannot create a restored revision', () async {
      final guarded = _RestoreRepository(repository)..fail = false;
      guarded.beforePublish = () async {
        guarded.beforePublish = null;
        await library.setDeleted(ancestor, true);
      };
      session.repository = guarded;
      await expectLater(
        session.restoreInkRevision(
          chosen,
          expectedHeadRevisionIds: [current.revisionId],
        ),
        throwsStateError,
      );
      expect(
        (await repository.heads(note.inkEntityId)).single.revisionId,
        current.revisionId,
      );
      expect(
        (await repository.revisions()).where(
          (r) => r.entityId == note.inkEntityId,
        ),
        hasLength(2),
      );
      expect((await store.list(includeDeleted: true)).single.trashed, isTrue);
    });

    test(
      'an ancestor move immediately before publication must be compared again',
      () async {
        final destination = await library.createFolder('Destination');
        final guarded = _RestoreRepository(repository)..fail = false;
        guarded.beforePublish = () async {
          guarded.beforePublish = null;
          await library.moveFolder(ancestor, destination.id);
        };
        session.repository = guarded;
        await expectLater(
          session.restoreInkRevision(
            chosen,
            expectedHeadRevisionIds: [current.revisionId],
          ),
          throwsStateError,
        );
        expect(
          (await repository.heads(note.inkEntityId)).single.revisionId,
          current.revisionId,
        );
        await session.restoreInkRevision(
          chosen,
          expectedHeadRevisionIds: [current.revisionId],
        );
        final restored = (await repository.heads(note.inkEntityId)).single;
        expect(restored.parentRevisionIds, [current.revisionId]);
        expect(
          (await repository.revisions()).where(
            (r) => r.entityId == note.inkEntityId,
          ),
          hasLength(3),
        );
      },
    );

    test('ambiguous live folder heads cannot authorize a restore', () async {
      await repository.commit(
        entityId: parent.id,
        kind: EntityKind.folder,
        files: {
          'folder.json': _bytes(
            jsonEncode({
              'title': 'Other parent branch',
              'parentId': ancestor.id,
            }),
          ),
        },
        parentRevisionIds: [],
      );
      expect(await repository.heads(parent.id), hasLength(2));
      await expectLater(
        session.restoreInkRevision(
          chosen,
          expectedHeadRevisionIds: [current.revisionId],
        ),
        throwsStateError,
      );
      expect(
        (await repository.heads(note.inkEntityId)).single.revisionId,
        current.revisionId,
      );
    });
  });
}

class _RestoreRepository implements NoteRepository {
  new(this.inner);
  final NoteRepository inner;
  var fail = true, failBefore = false;
  Future<void> Function()? beforePublish;
  final attempts = <RevisionRecord>[];
  @override
  Directory get root => inner.root;
  @override
  String get vaultId => inner.vaultId;
  @override
  String get deviceId => inner.deviceId;
  @override
  int get formatVersion => inner.formatVersion;
  @override
  Future<List<RevisionRecord>> revisions() => inner.revisions();
  @override
  Future<List<RevisionRecord>> heads(String id) => inner.heads(id);
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
  Future<RevisionRecord> commitPreparedIfHeads(
    PreparedCommit prepared, {
    required Map<String, List<String>> expectedHeads,
    List<String>? expectedRevisionIds,
    void Function()? beforePublish,
    bool allowHistoricalParents = false,
  }) async {
    attempts.add(prepared.record);
    await this.beforePublish?.call();
    if (fail && failBefore) {
      fail = false;
      throw StateError('Before publication');
    }
    final result = await inner.commitPreparedIfHeads(
      prepared,
      expectedHeads: expectedHeads,
      expectedRevisionIds: expectedRevisionIds,
      beforePublish: beforePublish,
      allowHistoricalParents: allowHistoricalParents,
    );
    if (fail) {
      fail = false;
      throw StateError('Published, response lost');
    }
    return result;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
