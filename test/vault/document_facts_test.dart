import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/vault/document_facts.dart';
import 'package:saber/data/vault/workspace_store.dart';

void main() {
  late Directory temporary;
  late NoteRepository repository;
  late WorkspaceStore store;

  setUp(() async {
    final owner = Directory.systemTemp;
    temporary = await owner.createTemp('piv-facts-');
    addTearDown(() async {
      final resolved = await temporary.resolveSymbolicLinks();
      expect(p.basename(resolved), startsWith('piv-facts-'));
      await Directory(resolved).delete(recursive: true);
    });
    repository = await NoteRepository.open(
      Directory(p.join(temporary.path, 'v')),
      createFormatVersion: 2,
    );
    addTearDown(repository.close);
    store = WorkspaceStore(repository);
  });

  Uint8List bytes() => Uint8List.fromList([1, 2, 3, 4]);

  test('revision times found once are kept for the next read', () async {
    final note = await store.create('Plain');
    final times = <String, DateTime>{};
    final first = await readDocumentFacts(repository, [note], times: times);
    expect(times[note.revision.revisionId], first[note.id]!.created);
    // A committed revision file never changes, so a known time is not read
    // from it again.
    final known = DateTime(2001, 2, 3);
    times[note.revision.revisionId] = known;
    final second = await readDocumentFacts(repository, [note], times: times);
    expect(second[note.id]!.created, known);
  });

  test('an office note reports the original extension', () async {
    final note = await store.createWithSource(
      'Deck',
      fileName: 'Slides.PPTX',
      bytes: bytes(),
      documentKind: VaultDocumentKind.office,
    );
    final facts = await readDocumentFacts(repository, [note]);
    expect(facts[note.id]!.format, 'pptx');
  });

  test('a pdf note reports pdf and others report null', () async {
    final pdf = await store.createWithSource(
      'Paper',
      fileName: 'paper.pdf',
      bytes: bytes(),
      documentKind: VaultDocumentKind.pdf,
    );
    final plain = await store.create('Plain');
    final facts = await readDocumentFacts(repository, [pdf, plain]);
    expect(facts[pdf.id]!.format, 'pdf');
    expect(facts[plain.id]!.format, isNull);
  });

  test(
    'changed is not before created and moves forward after a save',
    () async {
      final note = await store.createWithSource(
        'Dated',
        fileName: 'dated.docx',
        bytes: bytes(),
        documentKind: VaultDocumentKind.office,
      );
      File revisionFile(RevisionRecord r) => File(
        p.join(repository.root.path, 'revisions', '${r.revisionId}.json'),
      );
      final base = DateTime.utc(2026, 1, 1);
      await revisionFile(note.revision).setLastModified(base);
      final source = (await repository.heads(note.sourceEntityId!)).single;
      await revisionFile(source).setLastModified(base);
      for (final id in [note.inkEntityId, note.markdownEntityId]) {
        for (final head in await repository.heads(id)) {
          await revisionFile(head).setLastModified(base);
        }
      }

      var facts = (await readDocumentFacts(repository, [note]))[note.id]!;
      expect(facts.created!.isAtSameMomentAs(base), isTrue);
      expect(facts.changed!.isAtSameMomentAs(base), isTrue);

      final later = base.add(const Duration(days: 3));
      await revisionFile(source).setLastModified(later);
      facts = (await readDocumentFacts(repository, [note]))[note.id]!;
      expect(facts.created!.isAtSameMomentAs(base), isTrue);
      expect(facts.changed!.isAtSameMomentAs(later), isTrue);
      expect(facts.changed!.isBefore(facts.created!), isFalse);
    },
  );

  test('withCover keeps the other facts and sets pages and aspect', () {
    final facts = const DocumentFacts(format: 'pdf')
        .withCover(pages: 3, aspect: 0.7);
    expect(facts.format, 'pdf');
    expect(facts.pages, 3);
    expect(facts.aspect, 0.7);
  });
}
