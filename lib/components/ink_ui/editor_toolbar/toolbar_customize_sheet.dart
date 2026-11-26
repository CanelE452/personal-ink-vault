import 'package:flutter/material.dart';
import 'package:saber/components/ink_ui/editor_toolbar/toolbar_tools_layout.dart';
import 'package:saber/components/kit/kit_controls.dart';
import 'package:saber/components/kit/kit_icon.dart';
import 'package:saber/components/kit/kit_text.dart';
import 'package:saber/components/kit/kit_tokens.dart';
import 'package:saber/data/prefs.dart';

abstract final class _Sheet {
  static const width = 340.0;
  static const top = 44.0;
  static const sideRoom = 24.0;
  static const bottomRoom = 64.0;
  static const scrim = KitTokens.customizeScrim;
  static const radius = 18.0;
  static const closeButton = 44.0;
  static const rowHeight = 44.0;

  /// `.kz` line height: the texts keep it whatever the fonts.
  static const line = 1.35;
  static const padH = 16.0;
  static const handleIcon = 18.0;
  static const handleStroke = 1.0625 * 24 / handleIcon;
  static const handleInk = KitTokens.customizeHandleInk;
  static const handleX = 16.0;
  static const toolIconX = 46.0;
  static const nameX = 80.0;
  static const count = KitTokens.menuValue;
  static const lift = KitTokens.customizeLift;
}

const _tooMany = '막대에는 6개까지 둘 수 있습니다. 다른 도구를 먼저 끄세요.';
const _tooFew = '도구는 하나 이상 있어야 합니다. 다른 도구를 먼저 켜세요.';

/// 「도구 막대 사용자화」 (preview 9th draft c, values §14-5 and §12-3 D):
/// over the page area, under a dim, 340 wide and 44 from the top. One list
/// of the toolbar's tools with a handle to drag, the name and a switch for
/// the bar; 1 to 6 on the bar, a red line when a switch is refused. Every
/// change is saved at once in `stows.editorToolbarTools` (the whole list, so
/// the 229 layout is not read again). 「기본값으로」 puts the default back,
/// 「닫기」, the cross and the dim close it.
class ToolbarCustomizeSheet extends StatefulWidget {
  const new({super.key, required this.onClose});

  final VoidCallback onClose;

  @override
  State<ToolbarCustomizeSheet> createState() => _ToolbarCustomizeSheetState();
}

class _ToolbarCustomizeSheetState extends State<ToolbarCustomizeSheet> {
  /// The refused change's line, if the last switch was refused.
  String? _refused;

  ToolbarToolsLayout get _layout => ToolbarToolsLayout.read(
    stored: stows.editorToolbarTools.value,
    stored229: stows.pageToolbarLayout.value,
  );

  void _save(ToolbarToolsLayout layout) => setState(() {
    _refused = null;
    stows.editorToolbarTools.value = layout.encode();
  });

