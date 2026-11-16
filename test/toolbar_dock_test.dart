import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/toolbar/toolbar_dock.dart';

void main() {
  test('nearest edge picks the closest side', () {
    const size = Size(800, 600);
    expect(nearestToolbarEdge(const Offset(5, 300), size), AxisDirection.left);
    expect(
      nearestToolbarEdge(const Offset(790, 300), size),
      AxisDirection.right,
    );
    expect(nearestToolbarEdge(const Offset(400, 3), size), AxisDirection.up);
    expect(nearestToolbarEdge(const Offset(400, 590), size), AxisDirection.down);
  });

  testWidgets('dragging the handle to the right edge docks the toolbar there', (
    tester,
  ) async {
    var alignment = AxisDirection.up;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            final vertical =
                alignment == AxisDirection.left ||
                alignment == AxisDirection.right;
            return ToolbarDock(
              alignment: alignment,
              onAlignmentChanged: (value) => setState(() => alignment = value),
              toolbar: ColoredBox(
                key: const ValueKey('bar'),
                color: Colors.grey,
                child: Flex(
                  direction: vertical ? Axis.vertical : Axis.horizontal,
                  mainAxisSize: MainAxisSize.min,
                  children: const [ToolbarDockHandle(), Icon(Icons.edit)],
                ),
              ),
              child: const ColoredBox(
                color: Colors.white,
                child: SizedBox.expand(),
              ),
            );
          },
        ),
      ),
    );
    final screen = tester.getSize(find.byType(ToolbarDock));
    expect(tester.getTopLeft(find.byKey(const ValueKey('bar'))).dy, 0);

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('toolbar-dock-handle'))),
    );
    await gesture.moveBy(const Offset(30, 30));
    await tester.pump();
    for (final side in ['up', 'down', 'left', 'right']) {
      expect(
        find.byKey(ValueKey('toolbar-dock-zone-$side')),
        findsOneWidget,
        reason: side,
      );
    }
    await gesture.moveTo(Offset(screen.width - 4, screen.height / 2));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(alignment, AxisDirection.right);
    expect(find.byKey(const ValueKey('toolbar-dock-zone-right')), findsNothing);
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('bar'))).dx,
      greaterThan(screen.width / 2),
    );
  });

  testWidgets('a handle outside a dock draws nothing', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: ToolbarDockHandle())),
    );
    expect(find.byKey(const ValueKey('toolbar-dock-handle')), findsNothing);
  });
}
