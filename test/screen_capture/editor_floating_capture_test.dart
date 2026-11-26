import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/ink_ui/editor_toolbar/kit_editor_toolbar.dart';
import 'package:saber/components/ink_ui/editor_toolbar/kit_save_chip.dart';
import 'package:saber/components/ink_ui/floating_bar/kit_floating_bar.dart';
import 'package:saber/components/ink_ui/kit_mode_pill.dart';
import 'package:saber/components/ink_ui/kit_zoom_badge.dart';
import 'package:saber/components/ink_ui/pen_panel/kit_pen_panel.dart';
import 'package:saber/components/ink_ui/pen_panel/size_level.dart';
import 'package:saber/components/kit/kit_icon.dart';
import 'package:saber/data/actions/app_action.dart';
import 'package:saber/data/actions/app_action_ids.dart';
import 'package:saber/data/actions/app_action_registry.dart';
import 'package:saber/data/editor/saving_state.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/tools/pen.dart';

import '../utils/screen_capture.dart';

/// Writes screenshots of the things over the editor's page (Task 13B-2) to
/// build/screen-review/t13b/app-13b2-*.png with the app's fonts at device
/// pixel ratio 2: the save chip's three states, the zoom badge, the phone's
/// one-row floating bar (first and slid to the end), the bar and the chip
/// hidden under a stroke, and the mode pill. The toolbar (Task 13B-1) and the
/// page area under it (586 x 734, or 360 x 594 for the phone); the stroke is
/// a drawn stand-in, not the pen's. Runs only with PIV_CAPTURE=1.
final _capture = Platform.environment['PIV_CAPTURE'] == '1';
final _outDir = captureDir('build/screen-review/t13b');
const _latin = captureLatin;
const _korean = captureKorean;

/// The preview's page: `--paper` with a 1px `--paper-grid` line every 22,
/// and, with [stroke], a wave between its two ends like the preview's
/// 「막대 밑에 쓰기」 demo.
class _Paper extends CustomPainter {
  const new({this.stroke});

  final (Offset, Offset)? stroke;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xfffbf8ef),
    );
    final grid = Paint()..color = const Color(0xffece4cd);
    for (var x = 0.0; x < size.width; x += 22) {
      canvas.drawRect(Rect.fromLTWH(x, 0, 1, size.height), grid);
    }
    for (var y = 0.0; y < size.height; y += 22) {
      canvas.drawRect(Rect.fromLTWH(0, y, size.width, 1), grid);
    }
    final ends = stroke;
    if (ends == null) return;
    final (from, to) = ends;
    final path = Path()..moveTo(from.dx, from.dy);
    for (var k = 0.0; k <= 1; k += 0.01) {
      final x = from.dx + (to.dx - from.dx) * k;
      final y = from.dy + (to.dy - from.dy) * k;
      path.lineTo(x, y - 8 * math.sin((x - from.dx) / 36));
    }
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2
        ..strokeCap = StrokeCap.round
        ..color = const Color(0xff1f2a44),
    );
  }

  @override
  bool shouldRepaint(_Paper old) => stroke != old.stroke;
}

/// The preview's pen in hand: the fine pen (볼펜) in the first dot's colour
/// at the preview's width 37.
Pen _finePen() {
  final pen = Pen.ballpointPen()..color = const Color(0xff1f2329);
  return pen
    ..options = pen.options.copyWith(
      size: levelToSize(37, min: pen.sizeMin, max: pen.sizeMax),
    );
}

