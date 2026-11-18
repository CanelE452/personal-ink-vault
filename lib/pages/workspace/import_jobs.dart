import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:ink_vault_core/ink_vault_core.dart' show newId;
import 'package:saber/data/user_error.dart';
import 'package:saber/data/vault/workspace_store.dart' show VaultNote;

/// Reads the file of an import: it reports how much of the file it has read
/// (0..1) and stops early once [cancelled] says so.
typedef ImportRead =
    Future<Uint8List> Function(
      void Function(double) progress,
      bool Function() cancelled,
    );

/// The message of a finished import: 「‘제목’을 가져왔습니다」, with 를 after a Hangul syllable
/// without a final consonant. A title that does not end in a Hangul syllable gets
/// 「‘제목’ 가져오기를 마쳤습니다」.
String importDoneMessage(String title) {
  final last = title.runes.isEmpty ? null : title.runes.last;
  if (last == null || last < 0xAC00 || last > 0xD7A3) {
    return '‘$title’ 가져오기를 마쳤습니다';
  }
  final particle = (last - 0xAC00) % 28 == 0 ? '를' : '을';
  return '‘$title’$particle 가져왔습니다';
}

/// An import on its way into the vault, as its library card shows it.
final class ImportJob {
  const new({
    required this.id,
    required this.title,
    required this.folderId,
    this.progress,
    this.error,
    this.writing = false,
  });

  final String id;
  final String title;

  /// The folder it goes into; null is the top of the library.
  final String? folderId;

  /// 0..1, or null while the size of the file is not known.
  final double? progress;

  /// Why it failed; its card stays until it is closed.
  final String? error;

  /// Its original is being stored in the vault.
  final bool writing;
}

/// Imports that run beside the library (설계 4절). Each reads its file (the
/// bar's first 85 %), then stores it in the vault, one import at a time (the
/// bar stays at 85 %), and leaves the list. A finished import opens nothing:
/// [start]'s `done` hears of it.
class ImportJobs extends ChangeNotifier {
  new({required this.trash});

  /// Sends a document to the trash: an import cancelled while it was being
  /// stored goes there once it is stored.
  final Future<void> Function(VaultNote note) trash;

  static const _readShare = 0.85;

  /// Running and failed imports, oldest first. Cancelling one removes it.
  final _jobs = <String, ImportJob>{};

  /// Imports cancelled with × while they were stored: their documents go to
  /// the trash once stored.
  final _trashWhenStored = <String>{};
  var _writes = Future<void>.value();

  List<ImportJob> get jobs => List.unmodifiable(_jobs.values);

  /// Starts importing [title] into [folderId] and returns the import's id.
  /// [read] gets the file; [write] stores it and returns the new document.
  String start({
    required String title,
    required String? folderId,
    required ImportRead read,
    required Future<VaultNote> Function(Uint8List bytes) write,
    void Function(VaultNote note)? done,
  }) {
    final id = newId();
    _jobs[id] = ImportJob(id: id, title: title, folderId: folderId);
    notifyListeners();
    unawaited(_run(id, read, write, done));
    return id;
  }

  /// Cancels an import: before it is stored nothing is written; while it is
  /// stored, the document goes to the trash once it is. A failed import's
  /// card closes.
  void cancel(String id) {
    final job = _jobs.remove(id);
    if (job == null) return;
    if (job.writing) _trashWhenStored.add(id);
    notifyListeners();
  }

  /// Closes the card of a failed import.
  void dismiss(String id) {
    if (_jobs[id]?.error != null) cancel(id);
  }

  /// Cancels every import, for another vault or a closed screen. An import
  /// being stored finishes and stays in the vault it went into; nobody asked
  /// to throw it away.
  void cancelAll() {
    if (_jobs.isEmpty) return;
    _jobs.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    _jobs.clear();
    super.dispose();
  }

  Future<void> _run(
    String id,
    ImportRead read,
    Future<VaultNote> Function(Uint8List bytes) write,
    void Function(VaultNote note)? done,
  ) async {
    bool cancelled() => !_jobs.containsKey(id);
    final VaultNote? note;
    try {
      final bytes = await read((fraction) => _progress(id, fraction), cancelled);
      if (cancelled()) return;
      _update(id, progress: _readShare);
      note = await _inTurn(() async {
        if (cancelled()) return null;
        _update(id, writing: true);
        return write(bytes);
      });
    } catch (error, stack) {
      _trashWhenStored.remove(id);
      if (cancelled()) return;
      logUserError(error, stack);
      _update(id, error: userErrorMessage(error), writing: false);
      return;
    }
    if (note == null) return;
    if (cancelled()) {
      if (!_trashWhenStored.remove(id)) return;
      try {
        await trash(note);
      } catch (error, stack) {
        logUserError(error, stack);
      }
      return;
    }
    _jobs.remove(id);
    notifyListeners();
    done?.call(note);
  }

  /// Runs [write] once the imports stored before it are done.
  Future<T> _inTurn<T>(Future<T> Function() write) {
    final result = _writes.then((_) => write());
    _writes = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  void _progress(String id, double fraction) {
    final job = _jobs[id];
    if (job == null || job.writing) return;
    final shown = job.progress;
    final progress = fraction.clamp(0.0, 1.0) * _readShare;
    _jobs[id] = _copy(job, progress: progress);
    // The card shows whole percents; a chunk that does not change them waits.
    if (shown == null || (shown * 100).round() != (progress * 100).round()) {
      notifyListeners();
    }
  }

  void _update(String id, {double? progress, String? error, bool? writing}) {
    final job = _jobs[id];
    if (job == null) return;
    _jobs[id] = _copy(job, progress: progress, error: error, writing: writing);
    notifyListeners();
  }

  static ImportJob _copy(
    ImportJob job, {
    double? progress,
    String? error,
    bool? writing,
  }) => ImportJob(
    id: job.id,
    title: job.title,
    folderId: job.folderId,
    progress: progress ?? job.progress,
    error: error ?? job.error,
    writing: writing ?? job.writing,
  );
}
