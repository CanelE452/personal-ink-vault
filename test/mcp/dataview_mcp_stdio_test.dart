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

const _operation = 'query_dataview';
const _prefix = 'piv-dataview-mcp-';
const _table =
    'TABLE rank AS "우선순위", active, empty, status FROM "연구" '
    'WHERE status = "진행 중" AND (rank >= 2 OR active) '
    'SORT status ASC, rank ASC LIMIT 1';

const _firstBody = '''
---
rank: 2
active: true
empty: null
status: 진행 중
---
첫 본문 #실험
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final library = Platform.environment['INK_VAULT_NATIVE_LIBRARY'];
  final executable = Platform.environment['INK_VAULT_MCP_TEST_EXE'];
  final libraryUnavailable = library == null
      ? 'Set INK_VAULT_NATIVE_LIBRARY to the Rust workspace library'
      : false;

  test('Dataview MCP service reads committed properties and never prepares a mutation', () async {
    final fixture = await _Fixture.open(library!);
    final (first, second) = await fixture.seed();
    final before = await fixture.revisions();

    expect(await fixture.query(_table), {
      'mode': 'table',
      'columns': [
        {'field': 'rank', 'label': '우선순위'},
        {'field': 'active', 'label': 'active'},
        {'field': 'empty', 'label': 'empty'},
        {'field': 'status', 'label': 'status'},
      ],
      'rows': [
        {
          'noteId': first.id,
          'title': first.title,
          'path': '연구/하위/첫 문서.md',
          'values': [2, true, null, '진행 중'],
        },
      ],
    });
    expect(await fixture.query('LIST FROM #실험 WHERE rank = 2'), {
      'mode': 'list',
      'columns': [],
      'rows': [
        {
          'noteId': first.id,
          'title': first.title,
          'path': '연구/하위/첫 문서.md',
          'values': [],
        },
      ],
    });
    for (final args in <Map<String, dynamic>>[
      {},
      {'query': 2},
      {'query': _table, 'vaultId': newId()},
      {'query': 'TABLE rank WHERE rank >'},
      {'query': 'LIST FROM "../outside"'},
      {'query': 'LIST FROM [[]]'},
      {'query': 'LIST${' ' * 4093}'},
    ]) {
      await expectLater(
        fixture.call(args),
        throwsA(_error('invalid_arguments')),
      );
    }
    await expectLater(
      fixture.call(
        {'query': _table},
        context: VaultMcpCallContext(
          isActive: () => false,
          canWrite: () => true,
        ),
      ),
      throwsA(_error('authorization_revoked')),
    );
    expect(await fixture.revisions(), before);

    await (await fixture.controller.store.open(first))
        .saveMarkdown(_firstBody.replaceFirst('status: 진행 중', 'status: 완료'));
    final afterEdit = await fixture.revisions();
    expect(afterEdit.difference(before), hasLength(1));
    final next = await fixture.query(_table);
    expect(next['rows'], [
      {
        'noteId': second.id,
        'title': second.title,
        'path': '연구/둘 문서.md',
        'values': [10, false, null, '진행 중'],
      },
    ]);
    expect(await fixture.revisions(), afterEdit);
    expect(fixture.preparedMutations, 0);
  }, skip: libraryUnavailable);

  test('Dataview TASK returns the exact saved Markdown revision', () async {
    final fixture = await _Fixture.open(library!);
    const body =
        '---\r\nstatus: 진행\r\n---\r\n'
        '- [ ] 자료 읽기 😀\r\n  - [x] 본문 정리\r\n'
        '```markdown\r\n- [ ] 코드 속 예시\r\n```\r\n';
    final note = await fixture.create('연구 할 일', body);
    final revision = (await fixture.controller.repository.heads(
      note.markdownEntityId,
    )).single.revisionId;
    final before = await fixture.revisions();
    final expectedTask = <String, Object?>{
      'text': '자료 읽기 😀',
      'status': ' ',
      'checked': false,
      'completed': false,
      'line': 4,
      'revisionId': revision,
    };
    expect(await fixture.query('TASK WHERE !completed'), {
      'mode': 'task',
      'columns': [],
      'rows': [
        {
          'noteId': note.id,
          'title': note.title,
          'path': '연구 할 일.md',
          'values': [],
          'task': expectedTask,
        },
      ],
    });
    final historical = await fixture.service.call(
      'read_document',
      {'noteId': note.id, 'revisionId': revision},
      context: VaultMcpCallContext(isActive: () => true, canWrite: () => false),
    ) as Map;
    expect((historical['revision'] as Map)['content'], body);
    expect(await fixture.revisions(), before);

    await (await fixture.controller.store.open(note))
        .saveMarkdown(body.replaceFirst('[ ]', '[X]'));
    final after = await fixture.revisions();
    expect(after.difference(before), hasLength(1));
    expect((await fixture.query('TASK WHERE !completed'))['rows'], isEmpty);
    final completed =
        (await fixture.query('TASK WHERE completed SORT line'))['rows'] as List;
    expect(completed.map((row) => row['task']['status']), ['X', 'x']);
    expect(
      completed.map((row) => row['task']['revisionId']).toSet(),
      after.difference(before),
    );
    expect(await fixture.revisions(), after);
    expect(fixture.preparedMutations, 0);
  }, skip: libraryUnavailable);

  test(
    'Dataview MCP limits groups separately from their task members',
    () async {
      final fixture = await _Fixture.open(library!);
      final last = await fixture.controller.library.createFolder('B');
      final first = await fixture.controller.library.createFolder('A');
      await fixture.create(
        '큰 문서',
        List.generate(240, (index) => '- [ ] 할 일 $index\n').join(),
        folderId: last.id,
      );
      final note = await fixture.create(
        '작은 문서',
        '- [ ] 첫째\n- [x] 둘째\n',
        folderId: first.id,
      );
      final before = await fixture.revisions();
      const grouped = 'TASK SORT line DESC GROUP BY file.folder AS "폴더"';
      final result = await fixture.query('$grouped LIMIT 1');
      expect(
        result.keys,
        unorderedEquals(['mode', 'columns', 'groupBy', 'groups']),
      );
      expect(result['mode'], 'task');
      expect(result['groupBy'], {'field': 'file.folder', 'label': '폴더'});
      final group = (result['groups'] as List).single as Map;
      expect(group['key'], 'A');
      final rows = group['rows'] as List;
      expect(rows.map((row) => row['noteId']), [note.id, note.id]);
      expect(rows.map((row) => row['task']['text']), ['둘째', '첫째']);
      await expectLater(
        fixture.query('$grouped LIMIT 2'),
        throwsA(_error('result_too_large')),
      );
      expect(await fixture.revisions(), before);
      expect(fixture.preparedMutations, 0);
    },
    skip: libraryUnavailable,
  );

  test(
    'Dataview MCP service caps response bytes including multibyte cells',
    () async {
      final fixture = await _Fixture.open(library!);
      final payload = '가' * 4096;
      for (var index = 1; index <= 3; index++) {
        await fixture.create('큰 노트 $index', '---\npayload: $payload\n---\n');
      }
      final before = await fixture.revisions();
      final columns = List.filled(16, 'payload').join(', ');
      expect(
        (await fixture.query('TABLE $columns LIMIT 2'))['rows'],
        hasLength(2),
      );
      await expectLater(
        fixture.query('TABLE $columns'),
        throwsA(_error('result_too_large')),
      );
      expect(await fixture.revisions(), before);
      expect(fixture.preparedMutations, 0);
    },
    skip: libraryUnavailable,
  );

  test(
    'Dataview MCP serializes document groups and typed file links',
    () async {
      final fixture = await _Fixture.open(library!);
      final (first, second) = await fixture.seed();
      final before = await fixture.revisions();
      const query =
          'TABLE rows.file.link AS "원본", rows.rank '
          'FROM "연구" SORT rank DESC GROUP BY status AS "상태"';
      final result = await fixture.query(query);
      expect(
        result.keys,
        unorderedEquals(['mode', 'columns', 'groupBy', 'groups']),
      );
      expect(result['mode'], 'table');
      expect(result['groupBy'], {'field': 'status', 'label': '상태'});
      final group = (result['groups'] as List).single as Map;
      expect(group['key'], '진행 중');
      expect(group['values'], [
        [
          {
            'type': 'file',
            'noteId': second.id,
            'title': second.title,
            'path': '연구/둘 문서.md',
          },
          {
            'type': 'file',
            'noteId': first.id,
            'title': first.title,
            'path': '연구/하위/첫 문서.md',
          },
        ],
        [10, 2],
      ]);
      expect((group['rows'] as List).map((row) => row['noteId']), [
        second.id,
        first.id,
      ]);
      expect(await fixture.revisions(), before);
      expect(fixture.preparedMutations, 0);
    },
    skip: libraryUnavailable,
  );

  test(
    'Windows Rust stdio exposes Dataview through the read-only app bridge',
    () async {
      final fixture = await _Fixture.open(library!);
      final (first, second) = await fixture.seed();
      final taskNote = await fixture.create('읽기 목록', '- [ ] 이번 주 자료\n');
      final linkNote = await fixture.create('문서 연결', '[[연구/하위/첫 문서]]');
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
      expect(args.first, '--bridge-file');
      final client = await WindowsMcpRpc.start(
        config['command'] as String,
        args.last,
      );
      addTearDown(client.close);

      expect(await client.tools(), contains(_operation));
      final status = await client.call('vault_status', {});
      expect(status.isError, isFalse);
      expect(status.data['writeEnabled'], isFalse);
      final before = await fixture.revisions();
      final result = await client.call(_operation, {'query': _table});
      expect(result.isError, isFalse);
      expect(result.data, await fixture.query(_table));
      expect((result.data['rows'] as List).single['noteId'], first.id);
      final linked = await client.call(_operation, {
        'query': 'LIST FROM [[연구/하위/첫 문서]] AND !#archive',
      });
      expect(linked.isError, isFalse);
      expect((linked.data['rows'] as List).single['noteId'], linkNote.id);

      const taskExpression =
          'TASK WHERE !completed AND (line >= 2 | status = " ") '
          'SORT file.name, line DESC';
      final taskQuery = await client.call(_operation, {
        'query': taskExpression,
      });
      expect(taskQuery.isError, isFalse);
      expect(taskQuery.data, await fixture.query(taskExpression));
      expect((taskQuery.data['rows'] as List).single['noteId'], taskNote.id);

      const grouped = 'TASK GROUP BY file.folder LIMIT 1';
      final groupQuery = await client.call(_operation, {'query': grouped});
      expect(groupQuery.isError, isFalse);
      expect(groupQuery.data, await fixture.query(grouped));
      final group = (groupQuery.data['groups'] as List).single as Map;
      expect(group['key'], '');
      expect((group['rows'] as List).single['noteId'], taskNote.id);

      const groupedDocuments =
          'LIST rows.file.link FROM "연구" GROUP BY status LIMIT 1';
      final documentGroups = await client.call(_operation, {
        'query': groupedDocuments,
      });
      expect(documentGroups.isError, isFalse);
      expect(documentGroups.data, await fixture.query(groupedDocuments));
      final documentGroup =
          (documentGroups.data['groups'] as List).single as Map;
      expect(documentGroup['key'], '진행 중');
      expect(
        (documentGroup['rows'] as List).map((row) => row['noteId']).toSet(),
        {first.id, second.id},
      );

      for (final invalid in [
        {'query': 'SELECT *'},
        {'query': 'LIST ${'😀' * 2046}'},
      ]) {
        final rejected = await client.call(_operation, invalid);
        expect(rejected.isError, isTrue);
        expect(rejected.data['code'], 'invalid_arguments');
      }
      expect(await fixture.revisions(), before);
      await (await fixture.controller.store.open(first))
          .saveMarkdown(_firstBody.replaceFirst('status: 진행 중', 'status: 완료'));
      final afterEdit = await fixture.revisions();
      final next = await client.call(_operation, {'query': _table});
      expect(next.isError, isFalse);
      expect((next.data['rows'] as List).single['noteId'], second.id);
      expect(await fixture.revisions(), afterEdit);
      expect(fixture.preparedMutations, 0);
    },
    skip: !Platform.isWindows || library == null || executable == null
        ? 'Set INK_VAULT_MCP_TEST_EXE and INK_VAULT_NATIVE_LIBRARY on Windows'
        : false,
  );
}

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

  Future<(VaultNote, VaultNote)> seed() async {
    final parent = await controller.library.createFolder('연구');
    final nested = await controller.library.createFolder(
      '하위',
      parentId: parent.id,
    );
    final unrelated = await controller.library.createFolder('연구실');
    final first = await create('첫 문서', _firstBody, folderId: nested.id);
    final second = await create('둘 문서', '''
---
rank: 10
active: false
status: 진행 중
---
둘째 본문 #실험
''', folderId: parent.id);
    await create(
      '다른 폴더',
      _firstBody.replaceFirst('rank: 2', 'rank: 1'),
      folderId: unrelated.id,
    );
    return (first, second);
  }

  Future<Set<String>> revisions() async => {
    for (final revision in await controller.repository.revisions())
      revision.revisionId,
  };

  Future<Object?> call(
    Map<String, dynamic> args, {
    VaultMcpCallContext? context,
  }) => service.call(
    _operation,
    args,
    context:
        context ??
        VaultMcpCallContext(isActive: () => true, canWrite: () => false),
  );

  Future<Map<String, dynamic>> query(String query) async =>
      Map<String, dynamic>.from(await call({'query': query}) as Map);
}
