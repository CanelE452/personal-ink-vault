import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/native/ink_vault_native.dart';
import 'package:saber/data/vault/database_actions.dart';
import 'package:saber/data/vault/workspace_database.dart';
import 'package:saber/data/vault/workspace_store.dart';

class DatabaseAutomationPlan {
  const new({
    required this.repository,
    required this.note,
    required this.inputRevision,
    required this.files,
    required this.database,
    required this.activity,
    required this.isCurrent,
    required this.capturedAtUtcMs,
    required this.events,
    required this.receipts,
    this.folderHeads = const {},
  });
  final NoteRepository repository;
  final VaultNote note;
  final RevisionRecord inputRevision;
  final Map<String, Uint8List> files;
  final WorkspaceDatabase database;
  final Object activity;
  final bool Function() isCurrent;
  final int capturedAtUtcMs;
  final int events;
  final int receipts;
  final Map<String, String> folderHeads;
}

class DatabaseAutomationCommit {
  const new(this.status, {this.revisionId});
  final String status;
  final String? revisionId;
}

class DatabaseAutomationOutcome {
  const new(
    this.noteId,
    this.status, {
    this.code,
    this.events = 0,
    this.receipts = 0,
    this.hasMore = false,
  });
  final String noteId;
  final String status;
  final String? code;
  final int events;
  final int receipts;
  final bool hasMore;
  Map<String, Object?> toJson() => {
    'noteId': noteId,
    'status': status,
    'code': ?code,
    'events': events,
    'receipts': receipts,
    'hasMore': hasMore,
  };
}

class DatabaseAutomationPass {
  const new(this.capturedAtUtcMs, this.status, this.outcomes);
  final int capturedAtUtcMs;
  final String status;
  final List<DatabaseAutomationOutcome> outcomes;
  int get committedNotes =>
      outcomes.where((outcome) => outcome.status == 'committed').length;
  int get failedNotes =>
      outcomes.where((outcome) => outcome.status == 'error').length;
  Map<String, Object?> toJson() => {
    'capturedAtUtcMs': capturedAtUtcMs,
    'status': status,
    'committedNotes': committedNotes,
    'failedNotes': failedNotes,
    'outcomes': [for (final outcome in outcomes) outcome.toJson()],
  };
}

class DatabaseAutomationCoordinator {
  new({
    required this.repository,
    required this.runtimeFor,
    required this.captureActivity,
    required this.commit,
    this.canRun,
    DateTime Function()? clock,
    this.interval = const Duration(minutes: 1),
    this.maxNotes = 16,
    this.maxPagesPerNote = 4,
    this.maxEventsPerPass = 64,
  }) : clock = clock ?? DateTime.now {
    if (maxNotes < 1 ||
        maxNotes > 64 ||
        maxPagesPerNote < 1 ||
        maxPagesPerNote > 16 ||
        maxEventsPerPass < 32 ||
        maxEventsPerPass > 256 ||
        maxEventsPerPass % 32 != 0 ||
        interval <= Duration.zero)
      throw ArgumentError('Invalid automation runner limits');
  }
  final NoteRepository Function() repository;
  final DatabaseActionRuntime? Function(NoteRepository) runtimeFor;
  final Object? Function() captureActivity;
  final Future<DatabaseAutomationCommit> Function(DatabaseAutomationPlan)
  commit;
  final bool Function()? canRun;
  final DateTime Function() clock;
  final Duration interval;
  final int maxNotes;
  final int maxPagesPerNote;
  final int maxEventsPerPass;
  DatabaseAutomationPass? lastPass;
  bool get isDisposed => _disposed;
  Future<DatabaseAutomationPass>? _job;
  Timer? _timer;
  var _enabled = true, _disposed = false, _rerun = false;
  var _epoch = 0;
  NoteRepository? _cursorRepository;
  String? _afterNoteId;

