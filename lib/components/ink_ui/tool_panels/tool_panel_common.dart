import 'package:flutter/material.dart';
import 'package:saber/components/kit/kit_controls.dart';
import 'package:saber/components/kit/kit_icon.dart';
import 'package:saber/components/kit/kit_text.dart';
import 'package:saber/components/kit/kit_tokens.dart';

/// The parts of the eraser and lasso windows (preview 10th draft 1-d,
/// `#eraser10 .e10o`). The window itself (colour, corner, shadow, nub) is
/// the popover's; these are what goes inside.

/// A window's contents: its title, then [children], [KitTokens.penPanelWidth]
/// wide.
class ToolWindow extends StatelessWidget {
  const new({super.key, required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: KitTokens.penPanelWidth,
    child: Padding(
      padding: const EdgeInsets.only(bottom: KitTokens.toolWindowPadBottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              KitTokens.toolWindowPadH,
              KitTokens.toolWindowTitlePadTop,
              KitTokens.toolWindowPadH,
              KitTokens.toolWindowTitlePadBottom,
            ),
            child: _exactLine(
              KitText(
                title,
                maxLines: 1,
                style: const TextStyle(
                  fontSize: KitTokens.toolWindowTitleSize,
                  height: KitTokens.toolWindowTitleHeight,
                  fontWeight: FontWeight.w600,
                  color: KitTokens.menuInk,
                  letterSpacing: 0,
                  decoration: TextDecoration.none,
                ),
              ),
            ),
          ),
          ...children,
        ],
      ),
    ),
  );
}

/// A group's title (`.gt`): 「크기」, 「지울 대상」, 「올가미 유형」.
class ToolWindowGroupTitle extends StatelessWidget {
  const new(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      KitTokens.toolWindowPadH,
      KitTokens.toolWindowGroupPadTop,
      KitTokens.toolWindowPadH,
      KitTokens.toolWindowGroupPadBottom,
    ),
    child: _exactLine(
      KitText(
        text,
        maxLines: 1,
        style: const TextStyle(
          fontSize: KitTokens.toolWindowGroupSize,
          height: KitTokens.toolWindowLine,
          fontWeight: FontWeight.w600,
          color: KitTokens.menuSub,
          letterSpacing: 0,
          decoration: TextDecoration.none,
        ),
      ),
    ),
  );
}

/// One line of [text] in a box exactly its font size x line height high, as
/// the preview lays it out: the engine rounds each line to whole pixels
/// (19.5 to 20), which would move everything under it.
Widget _exactLine(KitText text, {Alignment alignment = Alignment.bottomLeft}) =>
    SizedBox(
      height: text.style.fontSize! * text.style.height!,
      child: OverflowBox(
        alignment: alignment,
        maxHeight: double.infinity,
        child: text,
      ),
    );

/// One card of [ToolCards]: its setting value, name, icon and key.
typedef ToolCard<T> = ({T value, String label, KitIconName icon, String key});

/// The kind cards (`.e10cards`): side by side, the chosen one white with
/// its name in bold; tapping a card chooses it.
class ToolCards<T> extends StatelessWidget {
  const new({
    super.key,
    required this.cards,
    required this.value,
    required this.onChanged,
  });

  final List<ToolCard<T>> cards;
  final T value;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      KitTokens.toolCardsPadH,
      KitTokens.toolCardsPadTop,
      KitTokens.toolCardsPadH,
      KitTokens.toolCardsPadBottom,
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: KitTokens.toolCardsGap,
      children: [
        for (final card in cards)
          Expanded(
            child: _Card(
              key: ValueKey(card.key),
              label: card.label,
              icon: card.icon,
              chosen: card.value == value,
              onTap: () => onChanged(card.value),
            ),
          ),
      ],
    ),
  );
}

class _Card extends StatelessWidget {
  const new({
    super.key,
    required this.label,
    required this.icon,
    required this.chosen,
    required this.onTap,
  });

