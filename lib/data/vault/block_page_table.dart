import 'dart:convert';

import 'package:ink_vault_core/ink_vault_core.dart';

class BlockPageTable {
  new _(
    this._extra,
    List<String> columns,
    List<BlockPageTableRow> rows,
    this.headerRow,
    this.headerColumn,
  ) : columns = List.unmodifiable(columns),
      rows = List.unmodifiable(rows);

  static const format = 'personal-ink-table-1';
  static const maxRows = 128;
  static const maxColumns = 32;
  static const maxCellCharacters = 16384;
  static const maxTextBytes = 1024 * 1024;

  factory create({int rows = 2, int columns = 2}) {
    if (rows < 1 || rows > maxRows || columns < 1 || columns > maxColumns) {
      throw const FormatException('Invalid table dimensions');
    }
    return BlockPageTable.fromJson({
      'format': format,
      'columns': [for (var column = 0; column < columns; column++) newId()],
      'rows': [
        for (var row = 0; row < rows; row++)
          {
            'id': newId(),
            'cells': [
              for (var column = 0; column < columns; column++)
                {'id': newId(), 'text': ''},
            ],
          },
      ],
      'headerRow': false,
      'headerColumn': false,
    });
  }

  factory fromJson(Map<String, dynamic> json) {
    final raw = _tableCopy(json);
    if (raw.remove('format') != format) {
      throw const FormatException('Unsupported table format');
    }
    final rawColumns = raw.remove('columns'), rawRows = raw.remove('rows');
    final headerRow = raw.remove('headerRow');
    final headerColumn = raw.remove('headerColumn');
    if (rawColumns is! List ||
        rawColumns.isEmpty ||
        rawColumns.length > maxColumns ||
        rawRows is! List ||
        rawRows.isEmpty ||
        rawRows.length > maxRows ||
        headerRow is! bool ||
        headerColumn is! bool) {
      throw const FormatException('Invalid table data');
    }
    final identities = <String>{};
    String identity(Object? value) {
      if (value is! String) {
        throw const FormatException('Invalid table identity');
      }
      validateId(value);
      if (!identities.add(value)) {
        throw const FormatException('Duplicate table identity');
      }
      return value;
    }

    final columns = [for (final column in rawColumns) identity(column)];
    final rows = <BlockPageTableRow>[];
    var textBytes = 0;
    for (final value in rawRows) {
      final row = _tableObject(value);
      final id = identity(row.remove('id'));
      final rawCells = row.remove('cells');
      if (rawCells is! List || rawCells.length != columns.length) {
        throw const FormatException('Table rows must be rectangular');
      }
      final cells = <BlockPageTableCell>[];
      for (final rawCell in rawCells) {
        final cell = _tableObject(rawCell);
        final cellId = identity(cell.remove('id'));
        final text = cell.remove('text');
        if (text is! String || text.length > maxCellCharacters) {
          throw const FormatException('Invalid table cell text');
        }
        textBytes += utf8.encode(text).length;
        if (textBytes > maxTextBytes) {
          throw const FormatException('Table text is too large');
        }
        cells.add(BlockPageTableCell._(cell, cellId, text));
      }
      rows.add(BlockPageTableRow._(row, id, cells));
    }
    return BlockPageTable._(raw, columns, rows, headerRow, headerColumn);
  }

  final Map<String, dynamic> _extra;
  final List<String> columns;
  final List<BlockPageTableRow> rows;
  final bool headerRow;
  final bool headerColumn;
  int get rowCount => rows.length;
  int get columnCount => columns.length;

  BlockPageTable setCellText(String rowId, String columnId, String text) {
    final row = _rowIndex(rowId), column = _columnIndex(columnId);
    final data = toJson();
    (((data['rows'] as List)[row] as Map)['cells'] as List)[column]['text'] =
        text;
    return BlockPageTable.fromJson(data);
  }

  BlockPageTable insertRow({int? index}) {
    if (rowCount == maxRows) {
      throw const FormatException('Table row limit reached');
    }
    final position = index ?? rowCount;
    RangeError.checkValueInInterval(position, 0, rowCount, 'index');
    final data = toJson();
    (data['rows'] as List).insert(position, {
      'id': newId(),
      'cells': [
        for (final _ in columns) {'id': newId(), 'text': ''},
      ],
    });
    return BlockPageTable.fromJson(data);
  }

