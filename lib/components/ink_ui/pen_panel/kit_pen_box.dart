import 'package:flutter/material.dart';
import 'package:saber/components/ink_ui/pen_panel/pen_panel_common.dart';
import 'package:saber/components/ink_ui/pen_panel/size_level.dart';
import 'package:saber/components/kit/kit_pen_art.dart';
import 'package:saber/components/kit/kit_popover.dart';
import 'package:saber/components/kit/kit_text.dart';
import 'package:saber/components/kit/kit_tokens.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/tools/_tool.dart';
import 'package:saber/data/tools/highlighter.dart';
import 'package:saber/data/tools/pen.dart';
import 'package:saber/data/tools/pen_box.dart';
import 'package:saber/data/tools/pencil.dart';
import 'package:saber/data/tools/shape_pen.dart';
import 'package:sbn/tool_id.dart';

const _title = '펜 상자';
const _removeHint = '길게 눌러 빼기';
// design review I-1: 「별로」 read as 「그다지」; the star is named by its mark
const _empty = '자주 쓰는 펜은 ☆ 단추로 이 상자에 담아 두세요.';
const _shapePen = '도형 펜';

/// Opens the pen box at [anchor]: the pens kept with the pen panel's star.
/// A tap picks one up ([setTool] with a new pen of its kind, then [setColor]
/// with its colour, as the old toolbar did) and closes the box; a long press
/// takes it out of the box. With [currentTool] the pen in hand is marked.
Future<void> showKitPenBox(
  BuildContext context, {
  required GlobalKey anchor,
  required ValueChanged<Tool> setTool,
  required ValueChanged<Color> setColor,
  ValueGetter<Tool>? currentTool,
}) => showKitPopover<void>(
  context: context,
  anchor: anchor,
  builder: (context) => _PenBox(
    currentTool: currentTool,
    onPick: (entry) {
      setTool(entry.createPen());
      setColor(Color(entry.color));
      Navigator.of(context).pop();
    },
  ),
);

class _PenBox extends StatelessWidget {
  const new({required this.currentTool, required this.onPick});

  final ValueGetter<Tool>? currentTool;
  final ValueChanged<PenBoxEntry> onPick;

  static const _line = TextStyle(
    fontSize: KitTokens.pageNameSize,
    height: KitTokens.lineHeightOne,
    color: KitTokens.menuSub,
    decoration: TextDecoration.none,
    fontWeight: FontWeight.w400,
  );

  @override
  Widget build(BuildContext context) => PenPanelSurface(
    key: const ValueKey('kit-pen-box'),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(
        KitTokens.penPanelPadH,
        KitTokens.penPanelPadTop,
        KitTokens.penPanelPadH,
        KitTokens.penPanelPadBottom,
      ),
      child: ValueListenableBuilder(
        valueListenable: stows.penBox,
        builder: (context, _, _) {
          final entries = PenBox.entries;
          final tool = currentTool?.call();
          final inHand = tool is Pen ? PenBoxEntry.of(tool) : null;
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: KitTokens.penPanelHeadHeight,
                child: Row(
                  children: [
                    const Expanded(
                      child: KitText(
                        _title,
                        maxLines: 1,
                        style: TextStyle(
                          fontSize: KitTokens.penBoxTitleSize,
                          height: KitTokens.penBoxTitleHeight,
                          fontWeight: KitTokens.penBoxTitleWeight,
                          color: KitTokens.menuSub,
                          decoration: TextDecoration.none,
                        ),
                      ),
                    ),
                    // design review I-2: the long press is the only way out
                    if (entries.isNotEmpty)
                      const KitText(_removeHint, maxLines: 1, style: _line),
                  ],
                ),
              ),
              const SizedBox(height: KitTokens.penPanelHeadGap),
              if (entries.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(
                    vertical: KitTokens.penBoxEmptyPadV,
                  ),
                  child: KitText(
                    _empty,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: KitTokens.penBoxCardTextSize,
                      height: KitTokens.penBoxTitleHeight,
                      color: KitTokens.menuSub,
                      decoration: TextDecoration.none,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                )
              else
                Flexible(
                  child: SingleChildScrollView(
                    child: _grid(context, entries, inHand),
                  ),
                ),
            ],
          );
        },
      ),
    ),
  );

  Widget _grid(
    BuildContext context,
    List<PenBoxEntry> entries,
    PenBoxEntry? inHand,
  ) {
    final invert = inkInverted(context);
    const n = KitTokens.penBoxColumns;
    return Column(
      children: [
        for (var row = 0; row < entries.length; row += n) ...[
          if (row > 0) const SizedBox(height: KitTokens.penBoxGap),
          Row(
            children: [
              for (var col = 0; col < n; col++) ...[
                if (col > 0) const SizedBox(width: KitTokens.penBoxGap),
                Expanded(
                  child: row + col < entries.length
                      ? _Card(
                          index: row + col,
                          entry: entries[row + col],
                          invert: invert,
                          inHand: entries[row + col] == inHand,
                          onTap: () => onPick(entries[row + col]),
                        )
                      : const SizedBox.shrink(),
                ),
              ],
            ],
          ),
        ],
      ],
    );
  }
}

