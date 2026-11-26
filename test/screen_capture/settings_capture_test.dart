import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/kit/kit_icon.dart';
import 'package:saber/data/actions/app_action.dart';
import 'package:saber/data/actions/app_action_ids.dart';
import 'package:saber/data/actions/app_action_registry.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/settings/setting_entry.dart';
import 'package:saber/data/settings/settings_registry.dart';
import 'package:saber/pages/settings/app_settings_page.dart';
import 'package:saber/pages/settings/settings_entries.dart';

import '../utils/screen_capture.dart';

/// Writes screenshots of the settings screens to build/screen-review/t9/.
/// Runs only with PIV_CAPTURE=1 so the normal suite writes no files.
final _capture = Platform.environment['PIV_CAPTURE'] == '1';
final _outDir = captureDir('build/screen-review/t9');
const _latin = captureLatin;
const _korean = captureKorean;

Future<void> _shoot(
  WidgetTester tester,
  GlobalKey boundary,
  String name,
) async {
  // flutter_test draws shadows without blur (debugDisableShadows); the app
  // draws them blurred (the switch thumb), so they are turned on for the
  // picture. The flag must be back before the test ends.
  debugDisableShadows = false;
  try {
    void mark(RenderObject o) {
      o.markNeedsPaint();
      o.visitChildren(mark);
    }

    mark(boundary.currentContext!.findRenderObject()!);
    await tester.pump();
    await tester.runAsync(() async {
      final object =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await object.toImage(pixelRatio: 2);
      final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      Directory(_outDir).createSync(recursive: true);
      File('$_outDir/$name').writeAsBytesSync(bytes.buffer.asUint8List());
    });
  } finally {
    debugDisableShadows = true;
  }
}

/// The preview's heights (9구역, logical px) with the real fonts: a row is 38
/// with one name line and 14 more per note line, a value-chip row without a
/// note 41.8, a chip 22.8, a group header 33.5, the search box 29.1. The test
/// font of the other tests cannot see a line that mixes the app font with the
/// Korean fallback font, so these are measured here.
void _expectPreviewHeights(WidgetTester tester, SettingsRegistry reg) {
  final off = <String>[];
  double check(String what, Finder finder, double preview) {
    final height = tester.getSize(finder).height;
    if ((height - preview).abs() > 0.5) off.add('$what: $height, preview $preview');
    return height;
  }

  Finder key(String value) => find.byKey(ValueKey(value));
  check('search box', key('settings-search-box'), 29.1);
  for (final group in reg.groups) {
    check('header $group', key('settings-head-$group'), 33.5);
  }
  final kinds = <String>{};
  for (final e in reg.entries) {
    final row = key('settings-row-${e.key}');
    if (e is ChoiceSetting) {
      check('chip ${e.label}', key('settings-chip-${e.key}'), 22.8);
    }
    if (e is ChoiceSetting && e.description == null) {
      kinds.add('chip row');
      check(e.label, row, 41.8);
    } else if (e.description == null) {
      kinds.add('one line');
      check(e.label, row, 38);
    } else {
      // A long note wraps; each of its lines is 14.
      kinds.add('with a note');
      final height = tester.getSize(row).height;
      final lines = math.max(1, ((height - 38) / 14).round());
      check('${e.label} ($lines note lines)', row, 38 + 14.0 * lines);
    }
  }
  expect(kinds, {'chip row', 'one line', 'with a note'});
  expect(
    off,
    isEmpty,
    reason: 'heights off the preview by more than 0.5:\n${off.join('\n')}',
  );
}

Widget _framed(GlobalKey boundary, Widget child) => RepaintBoundary(
  key: boundary,
  child: MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData(fontFamily: _latin, fontFamilyFallback: const [_korean]),
    home: child,
  ),
);

Future<void> _capturePage(
  WidgetTester tester,
  double width,
  double height,
  String file,
) async {
  await tester.runAsync(loadCaptureFonts);
  tester.view.physicalSize = Size(width * 2, height * 2);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final reg = SettingsRegistry(reasons: ValueNotifier(<String, String>{}));
  registerSettingsEntries(reg);
  addTearDown(reg.dispose);
  final acts = AppActionRegistry();
  addTearDown(acts.dispose);
  acts.publish(Object(), [
    for (final (id, icon) in const [
      (AppActionIds.localVaults, KitIconName.folder),
      (AppActionIds.backup, KitIconName.upload),
      (AppActionIds.restore, KitIconName.history),
      (AppActionIds.vaultExport, KitIconName.share),
      (AppActionIds.mcp, KitIconName.ai),
      (AppActionIds.openNoteLink, KitIconName.link),
      (AppActionIds.viewLogs, KitIconName.doc),
      (AppActionIds.openDataDir, KitIconName.open),
    ])
      AppAction(id: id, label: id, icon: icon, run: (_) {}),
  ]);
  final boundary = GlobalKey();
  await tester.pumpWidget(
    _framed(boundary, AppSettingsPage(actions: acts, registry: reg)),
  );
  await tester.pumpAndSettle();
  await _shoot(tester, boundary, file);
  _expectPreviewHeights(tester, reg);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();

  testWidgets('settings page 876 wide', (tester) async {
    await _capturePage(tester, 876, 1600, 'app-settings-page.png');
  }, skip: !_capture);

  testWidgets('settings page 400 wide', (tester) async {
    await _capturePage(tester, 400, 2300, 'app-settings-page-400.png');
  }, skip: !_capture);
}
