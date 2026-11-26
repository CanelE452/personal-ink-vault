import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/ink_ui/pen_panel/size_level.dart';
import 'package:saber/components/ink_ui/tool_panels/kit_eraser_panel.dart';
import 'package:saber/components/ink_ui/tool_panels/tool_panel_common.dart';
import 'package:saber/components/kit/kit_controls.dart';
import 'package:saber/components/kit/kit_icon.dart';
import 'package:saber/components/kit/kit_pill.dart';
import 'package:saber/components/kit/kit_text.dart';
import 'package:saber/components/kit/kit_tokens.dart';
import 'package:saber/data/actions/app_action.dart';
import 'package:saber/data/actions/app_action_ids.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/tools/eraser.dart';
import 'package:saber/data/tools/eraser_targets.dart';
import 'package:saber/data/tools/select.dart';

import 'floating_bar_harness.dart';

/// The eraser's floating bar and its two windows (preview 10th draft 1-d,
/// spec 「지우개·올가미 창 개정」): [kind chip ▾] · [고급 설정] · [10 · 40 · 80],
/// 「지우개 종류」 with two cards, 「고급 설정」 with the size slider, the four
/// targets, 「자동 해제」 and 「쪽 지우기」.

const _chip = 'floating-bar-eraser-kind';
const _advanced = 'floating-bar-eraser-advanced';
String _size(int level) => 'floating-bar-eraser-size-$level';

final _typePanel = find.byKey(const ValueKey('kit-eraser-type-panel'));
final _advancedPanel = find.byKey(const ValueKey('kit-eraser-advanced-panel'));
final _slider = find.byKey(const ValueKey('eraser-advanced-size'));
final _ring = find.byKey(const ValueKey('floating-bar-eraser-size-ring'));

SemanticsData _semantics(WidgetTester tester, String key) =>
    tester.getSemantics(barKey(key)).getSemanticsData();

/// The presets drawn with the chosen ring.
List<int> _ringed(WidgetTester tester) => [
  for (final level in KitTokens.eraserSizePresets)
    if (inside(barKey(_size(level)), _ring).evaluate().isNotEmpty) level,
];

void _setLevel(int level) => stows.eraserSize.value = levelToSize(
  level,
  min: KitTokens.eraserSizeMin,
  max: KitTokens.eraserSizeMax,
);

int _level() => sizeToLevel(
  stows.eraserSize.value,
  min: KitTokens.eraserSizeMin,
  max: KitTokens.eraserSizeMax,
);

Future<void> _open(WidgetTester tester, String key) async {
  await tester.tap(barKey(key));
  await tester.pumpAndSettle();
}

Future<void> _closeWindow(WidgetTester tester) async {
  await tester.tapAt(outside);
  await tester.pumpAndSettle();
}

