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
import 'package:saber/data/vault/knowledge_index.dart';
import 'package:saber/data/vault/workspace_database.dart';
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
    'actual Rust MCP preserves inline text, search, links, retries and guards after restart',
    () async {
      final temp = await Directory.systemTemp.createTemp('piv-inline-stdio-');
      final vault = Directory(p.join(temp.path, 'vault'));
      final native = InkVaultNative.open(libraryPath: library);
      var controller = WorkspaceController(
        await NoteRepository.open(vault, createFormatVersion: 2),
        native: native,
      );
      var repositoryOpen = true;
      McpAccessController? access;
      _Client? client;
      final exits = <int>[];
      final executableHash = sha256
          .convert(await File(executable).readAsBytes())
          .toString();
      final libraryHash = sha256
          .convert(await File(library).readAsBytes())
          .toString();

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
            'clientInfo': {'name': 'piv-inline-acceptance', 'version': '1.0'},
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

      Future<Map<String, dynamic>> read(String id) async =>
          client!.data(await client!.tool('read_document', {'noteId': id}));
      Map<String, dynamic> content(Map<String, dynamic> value) =>
          Map<String, dynamic>.from(value['body']['content'] as Map);
      Future<Set<String>> revisions() async =>
          (await controller.repository.revisions())
              .map((r) => r.revisionId)
              .toSet();
      const text = '연구foobar한글 😀 끝';
      Map<String, dynamic> body(String target, {bool changed = false}) => {
        'version': 3,
        'blockMedia': <String, Object?>{},
        'futurePage': {'preserved': true},
        'blocks': [
          {
            'id': blockId,
            'type': 'paragraph',
            'text': text,
            'futureBlock': ['keep'],
            'inlineData': {
              'format': 'personal-ink-inline-1',
              'textSha256': sha256.convert(utf8.encode(text)).toString(),
              'futureInline': {'preserved': true},
              'runs': [
                {
                  'start': 2,
                  'end': 5,
                  'marks': <String>[],
                  'link': 'inkvault://note/$target',
                },
                {
                  'start': 5,
                  'end': 8,
                  'marks': [if (changed) 'strikethrough' else 'bold'],
                  'link': 'inkvault://note/$target',
                },
              ],
            },
          },
        ],
      };

      try {
        await start();
        await access!.allowEdits(true);
        final target =
            client!.data(
                  await client!.tool('create_document', {
                    'kind': 'page',
                    'title': '서식 링크 대상',
                    'body': {'version': 1, 'blocks': <Object?>[]},
                    'requestId': newId(),
                  }),
                )['noteId']
                as String;
        final shieldedIds = <String>[];
        for (final shieldedText in ['```\na\n\nb', '<div>\na\n\nb']) {
          final shielded = client!.data(
            await client!.tool('create_document', {
              'kind': 'page',
              'title': '보호 구문 뒤 서식 링크',
              'requestId': newId(),
              'body': {
                'version': 3,
                'blockMedia': <String, Object?>{},
                'blocks': [
                  {
                    'id': newId(),
                    'type': 'paragraph',
                    'text': shieldedText,
                    'inlineData': {
                      'format': 'personal-ink-inline-1',
                      'textSha256': sha256
                          .convert(utf8.encode(shieldedText))
                          .toString(),
                      'runs': [
                        {
                          'start': 0,
                          'end': shieldedText.length,
                          'marks': ['bold'],
                          'link': 'inkvault://note/$target',
                        },
                      ],
                    },
                  },
                ],
              },
            }),
          );
          shieldedIds.add(shielded['noteId'] as String);
        }
        final initial = body(target);
        final created = client!.data(
          await client!.tool('create_document', {
            'kind': 'page',
            'title': '서식 자동화',
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
        await session.saveMarkdown('직접 쓴 별도 Markdown');
        final before = await read(noteId);
        final oldRevision = before['body']['revisionId'] as String;
        final edited = body(target, changed: true);
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
        expect(stored['markdown']['content'], '직접 쓴 별도 Markdown');
        final index = await KnowledgeIndex.build(controller.repository, native);
        expect(index.search('foobar').map((hit) => hit.id), contains(noteId));
        expect(
          index.edges.any((edge) => edge.from == noteId && edge.to == target),
          true,
        );
        for (final shieldedId in shieldedIds) {
          expect(
            index.edges.any(
              (edge) => edge.from == shieldedId && edge.to == target,
            ),
            true,
          );
        }
        expect(
          jsonEncode(
            client!.data(
              await client!.tool('list_documents', {'query': 'foobar'}),
            ),
          ),
          contains(noteId),
        );
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
          jsonDecode(
            utf8.decode(
              (await controller.repository.readFiles(original))['page.json']!,
            ),
          ),
          initial,
        );

        final downgrade = {
          'version': 2,
          'blockMedia': <String, Object?>{},
          'blocks': [
            {'id': blockId, 'type': 'paragraph', 'text': text},
          ],
        };
        final staleDigest =
            jsonDecode(jsonEncode(edited)) as Map<String, dynamic>;
        (staleDigest['blocks'] as List).single['text'] = '상대가 바꾼 원문';
        for (final invalid in [
          {...request, 'requestId': newId()},
          {
            ...request,
            'content': staleDigest,
            'requestId': newId(),
            'expectedRevisionId': result['revisionId'],
          },
          {
            ...request,
            'content': downgrade,
            'requestId': newId(),
            'expectedRevisionId': result['revisionId'],
          },
        ]) {
          expect(
            (await client!.tool('update_document', invalid))['isError'],
            true,
          );
        }
        expect(await revisions(), after);
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

        await access!.allowEdits(true);
        final db = WorkspaceDatabase.empty();
        final row = DatabaseRow.create(body: initial);
        final databaseBody = db.copyWith(rows: [row]).toJson();
        final database = client!.data(
          await client!.tool('create_document', {
            'kind': 'database',
            'title': '서식 행',
            'body': databaseBody,
            'requestId': newId(),
          }),
        );
        final databaseId = database['noteId'] as String;
        final databaseRead = await read(databaseId);
        expect(content(databaseRead), databaseBody);
        final rowDowngrade =
            jsonDecode(jsonEncode(databaseBody)) as Map<String, dynamic>;
        (rowDowngrade['rows'] as List).single['body'] = downgrade;
        final databaseRevisions = await revisions();
        expect(
          (await client!.tool('update_document', {
            'noteId': databaseId,
            'target': 'body',
            'content': rowDowngrade,
            'expectedRevisionId': databaseRead['body']['revisionId'],
            'requestId': newId(),
          }))['isError'],
          true,
        );
        expect(await revisions(), databaseRevisions);

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
        expect(content(await read(databaseId)), databaseBody);
        await access!.allowEdits(true);
        expect(
          client!.data(await client!.tool('update_document', request)),
          result,
        );
        expect(await revisions(), databaseRevisions);
        final reopenedIndex = await KnowledgeIndex.build(
          controller.repository,
          native,
        );
        expect(
          reopenedIndex.search('foobar').map((hit) => hit.id),
          containsAll([noteId, databaseId]),
        );
        expect(
          reopenedIndex.edges.any(
            (edge) => edge.from == noteId && edge.to == target,
          ),
          true,
        );
        for (final shieldedId in shieldedIds) {
          expect(
            reopenedIndex.edges.any(
              (edge) => edge.from == shieldedId && edge.to == target,
            ),
            true,
          );
        }
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
        final report = Platform.environment['PIV_INLINE_STDIO_REPORT'];
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
                'formatOnlyUpdate',
                'retry',
                'reopen',
                'retryAfterRestart',
                'staleDenied',
                'staleTextDigestDenied',
                'pageDowngradeDenied',
                'databaseRowDowngradeDenied',
                'readOnlyDenied',
                'historyPreserved',
                'opaquePreserved',
                'markdownPreserved',
                'mcpWholeWordSearch',
                'rustWholeWordSearch',
                'inlineNoteBacklink',
                'multilineBacklinkOutsideProtectedText',
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

const blockId = '038784b4-e660-4cea-b0df-219e51fca27f';

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
