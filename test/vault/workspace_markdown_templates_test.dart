import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/vault/library_store.dart';
import 'package:saber/data/vault/workspace_markdown_templates.dart';
import 'package:saber/data/vault/workspace_store.dart';

void main() {
  late Directory temporary;
  late NoteRepository repository;
  late WorkspaceMarkdownTemplateStore store;
  late LibraryStore library;
  late WorkspaceStore workspace;

  setUp(() async {
    final owner = Directory.systemTemp;
    temporary = await owner.createTemp('piv-markdown-templates-');
    addTearDown(() async {
      final resolved = await temporary.resolveSymbolicLinks();
      expect(p.dirname(resolved), await owner.resolveSymbolicLinks());
      expect(p.basename(resolved), startsWith('piv-markdown-templates-'));
      await Directory(resolved).delete(recursive: true);
    });
    repository = await NoteRepository.open(
      Directory(p.join(temporary.path, 'vault')),
      createFormatVersion: 2,
    );
    addTearDown(repository.close);
    store = WorkspaceMarkdownTemplateStore(repository);
    library = LibraryStore(repository);
    workspace = WorkspaceStore(repository);
  });

  test('stores per-vault settings in a guarded ownerless attachment', () async {
    final folder = await library.createFolder('Templates');
    final original = await store.settings();
    expect(original.folderId, isNull);
    expect(original.dateFormat, 'YYYY-MM-DD');
    expect(original.timeFormat, 'HH:mm');
    await expectLater(
      store.saveSettings(
        original,
        folderId: folder.id,
        dateFormat: 'YYYY-MM-DD',
        timeFormat: 'HH:mm',
        beforePublish: () => throw StateError('Vault changed'),
      ),
      throwsStateError,
    );
    expect((await store.settings()).revisionIds, isEmpty);
    final saved = await store.saveSettings(
      original,
      folderId: folder.id,
      dateFormat: 'DD/MM/YYYY',
      timeFormat: 'h:mm A',
    );
    await expectLater(
      store.saveSettings(
        original,
        folderId: null,
        dateFormat: 'YYYY-MM-DD',
        timeFormat: 'HH:mm',
      ),
      throwsA(isA<FormatException>()),
    );
    final attachment = (await repository.revisions()).singleWhere(
      (revision) => revision.revisionId == saved.revisionIds.single,
    );
    expect(attachment.kind, EntityKind.attachment);
    expect(attachment.ownerNoteId, isNull);
    await repository.close();
    final reopened = await NoteRepository.open(repository.root);
    addTearDown(reopened.close);
    final settings = await WorkspaceMarkdownTemplateStore(reopened).settings();
    expect(settings.folderId, folder.id);
    expect(settings.dateFormat, 'DD/MM/YYYY');
    expect(settings.timeFormat, 'h:mm A');
  });

  test('catalog includes only Markdown under a live folder path', () async {
    final root = await library.createFolder('Templates');
    final nested = await library.createFolder('Seminar', parentId: root.id);
    final note = await workspace.createMarkdown(
      'Lesson',
      Uint8List.fromList(utf8.encode('# {{title}}')),
      folderId: nested.id,
    );
    await workspace.create('Handwriting', folderId: nested.id);
    await workspace.createMarkdown('Outside', Uint8List(0));
    expect((await store.folders()).map((folder) => folder.label), [
      'Templates',
      'Templates/Seminar',
    ]);
    final choices = await store.templates(root.id);
    final choice = choices.single;
    expect(choice.noteId, note.id);
    expect(choice.label, 'Seminar/Lesson');
    expect(await store.readTemplate(root.id, choice), '# {{title}}');
    final session = await workspace.open(note);
    await session.saveMarkdown('# changed');
    await expectLater(
      store.readTemplate(root.id, choice),
      throwsA(isA<FormatException>()),
    );
    final latest = (await store.templates(root.id)).single;
    await repository.commit(
      entityId: nested.id,
      kind: EntityKind.folder,
      files: {
        'folder.json': Uint8List.fromList(
          utf8.encode('{"title":"Seminar","parentId":null}'),
        ),
      },
      parentRevisionIds: [nested.revision.revisionId],
    );
    expect(await store.templates(root.id), isEmpty);
    await expectLater(
      store.readTemplate(root.id, latest),
      throwsA(isA<FormatException>()),
    );
  });

  test(
    'daily default follows the current Markdown and keeps manual settings',
    () async {
      final folder = await library.createFolder('Templates');
      final template = await workspace.createMarkdown(
        'Lab journal',
        Uint8List.fromList(utf8.encode('# {{title}}\n{{date}} · {{time}}')),
        folderId: folder.id,
      );
      final manual = await store.saveSettings(
        await store.settings(),
        folderId: folder.id,
        dateFormat: 'DD/MM/YYYY',
        timeFormat: 'h:mm A',
      );
      final today = DateTime(2026, 11, 9, 13, 17);
      expect(await store.initialDailyMarkdown('2026-11-06', today), isNull);
      final previous = await store.dailyNoteTemplateSettings();
      final choice = (await store.templates(folder.id)).single;
      final saved = await store.saveDailyNoteTemplateSettings(
        previous,
        choice: choice,
      );
      expect(saved.folderId, folder.id);
      expect(saved.noteId, template.id);
      final resolved = await store.initialDailyMarkdown('2026-11-06', today);
      expect(
        utf8.decode(resolved!.bytes),
        '# 2026-11-06\n09/11/2026 · 1:17 PM',
      );
      expect(
        resolved.expectedHeads.values.expand((ids) => ids),
        containsAll([...saved.revisionIds, ...manual.revisionIds]),
      );
      expect((await store.settings()).revisionIds, manual.revisionIds);

      await (await workspace.open(template)).saveMarkdown('새 양식 {{title}}');
      await workspace.rename(template, 'Renamed journal');
      await expectLater(
        store.saveDailyNoteTemplateSettings(saved, choice: choice),
        throwsStateError,
      );
      final latest = await store.initialDailyMarkdown('2026-11-07', today);
      expect(utf8.decode(latest!.bytes), '새 양식 2026-11-07');

      final reopenedStore = WorkspaceMarkdownTemplateStore(repository);
      final persisted = await reopenedStore.dailyNoteTemplateSettings();
      expect(persisted.noteId, template.id);
      final cleared = await reopenedStore.saveDailyNoteTemplateSettings(
        persisted,
        choice: null,
      );
      expect(cleared.noteId, isNull);
      expect(await store.initialDailyMarkdown('2026-11-07', today), isNull);
      expect((await store.settings()).revisionIds, manual.revisionIds);
    },
  );

  test(
    'missing daily template prevents only new daily note creation',
    () async {
      final folder = await library.createFolder('Templates');
      final template = await workspace.createMarkdown(
        'Lab journal',
        Uint8List.fromList(utf8.encode('# {{title}}')),
        folderId: folder.id,
      );
      final day = DateTime(2026, 11, 8);
      final existing = await workspace.openDailyNote(day);
      await (await workspace.open(existing)).saveMarkdown('기존 기록');
      await store.saveDailyNoteTemplateSettings(
        await store.dailyNoteTemplateSettings(),
        choice: (await store.templates(folder.id)).single,
      );
      await workspace.setDeleted(template, true);
      final before = (await repository.revisions())
          .map((revision) => revision.revisionId)
          .toSet();
      final reopened = await workspace.openDailyNote(
        day,
        loadInitialMarkdown: (title) => store.initialDailyMarkdown(title, day),
      );
      expect(reopened.id, existing.id);
      expect(await (await workspace.open(reopened)).readMarkdown(), '기존 기록');
      await expectLater(
        workspace.openDailyNote(
          DateTime(2026, 11, 9),
          loadInitialMarkdown: (title) =>
              store.initialDailyMarkdown(title, day),
        ),
        throwsFormatException,
      );
      expect(
        (await repository.revisions())
            .map((revision) => revision.revisionId)
            .toSet(),
        before,
      );
    },
  );

  test('two devices reconcile all concurrent settings revisions', () async {
    final peer = await NoteRepository.open(
      Directory(p.join(temporary.path, 'peer')),
      vaultId: repository.vaultId,
      createFormatVersion: 2,
    );
    addTearDown(peer.close);
    final peerStore = WorkspaceMarkdownTemplateStore(peer);
    final folder = await library.createFolder('Templates');
    await copyRevision(repository, peer, folder.revision);
    final a = await store.saveSettings(
      await store.settings(),
      folderId: folder.id,
      dateFormat: 'DD/MM/YYYY',
      timeFormat: 'HH:mm',
    );
    final b = await peerStore.saveSettings(
      await peerStore.settings(),
      folderId: null,
      dateFormat: 'YYYY-MM-DD',
      timeFormat: 'h:mm A',
    );
    await copyRevision(repository, peer, await findRevision(repository, a));
    await copyRevision(peer, repository, await findRevision(peer, b));
    final conflict = await store.settings();
    expect(conflict.conflicted, isTrue);
    expect(conflict.folderId, isNull);
    expect(
      conflict.revisionIds,
      unorderedEquals([...a.revisionIds, ...b.revisionIds]),
    );
    final saved = await store.saveSettings(
      conflict,
      folderId: folder.id,
      dateFormat: 'DD/MM/YYYY',
      timeFormat: 'h:mm A',
    );
    await copyRevision(repository, peer, await findRevision(repository, saved));
    final synced = await peerStore.settings();
    expect(synced.conflicted, isFalse);
    expect(synced.folderId, folder.id);
    expect(synced.dateFormat, 'DD/MM/YYYY');
    expect(synced.timeFormat, 'h:mm A');
  });

  test('preserves foreign data at the reserved settings identity', () async {
    final prior = await store.settings();
    final record = await repository.commit(
      entityId: 'ed535140-6850-5d21-8c8f-e965c2bffb1a',
      kind: EntityKind.attachment,
      files: {'another-feature.json': Uint8List.fromList(utf8.encode('{}'))},
      parentRevisionIds: [],
    );
    await expectLater(
      store.saveSettings(
        prior,
        folderId: null,
        dateFormat: 'YYYY-MM-DD',
        timeFormat: 'HH:mm',
      ),
      throwsA(isA<FormatException>()),
    );
    expect(
      (await repository.heads(record.entityId)).single.revisionId,
      record.revisionId,
    );
  });
}

Future<RevisionRecord> findRevision(
  NoteRepository repository,
  WorkspaceMarkdownTemplateSettings settings,
) async => (await repository.revisions()).singleWhere(
  (record) => record.revisionId == settings.revisionIds.single,
);

Future<void> copyRevision(
  NoteRepository from,
  NoteRepository to,
  RevisionRecord record,
) async => to.importRevision(
  record,
  blobsByHash: {
    for (final blob in record.blobs.values)
      blob.hash: await from.readBlob(blob.hash),
  },
);
