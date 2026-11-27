import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/kit/kit_icon.dart';

/// Icons whose own line weights carry meaning (kept by the export script).
const _ownStroke = {'bold', 'bi', 'width'};

final _hex = RegExp('#[0-9a-fA-F]{6}');

/// Colours that appear only in the selected drawing of [n].
Set<String> _accentColors(KitIconName n) =>
    _hex.allMatches(n.selectedSvg).map((m) => m.group(0)!.toLowerCase()).toSet()
      ..removeAll(_hex.allMatches(n.svg).map((m) => m.group(0)!.toLowerCase()));

/// Draws [icon] on a transparent surface and returns RGBA pixels.
Future<List<int>> _pixels(WidgetTester tester, Widget icon) async {
  final key = GlobalKey();
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Center(
        child: RepaintBoundary(key: key, child: icon),
      ),
    ),
  );
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 200)),
  );
  await tester.pump();
  late List<int> data;
  await tester.runAsync(() async {
    final b = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final img = await b.toImage();
    data = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer
        .asUint8List();
    img.dispose();
  });
  return data;
}

int _inked(List<int> rgba) {
  var n = 0;
  for (var i = 3; i < rgba.length; i += 4) {
    if (rgba[i] > 8) n++;
  }
  return n;
}

int _near(List<int> rgba, String hex) {
  final v = int.parse(hex.substring(1), radix: 16);
  final r = v >> 16 & 255, g = v >> 8 & 255, b = v & 255;
  var n = 0;
  for (var i = 0; i < rgba.length; i += 4) {
    if (rgba[i + 3] > 200 &&
        (rgba[i] - r).abs() < 24 &&
        (rgba[i + 1] - g).abs() < 24 &&
        (rgba[i + 2] - b).abs() < 24) {
      n++;
    }
  }
  return n;
}

