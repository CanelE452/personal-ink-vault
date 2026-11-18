import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ink_vault_core/ink_vault_core.dart' show newId;
import 'package:saber/components/user_error_text.dart';
import 'package:saber/data/planner/planner_models.dart';
import 'package:saber/data/planner/planner_platform.dart';
import 'package:saber/data/planner/planner_store.dart';
import 'package:saber/data/planner/widget_payload.dart';
import 'package:saber/data/user_error.dart';
import 'package:saber/pages/planner/ink_pad.dart';

const _blue = Color(0xFF3D5AFE);
const _paleBlue = Color(0xFFD9E3FF);
const _navy = Color(0xFF1B2F6E);
const _grey = Color(0xFF5F6368);
const _faint = Color(0xFF8A8A8A);

/// Red of a time that has passed; the widget uses the same red.
const _red = Color(0xFFD93025);

/// Notein's light look, as in library_add.dart and library_menus.dart: a
/// light-grey page with white groups.
const _page = Color(0xFFF2F2F7);
const _line = Color(0xFFE5E5EA);
const _chip = Color(0xFFEFEFF1);

/// The widget's memo paper.
const _memoPaper = Color(0xFFFFF8E1);

const _weekdays = ['월', '화', '수', '목', '금', '토', '일'];
const _exactOff = '정확한 알람이 꺼져 있어 알림이 몇 분 늦을 수 있습니다';

/// The one reminder note (설계 6절): a handwriting memo on top, the tasks
/// under it and the finished ones folded at the bottom. A change is saved
/// five seconds later (changes in between go together), and at once when the
/// screen is left or the app goes to the background; then it is sent to the
/// home-screen widget and to the alarms.
class ReminderPage extends StatefulWidget {
  const new({
    super.key,
    required this.store,
    required this.platform,
    this.changes,
    this.now,
  });

  final PlannerStore store;
  final PlannerPlatform platform;

  /// Fires when the vault changed, here or through sync. The page then reads
  /// the store again, after the save it is waiting for if any.
  final Listenable? changes;

  /// The clock; tests replace it.
  final DateTime Function()? now;

  @override
  State<ReminderPage> createState() => _ReminderPageState();
}

typedef _TimeChoice = ({DateTime? at, ReminderRepeat repeat});

