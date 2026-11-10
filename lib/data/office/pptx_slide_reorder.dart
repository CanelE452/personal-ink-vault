import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/native/ink_vault_native.dart';

final class PptxSlideReorderChoice {
  const new({
    required this.index,
    required this.hidden,
    this.title,
    this.sectionTitle,
    this.sectionGroup,
    this.background,
  });

  final int index;
  final bool hidden;
  final String? title;
  final String? sectionTitle;
  final int? sectionGroup;
  final String? background;
}

final class PptxSlideReorderPlan {
  new({
    required this.sourceSha256,
    required List<PptxSlideReorderChoice> slides,
  }) : slides = List.unmodifiable(slides);

  final String sourceSha256;
  final List<PptxSlideReorderChoice> slides;
  int get slideCount => slides.length;

  bool canMove(int sourceIndex, int targetIndex, {required bool after}) {
    if (sourceIndex < 0 ||
        sourceIndex >= slideCount ||
        targetIndex < 0 ||
        targetIndex >= slideCount ||
        sourceIndex == targetIndex ||
        slides[sourceIndex].index != sourceIndex ||
        slides[targetIndex].index != targetIndex) {
      return false;
    }
    if (PptxSlideReorderEngine.destinationIndex(
          sourceIndex,
          targetIndex,
          after: after,
        ) !=
        sourceIndex) {
      return true;
    }
    final sourceGroup = slides[sourceIndex].sectionGroup;
    final targetGroup = slides[targetIndex].sectionGroup;
    return sourceGroup != null &&
        sourceGroup >= 0 &&
        sourceGroup < slideCount &&
        targetGroup != null &&
        targetGroup >= 0 &&
        targetGroup < slideCount &&
        sourceGroup != targetGroup;
  }
}

final class PptxSlideReorderOutput {
  const new({
    required this.sourceSha256,
    required this.outputSha256,
    required this.slideCount,
    required this.sourceIndex,
    required this.destinationIndex,
  });

  final String sourceSha256;
  final String outputSha256;
  final int slideCount;
  final int sourceIndex;
  final int destinationIndex;
}

final class PptxSlideDisplayOutput {
  const new({
    required this.sourceSha256,
    required this.outputSha256,
    required this.slideCount,
    required this.slideIndex,
    required this.hidden,
  });

  final String sourceSha256;
  final String outputSha256;
  final int slideCount;
  final int slideIndex;
  final bool hidden;
}

typedef PptxSlideBackgroundOutput = ({
  String sourceSha256,
  String outputSha256,
  int slideCount,
  int slideIndex,
  String background,
});

class PptxSlideReorderEngine {
  const new({this._libraryPath});

  final String? _libraryPath;
  static const _maxSlides = 256;
  static const _maxPptxBytes = 128 * 1024 * 1024;
  static final _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');
  static final _rgbPattern = RegExp(r'^#[0-9A-F]{6}$');

  static int destinationIndex(
    int sourceIndex,
    int targetIndex, {
    required bool after,
  }) {
    final insertion = targetIndex + (after ? 1 : 0);
    return insertion - (sourceIndex < insertion ? 1 : 0);
  }

  Future<PptxSlideReorderPlan> inspect({
    required String sourcePath,
    required String sourceSha256,
  }) => _inspect(sourcePath, sourceSha256, background: false);

  Future<PptxSlideReorderPlan> inspectBackground({
    required String sourcePath,
    required String sourceSha256,
  }) => _inspect(sourcePath, sourceSha256, background: true);

