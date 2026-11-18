import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ink_vault_core/ink_vault_core.dart' show newId;
import 'package:saber/components/user_error_text.dart';
import 'package:saber/data/planner/calendar_sync.dart';
import 'package:saber/data/planner/google_calendar.dart';
import 'package:saber/data/planner/handwriting_recognizer.dart';
import 'package:saber/data/planner/planner_models.dart';
import 'package:saber/data/planner/planner_platform.dart';
import 'package:saber/data/planner/planner_store.dart';
import 'package:saber/data/planner/widget_payload.dart';
import 'package:saber/data/user_error.dart';
import 'package:saber/pages/planner/event_sheet.dart';
import 'package:saber/pages/planner/ink_pad.dart';
import 'package:saber/pages/planner/month_grid.dart';

const _paleBlue = Color(0xFFD9E3FF);
const _navy = Color(0xFF1B2F6E);
const _grey = Color(0xFF5F6368);
const _black = Color(0xFF202124);

/// Pen colours of the month handwriting: black, red, blue, green, orange.
const _penColors = [0xFF202124, 0xFFD93025, 0xFF1A73E8, 0xFF188038, 0xFFE37400];

/// Pen widths, as a fraction of the grid's width.
const _penWidths = [0.003, 0.006, 0.012];

String _monthKey(DateTime month) =>
    '${month.year.toString().padLeft(4, '0')}-'
    '${month.month.toString().padLeft(2, '0')}';

DateTime _monthOf(String key) =>
    DateTime(int.parse(key.substring(0, 4)), int.parse(key.substring(5, 7)));

/// [month] and the months before and after it, whose first and last days
/// the grid shows.
List<DateTime> _around(DateTime month) => [
  month,
  DateTime(month.year, month.month - 1),
  DateTime(month.year, month.month + 1),
];

/// Whether [event] has a day in [month].
bool _touches(PlannerEvent event, DateTime month) {
  final days = eventDays(event);
  return days.first.isBefore(DateTime(month.year, month.month + 1)) &&
      !days.last.isBefore(month);
}

/// [stroke]'s bounds, in its 0..1 coordinates; a stroke without a point lies
/// outside the grid.
Rect _bounds(InkStroke stroke) {
  final points = stroke.points;
  if (points.length < 2) return const Rect.fromLTWH(-1, -1, 0, 0);
  var left = points[0], right = points[0];
  var top = points[1], bottom = points[1];
  for (var i = 0; i + 1 < points.length; i += 2) {
    left = math.min(left, points[i]);
    right = math.max(right, points[i]);
    top = math.min(top, points[i + 1]);
    bottom = math.max(bottom, points[i + 1]);
  }
  return Rect.fromLTRB(left, top, right, bottom);
}

/// A day whose 「글자로 바꾸기」 waits for a model, with the month whose grid
/// its writing is on.
typedef _WaitingDay = ({DateTime month, DateTime day});

/// The one calendar (설계 7절): a month grid of this device's events and,
/// once connected, Google Calendar's.
///
/// In edit mode a day opens its list and the event editor, and the pill at
/// the bottom adds an all-day event to the chosen day. In handwriting mode
/// the pen writes over the grid; the writing is kept per month in 0..1 of
/// the weeks, as the home-screen widget draws it, and a day's writing can
/// become that day's event (「글자로 바꾸기」). An event is saved at once;
/// handwriting five seconds after the last stroke, and at once when the mode
/// switches, the screen is left or the app goes to the background. Every
/// save is then sent to the widget.
class CalendarPage extends StatefulWidget {
  const new({
    super.key,
    required this.store,
    required this.platform,
    required this.sync,
    required this.recognizer,
    this.onConnectGoogle,
    this.onDisconnectGoogle,
    this.changes,
    this.now,
  });

  final PlannerStore store;
  final PlannerPlatform platform;

  /// Google Calendar; null where it cannot be used.
  final CalendarSync? sync;
  final HandwritingRecognizer recognizer;

  /// Signs in to Google Calendar; the page then checks the connection again.
  final Future<void> Function()? onConnectGoogle;

  /// Signs out of Google Calendar and drops its cached events; with it, the
  /// connected calendar's button offers 「연결 끊기」.
  final Future<void> Function()? onDisconnectGoogle;

  /// Fires when the vault changed, here or through sync. The page then reads
  /// the store again, after the save it is waiting for if any.
  final Listenable? changes;

  /// The clock; tests replace it.
  final DateTime Function()? now;

