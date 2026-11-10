import 'dart:convert';
import 'dart:typed_data';

const notionCsvMaxBytes = 8 * 1024 * 1024;
const _maxDataRows = 2000;
const _maxColumns = 128;
const _maxCellCodeUnits = 64 * 1024;

final class NotionCsvTable {
  new _(List<String> headers, List<List<String>> rows)
    : headers = List.unmodifiable(headers),
      rows = List.unmodifiable(rows.map(List<String>.unmodifiable));

  final List<String> headers;
  final List<List<String>> rows;
}

NotionCsvTable parseNotionCsv(Uint8List bytes) {
  if (bytes.length > notionCsvMaxBytes) {
    throw const FormatException('Notion CSV exceeds the file size limit');
  }
  final String input;
  try {
    input = utf8.decode(bytes);
  } on FormatException {
    throw const FormatException('Notion CSV is not valid UTF-8');
  }
  if (input.isEmpty) {
    throw const FormatException('Notion CSV has no header');
  }
  if (input.contains('\u0000')) {
    throw const FormatException('Notion CSV contains a NUL character');
  }

  final reader = _CsvReader(input);
  final headers = reader.readRow();
  final rows = <List<String>>[];
  while (!reader.atEnd) {
    if (rows.length == _maxDataRows) {
      throw const FormatException('Notion CSV exceeds the row limit');
    }
    final row = reader.readRow();
    if (row.length != headers.length) {
      throw FormatException(
        'Notion CSV record ${rows.length + 2} has a different column count',
      );
    }
    rows.add(row);
  }
  return NotionCsvTable._(headers, rows);
}

final class _CsvReader {
  new(this._input);

  static const _quote = 0x22;
  static const _comma = 0x2c;
  static const _lineFeed = 0x0a;
  static const _carriageReturn = 0x0d;

  final String _input;
  var _offset = 0;

  bool get atEnd => _offset == _input.length;

  List<String> readRow() {
    final cells = <String>[];
    while (true) {
      if (cells.length == _maxColumns) {
        throw const FormatException('Notion CSV exceeds the column limit');
      }
      cells.add(
        !atEnd && _input.codeUnitAt(_offset) == _quote
            ? _quotedCell()
            : _unquotedCell(),
      );
      if (atEnd) return cells;
      switch (_input.codeUnitAt(_offset++)) {
        case _comma:
          continue;
        case _lineFeed:
          return cells;
        case _carriageReturn:
          if (atEnd || _input.codeUnitAt(_offset) != _lineFeed) {
            throw const FormatException(
              'Notion CSV records require LF or CRLF',
            );
          }
          _offset++;
          return cells;
        default:
          throw const FormatException(
            'Unexpected data after a quoted Notion CSV cell',
          );
      }
    }
  }

  String _unquotedCell() {
    final start = _offset;
    while (!atEnd) {
      final unit = _input.codeUnitAt(_offset);
      if (unit == _comma || unit == _lineFeed || unit == _carriageReturn) break;
      if (unit == _quote) {
        throw const FormatException(
          'Unexpected quote in an unquoted Notion CSV cell',
        );
      }
      _offset++;
    }
    _checkCellSize(_offset - start);
    return _input.substring(start, _offset);
  }

  String _quotedCell() {
    final value = StringBuffer();
    var start = ++_offset;
    while (true) {
      final end = _input.indexOf('"', start);
      if (end < 0) {
        throw const FormatException('Unclosed quoted Notion CSV cell');
      }
      _offset = end + 1;
      final escaped = !atEnd && _input.codeUnitAt(_offset) == _quote;
      _checkCellSize(value.length + end - start + (escaped ? 1 : 0));
      value.write(_input.substring(start, end));
      if (!escaped) return value.toString();
      value.writeCharCode(_quote);
      start = ++_offset;
    }
  }

  void _checkCellSize(int size) {
    if (size > _maxCellCodeUnits) {
      throw const FormatException('Notion CSV exceeds the cell size limit');
    }
  }
}