  final String label;
  final KitIconName icon;
  final bool chosen;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ink = chosen ? KitTokens.menuInk : KitTokens.menuSub;
    final shape = BorderRadius.circular(KitTokens.toolCardRadius);
    return Semantics(
      button: true,
      inMutuallyExclusiveGroup: true,
      selected: chosen,
      label: label,
      onTap: onTap,
      excludeSemantics: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: chosen ? KitTokens.toolCardOnBg : null,
          borderRadius: shape,
          boxShadow: chosen ? KitTokens.toolCardShadow : null,
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: shape,
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                minHeight: KitTokens.toolCardHeight,
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  KitTokens.toolCardPadH,
                  KitTokens.toolCardPadTop,
                  KitTokens.toolCardPadH,
                  KitTokens.toolCardPadBottom,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  spacing: KitTokens.toolCardGap,
                  children: [
                    KitIcon(
                      icon,
                      size: KitTokens.toolCardIconSize,
                      strokeWidth: KitTokens.toolCardIconStroke,
                      color: ink,
                      selected: chosen,
                    ),
                    _exactLine(
                      KitText(
                        label,
                        maxLines: 1,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: KitTokens.toolCardTextSize,
                          height: KitTokens.toolCardTextHeight,
                          fontWeight: chosen
                              ? FontWeight.w600
                              : FontWeight.w400,
                          color: ink,
                          letterSpacing: 0,
                          decoration: TextDecoration.none,
                        ),
                      ),
                      alignment: Alignment.bottomCenter,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A switch row (`.e10row`): [icon] if any, the name, the switch. While
/// [lockedReason] is set (the last target on) the switch cannot go off: it
/// keeps its look, screen readers hear it cannot be changed and why, and a
/// tap calls [onLocked] instead.
class ToolSwitchRow extends StatelessWidget {
  const new({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.icon,
    this.lockedReason,
    this.onLocked,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;
  final KitIconName? icon;
  final String? lockedReason;
  final VoidCallback? onLocked;

  @override
  Widget build(BuildContext context) {
    final locked = lockedReason != null;
    final icon = this.icon;
    return Semantics(
      container: true,
      toggled: value,
      enabled: !locked,
      label: label,
      hint: lockedReason,
      onTap: locked ? null : () => onChanged(!value),
      excludeSemantics: true,
      child: InkWell(
        onTap: locked ? onLocked : () => onChanged(!value),
        child: SizedBox(
          height: KitTokens.toolRowHeight,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: KitTokens.toolWindowPadH,
            ),
            child: Row(
              spacing: KitTokens.toolRowGap,
              children: [
                if (icon != null)
                  KitIcon(
                    icon,
                    size: KitTokens.menuIconSize,
                    strokeWidth: KitTokens.menuIconStroke,
                    color: KitTokens.menuInk,
                  ),
                Expanded(
                  child: KitText(
                    label,
                    maxLines: 1,
                    style: const TextStyle(
                      fontSize: KitTokens.toolRowTextSize,
                      height: KitTokens.toolWindowLine,
                      color: KitTokens.menuInk,
                      fontWeight: FontWeight.w400,
                      letterSpacing: 0,
                      decoration: TextDecoration.none,
                    ),
                  ),
                ),
                KitSwitch(value: value),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// [text] broken between words only, read out as written.
///
/// A line the engine rounds down (17.4 to 17) still takes its whole height,
/// so what follows sits where the preview has it; the text stays at the top.
Widget _words(String text, {required TextStyle style, TextAlign? textAlign}) =>
    Semantics(
      label: text,
      excludeSemantics: true,
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: style.fontSize! * style.height!),
        child: KitText(keepWords(text), textAlign: textAlign, style: style),
      ),
    );

/// A grey line of help (`.e10help`): centred under the cards, or from the
/// left under the rows ([left]).
Widget toolWindowHelp(String text, {required Key key, bool left = false}) =>
    Padding(
      key: key,
      padding: EdgeInsets.fromLTRB(
        KitTokens.toolWindowPadH,
        KitTokens.toolHelpPadTop,
        KitTokens.toolWindowPadH,
        left ? KitTokens.toolHelpPadBottomLeft : KitTokens.toolHelpPadBottom,
      ),
      child: _words(
        text,
        textAlign: left ? TextAlign.start : TextAlign.center,
        style: const TextStyle(
          fontSize: KitTokens.toolHelpSize,
          height: KitTokens.toolHelpHeight,
          color: KitTokens.menuSub,
          fontWeight: FontWeight.w400,
          letterSpacing: 0,
          decoration: TextDecoration.none,
        ),
      ),
    );

/// A red note (`.e10msg`): why a switch did not go off.
Widget toolWindowMessage(String text, {required Key key}) => Padding(
  key: key,
  padding: const EdgeInsets.fromLTRB(
    KitTokens.toolWindowPadH,
    KitTokens.toolMsgPadTop,
    KitTokens.toolWindowPadH,
    KitTokens.toolMsgPadBottom,
  ),
  child: Semantics(
    liveRegion: true,
    child: _words(
      text,
      style: const TextStyle(
        fontSize: KitTokens.toolHelpSize,
        height: KitTokens.toolMsgHeight,
        color: KitTokens.danger,
        fontWeight: FontWeight.w400,
        letterSpacing: 0,
        decoration: TextDecoration.none,
      ),
    ),
  ),
);

/// A grey note under a row (`.e10note`).
Widget toolWindowNote(String text) => Padding(
  padding: const EdgeInsets.fromLTRB(
    KitTokens.toolWindowPadH,
    0,
    KitTokens.toolWindowPadH,
    KitTokens.toolNotePadBottom,
  ),
  child: _words(
    text,
    style: const TextStyle(
      fontSize: KitTokens.toolHelpSize,
      height: KitTokens.toolWindowLine,
      color: KitTokens.menuSub,
      fontWeight: FontWeight.w400,
      letterSpacing: 0,
      decoration: TextDecoration.none,
    ),
  ),
);

/// The line between a window's groups (`.e10line`).
class ToolWindowLine extends StatelessWidget {
  const new({super.key});

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.only(
      top: KitTokens.toolLineTop,
      bottom: KitTokens.toolLineBottom,
    ),
    child: SizedBox(
      height: 1,
      child: ColoredBox(color: KitTokens.toolLineColor),
    ),
  );
}

/// A red row that does something that cannot be taken back without undo
/// (`.e10red`: 「쪽 지우기」). With [danger] false it is the same row in the
/// menu's ink at 600, the safe way out (the 「취소」 under the clear-page
/// window's 「지우기」, final review design call 1).
class ToolWindowRedButton extends StatelessWidget {
  const new({
    super.key,
    required this.label,
    required this.onTap,
    this.danger = true,
  });

  final String label;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    onTap: onTap,
    excludeSemantics: true,
    child: InkWell(
      onTap: onTap,
      child: SizedBox(
        height: KitTokens.toolRowHeight,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: KitTokens.toolWindowPadH,
          ),
          child: Align(
            alignment: Alignment.centerLeft,
            child: KitText(
              label,
              style: TextStyle(
                fontSize: KitTokens.toolRowTextSize,
                height: 1,
                color: danger ? KitTokens.danger : KitTokens.menuInk,
                fontWeight: danger ? FontWeight.w400 : FontWeight.w600,
                letterSpacing: 0,
                decoration: TextDecoration.none,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
