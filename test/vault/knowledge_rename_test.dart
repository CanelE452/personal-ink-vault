import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/native/ink_vault_native.dart';
import 'package:saber/data/vault/block_page_document.dart';
import 'package:saber/data/vault/knowledge_index.dart';
import 'package:saber/data/vault/library_store.dart';
import 'package:saber/data/vault/workspace_database.dart';
import 'package:saber/data/vault/workspace_store.dart';

void main() {
  late Directory temp;
  late NoteRepository repository;
  late WorkspaceStore store;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('knowledge-rename-');
    repository = await NoteRepository.open(temp, createFormatVersion: 2);
    store = WorkspaceStore(repository);
  });
  tearDown(() async {
    await repository.close();
    final resolved = await temp.resolveSymbolicLinks();
    final parent = await Directory.systemTemp.resolveSymbolicLinks();
    expect(
      resolved,
      startsWith('$parent${Platform.pathSeparator}knowledge-rename-'),
    );
    await Directory(resolved).delete(recursive: true);
  });

  test('rename without a common engine refuses active inbound links before changing the title', () async {
    final target = await store.create('Old');
    final source = await store.create('Source');
    final session = await store.open(source);
    const text = '😀 [[Old#Section|Keep label]] [shown](Old.md "Keep title")';
    await session.saveMarkdown(text);
    final before = (await repository.revisions())
        .map((r) => r.revisionId)
        .toSet();

    await expectLater(store.rename(target, 'New'), throwsStateError);

    expect(
      (await store.list()).singleWhere((note) => note.id == target.id).title,
      'Old',
    );
    expect(await session.readMarkdown(), text);
    expect(
      (await repository.revisions()).map((r) => r.revisionId).toSet(),
      before,
    );
  });

  test('rename refuses an unresolved target metadata branch instead of creating another branch', () async {
    final target = await store.create('Old');
    final files = await repository.readFiles(target.revision);
    await repository.commit(
      entityId: target.id,
      kind: EntityKind.metadata,
      files: {
        ...files,
        'note.json': Uint8List.fromList(
          utf8.encode(jsonEncode({...target.json, 'title': 'Remote'})),
        ),
      },
      parentRevisionIds: [],
    );
    final before = (await repository.heads(target.id))
        .map((r) => r.revisionId)
        .toSet();

    await expectLater(store.rename(target, 'New'), throwsStateError);

    expect(
      (await repository.heads(target.id)).map((r) => r.revisionId).toSet(),
      before,
    );
    expect((await store.list()).map((note) => note.title).toSet(), {
      'Old',
      'Remote',
    });
  });

  test(
    'rename refuses an opened metadata revision superseded by a remote edit',
    () async {
      final target = await store.create('Old');
      final files = await repository.readFiles(target.revision);
      final remote = await repository.commit(
        entityId: target.id,
        kind: EntityKind.metadata,
        files: {
          ...files,
          'note.json': Uint8List.fromList(
            utf8.encode(jsonEncode({...target.json, 'title': 'Remote'})),
          ),
        },
        parentRevisionIds: [target.revision.revisionId],
      );

      await expectLater(store.rename(target, 'New'), throwsStateError);

      expect(
        (await repository.heads(target.id)).single.revisionId,
        remote.revisionId,
      );
      expect((await store.list()).single.title, 'Remote');
    },
  );

  test('rename refuses an old note after it has entered the trash', () async {
    final target = await store.create('Old');
    await store.setDeleted(target, true);
    final deleted = (await repository.heads(target.id)).single;

    await expectLater(store.rename(target, 'New'), throwsStateError);

    expect(
      (await repository.heads(target.id)).single.revisionId,
      deleted.revisionId,
    );
    expect(await store.list(), isEmpty);
  });

  test('a freshly read deleted head can change title without normalizing active source references', () async {
    final target = await store.create('Old'),
        source = await store.create('Source');
    await (await store.open(source)).saveMarkdown('[[Old]]');
    await repository.commit(
      entityId: target.id,
      kind: EntityKind.metadata,
      files: await repository.readFiles(target.revision),
      parentRevisionIds: [target.revision.revisionId],
      deleted: true,
      baseRefs: {
        target.markdownEntityId: [
          (await repository.heads(target.markdownEntityId)).single.revisionId,
        ],
      },
    );
    final current = (await store.list(includeDeleted: true))
        .singleWhere((note) => note.id == target.id);
    final sourceBefore = (await repository.heads(source.markdownEntityId))
        .single;

    await store.rename(current, 'In trash');

    final head = (await repository.heads(target.id)).single;
    expect(head.deleted, isTrue);
    expect(head.baseRefs, current.revision.baseRefs);
    expect(head.parentRevisionIds, [current.revision.revisionId]);
    expect(
      (await store.list(includeDeleted: true))
          .singleWhere((note) => note.id == target.id)
          .title,
      'In trash',
    );
    expect(
      (await repository.heads(source.markdownEntityId)).single.revisionId,
      sourceBefore.revisionId,
    );
    expect(
      (await repository.readFiles(sourceBefore))['summary.md'],
      _bytes('[[Old]]'),
    );
  });

  test(
    'rename without a common engine refuses real structured page references',
    () async {
      final target = await store.create('Old');
      final page = await store.create(
        'Page',
        documentKind: VaultDocumentKind.page,
      );
      final document = const BlockPageDocument.empty().copyWith(
        blocks: [BlockPageBlock.create(type: 'paragraph', text: '[[Old]]')],
      );
      final json = {
        ...document.toJson(),
        'future': {
          'keep': [1, 'Original'],
        },
      };
      final pageSession = await store.open(page);
      final original = Uint8List.fromList(utf8.encode(jsonEncode(json)));
      await pageSession.saveInk({
        'page.json': original,
        'future.bin': Uint8List.fromList([1, 2, 3]),
      });
      final before = (await repository.heads(page.inkEntityId)).single;

      await expectLater(store.rename(target, 'New'), throwsStateError);

      expect(
        (await repository.heads(page.inkEntityId)).single.revisionId,
        before.revisionId,
      );
      expect((await repository.readFiles(before))['page.json'], original);
      expect(
        (await store.list()).singleWhere((note) => note.id == target.id).title,
        'Old',
      );
    },
  );

  test(
    'linkless legacy rename remains available without a common engine',
    () async {
      final target = await store.create('Old');
      final session = await store.open(target);
      await session.saveMarkdown('A plain paragraph with no internal links.');

      await store.rename(target, 'New');

      expect((await store.list()).single.id, target.id);
      expect((await store.list()).single.title, 'New');
      expect(
        await session.readMarkdown(),
        'A plain paragraph with no internal links.',
      );
    },
  );

  test('real engine normalizes inbound references before repeated renames and old title reuse', () async {
    final native = _native();
    final nativeStore = WorkspaceStore(repository, native: native);
    final folder = await LibraryStore(repository).createFolder('Course');
    final target = await nativeStore.create('Old', folderId: folder.id);
    final source = await nativeStore.create('Source', folderId: folder.id);
    const text =
        '😀 [[Old#Section|Keep label]] [shown](Old.md#%5Eblock "Keep title")\n'
        '`[[Old]]` <!-- [[Old]] --> [external](https://example.com/Old.md)';
    await (await nativeStore.open(source)).saveMarkdown('\uFEFF$text');
    final sourceBefore = (await repository.heads(source.markdownEntityId))
        .single;
    await nativeStore.rename(target, 'New');
    final first = (await repository.heads(source.markdownEntityId)).single;
    final rewritten = utf8.decode(
      (await repository.readFiles(first))['summary.md']!,
    );
    expect((await repository.readFiles(first))['summary.md']!.take(3), [
      239,
      187,
      191,
    ]);
    expect(
      rewritten,
      '😀 [[${target.id}#Section|Keep label]] '
      '[shown](inkvault://note/${target.id}?view=markdown#%5Eblock "Keep title")\n'
      '`[[Old]]` <!-- [[Old]] --> [external](https://example.com/Old.md)',
    );
    expect(first.parentRevisionIds, [sourceBefore.revisionId]);
    expect(
      utf8.decode((await repository.readFiles(sourceBefore))['summary.md']!),
      text,
    );
    final renamed = (await nativeStore.list()).singleWhere(
      (n) => n.id == target.id,
    );
    await nativeStore.rename(renamed, 'Later');
    await nativeStore.create('Old', folderId: folder.id);
    final index = await KnowledgeIndex.build(repository, native);
    expect(index.backlinks(target.id).map((d) => d.id), [source.id]);
    expect(
      (await repository.heads(source.markdownEntityId)).single.revisionId,
      first.revisionId,
    );
  });

  test(
    'rename pins nested YAML links without changing other Markdown bytes',
    () async {
      final native = _native();
      final nativeStore = WorkspaceStore(repository, native: native);
      final target = await nativeStore.createMarkdown('Old', _bytes(''));
      const original =
          '\uFEFF---\r\n'
          'reading:\r\n'
          '  primary:\r\n'
          '    - "[[Old#Section|Keep alias]]" # keep [[Old]]\r\n'
          '    - \'[shown](Old.md#%5Eblock "Keep title")\'\r\n'
          '    - \'prefix [[Old]]\'\r\n'
          '# sample: \'[[Old]]\'\r\n'
          '---\r\n\r\n'
          '`[[Old]]` <!-- [[Old]] -->\r\n';
      final source = await nativeStore.createMarkdown(
        'Source',
        _bytes(original),
      );
      final before = (await repository.heads(source.markdownEntityId)).single;

      await nativeStore.rename(target, 'New');

      final head = (await repository.heads(source.markdownEntityId)).single;
      final expected = original
          .replaceFirst(
            '[[Old#Section|Keep alias]]',
            '[[${target.id}#Section|Keep alias]]',
          )
          .replaceFirst(
            'Old.md#%5Eblock',
            'inkvault://note/${target.id}?view=markdown#%5Eblock',
          );
      expect(
        (await repository.readFiles(head))['summary.md'],
        _bytes(expected),
      );
      expect(head.parentRevisionIds, [before.revisionId]);
      expect(
        (await repository.readFiles(before))['summary.md'],
        _bytes(original),
      );

      final replacement = await nativeStore.createMarkdown('Old', _bytes(''));
      final index = await KnowledgeIndex.build(repository, native);
      expect(index.backlinks(target.id).map((note) => note.id), [source.id]);
      expect(index.backlinks(replacement.id), isEmpty);
    },
  );

  test('raw page string edits preserve unknown numbers whitespace code and attachment bytes', () async {
    final nativeStore = WorkspaceStore(repository, native: _native());
    final target = await nativeStore.create('Old');
    final page = await nativeStore.create(
      'Page',
      documentKind: VaultDocumentKind.page,
    );
    final paragraph = newId(), code = newId();
    final original =
        '\uFEFF{ "version": 1, "future": 18446744073709551617, "blocks": ['
        '{"id":"$paragraph","type":"paragraph","text":"😀 [[Old|label]]","future":"[[Old]]"},'
        '{"id":"$code","type":"code","text":"[[Old]]"}], "spacing": 1.00e+03 }';
    await (await nativeStore.open(page)).saveInk({
      'page.json': _bytes(original),
      'future.bin': Uint8List.fromList([0, 255, 1]),
    });
    final previous = (await repository.heads(page.inkEntityId)).single;
    await nativeStore.rename(target, 'New');
    final head = (await repository.heads(page.inkEntityId)).single;
    final files = await repository.readFiles(head);
    expect(
      files['page.json'],
      _bytes(
        original.replaceFirst('😀 [[Old|label]]', '😀 [[${target.id}|label]]'),
      ),
    );
    expect(files['future.bin'], [0, 255, 1]);
    expect(head.parentRevisionIds, [previous.revisionId]);
    expect(
      (await repository.readFiles(previous))['page.json'],
      _bytes(original),
    );
  });

  test('real database title text and row body refs are rewritten without changing archived rows', () async {
    final nativeStore = WorkspaceStore(repository, native: _native());
    final target = await nativeStore.create('Old');
    final note = await nativeStore.create(
      'Database',
      documentKind: VaultDocumentKind.database,
    );
    var db = WorkspaceDatabase.empty();
    final titleId = db.properties.single.id;
    db = db.addRow(
      DatabaseRow.create(
        values: {titleId: '[[Old|row]]'},
        body: const BlockPageDocument.empty()
            .copyWith(blocks: [BlockPageBlock.create(text: '[body](Old.md)')])
            .toJson(),
      ),
    );
    db = db.addRow(
      DatabaseRow.create(values: {titleId: '[[Old|archived]]'})
          .copyWith(archived: true),
    );
    final raw = jsonEncode(db.toJson());
    await (await nativeStore.open(note))
        .saveInk({'database.json': _bytes(raw)});
    await nativeStore.rename(target, 'New');
    final files = await repository.readFiles(
      (await repository.heads(note.inkEntityId)).single,
    );
    expect(
      utf8.decode(files['database.json']!),
      raw
          .replaceFirst('[[Old|row]]', '[[${target.id}|row]]')
          .replaceFirst(
            '[body](Old.md)',
            '[body](inkvault://note/${target.id}?view=markdown)',
          ),
    );
  });

  test('an unresolved canvas filename cannot choose between vault root and source relative targets', () async {
    final nativeStore = WorkspaceStore(repository, native: _native());
    final rootTarget = await nativeStore.create('Old');
    final course = await LibraryStore(repository).createFolder('Course');
    final relativeTarget = await nativeStore.create('Old', folderId: course.id);
    final canvas = await nativeStore.create(
      'Canvas',
      folderId: course.id,
      documentKind: VaultDocumentKind.canvas,
    );
    final raw = jsonEncode({
      'nodes': [
        {
          'id': newId(),
          'type': 'file',
          'file': 'Old.md',
          'x': 0,
          'y': 0,
          'width': 280,
          'height': 180,
        },
        {
          'id': newId(),
          'type': 'file',
          'file': rootTarget.id,
          'x': 300,
          'y': 0,
          'width': 280,
          'height': 180,
        },
      ],
      'edges': <Object>[],
      'future': {'keep': 'Original'},
    });
    await (await nativeStore.open(canvas))
        .saveInk({'board.canvas': _bytes(raw)});
    final before = (await repository.revisions())
        .map((r) => r.revisionId)
        .toSet();
    final canvasBefore = (await repository.heads(canvas.inkEntityId)).single;

    await expectLater(
      nativeStore.rename(relativeTarget, 'New'),
      throwsStateError,
    );

    expect(
      (await repository.revisions()).map((r) => r.revisionId).toSet(),
      before,
    );
    expect(
      (await repository.heads(canvas.inkEntityId)).single.revisionId,
      canvasBefore.revisionId,
    );
    expect(
      (await repository.readFiles(canvasBefore))['board.canvas'],
      _bytes(raw),
    );
    expect(
      (await nativeStore.list())
          .singleWhere((n) => n.id == relativeTarget.id)
          .title,
      'Old',
    );
  });

  test(
    'rename pins Obsidian note embeds and preserves selectors and aliases',
    () async {
      final native = _native();
      final nativeStore = WorkspaceStore(repository, native: native);
      final target = await nativeStore.createMarkdown(
        'Old',
        _bytes('# Section\n\nSelected body ^block'),
      );
      await nativeStore.createMarkdown('Other', _bytes('Unrelated'));
      const untouched =
          '![[Other]] `![[Old#Section]]`\r\n'
          '```md\r\n![[Old#^block]]\r\n```\r\n';
      const original =
          '😀 ![[Old#Section|Keep label]] ![[Old#^block]] ![[Old]]\r\n'
          '$untouched';
      final source = await nativeStore.createMarkdown(
        'Source',
        _bytes(original),
      );
      final before = (await repository.heads(source.markdownEntityId)).single;
      final targetBefore = (await repository.heads(target.markdownEntityId))
          .single;

      await nativeStore.rename(target, 'New');

      final after = (await repository.heads(source.markdownEntityId)).single;
      expect(after.parentRevisionIds, [before.revisionId]);
      expect(
        (await repository.readFiles(before))['summary.md'],
        _bytes(original),
      );
      expect(
        (await repository.readFiles(after))['summary.md'],
        _bytes(
          '😀 ![[${target.id}#Section|Keep label]] '
          '![[${target.id}#^block|Old#^block]] ![[${target.id}|Old]]\r\n'
          '$untouched',
        ),
      );
      expect(
        (await repository.heads(target.markdownEntityId)).single.revisionId,
        targetBefore.revisionId,
      );

      final renamed = (await nativeStore.list()).singleWhere(
        (note) => note.id == target.id,
      );
      expect(renamed.title, 'New');
      await nativeStore.rename(renamed, 'Later');
      await nativeStore.createMarkdown('Old', _bytes('Same-name decoy'));
      expect(
        (await repository.heads(source.markdownEntityId)).single.revisionId,
        after.revisionId,
      );
      final index = await KnowledgeIndex.build(repository, native);
      for (final anchor in ['Section', '^block']) {
        final embed = index.resolveWikiLink(
          '${target.id}#$anchor',
          fromNoteId: source.id,
        );
        expect((embed?.noteId, embed?.anchor), (target.id, anchor));
      }
    },
  );

  test(
    'move pins inbound and outbound Obsidian note embeds before paths can retarget',
    () async {
      final native = _native();
      final nativeStore = WorkspaceStore(repository, native: native);
      final library = LibraryStore(repository);
      final course = await library.createFolder('Course');
      final other = await library.createFolder('Other');
      final target = await nativeStore.createMarkdown(
        'Target',
        _bytes('# Section\n\nOriginal target'),
        folderId: course.id,
      );
      await nativeStore.createMarkdown(
        'Target',
        _bytes('# Section\n\nDecoy target'),
        folderId: other.id,
      );
      final moved = await nativeStore.createMarkdown(
        'Moved',
        _bytes('![[Target#Section|Keep label]]\n\nMoved body ^point'),
        folderId: course.id,
      );
      final inbound = await nativeStore.createMarkdown(
        'Inbound',
        _bytes('![[Course/Moved#^point]]'),
      );
      final index = await KnowledgeIndex.build(repository, native);
      expect(
        index.resolveWikiLink('Target#Section', fromNoteId: moved.id)?.noteId,
        target.id,
      );

      await nativeStore.moveNote(moved, other.id);

      final current = (await nativeStore.list()).singleWhere(
        (note) => note.id == moved.id,
      );
      expect(current.folderId, other.id);
      expect(
        await (await nativeStore.open(current)).readMarkdown(),
        '![[${target.id}#Section|Keep label]]\n\nMoved body ^point',
      );
      expect(
        await (await nativeStore.open(inbound)).readMarkdown(),
        '![[${moved.id}#^point|Course/Moved#^point]]',
      );
    },
  );

  test(
    'an affected Obsidian image embed still prevents all writes during a move',
    () async {
      final native = _native();
      final nativeStore = WorkspaceStore(repository, native: native);
      final library = LibraryStore(repository);
      final course = await library.createFolder('Course');
      final other = await library.createFolder('Other');
      final target = await nativeStore.createWithSource(
        'Pixel.png',
        fileName: 'Pixel.png',
        bytes: base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ'
          'AAAACklEQVQImWNgAAAAAgAB9HFkpgAAAABJRU5ErkJggg==',
        ),
        folderId: course.id,
        documentKind: VaultDocumentKind.image,
        fromObsidian: true,
      );
      const original = '![[Course/Pixel.png]]';
      final source = await nativeStore.createMarkdown('Source', _bytes(original));
      final index = await KnowledgeIndex.build(repository, native);
      expect(
        index
            .resolveWikiLink('Course/Pixel.png', fromNoteId: source.id)
            ?.attachmentName,
        'Pixel.png',
      );
      final before = (await repository.revisions())
          .map((r) => r.revisionId)
          .toSet();

      await expectLater(nativeStore.moveNote(target, other.id), throwsStateError);

      expect(
        (await repository.revisions()).map((r) => r.revisionId).toSet(),
        before,
      );
      expect(
        (await nativeStore.list()).singleWhere((note) => note.id == target.id).folderId,
        course.id,
      );
      expect(await (await nativeStore.open(source)).readMarkdown(), original);
    },
  );

  test(
    'rename keeps explicit Canvas bindings and inert paths byte-identical',
    () async {
      final nativeStore = WorkspaceStore(repository, native: _native());
      final target = await nativeStore.create('Before');
      final board = await nativeStore.create(
        'Board',
        documentKind: VaultDocumentKind.canvas,
      );
      Map<String, Object?> fileCard(String file, String? id) => {
        'id': newId(),
        'type': 'file',
        'file': file,
        'inkVaultNoteId': id,
        'subpath': '#heading',
        'x': 0,
        'y': 0,
        'width': 280,
        'height': 180,
      };
      final raw = _bytes(
        jsonEncode({
          'nodes': [
            fileCard('Before.md', target.id),
            fileCard('Missing.md', null),
          ],
        }),
      );
      await (await nativeStore.open(board)).saveInk({'board.canvas': raw});
      final before = (await repository.heads(board.inkEntityId)).single;
      await nativeStore.rename(target, 'After');
      final after = (await repository.heads(board.inkEntityId)).single;
      expect(after.revisionId, before.revisionId);
      expect((await repository.readFiles(after))['board.canvas'], raw);
    },
  );

  test(
    'an inbound body branch prevents normalization and metadata publication',
    () async {
      final nativeStore = WorkspaceStore(repository, native: _native());
      final target = await nativeStore.create('Old');
      final source = await nativeStore.create('Source');
      final first = await nativeStore.open(source),
          second = await nativeStore.open(source);
      await first.saveMarkdown('[[Old]]');
      await second.saveMarkdown('Another branch');
      final before = (await repository.revisions())
          .map((r) => r.revisionId)
          .toSet();
      await expectLater(nativeStore.rename(target, 'New'), throwsStateError);
      expect(
        (await repository.revisions()).map((r) => r.revisionId).toSet(),
        before,
      );
    },
  );

  test('a lost normalization response retries the same token through a new store instance', () async {
    final native = _native();
    final target = await store.create('Old'),
        source = await store.create('Source');
    await (await store.open(source)).saveMarkdown('[[Old]]');
    final guarded = _RenameRepository(repository)
      ..loseResponseFor = EntityKind.markdown;
    await expectLater(
      WorkspaceStore(guarded, native: native).rename(target, 'New'),
      throwsStateError,
    );
    expect(
      (await store.list()).singleWhere((n) => n.id == target.id).title,
      'Old',
    );
    final published = (await repository.heads(source.markdownEntityId)).single;
    await WorkspaceStore(guarded, native: native).rename(target, 'New');
    expect(
      guarded.attempts
          .where((r) => r.kind == EntityKind.markdown)
          .map((r) => r.revisionId)
          .toSet(),
      {published.revisionId},
    );
    expect(
      (await repository.heads(source.markdownEntityId)).single.revisionId,
      published.revisionId,
    );
    expect(
      (await store.list()).singleWhere((n) => n.id == target.id).title,
      'New',
    );
  });

  test('a lost title response retries its exact token with the already refreshed document', () async {
    final target = await store.create('Old');
    final guarded = _RenameRepository(repository)
      ..loseResponseFor = EntityKind.metadata;
    await expectLater(
      WorkspaceStore(guarded).rename(target, 'New'),
      throwsStateError,
    );
    final refreshed = (await store.list()).single;
    expect(refreshed.title, 'New');
    await WorkspaceStore(guarded).rename(refreshed, 'New');
    expect(guarded.attempts.map((r) => r.revisionId).toSet(), {
      refreshed.revision.revisionId,
    });
    expect(
      (await repository.heads(target.id)).single.revisionId,
      refreshed.revision.revisionId,
    );
  });

  test('permission withdrawal after normalization stops metadata then uses the current retry callback', () async {
    final native = _native();
    final target = await store.create('Old'),
        source = await store.create('Source');
    await (await store.open(source)).saveMarkdown('[[Old]]');
    var allowed = true;
    final guarded = _RenameRepository(repository)
      ..afterPublish = (r) {
        if (r.kind == EntityKind.markdown) allowed = false;
      };
    await expectLater(
      WorkspaceStore(guarded, native: native).rename(
        target,
        'New',
        requireWrite: () {
          if (!allowed) throw StateError('Read only');
        },
      ),
      throwsStateError,
    );
    expect(
      (await store.list()).singleWhere((n) => n.id == target.id).title,
      'Old',
    );
    guarded.afterPublish = null;
    await WorkspaceStore(
      guarded,
      native: native,
    ).rename(target, 'New', requireWrite: () {});
    expect(
      (await store.list()).singleWhere((n) => n.id == target.id).title,
      'New',
    );
  });

  test(
    'a newly created inbound source defeats the final whole workspace guard',
    () async {
      final native = _native();
      final target = await store.create('Old'),
          source = await store.create('Source');
      await (await store.open(source)).saveMarkdown('[[Old]]');
      var injected = false;
      final guarded = _RenameRepository(repository)
        ..beforeConditional = (prepared) async {
          if (prepared.record.kind == EntityKind.metadata && !injected) {
            injected = true;
            final newcomer = await store.create('New source');
            await (await store.open(newcomer)).saveMarkdown('[[Old]]');
          }
        };
      await expectLater(
        WorkspaceStore(guarded, native: native).rename(target, 'New'),
        throwsStateError,
      );
      expect(
        (await store.list()).singleWhere((n) => n.id == target.id).title,
        'Old',
      );
      expect(
        utf8.decode(
          (await repository.readFiles(
            (await repository.heads(source.markdownEntityId)).single,
          ))['summary.md']!,
        ),
        '[[${target.id}|Old]]',
      );
      guarded.beforeConditional = null;
      await WorkspaceStore(guarded, native: native).rename(target, 'New');
      final newcomer = (await store.list()).singleWhere(
        (n) => n.title == 'New source',
      );
      expect(
        utf8.decode(
          (await repository.readFiles(
            (await repository.heads(newcomer.markdownEntityId)).single,
          ))['summary.md']!,
        ),
        '[[${target.id}|Old]]',
      );
    },
  );

  test('metadata string editing retains unknown numeric tokens extra files and base references', () async {
    final target = await store.create('Old');
    final bases = {
      target.markdownEntityId: [
        (await repository.heads(target.markdownEntityId)).single.revisionId,
      ],
    };
    final original =
        '\uFEFF{ "title" : "Old", "inkEntityId":"${target.inkEntityId}",'
        ' "markdownEntityId":"${target.markdownEntityId}", "future":18446744073709551617, "decimal":1.00e+03 }';
    final seeded = await repository.commit(
      entityId: target.id,
      kind: EntityKind.metadata,
      files: {
        'note.json': _bytes(original),
        'future.bin': Uint8List.fromList([1, 255]),
      },
      parentRevisionIds: [target.revision.revisionId],
      baseRefs: bases,
    );
    final opened = (await store.list()).single;
    await store.rename(opened, 'New');
    final head = (await repository.heads(target.id)).single;
    expect(head.parentRevisionIds, [seeded.revisionId]);
    expect(head.baseRefs, bases);
    final files = await repository.readFiles(head);
    expect(files['note.json'], _bytes(original.replaceFirst('"Old"', '"New"')));
    expect(files['future.bin'], [1, 255]);
  });

  test('a linkless rename is not blocked by an unrelated title without a safe logical path', () async {
    final target = await store.create('Old');
    await store.create('Unrelated/title');
    await store.rename(target, 'New');
    expect(
      (await store.list()).singleWhere((n) => n.id == target.id).title,
      'New',
    );
  });

  test('malformed native UTF16 ranges cannot split a scalar or publish any revision', () async {
    final target = await store.create('Old'),
        source = await store.create('Source');
    await (await store.open(source)).saveMarkdown('😀 [[Old]]');
    final before = (await repository.revisions())
        .map((r) => r.revisionId)
        .toSet();
    final invalid = WorkspaceStore(
      repository,
      knowledgeInvoke: (request) => {
        'unsupported': <Object>[],
        'replacements': [
          {
            'start': 1,
            'end': 2,
            'original': '😀'.substring(1),
            'replacement': 'x',
          },
        ],
      },
    );
    await expectLater(invalid.rename(target, 'New'), throwsFormatException);
    expect(
      (await repository.revisions()).map((r) => r.revisionId).toSet(),
      before,
    );
  });

  test(
    'the display label of metadata branches is never a synthetic lookup title',
    () async {
      final native = _native();
      final target = await store.create('Old'),
          source = await store.create('Source');
      final files = await repository.readFiles(target.revision);
      await repository.commit(
        entityId: target.id,
        kind: EntityKind.metadata,
        files: {
          ...files,
          'note.json': _bytes(jsonEncode({...target.json, 'title': 'Remote'})),
        },
        parentRevisionIds: [],
      );
      await (await store.open(source))
          .saveMarkdown('[[Old]] [[Remote]] [[Old / Remote]]');
      final index = await KnowledgeIndex.build(repository, native);
      expect(index.documents[target.id]!.title, 'Old / Remote');
      expect(index.documents[target.id]!.metadataConflict, isTrue);
      expect(
        index.documents[source.id]!.links.where(
          (link) => link.targetId == target.id,
        ),
        hasLength(2),
      );
      expect(index.unresolved.map((link) => link.target), ['Old / Remote']);
      expect(
        index.resolveWikiLink('inkwiki:Old', fromNoteId: source.id)!.noteId,
        target.id,
      );
      expect(
        index.resolveWikiLink(
          'inkwiki:Old%20%2F%20Remote',
          fromNoteId: source.id,
        ),
        isNull,
      );
    },
  );

  test('wiki and actual Markdown clicks keep their different source relative lookup rules', () async {
    final native = _native();
    final course = await LibraryStore(repository).createFolder('Course');
    final other = await LibraryStore(repository).createFolder('Other');
    final target = await store.create('100% #노트', folderId: other.id);
    final remote = await store.create('Remote wiki name', folderId: other.id);
    final source = await store.create('Source', folderId: course.id);
    final index = await KnowledgeIndex.build(repository, native);
    expect(
      index.resolveWikiLink('Remote wiki name', fromNoteId: source.id)?.noteId,
      remote.id,
    );
    final wiki = Uri(
      scheme: 'inkwiki',
      path: '100% #노트',
      fragment: '정리#50%',
    ).toString();
    expect(
      index.resolveWikiLink(wiki, fromNoteId: source.id)!.noteId,
      target.id,
    );
    expect(
      index.resolveWikiLink(wiki, fromNoteId: source.id)!.anchor,
      '정리#50%',
    );
    expect(
      index.resolveMarkdownLink(
        '100%25%20%23%EB%85%B8%ED%8A%B8.md',
        fromNoteId: source.id,
      ),
      isNull,
    );
    final resolved = index.resolveMarkdownLink(
      '../Other/100%25%20%23%EB%85%B8%ED%8A%B8.md#%EC%A0%95%EB%A6%AC%2350%25',
      fromNoteId: source.id,
    )!;
    expect(resolved.noteId, target.id);
    expect(resolved.anchor, '정리#50%');
  });
}

