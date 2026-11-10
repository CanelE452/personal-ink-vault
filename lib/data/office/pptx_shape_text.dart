import 'dart:io';
import 'dart:isolate';

import 'package:characters/characters.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/native/ink_vault_native.dart';

part 'pptx_speaker_notes.dart';
part 'pptx_table_cell_text.dart';
part 'pptx_table_merge.dart';
part 'pptx_table_structure.dart';

final class PptxShapeTextSlide {
  const new({required this.index, required this.hidden, this.title});

  final int index;
  final bool hidden;
  final String? title;
}

final class PptxShapeTextPlan {
  new({required this.sourceSha256, required List<PptxShapeTextSlide> slides})
    : slides = List.unmodifiable(slides);

  final String sourceSha256;
  final List<PptxShapeTextSlide> slides;
  int get slideCount => slides.length;
}

final class PptxShapeTextRun {
  const new({
    required this.paragraphIndex,
    required this.runIndex,
    required this.text,
  });

  final int paragraphIndex;
  final int runIndex;
  final String text;
}

final class PptxShapeTextShape {
  new({
    required this.shapeId,
    required this.name,
    required List<PptxShapeTextRun> runs,
    List<PptxShapeTextParagraph> paragraphs = const [],
  }) : runs = List.unmodifiable(runs),
       paragraphs = List.unmodifiable(paragraphs);

  final int shapeId;
  final String name;
  final List<PptxShapeTextRun> runs;
  final List<PptxShapeTextParagraph> paragraphs;
}

enum PptxParagraphAlignment {
  inherited(null),
  left('l'),
  center('ctr'),
  right('r'),
  justify('just'),
  justifyLow('justLow'),
  distributed('dist'),
  thaiDistributed('thaiDist');

  new(this.wireValue);

  final String? wireValue;
  bool get canSet => index <= justify.index;
}

final class PptxShapeTextParagraph {
  const new({required this.index, required this.text, required this.alignment});

  final int index;
  final String text;
  final PptxParagraphAlignment alignment;
}

final class PptxShapeParagraphAlignmentChange {
  const new({required this.paragraphIndex, required this.value});

  final int paragraphIndex;
  final PptxParagraphAlignment value;
}

final class PptxShapeTextChange {
  const new({
    required this.paragraphIndex,
    required this.runIndex,
    required this.text,
  });

  final int paragraphIndex;
  final int runIndex;
  final String text;
}

final class PptxShapeTextFormat {
  const new({
    required this.paragraphIndex,
    required this.runIndex,
    required this.start,
    required this.end,
    this.bold,
    this.italic,
    this.underline,
    this.fontSize,
    this.fontColor,
  });

  final int paragraphIndex;
  final int runIndex;
  final int start;
  final int end;
  final bool? bold;
  final bool? italic;
  final bool? underline;

  /// Hundredths of a point.
  final int? fontSize;
  final String? fontColor;
}

final class PptxShapeTextOutput {
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

class PptxShapeTextEngine {
  const new({this._libraryPath});

  final String? _libraryPath;
  static const maxRunLength = 2000;
  static const maxRunsPerSlide = 400;
  static const maxTotalRunLength = 150000;
  static const minFormatFontSize = 100;
  static const maxFormatFontSize = 400000;
  static const _maxSlides = 256;
  static const _maxPptxBytes = 128 * 1024 * 1024;
  static final _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');
  static final _fontColorPattern = RegExp(r'^[0-9a-fA-F]{6}$');
  static final _invalidCharacters = RegExp(
    r'[\u0000-\u001f\u007f-\u009f\u2028\u2029\ud800-\udfff\ufffe\uffff]',
    unicode: true,
  );
  static const _invalidReply = InkVaultNativeException(
    'invalid_response',
    'PPTX 도형의 글자와 원본 판본을 확인하지 못했습니다.',
  );

  static bool validText(String value) =>
      value.length <= maxRunLength && !_invalidCharacters.hasMatch(value);

  static bool validFormatFontSize(int value) =>
      value >= minFormatFontSize && value <= maxFormatFontSize;

  static bool validFormatFontColor(String value) =>
      value.length == 6 && _fontColorPattern.hasMatch(value);

  static bool validFormatRange(String text, int start, int end) {
    if (start < 0 || end <= start || end > text.length || !validText(text)) {
      return false;
    }
    var offset = 0;
    var startIsBoundary = start == 0;
    for (final grapheme in text.characters) {
      offset += grapheme.length;
      if (offset == start) startIsBoundary = true;
      if (offset >= end) return startIsBoundary && offset == end;
    }
    return false;
  }

