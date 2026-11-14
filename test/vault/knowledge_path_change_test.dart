import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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
    temp = await Directory.systemTemp.createTemp('knowledge-path-change-');
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
      startsWith('$parent${Platform.pathSeparator}knowledge-path-change-'),
    );
    await Directory(actual).delete(recursive: true);
  });

  Future<String> markdown(VaultNote note) async {
    final head = (await repository.heads(note.markdownEntityId)).single;
    return utf8.decode((await repository.readFiles(head))['summary.md']!);
  }

  Future<VaultNote> current(VaultNote note, {bool deleted = false}) async =>
      (await store.list(includeDeleted: deleted))
          .singleWhere((n) => n.id == note.id);

  Future<Set<String>> revisionIds() async =>
      (await repository.revisions()).map((r) => r.revisionId).toSet();

  test('concurrent folder moves keep valid caller branches', () async {
    final folder = await library.createFolder('Course');
    final first = await library.createFolder('First');
    final second = await library.createFolder('Second');

    await library.moveFolder(folder, first.id);
    await library.moveFolder(folder, second.id);

    expect((await repository.heads(folder.id)), hasLength(2));
    final branches = (await library.listFolders()).where(
      (f) => f.id == folder.id,
    );
    expect(branches.map((f) => f.parentId).toSet(), {first.id, second.id});
  });

  test(
    'linkless moves and empty folders work without a common engine',
    () async {
      final folder = await library.createFolder('Empty');
      final destination = await library.createFolder('Destination');
      final note = await store.create('Plain');
      await (await store.open(note)).saveMarkdown('No internal reference.');

      await store.moveNote(note, destination.id);
      await library.renameFolder(folder, 'Renamed');
      final renamed = (await library.listFolders()).singleWhere(
        (f) => f.id == folder.id,
      );
      await library.moveFolder(renamed, destination.id);

      expect((await current(note)).folderId, destination.id);
      expect(await markdown(note), 'No internal reference.');
      expect(
        (await library.listFolders())
            .singleWhere((f) => f.id == folder.id)
            .parentId,
        destination.id,
      );
    },
  );

  test(
    'same destination and same folder title do not publish revisions',
    () async {
      final folder = await library.createFolder('Course');
      final note = await store.create('A', folderId: folder.id);
      final before = await revisionIds();

      await store.moveNote(note, folder.id);
      await library.renameFolder(folder, 'Course');
      await library.moveFolder(folder, null);

      expect(await revisionIds(), before);
    },
  );

  test(
    'linked source move without an engine refuses before metadata changes',
    () async {
      final course = await library.createFolder('Course');
      final other = await library.createFolder('Other');
      final source = await store.create('A', folderId: course.id);
      await store.create('B', folderId: course.id);
      await store.create('B', folderId: other.id);
      await (await store.open(source)).saveMarkdown('[B](B.md)');
      final before = await revisionIds();

      await expectLater(store.moveNote(source, other.id), throwsStateError);

      expect(await revisionIds(), before);
      expect((await current(source)).folderId, course.id);
    },
  );

  group(
    'installed native engine',
    () {
      late InkVaultNative native;
      setUp(() {
        native = InkVaultNative.open(libraryPath: _nativePath);
        store = WorkspaceStore(repository, native: native);
        library = LibraryStore(repository, native: native);
      });

      test('note move pins outbound targets before a destination namesake can capture them', () async {
        final course = await library.createFolder('Course');
        final other = await library.createFolder('Other');
        final source = await store.create('A', folderId: course.id);
        final original = await store.create('B', folderId: course.id);
        final namesake = await store.create('B', folderId: other.id);
        const text =
            '😀 [shown](B.md#%5Eblock "Keep title") [[B#Heading|Keep alias]]';
        await (await store.open(source)).saveMarkdown(text);
        final before = (await repository.heads(source.markdownEntityId)).single;

        await store.moveNote(source, other.id);

        expect(
          await markdown(source),
          '😀 [shown](inkvault://note/${original.id}?view=markdown#%5Eblock "Keep title") [[${original.id}#Heading|Keep alias]]',
        );
        final index = await KnowledgeIndex.build(repository, native);
        expect(
          index.documents[source.id]!.links.map((l) => l.targetId).toSet(),
          {original.id},
        );
        expect(index.backlinks(namesake.id), isEmpty);
        expect(
          (await repository.readFiles(before))['summary.md'],
          _bytes(text),
        );
        expect((await current(source)).folderId, other.id);
      });

      test(
        'note move pins inbound references before the old path is reused',
        () async {
          final course = await library.createFolder('Course');
          final other = await library.createFolder('Other');
          final target = await store.create('B', folderId: course.id);
          final source = await store.create('Outside');
          await (await store.open(source))
              .saveMarkdown('[read](Course/B.md#Heading)');

          await store.moveNote(target, other.id);
          final replacement = await store.create('B', folderId: course.id);

          expect(
            await markdown(source),
            '[read](inkvault://note/${target.id}?view=markdown#Heading)',
          );
          final index = await KnowledgeIndex.build(repository, native);
          expect(index.backlinks(target.id).map((n) => n.id), [source.id]);
          expect(index.backlinks(replacement.id), isEmpty);
        },
      );

      for (final operation in ['rename', 'move']) {
        test(
          'folder $operation pins subtree inbound and outbound links in both directions',
          () async {
            final course = await library.createFolder('Course');
            final child = await library.createFolder(
              'Unit',
              parentId: course.id,
            );
            final other = await library.createFolder('Other');
            final internal = await store.create('A', folderId: child.id);
            final sibling = await store.create('B', folderId: child.id);
            final external = await store.create('Outside');
            await (await store.open(internal)).saveMarkdown(
              '[outside](../../Outside.md#%5Eout) [sibling](B.md)',
            );
            await (await store.open(external))
                .saveMarkdown('[inside](Course/Unit/A.md#Heading)');

            if (operation == 'rename') {
              await library.renameFolder(course, 'Changed');
            } else {
              await library.moveFolder(course, other.id);
            }

            expect(
              await markdown(internal),
              '[outside](inkvault://note/${external.id}?view=markdown#%5Eout) [sibling](inkvault://note/${sibling.id}?view=markdown)',
            );
            expect(
              await markdown(external),
              '[inside](inkvault://note/${internal.id}?view=markdown#Heading)',
            );
            final index = await KnowledgeIndex.build(repository, native);
            expect(index.backlinks(internal.id).map((n) => n.id), [
              external.id,
            ]);
            expect(index.backlinks(external.id).map((n) => n.id), [
              internal.id,
            ]);
          },
        );
      }

      test(
        'folder move pins inbound and relative outbound YAML links',
        () async {
          final course = await library.createFolder('Course');
          final unit = await library.createFolder('Unit', parentId: course.id);
          final archive = await library.createFolder('Archive');
          final reading = await store.createMarkdown('Reading', _bytes(''));
          const internalText =
              '---\nlinks:\n  - \'[reading](../../Reading.md#%5Epage)\'\n---\n';
          const externalText =
              '---\noutline: "[[Course/Unit/Outline#Week|Lecture]]"\n---\n';
          final outline = await store.createMarkdown(
            'Outline',
            _bytes(internalText),
            folderId: unit.id,
          );
          final syllabus = await store.createMarkdown(
            'Syllabus',
            _bytes(externalText),
          );

          await library.moveFolder(course, archive.id);

          expect(
            await markdown(outline),
            internalText.replaceFirst(
              '../../Reading.md#%5Epage',
              'inkvault://note/${reading.id}?view=markdown#%5Epage',
            ),
          );
          expect(
            await markdown(syllabus),
            externalText.replaceFirst('Course/Unit/Outline', outline.id),
          );
          final oldCourse = await library.createFolder('Course');
          final oldUnit = await library.createFolder(
            'Unit',
            parentId: oldCourse.id,
          );
          final replacement = await store.createMarkdown(
            'Outline',
            _bytes(''),
            folderId: oldUnit.id,
          );
          final index = await KnowledgeIndex.build(repository, native);
          expect(index.backlinks(outline.id).map((note) => note.id), [
            syllabus.id,
          ]);
          expect(index.backlinks(reading.id).map((note) => note.id), [
            outline.id,
          ]);
          expect(index.backlinks(replacement.id), isEmpty);
        },
      );

      test('moving a page rewrites typed text while unknown JSON code and extra files stay byte exact', () async {
        final course = await library.createFolder('Course');
        final other = await library.createFolder('Other');
        final target = await store.create('B', folderId: course.id);
        await store.create('B', folderId: other.id);
        final page = await store.create(
          'Page',
          folderId: course.id,
          documentKind: VaultDocumentKind.page,
        );
        final paragraph = newId(), code = newId();
        final original =
            '\uFEFF{ "version":1, "future":18446744073709551617, "blocks":['
            '{"id":"$paragraph","type":"paragraph","text":"😀 [B](B.md)","future":"[[B]]"},'
            '{"id":"$code","type":"code","text":"[[B]]"}], "decimal":1.00e+03 }';
        await (await store.open(page)).saveInk({
          'page.json': _bytes(original),
          'future.bin': Uint8List.fromList([0, 255, 7]),
        });
        final before = (await repository.heads(page.inkEntityId)).single;

        await store.moveNote(page, other.id);

        final head = (await repository.heads(page.inkEntityId)).single;
        final files = await repository.readFiles(head);
        expect(
          files['page.json'],
          _bytes(
            original.replaceFirst(
              '[B](B.md)',
              '[B](inkvault://note/${target.id}?view=markdown)',
            ),
          ),
        );
        expect(files['future.bin'], [0, 255, 7]);
        expect(head.parentRevisionIds, [before.revisionId]);
        expect(
          (await repository.readFiles(before))['page.json'],
          _bytes(original),
        );
      });

      test('unknown active structured reference refuses a path change before any publication', () async {
        final course = await library.createFolder('Course');
        final other = await library.createFolder('Other');
        final target = await store.create('B', folderId: course.id);
        final database = await store.create(
          'Database',
          documentKind: VaultDocumentKind.database,
        );
        final property = newId(), row = newId();
        await (await store.open(database)).saveInk({
          'database.json': _bytes(
            jsonEncode({
              'schemaVersion': 1,
              'id': newId(),
              'properties': [
                {'id': property, 'name': 'Future', 'type': 'select'},
              ],
              'rows': [
                {
                  'id': row,
                  'values': {property: '[B](Course/B.md)'},
                  'body': {'version': 1, 'blocks': []},
                },
              ],
            }),
          ),
        });
        final before = await revisionIds();

        await expectLater(store.moveNote(target, other.id), throwsStateError);

        expect(await revisionIds(), before);
        expect((await current(target)).folderId, course.id);
      });

      test('trash pins the old target before path reuse and restore keeps the same UUID', () async {
        final course = await library.createFolder('Course');
        final target = await store.create('B', folderId: course.id);
        final source = await store.create('Outside');
        await (await store.open(source))
            .saveMarkdown('[read](Course/B.md#Heading)');

        await store.setDeleted(target, true);
        final tombstone = (await repository.heads(target.id)).single;
        final replacement = await store.create('B', folderId: course.id);

        expect(
          await markdown(source),
          '[read](inkvault://note/${target.id}?view=markdown#Heading)',
        );
        final deleted = await current(target, deleted: true);
        await store.setDeleted(deleted, false);
        final restored = (await repository.heads(target.id)).single;
        expect(restored.deleted, isFalse);
        expect(restored.baseRefs, tombstone.baseRefs);
        final index = await KnowledgeIndex.build(repository, native);
        expect(index.backlinks(target.id).map((n) => n.id), [source.id]);
        expect(index.backlinks(replacement.id), isEmpty);
      });

      test('trash records the normalized own body head and keeps original source bytes', () async {
        final course = await library.createFolder('Course');
        final target = await store.createWithSource(
          'A',
          folderId: course.id,
          fileName: 'original.pdf',
          bytes: Uint8List.fromList([37, 80, 68, 70, 0, 255]),
          documentKind: VaultDocumentKind.pdf,
        );
        final peer = await store.create('B', folderId: course.id);
        await (await store.open(target)).saveMarkdown('[peer](B.md)');
        final oldBody = (await repository.heads(target.markdownEntityId))
            .single;
        final original = (await repository.heads(target.sourceEntityId!))
            .single;

        await store.setDeleted(target, true);

        final tombstone = (await repository.heads(target.id)).single;
        final normalized = (await repository.heads(target.markdownEntityId))
            .single;
        expect(
          await markdown(target),
          '[peer](inkvault://note/${peer.id}?view=markdown)',
        );
        expect(normalized.parentRevisionIds, [oldBody.revisionId]);
        expect(tombstone.baseRefs[target.markdownEntityId], [
          normalized.revisionId,
        ]);
        expect(tombstone.baseRefs[target.sourceEntityId!], [
          original.revisionId,
        ]);
        expect(
          tombstone.baseRefs.keys,
          unorderedEquals([target.markdownEntityId, target.sourceEntityId!]),
        );
        expect((await repository.readFiles(original))['original.pdf'], [
          37,
          80,
          68,
          70,
          0,
          255,
        ]);
        expect(
          (await current(target, deleted: true)).deletionConflict,
          isFalse,
        );
      });

      test('folder trash observes rewritten subtree heads without including outside sources', () async {
        final course = await library.createFolder('Course');
        final unit = await library.createFolder('Unit', parentId: course.id);
        final inside = await store.create('A', folderId: unit.id);
        final outside = await store.create('Outside');
        await (await store.open(inside))
            .saveMarkdown('[outside](../../Outside.md)');
        await (await store.open(outside))
            .saveMarkdown('[inside](Course/Unit/A.md)');

        await library.setDeleted(course, true);

        final tombstone = (await repository.heads(course.id)).single;
        final body = (await repository.heads(inside.markdownEntityId)).single;
        expect(
          await markdown(inside),
          '[outside](inkvault://note/${outside.id}?view=markdown)',
        );
        expect(
          await markdown(outside),
          '[inside](inkvault://note/${inside.id}?view=markdown)',
        );
        expect(tombstone.baseRefs[inside.markdownEntityId], [body.revisionId]);
        expect(
          tombstone.baseRefs.keys,
          unorderedEquals([unit.id, inside.id, inside.markdownEntityId]),
        );
        expect(
          (await current(inside, deleted: true)).deletionConflict,
          isFalse,
        );
        final trashed = (await library.listFolders(includeDeleted: true))
            .singleWhere((f) => f.id == course.id);
        await library.setDeleted(trashed, false);
        expect((await current(inside)).id, inside.id);
        expect(
          (await repository.heads(course.id)).single.baseRefs,
          tombstone.baseRefs,
        );
      });

      test('a lost body response resumes the exact prepared move through a new store', () async {
        final course = await library.createFolder('Course');
        final other = await library.createFolder('Other');
        final target = await store.create('B', folderId: course.id);
        final source = await store.create('Outside');
        await (await store.open(source)).saveMarkdown('[read](Course/B.md)');
        final guarded = _PathRepository(repository)
          ..loseResponseFor = EntityKind.markdown;

        await expectLater(
          WorkspaceStore(guarded, native: native).moveNote(target, other.id),
          throwsStateError,
        );

        expect((await current(target)).folderId, course.id);
        final normalized = (await repository.heads(source.markdownEntityId))
            .single;
        await WorkspaceStore(
          guarded,
          native: native,
        ).moveNote(target, other.id);
        expect(
          guarded.attempts
              .where((r) => r.kind == EntityKind.markdown)
              .map((r) => r.revisionId)
              .toSet(),
          {normalized.revisionId},
        );
        expect(
          (await repository.heads(source.markdownEntityId)).single.revisionId,
          normalized.revisionId,
        );
        expect((await current(target)).folderId, other.id);
      });

      test('a lost final move response acknowledges its token with the refreshed note', () async {
        final other = await library.createFolder('Other');
        final target = await store.create('A');
        final guarded = _PathRepository(repository)
          ..loseResponseFor = EntityKind.metadata;

        await expectLater(
          WorkspaceStore(guarded, native: native).moveNote(target, other.id),
          throwsStateError,
        );

        final refreshed = await current(target);
        expect(refreshed.folderId, other.id);
        await WorkspaceStore(
          guarded,
          native: native,
        ).moveNote(refreshed, other.id);
        expect(guarded.attempts.map((r) => r.revisionId).toSet(), {
          refreshed.revision.revisionId,
        });
        expect(
          (await repository.heads(target.id)).single.revisionId,
          refreshed.revision.revisionId,
        );
      });

      test('an external head created after normalization defeats the final path publication', () async {
        final course = await library.createFolder('Course');
        final other = await library.createFolder('Other');
        final target = await store.create('B', folderId: course.id);
        final source = await store.create('Outside');
        await (await store.open(source)).saveMarkdown('[read](Course/B.md)');
        var injected = false;
        final guarded = _PathRepository(repository)
          ..beforeConditional = (prepared) async {
            if (prepared.record.kind == EntityKind.metadata && !injected) {
              injected = true;
              final newcomer = await store.create('Newcomer');
              await (await store.open(newcomer))
                  .saveMarkdown('[new](Course/B.md)');
            }
          };

        await expectLater(
          WorkspaceStore(guarded, native: native).moveNote(target, other.id),
          throwsStateError,
        );

        expect((await current(target)).folderId, course.id);
        expect(
          await markdown(source),
          '[read](inkvault://note/${target.id}?view=markdown)',
        );
        guarded.beforeConditional = null;
        await WorkspaceStore(
          guarded,
          native: native,
        ).moveNote(target, other.id);
        final newcomer = (await store.list()).singleWhere(
          (n) => n.title == 'Newcomer',
        );
        expect(
          await markdown(newcomer),
          '[new](inkvault://note/${target.id}?view=markdown)',
        );
      });

      test('moving a source with a missing internal path refuses instead of resolving it at the destination', () async {
        final course = await library.createFolder('Course');
        final other = await library.createFolder('Other');
        final source = await store.create('A', folderId: course.id);
        await store.create('Only there', folderId: other.id);
        await (await store.open(source))
            .saveMarkdown('[missing](Only%20there.md)');
        final before = await revisionIds();

        await expectLater(store.moveNote(source, other.id), throwsStateError);

        expect(await revisionIds(), before);
        expect((await current(source)).folderId, course.id);
      });

      test(
        'moving a source with an ambiguous wiki target refuses without writing',
        () async {
          final course = await library.createFolder('Course');
          final other = await library.createFolder('Other');
          final third = await library.createFolder('Third');
          final source = await store.create('A', folderId: course.id);
          await store.create('Duplicate', folderId: other.id);
          await store.create('Duplicate', folderId: third.id);
          await (await store.open(source)).saveMarkdown('[[Duplicate]]');
          final before = await revisionIds();

          await expectLater(store.moveNote(source, other.id), throwsStateError);

          expect(await revisionIds(), before);
        },
      );

      test('source validation preserves external code comment prose and stable references to trash', () async {
        final course = await library.createFolder('Course');
        final other = await library.createFolder('Other');
        final deleted = await store.create('Deleted');
        await store.setDeleted(deleted, true);
        final peer = await store.create('B', folderId: course.id);
        final source = await store.create('A', folderId: course.id);
        final text =
            '[peer](B.md) [external](https://example.com/No.md) [mail](mailto:a@example.com)\n'
            '`[[Missing code]]` <!-- [[Missing comment]] --> ordinary No.md prose\n'
            '[[${deleted.id}#Heading|deleted]] [deleted](inkvault://note/${deleted.id}?view=markdown#Heading)';
        await (await store.open(source)).saveMarkdown(text);

        await store.moveNote(source, other.id);

        expect(
          await markdown(source),
          text.replaceFirst(
            '[peer](B.md)',
            '[peer](inkvault://note/${peer.id}?view=markdown)',
          ),
        );
        expect((await current(source)).folderId, other.id);
      });

      test('an unmoved source with an unrelated unresolved reference does not block target movement', () async {
        final other = await library.createFolder('Other');
        final target = await store.create('B');
        final source = await store.create('Source');
        await (await store.open(source))
            .saveMarkdown('[B](B.md) [unrelated](Missing.md)');

        await store.moveNote(target, other.id);

        expect(
          await markdown(source),
          '[B](inkvault://note/${target.id}?view=markdown) [unrelated](Missing.md)',
        );
      });

      test('stale folder moves retain concurrent branches after links are fixed to UUIDs', () async {
        final folder = await library.createFolder('Course');
        final first = await library.createFolder('First');
        final second = await library.createFolder('Second');
        final inside = await store.create('A', folderId: folder.id);
        final outside = await store.create('Outside');
        await (await store.open(outside)).saveMarkdown('[A](Course/A.md)');
        await library.moveFolder(folder, first.id);
        final body = (await repository.heads(outside.markdownEntityId)).single;

        await library.moveFolder(folder, second.id);

        expect((await repository.heads(folder.id)), hasLength(2));
        expect(
          (await library.listFolders())
              .where((f) => f.id == folder.id)
              .map((f) => f.parentId)
              .toSet(),
          {first.id, second.id},
        );
        expect(
          await markdown(outside),
          '[A](inkvault://note/${inside.id}?view=markdown)',
        );
        expect(
          (await repository.heads(outside.markdownEntityId)).single.revisionId,
          body.revisionId,
        );
      });

      for (final kind in [
        VaultDocumentKind.canvas,
        VaultDocumentKind.database,
      ]) {
        test(
          'moving ${kind.name} rewrites typed text and retains unknown JSON and extra bytes',
          () async {
            final course = await library.createFolder('Course');
            final other = await library.createFolder('Other');
            final target = await store.create('B', folderId: course.id);
            await store.create('B', folderId: other.id);
            final source = await store.create(
              'Structured',
              folderId: course.id,
              documentKind: kind,
            );
            final id = newId(), row = newId(), property = newId();
            final raw = kind == VaultDocumentKind.canvas
                ? '{ "nodes":[{"id":"$id","type":"text","text":"[typed](B.md)","x":0,"y":0,"width":280,"height":180,"future":"[[B]]"}],"edges":[],"future":18446744073709551617,"decimal":1.00e+03 }'
                : '{ "schemaVersion":1,"id":"$id","properties":[{"id":"$property","name":"Title","type":"title"}],"rows":[{"id":"$row","values":{"$property":"[typed](B.md)"},"body":{"version":1,"blocks":[]},"future":"[[B]]"}],"views":[],"future":18446744073709551617,"decimal":1.00e+03 }';
            final name = kind == VaultDocumentKind.canvas
                ? 'board.canvas'
                : 'database.json';
            await (await store.open(source)).saveInk({
              name: _bytes(raw),
              'future.bin': Uint8List.fromList([9, 0, 255]),
            });

            await store.moveNote(source, other.id);

            final files = await repository.readFiles(
              (await repository.heads(source.inkEntityId)).single,
            );
            expect(
              files[name],
              _bytes(
                raw.replaceFirst(
                  '[typed](B.md)',
                  '[typed](inkvault://note/${target.id}?view=markdown)',
                ),
              ),
            );
            expect(files['future.bin'], [9, 0, 255]);
          },
        );
      }

      test('restoring after an unobserved child edit refuses to erase the deletion conflict', () async {
        final target = await store.create('A');
        final session = await store.open(target);
        await store.setDeleted(target, true);
        await session.saveMarkdown('Offline child edit');
        final deleted = await current(target, deleted: true);
        expect(deleted.deletionConflict, isTrue);
        final before = await revisionIds();

        await expectLater(store.setDeleted(deleted, false), throwsStateError);

        expect(await revisionIds(), before);
        expect((await repository.heads(target.id)).single.deleted, isTrue);
      });
    },
    skip: File(_nativePath).existsSync() ? false : 'Set INK_VAULT_NATIVE_LIBRARY to the installed common-engine library.',
  );
}

