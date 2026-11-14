import 'dart:collection';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:saber/data/office/office_image_asset.dart';
import 'package:saber/data/office/windows_office_engine.dart';

typedef HwpOfficeRunner = Future<Map<String, dynamic>> Function(
  Map<String, Object?> request,
);

class HwpOfficeException implements Exception {
  const new(this.code, this.message, [this.details = const {}]);
  final String code;
  final String message;
  final Map<String, dynamic> details;
  @override
  String toString() => 'HwpOfficeException($code): $message';
}

class HwpOfficeEngine {
  new({this._libraryPath, this._fontDirectory, this._runner});
  final String? _libraryPath;
  final String? _fontDirectory;
  final HwpOfficeRunner? _runner;
  static const editableFormats = ['hwp', 'hwpx'];
  static const maxTableInsertRows = 8;
  static const maxTableInsertColumns = 6;
  static const maxTableCellLength = 120;
  static const fontAsset = 'build/native/fonts/NotoSansCJKkr-Regular.otf';
  static const licenseAsset = 'build/native/fonts/OFL.txt';
  static const fontSha256 =
      '6bcb2a0703aa137e874fc2dffa85f6c21ba9a67fa329e81b8c801663af7e992a';
  static const _licenseSha256 =
      'aa740660d65a99854f1acbcedead0741255ad09d911f19f63d4e1086cb256804';
  static Future<String>? _preparedFonts;

  Future<bool> get available async {
    if (_runner != null) return true;
    final library = _libraryPath;
    try {
      return await Isolate.run(
        () => _NativeHwp.open(library).version.isNotEmpty,
      );
    } on Object {
      return false;
    }
  }

  Future<Map<String, dynamic>> inspect(
    String sourcePath, {
    bool preview = false,
  }) async {
    _format(sourcePath);
    final before = await _hash(File(sourcePath));
    final result = await _invoke({
      'mode': 'inspect',
      'sourcePath': sourcePath,
      'preview': preview,
    });
    try {
      final snapshot = _object(result['snapshot']);
      if (snapshot['kind'] != 'word' ||
          snapshot['sourceSha256'] != before ||
          await _hash(File(sourcePath)) != before) {
        throw const HwpOfficeException(
          'source_changed',
          '원본 판본이 바뀌었습니다. 문서를 다시 열어 주세요.',
        );
      }
      if (preview) {
        final path = snapshot['previewPdfPath'];
        final hash = snapshot['previewPdfSha256'];
        final pages = snapshot['previewPageCount'];
        if (path is! String ||
            hash is! String ||
            pages is! int ||
            pages < 1 ||
            await _hash(File(path)) != hash ||
            !await _isPdf(File(path))) {
          throw const HwpOfficeException(
            'invalid_preview',
            '문서 미리보기를 확인하지 못했습니다.',
          );
        }
      }
      return result;
    } catch (_) {
      if (result is _OwnedHwpInspection) await result.dispose();
      rethrow;
    }
  }

  /// Renders every page of the original to a separate PDF with rhwp. Unlike
  /// [inspect], this does not require the document to be structurally editable.
  Future<Map<String, dynamic>> renderPdf(String sourcePath) async {
    _format(sourcePath);
    final before = await _hash(File(sourcePath));
    final result = await _invoke({'mode': 'pdf', 'sourcePath': sourcePath});
    try {
      if (result['sourceSha256'] != before ||
          await _hash(File(sourcePath)) != before) {
        throw const HwpOfficeException(
          'source_changed',
          '원본 판본이 바뀌었습니다. 문서를 다시 열어 주세요.',
        );
      }
      final path = result['pdfPath'];
      final hash = result['pdfSha256'];
      final pages = result['pdfPageCount'];
      final version = result['engineVersion'];
      if (path is! String ||
          hash is! String ||
          pages is! int ||
          pages < 1 ||
          version is! String ||
          version.trim().isEmpty ||
          await _hash(File(path)) != hash ||
          !await _isPdf(File(path))) {
        throw const HwpOfficeException(
          'invalid_preview',
          '문서 미리보기를 확인하지 못했습니다.',
        );
      }
      return result;
    } catch (_) {
      if (result is _OwnedHwpInspection) await result.dispose();
      rethrow;
    }
  }

