import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/ink_ui/hover_badge.dart';
import 'package:saber/components/kit/kit_icon.dart';

/// The preview's page (1구역 편집기, `.page` 586 x 734).
const _page = Size(586, 734);

/// A strip over the foot of the page that the pen can hover onto (as it
/// can onto the floating bar).
const _strip = Rect.fromLTWH(0, 690, 586, 44);

final _badge = find.byKey(const ValueKey('kit-hover-badge'));
final _dot = find.byKey(const ValueKey('kit-hover-dot'));

/// The badge's icon now.
KitIconName _icon(WidgetTester tester) => tester
    .widget<KitIcon>(
      find.descendant(of: _badge, matching: find.byType(KitIcon)),
    )
    .name;

/// The page heard by a [HoverBadgeListener], the strip, the badge layer
/// over both. Returns how many taps the page took.
Future<ValueNotifier<int>> _pump(
  WidgetTester tester, {
  KitIconName icon = KitIconName.pen,
}) async {
  tester.view.physicalSize = _page;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final controller = HoverBadgeController();
  addTearDown(controller.dispose);
  final taps = ValueNotifier(0);
  addTearDown(taps.dispose);
  await tester.pumpWidget(
    MediaQuery(
      data: const MediaQueryData(size: _page),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Stack(
          children: [
            Positioned.fill(
              child: HoverBadgeListener(
                controller: controller,
                child: GestureDetector(
                  onTap: () => taps.value++,
                  child: const ColoredBox(color: Color(0xfffbf8ef)),
                ),
              ),
            ),
            Positioned.fromRect(
              rect: _strip,
              child: const ColoredBox(color: Color(0xfff2f2f4)),
            ),
            Positioned.fill(
              child: KitHoverBadge(controller: controller, toolIcon: icon),
            ),
          ],
        ),
      ),
    ),
  );
  return taps;
}

/// A pen hovering at [at] (it comes in range a little away first).
Future<TestGesture> _hover(
  WidgetTester tester,
  Offset at, {
  PointerDeviceKind kind = PointerDeviceKind.stylus,
}) async {
  final pen = await tester.createGesture(kind: kind);
  await pen.addPointer(location: at - const Offset(4, 4));
  await pen.moveTo(at);
  await tester.pump();
  return pen;
}

