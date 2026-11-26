import 'dart:async';

import 'package:flutter/material.dart';
import 'package:saber/components/ink_ui/doc_menu/kit_doc_menu.dart'
    show closeMenuThen;
import 'package:saber/components/kit/kit_icon.dart';
import 'package:saber/components/kit/kit_menu.dart';
import 'package:saber/components/kit/kit_tokens.dart';
import 'package:saber/data/vault/workspace_navigation.dart';

/// 229's list of the open tabs at the tab row's right end: the number of
/// tabs and a ⌄, white on the 9th draft c row. It opens a kit window under
/// itself: 탭 줄 숨기기 and 다른 탭 닫기, then the tabs, the open one
/// checked.
class WorkspaceTabSwitcher extends StatefulWidget {
  const new({
    super.key,
    required this.tabs,
    required this.activeNoteId,
    required this.onSelected,
    this.onHideTabBar,
    this.onCloseOthers,
  });

  final List<WorkspaceDocumentTab> tabs;
  final String? activeNoteId;
  final ValueChanged<String>? onSelected;

  /// "탭 줄 숨기기" at the top of the list.
  final VoidCallback? onHideTabBar;

  /// "다른 탭 닫기" at the top of the list.
  final VoidCallback? onCloseOthers;

  @override
  State<WorkspaceTabSwitcher> createState() => _WorkspaceTabSwitcherState();
}

class _WorkspaceTabSwitcherState extends State<WorkspaceTabSwitcher> {
  final _anchor = GlobalKey();

  Future<void> _open() => showKitMenu(
    context: context,
    anchor: _anchor,
    within: Navigator.of(context).context.findRenderObject() as RenderBox?,
    builder: _menu,
  );

  /// A row closes the window and then runs, as the editor's ⋯ rows do.
  void _then(VoidCallback then) => closeMenuThen(context, then);

  KitMenu _menu() {
    final hide = widget.onHideTabBar;
    final closeOthers = widget.onCloseOthers;
    return KitMenu(
      width: KitTokens.tabMenuWidth,
      window: true,
      groups: [
        if (hide != null || closeOthers != null)
          KitMenuGroup(
            rows: [
              if (hide != null)
                KitMenuRow.action(
                  key: const ValueKey('workspace-tab-bar-hide'),
                  icon: KitIconName.noteTab,
                  label: '탭 줄 숨기기',
                  onTap: () => _then(hide),
                ),
              if (closeOthers != null)
                KitMenuRow.action(
                  key: const ValueKey('workspace-tab-close-others'),
                  icon: KitIconName.close,
                  label: '다른 탭 닫기',
                  enabled: widget.tabs.length > 1,
                  onTap: () => _then(closeOthers),
                ),
            ],
          ),
        KitMenuGroup(
          rows: [
            for (final tab in widget.tabs)
              KitMenuRow.action(
                key: ValueKey('workspace-tab-switcher-item-${tab.noteId}'),
                label: tab.title,
                checked: tab.noteId == widget.activeNoteId,
                onTap: () => _then(() {
                  if (tab.noteId != widget.activeNoteId) {
                    widget.onSelected?.call(tab.noteId);
                  }
                }),
              ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final tabs = widget.tabs;
    if (tabs.isEmpty) return const SizedBox.shrink();
    final enabled = widget.onSelected != null;
    final label = '열린 문서 ${tabs.length}개';
    return Semantics(
      key: const ValueKey('workspace-tab-switcher'),
      button: true,
      enabled: enabled,
      label: label,
      onTap: enabled ? () => unawaited(_open()) : null,
      excludeSemantics: true,
      child: Tooltip(
        message: label,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            InkWell(
              onTap: enabled ? () => unawaited(_open()) : null,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 52, minHeight: 44),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Opacity(
                    opacity: enabled ? 1 : KitTokens.disabledOpacity,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          '${tabs.length}',
                          style: Theme.of(context).textTheme.labelLarge
                              ?.copyWith(color: KitTokens.toolbarOnBar),
                        ),
                        const SizedBox(width: 2),
                        const KitIcon(
                          KitIconName.chev,
                          size: KitTokens.tabIconSize,
                          strokeWidth: KitTokens.tabIconStroke,
                          color: KitTokens.toolbarOnBar,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            // the window 4 under it; a wide window keeps the screen's edge
            Positioned(
              right: 0,
              bottom: -KitTokens.tabMenuGap,
              width: 0,
              height: 0,
              child: SizedBox(key: _anchor),
            ),
          ],
        ),
      ),
    );
  }
}
