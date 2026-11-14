import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/office/hwp_office_engine.dart';
import 'package:saber/data/office/windows_office_engine.dart';
import 'package:saber/pages/office/windows_office_editor.dart';

const _paragraphId = 's0:p0';
const _originalText = '한글 원문 😀';
const _alignments = ['left', 'center', 'right', 'justify'];

String _digest(String value) => sha256.convert(utf8.encode(value)).toString();

WindowsOfficeSnapshot _snapshot({
  String text = _originalText,
  String? alignment = 'left',
  String sourceHash = 'a',
}) => WindowsOfficeSnapshot.fromJson({
  'kind': 'word',
  'sourceSha256': sourceHash * 64,
  'paragraphs': [
    {
      'id': _paragraphId,
      'text': text,
      if (alignment != null) 'paragraphFormat': {'alignment': alignment},
    },
  ],
  'tables': [
    {
      'id': 's0:p1:t0',
      'cells': {'0,0': '표 셀'},
    },
  ],
  'slides': [],
});

Finder _alignment(String value) =>
    find.byKey(ValueKey('office-paragraph-alignment-$_paragraphId-$value'));

Finder get _paragraph =>
    find.byKey(const ValueKey('office-paragraph-$_paragraphId'));

Future<GlobalKey<WindowsOfficeEditorState>> _mount(
  WidgetTester tester, {
  WindowsOfficeSnapshot? snapshot,
  required Future<void> Function(List<WindowsOfficeOperation>) commit,
  FutureOr<void> Function()? back,
  ValueChanged<bool>? dirty,
  bool alignmentEnabled = true,
  Size size = const Size(1000, 800),
  GlobalKey<WindowsOfficeEditorState>? key,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final editorKey = key ?? GlobalKey<WindowsOfficeEditorState>();
  await tester.pumpWidget(
    MaterialApp(
      home: WindowsOfficeEditor(
        key: editorKey,
        snapshot: snapshot ?? _snapshot(),
        allowFormatting: false,
        allowParagraphAlignment: alignmentEnabled,
        onCommit: commit,
        onBack: back ?? () {},
        onDirtyChanged: dirty,
      ),
    ),
  );
  await tester.pump();
  return editorKey;
}

Map<String, Object?> _format(String alignment) => {
  'op': 'paragraphFormat',
  'id': _paragraphId,
  'expectedTextSha256': _digest(_originalText),
  'alignment': alignment,
};

void main() {
  for (final value in _alignments) {
    testWidgets(
      'HWP $value alignment is independent of typography permission',
      (tester) async {
        List<Map<String, Object?>>? saved;
        final dirty = <bool>[];
        var closed = false;
        await _mount(
          tester,
          snapshot: _snapshot(alignment: value == 'left' ? 'center' : 'left'),
          commit: (operations) async {
            saved = [for (final operation in operations) operation.toJson()];
          },
          dirty: dirty.add,
          back: () {
            closed = true;
          },
        );
        expect(find.byTooltip('굵게'), findsNothing);
        expect(find.byTooltip('글자 색'), findsNothing);
        expect(find.text('글자 크기(pt)'), findsNothing);
        expect(find.byTooltip('개체 추가'), findsNothing);
        await tester.tap(_alignment(value));
        await tester.pump();
        expect(tester.widget<IconButton>(_alignment(value)).isSelected, isTrue);
        await tester.tap(find.text('저장하고 닫기'));
        await tester.pumpAndSettle();
        expect(saved, [_format(value)]);
        expect(dirty, [true, false]);
        expect(closed, isTrue);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('HWP combined text and alignment use the original UTF8 digest', (
    tester,
  ) async {
    List<Map<String, Object?>>? saved;
    await _mount(
      tester,
      commit: (operations) async {
        saved = [for (final operation in operations) operation.toJson()];
      },
    );
    await tester.enterText(_paragraph, '바뀐 문단 e\u0301 👨‍👩‍👧');
    await tester.tap(_alignment('justify'));
    await tester.pump();
    await tester.tap(find.text('저장하고 닫기'));
    await tester.pumpAndSettle();
    expect(saved, [
      {
        'op': 'paragraphText',
        'id': _paragraphId,
        'text': '바뀐 문단 e\u0301 👨‍👩‍👧',
      },
      _format('justify'),
    ]);
    expect(
      saved!.last['expectedTextSha256'],
      isNot(_digest('바뀐 문단 e\u0301 👨‍👩‍👧')),
    );
  });

  testWidgets(
    'HWP selecting the source alignment again removes the pending format',
    (tester) async {
      final dirty = <bool>[];
      var commits = 0;
      await _mount(
        tester,
        dirty: dirty.add,
        commit: (_) async {
          commits++;
        },
      );
      await tester.tap(_alignment('center'));
      await tester.pump();
      await tester.tap(_alignment('left'));
      await tester.pump();
      await tester.tap(find.text('저장하고 닫기'));
      await tester.pumpAndSettle();
      expect(commits, 0);
      expect(dirty, [true, false]);
    },
  );

  testWidgets(
    'HWP failed save retains alignment and retries the exact same batch',
    (tester) async {
      final batches = <List<Map<String, Object?>>>[];
      var closed = false;
      await _mount(
        tester,
        commit: (operations) async {
          batches.add([for (final operation in operations) operation.toJson()]);
          if (batches.length == 1) throw StateError('synthetic write failure');
        },
        back: () {
          closed = true;
        },
      );
      await tester.enterText(_paragraph, '저장할 내용');
      await tester.tap(_alignment('right'));
      await tester.pump();
      await tester.tap(find.text('저장하고 닫기'));
      await tester.pumpAndSettle();
      expect(closed, isFalse);
      expect(find.textContaining('저장하지 못했습니다'), findsOneWidget);
      expect(tester.widget<TextField>(_paragraph).controller!.text, '저장할 내용');
      expect(tester.widget<IconButton>(_alignment('right')).isSelected, isTrue);
      await tester.tap(find.text('저장 재시도'));
      await tester.pumpAndSettle();
      expect(batches, hasLength(2));
      expect(batches.first, batches.last);
      expect(batches.last.last, _format('right'));
      expect(closed, isTrue);
    },
  );

  testWidgets('HWP alignment controls cannot mutate a batch while saving', (
    tester,
  ) async {
    final pending = Completer<void>();
    List<Map<String, Object?>>? saved;
    final key = await _mount(
      tester,
      commit: (operations) {
        saved = [for (final operation in operations) operation.toJson()];
        return pending.future;
      },
    );
    await tester.tap(_alignment('center'));
    await tester.pump();
    final save = key.currentState!.save();
    await tester.pump();
    for (final value in _alignments) {
      expect(tester.widget<IconButton>(_alignment(value)).onPressed, isNull);
    }
    pending.complete();
    await tester.pump();
    await save;
    expect(saved, [_format('center')]);
  });

  testWidgets(
    'HWP snapshot replacement drops stale alignment and ignores old save completion',
    (tester) async {
      final pending = Completer<void>();
      var closed = 0;
      final key = await _mount(
        tester,
        commit: (_) => pending.future,
        back: () {
          closed++;
        },
      );
      await tester.tap(_alignment('center'));
      await tester.pump();
      final oldSave = key.currentState!.save();
      await tester.pump();
      await _mount(
        tester,
        key: key,
        snapshot: _snapshot(text: '다른 판본', alignment: 'right', sourceHash: 'b'),
        commit: (_) async {},
        back: () {
          closed++;
        },
      );
      expect(tester.widget<TextField>(_paragraph).controller!.text, '다른 판본');
      expect(tester.widget<IconButton>(_alignment('right')).isSelected, isTrue);
      expect(
        tester.widget<IconButton>(_alignment('center')).isSelected,
        isFalse,
      );
      pending.complete();
      await tester.pump();
      await oldSave;
      expect(closed, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'HWP absent alignment metadata keeps text editing without guessed formatting',
    (tester) async {
      List<Map<String, Object?>>? saved;
      await _mount(
        tester,
        snapshot: _snapshot(alignment: null),
        commit: (operations) async {
          saved = [for (final operation in operations) operation.toJson()];
        },
      );
      for (final value in _alignments) {
        expect(_alignment(value), findsNothing);
      }
      await tester.enterText(_paragraph, '텍스트만 변경');
      await tester.tap(find.text('저장하고 닫기'));
      await tester.pumpAndSettle();
      expect(saved, [
        {'op': 'paragraphText', 'id': _paragraphId, 'text': '텍스트만 변경'},
      ]);
    },
  );

  testWidgets('HWP other alignment is preserved until explicitly selected', (
    tester,
  ) async {
    List<Map<String, Object?>>? saved;
    await _mount(
      tester,
      snapshot: _snapshot(alignment: 'other'),
      commit: (operations) async {
        saved = [for (final operation in operations) operation.toJson()];
      },
    );
    for (final value in _alignments) {
      expect(tester.widget<IconButton>(_alignment(value)).isSelected, isFalse);
    }
    await tester.tap(_alignment('left'));
    await tester.pump();
    await tester.tap(find.text('저장하고 닫기'));
    await tester.pumpAndSettle();
    expect(saved, [_format('left')]);
  });

  testWidgets(
    'HWP paragraph alignment is hidden unless the separate capability is enabled',
    (tester) async {
      await _mount(tester, alignmentEnabled: false, commit: (_) async {});
      for (final value in _alignments) {
        expect(_alignment(value), findsNothing);
      }
    },
  );

  testWidgets('HWP alignment actions and save fit a 320px display', (
    tester,
  ) async {
    List<Map<String, Object?>>? saved;
    await _mount(
      tester,
      size: const Size(320, 900),
      commit: (operations) async {
        saved = [for (final operation in operations) operation.toJson()];
      },
    );
    for (final value in _alignments) {
      final rect = tester.getRect(_alignment(value));
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(320));
      await tester.tap(_alignment(value));
      await tester.pump();
    }
    await tester.tap(find.text('저장하고 닫기'));
    await tester.pumpAndSettle();
    expect(saved, [_format('justify')]);
    expect(tester.takeException(), isNull);
  });

  group('HWP alignment adapter contract', _adapterTests);
}

void _adapterTests() {
  late Directory directory;
  late File source, edited, pdf;
  late String sourceHash, editedHash, pdfHash;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'piv-hwp-alignment-contract-',
    );
    source = await File('${directory.path}/original.hwpx')
        .writeAsBytes([1, 2, 3]);
    edited = await File('${directory.path}/edited.hwpx')
        .writeAsBytes([4, 5, 6]);
    pdf = await File('${directory.path}/preview.pdf')
        .writeAsString('%PDF-1.7\nfixture');
    sourceHash = sha256.convert(await source.readAsBytes()).toString();
    editedHash = sha256.convert(await edited.readAsBytes()).toString();
    pdfHash = sha256.convert(await pdf.readAsBytes()).toString();
  });
  tearDown(() async {
    final root = await Directory.systemTemp.resolveSymbolicLinks();
    final owned = await directory.resolveSymbolicLinks();
    expect(Directory(owned).parent.path, root);
    expect(
      directory.uri.pathSegments.where((part) => part.isNotEmpty).last,
      startsWith('piv-hwp-alignment-contract-'),
    );
    await directory.delete(recursive: true);
  });

  Map<String, dynamic> response(Map<String, Object?> request) => {
    'status': 'saved',
    'sessionId': request['sessionId'],
    'sourcePath': edited.path,
    'pdfPath': pdf.path,
    'sourceSha256': editedHash,
    'pdfSha256': pdfHash,
    'pdfPageCount': 1,
    'engineVersion': 'synthetic-contract',
    'snapshot': {
      'kind': 'word',
      'sourceSha256': editedHash,
      'paragraphs': [
        {
          'id': _paragraphId,
          'text': _originalText,
          'paragraphFormat': {'alignment': 'center'},
        },
      ],
      'tables': [],
      'slides': [],
    },
  };

  for (final value in _alignments) {
    test(
      'HWP adapter forwards only the closed $value alignment operation',
      () async {
        List<Object?>? forwarded;
        final engine = HwpStructuredOfficeEngine(
          runner: (request) async {
            expect(request['expectedSourceSha256'], sourceHash);
            forwarded = request['operations'] as List;
            return response(request);
          },
        );
        final result = await engine.apply(
          source.path,
          sessionId: 'alignment-$value',
          expectedSourceSha256: sourceHash,
          operations: [
            WindowsOfficeOperation.paragraphFormat(
              id: _paragraphId,
              expectedTextSha256: _digest(_originalText),
              alignment: value,
            ),
          ],
        );
        expect(forwarded, [_format(value)]);
        expect(result.sourceSha256, editedHash);
        expect(result.pdfSha256, pdfHash);
        expect(await source.readAsBytes(), [1, 2, 3]);
      },
    );
  }

  for (final formatFirst in [true, false]) {
    test(
      'HWP adapter retains text and alignment batch order formatFirst=$formatFirst',
      () async {
        final format = _format('center');
        final text = <String, Object?>{
          'op': 'paragraphText',
          'id': _paragraphId,
          'text': '새 원문',
        };
        final operations = formatFirst ? [format, text] : [text, format];
        final engine = HwpOfficeEngine(
          runner: (request) async {
            expect(request['operations'], operations);
            return response(request);
          },
        );
        await engine.apply(
          source.path,
          sessionId: 'both-$formatFirst',
          expectedSourceSha256: sourceHash,
          operations: operations,
        );
      },
    );
  }

  final invalid = <String, Map<String, Object?>>{
    'unknown field': {..._format('left'), 'future': true},
    'styleName': {..._format('left'), 'styleName': 'Body'},
    'null styleName': {..._format('left'), 'styleName': null},
    'listKind': {..._format('left'), 'listKind': 'bullet'},
    'page break': {..._format('left'), 'pageBreakBefore': false},
    'unsupported alignment': {..._format('other')},
    'missing alignment': {
      'op': 'paragraphFormat',
      'id': _paragraphId,
      'expectedTextSha256': _digest(_originalText),
    },
    'invalid digest': {..._format('left'), 'expectedTextSha256': 'stale'},
    'missing digest': {
      'op': 'paragraphFormat',
      'id': _paragraphId,
      'alignment': 'left',
    },
    'invalid id': {..._format('left'), 'id': ''},
  };
  for (final entry in invalid.entries) {
    test(
      'HWP adapter rejects ${entry.key} before invoking the writer',
      () async {
        var called = false;
        final engine = HwpOfficeEngine(
          runner: (request) async {
            called = true;
            return response(request);
          },
        );
        await expectLater(
          engine.apply(
            source.path,
            sessionId: 'invalid',
            operations: [entry.value],
          ),
          throwsA(
            isA<HwpOfficeException>().having(
              (error) => error.code,
              'code',
              'invalid_request',
            ),
          ),
        );
        expect(called, isFalse);
        expect(await source.readAsBytes(), [1, 2, 3]);
      },
    );
  }
}
