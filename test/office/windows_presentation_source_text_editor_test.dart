import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/office/office_image_asset.dart';
import 'package:saber/data/office/windows_office_engine.dart';
import 'package:saber/pages/office/windows_office_editor.dart';

const _owner = 'slide-0';
const _first = 'slide-0/shape-7';
const _second = 'slide-0/shape-8';
String _digest(String text) => sha256.convert(utf8.encode(text)).toString();

Map<String, dynamic> _patch(
  String text, {
  bool editable = true,
  bool protected = false,
}) => {
  'canReplace': editable,
  'truncated': false,
  'text': text,
  'utf16Length': text.length,
  'textSha256': _digest(text),
  'segments': protected
      ? [
          {'startUtf16': 0, 'endUtf16': 1, 'editable': true},
          {'startUtf16': 1, 'endUtf16': 2, 'editable': false},
          {'startUtf16': 2, 'endUtf16': text.length, 'editable': true},
        ]
      : [
          {'startUtf16': 0, 'endUtf16': text.length, 'editable': true},
        ],
  'protectedRanges': protected
      ? [
          {'startUtf16': 1, 'endUtf16': 2, 'reason': 'field'},
        ]
      : [],
};

Map<String, dynamic> _table(
  String id,
  String text, {
  bool editable = true,
  bool protected = false,
  bool missingMap = false,
}) => {
  'id': id,
  'ownerId': _owner,
  'tableSha256': null,
  'rowCount': 1,
  'columnCount': 2,
  'totalCellCount': 2,
  'truncated': false,
  'rowHeightsHmm': [3500],
  'columnWidthsHmm': [11000, 11000],
  'nativeBoundsHmm': {'x': 1500, 'y': 3000, 'width': 21999, 'height': 3500},
  'authoredGeometry': {
    'sourcePart': 'ppt/slides/slide1.xml',
    'shapeId': id == _first ? '9' : '10',
    'positionEmu': {'x': 540000, 'y': 1080000},
    'extentEmu': {'width': 7920000, 'height': 1260000},
    'columnWidthsEmu': [3960000, 3960000],
    'rowHeightsEmu': [1260000],
  },
  'rawStyle': {},
  'capabilities': {},
  'sourceTextPatchAuthority': {
    'kind': 'sourceTextPatch',
    'version': 1,
    'sourceSha256': 'a' * 64,
    'sourcePart': 'ppt/slides/slide1.xml',
    'shapeId': id == _first ? '9' : '10',
    'frameSha256': id == _first ? 'b' * 64 : 'c' * 64,
  },
  'cells': [
    for (var column = 0; column < 2; column++)
      {
        'id': '$id/cell-$column',
        'row': 0,
        'column': column,
        'rowSpan': 1,
        'columnSpan': 1,
        'covered': false,
        'anchorCellId': null,
        'text': column == 0 ? text : 'untouched',
        'textDetails': {
          'utf16Length': column == 0 ? text.length : 9,
          'textSha256': column == 0 ? _digest(text) : _digest('untouched'),
          'truncated': true,
          'canReplace': false,
          'canStyle': false,
          'runs': [],
          'protectedRanges': [],
        },
        'rawStyle': {},
        if (!missingMap)
          'sourceTextPatch': _patch(
            column == 0 ? text : 'untouched',
            editable: editable,
            protected: column == 0 && protected,
          ),
      },
  ],
};

Map<String, dynamic> _wire({
  String first = 'A😀BC',
  String second = 'A😀BC',
  bool editable = true,
  bool protected = false,
  bool missingMap = false,
}) => {
  'kind': 'presentation',
  'sourceSha256': 'a' * 64,
  'paragraphs': [],
  'tables': [],
  'masters': [],
  'layoutOptions': [],
  'slides': [
    {
      'id': _owner,
      'width': 280,
      'height': 157.5,
      'presentationTables': [
        _table(
          _first,
          first,
          editable: editable,
          protected: protected,
          missingMap: missingMap,
        ),
        _table(_second, second),
      ],
      'presentationTableCount': 2,
      'presentationTablesTruncated': false,
      'canAddTable': false,
      'shapes': [
        for (final id in [_first, _second])
          {
            'id': id,
            'ownerId': _owner,
            'ownerKind': 'slide',
            'type': 'com.sun.star.drawing.TableShape',
            'text': '',
            'editableText': false,
            'canEditTextStyle': false,
            'canEditGeometry': false,
            'canDelete': false,
            'x': 15,
            'y': 30,
            'width': 219.99,
            'height': 35,
          },
      ],
    },
  ],
};

