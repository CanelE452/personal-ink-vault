import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/office/hwp_office_engine.dart';
import 'package:saber/data/office/office_templates.dart';
import 'package:saber/data/office/windows_office_engine.dart';

Map<String, dynamic> model(String hash) => {
  'kind': 'word',
  'sourceSha256': hash,
  'paragraphs': [
    {'id': 's0:p1', 'text': '새 문단'},
  ],
  'tables': [
    {
      'id': 's0:p0:t0',
      'cells': {'0,0': '새 셀'},
    },
  ],
  'slides': <Object?>[],
};

void main() {
  late Directory directory;
  late File original;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('ink-hwp-contract-');
    original = await File('${directory.path}/original.hwp')
        .writeAsBytes([1, 2, 3]);
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });
  nativeContractTests();

  for (final preview in [true, false]) {
    test(
      'failed ${preview ? 'preview' : 'apply'} preparation removes its own temporary work directory',
      () async {
        final retained = await Directory('${directory.path}/retained-output')
            .create();
        final saved = await File('${retained.path}/successful.pdf')
            .writeAsString('caller-owned output');
        final engine = HwpOfficeEngine(
          libraryPath: '${directory.path}/missing.dll',
          fontDirectory: '${directory.path}/missing-fonts',
        );
        await IOOverrides.runZoned(() async {
          await expectLater(
            preview
                ? engine.inspect(original.path, preview: true)
                : engine.apply(
                    original.path,
                    sessionId: 'failed-apply',
                    operations: [
                      {'op': 'paragraphText', 'id': 's0:p1', 'text': 'Changed'},
                    ],
                  ),
            throwsA(isA<FileSystemException>()),
          );
        }, getSystemTempDirectory: () => directory);
        final remaining = await directory
            .list()
            .where(
              (entry) =>
                  entry is Directory &&
                  entry.uri.pathSegments
                      .where((segment) => segment.isNotEmpty)
                      .last
                      .startsWith('personal-ink-vault-hwp-'),
            )
            .toList();
        expect(remaining, isEmpty);
        expect(await original.readAsBytes(), [1, 2, 3]);
        expect(await saved.readAsString(), 'caller-owned output');
      },
    );
  }

  test(
    'inspect forwards preview and returns normalized word snapshot',
    () async {
      final hash = sha256.convert(await original.readAsBytes()).toString();
      final engine = HwpOfficeEngine(
        runner: (request) async {
          expect(request['mode'], 'inspect');
          expect(request['sourcePath'], original.path);
          expect(request['preview'], false);
          return {'snapshot': model(hash)};
        },
      );
      expect(await engine.available, true);
      final result = await engine.inspect(original.path);
      expect((result['snapshot'] as Map)['sourceSha256'], hash);
    },
  );

  test(
    'renderPdf sends only a PDF request and validates the physical PDF',
    () async {
      final hash = sha256.convert(await original.readAsBytes()).toString();
      final pdf = await File('${directory.path}/document.pdf')
          .writeAsBytes('%PDF-1.7\nfixture'.codeUnits);
      final pdfHash = sha256.convert(await pdf.readAsBytes()).toString();
      Map<String, dynamic> response(String pdfSha256) => {
        'status': 'previewed',
        'sourceSha256': hash,
        'pdfPath': pdf.path,
        'pdfSha256': pdfSha256,
        'pdfPageCount': 2,
        'engineVersion': 'ink_hwp_native/0.1.0+rhwp.0.9.0',
      };
      final result = await HwpOfficeEngine(
        runner: (request) async {
          expect(request, {'mode': 'pdf', 'sourcePath': original.path});
          return response(pdfHash);
        },
      ).renderPdf(original.path);
      expect(result['pdfPageCount'], 2);
      await expectLater(
        HwpOfficeEngine(runner: (_) async => response('0' * 64))
            .renderPdf(original.path),
        throwsA(
          isA<HwpOfficeException>().having(
            (error) => error.code,
            'code',
            'invalid_preview',
          ),
        ),
      );
      await expectLater(
        HwpOfficeEngine(
          runner: (_) async => {...response(pdfHash), 'sourceSha256': '1' * 64},
        ).renderPdf(original.path),
        throwsA(
          isA<HwpOfficeException>().having(
            (error) => error.code,
            'code',
            'source_changed',
          ),
        ),
      );
    },
  );

  test(
    'apply captures source precondition and validates actual edited/PDF bytes',
    () async {
      final sourceHash = sha256
          .convert(await original.readAsBytes())
          .toString();
      final edited = await File('${directory.path}/edited.hwp')
          .writeAsBytes([4, 5]);
      final pdf = await File('${directory.path}/edited.pdf')
          .writeAsBytes('%PDF-1.7\nfixture'.codeUnits);
      final editedHash = sha256.convert(await edited.readAsBytes()).toString();
      final engine = HwpOfficeEngine(
        runner: (request) async {
          expect(request['expectedSourceSha256'], sourceHash);
          expect((request['operations'] as List).single, {
            'op': 'paragraphText',
            'id': 's0:p1',
            'text': '새 문단',
          });
          return {
            'status': 'saved',
            'sessionId': 'edit-1',
            'sourcePath': edited.path,
            'pdfPath': pdf.path,
            'sourceSha256': editedHash,
            'pdfSha256': sha256.convert(await pdf.readAsBytes()).toString(),
            'pdfPageCount': 1,
            'engineVersion': 'ink_hwp_native/0.1.0',
            'snapshot': model(editedHash),
          };
        },
      );
      final result = await engine.apply(
        original.path,
        sessionId: 'edit-1',
        operations: [
          {'op': 'paragraphText', 'id': 's0:p1', 'text': '새 문단'},
        ],
      );
      expect(result['sourcePath'], edited.path);
      expect(await original.readAsBytes(), [1, 2, 3]);
    },
  );

  test('physical result hash mismatch cannot be reported as saved', () async {
    final edited = await File('${directory.path}/edited.hwp')
        .writeAsBytes([4, 5]);
    final pdf = await File('${directory.path}/edited.pdf')
        .writeAsBytes('%PDF-1.7\nfixture'.codeUnits);
    final engine = HwpOfficeEngine(
      runner: (_) async => {
        'status': 'saved',
        'sessionId': 'edit-1',
        'sourcePath': edited.path,
        'pdfPath': pdf.path,
        'sourceSha256': '0' * 64,
        'pdfSha256': sha256.convert(await pdf.readAsBytes()).toString(),
        'pdfPageCount': 1,
        'engineVersion': '0.1.0',
        'snapshot': model('0' * 64),
      },
    );
    await expectLater(
      engine.apply(
        original.path,
        sessionId: 'edit-1',
        operations: [
          {'op': 'paragraphText', 'id': 's0:p1', 'text': 'changed'},
        ],
      ),
      throwsA(
        isA<HwpOfficeException>().having(
          (e) => e.code,
          'code',
          'payload_mismatch',
        ),
      ),
    );
  });

  test('stale source fails before calling native worker', () async {
    var called = false;
    final engine = HwpOfficeEngine(
      runner: (_) async {
        called = true;
        return {};
      },
    );
    await expectLater(
      engine.apply(
        original.path,
        sessionId: 'edit-1',
        expectedSourceSha256: '0' * 64,
        operations: [
          {'op': 'paragraphText', 'id': 's0:p1', 'text': 'changed'},
        ],
      ),
      throwsA(
        isA<HwpOfficeException>().having(
          (e) => e.code,
          'code',
          'source_changed',
        ),
      ),
    );
    expect(called, false);
  });

  test('HWP5 rows and HWPX columns reach native with a source hash', () async {
    final originalBytes = await original.readAsBytes();
    final sourceHash = sha256.convert(originalBytes).toString();
    final pdf = await File('${directory.path}/edited.pdf')
        .writeAsString('%PDF-1.7\nfixture');
    final pdfHash = sha256.convert(await pdf.readAsBytes()).toString();
    final hwpx = await original.copy('${directory.path}/original.hwpx');
    for (final (source, action) in [
      (original, 'insertRow'),
      (original, 'deleteRow'),
      (hwpx, 'insertColumn'),
      (hwpx, 'deleteColumn'),
    ]) {
      final extension = source.path.split('.').last;
      final edited = await File('${directory.path}/edited.$extension')
          .writeAsBytes([4, 5]);
      final editedHash = sha256.convert(await edited.readAsBytes()).toString();
      final operation = WindowsOfficeOperation.hwpTableStructure(
        id: 's0:p0:t0',
        action: action,
        index: 0,
      ).toJson();
      var calls = 0;
      final engine = HwpOfficeEngine(
        runner: (request) async {
          calls++;
          expect(request['sourcePath'], source.path);
          expect(request['expectedSourceSha256'], sourceHash);
          expect(request['operations'], [operation]);
          return {
            'status': 'saved',
            'sessionId': request['sessionId'],
            'sourcePath': edited.path,
            'pdfPath': pdf.path,
            'sourceSha256': editedHash,
            'pdfSha256': pdfHash,
            'pdfPageCount': 1,
            'engineVersion': 'ink_hwp_native/0.1.0',
            'snapshot': model(editedHash),
          };
        },
      );
      await expectLater(
        engine.apply(
          source.path,
          sessionId: 'table-structure',
          expectedSourceSha256: '0' * 64,
          operations: [operation],
        ),
        throwsA(
          isA<HwpOfficeException>().having(
            (error) => error.code,
            'code',
            'source_changed',
          ),
        ),
      );
      expect(calls, 0);
      final result = await engine.apply(
        source.path,
        sessionId: 'table-structure',
        expectedSourceSha256: sourceHash,
        operations: [operation],
      );
      expect(calls, 1);
      expect(result['sourcePath'], edited.path);
      expect(result['pdfPath'], pdf.path);
      expect(await source.readAsBytes(), originalBytes);
    }
  });

  test('unsupported formatting is explicit and never sent to writer', () async {
    var called = false;
    final engine = HwpOfficeEngine(
      runner: (_) async {
        called = true;
        return {};
      },
    );
    await expectLater(
      engine.apply(
        original.path,
        sessionId: 'edit-1',
        operations: [
          {'op': 'paragraphStyle', 'id': 's0:p1', 'bold': true},
        ],
      ),
      throwsA(
        isA<HwpOfficeException>().having(
          (e) => e.code,
          'code',
          'unsupported_operation',
        ),
      ),
    );
    expect(called, false);
  });

  test('native incomplete layout is an error, never saved', () async {
    final engine = HwpOfficeEngine(
      runner: (_) async => {
        'error': {
          'code': 'incomplete_layout',
          'message': '표의 일부를 표시하지 못했습니다.',
          'workingDirectory': directory.path,
        },
      },
    );
    await expectLater(
      engine.apply(
        original.path,
        sessionId: 'edit-1',
        operations: [
          {
            'op': 'tableCellText',
            'tableId': 's0:p0:t0',
            'cell': '0,0',
            'text': 'long',
          },
        ],
      ),
      throwsA(
        isA<HwpOfficeException>().having(
          (e) => e.code,
          'code',
          'incomplete_layout',
        ),
      ),
    );
  });

  test(
    'missing native library is unavailable with no Dart edit fallback',
    () async {
      final engine = HwpOfficeEngine(
        libraryPath: '${directory.path}/missing.dll',
      );
      expect(await engine.available, false);
      await expectLater(
        engine.inspect(original.path),
        throwsA(
          isA<HwpOfficeException>().having(
            (e) => e.code,
            'code',
            'library_unavailable',
          ),
        ),
      );
    },
  );
}

