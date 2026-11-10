import 'dart:convert';

import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/vault/block_page_document.dart';
import 'package:saber/data/vault/workspace_store.dart';

enum BlockPageChangeKind {
  added,
  deleted,
  moved,
  content,
  type,
  checked,
  collapsed,
  link,
  formatting,
  unknown,
}

class BlockPageBlockChange {
  new _(
    this.blockId,
    _BlockPosition? before,
    _BlockPosition? after,
    Set<BlockPageChangeKind> kinds,
  ) : before = before?.block,
      after = after?.block,
      beforeParentId = before?.parentId,
      afterParentId = after?.parentId,
      beforeIndex = before?.index,
      afterIndex = after?.index,
      kinds = Set.unmodifiable(kinds);

  final String blockId;
  final BlockPageBlock? before;
  final BlockPageBlock? after;
  final String? beforeParentId;
  final String? afterParentId;
  final int? beforeIndex;
  final int? afterIndex;
  final Set<BlockPageChangeKind> kinds;
}

class BlockPageHistoryDiff {
  new _(List<BlockPageBlockChange> changes, this.pageMetadataChanged)
    : changes = List.unmodifiable(changes);

  final List<BlockPageBlockChange> changes;
  final bool pageMetadataChanged;

  factory compare(BlockPageDocument before, BlockPageDocument after) {
    final oldBlocks = _positions(before);
    final newBlocks = _positions(after);
    final reordered = _reordered(oldBlocks, newBlocks);
    final changes = <BlockPageBlockChange>[];
    for (final id in {...newBlocks.keys, ...oldBlocks.keys}) {
      final oldPosition = oldBlocks[id], newPosition = newBlocks[id];
      final kinds = <BlockPageChangeKind>{};
      if (oldPosition == null) {
        kinds.add(BlockPageChangeKind.added);
      } else if (newPosition == null) {
        kinds.add(BlockPageChangeKind.deleted);
      } else {
        final oldBlock = oldPosition.block, newBlock = newPosition.block;
        if (oldPosition.parentId != newPosition.parentId ||
            reordered.contains(id))
          kinds.add(BlockPageChangeKind.moved);
        if (oldBlock.text != newBlock.text)
          kinds.add(BlockPageChangeKind.content);
        if (oldBlock.type != newBlock.type) kinds.add(BlockPageChangeKind.type);
        if (oldBlock.checked != newBlock.checked)
          kinds.add(BlockPageChangeKind.checked);
        if (oldBlock.collapsed != newBlock.collapsed)
          kinds.add(BlockPageChangeKind.collapsed);
        if (oldBlock.noteId != newBlock.noteId)
          kinds.add(BlockPageChangeKind.link);
        if (!_jsonEqual(
          oldBlock.inlineText?.toJson(),
          newBlock.inlineText?.toJson(),
        ))
          kinds.add(BlockPageChangeKind.formatting);
        final oldExtra = _blockExtra(oldBlock);
        final newExtra = _blockExtra(newBlock);
        if (!_jsonEqual(oldExtra, newExtra))
          kinds.add(BlockPageChangeKind.unknown);
      }
      if (kinds.isNotEmpty)
        changes.add(
          BlockPageBlockChange._(id, oldPosition, newPosition, kinds),
        );
    }
    final oldExtra = before.toJson()..remove('blocks');
    final newExtra = after.toJson()..remove('blocks');
    return BlockPageHistoryDiff._(changes, !_jsonEqual(oldExtra, newExtra));
  }
}

/// A read-only comparison against the actual saved head at capture time.
/// Revision records have graph identities and devices, but no saved timestamps.
class BlockPageHistorySnapshot {
  new _(
    this._session,
    this._repository,
    this._scope,
    this._noteScope,
    this.currentRevision,
    this.currentDocument,
    List<RevisionRecord> revisions,
    Map<String, List<String>> expectedHeads,
  ) : revisions = List.unmodifiable(revisions),
      expectedHeadRevisionIds = List.unmodifiable([currentRevision.revisionId]),
      expectedHeads = Map.unmodifiable({
        for (final entry in expectedHeads.entries)
          entry.key: List<String>.unmodifiable(entry.value),
      });

  final NoteSession _session;
  final NoteRepository _repository;
  final (String, String, String, int) _scope;
  final (String, String, String) _noteScope;
  final RevisionRecord currentRevision;
  final BlockPageDocument currentDocument;
  final List<RevisionRecord> revisions;
  final List<String> expectedHeadRevisionIds;
  final Map<String, List<String>> expectedHeads;

  static Future<BlockPageHistorySnapshot> read(NoteSession session) async {
    final repository = session.repository;
    final note = session.note;
    if (note.documentKind != VaultDocumentKind.page ||
        note.trashed ||
        note.deletionConflict)
      throw StateError('Open a live block page before reading its history');
    final scope = _repositoryScope(repository);
    final noteScope = (note.id, note.inkEntityId, note.markdownEntityId);
    final records = await repository.revisions();
    final entity = records
        .where((r) => r.entityId == note.inkEntityId)
        .toList();
    final parents = entity.expand((r) => r.parentRevisionIds).toSet();
    final heads = entity.where((r) => !parents.contains(r.revisionId)).toList();
    if (heads.length != 1)
      throw StateError('Save or resolve the page before reading its history');
    final current = heads.single;
    final owned = entity
        .where(
          (r) =>
              r.vaultId == repository.vaultId &&
              r.kind == EntityKind.ink &&
              r.ownerNoteId == note.id,
        )
        .toList();
    if (current.deleted || !owned.contains(current))
      throw const FormatException(
        'The current page revision is not live or owned',
      );
    final guards = await session.captureInkRevisionRestoreHeads(current);
    final document = await _readPage(repository, current);
    await session.validateInkRevisionRestoreHeads(guards);
    final snapshot = BlockPageHistorySnapshot._(
      session,
      repository,
      scope,
      noteScope,
      current,
      document,
      _graphOrder(owned),
      guards,
    );
    snapshot._requireScope();
    return snapshot;
  }

