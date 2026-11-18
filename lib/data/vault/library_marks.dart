import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:logging/logging.dart';
import 'package:saber/data/vault/fork_merge.dart';

final class LibraryLabel {
  const new({
    required this.id,
    required this.name,
    required this.color,
    this.changedAt = 0,
  });

  final String id;
  final String name;

  /// ARGB.
  final int color;
  final int changedAt;
}

/// Favorites, pins, labels and cover colours of a vault's library screen.
/// Values are immutable; every change returns a new instance.
final class LibraryMarks {
  const new({
    required this.favorites,
    required this.pinned,
    required this.labels,
    required this.labelsOf,
    required this.covers,
  });

  static const empty = LibraryMarks(
    favorites: <String>{},
    pinned: <String>{},
    labels: <LibraryLabel>[],
    labelsOf: <String, Set<String>>{},
    covers: <String, ({int color, int changedAt})>{},
  );

  /// The [covers] value of 표지 변경's 형식 표지: an Office·한글 document shows
  /// its format's light cover with the format's name instead of its first
  /// page. Every colour cover is opaque, so this fully transparent value is
  /// never one; it is stored and merged like a colour, in the same JSON shape.
  static const formatCover = 0;

  final Set<String> favorites;
  final Set<String> pinned;
  final List<LibraryLabel> labels;
  final Map<String, Set<String>> labelsOf;

  /// ARGB colour covers, or [formatCover], by document or folder id.
  final Map<String, ({int color, int changedAt})> covers;

  LibraryMarks toggleFavorite(String id) =>
      _copy(favorites: _toggled(favorites, id));

  LibraryMarks togglePin(String id) => _copy(pinned: _toggled(pinned, id));

  LibraryMarks setLabels(String id, Set<String> labelIds) {
    final next = {for (final entry in labelsOf.entries) entry.key: entry.value};
    if (labelIds.isEmpty) {
      next.remove(id);
    } else {
      next[id] = Set.of(labelIds);
    }
    return _copy(labelsOf: next);
  }

  LibraryMarks putLabel(LibraryLabel label) {
    final next = [...labels];
    final at = next.indexWhere((existing) => existing.id == label.id);
    if (at < 0) {
      next.add(label);
    } else {
      next[at] = label;
    }
    return _copy(labels: next);
  }

  LibraryMarks removeLabel(String labelId) {
    final next = <String, Set<String>>{};
    for (final entry in labelsOf.entries) {
      final kept = entry.value.where((id) => id != labelId).toSet();
      if (kept.isNotEmpty) next[entry.key] = kept;
    }
    return _copy(
      labels: [
        for (final label in labels)
          if (label.id != labelId) label,
      ],
      labelsOf: next,
    );
  }

  LibraryMarks setCover(String id, int? color) {
    final next = {...covers};
    if (color == null) {
      next.remove(id);
    } else {
      next[id] = (
        color: color,
        changedAt: DateTime.now().millisecondsSinceEpoch,
      );
    }
    return _copy(covers: next);
  }

  // ignore: prefer_constructors_over_static_methods
  static LibraryMarks merge(LibraryMarks a, LibraryMarks b) {
    final labels = <String, LibraryLabel>{
      for (final label in a.labels) label.id: label,
    };
    for (final label in b.labels) {
      final current = labels[label.id];
      if (current == null || label.changedAt > current.changedAt) {
        labels[label.id] = label;
      }
    }
    final covers = {...a.covers};
    for (final entry in b.covers.entries) {
      final current = covers[entry.key];
      if (current == null || entry.value.changedAt > current.changedAt) {
        covers[entry.key] = entry.value;
      }
    }
    final labelsOf = <String, Set<String>>{};
    for (final source in [a.labelsOf, b.labelsOf]) {
      for (final entry in source.entries) {
        (labelsOf[entry.key] ??= {}).addAll(entry.value);
      }
    }
    return LibraryMarks(
      favorites: {...a.favorites, ...b.favorites},
      pinned: {...a.pinned, ...b.pinned},
      labels: labels.values.toList(),
      labelsOf: labelsOf,
      covers: covers,
    );
  }

  static Set<String> _toggled(Set<String> set, String id) {
    final next = {...set};
    if (!next.remove(id)) next.add(id);
    return next;
  }

  LibraryMarks _copy({
    Set<String>? favorites,
    Set<String>? pinned,
    List<LibraryLabel>? labels,
    Map<String, Set<String>>? labelsOf,
    Map<String, ({int color, int changedAt})>? covers,
  }) => LibraryMarks(
    favorites: favorites ?? this.favorites,
    pinned: pinned ?? this.pinned,
    labels: labels ?? this.labels,
    labelsOf: labelsOf ?? this.labelsOf,
    covers: covers ?? this.covers,
  );
}

/// Stores [LibraryMarks] as one ownerless attachment entity with a fixed id,
/// so the marks travel with the vault through sync and backup.
final class LibraryMarksStore {
  const new(this.repository);

  final NoteRepository repository;

