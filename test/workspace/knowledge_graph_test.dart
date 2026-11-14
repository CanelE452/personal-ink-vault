import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/native/ink_vault_native.dart';
import 'package:saber/data/vault/knowledge_index.dart';
import 'package:saber/data/vault/workspace_store.dart';

void main() {
  late KnowledgeIndex index;
  final ids = <String, String>{};
  const notes = {
    'A': '[[B]] [[B]] [[P]] [[A]] [[Missing]] [[Trashed]]',
    'B': '[[D]] [[P]]',
    'C': '[[A]] [[D]]',
    'D': '[[B]] [[E]]',
    'E': '[[F]]',
    'F': '[[G]]',
    'G': '[[H]]',
    'H': '',
    'P': '[[B]]',
    'Isolated': '',
    'Trashed': '[[A]]',
  };

  setUpAll(() async {
    final libraryPath =
        Platform.environment['INK_VAULT_NATIVE_LIBRARY'] ??
        p.absolute('build', 'native', 'windows', 'ink_vault_native.dll');
    final native = InkVaultNative.open(libraryPath: libraryPath);
    final temp = await Directory.systemTemp.createTemp('ink-local-graph-');
    try {
      final repository = await NoteRepository.open(
        temp,
        createFormatVersion: 2,
      );
      try {
        final workspace = WorkspaceStore(repository, native: native);
        for (final MapEntry(key: title, value: markdown) in notes.entries) {
          final note = await workspace.createMarkdown(
            title,
            utf8.encode(markdown),
          );
          ids[title] = note.id;
          if (title == 'Trashed') await workspace.setDeleted(note, true);
        }
        index = await KnowledgeIndex.build(repository, native);
      } finally {
        await repository.close();
      }
    } finally {
      await temp.delete(recursive: true);
    }
  });

  List<String> documentIds(KnowledgeLocalGraph graph) =>
      graph.documents.map((document) => document.id).toList();

  List<String> orderedIds(List<String> titles) =>
      titles.map((title) => ids[title]!).toList()..sort();

  Set<(String, String)> edgeIds(KnowledgeLocalGraph graph) =>
      graph.edges.map((edge) => (edge.from, edge.to)).toSet();

  Set<(String, String)> expectedEdges(List<(String, String)> titles) => {
    for (final (from, to) in titles) (ids[from]!, ids[to]!),
  };

  test(
    'default graph keeps only resolved first-hop edges and immutable lists',
    () {
      final graph = index.localGraph(ids['A']!);

      expect(documentIds(graph), [
        ids['A'],
        ...orderedIds(['B', 'C', 'P']),
      ]);
      expect(
        edgeIds(graph),
        expectedEdges([('A', 'B'), ('A', 'P'), ('C', 'A')]),
      );
      expect(graph.edges, hasLength(3));
      expect(index.documents.keys, isNot(contains(ids['Trashed'])));
      expect(index.unresolved.any((link) => link.from == ids['A']), isTrue);
      expect(() => graph.documents.clear(), throwsUnsupportedError);
      expect(() => graph.edges.clear(), throwsUnsupportedError);
    },
  );

  test(
    'independent direction switches admit links in their original direction',
    () {
      final outgoing = index.localGraph(ids['A']!, incoming: false);
      final incoming = index.localGraph(ids['A']!, outgoing: false);
      final neither = index.localGraph(
        ids['A']!,
        incoming: false,
        outgoing: false,
        interlinks: true,
      );

      expect(documentIds(outgoing), [
        ids['A'],
        ...orderedIds(['B', 'P']),
      ]);
      expect(edgeIds(outgoing), expectedEdges([('A', 'B'), ('A', 'P')]));
      expect(documentIds(incoming), [ids['A'], ids['C']]);
      expect(edgeIds(incoming), expectedEdges([('C', 'A')]));
      expect(documentIds(neither), [ids['A']]);
      expect(neither.edges, isEmpty);
    },
  );

  test(
    'a shared second-hop node retains both routes and admitted reverse links',
    () {
      final graph = index.localGraph(ids['A']!, depth: 2);
      final outgoing = index.localGraph(ids['A']!, depth: 2, incoming: false);

      expect(documentIds(graph), [
        ids['A'],
        ...orderedIds(['B', 'C', 'P']),
        ids['D'],
      ]);
      expect(
        edgeIds(graph),
        expectedEdges([
          ('A', 'B'),
          ('A', 'P'),
          ('C', 'A'),
          ('B', 'D'),
          ('C', 'D'),
          ('D', 'B'),
        ]),
      );
      expect(graph.edges, hasLength(6));
      expect(
        edgeIds(outgoing),
        expectedEdges([('A', 'B'), ('A', 'P'), ('B', 'D')]),
      );
    },
  );

  test('interlinks add visible-node edges without expanding the search', () {
    final traversal = index.localGraph(ids['A']!, depth: 2, incoming: false);
    final induced = index.localGraph(
      ids['A']!,
      depth: 2,
      incoming: false,
      interlinks: true,
    );

    expect(documentIds(induced), documentIds(traversal));
    expect(
      edgeIds(induced),
      expectedEdges([
        ('A', 'B'),
        ('A', 'P'),
        ('B', 'D'),
        ('D', 'B'),
        ('B', 'P'),
        ('P', 'B'),
      ]),
    );
    expect(induced.edges, hasLength(6));
  });

  test(
    'breadth-first projection terminates cycles and enforces the depth bound',
    () {
      final graph = index.localGraph(ids['A']!, depth: 5);

      expect(documentIds(graph), [
        ids['A'],
        ...orderedIds(['B', 'C', 'P']),
        for (final title in ['D', 'E', 'F', 'G']) ids[title],
      ]);
      expect(documentIds(graph), isNot(contains(ids['H'])));
      expect(() => index.localGraph(ids['A']!, depth: 0), throwsArgumentError);
      expect(() => index.localGraph(ids['A']!, depth: 6), throwsArgumentError);
    },
  );

  test(
    'missing centers return an empty graph and isolated centers stay visible',
    () {
      final missing = index.localGraph(ids['Trashed']!);
      final isolated = index.localGraph(ids['Isolated']!, interlinks: true);

      expect(missing.documents, isEmpty);
      expect(missing.edges, isEmpty);
      expect(documentIds(isolated), [ids['Isolated']]);
      expect(isolated.edges, isEmpty);
    },
  );
}
