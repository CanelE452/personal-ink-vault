import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/planner/calendar_sync.dart';
import 'package:saber/data/planner/google_calendar.dart';
import 'package:saber/data/planner/handwriting_recognizer.dart';
import 'package:saber/data/planner/planner_models.dart';
import 'package:saber/data/planner/planner_platform.dart';
import 'package:saber/data/planner/planner_store.dart';
import 'package:saber/pages/planner/calendar_page.dart';
import 'package:saber/pages/planner/ink_pad.dart';

/// Reads [answer] in Korean and [english] in English; a null answer means
/// the engine is missing. A language in [missing] has no model until a
/// download brings it, which the test finishes through [pending].
class _Recognizer implements HandwritingRecognizer {
  new(this.answer, {this.english = const []});

  final List<String>? answer;
  final List<String> english;
  final missing = <String>{};

  /// The model check says ready although the model is missing, as when the
  /// model goes between the check and the reading.
  var staleCheck = false;

  final seen = <({List<InkStroke> strokes, String language, Size area})>[];
  final downloads = <String>[];

  /// The download running now.
  Completer<void>? pending;

  @override
  late final models = HandwritingModels(downloadModel);

  @override
  Future<HandwritingModelState> modelState(String language) async {
    if (answer == null) return HandwritingModelState.unavailable;
    return missing.contains(language) && !staleCheck
        ? HandwritingModelState.missing
        : HandwritingModelState.ready;
  }

  @override
  Future<void> downloadModel(String language) async {
    downloads.add(language);
    final download = pending = Completer<void>();
    await download.future;
    missing.remove(language);
  }

