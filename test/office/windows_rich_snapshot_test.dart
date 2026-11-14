import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/office/windows_office_engine.dart';

Map<String, Object?> _details(String text) => {
  'utf16Length': text.length,
  'textSha256': sha256.convert(utf8.encode(text)).toString(),
  'canReplace': true,
  'canStyle': true,
  'truncated': false,
  'runs': [
    {'startUtf16': 0, 'endUtf16': 1, 'bold': false, 'fontFamily': 'Original'},
    {
      'startUtf16': 1,
      'endUtf16': 3,
      'bold': true,
      'italic': true,
      'underline': false,
      'fontSize': 24,
      'color': 0x123456,
      'fontFamily': 'Emoji font',
    },
  ],
  'protectedRanges': [
    {'startUtf16': 6, 'endUtf16': 7, 'type': 'TextField'},
    {'startUtf16': 7, 'endUtf16': 7, 'type': 'Frame'},
  ],
};

void main() {
  test('reading mixed text keeps UTF16 runs and zero-width protected objects', () {
    const text = 'A😀éB1';
    final snapshot = WindowsOfficeSnapshot.fromJson({
      'kind': 'word',
      'sourceSha256': 'a' * 64,
      'paragraphs': [
        {'id': 'paragraph-0', 'text': text, 'textDetails': _details(text)},
      ],
      'tables': [
        {
          'id': 'Table1',
          'cells': {'A1': text},
          'cellTextDetails': {'A1': _details(text)},
        },
      ],
      'slides': [],
    });
    final dynamic paragraph = snapshot.paragraphs.single;
    final dynamic details = paragraph.textDetails;
    expect(details.utf16Length, 7);
    expect(details.textSha256, sha256.convert(utf8.encode(text)).toString());
    expect(details.canReplace, isTrue);
    expect(details.canStyle, isTrue);
    expect(details.truncated, isFalse);
    expect(details.runs[1].startUtf16, 1);
    expect(details.runs[1].endUtf16, 3);
    expect(details.runs[1].italic, isTrue);
    expect(details.runs[1].fontFamily, 'Emoji font');
    expect(details.protectedRanges[1].startUtf16, 7);
    expect(details.protectedRanges[1].endUtf16, 7);
    final dynamic table = snapshot.tables.single;
    expect(table.cellTextDetails['A1'].textSha256, details.textSha256);
  });

  test('older snapshots never claim selected text is safe to replace', () {
    final snapshot = WindowsOfficeSnapshot.fromJson({
      'kind': 'word',
      'sourceSha256': 'a' * 64,
      'paragraphs': [
        {'id': 'paragraph-0', 'text': 'old'},
      ],
      'tables': [
        {'id': 'Table1', 'cells': {'A1': 'cell'}},
      ],
      'slides': [],
    });
    final dynamic paragraph = snapshot.paragraphs.single;
    final dynamic table = snapshot.tables.single;
    expect(paragraph.textDetails, isNull);
    expect(table.cellTextDetails, isEmpty);
  });

  test('a native image keeps bounded preview bytes and original MIME identity', () {
    final bytes = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Zl1sAAAAASUVORK5CYII=',
    );
    final snapshot = WindowsOfficeSnapshot.fromJson({
      'kind': 'presentation',
      'sourceSha256': 'a' * 64,
      'paragraphs': [],
      'tables': [],
      'slides': [
        {
          'id': 'slide-0', 'width': 254, 'height': 143,
          'shapes': [
            {
              'id': 'slide-0/shape-0',
              'type': 'com.sun.star.drawing.GraphicObjectShape',
              'shapeKind': 'image', 'text': '', 'editableText': false,
              'x': 10, 'y': 20, 'width': 30, 'height': 40,
              'image': {
                'mimeType': 'image/jpeg', 'pixelWidth': 4032, 'pixelHeight': 3024,
                'canReplace': true, 'thumbnailMimeType': 'image/png',
                'thumbnailBase64': base64Encode(bytes),
                'thumbnailSha256': sha256.convert(bytes).toString(),
                'thumbnailTruncated': false,
              },
            },
          ],
        },
      ],
    });
    final dynamic shape = snapshot.slides.single.shapes.single;
    expect(shape.image.mimeType, 'image/jpeg');
    expect(shape.image.pixelWidth, 4032);
    expect(shape.image.pixelHeight, 3024);
    expect(shape.image.canReplace, isTrue);
    expect(shape.image.thumbnailBytes, orderedEquals(bytes));
  });
}
