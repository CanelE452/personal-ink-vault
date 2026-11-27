import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:saber/components/ink_ui/audio/listen_bar.dart';
import 'package:saber/components/ink_ui/audio/record_pill.dart';
import 'package:saber/components/ink_ui/side_panel/audio_tab.dart';
import 'package:saber/components/kit/kit_tokens.dart';
import 'package:saber/components/kit/kit_undo_notice.dart';
import 'package:saber/data/audio/note_player.dart';
import 'package:saber/data/audio/note_recorder.dart';
import 'package:saber/data/audio/recording_entry.dart';
import 'package:saber/data/user_error.dart';
import 'package:saber/pages/editor/editor_chrome.dart';

/// The note's recordings beside the editor (the left panel's audio tab) and
/// the listening bar, apart from the editor's state so that none of it
/// builds the page again; the left panel's host owns it.
///
/// The recordings are read by [load], again by [reload] (the tab coming into
/// sight) and after [recordingSaved]; the list keeps their order, newest
/// first. A rename is shown at once and written after the recording work
/// before it. A removed recording's row goes at once, and the recording is
/// marked deleted only when the undo [notice] goes unpressed (by itself, for
/// another notice, when the panel closes ([panelClosed]) or when this is
/// disposed); 「실행 취소」 brings the row back. A row press plays the
/// recording in the listening bar ([player]); playing that fails says so
/// ([onError]) once for each failure.
///
/// On Android it records the note too (supplement Task 12): one recorder
/// for the editor, made on the first [toggleRecording]. Starting pauses the
/// listening, and while it records the listening does not play (the
/// microphone would hear it). A stopped recording goes into the list,
/// marked new, and the notice says so with 「보기」 ([showTab]); one stopped
/// by leaving the app says so when the app is back. A save that fails says
/// so ([onError]) the same way: the recorder keeps the audio and saves it
/// when the list is read again ([reload]). Disposed (the note closes or
/// another opens), it stops and saves what was recorded, and says nothing.
class EditorAudioHost extends ChangeNotifier {
  new({required this.notice, required this.onError, this.showTab}) {
    listening.addListener(_listeningChanged);
  }

  /// The undo notice over the page area, shared with the outline.
  final KitUndoNoticeController notice;

  /// A rename or a removal could not be saved, a recording not played, or
  /// recording could not start or be saved.
  final void Function(Object error) onError;

  /// Opens the left panel on the audio tab (the notice's 「보기」).
  final VoidCallback? showTab;

  /// Whether this device records (Android); null asks the platform.
  @visibleForTesting
  static bool? debugAndroid;

  /// Makes the recorder (on the `record` plugin when null).
  @visibleForTesting
  static NoteRecorder Function(
    NoteRecordings recordings,
    Future<void> Function() beforeStart,
  )?
  debugNewRecorder;

  /// Whether this device records: Android only (supplement design).
  static bool get recordsHere => debugAndroid ?? Platform.isAndroid;

  /// Whether a recording runs ([KitRecording]).
  final recording = ValueNotifier(KitRecording.off);

  /// The recording pill as drawn (the quick note keeps out of its way).
  final recordPill = GlobalKey();

  bool get recordingOn => switch (recording.value) {
    KitRecording.on || KitRecording.paused => true,
    KitRecording.off || KitRecording.saving => false,
  };

  /// A stopped recording is being saved: 「녹음 시작」 takes no press.
  bool get savingRecording => recording.value == KitRecording.saving;

  NoteRecorder? _recorder;

  /// Waits for the app to come back, to say a recording stopped by leaving.
  AppLifecycleListener? _back;

  /// The recorder, made when first asked once the note's recordings are
  /// known ([load]); null before.
  NoteRecorder? get _recorderNow {
    final recordings = _recordings;
    if (_disposed || recordings == null) return null;
    if (_recorder case final recorder?) return recorder;
    Future<void> beforeStart() async {
      // the microphone would hear what plays
      if (_player?.state.value == PlayerState.playing) await _player!.pause();
    }

    final recorder =
        debugNewRecorder?.call(recordings, beforeStart) ??
        NoteRecorder(recordings: recordings, beforeStart: beforeStart);
    recorder.state.addListener(_recorderMoved);
    recorder.lastResult.addListener(_stopped);
    return _recorder = recorder;
  }

