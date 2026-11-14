import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/office/office_image_asset.dart';
import 'package:saber/data/office/windows_office_engine.dart';
import 'package:saber/pages/office/windows_office_editor.dart';

import 'windows_office_rich_editor_test.dart'
    show digest, input, textDetails, thumbnail;

Map<String, Object?> photo(
  String id,
  String paragraph,
  int offset, {
  String hash = 'b',
  double width = 25,
  double height = 20,
}) => {
  'id': id,
  'ownerId': 'body',
  'paragraphId': paragraph,
  'anchorType': 'AS_CHARACTER',
  'offsetUtf16': offset,
  'canMove': true,
  'canDelete': true,
  'width': width,
  'height': height,
  'nativeGraphicSha256': hash * 64,
  'image': {
    'mimeType': 'image/png',
    'pixelWidth': 1,
    'pixelHeight': 1,
    'canReplace': true,
  },
};

WindowsOfficeSnapshot mutationWord({
  List<Map<String, Object?>> images = const [],
  List<Map<String, Object?>>? targets,
  bool knownTargets = true,
  String source = 'a',
  String firstText = 'ABCD',
  String secondText = 'TAIL',
  Map<String, List<Map<String, Object?>>> extraProtected = const {},
  Map<String, List<Map<String, Object?>>> paragraphRuns = const {},
  bool corruptRun = false,
  bool firstBold = false,
}) => WindowsOfficeSnapshot.fromJson({
  'kind': 'word',
  'sourceSha256': source * 64,
  'bodyOwnerId': 'body',
  'blocks': [
    for (final id in ['p0', 'p1']) {'kind': 'paragraph', 'id': id},
  ],
  'paragraphs': [
    for (final entry in [('p0', firstText), ('p1', secondText)])
      {
        'id': entry.$1,
        'ownerId': 'body',
        'text': entry.$2,
        'textDetails': {
          ...textDetails(
            entry.$2,
            protectedRanges:
                [
                  for (final image in images.where(
                    (image) => image['paragraphId'] == entry.$1,
                  ))
                    {
                      'startUtf16': image['offsetUtf16'],
                      'endUtf16': image['offsetUtf16'],
                      'type': 'Frame',
                    },
                  ...?extraProtected[entry.$1],
                ]..sort(
                  (a, b) => (a['startUtf16'] as int).compareTo(
                    b['startUtf16'] as int,
                  ),
                ),
          ),
          if (corruptRun && entry.$1 == 'p1')
            'runs': [
              {
                'startUtf16': 0,
                'endUtf16': entry.$2.length,
                'fontSize': 13,
                'bold': false,
                'italic': false,
                'underline': false,
                'fontFamily': 'Arial',
                'color': 0,
              },
            ],
          if (firstBold && entry.$1 == 'p0')
            'runs': [
              {
                'startUtf16': 0,
                'endUtf16': entry.$2.length,
                'fontSize': 12,
                'bold': true,
                'italic': false,
                'underline': false,
                'fontFamily': 'Arial',
                'color': 0,
              },
            ],
          if (paragraphRuns.containsKey(entry.$1))
            'runs': paragraphRuns[entry.$1],
        },
      },
  ],
  'tables': [],
  'slides': [],
  'wordOwners': [],
  'pageStyles': [],
  'wordImages': images,
  if (knownTargets)
    'wordImageTargets':
        targets ??
        [
          for (final id in ['p0', 'p1'])
            {
              'ownerId': 'body',
              'paragraphId': id,
              'canAdd': true,
              'canMoveHere': true,
            },
        ],
});

Finder button(String key) => find.byKey(ValueKey(key));
Finder field(String id) => button('office-paragraph-$id');

Future<void> press(WidgetTester tester, String key) async {
  await tester.ensureVisible(button(key));
  await tester.tap(button(key));
  await tester.pumpAndSettle();
}

