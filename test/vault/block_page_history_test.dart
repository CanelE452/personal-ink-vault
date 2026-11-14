import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/vault/block_page_document.dart';
import 'package:saber/data/vault/block_page_history.dart';
import 'package:saber/data/vault/workspace_store.dart';

Uint8List _bytes(Object json) =>
    Uint8List.fromList(utf8.encode(jsonEncode(json)));

BlockPageDocument _page(
  List<Map<String, dynamic>> blocks, {
  Map<String, dynamic> extra = const {},
}) => BlockPageDocument.fromJson({'version': 1, 'blocks': blocks, ...extra});

Map<String, dynamic> _block(
  String id,
  String text, {
  List<Map<String, dynamic>> children = const [],
}) => {'id': id, 'type': 'paragraph', 'text': text, 'children': children};

void main() {
  test(
    'stable IDs distinguish every block field and preserve unknown JSON',
    () {
      final id = newId(), oldLink = newId(), newLink = newId();
      final before = _page(
        [
          {
            ..._block(id, 'Before'),
            'checked': false,
            'collapsed': false,
            'noteId': oldLink,
            'future': {
              'color': 'red',
              'items': [1, 2],
            },
          },
        ],
        extra: {
          'futurePage': {'layout': 'old'},
        },
      );
      final after = _page(
        [
          {
            ..._block(id, 'After'),
            'type': 'todo',
            'checked': true,
            'collapsed': true,
            'noteId': newLink,
            'future': {
              'color': 'blue',
              'items': [2, 1],
            },
          },
        ],
        extra: {
          'futurePage': {'layout': 'new'},
        },
      );
      final diff = BlockPageHistoryDiff.compare(before, after);
      expect(diff.pageMetadataChanged, isTrue);
      final changed = diff.changes.single;
      expect(changed.blockId, id);
      expect(changed.before!.text, 'Before');
      expect(changed.after!.text, 'After');
      expect(
        changed.kinds,
        unorderedEquals([
          BlockPageChangeKind.content,
          BlockPageChangeKind.type,
          BlockPageChangeKind.checked,
          BlockPageChangeKind.collapsed,
          BlockPageChangeKind.link,
          BlockPageChangeKind.unknown,
        ]),
      );
      expect(before.toJson()['futurePage'], {'layout': 'old'});
      expect(after.blocks.single.toJson()['future'], {
        'color': 'blue',
        'items': [2, 1],
      });
    },
  );

  test(
    'unknown objects ignore key order but distinguish list order and absence',
    () {
      final id = newId();
      final before = _page(
        [
          {
            ..._block(id, 'Same'),
            'future': {
              'a': 1,
              'b': [2, 3],
            },
          },
        ],
        extra: {
          'meta': {'a': 1, 'b': 2},
        },
      );
      final reordered = _page(
        [
          {
            ..._block(id, 'Same'),
            'future': {
              'b': [2, 3],
              'a': 1,
            },
          },
        ],
        extra: {
          'meta': {'b': 2, 'a': 1},
        },
      );
      expect(BlockPageHistoryDiff.compare(before, reordered).changes, isEmpty);
      expect(
        BlockPageHistoryDiff.compare(before, reordered).pageMetadataChanged,
        isFalse,
      );
      final missing = _page([_block(id, 'Same')]);
      expect(
        BlockPageHistoryDiff.compare(before, missing).changes.single.kinds,
        {BlockPageChangeKind.unknown},
      );
      final explicitNull = _page([
        {..._block(id, 'Same'), 'future': null},
      ]);
      expect(
        BlockPageHistoryDiff.compare(
          missing,
          explicitNull,
        ).changes.single.kinds,
        {BlockPageChangeKind.unknown},
      );
    },
  );

  test(
    'nested moves retain identities while additions do not move shifted rows',
    () {
      final parent = newId(), child = newId(), next = newId();
      final added = newId(), removed = newId();
      final before = _page([
        _block(parent, 'Parent', children: [_block(child, 'Child')]),
        _block(next, 'Next'),
        _block(removed, 'Removed'),
      ]);
      final after = _page([
        _block(added, 'Added'),
        _block(parent, 'Parent'),
        _block(next, 'Next', children: [_block(child, 'Child')]),
      ]);
      final diff = BlockPageHistoryDiff.compare(before, after);
      expect(
        diff.changes.map((c) => c.blockId),
        unorderedEquals([child, added, removed]),
      );
      final moved = diff.changes.singleWhere((c) => c.blockId == child);
      expect(moved.kinds, {BlockPageChangeKind.moved});
      expect(moved.beforeParentId, parent);
      expect(moved.afterParentId, next);
      expect(moved.beforeIndex, 0);
      expect(moved.afterIndex, 0);
      expect(diff.changes.singleWhere((c) => c.blockId == added).kinds, {
        BlockPageChangeKind.added,
      });
      expect(diff.changes.singleWhere((c) => c.blockId == removed).kinds, {
        BlockPageChangeKind.deleted,
      });
    },
  );

  test('sibling reorder detects a minimal stable-ID move and unchanged descendants', () {
    final a = newId(), b = newId(), c = newId(), child = newId();
    final blocks = [
      _block(a, 'A', children: [_block(child, 'Child')]),
      _block(b, 'B'),
      _block(c, 'C'),
    ];
    final diff = BlockPageHistoryDiff.compare(
      _page(blocks),
      _page([blocks[2], blocks[0], blocks[1]]),
    );
    expect(diff.changes, hasLength(1));
    expect(diff.changes.single.blockId, c);
    expect(diff.changes.single.kinds, {BlockPageChangeKind.moved});
    expect(diff.changes.single.beforeIndex, 2);
    expect(diff.changes.single.afterIndex, 0);
  });

  group('saved revision snapshots', () {
    late Directory directory;
    late NoteRepository repository;
    late WorkspaceStore store;
    late VaultNote note;
    late NoteSession session;
    setUp(() async {
      directory = await Directory.systemTemp.createTemp('block-history-');
      repository = await NoteRepository.open(directory, createFormatVersion: 2);
      store = WorkspaceStore(repository);
      note = await store.create('Page', documentKind: VaultDocumentKind.page);
      session = await store.open(note);
    });
    tearDown(() async {
      await repository.close();
      await directory.delete(recursive: true);
    });

    test('preview reads actual revisions without changing session parents or files', () async {
      final id = newId();
      await session.saveInk({
        'page.json': _bytes(_page([_block(id, 'Old')]).toJson()),
      });
      final old = (await repository.heads(note.inkEntityId)).single;
      await session.saveInk({
        'page.json': _bytes(_page([_block(id, 'Current')]).toJson()),
      });
      final parents = List.of(session.inkParents);
      final markdownParents = List.of(session.markdownParents);
      final before = await repository.revisions();
      final snapshot = await BlockPageHistorySnapshot.read(session);
      expect(snapshot.expectedHeadRevisionIds, parents);
      expect(snapshot.currentRevision.revisionId, parents.single);
      expect(snapshot.revisions.map((r) => r.revisionId), [
        parents.single,
        old.revisionId,
      ]);
      expect((await snapshot.readRevision(old)).blocks.single.text, 'Old');
      final diff = await snapshot.compare(old);
      expect(diff.changes.single.kinds, {BlockPageChangeKind.content});
      expect(diff.changes.single.before!.text, 'Old');
      expect(diff.changes.single.after!.text, 'Current');
      expect(session.inkParents, parents);
      expect(session.markdownParents, markdownParents);
      expect(
        (await repository.revisions()).map((r) => r.toJson()),
        before.map((r) => r.toJson()),
      );
      expect(
        (await repository.readFiles(old))['page.json'],
        _bytes(_page([_block(id, 'Old')]).toJson()),
      );
    });

    test(
      'history keeps merged alternate ancestors and tombstones in graph order',
      () async {
        final id = newId();
        Future<RevisionRecord> commit(
          String text,
          List<String> parents, {
          bool deleted = false,
        }) => repository.commit(
          entityId: note.inkEntityId,
          kind: EntityKind.ink,
          ownerNoteId: note.id,
          files: {
            'page.json': _bytes(_page([_block(id, text)]).toJson()),
          },
          parentRevisionIds: parents,
          deleted: deleted,
        );
        final base = await commit('base', []);
        final left = await commit('left', [base.revisionId]);
        final right = await commit('right', [base.revisionId], deleted: true);
        final merged = await commit('merged', [
          left.revisionId,
          right.revisionId,
        ]);
        final snapshot = await BlockPageHistorySnapshot.read(session);
        expect(snapshot.revisions, hasLength(4));
        final ids = snapshot.revisions.map((r) => r.revisionId).toList();
        expect(ids.first, merged.revisionId);
        expect(ids.last, base.revisionId);
        expect(ids, containsAll([left.revisionId, right.revisionId]));
        await expectLater(snapshot.readRevision(right), throwsFormatException);
      },
    );

    test('foreign entity, forged record, deleted and malformed previews are rejected', () async {
      final id = newId();
      final old = await repository.commit(
        entityId: note.inkEntityId,
        kind: EntityKind.ink,
        ownerNoteId: note.id,
        files: {
          'page.json': _bytes({'version': 9, 'blocks': []}),
        },
        parentRevisionIds: [],
      );
      session.inkParents = [old.revisionId];
      await session.saveInk({
        'page.json': _bytes(_page([_block(id, 'Current')]).toJson()),
      });
      final snapshot = await BlockPageHistorySnapshot.read(session);
      final other = await store.create(
        'Other',
        documentKind: VaultDocumentKind.page,
      );
      final otherSession = await store.open(other);
      await otherSession.saveInk({'page.json': _bytes(_page([]).toJson())});
      await expectLater(
        snapshot.readRevision(
          (await repository.heads(other.inkEntityId)).single,
        ),
        throwsFormatException,
      );
      await expectLater(snapshot.readRevision(old), throwsFormatException);
      final forged = RevisionRecord.fromJson({
        ...snapshot.currentRevision.toJson(),
        'deleted': true,
      });
      await expectLater(snapshot.readRevision(forged), throwsFormatException);
      expect(snapshot.revisions, hasLength(2));
    });

    test('a repository or note switch invalidates captured preview', () async {
      await session.saveInk({'page.json': _bytes(_page([]).toJson())});
      final snapshot = await BlockPageHistorySnapshot.read(session);
      final other = await store.create(
        'Other',
        documentKind: VaultDocumentKind.page,
      );
      session.note = other;
      await expectLater(
        snapshot.readRevision(snapshot.currentRevision),
        throwsStateError,
      );
      session.note = note;
      final clone = await NoteRepository.open(
        Directory('${directory.path}/clone'),
        vaultId: repository.vaultId,
        deviceId: repository.deviceId,
        createFormatVersion: 2,
      );
      try {
        session.repository = clone;
        await expectLater(
          snapshot.readRevision(snapshot.currentRevision),
          throwsStateError,
        );
      } finally {
        session.repository = repository;
        await clone.close();
      }
    });

    test('unsaved, conflicting and invalid current pages cannot establish comparison', () async {
      await expectLater(
        BlockPageHistorySnapshot.read(session),
        throwsStateError,
      );
      await session.saveInk({'page.json': _bytes(_page([]).toJson())});
      await repository.commit(
        entityId: note.inkEntityId,
        kind: EntityKind.ink,
        ownerNoteId: note.id,
        files: {'page.json': _bytes(_page([]).toJson())},
        parentRevisionIds: [],
      );
      await expectLater(
        BlockPageHistorySnapshot.read(session),
        throwsStateError,
      );
    });
  });
}
