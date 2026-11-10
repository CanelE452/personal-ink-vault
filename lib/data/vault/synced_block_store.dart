import 'dart:convert';
import 'dart:typed_data';

import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/vault/block_page_document.dart';
import 'package:saber/data/vault/block_page_media.dart';
import 'package:saber/data/vault/block_page_media_worker.dart';
import 'package:saber/data/vault/block_page_snapshot.dart';
import 'package:saber/data/vault/block_page_synced_reference.dart';
import 'package:saber/data/vault/workspace_store.dart';

final class SyncedBlockTarget {
  new _(
    this.reference,
    this.sourceTitle,
    this.block,
    this.revisionId,
    this._repository,
    Map<String, String> heads,
  ) : _heads = Map.unmodifiable(heads);

  final BlockSyncedReference reference;
  final String sourceTitle;
  final BlockPageBlock block;
  final String revisionId;
  final NoteRepository _repository;
  final Map<String, String> _heads;
}

final class SyncedBlockStore {
  const new(this.repository);

  final NoteRepository repository;

  Future<List<SyncedBlockTarget>> listSources(String noteId) async {
    final page = await _readPage(noteId);
    await _requireHeads(page.heads);
    return [
      for (final block in _walk(page.document.blocks))
        if (_supportsText(block)) _target(page, block),
    ];
  }

  Future<SyncedBlockTarget> open(BlockSyncedReference reference) async {
    final page = await _readPage(reference.sourceNoteId);
    final block = _find(page.document, reference.sourceBlockId);
    if (block == null || !_supportsText(block)) {
      throw StateError('원본 블록을 찾을 수 없거나 편집할 수 없는 형식입니다.');
    }
    await _requireHeads(page.heads);
    return _target(page, block);
  }

  Future<void> saveText(
    SyncedBlockTarget target, {
    required NoteSession owner,
    required String ownerBlockId,
    required String text,
    required void Function() requireWrite,
  }) async {
    final (
      :source,
      :original,
      :heads,
      :requireOwner,
      :expectedHeads,
      host: _,
      occurrence: _,
    ) = await _bind(
      target,
      owner,
      ownerBlockId,
      requireWrite,
    );
    if (text == original.text) {
      await _requireHeads(heads);
      requireOwner();
      return;
    }
    final next = source.document.copyWith(
      blocks: _replace(source.document.blocks, original.copyWith(text: text)),
    );
    final files = await repository.readFiles(source.ink);
    final snapshot = await prepareBlockPageMediaInWorker(
      next,
      existingFiles: files,
      addedFiles: const {},
    );
    requireOwner();
    final prepared = repository.prepareCommit(
      entityId: source.ink.entityId,
      kind: EntityKind.ink,
      ownerNoteId: source.id,
      files: snapshot.files,
      parentRevisionIds: [source.ink.revisionId],
    );
    await repository.commitPreparedIfHeads(
      prepared,
      expectedHeads: expectedHeads,
      beforePublish: requireOwner,
    );
  }

