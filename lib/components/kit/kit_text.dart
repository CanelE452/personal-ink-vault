import 'package:flutter/material.dart';

/// [text] with a word joiner (U+2060) between the letters of each word, so
/// a line breaks only at a space, as the preview's `word-break: keep-all`
/// (Flutter would break Korean between any two syllables).
String keepWords(String text) => [
  for (final word in text.split(' '))
    word.runes.map(String.fromCharCode).join('\u2060'),
].join(' ');

/// Interface text set like the preview's CSS, whatever fonts draw it.
///
/// Each line is exactly font size x height high (a forced strut with even
/// leading), so a line that mixes the app font (spaces, digits, Latin) with
/// the Korean fallback font does not grow. The preview's main font draws
/// Korean, so its lines sit on that font's baseline. Here the strut takes the
/// baseline from the app font, which puts Korean about a tenth of the font
/// size too high (Atkinson: 1.1 px at 11 px). The text is moved down by the
/// difference, measured from the fonts in use, so it lands where the preview
/// puts it on any device. Where one font draws everything (the test font)
/// nothing moves.
class KitText extends StatelessWidget {
  const new(
    this.data, {
    super.key,
    required this.style,
    this.textAlign,
    this.maxLines,
    this.softWrap,
    this.overflow,
  });

  final String data;
  final TextStyle style;
  final TextAlign? textAlign;
  final int? maxLines;
  final bool? softWrap;
  final TextOverflow? overflow;

  @override
  Widget build(BuildContext context) {
    final merged = DefaultTextStyle.of(context).style.merge(style);
    final text = Text(
      data,
      style: style,
      textAlign: textAlign,
      maxLines: maxLines,
      softWrap: softWrap,
      overflow: overflow,
      strutStyle: StrutStyle.fromTextStyle(
        merged,
        leadingDistribution: TextLeadingDistribution.even,
        forceStrutHeight: true,
      ),
    );
    final shift = kitKoreanBaselineShift(
      merged,
      MediaQuery.textScalerOf(context),
    );
    if (shift == 0) return text;
    return Transform.translate(offset: Offset(0, shift), child: text);
  }
}

/// [KitText] whose lines stand exactly font size x height apart, as CSS sets
/// them (a note's 11 px on a 1.4 line: 15.4).
///
/// Flutter rounds every line of a paragraph to whole pixels (15.4 to 15, 17.5
/// to 18), so a note of n lines comes out off by the difference n times. Here
/// the text is broken where one paragraph would break it, and each line is a
/// [KitText] at the foot of a box of the exact height. Measured against the
/// preview at scale 2: 12.5 px lines land on its glyph rows, 11 px ones about
/// half a pixel higher. It is read out as one text. It needs a bounded width.
class KitLines extends StatelessWidget {
  const new(this.data, {super.key, required this.style});

  final String data;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final merged = DefaultTextStyle.of(context).style.merge(style);
    final scaler = MediaQuery.textScalerOf(context);
    final pitch = scaler.scale(merged.fontSize!) * merged.height!;
    final direction = Directionality.of(context);
    return Semantics(
      label: data,
      excludeSemantics: true,
      child: LayoutBuilder(
        builder: (context, box) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final line in _breakLines(merged, scaler, direction, box))
              SizedBox(
                height: pitch,
                child: OverflowBox(
                  alignment: AlignmentDirectional.bottomStart,
                  maxHeight: double.infinity,
                  child: KitText(
                    line,
                    style: style,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.visible,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// [data] cut where one paragraph in [box]'s width breaks it, without the
  /// spaces at the breaks (CSS drops them too).
  List<String> _breakLines(
    TextStyle merged,
    TextScaler scaler,
    TextDirection direction,
    BoxConstraints box,
  ) {
    assert(box.hasBoundedWidth, 'KitLines needs a bounded width');
    final painter = TextPainter(
      text: TextSpan(text: data, style: merged),
      textDirection: direction,
      textScaler: scaler,
    )..layout(maxWidth: box.maxWidth);
    final edge = direction == TextDirection.ltr ? 0.0 : box.maxWidth;
    final starts = [
      for (final line in painter.computeLineMetrics())
        painter.getPositionForOffset(Offset(edge, line.baseline)).offset,
    ];
    painter.dispose();
    return [
      for (var i = 0; i < starts.length; i++)
        data
            .substring(
              i == 0 ? 0 : starts[i],
              i + 1 < starts.length ? starts[i + 1] : data.length,
            )
            .trim(),
    ];
  }
}

final _shifts = <(TextStyle, TextScaler), double>{};

/// How far below the app font's baseline the Korean font would put it as the
/// main font: half the difference of (ascent - descent) of the two, measured
/// with one Korean and one Latin glyph in [style].
double kitKoreanBaselineShift(TextStyle style, TextScaler scaler) =>
    _shifts.putIfAbsent((style, scaler), () {
      double halfSpan(String glyph) {
        final painter = TextPainter(
          text: TextSpan(text: glyph, style: style),
          textDirection: TextDirection.ltr,
          textScaler: scaler,
        )..layout();
        final line = painter.computeLineMetrics().single;
        painter.dispose();
        return (line.ascent - line.descent) / 2;
      }

      final shift = halfSpan('가') - halfSpan('H');
      // Within a hundredth of a pixel it is the same font.
      return shift.abs() < 0.01 ? 0.0 : shift;
    });
