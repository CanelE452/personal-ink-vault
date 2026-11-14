import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/mcp/vault_mcp_service.dart';
import 'package:saber/data/native/ink_vault_native.dart';
import 'package:saber/data/vault/block_page_document.dart';
import 'package:saber/data/vault/knowledge_index.dart';
import 'package:saber/pages/workspace/mcp_panel.dart';
import 'package:saber/pages/workspace/workspace_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final executable =
      Platform.environment['INK_VAULT_MCP_TEST_EXE'] ??
      p.absolute('build/native/windows/ink_vault_mcp.exe');
  final library =
      Platform.environment['INK_VAULT_NATIVE_LIBRARY'] ??
      p.absolute('build/native/windows/ink_vault_native.dll');

  test(
    'actual Rust stdio edits a page table and retains its history after restart',
    () async {
      final temp = await Directory.systemTemp.createTemp('piv-table-stdio-');
      final vault = Directory(p.join(temp.path, 'vault'));
      final native = InkVaultNative.open(libraryPath: library);
      var controller = WorkspaceController(
        await NoteRepository.open(vault, createFormatVersion: 2),
        native: native,
      );
      McpAccessController? access;
      _Client? client;
      var repositoryOpen = true;
      final executableHash = sha256
          .convert(await File(executable).readAsBytes())
          .toString();
      final libraryHash = sha256
          .convert(await File(library).readAsBytes())
          .toString();
      final exits = <int>[];

      Future<void> start() async {
        access = McpAccessController(
          () => VaultMcpService(controller, prepareMutation: controller.flush),
          executable: executable,
          supportDirectory: () async => Directory(p.join(temp.path, 'support')),
        );
        await access!.start();
        final config =
            (access!.clientConfiguration['mcpServers']
                    as Map)['personal-ink-vault']
                as Map;
        client = _Client(
          await Process.start(
            executable,
            List<String>.from(config['args'] as List),
          ),
        );
        expect(
          (await client!.request('initialize', {
            'protocolVersion': '2025-11-25',
            'capabilities': <String, Object?>{},
            'clientInfo': {
              'name': 'piv-page-table-acceptance',
              'version': '1.0',
            },
          }))['error'],
          isNull,
        );
        client!.process.stdin.writeln(
          jsonEncode({'jsonrpc': '2.0', 'method': 'notifications/initialized'}),
        );
      }

      Future<void> stop() async {
        if (client != null) {
          exits.add(await client!.close());
          client = null;
        }
        await access?.stop();
        access?.dispose();
        access = null;
      }

      Map<String, dynamic> body(String text) => {
        'version': 1,
        'futurePage': {'preserved': true},
        'blocks': [
          {
            'id': newId(),
            'type': 'table',
            'text': '표 설명',
            'futureBlock': ['keep'],
            'tableData': {
              'format': 'personal-ink-table-1',
              'columns': [newId(), newId()],
              'rows': [
                for (var row = 0; row < 2; row++)
                  {
                    'id': newId(),
                    'futureRow': row,
                    'cells': [
                      for (var column = 0; column < 2; column++)
                        {
                          'id': newId(),
                          'text': row == 0 && column == 0
                              ? text
                              : '$row:$column',
                          'futureCell': {'keep': true},
                        },
                    ],
                  },
              ],
              'headerRow': true,
              'headerColumn': false,
              'futureTable': {'keep': true},
            },
          },
        ],
      };
      Future<Set<String>> revisions() async =>
          (await controller.repository.revisions())
              .map((r) => r.revisionId)
              .toSet();
      Future<Map<String, dynamic>> read(String id) async =>
          client!.data(await client!.tool('read_document', {'noteId': id}));
      Map<String, dynamic> content(Map<String, dynamic> read) =>
          Map<String, dynamic>.from(read['body']['content'] as Map);
      try {
        await start();
        await access!.allowEdits(true);
        final initial = body('처음 표 내용 😀');
        final created = client!.data(
          await client!.tool('create_document', {
            'kind': 'page',
            'title': '표 자동화',
            'body': initial,
            'requestId': newId(),
          }),
        );
        final noteId = created['noteId'] as String;
        final note = (await controller.store.list()).singleWhere(
          (n) => n.id == noteId,
        );
        final session = await controller.store.open(note);
        final first = (await controller.repository.heads(note.inkEntityId))
            .single;
        final firstFiles = await controller.repository.readFiles(first);
        final opaque = Uint8List.fromList([0, 255, 17, 42]);
        await session.saveInk({...firstFiles, 'retained/future.bin': opaque});
        await session.saveMarkdown('직접 쓴 Markdown 정리');
        final before = await read(noteId);
        final oldRevision = before['body']['revisionId'] as String;
        final edited = content(before);
        final table = (edited['blocks'] as List).single['tableData'] as Map;
        (table['rows'] as List).first['cells'][0]['text'] = '동기화 셀 고유문구 😀';
        final request = <String, Object?>{
          'noteId': noteId,
          'target': 'body',
          'content': edited,
          'expectedRevisionId': oldRevision,
          'requestId': newId(),
        };
        final count = await revisions();
        final result = client!.data(
          await client!.tool('update_document', request),
        );
        final after = await revisions();
        expect(after.difference(count), hasLength(1));
        expect(
          client!.data(await client!.tool('update_document', request)),
          result,
        );
        expect(await revisions(), after);
        final stored = await read(noteId);
        expect(content(stored), edited);
        expect(stored['markdown']['content'], '직접 쓴 Markdown 정리');
        final projection = BlockPageDocument.fromJson(content(stored))
            .toMarkdown();
        expect(projection, contains('동기화 셀 고유문구 😀'));
        final listed = client!.data(
          await client!.tool('list_documents', {'query': '동기화 셀 고유문구'}),
        );
        expect(jsonEncode(listed), contains(noteId));
        final index = await KnowledgeIndex.build(controller.repository, native);
        expect(index.search('고유문구').map((hit) => hit.id), contains(noteId));
        final current = (await controller.repository.heads(note.inkEntityId))
            .single;
        expect(
          (await controller.repository.readFiles(
            current,
          ))['retained/future.bin'],
          opaque,
        );
        final original = (await controller.repository.revisions()).singleWhere(
          (r) => r.revisionId == oldRevision,
        );
        expect(
          utf8.decode(
            (await controller.repository.readFiles(original))['page.json']!,
          ),
          contains('처음 표 내용 😀'),
        );
        final malformed =
            jsonDecode(jsonEncode(edited)) as Map<String, dynamic>;
        ((malformed['blocks'] as List).single['tableData']['rows'] as List)
            .first['cells']
            .removeLast();
        for (final invalid in [
          {...request, 'requestId': newId()},
          {
            ...request,
            'content': malformed,
            'requestId': newId(),
            'expectedRevisionId': result['revisionId'],
          },
        ]) {
          expect(
            (await client!.tool('update_document', invalid))['isError'],
            true,
          );
        }
        await access!.allowEdits(false);
        expect(
          (await client!.tool('update_document', {
            ...request,
            'requestId': newId(),
            'expectedRevisionId': result['revisionId'],
          }))['isError'],
          true,
        );
        expect(await revisions(), after);
        await stop();
        await controller.flush();
        controller.dispose();
        await controller.repository.close();
        repositoryOpen = false;
        controller = WorkspaceController(
          await NoteRepository.open(vault),
          native: native,
        );
        repositoryOpen = true;
        await start();
        expect(content(await read(noteId)), edited);
        await access!.allowEdits(true);
        expect(
          client!.data(await client!.tool('update_document', request)),
          result,
        );
        expect(await revisions(), after);
        await stop();
        expect(exits, [0, 0]);
        expect(
          sha256.convert(await File(executable).readAsBytes()).toString(),
          executableHash,
        );
        expect(
          sha256.convert(await File(library).readAsBytes()).toString(),
          libraryHash,
        );
        final report = Platform.environment['PIV_TABLE_STDIO_REPORT'];
        if (report != null) {
          await File(report).writeAsString(
            jsonEncode({
              'passed': true,
              'actualRustSdk': true,
              'actualRustSearch': true,
              'sdkSha256': executableHash,
              'librarySha256': libraryHash,
              'processExits': exits,
              'forcedTermination': false,
              'checks': [
                'create',
                'read',
                'update',
                'retry',
                'reopen',
                'retryAfterRestart',
                'staleDenied',
                'malformedDenied',
                'readOnlyDenied',
                'historyPreserved',
                'opaquePreserved',
                'markdownPreserved',
                'mcpSearch',
                'rustSearch',
              ],
            }),
          );
        }
      } finally {
        await stop();
        if (repositoryOpen) {
          await controller.flush();
          controller.dispose();
          await controller.repository.close();
        }
        expect(p.isWithin(Directory.systemTemp.path, temp.path), true);
        await temp.delete(recursive: true);
      }
    },
    skip: !File(executable).existsSync() || !File(library).existsSync()
        ? 'Build the actual Windows Rust SDK and native library first'
        : false,
  );
}

