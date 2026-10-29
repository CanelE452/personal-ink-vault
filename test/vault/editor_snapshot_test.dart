import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/canvas/save_indicator.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/tools/eraser.dart';
import 'package:saber/data/tools/select.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/editor/editor.dart';

import '../utils/test_editor.dart';
import '../utils/test_mock_channel_handlers.dart';

void main() {
  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    setupMockPathProvider();
    setupMockPrinting();
    setupMockWindowManager();
    FlavorConfig.setup();
    await FileManager.init();
  });
  testWidgets(
    'failed canonical capture stays dirty and retry publishes only once',
    (tester) async {
      var calls = 0;
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: Editor(
              path: '/snapshot-test',
              customTitle: 'Test',
              onSaveSnapshot: (core, page) async {
                if (++calls == 1) throw StateError('synthetic capture failure');
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final editor = tester.state<EditorState>(find.byType(Editor));
      editor.drawTestStroke();
      await editor.saveToFile();
      expect(editor.savingState.value, SavingState.waitingToSave);
      await tester.pump();
      expect(find.textContaining('기기 저장 실패'), findsOneWidget);
      await editor.saveToFile();
      expect(editor.savingState.value, SavingState.saved);
      expect(calls, 2);
      editor.cancelAutosaveAndMarkSaved();
    },
  );
  for (final tool in ['pen', 'eraser', 'select']) {
    testWidgets(
      '$tool gesture protects work before its end and forbids capture',
      (tester) async {
        var dirty = false;
        var saves = 0;
        await tester.pumpWidget(
          TranslationProvider(
            child: MaterialApp(
              home: Editor(
                path: '/gesture-$tool',
                customTitle: 'Gesture',
                onDirtyChanged: (value) => dirty = value,
                onSaveSnapshot: (_, _) async {
                  saves++;
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final editor = tester.state<EditorState>(find.byType(Editor));
        editor.drawTestStroke();
        await editor.saveToFile();
        final saved = saves;
        if (tool == 'eraser') editor.currentTool = Eraser();
        if (tool == 'select') editor.currentTool = Select.currentSelect;
        final box = editor.coreInfo.pages.first.renderBox!;
        editor.dragPageIndex = 0;
        editor.onDrawStart(
          ScaleStartDetails(
            focalPoint: box.localToGlobal(const Offset(40, 40)),
            pointerCount: 1,
          ),
        );
        expect(
          dirty,
          isTrue,
          reason: 'remote refresh must not replace a live gesture',
        );
        await editor.saveToFile();
        expect(
          saves,
          saved,
          reason: 'unfinished gestures must never be snapshotted',
        );
        editor.onDrawUpdate(
          ScaleUpdateDetails(
            focalPoint: box.localToGlobal(const Offset(90, 90)),
            pointerCount: 1,
          ),
        );
        editor.onDrawEnd(ScaleEndDetails());
        await editor.saveToFile();
        editor.cancelAutosaveAndMarkSaved();
      },
    );
  }
  testWidgets(
    'caller waits for existing capture before reporting save complete',
    (tester) async {
      final started = Completer<void>(), release = Completer<void>();
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: Editor(
              path: '/capture-wait',
              customTitle: 'Capture',
              onSaveSnapshot: (_, _) async {
                started.complete();
                await release.future;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final editor = tester.state<EditorState>(find.byType(Editor));
      editor.drawTestStroke();
      final first = editor.saveToFile();
      await started.future;
      var finished = false;
      final second = editor.saveToFile().then((_) => finished = true);
      await tester.pump();
      expect(finished, isFalse);
      release.complete();
      await Future.wait([first, second]);
      expect(editor.savingState.value, SavingState.saved);
      editor.cancelAutosaveAndMarkSaved();
    },
  );
}
