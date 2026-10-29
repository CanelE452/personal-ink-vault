import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'package:ink_vault_core/src/revision.dart';

/// Canonical state is immutable manifests plus SHA-256 blobs. Indexes are rebuilt
/// on open. Operations are serialized per instance; cross-process locking and
/// power-loss durability of directory entries are not promised.
/// Verified immutable blobs are cached per instance. External disk mutations are
/// checked on explicit payload reads/imports and reopen, without a file watcher.
class NoteRepository {
  final Directory root;
  final String vaultId;
  final String deviceId;
  final _changes = StreamController<void>.broadcast();
  final _records = <String, RevisionRecord>{};
  final _active = <String, RevisionRecord>{};
  final _integrityIssues = <String>[];
  final _validatedBlobLengths = <String, int>{};
  Future<void> _tail = Future.value();
  bool _closed = false;

  NoteRepository._(this.root, this.vaultId, this.deviceId);

  Stream<void> get changes => _changes.stream;

  /// Damaged records remain on disk for inspection; they cannot become heads.
  List<String> get integrityIssues => List.unmodifiable(_integrityIssues);

  int get pendingRevisionCount => _records.length - _active.length;

  static Future<NoteRepository> open(
    Directory root, {
    String? vaultId,
    String? deviceId,
  }) async {
    if (vaultId != null) validateId(vaultId);
    if (deviceId != null) validateId(deviceId);
    await root.create(recursive: true);
    final config = File('${root.path}/vault.json');
    String storedVault;
    String storedDevice;
    if (await config.exists()) {
      final json = jsonObject(jsonDecode(await config.readAsString()));
      if (json['formatVersion'] != 1 ||
          json['vaultId'] is! String ||
          json['deviceId'] is! String) {
        throw const FormatException('Invalid vault configuration');
      }
      storedVault = json['vaultId'] as String;
      storedDevice = json['deviceId'] as String;
      validateId(storedVault);
      validateId(storedDevice);
      if (vaultId != null && storedVault != vaultId ||
          deviceId != null && storedDevice != deviceId) {
        throw const FormatException('Vault or device identity mismatch');
      }
    } else {
      storedVault = vaultId ?? newId();
      storedDevice = deviceId ?? newId();
      await _atomicWrite(
        config,
        utf8.encode(
          jsonEncode({
            'formatVersion': 1,
            'vaultId': storedVault,
            'deviceId': storedDevice,
          }),
        ),
      );
    }
    final repository = NoteRepository._(
      root.absolute,
      storedVault,
      storedDevice,
    );
    await Directory('${root.path}/blobs').create();
    await Directory('${root.path}/revisions').create();
    await for (final file in Directory(
      '${root.path}/revisions',
    ).list(followLinks: false)) {
      if (file is! File || !file.path.endsWith('.json')) continue;
      try {
        final r = RevisionRecord.fromJson(
          jsonObject(jsonDecode(await file.readAsString())),
        );
        if (r.vaultId != storedVault ||
            file.uri.pathSegments.last != '${r.revisionId}.json') {
          throw const FormatException('Revision identity mismatch');
        }
        repository._records[r.revisionId] = r;
      } on FormatException {
        repository._integrityIssues.add(
          'Invalid manifest: ${file.uri.pathSegments.last}',
        );
      }
    }
    await repository._rebuild();
    return repository;
  }

  Future<T> _serial<T>(Future<T> Function() action) {
    if (_closed) return Future.error(StateError('Repository is closed'));
    final next = _tail.then((_) => action());
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return next;
  }

