import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:logging/logging.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:saber/components/canvas/image/editor_image.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/vault/note_page_marks.dart';

final _log = Logger('PdfOutline');

/// One line of a PDF's outline, tied to the note page that shows its PDF page.
class PdfOutlineRow {
  const new({
    required this.title,
    required this.depth,
    required this.pageId,
    required this.pageIndex,
    required this.renamed,
  });

  /// The title to show: the user's own if renamed, else the PDF's.
  final String title;
  final int depth;
  final String pageId;

  /// The note page, counted from 0.
  final int pageIndex;
  final bool renamed;
}

/// The PDF outlines of [note], one row per outline line that leads to a page of the note.
/// [edits] are applied as given: a renamed line shows the new title, a hidden line is left out.
/// A PDF whose outline cannot be read is skipped.
Future<List<PdfOutlineRow>> readPdfOutline(
  EditorCoreInfo note,
  List<OutlineRename> edits,
) async {
  final sources = _pdfSources(note);
  final nodesPerPdf = <String, List<PdfOutlineNode>>{};
  for (final entry in sources.entries) {
    final PdfDocument document;
    try {
      document = await note.assetCache.pdfDocumentCache.load(
        entry.key,
        pdfBytes: entry.value.bytes,
      );
    } catch (error, stackTrace) {
      _log.warning('Could not open ${entry.key}', error, stackTrace);
      continue;
    }
    try {
      nodesPerPdf[entry.key] = await document.loadOutline();
    } catch (error, stackTrace) {
      _log.warning(
        'Could not read the outline of ${entry.key}',
        error,
        stackTrace,
      );
    }
  }
  return mapOutlineToPages(nodesPerPdf, note, edits);
}

/// Ties outline [nodesPerPdf] (keyed as the note's PDF cache names each PDF) to the note's pages.
/// PDFs come in the order their first page appears in the note; lines keep their outline order.
List<PdfOutlineRow> mapOutlineToPages(
  Map<String, List<PdfOutlineNode>> nodesPerPdf,
  EditorCoreInfo note,
  List<OutlineRename> edits,
) {
  final changes = {
    for (final edit in edits)
      _editKey(edit.pageId, edit.depth, edit.originalTitle): edit,
  };
  final rows = <PdfOutlineRow>[];
  for (final entry in _pdfSources(note).entries) {
    final nodes = nodesPerPdf[entry.key];
    if (nodes == null) continue;
    void walk(List<PdfOutlineNode> level, int depth) {
      for (final node in level) {
        final pageNumber = node.dest?.pageNumber;
        final pageIndex = pageNumber == null
            ? null
            : entry.value.firstNotePage[pageNumber - 1];
        if (pageIndex != null) {
          final pageId = note.pages[pageIndex].pageId;
          final edit = changes[_editKey(pageId, depth, node.title)];
          if (edit == null || !edit.hidden) {
            final title = edit?.title;
            rows.add(
              PdfOutlineRow(
                title: title ?? node.title,
                depth: depth,
                pageId: pageId,
                pageIndex: pageIndex,
                renamed: title != null,
              ),
            );
          }
        }
        walk(node.children, depth + 1);
      }
    }

    walk(nodes, 0);
  }
  return rows;
}

String _editKey(String pageId, int depth, String title) =>
    '$pageId\u0000$depth\u0000$title';

class _PdfSource {
  Uint8List? bytes;
  Digest? _digest;
  final firstNotePage = <int, int>{};

  Digest get digest => _digest ??= sha256.convert(bytes!);
}

/// The note's PDFs by cache name, in note order, each with its first note page per PDF page.
/// A PDF with a file is named by its path. A PDF inside the note is one source per bytes object
/// (or per equal bytes), named like the editor names it: after the first image that holds it.
Map<String, _PdfSource> _pdfSources(EditorCoreInfo note) {
  final sources = <String, _PdfSource>{};
  final inline = <_PdfSource>[];
  final inlineKeys = <_PdfSource, String>{};
  for (var index = 0; index < note.pages.length; index++) {
    final image = note.pages[index].backgroundImage;
    if (image is! PdfEditorImage) continue;
    final file = image.pdfFile;
    final _PdfSource source;
    if (file != null) {
      source = sources.putIfAbsent(file.path, _PdfSource.new);
    } else {
      final bytes = image.pdfBytes;
      var found = inline.where((s) => identical(s.bytes, bytes)).firstOrNull;
      if (found == null && bytes != null) {
        Digest? digest;
        found = inline.where((s) {
          final other = s.bytes;
          if (other == null || other.length != bytes.length) return false;
          return s.digest == (digest ??= sha256.convert(bytes));
        }).firstOrNull;
      }
      if (found == null) {
        found = _PdfSource()..bytes = bytes;
        inline.add(found);
        inlineKeys[found] = 'inline_pdf_${image.id}.pdf';
        sources[inlineKeys[found]!] = found;
      }
      source = found;
    }
    source.bytes ??= image.pdfBytes;
    source.firstNotePage.putIfAbsent(image.pdfPage, () => index);
  }
  return sources;
}
