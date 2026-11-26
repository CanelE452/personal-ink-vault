import 'package:flutter/gestures.dart' show kLongPressTimeout;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/ink_ui/floating_bar/floating_bar_parts.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/tools/laser_pointer.dart';
import 'package:saber/data/tools/pen.dart';
import 'package:saber/data/tools/shape_pen.dart';

import '../utils/shown.dart';
import 'floating_bar_harness.dart';

double _shown(WidgetTester tester) => shownOf(tester, floatingBar);

bool _takesPresses(WidgetTester tester) =>
    takesPresses(tester, barKey('floating-bar-undo'));

({bool start, bool end})? _fade(WidgetTester tester) {
  final fade = find.byType(FloatingBarEdgeFade);
  if (fade.evaluate().isEmpty) return null;
  final w = tester.widget<FloatingBarEdgeFade>(fade);
  return (start: w.start, end: w.end);
}

void main() {
  setUp(() {
    FlavorConfig.setup();
    resetBarState();
  });
  tearDown(resetBarState);

  testWidgets('it grows from the button that shows it and goes back there', (
    tester,
  ) async {
    final host = await pumpBar(tester, ShapePen());
    // the toolbar's pen button, its middle at 225 across (values §14-4)
    host.growFrom.value = 225;
    host.pick(Pen.fountainPen());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    var r = tester.getRect(floatingBar);
    var s = r.width / 440;
    expect(s, inExclusiveRange(0.92, 1));
    expect(r.left, moreOrLessEquals(10 + 215 * (1 - s)));
    expect(r.top, 10);
    await tester.pumpAndSettle();
    expect(tester.getRect(floatingBar), const Rect.fromLTWH(10, 10, 440, 40));

    // it goes into the same place
    host.pick(LaserPointer.currentLaserPointer);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    r = tester.getRect(floatingBar);
    s = r.width / 440;
    expect(s, inExclusiveRange(0.92, 1));
    expect(r.left, moreOrLessEquals(10 + 215 * (1 - s)));
    await tester.pumpAndSettle();
    expect(floatingBar, findsNothing);

    // with no button known it grows from its own left
    host.growFrom.value = null;
    host.pick(Pen.fountainPen());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(tester.getRect(floatingBar).left, 10);
    await tester.pumpAndSettle();
  });

  testWidgets('a hold that moves 10 or less keeps its place', (tester) async {
    final host = await pumpBar(tester, Pen.fountainPen());
    expect(stows.floatingBarPosition.value, 'top');
    await dragBar(tester, Offset.zero);
    expect(stows.floatingBarPosition.value, 'top');
    await dragBar(tester, const Offset(-4, 6));
    expect(stows.floatingBarPosition.value, 'top');
    expect(tester.getRect(floatingBar), const Rect.fromLTWH(10, 10, 440, 40));
    // upright, the same
    stows.floatingBarPosition.value = 'left';
    await tester.pumpAndSettle();
    await dragBar(tester, const Offset(10, 0));
    expect(stows.floatingBarPosition.value, 'left');
    // a longer move still docks by where it is let go
    await dragBar(tester, const Offset(190, 0));
    expect(stows.floatingBarPosition.value, 'top');
    expect(host.undoRuns, 0);
  });

  testWidgets('while dragged it stays on the page', (tester) async {
    await pumpBar(tester, Pen.fountainPen());
    final g = await tester.startGesture(
      tester.getCenter(barKey('floating-bar-undo')),
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    await g.moveBy(const Offset(900, 1200));
    await tester.pump();
    // values §9: kept inside the page area (800 x 900 here)
    expect(tester.getRect(floatingBar), const Rect.fromLTWH(360, 860, 440, 40));
    await g.moveBy(const Offset(-2000, -2000));
    await tester.pump();
    expect(tester.getRect(floatingBar).topLeft, Offset.zero);
    await g.up();
    await tester.pumpAndSettle();
  });

  testWidgets(
    'on a narrow page only the tools slide, faded at the hidden end',
    (tester) async {
      await pumpBar(tester, Pen.fountainPen(), screen: const Size(360, 640));
      expect(tester.takeException(), isNull);
      // values §13-2: 340 wide, the undo pill still, the tools 254 from 96
      expect(tester.getRect(floatingBar), const Rect.fromLTWH(10, 10, 340, 40));
      expect(tester.getRect(undoPill), const Rect.fromLTWH(10, 10, 80, 40));
      expect(tester.getRect(toolPill), const Rect.fromLTWH(96, 10, 254, 40));
      expect(_fade(tester), (start: false, end: true));

      final pencil = tester.getRect(barKey('floating-bar-pen-pencil'));
      await tester.drag(toolPill, const Offset(-40, 0));
      await tester.pumpAndSettle();
      expect(_fade(tester), (start: true, end: true));
      await tester.drag(toolPill, const Offset(-400, 0));
      await tester.pumpAndSettle();
      expect(_fade(tester), (start: true, end: false));
      expect(tester.getRect(undoPill), const Rect.fromLTWH(10, 10, 80, 40));
      expect(tester.getRect(toolPill), const Rect.fromLTWH(96, 10, 254, 40));
      expect(
        tester.getRect(barKey('floating-bar-pen-pencil')).left,
        lessThan(pencil.left),
      );
      // the 6 between the pills is still the page's
      expect(stows.floatingBarPosition.value, 'top');
    },
  );

  testWidgets('a wide page shows the whole bar without fading', (tester) async {
    await pumpBar(tester, Pen.fountainPen());
    expect(_fade(tester), (start: false, end: false));
    expect(
      find.descendant(of: floatingBar, matching: find.byType(ShaderMask)),
      findsNothing,
    );
  });

  testWidgets('a stroke near the upright bar hides it; less motion at once', (
    tester,
  ) async {
    stows.floatingBarPosition.value = 'left';
    final host = await pumpBar(tester, Pen.fountainPen(), reduceMotion: true);
    final r = tester.getRect(floatingBar);
    expect(r, const Rect.fromLTWH(10, 10, 40, 416));
    host.strokeAt.value = Offset(r.right + 13, 200);
    await tester.pump();
    expect(_shown(tester), 1);
    host.strokeAt.value = Offset(r.right + 11, 200);
    await tester.pump();
    expect(_shown(tester), 0, reason: 'at once with less motion');
    expect(_takesPresses(tester), isFalse);
    host.strokeAt.value = null;
    await tester.pump(const Duration(milliseconds: 599));
    expect(_shown(tester), 0);
    await tester.pump(const Duration(milliseconds: 2));
    await tester.pump();
    expect(_shown(tester), 1);
    expect(_takesPresses(tester), isTrue);
    expect(host.paints, 1, reason: 'the page under it is not painted again');
  });

  testWidgets('a long press on the bar under a stroke is the page\'s', (
    tester,
  ) async {
    final host = await pumpBar(tester, Pen.fountainPen());
    host.strokeAt.value = const Offset(200, 30);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    final g = await tester.startGesture(tester.getCenter(undoPill));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    await g.moveBy(const Offset(200, 300));
    await g.up();
    await tester.pump();
    expect(tester.getRect(floatingBar).topLeft, const Offset(10, 10));
    expect(host.canvasTaps, 0);
    host.strokeAt.value = null;
    await tester.pumpAndSettle();
  });
}
