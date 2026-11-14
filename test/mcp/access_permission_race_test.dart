import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/mcp/vault_mcp_bridge.dart';
import 'package:saber/data/mcp/vault_mcp_service.dart';
import 'package:saber/pages/workspace/workspace_controller.dart';

void main() {
  test('an older failed enable cannot undo a newer completed revoke or authorize a new HTTP write', () async {
    final temp = await Directory.systemTemp.createTemp('mcp-permission-race-');
    final config = File('${temp.path}/private/bridge.json');
    final controller = WorkspaceController(
      await NoteRepository.open(
        Directory('${temp.path}/vault'),
        createFormatVersion: 2,
      ),
      directoryProvider: () async => temp,
    );
    final service = VaultMcpService(
      controller,
      prepareMutation: controller.flush,
    );
    VaultMcpBridge? bridge;
    try {
      bridge = await VaultMcpBridge.start(
        configFile: config,
        writeEnabled: true,
        handler: (operation, arguments, context) =>
            service.call(operation, arguments, context: context),
      );
      final settings = Map<String, dynamic>.from(
        jsonDecode(await config.readAsString()) as Map,
      );
      await config.delete();
      await Directory(config.path).create();
      var olderFailed = false;
      final enabling = bridge
          .setWriteEnabled(true)
          .then<void>(
            (_) {
              fail('The first configuration rename must fail in this fixture');
            },
            onError: (Object error, StackTrace stack) {
              expect(error, isA<FileSystemException>());
              olderFailed = true;
              // Repair only the failed target before the queued revoke publishes.
              // The pending config files are siblings, so this directory is empty.
              Directory(config.path).deleteSync();
            },
          );
      final revoking = bridge.setWriteEnabled(false);
      await Future.wait([enabling, revoking])
          .timeout(const Duration(seconds: 5));
      expect(olderFailed, true);

      // A real request after the revoke future completes must remain forbidden.
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 1);
      try {
        final request = await client
            .postUrl(Uri.parse('${settings['endpoint']}/v1/call'))
            .timeout(const Duration(seconds: 2));
        request.headers.contentType = ContentType.json;
        request.headers.set(
          HttpHeaders.authorizationHeader,
          'Bearer ${settings['token']}',
        );
        request.write(
          jsonEncode({
            'operation': 'create_document',
            'arguments': {
              'kind': 'markdown',
              'title': 'Must remain forbidden',
              'body': 'No unauthorized revision',
              'requestId': newId(),
            },
          }),
        );
        final response = await request.close().timeout(
          const Duration(seconds: 3),
        );
        final result = jsonDecode(
          await utf8.decoder
              .bind(response)
              .join()
              .timeout(const Duration(seconds: 3)),
        ) as Map;
        expect(response.statusCode, 403);
        expect(result['error']['code'], 'read_only');
      } finally {
        client.close(force: true);
      }
      expect(bridge.writeEnabled, false);
      expect(await controller.store.list(), isEmpty);
      final persisted = jsonDecode(await config.readAsString()) as Map;
      expect(persisted['writeEnabled'], false);
    } finally {
      await bridge?.stop();
      await controller.flush();
      controller.dispose();
      await controller.repository.close();
      await temp.delete(recursive: true);
    }
  });
}
