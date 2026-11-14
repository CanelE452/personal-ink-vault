import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/mcp/vault_mcp_bridge.dart';

void main() {
  late Directory temp;
  late File config;
  VaultMcpBridge? bridge;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('mcp-bridge-');
    config = File('${temp.path}/bridge.json');
  });
  tearDown(() async {
    await bridge?.stop();
    bridge = null;
    await temp.delete(recursive: true);
  });

  Future<(int, Map<String, dynamic>)> request({
    String operation = 'vault_status',
    String? token,
    String? origin,
    String? host,
    String? raw,
    int? length,
  }) async {
    final data =
        jsonDecode(await config.readAsString()) as Map<String, dynamic>;
    final client = HttpClient();
    try {
      final request = await client.postUrl(
        Uri.parse('${data['endpoint']}/v1/call'),
      );
      request.headers.contentType = ContentType.json;
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer ${token ?? data['token']}',
      );
      if (origin != null) request.headers.set('Origin', origin);
      if (host != null) request.headers.set(HttpHeaders.hostHeader, host);
      if (length != null) request.contentLength = length;
      request.write(
        raw ?? jsonEncode({'operation': operation, 'arguments': {}}),
      );
      final response = await request.close();
      final body = await utf8.decoder.bind(response).join();
      return (response.statusCode, jsonDecode(body) as Map<String, dynamic>);
    } finally {
      client.close(force: true);
    }
  }

  test(
    'database action is a write at the HTTP boundary before handler dispatch',
    () async {
      var calls = 0;
      bridge = await VaultMcpBridge.start(
        configFile: config,
        handler: (_, _, _) async {
          calls++;
          return {'changed': true};
        },
      );
      final (deniedStatus, denied) = await request(
        operation: 'database_action',
      );
      expect(deniedStatus, 403);
      expect(denied['error']['code'], 'read_only');
      expect(calls, 0);
      await bridge!.setWriteEnabled(true);
      final (allowedStatus, allowed) = await request(
        operation: 'database_action',
      );
      expect(allowedStatus, 200);
      expect(allowed['result']['changed'], true);
      expect(calls, 1);
      await bridge!.setWriteEnabled(false);
      expect((await request(operation: 'database_action')).$1, 403);
      expect(calls, 1);
    },
  );

  test(
    'write revocation survives a configuration persistence failure',
    () async {
      VaultMcpCallContext? captured;
      bridge = await VaultMcpBridge.start(
        configFile: config,
        writeEnabled: true,
        handler: (_, _, current) async {
          captured = current;
          return {};
        },
      );
      await request();
      captured!.requireActive(write: true);
      await config.delete();
      await Directory(config.path).create();
      await expectLater(
        bridge!.setWriteEnabled(false),
        throwsA(isA<FileSystemException>()),
      );
      expect(bridge!.writeEnabled, isFalse);
      expect(
        () => captured!.requireActive(write: true),
        throwsA(
          isA<VaultMcpException>().having((e) => e.code, 'code', 'read_only'),
        ),
      );
    },
  );

  test(
    'image responses have a separate eight MiB allowance from two MiB requests',
    () async {
      final data = 'a' * (3 * 1024 * 1024);
      bridge = await VaultMcpBridge.start(
        configFile: config,
        handler: (_, _, _) async => {
          'image': {'mimeType': 'image/png', 'data': data},
        },
      );
      final (status, body) = await request();
      expect(status, 200);
      expect((body['result']['image']['data'] as String).length, data.length);
    },
  );

  test('body deadline closes slow chunked senders even when bytes keep arriving', () async {
    bridge = await VaultMcpBridge.start(
      configFile: config,
      bodyTimeout: const Duration(milliseconds: 180),
      handler: (_, _, _) async => {},
    );
    final settings = jsonDecode(await config.readAsString()) as Map;
    final uri = Uri.parse(settings['endpoint'] as String);
    final socket = await Socket.connect(uri.host, uri.port);
    final received = utf8.decoder
        .bind(socket)
        .join()
        .timeout(const Duration(seconds: 3));
    socket.write(
      'POST /v1/call HTTP/1.1\r\nHost: 127.0.0.1:${uri.port}\r\nAuthorization: Bearer ${settings['token']}\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n1\r\n{\r\n',
    );
    await socket.flush();
    final timer = Timer.periodic(const Duration(milliseconds: 45), (_) {
      try {
        socket.write('1\r\n \r\n');
      } catch (_) {}
    });
    try {
      final response = await received;
      expect(response, contains('408'));
      expect(response, contains('request_timeout'));
    } finally {
      timer.cancel();
      socket.destroy();
    }
  });

  test(
    'an unencodable handler result still produces a closed JSON error response',
    () async {
      bridge = await VaultMcpBridge.start(
        configFile: config,
        handler: (_, _, _) async => Object(),
      );
      final (status, body) = await request().timeout(
        const Duration(seconds: 3),
      );
      expect(status, 500);
      expect(body['error']['code'], 'invalid_result');
    },
  );

  test(
    'real loopback HTTP authenticates and returns only handler data',
    () async {
      bridge = await VaultMcpBridge.start(
        configFile: config,
        handler: (op, args, context) async => {'operation': op, 'count': 3},
      );
      final data = jsonDecode(await config.readAsString()) as Map;
      expect(data['version'], 1);
      expect(Uri.parse(data['endpoint'] as String).host, '127.0.0.1');
      expect((data['token'] as String).length, greaterThanOrEqualTo(43));
      final (status, body) = await request();
      expect(status, 200);
      expect(body, {
        'ok': true,
        'result': {'operation': 'vault_status', 'count': 3},
      });
    },
  );

  test('wrong bearer browser Origin and forged Host are rejected before the handler', () async {
    var calls = 0;
    bridge = await VaultMcpBridge.start(
      configFile: config,
      handler: (_, _, _) async {
        calls++;
        return {};
      },
    );
    expect((await request(token: 'bad')).$1, 401);
    expect((await request(origin: 'https://example.com')).$1, 403);
    expect((await request(host: 'evil.example')).$1, 403);
    expect(calls, 0);
  });

  test(
    'read-only mode revokes queued writes and can be explicitly enabled',
    () async {
      VaultMcpCallContext? captured;
      bridge = await VaultMcpBridge.start(
        configFile: config,
        handler: (_, _, context) async {
          captured = context;
          return {};
        },
      );
      expect((await request(operation: 'create_document')).$1, 403);
      await bridge!.setWriteEnabled(true);
      expect((await request(operation: 'create_document')).$1, 200);
      captured!.requireActive(write: true);
      await bridge!.setWriteEnabled(false);
      expect(
        () => captured!.requireActive(write: true),
        throwsA(
          isA<VaultMcpException>().having((e) => e.code, 'code', 'read_only'),
        ),
      );
    },
  );

  test('oversized chunked bodies malformed payloads and unknown envelopes are bounded', () async {
    var calls = 0;
    bridge = await VaultMcpBridge.start(
      configFile: config,
      handler: (_, _, _) async {
        calls++;
        return {};
      },
    );
    expect((await request(raw: '{')).$1, 400);
    expect(
      (await request(
        raw: jsonEncode({
          'operation': 'vault_status',
          'arguments': [],
          'extra': true,
        }),
      )).$1,
      400,
    );
    expect(
      (await request(
        raw: jsonEncode({
          'operation': 'vault_status',
          'arguments': {'big': 'x' * (2 * 1024 * 1024)},
        }),
      )).$1,
      413,
    );
    expect(calls, 0);
  });

  test(
    'in-flight limit rejects excess work without canceling the accepted call',
    () async {
      final entered = Completer<void>(), release = Completer<void>();
      bridge = await VaultMcpBridge.start(
        configFile: config,
        maxConcurrentRequests: 1,
        handler: (_, _, _) async {
          entered.complete();
          await release.future;
          return {'done': true};
        },
      );
      final pending = request();
      await entered.future;
      expect((await request()).$1, 429);
      release.complete();
      expect((await pending).$1, 200);
    },
  );

  test('stop revokes contexts and removes only its own config, restart rotates tokens', () async {
    VaultMcpCallContext? context;
    bridge = await VaultMcpBridge.start(
      configFile: config,
      handler: (_, _, current) async {
        context = current;
        return {};
      },
    );
    await request();
    final first = jsonDecode(await config.readAsString()) as Map;
    await bridge!.stop();
    expect(config.existsSync(), isFalse);
    expect(() => context!.requireActive(), throwsA(isA<VaultMcpException>()));
    bridge = await VaultMcpBridge.start(
      configFile: config,
      handler: (_, _, _) async => {},
    );
    final next = jsonDecode(await config.readAsString()) as Map;
    expect(next['token'], isNot(first['token']));
    expect(next['instanceId'], isNot(first['instanceId']));
    await config.writeAsString(
      jsonEncode({...next, 'instanceId': 'another-owner'}),
    );
    await bridge!.stop();
    expect(config.existsSync(), isTrue);
  });
}
