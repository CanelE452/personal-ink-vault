import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter_quill/flutter_quill.dart'
    show FlutterQuillLocalizations;
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/components/ink_ui/side_panel/audio_tab.dart';
import 'package:saber/components/ink_ui/side_panel/kit_side_panel.dart';
import 'package:saber/components/kit/kit_motion.dart';
import 'package:saber/components/kit/kit_text.dart';
import 'package:saber/components/kit/kit_tokens.dart';
import 'package:saber/data/audio/note_player.dart';
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
import 'package:sbn/tool_id.dart';

import '../utils/paint_counts.dart';
import '../utils/test_mock_channel_handlers.dart';

/// A player that plays nothing and keeps what it was asked.
class _Backend implements PlayerBackend {
  new({this.supported = true});

  @override
  final bool supported;
  final calls = <String>[];
  final speeds = <double>[];
  final seeks = <Duration>[];
  late void Function(Duration position) onPosition;
  late void Function() onCompleted;
  late void Function(String path, Object error, StackTrace stack) onFailed;

  /// Thrown by [load] when set.
  Object? loadError;

  /// The files loaded, in order.
  final loads = <String>[];

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
    if (loadError case final error?) throw error;
    loads.add(path);
  }

  @override
  Future<void> play() async => calls.add('play');

  @override
  Future<void> pause() async => calls.add('pause');

  @override
  Future<void> seek(Duration position) async => seeks.add(position);

  @override
  Future<void> setSpeed(double speed) async => speeds.add(speed);

  @override
  Future<void> stop() async => calls.add('stop');

  @override
  Future<void> dispose() async => calls.add('dispose');
}

