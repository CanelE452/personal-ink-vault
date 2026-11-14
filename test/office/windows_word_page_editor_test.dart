import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/office/office_image_asset.dart';
import 'package:saber/data/office/windows_office_engine.dart';
import 'package:saber/pages/office/windows_office_editor.dart';

import 'windows_office_rich_editor_test.dart' show input, textDetails;
import 'windows_word_owners_editor_test.dart'
    show append, ownerParagraph, selectOwner, splitId;
import 'windows_word_structure_editor_test.dart'
    show focusParagraph, paragraph, press, save, value;

typedef _Preview = Future<WindowsOfficeDraftPreview> Function(
  List<WindowsOfficeOperation>,
  Map<String, WindowsOfficeImageAsset>,
);

WindowsOfficeSnapshot _word({
  String source = 'a',
  String body = 'BODY',
  List<(String, String)> header = const [('hp0', 'HEAD')],
  String layoutHash = 'b',
  double width = 210,
  double height = 297,
  bool landscape = false,
  double leftMargin = 20,
  double rightMargin = 20,
  double topMargin = 20,
  bool? capability = true,
  bool metadata = true,
  Map<String, Object?> bodyOverrides = const {},
  Map<String, Object?> bodyTableOverrides = const {},
}) => WindowsOfficeSnapshot.fromJson({
  'kind': 'word',
  'sourceSha256': source * 64,
  'bodyOwnerId': 'body',
  'blocks': [
    {'kind': 'paragraph', 'id': 'p0'},
    {'kind': 'table', 'id': 'bt0'},
    {'kind': 'paragraph', 'id': 'p1'},
  ],
  'paragraphs': [
    {...ownerParagraph('p0', 'body', body), ...bodyOverrides},
    ownerParagraph('p1', 'body', 'TAIL'),
  ],
  'paragraphStyles': [
    {'name': 'Body', 'displayName': '본문 스타일'},
  ],
  'tables': [
    for (final item in [
      ('bt0', 'body', 'BODY CELL'),
      ('ht0', 'header', 'HEAD CELL'),
    ])
      {
        'id': item.$1,
        'ownerId': item.$2,
        'cells': {'A1': item.$3},
        'cellTextDetails': {'A1': textDetails(item.$3)},
        if (item.$1 == 'bt0') ...bodyTableOverrides,
      },
  ],
  'wordOwners': [
    {
      'id': 'header',
      'kind': 'header',
      'references': [
        {'pageStyleId': 'pageB', 'variant': 'default'},
        {'pageStyleId': 'pageB', 'variant': 'right'},
      ],
      'blocks': [
        for (final part in header) {'kind': 'paragraph', 'id': part.$1},
        {'kind': 'table', 'id': 'ht0'},
      ],
      'paragraphs': [
        for (final part in header) ownerParagraph(part.$1, 'header', part.$2),
      ],
      'tableIds': ['ht0'],
    },
  ],
  if (metadata)
    'pageStyles': [
      for (final id in ['pageA', 'pageB'])
        {
          'id': id,
          'name': 'Imported$id',
          'displayName': id == 'pageA' ? '앞 구역' : '뒤 구역',
          'inUse': true,
          'canEditGeometry': ?capability,
          'width': id == 'pageB' ? width : 210,
          'height': id == 'pageB' ? height : 297,
          'landscape': id == 'pageB' ? landscape : false,
          'leftMargin': id == 'pageB' ? leftMargin : 20,
          'rightMargin': id == 'pageB' ? rightMargin : 20,
          'topMargin': id == 'pageB' ? topMargin : 20,
          'bottomMargin': 20,
          'layoutSha256': (id == 'pageB' ? layoutHash : 'b') * 64,
          'regions': {
            'header': {'default': id == 'pageB' ? 'header' : null},
            'footer': {'default': null},
          },
        },
    ],
  'slides': [],
});

