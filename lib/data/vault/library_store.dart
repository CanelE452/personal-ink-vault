import 'dart:convert';
import 'dart:typed_data';

import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/native/ink_vault_native.dart';
import 'package:saber/data/vault/knowledge_rename.dart';

class VaultFolder {
  final String id;
  final String title;
  final String? parentId;
  final RevisionRecord revision;
  final bool deletionConflict;
  final bool trashed;

  const new(
    this.id,
    this.title,
    this.parentId,
    this.revision, {
    this.deletionConflict = false,
    this.trashed = false,
  });
}

class LibraryLocation {
  final bool trashed;
  final bool deletionConflict;

  const new({this.trashed = false, this.deletionConflict = false});
}

class LibraryStore {
  final NoteRepository repository;
  final KnowledgeInvoke? _knowledgeInvoke;

  new(
    this.repository, {
    InkVaultNative? native,
    KnowledgeInvoke? knowledgeInvoke,
  }) : _knowledgeInvoke = knowledgeInvoke ?? native?.invoke;

  void _requireV2() {
    if (repository.formatVersion < 2) {
      throw const FormatException('Folders require vault format 2');
    }
  }

  Future<_LibraryState> _state() async {
    final records = await repository.revisions();
    final parents = records.expand((r) => r.parentRevisionIds).toSet();
    final heads = <String, List<RevisionRecord>>{};
    for (final record in records) {
      if (!parents.contains(record.revisionId)) {
        (heads[record.entityId] ??= []).add(record);
      }
    }
    final folders = <String, List<VaultFolder>>{};
    final noteFolders = <String, String?>{};
    for (final entityHeads in heads.values) {
      for (final head in entityHeads) {
        if (head.kind != EntityKind.folder &&
            head.kind != EntityKind.metadata) {
          continue;
        }
        final files = await repository.readFiles(head);
        final name = head.kind == EntityKind.folder
            ? 'folder.json'
            : 'note.json';
        final bytes = files[name];
        if (bytes == null) throw FormatException('Missing $name');
        final json = jsonObject(jsonDecode(utf8.decode(bytes)));
        if (head.kind == EntityKind.folder) {
          if (json['title'] is! String)
            throw const FormatException('Invalid folder title');
          final parent = _optionalId(json['parentId']);
          (folders[head.entityId] ??= []).add(
            VaultFolder(head.entityId, json['title'] as String, parent, head),
          );
        } else {
          noteFolders[head.revisionId] = _optionalId(json['folderId']);
        }
      }
    }
    return _LibraryState(heads, folders, noteFolders);
  }

  Future<List<VaultFolder>> listFolders({bool includeDeleted = false}) async {
    final state = await _state();
    final result = <VaultFolder>[];
    for (final branches in state.folders.values) {
      for (final folder in branches) {
        final location = state.location(
          folder.parentId,
          state.subtreeHeads(folder.id, includeRoot: true),
        );
        final trashed = folder.revision.deleted || location.trashed;
        final conflict =
            state.deletionConflict(folder) || location.deletionConflict;
        if (trashed && !includeDeleted && !conflict) continue;
        result.add(
          VaultFolder(
            folder.id,
            folder.title,
            folder.parentId,
            folder.revision,
            trashed: trashed,
            deletionConflict: conflict,
          ),
        );
      }
    }
    result.sort(
      (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
    );
    return result;
  }

  Future<LibraryLocation> location(
    String? folderId, {
    required Iterable<RevisionRecord> documentRevisions,
  }) async => (await _state()).location(folderId, documentRevisions);

  Future<Map<String, LibraryLocation>> documentLocations() async {
    final state = await _state();
    final result = <String, LibraryLocation>{};
    final owned = <String, List<RevisionRecord>>{};
    for (final branches in state.heads.values) {
      for (final head in branches) {
        if (head.ownerNoteId case final String owner) {
          (owned[owner] ??= []).add(head);
        }
      }
    }
    for (final branches in state.heads.values) {
      for (final head in branches.where((r) => r.kind == EntityKind.metadata)) {
        result[head.revisionId] = state.location(
          state.noteFolders[head.revisionId],
          [head, ...?owned[head.entityId]],
        );
      }
    }
    return result;
  }

  Future<void> validateDestination(String? folderId) async {
    if (folderId == null) return;
    _requireV2();
    validateId(folderId);
    final folders = await listFolders(includeDeleted: true);
    final candidates = folders.where((f) => f.id == folderId).toList();
    if (candidates.isEmpty || candidates.any((f) => f.trashed)) {
      throw const FormatException('Destination folder is missing or in trash');
    }
  }

  Future<VaultFolder> createFolder(String title, {String? parentId}) async {
    _requireV2();
    final normalized = _title(title);
    await validateDestination(parentId);
    final revision = await repository.commit(
      entityId: newId(),
      kind: EntityKind.folder,
      files: {
        'folder.json': _encode({'title': normalized, 'parentId': parentId}),
      },
      parentRevisionIds: [],
    );
    return VaultFolder(revision.entityId, normalized, parentId, revision);
  }

  Future<void> renameFolder(
    VaultFolder folder,
    String title, {
    void Function()? requireWrite,
    Future<void> Function(PreparedKnowledgeChange)? onPrepared,
  }) async {
    _requireV2();
    await changeKnowledgePath(
      repository,
      folder: folder,
      changes: {'title': _title(title)},
      invoke: _knowledgeInvoke,
      requireWrite: requireWrite,
      onPrepared: onPrepared,
    );
  }

  Future<void> moveFolder(
    VaultFolder folder,
    String? parentId, {
    void Function()? requireWrite,
    Future<void> Function(PreparedKnowledgeChange)? onPrepared,
  }) async {
    _requireV2();
    await changeKnowledgePath(
      repository,
      folder: folder,
      changes: {'parentId': parentId},
      invoke: _knowledgeInvoke,
      requireWrite: requireWrite,
      onPrepared: onPrepared,
    );
  }

  Future<void> setDeleted(
    VaultFolder folder,
    bool deleted, {
    void Function()? requireWrite,
    Future<void> Function(PreparedKnowledgeChange)? onPrepared,
  }) async {
    _requireV2();
    await changeKnowledgePath(
      repository,
      folder: folder,
      deleted: deleted,
      invoke: _knowledgeInvoke,
      requireWrite: requireWrite,
      onPrepared: onPrepared,
    );
  }
}

class _LibraryState {
  final Map<String, List<RevisionRecord>> heads;
  final Map<String, List<VaultFolder>> folders;
  final Map<String, String?> noteFolders;

