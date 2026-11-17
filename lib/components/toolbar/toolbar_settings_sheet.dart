import 'package:flutter/material.dart';
import 'package:saber/components/toolbar/toolbar_layout.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/tools/shape_pen.dart';
import 'package:stow_plain/stow_plain.dart';

/// Opens the toolbar settings: where the toolbar sits, the toolbar editor
/// (when [items] and [layout] are given), and for the page editor
/// ([editorOptions]) the two pan locks that used to float over it.
Future<void> showToolbarSettings(
  BuildContext context, {
  required AxisDirection alignment,
  required ValueChanged<AxisDirection> onAlignmentChanged,
  bool editorOptions = false,
  List<ToolbarItem>? items,
  PlainStow<List<String>>? layout,
}) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  builder: (context) => _ToolbarSettings(
    alignment: alignment,
    onAlignmentChanged: onAlignmentChanged,
    editorOptions: editorOptions,
    items: items,
    layout: layout,
  ),
);

/// Opens the toolbar editor: show or hide each item and drag to reorder.
Future<void> showToolbarEditor(
  BuildContext context, {
  required List<ToolbarItem> items,
  required PlainStow<List<String>> layout,
}) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (context) => SizedBox(
    height: MediaQuery.sizeOf(context).height * .75,
    child: _ToolbarEditor(items: items, layout: layout),
  ),
);

class _ToolbarSettings extends StatefulWidget {
  const new({
    required this.alignment,
    required this.onAlignmentChanged,
    required this.editorOptions,
    required this.items,
    required this.layout,
  });

  final AxisDirection alignment;
  final ValueChanged<AxisDirection> onAlignmentChanged;
  final bool editorOptions;
  final List<ToolbarItem>? items;
  final PlainStow<List<String>>? layout;

  @override
  State<_ToolbarSettings> createState() => _ToolbarSettingsState();
}

/// The page editor's writing settings: the zoom and pan locks, the line and
/// finger settings Saber kept on its own page (which the workspace no longer
/// opens), and the shape preview delay. The toolbar settings sheet and the
/// editor's "기타 설정" panel show it.
class ToolbarWritingSettings extends StatelessWidget {
  const new({super.key});

  Widget _switch(
    PlainStow<bool> stow,
    String title,
    String subtitle, {
    Key? key,
  }) => ValueListenableBuilder(
    valueListenable: stow,
    builder: (context, value, _) => SwitchListTile(
      key: key,
      contentPadding: EdgeInsets.zero,
      title: Text(title),
      subtitle: Text(subtitle),
      value: value,
      onChanged: (next) => stow.value = next,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final text = TextTheme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _switch(
          stows.lastZoomLock,
          '확대 잠금',
          '두 손가락으로 확대·축소하지 않습니다.',
          key: const ValueKey('toolbar-zoom-lock'),
        ),
        _switch(
          stows.lastSingleFingerPanLock,
          '한 손가락 이동 잠금',
          '한 손가락으로는 화면이 움직이지 않습니다.',
        ),
        _switch(
          stows.lastAxisAlignedPanLock,
          '가로·세로로만 이동',
          '화면을 비스듬히 움직이지 않습니다.',
        ),
        const SizedBox(height: 12),
        Text('필기', style: text.labelLarge),
        _switch(
          stows.autoStraightenLines,
          '거의 곧은 선을 직선으로',
          '손으로 그은 선이 거의 곧으면 반듯하게 바꿉니다.',
          key: const ValueKey('toolbar-auto-straighten'),
        ),
        _switch(
          stows.autoDisableFingerDrawingWhenStylusDetected,
          '펜이 닿으면 손가락 그리기 끄기',
          '스타일러스를 쓰면 손가락으로는 화면만 움직입니다.',
        ),
        const SizedBox(height: 8),
        Text('도형 미리보기', style: text.bodyMedium),
        const SizedBox(height: 6),
        ValueListenableBuilder(
          valueListenable: stows.shapeRecognitionDelay,
          builder: (context, delay, _) => SegmentedButton<int>(
            key: const ValueKey('toolbar-shape-delay'),
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: 500, label: Text('0.5초')),
              ButtonSegment(value: 1000, label: Text('1초')),
              ButtonSegment(value: -1, label: Text('끄기')),
            ],
            selected: {delay},
            onSelectionChanged: (selection) {
              stows.shapeRecognitionDelay.value = selection.single;
              // The shape pen keeps its own copy (Saber's settings page
              // refreshed it the same way).
              ShapePen.debounceDuration = ShapePen.getDebounceFromPref();
            },
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '도형 펜으로 그리다 멈추면 이 시간 뒤에 반듯한 도형을 미리 보여 줍니다. '
          '꺼도 펜을 떼면 도형으로 바뀝니다.',
          style: text.bodySmall,
        ),
      ],
    );
  }
}

