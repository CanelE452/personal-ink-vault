import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/vault/database_media_snapshot.dart';
import 'package:saber/data/vault/workspace_database.dart';
import 'package:saber/data/vault/workspace_store.dart';

final class LinkedDatabaseSession {
  factory create({
    required NoteSession owner,
    required NoteSession target,
    required WorkspaceDatabase database,
    required int editorGeneration,
    required Map<String, List<String>> metadataHeads,
  }) => LinkedDatabaseSession._(
    owner,
    target,
    database,
    editorGeneration,
    metadataHeads,
  );

  new _(
    this.owner,
    this.target,
    this._database,
    this.editorGeneration,
    Map<String, List<String>> metadataHeads,
  ) : repository = target.repository,
      source = target.note,
      ownerNoteId = owner.note.id,
      ownerInkEntityId = owner.note.inkEntityId,
      metadataHeads = Map.unmodifiable({
        for (final entry in metadataHeads.entries)
          entry.key: List<String>.unmodifiable(entry.value),
      });

  final NoteSession owner;
  final NoteSession target;
  final NoteRepository repository;
  final VaultNote source;
  final String ownerNoteId;
  final String ownerInkEntityId;
  final int editorGeneration;
  final Map<String, List<String>> metadataHeads;
  WorkspaceDatabase _database;
  DatabaseMediaSnapshot? _pendingSnapshot;
  Map<String, List<String>>? _pendingHeads;
  var _closed = false;

  WorkspaceDatabase get database => _database;
  String get revisionId => target.inkParents.single;
  bool get isClosed => _closed;
  DatabaseMediaSnapshot? get pendingSnapshot => _pendingSnapshot;
  Map<String, List<String>>? get pendingHeads => _pendingHeads;

  void stageSave(
    DatabaseMediaSnapshot snapshot,
    Map<String, List<String>> heads,
  ) {
    if (_closed) throw StateError('이 연결된 데이터베이스는 이미 닫혔습니다.');
    _pendingSnapshot = snapshot;
    _pendingHeads = Map.unmodifiable({
      for (final entry in heads.entries)
        entry.key: List<String>.unmodifiable(entry.value),
    });
  }

  void saved(WorkspaceDatabase database) {
    if (_closed) throw StateError('이 연결된 데이터베이스는 이미 닫혔습니다.');
    _database = database;
    _pendingSnapshot = null;
    _pendingHeads = null;
  }

  void close() {
    _closed = true;
    _pendingSnapshot = null;
    _pendingHeads = null;
  }
}
