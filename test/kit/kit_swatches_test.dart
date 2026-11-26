import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/kit/kit_icon.dart';
import 'package:saber/components/kit/kit_swatches.dart';
import 'package:saber/components/kit/kit_tokens.dart';

const _screen = Size(400, 600);

void _size(WidgetTester tester) {
  tester.view.physicalSize = _screen;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Finder _iconNamed(KitIconName n) =>
    find.byWidgetPredicate((w) => w is KitIcon && w.name == n);

Finder _key(Color c) =>
    find.byKey(Key('kit-swatch-${c.toARGB32().toRadixString(16)}'));

/// The colour dot inside a swatch.
Finder _dot(Color c) =>
    find.descendant(of: _key(c), matching: find.byType(DecoratedBox)).first;

final _palette = find.byWidgetPredicate(
  (w) =>
      w is DecoratedBox &&
      w.decoration is BoxDecoration &&
      (w.decoration as BoxDecoration).gradient is SweepGradient,
);

/// KitSwatches 270 wide at (15, 40), the pen panel's colour row.
Future<void> _row(WidgetTester tester, Widget swatches) async {
  _size(tester);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: Padding(
            padding: const EdgeInsets.only(left: 15, top: 40),
            child: SizedBox(width: 270, child: swatches),
          ),
        ),
      ),
    ),
  );
}

const _eight = [
  Color(0xffe5323e),
  Color(0xffffc83d),
  Color(0xfff7e43a),
  Color(0xff2ccfc4),
  Color(0xff2f9bf0),
  Color(0xff2f55d4),
  Color(0xff8a3ee6),
  Color(0xff1f2023),
];

