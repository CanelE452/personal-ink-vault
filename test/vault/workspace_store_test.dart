import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/vault/workspace_store.dart';

void main() {
  late Directory temp;
  late NoteRepository repo;
  late WorkspaceStore store;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('ink-workspace-');
    repo = await NoteRepository.open(temp);
    store = WorkspaceStore(repo);
  });
  tearDown(() async {
    await repo.close();
    await temp.delete(recursive: true);
  });

  test('Markdown saves branch from opened base after remote arrival', () async {
    final note = await store.create('Study');
    final session = await store.open(note);
    final base = session.markdownParents.single;
    await repo.commit(
      entityId: note.markdownEntityId,
      kind: EntityKind.markdown,
      ownerNoteId: note.id,
      files: {'summary.md': Uint8List.fromList('remote'.codeUnits)},
      parentRevisionIds: [base],
    );
    await session.saveMarkdown('local');
    final heads = await repo.heads(note.markdownEntityId);
    expect(heads, hasLength(2));
    final local = heads.singleWhere(
      (r) => r.revisionId == session.markdownParents.single,
    );
    expect(local.parentRevisionIds, [base]);
    expect(await session.readMarkdown(), 'local');
  });

  test('search includes Markdown and rename preserves note identity', () async {
    final note = await store.create('First');
    final session = await store.open(note);
    await session.saveMarkdown('a rare-token in the source');
    await store.rename(note, 'Renamed');
    final found = await store.search('rare-token');
    expect(found.single.id, note.id);
    expect(found.single.title, 'Renamed');
  });

  test('delete records child bases and restore retains original IDs', () async {
    final note = await store.create('Recover');
    await store.setDeleted(note, true);
    expect(await store.search(''), isEmpty);
    final deleted = (await store.list(includeDeleted: true)).single;
    expect(deleted.revision.baseRefs.keys, contains(note.markdownEntityId));
    await store.setDeleted(deleted, false);
    expect((await store.list()).single.id, note.id);
  });
  test(
    'an offline child edit keeps a deleted note visible for recovery',
    () async {
      final note = await store.create('Keep my edit');
      final offline = await store.open(note);
      await store.setDeleted(note, true);
      await offline.saveMarkdown('arrived after delete');
      final notes = await store.list();
      expect(notes.single.id, note.id);
      expect(notes.single.deletionConflict, isTrue);
    },
  );
  test('explicit Markdown merge includes both heads as parents', () async {
    final note = await store.create('Merge');
    final first = await store.open(note), second = await store.open(note);
    await first.saveMarkdown('alpha');
    await second.saveMarkdown('beta');
    final parents = (await repo.heads(note.markdownEntityId))
        .map((r) => r.revisionId)
        .toSet();
    await first.mergeMarkdown('alpha\nbeta');
    final merged = (await repo.heads(note.markdownEntityId)).single;
    expect(merged.parentRevisionIds.toSet(), parents);
    expect(await first.readMarkdown(), 'alpha\nbeta');
    expect(await repo.revisions(), hasLength(5));
  });
}
