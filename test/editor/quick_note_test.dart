import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:bson/bson.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:logging/logging.dart';
import 'package:perfect_freehand/perfect_freehand.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/editor/quick_note.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/tools/pen.dart';
import 'package:saber/data/tools/stroke_properties.dart';
import 'package:saber/data/vault/note_side_store.dart';
import 'package:saber/data/vault/workspace_store.dart';

const _kind = NoteSideKind.quickNote;

/// Long enough that only [QuickNote.flush] saves in these tests.
const _noTimer = Duration(hours: 1);

Pen _pen({Color color = Colors.black, double stabiliser = 0}) => Pen(
  name: 'test',
  sizeMin: 1,
  sizeMax: 25,
  sizeStep: 1,
  icon: Pen.ballpointPenIcon,
  options: StrokeOptions(size: 5, streamline: stabiliser),
  pressureEnabled: false,
  color: color,
  toolId: .ballpointPen,
);

/// Whole page units, so the points survive the 32-bit save unchanged.
List<Offset> _line(double x, double y) => [
  for (var i = 0; i <= 10; i++) Offset(x + 10.0 * i, y),
];

void _draw(QuickNote quick, List<Offset> points, {Pen? pen}) {
  quick.penDown(points.first, pen ?? _pen(), null);
  for (final point in points.skip(1)) {
    quick.penMove(point, null);
  }
  quick.penUp();
}

