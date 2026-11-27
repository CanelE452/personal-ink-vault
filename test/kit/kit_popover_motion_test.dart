import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/kit/kit_popover.dart';

const _screen = Size(400, 600);
const _popKey = Key('pop');
const _nubKey = ValueKey('kit-popover-nub');

Widget _pop(BuildContext _) =>
    const SizedBox(key: _popKey, width: 120, height: 80);

/// Opens a popover on an anchor of 40 x 40 at [at], pumps to the middle of its
/// opening (110 ms of 220) and returns the window's rect then and when open.
Future<(Rect mid, Rect open)> _openAt(
  WidgetTester tester,
  Offset at,
  AxisDirection grow, {
  bool nub = false,
}) async {
  tester.view.physicalSize = _screen;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final anchor = GlobalKey();
  late BuildContext ctx;
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (c) {
            ctx = c;
            return Stack(
              children: [
                Positioned(
                  left: at.dx,
                  top: at.dy,
                  child: SizedBox(key: anchor, width: 40, height: 40),
                ),
              ],
            );
          },
        ),
      ),
    ),
  );
  void open() => unawaited(
    showKitPopover<void>(
      context: ctx,
      anchor: anchor,
      builder: _pop,
      grow: grow,
      nub: nub,
    ),
  );
  open();
  await tester.pumpAndSettle();
  final done = tester.getRect(find.byKey(_popKey));
  await tester.tapAt(const Offset(2, 2));
  await tester.pumpAndSettle();
  expect(find.byKey(_popKey), findsNothing);

  open();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 110));
  return (tester.getRect(find.byKey(_popKey)), done);
}

void main() {
  testWidgets('a window on the right edge grows from its own corner', (
    tester,
  ) async {
    for (final (grow, corner) in <(AxisDirection, Offset Function(Rect))>[
      (AxisDirection.down, (r) => r.topLeft),
      (AxisDirection.up, (r) => r.bottomLeft),
      (AxisDirection.right, (r) => r.topLeft),
      (AxisDirection.left, (r) => r.topRight),
    ]) {
      final (mid, open) = await _openAt(tester, const Offset(340, 300), grow);
      expect(mid.width, lessThan(open.width), reason: '$grow still growing');
      expect(
        (corner(mid) - corner(open)).distance,
        lessThan(2),
        reason: '$grow: the corner it grows from stays where it ends up',
      );
      // the next one opens on a clean navigator
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(2, 2));
      await tester.pumpAndSettle();
    }
  });

  testWidgets('a window with a nub grows from its corner, nub with it', (
    tester,
  ) async {
    final (mid, open) = await _openAt(
      tester,
      const Offset(340, 100),
      AxisDirection.down,
      nub: true,
    );
    final nubMid = tester.getCenter(find.byKey(_nubKey));
    expect(mid.width, lessThan(open.width));
    expect((mid.topLeft - open.topLeft).distance, lessThan(2));
    await tester.pumpAndSettle();
    final nubOpen = tester.getCenter(find.byKey(_nubKey));
    // the nub is on the window's top edge, scaled about the same corner
    final s = mid.width / open.width;
    final expected = open.topLeft + (nubOpen - open.topLeft) * s;
    expect((nubMid - expected).distance, lessThan(2));
  });
}