  Future<Map<String, dynamic>> apply(
    String sourcePath, {
    required List<Map<String, Object?>> operations,
    required String sessionId,
    String? expectedSourceSha256,
  }) async {
    _format(sourcePath);
    if (sessionId.trim().isEmpty ||
        operations.isEmpty ||
        operations.length > 128)
      throw ArgumentError('Expected an edit session and bounded operations');
    final insertedIds = <String>{};
    final insertionAnchors = <String>{};
    for (final operation in operations) {
      if (operation['op'] == 'tableStructure') {
        final action = operation['action'];
        if (p.extension(sourcePath).toLowerCase() == '.hwp' &&
            (action == 'insertColumn' || action == 'deleteColumn')) {
          throw const HwpOfficeException(
            'unsupported_operation',
            '표의 열 편집은 HWPX 문서에서 지원합니다.',
          );
        }
        final id = operation['id'];
        final index = operation['index'];
        final maxIndex = switch (action) {
          'insertRow' ||
          'deleteRow' => WindowsOfficeHwpTableStructure.maxRows - 1,
          'insertColumn' ||
          'deleteColumn' => WindowsOfficeHwpTableStructure.maxColumns - 1,
          _ => -1,
        };
        if (operations.length != 1 ||
            expectedSourceSha256 == null ||
            expectedSourceSha256.length != 64 ||
            !_sha.hasMatch(expectedSourceSha256) ||
            operation.length != 4 ||
            id is! String ||
            id.length > 128 ||
            _tableStructureId.stringMatch(id) != id ||
            index is! int ||
            index < 0 ||
            index > maxIndex) {
          throw const HwpOfficeException(
            'invalid_request',
            '한글 표의 작업과 위치를 확인하고 다른 편집 내용을 먼저 저장해 주세요.',
          );
        }
        continue;
      }
      if (operation['op'] == 'tableInsert') {
        if (p.extension(sourcePath).toLowerCase() != '.hwpx') {
          throw const HwpOfficeException(
            'unsupported_operation',
            '표 추가는 HWPX 문서에서만 지원합니다.',
          );
        }
        const fields = {
          'op',
          'id',
          'referenceId',
          'position',
          'expectedTextSha256',
          'rows',
          'columns',
        };
        final id = operation['id'];
        final anchor = operation['referenceId'];
        final digest = operation['expectedTextSha256'];
        final rows = operation['rows'];
        final columns = operation['columns'];
        final hasCells = operation.containsKey('cells');
        if (operations.length != 1 ||
            expectedSourceSha256 == null ||
            expectedSourceSha256.length != 64 ||
            !_sha.hasMatch(expectedSourceSha256) ||
            operation.length != fields.length + (hasCells ? 1 : 0) ||
            !fields.every(operation.containsKey) ||
            id is! String ||
            anchor is! String ||
            !isValidTableInsertTarget(id, anchor) ||
            operation['position'] != 'after' ||
            digest is! String ||
            digest.length != 64 ||
            !_sha.hasMatch(digest) ||
            rows is! int ||
            rows < 1 ||
            rows > maxTableInsertRows ||
            columns is! int ||
            columns < 1 ||
            columns > maxTableInsertColumns ||
            hasCells &&
                !isValidTableInsertCells(operation['cells'], rows, columns)) {
          throw const HwpOfficeException(
            'invalid_request',
            '표 크기, 셀 내용과 기준 문단을 확인하고 다른 편집 내용을 먼저 저장해 주세요.',
          );
        }
        continue;
      }
      if (operation['op'] == 'paragraphInsert') {
        const fields = {
          'op',
          'id',
          'referenceId',
          'position',
          'expectedTextSha256',
          'text',
        };
        final id = operation['id'];
        final referenceId = operation['referenceId'];
        final digest = operation['expectedTextSha256'];
        final text = operation['text'];
        if (operation.length != fields.length ||
            !operation.keys.every(fields.contains) ||
            id is! String ||
            id.length > 256 ||
            id.trim().isEmpty ||
            !_wellFormedUtf16(id) ||
            _isParagraphAnchor(id) ||
            referenceId is! String ||
            referenceId.length > 256 ||
            !_isParagraphAnchor(referenceId) ||
            operation['position'] != 'after' ||
            digest is! String ||
            digest.length != 64 ||
            !_sha.hasMatch(digest) ||
            text is! String ||
            !isValidParagraphInsertText(text) ||
            !insertedIds.add(id) ||
            !insertionAnchors.add(referenceId)) {
          throw const HwpOfficeException(
            'invalid_request',
            '추가할 문단이나 기준 문단이 올바르지 않습니다.',
          );
        }
        continue;
      }
      if (operation['op'] == 'paragraphDelete') {
        const fields = {'op', 'id', 'expectedTextSha256'};
        final id = operation['id'];
        final digest = operation['expectedTextSha256'];
        if (operations.length != 1 ||
            operation.length != fields.length ||
            !operation.keys.every(fields.contains) ||
            id is! String ||
            id.length > 256 ||
            !_isParagraphAnchor(id) ||
            digest is! String ||
            digest.length != 64 ||
            !_sha.hasMatch(digest)) {
          throw const HwpOfficeException(
            'invalid_request',
            '삭제할 본문 문단을 확인하고 다른 편집 내용을 먼저 저장해 주세요.',
          );
        }
        continue;
      }
      if (operation['op'] == 'textStyle' || operation['op'] == 'textReplace') {
        _validateTextOperation(operation);
        continue;
      }
      if (operation['op'] == 'paragraphFormat') {
        const fields = {'op', 'id', 'expectedTextSha256', 'alignment'};
        final id = operation['id'];
        final digest = operation['expectedTextSha256'];
        final alignment = operation['alignment'];
        if (operation.length != fields.length ||
            !operation.keys.every(fields.contains) ||
            id is! String ||
            id.isEmpty ||
            digest is! String ||
            !_sha.hasMatch(digest) ||
            !const ['left', 'center', 'right', 'justify'].contains(alignment)) {
          throw const HwpOfficeException(
            'invalid_request',
            '문단 정렬 요청이 올바르지 않습니다. 원본 문서를 다시 열어 주세요.',
          );
        }
        continue;
      }
      if (!['paragraphText', 'tableCellText'].contains(operation['op'])) {
        throw const HwpOfficeException(
          'unsupported_operation',
          'HWP에서는 문단·표 셀의 글자, 지원되는 글자 서식과 문단 정렬을 편집할 수 있습니다.',
        );
      }
    }
    final before = await _hash(File(sourcePath));
    if (expectedSourceSha256 != null && expectedSourceSha256 != before) {
      throw const HwpOfficeException(
        'source_changed',
        '원본 판본이 바뀌었습니다. 문서를 다시 열어 주세요.',
      );
    }
    final result = await _invoke({
      'mode': 'apply',
      'sourcePath': sourcePath,
      'sessionId': sessionId,
      'expectedSourceSha256': expectedSourceSha256 ?? before,
      'operations': operations,
    });
    final edited = result['sourcePath'];
    final pdf = result['pdfPath'];
    final originalHash = result['sourceSha256'];
    final pdfHash = result['pdfSha256'];
    final pages = result['pdfPageCount'];
    if (result['status'] != 'saved' ||
        result['sessionId'] != sessionId ||
        edited is! String ||
        pdf is! String ||
        originalHash is! String ||
        pdfHash is! String ||
        pages is! int ||
        pages < 1 ||
        result['engineVersion'] is! String ||
        !_sha.hasMatch(originalHash) ||
        !_sha.hasMatch(pdfHash) ||
        _samePath(edited, sourcePath) ||
        _samePath(edited, pdf) ||
        _samePath(pdf, sourcePath)) {
      throw const HwpOfficeException('invalid_result', '문서 저장 결과를 확인하지 못했습니다.');
    }
    if (await _hash(File(edited)) != originalHash ||
        await _hash(File(pdf)) != pdfHash ||
        !await _isPdf(File(pdf))) {
      throw const HwpOfficeException(
        'payload_mismatch',
        '저장된 파일이 편집 결과와 일치하지 않습니다.',
      );
    }
    if (await _hash(File(sourcePath)) != before)
      throw const HwpOfficeException('source_changed', '작업 중 원본 판본이 바뀌었습니다.');
    final model = _object(result['snapshot']);
    if (model['kind'] != 'word' || model['sourceSha256'] != originalHash) {
      throw const HwpOfficeException(
        'invalid_result',
        '저장된 문서 판본을 확인하지 못했습니다.',
      );
    }
    return result;
  }

