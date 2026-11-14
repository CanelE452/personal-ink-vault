import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/native/ink_vault_native.dart';
import 'package:saber/data/vault/knowledge_index.dart';
import 'package:saber/data/vault/library_store.dart';
import 'package:saber/data/vault/workspace_store.dart';

void main() {
  late NoteRepository repository;
  late WorkspaceStore workspace;
  late LibraryStore library;
  late InkVaultNative native;

  setUp(() async {
    native = InkVaultNative.open(
      libraryPath:
          Platform.environment['INK_VAULT_NATIVE_LIBRARY'] ??
          p.absolute('build', 'native', 'windows', 'ink_vault_native.dll'),
    );
    final temp = await Directory.systemTemp.createTemp('ink-dataview-');
    repository = await NoteRepository.open(temp, createFormatVersion: 2);
    workspace = WorkspaceStore(repository, native: native);
    library = LibraryStore(repository);
    addTearDown(() async {
      await repository.close();
      await temp.delete(recursive: true);
    });
  });

  Future<VaultNote> note(String title, String markdown, {String? folderId}) =>
      workspace.createMarkdown(
        title,
        Uint8List.fromList(utf8.encode(markdown)),
        folderId: folderId,
      );

  test(
    'projects finite typed scalars and direct normalized YAML tags',
    () async {
      final input = await note('Research', '''
---
status: 진행
active: true
score: 2.5
numberText: "42"
explicitNull: null
details: { child: hidden }
choices: [first, second]
unbounded: .inf
tags: ["#Cafe\u0301", "Research/Method", "invalid tag"]
description: "mention #yamlonly"
---

본문 #Body/Topic
''');
      final index = await KnowledgeIndex.build(repository, native);
      final document = index.documents[input.id]!;
      final data = _projection(document);
      expect(data['eligible'], isTrue);
      expect(data['properties'], {
        'status': '진행',
        'active': true,
        'score': 2.5,
        'numberText': '42',
        'explicitNull': null,
        'description': 'mention #yamlonly',
      });
      expect(data['tags'], {'café', 'research/method'});
      expect(data['bodyTags'], {'body', 'body/topic'});
      expect(document.tags, contains('body/topic'));
      expect(index.tags['body/topic']!.single.id, input.id);
      expect(data['folder'], '');
      expect(data['path'], 'Research.md');
    },
  );

  test('recognizes scalar tags and CRLF without rewriting Markdown', () async {
    const source =
        '---\r\ntags: "#ReSearch"\r\nstage: false\r\n---\r\n#Read\r\n';
    final input = await note('Preserve', source);
    final index = await KnowledgeIndex.build(repository, native);
    final document = index.documents[input.id]!;
    final data = _projection(document);
    expect(data['eligible'], isTrue);
    expect(data['tags'], {'research'});
    expect((data['properties'] as Map)['stage'], isFalse);
    expect(data['bodyTags'], {'read'});
    expect(document.markdown, source);
  });

  test(
    'notes without frontmatter retain their native body tag projection',
    () async {
      final input = await note('Plain', 'Original #Research/Methods');
      final index = await KnowledgeIndex.build(repository, native);
      final document = index.documents[input.id]!;
      final data = _projection(document);
      expect(data['eligible'], isTrue);
      expect(data['properties'], isEmpty);
      expect(data['tags'], isEmpty);
      expect(data['bodyTags'], {'research', 'research/methods'});
      expect(data['bodyTags'], document.tags);
    },
  );

  test(
    'malformed duplicate and oversized YAML fail closed without losing notes',
    () async {
      final oversized = 'x' * 65536;
      final sources = [
        '---\nstatus: [broken\ntags: "#leak"\n---\n',
        '---\nstatus: one\nstatus: two\ntags: "#leak"\n---\n',
        '---\ntags: "#leak"\n',
        '---\nstatus: "$oversized"\ntags: "#leak"\n---\n',
      ];
      final inputs = [
        for (var i = 0; i < sources.length; i++)
          await note('Malformed $i', sources[i]),
      ];
      final index = await KnowledgeIndex.build(repository, native);
      for (var i = 0; i < inputs.length; i++) {
        final document = index.documents[inputs[i].id]!;
        final data = _projection(document);
        expect(data['eligible'], isFalse, reason: inputs[i].title);
        expect(data['properties'], isEmpty);
        expect(data['tags'], isEmpty);
        expect(data['bodyTags'], isEmpty);
        expect(document.markdown, sources[i]);
      }
    },
  );

  test(
    'conflicting Markdown and metadata heads expose no Dataview values',
    () async {
      final bodyConflict = await note(
        'Body conflict',
        '---\nstatus: base\n---\n',
      );
      final session = await workspace.open(bodyConflict);
      await repository.commit(
        entityId: bodyConflict.markdownEntityId,
        kind: EntityKind.markdown,
        ownerNoteId: bodyConflict.id,
        files: {
          'summary.md': Uint8List.fromList(
            utf8.encode('---\nstatus: remote\ntags: remote\n---\n'),
          ),
        },
        parentRevisionIds: session.markdownParents,
      );
      await session.saveMarkdown('---\nstatus: local\ntags: local\n---\n');

      final metadataConflict = await note(
        'Metadata conflict',
        '---\nstatus: one\n---\n',
      );
      final files = await repository.readFiles(metadataConflict.revision);
      for (var i = 0; i < 2; i++) {
        await repository.commit(
          entityId: metadataConflict.id,
          kind: EntityKind.metadata,
          files: files,
          parentRevisionIds: [metadataConflict.revision.revisionId],
        );
      }
      final index = await KnowledgeIndex.build(repository, native);
      expect(index.documents[bodyConflict.id]!.markdownConflict, isTrue);
      expect(index.documents[metadataConflict.id]!.metadataConflict, isTrue);
      for (final input in [bodyConflict, metadataConflict]) {
        final data = _projection(index.documents[input.id]!);
        expect(data['eligible'], isFalse);
        expect(data['properties'], isEmpty);
        expect(data['tags'], isEmpty);
        expect(data['path'], isNull);
      }
    },
  );

  test(
    'same-label ancestor conflicts cannot provide folder or path authority',
    () async {
      final parent = await library.createFolder('University');
      final child = await library.createFolder('Research', parentId: parent.id);
      final input = await note(
        'Report',
        '---\nstatus: ready\n---\n',
        folderId: child.id,
      );
      var index = await KnowledgeIndex.build(repository, native);
      var data = _projection(index.documents[input.id]!);
      expect(data['folder'], 'University/Research');
      expect(data['path'], 'University/Research/Report.md');

      final files = await repository.readFiles(parent.revision);
      for (var i = 0; i < 2; i++) {
        await repository.commit(
          entityId: parent.id,
          kind: EntityKind.folder,
          files: files,
          parentRevisionIds: [parent.revision.revisionId],
        );
      }
      expect(await repository.heads(parent.id), hasLength(2));
      index = await KnowledgeIndex.build(repository, native);
      data = _projection(index.documents[input.id]!);
      expect(data['eligible'], isTrue);
      expect(data['properties'], {'status': 'ready'});
      expect(data['folder'], isNull);
      expect(data['path'], isNull);
    },
  );

  test('a non-Markdown note summary is not a Dataview document', () async {
    final input = await workspace.create(
      'Ink summary',
      documentKind: VaultDocumentKind.handwriting,
    );
    await (await workspace.open(input))
        .saveMarkdown('---\nstatus: ready\ntags: research\n---\n');
    final index = await KnowledgeIndex.build(repository, native);
    final data = _projection(index.documents[input.id]!);
    expect(data['eligible'], isFalse);
    expect(data['properties'], isEmpty);
    expect(data['tags'], isEmpty);
  });

  test(
    'rebuild uses only the current Markdown head and renamed note path',
    () async {
      final input = await note('Before', '---\nstatus: ready\n---\n');
      var index = await KnowledgeIndex.build(repository, native);
      expect(_projection(index.documents[input.id]!)['properties'], {
        'status': 'ready',
      });
      await (await workspace.open(input))
          .saveMarkdown('---\nstatus: done\n---\n');
      await workspace.rename(input, 'After');
      index = await KnowledgeIndex.build(repository, native);
      final data = _projection(index.documents[input.id]!);
      expect(data['properties'], {'status': 'done'});
      expect(data['path'], 'After.md');
    },
  );
}

Map<String, Object?> _projection(KnowledgeDocument document) => {
  'eligible': document.dataviewEligible,
  'properties': document.dataviewProperties,
  'tags': document.dataviewTags,
  'bodyTags': document.dataviewBodyTags,
  'folder': document.dataviewFolder,
  'path': document.dataviewPath,
};