  Future<DatabaseAutomationPass> runOnce({int? capturedAtUtcMs}) {
    final current = _job;
    if (current != null) return current;
    final reportRepository = repository(), reportEpoch = _epoch;
    final captured = capturedAtUtcMs ?? clock().toUtc().millisecondsSinceEpoch;
    late Future<DatabaseAutomationPass> tracked;
    tracked = _run(captured)
        .then((result) {
          if (!_disposed &&
              _epoch == reportEpoch &&
              identical(repository(), reportRepository))
            lastPass = result;
          return result;
        })
        .whenComplete(() {
          if (identical(_job, tracked)) _job = null;
          if (_rerun && _enabled && !_disposed) {
            _rerun = false;
            unawaited(runOnce());
          }
        });
    _job = tracked;
    return tracked;
  }

  bool _valid(NoteRepository repo, int epoch) =>
      !_disposed &&
      _enabled &&
      epoch == _epoch &&
      identical(repository(), repo) &&
      (canRun?.call() ?? true);
  bool _sameActivity(NoteRepository repo, int epoch, Object activity) =>
      _valid(repo, epoch) && captureActivity() == activity;

  Future<DatabaseAutomationPass> _run(int captured) async {
    final repo = repository(), epoch = _epoch;
    final outcomes = <DatabaseAutomationOutcome>[];
    if (!_valid(repo, epoch) || captureActivity() == null)
      return DatabaseAutomationPass(captured, 'deferred', const []);
    if (repo.formatVersion < 2)
      return DatabaseAutomationPass(captured, 'unsupported_vault', const []);
    final runtime = runtimeFor(repo);
    if (runtime == null || runtime.deviceId != repo.deviceId)
      return DatabaseAutomationPass(captured, 'unavailable', const []);
    try {
      if (!identical(_cursorRepository, repo)) {
        _cursorRepository = repo;
        _afterNoteId = await _loadNoteCursor(repo);
      }
      final candidates =
          (await repo.revisions())
              .where(
                (r) =>
                    r.kind == EntityKind.metadata &&
                    r.blobs.containsKey('note.json'),
              )
              .map((r) => r.entityId)
              .toSet()
              .toList()
            ..sort();
      final ordered = [
        ...candidates.where(
          (id) => _afterNoteId == null || id.compareTo(_afterNoteId!) > 0,
        ),
        if (_afterNoteId != null)
          ...candidates.where((id) => id.compareTo(_afterNoteId!) <= 0),
      ];
      var remaining = maxEventsPerPass, notes = 0;
      for (final id in ordered.take(256)) {
        if (!_valid(repo, epoch) || remaining < 32 || notes >= maxNotes) break;
        final activity = captureActivity();
        if (activity == null) break;
        try {
          final heads = await repo.heads(id);
          if (heads.length != 1 || heads.single.deleted) {
            _afterNoteId = id;
            continue;
          }
          final metadata = heads.single;
          final bytes = (await repo.readFiles(metadata))['note.json'];
          if (bytes == null)
            throw const FormatException('Missing note metadata');
          final json = jsonObject(jsonDecode(utf8.decode(bytes)));
          if (json['documentKind'] != 'database') {
            _afterNoteId = id;
            continue;
          }
          notes++;
          final note = _note(metadata, json);
          final folders = await _folders(repo, note.folderId);
          final result = await _execute(
            repo,
            epoch,
            activity,
            note,
            folders,
            runtime,
            captured,
            remaining,
          );
          outcomes.add(result);
          remaining -= result.events;
          _afterNoteId = id;
        } catch (error) {
          outcomes.add(
            DatabaseAutomationOutcome(id, 'error', code: _code(error)),
          );
          _afterNoteId = id;
        }
      }
      final result = DatabaseAutomationPass(
        captured,
        _valid(repo, epoch) && captureActivity() != null
            ? 'completed'
            : 'deferred',
        List.unmodifiable(outcomes),
      );
      if (_valid(repo, epoch)) {
        try {
          await _write(repo, _runnerFile(repo), {
            'version': 1,
            'vaultId': repo.vaultId,
            'deviceId': repo.deviceId,
            'afterNoteId': _afterNoteId,
            'lastPass': {
              ...result.toJson(),
              'outcomes': outcomes.take(32).map((r) => r.toJson()).toList(),
            },
          }, epoch);
        } catch (_) {
          /* The canonical receipt is independent of runner diagnostics. */
        }
      }
      return result;
    } catch (error) {
      return DatabaseAutomationPass(captured, 'error', [
        ...outcomes,
        DatabaseAutomationOutcome(repo.vaultId, 'error', code: _code(error)),
      ]);
    }
  }

