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
    temp = await Directory.systemTemp.createTemp('knowledge-path-boundary-');
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
      startsWith('$parent${Platform.pathSeparator}knowledge-path-boundary-'),
    );
    await Directory(actual).delete(recursive: true);
  });
  Future<Set<String>> ids() async =>
      (await repository.revisions()).map((r) => r.revisionId).toSet();
  Future<String> markdown(VaultNote note) async =>
      (await store.open(note)).readMarkdown();

  test(
    'stable UUID md forms pointing into trash move without a common engine',
    () async {
      final destination = await library.createFolder('Other');
      final target = await store.create('Deleted');
      await store.setDeleted(target, true);
      final source = await store.create('Source');
      final text =
          '[[${target.id}.md#Heading|read]] [read](${target.id}.md#Heading)';
      await (await store.open(source)).saveMarkdown(text);
      final body = (await repository.heads(source.markdownEntityId)).single;

      await store.moveNote(source, destination.id);

      expect(await markdown(source), text);
      expect(
        (await repository.heads(source.markdownEntityId)).single.revisionId,
        body.revisionId,
      );
    },
  );

  group(
    'installed native boundaries',
    () {
      late InkVaultNative native;
      setUp(() {
        native = InkVaultNative.open(libraryPath: _nativePath);
        store = WorkspaceStore(repository, native: native);
        library = LibraryStore(repository, native: native);
      });

      for (final action in ['note move', 'folder rename', 'folder move']) {
        test(
          '$action preserves references to the pre-existing destination namesake',
          () async {
            final course = await library.createFolder('Course');
            final other = await library.createFolder('Other');
            final existingFolder = action == 'folder move'
                ? await library.createFolder('Course', parentId: other.id)
                : other;
            final moved = await store.create('A', folderId: course.id);
            final existing = await store.create(
              'A',
              folderId: existingFolder.id,
            );
            final reader = await store.create(
              'Reader',
              folderId: existingFolder.id,
            );
            final outside = await store.create('Outside');
            await (await store.open(reader))
                .saveMarkdown('[existing](A.md#Existing)');
            await (await store.open(outside))
                .saveMarkdown('[moved](Course/A.md#Moved)');

            if (action == 'note move') {
              await store.moveNote(moved, other.id);
            } else if (action == 'folder rename') {
              await library.renameFolder(course, 'Other');
            } else {
              await library.moveFolder(course, other.id);
            }

            expect(
              await markdown(reader),
              '[existing](inkvault://note/${existing.id}?view=markdown#Existing)',
            );
            expect(
              await markdown(outside),
              '[moved](inkvault://note/${moved.id}?view=markdown#Moved)',
            );
            final index = await KnowledgeIndex.build(repository, native);
            expect(index.backlinks(existing.id).map((n) => n.id), [reader.id]);
            expect(index.backlinks(moved.id).map((n) => n.id), [outside.id]);
          },
        );
      }

      test('internal autolinks refuse source movement when the common rewriter cannot preserve them', () async {
        final course = await library.createFolder('Course');
        final other = await library.createFolder('Other');
        final source = await store.create('A', folderId: course.id);
        final original = await store.create('B', folderId: course.id);
        await store.create('B', folderId: other.id);
        await (await store.open(source)).saveMarkdown('<inkwiki:B.md>');
        final index = await KnowledgeIndex.build(repository, native);
        expect(index.documents[source.id]!.links.single.targetId, original.id);
        final before = await ids();

        await expectLater(store.moveNote(source, other.id), throwsStateError);

        expect(await ids(), before);
        expect(
          (await store.list()).singleWhere((n) => n.id == source.id).folderId,
          course.id,
        );
      });

      test('native source validation retains stable UUID md forms pointing into trash', () async {
        final destination = await library.createFolder('Other');
        final target = await store.create('Deleted');
        await store.setDeleted(target, true);
        final source = await store.create('Source');
        final peer = await store.create('Peer');
        final text =
            '[peer](Peer.md) [[${target.id}.md#Heading|read]] [read](${target.id}.md#Heading)';
        await (await store.open(source)).saveMarkdown(text);

        await store.moveNote(source, destination.id);

        expect(
          await markdown(source),
          text.replaceFirst(
            '[peer](Peer.md)',
            '[peer](inkvault://note/${peer.id}?view=markdown)',
          ),
        );
      });

      for (final kind in ['note', 'folder']) {
        test(
          'restore with a stale deleted $kind object rechecks unobserved child heads',
          () async {
            final folder = await library.createFolder('Course');
            final note = await store.create('A', folderId: folder.id);
            final session = await store.open(note);
            VaultNote? deletedNote;
            VaultFolder? deletedFolder;
            if (kind == 'note') {
              await store.setDeleted(note, true);
              deletedNote = (await store.list(includeDeleted: true)).single;
              expect(deletedNote.deletionConflict, isFalse);
            } else {
              await library.setDeleted(folder, true);
              deletedFolder = (await library.listFolders(includeDeleted: true))
                  .single;
              expect(deletedFolder.deletionConflict, isFalse);
            }
            await session.saveMarkdown(
              'Child edit arrived after opening the tombstone',
            );
            final before = await ids();

            if (kind == 'note') {
              await expectLater(
                store.setDeleted(deletedNote!, false),
                throwsStateError,
              );
            } else {
              await expectLater(
                library.setDeleted(deletedFolder!, false),
                throwsStateError,
              );
            }

            expect(await ids(), before);
            expect(
              (await repository.heads(kind == 'note' ? note.id : folder.id))
                  .single
                  .deleted,
              isTrue,
            );
          },
        );
      }
    },
    skip: File(_nativePath).existsSync() ? false : 'Set INK_VAULT_NATIVE_LIBRARY to the installed common-engine library.',
  );
}

final _nativePath =
    Platform.environment['INK_VAULT_NATIVE_LIBRARY'] ??
    p.absolute('build', 'native', 'windows', 'ink_vault_native.dll');
