import 'dart:async';
import 'dart:convert';
import 'dart:io';

class McpToolReply {
  const new({
    required this.isError,
    required this.data,
    this.content = const [],
  });

  final bool isError;
  final Map<String, dynamic> data;
  final List<Map<String, dynamic>> content;
}

class WindowsMcpRpc {
  new _(this._process, this._replyTimeout) {
    _stdout = _process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          _receive,
          onError: (Object _) => _fail('MCP stdout could not be read'),
          onDone: () => _fail('MCP stdout closed'),
          cancelOnError: true,
        );
    _stderr = _process.stderr.listen((_) {}, onError: (Object _) {});
    unawaited(
      _process.stdin.done.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) =>
            _fail('MCP stdin could not be written'),
      ),
    );
  }

  static const _defaultReplyTimeout = Duration(seconds: 15);
  static const _closeTimeout = Duration(seconds: 3);
  final Process _process;
  final Duration _replyTimeout;
  final _pending = <int, Completer<Map<String, dynamic>>>{};
  late final StreamSubscription<String> _stdout;
  late final StreamSubscription<List<int>> _stderr;
  var _nextId = 0;
  String? _failure;
  Future<void>? _closing;

  int get pid => _process.pid;

  static Future<WindowsMcpRpc> start(
    String executable,
    String bridgePath, {
    Duration replyTimeout = _defaultReplyTimeout,
  }) async {
    final process = await Process.start(executable, [
      '--bridge-file',
      bridgePath,
    ]);
    final rpc = WindowsMcpRpc._(process, replyTimeout);
    try {
      final result = await rpc._request('initialize', {
        'protocolVersion': '2025-11-25',
        'capabilities': <String, Object?>{},
        'clientInfo': {'name': 'piv-windows-integration', 'version': '1.0'},
      });
      if (result['protocolVersion'] != '2025-11-25') {
        throw StateError('MCP did not negotiate the requested protocol');
      }
      rpc._send({'jsonrpc': '2.0', 'method': 'notifications/initialized'});
      return rpc;
    } on Object {
      await rpc.close();
      rethrow;
    }
  }

  Future<List<String>> tools() async {
    final result = await _request('tools/list', {});
    final tools = result['tools'];
    if (tools is! List) throw StateError('MCP did not return a tool list');
    return [
      for (final tool in tools)
        if (tool is Map && tool['name'] is String)
          tool['name'] as String
        else
          throw StateError('MCP returned a tool without a name'),
    ];
  }

  Future<McpToolReply> call(String name, Map<String, Object?> args) async {
    final result = await _request('tools/call', {
      'name': name,
      'arguments': args,
    });
    final structured = result['structuredContent'];
    final wireContent = result['content'];
    final content = wireContent is List
        ? wireContent.whereType<Map<String, dynamic>>().toList(growable: false)
        : const <Map<String, dynamic>>[];
    if (structured is Map<String, dynamic>) {
      return McpToolReply(
        isError: result['isError'] == true,
        data: structured,
        content: content,
      );
    }
    for (final part in content) {
      if (part['type'] == 'text' && part['text'] is String) {
        final decoded = _decode(part['text'] as String);
        if (decoded != null) {
          return McpToolReply(
            isError: result['isError'] == true,
            data: decoded,
            content: content,
          );
        }
      }
    }
    throw StateError('MCP tool did not return a JSON object');
  }

  static Map<String, dynamic>? _decode(String line) {
    try {
      final decoded = jsonDecode(line);
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  void _receive(String line) {
    final message = _decode(line);
    if (message == null || message['jsonrpc'] != '2.0') {
      _fail('MCP sent an invalid JSON-RPC message');
      return;
    }
    final id = message['id'];
    if (id is int) _pending.remove(id)?.complete(message);
  }

  void _fail(String reason) {
    _failure ??= reason;
    for (final reply in _pending.values) {
      reply.completeError(StateError(_failure!));
    }
    _pending.clear();
  }

  void _send(Map<String, Object?> message) {
    if (_failure != null) throw StateError(_failure!);
    _process.stdin.writeln(jsonEncode(message));
  }

  Future<Map<String, dynamic>> _request(
    String method,
    Map<String, Object?> params,
  ) async {
    final id = ++_nextId;
    final reply = Completer<Map<String, dynamic>>();
    _pending[id] = reply;
    try {
      _send({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params});
      final response = await reply.future.timeout(_replyTimeout);
      if (response['error'] case {'code': final int code}) {
        throw StateError('MCP rejected $method (JSON-RPC code $code)');
      }
      final result = response['result'];
      if (result is! Map<String, dynamic>) {
        throw StateError('MCP did not return a result for $method');
      }
      return result;
    } finally {
      _pending.remove(id);
    }
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _fail('MCP client closed');
    try {
      try {
        await _process.stdin.close().timeout(_closeTimeout);
        await _process.exitCode.timeout(_closeTimeout);
      } on TimeoutException {
        _process.kill();
        await _process.exitCode.timeout(_closeTimeout);
      } on IOException {
        _process.kill();
        await _process.exitCode.timeout(_closeTimeout);
      }
    } finally {
      await Future.wait([_stdout.cancel(), _stderr.cancel()])
          .timeout(_closeTimeout);
    }
  }
}
