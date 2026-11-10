import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/vault/block_page_document.dart';
import 'package:saber/data/vault/block_page_media.dart';

final class BlockPageMediaSnapshot {
  new _(this.document, this._files);

  factory fromFiles(Map<String, Uint8List> files) {
    _validateFiles(files);
    final document = _readDocument(files);
    _validateMedia(document, files);
    return BlockPageMediaSnapshot._(document, _copyFiles(files));
  }

  factory prepare(
    BlockPageDocument document, {
    Map<String, Uint8List> existingFiles = const {},
    Map<String, Uint8List> addedFiles = const {},
  }) {
    _validateFiles(existingFiles);
    if (existingFiles.isNotEmpty) {
      final previous = _readDocument(existingFiles);
      if (previous.version > document.version) {
        throw const FormatException(
          'A page cannot be downgraded by an ordinary save',
        );
      }
      if (previous.version == 1 &&
          document.version >= 2 &&
          previous.toJson().containsKey('blockMedia')) {
        throw const FormatException(
          'The old page has opaque data in the reserved media registry',
        );
      }
    }
    final allowed = document.media.values.map((media) => media.path).toSet();
    final combined = <String, Uint8List>{...existingFiles};
    for (final entry in addedFiles.entries) {
      if (!allowed.contains(entry.key)) {
        throw const FormatException(
          'Added media must be referenced by this page',
        );
      }
      final existing = combined[entry.key];
      if (existing != null && !_sameBytes(existing, entry.value)) {
        throw const FormatException(
          'Existing page media cannot be replaced with different bytes',
        );
      }
      combined[entry.key] = entry.value;
    }
    combined['page.json'] = Uint8List.fromList(
      utf8.encode(jsonEncode(document.toJson())),
    );
    _validateFiles(combined);
    _validateMedia(document, combined);
    return BlockPageMediaSnapshot._(document, _copyFiles(combined));
  }

  static const maxSnapshotBytes = 128 * 1024 * 1024;
  final BlockPageDocument document;
  final Map<String, Uint8List> _files;

  Map<String, Uint8List> get files => _copyFiles(_files);

  Uint8List mediaBytes(String blockId) {
    validateId(blockId);
    final reference = document.media[blockId];
    if (reference == null) {
      throw const FormatException('This block has no registered media');
    }
    final bytes = _files[reference.path];
    if (bytes == null) {
      throw const FormatException('Page media file is missing');
    }
    return Uint8List.fromList(bytes);
  }
}

BlockPageDocument _readDocument(Map<String, Uint8List> files) {
  final bytes = files['page.json'];
  if (bytes == null) {
    throw const FormatException('Page snapshot has no page.json');
  }
  return BlockPageDocument.fromJson(jsonObject(jsonDecode(utf8.decode(bytes))));
}

void _validateFiles(Map<String, Uint8List> files) {
  var size = 0;
  for (final entry in files.entries) {
    validateLogicalPath(entry.key);
    size += entry.value.length;
    if (size > BlockPageMediaSnapshot.maxSnapshotBytes) {
      throw const FormatException('Page snapshot must be at most 128 MiB');
    }
  }
}

Map<String, Uint8List> _copyFiles(Map<String, Uint8List> files) =>
    Map.unmodifiable({
      for (final entry in files.entries)
        entry.key: Uint8List.fromList(entry.value),
    });

void _validateMedia(BlockPageDocument document, Map<String, Uint8List> files) {
  final references = <String, List<BlockPageMedia>>{};
  for (final media in document.media.values) {
    references.putIfAbsent(media.path, () => []).add(media);
  }
  for (final entry in references.entries) {
    final bytes = files[entry.key];
    if (bytes == null) {
      throw const FormatException('Page media file is missing');
    }
    final hash = crypto.sha256.convert(bytes).toString();
    for (final reference in entry.value) {
      if (reference.byteLength != bytes.length || reference.sha256 != hash) {
        throw const FormatException(
          'Page media bytes do not match their descriptor',
        );
      }
    }
    final images = entry.value.where((reference) => reference.isImage).toList();
    if (images.isNotEmpty) {
      final image = images.first;
      image.verifyBytes(bytes);
      for (final other in images.skip(1)) {
        if (other.mimeType != image.mimeType ||
            other.width != image.width ||
            other.height != image.height) {
          throw const FormatException(
            'Shared page image descriptors are inconsistent',
          );
        }
      }
    }
  }
}

bool _sameBytes(Uint8List first, Uint8List second) {
  if (first.length != second.length) return false;
  for (var index = 0; index < first.length; index++) {
    if (first[index] != second[index]) return false;
  }
  return true;
}
