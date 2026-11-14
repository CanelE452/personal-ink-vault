import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/native/ink_vault_native.dart';
import 'package:saber/data/vault/block_page_document.dart';
import 'package:saber/data/vault/card_canvas_document.dart';
import 'package:saber/data/vault/knowledge_index.dart';
import 'package:saber/data/vault/library_store.dart';
import 'package:saber/data/vault/obsidian_vault_import.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/pages/workspace/knowledge_panel.dart';
import 'package:saber/pages/workspace/markdown_editor.dart';

void main() {
  late Directory temp;
  late NoteRepository repository;
  late WorkspaceStore workspace;
  late InkVaultNative native;
  final libraryPath =
      Platform.environment['INK_VAULT_NATIVE_LIBRARY'] ??
      p.absolute('build', 'native', 'windows', 'ink_vault_native.dll');
  setUp(() async {
    native = InkVaultNative.open(libraryPath: libraryPath);
    temp = await Directory.systemTemp.createTemp('ink-knowledge-');
    repository = await NoteRepository.open(temp, createFormatVersion: 2);
    workspace = WorkspaceStore(repository, native: native);
  });
  tearDown(() async {
    await repository.close();
    await temp.delete(recursive: true);
  });

  test(
    'bounded indexing enforces both document and aggregate byte limits',
    () async {
      final a = await workspace.createMarkdown(
        'One',
        Uint8List.fromList(utf8.encode('four')),
      );
      final b = await workspace.createMarkdown(
        'Two',
        Uint8List.fromList(utf8.encode('more')),
      );
      for (final limits in [
        (documents: 1, bytes: 8),
        (documents: 2, bytes: 7),
      ]) {
        await expectLater(
          KnowledgeIndex.build(repository, native, readLimits: limits),
          throwsA(isA<KnowledgeIndexReadLimitExceeded>()),
        );
      }
      final index = await KnowledgeIndex.build(
        repository,
        native,
        readLimits: (documents: 2, bytes: 8),
      );
      expect(index.documents.keys.toSet(), {a.id, b.id});
    },
  );

  test(
    'search expressions use current folders, real filenames and metadata tags',
    () async {
      final library = LibraryStore(repository, native: native);
      final course = await library.createFolder('연구 노트');
      final folder = await library.createFolder('자료', parentId: course.id);
      final reading = await workspace.createMarkdown(
        'Reading 1',
        Uint8List.fromList(
          utf8.encode('---\ntags: [Topic/Sub]\n---\nalpha beta ready\n'),
        ),
        folderId: folder.id,
      );
      await workspace.createMarkdown(
        'Reading 2',
        Uint8List.fromList(
          utf8.encode('---\ntags: [Topicx]\n---\nalpha beta draft\n'),
        ),
        folderId: folder.id,
      );
      final pdf = await workspace.createWithSource(
        '강의 자료',
        fileName: 'Lecture 1.pdf',
        bytes: Uint8List.fromList(utf8.encode('%PDF-1.7\nsynthetic')),
        documentKind: VaultDocumentKind.pdf,
        folderId: folder.id,
      );
      await (await workspace.open(pdf))
          .saveMarkdown('---\ntags: [Lecture/Week1]\n---\nalpha beta overview');
      final index = await KnowledgeIndex.build(repository, native);
      expect(index.search('file:Lecture').toList(), isEmpty);
      expect(
        index
            .search('path:"연구 노트/자료" file:.pdf tag:#lecture', expression: true)
            .map((hit) => hit.id),
        [pdf.id],
      );
      expect(
        index
            .search('tag:#topic content:"alpha beta" -draft', expression: true)
            .map((hit) => hit.id),
        [reading.id],
      );
      await library.renameFolder(course, '보관 노트');
      final reopened = await KnowledgeIndex.build(repository, native);
      expect(reopened.search('path:"연구 노트"', expression: true), isEmpty);
      expect(
        reopened
            .search('path:"보관 노트/자료" file:"Lecture 1"', expression: true)
            .map((hit) => hit.id),
        [pdf.id],
      );
    },
  );

  test(
    'search attaches an exact source range to an opted-in Markdown hit',
    () async {
      const phrase = 'Cafe\u0301 목표';
      final markdown =
          '---\n[broken\n---\n${List.filled(80, '😀').join()}'
          '\nBefore $phrase after\n${List.filled(80, '😀').join()}';
      final note = await workspace.createMarkdown(
        'Source-only title',
        Uint8List.fromList(utf8.encode(markdown)),
      );
      final revision = (await repository.heads(note.markdownEntityId)).single;
      final index = await KnowledgeIndex.build(repository, native);

      expect(index.search('café').single.bodyMatch, isNull);
      expect(
        index.search('Source-only', includeBodyMatches: true).single.bodyMatch,
        isNull,
      );
      for (final (query, expression, expected) in [
        ('café', false, 'Cafe\u0301'),
        ('content:"café 목표"', true, phrase),
      ]) {
        final match = index
            .search(query, expression: expression, includeBodyMatches: true)
            .single
            .bodyMatch;
        expect(match, isNotNull);
        expect(match!.markdownRevisionId, revision.revisionId);
        expect(match.start, markdown.indexOf(expected));
        expect(match.end, match.start + expected.length);
        expect(match.text, expected);
        expect(match.excerpt, contains('Before $phrase after'));
        expect(match.excerpt.length, lessThanOrEqualTo(180));
        expect(match.excerpt.runes, isNot(contains(0xfffd)));
      }
    },
  );

  test('block and canvas text join real search and links without replacing human Markdown', () async {
    final target = await workspace.create(
      'Target',
      documentKind: VaultDocumentKind.markdown,
    );
    final page = await workspace.create(
      'Page',
      documentKind: VaultDocumentKind.page,
    );
    final canvas = await workspace.create(
      'Map',
      documentKind: VaultDocumentKind.canvas,
    );
    final pageSession = await workspace.open(page);
    await pageSession.saveMarkdown('Human summary');
    final body = const BlockPageDocument.empty().copyWith(
      blocks: [
        BlockPageBlock.create(
          type: 'paragraph',
          text: 'Structured needle [[Target]] #course',
        ),
      ],
    );
    await pageSession.saveInk({
      'page.json': Uint8List.fromList(utf8.encode(jsonEncode(body.toJson()))),
    });
    final board = const CardCanvasDocument.empty().copyWith(
      nodes: [
        CardCanvasNode.text(id: newId(), text: 'Canvas needle [[Target]]'),
      ],
    );
    await (await workspace.open(canvas)).saveInk({
      'board.canvas': Uint8List.fromList(
        utf8.encode(jsonEncode(board.toJson())),
      ),
    });
    expect((await workspace.search('Structured needle')).map((n) => n.id), [
      page.id,
    ]);
    final index = await KnowledgeIndex.build(repository, native);
    expect(index.search('Structured needle').map((n) => n.id), [page.id]);
    expect(index.search('Canvas needle').map((n) => n.id), [canvas.id]);
    expect(
      index
          .search('Structured needle', includeBodyMatches: true)
          .single
          .bodyMatch,
      isNull,
    );
    expect(
      index.search('Human summary', includeBodyMatches: true).single.bodyMatch,
      isNull,
    );
    expect(index.backlinks(target.id).map((n) => n.id).toSet(), {
      page.id,
      canvas.id,
    });
    expect(await pageSession.readMarkdown(), 'Human summary');
  });

  test('actual Rust indexes Unicode aliases anchors nested tags and ambiguous targets', () async {
    final source = await workspace.create(
      '입문',
      documentKind: VaultDocumentKind.markdown,
    );
    final cafe = await workspace.create(
      'Café',
      documentKind: VaultDocumentKind.markdown,
    );
    final percent = await workspace.create(
      '100% #노트',
      documentKind: VaultDocumentKind.markdown,
    );
    await workspace.create('동명', documentKind: VaultDocumentKind.markdown);
    await workspace.create('동명', documentKind: VaultDocumentKind.markdown);
    await (await workspace.open(cafe)).saveMarkdown('공통 엔진을 연결합니다');
    await (await workspace.open(source)).saveMarkdown(
      '[[Cafe\u0301#정리|참고]] [[${cafe.id}#page-1|ID]] [[동명]] [[#오늘]] #연구/그래프 #Rust\n'
      '`[[없는문서]] #코드태그`\n\n```text\n[[없는문서]] #블록태그\n```',
    );
    final index = await KnowledgeIndex.build(repository, native);
    expect(index.documents[source.id]!.tags, {'연구', '연구/그래프', 'rust'});
    expect(index.backlinks(cafe.id).map((d) => d.id), [source.id]);
    expect(index.tags['연구/그래프']!.map((d) => d.id), [source.id]);
    expect(
      index.edges.any((edge) => edge.from == source.id && edge.to == cafe.id),
      isTrue,
    );
    expect(index.unresolved.map((link) => link.target), ['동명']);
    final resolved = index.resolveWikiLink(
      Uri(scheme: 'inkwiki', path: 'Cafe\u0301', fragment: '정리').toString(),
      fromNoteId: source.id,
    )!;
    expect(resolved.noteId, cafe.id);
    expect(resolved.anchor, '정리');
    expect(index.resolveWikiLink('동명', fromNoteId: source.id), isNull);
    expect(
      index.resolveWikiLink('Café#', fromNoteId: source.id)!.anchor,
      isNull,
    );
    expect(
      index.resolveMarkdownLink('Caf%C3%A9.md#', fromNoteId: source.id)!.anchor,
      isNull,
    );
    expect(index.resolveWikiLink('${cafe.id}.md#page-1')!.noteId, cafe.id);
    expect(
      index.resolveWikiLink('#오늘', fromNoteId: source.id)!.noteId,
      source.id,
    );
    expect(index.resolveWikiLink('https://example.com'), isNull);
    final literal = index.resolveWikiLink(
      Uri(scheme: 'inkwiki', path: '100% #노트', fragment: 'x#y%').toString(),
    )!;
    expect(literal.noteId, percent.id);
    expect(literal.anchor, 'x#y%');
    expect(index.search('공통 엔진').map((match) => match.id), [cafe.id]);
    expect(index.search('cafe\u0301').first.id, cafe.id);
  });

  test(
    'indexes complete Obsidian property links and refreshes after save',
    () async {
      final folder = await LibraryStore(repository).createFolder('Research');
      final source = await workspace.createMarkdown(
        'Source',
        Uint8List(0),
        folderId: folder.id,
      );
      final project = await workspace.createMarkdown('Project', Uint8List(0));
      final topic = await workspace.createMarkdown(
        'Topic',
        Uint8List(0),
        folderId: folder.id,
      );
      final followup = await workspace.createMarkdown(
        'Followup',
        Uint8List(0),
        folderId: folder.id,
      );
      final wrongTopic = await workspace.createMarkdown('Topic', Uint8List(0));
      final ignored = await workspace.createMarkdown('Ignored', Uint8List(0));
      final body = await workspace.createMarkdown('Body', Uint8List(0));
      final session = await workspace.open(source);
      const original = r'''
---
project: '[[Project#Overview]]'
duplicates: ['[[Project#Overview]]', '[[Project#Overview|Project]]']
details:
  nested:
    - '[[./Topic#Notes]]'
    - '[follow](./Followup.md#^task)'
examples:
  - 'see [[Ignored]]'
  - '\[[Ignored]]'
  - '`[[Ignored]]`'
  - '[website](https://example.test/Ignored.md)'
# [[Ignored]]
---
[[Body]] #body-tag
''';
      await session.saveMarkdown(original);

      final index = await KnowledgeIndex.build(repository, native);
      final targets = index.edges.where((edge) => edge.from == source.id);
      expect(
        targets.map((edge) => edge.to),
        unorderedEquals([project.id, topic.id, followup.id, body.id]),
      );
      for (final target in [project, topic, followup, body]) {
        expect(index.backlinks(target.id).map((note) => note.id), [source.id]);
      }
      expect(index.backlinks(wrongTopic.id), isEmpty);
      expect(index.backlinks(ignored.id), isEmpty);
      expect(index.unresolved, isEmpty);
      expect(
        index.documents[source.id]!.links.map(
          (link) => (link.targetId, link.anchor),
        ),
        unorderedEquals([
          (project.id, 'Overview'),
          (topic.id, 'Notes'),
          (followup.id, '^task'),
          (body.id, null),
        ]),
      );
      expect(index.documents[source.id]!.markdown, original);
      expect(index.documents[source.id]!.tags, {'body-tag'});
      expect(await session.readMarkdown(), original);

      const revised = '''
---
project: '[[Followup#Next]]'
---
[[Body]] #body-tag
''';
      await session.saveMarkdown(revised);
      final refreshed = await KnowledgeIndex.build(repository, native);
      expect(refreshed.backlinks(project.id), isEmpty);
      expect(refreshed.backlinks(topic.id), isEmpty);
      expect(refreshed.backlinks(followup.id).map((note) => note.id), [
        source.id,
      ]);
      expect(refreshed.backlinks(body.id).map((note) => note.id), [source.id]);
      expect(await session.readMarkdown(), revised);
    },
  );

  test(
    'ignores malformed Obsidian properties while indexing body links',
    () async {
      final source = await workspace.createMarkdown('Source', Uint8List(0));
      final ignored = await workspace.createMarkdown('Ignored', Uint8List(0));
      final body = await workspace.createMarkdown('Body', Uint8List(0));
      final session = await workspace.open(source);
      const original = '''
---
project: '[[Ignored]]'
broken: [unclosed
---
[[Body]]
''';
      await session.saveMarkdown(original);

      final index = await KnowledgeIndex.build(repository, native);
      expect(index.backlinks(ignored.id), isEmpty);
      expect(index.backlinks(body.id).map((note) => note.id), [source.id]);
      expect(index.unresolved, isEmpty);
      expect(await session.readMarkdown(), original);
    },
  );

  test(
    'indexes a property backlink from a real Obsidian folder import',
    () async {
      final source = Directory(p.join(temp.path, 'source'));
      final course = await Directory(p.join(source.path, 'Course'))
          .create(recursive: true);
      const markdown = "---\nreading: '[[./자료#정리]]'\n---\n\n수업 노트\n";
      final raw = utf8.encode(markdown);
      final original = await File(p.join(course.path, '노트.md'))
          .writeAsBytes(raw);
      await File(p.join(course.path, '자료.md')).writeAsString('# 정리\n');
      final imported = await importObsidianVault(
        vaultsDirectory: Directory(p.join(temp.path, 'imports')),
        sourceFolder: source,
        sourceName: 'fixture',
        native: native,
      );
      try {
        expect(imported.noteCount, 2);
        final store = WorkspaceStore(imported.repository, native: native);
        final notes = {for (final note in await store.list()) note.title: note};
        final index = await KnowledgeIndex.build(imported.repository, native);
        expect(index.backlinks(notes['자료']!.id).single.id, notes['노트']!.id);
        expect(index.documents[notes['노트']!.id]!.links.single.anchor, '정리');
        expect(await (await store.open(notes['노트']!)).readMarkdown(), markdown);
        expect(await original.readAsBytes(), raw);
      } finally {
        await imported.repository.close();
      }
    },
  );

  test('Canvas bindings create stable backlinks without interpreting file paths or labels as links', () async {
    final target = await workspace.create(
      'Target',
      documentKind: VaultDocumentKind.markdown,
    );
    final decoy = await workspace.create('Decoy');
    final canvas = await workspace.create(
      'Canvas',
      documentKind: VaultDocumentKind.canvas,
    );
    final fileCard = CardCanvasNode.note(
      id: newId(),
      noteId: target.id,
      title: 'File card [[Decoy]]',
    ).toJson();
    final board = CardCanvasDocument.fromJson({
      'nodes': [
        {...fileCard, 'file': 'Folder/Target.md', 'inkVaultNoteId': target.id},
        {...fileCard, 'id': newId(), 'file': decoy.id, 'inkVaultNoteId': null},
      ],
    });
    await (await workspace.open(canvas)).saveInk({
      'board.canvas': Uint8List.fromList(
        utf8.encode(jsonEncode(board.toJson())),
      ),
    });
    final index = await KnowledgeIndex.build(repository, native);
    expect(index.backlinks(target.id).map((note) => note.id), [canvas.id]);
    expect(index.backlinks(decoy.id), isEmpty);
    expect(index.search('File card').map((note) => note.id), [canvas.id]);

    final incomplete = board.copyWith(
      nodes: [
        CardCanvasNode.text(id: newId(), text: '```dart\nUnclosed fence'),
        ...board.nodes,
      ],
    );
    await (await workspace.open(canvas)).saveInk({
      'board.canvas': Uint8List.fromList(
        utf8.encode(jsonEncode(incomplete.toJson())),
      ),
    });
    final after = await KnowledgeIndex.build(repository, native);
    expect(after.backlinks(target.id).map((note) => note.id), [canvas.id]);
  });

  test(
    'all Markdown branches are analyzed independently and trash is excluded',
    () async {
      final source = await workspace.create(
        'Conflict',
        documentKind: VaultDocumentKind.markdown,
      );
      final target = await workspace.create(
        'Target',
        documentKind: VaultDocumentKind.markdown,
      );
      final removed = await workspace.create(
        'Removed',
        documentKind: VaultDocumentKind.markdown,
      );
      await (await workspace.open(removed)).saveMarkdown('[[Target]] #removed');
      await workspace.setDeleted(removed, true);
      final first = await workspace.open(source);
      final second = await workspace.open(source);
      await first.saveMarkdown('```\n[[Hidden]] #hidden');
      await second.saveMarkdown('[[Target]] #kept');
      final index = await KnowledgeIndex.build(repository, native);
      expect(index.documents.keys, isNot(contains(removed.id)));
      expect(index.documents[source.id]!.markdownConflict, isTrue);
      expect(
        index.search('kept', includeBodyMatches: true).single.bodyMatch,
        isNull,
      );
      expect(index.backlinks(target.id).map((d) => d.id), [source.id]);
      expect(index.documents[source.id]!.tags, {'kept'});
      expect(index.unresolved, isEmpty);
    },
  );

  testWidgets('backlinks tags and graph open real indexed document IDs', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1100, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final setup = await tester.runAsync(() async {
      final source = await workspace.create(
        '입문',
        documentKind: VaultDocumentKind.markdown,
      );
      final target = await workspace.create(
        '대상',
        documentKind: VaultDocumentKind.markdown,
      );
      await (await workspace.open(source)).saveMarkdown('[[대상]] #연구/그래프');
      final index = await KnowledgeIndex.build(repository, native);
      return (source, target, index);
    });
    final (source, target, index) = setup!;
    final opened = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: KnowledgePanel(
            index: index,
            selectedNoteId: target.id,
            onOpenNote: opened.add,
          ),
        ),
      ),
    );
    await tester.tap(find.text('입문'));
    expect(opened, [source.id]);
    await tester.tap(find.text('태그'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('#연구/그래프'));
    await tester.pumpAndSettle();
    expect(find.text('입문'), findsOneWidget);
    await tester.tap(find.text('그래프'));
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('knowledge-node-${source.id}')), findsOneWidget);
    expect(find.byKey(ValueKey('knowledge-node-${target.id}')), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('knowledge-node-${target.id}')));
    expect(opened.last, target.id);
    final semantics = tester.ensureSemantics();
    try {
      expect(find.bySemanticsLabel('문서: 입문'), findsOneWidget);
      final sourceLabel = find.descendant(
        of: find.byKey(ValueKey('knowledge-node-${source.id}')),
        matching: find.byType(Text),
      );
      Focus.of(tester.element(sourceLabel)).requestFocus();
      await tester.pump();
      final previousOpens = opened.length;
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(opened, hasLength(previousOpens + 1));
      expect(opened.last, source.id);
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('local graph settings filter connected notes on a compact view', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(360, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final setup = await tester.runAsync(() async {
      final ids = <String, String>{};
      const notes = {
        'Center': '[[Outgoing]] [[Peer]]',
        'Incoming': '[[Center]]',
        'Outgoing': '[[Peer]] [[Second hop]]',
        'Peer': '',
        'Second hop': '',
        'Disconnected': '',
      };
      for (final MapEntry(key: title, value: markdown) in notes.entries) {
        final note = await workspace.createMarkdown(
          title,
          Uint8List.fromList(utf8.encode(markdown)),
        );
        ids[title] = note.id;
      }
      return (ids, await KnowledgeIndex.build(repository, native));
    });
    final (ids, index) = setup!;
    final opened = <String>[];
    final selected = ValueNotifier<String?>(ids['Center']);
    addTearDown(selected.dispose);

    Future<void> tap(Finder finder) async {
      await tester.tap(finder);
      await tester.pumpAndSettle();
    }

    Finder node(String title) =>
        find.byKey(ValueKey('knowledge-node-${ids[title]}'));

    void expectGraph(Set<String> visible, int edges) {
      for (final title in ids.keys) {
        expect(
          node(title),
          visible.contains(title) ? findsOneWidget : findsNothing,
        );
      }
      expect(
        find.textContaining('${visible.length}개 문서 · $edges개 연결'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    }

    Future<void> settings() => tap(find.text('그래프 설정'));
    Future<void> apply() => tap(find.text('적용'));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<String?>(
            valueListenable: selected,
            builder: (context, noteId, child) => KnowledgePanel(
              index: index,
              selectedNoteId: noteId,
              onOpenNote: opened.add,
            ),
          ),
        ),
      ),
    );
    await tap(find.text('그래프'));
    expectGraph(ids.keys.toSet(), 5);
    await tap(find.text('현재 문서'));
    expectGraph({'Center', 'Incoming', 'Outgoing', 'Peer'}, 3);

    await settings();
    await tap(find.widgetWithText(SwitchListTile, '이웃 간 연결'));
    await apply();
    expectGraph({'Center', 'Incoming', 'Outgoing', 'Peer'}, 4);

    await settings();
    await tap(find.byKey(const ValueKey('knowledge-graph-depth')));
    await tap(find.text('2단계').last);
    await apply();
    expectGraph({'Center', 'Incoming', 'Outgoing', 'Peer', 'Second hop'}, 5);

    await tap(find.text('태그'));
    await tap(find.text('그래프'));
    expectGraph({'Center', 'Incoming', 'Outgoing', 'Peer', 'Second hop'}, 5);

    await settings();
    await tap(find.widgetWithText(SwitchListTile, '나가는 링크'));
    await apply();
    expectGraph({'Center', 'Incoming'}, 1);

    await settings();
    await tap(find.widgetWithText(SwitchListTile, '들어오는 링크'));
    await apply();
    expectGraph({'Center'}, 0);

    await settings();
    await tap(find.widgetWithText(SwitchListTile, '나가는 링크'));
    await apply();
    expectGraph({'Center', 'Outgoing', 'Peer', 'Second hop'}, 4);
    await tap(node('Outgoing'));
    expect(opened, [ids['Outgoing']]);

    await tap(find.text('전체'));
    expectGraph(ids.keys.toSet(), 5);
    await tap(find.text('현재 문서'));
    selected.value = null;
    await tester.pumpAndSettle();
    expectGraph(ids.keys.toSet(), 5);
    expect(
      tester
          .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, '현재 문서'))
          .onSelected,
      isNull,
    );
  });

  testWidgets(
    'wikilink preview emits safe URI links while leaving code untouched',
    (tester) async {
      final opened = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MarkdownPreview(
              source:
                  '[[Café#정리|참고]]\n\n`[[Café|코드]]`\n\n```\n[[Café|블록]]\n```\n\n'
                  '[remote](inkwiki://remote/path)\n\n[unsafe](javascript:alert(1))',
              onOpenLink: opened.add,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final label in ['참고', 'remote', 'unsafe']) {
        await tester.tap(find.text(label, findRichText: true).last);
        await tester.pump();
      }
      expect(opened, [
        'inkwiki:${Uri.encodeComponent('Café')}#${Uri.encodeComponent('정리')}',
      ]);
      expect(find.text('[[Café|코드]]', findRichText: true), findsWidgets);
      expect(find.text('[[Café|블록]]', findRichText: true), findsWidgets);
    },
  );
}
