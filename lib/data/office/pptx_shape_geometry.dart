import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/native/ink_vault_native.dart';

final class PptxShapeGeometrySlide {
  const new({required this.index, required this.hidden, this.title});

  final int index;
  final bool hidden;
  final String? title;
}

final class PptxShapeGeometryPlan {
  new({
    required this.sourceSha256,
    required List<PptxShapeGeometrySlide> slides,
  }) : slides = List.unmodifiable(slides);

  final String sourceSha256;
  final List<PptxShapeGeometrySlide> slides;
  int get slideCount => slides.length;
}

final class PptxShapeGeometry {
  const new({
    required this.xEmu,
    required this.yEmu,
    required this.widthEmu,
    required this.heightEmu,
  });

  static const minCoordinate = -2147483648;
  static const maxCoordinate = 2147483647;

  final int xEmu;
  final int yEmu;
  final int widthEmu;
  final int heightEmu;

  bool get isValid =>
      xEmu >= minCoordinate &&
      xEmu <= maxCoordinate &&
      yEmu >= minCoordinate &&
      yEmu <= maxCoordinate &&
      widthEmu > 0 &&
      widthEmu <= maxCoordinate &&
      heightEmu > 0 &&
      heightEmu <= maxCoordinate;

  static int? proportionalExtent(int extent, int original, int other) {
    if (extent <= 0 || original <= 0 || other <= 0) return null;
    final scaled =
        (BigInt.from(extent) * BigInt.from(other) +
            BigInt.from(original ~/ 2)) ~/
        BigInt.from(original);
    if (scaled <= BigInt.zero || scaled > BigInt.from(maxCoordinate)) {
      return null;
    }
    return scaled.toInt();
  }

  @override
  bool operator ==(Object other) =>
      other is PptxShapeGeometry &&
      xEmu == other.xEmu &&
      yEmu == other.yEmu &&
      widthEmu == other.widthEmu &&
      heightEmu == other.heightEmu;

  @override
  int get hashCode => Object.hash(xEmu, yEmu, widthEmu, heightEmu);
}

final class PptxShapeGeometryShape {
  const new({
    required this.shapeId,
    required this.name,
    required this.kind,
    required this.geometry,
    required this.aspectRatioLocked,
    required this.canMove,
    required this.canResize,
  });

  final int shapeId;
  final String name;
  final String kind;
  final PptxShapeGeometry geometry;
  final bool aspectRatioLocked;
  final bool canMove;
  final bool canResize;
}

final class PptxShapeGeometryOutput {
  const new({
    required this.sourceSha256,
    required this.outputSha256,
    required this.slideCount,
    required this.slideIndex,
    required this.shapeId,
    required this.geometry,
  });

  final String sourceSha256;
  final String outputSha256;
  final int slideCount;
  final int slideIndex;
  final int shapeId;
  final PptxShapeGeometry geometry;
}

class PptxShapeGeometryEngine {
  const new({this._libraryPath});

  static const _maxSlides = 256;
  static const _maxShapesPerSlide = 400;
  static const _maxPptxBytes = 128 * 1024 * 1024;
  static final _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');
  static const _invalidReply = InkVaultNativeException(
    'invalid_response',
    'PPTX 개체의 위치, 크기와 원본 판본을 확인하지 못했습니다.',
  );

  final String? _libraryPath;

