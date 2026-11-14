import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/mcp/vault_mcp_bridge.dart';
import 'package:saber/data/mcp/vault_mcp_service.dart';
import 'package:saber/data/native/ink_vault_native.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/pages/workspace/mcp_panel.dart';
import 'package:saber/pages/workspace/workspace_controller.dart';

import '../../integration_test/support/windows_mcp_rpc.dart';

const _operation = 'search_documents';
const _prefix = 'piv-search-mcp-';
const _expression =
    'path:"연구 노트/" tag:#연구 -file:초안 '
    '(content:"graph model" OR content:"vector index")';
const _legacyQuery = 'path:"연구 노트/"';
const _readOnly = VaultMcpCallContext(isActive: _yes, canWrite: _no);

bool _yes() => true;
bool _no() => false;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final library = Platform.environment['INK_VAULT_NATIVE_LIBRARY'];
  final executable = Platform.environment['INK_VAULT_MCP_TEST_EXE'];

  test(
    'MCP expression search pages saved hits without mutating notes',
    () async {
      final fixture = await _Fixture.open(library!);
      final (first, second, _) = await fixture.seed();
      final before = await fixture.revisions();

      final result = await fixture.search(_expression);
      final matches = _matches(result);
      expect(
        result.keys,
        unorderedEquals(['matches', 'total', 'offset', 'limit']),
      );
      expect(result['total'], 2);
      expect(result['offset'], 0);
      expect(result['limit'], 50);
      expect(matches.map((row) => row['noteId']), [first.id, second.id]);
      expect(matches.map((row) => row['title']), [first.title, second.title]);
      expect(matches.map((row) => row['path']), [
        '연구 노트/하위/A 실험.md',
        '연구 노트/B 현장.md',
      ]);
      expect(matches.first['snippet'], contains('graph model'));
      expect(matches.last['snippet'], contains('vector index'));
      expect(matches.map((row) => row['score']), everyElement(isA<int>()));
      expect(await fixture.search(_expression, limit: 1, offset: 1), {
        'matches': [matches.last],
        'total': 2,
        'offset': 1,
        'limit': 1,
      });
      expect(_matches(await fixture.search(_expression, offset: 2)), isEmpty);

      for (final args in <Map<String, dynamic>>[
        {},
        {'query': 9},
        {'query': ' \t '},
        {'query': '😀' * 1025},
        {'query': _expression, 'limit': 101},
        {'query': _expression, 'offset': -1},
        {'query': _expression, 'vaultId': newId()},
      ]) {
        await expectLater(
          fixture.call(args),
          throwsA(_error('invalid_arguments')),
        );
      }
      await expectLater(
        fixture.search('tag:#연구 OR'),
        throwsA(_error('invalid_search_expression')),
      );
      await expectLater(
        fixture.call({
          'query': _expression,
        }, context: const VaultMcpCallContext(isActive: _no, canWrite: _yes)),
        throwsA(_error('authorization_revoked')),
      );
      expect(await fixture.revisions(), before);

      final controller = fixture.controller;
      await controller.openNote(first, recordNavigation: false);
      final saved = controller.markdown;
      // Model a pending draft without scheduling the editor autosave timer.
      controller.markdown = 'mcp draft secret';
      controller.markdownDirty = true;
      try {
        expect(
          _matches(await fixture.search('content:"mcp draft secret"')),
          isEmpty,
        );
        expect(
          _matches(await fixture.search(_expression)).first['noteId'],
          first.id,
        );
        expect(controller.markdown, 'mcp draft secret');
        expect(controller.markdownDirty, isTrue);
        expect(await fixture.revisions(), before);
      } finally {
        controller.markdown = saved;
        controller.markdownDirty = false;
      }

      await (await fixture.controller.store.open(first))
          .saveMarkdown('graph model 보고서 #다른태그');
      final edited = await fixture.revisions();
      expect(edited.difference(before), hasLength(1));
      expect(
        _matches(await fixture.search(_expression)).single['noteId'],
        second.id,
      );
      expect(await fixture.revisions(), edited);
      expect(fixture.preparedMutations, 0);
    },
    skip: library == null ? 'Set INK_VAULT_NATIVE_LIBRARY' : false,
  );

  test(
    'Windows MCP exposes search through the read-only bridge and preserves literal listing',
    () async {
      final fixture = await _Fixture.open(library!);
      final (first, second, literal) = await fixture.seed();
      final access = McpAccessController(
        () => fixture.service,
        executable: p.absolute(executable!),
        supportDirectory: () async =>
            Directory(p.join(fixture.temp.path, 'support')),
      );
      addTearDown(() async {
        await access.stop();
        access.dispose();
      });
      await access.start();
      final servers = access.clientConfiguration['mcpServers'] as Map;
      final config = servers['personal-ink-vault'] as Map;
      final args = List<String>.from(config['args'] as List);
      final client = await WindowsMcpRpc.start(
        config['command'] as String,
        args.last,
      );
      addTearDown(client.close);

      expect(await client.tools(), containsAll([_operation, 'list_documents']));
      final status = await client.call('vault_status', {});
      expect(status.isError, isFalse);
      expect(status.data['writeEnabled'], isFalse);
      final before = await fixture.revisions();

      final result = await client.call(_operation, {'query': _expression});
      expect(result.isError, isFalse);
      expect(result.data, await fixture.search(_expression));
      expect(_matches(result.data).map((row) => row['noteId']), [
        first.id,
        second.id,
      ]);
      final document = await client.call('read_document', {
        'noteId': _matches(result.data).first['noteId'],
      });
      expect(document.isError, isFalse);
      expect(document.data['title'], first.title);
      expect(document.data['markdown']['content'], contains('graph model'));

      final legacy = await client.call('list_documents', {
        'query': _legacyQuery,
      });
      expect(legacy.isError, isFalse);
      expect((legacy.data['documents'] as List).single['id'], literal.id);
      final invalid = await client.call(_operation, {'query': 'tag:#연구 OR'});
      expect(invalid.isError, isTrue);
      expect(invalid.data['code'], 'invalid_search_expression');
      final denied = await client.call('create_document', {
        'title': '권한 시험',
        'kind': 'markdown',
        'requestId': newId(),
      });
      expect(denied.isError, isTrue);
      expect(denied.data['code'], 'read_only');

      await access.stop();
      final disconnected = await client.call(_operation, {
        'query': _expression,
      });
      expect(disconnected.isError, isTrue);
      expect(disconnected.data['code'], 'app_not_running');
      expect(await fixture.revisions(), before);
      expect(fixture.preparedMutations, 0);
    },
    skip: !Platform.isWindows || library == null || executable == null
        ? 'Set INK_VAULT_MCP_TEST_EXE and INK_VAULT_NATIVE_LIBRARY on Windows'
        : false,
  );
}

