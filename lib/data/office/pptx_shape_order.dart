import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:saber/data/native/ink_vault_native.dart';

typedef PptxShapeOrderSlide = ({int index, bool hidden, String? title});
typedef PptxShapeOrderPlan = ({
  String sourceSha256,
  List<PptxShapeOrderSlide> slides,
});
typedef PptxShapeOrderTarget = ({int shapeId, String name, String kind});
typedef PptxShapeOrderResult = ({
  String sourceSha256,
  String outputSha256,
  int slideCount,
  int slideIndex,
  int shapeId,
  int fromIndex,
  int toIndex,
});

enum PptxShapeOrderDirection {
  front('맨 앞으로'),
  forward('한 단계 앞으로'),
  backward('한 단계 뒤로'),
  back('맨 뒤로');

  new(this.label);

  final String label;

  int? destination(int index, int count) {
    if (index < 0 || index >= count) return null;
    final target = switch (this) {
      front => count - 1,
      forward => index + 1,
      backward => index - 1,
      back => 0,
    };
    return target >= 0 && target < count && target != index ? target : null;
  }
}

class PptxShapeOrderEngine {
  const new({this._libraryPath});

  static const _maxSlides = 256;
  static const _maxShapes = 400;
  static final _hashPattern = RegExp(r'^[0-9a-f]{64}$');
  static const _invalid = InkVaultNativeException(
    'invalid_response',
    'PPTX 개체 순서와 원본 판본을 확인하지 못했습니다.',
  );

  final String? _libraryPath;

  Future<PptxShapeOrderPlan> inspect({
    required String sourcePath,
    required String sourceSha256,
  }) async {
    final result = await _invoke(
      _source('pptx_shape_order_inspect', sourcePath, sourceSha256),
    );
    final slides = result['slides'];
    if (result.length != 3 ||
        result['sourceSha256'] != sourceSha256 ||
        slides is! List ||
        slides.isEmpty ||
        slides.length > _maxSlides ||
        result['slideCount'] is! int ||
        result['slideCount'] != slides.length) {
      throw _invalid;
    }
    final choices = <PptxShapeOrderSlide>[];
    for (final row in slides) {
      if (row is! Map<String, Object?> ||
          row['index'] is! int ||
          row['index'] != choices.length ||
          row['hidden'] is! bool) {
        throw _invalid;
      }
      final title = row['title'];
      if (title != null && (title is! String || title.length > 400)) {
        throw _invalid;
      }
      choices.add((
        index: choices.length,
        hidden: row['hidden'] as bool,
        title: title as String?,
      ));
    }
    return (
      sourceSha256: sourceSha256,
      slides: List<PptxShapeOrderSlide>.unmodifiable(choices),
    );
  }

  Future<List<PptxShapeOrderTarget>> inspectSlide({
    required String sourcePath,
    required PptxShapeOrderPlan plan,
    required int slideIndex,
  }) async {
    final result = await _invoke(
      _slide('pptx_shape_order_inspect', sourcePath, plan, slideIndex),
    );
    final shapes = result['shapes'];
    if (result.length != 4 ||
        !_matchesSlide(result, plan, slideIndex) ||
        shapes is! List ||
        shapes.length > _maxShapes) {
      throw _invalid;
    }
    final ids = <int>{};
    final choices = <PptxShapeOrderTarget>[];
    for (final row in shapes) {
      if (row is! Map<String, Object?> || row.length != 3) throw _invalid;
      final id = row['shapeId'];
      final name = row['name'];
      final kind = row['kind'];
      if (id is! int ||
          !_validId(id) ||
          !ids.add(id) ||
          name is! String ||
          name.length > 1024 ||
          kind is! String ||
          !const {
            'shape',
            'picture',
            'textBox',
            'connector',
            'graphicFrame',
            'group',
          }.contains(kind)) {
        throw _invalid;
      }
      choices.add((shapeId: id, name: name, kind: kind));
    }
    return List.unmodifiable(choices);
  }

  Future<PptxShapeOrderResult> apply({
    required String sourcePath,
    required PptxShapeOrderPlan plan,
    required String outputPath,
    required int slideIndex,
    required int shapeId,
    required PptxShapeOrderDirection direction,
    required int fromIndex,
    required int shapeCount,
  }) async {
    _requirePath(outputPath);
    final destination = direction.destination(fromIndex, shapeCount);
    if (!_validId(shapeId) ||
        shapeCount > _maxShapes ||
        destination == null ||
        p.equals(sourcePath, outputPath) ||
        !p.equals(p.dirname(sourcePath), p.dirname(outputPath))) {
      throw ArgumentError('Expected a new layer for one PPTX object');
    }
    final result = await _invoke({
      ..._slide('pptx_shape_order_apply', sourcePath, plan, slideIndex),
      'outputPath': outputPath,
      'shapeId': shapeId,
      'direction': direction.name,
    });
    final hash = result['outputSha256'];
    if (result.length != 7 ||
        !_matchesSlide(result, plan, slideIndex) ||
        result['shapeId'] is! int ||
        result['shapeId'] != shapeId ||
        result['fromIndex'] is! int ||
        result['fromIndex'] != fromIndex ||
        result['toIndex'] is! int ||
        result['toIndex'] != destination ||
        hash is! String ||
        hash == plan.sourceSha256 ||
        !_hashPattern.hasMatch(hash) ||
        FileSystemEntity.typeSync(outputPath, followLinks: false) !=
            FileSystemEntityType.file) {
      throw _invalid;
    }
    return (
      sourceSha256: plan.sourceSha256,
      outputSha256: hash,
      slideCount: plan.slides.length,
      slideIndex: slideIndex,
      shapeId: shapeId,
      fromIndex: fromIndex,
      toIndex: destination,
    );
  }

  static bool _validId(int id) => id > 0 && id <= 0xffffffff;

  static bool _matchesSlide(
    Map<String, Object?> result,
    PptxShapeOrderPlan plan,
    int index,
  ) =>
      result['sourceSha256'] == plan.sourceSha256 &&
      result['slideCount'] is int &&
      result['slideCount'] == plan.slides.length &&
      result['slideIndex'] is int &&
      result['slideIndex'] == index;

  static Map<String, Object?> _slide(
    String operation,
    String path,
    PptxShapeOrderPlan plan,
    int index,
  ) {
    if (index < 0 ||
        index >= plan.slides.length ||
        plan.slides.length > _maxSlides ||
        plan.slides[index].index != index) {
      throw ArgumentError('Expected a slide in the inspected PPTX');
    }
    return {
      ..._source(operation, path, plan.sourceSha256),
      'slideIndex': index,
    };
  }

  static Map<String, Object?> _source(
    String operation,
    String path,
    String hash,
  ) {
    _requirePath(path);
    if (!_hashPattern.hasMatch(hash)) {
      throw ArgumentError('Expected a PPTX SHA-256 digest');
    }
    return {'op': operation, 'sourcePath': path, 'sourceSha256': hash};
  }

  static void _requirePath(String path) {
    if (!p.isAbsolute(path) ||
        p.normalize(path) != path ||
        p.extension(path).toLowerCase() != '.pptx') {
      throw ArgumentError('Expected a normalized absolute PPTX path');
    }
  }

  Future<Map<String, dynamic>> _invoke(Map<String, Object?> request) {
    final library = _libraryPath;
    return Isolate.run(
      () => InkVaultNative.open(libraryPath: library).invoke(request),
    );
  }
}
