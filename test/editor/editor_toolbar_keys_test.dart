import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart' show FlutterQuillLocalizations;
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/kit/kit_icon.dart';
import 'package:saber/components/theming/dynamic_material_app.dart';
import 'package:saber/data/actions/app_action.dart';
import 'package:saber/data/actions/app_action_ids.dart';
import 'package:saber/data/actions/app_action_registry.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/tools/eraser.dart';
import 'package:saber/data/tools/pen.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/editor/editor.dart';
import 'package:sbn/tool_id.dart';

import '../utils/test_mock_channel_handlers.dart';

/// The old toolbar's keys (Ctrl+F, Ctrl+E, Ctrl+C, Ctrl+Shift+S, F11,
/// Ctrl+V) are the editor's focus shortcuts now: they work while the focus
/// is in the editor and leave a text field inside it alone.
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
    stows.editorGestureMode.value = false;
    addTearDown(() {
      stows.lastTool.value = saved.$1;
      stows.lastPenFamily.value = saved.$2;
      stows.editorFingerDrawing.value = saved.$3;
      stows.hideFingerDrawingToggle.value = saved.$4;
      DynamicMaterialApp.setFullscreen(false, updateSystem: false);
    });
  });

  Future<EditorState> mountAlone(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          localizationsDelegates: const [FlutterQuillLocalizations.delegate],
          home: Editor(path: '/editor-toolbar-keys', onSaveSnapshot: (_, _) async {}),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return tester.state<EditorState>(find.byType(Editor));
  }

  Future<void> press(
    WidgetTester tester,
    LogicalKeyboardKey key, {
    bool control = false,
    bool shift = false,
  }) async {
    if (control) await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(key);
    if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    if (control) await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
  }

  final bar = find.byKey(const ValueKey('kit-floating-bar'));

  /// Stand-ins for the paste and export actions, published after the
  /// editor's own (the later publisher wins until the editor builds again):
  /// the ids they ran go into the returned list ([into] to add to one).
  List<String> fakeActions(WidgetTester tester, [List<String>? into]) {
    final ran = into ?? <String>[];
    final actions = tester
        .widget<AppActionScope>(find.byType(AppActionScope))
        .notifier!;
    actions.publish(_fakeOwner, [
      for (final id in const [AppActionIds.paste, AppActionIds.export])
        AppAction(
          id: id,
          label: id,
          icon: KitIconName.paste,
          run: (_) => ran.add(id),
        ),
    ]);
    return ran;
  }

  testWidgets('the keys work in the editor', (tester) async {
    final editor = await mountAlone(tester);
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'Editor');

    await press(tester, LogicalKeyboardKey.keyE, control: true);
    expect(editor.currentTool, isA<Eraser>(), reason: 'Ctrl+E');
    await press(tester, LogicalKeyboardKey.keyE, control: true);
    expect(editor.currentTool, isA<Pen>(), reason: 'Ctrl+E again');

    await press(tester, LogicalKeyboardKey.keyF, control: true);
    expect(stows.editorFingerDrawing.value, isFalse, reason: 'Ctrl+F');

    expect(bar, findsOneWidget);
    await press(tester, LogicalKeyboardKey.keyC, control: true);
    expect(bar, findsNothing, reason: 'Ctrl+C hides the colours');
    await press(tester, LogicalKeyboardKey.keyC, control: true);
    expect(bar, findsOneWidget, reason: 'Ctrl+C shows them');

    await press(tester, LogicalKeyboardKey.f11);
    expect(DynamicMaterialApp.isFullscreen, isTrue, reason: 'F11');
    await press(tester, LogicalKeyboardKey.f11);
    expect(DynamicMaterialApp.isFullscreen, isFalse);

    final ran = fakeActions(tester);
    await press(tester, LogicalKeyboardKey.keyS, control: true, shift: true);
    fakeActions(tester, ran);
    await press(tester, LogicalKeyboardKey.keyV, control: true);
    expect(ran, [AppActionIds.export, AppActionIds.paste]);
    editor.cancelAutosaveAndMarkSaved();
  });

  testWidgets('Ctrl+E writes again from gesture mode and brings the bar', (
    tester,
  ) async {
    final editor = await mountAlone(tester);
    // the pen in hand with its bar hidden, in gesture mode
    await tester.tap(find.byKey(const ValueKey('editor-tool-pen')));
    await tester.pumpAndSettle();
    expect(bar, findsNothing);
    await tester.tap(find.byKey(const ValueKey('editor-mode')));
    await tester.pumpAndSettle();
    expect(stows.editorGestureMode.value, isTrue);

    await press(tester, LogicalKeyboardKey.keyE, control: true);
    expect(editor.currentTool, isA<Eraser>());
    expect(stows.editorGestureMode.value, isFalse, reason: 'back to writing');
    expect(bar, findsOneWidget, reason: 'the eraser bar, as its button');
    // the button again hides it, as before
    await tester.tap(find.byKey(const ValueKey('editor-tool-eraser')));
    await tester.pumpAndSettle();
    expect(bar, findsNothing);
    // Ctrl+E puts the pen back with its bar
    await press(tester, LogicalKeyboardKey.keyE, control: true);
    expect(editor.currentTool, isA<Pen>());
    expect(bar, findsOneWidget);
    editor.cancelAutosaveAndMarkSaved();
  });

  testWidgets('a text field in the editor keeps the keys', (tester) async {
    final editor = await mountAlone(tester);
    final name = find.byType(TextField);
    await tester.tap(name);
    await tester.pump();
    await press(tester, LogicalKeyboardKey.keyE, control: true);
    expect(editor.currentTool, isA<Pen>(), reason: 'Ctrl+E while typing');
    await press(tester, LogicalKeyboardKey.keyF, control: true);
    expect(stows.editorFingerDrawing.value, isTrue, reason: 'Ctrl+F');
    await press(tester, LogicalKeyboardKey.keyC, control: true);
    expect(bar, findsOneWidget, reason: 'Ctrl+C copies the text');
    await press(tester, LogicalKeyboardKey.f11);
    expect(DynamicMaterialApp.isFullscreen, isFalse, reason: 'F11');
    final ran = fakeActions(tester);
    await press(tester, LogicalKeyboardKey.keyV, control: true);
    fakeActions(tester, ran);
    await press(tester, LogicalKeyboardKey.keyS, control: true, shift: true);
    expect(ran, isEmpty, reason: 'Ctrl+V and Ctrl+Shift+S stay with the field');
  });
}
