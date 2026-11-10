import 'package:flutter/material.dart';
import 'package:saber/data/vault/workspace_navigation.dart';

class WorkspaceTabSwitcher extends StatelessWidget {
  const new({
    super.key,
    required this.tabs,
    required this.activeNoteId,
    required this.onSelected,
  });

  final List<WorkspaceDocumentTab> tabs;
  final String? activeNoteId;
  final ValueChanged<String>? onSelected;

  @override
  Widget build(BuildContext context) {
    if (tabs.isEmpty) return const SizedBox.shrink();
    return Semantics(
      button: true,
      child: PopupMenuButton<String>(
        key: const ValueKey('workspace-tab-switcher'),
        tooltip: '열린 문서 ${tabs.length}개',
        enabled: onSelected != null,
        initialValue: activeNoteId,
        position: PopupMenuPosition.under,
        borderRadius: BorderRadius.circular(8),
        onSelected: (id) {
          if (id != activeNoteId) onSelected?.call(id);
        },
        itemBuilder: (context) => [
          for (final tab in tabs)
            CheckedPopupMenuItem<String>(
              key: ValueKey('workspace-tab-switcher-item-${tab.noteId}'),
              value: tab.noteId,
              checked: tab.noteId == activeNoteId,
              child: Text(
                tab.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
        child: ExcludeSemantics(
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 52, minHeight: 44),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    '${tabs.length}',
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  const SizedBox(width: 2),
                  const Icon(Icons.expand_more, size: 18),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
