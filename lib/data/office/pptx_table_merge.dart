part of 'pptx_shape_text.dart';

enum PptxTableMergeAction { merge, unmerge }

typedef PptxTableCellRange = ({
  int row,
  int column,
  int rowSpan,
  int columnSpan,
});

final class PptxTableMergeTable {
  new({
    required this.shapeId,
    required this.name,
    required this.rows,
    required this.columns,
    required Iterable<PptxTableCellRange> mergedRanges,
  }) : mergedRanges = List.unmodifiable(mergedRanges);

  final int shapeId;
  final String name;
  final int rows;
  final int columns;
  final List<PptxTableCellRange> mergedRanges;

  bool contains(PptxTableCellRange range) =>
      range.row >= 0 &&
      range.column >= 0 &&
      range.rowSpan >= 1 &&
      range.columnSpan >= 1 &&
      range.row + range.rowSpan <= rows &&
      range.column + range.columnSpan <= columns;

  bool allows(PptxTableMergeAction action, PptxTableCellRange range) =>
      contains(range) &&
      range.rowSpan * range.columnSpan > 1 &&
      (action == PptxTableMergeAction.unmerge
          ? mergedRanges.contains(range)
          : !mergedRanges.any((merged) => _overlaps(merged, range)) &&
                keepsGridBoundaries(range));

  bool keepsGridBoundaries(PptxTableCellRange range) {
    // Impress drops non-leading rows and columns containing only covered cells.
    for (
      var column = range.column == 0 ? 1 : range.column;
      column < range.column + range.columnSpan;
      column++
    ) {
      var covered = range.rowSpan - (column == range.column ? 1 : 0);
      for (final merged in mergedRanges) {
        if (merged.column <= column &&
            column < merged.column + merged.columnSpan) {
          covered += merged.rowSpan - (column == merged.column ? 1 : 0);
        }
      }
      if (covered >= rows) return false;
    }
    for (
      var row = range.row == 0 ? 1 : range.row;
      row < range.row + range.rowSpan;
      row++
    ) {
      var covered = range.columnSpan - (row == range.row ? 1 : 0);
      for (final merged in mergedRanges) {
        if (merged.row <= row && row < merged.row + merged.rowSpan) {
          covered += merged.columnSpan - (row == merged.row ? 1 : 0);
        }
      }
      if (covered >= columns) return false;
    }
    return true;
  }

  static bool _overlaps(PptxTableCellRange a, PptxTableCellRange b) =>
      a.row < b.row + b.rowSpan &&
      b.row < a.row + a.rowSpan &&
      a.column < b.column + b.columnSpan &&
      b.column < a.column + a.columnSpan;
}

typedef PptxTableMergeOutput = ({
  String sourceSha256,
  String outputSha256,
  int slideCount,
  int slideIndex,
  int shapeId,
  PptxTableMergeAction action,
  PptxTableCellRange range,
  int rows,
  int columns,
});

class PptxTableMergeEngine {
  const new({this._libraryPath});

  final String? _libraryPath;
  PptxShapeTextEngine get _bridge =>
      PptxShapeTextEngine(libraryPath: _libraryPath);

  static const _invalidReply = InkVaultNativeException(
    'invalid_response',
    'PPTX 표의 병합 영역과 원본 판본을 확인하지 못했습니다.',
  );

  Future<PptxShapeTextPlan> inspect({
    required String sourcePath,
    required String sourceSha256,
  }) => _bridge._inspect(
    sourcePath,
    sourceSha256,
    'pptx_table_merge_inspect',
    _invalidReply,
  );

