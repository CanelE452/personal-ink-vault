import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:perfect_freehand/perfect_freehand.dart';
import 'package:saber/components/canvas/_circle_stroke.dart';
import 'package:saber/components/canvas/_rectangle_stroke.dart';
import 'package:saber/components/canvas/_stroke.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/tools/eraser.dart';
import 'package:saber/data/tools/eraser_targets.dart';
import 'package:saber/data/tools/lasso_targets.dart';
import 'package:saber/data/tools/select.dart';
import 'package:sbn/has_size.dart';
import 'package:sbn/tool_id.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:stow/stow.dart';
import 'package:stow_plain/stow_plain.dart';

const _page = HasSize(Size(200, 200));
const _at = Offset(50, 50);

/// A plain stroke of [tool] with a point at [_at].
Stroke _stroke(ToolId tool) => Stroke(
  color: Stroke.defaultColor,
  pressureEnabled: false,
  options: StrokeOptions(size: 1),
  pageIndex: 0,
  page: _page,
  toolId: tool,
)..addPoint(_at);

CircleStroke _circle({ToolId tool = ToolId.shapePen}) => CircleStroke(
  color: Stroke.defaultColor,
  pressureEnabled: false,
  options: StrokeOptions(size: 1),
  pageIndex: 0,
  page: _page,
  toolId: tool,
  center: _at,
  radius: 4,
);

RectangleStroke _rectangle() => RectangleStroke(
  color: Stroke.defaultColor,
  pressureEnabled: false,
  options: StrokeOptions(size: 1),
  pageIndex: 0,
  page: _page,
  toolId: ToolId.shapePen,
  rect: Rect.fromCenter(center: _at, width: 8, height: 8),
);

/// One of each stroke the page can hold, by the 「지울 대상」 it belongs to:
/// 펜 = the fountain and ballpoint pens, 연필, 형광펜, 도형 = the shape pen's
/// strokes and the circles and rectangles it turns them into.
Map<StrokeKind, List<Stroke>> _strokes() => {
  StrokeKind.pen: [_stroke(ToolId.fountainPen), _stroke(ToolId.ballpointPen)],
  StrokeKind.pencil: [_stroke(ToolId.pencil)],
  StrokeKind.highlighter: [_stroke(ToolId.highlighter)],
  // a circle is a shape whatever tool it names
  StrokeKind.shape: [
    _stroke(ToolId.shapePen),
    _circle(),
    _circle(tool: ToolId.fountainPen),
    _rectangle(),
  ],
};