  Future<PptxShapeTextPlan> inspect({
    required String sourcePath,
    required String sourceSha256,
  }) => _inspect(
    sourcePath,
    sourceSha256,
    'pptx_shape_text_inspect',
    _invalidReply,
  );

  Future<PptxShapeTextPlan> _inspect(
    String sourcePath,
    String sourceSha256,
    String operation,
    InkVaultNativeException invalid,
  ) async {
    _requireSource(sourcePath, sourceSha256);
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
        slides.length > _maxSlides ||
        result['slideCount'] != slides.length) {
      throw invalid;
    }
    final choices = <PptxShapeTextSlide>[];
    for (final slide in slides) {
      if (slide is! Map<String, Object?> ||
          !slide.keys.every(const {'index', 'hidden', 'title'}.contains)) {
        throw invalid;
      }
      final index = slide['index'];
      final hidden = slide['hidden'];
      final title = slide['title'];
      if (index is! int ||
          index != choices.length ||
          hidden is! bool ||
          (title != null && (title is! String || title.length > 200))) {
        throw invalid;
      }
      choices.add(
        PptxShapeTextSlide(
          index: index,
          hidden: hidden,
          title: title as String?,
        ),
      );
    }
    return PptxShapeTextPlan(sourceSha256: sourceSha256, slides: choices);
  }

  Future<List<PptxShapeTextShape>> inspectSlide({
    required String sourcePath,
    required PptxShapeTextPlan plan,
    required int slideIndex,
  }) async {
    _requireSlide(sourcePath, plan, slideIndex);
    final result = await _invoke({
      'op': 'pptx_shape_text_inspect',
      'sourcePath': sourcePath,
      'sourceSha256': plan.sourceSha256,
      'slideIndex': slideIndex,
    });
    final shapes = result['shapes'];
    if (result.length != 4 ||
        !_matchesSlide(result, plan, slideIndex) ||
        shapes is! List ||
        shapes.length > maxRunsPerSlide) {
      throw _invalidReply;
    }
    final choices = <PptxShapeTextShape>[];
    final ids = <int>{};
    var runCount = 0;
    var textLength = 0;
    for (final shape in shapes) {
      if (shape is! Map<String, Object?> || shape.length != 3) {
        throw _invalidReply;
      }
      final shapeId = shape['shapeId'];
      final name = shape['name'];
      final runs = shape['runs'];
      if (shapeId is! int ||
          shapeId < 1 ||
          shapeId > 0xffffffff ||
          !ids.add(shapeId) ||
          name is! String ||
          name.length > 1024 ||
          runs is! List ||
          runs.isEmpty ||
          runs.length > maxRunsPerSlide - runCount) {
        throw _invalidReply;
      }
      runCount += runs.length;
      final editable = _readRuns(runs, _invalidReply);
      for (final run in editable) {
        textLength += run.text.length;
        if (textLength > maxTotalRunLength) throw _invalidReply;
      }
      choices.add(
        PptxShapeTextShape(shapeId: shapeId, name: name, runs: editable),
      );
    }
    return List.unmodifiable(choices);
  }

  Future<List<PptxShapeTextShape>> inspectAlignmentSlide({
    required String sourcePath,
    required PptxShapeTextPlan plan,
    required int slideIndex,
  }) async {
    _requireSlide(sourcePath, plan, slideIndex);
    final result = await _invoke({
      'op': 'pptx_shape_paragraph_alignment',
      'sourcePath': sourcePath,
      'sourceSha256': plan.sourceSha256,
      'slideIndex': slideIndex,
    });
    final shapes = result['shapes'];
    if (result.length != 4 ||
        !_matchesSlide(result, plan, slideIndex) ||
        shapes is! List ||
        shapes.length > maxRunsPerSlide) {
      throw _invalidReply;
    }
    final choices = <PptxShapeTextShape>[];
    final ids = <int>{};
    var paragraphCount = 0;
    for (final shape in shapes) {
      if (shape is! Map<String, Object?> || shape.length != 3) {
        throw _invalidReply;
      }
      final id = shape['shapeId'];
      final name = shape['name'];
      final paragraphs = shape['paragraphs'];
      if (id is! int ||
          id < 1 ||
          id > 0xffffffff ||
          !ids.add(id) ||
          name is! String ||
          name.length > 1024 ||
          paragraphs is! List ||
          paragraphs.isEmpty ||
          paragraphs.length > maxRunsPerSlide - paragraphCount) {
        throw _invalidReply;
      }
      paragraphCount += paragraphs.length;
      final editable = <PptxShapeTextParagraph>[];
      for (final paragraph in paragraphs) {
        if (paragraph is! Map<String, Object?> ||
            paragraph.length != 3 ||
            !paragraph.containsKey('alignment') ||
            paragraph['index'] is! int ||
            paragraph['index'] != editable.length ||
            paragraph['text'] is! String ||
            (paragraph['text'] as String).length > 240) {
          throw _invalidReply;
        }
        final alignment = PptxParagraphAlignment.values
            .where((value) => value.wireValue == paragraph['alignment'])
            .singleOrNull;
        if (alignment == null) throw _invalidReply;
        editable.add(
          PptxShapeTextParagraph(
            index: editable.length,
            text: paragraph['text'] as String,
            alignment: alignment,
          ),
        );
      }
      choices.add(
        PptxShapeTextShape(
          shapeId: id,
          name: name,
          runs: const [],
          paragraphs: editable,
        ),
      );
    }
    return List.unmodifiable(choices);
  }