  Future<BlockPageDocument> detach(
    SyncedBlockTarget target, {
    required NoteSession owner,
    required String ownerBlockId,
    required void Function() requireWrite,
  }) async {
    final (
      :host,
      :source,
      :occurrence,
      :original,
      :requireOwner,
      :expectedHeads,
      heads: _,
    ) = await _bind(
      target,
      owner,
      ownerBlockId,
      requireWrite,
    );
    if (!occurrence.toJson().keys.every(
      const {'id', 'type', 'text', 'noteId', 'syncedBlockData'}.contains,
    )) {
      throw StateError('이 연결에 해석할 수 없는 속성이 있어 연결을 해제할 수 없습니다.');
    }
    final copied = _copyDetachedSubtree(
      original,
      occurrence.id,
      source,
      host.id,
    );
    final next = host.document.copyWith(
      blocks: _replace(host.document.blocks, copied.blocks.single),
      media: {...host.document.media, ...copied.media},
      minimumVersion: copied.version,
    );
    final needed = <String, BlockPageMedia>{};
    for (final media in copied.media.values) {
      final originalFile = source.ink.blobs[media.path];
      if (originalFile?.hash != media.sha256 ||
          originalFile?.length != media.byteLength) {
        throw const FormatException('원본 블록에 연결된 첨부 파일이 일치하지 않습니다.');
      }
      final hostFile = host.ink.blobs[media.path];
      if (hostFile == null) {
        needed[media.path] = media;
      } else if (hostFile.hash != media.sha256 ||
          hostFile.length != media.byteLength) {
        throw const FormatException('페이지에 같은 경로의 다른 첨부 파일이 있습니다.');
      }
    }
    final size =
        host.ink.blobs.values.fold(0, (sum, file) => sum + file.length) +
        needed.values.fold(0, (sum, media) => sum + media.byteLength);
    if (size > BlockPageMediaSnapshot.maxSnapshotBytes) {
      throw const FormatException('복사할 페이지와 첨부 파일이 128MiB를 넘습니다.');
    }
    requireOwner();
    final existing = await repository.readFiles(host.ink);
    final added = <String, Uint8List>{};
    for (final media in needed.values) {
      requireOwner();
      added[media.path] = await repository.readRevisionFile(
        source.ink,
        media.path,
      );
    }
    final snapshot = await prepareBlockPageMediaInWorker(
      next,
      existingFiles: existing,
      addedFiles: added,
    );
    requireOwner();
    await owner.saveDetachedPage(
      snapshot.files,
      expectedHeads: expectedHeads,
      requireWrite: requireOwner,
    );
    return snapshot.document;
  }

  Future<_BoundSyncedBlock> _bind(
    SyncedBlockTarget target,
    NoteSession owner,
    String ownerBlockId,
    void Function() requireWrite,
  ) async {
    validateId(ownerBlockId);
    final reference = target.reference;
    if (!identical(target._repository, repository) ||
        !identical(owner.repository, repository) ||
        owner.note.documentKind != VaultDocumentKind.page ||
        owner.note.id == reference.sourceNoteId ||
        owner.inkParents.length != 1) {
      throw StateError('이 페이지에서 동기화 블록을 저장할 수 없습니다.');
    }
    final ownerBodyId = owner.inkParents.single;
    final ownerNoteId = owner.note.id;
    final ownerInkId = owner.note.inkEntityId;
    final ownerMetadataId = owner.note.revision.revisionId;
    void requireOwner() {
      requireWrite();
      if (!identical(owner.repository, repository) ||
          owner.note.id != ownerNoteId ||
          owner.note.inkEntityId != ownerInkId ||
          owner.note.revision.revisionId != ownerMetadataId ||
          owner.inkParents.singleOrNull != ownerBodyId) {
        throw StateError('연결된 페이지가 바뀌었습니다.');
      }
    }

    requireOwner();
    final host = await _readPage(ownerNoteId);
    final occurrence = _find(host.document, ownerBlockId);
    final hostReference = occurrence?.syncedBlock;
    if (host.ink.revisionId != ownerBodyId ||
        host.ink.entityId != ownerInkId ||
        host.heads[ownerNoteId] != ownerMetadataId ||
        hostReference == null ||
        hostReference.sourceNoteId != reference.sourceNoteId ||
        hostReference.sourceBlockId != reference.sourceBlockId) {
      throw StateError('페이지에 저장된 동기화 블록이 바뀌었습니다.');
    }
    final source = await _readPage(reference.sourceNoteId);
    if (source.ink.revisionId != target.revisionId ||
        source.heads.length != target._heads.length ||
        source.heads.entries.any(
          (head) => target._heads[head.key] != head.value,
        )) {
      throw StateError('원본 페이지가 바뀌었습니다. 다시 열어 최신 내용을 확인하세요.');
    }
    final original = _find(source.document, reference.sourceBlockId);
    if (original == null || !_supportsText(original)) {
      throw StateError('원본 블록이 사라졌거나 편집할 수 없는 형식입니다.');
    }
    final guards = {...host.heads};
    for (final entry in source.heads.entries) {
      if (guards.containsKey(entry.key) && guards[entry.key] != entry.value) {
        throw StateError('페이지 폴더의 판본이 바뀌었습니다.');
      }
      guards[entry.key] = entry.value;
    }
    requireOwner();
    return (
      host: host,
      source: source,
      occurrence: occurrence!,
      original: original,
      heads: guards,
      expectedHeads: {
        for (final head in guards.entries) head.key: [head.value],
      },
      requireOwner: requireOwner,
    );
  }

