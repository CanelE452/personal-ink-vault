import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:saber/data/planner/handwriting_recognizer.dart';
import 'package:saber/data/planner/planner_models.dart';
import 'package:saber/pages/planner/month_grid.dart';

const _grey = Color(0xFF5F6368);
const _faint = Color(0xFF8A8A8A);
const _red = Color(0xFFD93025);

/// Notein's light look, as in reminder_page.dart: a light-grey dialog with
/// white groups.
const _page = Color(0xFFF2F2F7);
const _line = Color(0xFFE5E5EA);
const _chip = Color(0xFFEFEFF1);

const _weekdays = ['월', '화', '수', '목', '금', '토', '일'];

String _two(int value) => value.toString().padLeft(2, '0');

String _clock(DateTime at) => '${_two(at.hour)}:${_two(at.minute)}';

/// 「11월 20일 (금)」; the year comes first when it is not [thisYear].
String dayLabel(DateTime day, {int? thisYear}) {
  final date = '${day.month}월 ${day.day}일 (${_weekdays[day.weekday - 1]})';
  return thisYear == null || day.year == thisYear ? date : '${day.year}년 $date';
}

/// When [event] happens, for the day list.
String _when(PlannerEvent event) {
  final days = eventDays(event);
  final oneDay = days.first == days.last;
  String day(DateTime at) => '${at.month}월 ${at.day}일';
  if (event.allDay) {
    return oneDay ? '하루 종일' : '${day(days.first)} – ${day(days.last)}';
  }
  return oneDay
      ? '${_clock(event.start)} – ${_clock(event.end)}'
      : '${day(event.start)} ${_clock(event.start)} – '
            '${day(event.end)} ${_clock(event.end)}';
}

/// A calendar an event can live in: this device, or a Google calendar the
/// account can write to.
final class CalendarChoice {
  const new({required this.id, required this.name, required this.color});

  /// The Google calendar's id; null for this device.
  final String? id;
  final String name;

  /// ARGB.
  final int color;
}

/// Events kept in the vault on this device (and synced with it).
const deviceCalendar = CalendarChoice(id: null, name: '기기', color: 0xFF3D5AFE);

/// What the day sheet was closed with: an event to open, or none for
/// 「일정 추가」.
typedef DaySheetChoice = ({PlannerEvent? event});

/// The sheet a day tap opens (설계 7절): the day's events and 「＋ 일정 추가」.
/// Events [canEdit] refuses (a read-only Google calendar) are listed but do
/// not open.
Future<DaySheetChoice?> showDaySheet(
  BuildContext context, {
  required DateTime day,
  required List<PlannerEvent> events,
  required bool Function(PlannerEvent event) canEdit,
}) {
  final light = Theme.of(context).brightness == Brightness.light;
  return showModalBottomSheet<DaySheetChoice>(
    context: context,
    showDragHandle: true,
    backgroundColor: light ? Colors.white : null,
    builder: (context) => SafeArea(
      key: const ValueKey('event-sheet'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text(
              dayLabel(day),
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
            ),
          ),
          if (events.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              child: Text('일정이 없습니다', style: TextStyle(color: _faint)),
            )
          else
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final event in events)
                    ListTile(
                      key: ValueKey('event-sheet-item-${event.id}'),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 24,
                      ),
                      minLeadingWidth: 4,
                      leading: SizedBox(
                        width: 4,
                        height: 32,
                        child: ColoredBox(color: Color(event.color)),
                      ),
                      title: Text(
                        event.title.isEmpty ? '(제목 없음)' : event.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(_when(event)),
                      trailing: canEdit(event)
                          ? const Icon(Icons.chevron_right)
                          : null,
                      onTap: canEdit(event)
                          ? () => Navigator.pop<DaySheetChoice>(context, (
                              event: event,
                            ))
                          : null,
                    ),
                ],
              ),
            ),
          Divider(height: 1, color: light ? _line : null),
          ListTile(
            key: const ValueKey('event-add'),
            contentPadding: const EdgeInsets.symmetric(horizontal: 24),
            leading: const Icon(Icons.add),
            title: const Text('일정 추가'),
            onTap: () => Navigator.pop<DaySheetChoice>(context, (event: null)),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}

/// What the editor was closed with: the event to save, or the event to
/// delete.
typedef EventEdit = ({PlannerEvent event, bool delete});

