import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:logging/logging.dart';
import 'package:saber/data/planner/planner_models.dart';
import 'package:saber/data/vault/fork_merge.dart';

typedef _Layer = ({
  List<InkStroke> strokes,
  Map<String, int> removed,
  int clearedAt,
});

/// What a read found: the entity's heads and each head's files, decoded, by
/// name.
typedef _Heads = ({
  List<RevisionRecord> heads,
  List<Map<String, Map<String, dynamic>>> files,
});

/// Stores the reminder note, the device events and the month handwriting as
/// three ownerless attachment entities with fixed ids, so they travel with the
/// vault through sync and backup. Two heads are merged on read, and the read
/// writes the merge back beside its caller, so the fork does not wait for an
/// edit to end.
///
/// The handwriting keeps each month in a file of its own,
/// `planner-ink-yyyy-MM.json`. Blobs are stored by their content, so a write
/// that changed one month adds only that month's file to the vault (and to
/// Drive); the size limit holds for each month. The old single
/// `planner-ink.json` is still read. Points are stored as whole numbers
/// ([InkStroke.toStoredJson]).
///
/// Deletions are kept as tombstones (an item with `deleted: true`, a removed
/// stroke id, a `clearedAt` time) so a merge cannot bring back what another
/// device deleted. Read methods return live data only; write methods take the
/// live data and turn whatever disappeared from it into tombstones. Tombstones
/// older than 60 days are dropped on write.
///
/// A writer that passes the ids (or stroke keys) it last read or wrote as
/// `known` keeps a stored one outside them: it reached the vault from another
/// device since, and the writer never saw it to delete it. Likewise an entry
/// passed with a time older than the stored one's is an old copy of a change
/// made elsewhere since, and the stored one stays; a writer stamps the
/// entries it changes with the time of the change.
///
/// A write publishes over exactly the heads it read. When they changed in
/// between (a sync, or a merge written back by a read) it starts over once,
/// so it never replaces what it did not read.
final class PlannerStore {
  const new(this.repository, {this.clock});

  final NoteRepository repository;

  /// Milliseconds since epoch; tests replace it.
  final int Function()? clock;

  static const remindersId = '5c9e7a12-8b34-4f6d-a1c2-3e8f9b0d7a45';
  static const eventsId = 'e2a4b6c8-1d3f-4a5b-8c7d-9e0f1a2b3c4d';
  static const inkId = '7f3a9c1e-5b2d-4e8f-b6a0-c4d2e8f1a3b5';

  static const _remindersFile = 'planner-reminders.json';
  static const _eventsFile = 'planner-events.json';

  /// The handwriting of every month in one file, as it was first kept; read,
  /// never written.
  static const _inkFile = 'planner-ink.json';
  static final _month = RegExp(r'^\d{4}-\d{2}$');
  static final _monthFile = RegExp(r'^planner-ink-(\d{4}-\d{2})\.json$');
  static const _maxBytes = 4 * 1024 * 1024;
  static const _tombstoneMs = 60 * 24 * 60 * 60 * 1000;
  static final _log = Logger('PIVPlanner');

  int get _now => (clock ?? () => DateTime.now().millisecondsSinceEpoch)();

  Future<ReminderNote> readReminders() async {
    final loaded = await _loadReminders();
    final raw = loaded.value;
    _mergeBack(
      remindersId,
      loaded.heads,
      () => {_remindersFile: _encode(_remindersJson(raw))},
    );
    return ReminderNote(
      items: [
        for (final item in raw.items)
          if (!item.deleted) item,
      ],
      memo: raw.memo,
      memoAspect: raw.memoAspect,
      memoRemoved: raw.memoRemoved,
      memoClearedAt: raw.memoClearedAt,
      memoChangedAt: raw.memoChangedAt,
    );
  }