Uint8List _bytes(String value) => Uint8List.fromList(utf8.encode(value));

InkVaultNative _native() => InkVaultNative.open(
  libraryPath:
      Platform.environment['INK_VAULT_NATIVE_LIBRARY'] ??
      p.absolute('build', 'native', 'windows', 'ink_vault_native.dll'),
);

class _RenameRepository implements NoteRepository {
  new(this.inner);
  final NoteRepository inner;
  EntityKind? loseResponseFor;
  Future<void> Function(PreparedCommit)? beforeConditional;
  void Function(RevisionRecord)? afterPublish;
  final attempts = <RevisionRecord>[];
  @override
  Directory get root => inner.root;
  @override
  String get vaultId => inner.vaultId;
  @override
  String get deviceId => inner.deviceId;
  @override
  int get formatVersion => inner.formatVersion;
  @override
  int get pendingRevisionCount => inner.pendingRevisionCount;
  @override
  List<String> get integrityIssues => inner.integrityIssues;
  @override
  Future<List<RevisionRecord>> revisions() => inner.revisions();
  @override
  Future<List<RevisionRecord>> heads(String id) => inner.heads(id);
  @override
  Future<Map<String, Uint8List>> readFiles(RevisionRecord revision) =>
      inner.readFiles(revision);
  @override
  PreparedCommit prepareCommit({
    required String entityId,
    required EntityKind kind,
    required Map<String, Uint8List> files,
    required List<String> parentRevisionIds,
    String? ownerNoteId,
    bool deleted = false,
    Map<String, List<String>> baseRefs = const {},
  }) => inner.prepareCommit(
    entityId: entityId,
    kind: kind,
    files: files,
    parentRevisionIds: parentRevisionIds,
    ownerNoteId: ownerNoteId,
    deleted: deleted,
    baseRefs: baseRefs,
  );
  @override
  Future<RevisionRecord> commitPreparedIfHeads(
    PreparedCommit prepared, {
    required Map<String, List<String>> expectedHeads,
    List<String>? expectedRevisionIds,
    void Function()? beforePublish,
    bool allowHistoricalParents = false,
  }) async {
    attempts.add(prepared.record);
    await beforeConditional?.call(prepared);
    final result = await inner.commitPreparedIfHeads(
      prepared,
      expectedHeads: expectedHeads,
      expectedRevisionIds: expectedRevisionIds,
      beforePublish: beforePublish,
      allowHistoricalParents: allowHistoricalParents,
    );
    afterPublish?.call(result);
    if (loseResponseFor == prepared.record.kind) {
      loseResponseFor = null;
      throw StateError('Lost response after publication');
    }
    return result;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
