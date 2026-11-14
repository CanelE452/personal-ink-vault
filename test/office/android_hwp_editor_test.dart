import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/office/android_hwp_editor.dart';
import 'package:saber/data/office/hwp_office_engine.dart';
import 'package:saber/data/office/office_original_edit_result.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('personal_ink_vault/office_engine');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory temp;
  late File working;
  late String inputHash;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('android-hwp-editor-');
    working = await File(
      p.join(temp.path, 'session', 'original.hwp'),
    ).create(recursive: true);
    await working.writeAsBytes(utf8.encode('original hwp bytes'));
    inputHash = sha256.convert(await working.readAsBytes()).toString();
  });
  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    await temp.delete(recursive: true);
  });

  String hash(File file) => sha256.convert(file.readAsBytesSync()).toString();

  HwpStructuredOfficeEngine pdfEngine(List<Map<String, Object?>> requests) =>
      HwpStructuredOfficeEngine(
        runner: (request) async {
          requests.add(request);
          final pdf = await File(
            p.join(temp.path, 'render', 'document.pdf'),
          ).create(recursive: true);
          await pdf.writeAsBytes(utf8.encode('%PDF-1.7\nrendered\n%%EOF\n'));
          return {
            'status': 'previewed',
            'sourceSha256': hash(File(request['sourcePath'] as String)),
            'pdfPath': pdf.path,
            'pdfSha256': hash(pdf),
            'pdfPageCount': 3,
            'engineVersion': 'ink_hwp_native/0.1.0+rhwp.0.9.0-dev.4cf97fe5',
          };
        },
      );

  void editor(Future<Object?> Function(MethodCall call) handler) =>
      messenger.setMockMethodCallHandler(channel, handler);

  test('a saved edit returns edited.hwp and a rhwp preview.pdf beside the working copy', () async {
    final calls = <MethodCall>[];
    editor((call) async {
      calls.add(call);
      final edited = File(p.join(working.parent.path, 'edited.hwp'));
      await edited.writeAsBytes(utf8.encode('edited hwp bytes'));
      return {
        'status': 'saved',
        'sessionId': 'session-1',
        'inputSourceSha256': inputHash,
        'sourcePath': edited.path,
        'sourceSha256': hash(edited),
      };
    });
    final requests = <Map<String, Object?>>[];
    final result = await AndroidHwpEditor(
      pdfEngine: pdfEngine(requests),
    ).edit(sourcePath: working.path, sessionId: 'session-1', fileName: '보고서.hwp');

    expect(calls.single.method, 'hwpEdit');
    expect(calls.single.arguments, {
      'sourcePath': working.path,
      'sessionId': 'session-1',
      'fileName': '보고서.hwp',
    });
    expect(result.status, OfficeOriginalEditStatus.saved);
    expect(result.sessionId, 'session-1');
    expect(result.inputSourceSha256, inputHash);
    expect(p.basename(result.sourcePath!), 'edited.hwp');
    expect(p.basename(result.pdfPath!), 'preview.pdf');
    expect(p.dirname(result.pdfPath!), working.parent.path);
    expect(result.sourceSha256, hash(File(result.sourcePath!)));
    expect(result.pdfSha256, hash(File(result.pdfPath!)));
    expect(result.pdfPageCount, 3);
    expect(
      result.engineVersion,
      'rhwp-studio-0.9.0-dev.4cf97fe5+ink_hwp_native/0.1.0+rhwp.0.9.0-dev.4cf97fe5',
    );
    expect(requests.single['mode'], 'pdf');
    expect(requests.single['sourcePath'], result.sourcePath);
    expect(await working.readAsString(), 'original hwp bytes');
  });

  test('a cancelled edit reports no output and keeps the working copy', () async {
    editor(
      (_) async => {
        'status': 'cancelled',
        'sessionId': 'session-1',
        'inputSourceSha256': inputHash,
      },
    );
    final requests = <Map<String, Object?>>[];
    final result = await AndroidHwpEditor(
      pdfEngine: pdfEngine(requests),
    ).edit(sourcePath: working.path, sessionId: 'session-1', fileName: 'a.hwp');
    expect(result.status, OfficeOriginalEditStatus.cancelled);
    expect(result.sourcePath, isNull);
    expect(result.pdfPath, isNull);
    expect(requests, isEmpty);
    expect(File(p.join(working.parent.path, 'preview.pdf')).existsSync(), isFalse);
    expect(await working.readAsString(), 'original hwp bytes');
  });

  test('a result for another session or with a changed edited file is rejected', () async {
    editor(
      (_) async => {
        'status': 'cancelled',
        'sessionId': 'another-session',
        'inputSourceSha256': inputHash,
      },
    );
    await expectLater(
      AndroidHwpEditor(pdfEngine: pdfEngine([])).edit(
        sourcePath: working.path,
        sessionId: 'session-1',
        fileName: 'a.hwp',
      ),
      throwsFormatException,
    );
    editor((_) async {
      final edited = File(p.join(working.parent.path, 'edited.hwp'));
      await edited.writeAsBytes(utf8.encode('edited hwp bytes'));
      return {
        'status': 'saved',
        'sessionId': 'session-1',
        'inputSourceSha256': inputHash,
        'sourcePath': edited.path,
        'sourceSha256': '0' * 64,
      };
    });
    final requests = <Map<String, Object?>>[];
    await expectLater(
      AndroidHwpEditor(pdfEngine: pdfEngine(requests)).edit(
        sourcePath: working.path,
        sessionId: 'session-1',
        fileName: 'a.hwp',
      ),
      throwsFormatException,
    );
    expect(requests, isEmpty);
  });

  test('editor errors become a readable message', () async {
    editor(
      (_) async => throw PlatformException(
        code: 'hwp_editor_crashed',
        message: '편집 화면이 멈췄습니다. 원본과 작업 파일은 보관됩니다.',
      ),
    );
    await expectLater(
      AndroidHwpEditor(pdfEngine: pdfEngine([])).edit(
        sourcePath: working.path,
        sessionId: 'session-1',
        fileName: 'a.hwp',
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('편집 화면이 멈췄습니다'),
        ),
      ),
    );
  });
}
