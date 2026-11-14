import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/mcp/vault_mcp_bridge.dart';
import 'package:saber/data/mcp/vault_mcp_service.dart';
import 'package:saber/data/vault/block_page_document.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/pages/workspace/workspace_controller.dart';

const _read = 'list_page_discussions';
const _mutate = 'mutate_page_discussion';
const _eventFile = 'discussion-event.json';
const _prefix = 'piv-discussion-stdio-';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final executable = Platform.environment['INK_VAULT_MCP_TEST_EXE'];

  test(
    'Rust stdio discussion tools enforce access and replay persisted events after a cold restart',
    () async {
      final exe = File(p.absolute(executable!));
      expect(
        exe.existsSync(),
        isTrue,
        reason: 'Expected the configured MCP exe',
      );
      final temp = await Directory.systemTemp.createTemp(_prefix);
      final vault = Directory(p.join(temp.path, 'vault'));
      final bridgeFile = File(p.join(temp.path, 'support', 'bridge.json'));
      final exits = <int>[];
      WorkspaceController? controller;
      VaultMcpBridge? bridge;
      _StdioClient? client;

      Future<WorkspaceController> open() async {
        final workspace = WorkspaceController(
          await NoteRepository.open(vault, createFormatVersion: 2),
        );
        controller = workspace;
        final service = VaultMcpService(
          workspace,
          prepareMutation: workspace.flush,
        );
        bridge = await VaultMcpBridge.start(
          configFile: bridgeFile,
          handler: (operation, arguments, context) =>
              service.call(operation, arguments, context: context),
        );
        return workspace;
      }

      Future<_StdioClient> connect() async {
        final connection = _StdioClient(
          await Process.start(
            exe.path,
            ['--bridge-file', bridgeFile.path],
            workingDirectory: temp.path,
            includeParentEnvironment: false,
            environment: {
              'SystemRoot': ?Platform.environment['SystemRoot'],
              'TEMP': temp.path,
              'TMP': temp.path,
            },
          ),
        );
        client = connection;
        await connection.request('initialize', {
          'protocolVersion': '2025-11-25',
          'capabilities': <String, Object?>{},
          'clientInfo': {'name': 'piv-discussion-stdio', 'version': '1.0'},
        });
        connection.send({'method': 'notifications/initialized'});
        return connection;
      }

      Future<void> close() async {
        try {
          final connection = client;
          client = null;
          if (connection != null) exits.add(await connection.close());
        } finally {
          try {
            final server = bridge;
            bridge = null;
            await server?.stop();
          } finally {
            final workspace = controller;
            if (workspace != null) {
              controller = null;
              workspace.dispose();
              await workspace.repository.close();
            }
          }
        }
      }

      try {
        final workspace = await open();
        final repo = workspace.repository;
        final note = await workspace.store.create(
          '댓글 stdio 시험',
          documentKind: VaultDocumentKind.page,
        );
        final block = BlockPageBlock.create(type: 'paragraph', text: '앞😀한뒤');
        final document = const BlockPageDocument.empty().copyWith(
          blocks: [block],
        );
        final bodyBytes = Uint8List.fromList(
          utf8.encode(jsonEncode(document.toJson())),
        );
        final body = await repo.commit(
          entityId: note.inkEntityId,
          kind: EntityKind.ink,
          ownerNoteId: note.id,
          parentRevisionIds: [],
          files: {'page.json': bodyBytes},
        );
        final listRequest = {'noteId': note.id};
        final first = await connect();
        final tools = (await first.request('tools/list', {}))['tools'] as List;
        for (final (name, required, readOnlyHint) in [
          (_read, ['noteId'], true),
          (
            _mutate,
            [
              'noteId',
              'expectedMetadataRevisionId',
              'expectedBody',
              'requestId',
              'action',
            ],
            false,
          ),
        ]) {
          final tool = tools.cast<Map>().singleWhere(
            (tool) => tool['name'] == name,
          );
          final schema = tool['inputSchema'] as Map;
          expect(schema['additionalProperties'], isFalse);
          expect(schema['required'], unorderedEquals(required));
          expect(tool['annotations']['readOnlyHint'], readOnlyHint);
          expect(tool['annotations']['openWorldHint'], isFalse);
        }

        final empty = await first.tool(_read, listRequest);
        expect(empty['threads'], isEmpty);
        expect(empty['metadataRevisionId'], note.revision.revisionId);
        expect(empty['body'], {'kind': 'saved', 'revisionId': body.revisionId});
        Map<String, Object?> mutation(Map<String, Object?> action) => {
          ...listRequest,
          'expectedMetadataRevisionId': empty['metadataRevisionId'],
          'expectedBody': empty['body'],
          'requestId': newId(),
          'action': action,
        };
        const rootBody = '원문 선택 댓글 😀';
        const replyBody = '저장할 답글 한글';
        final create = {
          'type': 'create_thread',
          'anchor': {
            'kind': 'quote',
            'blockId': block.id,
            'startUtf16': 1,
            'endUtf16': 4,
          },
          'body': rootBody,
        };
        final createRequest = mutation(create);
        final before = await _revisionIds(repo);
        await first.tool(_mutate, createRequest, errorCode: 'read_only');
        expect(await _revisionIds(repo), before);

        await bridge!.setWriteEnabled(true);
        final created = await first.tool(_mutate, createRequest);
        final threadId = created['threadId'] as String;
        expect(created['eventId'], threadId);
        expect(created['noteId'], note.id);
        final replied = await first.tool(
          _mutate,
          mutation({
            'type': 'reply',
            'threadId': threadId,
            'replyToId': threadId,
            'body': replyBody,
          }),
        );
        final resolved = await first.tool(
          _mutate,
          mutation({
            'type': 'set_resolved',
            'threadId': threadId,
            'resolved': true,
            'expectedStatusIds': [threadId],
          }),
        );
        final replyId = replied['eventId'] as String;
        final resolutionId = resolved['eventId'] as String;
        expect(replied['threadId'], threadId);
        expect(resolved['threadId'], threadId);
        expect({threadId, replyId, resolutionId}, hasLength(3));
        final published = await _revisionIds(repo);
        expect(published.difference(before), {
          created['revisionId'],
          replied['revisionId'],
          resolved['revisionId'],
        });

        await close();
        final reopened = (await open()).repository;
        final cold = await connect();
        final detail = await cold.tool(_read, {
          ...listRequest,
          'threadId': threadId,
        });
        final thread = detail['thread'] as Map;
        final anchor = thread['anchor'] as Map;
        expect(detail['body'], empty['body']);
        expect(thread['threadId'], threadId);
        expect(thread['anchorStatus'], 'attached');
        expect(anchor, containsPair('kind', 'quote'));
        expect(anchor, containsPair('blockId', block.id));
        expect(anchor, containsPair('quote', '😀한'));
        expect(anchor, containsPair('startUtf16', 1));
        expect(anchor, containsPair('endUtf16', 4));
        expect(thread['root'], containsPair('body', rootBody));
        expect(thread['status'], 'resolved');
        expect(thread['statusHeads'], [
          {'id': resolutionId, 'resolved': true},
        ]);
        expect(
          (detail['replies'] as List).single,
          allOf(
            containsPair('id', replyId),
            containsPair('replyToId', threadId),
            containsPair('body', replyBody),
          ),
        );
        await cold.tool(_mutate, createRequest, errorCode: 'read_only');
        await bridge!.setWriteEnabled(true);
        expect(await cold.tool(_mutate, createRequest), created);
        await cold.tool(_mutate, {
          ...createRequest,
          'action': {...create, 'body': '같은 요청 ID의 다른 본문'},
        }, errorCode: 'request_id_reused');
        await bridge!.setWriteEnabled(false);
        await cold.tool(_mutate, createRequest, errorCode: 'read_only');
        expect(await _revisionIds(reopened), published);

        Future<Map<String, dynamic>> storedEvent(Map result) async {
          final record = (await reopened.heads(result['eventId'] as String))
              .single;
          expect(record.revisionId, result['revisionId']);
          expect(record.kind, EntityKind.attachment);
          expect(record.ownerNoteId, note.id);
          final files = await reopened.readFiles(record);
          final event = jsonDecode(
            utf8.decode(files[_eventFile]!),
          ) as Map<String, dynamic>;
          expect(event['pageId'], note.id);
          expect(event['eventId'], result['eventId']);
          expect(event['threadId'], threadId);
          return event;
        }

        expect(
          await storedEvent(created),
          allOf(
            containsPair('kind', 'thread'),
            containsPair('body', rootBody),
            containsPair('anchor', anchor),
          ),
        );
        expect(
          await storedEvent(replied),
          allOf(
            containsPair('kind', 'reply'),
            containsPair('body', replyBody),
            containsPair('replyToId', threadId),
          ),
        );
        expect(
          await storedEvent(resolved),
          allOf(
            containsPair('kind', 'status'),
            containsPair('resolved', true),
            containsPair('statusParentIds', [threadId]),
          ),
        );
        expect(
          (await reopened.heads(note.id)).single.revisionId,
          note.revision.revisionId,
        );
        final storedBody = (await reopened.heads(note.inkEntityId)).single;
        expect(storedBody.revisionId, body.revisionId);
        expect((await reopened.readFiles(storedBody))['page.json'], bodyBytes);
        await close();
        expect(exits, [0, 0]);
      } finally {
        try {
          await close();
        } finally {
          final actual = await temp.resolveSymbolicLinks();
          final parent = await Directory.systemTemp.resolveSymbolicLinks();
          expect(p.dirname(actual), p.normalize(parent));
          expect(p.basename(actual), startsWith(_prefix));
          await Directory(actual).delete(recursive: true);
        }
      }
    },
    skip: !Platform.isWindows || executable == null
        ? 'Set INK_VAULT_MCP_TEST_EXE to the installed Windows Rust MCP executable'
        : false,
  );
}

