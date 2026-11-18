import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:saber/data/drive/drive_connection.dart';
import 'package:saber/data/planner/calendar_auth.dart';
import 'package:saber/data/planner/calendar_sync.dart';
import 'package:saber/data/planner/google_calendar.dart';
import 'package:saber/data/planner/planner_models.dart';
import 'package:saber/data/planner/planner_platform.dart';
import 'package:saber/data/planner/planner_store.dart';
import 'package:saber/data/planner/widget_payload.dart';

/// Google Calendar as the calendar screen and its widget use it.
typedef GoogleCalendar = ({CalendarAuth auth, CalendarSync sync});

/// Keeps Android's home-screen widgets and reminder alarms fed from the open
/// vault (설계 6·7절), so the widgets show it even when its screens were never
/// opened. A send reads the planner only when something it is made from
/// changed since the last send: the vault, the heads of the planner's three
/// entities, the day, or Google Calendar's cached events. The alarms are
/// scheduled again only when their list differs from the last one scheduled,
/// by this or by the reminder screen.
class PlannerWidgetSync {
  new({
    required this.platform,
    this.drive,
    this.supportDirectory = getApplicationSupportDirectory,
    this.createAuth = CalendarAuth.platform,
    this.now = DateTime.now,
  });

  final PlannerPlatform platform;

  /// Drive's connection, whose OAuth client signs in to Google Calendar too;
  /// null without Drive.
  final DriveConnectionController? Function()? drive;

  /// The app's support folder; Google Calendar's months are cached in its
  /// `planner` folder.
  final Future<Directory> Function() supportDirectory;

  final CalendarAuth Function({
    required String androidServerClientId,
    required String desktopClientId,
  })
  createAuth;

  /// The clock; tests replace it.
  final DateTime Function() now;

  static final _log = Logger('PIVPlanner');

  ({
    String android,
    String desktop,
    CalendarAuth auth,
    CalendarSync sync,
    Future<void> restored,
  })?
  _google;
  Future<Directory>? _support;

  /// What the last successful send was made from.
  Object? _sent;
  var _sends = Future<void>.value();

  /// Sends [repository]'s planner when something it is made from changed
  /// since the last send. Sends follow one another; a failure is only
  /// logged, and the next call tries again. A send is dropped once
  /// [isCurrent] says its vault is no longer the open one.
  Future<void> send(NoteRepository repository, {bool Function()? isCurrent}) =>
      _sends = _sends.then((_) => _send(repository, isCurrent ?? () => true));

  Future<void> _send(
    NoteRepository repository,
    bool Function() isCurrent,
  ) async {
    try {
      final at = now();
      final heads = [
        for (final id in const [
          PlannerStore.remindersId,
          PlannerStore.eventsId,
          PlannerStore.inkId,
        ])
          [for (final head in await repository.heads(id)) head.revisionId]
            ..sort(),
      ];
      final google = await _googleEvents(at);
      final inputs = (
        repository,
        '${at.year}-${at.month}-${at.day}',
        jsonEncode(heads),
        google == null
            ? null
            : jsonEncode([for (final event in google) event.toJson()]),
      );
      if (inputs == _sent || !isCurrent()) return;
      final store = PlannerStore(repository);
      final note = shownReminders(await store.readReminders());
      final events = await store.readEvents();
      final ink = await store.readInk();
      if (!isCurrent()) return;
      await platform.updateWidget(
        'reminder',
        reminderWidgetPayload(note, now: at),
      );
      await platform.updateWidget(
        'calendar',
        calendarWidgetPayload(
          today: at,
          events: [...events, ...?google],
          ink: ink,
        ),
      );
      final alarms = reminderAlarms(note, at);
      if (jsonEncode(alarms) != platform.lastAlarms) {
        await platform.scheduleReminders(alarms);
      }
      _sent = inputs;
    } catch (error, stackTrace) {
      _log.warning(
        'The planner widgets were not updated: $error',
        error,
        stackTrace,
      );
    }
  }

  /// Google Calendar's cached events of last, this and next month, as the
  /// calendar screen sends them; null when Google is not connected.
  Future<List<PlannerEvent>?> _googleEvents(DateTime at) async {
    final google = await googleCalendar();
    if (google == null || !google.auth.connected) return null;
    final events = <String, PlannerEvent>{};
    for (var month = -1; month <= 1; month++) {
      final cached = await google.sync.cached(
        DateTime(at.year, at.month + month),
      );
      for (final event in cached ?? const <PlannerEvent>[]) {
        events[event.id] = event;
      }
    }
    return events.values.toList();
  }

  /// Google Calendar for the calendar screen and its widget, signed in with
  /// Drive's OAuth client and restored once. Null without Drive, before Drive
  /// has read its settings (start-up waits for that a moment), or without a
  /// client id for this platform: the calendar then leaves Google out.
  Future<GoogleCalendar?> googleCalendar() async {
    final drive = this.drive?.call();
    if (drive == null) return null;
    for (var i = 0; i < 30 && !drive.ready && drive.busy; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (!drive.ready) return null;
    final Directory support;
    try {
      support = await (_support ??= supportDirectory());
    } catch (error) {
      _support = null;
      _log.warning('Google Calendar has no cache folder: $error');
      return null;
    }
    final android = drive.settings.androidServerClientId;
    final desktop = drive.settings.desktopClientId;
    var google = _google;
    if (google == null ||
        google.android != android ||
        google.desktop != desktop) {
      // Another client: the last sign-in lets go of its connection.
      google?.auth.close();
      _google = null;
      final CalendarAuth auth;
      try {
        auth = createAuth(
          androidServerClientId: android,
          desktopClientId: desktop,
        );
      } catch (_) {
        // No client id for this platform.
        return null;
      }
      google = _google = (
        android: android,
        desktop: desktop,
        auth: auth,
        sync: CalendarSync(
          cacheDir: Directory(p.join(support.path, 'planner')),
          api: () async =>
              auth.connected ? GoogleCalendarApi.fromAuth(auth) : null,
        ),
        restored: auth.restore().catchError((Object error) {
          _log.warning('Google Calendar sign-in was not restored: $error');
        }),
      );
    }
    await google.restored;
    return (auth: google.auth, sync: google.sync);
  }

  /// Lets go of Google Calendar's connection.
  void dispose() {
    _google?.auth.close();
    _google = null;
  }
}
