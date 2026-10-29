import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:ink_vault_core/src/repository.dart';
import 'package:ink_vault_core/src/revision.dart';

/// Portable JSON snapshots contain complete revisions and base64 blobs only.
/// This first format is held in memory (several times the encoded size during
/// processing), with a default 128 MiB encoded-size cap. It is not encrypted.
class BackupService {
  static const defaultMaxBytes = 128 * 1024 * 1024;

  static Future<Uint8List> exportSnapshot(
    NoteRepository repository, {
    int maxBytes = defaultMaxBytes,
  }) async {
    final revisions = await repository.revisions();
    if (repository.integrityIssues.isNotEmpty ||
        repository.pendingRevisionCount != 0) {
      throw const FormatException(
        'Repair or finish receiving the vault before export',
      );
    }
    final lengths = <String, int>{};
    for (final r in revisions) {
      for (final ref in r.blobs.values) {
        final previous = lengths[ref.hash];
        if (previous != null && previous != ref.length)
          throw const FormatException('Conflicting blob lengths');
        lengths[ref.hash] = ref.length;
      }
    }
    if (maxBytes <= 0 ||
        lengths.values.fold<int>(0, (sum, n) => sum + 4 * ((n + 2) ~/ 3)) >
            maxBytes) {
      throw const FormatException('Snapshot size limit exceeded');
    }
    final blobs = <String, String>{};
    for (final hash in lengths.keys.toList()..sort()) {
      final data = await repository.readBlob(hash);
      if (data.length != lengths[hash])
        throw const FormatException('Blob length mismatch');
      blobs[hash] = base64Encode(data);
    }
    final ordered = [...revisions]
      ..sort((a, b) => a.revisionId.compareTo(b.revisionId));
    final result = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'formatVersion': 1,
          'vaultId': repository.vaultId,
          'revisions': ordered.map((r) => r.toJson()).toList(),
          'blobs': blobs,
        }),
      ),
    );
    if (result.length > maxBytes)
      throw const FormatException('Snapshot size limit exceeded');
    return result;
  }

  static Future<NoteRepository> restoreToEmpty(
    Uint8List snapshot,
    Directory destination, {
    int maxBytes = defaultMaxBytes,
  }) async {
    if (maxBytes <= 0 || snapshot.length > maxBytes)
      throw const FormatException('Snapshot size limit exceeded');
    final raw = jsonObject(jsonDecode(utf8.decode(snapshot)));
    if (raw['formatVersion'] != 1 ||
        raw['vaultId'] is! String ||
        raw['revisions'] is! List) {
      throw const FormatException('Unsupported or invalid snapshot');
    }
    final oldVaultId = raw['vaultId'] as String;
    validateId(oldVaultId);
    final records = <String, RevisionRecord>{};
    final entities = <String, RevisionRecord>{};
    final lengths = <String, int>{};
    for (final item in raw['revisions'] as List) {
      final r = RevisionRecord.fromJson(jsonObject(item));
      if (r.vaultId != oldVaultId || records.containsKey(r.revisionId))
        throw const FormatException('Mixed vault or duplicate revision');
      final entity = entities[r.entityId];
      if (entity != null &&
          (entity.kind != r.kind || entity.ownerNoteId != r.ownerNoteId))
        throw const FormatException('Conflicting entity identity');
      entities[r.entityId] = r;
      records[r.revisionId] = r;
      for (final ref in r.blobs.values) {
        if (lengths.containsKey(ref.hash) && lengths[ref.hash] != ref.length)
          throw const FormatException('Conflicting blob lengths');
        lengths[ref.hash] = ref.length;
      }
    }
    final ordered = <RevisionRecord>[];
    final visited = <String>{};
    final visiting = <String>{};
    void visit(RevisionRecord r) {
      if (visited.contains(r.revisionId)) return;
      if (!visiting.add(r.revisionId))
        throw const FormatException('Cyclic snapshot ancestry');
      for (final id in r.parentRevisionIds) {
        final parent = records[id];
        if (parent == null ||
            parent.entityId != r.entityId ||
            parent.kind != r.kind ||
            parent.ownerNoteId != r.ownerNoteId) {
          throw const FormatException('Missing or foreign snapshot parent');
        }
        visit(parent);
      }
      visiting.remove(r.revisionId);
      visited.add(r.revisionId);
      ordered.add(r);
    }

    for (final r in records.values) {
      visit(r);
    }
    final blobs = <String, Uint8List>{};
    final encoded = jsonObject(raw['blobs']);
    if (encoded.length != lengths.length)
      throw const FormatException('Missing or unexpected snapshot blobs');
    for (final entry in encoded.entries) {
      validateHash(entry.key);
      if (!lengths.containsKey(entry.key) || entry.value is! String)
        throw const FormatException('Unexpected snapshot blob');
      final data = base64Decode(entry.value as String);
      if (data.length != lengths[entry.key] ||
          sha256.convert(data).toString() != entry.key)
        throw const FormatException('Corrupt snapshot blob');
      blobs[entry.key] = data;
    }
    // All untrusted input has been validated before touching the destination.
    final type = await FileSystemEntity.type(
      destination.path,
      followLinks: false,
    );
    if (type != FileSystemEntityType.notFound &&
            type != FileSystemEntityType.directory ||
        type == FileSystemEntityType.directory &&
            !await destination.list().isEmpty) {
      throw FileSystemException(
        'Restore destination must be empty',
        destination.path,
      );
    }
    await destination.parent.create(recursive: true);
    final staging = Directory('${destination.path}.restore-${newId()}');
    NoteRepository? repository;
    try {
      final vaultId = newId();
      repository = await NoteRepository.open(staging, vaultId: vaultId);
      for (final r in ordered) {
        final remapped = RevisionRecord.fromJson({
          ...r.toJson(),
          'vaultId': vaultId,
        });
        await repository.importRevision(
          remapped,
          blobsByHash: {
            for (final ref in r.blobs.values) ref.hash: blobs[ref.hash]!,
          },
        );
      }
      await repository.close();
      if (type == FileSystemEntityType.directory) await destination.delete();
      await staging.rename(destination.path);
      return await NoteRepository.open(destination);
    } finally {
      await repository?.close();
      if (await staging.exists()) await staging.delete(recursive: true);
    }
  }
}
