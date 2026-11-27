import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';

/// The kinds of data kept beside a note, each named by the file that marks its attachment.
enum NoteSideKind {
  pageMarks('page-marks.json'),
  quickNote('quick-note.json'),
  recording('recording.json');

  new(this.markerFile);

  /// The JSON file every revision of this kind carries, a deletion mark included.
  final String markerFile;
}

/// One attachment found for a note. [heads] holds every current head (two or more after offline edits on two
/// devices); [revisionId] is the head [NoteSideStore.read] reads, the smallest revision id so every device picks the
/// same one. Read the other heads with [NoteRepository.readFiles] to merge them, then pass this record as the `base`
/// of [NoteSideStore.write] so the write fails if another head arrived meanwhile.
class NoteSideRecord {
  const new({
    required this.entityId,
    required this.revisionId,
    required this.heads,
    required this.kind,
  });
  final String entityId;
  final String revisionId;
  final List<RevisionRecord> heads;
  final NoteSideKind kind;
}

/// Keeps favourites, the user outline, the quick note and recordings in attachments owned by the note, outside the
/// note's ink entity, so older apps still open the note (their ink adapter rejects unknown files in the ink entity)
/// and rename, move, trash and Drive sync carry the attachments by owner id. Other attachment readers pick their own
/// marker files, so they skip these. A deleted attachment gets a revision whose marker file reads
/// `{"schemaVersion": 1, "deleted": true}`; it is left out of [list]. A marker file without `"schemaVersion": 1` (a
/// user's own file that happens to share the name) is not one of these attachments.
class NoteSideStore {
  new(this.repository);
  final NoteRepository repository;
  static final _log = Logger('NoteSideStore');

  /// Runs after [write] has read the heads it guards and before it commits, so a test can change them in between.
  @visibleForTesting
  Future<void> Function()? beforeCommit;

  /// Format 1 vaults cannot hold attachments.
  bool get available => repository.formatVersion >= 2;

  /// Whether an entity with [heads] is one of these attachments: every head
  /// is an attachment carrying a [NoteSideKind] marker file. They join their
  /// own splits (on writing, and the editor on opening the note), so a split
  /// there is no conflict for the note, and the conflict window leaves them
  /// out. Other attachments (a PDF source, an Office copy) are not.
  static bool joinsItself(List<RevisionRecord> heads) =>
      heads.isNotEmpty &&
      heads.every(
        (head) =>
            head.kind == EntityKind.attachment &&
            NoteSideKind.values.any(
              (kind) => head.blobs.containsKey(kind.markerFile),
            ),
      );

  /// The live attachments of [kind] owned by [noteId], in entity id order. An attachment with a deletion mark among
  /// its heads is left out (deleting wins over a concurrent edit). A head whose marker cannot be read is skipped and
  /// logged; the rest of the list still comes back. Such a skipped head cannot hide its attachment even if it was a
  /// deletion mark (its content is unknown), unless the revision itself carries the repository's `deleted` flag.
  Future<List<NoteSideRecord>> list(String noteId, NoteSideKind kind) async {
    if (!available) return const [];
    final result = <NoteSideRecord>[];
    for (final entry in (await _heads(noteId, kind)).entries) {
      final live = <RevisionRecord>[];
      var deleted = false;
      for (final head in entry.value) {
        if (head.deleted) {
          deleted = true;
          break;
        }
        final marker = await _marker(head, kind);
        if (marker == null) continue;
        if (marker['deleted'] == true) deleted = true;
        live.add(head);
      }
      if (deleted || live.isEmpty) continue;
      live.sort((a, b) => a.revisionId.compareTo(b.revisionId));
      result.add(
        NoteSideRecord(
          entityId: entry.key,
          revisionId: live.first.revisionId,
          heads: List.unmodifiable(live),
          kind: kind,
        ),
      );
    }
    result.sort((a, b) => a.entityId.compareTo(b.entityId));
    return result;
  }

  /// Every head of each attachment of [kind] owned by [noteId], by entity id, deleted ones and unreadable ones too.
  Future<Map<String, List<RevisionRecord>>> _heads(
    String noteId,
    NoteSideKind kind,
  ) async {
    final records = await repository.revisions();
    final parents = {for (final record in records) ...record.parentRevisionIds};
    final heads = <String, List<RevisionRecord>>{};
    for (final record in records) {
      if (record.kind != EntityKind.attachment ||
          record.ownerNoteId != noteId ||
          !record.blobs.containsKey(kind.markerFile) ||
          parents.contains(record.revisionId)) {
        continue;
      }
      (heads[record.entityId] ??= []).add(record);
    }
    return heads;
  }

  /// Whether the vault holds a head of [r]'s attachment that [r] does not (one [list] could not read, or one that
  /// arrived after it): a write over [r] is refused while it is there.
  Future<bool> hasUnlistedHead(NoteSideRecord r) async {
    final listed = {for (final head in r.heads) head.revisionId};
    return (await repository.heads(r.entityId))
        .any((head) => !listed.contains(head.revisionId));
  }

  /// Ends the splits of [kind] owned by [noteId] that have a deletion mark among their heads (hidden by [list], so
  /// never joined by a write): a deletion mark goes over all their heads, as deleting wins. Returns whether one was
  /// written. A write that fails (the note is in the trash, another head arrived) is logged and left for the next time.
  Future<bool> joinDeleted(String noteId, NoteSideKind kind) async {
    if (!available) return false;
    var joined = false;
    final all = await _heads(noteId, kind);
    for (final MapEntry(key: entityId, value: heads) in all.entries) {
      if (heads.length < 2) continue;
      var deleted = false;
      for (final head in heads) {
        if (head.deleted || (await _marker(head, kind))?['deleted'] == true) {
          deleted = true;
        }
      }
      if (!deleted) continue;
      try {
        await markDeleted(
          NoteSideRecord(
            entityId: entityId,
            revisionId: heads.first.revisionId,
            heads: heads,
            kind: kind,
          ),
        );
        joined = true;
      } on StateError catch (error) {
        _log.warning('Split ${kind.name} $entityId not joined: $error');
      }
    }
    return joined;
  }