final _nativePath =
    Platform.environment['INK_VAULT_NATIVE_LIBRARY'] ??
    p.absolute('build', 'native', 'windows', 'ink_vault_native.dll');
Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));

class _PathRepository implements NoteRepository {
  new(this.inner);
  final NoteRepository inner;
  EntityKind? loseResponseFor;
  Future<void> Function(PreparedCommit)? beforeConditional;
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
  int get pendingRevisionCount => inner.pendingRevisionCount;
  @override
  List<String> get integrityIssues => inner.integrityIssues;
  @override
  Future<List<RevisionRecord>> revisions() => inner.revisions();
  @override
  Future<List<RevisionRecord>> heads(String id) => inner.heads(id);
  @override
  Future<Map<String, Uint8List>> readFiles(RevisionRecord revision) =>
      inner.readFiles(revision);
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
  Future<RevisionRecord> commit({
    required String entityId,
    required EntityKind kind,
    required Map<String, Uint8List> files,
    required List<String> parentRevisionIds,
    String? ownerNoteId,
    bool deleted = false,
    Map<String, List<String>> baseRefs = const {},
  }) => inner.commit(
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
    await beforeConditional?.call(prepared);
    final result = await inner.commitPreparedIfHeads(
      prepared,
      expectedHeads: expectedHeads,
      expectedRevisionIds: expectedRevisionIds,
      beforePublish: beforePublish,
      allowHistoricalParents: allowHistoricalParents,
    );
    if (loseResponseFor == prepared.record.kind) {
      loseResponseFor = null;
      throw StateError('Lost response after publication');
    }
    return result;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
