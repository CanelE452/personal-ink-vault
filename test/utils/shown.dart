import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// How much of [f] shows: the fades above it multiplied (0 once it is not
/// built).
double shownOf(WidgetTester tester, Finder f) {
  if (f.evaluate().isEmpty) return 0;
  var opacity = 1.0;
  for (final fade in tester.widgetList<FadeTransition>(
    find.ancestor(of: f, matching: find.byType(FadeTransition)),
  )) {
    opacity *= fade.opacity.value;
  }
  return opacity;
}

/// Whether a press at the middle of [f] reaches it.
bool takesPresses(WidgetTester tester, Finder f) {
  final target = tester.renderObject(f);
  final result = HitTestResult();
  tester.binding.hitTestInView(result, tester.getCenter(f), tester.view.viewId);
  return result.path.any((entry) => entry.target == target);
}
