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

  Future<OfficeOriginalEditResult> edit({
    required String sourcePath,
    required String sessionId,
    required String fileName,
  }) async {
    final working = File(sourcePath);
    final inputHash = await _hash(working);
    final Map<Object?, Object?>? response;
    try {
      response = await AppExternalScreen.run(
        () => _channel.invokeMethod<Map<Object?, Object?>>('hwpEdit', {
          'sourcePath': sourcePath,
          'sessionId': sessionId,
          'fileName': fileName,
        }),
      );
    } on MissingPluginException {
      throw const FormatException('이 앱 버전에서는 HWP 편집 화면을 쓸 수 없습니다.');
    } on PlatformException catch (error) {
      throw FormatException(error.message ?? 'HWP 편집 화면을 열지 못했습니다. 원본은 보관됩니다.');
    }
    if (response == null ||
        response['sessionId'] != sessionId ||
        response['inputSourceSha256'] != inputHash) {
      throw const FormatException('HWP 편집 결과가 이 작업과 맞지 않습니다. 원본은 보관됩니다.');
    }
    if (response['status'] == 'cancelled') {
      return OfficeOriginalEditResult(
        status: OfficeOriginalEditStatus.cancelled,
        engineVersion: editorVersion,
        sessionId: sessionId,
        inputSourceSha256: inputHash,
      );
    }
    // The editor writes edited.<ext> beside the working copy; use the Dart-side path for the result.
    final edited = File(
      p.join(p.dirname(sourcePath), 'edited${p.extension(sourcePath).toLowerCase()}'),
    );
    final reported = response['sourcePath'];
    final sourceHash = response['sourceSha256'];
    if (response['status'] != 'saved' ||
        reported is! String ||
        sourceHash is! String ||
        FileSystemEntity.typeSync(edited.path, followLinks: false) !=
            FileSystemEntityType.file ||
        await File(reported).resolveSymbolicLinks() !=
            await edited.resolveSymbolicLinks() ||
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