  void _recorderMoved() {
    if (_disposed) return;
    recording.value = switch (_recorder?.state.value) {
      RecorderState.recording => KitRecording.on,
      RecorderState.paused => KitRecording.paused,
      RecorderState.saving => KitRecording.saving,
      RecorderState.idle || null => KitRecording.off,
    };
    _hushWhileRecording();
  }

  /// The microphone would hear what plays: a listening that began to play
  /// while recording started (it was loading) pauses.
  void _hushWhileRecording() {
    if (recordingOn && _player?.state.value == PlayerState.playing) {
      unawaited(_player!.pause());
    }
  }

  /// 「녹음 시작」 or 「녹음 멈춤」. A refused microphone and a start that
  /// fails say so; a start given up (the app went away) says nothing.
  Future<void> toggleRecording() async {
    final recorder = _recorderNow;
    final binding = _binding;
    if (recorder == null || binding == null) return;
    switch (recorder.state.value) {
      case RecorderState.idle:
        final result = await recorder.start(binding.noteId);
        if (_disposed) return;
        switch (result) {
          case RecorderStartResult.permissionDenied:
            onError(StateError('녹음하려면 마이크 권한을 허용해 주세요.'));
          case RecorderStartResult.failed:
            onError(StateError('녹음을 시작하지 못했습니다.'));
          case RecorderStartResult.started ||
              RecorderStartResult.busy ||
              RecorderStartResult.cancelled:
            break;
        }
      case RecorderState.recording || RecorderState.paused:
        await recorder.stop();
      case RecorderState.saving:
        break;
    }
  }

  /// The pill's pause or resume button.
  void pauseOrResumeRecording() {
    final recorder = _recorder;
    switch (recorder?.state.value) {
      case RecorderState.recording:
        unawaited(recorder!.pause());
      case RecorderState.paused:
        unawaited(recorder!.resume());
      case _:
        break;
    }
  }

  /// A recording stopped ([NoteRecorder.lastResult]): the notice says where
  /// it went, or a failed save says so (the recorder keeps the audio and
  /// saves it later). An empty one, dropped, says nothing. Stopped by
  /// leaving the app, it is said when the app is back.
  void _stopped() {
    final recorder = _recorder;
    final result = recorder?.lastResult.value;
    if (_disposed || recorder == null || result == null) return;
    final entry = result.entry;
    // no entry and nothing kept: the audio was empty and is gone
    if (entry == null && recorder.pendingCount.value == 0) return;
    if (entry != null) unawaited(recordingSaved(entry));
    void say() {
      if (_disposed) return;
      if (entry == null) {
        onError(StateError(_saveFailed));
      } else {
        _sayWhere(
          result.leftApp ? _leftAppNotice : '오디오 탭에 넣었습니다 · ${entry.name}',
        );
      }
    }

    if (!result.leftApp ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      say();
    } else {
      _back?.dispose();
      _back = AppLifecycleListener(
        onResume: () {
          _back?.dispose();
          _back = null;
          say();
        },
      );
    }
  }

  static const _leftAppNotice = '앱을 벗어나 녹음을 멈추고 저장했습니다';
  static const _saveFailed = '녹음을 저장하지 못했습니다. 녹음은 기기에 남아 있고 나중에 다시 저장합니다.';

  void _sayWhere(String text) {
    if (_disposed) return;
    notice.show(text, action: '보기', onAction: showTab);
  }

  /// Makes the player (on `just_audio` when null).
  @visibleForTesting
  static NotePlayer Function(
    Future<Uint8List> Function(RecordingEntry entry) readAudio,
  )?
  debugNewPlayer;

  /// The recording whose name is being changed (its entity id).
  final renaming = ValueNotifier<String?>(null);

  /// The recording in the listening bar.
  final listening = ValueNotifier<RecordingEntry?>(null);

