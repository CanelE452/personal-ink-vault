import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:path_drawing/path_drawing.dart';
import 'package:perfect_freehand/perfect_freehand.dart';
import 'package:saber/components/kit/kit_pen_art.dart';

/// What a pen draws: the [path] to paint, and [hitPolygon], the points on both
/// edges of the centre line that the eraser and the lasso test against.
@immutable
class InkOutline {
  const new({required this.path, required this.hitPolygon});

  final Path path;
  final List<Offset> hitPolygon;
}

/// The outline of a stroke written with a flat chisel nib held at
/// [angleDegrees] (0 is right, 90 is up). Each pair of neighbouring points
/// gives a quadrangle between two nib-long lines, so the stroke is thick
/// across the nib and thin along it, never thinner than [minThickness]. A
/// [pressure] per point (0 to 1) multiplies the nib length.
InkOutline chiselOutline(
  List<Offset> centre, {
  required double width,
  required double angleDegrees,
  required double minThickness,
  List<double>? pressure,
}) {
  final path = Path();
  if (centre.isEmpty) return InkOutline(path: path, hitPolygon: const []);
  final r = angleDegrees * math.pi / 180;
  final dir = Offset(math.cos(r), -math.sin(r));

  final left = <Offset>[];
  final right = <Offset>[];
  for (var i = 0; i < centre.length; i++) {
    final p = pressure != null && i < pressure.length ? pressure[i] : 1.0;
    final half = math.max(minThickness, width * p) / 2;
    left.add(centre[i] - dir * half);
    right.add(centre[i] + dir * half);
  }

  // One point, or points that all lie on one spot, still leave a mark: a
  // small closed quadrangle along the nib.
  final first = centre.first;
  if (centre.every((c) => c == first)) {
    final across = Offset(-dir.dy, dir.dx) * (minThickness / 2);
    final tap = [
      left[0] - across,
      right[0] - across,
      right[0] + across,
      left[0] + across,
    ];
    path.addPolygon(tap, true);
    // the same quadrangle for the eraser and the lasso
    return InkOutline(path: path, hitPolygon: tap);
  }
  for (var i = 0; i < centre.length - 1; i++) {
    final quad = [left[i], right[i], right[i + 1], left[i + 1]];
    // one winding for all, so overlapping quadrangles never cancel
    var area = 0.0;
    for (var k = 0; k < 4; k++) {
      final a = quad[k], b = quad[(k + 1) % 4];
      area += a.dx * b.dy - b.dx * a.dy;
    }
    final ordered = area < 0 ? quad.reversed.toList() : quad;
    path.addPolygon(ordered, true);
  }

  // The hit polygon follows the two sides of the stroke: each point is moved
  // across the travel direction by the part of the nib that lies across it
  // (never less than the minimum thickness), so a line along the nib is thin.
  // The nib itself reaches past the first and the last point, so the ends are
  // capped with the nib end points, as drawn.
  final sideA = <Offset>[];
  final sideB = <Offset>[];
  final unitAt = <Offset?>[];
  for (var i = 0; i < centre.length; i++) {
    final nibHalf = (right[i] - left[i]) / 2;
    final travel =
        centre[math.min(centre.length - 1, i + 1)] - centre[math.max(0, i - 1)];
    if (travel.distance == 0) {
      unitAt.add(null);
      sideA.add(centre[i] - nibHalf);
      sideB.add(centre[i] + nibHalf);
      continue;
    }
    final unit = travel / travel.distance;
    unitAt.add(unit);
    final normal = Offset(-unit.dy, unit.dx);
    final across = (nibHalf.dx * normal.dx + nibHalf.dy * normal.dy).abs();
    final half = math.max(minThickness / 2, across);
    sideA.add(centre[i] - normal * half);
    sideB.add(centre[i] + normal * half);
  }

  /// The nib end points at point [i], the ones on the -normal side first, or
  /// none where the travel is unknown. [forward] is whether the cap closes
  /// the end of the stroke.
  List<Offset> cap(int i, {required bool forward}) {
    final unit = unitAt[i];
    if (unit == null) return const [];
    final normal = Offset(-unit.dy, unit.dx);
    double side(Offset e) =>
        (e - centre[i]).dx * -normal.dx + (e - centre[i]).dy * -normal.dy;
    double along(Offset e) =>
        (e - centre[i]).dx * unit.dx + (e - centre[i]).dy * unit.dy;
    final ends = [left[i], right[i]];
    // nearly along the travel is judged against the nib length: a nib a degree
    // off would otherwise draw a hair-thin cap with the tip on its edge
    final nibHalfLength = (right[i] - left[i]).distance / 2;
    if (ends.every((e) => side(e).abs() < 0.1 * nibHalfLength)) {
      // the nib lies along the travel: only the end that sticks out
      ends.sort((x, y) => along(x).compareTo(along(y)));
      return [if (forward) ends.last else ends.first];
    }
    ends.sort((x, y) => side(y).compareTo(side(x)));
    return ends;
  }

  final startCap = cap(0, forward: false);
  final endCap = cap(centre.length - 1, forward: true);
  return InkOutline(
    path: path,
    hitPolygon: [
      ...startCap.take(1),
      ...sideA,
      ...endCap,
      ...sideB.reversed,
      ...startCap.skip(1),
    ],
  );
}

