import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/kit/kit_pen_art.dart';
import 'package:sbn/tool_id.dart';

import 'svg_normalize.dart';

/// Fixtures written by scripts/kit_preview_export.mjs from the preview's own
/// penArt / penSampleInner / kFor, so these tests compare the app with the preview.
final _fx = jsonDecode(
  File('test/kit/fixtures/pen_art_cases.json').readAsStringSync(),
) as Map<String, dynamic>;

KitPenKind _kind(String previewId) =>
    KitPenKind.values.firstWhere((k) => k.previewId == previewId);

Color _ink(String hex) =>
    Color(0xff000000 | int.parse(hex.substring(1), radix: 16));

List<Map<String, dynamic>> _list(String key) =>
    (_fx[key] as List).cast<Map<String, dynamic>>();

/// The two numbers of the first stroke-dasharray in [svg].
List<double> _dashArray(String svg) {
  final m = RegExp(r'stroke-dasharray="([\d.]+) ([\d.]+)"').firstMatch(svg)!;
  return [double.parse(m.group(1)!), double.parse(m.group(2)!)];
}

/// Stroke width of the dashed path in [svg].
double _dashedWidth(String svg) {
  final m = RegExp(
    r'stroke-width="([\d.]+)" stroke-linecap="round" '
    r'stroke-linejoin="round" stroke-dasharray',
  ).firstMatch(svg)!;
  return double.parse(m.group(1)!);
}

