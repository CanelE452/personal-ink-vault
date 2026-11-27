import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/ink_ui/editor_toolbar/kit_editor_toolbar.dart';
import 'package:saber/components/ink_ui/editor_toolbar/toolbar_customize_sheet.dart';
import 'package:saber/components/ink_ui/floating_bar/kit_floating_bar.dart';
import 'package:saber/components/ink_ui/pen_panel/pen_kinds.dart';
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
import 'package:saber/pages/editor/editor_side_host.dart';

import '../utils/screen_capture.dart';

/// Writes screenshots of the editor toolbar (9th draft c) to
/// build/screen-review/t13b/app-v9c-*.png with the app's fonts at device
/// pixel ratio 2, for the states of the preview's ref-v9c-*.png: the bar
/// (inner width 586) and the page area under it (734 high) with what lies
/// over it. The tab row above is the workspace's (Task 17) and is not drawn.
/// Runs only with PIV_CAPTURE=1 so the normal suite writes no files.
final _capture = Platform.environment['PIV_CAPTURE'] == '1';
final _outDir = captureDir('build/screen-review/t13b');
const _latin = captureLatin;
const _korean = captureKorean;
const _width = 586.0;
const _page = 734.0;

/// The preview's page: `--paper` with a 1px `--paper-grid` line every 22.
class _Paper extends CustomPainter {
  const new();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xfffbf8ef));
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

/// The preview's pen in hand: the fine pen (볼펜) in the first dot's colour
/// at the preview's width 37 (the app's own default stays as it is).
Pen _finePen() {
  final pen = Pen.ballpointPen()..color = const Color(0xff1f2329);
  return pen
    ..options = pen.options.copyWith(
      size: levelToSize(37, min: pen.sizeMin, max: pen.sizeMax),
    );
}

/// The editor's actions as the preview has them: [tool] in hand.
void _publish(AppActionRegistry actions, Tool tool) {
  AppAction a(String id, KitIconName icon, {bool? checked, bool enabled = true}) =>
      AppAction(
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
    a(AppActionIds.toolPen, KitIconName.pen, checked: isInkTool(tool)),
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
  ]);
}

void main() {
  FlavorConfig.setup();

  Future<void> shoot(
    WidgetTester tester,
    String name, {
    Tool? tool,
    bool floatingBar = true,
    bool gesture = false,
    bool note = false,
    bool customize = false,
    List<String> tools = const [],
    Future<void> Function()? then,
  }) async {
    await tester.runAsync(loadCaptureFonts);
    const size = Size(_width, 46 + _page);
    tester.view.physicalSize = size * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    stows.editorToolbarTools.value = tools;
    stows.pageToolbarLayout.value = const [];
    stows.editorGestureMode.value = gesture;
    stows.floatingBarPosition.value = 'top';
    // the preview's eraser size in hand: 중간, the slider's 40 (as the v10
    // eraser capture; the stored default, radius 10, is level 12 and rings
    // none of the three sizes)
    final eraserSize = stows.eraserSize.value;
    stows.eraserSize.value = levelToSize(
      40,
      min: KitTokens.eraserSizeMin,
      max: KitTokens.eraserSizeMax,
    );
    addTearDown(() => stows.eraserSize.value = eraserSize);
    final inHand = tool ?? _finePen();
    final actions = AppActionRegistry();
    final open = ValueNotifier(floatingBar);
    final sheet = ValueNotifier(note);
    // the quick note window (supplement Task 13), its page not read
    final quick = EditorQuickNoteHost(open: sheet)..available.value = true;
    final collapsed = ValueNotifier(false);
    addTearDown(() {
      actions.dispose();
      open.dispose();
      quick.dispose();
      sheet.dispose();
      collapsed.dispose();
      stows.editorGestureMode.value = false;
      stows.editorToolbarTools.value = const [];
    });
    _publish(actions, inHand);
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
                          currentTool: inHand,
                          setTool: (_) {},
                          setColor: (_) {},
                          actions: actions,
                          penPanelCollapsed: collapsed,
                          visible: floatingBar && !gesture,
                        ),
                      ),
                      Positioned.fill(
                        child: EditorQuickNoteLayer(
                          host: quick,
                          pen: Pen.fountainPen,
                          erasing: () => false,
                        ),
                      ),
                      if (customize)
                        Positioned.fill(
                          child: ToolbarCustomizeSheet(onClose: () {}),
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
        File('$_outDir/app-v9c-$name.png')
            .writeAsBytesSync(png.buffer.asUint8List());
        image.dispose();
      });
    } finally {
      debugDisableShadows = true;
    }
    expect(tester.takeException(), isNull);
  }

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  group('editor toolbar captures', skip: !_capture, () {
    testWidgets('write', (tester) => shoot(tester, 'write'));
    testWidgets('nofb', (tester) => shoot(tester, 'nofb', floatingBar: false));
    testWidgets('eraser', (tester) => shoot(tester, 'eraser', tool: Eraser()));
    testWidgets(
      'gesture',
      (tester) => shoot(tester, 'gesture', gesture: true),
    );
    testWidgets(
      'more',
      (tester) => shoot(
        tester,
        'more',
        then: () => tap(tester, find.byKey(const ValueKey('editor-tools-more'))),
      ),
    );
    testWidgets('cust', (tester) => shoot(tester, 'cust', customize: true));
    testWidgets(
      'custmax',
      (tester) => shoot(
        tester,
        'custmax',
        customize: true,
        then: () => tap(tester, find.bySemanticsLabel('레이저 펜 막대에 보이기')),
      ),
    );
    testWidgets(
      'custmin',
      (tester) => shoot(
        tester,
        'custmin',
        customize: true,
        tools: const [
          '!lasso',
          'pen',
          '!eraser',
          '!text',
          '!shapes',
          '!image',
          '!laser',
        ],
        then: () => tap(tester, find.bySemanticsLabel('펜 막대에 보이기')),
      ),
    );
    testWidgets(
      'doc',
      (tester) => shoot(
        tester,
        'doc',
        then: () => tap(tester, find.byKey(const ValueKey('editor-doc-menu'))),
      ),
    );
    testWidgets(
      'docsub',
      (tester) => shoot(
        tester,
        'docsub',
        then: () async {
          await tap(tester, find.byKey(const ValueKey('editor-doc-menu')));
          await tap(tester, find.text('쪽 배치'));
        },
      ),
    );
    testWidgets('note', (tester) => shoot(tester, 'note', note: true));
  });
}