void main() {
  FlavorConfig.setup();
  tearDown(() {
    resetBarState();
    Select.currentSelect.unselect();
  });

  testWidgets('the bar: kind chip, advanced settings, three sizes', (
    tester,
  ) async {
    _setLevel(40);
    await pumpBar(tester, Eraser());
    // no stroke/circle buttons and no 「형광펜만 지우기」 any more
    for (final old in [
      'floating-bar-eraser-stroke',
      'floating-bar-eraser-lasso',
      'floating-bar-erase-highlighter-only',
    ]) {
      expect(barKey(old), findsNothing, reason: old);
    }
    final chip = tester.getRect(barKey(_chip));
    final adv = tester.getRect(barKey(_advanced));
    final sizes = [
      for (final level in const [10, 40, 80])
        tester.getRect(barKey(_size(level))),
    ];
    final line = tester.getRect(inside(toolPill, find.byType(KitPillDivider)));
    // `.e10chip` 32 high; the buttons 32; the pill's gap 2, the line 3 in
    expect(chip.height, 32);
    expect(chip.width, greaterThanOrEqualTo(64));
    expect(adv.size, const Size(32, 32));
    expect(adv.left, chip.right + 2);
    expect(line.left, adv.right + 2 + 3);
    expect(sizes.first.left, line.right + 3 + 2);
    for (final (i, s) in sizes.indexed) {
      expect(s.size, const Size(32, 32));
      expect(s.top, chip.top);
      if (i > 0) expect(s.left, sizes[i - 1].right + 2);
    }
    // the circles 10, 15, 20 across
    for (final (level, d) in const [(10, 10.0), (40, 15.0), (80, 20.0)]) {
      final circle = inside(
        barKey(_size(level)),
        find.byKey(const ValueKey('floating-bar-eraser-size-circle')),
      );
      expect(tester.getSize(circle), Size(d, d), reason: '$level');
    }
    // the chip: the stroke eraser's icon and its short name, opening a window
    expect(inside(barKey(_chip), find.text('획')), findsOneWidget);
    expect(
      tester.widget<KitIcon>(inside(barKey(_chip), find.byType(KitIcon))).name,
      KitIconName.eraseStroke,
    );
    expect(tooltipOf(tester, _chip), '지우개 종류: 획 지우개');
    expect(tooltipOf(tester, _advanced), '고급 설정');
    expect(
      tester
          .widget<KitIcon>(inside(barKey(_advanced), find.byType(KitIcon)))
          .name,
      KitIconName.toggles,
    );
    expect(tooltipOf(tester, _size(10)), '크기 작게');
    expect(tooltipOf(tester, _size(40)), '크기 중간');
    expect(tooltipOf(tester, _size(80)), '크기 크게');
    // the size in hand is ringed
    expect(_ringed(tester), [40]);
    // a size is taken at once, the slider's number with it
    await tester.tap(barKey(_size(80)));
    await tester.pump();
    expect(_level(), 80);
    expect(_ringed(tester), [80]);
  });

  testWidgets('circle select does not use the size: the sizes are dimmed', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    _setLevel(40);
    stows.eraserMode.value = EraserMode.lasso;
    await pumpBar(tester, Eraser());
    expect(inside(barKey(_chip), find.text('원형')), findsOneWidget);
    expect(tooltipOf(tester, _chip), '지우개 종류: 원형 선택 지우기');
    expect(
      tester.widget<KitIcon>(inside(barKey(_chip), find.byType(KitIcon))).name,
      KitIconName.eraseLasso,
    );
    for (final level in KitTokens.eraserSizePresets) {
      expect(opacityOf(tester, _size(level)), KitTokens.disabledOpacity);
      expect(
        _semantics(tester, _size(level)).flagsCollection.isEnabled,
        Tristate.isFalse,
      );
      expect(
        _semantics(tester, _size(level)).hasAction(SemanticsAction.tap),
        isFalse,
      );
    }
    await tester.tap(barKey(_size(80)), warnIfMissed: false);
    await tester.pump();
    expect(_level(), 40);
    // the slider in 「고급 설정」 is dimmed too
    await _open(tester, _advanced);
    expect(tester.widget<KitSlider>(_slider).enabled, isFalse);
    handle.dispose();
  });

  testWidgets('the sizes are the slider\'s shortcuts: 25 rings none', (
    tester,
  ) async {
    // an old size between the presets stays as it is, ringing none
    await pumpBar(tester, Eraser());
    final before = stows.eraserSize.value;
    expect(_ringed(tester), isEmpty);
    await _open(tester, _advanced);
    expect(tester.widget<KitSlider>(_slider).value, _level());
    await _closeWindow(tester);
    expect(stows.eraserSize.value, before);

    // 40 from the bar, then 25 on the slider (−5 three times)
    await tester.tap(barKey(_size(40)));
    await tester.pump();
    await _open(tester, _advanced);
    expect(tester.widget<KitSlider>(_slider).value, 40);
    final less = inside(_slider, find.byTooltip('작게'));
    for (var i = 0; i < 3; i++) {
      await tester.tap(less);
      await tester.pumpAndSettle();
    }
    expect(_level(), 25);
    await _closeWindow(tester);
    expect(_ringed(tester), isEmpty);
    // a preset sets the slider
    await tester.tap(barKey(_size(10)));
    await tester.pump();
    expect(_ringed(tester), [10]);
    await _open(tester, _advanced);
    expect(tester.widget<KitSlider>(_slider).value, 10);
  });

  testWidgets('the chip opens 지우개 종류: two cards and what they do', (
    tester,
  ) async {
    await pumpBar(tester, Eraser());
    await _open(tester, _chip);
    expect(inside(_typePanel, find.text('지우개 종류')), findsOneWidget);
    // stage 1: the stroke eraser and circle select, no 「일반 지우개」 card
    final stroke = find.byKey(const ValueKey('eraser-kind-stroke'));
    final circle = find.byKey(const ValueKey('eraser-kind-lasso'));
    expect(inside(_typePanel, find.text('획 지우개')), findsOneWidget);
    expect(inside(_typePanel, find.text('원형 선택 지우기')), findsOneWidget);
    expect(inside(_typePanel, find.text('일반 지우개')), findsNothing);
    expect(
      tester.getSemantics(stroke).flagsCollection.isSelected,
      Tristate.isTrue,
    );
    final help = find.byKey(const ValueKey('eraser-kind-help'));
    expect(
      inside(help, find.text(keepWords('닿은 획 하나를 통째로 지웁니다.'))),
      findsOneWidget,
    );
    // 300 wide, its middle under the chip's, 10 under the chip
    final window = tester.getRect(_typePanel);
    final chip = tester.getRect(barKey(_chip));
    expect(window.width, 300);
    expect(window.top, chip.bottom + 10);
    expect(
      tester.getCenter(find.byKey(const ValueKey('kit-popover-nub'))).dx,
      closeTo(chip.center.dx, 0.01),
    );
    await tester.tap(circle);
    await tester.pumpAndSettle();
    expect(stows.eraserMode.value, EraserMode.lasso);
    expect(
      inside(help, find.text(keepWords('둘러 그린 안쪽을 한꺼번에 지웁니다.'))),
      findsOneWidget,
    );
    await _closeWindow(tester);
    expect(inside(barKey(_chip), find.text('원형')), findsOneWidget);
  });

  testWidgets('고급 설정: size, four targets, auto release, clear page', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final host = await pumpBar(tester, Eraser());
    var cleared = 0;
    host.actions.publish(host, [
      host.undo(),
      host.redo(enabled: false),
      AppAction(
        id: AppActionIds.clearPage,
        label: '쪽 지우기',
        icon: KitIconName.eraser,
        run: (_) => cleared++,
      ),
    ]);
    await tester.pump();
    await _open(tester, _advanced);
    expect(inside(_advancedPanel, find.text('고급 설정')), findsOneWidget);
    // its middle under the button's, 10 under it
    final button = tester.getRect(barKey(_advanced));
    expect(
      tester.getCenter(_advancedPanel).dx,
      closeTo(button.center.dx, 0.01),
    );
    expect(tester.getTopLeft(_advancedPanel).dy, button.bottom + 10);
    expect(tester.widget<KitSlider>(_slider).enabled, isTrue);
    // 크기 above 지울 대상
    expect(
      tester.getTopLeft(_slider).dy,
      lessThan(tester.getTopLeft(find.text('지울 대상')).dy),
    );
    // the four targets in order, each with its icon; no 테이프
    final rows = [
      for (final kind in StrokeKind.values)
        find.byKey(ValueKey('eraser-target-${kind.name}')),
    ];
    final names = ['펜', '연필', '형광펜', '도형'];
    final icons = [
      KitIconName.pen,
      KitIconName.pencil,
      KitIconName.marker,
      KitIconName.shapes,
    ];
    for (final (i, row) in rows.indexed) {
      expect(tester.getSemantics(row).label, names[i]);
      expect(
        tester.getSemantics(row).flagsCollection.isToggled,
        Tristate.isTrue,
      );
      expect(
        tester.widget<KitIcon>(inside(row, find.byType(KitIcon))).name,
        icons[i],
      );
      if (i > 0) {
        expect(tester.getTopLeft(row).dy, tester.getBottomLeft(rows[i - 1]).dy);
      }
      expect(tester.getSize(row).height, 44);
    }
    expect(inside(_advancedPanel, find.text('테이프')), findsNothing);
    expect(find.text(keepWords('꺼 둔 대상의 흔적은 지우지 않습니다.')), findsOneWidget);
    // a target off
    await tester.tap(rows[1]);
    await tester.pump();
    expect(
      EraserTargets.value,
      StrokeKind.values.toSet()..remove(StrokeKind.pencil),
    );
    expect(
      tester.getSemantics(rows[1]).flagsCollection.isToggled,
      Tristate.isFalse,
    );
    // 자동 해제
    final auto = find.byKey(const ValueKey('eraser-auto-release'));
    expect(tester.getSemantics(auto).label, '자동 해제');
    expect(find.text(keepWords('지우고 나면 전에 쓰던 도구로 돌아갑니다.')), findsOneWidget);
    await tester.tap(auto);
    await tester.pump();
    expect(stows.disableEraserAfterUse.value, isTrue);
    // 쪽 지우기 asks first
    final clear = find.byKey(const ValueKey('eraser-clear-page'));
    expect(
      tester.widget<Text>(inside(clear, find.text('쪽 지우기'))).style?.color,
      KitTokens.danger,
    );
    await tester.tap(clear);
    await tester.pumpAndSettle();
    expect(cleared, 0);
    await tester.tap(find.byKey(const ValueKey('eraser-clear-page-cancel')));
    await tester.pumpAndSettle();
    expect(cleared, 0);
    expect(
      find.byKey(const ValueKey('eraser-clear-page-confirm')),
      findsNothing,
    );
    await _open(tester, _advanced);
    await tester.tap(find.byKey(const ValueKey('eraser-clear-page')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('eraser-clear-page-confirm')));
    await tester.pumpAndSettle();
    expect(cleared, 1);
    handle.dispose();
  });

  testWidgets('쪽 지우기 asks in a kit window, not a Material dialog', (
    tester,
  ) async {
    final host = await pumpBar(tester, Eraser());
    host.actions.publish(host, [
      AppAction(
        id: AppActionIds.clearPage,
        label: '쪽 지우기',
        icon: KitIconName.eraser,
        run: (_) {},
      ),
    ]);
    await tester.pump();
    await _open(tester, _advanced);
    await tester.tap(find.byKey(const ValueKey('eraser-clear-page')));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    final window = find.ancestor(
      of: find.byKey(const ValueKey('eraser-clear-page-confirm')),
      matching: find.byType(ToolWindow),
    );
    expect(window, findsOneWidget);
    expect(tester.widget<ToolWindow>(window).title, '쪽 지우기');
    expect(
      inside(
        window,
        find.text(keepWords('이 쪽의 필기와 사진을 모두 지웁니다. 실행 취소로 되돌릴 수 있습니다.')),
      ),
      findsOneWidget,
    );
    // the kit window's surface: the tool windows' colour and corner
    final surface = tester.widget<DecoratedBox>(
      find
          .ancestor(of: window, matching: find.byType(DecoratedBox))
          .first,
    );
    final decoration = surface.decoration as BoxDecoration;
    expect(decoration.color, KitTokens.menuBg);
    expect(
      decoration.borderRadius,
      BorderRadius.circular(KitTokens.penPanelRadius),
    );
    // as the floating bar's tool windows: the menu shadow, no outline
    expect(decoration.boxShadow, KitTokens.menuShadow);
    expect(decoration.border, isNull);
    // a dangerous step keeps a dim behind it, the kit's light one
    expect(
      tester.widgetList<ModalBarrier>(find.byType(ModalBarrier)).last.color,
      KitTokens.customizeScrim,
    );
    expect(
      tester
          .widget<Text>(
            inside(
              find.byKey(const ValueKey('eraser-clear-page-confirm')),
              find.text('지우기'),
            ),
          )
          .style
          ?.color,
      KitTokens.danger,
    );
    // final review design call 1: the safe 「취소」 stands out (600, ink),
    // 「지우기」 stays 400 red, a 1 px line in the window's line colour
    // between the two 44 rows
    TextStyle? styleOf(String key, String text) => tester
        .widget<Text>(inside(find.byKey(ValueKey(key)), find.text(text)))
        .style;
    expect(
      styleOf('eraser-clear-page-confirm', '지우기')?.fontWeight,
      FontWeight.w400,
    );
    expect(
      styleOf('eraser-clear-page-cancel', '취소')?.fontWeight,
      FontWeight.w600,
    );
    expect(
      styleOf('eraser-clear-page-cancel', '취소')?.color,
      KitTokens.menuInk,
    );
    final confirm = tester.getRect(
      find.byKey(const ValueKey('eraser-clear-page-confirm')),
    );
    final cancel = tester.getRect(
      find.byKey(const ValueKey('eraser-clear-page-cancel')),
    );
    final divider = find.byKey(const ValueKey('eraser-clear-page-divider'));
    expect(divider, findsOneWidget);
    final line = tester.getRect(divider);
    expect(line.height, 1);
    expect(line.top, confirm.bottom);
    expect(line.bottom, cancel.top);
    expect(line.width, tester.getSize(window).width);
    expect(
      tester
          .widget<ColoredBox>(
            find.descendant(of: divider, matching: find.byType(ColoredBox)),
          )
          .color,
      KitTokens.toolLineColor,
    );
    expect(confirm.height, greaterThanOrEqualTo(44));
    expect(cancel.height, greaterThanOrEqualTo(44));
    await tester.tap(find.byKey(const ValueKey('eraser-clear-page-cancel')));
    await tester.pumpAndSettle();
    expect(find.byType(ToolWindow), findsNothing);
  });

  testWidgets('the last target stays on and says why in red', (tester) async {
    final handle = tester.ensureSemantics();
    stows.eraserTargets.value = ['highlighter'];
    await pumpBar(tester, Eraser());
    await _open(tester, _advanced);
    final highlighter = find.byKey(const ValueKey('eraser-target-highlighter'));
    final message = find.byKey(const ValueKey('eraser-target-message'));
    const why = '지울 대상은 하나 이상 있어야 합니다. 다른 대상을 먼저 켜세요.';
    expect(message, findsNothing);
    final data = tester.getSemantics(highlighter).getSemanticsData();
    expect(data.flagsCollection.isToggled, Tristate.isTrue);
    expect(data.flagsCollection.isEnabled, Tristate.isFalse);
    expect(data.hint, why);
    await tester.tap(highlighter);
    await tester.pump();
    expect(EraserTargets.value, {StrokeKind.highlighter});
    // read out as written, without the word joiners that keep words whole
    String spoken(Finder of) => tester
        .getSemantics(find.descendant(of: of, matching: find.byType(KitText)))
        .label;
    expect(spoken(message), why);
    expect(
      spoken(find.byKey(const ValueKey('eraser-target-help'))),
      '꺼 둔 대상의 흔적은 지우지 않습니다.',
    );
    expect(inside(message, find.text(keepWords(why))), findsOneWidget);
    expect(
      tester
          .widget<Text>(inside(message, find.text(keepWords(why))))
          .style
          ?.color,
      KitTokens.danger,
    );
    // another one on: the note goes, the highlighter may go off again
    await tester.tap(find.byKey(const ValueKey('eraser-target-pen')));
    await tester.pump();
    expect(message, findsNothing);
    expect(EraserTargets.value, {StrokeKind.pen, StrokeKind.highlighter});
    expect(
      tester.getSemantics(highlighter).flagsCollection.isEnabled,
      Tristate.isTrue,
    );
    handle.dispose();
  });

  testWidgets('「형광펜만 지우기」 users start with the highlighter alone', (
    tester,
  ) async {
    stows.eraseHighlighterOnly.value = true;
    await pumpBar(tester, Eraser());
    await _open(tester, _advanced);
    for (final kind in StrokeKind.values) {
      expect(
        tester
            .getSemantics(find.byKey(ValueKey('eraser-target-${kind.name}')))
            .flagsCollection
            .isToggled,
        kind == StrokeKind.highlighter ? Tristate.isTrue : Tristate.isFalse,
        reason: kind.name,
      );
    }
  });

  testWidgets('a phone: the bar slides, the windows stay on the page and '
      'scroll inside', (tester) async {
    // narrower than the bar: one row, the tools slide inside their pill
    await pumpBar(tester, Eraser(), screen: const Size(300, 600));
    expect(tester.takeException(), isNull);
    expect(tester.getRect(floatingBar).right, lessThanOrEqualTo(300 - 10));
    final scroll = tester.state<ScrollableState>(
      inside(toolPill, find.byType(Scrollable)),
    );
    expect(scroll.position.maxScrollExtent, greaterThan(0));
    // a short phone page: 「고급 설정」 keeps 8 from the page's edges and
    // slides inside
    final host = await pumpBar(tester, Eraser(), screen: const Size(360, 480));
    host.actions.publish(host, [
      host.undo(),
      AppAction(
        id: AppActionIds.clearPage,
        label: '쪽 지우기',
        icon: KitIconName.eraser,
        run: (_) {},
      ),
    ]);
    await tester.pump();
    await _open(tester, _advanced);
    final view = find.ancestor(
      of: _advancedPanel,
      matching: find.byType(SingleChildScrollView),
    );
    final box = tester.getRect(view.first);
    expect(box.left, greaterThanOrEqualTo(8));
    expect(box.right, lessThanOrEqualTo(360 - 8));
    expect(box.bottom, lessThanOrEqualTo(480 - 8));
    final inner = tester.state<ScrollableState>(
      find.descendant(of: view.first, matching: find.byType(Scrollable)).first,
    );
    expect(inner.position.maxScrollExtent, greaterThan(0));
    // more below: the foot fades (10th draft fix 1, `.e10in.more`)
    final fade = find.byKey(const ValueKey('kit-popover-fade'));
    expect(fade, findsOneWidget);
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('eraser-clear-page')),
      40,
      scrollable: find
          .descendant(of: view.first, matching: find.byType(Scrollable))
          .first,
    );
    expect(
      tester.getRect(find.byKey(const ValueKey('eraser-clear-page'))).bottom,
      lessThanOrEqualTo(box.bottom + 0.01),
    );
    // at the end nothing is below: no fade
    await tester.pumpAndSettle();
    expect(fade, findsNothing);
  });

  testWidgets('notes break between words, as the preview (keep-all)', (
    tester,
  ) async {
    // 30 glyphs of the test font (12 each) reach 「먼」: a syllable break
    // would split 「먼저」 there
    await tester.pumpWidget(
      MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 30 * 12 + 2 * KitTokens.toolWindowPadH,
            child: toolWindowMessage(
              KitEraserAdvancedPanel.keepOne,
              key: const ValueKey('message'),
            ),
          ),
        ),
      ),
    );
    final paragraph = tester.renderObject<RenderParagraph>(
      find.descendant(
        of: find.byKey(const ValueKey('message')),
        matching: find.byType(RichText),
      ),
    );
    final text = paragraph.text.toPlainText();
    final lines = paragraph.getBoxesForSelection(
      TextSelection(baseOffset: 0, extentOffset: text.length),
    );
    final tops = lines.map((b) => b.top).toSet().toList()..sort();
    expect(tops.length, greaterThan(1), reason: 'it wraps at this width');
    // every line after the first starts after a space
    for (final top in tops.skip(1)) {
      final start = paragraph.getPositionForOffset(Offset(0, top + 1)).offset;
      expect(text[start - 1], ' ', reason: 'a line starts inside a word');
    }
  });

  testWidgets('opening and closing the windows does not repaint the page', (
    tester,
  ) async {
    final host = await pumpBar(tester, Eraser());
    final paints = host.paints;
    final builds = host.builds;
    for (final key in [_chip, _advanced]) {
      await _open(tester, key);
      await _closeWindow(tester);
    }
    expect(host.paints, paints);
    expect(host.builds, builds);
  });
}