/// 일정 편집 (설계 7절): the title (typed, or written with the pen through the
/// stylus handwriting input), 하루 종일, start and end, the calendar, save
/// and delete. [event] is the event as it stands; a new one comes with its
/// day, its default calendar and an empty title. [calendars] must hold the
/// event's calendar.
Future<EventEdit?> showEventEditor(
  BuildContext context, {
  required PlannerEvent event,
  required bool isNew,
  required List<CalendarChoice> calendars,
}) => showDialog<EventEdit>(
  context: context,
  builder: (_) =>
      _EventEditor(event: event, isNew: isNew, calendars: calendars),
);

class _EventEditor extends StatefulWidget {
  const new({
    required this.event,
    required this.isNew,
    required this.calendars,
  });

  final PlannerEvent event;
  final bool isNew;
  final List<CalendarChoice> calendars;

  @override
  State<_EventEditor> createState() => _EventEditorState();
}

class _EventEditorState extends State<_EventEditor> {
  late final _title = TextEditingController(text: widget.event.title);
  late var _allDay = widget.event.allDay;
  late var _start = widget.event.start;
  late var _end = widget.event.end;
  late var _calendar = math.max(
    0,
    widget.calendars.indexWhere(
      (choice) => choice.id == widget.event.calendarId,
    ),
  );

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  void _setAllDay(bool allDay) => setState(() {
    _allDay = allDay;
    if (!allDay && _start.hour == 0 && _start.minute == 0) {
      // A day becomes 09:00 to 10:00.
      _start = DateTime(_start.year, _start.month, _start.day, 9);
      _end = DateTime(_end.year, _end.month, _end.day, 10);
    }
  });

  void _setStart(DateTime start) => setState(() {
    _start = start;
    if (_end.isBefore(_start)) {
      _end = _allDay ? _start : _start.add(const Duration(hours: 1));
    }
  });

  void _setEnd(DateTime end) => setState(() {
    _end = end;
    if (_end.isBefore(_start)) {
      _start = _allDay ? _end : _end.subtract(const Duration(hours: 1));
    }
  });

  Future<void> _pickDay({required bool start}) async {
    final value = start ? _start : _end;
    final day = await showDatePicker(
      context: context,
      initialDate: value,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (day == null || !mounted) return;
    final next = DateTime(
      day.year,
      day.month,
      day.day,
      value.hour,
      value.minute,
    );
    start ? _setStart(next) : _setEnd(next);
  }

  Future<void> _pickTime({required bool start}) async {
    final value = start ? _start : _end;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(value),
    );
    if (time == null || !mounted) return;
    final next = DateTime(
      value.year,
      value.month,
      value.day,
      time.hour,
      time.minute,
    );
    start ? _setStart(next) : _setEnd(next);
  }

  void _save() {
    final title = _title.text.trim();
    if (title.isEmpty) return;
    final original = widget.event;
    final choice = widget.calendars[_calendar];
    // Moved to another calendar, it is a new event there.
    final same = choice.id == original.calendarId;
    Navigator.pop<EventEdit>(context, (
      event: PlannerEvent(
        id: original.id,
        title: title,
        start: _allDay ? DateUtils.dateOnly(_start) : _start,
        end: _allDay ? DateUtils.dateOnly(_end) : _end,
        allDay: _allDay,
        color: same ? original.color : choice.color,
        calendarId: choice.id,
        googleId: same ? original.googleId : null,
        changedAt: original.changedAt,
      ),
      delete: false,
    ));
  }

