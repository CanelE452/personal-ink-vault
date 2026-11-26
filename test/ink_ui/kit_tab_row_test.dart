import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/ink_ui/doc_menu/kit_doc_menu.dart';
import 'package:saber/components/ink_ui/floating_bar/floating_bar_parts.dart';
import 'package:saber/components/ink_ui/kit_tab_row.dart';
import 'package:saber/components/kit/kit_tokens.dart';

import '../utils/kit_menu_finders.dart';

/// The tab row (Task 17, 9th draft c) on its own: the phone width slides
/// instead of cutting the titles, the open tab stays in view, the presses
/// of ⌄ and ×, and the ⌄ window's values.
void main() {
  const tabs = [
    KitTab(id: 'a', title: '강의노트 3주차'),
    KitTab(id: 'b', title: '예시 논문'),
    KitTab(id: 'c', title: '회의 메모'),
  ];

  Future<void> mount(
    WidgetTester tester, {
    double width = 586,
    List<KitTab> tabs = tabs,
    String? activeId = 'a',
    String? fallbackTitle,
    DocInfo info = const DocInfo(syncLabel: '연결 안 됨', offlineLabel: '준비됨'),
    ValueChanged<String>? onSelect,
    ValueChanged<String>? onClose,
  }) async {
    final size = Size(width, 400);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MediaQuery(
        data: MediaQueryData(size: size),
        child: MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                KitTabRow(
                  tabs: tabs,
                  activeId: activeId,
                  fallbackTitle: fallbackTitle,
                  onHome: () {},
                  onSelect: onSelect ?? (_) {},
                  onClose: onClose ?? (_) {},
                  onCloseOthers: (_) {},
                  onNewTab: () {},
                  docInfo: () => info,
                  onRename: () {},
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  RenderParagraph title(WidgetTester tester, String text) =>
      tester.renderObject<RenderParagraph>(find.text(text));

  testWidgets('on a phone the tabs keep their titles and the row slides', (
    tester,
  ) async {
    await mount(tester, width: 360);
    for (final tab in tabs) {
      expect(
        title(tester, tab.title).didExceedMaxLines,
        isFalse,
        reason: '${tab.title} is cut',
      );
    }
    final strip = tester.state<ScrollableState>(
      find.descendant(
        of: find.byType(KitTabRow),
        matching: find.byType(Scrollable),
      ),
    );
    expect(strip.position.maxScrollExtent, greaterThan(0));
    // on a tablet they share the row up to 190 each, as before (800: the
    // test font's names are wider than the app's)
    await mount(tester, width: 800);
    expect(
      tester.getSize(find.byKey(const ValueKey('document-tab-a'))).width,
      lessThanOrEqualTo(KitTokens.tabMaxWidth),
    );
    expect(
      tester
          .state<ScrollableState>(
            find.descendant(
              of: find.byType(KitTabRow),
              matching: find.byType(Scrollable),
            ),
          )
          .position
          .maxScrollExtent,
      0,
    );
  });

  testWidgets('the open tab slides into view', (tester) async {
    final many = [
      for (var i = 0; i < 6; i++) KitTab(id: 't$i', title: '긴 문서 이름 $i'),
    ];
    await mount(tester, width: 360, tabs: many, activeId: 't5');
    final last = find.byKey(const ValueKey('document-tab-t5'));
    expect(tester.getRect(last).right, lessThanOrEqualTo(360));
    expect(last.hitTestable(), findsOneWidget);
    // another tab opens: it comes into view too
    await mount(tester, width: 360, tabs: many, activeId: 't0');
    expect(
      find.byKey(const ValueKey('document-tab-t0')).hitTestable(),
      findsOneWidget,
    );
  });

  testWidgets('the open tab title takes no letter spacing from the theme', (
    tester,
  ) async {
    await mount(tester);
    for (final tab in tabs) {
      expect(
        title(tester, tab.title).text.style?.letterSpacing ?? 0,
        0,
        reason: tab.title,
      );
    }
  });

  testWidgets('⌄ and × take presses over 36 x the tab', (tester) async {
    final selected = <String>[];
    final closed = <String>[];
    await mount(tester, onSelect: selected.add, onClose: closed.add);
    final info = find.byKey(const ValueKey('document-tab-info'));
    final close = find.byKey(const ValueKey('document-tab-close-a'));
    for (final box in [info, close]) {
      expect(tester.getSize(box).width, KitTokens.tabHit);
      expect(
        tester.getSize(box).height,
        KitTokens.tabRowHeight - KitTokens.tabTop,
      );
    }

    /// The four corners of [box], 3 inside (the open tab's top corners are
    /// round, radius 8, and its shape takes the presses), and the middle of
    /// each side, 1 inside.
    List<Offset> corners(Finder box) {
      final r = tester.getRect(box).deflate(3);
      final e = tester.getRect(box).deflate(1);
      return [
        r.topLeft,
        r.topRight,
        r.bottomLeft,
        r.bottomRight,
        e.topCenter,
        e.bottomCenter,
        e.centerLeft,
        e.centerRight,
      ];
    }

    for (final at in corners(close)) {
      await tester.tapAt(at);
      await tester.pump();
    }
    expect(closed, List.filled(8, 'a'));
    for (final at in corners(info)) {
      await tester.tapAt(at);
      await tester.pumpAndSettle();
      expect(find.text('마지막 편집'), findsOneWidget, reason: '$at');
      await tester.tapAt(const Offset(560, 380));
      await tester.pumpAndSettle();
      expect(find.text('마지막 편집'), findsNothing);
    }
    expect(selected, isEmpty, reason: 'the tab itself took none of them');
  });

  testWidgets('on a phone the tab row fades where the tabs run past it', (
    tester,
  ) async {
    FloatingBarEdgeFade fade() => tester.widget<FloatingBarEdgeFade>(
      find.descendant(
        of: find.byType(KitTabRow),
        matching: find.byType(FloatingBarEdgeFade),
      ),
    );
    await mount(tester, width: 360);
    expect((fade().start, fade().end), (false, true));
    final strip = tester.state<ScrollableState>(
      find.descendant(
        of: find.byType(KitTabRow),
        matching: find.byType(Scrollable),
      ),
    );
    strip.position.jumpTo(strip.position.maxScrollExtent / 2);
    await tester.pump();
    expect((fade().start, fade().end), (true, true));
    strip.position.jumpTo(strip.position.maxScrollExtent);
    await tester.pump();
    expect((fade().start, fade().end), (true, false));
    // a tablet: all of them in the row, no fade
    await mount(tester, width: 800);
    expect((fade().start, fade().end), (false, false));
  });

  testWidgets('with no tabs the name shows, with home and +', (tester) async {
    await mount(tester, tabs: const [], activeId: null, fallbackTitle: '혼자 연 문서');
    expect(find.text('혼자 연 문서'), findsOneWidget);
    expect(find.byKey(const ValueKey('workspace-back-to-library')), findsOneWidget);
    expect(find.byKey(const ValueKey('workspace-new-tab')), findsOneWidget);
  });

  testWidgets('the ⌄ window shows 동기화됨 in green', (tester) async {
    await mount(
      tester,
      info: const DocInfo(
        syncLabel: '동기화됨',
        synced: true,
        offlineLabel: '준비됨',
      ),
    );
    await tester.tap(find.byKey(const ValueKey('document-tab-info')));
    await tester.pumpAndSettle();
    expect(findMenuText('동기화 상태'), findsOneWidget);
    expect(tester.widget<Text>(find.text('동기화됨')).style?.color, KitTokens.ok);
  });
}