  static void _validateTextOperation(Map<String, Object?> operation) {
    const styleFields = ['bold', 'italic', 'underline', 'fontSize', 'color'];
    final replacing = operation['op'] == 'textReplace';
    final cellTarget = operation['targetKind'] == 'cell';
    final fields = {
      'op',
      'targetKind',
      'id',
      'startUtf16',
      'endUtf16',
      'expectedTextSha256',
      if (cellTarget) 'cell',
      if (replacing) 'text' else ...styleFields,
    };
    final id = operation['id'];
    final start = operation['startUtf16'];
    final end = operation['endUtf16'];
    final digest = operation['expectedTextSha256'];
    var valid =
        operation.keys.every(fields.contains) &&
        const ['paragraph', 'cell'].contains(operation['targetKind']) &&
        id is String &&
        id.isNotEmpty &&
        start is int &&
        start >= 0 &&
        end is int &&
        (replacing ? end >= start : end > start) &&
        digest is String &&
        _sha.hasMatch(digest);
    if (cellTarget) {
      final cell = operation['cell'];
      valid =
          valid &&
          cell is String &&
          RegExp(r'^(0|[1-9][0-9]*),(0|[1-9][0-9]*)$').hasMatch(cell) &&
          cell
              .split(',')
              .every((part) => (int.tryParse(part) ?? 65536) <= 65535);
    }
    if (replacing) {
      final text = operation['text'];
      valid = valid && text is String && _wellFormedUtf16(text);
    } else {
      valid = valid && styleFields.any(operation.containsKey);
      if (operation.containsKey('bold'))
        valid = valid && operation['bold'] is bool;
      if (operation.containsKey('italic'))
        valid = valid && operation['italic'] is bool;
      if (operation.containsKey('underline'))
        valid = valid && operation['underline'] is bool;
      if (operation.containsKey('fontSize')) {
        final size = operation['fontSize'];
        valid =
            valid && size is num && size.isFinite && size >= 1 && size <= 400;
      }
      if (operation.containsKey('color')) {
        final color = operation['color'];
        valid = valid && color is int && color >= 0 && color <= 0xffffff;
      }
    }
    if (!valid) {
      throw const HwpOfficeException(
        'invalid_request',
        '선택한 글자의 편집 요청이 올바르지 않습니다. 문서를 다시 열어 주세요.',
      );
    }
  }

