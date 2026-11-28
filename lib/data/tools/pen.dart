import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:perfect_freehand/perfect_freehand.dart';
import 'package:saber/components/canvas/_stroke.dart';
import 'package:saber/components/kit/kit_pen_art.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/ink/pen_kind.dart' show specOf;
import 'package:saber/data/ink/stroke_style.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/tools/_tool.dart';
import 'package:saber/data/tools/highlighter.dart';
import 'package:saber/data/tools/pencil.dart';
import 'package:saber/data/tools/shape_pen.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:sbn/tool_id.dart';
import 'package:stow_plain/stow_plain.dart';

class Pen extends Tool {
  @protected
  @visibleForTesting
  new({
    required this.name,
    required this.sizeMin,
    required this.sizeMax,
    required this.sizeStep,
    required this.icon,
    required this.options,
    required this.pressureEnabled,
    required this.color,
    required this.toolId,
  });

  new fountainPen()
    : name = t.editor.pens.fountainPen,
      sizeMin = 1,
      sizeMax = 25,
      sizeStep = 1,
      icon = fountainPenIcon,
      options = stows.lastFountainPenOptions.value,
      pressureEnabled = true,
      color = Color(stows.lastFountainPenColor.value),
      toolId = .fountainPen;

  new ballpointPen()
    : name = t.editor.pens.ballpointPen,
      sizeMin = 1,
      sizeMax = 25,
      sizeStep = 1,
      icon = ballpointPenIcon,
      options = stows.lastBallpointPenOptions.value,
      pressureEnabled = false,
      color = Color(stows.lastBallpointPenColor.value),
      toolId = .ballpointPen;

  /// 만년필(넓은 촉): a chisel nib held at an angle, thicker across it.
  new calligraphyPen()
    : name = KitPenKind.calligraphy.label,
      sizeMin = specOf(KitPenKind.calligraphy).minSize,
      sizeMax = specOf(KitPenKind.calligraphy).maxSize,
      sizeStep = 1,
      icon = fountainPenIcon,
      options = stows.lastCalligraphyPenOptions.value,
      pressureEnabled = true,
      color = Color(stows.lastCalligraphyPenColor.value),
      toolId = .calligraphyPen;

  /// 붓: thick in the middle and thin at both ends.
  new brush()
    : name = KitPenKind.brush.label,
      sizeMin = specOf(KitPenKind.brush).minSize,
      sizeMax = specOf(KitPenKind.brush).maxSize,
      sizeStep = 1,
      icon = fountainPenIcon,
      options = stows.lastBrushOptions.value,
      pressureEnabled = true,
      color = Color(stows.lastBrushColor.value),
      toolId = .brush;

  final String name;
  final double sizeMin, sizeMax, sizeStep;
  late final int sizeStepsBetweenMinAndMax = ((sizeMax - sizeMin) / sizeStep)
      .round();
  final Object icon;

  @override
  final ToolId toolId;

  static const fountainPenIcon = FontAwesomeIcons.penFancy;
  static const ballpointPenIcon = FontAwesomeIcons.pen;

  static Stroke? currentStroke;
  Color color;
  bool pressureEnabled;
  StrokeOptions options;

  // Starts as the pen button's last kind, so a restart keeps the ballpoint.
  static var _currentPen = switch (stows.lastPenFamily.value) {
    .ballpointPen => Pen.ballpointPen(),
    .shapePen => ShapePen(),
    _ => Pen.fountainPen(),
  };
  static Pen get currentPen => _currentPen;
  static set currentPen(Pen currentPen) {
    assert(
      currentPen is! Highlighter,
      'Use Highlighter.currentHighlighter instead',
    );
    assert(currentPen is! Pencil, 'Use Pencil.currentPencil instead');
    _currentPen = currentPen;
  }

  /// What the pen button holds: the pencil if it was the last pen kind
  /// chosen, otherwise [currentPen] (fountain pen, ballpoint or shape pen).
  static Pen get currentPenFamily => stows.lastPenFamily.value == .pencil
      ? Pencil.currentPencil
      : currentPen;

  /// Whether [tool] is one of the pen button's kinds (not the highlighter).
  static bool isPenFamily(Tool tool) => tool is Pen && tool is! Highlighter;

  /// Where this pen keeps its colour for the next pen of its kind, or null.
  PlainStow<int?>? get colorStow => switch (toolId) {
    .fountainPen => stows.lastFountainPenColor,
    .ballpointPen => stows.lastBallpointPenColor,
    .shapePen => stows.lastShapePenColor,
    .pencil => stows.lastPencilColor,
    .highlighter => stows.lastHighlighterColor,
    .calligraphyPen => stows.lastCalligraphyPenColor,
    .brush => stows.lastBrushColor,
    _ => null,
  };

  /// Where this pen keeps its options for the next pen of its kind, or null.
  PlainStow<StrokeOptions?>? get optionsStow => switch (toolId) {
    .fountainPen => stows.lastFountainPenOptions,
    .ballpointPen => stows.lastBallpointPenOptions,
    .shapePen => stows.lastShapePenOptions,
    .pencil => stows.lastPencilOptions,
    .highlighter => stows.lastHighlighterOptions,
    .calligraphyPen => stows.lastCalligraphyPenOptions,
    .brush => stows.lastBrushOptions,
    _ => null,
  };

  /// The opacity (0 to 255) this pen keeps, or null for a pen without one:
  /// the pencil here, the highlighters in [Highlighter].
  PlainStow<int>? get opacityStow =>
      toolId == .pencil ? stows.pencilOpacity : null;

  /// The line this pen keeps, or null: only the fine pen has a choice.
  PlainStow<KitPenDash>? get lineStyleStow =>
      toolId == .ballpointPen ? stows.finePenLineStyle : null;