  @override
  Future<List<String>> recognize(
    List<InkStroke> strokes, {
    String language = 'ko',
    required Size area,
  }) async {
    seen.add((strokes: strokes, language: language, area: area));
    final answer = this.answer;
    if (answer == null) throw HandwritingUnavailable();
    if (missing.contains(language)) throw HandwritingModelMissing();
    return language == 'ko' ? answer : english;
  }
}

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final now = DateTime(2026, 11, 17, 10);

  /// Friday 20 is column 5 of 7 and row 2 of 5 in November 2026, so its cell
  /// is x 0.714–0.857 and y 0.4–0.6 of the weeks.
  const inFriday20 = InkStroke(
    points: [0.74, 0.45, 0.8, 0.5],
    color: 0xFF202124,
    width: 0.006,
  );

  /// Friday 20's too (its middle is in the cell), but it runs on into
  /// Saturday 21.
  const intoSaturday21 = InkStroke(
    points: [0.8, 0.52, 0.88, 0.56],
    color: 0xFF202124,
    width: 0.006,
  );

  /// In Monday 2's cell (column 1, row 0).
  const inMonday2 = InkStroke(
    points: [0.2, 0.1, 0.25, 0.12],
    color: 0xFF202124,
    width: 0.006,
  );

  late Directory temporary;
  late NoteRepository repository;
  late PlannerStore store;
  late List<MethodCall> calls;

  setUp(() async {
    final owner = Directory.systemTemp;
    temporary = await owner.createTemp('piv-calendar-page-');
    addTearDown(() async {
      final resolved = await temporary.resolveSymbolicLinks();
      expect(p.dirname(resolved), await owner.resolveSymbolicLinks());
      expect(p.basename(resolved), startsWith('piv-calendar-page-'));
      await Directory(resolved).delete(recursive: true);
    });
    repository = await NoteRepository.open(
      Directory(p.join(temporary.path, 'vault')),
      createFormatVersion: 2,
    );
    // See reminder_page_test.dart: after a failed test the repository's
    // queue can wait on the test's fake zone, so close() gets a time limit.
    addTearDown(
      () => repository.close().timeout(
        const Duration(seconds: 5),
        onTimeout: () {},
      ),
    );
    store = PlannerStore(repository);
    calls = [];
    messenger.setMockMethodCallHandler(PlannerPlatform.channel, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(PlannerPlatform.channel, null),
    );
  });

  int count(String method) =>
      calls.where((call) => call.method == method).length;

  /// Moves the app to [target] through the states between, as the engine
  /// reports them.
  void changeLifecycle(WidgetTester tester, AppLifecycleState target) {
    final binding = tester.binding;
    final previous = binding.lifecycleState;
    if (previous == target) return;
    if (previous == null) {
      binding.handleAppLifecycleStateChanged(target);
      return;
    }
    const states = AppLifecycleState.values;
    final start = states.indexOf(previous), end = states.indexOf(target);
    final step = start < end ? 1 : -1;
    for (var i = start + step; i != end + step; i += step) {
      binding.handleAppLifecycleStateChanged(states[i]);
    }
  }

  Map<String, dynamic> lastPayload() {
    final update =
        calls.lastWhere((call) => call.method == 'updateWidget').arguments
            as Map;
    expect(update['kind'], 'calendar');
    return jsonDecode(update['payload'] as String) as Map<String, dynamic>;
  }

  /// Real time for the file work, then fake time for the page.
  Future<void> drain(WidgetTester tester, [int cycles = 8]) async {
    await tester.runAsync(() async {
      for (var i = 0; i < cycles; i++) {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 15));
      }
    });
    await tester.pump(const Duration(milliseconds: 50));
  }

  Future<void> waitFor(WidgetTester tester, Finder finder) async {
    for (var i = 0; i < 40 && finder.evaluate().isEmpty; i++) {
      await drain(tester);
    }
    expect(finder, findsWidgets);
  }

  /// Lets a dialog or sheet open or close.
  Future<void> animate(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// Runs the page's pending saves (handwriting waits five seconds) up to
  /// the widget update after them, and any save queued behind them.
  Future<void> settle(WidgetTester tester) async {
    final before = count('updateWidget');
    await tester.pump(const Duration(seconds: 5));
    for (var i = 0; i < 40 && count('updateWidget') == before; i++) {
      await drain(tester);
    }
    expect(
      count('updateWidget'),
      greaterThan(before),
      reason: 'the save did not finish',
    );
    var seen = count('updateWidget');
    for (var quiet = 0; quiet < 3;) {
      await tester.pump(const Duration(seconds: 5));
      await drain(tester);
      if (count('updateWidget') == seen) {
        quiet++;
      } else {
        seen = count('updateWidget');
        quiet = 0;
      }
    }
  }

  /// Reads the store in real time while pumping the fake zone, which also
  /// hands the repository's queue back to the real zone (see
  /// reminder_page_test.dart).
  Future<T> read<T>(WidgetTester tester, Future<T> Function() reading) async {
    late T value;
    await tester.runAsync(() async {
      var done = false;
      final future = reading().whenComplete(() => done = true);
      for (var i = 0; i < 300 && !done; i++) {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      if (!done) throw StateError('the store did not answer');
      value = await future;
    });
    return value;
  }

  Future<List<PlannerEvent>> storedEvents(WidgetTester tester) =>
      read(tester, store.readEvents);

  Future<Map<String, MonthInk>> storedInk(WidgetTester tester) =>
      read(tester, store.readInk);

  /// Writes through a second store, as another device's sync would, while
  /// pumping the page's fake zone (see [read]).
  Future<void> elsewhere(
    WidgetTester tester,
    Future<void> Function(PlannerStore other) write,
  ) => read(tester, () => write(PlannerStore(repository)));

  Future<void> mount(
    WidgetTester tester, {
    Size size = const Size(1000, 900),
    HandwritingRecognizer? recognizer,
    CalendarSync? sync,
    Future<void> Function()? onConnectGoogle,
    Future<void> Function()? onDisconnectGoogle,
    Listenable? changes,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: CalendarPage(
          store: store,
          platform: PlannerPlatform(),
          sync: sync,
          recognizer: recognizer ?? _Recognizer(const []),
          onConnectGoogle: onConnectGoogle,
          onDisconnectGoogle: onDisconnectGoogle,
          changes: changes,
          now: () => now,
        ),
      ),
    );
    await waitFor(tester, find.byKey(const ValueKey('month-cell-2026-11-17')));
    expect(find.byKey(const ValueKey('calendar-page')), findsOneWidget);
    expect(find.text('2026년 11월'), findsOneWidget);
  }

  /// Leaves the page, lets a save started by leaving finish and hands the
  /// repository back to real time.
  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await drain(tester);
    await storedEvents(tester);
  }

  Future<void> openDay(WidgetTester tester, String day) async {
    await tester.tap(find.byKey(ValueKey('month-cell-$day')));
    await animate(tester);
    expect(find.byKey(const ValueKey('event-sheet')), findsOneWidget);
  }

  /// Lets a dialog open that waits for the recognizer.
  Future<void> waitForDialog(WidgetTester tester, String key) async {
    final dialog = find.byKey(ValueKey(key));
    for (var i = 0; i < 10 && dialog.evaluate().isEmpty; i++) {
      await animate(tester);
    }
    expect(dialog, findsOneWidget);
  }

  /// Lets a SnackBar with [text] come in, after the one shown before it.
  Future<void> waitForSnackBar(WidgetTester tester, String text) async {
    final snackBar = find.descendant(
      of: find.byType(SnackBar),
      matching: find.text(text),
    );
    for (var i = 0; i < 10 && snackBar.evaluate().isEmpty; i++) {
      await animate(tester);
    }
    expect(snackBar, findsOneWidget);
    await animate(tester);
  }

  /// 「글자로 바꾸기」 on [day], which opens the dialog keyed [opens].
  Future<void> pickConvertDay(
    WidgetTester tester,
    String day, {
    String opens = 'calendar-convert-dialog',
  }) async {
    await tester.tap(find.byKey(const ValueKey('calendar-mode')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('calendar-ink-convert')));
    await tester.pump();
    expect(find.text('글자로 바꿀 날짜 칸을 누르세요'), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('month-cell-$day')));
    await waitForDialog(tester, opens);
  }

  testWidgets('a day opens its sheet; an added event is drawn and stored, '
      'then renamed and deleted', (tester) async {
    await mount(tester);
    await openDay(tester, '2026-11-20');
    expect(find.text('11월 20일 (금)'), findsOneWidget);
    expect(find.text('일정이 없습니다'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('event-add')));
    await animate(tester);
    final title = find.byKey(const ValueKey('event-title'));
    // The tablet's pen handwriting input works in the title.
    expect(tester.widget<TextField>(title).stylusHandwritingEnabled, isTrue);
    await tester.enterText(title, '치과');
    // The save button turns on with the next frame.
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('event-save')));
    await settle(tester);

    final saved = (await storedEvents(tester)).single;
    expect(saved.title, '치과');
    expect(saved.allDay, isTrue);
    expect(saved.start, DateTime(2026, 11, 20));
    expect(saved.end, DateTime(2026, 11, 20));
    expect(saved.calendarId, isNull);
    expect(saved.changedAt, greaterThan(0));
    final drawn = find.byKey(ValueKey('month-event-${saved.id}'));
    expect(drawn, findsOneWidget);
    expect(
      tester
          .getRect(find.byKey(const ValueKey('month-cell-2026-11-20')))
          .contains(tester.getCenter(drawn)),
      isTrue,
    );
    expect(lastPayload()['events'], [
      {
        'start': '2026-11-20',
        'end': '2026-11-20',
        'title': '치과',
        'color': '#3D5AFE',
      },
    ]);

    await openDay(tester, '2026-11-20');
    await tester.tap(find.byKey(ValueKey('event-sheet-item-${saved.id}')));
    await animate(tester);
    await tester.enterText(find.byKey(const ValueKey('event-title')), '치과 검진');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('event-save')));
    await settle(tester);
    final renamed = (await storedEvents(tester)).single;
    expect(renamed.id, saved.id);
    expect(renamed.title, '치과 검진');
    expect(find.text('치과 검진'), findsOneWidget);

    await openDay(tester, '2026-11-20');
    await tester.tap(find.byKey(ValueKey('event-sheet-item-${saved.id}')));
    await animate(tester);
    await tester.tap(find.byKey(const ValueKey('event-delete')));
    await animate(tester);
    await tester.tap(find.byKey(const ValueKey('event-delete-ok')));
    await settle(tester);
    expect(await storedEvents(tester), isEmpty);
    expect(drawn, findsNothing);
    expect(lastPayload()['events'], isEmpty);
    await unmount(tester);
  });

  testWidgets('the quick-add pill adds an all-day event on the chosen day', (
    tester,
  ) async {
    await mount(tester);
    final pill = find.byKey(const ValueKey('calendar-quick-add'));
    expect(
      find.descendant(of: pill, matching: find.text('11월 17일에 추가')),
      findsOneWidget,
    );
    // Choosing a day moves the pill to it.
    await openDay(tester, '2026-11-25');
    await tester.tapAt(const Offset(10, 10));
    await animate(tester);
    expect(find.byKey(const ValueKey('event-sheet')), findsNothing);
    expect(
      find.descendant(of: pill, matching: find.text('11월 25일에 추가')),
      findsOneWidget,
    );

    final field = find.descendant(of: pill, matching: find.byType(TextField));
    expect(tester.widget<TextField>(field).stylusHandwritingEnabled, isTrue);
    await tester.enterText(field, '회의');
    await tester.tap(find.byKey(const ValueKey('calendar-quick-add-submit')));
    await settle(tester);

    final saved = (await storedEvents(tester)).single;
    expect(saved.title, '회의');
    expect(saved.allDay, isTrue);
    expect(saved.start, DateTime(2026, 11, 25));
    expect(saved.end, DateTime(2026, 11, 25));
    expect(find.byKey(ValueKey('month-event-${saved.id}')), findsOneWidget);
    expect(tester.widget<TextField>(field).controller!.text, isEmpty);
    await unmount(tester);
  });

  testWidgets('a stroke drawn in handwriting mode is stored for the month '
      'and sent to the widget', (tester) async {
    await mount(tester);
    InkPad pad() =>
        tester.widget<InkPad>(find.byKey(const ValueKey('calendar-ink')));
    // The month's handwriting shows in edit mode too, but takes no input.
    expect(pad().enabled, isFalse);
    await tester.tap(find.byKey(const ValueKey('calendar-mode')));
    await tester.pump();
    expect(pad().enabled, isTrue);
    expect(find.byKey(const ValueKey('calendar-quick-add')), findsNothing);

    final cell = tester.getRect(
      find.byKey(const ValueKey('month-cell-2026-11-11')),
    );
    final pen = await tester.startGesture(
      cell.center - const Offset(20, 0),
      kind: PointerDeviceKind.stylus,
    );
    await pen.moveTo(cell.center);
    await pen.moveTo(cell.center + const Offset(20, 10));
    await pen.up();
    await settle(tester);

    final ink = await storedInk(tester);
    expect(ink.keys, ['2026-11']);
    final stroke = ink['2026-11']!.strokes.single;
    expect(stroke.changedAt, greaterThan(0));
    // In 0..1 of the weeks: Wednesday 11 is column 3 of 7, row 1 of 5.
    expect(stroke.points[0], inInclusiveRange(3 / 7, 4 / 7));
    expect(stroke.points[1], inInclusiveRange(1 / 5, 2 / 5));
    final months = lastPayload()['months'] as Map<String, dynamic>;
    expect((months['2026-11'] as Map)['strokes'], hasLength(1));

    // Undo takes the stroke away again.
    await tester.tap(find.byKey(const ValueKey('calendar-ink-undo')));
    await settle(tester);
    expect(await storedInk(tester), isEmpty);
    await unmount(tester);
  });

  testWidgets('handwriting is saved five seconds later, and at once when the '
      'mode switches, the app goes to the background or the screen is '
      'left', (tester) async {
    addTearDown(() => changeLifecycle(tester, AppLifecycleState.resumed));
    await mount(tester);
    Future<void> write(String day) async {
      final cell = tester.getRect(find.byKey(ValueKey('month-cell-$day')));
      final pen = await tester.startGesture(
        cell.center - const Offset(20, 0),
        kind: PointerDeviceKind.stylus,
      );
      await pen.moveTo(cell.center);
      await pen.moveTo(cell.center + const Offset(20, 10));
      await pen.up();
      await tester.pump();
    }

    /// Waits a little (under a second of the page's time, so a missed flush
    /// cannot pass for the five-second save) for the widget update that
    /// follows a save.
    Future<void> saved(int sends) async {
      for (var i = 0; i < 16 && count('updateWidget') < sends; i++) {
        await drain(tester);
      }
      expect(count('updateWidget'), sends);
    }

    Future<int> strokes() async =>
        (await storedInk(tester))['2026-11']?.strokes.length ?? 0;

    final mode = find.byKey(const ValueKey('calendar-mode'));
    await tester.tap(mode);
    await tester.pump();
    await write('2026-11-11');
    await tester.pump(const Duration(seconds: 4));
    await drain(tester);
    await drain(tester);
    expect(count('updateWidget'), 0, reason: 'nothing is sent unsaved');
    expect(await strokes(), 0, reason: 'nothing is saved before five seconds');

    // Back to edit mode: saved at once, then sent to the widget.
    await tester.tap(mode);
    await tester.pump();
    await saved(1);
    expect(await strokes(), 1);

    // The app going to the background saves the next stroke.
    await tester.tap(mode);
    await tester.pump();
    await write('2026-11-12');
    changeLifecycle(tester, AppLifecycleState.paused);
    await saved(2);
    expect(await strokes(), 2);
    changeLifecycle(tester, AppLifecycleState.resumed);

    // Leaving the screen saves the last one.
    await write('2026-11-13');
    await tester.pumpWidget(const SizedBox());
    await saved(3);
    expect(await strokes(), 3);
  });

  testWidgets('an event another device changed keeps that change when this '
      'screen saves its old copy', (tester) async {
    final day = DateTime(2026, 11, 20);
    await tester.runAsync(
      () => store.writeEvents([
        PlannerEvent(id: 'class', title: '수업', start: day, end: day),
      ]),
    );
    await mount(tester);
    expect(find.text('수업'), findsWidgets);
    // Another device renames it. This screen is not told (no change
    // listener), so it keeps its old copy.
    await elsewhere(tester, (other) async {
      await other.writeEvents([
        for (final event in await other.readEvents())
          PlannerEvent(
            id: event.id,
            title: '휴강',
            start: event.start,
            end: event.end,
            changedAt: event.changedAt + 1,
          ),
      ]);
    });

    // An event added here saves every event the screen holds.
    final pill = find.byKey(const ValueKey('calendar-quick-add'));
    await tester.enterText(
      find.descendant(of: pill, matching: find.byType(TextField)),
      '회의',
    );
    await tester.tap(find.byKey(const ValueKey('calendar-quick-add-submit')));
    await settle(tester);
    final titles = {
      for (final event in await storedEvents(tester)) event.id: event.title,
    };
    expect(titles['class'], '휴강');
    expect(titles.values, contains('회의'));
    await unmount(tester);
  });

  testWidgets('clearing the month asks first, and undo brings the saved '
      'strokes back', (tester) async {
    await tester.runAsync(
      () => store.writeInk({
        '2026-11': const MonthInk(month: '2026-11', strokes: [inMonday2]),
      }),
    );
    await mount(tester);
    await tester.tap(find.byKey(const ValueKey('calendar-mode')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('calendar-ink-clear')));
    await animate(tester);
    await tester.tap(find.byKey(const ValueKey('calendar-ink-clear-ok')));
    await settle(tester);
    expect(await storedInk(tester), isEmpty);

    // The strokes come back although the store saw them cleared.
    await tester.tap(find.byKey(const ValueKey('calendar-ink-undo')));
    await settle(tester);
    final strokes = (await storedInk(tester))['2026-11']!.strokes;
    expect(strokes.single.points, inMonday2.points);
    await unmount(tester);
  });

  testWidgets("글자로 바꾸기 makes an event of a day's handwriting with the "
      "recognizer's text", (tester) async {
    await tester.runAsync(
      () => store.writeInk({
        '2026-11': const MonthInk(
          month: '2026-11',
          strokes: [inFriday20, intoSaturday21, inMonday2],
        ),
      }),
    );
    final recognizer = _Recognizer(['병원 예약', '병원 예악']);
    await mount(tester, recognizer: recognizer);
    await pickConvertDay(tester, '2026-11-20');

    // Friday's two strokes go in Korean, in 0..1 of the writing area: the
    // cell as the grid draws it (1/7 by 1/5 of the weeks), grown to the
    // stroke that runs into Saturday.
    final sent = recognizer.seen.single;
    expect(sent.language, 'ko');
    final grid = tester.getSize(find.byKey(const ValueKey('calendar-ink')));
    const boxWidth = 0.88 - 5 / 7;
    expect(sent.area.width, closeTo(boxWidth * grid.width, 1e-6));
    expect(sent.area.height, closeTo(grid.height / 5, 1e-6));
    expect(sent.strokes, hasLength(2));
    expect(sent.strokes.first.points, [
      closeTo((0.74 - 5 / 7) / boxWidth, 1e-9),
      closeTo(0.25, 1e-9),
      closeTo((0.8 - 5 / 7) / boxWidth, 1e-9),
      closeTo(0.5, 1e-9),
    ]);
    expect(sent.strokes.last.points[2], closeTo(1, 1e-9));
    for (final stroke in sent.strokes) {
      for (final (index, value) in stroke.points.indexed) {
        final extent = index.isEven ? sent.area.width : sent.area.height;
        expect(value * extent, inInclusiveRange(0, extent));
      }
    }
    final text = find.byKey(const ValueKey('calendar-convert-text'));
    expect(tester.widget<TextField>(text).controller!.text, '병원 예약');
    await tester.tap(find.byKey(const ValueKey('calendar-convert-save')));
    await animate(tester);
    await tester.tap(find.byKey(const ValueKey('calendar-convert-erase')));
    await settle(tester);

    final event = (await storedEvents(tester)).single;
    expect(event.title, '병원 예약');
    expect(event.allDay, isTrue);
    expect(event.start, DateTime(2026, 11, 20));
    expect(event.end, DateTime(2026, 11, 20));
    expect(find.byKey(ValueKey('month-event-${event.id}')), findsOneWidget);
    final strokes = (await storedInk(tester))['2026-11']!.strokes;
    expect(strokes.single.points, inMonday2.points);
    await unmount(tester);
  });

  testWidgets('without a recognizer engine the reason shows and a pen-input '
      'field opens', (tester) async {
    await tester.runAsync(
      () => store.writeInk({
        '2026-11': const MonthInk(month: '2026-11', strokes: [inFriday20]),
      }),
    );
    await mount(tester, recognizer: _Recognizer(null));
    await pickConvertDay(tester, '2026-11-20');

    expect(find.text(HandwritingUnavailable().message), findsOneWidget);
    // As before the engine: no language to choose, no model to download.
    expect(find.byType(SegmentedButton<String>), findsNothing);
    expect(find.byKey(const ValueKey('handwriting-model-notice')), findsNothing);
    final text = find.byKey(const ValueKey('calendar-convert-text'));
    expect(tester.widget<TextField>(text).controller!.text, isEmpty);
    expect(tester.widget<TextField>(text).stylusHandwritingEnabled, isTrue);
    await tester.enterText(text, '수영');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('calendar-convert-save')));
    await animate(tester);
    await tester.tap(find.byKey(const ValueKey('calendar-convert-keep')));
    await settle(tester);

    final event = (await storedEvents(tester)).single;
    expect(event.title, '수영');
    expect(event.start, DateTime(2026, 11, 20));
    expect((await storedInk(tester))['2026-11']!.strokes, hasLength(1));
    await unmount(tester);
  });

  testWidgets('a missing model is asked for, downloads in the background '
      'while the calendar stays usable, then converts the day', (tester) async {
    await tester.runAsync(
      () => store.writeInk({
        '2026-11': const MonthInk(month: '2026-11', strokes: [inFriday20]),
      }),
    );
    final recognizer = _Recognizer(['수영'])..missing.add('ko');
    await mount(tester, recognizer: recognizer);
    final progress = find.byKey(const ValueKey('handwriting-model-progress'));
    expect(progress, findsNothing);
    await pickConvertDay(
      tester,
      '2026-11-20',
      opens: 'handwriting-model-notice',
    );
    final notice = find.byKey(const ValueKey('handwriting-model-notice'));
    for (final text in ['한국어', '15.7MB', '25MB', 'Wi-Fi']) {
      expect(
        find.descendant(of: notice, matching: find.textContaining(text)),
        findsWidgets,
        reason: text,
      );
    }
    expect(recognizer.seen, isEmpty);

    await tester.tap(find.byKey(const ValueKey('handwriting-model-download')));
    await animate(tester);
    // 받기 returns at once: the download runs behind the calendar.
    expect(notice, findsNothing);
    expect(find.byKey(const ValueKey('calendar-convert-dialog')), findsNothing);
    expect(recognizer.downloads, ['ko']);
    expect(progress, findsOneWidget);
    // Indeterminate: ML Kit does not say how far the download is.
    expect(tester.widget<LinearProgressIndicator>(progress).value, isNull);
    expect(find.text('한국어 손글씨 모델을 받는 중입니다.'), findsOneWidget);

    // The calendar stays usable: another month shows while it runs.
    await tester.tap(find.byKey(const ValueKey('calendar-next')));
    await tester.pump();
    expect(find.text('2026년 12월'), findsOneWidget);
    expect(progress, findsOneWidget);

    recognizer.pending!.complete();
    await waitForSnackBar(tester, '손글씨 모델을 받았습니다');
    expect(progress, findsNothing);
    // Its 글자로 바꾸기 goes back to November and reads Friday the 20th.
    await tester.tap(find.widgetWithText(SnackBarAction, '글자로 바꾸기'));
    await waitForDialog(tester, 'calendar-convert-dialog');
    expect(find.text('2026년 11월'), findsOneWidget);
    expect(recognizer.seen.single.language, 'ko');
    final text = find.byKey(const ValueKey('calendar-convert-text'));
    expect(tester.widget<TextField>(text).controller!.text, '수영');
    await tester.tap(find.byKey(const ValueKey('calendar-convert-save')));
    await animate(tester);
    await tester.tap(find.byKey(const ValueKey('calendar-convert-keep')));
    await settle(tester);

    final event = (await storedEvents(tester)).single;
    expect(event.title, '수영');
    expect(event.start, DateTime(2026, 11, 20));
    expect(event.end, DateTime(2026, 11, 20));
    await unmount(tester);
  });

  testWidgets('a failed model download says why, and 다시 받기 starts it '
      'again', (tester) async {
    await tester.runAsync(
      () => store.writeInk({
        '2026-11': const MonthInk(month: '2026-11', strokes: [inFriday20]),
      }),
    );
    final recognizer = _Recognizer(['수영'])..missing.add('ko');
    await mount(tester, recognizer: recognizer);
    await pickConvertDay(
      tester,
      '2026-11-20',
      opens: 'handwriting-model-notice',
    );
    await tester.tap(find.byKey(const ValueKey('handwriting-model-download')));
    await animate(tester);
    final progress = find.byKey(const ValueKey('handwriting-model-progress'));
    expect(progress, findsOneWidget);

    recognizer.pending!.completeError(
      PlatformException(
        code: 'download_failed',
        message: '네트워크에 연결되어 있지 않습니다.',
      ),
    );
    await waitForSnackBar(tester, '손글씨 모델을 받지 못했습니다: 네트워크에 연결되어 있지 않습니다.');
    expect(progress, findsNothing);
    expect(find.widgetWithText(SnackBarAction, '글자로 바꾸기'), findsNothing);

    await tester.tap(find.widgetWithText(SnackBarAction, '다시 받기'));
    await animate(tester);
    expect(recognizer.downloads, ['ko', 'ko']);
    expect(progress, findsOneWidget);
    expect(find.text('한국어 손글씨 모델을 받는 중입니다.'), findsOneWidget);

    recognizer.pending!.complete();
    await waitForSnackBar(tester, '손글씨 모델을 받았습니다');
    expect(progress, findsNothing);
    expect(recognizer.missing, isEmpty);
    await unmount(tester);
  });

  testWidgets('한국어 | 영어 reads the day again in English, and a missing '
      'English model is asked for first', (tester) async {
    await tester.runAsync(
      () => store.writeInk({
        '2026-11': const MonthInk(month: '2026-11', strokes: [inFriday20]),
      }),
    );
    final recognizer = _Recognizer(['병원'], english: ['Dentist'])
      ..missing.add('en-US');
    await mount(tester, recognizer: recognizer);
    await pickConvertDay(tester, '2026-11-20');
    final text = find.byKey(const ValueKey('calendar-convert-text'));
    String shown() => tester.widget<TextField>(text).controller!.text;
    Set<String> language() => tester
        .widget<SegmentedButton<String>>(find.byType(SegmentedButton<String>))
        .selected;
    expect(language(), {'ko'});
    expect(shown(), '병원');

    // English has no model yet: its notice first; 취소 stays on Korean.
    final notice = find.byKey(const ValueKey('handwriting-model-notice'));
    await tester.tap(find.byKey(const ValueKey('handwriting-language-en')));
    await waitForDialog(tester, 'handwriting-model-notice');
    for (final size in ['13.8MB', '26MB']) {
      expect(
        find.descendant(of: notice, matching: find.textContaining(size)),
        findsOneWidget,
        reason: size,
      );
    }
    await tester.tap(find.descendant(of: notice, matching: find.text('취소')));
    await animate(tester);
    expect(notice, findsNothing);
    expect(language(), {'ko'});
    expect(shown(), '병원');
    expect(recognizer.downloads, isEmpty);

    // 받기 closes the dialog while the model comes.
    await tester.tap(find.byKey(const ValueKey('handwriting-language-en')));
    await waitForDialog(tester, 'handwriting-model-notice');
    await tester.tap(find.byKey(const ValueKey('handwriting-model-download')));
    await animate(tester);
    expect(find.byKey(const ValueKey('calendar-convert-dialog')), findsNothing);
    expect(recognizer.downloads, ['en-US']);
    expect(find.text('영어 손글씨 모델을 받는 중입니다.'), findsOneWidget);

    recognizer.pending!.complete();
    await waitForSnackBar(tester, '손글씨 모델을 받았습니다');
    await tester.tap(find.widgetWithText(SnackBarAction, '글자로 바꾸기'));
    await waitForDialog(tester, 'calendar-convert-dialog');
    expect(language(), {'en-US'});
    expect(shown(), 'Dentist');

    // With both models here, a switch reads again at once.
    await tester.tap(find.byKey(const ValueKey('handwriting-language-ko')));
    await animate(tester);
    expect(language(), {'ko'});
    expect(shown(), '병원');
    await tester.tap(find.byKey(const ValueKey('handwriting-language-en')));
    await animate(tester);
    expect(shown(), 'Dentist');
    expect([for (final read in recognizer.seen) read.language], [
      'ko',
      'en-US',
      'ko',
      'en-US',
    ]);
    // Every reading was of the same writing area.
    expect({for (final read in recognizer.seen) read.area}, hasLength(1));

    await tester.tap(find.byKey(const ValueKey('calendar-convert-save')));
    await animate(tester);
    await tester.tap(find.byKey(const ValueKey('calendar-convert-keep')));
    await settle(tester);
    expect((await storedEvents(tester)).single.title, 'Dentist');
    await unmount(tester);
  });

  testWidgets('a model gone since its check is asked for again', (
    tester,
  ) async {
    await tester.runAsync(
      () => store.writeInk({
        '2026-11': const MonthInk(month: '2026-11', strokes: [inFriday20]),
      }),
    );
    final recognizer = _Recognizer(['수영'])
      ..missing.add('ko')
      ..staleCheck = true;
    await mount(tester, recognizer: recognizer);
    await pickConvertDay(
      tester,
      '2026-11-20',
      opens: 'handwriting-model-notice',
    );
    expect(recognizer.seen, hasLength(1));
    final notice = find.byKey(const ValueKey('handwriting-model-notice'));
    await tester.tap(find.descendant(of: notice, matching: find.text('취소')));
    await animate(tester);
    expect(notice, findsNothing);
    expect(find.byKey(const ValueKey('calendar-convert-dialog')), findsNothing);
    expect(recognizer.downloads, isEmpty);
    expect(
      find.byKey(const ValueKey('handwriting-model-progress')),
      findsNothing,
    );
    await unmount(tester);
  });

  testWidgets('a model download outlives the calendar: opened again, the '
      'screen shows it and says when it ends', (tester) async {
    await tester.runAsync(
      () => store.writeInk({
        '2026-11': const MonthInk(month: '2026-11', strokes: [inFriday20]),
      }),
    );
    final recognizer = _Recognizer(['수영'])..missing.add('ko');
    await mount(tester, recognizer: recognizer);
    await pickConvertDay(
      tester,
      '2026-11-20',
      opens: 'handwriting-model-notice',
    );
    await tester.tap(find.byKey(const ValueKey('handwriting-model-download')));
    await animate(tester);

    // The calendar is left while the model downloads, and opened again.
    await unmount(tester);
    await mount(tester, recognizer: recognizer);
    final progress = find.byKey(const ValueKey('handwriting-model-progress'));
    expect(progress, findsOneWidget);
    expect(recognizer.downloads, ['ko']);

    recognizer.pending!.complete();
    await waitForSnackBar(tester, '손글씨 모델을 받았습니다');
    expect(progress, findsNothing);
    // No day of this screen waited for it, so there is nothing to convert.
    expect(find.byType(SnackBarAction), findsNothing);
    await unmount(tester);
  });

  testWidgets('a day picked while its model downloads waits for that '
      'download instead of asking again', (tester) async {
    await tester.runAsync(
      () => store.writeInk({
        '2026-11': const MonthInk(
          month: '2026-11',
          strokes: [inFriday20, inMonday2],
        ),
      }),
    );
    final recognizer = _Recognizer(['수영'])..missing.add('ko');
    await mount(tester, recognizer: recognizer);
    await pickConvertDay(
      tester,
      '2026-11-20',
      opens: 'handwriting-model-notice',
    );
    await tester.tap(find.byKey(const ValueKey('handwriting-model-download')));
    await animate(tester);
    // Its SnackBar goes, which uncovers the pen tools.
    await tester.pump(const Duration(seconds: 5));
    await animate(tester);
    expect(find.byType(SnackBar), findsNothing);

    // Monday the 2nd while the model is coming: no notice, no second
    // download, and nothing read yet.
    await tester.tap(find.byKey(const ValueKey('calendar-ink-convert')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('month-cell-2026-11-02')));
    await animate(tester);
    expect(find.byKey(const ValueKey('handwriting-model-notice')), findsNothing);
    expect(recognizer.downloads, ['ko']);
    expect(recognizer.seen, isEmpty);
    expect(find.text('한국어 손글씨 모델을 받는 중입니다.'), findsOneWidget);

    // Once the model is here, 글자로 바꾸기 reads the day picked last.
    recognizer.pending!.complete();
    await waitForSnackBar(tester, '손글씨 모델을 받았습니다');
    await tester.tap(find.widgetWithText(SnackBarAction, '글자로 바꾸기'));
    await waitForDialog(tester, 'calendar-convert-dialog');
    expect(find.text('11월 2일 (월) 일정으로 넣습니다.'), findsOneWidget);
    // Monday's cell is column 1 of 7 and row 0 of 5.
    expect(recognizer.seen.single.strokes.single.points, [
      closeTo((0.2 - 1 / 7) * 7, 1e-9),
      closeTo(0.1 * 5, 1e-9),
      closeTo((0.25 - 1 / 7) * 7, 1e-9),
      closeTo(0.12 * 5, 1e-9),
    ]);
    final dialog = find.byKey(const ValueKey('calendar-convert-dialog'));
    await tester.tap(find.descendant(of: dialog, matching: find.text('취소')));
    await animate(tester);
    expect(dialog, findsNothing);
    await unmount(tester);
  });

  testWidgets('without a Google connection only device events show', (
    tester,
  ) async {
    await tester.runAsync(
      () => store.writeEvents([
        PlannerEvent(
          id: 'mine',
          title: '독서',
          start: DateTime(2026, 11, 5),
          end: DateTime(2026, 11, 5),
        ),
      ]),
    );
    // A month cached while the calendar was still connected.
    final cache = Directory(p.join(temporary.path, 'planner'))..createSync();
    File(p.join(cache.path, 'google-2026-11.json')).writeAsStringSync(
      jsonEncode([
        PlannerEvent(
          id: 'g1',
          title: '예전 회의',
          start: DateTime(2026, 11, 6),
          end: DateTime(2026, 11, 6),
          calendarId: 'cal',
          googleId: 'g1',
        ).toJson(),
      ]),
    );
    var connects = 0;
    await mount(
      tester,
      sync: CalendarSync(cacheDir: cache, api: () async => null),
      onConnectGoogle: () async => connects++,
    );
    await drain(tester);
    expect(find.byKey(const ValueKey('month-event-mine')), findsOneWidget);
    expect(find.byKey(const ValueKey('month-event-g1')), findsNothing);
    final google = find.byKey(const ValueKey('calendar-google'));
    expect(
      find.descendant(
        of: google,
        matching: find.byIcon(Icons.cloud_off_outlined),
      ),
      findsOneWidget,
    );

    // The editor offers this device only.
    await openDay(tester, '2026-11-05');
    await tester.tap(find.byKey(const ValueKey('event-sheet-item-mine')));
    await animate(tester);
    final calendar = find.byKey(const ValueKey('event-calendar'));
    expect(
      find.descendant(of: calendar, matching: find.text('기기')),
      findsOneWidget,
    );
    await tester.tap(find.text('취소'));
    await animate(tester);

    // Connecting asks the hook; still not connected, nothing else shows.
    await tester.tap(google);
    await drain(tester);
    expect(connects, 1);
    expect(find.byKey(const ValueKey('month-event-g1')), findsNothing);
    await unmount(tester);
  });

  testWidgets('a connected Google calendar is drawn, and an event saved to '
      'it goes to Google instead of the device store', (tester) async {
    final requests = <http.Request>[];
    final client = MockClient((request) async {
      requests.add(request);
      final path = request.url.path;
      if (path.endsWith('/calendarList')) {
        return _json({
          'items': [
            {
              'id': 'me@example.com',
              'summary': '내 캘린더',
              'backgroundColor': '#0B8043',
              'selected': true,
              'accessRole': 'owner',
            },
            {
              'id': 'ko.south_korea#holiday@group.v.calendar.google.com',
              'summary': '휴일',
              'backgroundColor': '#D50000',
              'selected': true,
              'accessRole': 'reader',
            },
          ],
        });
      }
      if (request.method == 'GET' && path.endsWith('/events')) {
        final from = DateTime.parse(request.url.queryParameters['timeMin']!)
            .toLocal();
        if (from.month != 11 ||
            request.url.pathSegments[3] != 'me@example.com') {
          return _json({'items': <Object>[]});
        }
        return _json({
          'items': [
            {
              'id': 'g1',
              'summary': '점심',
              'start': {'date': '2026-11-05'},
              'end': {'date': '2026-11-06'},
            },
          ],
        });
      }
      if (request.method == 'POST') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        return _json({
          'id': 'g2',
          'summary': body['summary'],
          'start': body['start'],
          'end': body['end'],
        });
      }
      return http.Response('', 204);
    });
    final sync = CalendarSync(
      cacheDir: Directory(p.join(temporary.path, 'planner')),
      api: () async => GoogleCalendarApi((_) async => 'token', client: client),
    );
    await mount(tester, sync: sync);
    await waitFor(tester, find.byKey(const ValueKey('month-event-g1')));
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('calendar-google')),
        matching: find.byIcon(Icons.cloud_done_outlined),
      ),
      findsOneWidget,
    );

    await openDay(tester, '2026-11-20');
    await tester.tap(find.byKey(const ValueKey('event-add')));
    await animate(tester);
    // A new event goes to the account's own Google calendar by default.
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('event-calendar')),
        matching: find.text('내 캘린더'),
      ),
      findsOneWidget,
    );
    await tester.enterText(find.byKey(const ValueKey('event-title')), '저녁');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('event-save')));
    await waitFor(tester, find.byKey(const ValueKey('month-event-g2')));

    final post = requests.singleWhere((request) => request.method == 'POST');
    expect(post.url.path, '/calendar/v3/calendars/me@example.com/events');
    expect(jsonDecode(post.body), {
      'summary': '저녁',
      'start': {'date': '2026-11-20'},
      'end': {'date': '2026-11-21'},
    });
    expect(await storedEvents(tester), isEmpty);
    List<Object?> titles() => [
      for (final event in lastPayload()['events'] as List)
        (event as Map)['title'],
    ];
    for (var i = 0; i < 20 && !titles().contains('저녁'); i++) {
      await drain(tester);
    }
    expect(titles(), unorderedEquals(['점심', '저녁']));
    await unmount(tester);
  });

  testWidgets('phone width fits the header, the grid, the day sheet, the '
      'editor and the pen tools', (tester) async {
    await tester.runAsync(
      () => store.writeEvents([
        PlannerEvent(
          id: 'long',
          title: '아주 긴 제목의 여러 날 일정은 칸을 넘어 이어집니다',
          start: DateTime(2026, 11, 13),
          end: DateTime(2026, 11, 16),
        ),
        for (var i = 0; i < 6; i++)
          PlannerEvent(
            id: 'busy$i',
            title: '하루 일정 $i 제목이 깁니다',
            start: DateTime(2026, 11, 18, 9 + i),
            end: DateTime(2026, 11, 18, 10 + i),
            allDay: false,
          ),
      ]),
    );
    await mount(tester, size: const Size(360, 640));
    expect(find.byKey(const ValueKey('calendar-mode')), findsOneWidget);
    expect(find.byKey(const ValueKey('calendar-today')), findsOneWidget);
    expect(find.byKey(const ValueKey('calendar-google')), findsOneWidget);
    expect(find.byKey(const ValueKey('month-event-long')), findsWidgets);
    expect(find.textContaining('+'), findsWidgets);

    await openDay(tester, '2026-11-18');
    await tester.tap(find.byKey(const ValueKey('event-sheet-item-busy0')));
    await animate(tester);
    expect(find.byKey(const ValueKey('event-start-time')), findsOneWidget);
    await tester.tap(find.text('취소'));
    await animate(tester);

    await tester.tap(find.byKey(const ValueKey('calendar-mode')));
    await tester.pump();
    for (final key in [
      'calendar-pen-color-0',
      'calendar-pen-width-2',
      'calendar-ink-eraser',
      'calendar-ink-undo',
      'calendar-ink-redo',
      'calendar-ink-clear',
      'calendar-ink-convert',
    ]) {
      expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
    }
    // 「글자로 바꾸기」 stays on screen while the other tools scroll.
    final convert = tester.getRect(
      find.byKey(const ValueKey('calendar-ink-convert')),
    );
    expect((Offset.zero & const Size(360, 640)).intersect(convert), convert);
    await unmount(tester);
  });

  testWidgets('an event and handwriting from another device survive this '
      "screen's saves", (tester) async {
    final changes = ValueNotifier(0);
    addTearDown(changes.dispose);
    await mount(tester, changes: changes);
    await elsewhere(tester, (other) async {
      await other.writeEvents([
        PlannerEvent(
          id: 'phone',
          title: '치과',
          start: DateTime(2026, 11, 9),
          end: DateTime(2026, 11, 9),
        ),
      ]);
      await other.writeInk({
        '2026-11': const MonthInk(month: '2026-11', strokes: [inMonday2]),
      });
    });
    // The workspace tells the page that the vault changed.
    changes.value++;
    await waitFor(tester, find.byKey(const ValueKey('month-event-phone')));

    final pill = find.byKey(const ValueKey('calendar-quick-add'));
    await tester.enterText(
      find.descendant(of: pill, matching: find.byType(TextField)),
      '회의',
    );
    await tester.tap(find.byKey(const ValueKey('calendar-quick-add-submit')));
    await settle(tester);
    expect({for (final event in await storedEvents(tester)) event.title}, {
      '치과',
      '회의',
    });

    // A month written elsewhere while a stroke waits for its save is kept.
    await tester.tap(find.byKey(const ValueKey('calendar-mode')));
    await tester.pump();
    final cell = tester.getRect(
      find.byKey(const ValueKey('month-cell-2026-11-11')),
    );
    final pen = await tester.startGesture(
      cell.center - const Offset(20, 0),
      kind: PointerDeviceKind.stylus,
    );
    await pen.moveTo(cell.center);
    await pen.moveTo(cell.center + const Offset(20, 10));
    await pen.up();
    await tester.pump();
    await elsewhere(tester, (other) async {
      final ink = await other.readInk();
      await other.writeInk({
        ...ink,
        '2026-12': const MonthInk(month: '2026-12', strokes: [inFriday20]),
      });
    });
    changes.value++;
    await settle(tester);
    final ink = await storedInk(tester);
    expect(ink['2026-11']!.strokes, hasLength(2));
    expect(ink['2026-12']!.strokes.single.points, inFriday20.points);
    await unmount(tester);
  });

  testWidgets('a connected calendar offers 새로 받기 and 연결 끊기, and 연결 '
      "끊기 leaves this device's events", (tester) async {
    var gets = 0;
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/calendarList')) {
        return _json({
          'items': [
            {
              'id': 'me@example.com',
              'summary': '내 캘린더',
              'backgroundColor': '#0B8043',
              'selected': true,
              'accessRole': 'owner',
            },
          ],
        });
      }
      gets++;
      final from = DateTime.parse(
        request.url.queryParameters['timeMin']!,
      ).toLocal();
      return _json({
        'items': [
          if (from.month == 11)
            {
              'id': 'g1',
              'summary': '점심',
              'start': {'date': '2026-11-05'},
              'end': {'date': '2026-11-06'},
            },
        ],
      });
    });
    var connected = true;
    var disconnects = 0;
    final cache = Directory(p.join(temporary.path, 'planner'));
    final sync = CalendarSync(
      cacheDir: cache,
      api: () async => connected
          ? GoogleCalendarApi((_) async => 'token', client: client)
          : null,
    );
    await mount(
      tester,
      sync: sync,
      onDisconnectGoogle: () async {
        disconnects++;
        connected = false;
        await sync.clear();
      },
    );
    await waitFor(tester, find.byKey(const ValueKey('month-event-g1')));
    final google = find.byKey(const ValueKey('calendar-google'));
    // The months beside this one are still being fetched.
    bool idle() => tester.widget<IconButton>(google).onPressed != null;
    for (var i = 0; i < 40 && !idle(); i++) {
      await drain(tester);
    }

    await tester.tap(google);
    await animate(tester);
    expect(
      find.byKey(const ValueKey('calendar-google-refresh')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('calendar-google-disconnect')),
      findsOneWidget,
    );
    final before = gets;
    await tester.tap(find.byKey(const ValueKey('calendar-google-refresh')));
    await animate(tester);
    for (var i = 0; i < 40 && gets == before; i++) {
      await drain(tester);
    }
    expect(gets, greaterThan(before));
    for (var i = 0; i < 40 && !idle(); i++) {
      await drain(tester);
    }

    await tester.tap(google);
    await animate(tester);
    await tester.tap(find.byKey(const ValueKey('calendar-google-disconnect')));
    for (
      var i = 0;
      i < 40 && find.byKey(const ValueKey('month-event-g1')).evaluate().isNotEmpty;
      i++
    ) {
      await drain(tester);
    }
    expect(disconnects, 1);
    expect(find.byKey(const ValueKey('month-event-g1')), findsNothing);
    expect(
      find.descendant(of: google, matching: find.byIcon(Icons.cloud_off_outlined)),
      findsOneWidget,
    );
    expect(
      cache.existsSync() ? cache.listSync().whereType<File>() : const <File>[],
      isEmpty,
    );
    expect(lastPayload()['events'], isEmpty);
    await unmount(tester);
  });
}
