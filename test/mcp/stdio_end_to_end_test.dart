import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as im;
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/mcp/vault_mcp_service.dart';
import 'package:saber/data/native/ink_vault_native.dart';
import 'package:saber/data/office/office_document_store.dart';
import 'package:saber/data/office/office_templates.dart';
import 'package:saber/data/office/windows_office_engine.dart';
import 'package:saber/data/vault/block_page_document.dart';
import 'package:saber/data/vault/block_page_media.dart';
import 'package:saber/data/vault/block_page_snapshot.dart';
import 'package:saber/data/vault/knowledge_index.dart';
import 'package:saber/data/vault/workspace_database.dart';
import 'package:saber/data/vault/workspace_markdown_templates.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/pages/workspace/mcp_panel.dart';
import 'package:saber/pages/workspace/workspace_controller.dart';

void pathChangeStdioTest() {
  final executable =
      Platform.environment['INK_VAULT_MCP_TEST_EXE'] ??
      p.absolute('build/native/windows/ink_vault_mcp.exe');
  final libraryPath =
      Platform.environment['INK_VAULT_NATIVE_LIBRARY'] ??
      p.absolute('build/native/windows/ink_vault_native.dll');
  test(
    'actual stdio move preserves link identities and completed receipts after app restart',
    () async {
      final temp = await Directory.systemTemp.createTemp('mcp-path-stdio-');
      final vault = Directory(p.join(temp.path, 'vault'));
      var controller = WorkspaceController(
        await NoteRepository.open(vault, createFormatVersion: 2),
        native: InkVaultNative.open(libraryPath: libraryPath),
      );
      McpAccessController? access;
      _StdioClient? client;
      Future<void> start() async {
        access = McpAccessController(
          () => VaultMcpService(controller, prepareMutation: controller.flush),
          executable: executable,
          supportDirectory: () async => Directory(p.join(temp.path, 'support')),
        );
        await access!.start();
        await access!.allowEdits(true);
        final config =
            (access!.clientConfiguration['mcpServers']
                    as Map)['personal-ink-vault']
                as Map;
        final process = await Process.start(
          executable,
          List<String>.from(config['args'] as List),
        );
        client = _StdioClient(process);
        expect(
          (await client!.request('initialize', {
            'protocolVersion': '2025-11-25',
            'capabilities': <String, Object?>{},
            'clientInfo': {
              'name': 'piv-path-restart-regression',
              'version': '1.0',
            },
          }))['error'],
          isNull,
        );
        process.stdin.writeln(
          jsonEncode({'jsonrpc': '2.0', 'method': 'notifications/initialized'}),
        );
      }

      Future<void> stop() async {
        await client?.close();
        client = null;
        await access?.stop();
        access?.dispose();
        access = null;
      }

      Future<Set<String>> revisions() async =>
          (await controller.repository.revisions())
              .map((r) => r.revisionId)
              .toSet();
      try {
        final course = await controller.library.createFolder('Course');
        final other = await controller.library.createFolder('Other');
        final sibling = await controller.store.create(
          'Sibling',
          folderId: course.id,
          documentKind: VaultDocumentKind.markdown,
        );
        final namesake = await controller.store.create(
          'Sibling',
          folderId: other.id,
          documentKind: VaultDocumentKind.markdown,
        );
        final target = await controller.store.create(
          'B',
          folderId: course.id,
          documentKind: VaultDocumentKind.markdown,
        );
        final reader = await controller.store.create(
          'Reader',
          documentKind: VaultDocumentKind.markdown,
        );
        await (await controller.store.open(target))
            .saveMarkdown('[relative](Sibling.md#Heading)');
        await (await controller.store.open(reader))
            .saveMarkdown('[read](Course/B.md#Topic)');
        await controller.refresh();
        await controller.openNote(reader);
        final before = await revisions();
        await start();
        final args = <String, Object?>{
          'noteId': target.id,
          'action': 'move',
          'folderId': other.id,
          'expectedRevisionId': target.revision.revisionId,
          'requestId': newId(),
        };
        final response = await client!.tool('document_action', args);
        expect(response['isError'], isNot(true));
        final result = client!.data(response);
        final after = await revisions();
        expect(after.difference(before), hasLength(3));
        expect(
          controller.markdown,
          '[read](inkvault://note/${target.id}?view=markdown#Topic)',
        );
        expect(controller.markdownDirty, isFalse);
        expect(controller.externalBusy, isFalse);
        final moved = (await controller.store.list()).singleWhere(
          (n) => n.id == target.id,
        );
        expect(moved.folderId, other.id);
        expect(
          await (await controller.store.open(moved)).readMarkdown(),
          '[relative](inkvault://note/${sibling.id}?view=markdown#Heading)',
        );
        expect(
          client!.data(await client!.tool('document_action', args)),
          result,
        );
        expect(await revisions(), after);

        await stop();
        await controller.flush();
        controller.dispose();
        await controller.repository.close();
        controller = WorkspaceController(
          await NoteRepository.open(vault),
          native: InkVaultNative.open(libraryPath: libraryPath),
        );
        await start();
        expect(
          client!.data(await client!.tool('document_action', args)),
          result,
        );
        expect(await revisions(), after);
        await controller.store.create(
          'B',
          folderId: course.id,
          documentKind: VaultDocumentKind.markdown,
        );
        final index = await KnowledgeIndex.build(
          controller.repository,
          controller.native!,
        );
        expect(index.backlinks(target.id).map((n) => n.id), [reader.id]);
        expect(index.backlinks(sibling.id).map((n) => n.id), [target.id]);
        expect(index.backlinks(namesake.id), isEmpty);
        final later = await revisions();
        expect(
          client!.data(await client!.tool('document_action', args)),
          result,
        );
        expect(await revisions(), later);
        expect(
          (await client!.tool('document_action', {
            ...args,
            'requestId': newId(),
          }))['isError'],
          true,
        );
        expect(await revisions(), later);
      } finally {
        await stop();
        await controller.flush();
        controller.dispose();
        await controller.repository.close();
        final actual = await temp.resolveSymbolicLinks();
        final parent = await Directory.systemTemp.resolveSymbolicLinks();
        expect(
          actual,
          startsWith('$parent${Platform.pathSeparator}mcp-path-stdio-'),
        );
        await Directory(actual).delete(recursive: true);
      }
    },
    skip: !File(executable).existsSync() || !File(libraryPath).existsSync()
        ? 'Build the actual MCP executable and common engine first'
        : false,
  );
}

class _StdioClient {
  new(this.process) {
    subscription = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          final message = Map<String, dynamic>.from(jsonDecode(line) as Map);
          final id = message['id'];
          if (id is int) pending.remove(id)?.complete(message);
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
    Map<String, Object?> params, {
    Duration timeout = const Duration(seconds: 15),
  }) {
    final id = ++sequence;
    final response = Completer<Map<String, dynamic>>();
    pending[id] = response;
    process.stdin.writeln(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': params,
      }),
    );
    return response.future.timeout(timeout);
  }

  Future<Map<String, dynamic>> tool(
    String name,
    Map<String, Object?> args, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final response = await request('tools/call', {
      'name': name,
      'arguments': args,
    }, timeout: timeout);
    expect(response['error'], isNull);
    return Map<String, dynamic>.from(response['result'] as Map);
  }

  Map<String, dynamic> data(Map<String, dynamic> result) =>
      Map<String, dynamic>.from(
        result['structuredContent'] as Map? ??
            jsonDecode((result['content'] as List).first['text'] as String)
                as Map,
      );
  Future<void> close() async {
    await process.stdin.close();
    try {
      await process.exitCode.timeout(const Duration(seconds: 3));
    } on TimeoutException {
      process.kill();
      await process.exitCode;
    }
    await subscription.cancel();
    await errors;
  }
}

