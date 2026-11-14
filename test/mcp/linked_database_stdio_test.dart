import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/mcp/vault_mcp_service.dart';
import 'package:saber/data/native/ink_vault_native.dart';
import 'package:saber/data/vault/block_page_document.dart';
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
  final unavailable =
      !Platform.isWindows ||
      !File(executable).existsSync() ||
      !File(library).existsSync();
  Directory? temporary;
  WorkspaceController? controller;
  McpAccessController? access;
  _Client? client;
  late String executableHash, libraryHash;
  late List<int> exits;

  Future<void> start() async {
    access = McpAccessController(
      () => VaultMcpService(controller!, prepareMutation: controller!.flush),
      executable: executable,
      supportDirectory: () async =>
          Directory(p.join(temporary!.path, 'support')),
    );
    await access!.start();
    final config =
        (access!.clientConfiguration['mcpServers'] as Map)['personal-ink-vault']
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
          'name': 'piv-linked-database-regression',
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
    final closing = client;
    client = null;
    if (closing != null) exits.add(await closing.close());
    await access?.stop();
    access?.dispose();
    access = null;
  }

  Future<Map<String, dynamic>> read(String noteId) async =>
      client!.data(await client!.tool('read_document', {'noteId': noteId}));

  Map<String, dynamic> body(Map<String, dynamic> value) =>
      Map<String, dynamic>.from(value['body']['content'] as Map);

  String revision(Map<String, dynamic> value) =>
      value['body']['revisionId'] as String;

  Future<Set<String>> revisions() async =>
      (await controller!.repository.revisions())
          .map((record) => record.revisionId)
          .toSet();

  group(
    'actual Rust stdio linked database workflow',
    () {
      setUp(() async {
        exits = [];
        temporary = await Directory.systemTemp.createTemp('piv-linked-stdio-');
        controller = WorkspaceController(
          await NoteRepository.open(
            Directory(p.join(temporary!.path, 'vault')),
            createFormatVersion: 2,
          ),
          native: InkVaultNative.open(libraryPath: library),
        );
        executableHash = sha256
            .convert(await File(executable).readAsBytes())
            .toString();
        libraryHash = sha256
            .convert(await File(library).readAsBytes())
            .toString();
        await start();
      });

      tearDown(() async {
        await stop();
        if (controller != null) {
          await controller!.flush();
          controller!.dispose();
          await controller!.repository.close();
          controller = null;
        }
        if (temporary != null && temporary!.existsSync()) {
          final actual = await temporary!.resolveSymbolicLinks();
          final parent = await Directory.systemTemp.resolveSymbolicLinks();
          expect(p.isWithin(parent, actual), isTrue);
          expect(p.basename(actual), startsWith('piv-linked-stdio-'));
          await Directory(actual).delete(recursive: true);
        }
        temporary = null;
      });

      test(
        'database row templates persist through the real Rust stdio bridge',
        () async {
          await access!.allowEdits(true);
          final database = WorkspaceDatabase.empty();
          final title = database.properties.first.id;
          final block = BlockPageBlock.create(text: '연구 점검 템플릿');
          final source = DatabaseRow.create(
            values: {title: '기본 제목'},
            body: const BlockPageDocument.empty()
                .copyWith(blocks: [block])
                .toJson(),
          );
          final created = client!.data(
            await client!.tool('create_document', {
              'kind': 'database',
              'title': '템플릿 테스트 DB',
              'body': database.addRow(source).toJson(),
              'requestId': newId(),
            }),
          );
          final noteId = created['noteId'] as String;
          final captured = client!.data(
            await client!.tool('database_action', {
              'action': 'create_row_template',
              'noteId': noteId,
              'expectedRevisionId': revision(await read(noteId)),
              'requestId': newId(),
              'rowId': source.id,
              'name': '연구 점검',
            }),
          );
          final templateId = captured['templateId'] as String;
          final templateHead = await read(noteId);
          expect(
            WorkspaceDatabase.fromJson(body(templateHead))
                .rowTemplates
                .single
                .id,
            templateId,
          );
          final args = <String, Object?>{
            'action': 'add_row',
            'noteId': noteId,
            'expectedRevisionId': revision(templateHead),
            'requestId': newId(),
            'templateId': templateId,
            'values': {title: '이번 연구 점검'},
          };
          final added = client!.data(
            await client!.tool('database_action', args),
          );
          final replay = client!.data(
            await client!.tool('database_action', args),
          );
          expect(replay['rowId'], added['rowId']);
          await stop();
          expect(exits, [0]);
          await start();
          final reopened = WorkspaceDatabase.fromJson(body(await read(noteId)));
          expect(reopened.rows, hasLength(2));
          expect(reopened.rowTemplates.single.name, '연구 점검');
          final copy = reopened.rows.singleWhere(
            (row) => row.id == added['rowId'],
          );
          final copiedBlock = BlockPageDocument.fromJson(copy.body)
              .blocks
              .single;
          expect(copiedBlock.text, block.text);
          expect(copiedBlock.id, isNot(block.id));
          expect(copy.values[title], '이번 연구 점검');
          expect(reopened.rows.first.values[title], '기본 제목');
        },
      );

      test('page-local views query and edit the original DB with separate revision guards', () async {
        await access!.allowEdits(true);
        final complete = DatabaseProperty.create(name: '완료', type: 'checkbox');
        var database = WorkspaceDatabase.empty().addProperty(complete);
        final title = database.properties.first.id;
        final pending = DatabaseRow.create(
          values: {title: '검토할 문서 😀', complete.id: false},
        );
        final finished = DatabaseRow.create(
          values: {title: '완료한 문서', complete.id: true},
        );
        database = database.addRow(pending).addRow(finished);
        final createdSource = client!.data(
          await client!.tool('create_document', {
            'kind': 'database',
            'title': '공통 연구 DB',
            'body': database.toJson(),
            'requestId': newId(),
          }),
        );
        final sourceId = createdSource['noteId'] as String;
        final sourceBefore = await read(sourceId);
        final sourceRevision = revision(sourceBefore);
        final sourceViews = body(sourceBefore)['views'];
        final localView = DatabaseView.create(
          name: '이 페이지의 미완료',
          type: 'list',
          filter: {
            'propertyId': complete.id,
            'operator': 'equals',
            'value': false,
          },
          visibleProperties: [title, complete.id],
        );
        expect(
          database.views.map((view) => view.id),
          isNot(contains(localView.id)),
        );
        final page = const BlockPageDocument.empty().copyWith(
          blocks: [
            BlockPageBlock.createLinkedDatabase(
              noteId: sourceId,
              view: localView,
              text: '연구 대시보드',
            ),
          ],
        );
        final createdPage = client!.data(
          await client!.tool('create_document', {
            'kind': 'page',
            'title': '연구 페이지',
            'body': page.toJson(),
            'requestId': newId(),
          }),
        );
        final pageId = createdPage['noteId'] as String;
        final pageBefore = await read(pageId);
        final rawBlock = (body(pageBefore)['blocks'] as List).single as Map;
        final rawReference = rawBlock['linkedDatabaseData'] as Map;
        expect(rawReference['noteId'], sourceId);
        expect(rawReference['view'], localView.toJson());
        expect(sourceId, isNot(database.id));

        Future<Map<String, dynamic>> query(Map view, String expected) async =>
            client!.data(
              await client!.tool('database_query', {
                'noteId': rawReference['noteId'],
                'expectedRevisionId': expected,
                'capturedAtUtc': '2026-11-07T00:00:00.000Z',
                'operations': [
                  {'type': 'apply', 'view': Map<String, dynamic>.from(view)},
                ],
              }),
            );
        List<String> rowIds(Map<String, dynamic> result) => List<String>.from(
          (result['results'] as List).single['rowIds'] as List,
        );

        await access!.allowEdits(false);
        final beforeQuery = await revisions();
        final initialQuery = await query(
          rawReference['view'] as Map,
          sourceRevision,
        );
        expect(rowIds(initialQuery), [pending.id]);
        expect(initialQuery['revisionId'], sourceRevision);
        expect(await revisions(), beforeQuery);

        final localEditedView = localView.copyWith(
          name: '이 페이지의 완료',
          type: 'table',
          filter: {
            'propertyId': complete.id,
            'operator': 'equals',
            'value': true,
          },
        );
        final editedPage = page.copyWith(
          blocks: [
            page.blocks.single.copyWith(
              linkedDatabase: page.blocks.single.linkedDatabase!.copyWith(
                view: localEditedView,
              ),
            ),
          ],
        );
        final pageRequest = <String, Object?>{
          'noteId': pageId,
          'target': 'body',
          'content': editedPage.toJson(),
          'expectedRevisionId': revision(pageBefore),
          'requestId': newId(),
        };
        expect(
          (await client!.tool('update_document', pageRequest))['isError'],
          isTrue,
        );
        expect(await revisions(), beforeQuery);
        await access!.allowEdits(true);
        final pageUpdate = client!.data(
          await client!.tool('update_document', pageRequest),
        );
        final savedPage = await read(pageId);
        expect(revision(savedPage), pageUpdate['revisionId']);
        expect(body(savedPage), editedPage.toJson());
        expect(revision(await read(sourceId)), sourceRevision);
        expect(body(await read(sourceId))['views'], sourceViews);
        expect(rowIds(await query(localEditedView.toJson(), sourceRevision)), [
          finished.id,
        ]);

        final sourceRequest = <String, Object?>{
          'noteId': sourceId,
          'action': 'set_cell',
          'rowId': pending.id,
          'propertyId': complete.id,
          'value': true,
          'expectedRevisionId': sourceRevision,
          'requestId': newId(),
        };
        final sourceUpdate = client!.data(
          await client!.tool('database_action', sourceRequest),
        );
        final changedRevision = sourceUpdate['revisionId'] as String;
        expect(changedRevision, isNot(sourceRevision));
        expect(revision(await read(pageId)), revision(savedPage));
        final sourceAfter = body(await read(sourceId));
        expect(sourceAfter['views'], sourceViews);
        expect(
          (sourceAfter['rows'] as List).singleWhere(
            (row) => row['id'] == pending.id,
          )['values'][complete.id],
          isTrue,
        );
        expect(
          rowIds(await query(localEditedView.toJson(), changedRevision)),
          unorderedEquals([pending.id, finished.id]),
        );
        final committed = await revisions();
        expect(
          client!.data(await client!.tool('database_action', sourceRequest)),
          sourceUpdate,
        );
        expect(
          client!.data(await client!.tool('update_document', pageRequest)),
          pageUpdate,
        );
        expect(await revisions(), committed);

        final staleQuery = await client!.tool('database_query', {
          'noteId': sourceId,
          'expectedRevisionId': sourceRevision,
          'operations': [
            {'type': 'apply', 'view': localEditedView.toJson()},
          ],
        });
        expect(staleQuery['isError'], isTrue);
        expect(client!.payload(staleQuery)['code'], 'revision_conflict');
        expect(
          (await client!.tool('database_action', {
            ...sourceRequest,
            'value': false,
            'requestId': newId(),
          }))['isError'],
          isTrue,
        );
        expect(
          (await client!.tool('update_document', {
            ...pageRequest,
            'requestId': newId(),
          }))['isError'],
          isTrue,
        );
        expect(await revisions(), committed);

        await stop();
        await controller!.flush();
        controller!.dispose();
        await controller!.repository.close();
        controller = WorkspaceController(
          await NoteRepository.open(
            Directory(p.join(temporary!.path, 'vault')),
          ),
          native: InkVaultNative.open(libraryPath: library),
        );
        await start();
        expect(body(await read(pageId)), editedPage.toJson());
        expect(revision(await read(sourceId)), changedRevision);
        expect(
          rowIds(await query(localEditedView.toJson(), changedRevision)),
          unorderedEquals([pending.id, finished.id]),
        );
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
      });

      test('opaque future references roundtrip and malformed known references cannot publish', () async {
        await access!.allowEdits(true);
        final opaque = <String, dynamic>{
          'format': 'future-linked-database-9',
          'noteId': 'future://opaque-source',
          'view': <String, dynamic>{'foreign': true},
          'future': [1, '保留 😀'],
        };
        final page = <String, dynamic>{
          'version': 1,
          'futurePage': {'keep': true},
          'blocks': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': newId(),
              'type': 'linkedDatabase',
              'text': '미래 보기 설명',
              'linkedDatabaseData': opaque,
            },
          ],
        };
        final created = client!.data(
          await client!.tool('create_document', {
            'kind': 'page',
            'title': '미래 연결 보존',
            'body': page,
            'requestId': newId(),
          }),
        );
        final pageId = created['noteId'] as String;
        final before = await read(pageId);
        expect(body(before), page);
        final stableRevisions = await revisions();
        final malformed = jsonDecode(jsonEncode(page)) as Map<String, dynamic>;
        ((malformed['blocks'] as List).single['linkedDatabaseData']
                as Map)['format'] =
            'personal-ink-linked-database-1';
        expect(
          (await client!.tool('update_document', {
            'noteId': pageId,
            'target': 'body',
            'content': malformed,
            'expectedRevisionId': revision(before),
            'requestId': newId(),
          }))['isError'],
          isTrue,
        );
        expect(await revisions(), stableRevisions);
        expect(body(await read(pageId)), page);

        final changed = jsonDecode(jsonEncode(page)) as Map<String, dynamic>;
        (changed['blocks'] as List).single['text'] = '설명만 변경';
        final result = client!.data(
          await client!.tool('update_document', {
            'noteId': pageId,
            'target': 'body',
            'content': changed,
            'expectedRevisionId': revision(before),
            'requestId': newId(),
          }),
        );
        final after = await read(pageId);
        expect(revision(after), result['revisionId']);
        expect(body(after), changed);
        expect(
          (body(after)['blocks'] as List).single['linkedDatabaseData'],
          opaque,
        );
        await stop();
        expect(exits, [0]);
        expect(
          sha256.convert(await File(executable).readAsBytes()).toString(),
          executableHash,
        );
        expect(
          sha256.convert(await File(library).readAsBytes()).toString(),
          libraryHash,
        );
      });
    },
    skip: unavailable
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

  Map<String, dynamic> payload(Map<String, dynamic> result) =>
      Map<String, dynamic>.from(
        result['structuredContent'] as Map? ??
            jsonDecode(result['content'][0]['text'] as String) as Map,
      );

  Map<String, dynamic> data(Map<String, dynamic> result) {
    expect(result['isError'], isNot(true), reason: jsonEncode(result));
    return payload(result);
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
