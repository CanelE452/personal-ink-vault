import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/office/hwp_office_engine.dart';
import 'package:saber/data/office/office_preview_engine.dart';
import 'package:saber/data/office/windows_office_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp, owned;
  late File source, pdf, unrelated;
  late String sourceHash, pdfHash;
  var releases = 0;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('office-preview-lease-');
    owned = await Directory('${temp.path}/owned-output').create();
    source = await File('${temp.path}/original.docx')
        .writeAsString('unchanged source');
    pdf = await File('${owned.path}/preview.pdf')
        .writeAsBytes(utf8.encode('%PDF-1.7\nowned preview fixture\n%%EOF\n'));
    unrelated = await File('${temp.path}/unrelated.pdf')
        .writeAsBytes(await pdf.readAsBytes());
    sourceHash = sha256.convert(await source.readAsBytes()).toString();
    pdfHash = sha256.convert(await pdf.readAsBytes()).toString();
    releases = 0;
  });
  tearDown(() async {
    if (temp.existsSync()) await temp.delete(recursive: true);
  });

  Map<String, dynamic> snapshot({String? path}) => {
    'kind': 'word',
    'sourceSha256': sourceHash,
    'paragraphs': [],
    'tables': [],
    'slides': [],
    'previewPdfPath': path ?? pdf.path,
    'previewPageCount': 1,
  };

  Future<void> release() async {
    releases++;
    if (owned.existsSync()) await owned.delete(recursive: true);
  }

  OfficePreviewEngine engine({
    bool hwp = false,
    Future<WindowsOfficeSnapshot> Function(String, bool)? inspect,
  }) {
    final callback =
        inspect ??
        (path, preview) async {
          expect(path, source.path);
          expect(preview, isTrue);
          return WindowsOfficeSnapshot.fromJson(
            snapshot(),
            onDisposePreview: release,
          );
        };
    return OfficePreviewEngine(
      isWindows: !hwp,
      isAndroid: false,
      windowsEngine: _InspectWindows(callback),
      hwpEngine: _InspectHwp(callback),
    );
  }

  for (final hwp in [false, true]) {
    test(
      '${hwp ? 'HWP' : 'Windows'} preview retains an explicitly owned output until idempotent release',
      () async {
        if (hwp) {
          source = await File('${temp.path}/original.hwpx')
              .writeAsString('unchanged source');
        }
        final modified = source.lastModifiedSync();
        final result = await engine(hwp: hwp)
            .preview(sourcePath: source.path, sessionId: 'owned-preview');
        expect(result, isNotNull);
        expect(result!.pdfPath, pdf.path);
        expect(result.pdfSha256, pdfHash);
        expect(pdf.existsSync(), isTrue);
        final copiedBytes = await pdf.readAsBytes();
        await Future.wait([result.dispose(), result.dispose()]);
        await result.dispose();
        expect(releases, 1);
        expect(owned.existsSync(), isFalse);
        expect(unrelated.existsSync(), isTrue);
        expect(sha256.convert(copiedBytes).toString(), pdfHash);
        expect(source.lastModifiedSync(), modified);
        expect(
          sha256.convert(await source.readAsBytes()).toString(),
          sourceHash,
        );
      },
    );
  }

  test('inspection ownership is released after PDF validation fails', () async {
    await pdf.writeAsString('not a PDF');
    await expectLater(
      engine().preview(sourcePath: source.path, sessionId: 'invalid-preview'),
      throwsA(
        isA<PlatformException>().having(
          (error) => error.code,
          'code',
          'invalid_office_preview',
        ),
      ),
    );
    expect(releases, 1);
    expect(owned.existsSync(), isFalse);
    expect(unrelated.existsSync(), isTrue);
    expect(sha256.convert(await source.readAsBytes()).toString(), sourceHash);
  });

  test('same-path rejection releases only the declared owned output', () async {
    final preview = engine(
      inspect: (_, _) async => WindowsOfficeSnapshot.fromJson(
        snapshot(path: source.path),
        onDisposePreview: release,
      ),
    );
    await expectLater(
      preview.preview(sourcePath: source.path, sessionId: 'same-path-preview'),
      throwsA(isA<PlatformException>()),
    );
    expect(releases, 1);
    expect(owned.existsSync(), isFalse);
    expect(source.existsSync(), isTrue);
    expect(unrelated.existsSync(), isTrue);
  });

  for (final changeBytes in [false, true]) {
    test(
      'source ${changeBytes ? 'bytes' : 'mtime'} failure in finally releases an otherwise valid preview',
      () async {
        final preview = engine(
          inspect: (_, _) async {
            if (changeBytes) {
              await source.writeAsString('changed by inspection');
            } else {
              await source.setLastModified(DateTime.utc(2000));
            }
            return WindowsOfficeSnapshot.fromJson(
              snapshot(),
              onDisposePreview: release,
            );
          },
        );
        await expectLater(
          preview.preview(
            sourcePath: source.path,
            sessionId: 'changed-source-preview',
          ),
          throwsA(
            isA<PlatformException>().having(
              (error) => error.code,
              'code',
              'preview_source_changed',
            ),
          ),
        );
        expect(releases, 1);
        expect(owned.existsSync(), isFalse);
        expect(unrelated.existsSync(), isTrue);
        if (changeBytes) {
          expect(await source.readAsString(), 'changed by inspection');
        } else {
          expect(source.lastModifiedSync().year, 2000);
        }
      },
    );
  }

  test('runner-provided preview paths never imply ownership', () async {
    final arbitrary = await Directory(
      '${temp.path}/personal-ink-vault-office-unowned',
    ).create();
    final externalPdf = await File('${arbitrary.path}/preview.pdf')
        .writeAsBytes(await unrelated.readAsBytes());
    final result = await OfficePreviewEngine(
      isWindows: true,
      isAndroid: false,
      windowsEngine: WindowsOfficeEngine(
        runner: (_) async => {'snapshot': snapshot(path: externalPdf.path)},
      ),
    ).preview(sourcePath: source.path, sessionId: 'unowned-runner-preview');
    await result!.dispose();
    await result.dispose();
    expect(externalPdf.existsSync(), isTrue);
    expect(arbitrary.existsSync(), isTrue);
    expect(source.existsSync(), isTrue);
    expect(releases, 0);
  });

  test('legacy fixture results have a no-op disposal', () async {
    final result = OfficePreviewResult(
      pdfPath: unrelated.path,
      pdfSha256: pdfHash,
      pageCount: 1,
      sourceSha256: sourceHash,
      engineVersion: 'fixture',
    );
    await result.dispose();
    await result.dispose();
    expect(unrelated.existsSync(), isTrue);
    expect(source.existsSync(), isTrue);
    expect(releases, 0);
  });
}

