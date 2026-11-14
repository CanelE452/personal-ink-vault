import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/office/android_office_engine.dart';
import 'package:saber/data/office/hwp_office_engine.dart';
import 'package:saber/data/office/office_preview_engine.dart';
import 'package:saber/data/office/windows_office_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late File source, pdf;
  late String originalHash, pdfHash;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('office-preview-');
    source = await File('${temp.path}/original.docx')
        .writeAsString('unchanged source');
    pdf = await File('${temp.path}/preview.pdf')
        .writeAsBytes(utf8.encode('%PDF-1.7\npreview fixture\n%%EOF\n'));
    originalHash = sha256.convert(await source.readAsBytes()).toString();
    pdfHash = sha256.convert(await pdf.readAsBytes()).toString();
  });
  tearDown(() => temp.delete(recursive: true));
  Map<String, dynamic> snapshot(String hash) => {
    'kind': 'word',
    'sourceSha256': hash,
    'paragraphs': [],
    'tables': [],
    'slides': [],
    'previewPdfPath': pdf.path,
    'previewPageCount': 1,
  };

  test('Windows preview invokes inspection only and verifies the unchanged original and physical PDF', () async {
    final modified = source.lastModifiedSync();
    final engine = OfficePreviewEngine(
      isWindows: true,
      isAndroid: false,
      windowsEngine: WindowsOfficeEngine(
        runner: (request) async {
          expect(request['mode'], 'inspect');
          expect(request['preview'], true);
          expect(request.containsKey('operations'), isFalse);
          return {'snapshot': snapshot(originalHash)};
        },
      ),
    );
    final result = await engine.preview(
      sourcePath: source.path,
      sessionId: 'preview-1',
    );
    expect(result!.pdfSha256, pdfHash);
    expect(result.sourceSha256, originalHash);
    expect(result.pageCount, 1);
    expect(source.lastModifiedSync(), modified);
    expect(sha256.convert(await source.readAsBytes()).toString(), originalHash);
  });

  test(
    'a preview that changes source bytes or modification time is rejected',
    () async {
      for (final changeBytes in [true, false]) {
        final engine = OfficePreviewEngine(
          isWindows: true,
          isAndroid: false,
          windowsEngine: WindowsOfficeEngine(
            runner: (_) async {
              if (changeBytes)
                await source.writeAsString('changed');
              else
                await source.setLastModified(DateTime.utc(2000));
              return {'snapshot': snapshot(originalHash)};
            },
          ),
        );
        await expectLater(
          engine.preview(sourcePath: source.path, sessionId: 'preview-1'),
          throwsA(
            isA<PlatformException>().having(
              (e) => e.code,
              'code',
              'preview_source_changed',
            ),
          ),
        );
        await source.writeAsString('unchanged source');
      }
    },
  );

  test('an invalid PDF payload and same-path output are rejected before any canonical save', () async {
    final engine = OfficePreviewEngine(
      isWindows: true,
      isAndroid: false,
      windowsEngine: WindowsOfficeEngine(
        runner: (_) async => {'snapshot': snapshot(originalHash)},
      ),
    );
    await pdf.writeAsString('not a PDF');
    await expectLater(
      engine.preview(sourcePath: source.path, sessionId: 'preview-1'),
      throwsA(
        isA<PlatformException>().having(
          (e) => e.code,
          'code',
          'invalid_office_preview',
        ),
      ),
    );
    final overwrite = OfficePreviewEngine(
      isWindows: true,
      isAndroid: false,
      windowsEngine: WindowsOfficeEngine(
        runner: (_) async => {
          'snapshot': {
            ...snapshot(originalHash),
            'previewPdfPath': source.path,
          },
        },
      ),
    );
    await expectLater(
      overwrite.preview(sourcePath: source.path, sessionId: 'preview-1'),
      throwsA(
        isA<PlatformException>().having(
          (e) => e.code,
          'code',
          'invalid_office_preview',
        ),
      ),
    );
  });

  test('HWP renders a separate rhwp PDF without the structured editor inspection and retains physical hash checks', () async {
    source = await source.rename('${temp.path}/original.hwp');
    final engine = OfficePreviewEngine(
      isWindows: false,
      isAndroid: true,
      hwpEngine: HwpStructuredOfficeEngine(
        runner: (request) async {
          expect(request['mode'], 'pdf');
          expect(request.containsKey('preview'), isFalse);
          return {
            'status': 'previewed',
            'sourceSha256': originalHash,
            'pdfPath': pdf.path,
            'pdfSha256': pdfHash,
            'pdfPageCount': 1,
            'engineVersion': 'ink_hwp_native/0.1.0+rhwp.0.9.0',
          };
        },
      ),
    );
    final result = await engine.preview(
      sourcePath: source.path,
      sessionId: 'hwp-preview',
    );
    expect(result!.sourceSha256, originalHash);
    expect(result.pdfSha256, pdfHash);
    expect(result.engineVersion, 'piv-preview-v2/ink_hwp_native/0.1.0+rhwp.0.9.0');
  });

  test('HWP PDF whose bytes differ from the native hash is rejected', () async {
    source = await source.rename('${temp.path}/original.hwpx');
    final engine = OfficePreviewEngine(
      isWindows: true,
      isAndroid: false,
      hwpEngine: HwpStructuredOfficeEngine(
        runner: (_) async => {
          'status': 'previewed',
          'sourceSha256': originalHash,
          'pdfPath': pdf.path,
          'pdfSha256': '0' * 64,
          'pdfPageCount': 1,
          'engineVersion': 'ink_hwp_native/0.1.0+rhwp.0.9.0',
        },
      ),
    );
    await expectLater(
      engine.preview(sourcePath: source.path, sessionId: 'hwp-mismatch'),
      throwsA(
        isA<WindowsOfficeException>().having(
          (error) => error.code,
          'code',
          'invalid_preview',
        ),
      ),
    );
  });

  test('Android dedicated preview cancellation has no PDF or source revision to import', () async {
    const channel = MethodChannel('personal_ink_vault/office_engine');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'preview');
          return {'status': 'cancelled'};
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final engine = OfficePreviewEngine(
      isWindows: false,
      isAndroid: true,
      androidEngine: const AndroidOfficeEngine(
        channel: channel,
        isAndroid: true,
      ),
    );
    expect(
      await engine.preview(
        sourcePath: source.path,
        sessionId: 'android-preview',
      ),
      isNull,
    );
  });
}
