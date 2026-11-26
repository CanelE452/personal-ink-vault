import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/kit/kit_icon.dart';
import 'package:saber/components/kit/kit_pill.dart';
import 'package:saber/components/kit/kit_popover.dart';
import 'package:saber/components/kit/kit_selection_bar.dart';
import 'package:saber/components/kit/kit_tokens.dart';
import 'package:saber/components/kit/kit_toolbar.dart';

const _screen = Size(400, 600);

Future<void> _pump(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = _screen;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
}

/// A small anchor placed with its top-left corner at [at].
Widget _anchorAt(GlobalKey key, Offset at, {Size size = const Size(40, 40)}) =>
    Stack(
      children: [
        Positioned(
          left: at.dx,
          top: at.dy,
          child: SizedBox(key: key, width: size.width, height: size.height),
        ),
      ],
    );

const _popKey = Key('pop');
Widget _pop(BuildContext _) =>
    const SizedBox(key: _popKey, width: 120, height: 80);

void main() {
  testWidgets('toolbar is 46 high and keeps start/middle/end order', (
    tester,
  ) async {
    await _pump(
      tester,
      Align(
        alignment: Alignment.topCenter,
        child: KitToolbar(
          start: [
            KitToolbarButton(
              key: const Key('s'),
              icon: KitIconName.home,
              tooltip: 'start',
              onPressed: () {},
            ),
          ],
          middle: [
            KitToolbarButton(
              key: const Key('m'),
              icon: KitIconName.plus,
              tooltip: 'middle',
              onPressed: () {},
            ),
            const KitToolbarDivider(),
          ],
          end: [
            KitToolbarButton(
              key: const Key('e'),
              icon: KitIconName.close,
              tooltip: 'end',
              onPressed: () {},
            ),
          ],
        ),
      ),
    );
    expect(tester.getSize(find.byType(KitToolbar)).height, 46);
    expect(tester.getSize(find.byType(KitToolbar)).width, _screen.width);
    final s = tester.getCenter(find.byKey(const Key('s'))).dx;
    final m = tester.getCenter(find.byKey(const Key('m'))).dx;
    final e = tester.getCenter(find.byKey(const Key('e'))).dx;
    expect(s < m, isTrue);
    expect(m < e, isTrue);
    expect(tester.getSize(find.byKey(const Key('s'))), const Size(34, 34));
    expect(tester.getSize(find.byType(KitToolbarDivider)), const Size(1, 22));
  });

  testWidgets('toolbar buttons tap and only the dropdown one shows a mark', (
    tester,
  ) async {
    var taps = 0;
    await _pump(
      tester,
      Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            KitToolbarButton(
              key: const Key('plain'),
              icon: KitIconName.home,
              tooltip: 'plain',
              onPressed: () => taps++,
            ),
            KitToolbarButton(
              key: const Key('dd'),
              icon: KitIconName.plus,
              tooltip: 'dd',
              dropdown: true,
              selected: true,
              onPressed: () => taps += 10,
            ),
          ],
        ),
      ),
    );
    int marks(Key k) => find
        .descendant(of: find.byKey(k), matching: find.byType(KitDropdownMark))
        .evaluate()
        .length;
    expect(marks(const Key('plain')), 0);
    expect(marks(const Key('dd')), 1);
    expect(tester.getSize(find.byKey(const Key('plain'))).width, 34);
    expect(tester.getSize(find.byKey(const Key('dd'))).width, 40);
    final mark = find.byType(KitDropdownMark);
    final opacity = tester.widget<Opacity>(
      find.descendant(of: mark, matching: find.byType(Opacity)),
    );
    expect(opacity.opacity, 0.9);
    final painter =
        tester
                .widget<CustomPaint>(
                  find.descendant(of: mark, matching: find.byType(CustomPaint)),
                )
                .painter
            as KitDropdownMarkPainter;
    expect(painter.lineWidth, 1.6);
    expect(painter.arm, 5);
    final dd = tester.getRect(find.byKey(const Key('dd')));
    expect(tester.getCenter(mark).dx - dd.left, closeTo(33, 0.5));
    final ddIcon = tester.widget<KitIcon>(
      find.descendant(
        of: find.byKey(const Key('dd')),
        matching: find.byType(KitIcon),
      ),
    );
    expect(ddIcon.size, 26);
    expect(
      tester.getCenter(find.byWidget(ddIcon)).dx - dd.left,
      closeTo(16, 0.5),
    );
    await tester.tap(find.byKey(const Key('plain')));
    await tester.tap(find.byKey(const Key('dd')));
    expect(taps, 11);
  });

  testWidgets('pill button is 32 square and dims when disabled', (
    tester,
  ) async {
    var taps = 0;
    await _pump(
      tester,
      Center(
        child: KitPill(
          children: [
            KitPillButton(
              key: const Key('on'),
              icon: KitIconName.home,
              tooltip: 'on',
              onPressed: () => taps++,
            ),
            const KitPillDivider(),
            const KitPillButton(
              key: Key('off'),
              icon: KitIconName.plus,
              tooltip: 'off',
            ),
            const KitColorDot(
              key: Key('dot'),
              color: Color(0xffff0000),
              label: 'red',
            ),
          ],
        ),
      ),
    );
    expect(tester.getSize(find.byKey(const Key('on'))), const Size(32, 32));
    expect(tester.getSize(find.byKey(const Key('off'))), const Size(32, 32));
    // 22 painted circle plus the 3 margin on each side
    expect(tester.getSize(find.byKey(const Key('dot'))), const Size(28, 22));
    expect(tester.getSize(find.byType(KitPillDivider)), const Size(1, 22));
    double opacityOf(Key k) => tester
        .widget<Opacity>(
          find.descendant(of: find.byKey(k), matching: find.byType(Opacity)),
        )
        .opacity;
    expect(opacityOf(const Key('on')), 1);
    expect(opacityOf(const Key('off')), 0.35);
    await tester.tap(find.byKey(const Key('on')));
    await tester.tap(find.byKey(const Key('off')));
    expect(taps, 1);
  });

  testWidgets('vertical pill turns the divider; color dot taps work', (
    tester,
  ) async {
    var dotTaps = 0;
    await _pump(
      tester,
      Center(
        child: KitPill(
          direction: Axis.vertical,
          children: [
            KitColorDot(
              key: const Key('dot'),
              color: const Color(0xff0000ff),
              label: 'blue',
              selected: true,
              onPressed: () => dotTaps++,
            ),
            const KitPillDivider(),
          ],
        ),
      ),
    );
    expect(tester.getSize(find.byType(KitPillDivider)), const Size(22, 1));
    await tester.tap(find.byKey(const Key('dot')));
    expect(dotTaps, 1);
  });

  testWidgets('selection bar buttons are 44 square with 26 icons', (
    tester,
  ) async {
    var taps = 0;
    await _pump(
      tester,
      Center(
        child: KitSelectionBar(
          groups: [
            [
              KitSelectionBarButton(
                key: const Key('a'),
                icon: KitIconName.home,
                tooltip: 'a',
                onPressed: () => taps++,
              ),
              const KitSelectionBarButton(
                key: Key('b'),
                icon: KitIconName.plus,
                tooltip: 'b',
                danger: true,
              ),
            ],
            [
              KitSelectionBarButton(
                key: const Key('c'),
                icon: KitIconName.close,
                tooltip: 'c',
                selected: true,
                onPressed: () {},
              ),
            ],
          ],
        ),
      ),
    );
    for (final k in ['a', 'b', 'c']) {
      expect(tester.getSize(find.byKey(Key(k))), const Size(44, 44));
      final icon = tester.widget<KitIcon>(
        find.descendant(of: find.byKey(Key(k)), matching: find.byType(KitIcon)),
      );
      expect(icon.size, 26);
      expect(icon.strokeWidth, closeTo(2.00003, 1e-4));
    }
    Color? fillOf(String k) => tester
        .widget<Material>(
          find.descendant(
            of: find.byKey(Key(k)),
            matching: find.byType(Material),
          ),
        )
        .color;
    expect(fillOf('c'), const Color(0xffe3e3e7));
    expect(fillOf('a'), Colors.transparent);
    final dividers = find.byKey(const ValueKey('kit-selection-bar-divider'));
    expect(dividers, findsOneWidget);
    expect(tester.getSize(dividers), const Size(1, 28));
    await tester.tap(find.byKey(const Key('a')));
    expect(taps, 1);
  });

  testWidgets('toolbar button icons are 26 with the 7th-draft stroke', (
    tester,
  ) async {
    await _pump(
      tester,
      Align(
        alignment: Alignment.topCenter,
        child: KitToolbar(
          start: [
            KitToolbarButton(
              key: const Key('t'),
              icon: KitIconName.home,
              tooltip: 't',
              onPressed: () {},
            ),
          ],
          middle: const [],
          end: const [],
        ),
      ),
    );
    final icon = tester.widget<KitIcon>(
      find.descendant(
        of: find.byKey(const Key('t')),
        matching: find.byType(KitIcon),
      ),
    );
    expect(icon.size, 26);
    expect(icon.strokeWidth, closeTo(1.43815, 1e-4));
  });

  testWidgets(
    'a popover opened without options keeps border and panel shadow',
    (tester) async {
      final anchor = GlobalKey();
      late BuildContext ctx;
      await _pump(
        tester,
        Builder(
          builder: (c) {
            ctx = c;
            return _anchorAt(anchor, const Offset(100, 100));
          },
        ),
      );
      unawaited(
        showKitPopover<void>(context: ctx, anchor: anchor, builder: _pop),
      );
      await tester.pumpAndSettle();
      final deco =
          tester
                  .widget<DecoratedBox>(
                    find
                        .ancestor(
                          of: find.byKey(_popKey),
                          matching: find.byType(DecoratedBox),
                        )
                        .first,
                  )
                  .decoration
              as BoxDecoration;
      expect(deco.border, Border.all(color: const Color(0xffeceef2)));
      expect(
        deco.borderRadius,
        BorderRadius.circular(KitTokens.penPanelRadius),
      );
      expect(deco.boxShadow, KitTokens.panelShadow);
    },
  );

  testWidgets('popover grows from its anchor and closes on outside tap', (
    tester,
  ) async {
    final anchor = GlobalKey();
    late BuildContext ctx;
    await _pump(
      tester,
      Builder(
        builder: (c) {
          ctx = c;
          return _anchorAt(anchor, const Offset(100, 200));
        },
      ),
    );
    var closed = false;
    unawaited(
      showKitPopover<void>(
        context: ctx,
        anchor: anchor,
        builder: _pop,
      ).then((_) => closed = true),
    );
    await tester.pumpAndSettle();
    final r = tester.getRect(find.byKey(_popKey));
    final a = tester.getRect(find.byKey(anchor));
    expect(r.top, a.bottom);
    expect(r.left, a.left);
    expect(closed, isFalse);

    // a tap inside keeps it open
    await tester.tapAt(r.center);
    await tester.pumpAndSettle();
    expect(find.byKey(_popKey), findsOneWidget);

    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.byKey(_popKey), findsNothing);
    expect(closed, isTrue);
  });

  testWidgets('popover grows up, left and right from its anchor', (
    tester,
  ) async {
    final anchor = GlobalKey();
    late BuildContext ctx;
    await _pump(
      tester,
      Builder(
        builder: (c) {
          ctx = c;
          return _anchorAt(anchor, const Offset(180, 300));
        },
      ),
    );
    final a = tester.getRect(find.byKey(anchor));
    for (final (dir, check) in <(AxisDirection, bool Function(Rect))>[
      (AxisDirection.up, (r) => r.bottom == a.top && r.left == a.left),
      (AxisDirection.right, (r) => r.left == a.right && r.top == a.top),
      (AxisDirection.left, (r) => r.right == a.left && r.top == a.top),
    ]) {
      unawaited(
        showKitPopover<void>(
          context: ctx,
          anchor: anchor,
          builder: _pop,
          grow: dir,
        ),
      );
      await tester.pumpAndSettle();
      expect(
        check(tester.getRect(find.byKey(_popKey))),
        isTrue,
        reason: '$dir',
      );
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
    }
  });

  testWidgets('popover near the right edge stays on screen', (tester) async {
    final anchor = GlobalKey();
    late BuildContext ctx;
    await _pump(
      tester,
      Builder(
        builder: (c) {
          ctx = c;
          return _anchorAt(
            anchor,
            const Offset(390, 100),
            size: const Size(8, 8),
          );
        },
      ),
    );
    unawaited(
      showKitPopover<void>(context: ctx, anchor: anchor, builder: _pop),
    );
    await tester.pumpAndSettle();
    final r = tester.getRect(find.byKey(_popKey));
    expect(r.right <= _screen.width, isTrue);
    expect(r.left >= 0, isTrue);
    expect(r.width, 120);
  });

  testWidgets('popovers stack and an outside tap closes only the top one', (
    tester,
  ) async {
    final anchor = GlobalKey();
    final inner = GlobalKey();
    late BuildContext ctx;
    await _pump(
      tester,
      Builder(
        builder: (c) {
          ctx = c;
          return _anchorAt(anchor, const Offset(60, 100));
        },
      ),
    );
    var aClosed = false;
    var bClosed = false;
    unawaited(
      showKitPopover<void>(
        context: ctx,
        anchor: anchor,
        builder: (c) => SizedBox(
          key: const Key('A'),
          width: 160,
          height: 120,
          child: Align(
            alignment: Alignment.topLeft,
            child: GestureDetector(
              key: const Key('open-b'),
              behavior: HitTestBehavior.opaque,
              onTap: () => unawaited(
                showKitPopover<void>(
                  context: c,
                  anchor: inner,
                  grow: AxisDirection.right,
                  builder: (_) =>
                      const SizedBox(key: Key('B'), width: 100, height: 60),
                ).then((_) => bClosed = true),
              ),
              child: SizedBox(key: inner, width: 30, height: 30),
            ),
          ),
        ),
      ).then((_) => aClosed = true),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('A')), findsOneWidget);
    expect(find.byKey(const Key('B')), findsNothing);

    await tester.tap(find.byKey(const Key('open-b')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('A')), findsOneWidget);
    expect(find.byKey(const Key('B')), findsOneWidget);
    final bRect = tester.getRect(find.byKey(const Key('B')));
    expect(bRect.left, tester.getRect(find.byKey(inner)).right);

    // outside both: only B goes away
    await tester.tapAt(const Offset(5, 590));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('B')), findsNothing);
    expect(find.byKey(const Key('A')), findsOneWidget);
    expect(bClosed, isTrue);
    expect(aClosed, isFalse);

    // the next outside tap closes A
    await tester.tapAt(const Offset(5, 590));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('A')), findsNothing);
    expect(aClosed, isTrue);
  });

  testWidgets('popover returns the value it was popped with', (tester) async {
    final anchor = GlobalKey();
    late BuildContext ctx;
    await _pump(
      tester,
      Builder(
        builder: (c) {
          ctx = c;
          return _anchorAt(anchor, const Offset(100, 100));
        },
      ),
    );
    int? result;
    unawaited(
      showKitPopover<int>(
        context: ctx,
        anchor: anchor,
        builder: (c) => GestureDetector(
          key: const Key('pick'),
          behavior: HitTestBehavior.opaque,
          onTap: () => Navigator.of(c).pop(7),
          child: const SizedBox(width: 50, height: 50),
        ),
      ).then((v) => result = v),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('pick')));
    await tester.pumpAndSettle();
    expect(result, 7);
  });

  testWidgets('color dot is named, shows its chosen state, and rings do not '
      'touch the next dot', (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(
      tester,
      Center(
        child: KitPill(
          children: [
            KitColorDot(
              key: const Key('d1'),
              color: const Color(0xffff0000),
              label: 'Red',
              selected: true,
              onPressed: () {},
            ),
            KitColorDot(
              key: const Key('d2'),
              color: const Color(0xff00ff00),
              label: 'Green',
              onPressed: () {},
            ),
          ],
        ),
      ),
    );
    final red = tester.getSemantics(find.byKey(const Key('d1')));
    expect(red.label, 'Red');
    expect(red.flagsCollection.isSelected.toBoolOrNull(), isTrue);
    expect(red.flagsCollection.isButton, isTrue);
    final green = tester.getSemantics(find.byKey(const Key('d2')));
    expect(green.label, 'Green');
    expect(green.flagsCollection.isSelected.toBoolOrNull(), isFalse);

    Rect circle(String k) => tester.getRect(
      find.descendant(of: find.byKey(Key(k)), matching: find.byType(Container)),
    );
    final ring = circle('d1')
        .inflate(KitTokens.colorDotRingGap + KitTokens.colorDotRingWidth);
    expect(ring.overlaps(circle('d2')), isFalse);
    handle.dispose();
  });

  testWidgets('the chosen colour dot shows the gap inside its ring', (
    tester,
  ) async {
    // `.fbar .cd.on` 0 0 0 3px pill, 0 0 0 6px ring: shadows are painted in
    // list order, so the ring must come first or it hides the gap
    await _pump(
      tester,
      Center(
        child: KitPill(
          children: [
            KitColorDot(
              key: const Key('d1'),
              color: const Color(0xffff0000),
              label: 'Red',
              selected: true,
              onPressed: () {},
            ),
            KitColorDot(
              key: const Key('d2'),
              color: const Color(0xff00ff00),
              label: 'Green',
              onPressed: () {},
            ),
          ],
        ),
      ),
    );
    BoxDecoration decoOf(String k) =>
        tester
                .widget<Container>(
                  find.descendant(
                    of: find.byKey(Key(k)),
                    matching: find.byType(Container),
                  ),
                )
                .decoration!
            as BoxDecoration;
    final deco = decoOf('d1');
    final rings = deco.boxShadow!;
    // the ring is #dcdce1 (task-12-values.md line 55)
    expect(rings.first.color, const Color(0xffdcdce1));
    expect(
      rings.first.spreadRadius,
      KitTokens.colorDotRingGap + KitTokens.colorDotRingWidth,
    );
    expect(rings.last.color, KitTokens.pillBg);
    expect(rings.last.spreadRadius, KitTokens.colorDotRingGap);
    // the rings replace the dot's thin inside line; a dot not chosen keeps
    // it (`inset 0 0 0 1px rgba(0,0,0,.12)`, line 54)
    expect(deco.border, isNull);
    expect(decoOf('d2').boxShadow, isNull);
    expect(decoOf('d2').border, Border.all(color: const Color(0x1f000000)));
  });

  testWidgets('popover follows its anchor when the screen size changes', (
    tester,
  ) async {
    final anchor = GlobalKey();
    late BuildContext ctx;
    await _pump(
      tester,
      Builder(
        builder: (c) {
          ctx = c;
          return Align(
            alignment: Alignment.bottomCenter,
            child: SizedBox(key: anchor, width: 40, height: 40),
          );
        },
      ),
    );
    unawaited(
      showKitPopover<void>(
        context: ctx,
        anchor: anchor,
        builder: _pop,
        grow: AxisDirection.up,
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.getRect(find.byKey(_popKey)).bottom,
      tester.getRect(find.byKey(anchor)).top,
    );
    final before = tester.getRect(find.byKey(anchor)).top;

    tester.view.physicalSize = const Size(500, 400);
    await tester.pumpAndSettle();
    final after = tester.getRect(find.byKey(anchor));
    expect(after.top == before, isFalse);
    final r = tester.getRect(find.byKey(_popKey));
    expect(r.bottom, after.top);
    expect(r.left, after.left);
  });

  testWidgets('screen reader tap runs the callback on dot and buttons', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    var dot = 0;
    var pill = 0;
    var tool = 0;
    var sel = 0;
    await _pump(
      tester,
      Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            KitPill(
              children: [
                KitColorDot(
                  key: const Key('dot'),
                  color: const Color(0xffff0000),
                  label: 'Red',
                  onPressed: () => dot++,
                ),
                KitPillButton(
                  key: const Key('pill'),
                  icon: KitIconName.home,
                  tooltip: 'Pill',
                  onPressed: () => pill++,
                ),
              ],
            ),
            KitToolbarButton(
              key: const Key('tool'),
              icon: KitIconName.plus,
              tooltip: 'Tool',
              onPressed: () => tool++,
            ),
            KitSelectionBarButton(
              key: const Key('sel'),
              icon: KitIconName.close,
              tooltip: 'Sel',
              onPressed: () => sel++,
            ),
            const KitPillButton(
              key: Key('off'),
              icon: KitIconName.home,
              tooltip: 'Off',
            ),
          ],
        ),
      ),
    );
    for (final k in ['dot', 'pill', 'tool', 'sel']) {
      final node = tester.getSemantics(find.byKey(Key(k)));
      expect(
        node.getSemanticsData().hasAction(SemanticsAction.tap),
        isTrue,
        reason: k,
      );
      tester.semantics.tap(find.semantics.byLabel(RegExp(node.label)));
    }
    expect([dot, pill, tool, sel], [1, 1, 1, 1]);
    final off = tester.getSemantics(find.byKey(const Key('off')));
    expect(off.getSemanticsData().hasAction(SemanticsAction.tap), isFalse);
    handle.dispose();
  });
}
