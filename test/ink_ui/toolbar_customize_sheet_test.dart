import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/ink_ui/editor_toolbar/toolbar_customize_sheet.dart';
import 'package:saber/components/kit/kit_text.dart';
import 'package:saber/components/kit/kit_tokens.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/prefs.dart';

/// 「도구 막대 사용자화」 (9th draft c): one tools tab, 1 to 6 on the bar,
/// switches save at once, drag to order, 「기본값으로」 and 「닫기」.
void main() {
  FlavorConfig.setup();
  late int closed;

  setUp(() {
    closed = 0;
    stows.editorToolbarTools.value = const [];
    stows.pageToolbarLayout.value = const [];
  });

  Future<void> pumpSheet(WidgetTester tester) async {
    tester.view.physicalSize = const Size(600, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(size: Size(600, 800)),
        child: MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                Positioned.fill(
                  child: ToolbarCustomizeSheet(onClose: () => closed++),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Finder switchOf(String name) =>
      find.bySemanticsLabel('$name 막대에 보이기');

  const tooMany = '막대에는 6개까지 둘 수 있습니다. 다른 도구를 먼저 끄세요.';
  const tooFew = '도구는 하나 이상 있어야 합니다. 다른 도구를 먼저 켜세요.';

  testWidgets('the rows, the count and the default switches', (tester) async {
    await pumpSheet(tester);
    // values §14-5: 340 × 477.1, 44 under the page's top
    final panel = tester.getRect(
      find.bySemanticsLabel('도구 막대 사용자화').first,
    );
    expect(panel.width, 340);
    expect(panel.top, 44);
    // lines rounded to whole pixels by the engine (16.875 → 17, 16.2 → 16);
    // the test font wraps the description, the app's keeps it on one line
    final caption = tester.getSize(
      find.text('1개 이상 6개 이하입니다. 나머지는 더 보기 안에 있습니다.'),
    );
    expect(caption.height % 16, 0);
    expect(
      panel.height - (caption.height - 16),
      moreOrLessEquals(477.1, epsilon: .5),
    );
    expect(find.text('도구 막대 사용자화'), findsOneWidget);
    expect(find.text('막대에 둘 도구'), findsOneWidget);
    expect(find.text('6 / 6'), findsOneWidget);
    expect(find.text('1개 이상 6개 이하입니다. 나머지는 더 보기 안에 있습니다.'), findsOneWidget);
    final names = ['올가미', '펜', '지우개', '텍스트', '모양', '사진', '레이저 펜'];
    final ys = [
      for (final name in names) tester.getCenter(find.text(name)).dy,
    ];
    expect(ys, orderedEquals([...ys]..sort()));
    expect(find.text('이모지'), findsNothing);
    expect(find.text('액세서리'), findsNothing, reason: 'no accessory tab');
    expect(find.byType(Switch), findsNothing, reason: 'kit switches only');
  });

  testWidgets('a seventh tool is refused with a red line', (tester) async {
    await pumpSheet(tester);
    await tester.tap(switchOf('레이저 펜'));
    await tester.pump();
    expect(find.text(tooMany), findsOneWidget);
    // its line keeps 12 x 1.4 whatever fonts draw it (values §14-5: 507.9)
    expect(
      find.ancestor(of: find.text(tooMany), matching: find.byType(KitText)),
      findsOneWidget,
    );
    expect(stows.editorToolbarTools.value, isEmpty, reason: 'nothing saved');
    final count = tester.widget<Text>(find.text('6 / 6'));
    expect(count.style?.color, KitTokens.danger, reason: 'red when refused');
    expect(count.style?.fontWeight, FontWeight.w600);

    // switching one off clears the line and saves at once
    await tester.tap(switchOf('펜'));
    await tester.pump();
    expect(find.text(tooMany), findsNothing);
    expect(
      tester.widget<Text>(find.text('5 / 6')).style?.color,
      isNot(KitTokens.danger),
    );
    expect(stows.editorToolbarTools.value, [
      'lasso',
      '!pen',
      'eraser',
      'text',
      'shapes',
      'image',
      '!laser',
    ]);
  });

  testWidgets('the last tool cannot go', (tester) async {
    stows.editorToolbarTools.value = const [
      '!lasso',
      'pen',
      '!eraser',
      '!text',
      '!shapes',
      '!image',
      '!laser',
    ];
    await pumpSheet(tester);
    expect(find.text('1 / 6'), findsOneWidget);
    await tester.tap(switchOf('펜'));
    await tester.pump();
    expect(find.text(tooFew), findsOneWidget);
    expect(stows.editorToolbarTools.value[1], 'pen');
  });

  testWidgets('「기본값으로」 writes the whole default list', (tester) async {
    stows.editorToolbarTools.value = const ['laser', '!lasso'];
    await pumpSheet(tester);
    await tester.tap(find.text('기본값으로'));
    await tester.pump();
    expect(stows.editorToolbarTools.value, [
      'lasso',
      'pen',
      'eraser',
      'text',
      'shapes',
      'image',
      '!laser',
    ]);
    expect(closed, 0, reason: 'the window stays open');
  });

  testWidgets('the 229 layout is shown until the bar is customized', (
    tester,
  ) async {
    stows.pageToolbarLayout.value = const ['!select', 'photo'];
    await pumpSheet(tester);
    expect(find.text('5 / 6'), findsOneWidget);
    expect(
      tester.getCenter(find.text('사진')).dy,
      lessThan(tester.getCenter(find.text('펜')).dy),
    );
  });

  testWidgets('dragging a handle orders the tools', (tester) async {
    await pumpSheet(tester);
    final handle = find.byKey(const ValueKey('toolbar-customize-drag-laser'));
    final to = tester.getCenter(find.text('올가미')).dy;
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await tester.pump(const Duration(milliseconds: 50));
    final distance = to - tester.getCenter(handle).dy - 20;
    for (var i = 0; i < 10; i++) {
      await gesture.moveBy(Offset(0, distance / 10));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await gesture.up();
    await tester.pumpAndSettle();
    expect(stows.editorToolbarTools.value.first, '!laser');
  });

  testWidgets('닫기, the cross and the dim area close it', (tester) async {
    await pumpSheet(tester);
    await tester.tap(find.text('닫기'));
    await tester.tap(find.byKey(const ValueKey('toolbar-customize-close')));
    await tester.tapAt(const Offset(5, 790));
    expect(closed, 3);
  });

  testWidgets('on a short screen the list scrolls inside the window', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              Positioned.fill(
                child: ToolbarCustomizeSheet(onClose: () => closed++),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('닫기').hitTestable(), findsOneWidget, reason: 'foot stays');
    expect(find.text('레이저 펜').hitTestable(), findsNothing);
    await tester.drag(find.text('지우개'), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(find.text('레이저 펜').hitTestable(), findsOneWidget);
  });
}
