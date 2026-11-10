import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/native/ink_vault_native.dart';

final class PptxSlideChoice {
  const new({
    required this.index,
    required this.canDuplicate,
    required this.hidden,
    this.title,
  });

  final int index;
  final bool canDuplicate;
  final bool hidden;
  final String? title;
}

final class PptxSlideClonePlan {
  new({required this.sourceSha256, required List<PptxSlideChoice> slides})
    : slides = List.unmodifiable(slides);

  final String sourceSha256;
  final List<PptxSlideChoice> slides;
  int get slideCount => slides.length;
}

final class PptxSlideCloneOutput {
  const new({
    required this.sourceSha256,
    required this.outputSha256,
    required this.slideCount,
    required this.duplicateIndex,
  });

  final String sourceSha256;
  final String outputSha256;
  final int slideCount;
  final int duplicateIndex;
}

class PptxSlideCloneEngine {
  const new({this._libraryPath});

  final String? _libraryPath;
  static const _maxSlides = 256;
  static const _maxPptxBytes = 128 * 1024 * 1024;
  static final _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');

  Future<PptxSlideClonePlan> inspect({
    required String sourcePath,
    required String sourceSha256,
  }) async {
    _requirePath(sourcePath);
    _requireHash(sourceSha256);
    final result = await _invoke({
      'op': 'pptx_clone_inspect',
      'sourcePath': sourcePath,
      'sourceSha256': sourceSha256,
    });
    final slides = result['slides'];
    if (!_hasKeys(result, const {'sourceSha256', 'slideCount', 'slides'}) ||
        result['sourceSha256'] != sourceSha256 ||
        result['slideCount'] is! int ||
        slides is! List ||
        slides.isEmpty ||
        slides.length > _maxSlides ||
        result['slideCount'] != slides.length) {
      throw _invalidReply();
    }
    final choices = <PptxSlideChoice>[];
    for (final slide in slides) {
      if (slide is! Map<String, Object?> ||
          !slide.keys.every(
            const {'index', 'canDuplicate', 'hidden', 'title'}.contains,
          )) {
        throw _invalidReply();
      }
      final index = slide['index'];
      final canDuplicate = slide['canDuplicate'];
      final hidden = slide['hidden'];
      final title = slide['title'];
      if (index is! int ||
          index != choices.length ||
          canDuplicate is! bool ||
          hidden is! bool ||
          (title != null && (title is! String || title.length > 200))) {
        throw _invalidReply();
      }
      choices.add(
        PptxSlideChoice(
          index: index,
          canDuplicate: canDuplicate && slides.length < _maxSlides,
          hidden: hidden,
          title: title as String?,
        ),
      );
    }
    return PptxSlideClonePlan(sourceSha256: sourceSha256, slides: choices);
  }

  Future<PptxSlideCloneOutput> duplicate({
    required String sourcePath,
    required PptxSlideClonePlan plan,
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
    if (plan.slideCount >= _maxSlides ||
        slideIndex < 0 ||
        slideIndex >= plan.slideCount ||
        plan.slides[slideIndex].index != slideIndex ||
        !plan.slides[slideIndex].canDuplicate) {
      throw const InkVaultNativeException(
        'unsupported_slide',
        '이 슬라이드를 복제할 수 없습니다.',
      );
    }
    final result = await _invoke({
      'op': 'pptx_clone_apply',
      'sourcePath': sourcePath,
      'sourceSha256': plan.sourceSha256,
      'outputPath': outputPath,
      'slideIndex': slideIndex,
    });
    final outputSha = result['outputSha256'];
    final count = result['slideCount'];
    final index = result['duplicateIndex'];
    if (!_hasKeys(result, const {
          'sourceSha256',
          'outputSha256',
          'slideCount',
          'duplicateIndex',
        }) ||
        result['sourceSha256'] != plan.sourceSha256 ||
        outputSha is! String ||
        !_sha256Pattern.hasMatch(outputSha) ||
        count is! int ||
        count != plan.slideCount + 1 ||
        index is! int ||
        index != slideIndex + 1) {
      throw _invalidReply();
    }
    final file = File(outputPath);
    if (FileSystemEntity.typeSync(outputPath, followLinks: false) !=
        FileSystemEntityType.file) {
      throw _invalidReply();
    }
    final length = await file.length();
    if (length <= 0 ||
        length > _maxPptxBytes ||
        (await sha256.bind(file.openRead()).first).toString() != outputSha) {
      throw _invalidReply();
    }
    return PptxSlideCloneOutput(
      sourceSha256: plan.sourceSha256,
      outputSha256: outputSha,
      slideCount: count,
      duplicateIndex: index,
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

  static bool _hasKeys(Map<String, Object?> value, Set<String> keys) =>
      value.length == keys.length && value.keys.every(keys.contains);

  static InkVaultNativeException _invalidReply() =>
      const InkVaultNativeException(
        'invalid_response',
        '복제한 PPTX를 확인하지 못했습니다.',
      );
}