class _ReminderPageState extends State<ReminderPage>
    with WidgetsBindingObserver {
  static const _saveDelay = Duration(seconds: 5);

  var _loading = true;
  Object? _loadError;
  var _items = <ReminderItem>[];
  var _memo = <InkStroke>[];
  var _aspect = const ReminderNote().memoAspect;
  final _texts = <String, TextEditingController>{};

  /// Memo strokes as the store last wrote them, stamped with an id and a
  /// time, by key. The pad hands back strokes without the stamp; written
  /// again without its time, a stroke drawn after a clear would read as
  /// older than the clear and vanish.
  var _stamped = <String, InkStroke>{};

  /// The task just added; its text field takes the focus.
  ReminderItem? _added;
  var _erasing = false;
  var _showDone = false;
  var _askedPermission = false;

  Timer? _saveTimer;
  var _unsaved = false;
  Future<void>? _saving;

  /// The tasks and the memo strokes (by key) the store held when the page
  /// last read or wrote it. A stored one outside them came from another
  /// device since then, and a save keeps it instead of deleting it.
  var _knownItems = <String>{};
  var _knownStrokes = <String>{};

  /// The vault changed while the page was loading or a save was waiting: the
  /// store is read again after it.
  var _readAgain = false;

  /// Counts this page's changes, so a read that a change overtook is dropped.
  var _edits = 0;

  DateTime _now() => (widget.now ?? DateTime.now)();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.changes?.addListener(_storeChanged);
    unawaited(_load());
  }

  /// The app going to the background saves what waits, as it may not come
  /// back.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if ((state == AppLifecycleState.inactive ||
            state == AppLifecycleState.paused) &&
        _unsaved) {
      unawaited(_flush());
    }
  }

  @override
  void didUpdateWidget(ReminderPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.changes, widget.changes)) {
      oldWidget.changes?.removeListener(_storeChanged);
      widget.changes?.addListener(_storeChanged);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.changes?.removeListener(_storeChanged);
    _saveTimer?.cancel();
    // A change made just before leaving is still saved.
    if (_unsaved) unawaited(_flush());
    for (final text in _texts.values) {
      text.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final note = await widget.store.readReminders();
      if (!mounted) return;
      setState(() {
        _items = [...note.items];
        _memo = note.memo;
        _aspect = note.memoAspect;
        _loading = false;
      });
      _remember(note);
    } catch (error, stackTrace) {
      logUserError(error, stackTrace);
      if (!mounted) return;
      setState(() {
        _loadError = error;
        _loading = false;
      });
    }
    if (_readAgain) _storeChanged();
  }

  void _remember(ReminderNote note) {
    _knownItems = {for (final item in note.items) item.id};
    _knownStrokes = {for (final stroke in note.memo) stroke.key};
    _stamped = {for (final stroke in note.memo) stroke.key: stroke};
  }

  /// The vault changed: the store is read now, or after the page's own
  /// changes are saved.
  void _storeChanged() {
    if (_loadError != null) return;
    if (_loading || _unsaved || _saving != null) {
      _readAgain = true;
      return;
    }
    _readAgain = false;
    unawaited(_readStore());
  }

  Future<void> _readStore() async {
    final edits = _edits;
    final ReminderNote note;
    try {
      note = await widget.store.readReminders();
    } catch (error, stackTrace) {
      logUserError(error, stackTrace);
      return;
    }
    if (!mounted) return;
    // A change made while reading, even one already saved, would be lost:
    // the store is read again once it is saved.
    if (edits != _edits || _unsaved || _saving != null) {
      _storeChanged();
      return;
    }
    final ids = {for (final item in note.items) item.id};
    final gone = [
      for (final id in [..._texts.keys])
        if (!ids.contains(id)) ?_texts.remove(id),
    ];
    for (final item in note.items) {
      final text = _texts[item.id];
      if (text != null && text.text != item.text) text.text = item.text;
    }
    setState(() {
      _items = [...note.items];
      _memo = note.memo;
      _aspect = note.memoAspect;
    });
    _remember(note);
    // The fields let go of their controllers in the next frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final text in gone) {
        text.dispose();
      }
    });
  }

  // ---- saving ----

  void _changed() {
    _edits++;
    _unsaved = true;
    _saveTimer?.cancel();
    _saveTimer = Timer(_saveDelay, () => unawaited(_flush()));
  }

  /// Saves until nothing is left unsaved, one write at a time.
  Future<void> _flush() {
    _saveTimer?.cancel();
    return _saving ??= _saveAll().whenComplete(() {
      _saving = null;
      if (_readAgain && mounted) _storeChanged();
    });
  }

  Future<void> _saveAll() async {
    final store = widget.store;
    final platform = widget.platform;
    while (_unsaved) {
      _unsaved = false;
      final note = ReminderNote(
        items: [..._items],
        memo: [for (final stroke in _memo) _stamped[stroke.key] ?? stroke],
        memoAspect: _aspect,
      );
      try {
        // What another device added since the last read stays in the store.
        await store.writeReminders(
          note,
          knownItems: _knownItems,
          knownStrokes: _knownStrokes,
        );
        _knownItems = {for (final item in note.items) item.id};
        _knownStrokes = {for (final stroke in note.memo) stroke.key};
        _stamped = {
          for (final stroke in (await store.readReminders()).memo)
            stroke.key: stroke,
        };
      } catch (error, stackTrace) {
        logUserError(error, stackTrace);
        _unsaved = true;
        _tell('리마인더를 저장하지 못했습니다: ${userErrorMessage(error)}');
        return;
      }
      // A blank task neither shows on the widget nor rings.
      final shown = shownReminders(note);
      final now = _now();
      try {
        await platform.updateWidget(
          'reminder',
          reminderWidgetPayload(shown, now: now),
        );
        await platform.scheduleReminders(reminderAlarms(shown, now));
      } on PlatformException catch (error, stackTrace) {
        logUserError(error, stackTrace);
        _tell('위젯과 알림을 고치지 못했습니다: ${userErrorMessage(error)}');
      }
    }
  }

  void _tell(String message) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.hideCurrentSnackBar();
    messenger?.showSnackBar(SnackBar(content: Text(message)));
  }

  // ---- changes ----

  /// A time that orders this change after the item's last one.
  int _stamp(ReminderItem? item) {
    final now = _now().millisecondsSinceEpoch;
    return item == null || now > item.changedAt ? now : item.changedAt + 1;
  }

  void _edit(String id, {String? text, bool? done, _TimeChoice? time}) {
    setState(() {
      _items = [
        for (final item in _items)
          if (item.id != id)
            item
          else
            ReminderItem(
              id: item.id,
              text: text ?? item.text,
              at: time == null ? item.at : time.at,
              repeat: time == null ? item.repeat : time.repeat,
              done: done ?? item.done,
              order: item.order,
              changedAt: _stamp(item),
            ),
      ];
    });
    _changed();
  }

  void _add() {
    final order = _items.fold(-1, (top, item) => math.max(top, item.order)) + 1;
    final item = ReminderItem(
      id: newId(),
      text: '',
      order: order,
      changedAt: _stamp(null),
    );
    setState(() {
      _items = [..._items, item];
      _added = item;
    });
    _changed();
  }

  void _remove(bool Function(ReminderItem item) gone) {
    final texts = [
      for (final item in _items)
        if (gone(item)) ?_texts.remove(item.id),
    ];
    setState(
      () => _items = [
        for (final item in _items)
          if (!gone(item)) item,
      ],
    );
    // The fields let go of their controllers in the next frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final text in texts) {
        text.dispose();
      }
    });
    _changed();
  }

  void _setMemo(List<InkStroke> strokes) {
    setState(() => _memo = strokes);
    _changed();
  }

  Future<void> _clearMemo() async {
    final clear = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('필기 메모를 모두 지울까요?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          TextButton(
            key: const ValueKey('reminder-memo-clear-ok'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('지우기'),
          ),
        ],
      ),
    );
    if (clear ?? false) _setMemo(const []);
  }

  Future<void> _pickTime(ReminderItem item) async {
    final now = _now();
    final choice = await showDialog<_TimeChoice>(
      context: context,
      builder: (_) => _TimeDialog(
        initial:
            item.at ?? DateTime(now.year, now.month, now.day, now.hour + 1),
        repeat: item.repeat,
        hasTime: item.at != null,
      ),
    );
    if (choice == null || !mounted) return;
    _edit(item.id, time: choice);
    if (choice.at == null || _askedPermission) return;
    // Android 13 and later ask for notifications the first time a task gets
    // a time.
    _askedPermission = true;
    try {
      final status = await widget.platform.requestNotificationPermission();
      // Not granted: no alarm shows at all (or there are none, on Windows),
      // so being late is not the point.
      if (status.granted && !status.exact) _tell(_exactOff);
    } on PlatformException catch (error, stackTrace) {
      logUserError(error, stackTrace);
    }
  }

  // ---- screen ----

  @override
  Widget build(BuildContext context) {
    final light = Theme.of(context).brightness == Brightness.light;
    final ready = !_loading && _loadError == null;
    final loadError = _loadError;
    return Scaffold(
      key: const ValueKey('reminder-page'),
      backgroundColor: light ? _page : null,
      appBar: AppBar(
        backgroundColor: light ? _page : null,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        leading: IconButton(
          tooltip: '뒤로',
          icon: const Icon(Icons.chevron_left),
          onPressed: () => Navigator.maybePop(context),
        ),
        title: const Text('리마인더'),
        actions: [
          IconButton(
            key: const ValueKey('reminder-add'),
            tooltip: '할 일 추가',
            icon: const Icon(Icons.add),
            onPressed: ready ? _add : null,
          ),
          PopupMenuButton<void>(
            key: const ValueKey('reminder-more'),
            tooltip: '더 보기',
            icon: const Icon(Icons.more_horiz),
            enabled: ready,
            position: PopupMenuPosition.under,
            color: light ? Colors.white : null,
            surfaceTintColor: light ? Colors.transparent : null,
            shadowColor: const Color(0x38000000),
            elevation: 8,
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.all(Radius.circular(16)),
            ),
            itemBuilder: (_) => [
              PopupMenuItem<void>(
                key: const ValueKey('reminder-clear-done'),
                enabled: _items.any((item) => item.done),
                height: 48,
                onTap: () => _remove((item) => item.done),
                child: const Row(
                  children: [
                    Icon(Icons.delete_sweep_outlined, size: 20),
                    SizedBox(width: 14),
                    Text('끝낸 일 모두 삭제'),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : loadError != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: UserErrorText.of(
                  loadError,
                  prefix: '리마인더를 읽지 못했습니다',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : _list(light),
    );
  }

  Widget _list(bool light) {
    List<ReminderItem> sorted(bool done) => [
      for (final item in _items)
        if (item.done == done) item,
    ]..sort((a, b) => a.order.compareTo(b.order));
    final open = sorted(false);
    final done = sorted(true);
    return LayoutBuilder(
      builder: (context, constraints) {
        final side = math.max(16.0, (constraints.maxWidth - 720) / 2);
        // A long time label shrinks before it pushes a task off a phone.
        final chipWidth = math.min(
          150.0,
          (constraints.maxWidth - 2 * side) * 0.4,
        );
        return ListView(
          padding: EdgeInsets.fromLTRB(side, 8, side, 32),
          children: [
            _memoSection(light),
            const SizedBox(height: 16),
            _group(light, [
              for (final item in open) _row(item, light, chipWidth),
            ], empty: '할 일이 없습니다'),
            if (done.isNotEmpty) ...[
              _doneToggle(done.length),
              if (_showDone)
                _group(light, [
                  for (final item in done) _row(item, light, chipWidth),
                ]),
            ],
          ],
        );
      },
    );
  }

  Widget _group(bool light, List<Widget> rows, {String? empty}) => Material(
    color: light
        ? Colors.white
        : Theme.of(context).colorScheme.surfaceContainerHigh,
    borderRadius: BorderRadius.circular(16),
    clipBehavior: Clip.antiAlias,
    child: rows.isEmpty && empty != null
        ? Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            child: Text(empty, style: const TextStyle(color: _faint)),
          )
        : Column(
            children: [
              for (final (index, row) in rows.indexed) ...[
                if (index > 0)
                  Divider(height: 1, indent: 52, color: light ? _line : null),
                row,
              ],
            ],
          ),
  );

  Widget _memoSection(bool light) {
    final scheme = Theme.of(context).colorScheme;
    Widget tool(
      String key,
      IconData icon,
      String label,
      bool selected,
      VoidCallback onPressed,
    ) => IconButton(
      key: ValueKey(key),
      tooltip: label,
      isSelected: selected,
      style: IconButton.styleFrom(
        backgroundColor: selected ? _paleBlue : null,
        foregroundColor: selected ? _navy : null,
      ),
      icon: Icon(icon, size: 20),
      onPressed: onPressed,
    );
    return Material(
      color: light ? Colors.white : scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 8, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    '필기 메모',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                ),
                tool(
                  'reminder-memo-pen',
                  Icons.edit,
                  '펜',
                  !_erasing,
                  () => setState(() => _erasing = false),
                ),
                tool(
                  'reminder-memo-eraser',
                  Icons.auto_fix_normal,
                  '지우개',
                  _erasing,
                  () => setState(() => _erasing = true),
                ),
                IconButton(
                  key: const ValueKey('reminder-memo-clear'),
                  tooltip: '지우기',
                  icon: const Icon(Icons.delete_sweep_outlined, size: 20),
                  onPressed: _memo.isEmpty ? null : _clearMemo,
                ),
              ],
            ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              // The widget draws the memo at the same aspect on the same
              // paper, so the strokes land where they were written.
              child: AspectRatio(
                aspectRatio: _aspect,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: _memoPaper,
                    border: Border.all(color: light ? _line : scheme.outline),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: InkPad(
                      key: const ValueKey('reminder-memo'),
                      strokes: _memo,
                      erasing: _erasing,
                      onChanged: _setMemo,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(ReminderItem item, bool light, double chipWidth) {
    final text = _texts.putIfAbsent(
      item.id,
      () => TextEditingController(text: item.text),
    );
    return Padding(
      key: ValueKey('reminder-item-${item.id}'),
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Row(
        children: [
          Checkbox(
            key: ValueKey('reminder-check-${item.id}'),
            value: item.done,
            shape: const CircleBorder(),
            activeColor: _blue,
            onChanged: (done) => _edit(item.id, done: done ?? false),
          ),
          Expanded(
            // Typed or written with the pen: the pen's handwriting input
            // (stylusHandwritingEnabled, on by default) turns it into text.
            child: TextField(
              controller: text,
              autofocus: identical(item, _added),
              decoration: const InputDecoration.collapsed(hintText: '할 일'),
              keyboardType: TextInputType.text,
              textInputAction: TextInputAction.done,
              maxLines: null,
              style: item.done
                  ? const TextStyle(
                      color: _faint,
                      decoration: TextDecoration.lineThrough,
                    )
                  : null,
              onChanged: (value) => _edit(item.id, text: value),
            ),
          ),
          _timeChip(item, light, chipWidth),
          IconButton(
            key: ValueKey('reminder-delete-${item.id}'),
            tooltip: '삭제',
            color: _faint,
            icon: const Icon(Icons.close, size: 20),
            onPressed: () => _remove((other) => other.id == item.id),
          ),
        ],
      ),
    );
  }

  Widget _timeChip(ReminderItem item, bool light, double maxWidth) {
    final at = item.at;
    final now = _now();
    final late =
        at != null &&
        item.repeat == ReminderRepeat.none &&
        !item.done &&
        at.isBefore(now);
    final colour = late ? _red : _grey;
    return Tooltip(
      message: at == null ? '시간 정하기' : '시간 바꾸기',
      child: InkWell(
        key: ValueKey('reminder-time-${item.id}'),
        borderRadius: BorderRadius.circular(16),
        onTap: () => unawaited(_pickTime(item)),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minWidth: 40,
            minHeight: 48,
            maxWidth: maxWidth,
          ),
          child: Center(
            child: at == null
                ? const Icon(Icons.alarm_add_outlined, size: 20, color: _faint)
                : DecoratedBox(
                    decoration: BoxDecoration(
                      color: late
                          ? _red.withValues(alpha: 0.1)
                          : light
                          ? _chip
                          : Theme.of(context)
                                .colorScheme
                                .surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.alarm, size: 15, color: colour),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              _timeLabel(item, now),
                              maxLines: 1,
                              softWrap: false,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 13, color: colour),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
          ),
        ),
      ),
    );
  }

  Widget _doneToggle(int count) => Padding(
    padding: const EdgeInsets.only(top: 12, bottom: 4),
    child: InkWell(
      key: const ValueKey('reminder-done-toggle'),
      borderRadius: BorderRadius.circular(12),
      onTap: () => setState(() => _showDone = !_showDone),
      child: SizedBox(
        height: 44,
        child: Row(
          children: [
            const SizedBox(width: 8),
            Icon(
              _showDone ? Icons.expand_less : Icons.expand_more,
              color: _grey,
            ),
            const SizedBox(width: 8),
            Text('끝낸 일 $count개', style: const TextStyle(color: _grey)),
          ],
        ),
      ),
    ),
  );
}

String _two(int value) => value.toString().padLeft(2, '0');

String _clock(DateTime at) => '${_two(at.hour)}:${_two(at.minute)}';

/// As the widget writes it: 「오늘 09:00」, 「11/20 09:00」; a repeating task
/// shows its rule, 「매일 09:00」, 「매주 화 09:00」.
String _timeLabel(ReminderItem item, DateTime now) {
  final at = item.at!;
  final clock = _clock(at);
  return switch (item.repeat) {
    ReminderRepeat.daily => '매일 $clock',
    ReminderRepeat.weekly => '매주 ${_weekdays[at.weekday - 1]} $clock',
    ReminderRepeat.none when DateUtils.isSameDay(at, now) => '오늘 $clock',
    ReminderRepeat.none when at.year == now.year =>
      '${at.month}/${at.day} $clock',
    ReminderRepeat.none => '${at.year}/${at.month}/${at.day} $clock',
  };
}

/// 알림 시간: the day, the time and the repeat; 「시간 지우기」 takes the time
/// away.
class _TimeDialog extends StatefulWidget {
  const new({
    required this.initial,
    required this.repeat,
    required this.hasTime,
  });

  final DateTime initial;
  final ReminderRepeat repeat;
  final bool hasTime;

  @override
  State<_TimeDialog> createState() => _TimeDialogState();
}

class _TimeDialogState extends State<_TimeDialog> {
  late var _at = widget.initial;
  late var _repeat = widget.repeat;

  static const _repeats = [
    (ReminderRepeat.none, '반복 없음'),
    (ReminderRepeat.daily, '매일'),
    (ReminderRepeat.weekly, '매주'),
  ];

  Future<void> _pickDay() async {
    final day = await showDatePicker(
      context: context,
      initialDate: _at,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (day == null || !mounted) return;
    setState(
      () => _at = DateTime(day.year, day.month, day.day, _at.hour, _at.minute),
    );
  }

  Future<void> _pickClock() async {
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_at),
    );
    if (time == null || !mounted) return;
    setState(
      () =>
          _at = DateTime(_at.year, _at.month, _at.day, time.hour, time.minute),
    );
  }

  @override
  Widget build(BuildContext context) {
    final light = Theme.of(context).brightness == Brightness.light;
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      key: const ValueKey('reminder-time-dialog'),
      backgroundColor: light ? _page : null,
      surfaceTintColor: light ? Colors.transparent : null,
      title: const Text('알림 시간'),
      contentPadding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Material(
              color: light ? Colors.white : scheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(16),
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  ListTile(
                    key: const ValueKey('reminder-time-day'),
                    leading: const Icon(Icons.calendar_today_outlined),
                    title: Text(
                      '${_at.year}년 ${_at.month}월 ${_at.day}일 '
                      '(${_weekdays[_at.weekday - 1]})',
                    ),
                    onTap: _pickDay,
                  ),
                  Divider(height: 1, indent: 56, color: light ? _line : null),
                  ListTile(
                    key: const ValueKey('reminder-time-clock'),
                    leading: const Icon(Icons.schedule),
                    title: Text(_clock(_at)),
                    onTap: _pickClock,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final (repeat, label) in _repeats)
                  ChoiceChip(
                    key: ValueKey('reminder-repeat-${repeat.name}'),
                    label: Text(label),
                    selectedColor: light ? _paleBlue : null,
                    checkmarkColor: light ? _navy : null,
                    selected: _repeat == repeat,
                    onSelected: (_) => setState(() => _repeat = repeat),
                  ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        if (widget.hasTime)
          TextButton(
            key: const ValueKey('reminder-time-clear'),
            onPressed: () => Navigator.pop<_TimeChoice>(context, (
              at: null,
              repeat: ReminderRepeat.none,
            )),
            child: const Text('시간 지우기'),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('취소'),
        ),
        TextButton(
          key: const ValueKey('reminder-time-ok'),
          onPressed: () =>
              Navigator.pop<_TimeChoice>(context, (at: _at, repeat: _repeat)),
          child: const Text('확인'),
        ),
      ],
    );
  }
}
