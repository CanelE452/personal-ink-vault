import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/native/ink_vault_native.dart';
import 'package:saber/data/office/pptx_photo_replacement.dart';

final class DocxPhotoTarget {
  const new({
    required this.index,
    required this.mediaPart,
    required this.mediaSha256,
    required this.format,
    this.title,
  });

  final int index;
  final String mediaPart;
  final String mediaSha256;
  final String format;
  final String? title;
}

final class DocxPhotoPlan {
  new({required this.sourceSha256, required List<DocxPhotoTarget> photos})
    : photos = List.unmodifiable(photos);

  final String sourceSha256;
  final List<DocxPhotoTarget> photos;
}

Uint8List? readDocxPhotoPreview(Uint8List source, DocxPhotoTarget target) =>
    readOfficePhotoPreview(
      source,
      target.mediaPart,
      target.mediaSha256,
      mimeType: target.format == 'png' ? 'image/png' : 'image/jpeg',
    );

class DocxPhotoReplacementEngine {
  const new({this._libraryPath});

  final String? _libraryPath;
  static final _hash = RegExp(r'^[0-9a-f]{64}$');
  static final _part = RegExp(r'^[A-Za-z0-9_.\[\]/-]+$');
  static const _maxBytes = 128 * 1024 * 1024;
  static const _invalidReply = InkVaultNativeException(
    'invalid_response',
    'DOCX 사진 편집 결과를 확인하지 못했습니다.',
  );

  Future<DocxPhotoPlan> inspect({
    required String sourcePath,
    required String sourceSha256,
  }) async {
    _requirePath(sourcePath);
    _requireHash(sourceSha256);
    final reply = await _invoke({
      'op': 'docx_photo_inspect',
      'sourcePath': sourcePath,
      'sourceSha256': sourceSha256,
    });
    final rows = reply['photos'];
    if (reply.length != 2 ||
        reply['sourceSha256'] != sourceSha256 ||
        rows is! List ||
        rows.length > 2048) {
      throw _invalidReply;
    }
    final photos = <DocxPhotoTarget>[];
    for (final row in rows) {
      if (row is! Map<String, Object?> ||
          !row.keys.every(
            const {
              'index',
              'title',
              'mediaPart',
              'mediaSha256',
              'format',
            }.contains,
          )) {
        throw _invalidReply;
      }
      final index = row['index'];
      final part = row['mediaPart'];
      final mediaSha = row['mediaSha256'];
      final format = row['format'];
      final title = row['title'];
      if (index is! int ||
          index != photos.length ||
          part is! String ||
          !_part.hasMatch(part) ||
          part.split('/').any((segment) => ['', '.', '..'].contains(segment)) ||
          mediaSha is! String ||
          !_hash.hasMatch(mediaSha) ||
          format is! String ||
          !const {'png', 'jpeg'}.contains(format) ||
          (title != null && (title is! String || title.length > 512))) {
        throw _invalidReply;
      }
      photos.add(
        DocxPhotoTarget(
          index: index,
          mediaPart: part,
          mediaSha256: mediaSha,
          format: format,
          title: title as String?,
        ),
      );
    }
    return DocxPhotoPlan(sourceSha256: sourceSha256, photos: photos);
  }

  Future<String> replace({
    required String sourcePath,
    required DocxPhotoPlan plan,
    required int photoIndex,
    required String outputPath,
    required String assetPath,
    required String assetSha256,
  }) async {
    final target = _requireDraft(sourcePath, outputPath, plan, photoIndex);
    _requirePath(assetPath, docx: false);
    _requireHash(assetSha256);
    if (p.equals(sourcePath, assetPath) ||
        p.equals(outputPath, assetPath) ||
        !p.equals(p.dirname(sourcePath), p.dirname(assetPath))) {
      throw ArgumentError('Expected separate files in one DOCX working folder');
    }
    if (target.mediaSha256 == assetSha256) {
      throw ArgumentError('Expected a replacement for a photo in this DOCX');
    }
    final reply = await _invoke({
      'op': 'docx_photo_replace',
      'sourcePath': sourcePath,
      'sourceSha256': plan.sourceSha256,
      'outputPath': outputPath,
      'photoIndex': photoIndex,
      'assetPath': assetPath,
      'assetSha256': assetSha256,
    });
    if (reply.length != 4 ||
        reply['sourceSha256'] != plan.sourceSha256 ||
        reply['photoIndex'] is! int ||
        reply['photoIndex'] != photoIndex ||
        reply['mediaSha256'] != assetSha256) {
      throw _invalidReply;
    }
    return _verifyOutput(outputPath, plan.sourceSha256, reply['outputSha256']);
  }

