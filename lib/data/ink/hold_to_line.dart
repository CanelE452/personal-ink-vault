import 'dart:ui' show Offset;

/// How long the pen stays still while drawing before the stroke becomes a
/// line (「멈추면 직선」, user answer 2).
///
/// 0.5 s and [holdToLineSlop] are the controller's values, not measured
/// against Samsung Notes or GoodNotes, which have the same gesture: tablet
/// measurement 1 tunes them, one constant each. They judge input, so they
/// are not screen timings of kit_motion.dart.
const holdToLineDelay = Duration(milliseconds: 500);

/// How far, in logical pixels on screen, the pen may wander and still count
/// as staying still for [holdToLineDelay].
const holdToLineSlop = 8.0;

/// 「멈추면 직선」 of one stroke by position: where the pen last stopped, and
/// whether the stroke has become a line. It keeps no time: its host (the
/// editor's ink input, the quick note) waits [holdToLineDelay] from each
/// [moved] that is true, not from [start] (a pause where the pen touched
/// down, before writing, keeps the stroke freehand), and calls [turn] when
/// the wait ends.
class HoldToLine {
  /// [slop] is in the stroke's own units: the host divides [holdToLineSlop]
  /// by the page's scale on screen.
  new({required this.slop});

  final double slop;

  var _anchor = Offset.zero;
  var _isLine = false;

  /// The stroke is a line from its first point; only its end follows the
  /// pen.
  bool get isLine => _isLine;

  /// A stroke starts at [point], freehand.
  void start(Offset point) {
    _anchor = point;
    _isLine = false;
  }

  /// The pen is at [point]. True, and [point] is where the pen stays from
  /// now on, when it is farther than [slop] from where it stayed; always
  /// false once the stroke is a line.
  bool moved(Offset point) {
    if (_isLine || (point - _anchor).distance <= slop) return false;
    _anchor = point;
    return true;
  }

  /// The pen stayed still long enough: the stroke becomes a line.
  void turn() => _isLine = true;
}
