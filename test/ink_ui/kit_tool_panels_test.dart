import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/ink_ui/pen_panel/kit_pen_panel.dart';
import 'package:saber/components/kit/kit_controls.dart';
import 'package:saber/components/kit/kit_icon.dart';
import 'package:saber/components/kit/kit_motion.dart';
import 'package:saber/components/kit/kit_pen_art.dart';
import 'package:saber/components/kit/kit_text.dart';
import 'package:saber/components/kit/kit_tokens.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/ink/pen_prefs.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/tools/highlighter.dart';
import 'package:saber/data/tools/pen.dart';

import 'pen_panel_harness.dart';

// user change 1 (2026-11-20, preview v8k line 2429): one line, so the panel
// is as high with the straight line on as blocked
const _note = '선을 수평·수직 중 가까운 쪽으로 맞춥니다.';
const _blockedNote = '먼저 위의 ‘직선 자동 보정’을 켜세요.';
const _stabNote = '높을수록 선이 부드럽고 약간 늦게 따라갑니다.';

final _stabiliser = find.byKey(const ValueKey('tool-panel-stabiliser'));
final _axis = find.byKey(const ValueKey('tool-panel-axis-lock'));

Finder _in(Finder of, Finder f) => find.descendant(of: of, matching: f);

Finder _key(String k) => find.byKey(ValueKey(k));

/// The lines of [data] (a [KitLines]).
Finder _lines(String data) =>
    find.byWidgetPredicate((w) => w is KitLines && w.data == data);

/// The stabiliser's value at the end of its title row.
String _stabValue(WidgetTester tester) =>
    tester.widget<KitText>(_key('tool-panel-stabiliser-value')).data;

/// The nearest [Opacity] above [f] that is still inside [within].
double _opacity(WidgetTester tester, Finder within, Finder f) {
  final fades = _in(
    within,
    find.ancestor(of: f, matching: find.byType(Opacity)),
  );
  return fades.evaluate().isEmpty
      ? 1
      : tester.widget<Opacity>(fades.first).opacity;
}

