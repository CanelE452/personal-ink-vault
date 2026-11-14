import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/vault/dataview_result.dart';
import 'package:saber/pages/workspace/markdown_editor.dart';

String _fence(String query) => '```dataview\n$query\n```';

DataviewResult _list(String id, String title) => DataviewResult(
  table: false,
  columns: const [],
  rows: [DataviewRow(noteId: id, title: title, values: const [])],
);

Widget _preview(
  String source,
  MarkdownDataviewAccess access, {
  VaultMarkdownEmbedAccess? embeds,
}) => MaterialApp(
  home: Scaffold(
    body: MarkdownPreview(
      source: source,
      onOpenLink: (_) {},
      dataview: access,
      vaultEmbeds: embeds,
      anchorResolver: (anchor, candidates) {
        final index = candidates.indexWhere(
          (candidate) => candidate['text'] == anchor,
        );
        return index < 0 ? null : index;
      },
    ),
  ),
);

void main() {
  testWidgets(
    'Dataview TASK toggles standard checkboxes and opens their source',
    (tester) async {
      const first = DataviewTask(
        text: '연구 초안 검토',
        line: 4,
        status: ' ',
        statusOffset: 22,
        revisionId: 'markdown-1',
      );
      const custom = DataviewTask(
        text: '협업 응답 대기',
        line: 7,
        status: '-',
        statusOffset: 55,
        revisionId: 'markdown-2',
      );
      final saving = Completer<void>();
      final changes = <(String, int, bool)>[];
      final opened = <String>[];
      var completed = false;
      final access = MarkdownDataviewAccess(
        evaluate: (_) async => DataviewResult(
          table: false,
          task: true,
          columns: const [],
          rows: [
            DataviewRow(
              noteId: 'draft',
              title: '초안 원본',
              values: const [],
              task: completed
                  ? const DataviewTask(
                      text: '연구 초안 검토',
                      line: 4,
                      status: 'x',
                      statusOffset: 22,
                      revisionId: 'markdown-3',
                    )
                  : first,
            ),
            const DataviewRow(
              noteId: 'pending',
              title: '협업 원본',
              values: [],
              task: custom,
            ),
          ],
        ),
        openNote: opened.add,
        toggleTask: (row, value) async {
          changes.add((row.noteId, row.task!.line, value));
          await saving.future;
          completed = value;
        },
      );
      await tester.pumpWidget(_preview(_fence('TASK'), access));
      await tester.pumpAndSettle();

      expect(find.text(first.text), findsOneWidget);
      expect(find.text(custom.text), findsOneWidget);
      expect(find.text('[${custom.status}]'), findsOneWidget);
      final checkbox = find.byType(Checkbox);
      expect(checkbox, findsOneWidget);
      expect(tester.widget<Checkbox>(checkbox).value, isFalse);
      await tester.tap(checkbox);
      await tester.pump();
      expect(changes, [('draft', 4, true)]);
      expect(tester.widget<Checkbox>(checkbox).onChanged, isNull);
      saving.complete();
      await tester.pumpAndSettle();
      expect(tester.widget<Checkbox>(checkbox).value, isTrue);

      await tester.tap(find.text('협업 원본 · 7줄'));
      expect(opened, ['pending']);
    },
  );

  testWidgets('Dataview TASK waits for the replacement scope after saving', (
    tester,
  ) async {
    const task = DataviewTask(
      text: '자료 확인',
      line: 1,
      status: ' ',
      statusOffset: 3,
      revisionId: 'original',
    );
    const original = DataviewResult(
      table: false,
      task: true,
      columns: [],
      rows: [
        DataviewRow(noteId: 'source', title: '원본', values: [], task: task),
      ],
    );
    final saving = Completer<void>();
    var current = true;
    var staleReads = 0;
    final oldAccess = MarkdownDataviewAccess(
      evaluate: (_) async {
        if (!current) staleReads++;
        return original;
      },
      openNote: (_) {},
      isCurrent: () => current,
      toggleTask: (_, _) async {
        await saving.future;
        current = false;
      },
    );
    const query = 'TASK WHERE !completed';
    await tester.pumpWidget(_preview(_fence(query), oldAccess));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Checkbox));
    await tester.pump();
    saving.complete();
    await tester.idle();
    expect(staleReads, 0);
    await tester.pump();
    expect(staleReads, 0);

    final newAccess = MarkdownDataviewAccess(
      evaluate: (_) async =>
          const DataviewResult(table: false, task: true, columns: [], rows: []),
      openNote: (_) {},
    );
    await tester.pumpWidget(_preview(_fence(query), newAccess));
    await tester.pumpAndSettle();
    expect(find.text('조건에 맞는 할 일이 없습니다.'), findsOneWidget);
    expect(find.byType(Checkbox), findsNothing);
    expect(staleReads, 0);
  });

  testWidgets('Markdown editor evaluates genuine Dataview AST fences only', (
    tester,
  ) async {
    final queries = <String>[];
    final opened = <String>[];
    const source =
        '# 집계\n\n'
        '````markdown\n```dataview\nLIST FROM #nested\n```\n````\n\n'
        '```dataviewjs\nLIST FROM #script\n```\n\n'
        '    ```dataview\n    LIST FROM #indented\n    ```\n\n'
        '~~~dataview\nLIST FROM #visible\n~~~';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MarkdownEditor(
            source: source,
            readOnly: false,
            dirty: false,
            onChanged: (_) {},
            onSave: () {},
            onOpenLink: (_) {},
            dataview: MarkdownDataviewAccess(
              evaluate: (query) async {
                queries.add(query.trim());
                return _list('note-1', '조회된 노트');
              },
              openNote: opened.add,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(queries, ['LIST FROM #visible']);
    expect(
      find.textContaining('LIST FROM #nested', findRichText: true),
      findsOneWidget,
    );
    expect(
      find.textContaining('LIST FROM #script', findRichText: true),
      findsOneWidget,
    );
    await tester.ensureVisible(find.text('조회된 노트'));
    await tester.tap(find.text('조회된 노트'));
    expect(opened, ['note-1']);

    await tester.tap(find.byTooltip('원문 편집'));
    await tester.pumpAndSettle();
    expect(find.text('조회된 노트'), findsNothing);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      source,
    );
  });

  testWidgets('only the selected section of an embedded note runs Dataview', (
    tester,
  ) async {
    final queries = <(String, String)>[];
    final opened = <String>[];
    await tester.pumpWidget(
      _preview(
        '${_fence('LIST FROM [[]]')}\n\n![[Embedded#Wanted]]',
        MarkdownDataviewAccess(
          evaluate: (query) async {
            queries.add(('host', query.trim()));
            return _list('root-result', '바깥 결과');
          },
          evaluateFromNote: (query, noteId) async {
            queries.add((noteId, query.trim()));
            return _list('linked', '포함된 결과');
          },
          openNote: opened.add,
        ),
        embeds: VaultMarkdownEmbedAccess(
          sourceNoteId: 'host',
          load: (_, _) async => VaultMarkdownEmbed(
            noteId: 'embedded',
            title: 'Embedded',
            anchor: 'Wanted',
            source:
                '## Wanted\n\n${_fence('LIST FROM [[]]')}\n\n'
                '## Next\n\n${_fence('LIST FROM #outside')}',
          ),
          openLink: (_, _) {},
          loadImage: (_, _) async => null,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(queries, [
      ('host', 'LIST FROM [[]]'),
      ('embedded', 'LIST FROM [[]]'),
    ]);
    await tester.tap(find.text('포함된 결과'));
    expect(opened, ['linked']);
  });

  testWidgets('scope and query changes discard late results and old buttons', (
    tester,
  ) async {
    final old = Completer<DataviewResult>();
    final current = Completer<DataviewResult>();
    final changed = Completer<DataviewResult>();
    final opened = <String>[];
    final before = MarkdownDataviewAccess(
      evaluate: (_) => old.future,
      openNote: opened.add,
    );
    final after = MarkdownDataviewAccess(
      evaluate: (query) =>
          query.trim().endsWith('#new') ? changed.future : current.future,
      openNote: opened.add,
    );
    await tester.pumpWidget(_preview(_fence('LIST FROM #same'), before));
    expect(find.text('Dataview 결과 불러오는 중'), findsOneWidget);
    await tester.pumpWidget(_preview(_fence('LIST FROM #same'), after));
    old.complete(_list('old-id', '이전 보관함 결과'));
    await tester.pump();
    expect(find.text('이전 보관함 결과'), findsNothing);
    expect(find.text('Dataview 결과 불러오는 중'), findsOneWidget);

    current.complete(_list('current-id', '현재 보관함 결과'));
    await tester.pumpAndSettle();
    final previousButton = tester.widget<TextButton>(
      find.widgetWithText(TextButton, '현재 보관함 결과'),
    );
    await tester.pumpWidget(_preview(_fence('LIST FROM #new'), after));
    expect(find.text('현재 보관함 결과'), findsNothing);
    previousButton.onPressed?.call();
    expect(opened, isEmpty);
    changed.complete(_list('new-id', '새 쿼리 결과'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('새 쿼리 결과'));
    expect(opened, ['new-id']);
  });

  testWidgets(
    'Dataview table is readable on a phone and handles empty or errors',
    (tester) async {
      tester.view.physicalSize = const Size(320, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final opened = <String>[];
      final access = MarkdownDataviewAccess(
        evaluate: (query) async => switch (query.trim()) {
          'TABLE topic' => const DataviewResult(
            table: true,
            columns: ['긴 속성 이름'],
            rows: [
              DataviewRow(
                noteId: 'phone',
                title: '테이블에서 여는 노트',
                values: ['여러 줄로 감길 수 있는 긴 속성 값'],
              ),
            ],
          ),
          'LIST FROM #missing' => const DataviewResult(
            table: false,
            columns: [],
            rows: [],
          ),
          'unsupported' => throw const FormatException('Internal grammar'),
          _ => throw StateError('internal vault path'),
        },
        openNote: opened.add,
      );
      await tester.pumpWidget(_preview(_fence('TABLE topic'), access));
      await tester.pumpAndSettle();
      expect(find.text('긴 속성 이름'), findsOneWidget);
      expect(find.text('여러 줄로 감길 수 있는 긴 속성 값'), findsOneWidget);
      expect(find.byType(Table), findsNothing);
      await tester.tap(find.text('테이블에서 여는 노트'));
      expect(opened, ['phone']);
      expect(tester.takeException(), isNull);

      tester.view.physicalSize = const Size(1000, 720);
      await tester.pumpAndSettle();
      expect(find.byType(Table), findsOneWidget);
      expect(find.text('노트'), findsOneWidget);

      for (final (query, message) in [
        ('LIST FROM #missing', '조건에 맞는 노트가 없습니다.'),
        ('unsupported', '지원하지 않는 Dataview 쿼리입니다.'),
        ('failure', 'Dataview 결과를 불러올 수 없습니다.'),
      ]) {
        await tester.pumpWidget(_preview(_fence(query), access));
        await tester.pumpAndSettle();
        expect(find.text(message), findsOneWidget);
        expect(find.text('테이블에서 여는 노트'), findsNothing);
      }
      expect(find.textContaining('internal vault path'), findsNothing);
    },
  );

  testWidgets('Dataview forwards fence whitespace for the raw query bound', (
    tester,
  ) async {
    final source = 'LIST FROM #note${' ' * 4096}';
    String? received;
    await tester.pumpWidget(
      _preview(
        _fence(source),
        MarkdownDataviewAccess(
          evaluate: (query) async {
            received = query;
            throw const FormatException('Query exceeds raw limit');
          },
          openNote: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(received, '$source\n');
    expect(find.text('지원하지 않는 Dataview 쿼리입니다.'), findsOneWidget);
  });

  testWidgets(
    'Grouped Dataview table renders one row per key and opens same-name notes',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final opened = <String>[];
      final access = MarkdownDataviewAccess(
        evaluate: (_) async => DataviewResult.groupedDocuments(
          table: true,
          columns: ['원본', '순위'],
          groupLabel: '종류',
          documentLinkColumns: {0},
          groups: [
            DataviewDocumentGroup(
              false,
              const [
                DataviewRow(
                  noteId: 'a',
                  title: '동일 제목',
                  path: 'A/동일 제목.md',
                  values: [],
                ),
                DataviewRow(
                  noteId: 'b',
                  title: '동일 제목',
                  path: 'B/동일 제목.md',
                  values: [],
                ),
              ],
              const [
                ['동일 제목', '동일 제목'],
                [9, 1],
              ],
            ),
            DataviewDocumentGroup(
              null,
              const [DataviewRow(noteId: 'c', title: '그룹 없음 원본', values: [])],
              const [
                ['그룹 없음 원본'],
                [null],
              ],
            ),
          ],
        ),
        openNote: opened.add,
      );
      await tester.pumpWidget(
        _preview(
          _fence(
            'TABLE rows.file.name AS "원본", rows.rank AS "순위" GROUP BY type AS 종류',
          ),
          access,
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.widget<Table>(find.byType(Table)).children, hasLength(3));
      expect(find.text('종류'), findsOneWidget);
      expect(find.text('false'), findsOneWidget);
      expect(find.text('9'), findsOneWidget);
      expect(find.text('1'), findsOneWidget);
      expect(find.byTooltip('A/동일 제목.md'), findsOneWidget);
      expect(find.byTooltip('B/동일 제목.md'), findsOneWidget);
      await tester.tap(find.text('동일 제목').at(1));
      expect(opened, ['b']);

      tester.view.physicalSize = const Size(320, 720);
      await tester.pumpAndSettle();
      expect(find.byType(Table), findsNothing);
      expect(find.text('(값 없음)'), findsOneWidget);
      await tester.ensureVisible(find.text('그룹 없음 원본'));
      await tester.tap(find.text('그룹 없음 원본'));
      expect(opened, ['b', 'c']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Dataview shares the block budget across primary and embeds', (
    tester,
  ) async {
    final queries = <String>[];
    final access = MarkdownDataviewAccess(
      evaluate: (query) async {
        queries.add(query.trim());
        return const DataviewResult(table: false, columns: [], rows: []);
      },
      openNote: (_) {},
    );
    final rootQueries = [for (var i = 0; i < 11; i++) 'LIST FROM #root-$i'];
    final source = [...rootQueries.map(_fence), '![[Embedded]]'].join('\n\n');
    final embeds = VaultMarkdownEmbedAccess(
      sourceNoteId: 'root',
      load: (_, _) async => VaultMarkdownEmbed(
        noteId: 'embedded',
        title: 'Embedded',
        source: [for (var i = 0; i < 3; i++) _fence('LIST FROM #embed-$i')]
            .join('\n\n'),
      ),
      openLink: (_, _) {},
      loadImage: (_, _) async => null,
    );
    final limited = find.text('Dataview 조회는 이 미리보기에서 12개까지 표시합니다.');

    await tester.pumpWidget(_preview(source, access, embeds: embeds));
    await tester.pumpAndSettle();
    expect(queries, [...rootQueries, 'LIST FROM #embed-0']);
    expect(limited, findsNWidgets(2));

    await tester.pumpWidget(_preview(source, access, embeds: embeds));
    await tester.pumpAndSettle();
    expect(queries, hasLength(12));
    expect(limited, findsNWidgets(2));
  });
}
