import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/drive/drive_connection.dart';
import 'package:saber/data/planner/calendar_auth.dart';
import 'package:saber/data/planner/planner_models.dart';
import 'package:saber/data/planner/planner_platform.dart';
import 'package:saber/data/planner/planner_store.dart';
import 'package:saber/data/planner/planner_widget_sync.dart';
import 'package:saber/data/planner/widget_payload.dart';

/// Signed in or not, as the test says; remembers being closed.
class _Auth extends CalendarAuth {
  new(this.clientId);

  final String clientId;
  var signedIn = false;
  var closed = false;

  @override
  bool get connected => signedIn;

  @override
  Future<void> restore() async {}

  @override
  Future<void> connect() async => signedIn = true;

  @override
  Future<String> accessToken() async => 'token';

  @override
  Future<void> disconnect() async => signedIn = false;

  @override
  void close() => closed = true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final timed = DateTime(2026, 11, 18, 12);

  late Directory temporary;
  late NoteRepository repository;
  late PlannerStore store;
  late List<MethodCall> calls;
  late bool failing;
  late PlannerPlatform platform;
  late DateTime today;
  late PlannerWidgetSync sync;

  setUp(() async {
    final owner = Directory.systemTemp;
    temporary = await owner.createTemp('piv-widget-sync-');
    addTearDown(() async {
      final resolved = await temporary.resolveSymbolicLinks();
      expect(p.basename(resolved), startsWith('piv-widget-sync-'));
      await Directory(resolved).delete(recursive: true);
    });
    repository = await NoteRepository.open(
      Directory(p.join(temporary.path, 'vault')),
      createFormatVersion: 2,
    );
    addTearDown(repository.close);
    store = PlannerStore(repository);
    calls = [];
    failing = false;
    messenger.setMockMethodCallHandler(PlannerPlatform.channel, (call) async {
      calls.add(call);
      if (failing) throw PlatformException(code: 'broken');
      return call.method == 'scheduleReminders'
          ? {'granted': true, 'exact': true}
          : null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(PlannerPlatform.channel, null),
    );
    platform = PlannerPlatform();
    today = DateTime(2026, 11, 18, 10);
    sync = PlannerWidgetSync(platform: platform, now: () => today);
    addTearDown(sync.dispose);
  });

  List<String> sent() => [
    for (final call in calls)
      if (call.method == 'updateWidget')
        'updateWidget ${(call.arguments as Map)['kind']}'
      else
        call.method,
  ];

  const both = ['updateWidget reminder', 'updateWidget calendar'];

  Map<String, dynamic> payload(String kind) =>
      jsonDecode(
            (calls
                        .lastWhere(
                          (call) =>
                              call.method == 'updateWidget' &&
                              (call.arguments as Map)['kind'] == kind,
                        )
                        .arguments
                    as Map)['payload']
                as String,
          )
          as Map<String, dynamic>;

  Future<void> writeTimedTask() => store.writeReminders(
    ReminderNote(
      items: [ReminderItem(id: 'pill', text: '약 먹기', at: timed, changedAt: 1)],
    ),
  );

  test('a send with the same heads calls nothing', () async {
    await writeTimedTask();
    await sync.send(repository);
    expect(sent(), [...both, 'scheduleReminders']);

    calls.clear();
    await sync.send(repository);
    expect(calls, isEmpty);
  });

  test('a changed reminder head sends both widgets and the alarms', () async {
    await sync.send(repository);
    calls.clear();

    await writeTimedTask();
    await sync.send(repository);
    expect(sent(), [...both, 'scheduleReminders']);
    expect(calls.last.arguments, {
      'items': [
        {'id': 'pill', 'title': '약 먹기', 'at': timed.millisecondsSinceEpoch},
      ],
    });
  });

  test('changed ink alone sends the widgets but not the same alarms', () async {
    await writeTimedTask();
    await sync.send(repository);
    calls.clear();

    await store.writeInk({
      '2026-11': const MonthInk(
        month: '2026-11',
        strokes: [
          InkStroke(
            points: [0.1, 0.1, 0.2, 0.2],
            color: 0xFF202124,
            width: 0.006,
          ),
        ],
      ),
    });
    await sync.send(repository);
    expect(sent(), both);
    expect((payload('calendar')['months'] as Map).keys, ['2026-11']);
  });

  test('alarms the reminder screen scheduled count as sent', () async {
    await writeTimedTask();
    // The screen's own save schedules them first.
    await platform.scheduleReminders(
      reminderAlarms(shownReminders(await store.readReminders()), today),
    );
    calls.clear();

    await sync.send(repository);
    expect(sent(), both);
  });

  test('another vault, a new day or a failed send sends again', () async {
    await writeTimedTask();
    await sync.send(repository);

    // Another vault with nothing in it: its widgets, and no alarms left.
    final other = await NoteRepository.open(
      Directory(p.join(temporary.path, 'other')),
      createFormatVersion: 2,
    );
    addTearDown(other.close);
    calls.clear();
    await sync.send(other);
    expect(sent(), [...both, 'scheduleReminders']);
    expect(calls.last.arguments, {'items': <Object>[]});

    // Back on the first vault the next day the task's time has passed.
    calls.clear();
    await sync.send(repository);
    expect(sent(), [...both, 'scheduleReminders']);
    calls.clear();
    today = DateTime(2026, 11, 19, 10);
    await sync.send(repository);
    expect(sent(), [...both, 'scheduleReminders']);
    expect(calls.last.arguments, {'items': <Object>[]});

    // A send that failed is not remembered.
    await store.writeReminders(const ReminderNote());
    failing = true;
    await sync.send(repository);
    failing = false;
    calls.clear();
    await sync.send(repository);
    expect(sent(), both);
    expect(payload('reminder')['items'], isEmpty);
  });

  group('Google Calendar', () {
    late DriveConnectionController drive;
    late List<_Auth> made;
    late bool signIn;

    setUp(() async {
      drive = DriveConnectionController(
        repository: () => repository,
        onRepositoryChanged: (_) async {},
        onRemoteUpdated: () async {},
        onResumeReload: () async {},
        directoryProvider: () async =>
            Directory(p.join(temporary.path, 'drive')),
      );
      addTearDown(drive.close);
      await drive.initialize();
      drive.settings
        ..androidServerClientId = 'client-a'
        ..desktopClientId = 'client-a';
      made = [];
      signIn = false;
      sync = PlannerWidgetSync(
        platform: platform,
        drive: () => drive,
        supportDirectory: () async =>
            Directory(p.join(temporary.path, 'support')),
        createAuth:
            ({required androidServerClientId, required desktopClientId}) {
              final auth = _Auth(desktopClientId)..signedIn = signIn;
              made.add(auth);
              return auth;
            },
        now: () => today,
      );
      addTearDown(sync.dispose);
    });

    test('without a client id there is no Google calendar', () async {
      drive.settings
        ..androidServerClientId = ''
        ..desktopClientId = '';
      final none = PlannerWidgetSync(
        platform: platform,
        drive: () => drive,
        supportDirectory: () async =>
            Directory(p.join(temporary.path, 'support')),
        now: () => today,
      );
      addTearDown(none.dispose);
      expect(await none.googleCalendar(), isNull);
    });

    test('another client id makes a new sign-in and closes the last one', () async {
      final first = await sync.googleCalendar();
      final again = await sync.googleCalendar();
      expect(again!.auth, same(first!.auth));
      expect(again.sync, same(first.sync));
      expect(made, hasLength(1));

      drive.settings.desktopClientId = 'client-b';
      drive.settings.androidServerClientId = 'client-b';
      final second = await sync.googleCalendar();
      expect(made, hasLength(2));
      expect(made.first.closed, isTrue);
      expect(second!.auth, same(made.last));
      expect(made.last.closed, isFalse);
    });

    test("a connected calendar's cached events are sent, and a change in "
        'them sends again', () async {
      signIn = true;
      final google = (await sync.googleCalendar())!;
      expect(google.auth.connected, isTrue);
      final cache = Directory(p.join(temporary.path, 'support', 'planner'))
        ..createSync(recursive: true);
      void cacheNovember(List<String> titles) =>
          File(p.join(cache.path, 'google-2026-11.json')).writeAsStringSync(
            jsonEncode([
              for (final (index, title) in titles.indexed)
                PlannerEvent(
                  id: 'g$index',
                  title: title,
                  start: DateTime(2026, 11, 5 + index),
                  end: DateTime(2026, 11, 5 + index),
                  calendarId: 'me',
                  googleId: 'g$index',
                ).toJson(),
            ]),
          );

      cacheNovember(['점심']);
      await sync.send(repository);
      List<Object?> titles() => [
        for (final event in payload('calendar')['events'] as List)
          (event as Map)['title'],
      ];
      expect(titles(), ['점심']);

      calls.clear();
      await sync.send(repository);
      expect(calls, isEmpty);

      cacheNovember(['점심', '저녁']);
      await sync.send(repository);
      expect(sent(), both);
      expect(titles(), ['점심', '저녁']);
    });
  });
}
