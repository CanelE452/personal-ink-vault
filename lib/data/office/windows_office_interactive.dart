import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:ink_vault_core/ink_vault_core.dart'
    show newId, validateHash, validateId;
import 'package:path/path.dart' as p;
import 'package:saber/data/office/office_original_edit_result.dart';
import 'package:saber/data/office/windows_office_engine.dart'
    show WindowsOfficeException;

typedef WindowsOfficeInteractiveRunner = Future<Map<String, dynamic>> Function(
  Map<String, Object?> request,
  Directory launchDirectory,
  Future<void> cancellation,
);

const _engineVersion = 'LibreOffice26.8.2.2';
const _maxPayload = 128 * 1024 * 1024;
const _maxReceipt = 64 * 1024;
const _commonFields = {
  'version',
  'sessionId',
  'controlNonce',
  'inputSourceSha256',
  'status',
  'engineVersion',
};

Never _invalid() => throw const WindowsOfficeException(
  'invalid_office_result',
  'Office 편집 결과의 파일과 세션을 확인하지 못했습니다. 작업 파일은 보관됩니다.',
);

bool _fields(Map value, Set<String> expected) =>
    value.length == expected.length && value.keys.every(expected.contains);

Future<List<int>> _diagnosticBytes(Stream<List<int>> source) async {
  final bytes = <int>[];
  try {
    await for (final chunk in source) {
      final remaining = _maxReceipt - bytes.length;
      if (remaining > 0) bytes.addAll(chunk.take(remaining));
    }
  } on Object {
    // A diagnostic stream cannot change the native operation's result.
  }
  return bytes;
}

Future<void> _requireDirectory(Directory directory) async {
  if (FileSystemEntity.typeSync(directory.path, followLinks: false) !=
          FileSystemEntityType.directory ||
      !p.equals(await directory.resolveSymbolicLinks(), directory.path)) {
    _invalid();
  }
}

Future<({String sha256, int length})> _inspect(
  File file, {
  int limit = _maxPayload,
}) async {
  if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
          FileSystemEntityType.file ||
      !p.equals(await file.resolveSymbolicLinks(), file.path)) {
    _invalid();
  }
  final before = file.statSync();
  if (before.size < 1 || before.size > limit) _invalid();
  final digest = (await sha256.bind(file.openRead()).first).toString();
  final after = file.statSync();
  if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
          FileSystemEntityType.file ||
      before.size != after.size ||
      before.modified != after.modified ||
      !p.equals(await file.resolveSymbolicLinks(), file.path)) {
    _invalid();
  }
  return (sha256: digest, length: after.size);
}

class WindowsOfficeInteractiveEngine {
  new({required this.runtimePath, required this.helperDirectory, this.runner});

  final String runtimePath, helperDirectory;
  final WindowsOfficeInteractiveRunner? runner;

  Future<bool> get available async =>
      runner != null ||
      Platform.isWindows &&
          File(p.join(runtimePath, 'program', 'python.exe')).existsSync() &&
          File(p.join(helperDirectory, 'run-office-interactive.ps1'))
              .existsSync();

