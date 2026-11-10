import 'package:flutter/material.dart';
import 'package:saber/data/office/pptx_shape_text.dart';

typedef PptxTableCellTextDraft = ({
  int slideIndex,
  int shapeId,
  int row,
  int column,
  List<PptxShapeTextChange> changes,
});

Future<PptxTableCellTextDraft?> choosePptxTableCellText(
  BuildContext context,
  PptxShapeTextPlan plan,
  Future<List<PptxTableCellTextTable>> Function(int slideIndex) loadSlide,
) => showDialog<PptxTableCellTextDraft>(
  context: context,
  builder: (context) => _PptxTableCellTextDialog(plan, loadSlide),
);

class _PptxTableCellTextDialog extends StatefulWidget {
  const new(this.plan, this.loadSlide);

  final PptxShapeTextPlan plan;
  final Future<List<PptxTableCellTextTable>> Function(int slideIndex) loadSlide;

  @override
  State<_PptxTableCellTextDialog> createState() =>
      _PptxTableCellTextDialogState();
}

class _PptxTableCellTextDialogState extends State<_PptxTableCellTextDialog> {
  final _changes = <(int, int), String>{};
  int? _slideIndex;
  Future<List<PptxTableCellTextTable>>? _tables;
  PptxTableCellTextTable? _table;
  int? _row;
  PptxTableCellTextCell? _cell;

  bool get _withinTotalLimit =>
      _changes.values.fold(0, (total, text) => total + text.length) <=
      PptxShapeTextEngine.maxTotalRunLength;

  bool get _canSubmit =>
      _cell != null &&
      _changes.isNotEmpty &&
      _withinTotalLimit &&
      _changes.values.every(PptxShapeTextEngine.validText);

  Future<void> _changeSelection(VoidCallback select) async {
    if (_changes.isNotEmpty) {
      final discard = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('이 셀의 변경 사항을 버릴까요?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('계속 편집'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('변경 버리기'),
            ),
          ],
        ),
      );
      if (discard != true || !mounted) return;
    }
    setState(() {
      _changes.clear();
      select();
    });
  }

  void _submit() {
    final slide = _slideIndex;
    final table = _table;
    final cell = _cell;
    if (slide == null || table == null || cell == null || !_canSubmit) return;
    Navigator.of(context).pop((
      slideIndex: slide,
      shapeId: table.shapeId,
      row: cell.row,
      column: cell.column,
      changes: List<PptxShapeTextChange>.unmodifiable([
        for (final run in cell.runs)
          if (_changes[(run.paragraphIndex, run.runIndex)] case final text?)
            PptxShapeTextChange(
              paragraphIndex: run.paragraphIndex,
              runIndex: run.runIndex,
              text: text,
            ),
      ]),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final runs = _cell?.runs ?? const <PptxShapeTextRun>[];
    return AlertDialog(
      title: const Text('PPTX 표 셀 글자 수정'),
      content: SizedBox(
        width: 480,
        height: 400,
        child: ListView.builder(
          itemCount: runs.length + 4,
          itemBuilder: (context, index) => switch (index) {
            0 => _slidePicker(),
            1 => _tablePicker(),
            2 => _cellPickers(),
            3 =>
              _cell == null
                  ? const SizedBox.shrink()
                  : const Padding(
                      padding: EdgeInsets.only(bottom: 12),
                      child: Text('편집 가능한 글자 구간을 표시합니다. 기존 서식은 유지됩니다.'),
                    ),
            _ => _runField(runs[index - 4]),
          },
        ),
      ),
      actions: [
        if (!_withinTotalLimit)
          Text(
            '한 번에 저장할 수 있는 글자 길이를 넘었습니다.',
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        TextButton(
          key: const ValueKey('pptx-table-cell-text-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        FilledButton(
          key: const ValueKey('pptx-table-cell-text-confirm'),
          onPressed: _canSubmit ? _submit : null,
          child: const Text('수정하고 저장'),
        ),
      ],
    );
  }

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
          key: ValueKey('pptx-table-cell-text-$name'),
          value: value,
          hint: Text('$label 선택'),
          isDense: true,
          isExpanded: true,
          items: items,
          onChanged: (value) {
            if (value != null) select(value);
          },
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
    select: (index) async {
      if (index == _slideIndex) return;
      await _changeSelection(() {
        _slideIndex = index;
        _tables = widget.loadSlide(index);
        _table = null;
        _row = null;
        _cell = null;
      });
    },
  );

  Widget _tablePicker() {
    final slide = _slideIndex;
    if (slide == null) return const SizedBox.shrink();
    return FutureBuilder<List<PptxTableCellTextTable>>(
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
        if (tables.isEmpty) {
          return const Text('이 슬라이드에 수정할 수 있는 표 셀이 없습니다.');
        }
        return _picker<PptxTableCellTextTable>(
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
          select: (table) async {
            if (identical(_table, table)) return;
            await _changeSelection(() {
              _table = table;
              _row = null;
              _cell = null;
            });
          },
        );
      },
    );
  }

  Widget _cellPickers() {
    final table = _table;
    if (table == null) return const SizedBox.shrink();
    return Row(
      children: [
        Expanded(
          child: _picker<int>(
            name: 'row',
            label: '행',
            value: _row,
            items: [
              for (final row in table.cells.map((cell) => cell.row).toSet())
                DropdownMenuItem(value: row, child: Text('${row + 1}행')),
            ],
            select: (row) async {
              if (_row == row) return;
              await _changeSelection(() {
                _row = row;
                _cell = null;
              });
            },
          ),
        ),
        if (_row != null) ...[
          const SizedBox(width: 12),
          Expanded(
            child: _picker<PptxTableCellTextCell>(
              name: 'column',
              label: '열',
              value: _cell,
              items: [
                for (final cell in table.cells)
                  if (cell.row == _row)
                    DropdownMenuItem(
                      value: cell,
                      child: Text('${cell.column + 1}열'),
                    ),
              ],
              select: (cell) async {
                if (identical(_cell, cell)) return;
                await _changeSelection(() => _cell = cell);
              },
            ),
          ),
        ],
      ],
    );
  }

  Widget _runField(PptxShapeTextRun run) {
    final key = (run.paragraphIndex, run.runIndex);
    final value = _changes[key] ?? run.text;
    return KeyedSubtree(
      key: ValueKey((
        _slideIndex,
        _table!.shapeId,
        _cell!.row,
        _cell!.column,
        key,
      )),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextFormField(
          key: ValueKey('pptx-table-cell-text-run-${key.$1}-${key.$2}'),
          initialValue: value,
          minLines: 1,
          maxLines: 3,
          keyboardType: TextInputType.text,
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(
            labelText: '문단 ${key.$1 + 1} · 글자 구간 ${key.$2 + 1}',
            hintText: '빈 글자 구간',
            border: const OutlineInputBorder(),
            errorText: PptxShapeTextEngine.validText(value)
                ? null
                : '이 구간의 글자 길이 또는 문자를 확인하세요.',
          ),
          onChanged: (text) => setState(() {
            if (text == run.text) {
              _changes.remove(key);
            } else {
              _changes[key] = text;
            }
          }),
        ),
      ),
    );
  }
}
