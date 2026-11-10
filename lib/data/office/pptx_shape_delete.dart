import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/native/ink_vault_native.dart';

typedef PptxShapeDeleteSlide = ({int index, bool hidden, String? title});
typedef PptxShapeDeleteTarget = ({int shapeId, String name, String kind});
typedef PptxShapeDeleteOutput = ({
  String sourceSha256,
  String outputSha256,
  int slideCount,
  int slideIndex,
  int shapeId,
});

final class PptxShapeDeletePlan {
  new({required this.sourceSha256, required List<PptxShapeDeleteSlide> slides})
    : slides = List.unmodifiable(slides);

  final String sourceSha256;
  final List<PptxShapeDeleteSlide> slides;
  int get slideCount => slides.length;
}

class PptxShapeDeleteEngine {
  const new({this._libraryPath});

  final String? _libraryPath;
  static const _maxSlides = 256;
  static const _maxShapes = 400;
  static const _maxPptxBytes = 128 * 1024 * 1024;
  static final _sha256 = RegExp(r'^[0-9a-f]{64}$');
  static const _invalidReply = InkVaultNativeException(
    'invalid_response',
    '삭제할 도형과 PPTX 판본을 확인하지 못했습니다.',
  );

  Future<PptxShapeDeletePlan> inspect({
    required String sourcePath,
    required String sourceSha256,
  }) async {
    _requireSource(sourcePath, sourceSha256);
    final result = await _invoke({
      'op': 'pptx_shape_delete_inspect',
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
    final choices = <PptxShapeDeleteSlide>[];
    for (final slide in slides) {
      if (slide is! Map<String, Object?> ||
          !slide.keys.every(const {'index', 'hidden', 'title'}.contains)) {
        throw _invalidReply;
      }
      final index = slide['index'];
      final hidden = slide['hidden'];
      final title = slide['title'];
      if (index is! int ||
          index != choices.length ||
          hidden is! bool ||
          (title != null && (title is! String || title.length > 200))) {
        throw _invalidReply;
      }
      choices.add((index: index, hidden: hidden, title: title as String?));
    }
    return PptxShapeDeletePlan(sourceSha256: sourceSha256, slides: choices);
  }

  Future<List<PptxShapeDeleteTarget>> inspectSlide({
    required String sourcePath,
    required PptxShapeDeletePlan plan,
    required int slideIndex,
  }) async {
    _requireSlide(sourcePath, plan, slideIndex);
    final result = await _invoke({
      'op': 'pptx_shape_delete_inspect',
      'sourcePath': sourcePath,
      'sourceSha256': plan.sourceSha256,
      'slideIndex': slideIndex,
    });
    final shapes = result['shapes'];
    if (result.length != 4 ||
        !_matchesSlide(result, plan, slideIndex) ||
        shapes is! List ||
        shapes.length > _maxShapes) {
      throw _invalidReply;
    }
    final choices = <PptxShapeDeleteTarget>[];
    final ids = <int>{};
    for (final shape in shapes) {
      if (shape is! Map<String, Object?> || shape.length != 3) {
        throw _invalidReply;
      }
      final shapeId = shape['shapeId'];
      final name = shape['name'];
      final kind = shape['kind'];
      if (shapeId is! int ||
          !_validShapeId(shapeId) ||
          !ids.add(shapeId) ||
          name is! String ||
          name.length > 1024 ||
          kind is! String ||
          !const {'shape', 'textBox', 'freeform'}.contains(kind)) {
        throw _invalidReply;
      }
      choices.add((shapeId: shapeId, name: name, kind: kind));
    }
    return List.unmodifiable(choices);
  }

  Future<PptxShapeDeleteOutput> delete({
    required String sourcePath,
    required PptxShapeDeletePlan plan,
    required String outputPath,
    required int slideIndex,
    required int shapeId,
  }) async {
    _requireSlide(sourcePath, plan, slideIndex);
    _requirePath(outputPath);
    if (p.equals(sourcePath, outputPath) ||
        !p.equals(p.dirname(sourcePath), p.dirname(outputPath))) {
      throw ArgumentError('Expected separate PPTX files in one working folder');
    }
    if (!_validShapeId(shapeId)) throw ArgumentError.value(shapeId, 'shapeId');
    final result = await _invoke({
      'op': 'pptx_shape_delete',
      'sourcePath': sourcePath,
      'sourceSha256': plan.sourceSha256,
      'outputPath': outputPath,
      'slideIndex': slideIndex,
      'shapeId': shapeId,
    });
    final outputSha = result['outputSha256'];
    if (result.length != 5 ||
        !_matchesSlide(result, plan, slideIndex) ||
        result['shapeId'] is! int ||
        result['shapeId'] != shapeId ||
        outputSha is! String ||
        !_sha256.hasMatch(outputSha) ||
        outputSha == plan.sourceSha256 ||
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
      slideCount: plan.slideCount,
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

  static bool _matchesSlide(
    Map<String, dynamic> result,
    PptxShapeDeletePlan plan,
    int index,
  ) =>
      result['sourceSha256'] == plan.sourceSha256 &&
      result['slideCount'] is int &&
      result['slideCount'] == plan.slideCount &&
      result['slideIndex'] is int &&
      result['slideIndex'] == index;

  static bool _validShapeId(int id) => id >= 1 && id <= 0xffffffff;

  static void _requireSlide(
    String sourcePath,
    PptxShapeDeletePlan plan,
    int index,
  ) {
    _requireSource(sourcePath, plan.sourceSha256);
    if (plan.slideCount > _maxSlides ||
        index < 0 ||
        index >= plan.slideCount ||
        plan.slides[index].index != index) {
      throw ArgumentError('Expected a slide in the inspected PPTX');
    }
  }

  static void _requireSource(String path, String hash) {
    _requirePath(path);
    if (!_sha256.hasMatch(hash)) {
      throw ArgumentError('Expected a PPTX SHA-256 digest');
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
