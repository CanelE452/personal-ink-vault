import 'dart:typed_data';

import 'package:archive/archive.dart' as archive;
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as im;
import 'package:saber/data/office/office_image_asset.dart';

Uint8List _chunk(String kind, List<int> data) {
  final result = Uint8List(data.length + 12);
  final words = ByteData.sublistView(result);
  words.setUint32(0, data.length, Endian.big);
  result.setRange(4, 8, kind.codeUnits);
  result.setRange(8, data.length + 8, data);
  words.setUint32(
    data.length + 8,
    archive.getCrc32(Uint8List.sublistView(result, 4, data.length + 8)),
    Endian.big,
  );
  return result;
}

Uint8List _rgbaHeaderPng(int width, int height) {
  final header = ByteData(13)
    ..setUint32(0, width, Endian.big)
    ..setUint32(4, height, Endian.big)
    ..setUint8(8, 8)
    ..setUint8(9, 6);
  return (BytesBuilder(copy: false)
        ..add([137, 80, 78, 71, 13, 10, 26, 10])
        ..add(_chunk('IHDR', header.buffer.asUint8List()))
        ..add(_chunk('IDAT', const archive.ZLibEncoder().encode([0, 0, 0, 0, 0])))
        ..add(_chunk('IEND', [])))
      .takeBytes();
}

Uint8List _oneFrameApng() {
  final original = im.encodePng(im.Image(width: 2, height: 2));
  final animation = ByteData(8)..setUint32(0, 1, Endian.big);
  final frame = ByteData(26)
    ..setUint32(4, 2, Endian.big)
    ..setUint32(8, 2, Endian.big)
    ..setUint16(20, 1, Endian.big)
    ..setUint16(22, 10, Endian.big);
  return Uint8List.fromList([
    ...original.sublist(0, 33),
    ..._chunk('acTL', animation.buffer.asUint8List()),
    ..._chunk('fcTL', frame.buffer.asUint8List()),
    ...original.sublist(33),
  ]);
}

void main() {
  test(
    'PNG and JPEG assets keep real dimensions and immutable payload identity',
    () {
      final image = im.Image(width: 3, height: 2);
      image.setPixelRgba(0, 0, 220, 40, 60, 255);
      for (final pair in <(Uint8List, String)>[
        (im.encodePng(image), 'image/png'),
        (im.encodeJpg(image), 'image/jpeg'),
      ]) {
        final original = Uint8List.fromList(pair.$1);
        final asset = WindowsOfficeImageAsset.fromBytes(pair.$1);
        expect(asset.mimeType, pair.$2);
        expect((asset.width, asset.height), (3, 2));
        expect(asset.sha256, sha256.convert(original).toString());
        pair.$1[0] = 0;
        final returned = asset.bytes;
        returned[0] = 0;
        expect(asset.bytes, orderedEquals(original));
      }
    },
  );

  test(
    'other formats corrupt photos and oversized byte payloads are rejected',
    () {
      final image = im.Image(width: 2, height: 2);
      for (final bytes in <List<int>>[
        [],
        [1, 2, 3],
        im.encodeGif(image),
        [0xff, 0xd8, 0xff, 0xd9],
        Uint8List(20 * 1024 * 1024 + 1),
      ]) {
        expect(
          () => WindowsOfficeImageAsset.fromBytes(bytes),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'an extreme image header is refused before allocating decoded pixels',
    () {
      final bytes = _rgbaHeaderPng(400000, 400000);
      expect(
        () => WindowsOfficeImageAsset.fromBytes(bytes),
        throwsFormatException,
      );
    },
  );

  test('valid-CRC Uint32 PNG dimensions cannot overflow the pixel guard', () {
    for (final dimensions in <(int, int)>[
      (0x80000001, 0xffffffff),
      (0xffffffff, 0x80000001),
      (0xffffffff, 0xffffffff),
      (40000001, 1),
      (8000, 5001),
    ]) {
      final bytes = _rgbaHeaderPng(dimensions.$1, dimensions.$2);
      final information = im.PngDecoder().startDecode(bytes)!;
      expect((information.width, information.height), dimensions);
      expect(
        () => WindowsOfficeImageAsset.fromBytes(bytes),
        throwsFormatException,
      );
    }
  });

  test('a valid PNG at exactly 20 MiB remains accepted', () {
    final original = im.encodePng(im.Image(width: 2, height: 2));
    final padding = _chunk(
      'npAD',
      Uint8List(20 * 1024 * 1024 - original.length - 12),
    );
    final bytes =
        (BytesBuilder(copy: false)
              ..add(original.sublist(0, original.length - 12))
              ..add(padding)
              ..add(original.sublist(original.length - 12)))
            .takeBytes();
    expect(bytes.length, 20 * 1024 * 1024);
    final asset = WindowsOfficeImageAsset.fromBytes(bytes);
    expect(asset.byteLength, 20 * 1024 * 1024);
    expect((asset.width, asset.height), (2, 2));
  });

  test(
    'animated PNG is rejected instead of staging its first frame as a photo',
    () {
      final first = im.Image(width: 2, height: 2)..setPixelRgb(0, 0, 255, 0, 0);
      first.addFrame(
        im.Image(width: 2, height: 2)..setPixelRgb(0, 0, 0, 0, 255),
      );
      final bytes = im.encodePng(first);
      final decoder = im.PngDecoder();
      expect(decoder.startDecode(bytes)!.numFrames, 2);
      expect(decoder.decodeFrame(0), isNotNull);
      expect(
        () => WindowsOfficeImageAsset.fromBytes(bytes),
        throwsFormatException,
      );
    },
  );

  test(
    'one-frame APNG control is rejected while a static PNG remains a photo',
    () {
      final bytes = _oneFrameApng();
      final decoder = im.PngDecoder();
      expect(decoder.startDecode(bytes)!.numFrames, 1);
      expect(decoder.info.isAnimated, isTrue);
      expect(decoder.decodeFrame(0), isNotNull);
      expect(
        () => WindowsOfficeImageAsset.fromBytes(bytes),
        throwsFormatException,
      );
      final still = WindowsOfficeImageAsset.fromBytes(
        im.encodePng(im.Image(width: 2, height: 2)),
      );
      expect((still.mimeType, still.width, still.height), ('image/png', 2, 2));
    },
  );
}
