import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart' show PdfPageFormat;
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfrx/pdfrx.dart';
import 'package:saber/data/editor/pdf_page_extract.dart';

import '../utils/office_preview.dart' show officePreviewPdfiumAvailable;

Future<Uint8List> _threePagePdf() {
  final document = pw.Document();
  for (final word in ['alpha', 'beta', 'gamma']) {
    document.addPage(
      pw.Page(
        pageFormat: const PdfPageFormat(200, 300),
        build: (_) => pw.Text(word),
      ),
    );
  }
  return document.save();
}

/// Loads pdfium directly; the tracker in office_preview.dart does not forward
/// PdfDocument.createNew.
Future<void> _withPdfium(
  WidgetTester tester,
  Future<void> Function() body,
) async {
  final temporary = (await tester.runAsync(
    () => Directory.systemTemp.createTemp('pdf-page-extract-'),
  ))!;
  final previous = Pdfrx.pdfiumModulePath;
  try {
    await tester.runAsync(() async {
      Pdfrx.pdfiumModulePath = File(
        'build/windows/x64/runner/Release/pdfium.dll',
      ).absolute.path;
      await pdfrxInitialize(tmpPath: temporary.path);
      await body();
    });
  } finally {
    Pdfrx.pdfiumModulePath = previous;
    await tester.runAsync(() => temporary.delete(recursive: true));
  }
}

void main() {
  testWidgets('extracts one page from a three page pdf', (tester) async {
    await _withPdfium(tester, () async {
      final source = await _threePagePdf();
      final one = await extractPdfPage(source, 1);
      expect(one, isNotNull);
      expect(one!.length, lessThan(source.length));
      final reopened = await PdfDocument.openData(one);
      try {
        expect(reopened.pages.length, 1);
        final text = (await reopened.pages[0].loadText())!.fullText;
        expect(text, contains('beta'));
        expect(text, isNot(contains('alpha')));
        expect(text, isNot(contains('gamma')));
      } finally {
        await reopened.dispose();
      }
    });
  }, skip: !officePreviewPdfiumAvailable);

  testWidgets('returns null for bytes that are not a pdf', (tester) async {
    Future<void> check() async {
      expect(await extractPdfPage(Uint8List.fromList([1, 2, 3]), 0), isNull);
    }

    if (officePreviewPdfiumAvailable) {
      await _withPdfium(tester, check);
    } else {
      await tester.runAsync(check);
    }
  });

  testWidgets('returns null for a page past the end', (tester) async {
    Future<void> check() async {
      final source = await _threePagePdf();
      expect(await extractPdfPage(source, 3), isNull);
      expect(await extractPdfPage(source, -1), isNull);
    }

    if (officePreviewPdfiumAvailable) {
      await _withPdfium(tester, check);
    } else {
      await tester.runAsync(check);
    }
  });
}