void main() {
  testWidgets(
    'swatch pages can differ in size, hide dots for one page, and long press reports the colour',
    (tester) async {
      const red = Color(0xffff0000);
      const green = Color(0xff00ff00);
      const blue = Color(0xff0000ff);
      const grey = Color(0xff888888);
      final picked = <Color>[];
      final held = <Color>[];
      Color? selected;
      var eye = 0;
      Future<void> pump(List<List<Color>> pages, {bool tools = true}) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 300,
                  child: StatefulBuilder(
                    builder: (context, setState) => KitSwatches(
                      pages: pages,
                      selected: selected,
                      onSelected: (c) {
                        picked.add(c);
                        setState(() => selected = c);
                      },
                      onLongPressColor: held.add,
                      onEyedropper: tools ? () => eye++ : null,
                      onPalette: tools ? () {} : null,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      }

      await pump([
        [red, green, blue],
        [grey],
      ]);
      expect(find.byKey(const Key('kit-swatch-page-dot-0')), findsOneWidget);
      expect(find.byKey(const Key('kit-swatch-page-dot-1')), findsOneWidget);
      expect(_key(green), findsOneWidget);
      expect(_key(grey), findsNothing);

      await tester.tap(_key(green));
      await tester.pumpAndSettle();
      expect(picked, [green]);

      await tester.longPress(_key(red));
      await tester.pumpAndSettle();
      expect(held, [red]);

      final eyeIcon = tester.widget<KitIcon>(_iconNamed(KitIconName.eyedrop));
      expect(eyeIcon.size, KitTokens.penPanelIconSize);
      expect(eyeIcon.strokeWidth, KitTokens.penPanelIconStroke);
      await tester.tap(_iconNamed(KitIconName.eyedrop));
      expect(eye, 1);

      // the second page has one colour; tapping its dot brings it in
      await tester.tap(find.byKey(const Key('kit-swatch-page-dot-1')));
      await tester.pumpAndSettle();
      expect(_key(grey), findsOneWidget);
      expect(_key(red), findsNothing);

      // swiping sideways turns back
      await tester.drag(_key(grey), const Offset(250, 0));
      await tester.pumpAndSettle();
      expect(_key(red), findsOneWidget);

      // one page: no dots; no tool callbacks: no tool buttons
      await pump([
        [red, green],
      ], tools: false);
      expect(find.byKey(const Key('kit-swatch-page-dot-0')), findsNothing);
      expect(_iconNamed(KitIconName.eyedrop), findsNothing);
      expect(_iconNamed(KitIconName.custom), findsNothing);
    },
  );

  testWidgets('swatch row lays out like the preview pen panel', (tester) async {
    // Preview `.snp .sncolors` (lines 589-602): eight 22 dots 28 apart from
    // the left edge of the 270 wide content. The eyedropper and the palette
    // follow 4 apart (design review M-6: the preview's 6 made the row 274),
    // so the palette ends on the content edge.
    await _row(
      tester,
      KitSwatches(
        pages: const [
          _eight,
          [Color(0xff9e9e9e)],
        ],
        selected: _eight.first,
        onSelected: (_) {},
        onEyedropper: () {},
        onPalette: () {},
      ),
    );
    expect(tester.takeException(), isNull);
    for (final (i, c) in _eight.indexed) {
      expect(
        tester.getRect(_dot(c)),
        Rect.fromLTWH(15.0 + 28 * i, 52, 22, 22),
        reason: '$i',
      );
    }
    expect(
      tester.getTopLeft(_iconNamed(KitIconName.eyedrop)),
      const Offset(15 + 222, 52),
    );
    expect(tester.getRect(_palette), const Rect.fromLTWH(15 + 248, 52, 22, 22));
    expect(tester.getRect(_palette).right, 15 + 270);
    // the page dots: 11 apart (`.snp .pdots button` 11 x 22, line 604),
    // centred under the row, the dot 13 below it
    final d0 = tester.getRect(find.byKey(const Key('kit-swatch-page-dot-0')));
    final d1 = tester.getRect(find.byKey(const Key('kit-swatch-page-dot-1')));
    expect(d0.size, const Size(11, 22));
    expect(d1.left - d0.left, 11);
    expect((d0.left + d1.right) / 2, 15 + 135);
    expect(d0.center.dy, 40 + 46 + 13 + 2.5);
  });

  testWidgets('the palette wheel starts with red at the top', (tester) async {
    // CSS conic-gradient starts at 12 o'clock, a sweep gradient at 3 o'clock
    await _row(
      tester,
      KitSwatches(
        pages: const [_eight],
        selected: null,
        onSelected: (_) {},
        onPalette: () {},
      ),
    );
    final wheel =
        (tester.widget<DecoratedBox>(_palette).decoration as BoxDecoration)
                .gradient!
            as SweepGradient;
    expect(wheel.colors.first, KitTokens.swatchPaletteColors.first);
    expect(wheel.transform, isA<GradientRotation>());
    expect((wheel.transform! as GradientRotation).radians, -math.pi / 2);
    // the one wheel the floating bar's 「색 만들기」 draws too (values §13)
    expect(wheel, same(kitColourWheel));
  });

  testWidgets(
    'swatches open on a given page, name it and mark pinned and light colours',
    (tester) async {
      const red = Color(0xffe5323e);
      const white = Color(0xffffffff);
      const grey = Color(0xff9e9e9e);
      const black = Color(0xff1f2023);
      _size(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 270,
                child: KitSwatches(
                  pages: const [
                    [red],
                    [grey, white, black],
                  ],
                  pageNames: const ['기본 색', '회색조'],
                  initialPage: 1,
                  pinned: {grey, black},
                  selected: grey,
                  onSelected: (_) {},
                ),
              ),
            ),
          ),
        ),
      );
      BoxDecoration deco(Color c) =>
          tester.widget<DecoratedBox>(_dot(c)).decoration as BoxDecoration;
      expect(_key(red), findsNothing);
      expect(_key(grey), findsOneWidget);
      // the page's name at the left of the dots (`.pname`, line 607)
      final name = find.text('회색조');
      expect(name, findsOneWidget);
      expect(tester.widget<Text>(name).style?.fontSize, 11);
      expect(tester.getTopLeft(name).dx, 4);
      // a light colour has a thin edge (`.lt`, line 600), others none
      expect(deco(white).border, isNotNull);
      expect(deco(grey).border, isNull);
      // the chosen ring: grey outside, the white gap drawn over it
      final ring = deco(grey).boxShadow!;
      expect(ring.first.color, KitTokens.swatchRing);
      expect(ring.first.spreadRadius, 3.5);
      expect(ring.last.color, KitTokens.swatchRingGapColor);
      expect(ring.last.spreadRadius, 2);
      // the pinned badge sits on the top right of the dot (line 602); on a
      // dark colour its white ring is wider (design review M-4)
      final badge = find.byKey(const Key('kit-swatch-pin-ff9e9e9e'));
      expect(badge, findsOneWidget);
      final dotRect = tester.getRect(_dot(grey));
      expect(
        tester.getRect(badge),
        Rect.fromLTWH(dotRect.right - 4, dotRect.top - 3, 7, 7),
      );
      double badgeRing(String hex) =>
          ((tester
                          .widget<DecoratedBox>(
                            find
                                .descendant(
                                  of: find.byKey(Key('kit-swatch-pin-$hex')),
                                  matching: find.byType(DecoratedBox),
                                )
                                .first,
                          )
                          .decoration
                      as BoxDecoration)
                  .boxShadow!
                  .single)
              .spreadRadius;
      expect(badgeRing('ff9e9e9e'), KitTokens.swatchPinRing);
      expect(badgeRing('ff1f2023'), KitTokens.swatchPinRingDark);
      expect(find.byKey(const Key('kit-swatch-pin-ffffffff')), findsNothing);
      // turning to the first page changes the name
      await tester.tap(find.byKey(const Key('kit-swatch-page-dot-0')));
      await tester.pumpAndSettle();
      expect(find.text('기본 색'), findsOneWidget);
      expect(_key(red), findsOneWidget);
    },
  );

  testWidgets('page dots answer within 22 of them and keep their look', (
    tester,
  ) async {
    // design review M-8 and code review M7: the dots stay 5 wide and 11
    // apart; a press up to 22 above, below or past the end dots still counts,
    // the nearest dot wins
    await _row(
      tester,
      KitSwatches(
        pages: const [
          [Color(0xffff0000)],
          [Color(0xff00ff00)],
          [Color(0xff0000ff)],
        ],
        selected: null,
        onSelected: (_) {},
      ),
    );
    Offset centre(int i) =>
        tester.getCenter(find.byKey(Key('kit-swatch-page-dot-$i')));
    Future<void> tapAt(Offset at) async {
      await tester.tapAt(at);
      await tester.pumpAndSettle();
    }

    expect(centre(1).dx - centre(0).dx, 11);
    await tapAt(centre(2) + const Offset(20, 0));
    expect(_key(const Color(0xff0000ff)), findsOneWidget);
    await tapAt(centre(0) + const Offset(-20, 20));
    expect(_key(const Color(0xffff0000)), findsOneWidget);
    await tapAt(centre(1) + const Offset(4, -20));
    expect(_key(const Color(0xff00ff00)), findsOneWidget);
    // a tap on the colour row above is still a colour, not a page
    await tapAt(centre(0) + const Offset(0, -30));
    expect(_key(const Color(0xff00ff00)), findsOneWidget);
  });

  testWidgets('a note takes the name place and a hint sits at the right', (
    tester,
  ) async {
    Widget swatches({String? note}) => KitSwatches(
      pages: const [
        [Color(0xffff0000)],
        [Color(0xff00ff00)],
      ],
      pageNames: const ['기본 색', '최근 색'],
      pageHints: const [null, '길게 눌러 고정'],
      note: note,
      selected: null,
      onSelected: (_) {},
    );
    await _row(tester, swatches());
    expect(find.text('기본 색'), findsOneWidget);
    expect(find.text('길게 눌러 고정'), findsNothing);
    await tester.tap(find.byKey(const Key('kit-swatch-page-dot-1')));
    await tester.pumpAndSettle();
    final hint = find.text('길게 눌러 고정');
    expect(hint, findsOneWidget);
    expect(tester.getTopRight(hint).dx, 15 + 270 - KitTokens.pageNameInset);
    await _row(tester, swatches(note: '고정은 8개까지'));
    expect(find.text('고정은 8개까지'), findsOneWidget);
    expect(find.text('최근 색'), findsNothing);
    expect(tester.getTopLeft(find.text('고정은 8개까지')).dx, 15 + 4);
  });

  testWidgets('swatches take their names and may ring more than one dot', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    const red = Color(0xffff0000);
    const green = Color(0xff00ff00);
    await _row(
      tester,
      KitSwatches(
        pages: const [
          [red, green],
        ],
        selected: null,
        isSelected: (page, c) => true,
        colourLabel: (page, index, colour) => '색 ${index + 1}',
        pinned: {green},
        onSelected: (_) {},
      ),
    );
    expect(tester.getSemantics(_key(red)).label, '색 1');
    expect(tester.getSemantics(_key(green)).label, '색 2, 고정함');
    expect(
      (tester.widget<DecoratedBox>(_dot(red)).decoration as BoxDecoration)
          .boxShadow,
      isNotNull,
    );
    expect(
      (tester.widget<DecoratedBox>(_dot(green)).decoration as BoxDecoration)
          .boxShadow,
      isNotNull,
    );
    handle.dispose();
  });

  testWidgets('swatch marks the chosen colour', (tester) async {
    final handle = tester.ensureSemantics();
    const red = Color(0xffff0000);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 300,
            child: KitSwatches(
              pages: const [
                [red, Color(0xff00ff00)],
              ],
              selected: red,
              onSelected: (_) {},
            ),
          ),
        ),
      ),
    );
    bool? isSelected(String key) => tester
        .getSemantics(find.byKey(Key(key)))
        .getSemanticsData()
        .flagsCollection
        .isSelected
        .toBoolOrNull();
    expect(isSelected('kit-swatch-ffff0000'), isTrue);
    expect(isSelected('kit-swatch-ff00ff00'), isFalse);
    handle.dispose();
  });
}
