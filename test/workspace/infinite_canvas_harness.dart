import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/ink_ui/editor_toolbar/kit_editor_toolbar.dart';
import 'package:saber/data/actions/app_action_registry.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/tools/eraser.dart';
import 'package:saber/data/vault/infinite_document.dart';
import 'package:saber/pages/workspace/infinite_canvas.dart';

// What the infinite note's tests share: a stroke, the settings its bars read,
// the canvas on a screen of a given size, a pen stroke on it, and finders.

InfiniteStroke stroke({
  String id = 'stroke-1',
  double x = -1000000,
  double y = -50,
  InfiniteInkTool tool = InfiniteInkTool.pen,
}) => InfiniteStroke(
  id: id,
  tool: tool,
  color: 0xff112233,
  width: 3,
  points: [
    InfinitePoint(x, y, pressure: .4),
    InfinitePoint(x + 20, y + 10, pressure: .9),
  ],
);

/// Puts the settings the infinite note's bars read back to their defaults.
void resetInkSettings() {
  stows.editorGestureMode.value = false;
  stows.floatingBarPosition.value = stows.floatingBarPosition.defaultValue;
  stows.penPanelCollapsed.value = false;
  stows.recentColorsPositioned.value = const [];
  stows.eraserSize.value = stows.eraserSize.defaultValue;
  stows.eraserMode.value = EraserMode.stroke;
  stows.eraserTargets.value = const [];
  stows.eraseHighlighterOnly.value = false;
  stows.disableEraserAfterUse.value = false;
  stows.selectRectangle.value = false;
  stows.selectInk.value = true;
  stows.selectHighlighter.value = true;
  stows.selectShapes.value = true;
  stows.selectImages.value = true;
  // shared with the editor; the tests that write with a finger turn it on
  stows.editorFingerDrawing.value = false;
  stows.lastZoomLock.value = false;
}

Future<GlobalKey<InfiniteCanvasState>> mount(
  WidgetTester tester, {
  InfiniteDocument initial = const InfiniteDocument.empty(),
  Future<void> Function(InfiniteDocument)? onSave,
  ValueChanged<bool>? onDirty,
  ValueChanged<bool>? onBusy,
  InfiniteViewport initialViewport = const InfiniteViewport(),
  Future<void> Function(InfiniteViewport)? onSaveViewport,
  Size size = const Size(800, 600),
  bool vaultKeepsAttachments = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final key = GlobalKey<InfiniteCanvasState>();
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(size: size),
      child: MaterialApp(
        home: Scaffold(
          body: InfiniteCanvas(
            key: key,
            initialDocument: initial,
            onSave: onSave ?? (_) async {},
            initialViewport: initialViewport,
            onSaveViewport: onSaveViewport,
            onDirtyChanged: onDirty,
            onBusyChanged: onBusy,
            autosaveDelay: const Duration(hours: 1),
            vaultKeepsAttachments: vaultKeepsAttachments,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return key;
}

final surface = find.byKey(const ValueKey('infinite-surface'));

Future<void> draw(
  WidgetTester tester,
  List<Offset> localPoints, {
  int pointer = 1,
}) async {
  final origin = tester.getTopLeft(surface);
  final gesture = await tester.createGesture(
    kind: PointerDeviceKind.stylus,
    pointer: pointer,
  );
  await gesture.down(origin + localPoints.first);
  for (final point in localPoints.skip(1)) {
    await gesture.moveTo(origin + point);
  }
  await gesture.up();
  await tester.pump();
}

Finder byKey(String key) => find.byKey(ValueKey(key));

/// The infinite note's own actions, as its toolbar runs them.
AppActionRegistry actionsOf(WidgetTester tester) =>
    tester.widget<KitEditorToolbar>(find.byType(KitEditorToolbar)).actions;

/// Whether the action [id] is on; fails when the note does not publish it.
bool checked(WidgetTester tester, String id) {
  final action = actionsOf(tester).lookup(id);
  expect(action, isNotNull, reason: '$id is published');
  return action!.checked!;
}

bool selected(WidgetTester tester, Finder f) =>
    tester.getSemantics(f).flagsCollection.isSelected.toBoolOrNull() ?? false;

/// Taps [f] and lets its window or bar settle.
Future<void> press(WidgetTester tester, Finder f) async {
  await tester.tap(f);
  await tester.pumpAndSettle();
}
