import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/native/ink_vault_native.dart';

final class DocxBodyTextRun {
  const new({required this.runIndex, required this.text});

  final int runIndex;
  final String text;
}

final class DocxBodyTextParagraph {
  new({required this.paragraphIndex, required List<DocxBodyTextRun> runs})
    : runs = List.unmodifiable(runs);

  final int paragraphIndex;
  final List<DocxBodyTextRun> runs;
}

final class DocxBodyTextPlan {
  new({
    required this.sourceSha256,
    required List<DocxBodyTextParagraph> paragraphs,
  }) : paragraphs = List.unmodifiable(paragraphs);

  final String sourceSha256;
  final List<DocxBodyTextParagraph> paragraphs;
}

final class DocxBodyTextOutput {
  const new({
    required this.sourceSha256,
    required this.outputSha256,
    required this.paragraphIndex,
    required this.runIndex,
  });

  final String sourceSha256;
  final String outputSha256;
  final int paragraphIndex;
  final int runIndex;
}

typedef DocxTableCellAddress = ({int tableIndex, int rowIndex, int cellIndex});

final class DocxTableCellText {
  new({required this.address, required List<DocxBodyTextParagraph> paragraphs})
    : paragraphs = List.unmodifiable(paragraphs);

  final DocxTableCellAddress address;
  final List<DocxBodyTextParagraph> paragraphs;
}

final class DocxTableCellTextPlan {
  new({required this.sourceSha256, required List<DocxTableCellText> cells})
    : cells = List.unmodifiable(cells);

  final String sourceSha256;
  final List<DocxTableCellText> cells;
}

final class DocxTableCellTextOutput {
  const new({
    required this.sourceSha256,
    required this.outputSha256,
    required this.address,
    required this.paragraphIndex,
    required this.runIndex,
  });

  final String sourceSha256;
  final String outputSha256;
  final DocxTableCellAddress address;
  final int paragraphIndex;
  final int runIndex;
}

final class _DocxTextBounds {
  var runCount = 0;
  var textLength = 0;
}

class DocxBodyTextEngine {
  const new({this._libraryPath});

  final String? _libraryPath;
  static const maxRunLength = 2000;
  static const _indexLimit = 512;
  static const _maxRuns = 400;
  static const _maxTotalLength = 150000;
  static const _maxDocxBytes = 128 * 1024 * 1024;
  static final _hashPattern = RegExp(r'^[0-9a-f]{64}$');
  static final _invalidCharacters = RegExp(
    r'[\u0000-\u001f\u007f-\u009f\u2028\u2029\ud800-\udfff\ufffe\uffff]',
    unicode: true,
  );
  static const _invalidReply = InkVaultNativeException(
    'invalid_response',
    'DOCX 편집 대상과 원본 판본을 확인하지 못했습니다.',
  );

  static bool validText(String text) =>
      text.length <= maxRunLength && !_invalidCharacters.hasMatch(text);

  Future<DocxBodyTextPlan> inspect({
    required String sourcePath,
    required String sourceSha256,
  }) async {
    final result = await _inspect(sourcePath, sourceSha256);
    return DocxBodyTextPlan(
      sourceSha256: sourceSha256,
      paragraphs: _readParagraphs(result['paragraphs'], _DocxTextBounds()),
    );
  }

  Future<DocxTableCellTextPlan> inspectCells({
    required String sourcePath,
    required String sourceSha256,
  }) async {
    final result = await _inspect(sourcePath, sourceSha256, tableCells: true);
    final entries = result['cells'];
    if (entries is! List || entries.length > _maxRuns) throw _invalidReply;

    final cells = <DocxTableCellText>[];
    final bounds = _DocxTextBounds();
    var lastCell = -1;
    for (final entry in entries) {
      if (entry is! Map<String, Object?> || entry.length != 4) {
        throw _invalidReply;
      }
      final address = _readCellAddress(entry);
      final cellOrder =
          (address.tableIndex * _indexLimit + address.rowIndex) * _indexLimit +
          address.cellIndex;
      if (cellOrder <= lastCell) throw _invalidReply;
      lastCell = cellOrder;
      final paragraphs = _readParagraphs(entry['paragraphs'], bounds);
      if (paragraphs.isEmpty) throw _invalidReply;
      cells.add(DocxTableCellText(address: address, paragraphs: paragraphs));
    }
    return DocxTableCellTextPlan(sourceSha256: sourceSha256, cells: cells);
  }

  Future<Map<String, dynamic>> _inspect(
    String sourcePath,
    String sourceSha256, {
    bool tableCells = false,
  }) async {
    _requirePath(sourcePath);
    _requireHash(sourceSha256);
    final result = await _invoke({
      'op': 'docx_text_inspect',
      'sourcePath': sourcePath,
      'sourceSha256': sourceSha256,
      if (tableCells) 'tableCells': true,
    });
    if (result.length != 2 || result['sourceSha256'] != sourceSha256) {
      throw _invalidReply;
    }
    return result;
  }