  static bool isValidParagraphInsertText(String text) =>
      text.length <= 4096 &&
      text.trim().isNotEmpty &&
      _wellFormedUtf16(text) &&
      text.codeUnits.every((unit) => unit >= 0x20 && unit < 0xfffe);

  static final _paragraphAnchor = RegExp(
    r's(?:0|[1-9][0-9]*):p(?:0|[1-9][0-9]*)',
  );

  static bool isValidTableInsertTarget(String id, String anchor) =>
      _tableInsertId.stringMatch(id) == id &&
      !_isParagraphAnchor(id) &&
      anchor.length <= 256 &&
      _isParagraphAnchor(anchor);

  static bool isValidTableInsertCells(Object? cells, int rows, int columns) =>
      rows >= 1 &&
      rows <= maxTableInsertRows &&
      columns >= 1 &&
      columns <= maxTableInsertColumns &&
      cells is List &&
      cells.length == rows &&
      cells.every(
        (row) =>
            row is List &&
            row.length == columns &&
            row.every((cell) => cell is String && isValidTableCellText(cell)),
      );

  static bool isValidTableCellText(String text) =>
      text.length <= maxTableCellLength &&
      _wellFormedUtf16(text) &&
      text.codeUnits.every(
        (unit) =>
            unit >= 0x20 &&
            (unit < 0x7f || unit >= 0xa0) &&
            unit != 0x2028 &&
            unit != 0x2029 &&
            unit < 0xfffe,
      );