void main() {
  testWidgets('stylus hover shows the current tool next to the tip', (
    tester,
  ) async {
    await _pump(tester);
    // the preview's places: dot at (430, 640) 12 x 12, so the tip is its
    // middle (436, 646); the badge at (446, 612) 34 x 34
    final pen = await _hover(tester, const Offset(436, 646));
    expect(tester.getRect(_badge), const Rect.fromLTWH(446, 612, 34, 34));
    expect(tester.getRect(_dot), const Rect.fromLTWH(430, 640, 12, 12));
    expect(_icon(tester), KitIconName.pen);
    // the icon in the middle, 22 (`svg.ic` 22 at 452, 618)
    expect(
      tester.getRect(
        find.descendant(of: _badge, matching: find.byType(KitIcon)),
      ),
      const Rect.fromLTWH(452, 618, 22, 22),
    );
    await pen.removePointer();

    await _pump(tester, icon: KitIconName.lassoRect);
    final again = await _hover(tester, const Offset(300, 400));
    expect(_icon(tester), KitIconName.lassoRect);
    expect(tester.getRect(_badge).topLeft, const Offset(310, 366));
    await again.removePointer();
  });

  testWidgets('the badge and the dot look like the preview', (tester) async {
    await _pump(tester);
    final pen = await _hover(tester, const Offset(436, 646));
    BoxDecoration decorationOf(Finder f) =>
        tester
                .widget<DecoratedBox>(
                  find.descendant(
                    of: f,
                    matching: find.byType(DecoratedBox),
                    matchRoot: true,
                  ),
                )
                .decoration
            as BoxDecoration;
    // `.badge`: --app-surface, 1px --app-line, radius 10,
    // `0 6px 14px -8px rgba(12,22,44,.26)`
    final badge = decorationOf(_badge);
    expect(badge.color, const Color(0xffffffff));
    expect(badge.border, Border.all(color: const Color(0xffe2e6ec)));
    expect(badge.borderRadius, BorderRadius.circular(10));
    expect(badge.boxShadow, [
      const BoxShadow(
        color: Color.fromRGBO(12, 22, 44, 0.26),
        offset: Offset(0, 6),
        blurRadius: (14 / 2 - 0.5) / 0.57735,
        spreadRadius: -8,
      ),
    ]);
    // `.hoverdot`: 1.5px #9fb6e8 ring around white at 60 %
    final dot = decorationOf(_dot);
    expect(dot.shape, BoxShape.circle);
    expect(dot.color, const Color.fromRGBO(255, 255, 255, 0.6));
    expect(dot.border, Border.all(color: const Color(0xff9fb6e8), width: 1.5));
    // the icon in --app-ink, line 1.558 on screen at 22 (computed 1.69964)
    final icon = tester.widget<KitIcon>(
      find.descendant(of: _badge, matching: find.byType(KitIcon)),
    );
    expect(icon.color, const Color(0xff1b2231));
    expect(icon.size, 22);
    expect(icon.strokeWidth, closeTo(1.69964, 0.0001));
    await pen.removePointer();
  });

  testWidgets('mouse and touch do not show the badge', (tester) async {
    await _pump(tester);
    final mouse = await _hover(
      tester,
      const Offset(300, 400),
      kind: PointerDeviceKind.mouse,
    );
    expect(_badge, findsNothing);
    expect(_dot, findsNothing);
    await mouse.removePointer();

    final finger = await tester.createGesture();
    await finger.down(const Offset(300, 400));
    await tester.pump();
    await finger.moveTo(const Offset(320, 420));
    await tester.pump();
    expect(_badge, findsNothing);
    await finger.up();
    await tester.pump();
    expect(_badge, findsNothing);

    // the pen's eraser end is a pen too
    final eraserEnd = await _hover(
      tester,
      const Offset(300, 400),
      kind: PointerDeviceKind.invertedStylus,
    );
    expect(_badge, findsOneWidget);
    await eraserEnd.removePointer();
  });

  testWidgets('badge hides when the pen touches down', (tester) async {
    await _pump(tester);
    final pen = await _hover(tester, const Offset(300, 400));
    expect(_badge, findsOneWidget);
    await pen.down(const Offset(300, 400));
    await tester.pump();
    expect(_badge, findsNothing);
    expect(_dot, findsNothing);
    // writing: still none
    await pen.moveTo(const Offset(340, 410));
    await tester.pump();
    expect(_badge, findsNothing);
    await pen.up();
    await tester.pump();
    expect(_badge, findsNothing);
    // lifted and hovering again
    await pen.moveTo(const Offset(350, 420));
    await tester.pump();
    expect(tester.getRect(_badge).topLeft, const Offset(360, 386));
    await pen.removePointer();
  });

  testWidgets('badge goes when the pen leaves', (tester) async {
    await _pump(tester);
    // out of range
    final pen = await _hover(tester, const Offset(300, 400));
    expect(_badge, findsOneWidget);
    await pen.removePointer();
    await tester.pump();
    expect(_badge, findsNothing);
    expect(_dot, findsNothing);

    // off the page onto what lies over it
    final again = await _hover(tester, const Offset(300, 400));
    expect(_badge, findsOneWidget);
    await again.moveTo(_strip.center);
    await tester.pump();
    expect(_badge, findsNothing);
    await again.removePointer();
  });

  testWidgets('badge stays on screen near the right edge', (tester) async {
    // Review Focus 2: no room on the right, it goes to the tip's left
    // (mirrored, 10 from it); no room above, it goes below the tip
    // (mirrored); both at the corner. Never over the tip.
    await _pump(tester);
    for (final (tip, at) in const [
      (Offset(581, 646), Offset(537, 612)),
      (Offset(436, 20), Offset(446, 20)),
      (Offset(581, 60), Offset(537, 26)),
      (Offset(581, 20), Offset(537, 20)),
      (Offset(2, 2), Offset(12, 2)),
    ]) {
      final pen = await _hover(tester, tip);
      final badge = tester.getRect(_badge);
      expect(badge.topLeft, at, reason: '$tip');
      expect((Offset.zero & _page).intersect(badge), badge, reason: '$tip');
      expect(badge.contains(tip), isFalse, reason: '$tip');
      await pen.removePointer();
      await tester.pump();
    }
  });

  testWidgets('it shows, moves and goes at once (no motion)', (tester) async {
    await _pump(tester);
    final pen = await _hover(tester, const Offset(300, 400));
    expect(tester.getRect(_badge).topLeft, const Offset(310, 366));
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(
      find.descendant(
        of: find.byType(KitHoverBadge),
        matching: find.byWidgetPredicate(
          (w) =>
              w is ImplicitlyAnimatedWidget ||
              w is AnimatedWidget ||
              w is Opacity,
        ),
      ),
      findsNothing,
    );
    await pen.moveTo(const Offset(200, 300));
    await tester.pump();
    expect(tester.getRect(_badge).topLeft, const Offset(210, 266));
    expect(tester.binding.hasScheduledFrame, isFalse);
    await pen.removePointer();
  });

  testWidgets('the badge takes no taps: the page under it gets them', (
    tester,
  ) async {
    final taps = await _pump(tester);
    final pen = await _hover(tester, const Offset(300, 400));
    final badge = tester.getRect(_badge);
    await tester.tapAt(badge.center);
    await tester.pump();
    expect(taps.value, 1);
    await pen.removePointer();
  });
}
