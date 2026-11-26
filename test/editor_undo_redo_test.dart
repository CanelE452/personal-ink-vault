import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:golden_screenshot/golden_screenshot.dart';
import 'package:saber/components/kit/kit_pill.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/editor/editor.dart';

import 'utils/test_mock_channel_handlers.dart';

void main() {
  testGoldens('Editor: undo/redo buttons interaction test', (tester) async {
    TestWidgetsFlutterBinding.ensureInitialized();

    setupMockPathProvider();
    setupMockPrinting();

    FlavorConfig.setup();
    await tester.runAsync(FileManager.init);

    await tester.pumpWidget(
      TranslationProvider(
        child: ScreenshotApp(
          device: GoldenScreenshotDevices.androidPhone.device,
          home: Editor(),
        ),
      ),
    );

    await tester.pumpAndSettle();
    final editorState = tester.state<EditorState>(find.byType(Editor));
    expect(
      editorState.coreInfo.readOnly,
      isFalse,
      reason: 'New file should not be read-only',
    );
    addTearDown(editorState.cancelAutosaveAndMarkSaved);

    // undo and redo are the floating bar's (Task 13B-1)
    const undo = ValueKey('floating-bar-undo');
    const redo = ValueKey('floating-bar-redo');
    KitPillButton getUndoBtn() => tester.widget<KitPillButton>(find.byKey(undo));
    KitPillButton getRedoBtn() => tester.widget<KitPillButton>(find.byKey(redo));

    expect(
      [getUndoBtn().onPressed, getRedoBtn().onPressed],
      [isNull, isNull],
      reason: 'Undo/redo buttons should be disabled initially',
    );

    await drawOnEditor(tester);
    await tester.pump();
    await tester.pump();
    expect(editorState.coreInfo.pages.first.strokes, hasLength(1));
    expect(
      [getUndoBtn().onPressed, getRedoBtn().onPressed],
      [isNotNull, isNull],
      reason: 'Undo button should be enabled after first draw',
    );

    // undo
    await tester.tap(find.byKey(undo));
    await tester.pump();
    await tester.pump();
    expect(editorState.coreInfo.pages.first.strokes, hasLength(0));
    expect(
      [getUndoBtn().onPressed, getRedoBtn().onPressed],
      [isNull, isNotNull],
      reason: 'Undo button should be disabled after undo',
    );

    // redo
    await tester.tap(find.byKey(redo));
    await tester.pump();
    await tester.pump();
    expect(editorState.coreInfo.pages.first.strokes, hasLength(1));
    expect(
      [getUndoBtn().onPressed, getRedoBtn().onPressed],
      [isNotNull, isNull],
      reason: 'Undo button should be enabled after redo',
    );

    // undo, then draw again
    await tester.tap(find.byKey(undo));
    await tester.pump();
    await tester.pump();
    expect(editorState.coreInfo.pages.first.strokes, hasLength(0));
    await drawOnEditor(tester);
    await tester.pump();
    await tester.pump();
    expect(editorState.coreInfo.pages.first.strokes, hasLength(1));
    expect(
      [getUndoBtn().onPressed, getRedoBtn().onPressed],
      [isNotNull, isNull],
      reason: 'Undo button should be enabled after undo and draw',
    );
  });
}

Future drawOnEditor(WidgetTester tester) => tester.timedDrag(
  find.byType(Editor),
  const Offset(50, 0),
  const Duration(milliseconds: 100),
);
