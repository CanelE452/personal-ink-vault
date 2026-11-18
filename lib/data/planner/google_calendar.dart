import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:saber/data/planner/calendar_auth.dart';
import 'package:saber/data/planner/planner_models.dart';

class CalendarApiException implements Exception {
  const new(this.status, this.message);

  final int status;
  final String message;

  @override
  String toString() => 'Google Calendar $status: $message';
}

final class GoogleCalendarInfo {
  const new({
    required this.id,
    required this.name,
    required this.color,
    required this.selected,
    required this.writable,
  });

  final String id;
  final String name;

  /// ARGB.
  final int color;
  final bool selected;
  final bool writable;
}

/// Returns an access token. With [refresh] true the cached token is known to
/// be rejected and a new one must be obtained.
typedef CalendarTokenSource = Future<String> Function(bool refresh);

class GoogleCalendarApi {
  const new(this.token, {this._client});

  /// Token source backed by [auth]; a refresh drops the cached token first.
  factory fromAuth(CalendarAuth auth, {http.Client? client}) =>
      GoogleCalendarApi((refresh) async {
        if (refresh) await auth.invalidateToken();
        return auth.accessToken();
      }, client: client);

  final CalendarTokenSource token;
  final http.Client? _client;

  static const _maxPages = 20;

  Uri _uri(List<String> segments, [Map<String, String>? query]) => Uri(
    scheme: 'https',
    host: 'www.googleapis.com',
    pathSegments: ['calendar', 'v3', ...segments],
    queryParameters: query,
  );