  @override
  State<CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends State<CalendarPage>
    with WidgetsBindingObserver {
  static const _saveDelay = Duration(seconds: 5);

  /// The first day of the shown month.
  late DateTime _month;

  /// The day of the pill and of the outline.
  late DateTime _selected;

  var _loading = true;
  Object? _loadError;

  /// This device's events of every month, as the store keeps them.
  var _events = <PlannerEvent>[];

  /// The handwriting of every month, by 'yyyy-MM'. The store takes all of it
  /// on each write: a month left out would be erased.
  var _ink = <String, MonthInk>{};

  var _handwriting = false;

  /// 「글자로 바꾸기」 waits for a day to be tapped.
  var _picking = false;
  var _penColor = _penColors.first;
  var _penWidth = _penWidths[1];
  var _erasing = false;

  /// Earlier and undone states of the shown month's handwriting.
  final _undo = <List<InkStroke>>[];
  final _redo = <List<InkStroke>>[];

  var _googleConnected = false;
  var _googleWork = 0;

  /// Why Google could not be reached on the last try, or null.
  String? _googleError;

  /// Google calendars the account can write to, its own first.
  var _calendars = <CalendarChoice>[];

  /// Google events by month 'yyyy-MM', the latest fetch last.
  final _googleMonths = <String, List<PlannerEvent>>{};

  /// Months asked from Google, not only from the cache, since the page
  /// opened.
  final _fresh = <String>{};

  var _eventsDirty = false;
  var _inkDirty = false;
  Timer? _inkTimer;
  Future<void>? _saving;

  /// The events, and each month's strokes by key, the store held when the
  /// page last read or wrote them. A stored one outside them came from
  /// another device since then, and a save keeps it instead of deleting it.
  var _knownEvents = <String>{};
  var _knownInk = <String, Set<String>>{};

  /// The vault changed while the page was loading or a save was waiting: the
  /// store is read again after it.
  var _readAgain = false;

  /// Counts this page's changes, so a read that a change overtook is dropped.
  var _edits = 0;

  final _quickText = TextEditingController();

  /// The weeks under the handwriting, whose drawn size makes the
  /// recognizer's writing area.
  final _inkArea = GlobalKey();

  /// Languages whose model download the page has seen running, with the day
  /// that waits to be converted once it is here (none when another page
  /// started it).
  final _awaited = <String, _WaitingDay?>{};

  DateTime _now() => (widget.now ?? DateTime.now)();

  @override
  void initState() {
    super.initState();
    final now = _now();
    _month = DateTime(now.year, now.month);
    _selected = DateUtils.dateOnly(now);
    WidgetsBinding.instance.addObserver(this);
    widget.changes?.addListener(_storeChanged);
    // A download started before the page opened shows too.
    final models = widget.recognizer.models..addListener(_modelsChanged);
    for (final language in handwritingLanguages.keys) {
      if (models.downloading(language)) _awaited[language] = null;
    }
    unawaited(_load());
  }

  /// The app going to the background saves what waits, as it may not come
  /// back.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if ((state == AppLifecycleState.inactive ||
            state == AppLifecycleState.paused) &&
        (_eventsDirty || _inkDirty)) {
      unawaited(_flush());
    }
  }

  @override
  void didUpdateWidget(CalendarPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.changes, widget.changes)) {
      oldWidget.changes?.removeListener(_storeChanged);
      widget.changes?.addListener(_storeChanged);
    }
    if (!identical(oldWidget.recognizer.models, widget.recognizer.models)) {
      oldWidget.recognizer.models.removeListener(_modelsChanged);
      widget.recognizer.models.addListener(_modelsChanged);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.changes?.removeListener(_storeChanged);
    widget.recognizer.models.removeListener(_modelsChanged);
    _inkTimer?.cancel();
    // A change made just before leaving is still saved.
    if (_eventsDirty || _inkDirty) unawaited(_flush());
    _quickText.dispose();
    super.dispose();
  }

  void _update(VoidCallback change) => mounted ? setState(change) : change();

  void _tell(String message) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.hideCurrentSnackBar();
    messenger?.showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _load() async {
    try {
      final events = await widget.store.readEvents();
      final ink = await widget.store.readInk();
      if (!mounted) return;
      setState(() {
        _events = events;
        _ink = ink;
        _loading = false;
      });
      _rememberEvents(events);
      _rememberInk(ink);
    } catch (error, stackTrace) {
      logUserError(error, stackTrace);
      if (!mounted) return;
      setState(() {
        _loadError = error;
        _loading = false;
      });
      return;
    }
    if (_readAgain) _storeChanged();
    await _startGoogle();
  }

  void _rememberEvents(List<PlannerEvent> events) =>
      _knownEvents = {for (final event in events) event.id};

  void _rememberInk(Map<String, MonthInk> ink) => _knownInk = {
    for (final MapEntry(key: month, value: written) in ink.entries)
      month: {for (final stroke in written.strokes) stroke.key},
  };

  /// The vault changed: the store is read now, or after the page's own
  /// changes are saved.
  void _storeChanged() {
    if (_loadError != null) return;
    if (_loading || _eventsDirty || _inkDirty || _saving != null) {
      _readAgain = true;
      return;
    }
    _readAgain = false;
    unawaited(_readStore());
  }

  Future<void> _readStore() async {
    final edits = _edits;
    final List<PlannerEvent> events;
    final Map<String, MonthInk> ink;
    try {
      events = await widget.store.readEvents();
      ink = await widget.store.readInk();
    } catch (error, stackTrace) {
      logUserError(error, stackTrace);
      return;
    }
    if (!mounted) return;
    // A change made while reading, even one already saved, would be lost:
    // the store is read again once it is saved.
    if (edits != _edits || _eventsDirty || _inkDirty || _saving != null) {
      _storeChanged();
      return;
    }
    setState(() {
      _events = events;
      _ink = ink;
    });
    _rememberEvents(events);
    _rememberInk(ink);
  }

  // ---- what is shown ----

  /// Google events of every fetched month, each once (the latest fetch
  /// wins).
  List<PlannerEvent> get _googleEvents => {
    for (final events in _googleMonths.values)
      for (final event in events) event.id: event,
  }.values.toList();

  List<PlannerEvent> get _shownEvents => [
    ..._events,
    if (_googleConnected) ..._googleEvents,
  ];

  String get _inkKey => _monthKey(_month);

  List<InkStroke> get _strokes => _ink[_inkKey]?.strokes ?? const [];

  void _show(DateTime month) {
    final now = _now();
    setState(() {
      _month = DateTime(month.year, month.month);
      _selected = _month.year == now.year && _month.month == now.month
          ? DateUtils.dateOnly(now)
          : _month;
      _undo.clear();
      _redo.clear();
      _picking = false;
    });
    unawaited(_showGoogle());
  }

  // ---- saving ----

  void _eventsChanged() {
    _edits++;
    _eventsDirty = true;
    unawaited(_flush());
  }

  void _inkChanged() {
    _edits++;
    _inkDirty = true;
    _inkTimer?.cancel();
    _inkTimer = Timer(_saveDelay, () => unawaited(_flush()));
  }

  /// Saves until nothing is left unsaved, one write at a time.
  Future<void> _flush() {
    _inkTimer?.cancel();
    return _saving ??= _saveAll().whenComplete(() {
      _saving = null;
      if (_readAgain && mounted) _storeChanged();
    });
  }

  Future<void> _saveAll() async {
    final store = widget.store;
    while (_eventsDirty || _inkDirty) {
      final events = _eventsDirty;
      final ink = _inkDirty;
      _eventsDirty = _inkDirty = false;
      try {
        // What another device added since the last read stays in the store.
        if (events) {
          final written = [..._events];
          await store.writeEvents(written, known: _knownEvents);
          _rememberEvents(written);
        }
        if (ink) {
          final written = {..._ink};
          await store.writeInk(written, known: _knownInk);
          _rememberInk(written);
        }
      } catch (error, stackTrace) {
        logUserError(error, stackTrace);
        _eventsDirty |= events;
        _inkDirty |= ink;
        _tell('달력을 저장하지 못했습니다: ${userErrorMessage(error)}');
        return;
      }
      await _sendWidget();
    }
  }

  Future<void> _sendWidget() async {
    // What is not saved yet is sent by the save that follows it.
    if (_eventsDirty || _inkDirty) return;
    try {
      await widget.platform.updateWidget(
        'calendar',
        calendarWidgetPayload(today: _now(), events: _shownEvents, ink: _ink),
      );
    } on PlatformException catch (error, stackTrace) {
      logUserError(error, stackTrace);
      _tell('위젯을 고치지 못했습니다: ${userErrorMessage(error)}');
    }
  }

  // ---- Google ----

  void _work(int change) => _update(() => _googleWork += change);

  /// Writable calendars, the account's own first: its id is an address,
  /// where a shared or group calendar's ends in calendar.google.com.
  static List<CalendarChoice> _writable(List<GoogleCalendarInfo> calendars) {
    bool own(GoogleCalendarInfo calendar) =>
        !calendar.id.endsWith('calendar.google.com');
    final writable = [
      for (final calendar in calendars)
        if (calendar.writable) calendar,
    ];
    return [
      for (final calendar in [
        ...writable.where(own),
        ...writable.where((calendar) => !own(calendar)),
      ])
        CalendarChoice(
          id: calendar.id,
          name: calendar.name,
          color: calendar.color,
        ),
    ];
  }

  /// Checks the connection; when connected, loads the calendar list and the
  /// months around the shown one. [refresh] asks Google for every month
  /// again.
  Future<void> _startGoogle({bool refresh = false}) async {
    final sync = widget.sync;
    if (sync == null) return;
    _work(1);
    try {
      GoogleCalendarApi? api;
      try {
        api = await sync.api();
      } catch (error, stackTrace) {
        logUserError(error, stackTrace);
      }
      _update(() => _googleConnected = api != null);
      if (api == null) return;
      try {
        final calendars = await api.calendars();
        _update(() => _calendars = _writable(calendars));
      } catch (error, stackTrace) {
        // Without the list, new events stay on this device.
        logUserError(error, stackTrace);
      }
      await _showGoogle(refresh: refresh);
    } finally {
      _work(-1);
    }
  }

  /// Google events of the shown month and the months beside it. The shown
  /// month is asked from Google once per opening of the page (every time
  /// with [refresh]); the others come from the cache once fetched. A failed
  /// fetch keeps the cache, and its reason shows on the Google button.
  Future<void> _showGoogle({bool refresh = false}) async {
    final sync = widget.sync;
    if (sync == null || !_googleConnected) return;
    final shown = _month;
    var asked = false;
    var changed = false;
    String? problem;
    _work(1);
    try {
      for (final month in _around(shown)) {
        final key = _monthKey(month);
        final ask = refresh || (month == shown && !_fresh.contains(key));
        if (!ask && _googleMonths.containsKey(key)) continue;
        final events = await sync.month(month, refresh: ask);
        if (ask) {
          asked = true;
          problem ??= sync.lastError;
          if (sync.lastError == null) _fresh.add(key);
        }
        changed = true;
        _update(() {
          _googleMonths.remove(key);
          _googleMonths[key] = events;
        });
      }
    } finally {
      _work(-1);
    }
    if (asked) _update(() => _googleError = problem);
    if (changed) await _sendWidget();
  }

  /// Puts a change just made on Google into the fetched months, as
  /// CalendarSync does to its cache.
  void _mirrorGoogle({String? removed, PlannerEvent? added}) {
    for (final key in [..._googleMonths.keys]) {
      _googleMonths[key] = [
        for (final event in _googleMonths[key]!)
          if (event.googleId != removed && event.googleId != added?.googleId)
            event,
        if (added != null && _touches(added, _monthOf(key))) added,
      ];
    }
  }

  Future<void> _google() async {
    if (_googleConnected) {
      await _startGoogle(refresh: true);
      final problem = _googleError;
      if (problem != null) _tell('Google 캘린더를 새로 받지 못했습니다: $problem');
      return;
    }
    final connect = widget.onConnectGoogle;
    if (widget.sync == null || connect == null) {
      _tell('이 기기에서는 Google 캘린더를 연결할 수 없습니다.');
      return;
    }
    try {
      await connect();
    } catch (error, stackTrace) {
      logUserError(error, stackTrace);
      _tell('Google 캘린더에 연결하지 못했습니다: ${userErrorMessage(error)}');
      return;
    }
    // Months fetched before may be another account's.
    _fresh.clear();
    _update(_googleMonths.clear);
    await _startGoogle();
  }

  /// The connected calendar's button: 「새로 받기」 or 「연결 끊기」.
  Future<void> _googleMenu(BuildContext button) async {
    final box = button.findRenderObject()! as RenderBox;
    final overlay =
        Overlay.of(button).context.findRenderObject()! as RenderBox;
    final rect =
        box.localToGlobal(Offset(0, box.size.height), ancestor: overlay) &
        box.size;
    final disconnect = await showMenu<bool>(
      context: button,
      position: RelativeRect.fromRect(rect, Offset.zero & overlay.size),
      items: const [
        PopupMenuItem(
          key: ValueKey('calendar-google-refresh'),
          value: false,
          child: Row(
            children: [
              Icon(Icons.refresh, size: 20),
              SizedBox(width: 12),
              Text('새로 받기'),
            ],
          ),
        ),
        PopupMenuItem(
          key: ValueKey('calendar-google-disconnect'),
          value: true,
          child: Row(
            children: [
              Icon(Icons.link_off, size: 20),
              SizedBox(width: 12),
              Text('연결 끊기'),
            ],
          ),
        ),
      ],
    );
    if (disconnect == null || !mounted) return;
    await (disconnect ? _disconnectGoogle() : _google());
  }

  /// 「연결 끊기」: the account and its cached events go, and the calendar
  /// shows this device's events only.
  Future<void> _disconnectGoogle() async {
    final disconnect = widget.onDisconnectGoogle;
    if (disconnect == null) return;
    _work(1);
    try {
      await disconnect();
    } catch (error, stackTrace) {
      logUserError(error, stackTrace);
      _tell('Google 캘린더 연결을 끊지 못했습니다: ${userErrorMessage(error)}');
      return;
    } finally {
      _work(-1);
    }
    _fresh.clear();
    _update(() {
      _googleConnected = false;
      _googleError = null;
      _calendars = [];
      _googleMonths.clear();
    });
    await _sendWidget();
  }

  // ---- events ----

  /// Where a new event goes: the account's own Google calendar when
  /// connected, otherwise this device.
  List<CalendarChoice> get _choices => [
    if (_googleConnected) ..._calendars,
    deviceCalendar,
  ];

  bool _canEdit(PlannerEvent event) =>
      event.googleId == null ||
      _calendars.any((calendar) => calendar.id == event.calendarId);

  PlannerEvent _newEvent(String title, DateTime day) {
    final calendar = _choices.first;
    return PlannerEvent(
      id: newId(),
      title: title,
      start: day,
      end: day,
      color: calendar.color,
      calendarId: calendar.id,
    );
  }

  /// [event] as an event of this device, stamped as changed now (after its
  /// last change), so the store takes it over an older stored copy. One that
  /// was on Google gets an id of its own, so it never shares a key with the
  /// Google copy, which stays when Google cannot delete it.
  PlannerEvent _onDevice(PlannerEvent event, {required bool wasOnGoogle}) {
    final now = _now().millisecondsSinceEpoch;
    return PlannerEvent(
      id: wasOnGoogle ? newId() : event.id,
      title: event.title,
      start: event.start,
      end: event.end,
      allDay: event.allDay,
      color: event.calendarId == null ? event.color : deviceCalendar.color,
      changedAt: !wasOnGoogle && event.changedAt >= now
          ? event.changedAt + 1
          : now,
    );
  }

  /// Puts [after] in place of [before] (no before: a new event; no after:
  /// deleted). This device's events go to the store. An event of a Google
  /// calendar goes to Google; when Google refuses it, it stays on this device
  /// and the page says so (설계 7절).
  Future<void> _apply(PlannerEvent? before, PlannerEvent? after) async {
    final sync = widget.sync;
    final wasOnGoogle = before != null && before.googleId != null;
    final drop = before != null && !wasOnGoogle ? before.id : null;
    var leaveGoogle =
        wasOnGoogle && (after == null || after.googleId != before.googleId);
    var googleChanged = false;
    PlannerEvent? keep;
    String? problem;
    if (after != null && after.calendarId == null) {
      keep = _onDevice(after, wasOnGoogle: wasOnGoogle);
    } else if (after != null) {
      try {
        if (sync == null) throw StateError('Google 캘린더에 연결되어 있지 않습니다.');
        final saved = await sync.save(after);
        _update(() => _mirrorGoogle(added: saved));
        googleChanged = true;
      } catch (error, stackTrace) {
        logUserError(error, stackTrace);
        problem =
            'Google 캘린더에 저장하지 못해 이 기기에 남겼습니다: '
            '${userErrorMessage(error)}';
        keep = _onDevice(after, wasOnGoogle: wasOnGoogle);
        // A move to another calendar leaves the event where it was, too.
        leaveGoogle = false;
      }
    }
    if (leaveGoogle && sync != null) {
      try {
        await sync.remove(before!);
        _update(() => _mirrorGoogle(removed: before.googleId));
        googleChanged = true;
      } catch (error, stackTrace) {
        logUserError(error, stackTrace);
        problem ??= 'Google 캘린더에서 지우지 못했습니다: ${userErrorMessage(error)}';
      }
    }
    if (drop != null || keep != null) {
      final added = keep;
      _update(
        () => _events = [
          for (final event in _events)
            if (event.id != drop && event.id != added?.id) event,
          ?added,
        ],
      );
      _eventsChanged();
    } else if (googleChanged) {
      await _sendWidget();
    }
    if (problem != null) _tell(problem);
  }

  Future<void> _tapDay(DateTime day) async {
    if (_picking) return _convert(day);
    setState(() => _selected = day);
    final events = [
      for (final event in _shownEvents)
        if (eventCovers(event, day)) event,
    ]..sort(compareEvents);
    final choice = await showDaySheet(
      context,
      day: day,
      events: events,
      canEdit: _canEdit,
    );
    if (choice == null || !mounted) return;
    final existing = choice.event;
    final edit = await showEventEditor(
      context,
      event: existing ?? _newEvent('', day),
      isNew: existing == null,
      calendars: _choices,
    );
    if (edit == null || !mounted) return;
    await _apply(existing, edit.delete ? null : edit.event);
  }

  Future<void> _quickAdd() async {
    final title = _quickText.text.trim();
    if (title.isEmpty) return;
    _quickText.clear();
    FocusScope.of(context).unfocus();
    await _apply(null, _newEvent(title, _selected));
  }

  // ---- handwriting ----

  void _putStrokes(List<InkStroke> strokes) {
    final key = _inkKey;
    setState(
      () => _ink = {..._ink, key: MonthInk(month: key, strokes: strokes)},
    );
    _inkChanged();
  }

  /// A change made on the pad or with the tools, which undo can take back.
  void _setStrokes(List<InkStroke> strokes) {
    _undo.add(_strokes);
    _redo.clear();
    _putStrokes(strokes);
  }

  /// Strokes brought back by undo or redo are new changes: without their
  /// saved time, the store stamps a stroke erased in between as newer than
  /// its erasure (and keeps the time of one that is still saved).
  static List<InkStroke> _renewed(List<InkStroke> strokes) => [
    for (final stroke in strokes)
      if (stroke.changedAt == 0) stroke else stroke.copyWith(changedAt: 0),
  ];

  void _undoInk() {
    if (_undo.isEmpty) return;
    _redo.add(_strokes);
    _putStrokes(_renewed(_undo.removeLast()));
  }

  void _redoInk() {
    if (_redo.isEmpty) return;
    _undo.add(_strokes);
    _putStrokes(_renewed(_redo.removeLast()));
  }

  Future<void> _clearInk() async {
    final clear = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('이 달 필기를 모두 지울까요?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          TextButton(
            key: const ValueKey('calendar-ink-clear-ok'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('지우기'),
          ),
        ],
      ),
    );
    if ((clear ?? false) && mounted) _setStrokes(const []);
  }

  /// 「글자로 바꾸기」 on [day]: its cell's strokes go to the recognizer in
  /// [language] (한국어 | 영어 in the dialog reads them again), the reading
  /// can be corrected and becomes the day's all-day event, then the page
  /// asks whether the writing goes. A language whose model is not on the
  /// device asks to download it first. Without an engine the reason shows
  /// with an empty field for the pen's handwriting input.
  Future<void> _convert(DateTime day, {String language = 'ko'}) async {
    final weeks = monthWeeks(_month);
    final row = weeks.indexWhere(
      (week) => week.any((other) => DateUtils.isSameDay(other, day)),
    );
    if (row < 0) return;
    final column = weeks[row].indexWhere(
      (other) => DateUtils.isSameDay(other, day),
    );
    final cell = Rect.fromLTWH(
      column / 7,
      row / weeks.length,
      1 / 7,
      1 / weeks.length,
    );
    final strokes = [
      for (final stroke in _strokes)
        if (cell.contains(_bounds(stroke).center)) stroke,
    ];
    if (strokes.isEmpty) {
      _tell('이 칸에는 필기가 없습니다.');
      return;
    }
    setState(() => _picking = false);
    // The writing area is the cell, grown to hold every stroke written into
    // it, at the size the grid draws it (700 wide when the grid is not
    // drawn); the strokes go in 0..1 of it.
    var box = cell;
    for (final stroke in strokes) {
      box = box.expandToInclude(_bounds(stroke));
    }
    final grid = _inkArea.currentContext?.findRenderObject();
    final scale = grid is RenderBox && grid.hasSize && !grid.size.isEmpty
        ? grid.size
        : Size.square(700 / box.width);
    final area = Size(box.width * scale.width, box.height * scale.height);
    final written = [
      for (final stroke in strokes)
        InkStroke(
          points: [
            for (var i = 0; i + 1 < stroke.points.length; i += 2) ...[
              (stroke.points[i] - box.left) / box.width,
              (stroke.points[i + 1] - box.top) / box.height,
            ],
          ],
          color: stroke.color,
          width: stroke.width / box.width,
        ),
    ];
    final reading = await _read(written, area, language);
    if (!mounted) return;
    if (reading == null) {
      await _offerModel(language, day);
      return;
    }
    var shown = reading;
    final title = await showConvertDialog(
      context,
      day: day,
      candidates: reading.candidates,
      notice: reading.notice,
      language: reading.language,
      onLanguage: (language) async {
        final next = await _read(written, area, language);
        if (next != null) return shown = next;
        if (!mounted) return shown;
        // 받기 closes the dialog while the model comes; 취소 stays.
        return await _offerModel(language, day) ? null : shown;
      },
    );
    if (title == null || !mounted) return;
    await _apply(null, _newEvent(title, day));
    if (!mounted) return;
    if (!await askEraseConverted(context) || !mounted) return;
    final gone = {for (final stroke in strokes) stroke.key};
    _setStrokes([
      for (final stroke in _strokes)
        if (!gone.contains(stroke.key)) stroke,
    ]);
  }

  /// The recognizer's reading of [strokes] (in 0..1 of [area]) in
  /// [language]; null when the language's model is not on the device.
  Future<ConvertReading?> _read(
    List<InkStroke> strokes,
    Size area,
    String language,
  ) async {
    final recognizer = widget.recognizer;
    try {
      final state = await recognizer.modelState(language);
      if (state == HandwritingModelState.missing) return null;
      if (state == HandwritingModelState.unavailable) {
        throw HandwritingUnavailable();
      }
      final candidates = await recognizer.recognize(
        strokes,
        language: language,
        area: area,
      );
      return (
        language: language,
        candidates: candidates,
        notice: candidates.isEmpty ? '글자를 알아보지 못했습니다. 펜으로 쓰거나 입력하세요.' : null,
      );
    } on HandwritingModelMissing {
      // Removed since the check.
      return null;
    } on HandwritingUnavailable catch (error) {
      // As before the engine: the reason and the pen's handwriting input.
      return (language: null, candidates: const <String>[], notice: error.message);
    } catch (error, stackTrace) {
      logUserError(error, stackTrace);
      return (
        language: language,
        candidates: const <String>[],
        notice: '손글씨를 알아보지 못했습니다: ${userErrorMessage(error)}',
      );
    }
  }

  /// [language]'s model is not on the device: the page asks to download it
  /// (unless it is coming already), then 「글자로 바꾸기」 on [day] waits for
  /// it. True when the model is coming.
  Future<bool> _offerModel(String language, DateTime day) async {
    final waiting = (month: _month, day: day);
    if (!widget.recognizer.models.downloading(language)) {
      final download = await showModelNotice(context, language: language);
      if (!download || !mounted) return false;
    }
    _download(language, waiting);
    return true;
  }

  /// Downloads [language]'s model in the background; the page stays usable
  /// and offers [waiting] again once the model is here.
  void _download(String language, _WaitingDay? waiting) {
    // Noted before the download starts, which tells the page at once.
    _awaited[language] = waiting;
    unawaited(widget.recognizer.models.start(language));
    _tell('${handwritingLanguages[language]!.name} 손글씨 모델을 받는 중입니다.');
  }

  /// Notes the downloads running now; one noted before that has ended says
  /// how it went.
  void _modelsChanged() {
    final models = widget.recognizer.models;
    for (final language in handwritingLanguages.keys) {
      if (models.downloading(language)) {
        _awaited.putIfAbsent(language, () => null);
      } else if (_awaited.containsKey(language)) {
        _modelDone(language, _awaited.remove(language));
      }
    }
    setState(() {});
  }

  /// [language]'s download ended: 「글자로 바꾸기」 converts the day that
  /// waited for it, or 「다시 받기」 tries again.
  void _modelDone(String language, _WaitingDay? waiting) {
    final error = widget.recognizer.models.lastError(language);
    final SnackBarAction? action;
    if (error != null) {
      action = SnackBarAction(
        label: '다시 받기',
        onPressed: () {
          if (mounted) _download(language, waiting);
        },
      );
    } else if (waiting != null) {
      action = SnackBarAction(
        label: '글자로 바꾸기',
        onPressed: () {
          if (!mounted) return;
          // The writing is on the grid of the month it was written on.
          if (_month != waiting.month) _show(waiting.month);
          unawaited(_convert(waiting.day, language: language));
        },
      );
    } else {
      action = null;
    }
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.hideCurrentSnackBar();
    messenger?.showSnackBar(
      SnackBar(
        content: Text(
          error == null
              ? '손글씨 모델을 받았습니다'
              : '손글씨 모델을 받지 못했습니다: ${userErrorMessage(error)}',
        ),
        persist: false,
        duration: const Duration(seconds: 8),
        action: action,
      ),
    );
  }

  // ---- screen ----

  @override
  Widget build(BuildContext context) {
    final light = Theme.of(context).brightness == Brightness.light;
    final loadError = _loadError;
    final ready = !_loading && loadError == null;
    const compact = VisualDensity.compact;
    return Scaffold(
      key: const ValueKey('calendar-page'),
      backgroundColor: light ? Colors.white : null,
      appBar: AppBar(
        backgroundColor: light ? Colors.white : null,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        leadingWidth: 48,
        leading: IconButton(
          tooltip: '뒤로',
          visualDensity: compact,
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.maybePop(context),
        ),
        titleSpacing: 0,
        centerTitle: true,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              key: const ValueKey('calendar-prev'),
              tooltip: '이전 달',
              visualDensity: compact,
              icon: const Icon(Icons.chevron_left),
              onPressed: ready
                  ? () => _show(DateTime(_month.year, _month.month - 1))
                  : null,
            ),
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  '${_month.year}년 ${_month.month}월',
                  key: const ValueKey('calendar-title'),
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
            IconButton(
              key: const ValueKey('calendar-next'),
              tooltip: '다음 달',
              visualDensity: compact,
              icon: const Icon(Icons.chevron_right),
              onPressed: ready
                  ? () => _show(DateTime(_month.year, _month.month + 1))
                  : null,
            ),
          ],
        ),
        actions: [
          // Shows the mode a tap goes to, as the pen in the Samsung photo.
          IconButton(
            key: const ValueKey('calendar-mode'),
            tooltip: _handwriting ? '편집 모드' : '필기 모드',
            visualDensity: compact,
            icon: Icon(_handwriting ? Icons.edit_calendar : Icons.draw),
            onPressed: ready
                ? () {
                    setState(() {
                      _handwriting = !_handwriting;
                      _picking = false;
                    });
                    // The handwriting waiting for its five seconds is saved
                    // now.
                    if (_inkDirty) unawaited(_flush());
                  }
                : null,
          ),
          IconButton(
            key: const ValueKey('calendar-today'),
            tooltip: '오늘',
            visualDensity: compact,
            icon: _TodayIcon(day: _now().day),
            onPressed: ready ? () => _show(_now()) : null,
          ),
          Builder(
            builder: (button) => IconButton(
              key: const ValueKey('calendar-google'),
              tooltip: !_googleConnected
                  ? 'Google 캘린더 연결'
                  : _googleError != null
                  ? 'Google 캘린더: $_googleError'
                  : widget.onDisconnectGoogle != null
                  ? 'Google 캘린더'
                  : 'Google 캘린더 새로 받기',
              visualDensity: compact,
              icon: Icon(
                !_googleConnected
                    ? Icons.cloud_off_outlined
                    : _googleError != null
                    ? Icons.sync_problem_outlined
                    : Icons.cloud_done_outlined,
              ),
              onPressed: ready && _googleWork == 0
                  ? () => unawaited(
                      _googleConnected && widget.onDisconnectGoogle != null
                          ? _googleMenu(button)
                          : _google(),
                    )
                  : null,
            ),
          ),
          const SizedBox(width: 4),
        ],
        // A handwriting model downloading in the background. The strip is
        // always there, so the grid does not move when the bar shows.
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(3),
          child: _awaited.isEmpty
              ? const SizedBox.shrink()
              : const LinearProgressIndicator(
                  key: ValueKey('handwriting-model-progress'),
                  minHeight: 3,
                  semanticsLabel: '손글씨 모델을 받는 중',
                ),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : loadError != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: UserErrorText.of(
                  loadError,
                  prefix: '달력을 읽지 못했습니다',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : Column(
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: MonthGrid(
                      month: _month,
                      today: DateUtils.dateOnly(_now()),
                      events: _shownEvents,
                      selected: _selected,
                      onTapDay: (day) => unawaited(_tapDay(day)),
                      overlay: KeyedSubtree(
                        key: _inkArea,
                        child: InkPad(
                          key: const ValueKey('calendar-ink'),
                          strokes: _strokes,
                          enabled: _handwriting && !_picking,
                          color: _penColor,
                          width: _penWidth,
                          erasing: _erasing,
                          onChanged: _setStrokes,
                        ),
                      ),
                    ),
                  ),
                ),
                // The same height in both modes, so the grid and its
                // handwriting stay where they are.
                SizedBox(
                  height: 64,
                  child: !_handwriting
                      ? _quickAddBar(light)
                      : _picking
                      ? _pickHint()
                      : _tools(),
                ),
              ],
            ),
    );
  }

  Widget _quickAddBar(bool light) => Center(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Material(
          key: const ValueKey('calendar-quick-add'),
          color: light
              ? Colors.white
              : Theme.of(context).colorScheme.surfaceContainerHigh,
          elevation: 3,
          shadowColor: const Color(0x38000000),
          shape: const StadiumBorder(),
          child: Row(
            children: [
              const SizedBox(width: 20),
              // Typed or written with the pen; a title alone makes an
              // all-day event on the chosen day.
              Expanded(
                child: TextField(
                  controller: _quickText,
                  decoration: InputDecoration.collapsed(
                    hintText: '${_selected.month}월 ${_selected.day}일에 추가',
                    hintStyle: const TextStyle(color: _grey),
                  ),
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => unawaited(_quickAdd()),
                ),
              ),
              IconButton(
                key: const ValueKey('calendar-quick-add-submit'),
                tooltip: '추가',
                icon: const Icon(Icons.add),
                onPressed: () => unawaited(_quickAdd()),
              ),
              const SizedBox(width: 4),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _pickHint() => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16),
    child: Row(
      children: [
        const Icon(Icons.touch_app_outlined, color: _grey),
        const SizedBox(width: 12),
        const Expanded(child: Text('글자로 바꿀 날짜 칸을 누르세요', maxLines: 2)),
        TextButton(
          key: const ValueKey('calendar-convert-cancel'),
          onPressed: () => setState(() => _picking = false),
          child: const Text('취소'),
        ),
      ],
    ),
  );

  /// Pen colours and widths, eraser, undo, redo and 이 달 지우기, which scroll
  /// sideways where they do not fit, and 「글자로 바꾸기」 kept at the end.
  Widget _tools() {
    final empty = _strokes.isEmpty;
    Widget tool(
      String key,
      String tooltip,
      Widget icon,
      VoidCallback? onPressed, {
      bool selected = false,
    }) => IconButton(
      key: ValueKey(key),
      tooltip: tooltip,
      isSelected: selected,
      style: IconButton.styleFrom(
        backgroundColor: selected ? _paleBlue : null,
        foregroundColor: selected ? _navy : null,
      ),
      icon: icon,
      onPressed: onPressed,
    );
    const gap = SizedBox(width: 12);
    final tools = [
      for (final (index, color) in _penColors.indexed)
        tool(
          'calendar-pen-color-$index',
          '펜 색',
          _Dot(color: Color(color), size: 18),
          () => setState(() {
            _penColor = color;
            _erasing = false;
          }),
          selected: !_erasing && _penColor == color,
        ),
      gap,
      for (final (index, width) in _penWidths.indexed)
        tool(
          'calendar-pen-width-$index',
          '굵기',
          _Dot(color: _black, size: 4.0 + 4 * index),
          () => setState(() {
            _penWidth = width;
            _erasing = false;
          }),
          selected: !_erasing && _penWidth == width,
        ),
      gap,
      tool(
        'calendar-ink-eraser',
        '지우개',
        const Icon(Icons.auto_fix_normal),
        () => setState(() => _erasing = true),
        selected: _erasing,
      ),
      tool(
        'calendar-ink-undo',
        '실행 취소',
        const Icon(Icons.undo),
        _undo.isEmpty ? null : _undoInk,
      ),
      tool(
        'calendar-ink-redo',
        '다시 실행',
        const Icon(Icons.redo),
        _redo.isEmpty ? null : _redoInk,
      ),
      tool(
        'calendar-ink-clear',
        '이 달 필기 지우기',
        const Icon(Icons.delete_sweep_outlined),
        empty ? null : () => unawaited(_clearInk()),
      ),
    ];
    final convert = empty ? null : () => setState(() => _picking = true);
    return LayoutBuilder(
      builder: (context, constraints) {
        // A phone shows the convert button as an icon only.
        final narrow = constraints.maxWidth < 600;
        return Row(
          children: [
            Expanded(
              child: LayoutBuilder(
                builder: (context, area) => SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minWidth: math.max(0, area.maxWidth - 16),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: tools,
                    ),
                  ),
                ),
              ),
            ),
            if (narrow)
              IconButton(
                key: const ValueKey('calendar-ink-convert'),
                tooltip: '글자로 바꾸기',
                icon: const Icon(Icons.text_fields),
                onPressed: convert,
              )
            else
              TextButton.icon(
                key: const ValueKey('calendar-ink-convert'),
                onPressed: convert,
                icon: const Icon(Icons.text_fields),
                label: const Text('글자로 바꾸기'),
              ),
            const SizedBox(width: 8),
          ],
        );
      },
    );
  }
}

/// The today button: today's date in a rounded square, as in the photo.
class _TodayIcon extends StatelessWidget {
  const new({required this.day});

  final int day;

  @override
  Widget build(BuildContext context) {
    final color = IconTheme.of(context).color ?? _black;
    return SizedBox.square(
      dimension: 22,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: color, width: 1.6),
          borderRadius: BorderRadius.circular(5),
        ),
        child: Center(
          child: Text(
            '$day',
            style: TextStyle(
              fontSize: 11,
              height: 1,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ),
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const new({required this.color, required this.size});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: 24,
    child: Center(
      child: DecoratedBox(
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        child: SizedBox.square(dimension: size),
      ),
    ),
  );
}
