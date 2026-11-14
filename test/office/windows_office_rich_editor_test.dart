import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/office/windows_office_engine.dart';
import 'package:saber/pages/office/windows_office_editor.dart';

String digest(String value) => sha256.convert(utf8.encode(value)).toString();

Map<String, Object?> textDetails(
  String text, {
  List<Map<String, Object?>> protectedRanges = const [],
}) => {
  'utf16Length': text.length,
  'textSha256': digest(text),
  'canReplace': true,
  'canStyle': true,
  'truncated': false,
  'protectedRanges': protectedRanges,
  'runs': [
    {
      'startUtf16': 0,
      'endUtf16': text.length,
      'fontSize': 12,
      'bold': false,
      'italic': false,
      'underline': false,
      'fontFamily': 'Arial',
      'color': 0,
    },
  ],
};

WindowsOfficeSnapshot wordFixture(
  String text, {
  List<Map<String, Object?>> protectedRanges = const [],
  bool mixed = false,
}) => WindowsOfficeSnapshot.fromJson({
  'kind': 'word',
  'sourceSha256': 'a' * 64,
  'paragraphs': [
    {
      'id': 'p0',
      'text': text,
      'fontSize': mixed ? null : 12,
      'bold': mixed ? null : false,
      'color': mixed ? null : 0,
      'textDetails': {
        ...textDetails(text, protectedRanges: protectedRanges),
        if (mixed)
          'runs': [
            {
              'startUtf16': 0,
              'endUtf16': 1,
              'fontSize': 12,
              'bold': false,
              'color': 0,
            },
            {
              'startUtf16': 1,
              'endUtf16': text.length,
              'fontSize': 24,
              'bold': true,
              'color': 0xb3261e,
            },
          ],
      },
    },
  ],
  'tables': [],
  'slides': [],
});

const thumbnail =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=';

WindowsOfficeSnapshot imageFixture() => WindowsOfficeSnapshot.fromJson({
  'kind': 'presentation',
  'sourceSha256': 'a' * 64,
  'paragraphs': [],
  'tables': [],
  'slides': [
    {
      'id': 's0',
      'width': 254,
      'height': 142.875,
      'shapes': [
        {
          'id': 's0/photo',
          'type': 'com.sun.star.drawing.GraphicObjectShape',
          'shapeKind': 'image',
          'text': '',
          'editableText': false,
          'x': 20,
          'y': 30,
          'width': 80,
          'height': 60,
          'image': {
            'mimeType': 'image/png',
            'pixelWidth': 1,
            'pixelHeight': 1,
            'canReplace': true,
            'thumbnailBase64': thumbnail,
            'thumbnailMimeType': 'image/png',
            'thumbnailSha256': sha256
                .convert(base64Decode(thumbnail))
                .toString(),
            'thumbnailTruncated': false,
          },
        },
        {
          'id': 's0/text',
          'type': 'com.sun.star.drawing.TextShape',
          'shapeKind': 'text',
          'text': '제목',
          'textDetails': textDetails('제목'),
          'editableText': true,
          'x': 110,
          'y': 10,
          'width': 100,
          'height': 30,
          'fontSize': 12,
          'bold': false,
          'color': 0,
        },
      ],
    },
  ],
});

Future<void> mount(
  WidgetTester tester,
  WindowsOfficeSnapshot snapshot, {
  required Future<void> Function(List<WindowsOfficeOperation>) commit,
  VoidCallback? back,
}) async {
  tester.view.physicalSize = const Size(1280, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: WindowsOfficeEditor(
        snapshot: snapshot,
        onCommit: commit,
        onBack: back ?? () {},
      ),
    ),
  );
}

final paragraphField = find.byKey(const ValueKey('office-paragraph-p0'));

Future<void> input(
  WidgetTester tester,
  Finder field,
  String text, {
  TextSelection? selection,
  TextRange composing = TextRange.empty,
}) async {
  await tester.tap(field);
  tester.testTextInput.updateEditingValue(
    TextEditingValue(
      text: text,
      selection: selection ?? TextSelection.collapsed(offset: text.length),
      composing: composing,
    ),
  );
  await tester.pump();
}

