import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:saber/data/native/ink_vault_native.dart';
import 'package:saber/data/office/pptx_shape_text.dart';

typedef PptxFindMatch = ({int slideIndex, String snippet, int count});

final class PptxFindReplacePreview {
  new({
    required this.sourceSha256,
    required this.find,
    required this.slideCount,
    required this.matchCount,
    required List<PptxFindMatch> matches,
  }) : matches = List.unmodifiable(matches);

  final String sourceSha256;
  final String find;
  final int slideCount;
  final int matchCount;
  final List<PptxFindMatch> matches;
}

typedef PptxFindReplaceOutput = ({
  String sourceSha256,
  String outputSha256,
  int slideCount,
  int matchCount,
});

class PptxFindReplaceEngine {
  const new({this._libraryPath});

  final String? _libraryPath;
  static const _maxSlides = 256;
  static const _maxMatches = 200;
  static final _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');
  static const _invalidReply = InkVaultNativeException(
    'invalid_response',
    'PPTX에서 찾은 위치와 원본 판본을 확인하지 못했습니다.',
  );

  static bool validFind(String value) =>
      value.isNotEmpty && PptxShapeTextEngine.validText(value);

  static bool validReplacement(String value) =>
      PptxShapeTextEngine.validText(value);

  Future<PptxFindReplacePreview> preview({
    required String sourcePath,
    required String sourceSha256,
    required String find,
  }) async {
    _requireSource(sourcePath, sourceSha256, find);
    final result = await _invoke({
      'op': 'pptx_find_replace_preview',
      'sourcePath': sourcePath,
      'sourceSha256': sourceSha256,
      'find': find,
    });
    final slideCount = result['slideCount'];
    final matchCount = result['matchCount'];
    final entries = result['matches'];
    if (result.length != 4 ||
        result['sourceSha256'] != sourceSha256 ||
        slideCount is! int ||
        slideCount < 1 ||
        slideCount > _maxSlides ||
        matchCount is! int ||
        matchCount < 0 ||
        matchCount > _maxMatches ||
        entries is! List ||
        entries.length > slideCount ||
        entries.length > matchCount) {
      throw _invalidReply;
    }
    final matches = <PptxFindMatch>[];
    var previousSlide = -1;
    var total = 0;
    for (final entry in entries) {
      if (entry is! Map<String, Object?> || entry.length != 3) {
        throw _invalidReply;
      }
      final index = entry['slideIndex'];
      final snippet = entry['snippet'];
      final count = entry['count'];
      if (index is! int ||
          index <= previousSlide ||
          index >= slideCount ||
          snippet is! String ||
          snippet.length > 160 ||
          count is! int ||
          count < 1 ||
          count > matchCount - total) {
        throw _invalidReply;
      }
      matches.add((slideIndex: index, snippet: snippet, count: count));
      previousSlide = index;
      total += count;
    }
    if (total != matchCount) throw _invalidReply;
    return PptxFindReplacePreview(
      sourceSha256: sourceSha256,
      find: find,
      slideCount: slideCount,
      matchCount: matchCount,
      matches: matches,
    );
  }

  Future<PptxFindReplaceOutput> replaceAll({
    required String sourcePath,
    required PptxFindReplacePreview plan,
    required String outputPath,
    required String replacement,
  }) async {
    _requireSource(sourcePath, plan.sourceSha256, plan.find);
    _requirePath(outputPath);
    if (p.equals(sourcePath, outputPath) ||
        !p.equals(p.dirname(sourcePath), p.dirname(outputPath))) {
      throw ArgumentError('Expected separate PPTX files in one working folder');
    }
    if (!validReplacement(replacement) ||
        replacement == plan.find ||
        plan.matchCount < 1 ||
        plan.matchCount > _maxMatches ||
        plan.slideCount < 1 ||
        plan.slideCount > _maxSlides) {
      throw ArgumentError(
        'Expected a valid PPTX replacement and search preview',
      );
    }
    final result = await _invoke({
      'op': 'pptx_find_replace_apply',
      'sourcePath': sourcePath,
      'sourceSha256': plan.sourceSha256,
      'find': plan.find,
      'replacement': replacement,
      'expectedMatchCount': plan.matchCount,
      'outputPath': outputPath,
    });
    final outputSha = result['outputSha256'];
    if (result.length != 4 ||
        result['sourceSha256'] != plan.sourceSha256 ||
        outputSha is! String ||
        !_sha256Pattern.hasMatch(outputSha) ||
        outputSha == plan.sourceSha256 ||
        result['matchCount'] is! int ||
        result['matchCount'] != plan.matchCount ||
        result['slideCount'] is! int ||
        result['slideCount'] != plan.slideCount ||
        FileSystemEntity.typeSync(outputPath, followLinks: false) !=
            FileSystemEntityType.file) {
      throw _invalidReply;
    }
    return (
      sourceSha256: plan.sourceSha256,
      outputSha256: outputSha,
      slideCount: plan.slideCount,
      matchCount: plan.matchCount,
    );
  }

  static void _requireSource(String path, String hash, String find) {
    _requirePath(path);
    if (!_sha256Pattern.hasMatch(hash) || !validFind(find)) {
      throw ArgumentError(
        'Expected a PPTX SHA-256 digest and valid search text',
      );
    }
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
