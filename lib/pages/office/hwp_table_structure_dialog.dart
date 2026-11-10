import 'package:flutter/material.dart';
import 'package:saber/data/office/windows_office_engine.dart';

typedef HwpTableStructureChoice = ({HwpTableStructureAction action, int index});

String hwpTableStructureTitle(WindowsOfficeHwpTableStructure structure) =>
    structure.canInsertColumn || structure.canDeleteColumn
        ? '표 행·열 편집'
        : '표 행 편집';

String hwpTableStructureLabel(HwpTableStructureAction action) =>
    switch (action) {
      HwpTableStructureAction.insertRow => '행 추가',
      HwpTableStructureAction.deleteRow => '행 삭제',
      HwpTableStructureAction.insertColumn => '열 추가',
      HwpTableStructureAction.deleteColumn => '열 삭제',
    };

String hwpTableStructurePosition(
  HwpTableStructureAction action,
  int index,
  WindowsOfficeHwpTableStructure structure,
) {
  final axis = action.isRow ? '행' : '열';
  final count = action.isRow ? structure.rows : structure.columns;
  if (action.isDelete) return '${index + 1}$axis';
  return index == count ? '$count$axis 뒤' : '${index + 1}$axis 앞';
}

Future<HwpTableStructureChoice?> chooseHwpTableStructure(
  BuildContext context,
  WindowsOfficeHwpTableStructure structure,
) => showDialog<HwpTableStructureChoice>(
  context: context,
  builder: (_) => _HwpTableStructureDialog(structure),
);

class _HwpTableStructureDialog extends StatefulWidget {
  const new(this.structure);

  final WindowsOfficeHwpTableStructure structure;

  @override
  State<_HwpTableStructureDialog> createState() =>
      _HwpTableStructureDialogState();
}

class _HwpTableStructureDialogState extends State<_HwpTableStructureDialog> {
  HwpTableStructureAction? _action;
  int? _index;

  Future<void> _confirm() async {
    final choice = (action: _action!, index: _index!);
    if (choice.action.isDelete) {
      final position = hwpTableStructurePosition(
        choice.action,
        choice.index,
        widget.structure,
      );
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('$position을 삭제할까요?'),
          content: const Text('선택한 범위와 그 안의 셀 내용이 삭제됩니다.'),
          actions: [
            TextButton(
              key: const ValueKey('office-hwpx-structure-delete-cancel'),
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('취소'),
            ),
            FilledButton(
              key: const ValueKey('office-hwpx-structure-delete-confirm'),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('삭제 선택'),
            ),
          ],
        ),
      );
      if (!mounted || confirmed != true) return;
    }
    Navigator.of(context).pop(choice);
  }

  @override
  Widget build(BuildContext context) {
    final structure = widget.structure;
    final action = _action;
    final count = action?.isRow == true ? structure.rows : structure.columns;
    return AlertDialog(
      title: Text(hwpTableStructureTitle(structure)),
      scrollable: true,
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<HwpTableStructureAction>(
              key: const ValueKey('office-hwpx-structure-action'),
              decoration: const InputDecoration(labelText: '작업'),
              isExpanded: true,
              items: [
                for (final option in HwpTableStructureAction.values)
                  DropdownMenuItem(
                    value: option,
                    enabled: structure.allows(option),
                    child: Text(hwpTableStructureLabel(option)),
                  ),
              ],
              onChanged: (value) => setState(() {
                _action = value;
                _index = null;
              }),
            ),
            const SizedBox(height: 12),
            InputDecorator(
              decoration: const InputDecoration(labelText: '위치'),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<int>(
                  key: const ValueKey('office-hwpx-structure-position'),
                  isExpanded: true,
                  isDense: true,
                  value: _index,
                  hint: const Text('위치 선택'),
                  items: [
                    if (action != null)
                      for (
                        var i = 0;
                        i < count + (action.isDelete ? 0 : 1);
                        i++
                      )
                        DropdownMenuItem(
                          value: i,
                          child: Text(
                            hwpTableStructurePosition(action, i, structure),
                          ),
                        ),
                  ],
                  onChanged: action == null
                      ? null
                      : (value) => setState(() => _index = value),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('office-hwpx-structure-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        FilledButton(
          key: const ValueKey('office-hwpx-structure-confirm'),
          onPressed: action == null || _index == null ? null : _confirm,
          child: const Text('작업 선택'),
        ),
      ],
    );
  }
}
