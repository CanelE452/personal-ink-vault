import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/audio/note_player.dart';
import 'package:saber/data/audio/recording_entry.dart';
import 'package:saber/data/vault/note_side_store.dart';

import 'fake_audio_backends.dart';

RecordingEntry entry(String id) => RecordingEntry(
  noteId: 'note',
  entityId: id,
  name: 'Lecture',
  duration: const Duration(minutes: 1),
  createdAt: DateTime.utc(2026, 11, 27),
  sizeBytes: 4,
  record: NoteSideRecord(
    entityId: id,
    revisionId: 'r-$id',
    heads: const [],
    kind: NoteSideKind.recording,
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  final audio = Uint8List.fromList([1, 2, 3, 4]);
  var reads = 0;
  Object? readError;

  NotePlayer newPlayer(FakePlayerBackend backend) => NotePlayer(
    backend: backend,
    readAudio: (_) async {
      reads++;
      if (readError != null) throw readError!;
      return audio;
    },
    directory: () async => Directory('${temp.path}/playback'),
  );

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('piv-player-');
    reads = 0;
    readError = null;
  });
  tearDown(() => temp.delete(recursive: true));

  test('speed cycles 1, 1.25, 1.5, 2, 0.75, 1', () async {
    final backend = FakePlayerBackend();
    final player = newPlayer(backend);
    expect(player.speed, 1.0);
    expect(
      [for (var i = 0; i < 6; i++) player.cycleSpeed()],
      [1.25, 1.5, 2.0, 0.75, 1.0, 1.25],
    );
    await player.play(entry('a'));
    expect(backend.speeds.last, 1.25);
    await player.dispose();
  });

  test(
    'play writes the audio to a file, loads it, and close removes it',
    () async {
      final backend = FakePlayerBackend();
      final player = newPlayer(backend);
      await player.play(entry('a'));
      expect(player.state.value, PlayerState.playing);
      expect(player.current.value?.entityId, 'a');
      expect(File(backend.loaded!).readAsBytesSync(), audio);
      expect(backend.loaded, endsWith('.m4a'));

      backend.onPosition(const Duration(seconds: 7));
      expect(player.position.value, const Duration(seconds: 7));
      await player.seek(const Duration(seconds: 20));
      expect(player.position.value, const Duration(seconds: 20));
      await player.pause();
      expect(player.state.value, PlayerState.paused);

      // Same recording again resumes without reading it again.
      await player.play(entry('a'));
      expect(reads, 1);
      expect(player.state.value, PlayerState.playing);

      backend.onCompleted();
      expect(player.state.value, PlayerState.paused);
      expect(player.position.value, Duration.zero);

      final file = backend.loaded!;
      await player.close();
      expect(player.state.value, PlayerState.idle);
      expect(player.current.value, isNull);
      expect(File(file).existsSync(), isFalse);
      await player.dispose();
    },
  );

  test(
    'a device that cannot play reports unsupported and play does nothing',
    () async {
      final backend = FakePlayerBackend(supported: false);
      final player = newPlayer(backend);
      expect(player.supported, isFalse);
      await player.play(entry('a'));
      expect(backend.calls, isEmpty);
      expect(reads, 0);
      expect(player.state.value, PlayerState.idle);
      await player.pause();
      await player.seek(const Duration(seconds: 1));
      await player.close();
      await player.dispose();
    },
  );

  test('a missing plugin turns supported off without throwing', () async {
    final backend = FakePlayerBackend(
      loadError: MissingPluginException('no just_audio'),
    );
    final player = newPlayer(backend);
    expect(player.supported, isTrue);
    await player.play(entry('a'));
    expect(player.supported, isFalse);
    expect(player.state.value, PlayerState.idle);
    expect(player.current.value, isNull);
    await player.play(entry('a'));
    expect(backend.calls.where((c) => c == 'load'), hasLength(1));
    await player.dispose();
  });

  test('a second tap while loading is ignored', () async {
    final backend = FakePlayerBackend();
    final player = newPlayer(backend);
    final first = player.play(entry('a'));
    expect(player.state.value, PlayerState.loading);
    final second = player.play(entry('b'));
    await Future.wait([first, second]);
    expect(backend.calls.where((c) => c == 'load'), hasLength(1));
    expect(reads, 1);
    expect(player.current.value?.entityId, 'a');
    expect(player.state.value, PlayerState.playing);
    await player.dispose();
  });

  test(
    'a recording that cannot be read shows an error, not an exception',
    () async {
      final backend = FakePlayerBackend();
      final player = newPlayer(backend);
      readError = const FileSystemException('gone');
      await player.play(entry('a'));
      expect(player.state.value, PlayerState.error);
      expect(player.current.value, isNull);
      expect(player.supported, isTrue);

      readError = null;
      await player.play(entry('a'));
      expect(player.state.value, PlayerState.playing);
      await player.dispose();
    },
  );

  test('a load that fails after close and a new play leaves the new recording playing', () async {
    final backend = FakePlayerBackend();
    final player = newPlayer(backend);
    final held = Completer<void>();
    backend.whileLoading = (path) async {
      if (path.contains('a.m4a')) {
        await held.future;
        throw const FileSystemException('late');
      }
    };
    final first = player.play(entry('a'));
    await pumpEventQueue();
    expect(player.state.value, PlayerState.loading);
    await player.close();
    await player.play(entry('b'));
    expect(player.current.value?.entityId, 'b');
    expect(player.state.value, PlayerState.playing);

    held.complete();
    await first;
    expect(player.current.value?.entityId, 'b');
    expect(player.state.value, PlayerState.playing);
    await player.dispose();
  });

  test(
    'resuming with the same recording read again reports its failure',
    () async {
      final backend = FakePlayerBackend();
      final player = newPlayer(backend);
      await player.play(entry('a'));
      await player.pause();
      backend.playError = const FileSystemException('busy');
      // the audio tab reads its list again: a new entry, the same recording
      await player.play(entry('a'));
      expect(reads, 1, reason: 'resumed, not loaded again');
      expect(player.state.value, PlayerState.error);
      expect(player.current.value, isNull);

      backend.playError = null;
      await player.play(entry('a'));
      expect(player.state.value, PlayerState.playing);
      await player.dispose();
    },
  );

  test('playing that fails once it started stops at an error', () async {
    final backend = FakePlayerBackend();
    final player = newPlayer(backend);
    await player.play(entry('a'));
    expect(player.state.value, PlayerState.playing);
    // just_audio's play() fails after it returned
    final a = backend.loaded!;
    backend.onFailed(a, const FileSystemException('decoder'), StackTrace.empty);
    await pumpEventQueue();
    expect(player.state.value, PlayerState.error);
    expect(player.current.value, isNull);
    expect(backend.calls.last, 'stop');

    // a failure heard while nothing plays changes nothing
    backend.onFailed(a, const FileSystemException('late'), StackTrace.empty);
    await pumpEventQueue();
    expect(player.state.value, PlayerState.error);

    await player.play(entry('a'));
    expect(player.state.value, PlayerState.playing);
    await player.dispose();
  });

  test(
    'a late failure of a recording since replaced changes nothing',
    () async {
      final backend = FakePlayerBackend();
      final player = newPlayer(backend);
      await player.play(entry('a'));
      final a = backend.loaded!;
      await player.play(entry('b'));
      expect(player.current.value?.entityId, 'b');
      expect(player.state.value, PlayerState.playing);
      // a's play() fails only now
      backend.onFailed(
        a,
        const FileSystemException('decoder'),
        StackTrace.empty,
      );
      await pumpEventQueue();
      expect(player.state.value, PlayerState.playing);
      expect(player.current.value?.entityId, 'b');
      await player.dispose();
    },
  );

  test('a load that fails after dispose does not throw', () async {
    final backend = FakePlayerBackend();
    final player = newPlayer(backend);
    final held = Completer<void>();
    backend.whileLoading = (_) async {
      await held.future;
      throw const FileSystemException('late');
    };
    final first = player.play(entry('a'));
    await pumpEventQueue();
    await player.dispose();
    held.complete();
    await expectLater(first, completes);
  });
}