class _Client {
  new(this.process) {
    subscription = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          final message = Map<String, dynamic>.from(jsonDecode(line) as Map);
          if (message['id'] is int)
            pending.remove(message['id'])?.complete(message);
        });
    errors = process.stderr.drain<void>();
  }
  final Process process;
  final pending = <int, Completer<Map<String, dynamic>>>{};
  late final StreamSubscription<String> subscription;
  late final Future<void> errors;
  var sequence = 0;
  Future<Map<String, dynamic>> request(
    String method,
    Map<String, Object?> args,
  ) {
    final id = ++sequence;
    final result = Completer<Map<String, dynamic>>();
    pending[id] = result;
    process.stdin.writeln(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': args,
      }),
    );
    return result.future.timeout(const Duration(seconds: 20));
  }

  Future<Map<String, dynamic>> tool(
    String name,
    Map<String, Object?> args,
  ) async {
    final result = await request('tools/call', {
      'name': name,
      'arguments': args,
    });
    expect(result['error'], isNull);
    return Map<String, dynamic>.from(result['result'] as Map);
  }

  Map<String, dynamic> data(Map<String, dynamic> result) {
    expect(result['isError'], isNot(true), reason: jsonEncode(result));
    return Map<String, dynamic>.from(
      result['structuredContent'] as Map? ??
          jsonDecode(result['content'][0]['text'] as String) as Map,
    );
  }

  Future<int> close() async {
    await process.stdin.close();
    try {
      final code = await process.exitCode.timeout(const Duration(seconds: 10));
      await subscription.cancel();
      await errors;
      return code;
    } on TimeoutException {
      process.kill();
      await process.exitCode;
      await subscription.cancel();
      await errors;
      rethrow;
    }
  }
}
