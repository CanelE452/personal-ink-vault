import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/kit/kit_controls.dart';
import 'package:saber/components/kit/kit_icon.dart';
import 'package:saber/components/kit/kit_menu.dart';
import 'package:saber/components/kit/kit_text.dart';
import 'package:saber/components/kit/kit_tokens.dart';

const _wide = Size(800, 600);

Future<BuildContext> _pump(
  WidgetTester tester,
  GlobalKey anchor,
  Offset at,
) async {
  tester.view.physicalSize = _wide;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
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
  return ctx;
}

const _subRow = Key('sub-row');

KitMenu _menuWithSubmenu() => KitMenu(
  groups: [
    KitMenuGroup(
      rows: [
        KitMenuRow.action(icon: KitIconName.copy, label: 'Copy', onTap: () {}),
        KitMenuRow.submenu(
          key: _subRow,
          icon: KitIconName.more,
          label: 'More',
          value: 'Two',
          children: [
            KitMenuRow.action(
              icon: KitIconName.trash,
              label: 'Leaf',
              onTap: () {},
            ),
          ],
        ),
      ],
    ),
  ],
);

void main() {
  testWidgets('submenu opens to the left of its row', (tester) async {
    final anchor = GlobalKey();
    final ctx = await _pump(tester, anchor, const Offset(500, 50));
    unawaited(
      showKitMenu(context: ctx, anchor: anchor, menu: _menuWithSubmenu()),
    );
    await tester.pumpAndSettle();
    expect(find.byType(KitMenu), findsOneWidget);
    final menu = tester.getRect(find.byType(KitMenu));
    final row = tester.getRect(find.byKey(_subRow));

    await tester.tap(find.byKey(_subRow));
    await tester.pumpAndSettle();
    expect(find.byType(KitMenu), findsNWidgets(2));
    expect(find.text('Leaf'), findsOneWidget);
    final sub = tester.getRect(find.byType(KitMenu).at(1));
    expect(sub.right, closeTo(menu.left - KitTokens.submenuGap, 0.5));
    expect(sub.top, closeTo(row.top, 0.5));
  });

  testWidgets('menu icons use the 7th-draft size and line', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: KitMenu(
              quick: [
                KitMenuQuick(
                  icon: KitIconName.share,
                  label: 'Export',
                  onTap: () {},
                ),
              ],
              groups: [
                KitMenuGroup(
                  rows: [
                    KitMenuRow.action(
                      icon: KitIconName.book,
                      label: 'Layout',
                      onTap: () {},
                    ),
                    KitMenuRow.submenu(
                      icon: KitIconName.more,
                      label: 'More',
                      children: [
                        KitMenuRow.action(
                          icon: KitIconName.trash,
                          label: 'Leaf',
                          onTap: () {},
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    KitIcon icon(KitIconName n) => tester.widget<KitIcon>(
      find.byWidgetPredicate((w) => w is KitIcon && w.name == n),
    );
    for (final n in [KitIconName.book, KitIconName.more, KitIconName.share]) {
      expect(icon(n).size, 22, reason: '$n');
      expect(icon(n).strokeWidth, closeTo(1.62273, 1e-4), reason: '$n');
    }
    expect(icon(KitIconName.chevR).size, 18);
    expect(icon(KitIconName.chevR).strokeWidth, closeTo(1.41667, 1e-4));
  });

  testWidgets('submenu window has radius 14 and its own two shadows', (
    tester,
  ) async {
    final anchor = GlobalKey();
    final ctx = await _pump(tester, anchor, const Offset(500, 50));
    unawaited(
      showKitMenu(context: ctx, anchor: anchor, menu: _menuWithSubmenu()),
    );
    await tester.pumpAndSettle();
    BoxDecoration windowOf(int i) =>
        tester
                .widget<DecoratedBox>(
                  find
                      .ancestor(
                        of: find.byType(KitMenu).at(i),
                        matching: find.byType(DecoratedBox),
                      )
                      .first,
                )
                .decoration
            as BoxDecoration;
    expect(
      windowOf(0).borderRadius,
      BorderRadius.circular(KitTokens.penPanelRadius),
    );
    expect(windowOf(0).border, isNull);
    expect(windowOf(0).boxShadow, KitTokens.menuShadow);

    await tester.tap(find.byKey(_subRow));
    await tester.pumpAndSettle();
    final sub = windowOf(1);
    expect(sub.border, isNull);
    expect(sub.boxShadow, KitTokens.subMenuShadow);
    expect(sub.borderRadius, BorderRadius.circular(14));
    expect(sub.boxShadow, hasLength(2));
    expect(sub.boxShadow![0].blurSigma, closeTo(15, 1e-9));
    expect(sub.boxShadow![0].spreadRadius, -14);
    expect(sub.boxShadow![1].spreadRadius, 1);
  });

  testWidgets('submenu falls back to the right when there is no room', (
    tester,
  ) async {
    final anchor = GlobalKey();
    final ctx = await _pump(tester, anchor, const Offset(20, 50));
    unawaited(
      showKitMenu(context: ctx, anchor: anchor, menu: _menuWithSubmenu()),
    );
    await tester.pumpAndSettle();
    final menu = tester.getRect(find.byType(KitMenu));
    final row = tester.getRect(find.byKey(_subRow));

    await tester.tap(find.byKey(_subRow));
    await tester.pumpAndSettle();
    final sub = tester.getRect(find.byType(KitMenu).at(1));
    expect(sub.left, closeTo(menu.right + KitTokens.submenuGap, 0.5));
    expect(sub.top, closeTo(row.top, 0.5));
  });

  testWidgets('a tap outside closes only the submenu', (tester) async {
    final anchor = GlobalKey();
    final ctx = await _pump(tester, anchor, const Offset(500, 50));
    unawaited(
      showKitMenu(context: ctx, anchor: anchor, menu: _menuWithSubmenu()),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(_subRow));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.byType(KitMenu), findsOneWidget);
  });

  testWidgets('danger rows use the danger colour', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: KitMenu(
            groups: [
              KitMenuGroup(
                rows: [
                  KitMenuRow.action(
                    icon: KitIconName.trash,
                    label: 'Delete',
                    danger: true,
                    onTap: () {},
                  ),
                  KitMenuRow.action(
                    icon: KitIconName.copy,
                    label: 'Copy',
                    onTap: () {},
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    expect(
      tester.widget<Text>(find.text('Delete')).style?.color,
      KitTokens.danger,
    );
    expect(
      tester.widget<Text>(find.text('Copy')).style?.color,
      KitTokens.menuInk,
    );
  });

  testWidgets('menu shows title, quick buttons, group titles and values', (
    tester,
  ) async {
    var quick = 0;
    var tapped = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: KitMenu(
              title: 'Note',
              quick: [
                KitMenuQuick(
                  icon: KitIconName.copy,
                  label: 'Duplicate',
                  onTap: () => quick++,
                ),
                KitMenuQuick(
                  icon: KitIconName.share,
                  label: 'Export',
                  onTap: () => quick++,
                ),
              ],
              groups: [
                KitMenuGroup(
                  title: 'View',
                  rows: [
                    KitMenuRow.action(
                      icon: KitIconName.book,
                      label: 'Layout',
                      value: 'Grid',
                      onTap: () => tapped++,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    expect(find.text('Note'), findsOneWidget);
    expect(find.text('View'), findsOneWidget);
    expect(find.text('Grid'), findsOneWidget);
    expect(tester.getSize(find.byType(KitMenu)).width, KitTokens.menuWidth);
    await tester.tap(find.text('Export'));
    await tester.tap(find.text('Layout'));
    expect(quick, 1);
    expect(tapped, 1);
  });

  testWidgets('toggle and segment rows send their change', (tester) async {
    var on = false;
    var mode = 'a';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: StatefulBuilder(
              builder: (context, setState) => KitMenu(
                groups: [
                  KitMenuGroup(
                    rows: [
                      KitMenuRow.toggle(
                        icon: KitIconName.lock,
                        label: 'Lock',
                        value: on,
                        onChanged: (v) => setState(() => on = v),
                      ),
                      KitMenuRow.segment<String>(
                        icon: KitIconName.scrollDir,
                        label: 'Direction',
                        options: const [('a', 'Down'), ('b', 'Side')],
                        value: mode,
                        onChanged: (v) => setState(() => mode = v),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Lock'));
    await tester.pumpAndSettle();
    expect(on, isTrue);
    await tester.tap(find.text('Side'));
    await tester.pumpAndSettle();
    expect(mode, 'b');
  });

  for (final accept in [true, false]) {
    testWidgets(
      'showKitMenu rows show what the caller holds (caller ${accept ? 'accepts' : 'refuses'})',
      (tester) async {
        final anchor = GlobalKey();
        final ctx = await _pump(tester, anchor, const Offset(100, 50));
        var on = false;
        var mode = 'a';
        unawaited(
          showKitMenu(
            context: ctx,
            anchor: anchor,
            builder: () => KitMenu(
              groups: [
                KitMenuGroup(
                  rows: [
                    KitMenuRow.toggle(
                      icon: KitIconName.lock,
                      label: 'Lock',
                      value: on,
                      onChanged: (v) {
                        if (accept) on = v;
                      },
                    ),
                    KitMenuRow.segment<String>(
                      icon: KitIconName.scrollDir,
                      label: 'Direction',
                      options: const [('a', 'Down'), ('b', 'Side')],
                      value: mode,
                      onChanged: (v) {
                        if (accept) mode = v;
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
        await tester.pumpAndSettle();
        bool switchOn() =>
            tester.widget<KitSwitch>(find.byType(KitSwitch)).value;
        Color? ink(String t) => tester.widget<Text>(find.text(t)).style?.color;
        expect(switchOn(), isFalse);
        expect(ink('Side'), KitTokens.menuInk);

        await tester.tap(find.text('Lock'));
        await tester.pumpAndSettle();
        expect(switchOn(), accept);

        await tester.tap(find.text('Side'));
        await tester.pumpAndSettle();
        expect(ink('Side'), accept ? KitTokens.onAccent : KitTokens.menuInk);
        expect(ink('Down'), accept ? KitTokens.menuInk : KitTokens.onAccent);
      },
    );
  }

  testWidgets('a toggle inside a submenu repaints from the caller too', (
    tester,
  ) async {
    final anchor = GlobalKey();
    final ctx = await _pump(tester, anchor, const Offset(500, 50));
    var on = false;
    unawaited(
      showKitMenu(
        context: ctx,
        anchor: anchor,
        builder: () => KitMenu(
          groups: [
            KitMenuGroup(
              rows: [
                KitMenuRow.submenu(
                  key: _subRow,
                  icon: KitIconName.more,
                  label: 'More',
                  children: [
                    KitMenuRow.toggle(
                      icon: KitIconName.lock,
                      label: 'Inner',
                      value: on,
                      onChanged: (v) => on = v,
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(_subRow));
    await tester.pumpAndSettle();
    expect(tester.widget<KitSwitch>(find.byType(KitSwitch)).value, isFalse);
    await tester.tap(find.text('Inner'));
    await tester.pumpAndSettle();
    expect(tester.widget<KitSwitch>(find.byType(KitSwitch)).value, isTrue);
  });

  testWidgets('only a window menu sets its group titles as KitText', (
    tester,
  ) async {
    KitMenu menu({required bool window}) => KitMenu(
      window: window,
      groups: [
        KitMenuGroup(
          title: 'Group',
          rows: [
            KitMenuRow.action(icon: KitIconName.copy, label: 'Copy', onTap: () {}),
          ],
        ),
      ],
    );
    for (final window in [false, true]) {
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: menu(window: window))),
      );
      expect(
        find.ancestor(of: find.text('Group'), matching: find.byType(KitText)),
        window ? findsOneWidget : findsNothing,
        reason: 'window $window',
      );
    }
    // the settings menu's group title keeps the height it had before
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: menu(window: false))),
    );
    final title = tester.getSize(find.text('Group')).height;
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Text(
            'Group',
            style: TextStyle(
              fontSize: KitTokens.menuGroupTitleSize,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
    expect(title, tester.getSize(find.text('Group')).height);
  });

  testWidgets('a submenu is 206 wide with 40 high rows', (tester) async {
    final anchor = GlobalKey();
    final ctx = await _pump(tester, anchor, const Offset(500, 50));
    unawaited(
      showKitMenu(context: ctx, anchor: anchor, menu: _menuWithSubmenu()),
    );
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(KitMenu)).width, KitTokens.menuWidth);
    await tester.tap(find.byKey(_subRow));
    await tester.pumpAndSettle();
    final sub = find.byType(KitMenu).at(1);
    expect(tester.getSize(sub).width, 206);
    final leaf = find.ancestor(
      of: find.text('Leaf'),
      matching: find.byType(InkWell),
    );
    expect(tester.getSize(leaf).height, 40);
    expect(tester.getSize(sub).height, 40 + 2 * KitTokens.subMenuPadV);
  });
}
