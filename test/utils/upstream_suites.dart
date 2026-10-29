import 'package:flutter_test/flutter_test.dart';
import 'package:golden_screenshot/golden_screenshot.dart';

const upstreamGoldens = bool.fromEnvironment('UPSTREAM_GOLDENS');
const upstreamPackaging = bool.fromEnvironment('UPSTREAM_PACKAGING');
const upstreamGoldenReason =
    'Opt-in upstream PNG baselines; unresolved platform/font pixel differences. '
    'Run with --dart-define=UPSTREAM_GOLDENS=true (see docs/upstream-provenance.md).';
const upstreamPackagingReason =
    'Opt-in upstream release fixtures not included in this fork. '
    'Run with --dart-define=UPSTREAM_PACKAGING=true after restoring upstream fixtures.';

void upstreamGolden(
  String name,
  WidgetTesterCallback body, {
  bool skip = false,
}) {
  group('Upstream PNG', () {
    testGoldens(name, body, skip: skip || !upstreamGoldens);
  }, skip: upstreamGoldens ? false : upstreamGoldenReason);
}
