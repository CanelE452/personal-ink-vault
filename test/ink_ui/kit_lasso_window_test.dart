import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/ink_ui/editor_toolbar/kit_editor_toolbar.dart';
import 'package:saber/components/kit/kit_icon.dart';
import 'package:saber/components/kit/kit_text.dart';
import 'package:saber/components/kit/kit_tokens.dart';
import 'package:saber/components/kit/kit_toolbar.dart';
import 'package:saber/data/actions/app_action.dart';
import 'package:saber/data/actions/app_action_ids.dart';
import 'package:saber/data/actions/app_action_registry.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/tools/lasso_targets.dart';

/// The lasso's window (preview 10th draft 1-d, spec 「지우개·올가미 창
/// 개정」): no floating bar; the chosen lasso button has a small ⌄ and,
/// pressed again, opens 「올가미 선택」 hanging from the toolbar.
void main() {
  FlavorConfig.setup();
  late AppActionRegistry actions;
  late List<String> ran;
  late ValueNotifier<bool> floatingBar;
  late ValueNotifier<bool> noteSheet;
  final owner = Object();

  void publish({String checked = AppActionIds.toolPen}) {
    actions.publish(owner, [
      for (final id in AppActionIds.tools)
        AppAction(
          id: id,
          label: id,
          icon: KitIconName.pen,
          checked: id == checked,
          run: (_) => ran.add(id),
        ),
    ]);
  }

  void reset() {
    stows.selectRectangle.value = stows.selectRectangle.defaultValue;
    for (final target in LassoTargets.all) {
      target.value = target.defaultValue;
    }
    stows.editorToolbarTools.value = const [];
    stows.pageToolbarLayout.value = const [];
    stows.editorGestureMode.value = false;
  }

  setUp(() {
    reset();
    actions = AppActionRegistry();
    ran = [];
    floatingBar = ValueNotifier(false);
    noteSheet = ValueNotifier(false);
  });

  tearDown(() {
    reset();
    actions.dispose();
    floatingBar.dispose();
    noteSheet.dispose();
  });

  Future<void> pumpBar(
    WidgetTester tester, {
    Size screen = const Size(600, 700),
  }) async {
    tester.view.physicalSize = screen;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MediaQuery(
        data: MediaQueryData(size: screen),
        child: MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: KitEditorToolbar(
                actions: actions,
                title: '강의노트',
                floatingBarOpen: floatingBar,
                noteSheetOpen: noteSheet,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  final lasso = find.byKey(const ValueKey('editor-tool-lasso'));
  final window = find.byKey(const ValueKey('kit-lasso-panel'));
  final mark = find.descendant(
    of: lasso,
    matching: find.byType(KitDropdownMark),
  );
  KitIconName lassoIcon(WidgetTester tester) => tester
      .widget<KitIcon>(
        find.descendant(of: lasso, matching: find.byType(KitIcon)),
      )
      .name;
  Finder row(String id) => find.byKey(ValueKey('lasso-target-$id'));
  Tristate toggled(WidgetTester tester, String id) =>
      tester.getSemantics(row(id)).flagsCollection.isToggled;

  Future<void> openWindow(WidgetTester tester) async {
    await tester.tap(lasso);
    await tester.pumpAndSettle();
  }

  testWidgets('the chosen lasso has ⌄; pressed again it opens the window', (
    tester,
  ) async {
    publish();
    await pumpBar(tester);
    expect(mark, findsNothing, reason: 'not chosen: no ⌄');
    final narrow = tester.getSize(lasso).width;
    publish(checked: AppActionIds.toolLasso);
    // the registry tells its listeners after the frame
    await tester.pump();
    await tester.pump();
    expect(mark, findsOneWidget);
    // the dropdown button is 40 wide, not 34
    expect(tester.getSize(lasso).width, narrow + 6);
    // the ⌄ in the button's last 8 (`grid-template-columns:auto 8px`, the
    // auto column stretched to 32): its middle 36 in
    final button = tester.getTopLeft(lasso).dx + KitTokens.toolbarGroupGap / 2;
    expect(tester.getCenter(mark).dx - button, closeTo(36, 0.01));
    expect(lassoIcon(tester), KitIconName.lassoFree);
    expect(floatingBar.value, isFalse, reason: 'the lasso has no bar');

    await openWindow(tester);
    expect(window, findsOneWidget);
    expect(ran, isEmpty, reason: 'the lasso in hand is not picked again');
    // hanging from the toolbar: right under it, its middle under the button
    final box = tester.getRect(window);
    expect(box.width, KitTokens.penPanelWidth);
    expect(box.top, KitTokens.toolbarHeight);
    expect(
      tester.getCenter(find.byKey(const ValueKey('kit-popover-nub'))).dx,
      closeTo(tester.getCenter(lasso).dx, 0.01),
    );
    for (final text in ['올가미 선택', '올가미 유형', '자유', '사각형', '선택 대상']) {
      expect(
        find.descendant(of: window, matching: find.text(text)),
        findsOneWidget,
        reason: text,
      );
    }
    // the four targets in order, all on
    final ids = ['ink', 'highlighter', 'shape', 'images'];
    final names = ['손글씨', '형광펜', '도형', '사진'];
    for (final (i, id) in ids.indexed) {
      expect(tester.getSemantics(row(id)).label, names[i]);
      expect(toggled(tester, id), Tristate.isTrue);
      if (i > 0) {
        expect(
          tester.getTopLeft(row(id)).dy,
          tester.getBottomLeft(row(ids[i - 1])).dy,
        );
      }
    }
    expect(find.byKey(const ValueKey('lasso-target-hint')), findsNothing);
    // 도형 off: the lasso leaves shapes
    await tester.tap(row('shape'));
    await tester.pump();
    expect(stows.selectShapes.value, isFalse);
    expect(toggled(tester, 'shape'), Tristate.isFalse);
  });

  testWidgets('the type sets the rectangle lasso and the button icon', (
    tester,
  ) async {
    publish(checked: AppActionIds.toolLasso);
    await pumpBar(tester);
    await openWindow(tester);
    final free = find.byKey(const ValueKey('lasso-kind-free'));
    final rect = find.byKey(const ValueKey('lasso-kind-rect'));
    expect(
      tester.getSemantics(free).flagsCollection.isSelected,
      Tristate.isTrue,
    );
    await tester.tap(rect);
    await tester.pumpAndSettle();
    expect(stows.selectRectangle.value, isTrue);
    expect(
      tester.getSemantics(rect).flagsCollection.isSelected,
      Tristate.isTrue,
    );
    expect(lassoIcon(tester), KitIconName.lassoRect);
    await tester.tapAt(const Offset(590, 690));
    await tester.pumpAndSettle();
    expect(window, findsNothing);
    expect(lassoIcon(tester), KitIconName.lassoRect);
    // and back
    stows.selectRectangle.value = false;
    await tester.pump();
    expect(lassoIcon(tester), KitIconName.lassoFree);
  });

  testWidgets('one target stays on, and the window says so', (tester) async {
    final handle = tester.ensureSemantics();
    stows.selectInk.value = false;
    stows.selectHighlighter.value = false;
    stows.selectShapes.value = false;
    publish(checked: AppActionIds.toolLasso);
    await pumpBar(tester);
    await openWindow(tester);
    final hint = find.byKey(const ValueKey('lasso-target-hint'));
    expect(
      find.descendant(
        of: hint,
        matching: find.text(keepWords('하나는 켜 두어야 합니다.')),
      ),
      findsOneWidget,
    );
    expect(
      tester
          .widget<Text>(
            find.descendant(
              of: hint,
              matching: find.text(keepWords('하나는 켜 두어야 합니다.')),
            ),
          )
          .style
          ?.color,
      KitTokens.danger,
    );
    final images = tester.getSemantics(row('images')).getSemanticsData();
    expect(images.flagsCollection.isEnabled, Tristate.isFalse);
    expect(images.hint, '하나는 켜 두어야 합니다.');
    await tester.tap(row('images'));
    await tester.pump();
    expect(stows.selectImages.value, isTrue);
    await tester.tap(row('ink'));
    await tester.pump();
    expect(stows.selectInk.value, isTrue);
    expect(hint, findsNothing);
    handle.dispose();
  });

  testWidgets('the lasso kept in ⌄ opens its window from there', (
    tester,
  ) async {
    // the user moved the lasso off the bar (도구 막대 사용자화)
    stows.editorToolbarTools.value = const [
      '!lasso',
      'pen',
      'eraser',
      'text',
      'shapes',
      'image',
      '!laser',
    ];
    publish(checked: AppActionIds.toolLasso);
    await pumpBar(tester);
    expect(lasso, findsNothing);
    Future<void> fromMore() async {
      await tester.tap(find.byKey(const ValueKey('editor-tools-more')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('editor-more-lasso')));
      await tester.pumpAndSettle();
    }

    await fromMore();
    expect(window, findsOneWidget);
    expect(ran, isEmpty, reason: 'the lasso in hand is not picked again');
    // hanging under ⌄, its nub at ⌄'s middle
    final more = find.byKey(const ValueKey('editor-tools-more'));
    expect(tester.getRect(window).top, KitTokens.toolbarHeight);
    expect(
      tester.getCenter(find.byKey(const ValueKey('kit-popover-nub'))).dx,
      closeTo(tester.getCenter(more).dx, 0.01),
    );
    // the type and the targets change from here
    await tester.tap(find.byKey(const ValueKey('lasso-kind-rect')));
    await tester.pumpAndSettle();
    expect(stows.selectRectangle.value, isTrue);
    await tester.tap(row('shape'));
    await tester.pump();
    expect(stows.selectShapes.value, isFalse);
    await tester.tapAt(const Offset(590, 690));
    await tester.pumpAndSettle();
    expect(window, findsNothing);
    // another tool in hand: the row takes the lasso, no window
    publish();
    await tester.pump();
    await tester.pump();
    await fromMore();
    expect(window, findsNothing);
    expect(ran, [AppActionIds.toolLasso]);
  });

  testWidgets('a phone: the window stays on screen and scrolls inside', (
    tester,
  ) async {
    publish(checked: AppActionIds.toolLasso);
    await pumpBar(tester, screen: const Size(360, 360));
    await openWindow(tester);
    expect(tester.takeException(), isNull);
    final view = find
        .ancestor(of: window, matching: find.byType(SingleChildScrollView))
        .first;
    final box = tester.getRect(view);
    expect(box.left, greaterThanOrEqualTo(8));
    expect(box.right, lessThanOrEqualTo(360 - 8));
    expect(box.top, KitTokens.toolbarHeight);
    expect(box.bottom, lessThanOrEqualTo(360 - 8));
    final scroll = tester.state<ScrollableState>(
      find.descendant(of: view, matching: find.byType(Scrollable)).first,
    );
    expect(scroll.position.maxScrollExtent, greaterThan(0));
  });
}
