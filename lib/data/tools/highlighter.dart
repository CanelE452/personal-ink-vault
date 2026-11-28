import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:perfect_freehand/perfect_freehand.dart';
import 'package:saber/data/ink/pen_kind.dart';
import 'package:saber/data/ink/pen_prefs.dart';
import 'package:saber/data/ink/stroke_style.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/tools/pen.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:stow_plain/stow_plain.dart';

class Highlighter extends Pen {
  /// The flat highlighter (납작 형광펜, the default) keeps the highlighter
  /// settings older builds kept; the round one ([Highlighter.round]) has its
  /// own, and until they are filled (`InkToolState.roundHighlighter`) reads
  /// the flat one's.
  new({this.nib = InkNib.chisel})
    : super(
        name: t.editor.pens.highlighter,
        sizeMin: 10,
        sizeMax: 100,
        // 5, so StarNote's 25 and 35 presets sit on the slider.
        sizeStep: 5,
        icon: highlighterIcon,
        options: nib == InkNib.chisel
            ? stows.lastHighlighterOptions.value
            : stows.lastRoundHighlighterOptions.value ??
                  stows.lastHighlighterOptions.value,
        pressureEnabled: false,
        color: Color(
          nib == InkNib.chisel
              ? stows.lastHighlighterColor.value
              : stows.lastRoundHighlighterColor.value ??
                    stows.lastHighlighterColor.value,
        ),
        toolId: .highlighter,
      );

  /// 둥근 형광펜: the round ends the highlighter of older builds drew.
  new round() : this(nib: InkNib.round);

  @override
  final InkNib nib;

  bool get _flat => nib == InkNib.chisel;

  @override
  PlainStow<int?>? get colorStow =>
      _flat ? stows.lastHighlighterColor : stows.lastRoundHighlighterColor;

  @override
  PlainStow<StrokeOptions?>? get optionsStow =>
      _flat ? stows.lastHighlighterOptions : stows.lastRoundHighlighterOptions;

  @override
  PlainStow<int>? get opacityStow =>
      _flat ? stows.highlighterOpacity : stows.roundHighlighterOpacity;

  /// With this highlighter's straight line on, the stroke stays a line from
  /// where it started to the pen; with its horizontal/vertical on as well,
  /// that line keeps to the closer axis.
  @override
  void onDragUpdate(Offset position, double? pressure) {
    super.onDragUpdate(position, pressure);
    final kind = penKindOf(this)!;
    if (straightLineOf(kind)) {
      Pen.currentStroke?.straightenWhileDrawing(axisLock: axisLockOf(kind));
    }
  }

  static const alpha = 100;

  static Pen currentHighlighter = Highlighter();

  static const highlighterIcon = FontAwesomeIcons.highlighter;
}