  new(this.heads, this.folders, this.noteFolders);

  Set<String> descendants(String folderId) {
    final result = <String>{folderId};
    var changed = true;
    while (changed) {
      changed = false;
      for (final branches in folders.values) {
        for (final folder in branches) {
          if (result.contains(folder.parentId) && result.add(folder.id)) {
            changed = true;
          }
        }
      }
    }
    return result;
  }

  List<RevisionRecord> subtreeHeads(
    String folderId, {
    bool includeRoot = false,
  }) {
    final ids = descendants(folderId);
    final notes = <String>{};
    final result = <RevisionRecord>[];
    for (final branches in heads.values) {
      for (final head in branches) {
        if (head.kind == EntityKind.folder &&
            ids.contains(head.entityId) &&
            (includeRoot || head.entityId != folderId)) {
          result.add(head);
        }
        if (head.kind == EntityKind.metadata &&
            ids.contains(noteFolders[head.revisionId])) {
          notes.add(head.entityId);
          result.add(head);
        }
      }
    }
    for (final branches in heads.values) {
      result.addAll(branches.where((r) => notes.contains(r.ownerNoteId)));
    }
    return result;
  }

  bool deletionConflict(VaultFolder folder) =>
      folder.revision.deleted &&
      ((folders[folder.id]?.length ?? 0) > 1 ||
          subtreeHeads(folder.id).any((r) => !_observed(folder.revision, r)));

  LibraryLocation location(
    String? folderId,
    Iterable<RevisionRecord> documentRevisions,
  ) {
    final outcomes = <LibraryLocation>[];
    void visit(
      String? id,
      List<RevisionRecord> required,
      Set<String> visited,
      bool trashed,
      bool conflict,
    ) {
      if (id == null) {
        outcomes.add(
          LibraryLocation(trashed: trashed, deletionConflict: conflict),
        );
        return;
      }
      final branches = folders[id];
      if (visited.contains(id) || branches == null || branches.isEmpty) {
        outcomes.add(const LibraryLocation(deletionConflict: true));
        return;
      }
      for (final folder in branches) {
        var nextTrashed = trashed;
        var nextConflict = conflict;
        if (folder.revision.deleted) {
          if (branches.length > 1 ||
              required.any((r) => !_observed(folder.revision, r))) {
            nextConflict = true;
          } else {
            nextTrashed = true;
          }
        }
        visit(
          folder.parentId,
          [...required, folder.revision],
          {...visited, id},
          nextTrashed,
          nextConflict,
        );
      }
    }

    visit(folderId, documentRevisions.toList(), {}, false, false);
    final allTrashed = outcomes.every((o) => o.trashed);
    return LibraryLocation(
      trashed: allTrashed,
      deletionConflict:
          outcomes.any((o) => o.deletionConflict) ||
          (outcomes.any((o) => o.trashed) && !allTrashed),
    );
  }
}

bool _observed(RevisionRecord deletion, RevisionRecord child) =>
    (deletion.baseRefs[child.entityId] ?? const []).contains(child.revisionId);

String? _optionalId(Object? value) {
  if (value == null) return null;
  if (value is! String) throw const FormatException('Invalid folder identity');
  validateId(value);
  return value;
}

String _title(String title) {
  if (title.trim().isEmpty) throw const FormatException('폴더 이름을 입력하세요');
  return title.trim();
}

Uint8List _encode(Map<String, dynamic> json) =>
    Uint8List.fromList(utf8.encode(jsonEncode(json)));
