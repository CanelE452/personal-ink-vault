import 'package:flex_color_picker/flex_color_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/ink_ui/pen_panel/kit_pen_panel.dart';
import 'package:saber/components/kit/kit_icon.dart';
import 'package:saber/components/kit/kit_motion.dart';
import 'package:saber/components/kit/kit_pen_art.dart';
import 'package:saber/data/actions/app_action.dart';
import 'package:saber/data/actions/app_action_ids.dart';
import 'package:saber/data/actions/app_action_registry.dart';
import 'package:saber/data/extensions/color_extensions.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/tools/pen.dart';

import 'pen_panel_harness.dart';

const _red = Color(0xffe5323e);
const _blue = Color(0xff2f9bf0);
const _black = Color(0xff1f2023);
const _pastelRed = Color(0xffffadad);
const _grey = Color(0xff9e9e9e);
const _darkGrey = Color(0xff424242);
const _pureBlack = Color(0xff000000);
const _navy = Color(0xff24304a);
const _sky = Color(0xffa0c4ff);

/// The palette (「색 만들기」) mark: the colour wheel.
final _palette = find.byWidgetPredicate(
  (w) =>
      w is DecoratedBox &&
      w.decoration is BoxDecoration &&
      (w.decoration as BoxDecoration).gradient is SweepGradient,
);

Future<PanelHost> _openWith(
  WidgetTester tester,
  Color ink, {
  Brightness brightness = Brightness.light,
  AppActionRegistry? actions,
}) async {
  final pen = Pen.fountainPen()..color = ink;
  Pen.currentPen = pen;
  final host = await pumpHost(tester, pen, brightness: brightness);
  await openPanel(tester, host, actions: actions);
  return host;
}

/// Taps page dot [i] at its middle. The dots' wider tap zone lies over them
/// (kit_swatches.dart, the `pageDotHitZone` box) and takes the tap there, so
/// the dot itself is never the one hit: tap() would warn about that.
Future<void> tapDot(WidgetTester tester, int i) =>
    tester.tap(pageDot(i), warnIfMissed: false);

int _dots(WidgetTester tester) {
  var n = 0;
  while (pageDot(n).evaluate().isNotEmpty) {
    n++;
  }
  return n;
}

bool _ringed(WidgetTester tester, Color c) =>
    (tester.widget<DecoratedBox>(swatchDot(c)).decoration as BoxDecoration)
        .boxShadow !=
    null;