  /// The files of the head named by [NoteSideRecord.revisionId].
  Future<Map<String, Uint8List>> read(NoteSideRecord r) => repository.readFiles(
    r.heads.singleWhere((head) => head.revisionId == r.revisionId),
  );

  /// Writes [files] as a new attachment of [noteId], or, with [base] (a record from [list]), as the next revision of
  /// that attachment whose parents are the heads [base] saw (joining a split). The commit is guarded by those heads,
  /// the note's head and the heads of the folders above the note (all read here, at write time), so it throws
  /// [StateError] when another head arrived after reading (read again and merge), or when the note is missing,
  /// conflicted or in the trash (an attachment there would bring the note back as a deletion conflict). [files] must
  /// hold the kind's marker file.
  ///
  /// If [list] skipped an unreadable head of [base]'s attachment, the guard never matches and this throws every time.
  /// When a fresh [list] still gives the same failure, treat that attachment as dead and write a new one (no [base]).
  Future<NoteSideRecord> write(
    String noteId,
    NoteSideKind kind,
    Map<String, Uint8List> files, {
    NoteSideRecord? base,
  }) async {
    _requireAvailable();
    if (!files.containsKey(kind.markerFile)) {
      throw FormatException(
        'A ${kind.name} attachment needs ${kind.markerFile}',
      );
    }
    if (base != null &&
        (base.kind != kind ||
            base.heads.any((head) => head.ownerNoteId != noteId))) {
      throw StateError('Not a ${kind.name} attachment of this note');
    }
    final guards = await _noteGuards(noteId);
    final entityId = base?.entityId ?? newId();
    final parents = [
      for (final head in base?.heads ?? const <RevisionRecord>[])
        head.revisionId,
    ];
    await beforeCommit?.call();
    final record = await repository.commitPreparedIfNoteHeads(
      repository.prepareCommit(
        entityId: entityId,
        kind: EntityKind.attachment,
        ownerNoteId: noteId,
        files: files,
        parentRevisionIds: parents,
      ),
      expectedHeads: {...guards, entityId: parents},
    );
    return NoteSideRecord(
      entityId: record.entityId,
      revisionId: record.revisionId,
      heads: List.unmodifiable([record]),
      kind: kind,
    );
  }

  /// Writes a deletion mark over the heads [r] saw; throws [StateError] like [write] if they changed.
  Future<void> markDeleted(NoteSideRecord r) async {
    final noteId = r.heads.first.ownerNoteId!;
    await write(noteId, r.kind, {
      r.kind.markerFile: Uint8List.fromList(
        utf8.encode(jsonEncode({'schemaVersion': 1, 'deleted': true})),
      ),
    }, base: r);
  }

  /// The heads [write] guards: the note's single live head and every head of every folder above it. A
  /// missing or split note, a missing folder, or any deleted branch of a folder means the note is unavailable, in the
  /// trash or conflicted.
  Future<Map<String, List<String>>> _noteGuards(String noteId) async {
    StateError unavailable() =>
        StateError('The note is missing, conflicted or in the trash');
    String? parent(Object? value) => value == null || value is String
        ? value as String?
        : throw unavailable();

    final note = (await repository.heads(noteId)).singleOrNull;
    if (note == null || note.kind != EntityKind.metadata || note.deleted) {
      throw unavailable();
    }
    final guards = {
      noteId: [note.revisionId],
    };
    // A folder split by offline edits on two devices stays usable while no branch is deleted (as the library sees
    // it): every head is guarded and every branch's parent chain is walked.
    final walked = <String>{};
    Future<void> walk(String? folderId, Set<String> path) async {
      if (folderId == null || walked.contains(folderId)) return;
      final heads = await repository.heads(folderId);
      if (path.contains(folderId) ||
          path.length >= 64 ||
          heads.isEmpty ||
          heads.any((head) => head.kind != EntityKind.folder || head.deleted)) {
        throw unavailable();
      }
      guards[folderId] = [for (final head in heads) head.revisionId];
      for (final head in heads) {
        await walk(parent((await _json(head, 'folder.json'))['parentId']), {
          ...path,
          folderId,
        });
      }
      walked.add(folderId);
    }

    await walk(parent((await _json(note, 'note.json'))['folderId']), {});
    return guards;
  }

  Future<Map<dynamic, dynamic>> _json(
    RevisionRecord record,
    String file,
  ) async {
    final value = jsonDecode(
      utf8.decode(await repository.readRevisionFile(record, file)),
    );
    if (value is! Map) throw FormatException('Invalid $file');
    return value;
  }

  /// The marker JSON of [head], or null when it cannot be read or is not schema version 1.
  Future<Map<dynamic, dynamic>?> _marker(
    RevisionRecord head,
    NoteSideKind kind,
  ) async {
    try {
      final value = jsonDecode(
        utf8.decode(await repository.readRevisionFile(head, kind.markerFile)),
      );
      return value is Map && value['schemaVersion'] == 1 ? value : null;
    } on FormatException catch (error) {
      _log.warning('Skipped ${kind.name} head ${head.revisionId}: $error');
    } on FileSystemException catch (error) {
      _log.warning('Skipped ${kind.name} head ${head.revisionId}: $error');
    }
    return null;
  }

  void _requireAvailable() {
    if (!available) {
      throw StateError('Note attachments need a format 2 vault');
    }
  }
}
