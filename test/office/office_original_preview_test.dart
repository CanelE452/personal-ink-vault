import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart' show PdfColor, PdfColors, PdfPageFormat;
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfrx/pdfrx.dart';
import 'package:saber/pages/office/office_original_preview.dart';

bool get officePreviewPdfiumAvailable =>
    Platform.isWindows &&
    File('build/windows/x64/runner/Release/pdfium.dll').existsSync();

Future<Uint8List> officePreviewPdf(PdfColor first, {PdfColor? second}) async {
  final document = pw.Document();
  for (final color in [first, ?second]) {
    document.addPage(
      pw.Page(
        pageFormat: const PdfPageFormat(200, 300),
        margin: pw.EdgeInsets.zero,
        build: (_) => pw.Container(width: 200, height: 300, color: color),
      ),
    );
  }
  return document.save();
}

Future<void> officePreviewUntil(
  WidgetTester tester,
  bool Function() ready,
  String reason,
) async {
  for (var i = 0; i < 400 && !ready(); i++) {
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(ready(), isTrue, reason: reason);
}

Future<T> officePreviewRead<T>(
  WidgetTester tester,
  Future<T> Function() operation,
) async {
  var done = false;
  T? result;
  Object? failure;
  StackTrace? trace;
  await tester.runAsync(() async {
    operation().then(
      (value) {
        result = value;
        done = true;
      },
      onError: (Object error, StackTrace stack) {
        failure = error;
        trace = stack;
        done = true;
      },
    );
  });
  await officePreviewUntil(tester, () => done, 'The preview I/O must finish');
  if (failure != null) Error.throwWithStackTrace(failure!, trace!);
  return result as T;
}

Future<void> withOfficePreviewPdfium(
  WidgetTester tester,
  Future<void> Function() body,
) async {
  final temporary = (await tester.runAsync(
    () => Directory.systemTemp.createTemp('office-original-render-'),
  ))!;
  final previous = Pdfrx.pdfiumModulePath;
  final previousBackend = PdfrxEntryFunctions.instance;
  final documents = OfficePreviewDocumentTracker(previousBackend);
  try {
    await tester.runAsync(() async {
      Pdfrx.pdfiumModulePath = File(
        'build/windows/x64/runner/Release/pdfium.dll',
      ).absolute.path;
      await pdfrxInitialize(tmpPath: temporary.path);
    });
    PdfrxEntryFunctions.instance = documents;
    await body();
  } finally {
    await tester.pumpWidget(const SizedBox());
    try {
      await officePreviewDocumentsClosed(tester);
    } finally {
      PdfrxEntryFunctions.instance = previousBackend;
      Pdfrx.pdfiumModulePath = previous;
    }
    await tester.runAsync(() => temporary.delete(recursive: true));
  }
}

Future<void> officePreviewDocumentsClosed(WidgetTester tester) async {
  final backend = PdfrxEntryFunctions.instance;
  expect(backend, isA<OfficePreviewDocumentTracker>());
  final documents = backend as OfficePreviewDocumentTracker;
  await officePreviewUntil(
    tester,
    () => documents.pendingOpens == 0 && documents.allClosed,
    'Every opened PDF must finish its actual native dispose before fixture deletion',
  );
}

Future<void> expectOfficePreviewColor(
  WidgetTester tester, {
  required bool red,
}) async {
  await officePreviewUntil(
    tester,
    () => find.byType(PdfPageView).evaluate().isNotEmpty,
    'The original first page must be displayed by the PDF renderer',
  );
  final view = tester.widget<PdfPageView>(find.byType(PdfPageView));
  expect(view.pageNumber, 1);
  final document = view.document!;
  final expected = red ? PdfColors.red : PdfColors.blue;
  final expectedRed = (expected.red * 255).round();
  final expectedGreen = (expected.green * 255).round();
  final expectedBlue = (expected.blue * 255).round();
  final count = await officePreviewRead(tester, () async {
    final image = (await document.pages.first.render(
      width: 80,
      height: 120,
      fullWidth: 80,
      fullHeight: 120,
    ))!;
    try {
      var pixels = 0;
      final bytes = image.pixels;
      for (var i = 0; i < bytes.length; i += 4) {
        final blue = bytes[i], green = bytes[i + 1], r = bytes[i + 2];
        if ((r - expectedRed).abs() <= 3 &&
            (green - expectedGreen).abs() <= 3 &&
            (blue - expectedBlue).abs() <= 3 &&
            bytes[i + 3] >= 250)
          pixels++;
      }
      return pixels;
    } finally {
      image.dispose();
    }
  });
  expect(count, greaterThan(8000));
}

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
  _TrackedDocument? document;

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
    document = _TrackedDocument(value);
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

class _TrackedDocument implements PdfDocument {
  new(this.actual);
  final PdfDocument actual;
  var disposed = false;
  var disposeCalls = 0;
  @override
  String get sourceName => actual.sourceName;
  @override
  List<PdfPage> get pages => actual.pages;
  @override
  set pages(List<PdfPage> value) => actual.pages = value;
  @override
  Stream<PdfDocumentEvent> get events => actual.events;
  @override
  PdfPermissions? get permissions => actual.permissions;
  @override
  bool get isEncrypted => actual.isEncrypted;
  @override
  Future<void> loadPagesProgressively<T>({
    PdfPageLoadingCallback<T>? onPageLoadProgress,
    T? data,
    Duration loadUnitDuration = const Duration(milliseconds: 250),
  }) => actual.loadPagesProgressively(
    onPageLoadProgress: onPageLoadProgress,
    data: data,
    loadUnitDuration: loadUnitDuration,
  );
  @override
  Future<List<PdfOutlineNode>> loadOutline() => actual.loadOutline();
  @override
  bool isIdenticalDocumentHandle(Object? other) =>
      actual.isIdenticalDocumentHandle(
        other is _TrackedDocument ? other.actual : other,
      );
  @override
  Future<bool> assemble() => actual.assemble();
  @override
  Future<Uint8List> encodePdf({
    bool incremental = false,
    bool removeSecurity = false,
  }) => actual.encodePdf(
    incremental: incremental,
    removeSecurity: removeSecurity,
  );
  @override
  Future<T> useNativeDocumentHandle<T>(FutureOr<T> Function(int) task) =>
      actual.useNativeDocumentHandle(task);
  @override
  Future<void> reloadPages({List<int>? pageNumbersToReload}) =>
      actual.reloadPages(pageNumbersToReload: pageNumbersToReload);
  @override
  PdfFontManagerAssociation associateFontManager(
    PdfFontManager fontManager, {
    PdfFontLoadResultCallback? onLoadComplete,
    PdfFontLoadProgressCallback? onProgress,
  }) => actual.associateFontManager(
    fontManager,
    onLoadComplete: onLoadComplete,
    onProgress: onProgress,
  );
  @override
  Future<void> dispose() async {
    disposeCalls++;
    await actual.dispose();
    disposed = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class OfficePreviewDocumentTracker implements PdfrxEntryFunctions {
  new(this.actual);
  final PdfrxEntryFunctions actual;
  final List<_TrackedDocument> _documents = [];
  final List<String> filePaths = [];
  var pendingOpens = 0;
  bool get allClosed => _documents.every((document) => document.disposed);

  Future<PdfDocument> _observe(Future<PdfDocument> Function() open) async {
    pendingOpens++;
    try {
      final document = _TrackedDocument(await open());
      _documents.add(document);
      return document;
    } finally {
      pendingOpens--;
    }
  }

  @override
  Future<PdfDocument> openFile(
    String filePath, {
    PdfPasswordProvider? passwordProvider,
    bool firstAttemptByEmptyPassword = true,
    bool useProgressiveLoading = false,
  }) {
    filePaths.add(filePath);
    return _observe(
      () => actual.openFile(
        filePath,
        passwordProvider: passwordProvider,
        firstAttemptByEmptyPassword: firstAttemptByEmptyPassword,
        useProgressiveLoading: useProgressiveLoading,
      ),
    );
  }

  @override
  Future<PdfDocument> openCustom({
    required FutureOr<int> Function(Uint8List, int, int) read,
    required int fileSize,
    required String sourceName,
    PdfPasswordProvider? passwordProvider,
    bool firstAttemptByEmptyPassword = true,
    bool useProgressiveLoading = false,
    int? maxSizeToCacheOnMemory,
    void Function()? onDispose,
  }) {
    filePaths.add(sourceName);
    return _observe(
      () => actual.openCustom(
        read: read,
        fileSize: fileSize,
        sourceName: sourceName,
        passwordProvider: passwordProvider,
        firstAttemptByEmptyPassword: firstAttemptByEmptyPassword,
        useProgressiveLoading: useProgressiveLoading,
        maxSizeToCacheOnMemory: maxSizeToCacheOnMemory,
        onDispose: onDispose,
      ),
    );
  }

  @override
  Future<PdfDocument> openData(
    Uint8List data, {
    PdfPasswordProvider? passwordProvider,
    bool firstAttemptByEmptyPassword = true,
    String? sourceName,
    bool allowDataOwnershipTransfer = false,
    bool useProgressiveLoading = false,
    void Function()? onDispose,
  }) => _observe(
    () => actual.openData(
      data,
      passwordProvider: passwordProvider,
      firstAttemptByEmptyPassword: firstAttemptByEmptyPassword,
      sourceName: sourceName,
      allowDataOwnershipTransfer: allowDataOwnershipTransfer,
      useProgressiveLoading: useProgressiveLoading,
      onDispose: onDispose,
    ),
  );

  @override
  Future<void> init() => actual.init();
  @override
  Future<R> compute<M, R>(FutureOr<R> Function(M) callback, M message) =>
      actual.compute(callback, message);
  @override
  Future<T> suspendPdfiumWorkerDuringAction<T>(FutureOr<T> Function() action) =>
      actual.suspendPdfiumWorkerDuringAction(action);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