WindowsOfficeSnapshot _snapshot({
  String first = 'A😀BC',
  String second = 'A😀BC',
  bool editable = true,
  bool protected = false,
  bool missingMap = false,
}) => WindowsOfficeSnapshot.fromJson(
  _wire(
    first: first,
    second: second,
    editable: editable,
    protected: protected,
    missingMap: missingMap,
  ),
);
WindowsOfficeSnapshot _draftSnapshot({String first = 'A😀BC'}) {
  final wire = _wire();
  wire['slides'][0]['presentationTables'][0]['cells'][0]['sourceTextPatch'] =
      _patch(first);
  return WindowsOfficeSnapshot.fromJson(wire);
}

WindowsOfficeDraftPreview _preview(WindowsOfficeSnapshot snapshot) =>
    WindowsOfficeDraftPreview(
      snapshot: snapshot,
      pdfPath: 'C:/owned-preview/source-text.pdf',
      signature: 'validated-source-text',
      baseSourceSha256: 'a' * 64,
    );
List<Map<String, Object?>> _json(List<WindowsOfficeOperation> operations) => [
  for (final op in operations) op.toJson(),
];

Future<GlobalKey<WindowsOfficeEditorState>> _mount(
  WidgetTester tester, {
  WindowsOfficeSnapshot? snapshot,
  Future<WindowsOfficeDraftPreview> Function(
    List<WindowsOfficeOperation>,
    Map<String, WindowsOfficeImageAsset>,
  )?
  preview,
  Future<void> Function(List<WindowsOfficeOperation>)? commit,
}) async {
  tester.view.physicalSize = const Size(1400, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final key = GlobalKey<WindowsOfficeEditorState>();
  await tester.pumpWidget(
    MaterialApp(
      home: WindowsOfficeEditor(
        key: key,
        snapshot: snapshot ?? _snapshot(),
        onPreview: preview,
        onCommit: commit ?? (_) async {},
        onBack: () {},
      ),
    ),
  );
  return key;
}

Future<void> _select(WidgetTester tester, String table, String cell) async {
  final tableFinder = find.byKey(ValueKey('office-ppt-table-$table'));
  expect(tableFinder, findsOneWidget);
  await tester.ensureVisible(tableFinder);
  await tester.tap(tableFinder);
  await tester.pump();
  final cellFinder = find.byKey(ValueKey('office-ppt-cell-$cell'));
  expect(cellFinder, findsOneWidget);
  await tester.ensureVisible(cellFinder);
  await tester.tap(cellFinder);
  await tester.pump();
}

Finder get _field => find.byKey(const ValueKey('office-ppt-cell-text'));
TextEditingController _controller(WidgetTester tester) =>
    tester.widget<TextField>(_field).controller!;
Future<void> _refresh(WidgetTester tester) async {
  final button = find.byKey(const ValueKey('office-ppt-refresh-preview'));
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pump();
}

void _expectPatch(
  Map<String, Object?> op,
  String id,
  String before,
  String after,
) {
  expect(op, {
    'op': 'presentationCellTextPatch',
    'authorityVersion': 1,
    'ownerId': _owner,
    'tableId': id,
    'cellId': '$id/cell-0',
    'expectedSourceSha256': 'a' * 64,
    'sourcePart': 'ppt/slides/slide1.xml',
    'shapeId': id == _first ? '9' : '10',
    'expectedSourceFrameSha256': id == _first ? 'b' * 64 : 'c' * 64,
    'expectedTextSha256': _digest(before),
    'startUtf16': op['startUtf16'],
    'endUtf16': op['endUtf16'],
    'text': op['text'],
  });
  for (final offset in [op['startUtf16'] as int, op['endUtf16'] as int]) {
    expect(offset, inInclusiveRange(0, before.length));
    if (offset > 0 && offset < before.length) {
      expect(
        before.codeUnitAt(offset) >= 0xdc00 &&
            before.codeUnitAt(offset) <= 0xdfff &&
            before.codeUnitAt(offset - 1) >= 0xd800 &&
            before.codeUnitAt(offset - 1) <= 0xdbff,
        isFalse,
      );
    }
  }
  expect(
    before.replaceRange(
      op['startUtf16'] as int,
      op['endUtf16'] as int,
      op['text'] as String,
    ),
    after,
  );
}

void main() {
  testWidgets(
    'real table and cell selection saves source text with closed native capabilities',
    (tester) async {
      List<Map<String, Object?>>? saved;
      await _mount(
        tester,
        commit: (operations) async => saved = _json(operations),
      );
      await _select(tester, _second, '$_second/cell-0');
      expect(tester.widget<TextField>(_field).readOnly, isFalse);
      expect(find.byKey(const ValueKey('office-shape-text')), findsNothing);
      await tester.enterText(_field, 'A😀changed');
      await tester.tap(find.text('저장하고 닫기'));
      await tester.pump();
      expect(saved, hasLength(1));
      _expectPatch(saved!.single, _second, 'A😀BC', 'A😀changed');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'preview preserves input authority and sequential cell hash after another edit',
    (tester) async {
      final previews = <List<Map<String, Object?>>>[];
      List<Map<String, Object?>>? saved;
      await _mount(
        tester,
        preview: (operations, _) async {
          previews.add(_json(operations));
          return _preview(_draftSnapshot(first: 'A😀X'));
        },
        commit: (operations) async => saved = _json(operations),
      );
      await _select(tester, _first, '$_first/cell-0');
      await tester.enterText(_field, 'A😀X');
      _controller(tester).selection = const TextSelection.collapsed(offset: 4);
      await _refresh(tester);
      expect(
        find.byKey(const ValueKey('office-ppt-retry-preview')),
        findsNothing,
      );
      expect(_controller(tester).text, 'A😀X');
      expect(
        _controller(tester).selection,
        const TextSelection.collapsed(offset: 4),
      );
      await tester.enterText(_field, 'A😀XY');
      await tester.tap(find.text('저장하고 닫기'));
      await tester.pump();
      expect(saved, hasLength(2));
      expect(saved!.first, previews.single.single);
      _expectPatch(saved!.last, _first, 'A😀X', 'A😀XY');
    },
  );

  testWidgets('undo redo restores actual selected cell and branch journal', (
    tester,
  ) async {
    List<Map<String, Object?>>? saved;
    await _mount(
      tester,
      commit: (operations) async => saved = _json(operations),
    );
    await _select(tester, _first, '$_first/cell-0');
    await tester.enterText(_field, 'First');
    await _select(tester, _second, '$_second/cell-0');
    await tester.enterText(_field, 'Second');
    await tester.tap(find.byKey(const ValueKey('office-ppt-undo')));
    await tester.pump();
    expect(_controller(tester).text, 'A😀BC');
    await tester.tap(find.byKey(const ValueKey('office-ppt-redo')));
    await tester.pump();
    expect(_controller(tester).text, 'Second');
    await tester.tap(find.byKey(const ValueKey('office-ppt-undo')));
    await tester.pump();
    await tester.enterText(_field, 'Branch');
    await tester.pump();
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('office-ppt-redo')))
          .onPressed,
      isNull,
    );
    await tester.tap(find.text('저장하고 닫기'));
    await tester.pump();
    expect(saved, hasLength(2));
    _expectPatch(saved!.first, _first, 'A😀BC', 'First');
    _expectPatch(saved!.last, _second, 'A😀BC', 'Branch');
  });

  for (final missing in [false, true]) {
    testWidgets('missing or closed source map remains read only: $missing', (
      tester,
    ) async {
      var commits = 0;
      await _mount(
        tester,
        snapshot: _snapshot(editable: false, missingMap: missing),
        commit: (_) async => commits++,
      );
      await _select(tester, _first, '$_first/cell-0');
      expect(tester.widget<TextField>(_field).readOnly, isTrue);
      await tester.tap(find.text('저장하고 닫기'));
      await tester.pump();
      expect(commits, 0);
    });
  }

  testWidgets(
    'protected source range rejects actual text input but allows adjacent replacement',
    (tester) async {
      List<Map<String, Object?>>? saved;
      await _mount(
        tester,
        snapshot: _snapshot(first: 'A#B', protected: true),
        commit: (operations) async => saved = _json(operations),
      );
      await _select(tester, _first, '$_first/cell-0');
      await tester.enterText(_field, 'removed');
      expect(_controller(tester).text, 'A#B');
      await tester.enterText(_field, 'A#C');
      expect(_controller(tester).text, 'A#C');
      await tester.tap(find.text('저장하고 닫기'));
      await tester.pump();
      expect(saved, hasLength(1));
      _expectPatch(saved!.single, _first, 'A#B', 'A#C');
    },
  );

  for (final corruption in [
    'other-cell',
    'authored-width',
    'native-width',
    'frame-authority',
    'missing-map',
    'map-protection',
    'cell-identity',
    'unexpected-shape',
  ]) {
    testWidgets(
      'preview rejects $corruption without replacing the current source draft',
      (tester) async {
        List<Map<String, Object?>>? saved;
        await _mount(
          tester,
          preview: (_, _) async {
            final wire = _wire();
            wire['slides'][0]['presentationTables'][0]['cells'][0]['sourceTextPatch'] =
                _patch('Requested');
            final slide = wire['slides'][0];
            final table = slide['presentationTables'][0];
            if (corruption == 'other-cell') {
              table['cells'][1]['text'] = 'foreign';
              table['cells'][1]['sourceTextPatch'] = _patch('foreign');
            }
            if (corruption == 'authored-width')
              table['authoredGeometry']['extentEmu']['width']++;
            if (corruption == 'native-width')
              table['nativeBoundsHmm']['width']++;
            if (corruption == 'frame-authority')
              table['sourceTextPatchAuthority']['frameSha256'] = 'd' * 64;
            if (corruption == 'missing-map')
              table['cells'][0].remove('sourceTextPatch');
            if (corruption == 'map-protection') {
              table['cells'][0]['sourceTextPatch']['segments'] = [
                {'startUtf16': 0, 'endUtf16': 1, 'editable': false},
                {'startUtf16': 1, 'endUtf16': 9, 'editable': true},
              ];
              table['cells'][0]['sourceTextPatch']['protectedRanges'] = [
                {'startUtf16': 0, 'endUtf16': 1, 'reason': 'field'},
              ];
            }
            if (corruption == 'cell-identity') {
              table['cells'][0]['id'] = '$_first/cell-1';
              table['cells'][1]['id'] = '$_first/cell-0';
            }
            if (corruption == 'unexpected-shape') slide['shapes'][1]['x'] = 16;
            return _preview(WindowsOfficeSnapshot.fromJson(wire));
          },
          commit: (operations) async => saved = _json(operations),
        );
        await _select(tester, _first, '$_first/cell-0');
        await tester.enterText(_field, 'Requested');
        await _refresh(tester);
        expect(
          find.byKey(const ValueKey('office-ppt-retry-preview')),
          findsOneWidget,
        );
        expect(_controller(tester).text, 'Requested');
        await tester.tap(find.text('저장하고 닫기'));
        await tester.pump();
        expect(saved, hasLength(1));
        _expectPatch(saved!.single, _first, 'A😀BC', 'Requested');
      },
    );
  }

  testWidgets(
    'late source preview cannot restore a replaced source or its selection',
    (tester) async {
      final pending = Completer<WindowsOfficeDraftPreview>();
      final key = await _mount(tester, preview: (_, _) => pending.future);
      await _select(tester, _first, '$_first/cell-0');
      await tester.enterText(_field, 'Old draft');
      await _refresh(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: WindowsOfficeEditor(
            key: key,
            snapshot: _snapshot(first: 'New source'),
            onCommit: (_) async {},
            onBack: () {},
          ),
        ),
      );
      pending.complete(_preview(_draftSnapshot(first: 'Old draft')));
      await tester.pump();
      await _select(tester, _first, '$_first/cell-0');
      expect(_controller(tester).text, 'New source');
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'source cell IME composition blocks context changes and commits only the completed input',
    (tester) async {
      List<Map<String, Object?>>? saved;
      await _mount(
        tester,
        commit: (operations) async => saved = _json(operations),
      );
      await _select(tester, _first, '$_first/cell-0');
      await tester.showKeyboard(_field);
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: 'A😀BC한',
          selection: TextSelection.collapsed(offset: 6),
          composing: TextRange(start: 5, end: 6),
        ),
      );
      await tester.pump();
      expect(_controller(tester).text, 'A😀BC한');
      expect(
        tester
            .widget<FilledButton>(
              find.byWidgetPredicate((widget) => widget is FilledButton),
            )
            .onPressed,
        isNull,
      );
      final otherTable = find.byKey(
        const ValueKey('office-ppt-table-$_second'),
      );
      await tester.ensureVisible(otherTable);
      await tester.tap(otherTable);
      await tester.pump();
      expect(_controller(tester).text, 'A😀BC한');
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: 'A😀BC한',
          selection: TextSelection.collapsed(offset: 6),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('저장하고 닫기'));
      await tester.pump();
      expect(saved, hasLength(1));
      _expectPatch(saved!.single, _first, 'A😀BC', 'A😀BC한');
    },
  );

  testWidgets('table and cell controls remain usable in a 320 pixel editor', (
    tester,
  ) async {
    List<Map<String, Object?>>? saved;
    await _mount(
      tester,
      commit: (operations) async => saved = _json(operations),
    );
    tester.view.physicalSize = const Size(320, 1000);
    await tester.pump();
    await _select(tester, _first, '$_first/cell-0');
    await tester.ensureVisible(_field);
    await tester.enterText(_field, 'Narrow');
    await tester.tap(find.text('저장하고 닫기'));
    await tester.pump();
    expect(saved, hasLength(1));
    _expectPatch(saved!.single, _first, 'A😀BC', 'Narrow');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'plain source range preview accepts equivalent editable segmentation',
    (tester) async {
      final wire = _wire();
      wire['slides'][0]['presentationTables'][0]['cells'][0]['sourceTextPatch']['segments'] =
          [
            {'startUtf16': 0, 'endUtf16': 1, 'editable': true},
            {'startUtf16': 1, 'endUtf16': 3, 'editable': true},
            {'startUtf16': 3, 'endUtf16': 5, 'editable': true},
          ];
      List<Map<String, Object?>>? saved;
      await _mount(
        tester,
        snapshot: WindowsOfficeSnapshot.fromJson(wire),
        preview: (_, _) async => _preview(_draftSnapshot(first: 'A😀X')),
        commit: (operations) async => saved = _json(operations),
      );
      await _select(tester, _first, '$_first/cell-0');
      await tester.enterText(_field, 'A😀X');
      await _refresh(tester);
      expect(
        find.byKey(const ValueKey('office-ppt-retry-preview')),
        findsNothing,
      );
      expect(_controller(tester).text, 'A😀X');
      await tester.tap(find.text('저장하고 닫기'));
      await tester.pump();
      expect(saved, hasLength(1));
      _expectPatch(saved!.single, _first, 'A😀BC', 'A😀X');
    },
  );

  testWidgets(
    '150 continuous source keystrokes save one bounded operation and undo together',
    (tester) async {
      List<Map<String, Object?>>? saved;
      await _mount(
        tester,
        commit: (operations) async => saved = _json(operations),
      );
      await _select(tester, _first, '$_first/cell-0');
      await tester.showKeyboard(_field);
      for (var count = 1; count <= 150; count++) {
        tester.testTextInput.updateEditingValue(
          TextEditingValue(
            text: 'A😀BC${'x' * count}',
            selection: TextSelection.collapsed(offset: 5 + count),
          ),
        );
        await tester.pump();
      }
      await tester.tap(find.byKey(const ValueKey('office-ppt-undo')));
      await tester.pump();
      expect(_controller(tester).text, 'A😀BC');
      await tester.tap(find.byKey(const ValueKey('office-ppt-redo')));
      await tester.pump();
      expect(_controller(tester).text, 'A😀BC${'x' * 150}');
      await tester.tap(find.text('저장하고 닫기'));
      await tester.pump();
      expect(saved, hasLength(1));
      _expectPatch(saved!.single, _first, 'A😀BC', 'A😀BC${'x' * 150}');
      expect(saved!.single['startUtf16'], 5);
      expect(saved!.single['endUtf16'], 5);
    },
  );

  testWidgets(
    'source edits outside an inserted span retain separate sequential range guards',
    (tester) async {
      final wire = _wire(first: 'AB');
      wire['slides'][0]['presentationTables'][0]['cells'][0]['sourceTextPatch']['segments'] =
          [
            {'startUtf16': 0, 'endUtf16': 1, 'editable': true},
            {'startUtf16': 1, 'endUtf16': 2, 'editable': true},
          ];
      List<Map<String, Object?>>? saved;
      await _mount(
        tester,
        snapshot: WindowsOfficeSnapshot.fromJson(wire),
        commit: (operations) async => saved = _json(operations),
      );
      await _select(tester, _first, '$_first/cell-0');
      await tester.enterText(_field, 'AXB');
      await tester.enterText(_field, 'AXY');
      await tester.tap(find.text('저장하고 닫기'));
      await tester.pump();
      expect(saved, hasLength(2));
      _expectPatch(saved![0], _first, 'AB', 'AXB');
      expect(saved![0]['startUtf16'], 1);
      expect(saved![0]['endUtf16'], 1);
      _expectPatch(saved![1], _first, 'AXB', 'AXY');
      expect(saved![1]['startUtf16'], 2);
      expect(saved![1]['endUtf16'], 3);
    },
  );

  testWidgets(
    'deleting ordinary text beside a comment accepts the closed current map through undo redo',
    (tester) async {
      final wire = _wire(first: 'A');
      wire['slides'][0]['presentationTables'][0]['cells'][0]['sourceTextPatch']['protectedRanges'] =
          [
            {'startUtf16': 1, 'endUtf16': 1, 'reason': 'comment'},
          ];
      await _mount(
        tester,
        snapshot: WindowsOfficeSnapshot.fromJson(wire),
        preview: (_, _) async {
          final returned = jsonDecode(jsonEncode(wire)) as Map<String, dynamic>;
          returned['slides'][0]['presentationTables'][0]['cells'][0]['sourceTextPatch'] =
              {
                'canReplace': false,
                'truncated': false,
                'text': '',
                'utf16Length': 0,
                'textSha256': _digest(''),
                'segments': [],
                'protectedRanges': [
                  {'startUtf16': 0, 'endUtf16': 0, 'reason': 'comment'},
                ],
              };
          return _preview(WindowsOfficeSnapshot.fromJson(returned));
        },
      );
      await _select(tester, _first, '$_first/cell-0');
      await tester.enterText(_field, '');
      await _refresh(tester);
      expect(
        find.byKey(const ValueKey('office-ppt-retry-preview')),
        findsNothing,
      );
      expect(_controller(tester).text, '');
      expect(tester.widget<TextField>(_field).readOnly, isTrue);
      await tester.tap(find.byKey(const ValueKey('office-ppt-undo')));
      await tester.pump();
      expect(_controller(tester).text, 'A');
      expect(tester.widget<TextField>(_field).readOnly, isFalse);
      await tester.tap(find.byKey(const ValueKey('office-ppt-redo')));
      await tester.pump();
      expect(_controller(tester).text, '');
      expect(tester.widget<TextField>(_field).readOnly, isTrue);
    },
  );

  testWidgets(
    '150 continuous backspaces stay bounded and undo as one source deletion',
    (tester) async {
      final original = 'x' * 150 + 'Z';
      List<Map<String, Object?>>? saved;
      await _mount(
        tester,
        snapshot: _snapshot(first: original),
        commit: (operations) async => saved = _json(operations),
      );
      await _select(tester, _first, '$_first/cell-0');
      await tester.showKeyboard(_field);
      _controller(tester).selection = const TextSelection.collapsed(
        offset: 150,
      );
      await tester.pump();
      for (var remaining = 149; remaining >= 0; remaining--) {
        tester.testTextInput.updateEditingValue(
          TextEditingValue(
            text: 'x' * remaining + 'Z',
            selection: TextSelection.collapsed(offset: remaining),
          ),
        );
        await tester.pump();
      }
      expect(_controller(tester).text, 'Z');
      await tester.tap(find.byKey(const ValueKey('office-ppt-undo')));
      await tester.pump();
      expect(_controller(tester).text, original);
      await tester.tap(find.byKey(const ValueKey('office-ppt-redo')));
      await tester.pump();
      expect(_controller(tester).text, 'Z');
      await tester.tap(find.text('저장하고 닫기'));
      await tester.pump();
      expect(saved, hasLength(1));
      _expectPatch(saved!.single, _first, original, 'Z');
      expect(saved!.single['startUtf16'], 0);
      expect(saved!.single['endUtf16'], 150);
      expect(saved!.single['text'], '');
    },
  );

  testWidgets(
    'sequential deletions on both sides of a zero width field stay separate',
    (tester) async {
      final wire = _wire(first: 'AB');
      final proof =
          wire['slides'][0]['presentationTables'][0]['cells'][0]['sourceTextPatch'];
      proof['segments'] = [
        {'startUtf16': 0, 'endUtf16': 1, 'editable': true},
        {'startUtf16': 1, 'endUtf16': 2, 'editable': true},
      ];
      proof['protectedRanges'] = [
        {'startUtf16': 1, 'endUtf16': 1, 'reason': 'field'},
      ];
      List<Map<String, Object?>>? saved;
      await _mount(
        tester,
        snapshot: WindowsOfficeSnapshot.fromJson(wire),
        commit: (operations) async => saved = _json(operations),
      );
      await _select(tester, _first, '$_first/cell-0');
      await tester.enterText(_field, 'B');
      await tester.enterText(_field, '');
      expect(_controller(tester).text, '');
      await tester.tap(find.text('저장하고 닫기'));
      await tester.pump();
      expect(saved, hasLength(2));
      _expectPatch(saved![0], _first, 'AB', 'B');
      expect(saved![0]['startUtf16'], 0);
      expect(saved![0]['endUtf16'], 1);
      _expectPatch(saved![1], _first, 'B', '');
      expect(saved![1]['startUtf16'], 0);
      expect(saved![1]['endUtf16'], 1);
    },
  );
  testWidgets(
    'no op preview preserves the selected source range before a later edit',
    (tester) async {
      List<Map<String, Object?>>? saved;
      await _mount(
        tester,
        preview: (_, _) async => _preview(_snapshot()),
        commit: (operations) async => saved = _json(operations),
      );
      await _select(tester, _first, '$_first/cell-0');
      _controller(tester).selection = const TextSelection(
        baseOffset: 1,
        extentOffset: 3,
      );
      await tester.pump();
      await _refresh(tester);
      expect(
        find.byKey(const ValueKey('office-ppt-retry-preview')),
        findsNothing,
      );
      expect(
        _controller(tester).selection,
        const TextSelection(baseOffset: 1, extentOffset: 3),
      );
      await tester.enterText(_field, 'A😀Later');
      await tester.tap(find.text('저장하고 닫기'));
      await tester.pump();
      expect(saved, hasLength(1));
      _expectPatch(saved!.single, _first, 'A😀BC', 'A😀Later');
    },
  );

  testWidgets(
    'no op preview cannot replace the original frame authority before editing',
    (tester) async {
      List<Map<String, Object?>>? saved;
      await _mount(
        tester,
        preview: (_, _) async {
          final wire = _wire();
          wire['slides'][0]['presentationTables'][0]['sourceTextPatchAuthority']['frameSha256'] =
              'd' * 64;
          return _preview(WindowsOfficeSnapshot.fromJson(wire));
        },
        commit: (operations) async => saved = _json(operations),
      );
      await _select(tester, _first, '$_first/cell-0');
      await _refresh(tester);
      expect(
        find.byKey(const ValueKey('office-ppt-retry-preview')),
        findsOneWidget,
      );
      expect(_controller(tester).text, 'A😀BC');
      await tester.enterText(_field, 'Guarded');
      await tester.tap(find.text('저장하고 닫기'));
      await tester.pump();
      expect(saved, hasLength(1));
      _expectPatch(saved!.single, _first, 'A😀BC', 'Guarded');
    },
  );

  testWidgets(
    'source cells with the same local ID keep their table scoped edit journals',
    (tester) async {
      final wire = _wire(editable: false);
      for (final table in wire['slides'][0]['presentationTables']) {
        table['cells'][0]['id'] = 'shared-cell';
      }
      List<Map<String, Object?>>? saved;
      await _mount(
        tester,
        snapshot: WindowsOfficeSnapshot.fromJson(wire),
        commit: (operations) async => saved = _json(operations),
      );
      await _select(tester, _second, 'shared-cell');
      await tester.enterText(_field, 'Changed');
      _controller(tester).selection = const TextSelection.collapsed(offset: 0);
      await tester.pump();
      await tester.tap(find.text('저장하고 닫기'));
      await tester.pump();
      expect(saved, hasLength(1));
      expect(saved!.single['tableId'], _second);
      expect(saved!.single['cellId'], 'shared-cell');
      expect(saved!.single['expectedTextSha256'], _digest('A😀BC'));
      expect(saved!.single['expectedSourceFrameSha256'], 'c' * 64);
    },
  );

  testWidgets(
    'valid preview cannot open a closed same ID cell in another table',
    (tester) async {
      final wire = _wire(first: 'CLOSED', second: 'OPEN', editable: false);
      for (final table in wire['slides'][0]['presentationTables']) {
        table['cells'][0]['id'] = 'shared-cell';
      }
      List<Map<String, Object?>>? saved;
      await _mount(
        tester,
        snapshot: WindowsOfficeSnapshot.fromJson(wire),
        preview: (_, _) async {
          final returned = jsonDecode(jsonEncode(wire)) as Map<String, dynamic>;
          returned['slides'][0]['presentationTables'][1]['cells'][0]['sourceTextPatch'] =
              _patch('EDITED');
          return _preview(WindowsOfficeSnapshot.fromJson(returned));
        },
        commit: (operations) async => saved = _json(operations),
      );
      await _select(tester, _second, 'shared-cell');
      await tester.enterText(_field, 'EDITED');
      await _refresh(tester);
      expect(
        find.byKey(const ValueKey('office-ppt-retry-preview')),
        findsNothing,
      );
      await _select(tester, _first, 'shared-cell');
      expect(tester.widget<TextField>(_field).readOnly, isTrue);
      expect(_controller(tester).text, 'CLOSED');
      await _select(tester, _second, 'shared-cell');
      expect(_controller(tester).text, 'EDITED');
      await tester.tap(find.text('저장하고 닫기'));
      await tester.pump();
      expect(saved, hasLength(1));
      expect(saved!.single['tableId'], _second);
      expect(saved!.single['cellId'], 'shared-cell');
      expect(saved!.single['expectedTextSha256'], _digest('OPEN'));
    },
  );

  testWidgets(
    'legacy slide display edits retain their existing batch capacity above 100',
    (tester) async {
      final wire = _wire();
      wire['slides'][0]['visible'] = true;
      List<Map<String, Object?>>? saved;
      await _mount(
        tester,
        snapshot: WindowsOfficeSnapshot.fromJson(wire),
        commit: (operations) async => saved = _json(operations),
      );
      final visible = find.byKey(const ValueKey('office-ppt-visible'));
      await tester.ensureVisible(visible);
      for (var count = 0; count < 101; count++) {
        await tester.tap(visible);
        await tester.pump();
      }
      await tester.tap(find.text('저장하고 닫기'));
      await tester.pump();
      expect(saved, hasLength(101));
      expect(saved!.every((op) => op['op'] == 'slideDisplay'), isTrue);
      expect(saved!.first['visible'], isFalse);
      expect(saved!.last['visible'], isFalse);
    },
  );

  testWidgets(
    'deleting an explicitly selected repeated character targets the selected source run',
    (tester) async {
      final wire = _wire(first: 'AA');
      wire['slides'][0]['presentationTables'][0]['cells'][0]['sourceTextPatch']['segments'] =
          [
            {'startUtf16': 0, 'endUtf16': 1, 'editable': true},
            {'startUtf16': 1, 'endUtf16': 2, 'editable': true},
          ];
      List<Map<String, Object?>>? saved;
      await _mount(
        tester,
        snapshot: WindowsOfficeSnapshot.fromJson(wire),
        commit: (operations) async => saved = _json(operations),
      );
      await _select(tester, _first, '$_first/cell-0');
      await tester.showKeyboard(_field);
      _controller(tester).selection = const TextSelection(
        baseOffset: 0,
        extentOffset: 1,
      );
      await tester.pump();
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: 'A',
          selection: TextSelection.collapsed(offset: 0),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('저장하고 닫기'));
      await tester.pump();
      expect(saved, hasLength(1));
      _expectPatch(saved!.single, _first, 'AA', 'A');
      expect(saved!.single['startUtf16'], 0);
      expect(saved!.single['endUtf16'], 1);
    },
  );

  for (final oldCursor in [1, 2]) {
    testWidgets(
      'backspace at repeated source cursor $oldCursor targets the preceding character',
      (tester) async {
        List<Map<String, Object?>>? saved;
        await _mount(
          tester,
          snapshot: _snapshot(first: 'AA'),
          commit: (operations) async => saved = _json(operations),
        );
        await _select(tester, _first, '$_first/cell-0');
        await tester.showKeyboard(_field);
        _controller(tester).selection = TextSelection.collapsed(
          offset: oldCursor,
        );
        await tester.pump();
        tester.testTextInput.updateEditingValue(
          TextEditingValue(
            text: 'A',
            selection: TextSelection.collapsed(offset: oldCursor - 1),
          ),
        );
        await tester.pump();
        await tester.tap(find.text('저장하고 닫기'));
        await tester.pump();
        expect(saved, hasLength(1));
        _expectPatch(saved!.single, _first, 'AA', 'A');
        expect(saved!.single['startUtf16'], oldCursor - 1);
        expect(saved!.single['endUtf16'], oldCursor);
      },
    );
  }

  testWidgets(
    'repeated text IME keeps the first composition selection as its source range',
    (tester) async {
      List<Map<String, Object?>>? saved;
      await _mount(
        tester,
        snapshot: _snapshot(first: 'AAA'),
        commit: (operations) async => saved = _json(operations),
      );
      await _select(tester, _first, '$_first/cell-0');
      await tester.showKeyboard(_field);
      _controller(tester).selection = const TextSelection(
        baseOffset: 0,
        extentOffset: 1,
      );
      await tester.pump();
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: 'AAAA',
          selection: TextSelection.collapsed(offset: 2),
          composing: TextRange(start: 0, end: 2),
        ),
      );
      await tester.pump();
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: 'AAAA',
          selection: TextSelection.collapsed(offset: 2),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('저장하고 닫기'));
      await tester.pump();
      expect(saved, hasLength(1));
      _expectPatch(saved!.single, _first, 'AAA', 'AAAA');
      expect(saved!.single['startUtf16'], 0);
      expect(saved!.single['endUtf16'], 1);
      expect(saved!.single['text'], 'AA');
    },
  );
}
