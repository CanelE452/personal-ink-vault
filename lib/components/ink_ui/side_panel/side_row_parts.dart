import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:saber/components/kit/kit_icon.dart';
import 'package:saber/components/kit/kit_popover.dart';
import 'package:saber/components/kit/kit_text.dart';
import 'package:saber/components/kit/kit_tokens.dart';

// What the outline tab's and the audio tab's rows share (12th draft
// `.r1gt`, `.r1hint`, `.mb`, `.r1menu`, `.r1ren`, `.r1ok`).

/// `.r1gt`: a group's title, with its `.r1tag` or its `.cnt` at the end.
class KitSideGroupTitle extends StatelessWidget {
  const new(this.title, {super.key, this.tag, this.count});

  final String title;
  final String? tag;
  final String? count;

  @override
  Widget build(BuildContext context) => Padding(
    padding: KitTokens.sideGroupPadding,
    child: Row(
      children: [
        KitText(
          title,
          maxLines: 1,
          style: const TextStyle(
            fontSize: KitTokens.sideGroupFontSize,
            height: KitTokens.sideLineHeight,
            letterSpacing: 0,
            fontWeight: FontWeight.w600,
            color: KitTokens.sideGroupInk,
          ),
        ),
        if (tag != null) ...[
          const SizedBox(width: KitTokens.sideGroupGap),
          DecoratedBox(
            decoration: BoxDecoration(
              color: KitTokens.sideTagBg,
              borderRadius: BorderRadius.circular(KitTokens.sideTagRadius),
            ),
            child: Padding(
              padding: KitTokens.sideTagPadding,
              child: KitText(
                tag!,
                maxLines: 1,
                style: const TextStyle(
                  fontSize: KitTokens.sideTagFontSize,
                  height: KitTokens.sideLineHeight,
                  letterSpacing: 0,
                  fontWeight: FontWeight.w600,
                  color: KitTokens.sideGroupInk,
                ),
              ),
            ),
          ),
        ],
        if (count != null) ...[
          const Spacer(),
          KitText(
            count!,
            maxLines: 1,
            style: const TextStyle(
              fontSize: KitTokens.sideCountFontSize,
              height: KitTokens.sideLineHeight,
              letterSpacing: 0,
              color: KitTokens.sideCountInk,
            ),
          ),
        ],
      ],
    ),
  );
}

/// `.r1hint`: a line under the rows.
class KitSideHint extends StatelessWidget {
  const new(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: KitTokens.sideHintPadding,
    child: KitText(
      keepWords(text),
      style: const TextStyle(
        fontSize: KitTokens.sideHintFontSize,
        height: KitTokens.sideHintLineHeight,
        letterSpacing: 0,
        color: KitTokens.sideHintInk,
      ),
    ),
  );
}

/// How far the ⋯ button's 44 reaches past its 36 on each side.
const kitSideMenuReach =
    (KitTokens.sideRowMenuHit - KitTokens.sideRowMenuButton) / 2;

/// `.mb`: a row's ⋯, 36, pressed anywhere in 44 around it ([buttonKey] on
/// what is pressed).
class KitSideMoreButton extends StatelessWidget {
  const new({
    super.key,
    required this.buttonKey,
    required this.label,
    required this.open,
    required this.onTap,
  });