  Future<PptxShapeGeometryPlan> inspect({
    required String sourcePath,
    required String sourceSha256,
  }) async {
    _requireSource(sourcePath, sourceSha256);
    final result = await _invoke({
      'op': 'pptx_shape_geometry_inspect',
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
    final choices = <PptxShapeGeometrySlide>[];
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
      choices.add(
        PptxShapeGeometrySlide(
          index: index,
          hidden: hidden,
          title: title as String?,
        ),
      );
    }
    return PptxShapeGeometryPlan(sourceSha256: sourceSha256, slides: choices);
  }

  Future<List<PptxShapeGeometryShape>> inspectSlide({
    required String sourcePath,
    required PptxShapeGeometryPlan plan,
    required int slideIndex,
  }) async {
    _requireSlide(sourcePath, plan, slideIndex);
    final result = await _invoke({
      'op': 'pptx_shape_geometry_inspect',
      'sourcePath': sourcePath,
      'sourceSha256': plan.sourceSha256,
      'slideIndex': slideIndex,
    });
    final shapes = result['shapes'];
    if (result.length != 4 ||
        !_matchesSlide(result, plan, slideIndex) ||
        shapes is! List ||
        shapes.length > _maxShapesPerSlide) {
      throw _invalidReply;
    }
    final choices = <PptxShapeGeometryShape>[];
    final ids = <int>{};
    for (final shape in shapes) {
      if (shape is! Map<String, Object?> || shape.length != 10) {
        throw _invalidReply;
      }
      final shapeId = shape['shapeId'];
      final name = shape['name'];
      final kind = shape['kind'];
      final aspectLocked = shape['aspectRatioLocked'];
      final canMove = shape['canMove'];
      final canResize = shape['canResize'];
      if (shapeId is! int ||
          !_validShapeId(shapeId) ||
          !ids.add(shapeId) ||
          name is! String ||
          name.length > 1024 ||
          kind is! String ||
          (kind != 'shape' && kind != 'picture') ||
          aspectLocked is! bool ||
          canMove is! bool ||
          canResize is! bool ||
          (!canMove && !canResize)) {
        throw _invalidReply;
      }
      choices.add(
        PptxShapeGeometryShape(
          shapeId: shapeId,
          name: name,
          kind: kind,
          geometry: _readGeometry(shape),
          aspectRatioLocked: aspectLocked,
          canMove: canMove,
          canResize: canResize,
        ),
      );
    }
    return List.unmodifiable(choices);
  }

  Future<PptxShapeGeometryOutput> replace({
    required String sourcePath,
    required PptxShapeGeometryPlan plan,
    required String outputPath,
    required int slideIndex,
    required PptxShapeGeometryShape shape,
    required PptxShapeGeometry geometry,
  }) async {
    _requireSlide(sourcePath, plan, slideIndex);
    _requirePath(outputPath);
    if (p.equals(sourcePath, outputPath) ||
        !p.equals(p.dirname(sourcePath), p.dirname(outputPath))) {
      throw ArgumentError('Expected separate PPTX files in one working folder');
    }
    final original = shape.geometry;
    final moved =
        geometry.xEmu != original.xEmu || geometry.yEmu != original.yEmu;
    final resized =
        geometry.widthEmu != original.widthEmu ||
        geometry.heightEmu != original.heightEmu;
    if (!_validShapeId(shape.shapeId) ||
        !original.isValid ||
        !geometry.isValid ||
        (!moved && !resized) ||
        (moved && !shape.canMove) ||
        (resized && !shape.canResize) ||
        (resized &&
            shape.aspectRatioLocked &&
            PptxShapeGeometry.proportionalExtent(
                  geometry.widthEmu,
                  original.widthEmu,
                  original.heightEmu,
                ) !=
                geometry.heightEmu &&
            PptxShapeGeometry.proportionalExtent(
                  geometry.heightEmu,
                  original.heightEmu,
                  original.widthEmu,
                ) !=
                geometry.widthEmu)) {
      throw ArgumentError('Expected an allowed change to one PPTX object');
    }
    final result = await _invoke({
      'op': 'pptx_shape_geometry_replace',
      'sourcePath': sourcePath,
      'sourceSha256': plan.sourceSha256,
      'outputPath': outputPath,
      'slideIndex': slideIndex,
      'shapeId': shape.shapeId,
      'xEmu': geometry.xEmu,
      'yEmu': geometry.yEmu,
      'widthEmu': geometry.widthEmu,
      'heightEmu': geometry.heightEmu,
    });
    final outputSha = result['outputSha256'];
    if (result.length != 9 ||
        !_matchesSlide(result, plan, slideIndex) ||
        result['shapeId'] is! int ||
        result['shapeId'] != shape.shapeId ||
        _readGeometry(result) != geometry ||
        outputSha is! String ||
        outputSha == plan.sourceSha256 ||
        !_sha256Pattern.hasMatch(outputSha) ||
        FileSystemEntity.typeSync(outputPath, followLinks: false) !=
            FileSystemEntityType.file) {
      throw _invalidReply;
    }
    final output = File(outputPath);
    final length = await output.length();
    if (length < 1 ||
        length > _maxPptxBytes ||
        (await sha256.bind(output.openRead()).first).toString() != outputSha) {
      throw _invalidReply;
    }
    return PptxShapeGeometryOutput(
      sourceSha256: plan.sourceSha256,
      outputSha256: outputSha,
      slideCount: plan.slideCount,
      slideIndex: slideIndex,
      shapeId: shape.shapeId,
      geometry: geometry,
    );
  }

  Future<Map<String, dynamic>> _invoke(Map<String, Object?> request) {
    final library = _libraryPath;
    return Isolate.run(
      () => InkVaultNative.open(libraryPath: library).invoke(request),
    );
  }

  static PptxShapeGeometry _readGeometry(Map<String, Object?> data) {
    final x = data['xEmu'];
    final y = data['yEmu'];
    final width = data['widthEmu'];
    final height = data['heightEmu'];
    if (x is! int || y is! int || width is! int || height is! int) {
      throw _invalidReply;
    }
    final geometry = PptxShapeGeometry(
      xEmu: x,
      yEmu: y,
      widthEmu: width,
      heightEmu: height,
    );
    if (!geometry.isValid) throw _invalidReply;
    return geometry;
  }

  static bool _validShapeId(int id) => id >= 1 && id <= 0xffffffff;

  static bool _matchesSlide(
    Map<String, dynamic> result,
    PptxShapeGeometryPlan plan,
    int slideIndex,
  ) =>
      result['sourceSha256'] == plan.sourceSha256 &&
      result['slideCount'] is int &&
      result['slideCount'] == plan.slideCount &&
      result['slideIndex'] is int &&
      result['slideIndex'] == slideIndex;

  static void _requireSlide(
    String sourcePath,
    PptxShapeGeometryPlan plan,
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

  static void _requirePath(String path) {
    if (!p.isAbsolute(path) ||
        p.normalize(path) != path ||
        p.extension(path).toLowerCase() != '.pptx') {
      throw ArgumentError('Expected a normalized absolute PPTX path');
    }
  }
}
