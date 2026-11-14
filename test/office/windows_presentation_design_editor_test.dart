import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/office/office_image_asset.dart';
import 'package:saber/data/office/windows_office_engine.dart';
import 'package:saber/pages/office/windows_office_editor.dart';

import 'windows_office_rich_editor_test.dart'
    show digest, textDetails, thumbnail, wordFixture;

typedef _Preview = Future<WindowsOfficeDraftPreview> Function(
  List<WindowsOfficeOperation>,
  Map<String, WindowsOfficeImageAsset>,
);

Map<String, Object?> _textShape(
  String id,
  String ownerId,
  String text, {
  String ownerKind = 'slide',
  bool template = false,
  bool mixed = false,
  double x = 10,
  double y = 20,
}) => {
  'id': id,
  'ownerKind': ownerKind,
  'ownerId': ownerId,
  'type': 'com.sun.star.drawing.TextShape',
  'shapeKind': 'text',
  'text': text,
  'editableText': !template,
  'presentationObject': template,
  'emptyPresentationObject': template && text.isEmpty,
  'canEditGeometry': !template,
  'canDelete': !template,
  'canEditTextStyle': !template,
  'canEditFill': !template,
  'canEditLine': !template,
  'x': x,
  'y': y,
  'width': 90,
  'height': 25,
  'fontSize': 12,
  'bold': false,
  'color': 0,
  'fillStyle': 'none',
  'lineStyle': 'none',
  'textDetails': {
    ...textDetails(text),
    'canReplace': !template,
    'canStyle': !template,
    if (mixed)
      'runs': [
        {
          'startUtf16': 0,
          'endUtf16': 1,
          'fontSize': 12,
          'fontFamily': 'Arial',
          'bold': false,
        },
        {
          'startUtf16': 1,
          'endUtf16': text.length,
          'fontSize': 24,
          'fontFamily': 'Serif',
          'bold': true,
        },
      ],
  },
};

String _designHash(String masterId, int layoutCode) =>
    digest('$masterId:$layoutCode');

WindowsOfficeSnapshot _presentation({
  String sourceHash = '',
  String title = 'TITLE',
  String masterId = 'm0',
  int layoutCode = 1,
  String? generatedId,
  String generatedText = '',
  String brand = 'Brand',
  Map<String, Object?>? masterImage,
  Map<String, Object?>? additionalMaster,
  Set<String> omittedMasters = const {},
  bool mixedTitle = false,
}) => WindowsOfficeSnapshot.fromJson({
  'kind': 'presentation',
  'sourceSha256': sourceHash.isEmpty ? 'a' * 64 : sourceHash,
  'paragraphs': [],
  'tables': [],
  'layoutOptions': [
    {'code': 0, 'label': '제목'},
    {'code': 1, 'label': '제목과 내용'},
    {'code': 19, 'label': '빈 슬라이드'},
    {'code': 20, 'label': '제목만'},
  ],
  'masters': [
    for (var i = 0; i < 2; i++)
      if (!omittedMasters.contains('m$i'))
        {
          'id': 'm$i',
          'name': '공통 디자인 ${i + 1}',
          'width': 254,
          'height': 142.875,
          'backgroundStyle': 'solid',
          'backgroundColor': 0xffffff,
          'shapes': [
            _textShape(
              'm$i/brand',
              'm$i',
              i == 0 ? brand : 'Other brand',
              ownerKind: 'master',
              y: 105,
            ),
            _textShape(
              'm$i/template',
              'm$i',
              '',
              ownerKind: 'master',
              template: true,
              x: 120,
            ),
            if (i == 0 && masterImage != null) masterImage,
          ],
        },
    ?additionalMaster,
  ],
  'slides': [
    for (var i = 0; i < 2; i++)
      {
        'id': 's$i',
        'width': 254,
        'height': 142.875,
        'masterId': i == 0 ? masterId : 'm0',
        'layoutCode': i == 0 ? layoutCode : 1,
        'designSha256': i == 0
            ? _designHash(masterId, layoutCode)
            : _designHash('m0', 1),
        'visible': true,
        'showMasterObjects': true,
        'backgroundStyle': 'none',
        'shapes': [
          _textShape(
            's$i/title',
            's$i',
            i == 0 ? title : 'SECOND',
            mixed: i == 0 && mixedTitle,
          ),
          if (i == 0 && generatedId != null)
            _textShape(generatedId, 's0', generatedText, x: 130, y: 70),
        ],
      },
  ],
});

