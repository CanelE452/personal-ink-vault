import 'dart:convert';
import 'dart:typed_data';

import 'package:ink_vault_core/ink_vault_core.dart';

/// A user outline row pointing at a page by its stable `pageId`. A deleted row stays as a deletion mark so a merge
/// with an older copy does not bring it back.
class OutlineEntry {
  const new({
    required this.id,
    required this.pageId,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    this.deleted = false,
    this.extra = const {},
  });
  final String id;
  final String pageId;
  final String title;
  final DateTime createdAt;
  final DateTime updatedAt;
  final bool deleted;

  /// Keys this version does not know, kept so a newer app's fields survive a save.
  final Map<String, Object?> extra;

  OutlineEntry _changed({String? title, bool? deleted, required DateTime at}) =>
      OutlineEntry(
        id: id,
        pageId: pageId,
        title: title ?? this.title,
        createdAt: createdAt,
        updatedAt: at,
        deleted: deleted ?? this.deleted,
        extra: extra,
      );

  Map<String, Object?> _toJson() => {
    ...extra,
    'id': id,
    'pageId': pageId,
    'title': title,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'deleted': deleted,
  };

  factory _fromJson(Object? value) {
    final json = _object(value);
    return OutlineEntry(
      id: _string(json['id']),
      pageId: _string(json['pageId']),
      title: _string(json['title']),
      createdAt: _time(json['createdAt']),
      updatedAt: _time(json['updatedAt']),
      deleted: _bool(json['deleted']),
      extra: _unknownKeys(json, _keys),
    );
  }

  static const _keys = {
    'id',
    'pageId',
    'title',
    'createdAt',
    'updatedAt',
    'deleted',
  };
}

/// A change to one PDF outline line: a new title, or hidden. The PDF outline itself is read from the PDF each time;
/// only the change is stored, keyed by the page it leads to, its depth and its title in the PDF.
class OutlineRename {
  const new({
    required this.pageId,
    required this.depth,
    required this.originalTitle,
    this.title,
    this.hidden = false,
    required this.updatedAt,
    this.extra = const {},
  });
  final String pageId;
  final int depth;
  final String originalTitle;
  final String? title;
  final bool hidden;
  final DateTime updatedAt;

  /// Keys this version does not know, kept so a newer app's fields survive a save.
  final Map<String, Object?> extra;

  String get _key => jsonEncode([pageId, depth, originalTitle]);

  Map<String, Object?> _toJson() => {
    ...extra,
    'pageId': pageId,
    'depth': depth,
    'originalTitle': originalTitle,
    'title': title,
    'hidden': hidden,
    'updatedAt': updatedAt.toIso8601String(),
  };

  factory _fromJson(Object? value) {
    final json = _object(value);
    final depth = json['depth'];
    final title = json['title'];
    if (depth is! int || depth < 0 || (title != null && title is! String)) {
      throw const FormatException('Invalid PDF outline edit');
    }
    return OutlineRename(
      pageId: _string(json['pageId']),
      depth: depth,
      originalTitle: _string(json['originalTitle']),
      title: title as String?,
      hidden: _bool(json['hidden']),
      updatedAt: _time(json['updatedAt']),
      extra: _unknownKeys(json, _keys),
    );
  }

  static const _keys = {
    'pageId',
    'depth',
    'originalTitle',
    'title',
    'hidden',
    'updatedAt',
  };
}

class _Favorite {
  const new(this.pageId, this.updatedAt, this.deleted, this.extra);
  final String pageId;
  final DateTime updatedAt;
  final bool deleted;
  final Map<String, Object?> extra;

  Map<String, Object?> _toJson() => {
    ...extra,
    'pageId': pageId,
    'updatedAt': updatedAt.toIso8601String(),
    'deleted': deleted,
  };

  factory _fromJson(Object? value) {
    final json = _object(value);
    return _Favorite(
      _string(json['pageId']),
      _time(json['updatedAt']),
      _bool(json['deleted']),
      _unknownKeys(json, const {'pageId', 'updatedAt', 'deleted'}),
    );
  }
}

/// Favourite pages, the user outline and PDF outline edits of one note: the `page-marks.json` file of the note's
/// [NoteSideKind.pageMarks] attachment, schema version 1. Pages are named by `pageId`, so inserting or moving pages
/// keeps every mark on its page. Removing a favourite or an outline row keeps a deletion mark with its time.
///
/// Two heads (offline edits on two devices) join with [merge]: per favourite page, outline row id and PDF edit key, the
/// later `updatedAt` wins; on the same time a deletion wins, then the larger JSON, so every device gets the same
/// bytes. The order of the lists carries no meaning (the side panel orders by page).
class NotePageMarks {
  new();

