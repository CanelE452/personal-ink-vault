import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/office/office_image_asset.dart';
import 'package:saber/data/office/windows_office_engine.dart';
import 'package:saber/pages/office/windows_office_editor.dart';

import 'windows_office_rich_editor_test.dart' show textDetails, thumbnail;

WindowsOfficeSnapshot photoWord({
  String hash = 'b',
  bool writable = true,
  bool corruptOther = false,
}) => WindowsOfficeSnapshot.fromJson({
  'kind': 'word',
  'sourceSha256': 'a' * 64,
  'bodyOwnerId': 'body',
  'blocks': [
    {'kind': 'paragraph', 'id': 'p0'},
  ],
  'paragraphs': [
    {
      'id': 'p0',
      'ownerId': 'body',
      'text': 'BODY',
      'textDetails': textDetails('BODY'),
    },
  ],
  'tables': [],
  'slides': [],
  'wordOwners': [],
  'pageStyles': [],
  'wordImages': [
    for (final id in ['photo-1', 'photo-2'])
      {
        'id': id,
        'ownerId': 'body',
        'paragraphId': 'p0',
        'anchorType': 'AS_CHARACTER',
        'width': 25.0,
        'height': 20.0,
        'nativeGraphicSha256':
            (id == 'photo-1'
                ? hash
                : corruptOther
                ? 'd'
                : 'f') *
            64,
        'image': {
          'mimeType': 'image/png',
          'pixelWidth': 1,
          'pixelHeight': 1,
          'canReplace': writable,
        },
      },
  ],
});

void main() {
  late WindowsOfficeImageAsset asset;
  setUp(
    () => asset = WindowsOfficeImageAsset.fromBytes(base64Decode(thumbnail)),
  );

  Future<GlobalKey<WindowsOfficeEditorState>> mount(
    WidgetTester tester, {
    bool writable = true,
    required Future<WindowsOfficeDraftPreview> Function(
      List<WindowsOfficeOperation>,
      Map<String, WindowsOfficeImageAsset>,
    )
    preview,
    required Future<void> Function(
      List<WindowsOfficeOperation>,
      Map<String, WindowsOfficeImageAsset>,
    )
    commit,
    VoidCallback? picked,
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
          snapshot: photoWord(writable: writable),
          onCommit: (_) async {},
          onBack: () {},
          onCommitWithAssets: commit,
          onPreview: preview,
          imagePicker: () async {
            picked?.call();
            return asset;
          },
        ),
      ),
    );
    return key;
  }

  WindowsOfficeDraftPreview response({bool corrupt = false}) =>
      WindowsOfficeDraftPreview(
        snapshot: photoWord(hash: 'c', corruptOther: corrupt),
        pdfPath: 'C:/owned/photo-preview.pdf',
        signature: 'validated-photo-preview',
        baseSourceSha256: 'a' * 64,
      );

  testWidgets(
    'Word photo replacement retains its asset through undo redo preview and save',
    (tester) async {
      final requests = <List<Map<String, Object?>>>[];
      final previews = <Map<String, WindowsOfficeImageAsset>>[];
      final commits = <Map<String, WindowsOfficeImageAsset>>[];
      final key = await mount(
        tester,
        preview: (operations, images) async {
          requests.add([
            for (final operation in operations) operation.toJson(),
          ]);
          previews.add(Map.of(images));
          return response();
        },
        commit: (operations, images) async {
          requests.add([
            for (final operation in operations) operation.toJson(),
          ]);
          commits.add(Map.of(images));
        },
      );
      await tester.tap(
        find.byKey(const ValueKey('office-word-image-replace-photo-1')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('office-word-undo')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('office-word-redo')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('office-word-refresh-preview')),
      );
      await tester.pumpAndSettle();
      expect(previews, hasLength(1));
      expect(previews.single.values.single.sha256, asset.sha256);
      expect(requests.single.single['op'], 'imageReplace');
      expect(requests.single.single['id'], 'photo-1');
      expect(requests.single.single['assetId'], previews.single.keys.single);
      await tester.tap(find.byKey(const ValueKey('office-word-undo')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('office-word-redo')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('office-word-refresh-preview')),
      );
      await tester.pumpAndSettle();
      expect(previews, hasLength(2));
      expect(previews.last.keys, previews.first.keys);
      await key.currentState!.save();
      await tester.pumpAndSettle();
      expect(commits, hasLength(1));
      expect(commits.single.keys, previews.first.keys);
      expect(commits.single.values.single.sha256, asset.sha256);
    },
  );

  testWidgets(
    'Word preview rejects changes to an unrelated photo and keeps the pending asset',
    (tester) async {
      final commits = <Map<String, WindowsOfficeImageAsset>>[];
      final key = await mount(
        tester,
        preview: (_, _) async => response(corrupt: true),
        commit: (_, images) async => commits.add(Map.of(images)),
      );
      await tester.tap(
        find.byKey(const ValueKey('office-word-image-replace-photo-1')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('office-word-refresh-preview')),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('미리보기를 만들지 못했습니다'), findsOneWidget);
      await key.currentState!.save();
      await tester.pumpAndSettle();
      expect(commits.single.values.single.sha256, asset.sha256);
    },
  );

  testWidgets('Word photo replacement requires explicit source capability', (
    tester,
  ) async {
    var picked = 0;
    await mount(
      tester,
      writable: false,
      picked: () => picked++,
      preview: (_, _) async => response(),
      commit: (_, _) async {},
    );
    final button = tester.widget<IconButton>(
      find.byKey(const ValueKey('office-word-image-replace-photo-1')),
    );
    expect(button.onPressed, isNull);
    expect(picked, 0);
  });
}