  static bool _isParagraphAnchor(String id) =>
      _paragraphAnchor.matchAsPrefix(id)?.end == id.length;

  static bool _wellFormedUtf16(String text) {
    final units = text.codeUnits;
    for (var i = 0; i < units.length; i++) {
      final unit = units[i];
      if (unit >= 0xd800 && unit <= 0xdbff) {
        if (++i >= units.length || units[i] < 0xdc00 || units[i] > 0xdfff)
          return false;
      } else if (unit >= 0xdc00 && unit <= 0xdfff) {
        return false;
      }
    }
    return true;
  }

  Future<Map<String, dynamic>> _invoke(Map<String, Object?> request) async {
    final runner = _runner;
    if (runner != null) return _response(await runner(request));
    final library = _libraryPath;
    final work = await Directory.systemTemp.createTemp(
      'personal-ink-vault-hwp-',
    );
    var retainOutput = false;
    final pdf = request['mode'] == 'pdf';
    try {
      final nativeRequest = {...request, 'outputDirectory': work.path};
      if (request['mode'] == 'apply' || request['preview'] == true || pdf)
        nativeRequest['fontDirectories'] = [await _fonts()];
      final result = await Isolate.run(
        () => _NativeHwp.open(library).invoke(nativeRequest),
      );
      final response = _response(result);
      retainOutput =
          request['mode'] == 'apply' || request['preview'] == true || pdf;
      if ((request['mode'] == 'inspect' && request['preview'] == true) || pdf) {
        return _OwnedHwpInspection(response, work);
      }
      return response;
    } finally {
      if (!retainOutput && work.existsSync())
        await work.delete(recursive: true);
    }
  }

  Future<String> _fonts() async {
    final explicit = _fontDirectory;
    if (explicit != null) {
      if (await _hash(File(p.join(explicit, 'NotoSansCJKkr-Regular.otf'))) !=
          fontSha256) {
        throw const HwpOfficeException(
          'fonts_unavailable',
          '문서 글꼴 파일을 확인하지 못했습니다.',
        );
      }
      return explicit;
    }
    return _preparedFonts ??= _prepareFonts().catchError((Object error) {
      _preparedFonts = null;
      throw error;
    });
  }

  static Future<String> _prepareFonts() async {
    try {
      final support = await getApplicationSupportDirectory();
      final directory = await Directory(
        p.join(support.path, 'hwp-fonts', fontSha256.substring(0, 16)),
      ).create(recursive: true);
      for (final entry in [
        (fontAsset, 'NotoSansCJKkr-Regular.otf', fontSha256),
        (licenseAsset, 'OFL.txt', _licenseSha256),
      ]) {
        final output = File(p.join(directory.path, entry.$2));
        if (output.existsSync() && await _hash(output) == entry.$3) continue;
        final data = await rootBundle.load(entry.$1);
        final bytes = data.buffer.asUint8List(
          data.offsetInBytes,
          data.lengthInBytes,
        );
        if (sha256.convert(bytes).toString() != entry.$3)
          throw const FormatException('Invalid bundled HWP font asset');
        final staging = File('${output.path}.tmp');
        await staging.writeAsBytes(bytes, flush: true);
        if (output.existsSync()) await output.delete();
        await staging.rename(output.path);
      }
      return directory.path;
    } on Object {
      throw const HwpOfficeException(
        'fonts_unavailable',
        '문서 글꼴을 준비하지 못했습니다. 앱을 다시 설치해 주세요.',
      );
    }
  }

