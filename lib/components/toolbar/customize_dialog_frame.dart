import 'package:flutter/material.dart';

/// The frame StarNote's customise dialogs share: "닫기", the title and "완료"
/// on top, a hint, then the lists (528 × 460 in StarNote).
class CustomizeDialogFrame extends StatelessWidget {
  const new({
    super.key,
    required this.title,
    required this.hint,
    required this.closeKey,
    required this.applyKey,
    required this.onApply,
    required this.children,
  });

  final String title;
  final String hint;
  final Key closeKey;
  final Key applyKey;
  final VoidCallback onApply;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final text = TextTheme.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 528, maxHeight: 560),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
            child: Row(
              children: [
                TextButton(
                  key: closeKey,
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('닫기'),
                ),
                Expanded(
                  child: Text(
                    title,
                    textAlign: TextAlign.center,
                    style: text.titleMedium,
                  ),
                ),
                TextButton(
                  key: applyKey,
                  onPressed: onApply,
                  child: const Text('완료'),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(hint, style: text.bodySmall),
                  ...children,
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A list's heading inside a customise dialog.
class CustomizeListTitle extends StatelessWidget {
  const new(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 16, bottom: 6),
    child: Text(text, style: TextTheme.of(context).labelLarge),
  );
}

/// One row of a customise dialog's list: the eye that shows or hides it, its
/// icon and name, and a drag handle when it can be moved.
class CustomizeRow extends StatelessWidget {
  const new({
    super.key,
    required this.icon,
    required this.label,
    this.eyeKey,
    this.shown = true,
    this.onEye,
    this.dragIndex,
  });

  final Widget icon;
  final String label;
  final Key? eyeKey;
  final bool shown;

  /// Null for a row that cannot be hidden.
  final VoidCallback? onEye;

  /// The row's index in its reorderable list, or null when it stays put.
  final int? dragIndex;

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.of(context);
    final dragIndex = this.dragIndex;
    return Container(
      height: 48,
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colorScheme.outlineVariant, width: 0.5)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 44,
            child: onEye == null
                ? null
                : IconButton(
                    key: eyeKey,
                    tooltip: shown ? '숨기기' : '보이기',
                    onPressed: onEye,
                    icon: Icon(
                      shown ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                      size: 22,
                    ),
                  ),
          ),
          SizedBox(width: 32, child: Center(child: icon)),
          const SizedBox(width: 8),
          Expanded(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis)),
          if (dragIndex != null)
            ReorderableDragStartListener(
              index: dragIndex,
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 12),
                child: Icon(Icons.drag_handle),
              ),
            ),
        ],
      ),
    );
  }
}
