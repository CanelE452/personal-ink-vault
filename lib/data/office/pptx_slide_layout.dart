import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/native/ink_vault_native.dart';
import 'package:saber/data/office/pptx_slide_insert.dart';

final class PptxSlideLayoutChoice {
  const new({
    required this.index,
    required this.slideId,
    required this.hidden,
    required this.layouts,
    this.title,
    this.sectionName,
  });

  final int index;
  final int slideId;
  final bool hidden;
  final List<PptxSlideInsertLayout> layouts;
  final String? title;
  final String? sectionName;
}

final class PptxSlideLayoutPlan {
  new({required this.sourceSha256, required List<PptxSlideLayoutChoice> slides})
    : slides = List.unmodifiable(slides);

  final String sourceSha256;
  final List<PptxSlideLayoutChoice> slides;
  int get slideCount => slides.length;
}

final class PptxSlideLayoutOutput {
  const new({
    required this.sourceSha256,
    required this.outputSha256,
    required this.slideCount,
    required this.slideIndex,
    required this.slideId,
    required this.layoutId,
  });

  final String sourceSha256;
  final String outputSha256;
  final int slideCount;
  final int slideIndex;
  final int slideId;
  final int layoutId;
}

class PptxSlideLayoutEngine {
  const new({this._libraryPath});

  final String? _libraryPath;
  static const _maxPptxBytes = 128 * 1024 * 1024;
  static final _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');
  static const _invalidReply = InkVaultNativeException(
    'invalid_response',
    '레이아웃을 변경한 PPTX를 확인하지 못했습니다.',
  );

  Future<PptxSlideLayoutPlan> inspect({
    required String sourcePath,
    required String sourceSha256,
  }) async {
    _requirePath(sourcePath);
    _requireHash(sourceSha256);
    final result = await _invoke({
      'op': 'pptx_layout_inspect',
      'sourcePath': sourcePath,
      'sourceSha256': sourceSha256,
    });
    final rows = result['slides'];
    if (result.length != 3 ||
        result['sourceSha256'] != sourceSha256 ||
        result['slideCount'] is! int ||
        rows is! List ||
        rows.isEmpty ||
        rows.length > PptxSlideInsertEngine.maxSlides ||
        result['slideCount'] != rows.length) {
      throw _invalidReply;
    }
    final slides = <PptxSlideLayoutChoice>[];
    final ids = <int>{};
    for (final row in rows) {
      if (row is! Map<String, Object?> ||
          !row.keys.every(
            const {
              'index',
              'slideId',
              'hidden',
              'title',
              'sectionName',
              'layouts',
            }.contains,
          )) {
        throw _invalidReply;
      }
      final index = row['index'];
      final id = row['slideId'];
      final hidden = row['hidden'];
      final title = row['title'];
      final sectionName = row['sectionName'];
      final layouts = PptxSlideInsertLayout.parseOptions(row['layouts']);
      if (index is! int ||
          index != slides.length ||
          id is! int ||
          id < 256 ||
          id >= 0x80000000 ||
          !ids.add(id) ||
          hidden is! bool ||
          (title != null && (title is! String || title.length > 200)) ||
          (sectionName != null &&
              (sectionName is! String || sectionName.length > 200)) ||
          layouts == null) {
        throw _invalidReply;
      }
      slides.add(
        PptxSlideLayoutChoice(
          index: index,
          slideId: id,
          hidden: hidden,
          title: title as String?,
          sectionName: sectionName as String?,
          layouts: layouts,
        ),
      );
    }
    return PptxSlideLayoutPlan(sourceSha256: sourceSha256, slides: slides);
  }

  Future<PptxSlideLayoutOutput> apply({
    required String sourcePath,
    required PptxSlideLayoutPlan plan,
    required String outputPath,
    required int slideIndex,
    required int layoutId,
  }) async {
    _requirePath(sourcePath);
    _requirePath(outputPath);
    _requireHash(plan.sourceSha256);
    if (p.equals(sourcePath, outputPath) ||
        !p.equals(p.dirname(sourcePath), p.dirname(outputPath))) {
      throw ArgumentError('Expected separate PPTX files in one working folder');
    }
    if (plan.slideCount > PptxSlideInsertEngine.maxSlides ||
        slideIndex < 0 ||
        slideIndex >= plan.slideCount ||
        plan.slides[slideIndex].index != slideIndex ||
        !plan.slides[slideIndex].layouts.any(
          (layout) => layout.id == layoutId,
        )) {
      throw const InkVaultNativeException(
        'unsupported_slide',
        '선택한 슬라이드에 적용할 수 있는 레이아웃을 다시 선택하세요.',
      );
    }
    final slideId = plan.slides[slideIndex].slideId;
    final result = await _invoke({
      'op': 'pptx_layout_apply',
      'sourcePath': sourcePath,
      'sourceSha256': plan.sourceSha256,
      'outputPath': outputPath,
      'slideIndex': slideIndex,
      'slideId': slideId,
      'layoutId': layoutId,
    });
    final outputSha = result['outputSha256'];
    if (result.length != 6 ||
        result['sourceSha256'] != plan.sourceSha256 ||
        outputSha is! String ||
        outputSha == plan.sourceSha256 ||
        !_isHash(outputSha) ||
        result['slideCount'] is! int ||
        result['slideCount'] != plan.slideCount ||
        result['slideIndex'] is! int ||
        result['slideIndex'] != slideIndex ||
        result['slideId'] is! int ||
        result['slideId'] != slideId ||
        result['layoutId'] is! int ||
        result['layoutId'] != layoutId ||
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
    return PptxSlideLayoutOutput(
      sourceSha256: plan.sourceSha256,
      outputSha256: outputSha,
      slideCount: plan.slideCount,
      slideIndex: slideIndex,
      slideId: slideId,
      layoutId: layoutId,
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

  static bool _isHash(String value) =>
      value.length == 64 && _sha256Pattern.hasMatch(value);

  static void _requireHash(String value) {
    if (!_isHash(value)) {
      throw ArgumentError('Expected a PPTX SHA-256 digest');
    }
  }
}
