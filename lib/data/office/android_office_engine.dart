import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/services.dart';
import 'package:ink_vault_core/ink_vault_core.dart' show newId, validateId;
import 'package:path/path.dart' as p;
import 'package:saber/data/app_external_screen.dart';
import 'package:saber/data/office/office_original_edit_result.dart';

export 'office_original_edit_result.dart';

typedef AndroidOfficeEditStatus = OfficeOriginalEditStatus;
typedef AndroidOfficeEditResult = OfficeOriginalEditResult;

class AndroidOfficePreviewResult {
  const new({
    required this.sessionId,
    required this.pdfPath,
    required this.sourceSha256,
    required this.pdfSha256,
    required this.pageCount,
    required this.engineVersion,
  }) : _lease = null;
  new _owned({
    required this.sessionId,
    required this.pdfPath,
    required this.sourceSha256,
    required this.pdfSha256,
    required this.pageCount,
    required this.engineVersion,
    required Future<void> Function() release,
  }) : _lease = _AndroidPreviewLease(release);
  final String sessionId;
  final String pdfPath;
  final String sourceSha256;
  final String pdfSha256;
  final int pageCount;
  final String engineVersion;
  final _AndroidPreviewLease? _lease;

  Future<void> dispose() => _lease?.dispose() ?? Future<void>.value();
}

class _AndroidPreviewLease {
  new(this.release);
  final Future<void> Function() release;
  Future<void>? _released;
  Future<void> dispose() => _released ??= release();
}

class AndroidOfficeCapabilities {
  const new({
    required this.available,
    required this.engineVersion,
    required this.editableFormats,
    this.supportsHwp = false,
    this.supportsHwpx = false,
    this.supportsLegacyConversion = false,
  });

  final bool available;
  final String engineVersion;
  final List<String> editableFormats;
  final bool supportsHwp;
  final bool supportsHwpx;
  final bool supportsLegacyConversion;
}

enum AndroidOfficeRecoveryStatus { missing, working, saved }

class AndroidOfficeRecoveryResult {
  const new({
    required this.status,
    required this.sessionId,
    required this.inputSourceSha256,
    required this.engineVersion,
    this.workingPath,
    this.workingSha256,
    this.savedResult,
  });
  final AndroidOfficeRecoveryStatus status;
  final String sessionId;
  final String inputSourceSha256;
  final String engineVersion;
  final String? workingPath;
  final String? workingSha256;
  final AndroidOfficeEditResult? savedResult;
}

class AndroidOfficeNativeObservationResult {
  const new _(
    this._preview, {
    required this.format,
    required this.observationPath,
    required this.observationSha256,
    required this.observationByteLength,
    required this.partCount,
    required this.nativeInfo,
  });

  final AndroidOfficePreviewResult _preview;
  final String format;
  final String observationPath;
  final String observationSha256;
  final int observationByteLength;
  final int partCount;
  final Map<String, Object?> nativeInfo;

  String get sessionId => _preview.sessionId;
  String get pdfPath => _preview.pdfPath;
  String get sourceSha256 => _preview.sourceSha256;
  String get pdfSha256 => _preview.pdfSha256;
  int get pageCount => _preview.pageCount;
  String get engineVersion => _preview.engineVersion;
  bool get sourceTableEditingSupported => false;
  bool get cellTextEditingSupported => false;
  Future<void> dispose() => _preview.dispose();
}

