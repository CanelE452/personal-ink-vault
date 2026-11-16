import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/app_external_screen.dart';
import 'package:saber/data/office/hwp_office_engine.dart';
import 'package:saber/data/office/office_original_edit_result.dart';

/// Full HWP/HWPX editing on Android: the bundled rhwp-studio screen (HwpEditorActivity) edits the working
/// copy, then rhwp renders the separate PDF. The result has the Office engine's shape (`edited.<ext>` and
/// `preview.pdf` beside the working copy), so the Office edit recovery and commit flow takes it unchanged.
class AndroidHwpEditor {
  new({MethodChannel? channel, HwpStructuredOfficeEngine? pdfEngine})
    : _channel = channel ?? const MethodChannel('personal_ink_vault/office_engine'),
      _pdf = pdfEngine ?? HwpStructuredOfficeEngine();

  static const editorVersion = 'rhwp-studio-0.9.0-dev.4cf97fe5';
  final MethodChannel _channel;
  final HwpStructuredOfficeEngine _pdf;

  /// [resume]: the session already existed, so its editor may still be open behind the app's
  /// tabs and is reused instead of opening a second one.
  Future<OfficeOriginalEditResult> edit({
    required String sourcePath,
    required String sessionId,
    required String fileName,
    bool resume = false,
  }) async {
    final working = File(sourcePath);
    final inputHash = await _hash(working);
    final Map<Object?, Object?>? response;
    AppExternalScreen.editorInFront(sessionId);
    try {
      response = await _channel.invokeMethod<Map<Object?, Object?>>('hwpEdit', {
        'sourcePath': sourcePath,
        'sessionId': sessionId,
        'fileName': fileName,
        if (resume) 'resume': true,
      });
    } on MissingPluginException {
      throw const FormatException('이 앱 버전에서는 HWP 편집 화면을 쓸 수 없습니다.');
    } on PlatformException catch (error) {
      throw FormatException(error.message ?? 'HWP 편집 화면을 열지 못했습니다. 원본은 보관됩니다.');
    } finally {
      AppExternalScreen.editorBehind(sessionId);
    }
    if (response == null ||
        response['sessionId'] != sessionId ||
        response['inputSourceSha256'] != inputHash) {
      throw const FormatException('HWP 편집 결과가 이 작업과 맞지 않습니다. 원본은 보관됩니다.');
    }
    if (response['status'] == 'cancelled') {
      final reason = response['closeReason'];
      return OfficeOriginalEditResult(
        status: OfficeOriginalEditStatus.cancelled,
        engineVersion: editorVersion,
        sessionId: sessionId,
        inputSourceSha256: inputHash,
        closeReason: reason == 'unchanged' || reason == 'discarded' ? reason as String : null,
      );
    }
    final reported = response['sourcePath'];
    final sourceHash = response['sourceSha256'];
    if (response['status'] != 'saved' ||
        reported is! String ||
        sourceHash is! String ||
        await File(reported).resolveSymbolicLinks() !=
            await _edited(sourcePath).resolveSymbolicLinks()) {
      throw const FormatException('편집한 HWP 파일을 확인하지 못했습니다. 원본은 보관됩니다.');
    }
    return _published(sourcePath, sessionId, inputHash, sourceHash);
  }

  /// Brings this session's open editor back in front of the app's tabs.
  Future<void> show({required String sessionId}) =>
      _bringBack('hwpShow', sessionId);

  /// Brings the open editor back and asks it to close; it asks the user when something changed.
  Future<void> requestClose({required String sessionId}) =>
      _bringBack('hwpRequestClose', sessionId);

  Future<void> _bringBack(String method, String sessionId) async {
    try {
      AppExternalScreen.editorInFront(sessionId);
      await _channel.invokeMethod<void>(method, {'sessionId': sessionId});
    } on PlatformException {
      AppExternalScreen.editorBehind(sessionId);
      rethrow;
    }
  }

  /// A save the editor finished while no call waited for it (the app restarted): the editor left
  /// result.json beside `edited.<ext>`. Null when there is none; a result for another session or a
  /// file that no longer matches is refused.
  Future<OfficeOriginalEditResult?> savedResult({
    required String sourcePath,
    required String sessionId,
  }) async {
    final marker = File(p.join(p.dirname(sourcePath), 'result.json'));
    if (FileSystemEntity.typeSync(marker.path, followLinks: false) !=
        FileSystemEntityType.file) {
      return null;
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(await marker.readAsString());
    } on FormatException {
      throw const FormatException('편집한 HWP 파일을 확인하지 못했습니다. 원본은 보관됩니다.');
    }
    final sourceHash = decoded is Map ? decoded['sourceSha256'] : null;
    if (decoded is! Map || decoded['sessionId'] != sessionId || sourceHash is! String) {
      throw const FormatException('HWP 편집 결과가 이 작업과 맞지 않습니다. 원본은 보관됩니다.');
    }
    return _published(sourcePath, sessionId, await _hash(File(sourcePath)), sourceHash);
  }

  /// The editor writes `edited.<ext>` beside the working copy; the Dart-side path is used.
  static File _edited(String sourcePath) => File(
    p.join(p.dirname(sourcePath), 'edited${p.extension(sourcePath).toLowerCase()}'),
  );

  Future<OfficeOriginalEditResult> _published(
    String sourcePath,
    String sessionId,
    String inputHash,
    String sourceHash,
  ) async {
    final edited = _edited(sourcePath);
    if (FileSystemEntity.typeSync(edited.path, followLinks: false) !=
            FileSystemEntityType.file ||
        await _hash(edited) != sourceHash) {
      throw const FormatException('편집한 HWP 파일을 확인하지 못했습니다. 원본은 보관됩니다.');
    }
    final pdf = await _pdf.renderPdf(edited.path);
    try {
      final preview = File(p.join(p.dirname(edited.path), 'preview.pdf'));
      await File(pdf.pdfPath).copy(preview.path);
      if (await _hash(preview) != pdf.pdfSha256) {
        throw const FormatException('편집한 문서의 PDF를 확인하지 못했습니다. 수정 파일은 보관됩니다.');
      }
      return OfficeOriginalEditResult(
        status: OfficeOriginalEditStatus.saved,
        engineVersion: '$editorVersion+${pdf.engineVersion}',
        sessionId: sessionId,
        sourcePath: edited.path,
        pdfPath: preview.path,
        sourceSha256: sourceHash,
        pdfSha256: pdf.pdfSha256,
        pdfPageCount: pdf.pageCount,
        inputSourceSha256: inputHash,
      );
    } finally {
      await pdf.dispose();
    }
  }

  static Future<String> _hash(File file) async =>
      crypto.sha256.convert(await file.readAsBytes()).toString();
}
