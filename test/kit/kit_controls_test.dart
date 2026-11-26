import 'dart:ui' show SemanticsAction, Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/kit/kit_controls.dart';
import 'package:saber/components/kit/kit_icon.dart';
import 'package:saber/components/kit/kit_motion.dart';
import 'package:saber/components/kit/kit_text.dart';
import 'package:saber/components/kit/kit_tokens.dart';

const _screen = Size(400, 600);
const _track = Key('kit-slider-track');
const _thumb = Key('kit-slider-thumb');

void _size(WidgetTester tester) {
  tester.view.physicalSize = _screen;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

class _Rec {
  final changes = <int>[];
  final ends = <int>[];
  var value = 50;
}

Future<_Rec> _slider(
  WidgetTester tester, {
  int start = 50,
  bool disableAnimations = false,
  double Function(int)? markDiameter,
}) async {
  _size(tester);
  final rec = _Rec()..value = start;
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(
          size: _screen,
          disableAnimations: disableAnimations,
        ),
        child: Scaffold(
          body: Center(
            child: StatefulBuilder(
              builder: (context, setState) => KitSlider(
                value: rec.value,
                markDiameter: markDiameter,
                onChanged: (v) {
                  rec.changes.add(v);
                  setState(() => rec.value = v);
                },
                onChangeEnd: rec.ends.add,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  return rec;
}

/// Where value [v] sits on screen, by the plan's formula.
double _xOf(WidgetTester tester, int v, {int min = 1, int max = 100}) {
  final box = tester.getRect(find.byKey(_track));
  const r = KitTokens.sliderThumb / 2;
  final x0 = box.left + r;
  final x1 = box.right - r;
  return x0 + (v - min) / (max - min) * (x1 - x0);
}

double _thumbX(WidgetTester tester) => tester.getCenter(find.byKey(_thumb)).dx;

double _thumbHeight(WidgetTester tester) =>
    tester.getRect(find.byKey(_thumb)).height;

Finder _iconNamed(KitIconName n) =>
    find.byWidgetPredicate((w) => w is KitIcon && w.name == n);

void main() {
  _more();
  testWidgets('slider track is 176 wide and hits 44 high', (tester) async {
    await _slider(tester);
    final box = tester.getRect(find.byKey(_track));
    expect(box.width, KitTokens.sliderTrackWidth);
    expect(box.height, KitTokens.sliderHitHeight);
    expect(tester.getSize(find.byKey(_thumb)).width, KitTokens.sliderThumb);
    expect(_thumbX(tester), closeTo(_xOf(tester, 50), 0.01));
  });

  testWidgets('slider steps by 5 with the minus and plus buttons', (
    tester,
  ) async {
    final rec = await _slider(tester);
    await tester.tap(_iconNamed(KitIconName.plus));
    await tester.pumpAndSettle();
    expect(rec.changes, [55]);
    expect(rec.ends, [55]);
    await tester.tap(_iconNamed(KitIconName.minus));
    await tester.pumpAndSettle();
    expect(rec.value, 50);
    expect(rec.ends, [55, 50]);
  });

  testWidgets('minus and plus are 32 icons in 36 boxes 7 from the track', (
    tester,
  ) async {
    // `.snp .srow` (line 578): 36 + 176 + 36 spread over 262, so 7 apart
    await _slider(tester);
    for (final n in [KitIconName.minus, KitIconName.plus]) {
      final icon = tester.widget<KitIcon>(_iconNamed(n));
      expect(icon.size, 32);
      expect(icon.strokeWidth, closeTo(1.1685, 1e-4));
    }
    final track = tester.getRect(find.byKey(_track));
    final minus = tester.getRect(_iconNamed(KitIconName.minus));
    final plus = tester.getRect(_iconNamed(KitIconName.plus));
    expect(track.left - (minus.right + 2), 7);
    expect(plus.left - 2 - track.right, 7);
  });

  testWidgets('minus and plus take the names they are given', (tester) async {
    final handle = tester.ensureSemantics();
    _size(tester);
    Future<void> pump({String? lower, String? higher, String? label}) =>
        tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: KitSlider(
                  value: 50,
                  onChanged: (_) {},
                  label: label,
                  decreaseLabel: lower ?? KitIconName.minus.label,
                  increaseLabel: higher ?? KitIconName.plus.label,
                ),
              ),
            ),
          ),
        );
    await pump();
    expect(find.bySemanticsLabel('빼기'), findsOneWidget);
    expect(find.bySemanticsLabel('더하기'), findsOneWidget);
    await pump(lower: '가늘게', higher: '굵게', label: '굵기');
    expect(find.bySemanticsLabel('가늘게'), findsOneWidget);
    expect(find.bySemanticsLabel('굵게'), findsOneWidget);
    expect(find.byTooltip('가늘게'), findsOneWidget);
    expect(find.byTooltip('굵게'), findsOneWidget);
    expect(tester.getSemantics(find.byKey(_track)).label, '굵기');
    handle.dispose();
  });

  testWidgets('minus is grey and dead at the minimum, plus at the maximum', (
    tester,
  ) async {
    KitIcon icon(KitIconName n) => tester.widget<KitIcon>(_iconNamed(n));
    final rec = await _slider(tester, start: 1);
    expect(icon(KitIconName.minus).color, KitTokens.stepperDisabled);
    expect(icon(KitIconName.plus).color, isNot(KitTokens.stepperDisabled));
    await tester.tap(_iconNamed(KitIconName.minus));
    await tester.pumpAndSettle();
    expect(rec.changes, isEmpty);
    expect(rec.ends, isEmpty);
    expect(rec.value, 1);

    final rec2 = await _slider(tester, start: 100);
    expect(icon(KitIconName.plus).color, KitTokens.stepperDisabled);
    await tester.tap(_iconNamed(KitIconName.plus));
    await tester.pumpAndSettle();
    expect(rec2.changes, isEmpty);
    expect(rec2.value, 100);
  });

  testWidgets('dragging the slider thumb follows the finger', (tester) async {
    final rec = await _slider(tester);
    final g = await tester.startGesture(Offset(_xOf(tester, 50), 300));
    await tester.pump();
    // grabbing alone changes nothing
    expect(rec.changes, isEmpty);

    final mid = _xOf(tester, 75);
    await g.moveTo(Offset(mid, 300));
    await tester.pump();
    expect(rec.changes.last, 75);
    expect(_thumbX(tester), closeTo(mid, 0.01));

    await g.moveTo(Offset(_xOf(tester, 100) + 80, 300));
    await tester.pump();
    expect(rec.changes.last, 100);
    // the thumb stops at the end of the track
    expect(_thumbX(tester), closeTo(_xOf(tester, 100), 0.01));
    await g.up();
    await tester.pumpAndSettle();
    expect(rec.value, 100);
  });

  testWidgets('a grabbed thumb keeps the offset to the finger', (tester) async {
    final rec = await _slider(tester);
    final start = _xOf(tester, 50);
    final g = await tester.startGesture(Offset(start + 8, 300));
    await g.moveTo(Offset(_xOf(tester, 60) + 8, 300));
    await tester.pump();
    expect(rec.changes.last, 60);
    await g.up();
  });

  testWidgets('grabbing grows the pill upward and releasing shrinks it', (
    tester,
  ) async {
    await _slider(tester);
    final restBottom = tester.getRect(find.byKey(_thumb)).bottom;
    final g = await tester.startGesture(Offset(_xOf(tester, 50), 300));
    await tester.pump();
    await tester.pump(KitMotion.sliderGrow);
    final grown = tester.getRect(find.byKey(_thumb));
    expect(grown.height, closeTo(KitTokens.sliderPillHeight, 0.01));
    expect(grown.width, closeTo(KitTokens.sliderPillWidth, 0.01));
    expect(grown.bottom, closeTo(restBottom, 0.01));
    await g.up();
    await tester.pump();
    await tester.pump(KitMotion.sliderShrink);
    expect(_thumbHeight(tester), closeTo(KitTokens.sliderThumb, 0.01));
  });

  testWidgets(
    'the value shows on top of the pill and the mark at track height',
    (tester) async {
      await _slider(tester, markDiameter: (v) => 4.0 + v / 10);
      final rest = tester.getCenter(find.text('50'));
      final g = await tester.startGesture(Offset(_xOf(tester, 50), 300));
      await tester.pump();
      await tester.pump(KitMotion.sliderGrow);
      final thumb = tester.getRect(find.byKey(_thumb));
      final up = tester.getCenter(find.text('50'));
      expect(up.dy, lessThan(rest.dy));
      expect(up.dy - thumb.top, closeTo(KitTokens.sliderValueTopInset, 0.01));
      final mark = tester.getRect(find.byKey(const Key('kit-slider-mark')));
      expect(mark.width, closeTo(9, 0.01));
      expect(
        mark.center.dy,
        closeTo(tester.getCenter(find.byKey(_track)).dy, 0.01),
      );
      await g.up();
      await tester.pumpAndSettle();
    },
  );

  testWidgets('tapping the empty track jumps there', (tester) async {
    final rec = await _slider(tester);
    final g = await tester.startGesture(Offset(_xOf(tester, 20), 300));
    await tester.pump();
    // the value is sent at once, the thumb slides
    expect(rec.changes, [20]);
    expect(_thumbX(tester), closeTo(_xOf(tester, 50), 0.01));
    await tester.pump(KitMotion.sliderJump ~/ 2);
    final halfway = _thumbX(tester);
    expect(halfway, lessThan(_xOf(tester, 50)));
    expect(halfway, greaterThan(_xOf(tester, 20)));
    await tester.pump(KitMotion.sliderJump);
    expect(_thumbX(tester), closeTo(_xOf(tester, 20), 0.01));
    await g.up();
    expect(rec.ends, [20]);
    // no pill for a jump
    expect(_thumbHeight(tester), closeTo(KitTokens.sliderThumb, 0.01));
  });

  testWidgets('the number hides while sliding and returns after it stops', (
    tester,
  ) async {
    await _slider(tester);
    double shown() => tester
        .widget<Opacity>(find.byKey(const Key('kit-slider-number')))
        .opacity;
    expect(shown(), 1);
    final g = await tester.startGesture(Offset(_xOf(tester, 20), 300));
    await tester.pump();
    expect(shown(), 0);
    await tester.pump(KitMotion.sliderJump ~/ 2);
    expect(shown(), 0);
    // after the thumb stops the number comes back (130 ms later)
    await tester.pumpAndSettle();
    expect(shown(), 1);
    expect(find.text('20'), findsOneWidget);
    await g.up();
  });

  testWidgets('moving past the touch slop after a tap follows the finger', (
    tester,
  ) async {
    final rec = await _slider(tester);
    final g = await tester.startGesture(Offset(_xOf(tester, 20), 300));
    await tester.pump(const Duration(milliseconds: 50));
    await g.moveTo(Offset(_xOf(tester, 80), 300));
    await tester.pump();
    expect(rec.changes.last, 80);
    expect(_thumbX(tester), closeTo(_xOf(tester, 80), 0.01));
    expect(_thumbHeight(tester), closeTo(KitTokens.sliderThumb, 0.01));
    await g.up();
    expect(rec.ends, [80]);
  });

  testWidgets('onChangeEnd fires once per drag', (tester) async {
    final rec = await _slider(tester);
    final g = await tester.startGesture(Offset(_xOf(tester, 50), 300));
    for (final v in [55, 60, 70, 40, 90]) {
      await g.moveTo(Offset(_xOf(tester, v), 300));
      await tester.pump();
    }
    expect(rec.ends, isEmpty);
    await g.up();
    await tester.pumpAndSettle();
    expect(rec.ends, [90]);
    expect(rec.changes.length, greaterThan(1));
  });

  testWidgets('a cancelled pointer still ends the drag once', (tester) async {
    final rec = await _slider(tester);
    final g = await tester.startGesture(Offset(_xOf(tester, 50), 300));
    await g.moveTo(Offset(_xOf(tester, 65), 300));
    await g.cancel();
    await tester.pumpAndSettle();
    expect(rec.ends, [65]);
  });

  testWidgets('slider goes straight to the end value without animations', (
    tester,
  ) async {
    final rec = await _slider(tester, disableAnimations: true);
    final g = await tester.startGesture(Offset(_xOf(tester, 20), 300));
    await tester.pump();
    expect(rec.changes, [20]);
    expect(_thumbX(tester), closeTo(_xOf(tester, 20), 0.01));
    await g.up();
    // grabbing also skips the growing
    final g2 = await tester.startGesture(Offset(_xOf(tester, 20), 300));
    await tester.pump();
    expect(_thumbHeight(tester), closeTo(KitTokens.sliderPillHeight, 0.01));
    await g2.up();
    await tester.pump();
    expect(_thumbHeight(tester), closeTo(KitTokens.sliderThumb, 0.01));
  });

  testWidgets('a value changed from outside slides the thumb there', (
    tester,
  ) async {
    _size(tester);
    final value = ValueNotifier<int>(30);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: ValueListenableBuilder<int>(
              valueListenable: value,
              builder: (_, v, _) => KitSlider(value: v, onChanged: (_) {}),
            ),
          ),
        ),
      ),
    );
    value.value = 80;
    await tester.pump();
    await tester.pump(KitMotion.sliderJump ~/ 2);
    expect(_thumbX(tester), lessThan(_xOf(tester, 80)));
    await tester.pump(KitMotion.sliderJump);
    expect(_thumbX(tester), closeTo(_xOf(tester, 80), 0.01));
  });

  testWidgets('semantics increase sends change and end once', (tester) async {
    final handle = tester.ensureSemantics();
    final rec = await _slider(tester);
    final node = tester.getSemantics(find.byKey(_track));
    expect(node.value, '50');
    expect(node.increasedValue, '55');
    expect(node.decreasedValue, '45');
    node.owner!.performAction(node.id, SemanticsAction.increase);
    await tester.pumpAndSettle();
    expect(rec.changes, [55]);
    expect(rec.ends, [55]);
    handle.dispose();
  });

  testWidgets('slider uses the value label and the min, max and step given', (
    tester,
  ) async {
    _size(tester);
    var v = 10;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: StatefulBuilder(
              builder: (context, setState) => KitSlider(
                value: v,
                min: 0,
                max: 20,
                step: 4,
                valueLabel: (x) => '${x}px',
                onChanged: (n) => setState(() => v = n),
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.text('10px'), findsOneWidget);
    await tester.tap(_iconNamed(KitIconName.plus));
    await tester.pumpAndSettle();
    expect(v, 14);
    await tester.tapAt(Offset(_xOf(tester, 20, min: 0, max: 20), 300));
    await tester.pumpAndSettle();
    expect(v, 20);
  });

  testWidgets('segment shows options and reports the chosen one', (
    tester,
  ) async {
    var value = 'a';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: StatefulBuilder(
              builder: (context, setState) => KitSegment<String>(
                options: const [('a', 'Down'), ('b', 'Side')],
                value: value,
                onChanged: (v) => setState(() => value = v),
              ),
            ),
          ),
        ),
      ),
    );
    expect(
      tester.widget<Text>(find.text('Side')).style?.color,
      KitTokens.menuInk,
    );
    await tester.tap(find.text('Side'));
    await tester.pumpAndSettle();
    expect(value, 'b');
    expect(
      tester.widget<Text>(find.text('Side')).style?.color,
      KitTokens.onAccent,
    );
    expect(
      tester.widget<Text>(find.text('Down')).style?.color,
      KitTokens.menuInk,
    );
  });

  testWidgets('toggle row shows its reason line', (tester) async {
    var on = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => KitToggleRow(
              label: 'Straighten',
              reason: 'Off while the pen is held down',
              description: 'Snaps lines',
              value: on,
              onChanged: (v) => setState(() => on = v),
            ),
          ),
        ),
      ),
    );
    final reason = tester.widget<Text>(
      find.text('Off while the pen is held down'),
    );
    expect(reason.style?.color, KitTokens.menuSub);
    final label = tester.getRect(find.text('Straighten'));
    final desc = tester.getRect(find.text('Snaps lines'));
    final why = tester.getRect(find.text('Off while the pen is held down'));
    expect(desc.top, greaterThanOrEqualTo(label.bottom));
    expect(why.top, greaterThanOrEqualTo(desc.bottom));
    await tester.tap(find.text('Straighten'));
    await tester.pumpAndSettle();
    expect(on, isTrue);
  });

  testWidgets('toggle row lines are held like the preview', (tester) async {
    // `.snp .tg` 12.5 px on the panel's 1.4 line (17.5), forced so a line that
    // mixes the app font with the Korean fallback does not grow
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: KitToggleRow(
            label: 'Straighten',
            description: 'Snaps lines',
            value: true,
            onChanged: (_) {},
          ),
        ),
      ),
    );
    for (final (text, height) in [
      ('Straighten', KitTokens.toggleLabelLineHeight),
      ('Snaps lines', KitTokens.toggleSubLineHeight),
    ]) {
      final t = tester.widget<Text>(find.text(text));
      expect(t.style?.height, height, reason: text);
      expect(t.strutStyle?.forceStrutHeight, isTrue, reason: text);
    }
  });

  testWidgets('toggle row without onChanged cannot be pressed', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: KitToggleRow(label: 'Locked', value: false, onChanged: null),
        ),
      ),
    );
    final flags = tester
        .getSemantics(find.text('Locked'))
        .getSemanticsData()
        .flagsCollection;
    expect(flags.isEnabled, Tristate.isFalse);
    handle.dispose();
  });
}

