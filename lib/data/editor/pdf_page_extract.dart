import 'dart:typed_data';

import 'package:logging/logging.dart';
import 'package:pdfrx/pdfrx.dart';

final _log = Logger('extractPdfPage');

/// Cuts page [pageIndex] (0-based) out of [pdf] into a new one-page PDF.
/// Returns null on any failure so the caller can fall back to the whole PDF.
Future<Uint8List?> extractPdfPage(Uint8List pdf, int pageIndex) async {
  PdfDocument? source;
  PdfDocument? target;
  try {
    source = await PdfDocument.openData(pdf, sourceName: 'extractPdfPage');
    if (pageIndex < 0 || pageIndex >= source.pages.length) return null;
    target = await PdfDocument.createNew(sourceName: 'extractPdfPage');
    target.pages = [source.pages[pageIndex]];
    return await target.encodePdf();
  } catch (error, stack) {
    _log.warning('could not extract page $pageIndex', error, stack);
    return null;
  } finally {
    await _disposeQuietly(target);
    await _disposeQuietly(source);
  }
}

Future<void> _disposeQuietly(PdfDocument? document) async {
  try {
    await document?.dispose();
  } catch (error, stack) {
    _log.warning('could not dispose a pdf document', error, stack);
  }
}