List<Map<String, Object?>> _json(List<WindowsOfficeOperation> operations) => [
  for (final operation in operations) operation.toJson(),
];

void _expectReplacement(
  Map<String, Object?> operation,
  String id,
  String before,
  String after,
) {
  expect(operation['op'], 'textReplace');
  expect(operation['targetKind'], 'shape');
  expect(operation['id'], id);
  expect(operation['expectedTextSha256'], digest(before));
  final start = operation['startUtf16'] as int;
  final end = operation['endUtf16'] as int;
  expect(start, inInclusiveRange(0, before.length));
  expect(end, inInclusiveRange(start, before.length));
  expect(before.replaceRange(start, end, operation['text'] as String), after);
}

WindowsOfficeDraftPreview _preview(
  WindowsOfficeSnapshot snapshot, {
  String signature = 'host-validated-signature',
}) => WindowsOfficeDraftPreview(
  snapshot: snapshot,
  pdfPath: 'C:/owned-office-preview/$signature.pdf',
  signature: signature,
  baseSourceSha256: 'a' * 64,
);

Future<GlobalKey<WindowsOfficeEditorState>> _mount(
  WidgetTester tester, {
  required _Preview preview,
  WindowsOfficeSnapshot? snapshot,
  Future<void> Function(List<WindowsOfficeOperation>)? commit,
  Future<void> Function(
    List<WindowsOfficeOperation>,
    Map<String, WindowsOfficeImageAsset>,
  )?
  commitWithAssets,
  Future<WindowsOfficeImageAsset?> Function()? picker,
  ValueChanged<bool>? dirty,
  VoidCallback? back,
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
        snapshot: snapshot ?? _presentation(),
        onPreview: preview,
        onCommit: commit ?? (_) async {},
        onCommitWithAssets: commitWithAssets,
        imagePicker: picker,
        onDirtyChanged: dirty,
        onBack: back ?? () {},
      ),
    ),
  );
  return key;
}

Future<void> _choose(WidgetTester tester, String button, String item) async {
  await tester.ensureVisible(find.byKey(ValueKey(button)));
  await tester.tap(find.byKey(ValueKey(button)));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ValueKey(item)).last);
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump();
}

Future<void> _selectShape(WidgetTester tester, String id) async {
  final shape = find.byKey(ValueKey('office-shape-$id'));
  await tester.ensureVisible(shape);
  await tester.tap(shape);
  await tester.pump();
}

TextEditingController _text(WidgetTester tester) => tester
    .widget<TextField>(find.byKey(const ValueKey('office-shape-text')))
    .controller!;