/// A line of [width] px along [centre] that is cut into pieces with round
/// ends, for [KitPenDash.dash] and [KitPenDash.dot]. The other styles give
/// the line unbroken. The path is meant to be stroked with [width] and round
/// caps, not filled.
InkOutline dashedOutline(
  List<Offset> centre, {
  required double width,
  required KitPenDash style,
}) {
  final line = Path();
  if (centre.isNotEmpty) {
    line.moveTo(centre.first.dx, centre.first.dy);
    if (centre.length == 2) line.lineTo(centre[1].dx, centre[1].dy);
    for (var i = 1; i < centre.length - 1; i++) {
      // smooth through the middles of the segments
      final mid = (centre[i] + centre[i + 1]) / 2;
      line.quadraticBezierTo(centre[i].dx, centre[i].dy, mid.dx, mid.dy);
    }
    if (centre.length > 2) line.lineTo(centre.last.dx, centre.last.dy);
  }

  // A piece is the "on" length of a stroke-dasharray and a space is its "off"
  // length. With round caps a piece shows [width] longer than its length and
  // the visible gap is [width] shorter than the space: gap = space - width.
  // The dash is the preview's dasharray 7 : 4.6 at a width of 3.6, so a piece
  // of 7 / 3.6 widths and a space of 4.6 / 3.6 widths (a visible gap of about
  // 0.28 widths). The dot is the preview's piece 0.55 * width + 0.44 (shown
  // 1.55 * width + 0.44 long) with a gap of 2 px.
  final path = switch (style) {
    KitPenDash.dash => dashPath(
      line,
      dashArray: CircularIntervalList<double>([
        width * 7 / 3.6,
        width * 4.6 / 3.6,
      ]),
    ),
    KitPenDash.dot => dashPath(
      line,
      dashArray: CircularIntervalList<double>([width * 0.55 + 0.44, width + 2]),
    ),
    KitPenDash.solid || KitPenDash.thin => line,
  };

  final half = width / 2;
  final left = <Offset>[];
  final right = <Offset>[];
  for (var i = 0; i < centre.length; i++) {
    final a = centre[math.max(0, i - 1)];
    final b = centre[math.min(centre.length - 1, i + 1)];
    final d = b - a;
    final n = d.distance == 0
        ? Offset.zero
        : Offset(-d.dy, d.dx) / d.distance * half;
    left.add(centre[i] + n);
    right.add(centre[i] - n);
  }
  return InkOutline(path: path, hitPolygon: [...left, ...right.reversed]);
}

/// [base] for the brush: strong thinning with speed or pressure, both ends
/// tapered. Pressure is simulated unless the input has a real [hasPressure].
StrokeOptions brushOptions(StrokeOptions base, {bool hasPressure = false}) =>
    base.copyWith(
      thinning: 0.8,
      smoothing: 0.6,
      streamline: 0.5,
      simulatePressure: !hasPressure,
      start: StrokeEndOptions.start(taperEnabled: true),
      end: StrokeEndOptions.end(taperEnabled: true),
    );
