import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as im;

Future<(Uint8List, int, int)> renderBlockPageMediaPreview(
  Uint8List bytes,
  int maxDimension,
) => compute(_render, (bytes, maxDimension), debugLabel: 'page media preview');

(Uint8List, int, int) _render((Uint8List, int) request) {
  final decoded = im.decodeImage(request.$1);
  if (decoded == null) throw const FormatException('Invalid page image');
  final oriented = im.bakeOrientation(decoded);
  var dimension = math.min(
    request.$2,
    math.max(oriented.width, oriented.height),
  );
  while (true) {
    final scale = dimension / math.max(oriented.width, oriented.height);
    final resized = im.copyResize(
      oriented,
      width: math.max(1, (oriented.width * scale).round()),
      height: math.max(1, (oriented.height * scale).round()),
    );
    final rgba = resized.getBytes(order: im.ChannelOrder.rgba);
    final clean = im.Image.fromBytes(
      width: resized.width,
      height: resized.height,
      bytes: rgba.buffer,
      bytesOffset: rgba.offsetInBytes,
      numChannels: 4,
      order: im.ChannelOrder.rgba,
    );
    final png = Uint8List.fromList(im.encodePng(clean));
    if (png.length <= 1024 * 1024) return (png, clean.width, clean.height);
    if (dimension <= 64)
      throw const FormatException('Page image preview is too large');
    dimension = math.max(64, dimension ~/ 2);
  }
}
