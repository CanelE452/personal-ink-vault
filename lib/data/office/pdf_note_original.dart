import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/office/office_document_store.dart';
import 'package:saber/data/vault/workspace_store.dart';

/// The Office or HWP original a "PDF 필기용" note was converted from.
class PdfNoteOriginal {
  const new _(this.fileName, this.bytes, this.engineVersion);
  final String fileName;
  final Uint8List bytes;

  /// The engine that converted the note's PDF, when it was recorded.
  final String? engineVersion;
}

/// Keeps the original of a "PDF 필기용" note in its own attachment owned by the note (the note's source stays the
/// PDF), so a newer engine can convert it into a new PDF note while the existing note, its PDF and its ink stay as
/// they are. Notes imported before 2026-11-14 have no original.
class PdfNoteOriginalStore {
  new(this.repository);
  final NoteRepository repository;
  static const metadataFile = 'office-original.json';

  /// Keeps [bytes] for [note] unless the note already has an original.
  Future<void> attach(
    VaultNote note, {
    required String fileName,
    required Uint8List bytes,
    String? engineVersion,
  }) async {
    final extension = p.extension(fileName).toLowerCase();
    if (note.documentKind != VaultDocumentKind.pdf ||
        extension.length < 2 ||
        !OfficeDocumentStore.supportedExtensions.contains(
          extension.substring(1),
        ) ||
        bytes.isEmpty) {
      throw const FormatException('Only a PDF note keeps an Office original');
    }
    if (await _record(note) != null) return;
    final file = 'original$extension';
    final metadata = {
      'schemaVersion': 1,
      'fileName': p.basename(fileName),
      'file': file,
      'sha256': sha256.convert(bytes).toString(),
      'bytes': bytes.length,
      'engineVersion': ?engineVersion,
    };
    await repository.commit(
      entityId: newId(),
      kind: EntityKind.attachment,
      ownerNoteId: note.id,
      files: {
        metadataFile: Uint8List.fromList(utf8.encode(jsonEncode(metadata))),
        file: Uint8List.fromList(bytes),
      },
      parentRevisionIds: const [],
    );
  }

  /// Whether [note] keeps an original, without reading any file.
  Future<bool> has(VaultNote note) async => await _record(note) != null;

  /// The kept original of [note], or null when the note has none.
  Future<PdfNoteOriginal?> read(VaultNote note) async {
    final record = await _record(note);
    if (record == null) return null;
    final files = await repository.readFiles(record);
    final metadata = jsonDecode(utf8.decode(files[metadataFile]!));
    final file = metadata is Map ? metadata['file'] : null;
    final bytes = file is String ? files[file] : null;
    if (metadata is! Map ||
        bytes == null ||
        metadata['fileName'] is! String ||
        metadata['sha256'] != sha256.convert(bytes).toString()) {
      throw const FormatException('The kept original does not match its record');
    }
    final version = metadata['engineVersion'];
    return PdfNoteOriginal._(
      metadata['fileName'] as String,
      bytes,
      version is String ? version : null,
    );
  }

  Future<RevisionRecord?> _record(VaultNote note) async {
    final records = await repository.revisions();
    final parents = {for (final record in records) ...record.parentRevisionIds};
    RevisionRecord? found;
    for (final record in records) {
      if (record.kind != EntityKind.attachment ||
          record.ownerNoteId != note.id ||
          record.entityId == note.sourceEntityId ||
          record.deleted ||
          !record.blobs.containsKey(metadataFile) ||
          parents.contains(record.revisionId)) {
        continue;
      }
      // Two devices may each keep the same original for one note; either copy serves.
      if (found == null || record.revisionId.compareTo(found.revisionId) < 0) {
        found = record;
      }
    }
    return found;
  }
}
