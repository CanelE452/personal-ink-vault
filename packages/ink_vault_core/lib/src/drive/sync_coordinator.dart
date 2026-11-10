import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:ink_vault_core/src/drive/remote_store.dart';
import 'package:ink_vault_core/src/repository.dart';
import 'package:ink_vault_core/src/revision.dart';

enum SyncPhase {
  idle,
  pending,
  syncing,
  synced,
  conflict,
  retryWaiting,
  authenticationRequired,
  error,
  closed,
}

class SyncStatus {
  final SyncPhase phase;
  final int pendingUploads;
  final int pendingDownloads;
  final String? message;
  final DateTime? retryAt;
  final DateTime? lastSuccessfulSync;
  const SyncStatus(
    this.phase, {
    this.pendingUploads = 0,
    this.pendingDownloads = 0,
    this.message,
    this.retryAt,
    this.lastSuccessfulSync,
  });
}

typedef _PersistedSyncState = ({
  List<String> uploaded,
  List<String> pending,
  Map<String, String> intents,
  Map<String, String> knownFiles,
  List<String> removedFiles,
  String? cursor,
  int attempts,
  DateTime? retryAt,
  DateTime? lastSuccess,
  bool authStopped,
  bool blocked,
});

/// One coordinator per state directory. Keep this directory device-local, outside
/// backups and Drive. State is reconstructible; immutable repository data is not.
/// The caller owns and closes the repository and remote transport separately.
class SyncCoordinator {
  final NoteRepository repository;
  final RemoteStore remote;
  final Directory stateDirectory;
  final Duration debounce;
  final Duration pollInterval;
  final _statuses = StreamController<SyncStatus>.broadcast();
  SyncStatus _status = const SyncStatus(SyncPhase.idle);
  SyncStatus get status => _status;
  Stream<SyncStatus> get statuses => _statuses.stream;
  final _uploaded = <String>{};
  final _intents = <String, String>{};
  final _pending = <String>{};
  final _knownFiles = <String, String>{};
  final _removedFiles = <String>{};
  String? _cursor;
  DateTime? _retryAt, _lastSuccess;
  int _attempts = 0;
  bool _loaded = false, _closed = false, _started = false;
  bool _authStopped = false, _blocked = false, _resumeRequested = false;
  Future<void>? _inFlight;
  StreamSubscription<void>? _subscription;
  Timer? _debounceTimer, _pollTimer;

  SyncCoordinator({
    required this.repository,
    required this.remote,
    required this.stateDirectory,
    this.debounce = const Duration(milliseconds: 700),
    this.pollInterval = const Duration(seconds: 15),
  }) {
    if (repository.vaultId != remote.vaultId)
      throw const FormatException('Cannot sync different vaults');
    if (debounce.isNegative || pollInterval <= Duration.zero)
      throw ArgumentError('Invalid sync timer interval');
  }
  void _emit(SyncPhase phase, {int? uploads, String? message}) {
    if (_closed && phase != SyncPhase.closed) return;
    _status = SyncStatus(
      phase,
      pendingUploads: uploads ?? _status.pendingUploads,
      pendingDownloads: _pending.length,
      message: message,
      retryAt: _retryAt,
      lastSuccessfulSync: _lastSuccess,
    );
    _statuses.add(_status);
  }

  void start() {
    if (_closed) throw StateError('Coordinator is closed');
    if (_started) return;
    _started = true;
    _subscription = repository.changes.listen((_) {
      _debounceTimer?.cancel();
      if (!_authStopped && !_blocked) _emit(SyncPhase.pending);
      _debounceTimer = Timer(debounce, () => unawaited(syncOnce()));
    });
    _pollTimer = Timer.periodic(pollInterval, (_) => unawaited(syncOnce()));
    unawaited(syncOnce());
  }

  /// Call after reauthentication, reconnecting, or repairing an explicit error.
  /// This does not itself request account consent or discard queued operations.
  void resume() {
    if (_closed) return;
    _resumeRequested = true;
    _authStopped = false;
    _blocked = false;
    _retryAt = null;
    _attempts = 0;
    if (_started) unawaited(syncOnce(force: true));
  }

