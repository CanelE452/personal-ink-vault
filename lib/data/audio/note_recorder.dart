import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:saber/data/app_external_screen.dart';
import 'package:saber/data/audio/recording_entry.dart';

/// The microphone, behind a boundary so tests can fake it.
abstract class RecorderBackend {
  /// Asks for the microphone permission when it is not granted yet.
  Future<bool> hasPermission();

  /// Starts writing AAC-LC, mono, 48 kbps audio to [path] (an `.m4a` file).
  Future<void> start(String path);
  Future<void> pause();
  Future<void> resume();

  /// Stops and closes the file; returns its path.
  Future<String?> stop();
  Future<void> dispose();
}

/// [RecorderBackend] on the `record` plugin. The plugin object is made on first use, so building a [NoteRecorder]
/// on a platform without the plugin (the assembled Windows build) does nothing.
class RecordPluginBackend implements RecorderBackend {
  AudioRecorder? _recorder;
  AudioRecorder get _plugin => _recorder ??= AudioRecorder();

  static const config = RecordConfig(
    encoder: AudioEncoder.aacLc,
    bitRate: 48000,
    numChannels: 1,
  );

  @override
  Future<bool> hasPermission() => _plugin.hasPermission();

  @override
  Future<void> start(String path) => _plugin.start(config, path: path);

  @override
  Future<void> pause() => _plugin.pause();

  @override
  Future<void> resume() => _plugin.resume();

  @override
  Future<String?> stop() => _plugin.stop();

  @override
  Future<void> dispose() async => _recorder?.dispose();
}

enum RecorderState { idle, recording, paused, saving }

enum RecorderStartResult {
  started,

  /// The microphone permission was refused.
  permissionDenied,

  /// The recorder could not start (no plugin, microphone busy, file error).
  failed,

  /// A recording is already running or being saved.
  busy,

  /// The app went to the background while starting. Nothing was recorded, or the little that was is saved and
  /// published in [NoteRecorder.lastResult] with `leftApp`.
  cancelled,
}

/// What became of a stopped recording.
class RecordingSaveResult {
  const new({required this.noteId, this.entry, this.leftApp = false});

  final String noteId;

  /// The saved recording, or null when the save failed and the audio is kept to be saved again (see
  /// [NoteRecorder.pendingCount]).
  final RecordingEntry? entry;

  /// True when the recorder stopped because the app went to the background, so the screen can say so.
  final bool leftApp;

  bool get saved => entry != null;
}

const _systemBars = MethodChannel('personal_ink_vault/system_bars');

/// Keeps the Android screen on while recording (`FLAG_KEEP_SCREEN_ON` through `MainActivity`).
Future<void> setKeepScreenOn(bool on) async {
  if (!Platform.isAndroid) return;
  await _systemBars.invokeMethod<void>('setKeepScreenOn', on);
}

/// Records one note at a time into the app support folder (`note-recordings/`) and saves each recording as an
/// attachment of the note when it stops (through [NoteRecordings]).
///
/// Nothing recorded is dropped: the audio file and a small JSON beside it (note id, start time, length) stay in the
/// folder until the attachment write succeeds. A save that fails (note in the trash, disk full, another head) is
/// kept, counted in [pendingCount] and tried again on the next [start] (every note) and on [list] (that note). The
/// files are deleted only after the write. A recording still running or still being saved by any recorder is never
/// touched by another one's retry.
///
/// Going to the background (`hidden` or `paused`) stops and saves, also while [start] is still on its way; the result
/// carries [RecordingSaveResult.leftApp] and is published in [lastResult]. Not while a screen of the app's own is in
/// front ([AppExternalScreen.active], a file picker): that is not leaving the app, unless the app is still away
/// [AppExternalScreen.closeGrace] after that screen closes (the user went to another app from it). The caller stops the recorder
/// itself when the note closes or another note opens; [dispose] stops a running recording too.
class NoteRecorder with WidgetsBindingObserver {
  new({
    required this.recordings,
    RecorderBackend? backend,
    Future<Directory> Function()? directory,
    Duration Function()? clock,
    DateTime Function()? now,
    Future<void> Function(bool on)? keepScreenOn,
    this.beforeStart,
  }) : backend = backend ?? RecordPluginBackend(),
       _directory = directory ?? _defaultDirectory,
       _clock = clock ?? _stopwatch(),
       _now = now ?? DateTime.now,
       _keepScreenOn = keepScreenOn ?? setKeepScreenOn {
    WidgetsBinding.instance.addObserver(this);
    AppExternalScreen.open.addListener(_externalScreenChanged);
  }

