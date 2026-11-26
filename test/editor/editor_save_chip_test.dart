import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart'
    show FlutterQuillLocalizations;
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/ink_ui/editor_toolbar/kit_save_chip.dart';
import 'package:saber/components/ink_ui/floating_bar/kit_floating_bar.dart';
import 'package:saber/data/editor/saving_state.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/editor/editor.dart';

import '../utils/test_editor.dart';
import '../utils/test_mock_channel_handlers.dart';

/// The save chip in the editor and the failed save (Task 13B-2).
void main() {
  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    setupMockPathProvider();
    setupMockPrinting();
    setupMockWindowManager();
    FlavorConfig.setup();
    await FileManager.init();
  });

  final chip = find.byKey(const ValueKey('kit-save-chip'));

  String? says(WidgetTester tester) {
    if (chip.evaluate().isEmpty) return null;
    return tester
        .widgetList<Text>(
          find.descendant(of: chip, matching: find.byType(Text)),
        )
        .map((t) => t.data)
        .join();
  }

  testWidgets('a throwing save shows not saved and retries on tap', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var calls = 0;
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(size: Size(1000, 1400)),
        child: TranslationProvider(
          child: MaterialApp(
            localizationsDelegates: const [FlutterQuillLocalizations.delegate],
            home: Editor(
              path: '/save-chip',
              customTitle: 'Test',
              onSaveSnapshot: (_, _) async {
                if (++calls == 1) throw StateError('synthetic save failure');
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final editor = tester.state<EditorState>(find.byType(Editor));
    expect(find.byType(KitSaveChip), findsOneWidget);
    expect(says(tester), isNull, reason: 'nothing while saved');

    editor.drawTestStroke();
    await editor.saveToFile();
    expect(editor.savingState.value, SavingState.failed);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 180));
    expect(says(tester), '저장 안 됨 · 다시 시도');
    // the old banner stays (it also holds 「PDF 가져오기 취소」)
    expect(find.textContaining('기기 저장 실패'), findsOneWidget);
    // under the floating bar, at the page's top right
    final area = tester.getRect(find.byType(KitFloatingBar));
    expect(
      tester.getRect(chip).topRight,
      area.topRight + const Offset(-12, 58),
    );

    await tester.tap(chip);
    await tester.pump();
    expect(calls, 2);
    expect(editor.savingState.value, SavingState.saved);
    await tester.pumpAndSettle();
    expect(says(tester), isNull);
    editor.cancelAutosaveAndMarkSaved();
  });

  testWidgets('failed saves again like waiting', (tester) async {
    await tester.pumpWidget(
      TranslationProvider(child: MaterialApp(home: Editor())),
    );
    final editor = tester.state<EditorState>(find.byType(Editor));
    editor.drawTestStroke();
    await tester.pump();
    final file = FileManager.getFile(
      editor.coreInfo.filePath + Editor.extension,
    );
    await tester.runAsync(() async {
      if (file.existsSync()) await file.delete();
    });
    // a write that failed before: the next save writes like a waiting one
    editor.savingState.value = SavingState.failed;
    await tester.runAsync(editor.saveToFile);
    expect(editor.savingState.value, SavingState.saved);
    expect(await tester.runAsync(file.exists), isTrue);
    editor.cancelAutosaveAndMarkSaved();
  });
}
