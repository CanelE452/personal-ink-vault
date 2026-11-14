import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/office/android_office_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('personal_ink_vault/office_engine');
  const engine = AndroidOfficeEngine(channel: channel, isAndroid: true);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const sessionId = '11111111-1111-4111-8111-111111111111';
  final inputHash = 'a' * 64;
  final outputHash = 'b' * 64;
  final pdfHash = 'c' * 64;
  Map<String, dynamic> saved() => {
    'status': 'saved',
    'sessionId': sessionId,
    'inputSourceSha256': inputHash,
    'sourcePath': '/private/session/edited.docx',
    'pdfPath': '/private/session/preview.pdf',
    'sourceSha256': outputHash,
    'pdfSha256': pdfHash,
    'pdfPageCount': 2,
    'engineVersion': '26.04.6.0-962',
  };
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'legacy recovery sends the retained file binding and keeps native errors',
    () async {
      final path = p.absolute(
        '.workspace',
        'office-recovery',
        sessionId,
        sessionId,
        'native',
        'edited.doc',
      );
      var reject = false;
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'validateLegacySource');
        expect(call.arguments, {
          'sourcePath': path,
          'format': 'doc',
          'sourceSha256': outputHash,
        });
        if (reject) throw PlatformException(code: 'office_format_mismatch');
        return <String, Object>{};
      });
      Future<void> validate() => engine.validateLegacySource(
        sourcePath: path,
        format: 'doc',
        sourceSha256: outputHash,
      );
      await validate();
      reject = true;
      await expectLater(
        validate(),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'office_format_mismatch',
          ),
        ),
      );
    },
  );

  test('recover reports missing without supplying an arbitrary path', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'recover');
      expect(call.arguments, {
        'sessionId': sessionId,
        'inputSourceSha256': inputHash,
      });
      return {
        'status': 'missing',
        'sessionId': sessionId,
        'inputSourceSha256': inputHash,
        'engineVersion': '26.04.6.0-962',
      };
    });
    final result = await engine.recoverSession(
      sessionId: sessionId,
      inputSourceSha256: inputHash,
    );
    expect(result.status, AndroidOfficeRecoveryStatus.missing);
    expect(result.savedResult, isNull);
    expect(result.workingPath, isNull);
  });

  test(
    'recover distinguishes mutable working copy from a verified saved pair',
    () async {
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => {
          'status': 'working',
          'sessionId': sessionId,
          'inputSourceSha256': inputHash,
          'workingPath': '/private/session/working.docx',
          'workingSha256': outputHash,
          'engineVersion': '26.04.6.0-962',
        },
      );
      final working = await engine.recoverSession(
        sessionId: sessionId,
        inputSourceSha256: inputHash,
      );
      expect(working.status, AndroidOfficeRecoveryStatus.working);
      expect(working.workingSha256, outputHash);
      expect(working.inputSourceSha256, inputHash);
      expect(working.savedResult, isNull);
      messenger.setMockMethodCallHandler(channel, (_) async => saved());
      final result = await engine.recoverSession(
        sessionId: sessionId,
        inputSourceSha256: inputHash,
      );
      expect(result.status, AndroidOfficeRecoveryStatus.saved);
      expect(result.savedResult!.inputSourceSha256, inputHash);
      expect(result.savedResult!.sourceSha256, outputHash);
      expect(result.savedResult!.pdfSha256, pdfHash);
    },
  );

  test('resume uses only persisted session and original hash and validates saved binding', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'resume');
      expect(call.arguments, {
        'sessionId': sessionId,
        'inputSourceSha256': inputHash,
      });
      return saved();
    });
    final result = await engine.resumeSession(
      sessionId: sessionId,
      inputSourceSha256: inputHash,
    );
    expect(result.status, AndroidOfficeEditStatus.saved);
    expect(result.inputSourceSha256, inputHash);
    expect(result.sourcePath, '/private/session/edited.docx');
  });

  test('recovery rejects another session, input, partial result and unsafe response shapes', () async {
    final mutations = <Map<String, dynamic>>[
      {'sessionId': 'foreign'},
      {'inputSourceSha256': outputHash},
      {'engineVersion': ''},
      {'status': 'previewed'},
      {'pdfPath': '/private/session/edited.docx'},
      {'sourcePath': 'relative/edited.docx'},
      {'pdfSha256': 'bad'},
      {'pdfPageCount': 0},
      {'pdfPath': null},
      {'sourceSha256': null},
    ];
    for (final mutation in mutations) {
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => {...saved(), ...mutation},
      );
      await expectLater(
        engine.recoverSession(
          sessionId: sessionId,
          inputSourceSha256: inputHash,
        ),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'invalid_office_recovery',
          ),
        ),
      );
      await expectLater(
        engine.resumeSession(
          sessionId: sessionId,
          inputSourceSha256: inputHash,
        ),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'invalid_office_recovery',
          ),
        ),
      );
    }
    for (final path in ['working.docx', '/private/session/preview.pdf']) {
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => {
          'status': 'working',
          'sessionId': sessionId,
          'inputSourceSha256': inputHash,
          'workingPath': path,
          'workingSha256': outputHash,
          'engineVersion': '26.04.6.0-962',
        },
      );
      await expectLater(
        engine.recoverSession(
          sessionId: sessionId,
          inputSourceSha256: inputHash,
        ),
        throwsA(isA<PlatformException>()),
      );
    }
  });

  test(
    'invalid request and unsupported platform never reach native channel',
    () async {
      var calls = 0;
      messenger.setMockMethodCallHandler(channel, (_) async {
        calls++;
        return saved();
      });
      await expectLater(
        engine.recoverSession(sessionId: '', inputSourceSha256: inputHash),
        throwsArgumentError,
      );
      await expectLater(
        engine.resumeSession(sessionId: sessionId, inputSourceSha256: 'bad'),
        throwsArgumentError,
      );
      const unsupported = AndroidOfficeEngine(
        channel: channel,
        isAndroid: false,
      );
      await expectLater(
        unsupported.recoverSession(
          sessionId: sessionId,
          inputSourceSha256: inputHash,
        ),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'office_unavailable',
          ),
        ),
      );
      expect(calls, 0);
    },
  );

  test('legacy edit captures an optional validated original hash without changing preview', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => saved());
    final result = await engine.edit(
      sourcePath: '/private/original.docx',
      sessionId: sessionId,
    );
    expect(result.inputSourceSha256, inputHash);
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => {...saved(), 'inputSourceSha256': 'bad'},
    );
    await expectLater(
      engine.edit(sourcePath: '/private/original.docx', sessionId: sessionId),
      throwsA(isA<PlatformException>()),
    );
  });
}
