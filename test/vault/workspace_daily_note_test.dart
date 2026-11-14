import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/vault/library_store.dart';
import 'package:saber/data/vault/workspace_store.dart';

void main() {
  final day = DateTime(2026, 11, 8);
  late Directory temp;
  late NoteRepository first;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('piv-daily-');
    first = await NoteRepository.open(
      Directory('${temp.path}/first'),
      createFormatVersion: 2,
    );
  });
  tearDown(() async {
    await first.close();
    await temp.delete(recursive: true);
  });

  Future<NoteRepository> peer({String name = 'second'}) async {
    final repository = await NoteRepository.open(
      Directory('${temp.path}/$name'),
      vaultId: first.vaultId,
      createFormatVersion: 2,
    );
    addTearDown(repository.close);
    return repository;
  }

  Future<void> copyRevision(
    RevisionRecord revision,
    NoteRepository source,
    NoteRepository destination,
  ) async {
    await destination.importRevision(
      revision,
      blobsByHash: {
        for (final ref in revision.blobs.values)
          ref.hash: await source.readBlob(ref.hash),
      },
    );
  }

  ({Uint8List bytes, Map<String, List<String>> expectedHeads}) initialMarkdown(
    String text, {
    Map<String, List<String>> expectedHeads = const {},
  }) => (
    bytes: Uint8List.fromList(utf8.encode(text)),
    expectedHeads: expectedHeads,
  );

  test(
    'concurrent daily opens retain one note and preserve a same-title note',
    () async {
      final workspace = WorkspaceStore(first);
      final ordinary = await workspace.create(
        '2026-11-08',
        documentKind: VaultDocumentKind.markdown,
      );
      final dated = await Future.wait([
        workspace.openDailyNote(day),
        WorkspaceStore(first).openDailyNote(DateTime(2026, 11, 8, 23, 59)),
      ]);
      final note = dated.first;
      expect(dated.last.id, note.id);
      expect(note.id, isNot(ordinary.id));
      expect(note.title, '2026-11-08');
      expect(note.documentKind, VaultDocumentKind.markdown);
      expect(note.folderId, isNull);
      expect(note.json['dailyDate'], '2026-11-08');
      expect(
        (await workspace.list()).map((entry) => entry.id),
        unorderedEquals([ordinary.id, note.id]),
      );
      expect(await first.heads(note.id), hasLength(1));
      expect(await first.heads(note.markdownEntityId), hasLength(1));
      final next = await workspace.openDailyNote(DateTime(2026, 11, 9));
      expect(next.id, isNot(note.id));
    },
  );

  test(
    'offline peers share exact genesis and keep divergent edited heads',
    () async {
      final second = await peer();
      final firstStore = WorkspaceStore(first);
      final secondStore = WorkspaceStore(second);
      final a = await firstStore.openDailyNote(day);
      final b = await secondStore.openDailyNote(day);
      expect(first.deviceId, isNot(second.deviceId));
      expect(a.id, b.id);
      expect(a.revision.toJson(), b.revision.toJson());
      final aBody = (await first.heads(a.markdownEntityId)).single;
      final bBody = (await second.heads(b.markdownEntityId)).single;
      expect(aBody.toJson(), bBody.toJson());
      await copyRevision(a.revision, first, second);
      await copyRevision(bBody, second, first);
      expect(await first.revisions(), hasLength(2));
      expect(await second.revisions(), hasLength(2));
      await (await firstStore.open(a)).saveMarkdown('첫 기기');
      await (await secondStore.open(b)).saveMarkdown('둘째 기기');
      final aEdited = (await first.heads(a.markdownEntityId)).single;
      final bEdited = (await second.heads(b.markdownEntityId)).single;
      await copyRevision(aEdited, first, second);
      await copyRevision(bEdited, second, first);
      final reopened = await firstStore.openDailyNote(day);
      final session = await firstStore.open(reopened);
      expect(session.markdownHeads, hasLength(2));
      expect([
        for (final head in session.markdownHeads)
          utf8.decode(await first.readRevisionFile(head, 'summary.md')),
      ], unorderedEquals(['첫 기기', '둘째 기기']));
    },
  );

  test(
    'only the first daily open seeds Markdown, even after clearing it',
    () async {
      final workspace = WorkspaceStore(first);
      final calls = <String>[];
      final created = await workspace.openDailyNote(
        day,
        loadInitialMarkdown: (title) async {
          calls.add(title);
          return initialMarkdown('# $title\n첫 본문');
        },
      );
      final body = (await first.heads(created.markdownEntityId)).single;
      expect(
        utf8.decode(await first.readRevisionFile(body, 'summary.md')),
        '# 2026-11-08\n첫 본문',
      );
      final initialSession = await workspace.open(created);
      await initialSession.saveMarkdown('');
      final cleared = (await first.heads(created.markdownEntityId)).single;
      final reopened = await workspace.openDailyNote(
        day,
        loadInitialMarkdown: (title) async {
          calls.add(title);
          throw StateError('Existing daily notes must skip template loading');
        },
      );
      expect(calls, ['2026-11-08']);
      expect(reopened.id, created.id);
      expect(
        (await first.heads(reopened.markdownEntityId)).single.revisionId,
        cleared.revisionId,
      );
      expect(await first.readRevisionFile(cleared, 'summary.md'), isEmpty);
    },
  );

  test(
    'concurrent local daily opens do not replace the first seeded body',
    () async {
      final workspace = WorkspaceStore(first);
      final started = Completer<void>();
      final otherStarted = Completer<void>();
      final firstSeed = Completer<void>();
      final secondSeed = Completer<void>();
      final firstOpen = workspace.openDailyNote(
        day,
        loadInitialMarkdown: (title) async {
          started.complete();
          await firstSeed.future;
          return initialMarkdown('첫 본문');
        },
      );
      await started.future;
      final secondOpen = WorkspaceStore(first).openDailyNote(
        day,
        loadInitialMarkdown: (title) async {
          otherStarted.complete();
          await secondSeed.future;
          return initialMarkdown('뒤늦은 본문');
        },
      );
      await otherStarted.future;
      firstSeed.complete();
      final firstNote = await firstOpen;
      final firstHead = (await first.heads(firstNote.markdownEntityId)).single;
      secondSeed.complete();
      final secondNote = await secondOpen;
      expect(secondNote.id, firstNote.id);
      expect((await workspace.list()).single.id, firstNote.id);
      expect(
        (await first.heads(firstNote.markdownEntityId)).single.revisionId,
        firstHead.revisionId,
      );
      expect(
        utf8.decode(await first.readRevisionFile(firstHead, 'summary.md')),
        '첫 본문',
      );
      expect(await first.revisions(), hasLength(3));
    },
  );

  test('offline peers deduplicate identical seeded daily bodies', () async {
    final second = await peer();
    final a = await WorkspaceStore(first).openDailyNote(
      day,
      loadInitialMarkdown: (title) async => initialMarkdown('# $title\n공통 본문'),
    );
    final b = await WorkspaceStore(second).openDailyNote(
      day,
      loadInitialMarkdown: (title) async => initialMarkdown('# $title\n공통 본문'),
    );
    final aBody = (await first.heads(a.markdownEntityId)).single;
    final bBody = (await second.heads(b.markdownEntityId)).single;
    expect(first.deviceId, isNot(second.deviceId));
    expect(a.revision.toJson(), b.revision.toJson());
    expect(aBody.revisionId, bBody.revisionId);
    expect(aBody.toJson(), bBody.toJson());
    final genesis = (await first.revisions()).singleWhere(
      (record) => record.revisionId == aBody.parentRevisionIds.single,
    );
    expect(await first.readRevisionFile(genesis, 'summary.md'), isEmpty);
    expect(
      utf8.decode(await first.readRevisionFile(aBody, 'summary.md')),
      '# 2026-11-08\n공통 본문',
    );
    await copyRevision(aBody, first, second);
    await copyRevision(bBody, second, first);
    expect(await first.revisions(), hasLength(3));
    expect(await second.revisions(), hasLength(3));
    expect(
      (await first.heads(a.markdownEntityId)).single.revisionId,
      aBody.revisionId,
    );
    expect(
      (await second.heads(b.markdownEntityId)).single.revisionId,
      bBody.revisionId,
    );
  });

  test('offline peers retain both differently seeded daily bodies', () async {
    final second = await peer();
    final a = await WorkspaceStore(first).openDailyNote(
      day,
      loadInitialMarkdown: (title) async => initialMarkdown('첫 기기의 템플릿'),
    );
    final b = await WorkspaceStore(second).openDailyNote(
      day,
      loadInitialMarkdown: (title) async => initialMarkdown('둘째 기기의 템플릿'),
    );
    final aBody = (await first.heads(a.markdownEntityId)).single;
    final bBody = (await second.heads(b.markdownEntityId)).single;
    expect(a.id, b.id);
    expect(a.revision.toJson(), b.revision.toJson());
    expect(aBody.parentRevisionIds, [bBody.parentRevisionIds.single]);
    expect(aBody.revisionId, isNot(bBody.revisionId));
    await copyRevision(aBody, first, second);
    await copyRevision(bBody, second, first);
    for (final repository in [first, second]) {
      final bodies = await repository.heads(a.markdownEntityId);
      expect(
        bodies.map((record) => record.revisionId),
        unorderedEquals([aBody.revisionId, bBody.revisionId]),
      );
      expect([
        for (final body in bodies)
          utf8.decode(await repository.readRevisionFile(body, 'summary.md')),
      ], unorderedEquals(['첫 기기의 템플릿', '둘째 기기의 템플릿']));
      expect(await repository.revisions(), hasLength(4));
    }
  });

  test('a daily loader error or publication veto leaves no target', () async {
    final workspace = WorkspaceStore(first);
    await expectLater(
      workspace.openDailyNote(
        day,
        loadInitialMarkdown: (_) async => throw StateError('템플릿 읽기 실패'),
      ),
      throwsStateError,
    );
    expect(await first.revisions(), isEmpty);
    await expectLater(
      workspace.openDailyNote(
        day,
        loadInitialMarkdown: (_) async => initialMarkdown('버려야 할 본문'),
        beforePublish: () => throw StateError('보관함 전환'),
      ),
      throwsStateError,
    );
    expect(await workspace.list(), isEmpty);
    expect(await first.revisions(), isEmpty);
  });

  test('stale template revision guards do not create a daily target', () async {
    final workspace = WorkspaceStore(first);
    final template = await workspace.createMarkdown(
      '일일 템플릿',
      Uint8List.fromList(utf8.encode('이전 내용')),
    );
    final stale = (await first.heads(template.markdownEntityId)).single;
    final session = await workspace.open(template);
    await session.saveMarkdown('새 내용');
    final before = (await first.revisions()).map((record) => record.revisionId);
    await expectLater(
      workspace.openDailyNote(
        day,
        loadInitialMarkdown: (_) async => initialMarkdown(
          '이전 내용',
          expectedHeads: {
            template.markdownEntityId: [stale.revisionId],
          },
        ),
      ),
      throwsStateError,
    );
    expect((await workspace.list()).single.id, template.id);
    expect(
      (await first.revisions()).map((record) => record.revisionId),
      unorderedEquals(before),
    );
  });

  test('an interrupted seed resumes without rereading the template', () async {
    final workspace = WorkspaceStore(first);
    var publicationChecks = 0;
    await expectLater(
      workspace.openDailyNote(
        day,
        loadInitialMarkdown: (_) async => initialMarkdown('저장 중단 전 본문'),
        beforePublish: () {
          if (++publicationChecks == 3) throw StateError('Interrupted');
        },
      ),
      throwsStateError,
    );
    expect(await workspace.list(), isEmpty);
    expect(first.pendingRevisionCount, 1);
    final reopened = await workspace.openDailyNote(
      day,
      loadInitialMarkdown: (_) async => throw StateError('Do not reseed'),
    );
    expect(first.pendingRevisionCount, 0);
    expect(await (await workspace.open(reopened)).readMarkdown(), '저장 중단 전 본문');
  });

  test('a resolved empty template still checks its revision guard', () async {
    final workspace = WorkspaceStore(first);
    final watched = await workspace.createMarkdown('Template', Uint8List(0));
    final prior = (await first.heads(watched.markdownEntityId)).single;
    await expectLater(
      workspace.openDailyNote(
        day,
        loadInitialMarkdown: (_) async {
          await (await workspace.open(watched)).saveMarkdown('변경된 템플릿');
          return initialMarkdown(
            '',
            expectedHeads: {
              watched.markdownEntityId: [prior.revisionId],
            },
          );
        },
      ),
      throwsStateError,
    );
    expect((await workspace.list()).map((note) => note.id), [watched.id]);
  });

  test(
    'open finishes partial metadata publication without resetting body',
    () async {
      final second = await peer();
      final note = await WorkspaceStore(first).openDailyNote(day);
      final body = (await first.heads(note.markdownEntityId)).single;
      await copyRevision(body, first, second);
      await second.commit(
        entityId: body.entityId,
        kind: EntityKind.markdown,
        ownerNoteId: note.id,
        files: {'summary.md': utf8.encode('이미 받은 내용')},
        parentRevisionIds: [body.revisionId],
      );
      final workspace = WorkspaceStore(second);
      final restored = await workspace.openDailyNote(
        day,
        loadInitialMarkdown: (_) async {
          fail('A body-only partial daily note must not load a template');
        },
      );
      expect(restored.revision.toJson(), note.revision.toJson());
      final head = (await second.heads(restored.markdownEntityId)).single;
      expect(
        utf8.decode(await second.readRevisionFile(head, 'summary.md')),
        '이미 받은 내용',
      );
    },
  );

  test(
    'renamed and moved notes reopen and a trashed folder stays closed',
    () async {
      final workspace = WorkspaceStore(first);
      final library = LibraryStore(first);
      final note = await workspace.openDailyNote(day);
      final folder = await library.createFolder('기록');
      await workspace.rename(note, '연구 일지');
      await workspace.moveNote((await workspace.list()).single, folder.id);
      final moved = await workspace.openDailyNote(day);
      expect(moved.id, note.id);
      expect(moved.title, '연구 일지');
      expect(moved.folderId, folder.id);
      await library.setDeleted(folder, true);
      await expectLater(workspace.openDailyNote(day), throwsStateError);
      expect(await first.heads(note.id), hasLength(1));
    },
  );

  test(
    'a conflicting daily metadata branch is not selected automatically',
    () async {
      final workspace = WorkspaceStore(first);
      final note = await workspace.openDailyNote(day);
      await workspace.rename(note, '첫 제목');
      await first.commit(
        entityId: note.id,
        kind: EntityKind.metadata,
        files: {
          'note.json': utf8.encode(
            jsonEncode({...note.json, 'title': '둘째 제목'}),
          ),
        },
        parentRevisionIds: [note.revision.revisionId],
      );
      await expectLater(workspace.openDailyNote(day), throwsStateError);
      expect(await first.heads(note.id), hasLength(2));
    },
  );

  test(
    'a foreign record at the daily identity is not adopted or changed',
    () async {
      final reference = await WorkspaceStore(first).openDailyNote(day);
      final second = await peer();
      final foreign = await second.commit(
        entityId: reference.id,
        kind: EntityKind.metadata,
        files: {
          'note.json': utf8.encode(
            jsonEncode({
              'title': reference.title,
              'inkEntityId': newId(),
              'markdownEntityId': newId(),
              'documentKind': 'markdown',
            }),
          ),
        },
        parentRevisionIds: const [],
      );
      await expectLater(
        WorkspaceStore(second).openDailyNote(day),
        throwsStateError,
      );
      expect((await second.revisions()).single.revisionId, foreign.revisionId);
      expect(await second.heads(reference.markdownEntityId), isEmpty);
    },
  );

  test('clone with a new vault identity reopens the same daily note', () async {
    final note = await WorkspaceStore(first).openDailyNote(day);
    final clone = await first.cloneToEmpty(Directory('${temp.path}/clone'));
    addTearDown(clone.close);
    expect(clone.vaultId, isNot(first.vaultId));
    final reopened = await WorkspaceStore(clone).openDailyNote(day);
    expect(reopened.id, note.id);
    expect(reopened.revision.revisionId, note.revision.revisionId);
    expect(await clone.revisions(), hasLength(2));
  });
}