  Future<void> syncOnce({bool force = false}) {
    if (_closed) return Future.value();
    final existing = _inFlight;
    if (existing != null) return existing;
    return _trackSync(_run(force: force));
  }

  /// Records a retryable remote folder check before this coordinator starts.
  /// The caller must hold the state directory lease throughout the check and save.
  Future<void> recordPreflightRetry(RemoteException failure) {
    if (failure.failure != RemoteFailure.retryable) {
      throw ArgumentError('Expected a retryable preflight failure');
    }
    if (_closed || _started || _loaded || _inFlight != null) {
      throw StateError('Preflight retry requires a fresh sync coordinator');
    }
    return _trackSync(_savePreflightRetry(failure));
  }

  Future<void> _savePreflightRetry(RemoteException failure) async {
    await _load();
    _scheduleRetry(failure);
    await _save();
  }

  Future<void> _trackSync(Future<void> future) {
    _inFlight = future;
    return future.whenComplete(() => _inFlight = null);
  }

  Future<void> _load() async {
    if (_loaded) return;
    await stateDirectory.create(recursive: true);
    final state = await _readState(
      stateDirectory,
      repository.vaultId,
      remote.remoteId,
    );
    if (state != null) {
      _uploaded.addAll(state.uploaded);
      _pending.addAll(state.pending);
      _intents.addAll(state.intents);
      _knownFiles.addAll(state.knownFiles);
      _removedFiles.addAll(state.removedFiles);
      _cursor = state.cursor;
      _attempts = state.attempts;
      _retryAt = state.retryAt;
      _lastSuccess = state.lastSuccess;
      _authStopped = state.authStopped;
      _blocked = state.blocked;
    }
    _loaded = true;
  }

  /// Checks automatic sync holds before authentication or remote preflight.
  /// The caller must already hold the lease for this state directory.
  static Future<SyncPhase?> readPersistedHold({
    required Directory stateDirectory,
    required String vaultId,
    required String remoteId,
  }) async {
    final state = await _readState(stateDirectory, vaultId, remoteId);
    if (state == null) return null;
    return _holdPhase(state.authStopped, state.blocked, state.retryAt);
  }

