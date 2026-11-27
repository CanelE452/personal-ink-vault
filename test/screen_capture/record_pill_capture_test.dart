import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/ink_ui/audio/record_pill.dart';
import 'package:saber/components/ink_ui/editor_toolbar/kit_editor_toolbar.dart';
import 'package:saber/components/kit/kit_icon.dart';
import 'package:saber/components/kit/kit_motion.dart';
import 'package:saber/components/kit/kit_tokens.dart';
import 'package:saber/components/kit/kit_undo_notice.dart';
import 'package:saber/data/actions/app_action.dart';
import 'package:saber/data/actions/app_action_ids.dart';
import 'package:saber/data/actions/app_action_registry.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/prefs.dart';

import '../utils/screen_capture.dart';

/// Writes screenshots of the toolbar's record button and the recording pill
/// (supplement Task 12) to build/screen-review/supp-t12/app-supp-t12-*.png
/// with the app's fonts at device pixel ratio 2, as the 12th draft's device
/// (`#extras12`): the toolbar (46) over the page area (586 x 734 on the
/// tablet, 360 x 600 on the phone), the pen in hand. Recording at 42 s
/// (`#r1=recon`), paused (`recpause`), the toolbar before recording, the
/// notice after it stops (`recdone`), the notice after leaving the app
/// stopped it, and the phone recording with the middle slid to the record
/// button (`rec360`). Runs only with PIV_CAPTURE=1.
final _capture = Platform.environment['PIV_CAPTURE'] == '1';
final _outDir = captureDir('build/screen-review/supp-t12');
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
      File('$_outDir/app-supp-t12-$name.png')
          .writeAsBytesSync(png.buffer.asUint8List());
      image.dispose();
    });
  } finally {
    debugDisableShadows = true;
  }
  expect(tester.takeException(), isNull);
}

void main() {
  FlavorConfig.setup();

  /// The toolbar over the page area of [size]; [recording] the record
  /// button's mark and, unless off, the pill at [elapsed]; the notice shows
  /// [notice] with 「보기」.
  Future<GlobalKey> mount(
    WidgetTester tester, {
    required Size size,
    KitRecording recording = KitRecording.off,
    Duration elapsed = const Duration(seconds: 42),
    String? notice,
  }) async {
    await tester.runAsync(loadCaptureFonts);
    stows.editorToolbarTools.value = const [];
    stows.pageToolbarLayout.value = const [];
    stows.editorGestureMode.value = false;
    final screen = Size(size.width, KitTokens.toolbarHeight + size.height);
    tester.view.physicalSize = screen * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final actions = AppActionRegistry();
    addTearDown(actions.dispose);
    final floatingBar = ValueNotifier(false);
    addTearDown(floatingBar.dispose);
    final noteSheet = ValueNotifier(false);
    addTearDown(noteSheet.dispose);
    final state = ValueNotifier(recording);
    addTearDown(state.dispose);
    final time = ValueNotifier(elapsed);
    addTearDown(time.dispose);
    final notices = KitUndoNoticeController();
    addTearDown(notices.dispose);
    final on = recording != KitRecording.off;
    AppAction action(String id, KitIconName icon, {bool? checked}) =>
        AppAction(id: id, label: id, icon: icon, checked: checked, run: (_) {});
    actions.publish(Object(), [
      action(AppActionIds.pageList, KitIconName.sidebar, checked: false),
      for (final id in AppActionIds.tools)
        action(id, KitIconName.pen, checked: id == AppActionIds.toolPen),
      action(AppActionIds.pickPhoto, KitIconName.image),
      action(AppActionIds.insertPageMenu, KitIconName.pageAdd),
      action(AppActionIds.fullscreen, KitIconName.expand, checked: false),
      AppAction(
        id: AppActionIds.record,
        label: on ? '녹음 멈춤' : '녹음 시작',
        icon: KitIconName.mic,
        checked: on,
        run: (_) {},
      ),
    ]);
    final boundary = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: MediaQuery(
          data: MediaQueryData(size: screen, devicePixelRatio: 2),
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
              fontFamily: captureLatin,
              fontFamilyFallback: const [captureKorean],
            ),
            home: Material(
              color: _paper,
              child: Column(
                children: [
                  KitEditorToolbar(
                    actions: actions,
                    title: '강의노트 3주차',
                    floatingBarOpen: floatingBar,
                    noteSheetOpen: noteSheet,
                    recording: state,
                  ),
                  Expanded(
                    child: Stack(
                      children: [
                        if (on)
                          Positioned.fill(
                            child: KitRecordPill(
                              paused: recording == KitRecording.paused,
                              elapsed: time,
                              onPauseResume: () {},
                              onStop: () {},
                            ),
                          ),
                        Positioned.fill(
                          child: KitUndoNotice(controller: notices),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    if (notice != null) {
      notices.show(notice, action: '보기', onAction: () {});
      await tester.pump();
      await tester.pump(KitMotion.undoNoticeIn);
    }
    return boundary;
  }

  const tablet = Size(586, 734);
  const phone = Size(360, 600);

  group('record pill captures', skip: !_capture, () {
    testWidgets('recording', (tester) async {
      final boundary = await mount(
        tester,
        size: tablet,
        recording: KitRecording.on,
      );
      await _write(tester, boundary, 'recording');
      await tester.pumpWidget(const SizedBox());
    });
    testWidgets('paused', (tester) async {
      final boundary = await mount(
        tester,
        size: tablet,
        recording: KitRecording.paused,
      );
      await _write(tester, boundary, 'paused');
    });
    testWidgets('toolbar', (tester) async {
      final boundary = await mount(tester, size: tablet);
      await _write(tester, boundary, 'toolbar');
    });
    testWidgets('stopped', (tester) async {
      final boundary = await mount(
        tester,
        size: tablet,
        notice: '오디오 탭에 넣었습니다 · 녹음 3',
      );
      await _write(tester, boundary, 'stopped');
    });
    testWidgets('left-app', (tester) async {
      final boundary = await mount(
        tester,
        size: tablet,
        notice: '앱을 벗어나 녹음을 멈추고 저장했습니다',
      );
      await _write(tester, boundary, 'left-app');
    });
    testWidgets('phone-recording', (tester) async {
      final boundary = await mount(
        tester,
        size: phone,
        recording: KitRecording.on,
      );
      final scroll = tester.state<ScrollableState>(
        find.descendant(
          of: find.byKey(const ValueKey('editor-tools-scroll')),
          matching: find.byType(Scrollable),
        ),
      );
      expect(scroll.position.pixels, scroll.position.maxScrollExtent);
      expect(scroll.position.pixels, greaterThan(0));
      await _write(tester, boundary, 'phone-recording');
      await tester.pumpWidget(const SizedBox());
    });
  });
}
