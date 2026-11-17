import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/toolbar/toolbar.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/tools/eraser.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/editor/editor.dart';

import 'utils/test_mock_channel_handlers.dart';

/// StarNote's tool bar (view_tool_bar_container): undo and redo, the tools,
/// then the chosen tool's values, each part scrolling on its own.
void main() {
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
    Size size = const Size(1200, 2000),
  }) async {
    final previousAlignment = stows.workspaceToolbarAlignment.value;
    final previousLayout = stows.pageToolbarLayout.value;
    final previousEraserSize = stows.eraserSize.value;
    final previousEraserMode = stows.eraserMode.value;
    final previousRectangle = stows.selectRectangle.value;
    stows.workspaceToolbarAlignment.value = alignment;
    stows.pageToolbarLayout.value = const [];
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      stows.workspaceToolbarAlignment.value = previousAlignment;
      stows.pageToolbarLayout.value = previousLayout;
      stows.eraserSize.value = previousEraserSize;
      stows.eraserMode.value = previousEraserMode;
      stows.selectRectangle.value = previousRectangle;
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Editor(
            path: '/toolbar-sections',
            onSaveSnapshot: (_, _) async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder inPart(String part, Finder matching) =>
      find.descendant(of: find.byKey(ValueKey(part)), matching: matching);

  testWidgets("undo, tools and the tool's values sit in three sections", (
    tester,
  ) async {
    await mountEditor(tester);
    await tester.tap(find.byTooltip('펜'));
    await tester.pumpAndSettle();
    expect(inPart('toolbar-undo-redo', find.byTooltip('실행 취소')), findsOneWidget);
    expect(inPart('toolbar-undo-redo', find.byTooltip('다시 실행')), findsOneWidget);
    expect(inPart('toolbar-tools-scroll', find.byTooltip('펜')), findsOneWidget);
    expect(inPart('toolbar-tools-scroll', find.byTooltip('지우개')), findsOneWidget);
    expect(
      inPart('toolbar-params-scroll', find.byKey(const ValueKey('toolbar-colors'))),
      findsOneWidget,
    );
    expect(
      inPart(
        'toolbar-params-scroll',
        find.byKey(const ValueKey('toolbar-quick-ink-widths')),
      ),
      findsOneWidget,
    );
    expect(
      inPart('toolbar-params-scroll', find.byKey(const ValueKey('toolbar-pen-box'))),
      findsOneWidget,
    );
  });

  testWidgets('the eraser shows its modes and three sizes', (tester) async {
    await mountEditor(tester);
    await tester.tap(find.byTooltip('지우개'));
    await tester.pumpAndSettle();
    for (final key in const [
      'toolbar-eraser-stroke',
      'toolbar-eraser-lasso',
      'toolbar-eraser-size-15',
      'toolbar-eraser-size-30',
      'toolbar-eraser-size-50',
    ]) {
      expect(inPart('toolbar-params-scroll', find.byKey(ValueKey(key))), findsOneWidget);
    }
    expect(find.byKey(const ValueKey('toolbar-colors')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('toolbar-eraser-size-30')));
    await tester.pumpAndSettle();
    expect(stows.eraserSize.value, 30);
    await tester.tap(find.byKey(const ValueKey('toolbar-eraser-lasso')));
    await tester.pumpAndSettle();
    expect(stows.eraserMode.value, EraserMode.lasso);
  });

  testWidgets('the lasso shows free and rectangle', (tester) async {
    await mountEditor(tester);
    stows.selectRectangle.value = false;
    await tester.tap(find.byTooltip('올가미'));
    await tester.pumpAndSettle();
    expect(
      inPart('toolbar-params-scroll', find.byKey(const ValueKey('toolbar-select-free'))),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('toolbar-select-rect')));
    await tester.pumpAndSettle();
    expect(stows.selectRectangle.value, isTrue);
  });

  testWidgets('docked left, the sections stand vertically without overflow', (
    tester,
  ) async {
    await mountEditor(
      tester,
      alignment: AxisDirection.left,
      size: const Size(400, 800),
    );
    expect(tester.takeException(), isNull);
    expect(
      tester
          .widget<SingleChildScrollView>(
            find.byKey(const ValueKey('toolbar-params-scroll')),
          )
          .scrollDirection,
      Axis.vertical,
    );
    expect(
      tester
          .widget<SingleChildScrollView>(
            find.byKey(const ValueKey('toolbar-tools-scroll')),
          )
          .scrollDirection,
      Axis.vertical,
    );
  });

  testWidgets('page actions, finger, fullscreen and export are not toolbar items', (
    tester,
  ) async {
    await mountEditor(tester);
    for (final tooltip in const ['쪽 추가', '페이지 추가', '손가락 필기', '전체 화면', '내보내기']) {
      expect(
        find.descendant(of: find.byType(Toolbar), matching: find.byTooltip(tooltip)),
        findsNothing,
        reason: tooltip,
      );
    }
  });
}
