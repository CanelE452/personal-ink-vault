import 'package:flutter/material.dart';
import 'package:saber/components/ink_ui/tool_panels/tool_panel_common.dart';
import 'package:saber/components/kit/kit_icon.dart';
import 'package:saber/data/ink/ink_engine.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/settings/app_settings.dart';
import 'package:saber/data/tools/lasso_targets.dart';
import 'package:stow_plain/stow_plain.dart';

/// 「올가미 선택」 (preview 10th draft `lassoPop`), opened from the chosen
/// lasso button: 「올가미 유형」 자유 · 사각형 as cards, then 「선택 대상」
/// 손글씨 · 형광펜 · 도형 · 사진. One target always stays on
/// ([LassoTargets]): the last one on keeps its look but cannot be turned off,
/// and a red note under the rows says so while it is the only one.
///
/// Only the targets [engine] picks up show (the infinite note: 손글씨 and
/// 형광펜); then the last of those on is the one that stays.
class KitLassoPanel extends StatelessWidget {
  const new({super.key, this.engine = InkEngineSupport.editor});

  /// What the document's ink engine has.
  final InkEngineSupport engine;

  /// Why the last target on cannot be turned off (the settings table's
  /// line).
  static String get keepOne =>
      settingsRegistry.keepOneText(stows.selectInk.key)!;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([stows.selectRectangle, ...LassoTargets.all]),
    builder: (context, _) {
      final all = LassoTargets.all;
      final shown = engine.lassoTargets ?? all;
      final shownKeys = [for (final t in shown) t.key];
      String? lockedReason(PlainStow<bool> t) =>
          settingsRegistry.keepOneReason(t.key, among: shownKeys);
      final hint = [for (final t in shown) lockedReason(t)]
          .nonNulls
          .firstOrNull;
      return ToolWindow(
        key: const ValueKey('kit-lasso-panel'),
        title: '올가미 선택',
        children: [
          const ToolWindowGroupTitle('올가미 유형'),
          ToolCards<bool>(
            cards: const [
              (
                value: false,
                label: '자유',
                icon: KitIconName.lassoFree,
                key: 'lasso-kind-free',
              ),
              (
                value: true,
                label: '사각형',
                icon: KitIconName.lassoRect,
                key: 'lasso-kind-rect',
              ),
            ],
            value: stows.selectRectangle.value,
            onChanged: (rectangle) => stows.selectRectangle.value = rectangle,
          ),
          const ToolWindowGroupTitle('선택 대상'),
          for (final (target, label, id) in [
            (all[0], '손글씨', 'ink'),
            (all[1], '형광펜', 'highlighter'),
            (all[2], '도형', 'shape'),
            (all[3], '사진', 'images'),
          ])
            if (shown.contains(target))
              ToolSwitchRow(
                key: ValueKey('lasso-target-$id'),
                label: label,
                value: target.value,
                lockedReason: lockedReason(target),
                onChanged: (on) => LassoTargets.set(target, on),
              ),
          if (hint != null)
            toolWindowMessage(hint, key: const ValueKey('lasso-target-hint')),
        ],
      );
    },
  );
}
