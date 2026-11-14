import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/office/office_image_asset.dart';
import 'package:saber/data/office/windows_office_engine.dart';
import 'package:saber/pages/office/windows_office_editor.dart';

import 'windows_office_rich_editor_test.dart'
    show imageFixture, thumbnail, wordFixture;

void main() {
  late WindowsOfficeImageAsset image;
  setUp(
    () => image = WindowsOfficeImageAsset.fromBytes(base64Decode(thumbnail)),
  );

  Future<void> mount(
    WidgetTester tester, {
    required Future<WindowsOfficeImageAsset?> Function() picker,
    required Future<void> Function(
      List<WindowsOfficeOperation>,
      Map<String, WindowsOfficeImageAsset>,
    )
    commit,
    VoidCallback? oldCommit,
  }) async {
    tester.view.physicalSize = const Size(1280, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: WindowsOfficeEditor(
          snapshot: imageFixture(),
          onCommit: (_) async {
            oldCommit?.call();
          },
          onCommitWithAssets: commit,
          imagePicker: picker,
          onBack: () {},
        ),
      ),
    );
  }

  testWidgets(
    'picked photo is embedded through an opaque asset and stable retry',
    (tester) async {
      final attempts = <List<Map<String, Object?>>>[];
      final assets = <Map<String, WindowsOfficeImageAsset>>[];
      var oldCommits = 0;
      await mount(
        tester,
        picker: () async => image,
        oldCommit: () => oldCommits++,
        commit: (operations, uploaded) async {
          attempts.add([
            for (final operation in operations) operation.toJson(),
          ]);
          assets.add(uploaded);
          if (attempts.length == 1)
            throw StateError('Synthetic image save failure');
        },
      );
      await tester.tap(find.byKey(const ValueKey('office-insert-image')));
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsNWidgets(2));
      await tester.tap(find.text('저장하고 닫기'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('저장 재시도'));
      await tester.pumpAndSettle();
      expect(oldCommits, 0);
      expect(attempts, hasLength(2));
      expect(attempts[1], attempts[0]);
      expect(assets[1].keys, assets[0].keys);
      final operation = attempts.first.single;
      expect(operation['op'], 'imageAdd');
      expect(operation['slideId'], 's0');
      expect(operation['id'], isNot(anyOf('s0/photo', 's0/text')));
      expect(operation.containsKey('path'), isFalse);
      expect(operation.containsKey('data'), isFalse);
      final assetId = operation['assetId'] as String;
      expect(assets.first.keys, [assetId]);
      expect(assets.first[assetId]!.sha256, image.sha256);
      expect(assets.first[assetId]!.bytes, image.bytes);
    },
  );

  testWidgets('photo replacement keeps original object identity and geometry', (
    tester,
  ) async {
    List<Map<String, Object?>>? saved;
    Map<String, WindowsOfficeImageAsset>? assets;
    await mount(
      tester,
      picker: () async => image,
      commit: (operations, uploaded) async {
        saved = [for (final operation in operations) operation.toJson()];
        assets = uploaded;
      },
    );
    await tester.tap(find.byKey(const ValueKey('office-shape-s0/photo')));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('office-image-rotate-right')),
      findsNothing,
    );
    await tester.tap(find.byKey(const ValueKey('office-replace-image')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('저장하고 닫기'));
    await tester.pumpAndSettle();
    expect(saved, hasLength(1));
    expect(saved!.single['op'], 'imageReplace');
    expect(saved!.single['id'], 's0/photo');
    expect(saved!.single.keys.toSet(), {'op', 'id', 'assetId'});
    expect(assets!.keys, [saved!.single['assetId']]);
  });

  testWidgets('photo rotation wraps clockwise and survives undo and redo', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final saves = <List<Map<String, Object?>>>[];
    final dirty = <bool>[];
    await tester.pumpWidget(
      MaterialApp(
        home: WindowsOfficeEditor(
          snapshot: WindowsOfficeSnapshot.fromJson({
            'kind': 'presentation',
            'sourceSha256': 'a' * 64,
            'paragraphs': [],
            'tables': [],
            'masters': [],
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
                    'image': {'rotationHundredths': 34800, 'canRotate': true},
                  },
                ],
              },
            ],
          }),
          onCommit: (operations) async => saves.add([
            for (final operation in operations) operation.toJson(),
          ]),
          onBack: () {},
          onDirtyChanged: dirty.add,
        ),
      ),
    );

    final angle = find.byKey(const ValueKey('office-image-rotation-angle'));
    final clockwise = find.byKey(const ValueKey('office-image-rotate-right'));
    await tester.tap(find.byKey(const ValueKey('office-shape-s0/photo')));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(angle).data, '회전 348°');

    await tester.ensureVisible(clockwise);
    await tester.tap(clockwise);
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(angle).data, '회전 78°');
    expect(dirty.last, isTrue);

    await tester.tap(find.byKey(const ValueKey('office-ppt-undo')));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(angle).data, '회전 348°');
    expect(dirty.last, isFalse);

    await tester.tap(find.byKey(const ValueKey('office-ppt-redo')));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(angle).data, '회전 78°');
    expect(saves, isEmpty);

    await tester.tap(find.text('저장하고 닫기'));
    await tester.pumpAndSettle();
    expect(saves, [
      [
        {
          'op': 'imageRotate',
          'id': 's0/photo',
          'expectedRotationHundredths': 34800,
          'rotationHundredths': 7800,
        },
      ],
    ]);
  });

  testWidgets(
    'deleting an unsaved photo drops its staged asset and operation',
    (tester) async {
      var commits = 0;
      await mount(
        tester,
        picker: () async => image,
        commit: (_, _) async {
          commits++;
        },
      );
      await tester.tap(find.byKey(const ValueKey('office-insert-image')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('office-delete-shape')));
      await tester.pump();
      await tester.tap(find.text('저장하고 닫기'));
      await tester.pumpAndSettle();
      expect(commits, 0);
      expect(find.byType(Image), findsOneWidget);
    },
  );

  testWidgets('late photo selection cannot attach to a replacement document', (
    tester,
  ) async {
    final picked = Completer<WindowsOfficeImageAsset?>();
    var commits = 0;
    await mount(
      tester,
      picker: () => picked.future,
      commit: (_, _) async {
        commits++;
      },
    );
    await tester.tap(find.byKey(const ValueKey('office-insert-image')));
    await tester.pump();
    await tester.pumpWidget(
      MaterialApp(
        home: WindowsOfficeEditor(
          snapshot: wordFixture('별도 문서'),
          onCommit: (_) async {
            commits++;
          },
          onBack: () {},
        ),
      ),
    );
    picked.complete(image);
    await tester.pumpAndSettle();
    expect(find.text('별도 문서'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    await tester.tap(find.text('저장하고 닫기'));
    await tester.pumpAndSettle();
    expect(commits, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'late photo selection after disposal does not update the editor',
    (tester) async {
      final picked = Completer<WindowsOfficeImageAsset?>();
      var commits = 0;
      await mount(
        tester,
        picker: () => picked.future,
        commit: (_, _) async {
          commits++;
        },
      );
      await tester.tap(find.byKey(const ValueKey('office-insert-image')));
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      picked.complete(image);
      await tester.pumpAndSettle();
      expect(commits, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'image controls require a caller that can publish the embedded asset',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: WindowsOfficeEditor(
            snapshot: imageFixture(),
            onCommit: (_) async {},
            onBack: () {},
          ),
        ),
      );
      expect(find.byKey(const ValueKey('office-insert-image')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('office-shape-s0/photo')));
      await tester.pump();
      expect(find.byKey(const ValueKey('office-replace-image')), findsNothing);
    },
  );
}