  /// The listening speed ([NotePlayer.speeds]).
  final speed = ValueNotifier(NotePlayer.speeds.first);

  /// The room the listening bar takes at the foot of the page area while it
  /// is there ([KitTokens.listenFootRoom]): the page flip bar and the end of
  /// the audio tab's list stand over it.
  final footRoom = ValueNotifier(0.0);

  NoteSideBinding? _binding;
  NoteRecordings? _recordings;
  var _list = const <RecordingEntry>[];
  var _read = false;

  /// Removed, their undo notice not gone yet, by entity id.
  final _removing = <String, RecordingEntry>{};

  /// Removed, their deletion being written.
  final _deleting = <String>{};

  /// New names shown while they are written, by entity id.
  final _renamed = <String, String>{};

  /// The entity id of the recording just saved and not listened to yet.
  String? _fresh;
  ({String id, String title})? _draft;
  List<KitAudioRow>? _rows;
  Future<void> _work = Future.value();
  NotePlayer? _player;
  var _disposed = false;

  /// Reads the recordings of the note [binding] names (a format 2 vault).
  Future<void> load(NoteSideBinding binding) {
    _binding = binding;
    _recordings = NoteRecordings(binding.store);
    return reload();
  }

  /// The player of the listening bar, made when first asked.
  NotePlayer get player {
    if (_player case final player?) return player;
    Future<Uint8List> read(RecordingEntry entry) =>
        _recordings!.readAudio(entry);
    final player = debugNewPlayer?.call(read) ?? NotePlayer(readAudio: read);
    player.state.addListener(_stateChanged);
    return _player = player;
  }

  /// The player moved on; into [PlayerState.error] it failed (it moves
  /// there once for each failure).
  void _stateChanged() {
    if (_disposed) return;
    if (_player?.state.value == PlayerState.error) {
      onError(StateError('녹음을 재생하지 못했습니다.'));
    }
    _hushWhileRecording();
    _changed();
  }

  void _listeningChanged() =>
      footRoom.value = listening.value == null ? 0 : KitTokens.listenFootRoom;

  /// The audio tab's rows: the note's recordings, newest first, without the
  /// removed ones. Asked again with nothing changed, the same list.
  List<KitAudioRow> get rows {
    final shown = listening.value?.entityId;
    final playing = switch (_player?.state.value) {
      PlayerState.playing || PlayerState.loading => true,
      _ => false,
    };
    return _rows ??= [
      for (final entry in _list)
        if (!_removing.containsKey(entry.entityId) &&
            !_deleting.contains(entry.entityId))
          KitAudioRow(
            id: entry.entityId,
            title: _renamed[entry.entityId] ?? entry.name,
            length: entry.duration,
            madeAt: entry.createdAt,
            listening: entry.entityId == shown,
            playing: entry.entityId == shown && playing,
            fresh: entry.entityId == _fresh,
          ),
    ];
  }

  /// The recordings have not been read yet (the note's favourites may be
  /// read before them).
  bool get loading => !_read;

  /// Reads the recordings again, after the recording work before; the
  /// recorder, once made, saves first what a failed save of this note kept.
  Future<void> reload() {
    final recordings = _recordings;
    final binding = _binding;
    if (recordings == null || binding == null) return Future.value();
    return _work = _work.then((_) async {
      try {
        _list =
            await (_recorder?.list(binding.noteId) ??
                recordings.list(binding.noteId));
      } catch (error, stackTrace) {
        logUserError(error, stackTrace);
      }
      _read = true;
      _changed();
    });
  }

  /// Ends the splits two devices made of the note's recordings
  /// ([NoteRecordings.joinSplits]), after the recording work before, and
  /// reads them again if one was written.
  Future<void> joinSplits() async {
    final recordings = _recordings;
    final binding = _binding;
    if (recordings == null || binding == null) return;
    var joined = false;
    await (_work = _work.then((_) async {
      try {
        joined = await recordings.joinSplits(binding.noteId);
      } catch (error, stackTrace) {
        logUserError(error, stackTrace);
      }
    }));
    if (joined && !_disposed) await reload();
  }