  Future<BlockPageDocument> readRevision(RevisionRecord chosen) async {
    _requireScope();
    final matches = revisions.where((r) => r.revisionId == chosen.revisionId);
    if (matches.length != 1 ||
        chosen.deleted ||
        !_jsonEqual(matches.single.toJson(), chosen.toJson()))
      throw const FormatException(
        'The selected revision is not owned page history',
      );
    final document = await _readPage(_session.repository, matches.single);
    _requireScope();
    return document;
  }

  Future<BlockPageHistoryDiff> compare(RevisionRecord chosen) async =>
      BlockPageHistoryDiff.compare(await readRevision(chosen), currentDocument);

  bool belongsTo(NoteSession session) {
    final note = session.note;
    return identical(session, _session) &&
        identical(session.repository, _repository) &&
        _repositoryScope(session.repository) == _scope &&
        (note.id, note.inkEntityId, note.markdownEntityId) == _noteScope &&
        note.documentKind == VaultDocumentKind.page &&
        !note.trashed &&
        !note.deletionConflict;
  }

  void _requireScope() {
    if (!belongsTo(_session))
      throw StateError('The opened page changed while reading history');
  }
}

(String, String, String, int) _repositoryScope(NoteRepository repository) => (
  repository.root.absolute.uri.normalizePath().toString(),
  repository.vaultId,
  repository.deviceId,
  repository.formatVersion,
);

Future<BlockPageDocument> _readPage(
  NoteRepository repository,
  RevisionRecord revision,
) async {
  final bytes = await repository.readRevisionFile(revision, 'page.json');
  return BlockPageDocument.fromJson(jsonObject(jsonDecode(utf8.decode(bytes))));
}

List<RevisionRecord> _graphOrder(List<RevisionRecord> records) {
  final byId = {for (final record in records) record.revisionId: record};
  final children = {for (final record in records) record.revisionId: 0};
  for (final record in records) {
    for (final parent in record.parentRevisionIds) {
      if (children.containsKey(parent))
        children[parent] = children[parent]! + 1;
    }
  }
  final ready = children.keys.where((id) => children[id] == 0).toList()..sort();
  final ordered = <RevisionRecord>[];
  while (ready.isNotEmpty) {
    final record = byId[ready.removeAt(0)]!;
    ordered.add(record);
    for (final parent in record.parentRevisionIds) {
      if (!children.containsKey(parent)) continue;
      children[parent] = children[parent]! - 1;
      if (children[parent] == 0) ready.add(parent);
    }
    ready.sort();
  }
  if (ordered.length != records.length)
    throw const FormatException('Invalid saved revision graph');
  return ordered;
}

class _BlockPosition {
  new(this.block, this.parentId, this.index);
  final BlockPageBlock block;
  final String? parentId;
  final int index;
}

Map<String, _BlockPosition> _positions(BlockPageDocument document) {
  final result = <String, _BlockPosition>{};
  void visit(List<BlockPageBlock> blocks, String? parentId) {
    for (var index = 0; index < blocks.length; index++) {
      final block = blocks[index];
      result[block.id] = _BlockPosition(block, parentId, index);
      visit(block.children, block.id);
    }
  }

  visit(document.blocks, null);
  return result;
}

Set<String> _reordered(
  Map<String, _BlockPosition> before,
  Map<String, _BlockPosition> after,
) {
  final groups = <String?, List<String>>{};
  for (final entry in after.entries) {
    final previous = before[entry.key];
    if (previous != null && previous.parentId == entry.value.parentId)
      (groups[entry.value.parentId] ??= []).add(entry.key);
  }
  final moved = <String>{};
  for (final ids in groups.values) {
    // The longest increasing sequence retains sibling order. Insertions,
    // deletions and moved parents do not falsely move every following block.
    final tails = <int>[];
    final predecessors = List.filled(ids.length, -1);
    for (var index = 0; index < ids.length; index++) {
      final rank = before[ids[index]]!.index;
      var low = 0, high = tails.length;
      while (low < high) {
        final middle = (low + high) ~/ 2;
        if (before[ids[tails[middle]]]!.index < rank) {
          low = middle + 1;
        } else {
          high = middle;
        }
      }
      if (low > 0) predecessors[index] = tails[low - 1];
      if (low == tails.length) {
        tails.add(index);
      } else {
        tails[low] = index;
      }
    }
    final retained = <String>{};
    var index = tails.isEmpty ? -1 : tails.last;
    while (index >= 0) {
      retained.add(ids[index]);
      index = predecessors[index];
    }
    moved.addAll(ids.where((id) => !retained.contains(id)));
  }
  return moved;
}

Map<String, dynamic> _blockExtra(BlockPageBlock block) => block.toJson()
  ..removeWhere(
    (key, _) =>
        const {
          'id',
          'type',
          'text',
          'checked',
          'collapsed',
          'noteId',
          'children',
        }.contains(key) ||
        key == 'inlineData' && block.inlineText != null,
  );

bool _jsonEqual(Object? left, Object? right) {
  if (left is Map && right is Map) {
    return left.length == right.length &&
        left.keys.every(
          (key) => right.containsKey(key) && _jsonEqual(left[key], right[key]),
        );
  }
  if (left is List && right is List) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (!_jsonEqual(left[index], right[index])) return false;
    }
    return true;
  }
  return left == right;
}
