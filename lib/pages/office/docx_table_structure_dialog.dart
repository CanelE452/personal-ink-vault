import 'package:flutter/material.dart';
import 'package:saber/data/office/docx_table_structure.dart';

typedef DocxTableStructureDraft = ({
  int tableIndex,
  DocxTableStructureAction action,
  int index,
  int? anchorIndex,
});

Future<DocxTableStructureDraft?> chooseDocxTableStructure(
  BuildContext context,
  DocxTableStructurePlan plan,
) => showDialog<DocxTableStructureDraft>(
  context: context,
  builder: (context) => _DocxTableStructureDialog(plan),
);

class _DocxTableStructureDialog extends StatefulWidget {
  const new(this.plan);

  final DocxTableStructurePlan plan;

  @override
  State<_DocxTableStructureDialog> createState() =>
      _DocxTableStructureDialogState();
}

class _DocxTableStructureDialogState extends State<_DocxTableStructureDialog> {
  late DocxTableStructureTable? _table = widget.plan.tables.singleOrNull;
  DocxTableStructureAction? _action;
  int? _anchor;
  var _after = false;

  DocxTableStructureDraft? get _draft {
    final table = _table;
    final action = _action;
    final anchor = _anchor;
    if (table == null || action == null || anchor == null) return null;
    final index = anchor + (_after && !action.isDelete ? 1 : 0);
    final anchorIndex = action.isDelete ? null : anchor;
    if (!table.allowsPosition(action, index, anchorIndex: anchorIndex)) {
      return null;
    }
    return (
      tableIndex: table.tableIndex,
      action: action,
      index: index,
      anchorIndex: anchorIndex,
    );
  }

  Future<void> _submit(DocxTableStructureDraft draft) async {
    if (draft.action.isDelete) {
      final axis = draft.action.isRow ? '행' : '열';
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('${draft.index + 1}$axis을 삭제할까요?'),
          content: const Text('선택한 행 또는 열과 그 안의 셀 내용이 삭제됩니다.'),
          actions: [
            TextButton(
              key: const ValueKey('docx-table-structure-delete-cancel'),
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('삭제 취소'),
            ),
            FilledButton(
              key: const ValueKey('docx-table-structure-delete-confirm'),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('삭제하고 저장'),
            ),
          ],
        ),
      );
      if (!mounted || confirmed != true) return;
    }
    Navigator.of(context).pop(draft);
  }

  Widget _picker<T>({
    required String name,
    required String label,
    required T? value,
    required List<DropdownMenuItem<T>> items,
    required ValueChanged<T?> select,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: InputDecorator(
      decoration: InputDecoration(labelText: label),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          key: ValueKey('docx-table-structure-$name'),
          isExpanded: true,
          isDense: true,
          value: value,
          hint: Text('$label 선택'),
          items: items,
          onChanged: select,
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final table = _table;
    final action = _action;
    final draft = _draft;
    final axis = action?.isRow == true ? '행' : '열';
    return AlertDialog(
      title: const Text('DOCX 표 행·열 편집'),
      scrollable: true,
      content: SizedBox(
        width: 420,
        child: widget.plan.tables.isEmpty
            ? const Text(
                '행·열을 편집할 수 있는 표가 없습니다. 셀이 병합되었거나 다른 표 안에 있는 표는 지원하지 않습니다.',
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(bottom: 12),
                    child: Text('행·열 편집을 지원하는 표만 표시합니다.'),
                  ),
                  _picker<DocxTableStructureTable>(
                    name: 'table',
                    label: '표',
                    value: table,
                    items: [
                      for (final item in widget.plan.tables)
                        DropdownMenuItem(
                          value: item,
                          child: Text(
                            '표 ${item.tableIndex + 1} · ${item.rowCount}행×${item.columnCount}열'
                            '${item.preview.isEmpty ? '' : ' · ${item.preview}'}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    select: (value) => setState(() {
                      _table = value;
                      _action = null;
                      _anchor = null;
                      _after = false;
                    }),
                  ),
                  if (table != null)
                    _picker<DocxTableStructureAction>(
                      name: 'action',
                      label: '작업',
                      value: action,
                      items: [
                        for (final option in DocxTableStructureAction.values)
                          DropdownMenuItem(
                            value: option,
                            enabled: table.allows(option),
                            child: Text(switch (option) {
                              DocxTableStructureAction.insertRow => '행 추가',
                              DocxTableStructureAction.deleteRow => '행 삭제',
                              DocxTableStructureAction.insertColumn => '열 추가',
                              DocxTableStructureAction.deleteColumn => '열 삭제',
                            }),
                          ),
                      ],
                      select: (value) => setState(() {
                        _action = value;
                        _anchor = null;
                        _after = false;
                      }),
                    ),
                  if (table != null && action != null) ...[
                    _picker<int>(
                      name: 'position',
                      label: '$axis 위치',
                      value: _anchor,
                      items: [
                        for (
                          var index = 0;
                          index < table.countFor(action);
                          index++
                        )
                          DropdownMenuItem(
                            value: index,
                            child: Text('${index + 1}$axis'),
                          ),
                      ],
                      select: (value) => setState(() => _anchor = value),
                    ),
                    if (!action.isDelete)
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          ChoiceChip(
                            key: const ValueKey('docx-table-structure-before'),
                            label: Text('선택한 $axis 앞'),
                            selected: !_after,
                            onSelected: (_) => setState(() => _after = false),
                          ),
                          ChoiceChip(
                            key: const ValueKey('docx-table-structure-after'),
                            label: Text('선택한 $axis 뒤'),
                            selected: _after,
                            onSelected: (_) => setState(() => _after = true),
                          ),
                        ],
                      ),
                  ],
                ],
              ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('docx-table-structure-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        FilledButton(
          key: const ValueKey('docx-table-structure-confirm'),
          onPressed: draft == null ? null : () => _submit(draft),
          child: Text(action?.isDelete == true ? '삭제 계속' : '추가하고 저장'),
        ),
      ],
    );
  }
}
