import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as im;
import 'package:saber/data/office/office_image_asset.dart';
import 'package:saber/data/office/windows_office_engine.dart';

const assetId = '11111111-1111-4111-8111-111111111111';

Map<String, dynamic> wordSnapshot() => {
  'kind': 'word',
  'sourceSha256': 'a' * 64,
  'bodyOwnerId': 'body',
  'paragraphs': <Object?>[],
  'tables': <Object?>[],
  'slides': <Object?>[],
};

WindowsOfficeOperation add({String asset = assetId}) =>
    WindowsOfficeOperation.wordImageAdd(
      id: 'new-photo',
      ownerId: 'body',
      paragraphId: 'paragraph-1',
      offsetUtf16: 3,
      expectedTextSha256: 'b' * 64,
      assetId: asset,
      width: 25.4,
      height: 19.05,
    );

WindowsOfficeOperation move() => WindowsOfficeOperation.wordImageMove(
  id: 'new-photo',
  ownerId: 'body',
  paragraphId: 'paragraph-2',
  offsetUtf16: 0,
  expectedTextSha256: 'c' * 64,
);

void main() {
  test(
    'Word mutation DTOs preserve ordered aliases and exact closed wire fields',
    () {
      final operations = [
        add(),
        move(),
        WindowsOfficeOperation.wordImageDelete(id: 'new-photo'),
      ];
      expect(operations.map((operation) => operation.toJson()).toList(), [
        {
          'op': 'wordImageAdd',
          'id': 'new-photo',
          'ownerId': 'body',
          'paragraphId': 'paragraph-1',
          'offsetUtf16': 3,
          'expectedTextSha256': 'b' * 64,
          'assetId': assetId,
          'width': 25.4,
          'height': 19.05,
        },
        {
          'op': 'wordImageMove',
          'id': 'new-photo',
          'ownerId': 'body',
          'paragraphId': 'paragraph-2',
          'offsetUtf16': 0,
          'expectedTextSha256': 'c' * 64,
        },
        {'op': 'wordImageDelete', 'id': 'new-photo'},
      ]);
      final exposed = operations.first.toJson();
      exposed['ownerId'] = 'foreign-owner';
      exposed['path'] = '/foreign/image.png';
      expect(operations.first.toJson()['ownerId'], 'body');
      expect(operations.first.toJson().containsKey('path'), isFalse);
    },
  );

  test(
    'Word target snapshots distinguish unknown from verified empty catalogs',
    () {
      for (final json in [
        wordSnapshot(),
        {...wordSnapshot(), 'wordImageTargets': null},
      ]) {
        expect(WindowsOfficeSnapshot.fromJson(json).wordImageTargets, isNull);
      }
      final empty = WindowsOfficeSnapshot.fromJson({
        ...wordSnapshot(),
        'wordImages': <Object?>[],
        'wordImageTargets': <Object?>[],
      });
      expect(empty.wordImages, isEmpty);
      expect(empty.wordImageTargets, isEmpty);
      expect(() => empty.wordImageTargets!.clear(), throwsUnsupportedError);
    },
  );

  test(
    'zero-photo Word documents retain immutable explicit target capabilities',
    () {
      final first = <String, Object?>{
        'ownerId': 'body',
        'paragraphId': 'paragraph-1',
        'canAdd': true,
        'canMoveHere': true,
      };
      final rows = <Object?>[
        first,
        {'ownerId': 'header-1', 'paragraphId': 'paragraph-2'},
      ];
      final snapshot = WindowsOfficeSnapshot.fromJson({
        ...wordSnapshot(),
        'wordImages': <Object?>[],
        'wordImageTargets': rows,
      });
      final targets = snapshot.wordImageTargets!;
      expect(targets.first.ownerId, 'body');
      expect(targets.first.paragraphId, 'paragraph-1');
      expect(targets.first.canAdd, isTrue);
      expect(targets.first.canMoveHere, isTrue);
      expect(targets.last.canAdd, isFalse);
      expect(targets.last.canMoveHere, isFalse);
      first['ownerId'] = 'foreign';
      first['canAdd'] = false;
      rows.clear();
      expect(targets, hasLength(2));
      expect(targets.first.ownerId, 'body');
      expect(targets.first.canAdd, isTrue);
      expect(() => targets.removeLast(), throwsUnsupportedError);
    },
  );

  test(
    'Word mutation capabilities require explicit known AS_CHARACTER locations',
    () {
      Map<String, Object?> image(
        String id, {
        String anchor = 'AS_CHARACTER',
        int? offset,
        bool capabilities = true,
      }) => {
        'id': id,
        'ownerId': 'body',
        'paragraphId': 'paragraph-1',
        'anchorType': anchor,
        'offsetUtf16': ?offset,
        if (capabilities) ...{'canMove': true, 'canDelete': true},
        'image': {'canReplace': true},
      };
      final rows = <Object?>[
        image('known', offset: 3),
        image('unknown-offset'),
        image('unknown-capability', offset: 0, capabilities: false),
        image('floating', offset: 0, anchor: 'AT_PARAGRAPH'),
        image('negative-offset', offset: -1),
      ];
      final snapshot = WindowsOfficeSnapshot.fromJson({
        ...wordSnapshot(),
        'wordImages': rows,
      });
      final images = snapshot.wordImages!;
      expect(images.first.offsetUtf16, 3);
      expect(images.first.canMove, isTrue);
      expect(images.first.canDelete, isTrue);
      expect(images[1].offsetUtf16, isNull);
      for (final image in images.skip(1)) {
        expect(image.canMove, isFalse, reason: image.id);
        expect(image.canDelete, isFalse, reason: image.id);
        expect(
          image.image!.canReplace,
          isTrue,
          reason: 'replace remains an independent existing capability',
        );
      }
      (rows.first as Map)['canMove'] = false;
      rows.clear();
      expect(images.first.canMove, isTrue);
      expect(images, hasLength(5));
      expect(() => images.clear(), throwsUnsupportedError);
    },
  );

  test('Word add stages the referenced bounded asset with source hash and no caller path', () async {
    final directory = await Directory.systemTemp.createTemp('word-image-dto-');
    addTearDown(() => directory.delete(recursive: true));
    final original = await File('${directory.path}/edited.docx')
        .writeAsBytes([1, 2, 3]);
    final pdf = await File('${directory.path}/preview.pdf')
        .writeAsBytes([4, 5]);
    final hash = sha256.convert(await original.readAsBytes()).toString();
    final pdfHash = sha256.convert(await pdf.readAsBytes()).toString();
    final asset = WindowsOfficeImageAsset.fromBytes(
      im.encodePng(im.Image(width: 3, height: 2)),
    );
    Map<String, Object?>? observed;
    final engine = WindowsOfficeEngine(
      runner: (request) async {
        observed = Map<String, Object?>.from(request);
        return {
          'status': 'saved',
          'sessionId': 'word-photo-session',
          'sourcePath': original.path,
          'pdfPath': pdf.path,
          'sourceSha256': hash,
          'pdfSha256': pdfHash,
          'pdfPageCount': 1,
          'engineVersion': 'fixture',
          'snapshot': {
            ...wordSnapshot(),
            'sourceSha256': hash,
            'wordImages': <Object?>[],
          },
        };
      },
    );
    final result = await engine.apply(
      'input.docx',
      sessionId: 'word-photo-session',
      expectedSourceSha256: 'a' * 64,
      operations: [
        add(),
        move(),
        WindowsOfficeOperation.wordImageDelete(id: 'new-photo'),
      ],
      imageAssets: {assetId: asset},
    );
    expect(result.sourceSha256, hash);
    expect(observed!['expectedSourceSha256'], 'a' * 64);
    expect(observed!['imageAssets'], [
      {
        'id': assetId,
        'fileName': 'assets/$assetId.png',
        'mimeType': 'image/png',
        'byteLength': asset.byteLength,
        'sha256': asset.sha256,
        'width': 3,
        'height': 2,
      },
    ]);
    expect(observed!.containsKey('assetDirectory'), isFalse);
    final serialized = (observed!['operations'] as List).cast<Map>();
    expect(serialized.map((operation) => operation['op']), [
      'wordImageAdd',
      'wordImageMove',
      'wordImageDelete',
    ]);
    expect(serialized[1].containsKey('assetId'), isFalse);
    expect(serialized[2].containsKey('assetId'), isFalse);
  });

  test(
    'Word missing unused and path-shaped assets never reach a worker',
    () async {
      final asset = WindowsOfficeImageAsset.fromBytes(
        im.encodePng(im.Image(width: 2, height: 2)),
      );
      var called = false;
      final engine = WindowsOfficeEngine(
        runner: (_) async {
          called = true;
          throw StateError('Unexpected worker call');
        },
      );
      for (final entry
          in <
            (List<WindowsOfficeOperation>, Map<String, WindowsOfficeImageAsset>)
          >[
            ([add()], {}),
            ([move()], {assetId: asset}),
            (
              [WindowsOfficeOperation.wordImageDelete(id: 'new-photo')],
              {assetId: asset},
            ),
            ([add(asset: '../outside')], {'../outside': asset}),
          ]) {
        await expectLater(
          engine.apply(
            'input.docx',
            sessionId: 'reject',
            operations: entry.$1,
            imageAssets: entry.$2,
          ),
          throwsFormatException,
        );
      }
      expect(called, isFalse);
    },
  );

  test('PPT imageAdd keeps its existing slide coordinates and replacement contract', () {
    expect(
      WindowsOfficeOperation.imageAdd(
        id: 'new-slide-photo',
        slideId: 'slide-0',
        assetId: assetId,
        x: 10,
        y: 20,
        width: 30,
        height: 40,
      ).toJson(),
      {
        'op': 'imageAdd',
        'id': 'new-slide-photo',
        'slideId': 'slide-0',
        'assetId': assetId,
        'x': 10.0,
        'y': 20.0,
        'width': 30.0,
        'height': 40.0,
      },
    );
    expect(
      WindowsOfficeOperation.imageReplace(
        id: 'existing-photo',
        assetId: assetId,
      ).toJson(),
      {'op': 'imageReplace', 'id': 'existing-photo', 'assetId': assetId},
    );
  });
}