Future<void> cursor(WidgetTester tester, String id, int offset) async {
  await tester.ensureVisible(field(id));
  final value = tester.widget<TextField>(field(id)).controller!.text;
  await input(
    tester,
    field(id),
    value,
    selection: TextSelection.collapsed(offset: offset),
  );
}

String addedAlias(WidgetTester tester) {
  final buttons = tester.widgetList<IconButton>(
    find.byWidgetPredicate(
      (widget) =>
          widget is IconButton &&
          widget.key is ValueKey<String> &&
          (widget.key! as ValueKey<String>).value.startsWith(
            'office-word-image-delete-',
          ),
    ),
  );
  expect(buttons, hasLength(1));
  return (buttons.single.key! as ValueKey<String>).value.substring(
    'office-word-image-delete-'.length,
  );
}

Future<void> mount(
  WidgetTester tester,
  GlobalKey<WindowsOfficeEditorState> key,
  WindowsOfficeSnapshot snapshot, {
  required Future<WindowsOfficeImageAsset?> Function() picker,
  Future<WindowsOfficeDraftPreview> Function(
    List<WindowsOfficeOperation>,
    Map<String, WindowsOfficeImageAsset>,
  )?
  preview,
  Future<void> Function(
    List<WindowsOfficeOperation>,
    Map<String, WindowsOfficeImageAsset>,
  )?
  commit,
  Future<void> Function(List<WindowsOfficeOperation>)? plainCommit,
  VoidCallback? back,
  double width = 1400,
}) async {
  tester.view.physicalSize = Size(width, 1400);
  tester.view.devicePixelRatio = 1;
  await tester.pumpWidget(
    MaterialApp(
      home: WindowsOfficeEditor(
        key: key,
        snapshot: snapshot,
        imagePicker: picker,
        onPreview: preview,
        onCommit: plainCommit ?? (_) async {},
        onBack: back ?? () {},
        onCommitWithAssets: commit ?? (_, _) async {},
      ),
    ),
  );
}

