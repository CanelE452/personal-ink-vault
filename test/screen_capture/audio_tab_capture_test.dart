import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_quill/flutter_quill.dart'
    show FlutterQuillLocalizations;
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/ink_ui/audio/listen_bar.dart';
import 'package:saber/components/ink_ui/side_panel/audio_tab.dart';
import 'package:saber/components/ink_ui/side_panel/kit_side_panel.dart';
import 'package:saber/components/kit/kit_motion.dart';
import 'package:saber/components/kit/kit_tokens.dart';
import 'package:saber/components/kit/kit_undo_notice.dart';
import 'package:saber/data/audio/note_player.dart';
import 'package:saber/data/audio/recording_entry.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/vault/note_side_store.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/editor/editor.dart';
import 'package:saber/pages/editor/editor_side_host.dart';
import 'package:sbn/tool_id.dart';

import '../utils/screen_capture.dart';
import '../utils/test_mock_channel_handlers.dart';

/// A player that plays nothing; [onPosition] moves its position.
class _Backend implements PlayerBackend {
  late void Function(Duration position) onPosition;

  @override
  bool get supported => true;

  @override
  void listen({
    required void Function(Duration position) onPosition,
    required void Function() onCompleted,
    required void Function(String path, Object error, StackTrace stack)
    onFailed,
  }) => this.onPosition = onPosition;

  @override
  Future<void> load(String path) async {}

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> setSpeed(double speed) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}
}

/// Writes screenshots of the left panel's audio tab and the listening bar
/// (supplement Task 11) to build/screen-review/supp-t11/app-supp-t11-*.png
/// with the app's fonts at device pixel ratio 2, on the 12th draft's page
/// area (`#extras12`: 586 x 734 on the tablet, 360 x 600 on the phone),
/// with the draft's recordings (`AU0`): the tab with 「3주차 강의」 in the bar
/// at .22 and marked new (`#r1=audio`, `S.newAu = 'a2'`), the empty tab
/// (`emptyaudio`), 「녹음 1」's menu (`S.menu = 'a1'`), its name being
/// changed (`S.ren = 'a1'`), the undo notice after it is removed, the bar
/// alone with 「녹음 1」 at .38 and speed 1.5× (`listen`, `S.spd = 2`) and the
/// phone's bar (`listen360`); and (fix round 1) the editor showing one page
/// at a time while listening, its page flip bar over the listening bar, and
/// (fix round 2) with an undo notice over both.
/// Runs only with PIV_CAPTURE=1.
final _capture = Platform.environment['PIV_CAPTURE'] == '1';
final _outDir = captureDir('build/screen-review/supp-t11');
const _paper = Color(0xfffbf8ef); // `--paper`

Future<void> _write(
  WidgetTester tester,
  GlobalKey boundary,
  String name,
) async {
  debugDisableShadows = false;
  try {
    void mark(RenderObject o) {
      o.markNeedsPaint();
      o.visitChildren(mark);
    }

    mark(boundary.currentContext!.findRenderObject()!);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump();
    await tester.runAsync(() async {
      final object =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await object.toImage(pixelRatio: 2);
      final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      Directory(_outDir).createSync(recursive: true);
      File('$_outDir/app-supp-t11-$name.png')
          .writeAsBytesSync(png.buffer.asUint8List());
      image.dispose();
    });
  } finally {
    debugDisableShadows = true;
  }
  expect(tester.takeException(), isNull);
}

/// `AU0`'s recordings: (id, name, length, made at).
final _recordings = [
  (
    'a2',
    '3주차 강의',
    const Duration(seconds: 2465),
    DateTime(2026, 11, 27, 14, 5),
  ),
  ('a1', '녹음 1', const Duration(seconds: 768), DateTime(2026, 11, 20, 10, 2)),
];

