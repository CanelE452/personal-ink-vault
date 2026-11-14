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

  test('capabilities keep modern HWP separate from Office formats', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => {
        'available': true,
        'engineVersion': '26.04.6.0-962',
        'editableFormats': ['docx', 'pptx'],
        'supportsHwp': false,
        'supportsHwpx': false,
      },
    );
    final result = await engine.capabilities();
    expect(result.available, true);
    expect(result.editableFormats, contains('pptx'));
    expect(result.supportsHwp, false);
    expect(result.supportsHwpx, false);
  });

  test(
    'saved edit requires separate original and PDF with verified metadata',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'edit');
        expect(call.arguments, {
          'sourcePath': '/cache/materialized.pptx',
          'sessionId': 's1',
        });
        return {
          'status': 'saved',
          'sessionId': 's1',
          'engineVersion': '26.04.6.0-962',
          'sourcePath': '/files/office-sessions/uuid/edited.pptx',
          'pdfPath': '/files/office-sessions/uuid/preview.pdf',
          'sourceSha256': 'a' * 64,
          'pdfSha256': 'b' * 64,
          'pdfPageCount': 3,
        };
      });
      final result = await engine.edit(
        sourcePath: '/cache/materialized.pptx',
        sessionId: 's1',
      );
      expect(result.status, AndroidOfficeEditStatus.saved);
      expect(result.pdfPageCount, 3);
      expect(result.sourcePath, endsWith('edited.pptx'));
    },
  );

  test(
    'PDF-only or overwriting the supplied original cannot claim saved',
    () async {
      for (final source in [null, '/cache/materialized.docx']) {
        messenger.setMockMethodCallHandler(
          channel,
          (_) async => {
            'status': 'saved',
            'sessionId': 's1',
            'engineVersion': '26.04.6.0-962',
            'sourcePath': source,
            'pdfPath': '/preview.pdf',
            'sourceSha256': 'a' * 64,
            'pdfSha256': 'b' * 64,
            'pdfPageCount': 1,
          },
        );
        await expectLater(
          engine.edit(sourcePath: '/cache/materialized.docx', sessionId: 's1'),
          throwsA(
            isA<PlatformException>().having(
              (e) => e.code,
              'code',
              'invalid_office_result',
            ),
          ),
        );
      }
    },
  );

  test('cancelled edit has no importable revision', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => {'status': 'cancelled'},
    );
    final result = await engine.edit(
      sourcePath: '/cache/materialized.docx',
      sessionId: 's1',
    );
    expect(result.status, AndroidOfficeEditStatus.cancelled);
    expect(result.sourcePath, isNull);
    expect(result.pdfPath, isNull);
  });

  test(
    'mismatched session result cannot be imported into another document',
    () async {
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => {
          'status': 'saved',
          'sessionId': 'other',
          'engineVersion': '26.04.6.0-962',
          'sourcePath': '/edited.docx',
          'pdfPath': '/preview.pdf',
          'sourceSha256': 'a' * 64,
          'pdfSha256': 'b' * 64,
          'pdfPageCount': 1,
        },
      );
      await expectLater(
        engine.edit(sourcePath: '/cache/materialized.docx', sessionId: 's1'),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'invalid_office_result',
          ),
        ),
      );
    },
  );
}
