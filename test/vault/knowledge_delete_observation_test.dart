import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/native/ink_vault_native.dart';
import 'package:saber/data/vault/knowledge_index.dart';
import 'package:saber/data/vault/library_store.dart';
import 'package:saber/data/vault/workspace_store.dart';

void main() {
  late Directory temp;
  late NoteRepository repository;
  late WorkspaceStore store;
  late LibraryStore library;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp(
      'knowledge-delete-observation-',
    );
    repository = await NoteRepository.open(temp, createFormatVersion: 2);
    store = WorkspaceStore(repository);
    library = LibraryStore(repository);
  });
  tearDown(() async {
    await repository.close();
    final actual = await temp.resolveSymbolicLinks();
    final parent = await Directory.systemTemp.resolveSymbolicLinks();
    expect(
      actual,
      startsWith(
        '$parent${Platform.pathSeparator}knowledge-delete-observation-',
      ),
    );
    await Directory(actual).delete(recursive: true);
  });

  test('repeated note trash observes a late own child head without interpreting its old relative text', () async {
    final note = await store.create('A');
    final peer = await store.create('B');
    final session = await store.open(note);
    await store.setDeleted(note, true);
    final oldTombstone = (await repository.heads(note.id)).single;
    const raw = '[old relative source](B.md#Heading)';
    await session.saveMarkdown(raw);
    final body = (await repository.heads(note.markdownEntityId)).single;
    final conflicted = (await store.list(includeDeleted: true))
        .singleWhere((n) => n.id == note.id);
    expect(conflicted.deletionConflict, isTrue);

    await store.setDeleted(conflicted, true);

    final tombstone = (await repository.heads(note.id)).single;
    expect(tombstone.parentRevisionIds, [oldTombstone.revisionId]);
    expect(tombstone.baseRefs, {
      note.markdownEntityId: [body.revisionId],
    });
    expect(utf8.decode((await repository.readFiles(body))['summary.md']!), raw);
    expect(
      (await repository.heads(note.markdownEntityId)).single.revisionId,
      body.revisionId,
    );
    expect((await store.list()).map((n) => n.id), [peer.id]);
    final observed = (await store.list(includeDeleted: true))
        .singleWhere((n) => n.id == note.id);
    expect(observed.deletionConflict, isFalse);
    final before = (await repository.revisions())
        .map((r) => r.revisionId)
        .toSet();
    await store.setDeleted(observed, true);
    expect(
      (await repository.revisions()).map((r) => r.revisionId).toSet(),
      before,
    );
  });

  test('repeated folder trash observes its latest subtree without changing deleted source bytes', () async {
    final folder = await library.createFolder('Course');
    final child = await library.createFolder('Unit', parentId: folder.id);
    final note = await store.create('A', folderId: child.id);
    await store.create('B');
    final session = await store.open(note);
    await library.setDeleted(folder, true);
    final oldTombstone = (await repository.heads(folder.id)).single;
    const raw = '[old relative source](../../B.md#Heading)';
    await session.saveMarkdown(raw);
    final body = (await repository.heads(note.markdownEntityId)).single;
    final conflicted = (await library.listFolders(includeDeleted: true))
        .singleWhere((f) => f.id == folder.id);
    expect(conflicted.deletionConflict, isTrue);

    await library.setDeleted(conflicted, true);

    final tombstone = (await repository.heads(folder.id)).single;
    expect(tombstone.parentRevisionIds, [oldTombstone.revisionId]);
    expect(tombstone.baseRefs, {
      child.id: [child.revision.revisionId],
      note.id: [note.revision.revisionId],
      note.markdownEntityId: [body.revisionId],
    });
    expect(utf8.decode((await repository.readFiles(body))['summary.md']!), raw);
    expect(
      (await repository.heads(note.markdownEntityId)).single.revisionId,
      body.revisionId,
    );
    expect((await store.list()).map((n) => n.id), isNot(contains(note.id)));
    expect(await library.listFolders(), isEmpty);
    final observed = (await library.listFolders(includeDeleted: true))
        .singleWhere((f) => f.id == folder.id);
    expect(observed.deletionConflict, isFalse);
    final before = (await repository.revisions())
        .map((r) => r.revisionId)
        .toSet();
    await library.setDeleted(observed, true);
    expect(
      (await repository.revisions()).map((r) => r.revisionId).toSet(),
      before,
    );
  });
  group(
    'active inbound links to conflicted tombstones',
    () {
      late InkVaultNative native;
      setUp(() {
        native = InkVaultNative.open(libraryPath: _nativePath);
        store = WorkspaceStore(repository, native: native);
        library = LibraryStore(repository, native: native);
      });

      test('repeated note trash pins a new active inbound link while preserving the deleted own source', () async {
        final target = await store.create('A');
        await store.create('B');
        final oldSession = await store.open(target);
        await store.setDeleted(target, true);
        const ownRaw = '[deleted own source](B.md#Keep)';
        await oldSession.saveMarkdown(ownRaw);
        final ownHead = (await repository.heads(target.markdownEntityId))
            .single;
        final reader = await store.create('Reader');
        await (await store.open(reader)).saveMarkdown('[read](A.md#Heading)');
        final before = await KnowledgeIndex.build(repository, native);
        expect(before.documents[reader.id]!.links.single.targetId, target.id);
        final conflicted = (await store.list(includeDeleted: true))
            .singleWhere((n) => n.id == target.id);

        await store.setDeleted(conflicted, true);
        final replacement = await store.create('A');

        expect(
          await (await store.open(reader)).readMarkdown(),
          '[read](inkvault://note/${target.id}?view=markdown#Heading)',
        );
        expect(
          (await repository.heads(target.markdownEntityId)).single.revisionId,
          ownHead.revisionId,
        );
        expect(
          utf8.decode((await repository.readFiles(ownHead))['summary.md']!),
          ownRaw,
        );
        final tombstone = (await repository.heads(target.id)).single;
        expect(tombstone.baseRefs, {
          target.markdownEntityId: [ownHead.revisionId],
        });
        final after = await KnowledgeIndex.build(repository, native);
        expect(
          after.documents[reader.id]!.links.single.targetId,
          isNot(replacement.id),
        );
      });

      test('repeated folder trash pins external inbound while leaving deleted subtree references unchanged', () async {
        final folder = await library.createFolder('Course');
        final unit = await library.createFolder('Unit', parentId: folder.id);
        final target = await store.create('A', folderId: unit.id);
        final peer = await store.create('B', folderId: unit.id);
        final oldTarget = await store.open(target),
            oldPeer = await store.open(peer);
        await library.setDeleted(folder, true);
        const ownRaw = '[[B#Keep|deleted subtree source]]';
        await oldTarget.saveMarkdown(ownRaw);
        await oldPeer.saveMarkdown('Late peer body');
        final ownHead = (await repository.heads(target.markdownEntityId))
            .single;
        final peerHead = (await repository.heads(peer.markdownEntityId)).single;
        final reader = await store.create('Reader');
        await (await store.open(reader)).saveMarkdown('[[A#Heading|read]]');
        final before = await KnowledgeIndex.build(repository, native);
        expect(before.documents[reader.id]!.links.single.targetId, target.id);
        final conflicted = (await library.listFolders(includeDeleted: true))
            .singleWhere((f) => f.id == folder.id);

        await library.setDeleted(conflicted, true);
        final reusedFolder = await library.createFolder('Course');
        final reusedUnit = await library.createFolder(
          'Unit',
          parentId: reusedFolder.id,
        );
        final replacement = await store.create('A', folderId: reusedUnit.id);

        expect(
          await (await store.open(reader)).readMarkdown(),
          '[[${target.id}#Heading|read]]',
        );
        expect(
          (await repository.heads(target.markdownEntityId)).single.revisionId,
          ownHead.revisionId,
        );
        expect(
          (await repository.heads(peer.markdownEntityId)).single.revisionId,
          peerHead.revisionId,
        );
        expect(
          utf8.decode((await repository.readFiles(ownHead))['summary.md']!),
          ownRaw,
        );
        expect(
          utf8.decode((await repository.readFiles(peerHead))['summary.md']!),
          'Late peer body',
        );
        final tombstone = (await repository.heads(folder.id)).single;
        expect(tombstone.baseRefs[target.markdownEntityId], [
          ownHead.revisionId,
        ]);
        expect(tombstone.baseRefs[peer.markdownEntityId], [
          peerHead.revisionId,
        ]);
        expect(
          tombstone.baseRefs.keys,
          isNot(contains(reader.markdownEntityId)),
        );
        final after = await KnowledgeIndex.build(repository, native);
        expect(
          after.documents[reader.id]!.links.single.targetId,
          isNot(replacement.id),
        );
      });
    },
    skip: File(_nativePath).existsSync() ? false : 'Set INK_VAULT_NATIVE_LIBRARY to the installed common-engine library.',
  );
}

final _nativePath =
    Platform.environment['INK_VAULT_NATIVE_LIBRARY'] ??
    p.absolute('build', 'native', 'windows', 'ink_vault_native.dll');
