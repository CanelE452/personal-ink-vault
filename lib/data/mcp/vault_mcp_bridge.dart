import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:ink_vault_core/ink_vault_core.dart' show newId;

typedef VaultMcpHandler = Future<Object?> Function(
  String operation,
  Map<String, dynamic> arguments,
  VaultMcpCallContext context,
);

class VaultMcpException implements Exception {
  const new(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => 'VaultMcpException($code): $message';
}

class VaultMcpCallContext {
  const new({required this._isActive, required this._canWrite});
  final bool Function() _isActive;
  final bool Function() _canWrite;
  bool get writeEnabled => _canWrite();
  void requireActive({bool write = false}) {
    if (!_isActive())
      throw const VaultMcpException('authorization_revoked', '앱 연결이 해제되었습니다.');
    if (write && !_canWrite())
      throw const VaultMcpException('read_only', '현재 연결은 읽기 전용입니다.');
  }
}

class VaultMcpBridge {
  new _(
    this._server,
    this._configFile,
    this._handler,
    this._writeEnabled,
    this._maxConcurrentRequests,
    this._bodyTimeout,
  ) : instanceId = newId(),
      _token = _randomToken();
  static Future<VaultMcpBridge> start({
    required File configFile,
    required VaultMcpHandler handler,
    bool writeEnabled = false,
    int maxConcurrentRequests = 4,
    Duration bodyTimeout = const Duration(seconds: 10),
  }) async {
    if (maxConcurrentRequests < 1 ||
        maxConcurrentRequests > 16 ||
        bodyTimeout <= Duration.zero) {
      throw ArgumentError('Invalid bridge limits');
    }
    final server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
      shared: false,
    );
    final bridge = VaultMcpBridge._(
      server,
      configFile,
      handler,
      writeEnabled,
      maxConcurrentRequests,
      bodyTimeout,
    );
    try {
      await bridge._persistConfig();
      server.listen((request) {
        unawaited(bridge._handle(request));
      }, onError: (Object _) {});
      return bridge;
    } catch (_) {
      await bridge.stop();
      rethrow;
    }
  }

  static const maxBodyBytes = 2 * 1024 * 1024;
  static const maxResponseBytes = 8 * 1024 * 1024;
  static const _writeOperations = {
    'create_document',
    'ensure_daily_note',
    'update_document',
    'document_action',
    'office_edit',
    'office_asset',
    'database_action',
  };
  final HttpServer _server;
  final File _configFile;
  final VaultMcpHandler _handler;
  final int _maxConcurrentRequests;
  final Duration _bodyTimeout;
  final String instanceId;
  String _token;
  bool _writeEnabled;
  var _permissionVersion = 0;
  var _running = true;
  var _activeRequests = 0;
  Future<void> _configurationTail = Future.value();
  String get endpoint => 'http://127.0.0.1:${_server.port}';
  bool get writeEnabled => _writeEnabled;
  bool get isRunning => _running;

  Future<void> _persistConfig() {
    final next = _configurationTail.then((_) async {
      if (!_running) return;
      final config = {
        'version': 1,
        'instanceId': instanceId,
        'endpoint': endpoint,
        'token': _token,
        'writeEnabled': _writeEnabled,
      };
      await _configFile.parent.create(recursive: true);
      final pending = File('${_configFile.path}.${newId()}.pending');
      try {
        await pending.create();
        _privatePermissions(pending.path);
        await pending.writeAsString(jsonEncode(config), flush: true);
        await pending.rename(_configFile.path);
      } finally {
        if (pending.existsSync()) await pending.delete();
      }
    });
    _configurationTail = next.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return next;
  }

