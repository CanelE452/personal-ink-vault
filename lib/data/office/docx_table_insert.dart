import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/native/ink_vault_native.dart';

final class DocxTableParagraph {
  const new({required this.index, required this.text});

  final int index;
  final String text;
}

final class DocxTableInsertPlan {
  new({
    required this.sourceSha256,
    required List<DocxTableParagraph> paragraphs,
  }) : paragraphs = List.unmodifiable(paragraphs);

  final String sourceSha256;
  final List<DocxTableParagraph> paragraphs;
}

final class DocxTableInsertOutput {
  const new({
    required this.sourceSha256,
    required this.outputSha256,
    required this.afterParagraphIndex,
    required this.rows,
    required this.columns,
    required this.tableIndex,
  });

  final String sourceSha256;
  final String outputSha256;
  final int? afterParagraphIndex;
  final int rows;
  final int columns;
  final int tableIndex;
}

class DocxTableInsertEngine {
  const new({this._libraryPath});

  final String? _libraryPath;
  static const maxRows = 8;
  static const maxColumns = 6;
  static const maxCellLength = 400;
  static const _maxParagraphs = 512;
  static const _maxPreviewLength = 160;
  static const _maxDocxBytes = 128 * 1024 * 1024;
  static final _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');
  static final _invalidCellCharacters = RegExp(
    r'[\u0000-\u001f\u007f-\u009f\u2028\u2029\ufffe\uffff]',
  );
  static const _invalidReply = InkVaultNativeException(
    'invalid_response',
    '표를 추가한 DOCX를 확인하지 못했습니다.',
  );

  static bool validCellText(String text) =>
      text.length <= maxCellLength && !_invalidCellCharacters.hasMatch(text);

  Future<DocxTableInsertPlan> inspect({
    required String sourcePath,
    required String sourceSha256,
  }) async {
    _requirePath(sourcePath);
    _requireHash(sourceSha256);
    final result = await _invoke({
      'op': 'docx_table_inspect',
      'sourcePath': sourcePath,
      'sourceSha256': sourceSha256,
    });
    final rows = result['paragraphs'];
    if (result.length != 2 ||
        result['sourceSha256'] != sourceSha256 ||
        rows is! List ||
        rows.length > _maxParagraphs) {
      throw _invalidReply;
    }
    final paragraphs = <DocxTableParagraph>[];
    for (final row in rows) {
      if (row is! Map<String, Object?> || row.length != 2) {
        throw _invalidReply;
      }
      final index = row['index'];
      final text = row['text'];
      if (index is! int ||
          index != paragraphs.length ||
          text is! String ||
          text.length > _maxPreviewLength) {
        throw _invalidReply;
      }
      paragraphs.add(DocxTableParagraph(index: index, text: text));
    }
    return DocxTableInsertPlan(
      sourceSha256: sourceSha256,
      paragraphs: paragraphs,
    );
  }

  Future<DocxTableInsertOutput> insert({
    required String sourcePath,
    required DocxTableInsertPlan plan,
    required String outputPath,
    required int? afterParagraphIndex,
    required List<List<String>> cells,
  }) async {
    _requirePath(sourcePath);
    _requirePath(outputPath);
    _requireHash(plan.sourceSha256);
    if (p.equals(sourcePath, outputPath) ||
        !p.equals(p.dirname(sourcePath), p.dirname(outputPath))) {
      throw ArgumentError('Expected separate DOCX files in one working folder');
    }
    if (afterParagraphIndex != null &&
        (afterParagraphIndex < 0 ||
            afterParagraphIndex >= plan.paragraphs.length ||
            plan.paragraphs[afterParagraphIndex].index !=
                afterParagraphIndex)) {
      throw ArgumentError('Expected a DOCX body paragraph');
    }
    final rows = cells.length;
    final columns = cells.isEmpty ? 0 : cells.first.length;
    if (rows < 1 ||
        rows > maxRows ||
        columns < 1 ||
        columns > maxColumns ||
        !cells.every(
          (row) => row.length == columns && row.every(validCellText),
        )) {
      throw ArgumentError('Expected rectangular DOCX table cells');
    }
    final result = await _invoke({
      'op': 'docx_table_insert',
      'sourcePath': sourcePath,
      'sourceSha256': plan.sourceSha256,
      'outputPath': outputPath,
      'afterParagraphIndex': afterParagraphIndex,
      'cells': cells,
    });
    final outputSha = result['outputSha256'];
    final tableIndex = result['tableIndex'];
    if (result.length != 6 ||
        result['sourceSha256'] != plan.sourceSha256 ||
        outputSha is! String ||
        outputSha == plan.sourceSha256 ||
        !_sha256Pattern.hasMatch(outputSha) ||
        !result.containsKey('afterParagraphIndex') ||
        result['afterParagraphIndex'] != afterParagraphIndex ||
        result['rows'] is! int ||
        result['rows'] != rows ||
        result['columns'] is! int ||
        result['columns'] != columns ||
        tableIndex is! int ||
        tableIndex < 0 ||
        FileSystemEntity.typeSync(outputPath, followLinks: false) !=
            FileSystemEntityType.file) {
      throw _invalidReply;
    }
    final file = File(outputPath);
    final length = await file.length();
    if (length < 1 ||
        length > _maxDocxBytes ||
        (await sha256.bind(file.openRead()).first).toString() != outputSha) {
      throw _invalidReply;
    }
    return DocxTableInsertOutput(
      sourceSha256: plan.sourceSha256,
      outputSha256: outputSha,
      afterParagraphIndex: afterParagraphIndex,
      rows: rows,
      columns: columns,
      tableIndex: tableIndex,
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
        p.extension(path).toLowerCase() != '.docx') {
      throw ArgumentError('Expected a normalized absolute DOCX path');
    }
  }

  static void _requireHash(String value) {
    if (!_sha256Pattern.hasMatch(value)) {
      throw ArgumentError('Expected a DOCX SHA-256 digest');
    }
  }
}
