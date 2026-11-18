import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/planner/planner_models.dart';
import 'package:saber/data/planner/planner_platform.dart';
import 'package:saber/data/planner/planner_store.dart';
import 'package:saber/pages/planner/reminder_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final now = DateTime(2026, 11, 17, 10);
  const red = Color(0xFFD93025);
  const exactOff = '정확한 알람이 꺼져 있어 알림이 몇 분 늦을 수 있습니다';

  late Directory temporary;
  late NoteRepository repository;
  late PlannerStore store;
  late List<MethodCall> calls;

  setUp(() async {
    final owner = Directory.systemTemp;
    temporary = await owner.createTemp('piv-reminder-page-');
    addTearDown(() async {
      final resolved = await temporary.resolveSymbolicLinks();
      expect(p.dirname(resolved), await owner.resolveSymbolicLinks());
      expect(p.basename(resolved), startsWith('piv-reminder-page-'));
      await Directory(resolved).delete(recursive: true);
    });
    repository = await NoteRepository.open(
      Directory(p.join(temporary.path, 'vault')),
      createFormatVersion: 2,
    );
    // close() waits for the repository's queue. After a test that failed
    // before [stored] ran, that queue can wait on a microtask of the test's
    // fake zone, which nothing runs any more: report instead of hanging.
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
      return switch (call.method) {
        'scheduleReminders' => {'granted': true, 'exact': true},
        'requestNotificationPermission' => {'granted': true, 'exact': false},
        _ => null,
      };
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

  /// Real time for the store's file work, then fake time for the page.
  Future<void> drain(WidgetTester tester, [int cycles = 8]) async {
    await tester.runAsync(() async {
      for (var i = 0; i < cycles; i++) {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 15));
      }
    });
    await tester.pump(const Duration(milliseconds: 50));
  }

  /// Runs the page's save, five seconds after the last change, and the
  /// widget and alarm calls after it (alarms go last).
  Future<void> settle(WidgetTester tester) async {
    final before = count('scheduleReminders');
    await tester.pump(const Duration(seconds: 5));
    for (var i = 0; i < 40 && count('scheduleReminders') == before; i++) {
      await drain(tester);
    }
    expect(
      count('scheduleReminders'),
      greaterThan(before),
      reason: 'the save did not finish',
    );
  }

  /// Reads the store in real time. The page's last call left the
  /// repository's queue in the test's fake zone, so the fake microtasks are
  /// pumped while the read waits; the queue then belongs to the real zone
  /// again and the repository can close after the test.
  Future<ReminderNote> stored(WidgetTester tester) async {
    ReminderNote? note;
    await tester.runAsync(() async {
      var done = false;
      final reading = store.readReminders().whenComplete(() => done = true);
      for (var i = 0; i < 300 && !done; i++) {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      if (!done) throw StateError('the store did not answer');
      note = await reading;
    });
    return note!;
  }

  Future<void> seed(WidgetTester tester, ReminderNote note) async {
    await tester.runAsync(() => store.writeReminders(note));
  }

  /// Writes through a second store, as another device's sync would, while
  /// pumping the page's fake zone (see [stored]).
  Future<void> elsewhere(
    WidgetTester tester,
    Future<void> Function(PlannerStore other) write,
  ) async {
    await tester.runAsync(() async {
      var done = false;
      final writing = write(
        PlannerStore(repository),
      ).whenComplete(() => done = true);
      for (var i = 0; i < 300 && !done; i++) {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      if (!done) throw StateError('the store did not answer');
      await writing;
    });
  }

  Future<void> mount(
    WidgetTester tester, {
    Size size = const Size(800, 1200),
    Listenable? changes,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: ReminderPage(
          store: store,
          platform: PlannerPlatform(),
          changes: changes,
          now: () => now,
        ),
      ),
    );
    final memo = find.byKey(const ValueKey('reminder-memo'));
    for (var i = 0; i < 40 && memo.evaluate().isEmpty; i++) {
      await drain(tester);
    }
    expect(find.byKey(const ValueKey('reminder-page')), findsOneWidget);
    expect(memo, findsOneWidget);
  }

  /// Leaves the page, lets a save started by leaving finish and hands the
  /// repository back to real time (see [stored]).
  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await drain(tester);
    await stored(tester);
  }

  Future<void> openTimeDialog(WidgetTester tester, String id) async {
    await tester.tap(find.byKey(ValueKey('reminder-time-$id')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('reminder-time-dialog')), findsOneWidget);
  }

  Future<void> draw(WidgetTester tester, [double right = 0]) async {
    final origin =
        tester.getTopLeft(find.byKey(const ValueKey('reminder-memo'))) +
        Offset(right, 0);
    final pen = await tester.startGesture(
      origin + const Offset(20, 60),
      kind: PointerDeviceKind.stylus,
    );
    await pen.moveTo(origin + const Offset(80, 30));
    await pen.moveTo(origin + const Offset(140, 50));
    await pen.up();
    await tester.pump();
  }

  testWidgets('adding, checking and deleting a task is saved', (tester) async {
    await mount(tester);
    await tester.tap(find.byKey(const ValueKey('reminder-add')));
    await tester.pump();
    final field = find.byType(TextField);
    // The tablet's pen handwriting input works in the task text.
    expect(tester.widget<TextField>(field).stylusHandwritingEnabled, isTrue);
    await tester.enterText(field, '우유 사기');
    await settle(tester);
    final item = (await stored(tester)).items.single;
    expect(item.text, '우유 사기');
    expect(item.done, isFalse);
    expect(item.changedAt, greaterThan(0));

    await tester.tap(find.byKey(ValueKey('reminder-check-${item.id}')));
    await settle(tester);
    expect((await stored(tester)).items.single.done, isTrue);

    await tester.tap(find.byKey(const ValueKey('reminder-done-toggle')));
    await tester.pump();
    await tester.tap(find.byKey(ValueKey('reminder-delete-${item.id}')));
    await settle(tester);
    expect((await stored(tester)).items, isEmpty);
    expect(find.byKey(ValueKey('reminder-item-${item.id}')), findsNothing);
    await unmount(tester);
  });

  testWidgets('finished tasks fold under the done count and open on tap', (
    tester,
  ) async {
    await seed(
      tester,
      const ReminderNote(
        items: [
          ReminderItem(id: 'open', text: '장보기', changedAt: 1),
          ReminderItem(
            id: 'finished',
            text: '빨래',
            done: true,
            order: 1,
            changedAt: 1,
          ),
        ],
      ),
    );
    await mount(tester);
    expect(find.byKey(const ValueKey('reminder-item-open')), findsOneWidget);
    expect(find.byKey(const ValueKey('reminder-item-finished')), findsNothing);
    expect(find.text('끝낸 일 1개'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('reminder-done-toggle')));
    await tester.pump();
    expect(
      find.byKey(const ValueKey('reminder-item-finished')),
      findsOneWidget,
    );
    await unmount(tester);
  });

  testWidgets('a past time is red, a later or repeating one is not', (
    tester,
  ) async {
    await seed(
      tester,
      ReminderNote(
        items: [
          ReminderItem(
            id: 'late',
            text: '병원',
            at: DateTime(2026, 11, 17, 9),
            changedAt: 1,
          ),
          ReminderItem(
            id: 'later',
            text: '회의',
            at: DateTime(2026, 11, 17, 12),
            order: 1,
            changedAt: 1,
          ),
          ReminderItem(
            id: 'daily',
            text: '약',
            at: DateTime(2026, 11, 16, 9),
            repeat: ReminderRepeat.daily,
            order: 2,
            changedAt: 1,
          ),
        ],
      ),
    );
    await mount(tester);
    Color? colour(String id) => tester
        .widget<Text>(
          find.descendant(
            of: find.byKey(ValueKey('reminder-time-$id')),
            matching: find.byType(Text),
          ),
        )
        .style
        ?.color;

    expect(find.text('오늘 09:00'), findsOneWidget);
    expect(colour('late'), red);
    expect(find.text('오늘 12:00'), findsOneWidget);
    expect(colour('later'), isNot(red));
    expect(find.text('매일 09:00'), findsOneWidget);
    expect(colour('daily'), isNot(red));
    await unmount(tester);
  });

  testWidgets('phone width fits long tasks, time chips and the time dialog', (
    tester,
  ) async {
    await seed(
      tester,
      ReminderNote(
        items: [
          ReminderItem(
            id: 'long',
            text: '아주 긴 할 일 글은 한 줄에 다 들어가지 않으면 줄을 바꿔 보여야 합니다',
            at: DateTime(2026, 11, 20, 9),
            repeat: ReminderRepeat.weekly,
            changedAt: 1,
          ),
          ReminderItem(
            id: 'last-year',
            text: '병원',
            at: DateTime(2025, 12, 31, 23, 59),
            order: 1,
            changedAt: 1,
          ),
        ],
      ),
    );
    await mount(tester, size: const Size(360, 640));
    expect(find.text('매주 금 09:00'), findsOneWidget);
    expect(find.text('2025/12/31 23:59'), findsOneWidget);

    await openTimeDialog(tester, 'last-year');
    expect(find.byKey(const ValueKey('reminder-time-clear')), findsOneWidget);
    await tester.tap(find.text('취소'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('reminder-time-dialog')), findsNothing);
    await unmount(tester);
  });

  testWidgets('setting a time asks for notifications once and sends alarms', (
    tester,
  ) async {
    await seed(
      tester,
      const ReminderNote(
        items: [ReminderItem(id: 'a', text: '약 먹기', changedAt: 1)],
      ),
    );
    await mount(tester);

    await openTimeDialog(tester, 'a');
    await tester.tap(find.byKey(const ValueKey('reminder-time-ok')));
    await settle(tester);
    // The next full hour is the first offer.
    final at = DateTime(2026, 11, 17, 11);
    expect(count('requestNotificationPermission'), 1);
    expect(find.text(exactOff), findsOneWidget);
    expect(calls.lastWhere((c) => c.method == 'scheduleReminders').arguments, {
      'items': [
        {'id': 'a', 'title': '약 먹기', 'at': at.millisecondsSinceEpoch},
      ],
    });
    expect((await stored(tester)).items.single.at, at);
    expect(find.text('오늘 11:00'), findsOneWidget);

    await openTimeDialog(tester, 'a');
    await tester.tap(find.byKey(const ValueKey('reminder-repeat-daily')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('reminder-time-ok')));
    await settle(tester);
    expect(count('requestNotificationPermission'), 1);
    expect(find.text('매일 11:00'), findsOneWidget);
    expect((await stored(tester)).items.single.repeat, ReminderRepeat.daily);
    await unmount(tester);
  });

  testWidgets('the memo drawing is saved and sent to the widget', (
    tester,
  ) async {
    await seed(
      tester,
      const ReminderNote(
        items: [ReminderItem(id: 'a', text: '약 먹기', changedAt: 1)],
      ),
    );
    await mount(tester);
    await draw(tester);
    await settle(tester);

    final memo = (await stored(tester)).memo;
    expect(memo, hasLength(1));
    expect(memo.single.changedAt, greaterThan(0));
    final update =
        calls.lastWhere((c) => c.method == 'updateWidget').arguments as Map;
    expect(update['kind'], 'reminder');
    final payload =
        jsonDecode(update['payload'] as String) as Map<String, dynamic>;
    expect(payload['items'], [
      {'id': 'a', 'text': '약 먹기', 'at': null, 'done': false, 'order': 0},
    ]);
    expect(payload['memo']['aspect'], 2.5);
    expect(payload['memo']['strokes'], hasLength(1));
    await unmount(tester);
  });

  testWidgets('memo strokes drawn after a clear survive the next saves', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await store.writeReminders(
        const ReminderNote(
          memo: [
            InkStroke(points: [0.5, 0.5], color: 0xFF000000, width: 0.01),
          ],
        ),
      );
      await store.writeReminders(const ReminderNote());
    });
    await mount(tester);
    await draw(tester);
    await settle(tester);
    // The pad still holds the first stroke as it drew it, without the time
    // the store gave it.
    await draw(tester, 200);
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('reminder-add')));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '다음 저장');
    await settle(tester);

    expect((await stored(tester)).memo, hasLength(2));
    await unmount(tester);
  });

  testWidgets('clearing the memo and the finished tasks is saved', (
    tester,
  ) async {
    await seed(
      tester,
      const ReminderNote(
        items: [
          ReminderItem(id: 'open', text: '장보기', changedAt: 1),
          ReminderItem(
            id: 'finished',
            text: '빨래',
            done: true,
            order: 1,
            changedAt: 1,
          ),
        ],
        memo: [
          InkStroke(points: [0.5, 0.5], color: 0xFF000000, width: 0.01),
        ],
      ),
    );
    await mount(tester);
    await tester.tap(find.byKey(const ValueKey('reminder-memo-clear')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const ValueKey('reminder-memo-clear-ok')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const ValueKey('reminder-more')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const ValueKey('reminder-clear-done')));
    await settle(tester);

    final note = await stored(tester);
    expect(note.memo, isEmpty);
    expect([for (final item in note.items) item.id], ['open']);
    await unmount(tester);
  });

  testWidgets('leaving right after a change still saves it', (tester) async {
    await mount(tester);
    await tester.tap(find.byKey(const ValueKey('reminder-add')));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '마지막');
    await tester.pumpWidget(const SizedBox());
    for (var i = 0; i < 40 && count('scheduleReminders') == 0; i++) {
      await drain(tester);
    }

    expect((await stored(tester)).items.single.text, '마지막');
  });

  testWidgets('a change is saved five seconds later, or at once when the app '
      'goes to the background', (tester) async {
    addTearDown(() => changeLifecycle(tester, AppLifecycleState.resumed));
    await mount(tester);
    await tester.tap(find.byKey(const ValueKey('reminder-add')));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '배경');
    await tester.pump(const Duration(seconds: 4));
    await drain(tester);
    await drain(tester);
    expect(
      count('scheduleReminders'),
      0,
      reason: 'nothing is saved before five seconds',
    );

    changeLifecycle(tester, AppLifecycleState.paused);
    // Still under the five seconds: the save is the pause's.
    for (var i = 0; i < 16 && count('scheduleReminders') == 0; i++) {
      await drain(tester);
    }
    expect(count('scheduleReminders'), 1);
    expect((await stored(tester)).items.single.text, '배경');
    changeLifecycle(tester, AppLifecycleState.resumed);
    await unmount(tester);
  });

  testWidgets('a task added on another device shows and survives the next '
      'save', (tester) async {
    final changes = ValueNotifier(0);
    addTearDown(changes.dispose);
    await seed(
      tester,
      const ReminderNote(
        items: [ReminderItem(id: 'mine', text: '장보기', changedAt: 1)],
      ),
    );
    await mount(tester, changes: changes);
    await elsewhere(tester, (other) async {
      final note = await other.readReminders();
      await other.writeReminders(
        ReminderNote(
          items: [
            ...note.items,
            const ReminderItem(
              id: 'phone',
              text: '택배 받기',
              order: 1,
              changedAt: 2,
            ),
          ],
        ),
      );
    });
    // The workspace tells the page that the vault changed.
    changes.value++;
    final arrived = find.byKey(const ValueKey('reminder-item-phone'));
    for (var i = 0; i < 40 && arrived.evaluate().isEmpty; i++) {
      await drain(tester);
    }
    expect(arrived, findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('reminder-check-mine')));
    await settle(tester);
    final items = {
      for (final item in (await stored(tester)).items) item.id: item,
    };
    expect(items.keys, unorderedEquals(['mine', 'phone']));
    expect(items['mine']!.done, isTrue);
    expect(items['phone']!.text, '택배 받기');
    await unmount(tester);
  });

  testWidgets('a task and a memo stroke from another device survive a save '
      'that was waiting', (tester) async {
    final changes = ValueNotifier(0);
    addTearDown(changes.dispose);
    await mount(tester, changes: changes);
    await tester.tap(find.byKey(const ValueKey('reminder-add')));
    await tester.pump();
    await tester.enterText(find.byType(TextField), '태블릿');
    // They reach the vault before the five-second save.
    await elsewhere(
      tester,
      (other) => other.writeReminders(
        const ReminderNote(
          items: [
            ReminderItem(id: 'phone', text: '폰', order: 7, changedAt: 1),
          ],
          memo: [
            InkStroke(
              points: [0.1, 0.1, 0.2, 0.2],
              color: 0xFF000000,
              width: 0.01,
            ),
          ],
        ),
      ),
    );
    changes.value++;
    await settle(tester);

    final note = await stored(tester);
    expect({for (final item in note.items) item.text}, {'태블릿', '폰'});
    expect(note.memo, hasLength(1));
    // After its save the page reads the vault again and shows both.
    final arrived = find.byKey(const ValueKey('reminder-item-phone'));
    for (var i = 0; i < 40 && arrived.evaluate().isEmpty; i++) {
      await drain(tester);
    }
    expect(arrived, findsOneWidget);
    await unmount(tester);
  });
}
