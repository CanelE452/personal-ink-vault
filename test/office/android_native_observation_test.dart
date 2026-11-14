import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
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
  const session = '70bf425f-c413-457a-82cc-119c3f6cc8ae';
  late Directory requestDirectory;
  late String source, inputHash, previewHash;
  late File previewFile, observationFile;
  const pdfText = '%PDF-1.7\n1 0 obj\n<<>>\nendobj\n%%EOF\n';
  final defaultNativeJson = jsonEncode({
    'slides': [
      {'name': '한글 😀', 'index': 0, 'objects': <Object?>[]},
    ],
  });
  final calls = <MethodCall>[];

  Map<String, dynamic> valid({String? nativeJson}) {
    final json = nativeJson ?? defaultNativeJson;
    final bytes = utf8.encode(json);
    return {
      'status': 'inspected',
      'sessionId': session,
      'sourceSha256': inputHash,
      'pdfSha256': previewHash,
      'pdfPath': previewFile.path,
      'pdfPageCount': 1,
      'engineVersion': '26.04.6.0-962',
      'format': 'pptx',
      'observationPath': observationFile.path,
      'observationSha256': crypto.sha256.convert(bytes).toString(),
      'observationByteLength': bytes.length,
      'partCount': 1,
      'nativeJson': json,
    };
  }

  Future<AndroidOfficeNativeObservationResult?> inspect() =>
      engine.inspectPresentation(
        sourcePath: source,
        sessionId: session,
        inputSourceSha256: inputHash,
      );

  Matcher invalid() => isA<PlatformException>().having(
    (error) => error.code,
    'code',
    'invalid_office_observation',
  );

  setUp(() async {
    calls.clear();
    requestDirectory = await Directory.systemTemp.createTemp(
      'android-observation-request-',
    );
    final sourceFile = File(p.join(requestDirectory.path, 'original.pptx'));
    await sourceFile.writeAsString('synthetic original presentation');
    source = sourceFile.path;
    inputHash = crypto.sha256
        .convert(await sourceFile.readAsBytes())
        .toString();
    final output = await Directory(
      p.join(requestDirectory.path, 'office-previews', 'random'),
    ).create(recursive: true);
    previewFile = File(p.join(output.path, 'preview.pdf'));
    observationFile = File(p.join(output.path, 'native-observation.json'));
    await previewFile.writeAsString(pdfText);
    previewHash = crypto.sha256
        .convert(await previewFile.readAsBytes())
        .toString();
    await observationFile.writeAsString(defaultNativeJson);
  });
  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    if (requestDirectory.existsSync()) {
      await requestDirectory.delete(recursive: true);
    }
  });

  test(
    'inspection sends a closed request and keeps one owned preview lease',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'inspect') {
          expect(call.arguments, {
            'sourcePath': source,
            'sessionId': session,
            'inputSourceSha256': inputHash,
          });
          return valid();
        }
        expect(call.method, 'releasePreview');
        expect(call.arguments, {'sessionId': session});
        return null;
      });
      final result = (await inspect())!;
      expect(result.sessionId, session);
      expect(result.sourceSha256, inputHash);
      expect(result.format, 'pptx');
      expect(result.partCount, 1);
      expect(result.pageCount, 1);
      expect(result.nativeInfo['slides'], [
        {'name': '한글 😀', 'index': 0, 'objects': <Object?>[]},
      ]);
      expect(result.sourceTableEditingSupported, isFalse);
      expect(result.cellTextEditingSupported, isFalse);
      expect(calls.map((call) => call.method), ['inspect']);
      await Future.wait([result.dispose(), result.dispose()]);
      await result.dispose();
      expect(calls.map((call) => call.method), ['inspect', 'releasePreview']);
    },
  );

  test(
    'a rejected duplicate inspection cannot delete the first ready result',
    () async {
      for (final code in ['office_busy', 'invalid_office_observation']) {
        calls.clear();
        final directory = await Directory.systemTemp.createTemp(
          'android-observation-owner-',
        );
        final pdf = File(p.join(directory.path, 'preview.pdf'));
        final observation = File(
          p.join(directory.path, 'native-observation.json'),
        );
        final native = valid()['nativeJson'] as String;
        await pdf.writeAsString(pdfText);
        await observation.writeAsString(native);
        var requested = false;
        messenger.setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'inspect') {
            if (requested) throw PlatformException(code: code);
            requested = true;
            return {
              ...valid(),
              'pdfPath': pdf.path,
              'observationPath': observation.path,
            };
          }
          expect(call.method, 'releasePreview');
          expect(call.arguments, {'sessionId': session});
          if (pdf.existsSync()) await pdf.delete();
          if (observation.existsSync()) await observation.delete();
          return null;
        });
        try {
          final first = (await inspect())!;
          await expectLater(
            inspect(),
            throwsA(
              isA<PlatformException>().having(
                (error) => error.code,
                'code',
                code,
              ),
            ),
          );
          expect(calls.map((call) => call.method), ['inspect', 'inspect']);
          expect(pdf.existsSync(), isTrue);
          expect(await observation.readAsString(), native);
          expect(first.sourceSha256, inputHash);
          expect(first.nativeInfo['slides'], [
            {'name': '한글 😀', 'index': 0, 'objects': <Object?>[]},
          ]);
          await first.dispose();
          await first.dispose();
          expect(pdf.existsSync(), isFalse);
          expect(observation.existsSync(), isFalse);
          expect(calls.map((call) => call.method), [
            'inspect',
            'inspect',
            'releasePreview',
          ]);
        } finally {
          if (pdf.existsSync()) await pdf.delete();
          if (observation.existsSync()) await observation.delete();
          await directory.delete();
        }
      }
    },
  );

  test(
    'native information is recursively immutable and has no edit authority',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return call.method == 'inspect' ? valid() : null;
      });
      final result = (await inspect())!;
      expect(
        () => result.nativeInfo['injected'] = true,
        throwsUnsupportedError,
      );
      final slides = result.nativeInfo['slides'] as List;
      expect(() => slides.add({}), throwsUnsupportedError);
      final slide = slides.single as Map;
      expect(() => slide['name'] = 'mutated', throwsUnsupportedError);
      expect(result.sourceTableEditingSupported, isFalse);
      await result.dispose();
    },
  );

  test('foreign envelopes do not grant a lease and owned malformed data is released', () async {
    final changes = <({Map<String, dynamic> fields, bool granted})>[
      (fields: {'status': 'previewed'}, granted: false),
      (
        fields: {'sessionId': '4cc6fb56-5965-4613-8a01-6a074d30120d'},
        granted: false,
      ),
      (fields: {'sourceSha256': 'c' * 64}, granted: false),
      (fields: {'format': 'docx'}, granted: false),
      (fields: {'partCount': 0}, granted: true),
      (fields: {'partCount': 257}, granted: true),
      (fields: {'partCount': 1.0}, granted: true),
      (fields: {'pdfPageCount': 0}, granted: true),
      (fields: {'pdfPath': source}, granted: false),
      (
        fields: {'pdfPath': '/private/office-previews/foreign/preview.pdf'},
        granted: false,
      ),
      (
        fields: {
          'observationPath':
              '/private/office-previews/foreign/native-observation.json',
        },
        granted: false,
      ),
      (
        fields: {
          'observationPath': '/private/office-previews/random/../random/native-observation.json',
        },
        granted: false,
      ),
      (
        fields: {
          'observationPath': '/private/office-previews/random/foreign.json',
        },
        granted: false,
      ),
      (fields: {'observationSha256': 'c' * 64}, granted: true),
      (fields: {'observationByteLength': 1}, granted: true),
      (fields: {'observationByteLength': 1.0}, granted: true),
      (fields: {'engineVersion': ''}, granted: true),
      (fields: {'sourceTableEditingSupported': true}, granted: true),
      (fields: {'cellTextEditingSupported': true}, granted: true),
    ];
    for (final change in changes) {
      calls.clear();
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return call.method == 'inspect' ? {...valid(), ...change.fields} : null;
      });
      await expectLater(inspect(), throwsA(invalid()));
      expect(
        calls.map((call) => call.method),
        change.granted ? ['inspect', 'releasePreview'] : ['inspect'],
      );
      if (change.granted) expect(calls.last.arguments, {'sessionId': session});
    }
  });

  test('non-map inspection messages cannot grant output ownership', () async {
    for (final response in [
      null,
      'foreign text',
      <Object?>[1, 2],
    ]) {
      calls.clear();
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return call.method == 'inspect' ? response : null;
      });
      await expectLater(inspect(), throwsA(invalid()));
      expect(calls.map((call) => call.method), ['inspect']);
    }
  });

  test(
    'byte budget measures UTF8 bytes instead of UTF16 character count',
    () async {
      final tooLarge = jsonEncode({'name': '한' * 50000});
      expect(tooLarge.length, lessThan(128 * 1024));
      expect(utf8.encode(tooLarge).length, greaterThan(128 * 1024));
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return call.method == 'inspect' ? valid(nativeJson: tooLarge) : null;
      });
      await expectLater(inspect(), throwsA(invalid()));
      expect(calls.map((call) => call.method), ['inspect', 'releasePreview']);
    },
  );

  test(
    'malformed deep nonfinite and oversized native JSON fail closed',
    () async {
      final nativeValues = [
        '[]',
        '{}',
        '{"broken":',
        '{"v":1e999}',
        '{"v":"${'x' * 16385}"}',
        '{"v":${'[' * 20}0${']' * 20}}',
        jsonEncode({'v': List.filled(5000, 0)}),
        r'{"v":"\ud800"}',
      ];
      for (final native in nativeValues) {
        calls.clear();
        messenger.setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return call.method == 'inspect' ? valid(nativeJson: native) : null;
        });
        await expectLater(inspect(), throwsA(invalid()));
        expect(calls.map((call) => call.method), ['inspect', 'releasePreview']);
      }
    },
  );

  test('cancelled and failed requests do not infer a result lease', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'inspect') {
        return {'status': 'cancelled', 'sessionId': session};
      }
      throw PlatformException(code: 'cleanup_failure');
    });
    expect(await inspect(), isNull);
    expect(calls.map((call) => call.method), ['inspect']);

    calls.clear();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'inspect') {
        throw PlatformException(
          code: 'office_native_observation_unsupported',
          message: 'original unsupported result',
        );
      }
      throw PlatformException(code: 'cleanup_failure');
    });
    await expectLater(
      inspect(),
      throwsA(
        isA<PlatformException>()
            .having(
              (error) => error.code,
              'code',
              'office_native_observation_unsupported',
            )
            .having(
              (error) => error.message,
              'message',
              'original unsupported result',
            ),
      ),
    );
    expect(calls.map((call) => call.method), ['inspect']);
  });

  test(
    'owned JSON rejection keeps the parse error if its release fails',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'inspect') {
          return valid(nativeJson: '{"broken":');
        }
        throw PlatformException(code: 'cleanup_failure');
      });
      await expectLater(inspect(), throwsA(invalid()));
      expect(calls.map((call) => call.method), ['inspect', 'releasePreview']);
      expect(calls.last.arguments, {'sessionId': session});
    },
  );

  test('invalid requests never dispatch or infer output ownership', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      fail('No native call should be dispatched for a rejected request');
    });
    for (final request in [
      (
        sourcePath: '/private/original.docx',
        sessionId: session,
        hash: inputHash,
      ),
      (sourcePath: 'relative.pptx', sessionId: session, hash: inputHash),
      (sourcePath: source, sessionId: 'not-a-session-id', hash: inputHash),
      (sourcePath: source, sessionId: session, hash: 'invalid'),
    ]) {
      await expectLater(
        engine.inspectPresentation(
          sourcePath: request.sourcePath,
          sessionId: request.sessionId,
          inputSourceSha256: request.hash,
        ),
        throwsArgumentError,
      );
    }
    const unavailable = AndroidOfficeEngine(channel: channel, isAndroid: false);
    await expectLater(
      unavailable.inspectPresentation(
        sourcePath: source,
        sessionId: session,
        inputSourceSha256: inputHash,
      ),
      throwsA(
        isA<PlatformException>().having(
          (error) => error.code,
          'code',
          'office_unavailable',
        ),
      ),
    );
  });
  group('disk-bound native presentation observation', () {
    late Directory directory;
    late File realSource, pdf, observation;
    late String realSourceHash, pdfHash, native;

    Map<String, dynamic> response() {
      final bytes = utf8.encode(native);
      return {
        ...valid(nativeJson: native),
        'sourceSha256': realSourceHash,
        'pdfSha256': pdfHash,
        'pdfPath': pdf.path,
        'observationPath': observation.path,
        'observationSha256': crypto.sha256.convert(bytes).toString(),
        'observationByteLength': bytes.length,
      };
    }

    Future<AndroidOfficeNativeObservationResult?> inspectReal() =>
        engine.inspectPresentation(
          sourcePath: realSource.path,
          sessionId: session,
          inputSourceSha256: realSourceHash,
        );

    void respond({Future<void> Function()? beforeResponse}) {
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'inspect') {
          if (beforeResponse != null) await beforeResponse();
          return response();
        }
        expect(call.method, 'releasePreview');
        expect(call.arguments, {'sessionId': session});
        return null;
      });
    }

    void expectReleased() =>
        expect(calls.map((call) => call.method), ['inspect', 'releasePreview']);

    Matcher sourceChanged() => isA<PlatformException>().having(
      (error) => error.code,
      'code',
      'preview_source_changed',
    );

    setUp(() async {
      directory = await Directory.systemTemp.createTemp(
        'android-observation-disk-',
      );
      realSource = File(p.join(directory.path, 'original.pptx'));
      await realSource.writeAsString('synthetic presentation work copy');
      realSourceHash = crypto.sha256
          .convert(await realSource.readAsBytes())
          .toString();
      final output = await Directory(
        p.join(directory.path, 'office-previews', 'random'),
      ).create(recursive: true);
      pdf = File(p.join(output.path, 'preview.pdf'));
      observation = File(p.join(output.path, 'native-observation.json'));
      native = valid()['nativeJson'] as String;
      await pdf.writeAsString('%PDF-1.7\n1 0 obj\n<<>>\nendobj\n%%EOF\n');
      pdfHash = crypto.sha256.convert(await pdf.readAsBytes()).toString();
      await observation.writeAsString(native);
    });

    tearDown(() async {
      if (directory.existsSync()) await directory.delete(recursive: true);
    });

    test(
      'valid private files retain the lease until explicit disposal',
      () async {
        respond();
        final result = (await inspectReal())!;
        expect(result.sourceSha256, realSourceHash);
        expect(result.pdfSha256, pdfHash);
        expect(result.observationPath, observation.path);
        expect(result.nativeInfo, jsonDecode(native));
        expect(calls.map((call) => call.method), ['inspect']);
        await result.dispose();
        await result.dispose();
        expectReleased();
      },
    );

    test(
      'missing or mismatched input bytes never dispatch inspection',
      () async {
        respond();
        await realSource.delete();
        await expectLater(inspectReal(), throwsA(invalid()));
        expect(calls, isEmpty);
        await realSource.writeAsString('different source bytes');
        await expectLater(inspectReal(), throwsA(invalid()));
        expect(calls, isEmpty);
        await realSource.writeAsBytes([]);
        await expectLater(inspectReal(), throwsA(invalid()));
        expect(calls, isEmpty);
      },
    );

    test(
      'oversized input is rejected before reading or dispatching it',
      () async {
        respond();
        final handle = await realSource.open(mode: FileMode.write);
        try {
          await handle.truncate(128 * 1024 * 1024 + 1);
        } finally {
          await handle.close();
        }
        await expectLater(inspectReal(), throwsA(invalid()));
        expect(calls, isEmpty);
      },
    );

    test('changed source bytes reject an otherwise owned response', () async {
      respond(
        beforeResponse: () async {
          await realSource.writeAsString('changed source');
        },
      );
      await expectLater(inspectReal(), throwsA(sourceChanged()));
      expectReleased();
    });

    test(
      'changed source modification time rejects a matching source hash',
      () async {
        final before = realSource.lastModifiedSync();
        respond(
          beforeResponse: () => realSource.setLastModified(
            before.add(const Duration(seconds: 5)),
          ),
        );
        await expectLater(inspectReal(), throwsA(sourceChanged()));
        expectReleased();
      },
    );

    test(
      'cancelled inspection still verifies unchanged source bytes',
      () async {
        messenger.setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          expect(call.method, 'inspect');
          await realSource.writeAsString('changed while cancelled');
          return {'status': 'cancelled', 'sessionId': session};
        });
        await expectLater(inspectReal(), throwsA(sourceChanged()));
        expect(calls.map((call) => call.method), ['inspect']);
      },
    );

    test('missing observation bytes release only the granted lease', () async {
      await observation.delete();
      respond();
      await expectLater(inspectReal(), throwsA(invalid()));
      expectReleased();
    });

    test(
      'tampered observation bytes cannot borrow the response JSON hash',
      () async {
        await observation.writeAsString(
          native.replaceFirst('slides', 'slidez'),
        );
        respond();
        await expectLater(inspectReal(), throwsA(invalid()));
        expectReleased();
      },
    );

    test('malformed on-disk UTF8 cannot borrow valid response JSON', () async {
      await observation.writeAsBytes([0xff, 0xfe, 0x7b, 0x7d]);
      respond();
      await expectLater(inspectReal(), throwsA(invalid()));
      expectReleased();
    });

    test(
      'missing PDF bytes reject matching metadata and release its lease',
      () async {
        await pdf.delete();
        respond();
        await expectLater(inspectReal(), throwsA(invalid()));
        expectReleased();
      },
    );

    test('tampered PDF bytes reject the claimed native PDF hash', () async {
      await pdf.writeAsString('%PDF-1.7\nchanged\n%%EOF\n');
      respond();
      await expectLater(inspectReal(), throwsA(invalid()));
      expectReleased();
    });

    test('matching hash cannot make non-PDF bytes a valid preview', () async {
      await pdf.writeAsString('plain text document with %%EOF marker');
      pdfHash = crypto.sha256.convert(await pdf.readAsBytes()).toString();
      respond();
      await expectLater(inspectReal(), throwsA(invalid()));
      expectReleased();
    });

    test('matching PDF header and hash still require an EOF marker', () async {
      await pdf.writeAsString('%PDF-1.7\ntruncated source');
      pdfHash = crypto.sha256.convert(await pdf.readAsBytes()).toString();
      respond();
      await expectLater(inspectReal(), throwsA(invalid()));
      expectReleased();
    });
  });
}
