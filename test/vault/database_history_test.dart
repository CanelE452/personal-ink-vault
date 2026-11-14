import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/vault/database_history.dart';
import 'package:saber/data/vault/workspace_database.dart';

Map<String, dynamic> _automationReceipt() => {
  'id': newId(),
  'ruleId': newId(),
  'ruleVersion': 1,
  'eventId': newId(),
  'eventDigest': 'a' * 64,
  'ruleDigest': 'b' * 64,
  'inputRevision': newId(),
  'deviceId': newId(),
  'capturedAtUtcMs': 1793343600000,
  'status': 'skipped',
  'actionResults': [],
  'future': {'source': 'automation'},
};

Map<String, dynamic> _formReceipt() => {
  'rowId': newId(),
  'formId': newId(),
  'requestId': newId(),
  'inputRevision': newId(),
  'submittedAt': '2026-11-08T12:00:00.000Z',
  'answersDigest': 'c' * 64,
  'formDigest': 'd' * 64,
  'future': {'source': 'form'},
};

WorkspaceDatabase _withFields(
  WorkspaceDatabase database,
  Map<String, Object?> fields,
) => WorkspaceDatabase.fromJson({...database.toJson(), ...fields});

void main() {
  test(
    'compares database content and attachment references by stable identity',
    () {
      final base = WorkspaceDatabase.empty();
      final title = base.properties.single;
      final first = DatabaseRow.create(values: {title.id: '처음 행'});
      final second = DatabaseRow.create(values: {title.id: '둘째 행'});
      final third = DatabaseRow.create();
      final removed = DatabaseRow.create();
      final added = DatabaseRow.create();
      final prior = base.copyWith(rows: [first, second, third, removed]);
      final template = prior.captureRowTemplate(
        rowId: first.id,
        templateId: newId(),
        name: '템플릿',
      );
      final before = _withFields(template, {
        'futureSettings': {'visible': true},
      });
      final after = _withFields(
        template.copyWith(
          properties: [
            DatabaseProperty.create(name: '추가 속성'),
            title.copyWith(name: '제목'),
          ],
          rows: [
            second,
            third,
            DatabaseRow.fromJson({
              ...first.copyWith(archived: true).toJson(),
              'futureRow': {'status': 'retained'},
            }),
            added,
          ],
          views: [
            base.views.single.copyWith(
              filter: {
                'and': [
                  {'propertyId': title.id},
                ],
              },
            ),
          ],
          rowTemplates: [],
        ),
        {
          'futureSettings': {'visible': false},
        },
      );
      final oldBlob = BlobRef(hash: '1' * 64, length: 4);
      final newBlob = BlobRef(hash: '2' * 64, length: 4);
      final diff = DatabaseHistoryDiff.compare(
        before,
        after,
        beforeFiles: {
          'database.json': oldBlob,
          'files/retained': oldBlob,
          'files/removed': oldBlob,
        },
        afterFiles: {
          'database.json': newBlob,
          'files/retained': newBlob,
          'files/added': newBlob,
        },
      );

      expect(diff.rows.added, 1);
      expect(diff.rows.removed, 1);
      expect(diff.rows.changed, 1);
      expect(diff.rows.moved, 1);
      final moved = diff.rows.items.singleWhere(
        (entry) => entry.id == first.id,
      );
      expect(moved.label, '처음 행');
      expect(moved.kinds, {
        DatabaseHistoryChangeKind.changed,
        DatabaseHistoryChangeKind.moved,
      });
      expect(diff.properties.added, 1);
      expect(diff.properties.changed, 1);
      expect(diff.properties.moved, 0);
      expect(diff.views.changed, 1);
      expect(diff.templates.removed, 1);
      expect(diff.attachments.added, 1);
      expect(diff.attachments.removed, 1);
      expect(diff.attachments.changed, 1);
      expect(diff.attachments.moved, 0);
      expect(diff.settingsChanged, isTrue);
      expect(diff.executionRecordsChanged, isFalse);
    },
  );

  test('isolates execution changes from database settings', () {
    final database = WorkspaceDatabase.empty();
    final changed = _withFields(database, {
      'automationExecutions': [_automationReceipt()],
      'formSubmissions': [_formReceipt()],
    });
    final diff = DatabaseHistoryDiff.compare(database, changed);
    expect(diff.settingsChanged, isFalse);
    expect(diff.executionRecordsChanged, isTrue);
  });

  test('restores chosen content with current rules and exact receipt maps', () {
    final base = WorkspaceDatabase.empty();
    final row = DatabaseRow.create();
    final oldAutomation = _automationReceipt(), oldForm = _formReceipt();
    final chosen = _withFields(base.copyWith(rows: [row]), {
      'automationRules': [
        {'id': newId(), 'version': 1},
      ],
      'automationExecutions': [oldAutomation],
      'formSubmissions': [oldForm],
      'futureSettings': {'layout': 'old'},
    });
    final current = _withFields(base, {
      'automationRules': [
        {
          'id': newId(),
          'version': 2,
          'future': [1],
        },
      ],
      'automationExecutions': [oldAutomation, _automationReceipt()],
      'formSubmissions': [oldForm, _formReceipt()],
      'futureSettings': {'layout': 'new'},
    });
    final currentRaw = current.toJson();
    final chosenRaw = chosen.toJson();
    final restored = databaseContentForRestore(
      current: current,
      chosen: chosen,
    );

    expect(restored.rows.map((value) => value.id), [row.id]);
    expect(restored.toJson(), {
      ...chosenRaw,
      'automationRules': currentRaw['automationRules'],
      'automationExecutions': currentRaw['automationExecutions'],
      'formSubmissions': currentRaw['formSubmissions'],
    });
    expect(current.toJson(), currentRaw);
    expect(chosen.toJson(), chosenRaw);
  });

  test(
    'accepts old empty ledgers without creating absent operational fields',
    () {
      final current = WorkspaceDatabase.empty();
      final chosen = _withFields(current, {
        'automationRules': [
          {'id': newId()},
        ],
        'automationExecutions': [],
        'formSubmissions': [],
      });
      final restored = databaseContentForRestore(
        current: current,
        chosen: chosen,
      );
      expect(restored.toJson(), current.toJson());
      final explicit = _withFields(current, {'formSubmissions': []});
      expect(
        databaseContentForRestore(current: explicit, chosen: current).toJson(),
        explicit.toJson(),
      );
    },
  );

  test('rejects missing, ambiguous, and modified historical receipts', () {
    final base = WorkspaceDatabase.empty();
    final automation = _automationReceipt();
    final form = _formReceipt();
    final chosen = _withFields(base, {
      'automationExecutions': [automation],
      'formSubmissions': [form],
    });
    for (final current in [
      base,
      _withFields(base, {
        'automationExecutions': [automation, automation],
        'formSubmissions': [form],
      }),
      _withFields(base, {
        'automationExecutions': [
          automation,
          {...automation, 'id': newId()},
        ],
        'formSubmissions': [form],
      }),
      _withFields(base, {
        'automationExecutions': [automation],
        'formSubmissions': [form, form],
      }),
      _withFields(base, {
        'automationExecutions': [
          {...automation, 'status': 'completed'},
        ],
        'formSubmissions': [form],
      }),
      _withFields(base, {
        'automationExecutions': [automation],
        'formSubmissions': [
          {...form, 'answersDigest': '1' * 64},
        ],
      }),
    ]) {
      expect(
        () => databaseContentForRestore(current: current, chosen: chosen),
        throwsFormatException,
      );
    }
  });

  test('rejects malformed receipt shapes and another database identity', () {
    final base = WorkspaceDatabase.empty();
    for (final malformed in [
      {'automationExecutions': null},
      {
        'automationExecutions': [
          {'id': newId()},
        ],
      },
      {
        'formSubmissions': {'id': newId()},
      },
      {
        'formSubmissions': [
          {'requestId': newId()},
        ],
      },
    ]) {
      final database = _withFields(base, malformed);
      expect(
        () => databaseContentForRestore(current: base, chosen: database),
        throwsFormatException,
      );
      expect(
        () => databaseContentForRestore(current: database, chosen: base),
        throwsFormatException,
      );
    }
    final other = WorkspaceDatabase.empty();
    expect(
      () => databaseContentForRestore(current: base, chosen: other),
      throwsFormatException,
    );
    expect(
      () => DatabaseHistoryDiff.compare(base, other),
      throwsFormatException,
    );
  });
}