void dailyNoteStdioTest() {
  final executable =
      Platform.environment['INK_VAULT_MCP_TEST_EXE'] ??
      p.absolute('build/native/windows/ink_vault_mcp.exe');
  test(
    'actual stdio finds and edits a daily note by date across restart',
    () async {
      const date = '2024-02-29';
      final temp = await Directory.systemTemp.createTemp('mcp-daily-stdio-');
      final vault = Directory(p.join(temp.path, 'vault'));
      var controller = WorkspaceController(
        await NoteRepository.open(vault, createFormatVersion: 2),
      );
      McpAccessController? access;
      _StdioClient? client;
      Future<_StdioClient> start() async {
        final connection = McpAccessController(
          () => VaultMcpService(controller, prepareMutation: controller.flush),
          executable: executable,
          supportDirectory: () async => Directory(p.join(temp.path, 'support')),
        );
        access = connection;
        await connection.start();
        final config = (connection.clientConfiguration['mcpServers']
                as Map)['personal-ink-vault']
            as Map;
        final process = await Process.start(
          executable,
          List<String>.from(config['args'] as List),
        );
        final stdio = client = _StdioClient(process);
        expect(
          (await stdio.request('initialize', {
            'protocolVersion': '2025-11-25',
            'capabilities': <String, Object?>{},
            'clientInfo': {'name': 'piv-daily-note-stdio', 'version': '1.0'},
          }))['error'],
          isNull,
        );
        process.stdin.writeln(
          jsonEncode({'jsonrpc': '2.0', 'method': 'notifications/initialized'}),
        );
        return stdio;
      }

      Future<void> stop() async {
        try {
          await client?.close();
        } finally {
          client = null;
          await access?.stop();
          access?.dispose();
          access = null;
        }
      }

      Future<Set<String>> revisions() async =>
          (await controller.repository.revisions())
              .map((revision) => revision.revisionId)
              .toSet();
      try {
        final namesake = await controller.store.createMarkdown(
          date,
          Uint8List.fromList(utf8.encode('일반 노트')),
        );
        final folder = await controller.library.createFolder('일지 양식');
        await controller.store.createMarkdown(
          '기본 일지',
          Uint8List.fromList(utf8.encode('# {{title}}\n기록')),
          folderId: folder.id,
        );
        final templates = WorkspaceMarkdownTemplateStore(controller.repository);
        await templates.saveDailyNoteTemplateSettings(
          await templates.dailyNoteTemplateSettings(),
          choice: (await templates.templates(folder.id)).single,
        );
        await controller.openNote(namesake);
        final before = await revisions();
        final first = await start();
        final tools =
            (await first.request('tools/list', {}))['result']['tools'] as List;
        expect(
          tools.map((tool) => tool['name']),
          containsAll(['read_daily_note', 'ensure_daily_note']),
        );
        final read = {'date': date};
        final ensure = {'date': date, 'requestId': newId()};
        expect(
          first.data(await first.tool('read_daily_note', read))['code'],
          'not_found',
        );
        expect(
          first.data(await first.tool('ensure_daily_note', ensure))['code'],
          'read_only',
        );
        expect(await revisions(), before);

        await access!.allowEdits(true);
        final created = first.data(await first.tool('ensure_daily_note', ensure));
        expect(created['date'], date);
        final id = created['noteId'] as String;
        expect(id, isNot(namesake.id));
        expect(controller.activeSession?.note.id, namesake.id);
        final seeded = first.data(await first.tool('read_daily_note', read));
        expect(seeded['noteId'], id);
        expect(seeded['markdown']['content'], '# $date\n기록');
        final edit = await first.tool('update_document', {
          'noteId': id,
          'target': 'markdown',
          'content': '저장한 일지',
          'expectedRevisionId': seeded['markdown']['revisionId'],
          'requestId': newId(),
        });
        expect(edit['isError'], isNot(true));
        final daily = (await controller.store.list()).singleWhere(
          (note) => note.id == id,
        );
        await controller.store.rename(daily, '연구 일지');
        final written = await revisions();

        await stop();
        await controller.flush();
        controller.dispose();
        await controller.repository.close();
        controller = WorkspaceController(await NoteRepository.open(vault));
        final reopened = await start();
        final loaded = reopened.data(await reopened.tool('read_daily_note', read));
        expect(loaded['noteId'], id);
        expect(loaded['title'], '연구 일지');
        expect(loaded['markdown']['content'], '저장한 일지');
        await access!.allowEdits(true);
        expect(
          reopened.data(await reopened.tool('ensure_daily_note', ensure)),
          created,
        );
        expect(await revisions(), written);
      } finally {
        await stop();
        controller.dispose();
        await controller.repository.close();
        final actual = await temp.resolveSymbolicLinks();
        final parent = await Directory.systemTemp.resolveSymbolicLinks();
        expect(p.dirname(actual), parent);
        expect(p.basename(actual), startsWith('mcp-daily-stdio-'));
        await Directory(actual).delete(recursive: true);
      }
    },
    skip: !File(executable).existsSync()
        ? 'Build the actual MCP executable first'
        : false,
  );
}

void pageMediaStdioTest() {
  final executable =
      Platform.environment['INK_VAULT_MCP_TEST_EXE'] ??
      p.absolute('build/native/windows/ink_vault_mcp.exe');
  test(
    'actual stdio page media reads images and edits captions without losing files',
    () async {
      final temp = await Directory.systemTemp.createTemp('mcp-media-stdio-');
      final controller = WorkspaceController(
        await NoteRepository.open(
          Directory('${temp.path}/vault'),
          createFormatVersion: 2,
        ),
        directoryProvider: () async => temp,
      );
      final access = McpAccessController(
        () => VaultMcpService(controller, prepareMutation: controller.flush),
        executable: executable,
        supportDirectory: () async => Directory('${temp.path}/support'),
      );
      _StdioClient? client;
      try {
        final note = await controller.store.create(
          '미디어 페이지',
          documentKind: VaultDocumentKind.page,
        );
        final image = BlockPageMediaAsset.image(
          name: '사진 한글😀.png',
          bytes: im.encodePng(im.Image(width: 7, height: 5)),
        );
        final attachment = BlockPageMediaAsset.attachment(
          name: '../강의.pptx',
          bytes: utf8.encode('원본 한글😀'),
        );
        final picture = BlockPageBlock.create(type: 'image', text: '사진 설명');
        final file = BlockPageBlock.create(type: 'attachment', text: '자료 설명');
        final page = const BlockPageDocument.empty().copyWith(
          blocks: [picture, file],
          media: {picture.id: image.reference, file.id: attachment.reference},
        );
        final session = await controller.store.open(note);
        await session.saveInk(
          BlockPageMediaSnapshot.prepare(
            page,
            existingFiles: {
              'page.json': Uint8List.fromList(
                utf8.encode(
                  jsonEncode(const BlockPageDocument.empty().toJson()),
                ),
              ),
              'future/opaque.bin': Uint8List.fromList([0, 255, 42]),
            },
            addedFiles: {
              image.reference.path: image.bytes,
              attachment.reference.path: attachment.bytes,
            },
          ).files,
        );
        await session.saveMarkdown('별도 Markdown 보존');
        final original = (await controller.repository.heads(note.inkEntityId))
            .single;
        final originalFiles = await controller.repository.readFiles(original);
        await access.start();
        final config =
            (access.clientConfiguration['mcpServers']
                    as Map)['personal-ink-vault']
                as Map;
        final process = await Process.start(
          executable,
          List<String>.from(config['args'] as List),
        );
        client = _StdioClient(process);
        expect(
          (await client.request('initialize', {
            'protocolVersion': '2025-11-25',
            'capabilities': <String, Object?>{},
            'clientInfo': {'name': 'page-media-acceptance', 'version': '1.0'},
          }))['error'],
          isNull,
        );
        process.stdin.writeln(
          jsonEncode({'jsonrpc': '2.0', 'method': 'notifications/initialized'}),
        );
        final tools =
            (await client.request('tools/list', {}))['result']['tools'] as List;
        expect(tools.map((tool) => tool['name']), contains('read_page_media'));
        Map<String, Object?> selector(String blockId, [String? revisionId]) => {
          'noteId': note.id,
          'revisionId': revisionId ?? original.revisionId,
          'blockId': blockId,
        };
        final metadata = client.data(
          await client.tool('read_page_media', selector(picture.id)),
        );
        expect(metadata['media'], image.reference.toJson());
        expect(metadata.containsKey('dataBase64'), isFalse);
        final preview = await client.tool('read_page_media', {
          ...selector(picture.id),
          'mode': 'preview',
          'maxDimension': 64,
        });
        expect(preview['isError'], isNot(true));
        final content =
            (preview['content'] as List)
                    .where((entry) => entry['type'] == 'image')
                    .single
                as Map;
        expect(content['mimeType'], 'image/png');
        final decoded = im.decodePng(base64Decode(content['data'] as String))!;
        expect((decoded.width, decoded.height), (7, 5));
        expect(
          (preview['structuredContent'] as Map).containsKey('image'),
          isFalse,
        );
        final received = BytesBuilder();
        var offset = 0;
        while (true) {
          final chunk = client.data(
            await client.tool('read_page_media', {
              ...selector(file.id),
              'mode': 'bytes',
              'offset': offset,
              'limit': 5,
            }),
          );
          expect(chunk['offset'], offset);
          final bytes = base64Decode(chunk['dataBase64'] as String);
          expect(bytes.length, lessThanOrEqualTo(5));
          received.add(bytes);
          if (chunk['eof'] == true) break;
          expect(chunk['nextOffset'], offset + bytes.length);
          offset = chunk['nextOffset'] as int;
        }
        expect(received.takeBytes(), attachment.bytes);
        final edited = page.copyWith(
          blocks: [
            picture.copyWith(text: 'AI가 수정한 설명😀'),
            file,
          ],
        );
        final args = <String, Object?>{
          'noteId': note.id,
          'target': 'body',
          'content': edited.toJson(),
          'expectedRevisionId': original.revisionId,
          'requestId': newId(),
        };
        expect((await client.tool('update_document', args))['isError'], isTrue);
        expect(
          (await controller.repository.heads(note.inkEntityId))
              .single
              .revisionId,
          original.revisionId,
        );
        await access.allowEdits(true);
        final updated = await client.tool('update_document', args);
        expect(updated['isError'], isNot(true));
        final updatedData = client.data(updated);
        final saved = (await controller.repository.heads(note.inkEntityId))
            .single;
        expect(saved.revisionId, updatedData['revisionId']);
        expect(saved.revisionId, isNot(original.revisionId));
        final files = await controller.repository.readFiles(saved);
        expect(
          BlockPageMediaSnapshot.fromFiles(files).document.toJson(),
          edited.toJson(),
        );
        for (final name in originalFiles.keys.where(
          (name) => name != 'page.json',
        )) {
          expect(files[name], originalFiles[name], reason: name);
        }
        expect(await controller.repository.readFiles(original), originalFiles);
        expect(
          await (await controller.store.open(note)).readMarkdown(),
          '별도 Markdown 보존',
        );
        expect(
          client.data(await client.tool('update_document', args)),
          updatedData,
        );
        expect(
          (await controller.repository.heads(note.inkEntityId))
              .single
              .revisionId,
          saved.revisionId,
        );
        expect(
          client.data(
            await client.tool(
              'read_page_media',
              selector(picture.id, saved.revisionId),
            ),
          )['media'],
          image.reference.toJson(),
        );
        await access.allowEdits(false);
        expect(
          (await client.tool(
            'read_page_media',
            selector(picture.id),
          ))['isError'],
          isNot(true),
        );
        await client.close();
        expect(await process.exitCode, 0);
        client = null;
      } finally {
        await client?.close();
        await access.stop();
        access.dispose();
        controller.dispose();
        await controller.repository.close();
        final actual = await temp.resolveSymbolicLinks();
        final parent = await Directory.systemTemp.resolveSymbolicLinks();
        expect(
          actual,
          startsWith('$parent${Platform.pathSeparator}mcp-media-stdio-'),
        );
        await Directory(actual).delete(recursive: true);
      }
    },
    skip: !File(executable).existsSync()
        ? 'Build the actual MCP executable first'
        : false,
  );
}

