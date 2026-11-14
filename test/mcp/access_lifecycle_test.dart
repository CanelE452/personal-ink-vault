import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/mcp/vault_mcp_service.dart';
import 'package:saber/pages/workspace/mcp_panel.dart';
import 'package:saber/pages/workspace/workspace_controller.dart';

Future<(int, Map<String, dynamic>)> _request(
  Map<String, dynamic> configuration,
  String operation,
  Map<String, Object?> arguments,
) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 1);
  try {
    final request = await client
        .postUrl(Uri.parse('${configuration['endpoint']}/v1/call'))
        .timeout(const Duration(seconds: 2));
    request.headers.contentType = ContentType.json;
    request.headers.set(
      HttpHeaders.authorizationHeader,
      'Bearer ${configuration['token']}',
    );
    request.write(jsonEncode({'operation': operation, 'arguments': arguments}));
    final response = await request.close().timeout(const Duration(seconds: 2));
    final body = await utf8.decoder
        .bind(response)
        .join()
        .timeout(const Duration(seconds: 2));
    return (
      response.statusCode,
      Map<String, dynamic>.from(jsonDecode(body) as Map),
    );
  } finally {
    client.close(force: true);
  }
}

Future<void> _settle(Future<void>? future) async {
  if (future == null) return;
  try {
    await future.timeout(const Duration(seconds: 5));
  } catch (_) {
    /* Cleanup must retain the original assertion failure. */
  }
}

void main() {
  late Directory temp;
  late Directory support;
  late File executable;
  late WorkspaceController controller;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('mcp-access-lifecycle-');
    support = Directory('${temp.path}/support');
    // The controller only checks presence. This fixture is never executed.
    executable = await File('${temp.path}/presence-only.exe')
        .writeAsString('test fixture');
    controller = WorkspaceController(
      await NoteRepository.open(
        Directory('${temp.path}/vault'),
        createFormatVersion: 2,
      ),
      directoryProvider: () async => support,
    );
  });
  tearDown(() async {
    await controller.flush();
    controller.dispose();
    await controller.repository.close();
    await temp.delete(recursive: true);
  });

  test('concurrent access starts share one private bridge and stop closes the old authorized endpoint', () async {
    final entered = Completer<void>(), release = Completer<Directory>();
    var directories = 0, services = 0;
    final access = McpAccessController(
      () {
        services++;
        return VaultMcpService(controller, prepareMutation: controller.flush);
      },
      executable: executable.path,
      supportDirectory: () {
        directories++;
        if (!entered.isCompleted) entered.complete();
        return release.future;
      },
    );
    Future<void>? first, second;
    try {
      first = access.start();
      second = access.start();
      await entered.future.timeout(const Duration(seconds: 2));
      // Assert before releasing either call: the RED path cannot leak an orphan.
      expect(
        directories,
        1,
        reason: 'A pending start must be shared by all callers',
      );
      release.complete(support);
      await Future.wait([first, second]).timeout(const Duration(seconds: 5));
      expect(services, 1);
      expect(access.connected, true);
      final configFile = File('${support.path}/mcp/bridge.json');
      final configuration = Map<String, dynamic>.from(
        jsonDecode(await configFile.readAsString()) as Map,
      );
      final status = await _request(configuration, 'vault_status', {});
      expect(status.$1, 200);
      expect(status.$2['ok'], true);
      await access.allowEdits(true);
      await access.stop();
      expect(access.connected, false);
      expect(configFile.existsSync(), false);
      await expectLater(
        _request(configuration, 'create_document', {
          'kind': 'markdown',
          'title': 'Must not be created after stop',
          'requestId': newId(),
        }),
        throwsA(
          anyOf(
            isA<SocketException>(),
            isA<HttpException>(),
            isA<TimeoutException>(),
          ),
        ),
      );
      expect(await controller.store.list(), isEmpty);
    } finally {
      // In the old implementation both late starts see disposed and close their
      // own bridges. Releasing only after dispose avoids leaking a RED fixture.
      access.dispose();
      if (!release.isCompleted) release.complete(support);
      await _settle(first);
      await _settle(second);
      await access.stop();
    }
  });

  test(
    'stopping a pending start leaves no late endpoint token or private config',
    () async {
      final entered = Completer<void>(), release = Completer<Directory>();
      final access = McpAccessController(
        () => VaultMcpService(controller, prepareMutation: controller.flush),
        executable: executable.path,
        supportDirectory: () {
          if (!entered.isCompleted) entered.complete();
          return release.future;
        },
      );
      Future<void>? starting, stopping;
      try {
        starting = access.start();
        await entered.future.timeout(const Duration(seconds: 2));
        stopping = access.stop();
        release.complete(support);
        await Future.wait([starting, stopping])
            .timeout(const Duration(seconds: 5));
        expect(
          access.connected,
          false,
          reason: 'A canceled pending start must not activate after stop',
        );
        expect(access.writeEnabled, false);
        expect(File('${support.path}/mcp/bridge.json').existsSync(), false);
      } finally {
        access.dispose();
        if (!release.isCompleted) release.complete(support);
        await _settle(starting);
        await _settle(stopping);
        await access.stop();
      }
    },
  );
}
