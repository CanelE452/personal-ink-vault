import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/vault/database_query.dart';
import 'package:saber/data/vault/workspace_database.dart';

WorkspaceDatabase database(
  List<DatabaseProperty> properties,
  List<DatabaseRow> rows, [
  List<DatabaseView>? views,
]) => WorkspaceDatabase.empty().copyWith(
  properties: properties,
  rows: rows,
  views: views ?? [DatabaseView.create()],
);
DatabaseProperty property(
  String name,
  String type, [
  Map<String, dynamic> config = const {},
]) => DatabaseProperty.create(name: name, type: type, config: config);

void main() {
  safetyRegressionTests();
  rowBodyValidationTests();
  test('immutable CRUD preserves UUID identities, view independence and archived rows', () {
    final title = property('이름', 'title');
    final row = DatabaseRow.create(values: {title.id: '연구'});
    final board = DatabaseView.create(name: '보드', type: 'board');
    final original = database([title], [row]);
    final edited = original
        .addView(board)
        .setCell(row.id, title.id, '수정')
        .renameProperty(title.id, '제목');
    expect(original.rows.single.values[title.id], '연구');
    expect(edited.properties.single.id, title.id);
    expect(edited.rows.single.id, row.id);
    expect(edited.rows.single.values[title.id], '수정');
    expect(edited.removeView(board.id).rows.single.id, row.id);
    expect(edited.archiveRow(row.id).rows.single.archived, true);
    expect(
      edited
          .archiveRow(row.id)
          .archiveRow(row.id, archived: false)
          .rows
          .single
          .id,
      row.id,
    );
    expect(
      WorkspaceDatabase.fromJson(edited.toJson()).toJson(),
      edited.toJson(),
    );
  });

  test(
    'permanent row removal prunes task links while archive retains them',
    () {
      final parent = DatabaseRow.create();
      final child = DatabaseRow.create();
      final predecessor = DatabaseRow.create();
      final other = DatabaseRow.create();
      final initial = WorkspaceDatabase.empty().copyWith(
        rows: [parent, child, predecessor, other],
      );
      final links = {
        'schemaVersion': 1,
        'items': {
          parent.id: {
            'predecessorIds': [predecessor.id],
          },
          child.id: {
            'parentId': parent.id,
            'predecessorIds': [predecessor.id, parent.id],
          },
          other.id: {'parentId': child.id},
        },
      };
      final db = WorkspaceDatabase.fromJson({
        ...initial.toJson(),
        'pivTaskLinks': links,
      });
      expect(db.archiveRow(parent.id).toJson()['pivTaskLinks'], links);
      expect(
        db
            .archiveRow(parent.id)
            .archiveRow(parent.id, archived: false)
            .toJson(),
        db.toJson(),
      );
      final removed = db.removeRow(parent.id);
      expect(removed.toJson()['pivTaskLinks'], {
        'schemaVersion': 1,
        'items': {
          child.id: {
            'predecessorIds': [predecessor.id],
          },
          other.id: {'parentId': child.id},
        },
      });
      expect(
        removed.removeRow(child.id).toJson().containsKey('pivTaskLinks'),
        isFalse,
      );
      expect(db.toJson()['pivTaskLinks'], links);
    },
  );

  test(
    'task link projections are immutable and accept legacy missing rows',
    () {
      final row = DatabaseRow.create();
      final missing = newId();
      final db = WorkspaceDatabase.empty().addRow(row);
      expect(db.supportsTaskLinks, isTrue);
      expect(db.taskLinks, isEmpty);
      expect(db.taskLinksEnvelope, isNull);

      final links = <String, dynamic>{
        'schemaVersion': 1,
        'items': {
          row.id: {
            'parentId': missing,
            'predecessorIds': [missing],
          },
        },
      };
      final attached = db.withTaskLinks(links);
      final restored = WorkspaceDatabase.fromJson(attached.toJson());
      final task = restored.taskLinks[row.id]!;
      expect(restored.supportsTaskLinks, isTrue);
      expect(task.parentId, missing);
      expect(task.predecessorIds, [missing]);
      expect(() => task.predecessorIds.clear(), throwsUnsupportedError);
      expect(() => restored.taskLinks.clear(), throwsUnsupportedError);
      (restored.taskLinksEnvelope!['items'] as Map).clear();
      (links['items'] as Map).clear();
      expect(attached.taskLinks[row.id]!.parentId, missing);
      expect(restored.taskLinks[row.id]!.predecessorIds, [missing]);
      expect(
        restored
            .withTaskLinks({'schemaVersion': 1, 'items': {}})
            .toJson()
            .containsKey('pivTaskLinks'),
        isFalse,
      );
    },
  );

  test('unsupported or malformed task link data survives unrelated writes', () {
    final row = DatabaseRow.create();
    final db = WorkspaceDatabase.empty().addRow(row);
    final other = newId();
    for (final raw in [
      null,
      {'schemaVersion': 2, 'items': {}, 'vendorFlag': true},
      {
        'schemaVersion': 1,
        'items': {
          row.id: {'parentId': row.id},
        },
      },
      {
        'schemaVersion': 1,
        'items': {
          row.id: {
            'predecessorIds': [other, other],
          },
        },
      },
      {
        'schemaVersion': 1,
        'items': {
          row.id: {
            'predecessorIds': [
              for (var i = 0; i <= DatabaseTaskLink.maxPredecessors; i++)
                newId(),
            ],
          },
        },
      },
    ]) {
      final restored = WorkspaceDatabase.fromJson({
        ...db.toJson(),
        'pivTaskLinks': raw,
      });
      expect(restored.supportsTaskLinks, isFalse);
      expect(restored.taskLinks, isEmpty);
      expect(restored.taskLinksEnvelope, isNull);
      final deleted = restored.removeRow(row.id).toJson();
      expect(deleted.containsKey('pivTaskLinks'), isTrue);
      expect(deleted['pivTaskLinks'], raw);
      expect(
        () => restored.withTaskLinks({'schemaVersion': 1, 'items': {}}),
        throwsFormatException,
      );
    }
  });

  test('unknown root/entity fields and nested row-page JSON survive edits without aliasing', () {
    final p = newId(), r = newId(), v = newId();
    final raw = <String, dynamic>{
      'schemaVersion': 1,
      'id': newId(),
      'future': {
        'keep': [1, 2],
      },
      'properties': [
        {
          'id': p,
          'name': '원래',
          'type': 'text',
          'config': {},
          'future': {
            'keep': ['property'],
          },
        },
      ],
      'rows': [
        {
          'id': r,
          'values': {p: 'text'},
          'body': {
            'version': 1,
            'blocks': [],
            'opaque': {
              'keep': [3],
            },
          },
          'future': {
            'keep': ['row'],
          },
        },
      ],
      'views': [
        {
          'id': v,
          'name': '표',
          'type': 'table',
          'future': {
            'keep': ['view'],
          },
        },
      ],
    };
    final db = WorkspaceDatabase.fromJson(raw);
    final edited = db.renameProperty(p, '수정').setCell(r, p, 'new');
    final json = edited.toJson();
    expect(json['future'], raw['future']);
    expect(
      (json['properties'] as List).single['future'],
      (raw['properties'] as List).single['future'],
    );
    expect(
      (json['rows'] as List).single['body'],
      (raw['rows'] as List).single['body'],
    );
    expect(
      (json['views'] as List).single['future'],
      (raw['views'] as List).single['future'],
    );
    (json['future'] as Map)['keep'].clear();
    expect(db.toJson()['future'], {
      'keep': [1, 2],
    });
    expect(
      () => (db.rows.single.body['opaque'] as Map)['keep'].clear(),
      throwsUnsupportedError,
    );
  });

  test('typed raw values validate all supported property families', () {
    final specs = <String, Object?>{
      'title': '이름',
      'text': '본문',
      'number': 12.5,
      'status': 'doing',
      'select': 'one',
      'multiSelect': ['one', 'two'],
      'date': {
        'start': '2026-10-30',
        'end': '2026-11-01',
        'timeZone': 'Asia/Seoul',
      },
      'checkbox': false,
      'url': 'https://example.com',
      'email': 'person@example.com',
      'phone': '+82 10-1234-5678',
      'people': [
        {'id': 'person-1', 'name': '연구자'},
      ],
      'files': [
        {'name': 'a.pdf', 'attachmentId': 'owned'},
      ],
      'relation': [
        {'databaseId': newId(), 'rowId': newId()},
      ],
    };
    final properties = [for (final type in specs.keys) property(type, type)];
    final row = DatabaseRow.create(
      values: {for (final p in properties) p.id: specs[p.type]},
    );
    final db = database(properties, [row]);
    expect(
      WorkspaceDatabase.fromJson(db.toJson()).rows.single.values,
      row.values,
    );
    final number = properties.firstWhere((p) => p.type == 'number');
    expect(() => db.setCell(row.id, number.id, '12'), throwsFormatException);
    expect(
      () => db.setCell(row.id, number.id, double.nan),
      throwsFormatException,
    );
    final checkbox = properties.firstWhere((p) => p.type == 'checkbox');
    expect(
      () => db.setCell(row.id, checkbox.id, 'false'),
      throwsFormatException,
    );
    final date = properties.firstWhere((p) => p.type == 'date');
    expect(
      () => db.setCell(row.id, date.id, '2026-02-30'),
      throwsFormatException,
    );
    expect(
      () => db.setCell(row.id, date.id, {
        'start': '2026-11-01',
        'end': '2026-10-30',
      }),
      throwsFormatException,
    );
    expect(
      () => db.setCell(
        row.id,
        properties.firstWhere((p) => p.type == 'url').id,
        'javascript:alert(1)',
      ),
      throwsFormatException,
    );
  });

  test(
    'duplicate identities and invalid select/relation values are rejected',
    () {
      final status = property('상태', 'status', {
        'options': [
          {'id': 'todo', 'name': '할 일'},
        ],
      });
      final row = DatabaseRow.create(values: {status.id: 'todo'});
      final db = database([status], [row]);
      expect(() => db.addRow(row), throwsFormatException);
      expect(() => db.addProperty(status), throwsFormatException);
      expect(
        () => db.setCell(row.id, status.id, 'missing'),
        throwsFormatException,
      );
      final relation = property('관계', 'relation');
      final linked = db.addProperty(relation);
      expect(
        () => linked.setCell(row.id, relation.id, [
          {'databaseId': 'not-id', 'rowId': newId()},
        ]),
        throwsFormatException,
      );
    },
  );

  test('safe formulas support ID references, lazy logic, Unicode and lists without changing raw input', () {
    final amount = property('금액', 'number');
    final formula = property('계산', 'formula', {
      'expression':
          'if(prop("${amount.id}") > 0, prop("${amount.id}") * 2 + sum([1,2,3]), 1/0)',
    });
    final unicode = property('문자', 'formula', {
      'expression': 'concat(upper("ab"), " ", length("가😀"), " ", count([null,false,0,""]))',
    });
    final row = DatabaseRow.create(values: {amount.id: 5});
    final db = database([amount, formula, unicode], [row]);
    final before = db.toJson();
    expect(DatabaseQuery(db).value(row, formula.id).value, 16);
    expect(DatabaseQuery(db).value(row, unicode.id).value, 'AB 2 2');
    expect(
      DatabaseQuery(db.renameProperty(amount.id, '합계'))
          .value(row, formula.id)
          .value,
      16,
    );
    expect(db.toJson(), before);
    expect(() => db.setCell(row.id, formula.id, 100), throwsFormatException);
  });

  test('formula errors are structured for divide-by-zero, cycle, unsupported code and budget', () {
    final zero = property('zero', 'formula', {'expression': '1 / 0'});
    final cycle = property('loop', 'formula', {'expression': 'prop("loop")'});
    final code = property('code', 'formula', {
      'expression': 'eval("Process.run")',
    });
    final work = property('work', 'formula', {'expression': '1+2+3+4+5+6'});
    final row = DatabaseRow.create();
    final db = database([zero, cycle, code, work], [row]);
    expect(
      DatabaseQuery(db).value(row, zero.id).error?.code,
      'division_by_zero',
    );
    expect(DatabaseQuery(db).value(row, cycle.id).error?.code, 'cycle');
    expect(
      DatabaseQuery(db).value(row, code.id).error?.code,
      'unsupported_function',
    );
    expect(
      DatabaseQuery(db, budget: 2).value(row, work.id).error?.code,
      'budget_exceeded',
    );
  });

  test(
    'nested filters, stable sorting and grouping use the same row identities',
    () {
      final title = property('이름', 'title'),
          amount = property('금액', 'number'),
          status = property('상태', 'status');
      final a = DatabaseRow.create(
        values: {title.id: 'alpha', amount.id: 5, status.id: 'doing'},
      );
      final b = DatabaseRow.create(
        values: {title.id: 'beta', amount.id: 10, status.id: 'done'},
      );
      final c = DatabaseRow.create(
        values: {title.id: 'gamma', amount.id: 2, status.id: 'doing'},
      );
      final db = database([title, amount, status], [a, b, c]);
      final view = DatabaseView.create(
        type: 'board',
        filter: {
          'and': [
            {'propertyId': amount.id, 'operator': 'gte', 'value': 5},
            {
              'or': [
                {'propertyId': title.id, 'operator': 'contains', 'value': 'a'},
                {
                  'propertyId': status.id,
                  'operator': 'equals',
                  'value': 'none',
                },
              ],
            },
          ],
        },
        sorts: [
          {'propertyId': amount.id, 'direction': 'descending'},
        ],
        groupBy: status.id,
      );
      final result = DatabaseQuery(db).apply(view);
      expect(result.rows.map((r) => r.id), [b.id, a.id]);
      expect(result.groups['done']!.single.id, b.id);
      expect(result.groups['doing']!.single.id, a.id);
      expect(db.rows.map((r) => r.id), [a.id, b.id, c.id]);
    },
  );

  test('relations and rollups resolve fixed IDs, report missing rows, and recover on restore', () {
    final amount = property('가격', 'number');
    final a = DatabaseRow.create(values: {amount.id: 10}),
        b = DatabaseRow.create(values: {amount.id: 20});
    var target = database([amount], [a, b]);
    final relation = property('연결', 'relation', {'databaseId': target.id});
    final rollup = property('합계', 'rollup', {
      'relationPropertyId': relation.id,
      'targetPropertyId': amount.id,
      'calculation': 'sum',
    });
    final row = DatabaseRow.create(
      values: {
        relation.id: [
          {'databaseId': target.id, 'rowId': a.id},
          {'databaseId': target.id, 'rowId': b.id},
        ],
      },
    );
    final db = database([relation, rollup], [row]);
    DatabaseQuery query() =>
        DatabaseQuery(db, resolver: (id) => id == target.id ? target : null);
    expect(query().value(row, rollup.id).value, 30);
    final raw = row.toJson();
    target = target.archiveRow(a.id);
    expect(query().value(row, rollup.id).error?.code, 'missing_relation');
    target = target
        .archiveRow(a.id, archived: false)
        .renameProperty(amount.id, '바뀐 가격');
    expect(query().value(row, rollup.id).value, 30);
    expect(row.toJson(), raw);
  });

  test('calendar and timeline use explicit UTC instants and chart aggregates share the rows', () {
    final date = property('날짜', 'date'),
        category = property('구분', 'select'),
        amount = property('금액', 'number');
    final a = DatabaseRow.create(
      values: {
        date.id: {
          'start': '2026-10-30T09:00:00+09:00',
          'end': '2026-10-31T09:00:00+09:00',
        },
        category.id: 'A',
        amount.id: 3,
      },
    );
    final b = DatabaseRow.create(
      values: {date.id: '2026-10-31', category.id: 'A', amount.id: 7},
    );
    final db = database([date, category, amount], [a, b]);
    final query = DatabaseQuery(db);
    final events = query.calendar(propertyId: date.id);
    expect(events.first.start, DateTime.utc(2026, 10, 30));
    expect(events.first.end, DateTime.utc(2026, 10, 31));
    expect(events.last.allDay, true);
    final points = query.chart(
      groupBy: category.id,
      valuePropertyId: amount.id,
      calculation: 'sum',
    );
    expect(points.single.value, 10);
    expect(points.single.rowIds, [a.id, b.id]);
    expect(query.aggregate(amount.id, calculation: 'average').value, 5);
  });

  test('date formulas require a captured clock and handle date-only arithmetic deterministically', () {
    final date = property('날짜', 'date');
    final plus = property('기한', 'formula', {
      'expression': 'dateAdd(prop("${date.id}"), 2, "days")',
    });
    final clock = property('시각', 'formula', {'expression': 'now()'});
    final row = DatabaseRow.create(values: {date.id: '2026-10-30'});
    final db = database([date, plus, clock], [row]);
    expect(
      DatabaseQuery(db).value(row, plus.id).value,
      '2026-11-01T00:00:00.000Z',
    );
    expect(
      DatabaseQuery(db).value(row, clock.id).error?.code,
      'clock_required',
    );
    expect(
      DatabaseQuery(
        db,
        now: DateTime.utc(2026, 10, 30, 3),
      ).value(row, clock.id).value,
      '2026-10-30T03:00:00.000Z',
    );
  });
}