class AndroidOfficeEngine {
  Future<OfficeConversionResult?> convertLegacy({
    required File source,
    required String sessionId,
    required String expectedSourceSha256,
  }) async {
    if (!_supportedPlatform) {
      throw PlatformException(
        code: 'office_unavailable',
        message: '이 기기에 맞는 문서 변환 엔진이 없습니다.',
      );
    }
    validateId(sessionId);
    final target = switch (p.extension(source.path).toLowerCase()) {
      '.doc' => 'docx',
      '.ppt' => 'pptx',
      _ => null,
    };
    if (target == null ||
        !p.isAbsolute(source.path) ||
        !_normalizedObservationPath(source.path) ||
        !_hash(expectedSourceSha256)) {
      throw ArgumentError('Expected an absolute DOC or PPT source and SHA-256');
    }
    final sourceBefore = await _conversionFingerprint(source);
    if (sourceBefore.sha256 != expectedSourceSha256) throw _invalidConversion();

    var ownsConverted = false;
    AndroidOfficePreviewResult? pdf;
    try {
      final response = _previewResponseMap(
        await AppExternalScreen.run(
          () => _channel.invokeMethod<Object?>('convertLegacy', {
            'sourcePath': source.path,
            'sessionId': sessionId,
            'inputSourceSha256': expectedSourceSha256,
          }),
        ),
      );
      if (response == null || response['sessionId'] != sessionId) {
        throw _invalidConversion();
      }
      final version = response['engineVersion'];
      final validVersion =
          version is String &&
          version.trim().isNotEmpty &&
          version.length <= 128;
      if (response['status'] == 'cancelled') {
        if (response.length != 3 || !validVersion) throw _invalidConversion();
        return null;
      }
      final outputPath = response['sourcePath'];
      final root = _conversionLeaseRoot(outputPath, 'converted.$target');
      final convertedHash = response['sourceSha256'];
      ownsConverted =
          response['status'] == 'converted' &&
          response['inputSourceSha256'] == expectedSourceSha256 &&
          response['targetExtension'] == target &&
          root != null;
      if (!ownsConverted ||
          response.length != 7 ||
          !validVersion ||
          !_hash(convertedHash) ||
          convertedHash == expectedSourceSha256) {
        throw _invalidConversion();
      }
      final candidate = File(outputPath as String);
      if (!_conversionOwnedFile(candidate)) throw _invalidConversion();
      final candidateBefore = await _conversionFingerprint(
        candidate,
        ooxml: true,
      );
      if (candidateBefore.sha256 != convertedHash) throw _invalidConversion();

      final reopenedSession = newId();
      try {
        pdf = await _requestPreview(
          sourcePath: candidate.path,
          sessionId: reopenedSession,
          conversionRoot: root,
        );
      } on PlatformException catch (error) {
        if (error.code == 'invalid_office_preview') throw _invalidConversion();
        rethrow;
      }
      final derived = pdf;
      if (derived == null) {
        if (!_conversionOwnedFile(candidate) ||
            await _conversionFingerprint(candidate, ooxml: true) !=
                candidateBefore) {
          throw _invalidConversion();
        }
        return null;
      }
      if (derived.sourceSha256 != convertedHash ||
          derived.engineVersion != version ||
          _conversionLeaseRoot(derived.pdfPath, 'preview.pdf') != root ||
          p.equals(p.dirname(derived.pdfPath), candidate.parent.path)) {
        throw _invalidConversion();
      }
      final originalBytes = await _readConversionFile(
        candidate,
        candidateBefore.sha256,
        expectedModified: candidateBefore.modified,
      );
      final pdfBytes = await _readConversionFile(
        File(derived.pdfPath),
        derived.pdfSha256,
        pdf: true,
      );
      return OfficeConversionResult(
        originalBytes: originalBytes.asUnmodifiableView(),
        pdfBytes: pdfBytes.asUnmodifiableView(),
        engineVersion: version,
        pageCount: derived.pageCount,
        targetExtension: target,
      );
    } finally {
      try {
        if (await _conversionFingerprint(source) != sourceBefore) {
          throw _invalidConversion();
        }
      } finally {
        try {
          await pdf?.dispose();
        } finally {
          if (ownsConverted) await _releasePreview(sessionId);
        }
      }
    }
  }

  static String? _conversionLeaseRoot(Object? path, String name) {
    if (path is! String ||
        !p.isAbsolute(path) ||
        !_normalizedObservationPath(path) ||
        p.basename(path) != name) {
      return null;
    }
    final directory = p.dirname(path);
    final leaf = p.basename(directory);
    final root = p.dirname(directory);
    if (!leaf.startsWith('preview-') ||
        leaf.length == 'preview-'.length ||
        p.basename(root) != 'office-previews') {
      return null;
    }
    return root;
  }

  Future<({String sha256, int length, DateTime modified})>
  _conversionFingerprint(File file, {bool ooxml = false}) async {
    try {
      return await _inspectionFileFingerprint(file, ooxml: ooxml);
    } on PlatformException {
      throw _invalidConversion();
    }
  }

  static Future<Uint8List> _readConversionFile(
    File file,
    String expectedHash, {
    bool pdf = false,
    DateTime? expectedModified,
  }) async {
    try {
      if (!_conversionOwnedFile(file)) throw _invalidConversion();
      final before = file.statSync();
      if (expectedModified != null &&
          !expectedModified.isAtSameMomentAs(before.modified)) {
        throw _invalidConversion();
      }
      final handle = await file.open();
      try {
        final length = await handle.length();
        if (length != before.size ||
            length < (pdf ? 10 : 4) ||
            length > 128 * 1024 * 1024) {
          throw _invalidConversion();
        }
        final bytes = await handle.read(length + 1);
        final after = file.statSync();
        if (bytes.length != length ||
            await handle.length() != length ||
            after.size != length ||
            !after.modified.isAtSameMomentAs(before.modified) ||
            !_conversionOwnedFile(file) ||
            crypto.sha256.convert(bytes).toString() != expectedHash) {
          throw _invalidConversion();
        }
        if (pdf) {
          final tail = Uint8List.sublistView(
            bytes,
            length > 2048 ? length - 2048 : 0,
          );
          if (latin1.decode(bytes.sublist(0, 5)) != '%PDF-' ||
              !latin1.decode(tail).contains('%%EOF')) {
            throw _invalidConversion();
          }
        } else if (!_hasOoxmlSignature(bytes)) {
          throw _invalidConversion();
        }
        return bytes;
      } finally {
        await handle.close();
      }
    } on FileSystemException {
      throw _invalidConversion();
    }
  }

