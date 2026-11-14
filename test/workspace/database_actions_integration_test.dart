import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart' show newId;
import 'package:saber/data/native/ink_vault_native.dart';
import 'package:saber/data/vault/database_actions.dart';
import 'package:saber/data/vault/database_forms.dart';
import 'package:saber/data/vault/workspace_database.dart';
import 'package:saber/pages/workspace/database_automations_panel.dart';
import 'package:saber/pages/workspace/database_editor.dart';

const titleId = '00000000-0000-4000-8000-000000000001';
const numberId = '00000000-0000-4000-8000-000000000002';
const statusId = '00000000-0000-4000-8000-000000000003';
const rowId = '00000000-0000-4000-8000-000000000004';
const ruleId = '00000000-0000-4000-8000-000000000005';
const formId = '00000000-0000-4000-8000-000000000006';
const revision = '00000000-0000-4000-8000-000000000007';
const laterRevision = '00000000-0000-4000-8000-000000000008';
const deviceId = '00000000-0000-4000-8000-000000000009';

WorkspaceDatabase fixture({
  String trigger = 'propertyChanged',
  bool invalid = false,
}) {
  var db = WorkspaceDatabase.empty().copyWith(
    properties: [
      DatabaseProperty.create(id: titleId, name: '이름', type: 'title'),
      DatabaseProperty.create(id: numberId, name: '개수', type: 'number'),
      DatabaseProperty.create(
        id: statusId,
        name: '상태',
        type: 'status',
        config: {
          'options': ['todo', 'done'],
        },
      ),
    ],
    rows: [
      DatabaseRow.create(
        id: rowId,
        values: {titleId: '원래 항목', numberId: 1, statusId: 'todo'},
      ),
    ],
  );
  db = DatabaseForms(db).putForm(
    DatabaseForm.create(
      id: formId,
      title: '접수',
      questions: [
        DatabaseFormQuestion.create(
          propertyId: titleId,
          label: '제목',
          required: true,
        ),
      ],
    ),
  );
  return WorkspaceDatabase.fromJson({
    ...db.toJson(),
    'future': {
      'keep': [1, 2],
    },
    'automationRules': [
      {
        'id': ruleId,
        'version': 1,
        'name': '자동 처리',
        'enabled': true,
        'trigger': {
          'type': trigger,
          if (trigger == 'propertyChanged') 'propertyId': numberId,
        },
        'actions': [
          {
            'id': newId(),
            'type': invalid ? 'unsupportedFutureAction' : 'setStatus',
            'propertyId': statusId,
            'value': 'done',
          },
          {
            'id': newId(),
            'type': 'addRow',
            'values': {titleId: '자동 생성'},
          },
        ],
      },
    ],
  });
}