void main() {
  dailyNoteStdioTest();
  pageMediaStdioTest();
  pathChangeStdioTest();
  pageHistoryStdioTest();
  nativeWordOwnersStdioTest();
  wordStructureStdioTest();
  slideDesignStdioTest();
  TestWidgetsFlutterBinding.ensureInitialized();
  final executable =
      Platform.environment['INK_VAULT_MCP_TEST_EXE'] ??
      p.absolute('build/native/windows/ink_vault_mcp.exe');
  final libraryPath =
      Platform.environment['INK_VAULT_NATIVE_LIBRARY'] ??
      p.absolute('build/native/windows/ink_vault_native.dll');
  test(
    'actual stdio database actions reach Rust and retain one atomic history after retry and reopen',
    () async {
      final temp = await Directory.systemTemp.createTemp('mcp-actions-real-');
      final controller = WorkspaceController(
        await NoteRepository.open(
          Directory('${temp.path}/vault'),
          createFormatVersion: 2,
        ),
        native: InkVaultNative.open(libraryPath: libraryPath),
      );
      final access = McpAccessController(
        () => VaultMcpService(controller, prepareMutation: controller.flush),
        executable: executable,
        supportDirectory: () async => Directory('${temp.path}/support'),
      );
      _StdioClient? client;
      try {
        await access.start();
        await access.allowEdits(true);
        final config =
            (access.clientConfiguration['mcpServers']
                    as Map)['personal-ink-vault']
                as Map;
        final process = await Process.start(
          executable,
          List<String>.from(config['args'] as List),
        );
        client = _StdioClient(process);
        final initialized = await client.request('initialize', {
          'protocolVersion': '2025-11-25',
          'capabilities': <String, Object?>{},
          'clientInfo': {
            'name': 'piv-database-action-regression',
            'version': '1.0',
          },
        });
        expect(initialized['error'], isNull);
        process.stdin.writeln(
          jsonEncode({'jsonrpc': '2.0', 'method': 'notifications/initialized'}),
        );
        final tools = await client.request('tools/list', {});
        expect(
          (tools['result']['tools'] as List).map((tool) => tool['name']),
          contains('database_action'),
        );
        final checked = DatabaseProperty.create(name: '완료', type: 'checkbox');
        final computed = DatabaseProperty.create(
          name: '계산',
          type: 'formula',
          config: {'expression': '2 * 3'},
        );
        final database = WorkspaceDatabase.empty()
            .addProperty(checked)
            .addProperty(computed);
        final title = database.properties.first.id;
        final created = client.data(
          await client.tool('create_document', {
            'kind': 'database',
            'title': 'AI 버튼 수용시험',
            'body': {
              ...database.toJson(),
              'futureField': {'retained': true},
            },
            'requestId': newId(),
          }),
        );
        final noteId = created['noteId'] as String;
        var revision = created['bodyRevisionId'] as String;
        final buttonId = newId();
        for (final rule in <Map<String, Object?>>[
          {
            'id': buttonId,
            'name': '행 추가 버튼',
            'enabled': true,
            'trigger': {'type': 'manual'},
            'actions': [
              {
                'id': newId(),
                'type': 'addRow',
                'values': {title: '버튼 행', checked.id: false},
              },
            ],
          },
          {
            'id': newId(),
            'name': '제목 확정 시 완료',
            'enabled': true,
            'trigger': {'type': 'propertyChanged', 'propertyId': title},
            'actions': [
              {
                'id': newId(),
                'type': 'setProperty',
                'propertyId': checked.id,
                'value': true,
              },
            ],
          },
          {
            'id': newId(),
            'name': '직접 추가한 행 완료',
            'enabled': true,
            'trigger': {'type': 'rowAdded'},
            'actions': [
              {
                'id': newId(),
                'type': 'setProperty',
                'propertyId': checked.id,
                'value': true,
              },
            ],
          },
        ]) {
          final added = await client.tool('database_action', {
            'noteId': noteId,
            'action': 'put_rule',
            'rule': rule,
            'expectedRevisionId': revision,
            'requestId': newId(),
          });
          expect(added['isError'], isNot(true));
          revision = client.data(added)['revisionId'] as String;
        }
        final buttonRequest = <String, Object?>{
          'noteId': noteId,
          'action': 'run_button',
          'ruleId': buttonId,
          'expectedRevisionId': revision,
          'requestId': newId(),
        };
        final first = client.data(
          await client.tool('database_action', buttonRequest),
        );
        expect(first['receipts'], hasLength(1));
        expect(
          client.data(await client.tool('database_action', buttonRequest)),
          first,
        );
        final read = client.data(
          await client.tool('read_document', {'noteId': noteId}),
        );
        final body = Map<String, dynamic>.from(read['body']['content'] as Map);
        final rowId = (body['rows'] as List).single['id'] as String;
        expect((body['rows'] as List).single['values'][checked.id], false);
        final changed = client.data(
          await client.tool('database_action', {
            'noteId': noteId,
            'action': 'set_cell',
            'rowId': rowId,
            'propertyId': title,
            'value': '수정한 행',
            'expectedRevisionId': first['revisionId'],
            'requestId': newId(),
          }),
        );
        expect(changed['receipts'], hasLength(1));
        final added = client.data(
          await client.tool('database_action', {
            'noteId': noteId,
            'action': 'add_row',
            'values': {title: '직접 추가', checked.id: false},
            'expectedRevisionId': changed['revisionId'],
            'requestId': newId(),
          }),
        );
        expect(added['receipts'], hasLength(1));
        expect(added['rowId'], isNot(rowId));
        final beforeDenied = (await controller.repository.revisions()).length;
        expect(
          (await client.tool('database_action', {
            ...buttonRequest,
            'requestId': newId(),
          }))['isError'],
          true,
        );
        await access.allowEdits(false);
        final query = await client.tool('database_query', {
          'noteId': noteId,
          'expectedRevisionId': added['revisionId'],
          'capturedAtUtc': '2026-10-30T12:00:00.000Z',
          'operations': [
            {'type': 'value', 'rowId': rowId, 'propertyId': computed.id},
            {
              'type': 'aggregate',
              'propertyId': title,
              'calculation': 'countAll',
            },
          ],
        });
        expect(query['isError'], isNot(true));
        expect(client.data(query)['results'], [
          {'value': 6},
          {'value': 2},
        ]);
        expect(client.data(query)['revisionId'], added['revisionId']);
        final staleQuery = await client.tool('database_query', {
          'noteId': noteId,
          'expectedRevisionId': first['revisionId'],
          'operations': [
            {'type': 'value', 'rowId': rowId, 'propertyId': computed.id},
          ],
        });
        expect(staleQuery['isError'], true);
        expect(client.data(staleQuery)['code'], 'revision_conflict');
        expect(
          (await client.tool('database_action', {
            ...buttonRequest,
            'expectedRevisionId': added['revisionId'],
            'requestId': newId(),
          }))['isError'],
          true,
        );
        expect((await controller.repository.revisions()).length, beforeDenied);
        final reopened = await NoteRepository.open(controller.repository.root);
        try {
          final heads = await reopened.heads(
            (await controller.store.list()).single.inkEntityId,
          );
          expect(heads.single.revisionId, added['revisionId']);
          final files = await reopened.readFiles(heads.single);
          final restored = WorkspaceDatabase.fromJson(
            Map<String, dynamic>.from(
              jsonDecode(utf8.decode(files['database.json']!)) as Map,
            ),
          );
          expect(restored.rows, hasLength(2));
          expect(
            restored.rows.every((row) => row.values[checked.id] == true),
            true,
          );
          expect(restored.toJson()['automationExecutions'], hasLength(3));
          expect(restored.toJson()['futureField'], {'retained': true});
        } finally {
          await reopened.close();
        }
      } finally {
        await client?.close();
        await access.stop();
        access.dispose();
        await controller.flush();
        controller.dispose();
        await controller.repository.close();
        await temp.delete(recursive: true);
      }
    },
    skip:
        !Platform.isWindows ||
            !File(executable).existsSync() ||
            !File(libraryPath).existsSync()
        ? 'Build the actual Windows MCP executable and native library first'
        : false,
  );
  test(
    'actual stdio PPT object edits reach the app once and preserve previous originals',
    () async {
      final temp = await Directory.systemTemp.createTemp('mcp-ppt-real-app-');
      final controller = WorkspaceController(
        await NoteRepository.open(
          Directory('${temp.path}/vault'),
          createFormatVersion: 2,
        ),
      );
      final original = OfficeTemplates.create(
        OfficeTemplateKind.presentation,
        title: 'Before',
      ).bytes;
      final edited = OfficeTemplates.create(
        OfficeTemplateKind.presentation,
        title: 'After',
      ).bytes;
      final pdf = Uint8List.fromList(
        utf8.encode('%PDF-1.7\ncontract fixture\n%%EOF\n'),
      );
      final originalHash = sha256.convert(original).toString();
      final editedHash = sha256.convert(edited).toString();
      final imageId = newId();
      final image = im.encodePng(im.Image(width: 3, height: 2));
      var editCount = 0;
      Map<String, dynamic> snapshot(String hash) => {
        'kind': 'presentation',
        'sourceSha256': hash,
        'paragraphs': [],
        'tables': [],
        'slides': [
          {
            'id': 'slide-0',
            'width': 280,
            'height': 157.5,
            'backgroundStyle': 'solid',
            'backgroundColor': 0xf0e0d0,
            'shapes': [
              {
                'id': 'slide-0/shape-0',
                'type': 'CustomShape',
                'shapeKind': 'rectangle',
                'text': hash == originalHash ? 'Before' : 'After',
                'editableText': true,
                'x': 10,
                'y': 20,
                'width': 60,
                'height': 30,
                'canEditFill': true,
                'canEditLine': true,
                'fillStyle': 'solid',
                'fillColor': 0x112233,
                'lineStyle': 'none',
                'lineColor': 0,
                'lineWidth': .5,
              },
            ],
          },
        ],
      };
      final operations = [
        {
          'op': 'shapeAdd',
          'id': 'llm-rectangle',
          'slideId': 'slide-0',
          'shapeKind': 'rectangle',
          'x': 10.0,
          'y': 20.0,
          'width': 60.0,
          'height': 30.0,
          'text': 'After',
        },
        {
          'op': 'shapeAppearance',
          'id': 'llm-rectangle',
          'fillStyle': 'solid',
          'fillColor': 0x112233,
          'lineStyle': 'none',
        },
        {'op': 'shapeDelete', 'id': 'slide-0/shape-0'},
        {
          'op': 'slideBackground',
          'id': 'slide-0',
          'fillStyle': 'solid',
          'fillColor': 0xf0e0d0,
        },
        {
          'op': 'textStyle',
          'targetKind': 'shape',
          'id': 'llm-rectangle',
          'startUtf16': 1,
          'endUtf16': 3,
          'expectedTextSha256': sha256.convert(utf8.encode('After')).toString(),
          'italic': true,
          'underline': true,
        },
        {
          'op': 'imageAdd',
          'id': 'llm-photo',
          'slideId': 'slide-0',
          'assetId': imageId,
          'x': 5.0,
          'y': 6.0,
          'width': 30.0,
          'height': 20.0,
        },
      ];
      final engine = WindowsOfficeEngine(
        runner: (request) async {
          final hash = sha256
              .convert(
                await File(request['sourcePath'] as String).readAsBytes(),
              )
              .toString();
          if (request['mode'] == 'inspect') return {'snapshot': snapshot(hash)};
          expect(request['expectedSourceSha256'], originalHash);
          expect(request['operations'], operations);
          expect(
            (request['imageAssets'] as List).single['sha256'],
            sha256.convert(image).toString(),
          );
          editCount++;
          return {
            'status': 'saved',
            'sessionId': request['sessionId'],
            'sourcePath': (await File(
              '${temp.path}/edited.pptx',
            ).writeAsBytes(edited)).path,
            'pdfPath': (await File(
              '${temp.path}/preview.pdf',
            ).writeAsBytes(pdf)).path,
            'sourceSha256': editedHash,
            'pdfSha256': sha256.convert(pdf).toString(),
            'pdfPageCount': 1,
            'engineVersion': 'synthetic-engine-real-stdio',
            'snapshot': snapshot(editedHash),
          };
        },
      );
      final access = McpAccessController(
        () => VaultMcpService(
          controller,
          officeEngine: engine,
          prepareMutation: controller.flush,
        ),
        executable: executable,
        supportDirectory: () async => Directory('${temp.path}/support'),
      );
      _StdioClient? client;
      try {
        final store = OfficeDocumentStore(controller.repository);
        final note = await store.importDocument(
          title: 'External LLM',
          fileName: 'source.pptx',
          bytes: original,
        );
        final first = await store.readLatest(note);
        await access.start();
        await access.allowEdits(true);
        final config =
            (access.clientConfiguration['mcpServers']
                    as Map)['personal-ink-vault']
                as Map;
        final process = await Process.start(
          executable,
          List<String>.from(config['args'] as List),
        );
        client = _StdioClient(process);
        expect(
          (await client.request('initialize', {
            'protocolVersion': '2025-11-25',
            'capabilities': <String, Object?>{},
            'clientInfo': {'name': 'piv-ppt-protocol-client', 'version': '1.0'},
          }))['error'],
          isNull,
        );
        process.stdin.writeln(
          jsonEncode({'jsonrpc': '2.0', 'method': 'notifications/initialized'}),
        );
        final read = client.data(
          await client.tool('read_document', {'noteId': note.id}),
        );
        expect(
          read['office']['slides'].single['shapes'].single['fillColor'],
          0x112233,
        );
        final args = {
          'noteId': note.id,
          'expectedRevisionId': read['office']['sourceRevisionId'],
          'requestId': newId(),
          'operations': operations,
        };
        Future<Map<String, dynamic>> upload(
          String action,
          Map<String, Object?> fields,
        ) async => client!.data(
          await client.tool('office_asset', {
            'action': action,
            'noteId': note.id,
            'expectedRevisionId': read['office']['sourceRevisionId'],
            'requestId': action == 'begin' ? imageId : newId(),
            if (action != 'begin') 'assetId': imageId,
            ...fields,
          }),
        );
        expect(
          (await upload('begin', {
            'mimeType': 'image/png',
            'byteLength': image.length,
            'sha256': sha256.convert(image).toString(),
          }))['assetId'],
          imageId,
        );
        final chunk = {'offset': 0, 'base64Data': base64Encode(image)};
        final uploaded = await upload('append', chunk);
        expect(await upload('append', chunk), uploaded);
        expect((await upload('seal', {}))['state'], 'sealed');
        expect((await upload('status', {}))['receivedBytes'], image.length);
        final saved = client.data(await client.tool('office_edit', args));
        expect(client.data(await client.tool('office_edit', args)), saved);
        expect(editCount, 1);
        final latest = await store.readLatest(note);
        expect(latest.originalBytes, edited);
        expect(latest.pdfBytes, pdf);
        expect(
          (await store.readLatest(
            note,
            revisionId: first.revision.revisionId,
          )).originalBytes,
          original,
        );
        final reread = client.data(
          await client.tool('read_document', {'noteId': note.id}),
        );
        expect(
          reread['office']['slides'].single['shapes'].single['text'],
          'After',
        );
        expect(
          (await client.tool('office_edit', {
            ...args,
            'requestId': newId(),
          }))['isError'],
          true,
        );
        await access.allowEdits(false);
        expect(
          (await client.tool('office_edit', {
            ...args,
            'expectedRevisionId': latest.revision.revisionId,
            'requestId': newId(),
          }))['isError'],
          true,
        );
        expect(editCount, 1);
      } finally {
        await client?.close();
        await access.stop();
        access.dispose();
        await controller.flush();
        controller.dispose();
        await controller.repository.close();
        await temp.delete(recursive: true);
      }
    },
    skip: !File(executable).existsSync()
        ? 'Build the actual MCP executable first'
        : false,
  );

  test(
    'actual stdio executable reaches the app writer and preserves versions across read update stale and read-only calls',
    () async {
      final temp = await Directory.systemTemp.createTemp('mcp-real-app-');
      final controller = WorkspaceController(
        await NoteRepository.open(
          Directory('${temp.path}/vault'),
          createFormatVersion: 2,
        ),
      );
      final access = McpAccessController(
        () => VaultMcpService(controller, prepareMutation: controller.flush),
        executable: executable,
        supportDirectory: () async => Directory('${temp.path}/support'),
      );
      _StdioClient? client;
      try {
        await access.start();
        await access.allowEdits(true);
        final config =
            ((access.clientConfiguration['mcpServers']
                    as Map)['personal-ink-vault']
                as Map);
        final process = await Process.start(
          executable,
          List<String>.from(config['args'] as List),
        );
        client = _StdioClient(process);
        final initialized = await client.request('initialize', {
          'protocolVersion': '2025-11-25',
          'capabilities': <String, Object?>{},
          'clientInfo': {'name': 'piv-actual-app-regression', 'version': '1.0'},
        });
        expect(initialized['error'], isNull);
        process.stdin.writeln(
          jsonEncode({'jsonrpc': '2.0', 'method': 'notifications/initialized'}),
        );
        final tools = await client.request('tools/list', {});
        expect(
          (tools['result']['tools'] as List).map((tool) => tool['name']),
          contains('update_document'),
        );
        final created = client.data(
          await client.tool('create_document', {
            'kind': 'markdown',
            'title': 'MCP actual app',
            'body': 'First version',
            'requestId': newId(),
          }),
        );
        final id = created['noteId'] as String;
        final read = client.data(
          await client.tool('read_document', {'noteId': id}),
        );
        expect(read['markdown']['content'], 'First version');
        final revision = read['markdown']['revisionId'] as String;
        final updated = await client.tool('update_document', {
          'noteId': id,
          'target': 'markdown',
          'content': 'Second version',
          'expectedRevisionId': revision,
          'requestId': newId(),
        });
        expect(updated['isError'], isNot(true));
        final stale = await client.tool('update_document', {
          'noteId': id,
          'target': 'markdown',
          'content': 'Must not replace',
          'expectedRevisionId': revision,
          'requestId': newId(),
        });
        expect(stale['isError'], true);
        final note = (await controller.store.list()).single;
        expect(
          await (await controller.store.open(note)).readMarkdown(),
          'Second version',
        );
        expect(
          (await controller.repository.revisions())
              .where((r) => r.entityId == note.markdownEntityId)
              .length,
          3,
        );
        for (final (kind, extension) in [
          ('word', '.docx'),
          ('presentation', '.pptx'),
          ('hwpx', '.hwpx'),
        ]) {
          final createdOffice = client.data(
            await client.tool('create_document', {
              'kind': kind,
              'title': 'Actual $kind',
              'requestId': newId(),
            }),
          );
          final officeNote = (await controller.store.list()).singleWhere(
            (note) => note.id == createdOffice['noteId'],
          );
          final edition = await OfficeDocumentStore(controller.repository)
              .readLatest(officeNote);
          expect(edition.originalFileName, endsWith(extension));
          expect(
            createdOffice['sourceRevisionId'],
            edition.revision.revisionId,
          );
        }
        await access.allowEdits(false);
        expect(
          (await client.tool('create_document', {
            'kind': 'markdown',
            'title': 'Denied',
            'requestId': newId(),
          }))['isError'],
          true,
        );
        expect((await controller.store.list()).length, 4);
      } finally {
        await client?.close();
        await access.stop();
        access.dispose();
        await controller.flush();
        controller.dispose();
        await controller.repository.close();
        await temp.delete(recursive: true);
      }
    },
    skip: !File(executable).existsSync()
        ? 'Build the actual MCP executable first'
        : false,
  );
}

