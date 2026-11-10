import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/native/ink_vault_native.dart';

final class PptxSlideInsertLayout {
  const new({required this.id, required this.name, required this.kind});

  final int id;
  final String name;
  final String kind;

  static final _kindPattern = RegExp(r'^[A-Za-z][A-Za-z0-9]{0,31}$');

  static List<PptxSlideInsertLayout>? parseOptions(Object? entries) {
    if (entries is! List || entries.length > 256) return null;
    final ids = <int>{};
    final layouts = <PptxSlideInsertLayout>[];
    for (final entry in entries) {
      if (entry is! Map<String, Object?> || entry.length != 3) return null;
      final id = entry['id'];
      final name = entry['name'];
      final kind = entry['kind'];
      if (id is! int ||
          id <= 0 ||
          id > 0xffffffff ||
          !ids.add(id) ||
          name is! String ||
          name.trim().isEmpty ||
          name.length > 200 ||
          kind is! String ||
          _kindPattern.firstMatch(kind)?.end != kind.length) {
        return null;
      }
      layouts.add(PptxSlideInsertLayout(id: id, name: name, kind: kind));
    }
    return List.unmodifiable(layouts);
  }
}

final class PptxSlideInsertChoice {
  const new({
    required this.index,
    required this.hidden,
    required this.canInsert,
    this.title,
    this.sectionName,
    this.layouts = const [],
  });

  final int index;
  final bool hidden;
  final bool canInsert;
  final String? title;
  final String? sectionName;
  final List<PptxSlideInsertLayout> layouts;
}

final class PptxSlideInsertPlan {
  new({required this.sourceSha256, required List<PptxSlideInsertChoice> slides})
    : slides = List.unmodifiable(slides);

  final String sourceSha256;
  final List<PptxSlideInsertChoice> slides;
  int get slideCount => slides.length;
}

final class PptxSlideInsertOutput {
  const new({
    required this.sourceSha256,
    required this.outputSha256,
    required this.slideCount,
    required this.insertedIndex,
    this.layoutId,
  });

  final String sourceSha256;
  final String outputSha256;
  final int slideCount;
  final int insertedIndex;
  final int? layoutId;
}

class PptxSlideInsertEngine {
  const new({this._libraryPath});

  final String? _libraryPath;
  static const maxSlides = 256;
  static const _maxPptxBytes = 128 * 1024 * 1024;
  static final _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');
  static const _invalidReply = InkVaultNativeException(
    'invalid_response',
    '슬라이드를 추가한 PPTX를 확인하지 못했습니다.',
  );

  Future<PptxSlideInsertPlan> inspect({
    required String sourcePath,
    required String sourceSha256,
  }) async {
    _requirePath(sourcePath);
    _requireHash(sourceSha256);
    final result = await _invoke({
      'op': 'pptx_insert_inspect',
      'sourcePath': sourcePath,
      'sourceSha256': sourceSha256,
      'includeLayouts': true,
    });
    final slides = result['slides'];
    if (result.length != 3 ||
        result['sourceSha256'] != sourceSha256 ||
        result['slideCount'] is! int ||
        slides is! List ||
        slides.isEmpty ||
        slides.length > maxSlides ||
        result['slideCount'] != slides.length) {
      throw _invalidReply;
    }
    final choices = <PptxSlideInsertChoice>[];
    for (final slide in slides) {
      if (slide is! Map<String, Object?> ||
          !slide.keys.every(
            const {
              'index',
              'hidden',
              'canInsert',
              'title',
              'sectionName',
              'layouts',
            }.contains,
          )) {
        throw _invalidReply;
      }
      final index = slide['index'];
      final hidden = slide['hidden'];
      final canInsert = slide['canInsert'];
      final title = slide['title'];
      final sectionName = slide['sectionName'];
      if (index is! int ||
          index != choices.length ||
          hidden is! bool ||
          canInsert is! bool ||
          (title != null && (title is! String || title.length > 200)) ||
          (sectionName != null &&
              (sectionName is! String || sectionName.length > 200))) {
        throw _invalidReply;
      }
      final layouts = slide.containsKey('layouts')
          ? _parseLayouts(slide['layouts'])
          : const <PptxSlideInsertLayout>[];
      if (layouts.isNotEmpty && (!canInsert || slides.length >= maxSlides)) {
        throw _invalidReply;
      }
      choices.add(
        PptxSlideInsertChoice(
          index: index,
          hidden: hidden,
          canInsert: canInsert && slides.length < maxSlides,
          title: title as String?,
          sectionName: sectionName as String?,
          layouts: layouts,
        ),
      );
    }
    return PptxSlideInsertPlan(sourceSha256: sourceSha256, slides: choices);
  }

  List<PptxSlideInsertLayout> _parseLayouts(Object? entries) {
    final layouts = PptxSlideInsertLayout.parseOptions(entries);
    if (layouts == null || layouts.isEmpty) throw _invalidReply;
    return layouts;
  }

  Future<PptxSlideInsertOutput> insert({
    required String sourcePath,
    required PptxSlideInsertPlan plan,
    required String outputPath,
    required int slideIndex,
    int? layoutId,
  }) async {
    _requirePath(sourcePath);
    _requirePath(outputPath);
    _requireHash(plan.sourceSha256);
    if (p.equals(sourcePath, outputPath) ||
        !p.equals(p.dirname(sourcePath), p.dirname(outputPath))) {
      throw ArgumentError('Expected separate PPTX files in one working folder');
    }
    if (plan.slideCount < 1 ||
        plan.slideCount >= maxSlides ||
        slideIndex < 0 ||
        slideIndex >= plan.slideCount ||
        plan.slides[slideIndex].index != slideIndex ||
        !plan.slides[slideIndex].canInsert) {
      throw const InkVaultNativeException(
        'unsupported_slide',
        '이 슬라이드 뒤에 빈 슬라이드를 추가할 수 없습니다.',
      );
    }
    if (layoutId != null &&
        !plan.slides[slideIndex].layouts.any(
          (layout) => layout.id == layoutId,
        )) {
      throw const InkVaultNativeException(
        'unsupported_slide',
        '이 위치에 사용할 수 있는 슬라이드 레이아웃을 다시 선택하세요.',
      );
    }
    final result = await _invoke({
      'op': 'pptx_insert_apply',
      'sourcePath': sourcePath,
      'sourceSha256': plan.sourceSha256,
      'outputPath': outputPath,
      'slideIndex': slideIndex,
      'layoutId': ?layoutId,
    });
    final outputSha = result['outputSha256'];
    final count = result['slideCount'];
    if (result.length != (layoutId == null ? 4 : 5) ||
        result['sourceSha256'] != plan.sourceSha256 ||
        outputSha is! String ||
        outputSha == plan.sourceSha256 ||
        !_sha256Pattern.hasMatch(outputSha) ||
        count is! int ||
        count != plan.slideCount + 1 ||
        result['insertedIndex'] is! int ||
        result['insertedIndex'] != slideIndex + 1 ||
        result.containsKey('layoutId') != (layoutId != null) ||
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
    return PptxSlideInsertOutput(
      sourceSha256: plan.sourceSha256,
      outputSha256: outputSha,
      slideCount: count,
      insertedIndex: slideIndex + 1,
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

  static void _requireHash(String value) {
    if (!_sha256Pattern.hasMatch(value)) {
      throw ArgumentError('Expected a PPTX SHA-256 digest');
    }
  }
}
