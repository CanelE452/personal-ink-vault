import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/ink/hold_to_line.dart';

/// 「멈추면 직선」 by position only: the hosts keep the time.
void main() {
  test('start sets the anchor to the first point', () {
    final hold = HoldToLine(slop: 8)..start(const Offset(10, 10));
    expect(hold.isLine, isFalse);
    // within 8 of the first point: still there
    expect(hold.moved(const Offset(17.9, 10)), isFalse);
    expect(hold.moved(const Offset(10, 2.1)), isFalse);
    // a new stroke starts from its own first point
    hold.start(const Offset(100, 100));
    expect(hold.moved(const Offset(105, 100)), isFalse);
    expect(hold.moved(const Offset(108.5, 100)), isTrue);
  });

  test('moved is true only past the slop and moves the anchor', () {
    final hold = HoldToLine(slop: 8)..start(Offset.zero);
    expect(hold.moved(const Offset(5, 0)), isFalse);
    expect(hold.moved(const Offset(8, 0)), isFalse);
    expect(hold.moved(const Offset(9, 0)), isTrue);
    // measured from (9, 0) now
    expect(hold.moved(const Offset(15, 0)), isFalse);
    expect(hold.moved(const Offset(9, 7)), isFalse);
    expect(hold.moved(const Offset(18, 0)), isTrue);
    expect(hold.moved(const Offset(18, 0)), isFalse);
    expect(hold.isLine, isFalse);
  });

  test('moved does nothing after the turn', () {
    final hold = HoldToLine(slop: 8)..start(Offset.zero);
    hold.turn();
    expect(hold.isLine, isTrue);
    expect(hold.moved(const Offset(100, 0)), isFalse);
    expect(hold.moved(const Offset(300, 40)), isFalse);
    expect(hold.isLine, isTrue);
    // the next stroke starts freehand again
    hold.start(const Offset(5, 5));
    expect(hold.isLine, isFalse);
    expect(hold.moved(const Offset(50, 5)), isTrue);
  });
}
