import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path/path.dart' as p;
import 'package:saber/components/canvas/image/editor_image.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/vault/saber_ink_adapter.dart';
import 'package:saber/data/vault/workspace_store.dart';

class ImageNoteImportException implements Exception {
  const new(this.note, this.cause);
  final VaultNote note;
  final Object cause;

  @override
  String toString() => '원본 이미지는 보존했지만 필기 페이지를 저장하지 못했습니다.';
}

class ImageNoteImporter {
  const new(this.repository);
  final NoteRepository repository;

  Future<VaultNote> import({
    required String title,
    required String fileName,
    required Uint8List bytes,
    String? folderId,
    bool fromObsidian = false,
  }) async {
    if (repository.formatVersion < 2) {
      throw const FormatException('이미지 가져오기는 라이브러리 형식 2가 필요합니다.');
    }
    final extension = _validateSource(fileName, bytes);
    final original = Uint8List.fromList(bytes);
    final size = await _decodeSize(original);
    final workspace = WorkspaceStore(repository);
    final note = await workspace.createWithSource(
      title,
      fileName: fileName,
      bytes: original,
      folderId: folderId,
      documentKind: VaultDocumentKind.image,
      fromObsidian: fromObsidian,
    );
    EditorCoreInfo? core;
    try {
      core = EditorCoreInfo(filePath: '/.image-import/${note.id}')
        ..backgroundPattern = .none
        ..nextImageId = 1;
      core.pages.add(
        EditorPage(
          size: size,
          backgroundImage: PngEditorImage(
            id: 0,
            assetCache: core.assetCache,
            extension: extension,
            imageProvider: MemoryImage(original),
            pageIndex: 0,
            pageSize: size,
            naturalSize: size,
            srcRect: ui.Offset.zero & size,
            dstRect: ui.Offset.zero & size,
            newImage: false,
            invertible: false,
            onMoveImage: null,
            onDeleteImage: null,
            onMiscChange: null,
          ),
        ),
      );
      final files = await SaberInkAdapter.capture(core, 0);
      await (await workspace.open(note)).saveInk(files);
      return note;
    } on Object catch (error) {
      throw ImageNoteImportException(note, error);
    } finally {
      core?.dispose();
    }
  }

  static const _maxBytes = 64 * 1024 * 1024;
  static const _maxPixels = 40000000;

  static String _validateSource(String fileName, Uint8List bytes) {
    validateLogicalPath(fileName);
    if (fileName.contains('/') ||
        RegExp(r'[<>"|?*]').hasMatch(fileName) ||
        fileName.endsWith('.') ||
        fileName.endsWith(' ') ||
        RegExp(
          r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)',
          caseSensitive: false,
        ).hasMatch(fileName)) {
      throw const FormatException('안전한 이미지 파일 이름이 필요합니다.');
    }
    if (bytes.isEmpty || bytes.length > _maxBytes) {
      throw const FormatException('이미지는 64MB 이하여야 합니다.');
    }
    final extension = p.extension(fileName).toLowerCase();
    final png =
        bytes.length >= 24 &&
        bytes[0] == 137 &&
        bytes[1] == 80 &&
        bytes[2] == 78 &&
        bytes[3] == 71 &&
        bytes[4] == 13 &&
        bytes[5] == 10 &&
        bytes[6] == 26 &&
        bytes[7] == 10;
    final jpeg =
        bytes.length >= 4 &&
        bytes[0] == 255 &&
        bytes[1] == 216 &&
        bytes[2] == 255;
    final webp =
        bytes.length >= 16 &&
        bytes[0] == 82 &&
        bytes[1] == 73 &&
        bytes[2] == 70 &&
        bytes[3] == 70 &&
        bytes[8] == 87 &&
        bytes[9] == 69 &&
        bytes[10] == 66 &&
        bytes[11] == 80;
    if (!(png && extension == '.png') &&
        !(jpeg && (extension == '.jpg' || extension == '.jpeg')) &&
        !(webp && extension == '.webp')) {
      throw const FormatException('PNG, JPEG 또는 WebP 이미지가 필요합니다.');
    }
    if (png) {
      final header = ByteData.sublistView(bytes);
      _checkDimensions(header.getUint32(16), header.getUint32(20));
    }
    return extension;
  }

  static void _checkDimensions(int width, int height) {
    if (width <= 0 || height <= 0 || width * height > _maxPixels) {
      throw const FormatException('이미지는 4천만 화소 이하여야 합니다.');
    }
  }

  static Future<ui.Size> _decodeSize(Uint8List bytes) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    try {
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      try {
        _checkDimensions(descriptor.width, descriptor.height);
        final codec = await descriptor.instantiateCodec();
        try {
          final image = (await codec.getNextFrame()).image;
          try {
            _checkDimensions(image.width, image.height);
            return ui.Size(image.width.toDouble(), image.height.toDouble());
          } finally {
            image.dispose();
          }
        } finally {
          codec.dispose();
        }
      } finally {
        descriptor.dispose();
      }
    } on Object catch (error) {
      if (error is FormatException) rethrow;
      throw const FormatException('이미지를 완전히 읽지 못했습니다.');
    } finally {
      buffer.dispose();
    }
  }
}
