import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:image/image.dart' as im;

final class WindowsOfficeImageAsset {
  factory fromBytes(List<int> bytes) {
    if (bytes.isEmpty || bytes.length > maxBytes) {
      throw const FormatException('Office photos must be at most 20 MiB');
    }
    final payload = Uint8List.fromList(bytes);
    final png =
        payload.length >= 8 &&
        payload[0] == 137 &&
        payload[1] == 80 &&
        payload[2] == 78 &&
        payload[3] == 71 &&
        payload[4] == 13 &&
        payload[5] == 10 &&
        payload[6] == 26 &&
        payload[7] == 10;
    final jpeg =
        payload.length >= 3 &&
        payload[0] == 255 &&
        payload[1] == 216 &&
        payload[2] == 255;
    if (!png && !jpeg) {
      throw const FormatException('Office photos must be PNG or JPEG');
    }
    if (png) {
      var offset = 8;
      while (offset + 12 <= payload.length) {
        final chunkLength = ByteData.sublistView(
          payload,
          offset,
          offset + 4,
        ).getUint32(0, Endian.big);
        if (chunkLength > payload.length - offset - 12) break;
        final type = payload.sublist(offset + 4, offset + 8);
        if (type[0] == 97 && type[1] == 99 && type[2] == 84 && type[3] == 76) {
          throw const FormatException('Animated PNG photos are not supported');
        }
        if (type[0] == 73 && type[1] == 69 && type[2] == 78 && type[3] == 68)
          break;
        offset += chunkLength + 12;
      }
    }
    try {
      final decoder = png ? im.PngDecoder() : im.JpegDecoder();
      final information = decoder.startDecode(payload);
      if (information == null ||
          information.width < 1 ||
          information.height < 1 ||
          information.width > maxPixels ~/ information.height ||
          decoder.decodeFrame(0) == null) {
        throw const FormatException('Invalid or oversized Office photo');
      }
      return WindowsOfficeImageAsset._(
        payload,
        png ? 'image/png' : 'image/jpeg',
        information.width,
        information.height,
        crypto.sha256.convert(payload).toString(),
      );
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('Invalid Office photo');
    }
  }

  const new _(this._bytes, this.mimeType, this.width, this.height, this.sha256);

  static const maxBytes = 20 * 1024 * 1024;
  static const maxPixels = 40 * 1000 * 1000;
  static const maxBatchBytes = 80 * 1024 * 1024;
  final Uint8List _bytes;
  Uint8List get bytes => Uint8List.fromList(_bytes);
  int get byteLength => _bytes.length;
  final String mimeType;
  final int width;
  final int height;
  final String sha256;
}
