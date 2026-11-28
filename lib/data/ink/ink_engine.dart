import 'package:flutter/foundation.dart';
import 'package:saber/components/kit/kit_pen_art.dart';
import 'package:saber/data/ink/ink_tool_state.dart';
import 'package:saber/data/ink/pen_kind.dart';
import 'package:saber/data/tools/_tool.dart';
import 'package:saber/data/tools/eraser.dart';
import 'package:saber/data/tools/eraser_targets.dart';
import 'package:saber/data/tools/lasso_targets.dart';
import 'package:saber/data/tools/pen.dart';
import 'package:stow_plain/stow_plain.dart';

/// How many strokes of each kind the page in view holds (the eraser's
/// 「켠 대상 지우기 (N개)」). The host gives it: the engine values are const.
typedef InkTargetCounts = Map<StrokeKind, int> Function();

/// What a host's ink engine can do, so the floating bar, the pen panel and
/// the eraser and lasso windows show that and nothing more (design: the
/// pens and rows the engine lacks are not shown). The editor's engine has
/// everything ([editor]); the infinite note has its own pen and
/// highlighter and fewer settings; the quick note's is [quickNote].
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

  /// The quick note's engine: the editor's pens and pen settings, the
  /// stroke eraser, and no lasso.
  static const quickNote = InkEngineSupport(
    eraserModes: [EraserMode.stroke],
    lassoTargets: [],
  );

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

  /// The pens on the floating bar, in order: the host's own, or the
  /// preview's (`#toolPill`) with one button for the highlighters.
  List<KitPenKind> get barPenKinds => [
    ...?pens?.keys,
    if (pens == null) ...[
      KitPenKind.fountain,
      KitPenKind.finePen,
      KitPenKind.brush,
      KitPenKind.pencil,
      KitPenKind.highlighterChisel,
    ],
  ];

  /// The tool to pick up for [kind]: the host's own, or the one [state]
  /// keeps for it.
  Tool toolFor(KitPenKind kind, InkToolState state) =>
      pens?[kind] ?? toolForPenKind(kind, state);

  /// Turns the first eraser and lasso target this engine shows on when none
  /// it shows is (the editor may have left only others on), so its windows
  /// keep one on as the editor's do. Called as a window opens. An engine
  /// that shows no targets of a kind (the quick note's lasso) leaves them.
  void keepTargetsOn() {
    final eraser = eraserTargets;
    if (eraser != null &&
        eraser.isNotEmpty &&
        !eraser.any(EraserTargets.value.contains)) {
      EraserTargets.set(eraser.first, true);
    }
    final lasso = lassoTargets;
    if (lasso != null &&
        lasso.isNotEmpty &&
        !lasso.any((target) => target.value)) {
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