/// How the box shows a kept pen: its sample, its name and its size range.
/// The shape pen has no drawing of its own and shows the fine pen's sample.
(KitPenKind, String, Pen) _look(ToolId toolId) => switch (toolId) {
  ToolId.ballpointPen => (
    KitPenKind.finePen,
    KitPenKind.finePen.label,
    Pen.ballpointPen(),
  ),
  ToolId.pencil => (KitPenKind.pencil, KitPenKind.pencil.label, Pencil()),
  ToolId.highlighter => (
    KitPenKind.highlighterChisel,
    KitPenKind.highlighterChisel.label,
    Highlighter(),
  ),
  ToolId.shapePen => (KitPenKind.finePen, _shapePen, ShapePen()),
  _ => (KitPenKind.fountain, KitPenKind.fountain.label, Pen.fountainPen()),
};

class _Card extends StatelessWidget {
  const new({
    required this.index,
    required this.entry,
    required this.invert,
    required this.inHand,
    required this.onTap,
  });

  final int index;
  final PenBoxEntry entry;
  final bool invert;
  final bool inHand;
  final VoidCallback onTap;

  // The part of the sample sheet the strokes fill, at the sample's scale:
  // x 0-35, y 20-34 of the 60 x 34 sheet (preview line 1999). The sample box
  // centres the sheet, 0.2 below the box top (31 high for 30.6).
  static const _scale = KitTokens.penSampleScale;
  static const _strokeWidth = KitTokens.penSampleStrokeRight * _scale;
  static const _strokeHeight =
      (KitTokens.penSampleSheetHeight - KitTokens.penSampleStrokeTop) * _scale;
  static const _strokeTop =
      (KitTokens.penSampleHeight - KitTokens.penSampleSheetHeight * _scale) /
          2 +
      KitTokens.penSampleStrokeTop * _scale;

  @override
  Widget build(BuildContext context) {
    final (kind, name, range) = _look(entry.toolId);
    void remove() => PenBox.remove(entry);
    return Semantics(
      key: ValueKey('pen-box-entry-$index'),
      button: true,
      selected: inHand,
      label: name,
      onTap: onTap,
      onLongPress: remove,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        onLongPress: remove,
        child: SizedBox(
          height: KitTokens.penBoxCardHeight,
          child: DecoratedBox(
            decoration: BoxDecoration(
              // design review M-1: the pen in hand, in the chosen tool's fill
              color: inHand ? KitTokens.selectedFill : KitTokens.penBoxCardBg,
              borderRadius: BorderRadius.circular(KitTokens.penBoxCardRadius),
            ),
            child: Padding(
              padding: const EdgeInsets.only(
                top: KitTokens.penBoxCardPadTop,
                bottom: KitTokens.penBoxCardPadBottom,
              ),
              child: Column(
                children: [
                  Expanded(
                    child: Center(
                      child: SizedBox(
                        key: const ValueKey('pen-box-stroke'),
                        width: _strokeWidth,
                        height: _strokeHeight,
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            Positioned(
                              left: 0,
                              top: -_strokeTop,
                              width: KitTokens.penSampleWidth,
                              height: KitTokens.penSampleHeight,
                              child: KitPenSample(
                                kind,
                                visibleInk(Color(entry.color), invert),
                                level: sizeToLevel(
                                  entry.size,
                                  min: range.sizeMin,
                                  max: range.sizeMax,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  KitText(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: KitTokens.penBoxCardTextSize,
                      height: KitTokens.penBoxCardTextHeight,
                      color: KitTokens.menuSub,
                      decoration: TextDecoration.none,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
