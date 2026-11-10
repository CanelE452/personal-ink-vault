import 'dart:convert';
import 'dart:typed_data';

import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/native/ink_vault_native.dart';
import 'package:saber/data/vault/knowledge_catalog.dart';
import 'package:saber/data/vault/obsidian_vault_source.dart';
import 'package:saber/data/vault/workspace_store.dart';

final class ObsidianCanvasExportFile {
  new _({
    required VaultNote note,
    required this.preferredPath,
    required this.bodyRevisionId,
    required Uint8List bytes,
  }) : noteId = note.id,
       title = note.title,
       metadataRevisionId = note.revision.revisionId,
       kind = note.documentKind,
       bytes = bytes.asUnmodifiableView();

  final String noteId, title, preferredPath, bodyRevisionId, metadataRevisionId;
  final VaultDocumentKind kind;
  final Uint8List bytes;
}

final class ObsidianCanvasExportReader {
  new _(this._repository, this._native, this._catalog, this._imageIds)
    : _revisionIds = _catalog.revisions
          .map((record) => record.revisionId)
          .toSet();

  final NoteRepository _repository;
  final InkVaultNative _native;
  final KnowledgeCatalog _catalog;
  final Map<String, String?> _imageIds;
  final Set<String> _revisionIds;

  KnowledgeCatalog get catalog => _catalog;

  static Future<ObsidianCanvasExportReader> capture(
    NoteRepository repository, {
    required InkVaultNative native,
  }) async {
    final catalog = await KnowledgeCatalog.capture(repository);
    final candidates = <(String?, List<String>)>[];
    for (final entry in catalog.documents.entries) {
      final paths = entry.value['attachmentPaths'];
      if (paths is! List) continue;
      final note = catalog.notes[entry.key]?.singleOrNull;
      final source = catalog.heads[note?.sourceEntityId]?.singleOrNull;
      final available =
          entry.value['attachmentUnavailable'] != true &&
          note?.documentKind == VaultDocumentKind.image &&
          source?.blobs.length == 1;
      for (final path in paths.whereType<String>()) {
        final parts = _imagePath(path);
        if (parts != null)
          candidates.add((available ? entry.key : null, parts));
      }
    }
    final segments = candidates
        .expand((candidate) => candidate.$2)
        .toSet()
        .toList();
    final normalized = normalizeObsidianExportSegments(native, segments);
    final keys = {
      for (var i = 0; i < segments.length; i++) segments[i]: normalized[i],
    };
    final imageIds = <String, String?>{};
    for (final (id, parts) in candidates) {
      final key = parts.map((segment) => keys[segment]!).join('/');
      imageIds[key] = imageIds.containsKey(key) ? null : id;
    }
    return ObsidianCanvasExportReader._(repository, native, catalog, imageIds);
  }

  String? resolveImage(String rawVaultPath) {
    final parts = _imagePath(rawVaultPath);
    if (parts == null || _imageIds.isEmpty) return null;
    final key = normalizeObsidianExportSegments(_native, parts).join('/');
    return _imageIds[key];
  }

  Future<ObsidianCanvasExportFile?> readImage(
    String noteId, {
    required int maxBytes,
  }) async {
    if (_catalog.notes[noteId]?.singleOrNull?.documentKind !=
        VaultDocumentKind.image) {
      return null;
    }
    return read(noteId, maxBytes: maxBytes);
  }

  Future<ObsidianCanvasExportFile?> read(
    String noteId, {
    required int maxBytes,
  }) async {
    final note = _catalog.notes[noteId]?.singleOrNull;
    final metadata = _catalog.heads[noteId]?.singleOrNull;
    if (note == null ||
        metadata == null ||
        note.trashed ||
        note.deletionConflict ||
        metadata.vaultId != _repository.vaultId ||
        metadata.deleted ||
        metadata.kind != EntityKind.metadata ||
        metadata.revisionId != note.revision.revisionId) {
      return null;
    }
    final kind = note.documentKind;
    final perFileLimit =
        (kind == VaultDocumentKind.markdown || kind == VaultDocumentKind.canvas
            ? 8
            : 64) *
        1024 *
        1024;
    final limit = maxBytes < perFileLimit ? maxBytes : perFileLimit;
    final source = switch (kind) {
      VaultDocumentKind.markdown => (
        note.markdownEntityId,
        EntityKind.markdown,
      ),
      VaultDocumentKind.canvas => (note.inkEntityId, EntityKind.ink),
      VaultDocumentKind.pdf ||
      VaultDocumentKind.image ||
      VaultDocumentKind.office => (note.sourceEntityId, EntityKind.attachment),
      _ => null,
    };
    if (source == null || source.$1 == null) return null;
    final revision = _catalog.heads[source.$1]?.singleOrNull;
    if (revision == null ||
        revision.deleted ||
        revision.vaultId != _repository.vaultId ||
        revision.kind != source.$2 ||
        revision.ownerNoteId != note.id) {
      return null;
    }
    final storedName = switch (kind) {
      VaultDocumentKind.markdown => 'summary.md',
      VaultDocumentKind.canvas => 'board.canvas',
      VaultDocumentKind.office => await _officeOriginalName(revision, limit),
      _ => revision.blobs.keys.singleOrNull,
    };
    if (storedName == null) return null;
    if (source.$2 == EntityKind.attachment &&
        obsidianAttachmentKind(storedName) != kind.name) {
      return null;
    }
    final ref = revision.blobs[storedName];
    if (ref == null ||
        ref.length > limit ||
        (ref.length == 0 && kind != VaultDocumentKind.markdown)) {
      return null;
    }
    final alias = note.obsidianAttachmentName;
    final leafTitle = note.title.replaceAll(RegExp(r'[/\\]'), '_');
    final filename = switch (kind) {
      VaultDocumentKind.markdown => '$leafTitle.md',
      VaultDocumentKind.canvas
          when alias != null && obsidianAttachmentKind(alias) == 'canvas' =>
        alias,
      VaultDocumentKind.canvas
          when leafTitle.toLowerCase().endsWith('.canvas') =>
        leafTitle,
      VaultDocumentKind.canvas => '$leafTitle.canvas',
      _ => storedName,
    };
    final bytes = await _repository.readRevisionFile(revision, storedName);
    return ObsidianCanvasExportFile._(
      note: note,
      preferredPath: _preferredPath(noteId, filename),
      bodyRevisionId: revision.revisionId,
      bytes: bytes,
    );
  }

