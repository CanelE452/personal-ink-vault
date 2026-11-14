import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;
  final opened = <NoteRepository>[];
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('ink-library-format-');
  });
  tearDown(() async {
    for (final repository in opened) {
      await repository.close();
    }
    opened.clear();
    await temp.delete(recursive: true);
  });
  Future<NoteRepository> open(
    String name, {
    int version = 1,
    String? vaultId,
  }) async {
    final repository = await NoteRepository.open(
      Directory('${temp.path}/$name'),
      vaultId: vaultId,
      createFormatVersion: version,
    );
    opened.add(repository);
    return repository;
  }

  test(
    'v2 persists folders and attachments while default repositories remain v1',
    () async {
      final legacy = await open('legacy');
      expect(legacy.formatVersion, 1);
      final repository = await open('v2', version: 2);
      final folder = await repository.commit(
        entityId: newId(),
        kind: EntityKind.folder,
        files: {
          'folder.json': Uint8List.fromList(
            utf8.encode('{"title":"Research"}'),
          ),
        },
        parentRevisionIds: [],
      );
      final source = await repository.commit(
        entityId: newId(),
        kind: EntityKind.attachment,
        ownerNoteId: newId(),
        files: {
          'source.pptx': Uint8List.fromList([0, 1, 2, 255]),
        },
        parentRevisionIds: [],
      );
      expect(folder.formatVersion, 2);
      await repository.close();
      final reopened = await open('v2');
      expect(reopened.formatVersion, 2);
      expect(
        (await reopened.heads(folder.entityId)).single.kind,
        EntityKind.folder,
      );
      expect((await reopened.readFiles(source))['source.pptx'], [0, 1, 2, 255]);
      await expectLater(
        legacy.commit(
          entityId: newId(),
          kind: EntityKind.folder,
          files: {},
          parentRevisionIds: [],
        ),
        throwsFormatException,
      );
    },
  );

  test('v1 refuses v2 import before writing manifests or blobs', () async {
    final repository = await open('v1');
    final record = RevisionRecord(
      vaultId: repository.vaultId,
      entityId: newId(),
      kind: EntityKind.metadata,
      revisionId: newId(),
      parentRevisionIds: [],
      deviceId: newId(),
      blobs: {},
      formatVersion: 2,
    );
    await expectLater(
      repository.importRevision(record, blobsByHash: {}),
      throwsFormatException,
    );
    expect(await repository.revisions(), isEmpty);
    expect(
      await Directory('${repository.root.path}/revisions').list().isEmpty,
      isTrue,
    );
  });

  test(
    'v1 to v2 clone keeps every branch, tombstone, owner, base and byte',
    () async {
      final repository = await open('v1');
      final noteId = newId();
      final entity = newId();
      final first = await repository.commit(
        entityId: entity,
        kind: EntityKind.ink,
        ownerNoteId: noteId,
        files: {
          'main.sbn2': Uint8List.fromList([1, 2]),
          'source.pdf': Uint8List.fromList([37, 80, 68, 70]),
        },
        parentRevisionIds: [],
      );
      for (final deleted in [true, false]) {
        await repository.commit(
          entityId: entity,
          kind: EntityKind.ink,
          ownerNoteId: noteId,
          files: {
            'main.sbn2': Uint8List.fromList([deleted ? 3 : 4]),
          },
          parentRevisionIds: [first.revisionId],
          deleted: deleted,
          baseRefs: {
            noteId: [first.revisionId],
          },
        );
      }
      final before = await repository.revisions();
      final snapshot = await BackupService.exportSnapshot(repository);
      final clone = await BackupService.restoreToEmpty(
        snapshot,
        Directory('${temp.path}/clone'),
        targetFormatVersion: 2,
      );
      opened.add(clone);
      expect(clone.formatVersion, 2);
      expect(repository.formatVersion, 1);
      expect(clone.vaultId, isNot(repository.vaultId));
      expect(await clone.heads(entity), hasLength(2));
      for (final original in before) {
        final copied = (await clone.revisions()).singleWhere(
          (r) => r.revisionId == original.revisionId,
        );
        expect(copied.toJson(), {
          ...original.toJson(),
          'vaultId': clone.vaultId,
        });
        expect(
          await clone.readFiles(copied),
          await repository.readFiles(original),
        );
      }
      final newRevision = await clone.commit(
        entityId: entity,
        kind: EntityKind.ink,
        ownerNoteId: noteId,
        files: {
          'main.sbn2': Uint8List.fromList([5]),
        },
        parentRevisionIds: (await clone.heads(entity))
            .map((r) => r.revisionId)
            .toList(),
      );
      expect(newRevision.formatVersion, 2);
      final roundtrip = await BackupService.restoreToEmpty(
        await BackupService.exportSnapshot(clone),
        Directory('${temp.path}/roundtrip'),
      );
      opened.add(roundtrip);
      expect(roundtrip.formatVersion, 2);
      expect(await roundtrip.revisions(), hasLength(4));
    },
  );

  test(
    'invalid versions and v2 downgrade leave the destination untouched',
    () async {
      final repository = await open('v2', version: 2);
      await repository.commit(
        entityId: newId(),
        kind: EntityKind.folder,
        files: {},
        parentRevisionIds: [],
      );
      final snapshot = await BackupService.exportSnapshot(repository);
      final destination = Directory('${temp.path}/untouched');
      await expectLater(
        BackupService.restoreToEmpty(
          snapshot,
          destination,
          targetFormatVersion: 1,
        ),
        throwsFormatException,
      );
      expect(await destination.exists(), isFalse);
      final raw = jsonDecode(utf8.decode(snapshot)) as Map<String, dynamic>;
      raw['formatVersion'] = 1;
      await expectLater(
        BackupService.restoreToEmpty(
          Uint8List.fromList(utf8.encode(jsonEncode(raw))),
          destination,
        ),
        throwsFormatException,
      );
      expect(await destination.exists(), isFalse);
      await expectLater(open('unsupported', version: 3), throwsFormatException);
      expect(await Directory('${temp.path}/unsupported').exists(), isFalse);
      expect(
        () => RevisionRecord.fromJson({
          ...(raw['revisions'] as List).single as Map<String, dynamic>,
          'formatVersion': 1,
        }),
        throwsFormatException,
      );
    },
  );
}
