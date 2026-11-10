import 'dart:convert';
import 'dart:math' as math;

import 'package:characters/characters.dart';
import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:saber/data/vault/block_inline_text.dart';
import 'package:saber/data/vault/block_page_document.dart';
import 'package:saber/data/vault/block_page_table.dart';
import 'package:saber/data/vault/note_link.dart';
import 'package:saber/data/vault/portable_document_export.dart';
import 'package:saber/data/vault/workspace_database.dart';

final class PortablePdfResult {
  new(this.bytes, List<String> warnings)
    : warnings = List.unmodifiable(warnings);

  final Uint8List bytes;
  final List<String> warnings;
}

Future<PortablePdfResult> renderPortableDocumentPdf(
  PortableExportSource source, {
  ByteData? fontData,
}) async {
  final supplied =
      fontData ??
      await rootBundle.load('build/native/fonts/NotoSansKR-Portable.ttf');
  final bytes = ByteData.sublistView(
    Uint8List.fromList(
      supplied.buffer.asUint8List(
        supplied.offsetInBytes,
        supplied.lengthInBytes,
      ),
    ),
  );
  late TtfParser parsed;
  try {
    parsed = TtfParser(bytes);
    if (!parsed.unicode ||
        parsed.glyphOffsets.isEmpty ||
        !parsed.tableOffsets.containsKey(TtfParser.glyf_table) ||
        !parsed.tableOffsets.containsKey(TtfParser.loca_table) ||
        !parsed.charToGlyphIndexMap.containsKey('한'.runes.single)) {
      throw const FormatException(
        'The portable Korean TrueType font is unavailable',
      );
    }
  } on Object {
    throw const FormatException(
      'The portable Korean TrueType font could not be read',
    );
  }
  return _PortablePdfBuilder(source, pw.Font.ttf(bytes), parsed).render();
}

final class _PortablePdfBuilder {
  new(this.source, this.font, this.parsed)
    : files = source.page?.files ?? source.database!.files;

  final PortableExportSource source;
  final pw.Font font;
  final TtfParser parsed;
  final Map<String, Uint8List> files;
  final warnings = <String>{};
  final widgets = <pw.Widget>[];
  var spanningTableRows = 0;