  void _switch(String id) {
    final layout = _layout;
    final (result, next) = layout.withShown(id, !layout.shown.contains(id));
    switch (result) {
      case ToolbarToolSwitch.done:
        _save(next);
      case ToolbarToolSwitch.tooMany:
        setState(() => _refused = _tooMany);
      case ToolbarToolSwitch.tooFew:
        setState(() => _refused = _tooFew);
    }
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => Stack(
      children: [
        Positioned.fill(
          child: Semantics(
            label: '닫기',
            button: true,
            onTap: widget.onClose,
            excludeSemantics: true,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onClose,
              child: const ColoredBox(color: _Sheet.scrim),
            ),
          ),
        ),
        Align(
          alignment: Alignment.topCenter,
          child: Padding(
            padding: const EdgeInsets.only(top: _Sheet.top),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: (constraints.maxWidth - _Sheet.sideRoom).clamp(
                  0,
                  _Sheet.width,
                ),
                minWidth: (constraints.maxWidth - _Sheet.sideRoom).clamp(
                  0,
                  _Sheet.width,
                ),
                maxHeight: (constraints.maxHeight - _Sheet.bottomRoom).clamp(
                  0,
                  double.infinity,
                ),
              ),
              child: _panel(),
            ),
          ),
        ),
      ],
    ),
  );

  Widget _panel() => Semantics(
    scopesRoute: true,
    explicitChildNodes: true,
    label: '도구 막대 사용자화',
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: KitTokens.menuBg,
        borderRadius: BorderRadius.circular(_Sheet.radius),
        boxShadow: KitTokens.menuShadow,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(_Sheet.radius),
        child: Material(
          type: MaterialType.transparency,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _head(),
              Flexible(child: SingleChildScrollView(child: _tools())),
              _foot(),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _head() => Padding(
    padding: const EdgeInsets.fromLTRB(_Sheet.padH, 4, 4, 2),
    child: Row(
      children: [
        const Expanded(
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text(
              '도구 막대 사용자화',
              style: TextStyle(
                fontSize: KitTokens.menuTitleSize,
                fontWeight: FontWeight.w600,
                color: KitTokens.menuInk,
              ),
            ),
          ),
        ),
        Semantics(
          button: true,
          label: '닫기',
          onTap: widget.onClose,
          excludeSemantics: true,
          child: InkWell(
            key: const ValueKey('toolbar-customize-close'),
            borderRadius: BorderRadius.circular(12),
            onTap: widget.onClose,
            child: const SizedBox.square(
              dimension: _Sheet.closeButton,
              child: Center(
                child: KitIcon(
                  KitIconName.close,
                  size: KitTokens.menuIconSize,
                  strokeWidth: KitTokens.menuIconStroke,
                  color: KitTokens.menuInk,
                ),
              ),
            ),
          ),
        ),
      ],
    ),
  );

  Widget _tools() {
    final layout = _layout;
    final shown = layout.shown.length;
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: KitTokens.menuGroupBg,
        border: Border(top: BorderSide(color: KitTokens.menuLine)),
      ),
      child: Padding(
        // the line over the group takes its 1 as in CSS
        padding: const EdgeInsets.only(
          top: KitTokens.menuLineWidth + KitTokens.menuGroupPad,
          bottom: KitTokens.menuGroupPad,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                _Sheet.padH,
                KitTokens.menuGroupTitlePadTop,
                _Sheet.padH,
                0,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  const Expanded(
                    child: KitText(
                      '막대에 둘 도구',
                      style: TextStyle(
                        height: _Sheet.line,
                        fontSize: KitTokens.menuGroupTitleSize,
                        fontWeight: FontWeight.w600,
                        color: KitTokens.menuInk,
                      ),
                    ),
                  ),
                  KitText(
                    '$shown / ${ToolbarToolsLayout.maxShown}',
                    style: TextStyle(
                      height: _Sheet.line,
                      fontSize: 12,
                      fontWeight: _refused == null
                          ? FontWeight.w400
                          : FontWeight.w600,
                      color: _refused == null ? _Sheet.count : KitTokens.danger,
                    ),
                  ),
                ],
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(_Sheet.padH, 2, _Sheet.padH, 6),
              child: KitText(
                '1개 이상 6개 이하입니다. 나머지는 더 보기 안에 있습니다.',
                style: TextStyle(
                  fontSize: 12,
                  height: _Sheet.line,
                  color: KitTokens.menuSub,
                ),
              ),
            ),
            ReorderableListView(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: false,
              proxyDecorator: (child, _, _) => DecoratedBox(
                decoration: const BoxDecoration(
                  color: KitTokens.menuGroupBg,
                  boxShadow: _Sheet.lift,
                ),
                child: Material(type: MaterialType.transparency, child: child),
              ),
              onReorderItem: (from, to) => _save(layout.moved(from, to)),
              children: [
                for (final (index, id) in layout.ids.indexed)
                  _row(index, toolbarToolOf(id), layout.shown.contains(id)),
              ],
            ),
            if (_refused != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(_Sheet.padH, 4, _Sheet.padH, 10),
                child: Semantics(
                  liveRegion: true,
                  child: KitText(
                    _refused!,
                    style: const TextStyle(
                      fontSize: 12,
                      height: 1.4,
                      color: KitTokens.danger,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _row(int index, ToolbarTool tool, bool on) => SizedBox(
    key: ValueKey('toolbar-customize-${tool.id}'),
    height: _Sheet.rowHeight,
    child: Stack(
      children: [
        Positioned(
          left: _Sheet.handleX - 6,
          top: 0,
          bottom: 0,
          width: _Sheet.handleIcon + 12,
          child: ReorderableDragStartListener(
            key: ValueKey('toolbar-customize-drag-${tool.id}'),
            index: index,
            child: const Center(
              child: KitIcon(
                KitIconName.menu,
                size: _Sheet.handleIcon,
                strokeWidth: _Sheet.handleStroke,
                color: _Sheet.handleInk,
              ),
            ),
          ),
        ),
        Positioned(
          left: _Sheet.toolIconX,
          top: 0,
          bottom: 0,
          child: Center(
            child: ExcludeSemantics(
              child: KitIcon(
                tool.icon,
                size: KitTokens.menuIconSize,
                strokeWidth: KitTokens.menuIconStroke,
                color: KitTokens.menuInk,
              ),
            ),
          ),
        ),
        Positioned(
          left: _Sheet.nameX,
          right: _Sheet.padH + KitTokens.switchWidth + 12,
          top: 0,
          bottom: 0,
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              tool.label,
              maxLines: 1,
              style: const TextStyle(
                fontSize: KitTokens.menuFontSize,
                color: KitTokens.menuInk,
              ),
            ),
          ),
        ),
        Positioned(
          right: _Sheet.padH - 6,
          top: 0,
          bottom: 0,
          child: Semantics(
            container: true,
            toggled: on,
            label: '${tool.label} 막대에 보이기',
            onTap: () => _switch(tool.id),
            excludeSemantics: true,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _switch(tool.id),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 13),
                child: KitSwitch(value: on),
              ),
            ),
          ),
        ),
      ],
    ),
  );

  Widget _foot() => DecoratedBox(
    decoration: const BoxDecoration(
      color: KitTokens.menuGroupBg,
      border: Border(top: BorderSide(color: KitTokens.menuLine)),
    ),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(12, KitTokens.menuLineWidth + 8, 12, 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _footButton(
            '기본값으로',
            filled: false,
            onTap: () => _save(ToolbarToolsLayout.decode(const [])),
          ),
          _footButton('닫기', filled: true, onTap: widget.onClose),
        ],
      ),
    ),
  );

  Widget _footButton(
    String label, {
    required bool filled,
    required VoidCallback onTap,
  }) {
    final shape = BorderRadius.circular(12);
    return Material(
      color: filled ? KitTokens.accent : Colors.transparent,
      borderRadius: shape,
      child: InkWell(
        borderRadius: shape,
        onTap: onTap,
        child: Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              height: 1,
              fontWeight: FontWeight.w600,
              color: filled ? KitTokens.onAccent : KitTokens.accent,
            ),
          ),
        ),
      ),
    );
  }
}