List<Map<String, dynamic>> _matches(Map<String, dynamic> reply) =>
    (reply['matches'] as List).cast<Map<String, dynamic>>();

Matcher _error(String code) =>
    isA<VaultMcpException>().having((error) => error.code, 'code', code);

final class _Fixture {
  new(this.temp, this.controller);

  final Directory temp;
  final WorkspaceController controller;
  var preparedMutations = 0;
  late final service = VaultMcpService(
    controller,
    prepareMutation: () async {
      preparedMutations++;
    },
  );

  static Future<_Fixture> open(String library) async {
    final temp = await Directory.systemTemp.createTemp(_prefix);
    addTearDown(() async {
      final actual = await temp.resolveSymbolicLinks();
      final parent = await Directory.systemTemp.resolveSymbolicLinks();
      expect(p.equals(p.dirname(actual), parent), isTrue);
      expect(p.basename(actual), startsWith(_prefix));
      await Directory(actual).delete(recursive: true);
    });
    final native = InkVaultNative.open(libraryPath: p.absolute(library));
    final repo = await NoteRepository.open(
      Directory(p.join(temp.path, 'vault')),
      createFormatVersion: 2,
    );
    addTearDown(repo.close);
    final controller = WorkspaceController(repo, native: native);
    addTearDown(controller.dispose);
    return _Fixture(temp, controller);
  }

  Future<VaultNote> create(String title, String body, {String? folderId}) =>
      controller.store.createMarkdown(
        title,
        Uint8List.fromList(utf8.encode(body)),
        folderId: folderId,
      );

  Future<(VaultNote, VaultNote, VaultNote)> seed() async {
    final parent = await controller.library.createFolder('연구 노트');
    final nested = await controller.library.createFolder(
      '하위',
      parentId: parent.id,
    );
    final unrelated = await controller.library.createFolder('연구 노트실');
    final first = await create(
      'A 실험',
      '---\ntags: [연구/실험]\n---\ngraph model 보고서',
      folderId: nested.id,
    );
    final second = await create(
      'B 현장',
      'vector index 기록 #연구/현장',
      folderId: parent.id,
    );
    await create('초안 문서', 'graph model #연구/실험', folderId: nested.id);
    await create('다른 폴더', 'graph model #연구/실험', folderId: unrelated.id);
    final literal = await create('일반 검색 예시', '문자 그대로 $_legacyQuery');
    return (first, second, literal);
  }

  Future<Set<String>> revisions() async => {
    for (final revision in await controller.repository.revisions())
      revision.revisionId,
  };

  Future<Object?> call(
    Map<String, dynamic> args, {
    VaultMcpCallContext context = _readOnly,
  }) => service.call(_operation, args, context: context);

  Future<Map<String, dynamic>> search(
    String query, {
    int? limit,
    int? offset,
  }) async => Map<String, dynamic>.from(
    await call({'query': query, 'limit': ?limit, 'offset': ?offset}) as Map,
  );
}
