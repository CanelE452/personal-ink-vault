import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/native/ink_vault_native.dart';
import 'package:saber/data/office/docx_body_text.dart';

enum DocxParagraphPosition {
  before,
  after;

  int insertionIndex(int anchor) => this == before ? anchor : anchor + 1;
}

final class DocxParagraphAnchor {
  const new({
    required this.index,
    required this.text,
    required this.canBefore,
    required this.canAfter,
  });

  final int index;
  final String text;
  final bool canBefore;
  final bool canAfter;

  bool allows(DocxParagraphPosition position) => switch (position) {
    DocxParagraphPosition.before => canBefore,
    DocxParagraphPosition.after => canAfter,
  };
}

final class DocxParagraphInsertPlan {
  new({
    required this.sourceSha256,
    required List<DocxParagraphAnchor> paragraphs,
  }) : paragraphs = List.unmodifiable(paragraphs);

  final String sourceSha256;
  final List<DocxParagraphAnchor> paragraphs;
}

final class DocxParagraphInsertOutput {
  const new({
    required this.sourceSha256,
    required this.outputSha256,
    required this.paragraphIndex,
  });

  final String sourceSha256;
  final String outputSha256;
  final int paragraphIndex;
}

class DocxParagraphInsertEngine {
  const new({this._libraryPath});

  final String? _libraryPath;
  static const _indexLimit = 512;
  static const _maxPreviewLength = 160;
  static const _maxDocxBytes = 128 * 1024 * 1024;
  static final _hashPattern = RegExp(r'^[0-9a-f]{64}$');
  static const _invalidReply = InkVaultNativeException(
    'invalid_response',
    '본문 문단을 추가한 DOCX를 확인하지 못했습니다.',
  );
  static const _invalidPhotoReply = InkVaultNativeException(
    'invalid_response',
    '사진을 추가한 DOCX를 확인하지 못했습니다.',
  );

  static bool validText(String text) =>
      text.trim().isNotEmpty && DocxBodyTextEngine.validText(text);

  Future<DocxParagraphInsertPlan> inspect({
    required String sourcePath,
    required String sourceSha256,
  }) async {
    _requirePath(sourcePath);
    _requireHash(sourceSha256);
    final result = await _invoke({
      'op': 'docx_paragraph_insert_inspect',
      'sourcePath': sourcePath,
      'sourceSha256': sourceSha256,
    });
    final entries = result['paragraphs'];
    if (result.length != 2 ||
        result['sourceSha256'] != sourceSha256 ||
        entries is! List ||
        entries.length > _indexLimit) {
      throw _invalidReply;
    }
    final paragraphs = <DocxParagraphAnchor>[];
    var lastIndex = -1;
    for (final entry in entries) {
      if (entry is! Map<String, Object?> || entry.length != 4) {
        throw _invalidReply;
      }
      final index = entry['index'];
      final text = entry['text'];
      final canBefore = entry['canBefore'];
      final canAfter = entry['canAfter'];
      if (index is! int ||
          index <= lastIndex ||
          index >= _indexLimit ||
          text is! String ||
          text.length > _maxPreviewLength ||
          canBefore is! bool ||
          canAfter is! bool) {
        throw _invalidReply;
      }
      lastIndex = index;
      paragraphs.add(
        DocxParagraphAnchor(
          index: index,
          text: text,
          canBefore: canBefore,
          canAfter: canAfter,
        ),
      );
    }
    return DocxParagraphInsertPlan(
      sourceSha256: sourceSha256,
      paragraphs: paragraphs,
    );
  }

  Future<DocxParagraphInsertOutput> insert({
    required String sourcePath,
    required DocxParagraphInsertPlan plan,
    required String outputPath,
    required int anchorParagraphIndex,
    required DocxParagraphPosition position,
    required String text,
  }) async {
    if (!validText(text)) throw ArgumentError('Expected DOCX paragraph text');
    return _insertAt(
      sourcePath,
      plan,
      outputPath,
      anchorParagraphIndex,
      position,
      {'op': 'docx_paragraph_insert', 'text': text},
      _invalidReply,
    );
  }

