import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart'
    show FlutterQuillLocalizations;
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/components/ink_ui/audio/record_pill.dart';
import 'package:saber/components/ink_ui/editor_toolbar/kit_editor_toolbar.dart';
import 'package:saber/components/ink_ui/editor_toolbar/toolbar_tools_layout.dart';
import 'package:saber/components/ink_ui/side_panel/kit_side_panel.dart';
import 'package:saber/components/kit/kit_icon.dart';
import 'package:saber/components/kit/kit_motion.dart';
import 'package:saber/components/kit/kit_tokens.dart';
import 'package:saber/components/kit/kit_undo_notice.dart';
import 'package:saber/data/actions/app_action.dart';
import 'package:saber/data/actions/app_action_ids.dart';
import 'package:saber/data/actions/app_action_registry.dart';
import 'package:saber/data/audio/note_player.dart';
import 'package:saber/data/audio/note_recorder.dart';
import 'package:saber/data/audio/recording_entry.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/vault/note_side_store.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/editor/editor.dart';
import 'package:saber/pages/editor/editor_chrome.dart';
import 'package:saber/pages/editor/editor_side_host.dart';
import 'package:sbn/read_only_reason.dart';
import 'package:sbn/tool_id.dart';

import '../audio/fake_audio_backends.dart';
import '../utils/paint_counts.dart';
import '../utils/test_mock_channel_handlers.dart';
import '../workspace/infinite_canvas_harness.dart' as infinite;

/// The note's recordings, whose note looks gone while [shut]: a save then
/// fails and the recording is kept to save later.
class _Gate extends NoteRecordings {
  new(super.store, this.shut);
  final bool Function() shut;

  @override
  Future<bool> noteIsLive(String noteId) async =>
      !shut() && await super.noteIsLive(noteId);
}

