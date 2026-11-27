import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/ink_ui/side_panel/kit_page_menu.dart';
import 'package:saber/components/kit/kit_icon.dart';
import 'package:saber/components/kit/kit_tokens.dart';

/// The thumbnail ⋮ menu (page thumbnail menu, Task 5).
void main() {
  const labels = [
    '앞에 쪽 추가',
    '뒤에 쪽 추가',
    '복제',
    '복사',
    '잘라내기',
    '붙여넣기',
    '쪽 비우기',
    '쪽 삭제',
  ];
  const icons = [
    KitIconName.pageAddBefore,
    KitIconName.pageAddAfter,
    KitIconName.dup,
    KitIconName.pageCopy,
    KitIconName.scissors,
    KitIconName.paste,
    KitIconName.eraser,
    KitIconName.trash,
  ];

  /// A button at [at] that opens the menu; what it returned goes in [picked]
  /// (null entries are closes).
  Future<List<KitPageAction?>> mount(
    WidgetTester tester, {
    bool canEdit = true,
    bool canPaste = true,
    bool canDelete = true,
    bool canClear = true,
    double top = 0,
    Alignment at = Alignment.topLeft,
    Size size = const Size(600, 800),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final picked = <KitPageAction?>[];
    await tester.pumpWidget(
      MediaQuery(
        data: MediaQueryData(size: size),
        child: MaterialApp(
          home: Material(
            child: Padding(
              padding: EdgeInsets.only(top: top),
              child: Align(
                alignment: at,
                child: Builder(
                  builder: (context) => GestureDetector(
                    key: const ValueKey('opener'),
                    behavior: HitTestBehavior.opaque,
                    onTap: () async => picked.add(
                      await showKitPageMenu(
                        context,
                        canEdit: canEdit,
                        canPaste: canPaste,
                        canDelete: canDelete,
                        canClear: canClear,
                      ),
                    ),
                    child: const SizedBox(width: 32, height: 32),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    return picked;
  }

  Future<void> open(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('opener')));
    await tester.pumpAndSettle();
  }

  Finder row(String label) => find.byKey(ValueKey('kit-page-menu-$label'));

  test('the actions are the eight, in the order of the menu', () {
    expect(KitPageAction.values.map((a) => a.name), [
      'insertBefore',
      'insertAfter',
      'duplicate',
      'copy',
      'cut',
      'paste',
      'clear',
      'delete',
    ]);
  });

  testWidgets('menu lists the eight items in order with lines between groups', (
    tester,
  ) async {
    await mount(tester);
    await open(tester);
    final tops = [for (final l in labels) tester.getTopLeft(row(l)).dy];
    expect(tops, orderedEquals([...tops]..sort()));
    expect(tops.toSet(), hasLength(8), reason: 'one row each');
    for (final l in labels) {
      expect(find.text(l), findsOneWidget, reason: l);
    }
    // a line over the first row of each group, none inside a group
    const lineAbove = [false, false, true, true, false, false, true, true];
    for (final (i, l) in labels.indexed) {
      final box = tester.widget<DecoratedBox>(
        find.descendant(of: row(l), matching: find.byType(DecoratedBox)).first,
      );
      final border = (box.decoration as BoxDecoration).border as Border?;
      expect(
        border?.top.color == KitTokens.menuLine &&
            border?.top.width == KitTokens.menuLineWidth,
        lineAbove[i],
        reason: l,
      );
    }
    // each item's icon, before its text
    for (final (i, l) in labels.indexed) {
      final icon = tester.widget<KitIcon>(
        find.descendant(of: row(l), matching: find.byType(KitIcon)),
      );
      expect(icon.name, icons[i], reason: l);
      expect(
        tester
            .getCenter(
              find.descendant(of: row(l), matching: find.byType(KitIcon)),
            )
            .dx,
        lessThan(tester.getCenter(find.text(l)).dx),
        reason: l,
      );
    }
  });

  testWidgets('add before and add after, clear and delete, look apart', (
    tester,
  ) async {
    await mount(tester);
    await open(tester);
    KitIconName iconOf(String label) => tester
        .widget<KitIcon>(
          find.descendant(of: row(label), matching: find.byType(KitIcon)),
        )
        .name;
    expect(iconOf('앞에 쪽 추가'), isNot(iconOf('뒤에 쪽 추가')));
    // clearing keeps the page: an eraser, not a page crossed out
    expect(iconOf('쪽 비우기'), KitIconName.eraser);
    expect(iconOf('쪽 삭제'), KitIconName.trash);
  });

  testWidgets('a tap on an item closes the menu with that action', (
    tester,
  ) async {
    final picked = await mount(tester);
    for (final (i, l) in labels.indexed) {
      await open(tester);
      await tester.tap(row(l));
      await tester.pumpAndSettle();
      expect(picked.last, KitPageAction.values[i], reason: l);
      expect(find.text(l), findsNothing, reason: 'closed');
    }
  });

  testWidgets('read-only menu enables only copy', (tester) async {
    final picked = await mount(tester, canEdit: false);
    await open(tester);
    for (final l in labels) {
      final dim = tester.widget<Opacity>(
        find.descendant(of: row(l), matching: find.byType(Opacity)).first,
      );
      expect(dim.opacity, l == '복사' ? 1 : KitTokens.disabledOpacity, reason: l);
    }
    for (final l in labels.where((l) => l != '복사')) {
      await tester.tap(row(l));
      await tester.pumpAndSettle();
      expect(find.text(l), findsOneWidget, reason: '$l does nothing');
    }
    expect(picked, isEmpty);
    await tester.tap(row('복사'));
    await tester.pumpAndSettle();
    expect(picked, [KitPageAction.copy]);
  });

  testWidgets('paste is off without a clip', (tester) async {
    final picked = await mount(tester, canPaste: false);
    await open(tester);
    expect(
      tester
          .widget<Opacity>(
            find
                .descendant(of: row('붙여넣기'), matching: find.byType(Opacity))
                .first,
          )
          .opacity,
      KitTokens.disabledOpacity,
    );
    await tester.tap(row('붙여넣기'));
    await tester.pumpAndSettle();
    expect(find.text('붙여넣기'), findsOneWidget);
    expect(picked, isEmpty);
    // the others stay on
    await tester.tap(row('복제'));
    await tester.pumpAndSettle();
    expect(picked, [KitPageAction.duplicate]);
  });

  testWidgets('delete and cut are off on the only page', (tester) async {
    final picked = await mount(tester, canDelete: false);
    await open(tester);
    for (final l in ['잘라내기', '쪽 삭제']) {
      expect(
        tester
            .widget<Opacity>(
              find.descendant(of: row(l), matching: find.byType(Opacity)).first,
            )
            .opacity,
        KitTokens.disabledOpacity,
        reason: l,
      );
      await tester.tap(row(l));
      await tester.pumpAndSettle();
      expect(find.text(l), findsOneWidget, reason: '$l does nothing');
    }
    expect(picked, isEmpty);
    for (final l in ['복사', '붙여넣기', '쪽 비우기']) {
      expect(
        tester
            .widget<Opacity>(
              find.descendant(of: row(l), matching: find.byType(Opacity)).first,
            )
            .opacity,
        1,
        reason: l,
      );
    }
  });

  testWidgets('the menu opens down from the button, up near the window foot', (
    tester,
  ) async {
    await mount(tester);
    await open(tester);
    final opener = tester.getRect(find.byKey(const ValueKey('opener')));
    expect(tester.getTopLeft(row('앞에 쪽 추가')).dy, closeTo(opener.bottom, 1));
    await tester.tapAt(const Offset(500, 700));
    await tester.pumpAndSettle();

    await mount(tester, at: Alignment.bottomLeft);
    await open(tester);
    final low = tester.getRect(find.byKey(const ValueKey('opener')));
    expect(
      tester.getBottomLeft(row('쪽 삭제')).dy,
      closeTo(low.top, 1),
      reason: 'it ends where the button starts',
    );
  });

  testWidgets('every row reads out its label as a button', (tester) async {
    final semantics = tester.ensureSemantics();
    await mount(tester, canEdit: false);
    await open(tester);
    for (final l in labels) {
      expect(
        tester.getSemantics(row(l)),
        matchesSemantics(
          label: l,
          isButton: true,
          hasTapAction: l == '복사',
          isEnabled: l == '복사',
          hasEnabledState: true,
        ),
        reason: l,
      );
    }
    semantics.dispose();
  });

  testWidgets('clear is off when the page is empty', (tester) async {
    final picked = await mount(tester, canClear: false);
    await open(tester);
    expect(
      tester
          .widget<Opacity>(
            find
                .descendant(of: row('쪽 비우기'), matching: find.byType(Opacity))
                .first,
          )
          .opacity,
      KitTokens.disabledOpacity,
    );
    await tester.tap(row('쪽 비우기'));
    await tester.pumpAndSettle();
    expect(find.text('쪽 비우기'), findsOneWidget);
    expect(picked, isEmpty);
    await tester.tap(row('쪽 삭제'));
    await tester.pumpAndSettle();
    expect(picked, [KitPageAction.delete], reason: 'the others stay on');
  });

  testWidgets('the menu is as tall as its rows and fits on screen near the '
      'bottom', (tester) async {
    const screen = 800.0;
    const button = 32.0;
    const height = KitTokens.sideMenuRow * 8;
    // the room under the button is a little short of the menu: it opens up
    // and stays on screen; with room, it opens down and stays on screen
    for (final under in [height - 12, height + KitTokens.sideMenuFoot + 4]) {
      await mount(tester, top: screen - button - under);
      await open(tester);
      final first = tester.getTopLeft(row('앞에 쪽 추가')).dy;
      final last = tester.getBottomLeft(row('쪽 삭제')).dy;
      expect(last - first, height, reason: 'room $under');
      expect(first, greaterThanOrEqualTo(0), reason: 'room $under');
      expect(last, lessThanOrEqualTo(screen), reason: 'room $under');
      final opener = tester.getRect(find.byKey(const ValueKey('opener')));
      expect(
        under < height ? last : first,
        under < height ? opener.top : opener.bottom,
        reason: 'room $under',
      );
      await tester.tapAt(const Offset(580, 20));
      await tester.pumpAndSettle();
    }
  });
}