  BlockPageTable removeRow(String rowId) {
    final index = _rowIndex(rowId);
    if (rowCount == 1) {
      throw const FormatException('A table must retain one row');
    }
    final data = toJson();
    (data['rows'] as List).removeAt(index);
    return BlockPageTable.fromJson(data);
  }

  BlockPageTable insertColumn({int? index}) {
    if (columnCount == maxColumns) {
      throw const FormatException('Table column limit reached');
    }
    final position = index ?? columnCount;
    RangeError.checkValueInInterval(position, 0, columnCount, 'index');
    final data = toJson();
    (data['columns'] as List).insert(position, newId());
    for (final row in data['rows'] as List) {
      ((row as Map)['cells'] as List).insert(position, {
        'id': newId(),
        'text': '',
      });
    }
    return BlockPageTable.fromJson(data);
  }

  BlockPageTable removeColumn(String columnId) {
    final index = _columnIndex(columnId);
    if (columnCount == 1) {
      throw const FormatException('A table must retain one column');
    }
    final data = toJson();
    (data['columns'] as List).removeAt(index);
    for (final row in data['rows'] as List) {
      ((row as Map)['cells'] as List).removeAt(index);
    }
    return BlockPageTable.fromJson(data);
  }

  BlockPageTable copyWith({bool? headerRow, bool? headerColumn}) =>
      BlockPageTable.fromJson({
        ...toJson(),
        'headerRow': headerRow ?? this.headerRow,
        'headerColumn': headerColumn ?? this.headerColumn,
      });

  Map<String, dynamic> toJson() => {
    ..._tableCopy(_extra),
    'format': format,
    'columns': List<String>.of(columns),
    'rows': [for (final row in rows) row.toJson()],
    'headerRow': headerRow,
    'headerColumn': headerColumn,
  };

  String toPlainText() => rows
      .map((row) => row.cells.map((cell) => cell.text).join('\t'))
      .join('\n');

  String toMarkdown() {
    String line(Iterable<String> cells) =>
        '| ${cells.map(_tableMarkdownCell).join(' | ')} |';
    final header = headerRow
        ? rows.first.cells.map((cell) => cell.text)
        : List<String>.filled(columnCount, '');
    return [
      line(header),
      line(List<String>.filled(columnCount, '---')),
      for (final row in headerRow ? rows.skip(1) : rows)
        line(row.cells.map((cell) => cell.text)),
    ].join('\n');
  }

  int _rowIndex(String id) {
    final index = rows.indexWhere((row) => row.id == id);
    if (index < 0) throw ArgumentError.value(id, 'rowId', 'Unknown table row');
    return index;
  }

  int _columnIndex(String id) {
    final index = columns.indexOf(id);
    if (index < 0) {
      throw ArgumentError.value(id, 'columnId', 'Unknown table column');
    }
    return index;
  }
}

class BlockPageTableRow {
  new _(this._extra, this.id, List<BlockPageTableCell> cells)
    : cells = List.unmodifiable(cells);
  final Map<String, dynamic> _extra;
  final String id;
  final List<BlockPageTableCell> cells;

  Map<String, dynamic> toJson() => {
    ..._tableCopy(_extra),
    'id': id,
    'cells': [for (final cell in cells) cell.toJson()],
  };
}

class BlockPageTableCell {
  const new _(this._extra, this.id, this.text);
  final Map<String, dynamic> _extra;
  final String id;
  final String text;

  Map<String, dynamic> toJson() => {
    ..._tableCopy(_extra),
    'id': id,
    'text': text,
  };
}

Map<String, dynamic> _tableObject(Object? value) {
  if (value is! Map) throw const FormatException('Expected a table object');
  return Map<String, dynamic>.from(value);
}

Map<String, dynamic> _tableCopy(Map<String, dynamic> value) {
  try {
    return _tableObject(jsonDecode(jsonEncode(value)));
  } on Object {
    throw const FormatException('Expected JSON table data');
  }
}

String _tableMarkdownCell(String text) => text
    .replaceAll('\\', r'\\')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('|', r'\|')
    .replaceAll('\r\n', '\n')
    .replaceAll('\r', '\n')
    .replaceAll('\n', '<br>');