  static const entityId = 'b7d1c2a4-3f5e-4c8a-9e21-6a0f4d7c8e13';
  static const fileName = 'library-marks.json';
  static const _maxBytes = 256 * 1024;
  static final _log = Logger('PIVLibrary');

  /// The marks of every head merged. A read that found two heads or more
  /// (another device's change came in by sync) writes the merge back over
  /// exactly those heads, beside its caller, so the top bar's cloud stops
  /// reporting a conflict without waiting for an edit (설계 13절). That
  /// write is queued before the read returns; if it fails (the heads
  /// changed, the vault closed), the next read or write merges instead.
  Future<LibraryMarks> read() async {
    final heads = await repository.heads(entityId);
    var marks = LibraryMarks.empty;
    for (final head in heads) {
      marks = LibraryMarks.merge(marks, await _read(head));
    }
    if (repository.formatVersion == 2 &&
        writesMergeBack(heads, repository.deviceId)) {
      unawaited(
        write(marks, over: heads).then<void>(
          (_) {},
          onError: (Object error) => _log.info(
            'The library marks merge was not written back: $error',
          ),
        ),
      );
    }
    return marks;
  }

  /// Writes [marks] over the current heads, or [over] exactly the heads
  /// they were read from.
  Future<LibraryMarks> write(
    LibraryMarks marks, {
    List<RevisionRecord>? over,
  }) async {
    if (repository.formatVersion != 2) {
      throw StateError('보관함 형식을 올린 뒤 쓸 수 있습니다.');
    }
    final heads = [
      for (final head in over ?? await repository.heads(entityId))
        head.revisionId,
    ];
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(_encode(marks))));
    if (bytes.length > _maxBytes) {
      throw const FormatException('보관함 표시 정보가 너무 큽니다.');
    }
    final prepared = repository.prepareCommit(
      entityId: entityId,
      kind: EntityKind.attachment,
      files: {fileName: bytes},
      parentRevisionIds: heads,
    );
    await repository.commitPreparedIfHeads(
      prepared,
      expectedHeads: {entityId: heads},
    );
    return marks;
  }

  Future<LibraryMarks> _read(RevisionRecord head) async {
    final ref = head.blobs[fileName];
    if (head.formatVersion != 2 ||
        head.kind != EntityKind.attachment ||
        head.ownerNoteId != null ||
        head.deleted ||
        head.baseRefs.isNotEmpty ||
        head.blobs.length != 1 ||
        ref == null ||
        ref.length > _maxBytes) {
      throw const FormatException('보관함 표시 정보의 저장 형식을 확인할 수 없습니다.');
    }
    final data = jsonObject(
      jsonDecode(
        utf8.decode(await repository.readRevisionFile(head, fileName)),
      ),
    );
    return _decode(data);
  }

  static Map<String, Object?> _encode(LibraryMarks marks) => {
    'version': 1,
    'favorites': marks.favorites.toList()..sort(),
    'pinned': marks.pinned.toList()..sort(),
    'labels': [
      for (final label in marks.labels)
        {
          'id': label.id,
          'name': label.name,
          'color': label.color,
          'changedAt': label.changedAt,
        },
    ],
    'labelsOf': {
      for (final entry in marks.labelsOf.entries)
        entry.key: entry.value.toList()..sort(),
    },
    'covers': {
      for (final entry in marks.covers.entries)
        entry.key: {
          'color': entry.value.color,
          'changedAt': entry.value.changedAt,
        },
    },
  };

  static LibraryMarks _decode(Map<String, dynamic> data) {
    const bad = FormatException('지원하지 않는 보관함 표시 정보입니다.');
    if (data['version'] != 1) throw bad;
    Set<String> strings(Object? value) {
      if (value is! List || value.any((item) => item is! String)) throw bad;
      return value.cast<String>().toSet();
    }

    final labelsJson = data['labels'];
    final labelsOfJson = data['labelsOf'];
    final coversJson = data['covers'];
    if (labelsJson is! List || labelsOfJson is! Map || coversJson is! Map) {
      throw bad;
    }
    final labels = <LibraryLabel>[];
    for (final item in labelsJson) {
      if (item is! Map ||
          item['id'] is! String ||
          item['name'] is! String ||
          item['color'] is! int ||
          item['changedAt'] is! int) {
        throw bad;
      }
      labels.add(
        LibraryLabel(
          id: item['id'] as String,
          name: item['name'] as String,
          color: item['color'] as int,
          changedAt: item['changedAt'] as int,
        ),
      );
    }
    final covers = <String, ({int color, int changedAt})>{};
    for (final entry in coversJson.entries) {
      final value = entry.value;
      if (entry.key is! String ||
          value is! Map ||
          value['color'] is! int ||
          value['changedAt'] is! int) {
        throw bad;
      }
      covers[entry.key as String] = (
        color: value['color'] as int,
        changedAt: value['changedAt'] as int,
      );
    }
    return LibraryMarks(
      favorites: strings(data['favorites']),
      pinned: strings(data['pinned']),
      labels: labels,
      labelsOf: {
        for (final entry in labelsOfJson.entries)
          if (entry.key is String) entry.key as String: strings(entry.value),
      },
      covers: covers,
    );
  }
}
