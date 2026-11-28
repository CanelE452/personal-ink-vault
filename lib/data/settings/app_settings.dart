import 'package:saber/data/prefs.dart';
import 'package:saber/data/settings/setting_entry.dart';
import 'package:saber/data/settings/setting_rule.dart';
import 'package:saber/data/settings/settings_registry.dart';

/// The app's one settings table. The settings page, the ink panels (pen,
/// eraser, lasso) and `main` use it. It comes with the ink rows and rules
/// ([registerInkRules]), so the panels read them without `main`.
final settingsRegistry = _create();

SettingsRegistry _create() {
  final registry = SettingsRegistry(reasons: stows.settingsAutoOffReasons);
  registerInkRules(registry);
  return registry;
}

/// The names of what the eraser rubs out, as `EraserTargets.value` works them
/// out (data/tools may not be imported here, so the four names are written
/// out; a test holds the two together): the stored list; until it is first
/// set, the old highlighter-only switch decides; a name nobody knows gives
/// all four.
List<String> _eraserTargetNames() {
  const all = ['pen', 'pencil', 'highlighter', 'shape'];
  final stored = stows.eraserTargets.value;
  if (stored.isEmpty) {
    return stows.eraseHighlighterOnly.value ? const ['highlighter'] : all;
  }
  return stored.every(all.contains) ? stored : all;
}

/// Puts into [registry] the rows the ink panels read (none of them is listed
/// on the settings page) and the rules over them. Calling it again replaces
/// each row in place and adds the rules once more, which says the same.
///
/// The rows of the pen in hand's straight line and 수평/수직 (each pen has
/// its own, user answer 2) are pages/settings/settings_entries.dart's: their
/// value is data/ink's `PenSettingInHand`, which data/settings may not
/// import. Their rule is here, under their keys written out
/// (`straightLineInHandKey`, `axisLockInHandKey`; a test holds them
/// together). A pen panel gives its own pen's straight line to
/// [SettingsRegistry.unusableReason].
void registerInkRules(SettingsRegistry registry) {
  const group = '펜·도구';
  registry.register(
    ListSetting(
      key: stows.eraserTargets.key,
      label: '지울 대상',
      group: group,
      notifier: stows.eraserTargets,
      read: _eraserTargetNames,
    ),
  );
  for (final (stow, label) in [
    (stows.selectInk, '손글씨'),
    (stows.selectHighlighter, '형광펜'),
    (stows.selectShapes, '도형'),
    (stows.selectImages, '사진'),
  ]) {
    registry.register(
      ToggleSetting(
        key: stow.key,
        label: label,
        group: group,
        onPage: false,
        notifier: stow,
      ),
    );
  }

  registry
    ..addRule(
      const Requires(
        key: 'axisLockInHand',
        needs: 'straightLineInHand',
        reason: '먼저 위의 ‘직선 자동 보정’을 켜세요.',
      ),
    )
    ..addRule(
      KeepOneOn.lists(
        keys: [stows.eraserTargets.key],
        reason: '지울 대상은 하나 이상 있어야 합니다. 다른 대상을 먼저 켜세요.',
      ),
    )
    ..addRule(
      KeepOneOn.toggles(
        keys: [
          stows.selectInk.key,
          stows.selectHighlighter.key,
          stows.selectShapes.key,
          stows.selectImages.key,
        ],
        reason: '하나는 켜 두어야 합니다.',
      ),
    );
}
