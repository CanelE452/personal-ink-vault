import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/ink_ui/pen_panel/kit_pen_panel.dart';
import 'package:saber/components/ink_ui/pen_panel/size_level.dart';
import 'package:saber/components/kit/kit_icon.dart';
import 'package:saber/components/kit/kit_pen_art.dart';
import 'package:saber/components/kit/kit_popover.dart';
import 'package:saber/components/kit/kit_text.dart';
import 'package:saber/components/kit/kit_tokens.dart';
import 'package:saber/data/actions/app_action.dart';
import 'package:saber/data/actions/app_action_ids.dart';
import 'package:saber/data/actions/app_action_registry.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/ink/pen_prefs.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/tools/highlighter.dart';
import 'package:saber/data/tools/pen.dart';
import 'package:saber/data/tools/pencil.dart';

import '../ink_ui/pen_panel_harness.dart' show PanelHost, resetPenPanelState;
import '../utils/screen_capture.dart';

/// Writes screenshots of the rows Task 11 adds to the pen panels (the eraser
/// and lasso windows are the 10th draft's now, eraser_lasso_capture_test.dart)
/// to build/screen-review/t11/ with the app's fonts
/// (Atkinson with the Korean fallback), at device pixel ratio 2, beside the
/// preview's renders there (ref-*.png). Runs only with PIV_CAPTURE=1 so the
/// normal suite writes no files.
final _capture = Platform.environment['PIV_CAPTURE'] == '1';
final _outDir = captureDir('build/screen-review/t11');
const _latin = captureLatin;
const _korean = captureKorean;
const _screen = Size(360, 640);

/// The preview's own example pens (`SP`, lines 2104-2121): the fine pen in
/// red at 37 (its stabiliser at the default 50 %), the chisel highlighter red
/// at 51, the example recent and pinned colours.
void _previewPens() {
  const red = 0xffe5323e;
  stows.lastFountainPenColor.value = 0xff2f55d4;
  stows.lastBallpointPenColor.value = red;
  stows.lastPencilColor.value = 0xff6f7278;
  stows.lastHighlighterColor.value = red;
  stows.autoStraightenLines.value = false;
  stows.recentColorsPositioned.value = [
    for (final c in const [
      0xff24304a,
      0xffe7a92b,
      0xff2f6ae0,
      0xffd94f30,
      0xff3d8b6e,
    ])
      '$c',
  ];
  stows.pinnedColors.value = [
    for (final c in const [red, 0xffa0c4ff, 0xff424242]) '$c',
  ];
  final fine = Pen.ballpointPen();
  fine.options = fine.options.copyWith(
    size: levelToSize(37, min: fine.sizeMin, max: fine.sizeMax),
  );
  Pen.currentPen = fine;
  Pencil.currentPencil = Pencil();
  final hl = Highlighter();
  hl.options = hl.options.copyWith(
    size: levelToSize(51, min: hl.sizeMin, max: hl.sizeMax),
  );
  Highlighter.currentHighlighter = hl;
}

/// Marks every render object under [boundary] for painting, so a changed
/// painting flag reaches the layers that repaint boundaries keep.
void _repaintAll(GlobalKey boundary) {
  void mark(RenderObject o) {
    o.markNeedsPaint();
    o.visitChildren(mark);
  }

  mark(boundary.currentContext!.findRenderObject()!);
}

Future<void> _shoot(
  WidgetTester tester,
  GlobalKey boundary,
  String name,
) async {
  // flutter_test draws shadows without blur (debugDisableShadows); the app
  // draws them blurred, so they are turned on for the picture. The flag must
  // be back before the test ends.
  debugDisableShadows = false;
  try {
    _repaintAll(boundary);
    // flutter_svg decodes off the frame: let it finish, then draw once more.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump();
    await tester.runAsync(() async {
      final object =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await object.toImage(pixelRatio: 2);
      final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      Directory(_outDir).createSync(recursive: true);
      File('$_outDir/$name').writeAsBytesSync(png.buffer.asUint8List());
      image.dispose();
    });
  } finally {
    debugDisableShadows = true;
    _repaintAll(boundary);
    await tester.pump();
  }
}

/// Opens [panel] on the app's background with the real fonts, as the
/// floating bar will (a popover). Returns the boundary to shoot.
Future<GlobalKey> _openPanel(
  WidgetTester tester,
  Widget Function(VoidCallback close) panel,
) async {
  await tester.runAsync(loadCaptureFonts);
  tester.view.physicalSize = _screen * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final boundary = GlobalKey();
  final anchor = GlobalKey();
  await tester.pumpWidget(
    RepaintBoundary(
      key: boundary,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          fontFamily: _latin,
          fontFamilyFallback: const [_korean],
        ),
        home: ColoredBox(
          color: KitTokens.settingsBg,
          child: Align(
            alignment: Alignment.topLeft,
            child: Padding(
              padding: const EdgeInsets.only(left: 30, top: 16),
              child: SizedBox(key: anchor, width: 1, height: 1),
            ),
          ),
        ),
      ),
    ),
  );
  unawaited(
    showKitPopover<void>(
      context: anchor.currentContext!,
      anchor: anchor,
      builder: (context) => panel(() => Navigator.of(context).pop()),
    ),
  );
  await tester.pumpAndSettle();
  return boundary;
}

