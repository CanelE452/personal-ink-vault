import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:saber/data/vault/block_page_table.dart';

enum _TableMenuAction { before, after, delete }

typedef _TableMenuSelection = ({
  BlockPageTable owner,
  String targetId,
  int index,
  _TableMenuAction action,
});

class BlockTableEditor extends StatefulWidget {
  const new({
    super.key,
    required this.blockId,
    required this.table,
    required this.onChanged,
    this.enabled = true,
  });

  final String blockId;
  final BlockPageTable table;
  final BlockPageTable? Function(BlockPageTable expected, BlockPageTable next)
  onChanged;
  final bool enabled;

  @override
  State<BlockTableEditor> createState() => _BlockTableEditorState();
}

class _BlockTableEditorState extends State<BlockTableEditor> {
  static const _cellWidth = 180.0;
  static const _rowHeight = 72.0;
  final _horizontal = ScrollController();
  final _vertical = ScrollController();
  final _fields = <String, _CellInput>{};
  final _retired = <_CellInput>{};
  late BlockPageTable _current;

  @override
  void initState() {
    super.initState();
    _current = widget.table;
  }

  @override
  void didUpdateWidget(BlockTableEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    _current = widget.table;
    final cells = {
      for (final row in _current.rows)
        for (final cell in row.cells) cell.id: cell.text,
    };
    for (final id in _fields.keys.toList()) {
      final field = _fields[id]!;
      final text = cells[id];
      if (text == null) {
        _fields.remove(id);
        _retired.add(field);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_retired.remove(field)) field.dispose();
        });
      } else {
        _setText(field.controller, text);
      }
    }
  }

  void _setText(TextEditingController controller, String text) {
    if (controller.text == text) return;
    final offset = controller.selection.extentOffset.clamp(0, text.length);
    controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: offset),
    );
  }

  bool _change(BlockPageTable expected, BlockPageTable Function() change) {
    if (!mounted || !widget.enabled || !identical(_current, expected))
      return false;
    try {
      final next = change();
      final committed = widget.onChanged(expected, next);
      if (committed == null) return false;
      setState(() => _current = committed);
      return true;
    } on FormatException {
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(const SnackBar(content: Text('표 크기나 셀 입력 내용을 확인하세요.')));
      return false;
    }
  }

  void _editCell(String rowId, String columnId, String cellId, String text) {
    final table = _current;
    final rowIndex = table.rows.indexWhere((row) => row.id == rowId);
    final columnIndex = table.columns.indexOf(columnId);
    if (rowIndex < 0 || columnIndex < 0) return;
    final cell = table.rows[rowIndex].cells[columnIndex];
    if (cell.id != cellId) return;
    if (!_change(table, () => table.setCellText(rowId, columnId, text))) {
      final field = _fields[cellId];
      if (field != null) _setText(field.controller, cell.text);
    }
  }

  _CellInput _input(BlockPageTableCell cell) =>
      _fields.putIfAbsent(cell.id, () => _CellInput(cell.text));

  PopupMenuButton<_TableMenuSelection> _columnMenu(
    BlockPageTable table,
    int index,
  ) {
    final id = table.columns[index];
    return PopupMenuButton<_TableMenuSelection>(
      key: ValueKey('block-table-column-${widget.blockId}-$id'),
      tooltip: '열 작업',
      enabled: widget.enabled,
      onSelected: (selection) => _change(
        selection.owner,
        () => switch (selection.action) {
          _TableMenuAction.before => selection.owner.insertColumn(
            index: selection.index,
          ),
          _TableMenuAction.after => selection.owner.insertColumn(
            index: selection.index + 1,
          ),
          _TableMenuAction.delete => selection.owner.removeColumn(
            selection.targetId,
          ),
        },
      ),
      itemBuilder: (_) => [
        PopupMenuItem<_TableMenuSelection>(
          value: (
            owner: table,
            targetId: id,
            index: index,
            action: _TableMenuAction.before,
          ),
          enabled: table.columnCount < BlockPageTable.maxColumns,
          child: const Text('앞에 열 추가'),
        ),
        PopupMenuItem<_TableMenuSelection>(
          value: (
            owner: table,
            targetId: id,
            index: index,
            action: _TableMenuAction.after,
          ),
          enabled: table.columnCount < BlockPageTable.maxColumns,
          child: const Text('뒤에 열 추가'),
        ),
        PopupMenuItem<_TableMenuSelection>(
          value: (
            owner: table,
            targetId: id,
            index: index,
            action: _TableMenuAction.delete,
          ),
          enabled: table.columnCount > 1,
          child: const Text('열 삭제'),
        ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(
          children: [
            Expanded(child: Text('열 ${index + 1}')),
            const Icon(Icons.arrow_drop_down, size: 18),
          ],
        ),
      ),
    );
  }

  PopupMenuButton<_TableMenuSelection> _rowMenu(
    BlockPageTable table,
    int index,
  ) {
    final id = table.rows[index].id;
    return PopupMenuButton<_TableMenuSelection>(
      key: ValueKey('block-table-row-${widget.blockId}-$id'),
      tooltip: '행 작업',
      enabled: widget.enabled,
      onSelected: (selection) => _change(
        selection.owner,
        () => switch (selection.action) {
          _TableMenuAction.before => selection.owner.insertRow(
            index: selection.index,
          ),
          _TableMenuAction.after => selection.owner.insertRow(
            index: selection.index + 1,
          ),
          _TableMenuAction.delete => selection.owner.removeRow(
            selection.targetId,
          ),
        },
      ),
      itemBuilder: (_) => [
        PopupMenuItem<_TableMenuSelection>(
          value: (
            owner: table,
            targetId: id,
            index: index,
            action: _TableMenuAction.before,
          ),
          enabled: table.rowCount < BlockPageTable.maxRows,
          child: const Text('앞에 행 추가'),
        ),
        PopupMenuItem<_TableMenuSelection>(
          value: (
            owner: table,
            targetId: id,
            index: index,
            action: _TableMenuAction.after,
          ),
          enabled: table.rowCount < BlockPageTable.maxRows,
          child: const Text('뒤에 행 추가'),
        ),
        PopupMenuItem<_TableMenuSelection>(
          value: (
            owner: table,
            targetId: id,
            index: index,
            action: _TableMenuAction.delete,
          ),
          enabled: table.rowCount > 1,
          child: const Text('행 삭제'),
        ),
      ],
      child: Center(child: Text('${index + 1}')),
    );
  }

  Widget _row(BlockPageTable table, int index) {
    final row = table.rows[index];
    final colors = Theme.of(context).colorScheme;
    return Row(
      key: ValueKey('block-table-row-content-${widget.blockId}-${row.id}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(width: 44, child: _rowMenu(table, index)),
        for (var column = 0; column < table.columnCount; column++)
          SizedBox(
            width: _cellWidth,
            child: Builder(
              builder: (_) {
                final cell = row.cells[column];
                final input = _input(cell);
                final header =
                    table.headerRow && index == 0 ||
                    table.headerColumn && column == 0;
                return TextField(
                  key: ValueKey(
                    'block-table-cell-${widget.blockId}-${cell.id}',
                  ),
                  controller: input.controller,
                  focusNode: input.focus,
                  readOnly: !widget.enabled,
                  minLines: 1,
                  maxLines: 2,
                  inputFormatters: [LengthLimitingTextInputFormatter(16384)],
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: header ? FontWeight.w600 : FontWeight.normal,
                  ),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: '내용',
                    filled: true,
                    fillColor: header
                        ? colors.surfaceContainerLow
                        : colors.surface,
                    border: const OutlineInputBorder(
                      borderRadius: BorderRadius.zero,
                    ),
                    contentPadding: const EdgeInsets.all(10),
                  ),
                  onChanged: (text) =>
                      _editCell(row.id, table.columns[column], cell.id, text),
                );
              },
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final table = _current;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            TextButton.icon(
              key: ValueKey('block-table-add-row-${widget.blockId}'),
              onPressed:
                  widget.enabled && table.rowCount < BlockPageTable.maxRows
                  ? () => _change(table, () => table.insertRow())
                  : null,
              icon: const Icon(Icons.add, size: 16),
              label: const Text('행 추가'),
            ),
            TextButton.icon(
              key: ValueKey('block-table-add-column-${widget.blockId}'),
              onPressed:
                  widget.enabled &&
                      table.columnCount < BlockPageTable.maxColumns
                  ? () => _change(table, () => table.insertColumn())
                  : null,
              icon: const Icon(Icons.add, size: 16),
              label: const Text('열 추가'),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Checkbox(
                  key: ValueKey('block-table-header-row-${widget.blockId}'),
                  value: table.headerRow,
                  onChanged: !widget.enabled
                      ? null
                      : (value) => _change(
                          table,
                          () => table.copyWith(headerRow: value),
                        ),
                ),
                const Text('머리글 행'),
              ],
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Checkbox(
                  key: ValueKey('block-table-header-column-${widget.blockId}'),
                  value: table.headerColumn,
                  onChanged: !widget.enabled
                      ? null
                      : (value) => _change(
                          table,
                          () => table.copyWith(headerColumn: value),
                        ),
                ),
                const Text('머리글 열'),
              ],
            ),
          ],
        ),
        Scrollbar(
          controller: _horizontal,
          thumbVisibility: true,
          child: SingleChildScrollView(
            controller: _horizontal,
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.only(bottom: 12),
            child: SizedBox(
              width: 44 + table.columnCount * _cellWidth,
              child: Column(
                children: [
                  SizedBox(
                    height: 40,
                    child: Row(
                      children: [
                        const SizedBox(width: 44),
                        for (
                          var column = 0;
                          column < table.columnCount;
                          column++
                        )
                          SizedBox(
                            width: _cellWidth,
                            child: _columnMenu(table, column),
                          ),
                      ],
                    ),
                  ),
                  SizedBox(
                    height: math.min(table.rowCount, 4) * _rowHeight,
                    child: Scrollbar(
                      controller: _vertical,
                      thumbVisibility: table.rowCount > 4,
                      child: ListView.builder(
                        controller: _vertical,
                        primary: false,
                        itemCount: table.rowCount,
                        itemExtent: _rowHeight,
                        itemBuilder: (_, index) => _row(table, index),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _horizontal.dispose();
    _vertical.dispose();
    for (final field in [..._fields.values, ..._retired]) {
      field.dispose();
    }
    _fields.clear();
    _retired.clear();
    super.dispose();
  }
}

class _CellInput {
  new(String text) : controller = TextEditingController(text: text);
  final TextEditingController controller;
  final focus = FocusNode();

  void dispose() {
    controller.dispose();
    focus.dispose();
  }
}
