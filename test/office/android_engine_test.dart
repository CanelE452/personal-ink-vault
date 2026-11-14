import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/office/android_office_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('personal_ink_vault/office_engine');
  const engine = AndroidOfficeEngine(channel: channel, isAndroid: true);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));
  test('dedicated Android preview accepts a PDF-only result without requiring a changed Office original', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'preview');
      expect(call.arguments, {
        'sourcePath': '/private/source.docx',
        'sessionId': 'p1',
      });
      return {
        'status': 'previewed',
        'sessionId': 'p1',
        'sourceSha256': 'a' * 64,
        'pdfSha256': 'b' * 64,
        'pdfPath': '/private/preview.pdf',
        'pdfPageCount': 2,
        'engineVersion': '26.04.6.0-962',
      };
    });
    final result = await engine.preview(
      sourcePath: '/private/source.docx',
      sessionId: 'p1',
    );
    expect(result!.sourceSha256, 'a' * 64);
    expect(result.pageCount, 2);
  });
  test('Android preview rejects another session and an output that overwrites its source', () async {
    for (final wrongSession in [true, false]) {
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => {
          'status': 'previewed',
          'sessionId': wrongSession ? 'other' : 'p1',
          'sourceSha256': 'a' * 64,
          'pdfSha256': 'b' * 64,
          'pdfPath': wrongSession
              ? '/private/preview.pdf'
              : '/private/source.docx',
          'pdfPageCount': 1,
          'engineVersion': '26.04.6.0-962',
        },
      );
      await expectLater(
        engine.preview(sourcePath: '/private/source.docx', sessionId: 'p1'),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'invalid_office_preview',
          ),
        ),
      );
    }
  });
}
