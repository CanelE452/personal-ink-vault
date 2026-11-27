import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart' as ja;
import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';
import 'package:saber/data/audio/recording_entry.dart';

/// The audio player, behind a boundary so tests can fake it.
abstract class PlayerBackend {
  /// False where the platform has no player (`just_audio` has no Windows or Linux implementation).
  bool get supported;

  /// Sets where the playing position (about every 0.2 s), the end of playback and a failure of playing once started
  /// (of the file at `path`) are reported.
  void listen({
    required void Function(Duration position) onPosition,
    required void Function() onCompleted,
    required void Function(String path, Object error, StackTrace stack)
    onFailed,
  });
  Future<void> load(String path);

  /// Starts playing and returns without waiting for the end.
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> setSpeed(double speed);
  Future<void> stop();
  Future<void> dispose();
}

/// [PlayerBackend] on `just_audio`; the plugin player is made on first load.
class JustAudioBackend implements PlayerBackend {
  ja.AudioPlayer? _player;
  final _subscriptions = <StreamSubscription<Object?>>[];
  void Function(Duration position)? _onPosition;
  void Function()? _onCompleted;
  void Function(String path, Object error, StackTrace stack)? _onFailed;
  String? _path;
  static final _log = Logger('JustAudioBackend');

  @override
  bool get supported =>
      Platform.isAndroid || Platform.isIOS || Platform.isMacOS;

  @override
  void listen({
    required void Function(Duration position) onPosition,
    required void Function() onCompleted,
    required void Function(String path, Object error, StackTrace stack)
    onFailed,
  }) {
    _onPosition = onPosition;
    _onCompleted = onCompleted;
    _onFailed = onFailed;
  }

  ja.AudioPlayer get _plugin {
    final existing = _player;
    if (existing != null) return existing;
    final player = ja.AudioPlayer();
    _subscriptions
      ..add(
        player
            .createPositionStream(
              minPeriod: const Duration(milliseconds: 200),
              maxPeriod: const Duration(milliseconds: 200),
            )
            .listen((position) => _onPosition?.call(position)),
      )
      ..add(
        player.processingStateStream
            .where((state) => state == ja.ProcessingState.completed)
            .listen((_) => _onCompleted?.call()),
      );
    return _player = player;
  }

  @override
  Future<void> load(String path) {
    _path = path;
    return _plugin.setFilePath(path);
  }

  @override
  Future<void> play() async {
    // just_audio's play() completes only when playback pauses or ends: a
    // failure comes after this returned, maybe once another file is loaded.
    final path = _path;
    unawaited(
      _plugin.play().catchError((Object error, StackTrace stack) {
        _log.warning('Playback failed', error, stack);
        if (path != null) _onFailed?.call(path, error, stack);
      }),
    );
  }

  @override
  Future<void> pause() => _plugin.pause();

  @override
  Future<void> seek(Duration position) => _plugin.seek(position);

  @override
  Future<void> setSpeed(double speed) => _plugin.setSpeed(speed);

  @override
  Future<void> stop() async => _player?.stop();

  @override
  Future<void> dispose() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _player?.dispose();
  }
}

enum PlayerState {
  idle,

  /// Writing the audio to a file and loading it; [NotePlayer.play] ignores taps until it is done.
  loading,
  playing,
  paused,

  /// The last [NotePlayer.play] failed (the recording could not be read or played); the next play clears it.
  error,
}

/// Plays one recording at a time: [play] writes the attachment's audio to a file in the app's temporary folder and
/// plays it. Where the device cannot play, [supported] is false and every call quietly does nothing; a missing
/// plugin found while playing turns [supported] false instead of throwing.
class NotePlayer {
  new({
    required this.readAudio,
    PlayerBackend? backend,
    Future<Directory> Function()? directory,
  }) : backend = backend ?? JustAudioBackend(),
       _directory = directory ?? _defaultDirectory {
    _supported = this.backend.supported;
    this.backend.listen(
      onPosition: (position) => _position.value = position,
      onCompleted: _completed,
      onFailed: _failed,
    );
  }

  final PlayerBackend backend;

  /// Reads a recording's audio (the host passes [NoteRecordings.readAudio]).
  final Future<Uint8List> Function(RecordingEntry entry) readAudio;
  final Future<Directory> Function() _directory;
  static final _log = Logger('NotePlayer');

  /// The order [cycleSpeed] steps through, starting at 1.
  static const speeds = [1.0, 1.25, 1.5, 2.0, 0.75];

  final _state = ValueNotifier(PlayerState.idle);
  final _position = ValueNotifier(Duration.zero);
  final _current = ValueNotifier<RecordingEntry?>(null);
  late bool _supported;
  var _speedIndex = 0;
  var _disposed = false;
  File? _file;

