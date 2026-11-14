import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/vault/block_page_history.dart';
import 'package:saber/data/vault/library_store.dart';
import 'package:saber/data/vault/workspace_store.dart';

Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));
Map<String, dynamic> _copy(Map<String, dynamic> json) =>
    jsonObject(jsonDecode(jsonEncode(json)));

void main() {
  late Directory directory;
  late NoteRepository repository;
  late WorkspaceStore store;
  late LibraryStore library;
  late VaultFolder ancestor;
  late VaultFolder parent;
  late VaultNote note;
  late NoteSession session;
  late RevisionRecord selected;
  late RevisionRecord observed;
  late Map<String, Uint8List> selectedFiles;
  late String blockId;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('page-restore-plan-');
    repository = await NoteRepository.open(directory, createFormatVersion: 2);
    store = WorkspaceStore(repository);
    library = LibraryStore(repository);
    ancestor = await library.createFolder('Ancestor');
    parent = await library.createFolder('Parent', parentId: ancestor.id);
    note = await store.create(
      'Page',
      documentKind: VaultDocumentKind.page,
      folderId: parent.id,
    );
    session = await store.open(note);
    blockId = newId();
    selectedFiles = {
      'page.json': _bytes(
        jsonEncode({
          'version': 1,
          'blocks': [
            {
              'id': blockId,
              'type': 'paragraph',
              'text': 'Old',
              'future': {'keep': true},
            },
          ],
          'futurePage': [1, 2],
        }),
      ),
      'assets/source.bin': Uint8List.fromList([0, 255, 42]),
    };
    selected = await repository.commit(
      entityId: note.inkEntityId,
      kind: EntityKind.ink,
      ownerNoteId: note.id,
      files: selectedFiles,
      parentRevisionIds: [],
      baseRefs: {
        newId(): [newId()],
      },
    );
    session.inkParents = [selected.revisionId];
    await session.saveInk({
      'page.json': _bytes(
        jsonEncode({
          'version': 1,
          'blocks': [
            {'id': blockId, 'type': 'paragraph', 'text': 'Current'},
          ],
        }),
      ),
    });
    observed = (await repository.heads(note.inkEntityId)).single;
    await session.saveMarkdown('Separate summary');
  });
  tearDown(() async {
    await repository.close();
    await directory.delete(recursive: true);
  });

  test('plan roundtrip after restart preserves exact revision, full files and baseRefs', () async {
    final snapshot = await BlockPageHistorySnapshot.read(session);
    final count = (await repository.revisions()).length;
    final plan = await session.prepareInkRevisionRestore(
      selected,
      expectedHeadRevisionIds: snapshot.expectedHeadRevisionIds,
      expectedHeads: snapshot.expectedHeads,
    );
    final descriptor = _copy(plan.toJson());
    expect(plan.record.baseRefs, selected.baseRefs);
    expect(plan.record.parentRevisionIds, [observed.revisionId]);
    expect(plan.selectedRevisionId, selected.revisionId);
    expect(
      plan.expectedHeads.keys,
      unorderedEquals([note.inkEntityId, note.id, parent.id, ancestor.id]),
    );
    expect(
      () => plan.expectedHeads[note.id]!.add(newId()),
      throwsUnsupportedError,
    );
    expect(() => plan.expectedHeads.clear(), throwsUnsupportedError);
    expect((await repository.revisions()).length, count);
    expect(session.inkParents, [observed.revisionId]);
    descriptor['selectedRevisionId'] = observed.revisionId;
    expect(plan.selectedRevisionId, selected.revisionId);
    await repository.close();
    repository = await NoteRepository.open(directory);
    store = WorkspaceStore(repository);
    library = LibraryStore(repository);
    session = await store.open((await store.list()).single);
    final resumed = await session.resumeInkRevisionRestore(
      _copy(plan.toJson()),
    );
    expect(resumed.record.toJson(), plan.record.toJson());
    final result = await session.publishInkRevisionRestore(resumed);
    expect(result.revisionId, plan.record.revisionId);
    expect(await repository.readFiles(result), selectedFiles);
    expect(await repository.readFiles(selected), selectedFiles);
    expect(await session.readMarkdown(), 'Separate summary');
    expect((await repository.revisions()).length, count + 1);
  });

  test('damaged and forged plan bindings reject without publication', () async {
    final plan = await session.prepareInkRevisionRestore(
      selected,
      expectedHeadRevisionIds: [observed.revisionId],
    );
    final valid = plan.toJson();
    final mutations = <void Function(Map<String, dynamic>)>[
      (j) => j['extra'] = true,
      (j) => j.remove('selectedRevisionId'),
      (j) => j['selectedRevisionId'] = observed.revisionId,
      (j) => jsonObject(j['prepared'])['rootUri'] = Directory(
        '${directory.path}/foreign',
      ).absolute.uri.normalizePath().toString(),
      (j) => jsonObject(jsonObject(j['prepared'])['record'])['ownerNoteId'] =
          newId(),
      (j) => jsonObject(jsonObject(j['prepared'])['record'])['baseRefs'] = {},
      (j) =>
          jsonObject(jsonObject(j['prepared'])['record'])['parentRevisionIds'] =
              [selected.revisionId],
      (j) => jsonObject(jsonObject(j['prepared'])['record'])['blobs'] = observed
          .toJson()['blobs'],
      (j) => jsonObject(j['expectedHeads']).remove(ancestor.id),
      (j) => jsonObject(j['expectedHeads'])[newId()] = [newId()],
      (j) => jsonObject(j['expectedHeads'])[note.id] = [selected.revisionId],
    ];
    final count = (await repository.revisions()).length;
    for (final mutate in mutations) {
      final damaged = _copy(valid);
      mutate(damaged);
      await expectLater(
        session.resumeInkRevisionRestore(damaged),
        throwsFormatException,
      );
    }
    expect((await repository.revisions()).length, count);
    final clone = await NoteRepository.open(
      Directory('${directory.path}/clone'),
      vaultId: repository.vaultId,
      deviceId: repository.deviceId,
      createFormatVersion: 2,
    );
    try {
      final foreignSession = NoteSession(clone, note, [], []);
      await expectLater(
        foreignSession.resumeInkRevisionRestore(_copy(valid)),
        throwsFormatException,
      );
    } finally {
      await clone.close();
    }
  });

  test('published plan acknowledgement survives restart and later descendants without rewinding writer', () async {
    final plan = await session.prepareInkRevisionRestore(
      selected,
      expectedHeadRevisionIds: [observed.revisionId],
    );
    final guarded = _PlanRepository(repository)..loseResponse = true;
    session.repository = guarded;
    await expectLater(
      session.publishInkRevisionRestore(plan),
      throwsStateError,
    );
    expect(
      (await repository.heads(note.inkEntityId)).single.revisionId,
      plan.record.revisionId,
    );
    await repository.close();
    repository = await NoteRepository.open(directory);
    store = WorkspaceStore(repository);
    library = LibraryStore(repository);
    session = await store.open((await store.list()).single);
    await session.saveInk({'page.json': _bytes('{"version":1,"blocks":[]}')});
    final descendant = session.inkParents.single;
    final count = (await repository.revisions()).length;
    final resumed = await session.resumeInkRevisionRestore(
      _copy(plan.toJson()),
    );
    final acknowledgement = await session.publishInkRevisionRestore(resumed);
    expect(acknowledgement.revisionId, plan.record.revisionId);
    expect(session.inkParents, [descendant]);
    expect(
      (await repository.heads(note.inkEntityId)).single.revisionId,
      descendant,
    );
    expect((await repository.revisions()).length, count);
    await library.renameFolder(ancestor, 'Renamed after publication');
    final historical = await session.resumeInkRevisionRestore(
      _copy(plan.toJson()),
    );
    expect(
      (await session.publishInkRevisionRestore(historical)).revisionId,
      plan.record.revisionId,
    );
    expect(session.inkParents, [descendant]);
    await repository.commit(
      entityId: note.inkEntityId,
      kind: EntityKind.ink,
      ownerNoteId: note.id,
      files: selectedFiles,
      parentRevisionIds: [observed.revisionId],
    );
    final branchedCount = (await repository.revisions()).length;
    expect(
      (await session.publishInkRevisionRestore(historical)).revisionId,
      plan.record.revisionId,
    );
    expect(session.inkParents, [descendant]);
    expect(await repository.heads(note.inkEntityId), hasLength(2));
    expect((await repository.revisions()).length, branchedCount);
  });

  test('published acknowledgement accepts later trash and metadata conflicts without writing', () async {
    final plan = await session.prepareInkRevisionRestore(
      selected,
      expectedHeadRevisionIds: [observed.revisionId],
    );
    await session.publishInkRevisionRestore(plan);
    await library.setDeleted(ancestor, true);
    session.note = (await store.list(includeDeleted: true)).single;
    expect(session.note.trashed, isTrue);
    await repository.commit(
      entityId: note.id,
      kind: EntityKind.metadata,
      files: await repository.readFiles(note.revision),
      parentRevisionIds: [],
    );
    expect(await repository.heads(note.id), hasLength(2));
    final count = (await repository.revisions()).length;
    final resumed = await session.resumeInkRevisionRestore(
      _copy(plan.toJson()),
    );
    expect(
      (await session.publishInkRevisionRestore(resumed)).revisionId,
      plan.record.revisionId,
    );
    expect((await repository.revisions()).length, count);
  });

  for (final damage in ['malformed', 'different', 'missing']) {
    for (final resumeFirst in [false, true]) {
      test(
        'published ${resumeFirst ? 'resumed' : 'in-memory'} plan refuses $damage actual manifest',
        () async {
          final plan = await session.prepareInkRevisionRestore(
            selected,
            expectedHeadRevisionIds: [observed.revisionId],
          );
          await session.publishInkRevisionRestore(plan);
          final manifest = File(
            '${directory.path}/revisions/${plan.record.revisionId}.json',
          );
          if (damage == 'missing') {
            await manifest.delete();
          } else if (damage == 'malformed') {
            await manifest.writeAsString('{', flush: true);
          } else {
            final changed = plan.record.toJson()..['deviceId'] = newId();
            await manifest.writeAsString(jsonEncode(changed), flush: true);
          }
          final damagedBytes = damage == 'missing'
              ? null
              : await manifest.readAsBytes();
          final count = (await repository.revisions()).length;
          Future<RevisionRecord> retry() async {
            final retryPlan = resumeFirst
                ? await session.resumeInkRevisionRestore(_copy(plan.toJson()))
                : plan;
            return session.publishInkRevisionRestore(retryPlan);
          }

          await expectLater(
            retry(),
            throwsA(anyOf(isA<FormatException>(), isA<FileSystemException>())),
          );
          if (damage == 'missing') {
            expect(manifest.existsSync(), isFalse);
          } else {
            expect(await manifest.readAsBytes(), damagedBytes);
          }
          expect((await repository.revisions()).length, count);
          expect(await repository.readFiles(selected), selectedFiles);
        },
      );
    }
  }

  test('unpublished plan can decode after guard changes but publication rejects stale observations', () async {
    final plan = await session.prepareInkRevisionRestore(
      selected,
      expectedHeadRevisionIds: [observed.revisionId],
    );
    await library.renameFolder(ancestor, 'New folder head');
    final resumed = await session.resumeInkRevisionRestore(
      _copy(plan.toJson()),
    );
    expect(resumed.record.revisionId, plan.record.revisionId);
    await expectLater(
      session.publishInkRevisionRestore(resumed),
      throwsStateError,
    );
    expect(
      (await repository.heads(note.inkEntityId)).single.revisionId,
      observed.revisionId,
    );
  });

  test('current permission is checked immediately before the final manifest rename', () async {
    final plan = await session.prepareInkRevisionRestore(
      selected,
      expectedHeadRevisionIds: [observed.revisionId],
    );
    var finalRenameChecked = false;
    await expectLater(
      session.publishInkRevisionRestore(
        plan,
        requireWrite: () {
          final pending = Directory('${directory.path}/revisions')
              .listSync()
              .any(
                (f) =>
                    f.path.contains('${plan.record.revisionId}.json.') &&
                    f.path.endsWith('.tmp'),
              );
          if (pending) {
            finalRenameChecked = true;
            throw StateError('Permission revoked at final rename');
          }
        },
      ),
      throwsStateError,
    );
    expect(finalRenameChecked, isTrue);
    expect(
      File('${directory.path}/revisions/${plan.record.revisionId}.json')
          .existsSync(),
      isFalse,
    );
    expect(
      (await repository.heads(note.inkEntityId)).single.revisionId,
      observed.revisionId,
    );
    expect(
      (await session.publishInkRevisionRestore(plan)).revisionId,
      plan.record.revisionId,
    );
  });

  test('an ordinary save cannot bypass the permission validator of a pending restore', () async {
    final plan = await session.prepareInkRevisionRestore(
      selected,
      expectedHeadRevisionIds: [observed.revisionId],
    );
    var writable = false;
    void requireWrite() {
      if (!writable) throw StateError('Permission revoked');
    }

    await expectLater(
      session.publishInkRevisionRestore(plan, requireWrite: requireWrite),
      throwsStateError,
    );
    await expectLater(
      session.saveInk({'page.json': _bytes('{"version":1,"blocks":[]}')}),
      throwsStateError,
    );
    expect(
      (await repository.heads(note.inkEntityId)).single.revisionId,
      observed.revisionId,
    );
    writable = true;
    await session.saveInk({'page.json': _bytes('{"version":1,"blocks":[]}')});
    final head = (await repository.heads(note.inkEntityId)).single;
    expect(head.parentRevisionIds, [plan.record.revisionId]);
  });

  for (final changeFolder in [false, true]) {
    test(
      '${changeFolder ? 'folder' : 'metadata'} change between comparison and restore is rejected',
      () async {
        final snapshot = await BlockPageHistorySnapshot.read(session);
        if (changeFolder) {
          await library.renameFolder(ancestor, 'Changed folder');
        } else {
          final files = await repository.readFiles(note.revision);
          final metadata = jsonObject(
            jsonDecode(utf8.decode(files['note.json']!)),
          );
          await repository.commit(
            entityId: note.id,
            kind: EntityKind.metadata,
            files: {
              'note.json': _bytes(
                jsonEncode({...metadata, 'title': 'Changed title'}),
              ),
            },
            parentRevisionIds: [note.revision.revisionId],
          );
        }
        await expectLater(
          session.restoreInkRevision(
            selected,
            expectedHeadRevisionIds: snapshot.expectedHeadRevisionIds,
            expectedHeads: snapshot.expectedHeads,
          ),
          throwsStateError,
        );
        expect(
          (await repository.heads(note.inkEntityId)).single.revisionId,
          observed.revisionId,
        );
      },
    );
  }

  test(
    'snapshot validates its guards again after reading only the page body',
    () async {
      final guarded = _PlanRepository(repository);
      session.repository = guarded;
      guarded.afterPageRead = () async {
        guarded.afterPageRead = null;
        await library.renameFolder(ancestor, 'Changed during body read');
      };
      await expectLater(
        BlockPageHistorySnapshot.read(session),
        throwsStateError,
      );
      expect(guarded.wholeInkReads, 0);
      expect(guarded.pageReads, 1);
    },
  );

  test('history body reads skip attachments and accept saved pages larger than one MiB', () async {
    final largeText = 'x' * (1024 * 1024 + 1);
    await session.saveInk({
      'page.json': _bytes(
        jsonEncode({
          'version': 1,
          'blocks': [
            {'id': blockId, 'type': 'paragraph', 'text': largeText},
          ],
        }),
      ),
      'assets/large.bin': Uint8List(2 * 1024 * 1024),
    });
    final guarded = _PlanRepository(repository);
    session.repository = guarded;
    final snapshot = await BlockPageHistorySnapshot.read(session);
    expect(
      snapshot.currentDocument.blocks.single.text.length,
      largeText.length,
    );
    expect((await snapshot.readRevision(selected)).blocks.single.text, 'Old');
    expect(guarded.wholeInkReads, 0);
    expect(guarded.pageReads, 2);
  });
}