void pageHistoryStdioTest() {
  final executable =
      Platform.environment['INK_VAULT_MCP_TEST_EXE'] ??
      p.absolute('build/native/windows/ink_vault_mcp.exe');
  test(
    'actual stdio page history compares read-only and restores an exact full revision',
    () async {
      final temp = await Directory.systemTemp.createTemp('mcp-page-stdio-');
      final repo = await NoteRepository.open(
        Directory('${temp.path}/vault'),
        createFormatVersion: 2,
      );
      final controller = WorkspaceController(
        repo,
        directoryProvider: () async => temp,
      );
      final access = McpAccessController(
        () => VaultMcpService(controller, prepareMutation: controller.flush),
        executable: executable,
        supportDirectory: () async => Directory('${temp.path}/support'),
      );
      _StdioClient? client;
      try {
        final folder = await controller.library.createFolder('Research');
        final note = await controller.store.create(
          'History',
          documentKind: VaultDocumentKind.page,
          folderId: folder.id,
        );
        final block = newId();
        Map<String, Object?> body(String text) => {
          'version': 1,
          'futurePage': true,
          'blocks': [
            {
              'id': block,
              'type': 'paragraph',
              'text': text,
              'future': {'kept': 1},
            },
          ],
        };
        final oldFiles = {
          'page.json': Uint8List.fromList(
            utf8.encode(jsonEncode(body('Before'))),
          ),
          'assets/source.bin': Uint8List.fromList([0, 255, 42]),
        };
        final old = await repo.commit(
          entityId: note.inkEntityId,
          kind: EntityKind.ink,
          ownerNoteId: note.id,
          files: oldFiles,
          parentRevisionIds: [],
          baseRefs: {
            newId(): [newId()],
          },
        );
        final session = await controller.store.open(note);
        await session.saveInk({
          'page.json': Uint8List.fromList(
            utf8.encode(jsonEncode(body('After'))),
          ),
        });
        final current = session.inkParents.single;
        await session.saveMarkdown('Separate summary');
        await access.start();
        final config =
            (access.clientConfiguration['mcpServers']
                    as Map)['personal-ink-vault']
                as Map;
        final process = await Process.start(
          executable,
          List<String>.from(config['args'] as List),
        );
        client = _StdioClient(process);
        expect(
          (await client.request('initialize', {
            'protocolVersion': '2025-11-25',
            'capabilities': <String, Object?>{},
            'clientInfo': {'name': 'page-history-acceptance', 'version': '1.0'},
          }))['error'],
          isNull,
        );
        process.stdin.writeln(
          jsonEncode({'jsonrpc': '2.0', 'method': 'notifications/initialized'}),
        );
        final tools =
            (await client.request('tools/list', {}))['result']['tools'] as List;
        expect(
          tools.map((tool) => tool['name']),
          containsAll([
            'list_revisions',
            'compare_page_revision',
            'restore_page_revision',
          ]),
        );
        final legacy = client.data(
          await client.tool('list_revisions', {'noteId': note.id}),
        );
        expect(
          legacy.keys,
          unorderedEquals(['noteId', 'revisions', 'total', 'truncated']),
        );
        final history = client.data(
          await client.tool('list_revisions', {
            'noteId': note.id,
            'target': 'body',
            'limit': 1,
          }),
        );
        expect(history['total'], 2);
        expect(history['revisions'], hasLength(1));
        final compared = client.data(
          await client.tool('compare_page_revision', {
            'noteId': note.id,
            'revisionId': old.revisionId,
            'expectedRevisionId': current,
          }),
        );
        expect(compared['totalChanges'], 1);
        expect(compared['changes'][0]['before']['text'], 'Before');
        expect(compared['expectedHeads'][folder.id], [
          folder.revision.revisionId,
        ]);
        final args = <String, Object?>{
          'noteId': note.id,
          'revisionId': old.revisionId,
          'expectedRevisionId': current,
          'expectedHeads': compared['expectedHeads'],
          'requestId': newId(),
        };
        final denied = await client.tool('restore_page_revision', args);
        expect(denied['isError'], true);
        expect(client.data(denied)['code'], 'read_only');
        await access.allowEdits(true);
        final restored = client.data(
          await client.tool('restore_page_revision', args),
        );
        expect(restored['restoredFromRevisionId'], old.revisionId);
        expect(
          client.data(await client.tool('restore_page_revision', args)),
          restored,
        );
        final head = (await repo.heads(note.inkEntityId)).single;
        expect(head.revisionId, restored['revisionId']);
        expect(head.parentRevisionIds, [current]);
        expect(head.baseRefs, old.baseRefs);
        expect(await repo.readFiles(head), oldFiles);
        expect(await repo.readFiles(old), oldFiles);
        expect(await session.readMarkdown(), 'Separate summary');
        final count = (await repo.revisions()).length;
        await access.allowEdits(false);
        expect(
          client.data(await client.tool('restore_page_revision', args))['code'],
          'read_only',
        );
        final comparisonAfter = client.data(
          await client.tool('compare_page_revision', {
            'noteId': note.id,
            'revisionId': current,
            'expectedRevisionId': head.revisionId,
          }),
        );
        expect(comparisonAfter['afterRevisionId'], head.revisionId);
        expect((await repo.revisions()).length, count);
        final reopened = await NoteRepository.open(repo.root);
        try {
          expect(
            (await reopened.heads(note.inkEntityId)).single.revisionId,
            restored['revisionId'],
          );
        } finally {
          await reopened.close();
        }
      } finally {
        await client?.close();
        await access.stop();
        controller.dispose();
        await repo.close();
        await temp.delete(recursive: true);
      }
    },
    skip: !File(executable).existsSync(),
    timeout: const Timeout(Duration(seconds: 90)),
  );
}

