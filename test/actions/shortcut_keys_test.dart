import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart' show FlutterQuillLocalizations;
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/canvas/canvas_gesture_detector.dart';
import 'package:saber/components/kit/kit_icon.dart';
import 'package:saber/data/actions/app_action.dart';
import 'package:saber/data/actions/app_action_ids.dart';
import 'package:saber/data/actions/app_action_registry.dart';
import 'package:saber/data/actions/shortcut_keys.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/tools/eraser.dart';
import 'package:saber/data/tools/pen.dart';
import 'package:saber/data/vault/infinite_document.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/editor/editor.dart';
import 'package:saber/pages/workspace/infinite_canvas.dart';
import 'package:sbn/tool_id.dart';

import '../utils/test_mock_channel_handlers.dart';
import '../workspace/infinite_canvas_harness.dart' as infinite;

/// The four actions behind the old toolbar keys (gestureMode, floatingBar,
/// zoomLock, eraserBar) and the key table the editor and the infinite note
/// share (Task 4).
final _fakeOwner = Object();

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
      stows.editorFingerDrawing.value,
      stows.hideFingerDrawingToggle.value,
    );
    stows.lastTool.value = ToolId.fountainPen;
    stows.lastPenFamily.value = ToolId.fountainPen;
    stows.editorFingerDrawing.value = true;
    stows.hideFingerDrawingToggle.value = false;
    infinite.resetInkSettings();
    stows.editorFingerDrawing.value = true;
    addTearDown(() {
      stows.lastTool.value = saved.$1;
      stows.lastPenFamily.value = saved.$2;
      stows.editorFingerDrawing.value = saved.$3;
      stows.hideFingerDrawingToggle.value = saved.$4;
      infinite.resetInkSettings();
    });
  });

  test('the four ids are in the list and the table has ids that exist', () {
    for (final id in [
      AppActionIds.gestureMode,
      AppActionIds.floatingBar,
      AppActionIds.zoomLock,
      AppActionIds.eraserBar,
    ]) {
      expect(AppActionIds.all, contains(id));
    }
    expect(AppActionIds.eraserBar, 'eraserBar');
    final seen = <ShortcutActivator>{};
    for (final (key, id) in appShortcutKeys) {
      expect(AppActionIds.all, contains(id), reason: id);
      expect(seen.add(key), isTrue, reason: 'one id per key: $id');
    }
    expect([for (final (_, id) in appShortcutKeys) id], [
      AppActionIds.undo,
      AppActionIds.redo,
      AppActionIds.redo,
      AppActionIds.finger,
      AppActionIds.eraserBar,
      AppActionIds.floatingBar,
      AppActionIds.saveNow,
      AppActionIds.export,
      AppActionIds.fullscreen,
      AppActionIds.paste,
    ]);
  });

  testWidgets('shortcutCallbacks bind only the ids the registry has', (
    tester,
  ) async {
    final ran = <String>[];
    final actions = AppActionRegistry()
      ..publish(_fakeOwner, [
        AppAction(
          id: AppActionIds.undo,
          label: 'undo',
          icon: KitIconName.undo,
          run: (_) => ran.add(AppActionIds.undo),
        ),
      ]);
    addTearDown(actions.dispose);
    late BuildContext context;
    await tester.pumpWidget(
      Builder(
        builder: (c) {
          context = c;
          return const SizedBox();
        },
      ),
    );
    final callbacks = shortcutCallbacks(actions, context);
    expect(callbacks.length, 1, reason: 'only Ctrl+Z: undo is published');
    for (final (key, id) in appShortcutKeys) {
      expect(callbacks.containsKey(key), id == AppActionIds.undo, reason: id);
    }
    callbacks.values.single();
    expect(ran, [AppActionIds.undo]);
  });

  /// The editor alone on a 1000 x 1400 screen.
  Future<EditorState> mountEditor(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          localizationsDelegates: const [FlutterQuillLocalizations.delegate],
          home: Editor(path: '/shortcut-keys', onSaveSnapshot: (_, _) async {}),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return tester.state<EditorState>(find.byType(Editor));
  }

  AppActionRegistry editorActions(WidgetTester tester) =>
      tester.widget<AppActionScope>(find.byType(AppActionScope)).notifier!;

  final bar = find.byKey(const ValueKey('kit-floating-bar'));

  testWidgets(
    'zoomLock run alone toggles zoom lock in the editor and in the infinite note',
    (tester) async {
      final editor = await mountEditor(tester);
      final detector = tester.state<CanvasGestureDetectorState>(
        find.byType(CanvasGestureDetector),
      );
      final context = tester.element(find.byType(Editor));
      expect(stows.lastZoomLock.value, isFalse);
      expect(detector.zoomLockedValue, isNull);
      expect(
        editorActions(tester).run(AppActionIds.zoomLock, context),
        isTrue,
      );
      await tester.pump();
      expect(stows.lastZoomLock.value, isTrue);
      expect(detector.zoomLockedValue, isNotNull, reason: 'held at its scale');
      editorActions(tester).run(AppActionIds.zoomLock, context);
      await tester.pump();
      expect(stows.lastZoomLock.value, isFalse);
      expect(detector.zoomLockedValue, isNull);
      editor.cancelAutosaveAndMarkSaved();
      await tester.pumpWidget(const SizedBox());

      final key = await infinite.mount(tester);
      final infiniteContext = tester.element(find.byType(InfiniteCanvas));
      final actions = infinite.actionsOf(tester);
      final page = tester.getTopLeft(infinite.surface);
      final mouse = TestPointer(9, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(
        mouse.hover(page + const Offset(300, 300)),
      );
      Future<void> wheel() async {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendEventToBinding(mouse.scroll(const Offset(0, -60)));
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();
      }

      // unlocked, the same Ctrl+wheel zooms
      await wheel();
      final zoomed = key.currentState!.viewport.scale;
      expect(zoomed, isNot(1), reason: 'the wheel zooms while unlocked');
      expect(actions.run(AppActionIds.zoomLock, infiniteContext), isTrue);
      await tester.pump();
      expect(stows.lastZoomLock.value, isTrue);
      await wheel();
      expect(key.currentState!.viewport.scale, zoomed, reason: 'locked: held');
      actions.run(AppActionIds.zoomLock, infiniteContext);
      await tester.pump();
      expect(stows.lastZoomLock.value, isFalse);
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('eraserBar picks the eraser and shows the floating bar', (
    tester,
  ) async {
    final editor = await mountEditor(tester);
    // the pen in hand with its bar hidden, in gesture mode
    await tester.tap(find.byKey(const ValueKey('editor-tool-pen')));
    await tester.pumpAndSettle();
    expect(bar, findsNothing);
    stows.editorGestureMode.value = true;
    await tester.pump();
    final context = tester.element(find.byType(Editor));
    expect(
      editorActions(tester).run(AppActionIds.eraserBar, context),
      isTrue,
    );
    await tester.pumpAndSettle();
    expect(editor.currentTool, isA<Eraser>());
    expect(stows.editorGestureMode.value, isFalse);
    expect(bar, findsOneWidget);
    editorActions(tester).run(AppActionIds.eraserBar, context);
    await tester.pumpAndSettle();
    expect(editor.currentTool, isA<Pen>(), reason: 'the eraser again: the pen');
    editor.cancelAutosaveAndMarkSaved();
    await tester.pumpWidget(const SizedBox());

    await infinite.mount(tester);
    final infiniteContext = tester.element(find.byType(InfiniteCanvas));
    final actions = infinite.actionsOf(tester);
    stows.editorGestureMode.value = true;
    await tester.pump();
    expect(actions.run(AppActionIds.eraserBar, infiniteContext), isTrue);
    await tester.pumpAndSettle();
    expect(infinite.checked(tester, AppActionIds.toolEraser), isTrue);
    expect(stows.editorGestureMode.value, isFalse);
    expect(infinite.byKey('kit-floating-bar'), findsOneWidget);
    expect(infinite.byKey('floating-bar-eraser-kind'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('gestureMode and floatingBar flip their stows', (tester) async {
    final editor = await mountEditor(tester);
    final context = tester.element(find.byType(Editor));
    final actions = editorActions(tester);
    expect(stows.editorGestureMode.value, isFalse);
    expect(actions.run(AppActionIds.gestureMode, context), isTrue);
    expect(stows.editorGestureMode.value, isTrue);
    actions.run(AppActionIds.gestureMode, context);
    expect(stows.editorGestureMode.value, isFalse);
    expect(bar, findsOneWidget);
    expect(actions.run(AppActionIds.floatingBar, context), isTrue);
    await tester.pumpAndSettle();
    expect(bar, findsNothing, reason: 'hidden');
    actions.run(AppActionIds.floatingBar, context);
    await tester.pumpAndSettle();
    expect(bar, findsOneWidget, reason: 'shown');
    editor.cancelAutosaveAndMarkSaved();
    await tester.pumpWidget(const SizedBox());

    await infinite.mount(tester);
    final infiniteContext = tester.element(find.byType(InfiniteCanvas));
    final infiniteActions = infinite.actionsOf(tester);
    expect(infiniteActions.run(AppActionIds.gestureMode, infiniteContext), isTrue);
    expect(stows.editorGestureMode.value, isTrue);
    infiniteActions.run(AppActionIds.gestureMode, infiniteContext);
    expect(stows.editorGestureMode.value, isFalse);
    await tester.pumpAndSettle();
    expect(infinite.byKey('kit-floating-bar'), findsOneWidget);
    expect(
      infiniteActions.run(AppActionIds.floatingBar, infiniteContext),
      isTrue,
    );
    await tester.pumpAndSettle();
    expect(infinite.byKey('kit-floating-bar'), findsNothing);
    infiniteActions.run(AppActionIds.floatingBar, infiniteContext);
    await tester.pumpAndSettle();
    expect(infinite.byKey('kit-floating-bar'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  /// Stand-ins for every id in the table, published after the screen's own
  /// (the later publisher wins until the screen builds again), noting the
  /// ids that ran into [ran].
  void fakeAll(AppActionRegistry actions, List<String> ran) {
    actions.publish(_fakeOwner, [
      for (final id in {for (final (_, id) in appShortcutKeys) id})
        AppAction(
          id: id,
          label: id,
          icon: KitIconName.paste,
          run: (_) => ran.add(id),
        ),
    ]);
  }

  Future<void> sendActivator(WidgetTester tester, SingleActivator key) async {
    if (key.control) {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    }
    if (key.shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(key.trigger);
    if (key.shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    if (key.control) {
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    }
  }

  testWidgets('the editor and the infinite note answer the same keys', (
    tester,
  ) async {
    final editor = await mountEditor(tester);
    final ran = <String>[];
    for (final (key, id) in appShortcutKeys) {
      fakeAll(editorActions(tester), ran);
      ran.clear();
      await sendActivator(tester, key);
      await tester.pump();
      expect(ran, [id], reason: 'editor: ${key.trigger.keyLabel}');
    }
    editor.cancelAutosaveAndMarkSaved();
    await tester.pumpWidget(const SizedBox());

    await infinite.mount(tester);
    // the note binds the ids it has when it builds: put the stand-ins in,
    // let it build again, then put them in over its own
    fakeAll(infinite.actionsOf(tester), ran);
    stows.lastZoomLock.value = !stows.lastZoomLock.value;
    await tester.pump();
    for (final (key, id) in appShortcutKeys) {
      fakeAll(infinite.actionsOf(tester), ran);
      ran.clear();
      await sendActivator(tester, key);
      await tester.pump();
      expect(ran, [id], reason: 'infinite note: ${key.trigger.keyLabel}');
    }
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('keys the infinite note has no action for reach its ancestors', (
    tester,
  ) async {
    const size = Size(800, 600);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final reached = <LogicalKeyboardKey>[];
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(size: size),
        child: MaterialApp(
          home: Scaffold(
            body: Focus(
              onKeyEvent: (_, event) {
                if (event is KeyDownEvent) reached.add(event.logicalKey);
                return KeyEventResult.ignored;
              },
              child: InfiniteCanvas(
                initialDocument: const InfiniteDocument.empty(),
                onSave: (_) async {},
                autosaveDelay: const Duration(hours: 1),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final actions = infinite.actionsOf(tester);
    for (final (key, id) in appShortcutKeys) {
      reached.clear();
      await sendActivator(tester, key);
      await tester.pump();
      final trigger = key.trigger;
      if (actions.has(id)) {
        expect(reached, isNot(contains(trigger)), reason: '$id is handled');
      } else {
        expect(reached, contains(trigger), reason: '$id goes on: $trigger');
      }
    }
    for (final id in [
      AppActionIds.saveNow,
      AppActionIds.export,
      AppActionIds.fullscreen,
      AppActionIds.paste,
    ]) {
      expect(actions.has(id), isFalse, reason: id);
    }
    await tester.pumpWidget(const SizedBox());
  });
}
