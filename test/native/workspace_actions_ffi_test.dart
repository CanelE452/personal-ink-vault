import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/native/ink_vault_native.dart';
import 'package:saber/data/vault/database_actions.dart';
import 'package:saber/data/vault/workspace_database.dart';

void main() {
  final path =
      Platform.environment['INK_VAULT_NATIVE_LIBRARY'] ??
      File('build/native/windows/ink_vault_native.dll').absolute.path;
  final available = Platform.isWindows && File(path).existsSync();
  final device = newId();
  late InkVaultNative native;
  late WorkspaceDatabase database;
  late String title;
  late DatabaseProperty status;
  late DatabaseRow row;
  setUp(() {
    if (!available) return;
    native = InkVaultNative.open(libraryPath: path);
    database = WorkspaceDatabase.empty();
    title = database.properties.single.id;
    status = DatabaseProperty.create(
      name: '상태',
      type: 'status',
      config: {
        'options': [
          {'id': 'todo', 'name': '대기'},
          {'id': 'done', 'name': '완료'},
        ],
      },
    );
    row = DatabaseRow.create(values: {title: '원래 항목', status.id: 'todo'});
    database = database.addProperty(status).addRow(row);
  });

  Map<String, dynamic> withRule(Map<String, dynamic> rule) => {
    ...database.toJson(),
    'unknown': {'preserve': true},
    'automationRules': [rule],
  };

  test('actual Rust ABI atomically sets typed status adds a row and reuses its receipt', () {
    final ruleId = newId();
    final db = withRule({
      'id': ruleId,
      'version': 1,
      'name': '완료하고 후속 항목 추가',
      'enabled': true,
      'trigger': {'type': 'manual'},
      'actions': [
        {
          'id': newId(),
          'type': 'setStatus',
          'rowId': row.id,
          'propertyId': status.id,
          'value': 'done',
        },
        {
          'id': newId(),
          'type': 'addRow',
          'values': {title: '후속 작업'},
        },
      ],
    });
    final before = jsonEncode(db);
    expect(
      native.invoke({
        'op': 'workspace_actions',
        'mode': 'validate',
        'database': db,
        'deviceId': device,
      })['valid'],
      true,
    );
    final request = <String, Object?>{
      'op': 'workspace_actions',
      'database': db,
      'ruleId': ruleId,
      'deviceId': device,
      'inputRevision': newId(),
      'capturedAtUtcMs': 1793322000000,
      'event': {'id': newId(), 'type': 'manual', 'origin': 'button'},
    };
    final result = native.invoke(request);
    final saved = WorkspaceDatabase.fromJson(
      Map<String, dynamic>.from(result['database'] as Map),
    );
    expect(saved.rows, hasLength(2));
    expect(
      saved.rows.firstWhere((item) => item.id == row.id).values[status.id],
      'done',
    );
    expect(saved.rows.last.values[title], '후속 작업');
    expect(saved.toJson()['unknown'], {'preserve': true});
    expect(result['receipts'], hasLength(1));
    final retry = native.invoke({
      ...request,
      'database': saved.toJson(),
      'inputRevision': newId(),
      'capturedAtUtcMs': 1793408400000,
    });
    expect(retry['duplicate'], true);
    expect(retry['changed'], false);
    expect(retry['database'], saved.toJson());
    expect(jsonEncode(db), before);
    final runtime = DatabaseActionRuntime(
      deviceId: device,
      invoke: native.invoke,
    );
    final typed = WorkspaceDatabase.fromJson(db);
    runtime.validate(typed);
    final fromGateway = runtime.prepareManual(
      typed,
      ruleId: ruleId,
      eventId: (request['event'] as Map)['id'] as String,
      inputRevision: request['inputRevision'] as String,
      capturedAtUtcMs: request['capturedAtUtcMs'] as int,
    );
    expect(fromGateway.database.toJson(), saved.toJson());
  }, skip: !available ? 'Build the Windows Rust native library first' : false);

  test(
    'actual Rust ABI plans Seoul schedule and persists one canonical UTC slot',
    () {
      final ruleId = newId();
      final db = withRule({
        'id': ruleId,
        'version': 1,
        'name': '서울 오전 9시',
        'enabled': true,
        'ownerDeviceId': device,
        'trigger': {
          'type': 'schedule',
          'frequency': 'daily',
          'interval': 1,
          'timeZone': 'Asia/Seoul',
          'startDate': '2026-10-30',
          'time': '09:00',
          'ambiguous': 'earlier',
          'gap': 'skip',
        },
        'actions': [
          {
            'id': newId(),
            'type': 'addRow',
            'values': {title: '정기 항목'},
          },
        ],
      });
      final captured = DateTime.utc(2026, 10, 30, 1).millisecondsSinceEpoch;
      final runtime = DatabaseActionRuntime(
        deviceId: device,
        invoke: native.invoke,
      );
      final typed = WorkspaceDatabase.fromJson(db);
      final due = runtime.due(typed, capturedAtUtcMs: captured);
      final event = Map<String, dynamic>.from(
        due.events.single['event'] as Map,
      );
      expect(
        event['scheduledForUtcMs'],
        DateTime.utc(2026, 10, 30).millisecondsSinceEpoch,
      );
      final applied = runtime.prepareScheduled(
        typed,
        ruleId: ruleId,
        scheduledForUtcMs: event['scheduledForUtcMs'] as int,
        inputRevision: newId(),
        capturedAtUtcMs: captured,
      );
      final after = runtime.due(applied.database, capturedAtUtcMs: captured);
      expect(after.events, isEmpty);
      expect(applied.database.rows, hasLength(2));
      final afterHorizon = runtime.due(
        typed,
        capturedAtUtcMs: DateTime.utc(2026, 11, 2, 1).millisecondsSinceEpoch,
        sinceUtcMs: DateTime.utc(2026, 11, 1, 1).millisecondsSinceEpoch,
      );
      expect(afterHorizon.events, hasLength(1));
      expect(
        (afterHorizon.events.single['event'] as Map)['scheduledForUtcMs'],
        DateTime.utc(2026, 11, 2).millisecondsSinceEpoch,
      );
    },
    skip: !available ? 'Build the Windows Rust native library first' : false,
  );

  test('actual gateway treats numeric and date representations as the same typed values', () {
    final number = DatabaseProperty.create(name: '개수', type: 'number');
    final date = DatabaseProperty.create(name: '날짜', type: 'date');
    database = database
        .addProperty(number)
        .addProperty(date)
        .setCell(row.id, number.id, 1)
        .setCell(row.id, date.id, {'start': null, 'dateISO': '2026-10-30'});
    final rule = newId();
    final input = WorkspaceDatabase.fromJson(
      withRule({
        'id': rule,
        'version': 1,
        'name': '같은 값',
        'enabled': true,
        'trigger': {'type': 'manual'},
        'condition': {
          'and': [
            {'propertyId': number.id, 'operator': 'eq', 'value': 1.0},
            {'propertyId': date.id, 'operator': 'eq', 'value': '2026-10-30'},
          ],
        },
        'actions': [
          {
            'id': newId(),
            'type': 'addRow',
            'values': {title: '조건 확인'},
          },
        ],
      }),
    );
    final runtime = DatabaseActionRuntime(
      deviceId: device,
      invoke: native.invoke,
    );
    runtime.validate(input);
    final result = runtime.prepareManual(
      input,
      ruleId: rule,
      eventId: newId(),
      rowId: row.id,
      inputRevision: newId(),
      capturedAtUtcMs: DateTime.utc(2026, 10, 30).millisecondsSinceEpoch,
    );
    expect(result.database.rows, hasLength(2));
    expect(result.receipts.single['status'], 'completed');
    expect(result.database.rows.last.values[title], '조건 확인');
  }, skip: !available ? 'Build the Windows Rust native library first' : false);
}
