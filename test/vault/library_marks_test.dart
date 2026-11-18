import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/vault/fork_merge.dart';
import 'package:saber/data/vault/library_marks.dart';
import 'package:saber/data/vault/workspace_bookmarks.dart';

void main() {
  late Directory temporary;
  late NoteRepository repository;
  late LibraryMarksStore store;

  setUp(() async {
    final owner = Directory.systemTemp;
    temporary = await owner.createTemp('piv-marks-');
    addTearDown(() async {
      final resolved = await temporary.resolveSymbolicLinks();
      expect(p.dirname(resolved), await owner.resolveSymbolicLinks());
      expect(p.basename(resolved), startsWith('piv-marks-'));
      await Directory(resolved).delete(recursive: true);
    });
    repository = await NoteRepository.open(
      Directory(p.join(temporary.path, 'first')),
      createFormatVersion: 2,
    );
    addTearDown(repository.close);
    store = LibraryMarksStore(repository);
  });

  test('marks round-trip through the vault and survive reopening', () async {
    const label = LibraryLabel(
      id: 'l1',
      name: '수업',
      color: 0xFFE53935,
      changedAt: 5,
    );
    final marks = LibraryMarks.empty
        .toggleFavorite('a')
        .togglePin('b')
        .putLabel(label)
        .setLabels('a', {'l1'})
        .setCover('b', 0xFF3949AB);
    await store.write(marks);
    await repository.close();

    final reopened = await NoteRepository.open(repository.root);
    addTearDown(reopened.close);
    final read = await LibraryMarksStore(reopened).read();
    expect(read.favorites, {'a'});
    expect(read.pinned, {'b'});
    expect(read.labels.single.id, 'l1');
    expect(read.labels.single.name, '수업');
    expect(read.labels.single.color, 0xFFE53935);
    expect(read.labelsOf, {
      'a': {'l1'},
    });
    expect(read.covers['b']!.color, 0xFF3949AB);
  });

  test('an empty vault reads as empty marks', () async {
    final read = await store.read();
    expect(read.favorites, isEmpty);
    expect(read.labels, isEmpty);
  });

  test('two marks heads merge and the next write resolves them', () async {
    final first = await store.write(LibraryMarks.empty.toggleFavorite('seed'));
    expect(first.favorites, {'seed'});
    final parent = (await repository.heads(LibraryMarksStore.entityId)).single;
    for (final id in ['a', 'c']) {
      final prepared = repository.prepareCommit(
        entityId: LibraryMarksStore.entityId,
        kind: EntityKind.attachment,
        files: {
          LibraryMarksStore.fileName: Uint8List.fromList(
            utf8.encode(
              jsonEncode({
                'version': 1,
                'favorites': [id],
                'pinned': <String>[],
                'labels': <Object>[],
                'labelsOf': <String, Object>{},
                'covers': <String, Object>{},
              }),
            ),
          ),
        },
        parentRevisionIds: [parent.revisionId],
      );
      await repository.commitPrepared(prepared);
    }
    expect((await repository.heads(LibraryMarksStore.entityId)).length, 2);
    final merged = await store.read();
    expect(merged.favorites, {'a', 'c'});
    await store.write(merged.toggleFavorite('a'));
    expect((await repository.heads(LibraryMarksStore.entityId)).length, 1);
    expect((await store.read()).favorites, {'c'});
  });

  test('a read that finds two heads writes the merge back over exactly '
      'those heads', () async {
    await store.write(LibraryMarks.empty.toggleFavorite('seed'));
    final parent = (await repository.heads(LibraryMarksStore.entityId)).single;
    for (final id in ['a', 'c']) {
      await repository.commitPrepared(
        repository.prepareCommit(
          entityId: LibraryMarksStore.entityId,
          kind: EntityKind.attachment,
          files: {
            LibraryMarksStore.fileName: Uint8List.fromList(
              utf8.encode(
                jsonEncode({
                  'version': 1,
                  'favorites': [id],
                  'pinned': <String>[],
                  'labels': <Object>[],
                  'labelsOf': <String, Object>{},
                  'covers': <String, Object>{},
                }),
              ),
            ),
          },
          parentRevisionIds: [parent.revisionId],
        ),
      );
    }
    final forked = await repository.heads(LibraryMarksStore.entityId);
    expect(forked, hasLength(2));
    final merged = await store.read();
    expect(merged.favorites, {'a', 'c'});
    // Queued before the read returned, so this call already sees it: the
    // top bar's cloud no longer finds a conflict.
    final heads = await repository.heads(LibraryMarksStore.entityId);
    expect(heads, hasLength(1));
    expect(
      heads.single.parentRevisionIds,
      unorderedEquals([for (final head in forked) head.revisionId]),
    );
    expect((await store.read()).favorites, {'a', 'c'});
  });

  test('a fork of two merges of the same heads is written back only by the '
      'device with the smallest id', () {
    const low = '00000000-0000-4000-8000-000000000001';
    const high = 'ffffffff-ffff-4fff-bfff-ffffffffffff';
    final vault = newId(), entity = newId(), a = newId(), b = newId();
    RevisionRecord head(String device, List<String> parents) => RevisionRecord(
      vaultId: vault,
      entityId: entity,
      kind: EntityKind.attachment,
      revisionId: newId(),
      parentRevisionIds: parents,
      deviceId: device,
      blobs: const {},
      formatVersion: 2,
    );

    // Two edits on two devices: either device writes the merge.
    final edits = [head(low, [a]), head(high, [b])];
    expect(writesMergeBack(edits, low), isTrue);
    expect(writesMergeBack(edits, high), isTrue);
    // Both devices merged a and b at once: only one merges the merges, so
    // the two never keep merging each other's merges.
    final merges = [head(low, [a, b]), head(high, [a, b])];
    expect(writesMergeBack(merges, low), isTrue);
    expect(writesMergeBack(merges, high), isFalse);
    // One head has nothing to merge.
    expect(writesMergeBack([head(high, [a])], high), isFalse);
  });

  test('marks do not show up as bookmarks', () async {
    await store.write(LibraryMarks.empty.toggleFavorite('a'));
    expect(await WorkspaceBookmarkStore(repository).list(), isEmpty);
  });

  test('removing a label removes its links', () {
    const label = LibraryLabel(id: 'l1', name: 'x', color: 1);
    final marks = LibraryMarks.empty
        .putLabel(label)
        .setLabels('a', {'l1'})
        .setLabels('b', {'l1'});
    final removed = marks.removeLabel('l1');
    expect(removed.labels, isEmpty);
    expect(removed.labelsOf, isEmpty);
  });

  test('merge keeps the newer label and cover per id', () {
    final a = LibraryMarks.empty
        .putLabel(
          const LibraryLabel(id: 'l', name: 'old', color: 1, changedAt: 1),
        )
        .setCover('n', 5);
    final b = LibraryMarks.empty
        .putLabel(
          const LibraryLabel(id: 'l', name: 'new', color: 2, changedAt: 9),
        )
        .toggleFavorite('f');
    final m = LibraryMarks.merge(a, b);
    expect(m.labels.single.name, 'new');
    expect(m.favorites, {'f'});
    expect(m.covers['n']!.color, 5);
  });

  test('the format cover is stored and merged like a colour', () async {
    final chosen = LibraryMarks.empty.setCover(
      'deck',
      LibraryMarks.formatCover,
    );
    await store.write(chosen);
    final head = (await repository.heads(LibraryMarksStore.entityId)).single;
    final json = jsonDecode(
      utf8.decode(
        await repository.readRevisionFile(head, LibraryMarksStore.fileName),
      ),
    ) as Map<String, dynamic>;
    // The same {color, changedAt} shape as a colour cover.
    expect(json['covers'], {
      'deck': {
        'color': LibraryMarks.formatCover,
        'changedAt': chosen.covers['deck']!.changedAt,
      },
    });
    expect(
      (await store.read()).covers['deck']!.color,
      LibraryMarks.formatCover,
    );
    // The later choice wins, whichever kind it is.
    LibraryMarks colour(int changedAt) => LibraryMarks(
      favorites: const {},
      pinned: const {},
      labels: const [],
      labelsOf: const {},
      covers: {'deck': (color: 0xFF3949AB, changedAt: changedAt)},
    );
    final at = chosen.covers['deck']!.changedAt;
    expect(
      LibraryMarks.merge(colour(at - 1), chosen).covers['deck']!.color,
      LibraryMarks.formatCover,
    );
    expect(
      LibraryMarks.merge(chosen, colour(at + 1)).covers['deck']!.color,
      0xFF3949AB,
    );
  });

  test('a format 1 vault cannot be written', () async {
    final old = await NoteRepository.open(
      Directory(p.join(temporary.path, 'old')),
    );
    addTearDown(old.close);
    expect(
      () => LibraryMarksStore(old).write(LibraryMarks.empty),
      throwsA(isA<StateError>()),
    );
  });
}
