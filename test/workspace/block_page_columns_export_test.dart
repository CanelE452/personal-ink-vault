import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:markdown/markdown.dart' as markdown;
import 'package:saber/data/vault/block_page_snapshot.dart';
import 'package:saber/data/vault/portable_document_export.dart';
import 'package:saber/data/vault/portable_document_pdf.dart';

void main() {
  final noteId = newId();
  Map<String, Object> block(String type, String text) => {
    'id': newId(),
    'type': type,
    'text': text,
  };
  final left = {
    ...block('column', ''),
    'columnLayout': 1,
    'children': [block('heading2', 'Left section')],
  };
  final right = {
    ...block('column', ''),
    'columnLayout': 1,
    'children': [
      {...block('documentLink', 'Right link'), 'noteId': noteId},
    ],
  };
  final group = {
    ...block('columnList', ''),
    'columnLayout': 1,
    'children': [left, right],
  };
  (PortableExportSource, Uint8List) fixture(Map<String, Object> group) {
    final bytes = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'version': 1,
          'blocks': [group],
        }),
      ),
    );
    return (
      PortableExportSource.page(
        noteId: noteId,
        title: 'Two columns',
        bodyRevisionId: newId(),
        metadataRevisionIds: [newId()],
        snapshot: BlockPageMediaSnapshot.fromFiles({'page.json': bytes}),
      ),
      bytes,
    );
  }

  test(
    'Markdown linearizes columns without losing heading and link semantics',
    () {
      final (source, bytes) = fixture(group);
      final bundle = buildPortableDocumentExport(
        source,
        PortableExportFormat.markdown,
      );
      final view = markdown.markdownToHtml(
        utf8.decode(bundle.files[bundle.entrypoint]!),
      );
      final dom = html_parser.parse(view);
      expect(dom.querySelector('h2')?.text, 'Left section');
      expect(dom.querySelector('a')?.text, 'Right link');
      expect(dom.querySelector('pre'), isNull);
      expect(
        view.indexOf('Left section'),
        lessThan(view.indexOf('Right link')),
      );
      expect(bundle.files['source/page.json'], bytes);
      expect(
        bundle.warnings.where((w) => w.startsWith('unknown-block:')),
        isEmpty,
      );
      expect(
        bundle.warnings,
        contains('markdown.columns_flattened:${group['id']}'),
      );
    },
  );

  test('HTML groups both columns in source order and stacks them on narrow screens', () {
    final (source, bytes) = fixture(group);
    final bundle = buildPortableDocumentExport(
      source,
      PortableExportFormat.html,
    );
    final view = utf8.decode(bundle.files[bundle.entrypoint]!);
    final dom = html_parser.parse(view);
    final columns = dom.querySelectorAll('.page-columns > .page-column');
    expect(columns, hasLength(2));
    expect(columns.first.querySelector('h2')?.text, 'Left section');
    expect(columns.last.querySelector('a')?.text, 'Right link');
    expect(dom.querySelector('style')?.text, contains('@media'));
    expect(bundle.files['source/page.json'], bytes);
    expect(
      bundle.warnings.where((w) => w.startsWith('unknown-block:')),
      isEmpty,
    );
  });

  test(
    'Markdown keeps numbered lists separate across an empty pane paragraph',
    () {
      final (source, _) = fixture({
        ...group,
        'children': [
          {
            ...left,
            'children': [
              block('numbered', 'Left first'),
              block('paragraph', ''),
            ],
          },
          {
            ...right,
            'children': [
              block('paragraph', ''),
              block('numbered', 'Right first'),
            ],
          },
        ],
      });
      final bundle = buildPortableDocumentExport(
        source,
        PortableExportFormat.markdown,
      );
      final view = markdown.markdownToHtml(
        utf8.decode(bundle.files[bundle.entrypoint]!),
      );
      final lists = html_parser.parse(view).querySelectorAll('ol');
      expect(lists.map((list) => list.text.trim()), [
        'Left first',
        'Right first',
      ]);
    },
  );

  test(
    'unmarked legacy blocks keep their original layout warning and source',
    () {
      final unmarked = {...group}..remove('columnLayout');
      final (source, bytes) = fixture(unmarked);
      final bundle = buildPortableDocumentExport(
        source,
        PortableExportFormat.html,
      );
      final view = utf8.decode(bundle.files[bundle.entrypoint]!);
      expect(html_parser.parse(view).querySelector('.page-columns'), isNull);
      expect(bundle.warnings, contains(startsWith('unknown-block:')));
      expect(bundle.files['source/page.json'], bytes);
    },
  );

  test(
    'PDF has a valid page and reports flattening the source columns',
    () async {
      final (source, _) = fixture(group);
      final font = await File('build/native/fonts/NotoSansKR-Portable.ttf')
          .readAsBytes();
      final pdf = await renderPortableDocumentPdf(
        source,
        fontData: ByteData.sublistView(font),
      );
      expect(ascii.decode(pdf.bytes.take(5).toList()), '%PDF-');
      expect(pdf.warnings, contains('pdf.columns_flattened:${group['id']}'));
      expect(
        pdf.warnings.where((w) => w.startsWith('pdf.unknown_block:')),
        isEmpty,
      );
    },
  );
}
