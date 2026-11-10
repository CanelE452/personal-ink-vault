import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:pdfrx/pdfrx.dart';

class PdfDocumentCache {
  new({this.useProgressiveLoading = true});

  final bool useProgressiveLoading;
  final Map<String, FutureOr<PdfDocument>> _cache = {};

  /// Loads a PDF document from [filePath].
  /// If the bytes are provided, they are used instead of reading from disk.
  FutureOr<PdfDocument> load(String filePath, {Uint8List? pdfBytes}) {
    return _cache[filePath] ??= _loadCacheMiss(filePath, pdfBytes: pdfBytes);
  }

  Future<PdfDocument> _loadCacheMiss(
    String filePath, {
    Uint8List? pdfBytes,
  }) async {
    final document = pdfBytes == null
        ? _openFile(filePath)
        : PdfDocument.openData(
            pdfBytes,
            useProgressiveLoading: useProgressiveLoading,
            sourceName: filePath,
          );
    _cache[filePath] = document;
    return document;
  }

  Future<PdfDocument> _openFile(String path) async {
    final file = File(path).absolute;
    if (!Platform.isWindows ||
        (file.path.length < 260 && file.path.codeUnits.every((c) => c < 128))) {
      return PdfDocument.openFile(
        path,
        useProgressiveLoading: useProgressiveLoading,
      );
    }

    // Use Dart file access when a path can exceed PDFium's Windows filename support.
    return PdfDocument.openCustom(
      fileSize: await file.length(),
      sourceName: path,
      read: (buffer, position, size) async {
        final source = await file.open();
        try {
          await source.setPosition(position);
          final count = await source.readInto(buffer, 0, size);
          return count == size ? count : 0;
        } finally {
          await source.close();
        }
      },
      useProgressiveLoading: useProgressiveLoading,
    );
  }

  void dispose() {
    for (final documentFuture in _cache.values) {
      Future.value(documentFuture).then<void>(
        (document) => document.dispose(),
        onError: (Object _, StackTrace _) {},
      );
    }
    _cache.clear();
  }
}
