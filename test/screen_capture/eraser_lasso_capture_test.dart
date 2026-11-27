import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/ink_ui/editor_toolbar/kit_editor_toolbar.dart';
import 'package:saber/components/ink_ui/floating_bar/kit_floating_bar.dart';
import 'package:saber/components/ink_ui/pen_panel/size_level.dart';
import 'package:saber/components/kit/kit_icon.dart';
import 'package:saber/components/kit/kit_tokens.dart';
import 'package:saber/data/actions/app_action.dart';
import 'package:saber/data/actions/app_action_ids.dart';
import 'package:saber/data/actions/app_action_registry.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/tools/_tool.dart';
import 'package:saber/data/tools/eraser.dart';
import 'package:saber/data/tools/pen.dart';
import 'package:saber/data/tools/select.dart';

import '../ink_ui/pen_panel_harness.dart' show resetPenPanelState;
import '../utils/screen_capture.dart';

/// Writes screenshots of the eraser bar and the eraser and lasso windows
/// (preview 10th draft 1-d) to build/screen-review/v10/app-v10-*.png with the
/// app's fonts at device pixel ratio 2, for the states of the preview's
/// ref-v10-*.png: the toolbar (586 wide, or 360 on a phone) and the page
/// under it (680, or 480 on a phone) with what lies over it. The tab row and
/// the device's frame around the preview's picture are not drawn. Runs only
/// with PIV_CAPTURE=1 so the normal suite writes no files.
final _capture = Platform.environment['PIV_CAPTURE'] == '1';
final _outDir = captureDir('build/screen-review/v10');
const _latin = captureLatin;
const _korean = captureKorean;

/// The preview's page: `--paper` with a 1px `--paper-grid` line every 22.
class _Paper extends CustomPainter {
  const new();

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
  }

  @override
  bool shouldRepaint(_Paper old) => false;
}

/// The editor's actions as the preview has them: [tool] in hand.
void _publish(AppActionRegistry actions, Tool tool) {
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
    a(AppActionIds.toolLasso, KitIconName.lassoFree, checked: tool is Select),
    a(AppActionIds.toolPen, KitIconName.pen, checked: tool is Pen),
    a(AppActionIds.toolEraser, KitIconName.eraser, checked: tool is Eraser),
    a(AppActionIds.toolText, KitIconName.text, checked: false),
    a(AppActionIds.toolShapes, KitIconName.shapes, checked: false),
    a(AppActionIds.toolLaser, KitIconName.laser, checked: false),
    a(AppActionIds.pickPhoto, KitIconName.image),
    a(AppActionIds.insertPageMenu, KitIconName.pageAdd),
    a(AppActionIds.fullscreen, KitIconName.expand, checked: false),
    a(AppActionIds.toolbarCustomize, KitIconName.tune),
    a(AppActionIds.docInfo, KitIconName.info),
    a(AppActionIds.rename, KitIconName.rename),
    a(AppActionIds.pageMode, KitIconName.scrollDir, checked: false),
    a(AppActionIds.clearPage, KitIconName.delPage),
  ]);
}

