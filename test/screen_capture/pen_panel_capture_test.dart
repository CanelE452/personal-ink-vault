import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/ink_ui/pen_panel/kit_pen_panel.dart';
import 'package:saber/components/ink_ui/pen_panel/size_level.dart';
import 'package:saber/components/kit/kit_icon.dart';
import 'package:saber/components/kit/kit_popover.dart';
import 'package:saber/components/kit/kit_tokens.dart';
import 'package:saber/data/actions/app_action.dart';
import 'package:saber/data/actions/app_action_ids.dart';
import 'package:saber/data/actions/app_action_registry.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/tools/_tool.dart';
import 'package:saber/data/tools/highlighter.dart';
import 'package:saber/data/tools/pen.dart';
import 'package:saber/data/tools/pen_box.dart';
import 'package:saber/data/tools/pencil.dart';
import 'package:sbn/tool_id.dart';

import '../ink_ui/pen_panel_harness.dart' show resetPenPanelState;
import '../utils/screen_capture.dart';

/// Writes screenshots of the pen panel to build/screen-review/t10/ with the
/// app's fonts (Atkinson with the Korean fallback), at device pixel ratio 2.
/// Runs only with PIV_CAPTURE=1 so the normal suite writes no files.
final _capture = Platform.environment['PIV_CAPTURE'] == '1';
final _outDir = captureDir('build/screen-review/t10');
const _latin = captureLatin;
const _korean = captureKorean;
const _screen = Size(360, 640);

