import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/ink_ui/doc_menu/kit_doc_menu.dart';
import 'package:saber/components/ink_ui/editor_toolbar/kit_editor_toolbar.dart';
import 'package:saber/components/ink_ui/floating_bar/kit_floating_bar.dart';
import 'package:saber/components/ink_ui/kit_zoom_badge.dart';
import 'package:saber/components/ink_ui/pen_panel/pen_kinds.dart';
import 'package:saber/components/kit/kit_icon.dart';
import 'package:saber/components/toolbar/note_function_row.dart';
import 'package:saber/components/toolbar/shortcut_layout.dart';
import 'package:saber/data/actions/app_action.dart';
import 'package:saber/data/actions/app_action_ids.dart';
import 'package:saber/data/actions/app_action_registry.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/tools/_tool.dart';
import 'package:saber/data/tools/eraser.dart';
import 'package:saber/data/tools/pen.dart';
import 'package:saber/data/tools/select.dart';
import 'package:saber/data/vault/infinite_document.dart';
import 'package:saber/pages/workspace/infinite_canvas.dart';

import '../utils/screen_capture.dart';

/// Writes screenshots of the infinite note on the editor's toolbar (Task 18)
/// to build/screen-review/t18/app-t18-*.png, and the same states of the ink
/// editor's toolbar and floating bar to ref-t18-*.png, with the app's fonts
/// at device pixel ratio 2: the bar with the pen and its floating bar
/// (586 wide as the 9th draft c frame, and a 360 phone), the pen panel open,
/// the eraser's bar and the zoom badge; fix 1: the eraser's 고급 설정
/// open, the lasso and the move tool in hand, and the workspace row's ⋯
/// over the note with 손가락 필기 and 확대 비율. Runs only with
/// PIV_CAPTURE=1.
final _capture = Platform.environment['PIV_CAPTURE'] == '1';
final _outDir = captureDir('build/screen-review/t18');
const _latin = captureLatin;
const _korean = captureKorean;
const _page = 420.0;

/// A few strokes, so the page is not empty.
final _document = InfiniteDocument(
  strokes: [
    for (final (i, y) in [150.0, 190.0, 230.0].indexed)
      InfiniteStroke(
        id: 'line-$i',
        tool: InfiniteInkTool.pen,
        color: 0xff1f2329,
        width: 2.5,
        points: [
          for (var x = 60.0; x <= 300 - 40 * i; x += 10)
            InfinitePoint(x, y + (x % 30 == 0 ? 3 : -3), pressure: .7),
        ],
      ),
    InfiniteStroke(
      id: 'marker',
      tool: InfiniteInkTool.highlighter,
      color: 0xffffd400,
      width: 12.5,
      points: const [InfinitePoint(60, 190), InfinitePoint(220, 190)],
    ),
  ],
);

/// The editor's paper (the preview's `--paper` with a line every 22).
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

/// The editor's actions with [tool] in hand.
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
    a(AppActionIds.toolPen, KitIconName.pen, checked: isInkTool(tool)),
    a(AppActionIds.toolEraser, KitIconName.eraser, checked: tool is Eraser),
    a(AppActionIds.toolText, KitIconName.text, checked: false),
    a(AppActionIds.toolShapes, KitIconName.shapes, checked: false),
    a(AppActionIds.pickPhoto, KitIconName.image),
    a(AppActionIds.insertPage, KitIconName.pageAdd),
    a(AppActionIds.fullscreen, KitIconName.expand, checked: false),
  ]);
}

