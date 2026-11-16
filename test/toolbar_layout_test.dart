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
    test('an empty layout is the StarNote order with laser and export hidden', () {
      final layout = ToolbarLayout.decode(pageToolbarItems, const []);
      expect(
        layout.items.map((item) => item.id),
        pageToolbarItems.map((item) => item.id),
      );
      expect(layout.shownIds.first, 'undo');
      expect(layout.shownIds, isNot(contains('laser')));
      expect(layout.shownIds, isNot(contains('export')));
      expect(layout.labelOf('select'), '올가미');
    });

    test('a stored layout keeps its order and adds unknown items after it', () {
      final layout = ToolbarLayout.decode(pageToolbarItems, [
        'redo',
        '!undo',
        'pen',
        'gone',
        'pen',
      ]);
      expect(layout.items.take(4).map((item) => item.id), [
        'redo',
        'undo',
        'pen',
        'pencil',
      ]);
      expect(layout.shown, isNot(contains('undo')));
      expect(layout.items, hasLength(pageToolbarItems.length));
      expect(layout.shown, isNot(contains('laser')));
    });

    test('moving, hiding and encoding round-trip', () {
      final layout = ToolbarLayout.decode(pageToolbarItems, const [])
          .moved(0, 3)
          .withShown('laser', true)
          .withShown('pencil', false);
      expect(layout.items.take(3).map((item) => item.id), [
        'redo',
        'pen',
        'undo',
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

    testWidgets('the default order follows StarNote and hides laser and export', (
      tester,
    ) async {
      await mountEditor(tester);
      final firstColor = tester.getCenter(
        find.byKey(const ValueKey('toolbar-color-0')),
      );
      final lastColor = tester.getCenter(
        find.byKey(const ValueKey('toolbar-color-4')),
      );
      expect(at(tester, '실행 취소').dx, lessThan(at(tester, '펜').dx));
      expect(at(tester, '펜').dx, lessThan(at(tester, '지우개').dx));
      expect(at(tester, '올가미').dx, lessThan(at(tester, '사진').dx));
      expect(at(tester, '글상자').dx, lessThan(firstColor.dx));
      expect(lastColor.dx, lessThan(at(tester, '전체 화면').dx));
      expect(at(tester, '전체 화면').dx, lessThan(at(tester, '툴바 설정').dx));
      expect(find.byTooltip('레이저 포인터'), findsNothing);
      expect(find.byTooltip('내보내기'), findsNothing);
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

    testWidgets('the toolbar editor shows, hides and resets items', (
      tester,
    ) async {
      await mountEditor(tester);
      await tester.tap(find.byTooltip('툴바 설정'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('toolbar-edit')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('toolbar-item-laser')));
      await tester.pumpAndSettle();
      // The pencil lives in the pen panel; its own button is off by default.
      await tester.tap(find.byKey(const ValueKey('toolbar-item-pencil')));
      await tester.pumpAndSettle();
      expect(stows.pageToolbarLayout.value, contains('laser'));
      expect(stows.pageToolbarLayout.value, contains('pencil'));
      expect(find.byTooltip('레이저 포인터'), findsOneWidget);
      expect(find.byTooltip('연필'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('toolbar-edit-reset')));
      await tester.pumpAndSettle();
      expect(stows.pageToolbarLayout.value, isEmpty);
      expect(find.byTooltip('레이저 포인터'), findsNothing);
      expect(find.byTooltip('연필'), findsNothing);
    });

    testWidgets('a narrow toolbar stays one row with its ends pinned', (
      tester,
    ) async {
      await mountEditor(tester);
      tester.view.physicalSize = const Size(640, 2000);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('toolbar-scroll')), findsOneWidget);
      expect(
        (at(tester, '실행 취소').dy - at(tester, '전체 화면').dy).abs(),
        lessThan(1),
      );
      expect(at(tester, '툴바 설정').dx, lessThan(640));
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

    testWidgets('the zoom lock can be turned off from the toolbar settings', (
      tester,
    ) async {
      final previous = stows.lastZoomLock.value;
      stows.lastZoomLock.value = true;
      addTearDown(() => stows.lastZoomLock.value = previous);
      await mountEditor(tester);
      await tester.tap(find.byTooltip('툴바 설정'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('toolbar-zoom-lock')));
      await tester.pumpAndSettle();
      expect(stows.lastZoomLock.value, isFalse);
    });

    testWidgets('the writing settings Saber kept on its own page are in the toolbar settings', (
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
      await tester.tap(find.byTooltip('툴바 설정'));
      await tester.pumpAndSettle();
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
      expect(at(tester, '글상자').dy, lessThan(at(tester, '전체 화면').dy));
      expect(at(tester, '펜').dx, lessThan(200));
    });
  });
}
