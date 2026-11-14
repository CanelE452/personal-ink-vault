import 'dart:io';

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
  const session = 'caller-owned-preview';
  const source = '/private/original.docx';
  final calls = <MethodCall>[];

  Map<String, Object> valid() => {
    'status': 'previewed',
    'sessionId': session,
    'sourceSha256': 'a' * 64,
    'pdfSha256': 'b' * 64,
    'pdfPath': '/private/office-previews/random/preview.pdf',
    'pdfPageCount': 1,
    'engineVersion': '26.04.6.0-962',
  };

  setUp(calls.clear);
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'actual preview releases only the captured session once after consumption',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'preview') return valid();
        expect(call.method, 'releasePreview');
        expect(call.arguments, {'sessionId': session});
        return null;
      });
      final result = await engine.preview(
        sourcePath: source,
        sessionId: session,
      );
      expect(result!.pdfPath, '/private/office-previews/random/preview.pdf');
      expect(calls.map((call) => call.method), ['preview']);
      await Future.wait([result.dispose(), result.dispose()]);
      await result.dispose();
      expect(calls.map((call) => call.method), ['preview', 'releasePreview']);
      expect(calls.last.arguments, {'sessionId': session});
    },
  );

  test(
    'a rejected duplicate preview cannot delete the first ready PDF',
    () async {
      for (final code in ['office_busy', 'office_open_failed']) {
        calls.clear();
        final directory = await Directory.systemTemp.createTemp(
          'android-preview-owner-',
        );
        final pdf = File(p.join(directory.path, 'preview.pdf'));
        await pdf.writeAsString('%PDF owned first result');
        var requested = false;
        messenger.setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'preview') {
            if (requested) throw PlatformException(code: code);
            requested = true;
            return {...valid(), 'pdfPath': pdf.path};
          }
          expect(call.method, 'releasePreview');
          expect(call.arguments, {'sessionId': session});
          if (pdf.existsSync()) await pdf.delete();
          return null;
        });
        try {
          final first = (await engine.preview(
            sourcePath: source,
            sessionId: session,
          ))!;
          await expectLater(
            engine.preview(sourcePath: source, sessionId: session),
            throwsA(
              isA<PlatformException>().having(
                (error) => error.code,
                'code',
                code,
              ),
            ),
          );
          expect(calls.map((call) => call.method), ['preview', 'preview']);
          expect(await pdf.readAsString(), '%PDF owned first result');
          expect(first.sourceSha256, 'a' * 64);
          await first.dispose();
          await first.dispose();
          expect(pdf.existsSync(), isFalse);
          expect(calls.map((call) => call.method), [
            'preview',
            'preview',
            'releasePreview',
          ]);
        } finally {
          if (pdf.existsSync()) await pdf.delete();
          await directory.delete();
        }
      }
    },
  );

  test(
    'legacy const preview results have no native output ownership',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        fail(
          'A constructed legacy result must not infer ownership from its path',
        );
      });
      const result = AndroidOfficePreviewResult(
        sessionId: 'durable-edit',
        pdfPath: '/private/office-sessions/durable/preview.pdf',
        sourceSha256: 'legacy',
        pdfSha256: 'legacy',
        pageCount: 1,
        engineVersion: 'fixture',
      );
      await result.dispose();
      await result.dispose();
    },
  );

  test(
    'cancelled preview leaves native cleanup to its creating call',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'preview') return {'status': 'cancelled'};
        expect(call.arguments, {'sessionId': session});
        throw PlatformException(code: 'cleanup_failed');
      });
      expect(
        await engine.preview(sourcePath: source, sessionId: session),
        isNull,
      );
      expect(calls.map((call) => call.method), ['preview']);
    },
  );

  test('malformed or foreign results release caller identity and preserve the parse error', () async {
    for (final (malformed, granted) in [
      ({...valid(), 'sessionId': 'foreign-durable-edit'}, false),
      ({...valid(), 'pdfPageCount': 0}, true),
      ({...valid(), 'pdfPath': source}, false),
    ]) {
      calls.clear();
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'preview') return malformed;
        expect(call.method, 'releasePreview');
        expect(call.arguments, {'sessionId': session});
        throw PlatformException(code: 'cleanup_failed');
      });
      await expectLater(
        engine.preview(sourcePath: source, sessionId: session),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'invalid_office_preview',
          ),
        ),
      );
      expect(
        calls.map((call) => call.method),
        granted ? ['preview', 'releasePreview'] : ['preview'],
      );
      if (granted) expect(calls.last.arguments, {'sessionId': session});
    }
  });

  test('non-map preview messages cannot grant output ownership', () async {
    for (final response in [
      null,
      'foreign text',
      <Object?>[1, 2],
    ]) {
      calls.clear();
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return call.method == 'preview' ? response : null;
      });
      await expectLater(
        engine.preview(sourcePath: source, sessionId: session),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'invalid_office_preview',
          ),
        ),
      );
      expect(calls.map((call) => call.method), ['preview']);
    }
  });

  test('failed native preview does not release an existing result', () async {
    final original = PlatformException(
      code: 'office_interrupted',
      message: 'original failure',
    );
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'preview') throw original;
      expect(call.method, 'releasePreview');
      expect(call.arguments, {'sessionId': session});
      throw PlatformException(code: 'cleanup_failed');
    });
    await expectLater(
      engine.preview(sourcePath: source, sessionId: session),
      throwsA(
        isA<PlatformException>()
            .having((error) => error.code, 'code', 'office_interrupted')
            .having((error) => error.message, 'message', 'original failure'),
      ),
    );
    expect(calls.map((call) => call.method), ['preview']);
  });

  test(
    'release failure cannot turn a consumed successful preview into a failure',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'preview') return valid();
        throw PlatformException(code: 'locked_owned_output');
      });
      final result = await engine.preview(
        sourcePath: source,
        sessionId: session,
      );
      await result!.dispose();
      await result.dispose();
      expect(result.pageCount, 1);
      expect(calls.map((call) => call.method), ['preview', 'releasePreview']);
      expect(calls.last.arguments, {'sessionId': session});
    },
  );
}
