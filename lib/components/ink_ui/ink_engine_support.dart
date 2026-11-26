import 'package:flutter/foundation.dart';
import 'package:saber/components/ink_ui/pen_panel/pen_kinds.dart';
import 'package:saber/components/kit/kit_pen_art.dart';
import 'package:saber/data/tools/_tool.dart';
import 'package:saber/data/tools/eraser.dart';
import 'package:saber/data/tools/eraser_targets.dart';
import 'package:saber/data/tools/lasso_targets.dart';
import 'package:saber/data/tools/pen.dart';
import 'package:stow_plain/stow_plain.dart';

/// What a host's ink engine can do, so the floating bar, the pen panel and
/// the eraser and lasso windows show that and nothing more (design: the
/// pens and rows the engine lacks are not shown). The editor's engine has
/// everything ([editor]); the infinite note has its own pen and
/// highlighter and fewer settings.
@immutable
class InkEngineSupport {
  const new({
    this.pens,
    this.penSettings = true,
    this.eraserModes,
    this.eraserTargets,
    this.lassoTargets,
  });

  /// The editor's engine.
  static const editor = InkEngineSupport();

  /// The host's own pens by kind, in the order they are offered; null: the
  /// editor's pens ([toolForPenKind]), every kind its engine has.
  final Map<KitPenKind, Pen>? pens;

  /// Whether the pen panel shows the pen box and its star, 「직선 자동 보정」
  /// (and the highlighter's 「수평/수직 그리기」) and 「스트로크 안정화」.
  final bool penSettings;

  /// The eraser kinds offered; null: all of [EraserMode].
  final List<EraserMode>? eraserModes;

  /// The eraser's 「지울 대상」 rows; null: all of [StrokeKind].
  final List<StrokeKind>? eraserTargets;

  /// The lasso's 「선택 대상」 rows, among [LassoTargets.all]; null: all.
  final List<PlainStow<bool>>? lassoTargets;

  /// The pen kinds offered, in order.
  List<KitPenKind> get penKinds => [
    ...?pens?.keys,
    if (pens == null)
      for (final kind in KitPenKind.values)
        if (kind.inEngine) kind,
  ];

  /// The tool to pick up for [kind].
  Tool toolFor(KitPenKind kind) => pens?[kind] ?? toolForPenKind(kind);

  /// Turns the first eraser and lasso target this engine shows on when none
  /// it shows is (the editor may have left only others on), so its windows
  /// keep one on as the editor's do. Called as a window opens.
  void keepTargetsOn() {
    final eraser = eraserTargets;
    if (eraser != null && !eraser.any(EraserTargets.value.contains)) {
      EraserTargets.set(eraser.first, true);
    }
    final lasso = lassoTargets;
    if (lasso != null && !lasso.any((target) => target.value)) {
      LassoTargets.set(lasso.first, true);
    }
  }

  /// The eraser kind in effect: the one chosen (`stows.eraserMode`) when
  /// offered, else the first offered.
  EraserMode eraserModeOf(EraserMode chosen) {
    final modes = eraserModes;
    if (modes == null || modes.contains(chosen)) return chosen;
    return modes.first;
  }
}