// Run with explicit compiled library/fixture paths to exercise the real FFI worker.
void nativeContractTests() {
  final library = Platform.environment['INK_HWP_NATIVE_LIBRARY'];
  final fixtures = Platform.environment['INK_HWP_FIXTURE_DIRECTORY'];
  final fontDirectory =
      Platform.environment['INK_HWP_FONT_DIRECTORY'] ??
      Directory('build/native/fonts').absolute.path;
  final publicHwp = File(
    'build/research/hwp/hwp-cli-v1.3.1-source/'
    'hwp-cli-4e6e8c2a61694899e37b4f7c2f97523153a623b9/'
    'fixtures/pdf-parity/public/source/public-safety-rfp-p1.hwp',
  ).absolute;
  final pdfSamples = Platform.environment['INK_HWP_PDF_SAMPLES'];
  test(
    'actual Rust renders real HWP and HWPX documents to a separate PDF with rhwp',
    () async {
      final engine = HwpStructuredOfficeEngine(
        libraryPath: library,
        fontDirectory: fontDirectory,
      );
      final files = Directory(pdfSamples!)
          .listSync()
          .whereType<File>()
          .where((file) {
            final name = file.path.toLowerCase();
            return name.endsWith('.hwp') || name.endsWith('.hwpx');
          })
          .toList();
      expect(files, isNotEmpty);
      for (final file in files) {
        final before = await file.readAsBytes();
        final pdf = await engine.renderPdf(file.path);
        try {
          expect(pdf.pageCount, greaterThan(0), reason: file.path);
          expect(pdf.engineVersion, contains('rhwp.0.9.0'));
          expect(File(pdf.pdfPath).existsSync(), isTrue, reason: file.path);
        } finally {
          await pdf.dispose();
        }
        expect(File(pdf.pdfPath).existsSync(), isFalse, reason: file.path);
        expect(await file.readAsBytes(), before, reason: file.path);
      }
    },
    skip: library == null || pdfSamples == null
        ? 'Set INK_HWP_NATIVE_LIBRARY and INK_HWP_PDF_SAMPLES'
        : false,
    timeout: const Timeout(Duration(minutes: 5)),
  );
  test(
    'actual Rust inserts a body paragraph while editing the HWP5 original',
    () async {
      final directory = await Directory.systemTemp.createTemp('hwp5-new-body-');
      addTearDown(() async {
        expect(
          await directory.parent.resolveSymbolicLinks(),
          await Directory.systemTemp.resolveSymbolicLinks(),
        );
        await directory.delete(recursive: true);
      });
      final before = await publicHwp.readAsBytes();
      final source = await File('${directory.path}/source.hwp')
          .writeAsBytes(before);
      final engine = HwpStructuredOfficeEngine(
        libraryPath: library,
        fontDirectory: fontDirectory,
      );
      final opened = await engine.inspect(source.path);
      final index = opened.paragraphs.indexWhere((p) => p.id == 's0:p6');
      expect(index, greaterThanOrEqualTo(0));
      final anchor = opened.paragraphs[index];
      expect(anchor.structure?.canInsertAfter, true);
      const replacement = '수정한 본문';
      const addition = '그 아래 추가한 문단 🈂 <A&B>';
      final saved = await IOOverrides.runZoned(
        () => engine.apply(
          source.path,
          expectedSourceSha256: opened.sourceSha256,
          sessionId: 'hwp5-new-body',
          operations: [
            WindowsOfficeOperation.paragraphText(anchor.id, replacement),
            WindowsOfficeOperation.paragraphInsert(
              id: 'draft-hwp5-body',
              referenceId: anchor.id,
              position: 'after',
              expectedTextSha256: sha256
                  .convert(utf8.encode(anchor.text))
                  .toString(),
              text: addition,
            ),
          ],
        ),
        getSystemTempDirectory: () => directory,
      );
      expect(saved.pdfPageCount, greaterThan(0));
      expect(await source.readAsBytes(), before);
      final reopened = await engine.inspect(saved.sourcePath);
      final expected = opened.paragraphs.map((p) => p.text).toList()
        ..replaceRange(index, index + 1, [replacement, addition]);
      expect(reopened.paragraphs.map((p) => p.text), expected);
      expect(reopened.paragraphs[index + 1].structure?.canInsertAfter, true);
      expect(
        reopened.tables.map((t) => t.cells),
        opened.tables.map((t) => t.cells),
      );
    },
    skip: library == null || !publicHwp.existsSync()
        ? 'Requires the compiled Rust HWP library and the public HWP5 fixture'
        : false,
  );
  test(
    'actual Rust adds an independent paragraph to the app HWPX starter',
    () async {
      final directory = await Directory.systemTemp.createTemp('hwpx-new-body-');
      addTearDown(() => directory.delete(recursive: true));
      final starter = OfficeTemplates.create(
        OfficeTemplateKind.hwpx,
        title: '독립 문단 검증',
      );
      final source = await File('${directory.path}/${starter.fileName}')
          .writeAsBytes(starter.bytes);
      final engine = HwpStructuredOfficeEngine(
        libraryPath: library,
        fontDirectory: fontDirectory,
      );
      final opened = await engine.inspect(source.path);
      final anchor = opened.paragraphs.single;
      expect(anchor.structure?.canInsertAfter, true);
      const body = '제목 아래 본문 😀 <A&B>';
      final saved = await IOOverrides.runZoned(
        () => engine.apply(
          source.path,
          expectedSourceSha256: opened.sourceSha256,
          sessionId: 'new-body',
          operations: [
            WindowsOfficeOperation.paragraphInsert(
              id: 'draft-body',
              referenceId: anchor.id,
              position: 'after',
              expectedTextSha256: sha256
                  .convert(utf8.encode(anchor.text))
                  .toString(),
              text: body,
            ),
          ],
        ),
        getSystemTempDirectory: () => directory,
      );
      expect(saved.pdfPageCount, greaterThan(0));
      expect(await source.readAsBytes(), starter.bytes);
      final reopened = await engine.inspect(saved.sourcePath);
      expect(reopened.paragraphs.map((p) => p.text), [anchor.text, body]);
      expect(reopened.paragraphs.last.id, isNot(anchor.id));
      expect(reopened.paragraphs.last.structure?.canInsertAfter, true);
    },
    skip: library == null ? 'Set the compiled Rust HWP library path' : false,
  );
  test(
    'actual native HWP and HWPX edits retain originals and validate PDF payloads',
    () async {
      final engine = HwpOfficeEngine(
        libraryPath: library,
        fontDirectory: fontDirectory,
      );
      expect(await engine.available, true);
      for (final extension in ['hwp', 'hwpx']) {
        final source = File('$fixtures/original.$extension');
        final before = await source.readAsBytes();
        final opened = await engine.inspect(source.path, preview: true);
        final snapshot = opened['snapshot'] as Map;
        final paragraph = (snapshot['paragraphs'] as List).first as Map;
        final table = (snapshot['tables'] as List).first as Map;
        final result = await engine.apply(
          source.path,
          sessionId: 'native-$extension',
          expectedSourceSha256: snapshot['sourceSha256'] as String,
          operations: [
            {
              'op': 'paragraphText',
              'id': paragraph['id'],
              'text': 'NEW_PARAGRAPH 새 문단',
            },
            {
              'op': 'tableCellText',
              'tableId': table['id'],
              'cell': '1,0',
              'text': 'NEW_CELL 새 셀',
            },
          ],
        );
        expect(result['status'], 'saved');
        expect(result['pdfPageCount'], greaterThan(0));
        expect(result['snapshot'].toString(), contains('NEW_PARAGRAPH 새 문단'));
        expect(result['snapshot'].toString(), contains('NEW_CELL 새 셀'));
        expect(await source.readAsBytes(), before);
      }
    },
    skip: library == null || fixtures == null
        ? 'Set explicit compiled native library and synthetic fixture paths'
        : false,
  );

  test(
    'actual native clipped table removes its failed temporary edited output',
    () async {
      final engine = HwpOfficeEngine(
        libraryPath: library,
        fontDirectory: fontDirectory,
      );
      final source = File('$fixtures/original.hwpx');
      final result = await engine.inspect(source.path);
      final snapshot = result['snapshot'] as Map;
      final table = (snapshot['tables'] as List).first as Map;
      try {
        await engine.apply(
          source.path,
          sessionId: 'native-clipped',
          operations: [
            {
              'op': 'tableCellText',
              'tableId': table['id'],
              'cell': '1,0',
              'text': 'CELL_WORD ' * 400,
            },
          ],
        );
        fail('Clipped PDF must never be reported as saved');
      } on HwpOfficeException catch (error) {
        expect(error.code, 'incomplete_layout');
        expect(
          File(error.details['workingSourcePath'] as String).existsSync(),
          false,
        );
      }
    },
    skip: library == null || fixtures == null
        ? 'Set explicit compiled native library and synthetic fixture paths'
        : false,
  );
}