  Future<void> setWriteEnabled(bool enabled) async {
    if (!_running)
      throw const VaultMcpException('authorization_revoked', '앱 연결이 해제되었습니다.');
    final previous = _writeEnabled;
    final version = ++_permissionVersion;
    _writeEnabled = enabled;
    try {
      await _persistConfig();
    } catch (_) {
      if (_permissionVersion == version) {
        _writeEnabled = _running && enabled ? previous : false;
      }
      rethrow;
    }
  }

  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    _permissionVersion++;
    _token = '';
    _writeEnabled = false;
    await _server.close(force: true);
    await _configurationTail;
    if (_configFile.existsSync()) {
      try {
        final json = jsonDecode(await _configFile.readAsString());
        if (json is Map && json['instanceId'] == instanceId)
          await _configFile.delete();
      } on FormatException {
        /* A foreign or corrupt config is left untouched. */
      }
    }
  }

  Future<void> _handle(HttpRequest request) async {
    var counted = false;
    try {
      if (!_running) {
        await _error(request, 403, 'authorization_revoked', '앱 연결이 해제되었습니다.');
        return;
      }
      if (request.headers.value('origin') != null ||
          request.headers.value(HttpHeaders.hostHeader) !=
              '127.0.0.1:${_server.port}') {
        await _error(
          request,
          403,
          'request_origin_rejected',
          '허용되지 않은 로컬 연결입니다.',
        );
        return;
      }
      if (!_sameToken(
        request.headers.value(HttpHeaders.authorizationHeader) ?? '',
        'Bearer $_token',
      )) {
        await _error(request, 401, 'unauthorized', '앱 연결 인증이 필요합니다.');
        return;
      }
      if (request.method != 'POST' ||
          request.uri.path != '/v1/call' ||
          request.uri.hasQuery) {
        await _error(request, 404, 'not_found', '지원하지 않는 요청 경로입니다.');
        return;
      }
      if (request.headers.contentType?.mimeType != 'application/json') {
        await _error(request, 415, 'invalid_content_type', 'JSON 요청만 지원합니다.');
        return;
      }
      if (_activeRequests >= _maxConcurrentRequests) {
        await _error(request, 429, 'busy', '처리 중인 요청이 많습니다. 잠시 후 다시 시도하세요.');
        return;
      }
      _activeRequests++;
      counted = true;
      if (request.contentLength > maxBodyBytes) {
        await _error(request, 413, 'request_too_large', '요청 크기가 지원 범위를 넘습니다.');
        return;
      }
      final bytes = BytesBuilder(copy: false);
      final chunks = StreamIterator(request);
      final deadline = Stopwatch()..start();
      try {
        while (true) {
          final remaining = _bodyTimeout - deadline.elapsed;
          if (remaining <= Duration.zero)
            throw TimeoutException('Body deadline');
          if (!await chunks.moveNext().timeout(remaining)) break;
          final chunk = chunks.current;
          if (bytes.length + chunk.length > maxBodyBytes) {
            await _error(
              request,
              413,
              'request_too_large',
              '요청 크기가 지원 범위를 넘습니다.',
            );
            return;
          }
          bytes.add(chunk);
        }
      } on TimeoutException {
        await _error(request, 408, 'request_timeout', '요청을 받는 시간이 초과되었습니다.');
        return;
      } finally {
        await chunks.cancel();
      }
      final raw = jsonDecode(utf8.decode(bytes.takeBytes()));
      if (raw is! Map ||
          raw.length != 2 ||
          raw['operation'] is! String ||
          raw['arguments'] is! Map ||
          (raw['operation'] as String).length > 80 ||
          (raw['operation'] as String).isEmpty) {
        throw const FormatException('Invalid call envelope');
      }
      final operation = raw['operation'] as String;
      final context = VaultMcpCallContext(
        isActive: () => _running,
        canWrite: () => _running && _writeEnabled,
      );
      context.requireActive(write: _writeOperations.contains(operation));
      final result = await _handler(
        operation,
        Map<String, dynamic>.from(raw['arguments'] as Map),
        context,
      );
      context.requireActive();
      await _respond(request, 200, {'ok': true, 'result': result});
    } on VaultMcpException catch (error) {
      final status = switch (error.code) {
        'authorization_revoked' || 'read_only' => 403,
        'revision_conflict' ||
        'request_id_reused' ||
        'operation_state_unknown' => 409,
        'result_too_large' => 413,
        'busy' => 429,
        'unknown_operation' ||
        'invalid_arguments' ||
        'revision_not_owned' ||
        'not_found' => 400,
        _ => 422,
      };
      await _error(request, status, error.code, error.message);
    } on TimeoutException {
      await _error(request, 408, 'request_timeout', '요청을 받는 시간이 초과되었습니다.');
    } on FormatException {
      await _error(request, 400, 'invalid_arguments', '요청 형식을 확인하세요.');
    } catch (_) {
      await _error(request, 500, 'internal_error', '요청을 완료하지 못했습니다.');
    } finally {
      if (counted) _activeRequests--;
    }
  }

  Future<void> _error(
    HttpRequest request,
    int status,
    String code,
    String message,
  ) => _respond(request, status, {
    'ok': false,
    'error': {'code': code, 'message': message},
  });

  Future<void> _respond(
    HttpRequest request,
    int status,
    Map<String, Object?> json,
  ) async {
    try {
      late List<int> bytes;
      try {
        bytes = utf8.encode(jsonEncode(json));
      } catch (_) {
        status = 500;
        bytes = utf8.encode(
          '{"ok":false,"error":{"code":"invalid_result","message":"요청 결과를 표시하지 못했습니다."}}',
        );
      }
      if (bytes.length > maxResponseBytes) {
        status = 413;
        bytes = utf8.encode(
          jsonEncode({
            'ok': false,
            'error': {
              'code': 'result_too_large',
              'message': '결과가 너무 큽니다. 범위를 좁혀 다시 요청하세요.',
            },
          }),
        );
      }
      final response = request.response;
      response.statusCode = status;
      response.headers.contentType = ContentType.json;
      response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      response.headers.set('X-Content-Type-Options', 'nosniff');
      response.persistentConnection = false;
      response.contentLength = bytes.length;
      response.add(bytes);
      await response.close();
    } catch (_) {
      /* Disconnected clients do not log request data. */
    }
  }
}

String _randomToken() {
  final random = Random.secure();
  return [
    for (var i = 0; i < 32; i++)
      random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ].join();
}

bool _sameToken(String a, String b) {
  var difference = a.length ^ b.length;
  for (var i = 0; i < b.length; i++) {
    difference |= b.codeUnitAt(i) ^ (i < a.length ? a.codeUnitAt(i) : 0);
  }
  return difference == 0;
}

void _privatePermissions(String path) {
  if (Platform.isWindows) return;
  final chmod = DynamicLibrary.process()
      .lookupFunction<
        Int32 Function(Pointer<Utf8>, Uint32),
        int Function(Pointer<Utf8>, int)
      >('chmod');
  final name = path.toNativeUtf8();
  try {
    if (chmod(name, 0x180) != 0)
      throw const FileSystemException(
        'Private MCP configuration permissions could not be applied',
      );
  } finally {
    malloc.free(name);
  }
}
