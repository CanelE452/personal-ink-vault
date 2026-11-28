import 'package:flutter/widgets.dart';
import 'package:saber/components/kit/kit_tokens.dart';

/// The track of the opacity slider (preview `.atrack`): a checkerboard under
/// a ramp from clear to [ink], in the slider's rounded 14 high bar.
class KitOpacityTrackPainter extends CustomPainter {
  const new(this.ink);

  /// The pen's ink, opaque.
  final Color ink;

  /// The thumb's colour at [percent] (10 to 100): the ink mixed with white
  /// by what is left to 100 (preview `mix(ink, '#ffffff', 1 - v / 100)`).
  static Color thumbAt(Color ink, int percent) =>
      Color.lerp(ink, KitTokens.sliderThumbColor, 1 - percent / 100)!;

  @override
  void paint(Canvas canvas, Size size) {
    final track = Rect.fromCenter(
      center: size.center(Offset.zero),
      width: size.width,
      height: KitTokens.sliderHeight,
    );
    canvas
      ..save()
      ..clipRRect(
        RRect.fromRectAndRadius(
          track,
          const Radius.circular(KitTokens.sliderHeight / 2),
        ),
      )
      ..drawRect(track, Paint()..color = KitTokens.opacityCheckerLight);
    // the dark squares: the top right and bottom left of each 8 px tile
    final dark = Paint()..color = KitTokens.opacityCheckerDark;
    const cell = KitTokens.opacityCheckerCell;
    for (var row = 0; row * cell < track.height; row++) {
      for (var col = 0; col * cell < track.width; col++) {
        if ((row + col).isEven) continue;
        canvas.drawRect(
          Rect.fromLTWH(
            track.left + col * cell,
            track.top + row * cell,
            cell,
            cell,
          ),
          dark,
        );
      }
    }
    // from the ink at no opacity, as CSS ramps from a clear colour
    canvas
      ..drawRect(
        track,
        Paint()
          ..shader = LinearGradient(colors: [ink.withValues(alpha: 0), ink])
              .createShader(track),
      )
      ..restore();
  }

  @override
  bool shouldRepaint(KitOpacityTrackPainter old) => old.ink != ink;
}
