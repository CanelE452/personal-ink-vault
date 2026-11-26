import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/kit/kit_tokens.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/editor/editor.dart';

import '../utils/test_mock_channel_handlers.dart';

/// 「기본 색은 최근 색에 넣지 않기」 keeps the pen panel's basic colours (its
/// first colour page, 「기본 색」; design 「기본 8색」) out of the recent
/// colours when the editor gives a pen a colour; pastel and grey colours go
/// in. The 229 palette that the rule read before is gone (Task 19, ruling in
/// fix 1).
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
    final dontSave = stows.recentColorsDontSavePresets.value;
    final recent = List.of(stows.recentColorsChronological.value);
    final placed = List.of(stows.recentColorsPositioned.value);
    final pinned = List.of(stows.pinnedColors.value);
    stows.recentColorsChronological.value = [];
    stows.recentColorsPositioned.value = [];
    stows.pinnedColors.value = [];
    addTearDown(() {
      stows.recentColorsDontSavePresets.value = dontSave;
      stows.recentColorsChronological.value = recent;
      stows.recentColorsPositioned.value = placed;
      stows.pinnedColors.value = pinned;
    });
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Editor(
            path: '/editor-recent-colours',
            onSaveSnapshot: (_, _) async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return tester.state<EditorState>(find.byType(Editor));
  }

  String text(Color colour) => colour.toARGB32().toString();

  testWidgets('a basic colour stays out of the recent colours when 기본 색은 최근 색에 넣지 않기 is on', (
    tester,
  ) async {
    final editor = await mountEditor(tester);
    stows.recentColorsDontSavePresets.value = true;
    for (final basic in KitTokens.penPanelColorPages[0]) {
      editor.updateColorBar(basic);
    }
    expect(stows.recentColorsPositioned.value, isEmpty);

    // the pastel and grey pages are not 「기본 색」: they go in
    final pastel = KitTokens.penPanelColorPages[1].last;
    final grey = KitTokens.penPanelColorPages[2][1];
    const other = Color(0xff123456);
    for (final colour in [pastel, grey, other]) {
      editor.updateColorBar(colour);
    }
    expect(stows.recentColorsPositioned.value.toSet(), {
      text(pastel),
      text(grey),
      text(other),
    });
  });

  testWidgets('with the setting off a basic colour goes into the recent colours', (
    tester,
  ) async {
    final editor = await mountEditor(tester);
    stows.recentColorsDontSavePresets.value = false;
    final basic = KitTokens.penPanelColorPages[0].first;
    editor.updateColorBar(basic);
    expect(stows.recentColorsPositioned.value, [text(basic)]);
  });
}
