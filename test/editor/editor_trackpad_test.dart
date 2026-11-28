import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart' show FlutterQuillLocalizations;
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/tools/pen.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/editor/editor.dart';

import '../utils/test_mock_channel_handlers.dart';

/// A trackpad scroll or pinch moves the page; it never leaves ink, whatever
/// the finger drawing setting says.
void main() {
  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    setupMockPathProvider();
    setupMockPrinting();
    setupMockWindowManager();
    FlavorConfig.setup();
    await FileManager.init();
  });

  Future<EditorState> mountEditor(WidgetTester tester) async {
    final previousLayout = stows.pageToolbarLayout.value;
    final previousTool = stows.lastTool.value;
    final previousFinger = stows.editorFingerDrawing.value;
    stows.pageToolbarLayout.value = const [];
    stows.lastTool.value = stows.lastTool.defaultValue;
    tester.view.physicalSize = const Size(1200, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      stows.pageToolbarLayout.value = previousLayout;
      stows.lastTool.value = previousTool;
      stows.editorFingerDrawing.value = previousFinger;
      Pen.currentPen = Pen.fountainPen();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          localizationsDelegates: const [FlutterQuillLocalizations.delegate],
          home: Editor(path: '/trackpad-page', onSaveSnapshot: (_, _) async {}),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return tester.state<EditorState>(find.byType(Editor));
  }

  testWidgets('a trackpad pan-zoom with finger drawing on leaves no stroke', (
    tester,
  ) async {
    final editor = await mountEditor(tester);
    final page = editor.coreInfo.pages.first;
    stows.editorFingerDrawing.value = true;
    final from = page.renderBox!.localToGlobal(const Offset(300, 300));

    final trackpad = await tester.createGesture(kind: PointerDeviceKind.trackpad);
    await trackpad.panZoomStart(from);
    for (var i = 1; i <= 5; i++) {
      await trackpad.panZoomUpdate(from, pan: Offset(0, -20.0 * i));
    }
    await trackpad.panZoomEnd();
    await tester.pump();
    expect(page.strokes, isEmpty, reason: 'the scroll added no ink');

  });

  testWidgets('a finger with finger drawing on does leave a stroke', (
    tester,
  ) async {
    final editor = await mountEditor(tester);
    final page = editor.coreInfo.pages.first;
    stows.editorFingerDrawing.value = true;
    final from = page.renderBox!.localToGlobal(const Offset(300, 300));
    final finger = await tester.startGesture(from);
    await finger.moveTo(from + const Offset(40, 5));
    await finger.moveTo(from + const Offset(80, 10));
    await finger.up();
    await tester.pump();
    expect(page.strokes, hasLength(1), reason: 'finger drawing is live');
  });
}
