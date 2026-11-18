import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/planner/planner_models.dart';
import 'package:saber/pages/planner/month_grid.dart';

void main() {
  const ink = Color(0xFF202124);
  const faint = Color(0xFFBDC1C6);

  test('November 2026 has five weeks starting on Sunday the 1st', () {
    final weeks = monthWeeks(DateTime(2026, 11, 17));
    expect(weeks, hasLength(5));
    expect(weeks.every((week) => week.length == 7), isTrue);
    expect(weeks.first.first, DateTime(2026, 11));
    expect(weeks.first.first.weekday, DateTime.sunday);
    expect(weeks.last.last, DateTime(2026, 12, 5));
  });

  test('August 2026 has six weeks', () {
    final weeks = monthWeeks(DateTime(2026, 8));
    expect(weeks, hasLength(6));
    expect(weeks.first.first, DateTime(2026, 7, 26));
    expect(weeks.last.last, DateTime(2026, 9, 5));
  });

  test('a February that fills four whole weeks keeps four rows', () {
    // The home-screen widget draws the same rows, and the month's
    // handwriting is stored in 0..1 of them.
    final weeks = monthWeeks(DateTime(2026, 2));
    expect(weeks, hasLength(4));
    expect(weeks.first.first, DateTime(2026, 2));
    expect(weeks.last.last, DateTime(2026, 2, 28));
  });

  Future<void> show(
    WidgetTester tester, {
    List<PlannerEvent> events = const [],
    DateTime? selected,
    ValueChanged<DateTime>? onTapDay,
    Size size = const Size(700, 600),
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: size.width,
              height: size.height,
              child: MonthGrid(
                month: DateTime(2026, 11),
                today: DateTime(2026, 11, 17),
                events: events,
                selected: selected,
                onTapDay: onTapDay,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Rect cell(WidgetTester tester, String day) =>
      tester.getRect(find.byKey(ValueKey('month-cell-$day')));

  Text number(WidgetTester tester, String day, String label) =>
      tester.widget<Text>(
        find.descendant(
          of: find.byKey(ValueKey('month-cell-$day')),
          matching: find.text(label),
        ),
      );

  final trip = PlannerEvent(
    id: 'trip',
    title: '여행',
    start: DateTime(2026, 11, 6),
    end: DateTime(2026, 11, 10),
  );

  testWidgets('a multi-day event that crosses a week is drawn as two bars', (
    tester,
  ) async {
    await show(
      tester,
      events: [
        trip,
        PlannerEvent(
          id: 'lunch',
          title: '점심',
          start: DateTime(2026, 11, 13, 12),
          end: DateTime(2026, 11, 13, 13),
          allDay: false,
          color: 0xFFF9AB00,
        ),
      ],
    );
    final bars = find.byKey(const ValueKey('month-event-trip'));
    expect(bars, findsNWidgets(2));
    // Friday 6 to Saturday 7, then Sunday 8 to Tuesday 10.
    final first = tester.getRect(bars.at(0));
    final second = tester.getRect(bars.at(1));
    expect(first.left, closeTo(cell(tester, '2026-11-06').left, 4));
    expect(first.right, closeTo(cell(tester, '2026-11-07').right, 4));
    expect(second.left, closeTo(cell(tester, '2026-11-08').left, 4));
    expect(second.right, closeTo(cell(tester, '2026-11-10').right, 4));
    expect(find.text('여행'), findsNWidgets(2));

    // A one-day event sits in its cell with a colour mark on its left.
    final lunch = find.byKey(const ValueKey('month-event-lunch'));
    expect(lunch, findsOneWidget);
    expect(
      cell(tester, '2026-11-13').contains(tester.getCenter(lunch)),
      isTrue,
    );
    final mark = find.descendant(
      of: lunch,
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is ColoredBox && widget.color == const Color(0xFFF9AB00),
      ),
    );
    expect(mark, findsOneWidget);
    expect(tester.getRect(mark).left, closeTo(tester.getRect(lunch).left, 1));
  });

  testWidgets('weekday colours, today and the faded days of other months', (
    tester,
  ) async {
    await show(tester);
    expect(tester.widget<Text>(find.text('일')).style?.color, sundayRed);
    expect(tester.widget<Text>(find.text('토')).style?.color, saturdayBlue);
    expect(number(tester, '2026-11-01', '1').style?.color, sundayRed);
    expect(number(tester, '2026-11-07', '7').style?.color, saturdayBlue);
    expect(number(tester, '2026-11-18', '18').style?.color, ink);

    // Today: a white number on a black rounded square, and the cell outline.
    expect(number(tester, '2026-11-17', '17').style?.color, Colors.white);
    final badge = tester.widget<DecoratedBox>(
      find
          .ancestor(
            of: find.descendant(
              of: find.byKey(const ValueKey('month-cell-2026-11-17')),
              matching: find.text('17'),
            ),
            matching: find.byType(DecoratedBox),
          )
          .first,
    );
    final decoration = badge.decoration as BoxDecoration;
    expect(decoration.color, ink);
    expect(decoration.borderRadius, isNotNull);
    RoundedRectangleBorder shape(String day) =>
        tester
                .widget<Material>(
                  find
                      .ancestor(
                        of: find.byKey(ValueKey('month-cell-$day')),
                        matching: find.byType(Material),
                      )
                      .first,
                )
                .shape!
            as RoundedRectangleBorder;
    expect(shape('2026-11-17').side.style, BorderStyle.solid);
    expect(shape('2026-11-18').side.style, BorderStyle.none);

    // Days of December in the last row are faded.
    expect(number(tester, '2026-12-01', '1').style?.color, faint);
  });

  testWidgets('the outline follows the chosen day', (tester) async {
    await show(tester, selected: DateTime(2026, 11, 20));
    RoundedRectangleBorder shape(String day) =>
        tester
                .widget<Material>(
                  find
                      .ancestor(
                        of: find.byKey(ValueKey('month-cell-$day')),
                        matching: find.byType(Material),
                      )
                      .first,
                )
                .shape!
            as RoundedRectangleBorder;
    expect(shape('2026-11-20').side.style, BorderStyle.solid);
    expect(shape('2026-11-17').side.style, BorderStyle.none);
  });

  testWidgets('a day with more events than fit shows +n in place of them', (
    tester,
  ) async {
    await show(
      tester,
      size: const Size(700, 420),
      events: [
        for (var i = 0; i < 8; i++)
          PlannerEvent(
            id: 'e$i',
            title: '일정 $i',
            start: DateTime(2026, 11, 18),
            end: DateTime(2026, 11, 18),
          ),
      ],
    );
    final shown = [
      for (var i = 0; i < 8; i++)
        if (find.byKey(ValueKey('month-event-e$i')).evaluate().isNotEmpty) i,
    ];
    expect(shown, isNotEmpty);
    expect(shown.length, lessThan(8));
    final more = find.text('+${8 - shown.length}');
    expect(more, findsOneWidget);
    final day = cell(tester, '2026-11-18');
    expect(day.contains(tester.getCenter(more)), isTrue);
    for (final i in shown) {
      final event = tester.getRect(find.byKey(ValueKey('month-event-e$i')));
      expect(day.contains(event.center), isTrue);
      expect(event.overlaps(tester.getRect(more)), isFalse);
    }
  });

  testWidgets('a tap on a day, or on an event bar over it, reports the day', (
    tester,
  ) async {
    final tapped = <DateTime>[];
    await show(tester, events: [trip], onTapDay: tapped.add);
    await tester.tap(find.byKey(const ValueKey('month-cell-2026-11-24')));
    // The second bar runs from Sunday 8 to Tuesday 10; its middle is over 9.
    await tester.tapAt(
      tester.getCenter(find.byKey(const ValueKey('month-event-trip')).at(1)),
    );
    expect(tapped, [DateTime(2026, 11, 24), DateTime(2026, 11, 9)]);
  });
}