void safetyRegressionTests() {
  test('integer overflow and malformed rollup config return error values', () {
    final big = property('overflow', 'formula', {
      'expression': '9223372036854775807 + 1',
    });
    final relation = property('relation', 'relation');
    final rollup = property('rollup', 'rollup', {
      'relationPropertyId': relation.id,
      'calculation': 12,
    });
    final row = DatabaseRow.create(values: {relation.id: []});
    final db = database([big, relation, rollup], [row]);
    expect(
      DatabaseQuery(db).value(row, big.id).error?.code,
      'numeric_overflow',
    );
    expect(DatabaseQuery(db).value(row, rollup.id).error?.code, 'type_error');
  });
  test('concat and replacement reject oversized output before allocation', () {
    final source = property('source', 'text'),
        replacement = property('replacement', 'text');
    final concat = property('concat', 'formula', {
      'expression':
          'concat(prop("${source.id}"), prop("${source.id}"), prop("${source.id}"))',
    });
    final replace = property('replace', 'formula', {
      'expression': 'replace("${'a' * 1000}", "a", prop("${replacement.id}"))',
    });
    final row = DatabaseRow.create(
      values: {source.id: 'a' * 500000, replacement.id: 'b' * 2000},
    );
    final db = database([source, replacement, concat, replace], [row]);
    expect(
      DatabaseQuery(db, budget: 100000).value(row, concat.id).error?.code,
      'result_limit',
    );
    expect(
      DatabaseQuery(db, budget: 100000).value(row, replace.id).error?.code,
      'result_limit',
    );
  });
  test(
    'date equality and grouping compare UTC instants across raw date shapes',
    () {
      final date = property('date', 'date');
      final a = DatabaseRow.create(
        values: {
          date.id: {'start': '2026-10-30T09:00:00+09:00'},
        },
      );
      final b = DatabaseRow.create(values: {date.id: '2026-10-30T00:00:00Z'});
      final db = database([date], [a, b]);
      final view = DatabaseView.create(
        groupBy: date.id,
        filter: {
          'propertyId': date.id,
          'operator': 'equals',
          'value': '2026-10-30T00:00:00Z',
        },
      );
      final result = DatabaseQuery(db).apply(view);
      expect(result.rows.map((r) => r.id), [a.id, b.id]);
      expect(result.groups.keys, ['2026-10-30']);
    },
  );
  test('unknown aggregates and malformed nested filters report errors on empty or invalid inputs', () {
    final amount = property('amount', 'number');
    final row = DatabaseRow.create();
    final db = database([amount], [row]);
    expect(
      DatabaseQuery(db)
          .aggregate(amount.id, calculation: 'execute')
          .error
          ?.code,
      'unsupported_aggregate',
    );
    final result = DatabaseQuery(db).apply(
      DatabaseView.create(
        filter: {
          'and': [42],
        },
      ),
    );
    expect(result.errors.single.code, 'invalid_filter');
  });
  test('formula reference and syntax depth limits are structured', () {
    final fields = <DatabaseProperty>[];
    for (var i = 0; i < 6; i++) {
      fields.add(
        property('field$i', 'formula', {
          'expression': i == 0 ? '1' : 'prop("field${i - 1}")',
        }),
      );
    }
    final row = DatabaseRow.create();
    final db = database(fields, [row]);
    expect(
      DatabaseQuery(db, maxDepth: 3).value(row, fields.last.id).error?.code,
      'depth_limit',
    );
    final nested = property('nested', 'formula', {
      'expression': '${'(' * 50}1${')' * 50}',
    });
    expect(
      DatabaseQuery(
        database([nested], [row]),
        maxDepth: 16,
      ).value(row, nested.id).error?.code,
      'depth_limit',
    );
  });
}

void rowBodyValidationTests() {
  test(
    'row block-page bodies validate their schema and preserve opaque blocks',
    () {
      expect(
        () => DatabaseRow.create(body: {'version': 1, 'blocks': 'not-a-list'}),
        throwsFormatException,
      );
      final duplicate = newId();
      expect(
        () => DatabaseRow.create(
          body: {
            'version': 1,
            'blocks': [
              {'id': duplicate, 'type': 'paragraph', 'text': 'first'},
              {'id': duplicate, 'type': 'paragraph', 'text': 'second'},
            ],
          },
        ),
        throwsFormatException,
      );
      expect(
        () => DatabaseRow.create(
          body: {
            'version': 1,
            'blocks': [
              {'id': newId(), 'type': 'paragraph', 'text': 42},
            ],
          },
        ),
        throwsFormatException,
      );
      final body = <String, dynamic>{
        'version': 1,
        'blocks': [
          {
            'id': newId(),
            'type': 'futureBlock',
            'opaque': {
              'keep': [1, 2],
            },
          },
        ],
        'future': {
          'keep': [3],
        },
      };
      expect(DatabaseRow.create(body: body).toJson()['body'], body);
    },
  );
}
