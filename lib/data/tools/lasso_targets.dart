import 'package:saber/data/prefs.dart';
import 'package:saber/data/settings/app_settings.dart';
import 'package:stow_plain/stow_plain.dart';

/// What the lasso picks up (「선택 대상」): handwriting, highlighter, shapes,
/// images. At least one stays on, or a loop would pick up nothing, so the
/// only one on cannot be turned off. The lasso window changes the settings
/// through here.
abstract final class LassoTargets {
  /// In the window's order.
  static List<PlainStow<bool>> get all => [
    stows.selectInk,
    stows.selectHighlighter,
    stows.selectShapes,
    stows.selectImages,
  ];

  /// Whether [target] is the only one on, so it cannot be turned off now. The
  /// settings table decides (its 「하나는 켜 두기」 rule).
  static bool isLocked(PlainStow<bool> target) =>
      settingsRegistry.keepOneReason(target.key) != null;

  /// Sets [target] to [on], unless that would turn the last one off: then
  /// nothing changes and this returns false.
  static bool set(PlainStow<bool> target, bool on) {
    if (!on && isLocked(target)) return false;
    target.value = on;
    return true;
  }
}
