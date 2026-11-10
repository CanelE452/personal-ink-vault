import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:saber/data/native/ink_vault_native.dart';
import 'package:saber/data/office/docx_body_text.dart';

typedef DocxFindMatch = ({int paragraphIndex, String snippet, int count});

final class DocxFindReplacePreview {
  new({
    required this.sourceSha256,
    required this.find,
    required this.matchCount,
    required List<DocxFindMatch> matches,
  }) : matches = List.unmodifiable(matches);

  final String sourceSha256;
  final String find;
  final int matchCount;
  final List<DocxFindMatch> matches;

  int get paragraphCount => matches.length;
}

typedef DocxFindReplaceOutput = ({
  String sourceSha256,
  String outputSha256,
  int matchCount,
  int paragraphCount,
});

class DocxFindReplaceEngine {
  const new({this._libraryPath});

  final String? _libraryPath;
  static const _maxMatches = 200;
  static final _hashPattern = RegExp(r'^[0-9a-f]{64}$');
  static const _invalidReply = InkVaultNativeException(
    'invalid_response',
    'DOCX에서 찾은 위치와 원본 판본을 확인하지 못했습니다.',
  );

  static bool validFind(String value) =>
      value.isNotEmpty && DocxBodyTextEngine.validText(value);

  static bool validReplacement(String value) =>
      DocxBodyTextEngine.validText(value);

  Future<DocxFindReplacePreview> preview({
    required String sourcePath,
    required String sourceSha256,
    required String find,
  }) async {
    _requireSource(sourcePath, sourceSha256, find);
    final result = await _invoke({
      'op': 'docx_find_replace_preview',
      'sourcePath': sourcePath,
      'sourceSha256': sourceSha256,
      'find': find,
    });
    final matchCount = result['matchCount'];
    final paragraphCount = result['paragraphCount'];
    final entries = result['matches'];
    if (result.length != 4 ||
        result['sourceSha256'] != sourceSha256 ||
        matchCount is! int ||
        matchCount < 0 ||
        matchCount > _maxMatches ||
        paragraphCount is! int ||
        paragraphCount < 0 ||
        paragraphCount > matchCount ||
        entries is! List ||
        entries.length != paragraphCount) {
      throw _invalidReply;
    }
    final matches = <DocxFindMatch>[];
    var lastParagraph = -1;
    var total = 0;
    for (final entry in entries) {
      if (entry is! Map<String, Object?> || entry.length != 3) {
        throw _invalidReply;
      }
      final index = entry['paragraphIndex'];
      final snippet = entry['snippet'];
      final count = entry['count'];
      if (index is! int ||
          index <= lastParagraph ||
          snippet is! String ||
          snippet.length > 160 ||
          count is! int ||
          count < 1 ||
          count > matchCount - total) {
        throw _invalidReply;
      }
      matches.add((paragraphIndex: index, snippet: snippet, count: count));
      lastParagraph = index;
      total += count;
    }
    if (total != matchCount) throw _invalidReply;
    return DocxFindReplacePreview(
      sourceSha256: sourceSha256,
      find: find,
      matchCount: matchCount,
      matches: matches,
    );
  }

  Future<DocxFindReplaceOutput> replaceAll({
    required String sourcePath,
    required DocxFindReplacePreview plan,
    required String outputPath,
    required String replacement,
  }) async {
    _requireSource(sourcePath, plan.sourceSha256, plan.find);
    _requirePath(outputPath);
    if (p.equals(sourcePath, outputPath) ||
        !p.equals(p.dirname(sourcePath), p.dirname(outputPath))) {
      throw ArgumentError('Expected separate DOCX files in one working folder');
    }
    if (!validReplacement(replacement) ||
        replacement == plan.find ||
        plan.matchCount < 1 ||
        plan.matchCount > _maxMatches ||
        plan.paragraphCount < 1 ||
        plan.paragraphCount > plan.matchCount) {
      throw ArgumentError(
        'Expected a valid DOCX replacement and search preview',
      );
    }
    final result = await _invoke({
      'op': 'docx_find_replace_apply',
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
        !_hashPattern.hasMatch(outputSha) ||
        outputSha == plan.sourceSha256 ||
        result['matchCount'] is! int ||
        result['matchCount'] != plan.matchCount ||
        result['paragraphCount'] is! int ||
        result['paragraphCount'] != plan.paragraphCount ||
        FileSystemEntity.typeSync(outputPath, followLinks: false) !=
            FileSystemEntityType.file) {
      throw _invalidReply;
    }
    return (
      sourceSha256: plan.sourceSha256,
      outputSha256: outputSha,
      matchCount: plan.matchCount,
      paragraphCount: plan.paragraphCount,
    );
  }

  static void _requireSource(String path, String hash, String find) {
    _requirePath(path);
    if (!_hashPattern.hasMatch(hash) || !validFind(find)) {
      throw ArgumentError(
        'Expected a DOCX SHA-256 digest and valid search text',
      );
    }
  }

  static void _requirePath(String path) {
    if (!p.isAbsolute(path) ||
        p.normalize(path) != path ||
        p.extension(path).toLowerCase() != '.docx') {
      throw ArgumentError('Expected a normalized absolute DOCX path');
    }
  }

  Future<Map<String, dynamic>> _invoke(Map<String, Object?> request) {
    final library = _libraryPath;
    return Isolate.run(
      () => InkVaultNative.open(libraryPath: library).invoke(request),
    );
  }
}
