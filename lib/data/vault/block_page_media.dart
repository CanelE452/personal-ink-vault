import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:saber/data/office/office_image_asset.dart';

final class BlockPageMedia {
  new _(this._raw);

  factory fromJson(Map<String, dynamic> json) {
    final raw = _copyMediaJson(json);
    final path = raw['path'];
    final name = raw['name'];
    final mimeType = raw['mimeType'];
    final byteLength = raw['byteLength'];
    final sha256 = raw['sha256'];
    final width = raw['width'];
    final height = raw['height'];
    final match = path is String ? _mediaPath.firstMatch(path) : null;
    if (path is! String ||
        match == null ||
        match.end != path.length ||
        sha256 is! String ||
        sha256.length != 64 ||
        match.group(1) != sha256 ||
        name is! String ||
        !_validName(name) ||
        mimeType is! String ||
        !_validMime(mimeType) ||
        byteLength is! int ||
        byteLength < 1 ||
        byteLength > BlockPageMediaAsset.maxAttachmentBytes) {
      throw const FormatException('Invalid page media descriptor');
    }
    final image = imageMimeTypes.contains(mimeType);
    if (image) {
      if (width is! int ||
          height is! int ||
          width < 1 ||
          height < 1 ||
          width > WindowsOfficeImageAsset.maxPixels ~/ height ||
          byteLength > WindowsOfficeImageAsset.maxBytes) {
        throw const FormatException('Invalid page image dimensions or size');
      }
    } else if (width != null || height != null) {
      throw const FormatException('Only supported page images have dimensions');
    }
    return BlockPageMedia._(raw);
  }

  static const imageMimeTypes = {'image/png', 'image/jpeg'};
  static final _mediaPath = RegExp(r'^media/([0-9a-f]{64})\.([a-z0-9]{1,12})$');
  final Map<String, dynamic> _raw;

  String get path => _raw['path'] as String;
  String get name => _raw['name'] as String;
  String get mimeType => _raw['mimeType'] as String;
  int get byteLength => _raw['byteLength'] as int;
  String get sha256 => _raw['sha256'] as String;
  int? get width => _raw['width'] as int?;
  int? get height => _raw['height'] as int?;
  bool get isImage => imageMimeTypes.contains(mimeType);

  Map<String, dynamic> toJson() => _copyMediaJson(_raw);

  void verifyBytes(List<int> bytes) {
    if (bytes.length != byteLength ||
        crypto.sha256.convert(bytes).toString() != sha256) {
      throw const FormatException(
        'Page media bytes do not match their descriptor',
      );
    }
    if (isImage) {
      final decoded = WindowsOfficeImageAsset.fromBytes(bytes);
      if (decoded.mimeType != mimeType ||
          decoded.width != width ||
          decoded.height != height) {
        throw const FormatException(
          'Page image metadata does not match its bytes',
        );
      }
    }
  }
}

final class BlockPageMediaAsset {
  new _(this.reference, this._bytes);

  factory image({required String name, required List<int> bytes}) {
    if (!_validName(name)) {
      throw const FormatException('Invalid page media name');
    }
    _validateInputBytes(bytes, WindowsOfficeImageAsset.maxBytes);
    final image = WindowsOfficeImageAsset.fromBytes(bytes);
    final extension = image.mimeType == 'image/png' ? 'png' : 'jpg';
    return BlockPageMediaAsset._(
      BlockPageMedia.fromJson({
        'path': 'media/${image.sha256}.$extension',
        'name': name,
        'mimeType': image.mimeType,
        'byteLength': image.byteLength,
        'sha256': image.sha256,
        'width': image.width,
        'height': image.height,
      }),
      image.bytes,
    );
  }

  factory attachment({
    required String name,
    required List<int> bytes,
    String mimeType = 'application/octet-stream',
  }) {
    if (!_validName(name) || !_validMime(mimeType)) {
      throw const FormatException('Invalid page attachment name or media type');
    }
    _validateInputBytes(bytes, maxAttachmentBytes);
    final payload = Uint8List.fromList(bytes);
    final hash = crypto.sha256.convert(payload).toString();
    final extensionMatch = RegExp(r'\.([A-Za-z0-9]{1,12})$').firstMatch(name);
    final extension = extensionMatch?.group(1)?.toLowerCase() ?? 'bin';
    final image = BlockPageMedia.imageMimeTypes.contains(mimeType)
        ? WindowsOfficeImageAsset.fromBytes(payload)
        : null;
    if (image != null && image.mimeType != mimeType) {
      throw const FormatException(
        'Attachment image type does not match its bytes',
      );
    }
    return BlockPageMediaAsset._(
      BlockPageMedia.fromJson({
        'path': 'media/$hash.$extension',
        'name': name,
        'mimeType': mimeType,
        'byteLength': payload.length,
        'sha256': hash,
        if (image != null) 'width': image.width,
        if (image != null) 'height': image.height,
      }),
      payload,
    );
  }

  static const maxAttachmentBytes = 64 * 1024 * 1024;
  final BlockPageMedia reference;
  final Uint8List _bytes;
  Uint8List get bytes => Uint8List.fromList(_bytes);
}

void _validateInputBytes(List<int> bytes, int maximum) {
  if (bytes.isEmpty || bytes.length > maximum) {
    throw const FormatException(
      'Page media file size is outside the allowed range',
    );
  }
  if (bytes.any((value) => value < 0 || value > 255)) {
    throw const FormatException('Expected page media bytes');
  }
}

bool _validName(String value) =>
    value.trim().isNotEmpty &&
    value.length <= 4096 &&
    !value.contains(RegExp(r'[\x00-\x1f\x7f]'));

bool _validMime(String value) {
  final match = RegExp(r'^[a-z0-9!#$&^_.+-]+/[a-z0-9!#$&^_.+-]+$')
      .firstMatch(value);
  return value.length <= 255 && match != null && match.end == value.length;
}

Map<String, dynamic> _copyMediaJson(Map<String, dynamic> value) {
  try {
    final copy = jsonDecode(jsonEncode(value));
    if (copy is! Map<String, dynamic>) {
      throw const FormatException('Expected page media JSON');
    }
    return copy;
  } catch (_) {
    throw const FormatException('Expected page media JSON');
  }
}
