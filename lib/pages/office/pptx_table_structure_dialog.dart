import 'package:flutter/material.dart';
import 'package:saber/data/office/pptx_shape_text.dart';

typedef PptxTableStructureDraft = ({
  int slideIndex,
  PptxTableStructureTable table,
  PptxTableStructureAction action,
  int index,
});

Future<PptxTableStructureDraft?> choosePptxTableStructure(
  BuildContext context,
  PptxShapeTextPlan plan,
  Future<List<PptxTableStructureTable>> Function(int slideIndex) loadSlide,
) => showDialog<PptxTableStructureDraft>(
  context: context,
  builder: (context) => _PptxTableStructureDialog(plan, loadSlide),
);

class _PptxTableStructureDialog extends StatefulWidget {
  const new(this.plan, this.loadSlide);

  final PptxShapeTextPlan plan;
  final Future<List<PptxTableStructureTable>> Function(int slideIndex)
  loadSlide;

  @override
  State<_PptxTableStructureDialog> createState() =>
      _PptxTableStructureDialogState();
}

class _PptxTableStructureDialogState extends State<_PptxTableStructureDialog> {
  int? _slideIndex;
  Future<List<PptxTableStructureTable>>? _tables;
  PptxTableStructureTable? _table;
  PptxTableStructureAction? _action;
  int? _index;

  bool get _canSubmit =>
      _index != null && _table?.allows(_action!, _index!) == true;

  Future<void> _submit() async {
    if (!_canSubmit) return;
    final draft = (
      slideIndex: _slideIndex!,
      table: _table!,
      action: _action!,
      index: _index!,
    );
    if (draft.action.isDelete) {
      final axis = draft.action.isRow ? '행' : '열';
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('${draft.index + 1}$axis을 삭제할까요?'),
          content: const Text('선택한 행 또는 열과 그 안의 셀 내용이 삭제됩니다.'),
          actions: [
            TextButton(
              key: const ValueKey('pptx-table-structure-delete-cancel'),
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('삭제 취소'),
            ),
            FilledButton(
              key: const ValueKey('pptx-table-structure-delete-confirm'),
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

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('PPTX 표 행·열 편집'),
    content: SizedBox(
      width: 420,
      height: 320,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _slidePicker(),
            if (_slideIndex != null) _tablePicker(_slideIndex!),
            if (_table case final table?) ..._operationFields(table),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        key: const ValueKey('pptx-table-structure-cancel'),
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('취소'),
      ),
      FilledButton(
        key: const ValueKey('pptx-table-structure-confirm'),
        onPressed: _canSubmit ? _submit : null,
        child: Text(_action?.isDelete == true ? '삭제 계속' : '추가하고 저장'),
      ),
    ],
  );

  Widget _picker<T>({
    required String name,
    required String label,
    required T? value,
    required List<DropdownMenuItem<T>> items,
    required ValueChanged<T> select,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: InputDecorator(
      decoration: InputDecoration(labelText: label),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          key: ValueKey('pptx-table-structure-$name'),
          value: value,
          hint: Text('$label 선택'),
          isDense: true,
          isExpanded: true,
          items: items,
          onChanged: items.any((item) => item.enabled)
              ? (value) {
                  if (value != null) select(value);
                }
              : null,
        ),
      ),
    ),
  );

  Widget _slidePicker() => _picker<int>(
    name: 'slide',
    label: '슬라이드',
    value: _slideIndex,
    items: [
      for (final slide in widget.plan.slides)
        DropdownMenuItem(
          value: slide.index,
          child: Text(
            [
              '슬라이드 ${slide.index + 1}',
              if (slide.hidden) '숨김',
              if (slide.title case final title? when title.isNotEmpty) title,
            ].join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
    ],
    select: (index) {
      if (_slideIndex == index) return;
      setState(() {
        _slideIndex = index;
        _tables = widget.loadSlide(index);
        _table = null;
        _action = null;
        _index = null;
      });
    },
  );

  Widget _tablePicker(int slide) =>
      FutureBuilder<List<PptxTableStructureTable>>(
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
                  onPressed: () =>
                      setState(() => _tables = widget.loadSlide(slide)),
                  child: const Text('다시 읽기'),
                ),
              ],
            );
          }
          final tables = snapshot.requireData;
          if (tables.isEmpty) return const Text('이 슬라이드에 행·열을 편집할 표가 없습니다.');
          return _picker<PptxTableStructureTable>(
            name: 'table',
            label: '표',
            value: _table,
            items: [
              for (final (index, table) in tables.indexed)
                DropdownMenuItem(
                  value: table,
                  child: Text(
                    [
                      '표 ${index + 1}',
                      if (table.name.trim().isNotEmpty) table.name.trim(),
                      '${table.rows}행×${table.columns}열',
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            select: (table) {
              if (identical(_table, table)) return;
              setState(() {
                _table = table;
                _action = null;
                _index = null;
              });
            },
          );
        },
      );

  List<Widget> _operationFields(PptxTableStructureTable table) {
    final action = _action;
    final positions = action == null ? const <int>[] : table.positions(action);
    final axis = action?.isRow == true ? '행' : '열';
    return [
      _picker<PptxTableStructureAction>(
        name: 'action',
        label: '작업',
        value: action,
        items: [
          for (final option in PptxTableStructureAction.values)
            DropdownMenuItem(
              value: option,
              enabled: table.positions(option).isNotEmpty,
              child: Text(_actionLabel(option)),
            ),
        ],
        select: (option) {
          if (_action == option) return;
          setState(() {
            _action = option;
            _index = null;
          });
        },
      ),
      if (action != null)
        _picker<int>(
          name: 'position',
          label: action.isDelete ? '삭제할 $axis' : '기준 $axis',
          value: _index,
          items: [
            for (final index in positions)
              DropdownMenuItem(value: index, child: Text('${index + 1}$axis')),
          ],
          select: (index) => setState(() => _index = index),
        ),
      if (table.rows == 1 || table.columns == 1)
        const Text('표에는 행과 열을 각각 하나 이상 남겨야 합니다.'),
      if (table.rows == PptxTableStructureEngine.maxDimension ||
          table.columns == PptxTableStructureEngine.maxDimension)
        const Text('최대 256행·256열을 지원합니다.'),
      const Text('병합 셀이나 표 크기에 따라 편집 가능한 위치만 표시합니다.'),
    ];
  }

  String _actionLabel(PptxTableStructureAction action) => switch (action) {
    PptxTableStructureAction.insertRowBefore => '위에 행 추가',
    PptxTableStructureAction.insertRowAfter => '아래에 행 추가',
    PptxTableStructureAction.insertColumnBefore => '왼쪽에 열 추가',
    PptxTableStructureAction.insertColumnAfter => '오른쪽에 열 추가',
    PptxTableStructureAction.deleteRow => '행 삭제',
    PptxTableStructureAction.deleteColumn => '열 삭제',
  };
}
