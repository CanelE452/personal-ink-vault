import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/vault/note_page_marks.dart';
import 'package:saber/data/vault/note_side_store.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/pages/workspace/study_workspace.dart';

import '../utils/test_mock_channel_handlers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();
  setupMockPathProvider();
  setupMockPrinting();
  setupMockWindowManager();
  test('Office source branches are visible and resolution preserves both originals', () async {
    final root = await Directory.systemTemp.createTemp('workspace-source-conflict-');
    final repo = await NoteRepository.open(root, createFormatVersion: 2);
    final c = WorkspaceController(repo);
    var note = await c.store.create('Slides', documentKind: VaultDocumentKind.office);
    note = await c.store.attachSource(note, fileName: 'slides.pptx', bytes: Uint8List.fromList([1]));
    await c.openNote(note);
    final base = (await repo.heads(note.sourceEntityId!)).single;
    final versions = <RevisionRecord>[];
    for (final contents in [[2], [3]]) {
      versions.add(await repo.commit(entityId: note.sourceEntityId!, kind: EntityKind.attachment,
        ownerNoteId: note.id, files: {'slides.pptx': Uint8List.fromList(contents)},
        parentRevisionIds: [base.revisionId]));
    }
    await c.refresh();
    final conflictVisible = c.remoteConflict;
    await c.chooseRevision(versions.first);
    expect(c.remoteConflict, isFalse);
    expect(await repo.heads(note.sourceEntityId!), hasLength(1));
    for (final version in versions) {
      expect(await repo.readFiles(version), contains('slides.pptx'));
    }
    c.dispose();
    await repo.close();
    await root.delete(recursive: true);
    expect(conflictVisible, isTrue);
  });

  // The note's own attachments (favourites, quick note, recordings) join
  // their splits themselves: a split there holds no PDF note in conflict
  // (final fix wave 1).
  group('a PDF note with a split attachment of its own', () {
    late Directory root;
    late NoteRepository repo;
    late WorkspaceController c;
    late VaultNote note;
    late List<RevisionRecord> marks;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('workspace-side-split-');
      repo = await NoteRepository.open(root, createFormatVersion: 2);
      c = WorkspaceController(repo);
      note = await c.store.create('Lecture', documentKind: VaultDocumentKind.pdf);
      note = await c.store.attachSource(note, fileName: 'lecture.pdf', bytes: Uint8List.fromList([1]));
      await c.openNote(note);
      // two devices each added a favourite offline over the same attachment
      final base = await NoteSideStore(repo).write(note.id, NoteSideKind.pageMarks, {
        NoteSideKind.pageMarks.markerFile: NotePageMarks().encode(),
      });
      marks = [
        for (final page in ['page-a', 'page-b'])
          await repo.commit(entityId: base.entityId, kind: EntityKind.attachment, ownerNoteId: note.id,
            files: {NoteSideKind.pageMarks.markerFile: (NotePageMarks()..addFavorite(page)).encode()},
            parentRevisionIds: [base.revisionId]),
      ];
    });
    tearDown(() async {
      c.dispose();
      await repo.close().timeout(const Duration(seconds: 30));
      await root.delete(recursive: true);
    });

    test('is no conflict, and ink from another device comes in', () async {
      await c.refresh();
      expect(c.remoteConflict, isFalse);
      final remote = await repo.commit(entityId: note.inkEntityId, kind: EntityKind.ink, ownerNoteId: note.id,
        files: {'main.sbn2': Uint8List.fromList([9])}, parentRevisionIds: c.activeSession!.inkParents);
      final generation = c.editorGeneration;
      await c.refresh();
      expect(c.remoteConflict, isFalse);
      expect(c.activeSession!.inkParents, [remote.revisionId]);
      expect(c.editorGeneration, greaterThan(generation));
      // the conflict window does not offer the favourites' heads
      expect(await c.conflictHeads(), isEmpty);
    });

    test('a split source is still a conflict, and only it is offered', () async {
      final base = (await repo.heads(note.sourceEntityId!)).single;
      final versions = [
        for (final contents in [[2], [3]])
          await repo.commit(entityId: note.sourceEntityId!, kind: EntityKind.attachment, ownerNoteId: note.id,
            files: {'lecture.pdf': Uint8List.fromList(contents)}, parentRevisionIds: [base.revisionId]),
      ];
      await c.refresh();
      expect(c.remoteConflict, isTrue);
      final offered = {for (final head in await c.conflictHeads()) head.revisionId};
      expect(offered, {for (final v in versions) v.revisionId});
      expect(offered.intersection({for (final m in marks) m.revisionId}), isEmpty);
    });

    // The window itself (final fix 2, Minor 4): it lists what the controller
    // offers, so the favourites' split heads are not there to choose.
    testWidgets('the conflict window lists the split source, not the favourites', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final versions = (await tester.runAsync(() async {
        final base = (await repo.heads(note.sourceEntityId!)).single;
        return [
          for (final contents in [[2], [3]])
            await repo.commit(entityId: note.sourceEntityId!, kind: EntityKind.attachment, ownerNoteId: note.id,
              files: {'lecture.pdf': Uint8List.fromList(contents)}, parentRevisionIds: [base.revisionId]),
        ];
      }))!;
      await tester.runAsync(c.refresh);
      expect(c.remoteConflict, isTrue);
      await tester.pumpWidget(MediaQuery(
        data: const MediaQueryData(size: Size(1280, 800)),
        child: MaterialApp(home: StudyWorkspace(controller: c)),
      ));
      await tester.pump();
      await tester.tap(find.text('충돌 확인'));
      // the window reads the vault first: let that real reading finish
      for (var i = 0; i < 500 && find.text('충돌 버전 선택').evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();
      }
      expect(find.text('충돌 버전 선택'), findsOneWidget);
      for (final version in versions) {
        expect(find.textContaining(version.revisionId.substring(0, 8)), findsOneWidget);
      }
      for (final head in marks) {
        expect(find.textContaining(head.revisionId.substring(0, 8)), findsNothing);
      }
      // close the window; the workspace's vault work runs on the test's fake
      // time, so the note is saved and the vault closed while pumping
      Navigator.of(tester.element(find.text('충돌 버전 선택'))).pop();
      await tester.pumpWidget(const SizedBox());
      Future<void> pumpUntilDone(Future<void> work) async {
        var done = false;
        unawaited(work.whenComplete(() => done = true));
        for (var i = 0; i < 2000 && !done; i++) {
          await tester.runAsync(() => Future<void>.delayed(Duration.zero));
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(done, isTrue);
      }

      await pumpUntilDone(c.flush());
      await pumpUntilDone(repo.close());
    });
  });

  test('joinsItself: every head an attachment with a marker file of its kind', () async {
    RevisionRecord head(EntityKind kind, String file) => RevisionRecord(
      vaultId: newId(), revisionId: newId(), entityId: newId(), kind: kind, ownerNoteId: newId(),
      parentRevisionIds: const [], deviceId: newId(), formatVersion: 2, blobs: {file: BlobRef(hash: 'a' * 64, length: 1)});
    for (final kind in NoteSideKind.values) {
      expect(NoteSideStore.joinsItself([head(EntityKind.attachment, kind.markerFile)]), isTrue);
    }
    expect(NoteSideStore.joinsItself([head(EntityKind.attachment, 'lecture.pdf')]), isFalse);
    expect(NoteSideStore.joinsItself([
      head(EntityKind.attachment, 'page-marks.json'), head(EntityKind.attachment, 'lecture.pdf'),
    ]), isFalse);
    expect(NoteSideStore.joinsItself([head(EntityKind.ink, 'page-marks.json')]), isFalse);
    expect(NoteSideStore.joinsItself(const []), isFalse);
  });
}
