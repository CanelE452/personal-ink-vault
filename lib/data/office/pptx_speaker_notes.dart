part of 'pptx_shape_text.dart';

typedef PptxSpeakerNotes = ({String text, bool editable, bool hasNotes});

typedef PptxSpeakerNotesOutput = ({
  String sourceSha256,
  String outputSha256,
  int slideCount,
  int slideIndex,
});

class PptxSpeakerNotesEngine {
  const new({this._libraryPath});

  final String? _libraryPath;
  PptxShapeTextEngine get _bridge =>
      PptxShapeTextEngine(libraryPath: _libraryPath);

  static const maxTextLength = 8000;
  static const maxLines = 128;
  static const _invalidReply = InkVaultNativeException(
    'invalid_response',
    '발표자 노트와 PPTX 판본을 확인하지 못했습니다.',
  );
  static final _invalidCharacters = RegExp(
    r'[\u0000-\u0008\u000b-\u001f\u007f-\u009f\ud800-\udfff\ufffe\uffff]',
    unicode: true,
  );

  static bool validText(String value) =>
      value.length <= maxTextLength &&
      '\n'.allMatches(value).length < maxLines &&
      !_invalidCharacters.hasMatch(value);

  Future<PptxShapeTextPlan> inspect({
    required String sourcePath,
    required String sourceSha256,
  }) => _bridge._inspect(
    sourcePath,
    sourceSha256,
    'pptx_speaker_notes_inspect',
    _invalidReply,
  );

  Future<PptxSpeakerNotes> inspectSlide({
    required String sourcePath,
    required PptxShapeTextPlan plan,
    required int slideIndex,
  }) async {
    PptxShapeTextEngine._requireSlide(sourcePath, plan, slideIndex);
    final result = await _bridge._invoke({
      'op': 'pptx_speaker_notes_inspect',
      'sourcePath': sourcePath,
      'sourceSha256': plan.sourceSha256,
      'slideIndex': slideIndex,
    });
    final text = result['text'];
    final editable = result['editable'];
    final hasNotes = result['hasNotes'];
    if (result.length != 6 ||
        !PptxShapeTextEngine._matchesSlide(result, plan, slideIndex) ||
        text is! String ||
        editable is! bool ||
        hasNotes is! bool ||
        (editable && !validText(text)) ||
        (!hasNotes && text.isNotEmpty)) {
      throw _invalidReply;
    }
    return (text: text, editable: editable, hasNotes: hasNotes);
  }

  Future<PptxSpeakerNotesOutput> edit({
    required String sourcePath,
    required PptxShapeTextPlan plan,
    required String outputPath,
    required int slideIndex,
    required String text,
  }) async {
    PptxShapeTextEngine._requireSlide(sourcePath, plan, slideIndex);
    PptxShapeTextEngine._requireOutputPath(sourcePath, outputPath);
    if (!validText(text)) {
      throw ArgumentError('Expected valid PPTX speaker notes text');
    }
    final result = await _bridge._invoke({
      'op': 'pptx_speaker_notes_edit',
      'sourcePath': sourcePath,
      'sourceSha256': plan.sourceSha256,
      'outputPath': outputPath,
      'slideIndex': slideIndex,
      'text': text,
    });
    final outputSha = result['outputSha256'];
    if (result.length != 4 ||
        !PptxShapeTextEngine._matchesSlide(result, plan, slideIndex) ||
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
    );
  }
}
