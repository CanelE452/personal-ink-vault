import 'package:flutter/material.dart';
import 'package:saber/components/kit/kit_icon.dart';
import 'package:saber/components/kit/kit_motion.dart';
import 'package:saber/components/kit/kit_text.dart';
import 'package:saber/components/kit/kit_tokens.dart';

/// The left panel's tabs (12th draft `#extras12`, `TABS`), with the line an
/// empty tab shows. The pages tab is never empty.
enum KitSideTab {
  pages('쪽', KitIconName.sidePages, null),
  favorites('즐겨찾기', KitIconName.bookmark, '쪽 ⋯ 메뉴에서 「쪽 즐겨찾기」를 누르면 여기에 모입니다.'),
  outline('개요', KitIconName.outlineList, '쪽 ⋯ 메뉴에서 「개요에 추가」를 누르면 여기에 모입니다.'),
  audio('오디오', KitIconName.audioClip, '도구 막대의 녹음 단추를 누르면 녹음이 여기에 모입니다.');

  new(this.label, this.icon, this.empty);

  final String label;
  final KitIconName icon;
  final String? empty;
}

/// The left panel over the page (`.r1side`): [tabs] on top, [tab] chosen,
/// and [body], the chosen tab's content, below them. It fills its parent and
/// stands at its left, [KitTokens.sidePanelWidth] wide, or across all of it
/// on a [phone] (no shadow there). It slides in from the left while [open]
/// turns on and out while it turns off ([KitMotion.sidePanelSlide]); closed,
/// it is not there.
class KitSidePanel extends StatefulWidget {
  const new({
    super.key,
    required this.open,
    required this.phone,
    required this.tabs,
    required this.tab,
    required this.onTab,
    required this.body,
  });

  final bool open;
  final bool phone;
  final List<KitSideTab> tabs;
  final KitSideTab tab;
  final ValueChanged<KitSideTab> onTab;

  /// Scrolls itself when it is longer than the panel.
  final Widget body;

  @override
  State<KitSidePanel> createState() => _KitSidePanelState();
}

class _KitSidePanelState extends State<KitSidePanel>
    with SingleTickerProviderStateMixin {
  late final _slide = AnimationController(
    vsync: this,
    duration: KitMotion.sidePanelSlide,
    value: widget.open ? 1 : 0,
  )..addStatusListener((_) => setState(() {}));

  // The preview eases both ways on the same curve, from where it starts.
  late final _position =
      Tween(
        begin: const Offset(KitTokens.sidePanelHiddenShift, 0),
        end: Offset.zero,
      ).animate(
        CurvedAnimation(
          parent: _slide,
          curve: KitMotion.samsungDecel,
          reverseCurve: KitMotion.samsungDecel.flipped,
        ),
      );

  @override
  void didUpdateWidget(KitSidePanel old) {
    super.didUpdateWidget(old);
    if (widget.open != old.open) {
      widget.open ? _slide.forward() : _slide.reverse();
    }
  }

  @override
  void dispose() {
    _slide.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_slide.isDismissed) return const SizedBox.shrink();
    final panel = DecoratedBox(
      decoration: BoxDecoration(
        color: KitTokens.sidePanelBg,
        boxShadow: widget.phone ? null : KitTokens.sidePanelShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Tabs(tabs: widget.tabs, tab: widget.tab, onTab: widget.onTab),
          Expanded(child: widget.body),
        ],
      ),
    );
    return Align(
      alignment: Alignment.centerLeft,
      child: SizedBox(
        width: widget.phone ? double.infinity : KitTokens.sidePanelWidth,
        height: double.infinity,
        child: RepaintBoundary(
          child: SlideTransition(
            position: _position,
            child: Semantics(
              key: const ValueKey('kit-side-panel'),
              container: true,
              explicitChildNodes: true,
              label: '왼쪽 창',
              child: panel,
            ),
          ),
        ),
      ),
    );
  }
}

/// `.r1tabs`: the tabs side by side in a light well, the chosen one white.
class _Tabs extends StatelessWidget {
  const new({required this.tabs, required this.tab, required this.onTab});

  final List<KitSideTab> tabs;
  final KitSideTab tab;
  final ValueChanged<KitSideTab> onTab;

  @override
  Widget build(BuildContext context) => Padding(
    padding: KitTokens.sideTabsMargin,
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: KitTokens.sideTabsBg,
        borderRadius: BorderRadius.circular(KitTokens.sideTabsRadius),
      ),
      child: Padding(
        padding: const EdgeInsets.all(KitTokens.sideTabsPadding),
        child: Row(
          children: [
            for (final (i, t) in tabs.indexed) ...[
              if (i > 0) const SizedBox(width: KitTokens.sideTabsGap),
              Expanded(
                child: _Tab(tab: t, on: t == tab, onTap: () => onTab(t)),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}

class _Tab extends StatelessWidget {
  const new({required this.tab, required this.on, required this.onTap});

  final KitSideTab tab;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ink = on ? KitTokens.sideTabOnInk : KitTokens.sideTabInk;
    return Semantics(
      selected: on,
      button: true,
      label: tab.label,
      excludeSemantics: true,
      child: GestureDetector(
        key: ValueKey('kit-side-tab-${tab.name}'),
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: on ? KitTokens.sideTabOnBg : null,
            borderRadius: BorderRadius.circular(KitTokens.sideTabRadius),
            boxShadow: on ? KitTokens.sideTabOnShadow : null,
          ),
          child: SizedBox(
            height: KitTokens.sideTabHeight,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                KitIcon(
                  tab.icon,
                  size: KitTokens.sideTabIconSize,
                  strokeWidth: KitTokens.sideTabIconStroke,
                  color: ink,
                ),
                const SizedBox(height: KitTokens.sideTabGap),
                KitText(
                  tab.label,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.visible,
                  style: TextStyle(
                    fontSize: KitTokens.sideTabFontSize,
                    height: KitTokens.sideTabLineHeight,
                    letterSpacing: 0,
                    fontWeight: FontWeight.w600,
                    color: ink,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// `.r1empty`: an empty tab's icon and its one line (or [text]), in the
/// middle. It scrolls when the panel is shorter (a phone on its side).
class KitSideEmpty extends StatelessWidget {
  const new(this.tab, {super.key, this.text});

  final KitSideTab tab;
  final String? text;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    child: Padding(
      padding: KitTokens.sideEmptyPadding,
      child: Column(
        children: [
          KitIcon(
            tab.icon,
            size: KitTokens.sideEmptyIconSize,
            strokeWidth: KitTokens.sideEmptyIconStroke,
            color: KitTokens.sideEmptyIconInk,
          ),
          const SizedBox(height: KitTokens.sideEmptyIconGap),
          KitText(
            keepWords(text ?? tab.empty ?? ''),
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: KitTokens.sideEmptyFontSize,
              height: KitTokens.sideEmptyLineHeight,
              // the preview spaces no letters (the Material theme's 0.25
              // would break 「…를 누르면」 a word early)
              letterSpacing: 0,
              color: KitTokens.sideEmptyInk,
            ),
          ),
        ],
      ),
    ),
  );
}