  static List<DocxBodyTextParagraph> _readParagraphs(
    Object? entries,
    _DocxTextBounds bounds,
  ) {
    if (entries is! List || entries.length > _maxRuns - bounds.runCount) {
      throw _invalidReply;
    }
    final paragraphs = <DocxBodyTextParagraph>[];
    var lastParagraph = -1;
    for (final entry in entries) {
      if (entry is! Map<String, Object?> || entry.length != 2) {
        throw _invalidReply;
      }
      final paragraphIndex = entry['paragraphIndex'];
      final items = entry['runs'];
      if (paragraphIndex is! int ||
          paragraphIndex <= lastParagraph ||
          paragraphIndex >= _indexLimit ||
          items is! List ||
          items.isEmpty ||
          items.length > _maxRuns - bounds.runCount) {
        throw _invalidReply;
      }
      lastParagraph = paragraphIndex;
      bounds.runCount += items.length;
      final runs = <DocxBodyTextRun>[];
      var lastRun = -1;
      for (final item in items) {
        if (item is! Map<String, Object?> || item.length != 2) {
          throw _invalidReply;
        }
        final runIndex = item['runIndex'];
        final text = item['text'];
        if (runIndex is! int ||
            runIndex <= lastRun ||
            runIndex >= _indexLimit ||
            text is! String ||
            !validText(text)) {
          throw _invalidReply;
        }
        lastRun = runIndex;
        bounds.textLength += text.length;
        if (bounds.textLength > _maxTotalLength) throw _invalidReply;
        runs.add(DocxBodyTextRun(runIndex: runIndex, text: text));
      }
      paragraphs.add(
        DocxBodyTextParagraph(paragraphIndex: paragraphIndex, runs: runs),
      );
    }
    return paragraphs;
  }

  Future<DocxBodyTextOutput> replace({
    required String sourcePath,
    required DocxBodyTextPlan plan,
    required String outputPath,
    required int paragraphIndex,
    required int runIndex,
    required String text,
  }) async {
    final outputSha = await _replace(
      sourcePath: sourcePath,
      sourceSha256: plan.sourceSha256,
      paragraphs: plan.paragraphs,
      outputPath: outputPath,
      paragraphIndex: paragraphIndex,
      runIndex: runIndex,
      text: text,
    );
    return DocxBodyTextOutput(
      sourceSha256: plan.sourceSha256,
      outputSha256: outputSha,
      paragraphIndex: paragraphIndex,
      runIndex: runIndex,
    );
  }

  Future<DocxTableCellTextOutput> replaceCell({
    required String sourcePath,
    required DocxTableCellTextPlan plan,
    required String outputPath,
    required DocxTableCellAddress address,
    required int paragraphIndex,
    required int runIndex,
    required String text,
  }) async {
    if (!_validCellAddress(address)) {
      throw ArgumentError('Expected a valid DOCX table cell address');
    }
    final cell = plan.cells
        .where((item) => item.address == address)
        .firstOrNull;
    final outputSha = await _replace(
      sourcePath: sourcePath,
      sourceSha256: plan.sourceSha256,
      paragraphs: cell?.paragraphs ?? const [],
      outputPath: outputPath,
      paragraphIndex: paragraphIndex,
      runIndex: runIndex,
      text: text,
      address: address,
    );
    return DocxTableCellTextOutput(
      sourceSha256: plan.sourceSha256,
      outputSha256: outputSha,
      address: address,
      paragraphIndex: paragraphIndex,
      runIndex: runIndex,
    );
  }

  Future<String> _replace({
    required String sourcePath,
    required String sourceSha256,
    required List<DocxBodyTextParagraph> paragraphs,
    required String outputPath,
    required int paragraphIndex,
    required int runIndex,
    required String text,
    DocxTableCellAddress? address,
  }) async {
    _requirePath(sourcePath);
    _requirePath(outputPath);
    _requireHash(sourceSha256);
    if (p.equals(sourcePath, outputPath) ||
        !p.equals(p.dirname(sourcePath), p.dirname(outputPath))) {
      throw ArgumentError('Expected separate DOCX files in one working folder');
    }
    final paragraph = paragraphs
        .where((item) => item.paragraphIndex == paragraphIndex)
        .firstOrNull;
    final run = paragraph?.runs
        .where((item) => item.runIndex == runIndex)
        .firstOrNull;
    if (!_validIndex(paragraphIndex) ||
        !_validIndex(runIndex) ||
        run == null ||
        text == run.text ||
        !validText(text)) {
      throw ArgumentError('Expected changed text in an editable DOCX run');
    }
    final result = await _invoke({
      'op': 'docx_text_replace',
      'sourcePath': sourcePath,
      'sourceSha256': sourceSha256,
      'outputPath': outputPath,
      'paragraphIndex': paragraphIndex,
      'runIndex': runIndex,
      'text': text,
      if (address != null) ...{
        'tableIndex': address.tableIndex,
        'rowIndex': address.rowIndex,
        'cellIndex': address.cellIndex,
      },
    });
    final outputSha = result['outputSha256'];
    if (result.length != (address == null ? 4 : 7) ||
        result['sourceSha256'] != sourceSha256 ||
        outputSha is! String ||
        outputSha == sourceSha256 ||
        !_hashPattern.hasMatch(outputSha) ||
        result['paragraphIndex'] is! int ||
        result['paragraphIndex'] != paragraphIndex ||
        result['runIndex'] is! int ||
        result['runIndex'] != runIndex ||
        (address != null && _readCellAddress(result) != address) ||
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
    return outputSha;
  }

  static DocxTableCellAddress _readCellAddress(Map<String, Object?> entry) {
    final tableIndex = entry['tableIndex'];
    final rowIndex = entry['rowIndex'];
    final cellIndex = entry['cellIndex'];
    if (tableIndex is! int || rowIndex is! int || cellIndex is! int) {
      throw _invalidReply;
    }
    final address = (
      tableIndex: tableIndex,
      rowIndex: rowIndex,
      cellIndex: cellIndex,
    );
    if (!_validCellAddress(address)) throw _invalidReply;
    return address;
  }

  static bool _validCellAddress(DocxTableCellAddress address) =>
      _validIndex(address.tableIndex) &&
      _validIndex(address.rowIndex) &&
      _validIndex(address.cellIndex);

  static bool _validIndex(int index) => index >= 0 && index < _indexLimit;

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
    if (!_hashPattern.hasMatch(value)) {
      throw ArgumentError('Expected a DOCX SHA-256 digest');
    }
  }
}
