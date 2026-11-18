import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:saber/data/planner/google_calendar.dart';
import 'package:saber/data/planner/planner_models.dart';

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

GoogleCalendarApi _api(MockClient client, [List<bool>? refreshes]) =>
    GoogleCalendarApi((refresh) async {
      refreshes?.add(refresh);
      return refresh ? 'fresh' : 'stale';
    }, client: client);

void main() {
  test(
    'reads all-day events with an exclusive end as an inclusive last day',
    () async {
      late http.Request seen;
      final api = _api(
        MockClient((request) async {
          seen = request;
          return _json({
            'items': [
              {
                'id': 'g1',
                'summary': 'Trip',
                'start': {'date': '2026-11-10'},
                'end': {'date': '2026-11-13'},
              },
              {
                'id': 'g2',
                'status': 'cancelled',
                'start': {'date': '2026-11-10'},
                'end': {'date': '2026-11-11'},
              },
            ],
          });
        }),
      );
      final events = await api.events(
        'primary',
        DateTime(2026, 11),
        DateTime(2026, 12),
        color: 0xFF112233,
      );
      expect(events, hasLength(1));
      final event = events.single;
      expect(event.allDay, isTrue);
      expect(event.start, DateTime(2026, 11, 10));
      expect(event.end, DateTime(2026, 11, 12));
      expect(event.googleId, 'g1');
      expect(event.calendarId, 'primary');
      expect(event.color, 0xFF112233);
      expect(event.title, 'Trip');
      expect(seen.url.path, '/calendar/v3/calendars/primary/events');
      expect(seen.url.queryParameters['singleEvents'], 'true');
      expect(seen.url.queryParameters['orderBy'], 'startTime');
      expect(seen.headers['authorization'], 'Bearer stale');
    },
  );

  test('reads timed events and follows pages', () async {
    var calls = 0;
    final api = _api(
      MockClient((request) async {
        calls++;
        if (request.url.queryParameters['pageToken'] == null) {
          return _json({
            'nextPageToken': 'p2',
            'items': [
              {
                'id': 'a',
                'summary': 'Standup',
                'start': {'dateTime': '2026-11-10T09:00:00+09:00'},
                'end': {'dateTime': '2026-11-10T09:30:00+09:00'},
              },
            ],
          });
        }
        return _json({
          'items': [
            {
              'id': 'b',
              'start': {'dateTime': '2026-11-11T09:00:00Z'},
              'end': {'dateTime': '2026-11-11T10:00:00Z'},
            },
          ],
        });
      }),
    );
    final events = await api.events(
      'work@example.com',
      DateTime(2026, 11),
      DateTime(2026, 12),
      color: 1,
    );
    expect(calls, 2);
    expect(events.map((e) => e.googleId), ['a', 'b']);
    expect(events.first.allDay, isFalse);
    expect(events.first.start.toUtc(), DateTime.utc(2026, 11, 10));
    expect(events.first.end.difference(events.first.start).inMinutes, 30);
    expect(events.last.title, '');
  });

  test('retries once with a fresh token after 401', () async {
    final tokens = <String?>[];
    final refreshes = <bool>[];
    final api = _api(
      MockClient((request) async {
        tokens.add(request.headers['authorization']);
        if (tokens.length == 1) {
          return _json({
            'error': {'message': 'expired'},
          }, 401);
        }
        return _json({'items': []});
      }),
      refreshes,
    );
    expect(await api.calendars(), isEmpty);
    expect(tokens, ['Bearer stale', 'Bearer fresh']);
    expect(refreshes, [false, true]);
  });

  test('does not retry a second 401', () async {
    var calls = 0;
    final api = _api(
      MockClient((request) async {
        calls++;
        return _json({
          'error': {'message': 'nope'},
        }, 401);
      }),
    );
    await expectLater(
      api.calendars(),
      throwsA(
        isA<CalendarApiException>()
            .having((e) => e.status, 'status', 401)
            .having((e) => e.message, 'message', 'nope'),
      ),
    );
    expect(calls, 2);
  });

  test('lists calendars with colour, selection and write access', () async {
    final api = _api(
      MockClient((request) async {
        expect(request.url.path, '/calendar/v3/users/me/calendarList');
        return _json({
          'items': [
            {
              'id': 'me',
              'summary': 'Me',
              'summaryOverride': 'My calendar',
              'backgroundColor': '#0b8043',
              'selected': true,
              'accessRole': 'owner',
            },
            {'id': 'holidays', 'summary': 'Holidays', 'accessRole': 'reader'},
          ],
        });
      }),
    );
    final list = await api.calendars();
    expect(list.first.name, 'My calendar');
    expect(list.first.color, 0xFF0B8043);
    expect(list.first.selected, isTrue);
    expect(list.first.writable, isTrue);
    expect(list.last.selected, isFalse);
    expect(list.last.writable, isFalse);
  });

  test('inserts an all-day event with an exclusive end date', () async {
    late http.Request seen;
    final api = _api(
      MockClient((request) async {
        seen = request;
        return _json({
          'id': 'new1',
          'summary': 'Trip',
          'start': {'date': '2026-11-10'},
          'end': {'date': '2026-11-13'},
        });
      }),
    );
    final saved = await api.insert(
      'primary',
      PlannerEvent(
        id: 'local',
        title: 'Trip',
        start: DateTime(2026, 11, 10),
        end: DateTime(2026, 11, 12),
        color: 0xFF010203,
      ),
    );
    expect(seen.method, 'POST');
    expect(seen.url.path, '/calendar/v3/calendars/primary/events');
    expect(jsonDecode(seen.body), {
      'summary': 'Trip',
      'start': {'date': '2026-11-10'},
      'end': {'date': '2026-11-13'},
    });
    expect(saved.googleId, 'new1');
    expect(saved.end, DateTime(2026, 11, 12));
    expect(saved.color, 0xFF010203);
  });

  test('inserts a timed event with dateTime', () async {
    late http.Request seen;
    final api = _api(
      MockClient((request) async {
        seen = request;
        return _json({
          'id': 'new2',
          'start': {'dateTime': '2026-11-10T00:00:00Z'},
          'end': {'dateTime': '2026-11-10T01:00:00Z'},
        });
      }),
    );
    final start = DateTime.utc(2026, 11, 10);
    await api.insert(
      'primary',
      PlannerEvent(
        id: 'x',
        title: 'Call',
        start: start.toLocal(),
        end: start.add(const Duration(hours: 1)).toLocal(),
        allDay: false,
      ),
    );
    final body = jsonDecode(seen.body) as Map<String, dynamic>;
    final startJson = body['start'] as Map<String, dynamic>;
    expect(DateTime.parse(startJson['dateTime'] as String), start);
    expect(startJson.containsKey('date'), isFalse);
  });

  test(
    'updates by google id and deletes, tolerating an already deleted event',
    () async {
      final seen = <String>[];
      final api = _api(
        MockClient((request) async {
          seen.add('${request.method} ${request.url.path}');
          if (request.method == 'DELETE') return http.Response('', 410);
          return _json({
            'id': 'g9',
            'summary': 'Renamed',
            'start': {'date': '2026-11-10'},
            'end': {'date': '2026-11-11'},
          });
        }),
      );
      final updated = await api.update(
        'primary',
        PlannerEvent(
          id: 'g9',
          title: 'Renamed',
          start: DateTime(2026, 11, 10),
          end: DateTime(2026, 11, 10),
          googleId: 'g9',
        ),
      );
      expect(updated.title, 'Renamed');
      await api.delete('primary', 'g9');
      expect(seen, [
        'PATCH /calendar/v3/calendars/primary/events/g9',
        'DELETE /calendar/v3/calendars/primary/events/g9',
      ]);
    },
  );

  test('patching across all-day and timed clears the other field', () async {
    final bodies = <Map<String, dynamic>>[];
    final api = _api(
      MockClient((request) async {
        bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
        return _json({
          'id': 'g',
          'start': {'date': '2026-11-10'},
          'end': {'date': '2026-11-11'},
        });
      }),
    );
    await api.update(
      'primary',
      PlannerEvent(
        id: 'g',
        title: 't',
        start: DateTime(2026, 11, 10),
        end: DateTime(2026, 11, 10),
        googleId: 'g',
      ),
    );
    await api.update(
      'primary',
      PlannerEvent(
        id: 'g',
        title: 't',
        start: DateTime(2026, 11, 10, 9),
        end: DateTime(2026, 11, 10, 10),
        allDay: false,
        googleId: 'g',
      ),
    );
    expect(bodies[0]['start'], {'date': '2026-11-10', 'dateTime': null});
    expect(bodies[0]['end'], {'date': '2026-11-11', 'dateTime': null});
    for (final side in ['start', 'end']) {
      final map = bodies[1][side] as Map<String, dynamic>;
      expect(map.containsKey('date') && map['date'] == null, isTrue);
      expect(map['dateTime'], isA<String>());
    }
  });
}
