import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/office/windows_office_engine.dart';

void main() {
  Map<String, dynamic> snapshot() => {
    'kind': 'word',
    'sourceSha256': 'a' * 64,
    'paragraphs': <Object?>[],
    'tables': <Object?>[],
    'slides': <Object?>[],
  };

  test('legacy snapshots distinguish unknown Word images from known none', () {
    final dynamic legacy = WindowsOfficeSnapshot.fromJson(snapshot());
    expect(legacy.wordImages, isNull);
    final dynamic unknown = WindowsOfficeSnapshot.fromJson({
      ...snapshot(),
      'wordImages': null,
    });
    expect(unknown.wordImages, isNull);
    final dynamic empty = WindowsOfficeSnapshot.fromJson({
      ...snapshot(),
      'wordImages': <Object?>[],
    });
    expect(empty.wordImages, isEmpty);
    expect(() => empty.wordImages.clear(), throwsUnsupportedError);
  });

  test(
    'Word image DTO preserves native locators, geometry and graphic hash',
    () {
      final dynamic word = WindowsOfficeSnapshot.fromJson({
        ...snapshot(),
        'wordImages': [
          {
            'id': 'word-image-source-1',
            'ownerId': 'body-1',
            'paragraphId': 'paragraph-7',
            'anchorType': 'AT_PARAGRAPH',
            'width': 25,
            'height': 12.5,
            'nativeGraphicSha256': 'b' * 64,
            'image': {
              'mimeType': 'image/png',
              'pixelWidth': 40,
              'pixelHeight': 20,
              'canReplace': true,
            },
          },
          {
            'id': 'word-image-source-2',
            'ownerId': 'header-1',
            'tableId': 'Table1',
            'cell': 'B2',
            'anchorType': 'AS_CHARACTER',
            'image': {'canReplace': false},
          },
        ],
      });
      final dynamic paragraph = word.wordImages[0];
      expect(paragraph.id, 'word-image-source-1');
      expect(paragraph.ownerId, 'body-1');
      expect(paragraph.paragraphId, 'paragraph-7');
      expect(paragraph.tableId, isNull);
      expect(paragraph.cell, isNull);
      expect(paragraph.anchorType, 'AT_PARAGRAPH');
      expect(paragraph.width, 25.0);
      expect(paragraph.height, 12.5);
      expect(paragraph.nativeGraphicSha256, 'b' * 64);
      expect(paragraph.image.mimeType, 'image/png');
      expect(paragraph.image.pixelWidth, 40);
      expect(paragraph.image.pixelHeight, 20);
      expect(paragraph.image.canReplace, true);
      final dynamic cell = word.wordImages[1];
      expect(cell.ownerId, 'header-1');
      expect(cell.paragraphId, isNull);
      expect(cell.tableId, 'Table1');
      expect(cell.cell, 'B2');
      expect(cell.anchorType, 'AS_CHARACTER');
      expect(cell.width, isNull);
      expect(cell.image.canReplace, false);
    },
  );

  test('Word images require explicit nested replacement capability', () {
    final dynamic word = WindowsOfficeSnapshot.fromJson({
      ...snapshot(),
      'wordImages': [
        {
          'id': 'image-missing-capability',
          'paragraphId': 'p1',
          'canReplace': true,
          'image': {'mimeType': 'image/png'},
        },
        {'id': 'image-unknown-details', 'paragraphId': 'p2'},
      ],
    });
    expect(word.wordImages[0].image.canReplace, false);
    expect(word.wordImages[1].image, isNull);
    expect(
      WindowsOfficeOperation.imageReplace(
        id: 'image-missing-capability',
        assetId: 'sealed-asset',
      ).toJson(),
      {
        'op': 'imageReplace',
        'id': 'image-missing-capability',
        'assetId': 'sealed-asset',
      },
    );
  });
}
