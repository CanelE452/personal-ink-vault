import 'package:flutter/foundation.dart';
import 'package:saber/components/kit/kit_pen_art.dart';
import 'package:saber/data/ink/ink_tool_state.dart';
import 'package:saber/data/ink/pen_kind.dart';
import 'package:saber/data/prefs.dart';
import 'package:sbn/tool_id.dart';

/// The settings table's keys of the pen in hand's 「직선 자동 보정」 and
/// 「수평/수직 그리기」 ([PenSettingInHand]). data/settings writes them out as
/// text in its rule (it may not import this); a test holds them together.
const straightLineInHandKey = 'straightLineInHand';
const axisLockInHandKey = 'axisLockInHand';

/// Whether [kind] makes its lines straight (「직선 자동 보정」). Each pen has
/// its own (user answer 2) and starts off: the one older builds kept for all
/// pens (`autoStraightenLines`, on by default) is not read. Until a
/// highlighter is set here, it reads the highlighter setting older builds
/// kept (`highlighterStraightLine`, off by default), which was already that
/// pen's own.
bool straightLineOf(KitPenKind kind) =>
    stows.straightLineByPen.value[kind.previewId] ??
    (kind.isHighlighter && stows.highlighterStraightLine.value);

void setStraightLine(KitPenKind kind, bool on) =>
    stows.straightLineByPen.value = {
      ...stows.straightLineByPen.value,
      kind.previewId: on,
    };

/// Whether [kind] keeps its straight lines horizontal or vertical
/// (「수평/수직 그리기」), as it is set: the settings table's rule makes it
/// unusable while that pen's straight line is off. Off until set; a
/// highlighter until then reads `highlighterAxisLock`.
bool axisLockOf(KitPenKind kind) =>
    stows.axisLockByPen.value[kind.previewId] ??
    (kind.isHighlighter && stows.highlighterAxisLock.value);

void setAxisLock(KitPenKind kind, bool on) => stows.axisLockByPen.value = {
  ...stows.axisLockByPen.value,
  kind.previewId: on,
};

/// The pen a note opens with: the last tool in hand when it is one of the
/// pen panel's pens (the round highlighter when it was the last one), else
/// the pen button's last pen ([Stows.lastPenFamily]) when that draws ink,
/// else the fountain pen, which the editor starts with when nothing is
/// saved.
KitPenKind startPenKind() =>
    _inkPenOf(stows.lastTool.value) ??
    _inkPenOf(stows.lastPenFamily.value) ??
    KitPenKind.fountain;

KitPenKind? _inkPenOf(ToolId tool) => switch (tool) {
  ToolId.fountainPen => KitPenKind.fountain,
  ToolId.calligraphyPen => KitPenKind.calligraphy,
  ToolId.ballpointPen => KitPenKind.finePen,
  ToolId.pencil => KitPenKind.pencil,
  ToolId.brush => KitPenKind.brush,
  ToolId.highlighter =>
    stows.lastHighlighterKind.value == KitPenKind.highlighterRound.previewId
        ? KitPenKind.highlighterRound
        : KitPenKind.highlighterChisel,
  _ => null,
};

/// The straight line ([PenSettingInHand.straightLine]) or the 수평/수직
/// ([PenSettingInHand.axisLock]) of the pen in hand, as one on/off value:
/// the pen panel's switches and the settings table's rows
/// ([straightLineInHandKey], [axisLockInHandKey]) read and set it.
///
/// With [tools] the pen in hand is that tool state's, and none while it
/// holds no ink pen (the eraser, the shape pen): then the value is off and
/// setting it changes no pen. Without, it is the pen a note opens with
/// ([startPenKind], the settings page). Listeners hear when the value shown
/// changes: another pen in hand, or a pen's setting.
class PenSettingInHand extends ValueNotifier<bool> {
  new straightLine([this.tools]) : _axis = false, super(false) {
    _listen();
  }

  new axisLock([this.tools]) : _axis = true, super(false) {
    _listen();
  }

  final InkToolState? tools;
  final bool _axis;

  /// The value listeners last heard of.
  var _shown = false;

  late final _sources = Listenable.merge([
    ?tools,
    stows.lastTool,
    stows.lastPenFamily,
    stows.lastHighlighterKind,
    if (_axis) ...[
      stows.axisLockByPen,
      stows.highlighterAxisLock,
    ] else ...[
      stows.straightLineByPen,
      stows.highlighterStraightLine,
    ],
  ]);

  KitPenKind? get kind => switch (tools) {
    final tools? => penKindOf(tools.tool),
    null => startPenKind(),
  };

  @override
  bool get value => switch (kind) {
    null => false,
    final kind => _axis ? axisLockOf(kind) : straightLineOf(kind),
  };

  @override
  set value(bool on) {
    final kind = this.kind;
    if (kind == null) return;
    _axis ? setAxisLock(kind, on) : setStraightLine(kind, on);
  }

  void _listen() {
    _shown = value;
    _sources.addListener(_check);
  }

  void _check() {
    final now = value;
    if (now == _shown) return;
    _shown = now;
    notifyListeners();
  }

  @override
  void dispose() {
    _sources.removeListener(_check);
    super.dispose();
  }
}
