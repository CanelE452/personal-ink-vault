import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart' show kLongPressTimeout;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/ink_ui/floating_bar/kit_floating_bar.dart';
import 'package:saber/components/ink_ui/pen_panel/size_level.dart';
import 'package:saber/components/kit/kit_icon.dart';
import 'package:saber/data/actions/app_action.dart';
import 'package:saber/data/actions/app_action_ids.dart';
import 'package:saber/data/actions/app_action_registry.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/tools/_tool.dart';
import 'package:saber/data/tools/pen.dart';

import '../ink_ui/pen_panel_harness.dart' show resetPenPanelState;
import '../utils/screen_capture.dart';

/// Writes screenshots of the floating bar to build/screen-review/t12/ with
/// the app's fonts, at device pixel ratio 2, beside the preview's renders
/// there (ref-*.png, task-12-values.md): the page's top left to 10 past the
/// bar's bottom right, on the preview's paper. Runs only with PIV_CAPTURE=1
/// so the normal suite writes no files.
final _capture = Platform.environment['PIV_CAPTURE'] == '1';
final _outDir = captureDir('build/screen-review/t12');
const _latin = captureLatin;
const _korean = captureKorean;
const _screen = Size(600, 600);
const _margin = 10.0;

/// The preview's page (`.page`, preview-v8f line 123): `--paper` with a 1px
/// `--paper-grid` line every 22 from the top left.
class _Paper extends CustomPainter {
  const new();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xfffbf8ef),
    );
    final grid = Paint()..color = const Color(0xffece4cd);
    for (var x = 0.0; x < size.width; x += 22) {
      canvas.drawRect(Rect.fromLTWH(x, 0, 1, size.height), grid);
    }
    for (var y = 0.0; y < size.height; y += 22) {
      canvas.drawRect(Rect.fromLTWH(0, y, size.width, 1), grid);
    }
  }

  @override
  bool shouldRepaint(_Paper old) => false;
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

