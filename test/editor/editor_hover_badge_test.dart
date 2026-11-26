import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter_quill/flutter_quill.dart'
    show FlutterQuillLocalizations;
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/canvas/canvas_gesture_detector.dart';
import 'package:saber/components/canvas/interactive_canvas.dart';
import 'package:saber/components/kit/kit_icon.dart';
import 'package:saber/components/kit/kit_pen_art.dart';
import 'package:saber/data/actions/app_action_ids.dart';
import 'package:saber/data/actions/app_action_registry.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/tools/eraser.dart';
import 'package:saber/data/tools/pencil.dart';
import 'package:saber/data/tools/select.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/editor/editor.dart';
import 'package:sbn/tool_id.dart';

import '../utils/test_mock_channel_handlers.dart';

/// The pen tip badge in the editor (Task 16): beside the S Pen's tip while
/// it hovers over the page, showing what a touch would write with.
void main() {
  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    setupMockPathProvider();
    setupMockPrinting();
    setupMockWindowManager();
    FlavorConfig.setup();
    await FileManager.init();
    final saved = (
      stows.lastTool.value,
      stows.lastPenFamily.value,
      stows.editorToolbarTools.value,
      stows.pageToolbarLayout.value,
      stows.selectRectangle.value,
      stows.floatingBarPosition.value,
    );
    stows.lastTool.value = ToolId.fountainPen;
    stows.lastPenFamily.value = ToolId.fountainPen;
    stows.editorToolbarTools.value = const [];
    stows.pageToolbarLayout.value = const [];
    stows.editorGestureMode.value = false;
    stows.selectRectangle.value = false;
    stows.floatingBarPosition.value = 'top';
    addTearDown(() {
      stows.lastTool.value = saved.$1;
      stows.lastPenFamily.value = saved.$2;
      stows.editorToolbarTools.value = saved.$3;
      stows.pageToolbarLayout.value = saved.$4;
      stows.selectRectangle.value = saved.$5;
      stows.floatingBarPosition.value = saved.$6;
      stows.editorGestureMode.value = false;
    });
  });

  // each editor its own path: the canvas keeps the last zoom and scroll
  // of a path for the next editor of that path
  var opened = 0;

  Future<EditorState> mountEditor(WidgetTester tester) async {
    const size = Size(1000, 1400);
    final path = '/editor-hover-badge-${opened++}';
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(size: size),
        child: TranslationProvider(
          child: MaterialApp(
            localizationsDelegates: const [FlutterQuillLocalizations.delegate],
            home: Editor(
              key: ValueKey(path),
              path: path,
              onSaveSnapshot: (_, _) async {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return tester.state<EditorState>(find.byType(Editor));
  }

  final badge = find.byKey(const ValueKey('kit-hover-badge'));
  final dot = find.byKey(const ValueKey('kit-hover-dot'));

  KitIconName icon(WidgetTester tester) => tester
      .widget<KitIcon>(
        find.descendant(of: badge, matching: find.byType(KitIcon)),
      )
      .name;

  Offset pageCentre(WidgetTester tester, EditorState editor) {
    final page = editor.coreInfo.pages.first;
    final box = page.renderBox!;
    return Rect.fromPoints(
      box.localToGlobal(Offset.zero),
      box.localToGlobal(page.size.bottomRight(Offset.zero)),
    ).intersect(tester.getRect(find.byType(InteractiveCanvasViewer))).center;
  }

  Future<TestGesture> hover(WidgetTester tester, Offset at) async {
    final pen = await tester.createGesture(kind: PointerDeviceKind.stylus);
    await pen.addPointer(location: at - const Offset(4, 4));
    await pen.moveTo(at);
    await tester.pump();
    return pen;
  }

  AppActionRegistry actionsOf(WidgetTester tester) =>
      tester.widget<AppActionScope>(find.byType(AppActionScope)).notifier!;

  testWidgets('the badge sits beside the tip over the page', (tester) async {
    final editor = await mountEditor(tester);
    final tip = pageCentre(tester, editor);
    final pen = await hover(tester, tip);
    // the preview's: badge at the tip + (10, -34), the dot's middle on it
    expect(tester.getRect(badge).topLeft, tip + const Offset(10, -34));
    expect(tester.getCenter(dot), tip);
    expect(icon(tester), KitIconName.pen);
    await pen.down(tip);
    await tester.pump();
    expect(badge, findsNothing);
    await pen.up();
    await pen.removePointer();
    editor.cancelAutosaveAndMarkSaved();
  });

  testWidgets('the pen button held while hovering shows the eraser', (
    tester,
  ) async {
    final editor = await mountEditor(tester);
    final tip = pageCentre(tester, editor);
    // the S Pen's side button: a hover with the secondary button
    const device = 7;
    await tester.sendEventToBinding(
      PointerAddedEvent(
        kind: PointerDeviceKind.stylus,
        device: device,
        position: tip - const Offset(4, 4),
      ),
    );
    await tester.sendEventToBinding(
      PointerHoverEvent(
        kind: PointerDeviceKind.stylus,
        device: device,
        position: tip,
        buttons: kSecondaryButton,
      ),
    );
    await tester.pump();
    expect(editor.currentTool, isA<Eraser>());
    expect(icon(tester), KitIconName.eraser);
    // let go of the button: the pen again
    await tester.sendEventToBinding(
      PointerHoverEvent(
        kind: PointerDeviceKind.stylus,
        device: device,
        position: tip + const Offset(6, 0),
      ),
    );
    await tester.pump();
    expect(editor.currentTool, isNot(isA<Eraser>()));
    expect(icon(tester), KitIconName.pen);
    await tester.sendEventToBinding(
      PointerRemovedEvent(
        kind: PointerDeviceKind.stylus,
        device: device,
        position: tip + const Offset(6, 0),
      ),
    );
    await tester.pump();
    expect(badge, findsNothing);
    editor.cancelAutosaveAndMarkSaved();
  });

  testWidgets('the rectangle lasso shows its icon, as its button does', (
    tester,
  ) async {
    stows.selectRectangle.value = true;
    final editor = await mountEditor(tester);
    await tester.tap(find.byKey(const ValueKey('editor-tool-lasso')));
    await tester.pumpAndSettle();
    expect(editor.currentTool, isA<Select>());
    final pen = await hover(tester, pageCentre(tester, editor));
    expect(icon(tester), KitIconName.lassoRect);
    stows.selectRectangle.value = false;
    await tester.pump();
    expect(icon(tester), KitIconName.lassoFree);
    await pen.removePointer();
    Select.currentSelect.unselect();
    editor.cancelAutosaveAndMarkSaved();
  });

  testWidgets('hovering does not repaint the page', (tester) async {
    final editor = await mountEditor(tester);
    final tip = pageCentre(tester, editor);
    final pen = await hover(tester, tip);
    final page =
        editor.coreInfo.pages.first.innerCanvasKey.currentContext!
                .findRenderObject()!
            as RenderRepaintBoundary;
    RenderRepaintBoundary boundaryAbove(RenderObject start) {
      var at = start.parent;
      while (at is! RenderRepaintBoundary) {
        at = at!.parent;
      }
      return at;
    }

    // the layers the canvas and the badge paint in
    final canvasLayer = boundaryAbove(
      tester.renderObject(find.byType(CanvasGestureDetector)),
    );
    final badgeLayer = boundaryAbove(tester.renderObject(badge));
    // A boundary painted on its own counts as asymmetric, and so does one
    // put back as it was when the boundary above it paints (proxy_box.dart
    // debugRegisterRepaintBoundaryPaint, object.dart flushPaint): both
    // counts unchanged means neither painted at all.
    (int, int) paints(RenderRepaintBoundary b) =>
        (b.debugSymmetricPaintCount, b.debugAsymmetricPaintCount);
    final before = (paints(page), paints(canvasLayer), paints(badgeLayer));
    for (var i = 1; i <= 5; i++) {
      await pen.moveTo(tip + Offset(12.0 * i, 6.0 * i));
      await tester.pump();
    }
    expect(
      tester.getRect(badge).topLeft,
      tip + const Offset(60, 30) + const Offset(10, -34),
    );
    expect(paints(page), before.$1);
    expect(paints(canvasLayer), before.$2);
    // the badge's own layer is what painted, once a move; it lies inside
    // the canvas's, so the counts above would see the badge without it
    expect(badgeLayer.debugAsymmetricPaintCount, before.$3.$2 + 5);
    expect(badgeLayer, isNot(same(canvasLayer)));
    var above = badgeLayer.parent;
    while (above != null && above != canvasLayer) {
      above = above.parent;
    }
    expect(above, same(canvasLayer));
    await pen.removePointer();
    editor.cancelAutosaveAndMarkSaved();
  });

  testWidgets('the badge takes no taps: the floating bar under it works', (
    tester,
  ) async {
    final editor = await mountEditor(tester);
    final button = find.byKey(
      ValueKey('floating-bar-pen-${KitPenKind.pencil.previewId}'),
    );
    final pill = tester.getRect(
      find.byKey(const ValueKey('floating-bar-tool-pill')),
    );
    final centre = tester.getCenter(button);
    // the tip just under the bar, the badge up over the pencil button
    final pen = await hover(tester, Offset(centre.dx - 27, pill.bottom + 2));
    expect(tester.getRect(badge).contains(centre), isTrue);
    expect(editor.currentTool, isNot(isA<Pencil>()));
    await tester.tapAt(centre, kind: PointerDeviceKind.stylus);
    await tester.pumpAndSettle();
    expect(editor.currentTool, isA<Pencil>());
    await pen.removePointer();
    editor.cancelAutosaveAndMarkSaved();
  });

  testWidgets('read-only shows no badge', (tester) async {
    final editor = await mountEditor(tester);
    final context = tester.element(find.byType(Editor));
    final actions = actionsOf(tester);
    actions.run(AppActionIds.readOnly, context);
    await tester.pump();
    expect(editor.inkLocked.value, isTrue);
    final tip = pageCentre(tester, editor);
    final pen = await hover(tester, tip);
    expect(badge, findsNothing);
    expect(dot, findsNothing);
    actions.run(AppActionIds.readOnly, context);
    await tester.pump();
    await pen.moveTo(tip + const Offset(6, 6));
    await tester.pump();
    expect(badge, findsOneWidget);
    await pen.removePointer();
    // the mode pill's own timers
    await tester.pumpAndSettle(const Duration(seconds: 3));
    editor.cancelAutosaveAndMarkSaved();
  });

  /// Hovers over the page while [on] holds, then after [off]: no badge
  /// while a touch would not write with the tool, the badge again after.
  Future<void> hiddenWhile(
    WidgetTester tester, {
    required void Function(EditorState editor) on,
    required void Function(EditorState editor) off,
  }) async {
    final editor = await mountEditor(tester);
    final tip = pageCentre(tester, editor);
    on(editor);
    await tester.pump();
    final pen = await hover(tester, tip);
    expect(badge, findsNothing);
    expect(dot, findsNothing);
    off(editor);
    await tester.pump();
    await pen.moveTo(tip + const Offset(6, 6));
    await tester.pump();
    expect(badge, findsOneWidget);
    await pen.removePointer();
    await tester.pumpAndSettle(const Duration(seconds: 5));
    editor.cancelAutosaveAndMarkSaved();
  }

  testWidgets('gesture mode shows no badge', (tester) async {
    await hiddenWhile(
      tester,
      on: (_) => stows.editorGestureMode.value = true,
      off: (_) => stows.editorGestureMode.value = false,
    );
  });

  testWidgets('the eyedropper waiting shows no badge', (tester) async {
    void eyedropper(EditorState editor) =>
        actionsOf(tester)
            .run(AppActionIds.eyedropper, tester.element(find.byType(Editor)));
    await hiddenWhile(tester, on: eyedropper, off: eyedropper);
  });

  testWidgets('placing a link shows no badge', (tester) async {
    void linkAdd(EditorState editor) =>
        actionsOf(tester)
            .run(AppActionIds.linkAdd, tester.element(find.byType(Editor)));
    await hiddenWhile(tester, on: linkAdd, off: linkAdd);
  });

  testWidgets('read-only clears the place: unlocking shows none until a move', (
    tester,
  ) async {
    final editor = await mountEditor(tester);
    final context = tester.element(find.byType(Editor));
    final actions = actionsOf(tester);
    final tip = pageCentre(tester, editor);
    final pen = await hover(tester, tip);
    expect(badge, findsOneWidget);
    actions.run(AppActionIds.readOnly, context);
    await tester.pump();
    expect(badge, findsNothing);
    // unlocked with the pen held still: the old place is gone
    actions.run(AppActionIds.readOnly, context);
    await tester.pump();
    expect(badge, findsNothing);
    await pen.moveTo(tip + const Offset(6, 6));
    await tester.pump();
    expect(tester.getRect(badge).topLeft, tip + const Offset(16, -28));
    await pen.removePointer();
    await tester.pumpAndSettle(const Duration(seconds: 3));
    editor.cancelAutosaveAndMarkSaved();
  });

  testWidgets('gesture mode clears the place: turning it off shows none until a move', (
    tester,
  ) async {
    final editor = await mountEditor(tester);
    final tip = pageCentre(tester, editor);
    final pen = await hover(tester, tip);
    expect(badge, findsOneWidget);
    stows.editorGestureMode.value = true;
    await tester.pump();
    expect(badge, findsNothing);
    // back to writing with the pen held still: the old place is gone
    stows.editorGestureMode.value = false;
    await tester.pump();
    expect(badge, findsNothing);
    expect(dot, findsNothing);
    await pen.moveTo(tip + const Offset(6, 6));
    await tester.pump();
    expect(tester.getRect(badge).topLeft, tip + const Offset(16, -28));
    await pen.removePointer();
    await tester.pumpAndSettle(const Duration(seconds: 5));
    editor.cancelAutosaveAndMarkSaved();
  });
}