  Future<DatabaseAutomationOutcome> _execute(
    NoteRepository repo,
    int epoch,
    Object activity,
    VaultNote note,
    Map<String, String> folders,
    DatabaseActionRuntime runtime,
    int captured,
    int remaining,
  ) async {
    final heads = await repo.heads(note.inkEntityId);
    if (heads.length != 1 || heads.single.deleted)
      return DatabaseAutomationOutcome(note.id, 'conflict');
    final input = heads.single;
    if (input.kind != EntityKind.ink ||
        input.ownerNoteId != note.id ||
        input.vaultId != repo.vaultId)
      throw const FormatException('Foreign database snapshot');
    final files = await repo.readFiles(input);
    final bytes = files['database.json'];
    if (bytes == null) throw const FormatException('Missing database body');
    final base = WorkspaceDatabase.fromJson(
      jsonObject(jsonDecode(utf8.decode(bytes))),
    );
    final rules = runtime.rules(base);
    if (!rules.any(
      (rule) =>
          rule['enabled'] != false &&
          (rule['trigger'] as Map?)?['type'] == 'schedule',
    ))
      return DatabaseAutomationOutcome(note.id, 'unchanged');
    final digest = sha256
        .convert(utf8.encode(jsonEncode(_canonical(rules))))
        .toString();
    var checkpoint = await _loadCheckpoint(repo, note, input, digest, captured);
    var working = base, events = 0, receiptCount = 0, changed = false;
    var cursor = checkpoint.cursor, more = true;
    final cutoff = checkpoint.cutoff ?? captured,
        since = checkpoint.since ?? checkpoint.horizon;
    for (
      var page = 0;
      page < maxPagesPerNote && remaining - events >= 32;
      page++
    ) {
      if (!_sameActivity(repo, epoch, activity))
        return DatabaseAutomationOutcome(note.id, 'stale', hasMore: true);
      final due = runtime.due(
        base,
        capturedAtUtcMs: cutoff,
        cursor: cursor,
        sinceUtcMs: since,
      );
      for (final entry in due.events) {
        final prepared = runtime.prepare(
          working,
          event: Map<String, dynamic>.from(entry['event'] as Map),
          ruleId: entry['ruleId'] as String,
          inputRevision: input.revisionId,
          capturedAtUtcMs: captured,
        );
        working = prepared.database;
        events++;
        receiptCount += prepared.receipts.length;
        changed = changed || prepared.changed;
      }
      more = due.hasMore;
      if (more &&
          jsonEncode(_canonical(cursor)) == jsonEncode(_canonical(due.cursor)))
        throw const DatabaseActionException(
          'stalled_cursor',
          '일정 검색이 진행되지 않았습니다.',
        );
      cursor = due.cursor;
      if (!more) break;
    }
    if (!_sameActivity(repo, epoch, activity))
      return DatabaseAutomationOutcome(note.id, 'stale', hasMore: true);
    String revisionId = input.revisionId;
    if (changed) {
      final result = await commit(
        DatabaseAutomationPlan(
          repository: repo,
          note: note,
          inputRevision: input,
          files: Map.unmodifiable({
            for (final entry in files.entries)
              entry.key: Uint8List.fromList(entry.value).asUnmodifiableView(),
          }),
          database: working,
          activity: activity,
          isCurrent: () => _valid(repo, epoch),
          capturedAtUtcMs: captured,
          events: events,
          receipts: receiptCount,
          folderHeads: Map.unmodifiable(folders),
        ),
      );
      if (result.status != 'committed')
        return DatabaseAutomationOutcome(
          note.id,
          result.status,
          events: result.status == 'conflict' ? events : 0,
          receipts: result.status == 'conflict' ? receiptCount : 0,
          hasMore: true,
        );
      revisionId = result.revisionId!;
    }
    if (!_valid(repo, epoch) || captureActivity() == null)
      return DatabaseAutomationOutcome(
        note.id,
        changed ? 'committed' : 'stale',
        events: changed ? events : 0,
        receipts: changed ? receiptCount : 0,
        hasMore: true,
      );
    checkpoint = _AutomationCheckpoint(
      note.revision.revisionId,
      revisionId,
      digest,
      horizon: more ? checkpoint.horizon : cutoff,
      cutoff: more ? cutoff : null,
      since: more ? since : null,
      cursor: more ? cursor : null,
    );
    String? code;
    try {
      await _write(
        repo,
        _checkpointFile(repo, note.id),
        checkpoint.json(repo, note.id),
        epoch,
      );
    } catch (_) {
      code = 'checkpoint_write_failed';
    }
    return DatabaseAutomationOutcome(
      note.id,
      changed ? 'committed' : 'unchanged',
      code: code,
      events: events,
      receipts: receiptCount,
      hasMore: more || code != null,
    );
  }

