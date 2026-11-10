import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/native/ink_vault_native.dart';

final class PptxPhotoAdditionSlide {
  const new({
    required this.index,
    required this.hidden,
    required this.canAdd,
    this.title,
    this.sectionName,
  });

  final int index;
  final bool hidden;
  final bool canAdd;
  final String? title;
  final String? sectionName;
}

final class PptxPhotoAdditionPlan {
  new({
    required this.sourceSha256,
    required List<PptxPhotoAdditionSlide> slides,
  }) : slides = List.unmodifiable(slides);

  final String sourceSha256;
  final List<PptxPhotoAdditionSlide> slides;
  int get slideCount => slides.length;
}

typedef PptxPhotoAdditionOutput = ({
  String sourceSha256,
  String outputSha256,
  int slideCount,
  int slideIndex,
  int shapeId,
});

class PptxPhotoAdditionEngine {
  const new({this._libraryPath});

  final String? _libraryPath;
  static const _maxSlides = 256;
  static const _maxPptxBytes = 128 * 1024 * 1024;
  static final _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');
  static const _invalidReply = InkVaultNativeException(
    'invalid_response',
    '사진을 추가한 PPTX를 확인하지 못했습니다.',
  );

  Future<PptxPhotoAdditionPlan> inspect({
    required String sourcePath,
    required String sourceSha256,
  }) async {
    _requirePath(sourcePath, pptx: true);
    _requireHash(sourceSha256);
    final result = await _invoke({
      'op': 'pptx_photo_add_inspect',
      'sourcePath': sourcePath,
      'sourceSha256': sourceSha256,
    });
    final slides = result['slides'];
    if (result.length != 3 ||
        result['sourceSha256'] != sourceSha256 ||
        slides is! List ||
        slides.isEmpty ||
        slides.length > _maxSlides ||
        result['slideCount'] is! int ||
        result['slideCount'] != slides.length) {
      throw _invalidReply;
    }
    final choices = <PptxPhotoAdditionSlide>[];
    for (final slide in slides) {
      if (slide is! Map<String, Object?> ||
          !slide.keys.every(
            const {
              'index',
              'hidden',
              'canAdd',
              'title',
              'sectionName',
            }.contains,
          )) {
        throw _invalidReply;
      }
      final index = slide['index'];
      final hidden = slide['hidden'];
      final canAdd = slide['canAdd'];
      final title = slide['title'];
      final sectionName = slide['sectionName'];
      if (index is! int ||
          index != choices.length ||
          hidden is! bool ||
          canAdd is! bool ||
          (title != null && (title is! String || title.length > 200)) ||
          (sectionName != null &&
              (sectionName is! String || sectionName.length > 200))) {
        throw _invalidReply;
      }
      choices.add(
        PptxPhotoAdditionSlide(
          index: index,
          hidden: hidden,
          canAdd: canAdd,
          title: title as String?,
          sectionName: sectionName as String?,
        ),
      );
    }
    return PptxPhotoAdditionPlan(sourceSha256: sourceSha256, slides: choices);
  }

  Future<PptxPhotoAdditionOutput> add({
    required String sourcePath,
    required PptxPhotoAdditionPlan plan,
    required String outputPath,
    required int slideIndex,
    required String assetPath,
    required String assetSha256,
  }) async {
    _requirePath(sourcePath, pptx: true);
    _requirePath(outputPath, pptx: true);
    _requirePath(assetPath);
    _requireHash(plan.sourceSha256);
    _requireHash(assetSha256);
    final workingDirectory = p.dirname(sourcePath);
    if (p.equals(sourcePath, outputPath) ||
        p.equals(sourcePath, assetPath) ||
        p.equals(outputPath, assetPath) ||
        !p.equals(p.dirname(outputPath), workingDirectory) ||
        !p.equals(p.dirname(assetPath), workingDirectory)) {
      throw ArgumentError('Expected separate files in one working folder');
    }
    if (plan.slideCount > _maxSlides ||
        slideIndex < 0 ||
        slideIndex >= plan.slideCount ||
        plan.slides[slideIndex].index != slideIndex ||
        !plan.slides[slideIndex].canAdd) {
      throw const InkVaultNativeException(
        'unsupported_slide',
        '이 슬라이드에는 사진을 추가할 수 없습니다.',
      );
    }
    final result = await _invoke({
      'op': 'pptx_photo_add',
      'sourcePath': sourcePath,
      'sourceSha256': plan.sourceSha256,
      'outputPath': outputPath,
      'slideIndex': slideIndex,
      'assetPath': assetPath,
      'assetSha256': assetSha256,
    });
    final outputSha = result['outputSha256'];
    final count = result['slideCount'];
    final shapeId = result['shapeId'];
    if (result.length != 5 ||
        result['sourceSha256'] != plan.sourceSha256 ||
        outputSha is! String ||
        outputSha == plan.sourceSha256 ||
        !_sha256Pattern.hasMatch(outputSha) ||
        count is! int ||
        count != plan.slideCount ||
        result['slideIndex'] is! int ||
        result['slideIndex'] != slideIndex ||
        shapeId is! int ||
        shapeId < 1 ||
        shapeId > 0xffffffff ||
        FileSystemEntity.typeSync(outputPath, followLinks: false) !=
            FileSystemEntityType.file) {
      throw _invalidReply;
    }
    final file = File(outputPath);
    final length = await file.length();
    if (length < 1 ||
        length > _maxPptxBytes ||
        (await sha256.bind(file.openRead()).first).toString() != outputSha) {
      throw _invalidReply;
    }
    return (
      sourceSha256: plan.sourceSha256,
      outputSha256: outputSha,
      slideCount: count,
      slideIndex: slideIndex,
      shapeId: shapeId,
    );
  }

  Future<Map<String, dynamic>> _invoke(Map<String, Object?> request) {
    final library = _libraryPath;
    return Isolate.run(
      () => InkVaultNative.open(libraryPath: library).invoke(request),
    );
  }

  static void _requirePath(String path, {bool pptx = false}) {
    if (!p.isAbsolute(path) ||
        p.normalize(path) != path ||
        (pptx && p.extension(path).toLowerCase() != '.pptx')) {
      throw ArgumentError('Expected a normalized absolute working file path');
    }
  }

  static void _requireHash(String value) {
    if (!_sha256Pattern.hasMatch(value)) {
      throw ArgumentError('Expected a SHA-256 digest');
    }
  }
}
