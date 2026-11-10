import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/native/ink_vault_native.dart';

final class PptxSlideDeleteChoice {
  const new({
    required this.index,
    required this.hidden,
    required this.canDelete,
    this.title,
    this.sectionName,
  });

  final int index;
  final bool hidden;
  final bool canDelete;
  final String? title;
  final String? sectionName;
}

final class PptxSlideDeletePlan {
  new({required this.sourceSha256, required List<PptxSlideDeleteChoice> slides})
    : slides = List.unmodifiable(slides);

  final String sourceSha256;
  final List<PptxSlideDeleteChoice> slides;
  int get slideCount => slides.length;
}

final class PptxSlideDeleteOutput {
  const new({
    required this.sourceSha256,
    required this.outputSha256,
    required this.slideCount,
    required this.deletedIndex,
  });

  final String sourceSha256;
  final String outputSha256;
  final int slideCount;
  final int deletedIndex;
}

class PptxSlideDeleteEngine {
  const new({this._libraryPath});

  final String? _libraryPath;
  static const _maxSlides = 256;
  static const _maxPptxBytes = 128 * 1024 * 1024;
  static final _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');
  static const _invalidReply = InkVaultNativeException(
    'invalid_response',
    '슬라이드를 삭제한 PPTX를 확인하지 못했습니다.',
  );

  Future<PptxSlideDeletePlan> inspect({
    required String sourcePath,
    required String sourceSha256,
  }) async {
    _requirePath(sourcePath);
    _requireHash(sourceSha256);
    final result = await _invoke({
      'op': 'pptx_delete_inspect',
      'sourcePath': sourcePath,
      'sourceSha256': sourceSha256,
    });
    final slides = result['slides'];
    if (result.length != 3 ||
        result['sourceSha256'] != sourceSha256 ||
        result['slideCount'] is! int ||
        slides is! List ||
        slides.isEmpty ||
        slides.length > _maxSlides ||
        result['slideCount'] != slides.length) {
      throw _invalidReply;
    }
    final choices = <PptxSlideDeleteChoice>[];
    for (final slide in slides) {
      if (slide is! Map<String, Object?> ||
          !slide.keys.every(
            const {
              'index',
              'hidden',
              'canDelete',
              'title',
              'sectionName',
            }.contains,
          )) {
        throw _invalidReply;
      }
      final index = slide['index'];
      final hidden = slide['hidden'];
      final canDelete = slide['canDelete'];
      final title = slide['title'];
      final sectionName = slide['sectionName'];
      if (index is! int ||
          index != choices.length ||
          hidden is! bool ||
          canDelete is! bool ||
          (title != null && (title is! String || title.length > 200)) ||
          (sectionName != null &&
              (sectionName is! String || sectionName.length > 200))) {
        throw _invalidReply;
      }
      choices.add(
        PptxSlideDeleteChoice(
          index: index,
          hidden: hidden,
          canDelete: canDelete && slides.length > 1,
          title: title as String?,
          sectionName: sectionName as String?,
        ),
      );
    }
    return PptxSlideDeletePlan(sourceSha256: sourceSha256, slides: choices);
  }

  Future<PptxSlideDeleteOutput> delete({
    required String sourcePath,
    required PptxSlideDeletePlan plan,
    required String outputPath,
    required int slideIndex,
  }) async {
    _requirePath(sourcePath);
    _requirePath(outputPath);
    _requireHash(plan.sourceSha256);
    if (p.equals(sourcePath, outputPath) ||
        !p.equals(p.dirname(sourcePath), p.dirname(outputPath))) {
      throw ArgumentError('Expected separate PPTX files in one working folder');
    }
    if (plan.slideCount < 2 ||
        plan.slideCount > _maxSlides ||
        slideIndex < 0 ||
        slideIndex >= plan.slideCount ||
        plan.slides[slideIndex].index != slideIndex ||
        !plan.slides[slideIndex].canDelete) {
      throw const InkVaultNativeException(
        'unsupported_slide',
        '이 슬라이드를 삭제할 수 없습니다.',
      );
    }
    final result = await _invoke({
      'op': 'pptx_delete_apply',
      'sourcePath': sourcePath,
      'sourceSha256': plan.sourceSha256,
      'outputPath': outputPath,
      'slideIndex': slideIndex,
    });
    final outputSha = result['outputSha256'];
    final count = result['slideCount'];
    if (result.length != 4 ||
        result['sourceSha256'] != plan.sourceSha256 ||
        outputSha is! String ||
        outputSha == plan.sourceSha256 ||
        !_sha256Pattern.hasMatch(outputSha) ||
        count is! int ||
        count != plan.slideCount - 1 ||
        result['deletedIndex'] is! int ||
        result['deletedIndex'] != slideIndex ||
        FileSystemEntity.typeSync(outputPath, followLinks: false) !=
            FileSystemEntityType.file) {
      throw _invalidReply;
    }
    final file = File(outputPath);
    final length = await file.length();
    if (length <= 0 ||
        length > _maxPptxBytes ||
        (await sha256.bind(file.openRead()).first).toString() != outputSha) {
      throw _invalidReply;
    }
    return PptxSlideDeleteOutput(
      sourceSha256: plan.sourceSha256,
      outputSha256: outputSha,
      slideCount: count,
      deletedIndex: slideIndex,
    );
  }

  Future<Map<String, dynamic>> _invoke(Map<String, Object?> request) {
    final library = _libraryPath;
    return Isolate.run(
      () => InkVaultNative.open(libraryPath: library).invoke(request),
    );
  }

  static void _requirePath(String path) {
    if (!p.isAbsolute(path) ||
        p.normalize(path) != path ||
        p.extension(path).toLowerCase() != '.pptx') {
      throw ArgumentError('Expected a normalized absolute PPTX path');
    }
  }

  static void _requireHash(String value) {
    if (!_sha256Pattern.hasMatch(value)) {
      throw ArgumentError('Expected a PPTX SHA-256 digest');
    }
  }
}