  static List<PptxShapeTextRun> _readRuns(
    List<Object?> runs,
    InkVaultNativeException invalid,
  ) {
    final editable = <PptxShapeTextRun>[];
    for (final run in runs) {
      if (run is! Map<String, Object?> || run.length != 3) throw invalid;
      final paragraph = run['paragraphIndex'];
      final index = run['runIndex'];
      final text = run['text'];
      if (paragraph is! int ||
          paragraph < 0 ||
          paragraph > 0xffffffff ||
          index is! int ||
          index < 0 ||
          index > 0xffffffff ||
          text is! String ||
          !validText(text)) {
        throw invalid;
      }
      if (editable.isNotEmpty) {
        final previous = editable.last;
        if (paragraph < previous.paragraphIndex ||
            (paragraph == previous.paragraphIndex &&
                index <= previous.runIndex)) {
          throw invalid;
        }
      }
      editable.add(
        PptxShapeTextRun(
          paragraphIndex: paragraph,
          runIndex: index,
          text: text,
        ),
      );
    }
    return editable;
  }

  Future<PptxShapeTextOutput> replace({
    required String sourcePath,
    required PptxShapeTextPlan plan,
    required String outputPath,
    required int slideIndex,
    required PptxShapeTextShape shape,
    required List<PptxShapeTextChange> changes,
  }) async {
    _requireSlide(sourcePath, plan, slideIndex);
    _requireOutputPath(sourcePath, outputPath);
    if (shape.shapeId < 1 ||
        shape.shapeId > 0xffffffff ||
        changes.isEmpty ||
        changes.length > maxRunsPerSlide) {
      throw ArgumentError('Expected changes to one PPTX shape');
    }
    final original = {
      for (final run in shape.runs)
        (run.paragraphIndex, run.runIndex): run.text,
    };
    var textLength = 0;
    final edits = <Map<String, Object>>[];
    for (final change in changes) {
      final previous = original.remove((
        change.paragraphIndex,
        change.runIndex,
      ));
      textLength += change.text.length;
      if (previous == null ||
          previous == change.text ||
          !validText(change.text) ||
          textLength > maxTotalRunLength) {
        throw ArgumentError('Expected distinct editable PPTX text changes');
      }
      edits.add({
        'paragraphIndex': change.paragraphIndex,
        'runIndex': change.runIndex,
        'text': change.text,
      });
    }
    final result = await _invoke({
      'op': 'pptx_shape_text_replace',
      'sourcePath': sourcePath,
      'sourceSha256': plan.sourceSha256,
      'outputPath': outputPath,
      'slideIndex': slideIndex,
      'shapeId': shape.shapeId,
      'changes': edits,
    });
    return _readOutput(result, plan, outputPath, slideIndex, shape.shapeId);
  }

  Future<PptxShapeTextOutput> align({
    required String sourcePath,
    required PptxShapeTextPlan plan,
    required String outputPath,
    required int slideIndex,
    required PptxShapeTextShape shape,
    required PptxShapeParagraphAlignmentChange alignment,
  }) async {
    _requireSlide(sourcePath, plan, slideIndex);
    _requireOutputPath(sourcePath, outputPath);
    final paragraph = shape.paragraphs
        .where((paragraph) => paragraph.index == alignment.paragraphIndex)
        .singleOrNull;
    if (shape.shapeId < 1 ||
        shape.shapeId > 0xffffffff ||
        paragraph == null ||
        paragraph.alignment == alignment.value ||
        !alignment.value.canSet) {
      throw ArgumentError(
        'Expected a different alignment for a PPTX paragraph',
      );
    }
    final result = await _invoke({
      'op': 'pptx_shape_paragraph_alignment',
      'sourcePath': sourcePath,
      'sourceSha256': plan.sourceSha256,
      'outputPath': outputPath,
      'slideIndex': slideIndex,
      'shapeId': shape.shapeId,
      'paragraphIndex': paragraph.index,
      'alignment': alignment.value.wireValue,
    });
    return _readOutput(result, plan, outputPath, slideIndex, shape.shapeId);
  }

