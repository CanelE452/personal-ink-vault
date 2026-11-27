import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/ink_ui/side_panel/kit_side_pages.dart';
import 'package:saber/components/ink_ui/side_panel/kit_side_panel.dart';
import 'package:saber/components/kit/kit_icon.dart';
import 'package:saber/components/kit/kit_text.dart';
import 'package:saber/components/kit/kit_tokens.dart';

/// The left panel's frame, its pages and its empty tabs (supplement Task 9,
/// 12th draft `#extras12`).
void main() {
  const pages = [
    KitSidePage(index: 0, aspectRatio: 1 / 1.4),
    KitSidePage(index: 1, aspectRatio: 1 / 1.4, current: true),
    KitSidePage(index: 2, aspectRatio: 1 / 1.4, favorite: true),
  ];

  /// The panel over a page of [size], holding its tab itself; the pages tab
  /// shows [pages], the others their empty line.
  Future<List<int>> mount(
    WidgetTester tester, {
    Size size = const Size(600, 800),
    bool phone = false,
    List<KitSideTab> tabs = KitSideTab.values,
    List<int>? held,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final tapped = <int>[];
    var tab = KitSideTab.pages;
    await tester.pumpWidget(
      MediaQuery(
        data: MediaQueryData(size: size),
        child: MaterialApp(
          home: Material(
            child: StatefulBuilder(
              builder: (context, setState) => KitSidePanel(
                open: true,
                phone: phone,
                tabs: tabs,
                tab: tab,
                onTab: (t) => setState(() => tab = t),
                body: tab == KitSideTab.pages
                    ? KitSidePages(
                        pages: pages,
                        columns: phone
                            ? KitTokens.sideGridPhoneColumns
                            : KitTokens.sideGridColumns,
                        thumbnail: (i) =>
                            SizedBox.expand(key: ValueKey('thumb-$i')),
                        onPage: tapped.add,
                        onManage: held?.add,
                      )
                    : KitSideEmpty(tab),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return tapped;
  }

  Finder tabOf(KitSideTab t) => find.byKey(ValueKey('kit-side-tab-${t.name}'));

  BoxDecoration decorationOf(WidgetTester tester, Finder f) =>
      tester
              .widget<DecoratedBox>(
                find
                    .descendant(of: f, matching: find.byType(DecoratedBox))
                    .first,
              )
              .decoration
          as BoxDecoration;

  testWidgets('a tab press shows that tab, white, and its content', (
    tester,
  ) async {
    await mount(tester);
    expect(
      decorationOf(tester, tabOf(KitSideTab.pages)).color,
      KitTokens.sideTabOnBg,
    );
    expect(decorationOf(tester, tabOf(KitSideTab.favorites)).color, isNull);
    expect(find.byKey(const ValueKey('thumb-0')), findsOneWidget);

    await tester.tap(tabOf(KitSideTab.favorites));
    await tester.pumpAndSettle();
    expect(
      decorationOf(tester, tabOf(KitSideTab.favorites)).color,
      KitTokens.sideTabOnBg,
    );
    expect(
      decorationOf(tester, tabOf(KitSideTab.favorites)).boxShadow,
      KitTokens.sideTabOnShadow,
    );
    expect(decorationOf(tester, tabOf(KitSideTab.pages)).color, isNull);
    expect(find.byKey(const ValueKey('thumb-0')), findsNothing);
    expect(find.text(keepWords(KitSideTab.favorites.empty!)), findsOneWidget);

    // 272 wide at the left, 48-high tabs under an 8 margin
    final panel = tester.getRect(find.byKey(const ValueKey('kit-side-panel')));
    expect(panel, const Rect.fromLTWH(0, 0, KitTokens.sidePanelWidth, 800));
    expect(
      tester.getRect(tabOf(KitSideTab.pages)),
      const Rect.fromLTWH(
        8 + KitTokens.sideTabsPadding,
        8 + KitTokens.sideTabsPadding,
        (KitTokens.sidePanelWidth - 16 - 6 - 3 * KitTokens.sideTabsGap) / 4,
        KitTokens.sideTabHeight,
      ),
    );
  });

  testWidgets(
    'the page on screen has the accent ring, a favourite the ribbon',
    (tester) async {
      final tapped = await mount(tester);
      Finder picture(int i) => find.byKey(ValueKey('kit-side-page-$i-picture'));
      BoxDecoration ring(int i) =>
          tester.widget<DecoratedBox>(picture(i)).decoration as BoxDecoration;
      expect(ring(1).boxShadow, KitTokens.sideThumbOnShadow);
      expect(ring(0).boxShadow, KitTokens.sideThumbShadow);
      expect(ring(2).boxShadow, KitTokens.sideThumbShadow);
      expect(ring(0).color, KitTokens.sideThumbBg);

      Text number(int i) => tester.widget<Text>(
        find.descendant(
          of: find.byKey(ValueKey('kit-side-page-$i')),
          matching: find.text('${i + 1}'),
        ),
      );
      expect(number(1).style!.color, KitTokens.sideThumbOnInk);
      expect(number(1).style!.fontWeight, FontWeight.w600);
      expect(number(0).style!.color, KitTokens.sideThumbInk);
      expect(number(0).style!.fontWeight, isNot(FontWeight.w600));

      for (final i in [0, 1]) {
        expect(find.byKey(ValueKey('kit-side-page-$i-ribbon')), findsNothing);
      }
      expect(
        find.byKey(const ValueKey('kit-side-page-2-ribbon')),
        findsOneWidget,
      );
      expect(
        tester.getSize(find.byKey(const ValueKey('kit-side-page-2-ribbon'))),
        const Size(KitTokens.sideRibbonWidth, KitTokens.sideRibbonHeight),
      );

      // two columns 14 apart inside 16 on each side
      const width = (KitTokens.sidePanelWidth - 32 - KitTokens.sideGridGap) / 2;
      expect(tester.getSize(picture(0)).width, closeTo(width, .01));
      expect(
        tester.getTopLeft(picture(1)).dx - tester.getTopRight(picture(0)).dx,
        closeTo(KitTokens.sideGridGap, .01),
      );
      final semantics = tester.ensureSemantics();
      expect(
        semanticsOf(tester, find.byKey(const ValueKey('kit-side-page-1'))),
        '쪽 2, 지금 쪽',
      );
      expect(
        semanticsOf(tester, find.byKey(const ValueKey('kit-side-page-2'))),
        '쪽 3, 즐겨찾기',
      );
      semantics.dispose();

      await tester.tap(find.byKey(const ValueKey('kit-side-page-2')));
      expect(tapped, [2]);
    },
  );

  testWidgets('a long press on a page asks to manage that page', (
    tester,
  ) async {
    final held = <int>[];
    final tapped = await mount(tester, held: held);
    await tester.longPress(find.byKey(const ValueKey('kit-side-page-2')));
    await tester.pumpAndSettle();
    expect(held, [2]);
    expect(tapped, isEmpty, reason: 'a long press is not a tap');
  });

  testWidgets('an empty tab shows its one line and icon only', (tester) async {
    await mount(tester);
    for (final tab in [
      KitSideTab.favorites,
      KitSideTab.outline,
      KitSideTab.audio,
    ]) {
      await tester.tap(tabOf(tab));
      await tester.pumpAndSettle();
      final empty = find.byType(KitSideEmpty);
      expect(empty, findsOneWidget, reason: tab.name);
      expect(
        find.descendant(of: empty, matching: find.byType(Text)),
        findsOneWidget,
        reason: tab.name,
      );
      expect(
        find.descendant(of: empty, matching: find.text(keepWords(tab.empty!))),
        findsOneWidget,
        reason: tab.name,
      );
      final icon = tester.widget<KitIcon>(
        find.descendant(of: empty, matching: find.byType(KitIcon)),
      );
      expect(icon.name, tab.icon, reason: tab.name);
      expect(icon.size, KitTokens.sideEmptyIconSize);
      expect(icon.color, KitTokens.sideEmptyIconInk);
      expect(find.byType(KitSidePages), findsNothing, reason: tab.name);
      // the preview spaces no letters; the Material theme's 0.25 would push
      // 「누르면」 down a line in the 228 the line has
      final line = tester.widget<RichText>(
        find.descendant(of: empty, matching: find.byType(RichText)),
      );
      expect(line.text.style!.letterSpacing, 0, reason: tab.name);
    }
  });

  testWidgets('without favourites the other three tabs share the row', (
    tester,
  ) async {
    await mount(
      tester,
      tabs: [KitSideTab.pages, KitSideTab.outline, KitSideTab.audio],
    );
    expect(tabOf(KitSideTab.favorites), findsNothing);
    expect(find.text('즐겨찾기'), findsNothing);
    const width =
        (KitTokens.sidePanelWidth - 16 - 6 - 2 * KitTokens.sideTabsGap) / 3;
    for (final t in [KitSideTab.pages, KitSideTab.outline, KitSideTab.audio]) {
      expect(tester.getSize(tabOf(t)).width, closeTo(width, .01));
    }
  });

  testWidgets('on a phone the panel covers the page, three pages a row', (
    tester,
  ) async {
    await mount(tester, size: const Size(360, 640), phone: true);
    final panel = tester.getRect(find.byKey(const ValueKey('kit-side-panel')));
    expect(panel, const Rect.fromLTWH(0, 0, 360, 640));
    final decoration =
        tester
                .widget<DecoratedBox>(
                  find
                      .descendant(
                        of: find.byKey(const ValueKey('kit-side-panel')),
                        matching: find.byType(DecoratedBox),
                      )
                      .first,
                )
                .decoration
            as BoxDecoration;
    expect(decoration.boxShadow, isNull);
    // the three pages side by side on one row
    final tops = {
      for (final i in [0, 1, 2])
        tester.getTopLeft(find.byKey(ValueKey('kit-side-page-$i'))).dy,
    };
    expect(tops, hasLength(1));
  });
}

/// The label the screen reader hears for [f].
String semanticsOf(WidgetTester tester, Finder f) =>
    tester.getSemantics(f).label;