  final _favorites = <String, _Favorite>{};
  final _outline = <String, OutlineEntry>{};
  final _pdfOutlineEdits = <String, OutlineRename>{};
  final _extra = <String, Object?>{};

  /// The favourite page ids, without deletion marks.
  List<String> get favorites => List.unmodifiable([
    for (final favorite in _favorites.values)
      if (!favorite.deleted) favorite.pageId,
  ]);

  /// Every outline row, deletion marks included (check [OutlineEntry.deleted]).
  List<OutlineEntry> get outline => List.unmodifiable(_outline.values);

  /// The outline rows to show: [outline] without deletion marks.
  List<OutlineEntry> get liveOutline =>
      List.unmodifiable(_outline.values.where((row) => !row.deleted));

  List<OutlineRename> get pdfOutlineEdits =>
      List.unmodifiable(_pdfOutlineEdits.values);

  void addFavorite(String pageId, {DateTime? at}) =>
      _setFavorite(pageId, false, at);

  void removeFavorite(String pageId, {DateTime? at}) =>
      _setFavorite(pageId, true, at);

  void _setFavorite(String pageId, bool deleted, DateTime? at) {
    _favorites[pageId] = _Favorite(
      pageId,
      _now(at),
      deleted,
      _favorites[pageId]?.extra ?? const {},
    );
  }

  OutlineEntry addOutline(String pageId, String title, {DateTime? at}) {
    final time = _now(at);
    final entry = OutlineEntry(
      id: newId(),
      pageId: pageId,
      title: title,
      createdAt: time,
      updatedAt: time,
    );
    _outline[entry.id] = entry;
    return entry;
  }

  void renameOutline(String id, String title, {DateTime? at}) =>
      _outline[id] = _row(id)._changed(title: title, at: _now(at));

  void removeOutline(String id, {DateTime? at}) =>
      _outline[id] = _row(id)._changed(deleted: true, at: _now(at));

  /// Undoes [removeOutline]: the row is live again, stamped [at] so it wins over the deletion in a merge.
  void restoreOutline(String id, {DateTime? at}) =>
      _outline[id] = _row(id)._changed(deleted: false, at: _now(at));

  /// Stores [edit] with its time in UTC, replacing any edit of the same page, depth and original title.
  void editPdfOutline(OutlineRename edit) =>
      _pdfOutlineEdits[edit._key] = OutlineRename(
        pageId: edit.pageId,
        depth: edit.depth,
        originalTitle: edit.originalTitle,
        title: edit.title,
        hidden: edit.hidden,
        updatedAt: _now(edit.updatedAt),
        extra: edit.extra,
      );

  OutlineEntry _row(String id) =>
      _outline[id] ?? (throw StateError('No outline row $id'));

  static DateTime _now(DateTime? at) => (at ?? DateTime.now()).toUtc();

  // ignore: prefer_constructors_over_static_methods
  static NotePageMarks decode(Uint8List bytes) {
    final json = _object(jsonDecode(utf8.decode(bytes)));
    if (json['schemaVersion'] != 1) {
      throw const FormatException('Unsupported page marks version');
    }
    final marks = NotePageMarks();
    marks._extra.addAll(_unknownKeys(json, _keys));
    for (final value in _list(json['favorites'])) {
      final favorite = _Favorite._fromJson(value);
      marks._favorites[favorite.pageId] = favorite;
    }
    for (final value in _list(json['outline'])) {
      final entry = OutlineEntry._fromJson(value);
      marks._outline[entry.id] = entry;
    }
    for (final value in _list(json['pdfOutlineEdits'])) {
      final edit = OutlineRename._fromJson(value);
      marks._pdfOutlineEdits[edit._key] = edit;
    }
    return marks;
  }

