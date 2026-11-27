import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfrx/pdfrx.dart';
import 'package:saber/components/canvas/image/editor_image.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/editor/pdf_outline.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/vault/note_page_marks.dart';

import '../utils/office_preview.dart'
    show officePreviewPdfiumAvailable, withOfficePreviewPdfium;

PdfOutlineNode _node(
  String title,
  int? pageNumber, [
  List<PdfOutlineNode> children = const [],
]) => PdfOutlineNode(
  title: title,
  dest: pageNumber == null
      ? null
      : PdfDest(pageNumber, PdfDestCommand.fit, null),
  children: children,
);

/// A note built from (pdf path, 0-based pdf page) entries; null = a blank page.
/// Page ids are p0, p1, ...
EditorCoreInfo _note(List<(String, int)?> pages) {
  final core = EditorCoreInfo(filePath: '/test');
  var id = 0;
  for (final page in pages) {
    final index = core.pages.length;
    core.pages.add(
      EditorPage(
        pageId: 'p$index',
        backgroundImage: page == null
            ? null
            : PdfEditorImage(
                id: id++,
                assetCache: core.assetCache,
                pdfBytes: null,
                pdfFile: File(page.$1),
                pdfPage: page.$2,
                pageIndex: index,
                pageSize: const Size(100, 200),
                naturalSize: const Size(100, 200),
                onMoveImage: null,
                onDeleteImage: null,
                onMiscChange: null,
              ),
      ),
    );
  }
  return core;
}

/// A note whose PDFs are inside it (no file), built like a loaded note: pdfBytes come from
/// `inlineAssets`, so pages of one PDF share one bytes object. Entries are (bytes, pdf page).
EditorCoreInfo _inlineNote(List<(Uint8List, int)> pages) {
  final core = EditorCoreInfo(filePath: '/test');
  final assets = <Uint8List>[];
  for (final page in pages) {
    var asset = assets.indexWhere((a) => identical(a, page.$1));
    if (asset < 0) {
      assets.add(page.$1);
      asset = assets.length - 1;
    }
    final index = core.pages.length;
    core.pages.add(
      EditorPage(
        pageId: 'p$index',
        backgroundImage: PdfEditorImage.fromJson(
          {
            'id': index,
            'a': asset,
            'pdfi': page.$2,
            'i': index,
            'nw': 100.0,
            'nh': 200.0,
          },
          inlineAssets: assets,
          sbnPath: '/test',
          assetCache: core.assetCache,
        ),
      ),
    );
  }
  return core;
}

OutlineRename _edit(
  String pageId,
  int depth,
  String original, {
  String? title,
  bool hidden = false,
}) => OutlineRename(
  pageId: pageId,
  depth: depth,
  originalTitle: original,
  title: title,
  hidden: hidden,
  updatedAt: DateTime.utc(2026, 11, 27),
);