  static final _sha = RegExp(r'^[0-9a-f]{64}$');
  static final _tableInsertId = RegExp(r'^[A-Za-z0-9_.:-]{1,128}$');
  static final _tableStructureId = RegExp(r'^s[0-9]+:p[0-9]+:t[0-9]+$');
  static void _format(String path) {
    if (!editableFormats.contains(
      p.extension(path).toLowerCase().replaceFirst('.', ''),
    )) {
      throw const HwpOfficeException(
        'unsupported_format',
        'HWP5 또는 HWPX 문서만 열 수 있습니다.',
      );
    }
  }

  static Future<String> _hash(File file) async {
    if (await file.length() > 128 * 1024 * 1024)
      throw const HwpOfficeException('resource_limit', '문서 크기가 지원 범위를 넘습니다.');
    return sha256.convert(await file.readAsBytes()).toString();
  }

  static Future<bool> _isPdf(File file) async {
    final stream = await file.open();
    try {
      return ascii.decode(await stream.read(5), allowInvalid: true) == '%PDF-';
    } finally {
      await stream.close();
    }
  }

  static bool _samePath(String a, String b) =>
      p.equals(p.absolute(a), p.absolute(b)) ||
      Platform.isWindows &&
          p.absolute(a).toLowerCase() == p.absolute(b).toLowerCase();
  static Map<String, dynamic> _object(Object? value) {
    if (value is! Map)
      throw const HwpOfficeException(
        'invalid_response',
        '문서 도구의 응답을 읽지 못했습니다.',
      );
    return Map<String, dynamic>.from(value);
  }

  static Map<String, dynamic> _response(Map<String, dynamic> result) {
    final error = result['error'];
    if (error is Map) {
      final details = Map<String, dynamic>.from(error);
      throw HwpOfficeException(
        details['code'] as String? ?? 'native_error',
        details['message'] as String? ?? '문서 작업을 완료하지 못했습니다.',
        details,
      );
    }
    return result;
  }
}

class _OwnedHwpInspection extends MapView<String, dynamic> {
  new(super.map, this._directory);
  final Directory _directory;
  Future<void>? _disposal;

  Future<void> dispose() => _disposal ??= _dispose();

  Future<void> _dispose() async {
    try {
      if (FileSystemEntity.typeSync(_directory.path, followLinks: false) ==
          FileSystemEntityType.directory) {
        await _directory.delete(recursive: true);
      }
    } on FileSystemException {
      // Retain this invocation's output if an OS reader still owns it.
    }
  }
}

/// A PDF of every page that [HwpStructuredOfficeEngine.renderPdf] made with rhwp.
/// The PDF stays on disk until [dispose] runs.
typedef HwpPdfPreview = ({
  String pdfPath,
  String pdfSha256,
  int pageCount,
  String sourceSha256,
  String engineVersion,
  Future<void> Function() dispose,
});

class HwpStructuredOfficeEngine extends WindowsOfficeEngine {
  new({
    HwpOfficeEngine? engine,
    String? libraryPath,
    String? fontDirectory,
    HwpOfficeRunner? runner,
  }) : _hwp =
           engine ??
           HwpOfficeEngine(
             libraryPath: libraryPath,
             fontDirectory: fontDirectory,
             runner: runner,
           );
  final HwpOfficeEngine _hwp;
  static const editableFormats = HwpOfficeEngine.editableFormats;
  @override
  Future<bool> get available => _hwp.available;
  @override
  Future<WindowsOfficePreview> preview(
    String sourcePath, {
    required List<WindowsOfficeOperation> operations,
    required String sessionId,
    String? expectedSourceSha256,
    Map<String, WindowsOfficeImageAsset> imageAssets = const {},
  }) async {
    throw const WindowsOfficeException(
      'unsupported_operation',
      'HWP에서는 슬라이드 디자인 편집을 지원하지 않습니다.',
    );
  }

  Future<HwpPdfPreview> renderPdf(String sourcePath) async {
    try {
      final result = await _hwp.renderPdf(sourcePath);
      return (
        pdfPath: result['pdfPath'] as String,
        pdfSha256: result['pdfSha256'] as String,
        pageCount: result['pdfPageCount'] as int,
        sourceSha256: result['sourceSha256'] as String,
        engineVersion: result['engineVersion'] as String,
        dispose: result is _OwnedHwpInspection
            ? result.dispose
            : () async {},
      );
    } on HwpOfficeException catch (error) {
      throw WindowsOfficeException(error.code, error.message);
    }
  }

