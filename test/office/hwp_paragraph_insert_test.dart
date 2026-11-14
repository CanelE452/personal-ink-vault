import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/office/hwp_office_engine.dart';
import 'package:saber/data/office/windows_office_engine.dart';
import 'package:saber/pages/office/windows_office_editor.dart';

const _original = '제목 😀';
const _addition = '새 문단 😀 <A&B>';

String _digest(String text) => sha256.convert(utf8.encode(text)).toString();

WindowsOfficeSnapshot _snapshot({bool canInsert = true}) =>
    WindowsOfficeSnapshot.fromJson({
      'kind': 'word',
      'sourceSha256': 'a' * 64,
      'paragraphs': [
        {
          'id': 's0:p0',
          'text': _original,
          if (canInsert) 'structure': {'canInsertAfter': true},
        },
        {'id': 's0:p1', 'text': '다음 원문'},
      ],
      'tables': [],
      'slides': [],
    });

Map<String, Object?> _insert({String id = 'draft-a'}) => {
  'op': 'paragraphInsert',
  'id': id,
  'referenceId': 's0:p0',
  'position': 'after',
  'expectedTextSha256': _digest(_original),
  'text': _addition,
};

void main() {
  const anchor = ValueKey('office-paragraph-s0:p0');
  const draft = ValueKey('office-hwpx-insert-text-s0:p0');
  const remove = ValueKey('office-hwpx-remove-insert-s0:p0');

  for (final width in [320.0, 1000.0]) {
    testWidgets(
      'HWPX adds a sibling draft and retries the same batch at $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final saves = <List<Map<String, Object?>>>[];
        final dirty = <bool>[];
        var closed = false;
        await tester.pumpWidget(
          MaterialApp(
            home: WindowsOfficeEditor(
              snapshot: _snapshot(),
              allowFormatting: false,
              onDirtyChanged: dirty.add,
              onBack: () {
                closed = true;
              },
              onCommit: (operations) async {
                saves.add(
                  operations.map((operation) => operation.toJson()).toList(),
                );
                if (saves.length == 1)
                  throw StateError('temporary save failure');
              },
            ),
          ),
        );
        expect(find.text('이 문단 아래 추가'), findsOneWidget);
        await tester.enterText(find.byKey(anchor), '편집한 제목');
        await tester.tap(find.text('이 문단 아래 추가'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(draft), _addition);
        await tester.tap(find.text('저장하고 닫기'));
        await tester.pumpAndSettle();
        expect(closed, isFalse);
        expect(find.text(_addition), findsOneWidget);
        await tester.tap(find.text('저장 재시도'));
        await tester.pumpAndSettle();

        expect(closed, isTrue);
        expect(dirty, [true, false]);
        expect(saves, hasLength(2));
        expect(saves.first, saves.last);
        final insertionId = saves.last.last['id'] as String;
        expect(insertionId, isNotEmpty);
        expect(saves.last, [
          {'op': 'paragraphText', 'id': 's0:p0', 'text': '편집한 제목'},
          _insert(id: insertionId),
        ]);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('HWPX discards only the pending new paragraph', (tester) async {
    final dirty = <bool>[];
    var commits = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: WindowsOfficeEditor(
          snapshot: _snapshot(),
          allowFormatting: false,
          onDirtyChanged: dirty.add,
          onBack: () {},
          onCommit: (_) async {
            commits++;
          },
        ),
      ),
    );
    await tester.tap(find.text('이 문단 아래 추가'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('저장하고 닫기'));
    await tester.pumpAndSettle();
    expect(commits, 0);
    expect(find.byKey(draft), findsOneWidget);
    await tester.tap(find.byKey(remove));
    await tester.pumpAndSettle();
    expect(find.byKey(draft), findsNothing);
    expect(find.text(_original), findsOneWidget);
    expect(dirty, [true, false]);
  });

  testWidgets('HWPX only offers insertion for a capable snapshot anchor', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: WindowsOfficeEditor(
          snapshot: _snapshot(canInsert: false),
          allowFormatting: false,
          onBack: () {},
          onCommit: (_) async {},
        ),
      ),
    );
    expect(find.text('이 문단 아래 추가'), findsNothing);
  });

  testWidgets('HWPX locks old and new paragraph text while saving', (
    tester,
  ) async {
    final pending = Completer<void>();
    var commits = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: WindowsOfficeEditor(
          snapshot: _snapshot(),
          allowFormatting: false,
          onBack: () {},
          onCommit: (_) {
            commits++;
            return pending.future;
          },
        ),
      ),
    );
    await tester.enterText(find.byKey(anchor), '편집한 제목');
    await tester.tap(find.text('이 문단 아래 추가'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(draft), _addition);
    await tester.tap(find.text('저장하고 닫기'));
    await tester.pump();
    try {
      expect(commits, 1);
      expect(tester.widget<TextField>(find.byKey(anchor)).readOnly, isTrue);
      expect(
        tester
            .widget<TextField>(
              find.descendant(
                of: find.byKey(draft),
                matching: find.byType(TextField),
              ),
            )
            .readOnly,
        isTrue,
      );
      expect(tester.widget<IconButton>(find.byKey(remove)).onPressed, isNull);
    } finally {
      pending.complete();
      await tester.pumpAndSettle();
    }
  });

  for (final extension in ['hwp', 'hwpx']) {
    test(
      '$extension forwards validated insertion operations to Rust unchanged',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'piv-hwpx-insert-',
        );
        addTearDown(() async {
          expect(
            await directory.parent.resolveSymbolicLinks(),
            await Directory.systemTemp.resolveSymbolicLinks(),
          );
          expect(
            directory.uri.pathSegments.where((s) => s.isNotEmpty).last,
            startsWith('piv-hwpx-insert-'),
          );
          await directory.delete(recursive: true);
        });
        final source = await File('${directory.path}/input.$extension')
            .writeAsString('before');
        final edited = await File('${directory.path}/edited.$extension')
            .writeAsString('after');
        const pdfText = '%PDF-1.7\nfixture';
        final pdf = await File('${directory.path}/preview.pdf')
            .writeAsString(pdfText);
        final operations = <Map<String, Object?>>[
          {'op': 'paragraphText', 'id': 's0:p0', 'text': '수정한 원문'},
          _insert(),
          {..._insert(id: 'draft-b'), 'referenceId': 's0:p1'},
        ];
        final engine = HwpOfficeEngine(
          runner: (request) async {
            expect(request['operations'], operations);
            expect(request['expectedSourceSha256'], _digest('before'));
            return {
              'status': 'saved',
              'sessionId': request['sessionId'],
              'sourcePath': edited.path,
              'pdfPath': pdf.path,
              'sourceSha256': _digest('after'),
              'pdfSha256': _digest(pdfText),
              'pdfPageCount': 1,
              'engineVersion': 'synthetic-contract',
              'snapshot': {'kind': 'word', 'sourceSha256': _digest('after')},
            };
          },
        );
        await engine.apply(
          source.path,
          operations: operations,
          sessionId: 'insert',
        );
        expect(await source.readAsString(), 'before');
      },
    );
  }

  test('HWP and HWPX reject invalid insertion batches before Rust', () async {
    final engine = HwpOfficeEngine(
      runner: (_) async => fail('Rust was invoked'),
    );
    Future<void> rejects(
      String extension,
      List<Map<String, Object?>> operations,
    ) => expectLater(
      engine.apply(
        'never-opened.$extension',
        operations: operations,
        sessionId: 'bad',
      ),
      throwsA(isA<HwpOfficeException>()),
    );
    final invalid = <Map<String, Object?>>[
      {'position': 'before'},
      {'referenceId': 's0:p0:t0'},
      {'referenceId': 'draft-a'},
      {'referenceId': 's0:p0\n'},
      {'expectedTextSha256': '${_digest(_original)}\n'},
      {'unknown': true},
      for (final text in [
        '',
        '  ',
        'a\nb',
        'a\tb',
        'a\u0000b',
        'a\uFFFF',
        String.fromCharCode(0xd800),
        '😀' * 2049,
      ])
        {'text': text},
    ];
    for (final extension in ['hwp', 'hwpx']) {
      for (final override in invalid) {
        await rejects(extension, [
          {..._insert(), ...override},
        ]);
      }
      await rejects(extension, [_insert(), _insert(id: 'draft-b')]);
      await rejects(extension, [
        _insert(),
        {..._insert(), 'referenceId': 's0:p1'},
      ]);
    }
  });
}
