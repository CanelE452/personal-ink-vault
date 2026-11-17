import 'package:flutter/material.dart';

/// StarNote's "기타 설정" side panel (popup_note_document_more_settings): its
/// header, then the sections the workspace and the editor provide.
class OtherSettingsPanel extends StatelessWidget {
  const new({super.key, required this.sections});

  final List<Widget> sections;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Column(
      key: const ValueKey('other-settings-panel'),
      children: [
        SizedBox(
          height: 44,
          child: Row(
            children: [
              const SizedBox(width: 48),
              Expanded(
                child: Text(
                  '기타 설정',
                  textAlign: TextAlign.center,
                  style: TextTheme.of(context).titleMedium,
                ),
              ),
              IconButton(
                key: const ValueKey('other-settings-close'),
                tooltip: '닫기',
                // Not a pop: the workspace's PopScope would take it for
                // leaving the note.
                onPressed: () => Scaffold.of(context).closeEndDrawer(),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
            children: sections,
          ),
        ),
      ],
    ),
  );
}

/// A titled part of the panel, such as "페이지 설정" or "일반 설정".
class OtherSettingsSection extends StatelessWidget {
  const new({
    super.key,
    required this.title,
    this.trailing,
    required this.children,
  });

  final String title;

  /// Shown after the title, such as the current page of "페이지 설정".
  final String? trailing;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final text = TextTheme.of(context);
    final muted = text.labelMedium?.copyWith(
      color: ColorScheme.of(context).onSurfaceVariant,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 16, bottom: 4),
          child: Row(
            children: [
              Expanded(child: Text(title, style: muted)),
              if (trailing case final trailing?) Text(trailing, style: muted),
            ],
          ),
        ),
        ...children,
        const Divider(height: 16),
      ],
    );
  }
}

/// A row that opens something else: its name and a chevron.
class OtherSettingsNavRow extends StatelessWidget {
  const new({super.key, required this.label, required this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    child: SizedBox(
      height: 48,
      child: Row(
        children: [
          Expanded(
            child: Text(label, style: TextTheme.of(context).bodyLarge),
          ),
          const Icon(Icons.chevron_right),
        ],
      ),
    ),
  );
}

/// "도구 모음" with StarNote's four places for the toolbar.
class ToolbarPositionRow extends StatelessWidget {
  const new({super.key, required this.alignment, required this.onChanged});

  final AxisDirection alignment;
  final ValueChanged<AxisDirection> onChanged;

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.of(context);
    return SizedBox(
      key: const ValueKey('toolbar-position'),
      height: 48,
      child: Row(
        children: [
          Expanded(
            child: Text('도구 모음', style: TextTheme.of(context).bodyLarge),
          ),
          for (final (direction, icon, name, label) in const [
            (AxisDirection.up, Icons.vertical_align_top, 'up', '위'),
            (AxisDirection.left, Icons.align_horizontal_left, 'left', '왼쪽'),
            (AxisDirection.right, Icons.align_horizontal_right, 'right', '오른쪽'),
            (AxisDirection.down, Icons.vertical_align_bottom, 'down', '아래'),
          ])
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: IconButton(
                key: ValueKey('toolbar-position-$name'),
                tooltip: '도구 모음 $label',
                onPressed: () => onChanged(direction),
                icon: Icon(icon, size: 20),
                style: IconButton.styleFrom(
                  fixedSize: const Size.square(36),
                  minimumSize: const Size.square(36),
                  padding: EdgeInsets.zero,
                  side: BorderSide(
                    color: direction == alignment
                        ? colorScheme.primary
                        : colorScheme.outlineVariant,
                    width: direction == alignment ? 1.5 : 1,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
