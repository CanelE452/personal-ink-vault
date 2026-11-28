import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';
import 'package:saber/components/kit/kit_pen_art.dart';
import 'package:saber/data/ink/pen_kind.dart';
import 'package:saber/data/ink/stroke_style.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/tools/_tool.dart';
import 'package:saber/data/tools/highlighter.dart';
import 'package:saber/data/tools/pen.dart';
import 'package:saber/data/tools/pencil.dart';

/// The tool in hand as the ink windows (the floating bar, the pen panel)
/// read it: the tool, the pen's colour, size, stabilisation, opacity and
/// line, and whether the eyedropper waits for its tap. The pens and their
/// settings stay the source of truth: a host writes the pen first, then
/// hands it to [update], so a change of colour or size reaches the windows
/// without building the document again.
class InkToolState extends ChangeNotifier {
  /// Starts with [tool], and its colour, size and stabilisation when it is a
  /// pen.
  new(Tool tool) : _tool = tool {
    if (tool is Pen) _readPen(tool);
  }

  Tool _tool;
  var _color = const Color(0xff000000);
  double _size = 0;
  double _stabiliser = 0;
  var _alpha = 255;
  var _lineStyle = KitPenDash.solid;
  var _eyedropper = false;

  /// The pens of the kinds that have no pen in hand of their own (no static
  /// one like [Pen.currentPen]): the calligraphy pen, the brush and the round
  /// highlighter, each made the first time it is asked for.
  final _newPens = <KitPenKind, Pen>{};

  Tool get tool => _tool;

  /// The colour, size, stabilisation, opacity (0 to 255) and line of the pen
  /// in hand, or of the last pen while another tool is (the eraser, the
  /// lasso, the text box).
  Color get color => _color;
  double get size => _size;
  double get stabiliser => _stabiliser;
  int get alpha => _alpha;
  KitPenDash get lineStyle => _lineStyle;

  bool get eyedropper => _eyedropper;

  /// The pen to pick up for [kind]. The pens in hand are used again, so each
  /// keeps its own size and colour: the fine-nib pen and the fine pen reuse
  /// [Pen.currentPen] when it is that kind, the pencil and the flat
  /// highlighter are their own pens in hand, and the other pens are kept
  /// here.
  Tool penFor(KitPenKind kind) {
    final current = Pen.currentPen;
    return switch (kind) {
      KitPenKind.fountain || KitPenKind.finePen =>
        current.toolId == kind.toolId ? current : newPenOf(kind),
      KitPenKind.pencil => Pencil.currentPencil,
      KitPenKind.highlighterChisel => Highlighter.currentHighlighter,
      KitPenKind.calligraphy ||
      KitPenKind.brush => _newPens[kind] ??= newPenOf(kind),
      KitPenKind.highlighterRound => _newPens[kind] ??= roundHighlighter(),
    };
  }

  /// A round highlighter to take in hand. The first one ever starts with the
  /// flat highlighter's colour and width, kept as its own from then on (the
  /// 232 highlighter drew round ends with those).
  static Pen roundHighlighter() {
    stows.lastRoundHighlighterColor.value ??= stows.lastHighlighterColor.value;
    stows.lastRoundHighlighterOptions.value ??=
        stows.lastHighlighterOptions.value;
    return Highlighter.round();
  }

  /// Takes the values given; a [tool] that is a pen also brings its own
  /// colour, size, stabilisation, opacity and line for those not given
  /// (another tool keeps the last pen's). Listeners hear once, and only when
  /// a value changed.
  void update({
    Tool? tool,
    Color? color,
    double? size,
    double? stabiliser,
    bool? eyedropper,
  }) {
    final before = _values;
    if (tool != null) {
      _tool = tool;
      if (tool is Pen) _readPen(tool);
    }
    if (color != null) _color = color;
    if (size != null) _size = size;
    if (stabiliser != null) _stabiliser = stabiliser;
    if (eyedropper != null) _eyedropper = eyedropper;
    if (!identical(before.$1, _tool) || before != _values) notifyListeners();
  }

  (Tool, Color, double, double, int, KitPenDash, bool) get _values =>
      (_tool, _color, _size, _stabiliser, _alpha, _lineStyle, _eyedropper);

  void _readPen(Pen pen) {
    _color = pen.color;
    _size = pen.options.size;
    _stabiliser = pen.options.streamline;
    final style = pen.style;
    _alpha = style.alpha ?? defaultAlphaOf(pen.toolId);
    _lineStyle = style.lineStyle;
    // a pen of a kind kept here that came in hand another way (the pen box,
    // the editor's start) is the one picked up from now on
    if (penKindOf(pen) case final kind? when _keptHere(kind)) {
      _newPens[kind] = pen;
    }
  }

  static bool _keptHere(KitPenKind kind) => switch (kind) {
    KitPenKind.calligraphy ||
    KitPenKind.brush ||
    KitPenKind.highlighterRound => true,
    _ => false,
  };
}

/// What the ink windows ask of the document that holds them: the editor,
/// the infinite note, the quick note. Each change goes to the tool in hand
/// first and is then told to [toolState].
abstract interface class InkToolHost {
  InkToolState get toolState;

  /// Takes [tool] in hand.
  void selectTool(Tool tool);

  /// Gives the pen in hand [color] (with the lasso in hand, the lassoed
  /// strokes).
  void setColor(Color color);

  /// Gives the pen in hand [size].
  void setSize(double size);

  /// Gives the pen in hand the stabilisation [value] (0 to 1).
  void setStabiliser(double value);

  /// Gives the pen in hand the opacity [alpha] (0 to 255): the highlighters
  /// and the pencil keep one.
  void setAlpha(int alpha);

  /// Gives the pen in hand the line [style]: the fine pen keeps one.
  void setLineStyle(KitPenDash style);
}
