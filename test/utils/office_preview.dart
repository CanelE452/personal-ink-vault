/// Test helpers for Office previews and PDF rendering, shared by the Office, vault and workspace
/// tests. They used to live in office_original_preview_test.dart, so other tests imported a test file.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart' show PdfColor, PdfColors, PdfPageFormat;
import 'package:pdf/widgets.dart' as pw;
import 'package:pdfrx/pdfrx.dart';

/// The PDF renderer is only available on Windows once a release build has put pdfium.dll in place.
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

/// A PDF document that records its native dispose.
class OfficePreviewTrackedDocument implements PdfDocument {
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
        other is OfficePreviewTrackedDocument ? other.actual : other,
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

/// The PDF backend for a test: opens through [actual] and remembers every document it opened, so
/// a test can wait until all of them are disposed before deleting its files.
class OfficePreviewDocumentTracker implements PdfrxEntryFunctions {
  new(this.actual);
  final PdfrxEntryFunctions actual;
  final List<OfficePreviewTrackedDocument> _documents = [];
  final List<String> filePaths = [];
  var pendingOpens = 0;
  bool get allClosed => _documents.every((document) => document.disposed);

  Future<PdfDocument> _observe(Future<PdfDocument> Function() open) async {
    pendingOpens++;
    try {
      final document = OfficePreviewTrackedDocument(await open());
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
