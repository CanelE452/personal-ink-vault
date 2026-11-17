import 'package:flutter/material.dart';
import 'package:saber/components/toolbar/shortcut_layout.dart';
import 'package:saber/components/toolbar/toolbar_custom_dialog.dart';
import 'package:stow_plain/stow_plain.dart';

/// StarNote's "사용자 지정 바로가기 막대" (popup_shortcut_bar_custom): the bar's
/// left and right shortcuts in one list split by their titles, the two fixed
/// ones at its end, then "더 많은 기능". At most [maxBarShortcuts] sit on the
/// bar. Changes are saved by "완료"; "닫기" drops them.
Future<void> showShortcutBarEditor(
  BuildContext context, {
  required PlainStow<List<String>> layout,
  List<String> legacyToolbar = const [],
}) => showDialog<void>(
  context: context,
  builder: (_) =>
      _ShortcutBarEditor(layout: layout, legacyToolbar: legacyToolbar),
);

/// The shortcuts StarNote keeps at the bar's end, outside the limit: they
/// need the note editor, so the editor provides them.
const fixedShortcuts = <(String, String, IconData)>[
  ('overview', '문서 개요', Icons.grid_view),
  ('otherSettings', '기타 설정', Icons.tune),
];

class _ShortcutBarEditor extends StatefulWidget {
  const new({required this.layout, required this.legacyToolbar});

  final PlainStow<List<String>> layout;
  final List<String> legacyToolbar;

  @override
  State<_ShortcutBarEditor> createState() => _ShortcutBarEditorState();
}

class _ShortcutBarEditorState extends State<_ShortcutBarEditor> {
  late var _layout = ShortcutLayout.decode(
    noteShortcutItems,
    widget.layout.value,
    legacyToolbar: widget.legacyToolbar,
  );
  var _limitHit = false;

  static const _leftTitle = '#left';
  static const _rightTitle = '#right';

  ShortcutItem _item(String id) =>
      noteShortcutItems.firstWhere((item) => item.id == id);

  ShortcutLayout _rebuilt(List<String> left, List<String> right, List<String> more) =>
      ShortcutLayout.decode(noteShortcutItems, [
        for (final id in left) 'L:$id',
        for (final id in right) 'R:$id',
        for (final id in more) '!$id',
      ]);

  /// [to] is the index after the move. A shortcut never goes above the left
  /// title or below the right part; where it lands relative to the right
  /// title decides its side.
  void _reorder(int from, int to) {
    final flat = [_leftTitle, ..._layout.left, _rightTitle, ..._layout.right];
    final moving = flat.removeAt(from);
    flat.insert(to.clamp(1, flat.length), moving);
    final split = flat.indexOf(_rightTitle);
    setState(() {
      _layout = _rebuilt(
        flat.sublist(1, split),
        flat.sublist(split + 1),
        _layout.more,
      );
    });
  }

  void _show(String id) => setState(() {
    if (_layout.barCount >= maxBarShortcuts) {
      _limitHit = true;
      return;
    }
    _limitHit = false;
    _layout = _layout.placed(id, .left);
  });

  void _hide(String id) => setState(() {
    _limitHit = false;
    _layout = _layout.placed(id, .more);
  });

  @override
  Widget build(BuildContext context) {
    final text = TextTheme.of(context);
    final colorScheme = ColorScheme.of(context);
    var index = 0;
    Widget barRow(String id) {
      final item = _item(id);
      return CustomizeRow(
        key: ValueKey('shortcut-editor-row-$id'),
        icon: Icon(item.icon),
        label: item.label,
        eyeKey: ValueKey('shortcut-editor-eye-$id'),
        onEye: () => _hide(id),
        dragIndex: index++,
      );
    }

    Widget title(String key, String label) {
      index++;
      return Container(
        key: ValueKey(key),
        height: 32,
        alignment: AlignmentDirectional.centerStart,
        child: Text(label, style: text.labelMedium),
      );
    }

    return Dialog(
      key: const ValueKey('shortcut-editor-dialog'),
      child: CustomizeDialogFrame(
        title: '사용자 지정 바로가기 막대',
        hint:
            "'문서 개요'와 '기타 설정' 외에 최대 10개의 바로가기를 추가해 바로가기 막대를 사용자 지정할 수 있습니다",
        closeKey: const ValueKey('shortcut-editor-close'),
        applyKey: const ValueKey('shortcut-editor-apply'),
        onApply: () {
          widget.layout.value = _layout.encode();
          Navigator.of(context).pop();
        },
        children: [
          const CustomizeListTitle('바로가기 막대'),
          ReorderableListView(
            key: const ValueKey('shortcut-editor-bar-list'),
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            onReorderItem: _reorder,
            children: [
              title('shortcut-editor-left-title', '바로가기 막대 왼쪽'),
              for (final id in _layout.left) barRow(id),
              title('shortcut-editor-right-title', '바로가기 막대 오른쪽'),
              for (final id in _layout.right) barRow(id),
              for (final (id, label, icon) in fixedShortcuts)
                CustomizeRow(
                  key: ValueKey('shortcut-editor-fixed-$id'),
                  icon: Icon(icon),
                  label: label,
                ),
            ],
          ),
          const CustomizeListTitle('더 많은 기능'),
          Row(
            children: [
              Text('클릭 ', style: text.bodySmall),
              Icon(
                Icons.visibility_off_outlined,
                size: 16,
                color: colorScheme.onSurfaceVariant,
              ),
              Text(' 도구 모음에 도구 표시', style: text.bodySmall),
            ],
          ),
          if (_limitHit)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                '바로가기 수가 한도에 도달했습니다',
                key: const ValueKey('shortcut-editor-limit'),
                style: text.bodySmall?.copyWith(color: colorScheme.error),
              ),
            ),
          Column(
            key: const ValueKey('shortcut-editor-more-list'),
            children: [
              for (final id in _layout.more)
                CustomizeRow(
                  key: ValueKey('shortcut-editor-more-$id'),
                  icon: Icon(_item(id).icon),
                  label: _item(id).label,
                  shown: false,
                  eyeKey: ValueKey('shortcut-editor-eye-$id'),
                  onEye: () => _show(id),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Center(
            child: TextButton(
              key: const ValueKey('shortcut-editor-reset'),
              // The defaults, not the 228 toolbar's switches.
              onPressed: () => setState(() {
                _limitHit = false;
                _layout = ShortcutLayout.decode(noteShortcutItems, const []);
              }),
              child: Text(
                '기본 설정 복원',
                style: TextStyle(color: colorScheme.error),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
