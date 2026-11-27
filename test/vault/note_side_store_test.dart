import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/office/pdf_note_original.dart';
import 'package:saber/data/vault/discussion_anchor.dart';
import 'package:saber/data/vault/discussion_store.dart';
import 'package:saber/data/vault/library_store.dart';
import 'package:saber/data/vault/note_side_store.dart';
import 'package:saber/data/vault/saber_ink_adapter.dart';
import 'package:saber/data/vault/workspace_store.dart';

Uint8List json(Object value) =>
    Uint8List.fromList(utf8.encode(jsonEncode(value)));

/// One attachment of each kind, as the later tasks will write them.
Map<NoteSideKind, Map<String, Uint8List>> sampleFiles() => {
  NoteSideKind.pageMarks: {
    'page-marks.json': json({'schemaVersion': 1, 'favorites': <String>[]}),
  },
  NoteSideKind.quickNote: {
    'quick-note.json': json({'schemaVersion': 1}),
    'quick-note.sbn2': Uint8List.fromList([1, 2, 3]),
  },
  NoteSideKind.recording: {
    'recording.json': json({'schemaVersion': 1, 'name': 'Lecture'}),
    'audio.m4a': Uint8List.fromList(List.generate(32, (i) => i)),
  },
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();
  late Directory temp;
  late NoteRepository repository;
  late WorkspaceStore workspace;
  late NoteSideStore side;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('piv-note-side-');
    repository = await NoteRepository.open(
      Directory('${temp.path}/vault'),
      createFormatVersion: 2,
    );
    workspace = WorkspaceStore(repository);
    side = NoteSideStore(repository);
    await FileManager.init(
      documentsDirectory: '${temp.path}/working',
      shouldWatchRootDirectory: false,
    );
  });
  tearDown(() async {
    await repository.close().timeout(const Duration(seconds: 30));
    await temp.delete(recursive: true);
  });

  Future<Map<NoteSideKind, NoteSideRecord>> writeAll(String noteId) async => {
    for (final entry in sampleFiles().entries)
      entry.key: await side.write(noteId, entry.key, entry.value),
  };

  test('attachments follow rename, move, trash and restore', () async {
    final folder = await LibraryStore(repository).createFolder('Lectures');
    final note = await workspace.create('Physics');
    final written = await writeAll(note.id);

    Future<VaultNote> current() async =>
        (await workspace.list(includeDeleted: true))
            .singleWhere((n) => n.id == note.id);
    await workspace.rename(await current(), 'Physics 2');
    await workspace.moveNote(await current(), folder.id);
    await workspace.setDeleted(await current(), true);
    expect(await workspace.list(), isEmpty);
    await workspace.setDeleted(await current(), false);

    final restored = (await workspace.list()).single;
    expect(restored.id, note.id);
    expect(restored.title, 'Physics 2');
    expect(restored.folderId, folder.id);
    for (final entry in sampleFiles().entries) {
      final found = (await side.list(note.id, entry.key)).single;
      expect(found.entityId, written[entry.key]!.entityId);
      expect(found.revisionId, written[entry.key]!.revisionId);
      expect(found.kind, entry.key);
      expect(found.heads, hasLength(1));
      expect(await side.read(found), entry.value);
    }
  });

  test('old adapter still opens the note', () async {
    final note = await workspace.create('Ink');
    final core = EditorCoreInfo(filePath: '/side-test');
    core.pages.add(EditorPage());
    final session = await workspace.open(note);
    await session.saveInk(await SaberInkAdapter.capture(core, 0));
    core.dispose();
    final inkBefore = (await repository.heads(note.inkEntityId)).single;

    await writeAll(note.id);

    final ink = (await repository.heads(note.inkEntityId)).single;
    expect(ink.revisionId, inkBefore.revisionId);
    expect(ink.blobs.keys, ['main.sbn2']);
    final opened = await SaberInkAdapter.load(repository, ink);
    expect(opened.pages, hasLength(1));
    opened.dispose();
  });

  test('other attachment readers ignore new kinds', () async {
    final pdf = Uint8List.fromList('%PDF-1.7\n%%EOF\n'.codeUnits);
    final pdfNote = await workspace.createWithSource(
      'Report',
      fileName: 'Report.pdf',
      bytes: pdf,
      documentKind: VaultDocumentKind.pdf,
    );
    await writeAll(pdfNote.id);
    final originals = PdfNoteOriginalStore(repository);
    expect(await originals.has(pdfNote), isFalse);
    final hwp = Uint8List.fromList(List.generate(64, (i) => 255 - i));
    await originals.attach(pdfNote, fileName: 'Report.hwp', bytes: hwp);
    expect((await originals.read(pdfNote))!.bytes, hwp);
    // The source PDF and the kept original are not side attachments either.
    for (final kind in NoteSideKind.values) {
      expect(await side.list(pdfNote.id, kind), hasLength(1));
    }

    final page = await workspace.create(
      'Page',
      documentKind: VaultDocumentKind.page,
    );
    final discussions = DiscussionStore(repository);
    await discussions.createThread(
      page: page.revision,
      anchor: DiscussionAnchor.page(pageId: page.id),
      body: 'first',
    );
    await writeAll(page.id);
    expect((await discussions.listThreads(page.id)).single.root.body, 'first');
    final metadata = (await repository.heads(page.id)).single;
    await discussions.createThread(
      page: metadata,
      anchor: DiscussionAnchor.page(pageId: page.id),
      body: 'second',
    );
    expect(await discussions.listThreads(page.id), hasLength(2));
    for (final kind in NoteSideKind.values) {
      expect(await side.list(page.id, kind), hasLength(1));
    }
  });

  test('format 1 vault is unavailable', () async {
    expect(side.available, isTrue);
    final oldRoot = Directory('${temp.path}/old');
    final old = await NoteRepository.open(oldRoot);
    try {
      final oldSide = NoteSideStore(old);
      expect(oldSide.available, isFalse);
      final note = newId();
      expect(await oldSide.list(note, NoteSideKind.pageMarks), isEmpty);
      await expectLater(
        oldSide.write(
          note,
          NoteSideKind.pageMarks,
          sampleFiles()[NoteSideKind.pageMarks]!,
        ),
        throwsStateError,
      );
      expect(await old.revisions(), isEmpty);
    } finally {
      await old.close().timeout(const Duration(seconds: 30));
    }
  });

  test('two heads are both returned', () async {
    final note = await workspace.create('Recorded');
    final first = await side.write(note.id, NoteSideKind.recording, {
      'recording.json': json({'schemaVersion': 1, 'name': 'A'}),
      'audio.m4a': Uint8List.fromList([7, 7]),
    });
    // Two devices rename the same recording while offline.
    final branches = <String>[];
    for (final name in ['B', 'C']) {
      final record = await repository.commit(
        entityId: first.entityId,
        kind: EntityKind.attachment,
        ownerNoteId: note.id,
        files: {
          'recording.json': json({'schemaVersion': 1, 'name': name}),
          'audio.m4a': Uint8List.fromList([7, 7]),
        },
        parentRevisionIds: [first.revisionId],
      );
      branches.add(record.revisionId);
    }

    final found = (await side.list(note.id, NoteSideKind.recording)).single;
    expect(found.entityId, first.entityId);
    expect(found.heads.map((h) => h.revisionId), unorderedEquals(branches));
    expect(branches, contains(found.revisionId));

    // A write based on what was listed takes both seen heads as parents.
    final joined = await side.write(note.id, NoteSideKind.recording, {
      'recording.json': json({'schemaVersion': 1, 'name': 'D'}),
      'audio.m4a': Uint8List.fromList([7, 7]),
    }, base: found);
    expect(joined.entityId, first.entityId);
    final record = (await repository.heads(first.entityId)).single;
    expect(record.revisionId, joined.revisionId);
    expect(record.parentRevisionIds, unorderedEquals(branches));
    final after = (await side.list(note.id, NoteSideKind.recording)).single;
    expect(after.heads.single.revisionId, joined.revisionId);
  });

  test(
    'a deletion mark hides the attachment and keeps its kind file',
    () async {
      final note = await workspace.create('Deleted');
      final written = await writeAll(note.id);
      final recording = written[NoteSideKind.recording]!;

      await side.markDeleted(recording);

      expect(await side.list(note.id, NoteSideKind.recording), isEmpty);
      expect(await side.list(note.id, NoteSideKind.pageMarks), hasLength(1));
      final mark = (await repository.heads(recording.entityId)).single;
      expect(mark.parentRevisionIds, [recording.revisionId]);
      expect(mark.blobs.keys, ['recording.json']);
      final content = jsonDecode(
        utf8.decode((await repository.readFiles(mark))['recording.json']!),
      );
      expect(content, {'schemaVersion': 1, 'deleted': true});
    },
  );

  test('a head that arrives after reading is not buried', () async {
    final note = await workspace.create('Synced');
    await side.write(note.id, NoteSideKind.recording, {
      'recording.json': json({'schemaVersion': 1, 'name': 'A'}),
      'audio.m4a': Uint8List.fromList([5]),
    });
    final seen = (await side.list(note.id, NoteSideKind.recording)).single;
    // Drive sync brings in another device's rename after this device read.
    final arrived = await repository.commit(
      entityId: seen.entityId,
      kind: EntityKind.attachment,
      ownerNoteId: note.id,
      files: {
        'recording.json': json({'schemaVersion': 1, 'name': 'Remote'}),
        'audio.m4a': Uint8List.fromList([5]),
      },
      parentRevisionIds: [seen.revisionId],
    );
    final stale = {
      'recording.json': json({'schemaVersion': 1, 'name': 'Local'}),
      'audio.m4a': Uint8List.fromList([5]),
    };
    await expectLater(
      side.write(note.id, NoteSideKind.recording, stale, base: seen),
      throwsStateError,
    );
    await expectLater(side.markDeleted(seen), throwsStateError);
    expect(
      (await repository.heads(seen.entityId)).single.revisionId,
      arrived.revisionId,
    );

    final fresh = (await side.list(note.id, NoteSideKind.recording)).single;
    final merged = await side.write(
      note.id,
      NoteSideKind.recording,
      stale,
      base: fresh,
    );
    expect((await repository.heads(seen.entityId)).single.parentRevisionIds, [
      arrived.revisionId,
    ]);
    expect(merged.entityId, seen.entityId);
  });

  test('a deletion mark beside a renamed head still hides it', () async {
    final note = await workspace.create('Split delete');
    final first = (await writeAll(note.id))[NoteSideKind.recording]!;
    await side.markDeleted(first);
    // Another device renamed the same recording offline; sync brings it in.
    await repository.commit(
      entityId: first.entityId,
      kind: EntityKind.attachment,
      ownerNoteId: note.id,
      files: {
        'recording.json': json({'schemaVersion': 1, 'name': 'Renamed'}),
        'audio.m4a': Uint8List.fromList(List.generate(32, (i) => i)),
      },
      parentRevisionIds: [first.revisionId],
    );
    expect(await repository.heads(first.entityId), hasLength(2));
    expect(await side.list(note.id, NoteSideKind.recording), isEmpty);
  });

  test('a deleted head hides the attachment even when unreadable', () async {
    final note = await workspace.create('Deleted flag');
    final first = (await writeAll(note.id))[NoteSideKind.recording]!;
    await repository.commit(
      entityId: first.entityId,
      kind: EntityKind.attachment,
      ownerNoteId: note.id,
      files: {
        'recording.json': json({'schemaVersion': 1, 'name': 'Renamed'}),
        'audio.m4a': Uint8List.fromList(List.generate(32, (i) => i)),
      },
      parentRevisionIds: [first.revisionId],
    );
    final deleted = await repository.commit(
      entityId: first.entityId,
      kind: EntityKind.attachment,
      ownerNoteId: note.id,
      files: {
        'recording.json': json({'schemaVersion': 1, 'gone': 'flag'}),
      },
      parentRevisionIds: [first.revisionId],
      deleted: true,
    );
    final hash = deleted.blobs['recording.json']!.hash;
    await File('${temp.path}/vault/blobs/$hash').delete();
    expect(await side.list(note.id, NoteSideKind.recording), isEmpty);
  });

  test('the note head is guarded until the commit', () async {
    final note = await workspace.create('Guarded');
    final seen = (await writeAll(note.id))[NoteSideKind.pageMarks]!;
    // A rename between reading and writing is fine: write reads the note head itself.
    await workspace.rename((await workspace.list()).single, 'Renamed once');
    final next = await side.write(
      note.id,
      NoteSideKind.pageMarks,
      sampleFiles()[NoteSideKind.pageMarks]!,
      base: seen,
    );
    // A rename after write has read the note head fails the commit.
    side.beforeCommit = () async =>
        workspace.rename((await workspace.list()).single, 'Renamed twice');
    final before = (await repository.revisions()).length;
    await expectLater(
      side.write(
        note.id,
        NoteSideKind.pageMarks,
        sampleFiles()[NoteSideKind.pageMarks]!,
        base: next,
      ),
      throwsStateError,
    );
    expect((await repository.revisions()).length, before + 1);
    expect(
      (await side.list(note.id, NoteSideKind.pageMarks)).single.revisionId,
      next.revisionId,
    );
  });

  test('the folder chain is guarded until the commit', () async {
    final library = LibraryStore(repository);
    final outer = await library.createFolder('Outer');
    final inner = await library.createFolder('Inner', parentId: outer.id);
    final note = await workspace.create('Filed', folderId: inner.id);
    await side.write(
      note.id,
      NoteSideKind.pageMarks,
      sampleFiles()[NoteSideKind.pageMarks]!,
    );
    side.beforeCommit = () async {
      final folder = (await library.listFolders()).singleWhere(
        (f) => f.id == outer.id,
      );
      await library.setDeleted(folder, true);
    };
    final before = (await repository.revisions()).length;
    await expectLater(
      side.write(
        note.id,
        NoteSideKind.recording,
        sampleFiles()[NoteSideKind.recording]!,
      ),
      throwsStateError,
    );
    expect((await repository.revisions()).length, before + 1);
    final trashed = (await workspace.list(includeDeleted: true)).single;
    expect(trashed.trashed, isTrue);
    expect(trashed.deletionConflict, isFalse);

    // Without the hook, a note under a trashed outer folder is refused up front.
    side.beforeCommit = null;
    await expectLater(
      side.write(
        note.id,
        NoteSideKind.recording,
        sampleFiles()[NoteSideKind.recording]!,
      ),
      throwsStateError,
    );
  });

  test('a folder split by a rename is walked on every branch', () async {
    final library = LibraryStore(repository);
    final outer = await library.createFolder('Outer');
    final inner = await library.createFolder('Inner');
    final note = await workspace.create('Filed', folderId: inner.id);
    // Two devices changed the inner folder offline: one renamed it at the top,
    // the other moved it under the outer folder.
    final branches = <String>[];
    for (final (title, parentId) in [('Left', null), ('Right', outer.id)]) {
      final branch = await repository.commit(
        entityId: inner.id,
        kind: EntityKind.folder,
        files: {
          'folder.json': json({'title': title, 'parentId': parentId}),
        },
        parentRevisionIds: [inner.revision.revisionId],
      );
      branches.add(branch.revisionId);
    }
    expect(await repository.heads(inner.id), hasLength(2));

    final written = await side.write(
      note.id,
      NoteSideKind.pageMarks,
      sampleFiles()[NoteSideKind.pageMarks]!,
    );
    expect(
      (await side.list(note.id, NoteSideKind.pageMarks)).single.entityId,
      written.entityId,
    );

    // The outer folder above one branch goes to the trash.
    final outerHead = (await repository.heads(outer.id)).single;
    await repository.commit(
      entityId: outer.id,
      kind: EntityKind.folder,
      files: await repository.readFiles(outerHead),
      parentRevisionIds: [outerHead.revisionId],
      deleted: true,
    );
    final before = (await repository.revisions()).length;
    await expectLater(
      side.write(
        note.id,
        NoteSideKind.recording,
        sampleFiles()[NoteSideKind.recording]!,
      ),
      throwsStateError,
    );
    expect((await repository.revisions()).length, before);
  });

  test('one deleted branch of the folder refuses the write', () async {
    final library = LibraryStore(repository);
    final folder = await library.createFolder('Split');
    final note = await workspace.create('Filed', folderId: folder.id);
    final left = await repository.commit(
      entityId: folder.id,
      kind: EntityKind.folder,
      files: {
        'folder.json': json({'title': 'Left', 'parentId': null}),
      },
      parentRevisionIds: [folder.revision.revisionId],
    );
    await repository.commit(
      entityId: folder.id,
      kind: EntityKind.folder,
      files: await repository.readFiles(left),
      parentRevisionIds: [folder.revision.revisionId],
      deleted: true,
    );
    expect(await repository.heads(folder.id), hasLength(2));
    await expectLater(
      side.write(
        note.id,
        NoteSideKind.pageMarks,
        sampleFiles()[NoteSideKind.pageMarks]!,
      ),
      throwsStateError,
    );
  });

  test('folder branches that meet again above are walked once', () async {
    final library = LibraryStore(repository);
    final top = await library.createFolder('Top');
    final left = await library.createFolder('Left', parentId: top.id);
    final right = await library.createFolder('Right', parentId: top.id);
    final inner = await library.createFolder('Inner');
    final note = await workspace.create('Filed', folderId: inner.id);
    // Two devices moved the inner folder offline, one under each side folder,
    // so both branches lead up to the same top folder.
    for (final parent in [left, right]) {
      await repository.commit(
        entityId: inner.id,
        kind: EntityKind.folder,
        files: {
          'folder.json': json({'title': 'Inner', 'parentId': parent.id}),
        },
        parentRevisionIds: [inner.revision.revisionId],
      );
    }
    expect(await repository.heads(inner.id), hasLength(2));

    // Reaching the top folder twice is not a cycle.
    final written = await side.write(
      note.id,
      NoteSideKind.pageMarks,
      sampleFiles()[NoteSideKind.pageMarks]!,
    );
    expect(
      (await side.list(note.id, NoteSideKind.pageMarks)).single.entityId,
      written.entityId,
    );

    // The shared top folder is guarded: a change to it after the guard read
    // refuses the commit.
    side.beforeCommit = () async {
      final head = (await repository.heads(top.id)).single;
      await repository.commit(
        entityId: top.id,
        kind: EntityKind.folder,
        files: {
          'folder.json': json({'title': 'Top 2', 'parentId': null}),
        },
        parentRevisionIds: [head.revisionId],
      );
    };
    final before = (await repository.revisions()).length;
    await expectLater(
      side.write(
        note.id,
        NoteSideKind.recording,
        sampleFiles()[NoteSideKind.recording]!,
      ),
      throwsStateError,
    );
    expect((await repository.revisions()).length, before + 1);
  });

  test('a folder cycle refuses the write and ends', () async {
    final library = LibraryStore(repository);
    final a = await library.createFolder('A');
    final b = await library.createFolder('B', parentId: a.id);
    final note = await workspace.create('Filed', folderId: b.id);
    // Offline on another device, A was moved under B: B → A → B.
    await repository.commit(
      entityId: a.id,
      kind: EntityKind.folder,
      files: {
        'folder.json': json({'title': 'A', 'parentId': b.id}),
      },
      parentRevisionIds: [a.revision.revisionId],
    );
    final before = (await repository.revisions()).length;
    await expectLater(
      side
          .write(
            note.id,
            NoteSideKind.pageMarks,
            sampleFiles()[NoteSideKind.pageMarks]!,
          )
          .timeout(const Duration(seconds: 30)),
      throwsStateError,
    );
    expect((await repository.revisions()).length, before);
  });

  test('a trashed note takes no attachment', () async {
    final note = await workspace.create('Trashed');
    await workspace.setDeleted(note, true);
    final before = (await repository.revisions()).length;
    await expectLater(
      side.write(
        note.id,
        NoteSideKind.pageMarks,
        sampleFiles()[NoteSideKind.pageMarks]!,
      ),
      throwsStateError,
    );
    expect((await repository.revisions()).length, before);
    expect(await workspace.list(), isEmpty);
    final trashed = (await workspace.list(includeDeleted: true)).single;
    expect(trashed.deletionConflict, isFalse);

    final library = LibraryStore(repository);
    final folder = await library.createFolder('Old');
    final inFolder = await workspace.create('In folder', folderId: folder.id);
    await library.setDeleted(folder, true);
    await expectLater(
      side.write(
        inFolder.id,
        NoteSideKind.pageMarks,
        sampleFiles()[NoteSideKind.pageMarks]!,
      ),
      throwsStateError,
    );
    expect(await workspace.list(), isEmpty);
  });

  test('a same-named file without the schema is not an attachment', () async {
    final note = await workspace.create('Imported');
    await repository.commit(
      entityId: newId(),
      kind: EntityKind.attachment,
      ownerNoteId: note.id,
      files: {
        'page-marks.json': json({'title': 'a user file'}),
      },
      parentRevisionIds: [],
    );
    expect(await side.list(note.id, NoteSideKind.pageMarks), isEmpty);
  });

  test('an unreadable head is skipped and the rest still list', () async {
    final note = await workspace.create('Damaged');
    final kept = await side.write(note.id, NoteSideKind.recording, {
      'recording.json': json({'schemaVersion': 1, 'name': 'kept'}),
      'audio.m4a': Uint8List.fromList([1]),
    });
    final lost = await side.write(note.id, NoteSideKind.recording, {
      'recording.json': json({'schemaVersion': 1, 'name': 'lost'}),
      'audio.m4a': Uint8List.fromList([2]),
    });
    final hash = lost.heads.single.blobs['recording.json']!.hash;
    await File('${temp.path}/vault/blobs/$hash').delete();

    final found = await side.list(note.id, NoteSideKind.recording);
    expect(found.map((r) => r.entityId), [kept.entityId]);
  });

  test('hasUnlistedHead sees a head the list left out', () async {
    final note = await workspace.create('Unlisted');
    final first = (await writeAll(note.id))[NoteSideKind.recording]!;
    expect(await side.hasUnlistedHead(first), isFalse);
    // another device's head this app cannot read (a newer schema)
    await repository.commit(
      entityId: first.entityId,
      kind: EntityKind.attachment,
      ownerNoteId: note.id,
      files: {
        'recording.json': json({'schemaVersion': 2, 'name': 'Newer'}),
        'audio.m4a': Uint8List.fromList([1]),
      },
      parentRevisionIds: const [],
    );
    final listed = (await side.list(note.id, NoteSideKind.recording)).single;
    expect(listed.heads, hasLength(1));
    expect(await side.hasUnlistedHead(listed), isTrue);
  });

  test('attachments of another note are not mixed in', () async {
    final a = await workspace.create('A');
    final b = await workspace.create('B');
    final ofA = await writeAll(a.id);
    final ofB = await writeAll(b.id);
    for (final kind in NoteSideKind.values) {
      expect(
        (await side.list(a.id, kind)).single.entityId,
        ofA[kind]!.entityId,
      );
      expect(
        (await side.list(b.id, kind)).single.entityId,
        ofB[kind]!.entityId,
      );
    }
  });
}
