import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/planner/planner_models.dart';
import 'package:saber/data/planner/planner_store.dart';

Uint8List _bytes(Object json) =>
    Uint8List.fromList(utf8.encode(jsonEncode(json)));

void main() {
  late Directory temporary;
  late NoteRepository repository;
  late PlannerStore store;

  setUp(() async {
    final owner = Directory.systemTemp;
    temporary = await owner.createTemp('piv-planner-');
    addTearDown(() async {
      final resolved = await temporary.resolveSymbolicLinks();
      expect(p.dirname(resolved), await owner.resolveSymbolicLinks());
      expect(p.basename(resolved), startsWith('piv-planner-'));
      await Directory(resolved).delete(recursive: true);
    });
    repository = await NoteRepository.open(
      Directory(p.join(temporary.path, 'first')),
      createFormatVersion: 2,
    );
    addTearDown(repository.close);
    store = PlannerStore(repository);
  });

  const stroke = InkStroke(
    points: [0.1, 0.2, 0.3, 0.4],
    color: 0xFF112233,
    width: 0.01,
  );

  test('the three entities round-trip and survive reopening', () async {
    const reminders = ReminderNote(
      items: [
        ReminderItem(
          id: 'r1',
          text: '약 먹기',
          at: null,
          repeat: ReminderRepeat.daily,
          done: true,
          order: 2,
          changedAt: 7,
        ),
      ],
      memo: [stroke],
      memoAspect: 1.5,
    );
    final events = [
      PlannerEvent(
        id: 'e1',
        title: '시험',
        start: DateTime(2026, 11, 20),
        end: DateTime(2026, 11, 21),
        color: 0xFF00FF00,
        calendarId: 'cal',
        googleId: 'g1',
        changedAt: 9,
      ),
    ];
    const ink = {
      '2026-11': MonthInk(month: '2026-11', strokes: [stroke]),
    };
    await store.writeReminders(reminders);
    await store.writeEvents(events);
    await store.writeInk(ink);
    await repository.close();

    final reopened = await NoteRepository.open(repository.root);
    addTearDown(reopened.close);
    final again = PlannerStore(reopened);
    final r = await again.readReminders();
    expect(r.items.single.text, '약 먹기');
    expect(r.items.single.repeat, ReminderRepeat.daily);
    expect(r.items.single.done, isTrue);
    expect(r.items.single.at, isNull);
    expect(r.memoAspect, 1.5);
    expect(r.memo.single.points, [0.1, 0.2, 0.3, 0.4]);
    expect(r.memo.single.color, 0xFF112233);
    final e = (await again.readEvents()).single;
    expect(e.title, '시험');
    expect(e.start, DateTime(2026, 11, 20));
    expect(e.end, DateTime(2026, 11, 21));
    expect(e.googleId, 'g1');
    expect(e.calendarId, 'cal');
    expect(e.allDay, isTrue);
    final i = await again.readInk();
    expect(i['2026-11']!.strokes.single.width, 0.01);
  });

  test('an empty vault reads as empty planner data', () async {
    expect((await store.readReminders()).items, isEmpty);
    expect(await store.readEvents(), isEmpty);
    expect(await store.readInk(), isEmpty);
  });

  test('two reminder heads merge by item id and newer changedAt', () async {
    await store.writeReminders(const ReminderNote());
    final parent = (await repository.heads(PlannerStore.remindersId)).single;
    Map<String, Object?> item(String id, String text, int changedAt) => {
      'id': id,
      'text': text,
      'at': null,
      'repeat': 'none',
      'done': false,
      'order': 0,
      'changedAt': changedAt,
    };
    final bodies = [
      [item('a', 'old', 1), item('b', 'only-b', 1)],
      [item('a', 'new', 5), item('c', 'only-c', 1)],
    ];
    for (final items in bodies) {
      final prepared = repository.prepareCommit(
        entityId: PlannerStore.remindersId,
        kind: EntityKind.attachment,
        files: {
          'planner-reminders.json': _bytes({
            'version': 1,
            'items': items,
            'memo': <Object>[],
            'memoAspect': 2.5,
          }),
        },
        parentRevisionIds: [parent.revisionId],
      );
      await repository.commitPrepared(prepared);
    }
    expect((await repository.heads(PlannerStore.remindersId)).length, 2);
    final merged = await store.readReminders();
    expect(
      {for (final i in merged.items) i.id: i.text},
      {'a': 'new', 'b': 'only-b', 'c': 'only-c'},
    );
    await store.writeReminders(merged);
    expect((await repository.heads(PlannerStore.remindersId)).length, 1);
  });

  test('two event heads merge by id and newer changedAt', () async {
    await store.writeEvents(const []);
    final parent = (await repository.heads(PlannerStore.eventsId)).single;
    Map<String, Object?> event(String id, String title, int changedAt) => {
      'id': id,
      'title': title,
      'start': DateTime(2026, 1, 1).millisecondsSinceEpoch,
      'end': DateTime(2026, 1, 1).millisecondsSinceEpoch,
      'allDay': true,
      'color': 1,
      'calendarId': null,
      'googleId': null,
      'changedAt': changedAt,
    };
    for (final events in [
      [event('x', 'older', 1)],
      [event('x', 'newer', 2), event('y', 'other', 1)],
    ]) {
      final prepared = repository.prepareCommit(
        entityId: PlannerStore.eventsId,
        kind: EntityKind.attachment,
        files: {
          'planner-events.json': _bytes({'version': 1, 'events': events}),
        },
        parentRevisionIds: [parent.revisionId],
      );
      await repository.commitPrepared(prepared);
    }
    final merged = await store.readEvents();
    expect(
      {for (final e in merged) e.id: e.title},
      {'x': 'newer', 'y': 'other'},
    );
  });

  test('two ink heads keep the strokes of both', () async {
    await store.writeInk(const {});
    final parent = (await repository.heads(PlannerStore.inkId)).single;
    Map<String, Object?> s(double x) => {
      'points': [x, x],
      'color': 1,
      'width': 0.01,
    };
    for (final strokes in [
      [s(0.1), s(0.2)],
      [s(0.2), s(0.3)],
    ]) {
      final prepared = repository.prepareCommit(
        entityId: PlannerStore.inkId,
        kind: EntityKind.attachment,
        files: {
          'planner-ink.json': _bytes({
            'version': 1,
            'months': {
              '2026-11': {'strokes': strokes},
            },
          }),
        },
        parentRevisionIds: [parent.revisionId],
      );
      await repository.commitPrepared(prepared);
    }
    final merged = await store.readInk();
    expect(merged['2026-11']!.strokes.length, 3);
  });

  test('a format 1 vault cannot be written', () async {
    final old = await NoteRepository.open(
      Directory(p.join(temporary.path, 'old')),
    );
    addTearDown(old.close);
    expect(
      () => PlannerStore(old).writeReminders(const ReminderNote()),
      throwsA(isA<StateError>()),
    );
    expect(
      () => PlannerStore(old).writeEvents(const []),
      throwsA(isA<StateError>()),
    );
    expect(
      () => PlannerStore(old).writeInk(const {}),
      throwsA(isA<StateError>()),
    );
  });

  group('tombstones', () {
    Map<String, Object?> item(
      String id,
      String text,
      int changedAt, {
      bool deleted = false,
    }) => {
      'id': id,
      'text': text,
      'at': null,
      'repeat': 'none',
      'done': false,
      'order': 0,
      'changedAt': changedAt,
      'deleted': deleted,
    };

    Map<String, Object?> strokeJson(double x, int changedAt) => {
      'id': 's$x',
      'points': [x, x],
      'color': 1,
      'width': 0.01,
      'changedAt': changedAt,
    };

    Future<void> twoHeads(
      String entityId,
      String file,
      List<Map<String, Object?>> bodies,
    ) async {
      final parent = (await repository.heads(entityId)).single;
      for (final body in bodies) {
        final prepared = repository.prepareCommit(
          entityId: entityId,
          kind: EntityKind.attachment,
          files: {file: _bytes(body)},
          parentRevisionIds: [parent.revisionId],
        );
        await repository.commitPrepared(prepared);
      }
      expect((await repository.heads(entityId)).length, 2);
    }

    Map<String, Object?> remindersBody(
      List<Map<String, Object?>> items, {
      List<Map<String, Object?>> memo = const [],
      Map<String, int> removed = const {},
      int clearedAt = 0,
      int changedAt = 0,
      double aspect = 2.5,
    }) => {
      'version': 1,
      'items': items,
      'memo': memo,
      'memoAspect': aspect,
      'memoRemoved': removed,
      'memoClearedAt': clearedAt,
      'memoChangedAt': changedAt,
    };

    Future<Object?> rawFile(String entityId, String file) async {
      final head = (await repository.heads(entityId)).single;
      return jsonDecode(
        utf8.decode(await repository.readRevisionFile(head, file)),
      );
    }

    test('a reminder deleted on one head stays deleted', () async {
      await store.writeReminders(const ReminderNote());
      await twoHeads(PlannerStore.remindersId, 'planner-reminders.json', [
        remindersBody([item('x', 'x', 5, deleted: true), item('y', 'y', 1)]),
        remindersBody([item('x', 'x', 1), item('y', 'y edited', 4)]),
      ]);
      final merged = await store.readReminders();
      expect({for (final i in merged.items) i.id: i.text}, {'y': 'y edited'});
    });

    test('a tie between edit and delete keeps the delete', () async {
      await store.writeReminders(const ReminderNote());
      await twoHeads(PlannerStore.remindersId, 'planner-reminders.json', [
        remindersBody([item('x', 'x', 5, deleted: true)]),
        remindersBody([item('x', 'x', 5)]),
      ]);
      expect((await store.readReminders()).items, isEmpty);
    });

    test('writing without an item leaves a tombstone in storage', () async {
      var now = 1000;
      final timed = PlannerStore(repository, clock: () => now);
      await timed.writeReminders(
        const ReminderNote(
          items: [ReminderItem(id: 'x', text: 'x')],
        ),
      );
      now = 2000;
      await timed.writeReminders(const ReminderNote());
      expect((await timed.readReminders()).items, isEmpty);
      final raw = await rawFile(
        PlannerStore.remindersId,
        'planner-reminders.json',
      ) as Map;
      final stored = (raw['items'] as List).single as Map;
      expect(stored['deleted'], isTrue);
      expect(stored['changedAt'], 2000);
    });

    test('tombstones older than 60 days are dropped on write', () async {
      var now = 1000;
      final timed = PlannerStore(repository, clock: () => now);
      await timed.writeEvents([
        PlannerEvent(
          id: 'e',
          title: 'e',
          start: DateTime(2026, 1, 1),
          end: DateTime(2026, 1, 1),
        ),
      ]);
      await timed.writeEvents(const []);
      now = 1000 + 61 * 24 * 60 * 60 * 1000;
      await timed.writeEvents(const []);
      final raw =
          await rawFile(PlannerStore.eventsId, 'planner-events.json') as Map;
      expect(raw['events'], isEmpty);
    });

    test('an event deleted on one head stays deleted', () async {
      await store.writeEvents(const []);
      Map<String, Object?> event(int changedAt, bool deleted) => {
        'id': 'e',
        'title': 'e',
        'start': '2026-11-20',
        'end': '2026-11-20',
        'allDay': true,
        'color': 1,
        'calendarId': null,
        'googleId': null,
        'changedAt': changedAt,
        'deleted': deleted,
      };
      await twoHeads(PlannerStore.eventsId, 'planner-events.json', [
        {
          'version': 1,
          'events': [event(9, true)],
        },
        {
          'version': 1,
          'events': [event(3, false)],
        },
      ]);
      expect(await store.readEvents(), isEmpty);
    });

    test('all-day events are stored as calendar dates', () async {
      await store.writeEvents([
        PlannerEvent(
          id: 'e',
          title: 'e',
          start: DateTime(2026, 11, 20),
          end: DateTime(2026, 11, 22),
        ),
        PlannerEvent(
          id: 't',
          title: 't',
          start: DateTime(2026, 11, 20, 9),
          end: DateTime(2026, 11, 20, 10),
          allDay: false,
        ),
      ]);
      final raw =
          await rawFile(PlannerStore.eventsId, 'planner-events.json') as Map;
      final byId = {for (final e in raw['events'] as List) e['id']: e};
      expect(byId['e']['start'], '2026-11-20');
      expect(byId['e']['end'], '2026-11-22');
      expect(byId['t']['start'], isA<int>());
      final read = {for (final e in await store.readEvents()) e.id: e};
      expect(read['e']!.start, DateTime(2026, 11, 20));
      expect(read['e']!.end, DateTime(2026, 11, 22));
      expect(read['t']!.start, DateTime(2026, 11, 20, 9));
    });

    test('an erased month stroke stays erased after a merge', () async {
      await store.writeInk(const {});
      Map<String, Object?> month(
        List<Map<String, Object?>> strokes, {
        Map<String, int> removed = const {},
        int clearedAt = 0,
      }) => {
        'version': 1,
        'months': {
          '2026-11': {
            'strokes': strokes,
            'removed': removed,
            'clearedAt': clearedAt,
          },
        },
      };
      await twoHeads(PlannerStore.inkId, 'planner-ink.json', [
        month([strokeJson(0.1, 2)], removed: {'s0.2': 9}),
        month([strokeJson(0.2, 3), strokeJson(0.3, 3)]),
      ]);
      final ink = await store.readInk();
      expect({for (final s in ink['2026-11']!.strokes) s.id}, {'s0.1', 's0.3'});
    });

    test('a cleared month stays cleared, newer strokes survive', () async {
      await store.writeInk(const {});
      Map<String, Object?> month(
        List<Map<String, Object?>> strokes, {
        int clearedAt = 0,
      }) => {
        'version': 1,
        'months': {
          '2026-11': {'strokes': strokes, 'clearedAt': clearedAt},
        },
      };
      await twoHeads(PlannerStore.inkId, 'planner-ink.json', [
        month([strokeJson(0.9, 20)], clearedAt: 10),
        month([strokeJson(0.1, 3), strokeJson(0.2, 4)]),
      ]);
      final ink = await store.readInk();
      expect([for (final s in ink['2026-11']!.strokes) s.id], ['s0.9']);
    });

    test(
      'ink written, erased and merged with an old copy stays erased',
      () async {
        var now = 100;
        final timed = PlannerStore(repository, clock: () => now);
        const stroke = InkStroke(points: [0.1, 0.1], color: 1, width: 0.01);
        await timed.writeInk({
          '2026-11': const MonthInk(month: '2026-11', strokes: [stroke]),
        });
        final written = (await timed.readInk())['2026-11']!.strokes.single;
        expect(written.changedAt, 100);
        expect(written.id, stroke.key);
        final firstHead = (await repository.heads(PlannerStore.inkId)).single;
        final oldCopy = jsonEncode({
          'version': 1,
          'months': {
            '2026-11': {
              'strokes': [written.toJson()],
            },
          },
        });
        now = 200;
        await timed.writeInk(const {});
        expect(await timed.readInk(), isEmpty);

        // Another device still has the old stroke.
        final prepared = repository.prepareCommit(
          entityId: PlannerStore.inkId,
          kind: EntityKind.attachment,
          files: {'planner-ink.json': Uint8List.fromList(utf8.encode(oldCopy))},
          parentRevisionIds: [firstHead.revisionId],
        );
        await repository.commitPrepared(prepared);
        expect((await repository.heads(PlannerStore.inkId)).length, 2);
        expect(await timed.readInk(), isEmpty);
      },
    );

    test('an erased memo stroke and a cleared memo stay gone', () async {
      await store.writeReminders(const ReminderNote());
      await twoHeads(PlannerStore.remindersId, 'planner-reminders.json', [
        remindersBody(
          const [],
          memo: [strokeJson(0.1, 2)],
          removed: {'s0.2': 9},
        ),
        remindersBody(const [], memo: [strokeJson(0.2, 3), strokeJson(0.3, 3)]),
      ]);
      expect(
        {for (final s in (await store.readReminders()).memo) s.id},
        {'s0.1', 's0.3'},
      );
    });

    test(
      'memo aspect: larger memoChangedAt wins, tie takes the larger',
      () async {
        await store.writeReminders(const ReminderNote());
        await twoHeads(PlannerStore.remindersId, 'planner-reminders.json', [
          remindersBody(const [], changedAt: 5, aspect: 3),
          remindersBody(const [], changedAt: 9, aspect: 1),
        ]);
        expect((await store.readReminders()).memoAspect, 1);
      },
    );

    test('memo aspect tie takes the larger value', () async {
      await store.writeReminders(const ReminderNote());
      await twoHeads(PlannerStore.remindersId, 'planner-reminders.json', [
        remindersBody(const [], changedAt: 5, aspect: 3),
        remindersBody(const [], changedAt: 5, aspect: 1),
      ]);
      expect((await store.readReminders()).memoAspect, 3);
    });

    test('old stroke data without ids gets a deterministic id', () {
      final a = InkStroke.fromJson({
        'points': [0.1, 0.2],
        'color': 5,
        'width': 0.01,
      });
      final b = InkStroke.fromJson({
        'points': [0.1, 0.2],
        'color': 5,
        'width': 0.01,
      });
      expect(a.id, b.id);
      expect(a.id, isNotEmpty);
      expect(a.changedAt, 0);
    });

    test('a stroke drawn after clearing the memo survives', () async {
      var now = 100;
      final timed = PlannerStore(repository, clock: () => now);
      const old = InkStroke(points: [0.1, 0.1], color: 1, width: 0.01);
      const fresh = InkStroke(points: [0.7, 0.7], color: 1, width: 0.01);
      await timed.writeReminders(const ReminderNote(memo: [old]));
      now = 200;
      await timed.writeReminders(const ReminderNote());
      expect((await timed.readReminders()).memoClearedAt, 200);
      now = 300;
      await timed.writeReminders(const ReminderNote(memo: [fresh]));
      final memo = (await timed.readReminders()).memo;
      expect(memo.single.key, fresh.key);
      expect(memo.single.changedAt, 300);
    });

    test('an unchanged saved stroke keeps its time on rewrite', () async {
      var now = 100;
      final timed = PlannerStore(repository, clock: () => now);
      const stroke = InkStroke(points: [0.1, 0.1], color: 1, width: 0.01);
      await timed.writeReminders(const ReminderNote(memo: [stroke]));
      now = 200;
      // Rewritten from an unstamped copy (changedAt 0), then a clear later.
      await timed.writeReminders(const ReminderNote(memo: [stroke]));
      expect((await timed.readReminders()).memo.single.changedAt, 100);
      now = 150;
      await timed.writeInk({
        '2026-11': const MonthInk(month: '2026-11', strokes: [stroke]),
      });
      now = 400;
      await timed.writeInk({
        '2026-11': const MonthInk(month: '2026-11', strokes: [stroke]),
      });
      final ink = (await timed.readInk())['2026-11']!.strokes.single;
      expect(ink.changedAt, 150);
    });

    test('changed content gets now; unchanged items keep their time', () async {
      var now = 100;
      final timed = PlannerStore(repository, clock: () => now);
      await timed.writeReminders(
        const ReminderNote(
          items: [ReminderItem(id: 'a', text: 'one')],
        ),
      );
      now = 200;
      await timed.writeReminders(
        const ReminderNote(
          items: [ReminderItem(id: 'a', text: 'one')],
        ),
      );
      expect((await timed.readReminders()).items.single.changedAt, 100);
      now = 300;
      await timed.writeReminders(
        const ReminderNote(
          items: [ReminderItem(id: 'a', text: 'two')],
        ),
      );
      expect((await timed.readReminders()).items.single.changedAt, 300);
    });
  });

  test('a write keeps what arrived after the writer read; what it knew and '
      'left out is deleted', () async {
    const other = InkStroke(
      points: [0.5, 0.6, 0.7, 0.8],
      color: 0xFF445566,
      width: 0.01,
    );
    final day = DateTime(2026, 11, 20);
    // What this device read.
    await store.writeReminders(
      const ReminderNote(
        items: [ReminderItem(id: 'mine', text: '장보기', changedAt: 1)],
        memo: [stroke],
      ),
    );
    await store.writeEvents([
      PlannerEvent(id: 'mine', title: '회의', start: day, end: day),
    ]);
    await store.writeInk({
      '2026-11': const MonthInk(month: '2026-11', strokes: [stroke]),
    });
    final read = await store.readReminders();
    // Then another device adds one of each.
    await store.writeReminders(
      ReminderNote(
        items: [
          ...read.items,
          const ReminderItem(id: 'phone', text: '택배', changedAt: 2),
        ],
        memo: [...read.memo, other],
      ),
    );
    await store.writeEvents([
      ...await store.readEvents(),
      PlannerEvent(id: 'phone', title: '치과', start: day, end: day),
    ]);
    await store.writeInk({
      ...await store.readInk(),
      '2026-12': const MonthInk(month: '2026-12', strokes: [other]),
    });

    // This device deletes everything it read.
    await store.writeReminders(
      const ReminderNote(),
      knownItems: {'mine'},
      knownStrokes: {stroke.key},
    );
    await store.writeEvents(const [], known: {'mine'});
    await store.writeInk(
      const {'2026-11': MonthInk(month: '2026-11', strokes: [])},
      known: {
        '2026-11': {stroke.key},
      },
    );

    final reminders = await store.readReminders();
    expect([for (final item in reminders.items) item.id], ['phone']);
    expect([for (final s in reminders.memo) s.key], [other.key]);
    expect([for (final event in await store.readEvents()) event.id], [
      'phone',
    ]);
    final ink = await store.readInk();
    expect(ink.keys, ['2026-12']);
    expect(ink['2026-12']!.strokes.single.key, other.key);
  });

  group('month files', () {
    const october = InkStroke(
      points: [0.1, 0.1, 0.2, 0.2],
      color: 0xFF000001,
      width: 0.006,
    );
    const november = InkStroke(
      points: [0.5, 0.5, 0.6, 0.6],
      color: 0xFF000002,
      width: 0.006,
    );
    const later = InkStroke(
      points: [0.7, 0.7, 0.8, 0.8],
      color: 0xFF000003,
      width: 0.006,
    );

    test('each month is a file of its own; writing November leaves '
        "October's blob as it was", () async {
      await store.writeInk({
        '2026-10': const MonthInk(month: '2026-10', strokes: [october]),
        '2026-11': const MonthInk(month: '2026-11', strokes: [november]),
      });
      final first = (await repository.heads(PlannerStore.inkId)).single;
      expect(
        first.blobs.keys,
        unorderedEquals(['planner-ink-2026-10.json', 'planner-ink-2026-11.json']),
      );
      final blobs = Directory(p.join(repository.root.path, 'blobs'));
      final before = blobs.listSync().length;

      // The calendar writes every month it holds; only November changed.
      final read = await store.readInk();
      await store.writeInk(
        {
          ...read,
          '2026-11': MonthInk(
            month: '2026-11',
            strokes: [...read['2026-11']!.strokes, later],
          ),
        },
        known: {
          for (final MapEntry(key: month, value: ink) in read.entries)
            month: {for (final stroke in ink.strokes) stroke.key},
        },
      );
      final second = (await repository.heads(PlannerStore.inkId)).single;
      expect(second.parentRevisionIds, [first.revisionId]);
      expect(
        second.blobs['planner-ink-2026-10.json']!.hash,
        first.blobs['planner-ink-2026-10.json']!.hash,
      );
      expect(
        second.blobs['planner-ink-2026-11.json']!.hash,
        isNot(first.blobs['planner-ink-2026-11.json']!.hash),
      );
      // Only November's new file went into the vault.
      expect(blobs.listSync().length, before + 1);
      final ink = await store.readInk();
      expect([for (final s in ink['2026-10']!.strokes) s.key], [october.key]);
      expect(
        [for (final s in ink['2026-11']!.strokes) s.key],
        [november.key, later.key],
      );
    });

    test('points are kept as whole numbers 0..10000 and read back as 0..1 '
        'within 1e-4', () async {
      const fine = InkStroke(
        points: [0.123456, 0.98761, 0, 1],
        color: 0xFF000004,
        width: 0.004,
      );
      await store.writeInk({
        '2026-11': const MonthInk(month: '2026-11', strokes: [fine]),
      });
      await store.writeReminders(const ReminderNote(memo: [fine]));
      Future<Map<String, dynamic>> raw(String entityId, String file) async {
        final head = (await repository.heads(entityId)).single;
        return jsonDecode(
              utf8.decode(await repository.readRevisionFile(head, file)),
            )
            as Map<String, dynamic>;
      }

      final month = await raw(PlannerStore.inkId, 'planner-ink-2026-11.json');
      expect((month['strokes'] as List).single['points'], [1235, 9876, 0, 10000]);
      final note = await raw(PlannerStore.remindersId, 'planner-reminders.json');
      expect((note['memo'] as List).single['points'], [1235, 9876, 0, 10000]);
      for (final read in [
        (await store.readInk())['2026-11']!.strokes.single,
        (await store.readReminders()).memo.single,
      ]) {
        expect(read.key, fine.key);
        expect(read.points, everyElement(isA<double>()));
        for (final (index, value) in read.points.indexed) {
          expect(value, closeTo(fine.points[index], 1e-4));
        }
      }
    });

    test('ink in the old single file is still read, and the next write moves '
        'it into month files', () async {
      await repository.commitPrepared(
        repository.prepareCommit(
          entityId: PlannerStore.inkId,
          kind: EntityKind.attachment,
          files: {
            'planner-ink.json': _bytes({
              'version': 1,
              'months': {
                '2026-10': {
                  'strokes': [
                    {
                      'points': [0.1, 0.2, 0.3, 0.4],
                      'color': 1,
                      'width': 0.01,
                    },
                  ],
                },
              },
            }),
          },
          parentRevisionIds: const [],
        ),
      );
      final old = (await store.readInk())['2026-10']!.strokes.single;
      expect(old.points, [0.1, 0.2, 0.3, 0.4]);

      await store.writeInk({
        ...await store.readInk(),
        '2026-11': const MonthInk(month: '2026-11', strokes: [november]),
      });
      final head = (await repository.heads(PlannerStore.inkId)).single;
      expect(
        head.blobs.keys,
        unorderedEquals(['planner-ink-2026-10.json', 'planner-ink-2026-11.json']),
      );
      final ink = await store.readInk();
      expect(ink['2026-10']!.strokes.single.key, old.key);
      expect(ink['2026-10']!.strokes.single.points, [0.1, 0.2, 0.3, 0.4]);
      expect(ink['2026-11']!.strokes.single.key, november.key);
    });
  });

  test('an older copy does not overwrite what another device changed since; '
      'a newer stamped edit wins with its own time', () async {
    var now = 1000;
    final timed = PlannerStore(repository, clock: () => now);
    final day = DateTime(2026, 11, 20);
    // What this screen read.
    const shown = [
      ReminderItem(id: 'x', text: '처음', changedAt: 500),
      ReminderItem(id: 'z', text: '지울 일', order: 1, changedAt: 500),
    ];
    final event = PlannerEvent(
      id: 'e',
      title: '처음',
      start: day,
      end: day,
      changedAt: 500,
    );
    await timed.writeReminders(const ReminderNote(items: shown));
    await timed.writeEvents([event]);

    // Another device then edits x and the event, and deletes z.
    now = 2000;
    await timed.writeReminders(
      const ReminderNote(
        items: [ReminderItem(id: 'x', text: '폰에서', changedAt: 1500)],
      ),
    );
    await timed.writeEvents([
      PlannerEvent(id: 'e', title: '폰에서', start: day, end: day, changedAt: 1500),
    ]);

    // The screen saves its old copies along with a task of its own.
    now = 3000;
    await timed.writeReminders(
      const ReminderNote(
        items: [
          ...shown,
          ReminderItem(id: 'y', text: '새 일', order: 2, changedAt: 2900),
        ],
      ),
    );
    await timed.writeEvents([event]);
    expect(
      {for (final item in (await timed.readReminders()).items) item.id: item.text},
      {'x': '폰에서', 'y': '새 일'},
    );
    expect((await timed.readEvents()).single.title, '폰에서');

    // An edit stamped after the stored change wins, keeping the edit's time.
    now = 4000;
    await timed.writeReminders(
      const ReminderNote(
        items: [
          ReminderItem(id: 'x', text: '고침', changedAt: 3500),
          ReminderItem(id: 'y', text: '새 일', order: 2, changedAt: 2900),
        ],
      ),
    );
    final x = (await timed.readReminders()).items.singleWhere(
      (item) => item.id == 'x',
    );
    expect((x.text, x.changedAt), ('고침', 3500));
  });

  test('a read that finds two heads writes the merge back over exactly '
      'those heads', () async {
    Future<void> fork(String entityId, List<Map<String, Uint8List>> files) async {
      final parent = (await repository.heads(entityId)).single;
      for (final body in files) {
        await repository.commitPrepared(
          repository.prepareCommit(
            entityId: entityId,
            kind: EntityKind.attachment,
            files: body,
            parentRevisionIds: [parent.revisionId],
          ),
        );
      }
    }

    Map<String, Object?> item(String id, String text) => {
      'id': id,
      'text': text,
      'at': null,
      'repeat': 'none',
      'done': false,
      'order': 0,
      'changedAt': 5,
    };
    Map<String, Object?> event(String id) => {
      'id': id,
      'title': id,
      'start': '2026-11-20',
      'end': '2026-11-20',
      'allDay': true,
      'color': 1,
      'calendarId': null,
      'googleId': null,
      'changedAt': 5,
    };
    Map<String, Object?> month(double x) => {
      'version': 1,
      'strokes': [
        {
          'id': 's$x',
          'points': [x, x],
          'color': 1,
          'width': 0.01,
          'changedAt': 5,
        },
      ],
    };
    await store.writeReminders(const ReminderNote());
    await store.writeEvents(const []);
    await store.writeInk(const {});
    await fork(PlannerStore.remindersId, [
      for (final id in ['a', 'b'])
        {
          'planner-reminders.json': _bytes({
            'version': 1,
            'items': [item(id, id)],
            'memo': <Object>[],
            'memoAspect': 2.5,
          }),
        },
    ]);
    await fork(PlannerStore.eventsId, [
      for (final id in ['a', 'b'])
        {
          'planner-events.json': _bytes({
            'version': 1,
            'events': [event(id)],
          }),
        },
    ]);
    await fork(PlannerStore.inkId, [
      {'planner-ink-2026-11.json': _bytes(month(0.1))},
      {'planner-ink-2026-11.json': _bytes(month(0.2))},
    ]);

    Future<void> mergedBack(String entityId, Future<void> Function() read) async {
      final forked = await repository.heads(entityId);
      expect(forked, hasLength(2));
      await read();
      // Queued before the read returned, so this call already sees it.
      final heads = await repository.heads(entityId);
      expect(heads, hasLength(1), reason: entityId);
      expect(
        heads.single.parentRevisionIds,
        unorderedEquals([for (final head in forked) head.revisionId]),
      );
    }

    await mergedBack(PlannerStore.remindersId, store.readReminders);
    await mergedBack(PlannerStore.eventsId, store.readEvents);
    await mergedBack(PlannerStore.inkId, store.readInk);
    expect(
      {for (final item in (await store.readReminders()).items) item.id},
      {'a', 'b'},
    );
    expect({for (final event in await store.readEvents()) event.id}, {'a', 'b'});
    expect(
      {for (final stroke in (await store.readInk())['2026-11']!.strokes) stroke.id},
      {'s0.1', 's0.2'},
    );
  });
}
