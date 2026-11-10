import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/native/ink_vault_native.dart';

enum DocxTableStructureAction {
  insertRow,
  deleteRow,
  insertColumn,
  deleteColumn;

  bool get isRow => this == insertRow || this == deleteRow;
  bool get isDelete => this == deleteRow || this == deleteColumn;
  int get rowDelta => isRow ? (isDelete ? -1 : 1) : 0;
  int get columnDelta => isRow ? 0 : (isDelete ? -1 : 1);
}

final class DocxTableStructureTable {
  const new({
    required this.tableIndex,
    required this.rowCount,
    required this.columnCount,
    required this.preview,
  });

  final int tableIndex;
  final int rowCount;
  final int columnCount;
  final String preview;

  int countFor(DocxTableStructureAction action) =>
      action.isRow ? rowCount : columnCount;

  bool allows(DocxTableStructureAction action) =>
      DocxTableStructureEngine._validDimensions(rowCount, columnCount) &&
      DocxTableStructureEngine._validDimensions(
        rowCount + action.rowDelta,
        columnCount + action.columnDelta,
      );

  bool allowsPosition(
    DocxTableStructureAction action,
    int index, {
    int? anchorIndex,
  }) {
    if (!allows(action)) return false;
    final count = countFor(action);
    if (action.isDelete) {
      return anchorIndex == null && index >= 0 && index < count;
    }
    return anchorIndex != null &&
        anchorIndex >= 0 &&
        anchorIndex < count &&
        (index == anchorIndex || index == anchorIndex + 1);
  }
}

final class DocxTableStructurePlan {
  new({
    required this.sourceSha256,
    required List<DocxTableStructureTable> tables,
  }) : tables = List.unmodifiable(tables);

  final String sourceSha256;
  final List<DocxTableStructureTable> tables;
}

final class DocxTableStructureOutput {
  const new({
    required this.sourceSha256,
    required this.outputSha256,
    required this.tableIndex,
    required this.rowCount,
    required this.columnCount,
  });

  final String sourceSha256;
  final String outputSha256;
  final int tableIndex;
  final int rowCount;
  final int columnCount;
}

class DocxTableStructureEngine {
  const new({this._libraryPath});

  final String? _libraryPath;

  static const maxRows = 64;
  static const maxColumns = 32;
  static const maxCells = 512;
  static const _indexLimit = 512;
  static const _maxPreviewLength = 160;
  static const _maxDocxBytes = 128 * 1024 * 1024;
  static final _shaPattern = RegExp(r'^[0-9a-f]{64}$');
  static const _invalidReply = InkVaultNativeException(
    'invalid_response',
    'DOCX 표의 행·열과 원본 판본을 확인하지 못했습니다.',
  );

  Future<DocxTableStructurePlan> inspect({
    required String sourcePath,
    required String sourceSha256,
  }) async {
    _requirePath(sourcePath);
    _requireHash(sourceSha256);
    final result = await _invoke({
      'op': 'docx_table_structure_inspect',
      'sourcePath': sourcePath,
      'sourceSha256': sourceSha256,
    });
    final entries = result['tables'];
    if (result.length != 2 ||
        result['sourceSha256'] != sourceSha256 ||
        entries is! List ||
        entries.length > _indexLimit) {
      throw _invalidReply;
    }
    final tables = <DocxTableStructureTable>[];
    var previousIndex = -1;
    for (final entry in entries) {
      if (entry is! Map<String, Object?> || entry.length != 4)
        throw _invalidReply;
      final index = entry['tableIndex'];
      final rows = entry['rowCount'];
      final columns = entry['columnCount'];
      final preview = entry['preview'];
      if (index is! int ||
          index <= previousIndex ||
          index >= _indexLimit ||
          rows is! int ||
          columns is! int ||
          !_validDimensions(rows, columns) ||
          preview is! String ||
          preview.length > _maxPreviewLength) {
        throw _invalidReply;
      }
      previousIndex = index;
      tables.add(
        DocxTableStructureTable(
          tableIndex: index,
          rowCount: rows,
          columnCount: columns,
          preview: preview,
        ),
      );
    }
    return DocxTableStructurePlan(sourceSha256: sourceSha256, tables: tables);
  }

  Future<DocxTableStructureOutput> edit({
    required String sourcePath,
    required DocxTableStructurePlan plan,
    required String outputPath,
    required int tableIndex,
    required DocxTableStructureAction action,
    required int index,
    int? anchorIndex,
  }) async {
    _requirePath(sourcePath);
    _requirePath(outputPath);
    _requireHash(plan.sourceSha256);
    if (p.equals(sourcePath, outputPath) ||
        !p.equals(p.dirname(sourcePath), p.dirname(outputPath))) {
      throw ArgumentError('Expected separate DOCX files in one working folder');
    }
    final table = plan.tables
        .where((table) => table.tableIndex == tableIndex)
        .singleOrNull;
    if (tableIndex < 0 ||
        tableIndex >= _indexLimit ||
        table == null ||
        !table.allowsPosition(action, index, anchorIndex: anchorIndex)) {
      throw ArgumentError(
        'Expected an eligible DOCX table and row or column index',
      );
    }
    final result = await _invoke({
      'op': 'docx_table_structure_edit',
      'sourcePath': sourcePath,
      'sourceSha256': plan.sourceSha256,
      'outputPath': outputPath,
      'tableIndex': tableIndex,
      'action': action.name,
      'index': index,
      'anchorIndex': ?anchorIndex,
    });
    final outputSha = result['outputSha256'];
    final rows = result['rowCount'];
    final columns = result['columnCount'];
    if (result.length != 5 ||
        result['sourceSha256'] != plan.sourceSha256 ||
        outputSha is! String ||
        outputSha == plan.sourceSha256 ||
        !_validHash(outputSha) ||
        result['tableIndex'] is! int ||
        result['tableIndex'] != tableIndex ||
        rows is! int ||
        rows != table.rowCount + action.rowDelta ||
        columns is! int ||
        columns != table.columnCount + action.columnDelta ||
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
    return DocxTableStructureOutput(
      sourceSha256: plan.sourceSha256,
      outputSha256: outputSha,
      tableIndex: tableIndex,
      rowCount: rows,
      columnCount: columns,
    );
  }

  Future<Map<String, dynamic>> _invoke(Map<String, Object?> request) {
    final library = _libraryPath;
    return Isolate.run(
      () => InkVaultNative.open(libraryPath: library).invoke(request),
    );
  }

  static bool _validDimensions(int rows, int columns) =>
      rows >= 1 &&
      rows <= maxRows &&
      columns >= 1 &&
      columns <= maxColumns &&
      rows * columns <= maxCells;

  static bool _validHash(String value) =>
      value.length == 64 && _shaPattern.hasMatch(value);

  static void _requireHash(String value) {
    if (!_validHash(value))
      throw ArgumentError('Expected a DOCX SHA-256 digest');
  }

  static void _requirePath(String path) {
    if (!p.isAbsolute(path) ||
        p.normalize(path) != path ||
        p.extension(path).toLowerCase() != '.docx') {
      throw ArgumentError('Expected a normalized absolute DOCX path');
    }
  }
}
