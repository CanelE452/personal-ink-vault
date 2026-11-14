import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/office/office_annotation_store.dart';
import 'package:saber/data/office/office_document_store.dart';
import 'package:saber/data/vault/library_store.dart';
import 'package:saber/data/vault/workspace_store.dart';

Uint8List officeFile(String body, {bool slides = false}) => Uint8List.fromList(
  ZipEncoder().encode(
    Archive()
      ..addFile(ArchiveFile.string('[Content_Types].xml', '<Types/>'))
      ..addFile(
        ArchiveFile.string(
          slides ? 'ppt/presentation.xml' : 'word/document.xml',
          slides
              ? '<presentation>$body</presentation>'
              : '<document>$body</document>',
        ),
      ),
    modified: DateTime.utc(1980, 1, 1),
  ),
);

Uint8List syntheticPdf(String label) => Uint8List.fromList(
  utf8.encode('%PDF-1.7\nsynthetic contract fixture $label\n%%EOF\n'),
);

Uint8List legacyOfficeFile(String label) => Uint8List.fromList([
  0xd0,
  0xcf,
  0x11,
  0xe0,
  0xa1,
  0xb1,
  0x1a,
  0xe1,
  ...utf8.encode(label),
]);

void main() {
  late Directory temp;
  late NoteRepository repository;
  late OfficeDocumentStore store;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('office-editions-');
    repository = await NoteRepository.open(temp, createFormatVersion: 2);
    store = OfficeDocumentStore(repository);
  });
  tearDown(() async {
    await repository.close();
    final root = await Directory.systemTemp.resolveSymbolicLinks();
    final resolved = await temp.resolveSymbolicLinks();
    expect(
      resolved,
      startsWith('$root${Platform.pathSeparator}office-editions-'),
    );
    await Directory(resolved).delete(recursive: true);
  });

  Future<VaultNote> imported() => store.importDocument(
    title: 'Lecture',
    fileName: 'lecture.docx',
    bytes: officeFile('original'),
  );

  test('import creates an Office note in the chosen folder with an immutable original', () async {
    final folder = await LibraryStore(repository).createFolder('Lectures');
    final original = officeFile('original');
    final note = await store.importDocument(
      title: 'Lecture',
      fileName: 'lecture.docx',
      bytes: original,
      folderId: folder.id,
    );
    expect(note.documentKind, VaultDocumentKind.office);
    expect(note.folderId, folder.id);
    expect(note.sourceEntityId, isNotNull);
    final edition = await store.readLatest(note);
    expect(edition.revision.kind, EntityKind.attachment);
    expect(edition.revision.ownerNoteId, note.id);
    expect(edition.originalFileName, 'lecture.docx');
    expect(
      await store.readOriginalFileName(note, edition.revision),
      'lecture.docx',
    );
    expect(edition.originalBytes, original);
    expect(edition.pdfBytes, isNull);
    expect(edition.bindingId, isNull);
    original[0] = 0;
    expect((await store.readLatest(note)).originalBytes.first, 0x50);
  });

  for (final (sourceName, copyName, slides) in [
    ('Lecture.DOC', 'Lecture.docx', false),
    ('Lecture.ppt', 'Lecture.pptx', true),
  ]) {
    test(
      'publishes $copyName with a first paired edition and leaves legacy ink intact',
      () async {
        final folder = await LibraryStore(repository).createFolder('Lectures');
        final legacy = legacyOfficeFile('legacy');
        final oldPdf = syntheticPdf('legacy');
        final note = await store.importDocument(
          title: 'Lecture',
          fileName: sourceName,
          bytes: legacy,
          folderId: folder.id,
        );
        final oldEdition = await store.commitEdited(
          await store.beginEdit(note),
          originalBytes: legacy,
          pdfBytes: oldPdf,
          engineVersion: 'legacy',
          pageCount: 1,
        );
        final annotations = OfficeAnnotationStore(repository);
        final oldInk = await (await annotations.open(note, oldEdition))
            .saveFiles({
              'main.sbn2': Uint8List.fromList([1, 2, 3]),
            });
        final modern = officeFile('converted', slides: slides);
        final pdf = syntheticPdf('converted');
        final copy = await store.createConvertedCopy(
          await store.beginEdit(note),
          originalBytes: modern,
          pdfBytes: pdf,
          engineVersion: 'LibreOffice',
          pageCount: 2,
        );
        final paired = (await store.readEditions(copy)).single;
        expect(copy.title, 'Lecture (편집용)');
        expect(copy.documentKind, VaultDocumentKind.office);
        expect(copy.folderId, folder.id);
        expect(copy.id, isNot(note.id));
        expect(copy.sourceEntityId, isNot(note.sourceEntityId));
        expect(paired.revision.parentRevisionIds, isEmpty);
        expect(paired.originalFileName, copyName);
        expect(paired.originalBytes, modern);
        expect(paired.pdfBytes, pdf);
        expect(paired.pageCount, 2);
        expect(paired.engineVersion, 'LibreOffice');
        expect(paired.bindingId, isNot(oldEdition.bindingId));
        expect((await annotations.open(copy, paired)).revision, isNull);
        expect(
          (await repository.readFiles(paired.revision)).keys,
          unorderedEquals([copyName, 'preview.pdf', 'edition.json']),
        );
        expect(
          (await store.readLatest(note)).revision.revisionId,
          oldEdition.revision.revisionId,
        );
        expect((await store.readLatest(note)).originalBytes, legacy);
        expect((await store.readLatest(note)).pdfBytes, oldPdf);
        expect(
          (await repository.heads(oldInk.entityId)).single.revisionId,
          oldInk.revisionId,
        );
        expect((await repository.readFiles(oldInk))['main.sbn2'], [1, 2, 3]);
      },
    );
  }

  test('invalid conversion result leaves the legacy source and visible notes unchanged', () async {
    final legacy = legacyOfficeFile('legacy');
    final note = await store.importDocument(
      title: 'Lecture',
      fileName: 'lecture.doc',
      bytes: legacy,
    );
    final session = await store.beginEdit(note);
    final before = await repository.revisions();
    for (final (source, pdf, version, pages) in [
      (
        officeFile('wrong family', slides: true),
        syntheticPdf('good'),
        'engine',
        1,
      ),
      (officeFile('good'), Uint8List(0), 'engine', 1),
      (officeFile('good'), syntheticPdf('good'), ' ', 1),
      (officeFile('good'), syntheticPdf('good'), 'engine', 0),
    ]) {
      await expectLater(
        store.createConvertedCopy(
          session,
          originalBytes: source,
          pdfBytes: pdf,
          engineVersion: version,
          pageCount: pages,
        ),
        throwsFormatException,
      );
    }
    expect(await repository.revisions(), hasLength(before.length));
    expect((await WorkspaceStore(repository).list()).single.id, note.id);
    expect((await store.readLatest(note)).originalBytes, legacy);
  });

  for (final changeSource in [true, false]) {
    test(
      'a change to the captured ${changeSource ? 'source' : 'note'} prevents copy publication',
      () async {
        final note = await store.importDocument(
          title: 'Lecture',
          fileName: 'lecture.doc',
          bytes: legacyOfficeFile('legacy'),
        );
        final session = await store.beginEdit(note);
        if (changeSource) {
          await store.commitEdited(
            session,
            originalBytes: legacyOfficeFile('updated'),
            pdfBytes: syntheticPdf('updated'),
            engineVersion: 'engine',
            pageCount: 1,
          );
        } else {
          await repository.commit(
            entityId: note.id,
            kind: EntityKind.metadata,
            files: await repository.readFiles(note.revision),
            parentRevisionIds: [note.revision.revisionId],
          );
        }
        final before = await repository.revisions();
        await expectLater(
          store.createConvertedCopy(
            session,
            originalBytes: officeFile('converted'),
            pdfBytes: syntheticPdf('converted'),
            engineVersion: 'engine',
            pageCount: 1,
          ),
          throwsStateError,
        );
        expect(await repository.revisions(), hasLength(before.length));
        expect((await WorkspaceStore(repository).list()).single.id, note.id);
      },
    );
  }

  test(
    'cancel at the metadata boundary does not expose a converted copy',
    () async {
      final note = await store.importDocument(
        title: 'Lecture',
        fileName: 'lecture.doc',
        bytes: legacyOfficeFile('legacy'),
      );
      final session = await store.beginEdit(note);
      var checks = 0;
      await expectLater(
        store.createConvertedCopy(
          session,
          originalBytes: officeFile('converted'),
          pdfBytes: syntheticPdf('converted'),
          engineVersion: 'engine',
          pageCount: 1,
          beforePublish: () {
            if (++checks >= 3) throw StateError('copy canceled');
          },
        ),
        throwsStateError,
      );
      expect(checks, 3);
      expect((await WorkspaceStore(repository).list()).single.id, note.id);
      expect(
        (await store.readLatest(note)).revision.revisionId,
        session.sourceRevision.revisionId,
      );
    },
  );

  test(
    'one revision binds the edited original and derived PDF with their hashes',
    () async {
      final note = await imported();
      final session = await store.beginEdit(note);
      final original = officeFile('edited');
      final pdf = syntheticPdf('edited');
      final edition = await store.commitEdited(
        session,
        originalBytes: original,
        pdfBytes: pdf,
        engineVersion: 'Collabora26.04',
        pageCount: 2,
      );
      expect(edition.revision.entityId, note.sourceEntityId);
      expect(edition.revision.parentRevisionIds, [
        session.sourceRevision.revisionId,
      ]);
      expect(edition.originalBytes, original);
      expect(edition.pdfBytes, pdf);
      expect(edition.pageCount, 2);
      expect(edition.originalSha256, sha256.convert(original).toString());
      expect(edition.pdfSha256, sha256.convert(pdf).toString());
      validateId(edition.bindingId!);
      final files = await repository.readFiles(edition.revision);
      expect(files.keys.toSet(), {
        'lecture.docx',
        'preview.pdf',
        'edition.json',
      });
      expect(
        await store.readOriginalFileName(note, edition.revision),
        'lecture.docx',
      );
      final metadata = jsonDecode(
        utf8.decode(files['edition.json']!),
      ) as Map<String, dynamic>;
      expect(metadata['originalSha256'], edition.originalSha256);
      expect(metadata['pdfSha256'], edition.pdfSha256);
      expect(metadata['bindingId'], edition.bindingId);
      expect(
        (await store.readLatest(note)).revision.revisionId,
        edition.revision.revisionId,
      );
    },
  );

  test('distinct derived PDFs stay under their captured original and clone without changing identities', () async {
    final note = await imported();
    final captured = await store.beginEdit(note);
    final original = await store.readLatest(note);
    final one = syntheticPdf('render one');
    final two = syntheticPdf('render two');
    final variants = await Future.wait([
      store.commitDerivedPdf(captured, pdfBytes: one, pageCount: 1),
      store.commitDerivedPdf(captured, pdfBytes: two, pageCount: 1),
    ]);
    final (first, second) = (variants[0], variants[1]);
    expect(first.bindingId, isNot(second.bindingId));
    expect(first.revision.entityId, isNot(first.bindingId));
    expect(first.revision.parentRevisionIds, isEmpty);
    expect(first.revision.baseRefs, {
      original.revision.entityId: [original.revision.revisionId],
    });
    expect(
      (await store.readEditions(note)).single.revision.revisionId,
      original.revision.revisionId,
    );
    expect(await store.readPdfVariantBytes(note, original, first), one);
    expect(await store.readPdfVariantBytes(note, original, second), two);

    final cloneRoot = await Directory.systemTemp.createTemp(
      'office-pdf-clone-',
    );
    final clone = await repository.cloneToEmpty(cloneRoot);
    addTearDown(() async {
      await clone.close();
      await cloneRoot.delete(recursive: true);
    });
    final cloneStore = OfficeDocumentStore(clone);
    final clonedNote = (await WorkspaceStore(clone).list()).single;
    final cloneOriginal = await cloneStore.readLatest(clonedNote);
    final repeated = await cloneStore.commitDerivedPdf(
      await cloneStore.beginEdit(clonedNote),
      pdfBytes: one,
      pageCount: 1,
    );
    expect(clone.vaultId, isNot(repository.vaultId));
    expect(repeated.revision.revisionId, first.revision.revisionId);
    expect(repeated.bindingId, first.bindingId);
    expect(
      await cloneStore.readPdfVariants(clonedNote, cloneOriginal),
      hasLength(2),
    );
    expect(
      await cloneStore.readPdfVariantBytes(clonedNote, cloneOriginal, repeated),
      one,
    );

    final edited = await store.commitEdited(
      captured,
      originalBytes: officeFile('real edit'),
      pdfBytes: syntheticPdf('edited document'),
      engineVersion: 'office-edit',
      pageCount: 1,
    );
    expect(
      (await store.readLatest(note)).revision.revisionId,
      edited.revision.revisionId,
    );
    final legacy = (await store.readPdfVariants(note, edited)).single;
    expect(legacy.bindingId, edited.bindingId);
    expect(legacy.pageCount, 1);
    expect(
      await store.readPdfVariantBytes(note, edited, legacy),
      edited.pdfBytes,
    );
    expect(await store.readPdfVariants(note, original), hasLength(2));
    await expectLater(
      store.readPdfVariantBytes(note, edited, first),
      throwsFormatException,
    );
  });

  test('new editions preserve all older originals, PDFs and annotation binding IDs after reopen', () async {
    final note = await imported();
    final first = await store.commitEdited(
      await store.beginEdit(note),
      originalBytes: officeFile('one'),
      pdfBytes: syntheticPdf('one'),
      engineVersion: 'engine',
      pageCount: 1,
    );
    final second = await store.commitEdited(
      await store.beginEdit(note),
      originalBytes: officeFile('two'),
      pdfBytes: syntheticPdf('two'),
      engineVersion: 'engine',
      pageCount: 3,
    );
    expect(second.bindingId, isNot(first.bindingId));
    expect(second.revision.parentRevisionIds, [first.revision.revisionId]);
    await repository.close();
    repository = await NoteRepository.open(temp);
    store = OfficeDocumentStore(repository);
    final history = await store.readEditions(note);
    expect(history, hasLength(3));
    final restoredFirst = history.singleWhere(
      (e) => e.revision.revisionId == first.revision.revisionId,
    );
    expect(restoredFirst.originalBytes, first.originalBytes);
    expect(restoredFirst.pdfBytes, first.pdfBytes);
    expect(restoredFirst.bindingId, first.bindingId);
    expect(
      (await store.readLatest(note)).revision.revisionId,
      second.revision.revisionId,
    );
    expect(
      File('${temp.path}/blobs/${first.originalSha256}').existsSync(),
      true,
    );
    expect(File('${temp.path}/blobs/${first.pdfSha256}').existsSync(), true);
  });

  test(
    'a damaged historical PDF leaves the current Office edition readable',
    () async {
      final note = await imported();
      final initial = await store.readLatest(note);
      final damagedPdf = Uint8List.fromList(
        utf8.encode('%PDF-1.7\nincomplete\n'),
      );
      final currentOriginal = officeFile('current');
      final currentPdf = syntheticPdf('current');

      Future<RevisionRecord> addEdition({
        required RevisionRecord parent,
        required Uint8List original,
        required Uint8List pdf,
        required int pages,
      }) => repository.commit(
        entityId: note.sourceEntityId!,
        kind: EntityKind.attachment,
        ownerNoteId: note.id,
        parentRevisionIds: [parent.revisionId],
        files: {
          'lecture.docx': original,
          'preview.pdf': pdf,
          'edition.json': Uint8List.fromList(
            utf8.encode(
              jsonEncode({
                'schemaVersion': 1,
                'sourceEntityId': note.sourceEntityId,
                'bindingId': newId(),
                'originalFileName': 'lecture.docx',
                'originalSha256': sha256.convert(original).toString(),
                'pdfSha256': sha256.convert(pdf).toString(),
                'engineVersion': 'fixture',
                'pageCount': pages,
              }),
            ),
          ),
        },
      );

      final damaged = await addEdition(
        parent: initial.revision,
        original: officeFile('older'),
        pdf: damagedPdf,
        pages: 1,
      );
      final current = await addEdition(
        parent: damaged,
        original: currentOriginal,
        pdf: currentPdf,
        pages: 2,
      );

      final history = await store.readEditionSummaries(note);
      expect(history.map((edition) => edition.revision.revisionId), [
        current.revisionId,
        damaged.revisionId,
        initial.revision.revisionId,
      ]);
      expect(history.map((edition) => edition.pageCount), [2, 1, null]);
      expect(history.map((edition) => edition.hasPairedPdf), [
        true,
        true,
        false,
      ]);
      expect(
        history.map((edition) => edition.metadataUnavailable),
        everyElement(false),
      );

      final selected = await store.readLatest(note);
      expect(selected.revision.revisionId, current.revisionId);
      expect(selected.originalBytes, currentOriginal);
      expect(selected.pdfBytes, currentPdf);
      await expectLater(
        store.readLatest(note, revisionId: damaged.revisionId),
        throwsFormatException,
      );
      expect(
        (await store.readLatest(note)).revision.revisionId,
        current.revisionId,
      );
    },
  );

  test('concurrent edits keep their captured parent and require explicit branch selection', () async {
    final note = await imported();
    final a = await store.beginEdit(note);
    final b = await store.beginEdit(note);
    final first = await store.commitEdited(
      a,
      originalBytes: officeFile('a'),
      pdfBytes: syntheticPdf('a'),
      engineVersion: 'engine',
      pageCount: 1,
    );
    final second = await store.commitEdited(
      b,
      originalBytes: officeFile('b'),
      pdfBytes: syntheticPdf('b'),
      engineVersion: 'engine',
      pageCount: 2,
    );
    expect(first.revision.parentRevisionIds, [a.sourceRevision.revisionId]);
    expect(second.revision.parentRevisionIds, [a.sourceRevision.revisionId]);
    expect(await repository.heads(note.sourceEntityId!), hasLength(2));
    await expectLater(store.readLatest(note), throwsStateError);
    await expectLater(store.beginEdit(note), throwsStateError);
    final selected = await store.readLatest(
      note,
      revisionId: second.revision.revisionId,
    );
    expect(selected.pdfBytes, syntheticPdf('b'));
    expect((await store.readEditions(note)), hasLength(3));
  });

  test(
    'unsafe names and unsupported extensions fail before creating a note',
    () async {
      for (final name in [
        '../lecture.docx',
        r'folder\lecture.docx',
        '/lecture.docx',
        'lecture.exe',
        'docx',
        '',
      ]) {
        await expectLater(
          store.importDocument(
            title: 'bad',
            fileName: name,
            bytes: officeFile('x'),
          ),
          throwsFormatException,
        );
      }
      expect(await WorkspaceStore(repository).list(), isEmpty);
    },
  );

  test(
    'modern HWP originals can be preserved without manufacturing a PDF edition',
    () async {
      final bytes = Uint8List.fromList(utf8.encode('opaque HWP original'));
      final note = await store.importDocument(
        title: '한글',
        fileName: '수업.hwp',
        bytes: bytes,
      );
      final edition = await store.readLatest(note);
      expect(edition.originalBytes, bytes);
      expect(edition.pdfBytes, isNull);
      expect(edition.engineVersion, isNull);
    },
  );

  test('incomplete originals, PDF output and missing engine evidence cannot commit', () async {
    final note = await imported();
    final session = await store.beginEdit(note);
    final count = (await repository.revisions()).length;
    final badCases = [
      (Uint8List(0), syntheticPdf('x'), 'engine', 1),
      (
        Uint8List.fromList(utf8.encode('not a docx')),
        syntheticPdf('x'),
        'engine',
        1,
      ),
      (
        officeFile('x'),
        Uint8List.fromList(utf8.encode('not a PDF')),
        'engine',
        1,
      ),
      (officeFile('x'), syntheticPdf('x'), '', 1),
      (officeFile('x'), syntheticPdf('x'), 'engine', 0),
    ];
    for (final (original, pdf, engine, pages) in badCases) {
      await expectLater(
        store.commitEdited(
          session,
          originalBytes: original,
          pdfBytes: pdf,
          engineVersion: engine,
          pageCount: pages,
        ),
        throwsFormatException,
      );
    }
    expect((await repository.revisions()).length, count);
  });

  test('guarded Office publication rejects a changed source and rechecks permission after staging', () async {
    final note = await imported();
    final session = await store.beginEdit(note);
    final count = (await repository.revisions()).length;
    var checks = 0;
    await expectLater(
      store.commitEdited(
        session,
        originalBytes: officeFile('revoked'),
        pdfBytes: syntheticPdf('revoked'),
        engineVersion: 'engine',
        pageCount: 1,
        requireCurrentHeads: true,
        beforePublish: () {
          if (++checks == 2)
            throw StateError('permission revoked after staging');
        },
      ),
      throwsStateError,
    );
    expect(checks, 2);
    expect((await repository.revisions()).length, count);
    final edited = await store.commitEdited(
      session,
      originalBytes: officeFile('allowed'),
      pdfBytes: syntheticPdf('allowed'),
      engineVersion: 'engine',
      pageCount: 1,
      requireCurrentHeads: true,
      beforePublish: () {},
    );
    await expectLater(
      store.commitEdited(
        session,
        originalBytes: officeFile('stale'),
        pdfBytes: syntheticPdf('stale'),
        engineVersion: 'engine',
        pageCount: 1,
        requireCurrentHeads: true,
        beforePublish: () {},
      ),
      throwsStateError,
    );
    expect(
      (await store.readLatest(note)).revision.revisionId,
      edited.revision.revisionId,
    );
  });

  test('metadata cannot claim a different original or PDF hash than the bound files', () async {
    final note = await imported();
    final edition = await store.commitEdited(
      await store.beginEdit(note),
      originalBytes: officeFile('edited'),
      pdfBytes: syntheticPdf('edited'),
      engineVersion: 'engine',
      pageCount: 1,
    );
    final files = await repository.readFiles(edition.revision);
    final metadata =
        jsonDecode(utf8.decode(files['edition.json']!)) as Map<String, dynamic>;
    metadata['pdfSha256'] = '0' * 64;
    files['edition.json'] = Uint8List.fromList(
      utf8.encode(jsonEncode(metadata)),
    );
    await repository.commit(
      entityId: note.sourceEntityId!,
      kind: EntityKind.attachment,
      ownerNoteId: note.id,
      files: files,
      parentRevisionIds: [edition.revision.revisionId],
    );
    await expectLater(store.readLatest(note), throwsFormatException);
  });
}
