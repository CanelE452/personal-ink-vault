import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/office/android_office_engine.dart';
import 'package:saber/data/office/hwp_office_engine.dart';
import 'package:saber/data/office/windows_office_engine.dart';

class OfficePreviewResult {
  const new({
    required this.pdfPath,
    required this.pdfSha256,
    required this.pageCount,
    required this.sourceSha256,
    required this.engineVersion,
  }) : _disposal = null;

  new _owned({
    required this.pdfPath,
    required this.pdfSha256,
    required this.pageCount,
    required this.sourceSha256,
    required this.engineVersion,
    required Future<void> Function() onDispose,
  }) : _disposal = _OfficePreviewDisposal(onDispose);

  final String pdfPath;
  final String pdfSha256;
  final int pageCount;
  final String sourceSha256;
  final String engineVersion;
  final _OfficePreviewDisposal? _disposal;

  Future<void> dispose() => _disposal?.dispose() ?? Future<void>.value();
}

class _OfficePreviewDisposal {
  new(this._release);
  final Future<void> Function() _release;
  Future<void>? _completion;

  Future<void> dispose() => _completion ??= Future<void>.sync(_release)
      .catchError((Object _, StackTrace _) {
        // An unavailable private cleanup must not replace a result or error.
      });
}

class OfficePreviewEngine {
  new({
    WindowsOfficeEngine? windowsEngine,
    HwpStructuredOfficeEngine? hwpEngine,
    AndroidOfficeEngine? androidEngine,
    bool? isWindows,
    bool? isAndroid,
  }) : _windows = windowsEngine ?? WindowsOfficeEngine(),
       _hwp = hwpEngine ?? HwpStructuredOfficeEngine(),
       _android = androidEngine ?? const AndroidOfficeEngine(),
       _isWindows = isWindows ?? Platform.isWindows,
       _isAndroid = isAndroid ?? Platform.isAndroid;
  final WindowsOfficeEngine _windows;
  final HwpStructuredOfficeEngine _hwp;
  final AndroidOfficeEngine _android;
  final bool _isWindows;
  final bool _isAndroid;
  Future<OfficePreviewResult?> preview({
    required String sourcePath,
    required String sessionId,
  }) async {
    if (sessionId.trim().isEmpty || sessionId.length > 128)
      throw ArgumentError('Expected a preview session');
    final source = File(sourcePath);
    if (!p.isAbsolute(sourcePath) ||
        FileSystemEntity.typeSync(sourcePath, followLinks: false) !=
            FileSystemEntityType.file ||
        await source.length() == 0 ||
        await source.length() > 128 * 1024 * 1024) {
      throw PlatformException(
        code: 'invalid_office_preview',
        message: '미리보기 원본 파일을 확인하지 못했습니다.',
      );
    }
    final before = await _hash(source), modified = source.lastModifiedSync();
    OfficePreviewResult? ownedResult;
    Future<void> Function()? releasePreview;
    var successful = false;
    try {
      final extension = p.extension(sourcePath).toLowerCase();
      late OfficePreviewResult result;
      if ({'.hwp', '.hwpx'}.contains(extension) || _isWindows) {
        final hwp = {'.hwp', '.hwpx'}.contains(extension);
        final engine = hwp ? _hwp : _windows;
        if (!await engine.available)
          throw PlatformException(
            code: 'office_unavailable',
            message: '문서 미리보기 엔진이 준비되지 않았습니다.',
          );
        final snapshot = await engine.inspect(sourcePath, preview: true);
        releasePreview = snapshot.disposePreview;
        if (snapshot.previewPdfPath == null ||
            snapshot.previewPageCount == null)
          throw PlatformException(
            code: 'invalid_office_preview',
            message: 'PDF 미리보기 파일을 만들지 못했습니다.',
          );
        final output = File(snapshot.previewPdfPath!);
        if (!p.isAbsolute(output.path) ||
            p.equals(p.absolute(output.path), p.absolute(sourcePath)) ||
            FileSystemEntity.typeSync(output.path, followLinks: false) !=
                FileSystemEntityType.file ||
            await output.length() < 10 ||
            await output.length() > 128 * 1024 * 1024) {
          throw PlatformException(
            code: 'invalid_office_preview',
            message: '별도 PDF 미리보기 파일을 확인하지 못했습니다.',
          );
        }
        result = OfficePreviewResult._owned(
          pdfPath: snapshot.previewPdfPath!,
          pdfSha256: await _hash(output),
          pageCount: snapshot.previewPageCount!,
          sourceSha256: snapshot.sourceSha256,
          engineVersion: hwp
              ? 'piv-preview-v1/hwp-cli-1.3.1'
              : 'piv-preview-v1/LibreOffice-26.8.2.2',
          onDispose: snapshot.disposePreview,
        );
      } else if (_isAndroid) {
        final native = await _android.preview(
          sourcePath: sourcePath,
          sessionId: sessionId,
        );
        if (native == null) return null;
        releasePreview = native.dispose;
        result = OfficePreviewResult._owned(
          pdfPath: native.pdfPath,
          pdfSha256: native.pdfSha256,
          pageCount: native.pageCount,
          sourceSha256: native.sourceSha256,
          engineVersion: native.engineVersion,
          onDispose: native.dispose,
        );
      } else {
        throw PlatformException(
          code: 'office_unavailable',
          message: '이 기기에서는 문서 미리보기를 지원하지 않습니다.',
        );
      }
      ownedResult = result;
      final pdf = File(result.pdfPath);
      if (result.sourceSha256 != before ||
          result.pageCount < 1 ||
          result.engineVersion.trim().isEmpty ||
          !p.isAbsolute(pdf.path) ||
          p.equals(p.absolute(pdf.path), p.absolute(sourcePath)) ||
          FileSystemEntity.typeSync(pdf.path, followLinks: false) !=
              FileSystemEntityType.file ||
          await pdf.length() < 10 ||
          await pdf.length() > 128 * 1024 * 1024 ||
          !await _isPdf(pdf) ||
          await _hash(pdf) != result.pdfSha256) {
        throw PlatformException(
          code: 'invalid_office_preview',
          message: '원본에 연결된 PDF 미리보기를 확인하지 못했습니다.',
        );
      }
      successful = true;
      return result;
    } finally {
      var unchanged = false;
      try {
        try {
          unchanged =
              await _hash(source) == before &&
              (source.lastModifiedSync()).isAtSameMomentAs(modified);
        } on FileSystemException {
          unchanged = false;
        }
        if (!unchanged)
          throw PlatformException(
            code: 'preview_source_changed',
            message: '미리보기를 만드는 동안 작업 원본이 변경됐습니다. 원래 저장본은 보존됩니다.',
          );
      } finally {
        if (!successful || !unchanged) {
          if (ownedResult != null) {
            await ownedResult.dispose();
          } else if (releasePreview != null) {
            await _OfficePreviewDisposal(releasePreview).dispose();
          }
        }
      }
    }
  }
}

Future<String> _hash(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();
Future<bool> _isPdf(File file) async {
  final handle = await file.open();
  try {
    if (ascii.decode(await handle.read(5), allowInvalid: true) != '%PDF-')
      return false;
    final length = await handle.length();
    await handle.setPosition(length > 2048 ? length - 2048 : 0);
    return latin1.decode(await handle.read(2048)).contains('%%EOF');
  } finally {
    await handle.close();
  }
}
