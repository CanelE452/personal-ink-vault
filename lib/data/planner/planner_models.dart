/// A pen stroke on a planner surface. Points are [x0, y0, x1, y1, ...] in
/// 0..1 of the surface, width is a fraction of the surface width.
///
/// An empty [id] means "not stamped yet"; [key] then falls back to an id
/// derived from the content, so the same stroke has the same key everywhere.
final class InkStroke {
  const new({
    required this.points,
    required this.color,
    required this.width,
    this.id = '',
    this.changedAt = 0,
  });

  final List<double> points;

  /// ARGB.
  final int color;
  final double width;
  final String id;
  final int changedAt;

  String get key => id.isEmpty ? contentId(points, color, width) : id;

  InkStroke copyWith({String? id, int? changedAt}) => InkStroke(
    points: points,
    color: color,
    width: width,
    id: id ?? this.id,
    changedAt: changedAt ?? this.changedAt,
  );

  /// Deterministic id from the content (64-bit FNV-1a).
  static String contentId(List<double> points, int color, double width) {
    var hash = 0xcbf29ce484222325;
    for (final unit in 'c$color/$width/${points.join(',')}'.codeUnits) {
      hash = (hash ^ unit) * 0x100000001b3;
    }
    return 'c${hash.toUnsigned(64).toRadixString(16)}';
  }

  Map<String, Object?> toJson() => {
    'id': key,
    'points': points,
    'color': color,
    'width': width,
    'changedAt': changedAt,
  };

  /// A stored point is a whole number: its 0..1 value times this, rounded
  /// (four decimal places, as the pad draws them).
  static const storedScale = 10000;

  /// As the planner store keeps it: [toJson] with whole-number points
  /// (see [storedScale]), which [fromJson] reads back as 0..1.
  Map<String, Object?> toStoredJson() => {
    ...toJson(),
    'points': [for (final value in points) (value * storedScale).round()],
  };

  /// Reads [toJson] and [toStoredJson] alike: whole-number points are
  /// stored ones, fractions are 0..1 as older data has them.
  // ignore: prefer_constructors_over_static_methods
  static InkStroke fromJson(Object? json) {
    const bad = FormatException('지원하지 않는 필기 형식입니다.');
    if (json is! Map) throw bad;
    final points = json['points'];
    final color = json['color'];
    final width = json['width'];
    final id = json['id'];
    final changedAt = json['changedAt'];
    if (points is! List ||
        points.any((value) => value is! num) ||
        color is! int ||
        width is! num ||
        (id != null && id is! String) ||
        (changedAt != null && changedAt is! int)) {
      throw bad;
    }
    final doubles = [
      for (final value in points)
        if (value is int) value / storedScale else (value as num).toDouble(),
    ];
    return InkStroke(
      points: doubles,
      color: color,
      width: width.toDouble(),
      id: (id as String?) ?? contentId(doubles, color, width.toDouble()),
      changedAt: (changedAt as int?) ?? 0,
    );
  }
}

/// Parses `{strokeId: removedAt}`; absent means no tombstones.
Map<String, int> removedFromJson(Object? json) {
  if (json == null) return const {};
  if (json is! Map || json.values.any((value) => value is! int)) {
    throw const FormatException('지원하지 않는 필기 삭제 기록입니다.');
  }
  return {
    for (final entry in json.entries) entry.key as String: entry.value as int,
  };
}

enum ReminderRepeat { none, daily, weekly }

final class ReminderItem {
  const new({
    required this.id,
    required this.text,
    this.at,
    this.repeat = ReminderRepeat.none,
    this.done = false,
    this.order = 0,
    this.changedAt = 0,
    this.deleted = false,
  });

  final String id;
  final String text;
  final DateTime? at;
  final ReminderRepeat repeat;
  final bool done;
  final int order;
  final int changedAt;

  /// Tombstone: kept in storage so a deletion survives a merge.
  final bool deleted;

  ReminderItem copyWith({bool? deleted, int? changedAt}) => ReminderItem(
    id: id,
    text: text,
    at: at,
    repeat: repeat,
    done: done,
    order: order,
    changedAt: changedAt ?? this.changedAt,
    deleted: deleted ?? this.deleted,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'text': text,
    'at': at?.millisecondsSinceEpoch,
    'repeat': repeat.name,
    'done': done,
    'order': order,
    'changedAt': changedAt,
    'deleted': deleted,
  };