class _PlanRepository implements NoteRepository {
  new(this.inner);
  final NoteRepository inner;
  var loseResponse = false;
  var wholeInkReads = 0, pageReads = 0;
  Future<void> Function()? afterPageRead;
  @override
  Directory get root => inner.root;
  @override
  String get vaultId => inner.vaultId;
  @override
  String get deviceId => inner.deviceId;
  @override
  int get formatVersion => inner.formatVersion;
  @override
  Future<List<RevisionRecord>> revisions() => inner.revisions();
  @override
  Future<List<RevisionRecord>> heads(String id) => inner.heads(id);
  @override
  Future<Map<String, Uint8List>> readFiles(RevisionRecord revision) {
    if (revision.kind == EntityKind.ink) wholeInkReads++;
    return inner.readFiles(revision);
  }

  @override
  Future<Uint8List> readRevisionFile(
    RevisionRecord revision,
    String path,
  ) async {
    pageReads++;
    final bytes = await inner.readRevisionFile(revision, path);
    await afterPageRead?.call();
    return bytes;
  }

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
  PreparedCommit resumePreparedCommit({
    required Map<String, dynamic> descriptor,
    required Map<String, Uint8List> files,
  }) => inner.resumePreparedCommit(descriptor: descriptor, files: files);
  @override
  Future<RevisionRecord> commitPreparedIfHeads(
    PreparedCommit prepared, {
    required Map<String, List<String>> expectedHeads,
    List<String>? expectedRevisionIds,
    void Function()? beforePublish,
    bool allowHistoricalParents = false,
  }) async {
    final record = await inner.commitPreparedIfHeads(
      prepared,
      expectedHeads: expectedHeads,
      expectedRevisionIds: expectedRevisionIds,
      beforePublish: beforePublish,
      allowHistoricalParents: allowHistoricalParents,
    );
    if (loseResponse) {
      loseResponse = false;
      throw StateError('Published response lost');
    }
    return record;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