void nativeWordOwnersStdioTest() {
  final sourcePath = Platform.environment['INK_VAULT_WORD_NATIVE_SOURCE'];
  final runtime = Platform.environment['INK_VAULT_OFFICE_RUNTIME'];
  final helpers = Platform.environment['INK_VAULT_OFFICE_HELPERS'];
  final executable =
      Platform.environment['INK_VAULT_MCP_TEST_EXE'] ??
      p.absolute('build/native/windows/ink_vault_mcp.exe');
  test(
    'native Word owners and page geometry travel through actual MCP stdio and canonical revisions',
    () async {
      final temp = await Directory.systemTemp.createTemp('mcp-word-native-');
      final controller = WorkspaceController(
        await NoteRepository.open(
          Directory(p.join(temp.path, 'vault')),
          createFormatVersion: 2,
        ),
      );
      final engine = WindowsOfficeEngine(
        runtimePath: runtime,
        helperDirectory: helpers,
      );
      final access = McpAccessController(
        () => VaultMcpService(
          controller,
          officeEngine: engine,
          prepareMutation: controller.flush,
        ),
        executable: executable,
        supportDirectory: () async => Directory(p.join(temp.path, 'support')),
      );
      _StdioClient? client;
      try {
        final original = await File(sourcePath!).readAsBytes();
        final originalHash = sha256.convert(original).toString();
        expect(
          originalHash,
          '47dbf7c5d7f7c77dfac11cb4f0ec863966476f71587ae15eb8d80dea9b2feeac',
          reason: 'Use the fixed owner-probe1/no-op-resaved.docx control',
        );
        final store = OfficeDocumentStore(controller.repository);
        final note = await store.importDocument(
          title: 'Native Word MCP',
          fileName: 'owners.docx',
          bytes: original,
        );
        final first = await store.readLatest(note);
        await access.start();
        final config =
            (access.clientConfiguration['mcpServers']
                    as Map)['personal-ink-vault']
                as Map;
        final process = await Process.start(
          executable,
          List<String>.from(config['args'] as List),
        );
        client = _StdioClient(process);
        expect(
          (await client.request('initialize', {
            'protocolVersion': '2025-11-25',
            'capabilities': <String, Object?>{},
            'clientInfo': {
              'name': 'piv-native-word-acceptance',
              'version': '1.0',
            },
          }))['error'],
          isNull,
        );
        process.stdin.writeln(
          jsonEncode({'jsonrpc': '2.0', 'method': 'notifications/initialized'}),
        );
        Future<Map<String, dynamic>> call(
          String name,
          Map<String, Object?> args,
        ) => client!.tool(name, args, timeout: const Duration(seconds: 120));
        final read = client.data(
          await call('read_document', {'noteId': note.id}),
        );
        final office = read['office'] as Map;
        expect(office['bodyOwnerId'], 'body');
        expect(office['sourceSha256'], originalHash);
        expect(office['truncated'], false);
        Map ownerWith(String marker) =>
            (office['wordOwners'] as List).cast<Map>().firstWhere(
              (owner) => (owner['paragraphs'] as List).any(
                (row) => (row['text'] as String).contains(marker),
              ),
            );
        final header = ownerWith('A_HeaderTextFirst');
        final footer = ownerWith('A_FooterTextFirst');
        final pageStyleIds = (header['references'] as List)
            .cast<Map>()
            .map((reference) => reference['pageStyleId'])
            .toSet();
        expect(pageStyleIds, hasLength(1));
        final pageStyle = (office['pageStyles'] as List)
            .cast<Map>()
            .singleWhere((style) => style['id'] == pageStyleIds.single);
        expect(pageStyle['inUse'], true);
        expect(pageStyle['canEditGeometry'], true);
        expect(pageStyle['layoutSha256'], matches(RegExp(r'^[0-9a-f]{64}$')));
        final hp = (header['paragraphs'] as List).last as Map;
        final fp = (footer['paragraphs'] as List).last as Map;
        expect(hp['text'], '');
        expect(fp['text'], '');
        final tableId = (header['tableIds'] as List).single as String;
        final table = (office['tables'] as List).cast<Map>().firstWhere(
          (t) => t['id'] == tableId,
        );
        expect(table['ownerId'], header['id']);
        final operations = <Map<String, Object?>>[
          {
            'op': 'pageGeometry',
            'id': pageStyle['id'],
            'expectedLayoutSha256': pageStyle['layoutSha256'],
            'width': 297,
            'height': 210.01,
            'landscape': true,
            'leftMargin': 25.4,
            'rightMargin': 18,
            'topMargin': 20,
            'bottomMargin': 21,
          },
          {
            'op': 'paragraphText',
            'id': hp['id'],
            'text': 'MCP_HEADER_VERIFIED',
          },
          {
            'op': 'paragraphText',
            'id': fp['id'],
            'text': 'MCP_FOOTER_VERIFIED',
          },
          {
            'op': 'tableCellText',
            'tableId': tableId,
            'cell': (table['cells'] as Map).keys.first,
            'text': 'MCP_HEADER_CELL',
          },
        ];
        final arguments = <String, Object?>{
          'noteId': note.id,
          'expectedRevisionId': office['sourceRevisionId'],
          'requestId': newId(),
          'operations': operations,
        };
        expect((await call('office_edit', arguments))['isError'], true);
        expect(await store.readEditions(note), hasLength(1));
        expect(
          (await store.readLatest(note)).revision.revisionId,
          first.revision.revisionId,
        );
        await access.allowEdits(true);
        final allowed = {...arguments, 'requestId': newId()};
        final result = await call('office_edit', allowed);
        expect(result['isError'], isNot(true), reason: jsonEncode(result));
        final saved = client.data(result);
        expect(client.data(await call('office_edit', allowed)), saved);
        final latest = await store.readLatest(note);
        expect(latest.revision.revisionId, isNot(first.revision.revisionId));
        expect(await store.readEditions(note), hasLength(2));
        expect(latest.pdfBytes, isNotNull);
        expect(latest.pageCount, greaterThan(0));
        final savedOriginalHash = sha256
            .convert(latest.originalBytes)
            .toString();
        final savedPdfHash = sha256.convert(latest.pdfBytes!).toString();
        expect(latest.originalSha256, savedOriginalHash);
        expect(latest.pdfSha256, savedPdfHash);
        final reread = client.data(
          await call('read_document', {'noteId': note.id}),
        );
        final after = reread['office'] as Map;
        expect(after['sourceRevisionId'], latest.revision.revisionId);
        expect(after['sourceSha256'], savedOriginalHash);
        expect(after['truncated'], false);
        final savedHeader = (after['wordOwners'] as List)
            .cast<Map>()
            .singleWhere(
              (owner) => (owner['paragraphs'] as List).any(
                (row) => row['text'] == 'MCP_HEADER_VERIFIED',
              ),
            );
        final savedPageStyleIds = (savedHeader['references'] as List)
            .cast<Map>()
            .map((reference) => reference['pageStyleId'])
            .toSet();
        expect(savedPageStyleIds, hasLength(1));
        final savedPageStyle = (after['pageStyles'] as List)
            .cast<Map>()
            .singleWhere((style) => style['id'] == savedPageStyleIds.single);
        expect(savedPageStyle['canEditGeometry'], true);
        expect(savedPageStyle['width'], 297);
        expect(savedPageStyle['height'], 210.01);
        expect(savedPageStyle['landscape'], true);
        expect(savedPageStyle['leftMargin'], 25.4);
        expect(savedPageStyle['rightMargin'], 17.99);
        expect(savedPageStyle['topMargin'], 20);
        expect(savedPageStyle['bottomMargin'], 21.01);
        expect(
          savedPageStyle['layoutSha256'],
          matches(RegExp(r'^[0-9a-f]{64}$')),
        );
        expect(
          savedPageStyle['layoutSha256'],
          isNot(pageStyle['layoutSha256']),
        );
        final rows = (after['wordOwners'] as List)
            .cast<Map>()
            .expand((owner) => (owner['paragraphs'] as List).cast<Map>())
            .toList();
        expect(
          rows.where((row) => row['text'] == 'MCP_HEADER_VERIFIED'),
          hasLength(1),
        );
        expect(
          rows.where((row) => row['text'] == 'MCP_FOOTER_VERIFIED'),
          hasLength(1),
        );
        expect(
          (after['paragraphs'] as List).map((p) => p['text']),
          (office['paragraphs'] as List).map((p) => p['text']),
        );
        expect(
          (after['tables'] as List).cast<Map>().any(
            (t) => (t['cells'] as Map).containsValue('MCP_HEADER_CELL'),
          ),
          true,
        );
        expect(
          (await call('office_edit', {
            ...allowed,
            'requestId': newId(),
          }))['isError'],
          true,
        );
        await access.allowEdits(false);
        expect(
          (await call('office_edit', {
            ...allowed,
            'expectedRevisionId': latest.revision.revisionId,
            'requestId': newId(),
          }))['isError'],
          true,
        );
        expect(
          (await store.readLatest(note)).revision.revisionId,
          latest.revision.revisionId,
        );
        expect(await store.readEditions(note), hasLength(2));
        final unchangedSaved = await store.readLatest(
          note,
          revisionId: latest.revision.revisionId,
        );
        expect(unchangedSaved.originalBytes, latest.originalBytes);
        expect(unchangedSaved.pdfBytes, latest.pdfBytes);
        expect(unchangedSaved.originalSha256, savedOriginalHash);
        expect(unchangedSaved.pdfSha256, savedPdfHash);
        final unchangedFirst = await store.readLatest(
          note,
          revisionId: first.revision.revisionId,
        );
        expect(unchangedFirst.originalBytes, original);
        expect(unchangedFirst.originalSha256, originalHash);
        expect(unchangedFirst.pdfBytes, first.pdfBytes);
        expect(unchangedFirst.pdfSha256, first.pdfSha256);
        expect(
          (await store.readLatest(
            note,
            revisionId: first.revision.revisionId,
          )).originalBytes,
          original,
        );
        expect(
          sha256.convert(await File(sourcePath).readAsBytes()).toString(),
          originalHash,
        );
      } finally {
        await client?.close();
        await access.stop();
        access.dispose();
        await controller.flush();
        controller.dispose();
        await controller.repository.close();
        await temp.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 6)),
    skip:
        !Platform.isWindows ||
            sourcePath == null ||
            runtime == null ||
            helpers == null
        ? 'Opt in with fixed native Word fixture/runtime/helpers; root owns serial Office execution'
        : !File(executable).existsSync()
        ? 'Build MCP executable first'
        : false,
  );
}

