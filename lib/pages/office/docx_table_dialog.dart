import 'package:flutter/material.dart';
import 'package:saber/data/office/docx_table_insert.dart';
import 'package:saber/data/office/hwp_office_engine.dart';

Future<({int? afterParagraphIndex, List<List<String>> cells})?> chooseDocxTable(
  BuildContext context,
  DocxTableInsertPlan plan,
) => showDialog(
  context: context,
  builder: (context) => _TableInsertDialog(plan),
);

Future<List<List<String>>?> chooseHwpTable(BuildContext context) async {
  final result =
      await showDialog<({int? afterParagraphIndex, List<List<String>> cells})>(
        context: context,
        builder: (context) => const _TableInsertDialog(null),
      );
  return result?.cells;
}

class _TableInsertDialog extends StatefulWidget {
  const new(this.plan);

  final DocxTableInsertPlan? plan;

  @override
  State<_TableInsertDialog> createState() => _TableInsertDialogState();
}

class _TableInsertDialogState extends State<_TableInsertDialog> {
  static const _documentStart = -1;
  var _location = _documentStart;
  var _rows = 2;
  var _columns = 2;
  var _selectedRow = 0;
  final _draft = <(int, int), String>{};

  List<List<String>> get _cells => [
    for (var row = 0; row < _rows; row++)
      [for (var col = 0; col < _columns; col++) _draft[(row, col)] ?? ''],
  ];

  bool get _hwpx => widget.plan == null;
  String get _keyPrefix => _hwpx ? 'office-hwpx-table' : 'docx-table';

  bool _valid(List<List<String>> cells) => _hwpx
      ? HwpOfficeEngine.isValidTableInsertCells(cells, _rows, _columns)
      : cells.every((row) => row.every(DocxTableInsertEngine.validCellText));

  void _save() {
    final cells = _cells;
    if (!_valid(cells)) return;
    Navigator.of(context).pop((
      afterParagraphIndex: _location == _documentStart ? null : _location,
      cells: cells,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final invalid = !_valid(_cells);
    final selectedRow = _selectedRow;
    final maxRows = _hwpx
        ? HwpOfficeEngine.maxTableInsertRows
        : DocxTableInsertEngine.maxRows;
    final maxColumns = _hwpx
        ? HwpOfficeEngine.maxTableInsertColumns
        : DocxTableInsertEngine.maxColumns;
    final maxCellLength = _hwpx
        ? HwpOfficeEngine.maxTableCellLength
        : DocxTableInsertEngine.maxCellLength;
    return AlertDialog(
      title: Text(_hwpx ? 'HWPX 표 추가' : 'DOCX 표 추가'),
      scrollable: true,
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.plan case final plan?) ...[
              DropdownButtonFormField<int>(
                key: const ValueKey('docx-table-location'),
                initialValue: _location,
                decoration: const InputDecoration(labelText: '표 위치'),
                isExpanded: true,
                items: [
                  const DropdownMenuItem(
                    value: _documentStart,
                    child: Text('문서 맨 앞'),
                  ),
                  for (final paragraph in plan.paragraphs)
                    DropdownMenuItem(
                      value: paragraph.index,
                      child: Text(
                        paragraph.text.trim().isEmpty
                            ? '${paragraph.index + 1}번 문단 뒤'
                            : '${paragraph.index + 1}번 문단 뒤 · ${paragraph.text}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (value) {
                  if (value != null) setState(() => _location = value);
                },
              ),
              const SizedBox(height: 8),
            ],
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<int>(
                    key: ValueKey('$_keyPrefix-rows'),
                    initialValue: _rows,
                    decoration: const InputDecoration(labelText: '행'),
                    items: [
                      for (var count = 1; count <= maxRows; count++)
                        DropdownMenuItem(value: count, child: Text('$count')),
                    ],
                    onChanged: (value) {
                      if (value == null) return;
                      setState(() {
                        _rows = value;
                        if (_selectedRow >= value) _selectedRow = value - 1;
                      });
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButtonFormField<int>(
                    key: ValueKey('$_keyPrefix-columns'),
                    initialValue: _columns,
                    decoration: const InputDecoration(labelText: '열'),
                    items: [
                      for (var count = 1; count <= maxColumns; count++)
                        DropdownMenuItem(value: count, child: Text('$count')),
                    ],
                    onChanged: (value) {
                      if (value != null) setState(() => _columns = value);
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Text('셀 내용 (선택)'),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              children: [
                for (var row = 0; row < _rows; row++)
                  ChoiceChip(
                    key: ValueKey('$_keyPrefix-row-${row + 1}'),
                    label: Text('${row + 1}행'),
                    selected: selectedRow == row,
                    onSelected: (_) => setState(() => _selectedRow = row),
                  ),
              ],
            ),
            for (var col = 0; col < _columns; col++)
              TextFormField(
                key: ValueKey('$_keyPrefix-cell-${selectedRow + 1}-${col + 1}'),
                initialValue: _draft[(selectedRow, col)] ?? '',
                decoration: InputDecoration(
                  labelText: '${selectedRow + 1}행 ${col + 1}열',
                ),
                onChanged: (value) => setState(() {
                  _draft[(selectedRow, col)] = value;
                }),
              ),
            if (invalid)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '각 셀은 한 줄에 최대 $maxCellLength자까지 입력할 수 있습니다.',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        FilledButton(
          key: ValueKey('$_keyPrefix-${_hwpx ? 'confirm' : 'apply'}'),
          onPressed: invalid ? null : _save,
          child: Text(_hwpx ? '추가 준비' : '추가하고 저장'),
        ),
      ],
    );
  }
}