void _more() {
  testWidgets('minus and plus slide the thumb and keep the number', (
    tester,
  ) async {
    await _slider(tester);
    final from = _thumbX(tester);
    await tester.tap(_iconNamed(KitIconName.plus));
    await tester.pump();
    await tester.pump(KitMotion.sliderJump ~/ 2);
    final mid = _thumbX(tester);
    expect(mid, greaterThan(from));
    expect(mid, lessThan(_xOf(tester, 55)));
    expect(
      tester
          .widget<Opacity>(find.byKey(const Key('kit-slider-number')))
          .opacity,
      1,
    );
    await tester.pumpAndSettle();
    expect(_thumbX(tester), closeTo(_xOf(tester, 55), 0.01));
  });

  testWidgets('minus and plus go straight there without animations', (
    tester,
  ) async {
    await _slider(tester, disableAnimations: true);
    await tester.tap(_iconNamed(KitIconName.plus));
    await tester.pump();
    expect(_thumbX(tester), closeTo(_xOf(tester, 55), 0.01));
  });

  testWidgets('a diagonal drag on the slider does not scroll the list', (
    tester,
  ) async {
    _size(tester);
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    final changes = <int>[];
    var value = 50;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => ListView(
              controller: scroll,
              children: [
                const SizedBox(height: 200),
                Center(
                  child: KitSlider(
                    value: value,
                    onChanged: (v) {
                      changes.add(v);
                      setState(() => value = v);
                    },
                  ),
                ),
                const SizedBox(height: 1500),
              ],
            ),
          ),
        ),
      ),
    );
    final g = await tester.startGesture(Offset(_xOf(tester, 50), 222));
    for (var i = 1; i <= 6; i++) {
      await g.moveBy(const Offset(8, -14));
      await tester.pump();
    }
    await g.up();
    await tester.pumpAndSettle();
    expect(changes, isNotEmpty);
    expect(changes.last, greaterThan(50));
    expect(scroll.offset, 0);
  });

  testWidgets('a slider with a snap moves and reports on its grid', (
    tester,
  ) async {
    _size(tester);
    final changes = <int>[];
    final ends = <int>[];
    var value = 50;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: StatefulBuilder(
              builder: (context, setState) => KitSlider(
                value: value,
                min: 0,
                max: 100,
                step: 10,
                snap: 10,
                valueLabel: (v) => '$v%',
                onChanged: (v) {
                  changes.add(v);
                  setState(() => value = v);
                },
                onChangeEnd: ends.add,
              ),
            ),
          ),
        ),
      ),
    );
    // 20 px past the thumb is 63.5: the thumb and the number stop at 60, as
    // the preview's `slValAt` rounds to `snap`
    final g = await tester.startGesture(tester.getCenter(find.byKey(_thumb)));
    await tester.pump();
    await g.moveBy(const Offset(20, 0));
    await tester.pump();
    expect(changes, [60]);
    expect(_thumbX(tester), closeTo(_xOf(tester, 60, min: 0, max: 100), 0.01));
    expect(find.text('60%'), findsOneWidget);
    await g.moveBy(const Offset(6, 0));
    await tester.pump();
    expect(changes, [60, 70]);
    await g.up();
    await tester.pumpAndSettle();
    expect(ends, [70]);
    // a tap on the track lands on the grid too
    await tester.tapAt(
      Offset(
        _xOf(tester, 33, min: 0, max: 100),
        tester.getCenter(find.byKey(_track)).dy,
      ),
    );
    await tester.pumpAndSettle();
    expect(changes.last, 30);
    expect(ends.last, 30);
  });

  testWidgets('a disabled slider takes no touch and greys its ends', (
    tester,
  ) async {
    _size(tester);
    final handle = tester.ensureSemantics();
    final changes = <int>[];
    final ends = <int>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: KitSlider(
              value: 50,
              enabled: false,
              onChanged: changes.add,
              onChangeEnd: ends.add,
            ),
          ),
        ),
      ),
    );
    final track = tester.getRect(find.byKey(_track));
    await tester.tapAt(Offset(track.left + 30, track.center.dy));
    final g = await tester.startGesture(tester.getCenter(find.byKey(_thumb)));
    await g.moveBy(const Offset(40, 0));
    await g.up();
    await tester.tapAt(tester.getCenter(_iconNamed(KitIconName.plus)));
    await tester.tapAt(tester.getCenter(_iconNamed(KitIconName.minus)));
    await tester.pumpAndSettle();
    expect(changes, isEmpty);
    expect(ends, isEmpty);
    expect(_thumbX(tester), closeTo(_xOf(tester, 50), 0.01));
    // `.srow.dis` (preview line 622): the row at .35, the minus and plus grey
    for (final n in [KitIconName.minus, KitIconName.plus]) {
      expect(
        tester.widget<KitIcon>(_iconNamed(n)).color,
        KitTokens.stepperDisabled,
        reason: n.id,
      );
    }
    final fade = tester.widget<Opacity>(
      find
          .ancestor(of: find.byKey(_track), matching: find.byType(Opacity))
          .first,
    );
    expect(fade.opacity, KitTokens.disabledOpacity);
    final data = tester.getSemantics(find.byKey(_track)).getSemanticsData();
    expect(data.flagsCollection.isEnabled, Tristate.isFalse);
    expect(data.hasAction(SemanticsAction.increase), isFalse);
    expect(data.hasAction(SemanticsAction.decrease), isFalse);
    handle.dispose();
  });

  testWidgets('a value of four characters or more is set at 11 px', (
    tester,
  ) async {
    _size(tester);
    Future<double?> sizeOf(int value) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: KitSlider(
                key: ValueKey(value),
                value: value,
                min: 0,
                max: 100,
                valueLabel: (v) => '$v%',
                onChanged: (_) {},
              ),
            ),
          ),
        ),
      );
      return tester.widget<Text>(find.text('$value%')).style?.fontSize;
    }

    // `.th .tn.lg` (preview line 171)
    expect(await sizeOf(50), KitTokens.sliderValueSize);
    expect(await sizeOf(100), KitTokens.sliderValueSizeLong);
  });

  testWidgets('a toggle row with a note keeps its switch at the top', (
    tester,
  ) async {
    _size(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 270,
                child: KitToggleRow(
                  key: const Key('tx'),
                  label: 'Straighten',
                  description: 'Snaps lines to the nearest of the two axes',
                  value: false,
                  onChanged: (_) {},
                ),
              ),
              SizedBox(
                width: 270,
                child: KitToggleRow(
                  key: const Key('plain'),
                  label: 'Plain',
                  value: false,
                  onChanged: (_) {},
                ),
              ),
            ],
          ),
        ),
      ),
    );
    Rect inRow(String row, Finder f) => tester
        .getRect(find.descendant(of: find.byKey(Key(row)), matching: f))
        .shift(-tester.getTopLeft(find.byKey(Key(row))));
    Finder lines(String data) =>
        find.byWidgetPredicate((w) => w is KitLines && w.data == data);
    const note = 'Snaps lines to the nearest of the two axes';
    // `.snp .tg.tx` (preview lines 615-618): the name's 17.5 line and the
    // switch at the top, 11 in, the switch 1 lower; the note's 15.4 lines 2
    // under the name, so the row is 11 + 17.5 + 2 + 15.4 x lines + 11
    final label = inRow('tx', lines('Straighten'));
    final noteBox = inRow('tx', lines(note));
    final noteLines = find
        .descendant(of: lines(note), matching: find.byType(Text))
        .evaluate()
        .length;
    final sw = inRow('tx', find.byType(KitSwitch));
    expect(label.top, KitTokens.toggleTextPadV);
    expect(label.height, closeTo(12.5 * 1.4, 1e-9));
    expect(noteBox.top, closeTo(label.bottom + KitTokens.toggleSubTop, 1e-9));
    expect(noteLines, greaterThan(1));
    expect(noteBox.height, closeTo(11 * 1.4 * noteLines, 1e-9));
    expect(
      tester.getSize(find.byKey(const Key('tx'))).height,
      closeTo(11 + 17.5 + 2 + 15.4 * noteLines + 11, 1e-9),
    );
    expect(sw.top, KitTokens.toggleTextPadV + KitTokens.toggleSwitchTop);
    expect(sw.right, 270);
    // a row without a note keeps its name and switch in the middle
    final plain = tester.getSize(find.byKey(const Key('plain')));
    expect(inRow('plain', find.byType(KitSwitch)).center.dy, plain.height / 2);
    expect(inRow('plain', find.text('Plain')).center.dy, plain.height / 2);
  });

  testWidgets('lines keep the preview pitch, each at the foot of its box', (
    tester,
  ) async {
    _size(tester);
    const text = 'one two three four five six seven';
    const style = TextStyle(fontSize: 11, height: 1.4);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 120,
              child: KitLines(text, key: Key('lines'), style: style),
            ),
          ),
        ),
      ),
    );
    final box = tester.getRect(find.byKey(const Key('lines')));
    final texts = tester
        .widgetList<Text>(
          find.descendant(
            of: find.byKey(const Key('lines')),
            matching: find.byType(Text),
          ),
        )
        .toList();
    // broken where one paragraph breaks it, spaces at the breaks dropped
    final paragraph = TextPainter(
      text: const TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: 120);
    expect(texts, hasLength(paragraph.computeLineMetrics().length));
    paragraph.dispose();
    expect(texts.map((t) => t.data).join(' '), text);
    expect(texts.every((t) => t.data == t.data!.trim()), isTrue);
    // 15.4 apart, not the 15 Flutter rounds a line to
    expect(box.height, closeTo(15.4 * texts.length, 1e-9));
    final lines = find.descendant(
      of: find.byKey(const Key('lines')),
      matching: find.byType(Text),
    );
    for (var i = 0; i < texts.length; i++) {
      expect(
        tester.getRect(lines.at(i)).bottom - box.top,
        closeTo(15.4 * (i + 1), 1e-9),
        reason: 'line $i',
      );
    }
    // read out as one text
    final handle = tester.ensureSemantics();
    expect(find.bySemanticsLabel(text), findsOneWidget);
    handle.dispose();
  });

  testWidgets('a slider says its unit but draws only the number', (
    tester,
  ) async {
    _size(tester);
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: KitSlider(
              value: 100,
              min: 0,
              max: 100,
              step: 10,
              unit: '%',
              onChanged: (_) {},
            ),
          ),
        ),
      ),
    );
    // the preview's stabiliser (`unit:'%'`): "100" on the thumb at 13 px,
    // "100%" to screen readers
    expect(find.text('100'), findsOneWidget);
    expect(find.text('100%'), findsNothing);
    expect(
      tester.widget<Text>(find.text('100')).style?.fontSize,
      KitTokens.sliderValueSize,
    );
    final data = tester.getSemantics(find.byKey(_track)).getSemanticsData();
    expect(data.value, '100%');
    expect(data.decreasedValue, '90%');
    handle.dispose();
  });

  testWidgets('a locked toggle row looks on, takes no tap and says why', (
    tester,
  ) async {
    _size(tester);
    final handle = tester.ensureSemantics();
    final changes = <bool>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 270,
            child: KitToggleRow(
              key: const Key('locked'),
              label: 'Ink',
              value: true,
              onChanged: changes.add,
              lockedReason: 'Keep one on.',
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('locked')));
    await tester.pump();
    expect(changes, isEmpty);
    // not dimmed like a row without onChanged (`.tg .sw[aria-disabled]`,
    // preview-v8g line 619): it is on, it only cannot be turned off now
    for (final f in [find.text('Ink'), find.byType(KitSwitch)]) {
      final fades = find.ancestor(of: f, matching: find.byType(Opacity));
      for (final o in tester.widgetList<Opacity>(fades)) {
        expect(o.opacity, 1);
      }
    }
    expect(tester.widget<KitSwitch>(find.byType(KitSwitch)).value, isTrue);
    // `aria-disabled` and `aria-describedby`: cannot be changed, and why
    final data = tester
        .getSemantics(find.byKey(const Key('locked')))
        .getSemanticsData();
    expect(data.flagsCollection.isEnabled, Tristate.isFalse);
    expect(data.flagsCollection.isToggled, Tristate.isTrue);
    expect(data.hasAction(SemanticsAction.tap), isFalse);
    expect(data.label, 'Ink');
    expect(data.hint, contains('Keep one on.'));
    handle.dispose();
  });
}
