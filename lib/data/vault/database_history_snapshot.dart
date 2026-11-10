import 'dart:convert';

import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/vault/database_history.dart';
import 'package:saber/data/vault/database_media_snapshot.dart';
import 'package:saber/data/vault/workspace_database.dart';
import 'package:saber/data/vault/workspace_store.dart';

/// An immutable comparison against a single saved database head.
final class DatabaseHistorySnapshot {
  new _(
    this._session,
    this._repository,
    this._noteIdentity,
    this.currentRevision,
    this.revisions,
    this._expectedHeads,
    this._currentDatabase,
  );

  final NoteSession _session;
  final NoteRepository _repository;
  final (String, String, String) _noteIdentity;
  final RevisionRecord currentRevision;
  final List<RevisionRecord> revisions;
  final Map<String, List<String>> _expectedHeads;
  final WorkspaceDatabase _currentDatabase;

  static Future<DatabaseHistorySnapshot> read(NoteSession session) async {
    final repository = session.repository;
    final identity = _identity(session.note);
    final captured = await session.captureDatabaseHistory();
    final database = await _readDatabase(repository, captured.current);
    final snapshot = DatabaseHistorySnapshot._(
      session,
      repository,
      identity,
      captured.current,
      captured.revisions,
      captured.expectedHeads,
      database,
    );
    snapshot._requireScope();
    await session.validateDatabaseRevisionRestoreHeads(
      captured.expectedHeads,
      captured.current,
    );
    snapshot._requireScope();
    return snapshot;
  }

  bool belongsTo(NoteSession session) {
    final note = session.note;
    return identical(_session, session) &&
        identical(_repository, session.repository) &&
        _noteIdentity == _identity(note) &&
        note.documentKind == VaultDocumentKind.database &&
        !note.trashed &&
        !note.deletionConflict;
  }

  Future<DatabaseHistoryDiff> compare(RevisionRecord chosen) async {
    final actual = _requireChosen(chosen);
    final historical = await _readDatabase(_repository, actual);
    _requireScope();
    if (historical.id != _currentDatabase.id) {
      throw const FormatException(
        'The selected revision has a different database identity',
      );
    }
    return DatabaseHistoryDiff.compare(
      historical,
      _currentDatabase,
      beforeFiles: actual.blobs,
      afterFiles: currentRevision.blobs,
    );
  }

  Future<void> restore(
    RevisionRecord chosen, {
    void Function(WorkspaceDatabase)? validateActions,
    void Function()? requireWrite,
  }) async {
    final actual = _requireChosen(chosen);
    await _session.restoreDatabaseRevision(
      actual,
      expectedHeads: _expectedHeads,
      observed: currentRevision,
      validateActions: validateActions,
      requireWrite: () {
        _requireScope();
        requireWrite?.call();
      },
    );
  }

  RevisionRecord _requireChosen(RevisionRecord chosen) {
    _requireScope();
    final actual = revisions
        .where((record) => record.revisionId == chosen.revisionId)
        .singleOrNull;
    if (actual == null ||
        jsonEncode(actual.toJson()) != jsonEncode(chosen.toJson())) {
      throw const FormatException(
        'The selected revision is not owned database history',
      );
    }
    return actual;
  }

  void _requireScope() {
    if (!belongsTo(_session)) {
      throw StateError('The opened database changed while reading its history');
    }
  }
}

(String, String, String) _identity(VaultNote note) =>
    (note.id, note.inkEntityId, note.markdownEntityId);

Future<WorkspaceDatabase> _readDatabase(
  NoteRepository repository,
  RevisionRecord revision,
) async {
  final file = revision.blobs['database.json'];
  if (file == null || file.length > DatabaseMediaSnapshot.maxSnapshotBytes) {
    throw const FormatException('Missing or oversized database.json');
  }
  final bytes = await repository.readRevisionFile(revision, 'database.json');
  return WorkspaceDatabase.fromJson(jsonObject(jsonDecode(utf8.decode(bytes))));
}
