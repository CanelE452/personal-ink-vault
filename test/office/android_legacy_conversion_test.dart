import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart' show validateId;
import 'package:path/path.dart' as p;
import 'package:saber/data/office/android_office_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('personal_ink_vault/office_engine');
  const engine = AndroidOfficeEngine(channel: channel, isAndroid: true);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const session = '70bf425f-c413-457a-82cc-119c3f6cc8ae';
  const engineVersion = '26.04.6.0-962';
  const legacyBytes = [0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1, 1];
  const modernBytes = [0x50, 0x4b, 0x03, 0x04, 1];
  const pdfText = '%PDF-1.7\n1 0 obj\n<<>>\nendobj\n%%EOF\n';
  final inputHash = sha256.convert(legacyBytes).toString();
  final outputHash = sha256.convert(modernBytes).toString();
  late Directory temporary, convertedDirectory, pdfDirectory;
  late File source, converted, pdf;
  late String pdfHash, target;
  String? reopenedSession;
  final calls = <String>[];
  final released = <String>[];

  setUp(() async {
    calls.clear();
    released.clear();
    reopenedSession = null;
    temporary = await Directory.systemTemp.createTemp(
      'legacy-conversion-test-',
    );
    final leases = p.join(temporary.path, 'office-previews');
    convertedDirectory = await Directory(p.join(leases, 'preview-conversion'))
        .create(recursive: true);
    pdfDirectory = await Directory(p.join(leases, 'preview-reopen')).create();
    pdf = await File(p.join(pdfDirectory.path, 'preview.pdf'))
        .writeAsString(pdfText);
    pdfHash = sha256.convert(await pdf.readAsBytes()).toString();
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    await temporary.delete(recursive: true);
  });

  Future<void> fixture(String extension) async {
    target = '${extension}x';
    source = await File(p.join(temporary.path, 'source.$extension'))
        .writeAsBytes(legacyBytes);
    converted = await File(p.join(convertedDirectory.path, 'converted.$target'))
        .writeAsBytes(modernBytes);
  }

  Map<String, Object> conversion() => {
    'status': 'converted',
    'engineVersion': engineVersion,
    'sessionId': session,
    'inputSourceSha256': inputHash,
    'targetExtension': target,
    'sourcePath': converted.path,
    'sourceSha256': outputHash,
  };

  Map<String, Object> preview() => {
    'status': 'previewed',
    'sessionId': reopenedSession!,
    'sourceSha256': outputHash,
    'pdfSha256': pdfHash,
    'pdfPath': pdf.path,
    'pdfPageCount': 2,
    'engineVersion': engineVersion,
  };

  void native({
    Future<Object?> Function()? convert,
    Future<Object?> Function()? reopen,
    bool previewCleanupFails = false,
  }) {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'convertLegacy':
          expect(call.arguments, {
            'sourcePath': source.path,
            'sessionId': session,
            'inputSourceSha256': inputHash,
          });
          return convert == null ? conversion() : await convert();
        case 'preview':
          final args = call.arguments as Map;
          expect(args.keys, unorderedEquals(['sourcePath', 'sessionId']));
          expect(args['sourcePath'], converted.path);
          final id = args['sessionId'] as String;
          validateId(id);
          expect(id, isNot(session));
          reopenedSession = id;
          return reopen == null ? preview() : await reopen();
        case 'releasePreview':
          final id = (call.arguments as Map)['sessionId'] as String;
          expect([session, reopenedSession], contains(id));
          released.add(id);
          if (id == reopenedSession && previewCleanupFails) {
            throw PlatformException(code: 'cleanup_failed');
          }
          final dir = id == session ? convertedDirectory : pdfDirectory;
          await dir.delete(recursive: true);
          return null;
        default:
          fail('Unexpected native request ${call.method}');
      }
    });
  }

  Matcher invalid() => isA<PlatformException>().having(
    (error) => error.code,
    'code',
    'invalid_office_conversion',
  );

  for (final extension in ['doc', 'ppt']) {
    test(
      'converts $extension and reopens the new source for its PDF',
      () async {
        await fixture(extension);
        native();
        final result = (await engine.convertLegacy(
          source: source,
          sessionId: session,
          expectedSourceSha256: inputHash,
        ))!;
        expect(result.originalBytes, modernBytes);
        expect(result.pdfBytes, pdfText.codeUnits);
        expect(result.engineVersion, engineVersion);
        expect(result.pageCount, 2);
        expect(result.targetExtension, target);
        expect(await source.readAsBytes(), legacyBytes);
        expect(calls, [
          'convertLegacy',
          'preview',
          'releasePreview',
          'releasePreview',
        ]);
        expect(released, [reopenedSession, session]);
        expect(pdfDirectory.existsSync(), isFalse);
        expect(convertedDirectory.existsSync(), isFalse);
      },
    );
  }

  test(
    'conversion cancellation never opens a PDF or releases a foreign job',
    () async {
      await fixture('doc');
      native(
        convert: () async => {
          'status': 'cancelled',
          'sessionId': session,
          'engineVersion': engineVersion,
        },
      );
      expect(
        await engine.convertLegacy(
          source: source,
          sessionId: session,
          expectedSourceSha256: inputHash,
        ),
        isNull,
      );
      expect(calls, ['convertLegacy']);
      expect(released, isEmpty);
    },
  );

  test(
    'cancelled PDF reopen releases the converted source without publishing',
    () async {
      await fixture('ppt');
      native(reopen: () async => {'status': 'cancelled'});
      expect(
        await engine.convertLegacy(
          source: source,
          sessionId: session,
          expectedSourceSha256: inputHash,
        ),
        isNull,
      );
      expect(calls, ['convertLegacy', 'preview', 'releasePreview']);
      expect(released, [session]);
    },
  );

  for (final fault in [
    'another UUID',
    'foreign path',
    'extra field',
    'wrong hash',
  ]) {
    test('rejects $fault before reopening the candidate', () async {
      await fixture('doc');
      native(
        convert: () async => {
          ...conversion(),
          if (fault == 'another UUID')
            'sessionId': '0350c0ce-2870-4c3a-9ea1-1d985a973b50',
          if (fault == 'foreign path')
            'sourcePath': p.join(temporary.path, 'foreign', 'converted.docx'),
          if (fault == 'extra field') 'extra': true,
          if (fault == 'wrong hash') 'sourceSha256': 'f' * 64,
        },
      );
      await expectLater(
        engine.convertLegacy(
          source: source,
          sessionId: session,
          expectedSourceSha256: inputHash,
        ),
        throwsA(invalid()),
      );
      final owned = fault == 'extra field' || fault == 'wrong hash';
      expect(calls, ['convertLegacy', if (owned) 'releasePreview']);
      expect(released, [if (owned) session]);
    });
  }

  for (final fault in [
    'wrong PDF source',
    'candidate mutation',
    'invalid PDF',
  ]) {
    test('rejects $fault and releases both separate jobs', () async {
      await fixture('ppt');
      native(
        reopen: () async {
          if (fault == 'candidate mutation') {
            await converted.writeAsBytes([...modernBytes, 2]);
          }
          if (fault == 'invalid PDF') {
            await pdf.writeAsString('not a complete PDF');
            pdfHash = sha256.convert(await pdf.readAsBytes()).toString();
          }
          return {
            ...preview(),
            if (fault == 'wrong PDF source') 'sourceSha256': inputHash,
          };
        },
        previewCleanupFails: true,
      );
      await expectLater(
        engine.convertLegacy(
          source: source,
          sessionId: session,
          expectedSourceSha256: inputHash,
        ),
        throwsA(invalid()),
      );
      expect(released, [reopenedSession, session]);
      expect(convertedDirectory.existsSync(), isFalse);
    });
  }
}