void main() {
  for (final sample in const [('', 0), ('prefix: ', 8)]) {
    testWidgets(
      'two hundred adjacent typing events become one native replacement at ${sample.$2}',
      (tester) async {
        List<Map<String, Object?>>? saved;
        final original = sample.$1;
        await mount(
          tester,
          wordFixture(original),
          commit: (operations) async {
            saved = [for (final operation in operations) operation.toJson()];
          },
        );
        await tester.tap(paragraphField);
        for (var count = 1; count <= 200; count++) {
          final text = original + 'x' * count;
          tester.testTextInput.updateEditingValue(
            TextEditingValue(
              text: text,
              selection: TextSelection.collapsed(offset: text.length),
            ),
          );
          await tester.pump();
        }
        await tester.tap(find.text('저장하고 닫기'));
        await tester.pumpAndSettle();
        expect(saved, hasLength(1));
        expect(saved!.single, {
          'op': 'textReplace',
          'targetKind': 'paragraph',
          'id': 'p0',
          'startUtf16': sample.$2,
          'endUtf16': sample.$2,
          'expectedTextSha256': digest(original),
          'text': 'x' * 200,
        });
      },
    );
  }

  testWidgets(
    'adjacent backspaces and replacement retain the original text hash',
    (tester) async {
      List<Map<String, Object?>>? saved;
      await mount(
        tester,
        wordFixture('ABCDE'),
        commit: (operations) async {
          saved = [for (final operation in operations) operation.toJson()];
        },
      );
      await input(tester, paragraphField, 'ABDE');
      await input(tester, paragraphField, 'ADE');
      await input(tester, paragraphField, 'AXE');
      await tester.tap(find.text('저장하고 닫기'));
      await tester.pumpAndSettle();
      expect(saved, hasLength(1));
      expect(saved!.single, {
        'op': 'textReplace',
        'targetKind': 'paragraph',
        'id': 'p0',
        'startUtf16': 1,
        'endUtf16': 4,
        'expectedTextSha256': digest('ABCDE'),
        'text': 'X',
      });
    },
  );

  testWidgets(
    'correction inside newly typed text reuses its native replacement',
    (tester) async {
      List<Map<String, Object?>>? saved;
      await mount(
        tester,
        wordFixture('AB'),
        commit: (operations) async {
          saved = [for (final operation in operations) operation.toJson()];
        },
      );
      await input(tester, paragraphField, 'AhelloB');
      await input(tester, paragraphField, 'AhXloB');
      await tester.tap(find.text('저장하고 닫기'));
      await tester.pumpAndSettle();
      expect(saved, hasLength(1));
      expect(saved!.single, {
        'op': 'textReplace',
        'targetKind': 'paragraph',
        'id': 'p0',
        'startUtf16': 1,
        'endUtf16': 1,
        'expectedTextSha256': digest('AB'),
        'text': 'hXlo',
      });
    },
  );

  testWidgets(
    'formatting between adjacent edits keeps the native operations separate',
    (tester) async {
      List<Map<String, Object?>>? saved;
      await mount(
        tester,
        wordFixture('AB'),
        commit: (operations) async {
          saved = [for (final operation in operations) operation.toJson()];
        },
      );
      await input(
        tester,
        paragraphField,
        'AXB',
        selection: const TextSelection(baseOffset: 1, extentOffset: 2),
      );
      await tester.tap(find.byKey(const ValueKey('office-bold-p0')));
      await tester.pump();
      await input(tester, paragraphField, 'AXYB');
      await tester.tap(find.text('저장하고 닫기'));
      await tester.pumpAndSettle();
      expect(saved, [
        {
          'op': 'textReplace',
          'targetKind': 'paragraph',
          'id': 'p0',
          'startUtf16': 1,
          'endUtf16': 1,
          'expectedTextSha256': digest('AB'),
          'text': 'X',
        },
        {
          'op': 'textStyle',
          'targetKind': 'paragraph',
          'id': 'p0',
          'startUtf16': 1,
          'endUtf16': 2,
          'expectedTextSha256': digest('AXB'),
          'bold': true,
        },
        {
          'op': 'textReplace',
          'targetKind': 'paragraph',
          'id': 'p0',
          'startUtf16': 2,
          'endUtf16': 2,
          'expectedTextSha256': digest('AXB'),
          'text': 'Y',
        },
      ]);
    },
  );

  testWidgets('adjacent edits in different original style runs stay separate', (
    tester,
  ) async {
    List<Map<String, Object?>>? saved;
    await mount(
      tester,
      wordFixture('AB', mixed: true),
      commit: (operations) async {
        saved = [for (final operation in operations) operation.toJson()];
      },
    );
    await input(tester, paragraphField, 'XB');
    await input(tester, paragraphField, 'XY');
    await tester.tap(find.text('저장하고 닫기'));
    await tester.pumpAndSettle();
    expect(saved, [
      {
        'op': 'textReplace',
        'targetKind': 'paragraph',
        'id': 'p0',
        'startUtf16': 0,
        'endUtf16': 1,
        'expectedTextSha256': digest('AB'),
        'text': 'X',
      },
      {
        'op': 'textReplace',
        'targetKind': 'paragraph',
        'id': 'p0',
        'startUtf16': 1,
        'endUtf16': 2,
        'expectedTextSha256': digest('XB'),
        'text': 'Y',
      },
    ]);
  });

  testWidgets(
    'typing at an original style boundary previews the observed native previous run',
    (tester) async {
      await mount(tester, wordFixture('AB', mixed: true), commit: (_) async {});
      await input(
        tester,
        paragraphField,
        'AXB',
        selection: const TextSelection(baseOffset: 1, extentOffset: 2),
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('office-font-p0')))
            .controller!
            .text,
        '12',
      );
      expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('office-bold-p0')))
            .isSelected,
        isFalse,
      );
    },
  );

  testWidgets(
    'selected emoji formatting uses UTF16 range after toolbar focus',
    (tester) async {
      List<Map<String, Object?>>? saved;
      const text = 'A😀éB';
      await mount(
        tester,
        wordFixture(text),
        commit: (operations) async {
          saved = [for (final operation in operations) operation.toJson()];
        },
      );
      await input(
        tester,
        paragraphField,
        text,
        selection: const TextSelection(baseOffset: 1, extentOffset: 3),
      );
      await tester.tap(find.byKey(const ValueKey('office-bold-p0')));
      await tester.pump();
      await tester.tap(find.text('저장하고 닫기'));
      await tester.pumpAndSettle();
      expect(saved, [
        {
          'op': 'textStyle',
          'targetKind': 'paragraph',
          'id': 'p0',
          'startUtf16': 1,
          'endUtf16': 3,
          'expectedTextSha256': digest(text),
          'bold': true,
        },
      ]);
    },
  );

  testWidgets(
    'two edits preserve field between them through failed save retry',
    (tester) async {
      final attempts = <List<Map<String, Object?>>>[];
      var closed = false;
      await mount(
        tester,
        wordFixture(
          'left 1 right',
          protectedRanges: [
            {'startUtf16': 5, 'endUtf16': 6, 'type': 'TextField'},
          ],
        ),
        commit: (operations) async {
          attempts.add([
            for (final operation in operations) operation.toJson(),
          ]);
          if (attempts.length == 1) throw StateError('Synthetic save failure');
        },
        back: () => closed = true,
      );
      await input(tester, paragraphField, 'Left 1 right');
      await input(tester, paragraphField, 'Left 1 righT');
      await tester.tap(find.text('저장하고 닫기'));
      await tester.pumpAndSettle();
      expect(closed, isFalse);
      await tester.tap(find.text('저장 재시도'));
      await tester.pumpAndSettle();
      expect(closed, isTrue);
      expect(attempts, hasLength(2));
      expect(attempts.last, attempts.first);
      expect(attempts.first, [
        {
          'op': 'textReplace',
          'targetKind': 'paragraph',
          'id': 'p0',
          'startUtf16': 0,
          'endUtf16': 1,
          'expectedTextSha256': digest('left 1 right'),
          'text': 'L',
        },
        {
          'op': 'textReplace',
          'targetKind': 'paragraph',
          'id': 'p0',
          'startUtf16': 11,
          'endUtf16': 12,
          'expectedTextSha256': digest('Left 1 right'),
          'text': 'T',
        },
      ]);
    },
  );

  testWidgets(
    'font input and style buttons retain the selected combining text',
    (tester) async {
      List<Map<String, Object?>>? saved;
      const text = 'A😀éB';
      await mount(
        tester,
        wordFixture(text),
        commit: (operations) async {
          saved = [for (final operation in operations) operation.toJson()];
        },
      );
      await input(
        tester,
        paragraphField,
        text,
        selection: const TextSelection(baseOffset: 3, extentOffset: 5),
      );
      await tester.tap(find.byKey(const ValueKey('office-italic-p0')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('office-underline-p0')));
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('office-font-p0')),
        '24',
      );
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('office-font-family-p0')),
        'Georgia',
      );
      await tester.pump();
      await tester.tap(find.text('저장하고 닫기'));
      await tester.pumpAndSettle();
      expect(saved, [
        for (final style in [
          {'italic': true},
          {'underline': true},
          {'fontSize': 24.0},
          {'fontFamily': 'Georgia'},
        ])
          {
            'op': 'textStyle',
            'targetKind': 'paragraph',
            'id': 'p0',
            'startUtf16': 3,
            'endUtf16': 5,
            'expectedTextSha256': digest(text),
            ...style,
          },
      ]);
    },
  );

  testWidgets(
    'table cell edits send the exact cell owner and sequential text hash',
    (tester) async {
      List<Map<String, Object?>>? saved;
      final snapshot = WindowsOfficeSnapshot.fromJson({
        'kind': 'word',
        'sourceSha256': 'a' * 64,
        'paragraphs': [],
        'slides': [],
        'tables': [
          {
            'id': 't0',
            'cells': {'A1': 'A😀B'},
            'cellTextDetails': {'A1': textDetails('A😀B')},
          },
        ],
      });
      await mount(
        tester,
        snapshot,
        commit: (operations) async {
          saved = [for (final operation in operations) operation.toJson()];
        },
      );
      await input(
        tester,
        find.byKey(const ValueKey('office-cell-t0-A1')),
        'A😀C',
      );
      await tester.tap(find.text('저장하고 닫기'));
      await tester.pumpAndSettle();
      expect(saved, [
        {
          'op': 'textReplace',
          'targetKind': 'cell',
          'id': 't0',
          'cell': 'A1',
          'startUtf16': 3,
          'endUtf16': 4,
          'expectedTextSha256': digest('A😀B'),
          'text': 'C',
        },
      ]);
    },
  );

  testWidgets('input cannot flatten a protected field into ordinary text', (
    tester,
  ) async {
    var commits = 0;
    await mount(
      tester,
      wordFixture(
        'left 1 right',
        protectedRanges: [
          {'startUtf16': 5, 'endUtf16': 6, 'type': 'TextField'},
        ],
      ),
      commit: (_) async {
        commits++;
      },
    );
    await input(tester, paragraphField, 'left 2 right');
    expect(
      tester.widget<TextField>(paragraphField).controller!.text,
      'left 1 right',
    );
    await tester.tap(find.text('저장하고 닫기'));
    await tester.pumpAndSettle();
    expect(commits, 0);
  });

  testWidgets(
    'insertion at a native protected field start keeps earlier valid edits',
    (tester) async {
      List<Map<String, Object?>>? saved;
      await mount(
        tester,
        wordFixture(
          'left 1 right',
          protectedRanges: [
            {'startUtf16': 5, 'endUtf16': 6, 'type': 'TextField'},
          ],
        ),
        commit: (operations) async {
          saved = [for (final operation in operations) operation.toJson()];
        },
      );
      await input(tester, paragraphField, 'Left 1 right');
      await input(tester, paragraphField, 'Left X1 right');
      expect(
        tester.widget<TextField>(paragraphField).controller!.text,
        'Left 1 right',
      );
      await tester.tap(find.text('저장하고 닫기'));
      await tester.pumpAndSettle();
      expect(saved, [
        {
          'op': 'textReplace',
          'targetKind': 'paragraph',
          'id': 'p0',
          'startUtf16': 0,
          'endUtf16': 1,
          'expectedTextSha256': digest('left 1 right'),
          'text': 'L',
        },
      ]);
    },
  );

  testWidgets(
    'paragraph editor rejects a structural newline instead of keeping an unsavable draft',
    (tester) async {
      var commits = 0;
      await mount(
        tester,
        wordFixture('내용'),
        commit: (_) async {
          commits++;
        },
      );
      await input(tester, paragraphField, '내용\n새 문단');
      expect(tester.widget<TextField>(paragraphField).controller!.text, '내용');
      await tester.tap(find.text('저장하고 닫기'));
      await tester.pumpAndSettle();
      expect(commits, 0);
    },
  );

  testWidgets('style can cross a zero-width bookmark without replacing it', (
    tester,
  ) async {
    List<Map<String, Object?>>? saved;
    await mount(
      tester,
      wordFixture(
        'AB',
        protectedRanges: [
          {'startUtf16': 1, 'endUtf16': 1, 'type': 'Bookmark'},
        ],
      ),
      commit: (operations) async {
        saved = [for (final operation in operations) operation.toJson()];
      },
    );
    await input(
      tester,
      paragraphField,
      'AB',
      selection: const TextSelection(baseOffset: 0, extentOffset: 2),
    );
    await tester.tap(find.byKey(const ValueKey('office-bold-p0')));
    await tester.pump();
    await tester.tap(find.text('저장하고 닫기'));
    await tester.pumpAndSettle();
    expect(saved, [
      {
        'op': 'textStyle',
        'targetKind': 'paragraph',
        'id': 'p0',
        'startUtf16': 0,
        'endUtf16': 2,
        'expectedTextSha256': digest('AB'),
        'bold': true,
      },
    ]);
  });

  testWidgets(
    'replacement touching a zero-width bookmark is rejected conservatively',
    (tester) async {
      var commits = 0;
      await mount(
        tester,
        wordFixture(
          'AB',
          protectedRanges: [
            {'startUtf16': 1, 'endUtf16': 1, 'type': 'Bookmark'},
          ],
        ),
        commit: (_) async {
          commits++;
        },
      );
      await input(tester, paragraphField, 'XB');
      expect(tester.widget<TextField>(paragraphField).controller!.text, 'AB');
      await tester.tap(find.text('저장하고 닫기'));
      await tester.pumpAndSettle();
      expect(commits, 0);
    },
  );

  testWidgets(
    'replacement ending before a field leaves the field and later text alone',
    (tester) async {
      List<Map<String, Object?>>? saved;
      await mount(
        tester,
        wordFixture(
          'AB1CD',
          protectedRanges: [
            {'startUtf16': 2, 'endUtf16': 3, 'type': 'TextField'},
          ],
        ),
        commit: (operations) async {
          saved = [for (final operation in operations) operation.toJson()];
        },
      );
      await input(tester, paragraphField, 'AX1CD');
      await tester.tap(find.text('저장하고 닫기'));
      await tester.pumpAndSettle();
      expect(saved, [
        {
          'op': 'textReplace',
          'targetKind': 'paragraph',
          'id': 'p0',
          'startUtf16': 1,
          'endUtf16': 2,
          'expectedTextSha256': digest('AB1CD'),
          'text': 'X',
        },
      ]);
    },
  );

  testWidgets('mixed typography is not presented as a uniform twelve points', (
    tester,
  ) async {
    var commits = 0;
    await mount(
      tester,
      wordFixture('AB', mixed: true),
      commit: (_) async {
        commits++;
      },
    );
    final font = tester.widget<TextField>(
      find.byKey(const ValueKey('office-font-p0')),
    );
    expect(font.controller!.text, isEmpty);
    await tester.tap(find.text('저장하고 닫기'));
    await tester.pumpAndSettle();
    expect(commits, 0);
  });

  testWidgets('save waits for active input composition to finish', (
    tester,
  ) async {
    final saved = <List<Map<String, Object?>>>[];
    await mount(
      tester,
      wordFixture('A'),
      commit: (operations) async {
        saved.add([for (final operation in operations) operation.toJson()]);
      },
    );
    await input(
      tester,
      paragraphField,
      'A한',
      composing: const TextRange(start: 1, end: 2),
    );
    await tester.tap(find.text('저장하고 닫기'));
    await tester.pumpAndSettle();
    expect(saved, isEmpty);
    await input(tester, paragraphField, 'A한');
    await tester.tap(find.text('저장하고 닫기'));
    await tester.pumpAndSettle();
    expect(saved, hasLength(1));
    expect(saved.single.single['op'], 'textReplace');
    expect(saved.single.single['text'], '한');
  });

  testWidgets('editing slide text keeps the existing photo in draft view', (
    tester,
  ) async {
    await mount(tester, imageFixture(), commit: (_) async {});
    expect(find.byType(Image), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('office-shape-s0/text')));
    await tester.pump();
    await input(
      tester,
      find.byKey(const ValueKey('office-shape-text')),
      '바뀐 제목',
    );
    expect(find.byType(Image), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