  Future<RevisionRecord> commit({
    required String entityId,
    required EntityKind kind,
    required Map<String, Uint8List> files,
    required List<String> parentRevisionIds,
    String? ownerNoteId,
    bool deleted = false,
    Map<String, List<String>> baseRefs = const {},
  }) async {
    final copiedFiles = files.map(
      (key, value) => MapEntry(key, Uint8List.fromList(value)),
    );
    final r = RevisionRecord(
      vaultId: vaultId,
      entityId: entityId,
      kind: kind,
      revisionId: newId(),
      parentRevisionIds: parentRevisionIds,
      deviceId: deviceId,
      ownerNoteId: ownerNoteId,
      deleted: deleted,
      baseRefs: baseRefs,
      blobs: copiedFiles.map(
        (key, value) => MapEntry(
          key,
          BlobRef(hash: sha256.convert(value).toString(), length: value.length),
        ),
      ),
    );
    return await _serial(() async {
      for (final parent in r.parentRevisionIds) {
        if (!_active.containsKey(parent))
          throw const FormatException('Unknown or incomplete local parent');
      }
      await _import(r, {
        for (final entry in copiedFiles.entries)
          r.blobs[entry.key]!.hash: entry.value,
      });
      return r;
    });
  }

  Future<List<RevisionRecord>> revisions() =>
      _serial(() async => List.unmodifiable(_active.values));

  Future<List<RevisionRecord>> heads(String entityId) => _serial(() async {
    validateId(entityId);
    final revisions = _active.values
        .where((r) => r.entityId == entityId)
        .toList();
    final parents = revisions.expand((r) => r.parentRevisionIds).toSet();
    return List.unmodifiable(
      revisions.where((r) => !parents.contains(r.revisionId)),
    );
  });

  Future<Uint8List> readBlob(String hash) => _serial(() async {
    try {
      return await _readBlob(hash);
    } on FileSystemException {
      await _rebuild();
      rethrow;
    } on FormatException {
      await _rebuild();
      rethrow;
    }
  });

  Future<Uint8List> _readBlob(String hash) async {
    validateHash(hash);
    try {
      final data = await File('${root.path}/blobs/$hash').readAsBytes();
      if (sha256.convert(data).toString() != hash)
        throw const FormatException('Blob hash mismatch');
      _validatedBlobLengths[hash] = data.length;
      return data;
    } on FileSystemException {
      _validatedBlobLengths.remove(hash);
      rethrow;
    } on FormatException {
      _validatedBlobLengths.remove(hash);
      rethrow;
    }
  }

  Future<Map<String, Uint8List>> readFiles(RevisionRecord record) =>
      _serial(() async {
        if (record.vaultId != vaultId)
          throw const FormatException('Foreign vault');
        final files = <String, Uint8List>{};
        try {
          for (final entry in record.blobs.entries) {
            final data = await _readBlob(entry.value.hash);
            if (data.length != entry.value.length)
              throw const FormatException('Blob length mismatch');
            files[entry.key] = data;
          }
        } on FileSystemException {
          await _rebuild();
          rethrow;
        } on FormatException {
          await _rebuild();
          rethrow;
        }
        return files;
      });

  Future<void> importRevision(
    RevisionRecord record, {
    required Map<String, Uint8List> blobsByHash,
  }) {
    final copied = blobsByHash.map(
      (key, value) => MapEntry(key, Uint8List.fromList(value)),
    );
    return _serial(() => _import(record, copied));
  }

  void _validateGraph(RevisionRecord r) {
    if (r.vaultId != vaultId) throw const FormatException('Foreign vault');
    for (final known in _records.values.where(
      (known) => known.entityId == r.entityId,
    )) {
      if (known.kind != r.kind || known.ownerNoteId != r.ownerNoteId) {
        throw const FormatException('Entity kind or owner cannot change');
      }
    }
    for (final id in r.parentRevisionIds) {
      final parent = _records[id];
      if (parent != null &&
          (parent.entityId != r.entityId ||
              parent.kind != r.kind ||
              parent.ownerNoteId != r.ownerNoteId)) {
        throw const FormatException('Invalid parent identity');
      }
    }
    final visiting = <String>{};
    final visited = <String>{};
    void visit(String id) {
      if (visited.contains(id)) return;
      if (!visiting.add(id)) throw const FormatException('Revision cycle');
      final node = id == r.revisionId ? r : _records[id];
      if (node != null) {
        for (final parent in node.parentRevisionIds) {
          visit(parent);
        }
      }
      visiting.remove(id);
      visited.add(id);
    }

    visit(r.revisionId);
  }

