import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart' show PdfColors;
import 'package:pdfrx/pdfrx.dart';
import 'package:saber/pages/office/office_original_preview.dart';

import '../utils/office_preview.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> mount(WidgetTester tester, String key, Uint8List bytes) =>
      tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: OfficeOriginalPreview(
              key: const ValueKey('stable-preview-slot'),
              sourceKey: key,
              pdfBytes: bytes,
            ),
          ),
        ),
      );

  testWidgets(
    'original preview displays the actual first page and replaces its selected source',
    (tester) => withOfficePreviewPdfium(tester, () async {
      final red = await officePreviewRead(
        tester,
        () => officePreviewPdf(PdfColors.red, second: PdfColors.blue),
      );
      final blue = await officePreviewRead(
        tester,
        () => officePreviewPdf(PdfColors.blue),
      );
      await mount(tester, 'vault/note/red-revision/red-pdf-sha', red);
      await expectOfficePreviewColor(tester, red: true);
      expect(
        tester
            .widget<PdfPageView>(find.byType(PdfPageView))
            .document!
            .sourceName,
        'vault/note/red-revision/red-pdf-sha',
      );
      await mount(tester, 'vault/note/blue-revision/blue-pdf-sha', blue);
      await officePreviewUntil(
        tester,
        () =>
            find.byType(PdfPageView).evaluate().isNotEmpty &&
            tester
                    .widget<PdfPageView>(find.byType(PdfPageView))
                    .document!
                    .sourceName ==
                'vault/note/blue-revision/blue-pdf-sha',
        'Changing the source must replace the old PDF document',
      );
      await expectOfficePreviewColor(tester, red: false);
      expect(tester.takeException(), isNull);
    }),
    skip: !officePreviewPdfiumAvailable,
  );

  testWidgets(
    'original preview has finite dimensions at phone width',
    (tester) => withOfficePreviewPdfium(tester, () async {
      await tester.binding.setSurfaceSize(const Size(320, 760));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final bytes = await officePreviewRead(
        tester,
        () => officePreviewPdf(PdfColors.red),
      );
      await mount(tester, 'phone-preview', bytes);
      await expectOfficePreviewColor(tester, red: true);
      final size = tester.getSize(find.byType(PdfPageView));
      expect(size.width, inInclusiveRange(1, 320));
      expect(size.height, inInclusiveRange(1, 440));
      expect(tester.takeException(), isNull);
    }),
    skip: !officePreviewPdfiumAvailable,
  );

  testWidgets(
    'a damaged PDF shows a preview error instead of a stale document',
    (tester) => withOfficePreviewPdfium(tester, () async {
      final bytes = await officePreviewRead(
        tester,
        () => officePreviewPdf(PdfColors.red),
      );
      await mount(tester, 'valid-preview', bytes);
      await expectOfficePreviewColor(tester, red: true);
      await mount(tester, 'damaged-preview', Uint8List.fromList([1, 2, 3]));
      await officePreviewUntil(
        tester,
        () => find
            .byKey(const ValueKey('office-original-preview-error'))
            .evaluate()
            .isNotEmpty,
        'The damaged PDF must produce a usable error message',
      );
      expect(find.byType(PdfPageView), findsNothing);
      expect(tester.takeException(), isNull);
    }),
    skip: !officePreviewPdfiumAvailable,
  );

  for (final replace in [false, true]) {
    testWidgets(
      'a late opened PDF is disposed after ${replace ? 'source replacement' : 'unmount'}',
      (tester) => withOfficePreviewPdfium(tester, () async {
        final red = await officePreviewRead(
          tester,
          () => officePreviewPdf(PdfColors.red),
        );
        final blue = await officePreviewRead(
          tester,
          () => officePreviewPdf(PdfColors.blue),
        );
        final originalBackend = PdfrxEntryFunctions.instance;
        final backend = _DelayedOpen(originalBackend, 'delayed-old-source');
        PdfrxEntryFunctions.instance = backend;
        try {
          await mount(tester, 'delayed-old-source', red);
          await officePreviewUntil(
            tester,
            () => backend.opened.isCompleted,
            'The old PDF must be opened but not delivered to the widget',
          );
          expect(find.byType(PdfPageView), findsNothing);
          if (replace) {
            await mount(tester, 'replacement-source', blue);
            await expectOfficePreviewColor(tester, red: false);
          } else {
            await tester.pumpWidget(const SizedBox());
          }
          backend.release.complete();
          await officePreviewUntil(
            tester,
            () => backend.document?.disposed == true,
            'A PDF that opens after its owner closes must be disposed',
          );
          expect(backend.document!.disposeCalls, 1);
          if (replace) {
            expect(
              tester
                  .widget<PdfPageView>(find.byType(PdfPageView))
                  .document!
                  .sourceName,
              'replacement-source',
            );
            await expectOfficePreviewColor(tester, red: false);
          }
          expect(tester.takeException(), isNull);
        } finally {
          if (!backend.release.isCompleted) backend.release.complete();
          await tester.pumpWidget(const SizedBox());
          if (backend.document != null) {
            await officePreviewUntil(
              tester,
              () => backend.document!.disposed,
              'The retained native test document must be released',
            );
          }
          PdfrxEntryFunctions.instance = originalBackend;
        }
      }),
      skip: !officePreviewPdfiumAvailable,
    );
  }
}

class _DelayedOpen implements PdfrxEntryFunctions {
  new(this.actual, this.delayedSource);
  final PdfrxEntryFunctions actual;
  final String delayedSource;
  final opened = Completer<void>();
  final release = Completer<void>();
  OfficePreviewTrackedDocument? document;

  @override
  Future<PdfDocument> openData(
    Uint8List data, {
    PdfPasswordProvider? passwordProvider,
    bool firstAttemptByEmptyPassword = true,
    String? sourceName,
    bool allowDataOwnershipTransfer = false,
    bool useProgressiveLoading = false,
    void Function()? onDispose,
  }) async {
    final value = await actual.openData(
      data,
      passwordProvider: passwordProvider,
      firstAttemptByEmptyPassword: firstAttemptByEmptyPassword,
      sourceName: sourceName,
      allowDataOwnershipTransfer: allowDataOwnershipTransfer,
      useProgressiveLoading: useProgressiveLoading,
      onDispose: onDispose,
    );
    if (sourceName != delayedSource) return value;
    document = OfficePreviewTrackedDocument(value);
    opened.complete();
    await release.future;
    return document!;
  }

  @override
  Future<R> compute<M, R>(FutureOr<R> Function(M) callback, M message) =>
      actual.compute(callback, message);
  @override
  Future<T> suspendPdfiumWorkerDuringAction<T>(FutureOr<T> Function() action) =>
      actual.suspendPdfiumWorkerDuringAction(action);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
