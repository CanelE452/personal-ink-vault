import 'dart:convert';
import 'dart:typed_data';

import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/vault/block_page_document.dart';
import 'package:saber/data/vault/block_page_media.dart';
import 'package:saber/data/vault/workspace_database.dart';

final class DatabaseMediaSnapshot {
  new _(this.database, this._files);

  factory fromFiles(Map<String, Uint8List> files) {
    _validateFiles(files);
    final database = _readDatabase(files);
    _validateMedia([
      ..._rowPages(database).values,
      ..._templatePages(database),
    ], files);
    return DatabaseMediaSnapshot._(database, _copyFiles(files));
  }

  factory prepare(
    WorkspaceDatabase database, {
    Map<String, Uint8List> existingFiles = const {},
    Map<String, Uint8List> addedFiles = const {},
  }) {
    _validateFiles(existingFiles);
    final pages = _rowPages(database);
    final mediaPages = [...pages.values, ..._templatePages(database)];
    if (existingFiles.isNotEmpty) {
      final previous = _readDatabase(existingFiles);
      if (previous.id != database.id) {
        throw const FormatException('The database identity cannot be changed');
      }
      for (final row in previous.rows) {
        final next = pages[row.id];
        if (next == null) continue;
        final old = BlockPageDocument.fromJson(row.body);
        if (old.version > next.version) {
          throw const FormatException(
            'A row page cannot be downgraded by an ordinary save',
          );
        }
        if (old.version == 1 &&
            next.version >= 2 &&
            old.toJson().containsKey('blockMedia')) {
          throw const FormatException(
            'The old row has opaque data in the reserved media registry',
          );
        }
      }
    }
    final allowed = {
      for (final page in mediaPages)
        for (final media in page.media.values) media.path,
    };
    final combined = <String, Uint8List>{...existingFiles};
    for (final entry in addedFiles.entries) {
      if (!allowed.contains(entry.key)) {
        throw const FormatException(
          'Added media must be referenced by a database row or template',
        );
      }
      final existing = combined[entry.key];
      if (existing != null && !_sameBytes(existing, entry.value)) {
        throw const FormatException(
          'Existing database media cannot be replaced with different bytes',
        );
      }
      combined[entry.key] = entry.value;
    }
    combined['database.json'] = Uint8List.fromList(
      utf8.encode(jsonEncode(database.toJson())),
    );
    _validateFiles(combined);
    _validateMedia(mediaPages, combined);
    return DatabaseMediaSnapshot._(database, _copyFiles(combined));
  }

  static const maxSnapshotBytes = 128 * 1024 * 1024;
  final WorkspaceDatabase database;
  final Map<String, Uint8List> _files;

  Map<String, Uint8List> get files => _copyFiles(_files);

  Uint8List mediaBytes(String rowId, String blockId) {
    validateId(rowId);
    validateId(blockId);
    final row = database.rows.where((row) => row.id == rowId).singleOrNull;
    if (row == null) {
      throw const FormatException('This database snapshot has no such row');
    }
    final reference = BlockPageDocument.fromJson(row.body).media[blockId];
    if (reference == null) {
      throw const FormatException('This row block has no registered media');
    }
    final bytes = _files[reference.path];
    if (bytes == null) {
      throw const FormatException('Database row media file is missing');
    }
    return Uint8List.fromList(bytes);
  }
}

WorkspaceDatabase _readDatabase(Map<String, Uint8List> files) {
  final bytes = files['database.json'];
  if (bytes == null) {
    throw const FormatException('Database snapshot has no database.json');
  }
  return WorkspaceDatabase.fromJson(jsonObject(jsonDecode(utf8.decode(bytes))));
}

Map<String, BlockPageDocument> _rowPages(WorkspaceDatabase database) => {
  for (final row in database.rows) row.id: BlockPageDocument.fromJson(row.body),
};

Iterable<BlockPageDocument> _templatePages(WorkspaceDatabase database) =>
    database.rowTemplates.map(
      (template) => BlockPageDocument.fromJson(template.body),
    );

void _validateFiles(Map<String, Uint8List> files) {
  var size = 0;
  for (final entry in files.entries) {
    validateLogicalPath(entry.key);
    size += entry.value.length;
    if (size > DatabaseMediaSnapshot.maxSnapshotBytes) {
      throw const FormatException('Database snapshot must be at most 128 MiB');
    }
  }
}

void _validateMedia(
  Iterable<BlockPageDocument> pages,
  Map<String, Uint8List> files,
) {
  final references = <String, List<BlockPageMedia>>{};
  for (final page in pages) {
    for (final media in page.media.values) {
      references.putIfAbsent(media.path, () => []).add(media);
    }
  }
  for (final entry in references.entries) {
    final bytes = files[entry.key];
    if (bytes == null) {
      throw const FormatException('Database row media file is missing');
    }
    final reference = entry.value.first;
    for (final other in entry.value.skip(1)) {
      if (other.sha256 != reference.sha256 ||
          other.byteLength != reference.byteLength ||
          other.mimeType != reference.mimeType ||
          other.width != reference.width ||
          other.height != reference.height) {
        throw const FormatException(
          'Shared database media descriptors are inconsistent',
        );
      }
    }
    reference.verifyBytes(bytes);
  }
}

Map<String, Uint8List> _copyFiles(Map<String, Uint8List> files) =>
    Map.unmodifiable({
      for (final entry in files.entries)
        entry.key: Uint8List.fromList(entry.value),
    });

bool _sameBytes(Uint8List first, Uint8List second) {
  if (first.length != second.length) return false;
  for (var index = 0; index < first.length; index++) {
    if (first[index] != second[index]) return false;
  }
  return true;
}
