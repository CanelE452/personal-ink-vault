import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/ink_ui/side_panel/kit_page_menu.dart';
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
      expect(find.bySemanticsLabel('쪽 2, 지금 쪽'), findsOneWidget);
      expect(find.bySemanticsLabel('쪽 3, 즐겨찾기'), findsOneWidget);
      semantics.dispose();

      await tester.tap(find.byKey(const ValueKey('kit-side-page-2')));
      expect(tapped, [2]);
    },
  );

  testWidgets('a long press on a page without onMove lifts nothing', (
    tester,
  ) async {
    await mount(tester);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('kit-side-page-2'))),
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    expect(find.byType(LongPressDraggable<int>), findsNothing);
    expect(find.byKey(const ValueKey('thumb-2')), findsOneWidget);
    await gesture.up();
    await tester.pumpAndSettle();
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

  group('thumbnail ribbon, dots and drag', () {
    /// [count] pages in a panel body of [size]; [phone] picks 3 columns.
    Future<void> mountGrid(
      WidgetTester tester, {
      int count = 4,
      bool phone = false,
      Size size = const Size(600, 800),
      Set<int> favorites = const {},
      bool showRibbon = false,
      void Function(int from, int to)? onMove,
      ValueChanged<int>? onFavorite,
      void Function(BuildContext context, int index)? onMenu,
      ValueChanged<int>? onPage,
      List<double>? ratios,
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData(size: size),
          child: MaterialApp(
            home: Material(
              child: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: phone ? size.width : KitTokens.sidePanelWidth,
                  child: KitSidePages(
                    pages: [
                      for (var i = 0; i < count; i++)
                        KitSidePage(
                          index: i,
                          aspectRatio: ratios?[i] ?? 1 / 1.4,
                          favorite: favorites.contains(i),
                        ),
                    ],
                    columns: phone
                        ? KitTokens.sideGridPhoneColumns
                        : KitTokens.sideGridColumns,
                    thumbnail: (i) =>
                        SizedBox.expand(key: ValueKey('thumb-$i')),
                    onPage: onPage ?? (_) {},
                    onMove: onMove,
                    onFavorite: onFavorite,
                    showRibbon: showRibbon,
                    onMenu: onMenu,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    Finder thumb(int i) => find.byKey(ValueKey('kit-side-page-$i-picture'));

    /// Holds the thumbnail [from] past the long-press time, moves it to the
    /// middle of thumbnail [to] and lets go.
    Future<void> dragOnto(WidgetTester tester, int from, int to) async {
      final gesture = await tester.startGesture(tester.getCenter(thumb(from)));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      await gesture.moveTo(tester.getCenter(thumb(to)));
      await tester.pump(const Duration(milliseconds: 100));
      await gesture.up();
      await tester.pumpAndSettle();
    }

    testWidgets('tapping the ribbon calls onFavorite and not onPage', (
      tester,
    ) async {
      final favorited = <int>[];
      final paged = <int>[];
      await mountGrid(
        tester,
        favorites: {1},
        showRibbon: true,
        onFavorite: favorited.add,
        onPage: paged.add,
      );
      final hit = find.byKey(const ValueKey('kit-side-page-1-favorite-button'));
      expect(tester.getSize(hit).width, greaterThanOrEqualTo(32));
      expect(tester.getSize(hit).height, greaterThanOrEqualTo(32));
      await tester.tap(hit);
      await tester.pumpAndSettle();
      expect(favorited, [1]);
      expect(paged, isEmpty);

      // a plain page's ribbon spot toggles the same way
      await tester.tap(
        find.byKey(const ValueKey('kit-side-page-0-favorite-button')),
      );
      await tester.pumpAndSettle();
      expect(favorited, [1, 0]);
      expect(paged, isEmpty);
    });

    testWidgets('no favourite button when onFavorite is null', (tester) async {
      await mountGrid(tester, favorites: {1});
      expect(
        find.byKey(const ValueKey('kit-side-page-1-favorite-button')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('kit-side-page-1-ribbon')),
        findsOneWidget,
      );
    });

    testWidgets(
      'an unfavourite page shows an outline ribbon only when showRibbon',
      (tester) async {
        await mountGrid(tester, favorites: {1}, showRibbon: true);
        final outline = find.byKey(const ValueKey('kit-side-page-0-ribbon'));
        expect(outline, findsOneWidget);
        expect(
          tester.getSize(outline),
          const Size(KitTokens.sideRibbonWidth, KitTokens.sideRibbonHeight),
        );
        // the outline is a stroke in its own colour, the favourite is filled
        expect(
          tester
              .widget<CustomPaint>(
                find.descendant(
                  of: outline,
                  matching: find.byType(CustomPaint),
                ),
              )
              .painter,
          isNotNull,
        );
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('kit-side-page-1-ribbon')),
            matching: find.byType(ColoredBox),
          ),
          findsOneWidget,
          reason: 'a favourite stays the filled accent ribbon',
        );
        expect(
          find.descendant(of: outline, matching: find.byType(ColoredBox)),
          findsNothing,
        );

        await mountGrid(tester, favorites: {1});
        expect(
          find.byKey(const ValueKey('kit-side-page-0-ribbon')),
          findsNothing,
        );
        expect(
          find.byKey(const ValueKey('kit-side-page-1-ribbon')),
          findsOneWidget,
        );
      },
    );

    testWidgets('tapping the dots calls onMenu with that page', (tester) async {
      final calls = <(BuildContext, int)>[];
      final paged = <int>[];
      await mountGrid(
        tester,
        onMenu: (context, i) => calls.add((context, i)),
        onPage: paged.add,
      );
      final dots = find.byKey(const ValueKey('kit-side-page-2-menu'));
      expect(tester.getSize(dots).width, greaterThanOrEqualTo(32));
      expect(tester.getSize(dots).height, greaterThanOrEqualTo(32));
      // bottom right of that page's picture
      final picture = tester.getRect(thumb(2));
      expect(tester.getRect(dots).bottomRight, picture.bottomRight);
      await tester.tap(dots);
      await tester.pumpAndSettle();
      expect(calls.map((c) => c.$2), [2]);
      expect(paged, isEmpty);
      expect(
        find
            .ancestor(
              of: dots,
              matching: find.byElementPredicate((e) => e == calls.single.$1),
            )
            .evaluate()
            .isNotEmpty,
        isTrue,
        reason: 'the context is that thumbnail\'s dots button',
      );
    });

    for (final phone in [false, true])
      testWidgets(
        phone
            ? 'on a phone each page menu ends 8 inside the panel, also opening '
                  'up'
            : 'each page menu ends 8 inside the panel, as a row menu does',
        (tester) async {
          const size = Size(360, 600);
          await mountGrid(
            tester,
            count: phone ? 9 : 4,
            phone: phone,
            size: phone ? size : const Size(600, 800),
            onMenu: (button, i) => showKitPageMenu(
              button,
              canEdit: true,
              canPaste: true,
              canDelete: true,
              canClear: true,
            ),
          );
          final panel = tester.getRect(find.byType(KitSidePages));
          final screen = phone ? size.height : 800.0;
          // every column; on a phone, the last row's menu opens up
          for (final i in phone ? [0, 1, 2, 7] : [0, 1]) {
            final dots = find.byKey(ValueKey('kit-side-page-$i-menu'));
            await tester.tap(dots);
            await tester.pumpAndSettle();
            final top = tester.getRect(
              find.byKey(const ValueKey('kit-page-menu-앞에 쪽 추가')),
            );
            final foot = tester.getRect(
              find.byKey(const ValueKey('kit-page-menu-쪽 삭제')),
            );
            expect(
              top.right,
              closeTo(panel.right - KitTokens.sideMenuRight, 0.01),
              reason: 'page $i',
            );
            expect(top.left, greaterThanOrEqualTo(panel.left), reason: '$i');
            expect(top.top, greaterThanOrEqualTo(0), reason: 'page $i');
            expect(foot.bottom, lessThanOrEqualTo(screen), reason: 'page $i');
            final button = tester.getRect(dots);
            if (i == 7) {
              expect(foot.bottom, closeTo(button.top, 0.01), reason: 'up');
            } else {
              expect(top.top, closeTo(button.bottom, 0.01), reason: '$i');
            }
            await tester.tapAt(Offset(panel.left + 4, screen - 4));
            await tester.pumpAndSettle();
          }
        },
      );

    testWidgets('the dots show their menu open until it is done', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      final menu = Completer<void>();
      await mountGrid(tester, onMenu: (_, _) => menu.future);
      Finder dots(int i) => find.byKey(ValueKey('kit-side-page-$i-menu'));
      Finder fill(int i) =>
          find.descendant(of: dots(i), matching: find.byType(DecoratedBox));
      bool expanded(int i) =>
          tester
              .getSemantics(
                find
                    .ancestor(of: dots(i), matching: find.byType(Semantics))
                    .first,
              )
              .flagsCollection
              .isExpanded
              .toBoolOrNull() ??
          false;
      expect(fill(1), findsNothing);

      await tester.tap(dots(1));
      await tester.pump();
      expect(fill(1), findsOneWidget);
      expect(
        (tester.widget<DecoratedBox>(fill(1)).decoration as BoxDecoration)
            .color,
        KitTokens.sideMenuDotsOpenBg,
      );
      expect(fill(0), findsNothing, reason: 'only the page whose menu it is');
      expect(expanded(1), isTrue);
      expect(expanded(0), isFalse);

      menu.complete();
      await tester.pumpAndSettle();
      expect(fill(1), findsNothing);
      expect(expanded(1), isFalse);
      semantics.dispose();
    });

    test('the outline ribbon stands 3:1 out from the paper', () {
      final ink = KitTokens.sideRibbonOutline.computeLuminance();
      final paper = KitTokens.sideThumbBg.computeLuminance();
      expect((paper + 0.05) / (ink + 0.05), greaterThanOrEqualTo(3));
    });

    testWidgets('no dots without onMenu', (tester) async {
      await mountGrid(tester);
      expect(find.byKey(const ValueKey('kit-side-page-0-menu')), findsNothing);
    });

    testWidgets('long press and drag onto the third thumbnail calls '
        'onMove(0, 2)', (tester) async {
      final moves = <(int, int)>[];
      final paged = <int>[];
      await mountGrid(
        tester,
        onMove: (a, b) => moves.add((a, b)),
        onPage: paged.add,
      );
      await dragOnto(tester, 0, 2);
      expect(moves, [(0, 2)]);
      expect(paged, isEmpty);
    });

    testWidgets('dropping on the last place calls onMove(0, 3)', (
      tester,
    ) async {
      final moves = <(int, int)>[];
      await mountGrid(tester, onMove: (a, b) => moves.add((a, b)));
      await dragOnto(tester, 0, 3);
      expect(moves, [(0, 3)]);
    });

    testWidgets('dropping back on itself calls nothing', (tester) async {
      final moves = <(int, int)>[];
      await mountGrid(tester, onMove: (a, b) => moves.add((a, b)));
      await dragOnto(tester, 1, 1);
      expect(moves, isEmpty);
    });

    testWidgets('no drag when onMove is null', (tester) async {
      final paged = <int>[];
      await mountGrid(tester, onPage: paged.add);
      expect(find.byType(LongPressDraggable<int>), findsNothing);
      await dragOnto(tester, 0, 2);
      expect(find.byType(DragTarget<int>), findsNothing);
      expect(paged, isEmpty, reason: 'a held press is not a tap');
    });

    testWidgets('a long press with onMove set starts the drag', (tester) async {
      final paged = <int>[];
      final moves = <(int, int)>[];
      await mountGrid(
        tester,
        onPage: paged.add,
        onMove: (a, b) => moves.add((a, b)),
      );
      await dragOnto(tester, 0, 2);
      expect(paged, isEmpty);
      expect(moves, [(0, 2)]);
    });

    testWidgets('a phone 3-column grid gives one onMove(0, 2) per drop', (
      tester,
    ) async {
      final moves = <(int, int)>[];
      await mountGrid(
        tester,
        phone: true,
        count: 6,
        size: const Size(400, 800),
        onMove: (a, b) => moves.add((a, b)),
      );
      await dragOnto(tester, 0, 2);
      expect(moves, [(0, 2)]);
    });

    testWidgets('dragging near the bottom edge scrolls the grid', (
      tester,
    ) async {
      final moves = <(int, int)>[];
      await mountGrid(
        tester,
        phone: true,
        count: 30,
        size: const Size(400, 500),
        onMove: (a, b) => moves.add((a, b)),
      );
      final list = find.byType(Scrollable);
      double offset() => tester.state<ScrollableState>(list).position.pixels;
      expect(offset(), 0);
      final gesture = await tester.startGesture(tester.getCenter(thumb(0)));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      await gesture.moveTo(
        const Offset(200, 500 - KitTokens.sideDragAutoScrollEdge / 2),
      );
      for (var n = 0; n < 20; n++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      final scrolled = offset();
      expect(scrolled, greaterThan(100));

      // and back up near the top edge
      await gesture.moveTo(
        const Offset(200, KitTokens.sideDragAutoScrollEdge / 2),
      );
      for (var n = 0; n < 20; n++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(offset(), lessThan(scrolled));
      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('a drop after scrolling lands on the page now under the '
        'finger', (tester) async {
      final moves = <(int, int)>[];
      await mountGrid(
        tester,
        phone: true,
        count: 30,
        size: const Size(400, 500),
        onMove: (a, b) => moves.add((a, b)),
      );
      final gesture = await tester.startGesture(tester.getCenter(thumb(0)));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      await gesture.moveTo(
        const Offset(200, 500 - KitTokens.sideDragAutoScrollEdge / 2),
      );
      for (var n = 0; n < 60; n++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await gesture.moveTo(const Offset(200, 250));
      await tester.pump(const Duration(milliseconds: 20));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(moves, hasLength(1));
      expect(moves.single.$1, 0);
      expect(moves.single.$2, greaterThan(15));
    });

    void expectAt(Offset actual, Offset expected, {String? reason}) =>
        expect((actual - expected).distance, lessThan(.01), reason: reason);

    Rect slot(WidgetTester tester, int i) => tester.getRect(thumb(i));

    testWidgets('hovering slot 2 with page 0 moves pages 1 and 2 one slot back '
        'and leaves page 0 a gap at slot 2', (tester) async {
      final moves = <(int, int)>[];
      await mountGrid(tester, onMove: (a, b) => moves.add((a, b)));
      final home = [for (var i = 0; i < 4; i++) slot(tester, i).topLeft];
      final gesture = await tester.startGesture(tester.getCenter(thumb(0)));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      await gesture.moveTo(tester.getCenter(thumb(2)));
      await tester.pump(const Duration(milliseconds: 20));
      await tester.pump(const Duration(milliseconds: 500));
      expectAt(tester.getTopLeft(thumb(1)), home[0]);
      expectAt(tester.getTopLeft(thumb(2)), home[1]);
      expectAt(tester.getTopLeft(thumb(0)), home[2], reason: 'the gap');
      expectAt(tester.getTopLeft(thumb(3)), home[3]);
      expect(moves, isEmpty, reason: 'nothing is asked before the drop');

      // sliding the other way: page 3 over slot 1 pushes pages 1 and 2 on
      await gesture.up();
      await tester.pumpAndSettle();
      expect(moves, [(0, 2)]);
      expect(
        [for (var i = 0; i < 4; i++) slot(tester, i).topLeft],
        home,
        reason: 'the real order is drawn again after the drop',
      );

      final back = await tester.startGesture(tester.getCenter(thumb(3)));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      await back.moveTo(tester.getCenter(thumb(1)));
      await tester.pump(const Duration(milliseconds: 20));
      await tester.pump(const Duration(milliseconds: 500));
      expectAt(tester.getTopLeft(thumb(1)), home[2]);
      expectAt(tester.getTopLeft(thumb(2)), home[3]);
      expectAt(tester.getTopLeft(thumb(3)), home[1]);
      expectAt(tester.getTopLeft(thumb(0)), home[0]);
      await back.up();
      await tester.pumpAndSettle();
      expect(moves, [(0, 2), (3, 1)]);
    });

    testWidgets('a cancelled drag calls nothing and puts the pages back', (
      tester,
    ) async {
      final moves = <(int, int)>[];
      await mountGrid(tester, onMove: (a, b) => moves.add((a, b)));
      final home = [for (var i = 0; i < 4; i++) slot(tester, i).topLeft];
      final gesture = await tester.startGesture(tester.getCenter(thumb(0)));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      await gesture.moveTo(tester.getCenter(thumb(3)));
      await tester.pump(const Duration(milliseconds: 20));
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.getTopLeft(thumb(1)), isNot(home[1]));
      await gesture.cancel();
      await tester.pumpAndSettle();
      expect(moves, isEmpty);
      expect([for (var i = 0; i < 4; i++) slot(tester, i).topLeft], home);
    });

    testWidgets('a phone drop across rows works and moves the pages between '
        'across the row end', (tester) async {
      final moves = <(int, int)>[];
      await mountGrid(
        tester,
        phone: true,
        count: 6,
        size: const Size(400, 800),
        onMove: (a, b) => moves.add((a, b)),
      );
      final home = [for (var i = 0; i < 6; i++) slot(tester, i).topLeft];
      final gesture = await tester.startGesture(tester.getCenter(thumb(0)));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      await gesture.moveTo(tester.getCenter(thumb(4)));
      await tester.pump(const Duration(milliseconds: 20));
      await tester.pump(const Duration(milliseconds: 500));
      // page 3 (second row, first column) steps back to slot 2 (first row,
      // last column)
      expectAt(tester.getTopLeft(thumb(3)), home[2]);
      expectAt(tester.getTopLeft(thumb(1)), home[0]);
      expectAt(tester.getTopLeft(thumb(4)), home[3]);
      expectAt(tester.getTopLeft(thumb(0)), home[4]);
      expectAt(tester.getTopLeft(thumb(5)), home[5]);
      await gesture.moveTo(tester.getCenter(thumb(5)));
      await tester.pump(const Duration(milliseconds: 500));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(moves, [(0, 5)]);
    });

    testWidgets('the picture under the finger has a size on the first frame '
        'of the drag', (tester) async {
      await mountGrid(tester, onMove: (a, b) {});
      final cell = tester.getSize(thumb(0));
      final gesture = await tester.startGesture(tester.getCenter(thumb(0)));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      final copies = find.byKey(const ValueKey('thumb-0'));
      expect(copies, findsNWidgets(2));
      final lifted = tester.getSize(copies.last);
      expect(lifted.width, closeTo(cell.width, .01));
      expect(lifted.height, closeTo(cell.height, .01));
      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('a finger held still while the grid runs drops on the page '
        'now under it', (tester) async {
      final moves = <(int, int)>[];
      await mountGrid(
        tester,
        phone: true,
        count: 30,
        size: const Size(400, 500),
        onMove: (a, b) => moves.add((a, b)),
      );
      final first = slot(tester, 0);
      final pitch = slot(tester, 3).top - first.top;
      final cellWidth = first.width;
      final gesture = await tester.startGesture(tester.getCenter(thumb(0)));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      const finger = Offset(200, 500 - KitTokens.sideDragAutoScrollEdge / 2);
      await gesture.moveTo(finger);
      for (var n = 0; n < 40; n++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      final offset = tester
          .state<ScrollableState>(find.byType(Scrollable))
          .position
          .pixels;
      expect(offset, greaterThan(300));
      final row = ((offset + finger.dy - first.top) / pitch).floor();
      final column =
          ((finger.dx - first.left) / (cellWidth + KitTokens.sideGridGap))
              .floor();
      await gesture.up();
      await tester.pumpAndSettle();
      expect(moves, hasLength(1));
      expect(moves.single, (0, row * 3 + column));
    });

    testWidgets('the ribbon and the dots speak for themselves', (tester) async {
      final semantics = tester.ensureSemantics();
      await mountGrid(
        tester,
        favorites: {1},
        showRibbon: true,
        onFavorite: (_) {},
        onMenu: (_, _) {},
      );
      expect(find.bySemanticsLabel('쪽 메뉴'), findsNWidgets(4));
      expect(find.bySemanticsLabel('즐겨찾기에서 빼기'), findsOneWidget);
      expect(find.bySemanticsLabel('즐겨찾기에 추가'), findsNWidgets(3));
      expect(
        find.bySemanticsLabel('쪽 2, 즐겨찾기'),
        findsOneWidget,
        reason: 'the page itself keeps its label and no button text in it',
      );
      semantics.dispose();
    });

    testWidgets('nothing drawn at the ribbon spot means nothing to tap', (
      tester,
    ) async {
      final favorited = <int>[];
      await mountGrid(tester, favorites: {1}, onFavorite: favorited.add);
      expect(
        find.byKey(const ValueKey('kit-side-page-0-favorite-button')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('kit-side-page-1-favorite-button')),
        findsOneWidget,
      );
      await tester.tapAt(
        tester.getRect(thumb(0)).topRight + const Offset(-10, 10),
      );
      expect(favorited, isEmpty);
    });

    testWidgets(
      'the outline ribbon is a stroke in the outline colour, the dots '
      'the kit icon in their ink',
      (tester) async {
        await mountGrid(
          tester,
          favorites: {1},
          showRibbon: true,
          onMenu: (_, _) {},
        );
        final outline = tester.renderObject(
          find.descendant(
            of: find.byKey(const ValueKey('kit-side-page-0-ribbon')),
            matching: find.byType(CustomPaint),
          ),
        );
        expect(
          outline,
          paints..path(
            color: KitTokens.sideRibbonOutline,
            style: PaintingStyle.stroke,
          ),
        );
        final dots = tester.widget<KitIcon>(
          find.descendant(
            of: find.byKey(const ValueKey('kit-side-page-0-menu')),
            matching: find.byType(KitIcon),
          ),
        );
        expect(dots.name, KitIconName.moreV);
        expect(dots.size, KitTokens.sideMenuDotsIconSize);
        expect(dots.color, KitTokens.sideMenuDotsInk);
        // in the middle of its 32 square
        expect(
          tester.getCenter(
            find.descendant(
              of: find.byKey(const ValueKey('kit-side-page-0-menu')),
              matching: find.byType(KitIcon),
            ),
          ),
          tester.getCenter(find.byKey(const ValueKey('kit-side-page-0-menu'))),
        );
      },
    );

    /// Where the pictures belong when page [from] is lifted over slot [over]:
    /// the pages in the new order, a row as tall as its tallest cell, worked
    /// out here from the ratios alone. [home] is where they sit at rest.
    List<Offset> reflowed(
      WidgetTester tester,
      List<double> ratios,
      int columns,
      int from,
      int over,
    ) {
      final width = slot(tester, 0).width;
      final cell = tester.getSize(
        find.byKey(const ValueKey('kit-side-page-0')),
      );
      final extra = cell.height - slot(tester, 0).height;
      double height(int page) => width / ratios[page] + extra;
      final order = [for (var i = 0; i < ratios.length; i++) i]
        ..removeAt(from)
        ..insert(over, from);
      final left = slot(tester, 0).left;
      var y = slot(tester, 0).top;
      final out = List.filled(ratios.length, Offset.zero);
      for (var row = 0; row * columns < order.length; row++) {
        var tallest = 0.0;
        for (var c = 0; c < columns && row * columns + c < order.length; c++) {
          final page = order[row * columns + c];
          out[page] = Offset(left + c * (width + KitTokens.sideGridGap), y);
          tallest = tallest < height(page) ? height(page) : tallest;
        }
        y += tallest + KitTokens.sideGridGap;
      }
      return out;
    }

    Future<void> mixedReflow(
      WidgetTester tester, {
      required List<double> ratios,
      required int columns,
      required int over,
    }) async {
      final moves = <(int, int)>[];
      await mountGrid(
        tester,
        phone: columns == 3,
        count: ratios.length,
        ratios: ratios,
        size: columns == 3 ? const Size(400, 800) : const Size(600, 800),
        onMove: (a, b) => moves.add((a, b)),
      );
      final want = reflowed(tester, ratios, columns, 0, over);
      final gesture = await tester.startGesture(tester.getCenter(thumb(0)));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      await gesture.moveTo(tester.getCenter(thumb(over)));
      await tester.pump(const Duration(milliseconds: 20));
      await tester.pump(const Duration(milliseconds: 500));
      final rects = <Rect>[];
      for (var i = 0; i < ratios.length; i++) {
        final at = tester.getTopLeft(thumb(i));
        expect(
          (at - want[i]).distance,
          lessThan(.5),
          reason: 'page $i should sit at ${want[i]}, sits at $at',
        );
        rects.add(tester.getRect(thumb(i)));
      }
      for (var a = 0; a < rects.length; a++) {
        for (var b = a + 1; b < rects.length; b++) {
          expect(
            rects[a].overlaps(rects[b]),
            isFalse,
            reason: 'pages $a and $b overlap: ${rects[a]} ${rects[b]}',
          );
        }
      }
      await gesture.up();
      await tester.pumpAndSettle();
      expect(moves, [(0, over)]);
    }

    testWidgets('mixed portrait and landscape pages, 2 columns: pages step '
        'into the reflowed rows and do not overlap', (tester) async {
      await mixedReflow(
        tester,
        ratios: const [0.71, 1.41, 1.41, 0.71, 0.71, 1.41],
        columns: 2,
        over: 3,
      );
    });

    testWidgets('mixed ratios, 3 columns, one row down', (tester) async {
      await mixedReflow(
        tester,
        ratios: const [1.41, 0.71, 1.41, 0.71, 1.41, 0.71, 0.71, 1.41, 0.71],
        columns: 3,
        over: 4,
      );
    });

    testWidgets('mixed ratios, 3 columns, a landscape page into a portrait '
        'row', (tester) async {
      await mixedReflow(
        tester,
        ratios: const [0.71, 1.41, 0.71, 1.41, 0.71, 1.41, 1.41, 0.71, 1.41],
        columns: 3,
        over: 7,
      );
    });

    testWidgets('pages the grid builds during a drag are already in their '
        'stepped-aside places', (tester) async {
      await mountGrid(
        tester,
        phone: true,
        count: 30,
        size: const Size(400, 500),
        onMove: (a, b) {},
      );
      final first = slot(tester, 0);
      final pitch = slot(tester, 3).top - first.top;
      Offset place(int s) => Offset(
        first.left + (s % 3) * (first.width + KitTokens.sideGridGap),
        first.top + (s ~/ 3) * pitch,
      );
      const finger = Offset(200, 400);
      final over =
          ((finger.dy - first.top) / pitch).floor() * 3 +
          ((finger.dx - first.left) / (first.width + KitTokens.sideGridGap))
              .floor();
      expect(over, greaterThan(6));
      final gesture = await tester.startGesture(tester.getCenter(thumb(0)));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      await gesture.moveTo(finger);
      await tester.pump(const Duration(milliseconds: 20));
      await tester.pump(const Duration(milliseconds: 500));
      final position = tester
          .state<ScrollableState>(find.byType(Scrollable))
          .position;
      // the grid is carried away and back (the finger still), so the pages
      // between are built again in the middle of the drag
      position.jumpTo(1200);
      await tester.pump(const Duration(milliseconds: 50));
      expect(thumb(2).evaluate(), isEmpty, reason: 'page 2 was let go');
      position.jumpTo(0);
      await tester.pump(const Duration(milliseconds: 50));
      for (var i = 1; i <= over; i++) {
        expect(thumb(i).evaluate(), isNotEmpty, reason: 'page $i is built');
        expectAt(
          tester.getTopLeft(thumb(i)),
          place(i - 1),
          reason: 'page $i steps one place back at once',
        );
      }
      await gesture.up();
      await tester.pumpAndSettle();
    });
  });
}

/// The label the screen reader hears for [f].
String semanticsOf(WidgetTester tester, Finder f) =>
    tester.getSemantics(f).label;