  static VaultNote _note(RevisionRecord record, Map<String, dynamic> json) {
    String id(String key) {
      final value = json[key];
      if (value is! String)
        throw const FormatException('Invalid database note');
      validateId(value);
      return value;
    }

    String? optionalId(String key) => json[key] == null ? null : id(key);
    if (json['title'] is! String)
      throw const FormatException('Invalid database title');
    return VaultNote(
      record.entityId,
      json['title'] as String,
      id('inkEntityId'),
      id('markdownEntityId'),
      record,
      folderId: optionalId('folderId'),
      sourceEntityId: optionalId('sourceEntityId'),
      documentKind: VaultDocumentKind.database,
      metadata: json,
    );
  }

  static Future<Map<String, String>> _folders(
    NoteRepository repo,
    String? folderId,
  ) async {
    final result = <String, String>{};
    while (folderId != null) {
      if (result.length >= 64 || result.containsKey(folderId))
        throw const FormatException('Invalid folder hierarchy');
      final heads = await repo.heads(folderId);
      if (heads.length != 1 ||
          heads.single.deleted ||
          heads.single.kind != EntityKind.folder)
        throw const DatabaseActionException(
          'folder_unavailable',
          '보관되었거나 충돌한 폴더의 일정은 실행하지 않습니다.',
        );
      final folder = heads.single;
      final bytes = (await repo.readFiles(folder))['folder.json'];
      if (bytes == null) throw const FormatException('Missing folder');
      final json = jsonObject(jsonDecode(utf8.decode(bytes)));
      result[folderId] = folder.revisionId;
      final parent = json['parentId'];
      if (parent != null) {
        if (parent is! String) throw const FormatException('Invalid parent');
        validateId(parent);
      }
      folderId = parent as String?;
    }
    return result;
  }

  File _runnerFile(NoteRepository repo) =>
      File('${repo.root.path}/.workspace/automation-runner/state.json');
  File _checkpointFile(NoteRepository repo, String noteId) =>
      File('${repo.root.path}/.workspace/automation-runner/notes/$noteId.json');
  Future<Map<String, dynamic>?> _read(NoteRepository repo, File file) async {
    if (!file.existsSync() || file.lengthSync() > 16384) return null;
    try {
      final json = jsonObject(jsonDecode(await file.readAsString()));
      if (json['version'] != 1 ||
          json['vaultId'] != repo.vaultId ||
          json['deviceId'] != repo.deviceId)
        return null;
      return json;
    } catch (_) {
      return null;
    }
  }

  Future<String?> _loadNoteCursor(NoteRepository repo) async {
    final state = await _read(repo, _runnerFile(repo));
    final value = state?['afterNoteId'];
    if (value is! String) return null;
    try {
      validateId(value);
      return value;
    } catch (_) {
      return null;
    }
  }