  final NoteRecordings recordings;
  final RecorderBackend backend;

  /// Runs before a recording starts; the host passes the player's pause so playback stops.
  final Future<void> Function()? beforeStart;

  final Future<Directory> Function() _directory;
  final Duration Function() _clock;
  final DateTime Function() _now;
  final Future<void> Function(bool on) _keepScreenOn;
  static final _log = Logger('NoteRecorder');

  /// Captures that some recorder is recording or saving right now; every retry skips them.
  static final _busyCaptures = <String>{};

  final _state = ValueNotifier(RecorderState.idle);
  final _elapsed = ValueNotifier(Duration.zero);
  final _lastResult = ValueNotifier<RecordingSaveResult?>(null);
  final _pendingCount = ValueNotifier(0);

  ValueListenable<RecorderState> get state => _state;

  /// The recorded length so far, paused time left out; updated about every quarter second while recording.
  ValueListenable<Duration> get elapsed => _elapsed;

  /// What became of the last stopped recording, published by every [stop] (also the ones the app lifecycle makes).
  ValueListenable<RecordingSaveResult?> get lastResult => _lastResult;

  /// Recordings kept in the recording folder because their save failed; they are saved again later.
  ValueListenable<int> get pendingCount => _pendingCount;

  /// The note being recorded, or null.
  String? get noteId => _capture?.noteId;

  _Capture? _capture;
  Completer<void>? _starting;
  var _leftWhileStarting = false;
  var _disposed = false;
  Duration _recorded = Duration.zero;
  Duration? _segmentStart;
  Timer? _ticker;
  Timer? _closeGrace;
  Future<void> _saving = Future.value();
  Future<RecordingSaveResult?> _stopping = Future.value();

  static Future<Directory> _defaultDirectory() async => Directory(
    '${(await getApplicationSupportDirectory()).path}/note-recordings',
  );

  static Duration Function() _stopwatch() {
    final watch = Stopwatch()..start();
    return () => watch.elapsed;
  }

  bool get _stopRequested => _leftWhileStarting || _disposed;

