import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as image;
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/native/ink_vault_native.dart';
import 'package:saber/data/vault/card_canvas_document.dart';
import 'package:saber/data/vault/obsidian_canvas_export_source.dart';

final class CardCanvasRaster {
  new({required Uint8List bytes, required this.width, required this.height})
    : bytes = bytes.asUnmodifiableView();

  final Uint8List bytes;
  final int width, height;
}

final class CardCanvasRasterReader {
  new(this._repository, {required this._native, required this._isCurrent});

  static const _maxBytes = 8 * 1024 * 1024;
  static const _maxDimension = 8192;
  static const _maxPixels = 24000000;
  final NoteRepository _repository;
  final InkVaultNative _native;
  final bool Function() _isCurrent;
  Future<ObsidianCanvasExportReader>? _capture;
  final _inFlight = <String, Future<CardCanvasRaster?>>{};

  Future<CardCanvasRaster?> read(CardCanvasNode node) async {
    final path = node.backgroundPath;
    final linkedId = node.subpath == null ? node.linkedNoteId : null;
    if (!_isCurrent() || (path == null && linkedId == null)) return null;
    try {
      final catalog = await (_capture ??= ObsidianCanvasExportReader.capture(
        _repository,
        native: _native,
      ));
      if (!_isCurrent()) return null;
      final id = path == null ? linkedId : catalog.resolveImage(path);
      if (id == null) return null;
      final pending = _inFlight.putIfAbsent(id, () async {
        try {
          final file = await catalog.readImage(id, maxBytes: _maxBytes);
          if (!_isCurrent() || file == null) return null;
          final decoder = switch (p
              .extension(file.preferredPath)
              .toLowerCase()) {
            '.png' => image.PngDecoder(),
            '.jpg' || '.jpeg' => image.JpegDecoder(),
            '.webp' => image.WebPDecoder(),
            _ => null,
          };
          final size = decoder?.startDecode(file.bytes);
          if (size == null ||
              size.width < 1 ||
              size.height < 1 ||
              size.width > _maxDimension ||
              size.height > _maxDimension ||
              size.width > _maxPixels ~/ size.height) {
            return null;
          }
          return CardCanvasRaster(
            bytes: file.bytes,
            width: size.width,
            height: size.height,
          );
        } finally {
          _inFlight.remove(id);
        }
      });
      final raster = await pending;
      if (raster == null || !_isCurrent()) return null;
      await catalog.ensureCurrent();
      return _isCurrent() ? raster : null;
    } on FormatException {
      return null;
    } on FileSystemException {
      return null;
    } on InkVaultNativeException {
      return null;
    } on image.ImageException {
      return null;
    } on RangeError {
      return null;
    } on StateError {
      return null;
    }
  }
}