void main() {
  final libraryPath =
      Platform.environment['INK_VAULT_NATIVE_LIBRARY'] ??
      File('build/native/windows/ink_vault_native.dll').absolute.path;
  final available = Platform.isWindows && File(libraryPath).existsSync();
  late InkVaultNative native;
  late List<Map<String, Object?>> calls;
  late DatabaseActionRuntime runtime;
  setUp(() {
    calls = [];
    if (!available) return;
    native = InkVaultNative.open(libraryPath: libraryPath);
    runtime = DatabaseActionRuntime(
      deviceId: deviceId,
      invoke: (request) {
        calls.add(request);
        return native.invoke(request);
      },
    );
  });
  List<Map<String, Object?>> preparations() =>
      calls.where((request) => request['mode'] == 'apply').toList();
  Future<GlobalKey<DatabaseEditorState>> mount(
    WidgetTester tester, {
    WorkspaceDatabase? initial,
    Future<void> Function(WorkspaceDatabase)? save,
    String Function()? currentRevision,
    ValueChanged<bool>? busy,
    ValueChanged<bool>? dirty,
  }) async {
    tester.view.physicalSize = const Size(1100, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final key = GlobalKey<DatabaseEditorState>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DatabaseEditor(
            key: key,
            initialDatabase: initial ?? fixture(),
            actionRuntime: runtime,
            currentRevision: currentRevision ?? () => revision,
            onSave: save ?? (_) async {},
            onBack: () {},
            onBusyChanged: busy,
            onDirtyChanged: dirty,
            autosaveDelay: const Duration(hours: 1),
          ),
        ),
      ),
    );
    return key;
  }

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  Future<void> edit(
    WidgetTester tester,
    String value, {
    bool close = true,
  }) async {
    await tap(tester, find.byKey(const ValueKey('db-cell-$rowId-$numberId')));
    await tester.enterText(find.byKey(const ValueKey('db-cell-input')), value);
    await tester.pump();
    if (close) await tap(tester, find.text('닫기'));
  }

  Future<void> flush(WidgetTester tester, DatabaseEditorState state) async {
    final saved = state.save();
    await tester.pumpAndSettle();
    await saved;
    await tester.pumpAndSettle();
  }

  test('withDatabase preserves form receipt and row identities while accepting expanded action rows', () {
    final db = fixture();
    final submitted = DatabaseForms(db).prepareSubmission(
      formId: formId,
      answers: {titleId: '접수'},
      requestId: newId(),
      inputRevision: revision,
      capturedAt: DateTime.utc(2026, 10, 30),
    );
    final expanded = submitted.database.addRow(
      DatabaseRow.create(values: {titleId: '자동 처리'}),
    );
    final result = submitted.withDatabase(expanded);
    expect(result.database.toJson(), expanded.toJson());
    expect(result.rowId, submitted.rowId);
    expect(result.receipt.toJson(), submitted.receipt.toJson());
    expect(result.duplicate, submitted.duplicate);
    expect(
      () => submitted.withDatabase(WorkspaceDatabase.empty()),
      throwsA(isA<DatabaseFormException>()),
    );
    expect(
      () => submitted.withDatabase(expanded.removeRow(submitted.rowId)),
      throwsA(isA<DatabaseFormException>()),
    );
    final changed = expanded.toJson();
    changed['formSubmissions'][0]['inputRevision'] = laterRevision;
    expect(
      () => submitted.withDatabase(WorkspaceDatabase.fromJson(changed)),
      throwsA(isA<DatabaseFormException>()),
    );
  });

  testWidgets(
    'cell confirmation prepares Rust actions once and persists one complete snapshot',
    (tester) async {
      final snapshots = <WorkspaceDatabase>[];
      var reads = 0;
      final key = await mount(
        tester,
        save: (db) async {
          snapshots.add(db);
        },
        currentRevision: () {
          reads++;
          return revision;
        },
      );
      await edit(tester, '4.5', close: false);
      expect(preparations(), isEmpty);
      await tap(tester, find.text('닫기'));
      expect(preparations(), hasLength(1));
      expect(key.currentState!.database.rows, hasLength(2));
      expect(key.currentState!.database.rows.first.values[statusId], 'done');
      await flush(tester, key.currentState!);
      expect(snapshots, hasLength(1));
      expect(snapshots.single.rows.first.values[numberId], 4.5);
      expect(
        runtime.receipts(snapshots.single).single['inputRevision'],
        revision,
      );
      expect(reads, 1);
    },
    skip: !available,
  );

  testWidgets(
    'cell cancel and identical value are noops without action events',
    (tester) async {
      var saves = 0;
      var reads = 0;
      var dirty = false;
      final original = fixture();
      final key = await mount(
        tester,
        initial: original,
        dirty: (value) => dirty = value,
        save: (_) async {
          saves++;
        },
        currentRevision: () {
          reads++;
          return revision;
        },
      );
      await edit(tester, '9', close: false);
      await tap(tester, find.text('입력 취소'));
      expect(key.currentState!.database.toJson(), original.toJson());
      expect(preparations(), isEmpty);
      await edit(tester, '1');
      await flush(tester, key.currentState!);
      expect(preparations(), isEmpty);
      expect(reads, 0);
      expect(saves, 0);
      expect(dirty, false);
    },
    skip: !available,
  );

  testWidgets(
    'failed action preparation preserves original database and allows explicit cancel',
    (tester) async {
      final original = fixture(invalid: true);
      var saves = 0;
      final key = await mount(
        tester,
        initial: original,
        save: (_) async {
          saves++;
        },
      );
      await edit(tester, '7', close: false);
      await tap(tester, find.text('닫기'));
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(key.currentState!.database.toJson(), original.toJson());
      expect(saves, 0);
      await tap(tester, find.text('입력 취소'));
      await flush(tester, key.currentState!);
      expect(saves, 0);
    },
    skip: !available,
  );

  testWidgets('manual row creation runs rowAdded before a single save', (
    tester,
  ) async {
    WorkspaceDatabase? saved;
    final key = await mount(
      tester,
      initial: fixture(trigger: 'rowAdded'),
      save: (db) async {
        saved = db;
      },
    );
    await tap(tester, find.text('항목 추가'));
    expect(key.currentState!.database.rows, hasLength(3));
    expect(preparations(), hasLength(1));
    await flush(tester, key.currentState!);
    expect(saved!.rows, hasLength(3));
    expect(runtime.receipts(saved!), hasLength(1));
  }, skip: !available);

  testWidgets(
    'saved row template creates an independent body and runs rowAdded once',
    (tester) async {
      final initial = fixture(trigger: 'rowAdded');
      final blockId = newId();
      WorkspaceDatabase? saved;
      final key = await mount(
        tester,
        initial: initial.updateRow(
          initial.rows.single.copyWith(
            body: {
              'version': 1,
              'blocks': [
                {'id': blockId, 'type': 'paragraph', 'text': '반복해서 쓰는 본문'},
              ],
            },
          ),
        ),
        save: (db) async => saved = db,
      );
      await tap(tester, find.byTooltip('항목 메뉴'));
      await tap(tester, find.text('템플릿으로 저장'));
      await tester.enterText(
        find.byKey(const ValueKey('db-row-template-name')),
        '연구 기록',
      );
      await tap(tester, find.text('템플릿 저장'));
      expect(preparations(), isEmpty);

      await tap(tester, find.text('항목 추가'));
      expect(find.text('빈 항목'), findsOneWidget);
      await tap(tester, find.text('연구 기록'));
      expect(preparations(), hasLength(1));
      await flush(tester, key.currentState!);
      final restored = WorkspaceDatabase.fromJson(saved!.toJson());
      final created = restored.rows.singleWhere(
        (row) => row.id != rowId && row.values[titleId] == '원래 항목',
      );
      final copiedBlock = (created.body['blocks'] as List).single as Map;
      expect(copiedBlock['id'], isNot(blockId));
      expect(copiedBlock['text'], '반복해서 쓰는 본문');
      expect(created.values[numberId], 1);
      expect(created.values[statusId], 'done');
      expect(restored.rows, hasLength(3));
      expect(runtime.receipts(restored), hasLength(1));
    },
    skip: !available,
  );

  testWidgets(
    'saved row template opens a yearly schedule without creating a row',
    (tester) async {
      final templateId = newId();
      final initial = fixture().captureRowTemplate(
        rowId: rowId,
        templateId: templateId,
        name: '연구 기록',
      );
      WorkspaceDatabase? saved;
      final key = await mount(
        tester,
        initial: initial,
        save: (db) async => saved = db,
      );

      await tap(tester, find.text('항목 추가'));
      await tap(tester, find.byTooltip('반복 일정 설정'));
      expect(find.byType(DatabaseAutomationsPanel), findsOneWidget);
      final frequency = tester.widget<DropdownButtonFormField<String>>(
        find.byKey(const ValueKey('actions-schedule-frequency')),
      );
      frequency.onChanged!('yearly');
      await tester.pumpAndSettle();
      await flush(tester, key.currentState!);

      final rule = runtime
          .rules(saved!)
          .singleWhere((rule) => rule['id'] != ruleId);
      expect(rule['ownerDeviceId'], deviceId);
      expect(rule['name'], contains('연구 기록'));
      expect(rule['trigger'], containsPair('type', 'schedule'));
      expect(rule['trigger'], containsPair('frequency', 'yearly'));
      final action = (rule['actions'] as List).single as Map;
      expect(action['type'], 'addRowFromTemplate');
      expect(action['templateId'], templateId);
      expect(action['values'], isEmpty);
      expect(saved!.rows.single.id, rowId);
      expect(preparations(), isEmpty);
    },
    skip: !available,
  );

  testWidgets(
    'failed snapshot save retries exact cell event and receipt without recapturing metadata',
    (tester) async {
      final snapshots = <WorkspaceDatabase>[];
      var current = revision;
      var reads = 0;
      final key = await mount(
        tester,
        currentRevision: () {
          reads++;
          return current;
        },
        save: (db) async {
          snapshots.add(db);
          if (snapshots.length == 1) throw StateError('disk');
        },
      );
      await edit(tester, '6');
      await expectLater(key.currentState!.save(), throwsStateError);
      current = laterRevision;
      await flush(tester, key.currentState!);
      expect(snapshots, hasLength(2));
      expect(snapshots[1].toJson(), snapshots[0].toJson());
      expect(reads, 1);
      expect(preparations(), hasLength(1));
    },
    skip: !available,
  );

  testWidgets(
    'parent save commits final open cell draft before writing and closes its input route',
    (tester) async {
      final write = Completer<void>();
      var saves = 0;
      var done = false;
      addTearDown(() {
        if (!write.isCompleted) write.complete();
      });
      final key = await mount(
        tester,
        save: (_) async {
          saves++;
          await write.future;
        },
      );
      await edit(tester, '8', close: false);
      final saved = key.currentState!.save().then((_) {
        done = true;
      });
      for (var frame = 0; frame < 30 && saves == 0; frame++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(saves, 1);
      expect(done, false);
      expect(preparations(), hasLength(1));
      expect(key.currentState!.database.rows, hasLength(2));
      expect(key.currentState!.database.rows.first.values[numberId], 8);
      write.complete();
      await saved;
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(key.currentState!.database.rows.first.values[statusId], 'done');
    },
    skip: !available,
  );

  testWidgets(
    'automation panel owns busy state and row-target manual execution returns its saved database',
    (tester) async {
      final snapshots = <WorkspaceDatabase>[];
      var busy = false;
      final key = await mount(
        tester,
        initial: fixture(trigger: 'manual'),
        busy: (value) => busy = value,
        save: (db) async {
          snapshots.add(db);
        },
      );
      await tap(tester, find.byTooltip('버튼·자동화'));
      expect(find.byType(DatabaseAutomationsPanel), findsOneWidget);
      expect(busy, true);
      await tap(tester, find.byKey(const ValueKey('actions-run-$ruleId')));
      expect(snapshots, hasLength(1));
      expect(snapshots.single.rows.first.values[statusId], 'done');
      expect(snapshots.single.rows, hasLength(2));
      await flush(tester, key.currentState!);
      expect(find.byType(DatabaseAutomationsPanel), findsNothing);
      expect(key.currentState!.database.toJson(), snapshots.single.toJson());
      expect(busy, false);
      expect(snapshots, hasLength(1));
    },
    skip: !available,
  );

  testWidgets(
    'form rowAdded hook expands cached prepared snapshot once across save failure and parent flush',
    (tester) async {
      final snapshots = <WorkspaceDatabase>[];
      final key = await mount(
        tester,
        initial: fixture(trigger: 'rowAdded'),
        save: (db) async {
          snapshots.add(db);
          if (snapshots.length == 1) throw StateError('disk');
        },
      );
      await tap(tester, find.byTooltip('입력 폼'));
      await tap(tester, find.byKey(const ValueKey('forms-respond')));
      await tester.enterText(
        find.byKey(const ValueKey('forms-answer-$titleId')),
        '폼 접수',
      );
      await tap(tester, find.byKey(const ValueKey('forms-submit')));
      expect(snapshots.single.rows, hasLength(3));
      expect(preparations(), hasLength(1));
      await tap(tester, find.byKey(const ValueKey('forms-submit')));
      expect(snapshots, hasLength(2));
      expect(snapshots[1].toJson(), snapshots[0].toJson());
      await flush(tester, key.currentState!);
      expect(key.currentState!.database.rows, hasLength(3));
      expect(runtime.receipts(key.currentState!.database), hasLength(1));
      expect(
        DatabaseForms(key.currentState!.database).submissions,
        hasLength(1),
      );
      expect(preparations(), hasLength(1));
    },
    skip: !available,
  );

  testWidgets('form definition save never invokes rowAdded preparation', (
    tester,
  ) async {
    final key = await mount(tester, initial: fixture(trigger: 'rowAdded'));
    await tap(tester, find.byTooltip('입력 폼'));
    await tester.enterText(
      find.byKey(const ValueKey('forms-title-$formId')),
      '다른 폼 제목',
    );
    await flush(tester, key.currentState!);
    expect(preparations(), isEmpty);
    expect(key.currentState!.database.rows, hasLength(1));
  }, skip: !available);
}
