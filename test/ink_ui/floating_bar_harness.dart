import 'package:flutter/gestures.dart' show kLongPressTimeout;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/ink_ui/floating_bar/kit_floating_bar.dart';
import 'package:saber/components/kit/kit_icon.dart';
import 'package:saber/components/kit/kit_pill.dart';
import 'package:saber/components/kit/kit_tokens.dart';
import 'package:saber/data/actions/app_action.dart';
import 'package:saber/data/actions/app_action_ids.dart';
import 'package:saber/data/actions/app_action_registry.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/tools/_tool.dart';

import 'pen_panel_harness.dart'
    show TestToolHost, colourString, resetPenPanelState;

/// Tall enough for the pen panels opened from the upright bar's buttons.
const barScreen = Size(800, 900);

/// A spot away from the bar and every window it opens.
const outside = Offset(790, 890);

final floatingBar = find.byKey(const ValueKey('kit-floating-bar'));
final undoPill = find.byKey(const ValueKey('floating-bar-undo-pill'));
final toolPill = find.byKey(const ValueKey('floating-bar-tool-pill'));
final widthsPopover = find.byKey(const ValueKey('floating-bar-widths'));

Finder barKey(String k) => find.byKey(ValueKey(k));

Finder inside(Finder of, Finder f) => find.descendant(of: of, matching: f);

/// The editor's part in the floating bar tests: it holds the tool and builds
/// again when the tool changes (as the editor does; a colour or a width only
/// reaches [toolState]), records what the bar asks of it, counts its own
/// builds, and draws a canvas under the bar that counts its paintings and
/// taps.
class BarHost extends TestToolHost {
  new(super.tool);

  final tools = <Tool>[];
  final colors = <Color>[];
  var builds = 0;
  var paints = 0;
  var canvasTaps = 0;
  var undoRuns = 0;
  var redoRuns = 0;
  final actions = AppActionRegistry();
  final collapsed = ValueNotifier(false);

  /// Where the toolbar button that shows the bar is across (the editor's).
  final growFrom = ValueNotifier<double?>(null);

  /// The tip of a stroke on the page now (the editor's).
  final strokeAt = ValueNotifier<Offset?>(null);

  /// Builds the host again with [next] in hand (the toolbar picking a tool).
  late void Function(Tool next) pick;

  @override
  void selectTool(Tool t) {
    tools.add(t);
    pick(t);
  }

  @override
  void setColor(Color c) {
    colors.add(c);
    _keepRecent(c);
    colourPen(c);
  }

  AppAction undo({bool enabled = true}) => AppAction(
    id: AppActionIds.undo,
    label: '실행 취소',
    icon: KitIconName.undo,
    enabled: enabled,
    run: (_) => undoRuns++,
  );

  AppAction redo({bool enabled = true}) => AppAction(
    id: AppActionIds.redo,
    label: '다시 실행',
    icon: KitIconName.redo,
    enabled: enabled,
    run: (_) => redoRuns++,
  );
}

class _HostPage extends StatefulWidget {
  const new({super.key, required this.host});

  final BarHost host;

  @override
  State<_HostPage> createState() => _HostPageState();
}

class _HostPageState extends State<_HostPage> {
  BarHost get host => widget.host;

  @override
  void initState() {
    super.initState();
    host.pick = (next) => setState(() => host.tool = next);
  }

  @override
  Widget build(BuildContext context) {
    host.builds++;
    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => host.canvasTaps++,
              child: RepaintBoundary(
                child: CustomPaint(painter: _Canvas(host)),
              ),
            ),
          ),
          Positioned.fill(
            child: KitFloatingBar(
              host: host,
              actions: host.actions,
              penPanelCollapsed: host.collapsed,
              growFrom: host.growFrom,
              strokeAt: host.strokeAt,
            ),
          ),
        ],
      ),
    );
  }
}

class _Canvas extends CustomPainter {
  new(this.host);

  final BarHost host;

