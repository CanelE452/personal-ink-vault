import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/office/office_annotation_store.dart';
import 'package:saber/data/office/office_document_store.dart';
import 'package:saber/data/vault/workspace_store.dart';

Uint8List annotationOfficeFile(String body) => Uint8List.fromList(
  ZipEncoder().encode(
    Archive()
      ..addFile(
        ArchiveFile.string('[Content_Types].xml', '<Types/>')
          ..lastModTime = 946684800,
      )
      ..addFile(
        ArchiveFile.string('word/document.xml', '<document>$body</document>')
          ..lastModTime = 946684800,
      ),
  ),
);
Uint8List annotationPdf(String body) =>
    Uint8List.fromList(utf8.encode('%PDF-1.7\nsynthetic $body\n%%EOF\n'));

void main() {
  late Directory temp;
  late NoteRepository repository;
  late OfficeDocumentStore documents;
  late OfficeAnnotationStore annotations;
  late VaultNote note;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('office-annotation-');
    repository = await NoteRepository.open(temp, createFormatVersion: 2);
    documents = OfficeDocumentStore(repository);
    annotations = OfficeAnnotationStore(repository);
    note = await documents.importDocument(
      title: 'Lecture',
      fileName: 'lecture.docx',
      bytes: annotationOfficeFile('original'),
    );
  });
  tearDown(() async {
    await repository.close();
    await temp.delete(recursive: true);
  });
  Future<OfficeEdition> edition(String name) async => documents.commitEdited(
    await documents.beginEdit(note),
    originalBytes: annotationOfficeFile(name),
    pdfBytes: annotationPdf(name),
    engineVersion: 'fixture',
    pageCount: 1,
  );

  test('each PDF edition owns a separate ink binding and preserves the old annotation graph', () async {
    final first = await edition('first');
    final old = await annotations.open(note, first);
    final oldInk = await old.saveFiles({
      'main.sbn2': Uint8List.fromList([1, 2, 3]),
    });
    final second = await edition('second');
    final current = await annotations.open(note, second);
    expect(current.bindingId, second.bindingId);
    expect(current.bindingId, isNot(old.bindingId));
    expect(current.parentRevisionIds, isEmpty);
    final newInk = await current.saveFiles({
      'main.sbn2': Uint8List.fromList([4, 5, 6]),
    });
    expect(oldInk.entityId, first.bindingId);
    expect(newInk.entityId, second.bindingId);
    expect(newInk.ownerNoteId, note.id);
    expect(await repository.heads(note.inkEntityId), isEmpty);
    expect(
      (await repository.heads(first.bindingId!)).single.revisionId,
      oldInk.revisionId,
    );
    expect(
      (await repository.readFiles(first.revision))['preview.pdf'],
      first.pdfBytes,
    );
  });

  test('concurrent annotations preserve captured parents and require explicit branch selection', () async {
    final source = await edition('first');
    final a = await annotations.open(note, source);
    final b = await annotations.open(note, source);
    final ra = await a.saveFiles({
      'main.sbn2': Uint8List.fromList([1]),
    });
    final rb = await b.saveFiles({
      'main.sbn2': Uint8List.fromList([2]),
    });
    expect(await repository.heads(source.bindingId!), hasLength(2));
    await expectLater(annotations.open(note, source), throwsStateError);
    final selected = await annotations.open(
      note,
      source,
      revisionId: ra.revisionId,
    );
    final next = await selected.saveFiles({
      'main.sbn2': Uint8List.fromList([3]),
    });
    expect(next.parentRevisionIds, [ra.revisionId]);
    expect(
      (await repository.heads(source.bindingId!)).map((r) => r.revisionId),
      containsAll([rb.revisionId, next.revisionId]),
    );
  });

  test(
    'sequential annotation saves advance only their own captured branch',
    () async {
      final source = await edition('first');
      final session = await annotations.open(note, source);
      final first = await session.saveFiles({
        'main.sbn2': Uint8List.fromList([1]),
      });
      final second = await session.saveFiles({
        'main.sbn2': Uint8List.fromList([2]),
        'main.sbn2.0': Uint8List.fromList([37, 80, 68, 70]),
      });
      expect(second.parentRevisionIds, [first.revisionId]);
      expect(session.parentRevisionIds, [second.revisionId]);
      expect(session.revision?.revisionId, second.revisionId);
    },
  );

  test(
    'foreign editions and original-only sources cannot own PDF annotations',
    () async {
      final original = await documents.readLatest(note);
      await expectLater(
        annotations.open(note, original),
        throwsFormatException,
      );
      final source = await edition('first');
      final another = await documents.importDocument(
        title: 'Other',
        fileName: 'other.docx',
        bytes: annotationOfficeFile('other'),
      );
      await expectLater(
        annotations.open(another, source),
        throwsFormatException,
      );
    },
  );

  test('annotation payload stays a standard Saber snapshot and rejects extra binding JSON', () async {
    final source = await edition('first');
    final session = await annotations.open(note, source);
    await expectLater(
      session.saveFiles({
        'main.sbn2': Uint8List.fromList([1]),
        'edition.json': Uint8List.fromList([2]),
      }),
      throwsFormatException,
    );
    expect(await repository.heads(source.bindingId!), isEmpty);
  });
}
