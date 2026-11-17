import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/toolbar/toolbar.dart';
import 'package:saber/components/toolbar/toolbar_layout.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/tools/pen.dart';
import 'package:saber/data/tools/shape_pen.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/editor/editor.dart';

import 'utils/test_mock_channel_handlers.dart';

void main() {
  group('toolbar layout', () {
    test('the page toolbar lists only the tools, StarNote-style, with pencil and laser hidden', () {
      final layout = ToolbarLayout.decode(pageToolbarItems, const []);
      expect(pageToolbarItems.map((item) => item.id), [
        'pen',
        'pencil',
        'highlighter',
        'eraser',
        'select',
        'photo',
        'text',
        'laser',
      ]);
      expect(layout.shownIds.first, 'pen');
      expect(layout.shownIds, isNot(contains('laser')));
      expect(layout.shownIds, isNot(contains('pencil')));
      expect(layout.labelOf('select'), '올가미');
    });

    test('a stored layout keeps its order and drops ids that are no longer tools', () {
      // 228 and earlier stored undo, colours, widths and page actions in the same list.
      final layout = ToolbarLayout.decode(pageToolbarItems, const [
        'undo',
        'highlighter',
        '!pen',
        'gone',
        'colors',
        'pageMode',
        'highlighter',
      ]);
      expect(layout.items.take(3).map((item) => item.id), [
        'highlighter',
        'pen',
        'pencil',
      ]);
      expect(layout.shown, isNot(contains('pen')));
      expect(layout.items, hasLength(pageToolbarItems.length));
      expect(layout.shown, isNot(contains('laser')));
    });

    test('moving, hiding and encoding round-trip', () {
      // The index after the move, as ReorderableListView.onReorderItem reports it.
      final layout = ToolbarLayout.decode(pageToolbarItems, const [])
          .moved(0, 2)
          .withShown('laser', true)
          .withShown('pencil', false);
      expect(layout.items.take(3).map((item) => item.id), [
        'pencil',
        'highlighter',
        'pen',
      ]);
      final again = ToolbarLayout.decode(pageToolbarItems, layout.encode());
      expect(again.encode(), layout.encode());
      expect(again.shownIds, contains('laser'));
      expect(again.shownIds, isNot(contains('pencil')));
    });
  });

  group('page toolbar', () {
    setUp(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      setupMockPathProvider();
      setupMockPrinting();
      setupMockWindowManager();
      FlavorConfig.setup();
      await FileManager.init();
    });

    Future<void> mountEditor(
      WidgetTester tester, {
      AxisDirection alignment = AxisDirection.up,
    }) async {
      final previousAlignment = stows.workspaceToolbarAlignment.value;
      final previousLayout = stows.pageToolbarLayout.value;
      stows.workspaceToolbarAlignment.value = alignment;
      stows.pageToolbarLayout.value = const [];
      tester.view.physicalSize = const Size(1200, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        stows.workspaceToolbarAlignment.value = previousAlignment;
        stows.pageToolbarLayout.value = previousLayout;
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: Editor(
              path: '/toolbar-layout',
              onSaveSnapshot: (_, _) async {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    Offset at(WidgetTester tester, String tooltip) =>
        tester.getCenter(find.byTooltip(tooltip).first);

    testWidgets('the default order follows StarNote and hides the laser', (
      tester,
    ) async {
      await mountEditor(tester);
      await tester.tap(find.byTooltip('펜'));
      await tester.pumpAndSettle();
      final firstColor = tester.getCenter(
        find.byKey(const ValueKey('toolbar-color-0')),
      );
      final lastColor = tester.getCenter(
        find.byKey(const ValueKey('toolbar-color-4')),
      );
      expect(at(tester, '실행 취소').dx, lessThan(at(tester, '펜').dx));
      expect(at(tester, '펜').dx, lessThan(at(tester, '지우개').dx));
      expect(at(tester, '올가미').dx, lessThan(at(tester, '사진').dx));
      // The tools come before the chosen tool's values.
      expect(at(tester, '글상자').dx, lessThan(firstColor.dx));
      expect(firstColor.dx, lessThan(lastColor.dx));
      expect(find.byTooltip('레이저 포인터'), findsNothing);
      expect(
        find.descendant(of: find.byType(Toolbar), matching: find.byTooltip('내보내기')),
        findsNothing,
      );
    });

    testWidgets('a quick colour is chosen with one tap', (tester) async {
      await mountEditor(tester);
      await tester.tap(find.byTooltip('펜'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('toolbar-color-1')));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('toolbar-color-1')),
          matching: find.byIcon(Icons.check),
        ),
        findsOneWidget,
      );
    });

    Future<void> tapKey(WidgetTester tester, String key) async {
      await tester.ensureVisible(find.byKey(ValueKey(key)));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey(key)));
      await tester.pumpAndSettle();
    }

    /// StarNote's 기타 설정 panel, where the toolbar settings now live.
    Future<void> openOtherSettings(WidgetTester tester) =>
        tapKey(tester, 'note-other-settings');

    testWidgets('사용자 지정 도구 모음 shows, hides and resets tools', (
      tester,
    ) async {
      await mountEditor(tester);
      await openOtherSettings(tester);
      await tapKey(tester, 'other-settings-toolbar-custom');
      await tapKey(tester, 'toolbar-custom-eye-laser');
      // The pencil lives in the pen panel; its own button is off by default.
      await tapKey(tester, 'toolbar-custom-eye-pencil');
      await tapKey(tester, 'toolbar-custom-apply');
      expect(stows.pageToolbarLayout.value, contains('laser'));
      expect(stows.pageToolbarLayout.value, contains('pencil'));
      expect(find.byTooltip('레이저 포인터'), findsOneWidget);
      expect(find.byTooltip('연필'), findsOneWidget);

      await openOtherSettings(tester);
      await tapKey(tester, 'other-settings-toolbar-custom');
      await tapKey(tester, 'toolbar-custom-reset');
      await tapKey(tester, 'toolbar-custom-apply');
      expect(
        ToolbarLayout.decode(pageToolbarItems, stows.pageToolbarLayout.value).shownIds,
        ToolbarLayout.decode(pageToolbarItems, const []).shownIds,
      );
      expect(find.byTooltip('레이저 포인터'), findsNothing);
      expect(find.byTooltip('연필'), findsNothing);
    });

    testWidgets('a narrow toolbar stays one row, its tools and values scrolling apart', (
      tester,
    ) async {
      await mountEditor(tester);
      tester.view.physicalSize = const Size(640, 2000);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('toolbar-tools-scroll')), findsOneWidget);
      expect(find.byKey(const ValueKey('toolbar-params-scroll')), findsOneWidget);
      expect(
        (at(tester, '실행 취소').dy - at(tester, '펜').dy).abs(),
        lessThan(1),
      );
      expect(
        tester.getCenter(find.byKey(const ValueKey('toolbar-dock-handle'))).dx,
        greaterThan(0),
      );
    });

    testWidgets('the default black pen shows black as chosen', (tester) async {
      final previous = stows.lastFountainPenColor.value;
      final previousPen = Pen.currentPen;
      stows.lastFountainPenColor.value = Colors.black.toARGB32();
      Pen.currentPen = Pen.fountainPen();
      addTearDown(() {
        stows.lastFountainPenColor.value = previous;
        Pen.currentPen = previousPen;
      });
      await mountEditor(tester);
      await tester.tap(find.byTooltip('펜'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('toolbar-color-0')),
          matching: find.byIcon(Icons.check),
        ),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('toolbar-current-color')), findsNothing);
    });

    testWidgets('a colour outside the five shows on the palette button', (
      tester,
    ) async {
      final previous = stows.lastFountainPenColor.value;
      final previousPen = Pen.currentPen;
      stows.lastFountainPenColor.value = 0xff00aa55;
      Pen.currentPen = Pen.fountainPen();
      addTearDown(() {
        stows.lastFountainPenColor.value = previous;
        Pen.currentPen = previousPen;
      });
      await mountEditor(tester);
      await tester.tap(find.byTooltip('펜'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('toolbar-current-color')),
        findsOneWidget,
      );
    });

    testWidgets('the highlighter shows its own five colours', (tester) async {
      await mountEditor(tester);
      await tester.tap(find.byTooltip('형광펜'));
      await tester.pumpAndSettle();
      // Its default yellow is the first of them, so it shows as chosen.
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('toolbar-color-0')),
          matching: find.byIcon(Icons.check),
        ),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('toolbar-current-color')), findsNothing);
    });

    testWidgets('the zoom lock can be turned off from 기타 설정', (
      tester,
    ) async {
      final previous = stows.lastZoomLock.value;
      stows.lastZoomLock.value = true;
      addTearDown(() => stows.lastZoomLock.value = previous);
      await mountEditor(tester);
      await openOtherSettings(tester);
      await tapKey(tester, 'toolbar-zoom-lock');
      expect(stows.lastZoomLock.value, isFalse);
    });

    testWidgets('the writing settings Saber kept on its own page are in 기타 설정', (
      tester,
    ) async {
      final straighten = stows.autoStraightenLines.value;
      final delay = stows.shapeRecognitionDelay.value;
      addTearDown(() {
        stows.autoStraightenLines.value = straighten;
        stows.shapeRecognitionDelay.value = delay;
        ShapePen.debounceDuration = ShapePen.getDebounceFromPref();
      });
      stows.autoStraightenLines.value = true;
      await mountEditor(tester);
      await openOtherSettings(tester);
      await tester.ensureVisible(find.byKey(const ValueKey('toolbar-auto-straighten')));
      await tester.tap(find.byKey(const ValueKey('toolbar-auto-straighten')));
      await tester.pumpAndSettle();
      expect(stows.autoStraightenLines.value, isFalse);
      await tester.ensureVisible(find.byKey(const ValueKey('toolbar-shape-delay')));
      await tester.tap(find.text('끄기'));
      await tester.pumpAndSettle();
      expect(stows.shapeRecognitionDelay.value, -1);
      // The shape pen picks it up at once, not after a restart.
      expect(ShapePen.debounceDuration, const Duration(hours: 1));
      await tester.tap(find.text('0.5초'));
      await tester.pumpAndSettle();
      expect(ShapePen.debounceDuration, const Duration(milliseconds: 500));
      expect(find.text('펜이 닿으면 손가락 그리기 끄기'), findsOneWidget);
    });

    testWidgets('moving the toolbar to the side keeps the same toolbar state', (
      tester,
    ) async {
      await mountEditor(tester);
      final before = tester.state(find.byType(Toolbar));
      stows.workspaceToolbarAlignment.value = AxisDirection.left;
      final editor = tester.state<EditorState>(find.byType(Editor));
      // ignore: invalid_use_of_protected_member
      editor.setState(() {});
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(Toolbar)), same(before));
    });

    testWidgets('a side toolbar keeps the same order from top to bottom', (
      tester,
    ) async {
      await mountEditor(tester, alignment: AxisDirection.left);
      expect(at(tester, '실행 취소').dy, lessThan(at(tester, '펜').dy));
      expect(at(tester, '펜').dy, lessThan(at(tester, '글상자').dy));
      expect(
        at(tester, '글상자').dy,
        lessThan(tester.getCenter(find.byKey(const ValueKey('toolbar-pen-box'))).dy),
      );
      expect(at(tester, '펜').dx, lessThan(200));
    });
  });
}