  static bool _conversionOwnedFile(File file) =>
      FileSystemEntity.typeSync(file.path, followLinks: false) ==
          FileSystemEntityType.file &&
      FileSystemEntity.typeSync(file.parent.path, followLinks: false) ==
          FileSystemEntityType.directory &&
      FileSystemEntity.typeSync(file.parent.parent.path, followLinks: false) ==
          FileSystemEntityType.directory;

  static bool _hasOoxmlSignature(List<int> bytes) =>
      bytes.length >= 4 &&
      bytes[0] == 0x50 &&
      bytes[1] == 0x4b &&
      bytes[2] == 3 &&
      bytes[3] == 4;

  static PlatformException _invalidConversion() => PlatformException(
    code: 'invalid_office_conversion',
    message: '이 원본에 속한 편집용 복사본과 PDF를 확인하지 못했습니다.',
  );

  Future<AndroidOfficeNativeObservationResult?> inspectPresentation({
    required String sourcePath,
    required String sessionId,
    required String inputSourceSha256,
  }) async {
    if (!_supportedPlatform) {
      throw PlatformException(
        code: 'office_unavailable',
        message: '이 기기에 맞는 문서 관측 엔진이 없습니다.',
      );
    }
    try {
      validateId(sessionId);
    } on FormatException {
      throw ArgumentError('Expected a presentation observation session UUID');
    }
    final sourceContext = _observationPathContext(sourcePath);
    final format = sourceContext.extension(sourcePath).toLowerCase();
    if (!_normalizedObservationPath(sourcePath) ||
        !const {'.ppt', '.pptx', '.odp'}.contains(format) ||
        !_hash(inputSourceSha256)) {
      throw ArgumentError(
        'Expected an absolute presentation source and SHA-256',
      );
    }
    final source = File(sourcePath);
    final sourceBefore = await _inspectionFileFingerprint(source);
    if (sourceBefore.sha256 != inputSourceSha256) {
      throw _invalidObservation();
    }
    var retained = false, leaseGranted = false;
    try {
      final raw = await AppExternalScreen.run(
        () => _channel.invokeMethod<Object?>('inspect', {
          'sourcePath': sourcePath,
          'sessionId': sessionId,
          'inputSourceSha256': inputSourceSha256,
        }),
      );
      final response = _previewResponseMap(raw);
      if (response == null) throw _invalidObservation();
      if (response['status'] == 'cancelled') {
        if (response['sessionId'] != sessionId ||
            response.keys.any(
              (key) => !{'status', 'sessionId', 'engineVersion'}.contains(key),
            )) {
          throw _invalidObservation();
        }
        return null;
      }
      leaseGranted = _inspectionLeaseGrant(
        response,
        sourcePath,
        sessionId,
        inputSourceSha256,
        format.substring(1),
      );
      if (!leaseGranted) throw _invalidObservation();
      final observation = _decodeObservation(
        response,
        sourcePath,
        sessionId,
        inputSourceSha256,
        format.substring(1),
      );
      await _verifyObservationFiles(
        observation,
        response['nativeJson'] as String,
      );
      retained = true;
      return observation;
    } finally {
      var unchanged = false;
      try {
        final sourceAfter = await _inspectionFileFingerprint(source);
        unchanged =
            sourceAfter.sha256 == sourceBefore.sha256 &&
            sourceAfter.length == sourceBefore.length &&
            sourceAfter.modified.isAtSameMomentAs(sourceBefore.modified);
      } on PlatformException {
        unchanged = false;
      }
      try {
        if (!unchanged) {
          throw PlatformException(
            code: 'preview_source_changed',
            message: '문서 정보를 읽는 동안 작업 원본이 변경됐습니다. 원래 저장본은 보존됩니다.',
          );
        }
      } finally {
        if (leaseGranted && (!retained || !unchanged)) {
          await _releasePreview(sessionId);
        }
      }
    }
  }