  Future<WindowsOfficeInteractiveSession> start({
    required String workingPath,
    required String sessionId,
    required String inputSourceSha256,
  }) async {
    validateId(sessionId);
    validateHash(inputSourceSha256);
    if (!p.isAbsolute(workingPath) ||
        FileSystemEntity.typeSync(workingPath, followLinks: false) !=
            FileSystemEntityType.file ||
        FileSystemEntity.typeSync(p.dirname(workingPath), followLinks: false) !=
            FileSystemEntityType.directory) {
      throw const FormatException('Expected a private Office working file');
    }
    final working = File(await File(workingPath).resolveSymbolicLinks());
    final parent = working.parent;
    await _requireDirectory(parent);
    if (p.basename(parent.path) != sessionId ||
        !RegExp(
          r'^original\.(doc|docx|odt|ppt|pptx|odp)$',
          caseSensitive: false,
        ).hasMatch(p.basename(working.path))) {
      throw const FormatException(
        'The Office working copy differs from its session',
      );
    }
    if (!await available) {
      throw const WindowsOfficeException(
        'office_interactive_unavailable',
        '이 기기에서 Office 편집창을 열 수 없습니다. 앱 설치 파일을 확인해 주세요.',
      );
    }
    final captured = await _inspect(working);
    final nonce = newId();
    final launch = Directory(p.join(parent.path, 'interactive-$nonce'));
    if (FileSystemEntity.typeSync(launch.path, followLinks: false) !=
        FileSystemEntityType.notFound)
      _invalid();
    await launch.create();
    await _requireDirectory(launch);
    final request = Map<String, Object?>.unmodifiable({
      'version': 1,
      'sessionId': sessionId,
      'controlNonce': nonce,
      'workingFileName': p.basename(working.path),
      'inputSourceSha256': inputSourceSha256,
      'expectedWorkingSha256': captured.sha256,
      'workingLength': captured.length,
      'parentProcessId': pid,
      'parentExecutablePath': Platform.resolvedExecutable,
    });
    final bytes = utf8.encode(jsonEncode(request));
    final pending = File(p.join(launch.path, 'request.pending'));
    await pending.create(exclusive: true);
    await pending.writeAsBytes(bytes, flush: true);
    final marker = File(p.join(launch.path, 'request.json'));
    if (FileSystemEntity.typeSync(marker.path, followLinks: false) !=
        FileSystemEntityType.notFound)
      _invalid();
    await pending.rename(marker.path);
    await _requireDirectory(parent);
    await _requireDirectory(launch);
    return WindowsOfficeInteractiveSession._(
      working: working,
      directory: launch,
      request: request,
      requestHash: sha256.convert(bytes).toString(),
      runtimePath: runtimePath,
      helperDirectory: helperDirectory,
      runner: runner,
    );
  }
}

class WindowsOfficeInteractiveSession {
  new _({
    required this._working,
    required this._directory,
    required this._request,
    required this._requestHash,
    required this._runtimePath,
    required this._helperDirectory,
    required this._runner,
  }) {
    _result = _perform();
    _result.ignore();
  }

  final File _working;
  final Directory _directory;
  final Map<String, Object?> _request;
  final String _requestHash, _runtimePath, _helperDirectory;
  final WindowsOfficeInteractiveRunner? _runner;
  final _cancellation = Completer<void>();
  late final Future<OfficeOriginalEditResult> _result;
  Future<void>? _cancelOperation, _releaseOperation, _disposal;
  Directory? _runtimeTemp;
  var _cancellationRequested = false;
  var _finished = false;
  var _saved = false;
  var _released = false;

  Future<OfficeOriginalEditResult> get result => _result;
  bool get cancellationRequested => _cancellationRequested;

  Future<void> cancel() {
    _cancellationRequested = true;
    if (!_cancellation.isCompleted) _cancellation.complete();
    if (_finished || _released) return Future.value();
    return _cancelOperation ??= _writeCancellation();
  }

  Future<void> dispose() => _disposal ??= _dispose();

  Future<void> _dispose() async {
    try {
      await cancel();
    } on Object {
      // A stale session keeps its working files and cannot authorize new work.
    }
  }

  Future<void> releaseOutputs() {
    if (!_finished || !_saved || _released) return Future.value();
    return _releaseOperation ??= _release();
  }

  Future<void> _owner() async {
    await _requireDirectory(_working.parent);
    await _requireDirectory(_directory);
    if (p.basename(_working.parent.path) != _request['sessionId'] ||
        p.basename(_directory.path) !=
            'interactive-${_request['controlNonce']}' ||
        !p.equals(_directory.parent.path, _working.parent.path))
      _invalid();
    final marker = await _inspect(
      File(p.join(_directory.path, 'request.json')),
      limit: _maxReceipt,
    );
    if (marker.sha256 != _requestHash) _invalid();
  }

