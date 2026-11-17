import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/tools/pen.dart';
import 'package:saber/i18n/strings.g.dart';

class Highlighter extends Pen {
  new()
    : super(
        name: t.editor.pens.highlighter,
        sizeMin: 10,
        sizeMax: 100,
        // 5, so StarNote's 25 and 35 presets sit on the slider.
        sizeStep: 5,
        icon: highlighterIcon,
        options: stows.lastHighlighterOptions.value,
        pressureEnabled: false,
        color: Color(stows.lastHighlighterColor.value),
        toolId: .highlighter,
      );

  /// With the highlighter panel's straight line on, the stroke stays a line
  /// from where it started to the pen; with horizontal/vertical on as well,
  /// that line keeps to the closer axis.
  @override
  void onDragUpdate(Offset position, double? pressure) {
    super.onDragUpdate(position, pressure);
    if (stows.highlighterStraightLine.value) {
      Pen.currentStroke?.straightenWhileDrawing(
        axisLock: stows.highlighterAxisLock.value,
      );
    }
  }

  static const alpha = 100;

  static Pen currentHighlighter = Highlighter();

  static const highlighterIcon = FontAwesomeIcons.highlighter;
}