  Future<void> _delete() async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('이 일정을 삭제할까요?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          TextButton(
            key: const ValueKey('event-delete-ok'),
            style: TextButton.styleFrom(foregroundColor: _red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if ((sure ?? false) && mounted) {
      Navigator.pop<EventEdit>(context, (event: widget.event, delete: true));
    }
  }

  @override
  Widget build(BuildContext context) {
    final light = Theme.of(context).brightness == Brightness.light;
    final scheme = Theme.of(context).colorScheme;
    Widget group(List<Widget> rows) => Material(
      color: light ? Colors.white : scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (final (index, row) in rows.indexed) ...[
            if (index > 0)
              Divider(height: 1, indent: 16, color: light ? _line : null),
            row,
          ],
        ],
      ),
    );
    return AlertDialog(
      key: const ValueKey('event-editor'),
      backgroundColor: light ? _page : null,
      surfaceTintColor: light ? Colors.transparent : null,
      title: Text(widget.isNew ? '일정 추가' : '일정 편집'),
      contentPadding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              group([
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  // The pen's handwriting input (stylusHandwritingEnabled,
                  // on by default) turns writing into the title.
                  child: TextField(
                    key: const ValueKey('event-title'),
                    controller: _title,
                    autofocus: widget.isNew,
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                      hintText: '제목',
                    ),
                    textInputAction: TextInputAction.done,
                    onChanged: (_) => setState(() {}),
                    onSubmitted: (_) => _save(),
                  ),
                ),
              ]),
              const SizedBox(height: 12),
              group([
                SwitchListTile(
                  key: const ValueKey('event-all-day'),
                  title: const Text('하루 종일'),
                  value: _allDay,
                  onChanged: _setAllDay,
                ),
                _timeRow('시작', start: true, light: light),
                _timeRow('끝', start: false, light: light),
              ]),
              const SizedBox(height: 12),
              group([_calendarRow()]),
            ],
          ),
        ),
      ),
      actions: [
        if (!widget.isNew)
          TextButton(
            key: const ValueKey('event-delete'),
            style: TextButton.styleFrom(foregroundColor: _red),
            onPressed: _delete,
            child: const Text('삭제'),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('취소'),
        ),
        TextButton(
          key: const ValueKey('event-save'),
          onPressed: _title.text.trim().isEmpty ? null : _save,
          child: const Text('저장'),
        ),
      ],
    );
  }

  Widget _timeRow(String label, {required bool start, required bool light}) {
    final value = start ? _start : _end;
    final which = start ? 'start' : 'end';
    Widget chip(String key, String text, VoidCallback onPressed) => TextButton(
      key: ValueKey(key),
      style: TextButton.styleFrom(
        backgroundColor: light ? _chip : null,
        foregroundColor: light ? const Color(0xFF202124) : null,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        minimumSize: const Size(0, 36),
      ),
      onPressed: onPressed,
      child: Text(text),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 12, 6),
      child: Row(
        children: [
          SizedBox(width: 36, child: Text(label)),
          Expanded(
            child: Wrap(
              alignment: WrapAlignment.end,
              spacing: 6,
              runSpacing: 6,
              children: [
                chip(
                  'event-$which-day',
                  dayLabel(value, thisYear: widget.event.start.year),
                  () => _pickDay(start: start),
                ),
                if (!_allDay)
                  chip(
                    'event-$which-time',
                    _clock(value),
                    () => _pickTime(start: start),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _calendarRow() {
    final choices = widget.calendars;
    Widget label(CalendarChoice choice) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            color: Color(choice.color),
            shape: BoxShape.circle,
          ),
          child: const SizedBox.square(dimension: 10),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            choice.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
    return Padding(
      key: const ValueKey('event-calendar'),
      padding: const EdgeInsets.fromLTRB(16, 0, 12, 0),
      child: Row(
        children: [
          const SizedBox(width: 36, child: Text('달력')),
          Expanded(
            child: choices.length < 2
                ? Align(
                    alignment: Alignment.centerRight,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      child: label(choices.single),
                    ),
                  )
                : DropdownButtonHideUnderline(
                    child: DropdownButton<int>(
                      isExpanded: true,
                      value: _calendar,
                      items: [
                        for (final (index, choice) in choices.indexed)
                          DropdownMenuItem(value: index, child: label(choice)),
                      ],
                      onChanged: (index) =>
                          setState(() => _calendar = index ?? _calendar),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

/// The recognizer's reading of a day's handwriting in [language]: its
/// candidates, and why there are none. A null language means no engine.
typedef ConvertReading = ({
  String? language,
  List<String> candidates,
  String? notice,
});

/// 「글자로 바꾸기」 (설계 7절): the recognizer's reading of a day's handwriting,
/// to correct before it becomes that day's event. When there is no reading,
/// [notice] says why, and the empty field takes the pen's handwriting input.
/// With [language] and [onLanguage], 한국어 | 영어 reads the day in the other
/// language: [onLanguage] gives the new reading, the one shown to stay on it,
/// or null to close the dialog. Closes with the title, or null.
Future<String?> showConvertDialog(
  BuildContext context, {
  required DateTime day,
  required List<String> candidates,
  String? notice,
  String? language,
  Future<ConvertReading?> Function(String language)? onLanguage,
}) => showDialog<String>(
  context: context,
  builder: (_) => _ConvertDialog(
    day: day,
    candidates: candidates,
    notice: notice,
    language: language,
    onLanguage: onLanguage,
  ),
);

class _ConvertDialog extends StatefulWidget {
  const new({
    required this.day,
    required this.candidates,
    this.notice,
    this.language,
    this.onLanguage,
  });

  final DateTime day;
  final List<String> candidates;
  final String? notice;
  final String? language;
  final Future<ConvertReading?> Function(String language)? onLanguage;

  @override
  State<_ConvertDialog> createState() => _ConvertDialogState();
}

class _ConvertDialogState extends State<_ConvertDialog> {
  late var _language = widget.language;
  late var _candidates = widget.candidates;
  late var _notice = widget.notice;

  /// A reading in another language is on its way.
  var _reading = false;

  late final _text = TextEditingController(
    text: _candidates.firstOrNull ?? '',
  );

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _save() {
    final title = _text.text.trim();
    if (title.isNotEmpty) Navigator.pop(context, title);
  }

  /// Reads the day in [language]: the dialog shows the new reading, keeps
  /// its own, or closes.
  Future<void> _switch(String language) async {
    final read = widget.onLanguage;
    if (read == null || _reading) return;
    setState(() => _reading = true);
    final reading = await read(language);
    if (!mounted) return;
    if (reading == null) {
      Navigator.pop(context);
      return;
    }
    setState(() {
      _reading = false;
      if (reading.language != _language) {
        _text.text = reading.candidates.firstOrNull ?? '';
      }
      _language = reading.language;
      _candidates = reading.candidates;
      _notice = reading.notice;
    });
  }

  @override
  Widget build(BuildContext context) {
    final notice = _notice;
    final language = _language;
    return AlertDialog(
      key: const ValueKey('calendar-convert-dialog'),
      title: const Text('글자로 바꾸기'),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '${dayLabel(widget.day)} 일정으로 넣습니다.',
                style: const TextStyle(color: _grey),
              ),
              if (language != null && widget.onLanguage != null) ...[
                const SizedBox(height: 12),
                SegmentedButton<String>(
                  showSelectedIcon: false,
                  segments: [
                    for (final MapEntry(key: tag, value: info)
                        in handwritingLanguages.entries)
                      ButtonSegment(
                        value: tag,
                        // handwriting-language-ko, handwriting-language-en.
                        label: Text(
                          info.name,
                          key: ValueKey(
                            'handwriting-language-${tag.split('-').first}',
                          ),
                        ),
                      ),
                  ],
                  selected: {language},
                  onSelectionChanged: _reading
                      ? null
                      : (chosen) => unawaited(_switch(chosen.single)),
                ),
              ],
              if (notice != null) ...[
                const SizedBox(height: 12),
                Text(
                  notice,
                  key: const ValueKey('calendar-convert-notice'),
                  style: const TextStyle(color: _red),
                ),
              ],
              if (_candidates.length > 1) ...[
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final (index, candidate) in _candidates.indexed)
                      ActionChip(
                        key: ValueKey('calendar-convert-candidate-$index'),
                        label: Text(candidate),
                        onPressed: () => setState(() => _text.text = candidate),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('calendar-convert-text'),
                controller: _text,
                autofocus: true,
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  hintText: notice == null ? '일정 제목' : '펜으로 쓰거나 입력하세요',
                ),
                textInputAction: TextInputAction.done,
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _save(),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('취소'),
        ),
        TextButton(
          key: const ValueKey('calendar-convert-save'),
          onPressed: _text.text.trim().isEmpty ? null : _save,
          child: const Text('일정으로 저장'),
        ),
      ],
    );
  }
}

/// Asked after a converted day's event is saved: whether its handwriting
/// goes.
Future<bool> askEraseConverted(BuildContext context) async {
  final erase = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('바꾼 필기를 지울까요?'),
      actions: [
        TextButton(
          key: const ValueKey('calendar-convert-keep'),
          onPressed: () => Navigator.pop(context, false),
          child: const Text('남기기'),
        ),
        TextButton(
          key: const ValueKey('calendar-convert-erase'),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('지우기'),
        ),
      ],
    ),
  );
  return erase ?? false;
}

/// Asked before [language]'s handwriting model is downloaded: its size and
/// that Wi-Fi is better. True for 「받기」.
Future<bool> showModelNotice(
  BuildContext context, {
  required String language,
}) async {
  final model = handwritingLanguages[language]!;
  final download = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      key: const ValueKey('handwriting-model-notice'),
      title: Text('${model.name} 손글씨 모델'),
      content: Text(
        '${model.name} 손글씨를 글자로 바꾸려면 모델을 받아야 합니다.\n\n'
        '받는 크기: 약 ${model.download}\n'
        '기기 저장 공간: 약 ${model.stored}\n\n'
        'Wi-Fi에서 받는 것을 권장합니다.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('취소'),
        ),
        TextButton(
          key: const ValueKey('handwriting-model-download'),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('받기'),
        ),
      ],
    ),
  );
  return download ?? false;
}