WindowsOfficeDraftPreview _preview(
  WindowsOfficeSnapshot snapshot, {
  String baseSource = 'a',
}) => WindowsOfficeDraftPreview(
  snapshot: snapshot,
  pdfPath: 'C:/owned-word-preview/layout.pdf',
  signature: 'host-validated-word-signature',
  baseSourceSha256: baseSource * 64,
);

Future<GlobalKey<WindowsOfficeEditorState>> _mount(
  WidgetTester tester, {
  required _Preview preview,
  WindowsOfficeSnapshot? snapshot,
  Future<void> Function(List<WindowsOfficeOperation>)? commit,
}) async {
  tester.view.physicalSize = const Size(1400, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final key = GlobalKey<WindowsOfficeEditorState>();
  await tester.pumpWidget(
    MaterialApp(
      home: WindowsOfficeEditor(
        key: key,
        snapshot: snapshot ?? _word(),
        onPreview: preview,
        onCommit: commit ?? (_) async {},
        onBack: () {},
      ),
    ),
  );
  return key;
}

Finder _key(String key) => find.byKey(ValueKey(key));
Finder _field(String property) => _key('office-word-page-$property');
String _fieldValue(WidgetTester tester, String property) =>
    tester.widget<TextField>(_field(property)).controller!.text;
double _number(WidgetTester tester, String property) =>
    double.parse(_fieldValue(tester, property));

Future<void> _tap(WidgetTester tester, String key) async {
  await tester.ensureVisible(_key(key));
  await tester.tap(_key(key));
  await tester.pumpAndSettle();
}

Future<void> _open(WidgetTester tester, {bool choose = true}) async {
  await _tap(tester, 'office-word-page-settings');
  if (choose) {
    await _tap(tester, 'office-word-page-style');
    await _tap(tester, 'office-word-page-style-pageB');
  }
}

Future<void> _set(WidgetTester tester, String property, String value) async {
  await tester.enterText(_field(property), value);
  await tester.pump();
}

List<Map<String, Object?>> _json(List<WindowsOfficeOperation> operations) => [
  for (final operation in operations) operation.toJson(),
];

Map<String, Object?> _markedDetails(
  String text,
  List<(int, int, String)> protected, {
  List<(int, int, bool)>? runs,
}) => {
  ...textDetails(
    text,
    protectedRanges: [
      for (final range in protected)
        {'startUtf16': range.$1, 'endUtf16': range.$2, 'type': range.$3},
    ],
  ),
  if (runs != null)
    'runs': [
      for (final run in runs)
        {
          ...Map<String, Object?>.from(
            (textDetails(text)['runs'] as List).single as Map,
          ),
          'startUtf16': run.$1,
          'endUtf16': run.$2,
          'bold': run.$3,
        },
    ],
};

void main() {
  for (final target in ['paragraph', 'cell']) {
    testWidgets('same-ID page response cannot lose authored $target text', (
      tester,
    ) async {
      await _mount(
        tester,
        preview: (_, _) async =>
            _preview(_word(leftMargin: 25.4, layoutHash: 'c')),
      );
      final field = target == 'paragraph'
          ? paragraph('p0')
          : _key('office-cell-bt0-A1');
      final edited = target == 'paragraph' ? 'BODY!' : 'BODY CELL!';
      await input(tester, field, edited);
      await _open(tester);
      await _set(tester, 'leftMargin', '25.4');
      await _tap(tester, 'office-word-page-apply');
      expect(_key('office-word-page-retry-preview'), findsOneWidget);
      expect(tester.widget<TextField>(field).controller!.text, edited);
      expect(_number(tester, 'leftMargin'), 25.4);
    });
  }

  for (final replacement in ['stripped', 'changed-type']) {
    testWidgets(
      'same-ID page response rejects $replacement non-field protection',
      (tester) async {
        final sourceDetails = _markedDetails('A#B', [(1, 2, 'Bookmark')]);
        final returned = _markedDetails(
          'A#B',
          replacement == 'stripped' ? [] : [(1, 2, 'ReferenceMark')],
        );
        await _mount(
          tester,
          snapshot: _word(
            body: 'A#B',
            bodyOverrides: {'textDetails': sourceDetails},
          ),
          preview: (_, _) async => _preview(
            _word(
              body: 'A#B',
              bodyOverrides: {'textDetails': returned},
              leftMargin: 25.4,
              layoutHash: 'c',
            ),
          ),
        );
        await _open(tester);
        await _set(tester, 'leftMargin', '25.4');
        await _tap(tester, 'office-word-page-apply');
        expect(_key('office-word-page-retry-preview'), findsOneWidget);
        expect(value(tester, 'p0'), 'A#B');
        await press(tester, 'office-word-undo');
        await _tap(tester, 'office-word-page-close');
        await input(tester, paragraph('p0'), 'AXB');
        expect(value(tester, 'p0'), 'A#B');
      },
    );
  }

  for (final malformed in ['literal', 'field-count']) {
    testWidgets(
      'field-cache exception rejects changed $malformed in same-ID response',
      (tester) async {
        const source = 'P 1 of 2 END';
        final response = malformed == 'literal'
            ? 'P 12 of 20 BAD'
            : 'P 12 of 20 END';
        final responseRanges = malformed == 'literal'
            ? [(2, 4, 'TextField'), (8, 10, 'TextField')]
            : [(2, 4, 'TextField')];
        await _mount(
          tester,
          snapshot: _word(
            body: source,
            bodyOverrides: {
              'textDetails': _markedDetails(source, [
                (2, 3, 'TextField'),
                (7, 8, 'TextField'),
              ]),
            },
          ),
          preview: (_, _) async => _preview(
            _word(
              body: response,
              bodyOverrides: {
                'textDetails': _markedDetails(response, responseRanges),
              },
              leftMargin: 25.4,
              layoutHash: 'c',
            ),
          ),
        );
        await _open(tester);
        await _set(tester, 'leftMargin', '25.4');
        await _tap(tester, 'office-word-page-apply');
        expect(_key('office-word-page-retry-preview'), findsOneWidget);
        expect(value(tester, 'p0'), source);
      },
    );
  }

  for (final formatting in ['character', 'paragraph']) {
    testWidgets(
      'same-ID page response cannot discard requested $formatting formatting',
      (tester) async {
        await _mount(
          tester,
          preview: (_, _) async =>
              _preview(_word(leftMargin: 25.4, layoutHash: 'c')),
        );
        await input(
          tester,
          paragraph('p0'),
          'BODY',
          selection: const TextSelection(baseOffset: 0, extentOffset: 4),
        );
        final control = formatting == 'character'
            ? 'office-bold-p0'
            : 'office-word-alignment-center';
        await _tap(tester, control);
        expect(tester.widget<IconButton>(_key(control)).isSelected, isTrue);
        await _open(tester);
        await _set(tester, 'leftMargin', '25.4');
        await _tap(tester, 'office-word-page-apply');
        expect(_key('office-word-page-retry-preview'), findsOneWidget);
        expect(tester.widget<IconButton>(_key(control)).isSelected, isTrue);
      },
    );
  }

  for (final malformed in [
    'hash',
    'utf16-length',
    'protection-range',
    'run-range',
  ]) {
    testWidgets(
      'same-ID page response rejects invalid own textDetails $malformed',
      (tester) async {
        final details = <String, Object?>{
          ...textDetails('BODY'),
          if (malformed == 'hash') 'textSha256': 'e' * 64,
          if (malformed == 'utf16-length') 'utf16Length': 5,
          if (malformed == 'protection-range')
            'protectedRanges': [
              {'startUtf16': 3, 'endUtf16': 9, 'type': 'TextField'},
            ],
          if (malformed == 'run-range')
            'runs': [
              {'startUtf16': 0, 'endUtf16': 9, 'bold': false},
            ],
        };
        await _mount(
          tester,
          preview: (_, _) async => _preview(
            _word(
              bodyOverrides: {'textDetails': details},
              leftMargin: 25.4,
              layoutHash: 'c',
            ),
          ),
        );
        await _open(tester);
        await _set(tester, 'leftMargin', '25.4');
        await _tap(tester, 'office-word-page-apply');
        expect(_key('office-word-page-retry-preview'), findsOneWidget);
        expect(value(tester, 'p0'), 'BODY');
      },
    );
  }

  testWidgets(
    'validated field caches may change length while literals protections and style survive',
    (tester) async {
      const source = 'P 1 of 2 END#';
      const authored = 'PAGE 1 of 2 END#';
      const normalized = 'PAGE 12 of 200 END#';
      List<Map<String, Object?>>? saved;
      await _mount(
        tester,
        snapshot: _word(
          body: source,
          bodyOverrides: {
            'textDetails': _markedDetails(
              source,
              [(2, 3, 'TextField'), (7, 8, 'TextField'), (12, 13, 'Bookmark')],
              runs: [(0, 9, false), (9, 12, true), (12, 13, false)],
            ),
          },
        ),
        preview: (_, _) async => _preview(
          _word(
            body: normalized,
            bodyOverrides: {
              'textDetails': _markedDetails(
                normalized,
                [
                  (5, 7, 'TextField'),
                  (11, 14, 'TextField'),
                  (18, 19, 'Bookmark'),
                ],
                runs: [(0, 15, false), (15, 18, true), (18, 19, false)],
              ),
            },
            leftMargin: 25.4,
            layoutHash: 'c',
          ),
        ),
        commit: (operations) async {
          saved = _json(operations);
        },
      );
      await input(tester, paragraph('p0'), authored);
      expect(value(tester, 'p0'), authored);
      await _open(tester);
      await _set(tester, 'leftMargin', '25.4');
      await _tap(tester, 'office-word-page-apply');
      expect(_key('office-word-page-retry-preview'), findsNothing);
      expect(_field('leftMargin'), findsNothing);
      expect(value(tester, 'p0'), normalized);
      await input(tester, paragraph('p0'), '$normalized!');
      await save(tester);
      expect(saved!.map((operation) => operation['op']), [
        'textReplace',
        'pageGeometry',
        'textReplace',
      ]);
      expect(saved!.last, append('p0', normalized, '!'));
    },
  );

  for (final key in [LogicalKeyboardKey.keyZ, LogicalKeyboardKey.keyY]) {
    testWidgets(
      'Word ${key.keyLabel} cannot change history during outstanding commit',
      (tester) async {
        final release = Completer<void>();
        List<Map<String, Object?>>? committed;
        final editor = await _mount(
          tester,
          preview: (_, _) async => _preview(_word()),
          commit: (operations) {
            committed = _json(operations);
            return release.future;
          },
        );
        await input(tester, paragraph('p0'), 'BODY!');
        await input(tester, paragraph('p1'), 'TAIL!');
        await press(tester, 'office-word-undo');
        expect(value(tester, 'p0'), 'BODY!');
        expect(value(tester, 'p1'), 'TAIL');
        final saving = editor.currentState!.save();
        await tester.pump();
        try {
          tester.widget<TextField>(paragraph('p0')).focusNode!.requestFocus();
          await tester.pump();
          await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
          await tester.sendKeyEvent(key);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
          await tester.pump();
          expect(value(tester, 'p0'), 'BODY!');
          expect(value(tester, 'p1'), 'TAIL');
          expect(committed, [append('p0', 'BODY', '!')]);
        } finally {
          release.complete();
          await saving;
          await tester.pumpAndSettle();
        }
      },
    );
  }

  testWidgets(
    'page geometry requires an explicit actual style and precedes later edits',
    (tester) async {
      final requests = <List<Map<String, Object?>>>[];
      List<Map<String, Object?>>? saved;
      String? addedId;
      await _mount(
        tester,
        preview: (operations, assets) async {
          expect(assets, isEmpty);
          requests.add(_json(operations));
          if (requests.length == 1) {
            return _preview(
              _word(
                body: 'BODY!',
                width: 297,
                height: 210,
                landscape: true,
                leftMargin: 25.4,
                rightMargin: 17.99,
                layoutHash: 'c',
              ),
            );
          }
          return _preview(
            _word(
              body: 'BODY!',
              header: [('hp0', 'HE'), (addedId!, 'AD!?')],
              width: 297,
              height: 210,
              landscape: true,
              leftMargin: 25.4,
              rightMargin: 17.99,
              topMargin: 21.01,
              layoutHash: 'd',
            ),
          );
        },
        commit: (operations) async {
          saved = _json(operations);
        },
      );
      await input(
        tester,
        paragraph('p0'),
        'BODY!',
        selection: const TextSelection.collapsed(offset: 2),
      );
      await _open(tester, choose: false);
      expect(
        tester.widget<FilledButton>(_key('office-word-page-apply')).onPressed,
        isNull,
      );
      await _tap(tester, 'office-word-page-style');
      expect(find.text('앞 구역'), findsWidgets);
      expect(find.text('뒤 구역'), findsWidgets);
      await _tap(tester, 'office-word-page-style-pageB');
      expect(_number(tester, 'width'), 210);
      expect(_number(tester, 'height'), 297);
      expect(find.textContaining('Hmm'), findsNothing);
      expect(find.textContaining('bbbbbbbb'), findsNothing);
      await _tap(tester, 'office-word-page-landscape');
      expect(_number(tester, 'width'), 297);
      expect(_number(tester, 'height'), 210);
      await _set(tester, 'leftMargin', '25.4');
      await _set(tester, 'rightMargin', '18');
      await _tap(tester, 'office-word-page-apply');
      expect(requests, [
        [
          append('p0', 'BODY', '!'),
          {
            'op': 'pageGeometry',
            'id': 'pageB',
            'expectedLayoutSha256': 'b' * 64,
            'width': 297.0,
            'height': 210.0,
            'landscape': true,
            'leftMargin': 25.4,
            'rightMargin': 18.0,
          },
        ],
      ]);
      expect(value(tester, 'p0'), 'BODY!');
      expect(
        tester.widget<TextField>(paragraph('p0')).controller!.selection,
        const TextSelection.collapsed(offset: 2),
      );
      await _open(tester);
      expect(_number(tester, 'rightMargin'), 17.99);
      expect(_number(tester, 'width'), 297);
      await _tap(tester, 'office-word-page-close');
      await selectOwner(tester, 'header');
      await input(tester, paragraph('hp0'), 'HEAD!');
      await focusParagraph(tester, 'hp0', 2);
      await press(tester, 'office-word-split');
      addedId = splitId(tester, 'AD!');
      await input(tester, paragraph(addedId), 'AD!?');
      await _open(tester);
      await _set(tester, 'topMargin', '21');
      await _tap(tester, 'office-word-page-apply');
      expect(requests.last.map((op) => op['op']), [
        'textReplace',
        'pageGeometry',
        'textReplace',
        'paragraphSplit',
        'textReplace',
        'pageGeometry',
      ]);
      expect(requests.last.last, {
        'op': 'pageGeometry',
        'id': 'pageB',
        'expectedLayoutSha256': 'c' * 64,
        'topMargin': 21.0,
      });
      expect(requests.last[4], append(addedId, 'AD!', '?'));
      expect(value(tester, 'hp0'), 'HE');
      expect(value(tester, addedId), 'AD!?');
      expect(_key('office-cell-bt0-A1'), findsNothing);
      expect(
        tester.getTopLeft(paragraph(addedId)).dy,
        lessThan(tester.getTopLeft(_key('office-cell-ht0-A1')).dy),
      );
      await press(tester, 'office-word-undo');
      expect(value(tester, addedId), 'AD!?');
      await _open(tester);
      expect(_number(tester, 'topMargin'), 20);
      await _tap(tester, 'office-word-page-close');
      await press(tester, 'office-word-redo');
      await _open(tester);
      expect(_number(tester, 'topMargin'), 21.01);
      await _tap(tester, 'office-word-page-close');
      await save(tester);
      expect(saved, requests.last);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'invalid millimetres preserve input and never request a preview',
    (tester) async {
      var previews = 0;
      await _mount(
        tester,
        preview: (_, _) async {
          previews++;
          return _preview(_word());
        },
      );
      await _open(tester);
      await _set(tester, 'leftMargin', 'invalid');
      await _tap(tester, 'office-word-page-apply');
      expect(_fieldValue(tester, 'leftMargin'), 'invalid');
      expect(previews, 0);
      expect(_key('office-word-page-error'), findsOneWidget);
      await _set(tester, 'leftMargin', '200');
      await _set(tester, 'rightMargin', '200');
      await _tap(tester, 'office-word-page-apply');
      expect(_number(tester, 'leftMargin'), 200);
      expect(_number(tester, 'rightMargin'), 200);
      expect(previews, 0);
      expect(_key('office-word-page-error'), findsOneWidget);
      await _set(tester, 'leftMargin', '20');
      await _set(tester, 'rightMargin', '20');
      await _set(tester, 'width', '210');
      await _set(tester, 'height', '210');
      await _tap(tester, 'office-word-page-apply');
      expect(previews, 0);
      expect(_number(tester, 'height'), 210);
      expect(_key('office-word-page-error'), findsOneWidget);
    },
  );

  testWidgets(
    'preview failure keeps geometry inputs and retries the same journal',
    (tester) async {
      final requests = <List<Map<String, Object?>>>[];
      await _mount(
        tester,
        preview: (operations, _) async {
          requests.add(_json(operations));
          if (requests.length == 1)
            throw StateError('synthetic preview failure');
          return _preview(_word(leftMargin: 25.4, layoutHash: 'c'));
        },
      );
      await _open(tester);
      await _set(tester, 'leftMargin', '25.4');
      await _tap(tester, 'office-word-page-apply');
      expect(_number(tester, 'leftMargin'), 25.4);
      expect(find.textContaining('미리보기'), findsWidgets);
      expect(requests, hasLength(1));
      await _tap(tester, 'office-word-page-retry-preview');
      expect(requests, hasLength(2));
      expect(requests.last, requests.first);
      await _open(tester);
      expect(_number(tester, 'leftMargin'), 25.4);
      await _tap(tester, 'office-word-page-close');
      await press(tester, 'office-word-undo');
      await _open(tester);
      expect(_number(tester, 'leftMargin'), 20);
    },
  );

  testWidgets(
    'pending page preview disables repeated apply save and owner changes',
    (tester) async {
      final pending = Completer<WindowsOfficeDraftPreview>();
      var previews = 0;
      var commits = 0;
      final editor = await _mount(
        tester,
        preview: (_, _) {
          previews++;
          return pending.future;
        },
        commit: (_) async {
          commits++;
        },
      );
      await _open(tester);
      await _set(tester, 'leftMargin', '25.4');
      await tester.tap(_key('office-word-page-apply'));
      await tester.pump();
      expect(previews, 1);
      expect(
        tester.widget<FilledButton>(_key('office-word-page-apply')).onPressed,
        isNull,
      );
      expect(
        tester
            .widget<PopupMenuButton<String>>(_key('office-word-page-style'))
            .enabled,
        isFalse,
      );
      expect(
        tester
            .widget<PopupMenuButton<String>>(_key('office-word-owner-selector'))
            .enabled,
        isFalse,
      );
      final saveButton = find.ancestor(
        of: find.text('저장하고 닫기'),
        matching: find.byWidgetPredicate((widget) => widget is FilledButton),
      );
      expect(tester.widget<FilledButton>(saveButton).onPressed, isNull);
      await editor.currentState!.save();
      expect(commits, 0);
      expect(previews, 1);
      pending.complete(_preview(_word(leftMargin: 25.4, layoutHash: 'c')));
      await tester.pumpAndSettle();
      expect(value(tester, 'p0'), 'BODY');
      expect(paragraph('hp0'), findsNothing);
    },
  );

  for (final capability in <bool?>[null, false]) {
    testWidgets(
      'unproven page capability $capability stays read only despite inUse',
      (tester) async {
        var previews = 0;
        await _mount(
          tester,
          snapshot: _word(capability: capability),
          preview: (_, _) async {
            previews++;
            return _preview(_word());
          },
        );
        await _open(tester);
        for (final name in [
          'width',
          'height',
          'leftMargin',
          'rightMargin',
          'topMargin',
          'bottomMargin',
        ]) {
          expect(tester.widget<TextField>(_field(name)).readOnly, isTrue);
        }
        expect(
          tester.widget<FilledButton>(_key('office-word-page-apply')).onPressed,
          isNull,
        );
        expect(previews, 0);
      },
    );
  }

  testWidgets(
    'absent page metadata and active composition disable page settings',
    (tester) async {
      await _mount(
        tester,
        snapshot: _word(metadata: false),
        preview: (_, _) async => _preview(_word()),
      );
      expect(
        tester.widget<IconButton>(_key('office-word-page-settings')).onPressed,
        isNull,
      );
      await _mount(tester, preview: (_, _) async => _preview(_word()));
      await input(
        tester,
        paragraph('p0'),
        'BODY한',
        composing: const TextRange(start: 4, end: 5),
      );
      expect(
        tester.widget<IconButton>(_key('office-word-page-settings')).onPressed,
        isNull,
      );
      expect(
        tester.widget<TextField>(paragraph('p0')).controller!.value.composing,
        const TextRange(start: 4, end: 5),
      );
    },
  );

  for (final wrongSource in [true, false]) {
    testWidgets(
      'page preview rejects ${wrongSource ? 'different source' : 'different kind'} without losing inputs',
      (tester) async {
        final response = wrongSource
            ? _word(source: 'e')
            : WindowsOfficeSnapshot.fromJson({
                'kind': 'presentation',
                'sourceSha256': 'a' * 64,
                'paragraphs': [],
                'tables': [],
                'slides': [],
              });
        await _mount(
          tester,
          preview: (_, _) async =>
              _preview(response, baseSource: wrongSource ? 'e' : 'a'),
        );
        await _open(tester);
        await _set(tester, 'leftMargin', '25.4');
        await _tap(tester, 'office-word-page-apply');
        expect(_number(tester, 'leftMargin'), 25.4);
        expect(paragraph('p0'), findsOneWidget);
        expect(value(tester, 'p0'), 'BODY');
        expect(_key('office-word-page-retry-preview'), findsOneWidget);
      },
    );
  }

  testWidgets('late page preview cannot replace a newer document draft', (
    tester,
  ) async {
    final pending = Completer<WindowsOfficeDraftPreview>();
    final editor = await _mount(tester, preview: (_, _) => pending.future);
    await _open(tester);
    await _set(tester, 'leftMargin', '25.4');
    await tester.tap(_key('office-word-page-apply'));
    await tester.pump();
    await tester.pumpWidget(
      MaterialApp(
        home: WindowsOfficeEditor(
          key: editor,
          snapshot: _word(source: 'e', body: 'REPLACEMENT'),
          onPreview: (_, _) async =>
              _preview(_word(source: 'e'), baseSource: 'e'),
          onCommit: (_) async {},
          onBack: () {},
        ),
      ),
    );
    pending.complete(
      _preview(_word(body: 'STALE', leftMargin: 25.4, layoutHash: 'c')),
    );
    await tester.pumpAndSettle();
    expect(value(tester, 'p0'), 'REPLACEMENT');
    expect(find.text('STALE'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
