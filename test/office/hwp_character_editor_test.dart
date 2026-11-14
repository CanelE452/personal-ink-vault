import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/office/windows_office_engine.dart';
import 'package:saber/pages/office/windows_office_editor.dart';

const _id = 's0:p0';
const _tableId = 's0:p1:t0';
const _cell = '0,0';
const _styles = {'bold', 'italic', 'underline', 'fontSize', 'color'};
const _text = '가😀e\u0301나';

String _digest(String text) => sha256.convert(utf8.encode(text)).toString();

Map<String, Object?> _details(
  String text, {
  bool canStyle = true,
  bool italic = false,
  bool underline = false,
}) => {
  'utf16Length': text.length,
  'textSha256': _digest(text),
  'canReplace': true,
  'canStyle': canStyle,
  'truncated': false,
  'protectedRanges': <Object?>[],
  'runs': [
    {
      'startUtf16': 0,
      'endUtf16': text.length,
      'fontSize': 12,
      'bold': false,
      'italic': italic,
      'underline': underline,
      'color': 0,
    },
  ],
};

WindowsOfficeSnapshot _snapshot({
  String text = _text,
  bool cell = false,
  bool rich = true,
  bool canStyle = true,
  bool italic = false,
  bool underline = false,
}) => WindowsOfficeSnapshot.fromJson({
  'kind': 'word',
  'sourceSha256': 'a' * 64,
  'paragraphs': [
    if (!cell)
      {
        'id': _id,
        'text': text,
        'paragraphFormat': {'alignment': 'left'},
        if (rich)
          'textDetails': _details(text, canStyle: canStyle, italic: italic),
      },
  ],
  'tables': [
    if (cell)
      {
        'id': _tableId,
        'cells': {_cell: text},
        if (rich)
          'cellTextDetails': {
            _cell: _details(
              text,
              canStyle: canStyle,
              italic: italic,
              underline: underline,
            ),
          },
      },
  ],
  'slides': <Object?>[],
});

Finder _field({bool cell = false}) => find.byKey(
  ValueKey(cell ? 'office-cell-$_tableId-$_cell' : 'office-paragraph-$_id'),
);