void main() {
  FlavorConfig.setup();
  tearDown(() {
    resetPenPanelState();
    stows.editorToolbarTools.value = const [];
    stows.floatingBarPosition.value = stows.floatingBarPosition.defaultValue;
  });

  Future<void> shoot(
    WidgetTester tester,
    String name, {
    required Tool tool,
    bool phone = false,
    void Function()? set,
    Future<void> Function()? then,
  }) async {
    await tester.runAsync(loadCaptureFonts);
    final size = phone ? const Size(360, 46 + 480) : const Size(586, 46 + 680);
    tester.view.physicalSize = size * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    stows.editorToolbarTools.value = const [];
    stows.pageToolbarLayout.value = const [];
    stows.editorGestureMode.value = false;
    stows.floatingBarPosition.value = 'top';
    // the preview's size in hand: 중간, the slider's 40
    stows.eraserSize.value = levelToSize(
      40,
      min: KitTokens.eraserSizeMin,
      max: KitTokens.eraserSizeMax,
    );
    set?.call();
    final actions = AppActionRegistry();
    final open = ValueNotifier(tool is Eraser || tool is Pen);
    final sheet = ValueNotifier(false);
    final collapsed = ValueNotifier(false);
    addTearDown(() {
      actions.dispose();
      open.dispose();
      sheet.dispose();
      collapsed.dispose();
    });
    _publish(actions, tool);
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
                      const Positioned.fill(
                        child: CustomPaint(painter: _Paper()),
                      ),
                      Positioned.fill(
                        child: KitFloatingBar(
                          currentTool: tool,
                          setTool: (_) {},
                          setColor: (_) {},
                          actions: actions,
                          penPanelCollapsed: collapsed,
                          visible: tool is Eraser || tool is Pen,
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
    await then?.call();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: 'an overflow was reported');
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
        File('$_outDir/app-v10-$name.png')
            .writeAsBytesSync(png.buffer.asUint8List());
        image.dispose();
      });
    } finally {
      debugDisableShadows = true;
    }
  }

  Future<void> tap(WidgetTester tester, String key) async {
    await tester.tap(find.byKey(ValueKey(key)));
    await tester.pumpAndSettle();
  }

  /// With the real fonts: the window 300 wide and inside the screen.
  void expectWindow(WidgetTester tester, String key, Size screen) {
    final window = tester.getRect(find.byKey(ValueKey(key)));
    expect(window.width, KitTokens.penPanelWidth);
    expect(window.left, greaterThanOrEqualTo(8));
    expect(window.right, lessThanOrEqualTo(screen.width - 8));
  }

  group('eraser and lasso captures (10th draft)', skip: !_capture, () {
    testWidgets('eraser-bar', (tester) async {
      await shoot(tester, 'eraser-bar', tool: Eraser());
      // the chip 32 high, the bar 40 (values: `.e10chip` 32, `.fbar` 40)
      expect(
        tester
            .getSize(find.byKey(const ValueKey('floating-bar-eraser-kind')))
            .height,
        32,
      );
      expect(
        tester.getSize(find.byKey(const ValueKey('kit-floating-bar'))).height,
        40,
      );
    });
    testWidgets(
      'eraser-bar-lassomode',
      (tester) => shoot(
        tester,
        'eraser-bar-lassomode',
        tool: Eraser(),
        set: () => stows.eraserMode.value = EraserMode.lasso,
      ),
    );
    testWidgets('eraser-type-s1', (tester) async {
      await shoot(
        tester,
        'eraser-type-s1',
        tool: Eraser(),
        then: () => tap(tester, 'floating-bar-eraser-kind'),
      );
      expectWindow(tester, 'kit-eraser-type-panel', const Size(586, 726));
    });
    testWidgets('eraser-adv', (tester) async {
      await shoot(
        tester,
        'eraser-adv',
        tool: Eraser(),
        then: () => tap(tester, 'floating-bar-eraser-advanced'),
      );
      expectWindow(tester, 'kit-eraser-advanced-panel', const Size(586, 726));
    });
    // Task 19: 쪽 비우기 asks in a tool window (no preview drawing of it)
    testWidgets('eraser-clear-confirm', (tester) async {
      await shoot(
        tester,
        'eraser-clear-confirm',
        tool: Eraser(),
        then: () async {
          await tap(tester, 'floating-bar-eraser-advanced');
          await tap(tester, 'eraser-clear-page');
        },
      );
      expect(
        find.byKey(const ValueKey('eraser-clear-page-confirm')),
        findsOneWidget,
      );
    });
    testWidgets(
      'eraser-adv-min',
      (tester) => shoot(
        tester,
        'eraser-adv-min',
        tool: Eraser(),
        set: () => stows.eraserTargets.value = ['highlighter'],
        then: () async {
          await tap(tester, 'floating-bar-eraser-advanced');
          await tap(tester, 'eraser-target-highlighter');
        },
      ),
    );
    testWidgets('lasso-pop', (tester) async {
      await shoot(
        tester,
        'lasso-pop',
        tool: Select.currentSelect,
        then: () => tap(tester, 'editor-tool-lasso'),
      );
      expectWindow(tester, 'kit-lasso-panel', const Size(586, 726));
    });
    testWidgets(
      'lasso-pop-rect',
      (tester) => shoot(
        tester,
        'lasso-pop-rect',
        tool: Select.currentSelect,
        set: () => stows.selectRectangle.value = true,
        then: () => tap(tester, 'editor-tool-lasso'),
      ),
    );
    testWidgets(
      'lasso-pop-min',
      (tester) => shoot(
        tester,
        'lasso-pop-min',
        tool: Select.currentSelect,
        set: () {
          stows.selectInk.value = false;
          stows.selectHighlighter.value = false;
          stows.selectImages.value = false;
        },
        then: () => tap(tester, 'editor-tool-lasso'),
      ),
    );
    testWidgets(
      'eraser-bar-360',
      (tester) => shoot(tester, 'eraser-bar-360', tool: Eraser(), phone: true),
    );
    testWidgets('eraser-adv-360', (tester) async {
      await shoot(
        tester,
        'eraser-adv-360',
        tool: Eraser(),
        phone: true,
        then: () => tap(tester, 'floating-bar-eraser-advanced'),
      );
      expectWindow(tester, 'kit-eraser-advanced-panel', const Size(360, 526));
    });
    // 10th draft fix 1: the window slides inside, its foot fading while
    // there is more below (the app's advanced settings already slide at 360)
    testWidgets('eraser-adv-360-scroll', (tester) async {
      await shoot(
        tester,
        'eraser-adv-360-scroll',
        tool: Eraser(),
        phone: true,
        then: () => tap(tester, 'floating-bar-eraser-advanced'),
      );
      expect(find.byKey(const ValueKey('kit-popover-fade')), findsOneWidget);
    });
    // the pen panel slides inside too, its own rows a view of their own
    testWidgets('pen-360-scroll', (tester) async {
      await shoot(
        tester,
        'pen-360-scroll',
        tool: Pen.fountainPen(),
        phone: true,
        then: () => tap(tester, 'floating-bar-pen-fountain'),
      );
      expect(find.byKey(const ValueKey('kit-popover-fade')), findsOneWidget);
    });
    testWidgets('lasso-pop-360', (tester) async {
      await shoot(
        tester,
        'lasso-pop-360',
        tool: Select.currentSelect,
        phone: true,
        then: () => tap(tester, 'editor-tool-lasso'),
      );
      expectWindow(tester, 'kit-lasso-panel', const Size(360, 526));
    });
  });
}
