import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/vault/note_page_marks.dart';
import 'package:saber/data/vault/note_side_store.dart';
import 'package:saber/data/vault/workspace_store.dart';

DateTime at(int hour) => DateTime.utc(2026, 11, 27, hour);

Map<String, dynamic> raw(NotePageMarks marks) =>
    jsonDecode(utf8.decode(marks.encode())) as Map<String, dynamic>;

NotePageMarks roundTrip(NotePageMarks marks) =>
    NotePageMarks.decode(marks.encode());

void main() {
  test('favorites add and remove with a deletion mark', () {
    final marks = NotePageMarks()
      ..addFavorite('page-1', at: at(1))
      ..addFavorite('page-2', at: at(2))
      ..removeFavorite('page-1', at: at(3));
    expect(marks.favorites, ['page-2']);

    final reopened = roundTrip(marks);
    expect(reopened.favorites, ['page-2']);
    final rows = raw(marks)['favorites'] as List;
    expect(rows, hasLength(2));
    expect(
      rows.firstWhere((row) => row['pageId'] == 'page-1')['deleted'],
      true,
    );
    expect(raw(marks)['schemaVersion'], 1);
  });

  test('outline rows add, rename and delete', () {
    final marks = NotePageMarks();
    final added = marks.addOutline('page-1', 'Intro', at: at(1));
    expect(added.createdAt, at(1));
    expect(added.updatedAt, at(1));
    expect(added.deleted, isFalse);

    marks.renameOutline(added.id, 'Introduction', at: at(2));
    var row = roundTrip(marks).outline.single;
    expect(row.id, added.id);
    expect(row.pageId, 'page-1');
    expect(row.title, 'Introduction');
    expect(row.createdAt, at(1));
    expect(row.updatedAt, at(2));

    marks.removeOutline(added.id, at: at(3));
    row = roundTrip(marks).outline.single;
    expect(row.deleted, isTrue);
    expect(row.updatedAt, at(3));
    expect(row.title, 'Introduction');
  });

  test('PDF outline edits are keyed by page, depth and original title', () {
    final marks = NotePageMarks()
      ..editPdfOutline(
        OutlineRename(
          pageId: 'page-1',
          depth: 0,
          originalTitle: 'Chapter 1',
          title: 'Basics',
          updatedAt: at(1),
        ),
      )
      ..editPdfOutline(
        OutlineRename(
          pageId: 'page-1',
          depth: 1,
          originalTitle: 'Chapter 1',
          hidden: true,
          updatedAt: at(1),
        ),
      )
      ..editPdfOutline(
        OutlineRename(
          pageId: 'page-1',
          depth: 0,
          originalTitle: 'Chapter 1',
          title: 'Fundamentals',
          updatedAt: at(2),
        ),
      );
    final edits = roundTrip(marks).pdfOutlineEdits;
    expect(edits, hasLength(2));
    final top = edits.singleWhere((edit) => edit.depth == 0);
    expect(top.title, 'Fundamentals');
    expect(top.hidden, isFalse);
    expect(top.updatedAt, at(2));
    final hidden = edits.singleWhere((edit) => edit.depth == 1);
    expect(hidden.title, isNull);
    expect(hidden.hidden, isTrue);
  });

  test('unknown keys survive decode and encode', () {
    final bytes = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'schemaVersion': 1,
          'futureTopLevel': {'kept': true},
          'favorites': [
            {
              'pageId': 'page-1',
              'updatedAt': at(1).toIso8601String(),
              'deleted': false,
              'colour': 'red',
            },
          ],
          'outline': [
            {
              'id': 'row-1',
              'pageId': 'page-1',
              'title': 'Intro',
              'createdAt': at(1).toIso8601String(),
              'updatedAt': at(1).toIso8601String(),
              'deleted': false,
              'icon': 'star',
            },
          ],
          'pdfOutlineEdits': [
            {
              'pageId': 'page-1',
              'depth': 0,
              'originalTitle': 'Chapter 1',
              'title': null,
              'hidden': true,
              'updatedAt': at(1).toIso8601String(),
              'note': 'x',
            },
          ],
        }),
      ),
    );
    final marks = NotePageMarks.decode(bytes)
      ..renameOutline('row-1', 'Introduction', at: at(2));
    final out = raw(marks);
    expect(out['futureTopLevel'], {'kept': true});
    expect((out['favorites'] as List).single['colour'], 'red');
    final row = (out['outline'] as List).single;
    expect(row['icon'], 'star');
    expect(row['title'], 'Introduction');
    expect((out['pdfOutlineEdits'] as List).single['note'], 'x');
  });

  test('decode rejects another schema version', () {
    expect(
      () => NotePageMarks.decode(
        Uint8List.fromList(utf8.encode(jsonEncode({'schemaVersion': 2}))),
      ),
      throwsFormatException,
    );
  });

  test('merge keeps the later outline row by id', () {
    final base = NotePageMarks();
    final kept = base.addOutline('page-1', 'Intro', at: at(1));
    final gone = base.addOutline('page-2', 'Method', at: at(1));
    final left = roundTrip(base)
      ..renameOutline(kept.id, 'Left title', at: at(3))
      ..renameOutline(gone.id, 'Renamed first', at: at(2));
    final right = roundTrip(base)
      ..renameOutline(kept.id, 'Right title', at: at(2))
      ..removeOutline(gone.id, at: at(4))
      ..addOutline('page-3', 'Results', at: at(5));

    final merged = NotePageMarks.merge([left, right]);
    expect(merged.outline, hasLength(3));
    expect(
      merged.outline.singleWhere((r) => r.id == kept.id).title,
      'Left title',
    );
    final removed = merged.outline.singleWhere((r) => r.id == gone.id);
    expect(removed.deleted, isTrue);
    expect(merged.outline.where((r) => !r.deleted).map((r) => r.title), [
      'Left title',
      'Results',
    ]);
    // The order of the inputs does not change the result.
    expect(NotePageMarks.merge([right, left]).encode(), merged.encode());
  });

  test('favorites merge as a union that honours deletion marks', () {
    final left = NotePageMarks()
      ..addFavorite('page-1', at: at(1))
      ..addFavorite('page-3', at: at(1))
      ..removeFavorite('page-3', at: at(4))
      ..addFavorite('page-4', at: at(1))
      ..removeFavorite('page-4', at: at(2));
    final right = NotePageMarks()
      ..addFavorite('page-2', at: at(1))
      ..addFavorite('page-3', at: at(3))
      ..addFavorite('page-4', at: at(3));
    final merged = NotePageMarks.merge([left, right]);
    expect(merged.favorites, unorderedEquals(['page-1', 'page-2', 'page-4']));
  });

  test('live outline leaves out deleted rows and restore brings one back', () {
    final marks = NotePageMarks();
    final kept = marks.addOutline('page-1', 'Intro', at: at(1));
    final undone = marks.addOutline('page-2', 'Method', at: at(1));
    marks.removeOutline(undone.id, at: at(2));
    expect(marks.outline, hasLength(2));
    expect(marks.liveOutline.map((row) => row.id), [kept.id]);

    final beforeRestore = roundTrip(marks);
    marks.restoreOutline(undone.id, at: at(3));
    final restored = roundTrip(marks).liveOutline
        .singleWhere((row) => row.id == undone.id);
    expect(restored.deleted, isFalse);
    expect(restored.updatedAt, at(3));
    expect(restored.title, 'Method');
    // The restore is later than the deletion, so it survives a merge with it.
    for (final order in [
      [marks, beforeRestore],
      [beforeRestore, marks],
    ]) {
      expect(
        NotePageMarks.merge(order).liveOutline.map((row) => row.id),
        unorderedEquals([kept.id, undone.id]),
      );
    }
  });

  test('PDF outline edits are stored in UTC', () {
    final local = DateTime(2026, 11, 27, 9, 30);
    final marks = NotePageMarks()
      ..editPdfOutline(
        OutlineRename(
          pageId: 'page-1',
          depth: 0,
          originalTitle: 'Chapter 1',
          title: 'Basics',
          updatedAt: local,
        ),
      );
    final edit = marks.pdfOutlineEdits.single;
    expect(edit.updatedAt.isUtc, isTrue);
    expect(edit.updatedAt, local.toUtc());
    final stored = (raw(marks)['pdfOutlineEdits'] as List).single;
    expect(stored['updatedAt'], endsWith('Z'));
  });

  test('merge picks unknown top-level values regardless of input order', () {
    NotePageMarks withExtra(Object value) => NotePageMarks.decode(
      Uint8List.fromList(
        utf8.encode(jsonEncode({'schemaVersion': 1, 'future': value})),
      ),
    );
    final a = withExtra({'n': 1});
    final b = withExtra({'n': 2});
    final ab = NotePageMarks.merge([a, b]).encode();
    final ba = NotePageMarks.merge([b, a]).encode();
    expect(ab, ba);
    expect(raw(NotePageMarks.decode(ab))['future'], anyOf({'n': 1}, {'n': 2}));
  });

  test('merge compares unknown values by content, not key order', () {
    NotePageMarks withExtra(String value) => NotePageMarks.decode(
      Uint8List.fromList(utf8.encode('{"schemaVersion": 1, "future": $value}')),
    );
    // As written, {"b":1,"a":1} sorts after {"a":2,"b":1} though its content
    // is the smaller one.
    final larger = withExtra('{"a": 2, "b": {"y": 1, "x": 1}}');
    final smaller = withExtra('{"b": {"x": 1, "y": 1}, "a": 1}');
    for (final inputs in [
      [larger, smaller],
      [smaller, larger],
    ]) {
      expect(raw(NotePageMarks.merge(inputs))['future'], {
        'a': 2,
        'b': {'x': 1, 'y': 1},
      });
    }
    // The same content in two key orders gives the same bytes either way.
    final x = withExtra('{"a": 1, "b": 2}');
    final y = withExtra('{"b": 2, "a": 1}');
    expect(
      NotePageMarks.merge([x, y]).encode(),
      NotePageMarks.merge([y, x]).encode(),
    );
  });

  test('a deletion wins over a rename at the same time', () {
    final start = NotePageMarks();
    final row = start.addOutline('page-1', 'Intro', at: at(1));
    final renamed = roundTrip(start)
      ..renameOutline(row.id, 'Introduction', at: at(2));
    final deleted = roundTrip(start)..removeOutline(row.id, at: at(2));
    for (final order in [
      [renamed, deleted],
      [deleted, renamed],
    ]) {
      final merged = NotePageMarks.merge(order);
      expect(merged.outline.single.deleted, isTrue);
      expect(merged.liveOutline, isEmpty);
    }
  });

  group('with a vault', () {
    late Directory temp;
    late NoteRepository repository;
    setUp(() async {
      temp = await Directory.systemTemp.createTemp('piv-page-marks-');
      repository = await NoteRepository.open(
        Directory('${temp.path}/vault'),
        createFormatVersion: 2,
      );
    });
    tearDown(() async {
      await repository.close().timeout(const Duration(seconds: 30));
      await temp.delete(recursive: true);
    });

    test('two heads are read, merged and written back as one', () async {
      final note = await WorkspaceStore(repository).create('Lecture');
      final side = NoteSideStore(repository);
      const kind = NoteSideKind.pageMarks;
      final start = NotePageMarks()..addFavorite('page-1', at: at(1));
      final first = await side.write(note.id, kind, {
        kind.markerFile: start.encode(),
      });
      // Two devices edit the marks offline; sync brings both heads together.
      for (final edit in <void Function(NotePageMarks)>[
        (marks) => marks.addFavorite('page-2', at: at(2)),
        (marks) => marks.addOutline('page-3', 'Results', at: at(3)),
      ]) {
        final marks = roundTrip(start);
        edit(marks);
        await repository.commit(
          entityId: first.entityId,
          kind: EntityKind.attachment,
          ownerNoteId: note.id,
          files: {kind.markerFile: marks.encode()},
          parentRevisionIds: [first.revisionId],
        );
      }

      final split = (await side.list(note.id, kind)).single;
      expect(split.heads, hasLength(2));
      final merged = NotePageMarks.merge([
        for (final head in split.heads)
          NotePageMarks.decode(
            (await repository.readFiles(head))[kind.markerFile]!,
          ),
      ]);
      await side.write(note.id, kind, {
        kind.markerFile: merged.encode(),
      }, base: split);

      final joined = (await side.list(note.id, kind)).single;
      expect(joined.heads, hasLength(1));
      expect(
        joined.heads.single.parentRevisionIds,
        unorderedEquals([for (final head in split.heads) head.revisionId]),
      );
      final reopened = NotePageMarks.decode(
        (await side.read(joined))[kind.markerFile]!,
      );
      expect(reopened.favorites, unorderedEquals(['page-1', 'page-2']));
      expect(reopened.outline.single.title, 'Results');
    });
  });
}