  Future<String> remove({
    required String sourcePath,
    required DocxPhotoPlan plan,
    required int photoIndex,
    required String outputPath,
  }) async {
    final target = _requireDraft(sourcePath, outputPath, plan, photoIndex);
    final reply = await _invoke({
      'op': 'docx_photo_delete',
      'sourcePath': sourcePath,
      'sourceSha256': plan.sourceSha256,
      'outputPath': outputPath,
      'photoIndex': photoIndex,
    });
    if (reply.length != 5 ||
        reply['sourceSha256'] != plan.sourceSha256 ||
        reply['photoIndex'] is! int ||
        reply['photoIndex'] != photoIndex ||
        reply['mediaSha256'] != target.mediaSha256 ||
        reply['remainingPhotoCount'] is! int ||
        reply['remainingPhotoCount'] != plan.photos.length - 1) {
      throw _invalidReply;
    }
    return _verifyOutput(outputPath, plan.sourceSha256, reply['outputSha256']);
  }

  Future<String> rotate({
    required String sourcePath,
    required DocxPhotoPlan plan,
    required int photoIndex,
    required String outputPath,
  }) async {
    final target = _requireDraft(sourcePath, outputPath, plan, photoIndex);
    final reply = await _invoke({
      'op': 'docx_photo_rotate',
      'sourcePath': sourcePath,
      'sourceSha256': plan.sourceSha256,
      'outputPath': outputPath,
      'photoIndex': photoIndex,
    });
    if (reply.length != 4 ||
        reply['sourceSha256'] != plan.sourceSha256 ||
        reply['photoIndex'] is! int ||
        reply['photoIndex'] != photoIndex ||
        reply['mediaSha256'] != target.mediaSha256) {
      throw _invalidReply;
    }
    return _verifyOutput(outputPath, plan.sourceSha256, reply['outputSha256']);
  }

  static DocxPhotoTarget _requireDraft(
    String sourcePath,
    String outputPath,
    DocxPhotoPlan plan,
    int photoIndex,
  ) {
    _requirePath(sourcePath);
    _requirePath(outputPath);
    _requireHash(plan.sourceSha256);
    if (p.equals(sourcePath, outputPath) ||
        !p.equals(p.dirname(sourcePath), p.dirname(outputPath))) {
      throw ArgumentError('Expected separate files in one DOCX working folder');
    }
    if (photoIndex < 0 ||
        photoIndex >= plan.photos.length ||
        plan.photos[photoIndex].index != photoIndex) {
      throw ArgumentError('Expected a selected photo in this DOCX');
    }
    return plan.photos[photoIndex];
  }

  static Future<String> _verifyOutput(
    String outputPath,
    String sourceSha,
    Object? outputSha,
  ) async {
    if (outputSha is! String ||
        outputSha == sourceSha ||
        !_hash.hasMatch(outputSha) ||
        FileSystemEntity.typeSync(outputPath, followLinks: false) !=
            FileSystemEntityType.file) {
      throw _invalidReply;
    }
    final file = File(outputPath);
    final length = await file.length();
    if (length <= 0 ||
        length > _maxBytes ||
        (await sha256.bind(file.openRead()).first).toString() != outputSha) {
      throw _invalidReply;
    }
    return outputSha;
  }

  Future<Map<String, dynamic>> _invoke(Map<String, Object?> request) async {
    final library = _libraryPath;
    try {
      return await Isolate.run(
        () => InkVaultNative.open(libraryPath: library).invoke(request),
      );
    } on InkVaultNativeException catch (error) {
      switch (error.code) {
        case 'invalid_pptx':
          throw const InkVaultNativeException(
            'invalid_docx',
            '손상되었거나 지원하지 않는 DOCX 문서입니다.',
          );
        case 'file_io':
          throw const InkVaultNativeException(
            'file_io',
            'DOCX 편집에 필요한 파일을 읽거나 쓰지 못했습니다.',
          );
        default:
          rethrow;
      }
    }
  }

  static void _requirePath(String path, {bool docx = true}) {
    if (!p.isAbsolute(path) ||
        p.normalize(path) != path ||
        docx && p.extension(path).toLowerCase() != '.docx') {
      throw ArgumentError('Expected a normalized absolute working path');
    }
  }

  static void _requireHash(String value) {
    if (!_hash.hasMatch(value))
      throw ArgumentError('Expected a SHA-256 digest');
  }
}