  Future<void> _verifyObservationFiles(
    AndroidOfficeNativeObservationResult result,
    String nativeJson,
  ) async {
    final pdf = await _inspectionFileFingerprint(
      File(result.pdfPath),
      pdf: true,
    );
    if (pdf.sha256 != result.pdfSha256) throw _invalidObservation();
    final file = File(result.observationPath);
    try {
      if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
          FileSystemEntityType.file) {
        throw _invalidObservation();
      }
      final before = file.statSync();
      final handle = await file.open();
      try {
        final length = await handle.length();
        if (length < 1 ||
            length > 128 * 1024 ||
            length != result.observationByteLength ||
            length != before.size) {
          throw _invalidObservation();
        }
        final bytes = await handle.read(length + 1);
        final after = file.statSync();
        if (bytes.length != length ||
            await handle.length() != length ||
            after.size != length ||
            !after.modified.isAtSameMomentAs(before.modified) ||
            FileSystemEntity.typeSync(file.path, followLinks: false) !=
                FileSystemEntityType.file ||
            crypto.sha256.convert(bytes).toString() !=
                result.observationSha256 ||
            utf8.decode(bytes) != nativeJson) {
          throw _invalidObservation();
        }
      } finally {
        await handle.close();
      }
    } on FileSystemException {
      throw _invalidObservation();
    } on FormatException {
      throw _invalidObservation();
    }
  }

  Future<({String sha256, int length, DateTime modified})>
  _inspectionFileFingerprint(
    File file, {
    bool pdf = false,
    bool ooxml = false,
  }) async {
    try {
      if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
          FileSystemEntityType.file) {
        throw _invalidObservation();
      }
      final before = file.statSync();
      final handle = await file.open();
      try {
        final length = await handle.length();
        if (length < (pdf ? 10 : 1) ||
            length > 128 * 1024 * 1024 ||
            length != before.size) {
          throw _invalidObservation();
        }
        if (pdf) {
          if (ascii.decode(await handle.read(5), allowInvalid: true) !=
              '%PDF-') {
            throw _invalidObservation();
          }
          await handle.setPosition(length > 2048 ? length - 2048 : 0);
          if (!latin1.decode(await handle.read(2048)).contains('%%EOF')) {
            throw _invalidObservation();
          }
          await handle.setPosition(0);
        } else if (ooxml) {
          if (!_hasOoxmlSignature(await handle.read(4))) {
            throw _invalidObservation();
          }
          await handle.setPosition(0);
        }
        Stream<List<int>> chunks() async* {
          var remaining = length;
          while (remaining > 0) {
            final bytes = await handle.read(
              remaining > 64 * 1024 ? 64 * 1024 : remaining,
            );
            if (bytes.isEmpty) throw _invalidObservation();
            remaining -= bytes.length;
            yield bytes;
          }
        }

        final digest = (await crypto.sha256.bind(chunks()).first).toString();
        final after = file.statSync();
        if (await handle.length() != length ||
            after.size != length ||
            !after.modified.isAtSameMomentAs(before.modified) ||
            FileSystemEntity.typeSync(file.path, followLinks: false) !=
                FileSystemEntityType.file) {
          throw _invalidObservation();
        }
        return (sha256: digest, length: length, modified: before.modified);
      } finally {
        await handle.close();
      }
    } on FileSystemException {
      throw _invalidObservation();
    }
  }

  AndroidOfficeNativeObservationResult _decodeObservation(
    Map<String, dynamic>? response,
    String sourcePath,
    String sessionId,
    String sourceHash,
    String expectedFormat,
  ) {
    const keys = {
      'status',
      'sessionId',
      'sourceSha256',
      'pdfSha256',
      'pdfPath',
      'pdfPageCount',
      'engineVersion',
      'format',
      'observationPath',
      'observationSha256',
      'observationByteLength',
      'partCount',
      'nativeJson',
    };
    if (response == null ||
        response.keys.length != keys.length ||
        !response.keys.every(keys.contains)) {
      throw _invalidObservation();
    }
    final pdf = response['pdfPath'];
    final path = response['observationPath'];
    final version = response['engineVersion'];
    final pages = response['pdfPageCount'];
    final parts = response['partCount'];
    final byteLength = response['observationByteLength'];
    final native = response['nativeJson'];
    if (response['status'] != 'inspected' ||
        response['sessionId'] != sessionId ||
        response['sourceSha256'] != sourceHash ||
        response['format'] != expectedFormat ||
        !_hash(response['pdfSha256']) ||
        !_hash(response['observationSha256']) ||
        pdf is! String ||
        path is! String ||
        !_normalizedObservationPath(pdf) ||
        !_normalizedObservationPath(path) ||
        pdf == sourcePath ||
        path == sourcePath ||
        version is! String ||
        !RegExp(r'^[0-9A-Za-z_.+\-]{1,80}$').hasMatch(version) ||
        pages is! int ||
        pages < 1 ||
        parts is! int ||
        parts < 1 ||
        parts > 256 ||
        byteLength is! int ||
        byteLength < 1 ||
        byteLength > 128 * 1024 ||
        native is! String ||
        !_scalarObservationText(native)) {
      throw _invalidObservation();
    }
    final context = _observationPathContext(pdf);
    if (context.style != _observationPathContext(path).style ||
        context.basename(pdf) != 'preview.pdf' ||
        context.basename(path) != 'native-observation.json' ||
        !context.equals(context.dirname(pdf), context.dirname(path))) {
      throw _invalidObservation();
    }
    final bytes = utf8.encode(native);
    if (bytes.length != byteLength ||
        bytes.length > 128 * 1024 ||
        crypto.sha256.convert(bytes).toString() !=
            response['observationSha256']) {
      throw _invalidObservation();
    }
    final info = _parseObservationInfo(native);
    return AndroidOfficeNativeObservationResult._(
      AndroidOfficePreviewResult._owned(
        sessionId: sessionId,
        pdfPath: pdf,
        sourceSha256: sourceHash,
        pdfSha256: response['pdfSha256'] as String,
        pageCount: pages,
        engineVersion: version,
        release: () => _releasePreview(sessionId),
      ),
      format: expectedFormat,
      observationPath: path,
      observationSha256: response['observationSha256'] as String,
      observationByteLength: byteLength,
      partCount: parts,
      nativeInfo: info,
    );
  }

  static p.Context _observationPathContext(String value) =>
      RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value) ? p.windows : p.posix;

  static bool _normalizedObservationPath(String value) =>
      _absolutePath(value) &&
      !value.contains('\u0000') &&
      _observationPathContext(value).normalize(value) == value;

  static bool _scalarObservationText(String value) {
    for (var index = 0; index < value.length; index++) {
      final unit = value.codeUnitAt(index);
      if (unit >= 0xd800 && unit <= 0xdbff) {
        if (++index >= value.length) return false;
        final next = value.codeUnitAt(index);
        if (next < 0xdc00 || next > 0xdfff) return false;
      } else if (unit >= 0xdc00 && unit <= 0xdfff) {
        return false;
      }
    }
    return true;
  }

  static Map<String, Object?> _parseObservationInfo(String native) {
    var quoted = false, escaped = false, depth = 0;
    for (final unit in native.codeUnits) {
      if (quoted) {
        if (escaped) {
          escaped = false;
        } else if (unit == 92) {
          escaped = true;
        } else if (unit == 34) {
          quoted = false;
        }
      } else if (unit == 34) {
        quoted = true;
      } else if (unit == 123 || unit == 91) {
        if (++depth > 16) throw _invalidObservation();
      } else if (unit == 125 || unit == 93) {
        if (--depth < 0) throw _invalidObservation();
      }
    }
    if (quoted || depth != 0) throw _invalidObservation();
    Object? decoded;
    try {
      decoded = jsonDecode(native);
    } on FormatException {
      throw _invalidObservation();
    }
    var nodes = 0;
    Object? freeze(Object? value, int level) {
      if (++nodes > 4096 || level > 16) throw _invalidObservation();
      if (value is Map<String, dynamic>) {
        if (value.length > 128) throw _invalidObservation();
        final result = <String, Object?>{};
        for (final entry in value.entries) {
          if (entry.key.length > 128 || !_scalarObservationText(entry.key)) {
            throw _invalidObservation();
          }
          result[entry.key] = freeze(entry.value, level + 1);
        }
        return Map<String, Object?>.unmodifiable(result);
      }
      if (value is List) {
        return List<Object?>.unmodifiable([
          for (final item in value) freeze(item, level + 1),
        ]);
      }
      if (value is String) {
        if (value.length > 16384 || !_scalarObservationText(value)) {
          throw _invalidObservation();
        }
        return value;
      }
      if (value is num) {
        if (!value.isFinite) throw _invalidObservation();
        return value;
      }
      if (value == null || value is bool) return value;
      throw _invalidObservation();
    }

    final result = freeze(decoded, 0);
    if (result is! Map<String, Object?> || result.isEmpty) {
      throw _invalidObservation();
    }
    return result;
  }

  static PlatformException _invalidObservation() => PlatformException(
    code: 'invalid_office_observation',
    message: '이 원본과 세션에 속한 읽기 전용 문서 정보를 확인하지 못했습니다.',
  );

  Future<void> validateLegacySource({
    required String sourcePath,
    required String format,
    required String sourceSha256,
  }) async {
    if (!_supportedPlatform) {
      throw PlatformException(
        code: 'office_unavailable',
        message: '이 기기에 맞는 문서 편집 엔진이 없습니다.',
      );
    }
    if (!p.isAbsolute(sourcePath) ||
        !const {'doc', 'ppt'}.contains(format) ||
        !_hash(sourceSha256)) {
      throw _invalidRecovery();
    }
    final response = await _channel.invokeMapMethod<String, dynamic>(
      'validateLegacySource',
      {
        'sourcePath': sourcePath,
        'format': format,
        'sourceSha256': sourceSha256,
      },
    );
    if (response?.isEmpty != true) throw _invalidRecovery();
  }

  Future<AndroidOfficeRecoveryResult> recoverSession({
    required String sessionId,
    required String inputSourceSha256,
  }) async {
    _validateRecoveryRequest(sessionId, inputSourceSha256);
    final response = await _channel.invokeMapMethod<String, dynamic>(
      'recover',
      {'sessionId': sessionId, 'inputSourceSha256': inputSourceSha256},
    );
    return _decodeRecovery(response, sessionId, inputSourceSha256);
  }

  Future<AndroidOfficeEditResult> resumeSession({
    required String sessionId,
    required String inputSourceSha256,
  }) async {
    _validateRecoveryRequest(sessionId, inputSourceSha256);
    final response = await AppExternalScreen.run(
      () => _channel.invokeMapMethod<String, dynamic>('resume', {
        'sessionId': sessionId,
        'inputSourceSha256': inputSourceSha256,
      }),
    );
    if (response?['status'] == 'cancelled') {
      _requireRecoveryBinding(response, sessionId, inputSourceSha256);
      return AndroidOfficeEditResult(
        status: AndroidOfficeEditStatus.cancelled,
        sessionId: sessionId,
        inputSourceSha256: inputSourceSha256,
        engineVersion: response!['engineVersion'] as String,
      );
    }
    final recovered = _decodeRecovery(response, sessionId, inputSourceSha256);
    if (recovered.savedResult == null) throw _invalidRecovery();
    return recovered.savedResult!;
  }

  void _validateRecoveryRequest(String sessionId, String inputSourceSha256) {
    if (!_supportedPlatform)
      throw PlatformException(
        code: 'office_unavailable',
        message: '이 기기에 맞는 문서 편집 엔진이 없습니다.',
      );
    try {
      validateId(sessionId);
    } on FormatException {
      throw ArgumentError('Expected a recovery session UUID');
    }
    if (!_hash(inputSourceSha256))
      throw ArgumentError('Expected an original SHA-256');
  }

  void _requireRecoveryBinding(
    Map<String, dynamic>? response,
    String sessionId,
    String inputHash,
  ) {
    final version = response?['engineVersion'];
    if (response?['sessionId'] != sessionId ||
        response?['inputSourceSha256'] != inputHash ||
        version is! String ||
        version.trim().isEmpty)
      throw _invalidRecovery();
  }

  AndroidOfficeRecoveryResult _decodeRecovery(
    Map<String, dynamic>? response,
    String sessionId,
    String inputHash,
  ) {
    _requireRecoveryBinding(response, sessionId, inputHash);
    final version = response!['engineVersion'] as String;
    final status = response['status'];
    if (status == 'missing')
      return AndroidOfficeRecoveryResult(
        status: AndroidOfficeRecoveryStatus.missing,
        sessionId: sessionId,
        inputSourceSha256: inputHash,
        engineVersion: version,
      );
    if (status == 'working') {
      final path = response['workingPath'], hash = response['workingSha256'];
      if (!_officePath(path, 'working') || !_hash(hash))
        throw _invalidRecovery();
      return AndroidOfficeRecoveryResult(
        status: AndroidOfficeRecoveryStatus.working,
        sessionId: sessionId,
        inputSourceSha256: inputHash,
        engineVersion: version,
        workingPath: path as String,
        workingSha256: hash as String,
      );
    }
    final source = response['sourcePath'], pdf = response['pdfPath'];
    final sourceHash = response['sourceSha256'],
        pdfHash = response['pdfSha256'];
    final pages = response['pdfPageCount'];
    if (status != 'saved' ||
        !_officePath(source, 'edited') ||
        pdf is! String ||
        !_absolutePath(pdf) ||
        p.basename(pdf) != 'preview.pdf' ||
        source == pdf ||
        p.dirname(source as String) != p.dirname(pdf) ||
        !_hash(sourceHash) ||
        !_hash(pdfHash) ||
        pages is! int ||
        pages < 1)
      throw _invalidRecovery();
    return AndroidOfficeRecoveryResult(
      status: AndroidOfficeRecoveryStatus.saved,
      sessionId: sessionId,
      inputSourceSha256: inputHash,
      engineVersion: version,
      savedResult: AndroidOfficeEditResult(
        status: AndroidOfficeEditStatus.saved,
        sessionId: sessionId,
        inputSourceSha256: inputHash,
        engineVersion: version,
        sourcePath: source,
        pdfPath: pdf,
        sourceSha256: sourceHash as String,
        pdfSha256: pdfHash as String,
        pdfPageCount: pages,
      ),
    );
  }

  static bool _hash(Object? value) =>
      value is String && RegExp(r'^[a-f0-9]{64}$').hasMatch(value);
  static bool _absolutePath(String value) =>
      value.startsWith('/') || RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value);
  static bool _officePath(Object? value, String basename) =>
      value is String &&
      _absolutePath(value) &&
      p.basenameWithoutExtension(value) == basename &&
      const {
        '.docx',
        '.pptx',
        '.doc',
        '.ppt',
        '.odt',
        '.odp',
      }.contains(p.extension(value).toLowerCase());
  static PlatformException _invalidRecovery() => PlatformException(
    code: 'invalid_office_recovery',
    message: '이 문서에 속한 복구 작업과 저장 파일을 확인하지 못했습니다.',
  );
  Future<AndroidOfficePreviewResult?> preview({
    required String sourcePath,
    required String sessionId,
  }) => _requestPreview(sourcePath: sourcePath, sessionId: sessionId);

  Future<AndroidOfficePreviewResult?> _requestPreview({
    required String sourcePath,
    required String sessionId,
    String? conversionRoot,
  }) async {
    if (!_supportedPlatform)
      throw PlatformException(
        code: 'office_unavailable',
        message: '이 기기에 맞는 문서 미리보기 엔진이 없습니다.',
      );
    if (sourcePath.isEmpty || sessionId.trim().isEmpty)
      throw ArgumentError('Expected a source and preview session');
    var retained = false, leaseGranted = false;
    try {
      final raw = await AppExternalScreen.run(
        () => _channel.invokeMethod<Object?>('preview', {
          'sourcePath': sourcePath,
          'sessionId': sessionId,
        }),
      );
      final result = _previewResponseMap(raw);
      if (result == null) throw _invalidPreview();
      if (result['status'] == 'cancelled') {
        if (result.containsKey('sessionId') &&
            result['sessionId'] != sessionId) {
          throw _invalidPreview();
        }
        return null;
      }
      final validLease = _previewLeaseGrant(result, sourcePath, sessionId);
      leaseGranted =
          validLease ||
          conversionRoot != null &&
              result['status'] == 'previewed' &&
              result['sessionId'] == sessionId &&
              _conversionLeaseRoot(result['pdfPath'], 'preview.pdf') ==
                  conversionRoot;
      if (!validLease) throw _invalidPreview();
      final path = result['pdfPath'],
          sourceHash = result['sourceSha256'],
          pdfHash = result['pdfSha256'];
      final pages = result['pdfPageCount'], version = result['engineVersion'];
      if (path is! String ||
          sourceHash is! String ||
          pdfHash is! String ||
          pages is! int ||
          pages < 1 ||
          version is! String ||
          version.trim().isEmpty) {
        throw _invalidPreview();
      }
      final preview = AndroidOfficePreviewResult._owned(
        sessionId: sessionId,
        pdfPath: path,
        sourceSha256: sourceHash,
        pdfSha256: pdfHash,
        pageCount: pages,
        engineVersion: version,
        release: () => _releasePreview(sessionId),
      );
      retained = true;
      return preview;
    } finally {
      if (leaseGranted && !retained) await _releasePreview(sessionId);
    }
  }

  static Map<String, dynamic>? _previewResponseMap(Object? response) {
    if (response is! Map || response.keys.any((key) => key is! String)) {
      return null;
    }
    return Map<String, dynamic>.from(response);
  }

  static bool _previewLeaseGrant(
    Map<String, dynamic> response,
    String sourcePath,
    String sessionId, {
    String status = 'previewed',
  }) {
    final path = response['pdfPath'];
    return response['status'] == status &&
        response['sessionId'] == sessionId &&
        _hash(response['sourceSha256']) &&
        _hash(response['pdfSha256']) &&
        path is String &&
        _normalizedObservationPath(path) &&
        path != sourcePath &&
        path.toLowerCase().endsWith('.pdf');
  }

  static bool _inspectionLeaseGrant(
    Map<String, dynamic> response,
    String sourcePath,
    String sessionId,
    String sourceSha256,
    String format,
  ) {
    if (!_previewLeaseGrant(
          response,
          sourcePath,
          sessionId,
          status: 'inspected',
        ) ||
        response['sourceSha256'] != sourceSha256 ||
        response['format'] != format) {
      return false;
    }
    final path = response['observationPath'], pdf = response['pdfPath'];
    if (path is! String ||
        pdf is! String ||
        !_normalizedObservationPath(path) ||
        path == sourcePath) {
      return false;
    }
    final context = _observationPathContext(pdf);
    return context.style == _observationPathContext(path).style &&
        context.basename(pdf) == 'preview.pdf' &&
        context.basename(path) == 'native-observation.json' &&
        context.equals(context.dirname(pdf), context.dirname(path));
  }

  static PlatformException _invalidPreview() => PlatformException(
    code: 'invalid_office_preview',
    message: '원본을 바꾸지 않는 PDF 미리보기 결과를 확인하지 못했습니다.',
  );

  Future<void> _releasePreview(String sessionId) async {
    try {
      await _channel.invokeMethod<void>('releasePreview', {
        'sessionId': sessionId,
      });
    } catch (_) {
      // Native cleanup never changes the preview's original result or error.
    }
  }

  const new({
    this._channel = const MethodChannel('personal_ink_vault/office_engine'),
    this._isAndroid,
  });

  final MethodChannel _channel;
  final bool? _isAndroid;
  bool get _supportedPlatform => _isAndroid ?? Platform.isAndroid;

  Future<AndroidOfficeCapabilities> capabilities() async {
    if (!_supportedPlatform) {
      return const AndroidOfficeCapabilities(
        available: false,
        engineVersion: '',
        editableFormats: [],
      );
    }
    final response = await _channel.invokeMapMethod<String, dynamic>(
      'capabilities',
    );
    return AndroidOfficeCapabilities(
      available: response?['available'] == true,
      engineVersion: response?['engineVersion'] as String? ?? '',
      editableFormats: List<String>.from(
        response?['editableFormats'] as List? ?? const [],
      ),
      supportsHwp: response?['supportsHwp'] == true,
      supportsHwpx: response?['supportsHwpx'] == true,
      supportsLegacyConversion: response?['supportsLegacyConversion'] == true,
    );
  }

  Future<AndroidOfficeEditResult> edit({
    required String sourcePath,
    required String sessionId,
  }) async {
    if (!_supportedPlatform) {
      throw PlatformException(
        code: 'office_unavailable',
        message: '이 기기에 맞는 문서 편집 엔진이 없습니다.',
      );
    }
    if (sourcePath.isEmpty || sessionId.trim().isEmpty) {
      throw ArgumentError('sourcePath and sessionId must not be empty.');
    }
    final response = await AppExternalScreen.run(
      () => _channel.invokeMapMethod<String, dynamic>('edit', {
        'sourcePath': sourcePath,
        'sessionId': sessionId,
      }),
    );
    final version = response?['engineVersion'] as String? ?? '';
    if (response?['status'] == 'cancelled') {
      return AndroidOfficeEditResult(
        status: AndroidOfficeEditStatus.cancelled,
        engineVersion: version,
      );
    }
    final edited = response?['sourcePath'];
    final pdf = response?['pdfPath'];
    final sourceHash = response?['sourceSha256'];
    final pdfHash = response?['pdfSha256'];
    final pages = response?['pdfPageCount'];
    final inputHash = response?['inputSourceSha256'];
    final validHash = RegExp(r'^[a-f0-9]{64}$');
    if (response?['status'] != 'saved' ||
        response?['sessionId'] != sessionId ||
        edited is! String ||
        edited.isEmpty ||
        edited == sourcePath ||
        pdf is! String ||
        pdf.isEmpty ||
        pdf == edited ||
        sourceHash is! String ||
        !validHash.hasMatch(sourceHash) ||
        pdfHash is! String ||
        !validHash.hasMatch(pdfHash) ||
        pages is! int ||
        pages < 1 ||
        inputHash != null && !_hash(inputHash)) {
      throw PlatformException(
        code: 'invalid_office_result',
        message: '수정된 원본과 PDF의 저장 결과를 확인하지 못했습니다.',
      );
    }
    return AndroidOfficeEditResult(
      status: AndroidOfficeEditStatus.saved,
      engineVersion: version,
      sessionId: sessionId,
      sourcePath: edited,
      pdfPath: pdf,
      sourceSha256: sourceHash,
      pdfSha256: pdfHash,
      pdfPageCount: pages,
      inputSourceSha256: inputHash as String?,
    );
  }
}
