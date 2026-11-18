import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/planner/planner_models.dart';
import 'package:saber/data/planner/widget_payload.dart';

void main() {
  const stroke = InkStroke(
    points: [0.0, 0.5, 1.0, 0.25],
    color: 0xFFE53935,
    width: 0.02,
  );

  PlannerEvent event(String id, DateTime start, DateTime end) => PlannerEvent(
    id: id,
    title: id,
    start: start,
    end: end,
    color: 0xFF3D5AFE,
  );

  Map<String, dynamic> calendar(
    DateTime today,
    List<PlannerEvent> events,
    Map<String, MonthInk> ink,
  ) =>
      jsonDecode(calendarWidgetPayload(today: today, events: events, ink: ink))
          as Map<String, dynamic>;

  test('calendar payload has the keys the widget reads', () {
    final json = calendar(
      DateTime(2026, 11, 17),
      [event('exam', DateTime(2026, 11, 20), DateTime(2026, 11, 22))],
      const {
        '2026-11': MonthInk(month: '2026-11', strokes: [stroke]),
      },
    );
    expect(json['version'], 1);
    final e = (json['events'] as List).single as Map<String, dynamic>;
    expect(e, {
      'start': '2026-11-20',
      'end': '2026-11-22',
      'title': 'exam',
      'color': '#3D5AFE',
    });
    final s = (json['months']['2026-11']['strokes'] as List).single;
    expect(s['color'], '#E53935');
    expect(s['width'], 0.02);
    expect(s['points'], [0.0, 0.5, 1.0, 0.25]);
  });

  test('events cover previous, current and next month only', () {
    final json = calendar(DateTime(2026, 11, 17), [
      event('before', DateTime(2026, 9, 30), DateTime(2026, 9, 30)),
      event('prev', DateTime(2026, 10, 1), DateTime(2026, 10, 1)),
      event('span-in', DateTime(2026, 9, 28), DateTime(2026, 10, 2)),
      event('next', DateTime(2026, 12, 31), DateTime(2026, 12, 31)),
      event('after', DateTime(2027, 1, 1), DateTime(2027, 1, 1)),
    ], const {});
    expect([
      for (final e in json['events'] as List) e['title'],
    ], unorderedEquals(['prev', 'span-in', 'next']));
  });

  test('window wraps across the year boundary', () {
    final json = calendar(DateTime(2026, 12, 5), [
      event('jan', DateTime(2027, 1, 31), DateTime(2027, 1, 31)),
      event('feb', DateTime(2027, 2, 1), DateTime(2027, 2, 1)),
    ], const {});
    expect([for (final e in json['events'] as List) e['title']], ['jan']);
  });

  test('ink covers the current and next month only', () {
    final json = calendar(DateTime(2026, 12, 5), const [], const {
      '2026-11': MonthInk(month: '2026-11', strokes: [stroke]),
      '2026-12': MonthInk(month: '2026-12', strokes: [stroke]),
      '2027-01': MonthInk(month: '2027-01', strokes: [stroke]),
      '2027-02': MonthInk(month: '2027-02', strokes: [stroke]),
    });
    expect(
      (json['months'] as Map).keys,
      unorderedEquals(['2026-12', '2027-01']),
    );
  });

  test('reminder payload keeps done items and a null time', () {
    final json = jsonDecode(
      reminderWidgetPayload(
        ReminderNote(
          items: [
            const ReminderItem(id: 'a', text: 'x', done: true, order: 1),
            ReminderItem(
              id: 'b',
              text: 'y',
              at: DateTime.fromMillisecondsSinceEpoch(1000),
            ),
          ],
          memo: const [stroke],
          memoAspect: 2.0,
        ),
      ),
    ) as Map<String, dynamic>;
    expect(json['version'], 1);
    final items = json['items'] as List;
    expect(items[0], {
      'id': 'a',
      'text': 'x',
      'at': null,
      'done': true,
      'order': 1,
    });
    expect(items[1]['at'], 1000);
    expect(json['memo']['aspect'], 2.0);
    expect((json['memo']['strokes'] as List).single['color'], '#E53935');
  });

  group('reminderAlarms', () {
    final now = DateTime(2026, 11, 17, 12);

    test('skips done, timeless and past items', () {
      final alarms = reminderAlarms(
        ReminderNote(
          items: [
            ReminderItem(
              id: 'future',
              text: 'f',
              at: DateTime(2026, 11, 18, 9),
            ),
            ReminderItem(id: 'past', text: 'p', at: DateTime(2026, 11, 16, 9)),
            ReminderItem(
              id: 'done',
              text: 'd',
              at: DateTime(2026, 11, 18, 9),
              done: true,
            ),
            const ReminderItem(id: 'none', text: 'n'),
          ],
        ),
        now,
      );
      expect(alarms, [
        {
          'id': 'future',
          'title': 'f',
          'at': DateTime(2026, 11, 18, 9).millisecondsSinceEpoch,
        },
      ]);
    });

    test('a daily repeat moves to the next day at the same time', () {
      final alarms = reminderAlarms(
        ReminderNote(
          items: [
            ReminderItem(
              id: 'd',
              text: 'daily',
              at: DateTime(2026, 11, 15, 9, 30),
              repeat: ReminderRepeat.daily,
            ),
          ],
        ),
        now,
      );
      expect(
        alarms.single['at'],
        DateTime(2026, 11, 18, 9, 30).millisecondsSinceEpoch,
      );
    });

    test('a weekly repeat moves to the next matching weekday', () {
      final alarms = reminderAlarms(
        ReminderNote(
          items: [
            ReminderItem(
              id: 'w',
              text: 'weekly',
              at: DateTime(2026, 11, 2, 8),
              repeat: ReminderRepeat.weekly,
            ),
          ],
        ),
        now,
      );
      expect(
        alarms.single['at'],
        DateTime(2026, 11, 23, 8).millisecondsSinceEpoch,
      );
    });

    test('a repeating alarm carries its step in days; a one-time one has '
        'none', () {
      final alarms = reminderAlarms(
        ReminderNote(
          items: [
            ReminderItem(
              id: 'd',
              text: 'daily',
              at: DateTime(2026, 11, 15, 9, 30),
              repeat: ReminderRepeat.daily,
            ),
            ReminderItem(
              id: 'w',
              text: 'weekly',
              at: DateTime(2026, 11, 2, 8),
              repeat: ReminderRepeat.weekly,
            ),
            ReminderItem(id: 'o', text: 'once', at: DateTime(2026, 11, 18, 9)),
          ],
        ),
        now,
      );
      final byId = {for (final alarm in alarms) alarm['id']: alarm};
      expect(byId['d']!['step'], 1);
      expect(byId['w']!['step'], 7);
      // The next occurrence stays the time to ring at.
      expect(
        byId['d']!['at'],
        DateTime(2026, 11, 18, 9, 30).millisecondsSinceEpoch,
      );
      expect(byId['o']!.containsKey('step'), isFalse);
    });
  });

  test('a repeating item tells the widget its step; a one-time one does '
      'not', () {
    final json = jsonDecode(
      reminderWidgetPayload(
        ReminderNote(
          items: [
            ReminderItem(
              id: 'd',
              text: 'daily',
              at: DateTime(2026, 11, 15, 9, 30),
              repeat: ReminderRepeat.daily,
            ),
            ReminderItem(
              id: 'w',
              text: 'weekly',
              at: DateTime(2026, 11, 2, 8),
              repeat: ReminderRepeat.weekly,
              done: true,
            ),
            ReminderItem(id: 'o', text: 'once', at: DateTime(2026, 11, 18, 9)),
            const ReminderItem(id: 'n', text: 'no time'),
          ],
        ),
        now: DateTime(2026, 11, 17, 12),
      ),
    ) as Map<String, dynamic>;
    final byId = {
      for (final item in json['items'] as List)
        (item as Map)['id']: item,
    };
    expect(byId['d']!['step'], 1);
    expect(byId['w']!['step'], 7);
    expect(byId['o']!.containsKey('step'), isFalse);
    expect(byId['n']!.containsKey('step'), isFalse);
  });

  test('a repeating item sends its next occurrence in the widget payload', () {
    final json = jsonDecode(
      reminderWidgetPayload(
        ReminderNote(
          items: [
            ReminderItem(
              id: 'd',
              text: 'daily',
              at: DateTime(2026, 11, 15, 9, 30),
              repeat: ReminderRepeat.daily,
            ),
            ReminderItem(
              id: 'p',
              text: 'past once',
              at: DateTime(2026, 11, 1, 8),
            ),
          ],
        ),
        now: DateTime(2026, 11, 17, 12),
      ),
    ) as Map<String, dynamic>;
    final items = json['items'] as List;
    expect(
      items[0]['at'],
      DateTime(2026, 11, 18, 9, 30).millisecondsSinceEpoch,
    );
    expect(items[1]['at'], DateTime(2026, 11, 1, 8).millisecondsSinceEpoch);
  });

  test('deleted items and events are left out of the payloads', () {
    final reminders = jsonDecode(
      reminderWidgetPayload(
        const ReminderNote(
          items: [ReminderItem(id: 'x', text: 'x', deleted: true)],
        ),
      ),
    ) as Map<String, dynamic>;
    expect(reminders['items'], isEmpty);
    final json = calendar(DateTime(2026, 11, 17), [
      PlannerEvent(
        id: 'gone',
        title: 'gone',
        start: DateTime(2026, 11, 20),
        end: DateTime(2026, 11, 20),
        deleted: true,
      ),
    ], const {});
    expect(json['events'], isEmpty);
  });
}