void main() {
  FlavorConfig.setup();
  tearDown(resetPenPanelState);

  testWidgets('stabiliser row edits the pen streamline', (tester) async {
    final pen = CountingPen(Pen.fountainPen());
    Pen.currentPen = pen;
    final host = await pumpHost(tester, pen);
    await openPanel(tester, host);
    expect(_in(_stabiliser, _lines('스트로크 안정화')), findsOneWidget);
    // the number on the thumb, the unit with it at the title row's end
    expect(sliderNumber(tester, _stabiliser), '50');
    expect(_stabValue(tester), '50%');
    final builds = host.builds;
    final gesture = await tester.startGesture(
      tester.getCenter(
        _in(_stabiliser, find.byKey(const Key('kit-slider-thumb'))),
      ),
    );
    await tester.pump();
    // held, the pill shows the preview's default dot (`.th .td`: 6, #1f2329)
    await tester.pump(KitMotion.sliderGrow);
    await tester.pump();
    final mark = _in(_stabiliser, find.byKey(const Key('kit-slider-mark')));
    expect(tester.getSize(mark), const Size.square(KitTokens.sliderMarkSize));
    expect(
      (tester.widget<DecoratedBox>(mark).decoration as BoxDecoration).color,
      KitTokens.sliderMarkInk,
    );
    for (var i = 0; i < 3; i++) {
      await gesture.moveBy(const Offset(15, 0));
      await tester.pump();
    }
    // 45 px is 30 points: shown on the 10 % grid, the title row's value
    // with it, nothing kept while held
    expect(sliderNumber(tester, _stabiliser), '80');
    expect(_stabValue(tester), '80%');
    expect(pen.streamlines, isEmpty);
    expect(host.builds, builds);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(pen.streamlines, [0.8]);
    expect(pen.options.streamline, 0.8);
    expect(stows.lastFountainPenOptions.value.streamline, 0.8);
    expect(sliderNumber(tester, _stabiliser), '80');
    expect(_stabValue(tester), '80%');
    expect(host.builds, builds);
    // the minus takes 10 off and keeps it once
    await tester.tap(_in(_stabiliser, iconNamed(KitIconName.minus)));
    await tester.pumpAndSettle();
    expect(pen.streamlines, [0.8, 0.7]);
    expect(sliderNumber(tester, _stabiliser), '70');
    expect(_stabValue(tester), '70%');
    expect(pen.sizes, isEmpty);
    // the pencil brings its own stabilisation
    await tester.tap(penColumn(KitPenKind.pencil));
    await tester.pumpAndSettle();
    expect(sliderNumber(tester, _stabiliser), '10');
    expect(_stabValue(tester), '10%');
    expect(host.builds, builds);
  });

  testWidgets('stabiliser row follows its pen setting changed elsewhere', (
    tester,
  ) async {
    Pen.currentPen = Pen.fountainPen();
    final host = await pumpHost(tester, Pen.currentPen);
    await openPanel(tester, host);
    expect(_stabValue(tester), '50%');
    // the fine-nib pen's saved options, changed while the panel is open
    stows.lastFountainPenOptions.value = stows.lastFountainPenOptions.value
        .copyWith(streamline: 0.3);
    await tester.pumpAndSettle();
    expect(sliderNumber(tester, _stabiliser), '30');
    expect(_stabValue(tester), '30%');
    // with the pencil in hand it follows the pencil's setting, not the pen's
    await tester.tap(penColumn(KitPenKind.pencil));
    await tester.pumpAndSettle();
    expect(_stabValue(tester), '10%');
    stows.lastFountainPenOptions.value = stows.lastFountainPenOptions.value
        .copyWith(streamline: 0.9);
    await tester.pumpAndSettle();
    expect(_stabValue(tester), '10%');
    stows.lastPencilOptions.value = stows.lastPencilOptions.value.copyWith(
      streamline: 0.6,
    );
    await tester.pumpAndSettle();
    expect(sliderNumber(tester, _stabiliser), '60');
    expect(_stabValue(tester), '60%');
    expect(host.tools, hasLength(1));
  });

  testWidgets('stabiliser row names its ends like the preview', (tester) async {
    final handle = tester.ensureSemantics();
    final host = await pumpHost(tester, Pen.currentPen);
    await openPanel(tester, host);
    expect(
      tester
          .getSemantics(
            _in(_stabiliser, find.byKey(const Key('kit-slider-track'))),
          )
          .label,
      '스트로크 안정화',
    );
    expect(find.bySemanticsLabel('안정화 줄이기'), findsOneWidget);
    expect(find.bySemanticsLabel('안정화 늘리기'), findsOneWidget);
    // the value with its unit (`aria-valuetext`); the title row's copy of it
    // is not read out twice
    expect(
      tester
          .getSemantics(
            _in(_stabiliser, find.byKey(const Key('kit-slider-track'))),
          )
          .getSemanticsData()
          .value,
      '50%',
    );
    expect(find.bySemanticsLabel('50%'), findsNothing);
    expect(find.bySemanticsLabel(_stabNote), findsOneWidget);
    handle.dispose();
  });

  testWidgets('axis lock is disabled until straight line is on', (
    tester,
  ) async {
    final host = await pumpHost(tester, Highlighter.currentHighlighter);
    await openPanel(tester, host, kind: KitPenPanelKind.highlighters);
    KitToggleRow axis() => tester.widget<KitToggleRow>(_axis);
    expect(axis().label, '수평/수직 그리기');
    // blocked, the note says what to do first (design review I-1)
    expect(axis().description, _blockedNote);
    expect(axis().value, isFalse);
    expect(axis().onChanged, isNull);
    await tester.tap(_axis);
    await tester.pump();
    expect(axisLockOf(KitPenKind.highlighterChisel), isFalse);
    // dim like `.tg.dis`: the name and the switch, not the note
    expect(
      _opacity(tester, _axis, _lines('수평/수직 그리기')),
      KitTokens.disabledOpacity,
    );
    expect(
      _opacity(tester, _axis, find.byType(KitSwitch)),
      KitTokens.disabledOpacity,
    );
    expect(_opacity(tester, _axis, _lines(_blockedNote)), 1);
    // with the straight line on it can be pressed and says what it does; the
    // panel keeps its height (user change 1: both notes are as long)
    Size panel() => tester.getSize(find.byKey(const ValueKey('kit-pen-panel')));
    final blocked = panel();
    await tester.tap(find.byKey(const ValueKey('toolbar-auto-straighten')));
    await tester.pump();
    expect(straightLineOf(KitPenKind.highlighterChisel), isTrue);
    expect(axis().onChanged, isNotNull);
    expect(axis().description, _note);
    expect(_opacity(tester, _axis, _lines(_note)), 1);
    expect(panel(), blocked);
    expect(_opacity(tester, _axis, find.byType(KitSwitch)), 1);
    await tester.tap(_axis);
    await tester.pump();
    expect(axisLockOf(KitPenKind.highlighterChisel), isTrue);
    expect(axis().value, isTrue);
    // the straight line turned off elsewhere: dim again, the lock is kept
    setStraightLine(KitPenKind.highlighterChisel, false);
    await tester.pump();
    expect(axis().onChanged, isNull);
    expect(axis().description, _blockedNote);
    expect(axis().value, isTrue);
    expect(axisLockOf(KitPenKind.highlighterChisel), isTrue);
    // the lock turned off elsewhere shows too
    setAxisLock(KitPenKind.highlighterChisel, false);
    await tester.pump();
    expect(axis().value, isFalse);
    // the pen panel has the same row for its pen (the controller's ruling:
    // every ink pen with the straight-line switch), dimmed while that pen's
    // straight line is off
    await closePanel(tester);
    host.tool = Pen.currentPen;
    await openPanel(tester, host);
    expect(_axis, findsOneWidget);
    expect(axis().description, _blockedNote);
    expect(axis().onChanged, isNull);
    expect(
      _opacity(tester, _axis, find.byType(KitSwitch)),
      KitTokens.disabledOpacity,
    );
    setStraightLine(KitPenKind.fountain, true);
    await tester.pump();
    expect(axis().onChanged, isNotNull);
    expect(axis().description, _note);
  });

  testWidgets(
    'the stabiliser and the axis rows sit where the preview has them',
    (tester) async {
      final host = await pumpHost(tester, Pen.currentPen);
      await openPanel(tester, host);
      var panel = tester.getRect(find.byKey(const ValueKey('kit-pen-panel')));
      Rect box(Finder f) => tester.getRect(f).shift(-panel.topLeft);
      // `.stab` 16 under the page dots (328..333): its line at 349 across
      // 278, the title row 6 + 17.5 with the value at its end (x 285), the
      // note 2 under it on its 15.4 line, the slider row 46 with the track at
      // x 62 (v8f 516.89 less the line-type row the stage hides)
      // (the note is one line with the app's fonts, maybe two with the test
      // font: 455.5 + 15.4 a line)
      final noteLines = find
          .descendant(of: _lines(_stabNote), matching: find.byType(Text))
          .evaluate()
          .length;
      // the 수평/수직 row under the straight-line row (the controller's
      // ruling) moves what is below it down by its height
      final penAxis = box(_axis);
      expect(
        penAxis.top,
        closeTo(box(_key('toolbar-auto-straighten')).bottom, 1e-9),
      );
      final down = penAxis.height;
      expect(panel.width, 300);
      expect(panel.height, closeTo(455.5 + down + 15.4 * noteLines, 1e-9));
      final stab = box(_stabiliser);
      expect(stab.topLeft, Offset(11, 349 + down));
      expect(stab.width, 278);
      expect(stab.height, closeTo(76.5 + 15.4 * noteLines, 1e-9));
      final title = box(_in(_stabiliser, _lines('스트로크 안정화')));
      expect(title.topLeft, Offset(15, 349 + down + 1 + 4 + 6));
      expect(title.height, closeTo(17.5, 1e-9));
      // on the title's line: both rounded lines end at the line box's foot
      final value = box(_key('tool-panel-stabiliser-value'));
      expect(value.right, closeTo(285, 1e-9));
      expect(value.bottom, closeTo(title.bottom, 1e-9));
      final note = box(_in(_stabiliser, _lines(_stabNote)));
      expect(note.left, 15);
      expect(note.top, closeTo(title.bottom + 2, 1e-9));
      expect(note.height, closeTo(15.4 * noteLines, 1e-9));
      final track = box(
        _in(_stabiliser, find.byKey(const Key('kit-slider-track'))),
      );
      expect(track.left, 62);
      expect(track.center.dy, closeTo(note.bottom + 23, 1e-9));
      // the page dots keep their place above it
      expect(box(pageDot(0)).center.dy, closeTo(330.5 + down, 1e-9));
      await closePanel(tester);

      host.tool = Highlighter.currentHighlighter;
      await openPanel(tester, host, kind: KitPenPanelKind.highlighters);
      panel = tester.getRect(find.byKey(const ValueKey('kit-pen-panel')));
      // under the straight-line row: the name's 17.5 line and the switch at
      // the top (11 in, the switch 1 lower), the note's 15.4 lines 2 under
      // the name; blocked, the note is one line with the app's fonts: 56.9
      // (v8f 56.89); stage 2's opacity row (46) sits above it
      final axisLines = find
          .descendant(of: _lines(_blockedNote), matching: find.byType(Text))
          .evaluate()
          .length;
      final axis = box(_axis);
      expect(axis.topLeft, const Offset(15, 265 + 46));
      expect(axis.width, 270);
      expect(axis.height, closeTo(11 + 17.5 + 2 + 15.4 * axisLines + 11, 1e-9));
      expect(
        box(_in(_axis, find.byType(KitSwitch))).topLeft,
        const Offset(253, 277 + 46),
      );
      final name = box(_in(_axis, _lines('수평/수직 그리기')));
      expect(name.top, 276 + 46);
      expect(
        box(_in(_axis, _lines(_blockedNote))).top,
        closeTo(name.bottom + 2, 1e-9),
      );
      // the colours 4 under it
      expect(
        box(find.byKey(const ValueKey('pen-panel-colors'))).top,
        closeTo(axis.bottom + KitTokens.penPanelColorsTop, 1e-9),
      );
      expect(panel.height, closeTo(363 + 46 + axis.height, 1e-9));
    },
  );
}