  Future<void> _writeCancellation() async {
    await _owner();
    final bytes = utf8.encode(
      jsonEncode({
        'version': 1,
        'sessionId': _request['sessionId'],
        'controlNonce': _request['controlNonce'],
      }),
    );
    final target = File(p.join(_directory.path, 'cancel.json'));
    if (FileSystemEntity.typeSync(target.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      final current = await _inspect(target, limit: _maxReceipt);
      if (current.sha256 != sha256.convert(bytes).toString()) _invalid();
      return;
    }
    final pending = File(p.join(_directory.path, 'cancel.pending'));
    await pending.create(exclusive: true);
    await pending.writeAsBytes(bytes, flush: true);
    await _owner();
    if (FileSystemEntity.typeSync(target.path, followLinks: false) !=
        FileSystemEntityType.notFound)
      _invalid();
    await pending.rename(target.path);
    await _owner();
  }

  Future<Map<String, dynamic>> _invoke() async {
    if (_runner != null)
      return _runner(_request, _directory, _cancellation.future);
    final created = await Directory.systemTemp.createTemp('piv-i-');
    final runtimeTemp = Directory(await created.resolveSymbolicLinks());
    _runtimeTemp = runtimeTemp;
    await _requireDirectory(runtimeTemp);
    await _owner();
    final tempMarker = File(p.join(_directory.path, 'runtime-temp.json'));
    await tempMarker.create(exclusive: true);
    await tempMarker.writeAsBytes(
      utf8.encode(
        jsonEncode({
          'version': 1,
          'sessionId': _request['sessionId'],
          'controlNonce': _request['controlNonce'],
          'path': runtimeTemp.path,
        }),
      ),
      flush: true,
    );
    await _owner();
    final process = await Process.start(
      'powershell.exe',
      [
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-WindowStyle',
        'Hidden',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        p.join(_helperDirectory, 'run-office-interactive.ps1'),
        '-RuntimePath',
        _runtimePath,
        '-RequestPath',
        p.join(_directory.path, 'request.json'),
      ],
      runInShell: false,
      environment: {'TEMP': runtimeTemp.path, 'TMP': runtimeTemp.path},
    );
    process.stdout.drain<void>().ignore();
    final stderr = _diagnosticBytes(process.stderr);
    final exitCode = await process.exitCode;
    final diagnostics = await stderr;
    await _owner();
    if (exitCode != 0 && diagnostics.isNotEmpty) {
      try {
        final file = File(p.join(_directory.path, 'interactive-stderr.txt'));
        await file.create(exclusive: true);
        await file.writeAsBytes(diagnostics, flush: true);
      } on Object {
        // Preserve the original failure and any existing private diagnostic.
      }
      await _owner();
    }
    final response = File(p.join(_directory.path, 'response.json'));
    if (!response.existsSync()) {
      throw const WindowsOfficeException(
        'office_interactive_failed',
        'Office 편집창을 정상적으로 마치지 못했습니다. 작업 파일은 보관됩니다.',
      );
    }
    final before = await _inspect(response, limit: _maxReceipt);
    final bytes = await response.readAsBytes();
    final after = await _inspect(response, limit: _maxReceipt);
    if (before != after || sha256.convert(bytes).toString() != before.sha256)
      _invalid();
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map<String, dynamic>) _invalid();
    if (exitCode != 0 && decoded['status'] != 'error') {
      throw const WindowsOfficeException(
        'office_interactive_failed',
        'Office 편집창을 정상적으로 마치지 못했습니다. 작업 파일은 보관됩니다.',
      );
    }
    return decoded;
  }

  Future<OfficeOriginalEditResult> _perform() async {
    try {
      await _owner();
      final response = await _invoke();
      await _owner();
      final result = await _decode(response);
      await _owner();
      await _removeEmptyRuntimeTemp();
      _saved = result.status == OfficeOriginalEditStatus.saved;
      return result;
    } on WindowsOfficeException {
      rethrow;
    } on Object {
      throw const WindowsOfficeException(
        'office_interactive_failed',
        'Office 편집을 완료하지 못했습니다. 작업 파일은 보관됩니다.',
      );
    } finally {
      _finished = true;
    }
  }

  Future<void> _removeEmptyRuntimeTemp() async {
    final runtimeTemp = _runtimeTemp;
    if (runtimeTemp == null) return;
    try {
      await _requireDirectory(runtimeTemp);
      await runtimeTemp.delete();
      _runtimeTemp = null;
    } on Object {
      // Nonempty recovery files and their diagnostic launch remain available.
    }
  }