  /// A recording of the note was just saved (the recorder's `lastResult`):
  /// the list is read again, [entry] marked 「새 녹음」 until it is listened
  /// to.
  Future<void> recordingSaved(RecordingEntry entry) {
    if (entry.noteId != _binding?.noteId) return Future.value();
    _fresh = entry.entityId;
    return reload();
  }

  RecordingEntry? _recording(String id) =>
      _list.where((entry) => entry.entityId == id).firstOrNull;

  /// A press on the row of [id]: plays it in the listening bar, or pauses
  /// or plays the one already there. Nothing where the device cannot play.
  void listen(String id) {
    final entry = _recording(id);
    if (entry == null || !player.supported || recordingOn) return;
    if (_fresh == id) _fresh = null;
    if (listening.value?.entityId == id) {
      playPause();
    } else {
      listening.value = entry;
      unawaited(player.play(entry));
    }
    _changed();
  }

  /// The listening bar's play button: pauses, or plays from where it is.
  void playPause() {
    final entry = listening.value;
    if (entry == null || recordingOn) return;
    unawaited(
      player.state.value == PlayerState.playing
          ? player.pause()
          : player.play(entry),
    );
  }

  void seekTo(Duration position) => unawaited(player.seek(position));

  /// Steps the speed (1, 1.25, 1.5, 2, 0.75, then 1 again).
  void cycleSpeed() => speed.value = player.cycleSpeed();

  /// Closes the listening bar: playing stops.
  void closeListening() {
    if (listening.value == null) return;
    listening.value = null;
    _changed();
    unawaited(player.close());
  }

  /// [title] has been typed into the name of the recording [id].
  void renameDraft(String id, String title) => _draft = (id: id, title: title);

  /// Ends the change of [id]'s name: it is [title] unless that is empty or
  /// the same.
  Future<void> rename(String id, String title) {
    if (renaming.value == id) renaming.value = null;
    _draft = null;
    final name = title.trim();
    final recordings = _recordings;
    final entry = _recording(id);
    if (recordings == null || entry == null || name.isEmpty) {
      return Future.value();
    }
    if ((_renamed[id] ?? entry.name) == name) return Future.value();
    _renamed[id] = name;
    _changed();
    return _work = _work.then((_) async {
      try {
        // the entry as the work before left it
        final renamed = await recordings.rename(_recording(id) ?? entry, name);
        _list = [
          for (final e in _list)
            if (e.entityId == id) renamed else e,
        ];
        if (!_disposed && listening.value?.entityId == id) {
          listening.value = renamed;
        }
      } catch (error, stackTrace) {
        logUserError(error, stackTrace);
        onError(StateError('녹음 이름을 저장하지 못했습니다. 다시 바꿔 주세요.'));
      }
      if (_renamed[id] == name) _renamed.remove(id);
      _changed();
    });
  }

  /// 「지우기」: the row goes, and so does the listening bar if it plays it;
  /// the undo notice can bring the row back. The recording is marked
  /// deleted when the notice goes unpressed.
  void remove(String id) {
    final entry = _recording(id);
    if (_recordings == null || entry == null) return;
    if (listening.value?.entityId == id) closeListening();
    _removing[id] = entry;
    _changed();
    notice.show(
      KitTokens.removedNotice(_renamed[id] ?? entry.name),
      onAction: () {
        if (_removing.remove(id) != null) _changed();
      },
      onEnd: () => _delete(id),
    );
  }

  /// Marks the removed recording [id] deleted, after the recording work
  /// before; if that fails its row comes back.
  void _delete(String id) {
    final entry = _removing.remove(id);
    final recordings = _recordings;
    if (entry == null || recordings == null) return;
    _deleting.add(id);
    _work = _work.then((_) async {
      try {
        await recordings.delete(_recording(id) ?? entry);
        _list = [
          for (final e in _list)
            if (e.entityId != id) e,
        ];
      } catch (error, stackTrace) {
        logUserError(error, stackTrace);
        onError(StateError('녹음을 지우지 못했습니다.'));
      }
      _deleting.remove(id);
      _changed();
    });
  }

