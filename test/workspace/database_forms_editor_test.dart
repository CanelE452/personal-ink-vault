import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/vault/database_forms.dart';
import 'package:saber/data/vault/workspace_database.dart';
import 'package:saber/pages/workspace/database_forms_editor.dart';

const titleId = '00000000-0000-4000-8000-000000000001';
const branchId = '00000000-0000-4000-8000-000000000002';
const detailId = '00000000-0000-4000-8000-000000000003';
const titleQ = '00000000-0000-4000-8000-000000000011';
const branchQ = '00000000-0000-4000-8000-000000000012';
const detailQ = '00000000-0000-4000-8000-000000000013';
const formId = '00000000-0000-4000-8000-000000000021';
const revision = '00000000-0000-4000-8000-000000000031';
const nextRevision = '00000000-0000-4000-8000-000000000032';

WorkspaceDatabase fixture() {
  final db = WorkspaceDatabase.empty().copyWith(
    properties: [
      DatabaseProperty.create(id: titleId, name: '이름', type: 'title'),
      DatabaseProperty.create(id: branchId, name: '상세 추가', type: 'checkbox'),
      DatabaseProperty.create(id: detailId, name: '상세', type: 'text'),
      DatabaseProperty.create(name: '계산', type: 'formula'),
      DatabaseProperty.create(name: '파일', type: 'files'),
    ],
  );
  return DatabaseForms(db).putForm(
    DatabaseForm.create(
      id: formId,
      title: '접수 폼',
      questions: [
        DatabaseFormQuestion.create(
          id: titleQ,
          propertyId: titleId,
          label: '이름',
          required: true,
        ),
        DatabaseFormQuestion.create(
          id: branchQ,
          propertyId: branchId,
          label: '상세 추가',
        ),
        DatabaseFormQuestion.create(
          id: detailQ,
          propertyId: detailId,
          label: '상세',
          required: true,
          visibleWhen: {'questionId': branchQ, 'operator': 'eq', 'value': true},
        ),
      ],
    ),
  );
}