void main() {
  FlavorConfig.setup();
  tearDown(resetPenPanelState);

  testWidgets('dark ink shows inverted and stores the raw colour', (
    tester,
  ) async {
    stows.editorAutoInvert.value = true;
    const ink = Color(0xff2f55d4);
    final host = await _openWith(tester, ink, brightness: Brightness.dark);
    // the pen and its sample are drawn in the ink as the page shows it
    final art = tester.widget<KitPenArt>(
      find
          .descendant(
            of: penColumn(KitPenKind.fountain),
            matching: find.byType(KitPenArt),
          )
          .first,
    );
    expect(art.ink, ink.withInversion());
    expect(penSample(tester).ink, ink.withInversion());
    // a swatch is painted inverted, and picking it gives the raw colour
    final shown = _red.withInversion();
    expect(swatch(_red), findsNothing);
    expect(swatch(shown), findsOneWidget);
    expect(
      (tester.widget<DecoratedBox>(swatchDot(shown)).decoration
              as BoxDecoration)
          .color,
      shown,
    );
    await tester.tap(swatch(shown));
    await tester.pump();
    expect(host.colors, [_red]);
    // without the editor's invert the dark theme shows the colours as they are
    await closePanel(tester);
    stows.editorAutoInvert.value = false;
    await openPanel(tester, host);
    expect(swatch(_red), findsOneWidget);
  });

  testWidgets('opening the panel keeps the pen colour', (tester) async {
    // a colour is only set when one is pressed; the ring may stand on a
    // nearby grey, the pen keeps its own
    final host = await _openWith(tester, _pureBlack);
    final pen = host.tool as Pen;
    expect(host.colors, isEmpty);
    expect(pen.color, _pureBlack);
    await tapDot(tester, 2);
    await tester.pumpAndSettle();
    await closePanel(tester);
    expect(host.colors, isEmpty);
    expect(pen.color, _pureBlack);
    expect(
      stows.lastFountainPenColor.value,
      stows.lastFountainPenColor.defaultValue,
    );
  });

  testWidgets('no eyedropper button without the action', (tester) async {
    final host = await _openWith(tester, _red);
    expect(iconNamed(KitIconName.eyedrop), findsNothing);
    // the palette is always there, and so are the dots of the three colour
    // pages that are never empty
    expect(_palette, findsOneWidget);
    expect(_dots(tester), 3);
    // a registry without the action shows no button either
    await closePanel(tester);
    final empty = AppActionRegistry();
    addTearDown(empty.dispose);
    await openPanel(tester, host, actions: empty);
    expect(iconNamed(KitIconName.eyedrop), findsNothing);
    expect(_palette, findsOneWidget);
  });

  testWidgets('eyedropper closes the panel and runs the action', (
    tester,
  ) async {
    BuildContext? given;
    var mountedThen = false;
    var navigatorThen = false;
    final acts = AppActionRegistry();
    addTearDown(acts.dispose);
    acts.publish(Object(), [
      AppAction(
        id: AppActionIds.eyedropper,
        label: '스포이트',
        icon: KitIconName.eyedrop,
        run: (context) {
          given = context;
          mountedThen = context.mounted;
          navigatorThen = Navigator.maybeOf(context) != null;
        },
      ),
    ]);
    final host = await _openWith(tester, _red, actions: acts);
    final eye = iconNamed(KitIconName.eyedrop);
    expect(eye, findsOneWidget);
    // after the colours: the eyedropper, then the palette, 4 apart; under
    // the pen's 수평/수직 row (Task 13: every ink pen has it)
    final panel = tester.getRect(find.byKey(const ValueKey('kit-pen-panel')));
    final down = tester
        .getSize(find.byKey(const ValueKey('tool-panel-axis-lock')))
        .height;
    expect(tester.getTopLeft(eye) - panel.topLeft, Offset(237, 281 + down));
    expect(tester.getTopLeft(_palette) - panel.topLeft, Offset(263, 281 + down));
    await tester.tap(eye);
    await tester.pumpAndSettle();
    expect(find.byType(KitPenPanel), findsNothing);
    // it ran after the panel closed, with a context that outlives the panel
    expect(given, isNotNull);
    expect(mountedThen, isTrue);
    expect(navigatorThen, isTrue);
    expect(given!.mounted, isTrue);
    expect(host.colors, isEmpty);
    expect(host.tools, isEmpty);
  });

  testWidgets('page dots page through the colours', (tester) async {
    await _openWith(tester, _red);
    // empty recent and pinned pages are hidden with their dots
    expect(_dots(tester), 3);
    expect(find.text('기본 색'), findsOneWidget);
    expect(swatch(_red), findsOneWidget);
    await tapDot(tester, 1);
    await tester.pumpAndSettle();
    expect(swatch(_pastelRed), findsOneWidget);
    expect(swatch(_red), findsNothing);
    expect(find.text('파스텔'), findsOneWidget);
    await tapDot(tester, 2);
    await tester.pumpAndSettle();
    expect(swatch(_grey), findsOneWidget);
    expect(find.text('회색조'), findsOneWidget);
    await closePanel(tester);
    // recent and pinned colours bring their pages
    stows.recentColorsPositioned.value = [colourString(_navy)];
    stows.pinnedColors.value = [colourString(_sky)];
    await _openWith(tester, _red);
    expect(_dots(tester), 5);
    await tapDot(tester, 3);
    await tester.pumpAndSettle();
    expect(swatch(_navy), findsOneWidget);
    expect(find.text('최근 색'), findsOneWidget);
    await tapDot(tester, 4);
    await tester.pumpAndSettle();
    expect(swatch(_sky), findsOneWidget);
    expect(find.text('고정한 색'), findsOneWidget);
    // sideways drags turn the pages too
    await tester.drag(swatch(_sky), const Offset(250, 0));
    await tester.pumpAndSettle();
    expect(swatch(_navy), findsOneWidget);
  });

  testWidgets('more than eight recent colours make two named pages', (
    tester,
  ) async {
    stows.recentColorsLength.value = 10;
    addTearDown(() {
      // empty the lists first: a shorter length trims them through
      // the chronological list
      stows.recentColorsPositioned.value =
          stows.recentColorsPositioned.defaultValue;
      stows.recentColorsChronological.value =
          stows.recentColorsChronological.defaultValue;
      stows.recentColorsLength.value = stows.recentColorsLength.defaultValue;
    });
    stows.recentColorsPositioned.value = [
      for (var i = 0; i < 10; i++) colourString(Color(0xff102030 + i * 0x10)),
    ];
    await _openWith(tester, _red);
    expect(_dots(tester), 5);
    await tapDot(tester, 3);
    await tester.pumpAndSettle();
    expect(find.text('최근 색 1/2'), findsOneWidget);
    expect(swatch(const Color(0xff102030)), findsOneWidget);
    expect(swatch(const Color(0xff1020a0)), findsOneWidget);
    await tapDot(tester, 4);
    await tester.pumpAndSettle();
    expect(find.text('최근 색 2/2'), findsOneWidget);
    expect(swatch(const Color(0xff1020b0)), findsOneWidget);
    expect(swatch(const Color(0xff1020c0)), findsOneWidget);
  });

  testWidgets('long press pins and unpins a colour', (tester) async {
    final handle = tester.ensureSemantics();
    await _openWith(tester, _red);
    await tester.longPress(swatch(_blue));
    await tester.pumpAndSettle();
    expect(stows.pinnedColors.value, [colourString(_blue)]);
    expect(find.byKey(const Key('kit-swatch-pin-ff2f9bf0')), findsOneWidget);
    expect(tester.getSemantics(swatch(_blue)).label, '색 5, 고정함');
    // the pinned page appears with its dot
    expect(_dots(tester), 4);
    await tester.longPress(swatch(_blue));
    await tester.pumpAndSettle();
    expect(stows.pinnedColors.value, isEmpty);
    expect(find.byKey(const Key('kit-swatch-pin-ff2f9bf0')), findsNothing);
    // like the old colour bar: an unpinned colour goes back to the recent ones
    expect(stows.recentColorsPositioned.value, [colourString(_blue)]);
    expect(_dots(tester), 4);
    // pinning a recent colour takes it out of the recent ones
    await tapDot(tester, 3);
    await tester.pumpAndSettle();
    await tester.longPress(swatch(_blue));
    await tester.pumpAndSettle();
    expect(stows.pinnedColors.value, [colourString(_blue)]);
    expect(stows.recentColorsPositioned.value, isEmpty);
    expect(stows.recentColorsChronological.value, isEmpty);
    // eight pins fill the pinned page (`cpPin`: up to 8); one more says so
    // in the page name's place for a moment (preview `cpNote`)
    stows.pinnedColors.value = [
      for (var i = 0; i < 8; i++) colourString(Color(0xff101010 + i)),
    ];
    await tester.pumpAndSettle();
    await tapDot(tester, 0);
    await tester.pumpAndSettle();
    await tester.longPress(swatch(_red));
    await tester.pump();
    expect(stows.pinnedColors.value, hasLength(8));
    expect(stows.pinnedColors.value, isNot(contains(colourString(_red))));
    expect(find.text('고정은 8개까지'), findsOneWidget);
    expect(find.text('기본 색'), findsNothing);
    await tester.pump(KitMotion.noteShow);
    await tester.pump();
    expect(find.text('고정은 8개까지'), findsNothing);
    expect(find.text('기본 색'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('a basic colour unpinned stays out of the recent ones', (
    tester,
  ) async {
    // 「기본 색은 최근 색에 넣지 않기」 keeps the basic page's colours out
    stows.recentColorsDontSavePresets.value = true;
    addTearDown(
      () => stows.recentColorsDontSavePresets.value =
          stows.recentColorsDontSavePresets.defaultValue,
    );
    stows.pinnedColors.value = [colourString(_blue), colourString(_navy)];
    await _openWith(tester, _red);
    await tester.longPress(swatch(_blue));
    await tester.pumpAndSettle();
    expect(stows.pinnedColors.value, [colourString(_navy)]);
    expect(stows.recentColorsPositioned.value, isEmpty);
    // a colour of no basic page still goes back
    await tapDot(tester, 3);
    await tester.pumpAndSettle();
    await tester.longPress(swatch(_navy));
    await tester.pumpAndSettle();
    expect(stows.pinnedColors.value, isEmpty);
    expect(stows.recentColorsPositioned.value, [colourString(_navy)]);
  });

  // Task 19 fix 1 ruling: the setting's 「기본 색」 is the first page only
  testWidgets('a pastel colour unpinned goes back to the recent ones', (
    tester,
  ) async {
    stows.recentColorsDontSavePresets.value = true;
    addTearDown(
      () => stows.recentColorsDontSavePresets.value =
          stows.recentColorsDontSavePresets.defaultValue,
    );
    stows.pinnedColors.value = [colourString(_pastelRed)];
    await _openWith(tester, _red);
    await tapDot(tester, 1);
    await tester.pumpAndSettle();
    await tester.longPress(swatch(_pastelRed));
    await tester.pumpAndSettle();
    expect(stows.pinnedColors.value, isEmpty);
    expect(stows.recentColorsPositioned.value, [colourString(_pastelRed)]);
  });

  testWidgets('the recent page tells how to pin until a colour is pinned', (
    tester,
  ) async {
    stows.recentColorsPositioned.value = [colourString(_navy)];
    await _openWith(tester, _red);
    expect(find.text('길게 눌러 고정'), findsNothing);
    await tapDot(tester, 3);
    await tester.pumpAndSettle();
    expect(find.text('길게 눌러 고정'), findsOneWidget);
    await tester.longPress(swatch(_navy));
    await tester.pumpAndSettle();
    expect(find.text('길게 눌러 고정'), findsNothing);
  });

  testWidgets('swatches are read by their place', (tester) async {
    final handle = tester.ensureSemantics();
    await _openWith(tester, _red);
    expect(tester.getSemantics(swatch(_red)).label, '색 1');
    expect(tester.getSemantics(swatch(_black)).label, '색 8');
    handle.dispose();
  });

  testWidgets('the palette opens the colour wheel and keeps the raw colour', (
    tester,
  ) async {
    const made = Color(0xff3a7d44);
    for (final dark in [false, true]) {
      stows.editorAutoInvert.value = true;
      final host = await _openWith(
        tester,
        _red,
        brightness: dark ? Brightness.dark : Brightness.light,
      );
      await tester.tap(_palette);
      await tester.pumpAndSettle();
      final wheel = tester.widget<ColorPicker>(find.byType(ColorPicker));
      // it opens on the colour as the page shows it
      expect(wheel.color, _red.withInversion(dark));
      wheel.onColorChanged(made.withInversion(dark));
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      // and keeps the colour itself
      expect(host.colors.single.toARGB32(), made.toARGB32(), reason: '$dark');
      await closePanel(tester);
    }
  });

  testWidgets('the colour row opens on the page of the current colour', (
    tester,
  ) async {
    Future<void> check(Color ink, String page) async {
      await _openWith(tester, ink);
      expect(find.text(page), findsOneWidget, reason: '$ink');
      await closePanel(tester);
    }

    await check(_red, '기본 색');
    await check(_pastelRed, '파스텔');
    await check(_grey, '회색조');
    await check(_darkGrey, '회색조');
    // black and the basic page's black are one colour here (design I-3)
    await check(_pureBlack, '기본 색');
    // a colour on no page opens the basic colours
    await check(const Color(0xff123456), '기본 색');
    // a colour found only among the recent ones (the eyedropper's, a made
    // colour) opens the recent page
    stows.recentColorsPositioned.value = [colourString(_navy)];
    await check(_navy, '최근 색');
    // greyscale first: only a colour on no page opens the greys; the page
    // that shows the current colour comes first
    stows.preferGreyscale.value = true;
    await check(_navy, '최근 색');
    await check(_red, '기본 색');
    await check(const Color(0xff123456), '회색조');
  });

  testWidgets('a nearby grey carries the ring, each page its own', (
    tester,
  ) async {
    await _openWith(tester, _pureBlack);
    expect(find.text('기본 색'), findsOneWidget);
    expect(_ringed(tester, _black), isTrue);
    expect(_ringed(tester, _red), isFalse);
    await tapDot(tester, 2);
    await tester.pumpAndSettle();
    // the grey page holds black itself: the ring goes there, not to #424242
    expect(_ringed(tester, _pureBlack), isTrue);
    expect(_ringed(tester, _darkGrey), isFalse);
  });
}
