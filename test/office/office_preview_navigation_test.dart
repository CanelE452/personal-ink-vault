import 'dart:typed_data';
import 'dart:ui' show ImageByteFormat;

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart' show PdfColor, PdfColors;
import 'package:pdfrx/pdfrx.dart';
import 'package:saber/pages/office/office_original_preview.dart';

import 'office_original_preview_test.dart'
    show
        officePreviewPdf,
        officePreviewPdfiumAvailable,
        officePreviewRead,
        officePreviewUntil,
        withOfficePreviewPdfium;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Office preview navigates pages and returns from fullscreen',
    (tester) => withOfficePreviewPdfium(tester, () async {
      final size = defaultTargetPlatform == TargetPlatform.android
          ? const Size(360, 720)
          : const Size(1000, 800);
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final original = await officePreviewRead(
        tester,
        () => officePreviewPdf(PdfColors.red, second: PdfColors.blue),
      );
      final replacement = await officePreviewRead(
        tester,
        () => officePreviewPdf(PdfColors.green, second: PdfColors.red),
      );

      final changedPages = <int>[];
      final annotatedPages = <int>[];
      Future<void> mount(
        String sourceKey,
        Uint8List bytes, {
        int initialPage = 1,
      }) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: OfficeOriginalPreview(
              key: const ValueKey('stable-navigation-preview'),
              sourceKey: sourceKey,
              pdfBytes: bytes,
              presentation: defaultTargetPlatform == TargetPlatform.android,
              initialPage: initialPage,
              onPageChanged: changedPages.add,
              onAnnotatePage: annotatedPages.add,
            ),
          ),
        ),
      );

      final preview = find.byType(PdfPageView);
      const originalSource = 'vault/note/office-revision/preview-pdf';
      const replacementSource = 'vault/note/next-office-revision/preview-pdf';
      final next = find.byKey(const ValueKey('office-preview-next'));
      final previous = find.byKey(const ValueKey('office-preview-previous'));
      final fullscreen = find.byKey(
        const ValueKey('office-preview-fullscreen'),
      );
      final close = find.byKey(const ValueKey('office-preview-close'));
      final jump = find.byKey(const ValueKey('office-preview-jump'));
      final annotate = find.byKey(
        const ValueKey('office-preview-annotate-page'),
      );

      Future<void> expectPage(
        int number,
        PdfColor color,
        String source, {
        bool isFullscreen = false,
      }) async {
        final current = isFullscreen
            ? find.descendant(
                of: find.ancestor(of: close, matching: find.byType(Scaffold)),
                matching: preview,
              )
            : preview;
        final raster = find.descendant(
          of: current,
          matching: find.byType(RawImage),
        );
        await officePreviewUntil(
          tester,
          () {
            if (current.evaluate().length != 1 ||
                raster.evaluate().length != 1 ||
                close.evaluate().length != (isFullscreen ? 1 : 0)) {
              return false;
            }
            final view = tester.widget<PdfPageView>(current);
            return view.pageNumber == number &&
                view.document?.sourceName == source &&
                tester.widget<RawImage>(raster).image != null;
          },
          'The renderer must show page $number of $source (fullscreen=$isFullscreen)',
        );
        final image = tester.widget<RawImage>(raster).image!;
        final rgba = (await officePreviewRead(
          tester,
          () => image.toByteData(format: ImageByteFormat.rawRgba),
        ))!;
        final center =
            ((image.height ~/ 2) * image.width + image.width ~/ 2) * 4;
        expect(rgba.getUint8(center), closeTo(color.red * 255, 3));
        expect(rgba.getUint8(center + 1), closeTo(color.green * 255, 3));
        expect(rgba.getUint8(center + 2), closeTo(color.blue * 255, 3));
        expect(rgba.getUint8(center + 3), greaterThanOrEqualTo(250));
      }

      await mount(originalSource, original);
      await expectPage(1, PdfColors.red, originalSource);
      expect(changedPages, isEmpty);
      expect(next, findsOneWidget);
      await tester.tap(next);
      await expectPage(2, PdfColors.blue, originalSource);
      expect(changedPages, [2]);
      expect(find.byTooltip('현재 쪽에 필기'), findsOneWidget);
      await tester.tap(annotate);
      expect(annotatedPages, [2]);

      await tester.tap(fullscreen);
      await expectPage(2, PdfColors.blue, originalSource, isFullscreen: true);
      await tester.pump(const Duration(milliseconds: 450));
      await tester.pump();
      expect(annotate, findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await expectPage(1, PdfColors.red, originalSource, isFullscreen: true);
      await tester.binding.handlePopRoute();
      await expectPage(1, PdfColors.red, originalSource);
      expect(changedPages, [2, 1]);

      await tester.tap(fullscreen);
      await expectPage(1, PdfColors.red, originalSource, isFullscreen: true);
      await tester.pump(const Duration(milliseconds: 450));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await expectPage(2, PdfColors.blue, originalSource, isFullscreen: true);
      await tester.tap(close);
      await expectPage(2, PdfColors.blue, originalSource);
      expect(changedPages, [2, 1, 2]);
      await mount(originalSource, original, initialPage: -7);
      await expectPage(2, PdfColors.blue, originalSource);

      await tester.tap(jump);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.text(
          defaultTargetPlatform == TargetPlatform.android
              ? '슬라이드로 이동'
              : '페이지로 이동',
        ),
        findsOneWidget,
      );
      final number = find.byType(TextFormField);
      await tester.enterText(number, '3');
      await tester.tap(find.text('이동'));
      await tester.pump();
      expect(find.text('1부터 2 사이의 번호를 입력하세요.'), findsOneWidget);
      await tester.enterText(number, '1');
      await tester.tap(find.text('이동'));
      await expectPage(1, PdfColors.red, originalSource);
      await tester.fling(preview, const Offset(-200, 0), 1000);
      await expectPage(2, PdfColors.blue, originalSource);

      await mount(replacementSource, replacement, initialPage: 1000);
      await expectPage(2, PdfColors.red, replacementSource);
      await tester.tap(annotate);
      expect(annotatedPages, [2, 2]);
      expect(changedPages, [2, 1, 2, 1, 2]);
      await tester.tap(previous);
      await expectPage(1, PdfColors.green, replacementSource);
      await tester.tap(next);
      await expectPage(2, PdfColors.red, replacementSource);

      await mount(
        'vault/note/damaged-office-revision/preview-pdf',
        Uint8List(3),
      );
      final error = find.byKey(const ValueKey('office-original-preview-error'));
      await officePreviewUntil(
        tester,
        () => error.evaluate().isNotEmpty,
        'A damaged replacement must show a preview error',
      );
      expect(preview, findsNothing);
      expect(next, findsNothing);
      expect(annotate, findsNothing);
      await mount(originalSource, original, initialPage: 0);
      await expectPage(1, PdfColors.red, originalSource);
      expect(changedPages, [2, 1, 2, 1, 2, 1, 2]);
      expect(tester.takeException(), isNull);
    }),
    skip: !officePreviewPdfiumAvailable,
    variant: const TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.windows,
    }),
  );
}
