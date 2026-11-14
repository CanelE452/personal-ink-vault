import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/vault/block_page_document.dart';
import 'package:saber/data/vault/database_actions.dart';
import 'package:saber/data/vault/workspace_database.dart';

void main() {
  late WorkspaceDatabase database;
  late String device, ruleId, eventId, revision, rowId, propertyId;
  late List<Map<String, Object?>> calls;
  late Map<String, dynamic> Function(Map<String, Object?>) respond;
  late DatabaseActionRuntime runtime;
  const captured = 1793343600000;

  Map<String, dynamic> rule() => {
    'id': ruleId,
    'version': 1,
    'name': '버튼',
    'enabled': true,
    'trigger': {
      'type': 'manual',
      'future': {
        'keep': [1],
      },
    },
    'actions': [
      {
        'id': newId(),
        'type': 'addRow',
        'values': {propertyId: '생성'},
        'future': [2],
      },
    ],
    'future': {
      'keep': [3],
    },
  };
  Map<String, dynamic> receipt(Map<String, Object?> request) => {
    'id': newId(),
    'ruleId': ruleId,
    'ruleVersion': 1,
    'eventId': eventId,
    'eventDigest': 'a' * 64,
    'ruleDigest': 'b' * 64,
    'inputRevision': revision,
    'deviceId': device,
    'capturedAtUtcMs': captured,
    'status': 'completed',
    'actionResults': [],
    'future': {
      'keep': [4],
    },
  };
  Map<String, dynamic> prepared(Map<String, Object?> request) {
    final record = receipt(request);
    return {
      'database': {
        ...database.toJson(),
        'automationExecutions': [record],
      },
      'receipts': [record],
      'duplicate': false,
      'changed': true,
    };
  }

  setUp(() {
    device = newId();
    ruleId = newId();
    eventId = newId();
    revision = newId();
    rowId = newId();
    propertyId = newId();
    database = WorkspaceDatabase.fromJson({
      'id': newId(),
      'schemaVersion': 1,
      'properties': [
        {'id': propertyId, 'name': '이름', 'type': 'title', 'config': {}},
      ],
      'rows': [
        {
          'id': rowId,
          'values': {propertyId: '행'},
          'archived': false,
        },
      ],
      'views': [],
      'futureRoot': {
        'nested': [1, 2],
      },
      'forms': [
        {'untouched': true},
      ],
      'automationRules': [rule()],
    });
    calls = [];
    respond = (request) =>
        request['mode'] == 'validate' ? {'valid': true} : prepared(request);
    runtime = DatabaseActionRuntime(
      deviceId: device,
      invoke: (request) {
        calls.add(request);
        return respond(request);
      },
    );
  });

  test('validation uses the Rust workspace_actions operation with the exact snapshot', () {
    runtime.validate(database);
    expect(calls.single['op'], 'workspace_actions');
    expect(calls.single['mode'], 'validate');
    expect(calls.single['deviceId'], device);
    expect(calls.single['database'], database.toJson());
  });
  test('rules and execution views are deeply read-only and detached', () {
    final rules = runtime.rules(database);
    expect(() => rules.add({}), throwsUnsupportedError);
    expect(
      () => (rules.first['future'] as Map)['keep'] = [],
      throwsUnsupportedError,
    );
    expect(runtime.receipts(database), isEmpty);
    expect(database.toJson()['futureRoot'], {
      'nested': [1, 2],
    });
  });
  test('putRule preserves unknown fields and increments its version once', () {
    final updated = runtime.putRule(database, {'id': ruleId, 'name': '다른 버튼'});
    final next = runtime.rules(updated).single;
    expect(next['name'], '다른 버튼');
    expect(next['version'], 2);
    expect(next['future'], runtime.rules(database).single['future']);
    expect(next['trigger'], runtime.rules(database).single['trigger']);
    expect(next['actions'], runtime.rules(database).single['actions']);
    expect(updated.toJson()['futureRoot'], database.toJson()['futureRoot']);
    expect(updated.toJson()['forms'], database.toJson()['forms']);
    expect(calls.single['mode'], 'validate');
    expect((calls.single['database'] as Map)['automationRules'], [next]);
  });
  test('new rules start at one and archive preserves unsupported future definitions', () {
    final id = newId();
    final created = runtime.putRule(database, {
      ...rule(),
      'id': id,
      'version': 99,
    });
    expect(runtime.rules(created).last['version'], 1);
    final future = WorkspaceDatabase.fromJson({
      ...created.toJson(),
      'automationRules': [
        ...runtime.rules(created),
        {
          'id': newId(),
          'version': 8,
          'name': '미래',
          'enabled': true,
          'trigger': {'type': 'future'},
          'actions': [
            {'opaque': 1},
          ],
          'unknown': [9],
        },
      ],
    });
    final target = runtime.rules(future).last;
    final archived = runtime
        .rules(runtime.archiveRule(future, target['id'] as String))
        .last;
    expect(archived, {
      ...target,
      'version': 9,
      'enabled': false,
      'archived': true,
    });
  });
  test('manual prepare passes captured identities unchanged and trusts native result', () {
    final result = runtime.prepareManual(
      database,
      ruleId: ruleId,
      eventId: eventId,
      rowId: rowId,
      inputRevision: revision,
      capturedAtUtcMs: captured,
    );
    expect(calls.single['mode'], 'apply');
    expect(calls.single['ruleId'], ruleId);
    expect(calls.single['event'], {
      'id': eventId,
      'type': 'manual',
      'rowId': rowId,
      'origin': 'button',
    });
    expect(calls.single['inputRevision'], revision);
    expect(calls.single['capturedAtUtcMs'], captured);
    expect(result.changed, isTrue);
    expect(result.receipts.single['eventId'], eventId);
    expect(result.database.toJson()['futureRoot'], {
      'nested': [1, 2],
    });
    expect(() => result.request['deviceId'] = 'other', throwsUnsupportedError);
    expect(
      () => result.receipts.single['future'] = null,
      throwsUnsupportedError,
    );
  });
  test('row and property events go to Rust without Dart action evaluation', () {
    respond = (_) => {
      'database': database.toJson(),
      'receipts': [],
      'duplicate': false,
      'changed': false,
    };
    runtime.prepareRowAdded(
      database,
      rowId: rowId,
      origin: 'form',
      inputRevision: revision,
      capturedAtUtcMs: captured,
    );
    expect(calls.last['event'], {
      'type': 'rowAdded',
      'rowId': rowId,
      'origin': 'form',
    });
    runtime.preparePropertyChanged(
      database,
      eventId: eventId,
      rowId: rowId,
      propertyId: propertyId,
      oldValue: '이전',
      value: '새 값',
      inputRevision: revision,
      capturedAtUtcMs: captured,
    );
    expect(calls.last['event'], {
      'id': eventId,
      'type': 'propertyChanged',
      'rowId': rowId,
      'propertyId': propertyId,
      'oldValue': '이전',
      'value': '새 값',
      'origin': 'user',
    });
    expect((calls.last['database'] as Map)['rows'], database.toJson()['rows']);
  });
  test('schedule due cursors and exact UTC slots remain engine-owned', () {
    final cursor = {
      'signature': 'c' * 64,
      'ruleIndex': 0,
      'localDate': '2026-10-30',
    };
    final event = {
      'ruleId': ruleId,
      'event': {
        'id': eventId,
        'type': 'schedule',
        'scheduledForUtcMs': captured - 1000,
      },
    };
    respond = (_) => {
      'events': [event],
      'hasMore': true,
      'cursor': cursor,
    };
    final batch = runtime.due(database, capturedAtUtcMs: captured);
    expect(batch.events, [event]);
    expect(batch.hasMore, isTrue);
    expect(batch.cursor, cursor);
    runtime.due(database, capturedAtUtcMs: captured, cursor: batch.cursor);
    expect(calls.last['cursor'], cursor);
    respond = (_) => {
      'database': database.toJson(),
      'receipts': [],
      'duplicate': false,
      'changed': false,
    };
    runtime.prepareScheduled(
      database,
      ruleId: ruleId,
      scheduledForUtcMs: captured - 1000,
      inputRevision: revision,
      capturedAtUtcMs: captured,
    );
    expect(calls.last['event'], {
      'type': 'schedule',
      'scheduledForUtcMs': captured - 1000,
      'origin': 'user',
    });
  });
  test(
    'scheduled template receipt is returned with a complete independent row',
    () {
      final templateId = newId(), generatedId = newId(), actionId = newId();
      final originalBlock = BlockPageBlock.create(
        type: 'paragraph',
        text: 'agenda',
      );
      database = database
          .updateRow(
            database.rows.single.copyWith(
              body: const BlockPageDocument.empty()
                  .copyWith(blocks: [originalBlock])
                  .toJson(),
            ),
          )
          .captureRowTemplate(
            rowId: rowId,
            templateId: templateId,
            name: 'Review',
          );
      final overrides = {propertyId: 'New review'};
      database = WorkspaceDatabase.fromJson({
        ...database.toJson(),
        'automationRules': [
          {
            ...rule(),
            'trigger': {'type': 'schedule'},
            'actions': [
              {
                'id': actionId,
                'type': 'addRowFromTemplate',
                'templateId': templateId,
                'values': overrides,
              },
            ],
          },
        ],
      });
      var omitTemplate = false;
      respond = (request) {
        if (request['mode'] == 'validateSnapshot') return {'valid': true};
        final record = receipt(request)
          ..['actionResults'] = [
            {
              'actionId': actionId,
              'type': 'addRow',
              'rowId': generatedId,
              if (!omitTemplate) 'templateId': templateId,
            },
          ];
        return {
          ...prepared(request),
          'database': {
            ...database
                .addRow(DatabaseRow.create(id: generatedId, values: overrides))
                .toJson(),
            'automationExecutions': [record],
          },
          'receipts': [record],
        };
      };
      DatabaseActionPrepared run() => runtime.prepareScheduled(
        database,
        ruleId: ruleId,
        scheduledForUtcMs: captured,
        inputRevision: revision,
        capturedAtUtcMs: captured,
      );
      final result = run();
      final generated = result.database.rows.last;
      expect(generated.id, generatedId);
      expect(generated.values, overrides);
      final copiedBlock = BlockPageDocument.fromJson(generated.body)
          .blocks
          .single;
      expect(copiedBlock.text, originalBlock.text);
      expect(copiedBlock.id, isNot(originalBlock.id));
      expect(calls.first['materializeTemplates'], isTrue);
      expect(calls.last['mode'], 'validateSnapshot');
      expect(calls.last['database'], result.database.toJson());
      expect(database.rows.single.id, rowId);
      omitTemplate = true;
      expect(run, throwsA(isA<DatabaseActionException>()));
    },
  );
  test('native errors retain their code and do not mutate the database', () {
    respond = (_) => {
      'error': {'code': 'invalid_value', 'message': 'typed value'},
    };
    expect(
      () => runtime.validate(database),
      throwsA(
        isA<DatabaseActionException>().having(
          (e) => e.code,
          'code',
          'invalid_value',
        ),
      ),
    );
    expect(database.toJson()['automationExecutions'], isNull);
  });
  test(
    'foreign database identities and malformed native results are refused',
    () {
      respond = (request) => {
        ...prepared(request),
        'database': {...database.toJson(), 'id': newId()},
      };
      expect(
        () => runtime.prepareManual(
          database,
          ruleId: ruleId,
          eventId: eventId,
          inputRevision: revision,
          capturedAtUtcMs: captured,
        ),
        throwsA(isA<DatabaseActionException>()),
      );
      respond = (request) => {...prepared(request), 'changed': 'yes'};
      expect(
        () => runtime.prepareManual(
          database,
          ruleId: ruleId,
          eventId: eventId,
          inputRevision: revision,
          capturedAtUtcMs: captured,
        ),
        throwsA(isA<DatabaseActionException>()),
      );
      respond = (request) => {
        ...prepared(request),
        'receipts': [
          {'id': newId()},
        ],
      };
      expect(
        () => runtime.prepareManual(
          database,
          ruleId: ruleId,
          eventId: eventId,
          inputRevision: revision,
          capturedAtUtcMs: captured,
        ),
        throwsA(isA<DatabaseActionException>()),
      );
    },
  );
  test(
    'a malformed due batch cannot inject manual or foreign scheduled events',
    () {
      respond = (_) => {
        'events': [
          {
            'ruleId': newId(),
            'event': {'type': 'manual', 'id': eventId},
          },
        ],
        'hasMore': false,
      };
      expect(
        () => runtime.due(database, capturedAtUtcMs: captured),
        throwsA(isA<DatabaseActionException>()),
      );
      respond = (_) => {'events': [], 'hasMore': true};
      expect(
        () => runtime.due(database, capturedAtUtcMs: captured),
        throwsA(isA<DatabaseActionException>()),
      );
    },
  );
  test(
    'invalid captured identities are rejected before invoking the engine',
    () {
      expect(
        () => runtime.prepareManual(
          database,
          ruleId: ruleId,
          eventId: 'bad',
          inputRevision: revision,
          capturedAtUtcMs: captured,
        ),
        throwsA(isA<DatabaseActionException>()),
      );
      expect(calls, isEmpty);
    },
  );

  test('due lower bounds are forwarded unchanged and omitted when absent', () {
    respond = (_) => {'events': [], 'hasMore': false};
    runtime.due(
      database,
      capturedAtUtcMs: captured,
      sinceUtcMs: captured - 3000,
    );
    expect(calls.last['sinceUtcMs'], captured - 3000);
    runtime.due(database, capturedAtUtcMs: captured);
    expect(calls.last.containsKey('sinceUtcMs'), isFalse);
    respond = (_) => {
      'error': {'code': 'invalid_time', 'message': 'future lower bound'},
    };
    expect(
      () => runtime.due(
        database,
        capturedAtUtcMs: captured,
        sinceUtcMs: captured + 1,
      ),
      throwsA(
        isA<DatabaseActionException>().having(
          (error) => error.code,
          'code',
          'invalid_time',
        ),
      ),
    );
  });
}
