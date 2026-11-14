import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/vault/block_page_document.dart';
import 'package:saber/data/vault/block_page_snapshot.dart';
import 'package:saber/data/vault/note_link.dart';
import 'package:saber/data/vault/portable_document_export.dart';
import 'package:saber/data/vault/portable_document_pdf.dart';
import 'package:saber/data/vault/workspace_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final sourceId = newId();
  final block = BlockPageBlock.createLinkedDatabase(
    noteId: sourceId,
    view: DatabaseView.create(type: 'board'),
    text: '<script>연구</script> [자료]',
  );

  PortableExportSource source(BlockPageDocument page) =>
      PortableExportSource.page(
        noteId: newId(),
        title: '연구 대시보드',
        bodyRevisionId: newId(),
        metadataRevisionIds: [newId()],
        snapshot: BlockPageMediaSnapshot.prepare(page),
      );

  for (final format in [
    PortableExportFormat.markdown,
    PortableExportFormat.html,
  ]) {
    test(
      '${format.name} preserves a linked source and declares reference-only export',
      () {
        final page = const BlockPageDocument.empty().copyWith(blocks: [block]);
        final bundle = buildPortableDocumentExport(source(page), format);
        final output = utf8.decode(bundle.files[bundle.entrypoint]!);
        expect(output, contains(NoteLink(sourceId).toString()));
        expect(output, isNot(contains('<script>')));
        expect(
          bundle.warnings,
          contains(
            contains('linked-database-reference: ${block.id}: $sourceId'),
          ),
        );
        expect(
          jsonDecode(utf8.decode(bundle.files['source/page.json']!)),
          page.toJson(),
        );
      },
    );
  }

  test('a future linked block remains opaque in portable output', () {
    final json = const BlockPageDocument.empty()
        .copyWith(blocks: [block])
        .toJson();
    final raw = (json['blocks'] as List).single as Map<String, dynamic>;
    (raw['linkedDatabaseData'] as Map<String, dynamic>)['format'] =
        'future-link-99';
    final page = BlockPageDocument.fromJson(json);
    final bundle = buildPortableDocumentExport(
      source(page),
      PortableExportFormat.html,
    );
    final output = utf8.decode(bundle.files[bundle.entrypoint]!);
    expect(output, isNot(contains(NoteLink(sourceId).toString())));
    expect(
      bundle.warnings,
      contains(contains('unknown-linked-database: ${block.id}')),
    );
    expect(
      jsonDecode(utf8.decode(bundle.files['source/page.json']!)),
      page.toJson(),
    );
  });

  test(
    'PDF keeps a linked reference and declares the missing live source',
    () async {
      final page = const BlockPageDocument.empty().copyWith(blocks: [block]);
      final pdf = await renderPortableDocumentPdf(
        source(page),
        fontData: ByteData.sublistView(
          await File('build/native/fonts/NotoSansKR-Portable.ttf')
              .readAsBytes(),
        ),
      );
      expect(latin1.decode(pdf.bytes), startsWith('%PDF-'));
      expect(latin1.decode(pdf.bytes), contains('/ToUnicode'));
      expect(
        pdf.warnings,
        contains('pdf.linked_database_reference:${block.id}:$sourceId'),
      );
    },
  );
}