/// Writes [boundary]'s picture as [name]; with [crop] only that part of it
/// (in logical pixels).
Future<void> _shoot(
  WidgetTester tester,
  GlobalKey boundary,
  String name, {
  Rect? crop,
}) async {
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
      var image = await object.toImage(pixelRatio: 2);
      if (crop != null) {
        final part = Rect.fromLTWH(
          crop.left * 2,
          crop.top * 2,
          crop.width * 2,
          crop.height * 2,
        );
        final recorder = ui.PictureRecorder();
        Canvas(recorder)
            .drawImageRect(image, part, Offset.zero & part.size, Paint());
        final picture = recorder.endRecording();
        final cut = await picture.toImage(
          part.width.round(),
          part.height.round(),
        );
        picture.dispose();
        image.dispose();
        image = cut;
      }
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

/// The bar with [tool] in hand on the preview's paper, the canvas area as
/// big as the bar and 10 around it ([bar] is the value sheet's size) unless
/// [page] is given, the undo action on and the redo action off as in the
/// preview.
Future<GlobalKey> _pumpBar(
  WidgetTester tester,
  Tool tool,
  Size bar, {
  Size? page,
}) async {
  await tester.runAsync(loadCaptureFonts);
  tester.view.physicalSize = _screen * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final acts = AppActionRegistry();
  addTearDown(acts.dispose);
  acts.publish(Object(), [
    for (final (id, icon, label, enabled) in const [
      (AppActionIds.undo, KitIconName.undo, '실행 취소', true),
      (AppActionIds.redo, KitIconName.redo, '다시 실행', false),
    ])
      AppAction(
        id: id,
        label: label,
        icon: icon,
        enabled: enabled,
        run: (_) {},
      ),
  ]);
  final collapsed = ValueNotifier(false);
  addTearDown(collapsed.dispose);
  final boundary = GlobalKey();
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(fontFamily: _latin, fontFamilyFallback: const [_korean]),
      home: Align(
        alignment: Alignment.topLeft,
        child: RepaintBoundary(
          key: boundary,
          child: SizedBox(
            width: page?.width ?? bar.width + 2 * _margin,
            height: page?.height ?? bar.height + 2 * _margin,
            child: Stack(
              children: [
                const Positioned.fill(child: CustomPaint(painter: _Paper())),
                Positioned.fill(
                  child: KitFloatingBar(
                    currentTool: tool,
                    setTool: (_) {},
                    setColor: (_) {},
                    actions: acts,
                    penPanelCollapsed: collapsed,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return boundary;
}

/// Collects sizes that are off from the expected value by more than
/// [within], and fails once with all of them.
class _Checks {
  final off = <String>[];

  void call(String what, double now, double expected, [double within = .03]) {
    if ((now - expected).abs() > within) off.add('$what: $now, want $expected');
  }

  void done() => expect(off, isEmpty, reason: off.join('\n'));
}

/// One state of the value sheet (§7, §12): the reference picture's name, the
/// bar across the top or upright, the tool in hand and how the preview set
/// it, the colour dot with the keyboard focus (§12), the bar's size and the
/// tool pill's length.
typedef _State = ({
  String name,
  bool upright,
  Tool Function() tool,
  void Function() set,
  int? focus,
  Size bar,
  double pill,
});

/// The fine pen in the first dot's colour (`#1f2329`).
Pen _finePen() => Pen.ballpointPen()..color = const Color(0xff1f2329);

/// The fine pen at the size number [level].
Pen _finePenAt(int level) {
  final pen = _finePen();
  return pen
    ..options = pen.options.copyWith(
      size: levelToSize(level, min: pen.sizeMin, max: pen.sizeMax),
    );
}

final _states = <_State>[
  for (final upright in [false, true])
    (
      name: upright ? 'pen-v' : 'pen-h',
      upright: upright,
      tool: _finePen,
      set: () {},
      focus: null,
      bar: upright ? const Size(40, 416) : const Size(440, 40),
      pill: upright ? 330 : 354,
    ),
  // the focus on the second dot, then on the chosen first one (v8h line 111)
  // the width icon at the size numbers 7, 52 and 97 (v8k, §13), put
  // together as the preview's picture by the comparison
  for (final level in const [7, 52, 97])
    (
      name: 'v8k-pen-h-$level',
      upright: false,
      tool: () => _finePenAt(level),
      set: () {},
      focus: null,
      bar: const Size(440, 40),
      pill: 354,
    ),
  for (final (name, dot) in const [
    ('v8h-dot-focus-a', 1),
    ('v8h-dot-focus-b', 0),
  ])
    (
      name: name,
      upright: false,
      tool: _finePen,
      set: () {},
      focus: dot,
      bar: const Size(440, 40),
      pill: 354,
    ),
  // the eraser's 10th draft bar: eraser_lasso_capture_test.dart; the lasso
  // has no bar any more
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();
  tearDown(() {
    resetPenPanelState();
    stows.floatingBarPosition.value = stows.floatingBarPosition.defaultValue;
  });

  for (final state in _states) {
    testWidgets('floating bar ${state.name}', (tester) async {
      stows.floatingBarPosition.value = state.upright ? 'left' : 'top';
      state.set();
      final boundary = await _pumpBar(tester, state.tool(), state.bar);
      if (state.focus case final dot?) {
        // the keyboard's focus, as Tab gives it (`:focus-visible`)
        FocusManager.instance.highlightStrategy =
            FocusHighlightStrategy.alwaysTraditional;
        addTearDown(
          () => FocusManager.instance.highlightStrategy =
              FocusHighlightStrategy.automatic,
        );
        Focus.of(
          tester.element(
            find.descendant(
              of: find.byKey(ValueKey('floating-bar-colour-$dot')),
              matching: find.byType(GestureDetector),
            ),
          ),
        ).requestFocus();
        await tester.pumpAndSettle();
      }
      await _shoot(tester, boundary, 'app-${state.name}.png');
      final check = _Checks();
      final bar = tester.getRect(
        find.byKey(const ValueKey('kit-floating-bar')),
      );
      check('bar left', bar.left, _margin);
      check('bar top', bar.top, _margin);
      check('bar width', bar.width, state.bar.width);
      check('bar height', bar.height, state.bar.height);
      final undo = tester.getSize(
        find.byKey(const ValueKey('floating-bar-undo-pill')),
      );
      final pill = tester.getSize(
        find.byKey(const ValueKey('floating-bar-tool-pill')),
      );
      // the undo pill 80 long, the tool pill 6 after it, both 40 across
      check('undo pill along', state.upright ? undo.height : undo.width, 80);
      check('undo pill across', state.upright ? undo.width : undo.height, 40);
      check(
        'tool pill along',
        state.upright ? pill.height : pill.width,
        state.pill,
      );
      check('tool pill across', state.upright ? pill.width : pill.height, 40);
      check.done();
    }, skip: !_capture);
  }

  // held and moved to (70, 50) on a larger page, shot while held: the bar
  // and 24 around it, as the preview's picture (v8k, §13), with the
  // preview's own width, 37
  testWidgets('floating bar v8k-grabbed', (tester) async {
    stows.floatingBarPosition.value = 'top';
    final boundary = await _pumpBar(
      tester,
      _finePenAt(37),
      const Size(440, 40),
      page: const Size(560, 140),
    );
    // on the redo button, which is off, so no button shows the press
    final hold = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('floating-bar-redo'))),
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 20));
    await hold.moveBy(const Offset(60, 40));
    await tester.pumpAndSettle();
    await _shoot(
      tester,
      boundary,
      'app-v8k-grabbed.png',
      crop: const Rect.fromLTWH(46, 26, 488, 88),
    );
    final check = _Checks();
    final bar = tester.getRect(find.byKey(const ValueKey('kit-floating-bar')));
    check('bar left', bar.left, 70);
    check('bar top', bar.top, 50);
    check('bar width', bar.width, 440);
    check('bar height', bar.height, 40);
    check.done();
    // let go further right: it stays across the top, which this page fits
    // (at 70 it would stand upright at the left)
    await hold.moveBy(const Offset(200, 0));
    await hold.up();
    await tester.pumpAndSettle();
  }, skip: !_capture);
}