  // ignore: prefer_constructors_over_static_methods
  static ReminderItem fromJson(Object? json) {
    const bad = FormatException('지원하지 않는 리마인더 형식입니다.');
    if (json is! Map ||
        json['id'] is! String ||
        json['text'] is! String ||
        (json['at'] != null && json['at'] is! int) ||
        json['done'] is! bool ||
        json['order'] is! int ||
        json['changedAt'] is! int ||
        (json['deleted'] != null && json['deleted'] is! bool)) {
      throw bad;
    }
    final repeat = ReminderRepeat.values.where(
      (value) => value.name == json['repeat'],
    );
    if (repeat.isEmpty) throw bad;
    final at = json['at'] as int?;
    return ReminderItem(
      id: json['id'] as String,
      text: json['text'] as String,
      at: at == null ? null : DateTime.fromMillisecondsSinceEpoch(at),
      repeat: repeat.single,
      done: json['done'] as bool,
      order: json['order'] as int,
      changedAt: json['changedAt'] as int,
      deleted: (json['deleted'] as bool?) ?? false,
    );
  }
}

final class ReminderNote {
  const new({
    this.items = const [],
    this.memo = const [],
    this.memoAspect = 2.5,
    this.memoRemoved = const {},
    this.memoClearedAt = 0,
    this.memoChangedAt = 0,
  });

  final List<ReminderItem> items;
  final List<InkStroke> memo;

  /// Memo area width divided by height.
  final double memoAspect;

  /// Tombstones of erased memo strokes: stroke key to removal time. Kept by
  /// the store; callers can leave it empty when writing.
  final Map<String, int> memoRemoved;

  /// Strokes older than this were cleared.
  final int memoClearedAt;

  /// When the memo (strokes or aspect) last changed; decides the aspect when
  /// two devices disagree.
  final int memoChangedAt;
}

final class PlannerEvent {
  const new({
    required this.id,
    required this.title,
    required this.start,
    required this.end,
    this.allDay = true,
    this.color = 0xFF3D5AFE,
    this.calendarId,
    this.googleId,
    this.changedAt = 0,
    this.deleted = false,
  });

  final String id;
  final String title;

  /// Local time.
  final DateTime start;

  /// Local time; for an all-day event this is the last day, inclusive.
  final DateTime end;
  final bool allDay;

  /// ARGB.
  final int color;
  final String? calendarId;
  final String? googleId;
  final int changedAt;

  /// Tombstone: kept in storage so a deletion survives a merge.
  final bool deleted;

  PlannerEvent copyWith({bool? deleted, int? changedAt}) => PlannerEvent(
    id: id,
    title: title,
    start: start,
    end: end,
    allDay: allDay,
    color: color,
    calendarId: calendarId,
    googleId: googleId,
    changedAt: changedAt ?? this.changedAt,
    deleted: deleted ?? this.deleted,
  );

  /// All-day dates are stored as calendar dates ('yyyy-MM-dd') so another
  /// time zone does not shift the day; timed events stay epoch milliseconds.
  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'start': allDay ? _dateText(start) : start.millisecondsSinceEpoch,
    'end': allDay ? _dateText(end) : end.millisecondsSinceEpoch,
    'allDay': allDay,
    'color': color,
    'calendarId': calendarId,
    'googleId': googleId,
    'changedAt': changedAt,
    'deleted': deleted,
  };

  static String _dateText(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';

  static DateTime _time(Object? value, FormatException bad) {
    if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
    if (value is String) {
      final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(value);
      if (match != null) {
        return DateTime(
          int.parse(match[1]!),
          int.parse(match[2]!),
          int.parse(match[3]!),
        );
      }
    }
    throw bad;
  }

  // ignore: prefer_constructors_over_static_methods
  static PlannerEvent fromJson(Object? json) {
    const bad = FormatException('지원하지 않는 일정 형식입니다.');
    if (json is! Map ||
        json['id'] is! String ||
        json['title'] is! String ||
        json['allDay'] is! bool ||
        json['color'] is! int ||
        (json['calendarId'] != null && json['calendarId'] is! String) ||
        (json['googleId'] != null && json['googleId'] is! String) ||
        json['changedAt'] is! int ||
        (json['deleted'] != null && json['deleted'] is! bool)) {
      throw bad;
    }
    return PlannerEvent(
      id: json['id'] as String,
      title: json['title'] as String,
      start: _time(json['start'], bad),
      end: _time(json['end'], bad),
      allDay: json['allDay'] as bool,
      color: json['color'] as int,
      calendarId: json['calendarId'] as String?,
      googleId: json['googleId'] as String?,
      changedAt: json['changedAt'] as int,
      deleted: (json['deleted'] as bool?) ?? false,
    );
  }
}

/// Handwriting laid over one month of the calendar grid.
final class MonthInk {
  const new({
    required this.month,
    this.strokes = const [],
    this.removed = const {},
    this.clearedAt = 0,
  });

  /// yyyy-MM.
  final String month;
  final List<InkStroke> strokes;

  /// Tombstones of erased strokes: stroke key to removal time. Kept by the
  /// store; callers can leave it empty when writing.
  final Map<String, int> removed;

  /// Strokes older than this were cleared.
  final int clearedAt;
}