Future<Set<String>> _revisionIds(NoteRepository repository) async => {
  for (final revision in await repository.revisions()) revision.revisionId,
};

final class _StdioClient {
  new(this.process)
    : _stdout = StreamIterator(
        process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      ),
      _stderr = process.stderr.drain<void>();

  final Process process;
  final StreamIterator<String> _stdout;
  final Future<void> _stderr;
  var _sequence = 0;

  void send(Map<String, Object?> message) => process.stdin.add(
    utf8.encode('${jsonEncode({'jsonrpc': '2.0', ...message})}\n'),
  );

  Future<Map<String, dynamic>> request(
    String method,
    Map<String, Object?> params,
  ) async {
    final id = ++_sequence;
    send({'id': id, 'method': method, 'params': params});
    while (await _stdout.moveNext().timeout(const Duration(seconds: 20))) {
      final response = jsonDecode(_stdout.current) as Map<String, dynamic>;
      if (response['id'] != id) continue;
      expect(response['error'], isNull, reason: method);
      return response['result'] as Map<String, dynamic>;
    }
    throw StateError('Rust MCP stdout closed before replying to $method');
  }

  Future<Map<String, dynamic>> tool(
    String name,
    Map<String, Object?> arguments, {
    String? errorCode,
  }) async {
    final result = await request('tools/call', {
      'name': name,
      'arguments': arguments,
    });
    expect(
      result['isError'] == true,
      errorCode != null,
      reason: jsonEncode(result),
    );
    final data = result['structuredContent'] as Map<String, dynamic>;
    if (errorCode != null) expect(data['code'], errorCode);
    return data;
  }

  Future<int> close() async {
    const timeout = Duration(seconds: 10);
    try {
      await process.stdin.close().timeout(timeout);
      return await process.exitCode.timeout(timeout);
    } on TimeoutException {
      process.kill();
      await process.exitCode;
      rethrow;
    } finally {
      await _stdout.cancel();
      await _stderr;
    }
  }
}