void _publish(AppActionRegistry actions) {
  AppAction a(
    String id,
    KitIconName icon, {
    bool? checked,
    bool enabled = true,
  }) => AppAction(
    id: id,
    label: id,
    icon: icon,
    checked: checked,
    enabled: enabled,
    run: (_) {},
  );
  actions.publish(Object(), [
    a(AppActionIds.undo, KitIconName.undo),
    a(AppActionIds.redo, KitIconName.redo, enabled: false),
    a(AppActionIds.pageList, KitIconName.sidebar),
    a(AppActionIds.toolLasso, KitIconName.lassoFree, checked: false),
    a(AppActionIds.toolPen, KitIconName.pen, checked: true),
    a(AppActionIds.toolEraser, KitIconName.eraser, checked: false),
    a(AppActionIds.toolText, KitIconName.text, checked: false),
    a(AppActionIds.toolShapes, KitIconName.shapes, checked: false),
    a(AppActionIds.toolLaser, KitIconName.laser, checked: false),
    a(AppActionIds.pickPhoto, KitIconName.image),
    a(AppActionIds.insertPage, KitIconName.pageAdd),
    a(AppActionIds.fullscreen, KitIconName.expand, checked: false),
    a(AppActionIds.toolbarCustomize, KitIconName.tune),
    a(AppActionIds.docInfo, KitIconName.info),
    a(AppActionIds.pageMode, KitIconName.scrollDir, checked: false),
    a(AppActionIds.save, KitIconName.download),
  ]);
}

/// What a capture sets before it is taken.
typedef _Scene = ({
  ValueNotifier<SavingState> saving,
  ValueNotifier<double> scale,
  ValueNotifier<Offset?> strokeAt,
});

