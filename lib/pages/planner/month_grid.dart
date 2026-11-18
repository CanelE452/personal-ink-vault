import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:saber/data/planner/planner_models.dart';

/// Sunday and Saturday in the weekday row and the day numbers; the
/// home-screen widget uses the same colours.
const sundayRed = Color(0xFFD93025);
const saturdayBlue = Color(0xFF1A73E8);

const _ink = Color(0xFF202124);
const _grey = Color(0xFF5F6368);

/// Day numbers of the months around the shown one, as the widget draws them.
const _faint = Color(0xFFBDC1C6);

/// Cell paper of the shown month and of the days around it.
const _paper = Color(0xFFF6F7F9);
const _otherPaper = Color(0xFFFBFBFC);

const _weekdays = ['일', '월', '화', '수', '목', '금', '토'];

String _two(int value) => value.toString().padLeft(2, '0');

/// 'yyyy-MM-dd', as in the cell keys.
String dayKey(DateTime day) =>
    '${day.year.toString().padLeft(4, '0')}-${_two(day.month)}-'
    '${_two(day.day)}';

/// The first and last date [event] covers, counted as the widget payload
/// counts them: its start date to its end date.
({DateTime first, DateTime last}) eventDays(PlannerEvent event) {
  final first = DateUtils.dateOnly(event.start);
  final last = DateUtils.dateOnly(event.end);
  return (first: first, last: last.isBefore(first) ? first : last);
}

bool eventCovers(PlannerEvent event, DateTime day) {
  final days = eventDays(event);
  final date = DateUtils.dateOnly(day);
  return !date.isBefore(days.first) && !date.isAfter(days.last);
}

/// Earlier first; on the same first day the longer span, then all-day before
/// timed, then by time and title.
int compareEvents(PlannerEvent a, PlannerEvent b) {
  final x = eventDays(a);
  final y = eventDays(b);
  var order = x.first.compareTo(y.first);
  if (order == 0) order = y.last.compareTo(x.last);
  if (order == 0 && a.allDay != b.allDay) order = a.allDay ? -1 : 1;
  if (order == 0) order = a.start.compareTo(b.start);
  if (order == 0) order = a.title.compareTo(b.title);
  return order == 0 ? a.id.compareTo(b.id) : order;
}

/// The weeks shown for [month], Sunday first: from the week of the 1st to
/// the week of the last day. That is five or six weeks, and four for a
/// February that starts on a Sunday: the rows the home-screen widget draws,
/// which the month's handwriting is stored against.
List<List<DateTime>> monthWeeks(DateTime month) {
  final lead = DateTime(month.year, month.month).weekday % 7;
  final days = DateUtils.getDaysInMonth(month.year, month.month);
  final count = ((lead + days) / 7).ceil();
  return [
    for (var week = 0; week < count; week++)
      [
        for (var day = 0; day < 7; day++)
          DateTime(month.year, month.month, 1 - lead + week * 7 + day),
      ],
  ];
}

/// The month grid of 설계 7절, after the Samsung Calendar photo: the weekday
/// row (일 red, 토 blue), day numbers, a one-day event as a line with a colour
/// mark on its left, an event of several days as a bar across its days (one
/// bar per week), today as a white number on a black rounded square, the
/// chosen day outlined, the days of other months faded. Events that do not
/// fit leave a `+n` on the last line of their day.
///
/// Events take no touches: a tap anywhere in a day reaches [onTapDay].
class MonthGrid extends StatelessWidget {
  const new({
    super.key,
    required this.month,
    required this.today,
    required this.events,
    this.selected,
    this.onTapDay,
    this.overlay,
  });

  final DateTime month;
  final DateTime today;
  final List<PlannerEvent> events;

  /// The outlined day; today when null.
  final DateTime? selected;
  final ValueChanged<DateTime>? onTapDay;

  /// Laid exactly over the weeks, below the weekday row: the month's
  /// handwriting, whose 0..1 points are of this area, as on the widget.
  final Widget? overlay;

