import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late NoteRepository repository;
  late PreparedCommit prepared;
  final contents = Uint8List.fromList(utf8.encode('published contents'));
  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'published-confirmation-',
    );
    repository = await NoteRepository.open(directory);
    prepared = repository.prepareCommit(
      entityId: newId(),
      kind: EntityKind.markdown,
      files: {'summary.md': contents},
      parentRevisionIds: [],
    );
  });
  tearDown(() async {
    await repository.close();
    await directory.delete(recursive: true);
  });
  File manifest() =>
      File('${directory.path}/revisions/${prepared.record.revisionId}.json');
  File blob() => File(
    '${directory.path}/blobs/${prepared.record.blobs.values.single.hash}',
  );
  Future<void> stage() async {
    await blob().writeAsBytes(contents, flush: true);
    await manifest().writeAsString(
      jsonEncode(prepared.record.toJson()),
      flush: true,
    );
  }

  test(
    'confirmation never creates an unpublished record or missing manifest',
    () async {
      await expectLater(
        repository.confirmPublishedCommit(prepared),
        throwsA(isA<FileSystemException>()),
      );
      expect(await repository.revisions(), isEmpty);
      expect(manifest().existsSync(), false);
      expect(await Directory('${directory.path}/blobs').list().length, 0);
    },
  );
  test('exact disk-only record rejoins the index without rewriting immutable files or later heads', () async {
    await stage();
    final originalManifest = await manifest().readAsBytes();
    final modified = await manifest().lastModified();
    expect(await repository.revisions(), isEmpty);
    final confirmed = await repository.confirmPublishedCommit(prepared);
    expect(confirmed.revisionId, prepared.record.revisionId);
    expect(
      (await repository.heads(confirmed.entityId)).single.revisionId,
      confirmed.revisionId,
    );
    expect(await manifest().readAsBytes(), originalManifest);
    expect(await manifest().lastModified(), modified);
    final next = await repository.commit(
      entityId: confirmed.entityId,
      kind: confirmed.kind,
      files: {
        'summary.md': Uint8List.fromList([42]),
      },
      parentRevisionIds: [confirmed.revisionId],
    );
    expect(
      (await repository.confirmPublishedCommit(prepared)).revisionId,
      confirmed.revisionId,
    );
    expect(
      (await repository.heads(confirmed.entityId)).single.revisionId,
      next.revisionId,
    );
    expect((await repository.revisions()).length, 2);
    expect(await manifest().readAsBytes(), originalManifest);
    expect(await manifest().lastModified(), modified);
  });
  test('different actual manifest is rejected without repair or index registration', () async {
    await stage();
    final changed = prepared.record.toJson()..['deviceId'] = newId();
    await manifest().writeAsString(jsonEncode(changed));
    final before = await manifest().readAsBytes();
    await expectLater(
      repository.confirmPublishedCommit(prepared),
      throwsFormatException,
    );
    expect(await repository.revisions(), isEmpty);
    expect(await manifest().readAsBytes(), before);
    expect(await blob().readAsBytes(), contents);
  });
  test('actual payload corruption cannot be acknowledged or repaired from token bytes', () async {
    await stage();
    await repository.confirmPublishedCommit(prepared);
    final changed = Uint8List.fromList(List.filled(contents.length, 42));
    await blob().writeAsBytes(changed);
    await expectLater(
      repository.confirmPublishedCommit(prepared),
      throwsFormatException,
    );
    expect(await blob().readAsBytes(), changed);
    expect(await repository.heads(prepared.record.entityId), isEmpty);
  });
  test(
    'an external same-bytes manifest symlink cannot enter the published index',
    () async {
      await stage();
      final external = await Directory.systemTemp.createTemp(
        'published-confirmation-external-',
      );
      final outside = File('${external.path}/immutable.json');
      await outside.writeAsBytes(await manifest().readAsBytes(), flush: true);
      final original = await outside.readAsBytes();
      final modified = outside.lastModifiedSync();
      await manifest().delete();
      final link = Link(manifest().path);
      try {
        try {
          await link.create(outside.path);
        } on FileSystemException catch (error) {
          if (!Platform.isWindows ||
              !const {5, 1314}.contains(error.osError?.errorCode))
            rethrow;
          markTestSkipped(
            'This Windows host cannot create file symlinks: ${error.osError}',
          );
          return;
        }
        expect(
          FileSystemEntity.typeSync(link.path, followLinks: false),
          FileSystemEntityType.link,
        );
        await expectLater(
          repository.confirmPublishedCommit(prepared),
          throwsFormatException,
        );
        expect(await repository.revisions(), isEmpty);
        expect(await repository.heads(prepared.record.entityId), isEmpty);
        expect(await outside.readAsBytes(), original);
        expect(outside.lastModifiedSync(), modified);
        expect(
          FileSystemEntity.typeSync(link.path, followLinks: false),
          FileSystemEntityType.link,
        );
        await repository.close();
        repository = await NoteRepository.open(directory);
        expect(await repository.revisions(), isEmpty);
        expect(await outside.readAsBytes(), original);
      } finally {
        if (FileSystemEntity.typeSync(link.path, followLinks: false) ==
            FileSystemEntityType.link)
          await link.delete();
        await external.delete(recursive: true);
      }
    },
  );
  for (final missing in [true, false]) {
    test(
      'failed ${missing ? 'missing' : 'malformed'} known manifest confirmation invalidates its cached descendants',
      () async {
        await repository.commitPrepared(prepared);
        final child = await repository.commit(
          entityId: prepared.record.entityId,
          kind: prepared.record.kind,
          files: {
            'summary.md': Uint8List.fromList([21]),
          },
          parentRevisionIds: [prepared.record.revisionId],
        );
        final descendant = await repository.commit(
          entityId: child.entityId,
          kind: child.kind,
          files: {
            'summary.md': Uint8List.fromList([22]),
          },
          parentRevisionIds: [child.revisionId],
        );
        final healthy = await repository.commit(
          entityId: newId(),
          kind: EntityKind.markdown,
          files: {
            'summary.md': Uint8List.fromList([23]),
          },
          parentRevisionIds: [],
        );
        final childManifest = File(
          '${directory.path}/revisions/${child.revisionId}.json',
        );
        final descendantManifest = File(
          '${directory.path}/revisions/${descendant.revisionId}.json',
        );
        final childBytes = await childManifest.readAsBytes();
        final descendantBytes = await descendantManifest.readAsBytes();
        if (missing) {
          await manifest().delete();
        } else {
          await manifest().writeAsString('{', flush: true);
        }
        await expectLater(
          repository.confirmPublishedCommit(prepared),
          throwsA(anyOf(isA<FileSystemException>(), isA<FormatException>())),
        );
        final next = repository.prepareCommit(
          entityId: descendant.entityId,
          kind: descendant.kind,
          files: {
            'summary.md': Uint8List.fromList([24]),
          },
          parentRevisionIds: [descendant.revisionId],
        );
        await expectLater(
          repository.commitPreparedIfHeads(
            next,
            expectedHeads: {
              descendant.entityId: [descendant.revisionId],
            },
          ),
          throwsA(anyOf(isA<StateError>(), isA<FormatException>())),
        );
        expect(await repository.heads(prepared.record.entityId), isEmpty);
        expect((await repository.revisions()).map((r) => r.revisionId), [
          healthy.revisionId,
        ]);
        expect(
          (await repository.heads(healthy.entityId)).single.revisionId,
          healthy.revisionId,
        );
        expect(
          File('${directory.path}/revisions/${next.record.revisionId}.json')
              .existsSync(),
          isFalse,
        );
        expect(await childManifest.readAsBytes(), childBytes);
        expect(await descendantManifest.readAsBytes(), descendantBytes);
        if (missing) {
          expect(manifest().existsSync(), isFalse);
        } else {
          expect(await manifest().readAsString(), '{');
        }
        await repository.close();
        repository = await NoteRepository.open(directory);
        expect(await repository.heads(prepared.record.entityId), isEmpty);
        expect((await repository.revisions()).map((r) => r.revisionId), [
          healthy.revisionId,
        ]);
        expect(await childManifest.readAsBytes(), childBytes);
        expect(await descendantManifest.readAsBytes(), descendantBytes);
      },
    );
  }
  test(
    'foreign root and closed repository cannot confirm a prepared record',
    () async {
      await stage();
      final foreign = await NoteRepository.open(
        Directory('${directory.path}/other'),
        vaultId: repository.vaultId,
        deviceId: repository.deviceId,
      );
      try {
        await expectLater(
          foreign.confirmPublishedCommit(prepared),
          throwsFormatException,
        );
      } finally {
        await foreign.close();
      }
      await repository.close();
      await expectLater(
        repository.confirmPublishedCommit(prepared),
        throwsStateError,
      );
    },
  );
}
