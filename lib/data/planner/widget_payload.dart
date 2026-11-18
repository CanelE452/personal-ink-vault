import 'dart:convert';

import 'package:saber/data/planner/planner_models.dart';

String _two(int value) => value.toString().padLeft(2, '0');

String _date(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-${_two(value.month)}-${_two(value.day)}';

String _monthKey(int year, int month) {
  final normalized = DateTime(year, month);
  return '${normalized.year.toString().padLeft(4, '0')}-${_two(normalized.month)}';
}

String _hex(int argb) =>
    '#${(argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

Map<String, Object?> _stroke(InkStroke stroke) => {
  'color': _hex(stroke.color),
  'width': stroke.width,
  'points': stroke.points,
};

/// Content of the calendar widget. The widget draws the current month, so
/// events cover the previous, current and next month and ink covers the
/// current and next month. Dates are local calendar dates.
String calendarWidgetPayload({
  required DateTime today,
  required List<PlannerEvent> events,
  required Map<String, MonthInk> ink,
}) {
  final windowStart = DateTime(today.year, today.month - 1);
  final windowEnd = DateTime(today.year, today.month + 2);
  final shown = <Map<String, Object?>>[];
  for (final event in events) {
    if (event.deleted) continue;
    final start = DateTime(
      event.start.year,
      event.start.month,
      event.start.day,
    );
    var end = DateTime(event.end.year, event.end.month, event.end.day);
    if (end.isBefore(start)) end = start;
    if (end.isBefore(windowStart) || !start.isBefore(windowEnd)) continue;
    shown.add({
      'start': _date(start),
      'end': _date(end),
      'title': event.title,
      'color': _hex(event.color),
    });
  }
  final months = <String, Object?>{};
  for (final key in [
    _monthKey(today.year, today.month),
    _monthKey(today.year, today.month + 1),
  ]) {
    final month = ink[key];
    if (month == null) continue;
    months[key] = {
      'strokes': [for (final stroke in month.strokes) _stroke(stroke)],
    };
  }
  return jsonEncode({'version': 1, 'events': shown, 'months': months});
}

/// The reminder note as the widget and the alarms take it: a blank task
/// neither shows nor rings. The reminder screen and the workspace both send
/// through this, so they never disagree.
ReminderNote shownReminders(ReminderNote note) => ReminderNote(
  items: [
    for (final item in note.items)
      if (item.text.trim().isNotEmpty) item,
  ],
  memo: note.memo,
  memoAspect: note.memoAspect,
);

/// Content of the reminder widget. Done items are included; the widget
/// filters them. A repeating item carries its next occurrence, not its
/// original (past) time, and its `step` in days, so the widget moves on to
/// the occurrence after it once that one passes.
String reminderWidgetPayload(ReminderNote note, {DateTime? now}) {
  final at = now ?? DateTime.now();
  return jsonEncode({
    'version': 1,
    'items': [
      for (final item in note.items)
        if (!item.deleted)
          {
            'id': item.id,
            'text': item.text,
            'at': _nextOccurrence(item, at)?.millisecondsSinceEpoch,
            'done': item.done,
            'order': item.order,
            if (_stepDays(item.repeat) case final step when step > 0)
              'step': step,
          },
    ],
    'memo': {
      'aspect': note.memoAspect,
      'strokes': [for (final stroke in note.memo) _stroke(stroke)],
    },
  });
}

/// Days between two occurrences of a repeating reminder; 0 for one that
/// rings once.
int _stepDays(ReminderRepeat repeat) => switch (repeat) {
  ReminderRepeat.none => 0,
  ReminderRepeat.daily => 1,
  ReminderRepeat.weekly => 7,
};

/// The item's time; for a repeating item whose time has passed, the next
/// occurrence at the same local time.
DateTime? _nextOccurrence(ReminderItem item, DateTime now) {
  final at = item.at;
  if (at == null) return null;
  final step = _stepDays(item.repeat);
  if (step == 0) return at;
  var next = at;
  var days = 0;
  while (!next.isAfter(now)) {
    days += step;
    next = DateTime(
      at.year,
      at.month,
      at.day + days,
      at.hour,
      at.minute,
      at.second,
    );
  }
  return next;
}

/// The notifications to schedule: items that are not done and whose time is
/// after [now]. A repeating item whose time has passed moves to its next
/// occurrence at the same local time, and carries its `step` in days: the
/// alarm sets itself again that many days later each time it rings.
List<Map<String, Object>> reminderAlarms(ReminderNote note, DateTime now) {
  final alarms = <Map<String, Object>>[];
  for (final item in note.items) {
    if (item.done || item.deleted) continue;
    final next = _nextOccurrence(item, now);
    if (next == null || !next.isAfter(now)) continue;
    final step = _stepDays(item.repeat);
    alarms.add({
      'id': item.id,
      'title': item.text,
      'at': next.millisecondsSinceEpoch,
      if (step > 0) 'step': step,
    });
  }
  return alarms;
}
