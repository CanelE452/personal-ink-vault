import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/vault/library_store.dart';
import 'package:saber/data/vault/workspace_store.dart';

void main() {
  late Directory temp;
  late NoteRepository repository;
  late LibraryStore library;
  late WorkspaceStore workspace;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('ink-library-');
    repository = await NoteRepository.open(temp, createFormatVersion: 2);
    library = LibraryStore(repository);
    workspace = WorkspaceStore(repository);
  });
  tearDown(() async {
    await repository.close();
    await temp.delete(recursive: true);
  });

  test(
    'folders and document types survive reopen with stable identities',
    () async {
      final parent = await library.createFolder('University');
      final child = await library.createFolder('Research', parentId: parent.id);
      final note = await workspace.create(
        'Lecture',
        folderId: child.id,
        documentKind: VaultDocumentKind.markdown,
      );
      expect(await repository.heads(note.inkEntityId), isEmpty);
      expect((await workspace.open(note)).markdownHeads, hasLength(1));
      await repository.close();
      repository = await NoteRepository.open(temp);
      library = LibraryStore(repository);
      workspace = WorkspaceStore(repository);
      expect(
        (await library.listFolders()).map((f) => f.id),
        containsAll([parent.id, child.id]),
      );
      final restored = (await workspace.list()).single;
      expect(restored.id, note.id);
      expect(restored.folderId, child.id);
      expect(restored.documentKind, VaultDocumentKind.markdown);
    },
  );

  test(
    'rename move and delete preserve unknown note fields and all payloads',
    () async {
      final folder = await library.createFolder('Destination');
      final note = await workspace.create(
        'Draft',
        documentKind: VaultDocumentKind.office,
      );
      final files = await repository.readFiles(note.revision);
      final json =
          jsonDecode(utf8.decode(files['note.json']!)) as Map<String, dynamic>;
      final custom = await repository.commit(
        entityId: note.id,
        kind: EntityKind.metadata,
        files: {
          ...files,
          'note.json': Uint8List.fromList(
            utf8.encode(
              jsonEncode({
                ...json,
                'office': {'mode': 'edit'},
                'future': [1, 2],
              }),
            ),
          ),
          'preview.bin': Uint8List.fromList([0, 255, 12]),
        },
        parentRevisionIds: [note.revision.revisionId],
      );
      await workspace.rename((await workspace.list()).single, 'Changed');
      await workspace.moveNote((await workspace.list()).single, folder.id);
      await workspace.setDeleted((await workspace.list()).single, true);
      var head = (await repository.heads(note.id)).single;
      expect(head.deleted, isTrue);
      await workspace.rename(
        (await workspace.list(includeDeleted: true)).single,
        'In trash',
      );
      head = (await repository.heads(note.id)).single;
      expect(head.deleted, isTrue);
      final saved = await repository.readFiles(head);
      expect(saved['preview.bin'], [0, 255, 12]);
      final metadata = jsonDecode(utf8.decode(saved['note.json']!));
      expect(metadata['office'], {'mode': 'edit'});
      expect(metadata['future'], [1, 2]);
      expect(metadata['folderId'], folder.id);
      expect(metadata['inkEntityId'], note.inkEntityId);
      expect(
        (await repository.revisions()).map((r) => r.revisionId),
        contains(custom.revisionId),
      );
    },
  );

  test('source attachment retains exact bytes and metadata through document changes', () async {
    final note = await workspace.create(
      'Slides',
      documentKind: VaultDocumentKind.office,
    );
    final imported = await workspace.attachSource(
      note,
      fileName: 'lecture.pptx',
      bytes: Uint8List.fromList([80, 75, 0, 255]),
    );
    expect(imported.sourceEntityId, isNotNull);
    final source = (await repository.heads(imported.sourceEntityId!)).single;
    expect(source.kind, EntityKind.attachment);
    expect(source.ownerNoteId, note.id);
    expect((await repository.readFiles(source))['lecture.pptx'], [
      80,
      75,
      0,
      255,
    ]);
    await workspace.rename(imported, 'Renamed');
    await workspace.setDeleted((await workspace.list()).single, true);
    final deleted = (await workspace.list(includeDeleted: true)).single;
    expect(deleted.sourceEntityId, source.entityId);
    expect(deleted.revision.baseRefs[source.entityId], [source.revisionId]);
    await expectLater(
      workspace.attachSource(
        deleted,
        fileName: 'again.pptx',
        bytes: Uint8List(0),
      ),
      throwsStateError,
    );
  });

  test(
    'folder rename and move preserve unknown metadata and payload files',
    () async {
      final first = await library.createFolder('First');
      final second = await library.createFolder('Second');
      await repository.commit(
        entityId: first.id,
        kind: EntityKind.folder,
        files: {
          'folder.json': Uint8List.fromList(
            utf8.encode(
              jsonEncode({
                'title': first.title,
                'parentId': null,
                'future': {'color': 7},
              }),
            ),
          ),
          'cover.bin': Uint8List.fromList([8, 9]),
        },
        parentRevisionIds: [first.revision.revisionId],
      );
      await library.renameFolder(
        (await library.listFolders()).singleWhere((f) => f.id == first.id),
        'Updated',
      );
      await library.moveFolder(
        (await library.listFolders()).singleWhere((f) => f.id == first.id),
        second.id,
      );
      final moved = (await library.listFolders()).singleWhere(
        (f) => f.id == first.id,
      );
      expect(moved.parentId, second.id);
      final files = await repository.readFiles(moved.revision);
      expect(files['cover.bin'], [8, 9]);
      expect(
        (jsonDecode(utf8.decode(files['folder.json']!)) as Map)['future'],
        {'color': 7},
      );
    },
  );

  test(
    'local folder cycles and missing or deleted destinations are refused',
    () async {
      final root = await library.createFolder('Root');
      final child = await library.createFolder('Child', parentId: root.id);
      await expectLater(
        library.moveFolder(root, child.id),
        throwsFormatException,
      );
      await expectLater(
        library.moveFolder(root, root.id),
        throwsFormatException,
      );
      await expectLater(
        workspace.create('Lost', folderId: newId()),
        throwsFormatException,
      );
      final before = (await repository.revisions()).length;
      await expectLater(
        library.createFolder('Lost', parentId: newId()),
        throwsFormatException,
      );
      expect(await repository.revisions(), hasLength(before));
      await library.setDeleted(child, true);
      await expectLater(
        workspace.create('Lost', folderId: child.id),
        throwsFormatException,
      );
    },
  );

  test('folder trash hides its observed subtree and restoring keeps every revision', () async {
    final root = await library.createFolder('Root');
    final child = await library.createFolder('Child', parentId: root.id);
    final note = await workspace.create('Saved', folderId: child.id);
    await (await workspace.open(note)).saveInk({
      'main.sbn2': Uint8List.fromList([1, 3, 5]),
    });
    final before = await repository.revisions();
    await library.setDeleted(root, true);
    expect(await workspace.list(), isEmpty);
    expect(await library.listFolders(), isEmpty);
    expect((await workspace.list(includeDeleted: true)).single.trashed, isTrue);
    final deleted = (await library.listFolders(includeDeleted: true))
        .singleWhere((f) => f.id == root.id);
    expect(
      deleted.revision.baseRefs.keys,
      containsAll([child.id, note.id, note.inkEntityId, note.markdownEntityId]),
    );
    await library.setDeleted(deleted, false);
    expect((await workspace.list()).single.id, note.id);
    expect(await library.listFolders(), hasLength(2));
    expect(
      (await repository.revisions()).map((r) => r.revisionId),
      containsAll(before.map((r) => r.revisionId)),
    );
  });

  test(
    'an offline child edit remains visible with its deleted parent as conflict',
    () async {
      final root = await library.createFolder('Root');
      final child = await library.createFolder('Child', parentId: root.id);
      final note = await workspace.create('Offline', folderId: child.id);
      final session = await workspace.open(note);
      await library.setDeleted(root, true);
      await session.saveMarkdown('arrived later');
      final visible = (await workspace.list()).single;
      expect(visible.id, note.id);
      expect(visible.deletionConflict, isTrue);
      expect(
        (await library.listFolders())
            .singleWhere((f) => f.id == root.id)
            .deletionConflict,
        isTrue,
      );
      expect(
        (await library.listFolders())
            .singleWhere((f) => f.id == child.id)
            .deletionConflict,
        isTrue,
      );
    },
  );

  test(
    'unobserved child created on another branch survives a folder tombstone',
    () async {
      final root = await library.createFolder('Root');
      final note = await workspace.create('Observed', folderId: root.id);
      final snapshot = await BackupService.exportSnapshot(repository);
      await library.setDeleted(root, true);
      final other = await BackupService.restoreToEmpty(
        snapshot,
        Directory('${temp.path}/other'),
      );
      final offline = await WorkspaceStore(other)
          .create('New offline', folderId: root.id);
      for (final revision in await other.revisions()) {
        final remapped = RevisionRecord.fromJson({
          ...revision.toJson(),
          'vaultId': repository.vaultId,
        });
        await repository.importRevision(
          remapped,
          blobsByHash: {
            for (final ref in revision.blobs.values)
              ref.hash: await other.readBlob(ref.hash),
          },
        );
      }
      await other.close();
      final visible = await workspace.list();
      expect(visible.map((n) => n.id), [offline.id]);
      expect(visible.single.deletionConflict, isTrue);
      expect(
        (await workspace.list(includeDeleted: true))
            .singleWhere((n) => n.id == note.id)
            .trashed,
        isTrue,
      );
    },
  );

  test('concurrent folder move branches are retained instead of timestamp selection', () async {
    final root = await library.createFolder('Root');
    final first = await library.createFolder('A');
    final second = await library.createFolder('B');
    await library.moveFolder(root, first.id);
    await library.moveFolder(root, second.id);
    final branches = (await library.listFolders())
        .where((f) => f.id == root.id)
        .toList();
    expect(branches.map((f) => f.parentId).toSet(), {first.id, second.id});
    expect(await repository.heads(root.id), hasLength(2));
  });

  test(
    'legacy storage remains readable and refuses new v2 folder/type writes',
    () async {
      final legacy = await NoteRepository.open(
        Directory('${temp.path}/legacy'),
      );
      final store = WorkspaceStore(legacy);
      final note = await store.create('Legacy');
      expect(note.documentKind, VaultDocumentKind.handwriting);
      expect(note.folderId, isNull);
      await expectLater(
        LibraryStore(legacy).createFolder('No'),
        throwsFormatException,
      );
      await expectLater(
        store.create('No', documentKind: VaultDocumentKind.markdown),
        throwsFormatException,
      );
      expect(await store.list(), hasLength(1));
      await legacy.close();
    },
  );
}