  @override
  Future<WindowsOfficeSnapshot> inspect(
    String sourcePath, {
    bool preview = false,
  }) async {
    Map<String, dynamic>? result;
    var transferred = false;
    try {
      result = await _hwp.inspect(sourcePath, preview: preview);
      final snapshot = WindowsOfficeSnapshot.fromJson(
        Map<String, dynamic>.from(result['snapshot'] as Map),
        onDisposePreview: result is _OwnedHwpInspection ? result.dispose : null,
      );
      transferred = true;
      return snapshot;
    } on HwpOfficeException catch (error) {
      throw WindowsOfficeException(error.code, error.message);
    } finally {
      if (!transferred && result is _OwnedHwpInspection) {
        await result.dispose();
      }
    }
  }

  @override
  Future<WindowsOfficeEditResult> apply(
    String sourcePath, {
    required List<WindowsOfficeOperation> operations,
    required String sessionId,
    String? expectedSourceSha256,
    Map<String, WindowsOfficeImageAsset> imageAssets = const {},
    bool includeDraftSnapshot = false,
  }) async {
    if (includeDraftSnapshot) {
      throw const WindowsOfficeException(
        'unsupported_operation',
        'HWP에서는 슬라이드 디자인 편집을 지원하지 않습니다.',
      );
    }
    if (imageAssets.isNotEmpty) {
      throw const WindowsOfficeException(
        'unsupported_operation',
        'HWP에서는 이미지 원본 편집을 지원하지 않습니다.',
      );
    }
    try {
      return WindowsOfficeEditResult.fromJson(
        await _hwp.apply(
          sourcePath,
          operations: [for (final op in operations) op.toJson()],
          sessionId: sessionId,
          expectedSourceSha256: expectedSourceSha256,
        ),
      );
    } on HwpOfficeException catch (error) {
      throw WindowsOfficeException(error.code, error.message);
    }
  }
}

class _NativeHwp {
  new(DynamicLibrary library)
    : _request = library
          .lookupFunction<
            Pointer<Utf8> Function(Pointer<Utf8>),
            Pointer<Utf8> Function(Pointer<Utf8>)
          >('ink_hwp_request'),
      _free = library
          .lookupFunction<
            Void Function(Pointer<Utf8>),
            void Function(Pointer<Utf8>)
          >('ink_hwp_free'),
      _version = library
          .lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(
            'ink_hwp_version',
          );
  static _NativeHwp open(String? explicit) {
    try {
      final path =
          explicit ??
          (Platform.isWindows
              ? p.join(
                  File(Platform.resolvedExecutable).parent.path,
                  'ink_hwp_native.dll',
                )
              : Platform.isAndroid
              ? 'libink_hwp_native.so'
              : throw const HwpOfficeException(
                  'platform_unsupported',
                  '이 기기에서는 HWP 편집 도구를 사용할 수 없습니다.',
                ));
      return _NativeHwp(DynamicLibrary.open(path));
    } on HwpOfficeException {
      rethrow;
    } on Object {
      throw const HwpOfficeException(
        'library_unavailable',
        'HWP 편집 도구를 불러오지 못했습니다. 앱을 다시 설치해 주세요.',
      );
    }
  }

  final Pointer<Utf8> Function(Pointer<Utf8>) _request;
  final void Function(Pointer<Utf8>) _free;
  final Pointer<Utf8> Function() _version;
  String get version => _version().toDartString();
  Map<String, dynamic> invoke(Map<String, Object?> request) {
    final input = jsonEncode(request).toNativeUtf8(allocator: calloc);
    Pointer<Utf8> output = nullptr;
    try {
      output = _request(input);
      if (output == nullptr)
        throw const HwpOfficeException('invalid_response', 'HWP 도구의 응답이 없습니다.');
      final decoded = jsonDecode(output.toDartString());
      return HwpOfficeEngine._object(decoded);
    } finally {
      if (output != nullptr) _free(output);
      calloc.free(input);
    }
  }
}