  /// The calligraphy pen's nib is a chisel, the others' round (the flat
  /// highlighter has its own, see [Highlighter.nib]).
  InkNib get nib => toolId == .calligraphyPen ? InkNib.chisel : InkNib.round;

  /// What this pen's strokes look like beyond colour and width: its opacity,
  /// line and nib as they are set now. [createStroke] gives a new stroke it
  /// before its first point, so the outline is right from the start.
  StrokeStyle get style => StrokeStyle(
    alpha: opacityStow?.value,
    lineStyle: lineStyleStow?.value ?? KitPenDash.solid,
    nib: nib,
  );

  /// Colours this pen and keeps the colour for the next pen of the same kind.
  void setColor(Color color) {
    this.color = color;
    colorStow?.value = color.toARGB32();
  }

  /// Keeps [alpha] (0 to 255) as this pen's opacity; nothing for a pen that
  /// has none.
  void setAlpha(int alpha) => opacityStow?.value = alpha;

  /// Keeps [style] as this pen's line; nothing for a pen that has no choice.
  void setLineStyle(KitPenDash style) => lineStyleStow?.value = style;

  List<double>? get sizePresets => switch (toolId) {
    .ballpointPen => const [3, 8, 15],
    .fountainPen || .pencil => const [5, 8, 15],
    .shapePen => const [3, 6, 10],
    // StarNote's shape_marker_pen_size_list_default.
    .highlighter => const [25, 35, 50],
    .calligraphyPen => const [5, 10, 20],
    .brush => const [5, 15, 30],
    _ => null,
  };

  void setSize(double size) {
    assert(size >= sizeMin && size <= sizeMax);
    if (options.size == size) return;
    _save(options.copyWith(size: size));
  }

  /// How much the pen steadies a stroke while it is drawn (0–1), shown as
  /// stroke stabilisation in the pen panel. It is kept in [options] as
  /// perfect_freehand's streamline, but the pens and the pencil smooth with
  /// the stroke stabiliser instead (see [onDragStart]).
  void setStreamline(double streamline) {
    assert(streamline >= 0 && streamline <= 1);
    if (options.streamline == streamline) return;
    _save(options.copyWith(streamline: streamline));
  }

  /// Keeps [updated] as this pen's options and, for the saved pens, as the
  /// options the next pen of the same kind starts with.
  void _save(StrokeOptions updated) {
    final setting = optionsStow;
    if (setting == null) {
      options = updated;
    } else {
      setting.value = updated;
      options = setting.value ?? updated;
    }
  }

  /// The stabiliser's width along the stroke at 100%, in logical pixels on
  /// screen (50%, the default, is 3).
  static const stabiliserWidthAtFull = 6.0;

  /// [screenScale] is the page's scale on screen (logical pixels per page
  /// unit), so the stabilisation looks the same at any zoom.
  void onDragStart(
    Offset position,
    EditorPage page,
    int pageIndex,
    double? pressure, {
    double screenScale = 1,
  }) {
    currentStroke = createStroke(page, pageIndex, screenScale: screenScale);
    onDragUpdate(position, pressure);
  }

  /// A new empty stroke in this pen's colour, width and stabiliser, on
  /// [page]. It leaves [currentStroke] alone, so the quick note can draw
  /// without the editor drawing the same stroke on its page [pageIndex].
  Stroke createStroke(
    EditorPage page,
    int pageIndex, {
    double screenScale = 1,
  }) {
    // The pens and the pencil smooth with the stabiliser and leave out
    // perfect_freehand's much weaker streamline; the highlighter and the
    // shape pen keep drawing as before.
    final stabilised = this is! Highlighter && this is! ShapePen;
    final stroke = Stroke(
      color: color,
      pressureEnabled: pressureEnabled,
      options: options.copyWith(
        isComplete: false,
        streamline: stabilised ? 0 : null,
      ),
      pageIndex: pageIndex,
      page: page,
      toolId: toolId,
      style: style,
    );
    if (stabilised) {
      stroke.stabilise(
        options.streamline * stabiliserWidthAtFull / screenScale,
      );
    }
    return stroke;
  }

  void onDragUpdate(Offset position, double? pressure) {
    currentStroke?.addPoint(position, pressure);
  }

  Stroke? onDragEnd() {
    final stroke = currentStroke;
    currentStroke = null;
    if (stroke == null) return null;

    return stroke
      // Finished: the points stay as they were last smoothed.
      ..stabilise(0)
      ..options.isComplete = true
      ..markPolygonNeedsUpdating();
  }

  /// The default stroke options.
  ///
  /// Note that these are different to the default options in [StrokeOptions]
  /// e.g. [StrokeOptions.defaultSize] for historical reasons
  /// (i.e. [StrokeOptions.toJson] does not include default values.)
  static final defaultOptions = StrokeOptions(size: 5);

  static StrokeOptions get fountainPenOptions => defaultOptions.copyWith();
  static StrokeOptions get ballpointPenOptions => defaultOptions.copyWith();
  static StrokeOptions get shapePenOptions =>
      defaultOptions.copyWith(smoothing: 0, streamline: 0);
  static StrokeOptions get highlighterOptions =>
      defaultOptions.copyWith(size: 50);
  static StrokeOptions get calligraphyPenOptions =>
      defaultOptions.copyWith(size: 8);
  static StrokeOptions get brushPenOptions => defaultOptions.copyWith(size: 10);
  static StrokeOptions get pencilOptions => defaultOptions.copyWith(
    streamline: 0.1,
    start: StrokeEndOptions.start(taperEnabled: true, customTaper: 1),
    end: StrokeEndOptions.end(taperEnabled: true, customTaper: 1),
  );
}
