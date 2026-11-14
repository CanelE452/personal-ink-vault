import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/vault/database_actions.dart';
import 'package:saber/data/vault/workspace_database.dart';
import 'package:saber/pages/workspace/database_automations_panel.dart';

void main() {
  late WorkspaceDatabase database;
  late String device, revision, ruleId, titleId, statusId, rowId;
  late List<Map<String, Object?>> calls;
  late List<WorkspaceDatabase> saved;
  late Future<void> Function(WorkspaceDatabase) persist;
  late Map<String, dynamic> Function(Map<String, Object?>) respond;
  late DatabaseActionRuntime runtime;
  final dirty = <bool>[], busy = <bool>[];

  setUp(() {
    device = newId();
    revision = newId();
    ruleId = newId();
    titleId = newId();
    statusId = newId();
    rowId = newId();
    database = WorkspaceDatabase.fromJson({
      'id': newId(),
      'schemaVersion': 1,
      'properties': [
        {'id': titleId, 'name': '이름', 'type': 'title', 'config': {}},
        {
          'id': statusId,
          'name': '상태',
          'type': 'status',
          'config': {
            'options': [
              {'id': 'todo', 'name': '할 일'},
              {'id': 'done', 'name': '완료'},
            ],
          },
        },
      ],
      'rows': [
        {
          'id': rowId,
          'values': {titleId: '대상 행', statusId: 'todo'},
          'archived': false,
        },
      ],
      'views': [],
      'automationRules': [
        {
          'id': ruleId,
          'version': 1,
          'name': '완료 버튼',
          'enabled': true,
          'trigger': {'type': 'manual'},
          'actions': [
            {
              'id': newId(),
              'type': 'setStatus',
              'propertyId': statusId,
              'value': 'done',
              'rowId': rowId,
            },
          ],
          'future': {
            'keep': [9],
          },
        },
      ],
      'futureRoot': {
        'keep': [1],
      },
    });
    calls = [];
    saved = [];
    dirty.clear();
    busy.clear();
    persist = (value) async {
      saved.add(value);
    };
    respond = (request) {
      if (request['mode'] == 'validate') return {'valid': true};
      if (request['mode'] == 'due') return {'events': [], 'hasMore': false};
      final input = Map<String, dynamic>.from(request['database'] as Map);
      final event = Map<String, dynamic>.from(request['event'] as Map);
      final rule = (input['automationRules'] as List).cast<Map>().singleWhere(
        (r) => r['id'] == request['ruleId'],
      );
      final record = {
        'id': newId(),
        'ruleId': rule['id'],
        'ruleVersion': rule['version'],
        'eventId': event['id'] ?? newId(),
        'eventDigest': 'a' * 64,
        'ruleDigest': 'b' * 64,
        'inputRevision': request['inputRevision'],
        'deviceId': device,
        'capturedAtUtcMs': request['capturedAtUtcMs'],
        'status': 'completed',
        'actionResults': [],
      };
      return {
        'database': {
          ...input,
          'automationExecutions': [
            ...?input['automationExecutions'] as List?,
            record,
          ],
        },
        'receipts': [record],
        'changed': true,
        'duplicate': false,
      };
    };
    runtime = DatabaseActionRuntime(
      deviceId: device,
      invoke: (request) {
        calls.add(request);
        return respond(request);
      },
    );
  });

  Future<GlobalKey<DatabaseAutomationsPanelState>> mount(
    WidgetTester tester,
  ) async {
    final key = GlobalKey<DatabaseAutomationsPanelState>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DatabaseAutomationsPanel(
            key: key,
            initialDatabase: database,
            runtime: runtime,
            currentRevision: () => revision,
            onSave: (value) => persist(value),
            onBack: () {},
            onDirtyChanged: dirty.add,
            onBusyChanged: busy.add,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    addTearDown(() => tester.pumpWidget(const SizedBox()));
    return key;
  }

  Future<void> tap(WidgetTester tester, String key) async {
    final finder = find.byKey(ValueKey(key));
    await tester.ensureVisible(finder);
    await tester.pump();
    expect(finder.hitTestable(), findsOneWidget);
    await tester.tap(finder);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
  }

  Future<void> text(WidgetTester tester, String key, String value) async {
    final finder = find.byKey(ValueKey(key));
    await tester.ensureVisible(finder);
    await tester.pump();
    await tester.enterText(finder, value);
    await tester.pump();
  }

  testWidgets(
    'rule definitions can be named saved and reopened with unknown JSON',
    (tester) async {
      final key = await mount(tester);
      await text(tester, 'actions-rule-name', '수정한 버튼');
      await key.currentState!.save();
      await tester.pumpAndSettle();
      final rule = runtime.rules(saved.single).single;
      expect(rule['name'], '수정한 버튼');
      expect(rule['version'], 2);
      expect(rule['future'], {
        'keep': [9],
      });
      expect(saved.single.toJson()['futureRoot'], {
        'keep': [1],
      });
      database = saved.single;
      await tester.pumpWidget(const SizedBox());
      await mount(tester);
      expect(find.text('수정한 버튼'), findsWidgets);
      expect(dirty.last, isFalse);
    },
  );
  testWidgets('create supports several addRow property and status actions', (
    tester,
  ) async {
    final key = await mount(tester);
    await tap(tester, 'actions-create-rule');
    await text(tester, 'actions-rule-name', '업무 버튼');
    await tap(tester, 'actions-add-setProperty');
    await tap(tester, 'actions-add-setStatus');
    await key.currentState!.save();
    await tester.pumpAndSettle();
    final rule = runtime.rules(saved.last).last;
    expect((rule['actions'] as List).map((a) => (a as Map)['type']), [
      'addRow',
      'setProperty',
      'setStatus',
    ]);
    expect(rule['name'], '업무 버튼');
  });
  testWidgets(
    'manual execution is successful only after its atomic save finishes',
    (tester) async {
      final waiting = Completer<void>();
      persist = (value) {
        saved.add(value);
        return waiting.future;
      };
      await mount(tester);
      await tap(tester, 'actions-run-$ruleId');
      expect(calls.where((c) => c['mode'] == 'apply'), hasLength(1));
      expect(saved, hasLength(1));
      expect(saved.single.toJson()['automationExecutions'], hasLength(1));
      expect(find.text('실행 결과를 저장했습니다.'), findsNothing);
      expect(busy.last, isTrue);
      waiting.complete();
      await tester.pumpAndSettle();
      expect(find.text('실행 결과를 저장했습니다.'), findsOneWidget);
      expect(dirty.last, isFalse);
      await tap(tester, 'actions-history-tab');
      expect(find.text('완료'), findsWidgets);
    },
  );
  testWidgets(
    'a failed action save retries the exact snapshot without another Rust apply',
    (tester) async {
      var fail = true;
      persist = (value) async {
        saved.add(value);
        if (fail) throw StateError('저장 실패');
      };
      final key = await mount(tester);
      await tap(tester, 'actions-run-$ruleId');
      expect(find.textContaining('저장 실패'), findsWidgets);
      expect(dirty.last, isTrue);
      final before = jsonEncode(saved.single.toJson());
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const ValueKey('actions-rule-name')),
            )
            .enabled,
        isFalse,
      );
      expect(runtime.rules(key.currentState!.database).single['name'], '완료 버튼');
      fail = false;
      revision = newId();
      await tap(tester, 'actions-retry');
      expect(saved, hasLength(2));
      expect(jsonEncode(saved.last.toJson()), before);
      expect(calls.where((c) => c['mode'] == 'apply'), hasLength(1));
      expect(find.text('실행 결과를 저장했습니다.'), findsOneWidget);
    },
  );
  testWidgets(
    'public save shares one future and drains edits typed while saving',
    (tester) async {
      final waiting = Completer<void>();
      persist = (value) async {
        saved.add(value);
        if (saved.length == 1) await waiting.future;
      };
      final key = await mount(tester);
      await text(tester, 'actions-rule-name', '첫 이름');
      final a = key.currentState!.save(), b = key.currentState!.save();
      expect(identical(a, b), isTrue);
      await tester.pump();
      await text(tester, 'actions-rule-name', '마지막 이름');
      waiting.complete();
      await a;
      await tester.pumpAndSettle();
      expect(saved, hasLength(2));
      expect(runtime.rules(saved.last).single['name'], '마지막 이름');
      expect(dirty.last, isFalse);
    },
  );
  testWidgets(
    'schedule builder persists IANA time owner and repeated-time policy',
    (tester) async {
      final key = await mount(tester);
      final type = tester.widget<DropdownButtonFormField<String>>(
        find.byKey(const ValueKey('actions-trigger')),
      );
      type.onChanged!('schedule');
      await tester.pumpAndSettle();
      await text(tester, 'actions-schedule-startDate', '2026-10-30');
      await text(tester, 'actions-schedule-time', '09:15');
      await text(tester, 'actions-schedule-timeZone', 'Asia/Seoul');
      final frequency = tester.widget<DropdownButtonFormField<String>>(
        find.byKey(const ValueKey('actions-schedule-frequency')),
      );
      frequency.onChanged!('weekly');
      final fold = tester.widget<DropdownButtonFormField<String>>(
        find.byKey(const ValueKey('actions-schedule-ambiguous')),
      );
      fold.onChanged!('later');
      await tester.pump();
      await tap(tester, 'actions-take-owner');
      await key.currentState!.save();
      await tester.pumpAndSettle();
      final rule = runtime.rules(saved.last).single;
      expect(rule['ownerDeviceId'], device);
      expect(rule['trigger'], containsPair('timeZone', 'Asia/Seoul'));
      expect(rule['trigger'], containsPair('frequency', 'weekly'));
      expect(rule['trigger'], containsPair('ambiguous', 'later'));
      expect(find.textContaining('앱이 열려'), findsWidgets);
    },
  );
  testWidgets('unsupported advanced rules stay intact and can be archived', (
    tester,
  ) async {
    final raw = database.toJson();
    final future = {
      ...((raw['automationRules'] as List).single as Map),
      'trigger': {'type': 'future'},
      'custom': {
        'keep': [1],
      },
    };
    database = WorkspaceDatabase.fromJson({
      ...raw,
      'automationRules': [future],
    });
    final original = respond;
    respond = (request) {
      if (request['mode'] == 'validate' &&
          (((request['database'] as Map)['automationRules'] as List).any(
            (rule) => (rule as Map)['trigger']['type'] == 'future',
          ))) {
        return {
          'error': {'code': 'unsupported_trigger', 'message': 'future trigger'},
        };
      }
      return original(request);
    };
    final key = await mount(tester);
    expect(find.textContaining('원문을 보존'), findsWidgets);
    await tap(tester, 'actions-archive-rule');
    await key.currentState!.save();
    await tester.pumpAndSettle();
    final archived = runtime.rules(saved.last).single;
    expect(archived['custom'], {
      'keep': [1],
    });
    expect(archived['trigger'], {'type': 'future'});
    expect(archived['enabled'], isFalse);
    expect(archived['version'], 2);
  });
  testWidgets(
    'phone320 and tablet layouts keep controls usable without overflow',
    (tester) async {
      for (final width in [320.0, 1100.0]) {
        tester.view.physicalSize = Size(width, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await mount(tester);
        expect(
          find.byKey(const ValueKey('actions-create-rule')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      }
    },
  );

  testWidgets('condition groups can be edited and preserved with the rule', (
    tester,
  ) async {
    final key = await mount(tester);
    await tap(tester, 'actions-add-condition');
    final kind = tester.widget<DropdownButtonFormField<String>>(
      find.byKey(const ValueKey('actions-condition-kind-root')),
    );
    kind.onChanged!('and');
    await tester.pumpAndSettle();
    await tap(tester, 'actions-condition-add-root');
    await key.currentState!.save();
    await tester.pumpAndSettle();
    final condition = runtime.rules(saved.single).single['condition'] as Map;
    expect(condition['and'], hasLength(2));
    expect(
      (condition['and'] as List).first,
      containsPair('propertyId', titleId),
    );
  });

  testWidgets('due schedule events can be inspected and saved exactly once', (
    tester,
  ) async {
    final raw = database.toJson();
    final rule = Map<String, dynamic>.from(
      (raw['automationRules'] as List).single as Map,
    );
    database = WorkspaceDatabase.fromJson({
      ...raw,
      'automationRules': [
        {
          ...rule,
          'ownerDeviceId': device,
          'trigger': {
            'type': 'schedule',
            'frequency': 'daily',
            'interval': 1,
            'startDate': '2026-10-30',
            'time': '09:00',
            'timeZone': 'Asia/Seoul',
            'ambiguous': 'earlier',
            'gap': 'skip',
          },
        },
      ],
    });
    final original = respond;
    int? slot;
    respond = (request) {
      if (request['mode'] == 'due') {
        slot = (request['capturedAtUtcMs'] as int) - 1000;
        return {
          'events': [
            {
              'ruleId': ruleId,
              'event': {
                'id': newId(),
                'type': 'schedule',
                'scheduledForUtcMs': slot,
              },
            },
          ],
          'hasMore': false,
        };
      }
      return original(request);
    };
    await mount(tester);
    await tap(tester, 'actions-schedule-tab');
    await tap(tester, 'actions-check-due');
    await tap(tester, 'actions-run-due-$ruleId-$slot');
    expect(saved, hasLength(1));
    expect(calls.where((request) => request['mode'] == 'apply'), hasLength(1));
    expect(find.text('실행 결과를 저장했습니다.'), findsOneWidget);
    expect(find.byKey(ValueKey('actions-run-due-$ruleId-$slot')), findsNothing);
  });
}