  Future<PortablePdfResult> render() async {
    final document = pw.Document(
      title: source.title,
      creator: 'Personal Ink Vault',
      subject:
          'noteId=${source.noteId};bodyRevisionId=${source.bodyRevisionId};'
          'metadataRevisionIds=${source.metadataRevisionIds.join(',')}',
      theme: pw.ThemeData.withFont(
        base: font,
        bold: font,
        italic: font,
        boldItalic: font,
      ),
    );
    widgets.add(pw.Anchor(name: 'note-${source.noteId}', child: pw.SizedBox()));
    text(source.title, size: 21, bold: true);
    if (source.page case final page?) {
      blocks(page.document, page.document.blocks);
    } else {
      database(source.database!.database);
    }
    document.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(40),
        maxPages: widgets.length + spanningTableRows + 4,
        footer: (context) => pw.Text(
          '${context.pageNumber} / ${context.pagesCount}',
          style: pw.TextStyle(
            font: font,
            fontSize: 8,
            color: PdfColors.grey600,
          ),
          textAlign: pw.TextAlign.right,
        ),
        build: (_) => widgets,
      ),
    );
    return PortablePdfResult(await document.save(), warnings.toList());
  }

  String supported(String value) {
    final result = StringBuffer();
    for (final rune in value.runes) {
      if (rune == 10 ||
          rune == 13 ||
          rune == 9 ||
          (parsed.charToGlyphIndexMap[rune] ?? 0) != 0) {
        result.writeCharCode(rune);
      } else {
        final code = rune.toRadixString(16).toUpperCase().padLeft(4, '0');
        warnings.add('pdf.unsupported_glyph:U+$code');
        result.write('[U+$code]');
      }
    }
    return result.toString();
  }

  void text(
    String value, {
    double size = 11,
    bool bold = false,
    int depth = 0,
    bool code = false,
    String? destination,
    bool internal = false,
  }) {
    final normalized = supported(value)
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .replaceAll('\t', '    ');
    final chunkSize = math.max(40, (350 * 11 / size).floor());
    for (final line in normalized.split('\n')) {
      final runes = line.runes.toList();
      if (runes.isEmpty) {
        widgets.add(pw.SizedBox(height: size * .7));
        continue;
      }
      for (var offset = 0; offset < runes.length; offset += chunkSize) {
        pw.Widget child = pw.Text(
          String.fromCharCodes(runes.skip(offset).take(chunkSize)),
          style: pw.TextStyle(
            font: font,
            fontSize: size,
            fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
            color: destination == null ? PdfColors.grey900 : PdfColors.blue800,
            lineSpacing: 3,
          ),
        );
        if (destination != null) {
          child = internal
              ? pw.Link(destination: destination, child: child)
              : pw.UrlLink(destination: destination, child: child);
        }
        widgets.add(
          pw.Container(
            margin: const pw.EdgeInsets.only(bottom: 5),
            padding: pw.EdgeInsets.only(
              left: math.min(depth, 8) * 6.0,
              top: code ? 4 : 0,
              bottom: code ? 4 : 0,
            ),
            color: code ? PdfColors.grey100 : null,
            child: child,
          ),
        );
      }
    }
  }

  void blockText(
    BlockPageBlock block, {
    String prefix = '',
    double size = 11,
    bool bold = false,
    int depth = 0,
  }) {
    if (!_inlineBlockTypes.contains(block.type)) {
      unsupportedBlockInline(block);
      text('$prefix${block.text}', size: size, bold: bold, depth: depth);
      return;
    }
    final inline = block.inlineText;
    if (inline == null || inline.runs.isEmpty) {
      text('$prefix${block.text}', size: size, bold: bold, depth: depth);
      return;
    }
    final segments = [
      if (prefix.isNotEmpty) (text: prefix, marks: <InlineMark>{}, link: null),
      for (final segment in inline.segments)
        (text: segment.text, marks: segment.marks, link: segment.link),
    ];
    final chunkSize = math.max(40, (350 * 11 / size).floor());
    var spans = <pw.InlineSpan>[];
    var count = 0;
    void flush({bool emptyLine = false}) {
      if (spans.isEmpty) {
        if (emptyLine) widgets.add(pw.SizedBox(height: size * .7));
        return;
      }
      widgets.add(
        pw.Container(
          margin: const pw.EdgeInsets.only(bottom: 5),
          padding: pw.EdgeInsets.only(left: math.min(depth, 8) * 6.0),
          child: _PdfTextPaint(
            size: size,
            color: PdfColors.grey900,
            child: pw.RichText(
              text: pw.TextSpan(
                style: pw.TextStyle(font: font, fontSize: size, lineSpacing: 3),
                children: spans,
              ),
            ),
          ),
        ),
      );
      spans = <pw.InlineSpan>[];
      count = 0;
    }

    for (final segment in segments) {
      final normalized = supported(segment.text)
          .replaceAll('\r\n', '\n')
          .replaceAll('\r', '\n')
          .replaceAll('\t', '    ');
      var part = StringBuffer();
      void append() {
        if (part.isEmpty) return;
        spans.addAll(
          inlineSpans(
            part.toString(),
            segment.marks,
            segment.link,
            block.id,
            size,
            bold,
          ),
        );
        part = StringBuffer();
      }

      for (final character in normalized.characters) {
        if (character == '\n') {
          append();
          flush(emptyLine: true);
          continue;
        }
        final length = character.runes.length;
        if (count > 0 && count + length > chunkSize) {
          append();
          flush();
        }
        part.write(character);
        count += length;
      }
      append();
    }
    flush();
  }

  Iterable<pw.InlineSpan> inlineSpans(
    String value,
    Set<InlineMark> marks,
    String? link,
    String blockId,
    double size,
    bool blockBold,
  ) sync* {
    pw.AnnotationBuilder? annotation;
    if (link != null) {
      final note = NoteLink.parse(link);
      if (note != null) {
        if (note.noteId == source.noteId &&
            note.pageId == null &&
            note.markdownAnchor == null) {
          annotation = pw.AnnotationLink('note-${source.noteId}');
        } else {
          warnings.add('pdf.unresolved_document_link:$blockId:$link');
        }
      } else if (isSafeExternalLink(link)) {
        annotation = pw.AnnotationUrl(link);
      } else {
        warnings.add('pdf.unsupported_inline_link:$blockId');
      }
    }
    final code = marks.contains(InlineMark.code);
    final effectiveSize = code ? size * .95 : size;
    final color = annotation == null ? PdfColors.grey900 : PdfColors.blue800;
    final style = pw.TextStyle(
      font: font,
      fontSize: effectiveSize,
      color: color,
      lineSpacing: 3,
      renderingMode: blockBold || marks.contains(InlineMark.bold)
          ? PdfTextRenderingMode.fillAndStroke
          : PdfTextRenderingMode.fill,
      decoration: pw.TextDecoration.combine([
        if (marks.contains(InlineMark.underline)) pw.TextDecoration.underline,
        if (marks.contains(InlineMark.strikethrough))
          pw.TextDecoration.lineThrough,
      ]),
      background: marks.contains(InlineMark.highlight)
          ? const pw.BoxDecoration(color: PdfColors.yellow200)
          : code
          ? const pw.BoxDecoration(color: PdfColors.grey200)
          : null,
    );
    if (!marks.contains(InlineMark.italic)) {
      yield pw.TextSpan(text: value, style: style, annotation: annotation);
      return;
    }
    // The bundled font has one regular face. Shearing searchable glyphs keeps
    // Korean italics visible without substituting a font with missing glyphs.
    for (final character in value.characters) {
      yield pw.WidgetSpan(
        baseline: parsed.descent / parsed.unitsPerEm * effectiveSize,
        annotation: annotation,
        child: pw.Transform(
          transform: Matrix4.identity()..setEntry(0, 1, .18),
          alignment: pw.Alignment.bottomLeft,
          child: _PdfTextPaint(
            size: effectiveSize,
            color: color,
            child: pw.Text(character, style: style),
          ),
        ),
      );
    }
  }

  void blocks(
    BlockPageDocument page,
    List<BlockPageBlock> values, [
    int depth = 0,
  ]) {
    var numbered = 0;
    for (final block in values) {
      if (depth == 0 && block.isColumnLayout) {
        warnings.add('pdf.columns_flattened:${block.id}');
        for (final column in block.children) {
          blocks(page, column.children, depth);
        }
        numbered = 0;
        continue;
      }
      numbered = block.type == 'numbered' ? numbered + 1 : 0;
      final media = page.media[block.id];
      if (media != null) {
        if (block.type == 'image') {
          final width = math.min(420.0, media.width!.toDouble());
          final height = width * media.height! / media.width!;
          final scale = math.min(1.0, 300 / height);
          widgets.add(
            pw.Padding(
              padding: const pw.EdgeInsets.symmetric(vertical: 8),
              child: pw.Image(
                pw.MemoryImage(files[media.path]!),
                width: width * scale,
                height: height * scale,
              ),
            ),
          );
          if (block.text.isNotEmpty) blockText(block, depth: depth, size: 10);
        } else {
          warnings.add('pdf.attachment_not_embedded:${block.id}');
          text(
            media.name,
            depth: depth,
            destination: Uri(path: media.path).toString(),
          );
          if (block.text.isNotEmpty &&
              (block.text != media.name || block.inlineText != null)) {
            blockText(block, depth: depth);
          }
        }
      } else {
        switch (block.type) {
          case 'heading1':
            blockText(block, depth: depth, size: 18, bold: true);
          case 'heading2':
            blockText(block, depth: depth, size: 15, bold: true);
          case 'heading3':
            blockText(block, depth: depth, size: 13, bold: true);
          case 'todo':
            blockText(
              block,
              prefix: '[${block.checked ? 'x' : ' '}] ',
              depth: depth,
            );
          case 'bullet':
            blockText(block, prefix: '- ', depth: depth);
          case 'numbered':
            blockText(block, prefix: '$numbered. ', depth: depth);
          case 'quote':
            blockText(block, prefix: '> ', depth: depth + 1);
          case 'callout':
            blockText(block, prefix: '참고: ', depth: depth + 1);
          case 'toggle':
            blockText(block, prefix: '> ', depth: depth);
          case 'code':
            unsupportedBlockInline(block);
            text(block.text, depth: depth, size: 10, code: true);
          case 'equation':
            unsupportedBlockInline(block);
            warnings.add('pdf.equation_as_text:${block.id}');
            text(block.text, depth: depth, code: true);
          case 'divider':
            unsupportedBlockInline(block);
            widgets.add(pw.Divider(color: PdfColors.grey400));
          case 'documentLink':
            unsupportedBlockInline(block);
            if (block.noteId == source.noteId) {
              text(
                block.text.isEmpty ? source.title : block.text,
                depth: depth,
                destination: 'note-${source.noteId}',
                internal: true,
              );
            } else {
              warnings.add(
                'pdf.unresolved_document_link:${block.id}:${block.noteId}',
              );
              text('${block.text} (${block.noteId ?? ''})', depth: depth);
            }
          case 'linkedDatabase':
            unsupportedBlockInline(block);
            final linked = block.linkedDatabase;
            if (linked == null) {
              warnings.add('pdf.unknown_linked_database:${block.id}');
              blockText(block, depth: depth);
            } else {
              warnings.add(
                'pdf.linked_database_reference:${block.id}:${linked.noteId}',
              );
              text(
                '${block.text.isEmpty ? '연결된 데이터베이스' : block.text} (${linked.noteId})',
                depth: depth,
              );
            }
          case 'table':
            if (block.text.isNotEmpty) blockText(block, depth: depth);
            if (block.table case final table?) {
              tableBlock(table, block.id, depth);
            } else {
              warnings.add('pdf.unknown_table:${block.id}');
            }
          case 'paragraph':
            blockText(block, depth: depth);
          case 'link':
            unsupportedBlockInline(block);
            text(
              block.text,
              depth: depth,
              destination: isSafeExternalLink(block.text) ? block.text : null,
            );
          default:
            warnings.add('pdf.unknown_block:${block.id}:${block.type}');
            blockText(block, depth: depth);
        }
      }
      blocks(page, block.children, depth + 1);
    }
  }

  void unsupportedBlockInline(BlockPageBlock block) {
    if (block.inlineText?.runs.isNotEmpty == true) {
      warnings.add('pdf.unsupported_inline_block:${block.id}:${block.type}');
    }
  }

  bool narrow(List<List<String>> data) =>
      data.isNotEmpty &&
      data.first.length <= 5 &&
      data.every(
        (row) => row.every(
          (cell) => cell.runes.length <= 90 && '\n'.allMatches(cell).length < 3,
        ),
      );

  void tableBlock(BlockPageTable table, String id, int depth) {
    final data = [
      for (final row in table.rows)
        [for (final cell in row.cells) supported(cell.text)],
    ];
    if (narrow(data)) {
      spanningTableRows += data.length;
      widgets.add(
        pw.TableHelper.fromTextArray(
          data: data,
          headerCount: table.headerRow ? 1 : 0,
          cellStyle: pw.TextStyle(font: font, fontSize: 9),
          headerStyle: pw.TextStyle(
            font: font,
            fontSize: 9,
            fontWeight: pw.FontWeight.bold,
          ),
          defaultColumnWidth: const pw.FlexColumnWidth(),
          headerDecoration: const pw.BoxDecoration(color: PdfColors.grey200),
          cellPadding: const pw.EdgeInsets.all(4),
        ),
      );
      widgets.add(pw.SizedBox(height: 8));
      return;
    }
    warnings.add('pdf.table_as_records:$id');
    for (var r = 0; r < data.length; r++) {
      text(
        '행 ${r + 1}${table.headerRow && r == 0 ? ' (머리글)' : ''}',
        depth: depth,
        bold: true,
      );
      for (var c = 0; c < data[r].length; c++) {
        final label = table.headerRow && r > 0 && data.first[c].isNotEmpty
            ? data.first[c]
            : '열 ${c + 1}';
        text('$label: ${data[r][c]}', depth: depth + 1);
      }
    }
  }

  String cell(DatabaseProperty property, DatabaseRow row) {
    final evaluated = source.values[row.id]?[property.id];
    if (evaluated?.error case final error?) {
      warnings.add(
        'pdf.computed_value_error:${row.id}:${property.id}:${error.code}',
      );
      return '[${error.code}] ${error.message}';
    }
    if (property.isComputed && evaluated == null) {
      warnings.add('pdf.computed_value_missing:${row.id}:${property.id}');
      return '[계산 결과 없음]';
    }
    final value = evaluated?.value ?? row.values[property.id];
    if (property.type == 'relation' && value != null) {
      warnings.add('pdf.relation_as_identifiers:${row.id}:${property.id}');
    }
    if (value == null) return '';
    if (value is String) return value;
    if (value is bool) return value ? 'true' : 'false';
    return jsonEncode(value);
  }

  void database(WorkspaceDatabase database) {
    final data = [
      ['상태', for (final property in database.properties) property.name],
      for (final row in database.rows)
        [
          if (row.archived) '보관됨' else '현재',
          for (final property in database.properties) cell(property, row),
        ],
    ];
    if (narrow(data)) {
      spanningTableRows += data.length;
      widgets.add(
        pw.TableHelper.fromTextArray(
          data: [
            for (final row in data) [for (final value in row) supported(value)],
          ],
          headerCount: 1,
          cellStyle: pw.TextStyle(font: font, fontSize: 9),
          headerStyle: pw.TextStyle(
            font: font,
            fontSize: 9,
            fontWeight: pw.FontWeight.bold,
          ),
          defaultColumnWidth: const pw.FlexColumnWidth(),
          headerDecoration: const pw.BoxDecoration(color: PdfColors.grey200),
          cellPadding: const pw.EdgeInsets.all(4),
        ),
      );
      widgets.add(pw.SizedBox(height: 12));
    } else {
      warnings.add('pdf.database_as_records:${database.id}');
    }
    for (var i = 0; i < database.rows.length; i++) {
      final row = database.rows[i];
      text('행 ${i + 1}${row.archived ? ' (보관됨)' : ''}', size: 15, bold: true);
      for (var p = 0; p < database.properties.length; p++) {
        text('${database.properties[p].name}: ${data[i + 1][p + 1]}');
      }
      final page = BlockPageDocument.fromJson(row.body);
      blocks(page, page.blocks);
      widgets.add(pw.SizedBox(height: 10));
    }
  }
}

final class _PdfTextPaint extends pw.SingleChildWidget {
  new({required this.size, required this.color, required super.child});

  final double size;
  final PdfColor color;

  @override
  void paint(pw.Context context) {
    super.paint(context);
    context.canvas
      ..saveContext()
      ..setStrokeColor(color)
      ..setLineWidth(size * .025);
    paintChild(context);
    context.canvas.restoreContext();
  }
}

const _inlineBlockTypes = {
  'paragraph',
  'heading1',
  'heading2',
  'heading3',
  'todo',
  'bullet',
  'numbered',
  'quote',
  'callout',
  'toggle',
  'table',
  'image',
  'attachment',
};