List<String> _summary(List<PdfOutlineRow> rows) => [
  for (final r in rows)
    '${r.depth}|${r.title}|${r.pageId}|${r.pageIndex}|${r.renamed}',
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();

  test('rows follow the outline depth first and land on their pages', () {
    final note = _note([('/x/a.pdf', 0), ('/x/a.pdf', 1), ('/x/a.pdf', 2)]);
    final rows = mapOutlineToPages(
      {
        '/x/a.pdf': [
          _node('One', 1, [_node('One.a', 2), _node('One.b', 3)]),
          _node('Two', 3),
        ],
      },
      note,
      const [],
    );
    expect(_summary(rows), [
      '0|One|p0|0|false',
      '1|One.a|p1|1|false',
      '1|One.b|p2|2|false',
      '0|Two|p2|2|false',
    ]);
  });

  test('blank pages between PDF pages do not shift the mapping', () {
    final note = _note([('/x/a.pdf', 0), null, null, ('/x/a.pdf', 1)]);
    final rows = mapOutlineToPages(
      {
        '/x/a.pdf': [_node('Second', 2)],
      },
      note,
      const [],
    );
    expect(_summary(rows), ['0|Second|p3|3|false']);
  });

  test('two PDFs each map to their own pages, in note order', () {
    final note = _note([
      ('/x/b.pdf', 0),
      ('/x/a.pdf', 0),
      null,
      ('/x/b.pdf', 1),
      ('/x/a.pdf', 1),
    ]);
    final rows = mapOutlineToPages(
      {
        '/x/a.pdf': [_node('A1', 1), _node('A2', 2)],
        '/x/b.pdf': [_node('B1', 1), _node('B2', 2)],
      },
      note,
      const [],
    );
    expect(_summary(rows), [
      '0|B1|p0|0|false',
      '0|B2|p3|3|false',
      '0|A1|p1|1|false',
      '0|A2|p4|4|false',
    ]);
  });

  test('a PDF with no outline gives an empty list', () {
    final note = _note([('/x/a.pdf', 0)]);
    expect(mapOutlineToPages({'/x/a.pdf': []}, note, const []), isEmpty);
    expect(mapOutlineToPages(const {}, note, const []), isEmpty);
  });

  test('lines without a destination or without a note page are dropped', () {
    final note = _note([('/x/a.pdf', 0), ('/x/a.pdf', 1)]);
    final rows = mapOutlineToPages(
      {
        '/x/a.pdf': [
          _node('No dest', null, [_node('Kept child', 2)]),
          _node('Past the end', 9),
          _node('Zero', 0),
          _node('Fine', 1),
        ],
      },
      note,
      const [],
    );
    expect(_summary(rows), ['1|Kept child|p1|1|false', '0|Fine|p0|0|false']);
  });

  test('a rename changes the title, hidden removes the line', () {
    final note = _note([('/x/a.pdf', 0), ('/x/a.pdf', 1)]);
    final rows = mapOutlineToPages(
      {
        '/x/a.pdf': [
          _node('One', 1),
          _node('Two', 2, [_node('Two.a', 2)]),
          _node('Three', 2),
        ],
      },
      note,
      [
        _edit('p0', 0, 'One', title: 'First'),
        _edit('p1', 0, 'Two', hidden: true),
        _edit('p1', 1, 'Two.a'),
        // Wrong depth and wrong original title do not match.
        _edit('p1', 1, 'Three', title: 'Nope'),
        _edit('p1', 0, 'Other', title: 'Nope'),
      ],
    );
    expect(_summary(rows), [
      '0|First|p0|0|true',
      '1|Two.a|p1|1|false',
      '0|Three|p1|1|false',
    ]);
  });

  test('one inline PDF over several pages is one source, in outline order', () {
    final bytes = Uint8List.fromList([1, 2, 3]);
    final note = _inlineNote([(bytes, 0), (bytes, 1), (bytes, 2)]);
    final rows = mapOutlineToPages(
      {
        'inline_pdf_0.pdf': [_node('C', 3), _node('A', 1), _node('B', 2)],
      },
      note,
      const [],
    );
    expect(_summary(rows), [
      '0|C|p2|2|false',
      '0|A|p0|0|false',
      '0|B|p1|1|false',
    ]);
  });

  test('inline PDF copies with equal bytes are one source', () {
    final note = _inlineNote([
      (Uint8List.fromList([1, 2, 3]), 0),
      (Uint8List.fromList([1, 2, 3]), 1),
      (Uint8List.fromList([9, 9]), 0),
    ]);
    final rows = mapOutlineToPages(
      {
        'inline_pdf_0.pdf': [_node('A', 1), _node('B', 2)],
        'inline_pdf_2.pdf': [_node('Other', 1)],
      },
      note,
      const [],
    );
    expect(_summary(rows), [
      '0|A|p0|0|false',
      '0|B|p1|1|false',
      '0|Other|p2|2|false',
    ]);
  });

  test('a PDF whose file is missing is skipped without throwing', () async {
    final note = _note([('/no/such/dir/missing.pdf', 0)]);
    expect(await readPdfOutline(note, const []), isEmpty);
    note.dispose();
  });

  testWidgets('reads a real PDF outline through pdfrx', (tester) async {
    final document = pw.Document();
    for (var i = 0; i < 3; i++) {
      document.addPage(
        pw.Page(
          build: (_) => pw.Column(
            children: [
              pw.Outline(
                name: 'c$i',
                title: 'Chapter $i',
                level: 0,
                child: pw.Text('c$i'),
              ),
              if (i == 1)
                pw.Outline(
                  name: 's',
                  title: 'Section',
                  level: 1,
                  child: pw.Text('s'),
                ),
            ],
          ),
        ),
      );
    }
    final dir = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('pdf-outline-'),
    ))!;
    final file = File('${dir.path}/o.pdf');
    await tester.runAsync(() async => file.writeAsBytes(await document.save()));
    await withOfficePreviewPdfium(tester, () async {
      final note = _note([
        (file.path, 0),
        null,
        (file.path, 1),
        (file.path, 2),
      ]);
      try {
        final rows = (await tester.runAsync(
          () => readPdfOutline(note, const []),
        ))!;
        expect(_summary(rows), [
          '0|Chapter 0|p0|0|false',
          '0|Chapter 1|p2|2|false',
          '1|Section|p2|2|false',
          '0|Chapter 2|p3|3|false',
        ]);
      } finally {
        note.dispose();
      }
    });
    // pdfium has released the file once the helper has closed its documents.
    await tester.runAsync(() => dir.delete(recursive: true));
  }, skip: !officePreviewPdfiumAvailable);
}
