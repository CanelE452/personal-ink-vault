import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:saber/data/planner/calendar_sync.dart';
import 'package:saber/data/planner/google_calendar.dart';
import 'package:saber/data/planner/planner_models.dart';

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status);

GoogleCalendarApi _api(Future<http.Response> Function(http.Request) handler) =>
    GoogleCalendarApi((_) async => 't', client: MockClient(handler));

Future<http.Response> _server(http.Request request) async {
  final path = request.url.path;
  if (path.endsWith('/calendarList')) {
    return _json({
      'items': [
        {
          'id': 'cal',
          'summary': 'Cal',
          'backgroundColor': '#112233',
          'selected': true,
          'accessRole': 'owner',
        },
        {'id': 'hidden', 'summary': 'Hidden', 'selected': false},
      ],
    });
  }
  if (path == '/calendar/v3/calendars/cal/events' && request.method == 'GET') {
    return _json({
      'items': [
        {
          'id': 'e1',
          'summary': 'Lunch',
          'start': {'date': '2026-11-05'},
          'end': {'date': '2026-11-06'},
        },
      ],
    });
  }
  if (request.method == 'POST') {
    return _json({
      'id': 'new',
      'summary': 'Made',
      'start': {'date': '2026-11-07'},
      'end': {'date': '2026-11-08'},
    });
  }
  return http.Response('', 204);
}

Future<http.Response> _failing(http.Request request) async => _json({
  'error': {'message': 'down'},
}, 500);

PlannerEvent _event({String? calendarId}) => PlannerEvent(
  id: 'local',
  title: 'Made',
  start: DateTime(2026, 11, 7),
  end: DateTime(2026, 11, 7),
  calendarId: calendarId,
);

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('cal_sync_test'));
  tearDown(() => dir.deleteSync(recursive: true));

  final november = DateTime(2026, 11);
  File cacheFile() => File('${dir.path}/google-2026-11.json');
  CalendarSync offline() => CalendarSync(cacheDir: dir, api: () async => null);
  CalendarSync online(Future<http.Response> Function(http.Request) h) =>
      CalendarSync(cacheDir: dir, api: () async => _api(h));

  test('without a connection returns the cache and records an error', () async {
    cacheFile().writeAsStringSync(
      jsonEncode([
        PlannerEvent(
          id: 'c',
          title: 'Cached',
          start: DateTime(2026, 11, 2),
          end: DateTime(2026, 11, 2),
          googleId: 'c',
        ).toJson(),
      ]),
    );
    final sync = offline();
    final events = await sync.month(november, refresh: true);
    expect(events.single.title, 'Cached');
    expect(sync.lastError, isNotNull);
  });

  test('without a connection or cache returns an empty month', () async {
    expect(await offline().month(november), isEmpty);
  });

  test(
    'a fresh fetch updates the cache and uses only selected calendars',
    () async {
      final sync = online(_server);
      final events = await sync.month(november);
      expect(events.single.title, 'Lunch');
      expect(events.single.calendarId, 'cal');
      expect(events.single.color, 0xFF112233);
      expect(sync.lastError, isNull);
      expect(cacheFile().existsSync(), isTrue);

      // A cached month is served without the network unless refresh is asked.
      final cached = CalendarSync(
        cacheDir: dir,
        api: () async => throw StateError('should not be called'),
      );
      expect((await cached.month(november)).single.title, 'Lunch');
    },
  );

  test('a failed refresh keeps the cache and records the error', () async {
    await online(_server).month(november);
    final failing = online(_failing);
    final events = await failing.month(november, refresh: true);
    expect(events.single.title, 'Lunch');
    expect(failing.lastError, contains('down'));
  });

  test('save inserts and adds the event to the cached month', () async {
    final sync = online(_server);
    await sync.month(november);
    final saved = await sync.save(_event(calendarId: 'cal'));
    expect(saved.googleId, 'new');
    final cached = await offline().month(november);
    expect(cached.map((e) => e.googleId), containsAll(['e1', 'new']));
  });

  test('a failed save throws and leaves the cache as it was', () async {
    await online(_server).month(november);
    final before = cacheFile().readAsStringSync();
    await expectLater(
      online(_failing).save(_event()),
      throwsA(isA<CalendarApiException>()),
    );
    expect(cacheFile().readAsStringSync(), before);
  });

  test('saving without a connection throws and keeps the cache', () async {
    await online(_server).month(november);
    final before = cacheFile().readAsStringSync();
    await expectLater(offline().save(_event()), throwsA(isA<StateError>()));
    expect(cacheFile().readAsStringSync(), before);
  });

  test('remove deletes remotely and drops the event from the cache', () async {
    final sync = online(_server);
    final events = await sync.month(november);
    await sync.remove(events.single);
    expect(await offline().month(november), isEmpty);
  });

  test('clear removes every cached month', () async {
    final sync = online(_server);
    await sync.month(november);
    await sync.clear();
    expect(cacheFile().existsSync(), isFalse);
    expect(await offline().month(november), isEmpty);
  });

  test('a cache write error after Google accepted the save is only noted', () async {
    final sync = online(_server);
    await sync.month(november);
    // Make the temp path unusable so the mirror write fails.
    Directory('${cacheFile().path}.tmp').createSync();
    final saved = await sync.save(_event(calendarId: 'cal'));
    expect(saved.googleId, 'new');
    expect(sync.lastError, isNotNull);
  });

  test('concurrent saves leave a readable cache with both events', () async {
    final sync = online(_server);
    await sync.month(november);
    await Future.wait([
      sync.save(_event(calendarId: 'cal')),
      sync.save(_event(calendarId: 'cal')),
    ]);
    final cached = await offline().month(november);
    expect(cached.where((e) => e.googleId == 'new'), hasLength(1));
    expect(cached.any((e) => e.googleId == 'e1'), isTrue);
  });
}