void main() {
  FlavorConfig.setup();

  Future<void> shoot(
    WidgetTester tester,
    String name, {
    double width = 586,
    double page = 734,
    bool floatingBar = true,
    (Offset, Offset)? stroke,
    required Future<void> Function(_Scene scene) then,
  }) async {
    await tester.runAsync(loadCaptureFonts);
    final size = Size(width, 46 + page);
    tester.view.physicalSize = size * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final delay = stows.autosaveDelay.value;
    stows.editorToolbarTools.value = const [];
    stows.pageToolbarLayout.value = const [];
    stows.editorGestureMode.value = false;
    stows.floatingBarPosition.value = 'top';
    final actions = AppActionRegistry();
    final open = ValueNotifier(floatingBar);
    final sheet = ValueNotifier(false);
    final collapsed = ValueNotifier(false);
    final scene = (
      saving: ValueNotifier(SavingState.saved),
      scale: ValueNotifier(1.0),
      strokeAt: ValueNotifier<Offset?>(null),
    );
    addTearDown(() {
      actions.dispose();
      open.dispose();
      sheet.dispose();
      collapsed.dispose();
      scene.saving.dispose();
      scene.scale.dispose();
      scene.strokeAt.dispose();
      stows.editorGestureMode.value = false;
      stows.autosaveDelay.value = delay;
    });
    _publish(actions);
    final boundary = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            fontFamily: _latin,
            fontFamilyFallback: const [_korean],
          ),
          home: Material(
            child: Column(
              children: [
                KitEditorToolbar(
                  actions: actions,
                  title: '강의노트 3주차',
                  floatingBarOpen: open,
                  noteSheetOpen: sheet,
                ),
                Expanded(
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: CustomPaint(painter: _Paper(stroke: stroke)),
                      ),
                      Positioned.fill(
                        child: KitFloatingBar(
                          currentTool: _finePen(),
                          setTool: (_) {},
                          setColor: (_) {},
                          actions: actions,
                          penPanelCollapsed: collapsed,
                          visible: floatingBar,
                          strokeAt: scene.strokeAt,
                        ),
                      ),
                      Positioned.fill(
                        child: KitSaveChip(
                          state: scene.saving,
                          actions: actions,
                          strokeAt: scene.strokeAt,
                        ),
                      ),
                      Positioned.fill(
                        child: KitZoomBadge(
                          scale: scene.scale,
                          shouldShow: () => true,
                          onReset: () {},
                        ),
                      ),
                      Positioned.fill(
                        child: KitModePill(
                          gestureMode: stows.editorGestureMode,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await then(scene);
    await tester.pumpAndSettle();
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
            boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await object.toImage(pixelRatio: 2);
        final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        Directory(_outDir).createSync(recursive: true);
        File('$_outDir/app-13b2-$name.png')
            .writeAsBytesSync(png.buffer.asUint8List());
        image.dispose();
      });
    } finally {
      debugDisableShadows = true;
    }
    expect(tester.takeException(), isNull);
  }

  /// The chip in [state], past its one second (auto save off, so waiting
  /// shows too).
  Future<void> Function(_Scene) chip(WidgetTester tester, SavingState state) =>
      (scene) async {
        stows.autosaveDelay.value = -1;
        scene.saving.value = state;
        await tester.pump(const Duration(milliseconds: 1001));
      };

  group('floating things captures', skip: !_capture, () {
    for (final (name, state) in const [
      ('savechip-busy', SavingState.saving),
      ('savechip-fail', SavingState.failed),
      ('savechip-wait', SavingState.waitingToSave),
    ]) {
      testWidgets(
        name,
        (tester) => shoot(tester, name, then: chip(tester, state)),
      );
    }
    testWidgets('zoom-150', (tester) {
      return shoot(
        tester,
        'zoom-150',
        then: (scene) async => scene.scale.value = 1.5,
      );
    });
    Future<void> phone(_Scene scene) async {
      scene.saving.value = SavingState.failed;
      scene.scale.value = 1.5;
    }

    testWidgets('phone-bar', (tester) {
      return shoot(tester, 'phone-bar', width: 360, page: 594, then: phone);
    });
    testWidgets('phone-bar-scrolled', (tester) {
      return shoot(
        tester,
        'phone-bar-scrolled',
        width: 360,
        page: 594,
        then: (scene) async {
          await phone(scene);
          await tester.drag(
            find.byKey(const ValueKey('floating-bar-tool-pill')),
            const Offset(-400, 0),
          );
        },
      );
    });
    // the stroke's tip under the bar, then into the chip (page + toolbar 46)
    testWidgets('hide-before', (tester) {
      return shoot(
        tester,
        'hide-before',
        then: (scene) async => scene.saving.value = SavingState.failed,
      );
    });
    testWidgets('hide-during', (tester) {
      return shoot(
        tester,
        'hide-during',
        stroke: (const Offset(8, 30), const Offset(230, 30)),
        then: (scene) async {
          scene.saving.value = SavingState.failed;
          await tester.pumpAndSettle();
          scene.strokeAt.value = const Offset(230, 46 + 25);
        },
      );
    });
    testWidgets('hide-chip', (tester) {
      return shoot(
        tester,
        'hide-chip',
        stroke: (const Offset(300, 160), const Offset(500, 95)),
        then: (scene) async {
          scene.saving.value = SavingState.failed;
          await tester.pumpAndSettle();
          scene.strokeAt.value = const Offset(500, 46 + 95);
        },
      );
    });
    // the pen panel from the phone bar: under the bar, inside the page area
    // (360 x 594 under the toolbar)
    testWidgets('phone-penpanel', (tester) {
      return shoot(
        tester,
        'phone-penpanel',
        width: 360,
        page: 594,
        then: (scene) async {
          await tester.tap(find.byKey(const ValueKey('floating-bar-pen-pen')));
          await tester.pumpAndSettle();
          final bar = tester.getRect(
            find.byKey(const ValueKey('kit-floating-bar')),
          );
          final panel = tester.getRect(find.byType(KitPenPanel));
          expect(panel.top, greaterThanOrEqualTo(bar.bottom));
          expect(panel.bottom, lessThanOrEqualTo(46 + 594));
        },
      );
    });
    testWidgets('mode-gesture', (tester) {
      return shoot(
        tester,
        'mode-gesture',
        floatingBar: false,
        then: (scene) async => stows.editorGestureMode.value = true,
      );
    });
  });
}
