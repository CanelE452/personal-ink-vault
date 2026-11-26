import 'package:saber/data/prefs.dart';

/// What a long press on a colour did.
enum PinChange { pinned, unpinned, full }

/// The colours kept with a long press (the old colour bar and the pen panel
/// share them) and their place among the recent colours. Colours are ARGB
/// numbers as strings, as the settings keep them.
abstract final class PinnedColors {
  /// Pins [colour] or takes its pin off. A pinned colour leaves the recent
  /// colours. An unpinned one goes back to them, in the oldest one's place
  /// when they are full, unless [backToRecent] is false. With [max], a new pin
  /// is refused once that many colours are pinned.
  ///
  /// The lists are replaced, not changed in place, so the settings save them
  /// and their listeners hear about it.
  static PinChange toggle(String colour, {int? max, bool backToRecent = true}) {
    final pinned = stows.pinnedColors.value;
    final order = [
      for (final c in stows.recentColorsChronological.value)
        if (c != colour) c,
    ];
    final recent = [
      for (final c in stows.recentColorsPositioned.value)
        if (c != colour) c,
    ];
    if (pinned.contains(colour)) {
      stows.pinnedColors.value = [
        for (final c in pinned)
          if (c != colour) c,
      ];
      if (backToRecent) {
        if (order.length >= stows.recentColorsLength.value) {
          final oldest = order.removeAt(0);
          final at = recent.indexOf(oldest);
          if (at >= 0) {
            recent[at] = colour;
          } else {
            recent.insert(0, colour);
          }
        } else {
          recent.insert(0, colour);
        }
        order.add(colour);
      }
      stows.recentColorsChronological.value = order;
      stows.recentColorsPositioned.value = recent;
      return PinChange.unpinned;
    }
    if (max != null && pinned.length >= max) return PinChange.full;
    stows.pinnedColors.value = [...pinned, colour];
    stows.recentColorsChronological.value = order;
    stows.recentColorsPositioned.value = recent;
    return PinChange.pinned;
  }
}
