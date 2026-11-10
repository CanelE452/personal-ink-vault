import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'package:ink_vault_core/src/revision.dart';

/// An in-memory write snapshot with a stable revision ID. Keep the same token
/// while retrying, or persist its recovery descriptor together with the files.
final class PreparedCommit {
  PreparedCommit._(this._rootUri, this.record, this._filesByHash);

  final String _rootUri;
  final RevisionRecord record;
  final Map<String, Uint8List> _filesByHash;

  /// Contains no payload bytes. The caller must authenticate its association
  /// with a durable operation receipt before recovering it in another process.
  Map<String, Object?> toRecoveryDescriptor() => {
    'version': 1,
    'rootUri': _rootUri,
    'record': record.toJson(),
  };

  bool belongsTo(NoteRepository repository) =>
      _rootUri == repository.root.absolute.uri.normalizePath().toString() &&
      record.vaultId == repository.vaultId &&
      record.deviceId == repository.deviceId &&
      record.formatVersion == repository.formatVersion;

  bool matchesFiles(Map<String, Uint8List> files) {
    if (files.length != record.blobs.length) return false;
    for (final entry in files.entries) {
      final ref = record.blobs[entry.key];
      if (ref == null || entry.value.length != ref.length) return false;
      final saved = _filesByHash[ref.hash]!;
      for (var index = 0; index < saved.length; index++) {
        if (saved[index] != entry.value[index]) return false;
      }
    }
    return true;
  }
}

/// Canonical state is immutable manifests plus SHA-256 blobs. Indexes are rebuilt
/// on open. Operations are serialized per instance; cross-process locking and
/// power-loss durability of directory entries are not promised.
/// Verified immutable blobs are cached per instance. External disk mutations are
/// checked on explicit payload reads/imports and disk refresh, without a file
/// watcher.
class NoteRepository {
  final Directory root;
  final String vaultId;
  final String deviceId;
  final int formatVersion;
  final _changes = StreamController<void>.broadcast();
  final _records = <String, RevisionRecord>{};
  final _active = <String, RevisionRecord>{};
  final _integrityIssues = <String>[];
  final _validatedBlobLengths = <String, int>{};
  Future<void> _tail = Future.value();
  bool _closed = false;

  NoteRepository._(this.root, this.vaultId, this.deviceId, this.formatVersion);

  Stream<void> get changes => _changes.stream;

  /// Damaged records remain on disk for inspection; they cannot become heads.
  List<String> get integrityIssues => List.unmodifiable(_integrityIssues);

  int get pendingRevisionCount => _records.length - _active.length;