  SyncedBlockTarget _target(_StoredPage page, BlockPageBlock block) =>
      SyncedBlockTarget._(
        BlockSyncedReference.create(
          sourceNoteId: page.id,
          sourceBlockId: block.id,
        ),
        page.title,
        block,
        page.ink.revisionId,
        repository,
        page.heads,
      );

  Future<_StoredPage> _readPage(String noteId) async {
    final metadata = await _head(noteId, EntityKind.metadata);
    final values = await _json(metadata, 'note.json');
    final inkId = values['inkEntityId'];
    final title = values['title'];
    var folderId = values['folderId'];
    if (values['documentKind'] != VaultDocumentKind.page.name ||
        inkId is! String ||
        title is! String) {
      throw StateError('동기화 블록의 원본은 저장된 일반 페이지여야 합니다.');
    }
    final guards = {noteId: metadata.revisionId};
    while (folderId != null) {
      if (folderId is! String ||
          guards.containsKey(folderId) ||
          guards.length > 64) {
        throw const FormatException('Invalid synced block folder hierarchy');
      }
      final folder = await _head(folderId, EntityKind.folder);
      guards[folderId] = folder.revisionId;
      folderId = (await _json(folder, 'folder.json'))['parentId'];
    }
    final ink = await _head(inkId, EntityKind.ink);
    if (ink.ownerNoteId != noteId || guards.containsKey(inkId)) {
      throw const FormatException('Invalid synced block page ownership');
    }
    guards[inkId] = ink.revisionId;
    final document = BlockPageDocument.fromJson(await _json(ink, 'page.json'));
    return (
      id: noteId,
      title: title,
      ink: ink,
      heads: guards,
      document: document,
    );
  }

  Future<RevisionRecord> _head(String id, EntityKind kind) async {
    validateId(id);
    final head = (await repository.heads(id)).singleOrNull;
    if (head == null ||
        head.deleted ||
        head.kind != kind ||
        head.entityId != id ||
        head.vaultId != repository.vaultId) {
      throw StateError('페이지나 폴더가 없거나 삭제·충돌 상태입니다.');
    }
    return head;
  }

  Future<Map<String, dynamic>> _json(RevisionRecord record, String path) async {
    final bytes = await repository.readRevisionFile(record, path);
    return jsonObject(jsonDecode(utf8.decode(bytes)));
  }

  Future<void> _requireHeads(Map<String, String> guards) async {
    for (final entry in guards.entries) {
      final current = (await repository.heads(entry.key)).singleOrNull;
      if (current == null ||
          current.deleted ||
          current.revisionId != entry.value) {
        throw StateError('동기화 블록을 읽는 동안 페이지가 바뀌었습니다.');
      }
    }
  }
}

typedef _StoredPage = ({
  String id,
  String title,
  RevisionRecord ink,
  Map<String, String> heads,
  BlockPageDocument document,
});

typedef _BoundSyncedBlock = ({
  _StoredPage host,
  _StoredPage source,
  BlockPageBlock occurrence,
  BlockPageBlock original,
  Map<String, String> heads,
  Map<String, List<String>> expectedHeads,
  void Function() requireOwner,
});

