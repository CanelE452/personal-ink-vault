import 'package:flutter/material.dart';

/// Settings text whose every line is exactly its font size x height high,
/// whatever fonts draw it. The app font has no Korean, so Korean glyphs come
/// from a fallback font; a line that mixes the two (a space, 「·」 or a digit
/// from the app font) would take the taller ascent of one and the deeper
/// descent of the other and grow by about one logical px.
class SettingsText extends StatelessWidget {
  const new(this.data, {super.key, required this.style});

  final String data;
  final TextStyle style;

  @override
  Widget build(BuildContext context) =>
      Text(data, style: style, strutStyle: settingsStrut(context, style));
}

/// The strut that holds each line of [style] (see [SettingsText]): forced,
/// with the text's own font, and even leading so that it is exactly font
/// size x height for any font, like a CSS line box.
StrutStyle settingsStrut(BuildContext context, TextStyle style) =>
    StrutStyle.fromTextStyle(
      DefaultTextStyle.of(context).style.merge(style),
      leadingDistribution: TextLeadingDistribution.even,
      forceStrutHeight: true,
    );
