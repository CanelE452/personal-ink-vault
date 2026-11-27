import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/ink_ui/editor_toolbar/kit_editor_toolbar.dart';
import 'package:saber/components/kit/kit_icon.dart';
import 'package:saber/components/kit/kit_menu.dart';
import 'package:saber/data/actions/app_action.dart';
import 'package:saber/data/actions/app_action_ids.dart';
import 'package:saber/data/actions/app_action_registry.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/prefs.dart';

import '../utils/kit_menu_finders.dart';

/// The editor toolbar of the 9th draft c: 쪽 목록 · 노트 창 | 필기/제스처 ·
/// tools (1 to 6) · ⌄ | 노트 추가 · 전체 화면 · ⋯.
void main() {
  FlavorConfig.setup();
  late AppActionRegistry actions;
  late List<String> ran;
  late ValueNotifier<bool> floatingBar;
  late ValueNotifier<bool> noteSheet;
  final owner = Object();

  /// Publishes the editor's actions; [checked] is the tool action in hand.
  void publish({
    String checked = AppActionIds.toolPen,
    Set<String> without = const {},
    bool singlePage = false,
  }) {
    AppAction action(
      String id,
      KitIconName icon, {
      bool? on,
      bool enabled = true,
    }) => AppAction(
      id: id,
      label: id,
      icon: icon,
      checked: on,
      enabled: enabled,
      run: (_) => ran.add(id),
    );
    actions.publish(owner, [
      for (final a in [
        action(AppActionIds.pageList, KitIconName.sidebar),
        for (final id in AppActionIds.tools)
          action(id, KitIconName.pen, on: id == checked),
        action(AppActionIds.pickPhoto, KitIconName.image),
        action(AppActionIds.insertPageMenu, KitIconName.pageAdd),
        action(AppActionIds.fullscreen, KitIconName.expand, on: false),
        action(AppActionIds.toolbarCustomize, KitIconName.tune),
        action(AppActionIds.docInfo, KitIconName.info),
        action(AppActionIds.rename, KitIconName.rename),
        action(AppActionIds.pageMode, KitIconName.scrollDir, on: singlePage),
      ])
        if (!without.contains(a.id)) a,
    ]);
  }

  setUp(() {
    actions = AppActionRegistry();
    ran = [];
    floatingBar = ValueNotifier(true);
    noteSheet = ValueNotifier(false);
    stows.editorToolbarTools.value = const [];
    stows.pageToolbarLayout.value = const [];
    stows.editorGestureMode.value = false;
  });

  tearDown(() {
    actions.dispose();
    floatingBar.dispose();
    noteSheet.dispose();
  });

  Future<void> pumpBar(WidgetTester tester, {double width = 600}) async {
    tester.view.physicalSize = Size(width, 500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MediaQuery(
        data: MediaQueryData(size: Size(width, 500)),
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

  Finder tool(String id) => find.byKey(ValueKey('editor-tool-$id'));

  bool selected(WidgetTester tester, Finder f) => tester
      .getSemantics(f)
      .flagsCollection
      .isSelected
      .toBoolOrNull() ??
      false;

  testWidgets('order and hidden tools', (tester) async {
    publish();
    await pumpBar(tester);
    final xs = [
      for (final id in ['lasso', 'pen', 'eraser', 'text', 'shapes', 'image'])
        tester.getCenter(tool(id)).dx,
    ];
    for (var i = 1; i < xs.length; i++) {
      expect(xs[i] - xs[i - 1], 37, reason: 'button 34 + gap 3');
    }
    expect(tool('laser'), findsNothing, reason: 'the laser pen waits in ⌄');
    for (final hidden in ['이모지', '녹음', '녹음 보기', '자', '액세서리', '내보내기']) {
      expect(find.byTooltip(hidden), findsNothing, reason: hidden);
    }
    // start, middle, end
    final names = [
      '쪽 목록',
      '노트 창',
      '필기 모드',
      '올가미',
      '펜',
      '지우개',
      '텍스트',
      '모양',
      '사진',
      '도구 더 보기',
      '노트 추가',
      '전체 화면',
      '문서 메뉴',
    ];
    final centres = [
      for (final name in names) tester.getCenter(find.byTooltip(name)).dx,
    ];
    expect(centres, orderedEquals([...centres]..sort()));
    // the tool in hand is the checked one
    expect(selected(tester, tool('pen')), isTrue);
    expect(selected(tester, tool('lasso')), isFalse);
    // the bar: 46 high, one row
    expect(tester.getSize(find.byType(KitEditorToolbar)).height, 46);
  });

  testWidgets('the pen button stands for every ink kind', (tester) async {
    publish(checked: AppActionIds.toolHighlighter);
    await pumpBar(tester);
    expect(selected(tester, tool('pen')), isTrue);
  });

  testWidgets('tool buttons run their actions', (tester) async {
    publish(checked: AppActionIds.toolLasso, without: {AppActionIds.toolShapes});
    await pumpBar(tester);
    expect(tool('shapes'), findsNothing, reason: 'no action, no button');
    await tester.tap(tool('pen'));
    await tester.tap(tool('image'));
    await tester.tap(find.byKey(const ValueKey('editor-page-list')));
    await tester.tap(find.byKey(const ValueKey('editor-insert-page')));
    await tester.tap(find.byKey(const ValueKey('editor-fullscreen')));
    expect(ran, [
      AppActionIds.toolPen,
      AppActionIds.pickPhoto,
      AppActionIds.pageList,
      AppActionIds.insertPageMenu,
      AppActionIds.fullscreen,
    ]);
  });

  testWidgets('pen and eraser show the floating bar; again hides it', (
    tester,
  ) async {
    publish();
    await pumpBar(tester);
    // the pen in hand: the button only shows or hides the bar
    await tester.tap(tool('pen'));
    expect(floatingBar.value, isFalse);
    await tester.tap(tool('pen'));
    expect(floatingBar.value, isTrue);
    expect(ran, isEmpty);

    await tester.tap(tool('lasso'));
    expect(ran, [AppActionIds.toolLasso]);
    expect(floatingBar.value, isFalse, reason: 'another tool hides it');

    publish(checked: AppActionIds.toolLasso);
    await tester.pump();
    await tester.tap(tool('eraser'));
    expect(ran.last, AppActionIds.toolEraser);
    expect(floatingBar.value, isTrue);
    publish(checked: AppActionIds.toolEraser);
    await tester.pump();
    await tester.tap(tool('eraser'));
    expect(floatingBar.value, isFalse);
    expect(ran.last, AppActionIds.toolEraser, reason: 'eraser kept in hand');
    expect(ran.where((id) => id == AppActionIds.toolEraser), hasLength(1));
  });

  // Final review B-1: a press that takes no other tool up (사진, whose
  // picker may be cancelled; the text box pressed off) leaves the bar.
  testWidgets('사진 and the text box off leave the floating bar as it is', (
    tester,
  ) async {
    publish();
    await pumpBar(tester);
    for (final open in [true, false]) {
      floatingBar.value = open;
      await tester.tap(tool('image'));
      expect(ran.last, AppActionIds.pickPhoto);
      expect(floatingBar.value, open, reason: '사진, bar open: $open');
    }

    publish(checked: AppActionIds.toolText);
    await tester.pump();
    for (final open in [true, false]) {
      floatingBar.value = open;
      await tester.tap(tool('text'));
      expect(ran.last, AppActionIds.toolText);
      expect(floatingBar.value, open, reason: 'text box off, bar open: $open');
    }
  });

  testWidgets('gesture mode: no tool chosen, a tool button writes again', (
    tester,
  ) async {
    publish();
    await pumpBar(tester);
    await tester.tap(find.byKey(const ValueKey('editor-mode')));
    await tester.pump();
    expect(stows.editorGestureMode.value, isTrue);
    expect(find.byTooltip('제스처 모드'), findsOneWidget);
    expect(selected(tester, tool('pen')), isFalse);

    floatingBar.value = false;
    await tester.tap(tool('pen'));
    await tester.pump();
    expect(stows.editorGestureMode.value, isFalse);
    expect(find.byTooltip('필기 모드'), findsOneWidget);
    expect(floatingBar.value, isTrue, reason: 'the pen bar comes back');

    // a tool that is not in hand is taken up as well
    await tester.tap(find.byKey(const ValueKey('editor-mode')));
    await tester.pump();
    await tester.tap(tool('text'));
    await tester.pump();
    expect(stows.editorGestureMode.value, isFalse);
    expect(ran, [AppActionIds.toolText]);
  });

  testWidgets('the more window lists the tools off the bar', (tester) async {
    publish();
    await pumpBar(tester);
    await tester.tap(find.byKey(const ValueKey('editor-tools-more')));
    await tester.pumpAndSettle();
    expect(find.text('막대에 없는 도구'), findsOneWidget);
    expect(find.text('레이저 펜'), findsOneWidget);
    expect(find.text('펜'), findsNothing, reason: 'tools on the bar stay out');
    expect(find.text('이모지'), findsNothing);
    expect(find.text('도구 막대 사용자화'), findsOneWidget);

    await tester.tap(find.text('레이저 펜'));
    await tester.pumpAndSettle();
    expect(ran, [AppActionIds.toolLaser]);
    expect(find.text('도구 막대 사용자화'), findsNothing, reason: 'closed');

    await tester.tap(find.byKey(const ValueKey('editor-tools-more')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('도구 막대 사용자화'));
    await tester.pumpAndSettle();
    expect(ran.last, AppActionIds.toolbarCustomize);
  });

  testWidgets('a customized bar shows its own tools', (tester) async {
    publish();
    stows.editorToolbarTools.value = const ['laser', '!lasso'];
    await pumpBar(tester);
    expect(tool('lasso'), findsNothing);
    expect(
      tester.getCenter(tool('laser')).dx,
      lessThan(tester.getCenter(tool('pen')).dx),
    );
  });

  testWidgets('⋯ holds 문서 정보, 이름 바꾸기 and 쪽 배치', (tester) async {
    publish();
    await pumpBar(tester);
    await tester.tap(find.byKey(const ValueKey('editor-doc-menu')));
    await tester.pumpAndSettle();
    expect(find.text('강의노트'), findsOneWidget, reason: 'the name on top');
    for (final row in ['문서 정보', '이름 바꾸기', '쪽 배치']) {
      expect(find.text(row), findsOneWidget, reason: row);
    }
    expect(find.text('세로'), findsOneWidget, reason: 'the layout now');

    await tester.tap(find.text('쪽 배치'));
    await tester.pumpAndSettle();
    expect(findMenuText('세로로 이어 보기'), findsOneWidget);
    expect(findMenuText('가로로 넘기기'), findsOneWidget);
    // the layout in use: tapping it changes nothing
    await tester.tap(findMenuText('세로로 이어 보기'));
    await tester.pumpAndSettle();
    expect(ran, isEmpty);
    expect(find.text('쪽 배치'), findsNothing, reason: 'both windows closed');

    await tester.tap(find.byKey(const ValueKey('editor-doc-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('쪽 배치'));
    await tester.pumpAndSettle();
    await tester.tap(findMenuText('가로로 넘기기'));
    await tester.pumpAndSettle();
    expect(ran, [AppActionIds.pageMode]);

    await tester.tap(find.byKey(const ValueKey('editor-doc-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('문서 정보'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('editor-doc-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('이름 바꾸기'));
    await tester.pumpAndSettle();
    expect(ran, [
      AppActionIds.pageMode,
      AppActionIds.docInfo,
      AppActionIds.rename,
    ]);
  });

  testWidgets('⋯ leaves out the rows nobody offers', (tester) async {
    publish(without: {AppActionIds.rename, AppActionIds.docInfo});
    await pumpBar(tester);
    await tester.tap(find.byKey(const ValueKey('editor-doc-menu')));
    await tester.pumpAndSettle();
    expect(find.text('이름 바꾸기'), findsNothing);
    expect(find.text('문서 정보'), findsNothing);
    expect(find.text('쪽 배치'), findsOneWidget);
  });

  testWidgets('a window taller than the screen scrolls inside', (
    tester,
  ) async {
    publish();
    tester.view.physicalSize = const Size(360, 150);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
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
    );
    await tester.tap(find.byKey(const ValueKey('editor-doc-menu')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    // the ⋯ window slides inside its room under the bar (Task 14): the
    // window's own view around the menu's
    final menu = find
        .ancestor(
          of: find.text('문서 정보'),
          matching: find.byType(SingleChildScrollView),
        )
        .last;
    expect(tester.getRect(menu).bottom, lessThanOrEqualTo(150));
    await tester.drag(find.text('문서 정보'), const Offset(0, -80));
    await tester.pumpAndSettle();
    expect(find.text('쪽 배치').hitTestable(), findsOneWidget);
  });

  testWidgets('with every tool on the bar ⌄ has no tool title', (
    tester,
  ) async {
    publish(without: {AppActionIds.toolLaser});
    await pumpBar(tester);
    await tester.tap(find.byKey(const ValueKey('editor-tools-more')));
    await tester.pumpAndSettle();
    expect(find.text('막대에 없는 도구'), findsNothing);
    expect(find.text('도구 막대 사용자화'), findsOneWidget);
  });

  testWidgets('the thin line keeps 7 on each side (values §14-3)', (
    tester,
  ) async {
    publish();
    await pumpBar(tester, width: 586);
    final mode = tester.getRect(
      find.descendant(
        of: find.byKey(const ValueKey('editor-mode')),
        matching: find.byType(InkWell),
      ),
    );
    final lasso = tester.getRect(
      find.descendant(of: tool('lasso'), matching: find.byType(InkWell)),
    );
    final line = tester.getRect(find.byKey(const ValueKey('editor-mode-line')));
    expect(line.size, const Size(1, 22));
    expect(line.left - mode.right, 7);
    expect(lasso.left - line.right, 7);
    // the bar's middle starts at 122 on a 586 bar (values §14-3)
    expect(mode.left - tester.getRect(find.byType(KitEditorToolbar)).left, 122);
  });

  testWidgets('the windows have the 9th draft c rows and heads', (
    tester,
  ) async {
    publish();
    await pumpBar(tester, width: 586);
    Rect panelOf(String text) => tester.getRect(
      find
          .ancestor(of: find.text(text), matching: find.byType(KitMenu))
          .first,
    );
    // ⌄: tools group (pad 3, title 10 + 12.5 × 1.35 + 3, row 44, pad 3), the line
    await tester.tap(find.byKey(const ValueKey('editor-tools-more')));
    await tester.pumpAndSettle();
    final more = panelOf('도구 막대 사용자화');
    final custom = tester.getRect(find.byKey(const ValueKey('editor-toolbar-customize')));
    // the engine rounds each line to whole pixels: 16.875 → 17, 16.9 → 17
    expect(custom.top - more.top, 3 + 10 + 17 + 3 + 44 + 3 + 1 + 3);
    await tester.tapAt(const Offset(5, 400));
    await tester.pumpAndSettle();

    // ⋯: head 12 + 13 × 1.3 + 6, then rows of 44; 「문서 정보 ›」
    await tester.tap(find.byKey(const ValueKey('editor-doc-menu')));
    await tester.pumpAndSettle();
    final doc = panelOf('문서 정보');
    final info = tester.getRect(find.byKey(const ValueKey('editor-doc-info')));
    // a line (1) under the head: the first group follows the title, so it
    // is not `.grp:first-child` and keeps its border
    expect(info.top - doc.top, 12 + 17 + 6 + 1 + 3);
    expect(info.height, 44);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('editor-doc-info')),
        matching: find.byWidgetPredicate(
          (w) => w is KitIcon && w.name == KitIconName.chevR,
        ),
      ),
      findsOneWidget,
    );

    // 쪽 배치: 206 × 94, rows 44, 112 under the ⋯ window's top, its row
    // not marked open (preview `openDoc`)
    await tester.tap(find.text('쪽 배치'));
    await tester.pumpAndSettle();
    final sub = panelOf('가로로 넘기기');
    expect(sub.size, const Size(206, 94));
    expect(sub.top - doc.top, moreOrLessEquals(112, epsilon: .01));
    expect(
      tester.getRect(find.byKey(const ValueKey('editor-doc-layout-true'))).height,
      44,
    );
    final layoutRow = find.descendant(
      of: find.byKey(const ValueKey('editor-doc-layout')),
      matching: find.byType(Material),
    );
    expect(
      tester.widgetList<Material>(layoutRow).map((m) => m.color),
      everyElement(Colors.transparent),
    );
  });

  testWidgets('the note window button opens and closes the note window', (
    tester,
  ) async {
    publish();
    await pumpBar(tester);
    await tester.tap(find.byKey(const ValueKey('editor-note-sheet')));
    expect(noteSheet.value, isTrue);
    await tester.tap(find.byKey(const ValueKey('editor-note-sheet')));
    expect(noteSheet.value, isFalse);
  });

  testWidgets('at phone width the toolbar does not overflow', (tester) async {
    publish();
    await pumpBar(tester, width: 360);
    expect(tester.takeException(), isNull);
    expect(
      tester.getRect(find.byKey(const ValueKey('editor-doc-menu'))).right,
      lessThanOrEqualTo(360),
    );
    expect(
      tester.getRect(find.byKey(const ValueKey('editor-page-list'))).left,
      greaterThanOrEqualTo(0),
    );
    // no button is hidden for want of room (user 2026-11-25): the ends
    // are whole on screen, the middle is all there and slides
    for (final key in const [
      'editor-page-list',
      'editor-note-sheet',
      'editor-insert-page',
      'editor-fullscreen',
      'editor-doc-menu',
    ]) {
      final rect = tester.getRect(find.byKey(ValueKey(key)));
      expect(rect.left >= 0 && rect.right <= 360, isTrue, reason: key);
    }
    for (final key in const [
      'editor-mode',
      'editor-tool-lasso',
      'editor-tool-pen',
      'editor-tool-eraser',
      'editor-tool-text',
      'editor-tool-shapes',
      'editor-tool-image',
      'editor-tools-more',
    ]) {
      expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
    }
    // the middle slides sideways; the ends stay
    final before = tester.getCenter(tool('image')).dx;
    final menu = tester.getCenter(find.byKey(const ValueKey('editor-doc-menu')));
    await tester.drag(tool('eraser'), const Offset(-120, 0));
    await tester.pumpAndSettle();
    expect(tester.getCenter(tool('image')).dx, lessThan(before));
    expect(
      tester.getCenter(find.byKey(const ValueKey('editor-doc-menu'))),
      menu,
    );
  });
}