void main() {
  FlavorConfig.setup();

  /// Draws [page] (the infinite note, or the editor's bar over its paper)
  /// on a [width] wide screen, runs [then] and writes `[file].png`.
  Future<void> shoot(
    WidgetTester tester,
    String file,
    Widget page, {
    double width = 586,
    Future<void> Function()? then,
  }) async {
    await tester.runAsync(loadCaptureFonts);
    final size = Size(width, 46 + _page);
    tester.view.physicalSize = size * 2;
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    stows.editorToolbarTools.value = const [];
    stows.pageToolbarLayout.value = const [];
    stows.editorGestureMode.value = false;
    stows.floatingBarPosition.value = 'top';
    stows.penPanelCollapsed.value = false;
    stows.recentColorsPositioned.value = const [];
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
          home: Material(child: page),
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
        File('$_outDir/$file.png').writeAsBytesSync(png.buffer.asUint8List());
        image.dispose();
      });
    } finally {
      debugDisableShadows = true;
    }
    expect(tester.takeException(), isNull);
    // the zoom badge's and the bar's timers go with the screen
    await tester.pumpWidget(const SizedBox());
  }

  Widget infinite({Future<void> Function(InfiniteDocument)? onSave}) =>
      InfiniteCanvas(
        initialDocument: _document,
        onSave: onSave ?? (_) async {},
        autosaveDelay: const Duration(hours: 1),
      );

  /// The editor's toolbar and floating bar with [tool] in hand over its
  /// paper, and [over] on top.
  Widget editor(Tool tool, {Widget? over, AppActionRegistry? actions}) {
    final registry = actions ?? AppActionRegistry();
    _publish(registry, tool);
    return Column(
      children: [
        KitEditorToolbar(
          actions: registry,
          title: '강의노트 3주차',
          floatingBarOpen: ValueNotifier(true),
          noteSheetOpen: ValueNotifier(false),
        ),
        Expanded(
          child: Stack(
            children: [
              const Positioned.fill(child: CustomPaint(painter: _Paper())),
              Positioned.fill(
                child: KitFloatingBar(
                  currentTool: tool,
                  setTool: (_) {},
                  setColor: (_) {},
                  actions: registry,
                  penPanelCollapsed: ValueNotifier(false),
                ),
              ),
              ?over,
            ],
          ),
        ),
      ],
    );
  }

  Pen fineNib() => Pen.fountainPen()..color = const Color(0xff1f2329);

  Future<void> tap(WidgetTester tester, String key) async {
    await tester.tap(find.byKey(ValueKey(key)));
    await tester.pumpAndSettle();
  }

  group('infinite note captures', skip: !_capture, () {
    testWidgets('bar', (tester) => shoot(tester, 'app-t18-bar', infinite()));
    testWidgets(
      'bar ref',
      (tester) => shoot(tester, 'ref-t18-bar', editor(fineNib())),
    );
    testWidgets(
      'phone',
      (tester) => shoot(tester, 'app-t18-phone', infinite(), width: 360),
    );
    testWidgets(
      'phone ref',
      (tester) => shoot(tester, 'ref-t18-phone', editor(fineNib()), width: 360),
    );
    testWidgets(
      'pen panel',
      (tester) => shoot(
        tester,
        'app-t18-penpanel',
        infinite(),
        then: () => tap(tester, 'floating-bar-pen-fountain'),
      ),
    );
    testWidgets(
      'pen panel ref',
      (tester) => shoot(
        tester,
        'ref-t18-penpanel',
        editor(fineNib()),
        then: () => tap(tester, 'floating-bar-pen-fountain'),
      ),
    );
    testWidgets(
      'eraser',
      (tester) => shoot(
        tester,
        'app-t18-eraser',
        infinite(),
        then: () => tap(tester, 'editor-tool-eraser'),
      ),
    );
    testWidgets(
      'eraser ref',
      (tester) => shoot(tester, 'ref-t18-eraser', editor(Eraser())),
    );
    testWidgets(
      'zoom',
      (tester) => shoot(
        tester,
        'app-t18-zoom',
        infinite(),
        then: () async {
          final surface = find.byKey(const ValueKey('infinite-surface'));
          final mouse = TestPointer(9, PointerDeviceKind.mouse);
          await tester.sendEventToBinding(
            mouse.hover(tester.getCenter(surface)),
          );
          await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
          // 300 · ln 1.5 down the wheel: 150 %
          await tester.sendEventToBinding(
            mouse.scroll(const Offset(0, -121.6)),
          );
          await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
          await tester.pump();
        },
      ),
    );
    testWidgets('zoom ref', (tester) {
      final scale = ValueNotifier(1.0);
      return shoot(
        tester,
        'ref-t18-zoom',
        editor(
          fineNib(),
          over: Positioned.fill(
            child: KitZoomBadge(scale: scale, shouldShow: () => true),
          ),
        ),
        then: () async {
          scale.value = 1.5;
          await tester.pump();
        },
      );
    });
    testWidgets(
      'eraser window',
      (tester) => shoot(
        tester,
        'app-t18-eraserwin',
        infinite(),
        then: () async {
          await tap(tester, 'editor-tool-eraser');
          await tap(tester, 'floating-bar-eraser-advanced');
        },
      ),
    );
    testWidgets(
      'eraser window ref',
      (tester) => shoot(
        tester,
        'ref-t18-eraserwin',
        editor(Eraser()),
        then: () => tap(tester, 'floating-bar-eraser-advanced'),
      ),
    );
    testWidgets(
      'lasso',
      (tester) => shoot(
        tester,
        'app-t18-lasso',
        infinite(),
        then: () => tap(tester, 'editor-tool-lasso'),
      ),
    );
    testWidgets(
      'lasso ref',
      (tester) => shoot(tester, 'ref-t18-lasso', editor(Select.currentSelect)),
    );
    testWidgets(
      'move',
      (tester) => shoot(
        tester,
        'app-t18-move',
        infinite(),
        then: () => tap(tester, 'editor-tool-move'),
      ),
    );
    for (final (name, submenu, off) in [
      ('rowmore', false, false),
      ('rowmore-off', false, true),
      ('rowzoom', true, false),
    ]) {
      var finger = true;
      testWidgets(
        name,
        (tester) => shoot(
          tester,
          'app-t18-$name',
          Column(
            children: [
              NoteFunctionRow(
                shortcuts: [
                  AppAction(
                    id: AppActionIds.prev,
                    label: '이전 위치',
                    icon: KitIconName.back,
                    run: (_) {},
                  ),
                  AppAction(
                    id: AppActionIds.save,
                    label: '기기에 저장',
                    icon: KitIconName.download,
                    run: (_) {},
                  ),
                ],
                layout: ShortcutLayout.decode(noteShortcutItems, const []),
                onCustomize: () {},
                switches: [
                  (
                    action: AppAction(
                      id: AppActionIds.finger,
                      label: '손가락 필기',
                      icon: KitIconName.tap,
                      run: (_) => finger = !finger,
                    ),
                    on: () => finger,
                  ),
                ],
                zoom: DocZoom(scale: () => 1.5, zoomTo: (_) {}),
              ),
              Expanded(child: infinite()),
            ],
          ),
          then: () async {
            await tap(tester, 'workspace-more-actions');
            if (submenu) await tap(tester, 'note-more-zoom');
            // pressed once, the window open: off
            if (off) await tap(tester, 'note-more-finger');
          },
        ),
      );
    }
    testWidgets(
      'saving',
      (tester) => shoot(
        tester,
        'app-t18-saving',
        // the save never ends while the picture is taken
        infinite(onSave: (_) => Completer<void>().future),
        then: () async {
          final page = tester.getTopLeft(
            find.byKey(const ValueKey('infinite-surface')),
          );
          final pen = await tester.createGesture(
            kind: PointerDeviceKind.stylus,
          );
          await pen.down(page + const Offset(300, 320));
          await pen.moveTo(page + const Offset(380, 340));
          await pen.up();
          await tester.pump();
          await tap(tester, 'editor-canvas-save');
        },
      ),
    );
  });
}