void main() {
  testWidgets(
    'design previews prior text then edits the real generated alias in order',
    (tester) async {
      final previews = <List<Map<String, Object?>>>[];
      List<Map<String, Object?>>? saved;
      final dirty = <bool>[];
      late String generatedId;
      await _mount(
        tester,
        dirty: dirty.add,
        preview: (operations, assets) async {
          final request = _json(operations);
          previews.add(request);
          expect(assets, isEmpty);
          final design = request.last;
          generatedId = '${design['changeId']}/shape-0';
          return _preview(
            _presentation(
              title: 'BEFORE',
              layoutCode: 19,
              generatedId: generatedId,
            ),
          );
        },
        commit: (operations) async => saved = _json(operations),
      );
      await _selectShape(tester, 's0/title');
      await tester.enterText(
        find.byKey(const ValueKey('office-shape-text')),
        'BEFORE',
      );
      await _choose(tester, 'office-ppt-layout', 'office-ppt-layout-19');
      expect(previews, hasLength(1));
      _expectReplacement(previews.single.first, 's0/title', 'TITLE', 'BEFORE');
      final design = previews.single.last;
      expect(design['op'], 'slideDesign');
      expect(design['id'], 's0');
      expect(design['layoutCode'], 19);
      expect(design['expectedDesignSha256'], _designHash('m0', 1));
      expect(
        design['changeId'],
        isA<String>().having((id) => id.length, 'length', greaterThan(20)),
      );
      expect(design.containsKey('masterId'), isFalse);
      await _selectShape(tester, generatedId);
      await tester.enterText(
        find.byKey(const ValueKey('office-shape-text')),
        'AFTER',
      );
      await tester.tap(find.text('저장하고 닫기'));
      await tester.pump();
      expect(saved, hasLength(3));
      expect(saved!.take(2), previews.single);
      _expectReplacement(saved!.last, generatedId, '', 'AFTER');
      expect(dirty, [true, false]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'shared master decoration has one owner and is separate from applying it',
    (tester) async {
      final previewRequests = <List<Map<String, Object?>>>[];
      List<Map<String, Object?>>? saved;
      await _mount(
        tester,
        preview: (operations, _) async {
          previewRequests.add(_json(operations));
          return _preview(_presentation(brand: 'Shared brand'));
        },
        commit: (operations) async => saved = _json(operations),
      );
      await tester.tap(find.byKey(const ValueKey('office-ppt-edit-master')));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('office-ppt-linked-slide-s0')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('office-ppt-linked-slide-s1')),
        findsOneWidget,
      );
      await _selectShape(tester, 'm0/brand');
      await tester.enterText(
        find.byKey(const ValueKey('office-shape-text')),
        'Shared brand',
      );
      await tester.tap(find.byKey(const ValueKey('office-ppt-return-slide')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('office-slide-s1')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('office-ppt-edit-master')));
      await tester.pump();
      await _selectShape(tester, 'm0/brand');
      expect(_text(tester).text, 'Shared brand');
      await tester.tap(find.text('저장하고 닫기'));
      await tester.pump();
      expect(
        previewRequests
            .expand((request) => request)
            .where((operation) => operation['op'] == 'slideDesign'),
        isEmpty,
      );
      expect(saved, hasLength(1));
      _expectReplacement(saved!.single, 'm0/brand', 'Brand', 'Shared brand');
    },
  );

  testWidgets('structured shape journal adds presets only on slides', (
    tester,
  ) async {
    List<Map<String, Object?>>? saved;
    await _mount(
      tester,
      preview: (_, _) async => _preview(_presentation()),
      commit: (operations) async => saved = _json(operations),
    );
    await tester.tap(find.byKey(const ValueKey('office-ppt-edit-master')));
    await tester.pumpAndSettle();
    final menu = find.byKey(const ValueKey('office-insert-shape'));
    await tester.ensureVisible(menu);
    await tester.tap(menu);
    await tester.pumpAndSettle();
    for (final kind in ['text', 'rectangle', 'ellipse', 'line']) {
      expect(find.byKey(ValueKey('office-insert-$kind')), findsOneWidget);
    }
    for (final kind in ['roundedRectangle', 'rightArrow']) {
      expect(find.byKey(ValueKey('office-insert-$kind')), findsNothing);
    }
    Navigator.of(tester.element(menu)).pop();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('office-ppt-return-slide')));
    await tester.pumpAndSettle();
    for (final kind in ['roundedRectangle', 'rightArrow']) {
      await _choose(tester, 'office-insert-shape', 'office-insert-$kind');
    }
    await tester.tap(find.text('저장하고 닫기'));
    await tester.pumpAndSettle();
    final additions = saved!.where((op) => op['op'] == 'shapeAdd').toList();
    expect(additions.map((op) => op['shapeKind']), [
      'roundedRectangle',
      'rightArrow',
    ]);
    expect(additions.map((op) => op['slideId']), ['s0', 's0']);
  });

  testWidgets('master selection changes only the selected slide', (
    tester,
  ) async {
    final previews = <List<Map<String, Object?>>>[];
    List<Map<String, Object?>>? saved;
    await _mount(
      tester,
      preview: (operations, _) async {
        previews.add(_json(operations));
        return _preview(_presentation(masterId: 'm1'));
      },
      commit: (operations) async => saved = _json(operations),
    );
    await _choose(tester, 'office-ppt-master', 'office-ppt-master-m1');
    expect(previews.single, hasLength(1));
    final design = previews.single.single;
    expect(design['op'], 'slideDesign');
    expect(design['id'], 's0');
    expect(design['masterId'], 'm1');
    expect(design.containsKey('layoutCode'), isFalse);
    await tester.tap(find.byKey(const ValueKey('office-ppt-edit-master')));
    await tester.pump();
    await _selectShape(tester, 'm1/brand');
    expect(_text(tester).text, 'Other brand');
    await tester.enterText(
      find.byKey(const ValueKey('office-shape-text')),
      'Selected master',
    );
    await tester.tap(find.text('저장하고 닫기'));
    await tester.pump();
    expect(saved, hasLength(2));
    expect(saved!.first, design);
    _expectReplacement(
      saved!.last,
      'm1/brand',
      'Other brand',
      'Selected master',
    );
  });

  testWidgets(
    'design undo restores the journal selection and expires its PDF lease',
    (tester) async {
      List<Map<String, Object?>>? saved;
      late String generatedId;
      await _mount(
        tester,
        preview: (operations, _) async {
          generatedId = '${operations.last.toJson()['changeId']}/shape-0';
          return _preview(
            _presentation(
              title: 'EDIT',
              layoutCode: 19,
              generatedId: generatedId,
            ),
            signature: 'expired-after-undo',
          );
        },
        commit: (operations) async => saved = _json(operations),
      );
      await _selectShape(tester, 's0/title');
      await tester.enterText(
        find.byKey(const ValueKey('office-shape-text')),
        'EDIT',
      );
      _text(tester).selection = const TextSelection.collapsed(offset: 2);
      await tester.pump();
      await _choose(tester, 'office-ppt-layout', 'office-ppt-layout-19');
      await tester.tap(find.byKey(const ValueKey('office-ppt-undo')));
      await tester.pump();
      expect(find.byKey(ValueKey('office-shape-$generatedId')), findsNothing);
      expect(_text(tester).text, 'EDIT');
      expect(_text(tester).selection, const TextSelection.collapsed(offset: 2));
      expect(
        find.byKey(
          const ValueKey(
            'office-preview-C:/owned-office-preview/expired-after-undo.pdf',
          ),
        ),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('office-ppt-redo')));
      await tester.pump();
      expect(find.byKey(ValueKey('office-shape-$generatedId')), findsOneWidget);
      expect(
        find.byKey(
          const ValueKey(
            'office-preview-C:/owned-office-preview/expired-after-undo.pdf',
          ),
        ),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('office-ppt-undo')));
      await tester.pump();
      await tester.tap(find.text('저장하고 닫기'));
      await tester.pump();
      expect(saved, hasLength(1));
      _expectReplacement(saved!.single, 's0/title', 'TITLE', 'EDIT');
    },
  );

  testWidgets(
    'failed design preview retries the same identity and failed save keeps edits',
    (tester) async {
      final previews = <List<Map<String, Object?>>>[];
      final saves = <List<Map<String, Object?>>>[];
      var closed = false;
      await _mount(
        tester,
        back: () => closed = true,
        preview: (operations, _) async {
          final request = _json(operations);
          previews.add(request);
          if (previews.length == 1)
            throw StateError('Synthetic preview failure');
          return _preview(_presentation(title: 'KEPT', layoutCode: 19));
        },
        commit: (operations) async {
          saves.add(_json(operations));
          if (saves.length == 1) throw StateError('Synthetic commit failure');
        },
      );
      await _selectShape(tester, 's0/title');
      await tester.enterText(
        find.byKey(const ValueKey('office-shape-text')),
        'KEPT',
      );
      await _choose(tester, 'office-ppt-layout', 'office-ppt-layout-19');
      expect(previews, hasLength(1));
      expect(_text(tester).text, 'KEPT');
      expect(closed, isFalse);
      await tester.tap(find.byKey(const ValueKey('office-ppt-retry-preview')));
      await tester.pump();
      expect(previews, hasLength(2));
      expect(previews[1], previews[0]);
      await tester.tap(find.text('저장하고 닫기'));
      await tester.pump();
      expect(closed, isFalse);
      expect(find.textContaining('저장하지 못했습니다'), findsOneWidget);
      await tester.tap(find.text('저장 재시도'));
      await tester.pump();
      expect(closed, isTrue);
      expect(saves, [previews.last, previews.last]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a late preview cannot replace another document draft', (
    tester,
  ) async {
    final pending = Completer<WindowsOfficeDraftPreview>();
    var previews = 0;
    var commits = 0;
    final key = await _mount(
      tester,
      preview: (_, _) {
        previews++;
        return pending.future;
      },
    );
    await _choose(tester, 'office-ppt-layout', 'office-ppt-layout-19');
    expect(previews, 1);
    await tester.pumpWidget(
      MaterialApp(
        home: WindowsOfficeEditor(
          key: key,
          snapshot: wordFixture('교체 문서'),
          onCommit: (_) async => commits++,
          onBack: () {},
        ),
      ),
    );
    pending.complete(_preview(_presentation(title: 'STALE', layoutCode: 19)));
    await tester.pump();
    expect(find.text('교체 문서'), findsOneWidget);
    expect(find.text('STALE'), findsNothing);
    await tester.tap(find.text('저장하고 닫기'));
    await tester.pump();
    expect(commits, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pending preview cannot switch its slide or master owner', (
    tester,
  ) async {
    final pending = Completer<WindowsOfficeDraftPreview>();
    await _mount(tester, preview: (_, _) => pending.future);
    await _selectShape(tester, 's0/title');
    await _choose(tester, 'office-ppt-layout', 'office-ppt-layout-19');
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const ValueKey('office-slide-s1')))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<OutlinedButton>(
            find.byKey(const ValueKey('office-ppt-edit-master')),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<PopupMenuButton<int>>(
            find.byKey(const ValueKey('office-ppt-layout')),
          )
          .enabled,
      isFalse,
    );
    expect(find.byKey(const ValueKey('office-shape-s0/title')), findsOneWidget);
    expect(find.byKey(const ValueKey('office-shape-s1/title')), findsNothing);
    expect(find.byKey(const ValueKey('office-shape-m0/brand')), findsNothing);
    pending.complete(_preview(_presentation(layoutCode: 19)));
    await tester.pump();
    expect(find.byKey(const ValueKey('office-shape-s0/title')), findsOneWidget);
    final master = find.byKey(const ValueKey('office-ppt-edit-master'));
    expect(tester.widget<OutlinedButton>(master).onPressed, isNotNull);
    await tester.ensureVisible(master);
    await tester.tap(master);
    await tester.pump();
    expect(find.byKey(const ValueKey('office-shape-m0/brand')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('IME composition blocks design without losing the input', (
    tester,
  ) async {
    var previews = 0;
    await _mount(
      tester,
      preview: (_, _) async {
        previews++;
        return _preview(_presentation(title: 'TITLE한', layoutCode: 19));
      },
    );
    await _selectShape(tester, 's0/title');
    await tester.tap(find.byKey(const ValueKey('office-shape-text')));
    await tester.showKeyboard(find.byKey(const ValueKey('office-shape-text')));
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'TITLE한',
        selection: TextSelection.collapsed(offset: 6),
        composing: TextRange(start: 5, end: 6),
      ),
    );
    await tester.pump();
    expect(
      tester
          .widget<PopupMenuButton<int>>(
            find.byKey(const ValueKey('office-ppt-layout')),
          )
          .enabled,
      isFalse,
    );
    expect(previews, 0);
    expect(_text(tester).text, 'TITLE한');
    expect(_text(tester).value.composing, const TextRange(start: 5, end: 6));
  });

  testWidgets(
    'native master template placeholders cannot be moved deleted or styled',
    (tester) async {
      var commits = 0;
      await _mount(
        tester,
        preview: (_, _) async => _preview(_presentation()),
        commit: (_) async => commits++,
      );
      await tester.tap(find.byKey(const ValueKey('office-ppt-edit-master')));
      await tester.pump();
      await _selectShape(tester, 'm0/template');
      final text = find.byKey(const ValueKey('office-shape-text'));
      if (text.evaluate().isNotEmpty) {
        expect(tester.widget<TextField>(text).readOnly, isTrue);
      }
      expect(find.byKey(const ValueKey('office-shape-resize')), findsNothing);
      for (final property in ['x', 'y', 'width', 'height', 'font']) {
        final field = find.byKey(ValueKey('office-shape-$property'));
        if (field.evaluate().isNotEmpty) {
          final widget = tester.widget<TextField>(field);
          expect(widget.readOnly || widget.enabled == false, isTrue);
        }
      }
      final delete = find.byKey(const ValueKey('office-delete-shape'));
      if (delete.evaluate().isNotEmpty) {
        expect(tester.widget<IconButton>(delete).onPressed, isNull);
      }
      await tester.drag(
        find.byKey(const ValueKey('office-shape-m0/template')),
        const Offset(40, 10),
      );
      await tester.pump();
      await tester.tap(find.text('저장하고 닫기'));
      await tester.pump();
      expect(commits, 0);
    },
  );

  testWidgets(
    'master photo survives undo redo and is replayed once through design preview',
    (tester) async {
      final photo = WindowsOfficeImageAsset.fromBytes(base64Decode(thumbnail));
      List<Map<String, Object?>>? previewed;
      List<Map<String, Object?>>? saved;
      Map<String, WindowsOfficeImageAsset>? savedAssets;
      await _mount(
        tester,
        picker: () async => photo,
        preview: (operations, assets) async {
          previewed = _json(operations);
          final image = previewed!.singleWhere((op) => op['op'] == 'imageAdd');
          expect(image['slideId'], 'm0');
          expect(assets.keys, [image['assetId']]);
          expect(assets[image['assetId']]!.sha256, photo.sha256);
          return _preview(
            _presentation(
              layoutCode: 19,
              masterImage: {
                'id': image['id'],
                'ownerKind': 'master',
                'ownerId': 'm0',
                'type': 'com.sun.star.drawing.GraphicObjectShape',
                'shapeKind': 'image',
                'text': '',
                'editableText': false,
                for (final property in ['x', 'y', 'width', 'height'])
                  property: image[property],
                'image': {
                  'mimeType': photo.mimeType,
                  'pixelWidth': photo.width,
                  'pixelHeight': photo.height,
                  'canReplace': true,
                  'thumbnailBase64': thumbnail,
                  'thumbnailMimeType': photo.mimeType,
                  'thumbnailSha256': photo.sha256,
                },
              },
            ),
          );
        },
        commitWithAssets: (operations, assets) async {
          saved = _json(operations);
          savedAssets = assets;
        },
      );
      await tester.tap(find.byKey(const ValueKey('office-ppt-edit-master')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('office-insert-image')));
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('office-ppt-undo')));
      await tester.pump();
      expect(find.byType(Image), findsNothing);
      await tester.tap(find.byKey(const ValueKey('office-ppt-redo')));
      await tester.pump();
      expect(find.byType(Image), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('office-ppt-return-slide')));
      await tester.pump();
      await _choose(tester, 'office-ppt-layout', 'office-ppt-layout-19');
      await tester.tap(find.text('저장하고 닫기'));
      await tester.pump();
      expect(saved, previewed);
      expect(saved!.map((op) => op['op']), ['imageAdd', 'slideDesign']);
      final assetId = saved!.first['assetId'];
      expect(savedAssets!.keys, [assetId]);
      expect(savedAssets![assetId]!.sha256, photo.sha256);
    },
  );

  testWidgets(
    'a temporary invalid width does not drop an independent appearance change',
    (tester) async {
      List<Map<String, Object?>>? saved;
      await _mount(
        tester,
        preview: (_, _) async => _preview(_presentation()),
        commit: (operations) async => saved = _json(operations),
      );
      await _selectShape(tester, 's0/title');
      await tester.enterText(
        find.byKey(const ValueKey('office-shape-width')),
        '',
      );
      await _choose(
        tester,
        'office-shape-fill-style',
        'office-shape-fill-solid',
      );
      await tester.enterText(
        find.byKey(const ValueKey('office-shape-width')),
        '100',
      );
      await tester.tap(find.text('저장하고 닫기'));
      await tester.pump();
      expect(saved, isNotNull);
      final appearance = saved!.indexWhere(
        (operation) =>
            operation['op'] == 'shapeAppearance' &&
            operation['id'] == 's0/title' &&
            operation['fillStyle'] == 'solid',
      );
      final geometry = saved!.indexWhere(
        (operation) =>
            operation['op'] == 'shapeGeometry' &&
            operation['id'] == 's0/title' &&
            operation['width'] == 100,
      );
      expect(appearance, greaterThanOrEqualTo(0));
      expect(geometry, greaterThan(appearance));
    },
  );

  testWidgets(
    'a temporary invalid font does not drop geometry or bold on a new text box',
    (tester) async {
      List<Map<String, Object?>>? saved;
      await _mount(
        tester,
        preview: (_, _) async => _preview(_presentation()),
        commit: (operations) async => saved = _json(operations),
      );
      await _choose(tester, 'office-insert-shape', 'office-insert-text');
      await tester.enterText(
        find.byKey(const ValueKey('office-shape-font')),
        '',
      );
      await tester.enterText(
        find.byKey(const ValueKey('office-shape-x')),
        '32',
      );
      await tester.tap(find.byTooltip('굵게'));
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('office-shape-font')),
        '24',
      );
      await tester.tap(find.text('저장하고 닫기'));
      await tester.pump();
      final added = saved!.singleWhere(
        (operation) => operation['op'] == 'shapeAdd',
      );
      final styles = saved!.where(
        (operation) =>
            operation['op'] == 'shapeStyle' && operation['id'] == added['id'],
      );
      expect(
        saved!.where(
          (operation) =>
              operation['op'] == 'shapeGeometry' &&
              operation['id'] == added['id'] &&
              operation['x'] == 32,
        ),
        hasLength(1),
      );
      expect(styles.any((operation) => operation['bold'] == true), isTrue);
      expect(styles.any((operation) => operation['fontSize'] == 24), isTrue);
      expect(styles.every((operation) => operation.keys.length > 2), isTrue);
    },
  );

  testWidgets(
    'design undo restores real text input focus and subsequent typing',
    (tester) async {
      List<Map<String, Object?>>? saved;
      await _mount(
        tester,
        preview: (_, _) async =>
            _preview(_presentation(title: 'EDIT', layoutCode: 19)),
        commit: (operations) async => saved = _json(operations),
      );
      await _selectShape(tester, 's0/title');
      await tester.enterText(
        find.byKey(const ValueKey('office-shape-text')),
        'EDIT',
      );
      _text(tester).selection = const TextSelection.collapsed(offset: 2);
      await tester.pump();
      await _choose(tester, 'office-ppt-layout', 'office-ppt-layout-19');
      await tester.tap(find.byKey(const ValueKey('office-ppt-undo')));
      await tester.pump();
      final editable = tester.widget<EditableText>(
        find.descendant(
          of: find.byKey(const ValueKey('office-shape-text')),
          matching: find.byType(EditableText),
        ),
      );
      expect(editable.focusNode.hasFocus, isTrue);
      expect(
        editable.controller.selection,
        const TextSelection.collapsed(offset: 2),
      );
      expect(tester.testTextInput.hasAnyClients, isTrue);
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: 'EDXIT',
          selection: TextSelection.collapsed(offset: 3),
        ),
      );
      await tester.pump();
      expect(_text(tester).text, 'EDXIT');
      await tester.tap(find.text('저장하고 닫기'));
      await tester.pump();
      expect(saved, hasLength(2));
      _expectReplacement(saved!.first, 's0/title', 'TITLE', 'EDIT');
      _expectReplacement(saved!.last, 's0/title', 'EDIT', 'EDXIT');
    },
  );

  testWidgets(
    'undo restores the selected rich font family and range formatting',
    (tester) async {
      List<Map<String, Object?>>? saved;
      await _mount(
        tester,
        snapshot: _presentation(title: 'AB', mixedTitle: true),
        preview: (_, _) async =>
            _preview(_presentation(title: 'AB', mixedTitle: true)),
        commit: (operations) async => saved = _json(operations),
      );
      await _selectShape(tester, 's0/title');
      _text(tester).selection = const TextSelection(
        baseOffset: 1,
        extentOffset: 2,
      );
      await tester.pump();
      final family = find.byKey(const ValueKey('office-font-family-s0/title'));
      expect(tester.widget<TextField>(family).controller!.text, 'Serif');
      await tester.enterText(
        find.byKey(const ValueKey('office-shape-x')),
        '32',
      );
      await tester.tap(find.byKey(const ValueKey('office-ppt-undo')));
      await tester.pump();
      expect(
        _text(tester).selection,
        const TextSelection(baseOffset: 1, extentOffset: 2),
      );
      expect(tester.widget<TextField>(family).controller!.text, 'Serif');
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('office-shape-font')))
            .controller!
            .text,
        '24',
      );
      await tester.tap(find.byKey(const ValueKey('office-bold-s0/title')));
      await tester.pump();
      await tester.tap(find.text('저장하고 닫기'));
      await tester.pump();
      expect(saved, [
        {
          'op': 'textStyle',
          'targetKind': 'shape',
          'id': 's0/title',
          'startUtf16': 1,
          'endUtf16': 2,
          'expectedTextSha256': digest('AB'),
          'bold': false,
        },
      ]);
    },
  );

  testWidgets(
    'design adopts a generated live master alias without losing existing owners',
    (tester) async {
      List<Map<String, Object?>>? previewed;
      List<Map<String, Object?>>? saved;
      late String masterId;
      late String shapeId;
      await _mount(
        tester,
        preview: (operations, _) async {
          previewed = _json(operations);
          final changeId = previewed!.single['changeId'] as String;
          masterId = '$changeId/master-0';
          shapeId = '$changeId/shape-0';
          return _preview(
            _presentation(
              masterId: masterId,
              layoutCode: 20,
              additionalMaster: {
                'id': masterId,
                'name': '새 공통 디자인',
                'width': 254,
                'height': 142.875,
                'backgroundStyle': 'solid',
                'backgroundColor': 0xffffff,
                'shapes': [
                  _textShape(
                    shapeId,
                    masterId,
                    'Live brand',
                    ownerKind: 'master',
                    y: 105,
                  ),
                ],
              },
            ),
          );
        },
        commit: (operations) async => saved = _json(operations),
      );
      await _choose(tester, 'office-ppt-layout', 'office-ppt-layout-20');
      expect(
        find.byKey(const ValueKey('office-ppt-retry-preview')),
        findsNothing,
      );
      final edit = find.byKey(const ValueKey('office-ppt-edit-master'));
      expect(tester.widget<OutlinedButton>(edit).onPressed, isNotNull);
      await tester.ensureVisible(edit);
      await tester.tap(edit);
      await tester.pump();
      expect(
        find.byKey(const ValueKey('office-ppt-linked-slide-s0')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('office-ppt-linked-slide-s1')),
        findsNothing,
      );
      await _selectShape(tester, shapeId);
      await tester.enterText(
        find.byKey(const ValueKey('office-shape-text')),
        'New brand',
      );
      await tester.tap(find.byKey(const ValueKey('office-ppt-return-slide')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('office-ppt-master')));
      await tester.pumpAndSettle();
      for (final id in ['m0', 'm1', masterId]) {
        expect(find.byKey(ValueKey('office-ppt-master-$id')), findsOneWidget);
      }
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      await tester.tap(find.text('저장하고 닫기'));
      await tester.pump();
      expect(saved, hasLength(2));
      expect(saved!.first, previewed!.single);
      _expectReplacement(saved!.last, shapeId, 'Live brand', 'New brand');
    },
  );

  for (final invalid in [
    'missing-original',
    'unrelated-alias',
    'wrong-owner',
    'unknown-reference',
  ]) {
    testWidgets(
      'preview rejects $invalid while preserving the existing master draft',
      (tester) async {
        var commits = 0;
        await _mount(
          tester,
          preview: (operations, _) async {
            final changeId = operations.single.toJson()['changeId'] as String;
            final masterId = invalid == 'unrelated-alias'
                ? 'unrelated/master-0'
                : '$changeId/master-0';
            return _preview(
              _presentation(
                masterId: invalid == 'unknown-reference'
                    ? 'unknown-owner'
                    : masterId,
                layoutCode: 20,
                omittedMasters: invalid == 'missing-original' ? {'m1'} : {},
                additionalMaster: {
                  'id': masterId,
                  'name': '확인할 공통 디자인',
                  'width': 254,
                  'height': 142.875,
                  'backgroundStyle': 'solid',
                  'backgroundColor': 0xffffff,
                  'shapes': [
                    _textShape(
                      '$changeId/shape-0',
                      invalid == 'wrong-owner' ? 'm0' : masterId,
                      'Unexpected brand',
                      ownerKind: 'master',
                      y: 105,
                    ),
                  ],
                },
              ),
            );
          },
          commit: (_) async => commits++,
        );
        await _choose(tester, 'office-ppt-layout', 'office-ppt-layout-20');
        expect(
          find.byKey(const ValueKey('office-ppt-retry-preview')),
          findsOneWidget,
        );
        final undo = find.byKey(const ValueKey('office-ppt-undo'));
        expect(tester.widget<IconButton>(undo).onPressed, isNotNull);
        await tester.tap(undo);
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('office-ppt-edit-master')));
        await tester.pump();
        await _selectShape(tester, 'm0/brand');
        expect(_text(tester).text, 'Brand');
        await tester.tap(find.text('저장하고 닫기'));
        await tester.pump();
        expect(commits, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