class _ToolbarSettingsState extends State<_ToolbarSettings> {
  late var _alignment = widget.alignment;

  @override
  Widget build(BuildContext context) {
    final text = TextTheme.of(context);
    final items = widget.items;
    final layout = widget.layout;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('툴바 설정', style: text.titleMedium),
            const SizedBox(height: 16),
            Text('툴바 위치', style: text.labelLarge),
            const SizedBox(height: 8),
            SegmentedButton<AxisDirection>(
              key: const ValueKey('toolbar-position'),
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: AxisDirection.up, label: Text('위')),
                ButtonSegment(value: AxisDirection.down, label: Text('아래')),
                ButtonSegment(value: AxisDirection.left, label: Text('왼쪽')),
                ButtonSegment(value: AxisDirection.right, label: Text('오른쪽')),
              ],
              selected: {_alignment},
              onSelectionChanged: (selection) {
                setState(() => _alignment = selection.single);
                widget.onAlignmentChanged(selection.single);
              },
            ),
            const SizedBox(height: 6),
            Text(
              '툴바 끝의 손잡이를 끌어서 옮길 수도 있습니다.',
              style: text.bodySmall,
            ),
            if (items != null && layout != null) ...[
              const SizedBox(height: 8),
              ListTile(
                key: const ValueKey('toolbar-edit'),
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.tune),
                title: const Text('툴바 편집'),
                subtitle: const Text('도구를 고르고 순서를 바꿉니다.'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () =>
                    showToolbarEditor(context, items: items, layout: layout),
              ),
            ],
            if (widget.editorOptions) ...[
              const SizedBox(height: 4),
              const ToolbarWritingSettings(),
            ],
          ],
        ),
      ),
    );
  }
}

class _ToolbarEditor extends StatelessWidget {
  const new({required this.items, required this.layout});

  final List<ToolbarItem> items;
  final PlainStow<List<String>> layout;

  void _save(ToolbarLayout next) => layout.value = next.encode();

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: layout,
    builder: (context, stored, _) {
      final current = ToolbarLayout.decode(items, stored);
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 12, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '툴바 편집',
                    style: TextTheme.of(context).titleMedium,
                  ),
                ),
                TextButton(
                  key: const ValueKey('toolbar-edit-reset'),
                  onPressed: () => layout.value = const [],
                  child: const Text('기본값으로'),
                ),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text('스위치로 보이기를 고르고, 손잡이를 끌어서 순서를 바꿉니다.'),
          ),
          Expanded(
            child: ReorderableListView.builder(
              buildDefaultDragHandles: false,
              itemCount: current.items.length,
              onReorderItem: (from, to) => _save(current.moved(from, to)),
              itemBuilder: (context, index) {
                final item = current.items[index];
                final shown = current.shown.contains(item.id);
                return ListTile(
                  key: ValueKey('toolbar-edit-${item.id}'),
                  leading: ReorderableDragStartListener(
                    index: index,
                    child: const Icon(Icons.drag_handle),
                  ),
                  title: Text(item.label),
                  trailing: Switch(
                    key: ValueKey('toolbar-item-${item.id}'),
                    value: shown,
                    onChanged: (value) =>
                        _save(current.withShown(item.id, value)),
                  ),
                );
              },
            ),
          ),
        ],
      );
    },
  );
}