  final Key buttonKey;
  final String label;
  final bool open;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    expanded: open,
    excludeSemantics: true,
    child: GestureDetector(
      key: buttonKey,
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: const SizedBox.square(
        dimension: KitTokens.sideRowMenuHit,
        child: Center(
          child: SizedBox.square(
            dimension: KitTokens.sideRowMenuButton,
            child: Center(
              child: KitIcon(
                KitIconName.more,
                size: KitTokens.sideRowMenuIconSize,
                strokeWidth: KitTokens.sideRowMenuIconStroke,
                color: KitTokens.sideRowMenuInk,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// Where a row's menu hangs from, to put in the row's [Stack]: 8 from the
/// panel's right edge, 2 over the row's foot ([below]) or under its top
/// ([above]).
List<Widget> kitSideMenuAnchors(GlobalKey below, GlobalKey above) => [
  Positioned(
    right: KitTokens.sideMenuRight,
    bottom: KitTokens.sideMenuOverlap,
    width: KitTokens.sideMenuWidth,
    height: 0,
    child: SizedBox(key: below),
  ),
  Positioned(
    right: KitTokens.sideMenuRight,
    top: KitTokens.sideMenuOverlap,
    width: KitTokens.sideMenuWidth,
    height: 0,
    child: SizedBox(key: above),
  ),
];

/// What a row's menu offers.
enum KitSideRowAction { rename, remove }

/// The menu of the row at [context] (`placeMenu`): 「이름 바꾸기」 and
/// 「지우기」 under the row, or over it where it would come too near the
/// panel's foot; what was picked, once it is closed.
Future<KitSideRowAction?> showKitSideRowMenu(
  BuildContext context, {
  required GlobalKey below,
  required GlobalKey above,
}) {
  final box = context.findRenderObject()! as RenderBox;
  final view = Scrollable.of(context).context.findRenderObject()! as RenderBox;
  final foot = box.localToGlobal(
    Offset(0, box.size.height - KitTokens.sideMenuOverlap),
    ancestor: view,
  );
  const height = 2 * KitTokens.sideMenuRow;
  final up = foot.dy + height > view.size.height - KitTokens.sideMenuFoot;
  return showKitPopover<KitSideRowAction>(
    context: context,
    anchor: up ? above : below,
    grow: up ? AxisDirection.up : AxisDirection.down,
    radius: BorderRadius.circular(KitTokens.sideMenuRadius),
    shadows: KitTokens.sideMenuShadow,
    border: false,
    builder: (context) => SizedBox(
      width: KitTokens.sideMenuWidth,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _MenuItem(
            icon: KitIconName.rename,
            label: '이름 바꾸기',
            onTap: () => Navigator.of(context).pop(KitSideRowAction.rename),
          ),
          _MenuItem(
            icon: KitIconName.trash,
            label: '지우기',
            danger: true,
            lineAbove: true,
            onTap: () => Navigator.of(context).pop(KitSideRowAction.remove),
          ),
        ],
      ),
    ),
  );
}

/// `.r1menu .it`: a row of a row's menu, 44 high; with [lineAbove]
/// (`.it+.it`) its top 1 is the line between the rows.
class _MenuItem extends StatelessWidget {
  const new({
    required this.icon,
    required this.label,
    required this.onTap,
    this.danger = false,
    this.lineAbove = false,
  });

  final KitIconName icon;
  final String label;
  final VoidCallback onTap;
  final bool danger;
  final bool lineAbove;

  @override
  Widget build(BuildContext context) {
    final ink = danger ? KitTokens.danger : KitTokens.menuInk;
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: KitTokens.menuGroupBg,
            border: lineAbove
                ? const Border(
                    top: BorderSide(
                      color: KitTokens.menuLine,
                      width: KitTokens.menuLineWidth,
                    ),
                  )
                : null,
          ),
          child: SizedBox(
            height: KitTokens.sideMenuRow,
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                KitTokens.menuPaddingH,
                lineAbove ? KitTokens.menuLineWidth : 0,
                KitTokens.menuPaddingH,
                0,
              ),
              child: Row(
                children: [
                  KitIcon(
                    icon,
                    size: KitTokens.menuIconSize,
                    strokeWidth: KitTokens.menuIconStroke,
                    color: ink,
                  ),
                  const SizedBox(width: KitTokens.menuIconGap),
                  Expanded(
                    child: KitText(
                      label,
                      maxLines: 1,
                      style: TextStyle(
                        fontSize: KitTokens.sideMenuFontSize,
                        height: KitTokens.sideLineHeight,
                        letterSpacing: 0,
                        color: ink,
                        decoration: TextDecoration.none,
                      ),
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

/// A name being changed (`.r1ren`, `.r1ok`): the field (read out [label],
/// [fieldKey] on it), all of [title] chosen, [gap] before 「완료」. [onEdit]
/// hears what is typed. 「완료」, the keyboard's done or a press outside
/// ends it with what was typed, Escape with [title], once ([onDone]).
class KitSideRenameField extends StatefulWidget {
  const new({
    super.key,
    required this.title,
    required this.label,
    required this.fieldKey,
    required this.style,
    required this.gap,
    required this.onEdit,
    required this.onDone,
  });

  final String title;
  final String label;
  final Key fieldKey;
  final TextStyle style;
  final double gap;
  final ValueChanged<String> onEdit;
  final ValueChanged<String> onDone;

  @override
  State<KitSideRenameField> createState() => _KitSideRenameFieldState();
}

class _KitSideRenameFieldState extends State<KitSideRenameField> {
  late final _text = TextEditingController(text: widget.title)
    ..selection = TextSelection(
      baseOffset: 0,
      extentOffset: widget.title.length,
    );
  final _focus = FocusNode();
  var _done = false;

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _finish([String? title]) {
    if (_done) return;
    _done = true;
    widget.onDone(title ?? _text.text);
  }

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: SizedBox(
          height: KitTokens.sideRenameHeight,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: KitTokens.sidePanelBg,
              border: Border.all(
                color: KitTokens.accent,
                width: KitTokens.sideRenameLine,
              ),
              borderRadius: BorderRadius.circular(KitTokens.sideRenameRadius),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: KitTokens.sideRenamePadH + KitTokens.sideRenameLine,
              ),
              child: Align(
                alignment: Alignment.centerLeft,
                child: CallbackShortcuts(
                  bindings: {
                    const SingleActivator(LogicalKeyboardKey.escape): () =>
                        _finish(widget.title),
                  },
                  child: Semantics(
                    label: widget.label,
                    child: TextField(
                      key: widget.fieldKey,
                      controller: _text,
                      focusNode: _focus,
                      autofocus: true,
                      maxLines: 1,
                      textInputAction: TextInputAction.done,
                      cursorColor: KitTokens.accent,
                      style: widget.style,
                      decoration: const InputDecoration.collapsed(
                        hintText: null,
                      ),
                      onChanged: widget.onEdit,
                      onSubmitted: (_) => _finish(),
                      onTapOutside: (_) => _finish(),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
      SizedBox(width: widget.gap),
      Semantics(
        container: true,
        button: true,
        label: '완료',
        excludeSemantics: true,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _finish,
          child: const SizedBox(
            height: KitTokens.sideDoneHeight,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: KitTokens.sideDonePadH),
              child: Center(
                widthFactor: 1,
                child: KitText(
                  '완료',
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: KitTokens.sideDoneFontSize,
                    height: KitTokens.lineHeightOne,
                    letterSpacing: 0,
                    fontWeight: FontWeight.w600,
                    color: KitTokens.accent,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ],
  );
}