  Future<ObsidianCanvasExportFile?> readSummary(
    VaultNote note, {
    required int maxBytes,
  }) async {
    if (!identical(_catalog.notes[note.id]?.singleOrNull, note) ||
        note.trashed ||
        note.deletionConflict) {
      return null;
    }
    final revision = _catalog.heads[note.markdownEntityId]?.singleOrNull;
    final ref = revision?.blobs['summary.md'];
    if (revision == null ||
        revision.vaultId != _repository.vaultId ||
        revision.deleted ||
        revision.kind != EntityKind.markdown ||
        revision.ownerNoteId != note.id ||
        ref == null ||
        ref.length > maxBytes ||
        ref.length > 8 * 1024 * 1024) {
      return null;
    }
    return ObsidianCanvasExportFile._(
      note: note,
      preferredPath: _preferredPath(note.id, '${note.title}.md'),
      bodyRevisionId: revision.revisionId,
      bytes: await _repository.readRevisionFile(revision, 'summary.md'),
    );
  }

  Future<void> ensureCurrent({String action = 'Canvas 내보내기'}) async {
    final revisions = await _repository.revisions();
    if (revisions.length != _revisionIds.length ||
        revisions.any((record) => !_revisionIds.contains(record.revisionId))) {
      throw StateError('보관함이 변경되었습니다. $action 작업을 다시 실행하세요.');
    }
  }

  String _preferredPath(String noteId, String filename) {
    final document = _catalog.documents[noteId];
    final paths = document?['attachmentPaths'] ?? document?['paths'];
    final path = paths is List ? paths.singleOrNull : null;
    if (path is! String) return filename;
    final slash = path.lastIndexOf('/');
    if (slash < 0) return filename;
    final folders = path.substring(0, slash).split('/');
    return folders.every(_visibleSegment)
        ? [...folders, filename].join('/')
        : filename;
  }

  Future<String?> _officeOriginalName(
    RevisionRecord revision,
    int maxBytes,
  ) async {
    final blobs = revision.blobs;
    final descriptor = blobs['edition.json'];
    if (descriptor == null) return blobs.keys.singleOrNull;
    final preview = blobs['preview.pdf'];
    if (blobs.length != 3 ||
        descriptor.length > 64 * 1024 ||
        preview == null ||
        preview.length == 0) {
      return null;
    }
    final name = blobs.keys.singleWhere(
      (name) => name != 'edition.json' && name != 'preview.pdf',
    );
    final original = blobs[name]!;
    if (obsidianAttachmentKind(name) != 'office' ||
        original.length == 0 ||
        original.length > maxBytes) {
      return null;
    }
    // The edition manifest binds the original and preview by hash. Only the
    // original is exported, so the preview bytes need not be loaded.
    final bytes = await _repository.readRevisionFile(revision, 'edition.json');
    try {
      final edition = jsonObject(jsonDecode(utf8.decode(bytes)));
      final binding = edition['bindingId'];
      final engine = edition['engineVersion'];
      final pages = edition['pageCount'];
      if (edition['schemaVersion'] != 1 ||
          edition['sourceEntityId'] != revision.entityId ||
          edition['originalFileName'] != name ||
          edition['originalSha256'] != original.hash ||
          edition['pdfSha256'] != preview.hash ||
          binding is! String ||
          engine is! String ||
          engine.trim().isEmpty ||
          pages is! int ||
          pages < 1) {
        return null;
      }
      validateId(binding);
      return name;
    } on FormatException {
      return null;
    }
  }
}

List<String>? _imagePath(String value) {
  if (value.length > 4096) return null;
  final parts = value.split('/');
  if (parts.length > 65 ||
      !parts.every(_visibleSegment) ||
      obsidianAttachmentKind(parts.last) != 'image') {
    return null;
  }
  return parts;
}

bool _visibleSegment(String value) =>
    !value.startsWith('.') && isObsidianPathSegment(value);

List<String> normalizeObsidianExportSegments(
  InkVaultNative native,
  List<String> segments,
) {
  const batchSize = 10000;
  final result = <String>[];
  for (var start = 0; start < segments.length; start += batchSize) {
    final batch = segments.skip(start).take(batchSize).toList();
    final normalized = native.invoke({
      'op': 'normalize_workspace_segments',
      'segments': batch,
    })['segments'];
    if (normalized is! List ||
        normalized.length != batch.length ||
        normalized.any(
          (value) => value is! String || value.isEmpty || value.contains('/'),
        )) {
      throw const FormatException('Invalid Canvas export path normalization');
    }
    result.addAll(normalized.cast<String>());
  }
  return result;
}