final _blockIdInText = RegExp(
  r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}',
  caseSensitive: false,
);

BlockPageDocument _copyDetachedSubtree(
  BlockPageBlock original,
  String occurrenceId,
  _StoredPage source,
  String hostId,
) {
  final blocks = {
    for (final block in _walk([original])) block.id: block,
  };
  final ids = {
    for (final id in blocks.keys)
      id: id == original.id ? occurrenceId : newId(),
  };
  final media = <String, BlockPageMedia>{};
  var hasInline = false;

  bool referencesCopiedBlock(Object? value) => switch (value) {
    final String text =>
      _blockIdInText
          .allMatches(text)
          .any((match) => ids.containsKey(match.group(0)!.toLowerCase())),
    final List list => list.any(referencesCopiedBlock),
    final Map map => map.entries.any(
      (entry) =>
          referencesCopiedBlock(entry.key) ||
          referencesCopiedBlock(entry.value),
    ),
    _ => false,
  };

  void rewrite(Map<String, dynamic> raw, {bool inColumns = false}) {
    final id = raw['id'] as String;
    final block = blocks[id]!;
    final supported =
        _supportsText(block) ||
        switch (block.type) {
          'divider' || 'documentLink' => true,
          'table' => block.table != null,
          'image' || 'attachment' => source.document.media.containsKey(id),
          'columnList' => block.isColumnLayout,
          'column' => inColumns,
          'linkedDatabase' => block.linkedDatabase != null,
          'syncedBlock' =>
            block.syncedBlock != null &&
                block.syncedBlock!.sourceNoteId != hostId &&
                block.syncedBlock!.sourceNoteId != source.id,
          _ => false,
        };
    final handled = {
      'id',
      'children',
      'text',
      'noteId',
      if (block.inlineText != null) 'inlineData',
      if (block.syncedBlock != null) 'syncedBlockData',
    };
    final ambiguous = raw.entries.any(
      (entry) =>
          !handled.contains(entry.key) &&
          (referencesCopiedBlock(entry.key) ||
              referencesCopiedBlock(entry.value)),
    );
    if (!supported ||
        ambiguous ||
        raw['inlineData'] != null && block.inlineText == null) {
      throw StateError('이 원본에 안전하게 복사할 수 없는 블록 또는 참조가 있습니다.');
    }
    final copyId = ids[id]!;
    raw['id'] = copyId;
    if (source.document.media[id] case final item?) media[copyId] = item;
    hasInline = hasInline || block.inlineText != null;
    for (final child in raw['children'] as List? ?? const []) {
      rewrite(jsonObject(child), inColumns: block.type == 'columnList');
    }
  }

  final root = original.toJson();
  rewrite(root);
  return BlockPageDocument.fromJson({
    'version': hasInline
        ? 3
        : media.isNotEmpty
        ? 2
        : 1,
    'blocks': [root],
    if (media.isNotEmpty)
      'blockMedia': {
        for (final entry in media.entries) entry.key: entry.value.toJson(),
      },
  });
}

bool _supportsText(BlockPageBlock block) => const {
  'paragraph',
  'heading1',
  'heading2',
  'heading3',
  'todo',
  'bullet',
  'numbered',
  'quote',
  'callout',
  'toggle',
  'code',
  'equation',
}.contains(block.type);

Iterable<BlockPageBlock> _walk(List<BlockPageBlock> blocks) sync* {
  for (final block in blocks) {
    yield block;
    yield* _walk(block.children);
  }
}

BlockPageBlock? _find(BlockPageDocument document, String id) =>
    _walk(document.blocks).where((block) => block.id == id).singleOrNull;

List<BlockPageBlock> _replace(
  List<BlockPageBlock> blocks,
  BlockPageBlock replacement,
) => [
  for (final block in blocks)
    if (block.id == replacement.id)
      replacement
    else if (block.children.isEmpty)
      block
    else
      block.copyWith(children: _replace(block.children, replacement)),
];
