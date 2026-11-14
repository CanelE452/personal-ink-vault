import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/components/canvas/image/editor_image.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/vault/pdf_import_state.dart';
import 'package:saber/data/vault/saber_ink_adapter.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/pages/workspace/workspace_controller.dart';

import '../utils/test_mock_channel_handlers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();
  setupMockPathProvider();
  late Directory temp;
  late NoteRepository repository;
  final controllers = <WorkspaceController>[];
  final repositories = <NoteRepository>[];
  final pdf = Uint8List.fromList('%PDF-source-recovery-test'.codeUnits);
  setUp(() async {
    await FileManager.init(shouldWatchRootDirectory: false);
    temp = await Directory.systemTemp.createTemp('pdf-source-recovery-');
    repository = await NoteRepository.open(
      Directory('${temp.path}/vault'),
      createFormatVersion: 2,
    );
    repositories.add(repository);
  });
  tearDown(() async {
    for (final controller in controllers) {
      controller.dispose();
    }
    controllers.clear();
    for (final repo in repositories) {
      await repo.close();
    }
    repositories.clear();
    await temp.delete(recursive: true);
  });
  WorkspaceController controller(NoteRepository repo) {
    final next = WorkspaceController(repo);
    controllers.add(next);
    return next;
  }

  Future<VaultNote> source() => WorkspaceStore(repository).createWithSource(
    '원본 PDF',
    fileName: '원본.pdf',
    bytes: pdf,
    documentKind: VaultDocumentKind.pdf,
  );
  Future<void> receive(NoteRepository target, RevisionRecord revision) async {
    await target.importRevision(
      revision,
      blobsByHash: {
        for (final ref in revision.blobs.values)
          ref.hash: await repository.readBlob(ref.hash),
      },
    );
  }

  Future<NoteRepository> reopen() async {
    final result = await NoteRepository.open(repository.root);
    repositories.add(result);
    return result;
  }

  Future<Map<String, Uint8List>> completedFiles(
    VaultNote note, {
    Map<String, Object?>? marker,
  }) async {
    final head = (await repository.heads(note.sourceEntityId!)).single;
    final core = EditorCoreInfo(filePath: '/pdf-completion-test')
      ..pages.add(EditorPage());
    try {
      return {
        ...await SaberInkAdapter.capture(core, 0),
        'pdf-import.json': Uint8List.fromList(
          utf8.encode(
            jsonEncode(
              marker ??
                  {
                    'version': 1,
                    'vaultId': repository.vaultId,
                    'noteId': note.id,
                    'sourceEntityId': head.entityId,
                    'sourceRevisionId': head.revisionId,
                    'sourceSha256': head.blobs.values.single.hash,
                  },
            ),
          ),
        ),
      };
    } finally {
      core.dispose();
    }
  }

  test(
    'PDF page links distinguish another PDF with the same page number',
    () async {
      final current = controller(repository);
      final note = await source();
      await current.openNote(note, pdfPageNumber: 2);
      final session = current.activeSession!;
      final core = await current.loadInk(session: session);
      addTearDown(core.dispose);
      final original = File(current.pendingPdfPath!);
      const size = Size(600, 800);
      EditorPage page({File? file, Uint8List? bytes}) => EditorPage(
        size: size,
        backgroundImage: PdfEditorImage(
          id: core.nextImageId++,
          assetCache: core.assetCache,
          pdfBytes: bytes,
          pdfFile: file,
          pdfPage: 1,
          pageIndex: 0,
          pageSize: size,
          naturalSize: size,
          onMoveImage: null,
          onDeleteImage: null,
          onMiscChange: null,
        ),
      );
      final foreign = page(bytes: Uint8List.fromList('%PDF-another'.codeUnits));
      final target = page(file: original);
      core.pages.insertAll(0, [foreign, target]);
      await current.saveInk(core, 0, session: session);
      expect(
        (await current.resolvePdfPageLink(session, core))?.page.pageId,
        target.pageId,
      );
      expect(current.resolvePdfPageLink(session, core), isNull);

      final prepared = await PdfImportPreparation.prepare(session);
      expect(prepared.complete, isTrue);
      core.pages.insert(0, page(file: original));
      expect(await prepared.findPage(core, 2), isNull);
    },
  );

  test('canonical PDF survives controller restart and lost working copy before first import', () async {
    final first = controller(repository);
    final note = await first.importPdf(
      '살아 있는 원본',
      fileName: '원본.pdf',
      bytes: pdf,
    );
    expect(note.sourceEntityId, isNotNull);
    expect(first.pendingPdfPath, isNotNull);
    expect(await File(first.pendingPdfPath!).readAsBytes(), pdf);
    final heads = await repository.heads(note.sourceEntityId!);
    expect((await repository.readFiles(heads.single)).values.single, pdf);
    final ink = List<String>.of(first.activeSession!.inkParents);
    final count = (await repository.revisions()).length;
    await File(first.pendingPdfPath!).delete();
    first.dispose();
    controllers.remove(first);
    final next = controller(await reopen());
    await next.openNote((await next.store.list()).single);
    expect(next.pendingPdfPath, isNotNull);
    expect(await File(next.pendingPdfPath!).readAsBytes(), pdf);
    expect(next.activeSession!.inkParents, ink);
    expect((await next.repository.revisions()).length, count);
    expect(next.dirty, isTrue);
  });

  test('cancelling canonical import keeps saved ink and source and allows explicit retry', () async {
    final current = controller(repository);
    final note = await current.importPdf('취소', fileName: '원본.pdf', bytes: pdf);
    final session = current.activeSession!;
    final saved = List.of(session.inkParents);
    await current.cancelPendingImport(session: session);
    expect(current.pendingPdfPath, isNull);
    expect(current.pdfImportError, isNotNull);
    expect(current.dirty, isFalse);
    expect(current.activeSession!.inkParents, saved);
    expect((await repository.heads(note.sourceEntityId!)), hasLength(1));
    await current.retryPdfImport(session: current.activeSession!);
    expect(current.pendingPdfPath, isNotNull);
    expect(current.activeSession!.inkParents, saved);
    expect(current.dirty, isTrue);
  });

  for (final related in [false, true]) {
    test(
      'first PDF ink ${related ? 'waits for its own' : 'saves despite unrelated'} pending revisions',
      () async {
        final current = controller(repository);
        final note = await current.importPdf(
          '저장할 PDF',
          fileName: '원본.pdf',
          bytes: pdf,
        );
        final session = current.activeSession!;
        final core = await current.loadInk(session: session);
        addTearDown(core.dispose);
        const size = Size(600, 800);
        core.pages.insert(
          0,
          EditorPage(
            size: size,
            backgroundImage: PdfEditorImage(
              id: core.nextImageId++,
              assetCache: core.assetCache,
              pdfFile: File(current.pendingPdfPath!),
              pdfBytes: null,
              pdfPage: 1,
              pageIndex: 0,
              pageSize: size,
              naturalSize: size,
              onMoveImage: null,
              onDeleteImage: null,
              onMiscChange: null,
            ),
          ),
        );
        final pending = RevisionRecord(
          vaultId: repository.vaultId,
          revisionId: newId(),
          entityId: related ? note.inkEntityId : newId(),
          kind: EntityKind.ink,
          ownerNoteId: related ? note.id : newId(),
          deviceId: newId(),
          parentRevisionIds: [newId()],
          blobs: {},
          formatVersion: 2,
        );
        await repository.importRevision(pending, blobsByHash: {});
        expect(repository.pendingRevisionCount, 1);

        if (related) {
          final before = session.inkParents.toList();
          await expectLater(current.saveInk(core, 0), throwsStateError);
          expect(session.inkParents, before);
          expect(current.pendingPdfPath, isNotNull);
        } else {
          await current.saveInk(core, 0);
          expect(current.pendingPdfPath, isNull);
          final saved = (await repository.heads(note.inkEntityId)).single;
          final files = await repository.readFiles(saved);
          expect(
            PdfImportMarker.fromBytes(files[PdfImportMarker.fileName]!).noteId,
            note.id,
          );
        }
        expect(repository.pendingRevisionCount, 1);
        expect(await repository.hasKnownRevisions([pending.entityId]), isTrue);
      },
    );
  }

  test('a peer previews its PDF without ink writes until the marked first ink arrives', () async {
    final author = controller(repository);
    final note = await author.importPdf(
      '원본 PDF',
      fileName: '원본.pdf',
      bytes: pdf,
    );
    final receiver = await NoteRepository.open(
      Directory('${temp.path}/receiver'),
      vaultId: repository.vaultId,
      createFormatVersion: 2,
    );
    repositories.add(receiver);
    expect(receiver.deviceId, isNot(repository.deviceId));
    await receive(receiver, note.revision);
    final current = controller(receiver);
    await current.openNote((await current.store.list()).single);
    final session = current.activeSession!;
    expect(current.pendingPdfPath, isNull);
    expect(current.pdfPeerPreview, isFalse);
    expect(current.pdfImportError, isNotNull);
    expect(current.dirty, isFalse);
    expect(await receiver.heads(note.inkEntityId), isEmpty);
    for (final revision in await repository.revisions()) {
      if (revision.entityId != note.inkEntityId)
        await receive(receiver, revision);
    }
    await current.refresh();
    expect(current.pdfPeerPreview, isTrue);
    expect(await File(current.pdfPeerPreviewPath!).readAsBytes(), pdf);
    expect(current.pendingPdfPath, isNull);
    expect(current.pdfImportError, isNull);
    expect(current.dirty, isFalse);
    expect(await receiver.heads(note.inkEntityId), isEmpty);

    final initial = (await repository.heads(note.inkEntityId)).single;
    await receive(receiver, initial);
    await current.refresh();
    expect(current.pdfPeerPreview, isTrue);
    expect(current.pendingPdfPath, isNull);
    expect(current.dirty, isFalse);
    expect(
      (await receiver.heads(note.inkEntityId)).single.revisionId,
      initial.revisionId,
    );
    final before = (await receiver.revisions()).length;

    final authorInk = await author.loadInk();
    addTearDown(authorInk.dispose);
    const size = Size(600, 800);
    final page = EditorPage(
      size: size,
      backgroundImage: PdfEditorImage(
        id: authorInk.nextImageId++,
        assetCache: authorInk.assetCache,
        pdfBytes: pdf,
        pdfFile: null,
        pdfPage: 0,
        pageIndex: 0,
        pageSize: size,
        naturalSize: size,
        onMoveImage: null,
        onDeleteImage: null,
        onMiscChange: null,
      ),
    );
    authorInk.pages.insert(0, page);
    await author.saveInk(authorInk, 0);
    final firstInk = (await repository.heads(note.inkEntityId)).single;
    expect(firstInk.parentRevisionIds, [initial.revisionId]);
    expect(firstInk.blobs, contains(PdfImportMarker.fileName));
    await receive(receiver, firstInk);
    await current.refresh();

    expect(current.activeSession, same(session));
    expect(current.pdfPeerPreview, isFalse);
    expect(current.pdfPeerPreviewPath, isNull);
    expect(current.pendingPdfPath, isNull);
    expect(current.pdfImportError, isNull);
    expect(current.dirty, isFalse);
    expect(session.inkParents, [firstInk.revisionId]);
    final loaded = await current.loadInk(session: session);
    addTearDown(loaded.dispose);
    expect(loaded.pages.first.pageId, page.pageId);
    expect(loaded.pages.first.backgroundImage, isA<PdfEditorImage>());
    expect((await receiver.revisions()).length, before + 1);
  });

  test(
    'explicit first ink prepares a cloned source-only PDF without a revision',
    () async {
      await source();
      final clone = await repository.cloneToEmpty(
        Directory('${temp.path}/clone'),
      );
      repositories.add(clone);
      expect(clone.deviceId, isNot(repository.deviceId));
      final current = controller(clone);
      final note = (await current.store.list()).single;
      await current.openNote(note);
      final session = current.activeSession!;
      expect(current.pdfPeerPreview, isTrue);
      expect(current.pendingPdfPath, isNull);
      expect(current.dirty, isFalse);
      final revisions = await clone.revisions();
      await expectLater(
        current.beginPdfInkHere(session: await current.store.open(note)),
        throwsStateError,
      );
      expect(current.pdfPeerPreview, isTrue);

      await current.beginPdfInkHere(session: session);
      expect(current.pdfPeerPreview, isFalse);
      expect(current.pdfPeerPreviewPath, isNull);
      expect(await File(current.pendingPdfPath!).readAsBytes(), pdf);
      expect(current.pdfImportError, isNull);
      expect(current.dirty, isTrue);
      expect(await clone.heads(note.inkEntityId), isEmpty);
      expect(await clone.revisions(), revisions);
    },
  );

  for (final deleted in [false, true]) {
    test(
      '${deleted ? 'deleted' : 'conflicted'} canonical source cannot open an empty PDF editor',
      () async {
        final note = await source();
        final sourceHead = (await repository.heads(note.sourceEntityId!))
            .single;
        await repository.commit(
          entityId: note.sourceEntityId!,
          kind: EntityKind.attachment,
          ownerNoteId: note.id,
          files: {'원본.pdf': pdf},
          parentRevisionIds: deleted ? [sourceHead.revisionId] : [],
          deleted: deleted,
        );
        final current = controller(repository);
        expect(
          await repository.heads(note.sourceEntityId!),
          hasLength(deleted ? 1 : 2),
        );
        await current.openNote(note);
        expect(current.pendingPdfPath, isNull);
        expect(current.pdfImportError, isNotNull);
        expect(current.dirty, isFalse);
        expect(await repository.heads(note.inkEntityId), isEmpty);
      },
    );
  }

  test('completion marker avoids reimport after PDF pages were deliberately removed', () async {
    final note = await source();
    await (await WorkspaceStore(repository).open(note))
        .saveInk(await completedFiles(note));
    final count = (await repository.revisions()).length;
    final current = controller(await reopen());
    await current.openNote((await current.store.list()).single);
    expect(current.pendingPdfPath, isNull);
    expect(current.pdfImportError, isNull);
    final core = await current.loadInk();
    expect(core.pages, hasLength(1));
    expect(core.pages.single.backgroundImage, isNull);
    core.dispose();
    expect((await current.repository.revisions()).length, count);
  });

  test(
    'foreign completion marker is blocked without changing saved snapshots',
    () async {
      final note = await source();
      final files = await completedFiles(
        note,
        marker: {
          'version': 1,
          'vaultId': newId(),
          'noteId': newId(),
          'sourceEntityId': newId(),
          'sourceRevisionId': newId(),
          'sourceSha256': '0' * 64,
        },
      );
      await (await WorkspaceStore(repository).open(note)).saveInk(files);
      final count = (await repository.revisions()).length;
      final current = controller(repository);
      await current.openNote(note);
      expect(current.pendingPdfPath, isNull);
      expect(current.pdfImportError, isNotNull);
      expect((await repository.revisions()).length, count);
    },
  );

  test('blank pending PDF cannot be committed as a completed import', () async {
    final current = controller(repository);
    final note = await current.importPdf('대기', fileName: '원본.pdf', bytes: pdf);
    final heads = await repository.heads(note.inkEntityId);
    final core = await current.loadInk();
    try {
      await expectLater(current.saveInk(core, 0), throwsStateError);
    } finally {
      core.dispose();
    }
    expect(
      (await repository.heads(note.inkEntityId)).map((r) => r.revisionId),
      heads.map((r) => r.revisionId),
    );
  });
}
