import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:logging/logging.dart';
import 'package:saber/data/app_external_screen.dart';
import 'package:saber/data/audio/note_player.dart';
import 'package:saber/data/audio/note_recorder.dart';
import 'package:saber/data/audio/recording_entry.dart';
import 'package:saber/data/vault/note_side_store.dart';
import 'package:saber/data/vault/workspace_store.dart';

import 'fake_audio_backends.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late Directory recordingFolder;
  late NoteRepository repository;
  late WorkspaceStore workspace;
  late NoteSideStore side;
  late NoteRecordings recordings;
  late FakeRecorderBackend backend;
  late NoteRecorder recorder;
  late Duration clock;
  late List<bool> keepScreenOn;
  late String noteId;
  final startedAt = DateTime.utc(2026, 11, 27, 5, 2);

  NoteRecorder newRecorder({Future<void> Function()? beforeStart}) =>
      NoteRecorder(
        recordings: recordings,
        backend: backend,
        directory: () async => recordingFolder,
        clock: () => clock,
        now: () => startedAt,
        keepScreenOn: (on) async => keepScreenOn.add(on),
        beforeStart: beforeStart,
      );

  String captureName() {
    final file = File(backend.path!).uri.pathSegments.last;
    return file.substring(0, file.length - '.m4a'.length);
  }

  Future<void> send(AppLifecycleState value) =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            SystemChannels.lifecycle.name,
            SystemChannels.lifecycle.codec.encodeMessage(value.toString()),
            (_) {},
          );

  /// The next result [recorder] publishes.
  Future<RecordingSaveResult> nextResult() {
    final result = Completer<RecordingSaveResult>();
    final listened = recorder;
    void onResult() {
      final value = listened.lastResult.value;
      if (value != null && !result.isCompleted) {
        listened.lastResult.removeListener(onResult);
        result.complete(value);
      }
    }

    listened.lastResult.addListener(onResult);
    return result.future.timeout(const Duration(seconds: 30));
  }

  List<FileSystemEntity> leftovers() =>
      recordingFolder.existsSync() ? recordingFolder.listSync() : const [];

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('piv-recorder-');
    recordingFolder = Directory('${temp.path}/recordings');
    repository = await NoteRepository.open(
      Directory('${temp.path}/vault'),
      createFormatVersion: 2,
    );
    workspace = WorkspaceStore(repository);
    side = NoteSideStore(repository);
    recordings = NoteRecordings(side);
    backend = FakeRecorderBackend();
    clock = Duration.zero;
    keepScreenOn = [];
    noteId = (await workspace.create('Physics')).id;
    recorder = newRecorder();
  });
  tearDown(() async {
    await send(AppLifecycleState.resumed);
    await recorder.dispose();
    await repository.close().timeout(const Duration(seconds: 30));
    await temp.delete(recursive: true);
  });

  test(
    'start, pause, resume and stop save one attachment without the paused time',
    () async {
      expect(await recorder.start(noteId), RecorderStartResult.started);
      expect(recorder.state.value, RecorderState.recording);
      clock = const Duration(seconds: 10);
      await recorder.pause();
      expect(recorder.state.value, RecorderState.paused);
      expect(recorder.elapsed.value, const Duration(seconds: 10));
      clock = const Duration(seconds: 25);
      expect(recorder.elapsed.value, const Duration(seconds: 10));
      await recorder.resume();
      clock = const Duration(seconds: 32);
      final result = await recorder.stop();

      expect(recorder.state.value, RecorderState.idle);
      expect(result?.saved, isTrue);
      expect(result!.leftApp, isFalse);
      final entry = result.entry!;
      expect(entry.duration, const Duration(seconds: 17));
      expect(entry.name, '녹음 1');
      expect(entry.sizeBytes, backend.audio.length);
      expect(entry.createdAt.isAtSameMomentAs(startedAt), isTrue);
      expect(recorder.lastResult.value?.entry?.entityId, entry.entityId);
      expect(recorder.pendingCount.value, 0);
      expect(backend.calls, [
        'hasPermission',
        'start',
        'pause',
        'resume',
        'stop',
      ]);
      expect(backend.path, endsWith('.m4a'));
      expect(keepScreenOn, [true, false]);

      final stored = (await side.list(noteId, NoteSideKind.recording)).single;
      expect(stored.entityId, entry.entityId);
      expect(await recordings.readAudio(entry), backend.audio);
      final listed = (await recordings.list(noteId)).single;
      expect(listed.duration, const Duration(seconds: 17));
      expect(listed.sizeBytes, backend.audio.length);
      expect(leftovers(), isEmpty);
    },
  );

  for (final state in [AppLifecycleState.hidden, AppLifecycleState.paused]) {
    test(
      'leaving the app (${state.name}) stops, saves and marks leftApp',
      () async {
        expect(await recorder.start(noteId), RecorderStartResult.started);
        clock = const Duration(seconds: 5);
        final published = nextResult();
        await send(state);
        final result = await published;
        await send(AppLifecycleState.resumed);

        expect(result.leftApp, isTrue);
        expect(result.saved, isTrue);
        expect(result.entry!.duration, const Duration(seconds: 5));
        expect(recorder.state.value, RecorderState.idle);
        expect(await recordings.list(noteId), hasLength(1));
        expect(keepScreenOn, [true, false]);
      },
    );
  }

  // A file picker of the app (final fix wave 3) hides the app while it is
  // open: that is not leaving it.
  test(
    'hidden and paused while an in-app screen is open keep recording',
    () async {
      expect(await recorder.start(noteId), RecorderStartResult.started);
      final picked = Completer<void>();
      addTearDown(() => picked.isCompleted ? null : picked.complete());
      final picking = AppExternalScreen.run(() => picked.future);
      await send(AppLifecycleState.hidden);
      await send(AppLifecycleState.paused);
      await pumpEventQueue();
      expect(recorder.state.value, RecorderState.recording);
      expect(recorder.lastResult.value, isNull);
      await send(AppLifecycleState.resumed);
      picked.complete();
      await picking;
      expect(recorder.state.value, RecorderState.recording);
      expect(keepScreenOn, [true]);
      await recorder.stop();
    },
  );

  test(
    'once the in-app screen is closed, leaving the app stops and saves',
    () async {
      await AppExternalScreen.run(() async {});
      expect(AppExternalScreen.active, isFalse);
      expect(await recorder.start(noteId), RecorderStartResult.started);
      clock = const Duration(seconds: 4);
      final published = nextResult();
      await send(AppLifecycleState.paused);
      final result = await published;
      expect(result.leftApp, isTrue);
      expect(result.saved, isTrue);
      expect(recorder.state.value, RecorderState.idle);
      expect(await recordings.list(noteId), hasLength(1));
    },
  );

  /// Lets the recorder's file work (started on the test's fake time) finish on
  /// the real event loop, with the fake time standing still.
  Future<void> settle(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 100 && !done(); i++) {
      await tester.runAsync(pumpEventQueue);
      await tester.pump();
    }
  }

  /// Disposes the recorder and closes the vault inside the test body: what
  /// they wait for was started on the fake time, which tearDown no longer runs.
  Future<void> finish(WidgetTester tester) async {
    var done = false;
    unawaited(
      (() async {
        await recorder.dispose();
        await repository.close();
      })().whenComplete(() => done = true),
    );
    await settle(tester, () => done);
    expect(done, isTrue, reason: 'the recorder and the vault should close');
  }

  /// Starts recording, opens an in-app screen, sends the app to the
  /// background and closes the screen while the app is still paused.
  Future<void> closeScreenWhileAway(WidgetTester tester) async {
    expect(
      await tester.runAsync(() => recorder.start(noteId)),
      RecorderStartResult.started,
    );
    clock = const Duration(seconds: 4);
    final picked = Completer<void>();
    final picking = AppExternalScreen.run(() => picked.future);
    await send(AppLifecycleState.hidden);
    await send(AppLifecycleState.paused);
    await tester.pump();
    expect(recorder.state.value, RecorderState.recording);
    picked.complete();
    await picking;
    await tester.pump();
    await settle(tester, () => recorder.state.value != RecorderState.saving);
  }

  // The user really went to another app while the picker was open (final
  // fix 2, concern 4): the picker closing with the app still away stops, as
  // leaving the app does. Android can deliver the picker's result just before
  // it resumes the app (final fix 3), so the recorder waits as long as the
  // workspace does before deciding.
  testWidgets(
    'an in-app screen closing while the app stays away stops and saves after the grace',
    (tester) async {
      try {
        await closeScreenWhileAway(tester);
        await tester.pump(
          AppExternalScreen.closeGrace - const Duration(milliseconds: 1),
        );
        await settle(
          tester,
          () => recorder.state.value != RecorderState.saving,
        );
        expect(recorder.state.value, RecorderState.recording);
        expect(recorder.lastResult.value, isNull);
        RecordingSaveResult? result;
        unawaited(nextResult().then((value) => result = value));
        await tester.pump(const Duration(milliseconds: 1));
        await settle(tester, () => result != null);
        expect(result?.leftApp, isTrue);
        expect(result?.saved, isTrue);
        expect(recorder.state.value, RecorderState.idle);
        expect(
          await tester.runAsync(() => recordings.list(noteId)),
          hasLength(1),
        );
      } finally {
        await finish(tester);
      }
    },
  );

  // Coming back from paused, the binding hands observers hidden and inactive
  // before resumed, so the hidden right after the picker closed must not stop.
  testWidgets(
    'an in-app screen closing just before the app comes back keeps recording',
    (tester) async {
      try {
        await closeScreenWhileAway(tester);
        await send(AppLifecycleState.resumed);
        await tester.pump(
          AppExternalScreen.closeGrace + const Duration(seconds: 1),
        );
        await settle(
          tester,
          () => recorder.state.value != RecorderState.saving,
        );
        expect(recorder.state.value, RecorderState.recording);
        expect(recorder.lastResult.value, isNull);
        await tester.runAsync(recorder.stop);
        expect(recorder.lastResult.value?.leftApp, isFalse);
      } finally {
        await finish(tester);
      }
    },
  );

  // A timer left after the recorder is gone would trip the binding's check
  // for timers still pending when the test ends.
  testWidgets('disposing the recorder during the grace leaves no timer', (
    tester,
  ) async {
    try {
      await closeScreenWhileAway(tester);
      await tester.pump(const Duration(seconds: 1));
      await settle(tester, () => recorder.state.value != RecorderState.saving);
      expect(recorder.state.value, RecorderState.recording);
      var disposed = false;
      unawaited(recorder.dispose().then((_) => disposed = true));
      await settle(tester, () => disposed);
      expect(disposed, isTrue);
      expect(recorder.lastResult.value?.leftApp, isFalse);
      expect(
        await tester.runAsync(() => recordings.list(noteId)),
        hasLength(1),
      );
    } finally {
      await finish(tester);
    }
  });

  test('an in-app screen closing with the app back keeps recording', () async {
    expect(await recorder.start(noteId), RecorderStartResult.started);
    final picked = Completer<void>();
    addTearDown(() => picked.isCompleted ? null : picked.complete());
    final picking = AppExternalScreen.run(() => picked.future);
    await send(AppLifecycleState.hidden);
    await send(AppLifecycleState.paused);
    await send(AppLifecycleState.hidden);
    await send(AppLifecycleState.inactive);
    await send(AppLifecycleState.resumed);
    picked.complete();
    await picking;
    await pumpEventQueue();
    expect(recorder.state.value, RecorderState.recording);
    expect(recorder.lastResult.value, isNull);
    await recorder.stop();
  });

  test('starting a recording pauses playback', () async {
    await recorder.start(noteId);
    final entry = (await recorder.stop())!.entry!;
    final playerBackend = FakePlayerBackend();
    final player = NotePlayer(
      backend: playerBackend,
      readAudio: recordings.readAudio,
      directory: () async => Directory('${temp.path}/playback'),
    );
    await recorder.dispose();
    recorder = newRecorder(beforeStart: player.pause);

    await player.play(entry);
    expect(player.state.value, PlayerState.playing);
    expect(await recorder.start(noteId), RecorderStartResult.started);
    expect(player.state.value, PlayerState.paused);
    expect(playerBackend.calls.last, 'pause');
    await recorder.stop();
    await player.dispose();
  });

  test(
    'a failed save keeps the audio; listing the note saves it once',
    () async {
      await recorder.start(noteId);
      clock = const Duration(seconds: 3);
      side.beforeCommit = () async => throw const FileSystemException('full');
      final result = await recorder.stop();
      expect(result?.saved, isFalse);
      expect(result!.leftApp, isFalse);
      expect(recorder.lastResult.value?.saved, isFalse);
      expect(recorder.pendingCount.value, 1);
      expect(recorder.state.value, RecorderState.idle);
      expect(keepScreenOn, [true, false]);
      expect(await side.list(noteId, NoteSideKind.recording), isEmpty);
      expect(leftovers().map((f) => f.uri.pathSegments.last).toSet(), {
        '${captureName()}.m4a',
        '${captureName()}.json',
      });
      expect(File(backend.path!).readAsBytesSync(), backend.audio);

      // Still failing: nothing is lost.
      expect(await recorder.list(noteId), isEmpty);
      expect(File(backend.path!).existsSync(), isTrue);
      expect(recorder.pendingCount.value, 1);

      side.beforeCommit = null;
      final listed = await recorder.list(noteId);
      expect(listed, hasLength(1));
      expect(listed.single.duration, const Duration(seconds: 3));
      expect(listed.single.name, '녹음 1');
      expect(await recordings.readAudio(listed.single), backend.audio);
      expect(leftovers(), isEmpty);
      expect(recorder.pendingCount.value, 0);
      expect(await recorder.list(noteId), hasLength(1));
    },
  );

  test('a save refused because the note is in the trash is retried on the next start', () async {
    await recorder.start(noteId);
    clock = const Duration(seconds: 4);
    final note = (await workspace.list()).single;
    await workspace.setDeleted(note, true);
    expect((await recorder.stop())?.saved, isFalse);
    final kept = backend.path!;
    expect(File(kept).existsSync(), isTrue);

    final restored = (await workspace.list(includeDeleted: true))
        .singleWhere((n) => n.id == noteId);
    await workspace.setDeleted(restored, false);
    clock = const Duration(seconds: 10);
    expect(await recorder.start(noteId), RecorderStartResult.started);
    expect(File(kept).existsSync(), isFalse);
    final first = (await recordings.list(noteId)).single;
    expect(first.duration, const Duration(seconds: 4));
    expect(first.name, '녹음 1');

    clock = const Duration(seconds: 12);
    final second = (await recorder.stop())!.entry!;
    expect(second.name, '녹음 2');
    expect(second.duration, const Duration(seconds: 2));
    expect(await recordings.list(noteId), hasLength(2));
    expect(leftovers(), isEmpty);
  });

  test(
    'a refused permission comes back as a result and leaves nothing',
    () async {
      backend.permission = false;
      expect(
        await recorder.start(noteId),
        RecorderStartResult.permissionDenied,
      );
      expect(recorder.state.value, RecorderState.idle);
      expect(keepScreenOn.where((on) => on), isEmpty);
      expect(leftovers(), isEmpty);
      expect(await recorder.stop(), isNull);
    },
  );

  test('a recorder that fails to start comes back as a result', () async {
    backend.startError = PlatformException(code: 'record');
    expect(await recorder.start(noteId), RecorderStartResult.failed);
    expect(recorder.state.value, RecorderState.idle);
    expect(keepScreenOn, [true, false]);
    expect(leftovers(), isEmpty);
  });

  test(
    'default names count up and skip taken ones; rename and delete',
    () async {
      await recorder.start(noteId);
      final first = (await recorder.stop())!.entry!;
      await recorder.start(noteId);
      final second = (await recorder.stop())!.entry!;
      expect([first.name, second.name], ['녹음 1', '녹음 2']);

      final renamed = await recordings.rename(first, '녹음 3');
      expect(renamed.entityId, first.entityId);
      expect(renamed.name, '녹음 3');
      expect(await recordings.readAudio(renamed), backend.audio);
      await recorder.start(noteId);
      final third = (await recorder.stop())!.entry!;
      expect(third.name, '녹음 4');

      final current = await recordings.list(noteId);
      await recordings.delete(
        current.singleWhere((e) => e.entityId == second.entityId),
      );
      final names = (await recordings.list(noteId)).map((e) => e.name).toSet();
      expect(names, {'녹음 3', '녹음 4'});
    },
  );

  test('leaving the app while start waits for permission cancels it', () async {
    backend.whileAsking = () => send(AppLifecycleState.paused);
    expect(await recorder.start(noteId), RecorderStartResult.cancelled);
    expect(backend.calls, isNot(contains('start')));
    expect(recorder.state.value, RecorderState.idle);
    expect(keepScreenOn.where((on) => on), isEmpty);
    expect(leftovers(), isEmpty);
  });

  test(
    'leaving the app while the recorder starts stops and saves at once',
    () async {
      backend.whileStarting = () => send(AppLifecycleState.paused);
      final published = nextResult();
      expect(await recorder.start(noteId), RecorderStartResult.cancelled);
      final result = await published;
      expect(result.saved, isTrue);
      expect(result.leftApp, isTrue);
      expect(backend.calls.last, 'stop');
      expect(recorder.state.value, RecorderState.idle);
      expect(keepScreenOn, [true, false]);
      expect(await recordings.list(noteId), hasLength(1));
      expect(leftovers(), isEmpty);
    },
  );

  test('leaving the app with a failing save reports the audio kept', () async {
    await recorder.start(noteId);
    clock = const Duration(seconds: 6);
    side.beforeCommit = () async => throw const FileSystemException('full');
    final published = nextResult();
    await send(AppLifecycleState.paused);
    final result = await published;
    expect(result.saved, isFalse);
    expect(result.leftApp, isTrue);
    expect(result.noteId, noteId);
    expect(recorder.pendingCount.value, 1);

    side.beforeCommit = null;
    final listed = await recorder.list(noteId);
    expect(listed.single.duration, const Duration(seconds: 6));
    expect(recorder.pendingCount.value, 0);
  });

  test('listing while a stop is saving leaves the save to the stop', () async {
    final listing = <Future<List<RecordingEntry>>>[];
    await recorder.dispose();
    recorder = NoteRecorder(
      recordings: recordings,
      backend: backend,
      directory: () async => recordingFolder,
      clock: () => clock,
      now: () => startedAt,
      keepScreenOn: (on) async {
        keepScreenOn.add(on);
        // The screen is let go right after the recorder stops: list in the gap before the save.
        if (!on) listing.add(recorder.list(noteId));
      },
    );
    await recorder.start(noteId);
    clock = const Duration(seconds: 5);
    final result = await recorder.stop();
    await Future.wait(listing);
    expect(listing, hasLength(1));
    expect(result?.saved, isTrue);
    expect(result!.entry!.duration, const Duration(seconds: 5));
    final all = await recordings.list(noteId);
    expect(all.single.duration, const Duration(seconds: 5));
    expect(leftovers(), isEmpty);
  });

  test(
    'an unreadable capture JSON keeps its audio, counts it and logs severe',
    () async {
      final records = <LogRecord>[];
      final subscription = Logger.root.onRecord.listen(records.add);
      addTearDown(subscription.cancel);
      await recordingFolder.create(recursive: true);
      final audio = File('${recordingFolder.path}/broken.m4a')
        ..writeAsBytesSync([1, 2, 3]);
      File('${recordingFolder.path}/broken.json').writeAsStringSync('');

      expect(await recorder.list(noteId), isEmpty);
      expect(audio.existsSync(), isTrue);
      expect(recorder.pendingCount.value, 1);
      expect(
        records.where(
          (r) => r.level == Level.SEVERE && r.message.contains('broken'),
        ),
        isNotEmpty,
      );

      // A start also leaves it alone.
      expect(await recorder.start(noteId), RecorderStartResult.started);
      await recorder.stop();
      expect(audio.existsSync(), isTrue);
      expect(await recordings.list(noteId), hasLength(1));
    },
  );

  test(
    'disposing while recording stops, saves and turns the screen back on',
    () async {
      await recorder.start(noteId);
      clock = const Duration(seconds: 7);
      await recorder.dispose();
      expect(backend.calls.last, 'stop');
      expect(keepScreenOn.last, isFalse);
      expect(
        (await recordings.list(noteId)).single.duration,
        const Duration(seconds: 7),
      );
      expect(leftovers(), isEmpty);
      recorder = newRecorder();
    },
  );

  test('another recorder leaves a recording in progress alone', () async {
    await recorder.start(noteId);
    final other = newRecorder();
    addTearDown(other.dispose);
    expect(await other.list(noteId), isEmpty);
    expect(other.pendingCount.value, 0);
    expect(File(backend.path!).existsSync(), isTrue);
    clock = const Duration(seconds: 2);
    final result = await recorder.stop();
    expect(result?.entry?.duration, const Duration(seconds: 2));
    expect(await recordings.list(noteId), hasLength(1));
  });

  test('leaving the app after the last check but before the microphone opens cancels the start', () async {
    await recorder.dispose();
    recorder = NoteRecorder(
      recordings: recordings,
      backend: backend,
      directory: () async => recordingFolder,
      clock: () => clock,
      now: () => startedAt,
      keepScreenOn: (on) async {
        keepScreenOn.add(on);
        // Held here, after the last check and before the capture is written: the app goes away.
        if (on && keepScreenOn.length == 1) {
          await send(AppLifecycleState.paused);
        }
      },
    );
    expect(await recorder.start(noteId), RecorderStartResult.cancelled);
    expect(backend.calls, isNot(contains('start')));
    expect(keepScreenOn, [true, false]);
    expect(recorder.state.value, RecorderState.idle);
    expect(await side.list(noteId, NoteSideKind.recording), isEmpty);
    expect(leftovers(), isEmpty);
    expect(recorder.pendingCount.value, 0);

    // The next start after a cancelled one records.
    await send(AppLifecycleState.resumed);
    expect(await recorder.start(noteId), RecorderStartResult.started);
    expect((await recorder.stop())?.saved, isTrue);
  });

  test(
    'the start after one cancelled while asking for permission records',
    () async {
      backend.whileAsking = () => send(AppLifecycleState.paused);
      expect(await recorder.start(noteId), RecorderStartResult.cancelled);
      backend.whileAsking = null;
      await send(AppLifecycleState.resumed);
      expect(await recorder.start(noteId), RecorderStartResult.started);
      clock = const Duration(seconds: 1);
      expect(
        (await recorder.stop())?.entry?.duration,
        const Duration(seconds: 1),
      );
    },
  );

  test(
    'two recorders saving the same kept recording at once add it once',
    () async {
      await recorder.start(noteId);
      clock = const Duration(seconds: 3);
      side.beforeCommit = () async => throw const FileSystemException('full');
      expect((await recorder.stop())?.saved, isFalse);
      side.beforeCommit = null;

      final other = newRecorder();
      addTearDown(other.dispose);
      await Future.wait([recorder.list(noteId), other.list(noteId)]);
      expect(await recordings.list(noteId), hasLength(1));
      expect(leftovers(), isEmpty);
    },
  );
}
