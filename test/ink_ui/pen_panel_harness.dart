import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:saber/components/ink_ui/pen_panel/kit_pen_panel.dart';
import 'package:saber/components/ink_ui/pen_panel/size_level.dart';
import 'package:saber/components/kit/kit_icon.dart';
import 'package:saber/components/kit/kit_pen_art.dart';
import 'package:saber/components/kit/kit_popover.dart';
import 'package:saber/data/actions/app_action_registry.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/tools/_tool.dart';
import 'package:saber/data/tools/highlighter.dart';
import 'package:saber/data/tools/pen.dart';
import 'package:saber/data/tools/pencil.dart';

const harnessScreen = Size(800, 900);

/// The editor's part in the pen panel tests: it holds the tool, records what
/// the panel asks of it and counts its own builds. It never rebuilds the panel.
class PanelHost {
  new(this.tool);

  Tool tool;
  final tools = <Tool>[];
  final colors = <Color>[];

  /// 'tool' and 'color' in the order the panel called them.
  final calls = <String>[];
  var builds = 0;
  final anchor = GlobalKey();
}

class _HostPage extends StatelessWidget {
  const new({required this.host});

  final PanelHost host;

  @override
  Widget build(BuildContext context) {
    host.builds++;
    return Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: SizedBox(key: host.anchor, width: 40, height: 40),
        ),
      ),
    );
  }
}

/// A pen that records the sizes and stabilisations it was given.
class CountingPen extends Pen {
  new(Pen from)
    : super(
        name: from.name,
        sizeMin: from.sizeMin,
        sizeMax: from.sizeMax,
        sizeStep: from.sizeStep,
        icon: from.icon,
        options: from.options,
        pressureEnabled: from.pressureEnabled,
        color: from.color,
        toolId: from.toolId,
      );

  final sizes = <double>[];
  final streamlines = <double>[];

  @override
  void setSize(double size) {
    sizes.add(size);
    super.setSize(size);
  }

  @override
  void setStreamline(double streamline) {
    streamlines.add(streamline);
    super.setStreamline(streamline);
  }
}

/// [pen] with its size at slider [level], without touching the settings.
T levelled<T extends Pen>(T pen, int level) {
  pen.options = pen.options.copyWith(
    size: levelToSize(level, min: pen.sizeMin, max: pen.sizeMax),
  );
  return pen;
}

Future<PanelHost> pumpHost(
  WidgetTester tester,
  Tool tool, {
  Brightness brightness = Brightness.light,
}) async {
  tester.view.physicalSize = harnessScreen;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final host = PanelHost(tool);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: brightness),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(size: harnessScreen),
        child: child!,
      ),
      home: _HostPage(host: host),
    ),
  );
  return host;
}

