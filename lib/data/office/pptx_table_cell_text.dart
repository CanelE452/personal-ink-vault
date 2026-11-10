part of 'pptx_shape_text.dart';

final class PptxTableCellTextCell {
  new({
    required this.row,
    required this.column,
    required List<PptxShapeTextRun> runs,
  }) : runs = List.unmodifiable(runs);

  final int row;
  final int column;
  final List<PptxShapeTextRun> runs;
}

final class PptxTableCellTextTable {
  new({
    required this.shapeId,
    required this.name,
    required this.rows,
    required this.columns,
    required List<PptxTableCellTextCell> cells,
  }) : cells = List.unmodifiable(cells);

  final int shapeId;
  final String name;
  final int rows;
  final int columns;
  final List<PptxTableCellTextCell> cells;
}

typedef PptxTableCellTextOutput = ({
  String sourceSha256,
  String outputSha256,
  int slideCount,
  int slideIndex,
  int shapeId,
  int row,
  int column,
});

class PptxTableCellTextEngine {
  const new({this._libraryPath});

  final String? _libraryPath;
  PptxShapeTextEngine get _bridge =>
      PptxShapeTextEngine(libraryPath: _libraryPath);

  static const _maxDimension = 256;
  static const _invalidReply = InkVaultNativeException(
    'invalid_response',
    'PPTX 표 셀과 원본 판본을 확인하지 못했습니다.',
  );

  Future<PptxShapeTextPlan> inspect({
    required String sourcePath,
    required String sourceSha256,
  }) => _bridge._inspect(
    sourcePath,
    sourceSha256,
    'pptx_table_cell_text_inspect',
    _invalidReply,
  );

  Future<List<PptxTableCellTextTable>> inspectSlide({
    required String sourcePath,
    required PptxShapeTextPlan plan,
    required int slideIndex,
  }) async {
    PptxShapeTextEngine._requireSlide(sourcePath, plan, slideIndex);
    final result = await _bridge._invoke({
      'op': 'pptx_table_cell_text_inspect',
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
    final parsed = <PptxTableCellTextTable>[];
    final shapeIds = <int>{};
    var runCount = 0;
    var textLength = 0;
    for (final table in tables) {
      if (table is! Map<String, Object?> || table.length != 5) {
        throw _invalidReply;
      }
      final id = table['shapeId'];
      final name = table['name'];
      final rows = table['rows'];
      final columns = table['columns'];
      final cells = table['cells'];
      if (id is! int ||
          id < 1 ||
          id > 0xffffffff ||
          !shapeIds.add(id) ||
          name is! String ||
          name.length > 1024 ||
          rows is! int ||
          rows < 1 ||
          rows > _maxDimension ||
          columns is! int ||
          columns < 1 ||
          columns > _maxDimension ||
          cells is! List ||
          cells.isEmpty ||
          cells.length > PptxShapeTextEngine.maxRunsPerSlide - runCount) {
        throw _invalidReply;
      }
      final parsedCells = <PptxTableCellTextCell>[];
      var previous = -1;
      for (final cell in cells) {
        if (cell is! Map<String, Object?> || cell.length != 3) {
          throw _invalidReply;
        }
        final row = cell['row'];
        final column = cell['column'];
        final runs = cell['runs'];
        if (row is! int ||
            row < 0 ||
            row >= rows ||
            column is! int ||
            column < 0 ||
            column >= columns ||
            row * columns + column <= previous ||
            runs is! List ||
            runs.isEmpty ||
            runs.length > PptxShapeTextEngine.maxRunsPerSlide - runCount) {
          throw _invalidReply;
        }
        previous = row * columns + column;
        runCount += runs.length;
        final editable = PptxShapeTextEngine._readRuns(runs, _invalidReply);
        for (final run in editable) {
          textLength += run.text.length;
          if (textLength > PptxShapeTextEngine.maxTotalRunLength) {
            throw _invalidReply;
          }
        }
        parsedCells.add(
          PptxTableCellTextCell(row: row, column: column, runs: editable),
        );
      }
      parsed.add(
        PptxTableCellTextTable(
          shapeId: id,
          name: name,
          rows: rows,
          columns: columns,
          cells: parsedCells,
        ),
      );
    }
    return List.unmodifiable(parsed);
  }

  Future<PptxTableCellTextOutput> replace({
    required String sourcePath,
    required PptxShapeTextPlan plan,
    required String outputPath,
    required int slideIndex,
    required int shapeId,
    required int row,
    required int column,
    required List<PptxShapeTextChange> changes,
  }) async {
    PptxShapeTextEngine._requireSlide(sourcePath, plan, slideIndex);
    PptxShapeTextEngine._requireOutputPath(sourcePath, outputPath);
    if (shapeId < 1 ||
        shapeId > 0xffffffff ||
        row < 0 ||
        row >= _maxDimension ||
        column < 0 ||
        column >= _maxDimension ||
        changes.isEmpty ||
        changes.length > PptxShapeTextEngine.maxRunsPerSlide) {
      throw ArgumentError('Expected changes to one PPTX table cell');
    }
    final keys = <(int, int)>{};
    var textLength = 0;
    final edits = <Map<String, Object>>[];
    for (final change in changes) {
      final paragraph = change.paragraphIndex;
      final run = change.runIndex;
      textLength += change.text.length;
      if (paragraph < 0 ||
          paragraph > 0xffffffff ||
          run < 0 ||
          run > 0xffffffff ||
          !keys.add((paragraph, run)) ||
          !PptxShapeTextEngine.validText(change.text) ||
          textLength > PptxShapeTextEngine.maxTotalRunLength) {
        throw ArgumentError('Expected distinct editable PPTX cell changes');
      }
      edits.add({
        'paragraphIndex': paragraph,
        'runIndex': run,
        'text': change.text,
      });
    }
    final result = await _bridge._invoke({
      'op': 'pptx_table_cell_text_replace',
      'sourcePath': sourcePath,
      'sourceSha256': plan.sourceSha256,
      'outputPath': outputPath,
      'slideIndex': slideIndex,
      'shapeId': shapeId,
      'row': row,
      'column': column,
      'changes': edits,
    });
    final outputSha = result['outputSha256'];
    if (result.length != 7 ||
        !PptxShapeTextEngine._matchesSlide(result, plan, slideIndex) ||
        result['shapeId'] is! int ||
        result['shapeId'] != shapeId ||
        result['row'] is! int ||
        result['row'] != row ||
        result['column'] is! int ||
        result['column'] != column ||
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
      shapeId: shapeId,
      row: row,
      column: column,
    );
  }
}
