import 'dart:convert';
import 'dart:io';

import 'package:saber/data/planner/google_calendar.dart';
import 'package:saber/data/planner/planner_models.dart';

/// Month cache of Google Calendar events in `<cacheDir>/google-yyyy-MM.json`.
class CalendarSync {
  new({required this.cacheDir, required this.api});

  final Directory cacheDir;

  /// Null when the calendar is not connected.
  final Future<GoogleCalendarApi?> Function() api;

  /// Why the last [month] call could not use the network, or null.
  String? lastError;

  static const _notConnected = 'Google 캘린더에 연결되어 있지 않습니다.';

  static String _key(DateTime month) =>
      '${month.year.toString().padLeft(4, '0')}-'
      '${month.month.toString().padLeft(2, '0')}';

  File _file(String key) => File('${cacheDir.path}/google-$key.json');

  /// Events of [month]. A cached month is returned as is unless [refresh] is
  /// set; without a connection or on failure the cache is returned and
  /// [lastError] says why.
  Future<List<PlannerEvent>> month(
    DateTime month, {
    bool refresh = false,
  }) async {
    final key = _key(month);
    final cached = await _read(key);
    lastError = null;
    if (!refresh && cached != null) return cached;
    try {
      final client = await api();
      if (client == null) {
        lastError = _notConnected;
        return cached ?? const [];
      }
      final from = DateTime(month.year, month.month);
      final to = DateTime(month.year, month.month + 1);
      final events = <PlannerEvent>[];
      for (final calendar in await client.calendars()) {
        if (!calendar.selected) continue;
        events.addAll(
          await client.events(calendar.id, from, to, color: calendar.color),
        );
      }
      events.sort((a, b) => a.start.compareTo(b.start));
      await _write(key, events);
      return events;
    } catch (e) {
      lastError = e is CalendarApiException ? e.message : '$e';
      return cached ?? const [];
    }
  }

  /// The cached events of [month], without asking Google; null when that
  /// month was never fetched.
  Future<List<PlannerEvent>?> cached(DateTime month) => _read(_key(month));

  /// Inserts or updates [event] on Google and mirrors it into cached months.
  /// Throws when it cannot be saved; the cache is left untouched then.
  Future<PlannerEvent> save(PlannerEvent event) async {
    final client = await _connected();
    final calendarId = event.calendarId ?? 'primary';
    final saved = event.googleId == null
        ? await client.insert(calendarId, event)
        : await client.update(calendarId, event);
    await _mirror(remove: saved.googleId, add: saved);
    return saved;
  }

  Future<void> remove(PlannerEvent event) async {
    final googleId = event.googleId;
    if (googleId == null) {
      throw ArgumentError.value(event.id, 'event', 'has no Google id');
    }
    final client = await _connected();
    await client.delete(event.calendarId ?? 'primary', googleId);
    await _mirror(remove: googleId);
  }

  Future<GoogleCalendarApi> _connected() async =>
      await api() ?? (throw StateError(_notConnected));

  /// Deletes every cached month, e.g. when the calendar is disconnected so a
  /// later account never sees the previous account's events.
  Future<void> clear() => _serial(() async {
    if (!cacheDir.existsSync()) return;
    for (final entity in cacheDir.listSync()) {
      if (entity is File &&
          RegExp(r'^google-.*\.json(\.tmp)?$').hasMatch(entity.uri.pathSegments.last)) {
        await entity.delete();
      }
    }
  });

  var _queue = Future<void>.value();

  // One cache mutation at a time, so writers never share a `.tmp` file.
  Future<T> _serial<T>(Future<T> Function() action) {
    final run = _queue.then((_) => action());
    _queue = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

  /// Google already holds the change by now, so a disk error is only noted.
  Future<void> _mirror({String? remove, PlannerEvent? add}) async {
    try {
      await _serial(() => _mirrorNow(remove: remove, add: add));
    } catch (e) {
      lastError = '$e';
    }
  }

  Future<void> _mirrorNow({String? remove, PlannerEvent? add}) async {
    final touched = <String>{};
    if (add != null) {
      var day = DateTime(add.start.year, add.start.month);
      final last = DateTime(add.end.year, add.end.month);
      while (!day.isAfter(last)) {
        touched.add(_key(day));
        day = DateTime(day.year, day.month + 1);
      }
    }
    if (!cacheDir.existsSync()) return;
    for (final entity in cacheDir.listSync()) {
      final name = entity.uri.pathSegments.last;
      final match = RegExp(r'^google-(\d{4}-\d{2})\.json$').firstMatch(name);
      if (entity is! File || match == null) continue;
      final key = match.group(1)!;
      final events = await _read(key);
      if (events == null) continue;
      final next = [
        for (final e in events)
          if (e.googleId == null || e.googleId != remove) e,
        if (add != null && touched.contains(key)) add,
      ]..sort((a, b) => a.start.compareTo(b.start));
      await _writeNow(key, next);
    }
  }

  Future<List<PlannerEvent>?> _read(String key) async {
    final file = _file(key);
    try {
      if (!file.existsSync()) return null;
      final json = jsonDecode(await file.readAsString());
      if (json is! List) return null;
      return [for (final item in json) PlannerEvent.fromJson(item)];
    } catch (_) {
      return null;
    }
  }

  Future<void> _write(String key, List<PlannerEvent> events) =>
      _serial(() => _writeNow(key, events));

  Future<void> _writeNow(String key, List<PlannerEvent> events) async {
    await cacheDir.create(recursive: true);
    final target = _file(key);
    final temp = File('${target.path}.tmp');
    await temp.writeAsString(
      jsonEncode([for (final event in events) event.toJson()]),
      flush: true,
    );
    await temp.rename(target.path);
  }
}