  static Future<NoteRepository> open(
    Directory root, {
    String? vaultId,
    String? deviceId,
    int createFormatVersion = 1,
  }) async {
    if (createFormatVersion != 1 && createFormatVersion != 2) {
      throw const FormatException('Unsupported vault format');
    }
    if (vaultId != null) validateId(vaultId);
    if (deviceId != null) validateId(deviceId);
    await root.create(recursive: true);
    final config = File('${root.path}/vault.json');
    String storedVault;
    String storedDevice;
    int storedFormat;
    if (await config.exists()) {
      (storedVault, storedDevice, storedFormat) = await _readIdentity(config);
      if (vaultId != null && storedVault != vaultId ||
          deviceId != null && storedDevice != deviceId) {
        throw const FormatException('Vault or device identity mismatch');
      }
    } else {
      storedVault = vaultId ?? newId();
      storedDevice = deviceId ?? newId();
      storedFormat = createFormatVersion;
      await _atomicWrite(
        config,
        utf8.encode(
          jsonEncode({
            'formatVersion': storedFormat,
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
      storedFormat,
    );
    await Directory('${root.path}/blobs').create();
    await Directory('${root.path}/revisions').create();
    await repository._loadRecords();
    return repository;
  }

  static Future<(String, String, int)> _readIdentity(File config) async {
    final json = jsonObject(jsonDecode(await config.readAsString()));
    final vault = json['vaultId'];
    final device = json['deviceId'];
    final format = json['formatVersion'];
    if (vault is! String ||
        device is! String ||
        format is! int ||
        (format != 1 && format != 2)) {
      throw const FormatException('Invalid vault configuration');
    }
    validateId(vault);
    validateId(device);
    return (vault, device, format);
  }

  Future<void> _loadRecords() async {
    await for (final file in Directory(
      '${root.path}/revisions',
    ).list(followLinks: false)) {
      if (file is! File || !file.path.endsWith('.json')) continue;
      try {
        final r = RevisionRecord.fromJson(
          jsonObject(jsonDecode(await file.readAsString())),
        );
        if (r.formatVersion > formatVersion ||
            r.vaultId != vaultId ||
            file.uri.pathSegments.last != '${r.revisionId}.json') {
          throw const FormatException('Revision identity mismatch');
        }
        _records[r.revisionId] = r;
      } on FormatException {
        _integrityIssues.add('Invalid manifest: ${file.uri.pathSegments.last}');
      }
    }
    await _rebuild();
  }

  Future<T> _serial<T>(Future<T> Function() action) {
    if (_closed) return Future.error(StateError('Repository is closed'));
    final next = _tail.then((_) => action());
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return next;
  }

  /// Reloads revisions written by a background worker while keeping open
  /// sessions and their change subscriptions bound to this repository.
  Future<void> reloadFromDisk() => _serial(() async {
    final identity = await _readIdentity(File('${root.path}/vault.json'));
    if (identity != (vaultId, deviceId, formatVersion)) {
      throw const FormatException('Vault identity or format changed');
    }

    final snapshot = NoteRepository._(root, vaultId, deviceId, formatVersion);
    try {
      await snapshot._loadRecords();
      _records
        ..clear()
        ..addAll(snapshot._records);
      _active
        ..clear()
        ..addAll(snapshot._active);
      _integrityIssues
        ..clear()
        ..addAll(snapshot._integrityIssues);
      _validatedBlobLengths
        ..clear()
        ..addAll(snapshot._validatedBlobLengths);
      _changes.add(null);
    } finally {
      await snapshot.close();
    }
  });

  Future<RevisionRecord> commit({
    required String entityId,
    required EntityKind kind,
    required Map<String, Uint8List> files,
    required List<String> parentRevisionIds,
    String? ownerNoteId,
    bool deleted = false,
    Map<String, List<String>> baseRefs = const {},
  }) async => commitPrepared(
    prepareCommit(
      entityId: entityId,
      kind: kind,
      files: files,
      parentRevisionIds: parentRevisionIds,
      ownerNoteId: ownerNoteId,
      deleted: deleted,
      baseRefs: baseRefs,
    ),
  );

  PreparedCommit prepareCommit({
    required String entityId,
    required EntityKind kind,
    required Map<String, Uint8List> files,
    required List<String> parentRevisionIds,
    String? ownerNoteId,
    bool deleted = false,
    Map<String, List<String>> baseRefs = const {},
  }) {
    if (_closed) throw StateError('Repository is closed');
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
      formatVersion: formatVersion,
      blobs: copiedFiles.map(
        (key, value) => MapEntry(
          key,
          BlobRef(hash: sha256.convert(value).toString(), length: value.length),
        ),
      ),
    );
    return PreparedCommit._(
      root.absolute.uri.normalizePath().toString(),
      r,
      Map.unmodifiable({
        for (final entry in copiedFiles.entries)
          r.blobs[entry.key]!.hash: entry.value,
      }),
    );
  }

  /// Reconstructs a receipt's exact write snapshot without publishing it.
  /// This validates structure and scope, not the descriptor's authenticity.
  /// The caller must authenticate its association with the operation receipt.
  PreparedCommit resumePreparedCommit({
    required Map<String, dynamic> descriptor,
    required Map<String, Uint8List> files,
  }) {
    if (_closed) throw StateError('Repository is closed');
    _requireRecoveryFields(descriptor, const {'version', 'rootUri', 'record'});
    if (descriptor['version'] is! int || descriptor['version'] != 1)
      throw const FormatException('Unsupported prepared recovery version');
    if (descriptor['rootUri'] is! String ||
        descriptor['rootUri'] != root.absolute.uri.normalizePath().toString())
      throw const FormatException('Prepared recovery belongs to another root');
    final manifest = jsonObject(descriptor['record']);
    _requireRecoveryFields(manifest, const {
      'vaultId',
      'entityId',
      'kind',
      'revisionId',
      'parentRevisionIds',
      'deviceId',
      'formatVersion',
      'deleted',
      'ownerNoteId',
      'blobs',
      'baseRefs',
    });
    if (manifest['formatVersion'] is! int)
      throw const FormatException('Invalid revision format');
    for (final value in jsonObject(manifest['blobs']).values) {
      _requireRecoveryFields(jsonObject(value), const {'hash', 'length'});
    }
    final record = RevisionRecord.fromJson(manifest);
    if (record.vaultId != vaultId ||
        record.deviceId != deviceId ||
        record.formatVersion != formatVersion)
      throw const FormatException(
        'Prepared recovery belongs to another repository',
      );
    _validateGraph(record);
    final existing = _records[record.revisionId];
    if (existing != null &&
        jsonEncode(existing.toJson()) != jsonEncode(record.toJson()))
      throw const FormatException('Immutable revision ID collision');
    if (files.length != record.blobs.length)
      throw const FormatException('Prepared recovery file names mismatch');
    final copied = <String, Uint8List>{};
    for (final entry in files.entries) {
      final ref = record.blobs[entry.key];
      if (ref == null)
        throw const FormatException('Prepared recovery file names mismatch');
      final data = Uint8List.fromList(entry.value);
      if (data.length != ref.length ||
          sha256.convert(data).toString() != ref.hash)
        throw const FormatException(
          'Prepared recovery hash or length mismatch',
        );
      copied[ref.hash] = data;
    }
    return PreparedCommit._(
      descriptor['rootUri'] as String,
      record,
      Map.unmodifiable(copied),
    );
  }

  Future<RevisionRecord> commitPrepared(PreparedCommit prepared) =>
      _serial(() => _publishPrepared(prepared));

  /// Checks the observations in the same per-instance queue as publication.
  /// External processes do not share the queue. An exact prepared retry may
  /// reuse its own unchanged head, but never a later branch or descendant.
  /// [beforePublish] is a pure synchronous validator and may be called multiple
  /// times, including immediately before the final revision manifest rename.
  /// [allowHistoricalParents] preserves existing branches while guarding current
  /// heads and requires a whole revision snapshot with valid nonempty parents.
  Future<RevisionRecord> commitPreparedIfHeads(
    PreparedCommit prepared, {
    required Map<String, List<String>> expectedHeads,
    List<String>? expectedRevisionIds,
    void Function()? beforePublish,
    bool allowHistoricalParents = false,
  }) {
    try {
      Set<String> copyIds(List<String> values) {
        for (final id in values) {
          validateId(id);
        }
        final ids = Set<String>.unmodifiable(values);
        if (ids.length != values.length)
          throw const FormatException('Duplicate expected revision identity');
        return ids;
      }

      final guards = <String, Set<String>>{};
      for (final entry in expectedHeads.entries) {
        validateId(entry.key);
        guards[entry.key] = copyIds(entry.value);
      }
      final writeGuard = guards[prepared.record.entityId];
      final directParents = prepared.record.parentRevisionIds.toSet();
      if (writeGuard == null ||
          !allowHistoricalParents && !_sameIds(writeGuard, directParents))
        throw const FormatException('The write entity must guard its parents');
      final snapshot = expectedRevisionIds == null
          ? null
          : copyIds(expectedRevisionIds);
      if (allowHistoricalParents && (snapshot == null || directParents.isEmpty))
        throw const FormatException(
          'Historical parents require a whole snapshot and nonempty parents',
        );
      return _serial(() async {
        if (!prepared.belongsTo(this))
          throw const FormatException(
            'Prepared commit belongs to another repository',
          );
        if (pendingRevisionCount != 0 || _integrityIssues.isNotEmpty)
          throw StateError(
            'Repair or finish receiving revisions before conditional publication',
          );
        if (allowHistoricalParents) {
          for (final id in directParents) {
            final parent = _active[id];
            if (!snapshot!.contains(id) || parent == null)
              throw const FormatException('Unknown or uncaptured local parent');
            if (parent.entityId != prepared.record.entityId ||
                parent.kind != prepared.record.kind ||
                parent.ownerNoteId != prepared.record.ownerNoteId)
              throw const FormatException('Invalid parent identity');
          }
        }
        final parents = _active.values
            .expand((record) => record.parentRevisionIds)
            .toSet();
        final currentHeads = <String, Set<String>>{};
        for (final record in _active.values) {
          if (!parents.contains(record.revisionId))
            (currentHeads[record.entityId] ??= {}).add(record.revisionId);
        }
        final ownHeads =
            currentHeads[prepared.record.entityId] ?? const <String>{};
        final repeatedHeads = {
          if (allowHistoricalParents) ...writeGuard.difference(directParents),
          prepared.record.revisionId,
        };
        final repeated = _sameIds(ownHeads, repeatedHeads);
        for (final entry in guards.entries) {
          final current = currentHeads[entry.key] ?? const <String>{};
          if (!_sameIds(current, entry.value) &&
              !(entry.key == prepared.record.entityId && repeated))
            throw StateError(
              'Revision heads changed before conditional publication',
            );
        }
        if (snapshot != null) {
          final current = _active.keys.toSet();
          if (!_sameIds(current, snapshot) &&
              !(repeated &&
                  _sameIds(current, {...snapshot, prepared.record.revisionId})))
            throw StateError(
              'Repository changed before conditional publication',
            );
        }
        beforePublish?.call();
        return _publishPrepared(prepared, beforeManifestRename: beforePublish);
      });
    } catch (error, stack) {
      return Future.error(error, stack);
    }
  }

  static bool _sameIds(Set<String> left, Set<String> right) =>
      left.length == right.length && left.containsAll(right);

  Future<RevisionRecord> _publishPrepared(
    PreparedCommit prepared, {
    void Function()? beforeManifestRename,
  }) async {
    if (!prepared.belongsTo(this))
      throw const FormatException(
        'Prepared commit belongs to another repository',
      );
    final r = prepared.record;
    for (final parent in r.parentRevisionIds) {
      if (!_active.containsKey(parent))
        throw const FormatException('Unknown or incomplete local parent');
    }
    final manifest = File('${root.path}/revisions/${r.revisionId}.json');
    final manifestMissing = !await manifest.exists();
    if (!manifestMissing) {
      final existing = RevisionRecord.fromJson(
        jsonObject(jsonDecode(await manifest.readAsString())),
      );
      if (jsonEncode(existing.toJson()) != jsonEncode(r.toJson()))
        throw const FormatException('Immutable revision ID collision');
    }
    await _import(
      r,
      prepared._filesByHash,
      restoreMissingManifest: manifestMissing,
      beforeManifestRename: beforeManifestRename,
    );
    return r;
  }

  /// Confirms an already published immutable record and rejoins this instance's
  /// index after a lost rename response. This never writes or repairs files.
  Future<RevisionRecord> confirmPublishedCommit(
    PreparedCommit prepared,
  ) => _serial(() async {
    if (!prepared.belongsTo(this))
      throw const FormatException('Foreign published commit');
    final record = prepared.record;
    final manifest = File('${root.path}/revisions/${record.revisionId}.json');
    final known = _records[record.revisionId];
    var manifestMatchesKnown = false;
    Future<RevisionRecord> readManifest() async {
      manifestMatchesKnown = false;
      final type = FileSystemEntity.typeSync(manifest.path, followLinks: false);
      if (type == FileSystemEntityType.notFound)
        throw FileSystemException(
          'Published manifest is missing',
          manifest.path,
        );
      if (type != FileSystemEntityType.file)
        throw const FormatException(
          'Published manifest must be a regular file',
        );
      final actual = RevisionRecord.fromJson(
        jsonObject(jsonDecode(await manifest.readAsString())),
      );
      manifestMatchesKnown =
          known != null &&
          jsonEncode(actual.toJson()) == jsonEncode(known.toJson());
      return actual;
    }

    try {
      final actual = await readManifest();
      final expectedJson = jsonEncode(record.toJson());
      if (jsonEncode(actual.toJson()) != expectedJson ||
          known != null && jsonEncode(known.toJson()) != expectedJson)
        throw const FormatException('Immutable published revision collision');
      _validateGraph(record);
      final files = <String, Uint8List>{};
      for (final entry in record.blobs.entries) {
        final bytes = await _readBlob(entry.value.hash);
        if (bytes.length != entry.value.length)
          throw const FormatException('Published blob length mismatch');
        files[entry.key] = bytes;
      }
      if (!prepared.matchesFiles(files))
        throw const FormatException(
          'Published bytes do not match the prepared commit',
        );
      final checked = await readManifest();
      if (jsonEncode(checked.toJson()) != expectedJson)
        throw const FormatException(
          'Published manifest changed during confirmation',
        );
      _records[record.revisionId] = record;
      await _rebuild();
      if (!_active.containsKey(record.revisionId))
        throw const FormatException('Published revision graph is incomplete');
      if (known == null) _changes.add(null);
      return record;
    } catch (error) {
      if (error is FileSystemException || error is FormatException) {
        final invalidated = known != null && !manifestMatchesKnown;
        if (invalidated) {
          _records.remove(record.revisionId);
          _integrityIssues.add('Invalid manifest: ${record.revisionId}.json');
        }
        await _rebuild();
        if (invalidated) _changes.add(null);
      }
      rethrow;
    }
  });

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

  Future<Uint8List> readRevisionFile(RevisionRecord revision, String name) =>
      _serial(() async {
        if (revision.vaultId != vaultId)
          throw const FormatException('Foreign vault');
        final ref = revision.blobs[name];
        if (ref == null) throw const FormatException('Unknown revision file');
        try {
          final data = await _readBlob(ref.hash);
          if (data.length != ref.length)
            throw const FormatException('Blob length mismatch');
          return data;
        } on FileSystemException {
          await _rebuild();
          rethrow;
        } on FormatException {
          await _rebuild();
          rethrow;
        }
      });

  Future<void> importRevision(
    RevisionRecord record, {
    required Map<String, Uint8List> blobsByHash,
    void Function()? beforePublish,
  }) {
    final copied = blobsByHash.map(
      (key, value) => MapEntry(key, Uint8List.fromList(value)),
    );
    return _serial(() {
      beforePublish?.call();
      return _import(record, copied, beforeManifestRename: beforePublish);
    });
  }

  Future<bool> hasKnownRevisions(Iterable<String> entityIds) {
    final ids = entityIds.toSet();
    return _serial(
      () async => _records.values.any((r) => ids.contains(r.entityId)),
    );
  }

  /// Publishes a new note only if neither entity has been received or created.
  /// Stage the Markdown child first so a retry can complete it without choosing
  /// a template again. Publishing metadata last keeps the note hidden until its
  /// Markdown is complete. The ordering is recoverable, not a disk transaction.
  Future<bool> importInitialNoteIfHeads({
    required RevisionRecord metadata,
    required RevisionRecord markdown,
    required RevisionRecord? initialMarkdown,
    required Map<String, Uint8List> blobsByHash,
    required Map<String, List<String>> expectedHeads,
    void Function()? beforePublish,
  }) {
    final records = [
      if (initialMarkdown != null) initialMarkdown,
      markdown,
      metadata,
    ];
    final revisionIds = records.map((r) => r.revisionId).toSet();
    if (formatVersion != 2 ||
        revisionIds.length != records.length ||
        metadata.entityId == markdown.entityId ||
        metadata.kind != EntityKind.metadata ||
        markdown.kind != EntityKind.markdown ||
        markdown.ownerNoteId != metadata.entityId ||
        metadata.parentRevisionIds.isNotEmpty ||
        markdown.parentRevisionIds.isNotEmpty ||
        (initialMarkdown != null &&
            (initialMarkdown.kind != EntityKind.markdown ||
                initialMarkdown.ownerNoteId != metadata.entityId ||
                initialMarkdown.entityId != markdown.entityId ||
                initialMarkdown.parentRevisionIds.singleOrNull !=
                    markdown.revisionId)) ||
        records.any(
          (r) =>
              r.vaultId != vaultId ||
              r.formatVersion != formatVersion ||
              r.deleted ||
              r.baseRefs.isNotEmpty ||
              r.blobs.length != 1,
        ) ||
        metadata.blobs.values.single.length > 4096 ||
        markdown.blobs.values.single.length != 0 ||
        (initialMarkdown != null &&
            (initialMarkdown.blobs.values.single.length == 0 ||
                initialMarkdown.blobs.values.single.length >
                    4 * 1024 * 1024))) {
      throw const FormatException('Invalid initial note revisions');
    }
    final files = <String, Uint8List>{};
    for (final record in records) {
      final ref = record.blobs.values.single;
      final bytes = blobsByHash[ref.hash];
      if (bytes == null ||
          bytes.length != ref.length ||
          sha256.convert(bytes).toString() != ref.hash) {
        throw const FormatException('Invalid initial note payload');
      }
      files[ref.hash] = Uint8List.fromList(bytes);
    }
    if (blobsByHash.length != files.length) {
      throw const FormatException('Unexpected initial note payload');
    }
    final guards = <String, Set<String>>{};
    for (final entry in expectedHeads.entries) {
      validateId(entry.key);
      for (final id in entry.value) {
        validateId(id);
      }
      final ids = entry.value.toSet();
      if (ids.length != entry.value.length) {
        throw const FormatException('Duplicate expected revision identity');
      }
      guards[entry.key] = ids;
    }
    return _serial(() async {
      if (_records.values.any(
        (r) =>
            r.entityId == metadata.entityId || r.entityId == markdown.entityId,
      )) {
        return false;
      }
      if (pendingRevisionCount != 0 || _integrityIssues.isNotEmpty) {
        throw StateError(
          'Repair or finish receiving revisions before conditional publication',
        );
      }
      if (revisionIds.any(_records.containsKey)) {
        throw const FormatException('Immutable revision ID collision');
      }
      final current = <String, Set<String>>{
        for (final id in guards.keys) id: {},
      };
      final parents = _active.values.expand((r) => r.parentRevisionIds).toSet();
      for (final r in _active.values) {
        if (!parents.contains(r.revisionId))
          current[r.entityId]?.add(r.revisionId);
      }
      if (guards.entries.any(
        (guard) => !_sameIds(current[guard.key]!, guard.value),
      )) {
        throw StateError(
          'Revision heads changed before conditional publication',
        );
      }
      beforePublish?.call();
      for (final record in records) {
        await _import(record, files, beforeManifestRename: beforePublish);
      }
      return true;
    });
  }

  /// A fixed complete revision graph is copied while this instance's writers
  /// wait. Blobs are copied and independently verified in 1 MiB chunks.
  Future<NoteRepository> cloneToEmpty(
    Directory destination, {
    int? targetFormatVersion,
  }) => _serial(() async {
    final targetFormat = targetFormatVersion ?? formatVersion;
    if ((targetFormat != 1 && targetFormat != 2) ||
        targetFormat < formatVersion)
      throw const FormatException('Unsupported vault format conversion');
    if (_integrityIssues.isNotEmpty || pendingRevisionCount != 0)
      throw const FormatException(
        'Repair or finish receiving the vault before cloning',
      );
    final ordered = _orderedCloneRecords(
      _active.values.toList(),
      vaultId,
      formatVersion,
    );
    final lengths = <String, int>{};
    for (final record in ordered) {
      for (final ref in record.blobs.values) {
        if (lengths.containsKey(ref.hash) && lengths[ref.hash] != ref.length)
          throw const FormatException('Conflicting blob lengths');
        lengths[ref.hash] = ref.length;
      }
    }
    final sourceRoot = Directory(await root.resolveSymbolicLinks());
    final target = await _resolvedCloneDestination(destination);
    final sourceKey = _directoryKey(sourceRoot),
        targetKey = _directoryKey(target);
    if (sourceKey.startsWith(targetKey) || targetKey.startsWith(sourceKey))
      throw const FormatException(
        'Clone source and destination must not overlap',
      );
    for (final name in ['blobs', 'revisions']) {
      if (await FileSystemEntity.type(
            '${sourceRoot.path}/$name',
            followLinks: false,
          ) !=
          FileSystemEntityType.directory)
        throw const FormatException(
          'Clone source directories must not be links',
        );
    }
    final originalTargetType = await _requireEmptyCloneDestination(target);
    final newVaultId = newId(), newDeviceId = newId();
    final configPath = '${sourceRoot.path}/vault.json';
    if (await FileSystemEntity.type(configPath, followLinks: false) !=
        FileSystemEntityType.file)
      throw const FormatException('Clone configuration must be a regular file');
    final originalConfig = jsonObject(
      jsonDecode(await File(configPath).readAsString()),
    );
    if (originalConfig['vaultId'] != vaultId ||
        originalConfig['deviceId'] != deviceId ||
        originalConfig['formatVersion'] != formatVersion)
      throw const FormatException('Source configuration changed during clone');
    final config = <String, dynamic>{
      ...originalConfig,
      'formatVersion': targetFormat,
      'vaultId': newVaultId,
      'deviceId': newDeviceId,
    };
    final remapped = <RevisionRecord>[];
    final manifests = <Map<String, dynamic>>[];
    for (final record in ordered) {
      final path = '${sourceRoot.path}/revisions/${record.revisionId}.json';
      if (await FileSystemEntity.type(path, followLinks: false) !=
          FileSystemEntityType.file)
        throw const FormatException('Clone manifest must be a regular file');
      final raw = jsonObject(jsonDecode(await File(path).readAsString()));
      if (jsonEncode(RevisionRecord.fromJson(raw).toJson()) !=
          jsonEncode(record.toJson()))
        throw const FormatException('Source manifest changed during clone');
      final manifest = <String, dynamic>{...raw, 'vaultId': newVaultId};
      manifests.add(manifest);
      remapped.add(RevisionRecord.fromJson(manifest));
    }
    await target.parent.create(recursive: true);
    final staging = Directory('${target.path}.clone-${newId()}');
    final stagingKey = _directoryKey(staging);
    var created = false;
    var removedEmptyDestination = false;
    try {
      if (await FileSystemEntity.type(staging.path, followLinks: false) !=
          FileSystemEntityType.notFound)
        throw FileSystemException('Clone staging already exists', staging.path);
      await staging.create();
      created = true;
      await Directory('${staging.path}/blobs').create();
      await Directory('${staging.path}/revisions').create();
      for (final entry in lengths.entries) {
        await _streamVerifiedBlob(
          File('${sourceRoot.path}/blobs/${entry.key}'),
          entry.key,
          entry.value,
          destination: File('${staging.path}/blobs/${entry.key}'),
        );
      }
      for (var i = 0; i < remapped.length; i++) {
        await _atomicWrite(
          File('${staging.path}/revisions/${remapped[i].revisionId}.json'),
          utf8.encode(jsonEncode(manifests[i])),
        );
      }
      await _atomicWrite(
        File('${staging.path}/vault.json'),
        utf8.encode(jsonEncode(config)),
      );
      for (final entry in lengths.entries) {
        await _streamVerifiedBlob(
          File('${staging.path}/blobs/${entry.key}'),
          entry.key,
          entry.value,
        );
      }
      for (var i = 0; i < remapped.length; i++) {
        final actual = jsonObject(
          jsonDecode(
            await File(
              '${staging.path}/revisions/${remapped[i].revisionId}.json',
            ).readAsString(),
          ),
        );
        if (jsonEncode(actual) != jsonEncode(manifests[i]))
          throw const FormatException('Clone manifest verification failed');
      }
      if (jsonEncode(
            jsonDecode(await File('${staging.path}/vault.json').readAsString()),
          ) !=
          jsonEncode(config))
        throw const FormatException('Clone configuration verification failed');
      final currentType = await _requireEmptyCloneDestination(target);
      if (currentType != originalTargetType)
        throw FileSystemException('Clone destination changed', target.path);
      if (_directoryKey(Directory(await staging.resolveSymbolicLinks())) !=
          stagingKey)
        throw const FormatException('Clone staging path changed');
      if (currentType == FileSystemEntityType.directory) {
        await target.delete();
        removedEmptyDestination = true;
      }
      await staging.rename(target.path);
      created = false;
      final clone = NoteRepository._(
        target.absolute,
        newVaultId,
        newDeviceId,
        targetFormat,
      );
      clone._records.addEntries(
        remapped.map((record) => MapEntry(record.revisionId, record)),
      );
      clone._active.addAll(clone._records);
      clone._validatedBlobLengths.addAll(lengths);
      return clone;
    } catch (error, stack) {
      try {
        if (removedEmptyDestination &&
            await FileSystemEntity.type(target.path, followLinks: false) ==
                FileSystemEntityType.notFound)
          await target.create();
      } catch (_) {}
      try {
        if (created &&
            await FileSystemEntity.type(staging.path, followLinks: false) ==
                FileSystemEntityType.directory &&
            _directoryKey(Directory(await staging.resolveSymbolicLinks())) ==
                stagingKey)
          await staging.delete(recursive: true);
      } catch (_) {}
      Error.throwWithStackTrace(error, stack);
    }
  });

  void _validateGraph(RevisionRecord r) {
    if (r.formatVersion > formatVersion) {
      throw const FormatException('Revision requires a newer vault format');
    }
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
    Map<String, Uint8List> bytesByHash, {
    bool restoreMissingManifest = false,
    void Function()? beforeManifestRename,
  }) async {
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
    if (existing == null || restoreMissingManifest) {
      await _atomicWrite(
        File('${root.path}/revisions/${r.revisionId}.json'),
        utf8.encode(jsonEncode(r.toJson())),
        beforeRename: beforeManifestRename,
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
              await _streamVerifiedBlob(
                File('${root.path}/blobs/${ref.hash}'),
                ref.hash,
                null,
              );
          _validatedBlobLengths[ref.hash] = length;
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

void _requireRecoveryFields(Map<String, dynamic> value, Set<String> fields) {
  if (value.length != fields.length || !value.keys.every(fields.contains))
    throw const FormatException('Invalid prepared recovery fields');
}

List<RevisionRecord> _orderedCloneRecords(
  List<RevisionRecord> records,
  String vaultId,
  int formatVersion,
) {
  final byId = <String, RevisionRecord>{};
  final entities = <String, RevisionRecord>{};
  for (final record in records) {
    RevisionRecord.fromJson(record.toJson());
    if (record.vaultId != vaultId ||
        record.formatVersion > formatVersion ||
        byId.containsKey(record.revisionId))
      throw const FormatException('Invalid clone revision identity');
    final entity = entities[record.entityId];
    if (entity != null &&
        (entity.kind != record.kind ||
            entity.ownerNoteId != record.ownerNoteId))
      throw const FormatException('Conflicting clone entity identity');
    byId[record.revisionId] = record;
    entities[record.entityId] = record;
  }
  final children = <String, List<String>>{};
  final remaining = <String, int>{};
  final ready = Queue<RevisionRecord>();
  for (final record in records) {
    remaining[record.revisionId] = record.parentRevisionIds.length;
    for (final id in record.parentRevisionIds) {
      final parent = byId[id];
      if (parent == null ||
          parent.entityId != record.entityId ||
          parent.kind != record.kind ||
          parent.ownerNoteId != record.ownerNoteId)
        throw const FormatException('Missing or foreign clone parent');
      children.putIfAbsent(id, () => []).add(record.revisionId);
    }
    if (record.parentRevisionIds.isEmpty) ready.add(record);
  }
  final ordered = <RevisionRecord>[];
  while (ready.isNotEmpty) {
    final record = ready.removeFirst();
    ordered.add(record);
    for (final id in children[record.revisionId] ?? const <String>[]) {
      remaining[id] = remaining[id]! - 1;
      if (remaining[id] == 0) ready.add(byId[id]!);
    }
  }
  if (ordered.length != records.length)
    throw const FormatException('Cyclic clone ancestry');
  return ordered;
}

String _directoryKey(Directory directory) {
  final uri = directory.absolute.uri.normalizePath().toString();
  return Platform.isWindows ? uri.toLowerCase() : uri;
}

Future<Directory> _resolvedCloneDestination(Directory destination) async {
  var existing = Directory.fromUri(destination.absolute.uri.normalizePath());
  final missing = <String>[];
  while (await FileSystemEntity.type(existing.path, followLinks: false) ==
      FileSystemEntityType.notFound) {
    final parent = existing.parent;
    if (_directoryKey(parent) == _directoryKey(existing))
      throw FileSystemException('Clone parent is unavailable', existing.path);
    missing.add(
      existing.uri.pathSegments.where((part) => part.isNotEmpty).last,
    );
    existing = parent;
  }
  if (await FileSystemEntity.type(existing.path, followLinks: false) ==
      FileSystemEntityType.file)
    throw FileSystemException('Clone parent is not a directory', existing.path);
  if (missing.isEmpty &&
      await FileSystemEntity.type(existing.path, followLinks: false) ==
          FileSystemEntityType.link)
    throw FileSystemException(
      'Clone destination must not be a link',
      existing.path,
    );
  var resolved = Directory(await existing.resolveSymbolicLinks());
  for (final name in missing.reversed) {
    resolved = Directory('${resolved.path}${Platform.pathSeparator}$name');
  }
  return resolved;
}

Future<FileSystemEntityType> _requireEmptyCloneDestination(
  Directory target,
) async {
  final type = await FileSystemEntity.type(target.path, followLinks: false);
  if (type != FileSystemEntityType.notFound &&
      (type != FileSystemEntityType.directory ||
          !await target.list(followLinks: false).isEmpty))
    throw FileSystemException('Clone destination must be empty', target.path);
  return type;
}

final class _BlobDigest implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

Future<int> _streamVerifiedBlob(
  File source,
  String hash,
  int? expectedLength, {
  File? destination,
}) async {
  validateHash(hash);
  if (await FileSystemEntity.type(source.path, followLinks: false) !=
      FileSystemEntityType.file)
    throw FileSystemException('Blob must be a regular file', source.path);
  final digest = _BlobDigest();
  final conversion = sha256.startChunkedConversion(digest);
  final input = await source.open();
  RandomAccessFile? output;
  var length = 0;
  Object? firstError;
  StackTrace? firstStack;
  try {
    if (destination != null)
      output = await destination.open(mode: FileMode.write);
    final buffer = Uint8List(1024 * 1024);
    while (true) {
      final read = await input.readInto(buffer);
      if (read == 0) break;
      length += read;
      if (expectedLength != null && length > expectedLength)
        throw const FormatException('Blob length mismatch');
      conversion.add(Uint8List.sublistView(buffer, 0, read));
      if (output != null) await output.writeFrom(buffer, 0, read);
    }
    conversion.close();
    if (expectedLength != null && length != expectedLength ||
        digest.value.toString() != hash)
      throw const FormatException('Blob hash or length mismatch');
    await output?.flush();
  } catch (error, stack) {
    firstError = error;
    firstStack = stack;
  }
  for (final file in [output, input]) {
    try {
      await file?.close();
    } catch (error, stack) {
      firstError ??= error;
      firstStack ??= stack;
    }
  }
  if (firstError != null) Error.throwWithStackTrace(firstError, firstStack!);
  return length;
}

Future<void> _atomicWrite(
  File target,
  List<int> bytes, {
  void Function()? beforeRename,
}) async {
  final temp = File('${target.path}.${newId()}.tmp');
  try {
    await temp.writeAsBytes(bytes, flush: true);
    beforeRename?.call();
    await temp.rename(target.path);
  } catch (error, stack) {
    try {
      if (await temp.exists()) await temp.delete();
    } catch (_) {}
    Error.throwWithStackTrace(error, stack);
  }
}