  @override
  void paint(Canvas canvas, Size size) {
    host.paints++;
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(_Canvas old) => false;
}

/// What the editor does with a colour it is given (`updateColorBar`): one
/// already among the recent colours only moves up in the time order, so the
/// colours keep their places; a new one goes in front.
void _keepRecent(Color c) {
  final s = colourString(c);
  stows.recentColorsChronological.value = [
    ...stows.recentColorsChronological.value.where((x) => x != s),
    s,
  ];
  final placed = stows.recentColorsPositioned.value;
  if (!placed.contains(s)) stows.recentColorsPositioned.value = [s, ...placed];
}

/// Puts back what the floating bar tests change.
void resetBarState() {
  resetPenPanelState();
  stows.floatingBarPosition.value = stows.floatingBarPosition.defaultValue;
}

/// The bar over a canvas filling an 800 x 900 screen (or [screen]), the
/// undo action on and the redo action off. Without [settle] only the first
/// frame is drawn; [reduceMotion] is the system's 「움직임 줄이기」.
Future<BarHost> pumpBar(
  WidgetTester tester,
  Tool tool, {
  Brightness brightness = Brightness.light,
  bool settle = true,
  bool reduceMotion = false,
  Size screen = barScreen,
}) async {
  tester.view.physicalSize = screen;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final host = BarHost(tool);
  addTearDown(host.actions.dispose);
  addTearDown(host.collapsed.dispose);
  addTearDown(host.growFrom.dispose);
  addTearDown(host.strokeAt.dispose);
  host.actions.publish(host, [host.undo(), host.redo(enabled: false)]);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: brightness),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(size: screen, disableAnimations: reduceMotion),
        child: child!,
      ),
      home: _HostPage(key: ObjectKey(host), host: host),
    ),
  );
  if (settle) await tester.pumpAndSettle();
  return host;
}

/// How far the bar has grown in (1 when it is all there).
double barScale(WidgetTester tester) => tester
    .widget<ScaleTransition>(
      find.ancestor(of: floatingBar, matching: find.byType(ScaleTransition)),
    )
    .scale
    .value;

/// The colour of the first icon inside [key].
Color? iconInk(WidgetTester tester, String key) => tester
    .widget<KitIcon>(inside(barKey(key), find.byType(KitIcon)).first)
    .color;

/// Holds the bar on [from] (its undo button unless given) until it is picked
/// up, moves it [by] and lets it go.
Future<void> dragBar(WidgetTester tester, Offset by, {Finder? from}) async {
  final g = await tester.startGesture(
    tester.getCenter(from ?? barKey('floating-bar-undo')),
  );
  await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
  await g.moveBy(by);
  await tester.pump();
  await g.up();
  await tester.pumpAndSettle();
}

bool isOn(WidgetTester tester, String key) =>
    tester.widget<KitPillButton>(barKey(key)).selected;

/// The first [Opacity] inside the button [key].
double opacityOf(WidgetTester tester, String key) => tester
    .widget<Opacity>(inside(barKey(key), find.byType(Opacity)).first)
    .opacity;

String tooltipOf(WidgetTester tester, String key) => tester
    .widget<Tooltip>(inside(barKey(key), find.byType(Tooltip)).first)
    .message!;

/// The painted circle of colour dot [i].
Finder dotCircle(int i) =>
    inside(barKey('floating-bar-colour-$i'), find.byType(Container));

/// The colours the four dots are painted in.
List<Color?> dotColours(WidgetTester tester) => [
  for (var i = 0; i < 4; i++)
    (tester.widget<Container>(dotCircle(i)).decoration! as BoxDecoration).color,
];

List<bool> chosenDots(WidgetTester tester) => [
  for (var i = 0; i < 4; i++)
    tester.widget<KitColorDot>(barKey('floating-bar-colour-$i')).selected,
];

/// Where a window opened from [button] starts: at the button's start, 8
/// under the bar, or 20 beside it when the bar is upright.
Offset windowAt(WidgetTester tester, String button, {bool upright = false}) {
  final b = tester.getRect(barKey(button));
  final bar = tester.getRect(floatingBar);
  return upright
      ? Offset(bar.right + KitTokens.floatingBarPanelGapUpright, b.top)
      : Offset(b.left, bar.bottom + KitTokens.floatingBarPanelGap);
}