  Future<List<PptxTableMergeTable>> inspectSlide({
    required String sourcePath,
    required PptxShapeTextPlan plan,
    required int slideIndex,
  }) async {
    PptxShapeTextEngine._requireSlide(sourcePath, plan, slideIndex);
    final result = await _bridge._invoke({
      'op': 'pptx_table_merge_inspect',
      'sourcePath': sourcePath,
      'sourceSha256': plan.sourceSha256,
      'slideIndex': slideIndex,
    });
    final tables = result['tables'];
    if (result.length != 4 ||
        !PptxShapeTextEngine._matchesSlide(result, plan, slideIndex) ||
        tables is! List ||
        tables.length > PptxShapeTextEngine.maxRunsPerSlide) {
      throw _invalidReply;
    }
    final ids = <int>{};
    final parsed = <PptxTableMergeTable>[];
    var rangeCount = 0;
    for (final table in tables) {
      if (table is! Map<String, Object?> || table.length != 5) {
        throw _invalidReply;
      }
      final id = table['shapeId'];
      final name = table['name'];
      final rows = table['rows'];
      final columns = table['columns'];
      final ranges = table['mergedRanges'];
      const maxDimension = PptxTableStructureEngine.maxDimension;
      if (id is! int ||
          id < 1 ||
          id > 0xffffffff ||
          !ids.add(id) ||
          name is! String ||
          name.length > 1024 ||
          rows is! int ||
          rows < 1 ||
          rows > maxDimension ||
          columns is! int ||
          columns < 1 ||
          columns > maxDimension ||
          ranges is! List ||
          ranges.length > rows * columns ~/ 2) {
        throw _invalidReply;
      }
      final parsedRanges = <PptxTableCellRange>[];
      rangeCount += ranges.length;
      if (rangeCount > 512) throw _invalidReply;
      final occupied = <int>{};
      for (final entry in ranges) {
        if (entry is! Map<String, Object?> || entry.length != 4) {
          throw _invalidReply;
        }
        final range = _range(entry);
        if (range.row < 0 ||
            range.column < 0 ||
            range.rowSpan < 1 ||
            range.columnSpan < 1 ||
            range.rowSpan * range.columnSpan <= 1 ||
            range.row + range.rowSpan > rows ||
            range.column + range.columnSpan > columns) {
          throw _invalidReply;
        }
        for (var row = range.row; row < range.row + range.rowSpan; row++) {
          for (
            var column = range.column;
            column < range.column + range.columnSpan;
            column++
          ) {
            if (!occupied.add(row * columns + column)) throw _invalidReply;
          }
        }
        parsedRanges.add(range);
      }
      parsed.add(
        PptxTableMergeTable(
          shapeId: id,
          name: name,
          rows: rows,
          columns: columns,
          mergedRanges: parsedRanges,
        ),
      );
    }
    return List.unmodifiable(parsed);
  }

  static PptxTableCellRange _range(Map<String, Object?> fields) {
    final row = fields['row'];
    final column = fields['column'];
    final rowSpan = fields['rowSpan'];
    final columnSpan = fields['columnSpan'];
    if (row is! int ||
        column is! int ||
        rowSpan is! int ||
        columnSpan is! int) {
      throw _invalidReply;
    }
    return (row: row, column: column, rowSpan: rowSpan, columnSpan: columnSpan);
  }

  Future<PptxTableMergeOutput> edit({
    required String sourcePath,
    required PptxShapeTextPlan plan,
    required String outputPath,
    required int slideIndex,
    required PptxTableMergeTable table,
    required PptxTableMergeAction action,
    required PptxTableCellRange range,
  }) async {
    PptxShapeTextEngine._requireSlide(sourcePath, plan, slideIndex);
    PptxShapeTextEngine._requireOutputPath(sourcePath, outputPath);
    if (table.shapeId < 1 ||
        table.shapeId > 0xffffffff ||
        !table.allows(action, range)) {
      throw ArgumentError('Expected an eligible PPTX table range');
    }
    final result = await _bridge._invoke({
      'op': 'pptx_table_merge_edit',
      'sourcePath': sourcePath,
      'sourceSha256': plan.sourceSha256,
      'outputPath': outputPath,
      'slideIndex': slideIndex,
      'shapeId': table.shapeId,
      'action': action.name,
      'row': range.row,
      'column': range.column,
      'rowSpan': range.rowSpan,
      'columnSpan': range.columnSpan,
    });
    final outputSha = result['outputSha256'];
    if (result.length != 12 ||
        !PptxShapeTextEngine._matchesSlide(result, plan, slideIndex) ||
        result['shapeId'] is! int ||
        result['shapeId'] != table.shapeId ||
        result['action'] != action.name ||
        _range(result) != range ||
        result['rows'] is! int ||
        result['rows'] != table.rows ||
        result['columns'] is! int ||
        result['columns'] != table.columns ||
        outputSha is! String ||
        outputSha == plan.sourceSha256 ||
        !PptxShapeTextEngine._sha256Pattern.hasMatch(outputSha)) {
      throw _invalidReply;
    }
    await PptxShapeTextEngine._validateWrittenCandidate(
      outputPath,
      outputSha,
      _invalidReply,
    );
    return (
      sourceSha256: plan.sourceSha256,
      outputSha256: outputSha,
      slideCount: plan.slideCount,
      slideIndex: slideIndex,
      shapeId: table.shapeId,
      action: action,
      range: range,
      rows: table.rows,
      columns: table.columns,
    );
  }
}