void slideDesignStdioTest() {
  final executable =
      Platform.environment['INK_VAULT_MCP_TEST_EXE'] ??
      p.absolute('build/native/windows/ink_vault_mcp.exe');
  test(
    'actual stdio PPT design preserves owners timeline revision retry and revocation',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'mcp-design-real-app-',
      );
      final controller = WorkspaceController(
        await NoteRepository.open(
          Directory('${temp.path}/vault'),
          createFormatVersion: 2,
        ),
      );
      final original = OfficeTemplates.create(
        OfficeTemplateKind.presentation,
        title: 'Original',
      ).bytes;
      final edited = OfficeTemplates.create(
        OfficeTemplateKind.presentation,
        title: 'Edited',
      ).bytes;
      final pdf = Uint8List.fromList(
        utf8.encode('%PDF-1.7\nsynthetic native adapter\n%%EOF\n'),
      );
      final operations = <Map<String, Object?>>[
        {'op': 'shapeText', 'id': 'master-0/shape-0', 'text': 'Updated brand'},
        {
          'op': 'slideDesign',
          'id': 'slide-0',
          'changeId': 'design-1',
          'expectedDesignSha256': 'b' * 64,
          'masterId': 'master-0',
          'layoutCode': 19,
        },
        {
          'op': 'slideDisplay',
          'id': 'slide-0',
          'visible': false,
          'showMasterObjects': false,
        },
      ];
      Map<String, Object?> snapshot(String hash, bool saved) => {
        'kind': 'presentation',
        'sourceSha256': hash,
        'paragraphs': [],
        'tables': [],
        'layoutOptions': [
          {'code': 0, 'label': 'Title'},
          {'code': 19, 'label': 'Title only'},
        ],
        'masters': [
          {
            'id': 'master-0',
            'name': 'Common design',
            'width': 280,
            'height': 157.5,
            'shapes': [
              {
                'id': 'master-0/shape-0',
                'ownerKind': 'master',
                'ownerId': 'master-0',
                'type': 'com.sun.star.drawing.TextShape',
                'shapeKind': 'text',
                'text': saved ? 'Updated brand' : 'Brand',
                'editableText': true,
                'presentationObject': false,
                'emptyPresentationObject': false,
                'x': 10,
                'y': 10,
                'width': 80,
                'height': 20,
              },
            ],
          },
        ],
        'slides': [
          {
            'id': 'slide-0',
            'width': 280,
            'height': 157.5,
            'masterId': 'master-0',
            'layoutCode': saved ? 19 : 0,
            'designSha256': 'b' * 64,
            'visible': !saved,
            'showMasterObjects': !saved,
            'shapes': [],
          },
        ],
      };
      var writes = 0;
      final access = McpAccessController(
        () => VaultMcpService(
          controller,
          prepareMutation: controller.flush,
          officeEngine: WindowsOfficeEngine(
            runner: (request) async {
              final hash = sha256
                  .convert(
                    await File(request['sourcePath'] as String).readAsBytes(),
                  )
                  .toString();
              if (request['mode'] == 'inspect')
                return {'snapshot': snapshot(hash, writes > 0)};
              expect(request['operations'], operations);
              writes++;
              return {
                'status': 'saved',
                'sessionId': request['sessionId'],
                'sourcePath': (await File(
                  '${temp.path}/edited.pptx',
                ).writeAsBytes(edited)).path,
                'pdfPath': (await File(
                  '${temp.path}/preview.pdf',
                ).writeAsBytes(pdf)).path,
                'sourceSha256': sha256.convert(edited).toString(),
                'pdfSha256': sha256.convert(pdf).toString(),
                'pdfPageCount': 1,
                'engineVersion': 'synthetic-native-adapter-real-stdio',
                'snapshot': snapshot(sha256.convert(edited).toString(), true),
              };
            },
          ),
        ),
        executable: executable,
        supportDirectory: () async => Directory('${temp.path}/support'),
      );
      _StdioClient? client;
      try {
        final store = OfficeDocumentStore(controller.repository);
        final note = await store.importDocument(
          title: 'Slides',
          fileName: 'source.pptx',
          bytes: original,
        );
        final first = await store.readLatest(note);
        await access.start();
        await access.allowEdits(true);
        final config =
            (access.clientConfiguration['mcpServers']
                    as Map)['personal-ink-vault']
                as Map;
        final process = await Process.start(
          executable,
          List<String>.from(config['args'] as List),
        );
        client = _StdioClient(process);
        expect(
          (await client.request('initialize', {
            'protocolVersion': '2025-11-25',
            'capabilities': <String, Object?>{},
            'clientInfo': {
              'name': 'piv-design-protocol-client',
              'version': '1.0',
            },
          }))['error'],
          isNull,
        );
        process.stdin.writeln(
          jsonEncode({'jsonrpc': '2.0', 'method': 'notifications/initialized'}),
        );
        final read = client.data(
          await client.tool('read_document', {'noteId': note.id}),
        );
        expect(
          read['office']['masters'].single['shapes'].single['ownerKind'],
          'master',
        );
        expect(read['office']['slides'].single['layoutCode'], 0);
        final args = {
          'noteId': note.id,
          'expectedRevisionId': read['office']['sourceRevisionId'],
          'requestId': newId(),
          'operations': operations,
        };
        final response = await client.tool('office_edit', args);
        expect(response['isError'], false);
        final saved = client.data(response);
        expect(client.data(await client.tool('office_edit', args)), saved);
        expect(writes, 1);
        final after = client.data(
          await client.tool('read_document', {'noteId': note.id}),
        );
        expect(
          after['office']['masters'].single['shapes'].single['text'],
          'Updated brand',
        );
        expect(after['office']['slides'].single['visible'], false);
        expect(after['office']['slides'].single['showMasterObjects'], false);
        expect((await store.readLatest(note)).originalBytes, edited);
        expect(
          (await store.readLatest(
            note,
            revisionId: first.revision.revisionId,
          )).originalBytes,
          original,
        );
        expect(
          (await client.tool('office_edit', {
            ...args,
            'requestId': newId(),
          }))['isError'],
          true,
        );
        await access.allowEdits(false);
        expect(
          (await client.tool('office_edit', {
            ...args,
            'expectedRevisionId': saved['revisionId'],
            'requestId': newId(),
          }))['isError'],
          true,
        );
        expect(writes, 1);
      } finally {
        await client?.close();
        await access.stop();
        access.dispose();
        await controller.flush();
        controller.dispose();
        await controller.repository.close();
        await temp.delete(recursive: true);
      }
    },
    skip: !File(executable).existsSync()
        ? 'Build the actual MCP executable first'
        : false,
  );
}