  static Future<_PersistedSyncState?> _readState(
    Directory directory,
    String vaultId,
    String remoteId,
  ) async {
    final file = File('${directory.path}/sync-state.json');
    final type = await FileSystemEntity.type(file.path);
    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.file) {
      throw const FormatException('Invalid sync state file');
    }
    final state = jsonObject(jsonDecode(await file.readAsString()));
    if (state['version'] != 1 ||
        state['vaultId'] != vaultId ||
        state['remoteId'] != remoteId) {
      throw const FormatException('Sync state identity mismatch');
    }
    final retryAt = state['retryAt'] as String?;
    final lastSuccess = state['lastSuccess'] as String?;
    return (
      uploaded: List<String>.from(state['uploaded'] as List<Object?>),
      pending: List<String>.from(state['pending'] as List<Object?>),
      intents: Map<String, String>.from(jsonObject(state['intents'])),
      knownFiles: Map<String, String>.from(jsonObject(state['knownFiles'])),
      removedFiles: List<String>.from(state['removedFiles'] as List<Object?>),
      cursor: state['cursor'] as String?,
      attempts: state['attempts'] as int,
      retryAt: retryAt == null ? null : DateTime.parse(retryAt),
      lastSuccess: lastSuccess == null ? null : DateTime.parse(lastSuccess),
      authStopped: state['authStopped'] as bool,
      blocked: state['blocked'] as bool,
    );
  }

  static SyncPhase? _holdPhase(
    bool authStopped,
    bool blocked,
    DateTime? retryAt, {
    bool force = false,
  }) {
    if (authStopped) return SyncPhase.authenticationRequired;
    if (blocked) return SyncPhase.error;
    if (!force && retryAt != null && DateTime.now().isBefore(retryAt)) {
      return SyncPhase.retryWaiting;
    }
    return null;
  }

  Future<void> _save() async {
    final target = File('${stateDirectory.path}/sync-state.json');
    final temp = File('${target.path}.${newId()}.tmp');
    try {
      await temp.writeAsString(
        jsonEncode({
          'version': 1,
          'vaultId': repository.vaultId,
          'remoteId': remote.remoteId,
          'uploaded': _uploaded.toList(),
          'pending': _pending.toList(),
          'intents': _intents,
          'knownFiles': _knownFiles,
          'removedFiles': _removedFiles.toList(),
          'cursor': _cursor,
          'attempts': _attempts,
          'retryAt': _retryAt?.toIso8601String(),
          'lastSuccess': _lastSuccess?.toIso8601String(),
          'authStopped': _authStopped,
          'blocked': _blocked,
        }),
        flush: true,
      );
      await temp.rename(target.path);
    } finally {
      if (await temp.exists()) await temp.delete();
    }
  }

  Future<String> _intent(String key) async {
    final existing = _intents[key];
    if (existing != null) return existing;
    final id = await remote.generateId();
    _intents[key] = id;
    await _save(); // Persist before any file creation request.
    return id;
  }

  Future<void> _push() async {
    final revisions = await repository.revisions();
    final waiting = revisions
        .where((r) => !_uploaded.contains(r.revisionId))
        .toList();
    _emit(SyncPhase.syncing, uploads: waiting.length);
    for (var i = 0; i < waiting.length; i++) {
      final record = waiting[i];
      for (final ref in record.blobs.values) {
        final key = 'blob:${ref.hash}';
        if (await remote.findBlob(ref) == null) {
          final bytes = await repository.readBlob(ref.hash);
          await remote.putBlob(ref, bytes, await _intent(key));
        }
        _intents.remove(key);
      }
      final key = 'revision:${record.revisionId}';
      final id = await _intent(key);
      await remote.publishRevision(
        record,
        id,
      ); // Immutable manifest is always last.
      _knownFiles[id] = record.revisionId;
      _uploaded.add(record.revisionId);
      _intents.remove(key);
      await _save();
      _emit(SyncPhase.syncing, uploads: waiting.length - i - 1);
    }
  }

  void _enqueue(List<RemoteChange> changes) {
    for (final change in changes) {
      if (change.removed) {
        if (_knownFiles.containsKey(change.fileId) ||
            _pending.contains(change.fileId))
          _removedFiles.add(change.fileId);
      } else {
        _pending.add(change.fileId);
      }
    }
  }

  Future<void> _fullScan() async {
    // Snapshot token first, then enumerate. Changes concurrent with enumeration
    // will still be observed by the following changes feed.
    final start = await remote.startPageToken();
    String? pageToken;
    final seen = <String>{};
    do {
      final page = await remote.listManifests(pageToken: pageToken);
      _enqueue(page.changes);
      seen.addAll(page.changes.where((c) => !c.removed).map((c) => c.fileId));
      await _save();
      pageToken = page.nextPageToken;
    } while (pageToken != null);
    _removedFiles.addAll(_knownFiles.keys.where((id) => !seen.contains(id)));
    _cursor = start;
    await _save();
  }

  Future<void> _pullChanges() async {
    if (_cursor == null) await _fullScan();
    var reset = false;
    while (true) {
      RemotePage page;
      try {
        page = await remote.readChanges(_cursor!);
      } on RemoteException catch (e) {
        if (e.failure != RemoteFailure.invalidCursor || reset) rethrow;
        reset = true;
        _cursor = null;
        await _save();
        await _fullScan();
        continue;
      }
      _enqueue(page.changes);
      final next = page.nextPageToken ?? page.newStartPageToken;
      if (next == null)
        throw const FormatException(
          'Drive change page has no continuation token',
        );
      _cursor = next;
      // Pending and cursor are committed together; missing blobs cannot be lost
      // by advancing a changes cursor or restarting this process.
      await _save();
      if (page.nextPageToken == null) break;
    }
  }

  Future<bool> _receivePending() async {
    var missing = false;
    final received = <String>{};
    for (final id in _pending.toList()) {
      try {
        final record = await remote.readManifest(id);
        if (record.vaultId != repository.vaultId)
          throw const FormatException('Foreign vault manifest');
        final knownRevision = _knownFiles[id];
        if (knownRevision != null && knownRevision != record.revisionId)
          throw const FormatException('Remote file changed revision identity');
        final blobs = <String, Uint8List>{};
        for (final ref in record.blobs.values) {
          Uint8List bytes;
          try {
            bytes = await repository.readBlob(ref.hash);
          } on FileSystemException {
            bytes = await remote.readBlob(ref);
          } on FormatException {
            bytes = await remote.readBlob(ref);
          }
          if (bytes.length != ref.length ||
              sha256.convert(bytes).toString() != ref.hash)
            throw const FormatException('Remote blob hash or length mismatch');
          blobs[ref.hash] = bytes;
        }
        await repository.importRevision(record, blobsByHash: blobs);
        _knownFiles[id] = record.revisionId;
        _uploaded.add(record.revisionId);
        received.add(id);
        await _save();
      } on RemoteException catch (e) {
        if (e.failure != RemoteFailure.missing) rethrow;
        missing = true;
      }
    }
    final active = (await repository.revisions())
        .map((r) => r.revisionId)
        .toSet();
    final completed = received.where((id) => active.contains(_knownFiles[id]));
    _removedFiles.removeAll(completed);
    _pending.removeAll(completed);
    await _save();
    return missing || _pending.isNotEmpty;
  }

  Future<bool> _hasConflicts() async {
    final records = await repository.revisions();
    final heads = <String, List<RevisionRecord>>{};
    for (final entityId in records.map((r) => r.entityId).toSet()) {
      final entityHeads = await repository.heads(entityId);
      heads[entityId] = entityHeads;
      if (entityHeads.length > 1) return true;
    }
    for (final list in heads.values) {
      for (final note in list.where(
        (r) => r.kind == EntityKind.metadata && r.deleted,
      )) {
        for (final child
            in heads.values
                .expand((r) => r)
                .where((r) => r.ownerNoteId == note.entityId)) {
          if (!(note.baseRefs[child.entityId] ?? const <String>[]).contains(
            child.revisionId,
          ))
            return true;
        }
      }
    }
    return _hasFolderConflicts(heads.values.expand((r) => r).toList());
  }

  Future<bool> _hasFolderConflicts(List<RevisionRecord> heads) async {
    final folders = {
      for (final head in heads.where((r) => r.kind == EntityKind.folder))
        head.entityId: head,
    };
    if (folders.isEmpty) return false;
    Future<String?> readParent(
      RevisionRecord record,
      String fileName,
      String key,
    ) async {
      final bytes = (await repository.readFiles(record))[fileName];
      if (bytes == null) {
        if (record.kind == EntityKind.folder)
          throw FormatException('Missing $fileName');
        return null;
      }
      final parent = jsonObject(jsonDecode(utf8.decode(bytes)))[key];
      if (parent == null) return null;
      if (parent is! String)
        throw const FormatException('Invalid folder reference');
      validateId(parent);
      return parent;
    }

    final parents = <String, String?>{};
    for (final folder in folders.values) {
      parents[folder.entityId] = await readParent(
        folder,
        'folder.json',
        'parentId',
      );
    }
    if (parents.values.any((p) => p != null && !folders.containsKey(p)))
      return true;
    final visited = <String>{};
    final visiting = <String>{};
    bool hasCycle(String id) {
      if (visited.contains(id)) return false;
      if (!visiting.add(id)) return true;
      final parent = parents[id];
      if (parent != null && hasCycle(parent)) return true;
      visiting.remove(id);
      visited.add(id);
      return false;
    }

    if (folders.keys.any(hasCycle)) return true;

    final noteFolders = <String, String?>{};
    for (final note in heads.where((r) => r.kind == EntityKind.metadata)) {
      final parent = await readParent(note, 'note.json', 'folderId');
      if (parent != null && !folders.containsKey(parent)) return true;
      noteFolders[note.entityId] = parent;
    }
    for (final deletion in folders.values.where((r) => r.deleted)) {
      final subtree = <String>{deletion.entityId};
      var changed = true;
      while (changed) {
        changed = false;
        for (final entry in parents.entries) {
          if (subtree.contains(entry.value) && subtree.add(entry.key))
            changed = true;
        }
      }
      final notes = noteFolders.entries
          .where((entry) => subtree.contains(entry.value))
          .map((entry) => entry.key)
          .toSet();
      // Only the observed subtree belongs to this tombstone. New revisions or
      // children must remain recoverable as conflicts, including source assets.
      for (final head in heads) {
        final isChildFolder =
            head.kind == EntityKind.folder &&
            head.entityId != deletion.entityId &&
            subtree.contains(head.entityId);
        if (isChildFolder ||
            notes.contains(head.entityId) ||
            notes.contains(head.ownerNoteId)) {
          if (!(deletion.baseRefs[head.entityId] ?? const <String>[]).contains(
            head.revisionId,
          )) {
            return true;
          }
        }
      }
    }
    return false;
  }

  Future<void> _run({required bool force}) async {
    try {
      await _load();
      if (_resumeRequested) {
        _authStopped = false;
        _blocked = false;
        _retryAt = null;
        _attempts = 0;
        _resumeRequested = false;
      }
      // A saved changes cursor/upload acknowledgement does not prove local
      // payloads survived. Recover known inactive revisions even without a new
      // Drive change, and persist that queue before attempting network access.
      final active = (await repository.revisions())
          .map((record) => record.revisionId)
          .toSet();
      _pending.addAll(
        _knownFiles.entries
            .where((entry) => !active.contains(entry.value))
            .map((entry) => entry.key),
      );
      _pending.addAll(_removedFiles);
      await _save();
      final hold = _holdPhase(_authStopped, _blocked, _retryAt, force: force);
      if (hold != null) {
        _emit(
          hold,
          message: switch (hold) {
            SyncPhase.authenticationRequired => 'Drive authorization required',
            SyncPhase.error => 'Repair the sync error and resume',
            _ => null,
          },
        );
        return;
      }
      _emit(SyncPhase.syncing);
      await _push();
      await _pullChanges();
      final missing = await _receivePending();
      if (_removedFiles.isNotEmpty)
        throw const RemoteException(
          RemoteFailure.permanent,
          'Drive files were removed outside the app; local revisions are preserved',
        );
      if (missing || repository.pendingRevisionCount > 0)
        throw RemoteException.retryable(
          'Waiting for referenced Drive blobs or manifests',
        );
      if (repository.integrityIssues.isNotEmpty)
        throw const FormatException(
          'Local repository integrity repair required',
        );
      _attempts = 0;
      _retryAt = null;
      _lastSuccess = DateTime.now().toUtc();
      await _save();
      _emit(
        await _hasConflicts() ? SyncPhase.conflict : SyncPhase.synced,
        uploads: 0,
      );
    } on RemoteException catch (e) {
      if (e.failure == RemoteFailure.authentication) {
        _authStopped = true;
        _emit(
          SyncPhase.authenticationRequired,
          message: 'Drive authorization required',
        );
      } else if (e.failure == RemoteFailure.retryable ||
          e.failure == RemoteFailure.missing) {
        _scheduleRetry(e);
        _emit(SyncPhase.retryWaiting, message: e.message);
      } else {
        _blocked = true;
        _emit(SyncPhase.error, message: e.message);
      }
      if (_loaded) await _saveSafely();
    } on FormatException {
      _blocked = true;
      _emit(
        SyncPhase.error,
        message: 'Sync data failed integrity validation; local revisions are preserved',
      );
      if (_loaded) await _saveSafely();
    } on FileSystemException {
      _blocked = true;
      _emit(
        SyncPhase.error,
        message: 'Cannot persist sync state or repository data',
      );
    } catch (_) {
      _blocked = true;
      _emit(
        SyncPhase.error,
        message: 'Sync failed; local revisions are preserved',
      );
      if (_loaded) await _saveSafely();
    }
  }

  void _scheduleRetry(RemoteException failure) {
    _attempts++;
    final base = min(300, 1 << min(8, _attempts));
    final delay =
        failure.retryAfter ??
        Duration(milliseconds: base * 1000 + Random.secure().nextInt(1000));
    _retryAt = DateTime.now().toUtc().add(delay);
  }

  Future<void> _saveSafely() async {
    try {
      await _save();
    } on FileSystemException {
      _emit(SyncPhase.error, message: 'Cannot persist sync state');
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _debounceTimer?.cancel();
    _pollTimer?.cancel();
    await _subscription?.cancel();
    await _inFlight;
    _emit(SyncPhase.closed);
    await _statuses.close();
  }
}
