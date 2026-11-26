import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/kit/kit_icon.dart';
import 'package:saber/components/kit/kit_pill.dart';
import 'package:saber/components/kit/kit_selection_bar.dart';
import 'package:saber/components/kit/kit_tokens.dart';

const _screen = Size(400, 300);

Future<void> _pump(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = _screen;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(size: _screen),
        child: child!,
      ),
      home: Scaffold(body: Center(child: child)),
    ),
  );
}

Color? _ink(WidgetTester tester, String key) => tester
    .widget<KitIcon>(
      find.descendant(of: find.byKey(Key(key)), matching: find.byType(KitIcon)),
    )
    .color;

Color _line(WidgetTester tester, Finder line) => tester
    .widget<ColoredBox>(
      find.descendant(of: line, matching: find.byType(ColoredBox)),
    )
    .color;

void main() {
  testWidgets('pill buttons and lines use the floating bar ink and line', (
    tester,
  ) async {
    // task-12-values.md lines 40 and 48: `.fbar .pb` ink `--app-ink`
    // #1b2231, `.vsep` `--app-line` #e2e6ec
    await _pump(
      tester,
      KitPill(
        children: [
          KitPillButton(
            key: const Key('on'),
            icon: KitIconName.home,
            tooltip: 'on',
            selected: true,
            onPressed: () {},
          ),
          const KitPillDivider(),
          const KitPillButton(
            key: Key('off'),
            icon: KitIconName.plus,
            tooltip: 'off',
          ),
        ],
      ),
    );
    for (final k in ['on', 'off']) {
      expect(_ink(tester, k), const Color(0xff1b2231), reason: k);
    }
    expect(_line(tester, find.byType(KitPillDivider)), const Color(0xffe2e6ec));
  });

  testWidgets('a raised pill casts the held shadow and keeps its size', (
    tester,
  ) async {
    // task-12-values.md §13: picked up, the shadow goes a step up, eased in
    // the fast step (.12 s); the pill does not grow
    Widget pill({required bool raised}) => KitPill(
      key: const Key('pill'),
      raised: raised,
      children: const [KitPillButton(icon: KitIconName.home, tooltip: 'h')],
    );
    List<BoxShadow>? shadow() =>
        (tester
                    .widget<DecoratedBox>(
                      find
                          .descendant(
                            of: find.byKey(const Key('pill')),
                            matching: find.byType(DecoratedBox),
                          )
                          .first,
                    )
                    .decoration
                as BoxDecoration)
            .boxShadow;
    await _pump(tester, pill(raised: false));
    final size = tester.getSize(find.byKey(const Key('pill')));
    expect(shadow(), KitTokens.pillShadow);
    await _pump(tester, pill(raised: true));
    // half the step in, CSS's `ease` has gone 80 % of the way
    await tester.pump(const Duration(milliseconds: 60));
    expect(
      shadow()!.single.offset.dy,
      closeTo(6 + 10 * Curves.ease.transform(0.5), 1e-9),
    );
    await tester.pumpAndSettle();
    expect(shadow(), KitTokens.pillShadowRaised);
    expect(tester.getSize(find.byKey(const Key('pill'))), size);
    await _pump(tester, pill(raised: false));
    await tester.pumpAndSettle();
    expect(shadow(), KitTokens.pillShadow);
  });

  testWidgets('the selection bar keeps its own ink and line', (tester) async {
    // design doc line 94: icons #141416, a 1 x 28 line #d6d6db between groups
    await _pump(
      tester,
      KitSelectionBar(
        groups: [
          [
            KitSelectionBarButton(
              key: const Key('a'),
              icon: KitIconName.home,
              tooltip: 'a',
              onPressed: () {},
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
    );
    expect(_ink(tester, 'a'), const Color(0xff141416));
    expect(_ink(tester, 'c'), const Color(0xff141416));
    final line = find.byKey(const ValueKey('kit-selection-bar-divider'));
    expect(tester.getSize(line), const Size(1, 28));
    expect(_line(tester, line), const Color(0xffd6d6db));
  });
}