  Future<OfficeOriginalEditResult> _decode(
    Map<String, dynamic> response,
  ) async {
    if (response['version'] is! int ||
        response['version'] != 1 ||
        response['sessionId'] != _request['sessionId'] ||
        response['controlNonce'] != _request['controlNonce'] ||
        response['inputSourceSha256'] != _request['inputSourceSha256'] ||
        response['engineVersion'] != _engineVersion)
      _invalid();
    final status = response['status'];
    if (status == 'cancelled') {
      if (!_fields(response, _commonFields)) _invalid();
      return OfficeOriginalEditResult(
        status: OfficeOriginalEditStatus.cancelled,
        engineVersion: _engineVersion,
        sessionId: _request['sessionId']! as String,
        inputSourceSha256: _request['inputSourceSha256']! as String,
      );
    }
    if (status == 'error') {
      if (!_fields(response, {..._commonFields, 'error'})) _invalid();
      final error = response['error'];
      if (error is! Map ||
          !_fields(error, {'code', 'message'}) ||
          error['code'] is! String ||
          !RegExp(r'^[a-z][a-z0-9_]{0,63}$')
              .hasMatch(error['code'] as String) ||
          error['message'] is! String ||
          (error['message'] as String).length > 1024)
        _invalid();
      throw WindowsOfficeException(
        error['code'] as String,
        'Office 편집을 완료하지 못했습니다. 작업 파일은 보관되며 이어서 편집할 수 있습니다.',
      );
    }
    if (status != 'saved' ||
        !_fields(response, {
          ..._commonFields,
          'sourcePath',
          'pdfPath',
          'sourceSha256',
          'pdfSha256',
          'pdfPageCount',
        }))
      _invalid();
    final extension = p.extension(_working.path).toLowerCase();
    final source = File(p.join(_directory.path, 'edited$extension'));
    final pdf = File(p.join(_directory.path, 'preview.pdf'));
    if (response['sourcePath'] is! String ||
        response['pdfPath'] is! String ||
        !p.isAbsolute(response['sourcePath'] as String) ||
        !p.isAbsolute(response['pdfPath'] as String) ||
        !p.equals(response['sourcePath'] as String, source.path) ||
        !p.equals(response['pdfPath'] as String, pdf.path) ||
        p.equals(source.path, _working.path) ||
        p.equals(pdf.path, source.path) ||
        response['sourceSha256'] is! String ||
        response['pdfSha256'] is! String ||
        !RegExp(r'^[a-f0-9]{64}$')
            .hasMatch(response['sourceSha256'] as String) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(response['pdfSha256'] as String) ||
        response['pdfPageCount'] is! int ||
        (response['pdfPageCount'] as int) < 1 ||
        (response['pdfPageCount'] as int) > 1000000)
      _invalid();
    final sourceInfo = await _inspect(source);
    await _owner();
    final pdfInfo = await _inspect(pdf);
    await _owner();
    if (sourceInfo.sha256 != response['sourceSha256'] ||
        pdfInfo.sha256 != response['pdfSha256'])
      _invalid();
    final input = await pdf.open();
    try {
      final header = await input.read(8);
      await input.setPosition(
        pdfInfo.length > 1024 ? pdfInfo.length - 1024 : 0,
      );
      final tail = await input.read(1024);
      if (!RegExp(r'^%PDF-[12]\.').hasMatch(String.fromCharCodes(header)) ||
          !RegExp(r'%%EOF[\x00\t\n\f\r ]*$')
              .hasMatch(String.fromCharCodes(tail)))
        _invalid();
    } finally {
      await input.close();
    }
    await _owner();
    if (await _inspect(source) != sourceInfo || await _inspect(pdf) != pdfInfo)
      _invalid();
    return OfficeOriginalEditResult(
      status: OfficeOriginalEditStatus.saved,
      engineVersion: _engineVersion,
      sessionId: _request['sessionId']! as String,
      inputSourceSha256: _request['inputSourceSha256']! as String,
      sourcePath: source.path,
      pdfPath: pdf.path,
      sourceSha256: sourceInfo.sha256,
      pdfSha256: pdfInfo.sha256,
      pdfPageCount: response['pdfPageCount'] as int,
    );
  }

  Future<void> _release() async {
    try {
      await _cancelOperation;
      if (_runtimeTemp != null) return;
      await _owner();
      // Windows directory enumeration needs an extended path for long paths.
      var listingDirectory = _directory;
      if (Platform.isWindows) {
        final path = _directory.path;
        if (RegExp(r'^[a-zA-Z]:\\').hasMatch(path)) {
          listingDirectory = Directory('\\\\?\\$path');
        } else if (path.startsWith(r'\\') &&
            !path.startsWith(r'\\?\') &&
            !path.startsWith(r'\\.\')) {
          listingDirectory = Directory('\\\\?\\UNC\\${path.substring(2)}');
        }
      }
      await for (final entry in listingDirectory.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entry is Link) return;
      }
      await _owner();
      await _directory.delete(recursive: true);
      _released = true;
    } on Object {
      // Cleanup cannot replace a saved edition or remove files with a changed owner.
    }
  }
}
