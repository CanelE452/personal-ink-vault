import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/office/pdf_note_original.dart';
import 'package:saber/data/vault/workspace_store.dart';

void main() {
  late Directory temp;
  late NoteRepository repository;
  late WorkspaceStore store;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('pdf-note-original-');
    repository = await NoteRepository.open(temp, createFormatVersion: 2);
    store = WorkspaceStore(repository);
  });
  tearDown(() async {
    await repository.close();
    await temp.delete(recursive: true);
  });

  final pdf = Uint8List.fromList('%PDF-1.7\n%%EOF\n'.codeUnits);
  final hwp = Uint8List.fromList(List.generate(64, (i) => i));

  Future<VaultNote> pdfNote() => store.createWithSource(
    'Report',
    fileName: 'Report.pdf',
    bytes: pdf,
    documentKind: VaultDocumentKind.pdf,
  );

  test('a PDF note keeps one original beside its single PDF source', () async {
    final note = await pdfNote();
    final originals = PdfNoteOriginalStore(repository);
    expect(await originals.has(note), isFalse);
    expect(await originals.read(note), isNull);

    await originals.attach(
      note,
      fileName: 'Report.hwp',
      bytes: hwp,
      engineVersion: 'engine-1',
    );
    // A second import of the same note (a retried share) keeps the first original.
    await originals.attach(
      note,
      fileName: 'Other.hwp',
      bytes: Uint8List.fromList([9]),
      engineVersion: 'engine-2',
    );

    final kept = (await originals.read(note))!;
    expect(kept.fileName, 'Report.hwp');
    expect(kept.bytes, hwp);
    expect(kept.engineVersion, 'engine-1');
    expect(await originals.has(note), isTrue);
    final owned = (await repository.revisions()).where(
      (record) =>
          record.ownerNoteId == note.id &&
          record.blobs.containsKey(PdfNoteOriginalStore.metadataFile),
    );
    expect(owned, hasLength(1));
    final source = (await repository.heads(note.sourceEntityId!)).single;
    expect((await repository.readFiles(source)).values.single, pdf);
  });

  test('only a supported, non-empty original is kept', () async {
    final note = await pdfNote();
    final originals = PdfNoteOriginalStore(repository);
    await expectLater(
      originals.attach(note, fileName: 'notes.txt', bytes: hwp),
      throwsFormatException,
    );
    await expectLater(
      originals.attach(note, fileName: 'Report.hwp', bytes: Uint8List(0)),
      throwsFormatException,
    );
    expect(await originals.has(note), isFalse);
  });

  test('a note without a recorded engine still reads its original', () async {
    final note = await pdfNote();
    final originals = PdfNoteOriginalStore(repository);
    await originals.attach(note, fileName: 'Slides.pptx', bytes: hwp);
    final kept = (await originals.read(note))!;
    expect(kept.fileName, 'Slides.pptx');
    expect(kept.engineVersion, isNull);
  });
}