  Future<void> writeReminders(
    ReminderNote note, {
    Set<String>? knownItems,
    Set<String>? knownStrokes,
  }) => _once(() async {
    final loaded = await _loadReminders();
    final stored = loaded.value;
    final now = _now;
    final layer = _writeLayer(
      stored: _layerOf(stored.memo, stored.memoRemoved, stored.memoClearedAt),
      given: note.memo,
      givenClearedAt: note.memoClearedAt,
      now: now,
      known: knownStrokes,
    );
    final memoChanged = layer.changed || note.memoAspect != stored.memoAspect;
    final written = ReminderNote(
      items: _writeTombstoned<ReminderItem>(
        stored.items,
        note.items,
        now,
        (item) => item.id,
        (item) => item.changedAt,
        (item) => item.deleted,
        (item, at) => item.copyWith(deleted: true, changedAt: at),
        (item, at) => item.copyWith(changedAt: at),
        (item) => item.toJson(),
        known: knownItems,
      ),
      memo: layer.layer.strokes,
      memoAspect: note.memoAspect,
      memoRemoved: layer.layer.removed,
      memoClearedAt: layer.layer.clearedAt,
      memoChangedAt: memoChanged
          ? now
          : (note.memoChangedAt > stored.memoChangedAt
                ? note.memoChangedAt
                : stored.memoChangedAt),
    );
    await _write(remindersId, loaded.heads, {
      _remindersFile: _encode(_remindersJson(written)),
    });
  });

  Future<List<PlannerEvent>> readEvents() async {
    final loaded = await _loadEvents();
    _mergeBack(
      eventsId,
      loaded.heads,
      () => {_eventsFile: _encode(_eventsJson(loaded.value))},
    );
    return [
      for (final event in loaded.value)
        if (!event.deleted) event,
    ];
  }

  Future<void> writeEvents(
    List<PlannerEvent> events, {
    Set<String>? known,
  }) => _once(() async {
    final loaded = await _loadEvents();
    final written = _writeTombstoned<PlannerEvent>(
      loaded.value,
      events,
      _now,
      (event) => event.id,
      (event) => event.changedAt,
      (event) => event.deleted,
      (event, at) => event.copyWith(deleted: true, changedAt: at),
      (event, at) => event.copyWith(changedAt: at),
      (event) => event.toJson(),
      known: known,
    );
    await _write(eventsId, loaded.heads, {
      _eventsFile: _encode(_eventsJson(written)),
    });
  });

  Future<Map<String, MonthInk>> readInk() async {
    final loaded = await _loadInk();
    _mergeBack(inkId, loaded.heads, () => _inkFiles(loaded.value.values));
    return {
      for (final entry in loaded.value.entries)
        if (entry.value.strokes.isNotEmpty) entry.key: entry.value,
    };
  }

  /// [known] holds each month's stroke keys; a month missing from it was
  /// never read.
  Future<void> writeInk(
    Map<String, MonthInk> months, {
    Map<String, Set<String>>? known,
  }) => _once(() async {
    final loaded = await _loadInk();
    final stored = loaded.value;
    final now = _now;
    final written = <MonthInk>[];
    for (final month in {...stored.keys, ...months.keys}) {
      final old = stored[month];
      final given = months[month];
      final layer = _writeLayer(
        stored: _layerOf(
          old?.strokes ?? const [],
          old?.removed ?? const {},
          old?.clearedAt ?? 0,
        ),
        given: given?.strokes ?? const [],
        givenClearedAt: given?.clearedAt ?? 0,
        now: now,
        known: known == null ? null : known[month] ?? const {},
      ).layer;
      written.add(
        MonthInk(
          month: month,
          strokes: layer.strokes,
          removed: layer.removed,
          clearedAt: layer.clearedAt,
        ),
      );
    }
    await _write(inkId, loaded.heads, _inkFiles(written));
  });

  /// Runs [write] once more when it could not publish because the heads it
  /// read changed meanwhile; the second try reads the vault again.
  Future<void> _once(Future<void> Function() write) async {
    try {
      await write();
    } on StateError {
      await write();
    }
  }

  /// Publishes [files] as the entity's next revision over exactly [heads],
  /// the heads its content was read from.
  Future<void> _write(
    String entityId,
    List<RevisionRecord> heads,
    Map<String, Uint8List> files,
  ) async {
    if (repository.formatVersion != 2) {
      throw StateError('보관함 형식을 올린 뒤 쓸 수 있습니다.');
    }
    final ids = [for (final head in heads) head.revisionId];
    final prepared = repository.prepareCommit(
      entityId: entityId,
      kind: EntityKind.attachment,
      files: files,
      parentRevisionIds: ids,
    );
    await repository.commitPreparedIfHeads(
      prepared,
      expectedHeads: {entityId: ids},
    );
  }