void main() {
  Future<GlobalKey<DatabaseFormsPanelState>> mount(
    WidgetTester tester, {
    WorkspaceDatabase? initial,
    Future<void> Function(WorkspaceDatabase)? save,
    String Function()? currentRevision,
    ValueChanged<bool>? dirty,
    ValueChanged<bool>? busy,
    VoidCallback? back,
    double width = 1000,
  }) async {
    tester.view.physicalSize = Size(width, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final key = GlobalKey<DatabaseFormsPanelState>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DatabaseFormsPanel(
            key: key,
            initialDatabase: initial ?? fixture(),
            onSave: save ?? (_) async {},
            currentRevision: currentRevision ?? () => revision,
            onBack: back ?? () {},
            onDirtyChanged: dirty,
            onBusyChanged: busy,
          ),
        ),
      ),
    );
    return key;
  }

  Future<void> tap(WidgetTester tester, String key) async {
    final finder = find.byKey(ValueKey(key));
    await tester.ensureVisible(finder);
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  Future<void> answer(
    WidgetTester tester,
    String propertyId,
    String value,
  ) async {
    final finder = find.byKey(ValueKey('forms-answer-$propertyId'));
    await tester.ensureVisible(finder);
    await tester.enterText(finder, value);
    await tester.pump();
  }

  testWidgets(
    'creates edits persists and reopens local in-app form definitions',
    (tester) async {
      WorkspaceDatabase? saved;
      final key = await mount(
        tester,
        initial: WorkspaceDatabase.empty(),
        save: (db) async {
          saved = db;
        },
      );
      expect(find.textContaining('이 앱 안에서'), findsWidgets);
      await tap(tester, 'forms-create');
      final created = DatabaseForms(key.currentState!.database).forms.single;
      await tester.enterText(
        find.byKey(ValueKey('forms-title-${created.id}')),
        '연구 접수',
      );
      await tester.enterText(
        find.byKey(ValueKey('forms-description-${created.id}')),
        '내용 설명',
      );
      await key.currentState!.save();
      await tester.pump();
      final restored = DatabaseForms(
        WorkspaceDatabase.fromJson(saved!.toJson()),
      ).forms.single;
      expect(restored.id, created.id);
      expect(restored.title, '연구 접수');
      expect(restored.description, '내용 설명');
      expect(saved!.rows, isEmpty);
    },
  );

  testWidgets(
    'basic definition edits retain unknown advanced condition JSON exactly',
    (tester) async {
      final raw = fixture().toJson();
      final form = raw['forms'][0] as Map;
      form['future'] = {
        'keep': [1, 2],
      };
      form['questions'][2]['visibleWhen'] = {
        'and': [
          {'questionId': branchQ, 'operator': 'eq', 'value': true},
          {
            'not': {'questionId': titleQ, 'operator': 'isEmpty'},
          },
        ],
        'future': {'keep': true},
      };
      final condition = form['questions'][2]['visibleWhen'];
      WorkspaceDatabase? saved;
      final key = await mount(
        tester,
        initial: WorkspaceDatabase.fromJson(raw),
        save: (db) async {
          saved = db;
        },
      );
      await tester.enterText(
        find.byKey(const ValueKey('forms-title-$formId')),
        '수정 제목',
      );
      await key.currentState!.save();
      final result = DatabaseForms(saved!).getForm(formId);
      expect(result.questions.last.visibleWhen, condition);
      expect(result.toJson()['future'], {
        'keep': [1, 2],
      });
    },
  );

  testWidgets(
    'question labels required order and archive edit through real controls',
    (tester) async {
      final key = await mount(tester);
      await tester.enterText(
        find.byKey(const ValueKey('forms-question-label-$branchQ')),
        '분기 여부',
      );
      await tap(tester, 'forms-question-required-$branchQ');
      await tap(tester, 'forms-question-up-$branchQ');
      await key.currentState!.save();
      final form = DatabaseForms(key.currentState!.database).getForm(formId);
      expect(form.questions.first.id, branchQ);
      expect(form.questions.first.label, '분기 여부');
      expect(form.questions.first.required, true);
      await tap(tester, 'forms-archive');
      await key.currentState!.save();
      expect(
        DatabaseForms(key.currentState!.database).getForm(formId).archived,
        true,
      );
    },
  );

  testWidgets(
    'question picker excludes unsupported properties and condition trees are editable',
    (tester) async {
      final count = DatabaseProperty.create(name: '개수', type: 'number');
      final key = await mount(tester, initial: fixture().addProperty(count));
      await tap(tester, 'forms-add-question');
      await tap(tester, 'forms-condition-editor-$detailQ');
      await tap(tester, 'forms-condition-kind-$detailQ-root');
      await tester.tap(find.text('모두 만족').last);
      await tester.pumpAndSettle();
      await tap(tester, 'forms-condition-add-$detailQ-root');
      await key.currentState!.save();
      final form = DatabaseForms(key.currentState!.database).getForm(formId);
      expect(form.questions.last.propertyId, count.id);
      expect(form.questions[2].visibleWhen!['and'], hasLength(2));
      expect(form.questions.map((q) => q.propertyId), hasLength(4));
    },
  );

  testWidgets(
    'invalid definition remains dirty and blocks save until repaired',
    (tester) async {
      var saves = 0;
      final dirty = <bool>[];
      final key = await mount(
        tester,
        dirty: dirty.add,
        save: (_) async {
          saves++;
        },
      );
      await tester.enterText(
        find.byKey(const ValueKey('forms-title-$formId')),
        '',
      );
      await expectLater(key.currentState!.save(), throwsA(anything));
      await tester.pump();
      expect(saves, 0);
      expect(dirty.last, true);
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('forms-title-$formId')),
            )
            .controller!
            .text,
        '',
      );
      await tester.enterText(
        find.byKey(const ValueKey('forms-title-$formId')),
        '복구',
      );
      await key.currentState!.save();
      expect(saves, 1);
      expect(dirty.last, false);
    },
  );

  testWidgets(
    'definition save shares one future and drains edits typed while saving',
    (tester) async {
      final first = Completer<void>();
      final snapshots = <WorkspaceDatabase>[];
      final busy = <bool>[];
      final key = await mount(
        tester,
        busy: busy.add,
        save: (db) async {
          snapshots.add(db);
          if (snapshots.length == 1) await first.future;
        },
      );
      await tester.enterText(
        find.byKey(const ValueKey('forms-title-$formId')),
        '첫 제목',
      );
      final a = key.currentState!.save();
      final b = key.currentState!.save();
      expect(identical(a, b), true);
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('forms-title-$formId')),
        '후속 제목',
      );
      first.complete();
      await a;
      await tester.pump();
      expect(snapshots, hasLength(2));
      expect(DatabaseForms(snapshots.last).getForm(formId).title, '후속 제목');
      expect(busy, [true, false]);
    },
  );

  testWidgets(
    'preview is read only and unsubmitted responses block parent save until cancel',
    (tester) async {
      var saves = 0;
      final key = await mount(
        tester,
        save: (_) async {
          saves++;
        },
      );
      await tap(tester, 'forms-preview');
      expect(find.byKey(const ValueKey('forms-answer-$titleId')), findsNothing);
      expect(find.byKey(const ValueKey('forms-submit')), findsNothing);
      await tap(tester, 'forms-respond');
      await answer(tester, titleId, '아직 미제출');
      await expectLater(key.currentState!.save(), throwsA(anything));
      expect(saves, 0);
      expect(key.currentState!.database.rows, isEmpty);
      await tap(tester, 'forms-cancel-response');
      await key.currentState!.save();
      expect(saves, 0);
    },
  );

  testWidgets(
    'required errors are inline and hidden answers never reach saved row',
    (tester) async {
      WorkspaceDatabase? saved;
      await mount(
        tester,
        save: (db) async {
          saved = db;
        },
      );
      await tap(tester, 'forms-respond');
      await tap(tester, 'forms-submit');
      expect(
        find.byKey(const ValueKey('forms-field-error-$titleId')),
        findsOneWidget,
      );
      await answer(tester, titleId, '응답 A');
      await tap(tester, 'forms-answer-$branchId');
      await answer(tester, detailId, '숨겨질 값');
      await tap(tester, 'forms-answer-$branchId');
      expect(
        find.byKey(const ValueKey('forms-answer-$detailId')),
        findsNothing,
      );
      await tap(tester, 'forms-submit');
      expect(saved!.rows.single.values, {titleId: '응답 A', branchId: false});
      expect(find.byKey(const ValueKey('forms-submitted')), findsOneWidget);
    },
  );

  testWidgets(
    'submission success waits for persistence and parent save joins it',
    (tester) async {
      final persistence = Completer<void>();
      var calls = 0;
      final key = await mount(
        tester,
        save: (_) async {
          calls++;
          await persistence.future;
        },
      );
      await tap(tester, 'forms-respond');
      await answer(tester, titleId, '대기');
      await tester.tap(find.byKey(const ValueKey('forms-submit')));
      await tester.pump();
      expect(calls, 1);
      expect(find.byKey(const ValueKey('forms-submitted')), findsNothing);
      var done = false;
      final pending = key.currentState!.save().then((_) {
        done = true;
      });
      await tester.pump();
      expect(done, false);
      persistence.complete();
      await pending;
      await tester.pump();
      expect(find.byKey(const ValueKey('forms-submitted')), findsOneWidget);
    },
  );

  testWidgets(
    'failed persistence retries identical snapshot ID revision and UTC then new response gets new request',
    (tester) async {
      final snapshots = <WorkspaceDatabase>[];
      var current = revision;
      var revisionReads = 0;
      await mount(
        tester,
        currentRevision: () {
          revisionReads++;
          return current;
        },
        save: (db) async {
          snapshots.add(db);
          if (snapshots.length == 1) throw StateError('disk full');
        },
      );
      await tap(tester, 'forms-respond');
      await answer(tester, titleId, '재시도');
      await tap(tester, 'forms-submit');
      expect(find.byKey(const ValueKey('forms-submitted')), findsNothing);
      current = nextRevision;
      await tap(tester, 'forms-submit');
      expect(snapshots, hasLength(2));
      expect(snapshots[1].toJson(), snapshots[0].toJson());
      final receipt = DatabaseForms(snapshots[1]).submissions.single;
      expect(receipt.inputRevision, revision);
      expect(receipt.submittedAt.isUtc, true);
      expect(revisionReads, 1);
      await tap(tester, 'forms-respond');
      await answer(tester, titleId, '새 응답');
      await tap(tester, 'forms-submit');
      expect(snapshots.last.rows, hasLength(2));
      expect(
        DatabaseForms(snapshots.last).submissions
            .map((r) => r.requestId)
            .toSet(),
        hasLength(2),
      );
      expect(
        DatabaseForms(snapshots.last).submissions.last.inputRevision,
        nextRevision,
      );
    },
  );

  testWidgets(
    'responders enter every supported raw type through typed controls',
    (tester) async {
      final values = <String, String>{
        'title': '이름',
        'text': '본문',
        'number': '12.5',
        'status': 'yes',
        'select': 'yes',
        'multiSelect': 'yes',
        'date': '2026-10-30',
        'url': 'https://example.com',
        'email': 'a@example.com',
        'phone': '+82 10',
      };
      final properties = [
        for (final type in [...values.keys, 'checkbox'])
          DatabaseProperty.create(
            name: type,
            type: type,
            config: {
              'options': ['yes', 'no'],
            },
          ),
      ];
      final definition = DatabaseForm.create(
        title: '모든 형식',
        questions: [
          for (final p in properties)
            DatabaseFormQuestion.create(propertyId: p.id, label: p.name),
        ],
      );
      final input = DatabaseForms(
        WorkspaceDatabase.empty().copyWith(properties: properties),
      ).putForm(definition);
      WorkspaceDatabase? saved;
      await mount(
        tester,
        initial: input,
        save: (db) async {
          saved = db;
        },
      );
      await tap(tester, 'forms-respond');
      for (final p in properties) {
        if (p.type == 'checkbox') {
          await tap(tester, 'forms-answer-${p.id}');
        } else if (['status', 'select'].contains(p.type)) {
          await tap(tester, 'forms-answer-${p.id}');
          await tester.tap(find.text('yes').last);
          await tester.pumpAndSettle();
        } else if (p.type == 'multiSelect') {
          await tap(tester, 'forms-answer-option-${p.id}-yes');
        } else {
          await answer(tester, p.id, values[p.type]!);
        }
      }
      await tap(tester, 'forms-submit');
      final raw = saved!.rows.single.values;
      for (final p in properties) {
        expect(raw[p.id], switch (p.type) {
          'number' => 12.5,
          'checkbox' => true,
          'multiSelect' => ['yes'],
          _ => values[p.type],
        });
      }
    },
  );

  testWidgets('mobile320 and tablet widths render without overflow', (
    tester,
  ) async {
    for (final width in [320.0, 800.0]) {
      await mount(tester, width: width);
      expect(tester.takeException(), isNull);
      await tap(tester, 'forms-respond');
      await answer(tester, titleId, '화면 검사');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }
  });

  testWidgets(
    'NaN number stays editable with inline validation and can be repaired',
    (tester) async {
      final number = DatabaseProperty.create(name: '개수', type: 'number');
      var input = fixture().addProperty(number);
      input = DatabaseForms(input).putForm(
        DatabaseForms(input)
            .getForm(formId)
            .copyWith(
              questions: [
                DatabaseFormQuestion.create(
                  propertyId: titleId,
                  label: '이름',
                  required: true,
                ),
                DatabaseFormQuestion.create(propertyId: number.id, label: '개수'),
              ],
            ),
      );
      WorkspaceDatabase? saved;
      await mount(
        tester,
        initial: input,
        save: (db) async {
          saved = db;
        },
      );
      await tap(tester, 'forms-respond');
      await answer(tester, titleId, '숫자 응답');
      await answer(tester, number.id, 'NaN');
      expect(find.byKey(ValueKey('forms-answer-${number.id}')), findsOneWidget);
      await tap(tester, 'forms-submit');
      expect(
        find.byKey(ValueKey('forms-field-error-${number.id}')),
        findsOneWidget,
      );
      expect(saved, isNull);
      await answer(tester, number.id, '3');
      await tap(tester, 'forms-submit');
      expect(saved!.rows.single.values[number.id], 3);
    },
  );

  testWidgets(
    'Infinity number leaves explicit cancel reachable and never saves an invalid row',
    (tester) async {
      final number = DatabaseProperty.create(name: '개수', type: 'number');
      var input = fixture().addProperty(number);
      input = DatabaseForms(input).putForm(
        DatabaseForms(input)
            .getForm(formId)
            .copyWith(
              questions: [
                DatabaseFormQuestion.create(
                  propertyId: titleId,
                  label: '이름',
                  required: true,
                ),
                DatabaseFormQuestion.create(propertyId: number.id, label: '개수'),
              ],
            ),
      );
      var saves = 0;
      final key = await mount(
        tester,
        initial: input,
        save: (_) async {
          saves++;
        },
      );
      await tap(tester, 'forms-respond');
      await answer(tester, titleId, '취소할 응답');
      await answer(tester, number.id, 'Infinity');
      expect(
        find.byKey(const ValueKey('forms-cancel-response')),
        findsOneWidget,
      );
      await expectLater(key.currentState!.save(), throwsA(anything));
      await tap(tester, 'forms-cancel-response');
      await key.currentState!.save();
      expect(saves, 0);
      expect(key.currentState!.database.rows, isEmpty);
    },
  );

  testWidgets('nested condition groups stay editable at320 without overflow', (
    tester,
  ) async {
    final input = fixture();
    final original = DatabaseForms(input).getForm(formId);
    var condition = original.questions.last.visibleWhen!;
    for (var i = 0; i < 6; i++) {
      condition = {
        'and': [condition],
      };
    }
    final changed = original.copyWith(
      questions: [
        ...original.questions.take(2),
        original.questions.last.copyWith(visibleWhen: condition),
      ],
    );
    final db = DatabaseForms(input).putForm(changed);
    await mount(tester, initial: db, width: 320);
    await tap(tester, 'forms-condition-editor-$detailQ');
    expect(tester.takeException(), isNull);
    expect(
      find.byKey(
        const ValueKey('forms-condition-kind-$detailQ-root-0-0-0-0-0-0'),
      ),
      findsOneWidget,
    );
  });
}