  Future<DocxParagraphInsertOutput> insertPhoto({
    required String sourcePath,
    required DocxParagraphInsertPlan plan,
    required String outputPath,
    required int anchorParagraphIndex,
    required DocxParagraphPosition position,
    required String assetPath,
    required String assetSha256,
  }) async {
    _requirePath(assetPath, docx: false);
    _requireHash(assetSha256);
    if (p.equals(sourcePath, assetPath) ||
        p.equals(outputPath, assetPath) ||
        !p.equals(p.dirname(sourcePath), p.dirname(assetPath))) {
      throw ArgumentError('Expected a separate photo in the working folder');
    }
    return _insertAt(
      sourcePath,
      plan,
      outputPath,
      anchorParagraphIndex,
      position,
      {
        'op': 'docx_photo_insert',
        'assetPath': assetPath,
        'assetSha256': assetSha256,
      },
      _invalidPhotoReply,
    );
  }

  Future<DocxParagraphInsertOutput> _insertAt(
    String sourcePath,
    DocxParagraphInsertPlan plan,
    String outputPath,
    int anchorParagraphIndex,
    DocxParagraphPosition position,
    Map<String, Object?> insertion,
    InkVaultNativeException invalidReply,
  ) async {
    _requirePath(sourcePath);
    _requirePath(outputPath);
    _requireHash(plan.sourceSha256);
    if (p.equals(sourcePath, outputPath) ||
        !p.equals(p.dirname(sourcePath), p.dirname(outputPath))) {
      throw ArgumentError('Expected separate DOCX files in one working folder');
    }
    if (anchorParagraphIndex < 0 ||
        anchorParagraphIndex >= _indexLimit ||
        !plan.paragraphs.any(
          (anchor) =>
              anchor.index == anchorParagraphIndex && anchor.allows(position),
        )) {
      throw ArgumentError('Expected an eligible DOCX body location');
    }
    final result = await _invoke({
      'sourcePath': sourcePath,
      'sourceSha256': plan.sourceSha256,
      'outputPath': outputPath,
      'anchorParagraphIndex': anchorParagraphIndex,
      'position': position.name,
      ...insertion,
    });
    final outputSha = result['outputSha256'];
    final paragraphIndex = result['paragraphIndex'];
    if (result.length != 3 ||
        result['sourceSha256'] != plan.sourceSha256 ||
        outputSha is! String ||
        outputSha == plan.sourceSha256 ||
        !_hashPattern.hasMatch(outputSha) ||
        paragraphIndex is! int ||
        paragraphIndex != position.insertionIndex(anchorParagraphIndex) ||
        FileSystemEntity.typeSync(outputPath, followLinks: false) !=
            FileSystemEntityType.file) {
      throw invalidReply;
    }
    final file = File(outputPath);
    final length = await file.length();
    if (length < 1 ||
        length > _maxDocxBytes ||
        (await sha256.bind(file.openRead()).first).toString() != outputSha) {
      throw invalidReply;
    }
    return DocxParagraphInsertOutput(
      sourceSha256: plan.sourceSha256,
      outputSha256: outputSha,
      paragraphIndex: paragraphIndex,
    );
  }

  Future<Map<String, dynamic>> _invoke(Map<String, Object?> request) {
    final library = _libraryPath;
    return Isolate.run(
      () => InkVaultNative.open(libraryPath: library).invoke(request),
    );
  }

  static void _requirePath(String path, {bool docx = true}) {
    if (!p.isAbsolute(path) ||
        p.normalize(path) != path ||
        (docx && p.extension(path).toLowerCase() != '.docx')) {
      throw ArgumentError('Expected a normalized absolute working file path');
    }
  }

  static void _requireHash(String value) {
    if (!_hashPattern.hasMatch(value)) {
      throw ArgumentError('Expected a DOCX SHA-256 digest');
    }
  }
}