/// The preview's own example state (`SP`, `CPAGES`, lines 2104-2121): the fine
/// pen in red at 37, the fine-nib pen blue, the pencil grey, the chisel
/// highlighter red at 51, and the example recent and pinned colours.
void _previewState() {
  const red = 0xffe5323e;
  stows.lastFountainPenColor.value = 0xff2f55d4;
  stows.lastBallpointPenColor.value = red;
  stows.lastPencilColor.value = 0xff6f7278;
  stows.lastHighlighterColor.value = red;
  stows.autoStraightenLines.value = false;
  stows.highlighterStraightLine.value = false;
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

/// The captured screen at device pixel ratio 2, as RGBA bytes.
class _Shot {
  new(this.width, this.rgba);

  final int width;
  final Uint8List rgba;

  /// The first and last rows (device px) inside [box] (logical) that hold a
  /// pixel darker than [sum] (r + g + b), like the screen review measured.
  (int, int)? inkRows(Rect box, int sum) {
    int? first;
    int? last;
    for (var y = (box.top * 2).round(); y < (box.bottom * 2).round(); y++) {
      for (var x = (box.left * 2).round(); x < (box.right * 2).round(); x++) {
        final i = (y * width + x) * 4;
        if (rgba[i] + rgba[i + 1] + rgba[i + 2] < sum) {
          first ??= y;
          last = y;
          break;
        }
      }
    }
    return first == null ? null : (first, last!);
  }
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

Future<_Shot> _shoot(
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
    late _Shot shot;
    await tester.runAsync(() async {
      final object =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await object.toImage(pixelRatio: 2);
      final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      Directory(_outDir).createSync(recursive: true);
      File('$_outDir/$name').writeAsBytesSync(png.buffer.asUint8List());
      final raw = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      shot = _Shot(image.width, raw.buffer.asUint8List());
      image.dispose();
    });
    return shot;
  } finally {
    debugDisableShadows = true;
    _repaintAll(boundary);
    await tester.pump();
  }
}

/// Opens [kind]'s panel on the app's background with the real fonts. Returns
/// the boundary to shoot.
Future<GlobalKey> _openPanel(
  WidgetTester tester, {
  required KitPenPanelKind kind,
  required Tool tool,
  bool collapsed = false,
}) async {
  await tester.runAsync(loadCaptureFonts);
  tester.view.physicalSize = _screen * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
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
  final notifier = ValueNotifier(collapsed);
  addTearDown(notifier.dispose);
  final boundary = GlobalKey();
  final anchor = GlobalKey();
  var current = tool;
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
      builder: (context) => KitPenPanel(
        kind: kind,
        currentTool: () => current,
        setTool: (t) => current = t,
        setColor: (c) {
          final t = current;
          if (t is Pen) t.color = c;
        },
        onClose: () => Navigator.of(context).pop(),
        collapsed: notifier,
        actions: acts,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return boundary;
}

/// The preview's heights with the real fonts: the stage 1 panel is 363 high
/// (head 22, pens 112, rows 46 + 46 + 4 + 46, dots, padding 20 / 29) before
/// the rows Task 11 adds (build/screen-review/t11, preview v8f): the pens'
/// stabiliser (16 + 91.89, so 470.89) and the highlighter's
/// horizontal/vertical row (blocked here, its note one line: 56.89). The
/// collapsed one ends under the pen row (158). The page name's line is 11.
void _expectPanel(
  WidgetTester tester,
  _Shot shot, {
  required bool collapsed,
  bool highlighter = false,
}) {
  final off = <String>[];
  void check(String what, double now, double preview, [double within = 0.01]) {
    if ((now - preview).abs() > within) {
      off.add('$what: $now, preview $preview');
    }
  }

  final panel = tester.getRect(find.byKey(const ValueKey('kit-pen-panel')));
  // the horizontal/vertical row pushes the colours down on the highlighter
  final axis = highlighter ? 56.89 : 0.0;
  check('panel width', panel.width, 300);
  check(
    'panel height',
    panel.height,
    collapsed ? 158 : (highlighter ? 363 + axis : 470.89),
    .02,
  );
  if (!collapsed) {
    check(
      'straight-line row',
      tester
          .getSize(find.byKey(const ValueKey('toolbar-auto-straighten')))
          .height,
      46,
    );
    final name = find.descendant(
      of: find.byKey(const ValueKey('pen-panel-colors')),
      matching: find.text('기본 색'),
    );
    check('page name line', tester.getSize(name).height, 11);
    check(
      'page name left',
      tester.getTopLeft(name).dx - panel.left,
      15 + KitTokens.pageNameInset,
    );
    // Where the glyphs land (device px from the panel's top at ratio 2). The
    // preview (Edge, scale 2, screen review t10) puts the page name's ink at
    // 653 and the switch label's at 473; within one device pixel.
    final top = panel.top * 2;
    final nameInk = shot.inkRows(
      Rect.fromLTWH(panel.left + 10, panel.top + 320 + axis, 65, 20),
      600,
    );
    final labelInk = shot.inkRows(
      Rect.fromLTWH(panel.left + 10, panel.top + 235, 140, 35),
      400,
    );
    check('page name ink top', nameInk!.$1 - top, 653 + 2 * axis, 1);
    check('switch label ink top', labelInk!.$1 - top, 473, 1);
  }
  expect(off, isEmpty, reason: off.join('\n'));
}

/// With the real fonts, [text] is laid out whole and every glyph box of it
/// lies in [cell] (logical px): no overflow was reported, no line was cut.
void _expectFits(WidgetTester tester, Finder text, Rect cell) {
  expect(tester.takeException(), isNull, reason: 'an overflow was reported');
  final paragraph = tester.renderObject<RenderParagraph>(
    find.descendant(of: text, matching: find.byType(RichText)),
  );
  expect(paragraph.didExceedMaxLines, isFalse, reason: 'a line was cut');
  final boxes = [
    for (final b in paragraph.getBoxesForSelection(
      TextSelection(
        baseOffset: 0,
        extentOffset: paragraph.text.toPlainText().length,
      ),
    ))
      Rect.fromPoints(
        paragraph.localToGlobal(Offset(b.left, b.top)),
        paragraph.localToGlobal(Offset(b.right, b.bottom)),
      ),
  ];
  const e = 0.01;
  final out = [
    for (final r in boxes)
      if (r.left < cell.left - e ||
          r.top < cell.top - e ||
          r.right > cell.right + e ||
          r.bottom > cell.bottom + e)
        r,
  ];
  expect(out, isEmpty, reason: 'cell $cell, glyph boxes outside it: $out');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();
  tearDown(resetPenPanelState);

  testWidgets('pen panel', (tester) async {
    _previewState();
    final boundary = await _openPanel(
      tester,
      kind: KitPenPanelKind.pens,
      tool: Pen.currentPen,
    );
    final shot = await _shoot(tester, boundary, 'pen-panel.png');
    _expectPanel(tester, shot, collapsed: false);
  }, skip: !_capture);

  testWidgets('highlighter panel', (tester) async {
    _previewState();
    final boundary = await _openPanel(
      tester,
      kind: KitPenPanelKind.highlighters,
      tool: Highlighter.currentHighlighter,
    );
    final shot = await _shoot(tester, boundary, 'highlighter-panel.png');
    _expectPanel(tester, shot, collapsed: false, highlighter: true);
  }, skip: !_capture);

  testWidgets('collapsed pen panel', (tester) async {
    _previewState();
    final boundary = await _openPanel(
      tester,
      kind: KitPenPanelKind.pens,
      tool: Pen.currentPen,
      collapsed: true,
    );
    final shot = await _shoot(tester, boundary, 'pen-panel-collapsed.png');
    _expectPanel(tester, shot, collapsed: true);
  }, skip: !_capture);

  testWidgets('pen box with two pens', (tester) async {
    _previewState();
    stows.penBox.value = [
      const PenBoxEntry(
        toolId: ToolId.fountainPen,
        color: 0xff2f55d4,
        size: 6,
        streamline: .5,
      ).toJson(),
      const PenBoxEntry(
        toolId: ToolId.shapePen,
        color: 0xff1f2023,
        size: 3,
        streamline: 0,
      ).toJson(),
    ];
    final boundary = await _openPanel(
      tester,
      kind: KitPenPanelKind.pens,
      tool: Pen.currentPen,
    );
    await tester.tap(find.byKey(const ValueKey('pen-panel-pen-box-open')));
    await tester.pumpAndSettle();
    await _shoot(tester, boundary, 'pen-box.png');
    // one row of cards: the line, padding 20 + title 22 + gap 14 + card +
    // padding 29, the line; it lies on the pen row, edge to edge
    final box = tester.getSize(find.byKey(const ValueKey('kit-pen-box')));
    expect(box.width, KitTokens.penPanelWidth);
    expect(
      box.height,
      2 * KitTokens.penPanelBorderWidth +
          KitTokens.penPanelPadTop +
          KitTokens.penPanelHeadHeight +
          KitTokens.penPanelHeadGap +
          KitTokens.penBoxCardHeight +
          KitTokens.penPanelPadBottom,
    );
    final card = find.byKey(const ValueKey('pen-box-entry-0'));
    expect(tester.getSize(card).height, KitTokens.penBoxCardHeight);
    final panel = tester.getRect(find.byKey(const ValueKey('kit-pen-panel')));
    expect(tester.getTopLeft(find.byKey(const ValueKey('kit-pen-box'))), panel.topLeft + const Offset(0, 45));
  }, skip: !_capture);

  testWidgets('recent colours with nothing pinned', (tester) async {
    _previewState();
    stows.pinnedColors.value = [];
    final boundary = await _openPanel(
      tester,
      kind: KitPenPanelKind.pens,
      tool: Pen.currentPen,
    );
    // nothing pinned, so no pinned page: the recent colours are the fourth
    // and last page, after the basic, pastel and grey ones
    expect(find.byKey(const Key('kit-swatch-page-dot-4')), findsNothing);
    final lastDot = find.byKey(const Key('kit-swatch-page-dot-3'));
    await tester.tap(lastDot);
    await tester.pumpAndSettle();
    await _shoot(tester, boundary, 'pen-panel-recent-empty.png');
    final colours = find.byKey(const ValueKey('pen-panel-colors'));
    expect(
      find.descendant(of: colours, matching: find.text('최근 색')),
      findsOneWidget,
    );
    // the hint's cell: the dots' band right of the dots, to the band's end
    // where it clips. The hint keeps pageNameInset from that end as margin;
    // its glyphs reach 0.125 into it with the real fonts.
    final row = tester.getRect(colours);
    final dot = tester.getRect(lastDot);
    _expectFits(
      tester,
      find.descendant(of: colours, matching: find.text('길게 눌러 고정')),
      Rect.fromLTRB(
        dot.right,
        dot.center.dy - KitTokens.pageDotHitZone / 2,
        row.right,
        dot.center.dy + KitTokens.pageDotHitZone / 2,
      ),
    );
  }, skip: !_capture);

  testWidgets('empty pen box', (tester) async {
    _previewState();
    stows.penBox.value = [];
    final boundary = await _openPanel(
      tester,
      kind: KitPenPanelKind.pens,
      tool: Pen.currentPen,
    );
    await tester.tap(find.byKey(const ValueKey('pen-panel-pen-box-open')));
    await tester.pumpAndSettle();
    await _shoot(tester, boundary, 'pen-box-empty.png');
    final box = find.byKey(const ValueKey('kit-pen-box'));
    // the take-out hint shows only with pens in the box (design review I-2)
    expect(find.text('길게 눌러 빼기'), findsNothing);
    // the note's cell: the box inside its line and padding, under the title
    // row and its gap
    final r = tester.getRect(box);
    const edge = KitTokens.penPanelBorderWidth;
    _expectFits(
      tester,
      find.descendant(of: box, matching: find.textContaining('☆')),
      Rect.fromLTRB(
        r.left + edge + KitTokens.penPanelPadH,
        r.top +
            edge +
            KitTokens.penPanelPadTop +
            KitTokens.penPanelHeadHeight +
            KitTokens.penPanelHeadGap,
        r.right - edge - KitTokens.penPanelPadH,
        r.bottom - edge - KitTokens.penPanelPadBottom,
      ),
    );
  }, skip: !_capture);
}