void main() {
  /// The page area of [size]: the panel on the audio tab when [panel], the
  /// recording [listening] in the bar at [at] of its length, and the undo
  /// notice.
  Future<(GlobalKey, KitUndoNoticeController)> mount(
    WidgetTester tester, {
    required Size size,
    bool panel = true,
    bool empty = false,
    String? listening,
    double at = 0,
    double speed = 1,
    String? fresh,
    String? renaming,
    String? removed,
  }) async {
    await tester.runAsync(loadCaptureFonts);
    tester.view.physicalSize = size * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final notice = KitUndoNoticeController();
    addTearDown(notice.dispose);
    final boundary = GlobalKey();
    final phone = size.width < KitTokens.sidePanelPhoneBelow;
    final rows = [
      for (final (id, title, length, made) in _recordings)
        if (!empty && id != removed)
          KitAudioRow(
            id: id,
            title: title,
            length: length,
            madeAt: made,
            listening: id == listening,
            playing: id == listening,
            fresh: id == fresh,
          ),
    ];
    final bar = _recordings.where((r) => r.$1 == listening).firstOrNull;
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: MediaQuery(
          data: MediaQueryData(size: size, devicePixelRatio: 2),
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
              fontFamily: captureLatin,
              fontFamilyFallback: const [captureKorean],
            ),
            home: Material(
              color: _paper,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: KitSidePanel(
                      open: panel,
                      phone: phone,
                      tabs: KitSideTab.values,
                      tab: KitSideTab.audio,
                      onTab: (_) {},
                      body: KitSideAudio(
                        rows: rows,
                        play: true,
                        editable: true,
                        renaming: renaming,
                        onPlay: (_) {},
                        onRenameStart: (_) {},
                        onRenameEdit: (_, _) {},
                        onRename: (_, _) {},
                        onRemove: (_) {},
                      ),
                    ),
                  ),
                  if (bar != null)
                    Positioned.fill(
                      child: KitListenBar(
                        title: bar.$2,
                        position: bar.$3 * at,
                        length: bar.$3,
                        playing: true,
                        speed: speed,
                        phone: phone,
                        onPlayPause: () {},
                        onSeek: (_) {},
                        onSpeed: () {},
                        onClose: () {},
                      ),
                    ),
                  Positioned.fill(child: KitUndoNotice(controller: notice)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (boundary, notice);
  }

  const tablet = Size(586, 734);
  const phone = Size(360, 600);

  group('audio tab captures', skip: !_capture, () {
    testWidgets('audio', (tester) async {
      final (boundary, _) = await mount(
        tester,
        size: tablet,
        listening: 'a2',
        at: .22,
        fresh: 'a2',
      );
      await _write(tester, boundary, 'audio');
    });
    testWidgets('audio-empty', (tester) async {
      final (boundary, _) = await mount(tester, size: tablet, empty: true);
      await _write(tester, boundary, 'audio-empty');
    });
    testWidgets('audio-menu', (tester) async {
      final (boundary, _) = await mount(
        tester,
        size: tablet,
        listening: 'a2',
        at: .22,
      );
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('kit-audio-row-a1')),
          matching: find.byKey(const ValueKey('kit-audio-more')),
        ),
      );
      await tester.pumpAndSettle();
      await _write(tester, boundary, 'audio-menu');
    });
    testWidgets('audio-rename', (tester) async {
      final (boundary, _) = await mount(
        tester,
        size: tablet,
        listening: 'a2',
        at: .22,
        renaming: 'a1',
      );
      await _write(tester, boundary, 'audio-rename');
    });
    testWidgets('audio-undo', (tester) async {
      final (boundary, notice) = await mount(
        tester,
        size: tablet,
        listening: 'a2',
        at: .22,
        removed: 'a1',
      );
      notice.show(KitTokens.removedNotice('녹음 1'), onAction: () {});
      await tester.pump();
      await tester.pump(KitMotion.undoNoticeIn);
      await _write(tester, boundary, 'audio-undo');
    });
    testWidgets('listen', (tester) async {
      final (boundary, _) = await mount(
        tester,
        size: tablet,
        panel: false,
        listening: 'a1',
        at: .38,
        speed: 1.5,
      );
      await _write(tester, boundary, 'listen');
    });
    testWidgets('phone-listen', (tester) async {
      final (boundary, _) = await mount(
        tester,
        size: phone,
        panel: false,
        listening: 'a2',
        at: .22,
      );
      await _write(tester, boundary, 'phone-listen');
    });

    /// The editor on page 2 of 3, one page at a time, 「3주차 강의」 in the
    /// listening bar at .22; with a removal's undo notice when [notice].
    Future<void> singlePage(
      WidgetTester tester,
      String name, {
      bool notice = false,
    }) async {
      FlavorConfig.setup();
      setupMockPathProvider();
      setupMockPrinting();
      setupMockWindowManager();
      await FileManager.init();
      await tester.runAsync(loadCaptureFonts);
      final saved = (stows.lastTool.value, stows.lastSinglePageMode.value);
      stows.lastTool.value = ToolId.fountainPen;
      stows.lastSinglePageMode.value = true;
      addTearDown(() {
        stows.lastTool.value = saved.$1;
        stows.lastSinglePageMode.value = saved.$2;
      });
      final backend = _Backend();
      final temp = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('piv-t11-'),
      ))!;
      addTearDown(() => temp.deleteSync(recursive: true));
      EditorAudioHost.debugNewPlayer = (read) => NotePlayer(
        readAudio: (_) async => Uint8List(4),
        backend: backend,
        directory: () async => temp,
      );
      addTearDown(() => EditorAudioHost.debugNewPlayer = null);
      const size = Size(800, 1000);
      tester.view.physicalSize = size * 2;
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const path = '/supp-t11-single-page';
      final core = EditorCoreInfo(filePath: path)
        ..initialPageIndex = 1
        ..pages.addAll([EditorPage(), EditorPage(), EditorPage()]);
      final boundary = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: TranslationProvider(
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              localizationsDelegates: const [
                FlutterQuillLocalizations.delegate,
              ],
              theme: ThemeData(
                fontFamily: captureLatin,
                fontFamilyFallback: const [captureKorean],
              ),
              home: Editor(
                path: path,
                customTitle: '강의노트 3주차',
                showDocumentHeader: false,
                loadSnapshot: () async => core,
                onSaveSnapshot: (_, _) async {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final editor = tester.state<EditorState>(find.byType(Editor));
      final (_, title, length, made) = _recordings.first;
      final entry = RecordingEntry(
        noteId: path,
        entityId: 'a2',
        name: title,
        duration: length,
        createdAt: made,
        sizeBytes: 4,
        record: const NoteSideRecord(
          entityId: 'a2',
          revisionId: 'r-a2',
          heads: [],
          kind: NoteSideKind.recording,
        ),
      );
      final audio = editor.side.audio;
      audio.listening.value = entry;
      await tester.runAsync(() => audio.player.play(entry));
      backend.onPosition(length * .22);
      await tester.pumpAndSettle();
      expect(find.byTooltip('다음 쪽'), findsOneWidget);
      expect(find.byKey(const ValueKey('kit-listen-bar')), findsOneWidget);
      if (notice) {
        editor.side.notice.show(
          KitTokens.removedNotice('녹음 1'),
          onAction: () {},
        );
        await tester.pump();
        await tester.pump(KitMotion.undoNoticeIn);
        expect(find.byKey(const ValueKey('kit-undo-notice')), findsOneWidget);
      }
      await _write(tester, boundary, name);
      editor.side.notice.hide();
      editor.cancelAutosaveAndMarkSaved();
      await tester.pumpWidget(const SizedBox());
    }

    testWidgets(
      'single-page-listen',
      (tester) => singlePage(tester, 'single-page-listen'),
    );
    testWidgets(
      'single-page-listen-notice',
      (tester) => singlePage(tester, 'single-page-listen-notice', notice: true),
    );
  });
}