  Future<Map<String, dynamic>> _send(
    String method,
    Uri uri, {
    Object? body,
  }) async {
    final client = _client ?? http.Client();
    try {
      for (var attempt = 0; ; attempt++) {
        final request = http.Request(method, uri)
          ..headers['authorization'] = 'Bearer ${await token(attempt > 0)}';
        if (body != null) {
          request.headers['content-type'] = 'application/json; charset=utf-8';
          request.body = jsonEncode(body);
        }
        final response = await http.Response.fromStream(
          await client.send(request),
        );
        if (response.statusCode == 401 && attempt == 0) continue;
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw CalendarApiException(
            response.statusCode,
            _errorMessage(response),
          );
        }
        if (response.bodyBytes.isEmpty) return const {};
        final decoded = jsonDecode(utf8.decode(response.bodyBytes));
        return decoded is Map<String, dynamic> ? decoded : const {};
      }
    } finally {
      if (_client == null) client.close();
    }
  }

  static String _errorMessage(http.Response response) {
    try {
      final error = (jsonDecode(
        utf8.decode(response.bodyBytes),
      ) as Map<String, dynamic>)['error'];
      if (error is Map && error['message'] is String) {
        return error['message'] as String;
      }
    } catch (_) {}
    return response.reasonPhrase ?? 'request failed';
  }

  Future<List<GoogleCalendarInfo>> calendars() async {
    final result = <GoogleCalendarInfo>[];
    String? page;
    for (var i = 0; i < _maxPages; i++) {
      final json = await _send(
        'GET',
        _uri(['users', 'me', 'calendarList'], {'pageToken': ?page}),
      );
      for (final item in (json['items'] as List? ?? const [])) {
        if (item is! Map || item['id'] is! String) continue;
        final role = item['accessRole'];
        result.add(
          GoogleCalendarInfo(
            id: item['id'] as String,
            name:
                (item['summaryOverride'] ?? item['summary'] ?? item['id'])
                    as String,
            color: _parseColor(item['backgroundColor']) ?? 0xFF3D5AFE,
            selected: item['selected'] == true,
            writable: role == 'owner' || role == 'writer',
          ),
        );
      }
      page = json['nextPageToken'] as String?;
      if (page == null) break;
    }
    return result;
  }

  Future<List<PlannerEvent>> events(
    String calendarId,
    DateTime from,
    DateTime to, {
    required int color,
  }) async {
    final result = <PlannerEvent>[];
    String? page;
    for (var i = 0; i < _maxPages; i++) {
      final json = await _send(
        'GET',
        _uri(
          ['calendars', calendarId, 'events'],
          {
            'singleEvents': 'true',
            'orderBy': 'startTime',
            'timeMin': from.toUtc().toIso8601String(),
            'timeMax': to.toUtc().toIso8601String(),
            'maxResults': '2500',
            'pageToken': ?page,
          },
        ),
      );
      for (final item in (json['items'] as List? ?? const [])) {
        if (item is! Map<String, dynamic> || item['status'] == 'cancelled') {
          continue;
        }
        final event = _parse(item, calendarId, color);
        if (event != null) result.add(event);
      }
      page = json['nextPageToken'] as String?;
      if (page == null) break;
    }
    return result;
  }

  Future<PlannerEvent> insert(String calendarId, PlannerEvent event) async {
    final json = await _send(
      'POST',
      _uri(['calendars', calendarId, 'events']),
      body: _body(event),
    );
    return _saved(json, calendarId, event);
  }

  Future<PlannerEvent> update(String calendarId, PlannerEvent event) async {
    final googleId = event.googleId;
    if (googleId == null) {
      throw ArgumentError.value(event.id, 'event', 'has no Google id');
    }
    final json = await _send(
      'PATCH',
      _uri(['calendars', calendarId, 'events', googleId]),
      body: _body(event, clearOtherKind: true),
    );
    return _saved(json, calendarId, event);
  }

  Future<void> delete(String calendarId, String googleId) async {
    try {
      await _send(
        'DELETE',
        _uri(['calendars', calendarId, 'events', googleId]),
      );
    } on CalendarApiException catch (e) {
      // Already gone on the server.
      if (e.status != 404 && e.status != 410) rethrow;
    }
  }

  PlannerEvent _saved(
    Map<String, dynamic> json,
    String calendarId,
    PlannerEvent sent,
  ) =>
      _parse(json, calendarId, sent.color) ??
      (throw const CalendarApiException(502, 'unexpected response'));

  static String _date(DateTime day) =>
      '${day.year.toString().padLeft(4, '0')}-'
      '${day.month.toString().padLeft(2, '0')}-'
      '${day.day.toString().padLeft(2, '0')}';

  /// With [clearOtherKind] (PATCH) the unused `date`/`dateTime` is sent as null
  /// so an event can switch between all-day and timed.
  static Map<String, Object?> _body(
    PlannerEvent event, {
    bool clearOtherKind = false,
  }) {
    if (event.allDay) {
      // Google's all-day end date is exclusive.
      final exclusiveEnd = DateTime(
        event.end.year,
        event.end.month,
        event.end.day + 1,
      );
      return {
        'summary': event.title,
        'start': {
          'date': _date(event.start),
          if (clearOtherKind) 'dateTime': null,
        },
        'end': {
          'date': _date(exclusiveEnd),
          if (clearOtherKind) 'dateTime': null,
        },
      };
    }
    return {
      'summary': event.title,
      'start': {
        'dateTime': event.start.toUtc().toIso8601String(),
        if (clearOtherKind) 'date': null,
      },
      'end': {
        'dateTime': event.end.toUtc().toIso8601String(),
        if (clearOtherKind) 'date': null,
      },
    };
  }

  static PlannerEvent? _parse(
    Map<String, dynamic> item,
    String calendarId,
    int color,
  ) {
    final id = item['id'];
    final start = item['start'], end = item['end'];
    if (id is! String || start is! Map || end is! Map) return null;
    final updated = DateTime.tryParse('${item['updated']}');
    final title = item['summary'] is String ? item['summary'] as String : '';
    if (start['date'] is String) {
      final first = DateTime.tryParse(start['date'] as String);
      final exclusive = DateTime.tryParse('${end['date']}');
      if (first == null) return null;
      var last = exclusive == null
          ? first
          : DateTime(exclusive.year, exclusive.month, exclusive.day - 1);
      if (last.isBefore(first)) last = first;
      return PlannerEvent(
        id: id,
        title: title,
        start: first,
        end: last,
        color: color,
        calendarId: calendarId,
        googleId: id,
        changedAt: updated?.millisecondsSinceEpoch ?? 0,
      );
    }
    final first = DateTime.tryParse('${start['dateTime']}');
    if (first == null) return null;
    final last = DateTime.tryParse('${end['dateTime']}') ?? first;
    return PlannerEvent(
      id: id,
      title: title,
      start: first.toLocal(),
      end: last.toLocal(),
      allDay: false,
      color: color,
      calendarId: calendarId,
      googleId: id,
      changedAt: updated?.millisecondsSinceEpoch ?? 0,
    );
  }

  static int? _parseColor(Object? hex) {
    if (hex is! String) return null;
    final match = RegExp(r'^#([0-9a-fA-F]{6})$').firstMatch(hex);
    if (match == null) return null;
    return 0xFF000000 | int.parse(match.group(1)!, radix: 16);
  }
}
