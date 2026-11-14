import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/office/hwp_office_engine.dart';
import 'package:saber/data/office/windows_office_engine.dart';
import 'package:saber/pages/office/windows_office_editor.dart';

String _digest(String text) => sha256.convert(utf8.encode(text)).toString();

void main() {
  const selectedText = '삭제할 문단 😀';
  final deletion = {
    'op': 'paragraphDelete',
    'id': 's0:p1',
    'expectedTextSha256': _digest(selectedText),
  };

  testWidgets(
    'HWP stages only a supported paragraph and can undo before save',
    (tester) async {
      final dirty = <bool>[];
      final committed = <Map<String, Object?>>[];
      final allowDelete = ValueNotifier(true);
      addTearDown(allowDelete.dispose);
      final snapshot = WindowsOfficeSnapshot.fromJson({
        'kind': 'word',
        'sourceSha256': 'a' * 64,
        'paragraphs': [
          {'id': 's0:p0', 'text': '구역 설정'},
          {
            'id': 's0:p1',
            'text': selectedText,
            'structure': {'canDelete': true},
          },
        ],
        'tables': [],
        'slides': [],
      });
      const keepField = ValueKey('office-paragraph-s0:p0');
      const delete = ValueKey('office-hwp-delete-paragraph-s0:p1');
      const undo = ValueKey('office-hwp-undo-delete-paragraph-s0:p1');
      await tester.pumpWidget(
        MaterialApp(
          home: ValueListenableBuilder(
            valueListenable: allowDelete,
            builder: (_, allowed, _) => WindowsOfficeEditor(
              snapshot: snapshot,
              allowFormatting: false,
              allowHwpParagraphDeletion: allowed,
              onDirtyChanged: dirty.add,
              onCommit: (ops) async {
                committed.addAll(ops.map((op) => op.toJson()));
              },
              onBack: () {},
            ),
          ),
        ),
      );
      expect(
        find.byKey(const ValueKey('office-hwp-delete-paragraph-s0:p0')),
        findsNothing,
      );
      expect(find.byKey(delete), findsOneWidget);
      await tester.tap(find.byKey(delete));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(find.byKey(keepField)).readOnly, isTrue);
      expect(committed, isEmpty);

      allowDelete.value = false;
      await tester.pump();
      await tester.tap(find.byKey(undo));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(find.byKey(keepField)).readOnly, isFalse);
      expect(find.text(selectedText), findsOneWidget);
      expect(find.byKey(delete), findsNothing);

      allowDelete.value = true;
      await tester.pump();
      await tester.tap(find.byKey(delete));
      await tester.pumpAndSettle();
      await tester.tap(find.text('저장하고 닫기'));
      await tester.pumpAndSettle();
      expect(committed, [deletion]);
      expect(dirty, [true, false, true, false]);
    },
  );

  for (final extension in ['hwp', 'hwpx']) {
    test(
      '$extension forwards an isolated validated deletion to Rust',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'piv-hwp-delete-',
        );
        final source = File('${directory.path}/original.$extension');
        final result = File('${directory.path}/edited.$extension');
        final pdf = File('${directory.path}/edited.pdf');
        addTearDown(() {
          for (final file in [source, result, pdf]) {
            if (file.existsSync()) file.deleteSync();
          }
          directory.deleteSync();
        });
        const pdfBody = '%PDF-1.7\nfixture';
        await source.writeAsString('original');
        await result.writeAsString('edited');
        await pdf.writeAsString(pdfBody);
        var calls = 0;
        final engine = HwpOfficeEngine(
          runner: (request) async {
            calls++;
            expect(request['operations'], [deletion]);
            expect(request['expectedSourceSha256'], _digest('original'));
            return {
              'status': 'saved',
              'sessionId': request['sessionId'],
              'sourcePath': result.path,
              'pdfPath': pdf.path,
              'sourceSha256': _digest('edited'),
              'pdfSha256': _digest(pdfBody),
              'pdfPageCount': 1,
              'engineVersion': 'synthetic-contract',
              'snapshot': {'kind': 'word', 'sourceSha256': _digest('edited')},
            };
          },
        );
        for (final invalid in [
          [deletion, deletion],
          [
            deletion,
            {'op': 'paragraphText', 'id': 's0:p0', 'text': 'other'},
          ],
          [
            {...deletion, 'id': 's0:p1:t0'},
          ],
          [
            {...deletion, 'id': 's0:p1\n'},
          ],
          [
            {...deletion, 'expectedTextSha256': '${_digest(selectedText)}\n'},
          ],
          [
            {...deletion, 'text': selectedText},
          ],
        ]) {
          await expectLater(
            engine.apply(source.path, operations: invalid, sessionId: 'bad'),
            throwsA(
              isA<HwpOfficeException>().having(
                (error) => error.code,
                'code',
                'invalid_request',
              ),
            ),
          );
        }
        expect(calls, 0);
        await engine.apply(
          source.path,
          operations: [deletion],
          sessionId: 'ok',
        );
        expect(calls, 1);
        expect(await source.readAsString(), 'original');
      },
    );
  }
}
