import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/ink_ui/doc_menu/kit_doc_menu.dart';
import 'package:saber/components/ink_ui/editor_toolbar/kit_editor_toolbar.dart';
import 'package:saber/components/ink_ui/kit_zoom_badge.dart';
import 'package:saber/components/kit/kit_controls.dart';
import 'package:saber/components/kit/kit_icon.dart';
import 'package:saber/components/kit/kit_menu.dart';
import 'package:saber/components/kit/kit_tokens.dart';
import 'package:saber/data/actions/app_action.dart';
import 'package:saber/data/actions/app_action_ids.dart';
import 'package:saber/data/actions/app_action_registry.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/pages/settings/app_settings_page.dart';

import '../utils/kit_menu_finders.dart';

/// The editor's ⋯ document menu (Task 14, user 2026-11-25 「⋯ 아래에 묶어
/// 둠」): the 9th draft c rows on top (문서 정보 · 이름 바꾸기 · 쪽 배치),
/// then the design table's groups in its order: the quick buttons (검색 ·
/// 읽기 전용), 보기, 쪽 N, 지우기, 정렬·설정, 더 보기.
void main() {
  FlavorConfig.setup();
  late AppActionRegistry actions;
  late List<String> ran;
  late ValueNotifier<bool> floatingBar;
  late ValueNotifier<bool> noteSheet;
  final owner = Object();

  /// The labels of [AppActionIds.more229] as the actions name them.
  const moreLabels = {
    AppActionIds.export: '파일 내보내기',
    AppActionIds.pdfRemake: '새 엔진으로 PDF 다시 만들기',
    AppActionIds.quickSwitch: '빠른 문서 전환',
    AppActionIds.bookmarks: '북마크',
    AppActionIds.knowledge: '문서 연결 · 태그 · 그래프',
    AppActionIds.mcp: '다른 AI 연결 · MCP',
    AppActionIds.copyPageLink: '현재 페이지 링크 복사',
    AppActionIds.openNoteLink: '노트 링크 열기',
    AppActionIds.vaultExport: 'Obsidian 보관함 ZIP',
    AppActionIds.linkAdd: '링크 추가',
  };

  /// Publishes what the editor and the workspace offer in stage 1, less
  /// [without], plus [extra].
  void publish({
    Set<String> without = const {},
    List<AppAction> extra = const [],
    bool saveEnabled = true,
    bool locked = false,
    Map<String, void Function(BuildContext)> runs = const {},
  }) {
    AppAction action(
      String id,
      String label,
      KitIconName icon, {
      bool? on,
      bool enabled = true,
      Key? key,
    }) => AppAction(
      id: id,
      label: label,
      icon: icon,
      checked: on,
      enabled: enabled,
      widgetKey: key,
      run: runs[id] ?? (_) => ran.add(id),
    );
    actions.publish(owner, [
      for (final a in [
        action(AppActionIds.pageList, '쪽 목록', KitIconName.sidebar),
        action(AppActionIds.toolPen, '펜', KitIconName.pen, on: true),
        action(AppActionIds.insertPage, '페이지 추가', KitIconName.pageAdd),
        action(AppActionIds.fullscreen, '전체 화면', KitIconName.expand, on: false),
        action(
          AppActionIds.pageMode,
          '한 쪽씩 보기',
          KitIconName.scrollDir,
          on: false,
          key: const ValueKey('editor-single-page-toggle'),
        ),
        action(AppActionIds.docInfo, '문서 정보', KitIconName.info),
        action(AppActionIds.rename, '이름 바꾸기', KitIconName.rename),
        action(AppActionIds.pdfSearch, 'PDF 본문 검색', KitIconName.search),
        action(
          AppActionIds.readOnly,
          '읽기 전용',
          KitIconName.readonly,
          on: locked,
        ),
        action(
          AppActionIds.viewToggle,
          'Markdown',
          KitIconName.textTt,
          key: const ValueKey('note-view-toggle'),
        ),
        action(AppActionIds.tabBarHide, '탭 줄 숨기기', KitIconName.collapse, on: false),
        action(AppActionIds.pageDuplicate, '쪽 복제', KitIconName.dup),
        action(AppActionIds.templateChange, '템플릿 바꾸기', KitIconName.template),
        action(AppActionIds.goToPage, '쪽으로 이동', KitIconName.gotoPage),
        action(AppActionIds.clearPage, '쪽 지우기', KitIconName.delPage),
        action(AppActionIds.moveToTrash, '휴지통으로', KitIconName.trash),
        action(AppActionIds.toolbarCustomize, '도구 막대 사용자화', KitIconName.tune),
        action(AppActionIds.openSettings, '설정', KitIconName.settings),
        action(
          AppActionIds.saveNow,
          '지금 저장',
          KitIconName.download,
          enabled: saveEnabled,
        ),
        for (final MapEntry(key: id, value: label) in moreLabels.entries)
          action(
            id,
            label,
            KitIconName.share,
            key: id == AppActionIds.quickSwitch
                ? const ValueKey('workspace-quick-switch')
                : null,
          ),
        ...extra,
      ])
        if (!without.contains(a.id)) a,
    ]);
  }

  setUp(() {
    actions = AppActionRegistry();
    ran = [];
    floatingBar = ValueNotifier(false);
    noteSheet = ValueNotifier(false);
    stows.editorToolbarTools.value = const [];
    stows.pageToolbarLayout.value = const [];
    stows.editorGestureMode.value = false;
    stows.lastZoomLock.value = false;
  });

  tearDown(() {
    actions.dispose();
    floatingBar.dispose();
    noteSheet.dispose();
    stows.lastZoomLock.value = false;
  });

  late double scale;
  late List<double> zoomedTo;

  Future<void> pumpBar(
    WidgetTester tester, {
    Size size = const Size(800, 2400),
    bool zoom = true,
  }) async {
    scale = 1.5;
    zoomedTo = [];
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MediaQuery(
        data: MediaQueryData(size: size),
        child: MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: KitEditorToolbar(
                actions: actions,
                title: '강의노트',
                floatingBarOpen: floatingBar,
                noteSheetOpen: noteSheet,
                pages: () => (index: 1, count: 5),
                zoom: zoom
                    ? DocZoom(
                        scale: () => scale,
                        zoomTo: (target) {
                          zoomedTo.add(target);
                          scale = target;
                        },
                      )
                    : null,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  Future<void> openMenu(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('editor-doc-menu')));
    await tester.pumpAndSettle();
  }

  /// The texts found, top to bottom.
  List<String> inOrder(WidgetTester tester, Iterable<String> texts) {
    final found = [
      for (final text in texts)
        if (findMenuText(text).evaluate().isNotEmpty)
          (text, tester.getTopLeft(findMenuText(text).first).dy),
    ]..sort((a, b) => a.$2.compareTo(b.$2));
    return [for (final (text, _) in found) text];
  }

  testWidgets('groups follow the design table and hide missing actions', (
    tester,
  ) async {
    publish();
    await pumpBar(tester);
    await openMenu(tester);
    expect(tester.takeException(), isNull);
    const order = [
      '강의노트',
      '문서 정보',
      '이름 바꾸기',
      '쪽 배치',
      '검색',
      '읽기 전용',
      '보기',
      'Markdown',
      '전체 화면',
      '탭 줄 숨기기',
      '확대 비율',
      '쪽 2',
      '쪽 복제',
      '템플릿 바꾸기',
      '쪽으로 이동',
      '지우기',
      '쪽 지우기',
      '휴지통으로',
      '정렬·설정',
      '도구 막대 사용자화',
      '전체 설정 열기',
      '더 보기',
      '지금 저장',
      '파일 내보내기',
    ];
    for (final text in order) {
      expect(find.text(text), findsOneWidget, reason: text);
    }
    expect(inOrder(tester, order), order);
    // 쪽으로 이동 shows where the page is; 확대 비율 the scale now
    expect(find.text('2 / 5'), findsOneWidget);
    expect(find.text('150%'), findsOneWidget);
    // 연속 스크롤 / 한 쪽씩 보기 is 쪽 배치 on top, not again in 보기
    expect(find.text('한 쪽씩 보기'), findsNothing);
    expect(find.text('연속 스크롤'), findsNothing);
    // 전체 화면 and 탭 줄 숨기기 are on/off rows
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('editor-doc-fullscreen')),
        matching: find.byWidgetPredicate(
          (w) => w is KitIcon && w.name == KitIconName.check,
        ),
      ),
      findsNothing,
    );
    // the red rows
    for (final row in ['쪽 지우기', '휴지통으로']) {
      expect(
        tester.widget<Text>(find.text(row)).style?.color,
        KitTokens.danger,
        reason: row,
      );
    }
    // later stages: nobody offers them, so no row
    for (final row in [
      '쪽 즐겨찾기',
      '쪽 복사',
      '개요에 추가',
      '골라서 지우기',
      '객체 정렬',
      '끝낸 메모도 보기',
    ]) {
      expect(find.text(row), findsNothing, reason: row);
    }

    // a missing action hides its row; a group with no row left hides too
    await tester.tapAt(const Offset(5, 2300));
    await tester.pumpAndSettle();
    publish(
      without: {
        AppActionIds.pdfSearch,
        AppActionIds.tabBarHide,
        AppActionIds.clearPage,
        AppActionIds.moveToTrash,
      },
    );
    await tester.pump();
    await tester.pump();
    await openMenu(tester);
    expect(find.text('검색'), findsNothing);
    expect(find.text('읽기 전용'), findsOneWidget);
    expect(find.text('탭 줄 숨기기'), findsNothing);
    expect(find.text('지우기'), findsNothing, reason: 'its two rows are gone');
    expect(find.text('쪽 지우기'), findsNothing);
  });

  testWidgets('rotate page row is hidden because the action does not exist', (
    tester,
  ) async {
    publish();
    await pumpBar(tester);
    await openMenu(tester);
    expect(actions.has(AppActionIds.pageRotate), isFalse);
    expect(find.text('쪽 돌리기'), findsNothing);
    await tester.tapAt(const Offset(5, 2300));
    await tester.pumpAndSettle();

    // the row is there for the stage that makes the action
    publish(
      extra: [
        AppAction(
          id: AppActionIds.pageRotate,
          label: '쪽 돌리기',
          icon: KitIconName.rotatePage,
          run: (_) => ran.add(AppActionIds.pageRotate),
        ),
      ],
    );
    await tester.pump();
    await tester.pump();
    await openMenu(tester);
    expect(find.text('쪽 돌리기'), findsOneWidget);
    expect(inOrder(tester, ['쪽 복제', '쪽 돌리기', '템플릿 바꾸기']), [
      '쪽 복제',
      '쪽 돌리기',
      '템플릿 바꾸기',
    ]);
  });

  testWidgets('more group lists the 229 overflow shortcuts in order', (
    tester,
  ) async {
    publish();
    await pumpBar(tester);
    await openMenu(tester);
    final labels = [
      for (final id in AppActionIds.more229) moreLabels[id]!,
    ];
    expect(inOrder(tester, ['더 보기', '지금 저장', ...labels]), [
      '더 보기',
      '지금 저장',
      ...labels,
    ]);
    // the rows keep the keys tests looked for on the old row
    expect(find.byKey(const ValueKey('workspace-quick-switch')), findsOneWidget);
    await tester.tap(find.text('북마크'));
    await tester.pumpAndSettle();
    expect(ran, [AppActionIds.bookmarks]);
    expect(find.text('더 보기'), findsNothing, reason: 'the menu closed first');
  });

  testWidgets('open settings pushes the full screen page', (tester) async {
    publish(
      runs: {
        AppActionIds.openSettings: (context) => Navigator.of(
          context,
        ).push(appSettingsRoute(actions: actions)),
      },
    );
    await pumpBar(tester);
    await openMenu(tester);
    await tester.tap(find.text('전체 설정 열기'));
    await tester.pumpAndSettle();
    expect(find.byType(AppSettingsPage), findsOneWidget);
    expect(find.text('전체 설정 열기'), findsNothing);
  });

  testWidgets('the quick buttons: 검색 runs, 읽기 전용 shows it is on', (
    tester,
  ) async {
    publish(locked: true);
    await pumpBar(tester);
    await openMenu(tester);
    expect(
      tester
          .getSemantics(find.byKey(const ValueKey('editor-doc-read-only')))
          .flagsCollection
          .isSelected
          .toBoolOrNull(),
      isTrue,
    );
    await tester.tap(find.text('읽기 전용'));
    await tester.pumpAndSettle();
    await openMenu(tester);
    await tester.tap(find.text('검색'));
    await tester.pumpAndSettle();
    expect(ran, [AppActionIds.readOnly, AppActionIds.pdfSearch]);
  });

  testWidgets('지금 저장 is dimmed with nothing to save', (tester) async {
    publish(saveEnabled: false);
    await pumpBar(tester);
    await openMenu(tester);
    final row = find.byKey(const ValueKey('editor-doc-saveNow'));
    expect(
      tester.getSemantics(row).flagsCollection.isEnabled.toBoolOrNull(),
      isFalse,
    );
    await tester.tap(find.text('지금 저장'));
    await tester.pumpAndSettle();
    expect(ran, isEmpty);
    expect(find.text('지금 저장'), findsOneWidget, reason: 'still open');
  });

  testWidgets('쪽 지우기 asks first, then runs clearPage', (tester) async {
    publish();
    await pumpBar(tester);
    await openMenu(tester);
    await tester.tap(find.text('쪽 지우기'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('eraser-clear-page-cancel')));
    await tester.pumpAndSettle();
    expect(ran, isEmpty);

    await openMenu(tester);
    await tester.tap(find.text('쪽 지우기'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('eraser-clear-page-confirm')));
    await tester.pumpAndSettle();
    expect(ran, [AppActionIds.clearPage]);
  });

  testWidgets('확대 비율: the ratios, the one in use checked, and the lock', (
    tester,
  ) async {
    publish();
    await pumpBar(tester);
    await openMenu(tester);
    await tester.tap(find.text('확대 비율'));
    await tester.pumpAndSettle();
    // the ratios are the zoom badge's list (one list)
    expect(zoomSteps, [0.5, 0.75, 1.0, 1.5, 2.0, 3.0]);
    final ratiosMenu = find
        .ancestor(of: find.text('75%'), matching: find.byType(KitMenu))
        .first;
    for (final label in ['50%', '75%', '100% (화면 너비)', '150%', '200%', '300%']) {
      expect(
        find.descendant(of: ratiosMenu, matching: find.text(label)),
        findsOneWidget,
        reason: label,
      );
    }
    bool checked(String key) =>
        tester
            .getSemantics(find.byKey(ValueKey(key)))
            .flagsCollection
            .isSelected
            .toBoolOrNull() ??
        false;
    expect(checked('editor-doc-zoom-1.5'), isTrue);
    expect(checked('editor-doc-zoom-2.0'), isFalse);
    // the submenu opens on the left of the menu, level with its row
    final row = tester.getRect(find.byKey(const ValueKey('editor-doc-zoom')));
    final ratios = tester.getRect(
      find.byKey(const ValueKey('editor-doc-zoom-0.5')),
    );
    expect(ratios.right, lessThan(row.left));

    // the lock: a switch row; while locked the ratios still choose
    await tester.tap(find.byKey(const ValueKey('editor-doc-zoom-lock')));
    await tester.pumpAndSettle();
    expect(stows.lastZoomLock.value, isTrue);
    await tester.tap(find.byKey(const ValueKey('editor-doc-zoom-2.0')));
    await tester.pumpAndSettle();
    expect(zoomedTo, [2.0]);
    expect(find.text('확대 비율'), findsNothing, reason: 'both windows closed');
  });

  testWidgets('without a page area there is no 확대 비율', (tester) async {
    publish();
    await pumpBar(tester, zoom: false);
    await openMenu(tester);
    expect(find.text('확대 비율'), findsNothing);
    expect(find.text('보기'), findsOneWidget);
  });

  testWidgets('on a phone the long menu stays on screen and slides inside', (
    tester,
  ) async {
    publish();
    await pumpBar(tester, size: const Size(360, 640));
    await openMenu(tester);
    expect(tester.takeException(), isNull);
    final head = find.text('강의노트');
    final window = find
        .ancestor(of: head, matching: find.byType(SingleChildScrollView))
        .last;
    expect(tester.getRect(window).bottom, lessThanOrEqualTo(640));
    expect(find.byKey(const ValueKey('kit-popover-fade')), findsOneWidget);
    expect(find.text('링크 추가').hitTestable(), findsNothing);
    await tester.drag(find.text('문서 정보'), const Offset(0, -2000));
    await tester.pumpAndSettle();
    expect(find.text('링크 추가').hitTestable(), findsOneWidget);
    expect(find.byKey(const ValueKey('kit-popover-fade')), findsNothing);
  });

  test('문서 정보 names the last edit as time ago', () {
    final now = DateTime(2026, 11, 25, 12);
    expect(docInfoAgo(now.subtract(const Duration(seconds: 20)), now), '방금 전');
    expect(docInfoAgo(now.subtract(const Duration(minutes: 43)), now), '43분 전');
    expect(docInfoAgo(now.subtract(const Duration(hours: 5)), now), '5시간 전');
    expect(docInfoAgo(now.subtract(const Duration(days: 3)), now), '3일 전');
    expect(docInfoAgo(DateTime(2026, 9, 2, 8), now), '2026-09-02');
  });

  testWidgets('the 7th draft quick buttons: 82 high, the icon 20 down', (
    tester,
  ) async {
    publish();
    await pumpBar(tester);
    await openMenu(tester);
    // `.kpanel .quick span`: padding 10, the icon's row 42, gap 4, the
    // text's line 12 × 1.35 (computed in the preview: 82.19 high)
    final box = tester.getRect(find.byKey(const ValueKey('editor-doc-search')));
    final icon = tester.getRect(
      find.descendant(
        of: find.byKey(const ValueKey('editor-doc-search')),
        matching: find.byType(KitIcon),
      ),
    );
    expect(box.height, moreOrLessEquals(82.2, epsilon: .05));
    expect(icon.top - box.top, moreOrLessEquals(20, epsilon: .05));
  });

  testWidgets('확대 잠금 sits under a line, 4 below the ratios', (
    tester,
  ) async {
    publish();
    await pumpBar(tester);
    await openMenu(tester);
    await tester.tap(find.text('확대 비율'));
    await tester.pumpAndSettle();
    final last = tester.getRect(find.byKey(const ValueKey('editor-doc-zoom-3.0')));
    final lock = tester.getRect(
      find.byKey(const ValueKey('editor-doc-zoom-lock')),
    );
    // `.ksub .it.zl`: margin-top 4, border-top 1
    expect(lock.top - last.bottom, moreOrLessEquals(5, epsilon: .01));
    expect(
      find.byKey(const ValueKey('kit-menu-line-above')),
      findsOneWidget,
    );
  });

  testWidgets('while read-only the rows that change the note are dimmed', (
    tester,
  ) async {
    publish(
      locked: true,
      extra: [
        AppAction(
          id: AppActionIds.outlineAdd,
          label: '개요에 추가',
          icon: KitIconName.outlineAdd,
          run: (_) => ran.add(AppActionIds.outlineAdd),
        ),
      ],
    );
    await pumpBar(tester);
    await openMenu(tester);
    bool on(String key) =>
        tester
            .getSemantics(find.byKey(ValueKey(key)))
            .flagsCollection
            .isEnabled
            .toBoolOrNull() ??
        true;
    // the workspace's 휴지통으로 does not know the lock; the menu dims it
    expect(on('editor-doc-moveToTrash'), isFalse);
    await tester.tap(find.text('휴지통으로'));
    await tester.pumpAndSettle();
    expect(ran, isEmpty);
    expect(on('editor-doc-rename'), isTrue, reason: 'naming is not writing');
    // the outline is the note's attachment, not the note (Task 10 ruling)
    expect(on('editor-doc-${AppActionIds.outlineAdd}'), isTrue);
  });

  /// The three rows left only in the old function row (Task 17 ruling):
  /// 이전·다음 위치 in 보기, 기기에 저장 in 더 보기, 손가락 필기 a switch in
  /// 정렬·설정; the names are 229's.
  List<AppAction> oldRowThree() => [
    for (final (id, label, icon) in const [
      (AppActionIds.prev, '이전 위치', KitIconName.back),
      (AppActionIds.next, '다음 위치', KitIconName.chevR),
      (AppActionIds.save, '기기에 저장', KitIconName.download),
    ])
      AppAction(id: id, label: label, icon: icon, run: (_) => ran.add(id)),
    AppAction(
      id: AppActionIds.finger,
      label: '손가락 필기',
      icon: KitIconName.tap,
      checked: stows.editorFingerDrawing.value,
      run: (_) {
        ran.add(AppActionIds.finger);
        stows.editorFingerDrawing.value = !stows.editorFingerDrawing.value;
      },
    ),
  ];

  testWidgets('the old function row\'s last three have rows in their groups', (
    tester,
  ) async {
    final finger = stows.editorFingerDrawing.value;
    addTearDown(() => stows.editorFingerDrawing.value = finger);
    stows.editorFingerDrawing.value = false;
    publish(extra: oldRowThree());
    await pumpBar(tester);
    await openMenu(tester);
    expect(
      inOrder(tester, [
        '보기',
        '탭 줄 숨기기',
        '이전 위치',
        '다음 위치',
        '확대 비율',
        '쪽 2',
        '정렬·설정',
        '도구 막대 사용자화',
        '손가락 필기',
        '전체 설정 열기',
        '더 보기',
        '지금 저장',
        '기기에 저장',
        '파일 내보내기',
      ]),
      [
        '보기',
        '탭 줄 숨기기',
        '이전 위치',
        '다음 위치',
        '확대 비율',
        '쪽 2',
        '정렬·설정',
        '도구 막대 사용자화',
        '손가락 필기',
        '전체 설정 열기',
        '더 보기',
        '지금 저장',
        '기기에 저장',
        '파일 내보내기',
      ],
    );
    // 손가락 필기 is a switch: it flips and the window stays open
    final fingerRow = find.byKey(const ValueKey('editor-doc-finger'));
    expect(
      find.descendant(of: fingerRow, matching: find.byType(KitSwitch)),
      findsOneWidget,
    );
    expect(tester.widget<KitSwitch>(find.byType(KitSwitch)).value, isFalse);
    await tester.tap(fingerRow);
    await tester.pumpAndSettle();
    expect(ran, [AppActionIds.finger]);
    expect(stows.editorFingerDrawing.value, isTrue);
    expect(find.text('정렬·설정'), findsOneWidget, reason: 'still open');
    expect(tester.widget<KitSwitch>(find.byType(KitSwitch)).value, isTrue);
    // the others close the window, then run
    for (final (label, id) in const [
      ('이전 위치', AppActionIds.prev),
      ('다음 위치', AppActionIds.next),
      ('기기에 저장', AppActionIds.save),
    ]) {
      ran.clear();
      if (find.text('보기').evaluate().isEmpty) await openMenu(tester);
      await tester.ensureVisible(find.text(label));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      expect(ran, [id], reason: label);
      expect(find.text('보기'), findsNothing, reason: '$label closed it');
    }
  });

  testWidgets('with the tab row hidden its row reads 탭 줄 보이기', (
    tester,
  ) async {
    publish(without: {AppActionIds.tabBarHide});
    // the workspace's, with the row hidden
    actions.publish(Object(), [
      AppAction(
        id: AppActionIds.tabBarHide,
        label: '탭 줄 숨기기',
        icon: KitIconName.noteTab,
        checked: true,
        run: (_) => ran.add(AppActionIds.tabBarHide),
      ),
    ]);
    await pumpBar(tester);
    await openMenu(tester);
    expect(find.text('탭 줄 숨기기'), findsNothing);
    final row = find.byKey(const ValueKey('editor-doc-tabBarHide'));
    expect(
      find.descendant(of: row, matching: find.text('탭 줄 보이기')),
      findsOneWidget,
    );
    // a way back, not a mode that is on: no check
    expect(
      find.descendant(
        of: row,
        matching: find.byWidgetPredicate(
          (w) => w is KitIcon && w.name == KitIconName.check,
        ),
      ),
      findsNothing,
    );
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(ran, [AppActionIds.tabBarHide]);
  });

  testWidgets('a long row name wraps instead of being cut', (tester) async {
    publish();
    await pumpBar(tester);
    await openMenu(tester);
    const label = '새 엔진으로 PDF 다시 만들기';
    final shown = findMenuText(label);
    final name = tester.renderObject<RenderParagraph>(shown);
    expect(name.didExceedMaxLines, isFalse);
    // two lines, broken between words, not inside 「만들기」
    expect(tester.getSize(shown).height, greaterThan(20));
    final text = tester.widget<Text>(shown).data!;
    expect(text.split(' ').last, '만\u2060들\u2060기');
    // read out as written
    expect(find.bySemanticsLabel(label), findsOneWidget);
    // a name that fits stays as it is
    expect(find.text('북마크'), findsOneWidget);
  });
}