void wordStructureStdioTest() {
  final executable =
      Platform.environment['INK_VAULT_MCP_TEST_EXE'] ??
      p.absolute('build/native/windows/ink_vault_mcp.exe');
  test(
    'actual stdio Word structure preserves timeline revision retry and write revocation',
    () async {
      final temp = await Directory.systemTemp.createTemp('mcp-word-real-app-');
      final controller = WorkspaceController(
        await NoteRepository.open(
          Directory('${temp.path}/vault'),
          createFormatVersion: 2,
        ),
      );
      final original = OfficeTemplates.create(
        OfficeTemplateKind.document,
        title: 'AB',
      ).bytes;
      final edited = OfficeTemplates.create(
        OfficeTemplateKind.document,
        title: 'AB after structure',
      ).bytes;
      final pdf = Uint8List.fromList(
        utf8.encode('%PDF-1.7\nsynthetic engine fixture\n%%EOF\n'),
      );
      String hash(String text) => sha256.convert(utf8.encode(text)).toString();
      final operations = <Map<String, Object?>>[
        {
          'op': 'paragraphSplit',
          'id': 'p0',
          'newId': 'right',
          'offsetUtf16': 1,
          'expectedTextSha256': hash('AB'),
        },
        {
          'op': 'paragraphInsert',
          'id': 'inserted',
          'referenceId': 'right',
          'position': 'after',
          'expectedTextSha256': hash('B'),
          'text': 'C',
        },
        {
          'op': 'paragraphJoin',
          'id': 'p0',
          'nextId': 'right',
          'expectedTextSha256': hash('A'),
          'expectedNextTextSha256': hash('B'),
        },
        {
          'op': 'paragraphDelete',
          'id': 'inserted',
          'expectedTextSha256': hash('C'),
        },
        {
          'op': 'paragraphFormat',
          'id': 'p0',
          'expectedTextSha256': hash('AB'),
          'alignment': 'center',
          'listKind': 'none',
          'pageBreakBefore': false,
        },
      ];
      Map<String, Object?> snapshot(String sourceHash, bool saved) => {
        'kind': 'word',
        'sourceSha256': sourceHash,
        'tables': [],
        'slides': [],
        'blocks': [
          {'kind': 'paragraph', 'id': 'p0'},
        ],
        'paragraphStyles': [
          {'name': 'Standard', 'displayName': '본문'},
        ],
        'paragraphs': [
          {
            'id': 'p0',
            'text': 'AB',
            'textDetails': {
              'utf16Length': 2,
              'textSha256': hash('AB'),
              'canReplace': true,
              'canStyle': true,
              'runs': [],
              'protectedRanges': [],
            },
            'paragraphFormat': {
              'styleName': 'Standard',
              'alignment': saved ? 'center' : 'left',
              'listKind': 'none',
              'listLevel': 0,
              'pageBreakBefore': false,
            },
            'structure': {
              'canSplit': true,
              'canDelete': false,
              'canInsertBefore': true,
              'canInsertAfter': true,
              'canJoinNext': false,
            },
          },
        ],
      };
      var writes = 0;
      final access = McpAccessController(
        () => VaultMcpService(
          controller,
          prepareMutation: controller.flush,
          officeEngine: WindowsOfficeEngine(
            runner: (request) async {
              final sourceHash = sha256
                  .convert(
                    await File(request['sourcePath'] as String).readAsBytes(),
                  )
                  .toString();
              if (request['mode'] == 'inspect')
                return {'snapshot': snapshot(sourceHash, writes > 0)};
              expect(request['operations'], operations);
              writes++;
              return {
                'status': 'saved',
                'sessionId': request['sessionId'],
                'sourcePath': (await File(
                  '${temp.path}/edited.docx',
                ).writeAsBytes(edited)).path,
                'pdfPath': (await File(
                  '${temp.path}/preview.pdf',
                ).writeAsBytes(pdf)).path,
                'sourceSha256': sha256.convert(edited).toString(),
                'pdfSha256': sha256.convert(pdf).toString(),
                'pdfPageCount': 1,
                'engineVersion': 'synthetic-word-engine-real-stdio',
                'snapshot': snapshot(sha256.convert(edited).toString(), true),
              };
            },
          ),
        ),
        executable: executable,
        supportDirectory: () async => Directory('${temp.path}/support'),
      );
      _StdioClient? client;
      try {
        final store = OfficeDocumentStore(controller.repository);
        final note = await store.importDocument(
          title: 'Word',
          fileName: 'source.docx',
          bytes: original,
        );
        final first = await store.readLatest(note);
        await access.start();
        await access.allowEdits(true);
        final config =
            (access.clientConfiguration['mcpServers']
                    as Map)['personal-ink-vault']
                as Map;
        final process = await Process.start(
          executable,
          List<String>.from(config['args'] as List),
        );
        client = _StdioClient(process);
        expect(
          (await client.request('initialize', {
            'protocolVersion': '2025-11-25',
            'capabilities': <String, Object?>{},
            'clientInfo': {
              'name': 'piv-word-protocol-client',
              'version': '1.0',
            },
          }))['error'],
          isNull,
        );
        process.stdin.writeln(
          jsonEncode({'jsonrpc': '2.0', 'method': 'notifications/initialized'}),
        );
        final read = client.data(
          await client.tool('read_document', {'noteId': note.id}),
        );
        expect(read['office']['blocks'], [
          {'kind': 'paragraph', 'id': 'p0'},
        ]);
        expect(
          read['office']['paragraphs'].single['textDetails']['textSha256'],
          hash('AB'),
        );
        final args = {
          'noteId': note.id,
          'expectedRevisionId': read['office']['sourceRevisionId'],
          'requestId': newId(),
          'operations': operations,
        };
        final result = client.data(await client.tool('office_edit', args));
        expect(client.data(await client.tool('office_edit', args)), result);
        expect(writes, 1);
        final after = client.data(
          await client.tool('read_document', {'noteId': note.id}),
        );
        expect(
          after['office']['paragraphs'].single['paragraphFormat']['alignment'],
          'center',
        );
        expect((await store.readLatest(note)).originalBytes, edited);
        expect(
          (await store.readLatest(
            note,
            revisionId: first.revision.revisionId,
          )).originalBytes,
          original,
        );
        expect(
          (await client.tool('office_edit', {
            ...args,
            'requestId': newId(),
          }))['isError'],
          true,
        );
        await access.allowEdits(false);
        expect(
          (await client.tool('office_edit', {
            ...args,
            'expectedRevisionId': result['revisionId'],
            'requestId': newId(),
          }))['isError'],
          true,
        );
        expect(writes, 1);
      } finally {
        await client?.close();
        await access.stop();
        access.dispose();
        await controller.flush();
        controller.dispose();
        await controller.repository.close();
        await temp.delete(recursive: true);
      }
    },
    skip: !File(executable).existsSync()
        ? 'Build the actual MCP executable first'
        : false,
  );
}