  static const _weekdayHeight = 28.0;
  static const _numberHeight = 26.0;
  static const _lineHeight = 18.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final light = theme.brightness == Brightness.light;
    final weeks = monthWeeks(month);
    final sorted = [...events]..sort(compareEvents);
    return Column(
      children: [
        SizedBox(
          height: _weekdayHeight,
          child: Row(
            children: [
              for (final (column, label) in _weekdays.indexed)
                Expanded(
                  child: Center(
                    child: Text(
                      label,
                      style: TextStyle(
                        fontSize: 12,
                        color: switch (column) {
                          0 => sundayRed,
                          6 => saturdayBlue,
                          _ => light ? _grey : theme.colorScheme.onSurface,
                        },
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final cell = Size(
                constraints.maxWidth / 7,
                constraints.maxHeight / weeks.length,
              );
              return Stack(
                children: [
                  Column(
                    children: [
                      for (final week in weeks)
                        Expanded(child: _week(theme, week, sorted, cell)),
                    ],
                  ),
                  if (overlay case final overlay?)
                    Positioned.fill(child: overlay),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _week(
    ThemeData theme,
    List<DateTime> days,
    List<PlannerEvent> sorted,
    Size cell,
  ) {
    final first = days.first;
    final last = days.last;
    int column(DateTime day) =>
        days.indexWhere((other) => DateUtils.isSameDay(other, day));

    // Events of several days become bars, one-day events lines in their day.
    final bars = <({PlannerEvent event, int from, int to})>[];
    final singles = [for (var i = 0; i < 7; i++) <PlannerEvent>[]];
    final tints = List<int?>.filled(7, null);
    for (final event in sorted) {
      final span = eventDays(event);
      if (span.last.isBefore(first) || span.first.isAfter(last)) continue;
      final from = span.first.isBefore(first) ? 0 : column(span.first);
      final to = span.last.isAfter(last) ? 6 : column(span.last);
      for (var c = from; c <= to; c++) {
        tints[c] ??= event.color;
      }
      if (span.last.isAfter(span.first)) {
        bars.add((event: event, from: from, to: to));
      } else {
        singles[from].add(event);
      }
    }

    // Each bar takes the first lane free on all its days.
    final lanes = <List<bool>>[];
    final laneOf = <int>[];
    for (final bar in bars) {
      var lane = lanes.indexWhere(
        (taken) => !taken.sublist(bar.from, bar.to + 1).contains(true),
      );
      if (lane < 0) {
        lanes.add(List.filled(7, false));
        lane = lanes.length - 1;
      }
      lanes[lane].fillRange(bar.from, bar.to + 1, true);
      laneOf.add(lane);
    }
    final used = List.filled(7, 0);
    for (final (index, bar) in bars.indexed) {
      for (var c = bar.from; c <= bar.to; c++) {
        used[c] = math.max(used[c], laneOf[index] + 1);
      }
    }

    // A day that cannot show everything keeps its last line for "+n".
    final capacity = math.max(
      0,
      ((cell.height - _numberHeight - 2) / _lineHeight).floor(),
    );
    final limit = [
      for (var c = 0; c < 7; c++)
        if (used[c] + singles[c].length <= capacity) capacity else capacity - 1,
    ];
    final hidden = List.filled(7, 0);
    final light = theme.brightness == Brightness.light;
    final text = light ? _ink : theme.colorScheme.onSurface;
    bool inMonth(DateTime day) =>
        day.year == month.year && day.month == month.month;

    final marks = <Widget>[];
    for (final (index, bar) in bars.indexed) {
      final lane = laneOf[index];
      var fits = true;
      for (var c = bar.from; c <= bar.to; c++) {
        if (lane >= limit[c]) fits = false;
      }
      if (!fits) {
        for (var c = bar.from; c <= bar.to; c++) {
          hidden[c]++;
        }
        continue;
      }
      final faded = !days.sublist(bar.from, bar.to + 1).any(inMonth);
      marks.add(
        Positioned(
          left: bar.from * cell.width + 3,
          top: _numberHeight + lane * _lineHeight,
          width: (bar.to - bar.from + 1) * cell.width - 6,
          height: _lineHeight - 2,
          child: Opacity(
            key: ValueKey('month-event-${bar.event.id}'),
            opacity: faded ? 0.4 : 1,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Color(bar.event.color).withValues(alpha: 0.28),
                borderRadius: BorderRadius.circular(3),
              ),
              child: Center(child: _title(bar.event, text)),
            ),
          ),
        ),
      );
    }
    for (var c = 0; c < 7; c++) {
      for (final (index, event) in singles[c].indexed) {
        final line = used[c] + index;
        if (line >= limit[c]) {
          hidden[c]++;
          continue;
        }
        marks.add(
          Positioned(
            left: c * cell.width + 3,
            top: _numberHeight + line * _lineHeight,
            width: cell.width - 6,
            height: _lineHeight - 2,
            child: Opacity(
              key: ValueKey('month-event-${event.id}'),
              opacity: inMonth(days[c]) ? 1 : 0.4,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Color(event.color).withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(2),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ColoredBox(
                      color: Color(event.color),
                      child: const SizedBox(width: 3),
                    ),
                    const SizedBox(width: 3),
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: _title(event, text),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      }
      if (hidden[c] > 0) {
        marks.add(
          Positioned(
            left: c * cell.width + 3,
            top: capacity > 0
                ? _numberHeight + (capacity - 1) * _lineHeight
                : 4,
            width: cell.width - 6,
            height: _lineHeight - 2,
            child: Align(
              alignment: Alignment.centerRight,
              child: Text(
                '+${hidden[c]}',
                style: TextStyle(
                  fontSize: 11,
                  height: 1.2,
                  fontWeight: FontWeight.w600,
                  color: light ? _grey : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        );
      }
    }

    return Stack(
      children: [
        for (var c = 0; c < 7; c++)
          _cell(theme, days[c], c, cell, inMonth(days[c]), tints[c]),
        Positioned.fill(
          child: IgnorePointer(child: Stack(children: marks)),
        ),
      ],
    );
  }

  static Widget _title(PlannerEvent event, Color color) => Text(
    event.title,
    maxLines: 1,
    softWrap: false,
    overflow: TextOverflow.clip,
    style: TextStyle(fontSize: 11, height: 1.2, color: color),
  );

  Widget _cell(
    ThemeData theme,
    DateTime day,
    int column,
    Size size,
    bool inMonth,
    int? tint,
  ) {
    final light = theme.brightness == Brightness.light;
    final scheme = theme.colorScheme;
    final text = light ? _ink : scheme.onSurface;
    final isToday = DateUtils.isSameDay(day, today);
    final outlined = DateUtils.isSameDay(day, selected ?? today);
    final paper = light
        ? (inMonth ? _paper : _otherPaper)
        : (inMonth ? scheme.surfaceContainerHigh : scheme.surfaceContainerLow);
    final number = Text(
      '${day.day}',
      style: TextStyle(
        fontSize: 13,
        height: 1.25,
        fontWeight: FontWeight.w600,
        color: isToday
            ? (light ? Colors.white : scheme.surface)
            : !inMonth
            ? (light ? _faint : scheme.outline)
            : switch (column) {
                0 => sundayRed,
                6 => saturdayBlue,
                _ => text,
              },
      ),
    );
    return Positioned(
      left: column * size.width,
      top: 0,
      width: size.width,
      height: size.height,
      child: Padding(
        padding: const EdgeInsets.all(1),
        child: Material(
          // The day's first event tints its paper, as in the photo.
          color: tint == null || !inMonth
              ? paper
              : Color.alphaBlend(Color(tint).withValues(alpha: 0.07), paper),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(6),
            side: outlined
                ? BorderSide(color: text, width: 1.2)
                : BorderSide.none,
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: ValueKey('month-cell-${dayKey(day)}'),
            onTap: onTapDay == null ? null : () => onTapDay!(day),
            child: Align(
              alignment: Alignment.topCenter,
              child: Padding(
                padding: const EdgeInsets.only(top: 4),
                child: isToday
                    ? DecoratedBox(
                        decoration: BoxDecoration(
                          color: text,
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: number,
                        ),
                      )
                    : number,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
