import 'dart:io';

import 'package:flutter/services.dart';
import 'package:saber/data/audio/note_player.dart';
import 'package:saber/data/audio/note_recorder.dart';

/// Records nothing: writes [audio] to the path when stopped, like an encoder
/// closing its file. Shared by the recorder's, the player's and the
/// recording pill's tests.
class FakeRecorderBackend implements RecorderBackend {
  var permission = true;
  Object? startError;
  var audio = Uint8List.fromList(List.generate(64, (i) => i));
  final calls = <String>[];
  String? path;

  /// Run inside [hasPermission], [start] and [stop], where the real plugin
  /// waits; a test holds the call there.
  Future<void> Function()? whileAsking;
  Future<void> Function()? whileStarting;
  Future<void> Function()? whileStopping;

  @override
  Future<bool> hasPermission() async {
    calls.add('hasPermission');
    await whileAsking?.call();
    return permission;
  }

  @override
  Future<void> start(String path) async {
    calls.add('start');
    if (startError != null) throw startError!;
    this.path = path;
    await File(path).writeAsBytes(audio.sublist(0, 8));
    await whileStarting?.call();
  }

  @override
  Future<void> pause() async => calls.add('pause');

  @override
  Future<void> resume() async => calls.add('resume');

  @override
  Future<String?> stop() async {
    calls.add('stop');
    await whileStopping?.call();
    await File(path!).writeAsBytes(audio);
    return path;
  }

  @override
  Future<void> dispose() async {}
}

/// Plays nothing and keeps what it was asked.
class FakePlayerBackend implements PlayerBackend {
  new({this.supported = true, this.loadError});

  @override
  final bool supported;
  final Object? loadError;
  final calls = <String>[];
  final speeds = <double>[];
  String? loaded;

  /// Runs inside [load] before it returns; a test holds a load here.
  Future<void> Function(String path)? whileLoading;
  late void Function(Duration position) onPosition;
  late void Function() onCompleted;
  late void Function(String path, Object error, StackTrace stack) onFailed;

  @override
  void listen({
    required void Function(Duration position) onPosition,
    required void Function() onCompleted,
    required void Function(String path, Object error, StackTrace stack)
    onFailed,
  }) {
    this.onPosition = onPosition;
    this.onCompleted = onCompleted;
    this.onFailed = onFailed;
  }

  @override
  Future<void> load(String path) async {
    calls.add('load');
    await whileLoading?.call(path);
    if (loadError != null) throw loadError!;
    loaded = path;
  }

  /// Thrown by [play] when set.
  Object? playError;

  @override
  Future<void> play() async {
    calls.add('play');
    if (playError != null) throw playError!;
  }

  @override
  Future<void> pause() async => calls.add('pause');

  @override
  Future<void> seek(Duration position) async => calls.add('seek $position');

  @override
  Future<void> setSpeed(double speed) async => speeds.add(speed);

  @override
  Future<void> stop() async => calls.add('stop');

  @override
  Future<void> dispose() async => calls.add('dispose');
}
