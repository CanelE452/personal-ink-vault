import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/kit/kit_pop_in.dart';

import '../utils/shown.dart';

final _child = find.byKey(const ValueKey('pop-child'));

/// A pop-in that [shown] opens and closes, with a button inside.
Future<ValueNotifier<bool>> _pump(
  WidgetTester tester, {
  bool linearFade = false,
  bool reduceMotion = false,
  void Function()? onTap,
}) async {
  final shown = ValueNotifier(false);
  addTearDown(shown.dispose);
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(disableAnimations: reduceMotion),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: ValueListenableBuilder(
            valueListenable: shown,
            builder: (context, on, _) => KitPopIn(
              shown: on,
              open: const Duration(milliseconds: 180),
              close: const Duration(milliseconds: 126),
              shift: -6,
              linearFade: linearFade,
              child: GestureDetector(
                key: const ValueKey('pop-child'),
                behavior: HitTestBehavior.opaque,
                onTap: onTap,
                child: const SizedBox(width: 40, height: 20),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  return shown;
}

void main() {
  testWidgets('it fades and moves in, then back out and away', (tester) async {
    final shown = await _pump(tester);
    expect(_child, findsNothing);
    shown.value = true;
    await tester.pump();
    expect(shownOf(tester, _child), 0);
    expect(tester.getTopLeft(_child), const Offset(0, -6));
    await tester.pump(const Duration(milliseconds: 90));
    expect(shownOf(tester, _child), inExclusiveRange(0.5, 1));
    await tester.pump(const Duration(milliseconds: 91));
    expect(shownOf(tester, _child), 1);
    expect(tester.getTopLeft(_child), Offset.zero);
    expect(takesPresses(tester, _child), isTrue);

    // closing is quick first and slow at the end, as the preview's CSS
    shown.value = false;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 63));
    expect(shownOf(tester, _child), lessThan(0.3));
    expect(takesPresses(tester, _child), isFalse);
    await tester.pump(const Duration(milliseconds: 64));
    expect(_child, findsNothing);
  });

  testWidgets('a linear fade moves on the curve but fades evenly', (
    tester,
  ) async {
    final shown = await _pump(tester, linearFade: true);
    shown.value = true;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 90));
    expect(shownOf(tester, _child), moreOrLessEquals(0.5, epsilon: 0.01));
    expect(tester.getTopLeft(_child).dy, greaterThan(-3));
    await tester.pumpAndSettle();
  });

  testWidgets('with less motion it comes and goes at once', (tester) async {
    final shown = await _pump(tester, reduceMotion: true);
    shown.value = true;
    await tester.pump();
    expect(shownOf(tester, _child), 1);
    shown.value = false;
    await tester.pump();
    await tester.pump();
    expect(_child, findsNothing);
  });
}