Future<GlobalKey> _openPenPanel(WidgetTester tester, KitPenPanelKind kind) {
  final acts = AppActionRegistry();
  addTearDown(acts.dispose);
  acts.publish(Object(), [
    AppAction(
      id: AppActionIds.eyedropper,
      label: '스포이트',
      icon: KitIconName.eyedrop,
      run: (_) {},
    ),
  ]);
  final collapsed = ValueNotifier(false);
  addTearDown(collapsed.dispose);
  final host = PanelHost(
    kind == KitPenPanelKind.pens
        ? Pen.currentPen
        : Highlighter.currentHighlighter,
  );
  return _openPanel(
    tester,
    (close) => KitPenPanel(
      kind: kind,
      host: host,
      onClose: close,
      collapsed: collapsed,
      actions: acts,
    ),
  );
}

/// How far a height made of the preview's text lines may differ: Chrome lays
/// out in 1/64 px, so its 15.4 line is 15.39 and two make 30.78, not 30.8.
const _chrome = .03;

/// Collects sizes that are off from the expected value by more than
/// [within], and fails once with all of them.
class _Checks {
  final off = <String>[];

  void call(String what, double now, double expected, [double within = .01]) {
    if ((now - expected).abs() > within) off.add('$what: $now, want $expected');
  }

  void done() => expect(off, isEmpty, reason: off.join('\n'));
}

/// The lines of [data] (a [KitLines]).
Finder _lines(String data) =>
    find.byWidgetPredicate((w) => w is KitLines && w.data == data);

/// With the real fonts, [text] (a [KitLines]) is laid out whole, each line
/// inside its box, in [lines] lines on the preview's pitch (font size x line
/// height a line, v8f: 15.4 for the notes).
void _expectLines(WidgetTester tester, _Checks check, Finder text, int lines) {
  expect(tester.takeException(), isNull, reason: 'an overflow was reported');
  final widget = tester.widget<KitLines>(text);
  final paragraphs = tester
      .renderObjectList<RenderParagraph>(
        find.descendant(of: text, matching: find.byType(RichText)),
      )
      .toList();
  check('${widget.data} lines', paragraphs.length.toDouble(), lines.toDouble());
  for (final p in paragraphs) {
    check(
      '${p.text.toPlainText()} fits its box',
      (p.textSize.width - p.size.width).clamp(0, double.infinity).toDouble(),
      0,
    );
  }
  check(
    '${widget.data} height',
    tester.getSize(text).height,
    lines * widget.style.fontSize! * widget.style.height!,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();
  tearDown(resetPenPanelState);

  testWidgets('pen panel stabiliser', (tester) async {
    _previewPens();
    final boundary = await _openPenPanel(tester, KitPenPanelKind.pens);
    await _shoot(tester, boundary, 'app-pen-stab.png');
    final check = _Checks();
    final panel = tester.getRect(find.byKey(const ValueKey('kit-pen-panel')));
    final stab = find.byKey(const ValueKey('tool-panel-stabiliser'));
    // v8f 516.89 less its line-type row (46) the stage hides; the stabiliser
    // 278 x 91.89 from 16 under the page dots: line, 4, title row 6 + 17.5,
    // 2, the note's 15.4 line, the slider row 46. Task 13 adds the pen's
    // 수평/수직 row (56.89, blocked) under the straight line for every ink
    // pen (the controller's ruling), which moves the rest down, as does
    // the fine pen's line-style row (46) stage 2 shows (Task 12).
    const axis = 56.89, lineStyles = 46.0;
    check('panel height', panel.height, 470.89 + axis + lineStyles, _chrome);
    final box = tester.getRect(stab).shift(-panel.topLeft);
    check('stabiliser top', box.top, 349 + axis + lineStyles);
    check('stabiliser height', box.height, 91.89, _chrome);
    _expectLines(
      tester,
      check,
      find.descendant(of: stab, matching: _lines('스트로크 안정화')),
      1,
    );
    _expectLines(
      tester,
      check,
      find.descendant(of: stab, matching: _lines('높을수록 선이 부드럽고 약간 늦게 따라갑니다.')),
      1,
    );
    // the value at the title row's end (x 285), the number alone on the
    // thumb
    final value = find.byKey(const ValueKey('tool-panel-stabiliser-value'));
    expect(tester.widget<KitText>(value).data, '50%');
    check('value right', tester.getRect(value).right - panel.left, 285);
    expect(
      find.descendant(of: stab, matching: find.text('50')),
      findsOneWidget,
    );
    check.done();
  }, skip: !_capture);

  for (final straight in [true, false]) {
    testWidgets('highlighter panel, straight line ${straight ? 'on' : 'off'}', (
      tester,
    ) async {
      _previewPens();
      // the flat highlighter's own straight line (Task 13); the old shared
      // key would turn the round one's ruler on too until either is set
      setStraightLine(KitPenKind.highlighterChisel, straight);
      final boundary = await _openPenPanel(
        tester,
        KitPenPanelKind.highlighters,
      );
      await _shoot(
        tester,
        boundary,
        'app-hl-axis-${straight ? 'on' : 'off'}.png',
      );
      final check = _Checks();
      final panel = tester.getRect(find.byKey(const ValueKey('kit-pen-panel')));
      final axis = find.byKey(const ValueKey('tool-panel-axis-lock'));
      // v8k (user change 1): the row 56.89 on and blocked alike (11 + 17.5 +
      // 2 + one 15.4 line + 11); the panel 557.89 in both less the opacity,
      // text-fit and T rows (138) the stage hides; stage 2 shows the opacity
      // row (46, Task 12)
      check('panel height', panel.height, 419.89 + 46, _chrome);
      check('axis row', tester.getSize(axis).height, 56.89, _chrome);
      _expectLines(
        tester,
        check,
        find.descendant(
          of: axis,
          matching: _lines(
            straight ? '선을 수평·수직 중 가까운 쪽으로 맞춥니다.' : '먼저 위의 ‘직선 자동 보정’을 켜세요.',
          ),
        ),
        1,
      );
      check.done();
    }, skip: !_capture);
  }
}