  Future<void> _import(
    RevisionRecord r,
    Map<String, Uint8List> bytesByHash,
  ) async {
    _validateGraph(r);
    final existing = _records[r.revisionId];
    if (existing != null &&
        jsonEncode(existing.toJson()) != jsonEncode(r.toJson())) {
      throw const FormatException('Immutable revision ID collision');
    }
    final blobs = <String, Uint8List>{};
    for (final ref in r.blobs.values) {
      final checked = blobs[ref.hash];
      if (checked != null) {
        if (checked.length != ref.length)
          throw const FormatException('Blob length mismatch');
        continue;
      }
      final data = bytesByHash[ref.hash] ?? await _readBlob(ref.hash);
      if (data.length != ref.length ||
          sha256.convert(data).toString() != ref.hash) {
        throw const FormatException('Blob hash or length mismatch');
      }
      blobs[ref.hash] = data;
    }
    for (final entry in blobs.entries) {
      final file = File('${root.path}/blobs/${entry.key}');
      if (await file.exists()) {
        try {
          await _readBlob(entry.key);
        } on FormatException {
          // The incoming bytes were hash-checked above; replace only corrupted
          // bytes, never a different logical revision or a valid blob.
          await _atomicWrite(file, entry.value);
        }
      } else {
        await _atomicWrite(file, entry.value);
      }
      _validatedBlobLengths[entry.key] = entry.value.length;
    }
    if (existing == null) {
      await _atomicWrite(
        File('${root.path}/revisions/${r.revisionId}.json'),
        utf8.encode(jsonEncode(r.toJson())),
      );
      _records[r.revisionId] = r;
      _integrityIssues.remove('Invalid manifest: ${r.revisionId}.json');
    }
    await _rebuild();
    _changes.add(null);
  }

  Future<void> _rebuild() async {
    _active.clear();
    _integrityIssues.removeWhere(
      (issue) => issue.startsWith('Incomplete or corrupt payload: '),
    );
    final complete = <String, RevisionRecord>{};
    final invalidBlobs = <String>{};
    for (final r in _records.values) {
      var valid = true;
      for (final ref in r.blobs.values) {
        if (invalidBlobs.contains(ref.hash)) {
          valid = false;
          continue;
        }
        try {
          final length =
              _validatedBlobLengths[ref.hash] ??
              (await _readBlob(ref.hash)).length;
          if (length != ref.length) valid = false;
        } on FileSystemException {
          invalidBlobs.add(ref.hash);
          valid = false;
        } on FormatException {
          invalidBlobs.add(ref.hash);
          valid = false;
        }
      }
      if (valid) {
        complete[r.revisionId] = r;
      } else {
        final issue = 'Incomplete or corrupt payload: ${r.revisionId}';
        if (!_integrityIssues.contains(issue)) _integrityIssues.add(issue);
      }
    }
    var progressed = true;
    while (progressed) {
      progressed = false;
      for (final r in complete.values) {
        if (_active.containsKey(r.revisionId)) continue;
        if (r.parentRevisionIds.every((id) {
          final parent = _active[id];
          return parent != null &&
              parent.entityId == r.entityId &&
              parent.kind == r.kind &&
              parent.ownerNoteId == r.ownerNoteId;
        })) {
          _active[r.revisionId] = r;
          progressed = true;
        }
      }
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _tail;
    await _changes.close();
  }
}

Future<void> _atomicWrite(File target, List<int> bytes) async {
  final temp = File('${target.path}.${newId()}.tmp');
  try {
    await temp.writeAsBytes(bytes, flush: true);
    await temp.rename(target.path);
  } finally {
    if (await temp.exists()) await temp.delete();
  }
}
