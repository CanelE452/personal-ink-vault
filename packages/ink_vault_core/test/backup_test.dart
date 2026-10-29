import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;
  late NoteRepository source;
  late RevisionRecord note;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('ink-backup-test-');
    source = await NoteRepository.open(Directory('${temp.path}/source'));
    note = await source.commit(
      entityId: newId(),
      kind: EntityKind.ink,
      files: {
        'main.sbn2': Uint8List.fromList(utf8.encode('page-id: preserved')),
        'assets/source.pdf': Uint8List.fromList([37, 80, 68, 70]),
      },
      parentRevisionIds: [],
    );
  });
  tearDown(() async {
    await source.close();
    await temp.delete(recursive: true);
  });

  test('backup restores exact content and IDs into a distinct vault', () async {
    final data = await BackupService.exportSnapshot(source);
    final restored = await BackupService.restoreToEmpty(
      data,
      Directory('${temp.path}/restored'),
    );
    expect(restored.vaultId, isNot(source.vaultId));
    expect(restored.deviceId, isNot(source.deviceId));
    final head = (await restored.heads(note.entityId)).single;
    expect(head.revisionId, note.revisionId);
    expect(head.entityId, note.entityId);
    final files = await restored.readFiles(head);
    expect(utf8.decode(files['main.sbn2']!), 'page-id: preserved');
    expect(files['assets/source.pdf'], [37, 80, 68, 70]);
    expect(await File('${restored.root.path}/vault.json').exists(), isTrue);
    await restored.close();
  });

  test('corrupted or missing backup blob never creates destination', () async {
    final raw = jsonDecode(
      utf8.decode(await BackupService.exportSnapshot(source)),
    ) as Map<String, dynamic>;
    for (final replacement in [
      <String, String>{},
      {
        note.blobs.values.first.hash: base64Encode([0]),
      },
    ]) {
      final bad = Uint8List.fromList(
        utf8.encode(jsonEncode({...raw, 'blobs': replacement})),
      );
      final destination = Directory('${temp.path}/bad');
      await expectLater(
        BackupService.restoreToEmpty(bad, destination),
        throwsFormatException,
      );
      expect(await destination.exists(), isFalse);
    }
  });

  test('unsupported format, mixed vaults, duplicate revisions and orphan ancestry are rejected', () async {
    final raw = jsonDecode(
      utf8.decode(await BackupService.exportSnapshot(source)),
    ) as Map<String, dynamic>;
    final revision = note.toJson();
    final variants = [
      {...raw, 'formatVersion': 2},
      {
        ...raw,
        'revisions': [
          {...revision, 'vaultId': newId()},
        ],
      },
      {
        ...raw,
        'revisions': [revision, revision],
      },
      {
        ...raw,
        'revisions': [
          {
            ...revision,
            'parentRevisionIds': [newId()],
          },
        ],
      },
      {
        ...raw,
        'revisions': [
          {
            ...revision,
            'baseRefs': {'../escape': <String>[]},
          },
        ],
      },
      {
        ...raw,
        'revisions': [
          {
            ...revision,
            'blobs': {'../escape': note.blobs.values.first.toJson()},
          },
        ],
      },
    ];
    for (final variant in variants) {
      final destination = Directory('${temp.path}/bad');
      await expectLater(
        BackupService.restoreToEmpty(
          Uint8List.fromList(utf8.encode(jsonEncode(variant))),
          destination,
        ),
        throwsFormatException,
      );
      expect(await destination.exists(), isFalse);
    }
  });

  test(
    'existing content is never overwritten and size limits fail before restore',
    () async {
      final data = await BackupService.exportSnapshot(source);
      final existing = Directory('${temp.path}/existing');
      await existing.create();
      final marker = File('${existing.path}/keep');
      await marker.writeAsString('untouched');
      await expectLater(
        BackupService.restoreToEmpty(data, existing),
        throwsA(isA<FileSystemException>()),
      );
      expect(await marker.readAsString(), 'untouched');
      await expectLater(
        BackupService.restoreToEmpty(
          data,
          Directory('${temp.path}/too-large'),
          maxBytes: 8,
        ),
        throwsFormatException,
      );
      expect(await Directory('${temp.path}/too-large').exists(), isFalse);
      await expectLater(
        BackupService.exportSnapshot(source, maxBytes: 8),
        throwsFormatException,
      );
    },
  );

  test('backup refuses a known damaged vault instead of silently omitting revisions', () async {
    await source.close();
    await File('${source.root.path}/revisions/${note.revisionId}.json')
        .writeAsString('{');
    source = await NoteRepository.open(source.root);
    await expectLater(
      BackupService.exportSnapshot(source),
      throwsFormatException,
    );
  });

  test('restore IO failure leaves source and existing destination parent content intact', () async {
    final data = await BackupService.exportSnapshot(source);
    final blocker = File('${temp.path}/blocked');
    await blocker.writeAsString('keep');
    await expectLater(
      BackupService.restoreToEmpty(data, Directory('${blocker.path}/restored')),
      throwsA(isA<FileSystemException>()),
    );
    expect(await blocker.readAsString(), 'keep');
    expect(
      (await source.heads(note.entityId)).single.revisionId,
      note.revisionId,
    );
    expect((await source.readFiles(note))['assets/source.pdf'], [
      37,
      80,
      68,
      70,
    ]);
  });
}