/// Opens the panel the way the editor will: a popover at the host's anchor.
Future<void> openPanel(
  WidgetTester tester,
  PanelHost host, {
  KitPenPanelKind kind = KitPenPanelKind.pens,
  ValueNotifier<bool>? collapsed,
  AppActionRegistry? actions,
}) async {
  final notifier = collapsed ?? ValueNotifier(false);
  if (collapsed == null) addTearDown(notifier.dispose);
  unawaited(
    showKitPopover<void>(
      context: host.anchor.currentContext!,
      anchor: host.anchor,
      builder: (context) => KitPenPanel(
        kind: kind,
        currentTool: () => host.tool,
        setTool: (t) {
          host.tools.add(t);
          host.calls.add('tool');
          host.tool = t;
        },
        setColor: (c) {
          host.colors.add(c);
          host.calls.add('color');
          final t = host.tool;
          if (t is Pen) t.color = c;
        },
        onClose: () => Navigator.of(context).pop(),
        collapsed: notifier,
        actions: actions,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> closePanel(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('pen-panel-close')));
  await tester.pumpAndSettle();
  expect(find.byType(KitPenPanel), findsNothing);
}

/// Puts back every setting and pen in hand the pen, eraser and lasso panel
/// tests change.
void resetPenPanelState() {
  for (final stow in [
    stows.highlighterAxisLock,
    stows.penPanelCollapsed,
    stows.eraseHighlighterOnly,
    stows.disableEraserAfterUse,
    stows.selectRectangle,
    stows.selectInk,
    stows.selectHighlighter,
    stows.selectShapes,
    stows.selectImages,
  ]) {
    stow.value = stow.defaultValue;
  }
  stows.eraserTargets.value = stows.eraserTargets.defaultValue;
  stows.eraserSize.value = stows.eraserSize.defaultValue;
  stows.eraserMode.value = stows.eraserMode.defaultValue;
  stows.penBox.value = stows.penBox.defaultValue;
  stows.pinnedColors.value = stows.pinnedColors.defaultValue;
  stows.recentColorsPositioned.value =
      stows.recentColorsPositioned.defaultValue;
  stows.recentColorsChronological.value =
      stows.recentColorsChronological.defaultValue;
  stows.autoStraightenLines.value = stows.autoStraightenLines.defaultValue;
  stows.highlighterStraightLine.value =
      stows.highlighterStraightLine.defaultValue;
  stows.preferGreyscale.value = stows.preferGreyscale.defaultValue;
  stows.editorAutoInvert.value = stows.editorAutoInvert.defaultValue;
  stows.lastFountainPenOptions.value =
      stows.lastFountainPenOptions.defaultValue;
  stows.lastBallpointPenOptions.value =
      stows.lastBallpointPenOptions.defaultValue;
  stows.lastPencilOptions.value = stows.lastPencilOptions.defaultValue;
  stows.lastHighlighterOptions.value =
      stows.lastHighlighterOptions.defaultValue;
  stows.lastShapePenOptions.value = stows.lastShapePenOptions.defaultValue;
  for (final color in [
    stows.lastFountainPenColor,
    stows.lastBallpointPenColor,
    stows.lastPencilColor,
    stows.lastShapePenColor,
    stows.lastHighlighterColor,
  ]) {
    color.value = color.defaultValue;
  }
  Pen.currentPen = Pen.fountainPen();
  Pencil.currentPencil = Pencil();
  Highlighter.currentHighlighter = Highlighter();
}

Finder iconNamed(KitIconName n) =>
    find.byWidgetPredicate((w) => w is KitIcon && w.name == n);

Finder penColumn(KitPenKind k) =>
    find.byKey(ValueKey('pen-panel-pen-${k.previewId}'));

Finder penBody(KitPenKind k) =>
    find.byKey(ValueKey('pen-panel-pen-body-${k.previewId}'));

double bodyTop(WidgetTester tester, KitPenKind k) =>
    tester.getTopLeft(penBody(k)).dy;

Finder swatch(Color c) =>
    find.byKey(Key('kit-swatch-${c.toARGB32().toRadixString(16)}'));

Finder pageDot(int i) => find.byKey(Key('kit-swatch-page-dot-$i'));

/// The colour dot inside a swatch.
Finder swatchDot(Color c) =>
    find.descendant(of: swatch(c), matching: find.byType(DecoratedBox)).first;

/// The pen panel's size row (the stabiliser row has a slider too).
final sizeRow = find.byKey(const ValueKey('pen-panel-size'));

/// [f] inside the size row.
Finder inSizeRow(Finder f) => find.descendant(of: sizeRow, matching: f);

/// The number on the slider in [row], the size row by default.
String sliderNumber(WidgetTester tester, [Finder? row]) => tester
    .widget<Text>(
      find.descendant(
        of: find.descendant(
          of: row ?? sizeRow,
          matching: find.byKey(const Key('kit-slider-number')),
        ),
        matching: find.byType(Text),
      ),
    )
    .data!;

KitPenSample penSample(WidgetTester tester) =>
    tester.widget<KitPenSample>(find.byType(KitPenSample));

/// A colour as the recent and pinned colour lists keep it.
String colourString(Color c) => c.toARGB32().toString();