void main() {
  late WindowsOfficeImageAsset asset;
  setUp(
    () => asset = WindowsOfficeImageAsset.fromBytes(base64Decode(thumbnail)),
  );

  void resetView(WidgetTester tester) {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets(
    'zero-photo add move delete keep aliases assets and Frame expectations through undo redo preview save',
    (tester) async {
      resetView(tester);
      final key = GlobalKey<WindowsOfficeEditorState>();
      final previews = <List<Map<String, Object?>>>[];
      final previewAssets = <Map<String, WindowsOfficeImageAsset>>[];
      final commits = <List<Map<String, Object?>>>[];
      final commitAssets = <Map<String, WindowsOfficeImageAsset>>[];
      await mount(
        tester,
        key,
        mutationWord(),
        picker: () async => asset,
        preview: (operations, assets) async {
          final journal = operations
              .map((operation) => operation.toJson())
              .toList();
          previews.add(journal);
          previewAssets.add(Map.of(assets));
          final added = journal.first;
          return WindowsOfficeDraftPreview(
            snapshot: mutationWord(
              images: [
                photo(
                  added['id'] as String,
                  'p1',
                  1,
                  hash: 'e',
                  width: added['width'] as double,
                  height: added['height'] as double,
                ),
              ],
            ),
            pdfPath: 'C:/fixture/mutated.pdf',
            signature: 'source-bound-frame-preview',
            baseSourceSha256: 'a' * 64,
          );
        },
        commit: (operations, assets) async {
          commits.add(
            operations.map((operation) => operation.toJson()).toList(),
          );
          commitAssets.add(Map.of(assets));
        },
      );
      expect(button('office-word-image-add'), findsOneWidget);
      await cursor(tester, 'p0', 2);
      expect(
        tester.widget<IconButton>(button('office-word-image-add')).onPressed,
        isNotNull,
      );
      await press(tester, 'office-word-image-add');
      final alias = addedAlias(tester);
      await cursor(tester, 'p1', 1);
      await press(tester, 'office-word-image-move-$alias');
      await press(tester, 'office-word-image-delete-$alias');
      expect(button('office-word-image-delete-$alias'), findsNothing);
      for (var i = 0; i < 3; i++) await press(tester, 'office-word-undo');
      expect(button('office-word-image-delete-$alias'), findsNothing);
      for (var i = 0; i < 3; i++) await press(tester, 'office-word-redo');
      expect(button('office-word-image-delete-$alias'), findsNothing);
      await press(tester, 'office-word-undo');
      expect(addedAlias(tester), alias);
      await press(tester, 'office-word-refresh-preview');
      expect(find.textContaining('미리보기를 만들지 못했습니다'), findsNothing);
      expect(previews.single.map((operation) => operation['op']), [
        'wordImageAdd',
        'wordImageMove',
      ]);
      expect(previews.single.first, {
        'op': 'wordImageAdd',
        'id': alias,
        'ownerId': 'body',
        'paragraphId': 'p0',
        'offsetUtf16': 2,
        'expectedTextSha256': digest('ABCD'),
        'assetId': previewAssets.single.keys.single,
        'width': previews.single.first['width'],
        'height': previews.single.first['height'],
      });
      expect(previews.single.first['width'], greaterThan(0));
      expect(previews.single.first['height'], previews.single.first['width']);
      expect(previews.single.last, {
        'op': 'wordImageMove',
        'id': alias,
        'ownerId': 'body',
        'paragraphId': 'p1',
        'offsetUtf16': 1,
        'expectedTextSha256': digest('TAIL'),
      });
      await press(tester, 'office-word-undo');
      await press(tester, 'office-word-redo');
      await press(tester, 'office-word-refresh-preview');
      expect(previews.last, previews.first);
      expect(previewAssets.last.keys, previewAssets.first.keys);
      await press(tester, 'office-word-image-delete-$alias');
      await key.currentState!.save();
      await tester.pumpAndSettle();
      expect(commits.single, [
        ...previews.first,
        {'op': 'wordImageDelete', 'id': alias},
      ]);
      expect(commitAssets.single.keys, previewAssets.first.keys);
      expect(commitAssets.single.values.single.sha256, asset.sha256);
    },
  );

  testWidgets(
    'new photo aliases are never reused after undo branches or deletion',
    (tester) async {
      resetView(tester);
      final key = GlobalKey<WindowsOfficeEditorState>();
      await mount(tester, key, mutationWord(), picker: () async => asset);
      await cursor(tester, 'p0', 1);
      await press(tester, 'office-word-image-add');
      final first = addedAlias(tester);
      await press(tester, 'office-word-undo');
      await cursor(tester, 'p0', 2);
      await press(tester, 'office-word-image-add');
      final second = addedAlias(tester);
      expect(second, isNot(first));
      await press(tester, 'office-word-image-delete-$second');
      await cursor(tester, 'p0', 3);
      await press(tester, 'office-word-image-add');
      final third = addedAlias(tester);
      expect({first, second, third}, hasLength(3));
    },
  );

  testWidgets(
    'unknown foreign protected surrogate and ambiguous Frame targets keep photo add disabled',
    (tester) async {
      resetView(tester);
      var picked = 0;
      final samples = <(WindowsOfficeSnapshot, int)>[
        (mutationWord(knownTargets: false), 0),
        (mutationWord(targets: []), 0),
        (
          mutationWord(
            targets: [
              {'ownerId': 'body', 'paragraphId': 'p0'},
            ],
          ),
          0,
        ),
        (
          mutationWord(
            targets: [
              {
                'ownerId': 'header-1',
                'paragraphId': 'p0',
                'canAdd': true,
                'canMoveHere': true,
              },
            ],
          ),
          0,
        ),
        (
          mutationWord(
            extraProtected: {
              'p0': [
                {'startUtf16': 1, 'endUtf16': 2, 'type': 'TextField'},
              ],
            },
          ),
          1,
        ),
        (mutationWord(firstText: 'A😀B'), 2),
        (
          mutationWord(
            extraProtected: {
              'p0': [
                {'startUtf16': 2, 'endUtf16': 2, 'type': 'Frame'},
                {'startUtf16': 2, 'endUtf16': 2, 'type': 'Frame'},
              ],
            },
          ),
          2,
        ),
      ];
      final key = GlobalKey<WindowsOfficeEditorState>();
      for (final sample in samples) {
        await mount(
          tester,
          key,
          sample.$1,
          picker: () async {
            picked++;
            return asset;
          },
        );
        await cursor(tester, 'p0', sample.$2);
        expect(
          tester.widget<IconButton>(button('office-word-image-add')).onPressed,
          isNull,
        );
      }
      expect(picked, 0);
      await mount(
        tester,
        key,
        mutationWord(
          images: [photo('source-photo', 'p0', 1)],
          targets: [
            {
              'ownerId': 'body',
              'paragraphId': 'p1',
              'canAdd': true,
              'canMoveHere': false,
            },
          ],
        ),
        picker: () async => asset,
      );
      await cursor(tester, 'p1', 2);
      expect(
        tester.widget<IconButton>(button('office-word-image-add')).onPressed,
        isNotNull,
      );
      expect(
        tester
            .widget<IconButton>(button('office-word-image-move-source-photo'))
            .onPressed,
        isNull,
      );
    },
  );

  testWidgets(
    'move preview permits only requested Frame delta and rejects unrelated run changes',
    (tester) async {
      resetView(tester);
      final key = GlobalKey<WindowsOfficeEditorState>();
      var corrupt = true;
      var back = 0;
      List<Map<String, Object?>>? committed;
      final first = photo('source-photo', 'p0', 1);
      final other = photo('other-photo', 'p0', 3, hash: 'f');
      const protected = {
        'p1': [
          {'startUtf16': 3, 'endUtf16': 4, 'type': 'Bookmark'},
        ],
      };
      await mount(
        tester,
        key,
        mutationWord(images: [first, other], extraProtected: protected),
        picker: () async => asset,
        preview: (_, _) async => WindowsOfficeDraftPreview(
          snapshot: mutationWord(
            images: [photo('source-photo', 'p1', 2), other],
            extraProtected: protected,
            corruptRun: corrupt,
          ),
          pdfPath: 'C:/fixture/frame-move.pdf',
          signature: 'frame-move-checked',
          baseSourceSha256: 'a' * 64,
        ),
        plainCommit: (operations) async => committed = operations
            .map((operation) => operation.toJson())
            .toList(),
        back: () => back++,
      );
      await cursor(tester, 'p1', 2);
      await press(tester, 'office-word-image-move-source-photo');
      await press(tester, 'office-word-refresh-preview');
      expect(find.textContaining('미리보기를 만들지 못했습니다'), findsOneWidget);
      expect(back, 0);
      corrupt = false;
      await press(tester, 'office-word-refresh-preview');
      expect(find.textContaining('미리보기를 만들지 못했습니다'), findsNothing);
      expect(button('office-word-image-delete-other-photo'), findsOneWidget);
      await key.currentState!.save();
      await tester.pumpAndSettle();
      expect(back, 1);
      expect(committed, [
        {
          'op': 'wordImageMove',
          'id': 'source-photo',
          'ownerId': 'body',
          'paragraphId': 'p1',
          'offsetUtf16': 2,
          'expectedTextSha256': digest('TAIL'),
        },
      ]);
    },
  );

  testWidgets(
    'late mutation preview cannot populate a replacement source snapshot',
    (tester) async {
      resetView(tester);
      final key = GlobalKey<WindowsOfficeEditorState>();
      final pending = Completer<WindowsOfficeDraftPreview>();
      List<Map<String, Object?>>? requested;
      await mount(
        tester,
        key,
        mutationWord(),
        picker: () async => asset,
        preview: (operations, _) {
          requested = operations
              .map((operation) => operation.toJson())
              .toList();
          return pending.future;
        },
      );
      await cursor(tester, 'p0', 1);
      await press(tester, 'office-word-image-add');
      final oldAlias = addedAlias(tester);
      await tester.tap(button('office-word-refresh-preview'));
      await tester.pump();
      expect(requested, hasLength(1));
      await mount(
        tester,
        key,
        mutationWord(source: 'd', firstText: 'NEW BODY'),
        picker: () async => asset,
      );
      final added = requested!.single;
      pending.complete(
        WindowsOfficeDraftPreview(
          snapshot: mutationWord(
            images: [
              photo(
                oldAlias,
                'p0',
                1,
                hash: 'e',
                width: added['width'] as double,
                height: added['height'] as double,
              ),
            ],
          ),
          pdfPath: 'C:/fixture/old-source.pdf',
          signature: 'old-source',
          baseSourceSha256: 'a' * 64,
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(field('p0')).controller!.text,
        'NEW BODY',
      );
      expect(button('office-word-image-delete-$oldAlias'), findsNothing);
      expect(find.textContaining('미리보기를 만들지 못했습니다'), findsNothing);
    },
  );

  testWidgets(
    'photo picker cancellation duplicate taps and late source result create no alias',
    (tester) async {
      resetView(tester);
      final key = GlobalKey<WindowsOfficeEditorState>();
      var picked = 0;
      final pending = Completer<WindowsOfficeImageAsset?>();
      await mount(
        tester,
        key,
        mutationWord(),
        picker: () {
          picked++;
          return pending.future;
        },
      );
      await cursor(tester, 'p0', 1);
      await tester.tap(button('office-word-image-add'));
      await tester.pump();
      expect(
        tester.widget<IconButton>(button('office-word-image-add')).onPressed,
        isNull,
      );
      expect(picked, 1);
      pending.complete(null);
      await tester.pumpAndSettle();
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is IconButton &&
              widget.key.toString().contains('office-word-image-delete-'),
        ),
        findsNothing,
      );
      final late = Completer<WindowsOfficeImageAsset?>();
      await mount(
        tester,
        key,
        mutationWord(),
        picker: () {
          picked++;
          return late.future;
        },
      );
      await cursor(tester, 'p0', 1);
      await tester.tap(button('office-word-image-add'));
      await tester.pump();
      await mount(
        tester,
        key,
        mutationWord(source: 'd', firstText: 'NEW BODY'),
        picker: () async => asset,
      );
      late.complete(asset);
      await tester.pumpAndSettle();
      expect(picked, 2);
      expect(
        tester.widget<TextField>(field('p0')).controller!.text,
        'NEW BODY',
      );
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is IconButton &&
              widget.key.toString().contains('office-word-image-delete-'),
        ),
        findsNothing,
      );
    },
  );

  testWidgets(
    'photo mutation save failure retries the identical alias journal and assets',
    (tester) async {
      resetView(tester);
      final key = GlobalKey<WindowsOfficeEditorState>();
      final journals = <List<Map<String, Object?>>>[];
      final images = <Map<String, WindowsOfficeImageAsset>>[];
      var back = 0;
      await mount(
        tester,
        key,
        mutationWord(),
        picker: () async => asset,
        commit: (operations, assets) async {
          journals.add(
            operations.map((operation) => operation.toJson()).toList(),
          );
          images.add(Map.of(assets));
          if (journals.length == 1)
            throw StateError('synthetic publication failure');
        },
        back: () => back++,
      );
      await cursor(tester, 'p0', 1);
      await press(tester, 'office-word-image-add');
      final alias = addedAlias(tester);
      await expectLater(key.currentState!.save(), throwsStateError);
      await tester.pumpAndSettle();
      expect(back, 0);
      expect(button('office-word-image-delete-$alias'), findsOneWidget);
      await key.currentState!.save();
      await tester.pumpAndSettle();
      expect(back, 1);
      expect(journals.last, journals.first);
      expect(images.last.keys, images.first.keys);
      expect(images.last.values.single.sha256, asset.sha256);
    },
  );

  testWidgets('photo mutation controls and zero-photo add fit a 320px editor', (
    tester,
  ) async {
    resetView(tester);
    final key = GlobalKey<WindowsOfficeEditorState>();
    await mount(
      tester,
      key,
      mutationWord(),
      picker: () async => asset,
      width: 320,
    );
    await cursor(tester, 'p0', 1);
    await press(tester, 'office-word-image-add');
    final alias = addedAlias(tester);
    await cursor(tester, 'p1', 2);
    await press(tester, 'office-word-image-move-$alias');
    await press(tester, 'office-word-image-delete-$alias');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'ordinary text before a Frame updates its exact photo location before deletion and preview',
    (tester) async {
      resetView(tester);
      final key = GlobalKey<WindowsOfficeEditorState>();
      List<Map<String, Object?>>? requested;
      await mount(
        tester,
        key,
        mutationWord(images: [photo('source-photo', 'p0', 2)]),
        picker: () async => asset,
        preview: (operations, images) async {
          requested = operations
              .map((operation) => operation.toJson())
              .toList();
          expect(images, isEmpty);
          return WindowsOfficeDraftPreview(
            snapshot: mutationWord(firstText: 'XABCD'),
            pdfPath: 'C:/fixture/text-delete.pdf',
            signature: 'text-frame-delta',
            baseSourceSha256: 'a' * 64,
          );
        },
      );
      await tester.ensureVisible(field('p0'));
      await input(
        tester,
        field('p0'),
        'XABCD',
        selection: const TextSelection.collapsed(offset: 1),
      );
      expect(
        tester
            .widget<IconButton>(button('office-word-image-delete-source-photo'))
            .onPressed,
        isNotNull,
      );
      await press(tester, 'office-word-image-delete-source-photo');
      await press(tester, 'office-word-refresh-preview');
      expect(find.textContaining('미리보기를 만들지 못했습니다'), findsNothing);
      expect(requested, [
        {
          'op': 'textReplace',
          'targetKind': 'paragraph',
          'id': 'p0',
          'startUtf16': 0,
          'endUtf16': 0,
          'expectedTextSha256': digest('ABCD'),
          'text': 'X',
        },
        {'op': 'wordImageDelete', 'id': 'source-photo'},
      ]);
    },
  );

  testWidgets(
    'replacement deletion and UTF16 text deltas retain the exact movable Frame',
    (tester) async {
      resetView(tester);
      final key = GlobalKey<WindowsOfficeEditorState>();
      for (final sample in [
        ('ABCD', 'LONGCD', 3, 4, 0, 2, 'LONG'),
        ('ABCD', 'ACD', 3, 1, 1, 2, ''),
        ('A😀BC', 'AX😀BC', 4, 2, 1, 1, 'X'),
      ]) {
        List<Map<String, Object?>>? requested;
        await mount(
          tester,
          key,
          mutationWord(
            firstText: sample.$1,
            images: [photo('source-photo', 'p0', sample.$3)],
          ),
          picker: () async => asset,
          preview: (operations, _) async {
            requested = operations
                .map((operation) => operation.toJson())
                .toList();
            return WindowsOfficeDraftPreview(
              snapshot: mutationWord(firstText: sample.$2),
              pdfPath: 'C:/fixture/text-delta.pdf',
              signature: 'exact-utf16-frame-delta',
              baseSourceSha256: 'a' * 64,
            );
          },
        );
        await tester.ensureVisible(field('p0'));
        await input(
          tester,
          field('p0'),
          sample.$2,
          selection: TextSelection.collapsed(offset: sample.$4),
        );
        expect(
          tester
              .widget<IconButton>(
                button('office-word-image-delete-source-photo'),
              )
              .onPressed,
          isNotNull,
        );
        await press(tester, 'office-word-image-delete-source-photo');
        await press(tester, 'office-word-refresh-preview');
        expect(find.textContaining('미리보기를 만들지 못했습니다'), findsNothing);
        expect(requested, [
          {
            'op': 'textReplace',
            'targetKind': 'paragraph',
            'id': 'p0',
            'startUtf16': sample.$5,
            'endUtf16': sample.$6,
            'expectedTextSha256': digest(sample.$1),
            'text': sample.$7,
          },
          {'op': 'wordImageDelete', 'id': 'source-photo'},
        ]);
      }
    },
  );

  testWidgets(
    'format-only changes keep Frame location while preserving styled runs after photo deletion',
    (tester) async {
      resetView(tester);
      final key = GlobalKey<WindowsOfficeEditorState>();
      List<Map<String, Object?>>? requested;
      await mount(
        tester,
        key,
        mutationWord(images: [photo('source-photo', 'p0', 2)]),
        picker: () async => asset,
        preview: (operations, _) async {
          requested = operations
              .map((operation) => operation.toJson())
              .toList();
          return WindowsOfficeDraftPreview(
            snapshot: mutationWord(firstBold: true),
            pdfPath: 'C:/fixture/styled-frame.pdf',
            signature: 'styled-run-frame-deletion',
            baseSourceSha256: 'a' * 64,
          );
        },
      );
      await tester.ensureVisible(field('p0'));
      await input(
        tester,
        field('p0'),
        'ABCD',
        selection: const TextSelection(baseOffset: 0, extentOffset: 4),
      );
      await press(tester, 'office-bold-p0');
      expect(
        tester
            .widget<IconButton>(button('office-word-image-delete-source-photo'))
            .onPressed,
        isNotNull,
      );
      await press(tester, 'office-word-image-delete-source-photo');
      await press(tester, 'office-word-refresh-preview');
      expect(find.textContaining('미리보기를 만들지 못했습니다'), findsNothing);
      expect(requested, [
        {
          'op': 'textStyle',
          'targetKind': 'paragraph',
          'id': 'p0',
          'startUtf16': 0,
          'endUtf16': 4,
          'expectedTextSha256': digest('ABCD'),
          'bold': true,
        },
        {'op': 'wordImageDelete', 'id': 'source-photo'},
      ]);
    },
  );

  for (final contrastingCaret in [false, true]) {
    testWidgets(
      'native Unicode null-color and ${contrastingCaret ? 'contrasting' : 'same'} zero-length caret runs allow add preview move preview save',
      (tester) async {
        resetView(tester);
        const sourceText =
            'SOURCE_FIRST: before A😀e\u0301B | after SOURCE_FIRST';
        const destinationText =
            'GAP_FIRST: before A😀e\u0301B | after GAP_FIRST';
        expect(sourceText.length, 48);
        expect(destinationText.length, 42);
        expect(
          digest(sourceText),
          '150515e7b94b8c97d7368e0f9912581f7f812b4626bd21abe17cc2ec65cd30d5',
        );
        expect(
          digest(destinationText),
          '5eed07acab3ca38c9cca78f9b98d1091c68541d07b9ec75fffa7556fa3625ae7',
        );
        final addOffset = sourceText.indexOf('|');
        final moveOffset = destinationText.indexOf('|');
        Map<String, Object?> run(int start, int end, {bool caret = false}) => {
          'startUtf16': start,
          'endUtf16': end,
          'fontSize': caret && contrastingCaret ? 16.0 : 10.0,
          'bold': caret && contrastingCaret,
          'italic': false,
          'underline': false,
          'color': null,
          'fontFamily': '맑은 고딕',
        };
        List<Map<String, Object?>> runs(String text, {int? frame}) => [
          if (frame == null)
            run(0, text.length)
          else ...[
            run(0, frame),
            run(frame, text.length),
          ],
          run(text.length, text.length, caret: true),
        ];
        WindowsOfficeSnapshot snapshot({Map<String, Object?>? image}) =>
            mutationWord(
              firstText: sourceText,
              secondText: destinationText,
              images: image == null ? [] : [image],
              paragraphRuns: {
                'p0': runs(
                  sourceText,
                  frame: image?['paragraphId'] == 'p0' ? addOffset : null,
                ),
                'p1': runs(
                  destinationText,
                  frame: image?['paragraphId'] == 'p1' ? moveOffset : null,
                ),
              },
            );
        final key = GlobalKey<WindowsOfficeEditorState>();
        final previewJournals = <List<Map<String, Object?>>>[];
        final previewAssets = <Map<String, WindowsOfficeImageAsset>>[];
        List<Map<String, Object?>>? saved;
        Map<String, WindowsOfficeImageAsset>? savedAssets;
        var back = 0;
        await mount(
          tester,
          key,
          snapshot(),
          picker: () async => asset,
          preview: (operations, assets) async {
            final journal = operations
                .map((operation) => operation.toJson())
                .toList();
            previewJournals.add(journal);
            previewAssets.add(Map.of(assets));
            expect(journal.length, inInclusiveRange(1, 2));
            expect(journal.first['op'], 'wordImageAdd');
            final added = journal.first;
            final moved = journal.length == 2;
            if (moved) expect(journal.last['op'], 'wordImageMove');
            return WindowsOfficeDraftPreview(
              snapshot: snapshot(
                image: photo(
                  added['id'] as String,
                  moved ? 'p1' : 'p0',
                  moved ? moveOffset : addOffset,
                  hash: 'e',
                  width: added['width'] as double,
                  height: added['height'] as double,
                ),
              ),
              pdfPath: 'C:/fixture/native-unicode-caret.pdf',
              signature: 'native-unicode-caret-${journal.length}',
              baseSourceSha256: 'a' * 64,
            );
          },
          commit: (operations, assets) async {
            saved = operations.map((operation) => operation.toJson()).toList();
            savedAssets = Map.of(assets);
          },
          back: () => back++,
        );
        await cursor(tester, 'p0', addOffset);
        expect(
          tester.widget<IconButton>(button('office-word-image-add')).onPressed,
          isNotNull,
        );
        await press(tester, 'office-word-image-add');
        final alias = addedAlias(tester);
        await press(tester, 'office-word-refresh-preview');
        expect(find.textContaining('미리보기를 만들지 못했습니다'), findsNothing);
        expect(previewJournals, hasLength(1));
        expect(
          previewJournals.single.single['expectedTextSha256'],
          digest(sourceText),
        );
        expect(previewJournals.single.single['offsetUtf16'], addOffset);
        await cursor(tester, 'p1', moveOffset);
        expect(
          tester
              .widget<IconButton>(button('office-word-image-move-$alias'))
              .onPressed,
          isNotNull,
        );
        await press(tester, 'office-word-image-move-$alias');
        await press(tester, 'office-word-refresh-preview');
        expect(find.textContaining('미리보기를 만들지 못했습니다'), findsNothing);
        expect(previewJournals, hasLength(2));
        expect(previewJournals.last, [
          previewJournals.first.single,
          {
            'op': 'wordImageMove',
            'id': alias,
            'ownerId': 'body',
            'paragraphId': 'p1',
            'offsetUtf16': moveOffset,
            'expectedTextSha256': digest(destinationText),
          },
        ]);
        expect(
          tester.widget<TextField>(field('p0')).controller!.text,
          sourceText,
        );
        expect(
          tester.widget<TextField>(field('p1')).controller!.text,
          destinationText,
        );
        expect(back, 0);
        await key.currentState!.save();
        await tester.pumpAndSettle();
        expect(back, 1);
        expect(saved, previewJournals.last);
        expect(savedAssets!.keys, previewAssets.first.keys);
        expect(savedAssets!.values.single.sha256, asset.sha256);
        expect(previewAssets.last.keys, previewAssets.first.keys);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