/// Where each stroke on the page starts; a stroke that came in twice shows
/// twice.
List<Offset> _starts(EditorCoreInfo core) => [
  for (final stroke in core.pages.single.strokes)
    Offset(stroke.points.first.x, stroke.points.first.y),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();
  StrokeOptionsExtension.setDefaults();
  late Directory temp;
  late NoteRepository repository;
  late WorkspaceStore workspace;
  late NoteSideStore store;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('piv-quick-note-');
    repository = await NoteRepository.open(
      Directory('${temp.path}/vault'),
      createFormatVersion: 2,
    );
    workspace = WorkspaceStore(repository);
    store = NoteSideStore(repository);
    await FileManager.init(
      documentsDirectory: '${temp.path}/working',
      shouldWatchRootDirectory: false,
    );
  });
  tearDown(() async {
    Pen.currentStroke = null;
    await repository.close().timeout(const Duration(seconds: 30));
    await temp.delete(recursive: true);
  });

  Future<QuickNote> open(String noteId) async {
    final quick = await QuickNote.open(store, noteId, saveDelay: _noTimer);
    addTearDown(quick.dispose);
    return quick;
  }

  Future<Uint8List> sbnOf(RevisionRecord head) =>
      repository.readRevisionFile(head, 'quick-note.sbn2');

  /// The quick note files another device would write: [sbn] as it read it,
  /// with one more stroke along each of [lines]; with [version], the page is
  /// marked as written by an app of that note version.
  Future<Map<String, Uint8List>> withStrokes(
    Uint8List? sbn,
    List<List<Offset>> lines, {
    int? version,
  }) async {
    final core = sbn == null
        ? (EditorCoreInfo(filePath: '/remote')..pages.add(EditorPage()))
        : await EditorCoreInfo.loadFromFileContents(
            bsonBytes: sbn,
            path: '/remote',
            onlyFirstPage: true,
          );
    final page = core.pages.single;
    for (final points in lines) {
      final stroke = _pen().createStroke(page, 0);
      for (final point in points) {
        stroke.addPoint(point);
      }
      stroke.options.isComplete = true;
      page.insertStroke(stroke);
    }
    final (json, _) = core.toJson();
    core.dispose();
    if (version != null) json['v'] = version;
    return {
      _kind.markerFile: Uint8List.fromList(
        utf8.encode(jsonEncode({'schemaVersion': 1})),
      ),
      'quick-note.sbn2': BsonCodec.serialize(json).byteList,
    };
  }

  Future<Map<String, Uint8List>> withStroke(
    Uint8List? sbn,
    List<Offset> points, {
    int? version,
  }) => withStrokes(sbn, [points], version: version);

  /// The quick note attachments [noteId] has, live or not.
  Future<Set<String>> entities(String noteId) async => {
    for (final r in await repository.revisions())
      if (r.ownerNoteId == noteId && r.blobs.containsKey(_kind.markerFile))
        r.entityId,
  };

  Future<int> strokeCount(RevisionRecord head) async {
    final bson = BsonCodec.deserialize(BsonBinary.from(await sbnOf(head)));
    final page = (bson['z'] as List).single as Map;
    return (page['s'] as List?)?.length ?? 0;
  }

  test('Pen.createStroke starts the stroke onDragStart starts', () {
    final pen = _pen(color: Colors.teal, stabiliser: 0.5);
    final page = EditorPage();
    final made = pen.createStroke(page, 3, screenScale: 2);
    expect(Pen.currentStroke, isNull);

    pen.onDragStart(_line(0, 0).first, page, 3, null, screenScale: 2);
    final started = Pen.currentStroke!;
    for (final point in _line(0, 0).skip(1)) {
      pen.onDragUpdate(point, null);
    }
    for (final point in _line(0, 0)) {
      made.addPoint(point);
    }
    expect(made.color, started.color);
    expect(made.toolId, started.toolId);
    expect(made.pageIndex, 3);
    expect(made.page, same(page));
    expect(made.options.toJson(), started.options.toJson());
    // The same stabiliser: the same points come out.
    expect(
      [for (final p in made.points) Offset(p.x, p.y)],
      [for (final p in started.points) Offset(p.x, p.y)],
    );
    pen.onDragEnd();
  });

  test('quick note stroke never touches Pen.currentStroke', () async {
    final note = await workspace.create('Lecture');
    final quick = await open(note.id);
    // The document is in the middle of a stroke of its own.
    final documentPage = EditorPage();
    final documentStroke = _pen().createStroke(documentPage, 0);
    Pen.currentStroke = documentStroke;

    quick.penDown(const Offset(10, 10), _pen(), null);
    expect(Pen.currentStroke, same(documentStroke));
    expect(quick.currentStroke.value, isNotNull);
    expect(quick.currentStroke.value!.pageIndex, 0);
    expect(quick.currentStroke.value!.page, same(quick.core.pages.single));
    quick.penMove(const Offset(20, 20), null);
    expect(Pen.currentStroke, same(documentStroke));
    expect(documentStroke.points, isEmpty);
    quick.penUp();
    expect(Pen.currentStroke, same(documentStroke));
    expect(quick.currentStroke.value, isNull);
    expect(quick.core.pages.single.strokes, hasLength(1));

    // With no document stroke going on, none appears.
    Pen.currentStroke = null;
    _draw(quick, _line(0, 100));
    expect(Pen.currentStroke, isNull);
    expect(quick.core.pages.single.strokes, hasLength(2));
  });

  test('write, save, reopen gives same strokes', () async {
    final note = await workspace.create('Lecture');
    final quick = await open(note.id);
    expect(quick.core.pages, hasLength(1));
    expect(quick.core.pages.single.size, EditorPage.defaultSize);
    _draw(quick, _line(0, 0));
    _draw(quick, _line(0, 50), pen: _pen(color: Colors.red));
    expect(quick.hasUnsavedChanges, isTrue);
    await quick.flush();
    expect(quick.hasUnsavedChanges, isFalse);

    final record = (await store.list(note.id, _kind)).single;
    final files = await store.read(record);
    expect(files.keys, unorderedEquals([_kind.markerFile, 'quick-note.sbn2']));
    final marker = jsonDecode(utf8.decode(files[_kind.markerFile]!)) as Map;
    expect(marker['schemaVersion'], 1);
    final bson = BsonCodec.deserialize(
      BsonBinary.from(files['quick-note.sbn2']!),
    );
    expect(bson['v'], 19);
    expect(bson['z'], hasLength(1));

    // Nothing new: no new revision.
    final revisions = (await repository.revisions()).length;
    await quick.flush();
    expect((await repository.revisions()).length, revisions);

    final reopened = await open(note.id);
    expect(reopened.core.pages, hasLength(1));
    final before = quick.core.pages.single.strokes;
    final after = reopened.core.pages.single.strokes;
    expect(after, hasLength(2));
    for (var i = 0; i < before.length; i++) {
      expect(after[i].color.toARGB32(), before[i].color.toARGB32());
      expect(
        [for (final p in after[i].points) Offset(p.x, p.y)],
        [for (final p in before[i].points) Offset(p.x, p.y)],
      );
    }
  });

  test('undo is separate from document history', () async {
    final note = await workspace.create('Lecture');
    // The document has a stroke.
    final document = EditorCoreInfo(filePath: '/doc')..pages.add(EditorPage());
    addTearDown(document.dispose);
    final pen = _pen();
    pen.onDragStart(const Offset(5, 5), document.pages.single, 0, null);
    pen.onDragUpdate(const Offset(50, 5), null);
    final documentStroke = pen.onDragEnd()!;
    document.pages.single.insertStroke(documentStroke);

    final quick = await open(note.id);
    expect(quick.history.canUndo, isFalse);
    _draw(quick, _line(0, 0));
    _draw(quick, _line(0, 50));
    expect(quick.history.canUndo, isTrue);

    quick.undo();
    expect(_starts(quick.core), [Offset.zero]);
    expect(quick.history.canRedo, isTrue);
    expect(document.pages.single.strokes, [documentStroke]);
    quick.redo();
    expect(
      _starts(quick.core),
      unorderedEquals(const [Offset.zero, Offset(0, 50)]),
    );

    // The eraser rubs out whole strokes, one undo step per touch.
    quick.eraseAt(const Offset(50, 0));
    quick.eraseAt(const Offset(50, 50));
    quick.penUp();
    expect(quick.core.pages.single.strokes, isEmpty);
    quick.undo();
    expect(quick.core.pages.single.strokes, hasLength(2));
    expect(document.pages.single.strokes, [documentStroke]);
    // The note's eraser and history are the editor's own; the quick note is
    // never given them. That the window's 실행 취소 leaves the note alone is
    // quick_note_window_test 「실행 취소 takes back the quick note's strokes」.
  });

  test('two heads merge strokes', () async {
    final note = await workspace.create('Lecture');
    final quick = await open(note.id);
    _draw(quick, _line(0, 0));
    await quick.flush();
    quick.dispose();
    final first = (await store.list(note.id, _kind)).single;
    final shared = await sbnOf(first.heads.single);

    // Two devices added a stroke each to the same quick note offline.
    final branches = <String>[];
    for (final y in [100.0, 200.0]) {
      final record = await repository.commit(
        entityId: first.entityId,
        kind: EntityKind.attachment,
        ownerNoteId: note.id,
        files: await withStroke(shared, _line(0, y)),
        parentRevisionIds: [first.revisionId],
      );
      branches.add(record.revisionId);
    }
    // A third device never saw it and made its own quick note for the note
    // (the largest id, so the first one is kept).
    await repository.commit(
      entityId: 'ffffffff-ffff-4fff-bfff-ffffffffffff',
      kind: EntityKind.attachment,
      ownerNoteId: note.id,
      files: await withStroke(null, _line(0, 300)),
      parentRevisionIds: [],
    );
    final split = await store.list(note.id, _kind);
    expect(split, hasLength(2));
    expect(
      split.singleWhere((r) => r.entityId == first.entityId).heads,
      hasLength(2),
    );

    final merged = await open(note.id);
    // The stroke every head of the first quick note holds comes in once.
    expect(
      _starts(merged.core),
      unorderedEquals(const [
        Offset.zero,
        Offset(0, 100),
        Offset(0, 200),
        Offset(0, 300),
      ]),
    );
    // Joining is a change to save.
    expect(merged.hasUnsavedChanges, isTrue);
    await merged.flush();

    // The first quick note by id holds the strokes, written over the heads it
    // read. The other one gets an empty page, not a deletion mark, and stays
    // listed.
    final kept = split.first;
    final other = split.singleWhere((r) => r.entityId != kept.entityId);
    final after = await store.list(note.id, _kind);
    expect(after.map((r) => r.entityId), [kept.entityId, other.entityId]);
    final joined = after.first;
    expect(joined.heads, hasLength(1));
    expect(
      joined.heads.single.parentRevisionIds,
      unorderedEquals([for (final head in kept.heads) head.revisionId]),
    );
    expect(await strokeCount(joined.heads.single), 4);
    final emptied = after.last.heads.single;
    expect(emptied.parentRevisionIds, [other.revisionId]);
    expect(await strokeCount(emptied), 0);

    // The joined strokes, saved and read back in another head, still come in
    // once: sync brings a stroke drawn on top of the joined page.
    var arrivals = 0;
    store.beforeCommit = () async {
      if (arrivals++ > 0) return;
      await repository.commit(
        entityId: kept.entityId,
        kind: EntityKind.attachment,
        ownerNoteId: note.id,
        files: await withStroke(
          await sbnOf(joined.heads.single),
          _line(0, 500),
        ),
        parentRevisionIds: [joined.revisionId],
      );
    };
    _draw(merged, _line(0, 600));
    await merged.flush();
    store.beforeCommit = null;
    const all = [
      Offset.zero,
      Offset(0, 100),
      Offset(0, 200),
      Offset(0, 300),
      Offset(0, 500),
      Offset(0, 600),
    ];
    expect(_starts(merged.core), unorderedEquals(all));
    merged.dispose();

    // Opening again writes nothing: one head, the other quick note empty.
    final reopened = await open(note.id);
    expect(_starts(reopened.core), unorderedEquals(all));
    expect(reopened.hasUnsavedChanges, isFalse);
    final revisions = (await repository.revisions()).length;
    await reopened.flush();
    expect((await repository.revisions()).length, revisions);
    reopened.dispose();

    // A device still offline on the other quick note's old head draws there;
    // the next open joins its stroke and empties that quick note again.
    await repository.commit(
      entityId: other.entityId,
      kind: EntityKind.attachment,
      ownerNoteId: note.id,
      files: await withStroke(await sbnOf(other.heads.single), _line(0, 400)),
      parentRevisionIds: [other.revisionId],
    );
    final again = await open(note.id);
    expect(
      _starts(again.core),
      unorderedEquals([...all, const Offset(0, 400)]),
    );
    expect(again.hasUnsavedChanges, isTrue);
    await again.flush();
    final settled = await store.list(note.id, _kind);
    expect(settled, hasLength(2));
    expect(await strokeCount(settled.first.heads.single), 7);
    expect(await strokeCount(settled.last.heads.single), 0);
    again.dispose();

    final last = await open(note.id);
    expect(_starts(last.core), unorderedEquals([...all, const Offset(0, 400)]));
    expect(last.hasUnsavedChanges, isFalse);
    final count = (await repository.revisions()).length;
    await last.flush();
    expect((await repository.revisions()).length, count);
  });

  test('identical strokes in one head both stay', () async {
    final note = await workspace.create('Lecture');
    // Two strokes with the same bytes (the same line drawn twice), and a
    // second head that has both and one more.
    final first = await repository.commit(
      entityId: newId(),
      kind: EntityKind.attachment,
      ownerNoteId: note.id,
      files: await withStrokes(null, [_line(0, 0), _line(0, 0)]),
      parentRevisionIds: [],
    );
    final quick = await open(note.id);
    expect(_starts(quick.core), const [Offset.zero, Offset.zero]);
    quick.dispose();
    await repository.commit(
      entityId: first.entityId,
      kind: EntityKind.attachment,
      ownerNoteId: note.id,
      files: await withStroke(await sbnOf(first), _line(0, 100)),
      parentRevisionIds: [first.revisionId],
    );
    await repository.commit(
      entityId: first.entityId,
      kind: EntityKind.attachment,
      ownerNoteId: note.id,
      files: await withStroke(await sbnOf(first), _line(0, 200)),
      parentRevisionIds: [first.revisionId],
    );
    final joined = await open(note.id);
    expect(
      _starts(joined.core),
      unorderedEquals(const [
        Offset.zero,
        Offset.zero,
        Offset(0, 100),
        Offset(0, 200),
      ]),
    );
  });

  test('a head that arrives while saving is merged, not lost', () async {
    final note = await workspace.create('Lecture');
    final quick = await open(note.id);
    _draw(quick, _line(0, 0));
    _draw(quick, _line(0, 50));
    await quick.flush();
    final seen = (await store.list(note.id, _kind)).single;
    final shared = await sbnOf(seen.heads.single);

    // Here the first stroke is rubbed out and a new one drawn; meanwhile sync
    // brings another device's stroke on top of what was saved.
    quick.eraseAt(const Offset(50, 0));
    quick.penUp();
    _draw(quick, _line(0, 150));
    var arrivals = 0;
    store.beforeCommit = () async {
      if (arrivals++ > 0) return;
      await repository.commit(
        entityId: seen.entityId,
        kind: EntityKind.attachment,
        ownerNoteId: note.id,
        files: await withStroke(shared, _line(0, 100)),
        parentRevisionIds: [seen.revisionId],
      );
    };
    await quick.flush();
    store.beforeCommit = null;

    expect(quick.hasUnsavedChanges, isFalse);
    // The remote stroke joins; the stroke rubbed out here stays gone.
    expect(
      _starts(quick.core),
      unorderedEquals(const [Offset(0, 50), Offset(0, 100), Offset(0, 150)]),
    );
    final saved = (await store.list(note.id, _kind)).single;
    expect(saved.entityId, seen.entityId);
    expect(saved.heads, hasLength(1));
    final reopened = await open(note.id);
    expect(_starts(reopened.core), unorderedEquals(_starts(quick.core)));
  });

  test('a quick note that keeps refusing writes moves to a new one', () async {
    final note = await workspace.create('Lecture');
    // The smallest id, so an open that does not leave it out picks it first.
    final seen = await repository.commit(
      entityId: '00000000-0000-4000-8000-000000000001',
      kind: EntityKind.attachment,
      ownerNoteId: note.id,
      files: await withStroke(null, _line(0, 0)),
      parentRevisionIds: [],
    );
    final quick = await open(note.id);
    expect(_starts(quick.core), [Offset.zero]);
    final shared = await sbnOf(seen);
    // Two heads arrive; a newer app wrote one of them (marker schema 2), so
    // the list leaves it out and every write guarded by the listed heads
    // fails.
    await repository.commit(
      entityId: seen.entityId,
      kind: EntityKind.attachment,
      ownerNoteId: note.id,
      files: await withStroke(shared, _line(0, 100)),
      parentRevisionIds: [seen.revisionId],
    );
    await repository.commit(
      entityId: seen.entityId,
      kind: EntityKind.attachment,
      ownerNoteId: note.id,
      files: {
        ...await withStroke(shared, _line(0, 200)),
        _kind.markerFile: Uint8List.fromList(
          utf8.encode(jsonEncode({'schemaVersion': 2})),
        ),
      },
      parentRevisionIds: [seen.revisionId],
    );
    expect((await store.list(note.id, _kind)).single.heads, hasLength(1));

    _draw(quick, _line(0, 50));
    await quick.flush();
    expect(quick.hasUnsavedChanges, isFalse);
    expect(
      _starts(quick.core),
      unorderedEquals(const [Offset.zero, Offset(0, 50), Offset(0, 100)]),
    );
    final listed = await store.list(note.id, _kind);
    final fresh = listed.singleWhere((r) => r.entityId != seen.entityId);
    expect(fresh.heads.single.parentRevisionIds, isEmpty);

    // The next save goes to the new quick note.
    _draw(quick, _line(0, 250));
    await quick.flush();
    expect(
      (await store.list(note.id, _kind))
          .singleWhere((r) => r.entityId == fresh.entityId)
          .heads
          .single
          .parentRevisionIds,
      [fresh.revisionId],
    );
    final reopened = await open(note.id);
    expect(
      _starts(reopened.core),
      unorderedEquals(const [
        Offset.zero,
        Offset(0, 50),
        Offset(0, 100),
        Offset(0, 250),
      ]),
    );

    // Opening again leaves the refusing quick note out: nothing to join, and
    // the next save goes to the new one without making a third.
    final before = await entities(note.id);
    expect(before, {seen.entityId, fresh.entityId});
    expect(reopened.hasUnsavedChanges, isFalse);
    _draw(reopened, _line(0, 300));
    await reopened.flush();
    expect(reopened.hasUnsavedChanges, isFalse);
    expect(await entities(note.id), before);
    expect(await repository.heads(seen.entityId), hasLength(2));
  });

  test('a head it cannot read arriving after the list moves the ink', () async {
    final note = await workspace.create('Lecture');
    final quick = await open(note.id);
    _draw(quick, _line(0, 0));
    await quick.flush();
    final seen = (await store.list(note.id, _kind)).single;
    final shared = await sbnOf(seen.heads.single);
    _draw(quick, _line(0, 50));
    // The first write meets a stroke from another device; the write after the
    // list meets a head a newer app wrote (marker schema 2).
    var arrivals = 0;
    store.beforeCommit = () async {
      final arrival = arrivals++;
      if (arrival > 1) return;
      final head = (await repository.heads(seen.entityId)).first;
      await repository.commit(
        entityId: seen.entityId,
        kind: EntityKind.attachment,
        ownerNoteId: note.id,
        files: {
          ...await withStroke(shared, _line(0, 100)),
          if (arrival == 1)
            _kind.markerFile: Uint8List.fromList(
              utf8.encode(jsonEncode({'schemaVersion': 2})),
            ),
        },
        parentRevisionIds: [head.revisionId],
      );
    };
    await quick.flush();
    store.beforeCommit = null;

    expect(quick.hasUnsavedChanges, isFalse);
    expect(
      _starts(quick.core),
      unorderedEquals(const [Offset.zero, Offset(0, 50), Offset(0, 100)]),
    );
    final fresh = (await store.list(
      note.id,
      _kind,
    )).singleWhere((r) => r.entityId != seen.entityId);
    expect(fresh.heads.single.parentRevisionIds, isEmpty);
    expect(await strokeCount(fresh.heads.single), 3);
    expect(await repository.heads(seen.entityId), hasLength(1));
  });

  test('a head from a newer app opens read-only', () async {
    final note = await workspace.create('Lecture');
    await repository.commit(
      entityId: newId(),
      kind: EntityKind.attachment,
      ownerNoteId: note.id,
      files: await withStroke(
        null,
        _line(0, 0),
        version: EditorCoreInfo.newestSbnVersion + 1,
      ),
      parentRevisionIds: [],
    );
    final revisions = (await repository.revisions()).length;
    final quick = await open(note.id);
    expect(quick.readOnly, isTrue);
    expect(_starts(quick.core), [Offset.zero]);
    quick.penDown(const Offset(10, 300), _pen(), null);
    expect(quick.currentStroke.value, isNull);
    quick.penUp();
    quick.eraseAt(const Offset(50, 0));
    quick.penUp();
    quick.clear();
    expect(_starts(quick.core), [Offset.zero]);
    await quick.flush();
    expect((await repository.revisions()).length, revisions);
  });

  test('a head from a newer app that arrives while saving is kept', () async {
    final note = await workspace.create('Lecture');
    final quick = await open(note.id);
    _draw(quick, _line(0, 0));
    await quick.flush();
    final seen = (await store.list(note.id, _kind)).single;
    final shared = await sbnOf(seen.heads.single);
    _draw(quick, _line(0, 50));
    late final RevisionRecord newer;
    var arrivals = 0;
    store.beforeCommit = () async {
      if (arrivals++ > 0) return;
      newer = await repository.commit(
        entityId: seen.entityId,
        kind: EntityKind.attachment,
        ownerNoteId: note.id,
        files: await withStroke(
          shared,
          _line(0, 100),
          version: EditorCoreInfo.newestSbnVersion + 1,
        ),
        parentRevisionIds: [seen.revisionId],
      );
    };
    await quick.flush();
    store.beforeCommit = null;

    // Nothing is written over the newer head; the ink drawn here stays in
    // memory.
    expect(quick.readOnly, isTrue);
    expect(quick.hasUnsavedChanges, isTrue);
    expect((await repository.heads(seen.entityId)).map((h) => h.revisionId), [
      newer.revisionId,
    ]);
    expect(await entities(note.id), {seen.entityId});
    expect(
      _starts(quick.core),
      unorderedEquals(const [Offset.zero, Offset(0, 50), Offset(0, 100)]),
    );
  });

  test('disposing with unsaved ink logs a warning', () async {
    final note = await workspace.create('Lecture');
    final records = <LogRecord>[];
    final listening = Logger.root.onRecord.listen(records.add);
    addTearDown(listening.cancel);
    final quick = await open(note.id);
    _draw(quick, _line(0, 0));
    quick.dispose();
    expect(
      records.where(
        (r) => r.loggerName == 'QuickNote' && r.level == Level.WARNING,
      ),
      hasLength(1),
    );

    // Saved first, it closes without a word.
    records.clear();
    final saved = await open(note.id);
    _draw(saved, _line(0, 50));
    await saved.flush();
    expect(saved.hasUnsavedChanges, isFalse);
    saved.dispose();
    expect(records.where((r) => r.loggerName == 'QuickNote'), isEmpty);
  });

  test('saveState tells when unsaved or read-only changes', () async {
    final note = await workspace.create('Lecture');
    final quick = await open(note.id);
    final heard = <(bool, bool)>[];
    quick.saveState.addListener(
      () => heard.add((quick.hasUnsavedChanges, quick.readOnly)),
    );
    _draw(quick, _line(0, 0));
    // A second stroke is still unsaved: nothing new to tell.
    _draw(quick, _line(0, 50));
    expect(heard, [(true, false)]);
    await quick.flush();
    expect(heard, [(true, false), (false, false)]);

    // A head from a newer app arrives while it saves: the ink stays unsaved,
    // and it is told that it became read-only.
    final seen = (await store.list(note.id, _kind)).single;
    final shared = await sbnOf(seen.heads.single);
    _draw(quick, _line(0, 100));
    var arrivals = 0;
    store.beforeCommit = () async {
      if (arrivals++ > 0) return;
      await repository.commit(
        entityId: seen.entityId,
        kind: EntityKind.attachment,
        ownerNoteId: note.id,
        files: await withStroke(
          shared,
          _line(0, 200),
          version: EditorCoreInfo.newestSbnVersion + 1,
        ),
        parentRevisionIds: [seen.revisionId],
      );
    };
    await quick.flush();
    store.beforeCommit = null;
    expect(quick.readOnly, isTrue);
    expect(heard, [(true, false), (false, false), (true, false), (true, true)]);
  });

  test(
    'a head arriving on the other quick note while it is emptied stays',
    () async {
      final note = await workspace.create('Lecture');
      // Two devices each made the note's first quick note offline.
      final kept = await repository.commit(
        entityId: '00000000-0000-4000-8000-000000000001',
        kind: EntityKind.attachment,
        ownerNoteId: note.id,
        files: await withStroke(null, _line(0, 0)),
        parentRevisionIds: [],
      );
      final other = await repository.commit(
        entityId: 'ffffffff-ffff-4fff-bfff-ffffffffffff',
        kind: EntityKind.attachment,
        ownerNoteId: note.id,
        files: await withStroke(null, _line(0, 100)),
        parentRevisionIds: [],
      );
      final quick = await open(note.id);
      expect(quick.hasUnsavedChanges, isTrue);
      // The second write empties the other one; just before it, sync brings a
      // stroke drawn there.
      late final RevisionRecord arrived;
      var commits = 0;
      store.beforeCommit = () async {
        if (++commits != 2) return;
        arrived = await repository.commit(
          entityId: other.entityId,
          kind: EntityKind.attachment,
          ownerNoteId: note.id,
          files: await withStroke(await sbnOf(other), _line(0, 300)),
          parentRevisionIds: [other.revisionId],
        );
      };
      await quick.flush();
      store.beforeCommit = null;

      // The save went through; the other one is not written over.
      expect(commits, 2);
      expect(quick.hasUnsavedChanges, isFalse);
      expect(
        (await repository.heads(other.entityId)).map((h) => h.revisionId),
        [arrived.revisionId],
      );
      expect(await strokeCount(arrived), 2);
      expect((await repository.heads(kept.entityId)).single.parentRevisionIds, [
        kept.revisionId,
      ]);
      // The next open joins the stroke that arrived.
      final reopened = await open(note.id);
      expect(
        _starts(reopened.core),
        unorderedEquals(const [Offset.zero, Offset(0, 100), Offset(0, 300)]),
      );
    },
  );

  test(
    'emptying the other quick note failing does not fail the save',
    () async {
      final note = await workspace.create('Lecture');
      await repository.commit(
        entityId: '00000000-0000-4000-8000-000000000001',
        kind: EntityKind.attachment,
        ownerNoteId: note.id,
        files: await withStroke(null, _line(0, 0)),
        parentRevisionIds: [],
      );
      await repository.commit(
        entityId: 'ffffffff-ffff-4fff-bfff-ffffffffffff',
        kind: EntityKind.attachment,
        ownerNoteId: note.id,
        files: await withStroke(null, _line(0, 100)),
        parentRevisionIds: [],
      );
      final quick = await open(note.id);
      var commits = 0;
      store.beforeCommit = () async {
        if (++commits == 2) throw const FileSystemException('disk full');
      };
      await quick.flush();
      store.beforeCommit = null;
      expect(commits, 2);
      // The joined page was written: nothing is left to save, so the next
      // flush writes no copy of it.
      expect(quick.hasUnsavedChanges, isFalse);
      final revisions = (await repository.revisions()).length;
      await quick.flush();
      expect((await repository.revisions()).length, revisions);
    },
  );

  test('a note in the trash keeps the strokes until it can save', () async {
    final note = await workspace.create('Lecture');
    final quick = await open(note.id);
    await workspace.setDeleted(note, true);
    _draw(quick, _line(0, 0));
    await quick.flush();
    expect(quick.hasUnsavedChanges, isTrue);
    expect(_starts(quick.core), const [Offset.zero]);
    expect(await store.list(note.id, _kind), isEmpty);

    await workspace.setDeleted(
      (await workspace.list(includeDeleted: true)).single,
      false,
    );
    await quick.flush();
    expect(quick.hasUnsavedChanges, isFalse);
    final reopened = await open(note.id);
    expect(_starts(reopened.core), const [Offset.zero]);
  });

  test('clearing writes an empty page, not a deletion mark', () async {
    final note = await workspace.create('Lecture');
    final quick = await open(note.id);
    _draw(quick, _line(0, 0));
    await quick.flush();
    quick.clear();
    expect(quick.core.pages.single.strokes, isEmpty);
    await quick.flush();

    final record = (await store.list(note.id, _kind)).single;
    final files = await store.read(record);
    expect(
      jsonDecode(utf8.decode(files[_kind.markerFile]!)),
      isNot(containsPair('deleted', true)),
    );
    final reopened = await open(note.id);
    expect(reopened.core.pages.single.strokes, isEmpty);
    // Clearing is one undo step.
    quick.undo();
    expect(_starts(quick.core), const [Offset.zero]);
  });

  test('saves on its own after writing stops', () async {
    final note = await workspace.create('Lecture');
    final quick = await QuickNote.open(
      store,
      note.id,
      saveDelay: const Duration(milliseconds: 20),
    );
    addTearDown(quick.dispose);
    _draw(quick, _line(0, 0));
    for (var i = 0; i < 250; i++) {
      if ((await store.list(note.id, _kind)).isNotEmpty) break;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(await store.list(note.id, _kind), hasLength(1));
    await quick.flush();
    expect(quick.hasUnsavedChanges, isFalse);
  });
}
