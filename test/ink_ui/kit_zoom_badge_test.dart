import 'dart:ui' show Tristate;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/ink_ui/kit_zoom_badge.dart';

import '../utils/shown.dart';

const _page = Size(586, 734);

final _badge = find.byKey(const ValueKey('zoom-badge'));

/// What the badge says now, null when it is not there.
String? _says(WidgetTester tester) {
  final text = find.descendant(of: _badge, matching: find.byType(Text));
  if (text.evaluate().isEmpty) return null;
  return tester.widget<Text>(text).data;
}

double _shown(WidgetTester tester) =>
    shownOf(tester, find.byKey(const ValueKey('zoom-badge-pill')));

Future<ValueNotifier<double>> _pump(
  WidgetTester tester, {
  VoidCallback? onReset,
  bool Function()? shouldShow,
  ValueListenable<bool>? touching,
}) async {
  tester.view.physicalSize = _page;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final scale = ValueNotifier(1.0);
  addTearDown(scale.dispose);
  await tester.pumpWidget(
    MediaQuery(
      data: const MediaQueryData(size: _page),
      child: MaterialApp(
        home: Scaffold(
          body: KitZoomBadge(
            key: const ValueKey('zoom-badge'),
            scale: scale,
            shouldShow: shouldShow ?? () => true,
            onReset: onReset,
            touching: touching,
          ),
        ),
      ),
    ),
  );
  return scale;
}

void main() {
  testWidgets('it stays while the fingers are down, then goes a second after', (
    tester,
  ) async {
    // the preview's `zoomRelease`: the hide is counted from the lift
    final touching = ValueNotifier(true);
    addTearDown(touching.dispose);
    final scale = await _pump(tester, touching: touching);
    scale.value = 1.5;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 1500));
    expect(_shown(tester), 1, reason: 'fingers still down, no change');
    touching.value = false;
    await tester.pump(const Duration(milliseconds: 999));
    expect(_shown(tester), 1);
    await tester.pump(const Duration(milliseconds: 2));
    await tester.pump(const Duration(milliseconds: 106));
    await tester.pump();
    expect(_says(tester), isNull, reason: 'gone a second after the lift');
  });

  testWidgets('zoom badge shows while pinching and resets to 100%', (
    tester,
  ) async {
    var resets = 0;
    final scale = await _pump(tester, onReset: () => resets++);
    // a two-finger pan's small drift stays quiet
    scale.value = 1.01;
    await tester.pump(const Duration(milliseconds: 200));
    expect(_says(tester), isNull);

    scale.value = 1.5;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(_says(tester), '150%');
    expect(_shown(tester), 1);
    // values §8: top 100, centred, 30 high, at least 64 wide
    final r = tester.getRect(find.byKey(const ValueKey('zoom-badge-pill')));
    expect(r.top, 100);
    expect(r.height, 30);
    // as wide as its words: at least 64, not the page
    expect(r.width, inInclusiveRange(64, 100));
    expect(r.center.dx, moreOrLessEquals(_page.width / 2));

    // it stays while the scale changes, then hides a second after the last
    await tester.pump(const Duration(milliseconds: 700));
    scale.value = 1.6;
    await tester.pump(const Duration(milliseconds: 700));
    expect(_says(tester), '160%');
    await tester.pump(const Duration(milliseconds: 299));
    expect(_shown(tester), 1);
    await tester.pump(const Duration(milliseconds: 2));
    await tester.pump(const Duration(milliseconds: 106));
    await tester.pump();
    expect(_says(tester), isNull);

    // a press goes back to 100 %
    scale.value = 2;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    await tester.tap(find.byKey(const ValueKey('zoom-badge-pill')));
    expect(resets, 1);
    await tester.pumpAndSettle();
  });

  testWidgets('locked, the badge cannot be pressed', (tester) async {
    final scale = await _pump(tester);
    scale.value = 1.5;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(_says(tester), '150%');
    final semantics = tester
        .getSemantics(find.byKey(const ValueKey('zoom-badge-pill')))
        .getSemanticsData();
    expect(semantics.flagsCollection.isEnabled, Tristate.isFalse);
    expect(semantics.hasAction(SemanticsAction.tap), isFalse);
    await tester.tap(find.byKey(const ValueKey('zoom-badge-pill')));
    await tester.pumpAndSettle();
  });

  testWidgets('zooms the app makes itself keep it hidden', (tester) async {
    final scale = await _pump(tester, shouldShow: () => false);
    scale.value = 1.5;
    await tester.pump(const Duration(milliseconds: 200));
    expect(_says(tester), isNull);
  });
}