  Uint8List encode() => Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        ..._extra,
        'schemaVersion': 1,
        'favorites': [for (final f in _favorites.values) f._toJson()],
        'outline': [for (final row in _outline.values) row._toJson()],
        'pdfOutlineEdits': [
          for (final edit in _pdfOutlineEdits.values) edit._toJson(),
        ],
      }),
    ),
  );

  // ignore: prefer_constructors_over_static_methods
  static NotePageMarks merge(List<NotePageMarks> all) {
    final merged = NotePageMarks();
    for (final marks in all) {
      for (final entry in marks._extra.entries) {
        // A newer app's key with different values on two heads: the larger JSON with sorted keys wins, then (same
        // content, other key order) the larger JSON as written, so neither the input order nor the key order decides.
        merged._extra.update(entry.key, (kept) {
          final byContent = _sortedJson(kept)
              .compareTo(_sortedJson(entry.value));
          if (byContent != 0) return byContent > 0 ? kept : entry.value;
          return jsonEncode(kept).compareTo(jsonEncode(entry.value)) >= 0
              ? kept
              : entry.value;
        }, ifAbsent: () => entry.value);
      }
      for (final favorite in marks._favorites.values) {
        merged._favorites.update(
          favorite.pageId,
          (kept) => _later(
            kept,
            favorite,
            kept.updatedAt,
            favorite.updatedAt,
            kept.deleted,
            favorite.deleted,
            jsonEncode(kept._toJson()),
            jsonEncode(favorite._toJson()),
          ),
          ifAbsent: () => favorite,
        );
      }
      for (final row in marks._outline.values) {
        merged._outline.update(
          row.id,
          (kept) => _later(
            kept,
            row,
            kept.updatedAt,
            row.updatedAt,
            kept.deleted,
            row.deleted,
            jsonEncode(kept._toJson()),
            jsonEncode(row._toJson()),
          ),
          ifAbsent: () => row,
        );
      }
      for (final edit in marks._pdfOutlineEdits.values) {
        merged._pdfOutlineEdits.update(
          edit._key,
          (kept) => _later(
            kept,
            edit,
            kept.updatedAt,
            edit.updatedAt,
            false,
            false,
            jsonEncode(kept._toJson()),
            jsonEncode(edit._toJson()),
          ),
          ifAbsent: () => edit,
        );
      }
    }
    // Sort so the merged bytes do not depend on the order of the inputs.
    void sortMap<T>(Map<String, T> map, String Function(T) key) {
      final sorted = map.entries.toList()
        ..sort((a, b) => key(a.value).compareTo(key(b.value)));
      map
        ..clear()
        ..addEntries(sorted);
    }

    sortMap(merged._favorites, (f) => f.pageId);
    sortMap(
      merged._outline,
      (row) => '${row.createdAt.toIso8601String()} ${row.id}',
    );
    sortMap(merged._pdfOutlineEdits, (edit) => edit._key);
    final extra = merged._extra.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    merged._extra
      ..clear()
      ..addEntries(extra);
    return merged;
  }

  static T _later<T>(
    T a,
    T b,
    DateTime aAt,
    DateTime bAt,
    bool aDeleted,
    bool bDeleted,
    String aJson,
    String bJson,
  ) {
    final byTime = aAt.compareTo(bAt);
    if (byTime != 0) return byTime > 0 ? a : b;
    if (aDeleted != bDeleted) return aDeleted ? a : b;
    return aJson.compareTo(bJson) >= 0 ? a : b;
  }

  static const _keys = {
    'schemaVersion',
    'favorites',
    'outline',
    'pdfOutlineEdits',
  };
}

Map<String, Object?> _object(Object? value) {
  if (value is! Map<String, dynamic>) {
    throw const FormatException('Expected a JSON object');
  }
  return value;
}

List<Object?> _list(Object? value) {
  if (value == null) return const [];
  if (value is! List) throw const FormatException('Expected a JSON list');
  return value;
}

String _string(Object? value) =>
    value is String ? value : throw const FormatException('Expected a string');

bool _bool(Object? value) =>
    value is bool ? value : throw const FormatException('Expected a boolean');

DateTime _time(Object? value) {
  if (value is! String) throw const FormatException('Expected a time');
  return DateTime.parse(value).toUtc();
}

Map<String, Object?> _unknownKeys(
  Map<String, Object?> json,
  Set<String> known,
) => {
  for (final entry in json.entries)
    if (!known.contains(entry.key)) entry.key: entry.value,
};

/// [value] as JSON with the keys of every object sorted, so the same content
/// gives the same string whatever order its keys came in.
String _sortedJson(Object? value) {
  Object? sorted(Object? value) => switch (value) {
    final Map<dynamic, dynamic> map => {
      for (final key in map.keys.cast<String>().toList()..sort())
        key: sorted(map[key]),
    },
    final List<dynamic> list => [for (final item in list) sorted(item)],
    _ => value,
  };
  return jsonEncode(sorted(value));
}
