import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/vault/database_forms.dart';
import 'package:saber/data/vault/workspace_database.dart';

Matcher formError(String code) =>
    isA<DatabaseFormException>().having((e) => e.code, 'code', code);
const inputRevision = '00000000-0000-4000-8000-000000000042';
const laterRevision = '00000000-0000-4000-8000-000000000043';

void main() {
  late DatabaseProperty title, branch, detail;
  late DatabaseFormQuestion titleQuestion, branchQuestion, detailQuestion;
  late DatabaseForm form;
  late WorkspaceDatabase db;
  final now = DateTime.utc(2026, 10, 30, 4, 5, 6);

  setUp(() {
    title = DatabaseProperty.create(name: '이름', type: 'title');
    branch = DatabaseProperty.create(name: '상세 입력', type: 'checkbox');
    detail = DatabaseProperty.create(name: '상세', type: 'text');
    titleQuestion = DatabaseFormQuestion.create(
      propertyId: title.id,
      label: '이름',
      required: true,
    );
    branchQuestion = DatabaseFormQuestion.create(
      propertyId: branch.id,
      label: '상세 추가',
    );
    detailQuestion = DatabaseFormQuestion.create(
      propertyId: detail.id,
      label: '상세 내용',
      required: true,
      visibleWhen: {
        'questionId': branchQuestion.id,
        'operator': 'eq',
        'value': true,
      },
    );
    form = DatabaseForm.create(
      title: '접수',
      description: '로컬 폼',
      questions: [titleQuestion, branchQuestion, detailQuestion],
    );
    db = WorkspaceDatabase.empty().copyWith(
      properties: [title, branch, detail],
    );
    db = DatabaseForms(db).putForm(form);
  });

  DatabaseFormSubmission submit(
    WorkspaceDatabase input,
    String requestId, {
    Map<String, Object?>? answers,
    DateTime? at,
    String revision = inputRevision,
  }) => DatabaseForms(input).prepareSubmission(
    formId: form.id,
    answers: answers ?? {title.id: '접수 A', branch.id: false},
    requestId: requestId,
    inputRevision: revision,
    capturedAt: at ?? now,
  );

  test('form order and UUID refs survive property rename and round trip', () {
    final changed = db.renameProperty(title.id, '변경된 속성');
    final restored = DatabaseForms(WorkspaceDatabase.fromJson(changed.toJson()))
        .getForm(form.id);
    expect(restored.toJson(), form.toJson());
    expect(restored.questions.map((q) => q.id), [
      titleQuestion.id,
      branchQuestion.id,
      detailQuestion.id,
    ]);
    expect(restored.questions.first.propertyId, title.id);
  });

  test(
    'form edits preserve unknown JSON and source and summary metadata deeply',
    () {
      final rawForm = form.toJson();
      rawForm['future'] = {
        'nested': [1, 2],
      };
      (rawForm['questions'] as List).first['futureQuestion'] = {
        'items': ['keep'],
      };
      final raw = db.toJson()..['source'] = {'entityId': 'keep-source'};
      raw['summary'] = {'manual': 'keep-summary'};
      raw['futureRoot'] = {
        'values': [7],
      };
      raw['forms'] = [rawForm];
      final loaded = WorkspaceDatabase.fromJson(raw);
      final f = DatabaseForms(loaded).getForm(form.id);
      final changed = DatabaseForms(loaded).putForm(
        f.copyWith(
          title: '수정',
          questions: [
            f.questions.first.copyWith(label: '새 질문'),
            ...f.questions.skip(1),
          ],
        ),
      );
      final saved = changed.toJson();
      expect(saved['source'], raw['source']);
      expect(saved['summary'], raw['summary']);
      expect(saved['futureRoot'], raw['futureRoot']);
      expect((saved['forms'] as List).first['future'], rawForm['future']);
      expect(
        (saved['forms'] as List).first['questions'][0]['futureQuestion'],
        rawForm['questions'][0]['futureQuestion'],
      );
      (rawForm['future'] as Map)['nested'].clear();
      expect(f.toJson()['future'], {
        'nested': [1, 2],
      });
      expect(() => f.questions.add(titleQuestion), throwsUnsupportedError);
      expect(
        () => f.questions.last.visibleWhen!['value'] = false,
        throwsUnsupportedError,
      );
      (saved['forms'] as List).clear();
      expect(DatabaseForms(changed).forms, hasLength(1));
    },
  );

  test(
    'hidden values are excluded and required applies only while visible',
    () {
      final hidden = DatabaseForms(db)
          .preview(form.id, {title.id: 'A', branch.id: false, detail.id: 123});
      expect(hidden.isValid, true);
      expect(hidden.visibleQuestions.map((q) => q.id), [
        titleQuestion.id,
        branchQuestion.id,
      ]);
      expect(hidden.values, {title.id: 'A', branch.id: false});
      final visible = DatabaseForms(db)
          .preview(form.id, {title.id: 'A', branch.id: true});
      expect(visible.isValid, false);
      expect(visible.errors.single.code, 'required');
      expect(visible.errors.single.propertyId, detail.id);
    },
  );

  test(
    'hidden ancestors cannot reveal descendants using stale submitted answers',
    () {
      final last = DatabaseProperty.create(name: '후속', type: 'text');
      final lastQ = DatabaseFormQuestion.create(
        propertyId: last.id,
        label: '후속',
        visibleWhen: {
          'questionId': detailQuestion.id,
          'operator': 'eq',
          'value': 'show',
        },
      );
      final changed = DatabaseForms(db.addProperty(last))
          .putForm(form.copyWith(questions: [...form.questions, lastQ]));
      final preview = DatabaseForms(changed).preview(form.id, {
        title.id: 'A',
        branch.id: false,
        detail.id: 'show',
        last.id: 'stale',
      });
      expect(preview.values.containsKey(last.id), false);
      expect(preview.visibleQuestions.map((q) => q.id), [
        titleQuestion.id,
        branchQuestion.id,
      ]);
    },
  );

  test(
    'all supported raw input property families validate and remain typed',
    () {
      final samples = <String, Object?>{
        'title': 'A',
        'text': 'B',
        'number': 12.5,
        'status': 'yes',
        'select': 'yes',
        'multiSelect': ['yes'],
        'date': {'start': '2026-10-30', 'timeZone': 'Asia/Seoul'},
        'checkbox': false,
        'url': 'https://example.com',
        'email': 'a@example.com',
        'phone': '+82-1',
      };
      final props = [
        for (final type in samples.keys)
          DatabaseProperty.create(
            name: type,
            type: type,
            config: {
              'options': ['yes'],
            },
          ),
      ];
      final f = DatabaseForm.create(
        title: 'types',
        questions: [
          for (final p in props)
            DatabaseFormQuestion.create(
              propertyId: p.id,
              label: p.name,
              required: true,
            ),
        ],
      );
      var input = WorkspaceDatabase.empty().copyWith(properties: props);
      input = DatabaseForms(input).putForm(f);
      final values = {for (final p in props) p.id: samples[p.type]};
      final result = DatabaseForms(input).prepareSubmission(
        formId: f.id,
        answers: values,
        requestId: newId(),
        inputRevision: inputRevision,
        capturedAt: now,
      );
      expect(result.database.rows.single.values, values);
      expect(result.receipt.inputRevision, inputRevision);
      expect(result.receipt.submittedAt, now);
      expect(result.receipt.formDigest, matches(RegExp(r'^[0-9a-f]{64}$')));
    },
  );

  test(
    'malformed visible typed answers fail before any row or receipt exists',
    () {
      expect(
        () => submit(
          db,
          newId(),
          answers: {title.id: 4, branch.id: true, detail.id: 'A'},
        ),
        throwsA(formError('invalid_answer')),
      );
      expect(db.rows, isEmpty);
      expect(DatabaseForms(db).submissions, isEmpty);
    },
  );

  test(
    'unknown or extra property answers and deleted question properties reject',
    () {
      expect(
        () => submit(db, newId(), answers: {title.id: 'A', newId(): 'extra'}),
        throwsA(formError('unknown_answer')),
      );
      final extra = DatabaseProperty.create(name: 'not in form');
      expect(
        () => submit(
          db.addProperty(extra),
          newId(),
          answers: {title.id: 'A', extra.id: 'extra'},
        ),
        throwsA(formError('unknown_answer')),
      );
      expect(
        () => submit(db.removeProperty(detail.id), newId()),
        throwsA(formError('missing_property')),
      );
    },
  );

  test('computed unknown people relation and file metadata are explicit unsupported inputs', () {
    for (final type in [
      'formula',
      'rollup',
      'futureType',
      'files',
      'relation',
      'people',
    ]) {
      final p = DatabaseProperty.create(name: type, type: type);
      final input = db.addProperty(p);
      final f = form.copyWith(
        questions: [DatabaseFormQuestion.create(propertyId: p.id, label: type)],
      );
      expect(
        () => DatabaseForms(input).putForm(f),
        throwsA(formError('unsupported_property')),
      );
      expect(
        DatabaseForms(input).supportedProperties.map((p) => p.id),
        isNot(contains(p.id)),
      );
    }
  });

  test(
    'cycles forward self unknown refs and repeated property refs reject',
    () {
      for (final reference in [detailQuestion.id, titleQuestion.id, newId()]) {
        final q = titleQuestion.copyWith(
          visibleWhen: {'questionId': reference, 'operator': 'isNotEmpty'},
        );
        expect(
          () => DatabaseForms(db).putForm(
            form.copyWith(questions: [q, branchQuestion, detailQuestion]),
          ),
          throwsA(formError('invalid_condition_reference')),
        );
      }
      final duplicate = DatabaseFormQuestion.create(
        propertyId: title.id,
        label: '반복',
      );
      expect(
        () =>
            DatabaseForms(db)
                .putForm(form.copyWith(questions: [titleQuestion, duplicate])),
        throwsA(formError('duplicate_property')),
      );
      expect(
        () => DatabaseForm.create(
          title: '중복',
          questions: [titleQuestion, titleQuestion],
        ),
        throwsA(formError('duplicate_question')),
      );
    },
  );

  test(
    'limited boolean condition tree compares typed values without coercion',
    () {
      final q = detailQuestion.copyWith(
        visibleWhen: {
          'and': [
            {
              'questionId': titleQuestion.id,
              'operator': 'contains',
              'value': 'A',
            },
            {
              'or': [
                {
                  'questionId': branchQuestion.id,
                  'operator': 'eq',
                  'value': true,
                },
                {
                  'not': {
                    'questionId': titleQuestion.id,
                    'operator': 'notEq',
                    'value': 'A',
                  },
                },
              ],
            },
          ],
        },
      );
      final changed = DatabaseForms(
        db,
      ).putForm(form.copyWith(questions: [titleQuestion, branchQuestion, q]));
      expect(
        DatabaseForms(changed).preview(form.id, {
          title.id: 'A',
          branch.id: false,
          detail.id: 'yes',
        }).visibleQuestions,
        hasLength(3),
      );
      expect(
        DatabaseForms(changed)
            .preview(form.id, {title.id: 'a', branch.id: true})
            .visibleQuestions,
        hasLength(2),
      );
      final bad = q.copyWith(
        visibleWhen: {
          'questionId': branchQuestion.id,
          'operator': 'eq',
          'value': 'true',
        },
      );
      expect(
        () => DatabaseForms(db).putForm(
          form.copyWith(questions: [titleQuestion, branchQuestion, bad]),
        ),
        throwsA(formError('invalid_condition_value')),
      );
      final unsafe = q.copyWith(
        visibleWhen: {
          'questionId': branchQuestion.id,
          'operator': 'eval',
          'value': 'run()',
        },
      );
      expect(
        () => DatabaseForms(db).putForm(
          form.copyWith(questions: [titleQuestion, branchQuestion, unsafe]),
        ),
        throwsA(formError('unsupported_condition')),
      );
    },
  );

  test('isEmpty isNotEmpty and list contains use empty and membership raw semantics', () {
    final options = DatabaseProperty.create(
      name: '선택',
      type: 'multiSelect',
      config: {
        'options': ['one', 'two'],
      },
    );
    final optionsQ = DatabaseFormQuestion.create(
      propertyId: options.id,
      label: '선택',
    );
    final q = detailQuestion.copyWith(
      visibleWhen: {
        'or': [
          {'questionId': optionsQ.id, 'operator': 'contains', 'value': 'two'},
          {'questionId': titleQuestion.id, 'operator': 'isEmpty'},
        ],
      },
    );
    final changed = DatabaseForms(db.addProperty(options)).putForm(
      form.copyWith(
        questions: [titleQuestion.copyWith(required: false), optionsQ, q],
      ),
    );
    expect(
      DatabaseForms(changed).preview(form.id, {
        title.id: 'A',
        options.id: ['one'],
      }).visibleQuestions,
      hasLength(2),
    );
    expect(
      DatabaseForms(changed).preview(form.id, {
        title.id: 'A',
        options.id: ['two'],
        detail.id: 'value',
      }).isValid,
      true,
    );
    final notEmpty = q.copyWith(
      visibleWhen: {'questionId': optionsQ.id, 'operator': 'isNotEmpty'},
    );
    final input = DatabaseForms(changed)
        .putForm(form.copyWith(questions: [titleQuestion, optionsQ, notEmpty]));
    expect(
      DatabaseForms(input)
          .preview(form.id, {title.id: 'A', options.id: []})
          .visibleQuestions,
      hasLength(2),
    );
  });

  test('receipt and row share one immutable snapshot and same content retry is idempotent', () {
    final request = newId();
    final result = submit(db, request);
    expect(result.duplicate, false);
    expect(result.database.rows.single.id, result.rowId);
    expect(
      DatabaseForms(result.database).submissions.single.rowId,
      result.rowId,
    );
    expect(db.rows, isEmpty);
    expect(DatabaseForms(db).submissions, isEmpty);
    final retry = submit(
      WorkspaceDatabase.fromJson(result.database.toJson()),
      request,
      at: now.add(const Duration(days: 1)),
      revision: laterRevision,
    );
    expect(retry.duplicate, true);
    expect(retry.rowId, result.rowId);
    expect(retry.receipt.inputRevision, result.receipt.inputRevision);
    expect(retry.receipt.submittedAt, now);
    expect(retry.database.toJson(), result.database.toJson());
  });

  test(
    'same request with changed content rejects including hidden answers',
    () {
      final request = newId();
      final result = submit(db, request);
      expect(
        () => submit(
          result.database,
          request,
          answers: {title.id: 'changed', branch.id: false},
        ),
        throwsA(formError('request_conflict')),
      );
      expect(
        () => submit(
          result.database,
          request,
          answers: {
            title.id: '접수 A',
            branch.id: false,
            detail.id: 'hidden change',
          },
        ),
        throwsA(formError('request_conflict')),
      );
    },
  );

  test(
    'request receipt survives form edits but requests cannot cross forms',
    () {
      final request = newId();
      final result = submit(db, request);
      final changed = DatabaseForms(result.database)
          .putForm(form.copyWith(title: '다른 버전', archived: true));
      final retry = submit(changed, request);
      expect(retry.duplicate, true);
      expect(retry.receipt.formDigest, result.receipt.formDigest);
      final other = DatabaseForm.create(
        title: '다른 폼',
        questions: [titleQuestion],
      );
      final input = DatabaseForms(changed).putForm(other);
      expect(
        () => DatabaseForms(input).prepareSubmission(
          formId: other.id,
          answers: {title.id: '접수 A'},
          requestId: request,
          inputRevision: inputRevision,
          capturedAt: now,
        ),
        throwsA(formError('request_conflict')),
      );
    },
  );

  test('save failure retry against original snapshot uses deterministic UUID and same timestamp capture', () {
    final request = newId();
    final prepared = submit(db, request);
    final retry = submit(db, request);
    expect(retry.rowId, prepared.rowId);
    expect(retry.database.toJson(), prepared.database.toJson());
    expect(
      prepared.rowId,
      matches(
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ),
      ),
    );
    expect(submit(db, newId()).rowId, isNot(prepared.rowId));
    expect(
      () => submit(db.addRow(DatabaseRow.create(id: prepared.rowId)), request),
      throwsA(formError('row_identity_conflict')),
    );
  });

  test('removed receipt row is not silently recreated and archived forms reject new submissions', () {
    final request = newId();
    final prepared = submit(db, request);
    expect(
      () => submit(prepared.database.removeRow(prepared.rowId), request),
      throwsA(formError('missing_submission_row')),
    );
    final archived = DatabaseForms(db).putForm(form.copyWith(archived: true));
    expect(
      () => submit(archived, newId()),
      throwsA(formError('archived_form')),
    );
  });

  test(
    'revision request and captured UTC time are mandatory validated metadata',
    () {
      expect(
        () => submit(db, newId(), revision: ''),
        throwsA(formError('invalid_input_revision')),
      );
      expect(
        () => submit(db, 'not-a-uuid'),
        throwsA(formError('invalid_request_id')),
      );
      expect(
        () => submit(db, newId(), at: DateTime(2026, 10, 30)),
        throwsA(formError('utc_required')),
      );
    },
  );

  test(
    'malformed identities and bounded form and answer structures reject',
    () {
      expect(
        () => DatabaseForm.create(id: 'invalid', title: 'A'),
        throwsA(formError('invalid_id')),
      );
      expect(
        () => DatabaseFormQuestion.create(propertyId: 'invalid', label: 'A'),
        throwsA(formError('invalid_id')),
      );
      expect(
        () => DatabaseForm.create(title: 'A' * 1000001),
        throwsA(formError('size_limit')),
      );
      expect(
        () => submit(db, newId(), answers: {title.id: 'A' * 1000001}),
        throwsA(formError('size_limit')),
      );
      var deep = <String, dynamic>{
        'questionId': titleQuestion.id,
        'operator': 'isNotEmpty',
      };
      for (var i = 0; i < 20; i++) {
        deep = {'not': deep};
      }
      final q = detailQuestion.copyWith(visibleWhen: deep);
      expect(
        () => DatabaseForms(
          db,
        ).putForm(form.copyWith(questions: [titleQuestion, branchQuestion, q])),
        throwsA(formError('condition_limit')),
      );
    },
  );
}
