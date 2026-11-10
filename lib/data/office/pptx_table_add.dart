part of 'pptx_text_box.dart';

typedef PptxTableAddOutput = ({
  String sourceSha256,
  String outputSha256,
  int slideCount,
  int slideIndex,
  int shapeId,
  int rows,
  int columns,
});

class PptxTableAddEngine {
  const new({this._libraryPath});

  final String? _libraryPath;
  PptxTextBoxEngine get _bridge => PptxTextBoxEngine(libraryPath: _libraryPath);
  static const maxRows = 10;
  static const maxColumns = 10;
  static const _invalidReply = InkVaultNativeException(
    'invalid_response',
    '표를 추가한 PPTX를 확인하지 못했습니다.',
  );

  Future<PptxTextBoxPlan> inspect({
    required String sourcePath,
    required String sourceSha256,
  }) => _bridge._inspect(
    sourcePath,
    sourceSha256,
    'pptx_table_add_inspect',
    _invalidReply,
  );

  Future<PptxTableAddOutput> add({
    required String sourcePath,
    required PptxTextBoxPlan plan,
    required String outputPath,
    required int slideIndex,
    required int rows,
    required int columns,
  }) async {
    PptxTextBoxEngine._requirePath(sourcePath);
    PptxTextBoxEngine._requirePath(outputPath);
    PptxTextBoxEngine._requireHash(plan.sourceSha256);
    PptxTextBoxEngine._requireSeparateOutput(sourcePath, outputPath);
    if (rows < 1 || rows > maxRows || columns < 1 || columns > maxColumns) {
      throw ArgumentError('PPTX table dimensions must be between 1 and 10');
    }
    if (plan.slideCount > PptxTextBoxEngine.maxSlides ||
        slideIndex < 0 ||
        slideIndex >= plan.slideCount ||
        plan.slides[slideIndex].index != slideIndex ||
        !plan.slides[slideIndex].canAdd) {
      throw const InkVaultNativeException(
        'unsupported_slide',
        '이 슬라이드에는 표를 추가할 수 없습니다.',
      );
    }
    final result = await _bridge._invoke({
      'op': 'pptx_table_add',
      'sourcePath': sourcePath,
      'sourceSha256': plan.sourceSha256,
      'outputPath': outputPath,
      'slideIndex': slideIndex,
      'rows': rows,
      'columns': columns,
    });
    final outputSha = result['outputSha256'];
    final shapeId = result['shapeId'];
    if (result.length != 7 ||
        result['sourceSha256'] != plan.sourceSha256 ||
        outputSha is! String ||
        outputSha == plan.sourceSha256 ||
        !PptxTextBoxEngine._sha256Pattern.hasMatch(outputSha) ||
        result['slideCount'] is! int ||
        result['slideCount'] != plan.slideCount ||
        result['slideIndex'] is! int ||
        result['slideIndex'] != slideIndex ||
        shapeId is! int ||
        shapeId < 1 ||
        shapeId > 0xffffffff ||
        result['rows'] is! int ||
        result['rows'] != rows ||
        result['columns'] is! int ||
        result['columns'] != columns) {
      throw _invalidReply;
    }
    await PptxTextBoxEngine._validateWrittenCandidate(
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
      rows: rows,
      columns: columns,
    );
  }
}
