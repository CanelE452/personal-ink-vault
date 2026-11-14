import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/vault/dataview_query.dart';

void main() {
  test('accepts Dataview link sources and combined source sets', () {
    final query = DataviewQuery.parse(
      'TABLE status FROM ([[연구/실험 설계#제목]] OR outgoing([[Notes|label]])) '
      '& "연구" AND -#archive WHERE status != "완료"',
    );
    final root = query.source as DataviewSourceLogical;
    final folder = root.left as DataviewSourceLogical;
    final links = folder.left as DataviewSourceLogical;
    final incoming = links.left as DataviewLinkSource;
    final outgoing = links.right as DataviewLinkSource;
    expect((incoming.target, incoming.outgoing), ('연구/실험 설계', false));
    expect((outgoing.target, outgoing.outgoing), ('Notes', true));
    expect((root.and, folder.and, links.and), (true, true, false));
    expect((folder.right as DataviewFolderSource).folder, '연구');
    expect(
      (root.right as DataviewSourceNegation).source,
      isA<DataviewTagSource>(),
    );
    expect(
      (DataviewQuery.parse('TASK FROM [[]]').source as DataviewLinkSource)
          .target,
      isEmpty,
    );
  });

  test('accepts compound Dataview predicates and ordered sort keys', () {
    final query = DataviewQuery.parse(
      'TABLE priority WHERE (status = "진행" OR priority >= 3) & !archived '
      'SORT priority DESCENDING, file.name ASCENDING',
    );
    expect(query.sorts.map((item) => (item.property, item.descending)), [
      ('priority', true),
      ('file.name', false),
    ]);
    expect(() => query.sorts.clear(), throwsUnsupportedError);
    final condition = query.condition as DataviewLogical;
    expect(condition.and, isTrue);
    expect((condition.left as DataviewLogical).and, isFalse);
    expect(condition.right, isA<DataviewNegation>());
    expect(
      () => DataviewQuery.parse(
        'TASK WHERE !completed AND (line >= 2 | status != " ") '
        'SORT line DESC, file.name GROUP BY file.folder SORT key',
      ),
      returnsNormally,
    );
  });

  test('parses a bounded table with Unicode fields and a nested tag', () {
    final query = DataviewQuery.parse('''
  TaBlE 상태 AS "현재 상태", priority, file.name AS "제목"
  FrOm #연구/논문
  WhErE 상태 = "진행 중"
  SoRt priority DeSc
  LiMiT 12
''');

    expect(query.layout, DataviewLayout.table);
    expect(query.columns.map((column) => column.property), [
      '상태',
      'priority',
      'file.name',
    ]);
    expect(query.columns.map((column) => column.label), [
      '현재 상태',
      'priority',
      '제목',
    ]);
    expect((query.source as DataviewTagSource).tag, '연구/논문');
    final filter = query.condition as DataviewFilter;
    expect(filter.property, '상태');
    expect(filter.value, '진행 중');
    expect(query.sorts.single.property, 'priority');
    expect(query.sorts.single.descending, isTrue);
    expect(query.limit, 12);
    expect(() => query.columns.clear(), throwsUnsupportedError);
  });

  test('supports lists, no source, vault root and optional sort direction', () {
    final plain = DataviewQuery.parse('LIST\r\n');
    expect(plain.layout, DataviewLayout.list);
    expect(plain.columns, isEmpty);
    expect(plain.source, isNull);
    expect(plain.condition, isNull);
    expect(plain.sorts, isEmpty);
    expect(plain.limit, 100);

    final folder = DataviewQuery.parse('LIST FROM "/연구 자료/문헌/" SORT 이름');
    expect((folder.source as DataviewFolderSource).folder, '연구 자료/문헌');
    expect(folder.sorts.single.descending, isFalse);
    for (final root in ['', '/']) {
      final source = DataviewQuery.parse('LIST FROM "$root"').source;
      expect((source as DataviewFolderSource).folder, '');
    }
    expect(DataviewQuery.parse('LIST SORT 이름 ASC LIMIT 1').limit, 1);
  });

  test('distinguishes typed literals and keeps quoted punctuation literal', () {
    for (final (literal, value) in <(String, Object?)>[
      ('-12.5', -12.5),
      ('42', 42),
      ('TrUe', true),
      ('FALSE', false),
      ('NULL', null),
      ('"false"', 'false'),
      (r'"x \", = #tag OR y"', 'x ", = #tag OR y'),
    ]) {
      final filter =
          DataviewQuery.parse('LIST WHERE 속성 = $literal').condition
              as DataviewFilter;
      expect(filter.value, value, reason: literal);
      expect(filter.value.runtimeType, value.runtimeType, reason: literal);
    }
  });

  test('parses TASK completion shorthand and explicit page properties', () {
    final query = DataviewQuery.parse('''
TaSk FROM #연구/논문
WHERE !completed
SORT file.name DESC
LIMIT 12
''');
    expect(query.layout.name, 'task');
    expect(query.columns, isEmpty);
    expect((query.source as DataviewTagSource).tag, '연구/논문');
    final negation = query.condition as DataviewNegation;
    final filter = negation.condition as DataviewFilter;
    expect(filter.property, 'completed');
    expect(filter.operator, DataviewOperator.truthy);
    expect(query.sorts.single.property, 'file.name');
    expect(query.sorts.single.descending, isTrue);
    expect(query.limit, 12);

    expect(
      (DataviewQuery.parse('TASK WHERE completed').condition as DataviewFilter)
          .operator,
      DataviewOperator.truthy,
    );
    expect(
      (DataviewQuery.parse('TASK WHERE completed = false').condition
              as DataviewFilter)
          .value,
      isFalse,
    );
    expect(
      (DataviewQuery.parse('TASK FROM "연구" WHERE rank = 2').condition
              as DataviewFilter)
          .value,
      2,
    );
  });

  test('parses one TASK grouping before the result limit', () {
    final query = DataviewQuery.parse('''
TASK FROM "연구"
WHERE !completed
SORT line DESC
GROUP BY file.folder AS "폴더"
SORT key DESC
LIMIT 2
''');
    expect(query.layout, DataviewLayout.task);
    expect((query.source as DataviewFolderSource).folder, '연구');
    expect(query.condition, isA<DataviewNegation>());
    expect(query.sorts.single.property, 'line');
    expect(query.groupBy?.property, 'file.folder');
    expect(query.groupBy?.label, '폴더');
    expect(query.groupBy?.descending, isTrue);
    expect(query.limit, 2);
    final defaultGroup = DataviewQuery.parse('TASK GROUP BY rank AS category');
    expect(defaultGroup.groupBy?.label, 'category');
    expect(defaultGroup.groupBy?.descending, isFalse);
    expect(defaultGroup.limit, 100);
  });

  test('parses grouped document columns, member sorting and key sorting', () {
    final query = DataviewQuery.parse('''
TABLE rows.file.name AS "문서", rows.priority AS "순위", category
FROM #연구
SORT priority DESC
GROUP BY status AS category
SORT category DESC
LIMIT 2
''');
    expect(query.layout, DataviewLayout.table);
    expect(query.columns.map((column) => column.property), [
      'rows.file.name',
      'rows.priority',
      'category',
    ]);
    expect(query.sorts.single.property, 'priority');
    expect(query.sorts.single.descending, isTrue);
    expect(query.groupBy?.property, 'status');
    expect(query.groupBy?.label, 'category');
    expect(query.groupBy?.descending, isTrue);
    expect(query.limit, 2);

    final list = DataviewQuery.parse(
      'LIST rows.file.name GROUP BY file.folder',
    );
    expect(list.layout, DataviewLayout.list);
    expect(list.columns.single.property, 'rows.file.name');
    expect(list.groupBy?.property, 'file.folder');
    expect(
      DataviewQuery.parse('LIST rows.file.link GROUP BY status')
          .columns
          .single
          .property,
      'rows.file.link',
    );
    expect(DataviewQuery.parse('LIST GROUP BY file.folder').columns, isEmpty);
  });

  test('rejects malformed and unsupported syntax without partial parsing', () {
    for (final input in [
      '',
      'LIST someExpression',
      'TASK FROM #연구 WHERE !completed = false',
      'TASK WHERE completed false',
      'TASK GROUP BY length(file.folder)',
      'TASK GROUP BY file.folder GROUP BY rank',
      'TASK GROUP BY file.folder SORT unrelated',
      'TASK GROUP BY file.folder AS rows',
      'LIST rows.file.name',
      'LIST rows GROUP BY file.folder',
      'LIST rows. GROUP BY file.folder',
      'LIST rows.file.ctime GROUP BY file.folder',
      'TABLE rows.file.name GROUP BY file.folder AS rows.file.name',
      'TABLE rank GROUP BY file.folder',
      'LIST WHERE !',
      'TABLE rank WHERE (completed',
      'TABLE',
      'TABLE WITHOUT ID 상태',
      'TABLE status,',
      'TABLE status AS',
      'TABLE status AS ""',
      'LIST FROM#tag',
      'LIST FROM #tag OR',
      'LIST FROM #tag || #other',
      'LIST FROM [[missing]',
      'LIST FROM ([[missing]]',
      'LIST FROM [[a\nb]]',
      'LIST FROM outgoing("title")',
      'LIST FROM outgoing([[title]]',
      'TABLE [[status]]',
      'LIST WHERE status = [[true]]',
      'LIST LIMIT [[2]]',
      'LIST FROM #tag/',
      'LIST FROM #tag//other',
      'LIST FROM "C:/Lab"',
      'LIST FROM "../Lab"',
      'LIST FROM "a//b"',
      'LIST FROM "//a"',
      r'LIST FROM "a\\b"',
      'LIST WHERE status == true',
      'LIST WHERE status = true AND',
      'LIST WHERE status = true && other = 5',
      'LIST WHERE status = date("2026-11-01")',
      'LIST WHERE status = NaN',
      'LIST WHERE status = 1e999',
      'LIST WHERE status = 0x10',
      r'LIST WHERE status = "\q"',
      'LIST SORT status,',
      'LIST SORT a,b,c,d,e,f,g,h,i',
      'LIST WHERE ${'(' * 17}status${')' * 17}',
      'LIST WHERE ${List.filled(65, 'status').join(' AND ')}',
      'LIST LIMIT 0',
      'LIST LIMIT 101',
      'LIST LIMIT -1',
      'LIST LIMIT 1.0',
      'LIST LIMIT 2 SORT status',
      'LIST FROM #tag FROM #again',
      'LIST\n```',
      'LIST; LIST',
    ]) {
      expect(
        () => DataviewQuery.parse(input),
        throwsFormatException,
        reason: input,
      );
    }
  });

  test('rejects oversized queries, columns, labels and values', () {
    for (final input in [
      'LIST${' ' * 4096}',
      'TABLE ${List.generate(17, (i) => 'field$i').join(', ')}',
      'TABLE field AS "${'a' * 257}"',
      'LIST WHERE field = "${'a' * 1025}"',
      'LIST FROM [[${'a' * 513}]]',
      'LIST FROM ${'(' * 17}#tag${')' * 17}',
      'LIST FROM ${'!' * 17}#tag',
      'LIST FROM ${List.filled(25, '#tag').join(' OR ')}',
    ]) {
      expect(() => DataviewQuery.parse(input), throwsFormatException);
    }
  });
}
