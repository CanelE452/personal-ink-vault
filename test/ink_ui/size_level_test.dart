import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/ink_ui/pen_panel/size_level.dart';

void main() {
  test('every level survives the size round trip', () {
    for (final (min, max) in [(1.0, 25.0), (1.0, 15.0), (10.0, 100.0)]) {
      for (var l = 1; l <= 100; l++) {
        expect(
          sizeToLevel(
            levelToSize(l, min: min, max: max),
            min: min,
            max: max,
          ),
          l,
          reason: 'level $l on $min-$max',
        );
      }
    }
    expect(levelToSize(1, min: 1, max: 25), 1);
    expect(levelToSize(100, min: 1, max: 25), 25);
    expect(levelToSize(50, min: 1, max: 25), closeTo(12.879, 0.001));
    expect(sizeToLevel(13, min: 1, max: 25), 51);
    expect(sizeToLevel(0, min: 1, max: 25), 1);
  });
}
