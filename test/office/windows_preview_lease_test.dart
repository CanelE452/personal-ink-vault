import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/office/windows_office_engine.dart';

void main() {
  late Directory directory;
  late File original;
  late File externalSource;
  late File externalPdf;
  late String sourceHash;
  Map<String, Object?> snapshot(String hash) => {
    'kind': 'presentation',
    'sourceSha256': hash,
    'paragraphs': [],
    'tables': [],
    'slides': [],
  };
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('office-lease-test-');
    original = await File('${directory.path}/source.pptx')
        .writeAsBytes([1, 2, 3]);
    externalSource = await File('${directory.path}/external.pptx')
        .writeAsBytes([4, 5, 6]);
    externalPdf = await File('${directory.path}/external.pdf')
        .writeAsBytes([7, 8, 9]);
    sourceHash = sha256.convert(await original.readAsBytes()).toString();
  });
  tearDown(() => directory.delete(recursive: true));
  WindowsOfficeEngine engine({String? draftHash}) => WindowsOfficeEngine(
    runner: (request) async {
      expect(request['includeDraftSnapshot'], true);
      final editedHash = sha256
          .convert(await externalSource.readAsBytes())
          .toString();
      return {
        'status': 'saved',
        'sessionId': request['sessionId'],
        'sourcePath': externalSource.path,
        'pdfPath': externalPdf.path,
        'sourceSha256': editedHash,
        'pdfSha256': sha256.convert(await externalPdf.readAsBytes()).toString(),
        'pdfPageCount': 1,
        'engineVersion': 'synthetic-owned-preview',
        'snapshot': snapshot(editedHash),
        'draftSnapshot': snapshot(draftHash ?? sourceHash),
      };
    },
  );
  test(
    'preview owns copies and never deletes a directory supplied by a worker',
    () async {
      final dynamic current = engine();
      final dynamic lease = await current.preview(
        original.path,
        operations: <WindowsOfficeOperation>[],
        sessionId: 'preview-1',
        expectedSourceSha256: sourceHash,
      );
      final WindowsOfficeEditResult result = lease.result;
      final owned = File(result.sourcePath).parent;
      addTearDown(() async {
        if (owned.existsSync()) await owned.delete(recursive: true);
      });
      expect(result.sourcePath, isNot(externalSource.path));
      expect(result.pdfPath, isNot(externalPdf.path));
      expect(await File(result.sourcePath).readAsBytes(), [4, 5, 6]);
      expect(await File(result.pdfPath).readAsBytes(), [7, 8, 9]);
      expect(result.draftSnapshot!.sourceSha256, sourceHash);
      await lease.dispose();
      await lease.dispose();
      expect(owned.existsSync(), false);
      expect(await externalSource.readAsBytes(), [4, 5, 6]);
      expect(await externalPdf.readAsBytes(), [7, 8, 9]);
      expect(await original.readAsBytes(), [1, 2, 3]);
    },
  );
  test(
    'a failed-save recovery keeps its own preview files after lease disposal',
    () async {
      final dynamic current = engine();
      final dynamic lease = await current.preview(
        original.path,
        operations: <WindowsOfficeOperation>[],
        sessionId: 'preview-recovery',
        expectedSourceSha256: sourceHash,
      );
      final WindowsOfficeEditResult result = lease.result;
      final owned = File(result.sourcePath).parent;
      addTearDown(() async {
        if (owned.existsSync()) await owned.delete(recursive: true);
      });
      lease.retainForRecovery();
      await lease.dispose();
      expect(File(result.sourcePath).existsSync(), true);
      expect(File(result.pdfPath).existsSync(), true);
      expect(externalSource.existsSync(), true);
    },
  );
  test('a preview from the wrong source is rejected without touching supplied files', () async {
    final dynamic current = engine(draftHash: '0' * 64);
    await expectLater(
      Future<dynamic>.sync(
        () => current.preview(
          original.path,
          operations: <WindowsOfficeOperation>[],
          sessionId: 'wrong-base',
          expectedSourceSha256: sourceHash,
        ),
      ),
      throwsA(isA<WindowsOfficeException>()),
    );
    expect(await original.readAsBytes(), [1, 2, 3]);
    expect(await externalSource.readAsBytes(), [4, 5, 6]);
    expect(await externalPdf.readAsBytes(), [7, 8, 9]);
  });
  test(
    'preview refuses a changed source before executing its request',
    () async {
      var calls = 0;
      final current = WindowsOfficeEngine(
        runner: (_) async {
          calls++;
          throw StateError('A stale source must not reach the runner');
        },
      );
      await expectLater(
        current.preview(
          original.path,
          operations: const [],
          sessionId: 'changed-source',
          expectedSourceSha256: 'f' * 64,
        ),
        throwsA(
          isA<WindowsOfficeException>().having(
            (error) => error.code,
            'code',
            'source_changed',
          ),
        ),
      );
      expect(calls, 0);
      expect(await original.readAsBytes(), [1, 2, 3]);
    },
  );
}