Future<GlobalKey<WindowsOfficeEditorState>> _mount(
  WidgetTester tester, {
  WindowsOfficeSnapshot? snapshot,
  Set<String>? styles = _styles,
  bool allowFormatting = false,
  required Future<void> Function(List<WindowsOfficeOperation>) commit,
  FutureOr<void> Function()? back,
}) async {
  tester.view.physicalSize = const Size(1280, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final key = GlobalKey<WindowsOfficeEditorState>();
  await tester.pumpWidget(
    MaterialApp(
      home: WindowsOfficeEditor(
        key: key,
        snapshot: snapshot ?? _snapshot(),
        allowFormatting: allowFormatting,
        allowParagraphAlignment: true,
        allowedTextStyleProperties: styles,
        onCommit: commit,
        onBack: back ?? () {},
      ),
    ),
  );
  await tester.pump();
  return key;
}

Future<void> _input(
  WidgetTester tester,
  String text, {
  bool cell = false,
  required int start,
  required int end,
}) async {
  await tester.ensureVisible(_field(cell: cell));
  await tester.tap(_field(cell: cell));
  tester.testTextInput.updateEditingValue(
    TextEditingValue(
      text: text,
      selection: TextSelection(baseOffset: start, extentOffset: end),
    ),
  );
  await tester.pump();
}

Map<String, Object?> _style(
  Map<String, Object?> format, {
  bool cell = false,
  String text = _text,
  int start = 1,
  int end = 5,
}) => {
  'op': 'textStyle',
  'targetKind': cell ? 'cell' : 'paragraph',
  'id': cell ? _tableId : _id,
  if (cell) 'cell': _cell,
  'startUtf16': start,
  'endUtf16': end,
  'expectedTextSha256': _digest(text),
  ...format,
};

void main() {
  testWidgets('HWP grants only supported rich character tools', (tester) async {
    await _mount(tester, commit: (_) async {});
    expect(find.byTooltip('굵게'), findsOneWidget);
    expect(find.byTooltip('글자 색'), findsOneWidget);
    expect(find.text('글자 크기(pt)'), findsOneWidget);
    expect(find.byTooltip('기울임'), findsOneWidget);
    expect(find.byTooltip('밑줄'), findsOneWidget);
    expect(find.text('글꼴'), findsNothing);
    expect(find.byTooltip('개체 추가'), findsNothing);
    expect(
      find.byKey(const ValueKey('office-paragraph-alignment-$_id-center')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('office-bold-$_id')))
          .onPressed,
      isNull,
    );
    expect(tester.widget<TextField>(_field()).readOnly, isFalse);
  });

  testWidgets(
    'HWP styles the selected emoji and combining text through toolbar focus',
    (tester) async {
      List<Map<String, Object?>>? saved;
      await _mount(
        tester,
        commit: (operations) async {
          saved = [for (final operation in operations) operation.toJson()];
        },
      );
      await _input(tester, _text, start: 1, end: 5);
      await tester.tap(find.byKey(const ValueKey('office-bold-$_id')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('office-italic-$_id')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('office-underline-$_id')));
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('office-font-$_id')),
        '24',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('office-text-color-$_id')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('파랑').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('저장하고 닫기'));
      await tester.pumpAndSettle();
      expect(saved, [
        _style({'bold': true}),
        _style({'italic': true}),
        _style({'underline': true}),
        _style({'fontSize': 24.0}),
        _style({'color': 0x2457a7}),
      ]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'HWP typing then styling uses the changed text digest and coordinates',
    (tester) async {
      List<Map<String, Object?>>? saved;
      await _mount(
        tester,
        commit: (operations) async {
          saved = [for (final operation in operations) operation.toJson()];
        },
      );
      const changed = '가새😀e\u0301나';
      await _input(tester, changed, start: 1, end: 2);
      await tester.tap(find.byKey(const ValueKey('office-bold-$_id')));
      await tester.pump();
      await tester.tap(find.text('저장하고 닫기'));
      await tester.pumpAndSettle();
      expect(saved, [
        {
          'op': 'textReplace',
          'targetKind': 'paragraph',
          'id': _id,
          'startUtf16': 1,
          'endUtf16': 1,
          'expectedTextSha256': _digest(_text),
          'text': '새',
        },
        _style({'bold': true}, text: changed, start: 1, end: 2),
      ]);
    },
  );

  testWidgets(
    'HWP selection styling and alignment remain separate operations',
    (tester) async {
      List<Map<String, Object?>>? saved;
      await _mount(
        tester,
        commit: (operations) async {
          saved = [for (final operation in operations) operation.toJson()];
        },
      );
      await _input(tester, _text, start: 1, end: 5);
      await tester.tap(find.byKey(const ValueKey('office-bold-$_id')));
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('office-paragraph-alignment-$_id-center')),
      );
      await tester.pump();
      await tester.tap(find.text('저장하고 닫기'));
      await tester.pumpAndSettle();
      expect(saved, [
        _style({'bold': true}),
        {
          'op': 'paragraphFormat',
          'id': _id,
          'expectedTextSha256': _digest(_text),
          'alignment': 'center',
        },
      ]);
    },
  );

  testWidgets(
    'HWP preserves selected style operations and text after failed save',
    (tester) async {
      final attempts = <List<Map<String, Object?>>>[];
      var closed = false;
      await _mount(
        tester,
        commit: (operations) async {
          attempts.add([
            for (final operation in operations) operation.toJson(),
          ]);
          if (attempts.length == 1) throw StateError('Synthetic save failure');
        },
        back: () => closed = true,
      );
      await _input(tester, _text, start: 1, end: 5);
      await tester.tap(find.byKey(const ValueKey('office-bold-$_id')));
      await tester.pump();
      await tester.tap(find.text('저장하고 닫기'));
      await tester.pumpAndSettle();
      expect(closed, isFalse);
      expect(tester.widget<TextField>(_field()).controller!.text, _text);
      await tester.tap(find.text('저장 재시도'));
      await tester.pumpAndSettle();
      expect(closed, isTrue);
      expect(attempts, [
        [
          _style({'bold': true}),
        ],
        [
          _style({'bold': true}),
        ],
      ]);
    },
  );

  testWidgets(
    'HWP rejects invalid visible size input without losing valid styles',
    (tester) async {
      List<Map<String, Object?>>? saved;
      await _mount(
        tester,
        commit: (operations) async {
          saved = [for (final operation in operations) operation.toJson()];
        },
      );
      await _input(tester, _text, start: 1, end: 5);
      await tester.tap(find.byKey(const ValueKey('office-bold-$_id')));
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('office-font-$_id')),
        '0',
      );
      await tester.pump();
      await tester.tap(find.text('저장하고 닫기'));
      await tester.pumpAndSettle();
      expect(saved, isNull);
      expect(find.textContaining('글자 크기는 1~400pt'), findsWidgets);
      await tester.enterText(
        find.byKey(const ValueKey('office-font-$_id')),
        '24',
      );
      await tester.pump();
      await tester.tap(find.text('저장하고 닫기'));
      await tester.pumpAndSettle();
      expect(saved, [
        _style({'bold': true}),
        _style({'fontSize': 24.0}),
      ]);
    },
  );

  testWidgets('HWP a smaller character capability grants only its own tool', (
    tester,
  ) async {
    await _mount(tester, styles: const {'bold'}, commit: (_) async {});
    expect(find.byTooltip('굵게'), findsOneWidget);
    expect(find.byTooltip('기울임'), findsNothing);
    expect(find.byTooltip('글자 색'), findsNothing);
    expect(find.text('글자 크기(pt)'), findsNothing);
  });

  for (final sample in const [
    ('가e\u0301나', 1, 2),
    ('가👨\u200d👩\u200d👧나', 1, 3),
  ]) {
    testWidgets('HWP selection tools reject a split grapheme: ${sample.$1}', (
      tester,
    ) async {
      await _mount(
        tester,
        snapshot: _snapshot(text: sample.$1),
        commit: (_) async {},
      );
      await _input(tester, sample.$1, start: sample.$2, end: sample.$3);
      expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('office-bold-$_id')))
            .onPressed,
        isNull,
      );
      await _input(tester, sample.$1, start: 1, end: sample.$1.length - 1);
      expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('office-bold-$_id')))
            .onPressed,
        isNotNull,
      );
    });
  }

  testWidgets('default Office retains its existing grapheme selection policy', (
    tester,
  ) async {
    const text = '가e\u0301나';
    await _mount(
      tester,
      snapshot: _snapshot(text: text),
      styles: null,
      allowFormatting: true,
      commit: (_) async {},
    );
    await _input(tester, text, start: 1, end: 2);
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('office-bold-$_id')))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets(
    'HWP typing inside a grapheme replaces the complete source cluster',
    (tester) async {
      const original = '가e\u0301나';
      const changed = '가e\u0300나';
      List<Map<String, Object?>>? saved;
      await _mount(
        tester,
        snapshot: _snapshot(text: original),
        commit: (operations) async {
          saved = [for (final operation in operations) operation.toJson()];
        },
      );
      await _input(tester, changed, start: 1, end: 3);
      await tester.tap(find.byKey(const ValueKey('office-bold-$_id')));
      await tester.pump();
      await tester.tap(find.text('저장하고 닫기'));
      await tester.pumpAndSettle();
      expect(saved, [
        {
          'op': 'textReplace',
          'targetKind': 'paragraph',
          'id': _id,
          'startUtf16': 1,
          'endUtf16': 3,
          'expectedTextSha256': _digest(original),
          'text': 'e\u0300',
        },
        _style({'bold': true}, text: changed, start: 1, end: 3),
      ]);
    },
  );

  testWidgets(
    'HWP single-paragraph table cell exposes the same selection tools',
    (tester) async {
      List<Map<String, Object?>>? saved;
      await _mount(
        tester,
        snapshot: _snapshot(cell: true, italic: true, underline: true),
        commit: (operations) async {
          saved = [for (final operation in operations) operation.toJson()];
        },
      );
      await _input(tester, _text, cell: true, start: 1, end: 5);
      final bold = find.byKey(const ValueKey('office-bold-$_tableId-$_cell'));
      await tester.ensureVisible(bold);
      await tester.tap(bold);
      await tester.pump();
      final italic = find.byKey(
        const ValueKey('office-italic-$_tableId-$_cell'),
      );
      await tester.ensureVisible(italic);
      expect(tester.widget<IconButton>(italic).isSelected, isTrue);
      await tester.tap(italic);
      await tester.pump();
      final underline = find.byKey(
        const ValueKey('office-underline-$_tableId-$_cell'),
      );
      await tester.ensureVisible(underline);
      expect(tester.widget<IconButton>(underline).isSelected, isTrue);
      await tester.tap(underline);
      await tester.pump();
      await tester.tap(find.text('저장하고 닫기'));
      await tester.pumpAndSettle();
      expect(saved, [
        _style({'bold': true}, cell: true),
        _style({'italic': false}, cell: true),
        _style({'underline': false}, cell: true),
      ]);
    },
  );

  for (final styles in <Set<String>?>[null, const {}]) {
    testWidgets(
      'HWP null or empty capability keeps character tools hidden: $styles',
      (tester) async {
        await _mount(tester, styles: styles, commit: (_) async {});
        expect(find.byTooltip('굵게'), findsNothing);
        expect(find.byTooltip('글자 색'), findsNothing);
        expect(find.text('글자 크기(pt)'), findsNothing);
        expect(tester.widget<TextField>(_field()).readOnly, isFalse);
      },
    );
  }

  for (final rich in [true, false]) {
    testWidgets(
      'HWP does not grant styles without engine metadata: rich=$rich',
      (tester) async {
        await _mount(
          tester,
          snapshot: _snapshot(rich: rich, canStyle: false),
          commit: (_) async {},
        );
        expect(find.byTooltip('굵게'), findsNothing);
        expect(find.byTooltip('글자 색'), findsNothing);
        expect(find.text('글자 크기(pt)'), findsNothing);
        expect(tester.widget<TextField>(_field()).readOnly, isFalse);
      },
    );
  }
}