class _InspectWindows extends WindowsOfficeEngine {
  new(this.callback);
  final Future<WindowsOfficeSnapshot> Function(String, bool) callback;
  @override
  Future<bool> get available async => true;
  @override
  Future<WindowsOfficeSnapshot> inspect(
    String sourcePath, {
    bool preview = false,
  }) => callback(sourcePath, preview);
}

class _InspectHwp extends HwpStructuredOfficeEngine {
  new(this.callback);
  final Future<WindowsOfficeSnapshot> Function(String, bool) callback;
  @override
  Future<bool> get available async => true;
  @override
  Future<WindowsOfficeSnapshot> inspect(
    String sourcePath, {
    bool preview = false,
  }) => callback(sourcePath, preview);
  // HWP previews come from renderPdf; reuse the same owned-output fixture.
  @override
  Future<HwpPdfPreview> renderPdf(String sourcePath) async {
    final snapshot = await callback(sourcePath, true);
    final path = snapshot.previewPdfPath!;
    return (
      pdfPath: path,
      pdfSha256: sha256.convert(await File(path).readAsBytes()).toString(),
      pageCount: snapshot.previewPageCount!,
      sourceSha256: snapshot.sourceSha256,
      engineVersion: 'test-hwp',
      dispose: snapshot.disposePreview,
    );
  }
}
