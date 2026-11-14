import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/vault/block_page_document.dart';
import 'package:saber/data/vault/block_page_media.dart';
import 'package:saber/data/vault/database_history_snapshot.dart';
import 'package:saber/data/vault/library_store.dart';
import 'package:saber/data/vault/workspace_database.dart';
import 'package:saber/data/vault/workspace_store.dart';

Uint8List _jsonBytes(Object? json) =>
    Uint8List.fromList(utf8.encode(jsonEncode(json)));

void main() {
  late Directory directory;
  late NoteRepository repository;
  late WorkspaceStore store;
  late VaultNote note;
  late NoteSession session;
  late WorkspaceDatabase database;
  late String folderId;

  Map<String, Uint8List> files(WorkspaceDatabase value) => {
    'database.json': _jsonBytes(value.toJson()),
  };

  Future<RevisionRecord> head() async =>
      (await repository.heads(note.inkEntityId)).single;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('database-history-');
    repository = await NoteRepository.open(directory, createFormatVersion: 2);
    store = WorkspaceStore(repository);
    folderId = (await LibraryStore(repository).createFolder('Projects')).id;
    note = await store.create(
      'Tasks',
      folderId: folderId,
      documentKind: VaultDocumentKind.database,
    );
    session = await store.open(note);
    database = WorkspaceDatabase.empty();
  });

  tearDown(() async {
    await repository.close();
    await directory.delete(recursive: true);
  });

  test(
    'restores owned database and media to one child of the compared head',
    () async {
      final asset = BlockPageMediaAsset.attachment(
        name: 'old.txt',
        bytes: utf8.encode('prior attachment'),
      );
      final blockId = newId();
      final body = const BlockPageDocument.empty().copyWith(
        blocks: [
          BlockPageBlock.fromJson({'id': blockId, 'type': 'attachment'}),
        ],
        media: {blockId: asset.reference},
      );
      final historical = database.addRow(
        DatabaseRow.create(body: body.toJson()),
      );
      final original = {
        ...files(historical),
        asset.reference.path: asset.bytes,
      };
      await session.saveInk(original);
      final selected = await head();
      await session.saveInk(files(database));
      final observed = await head();
      await session.saveMarkdown('Separate summary');
      final markdown = (await repository.heads(note.markdownEntityId)).single;

      final snapshot = await DatabaseHistorySnapshot.read(session);
      expect(snapshot.currentRevision.revisionId, observed.revisionId);
      expect(snapshot.revisions.map((record) => record.revisionId), [
        observed.revisionId,
        selected.revisionId,
      ]);
      expect(snapshot.belongsTo(session), isTrue);
      final revisionCount = (await repository.revisions()).length;
      var validated = 0;
      await snapshot.restore(
        selected,
        validateActions: (candidate) {
          expect(candidate.toJson(), historical.toJson());
          validated++;
        },
      );
      expect(validated, 1);
      final restored = await head();
      expect(restored.parentRevisionIds, [observed.revisionId]);
      expect(restored.revisionId, isNot(selected.revisionId));
      expect(session.inkParents, [restored.revisionId]);
      expect(await repository.readFiles(restored), original);
      expect(await repository.readFiles(selected), original);
      expect(
        (await repository.heads(note.markdownEntityId)).single.revisionId,
        markdown.revisionId,
      );
      expect((await repository.revisions()).length, revisionCount + 1);
    },
  );

  test(
    'foreign or forged history records cannot be compared or restored',
    () async {
      await session.saveInk(files(database));
      final selected = await head();
      final snapshot = await DatabaseHistorySnapshot.read(session);
      final forged = RevisionRecord.fromJson({
        ...selected.toJson(),
        'deviceId': newId(),
      });
      final other = await store.create(
        'Other',
        documentKind: VaultDocumentKind.database,
      );
      final otherSession = await store.open(other);
      await otherSession.saveInk(files(database));
      final foreign = (await repository.heads(other.inkEntityId)).single;
      for (final chosen in [forged, foreign]) {
        await expectLater(snapshot.compare(chosen), throwsFormatException);
        await expectLater(snapshot.restore(chosen), throwsFormatException);
      }
      expect((await head()).revisionId, selected.revisionId);
    },
  );

  test(
    'the exact folder revision and a later body edit guard publication',
    () async {
      await session.saveInk(files(database));
      final selected = await head();
      final current = database.addRow(DatabaseRow.create());
      await session.saveInk(files(current));
      final observed = await head();
      final staleFolder = await DatabaseHistorySnapshot.read(session);
      final folder = (await LibraryStore(repository).listFolders()).single;
      await LibraryStore(repository).renameFolder(folder, 'Renamed');
      await expectLater(staleFolder.restore(selected), throwsStateError);
      expect((await head()).revisionId, observed.revisionId);

      final staleBody = await DatabaseHistorySnapshot.read(session);
      await session.saveInk(files(current.addRow(DatabaseRow.create())));
      final later = await head();
      await expectLater(staleBody.restore(selected), throwsStateError);
      expect((await head()).revisionId, later.revisionId);
    },
  );

  test('a caller losing write access cannot publish the restore', () async {
    await session.saveInk(files(database));
    final selected = await head();
    await session.saveInk(files(database.addRow(DatabaseRow.create())));
    final observed = await head();
    final snapshot = await DatabaseHistorySnapshot.read(session);
    await expectLater(
      snapshot.restore(
        selected,
        requireWrite: () => throw StateError('Write access ended'),
      ),
      throwsStateError,
    );
    expect((await head()).revisionId, observed.revisionId);
  });

  test(
    'comparison avoids historical media bytes but restore requires them',
    () async {
      final asset = BlockPageMediaAsset.attachment(
        name: 'missing.txt',
        bytes: utf8.encode('missing attachment'),
      );
      final id = newId();
      final body = const BlockPageDocument.empty().copyWith(
        blocks: [
          BlockPageBlock.fromJson({'id': id, 'type': 'attachment'}),
        ],
        media: {id: asset.reference},
      );
      final historical = database.addRow(
        DatabaseRow.create(body: body.toJson()),
      );
      await session.saveInk(files(historical));
      final selected = await head();
      await session.saveInk(files(database));
      final observed = await head();
      final snapshot = await DatabaseHistorySnapshot.read(session);
      final difference = await snapshot.compare(selected);
      expect(difference.rows.removed, 1);
      await expectLater(snapshot.restore(selected), throwsFormatException);
      expect((await head()).revisionId, observed.revisionId);
    },
  );

  test(
    'retains current rules and receipts and validates rules before publication',
    () async {
      await session.saveInk(files(database));
      final selected = await head();
      final ruleId = newId(), generatedRowId = newId();
      final rules = [
        {
          'id': ruleId,
          'version': 1,
          'name': 'Action',
          'enabled': true,
          'trigger': {'type': 'manual'},
          'actions': [
            {'id': newId(), 'type': 'addRow', 'values': <String, dynamic>{}},
          ],
        },
      ];
      final executions = [
        {
          'id': newId(),
          'ruleId': ruleId,
          'ruleVersion': 1,
          'eventId': newId(),
          'inputRevision': selected.revisionId,
          'deviceId': repository.deviceId,
          'capturedAtUtcMs': 1793343600000,
          'eventDigest': 'a' * 64,
          'ruleDigest': 'b' * 64,
          'status': 'completed',
          'actionResults': [],
        },
      ];
      final forms = [
        {
          'rowId': generatedRowId,
          'formId': newId(),
          'requestId': newId(),
          'inputRevision': selected.revisionId,
          'submittedAt': DateTime.utc(2026, 11, 8).toIso8601String(),
          'answersDigest': 'c' * 64,
          'formDigest': 'd' * 64,
        },
      ];
      final current = WorkspaceDatabase.fromJson({
        ...database.addRow(DatabaseRow.create(id: generatedRowId)).toJson(),
        'automationRules': rules,
        'automationExecutions': executions,
        'formSubmissions': forms,
      });
      await session.saveInk(files(current));
      final observed = await head();
      final snapshot = await DatabaseHistorySnapshot.read(session);
      await expectLater(snapshot.restore(selected), throwsStateError);
      await expectLater(
        snapshot.restore(
          selected,
          validateActions: (_) =>
              throw const FormatException('Rejected candidate'),
        ),
        throwsFormatException,
      );
      expect((await head()).revisionId, observed.revisionId);
      WorkspaceDatabase? validated;
      await snapshot.restore(
        selected,
        validateActions: (candidate) => validated = candidate,
      );
      expect(validated!.rows, isEmpty);
      final restored = jsonObject(
        jsonDecode(
          utf8.decode(
            await repository.readRevisionFile(await head(), 'database.json'),
          ),
        ),
      );
      expect(restored['automationRules'], rules);
      expect(restored['automationExecutions'], executions);
      expect(restored['formSubmissions'], forms);
      expect(restored, validated!.toJson());

      await session.saveInk(
        files(WorkspaceDatabase.fromJson({...restored, 'automationRules': []})),
      );
      final withoutRules = await head();
      final retiredHistory = await DatabaseHistorySnapshot.read(session);
      await expectLater(retiredHistory.restore(selected), throwsStateError);
      expect((await head()).revisionId, withoutRules.revisionId);
    },
  );

  test('a lost response acknowledges the same published restore without a second commit', () async {
    await session.saveInk(files(database));
    final selected = await head();
    await session.saveInk(files(database.addRow(DatabaseRow.create())));
    final interrupted = _InterruptedRepository(repository);
    session.repository = interrupted;
    final snapshot = await DatabaseHistorySnapshot.read(session);
    final count = (await repository.revisions()).length;

    await expectLater(snapshot.restore(selected), throwsStateError);
    final restored = await head();
    await snapshot.restore(selected);
    expect(interrupted.attempts, [restored.revisionId]);
    expect(session.inkParents, [restored.revisionId]);
    expect((await repository.revisions()).length, count + 1);
  });
}

class _InterruptedRepository implements NoteRepository {
  new(this.inner);
  final NoteRepository inner;
  final attempts = <String>[];

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
  Future<Map<String, Uint8List>> readFiles(RevisionRecord revision) =>
      inner.readFiles(revision);
  @override
  Future<Uint8List> readRevisionFile(RevisionRecord revision, String name) =>
      inner.readRevisionFile(revision, name);

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
    attempts.add(prepared.record.revisionId);
    final result = await inner.commitPreparedIfHeads(
      prepared,
      expectedHeads: expectedHeads,
      expectedRevisionIds: expectedRevisionIds,
      beforePublish: beforePublish,
      allowHistoricalParents: allowHistoricalParents,
    );
    if (attempts.length == 1) throw StateError('Published, response lost');
    return result;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