/// The left panel's audio tab and the listening bar (supplement Task 11,
/// 12th draft `#extras12`: `arow`, `playHtml`, `.r1au`, `.r1play`).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();

  final audio = Uint8List.fromList([1, 2, 3, 4]);

  /// Lets the vault's file work run between frames.
  Future<void> drain(WidgetTester tester) async {
    await tester.runAsync(() async {
      for (var i = 0; i < 12; i++) {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 15));
      }
    });
    await tester.pump(const Duration(milliseconds: 50));
  }

  /// Runs [work] (the vault's file work) while frames go on.
  Future<T> settle<T>(WidgetTester tester, Future<T> Function() work) async {
    late T value;
    var done = false;
    await tester.runAsync(() async {
      unawaited(
        work().then((v) {
          value = v;
          done = true;
        }),
      );
    });
    for (var i = 0; i < 40 && !done; i++) {
      await drain(tester);
    }
    expect(done, isTrue, reason: 'the vault work finished');
    return value;
  }

  /// A format 2 vault with one note holding the draft's recordings (`AU0`):
  /// 「녹음 1」 12:48 from 11월 20일 오전 10:02 and 「3주차 강의」 41:05 from
  /// 11월 27일 오후 2:05; and a folder for the player's files.
  Future<(NoteSideBinding, Directory)> openVault(WidgetTester tester) async {
    final made = await tester.runAsync(() async {
      final temp = await Directory.systemTemp.createTemp('piv-audio-');
      final repository = await NoteRepository.open(
        Directory('${temp.path}/vault'),
        createFormatVersion: 2,
      );
      final id = (await WorkspaceStore(repository).create('Audio')).id;
      final store = NoteSideStore(repository);
      final recordings = NoteRecordings(store);
      await recordings.add(
        id,
        audio: audio,
        duration: const Duration(minutes: 12, seconds: 48),
        createdAt: DateTime(2026, 11, 20, 10, 2),
      );
      final lecture = await recordings.add(
        id,
        audio: audio,
        duration: const Duration(minutes: 41, seconds: 5),
        createdAt: DateTime(2026, 11, 27, 14, 5),
      );
      await recordings.rename(lecture, '3주차 강의');
      return (repository, id, temp, store);
    });
    addTearDown(
      () => settle(tester, () async {
        await made!.$1.close().timeout(const Duration(seconds: 10));
        await made.$3.delete(recursive: true);
      }),
    );
    return ((store: made!.$4, noteId: made.$2), made.$3);
  }

  /// The names of the note's live recordings, newest first, once every
  /// write [host] has started is done.
  Future<List<String>> stored(
    WidgetTester tester,
    EditorSideHost host,
    NoteSideBinding binding,
  ) async {
    await settle(tester, () => host.idle);
    return settle(
      tester,
      () async => [
        for (final entry in await NoteRecordings(
          binding.store,
        ).list(binding.noteId))
          entry.name,
      ],
    );
  }

  /// Makes the host's player on [backend], its files in [temp].
  void usePlayer(_Backend backend, Directory temp) {
    EditorAudioHost.debugNewPlayer = (read) => NotePlayer(
      readAudio: read,
      backend: backend,
      directory: () async => Directory('${temp.path}/playback'),
    );
    addTearDown(() => EditorAudioHost.debugNewPlayer = null);
  }

  /// The left panel on its audio tab over a page area of [size], with the
  /// listening bar and the undo notice over it, as the editor lays them. The
  /// host has read the vault unless not [loaded]; what it says went wrong
  /// goes to [onError] (failing the test when null). The test ends by
  /// disposing it, unless not [disposeAfter].
  Future<EditorSideHost> mount(
    WidgetTester tester, {
    required NoteSideBinding binding,
    required Directory temp,
    required _Backend backend,
    Size size = const Size(586, 734),
    bool loaded = true,
    void Function(Object error)? onError,
    bool disposeAfter = true,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    usePlayer(backend, temp);
    final core = EditorCoreInfo(filePath: '/audio-tab')
      ..pages.add(EditorPage(pageId: 'p0'));
    final host = EditorSideHost(
      binding: () => binding,
      saveNote: (_) async {},
      pages: () => core.pages,
      pageOnScreen: () => 0,
      pageMoves: const AlwaysStoppedAnimation(0),
      onChanged: () {},
      onError: onError ?? (error) => fail('$error'),
    );
    if (disposeAfter) addTearDown(host.dispose);
    if (loaded) await settle(tester, host.load);
    host.tab.value = KitSideTab.audio;
    host.togglePanel();
    await tester.pumpWidget(
      MediaQuery(
        data: MediaQueryData(size: size),
        child: MaterialApp(
          home: Material(
            child: Stack(
              children: [
                Positioned.fill(
                  child: EditorSidePanelLayer(
                    host: host,
                    coreInfo: core,
                    goTo: (_) {},
                    managePage: (_) {},
                  ),
                ),
                Positioned.fill(child: EditorListenBarLayer(audio: host.audio)),
                Positioned.fill(child: KitUndoNotice(controller: host.notice)),
              ],
            ),
          ),
        ),
      ),
    );
    await drain(tester);
    await tester.pumpAndSettle();
    return host;
  }

  Finder row(String title) => find.ancestor(
    of: find.text(title),
    matching: find.byWidgetPredicate(
      (w) =>
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('kit-audio-row-'),
    ),
  );
  Finder inRow(String title, String key) =>
      find.descendant(of: row(title), matching: find.byKey(ValueKey(key)));
  final bar = find.byKey(const ValueKey('kit-listen-bar'));
  Finder inBar(Finder of) => find.descendant(of: bar, matching: of);
  final speed = find.byKey(const ValueKey('kit-listen-speed'));
  final track = find.byKey(const ValueKey('kit-listen-track'));
  final rename = find.byKey(const ValueKey('kit-audio-rename'));
  final notice = find.byKey(const ValueKey('kit-undo-notice'));

  /// Presses [finder] outside the fake time: the player writes a file.
  Future<void> press(WidgetTester tester, Finder finder) async {
    await tester.runAsync(() => tester.tap(finder));
    await drain(tester);
    await tester.pump();
  }

  /// The colour of the play circle of [title]'s row.
  Color? circle(WidgetTester tester, String title) =>
      (tester
                  .widget<DecoratedBox>(
                    find
                        .descendant(
                          of: inRow(title, 'kit-audio-play'),
                          matching: find.byType(DecoratedBox),
                        )
                        .first,
                  )
                  .decoration
              as BoxDecoration)
          .color;

  testWidgets('the list: newest first, its name, length and date', (
    tester,
  ) async {
    final (binding, temp) = await openVault(tester);
    final backend = _Backend();
    final host = await mount(
      tester,
      binding: binding,
      temp: temp,
      backend: backend,
    );
    expect(find.text('이 노트의 녹음'), findsOneWidget);
    expect(find.text('2개'), findsOneWidget);
    expect(
      tester.getTopLeft(row('3주차 강의')).dy,
      lessThan(tester.getTopLeft(row('녹음 1')).dy),
    );
    expect(
      find.descendant(
        of: row('3주차 강의'),
        matching: find.text('41:05 · 11월 27일 오후 2:05'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: row('녹음 1'),
        matching: find.text('12:48 · 11월 20일 오전 10:02'),
      ),
      findsOneWidget,
    );
    expect(tester.getSize(row('녹음 1')).height, KitTokens.audioRowHeight);
    expect(KitTokens.audioRowHeight, 60);
    expect(tester.getSize(inRow('녹음 1', 'kit-audio-play')).width, 36);
    expect(find.text(keepWords('녹음을 누르면 아래에 듣기 막대가 뜹니다.')), findsOneWidget);
    expect(find.text('새 녹음'), findsNothing);

    // a recording just saved (Task 12 calls this): read again, marked new
    final made = await settle(
      tester,
      () => NoteRecordings(binding.store).add(
        binding.noteId,
        audio: audio,
        duration: const Duration(seconds: 42),
        createdAt: DateTime(2026, 11, 27, 15, 20),
      ),
    );
    host.audio.recordingSaved(made);
    await settle(tester, () => host.idle);
    await tester.pumpAndSettle();
    expect(find.text('3개'), findsOneWidget);
    expect(made.name, '녹음 3');
    expect(
      tester.getTopLeft(row('녹음 3')).dy,
      lessThan(tester.getTopLeft(row('3주차 강의')).dy),
    );
    expect(
      find.descendant(of: row('녹음 3'), matching: find.text('새 녹음')),
      findsOneWidget,
    );
    expect(find.text('새 녹음'), findsOneWidget);
    expect(
      find.descendant(
        of: row('녹음 3'),
        matching: find.text('00:42 · 11월 27일 오후 3:20'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('a press opens the listening bar; it plays, pauses, closes', (
    tester,
  ) async {
    final (binding, temp) = await openVault(tester);
    final backend = _Backend();
    final host = await mount(
      tester,
      binding: binding,
      temp: temp,
      backend: backend,
    );
    final made = await settle(
      tester,
      () => NoteRecordings(binding.store).add(
        binding.noteId,
        audio: audio,
        duration: const Duration(seconds: 42),
        createdAt: DateTime(2026, 11, 27, 15, 20),
      ),
    );
    host.audio.recordingSaved(made);
    await settle(tester, () => host.idle);
    await tester.pumpAndSettle();
    expect(bar, findsNothing);
    expect(circle(tester, '3주차 강의'), KitTokens.audioPlayBg);

    await press(tester, row('3주차 강의'));
    expect(bar, findsOneWidget);
    expect(backend.calls, containsAllInOrder(['load', 'play']));
    expect(inBar(find.text('3주차 강의')), findsOneWidget);
    expect(inBar(find.text('00:00')), findsOneWidget);
    expect(inBar(find.text('41:05')), findsOneWidget);
    // the row in the bar is lit, its circle the accent
    expect(circle(tester, '3주차 강의'), KitTokens.accent);
    expect(circle(tester, '녹음 1'), KitTokens.audioPlayBg);
    expect(find.bySemanticsLabel('3주차 강의 일시 정지'), findsOneWidget);

    // listened once, the new mark goes
    await press(tester, row('녹음 3'));
    expect(inBar(find.text('녹음 3')), findsOneWidget);
    expect(find.text('새 녹음'), findsNothing);
    expect(circle(tester, '3주차 강의'), KitTokens.audioPlayBg);

    // the bar's button pauses and plays
    backend.calls.clear();
    await press(tester, find.byKey(const ValueKey('kit-listen-play')));
    expect(backend.calls, ['pause']);
    expect(find.bySemanticsLabel('재생'), findsOneWidget);
    await press(tester, find.byKey(const ValueKey('kit-listen-play')));
    expect(backend.calls, ['pause', 'play']);
    expect(find.bySemanticsLabel('일시 정지'), findsOneWidget);
    // a press on the row in the bar pauses too
    await press(tester, row('녹음 3'));
    expect(backend.calls, ['pause', 'play', 'pause']);

    await press(tester, find.byKey(const ValueKey('kit-listen-close')));
    await tester.pumpAndSettle();
    expect(bar, findsNothing);
    expect(backend.calls.last, 'stop');
    expect(host.audio.player.current.value, isNull);
  });

  testWidgets(
    'the bar sits 12 over the foot, 470 wide; a phone hides the name',
    (tester) async {
      for (final size in const [Size(586, 734), Size(360, 600)]) {
        final (binding, temp) = await openVault(tester);
        final host = await mount(
          tester,
          binding: binding,
          temp: temp,
          backend: _Backend(),
          size: size,
        );
        await press(tester, row('녹음 1'));
        final rect = tester.getRect(bar);
        final phone = size.width < KitTokens.sidePanelPhoneBelow;
        expect(rect.height, KitTokens.playerBarHeight, reason: '$size');
        expect(KitTokens.playerBarHeight, 54);
        expect(rect.bottom, size.height - 12, reason: '$size');
        expect(rect.width, phone ? 344 : 470, reason: '$size');
        expect(rect.center.dx, size.width / 2, reason: '$size');
        expect(
          inBar(find.text('녹음 1')),
          phone ? findsNothing : findsOneWidget,
          reason: '$size',
        );
        // the undo notice stands over it
        host.notice.show(KitTokens.removedNotice('3주차 강의'));
        await tester.pump();
        await tester.pump(KitMotion.undoNoticeIn);
        final shown = tester.getRect(notice);
        expect(shown.overlaps(rect), isFalse, reason: '$size: $shown $rect');
        expect(shown.bottom, lessThanOrEqualTo(rect.top), reason: '$size');
        host.notice.hide();
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox());
        await drain(tester);
      }
    },
  );

  testWidgets('the speed button steps 1, 1.25, 1.5, 2, 0.75, 1', (
    tester,
  ) async {
    final (binding, temp) = await openVault(tester);
    final backend = _Backend();
    await mount(tester, binding: binding, temp: temp, backend: backend);
    await press(tester, row('3주차 강의'));
    expect(inBar(find.text('1×')), findsOneWidget);
    final labels = <String>[];
    for (var i = 0; i < 5; i++) {
      await tester.tap(speed);
      await tester.pump();
      labels.add(
        (tester.widget<Text>(
          find.descendant(of: speed, matching: find.byType(Text)),
        )).data!,
      );
    }
    expect(labels, ['1.25×', '1.5×', '2×', '0.75×', '1×']);
    await tester.runAsync(() async {});
    expect(backend.speeds, [1.0, 1.25, 1.5, 2.0, 0.75, 1.0]);
    expect(find.bySemanticsLabel('재생 속도 1×'), findsOneWidget);
  });

  testWidgets('the track follows the position; dragging it seeks', (
    tester,
  ) async {
    final (binding, temp) = await openVault(tester);
    final backend = _Backend();
    await mount(tester, binding: binding, temp: temp, backend: backend);
    await press(tester, row('3주차 강의'));
    backend.onPosition(const Duration(minutes: 9, seconds: 2));
    await tester.pump();
    expect(inBar(find.text('09:02')), findsOneWidget);

    const length = Duration(minutes: 41, seconds: 5);
    final box = tester.getRect(track);
    // from the left end to the middle
    await tester.timedDragFrom(
      box.centerLeft + const Offset(1, 0),
      Offset(box.width / 2 - 1, 0),
      const Duration(milliseconds: 300),
    );
    await tester.pump();
    await tester.runAsync(() async {});
    expect(backend.seeks, isNotEmpty);
    expect(
      backend.seeks.last.inMilliseconds,
      closeTo(length.inMilliseconds / 2, 1000),
    );
    expect(inBar(find.text(kitAudioClock(backend.seeks.last))), findsOneWidget);

    // a tap a quarter in goes there, and only there
    backend.seeks.clear();
    await tester.tapAt(box.centerLeft + Offset(box.width / 4, 0));
    await tester.pump();
    await tester.runAsync(() async {});
    expect(backend.seeks, hasLength(1), reason: '${backend.seeks}');
    expect(
      backend.seeks.single.inMilliseconds,
      closeTo(length.inMilliseconds / 4, 1000),
    );
  });

  testWidgets('a recording is renamed, and removed with the undo notice', (
    tester,
  ) async {
    final (binding, temp) = await openVault(tester);
    final backend = _Backend();
    final host = await mount(
      tester,
      binding: binding,
      temp: temp,
      backend: backend,
    );

    await tester.tap(inRow('녹음 1', 'kit-audio-more'));
    await tester.pumpAndSettle();
    expect(find.text('지우기'), findsOneWidget);
    await tester.tap(find.text('이름 바꾸기'));
    await tester.pumpAndSettle();
    expect(rename, findsOneWidget);
    expect(tester.widget<TextField>(rename).controller!.text, '녹음 1');
    expect(find.bySemanticsLabel('녹음 이름'), findsOneWidget);
    await tester.enterText(rename, '세미나');
    await tester.tap(find.text('완료'));
    await tester.pumpAndSettle();
    expect(rename, findsNothing);
    expect(find.text('세미나'), findsOneWidget);
    expect(await stored(tester, host, binding), ['3주차 강의', '세미나']);

    // removed: the row goes at once, the recording only when the notice goes
    await tester.tap(inRow('세미나', 'kit-audio-more'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('지우기'));
    await tester.pump();
    await tester.pump(KitMotion.undoNoticeIn);
    expect(row('세미나'), findsNothing);
    expect(find.text('1개'), findsOneWidget);
    expect(notice, findsOneWidget);
    expect(find.text('지웠습니다 · 세미나'), findsOneWidget);
    expect(await stored(tester, host, binding), ['3주차 강의', '세미나']);
    await tester.tap(find.text(KitTokens.undoNoticeAction));
    await tester.pumpAndSettle();
    expect(row('세미나'), findsOneWidget);
    expect(await stored(tester, host, binding), ['3주차 강의', '세미나']);

    // removed again and left: gone when the notice goes by itself
    await tester.tap(inRow('세미나', 'kit-audio-more'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('지우기'));
    await tester.pump();
    await tester.pump(
      KitMotion.undoNoticeShow +
          KitMotion.undoNoticeOut +
          const Duration(milliseconds: 1),
    );
    expect(notice, findsNothing);
    expect(await stored(tester, host, binding), ['3주차 강의']);
    await tester.pumpAndSettle();
    expect(row('세미나'), findsNothing);

    // one being listened to: the bar closes; closing the panel ends the
    // notice, and the recording goes
    await press(tester, row('3주차 강의'));
    expect(bar, findsOneWidget);
    await tester.tap(inRow('3주차 강의', 'kit-audio-more'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('지우기'));
    await tester.pump();
    await tester.pumpAndSettle(const Duration(milliseconds: 50));
    expect(bar, findsNothing);
    expect(backend.calls.last, 'stop');
    expect(await stored(tester, host, binding), ['3주차 강의']);
    host.togglePanel();
    await tester.pump();
    expect(await stored(tester, host, binding), isEmpty);
    await tester.pumpAndSettle();
    expect(notice, findsNothing);
  });

  testWidgets('where the device cannot play, the play circles are dim', (
    tester,
  ) async {
    final (binding, temp) = await openVault(tester);
    final backend = _Backend(supported: false);
    final host = await mount(
      tester,
      binding: binding,
      temp: temp,
      backend: backend,
    );
    expect(row('3주차 강의'), findsOneWidget);
    expect(row('녹음 1'), findsOneWidget);
    for (final title in ['3주차 강의', '녹음 1']) {
      final dim = tester.widget<Opacity>(
        find
            .ancestor(
              of: inRow(title, 'kit-audio-play'),
              matching: find.byType(Opacity),
            )
            .first,
      );
      expect(dim.opacity, KitTokens.disabledOpacity, reason: title);
      // read out as a button that cannot be pressed
      expect(
        tester.getSemantics(find.bySemanticsLabel('$title 듣기')),
        isSemantics(isButton: true, hasEnabledState: true, isEnabled: false),
        reason: title,
      );
    }
    // the menu still works
    expect(inRow('녹음 1', 'kit-audio-more'), findsOneWidget);

    await press(tester, row('3주차 강의'));
    expect(bar, findsNothing);
    expect(backend.calls, isEmpty);
    expect(host.audio.listening.value, isNull);
  });

  /// [mount] with errors kept in [errors] (their messages).
  Future<EditorSideHost> mountKeeping(
    WidgetTester tester,
    List<String> errors, {
    required NoteSideBinding binding,
    required Directory temp,
    required _Backend backend,
  }) => mount(
    tester,
    binding: binding,
    temp: temp,
    backend: backend,
    onError: (error) => errors.add((error as StateError).message),
  );
  const failed = '녹음을 재생하지 못했습니다.';

  /// The player's [backend] hears playing [path] fail late.
  Future<void> failLate(WidgetTester tester, _Backend backend, String path) =>
      tester.runAsync(
        () async => backend.onFailed(
          path,
          const FileSystemException('decoder'),
          StackTrace.empty,
        ),
      );

  testWidgets('a recording that cannot be loaded says so once', (tester) async {
    final (binding, temp) = await openVault(tester);
    final backend = _Backend()..loadError = const FileSystemException('bad');
    final errors = <String>[];
    final host = await mountKeeping(
      tester,
      errors,
      binding: binding,
      temp: temp,
      backend: backend,
    );
    await press(tester, row('녹음 1'));
    await tester.pumpAndSettle();
    expect(host.audio.player.state.value, PlayerState.error);
    expect(errors, [failed]);
    await drain(tester);
    expect(errors, [failed]);
    expect(find.bySemanticsLabel('재생'), findsOneWidget);
  });

  testWidgets('playing that fails once started says so once', (tester) async {
    final (binding, temp) = await openVault(tester);
    final backend = _Backend();
    final errors = <String>[];
    final host = await mountKeeping(
      tester,
      errors,
      binding: binding,
      temp: temp,
      backend: backend,
    );
    await press(tester, row('녹음 1'));
    expect(host.audio.player.state.value, PlayerState.playing);
    await failLate(tester, backend, backend.loads.single);
    await drain(tester);
    expect(host.audio.player.state.value, PlayerState.error);
    expect(find.bySemanticsLabel('재생'), findsOneWidget);
    expect(errors, [failed]);

    // the same failure heard again says nothing more
    await failLate(tester, backend, backend.loads.single);
    await drain(tester);
    expect(errors, [failed]);
  });

  testWidgets('a late failure of the recording before leaves the new one', (
    tester,
  ) async {
    final (binding, temp) = await openVault(tester);
    final backend = _Backend();
    final errors = <String>[];
    final host = await mountKeeping(
      tester,
      errors,
      binding: binding,
      temp: temp,
      backend: backend,
    );
    await press(tester, row('녹음 1'));
    await press(tester, row('3주차 강의'));
    expect(backend.loads, hasLength(2));
    expect(inBar(find.text('3주차 강의')), findsOneWidget);
    // 녹음 1's play() fails only now
    await failLate(tester, backend, backend.loads.first);
    await drain(tester);
    expect(host.audio.player.state.value, PlayerState.playing);
    expect(host.audio.player.current.value?.name, '3주차 강의');
    expect(find.bySemanticsLabel('일시 정지'), findsOneWidget);
    expect(errors, isEmpty);
  });

  testWidgets('a recording removed as the note closes is gone', (tester) async {
    final (binding, temp) = await openVault(tester);
    final host = await mount(
      tester,
      binding: binding,
      temp: temp,
      backend: _Backend(),
      disposeAfter: false,
    );
    await tester.tap(inRow('녹음 1', 'kit-audio-more'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('지우기'));
    await tester.pump();
    expect(row('녹음 1'), findsNothing);
    expect(notice, findsOneWidget);

    // the note closes before the notice goes
    await tester.pumpWidget(const SizedBox());
    host.dispose();
    expect(await stored(tester, host, binding), ['3주차 강의']);
  });

  testWidgets('what is typed into a name is kept when the panel closes', (
    tester,
  ) async {
    final (binding, temp) = await openVault(tester);
    final host = await mount(
      tester,
      binding: binding,
      temp: temp,
      backend: _Backend(),
    );
    await tester.tap(inRow('녹음 1', 'kit-audio-more'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('이름 바꾸기'));
    await tester.pumpAndSettle();
    await tester.enterText(rename, '세미나');
    await tester.pump();
    host.togglePanel();
    await tester.pumpAndSettle();
    expect(host.audio.renaming.value, isNull);
    expect(await stored(tester, host, binding), ['3주차 강의', '세미나']);

    // with nothing typed, closing just ends it
    host.togglePanel();
    await drain(tester);
    await tester.pumpAndSettle();
    await tester.tap(inRow('3주차 강의', 'kit-audio-more'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('이름 바꾸기'));
    await tester.pumpAndSettle();
    expect(rename, findsOneWidget);
    host.togglePanel();
    await tester.pumpAndSettle();
    expect(host.audio.renaming.value, isNull);
    expect(await stored(tester, host, binding), ['3주차 강의', '세미나']);
  });

  testWidgets('while the note is first read the tab shows no empty line', (
    tester,
  ) async {
    final (binding, temp) = await openVault(tester);
    final host = await mount(
      tester,
      binding: binding,
      temp: temp,
      backend: _Backend(),
      loaded: false,
    );
    // the favourites are being read (started here, outside the real time,
    // it waits for the frames below): the tab is there, still empty
    final load = host.load();
    expect(host.favoritesAvailable, isTrue);
    expect(host.audio.loading, isTrue);
    await tester.pump();
    expect(find.byKey(const ValueKey('kit-side-tab-audio')), findsOneWidget);
    expect(find.byType(KitSideEmpty), findsNothing);
    expect(row('녹음 1'), findsNothing);

    await settle(tester, () => load);
    await tester.pumpAndSettle();
    expect(row('녹음 1'), findsOneWidget);
    expect(find.byType(KitSideEmpty), findsNothing);
  });

  testWidgets('while listening the list ends over the bar', (tester) async {
    final (binding, temp) = await openVault(tester);
    final host = await mount(
      tester,
      binding: binding,
      temp: temp,
      backend: _Backend(),
      size: const Size(586, 320),
    );
    await press(tester, row('녹음 1'));
    expect(bar, findsOneWidget);
    await tester.drag(find.byType(KitSideAudio), const Offset(0, -600));
    await tester.pumpAndSettle();
    final hint = tester.getRect(
      find.text(keepWords('녹음을 누르면 아래에 듣기 막대가 뜹니다.')),
    );
    expect(hint.bottom, lessThanOrEqualTo(tester.getRect(bar).top));
    EdgeInsetsGeometry? listRoom() => tester
        .widget<ListView>(
          find.descendant(
            of: find.byType(KitSideAudio),
            matching: find.byType(ListView),
          ),
        )
        .padding;
    expect(listRoom(), const EdgeInsets.only(bottom: KitTokens.listenFootRoom));

    // closed, the room goes
    await press(tester, find.byKey(const ValueKey('kit-listen-close')));
    await tester.pumpAndSettle();
    expect(bar, findsNothing);
    expect(host.audio.footRoom.value, 0);
    expect(listRoom(), EdgeInsets.zero);
  });

  group('in the editor', () {
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

    testWidgets('the position moving repaints neither the page nor the list', (
      tester,
    ) async {
      final (binding, temp) = await openVault(tester);
      final backend = _Backend();
      usePlayer(backend, temp);
      final chrome = EditorChromeController()..noteSide = () => binding;
      addTearDown(chrome.dispose);
      const size = Size(1000, 1400);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(size: size),
          child: TranslationProvider(
            child: MaterialApp(
              localizationsDelegates: const [
                FlutterQuillLocalizations.delegate,
              ],
              home: Editor(
                path: '/audio-tab-paint',
                onSaveSnapshot: (_, _) async {},
                chrome: chrome,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await drain(tester);
      final editor = tester.state<EditorState>(find.byType(Editor));
      await tester.tap(find.byKey(const ValueKey('editor-page-list')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('kit-side-tab-audio')));
      await drain(tester);
      await tester.pumpAndSettle();
      await press(tester, row('3주차 강의'));
      expect(bar, findsOneWidget);
      await tester.pumpAndSettle();

      RenderRepaintBoundary boundary(Finder of) =>
          tester.renderObject<RenderRepaintBoundary>(
            find
                .descendant(of: of, matching: find.byType(RepaintBoundary))
                .first,
          );
      final page =
          editor.coreInfo.pages.first.innerCanvasKey.currentContext!
                  .findRenderObject()!
              as RenderRepaintBoundary;
      final list = boundary(find.byType(KitSidePanel));
      final listening = boundary(bar);
      final pageBefore = paintCounts(page);
      final listBefore = paintCounts(list);
      final barBefore = listening.debugAsymmetricPaintCount;
      for (var s = 1; s <= 5; s++) {
        backend.onPosition(Duration(seconds: 61 * s));
        await tester.pump();
        expect(
          inBar(find.text(kitAudioClock(Duration(seconds: 61 * s)))),
          findsOneWidget,
        );
      }
      expect(listening.debugAsymmetricPaintCount, greaterThan(barBefore));
      expectNotPainted(page, pageBefore);
      expectNotPainted(list, listBefore);
      editor.cancelAutosaveAndMarkSaved();
      await tester.pumpWidget(const SizedBox());
      await drain(tester);
    });

    testWidgets('one page at a time, the page flip bar stands over the bar', (
      tester,
    ) async {
      final (binding, temp) = await openVault(tester);
      usePlayer(_Backend(), temp);
      final singlePage = stows.lastSinglePageMode.value;
      stows.lastSinglePageMode.value = true;
      addTearDown(() => stows.lastSinglePageMode.value = singlePage);
      final chrome = EditorChromeController()..noteSide = () => binding;
      addTearDown(chrome.dispose);
      const size = Size(1000, 1400);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const path = '/audio-tab-pages';
      final core = EditorCoreInfo(filePath: path)
        ..initialPageIndex = 1
        ..pages.addAll([EditorPage(), EditorPage(), EditorPage()]);
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(size: size),
          child: TranslationProvider(
            child: MaterialApp(
              localizationsDelegates: const [
                FlutterQuillLocalizations.delegate,
              ],
              home: Editor(
                path: path,
                loadSnapshot: () async => core,
                onSaveSnapshot: (_, _) async {},
                chrome: chrome,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await drain(tester);
      final editor = tester.state<EditorState>(find.byType(Editor));
      expect(editor.currentPageIndex, 1);
      final flip = find.ancestor(
        of: find.byTooltip('다음 쪽'),
        matching: find.byWidgetPredicate(
          (w) => w is Material && w.borderRadius == BorderRadius.circular(24),
        ),
      );
      expect(flip, findsOneWidget);
      final down = tester.getRect(flip);

      await tester.tap(find.byKey(const ValueKey('editor-page-list')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('kit-side-tab-audio')));
      await drain(tester);
      await tester.pumpAndSettle();
      await press(tester, row('3주차 강의'));
      await tester.tap(find.byKey(const ValueKey('editor-page-list')));
      await tester.pumpAndSettle();
      expect(bar, findsOneWidget);

      final up = tester.getRect(flip);
      final listening = tester.getRect(bar);
      expect(up.overlaps(listening), isFalse, reason: '$up $listening');
      expect(up.bottom, lessThan(listening.top));
      await tester.tap(find.byTooltip('다음 쪽'));
      await tester.pumpAndSettle();
      expect(editor.currentPageIndex, 2);
      await tester.tap(find.byTooltip('이전 쪽'));
      await tester.pumpAndSettle();
      expect(editor.currentPageIndex, 1);

      // a removal's notice stands over both bars; the page still turns
      await tester.tap(find.byKey(const ValueKey('editor-page-list')));
      await tester.pumpAndSettle();
      await tester.tap(inRow('녹음 1', 'kit-audio-more'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('지우기'));
      await tester.pump();
      await tester.pump(KitMotion.undoNoticeIn);
      final flipNow = tester.getRect(flip);
      final shown = tester.getRect(notice);
      final barNow = tester.getRect(bar);
      expect(
        shown.overlaps(flipNow),
        isFalse,
        reason: 'notice $shown, $flipNow',
      );
      expect(shown.overlaps(barNow), isFalse, reason: '$shown $barNow');
      expect(flipNow.overlaps(barNow), isFalse, reason: '$flipNow $barNow');
      await tester.tap(find.byTooltip('다음 쪽'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(editor.currentPageIndex, 2);
      expect(notice, findsOneWidget);
      await tester.tap(find.text(KitTokens.undoNoticeAction));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('editor-page-list')));
      await tester.pumpAndSettle();

      // closed, it comes down again
      await press(tester, find.byKey(const ValueKey('kit-listen-close')));
      await tester.pumpAndSettle();
      expect(bar, findsNothing);
      expect(tester.getRect(flip), down);

      editor.cancelAutosaveAndMarkSaved();
      await tester.pumpWidget(const SizedBox());
      await drain(tester);
    });
  });
}
