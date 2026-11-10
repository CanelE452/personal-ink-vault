import 'package:flutter/material.dart';
import 'package:saber/data/office/pptx_shape_text.dart';

typedef PptxTableMergeDraft = ({
  int slideIndex,
  PptxTableMergeTable table,
  PptxTableMergeAction action,
  PptxTableCellRange range,
});

Future<PptxTableMergeDraft?> choosePptxTableMerge(
  BuildContext context,
  PptxShapeTextPlan plan,
  Future<List<PptxTableMergeTable>> Function(int slideIndex) loadSlide,
) => showDialog<PptxTableMergeDraft>(
  context: context,
  builder: (context) => _PptxTableMergeDialog(plan, loadSlide),
);

class _PptxTableMergeDialog extends StatefulWidget {
  const new(this.plan, this.loadSlide);

  final PptxShapeTextPlan plan;
  final Future<List<PptxTableMergeTable>> Function(int slideIndex) loadSlide;

  @override
  State<_PptxTableMergeDialog> createState() => _PptxTableMergeDialogState();
}

class _PptxTableMergeDialogState extends State<_PptxTableMergeDialog> {
  int? _slide;
  Future<List<PptxTableMergeTable>>? _tables;
  PptxTableMergeTable? _table;
  var _action = PptxTableMergeAction.merge;
  var _row = 0, _column = 0, _lastRow = 0, _lastColumn = 0;
  PptxTableCellRange? _merged;

  PptxTableCellRange? get _range => _action == PptxTableMergeAction.unmerge
      ? _merged
      : (
          row: _row,
          column: _column,
          rowSpan: _lastRow - _row + 1,
          columnSpan: _lastColumn - _column + 1,
        );

  void _openSlide(int slide) {
    setState(() {
      _slide = slide;
      _table = null;
      _tables = widget.loadSlide(slide);
    });
  }

  void _selectTable(PptxTableMergeTable table) {
    setState(() {
      _table = table;
      _action = PptxTableMergeAction.merge;
      _row = _column = _lastRow = _lastColumn = 0;
      _merged = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final table = _table;
    final range = _range;
    final canSave = range != null && table?.allows(_action, range) == true;
    return AlertDialog(
      title: const Text('PPTX 표 셀 병합·해제'),
      content: SizedBox(
        width: 440,
        height: 320,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              _picker<int>(
                name: 'slide',
                label: '슬라이드',
                value: _slide,
                choices: [
                  for (final slide in widget.plan.slides)
                    (
                      slide.index,
                      [
                        '슬라이드 ${slide.index + 1}',
                        if (slide.hidden) '숨김',
                        if (slide.title case final title? when title.isNotEmpty)
                          title,
                      ].join(' · '),
                    ),
                ],
                onSelect: _openSlide,
              ),
              if (_slide case final slide?) _tablePicker(slide),
              if (table != null) ..._tableFields(table),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        FilledButton(
          key: const ValueKey('pptx-table-merge-confirm'),
          onPressed: canSave
              ? () => Navigator.of(context).pop((
                  slideIndex: _slide!,
                  table: table!,
                  action: _action,
                  range: range,
                ))
              : null,
          child: Text(
            _action == PptxTableMergeAction.merge ? '병합하고 저장' : '해제하고 저장',
          ),
        ),
      ],
    );
  }

  Widget _tablePicker(int slide) => FutureBuilder(
    future: _tables,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return const LinearProgressIndicator(semanticsLabel: '표 읽는 중');
      }
      if (snapshot.hasError) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('이 슬라이드의 표를 읽지 못했습니다.'),
            TextButton(
              onPressed: () => _openSlide(slide),
              child: const Text('다시 읽기'),
            ),
          ],
        );
      }
      final tables = snapshot.requireData;
      if (tables.isEmpty) return const Text('이 슬라이드에 편집할 표가 없습니다.');
      return _picker<PptxTableMergeTable>(
        name: 'table',
        label: '표',
        value: _table,
        choices: [
          for (final (index, table) in tables.indexed)
            (
              table,
              [
                '표 ${index + 1}',
                if (table.name.trim().isNotEmpty) table.name.trim(),
                '${table.rows}행×${table.columns}열',
              ].join(' · '),
            ),
        ],
        onSelect: _selectTable,
      );
    },
  );

  List<Widget> _tableFields(PptxTableMergeTable table) => [
    _picker<PptxTableMergeAction>(
      name: 'action',
      label: '작업',
      value: _action,
      choices: [
        (PptxTableMergeAction.merge, '셀 병합'),
        if (table.mergedRanges.isNotEmpty)
          (PptxTableMergeAction.unmerge, '병합 해제'),
      ],
      onSelect: (action) => setState(() => _action = action),
    ),
    if (_action == PptxTableMergeAction.merge) ...[
      _number('row', '시작 행', _row, 0, table.rows, (value) {
        _row = value;
        if (_lastRow < _row) _lastRow = _row;
      }),
      _number('column', '시작 열', _column, 0, table.columns, (value) {
        _column = value;
        if (_lastColumn < _column) _lastColumn = _column;
      }),
      _number(
        'last-row',
        '끝 행',
        _lastRow,
        _row,
        table.rows,
        (value) => _lastRow = value,
      ),
      _number(
        'last-column',
        '끝 열',
        _lastColumn,
        _column,
        table.columns,
        (value) => _lastColumn = value,
      ),
      const Text('연속된 셀을 두 개 이상 고르세요. 기존 병합 영역과 겹칠 수 없습니다.'),
      if (_range case final range? when !table.keepsGridBoundaries(range))
        const Text('병합하면 모든 칸이 가려지는 행이나 열이 있습니다. 범위를 줄이세요.'),
      const SizedBox(height: 6),
      const Text('선택한 셀의 글자는 왼쪽 위 셀에 행 순서대로 모입니다.'),
    ] else ...[
      _picker<PptxTableCellRange>(
        name: 'merged-range',
        label: '병합된 영역',
        value: _merged,
        choices: [
          for (final range in table.mergedRanges)
            (
              range,
              '${range.row + 1}행 ${range.column + 1}열 · '
                  '${range.rowSpan}행×${range.columnSpan}열',
            ),
        ],
        onSelect: (range) => setState(() => _merged = range),
      ),
      const Text('셀을 원래 칸으로 나누고 현재 셀의 글자는 그대로 둡니다.'),
    ],
  ];

  Widget _number(
    String name,
    String label,
    int value,
    int start,
    int end,
    ValueChanged<int> select,
  ) => _picker<int>(
    name: name,
    label: label,
    value: value,
    choices: [
      for (var index = start; index < end; index++) (index, '${index + 1}'),
    ],
    onSelect: (value) => setState(() => select(value)),
  );

  Widget _picker<T>({
    required String name,
    required String label,
    required T? value,
    required List<(T, String)> choices,
    required ValueChanged<T> onSelect,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: InputDecorator(
      decoration: InputDecoration(labelText: label),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          key: ValueKey('pptx-table-merge-$name'),
          value: value,
          hint: Text('$label 선택'),
          isDense: true,
          isExpanded: true,
          items: [
            for (final (id, text) in choices)
              DropdownMenuItem(
                value: id,
                child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: (value) {
            if (value != null) onSelect(value);
          },
        ),
      ),
    ),
  );
}