void _reset() {
  stows.eraserTargets.value = stows.eraserTargets.defaultValue;
  stows.eraseHighlighterOnly.value = stows.eraseHighlighterOnly.defaultValue;
  stows.selectShapes.value = stows.selectShapes.defaultValue;
  for (final target in LassoTargets.all) {
    target.value = target.defaultValue;
  }
  Select.currentSelect.unselect();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();
  setUp(_reset);
  tearDown(_reset);

  group('the eraser targets', () {
    test('start from the old highlighter-only switch', () {
      // no new value yet: highlighter only stays highlighter only
      expect(stows.eraserTargets.value, isEmpty);
      stows.eraseHighlighterOnly.value = true;
      expect(EraserTargets.value, {StrokeKind.highlighter});
      // and without it every kind is erased
      stows.eraseHighlighterOnly.value = false;
      expect(EraserTargets.value, StrokeKind.values.toSet());
    });

    test('a new value wins over the old highlighter-only switch', () {
      stows.eraseHighlighterOnly.value = true;
      stows.eraserTargets.value = ['pen'];
      expect(EraserTargets.value, {StrokeKind.pen});
    });

    test(
      'a stored value that is not a list of names reads as all four',
      () async {
        // Stows do not read storage in tests; a stow made the way
        // stows.eraserTargets is made does, with reading turned on.
        Stow.volatileInTests = false;
        addTearDown(() {
          Stow.volatileInTests = true;
          SharedPreferences.setMockInitialValues({});
        });
        for (final stored in <Object>['tape', 7, true]) {
          SharedPreferences.setMockInitialValues({'eraserTargets': stored});
          final stow = PlainStow(
            'eraserTargets',
            stows.eraserTargets.defaultValue,
            codec: stows.eraserTargets.codec,
          );
          // ignore: invalid_use_of_visible_for_testing_member
          await stow.read();
          stows.eraserTargets.value = stow.value;
          expect(
            EraserTargets.value,
            StrokeKind.values.toSet(),
            reason: '$stored',
          );
        }
      },
    );

    test('a broken value gives the default, all four', () {
      for (final only in [false, true]) {
        stows.eraseHighlighterOnly.value = only;
        stows.eraserTargets.value = ['pen', 'tape'];
        expect(EraserTargets.value, StrokeKind.values.toSet(), reason: '$only');
      }
    });

    test('are kept by name, the old switch left as it was', () {
      stows.eraseHighlighterOnly.value = true;
      expect(EraserTargets.set(StrokeKind.pen, true), isTrue);
      expect(EraserTargets.value, {StrokeKind.pen, StrokeKind.highlighter});
      expect(stows.eraserTargets.value, ['pen', 'highlighter']);
      expect(stows.eraseHighlighterOnly.value, isTrue);
    });

    test('the last one on cannot go off', () {
      stows.eraserTargets.value = ['shape'];
      expect(EraserTargets.isLocked(StrokeKind.shape), isTrue);
      expect(EraserTargets.isLocked(StrokeKind.pen), isFalse);
      expect(EraserTargets.set(StrokeKind.shape, false), isFalse);
      expect(EraserTargets.value, {StrokeKind.shape});
      expect(EraserTargets.set(StrokeKind.pencil, true), isTrue);
      expect(EraserTargets.isLocked(StrokeKind.shape), isFalse);
      expect(EraserTargets.set(StrokeKind.shape, false), isTrue);
      expect(EraserTargets.value, {StrokeKind.pencil});
    });
  });

  test('the eraser leaves the kinds turned off and erases the rest', () {
    for (final off in StrokeKind.values) {
      stows.eraserTargets.value = [
        for (final kind in StrokeKind.values)
          if (kind != off) kind.name,
      ];
      final strokes = _strokes();
      final all = [for (final list in strokes.values) ...list];

      // rubbing over them
      final eraser = Eraser(size: 10);
      final rubbed = eraser.checkForOverlappingStrokes(_at, all);
      // and a loop around them (circle select)
      final looped =
          (Eraser(size: 10)
                ..startLasso(Offset.zero, 0)
                ..extendLasso(const Offset(0, 120))
                ..extendLasso(const Offset(120, 120))
                ..extendLasso(const Offset(120, 0)))
              .finishLasso(all);

      for (final erased in [rubbed, looped]) {
        for (final MapEntry(key: kind, value: list) in strokes.entries) {
          for (final stroke in list) {
            expect(
              erased.contains(stroke),
              kind != off,
              reason: '${off.name} off: ${stroke.runtimeType} ${stroke.toolId}',
            );
          }
        }
      }
    }
  });

  test('the lasso picks shapes by their own switch', () {
    expect(LassoTargets.all, [
      stows.selectInk,
      stows.selectHighlighter,
      stows.selectShapes,
      stows.selectImages,
    ]);
    List<Stroke> picked(List<Stroke> strokes) {
      final select = Select.currentSelect
        ..onDragStart(Offset.zero, 0)
        ..onDragUpdate(const Offset(0, 120))
        ..onDragUpdate(const Offset(120, 120))
        ..onDragUpdate(const Offset(120, 0))
        ..onDragEnd(strokes, const []);
      return select.selectResult.strokes;
    }

    final strokes = _strokes();
    final all = [for (final list in strokes.values) ...list];
    final ink = [...strokes[StrokeKind.pen]!, ...strokes[StrokeKind.pencil]!];
    final shapes = strokes[StrokeKind.shape]!;

    // 손글씨 without 도형: the shape pen's strokes are not handwriting
    stows.selectShapes.value = false;
    expect(
      picked(all),
      unorderedEquals([...ink, ...strokes[StrokeKind.highlighter]!]),
    );
    // 도형 alone
    stows.selectShapes.value = true;
    stows.selectInk.value = false;
    stows.selectHighlighter.value = false;
    expect(picked(all), unorderedEquals(shapes));
  });
}
