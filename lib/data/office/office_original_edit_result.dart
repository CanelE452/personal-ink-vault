import 'dart:typed_data';

enum OfficeOriginalEditStatus { saved, cancelled }

class OfficeOriginalEditResult {
  const new({
    required this.status,
    required this.engineVersion,
    this.sessionId,
    this.sourcePath,
    this.pdfPath,
    this.sourceSha256,
    this.pdfSha256,
    this.pdfPageCount,
    this.inputSourceSha256,
    this.closeReason,
  });

  final OfficeOriginalEditStatus status;
  final String engineVersion;
  final String? sessionId;
  final String? sourcePath;
  final String? pdfPath;
  final String? sourceSha256;
  final String? pdfSha256;
  final int? pdfPageCount;
  final String? inputSourceSha256;

  /// On a cancelled close: 'unchanged' (nothing changed since it opened) or 'discarded' (저장 안 함).
  final String? closeReason;
}

class OfficeConversionResult {
  const new({
    required this.originalBytes,
    required this.pdfBytes,
    required this.engineVersion,
    required this.pageCount,
    required this.targetExtension,
  });

  final Uint8List originalBytes;
  final Uint8List pdfBytes;
  final String engineVersion;
  final int pageCount;
  final String targetExtension;
}