  /// The left panel closed: a removed recording's notice ends (and the
  /// recording goes), and a name being changed keeps what was typed, as a
  /// press outside the field keeps it.
  void panelClosed() {
    if (_removing.isNotEmpty) notice.hide();
    keepRenameDraft(renaming, _draft, rename);
  }

  /// Done when every recording read and write started so far is.
  Future<void> get idle async {
    for (var work = _work; ; work = _work) {
      await work;
      if (identical(work, _work)) return;
    }
  }

  /// The rows may have changed; the editor's actions do not show them.
  void _changed() {
    if (_disposed) return;
    _rows = null;
    notifyListeners();
  }

  @override
  void dispose() {
    // the note closes: its removed recordings go, and a name being changed
    // keeps what was typed (as when the panel closes)
    _removing.keys.toList().forEach(_delete);
    keepRenameDraft(renaming, _draft, rename);
    _disposed = true;
    _back?.dispose();
    // and what is being recorded is stopped and saved, unheard
    if (_recorder case final recorder?) {
      recorder.state.removeListener(_recorderMoved);
      recorder.lastResult.removeListener(_stopped);
      unawaited(recorder.dispose());
    }
    recording.dispose();
    renaming.dispose();
    listening.dispose();
    speed.dispose();
    footRoom.dispose();
    if (_player case final player?) {
      player.state.removeListener(_stateChanged);
      unawaited(player.dispose());
    }
    super.dispose();
  }
}

/// The left panel closed while [renaming] names a row: what was typed into
/// it ([draft]) is kept by [rename], as a press outside the field keeps it;
/// with nothing typed into it the change just ends.
void keepRenameDraft(
  ValueNotifier<String?> renaming,
  ({String id, String title})? draft,
  Future<void> Function(String id, String title) rename,
) {
  final id = renaming.value;
  if (id == null) return;
  if (draft case (id: final draftId, :final title) when draftId == id) {
    unawaited(rename(id, title));
  } else {
    renaming.value = null;
  }
}

/// The listening bar over the editor's page area (`.r1play`) while [audio]
/// has a recording in it. It follows the player on its own: a new position
/// builds the bar only, not the editor, the page or the left panel.
class EditorListenBarLayer extends StatelessWidget {
  const new({super.key, required this.audio});

  final EditorAudioHost audio;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) => ValueListenableBuilder(
      valueListenable: audio.listening,
      builder: (context, entry, _) {
        if (entry == null) return const SizedBox.shrink();
        final player = audio.player;
        return ListenableBuilder(
          listenable: Listenable.merge([
            player.state,
            player.position,
            audio.speed,
          ]),
          builder: (context, _) => KitListenBar(
            title: entry.name,
            position: player.position.value,
            length: entry.duration,
            playing: switch (player.state.value) {
              PlayerState.playing || PlayerState.loading => true,
              _ => false,
            },
            speed: audio.speed.value,
            phone: box.maxWidth < KitTokens.sidePanelPhoneBelow,
            enabled: player.supported,
            onPlayPause: audio.playPause,
            onSeek: audio.seekTo,
            onSpeed: audio.cycleSpeed,
            onClose: audio.closeListening,
          ),
        );
      },
    ),
  );
}

/// The recording pill over the editor's page area (`.r1rec`) while [audio]
/// records. It follows the recorder on its own: the time moving builds the
/// pill's time only, not the editor, the page or the toolbar.
class EditorRecordPillLayer extends StatelessWidget {
  const new({super.key, required this.audio});

  final EditorAudioHost audio;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: audio.recording,
    builder: (context, state, _) {
      final recorder = audio._recorder;
      if (!audio.recordingOn || recorder == null) {
        return const SizedBox.shrink();
      }
      return KitRecordPill(
        boxKey: audio.recordPill,
        paused: state == KitRecording.paused,
        elapsed: recorder.elapsed,
        onPauseResume: audio.pauseOrResumeRecording,
        onStop: () => unawaited(audio.toggleRecording()),
      );
    },
  );
}
