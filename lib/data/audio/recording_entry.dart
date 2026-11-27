import 'dart:convert';
import 'dart:typed_data';

import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:logging/logging.dart';
import 'package:saber/data/vault/note_side_store.dart';

/// One recording kept beside a note: the `recording.json` marker of a [NoteSideKind.recording] attachment, whose
/// audio sits beside it as `audio.m4a` (AAC-LC, mono, 48 kbps).
class RecordingEntry {
  const new({
    required this.noteId,
    required this.entityId,
    required this.name,
    required this.duration,
    required this.createdAt,
    required this.sizeBytes,
    required this.record,
    this.captureId,
  });

  final String noteId;
  final String entityId;
  final String name;

  /// The recorded length, paused time left out. Zero when the app stopped before the length was known.
  final Duration duration;

  /// When the recording started.
  final DateTime createdAt;

  /// The size of `audio.m4a` in bytes (the attachment write holds it in memory, twice).
  final int sizeBytes;

  /// The revision this entry was read from; [NoteRecordings.rename] and [NoteRecordings.delete] build on it.
  final NoteSideRecord record;

  /// The temporary capture this recording was saved from, so a retried save does not add it twice.
  final String? captureId;
}

/// Lists, adds, renames and deletes the recordings of a note through [NoteSideStore].
class NoteRecordings {
  new(this.store);
  final NoteSideStore store;
  static final _log = Logger('NoteRecordings');

  static const audioFile = 'audio.m4a';

  /// False in a format 1 vault, where notes cannot hold attachments.
  bool get available => store.available;

  /// Whether [noteId] is a single live note (not missing, split or deleted), checked before reading a kept
  /// recording's audio. [add] still guards the folders above the note.
  Future<bool> noteIsLive(String noteId) async {
    final heads = await store.repository.heads(noteId);
    return heads.length == 1 &&
        heads.single.kind == EntityKind.metadata &&
        !heads.single.deleted;
  }

  /// The live recordings of [noteId], newest first.
  Future<List<RecordingEntry>> list(String noteId) async {
    final entries = <RecordingEntry>[];
    for (final record in await store.list(noteId, NoteSideKind.recording)) {
      final head = _head(record);
      final marker = jsonDecode(
        utf8.decode(
          await store.repository.readRevisionFile(
            head,
            NoteSideKind.recording.markerFile,
          ),
        ),
      ) as Map;
      final size = head.blobs[audioFile]?.length;
      entries.add(_entry(noteId, record, marker, size ?? 0));
    }
    entries.sort((a, b) {
      final byTime = b.createdAt.compareTo(a.createdAt);
      return byTime != 0 ? byTime : a.entityId.compareTo(b.entityId);
    });
    return entries;
  }

  /// Saves [audio] as a new recording of [noteId] named [defaultName] over the recordings already there. Throws
  /// [StateError] like [NoteSideStore.write] when the note is missing, conflicted or in the trash.
  Future<RecordingEntry> add(
    String noteId, {
    required Uint8List audio,
    required Duration duration,
    required DateTime createdAt,
    String? captureId,
    List<RecordingEntry>? existing,
  }) async {
    final names = (existing ?? await list(noteId)).map((e) => e.name);
    final marker = {
      'schemaVersion': 1,
      'name': defaultName(names),
      'durationMs': duration.inMilliseconds,
      'createdAt': createdAt.toUtc().toIso8601String(),
      'captureId': ?captureId,
    };
    final record = await store.write(noteId, NoteSideKind.recording, {
      NoteSideKind.recording.markerFile: _encode(marker),
      audioFile: audio,
    });
    return _entry(noteId, record, marker, audio.length);
  }

  /// Writes [entry] again under [name] (the audio unchanged) over the revision it was read from. Throws
  /// [StateError] when another revision arrived meanwhile (list again and retry).
  Future<RecordingEntry> rename(RecordingEntry entry, String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) throw ArgumentError.value(name, 'name');
    final head = _head(entry.record);
    final repository = store.repository;
    final marker = jsonDecode(
      utf8.decode(
        await repository.readRevisionFile(
          head,
          NoteSideKind.recording.markerFile,
        ),
      ),
    ) as Map;
    marker['name'] = trimmed;
    final audio = await repository.readRevisionFile(head, audioFile);
    final record = await store.write(entry.noteId, NoteSideKind.recording, {
      NoteSideKind.recording.markerFile: _encode(marker),
      audioFile: audio,
    }, base: entry.record);
    return _entry(entry.noteId, record, marker, audio.length);
  }

  /// Marks [entry] deleted; throws [StateError] like [rename].
  Future<void> delete(RecordingEntry entry) => store.markDeleted(entry.record);

  /// Ends the splits two devices made of [noteId]'s recordings offline: a recording deleted on one keeps a deletion
  /// mark over all its heads ([NoteSideStore.joinDeleted]); one renamed on both gets the head [list] reads (the
  /// smallest revision id, as every device picks) written over its heads. Returns whether one was written. A write
  /// that fails is logged and left for the next time.
  Future<bool> joinSplits(String noteId) async {
    var joined = await store.joinDeleted(noteId, NoteSideKind.recording);
    for (final record in await store.list(noteId, NoteSideKind.recording)) {
      if (record.heads.length < 2) continue;
      try {
        await store.write(
          noteId,
          NoteSideKind.recording,
          await store.read(record),
          base: record,
        );
        joined = true;
      } on StateError catch (error) {
        _log.warning('Split recording ${record.entityId} not joined: $error');
      }
    }
    return joined;
  }

  /// The audio bytes of [entry].
  Future<Uint8List> readAudio(RecordingEntry entry) =>
      store.repository.readRevisionFile(_head(entry.record), audioFile);

  /// 「녹음 N」 with N one more than the number of [taken] names, counted up past names already in use.
  static String defaultName(Iterable<String> taken) {
    final names = taken.toSet();
    var n = taken.length + 1;
    while (names.contains('녹음 $n')) {
      n++;
    }
    return '녹음 $n';
  }

  RevisionRecord _head(NoteSideRecord record) =>
      record.heads.singleWhere((head) => head.revisionId == record.revisionId);

  static Uint8List _encode(Map<dynamic, dynamic> marker) =>
      Uint8List.fromList(utf8.encode(jsonEncode(marker)));

  static RecordingEntry _entry(
    String noteId,
    NoteSideRecord record,
    Map<dynamic, dynamic> marker,
    int size,
  ) {
    final name = marker['name'];
    final duration = marker['durationMs'];
    final createdAt = marker['createdAt'];
    final captureId = marker['captureId'];
    return RecordingEntry(
      noteId: noteId,
      entityId: record.entityId,
      name: name is String && name.trim().isNotEmpty ? name : '녹음',
      duration: Duration(milliseconds: duration is num ? duration.toInt() : 0),
      createdAt:
          (createdAt is String ? DateTime.tryParse(createdAt) : null) ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      sizeBytes: size,
      record: record,
      captureId: captureId is String ? captureId : null,
    );
  }
}
