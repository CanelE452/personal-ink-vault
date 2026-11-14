import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/office/hwp_office_engine.dart';
import 'package:saber/data/office/office_templates.dart';
import 'package:saber/data/office/windows_office_engine.dart';

String _sha(String text) => sha256.convert(utf8.encode(text)).toString();

Map<String, Object?> _table() => {
  'op': 'tableInsert',
  'id': 'draft-table',
  'referenceId': 's0:p0',
  'position': 'after',
  'expectedTextSha256': _sha('원본 기준 문단'),
  'rows': 2,
  'columns': 2,
};

Matcher _hwpError(String code) =>
    isA<HwpOfficeException>().having((error) => error.code, 'code', code);

void main() {
  final native = Platform.environment['PIV_HWP_TABLE_TEST_DLL'];
  test(
    'actual Rust HWPX starter reopens with an editable table at the selected paragraph',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'piv-hwpx-table-',
      );
      addTearDown(() async {
        final resolved = await directory.resolveSymbolicLinks();
        expect(
          p.dirname(resolved),
          await Directory.systemTemp.resolveSymbolicLinks(),
        );
        expect(p.basename(resolved), startsWith('piv-hwpx-table-'));
        await Directory(resolved).delete(recursive: true);
      });
      await IOOverrides.runZoned(() async {
        final engine = HwpStructuredOfficeEngine(
          libraryPath: native,
          fontDirectory:
              Platform.environment['INK_HWP_FONT_DIRECTORY'] ??
              Directory('build/native/fonts').absolute.path,
        );
        final starter = OfficeTemplates.create(
          OfficeTemplateKind.hwpx,
          title: '한글 표 삽입',
        );
        final source = await File(p.join(directory.path, starter.fileName))
            .writeAsBytes(starter.bytes);
        final first = await engine.inspect(source.path);
        final withTail = await engine.apply(
          source.path,
          sessionId: 'table-fixture',
          expectedSourceSha256: first.sourceSha256,
          operations: [
            WindowsOfficeOperation.paragraphInsert(
              id: 'later-body',
              referenceId: first.paragraphs.single.id,
              position: 'after',
              expectedTextSha256: _sha(first.paragraphs.single.text),
              text: '그다음 문단',
            ),
          ],
        );
        final baseline = await File(withTail.sourcePath).readAsBytes();
        final opened = await engine.inspect(withTail.sourcePath);
        expect(opened.supportsHwpTableInsert, isTrue);
        expect(opened.paragraphs.first.tableInsertAnchor, isTrue);
        final inserted = await engine.apply(
          withTail.sourcePath,
          sessionId: 'table-insert',
          expectedSourceSha256: opened.sourceSha256,
          operations: [
            WindowsOfficeOperation.hwpTableInsert(
              id: 'table-a',
              referenceId: opened.paragraphs.first.id,
              expectedTextSha256: _sha(opened.paragraphs.first.text),
              rows: 3,
              columns: 2,
            ),
          ],
        );
        expect(inserted.pdfPageCount, greaterThan(0));
        final reopened = await engine.inspect(inserted.sourcePath);
        expect(reopened.paragraphs.map((entry) => entry.text), [
          opened.paragraphs.first.text,
          '그다음 문단',
        ]);
        final table = reopened.tables.single;
        expect(table.id, 's0:p1:t0');
        expect(table.cells, {
          for (var row = 0; row < 3; row++)
            for (var column = 0; column < 2; column++) '$row,$column': '',
        });
        final edited = await engine.apply(
          inserted.sourcePath,
          sessionId: 'table-cell',
          expectedSourceSha256: reopened.sourceSha256,
          operations: [
            WindowsOfficeOperation.tableCellText(table.id, '2,1', '새 셀'),
          ],
        );
        final reopenedEdit = await engine.inspect(edited.sourcePath);
        expect(reopenedEdit.tables.single.cells['2,1'], '새 셀');
        expect(reopenedEdit.tables.single.cells['0,0'], '');
        expect(edited.pdfPageCount, greaterThan(0));
        const initialCells = [
          ['  첫째 & <1>  ', ''],
          ['둘째', '새 값'],
          ['', '끝'],
        ];
        final populated = await engine.apply(
          withTail.sourcePath,
          sessionId: 'table-insert-populated',
          expectedSourceSha256: opened.sourceSha256,
          operations: [
            WindowsOfficeOperation.hwpTableInsert(
              id: 'table-b',
              referenceId: opened.paragraphs.first.id,
              expectedTextSha256: _sha(opened.paragraphs.first.text),
              rows: initialCells.length,
              columns: initialCells.first.length,
              cells: initialCells,
            ),
          ],
        );
        final reopenedPopulated = await engine.inspect(populated.sourcePath);
        expect(reopenedPopulated.tables.single.cells, {
          for (var row = 0; row < initialCells.length; row++)
            for (var column = 0; column < initialCells[row].length; column++)
              '$row,$column': initialCells[row][column],
        });
        expect(populated.pdfPageCount, greaterThan(0));
        expect(await File(withTail.sourcePath).readAsBytes(), baseline);
        expect(await source.readAsBytes(), starter.bytes);
      }, getSystemTempDirectory: () => directory);
    },
    skip: native == null
        ? 'Set PIV_HWP_TABLE_TEST_DLL to the compiled native library'
        : false,
  );

  test(
    'HWPX sends a revision-bound table insertion to the native engine',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'piv-hwpx-table-',
      );
      addTearDown(() async {
        final resolved = await directory.resolveSymbolicLinks();
        expect(
          p.dirname(resolved),
          await Directory.systemTemp.resolveSymbolicLinks(),
        );
        expect(p.basename(resolved), startsWith('piv-hwpx-table-'));
        await Directory(resolved).delete(recursive: true);
      });
      final source = await File(p.join(directory.path, 'input.hwpx'))
          .writeAsString('original');
      final edited = await File(p.join(directory.path, 'edited.hwpx'))
          .writeAsString('updated');
      const pdfText = '%PDF-1.7\nfixture';
      final pdf = await File(p.join(directory.path, 'preview.pdf'))
          .writeAsString(pdfText);
      var nativeCalls = 0;
      final engine = HwpOfficeEngine(
        runner: (request) async {
          nativeCalls++;
          expect(request['operations'], [_table()]);
          expect(request['expectedSourceSha256'], _sha('original'));
          return {
            'status': 'saved',
            'sessionId': request['sessionId'],
            'sourcePath': edited.path,
            'pdfPath': pdf.path,
            'sourceSha256': _sha('updated'),
            'pdfSha256': _sha(pdfText),
            'pdfPageCount': 1,
            'engineVersion': 'synthetic-contract',
            'snapshot': {'kind': 'word', 'sourceSha256': _sha('updated')},
          };
        },
      );
      await expectLater(
        engine.apply(
          source.path,
          operations: [_table()],
          sessionId: 'table',
          expectedSourceSha256: _sha('stale'),
        ),
        throwsA(_hwpError('source_changed')),
      );
      expect(nativeCalls, 0);
      await engine.apply(
        source.path,
        operations: [_table()],
        sessionId: 'table',
        expectedSourceSha256: _sha('original'),
      );
      expect(nativeCalls, 1);
      expect(await source.readAsString(), 'original');
    },
  );

  test(
    'table insertion rejects invalid shape or mixed drafts before Rust',
    () async {
      final engine = HwpOfficeEngine(
        runner: (_) async => fail('Rust should not run for an invalid request'),
      );
      Future<void> reject(
        List<Map<String, Object?>> operations, {
        String extension = 'hwpx',
        String? hash,
        String code = 'invalid_request',
      }) => expectLater(
        engine.apply(
          'never-opened.$extension',
          operations: operations,
          sessionId: 'table',
          expectedSourceSha256: hash,
        ),
        throwsA(_hwpError(code)),
      );

      final hash = _sha('original');
      await reject(
        [_table()],
        extension: 'hwp',
        hash: hash,
        code: 'unsupported_operation',
      );
      await reject([_table()]);
      for (final invalid in <Map<String, Object?>>[
        {'rows': 0},
        {'rows': 9},
        {'rows': 2.0},
        {'columns': 0},
        {'columns': 7},
        {'referenceId': 's0:p0:t0'},
        {'referenceId': 's0:p0\n'},
        {'expectedTextSha256': 'stale'},
        {'position': 'before'},
        {'id': 's0:p1'},
        {'id': '한글'},
        {'id': 'a' * 129},
        {
          'cells': ['injected text'],
        },
      ]) {
        await reject([
          {..._table(), ...invalid},
        ], hash: hash);
      }
      await reject([_table(), _table()], hash: hash);
      await reject([
        {'op': 'paragraphText', 'id': 's0:p0', 'text': 'separate edit'},
        _table(),
      ], hash: hash);
    },
  );
}
