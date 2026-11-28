import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:perfect_freehand/perfect_freehand.dart';
import 'package:saber/components/kit/kit_pen_art.dart';
import 'package:saber/data/ink/pen_kind.dart';
import 'package:saber/data/ink/stroke_outline.dart';
import 'package:saber/data/ink/stroke_style.dart';
import 'package:sbn/tool_id.dart';

/// The shapes of the new pens: the chisel nib, the dashed line and the brush.
void main() {
  /// A straight line of [length] px from the origin along [degrees]; 0 is
  /// right, 90 is up (the same angle as the nib).
  List<Offset> line(double degrees, {double length = 100, int steps = 10}) {
    final r = degrees * math.pi / 180;
    final dir = Offset(math.cos(r), -math.sin(r));
    return [for (var i = 0; i <= steps; i++) dir * (length * i / steps)];
  }

  /// The distance from the centre line (the line through the nearest
  /// segment, so the nib overhang past an end does not count as thickness).
  double distanceToPolyline(Offset p, List<Offset> centre) {
    var best = double.infinity;
    for (var i = 0; i < centre.length - 1; i++) {
      final ab = centre[i + 1] - centre[i];
      final ap = p - centre[i];
      final cross = (ab.dx * ap.dy - ab.dy * ap.dx).abs() / ab.distance;
      best = math.min(best, cross);
    }
    return best;
  }

  /// The thickness: twice the farthest hit point from the centre line. Valid
  /// for straight lines only: the distance is measured to the line through
  /// the nearest segment.
  double thickness(InkOutline o, List<Offset> centre) =>
      o.hitPolygon.map((p) => distanceToPolyline(p, centre)).reduce(math.max) *
      2;

  test(
    'a 45 degree nib draws a line across the nib thicker than one along it',
    () {
      final across = line(135);
      final along = line(45);
      final a = chiselOutline(
        across,
        width: 10,
        angleDegrees: 45,
        minThickness: 2,
      );
      final b = chiselOutline(
        along,
        width: 10,
        angleDegrees: 45,
        minThickness: 2,
      );
      expect(thickness(a, across), closeTo(10, 0.5));
      expect(thickness(b, along), inInclusiveRange(2, 2.5));
      expect(a.path.getBounds().isEmpty, isFalse);
    },
  );

  test('the chisel highlighter nib at 90 degrees is flat-ended', () {
    final centre = line(0);
    final o = chiselOutline(
      centre,
      width: 20,
      angleDegrees: 90,
      minThickness: 2,
    );
    for (final p in [o.hitPolygon.first, o.hitPolygon.last]) {
      expect(p.dx, closeTo(centre.first.dx, 0.001));
    }
    expect(
      (o.hitPolygon.first - o.hitPolygon.last).distance,
      closeTo(20, 0.001),
    );
  });

  test('pressure scales the nib length', () {
    final centre = line(135);
    double thick(double pressure) => thickness(
      chiselOutline(
        centre,
        width: 10,
        angleDegrees: 45,
        minThickness: 2,
        pressure: List.filled(centre.length, pressure),
      ),
      centre,
    );
    expect(thick(0.5), closeTo(thick(1) / 2, thick(1) / 2 * 0.1));
  });

  test('a dashed line has gaps and a dotted line has shorter pieces', () {
    final centre = line(0);
    List<double> pieces(KitPenDash style) => dashedOutline(
      centre,
      width: 4,
      style: style,
    ).path.computeMetrics().map((m) => m.length).toList();
    final dash = pieces(KitPenDash.dash);
    final dot = pieces(KitPenDash.dot);
    double mean(List<double> l) => l.reduce((a, b) => a + b) / l.length;
    expect(dash.length, greaterThanOrEqualTo(2));
    expect(dot.length, greaterThan(dash.length));
    expect(mean(dot), lessThan(mean(dash)));
    expect(
      dashedOutline(centre, width: 4, style: KitPenDash.dash).hitPolygon,
      isNotEmpty,
    );
  });

  test('a dash leaves the preview gap of about a third of a width', () {
    // the preview draws 7 : 4.6 at a width of 3.6 with round caps: a visible
    // gap of 4.6 - 3.6 = 1.0
    final path = dashedOutline(
      line(0),
      width: 3.6,
      style: KitPenDash.dash,
    ).path;
    final pieces = path.computeMetrics().toList();
    expect(pieces.length, greaterThanOrEqualTo(3));
    for (var i = 1; i < pieces.length; i++) {
      final previousEnd = pieces[i - 1]
          .getTangentForOffset(pieces[i - 1].length)!
          .position;
      final nextStart = pieces[i].getTangentForOffset(0)!.position;
      expect(nextStart.dx - previousEnd.dx - 3.6, closeTo(1.0, 0.3));
    }
  });

  test('brush options taper both ends and simulate pressure', () {
    final base = StrokeOptions(size: 8, thinning: 0.1);
    final o = brushOptions(base);
    expect(o.thinning, greaterThan(base.thinning));
    expect(o.start.taperEnabled, isTrue);
    expect(o.end.taperEnabled, isTrue);
    expect(o.simulatePressure, isTrue);
    expect(o.size, base.size);
    expect(brushOptions(base, hasPressure: true).simulatePressure, isFalse);
  });

  test('kindOfStroke tells chisel and round highlighters apart', () {
    expect(
      kindOfStroke(ToolId.highlighter, const StrokeStyle(nib: InkNib.chisel)),
      KitPenKind.highlighterChisel,
    );
    expect(
      kindOfStroke(ToolId.highlighter, const StrokeStyle()),
      KitPenKind.highlighterRound,
    );
    expect(
      kindOfStroke(ToolId.calligraphyPen, const StrokeStyle()),
      KitPenKind.calligraphy,
    );
    expect(kindOfStroke(ToolId.brush, const StrokeStyle()), KitPenKind.brush);
    expect(
      kindOfStroke(ToolId.fountainPen, const StrokeStyle()),
      KitPenKind.fountain,
    );
    expect(
      kindOfStroke(ToolId.ballpointPen, const StrokeStyle()),
      KitPenKind.finePen,
    );
    expect(kindOfStroke(ToolId.pencil, const StrokeStyle()), KitPenKind.pencil);
    for (final kind in KitPenKind.values) {
      final spec = specOf(kind);
      expect(spec.minSize, lessThan(spec.maxSize));
      expect(
        kindOfStroke(spec.toolId!, StrokeStyle(nib: spec.nib)),
        kind,
        reason: kind.label,
      );
    }
    expect(specOf(KitPenKind.highlighterChisel).nib, InkNib.chisel);
    expect(specOf(KitPenKind.calligraphy).nib, InkNib.chisel);
    expect(specOf(KitPenKind.highlighterRound).nib, InkNib.round);
  });

  Offset nibDir(double degrees) => Offset(
    math.cos(degrees * math.pi / 180),
    -math.sin(degrees * math.pi / 180),
  );

  test('the drawn path of a 45 degree nib covers the nib and no more', () {
    final centre = line(135);
    final mid = centre[5];
    final o = chiselOutline(
      centre,
      width: 10,
      angleDegrees: 45,
      minThickness: 2,
    );
    final bounds = o.path.getBounds();
    expect(bounds.width, closeTo((100 + 10) * math.cos(math.pi / 4), 0.01));
    expect(bounds.height, closeTo((100 + 10) * math.cos(math.pi / 4), 0.01));
    expect(o.path.contains(mid), isTrue);
    expect(o.path.contains(mid + nibDir(45) * 4), isTrue);
    expect(o.path.contains(mid + nibDir(45) * 8), isFalse);
    expect(o.path.contains(mid - nibDir(45) * 8), isFalse);
  });

  test('the drawn path is filled between neighbouring points', () {
    final centre = line(135);
    final o = chiselOutline(
      centre,
      width: 10,
      angleDegrees: 45,
      minThickness: 2,
    );
    for (var k = 0; k < centre.length - 1; k++) {
      final mid = (centre[k] + centre[k + 1]) / 2;
      expect(o.path.contains(mid + nibDir(45) * 3), isTrue, reason: '$k');
      expect(o.path.contains(mid - nibDir(45) * 3), isTrue, reason: '$k');
    }
  });

  test('the drawn path between points of different pressure tapers', () {
    final centre = line(135);
    final o = chiselOutline(
      centre,
      width: 10,
      angleDegrees: 45,
      minThickness: 2,
      pressure: [1, 0.5, ...List.filled(centre.length - 2, 0.5)],
    );
    // half the nib is 5 at the first point and 2.5 at the second: 3.75 between
    final mid = (centre[0] + centre[1]) / 2;
    expect(o.path.contains(mid + nibDir(45) * 3), isTrue);
    expect(o.path.contains(mid - nibDir(45) * 3), isTrue);
    expect(o.path.contains(mid + nibDir(45) * 4.5), isFalse);
    expect(o.path.contains(mid - nibDir(45) * 4.5), isFalse);
  });

  test('the drawn path follows the pressure', () {
    final centre = line(135);
    final mid = centre[5];
    final o = chiselOutline(
      centre,
      width: 10,
      angleDegrees: 45,
      minThickness: 2,
      pressure: List.filled(centre.length, 0.5),
    );
    expect(o.path.contains(mid + nibDir(45) * 2), isTrue);
    expect(o.path.contains(mid + nibDir(45) * 4), isFalse);
  });

  test('a single point or two equal points leave a nib-sized mark', () {
    const p = Offset(50, 60);
    for (final centre in [
      [p],
      [p, p],
    ]) {
      final o = chiselOutline(
        centre,
        width: 10,
        angleDegrees: 45,
        minThickness: 2,
      );
      final bounds = o.path.getBounds();
      expect(bounds.isEmpty, isFalse);
      expect(bounds.width * bounds.height, greaterThan(0));
      expect(o.path.contains(p), isTrue);
      expect(o.path.contains(p + nibDir(45) * 4), isTrue);
      expect(o.path.contains(p + nibDir(45) * 8), isFalse);
      expect(o.hitPolygon, isNotEmpty);
    }
  });

  test('a tap has a hit polygon with area that contains the point', () {
    const p = Offset(50, 60);
    for (final centre in [
      [p],
      [p, p],
    ]) {
      final o = chiselOutline(
        centre,
        width: 10,
        angleDegrees: 45,
        minThickness: 2,
      );
      expect(_inside(o.hitPolygon, p), isTrue);
      expect(_inside(o.hitPolygon, p + nibDir(45) * 4), isTrue);
      expect(_inside(o.hitPolygon, p + nibDir(45) * 8), isFalse);
    }
  });

  test('a nib a degree off the travel still has its overhang in the hit', () {
    final centre = line(0, length: 200);
    final o = chiselOutline(
      centre,
      width: 100,
      angleDegrees: 1,
      minThickness: 2,
    );
    expect(_inside(o.hitPolygon, centre.last + nibDir(1) * 30), isTrue);
    expect(_inside(o.hitPolygon, centre.first - nibDir(1) * 30), isTrue);
  });

  test('the hit polygon reaches the nib overhang past the stroke ends', () {
    // a flat highlighter of width 100 drawn along its own nib
    final centre = line(0, length: 200);
    final o = chiselOutline(
      centre,
      width: 100,
      angleDegrees: 0,
      minThickness: 2,
    );
    expect(_inside(o.hitPolygon, centre.last + const Offset(30, 0)), isTrue);
    expect(_inside(o.hitPolygon, centre.first - const Offset(30, 0)), isTrue);
    expect(_inside(o.hitPolygon, centre.last + const Offset(60, 0)), isFalse);
    expect(o.path.contains(centre.last + const Offset(30, 0)), isTrue);
  });
}

/// Whether [p] is inside the polygon (even-odd).
bool _inside(List<Offset> poly, Offset p) {
  var inside = false;
  for (var i = 0, j = poly.length - 1; i < poly.length; j = i++) {
    final a = poly[i], b = poly[j];
    if ((a.dy > p.dy) != (b.dy > p.dy) &&
        p.dx < (b.dx - a.dx) * (p.dy - a.dy) / (b.dy - a.dy) + a.dx) {
      inside = !inside;
    }
  }
  return inside;
}