  Future<_AutomationCheckpoint> _loadCheckpoint(
    NoteRepository repo,
    VaultNote note,
    RevisionRecord input,
    String rules,
    int captured,
  ) async {
    final fallback = _AutomationCheckpoint(
      note.revision.revisionId,
      input.revisionId,
      rules,
    );
    final json = await _read(repo, _checkpointFile(repo, note.id));
    if (json == null ||
        json['noteId'] != note.id ||
        json['metadataRevisionId'] != note.revision.revisionId ||
        json['inkRevisionId'] != input.revisionId ||
        json['rulesDigest'] != rules)
      return fallback;
    final horizon = json['horizonUtcMs'],
        cutoff = json['scanCutoffUtcMs'],
        since = json['sinceUtcMs'];
    final earliest = DateTime.utc(0).millisecondsSinceEpoch;
    final latest = DateTime.utc(10000).millisecondsSinceEpoch - 1;
    if ([horizon, cutoff, since].any(
          (value) =>
              value != null &&
              (value is! int ||
                  value < earliest ||
                  value > latest ||
                  value > captured),
        ) ||
        cutoff != null && since != null && (since as int) > (cutoff as int) ||
        json['cursor'] != null && json['cursor'] is! Map)
      return fallback;
    return _AutomationCheckpoint(
      note.revision.revisionId,
      input.revisionId,
      rules,
      horizon: horizon as int?,
      cutoff: cutoff as int?,
      since: since as int?,
      cursor: json['cursor'] == null
          ? null
          : Map<String, dynamic>.from(json['cursor'] as Map),
    );
  }

  Future<void> _write(
    NoteRepository repo,
    File target,
    Map<String, Object?> value,
    int epoch,
  ) async {
    if (!_valid(repo, epoch)) return;
    final bytes = utf8.encode(jsonEncode(value));
    if (bytes.length > 16384)
      throw const FormatException('Runner state exceeds its bound');
    await target.parent.create(recursive: true);
    final pending = File('${target.path}.${newId()}.pending');
    try {
      await pending.writeAsBytes(bytes, flush: true);
      if (_valid(repo, epoch)) await pending.rename(target.path);
    } finally {
      if (pending.existsSync()) await pending.delete();
    }
  }

  static Object? _canonical(Object? value) => value is Map
      ? SplayTreeMap<String, Object?>.from({
          for (final key in value.keys) key as String: _canonical(value[key]),
        })
      : value is List
      ? [for (final item in value) _canonical(item)]
      : value;
  static String _code(Object error) => error is DatabaseActionException
      ? error.code
      : error is InkVaultNativeException
      ? error.code
      : error is FileSystemException
      ? 'storage_error'
      : error is FormatException
      ? 'invalid_database'
      : 'automation_error';

  void start() {
    if (_disposed) return;
    _enabled = true;
    _timer ??= Timer.periodic(interval, (_) => unawaited(runOnce()));
    if (_job != null) _rerun = true;
    unawaited(runOnce());
  }

  void resume() {
    _epoch++;
    start();
  }

  void pause() {
    _enabled = false;
    _epoch++;
    _rerun = false;
    _timer?.cancel();
    _timer = null;
  }

  void invalidate() {
    _epoch++;
    lastPass = null;
    _cursorRepository = null;
    if (_job != null)
      _rerun = true;
    else if (_enabled && !_disposed)
      unawaited(runOnce());
  }

  void dispose() {
    pause();
    _disposed = true;
  }
}

class _AutomationCheckpoint {
  const new(
    this.metadata,
    this.ink,
    this.rules, {
    this.horizon,
    this.cutoff,
    this.since,
    this.cursor,
  });
  final String metadata, ink, rules;
  final int? horizon, cutoff, since;
  final Map<String, dynamic>? cursor;
  Map<String, Object?> json(NoteRepository repo, String noteId) => {
    'version': 1,
    'vaultId': repo.vaultId,
    'deviceId': repo.deviceId,
    'noteId': noteId,
    'metadataRevisionId': metadata,
    'inkRevisionId': ink,
    'rulesDigest': rules,
    'horizonUtcMs': horizon,
    'scanCutoffUtcMs': cutoff,
    'sinceUtcMs': since,
    'cursor': cursor,
  };
}