Rect _b(double x, double y, [double w = 32, double h = 32]) =>
    Rect.fromLTWH(x, y, w, h);

typedef BarSheet = ({
  Size size,
  Map<String, Rect> boxes,
  List<Rect> lines,
  List<Rect> dots,
});

const _undoAcross = {'floating-bar-undo-pill': Rect.fromLTWH(0, 0, 80, 40)};
const _undoUpright = {'floating-bar-undo-pill': Rect.fromLTWH(0, 0, 40, 80)};

/// The value sheet's boxes (task-12-values.md §7), from the bar's top left:
/// the bar, its pills and buttons, the lines between groups, the dots. Stage
/// 2 puts the brush after the fine pen (the preview's `#toolPill`), so every
/// box from there on is one pen button (34) further along.
final barSheets = <String, BarSheet>{
  'pen-h': (
    size: const Size(barAcross, 40),
    boxes: {
      ..._undoAcross,
      'floating-bar-tool-pill': _b(86, 0, 388, 40),
      'floating-bar-undo': _b(7, 4),
      'floating-bar-redo': _b(41, 4),
      'floating-bar-pen-fountain': _b(93, 4),
      'floating-bar-pen-pen': _b(127, 4),
      'floating-bar-pen-brush': _b(161, 4),
      'floating-bar-pen-pencil': _b(195, 4),
      'floating-bar-pen-hlchisel': _b(229, 4),
      'toolbar-quick-ink-widths': _b(272, 4),
      'floating-bar-custom-colour': _b(435, 4),
    },
    lines: [_b(266, 9, 1, 22), _b(309, 9, 1, 22)],
    dots: [
      for (final x in const <double>[318, 348, 378, 408]) _b(x, 9, 22, 22),
    ],
  ),
  'pen-v': (
    size: const Size(40, barUpright),
    boxes: {
      ..._undoUpright,
      'floating-bar-tool-pill': _b(0, 86, 40, 364),
      'floating-bar-undo': _b(4, 7),
      'floating-bar-redo': _b(4, 41),
      'floating-bar-pen-fountain': _b(4, 93),
      'floating-bar-pen-pen': _b(4, 127),
      'floating-bar-pen-brush': _b(4, 161),
      'floating-bar-pen-pencil': _b(4, 195),
      'floating-bar-pen-hlchisel': _b(4, 229),
      'toolbar-quick-ink-widths': _b(4, 272),
      'floating-bar-custom-colour': _b(4, 411),
    },
    lines: [_b(9, 266, 22, 1), _b(9, 309, 22, 1)],
    dots: [
      for (final y in const <double>[315, 339, 363, 387]) _b(9, y, 22, 22),
    ],
  ),
};

/// The pen bar's length across the top and standing at the side.
const barAcross = 474.0;
const barUpright = 450.0;

/// The bar sits 10 in from the canvas area's top left, with the sizes and
/// places of the value sheet's state [name].
void expectSheet(WidgetTester tester, String name) {
  final sheet = barSheets[name]!;
  final origin = tester.getTopLeft(floatingBar);
  const inset = KitTokens.floatingBarInset;
  expect(origin, const Offset(inset, inset), reason: name);
  expect(tester.getSize(floatingBar), sheet.size, reason: name);
  Rect at(Finder f) => tester.getRect(f).shift(-origin);
  for (final MapEntry(key: k, value: box) in sheet.boxes.entries) {
    expect(at(barKey(k)), rectMoreOrLessEquals(box), reason: '$name $k');
  }
  final lines = find.byType(KitPillDivider);
  expect(lines, findsNWidgets(sheet.lines.length), reason: name);
  for (final (i, line) in sheet.lines.indexed) {
    expect(at(lines.at(i)), rectMoreOrLessEquals(line), reason: '$name $i');
  }
  expect(find.byType(KitColorDot), findsNWidgets(sheet.dots.length));
  for (final (i, dot) in sheet.dots.indexed) {
    expect(at(dotCircle(i)), rectMoreOrLessEquals(dot), reason: '$name $i');
  }
}
