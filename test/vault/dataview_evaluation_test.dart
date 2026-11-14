import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/native/ink_vault_native.dart';
import 'package:saber/data/vault/dataview.dart';
import 'package:saber/data/vault/dataview_query.dart';
import 'package:saber/data/vault/dataview_result.dart';
import 'package:saber/data/vault/knowledge_index.dart';
import 'package:saber/data/vault/library_store.dart';
import 'package:saber/data/vault/workspace_store.dart';

void main() {
  final library = Platform.environment['INK_VAULT_NATIVE_LIBRARY'];
  test('Dataview matches complete folder paths and typed values', () async {
    final directory = await Directory.systemTemp.createTemp(
      'piv-dataview-query-',
    );
    final repository = await NoteRepository.open(
      directory,
      createFormatVersion: 2,
    );
    addTearDown(() async {
      await repository.close();
      final owned = await directory.resolveSymbolicLinks();
      expect(
        p.dirname(owned),
        await Directory.systemTemp.resolveSymbolicLinks(),
      );
      expect(p.basename(owned), startsWith('piv-dataview-query-'));
      await Directory(owned).delete(recursive: true);
    });
    final native = InkVaultNative.open(libraryPath: library!);
    final folders = LibraryStore(repository, native: native);
    final research = await folders.createFolder('연구');
    final child = await folders.createFolder('하위', parentId: research.id);
    final other = await folders.createFolder('연구실');
    final store = WorkspaceStore(repository, native: native);
    Future<VaultNote> note(String title, String properties, String folder) =>
        store.createMarkdown(
          title,
          Uint8List.fromList(utf8.encode('---\n$properties\n---\n본문 #실험')),
          folderId: folder,
        );
    final a = await note('첫 문서', 'rank: 2\nstatus: null', research.id);
    final b = await note('둘 문서', 'rank: 10', child.id);
    final quoted = await note('문자 속성', 'rank: "2"\nstatus: 진행', research.id);
    await note('폴더 접두사만 일치', 'rank: 100\nstatus: null', other.id);
    final noFilePath = await note('CON', 'file.path: spoof', other.id);
    final index = await KnowledgeIndex.build(repository, native);
    DataviewResult evaluate(String query) =>
        evaluateDataview(index, native, DataviewQuery.parse(query));

    final table = evaluate(
      'TABLE file.path, rank FROM "연구" SORT rank ASC LIMIT 2',
    );
    expect(table.columns, ['file.path', 'rank']);
    expect(table.rows.map((row) => row.noteId), [a.id, b.id]);
    expect(table.rows.first.values, ['연구/첫 문서.md', 2]);
    expect(table.rows.last.values, ['연구/하위/둘 문서.md', 10]);
    expect(
      evaluate('LIST FROM "연구" WHERE status = null').rows
          .map((row) => row.noteId),
      [a.id],
    );
    expect(
      evaluate('LIST FROM #실험 WHERE rank = 2').rows.map((row) => row.noteId),
      [a.id],
    );
    expect(
      evaluate('LIST FROM #실험 WHERE rank = "2"').rows.map((row) => row.noteId),
      [quoted.id],
    );
    expect(evaluate('LIST WHERE file.path = null').rows, isEmpty);
    expect(
      evaluate(
        'LIST FROM "연구" WHERE rank = 2 OR rank = 10 AND file.name = "둘 문서"',
      ).rows.map((row) => row.noteId),
      [b.id],
    );
    expect(
      evaluate(
        'LIST FROM "연구" WHERE rank = 2 OR (rank = 10 AND file.name = "둘 문서") '
        'SORT rank ASC',
      ).rows.map((row) => row.noteId),
      [a.id, b.id],
    );
    expect(
      evaluate(
        'LIST FROM "연구" WHERE rank >= 2 AND !(status != null) SORT rank DESC',
      ).rows.map((row) => row.noteId),
      [b.id, a.id],
    );
    expect(
      evaluate('LIST FROM "연구" SORT status ASC, rank DESC').rows
          .map((row) => row.noteId),
      [quoted.id, b.id, a.id],
    );
    expect(
      evaluate('LIST FROM "연구실" WHERE file.name = "CON"').rows
          .map((row) => row.noteId),
      [noFilePath.id],
    );
  }, skip: library == null || !File(library).existsSync());

  test(
    'Dataview combines resolved link directions, folders and tags',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'piv-dataview-links-',
      );
      final repository = await NoteRepository.open(
        directory,
        createFormatVersion: 2,
      );
      addTearDown(() async {
        await repository.close();
        final owned = await directory.resolveSymbolicLinks();
        expect(
          p.dirname(owned),
          await Directory.systemTemp.resolveSymbolicLinks(),
        );
        expect(p.basename(owned), startsWith('piv-dataview-links-'));
        await Directory(owned).delete(recursive: true);
      });
      final native = InkVaultNative.open(libraryPath: library!);
      final folders = LibraryStore(repository, native: native);
      final research = await folders.createFolder('연구');
      final store = WorkspaceStore(repository, native: native);
      Future<VaultNote> note(String title, String body, {String? folderId}) =>
          store.createMarkdown(
            title,
            Uint8List.fromList(utf8.encode(body)),
            folderId: folderId,
          );
      final hub = await note('설계 (', '[[결과 )]]');
      final result = await note('결과 )', '결과 본문', folderId: research.id);
      final source = await note('초안', '[[설계 (|설명]] #실험', folderId: research.id);
      final old = await note(
        '이전',
        '[[설계 (]] #실험 #archive',
        folderId: research.id,
      );
      final outside = await note('외부', '[[설계 (]] #실험');
      final dangling = await note('미해결', '[[없는 문서]]');
      final conflicted = await note('충돌 문서', '처음 본문');
      final parent = (await repository.heads(conflicted.markdownEntityId))
          .single;
      for (final body in ['[[결과 )]]', '[[초안]]']) {
        await repository.commit(
          entityId: conflicted.markdownEntityId,
          kind: EntityKind.markdown,
          ownerNoteId: conflicted.id,
          parentRevisionIds: [parent.revisionId],
          files: {'summary.md': Uint8List.fromList(utf8.encode(body))},
        );
      }
      await store.create('필기 문서');
      final index = await KnowledgeIndex.build(repository, native);
      Set<String> rows(String query, {String? origin}) => evaluateDataview(
        index,
        native,
        DataviewQuery.parse(query),
        originNoteId: origin,
      ).rows.map((row) => row.noteId).toSet();

      expect(rows('LIST FROM [[설계 (#제목]]'), {source.id, old.id, outside.id});
      expect(rows('LIST FROM outgoing([[설계 (]])'), {result.id});
      expect(rows('LIST FROM [[]]', origin: hub.id), {
        source.id,
        old.id,
        outside.id,
      });
      expect(rows('LIST FROM outgoing([[#제목]])', origin: hub.id), {result.id});
      expect(rows('LIST FROM outgoing([[결과 )]])'), isEmpty);
      expect(rows('LIST FROM [[없는 문서]]'), isEmpty);
      expect(index.documents[conflicted.id]?.markdownConflict, isTrue);
      expect(
        index.edges.where((edge) => edge.from == conflicted.id),
        hasLength(2),
      );
      expect(rows('LIST FROM outgoing([[충돌 문서]])'), isEmpty);
      expect(
        rows(
          'LIST FROM ([[설계 (]] AND #실험 | outgoing([[설계 (]])) & "연구" AND -#archive',
        ),
        {source.id, result.id},
      );
      expect(rows('LIST FROM !([[설계 (]] OR outgoing([[설계 (]]))'), {
        hub.id,
        dangling.id,
      });
      expect(() => rows('LIST FROM [[]]'), throwsFormatException);
    },
    skip: library == null || !File(library).existsSync(),
  );

  test(
    'Dataview TASK projects saved Markdown markers without YAML or code',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'piv-dataview-task-',
      );
      final repository = await NoteRepository.open(
        directory,
        createFormatVersion: 2,
      );
      addTearDown(() async {
        await repository.close();
        final owned = await directory.resolveSymbolicLinks();
        expect(
          p.dirname(owned),
          await Directory.systemTemp.resolveSymbolicLinks(),
        );
        expect(p.basename(owned), startsWith('piv-dataview-task-'));
        await Directory(owned).delete(recursive: true);
      });
      final native = InkVaultNative.open(libraryPath: library!);
      final folders = LibraryStore(repository, native: native);
      final research = await folders.createFolder('연구');
      final other = await folders.createFolder('연구실');
      final store = WorkspaceStore(repository, native: native);
      const source =
          '---\r\nrank: 2\r\ncompleted: true\r\nexample: |\r\n'
          '  - [x] YAML\r\n---\r\n😀 본문 #연구/자료\r\n\r\n'
          '- [ ] 첫째\r\n  - [X] 둘째\r\n- [>] 셋째\r- [🟡] 넷째\r\n\r\n'
          '```md\r\n- [ ] 코드\r\n```\r\n';
      Future<VaultNote> note(String title, String body, String folderId) =>
          store.createMarkdown(
            title,
            Uint8List.fromList(utf8.encode(body)),
            folderId: folderId,
          );
      final tasks = await note('작업', source, research.id);
      await note('접두사만 같은 폴더', '- [ ] 외부', other.id);
      final index = await KnowledgeIndex.build(repository, native);
      DataviewResult evaluate(String query) =>
          evaluateDataview(index, native, DataviewQuery.parse(query));

      final result = evaluate('TASK FROM "연구" WHERE rank = 2');
      expect(result.task, isTrue);
      expect(result.table, isFalse);
      expect(result.columns, isEmpty);
      expect(result.rows.map((row) => row.noteId), [
        tasks.id,
        tasks.id,
        tasks.id,
        tasks.id,
      ]);
      expect(result.rows.map((row) => row.task!.text), [
        '첫째',
        '둘째',
        '셋째',
        '넷째',
      ]);
      final head = (await repository.heads(tasks.markdownEntityId)).single;
      for (final row in result.rows) {
        final task = row.task!;
        final offset = source.indexOf('[${task.status}] ${task.text}') + 1;
        expect(task.statusOffset, offset);
        expect(
          task.line,
          RegExp(r'\r\n?|\n').allMatches(source.substring(0, offset)).length +
              1,
        );
        expect(task.revisionId, head.revisionId);
      }
      expect(result.rows.map((row) => row.task!.checked), [
        false,
        true,
        true,
        true,
      ]);
      expect(result.rows.map((row) => row.task!.completed), [
        false,
        true,
        false,
        false,
      ]);
      expect(
        evaluate('TASK FROM #연구 WHERE !completed').rows
            .map((row) => row.task!.text),
        ['첫째', '셋째', '넷째'],
      );
      expect(
        evaluate('TASK FROM "연구" WHERE completed').rows
            .map((row) => row.task!.text),
        ['둘째'],
      );
      expect(
        evaluate('TASK FROM "연구" SORT line DESC LIMIT 2').rows
            .map((row) => row.task!.text),
        ['넷째', '셋째'],
      );
    },
    skip: library == null || !File(library).existsSync(),
  );

  test('Dataview TASK groups typed keys after member sorting', () async {
    final directory = await Directory.systemTemp.createTemp(
      'piv-dataview-group-',
    );
    final repository = await NoteRepository.open(
      directory,
      createFormatVersion: 2,
    );
    addTearDown(() async {
      await repository.close();
      final owned = await directory.resolveSymbolicLinks();
      expect(
        p.dirname(owned),
        await Directory.systemTemp.resolveSymbolicLinks(),
      );
      expect(p.basename(owned), startsWith('piv-dataview-group-'));
      await Directory(owned).delete(recursive: true);
    });
    final native = InkVaultNative.open(libraryPath: library!);
    final store = WorkspaceStore(repository, native: native);
    Future<VaultNote> note(String title, String property) =>
        store.createMarkdown(
          title,
          Uint8List.fromList(utf8.encode('$property- [ ] 첫째\n- [x] 둘째\n')),
        );

    await note('문자', '---\nrank: "2"\n---\n');
    await note('숫자', '---\nrank: 2\n---\n');
    await note('참거짓', '---\nrank: false\n---\n');
    final empty = await note('명시 null', '---\nrank: null\n---\n');
    final absent = await note('없는 속성', '');
    final index = await KnowledgeIndex.build(repository, native);
    DataviewResult evaluate(String query) =>
        evaluateDataview(index, native, DataviewQuery.parse(query));

    final groups = evaluate('TASK SORT line DESC GROUP BY rank').groups!;
    expect(groups.map((group) => group.key), [null, false, 2, '2']);
    expect(groups.first.rows.map((row) => row.noteId).toSet(), {
      empty.id,
      absent.id,
    });
    expect(groups[2].rows.map((row) => row.task!.text), ['둘째', '첫째']);
    expect(groups[2].rows.map((row) => row.task!.completed), [true, false]);
    expect(
      evaluate('TASK GROUP BY rank AS category SORT category DESC LIMIT 2')
          .groups!
          .map((group) => group.key),
      ['2', 2],
    );
    expect(
      evaluate('TASK WHERE !completed GROUP BY completed').groups!.single.key,
      false,
    );
  }, skip: library == null || !File(library).existsSync());

  test(
    'Dataview document groups keep typed keys, projections and source IDs',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'piv-dataview-document-group-',
      );
      final repository = await NoteRepository.open(
        directory,
        createFormatVersion: 2,
      );
      addTearDown(() async {
        await repository.close();
        final owned = await directory.resolveSymbolicLinks();
        expect(
          p.dirname(owned),
          await Directory.systemTemp.resolveSymbolicLinks(),
        );
        expect(p.basename(owned), startsWith('piv-dataview-document-group-'));
        await Directory(owned).delete(recursive: true);
      });
      final native = InkVaultNative.open(libraryPath: library!);
      final folders = LibraryStore(repository, native: native);
      final folderA = await folders.createFolder('A');
      final folderB = await folders.createFolder('B');
      final store = WorkspaceStore(repository, native: native);
      Future<VaultNote> note(String title, String yaml, {String? folderId}) =>
          store.createMarkdown(
            title,
            Uint8List.fromList(utf8.encode('---\n$yaml\n---\n본문 #연구\n')),
            folderId: folderId,
          );

      final low = await note(
        '같은 제목',
        'category: false\nrank: 1',
        folderId: folderA.id,
      );
      final high = await note(
        '같은 제목',
        'category: false\nrank: 9',
        folderId: folderB.id,
      );
      final nil = await note('명시 null', 'category: null');
      final absent = await note('없는 속성', 'rank: 3');
      await note('숫자', 'category: 2');
      await note('문자', 'category: "2"');
      var index = await KnowledgeIndex.build(repository, native);
      DataviewResult evaluate(String query) =>
          evaluateDataview(index, native, DataviewQuery.parse(query));

      const table =
          'TABLE rows.file.name AS "노트", rows.rank, key, 유형 '
          'FROM #연구 SORT rank DESC GROUP BY category AS 유형';
      final result = evaluate(table);
      expect(result.table, isTrue);
      expect(result.rows, isEmpty);
      expect(result.documentGroupLabel, '유형');
      expect(result.documentLinkColumns, {0});
      expect(result.columns, ['노트', 'rows.rank', 'key', '유형']);
      final groups = result.documentGroups!;
      expect(groups.map((group) => group.key), [null, false, 2, '2']);
      expect(groups.first.rows.map((row) => row.noteId), [absent.id, nil.id]);
      expect(groups[1].rows.map((row) => row.noteId), [high.id, low.id]);
      expect(groups[1].values, [
        ['같은 제목', '같은 제목'],
        [9, 1],
        false,
        false,
      ]);
      expect(groups[0].values[1], [3, null]);
      expect(
        evaluate('$table SORT 유형 DESC LIMIT 2').documentGroups!
            .map((group) => group.key),
        ['2', 2],
      );
      final linked = evaluate(
        'LIST rows.file.link FROM "B" GROUP BY file.folder',
      );
      expect(linked.table, isFalse);
      final linkGroup = linked.documentGroups!.single;
      expect(linkGroup.key, 'B');
      expect(linkGroup.values.single, [
        {
          'type': 'file',
          'noteId': high.id,
          'title': high.title,
          'path': 'B/같은 제목.md',
        },
      ]);
      expect(evaluate('LIST FROM #missing GROUP BY category').isEmpty, isTrue);

      for (var number = 0; number <= DataviewQuery.maxResults; number++) {
        await note('추가 노트 $number', 'category: zzz');
      }
      index = await KnowledgeIndex.build(repository, native);
      expect(
        evaluate('LIST GROUP BY category LIMIT 1').documentGroups!.single.key,
        isNull,
      );
      expect(
        () => evaluate('LIST GROUP BY category SORT key DESC LIMIT 1'),
        throwsA(isA<DataviewDocumentGroupLimitException>()),
      );
    },
    skip: library == null || !File(library).existsSync(),
  );
}