  ValueListenable<PlayerState> get state => _state;
  ValueListenable<Duration> get position => _position;

  /// The recording loaded in the player, or null.
  ValueListenable<RecordingEntry?> get current => _current;
  bool get supported => _supported;
  double get speed => speeds[_speedIndex];

  static Future<Directory> _defaultDirectory() async =>
      Directory('${(await getTemporaryDirectory()).path}/note-playback');

  /// Plays [requested], or resumes it when it is the recording already loaded (the same entity id: the audio tab reads
  /// its list again, so the entry may be a new one of the same recording).
  Future<void> play(RecordingEntry requested) async {
    if (!_supported || _state.value == PlayerState.loading) return;
    final loaded = _current.value;
    // what the checks below compare is the loaded entry itself
    final entry = loaded?.entityId == requested.entityId ? loaded! : requested;
    try {
      if (identical(entry, loaded)) {
        if (_state.value == PlayerState.playing) return;
        await backend.play();
        _state.value = PlayerState.playing;
        return;
      }
      _state.value = PlayerState.loading;
      await _unload(PlayerState.loading);
      // Closed (or disposed) while unloading: leave it so.
      if (_disposed || _state.value != PlayerState.loading) return;
      _current.value = entry;
      final directory = await _directory();
      await directory.create(recursive: true);
      final file = File('${directory.path}/${entry.entityId}.m4a');
      _file = file;
      await file.writeAsBytes(await readAudio(entry), flush: true);
      if (!_isCurrent(entry)) return;
      await backend.load(file.path);
      if (!_isCurrent(entry)) return;
      await backend.setSpeed(speed);
      await backend.play();
      _state.value = PlayerState.playing;
    } catch (error, stack) {
      // A late failure of a recording closed or replaced meanwhile changes nothing.
      if (!_isCurrent(entry)) {
        _log.info('Dropped a late failure of ${entry.entityId}: $error');
        return;
      }
      if (error is MissingPluginException || error is UnimplementedError) {
        _log.info('No audio player on this device: $error');
        _supported = false;
        await _unload();
      } else {
        _log.warning('Could not play ${entry.entityId}', error, stack);
        await _unload(PlayerState.error);
      }
    }
  }

  Future<void> pause() async {
    if (_state.value != PlayerState.playing) return;
    _state.value = PlayerState.paused;
    await _quietly('pause', backend.pause);
  }

  Future<void> seek(Duration position) async {
    if (_current.value == null) return;
    _position.value = position;
    await _quietly('seek', () => backend.seek(position));
  }

  /// Steps the speed 1 → 1.25 → 1.5 → 2 → 0.75 → 1 and returns the new one.
  double cycleSpeed() {
    _speedIndex = (_speedIndex + 1) % speeds.length;
    final next = speed;
    if (_current.value != null) {
      unawaited(_quietly('speed', () => backend.setSpeed(next)));
    }
    return next;
  }

  /// Stops playing and forgets the recording (the listening bar closed).
  Future<void> close() => _unload();

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _unload();
    await _quietly('dispose', backend.dispose);
    _state.dispose();
    _position.dispose();
    _current.dispose();
  }

  /// Whether [entry] is still the loaded recording of a player not disposed.
  bool _isCurrent(RecordingEntry entry) =>
      !_disposed && identical(_current.value, entry);

  void _completed() {
    if (_current.value == null) return;
    _state.value = PlayerState.paused;
    _position.value = Duration.zero;
    unawaited(
      _quietly('rewind', () async {
        await backend.pause();
        await backend.seek(Duration.zero);
      }),
    );
  }

  /// Playing the file at [path] failed after it started (the backend heard
  /// it late): it stops at [PlayerState.error]. Heard while nothing plays,
  /// or for a recording since replaced (another file), it changes nothing.
  void _failed(String path, Object error, StackTrace stack) {
    if (_disposed || _state.value != PlayerState.playing) return;
    if (path != _file?.path) {
      _log.info('Dropped a late failure of $path: $error');
      return;
    }
    _log.warning('Playing ${_current.value?.entityId} failed', error, stack);
    unawaited(_unload(PlayerState.error));
  }

  /// Stops and forgets the loaded recording, leaving [state] at [next].
  Future<void> _unload([PlayerState next = PlayerState.idle]) async {
    if (_current.value != null) await _quietly('stop', backend.stop);
    _state.value = next;
    _position.value = Duration.zero;
    _current.value = null;
    final file = _file;
    _file = null;
    try {
      if (file != null && file.existsSync()) await file.delete();
    } on FileSystemException catch (error) {
      _log.warning('Could not delete ${file?.path}: $error');
    }
  }

  Future<void> _quietly(String what, Future<void> Function() action) async {
    try {
      await action();
    } catch (error, stack) {
      _log.warning('Could not $what', error, stack);
    }
  }
}