void main() {
  test('Dart pen art matches the preview for every fixture', () {
    final cases = _list('art');
    expect(cases.length, greaterThan(50));
    for (final c in cases) {
      expect(
        normalizeSvg(
          kitPenArtSvg(
            _kind(c['kind'] as String),
            _ink(c['ink'] as String),
            selected: c['selected'] as bool,
            ruler: c['ruler'] as bool,
            nibRight: c['nibRight'] as bool,
          ),
        ),
        normalizeSvg(c['svg'] as String),
        reason: c['name'] as String,
      );
    }
  });

  test('Dart samples match the preview', () {
    final cases = _list('samples');
    expect(cases.length, greaterThan(50));
    for (final c in cases) {
      final kind = _kind(c['kind'] as String);
      expect(
        normalizeSvg(
          kitPenSampleSvg(
            kind,
            _ink(c['ink'] as String),
            k: kitPenK(kind, c['level'] as int),
            alpha: (c['alpha'] as num).toDouble(),
            straight: c['straight'] as bool,
            dash: KitPenDash.values.byName(c['dash'] as String),
          ),
        ),
        normalizeSvg(c['svg'] as String),
        reason: c['name'] as String,
      );
    }
  });

  test('the comparison is not blind: other input gives other output', () {
    final ink = _ink('#1f2329');
    final a = normalizeSvg(kitPenSampleSvg(KitPenKind.fountain, ink, k: 1));
    expect(
      a,
      isNot(normalizeSvg(kitPenSampleSvg(KitPenKind.fountain, ink, k: 1.1))),
    );
    expect(
      a,
      isNot(
        normalizeSvg(
          kitPenSampleSvg(KitPenKind.fountain, ink, k: 1, straight: true),
        ),
      ),
    );
    expect(
      normalizeSvg('<a x="1.0004" c="#f3f3f5" id="pa1b" w="-0.0001" h=".5"/>'),
      '<a x="1" c="#f3f3f5" id="pa1b" w="0" h="0.5"/>',
    );
  });

  test('size to k follows the preview kFor for every pen', () {
    final table = _fx['kTable'] as Map<String, dynamic>;
    for (final kind in KitPenKind.values) {
      final row = table[kind.previewId] as Map<String, dynamic>;
      for (final e in row.entries) {
        expect(
          kitPenK(kind, int.parse(e.key)),
          closeTo((e.value as num).toDouble(), 1e-12),
          reason: '${kind.previewId} level ${e.key}',
        );
      }
    }
  });

  test('the chisel nib draws another face when the high side flips', () {
    final ink = _ink('#f7d708');
    expect(
      kitPenArtSvg(KitPenKind.highlighterChisel, ink),
      isNot(kitPenArtSvg(KitPenKind.highlighterChisel, ink, nibRight: false)),
    );
  });

  test('dotted sample follows the 7th-draft part-2 formula', () {
    // Panel px: W = max(1.13 + 0.017 v, 0.0857 v - 0.43), dash length 1.55 W + 0.4,
    // gap 2, round caps, one unit = 0.9 px, v = slider value (k = .3 + 1.2 v / 100).
    for (final v in [4, 16, 47, 96]) {
      final k = kitPenK(KitPenKind.finePen, v);
      final svg = kitPenSampleSvg(
        KitPenKind.finePen,
        _ink('#1f2329'),
        k: k,
        dash: KitPenDash.dot,
      );
      final w = [
        1.13 + 0.017 * v,
        0.0857 * v - 0.43,
      ].reduce((a, b) => a > b ? a : b);
      final wUnits = _dashedWidth(svg);
      final [dash, space] = _dashArray(svg);
      expect(wUnits * 0.9, closeTo(w, 0.03), reason: 'width, level $v');
      expect(
        (dash + wUnits) * 0.9,
        closeTo(1.55 * w + 0.4, 0.05),
        reason: 'length, level $v',
      );
      expect((space - wUnits) * 0.9, closeTo(2, 0.01), reason: 'gap, level $v');
    }
  });

  test('engine mapping and names', () {
    expect(KitPenKind.finePen.toolId, ToolId.ballpointPen);
    expect(KitPenKind.fountain.toolId, ToolId.fountainPen);
    expect(KitPenKind.pencil.toolId, ToolId.pencil);
    expect(KitPenKind.highlighterChisel.toolId, ToolId.highlighter);
    expect(KitPenKind.fountain.label, '펜(가는 촉)');
    expect(KitPenKind.calligraphy.inEngine, isFalse);
    expect(KitPenKind.values.where((k) => k.inEngine).length, 4);
    expect(KitPenKind.values.where((k) => k.isHighlighter).toList(), [
      KitPenKind.highlighterChisel,
      KitPenKind.highlighterRound,
    ]);
    final labels = _fx['labels'] as Map<String, dynamic>;
    expect([
      for (final k in KitPenKind.values) k.previewId,
    ], labels.keys.toList());
    for (final k in KitPenKind.values) {
      expect(k.label, labels[k.previewId], reason: k.previewId);
    }
  });

  test('stroke-only lines reach flutter_svg without a fill', () {
    // flutter_svg paints the default black fill of a line that only has a
    // stroke (Chrome paints nothing), so the rim, band edge and nib slit came
    // out darker than the preview. The drawing given to flutter_svg adds
    // fill="none" there and changes nothing else.
    const ink = Color(0xff2f55d4);
    final strokeTag = RegExp(r'<(?:path|g)\b[^>]*\bstroke=[^>]*>');
    for (final kind in KitPenKind.values) {
      for (final (selected, ruler) in [(false, false), (true, true)]) {
        final svg = kitPenArtSvg(kind, ink, selected: selected, ruler: ruler);
        final drawn = kitSvgForFlutter(svg);
        String plain(String x) => x.replaceAll(' fill="none"', '');
        expect(plain(drawn), plain(svg), reason: kind.previewId);
        for (final m in strokeTag.allMatches(drawn)) {
          expect(m.group(0), contains('fill='), reason: m.group(0));
        }
      }
    }
  });

  testWidgets('the fine pen rim line is as light as in the preview', (
    tester,
  ) async {
    // preview at scale 2: d7d9dd / dbdde2 on the rim (screen review 5)
    final key = GlobalKey();
    tester.view.physicalSize = const Size(200, 400);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: RepaintBoundary(
            key: key,
            child: const ColoredBox(
              color: Color(0xffffffff),
              child: SizedBox(
                width: 40,
                height: 167,
                child: KitPenArt(
                  KitPenKind.finePen,
                  Color(0xffe5323e),
                  selected: true,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pump();
    late List<int> darkest;
    await tester.runAsync(() async {
      final b =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final img = await b.toImage(pixelRatio: 2);
      final data = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!
          .buffer
          .asUint8List();
      // the rim: y 55.6 of the 200 sheet, at the middle of the pen
      final y = ((0.1667 + 55.6 * 40 / 48) * 2).round();
      darkest = [255, 255, 255];
      for (var yy = y - 3; yy <= y + 3; yy++) {
        final i = (yy * img.width + 40) * 4;
        for (var c = 0; c < 3; c++) {
          darkest[c] = math.min(darkest[c], data[i + c]);
        }
      }
      img.dispose();
    });
    expect(darkest.every((v) => v >= 0xc8), isTrue, reason: '$darkest');
  });

  testWidgets('samples are drawn past their box like the preview', (
    tester,
  ) async {
    // `.psmp{overflow:visible}`: the chisel flag's pole runs to y 40 of the
    // 34 high sheet, below the box (screen review 6: 8% of its red was cut)
    final key = GlobalKey();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: RepaintBoundary(
            key: key,
            child: const ColoredBox(
              color: Color(0xffffffff),
              child: SizedBox(
                width: 100,
                height: 80,
                child: Stack(
                  children: [
                    Positioned(
                      left: 20,
                      top: 20,
                      width: 60,
                      height: 34,
                      child: KitPenSample(
                        KitPenKind.highlighterChisel,
                        Color(0xffe5323e),
                        level: 51,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pump();
    var below = 0;
    await tester.runAsync(() async {
      final b =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final img = await b.toImage();
      final data = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!
          .buffer
          .asUint8List();
      for (var y = 55; y < 60; y++) {
        for (var x = 20; x < 28; x++) {
          final i = (y * img.width + x) * 4;
          if (data[i] > 170 && data[i + 1] < 130) below++;
        }
      }
      img.dispose();
    });
    expect(below, greaterThan(20), reason: 'red pixels below the box: $below');
    expect(tester.getSize(find.byType(KitPenSample)), const Size(60, 34));
  });

  testWidgets('pen art and samples build for every pen', (tester) async {
    const ink = Color(0xff1f2329);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Wrap(
          children: [
            for (final kind in KitPenKind.values) ...[
              SizedBox(
                width: 24,
                height: 100,
                child: KitPenArt(kind, ink, ruler: true),
              ),
              KitPenSample(kind, ink, level: 50, alpha: .5, straight: true),
            ],
          ],
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(
      find.byType(SvgPicture),
      findsNWidgets(KitPenKind.values.length * 2 - 1),
    );
  });

  testWidgets('no pen the app draws through flutter_svg uses a filter', (
    tester,
  ) async {
    const ink = Color(0xff1f2329);
    for (final kind in KitPenKind.values.where((k) => k != KitPenKind.pencil)) {
      expect(
        kitPenSampleSvg(kind, ink, k: kitPenK(kind, 60)),
        isNot(contains('<filter')),
        reason: kind.previewId,
      );
    }
    // The pencil is drawn by a painter (the preview svg needs feTurbulence),
    // every other pen is still the svg.
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Column(
          children: [
            KitPenSample(KitPenKind.pencil, ink, level: 60),
            KitPenSample(KitPenKind.fountain, ink, level: 60),
          ],
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(SvgPicture), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the pencil stroke shows grain, not a flat line', (tester) async {
    Future<ui.Image> render(int level, {required bool straight}) async {
      final key = GlobalKey();
      final watch = Stopwatch()..start();
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Align(
            alignment: Alignment.topLeft,
            child: RepaintBoundary(
              key: key,
              child: ColoredBox(
                color: Colors.white,
                child: SizedBox(
                  width: 600,
                  height: 340,
                  child: KitPenSample(
                    KitPenKind.pencil,
                    const Color(0xff1f2329),
                    level: level,
                    straight: straight,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      debugPrint(
        'pencil level $level: build and first paint ${watch.elapsedMicroseconds} us',
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pump();
      late ui.Image img;
      await tester.runAsync(() async {
        final b =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        img = await b.toImage();
      });
      return img;
    }

    // To look at by eye: build/screen-review/t4-pencil/ (kept after the run).
    final dir = Directory('build/screen-review/t4-pencil')
      ..createSync(recursive: true);
    for (final level in [10, 30, 60, 100]) {
      final img = await render(level, straight: false);
      await tester.runAsync(() async {
        final png = await img.toByteData(format: ui.ImageByteFormat.png);
        File('${dir.path}/pencil-level-$level.png')
            .writeAsBytesSync(png!.buffer.asUint8List());
      });
      img.dispose();
    }
    // Straight strokes at 10 px per unit, centre line y0 = 331 px, columns 20..299
    // (units 2..30, clear of the round cap). The bottom half of the halo is cut
    // by the 34-unit box, so the band is measured on the upper side only.
    // Reference (preview svg rendered in Edge): dark ratio 0.46 (level 60) and
    // 0.39 (level 10), band covered 0.69 (gray < 200), band gray std 39.
    const y0 = 331;
    for (final level in [60, 10]) {
      final wpx = 1.7 * kitPenK(KitPenKind.pencil, level) * 10;
      final img = await render(level, straight: true);
      late List<int> gray;
      await tester.runAsync(() async {
        final data = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!
            .buffer
            .asUint8List();
        gray = [for (var i = 0; i < data.length; i += 4) data[i]];
      });
      img.dispose();
      var ink = 0, dark = 0, outside = 0;
      final band = <int>[];
      for (var y = 0; y < y0; y++) {
        final dist = y0 - y;
        for (var x = 20; x < 300; x++) {
          final g = gray[y * 600 + x];
          if (g < 250) {
            ink++;
            if (g < 60) dark++;
            if (dist > .95 * wpx + 3) outside++;
          }
          if (dist > wpx / 2 + 1 && dist < .95 * wpx - 1) band.add(g);
        }
      }
      // The lower half (y >= y0) holds the same number of core pixels.
      for (var y = y0; y < 340; y++) {
        for (var x = 20; x < 300; x++) {
          final g = gray[y * 600 + x];
          if (g < 250) {
            ink++;
            if (g < 60) dark++;
          }
        }
      }
      final darkRatio = dark / ink;
      debugPrint(
        'pencil level $level: ink $ink dark ${darkRatio.toStringAsFixed(3)}',
      );
      expect(
        darkRatio,
        greaterThanOrEqualTo(.30),
        reason: 'level $level core is near solid ink',
      );
      expect(outside, 0, reason: 'level $level: no ink beyond the halo');
      if (level == 60) {
        final mean = band.reduce((a, b) => a + b) / band.length;
        final sd = math.sqrt(
          band.map((v) => (v - mean) * (v - mean)).reduce((a, b) => a + b) /
              band.length,
        );
        final cover = band.where((g) => g < 200).length / band.length;
        debugPrint(
          'pencil band: cover ${cover.toStringAsFixed(2)} sd ${sd.toStringAsFixed(1)}',
        );
        expect(
          cover,
          inInclusiveRange(.30, .75),
          reason: 'halo is about half covered',
        );
        expect(sd, greaterThan(20), reason: 'halo is mottled');
      }
    }
  });
}
