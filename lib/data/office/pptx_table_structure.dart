part of 'pptx_shape_text.dart';

enum PptxTableStructureAction {
  insertRowBefore(true),
  insertRowAfter(true),
  insertColumnBefore(false),
  insertColumnAfter(false),
  deleteRow(true),
  deleteColumn(false);

  new(this.isRow);

  final bool isRow;
  bool get isDelete => this == deleteRow || this == deleteColumn;
  bool get isAfter => this == insertRowAfter || this == insertColumnAfter;
  int get rowDelta => isRow ? (isDelete ? -1 : 1) : 0;
  int get columnDelta => isRow ? 0 : (isDelete ? -1 : 1);
}

final class PptxTableStructureTable {
  new({
    required this.shapeId,
    required this.name,
    required this.rows,
    required this.columns,
    required Iterable<int> rowInsertGaps,
    required Iterable<int> columnInsertGaps,
    required Iterable<int> rowDelete,
    required Iterable<int> columnDelete,
  }) : rowInsertGaps = Set.unmodifiable(rowInsertGaps),
       columnInsertGaps = Set.unmodifiable(columnInsertGaps),
       rowDelete = Set.unmodifiable(rowDelete),
       columnDelete = Set.unmodifiable(columnDelete);

  final int shapeId;
  final String name;
  final int rows;
  final int columns;
  final Set<int> rowInsertGaps;
  final Set<int> columnInsertGaps;
  final Set<int> rowDelete;
  final Set<int> columnDelete;

  bool allows(PptxTableStructureAction action, int index) {
    final count = action.isRow ? rows : columns;
    if (index < 0 || index >= count) return false;
    if (action.isDelete) {
      return count > 1 &&
          (action.isRow ? rowDelete : columnDelete).contains(index);
    }
    final gaps = action.isRow ? rowInsertGaps : columnInsertGaps;
    return count < PptxTableStructureEngine.maxDimension &&
        gaps.contains(index + (action.isAfter ? 1 : 0));
  }

  List<int> positions(PptxTableStructureAction action) => [
    for (var index = 0; index < (action.isRow ? rows : columns); index++)
      if (allows(action, index)) index,
  ];
}

typedef PptxTableStructureOutput = ({
  String sourceSha256,
  String outputSha256,
  int slideCount,
  int slideIndex,
  int shapeId,
  PptxTableStructureAction action,
  int index,
  int rows,
  int columns,
});

class PptxTableStructureEngine {
  const new({this._libraryPath});

  final String? _libraryPath;
  PptxShapeTextEngine get _bridge =>
      PptxShapeTextEngine(libraryPath: _libraryPath);

  static const maxDimension = 256;
  static const _invalidReply = InkVaultNativeException(
    'invalid_response',
    'PPTX 표의 행·열과 원본 판본을 확인하지 못했습니다.',
  );

  Future<PptxShapeTextPlan> inspect({
    required String sourcePath,
    required String sourceSha256,
  }) => _bridge._inspect(
    sourcePath,
    sourceSha256,
    'pptx_table_structure_inspect',
    _invalidReply,
  );

  Future<List<PptxTableStructureTable>> inspectSlide({
    required String sourcePath,
    required PptxShapeTextPlan plan,
    required int slideIndex,
  }) async {
    PptxShapeTextEngine._requireSlide(sourcePath, plan, slideIndex);
    final result = await _bridge._invoke({
      'op': 'pptx_table_structure_inspect',
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
    final parsed = <PptxTableStructureTable>[];
    final ids = <int>{};
    for (final table in tables) {
      if (table is! Map<String, Object?> || table.length != 8) {
        throw _invalidReply;
      }
      final id = table['shapeId'];
      final name = table['name'];
      final rows = table['rows'];
      final columns = table['columns'];
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
          columns > maxDimension) {
        throw _invalidReply;
      }
      parsed.add(
        PptxTableStructureTable(
          shapeId: id,
          name: name,
          rows: rows,
          columns: columns,
          rowInsertGaps: _indices(
            table['rowInsertGaps'],
            rows < maxDimension ? rows : -1,
          ),
          columnInsertGaps: _indices(
            table['columnInsertGaps'],
            columns < maxDimension ? columns : -1,
          ),
          rowDelete: _indices(table['rowDelete'], rows > 1 ? rows - 1 : -1),
          columnDelete: _indices(
            table['columnDelete'],
            columns > 1 ? columns - 1 : -1,
          ),
        ),
      );
    }
    return List.unmodifiable(parsed);
  }

  static Set<int> _indices(Object? values, int maxIndex) {
    if (values is! List || values.length > maxIndex + 1) throw _invalidReply;
    final indices = <int>{};
    for (final value in values) {
      if (value is! int ||
          value < 0 ||
          value > maxIndex ||
          !indices.add(value)) {
        throw _invalidReply;
      }
    }
    return indices;
  }

  Future<PptxTableStructureOutput> edit({
    required String sourcePath,
    required PptxShapeTextPlan plan,
    required String outputPath,
    required int slideIndex,
    required PptxTableStructureTable table,
    required PptxTableStructureAction action,
    required int index,
  }) async {
    PptxShapeTextEngine._requireSlide(sourcePath, plan, slideIndex);
    PptxShapeTextEngine._requireOutputPath(sourcePath, outputPath);
    if (table.shapeId < 1 ||
        table.shapeId > 0xffffffff ||
        !table.allows(action, index)) {
      throw ArgumentError('Expected an allowed PPTX table operation');
    }
    final result = await _bridge._invoke({
      'op': 'pptx_table_structure_edit',
      'sourcePath': sourcePath,
      'sourceSha256': plan.sourceSha256,
      'outputPath': outputPath,
      'slideIndex': slideIndex,
      'shapeId': table.shapeId,
      'action': action.name,
      'index': index,
    });
    final outputSha = result['outputSha256'];
    final rows = result['rows'];
    final columns = result['columns'];
    if (result.length != 9 ||
        !PptxShapeTextEngine._matchesSlide(result, plan, slideIndex) ||
        result['shapeId'] is! int ||
        result['shapeId'] != table.shapeId ||
        result['action'] != action.name ||
        result['index'] is! int ||
        result['index'] != index ||
        rows is! int ||
        rows != table.rows + action.rowDelta ||
        columns is! int ||
        columns != table.columns + action.columnDelta ||
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
      index: index,
      rows: rows,
      columns: columns,
    );
  }
}
