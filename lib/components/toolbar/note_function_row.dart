import 'package:flutter/material.dart';
import 'package:saber/components/toolbar/shortcut_layout.dart';

/// One action of a note's function row. The workspace and the editor each
/// provide the ones that apply to the open document; [ShortcutLayout] places
/// them by [id].
@immutable
class NoteShortcut {
  const new({
    required this.id,
    required this.label,
    required this.icon,
    this.onPressed,
    this.selected = false,
    this.buttonKey,
    this.menuBuilder,
  });

  final String id;

  /// Its tooltip on the bar and its name in "더 많은 기능".
  final String label;
  final Widget icon;

  /// Null turns the shortcut off. A [menuBuilder] shortcut is on when this
  /// is not null, and opens its menu instead of calling it.
  final VoidCallback? onPressed;
  final bool selected;

  /// The key of its button on the bar, or of its item in "더 많은 기능".
  final Key? buttonKey;

  /// For a shortcut that offers choices, such as the export formats.
  final List<PopupMenuEntry<void>> Function(BuildContext)? menuBuilder;
}

/// StarNote's function row (layout_function_tool), under the tab row: back,
/// the shortcut bar's left part and right part (each scrolling on its own),
/// the [fixed] shortcuts at the right end, and ⋯ "더 많은 기능" with the
/// shortcuts the bar does not show and "사용자 지정 바로가기 막대".
class NoteFunctionRow extends StatelessWidget {
  const new({
    super.key,
    this.back,
    this.leading = const [],
    required this.shortcuts,
    this.fixed = const [],
    required this.layout,
    required this.onCustomize,
  });

  final Widget? back;

  /// Placed after [back], for example the button that shows a hidden tab row.
  final List<Widget> leading;
  final List<NoteShortcut> shortcuts;

  /// StarNote's 문서 개요 and 기타 설정: always at the right end.
  final List<NoteShortcut> fixed;
  final ShortcutLayout layout;
  final VoidCallback onCustomize;

  static const height = 44.0;

  @override
  Widget build(BuildContext context) {
    final byId = {for (final shortcut in shortcuts) shortcut.id: shortcut};
    final left = [for (final id in layout.left) ?byId[id]];
    final right = [for (final id in layout.right) ?byId[id]];
    final more = [for (final id in layout.more) ?byId[id]];
    final colorScheme = ColorScheme.of(context);
    Widget part(String key, List<NoteShortcut> items) => SingleChildScrollView(
      key: ValueKey(key),
      scrollDirection: Axis.horizontal,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [for (final item in items) _ShortcutButton(item)],
      ),
    );
    return Material(
      key: const ValueKey('note-function-row'),
      color: colorScheme.surface,
      child: Container(
        height: height,
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: colorScheme.outlineVariant, width: 0.5),
          ),
        ),
        child: Row(
          children: [
            ?back,
            ...leading,
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) => Row(
                  children: [
                    // StarNote gives the left part up to 300 of its bar.
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: constraints.maxWidth * .5,
                      ),
                      child: part('note-function-left', left),
                    ),
                    if (left.isNotEmpty)
                      Container(
                        width: 0.5,
                        height: 20,
                        margin: const EdgeInsets.symmetric(horizontal: 4),
                        color: colorScheme.outlineVariant,
                      ),
                    Expanded(
                      child: Align(
                        alignment: AlignmentDirectional.centerEnd,
                        child: part('note-function-right', right),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // StarNote's fixed pair stays in view on any width.
            for (final item in fixed) _ShortcutButton(item),
            _MoreFunctions(more: more, onCustomize: onCustomize),
          ],
        ),
      ),
    );
  }
}

class _ShortcutButton extends StatelessWidget {
  const new(this.shortcut);

  final NoteShortcut shortcut;

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.of(context);
    final menu = shortcut.menuBuilder;
    if (menu != null) {
      return PopupMenuButton<void>(
        key: shortcut.buttonKey,
        tooltip: shortcut.label,
        enabled: shortcut.onPressed != null,
        icon: shortcut.icon,
        itemBuilder: menu,
      );
    }
    return IconButton(
      key: shortcut.buttonKey,
      tooltip: shortcut.label,
      onPressed: shortcut.onPressed,
      icon: shortcut.icon,
      style: IconButton.styleFrom(
        fixedSize: const Size.square(40),
        minimumSize: const Size.square(40),
        padding: EdgeInsets.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        backgroundColor: shortcut.selected
            ? colorScheme.secondaryContainer
            : null,
      ),
    );
  }
}

/// ⋯ "더 많은 기능" (popup_shortcut_bar_more_functions).
class _MoreFunctions extends StatelessWidget {
  const new({required this.more, required this.onCustomize});

  final List<NoteShortcut> more;
  final VoidCallback onCustomize;

  @override
  Widget build(BuildContext context) => PopupMenuButton<void>(
    key: const ValueKey('workspace-more-actions'),
    tooltip: '더 많은 기능',
    icon: const Icon(Icons.more_horiz),
    position: PopupMenuPosition.under,
    itemBuilder: (_) => [
      for (final shortcut in more)
        PopupMenuItem<void>(
          key: shortcut.buttonKey,
          enabled: shortcut.onPressed != null,
          onTap: shortcut.menuBuilder == null
              ? shortcut.onPressed
              : () => _openMenuAfterClose(context, shortcut),
          child: _MenuRow(icon: shortcut.icon, label: shortcut.label),
        ),
      if (more.isNotEmpty) const PopupMenuDivider(),
      PopupMenuItem<void>(
        key: const ValueKey('shortcut-bar-customize'),
        onTap: onCustomize,
        child: const _MenuRow(
          icon: Icon(Icons.dashboard_customize_outlined),
          label: '사용자 지정 바로가기 막대',
        ),
      ),
    ],
  );

  /// A choice shortcut picked from this menu opens its own menu once this one
  /// has closed, under the ⋯ button.
  void _openMenuAfterClose(BuildContext context, NoteShortcut shortcut) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!context.mounted) return;
      final box = context.findRenderObject() as RenderBox?;
      final overlay =
          Overlay.of(context).context.findRenderObject() as RenderBox?;
      if (box == null || overlay == null) return;
      final position = RelativeRect.fromRect(
        Rect.fromPoints(
          box.localToGlobal(box.size.bottomLeft(Offset.zero), ancestor: overlay),
          box.localToGlobal(box.size.bottomRight(Offset.zero), ancestor: overlay),
        ),
        Offset.zero & overlay.size,
      );
      showMenu<void>(
        context: context,
        position: position,
        items: shortcut.menuBuilder!(context),
      );
    });
  }
}

class _MenuRow extends StatelessWidget {
  const new({required this.icon, required this.label});

  final Widget icon;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      IconTheme.merge(data: const IconThemeData(size: 22), child: icon),
      const SizedBox(width: 12),
      Flexible(child: Text(label)),
    ],
  );
}
