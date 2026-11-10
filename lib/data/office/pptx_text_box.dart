import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/native/ink_vault_native.dart';

part 'pptx_table_add.dart';

enum PptxTextBoxPlacement { top, middle, bottom }

enum PptxPresetShape { rectangle, roundedRectangle, ellipse, rightArrow }

final class PptxTextBoxSlide {
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

final class PptxTextBoxPlan {
  new({required this.sourceSha256, required List<PptxTextBoxSlide> slides})
    : slides = List.unmodifiable(slides);

  final String sourceSha256;
  final List<PptxTextBoxSlide> slides;
  int get slideCount => slides.length;
}

final class PptxTextBoxOutput {
  const new({
    required this.sourceSha256,
    required this.outputSha256,
    required this.slideCount,
    required this.slideIndex,
    required this.shapeId,
  });

  final String sourceSha256;
  final String outputSha256;
  final int slideCount;
  final int slideIndex;
  final int shapeId;
}

class PptxTextBoxEngine {
  const new({this._libraryPath});

  final String? _libraryPath;
  static const maxSlides = 256;
  static const maxTextLength = 600;
  static const maxLines = 8;
  static const minFontSize = 12;
  static const maxFontSize = 40;
  static const _maxPptxBytes = 128 * 1024 * 1024;
  static final _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');
  static final _colorPattern = RegExp(r'^[0-9A-F]{6}$');
  static final _invalidCharacters = RegExp(
    r'[\u0000-\u0009\u000b-\u001f\u007f-\u009f\u2028\u2029\ud800-\udfff\ufffe\uffff]',
    unicode: true,
  );
  static const _invalidReply = InkVaultNativeException(
    'invalid_response',
    '텍스트 상자를 추가한 PPTX를 확인하지 못했습니다.',
  );
  static const _invalidShapeReply = InkVaultNativeException(
    'invalid_response',
    '도형을 추가한 PPTX를 확인하지 못했습니다.',
  );

  static String normalizeText(String value) =>
      value.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

  static bool validText(String value) =>
      value.trim().isNotEmpty &&
      value.length <= maxTextLength &&
      '\n'.allMatches(value).length < maxLines &&
      !_invalidCharacters.hasMatch(value);

  static bool validPresetText(String value) =>
      value.isEmpty || validText(value);

  Future<PptxTextBoxPlan> inspect({
    required String sourcePath,
    required String sourceSha256,
  }) => _inspect(
    sourcePath,
    sourceSha256,
    'pptx_text_box_inspect',
    _invalidReply,
  );

  Future<PptxTextBoxPlan> inspectPresetShapes({
    required String sourcePath,
    required String sourceSha256,
  }) => _inspect(
    sourcePath,
    sourceSha256,
    'pptx_preset_shape_inspect',
    _invalidShapeReply,
  );

