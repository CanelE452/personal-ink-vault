import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:saber/components/theming/adaptive_icon.dart';
import 'package:saber/i18n/strings.g.dart';

class SelectionBar extends StatelessWidget {
  final VoidCallback duplicateSelection;
  final VoidCallback deleteSelection;

  /// 「링크」: a link over the selected strokes and pictures.
  final VoidCallback? linkSelection;

  const new({
    super.key,
    required this.duplicateSelection,
    required this.deleteSelection,
    this.linkSelection,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: .center,
      children: [
        IconButton(
          onPressed: duplicateSelection,
          style: TextButton.styleFrom(
            foregroundColor: ColorScheme.of(context).secondary,
            backgroundColor: Colors.transparent,
            shape: const CircleBorder(),
          ),
          tooltip: t.editor.selectionBar.duplicate,
          icon: const AdaptiveIcon(
            icon: Icons.content_copy,
            cupertinoIcon: CupertinoIcons.doc_on_clipboard,
          ),
        ),
        IconButton(
          onPressed: deleteSelection,
          style: TextButton.styleFrom(
            foregroundColor: ColorScheme.of(context).secondary,
            backgroundColor: Colors.transparent,
            shape: const CircleBorder(),
          ),
          tooltip: t.editor.selectionBar.delete,
          icon: const AdaptiveIcon(
            icon: Icons.delete,
            cupertinoIcon: CupertinoIcons.delete,
          ),
        ),
        if (linkSelection != null)
          IconButton(
            key: const ValueKey('selection-link'),
            onPressed: linkSelection,
            style: TextButton.styleFrom(
              foregroundColor: ColorScheme.of(context).secondary,
              backgroundColor: Colors.transparent,
              shape: const CircleBorder(),
            ),
            tooltip: '링크',
            icon: const Icon(Icons.link),
          ),
      ],
    );
  }
}
