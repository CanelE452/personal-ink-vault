import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:saber/components/toolbar/toolbar_layout.dart';
import 'package:saber/data/tools/highlighter.dart';
import 'package:saber/data/tools/pen.dart';
import 'package:saber/data/tools/pencil.dart';
import 'package:stow_plain/stow_plain.dart';

/// StarNote's "사용자 지정 도구 모음" (popup_shape_toolbar_custom): the shown
/// tools in order, the hidden ones below, and "기본 설정 복원". Changes are
/// saved by "완료"; "닫기" drops them.
Future<void> showToolbarCustomDialog(
  BuildContext context, {
  required List<ToolbarItem> items,
  required PlainStow<List<String>> layout,
}) => showDialog<void>(
  context: context,
  builder: (_) => _ToolbarCustomDialog(items: items, layout: layout),
);

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

/// The toolbar's picture for each tool, as the toolbar shows it.
Widget toolbarItemIcon(String id) => switch (id) {
  'pen' => const FaIcon(Pen.fountainPenIcon, size: 18),
  'pencil' => const FaIcon(Pencil.pencilIcon, size: 18),
  'highlighter' => const FaIcon(Highlighter.highlighterIcon, size: 18),
  'eraser' => const FaIcon(FontAwesomeIcons.eraser, size: 18),
  'select' => const Icon(CupertinoIcons.lasso),
  'photo' => const Icon(Icons.photo),
  'text' => const Icon(Icons.text_fields),
  'laser' => const Icon(Symbols.stylus_laser_pointer),
  _ => const Icon(Icons.build_outlined),
};

class _ToolbarCustomDialog extends StatefulWidget {
  const new({required this.items, required this.layout});

  final List<ToolbarItem> items;
  final PlainStow<List<String>> layout;

  @override
  State<_ToolbarCustomDialog> createState() => _ToolbarCustomDialogState();
}

class _ToolbarCustomDialogState extends State<_ToolbarCustomDialog> {
  late var _layout = ToolbarLayout.decode(widget.items, widget.layout.value);

  @override
  Widget build(BuildContext context) {
    final shown = [
      for (final item in _layout.items)
        if (_layout.shown.contains(item.id)) item,
    ];
    final hidden = [
      for (final item in _layout.items)
        if (!_layout.shown.contains(item.id)) item,
    ];
    return Dialog(
      key: const ValueKey('toolbar-custom-dialog'),
      child: CustomizeDialogFrame(
        title: '사용자 지정 도구 모음',
        hint: '개인 선호에 따라 도구 모음 사용자 지정',
        closeKey: const ValueKey('toolbar-custom-close'),
        applyKey: const ValueKey('toolbar-custom-apply'),
        onApply: () {
          widget.layout.value = _layout.encode();
          Navigator.of(context).pop();
        },
        children: [
          const CustomizeListTitle('표시된 도구'),
          ReorderableListView(
            key: const ValueKey('toolbar-custom-shown-list'),
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            // [to] is the index after the move, as onReorderItem reports it;
            // the hidden tools keep their order after the shown ones.
            onReorderItem: (from, to) => setState(() {
              final order = [for (final item in shown) item.id];
              order.insert(to, order.removeAt(from));
              _layout = ToolbarLayout.decode(widget.items, [
                ...order,
                for (final item in hidden) '!${item.id}',
              ]);
            }),
            children: [
              for (final (index, item) in shown.indexed)
                CustomizeRow(
                  key: ValueKey('toolbar-custom-shown-${item.id}'),
                  icon: toolbarItemIcon(item.id),
                  label: item.label,
                  eyeKey: ValueKey('toolbar-custom-eye-${item.id}'),
                  onEye: () => setState(() => _layout = _layout.withShown(item.id, false)),
                  dragIndex: index,
                ),
            ],
          ),
          const CustomizeListTitle('숨겨진 도구'),
          Column(
            key: const ValueKey('toolbar-custom-hidden-list'),
            children: [
              for (final item in hidden)
                CustomizeRow(
                  key: ValueKey('toolbar-custom-hidden-${item.id}'),
                  icon: toolbarItemIcon(item.id),
                  label: item.label,
                  shown: false,
                  eyeKey: ValueKey('toolbar-custom-eye-${item.id}'),
                  onEye: () => setState(() => _layout = _layout.withShown(item.id, true)),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Center(
            child: TextButton(
              key: const ValueKey('toolbar-custom-reset'),
              onPressed: () => setState(
                () => _layout = ToolbarLayout.decode(widget.items, const []),
              ),
              child: Text(
                '기본 설정 복원',
                style: TextStyle(color: ColorScheme.of(context).error),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