  Future<PptxTextBoxPlan> _inspect(
    String sourcePath,
    String sourceSha256,
    String operation,
    InkVaultNativeException invalid,
  ) async {
    _requirePath(sourcePath);
    _requireHash(sourceSha256);
    final result = await _invoke({
      'op': operation,
      'sourcePath': sourcePath,
      'sourceSha256': sourceSha256,
    });
    final slides = result['slides'];
    if (result.length != 3 ||
        result['sourceSha256'] != sourceSha256 ||
        result['slideCount'] is! int ||
        slides is! List ||
        slides.isEmpty ||
        slides.length > maxSlides ||
        result['slideCount'] != slides.length) {
      throw invalid;
    }
    final choices = <PptxTextBoxSlide>[];
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
        throw invalid;
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
        throw invalid;
      }
      choices.add(
        PptxTextBoxSlide(
          index: index,
          hidden: hidden,
          canAdd: canAdd,
          title: title as String?,
          sectionName: sectionName as String?,
        ),
      );
    }
    return PptxTextBoxPlan(sourceSha256: sourceSha256, slides: choices);
  }

  Future<PptxTextBoxOutput> add({
    required String sourcePath,
    required PptxTextBoxPlan plan,
    required String outputPath,
    required int slideIndex,
    required String text,
    required PptxTextBoxPlacement placement,
    required int fontSize,
  }) => _add(
    sourcePath: sourcePath,
    plan: plan,
    outputPath: outputPath,
    slideIndex: slideIndex,
    text: text,
    placement: placement,
    fontSize: fontSize,
  );

  Future<PptxTextBoxOutput> addPresetShape({
    required String sourcePath,
    required PptxTextBoxPlan plan,
    required String outputPath,
    required int slideIndex,
    required String text,
    required PptxTextBoxPlacement placement,
    required int fontSize,
    required PptxPresetShape preset,
    required String? fillColor,
    required String lineColor,
  }) {
    if ((fillColor != null && !_colorPattern.hasMatch(fillColor)) ||
        !_colorPattern.hasMatch(lineColor)) {
      throw ArgumentError(
        'Expected six hexadecimal digits for each PPTX color',
      );
    }
    return _add(
      sourcePath: sourcePath,
      plan: plan,
      outputPath: outputPath,
      slideIndex: slideIndex,
      text: text,
      placement: placement,
      fontSize: fontSize,
      preset: preset,
      fillColor: fillColor,
      lineColor: lineColor,
    );
  }

  Future<PptxTextBoxOutput> _add({
    required String sourcePath,
    required PptxTextBoxPlan plan,
    required String outputPath,
    required int slideIndex,
    required String text,
    required PptxTextBoxPlacement placement,
    required int fontSize,
    PptxPresetShape? preset,
    String? fillColor,
    String? lineColor,
  }) async {
    _requirePath(sourcePath);
    _requirePath(outputPath);
    _requireHash(plan.sourceSha256);
    _requireSeparateOutput(sourcePath, outputPath);
    final normalized = normalizeText(text);
    final presetMode = preset != null;
    final invalid = presetMode ? _invalidShapeReply : _invalidReply;
    if (!(presetMode ? validPresetText(normalized) : validText(normalized)) ||
        fontSize < minFontSize ||
        fontSize > maxFontSize) {
      throw ArgumentError('Invalid PPTX shape text or font size');
    }
    if (plan.slideCount > maxSlides ||
        slideIndex < 0 ||
        slideIndex >= plan.slideCount ||
        plan.slides[slideIndex].index != slideIndex ||
        !plan.slides[slideIndex].canAdd) {
      throw InkVaultNativeException(
        'unsupported_slide',
        presetMode
            ? '이 슬라이드에는 도형을 추가할 수 없습니다.'
            : '이 슬라이드에는 텍스트 상자를 추가할 수 없습니다.',
      );
    }
    final result = await _invoke({
      'op': presetMode ? 'pptx_preset_shape_add' : 'pptx_text_box_add',
      'sourcePath': sourcePath,
      'sourceSha256': plan.sourceSha256,
      'outputPath': outputPath,
      'slideIndex': slideIndex,
      'text': normalized,
      'placement': placement.name,
      'fontSize': fontSize,
      if (preset != null) ...{
        'preset': preset.name,
        'fillColor': fillColor,
        'lineColor': lineColor!,
      },
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
        shapeId > 0xffffffff) {
      throw invalid;
    }
    await _validateWrittenCandidate(outputPath, outputSha, invalid);
    return PptxTextBoxOutput(
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

  static Future<void> _validateWrittenCandidate(
    String outputPath,
    String outputSha,
    InkVaultNativeException invalid,
  ) async {
    if (FileSystemEntity.typeSync(outputPath, followLinks: false) !=
        FileSystemEntityType.file) {
      throw invalid;
    }
    final file = File(outputPath);
    final length = await file.length();
    if (length < 1 ||
        length > _maxPptxBytes ||
        (await sha256.bind(file.openRead()).first).toString() != outputSha) {
      throw invalid;
    }
  }

  static void _requireSeparateOutput(String sourcePath, String outputPath) {
    if (p.equals(sourcePath, outputPath) ||
        !p.equals(p.dirname(sourcePath), p.dirname(outputPath))) {
      throw ArgumentError('Expected separate PPTX files in one working folder');
    }
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