  /// Starts recording [noteId]. Saves recordings left from failed saves first. Refused permission or a recorder
  /// that will not start comes back as a result, never as an exception, with the state back to idle. When the app
  /// goes to the background (or [dispose] runs) on the way, the start is given up, at the latest just before the
  /// microphone opens (nothing is kept); only when it happens while the microphone is opening is the recording
  /// stopped and saved at once. Both come back as [RecorderStartResult.cancelled].
  Future<RecorderStartResult> start(String noteId) async {
    if (_disposed || _starting != null || _state.value != RecorderState.idle) {
      return RecorderStartResult.busy;
    }
    final starting = _starting = Completer<void>();
    _leftWhileStarting = false;
    try {
      try {
        await beforeStart?.call();
      } catch (error, stack) {
        _log.warning('Could not pause playback', error, stack);
      }
      await _serial(_savePending);
      await _countPending();
      if (_stopRequested) return RecorderStartResult.cancelled;
      try {
        if (!await backend.hasPermission()) {
          return RecorderStartResult.permissionDenied;
        }
      } catch (error, stack) {
        _log.warning('Could not ask for the microphone', error, stack);
        return RecorderStartResult.failed;
      }
      if (_stopRequested) return RecorderStartResult.cancelled;
      _Capture? capture;
      Future<void> giveUp() async {
        await _screenOn(false);
        try {
          await capture?.delete();
        } on FileSystemException catch (error) {
          _log.warning('Could not remove the unused capture: $error');
        }
        _busyCaptures.remove(capture?.id);
      }

      await _screenOn(true);
      try {
        capture = _Capture(
          id: newId(),
          noteId: noteId,
          createdAt: _now().toUtc(),
          directory: await _directory(),
        );
        _busyCaptures.add(capture.id);
        await capture.directory.create(recursive: true);
        await capture.writeInfo();
        // The awaits above leave room for the app to go away: look once more before the microphone opens.
        if (_stopRequested) {
          await giveUp();
          return RecorderStartResult.cancelled;
        }
        await backend.start(capture.audio.path);
      } catch (error, stack) {
        _log.warning('Could not start recording', error, stack);
        await giveUp();
        return RecorderStartResult.failed;
      }
      _capture = capture;
      _recorded = Duration.zero;
      _segmentStart = _clock();
      _elapsed.value = Duration.zero;
      _ticker = Timer.periodic(
        const Duration(milliseconds: 250),
        (_) => _elapsed.value = _currentElapsed(),
      );
      _state.value = RecorderState.recording;
      if (_stopRequested) {
        await stop(leftApp: _leftWhileStarting);
        return RecorderStartResult.cancelled;
      }
      return RecorderStartResult.started;
    } finally {
      _starting = null;
      starting.complete();
    }
  }

  Future<void> pause() async {
    if (_state.value != RecorderState.recording) return;
    _recorded = _currentElapsed();
    _segmentStart = null;
    _elapsed.value = _recorded;
    _state.value = RecorderState.paused;
    try {
      await backend.pause();
    } catch (error, stack) {
      _log.warning('Could not pause recording', error, stack);
    }
  }

  Future<void> resume() async {
    if (_state.value != RecorderState.paused) return;
    try {
      await backend.resume();
    } catch (error, stack) {
      _log.warning('Could not resume recording', error, stack);
      return;
    }
    _segmentStart = _clock();
    _state.value = RecorderState.recording;
  }

  /// Stops and saves the recording. Returns null only when nothing was recording; a failed save comes back as a
  /// result without an entry (the audio is kept and saved later, see the class comment).
  Future<RecordingSaveResult?> stop({bool leftApp = false}) {
    final capture = _capture;
    if (capture == null ||
        (_state.value != RecorderState.recording &&
            _state.value != RecorderState.paused)) {
      return Future.value();
    }
    return _stopping = _stop(capture, leftApp);
  }

  Future<RecordingSaveResult> _stop(_Capture capture, bool leftApp) async {
    _state.value = RecorderState.saving;
    final duration = _currentElapsed();
    _ticker?.cancel();
    _ticker = null;
    _segmentStart = null;
    _elapsed.value = duration;
    final RecordingEntry? entry;
    try {
      try {
        await backend.stop();
      } catch (error, stack) {
        _log.warning('Could not stop the recorder cleanly', error, stack);
      }
      await _screenOn(false);
      _capture = null;
      capture.duration = duration;
      try {
        await capture.writeInfo();
      } catch (error, stack) {
        _log.warning('Could not note the recording length', error, stack);
      }
      entry = await _serial(() => _save(capture));
    } finally {
      // Until here no retry may take this capture: it would save it without its length and delete it under us.
      _busyCaptures.remove(capture.id);
    }
    await _countPending();
    _state.value = RecorderState.idle;
    final result = RecordingSaveResult(
      noteId: capture.noteId,
      entry: entry,
      leftApp: leftApp,
    );
    _lastResult.value = result;
    return result;
  }