  Future<PptxSlideReorderPlan> _inspect(
    String sourcePath,
    String sourceSha256, {
    required bool background,
  }) async {
    _requirePath(sourcePath);
    _requireHash(sourceSha256);
    final invalid = background ? _invalidBackgroundReply : _invalidReply;
    final result = await _invoke({
      'op': background
          ? 'pptx_slide_background_inspect'
          : 'pptx_reorder_inspect',
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
      throw invalid;
    }

    final choices = <PptxSlideReorderChoice>[];
    final allowed = {
      'index',
      'hidden',
      'title',
      'sectionTitle',
      if (!background) 'sectionGroup',
      if (background) 'background',
    };
    for (final slide in slides) {
      if (slide is! Map<String, Object?> ||
          !slide.keys.every(allowed.contains)) {
        throw invalid;
      }
      final index = slide['index'];
      final hidden = slide['hidden'];
      final title = slide['title'];
      final sectionTitle = slide['sectionTitle'];
      final sectionGroup = slide['sectionGroup'];
      final slideBackground = slide['background'];
      if (index is! int ||
          index != choices.length ||
          hidden is! bool ||
          (background &&
              slideBackground != 'unsupported' &&
              !_editableBackground(slideBackground)) ||
          (title != null && (title is! String || title.length > 200)) ||
          (sectionTitle != null &&
              (sectionTitle is! String || sectionTitle.length > 200)) ||
          (slide.containsKey('sectionGroup') &&
              (sectionGroup is! int ||
                  sectionGroup < 0 ||
                  sectionGroup >= slides.length))) {
        throw invalid;
      }
      choices.add(
        PptxSlideReorderChoice(
          index: index,
          hidden: hidden,
          title: title as String?,
          sectionTitle: sectionTitle as String?,
          sectionGroup: sectionGroup as int?,
          background: slideBackground as String?,
        ),
      );
    }
    return PptxSlideReorderPlan(sourceSha256: sourceSha256, slides: choices);
  }

  Future<PptxSlideBackgroundOutput> setBackground({
    required String sourcePath,
    required PptxSlideReorderPlan plan,
    required String outputPath,
    required int slideIndex,
    required String background,
  }) async {
    _requirePath(sourcePath);
    _requirePath(outputPath);
    _requireHash(plan.sourceSha256);
    if (p.equals(sourcePath, outputPath) ||
        !p.equals(p.dirname(sourcePath), p.dirname(outputPath))) {
      throw ArgumentError('Expected separate PPTX files in one working folder');
    }
    if (plan.slideCount > _maxSlides ||
        slideIndex < 0 ||
        slideIndex >= plan.slideCount ||
        plan.slides[slideIndex].index != slideIndex) {
      throw ArgumentError('Expected a known slide');
    }
    final expected = plan.slides[slideIndex].background;
    if (!_editableBackground(expected) ||
        !_editableBackground(background) ||
        expected == background) {
      throw ArgumentError('Expected a changed solid slide background');
    }
    final result = await _invoke({
      'op': 'pptx_slide_background_apply',
      'sourcePath': sourcePath,
      'sourceSha256': plan.sourceSha256,
      'outputPath': outputPath,
      'slideIndex': slideIndex,
      'expectedBackground': expected,
      'background': background,
    });
    final outputSha = result['outputSha256'];
    final count = result['slideCount'];
    if (!_hasKeys(result, const {
          'sourceSha256',
          'outputSha256',
          'slideCount',
          'slideIndex',
          'background',
        }) ||
        result['sourceSha256'] != plan.sourceSha256 ||
        outputSha is! String ||
        outputSha == plan.sourceSha256 ||
        !_sha256Pattern.hasMatch(outputSha) ||
        count is! int ||
        count != plan.slideCount ||
        result['slideIndex'] is! int ||
        result['slideIndex'] != slideIndex ||
        result['background'] != background) {
      throw _invalidBackgroundReply;
    }
    await _verifyOutput(outputPath, outputSha, _invalidBackgroundReply);
    return (
      sourceSha256: plan.sourceSha256,
      outputSha256: outputSha,
      slideCount: count,
      slideIndex: slideIndex,
      background: background,
    );
  }

  static bool _editableBackground(Object? value) =>
      value == 'inherited' || (value is String && _rgbPattern.hasMatch(value));

  Future<PptxSlideReorderOutput> move({
    required String sourcePath,
    required PptxSlideReorderPlan plan,
    required String outputPath,
    required int sourceIndex,
    required int targetIndex,
    required bool after,
  }) async {
    _requirePath(sourcePath);
    _requirePath(outputPath);
    _requireHash(plan.sourceSha256);
    if (p.equals(sourcePath, outputPath) ||
        !p.equals(p.dirname(sourcePath), p.dirname(outputPath))) {
      throw ArgumentError('Expected separate PPTX files in one working folder');
    }
    final destination = destinationIndex(
      sourceIndex,
      targetIndex,
      after: after,
    );
    if (plan.slideCount > _maxSlides ||
        !plan.canMove(sourceIndex, targetIndex, after: after)) {
      throw ArgumentError('Expected a slide position or section change');
    }
    final result = await _invoke({
      'op': 'pptx_reorder_apply',
      'sourcePath': sourcePath,
      'sourceSha256': plan.sourceSha256,
      'outputPath': outputPath,
      'sourceIndex': sourceIndex,
      'targetIndex': targetIndex,
      'after': after,
    });
    final outputSha = result['outputSha256'];
    final count = result['slideCount'];
    if (!_hasKeys(result, const {
          'sourceSha256',
          'outputSha256',
          'slideCount',
          'sourceIndex',
          'destinationIndex',
        }) ||
        result['sourceSha256'] != plan.sourceSha256 ||
        outputSha is! String ||
        outputSha == plan.sourceSha256 ||
        !_sha256Pattern.hasMatch(outputSha) ||
        count is! int ||
        count != plan.slideCount ||
        result['sourceIndex'] is! int ||
        result['sourceIndex'] != sourceIndex ||
        result['destinationIndex'] is! int ||
        result['destinationIndex'] != destination) {
      throw _invalidReply;
    }
    await _verifyOutput(outputPath, outputSha, _invalidReply);
    return PptxSlideReorderOutput(
      sourceSha256: plan.sourceSha256,
      outputSha256: outputSha,
      slideCount: count,
      sourceIndex: sourceIndex,
      destinationIndex: destination,
    );
  }

  Future<PptxSlideDisplayOutput> setHidden({
    required String sourcePath,
    required PptxSlideReorderPlan plan,
    required String outputPath,
    required int slideIndex,
    required bool expectedHidden,
    required bool hidden,
  }) async {
    _requirePath(sourcePath);
    _requirePath(outputPath);
    _requireHash(plan.sourceSha256);
    if (p.equals(sourcePath, outputPath) ||
        !p.equals(p.dirname(sourcePath), p.dirname(outputPath))) {
      throw ArgumentError('Expected separate PPTX files in one working folder');
    }
    if (plan.slideCount > _maxSlides ||
        slideIndex < 0 ||
        slideIndex >= plan.slideCount ||
        plan.slides[slideIndex].index != slideIndex ||
        plan.slides[slideIndex].hidden != expectedHidden ||
        expectedHidden == hidden) {
      throw ArgumentError('Expected a changed display state for a known slide');
    }
    final result = await _invoke({
      'op': 'pptx_slide_display',
      'sourcePath': sourcePath,
      'sourceSha256': plan.sourceSha256,
      'outputPath': outputPath,
      'slideIndex': slideIndex,
      'expectedHidden': expectedHidden,
      'hidden': hidden,
    });
    final outputSha = result['outputSha256'];
    final count = result['slideCount'];
    if (!_hasKeys(result, const {
          'sourceSha256',
          'outputSha256',
          'slideCount',
          'slideIndex',
          'hidden',
        }) ||
        result['sourceSha256'] != plan.sourceSha256 ||
        outputSha is! String ||
        outputSha == plan.sourceSha256 ||
        !_sha256Pattern.hasMatch(outputSha) ||
        count is! int ||
        count != plan.slideCount ||
        result['slideIndex'] is! int ||
        result['slideIndex'] != slideIndex ||
        result['hidden'] != hidden) {
      throw _invalidDisplayReply;
    }
    await _verifyOutput(outputPath, outputSha, _invalidDisplayReply);
    return PptxSlideDisplayOutput(
      sourceSha256: plan.sourceSha256,
      outputSha256: outputSha,
      slideCount: count,
      slideIndex: slideIndex,
      hidden: hidden,
    );
  }

  static Future<void> _verifyOutput(
    String path,
    String expectedSha,
    InkVaultNativeException error,
  ) async {
    if (FileSystemEntity.typeSync(path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw error;
    }
    final file = File(path);
    final length = await file.length();
    if (length <= 0 ||
        length > _maxPptxBytes ||
        (await sha256.bind(file.openRead()).first).toString() != expectedSha) {
      throw error;
    }
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

  static const _invalidReply = InkVaultNativeException(
    'invalid_response',
    '순서를 바꾼 PPTX를 확인하지 못했습니다.',
  );
  static const _invalidDisplayReply = InkVaultNativeException(
    'invalid_response',
    '발표 표시 상태를 바꾼 PPTX를 확인하지 못했습니다.',
  );
  static const _invalidBackgroundReply = InkVaultNativeException(
    'invalid_response',
    '배경을 바꾼 PPTX를 확인하지 못했습니다.',
  );
}