  /// A read that found two heads or more (another device's change came in by
  /// sync) writes what it merged back over exactly those heads, beside its
  /// caller. It is queued before the read returns, so the caller's next vault
  /// call comes after it; if it fails (the heads changed, the vault closed),
  /// the next read or write merges instead.
  void _mergeBack(
    String entityId,
    List<RevisionRecord> heads,
    Map<String, Uint8List> Function() files,
  ) {
    if (repository.formatVersion != 2 ||
        !writesMergeBack(heads, repository.deviceId)) {
      return;
    }
    void failed(Object error) =>
        _log.info('The planner merge was not written back: $error');
    final ids = [for (final head in heads) head.revisionId];
    try {
      unawaited(
        repository
            .commitPreparedIfHeads(
              repository.prepareCommit(
                entityId: entityId,
                kind: EntityKind.attachment,
                files: files(),
                parentRevisionIds: ids,
              ),
              expectedHeads: {entityId: ids},
            )
            .then<void>((_) {}, onError: failed),
      );
    } catch (error) {
      failed(error);
    }
  }

  static Uint8List _encode(Map<String, Object?> body) {
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(body)));
    if (bytes.length > _maxBytes) {
      throw const FormatException('플래너 정보가 너무 큽니다.');
    }
    return bytes;
  }

  static Map<String, Object?> _remindersJson(ReminderNote note) => {
    'version': 1,
    'items': [for (final item in note.items) item.toJson()],
    'memo': [for (final stroke in note.memo) stroke.toStoredJson()],
    'memoAspect': note.memoAspect,
    'memoRemoved': note.memoRemoved,
    'memoClearedAt': note.memoClearedAt,
    'memoChangedAt': note.memoChangedAt,
  };

  static Map<String, Object?> _eventsJson(List<PlannerEvent> events) => {
    'version': 1,
    'events': [for (final event in events) event.toJson()],
  };

  /// A file for each month that holds strokes or tombstones.
  static Map<String, Uint8List> _inkFiles(Iterable<MonthInk> months) => {
    for (final month in months)
      if (month.strokes.isNotEmpty || month.removed.isNotEmpty)
        _monthFileName(month.month): _encode({
          'version': 1,
          'strokes': [
            for (final stroke in month.strokes) stroke.toStoredJson(),
          ],
          'removed': month.removed,
          'clearedAt': month.clearedAt,
        }),
  };

  static String _monthFileName(String month) {
    if (!_month.hasMatch(month)) {
      throw FormatException('지원하지 않는 달입니다: $month');
    }
    return 'planner-ink-$month.json';
  }

  /// The heads of [entityId] and their files, which must all pass [accepts];
  /// a head of a [single] entity holds exactly one file.
  Future<_Heads> _readHeads(
    String entityId,
    bool Function(String name) accepts, {
    bool single = true,
  }) async {
    final heads = await repository.heads(entityId);
    final files = <Map<String, Map<String, dynamic>>>[];
    for (final head in heads) {
      if (head.formatVersion != 2 ||
          head.kind != EntityKind.attachment ||
          head.ownerNoteId != null ||
          head.deleted ||
          head.baseRefs.isNotEmpty ||
          (single && head.blobs.length != 1) ||
          head.blobs.entries.any(
            (file) => !accepts(file.key) || file.value.length > _maxBytes,
          )) {
        throw const FormatException('플래너 정보의 저장 형식을 확인할 수 없습니다.');
      }
      final decoded = <String, Map<String, dynamic>>{};
      for (final name in head.blobs.keys) {
        decoded[name] = jsonObject(
          jsonDecode(utf8.decode(await repository.readRevisionFile(head, name))),
        );
      }
      files.add(decoded);
    }
    return (heads: heads, files: files);
  }

  // ---- loading (merged over all heads, tombstones kept) ----

  Future<({ReminderNote value, List<RevisionRecord> heads})>
  _loadReminders() async {
    final read = await _readHeads(
      remindersId,
      (name) => name == _remindersFile,
    );
    var note = const ReminderNote();
    var first = true;
    for (final files in read.files) {
      final next = _decodeReminders(files[_remindersFile]!);
      note = first ? _mergeReminders(next, next) : _mergeReminders(note, next);
      first = false;
    }
    return (value: note, heads: read.heads);
  }

  Future<({List<PlannerEvent> value, List<RevisionRecord> heads})>
  _loadEvents() async {
    final read = await _readHeads(eventsId, (name) => name == _eventsFile);
    final byId = <String, PlannerEvent>{};
    for (final files in read.files) {
      for (final event in _decodeEvents(files[_eventsFile]!)) {
        final current = byId[event.id];
        if (current == null ||
            _newer(
              event.changedAt,
              event.deleted,
              current.changedAt,
              current.deleted,
            )) {
          byId[event.id] = event;
        }
      }
    }
    return (value: byId.values.toList(), heads: read.heads);
  }

  /// Larger changedAt wins; on a tie the tombstone wins.
  static bool _newer(
    int changedAt,
    bool deleted,
    int currentAt,
    bool currentDeleted,
  ) {
    if (changedAt != currentAt) return changedAt > currentAt;
    return deleted && !currentDeleted;
  }

  /// Every month of every head, from the month files and the old single
  /// file alike.
  Future<({Map<String, MonthInk> value, List<RevisionRecord> heads})>
  _loadInk() async {
    final read = await _readHeads(
      inkId,
      (name) => name == _inkFile || _monthFile.hasMatch(name),
      single: false,
    );
    final months = <String, MonthInk>{};
    for (final files in read.files) {
      for (final MapEntry(key: name, value: data) in files.entries) {
        final found = name == _inkFile
            ? _decodeInk(data).values
            : [_decodeMonthFile(_monthFile.firstMatch(name)![1]!, data)];
        for (final month in found) {
          final old = months[month.month];
          final merged = _mergeLayers(
            _layerOf(
              old?.strokes ?? const [],
              old?.removed ?? const {},
              old?.clearedAt ?? 0,
            ),
            _layerOf(month.strokes, month.removed, month.clearedAt),
          );
          months[month.month] = MonthInk(
            month: month.month,
            strokes: merged.strokes,
            removed: merged.removed,
            clearedAt: merged.clearedAt,
          );
        }
      }
    }
    return (value: months, heads: read.heads);
  }

  // ---- merge ----

  static _Layer _layerOf(
    List<InkStroke> strokes,
    Map<String, int> removed,
    int clearedAt,
  ) => (strokes: strokes, removed: removed, clearedAt: clearedAt);

  /// Union of strokes by key (larger changedAt wins), minus tombstoned
  /// strokes (a tombstone at least as new as the stroke wins) and minus
  /// strokes older than the larger clearedAt.
  static _Layer _mergeLayers(_Layer a, _Layer b) {
    final clearedAt = a.clearedAt > b.clearedAt ? a.clearedAt : b.clearedAt;
    final removed = {...a.removed};
    for (final entry in b.removed.entries) {
      final current = removed[entry.key];
      if (current == null || entry.value > current) {
        removed[entry.key] = entry.value;
      }
    }
    final byKey = <String, InkStroke>{};
    for (final stroke in [...a.strokes, ...b.strokes]) {
      final current = byKey[stroke.key];
      if (current == null || stroke.changedAt > current.changedAt) {
        byKey[stroke.key] = stroke;
      }
    }
    return (
      strokes: [
        for (final stroke in byKey.values)
          if (stroke.changedAt >= clearedAt &&
              (removed[stroke.key] ?? -1) < stroke.changedAt)
            stroke,
      ],
      removed: removed,
      clearedAt: clearedAt,
    );
  }

  static ReminderNote _mergeReminders(ReminderNote a, ReminderNote b) {
    final items = <String, ReminderItem>{
      for (final item in a.items) item.id: item,
    };
    for (final item in b.items) {
      final current = items[item.id];
      if (current == null ||
          _newer(
            item.changedAt,
            item.deleted,
            current.changedAt,
            current.deleted,
          )) {
        items[item.id] = item;
      }
    }
    final layer = _mergeLayers(
      _layerOf(a.memo, a.memoRemoved, a.memoClearedAt),
      _layerOf(b.memo, b.memoRemoved, b.memoClearedAt),
    );
    final bWins =
        b.memoChangedAt > a.memoChangedAt ||
        (b.memoChangedAt == a.memoChangedAt && b.memoAspect > a.memoAspect);
    return ReminderNote(
      items: items.values.toList(),
      memo: layer.strokes,
      memoAspect: bWins ? b.memoAspect : a.memoAspect,
      memoRemoved: layer.removed,
      memoClearedAt: layer.clearedAt,
      memoChangedAt: bWins ? b.memoChangedAt : a.memoChangedAt,
    );
  }

  // ---- write helpers ----

  /// The items to store: the given ones, plus a tombstone for every stored
  /// live item that is missing from [given] (one outside [known] stays as it
  /// is), plus still-young stored tombstones. A given item older than the
  /// stored one with other content is an old copy, and the stored one stays;
  /// a newer one keeps the time its writer stamped; a changed one without a
  /// new time gets now.
  static List<T> _writeTombstoned<T>(
    List<T> stored,
    List<T> given,
    int now,
    String Function(T) id,
    int Function(T) changedAt,
    bool Function(T) deleted,
    T Function(T, int) tombstone,
    T Function(T, int) stamp,
    Map<String, Object?> Function(T) json, {
    Set<String>? known,
  }) {
    final storedById = {for (final item in stored) id(item): item};
    final givenIds = {for (final item in given) id(item)};
    final result = <T>[];
    for (final item in given) {
      final old = storedById[id(item)];
      if (old == null) {
        result.add(changedAt(item) == 0 ? stamp(item, now) : item);
      } else if (_sameContent(json(item), json(old))) {
        final at = changedAt(item) > changedAt(old)
            ? changedAt(item)
            : changedAt(old);
        result.add(at == changedAt(item) ? item : stamp(item, at));
      } else if (changedAt(item) != 0 && changedAt(item) < changedAt(old)) {
        result.add(old);
      } else if (changedAt(item) > changedAt(old)) {
        result.add(item);
      } else {
        result.add(
          stamp(item, changedAt(old) >= now ? changedAt(old) + 1 : now),
        );
      }
    }
    for (final item in stored) {
      if (givenIds.contains(id(item))) continue;
      if (deleted(item) || (known != null && !known.contains(id(item)))) {
        result.add(item);
      } else {
        final at = changedAt(item) >= now ? changedAt(item) + 1 : now;
        result.add(tombstone(item, at));
      }
    }
    return [
      for (final item in result)
        if (!deleted(item) || changedAt(item) >= now - _tombstoneMs) item,
    ];
  }

  static bool _sameContent(Map<String, Object?> a, Map<String, Object?> b) =>
      jsonEncode({...a}..remove('changedAt')) ==
      jsonEncode({...b}..remove('changedAt'));

  /// The layer to store: given strokes (new ones stamped with an id and
  /// time; an old copy of a stroke changed since gives way, as items do), a
  /// tombstone for each stored live stroke missing from [given] (one outside
  /// [known] stays as it is), and clearedAt moved to now when everything was
  /// wiped. Strokes are compared as they are stored.
  static ({_Layer layer, bool changed}) _writeLayer({
    required _Layer stored,
    required List<InkStroke> given,
    required int givenClearedAt,
    required int now,
    Set<String>? known,
  }) {
    final storedByKey = {for (final s in stored.strokes) s.key: s};
    var changed = false;
    final strokes = <InkStroke>[];
    for (final stroke in given) {
      final key = stroke.key;
      final old = storedByKey[key];
      if (old == null) {
        if (stroke.changedAt == 0) {
          strokes.add(stroke.copyWith(id: key, changedAt: now));
          changed = true;
        } else {
          strokes.add(stroke.copyWith(id: key));
        }
      } else if (_sameContent(stroke.toStoredJson(), old.toStoredJson())) {
        final at = stroke.changedAt > old.changedAt
            ? stroke.changedAt
            : old.changedAt;
        strokes.add(stroke.copyWith(id: key, changedAt: at));
      } else if (stroke.changedAt != 0 && stroke.changedAt < old.changedAt) {
        strokes.add(old);
      } else {
        strokes.add(
          stroke.copyWith(
            id: key,
            changedAt: stroke.changedAt > old.changedAt
                ? stroke.changedAt
                : (old.changedAt >= now ? old.changedAt + 1 : now),
          ),
        );
        changed = true;
      }
    }
    final givenKeys = {for (final s in strokes) s.key};
    final removed = {...stored.removed};
    for (final entry in storedByKey.entries) {
      if (givenKeys.contains(entry.key)) continue;
      if (known != null && !known.contains(entry.key)) {
        strokes.add(entry.value);
        continue;
      }
      final at = entry.value.changedAt >= now ? entry.value.changedAt + 1 : now;
      removed[entry.key] = at;
      changed = true;
    }
    var clearedAt = stored.clearedAt > givenClearedAt
        ? stored.clearedAt
        : givenClearedAt;
    if (strokes.isEmpty && storedByKey.isNotEmpty && clearedAt < now) {
      clearedAt = now;
    }
    removed.removeWhere((_, at) => at < now - _tombstoneMs);
    return (layer: _layerOf(strokes, removed, clearedAt), changed: changed);
  }

  // ---- decoding ----

  static ReminderNote _decodeReminders(Map<String, dynamic> data) {
    const bad = FormatException('지원하지 않는 리마인더 정보입니다.');
    final items = data['items'];
    final memo = data['memo'];
    final aspect = data['memoAspect'];
    final clearedAt = data['memoClearedAt'] ?? 0;
    final changedAt = data['memoChangedAt'] ?? 0;
    if (data['version'] != 1 || items is! List || memo is! List) throw bad;
    if (aspect is! num || clearedAt is! int || changedAt is! int) throw bad;
    return ReminderNote(
      items: [for (final item in items) ReminderItem.fromJson(item)],
      memo: [for (final stroke in memo) InkStroke.fromJson(stroke)],
      memoAspect: aspect.toDouble(),
      memoRemoved: removedFromJson(data['memoRemoved']),
      memoClearedAt: clearedAt,
      memoChangedAt: changedAt,
    );
  }

  static List<PlannerEvent> _decodeEvents(Map<String, dynamic> data) {
    final events = data['events'];
    if (data['version'] != 1 || events is! List) {
      throw const FormatException('지원하지 않는 일정 정보입니다.');
    }
    return [for (final event in events) PlannerEvent.fromJson(event)];
  }

  /// The old single file: every month under `months`.
  static Map<String, MonthInk> _decodeInk(Map<String, dynamic> data) {
    final months = data['months'];
    if (data['version'] != 1 || months is! Map) throw _badMonth;
    final result = <String, MonthInk>{};
    for (final entry in months.entries) {
      final month = entry.key;
      if (month is! String) throw _badMonth;
      result[month] = _decodeMonth(month, entry.value);
    }
    return result;
  }

  /// A month file (`planner-ink-yyyy-MM.json`).
  static MonthInk _decodeMonthFile(String month, Map<String, dynamic> data) {
    if (data['version'] != 1) throw _badMonth;
    return _decodeMonth(month, data);
  }

  static const _badMonth = FormatException('지원하지 않는 달 필기 정보입니다.');

  /// One month's strokes, tombstones and clear time, as both files keep it.
  static MonthInk _decodeMonth(String month, Object? value) {
    if (!_month.hasMatch(month) ||
        value is! Map ||
        value['strokes'] is! List) {
      throw _badMonth;
    }
    final clearedAt = value['clearedAt'] ?? 0;
    if (clearedAt is! int) throw _badMonth;
    return MonthInk(
      month: month,
      strokes: [
        for (final stroke in value['strokes'] as List)
          InkStroke.fromJson(stroke),
      ],
      removed: removedFromJson(value['removed']),
      clearedAt: clearedAt,
    );
  }
}
