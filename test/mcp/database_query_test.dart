import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/mcp/vault_mcp_bridge.dart';
import 'package:saber/data/mcp/vault_mcp_service.dart';
import 'package:saber/data/native/ink_vault_native.dart';
import 'package:saber/data/vault/workspace_database.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/pages/workspace/workspace_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final nativePath =
      Platform.environment['INK_VAULT_NATIVE_LIBRARY'] ??
      File('build/native/windows/ink_vault_native.dll').absolute.path;
  final nativeAvailable = Platform.isWindows && File(nativePath).existsSync();
  final nativeSkip = nativeAvailable
      ? false
      : 'Build the Windows Rust native library first';
  late Directory temp;
  late WorkspaceController controller;
  late VaultMcpService service;
  late VaultNote note, relatedNote;
  late WorkspaceDatabase database, related;
  late DatabaseProperty amount, formula, relation, rollup, date;
  late DatabaseRow row;
  late String revision, relatedRevision;
  final context = VaultMcpCallContext(
    isActive: () => true,
    canWrite: () => false,
  );

  Future<String> save(VaultNote target, WorkspaceDatabase value) async {
    final session = await controller.store.open(target);
    await session.saveInk({
      'database.json': Uint8List.fromList(
        utf8.encode(jsonEncode(value.toJson())),
      ),
      'future/opaque.bin': Uint8List.fromList([0, 128, 255]),
    });
    return session.inkParents.single;
  }

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('mcp-database-query-');
    controller = WorkspaceController(
      await NoteRepository.open(temp, createFormatVersion: 2),
      native: nativeAvailable
          ? InkVaultNative.open(libraryPath: nativePath)
          : null,
    );
    service = VaultMcpService(controller);
    related = WorkspaceDatabase.empty();
    final weight = DatabaseProperty.create(name: '가중치', type: 'number');
    final relatedRow = DatabaseRow.create(values: {weight.id: 7});
    related = related.addProperty(weight).addRow(relatedRow);
    relatedNote = await controller.store.create(
      '관계 DB',
      documentKind: VaultDocumentKind.database,
    );
    relatedRevision = await save(relatedNote, related);
    database = WorkspaceDatabase.empty();
    amount = DatabaseProperty.create(name: '수량', type: 'number');
    formula = DatabaseProperty.create(
      name: '두 배',
      type: 'formula',
      config: {'expression': 'prop("${amount.id}") * 2'},
    );
    relation = DatabaseProperty.create(
      name: '관계',
      type: 'relation',
      config: {'databaseId': related.id},
    );
    rollup = DatabaseProperty.create(
      name: '가중치 합',
      type: 'rollup',
      config: {
        'relationPropertyId': relation.id,
        'targetPropertyId': weight.id,
        'calculation': 'sum',
      },
    );
    date = DatabaseProperty.create(name: '날짜', type: 'date');
    row = DatabaseRow.create(
      values: {
        database.properties.single.id: '연구 항목',
        amount.id: 3,
        date.id: '2026-10-30',
        relation.id: [
          {'databaseId': related.id, 'rowId': relatedRow.id},
        ],
      },
    );
    database = database.copyWith(
      properties: [
        ...database.properties,
        amount,
        formula,
        relation,
        rollup,
        date,
      ],
      rows: [row],
    );
    note = await controller.store.create(
      '연구 DB',
      documentKind: VaultDocumentKind.database,
    );
    revision = await save(note, database);
  });
  tearDown(() async {
    await controller.flush();
    controller.dispose();
    await controller.repository.close();
    await temp.delete(recursive: true);
  });

  Map<String, dynamic> arguments() => {
    'noteId': note.id,
    'expectedRevisionId': revision,
    'relatedDatabases': [
      {'noteId': relatedNote.id, 'expectedRevisionId': relatedRevision},
    ],
    'capturedAtUtc': '2026-10-30T12:00:00.000Z',
    'operations': [
      {'type': 'value', 'rowId': row.id, 'propertyId': formula.id},
    ],
  };
  Future<Map<String, dynamic>> query(Map<String, dynamic> args) async =>
      Map<String, dynamic>.from(
        await service.call('database_query', args, context: context) as Map,
      );
  Matcher error(String code) =>
      throwsA(isA<VaultMcpException>().having((e) => e.code, 'code', code));

  test('read-only MCP query uses persisted Rust calculations and related revisions without writing', () async {
    final before = await controller.repository.revisions();
    final view = database.views.single.toJson();
    final title = database.properties.first.id;
    final result = await query({
      ...arguments(),
      'operations': [
        {'type': 'apply', 'view': view},
        {
          'type': 'values',
          'from': 0,
          'propertyIds': [formula.id, rollup.id],
        },
        {'type': 'aggregate', 'propertyId': amount.id, 'from': 0},
        {'type': 'calendar', 'propertyId': date.id, 'view': view},
        {'type': 'chart', 'groupBy': title, 'view': view},
        {'type': 'value', 'rowId': row.id, 'propertyId': formula.id},
      ],
    });
    expect(result['noteId'], note.id);
    expect(result['databaseId'], database.id);
    expect(result['revisionId'], revision);
    expect(result['capturedAtUtc'], '2026-10-30T12:00:00.000Z');
    expect(result['inputs'], [
      {
        'noteId': note.id,
        'databaseId': database.id,
        'revisionId': revision,
        'metadataRevisionId': note.revision.revisionId,
      },
      {
        'noteId': relatedNote.id,
        'databaseId': related.id,
        'revisionId': relatedRevision,
        'metadataRevisionId': relatedNote.revision.revisionId,
      },
    ]);
    final results = result['results'] as List;
    expect(results[0]['rowIds'], [row.id]);
    expect(results[1][0]['values'], [
      {'propertyId': formula.id, 'value': 6},
      {'propertyId': rollup.id, 'value': 7},
    ]);
    expect(results[2], {'value': 3});
    expect(results[3][0]['start'], '2026-10-30T00:00:00.000Z');
    expect(results[4][0]['label'], '연구 항목');
    expect(results[5], {'value': 6});
    expect(result['errors'], isEmpty);
    expect(result['remainingBudget'], lessThan(10000));
    expect(
      (await controller.repository.revisions()).map((r) => r.revisionId),
      before.map((r) => r.revisionId),
    );
    final files = await controller.repository.readFiles(
      (await controller.repository.heads(note.inkEntityId)).single,
    );
    expect(jsonDecode(utf8.decode(files['database.json']!)), database.toJson());
    expect(files['future/opaque.bin'], [0, 128, 255]);
  }, skip: nativeSkip);

  test('MCP query exposes computed faults and budget exhaustion rather than a Dart fallback', () async {
    final result = await query({
      ...arguments(),
      'budget': 1,
      'operations': [
        {'type': 'value', 'rowId': row.id, 'propertyId': formula.id},
        {'type': 'value', 'rowId': row.id, 'propertyId': rollup.id},
      ],
    });
    expect(result['remainingBudget'], lessThan(0));
    expect(result['errors'], isNotEmpty);
    expect(result['results'][0]['error']['code'], 'budget_exceeded');
    expect(result['results'][0]['value'], isNull);
  }, skip: nativeSkip);

  test('MCP query rejects lone UTF-16 results explicitly while preserving valid supplementary text', () async {
    database = database.updateProperty(
      formula.copyWith(config: {'expression': '"😀"'}),
    );
    revision = await save(note, database);
    expect((await query(arguments()))['results'][0]['value'], '😀');
    database = database.updateProperty(
      formula.copyWith(config: {'expression': '"\\uD800"'}),
    );
    revision = await save(note, database);
    final before = (await controller.repository.revisions()).length;
    await expectLater(query(arguments()), error('unsupported_text_encoding'));
    expect((await controller.repository.revisions()).length, before);
  }, skip: nativeSkip);

  test('MCP query rejects stale main and related heads, foreign revisions and duplicate database identities', () async {
    await expectLater(
      query({...arguments(), 'expectedRevisionId': relatedRevision}),
      error('revision_conflict'),
    );
    final updated = related.addRow(DatabaseRow.create());
    await save(relatedNote, updated);
    await expectLater(query(arguments()), error('revision_conflict'));
    relatedRevision = (await controller.repository.heads(
      relatedNote.inkEntityId,
    )).single.revisionId;
    await save(relatedNote, database);
    relatedRevision = (await controller.repository.heads(
      relatedNote.inkEntityId,
    )).single.revisionId;
    await expectLater(query(arguments()), error('ambiguous_database'));
  });

  test('MCP query rejects non-database documents and invalid bounded input before native execution', () async {
    final other = await controller.store.create(
      'Markdown',
      documentKind: VaultDocumentKind.markdown,
    );
    await expectLater(
      query({...arguments(), 'noteId': other.id}),
      error('invalid_document_kind'),
    );
    for (final extra in <Map<String, dynamic>>[
      {'capturedAtUtc': '2026-10-30'},
      {'capturedAtUtc': '2026-10-30T12:00:00+09:00'},
      {'capturedAtUtc': '2026-02-31T00:00:00.000Z'},
      {'maxDepth': 129},
      {'budget': 1000001},
      {'database': database.toJson()},
      {
        'operations': List.generate(
          513,
          (_) => {'type': 'value', 'rowId': row.id, 'propertyId': formula.id},
        ),
      },
      {
        'relatedDatabases': List.generate(
          65,
          (_) => {
            'noteId': relatedNote.id,
            'expectedRevisionId': relatedRevision,
          },
        ),
      },
    ]) {
      await expectLater(
        query({...arguments(), ...extra}),
        error('invalid_arguments'),
      );
    }
  });

  test('MCP query without a native engine is an explicit read error and preserves the vault', () async {
    final noNative = WorkspaceController(controller.repository);
    service = VaultMcpService(noNative);
    final before = (await controller.repository.revisions()).length;
    try {
      await expectLater(query(arguments()), error('native_unavailable'));
      expect((await controller.repository.revisions()).length, before);
    } finally {
      noNative.dispose();
    }
  });
}
