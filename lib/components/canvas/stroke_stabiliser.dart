import 'dart:math';
import 'dart:ui' show Offset;

import 'package:perfect_freehand/perfect_freehand.dart';

/// Smooths a stroke along its length while it is drawn: the pen panel's
/// stroke stabilisation.
///
/// Each point becomes a Gaussian average of the points around it, weighted
/// by their distance along the stroke ([sigma], in page units). Distances
/// are measured on a lightly averaged copy of the stroke, so jitter does not
/// stretch them. Past either end the stroke is mirrored through its end
/// point, so it still starts where the pen touched down and ends where the
/// pen is now: nothing trails the pen. Pressure stays as the pen gave it.
///
/// Unlike perfect_freehand's streamline, which pulls each point back toward
/// the previous ones, this takes out a slow stroke's wobble without shrinking
/// quick loops (measured in `_docs/history/2026-11-16.md`).
class StrokeStabiliser {
  new(this.sigma) : assert(sigma > 0);

  /// The Gaussian's width along the stroke, in page units.
  final double sigma;

  final _raw = <PointVector>[];

  /// [_raw] averaged over [_guideReach] points on each side.
  final _guide = <Offset>[];

  /// The distance along [_guide] to each point.
  final _along = <double>[];

  static const _guideReach = 2;

  /// The most points averaged on each side of a point, counting mirrored
  /// ones by where they stand. Writing never gathers this many within the
  /// Gaussian's reach, but a resting pen piles hundreds into one spot, and
  /// each new point would otherwise average all of them again.
  static const _maxSide = 48;

  /// [raw] smoothed as a whole.
  static List<PointVector> smooth(List<PointVector> raw, double sigma) {
    final stabiliser = StrokeStabiliser(sigma);
    stabiliser._raw.addAll(raw);
    stabiliser._measure(0);
    final smoothed = <PointVector>[];
    stabiliser._rewrite(0, smoothed);
    return smoothed;
  }

  /// Takes the pen's next point and brings [smoothed], the stroke's points,
  /// up to date. Only its tail changes.
  void add(PointVector point, List<PointVector> smoothed) {
    _raw.add(point);
    // The new point changes the guide's last few points (their averages
    // shrank at the end) and so the distances from there on.
    final changed = max(0, _raw.length - 1 - _guideReach);
    _measure(changed);
    // Points whose averages reach a changed distance, or the mirror past the
    // end, are averaged again; an average reaches at most _maxSide points.
    var from = changed;
    if (changed > 0) {
      final reach = _along[changed - 1] - 3 * sigma;
      while (from > 0 &&
          from > changed - _maxSide &&
          _along[from - 1] >= reach) {
        from--;
      }
    }
    _rewrite(from, smoothed);
  }

  void _measure(int from) {
    final n = _raw.length;
    _guide.removeRange(from, _guide.length);
    _along.removeRange(from, _along.length);
    for (var i = from; i < n; i++) {
      final reach = min(_guideReach, min(i, n - 1 - i));
      var x = 0.0, y = 0.0;
      for (var j = i - reach; j <= i + reach; j++) {
        x += _raw[j].x;
        y += _raw[j].y;
      }
      final count = 2 * reach + 1;
      _guide.add(Offset(x / count, y / count));
      _along.add(i == 0 ? 0 : _along[i - 1] + (_guide[i] - _guide[i - 1]).distance);
    }
  }

  void _rewrite(int from, List<PointVector> smoothed) {
    final n = _raw.length;
    smoothed.removeRange(min(from, smoothed.length), smoothed.length);
    final reach = 3 * sigma;
    final total = _along[n - 1];
    final first = _raw.first, last = _raw[n - 1];
    var start = max(0, from - _maxSide);
    for (var i = from; i < n; i++) {
      final point = _raw[i];
      if (i == 0 || i == n - 1) {
        smoothed.add(point);
        continue;
      }
      final at = _along[i];
      var x = 0.0, y = 0.0, weights = 0.0;
      void take(double distance, double px, double py) {
        final d = distance - at;
        final weight = exp(-d * d / (2 * sigma * sigma));
        x += px * weight;
        y += py * weight;
        weights += weight;
      }

      final upTo = min(n - 1, i + _maxSide);
      while (start < i - _maxSide || _along[start] < at - reach) {
        start++;
      }
      for (var j = start; j <= upTo && _along[j] <= at + reach; j++) {
        take(_along[j], _raw[j].x, _raw[j].y);
      }
      // Before the start: the stroke mirrored through its first point (point
      // j stands at -j there).
      for (var j = 1;
          j < n && j <= _maxSide - i && _along[j] <= reach - at;
          j++) {
        take(-_along[j], 2 * first.x - _raw[j].x, 2 * first.y - _raw[j].y);
      }
      // Past the end: the stroke mirrored through the pen's point (point j
      // stands at 2(n - 1) - j there).
      for (var j = n - 2;
          j >= 0 &&
              j >= 2 * (n - 1) - i - _maxSide &&
              _along[j] >= 2 * total - at - reach;
          j--) {
        take(
          2 * total - _along[j],
          2 * last.x - _raw[j].x,
          2 * last.y - _raw[j].y,
        );
      }
      smoothed.add(PointVector(x / weights, y / weights, point.pressure));
    }
  }
}