  /// The recordings of [noteId], after saving the ones of this note left from failed saves.
  Future<List<RecordingEntry>> list(String noteId) async {
    if (!recordings.available) return const [];
    await _serial(() => _savePending(noteId: noteId));
    await _countPending();
    return recordings.list(noteId);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _closeGrace?.cancel();
    if (state != AppLifecycleState.hidden &&
        state != AppLifecycleState.paused) {
      return;
    }
    // Coming back from paused, observers get hidden and inactive before resumed: during the grace only its end
    // decides.
    if (AppExternalScreen.active || (_closeGrace?.isActive ?? false)) return;
    if (_starting != null) {
      _leftWhileStarting = true;
    } else {
      unawaited(stop(leftApp: true));
    }
  }

  /// The app's own screen closed while the app is in the background. Android can deliver the screen's result just
  /// before it resumes the app, so only an app still away after [AppExternalScreen.closeGrace] was left from it.
  void _externalScreenChanged() {
    _closeGrace?.cancel();
    final state = WidgetsBinding.instance.lifecycleState;
    if (AppExternalScreen.active ||
        (state != AppLifecycleState.hidden &&
            state != AppLifecycleState.paused)) {
      return;
    }
    _closeGrace = Timer(AppExternalScreen.closeGrace, () {
      final now = WidgetsBinding.instance.lifecycleState;
      if (!AppExternalScreen.active && now != null) {
        didChangeAppLifecycleState(now);
      }
    });
  }

  /// Stops and saves a running recording (the screen is let go first), then releases the microphone. A start on
  /// its way is given up as on leaving the app.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    AppExternalScreen.open.removeListener(_externalScreenChanged);
    _closeGrace?.cancel();
    await _starting?.future;
    if (_state.value == RecorderState.recording ||
        _state.value == RecorderState.paused) {
      await _screenOn(false);
      await stop();
    }
    _ticker?.cancel();
    await _stopping;
    await _saving;
    try {
      await backend.dispose();
    } catch (error, stack) {
      _log.warning('Could not release the recorder', error, stack);
    }
    _state.dispose();
    _elapsed.dispose();
    _lastResult.dispose();
    _pendingCount.dispose();
  }

  Duration _currentElapsed() {
    final start = _segmentStart;
    return start == null ? _recorded : _recorded + (_clock() - start);
  }

  Future<void> _screenOn(bool on) async {
    try {
      await _keepScreenOn(on);
    } catch (error, stack) {
      _log.warning('Could not set keep-screen-on', error, stack);
    }
  }

  /// Runs saves one at a time, so a retry and a stop never save the same capture twice.
  Future<T> _serial<T>(Future<T> Function() task) {
    final result = _saving.then((_) => task());
    _saving = result.then<void>((_) {}, onError: (_) {});
    return result;
  }

  /// The ids of the audio files kept in the recording folder that no recorder is busy with.
  Future<List<String>> _keptIds(Directory directory) async => [
    if (directory.existsSync())
      for (final file in directory.listSync().whereType<File>())
        if (file.path.endsWith('.m4a'))
          ?_idOf(file.uri.pathSegments.last, '.m4a'),
  ];

  static String? _idOf(String name, String suffix) {
    final id = name.substring(0, name.length - suffix.length);
    return _busyCaptures.contains(id) ? null : id;
  }

  Future<void> _countPending() async {
    try {
      final count = (await _keptIds(await _directory())).length;
      if (!_disposed) _pendingCount.value = count;
    } catch (error, stack) {
      _log.warning('Could not count unsaved recordings', error, stack);
    }
  }

  /// Saves the recordings kept in the folder (of [noteId] only when given). An audio file whose JSON is missing or
  /// unreadable is left as it is, neither saved nor deleted, and logged as severe.
  Future<void> _savePending({String? noteId}) async {
    final List<_Capture> pending;
    try {
      final directory = await _directory();
      pending = [];
      for (final id in await _keptIds(directory)) {
        final capture = await _Capture.read(id, directory);
        if (capture == null) {
          _log.severe(
            'Kept ${directory.path}/$id.m4a unsaved: its $id.json is missing or unreadable',
          );
        } else {
          pending.add(capture);
        }
      }
    } catch (error, stack) {
      _log.warning('Could not look for unsaved recordings', error, stack);
      return;
    }
    for (final capture in pending) {
      if (noteId != null && capture.noteId != noteId) continue;
      // Another recorder may be saving it right now (or have just saved it).
      if (_busyCaptures.contains(capture.id)) continue;
      _busyCaptures.add(capture.id);
      try {
        await _save(capture);
      } finally {
        _busyCaptures.remove(capture.id);
      }
    }
  }

  /// Writes [capture] as an attachment and deletes its files. Any failure leaves the files for a later try.
  Future<RecordingEntry?> _save(_Capture capture) async {
    try {
      if (!capture.audio.existsSync() || capture.audio.lengthSync() == 0) {
        await capture.delete();
        return null;
      }
      if (!await recordings.noteIsLive(capture.noteId)) {
        _log.warning(
          'Kept recording ${capture.id}: note ${capture.noteId} is missing, conflicted or in the trash',
        );
        return null;
      }
      final existing = await recordings.list(capture.noteId);
      final saved =
          existing.where((e) => e.captureId == capture.id).firstOrNull ??
          await recordings.add(
            capture.noteId,
            audio: await capture.audio.readAsBytes(),
            duration: capture.duration ?? Duration.zero,
            createdAt: capture.createdAt,
            captureId: capture.id,
            existing: existing,
          );
      try {
        await capture.delete();
      } catch (error, stack) {
        _log.warning(
          'Saved recording ${capture.id}; could not delete',
          error,
          stack,
        );
      }
      return saved;
    } catch (error, stack) {
      _log.warning('Kept recording ${capture.id} to save later', error, stack);
      return null;
    }
  }
}