void main() {
  test('every preview icon is generated', () {
    expect(KitIconName.values.length, greaterThanOrEqualTo(97));
    for (final n in KitIconName.values) {
      expect(n.svg, isNotEmpty, reason: n.id);
    }
    expect(KitIconName.lassoFree.id, 'lasso_free');
    expect(KitIconName.chevR.id, 'chev_r');
    expect(KitIconName.pen.label, isNotEmpty);
  });

  test('the 12th draft adds nine icons, each with a name and ink', () {
    const ids = [
      'side_pages',
      'outline_list',
      'audio_clip',
      'play',
      'pause',
      'rec_dot',
      'stop_sq',
      'grip_corner',
      'save_to',
    ];
    final byId = {for (final n in KitIconName.values) n.id: n};
    // 187 + the nine + autoHl, quiz + the page menu's add before and after
    expect(KitIconName.values.length, 200);
    for (final id in ids) {
      final n = byId[id];
      expect(n, isNotNull, reason: id);
      expect(n!.label, isNot(id), reason: id);
      expect(RegExp('<(path|rect|circle)').hasMatch(n.svg), isTrue, reason: id);
    }
    expect(byId['play']!.label, '재생');
    expect(byId['rec_dot']!.label, '이어서 녹음');
    expect(
      kitIconGroups.any((g) => ids.every((id) => g.$2.contains(byId[id]))),
      isTrue,
    );
  });

  testWidgets('the nine new icons paint pixels', (tester) async {
    for (final id in [
      'side_pages',
      'outline_list',
      'audio_clip',
      'play',
      'pause',
      'rec_dot',
      'stop_sq',
      'grip_corner',
      'save_to',
    ]) {
      final n = KitIconName.values.firstWhere((n) => n.id == id);
      final px = await _pixels(
        tester,
        KitIcon(n, size: 48, color: Colors.black),
      );
      expect(_inked(px), greaterThan(40), reason: id);
    }
  });

  testWidgets('the page menu add before and add after are mirror images', (
    tester,
  ) async {
    expect(KitIconName.pageAddBefore.label, '앞에 쪽 추가');
    expect(KitIconName.pageAddAfter.label, '뒤에 쪽 추가');
    expect(
      kitIconGroups.any(
        (g) =>
            g.$2.contains(KitIconName.pageAddBefore) &&
            g.$2.contains(KitIconName.pageAddAfter),
      ),
      isTrue,
    );
    // the middle of the ink, across a 48 wide drawing
    Future<double> inkMiddle(KitIconName n) async {
      final px = await _pixels(
        tester,
        KitIcon(n, size: 48, color: Colors.black),
      );
      expect(_inked(px), greaterThan(40), reason: n.id);
      var sum = 0.0, count = 0;
      for (var i = 3; i < px.length; i += 4) {
        if (px[i] > 8) {
          sum += (i ~/ 4) % 48;
          count++;
        }
      }
      return sum / count;
    }

    final before = await inkMiddle(KitIconName.pageAddBefore);
    final after = await inkMiddle(KitIconName.pageAddAfter);
    // mirror images about the middle, each within 1.5 of 24 (12 on its grid)
    expect(before + after, closeTo(47, 1));
    expect((before - 23.5).abs(), lessThanOrEqualTo(3));
    // before: the chevron on the left, the page right of it; after: mirrored
    expect(before, greaterThan(after));
  });

  test('groups only name generated icons', () {
    expect(kitIconGroups, isNotEmpty);
    expect(kitIconGroups.every((g) => g.$2.isNotEmpty), isTrue);
  });

  test('svg strings hold nothing flutter_svg cannot read', () {
    for (final n in KitIconName.values) {
      for (final s in [n.svg, n.selectedSvg]) {
        expect(s.contains('class='), isFalse, reason: n.id);
        expect(s.contains('var('), isFalse, reason: n.id);
      }
      expect(n.svg.contains('"acc"'), isFalse, reason: n.id);
    }
  });

  test('only the allow-listed icons keep their own stroke-width', () {
    for (final n in KitIconName.values) {
      if (_ownStroke.contains(n.id)) continue;
      expect(n.svg.contains('stroke-width'), isFalse, reason: n.id);
      expect(n.selectedSvg.contains('stroke-width'), isFalse, reason: n.id);
    }
  });

  test('accent colours exist only in the selected drawing', () {
    final withAccent = KitIconName.values.where((n) => n.hasAccent).toList();
    expect(withAccent, isNotEmpty);
    for (final n in withAccent) {
      final colors = _accentColors(n);
      expect(colors, isNotEmpty, reason: n.id);
      expect(n.selectedSvg.length, greaterThan(n.svg.length), reason: n.id);
    }
  });

  test('every label differs from its id', () {
    for (final n in KitIconName.values) {
      expect(n.label, isNot(n.id), reason: n.id);
    }
    expect(KitIconName.chevR.label, '하위 메뉴');
  });

  test('generated file is LF with the generated header', () {
    final bytes = File('lib/components/kit/kit_icons.g.dart').readAsBytesSync();
    expect(bytes.contains(13), isFalse);
    expect(
      String.fromCharCodes(bytes.take(100)),
      startsWith('// GENERATED by scripts/kit_preview_export.mjs'),
    );
    expect(String.fromCharCodes(bytes).contains('Icons.'), isFalse);
  });

  testWidgets('each icon renders without errors', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Material(
          child: SingleChildScrollView(
            child: Wrap(
              children: [
                for (final n in KitIconName.values) ...[
                  KitIcon(n),
                  KitIcon(n, selected: true),
                ],
              ],
            ),
          ),
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(
      find.byType(SvgPicture),
      findsNWidgets(KitIconName.values.length * 2),
    );
  });

  testWidgets('icons paint pixels, accents only when selected', (tester) async {
    for (final n in [KitIconName.home, KitIconName.pen, KitIconName.search]) {
      final px = await _pixels(
        tester,
        KitIcon(n, size: 48, color: Colors.black),
      );
      expect(_inked(px), greaterThan(0), reason: n.id);
    }
    final withAccent = KitIconName.values.firstWhere((n) => n.hasAccent);
    final accent = _accentColors(withAccent).first;
    final plain = await _pixels(
      tester,
      KitIcon(withAccent, size: 48, color: Colors.black),
    );
    final chosen = await _pixels(
      tester,
      KitIcon(withAccent, size: 48, color: Colors.black, selected: true),
    );
    expect(_near(plain, accent), 0, reason: withAccent.id);
    expect(_near(chosen, accent), greaterThan(20), reason: withAccent.id);
  });

  testWidgets('strokeWidth thickens icons without their own stroke-width', (
    tester,
  ) async {
    for (final n in [KitIconName.pen, KitIconName.home]) {
      expect(n.svg.contains('stroke-width'), isFalse, reason: n.id);
      final thin = await _pixels(
        tester,
        KitIcon(n, size: 48, strokeWidth: 1, color: Colors.black),
      );
      final thick = await _pixels(
        tester,
        KitIcon(n, size: 48, strokeWidth: 2, color: Colors.black),
      );
      expect(_inked(thick), greaterThan(_inked(thin)), reason: n.id);
    }
  });

  testWidgets('dashed lines are cut along their length, the rest as before', (
    tester,
  ) async {
    // flutter_svg cuts a dash at a share of a curve's parameter, so on a
    // curve its dashes fall elsewhere than the browser's (Task 12 screen
    // review 1-3). The dashed lines are drawn along the measured path; an
    // icon without dashes is the same SvgPicture as before.
    bool dashed(KitIconName n) =>
        '${n.svg}${n.selectedSvg}'.contains('stroke-dasharray');
    expect([
      for (final n in KitIconName.values)
        if (dashed(n)) n.id,
    ], containsAll(['lasso_free', 'custom', 'erase_lasso']));
    await tester.pumpWidget(
      MaterialApp(
        home: Material(
          child: SingleChildScrollView(
            child: Wrap(
              children: [
                for (final n in KitIconName.values)
                  for (final selected in [false, true])
                    KitIcon(
                      n,
                      key: ValueKey('${n.id} $selected'),
                      selected: selected,
                    ),
              ],
            ),
          ),
        ),
      ),
    );
    for (final n in KitIconName.values) {
      for (final selected in [false, true]) {
        final icon = find.byKey(ValueKey('${n.id} $selected'));
        final dashes = find.descendant(
          of: icon,
          matching: find.byWidgetPredicate(
            (w) => w is CustomPaint && w.painter != null,
          ),
        );
        expect(dashes, dashed(n) ? findsOneWidget : findsNothing, reason: n.id);
        expect(
          find.descendant(of: icon, matching: find.byType(SvgPicture)),
          findsOneWidget,
          reason: n.id,
        );
      }
    }
  });

  test('the width icon draws its middle line for the size number', () {
    // task-12-values.md §13: 1.4 + min(4, floor((size - 1) / 20)) x 0.7 on
    // the 24 grid; the thin and thick lines stay
    List<String> lines(int level) => [
      for (final m in RegExp(
        r'stroke-width="([^"]*)"',
      ).allMatches(kitWidthDrawing(level)))
        m[1]!,
    ];
    // each step's ends, and the values sheet's 7, 37, 52 and 97
    for (final (level, middle) in const [
      (1, '1.4'),
      (7, '1.4'),
      (20, '1.4'),
      (21, '2.1'),
      (37, '2.1'),
      (40, '2.1'),
      (41, '2.8'),
      (52, '2.8'),
      (61, '3.5'),
      (80, '3.5'),
      (81, '4.2'),
      (97, '4.2'),
      (100, '4.2'),
    ]) {
      expect(lines(level)[1], middle, reason: '$level');
    }
    expect(lines(52), ['1.6', '2.8', '4.2']);
    expect(
      kitWidthDrawing(52)
          .replaceFirst('stroke-width="2.8"', 'stroke-width="3"'),
      KitIconName.width.svg,
    );
  });
}