  Future<PptxShapeTextOutput> format({
    required String sourcePath,
    required PptxShapeTextPlan plan,
    required String outputPath,
    required int slideIndex,
    required PptxShapeTextShape shape,
    required PptxShapeTextFormat format,
  }) async {
    _requireSlide(sourcePath, plan, slideIndex);
    _requireOutputPath(sourcePath, outputPath);
    if (shape.shapeId < 1 ||
        shape.shapeId > 0xffffffff ||
        format.paragraphIndex < 0 ||
        format.paragraphIndex > 0xffffffff ||
        format.runIndex < 0 ||
        format.runIndex > 0xffffffff) {
      throw ArgumentError('Expected a run in one PPTX shape');
    }
    final fontSize = format.fontSize;
    final fontColor = format.fontColor;
    if ((fontSize != null && !validFormatFontSize(fontSize)) ||
        (fontColor != null && !validFormatFontColor(fontColor))) {
      throw ArgumentError('Expected a PPTX font size or six-digit RGB color');
    }
    final styles = <String, Object>{
      'bold': ?format.bold,
      'italic': ?format.italic,
      'underline': ?format.underline,
      'fontSize': ?fontSize,
      'fontColor': ?fontColor?.toUpperCase(),
    };
    final run = shape.runs.where((run) {
      return run.paragraphIndex == format.paragraphIndex &&
          run.runIndex == format.runIndex;
    }).singleOrNull;
    if (styles.isEmpty ||
        run == null ||
        !validFormatRange(run.text, format.start, format.end)) {
      throw ArgumentError('Expected formatting for a selected PPTX text range');
    }
    final result = await _invoke({
      'op': 'pptx_shape_text_format',
      'sourcePath': sourcePath,
      'sourceSha256': plan.sourceSha256,
      'outputPath': outputPath,
      'slideIndex': slideIndex,
      'shapeId': shape.shapeId,
      'paragraphIndex': format.paragraphIndex,
      'runIndex': format.runIndex,
      'start': format.start,
      'end': format.end,
      'styles': styles,
    });
    return _readOutput(result, plan, outputPath, slideIndex, shape.shapeId);
  }

  static Future<PptxShapeTextOutput> _readOutput(
    Map<String, dynamic> result,
    PptxShapeTextPlan plan,
    String outputPath,
    int slideIndex,
    int shapeId,
  ) async {
    final outputSha = result['outputSha256'];
    if (result.length != 5 ||
        !_matchesSlide(result, plan, slideIndex) ||
        result['shapeId'] is! int ||
        result['shapeId'] != shapeId ||
        outputSha is! String ||
        outputSha == plan.sourceSha256 ||
        !_sha256Pattern.hasMatch(outputSha)) {
      throw _invalidReply;
    }
    await _validateWrittenCandidate(outputPath, outputSha, _invalidReply);
    return PptxShapeTextOutput(
      sourceSha256: plan.sourceSha256,
      outputSha256: outputSha,
      slideCount: plan.slideCount,
      slideIndex: slideIndex,
      shapeId: shapeId,
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

  Future<Map<String, dynamic>> _invoke(Map<String, Object?> request) {
    final library = _libraryPath;
    return Isolate.run(
      () => InkVaultNative.open(libraryPath: library).invoke(request),
    );
  }

  static bool _matchesSlide(
    Map<String, dynamic> result,
    PptxShapeTextPlan plan,
    int slideIndex,
  ) =>
      result['sourceSha256'] == plan.sourceSha256 &&
      result['slideCount'] is int &&
      result['slideCount'] == plan.slideCount &&
      result['slideIndex'] is int &&
      result['slideIndex'] == slideIndex;

  static void _requireSlide(
    String sourcePath,
    PptxShapeTextPlan plan,
    int slideIndex,
  ) {
    _requireSource(sourcePath, plan.sourceSha256);
    if (plan.slideCount > _maxSlides ||
        slideIndex < 0 ||
        slideIndex >= plan.slideCount ||
        plan.slides[slideIndex].index != slideIndex) {
      throw ArgumentError('Expected a slide in the inspected PPTX');
    }
  }

  static void _requireSource(String path, String hash) {
    _requirePath(path);
    if (!_sha256Pattern.hasMatch(hash)) {
      throw ArgumentError('Expected a PPTX SHA-256 digest');
    }
  }

  static void _requireOutputPath(String sourcePath, String outputPath) {
    _requirePath(outputPath);
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
}
