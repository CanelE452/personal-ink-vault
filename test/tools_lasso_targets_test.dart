import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/tools/lasso_targets.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();
  setUp(() {
    for (final target in LassoTargets.all) {
      target.value = target.defaultValue;
    }
  });
  tearDown(() {
    for (final target in LassoTargets.all) {
      target.value = target.defaultValue;
    }
  });

  test(
    'the targets are ink, highlighter, shapes and images, all on at first',
    () {
      expect(LassoTargets.all, [
        stows.selectInk,
        stows.selectHighlighter,
        stows.selectShapes,
        stows.selectImages,
      ]);
      expect(LassoTargets.all.every((t) => t.value), isTrue);
      expect(LassoTargets.all.any(LassoTargets.isLocked), isFalse);
    },
  );

  test('any target may go off while another stays on', () {
    expect(LassoTargets.set(stows.selectInk, false), isTrue);
    expect(stows.selectInk.value, isFalse);
    expect(LassoTargets.isLocked(stows.selectHighlighter), isFalse);
    expect(LassoTargets.set(stows.selectHighlighter, false), isTrue);
    expect(stows.selectHighlighter.value, isFalse);
  });

  test('the last target on cannot go off', () {
    stows.selectInk.value = false;
    stows.selectHighlighter.value = false;
    stows.selectShapes.value = false;
    // only images is on: it is locked, the two off ones are not
    expect(LassoTargets.isLocked(stows.selectImages), isTrue);
    expect(LassoTargets.isLocked(stows.selectInk), isFalse);
    expect(LassoTargets.isLocked(stows.selectHighlighter), isFalse);
    expect(LassoTargets.set(stows.selectImages, false), isFalse);
    expect(stows.selectImages.value, isTrue);
    // turning another one on unlocks it
    expect(LassoTargets.set(stows.selectInk, true), isTrue);
    expect(LassoTargets.isLocked(stows.selectImages), isFalse);
    expect(LassoTargets.set(stows.selectImages, false), isTrue);
    expect(stows.selectImages.value, isFalse);
    expect(LassoTargets.isLocked(stows.selectInk), isTrue);
  });

  test('a target set to what it already is is not refused', () {
    stows.selectInk.value = false;
    stows.selectHighlighter.value = false;
    stows.selectShapes.value = false;
    expect(LassoTargets.set(stows.selectImages, true), isTrue);
    expect(stows.selectImages.value, isTrue);
  });
}
