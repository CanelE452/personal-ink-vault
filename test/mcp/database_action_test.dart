import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/mcp/vault_mcp_bridge.dart';
import 'package:saber/data/mcp/vault_mcp_service.dart';
import 'package:saber/data/native/ink_vault_native.dart';
import 'package:saber/data/vault/block_page_document.dart';
import 'package:saber/data/vault/block_page_media.dart';
import 'package:saber/data/vault/workspace_database.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/pages/workspace/mcp_panel.dart';
import 'package:saber/pages/workspace/workspace_controller.dart';

import '../../integration_test/support/windows_mcp_rpc.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final nativePath =
      Platform.environment['INK_VAULT_NATIVE_LIBRARY'] ??
      File('build/native/windows/ink_vault_native.dll').absolute.path;
  final nativeAvailable = Platform.isWindows && File(nativePath).existsSync();
  final mcpExe = Platform.environment['INK_VAULT_MCP_TEST_EXE'];
  final nativeSkip = !nativeAvailable
      ? 'Build the Windows Rust native library first'
      : false;
  late Directory temp;
  late WorkspaceController controller;
  late VaultMcpService service;
  late VaultNote note;
  late WorkspaceDatabase database;
  late DatabaseProperty status;
  late DatabaseRow row;
  late String title;
  late String revision;
  var canWrite = true;
  var active = true;
  final context = VaultMcpCallContext(
    isActive: () => active,
    canWrite: () => canWrite,
  );

  Future<void> saveFixture(WorkspaceDatabase value) async {
    final session = await WorkspaceStore(controller.repository).open(note);
    await session.saveInk({
      'future/opaque.bin': Uint8List.fromList([0, 128, 255]),
      'database.json': Uint8List.fromList(
        utf8.encode(jsonEncode(value.toJson())),
      ),
    });
    revision = session.inkParents.single;
  }

  setUp(() async {
    canWrite = true;
    active = true;
    temp = await Directory.systemTemp.createTemp('mcp-database-action-');
    controller = WorkspaceController(
      await NoteRepository.open(temp, createFormatVersion: 2),
      native: nativeAvailable
          ? InkVaultNative.open(libraryPath: nativePath)
          : null,
    );
    service = VaultMcpService(controller);
    database = WorkspaceDatabase.empty();
    title = database.properties.single.id;
    status = DatabaseProperty.create(
      name: '상태',
      type: 'status',
      config: {
        'options': ['todo', 'done'],
      },
    );
    row = DatabaseRow.fromJson({
      ...DatabaseRow.create(values: {title: '원래 항목', status.id: 'todo'})
          .toJson(),
      'futureRowMetadata': {'keep': true},
    });
    database = WorkspaceDatabase.fromJson({
      ...database.addProperty(status).addRow(row).toJson(),
      'futureDatabaseMetadata': {
        'keep': [1, 2],
      },
    });
    note = await WorkspaceStore(controller.repository)
        .create('연구 DB', documentKind: VaultDocumentKind.database);
    await saveFixture(database);
  });
  tearDown(() async {
    await controller.flush();
    controller.dispose();
    await controller.repository.close();
    await temp.delete(recursive: true);
  });

  Future<Map<String, dynamic>> call(
    String operation,
    Map<String, dynamic> args,
  ) async => Map<String, dynamic>.from(
    await service.call(operation, args, context: context) as Map,
  );
  Future<Map<String, dynamic>> action(String name, Map<String, dynamic> args) =>
      call('database_action', {
        'noteId': note.id,
        'expectedRevisionId': revision,
        'requestId': newId(),
        'action': name,
        ...args,
      });
  Future<WorkspaceDatabase> readSaved() async {
    final head = (await controller.repository.heads(note.inkEntityId)).single;
    final files = await controller.repository.readFiles(head);
    revision = head.revisionId;
    return WorkspaceDatabase.fromJson(
      jsonObject(jsonDecode(utf8.decode(files['database.json']!))),
    );
  }

  Map<String, dynamic> rule(
    String trigger,
    List<Map<String, dynamic>> actions, {
    String? id,
  }) => {
    'id': id ?? newId(),
    'version': 1,
    'name': '규칙',
    'enabled': true,
    'trigger': {
      'type': trigger,
      if (trigger == 'propertyChanged') 'propertyId': status.id,
    },
    'actions': actions,
  };
  Matcher error(String code) =>
      throwsA(isA<VaultMcpException>().having((e) => e.code, 'code', code));

  test('MCP writes and reads task links under existing revision and permission guards', () async {
    final parent = row.id;
    final dependency = DatabaseRow.create(values: {title: '선행'});
    await saveFixture(database.addRow(dependency));
    final newTask = await action('add_row', {
      'parentTaskId': parent,
      'values': {title: '하위 작업'},
    });
    final child = newTask['rowId'] as String;
    await readSaved();
    final request = {
      'noteId': note.id,
      'expectedRevisionId': revision,
      'requestId': newId(),
      'action': 'set_task_links',
      'rowId': child,
      'parentId': parent,
      'predecessorIds': [dependency.id],
    };
    canWrite = false;
    await expectLater(call('database_action', request), error('read_only'));
    canWrite = true;
    final updated = await call('database_action', request);
    expect(await call('database_action', request), updated);
    final saved = await readSaved();
    final readArgs = {
      'noteId': note.id,
      'expectedRevisionId': revision,
      'rowId': child,
    };
    canWrite = false;
    final linked = await call('database_task_links', readArgs);
    expect(linked['parentId'], parent);
    expect(linked['predecessorIds'], [dependency.id]);
    expect(linked['revisionId'], revision);
    expect(linked['archived'], isFalse);
    canWrite = true;
    await expectLater(
      action('set_task_links', {
        'rowId': parent,
        'parentId': child,
        'predecessorIds': [],
      }),
      error('task_link_cycle'),
    );
    final unchangedRevision = revision;
    final raw = saved.toJson()..remove('pivTaskLinks');
    await expectLater(
      call('update_document', {
        'noteId': note.id,
        'expectedRevisionId': revision,
        'requestId': newId(),
        'target': 'body',
        'content': raw,
      }),
      error('task_links_managed'),
    );
    final missingParent = saved.toJson();
    missingParent['rows'] = [
      for (final candidate in saved.rows)
        if (candidate.id != parent) candidate.toJson(),
    ];
    await expectLater(
      call('update_document', {
        'noteId': note.id,
        'expectedRevisionId': revision,
        'requestId': newId(),
        'target': 'body',
        'content': missingParent,
      }),
      error('task_links_managed'),
    );
    await readSaved();
    expect(revision, unchangedRevision);
    await action('set_task_links', {
      'rowId': child,
      'parentId': null,
      'predecessorIds': [],
    });
    await readSaved();
    await expectLater(
      call('database_task_links', readArgs),
      error('revision_conflict'),
    );
    final cleared = await call('database_task_links', {
      ...readArgs,
      'expectedRevisionId': revision,
    });
    expect(cleared['parentId'], isNull);
    expect(cleared['predecessorIds'], isEmpty);
  }, skip: nativeSkip);

  test(
    'Windows stdio edits task links and reads them from a large saved DB',
    () async {
      final child = DatabaseRow.create(values: {title: '하위 작업'});
      final predecessor = DatabaseRow.create(values: {title: '선행 작업'});
      await saveFixture(
        WorkspaceDatabase.fromJson({
          ...database.addRow(child).addRow(predecessor).toJson(),
          'futureLargeBody': 'x' * (1024 * 1024 + 64),
        }),
      );
      final access = McpAccessController(
        () => service,
        executable: mcpExe!,
        supportDirectory: () async => Directory('${temp.path}/support'),
      );
      await access.start();
      addTearDown(() async {
        await access.stop();
        access.dispose();
      });
      final server =
          (access.clientConfiguration['mcpServers']
                  as Map)['personal-ink-vault']
              as Map;
      final client = await WindowsMcpRpc.start(
        server['command'] as String,
        (server['args'] as List).last as String,
      );
      addTearDown(client.close);
      expect(await client.tools(), contains('database_task_links'));
      final document = await client.call('read_document', {'noteId': note.id});
      expect(document.isError, isFalse);
      expect((document.data['body'] as Map)['contentUnavailable'], 'too_large');
      final request = {
        'action': 'set_task_links',
        'noteId': note.id,
        'expectedRevisionId': revision,
        'requestId': newId(),
        'rowId': child.id,
        'parentId': row.id,
        'predecessorIds': [predecessor.id],
      };
      expect(
        (await client.call('database_action', request)).data['code'],
        'read_only',
      );
      await access.allowEdits(true);
      final edited = await client.call('database_action', request);
      expect(edited.isError, isFalse);
      expect((await client.call('database_action', request)).data, edited.data);
      await access.allowEdits(false);
      final linked = await client.call('database_task_links', {
        'noteId': note.id,
        'expectedRevisionId': edited.data['revisionId'],
        'rowId': child.id,
      });
      expect(linked.isError, isFalse);
      expect(linked.data['parentId'], row.id);
      expect(linked.data['predecessorIds'], [predecessor.id]);
    },
    skip: !nativeAvailable || mcpExe == null,
  );

  test('MCP can capture, apply, and remove a saved row template', () async {
    final blockId = newId();
    final withBody = database.updateRow(
      row.copyWith(
        body: {
          'version': 1,
          'blocks': [
            {'id': blockId, 'type': 'paragraph', 'text': '실험 순서'},
          ],
        },
      ),
    );
    database = WorkspaceDatabase.fromJson({
      ...withBody.toJson(),
      'automationRules': [
        rule('rowAdded', [
          {
            'id': newId(),
            'type': 'setStatus',
            'propertyId': status.id,
            'value': 'done',
          },
        ]),
      ],
    });
    await saveFixture(database);
    final captured = await action('create_row_template', {
      'rowId': row.id,
      'name': '실험 기록',
    });
    final templateId = captured['templateId'] as String;
    expect(captured['receipts'], isEmpty);
    await readSaved();
    final document = await call('read_document', {'noteId': note.id});
    final content = (document['body'] as Map)['content'] as Map;
    final templateItems = (content['pivRowTemplates'] as Map)['items'] as List;
    expect(templateItems.single, containsPair('id', templateId));

    final addArgs = {
      'noteId': note.id,
      'expectedRevisionId': revision,
      'requestId': newId(),
      'action': 'add_row',
      'templateId': templateId,
      'values': {title: '두 번째 실험'},
    };
    final added = await call('database_action', addArgs);
    expect(added['receipts'], hasLength(1));
    expect(await call('database_action', addArgs), added);
    final saved = await readSaved();
    final created = saved.rows.singleWhere((row) => row.id == added['rowId']);
    expect(saved.rows, hasLength(2));
    expect(created.values[title], '두 번째 실험');
    expect(created.values[status.id], 'done');
    final copied = (created.body['blocks'] as List).single as Map;
    expect(copied['text'], '실험 순서');
    expect(copied['id'], isNot(blockId));
    expect(saved.rows.first.toJson(), withBody.rows.first.toJson());

    await action('delete_row_template', {'templateId': templateId});
    final withoutTemplate = await readSaved();
    expect(withoutTemplate.rowTemplates, isEmpty);
    expect(
      withoutTemplate.rows.map((row) => row.toJson()),
      saved.rows.map((row) => row.toJson()),
    );
  }, skip: nativeSkip);

  test(
    'MCP can configure a recurring template on the connected device',
    () async {
      final captured = await action('create_row_template', {
        'rowId': row.id,
        'name': '연간 회고',
      });
      final templateId = captured['templateId'] as String;
      await readSaved();
      canWrite = false;
      final vault = await call('vault_status', {});
      expect(vault['deviceId'], controller.repository.deviceId);
      final definition = {
        ...rule('schedule', [
          {
            'id': newId(),
            'type': 'addRowFromTemplate',
            'templateId': templateId,
            'values': <String, Object?>{},
          },
        ]),
        'ownerDeviceId': vault['deviceId'],
        'trigger': {
          'type': 'schedule',
          'frequency': 'yearly',
          'interval': 1,
          'startDate': '2026-11-08',
          'time': '09:00',
          'timeZone': 'Asia/Seoul',
        },
      };
      await expectLater(
        action('put_rule', {'rule': definition}),
        error('read_only'),
      );
      canWrite = true;
      final result = await action('put_rule', {'rule': definition});
      expect(result['receipts'], isEmpty);
      var saved = await readSaved();
      expect(saved.rows, hasLength(1));
      expect(saved.toJson()['automationRules'], [definition]);
      await expectLater(
        action('delete_row_template', {'templateId': templateId}),
        error('invalid_arguments'),
      );
      expect((await readSaved()).rowTemplates.single.id, templateId);
      await action('archive_rule', {'ruleId': definition['id']});
      await readSaved();
      await action('delete_row_template', {'templateId': templateId});
      saved = await readSaved();
      expect(saved.rowTemplates, isEmpty);
    },
    skip: nativeSkip,
  );

  test(
    'MCP refuses to publish a row from a template with missing retained media',
    () async {
      final blockId = newId();
      final attachment = BlockPageMediaAsset.attachment(
        name: '결과.txt',
        bytes: utf8.encode('synthetic evidence'),
      );
      final body = const BlockPageDocument.empty().copyWith(
        blocks: [
          BlockPageBlock.fromJson({
            'id': blockId,
            'type': 'attachment',
            'text': '결과 파일',
          }),
        ],
        media: {blockId: attachment.reference},
      );
      final templateId = newId();
      final malformed = database
          .updateRow(row.copyWith(body: body.toJson()))
          .captureRowTemplate(rowId: row.id, templateId: templateId, name: '결과')
          .updateRow(row);
      await saveFixture(malformed);
      final before = revision;
      await expectLater(
        action('add_row', {'templateId': templateId}),
        error('invalid_arguments'),
      );
      expect((await readSaved()).toJson(), malformed.toJson());
      expect(revision, before);
    },
    skip: nativeSkip,
  );

  test('actual MCP Rust button commits effects and receipt once and survives service recreation', () async {
    final manual = rule('manual', [
      {
        'id': newId(),
        'type': 'setStatus',
        'propertyId': status.id,
        'value': 'done',
      },
      {
        'id': newId(),
        'type': 'addRow',
        'values': {title: '후속 항목'},
      },
    ]);
    database = WorkspaceDatabase.fromJson({
      ...database.toJson(),
      'automationRules': [manual],
    });
    await saveFixture(database);
    final before = (await controller.repository.revisions()).length;
    final old = revision;
    final args = {
      'noteId': note.id,
      'expectedRevisionId': old,
      'requestId': newId(),
      'action': 'run_button',
      'ruleId': manual['id'],
      'rowId': row.id,
    };
    final result = await call('database_action', args);
    final saved = await readSaved();
    expect(result['revisionId'], revision);
    expect(result['receipts'], hasLength(1));
    expect(saved.rows, hasLength(2));
    expect(saved.rows.first.values[status.id], 'done');
    expect(saved.rows.last.values[title], '후속 항목');
    expect(saved.rows.first.toJson()['futureRowMetadata'], {'keep': true});
    expect(saved.toJson()['futureDatabaseMetadata'], {
      'keep': [1, 2],
    });
    expect(saved.toJson()['automationExecutions'], result['receipts']);
    expect(
      (await controller.repository.readFiles(
        (await controller.repository.heads(note.inkEntityId)).single,
      ))['future/opaque.bin'],
      [0, 128, 255],
    );
    expect((await controller.repository.revisions()).length, before + 1);
    expect(
      (await controller.repository.heads(note.inkEntityId))
          .single
          .parentRevisionIds,
      [old],
    );
    service = VaultMcpService(controller);
    expect(await call('database_action', args), result);
    expect((await controller.repository.revisions()).length, before + 1);
    await expectLater(
      call('database_action', {...args, 'requestId': newId()}),
      error('revision_conflict'),
    );
    expect((await readSaved()).rows, hasLength(2));
  }, skip: nativeSkip);

  test('typed cell and row additions run matching Rust rules atomically without cascades', () async {
    database = WorkspaceDatabase.fromJson({
      ...database.toJson(),
      'automationRules': [
        rule('propertyChanged', [
          {
            'id': newId(),
            'type': 'addRow',
            'values': {title: '상태 변경 후속'},
          },
        ]),
        rule('rowAdded', [
          {
            'id': newId(),
            'type': 'setStatus',
            'propertyId': status.id,
            'value': 'done',
          },
        ]),
      ],
    });
    await saveFixture(database);
    final changed = await action('set_cell', {
      'rowId': row.id,
      'propertyId': status.id,
      'value': 'done',
    });
    var saved = await readSaved();
    expect(changed['receipts'], hasLength(1));
    expect(saved.rows, hasLength(2));
    expect(saved.rows.first.values[status.id], 'done');
    expect(saved.rows.last.values[title], '상태 변경 후속');
    final unchanged = await action('set_cell', {
      'rowId': row.id,
      'propertyId': status.id,
      'value': 'done',
    });
    expect(unchanged['revisionId'], revision);
    expect(unchanged['receipts'], isEmpty);
    final added = await action('add_row', {
      'values': {title: 'AI가 추가', status.id: 'todo'},
    });
    saved = await readSaved();
    expect(added['receipts'], hasLength(1));
    expect(saved.rows, hasLength(3));
    expect(
      saved.rows
          .singleWhere((item) => item.id == added['rowId'])
          .values[status.id],
      'done',
    );
    expect(saved.toJson()['automationExecutions'], hasLength(2));
  }, skip: nativeSkip);

  test('rule writes preserve unknown fields and archive creates the next immutable body revision', () async {
    final raw = rule('manual', [
      {
        'id': newId(),
        'type': 'addRow',
        'values': {title: '항목'},
      },
    ])..['futureRuleMetadata'] = {'keep': true};
    final inserted = await action('put_rule', {'rule': raw});
    var saved = await readSaved();
    expect(inserted['receipts'], isEmpty);
    expect((saved.toJson()['automationRules'] as List).single['version'], 1);
    final update = {
      ...raw,
      'name': '갱신',
      'futureRuleMetadata': {'keep': true},
    }..remove('version');
    await action('put_rule', {'rule': update});
    saved = await readSaved();
    expect((saved.toJson()['automationRules'] as List).single['version'], 2);
    await action('archive_rule', {'ruleId': raw['id']});
    saved = await readSaved();
    final archived = (saved.toJson()['automationRules'] as List).single;
    expect(archived['version'], 3);
    expect(archived['enabled'], false);
    expect(archived['archived'], true);
    expect(archived['futureRuleMetadata'], {'keep': true});
  }, skip: nativeSkip);

  test('new MCP databases reject injected execution receipts before publishing a document', () async {
    final before = (await controller.repository.revisions()).length;
    for (final ledger in [
      null,
      [
        {'id': newId(), 'status': 'completed'},
      ],
      <String, dynamic>{},
      'invalid',
    ]) {
      await expectLater(
        call('create_document', {
          'title': '실행 기록 주입',
          'kind': 'database',
          'body': {
            ...WorkspaceDatabase.empty().toJson(),
            'automationExecutions': ledger,
          },
          'requestId': newId(),
        }),
        error('invalid_arguments'),
      );
    }
    expect(
      (await WorkspaceStore(controller.repository).list()).single.id,
      note.id,
    );
    expect((await controller.repository.revisions()).length, before);
  });

  test('new MCP databases allow absent or empty execution receipts and preserve rule definitions', () async {
    for (final includeEmptyLedger in [false, true]) {
      final raw = WorkspaceDatabase.empty().toJson();
      final propertyId =
          ((raw['properties'] as List).single as Map)['id'] as String;
      final definitions = [
        rule('manual', [
          {
            'id': newId(),
            'type': 'addRow',
            'values': {propertyId: '항목'},
          },
        ]),
      ];
      raw['automationRules'] = definitions;
      raw['futureMetadata'] = {'keep': true};
      if (includeEmptyLedger) raw['automationExecutions'] = [];
      final created = await call('create_document', {
        'title': '새 DB',
        'kind': 'database',
        'body': raw,
        'requestId': newId(),
      });
      final savedNote = (await WorkspaceStore(
        controller.repository,
      ).list()).singleWhere((item) => item.id == created['noteId']);
      final head = (await controller.repository.heads(savedNote.inkEntityId))
          .single;
      final savedFiles = await controller.repository.readFiles(head);
      final saved = jsonObject(
        jsonDecode(utf8.decode(savedFiles['database.json']!)),
      );
      expect(head.revisionId, created['bodyRevisionId']);
      expect(saved['automationRules'], definitions);
      expect(saved['futureMetadata'], {'keep': true});
      expect(saved.containsKey('automationExecutions'), includeEmptyLedger);
      if (includeEmptyLedger) expect(saved['automationExecutions'], isEmpty);
    }
  });

  test('raw body updates cannot forge delete or alter server managed execution receipts', () async {
    final manual = rule('manual', [
      {
        'id': newId(),
        'type': 'addRow',
        'values': {title: '항목'},
      },
    ]);
    database = WorkspaceDatabase.fromJson({
      ...database.toJson(),
      'automationRules': [manual],
    });
    await saveFixture(database);
    await action('run_button', {'ruleId': manual['id']});
    final saved = await readSaved();
    final before = (await controller.repository.revisions()).length;
    for (final ledger in [
      null,
      [],
      [
        {'id': newId()},
      ],
    ]) {
      final json = {...saved.toJson()};
      if (ledger == null) {
        json.remove('automationExecutions');
      } else {
        json['automationExecutions'] = ledger;
      }
      await expectLater(
        call('update_document', {
          'noteId': note.id,
          'expectedRevisionId': revision,
          'requestId': newId(),
          'target': 'body',
          'content': json,
        }),
        error('invalid_arguments'),
      );
    }
    expect((await controller.repository.revisions()).length, before);
    final json = saved.toJson();
    json['automationExecutions'] = [
      for (final item in json['automationExecutions'] as List)
        {
          for (final key in (item as Map).keys.toList().reversed)
            key: item[key],
        },
    ];
    await call('update_document', {
      'noteId': note.id,
      'expectedRevisionId': revision,
      'requestId': newId(),
      'target': 'body',
      'content': json,
    });
    expect(
      (await readSaved()).toJson()['automationExecutions'],
      saved.toJson()['automationExecutions'],
    );
    expect(
      (await controller.repository.readFiles(
        (await controller.repository.heads(note.inkEntityId)).single,
      ))['future/opaque.bin'],
      [0, 128, 255],
    );
  }, skip: nativeSkip);

  test('database actions enforce typed inputs archived rows stale revisions and exact fields before writes', () async {
    final archived = row.copyWith(archived: true);
    database = database
        .updateRow(archived)
        .addProperty(DatabaseProperty.create(name: '계산', type: 'formula'));
    await saveFixture(database);
    final before = (await controller.repository.revisions()).length;
    for (final args in [
      {
        'action': 'set_cell',
        'rowId': row.id,
        'propertyId': status.id,
        'value': 'done',
      },
      {'action': 'set_cell', 'rowId': row.id, 'propertyId': title},
      {
        'action': 'add_row',
        'values': {newId(): 'unknown'},
      },
      {
        'action': 'add_row',
        'values': {status.id: 'unknown'},
      },
      {
        'action': 'add_row',
        'values': {database.properties.last.id: 3},
      },
      {'action': 'add_row', 'values': {}, 'rowId': newId()},
      {'action': 'put_rule', 'rule': {}, 'value': 'extra'},
    ]) {
      await expectLater(
        call('database_action', {
          'noteId': note.id,
          'expectedRevisionId': revision,
          'requestId': newId(),
          ...args,
        }),
        error('invalid_arguments'),
      );
    }
    expect((await controller.repository.revisions()).length, before);
  }, skip: nativeSkip);

  test('database action requires live write permission and a supported native engine', () async {
    final previousRepository = controller.repository;
    await controller.flush();
    controller.dispose();
    await previousRepository.close();
    controller = WorkspaceController(await NoteRepository.open(temp));
    service = VaultMcpService(controller);
    final before = (await controller.repository.revisions()).length;
    await expectLater(
      action('add_row', {
        'values': {title: '행'},
      }),
      error('unsupported'),
    );
    canWrite = false;
    await expectLater(
      action('add_row', {
        'values': {title: '행'},
      }),
      error('read_only'),
    );
    canWrite = true;
    active = false;
    await expectLater(
      action('add_row', {
        'values': {title: '행'},
      }),
      error('authorization_revoked'),
    );
    expect((await controller.repository.revisions()).length, before);
  });
}