/// A recording in the recording folder: `{id}.m4a` and `{id}.json` (note id, start time, length once stopped).
class _Capture {
  new({
    required this.id,
    required this.noteId,
    required this.createdAt,
    required this.directory,
    this.duration,
  });

  final String id;
  final String noteId;
  final DateTime createdAt;
  final Directory directory;
  Duration? duration;

  File get audio => File('${directory.path}/$id.m4a');
  File get info => File('${directory.path}/$id.json');

  /// Writes the JSON beside a temporary name and renames it over the old one, so a full disk leaves the old JSON
  /// whole instead of an empty one.
  Future<void> writeInfo() async {
    final next = File('${info.path}.tmp');
    await next.writeAsString(
      jsonEncode({
        'schemaVersion': 1,
        'noteId': noteId,
        'createdAt': createdAt.toIso8601String(),
        'durationMs': ?duration?.inMilliseconds,
      }),
      flush: true,
    );
    await next.rename(info.path);
  }

  Future<void> delete() async {
    if (audio.existsSync()) await audio.delete();
    if (info.existsSync()) await info.delete();
  }

  /// The capture [id] in [directory], or null when its JSON is missing or cannot be read.
  static Future<_Capture?> read(String id, Directory directory) async {
    final file = File('${directory.path}/$id.json');
    try {
      final value = jsonDecode(await file.readAsString());
      if (value is! Map || value['schemaVersion'] != 1) return null;
      final noteId = value['noteId'];
      final createdAt = DateTime.tryParse('${value['createdAt']}');
      final duration = value['durationMs'];
      if (noteId is! String || createdAt == null) return null;
      return _Capture(
        id: id,
        noteId: noteId,
        createdAt: createdAt,
        directory: directory,
        duration: duration is num
            ? Duration(milliseconds: duration.toInt())
            : null,
      );
    } on FormatException {
      return null;
    } on FileSystemException {
      return null;
    }
  }
}