/// The toolbar's record button and the recording pill (supplement Task 12,
/// 12th draft `#extras12`: `tbHtml` `data-a="rec"`, `recHtml`, `.r1rec`,
/// `stopRec`, `#r1=recon`, `recpause`, `recdone`, `rec360`).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();

  late FakeRecorderBackend mic;
  var saveFails = false;
  var saveChecks = 0;
  late NoteRecorder recorder;
  late List<bool> screenOn;
  late Directory folder;
  late NoteSideBinding vault;
  var clock = Duration.zero;

  setUp(() async {
    setupMockPathProvider();
    setupMockPrinting();
    setupMockWindowManager();
    await FileManager.init();
    final saved = (
      stows.lastTool.value,
      stows.lastPenFamily.value,
      stows.editorToolbarTools.value,
      stows.pageToolbarLayout.value,
    );
    stows.lastTool.value = ToolId.fountainPen;
    stows.lastPenFamily.value = ToolId.fountainPen;
    stows.editorToolbarTools.value = const [];
    stows.pageToolbarLayout.value = const [];
    stows.editorGestureMode.value = false;
    addTearDown(() {
      stows.lastTool.value = saved.$1;
      stows.lastPenFamily.value = saved.$2;
      stows.editorToolbarTools.value = saved.$3;
      stows.pageToolbarLayout.value = saved.$4;
    });
  });

  /// Lets the vault's and the recorder's file work run outside the fake
  /// time, then builds a frame in it (so the timers the frame makes are
  /// fake ones).
  Future<void> drain(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 15)),
    );
    await tester.pump();
  }

  /// Drains until [done].
  Future<void> until(
    WidgetTester tester,
    bool Function() done,
    String what,
  ) async {
    for (var i = 0; i < 300 && !done(); i++) {
      await drain(tester);
    }
    expect(done(), isTrue, reason: what);
  }

  /// A format 2 vault with one note and no recordings; the recorder keeps
  /// its files in [folder].
  Future<NoteSideBinding> openVault(WidgetTester tester) async {
    final made = await tester.runAsync(() async {
      final temp = await Directory.systemTemp.createTemp('piv-record-');
      final repository = await NoteRepository.open(
        Directory('${temp.path}/vault'),
        createFormatVersion: 2,
      );
      final id = (await WorkspaceStore(repository).create('Record')).id;
      return (repository, id, temp, NoteSideStore(repository));
    });
    // closed from the fake time: the editor's vault work waits in its queue
    addTearDown(() async {
      var closed = false;
      unawaited(
        made!.$1
            .close()
            .timeout(const Duration(seconds: 10))
            .whenComplete(() => closed = true),
      );
      await until(tester, () => closed, 'the vault closes');
      await tester.runAsync(() => made.$3.delete(recursive: true));
    });
    folder = Directory('${made!.$3.path}/recordings');
    return vault = (store: made.$4, noteId: made.$2);
  }

  /// The [recorder] on [mic], its clock [clock], its saves failing while
  /// [saveFails] (each save looks at it, counted in [saveChecks]), keeping the screen on into [screenOn]; the device records
  /// unless not [android].
  void useRecorder({bool android = true}) {
    mic = FakeRecorderBackend();
    screenOn = [];
    clock = Duration.zero;
    saveFails = false;
    saveChecks = 0;
    EditorAudioHost.debugAndroid = android;
    EditorAudioHost.debugNewRecorder = (recordings, beforeStart) =>
        recorder = NoteRecorder(
          recordings: _Gate(recordings.store, () {
            saveChecks++;
            return saveFails;
          }),
          backend: mic,
          directory: () async => folder,
          clock: () => clock,
          now: () => DateTime(2026, 11, 27, 15, 20),
          keepScreenOn: (on) async => screenOn.add(on),
          beforeStart: beforeStart,
        );
    addTearDown(() {
      EditorAudioHost.debugAndroid = null;
      EditorAudioHost.debugNewRecorder = null;
    });
  }

  /// The app [open] built, built again at another size.
  late Widget Function(Size size) app;

  /// The editor on a note at [path] of [size], in a format 2 vault unless
  /// not [vault]; [readOnly] like a note of a newer app.
  Future<EditorState> open(
    WidgetTester tester,
    String path, {
    Size size = const Size(1000, 1400),
    bool vault = true,
    bool readOnly = false,
  }) async {
    final binding = vault ? await openVault(tester) : null;
    final chrome = EditorChromeController()..noteSide = () => binding;
    addTearDown(chrome.dispose);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final core = EditorCoreInfo(
      filePath: path,
      readOnlyReason: readOnly ? ReadOnlyReason.versionTooNew : null,
    )..pages.add(EditorPage());
    app = (size) => MediaQuery(
      data: MediaQueryData(size: size),
      child: TranslationProvider(
        child: MaterialApp(
          localizationsDelegates: const [FlutterQuillLocalizations.delegate],
          home: Editor(
            path: path,
            loadSnapshot: () async => core,
            onSaveSnapshot: (_, _) async {},
            chrome: chrome,
          ),
        ),
      ),
    );
    await tester.pumpWidget(app(size));
    await tester.pumpAndSettle();
    final editor = tester.state<EditorState>(find.byType(Editor));
    if (vault) {
      await until(
        tester,
        () => !editor.side.audio.loading,
        'the recordings are read',
      );
    }
    await tester.pump();
    return editor;
  }

  Future<void> close(WidgetTester tester, EditorState editor) async {
    editor.cancelAutosaveAndMarkSaved();
    await tester.pumpWidget(const SizedBox());
    for (var i = 0; i < 10; i++) {
      await drain(tester);
    }
  }

  Future<void> send(AppLifecycleState value) =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            SystemChannels.lifecycle.name,
            SystemChannels.lifecycle.codec.encodeMessage(value.toString()),
            (_) {},
          );

  final recordButton = find.byKey(const ValueKey('editor-record'));
  final recordLine = find.byKey(const ValueKey('editor-record-line'));
  final mark = find.byKey(const ValueKey('editor-record-mark'));
  final pill = find.byKey(const ValueKey('kit-record-pill'));
  final dot = find.byKey(const ValueKey('kit-record-dot'));
  final pause = find.byKey(const ValueKey('kit-record-pause'));
  final stop = find.byKey(const ValueKey('kit-record-stop'));
  final notice = find.byKey(const ValueKey('kit-undo-notice'));
  Finder inPill(Finder of) => find.descendant(of: pill, matching: of);
  Color? colourOf(WidgetTester tester, Finder box) =>
      (tester.widget<DecoratedBox>(box).decoration as BoxDecoration).color;
  String? labelOf(WidgetTester tester, Finder button) =>
      tester.getSemantics(button).label;

  testWidgets('the record button shows on Android in a format 2 vault only, '
      'and not on an infinite note', (tester) async {
    useRecorder();
    var editor = await open(tester, '/record-shown');
    expect(recordButton, findsOneWidget);
    expect(recordLine, findsOneWidget);
    expect(labelOf(tester, recordButton), '녹음 시작');
    expect(editor.actions.lookup(AppActionIds.record)?.icon, KitIconName.mic);
    // after ⌄, past a thin line, at the end of the middle
    final more = tester.getRect(
      find.byKey(const ValueKey('editor-tools-more')),
    );
    final line = tester.getRect(recordLine);
    final button = tester.getRect(recordButton);
    expect(line.left, greaterThan(more.right - 1));
    expect(button.left, greaterThan(line.right - 1));
    expect(
      tester.getRect(find.byKey(const ValueKey('editor-insert-page'))).left,
      greaterThan(button.right - 1),
    );
    expect(mark, findsNothing);
    await close(tester, editor);

    // not Android
    useRecorder(android: false);
    editor = await open(tester, '/record-not-android');
    expect(recordButton, findsNothing);
    expect(recordLine, findsNothing);
    expect(editor.actions.lookup(AppActionIds.record), isNull);
    await close(tester, editor);

    // no vault holding recordings
    useRecorder();
    editor = await open(tester, '/record-no-vault', vault: false);
    expect(recordButton, findsNothing);
    expect(editor.actions.lookup(AppActionIds.record), isNull);
    await close(tester, editor);

    // the infinite note: its own bar has no record button
    infinite.resetInkSettings();
    await infinite.mount(tester);
    expect(find.byType(KitEditorToolbar), findsOneWidget);
    expect(recordButton, findsNothing);

    // a bar with its own tools leaves it out even when it is published
    final actions = AppActionRegistry();
    addTearDown(actions.dispose);
    final open0 = ValueNotifier(false);
    addTearDown(open0.dispose);
    actions.publish(Object(), [
      for (final id in [AppActionIds.toolPen, AppActionIds.record])
        AppAction(id: id, label: id, icon: KitIconName.mic, run: (_) {}),
    ]);
    Future<void> bar(List<ToolbarTool>? tools) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: KitEditorToolbar(
            actions: actions,
            title: 'x',
            floatingBarOpen: open0,
            tools: tools,
          ),
        ),
      ),
    );
    await bar([toolbarToolOf('pen')]);
    await tester.pump();
    expect(recordButton, findsNothing);
    await bar(null);
    await tester.pump();
    expect(recordButton, findsOneWidget);
  });

  testWidgets('start, pause, resume and stop; 「보기」 opens the audio tab', (
    tester,
  ) async {
    useRecorder();
    final editor = await open(tester, '/record-flow');
    expect(pill, findsNothing);

    await tester.tap(recordButton);
    await until(tester, () => pill.evaluate().isNotEmpty, 'the pill shows');
    await tester.pump();
    expect(mic.calls, ['hasPermission', 'start']);
    expect(inPill(find.text('녹음 중')), findsOneWidget);
    expect(inPill(find.text('00:00')), findsOneWidget);
    // the top right of the page area, 10 in; 44 high (`.r1rec`)
    final area = tester.getRect(find.byType(EditorRecordPillLayer));
    final at = tester.getRect(pill);
    expect(at.top - area.top, 10);
    expect(area.right - at.right, 10);
    expect(at.height, 44);
    expect(tester.getSize(pause), const Size(36, 36));
    expect(colourOf(tester, dot), KitTokens.recRed);
    expect(labelOf(tester, pause), '일시 정지');
    expect(labelOf(tester, stop), '녹음 멈춤');
    // the toolbar's button: a red mark, and pressed again it stops
    expect(colourOf(tester, mark), KitTokens.recMarkOn);
    expect(labelOf(tester, recordButton), '녹음 멈춤');

    // the clock: whole seconds of what was recorded
    clock = const Duration(seconds: 42, milliseconds: 600);
    await tester.pump(const Duration(milliseconds: 250));
    expect(inPill(find.text('00:42')), findsOneWidget);

    // paused: grey and still, the clock stands
    await tester.tap(pause);
    await tester.pump();
    await tester.pump();
    expect(mic.calls, ['hasPermission', 'start', 'pause']);
    expect(inPill(find.text('일시 정지')), findsOneWidget);
    expect(colourOf(tester, dot), KitTokens.recDotPaused);
    expect(labelOf(tester, pause), '이어서 녹음');
    expect(colourOf(tester, mark), KitTokens.recMarkPaused);
    clock = const Duration(seconds: 50);
    await tester.pump(const Duration(seconds: 1));
    expect(inPill(find.text('00:42')), findsOneWidget);

    // on again, from where it stood (42.6 + 2.4)
    await tester.tap(pause);
    await tester.pump();
    expect(mic.calls, ['hasPermission', 'start', 'pause', 'resume']);
    expect(inPill(find.text('녹음 중')), findsOneWidget);
    expect(colourOf(tester, mark), KitTokens.recMarkOn);
    clock = const Duration(seconds: 52, milliseconds: 400);
    await tester.pump(const Duration(milliseconds: 250));
    expect(inPill(find.text('00:45')), findsOneWidget);

    await tester.tap(stop);
    await until(
      tester,
      () => find.text('오디오 탭에 넣었습니다 · 녹음 1').evaluate().isNotEmpty,
      'the notice says where it went',
    );
    await tester.pump(KitMotion.undoNoticeIn);
    expect(mic.calls.last, 'stop');
    expect(pill, findsNothing);
    expect(mark, findsNothing);
    expect(
      find.descendant(of: notice, matching: find.text('보기')),
      findsOneWidget,
    );
    expect(editor.side.panelOpen.value, isFalse);

    await tester.tap(find.text('보기'));
    await until(
      tester,
      () => find.text('새 녹음').evaluate().isNotEmpty,
      'the audio tab shows the new recording',
    );
    expect(editor.side.panelOpen.value, isTrue);
    expect(editor.side.tab.value, KitSideTab.audio);
    expect(find.text('녹음 1'), findsOneWidget);
    expect(find.text('00:45 · 11월 27일 오후 3:20'), findsOneWidget);
    await tester.pump(
      KitMotion.undoNoticeOut + const Duration(milliseconds: 1),
    );
    expect(notice, findsNothing);
    await close(tester, editor);
  });

  testWidgets('leaving the app stops and saves; back, it says so', (
    tester,
  ) async {
    useRecorder();
    final editor = await open(tester, '/record-left');
    addTearDown(() => send(AppLifecycleState.resumed));
    await tester.tap(recordButton);
    await until(tester, () => pill.evaluate().isNotEmpty, 'the pill shows');
    clock = const Duration(seconds: 7);
    await tester.pump(const Duration(milliseconds: 250));

    await send(AppLifecycleState.paused);
    await until(
      tester,
      () => editor.side.audio.rows.length == 1,
      'the recording is saved',
    );
    await tester.pump();
    expect(mic.calls.last, 'stop');
    expect(pill, findsNothing);
    // away, no notice is shown (no frames are drawn: ask the notice itself)
    expect(editor.side.notice.notice, isNull);

    await send(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump(KitMotion.undoNoticeIn);
    expect(find.text('앱을 벗어나 녹음을 멈추고 저장했습니다'), findsOneWidget);
    expect(find.text('오디오 탭에 넣었습니다 · 녹음 1'), findsNothing);
    await tester.tap(find.text('보기'));
    await until(
      tester,
      () => find.text('새 녹음').evaluate().isNotEmpty,
      'the audio tab shows the new recording',
    );
    expect(editor.side.tab.value, KitSideTab.audio);
    expect(find.text('00:07 · 11월 27일 오후 3:20'), findsOneWidget);
    await close(tester, editor);
  });

  testWidgets('while recording the screen is kept on', (tester) async {
    useRecorder();
    final editor = await open(tester, '/record-screen');
    expect(screenOn, isEmpty);
    await tester.tap(recordButton);
    await until(tester, () => pill.evaluate().isNotEmpty, 'the pill shows');
    expect(screenOn, [true]);
    await tester.tap(pause);
    await tester.pump();
    expect(screenOn, [true]);
    await tester.tap(stop);
    await until(
      tester,
      () => editor.side.audio.rows.length == 1,
      'the recording is saved',
    );
    expect(screenOn, [true, false]);
    await close(tester, editor);
  });

  testWidgets('the pill clock going on paints no page and no toolbar', (
    tester,
  ) async {
    useRecorder();
    final editor = await open(tester, '/record-paint');
    await tester.tap(recordButton);
    await until(tester, () => pill.evaluate().isNotEmpty, 'the pill shows');
    await tester.pump();
    await tester.pump();

    RenderRepaintBoundary boundary(Finder of) =>
        tester.renderObject<RenderRepaintBoundary>(
          find.descendant(of: of, matching: find.byType(RepaintBoundary)).first,
        );
    final page =
        editor.coreInfo.pages.first.innerCanvasKey.currentContext!
                .findRenderObject()!
            as RenderRepaintBoundary;
    final toolbar = boundary(find.byType(KitEditorToolbar));
    final shown = boundary(find.byType(KitRecordPill));
    final pillWidget = find.descendant(
      of: find.byType(EditorRecordPillLayer),
      matching: find.byType(KitRecordPill),
    );
    final toolbarBuilt = tester.widget(find.byType(KitEditorToolbar));
    final pillBuilt = tester.widget(pillWidget);
    final pageBefore = paintCounts(page);
    final toolbarBefore = paintCounts(toolbar);
    final pillBefore = shown.debugAsymmetricPaintCount;
    for (var s = 1; s <= 5; s++) {
      clock = Duration(seconds: s);
      await tester.pump(const Duration(seconds: 1));
      expect(inPill(find.text('00:0$s')), findsOneWidget);
    }
    expect(shown.debugAsymmetricPaintCount, greaterThan(pillBefore));
    expectNotPainted(page, pageBefore);
    expectNotPainted(toolbar, toolbarBefore);
    // the clock builds the pill's time only (decision 6)
    expect(
      identical(tester.widget(find.byType(KitEditorToolbar)), toolbarBuilt),
      isTrue,
    );
    expect(identical(tester.widget(pillWidget), pillBuilt), isTrue);

    await tester.tap(stop);
    await until(
      tester,
      () => editor.side.audio.rows.length == 1,
      'the recording is saved',
    );
    await close(tester, editor);
  });

  testWidgets('on a phone the toolbar slides to the record button', (
    tester,
  ) async {
    useRecorder();
    final editor = await open(
      tester,
      '/record-phone',
      size: const Size(360, 740),
    );
    final scroll = find.byKey(const ValueKey('editor-tools-scroll'));
    ScrollPosition position() => tester
        .state<ScrollableState>(
          find.descendant(of: scroll, matching: find.byType(Scrollable)),
        )
        .position;
    expect(position().pixels, 0);
    final view = tester.getRect(scroll);
    expect(tester.getRect(recordButton).right, greaterThan(view.right));

    unawaited(editor.side.audio.toggleRecording());
    await until(tester, () => pill.evaluate().isNotEmpty, 'the pill shows');
    await tester.pump();
    expect(position().pixels, greaterThan(0));
    final button = tester.getRect(recordButton);
    expect(button.left, greaterThanOrEqualTo(view.left));
    expect(button.right, lessThanOrEqualTo(view.right));
    final area = tester.getRect(find.byType(EditorRecordPillLayer));
    expect(area.right - tester.getRect(pill).right, 10);

    await tester.tap(stop);
    await until(
      tester,
      () => editor.side.audio.rows.length == 1,
      'the recording is saved',
    );
    await close(tester, editor);
  });

  testWidgets('a refused microphone or a failed start says so', (tester) async {
    useRecorder();
    final editor = await open(tester, '/record-refused');
    final messenger = ScaffoldMessenger.of(tester.element(find.byType(Editor)));
    mic.permission = false;
    await tester.tap(recordButton);
    await until(
      tester,
      () => find.text('녹음하려면 마이크 권한을 허용해 주세요.').evaluate().isNotEmpty,
      'the refusal is said',
    );
    expect(pill, findsNothing);
    expect(screenOn, isEmpty);
    messenger.removeCurrentSnackBar();
    await tester.pump();

    mic
      ..permission = true
      ..startError = const FileSystemException('busy');
    await tester.tap(recordButton);
    await until(
      tester,
      () => find.text('녹음을 시작하지 못했습니다.').evaluate().isNotEmpty,
      'the failure is said',
    );
    expect(pill, findsNothing);
    expect(mic.path, isNull);
    messenger.removeCurrentSnackBar();
    await close(tester, editor);
  });

  testWidgets('recording pauses the listening, which does not play on', (
    tester,
  ) async {
    useRecorder();
    final speaker = FakePlayerBackend();
    EditorAudioHost.debugNewPlayer = (read) => NotePlayer(
      readAudio: read,
      backend: speaker,
      directory: () async => Directory('${folder.parent.path}/playback'),
    );
    addTearDown(() => EditorAudioHost.debugNewPlayer = null);
    final editor = await open(tester, '/record-listen');
    final audio = editor.side.audio;
    final lecture = (await tester.runAsync(
      () => NoteRecordings(vault.store).add(
        vault.noteId,
        audio: Uint8List.fromList([1, 2, 3, 4]),
        duration: const Duration(minutes: 3),
        createdAt: DateTime(2026, 11, 27, 14, 5),
      ),
    ))!;
    unawaited(audio.recordingSaved(lecture));
    await until(tester, () => audio.rows.length == 1, 'the list is read');
    audio.listen(lecture.entityId);
    await until(
      tester,
      () => audio.player.state.value == PlayerState.playing,
      'it plays',
    );

    await tester.tap(recordButton);
    await until(tester, () => pill.evaluate().isNotEmpty, 'the pill shows');
    expect(audio.player.state.value, PlayerState.paused);
    expect(speaker.calls.last, 'pause');
    // while it records, neither the bar nor the row plays
    final heard = speaker.calls.length;
    audio.playPause();
    audio.listen(lecture.entityId);
    await drain(tester);
    expect(speaker.calls, hasLength(heard));
    expect(audio.player.state.value, PlayerState.paused);

    await tester.tap(stop);
    await until(tester, () => audio.rows.length == 2, 'the recording is saved');
    // stopped, it plays again
    audio.playPause();
    await until(
      tester,
      () => audio.player.state.value == PlayerState.playing,
      'it plays again',
    );
    await close(tester, editor);
  });

  const saveFailed = '녹음을 저장하지 못했습니다. 녹음은 기기에 남아 있고 나중에 다시 저장합니다.';

  testWidgets('a save that fails says so once, after leaving the app when '
      'it is back', (tester) async {
    useRecorder();
    final editor = await open(tester, '/record-save-fails');
    final messenger = ScaffoldMessenger.of(tester.element(find.byType(Editor)));
    final failed = find.text(saveFailed);
    Future<void> saidOnce() async {
      expect(failed, findsOneWidget);
      messenger.removeCurrentSnackBar();
      for (var i = 0; i < 5; i++) {
        await drain(tester);
      }
      expect(failed, findsNothing);
    }

    saveFails = true;
    await tester.tap(recordButton);
    await until(tester, () => pill.evaluate().isNotEmpty, 'the pill shows');
    await tester.tap(stop);
    await until(
      tester,
      () => failed.evaluate().isNotEmpty,
      'the failed save is said',
    );
    expect(recorder.pendingCount.value, 1);
    expect(pill, findsNothing);
    expect(editor.side.notice.notice, isNull);
    expect(editor.side.audio.rows, isEmpty);
    await saidOnce();

    // stopped by leaving the app: said when it is back, in place of
    // 「앱을 벗어나 녹음을 멈추고 저장했습니다」
    addTearDown(() => send(AppLifecycleState.resumed));
    await tester.tap(recordButton);
    await until(tester, () => pill.evaluate().isNotEmpty, 'the pill shows');
    await send(AppLifecycleState.paused);
    await until(
      tester,
      () => recorder.pendingCount.value == 2,
      'the second recording is kept',
    );
    expect(editor.side.notice.notice, isNull);
    await send(AppLifecycleState.resumed);
    await until(
      tester,
      () => failed.evaluate().isNotEmpty,
      'the failed save is said once back',
    );
    expect(find.text('앱을 벗어나 녹음을 멈추고 저장했습니다'), findsNothing);
    expect(editor.side.notice.notice, isNull);
    await saidOnce();
    await close(tester, editor);
  });

  testWidgets('a recording kept by a failed save is listed when the list is '
      'read again', (tester) async {
    useRecorder();
    final editor = await open(tester, '/record-kept');
    final audio = editor.side.audio;
    saveFails = true;
    await tester.tap(recordButton);
    await until(tester, () => pill.evaluate().isNotEmpty, 'the pill shows');
    clock = const Duration(seconds: 3);
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(stop);
    await until(
      tester,
      () => recorder.pendingCount.value == 1,
      'the recording is kept',
    );
    ScaffoldMessenger.of(tester.element(find.byType(Editor)))
        .removeCurrentSnackBar();
    expect(audio.rows, isEmpty);

    saveFails = false;
    unawaited(audio.reload());
    await until(
      tester,
      () => audio.rows.length == 1,
      'the kept recording is listed',
    );
    expect(audio.rows.single.title, '녹음 1');
    expect(audio.rows.single.length, const Duration(seconds: 3));
    expect(recorder.pendingCount.value, 0);
    await close(tester, editor);
  });

  for (final width in [1000.0, 360.0]) {
    testWidgets('on Android in a format 2 vault the infinite note\'s tools '
        'sit where the editor\'s do at $width', (tester) async {
      useRecorder();
      final size = Size(width, 740);
      List<double> xs() => [
        for (final id in ['lasso', 'pen', 'eraser'])
          tester.getCenter(find.byKey(ValueKey('editor-tool-$id'))).dx,
      ];
      final editor = await open(tester, '/record-x', size: size);
      expect(recordButton, findsOneWidget);
      final inEditor = xs();
      await close(tester, editor);

      infinite.resetInkSettings();
      await infinite.mount(tester, size: size, vaultKeepsAttachments: true);
      expect(recordButton, findsNothing);
      expect(xs(), inEditor);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('a listening still loading when recording starts does not play', (
    tester,
  ) async {
    useRecorder();
    final speaker = FakePlayerBackend();
    final loads = <Completer<void>>[];
    speaker.whileLoading = (_) {
      final load = Completer<void>();
      loads.add(load);
      return load.future;
    };
    EditorAudioHost.debugNewPlayer = (read) => NotePlayer(
      readAudio: read,
      backend: speaker,
      directory: () async => Directory('${folder.parent.path}/playback'),
    );
    addTearDown(() => EditorAudioHost.debugNewPlayer = null);
    final editor = await open(tester, '/record-loading');
    final audio = editor.side.audio;
    final lecture = (await tester.runAsync(
      () => NoteRecordings(vault.store).add(
        vault.noteId,
        audio: Uint8List.fromList([1, 2, 3, 4]),
        duration: const Duration(minutes: 3),
        createdAt: DateTime(2026, 11, 27, 14, 5),
      ),
    ))!;
    unawaited(audio.recordingSaved(lecture));
    await until(tester, () => audio.rows.length == 1, 'the list is read');

    // the load ends once it records
    audio.listen(lecture.entityId);
    await until(tester, () => loads.length == 1, 'it loads');
    expect(audio.player.state.value, PlayerState.loading);
    await tester.tap(recordButton);
    await until(tester, () => pill.evaluate().isNotEmpty, 'the pill shows');
    loads.last.complete();
    await until(
      tester,
      () => speaker.calls.contains('play'),
      'the load ends and it plays',
    );
    await drain(tester);
    expect(audio.player.state.value, isNot(PlayerState.playing));
    expect(speaker.calls.last, 'pause');
    await tester.tap(stop);
    await until(tester, () => audio.rows.length == 2, 'the recording is saved');

    // the load ends while the microphone is asked for
    audio.closeListening();
    await drain(tester);
    audio.listen(lecture.entityId);
    await until(tester, () => loads.length == 2, 'it loads again');
    final asking = Completer<void>();
    mic.whileAsking = () => asking.future;
    await tester.tap(recordButton);
    await until(
      tester,
      () => mic.calls.last == 'hasPermission',
      'the microphone is asked for',
    );
    loads.last.complete();
    await until(
      tester,
      () => audio.player.state.value == PlayerState.playing,
      'it plays before the microphone opens',
    );
    asking.complete();
    await until(tester, () => pill.evaluate().isNotEmpty, 'the pill shows');
    await drain(tester);
    expect(audio.player.state.value, isNot(PlayerState.playing));
    expect(speaker.calls.last, 'pause');
    await tester.tap(stop);
    await until(tester, () => audio.rows.length == 3, 'the recording is saved');
    await close(tester, editor);
  });

  testWidgets('while a recording is saved the record button takes no press', (
    tester,
  ) async {
    useRecorder();
    final editor = await open(tester, '/record-saving');
    await tester.tap(recordButton);
    await until(tester, () => pill.evaluate().isNotEmpty, 'the pill shows');
    final saving = Completer<void>();
    mic.whileStopping = () => saving.future;
    await tester.tap(stop);
    await until(tester, () => mic.calls.last == 'stop', 'it stops');
    await tester.pump();
    expect(pill, findsNothing);
    expect(mark, findsNothing);
    expect(editor.actions.lookup(AppActionIds.record)?.enabled, isFalse);
    await tester.tap(recordButton, warnIfMissed: false);
    await drain(tester);
    expect(mic.calls.where((call) => call == 'start'), hasLength(1));

    saving.complete();
    await until(
      tester,
      () => editor.side.audio.rows.length == 1,
      'the recording is saved',
    );
    await tester.pump();
    expect(editor.actions.lookup(AppActionIds.record)?.enabled, isTrue);
    await close(tester, editor);
  });

  testWidgets('narrowed to a phone while it records, the toolbar slides to '
      'the record button again', (tester) async {
    useRecorder();
    final editor = await open(tester, '/record-narrowed');
    final scroll = find.byKey(const ValueKey('editor-tools-scroll'));
    ScrollPosition position() => tester
        .state<ScrollableState>(
          find.descendant(of: scroll, matching: find.byType(Scrollable)),
        )
        .position;
    await tester.tap(recordButton);
    await until(tester, () => pill.evaluate().isNotEmpty, 'the pill shows');
    await tester.pump();
    expect(position().pixels, 0);

    const phone = Size(360, 740);
    tester.view.physicalSize = phone;
    await tester.pumpWidget(app(phone));
    await tester.pump();
    await tester.pump();
    expect(position().pixels, greaterThan(0));
    final view = tester.getRect(scroll);
    final button = tester.getRect(recordButton);
    expect(button.left, greaterThanOrEqualTo(view.left));
    expect(button.right, lessThanOrEqualTo(view.right));

    await tester.tap(stop);
    await until(
      tester,
      () => editor.side.audio.rows.length == 1,
      'the recording is saved',
    );
    await close(tester, editor);
  });

  testWidgets('a 1.6 s recording is 00:01 on the pill and in the list', (
    tester,
  ) async {
    useRecorder();
    final editor = await open(tester, '/record-length');
    await tester.tap(recordButton);
    await until(tester, () => pill.evaluate().isNotEmpty, 'the pill shows');
    clock = const Duration(milliseconds: 1600);
    await tester.pump(const Duration(milliseconds: 250));
    expect(inPill(find.text('00:01')), findsOneWidget);
    await tester.tap(stop);
    await until(
      tester,
      () => find.text('오디오 탭에 넣었습니다 · 녹음 1').evaluate().isNotEmpty,
      'the notice says where it went',
    );
    await tester.pump(KitMotion.undoNoticeIn);
    await tester.tap(find.text('보기'));
    await until(
      tester,
      () => find.text('새 녹음').evaluate().isNotEmpty,
      'the audio tab shows the new recording',
    );
    expect(find.text('00:01 · 11월 27일 오후 3:20'), findsOneWidget);
    await tester.pump(
      KitMotion.undoNoticeOut + const Duration(milliseconds: 1),
    );
    await close(tester, editor);
  });

  testWidgets('a read-only note has no record button; 「읽기 전용」 keeps it', (
    tester,
  ) async {
    useRecorder();
    var editor = await open(tester, '/record-read-only', readOnly: true);
    expect(editor.coreInfo.readOnly, isTrue);
    expect(recordButton, findsNothing);
    expect(editor.actions.lookup(AppActionIds.record), isNull);
    await close(tester, editor);

    // ⋯ 「읽기 전용」 locks the ink only: a recording is an attachment
    editor = await open(tester, '/record-ink-locked');
    editor.actions.run(
      AppActionIds.readOnly,
      tester.element(find.byType(Editor)),
    );
    await tester.pump();
    await tester.pump();
    expect(editor.inkLocked.value, isTrue);
    expect(recordButton, findsOneWidget);
    expect(editor.actions.lookup(AppActionIds.record)?.enabled, isTrue);
    await tester.tap(recordButton);
    await until(tester, () => pill.evaluate().isNotEmpty, 'the pill shows');
    await tester.tap(stop);
    await until(
      tester,
      () => editor.side.audio.rows.length == 1,
      'the recording is saved',
    );
    await close(tester, editor);
  });

  testWidgets('an empty recording, dropped, says nothing, after leaving the '
      'app too', (tester) async {
    useRecorder();
    final editor = await open(tester, '/record-empty');
    final audio = mic.audio;
    final failed = find.text(saveFailed);
    Future<void> settled() async {
      await until(
        tester,
        () => recorder.lastResult.value != null && !editor.side.audio.loading,
        'the recording is dropped',
      );
      for (var i = 0; i < 5; i++) {
        await drain(tester);
      }
    }

    await tester.tap(recordButton);
    await until(tester, () => pill.evaluate().isNotEmpty, 'the pill shows');
    // the encoder closes the file with nothing in it: the recorder deletes
    // the capture
    mic.audio = Uint8List(0);
    await tester.tap(stop);
    await settled();
    expect(recorder.lastResult.value?.entry, isNull);
    expect(recorder.pendingCount.value, 0);
    expect(failed, findsNothing);
    expect(editor.side.notice.notice, isNull);
    expect(editor.side.audio.rows, isEmpty);

    // stopped by leaving the app: nothing when it is back either
    addTearDown(() => send(AppLifecycleState.resumed));
    mic.audio = audio;
    await tester.tap(recordButton);
    await until(tester, () => pill.evaluate().isNotEmpty, 'the pill shows');
    mic.audio = Uint8List(0);
    final first = recorder.lastResult.value;
    await send(AppLifecycleState.paused);
    await until(
      tester,
      () => !identical(recorder.lastResult.value, first),
      'the second recording is dropped',
    );
    await send(AppLifecycleState.resumed);
    for (var i = 0; i < 5; i++) {
      await drain(tester);
    }
    await tester.pump(KitMotion.undoNoticeIn);
    expect(recorder.lastResult.value?.leftApp, isTrue);
    expect(recorder.pendingCount.value, 0);
    expect(failed, findsNothing);
    expect(find.text('앱을 벗어나 녹음을 멈추고 저장했습니다'), findsNothing);
    expect(editor.side.notice.notice, isNull);
    await close(tester, editor);
  });

  testWidgets('a save that fails once the note has closed says nothing', (
    tester,
  ) async {
    useRecorder();
    saveFails = true;
    final binding = await openVault(tester);
    final notice = KitUndoNoticeController();
    addTearDown(notice.dispose);
    final errors = <Object>[];
    final audio = EditorAudioHost(notice: notice, onError: errors.add);
    var closed = false;
    addTearDown(() {
      if (!closed) audio.dispose();
    });
    unawaited(audio.load(binding));
    await until(tester, () => !audio.loading, 'the recordings are read');
    Future<void> record() async {
      unawaited(audio.toggleRecording());
      await until(tester, () => audio.recordingOn, 'it records');
    }

    // one kept while the note is open, said (the recorder's pending count
    // is no longer kept once it is disposed: this keeps it above 0)
    await record();
    unawaited(audio.toggleRecording());
    await until(tester, () => errors.isNotEmpty, 'the failed save is said');
    expect(recorder.pendingCount.value, 1);
    errors.clear();

    await record();
    final saving = Completer<void>();
    mic.whileStopping = () => saving.future;
    unawaited(audio.toggleRecording());
    await until(tester, () => mic.calls.last == 'stop', 'it stops');

    // the note closes while the recording is being saved
    final checks = saveChecks;
    audio.dispose();
    closed = true;
    saving.complete();
    await until(tester, () => saveChecks > checks, 'the save is tried');
    for (var i = 0; i < 10; i++) {
      await drain(tester);
    }
    expect(
      folder.listSync().where((file) => file.path.endsWith('.m4a')),
      hasLength(2),
      reason: 'the failed saves keep both recordings',
    );
    expect(errors, isEmpty);
    expect(notice.notice, isNull);
  });

  // The infinite note's middle is centred in the editor's middle width
  // while that fits (`editorMiddle <= maxWidth`), else from its start. On
  // Android in a format 2 vault with the default tools, editorMiddle is
  // 37 (필기) + 12 (line) + 7 × 37 (6 tools and ⌄) + 12 + 37 (녹음) = 357;
  // the middle gets the width less 2 × 6.5 (padding) and 5 × 37 (쪽 목록 ·
  // 노트 창, 노트 추가 · 전체 화면 · ⋯), so it fits from 555 wide.
  for (final (width, slides) in [(554.0, true), (556.0, false)]) {
    testWidgets('on Android in a format 2 vault the infinite note\'s tools '
        'sit where the editor\'s do at $width, by the fit at 555', (
      tester,
    ) async {
      useRecorder();
      final size = Size(width, 740);
      List<double> xs() => [
        for (final id in ['lasso', 'pen', 'eraser'])
          tester.getCenter(find.byKey(ValueKey('editor-tool-$id'))).dx,
      ];
      double slide() => tester
          .state<ScrollableState>(
            find.descendant(
              of: find.byKey(const ValueKey('editor-tools-scroll')),
              matching: find.byType(Scrollable),
            ),
          )
          .position
          .maxScrollExtent;
      final editor = await open(tester, '/record-fit', size: size);
      expect(recordButton, findsOneWidget);
      // the editor's middle slides below 555 only (the fit computed above)
      expect(slide() > 0, slides);
      final inEditor = xs();
      await close(tester, editor);

      infinite.resetInkSettings();
      await infinite.mount(tester, size: size, vaultKeepsAttachments: true);
      expect(xs(), inEditor);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
