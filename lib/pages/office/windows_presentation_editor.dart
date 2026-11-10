part of 'windows_office_editor.dart';

Object? _pptCanonicalValue(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: _pptCanonicalValue(value[key])};
  }
  if (value is List)
    return [for (final item in value) _pptCanonicalValue(item)];
  return value;
}

String _pptOperationsHash(List<WindowsOfficeOperation> operations) => sha256
    .convert(
      utf8.encode(
        jsonEncode(
          _pptCanonicalValue([
            for (final operation in operations) operation.toJson(),
          ]),
        ),
      ),
    )
    .toString();

Object _pptStructureTable(
  WindowsOfficePresentationTable table, {
  String? sourceSha256,
}) => [
  _pptNativeTable(table, sourceSha256: sourceSha256),
  [for (final cell in table.cells) cell.sourceTextPatch?.toJson()],
];

class _PptSourceTableSize {
  const new(
    this.rows,
    this.columns,
    this.rowHeight,
    this.columnWidth,
    this.x,
    this.y,
  );
  final int rows, columns;
  final num rowHeight, columnWidth, x, y;
}

class _PptSourceTableDialog extends StatefulWidget {
  const new({required this.slideWidth, required this.slideHeight});
  final double slideWidth, slideHeight;
  @override
  State<_PptSourceTableDialog> createState() => _PptSourceTableDialogState();
}

class _PptSourceTableDialogState extends State<_PptSourceTableDialog> {
  late final Map<String, TextEditingController> _fields;
  String? _error;
  bool get _composing => _fields.values.any(
    (field) =>
        field.value.composing.isValid && !field.value.composing.isCollapsed,
  );

  @override
  void initState() {
    super.initState();
    final x = math.min(15.0, math.max(0.0, widget.slideWidth - 90));
    final y = math.min(120.0, math.max(0.0, widget.slideHeight - 24));
    _fields = {
      'rows': TextEditingController(text: '2'),
      'columns': TextEditingController(text: '3'),
      'row-height': TextEditingController(text: '12'),
      'column-width': TextEditingController(text: '30'),
      'x': TextEditingController(text: ((x * 100).floor() / 100).toString()),
      'y': TextEditingController(text: ((y * 100).floor() / 100).toString()),
    };
    for (final field in _fields.values) field.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() => _error = null);
  }

  void _submit() {
    if (_composing) return;
    final rows = int.tryParse(_fields['rows']!.text);
    final columns = int.tryParse(_fields['columns']!.text);
    final rowHeight = num.tryParse(_fields['row-height']!.text);
    final columnWidth = num.tryParse(_fields['column-width']!.text);
    final x = num.tryParse(_fields['x']!.text);
    final y = num.tryParse(_fields['y']!.text);
    if (rows == null ||
        columns == null ||
        rows < 1 ||
        columns < 1 ||
        rows > 100 ||
        columns > 100 ||
        rows * columns > 100) {
      setState(() => _error = '행과 열은 1 이상, 전체 셀은 100개 이내로 입력하세요.');
      return;
    }
    if ([rowHeight, columnWidth, x, y].any((value) => value == null)) {
      setState(() => _error = '크기와 위치를 숫자로 입력하세요.');
      return;
    }
    try {
      WindowsOfficeOperation.presentationSourceTableAdd(
        id: 'new-table-validation',
        ownerId: 'slide-0',
        expectedSourceSha256: '0' * 64,
        sourcePart: 'ppt/slides/slide1.xml',
        expectedSourcePartSha256: '0' * 64,
        expectedShapeIdInventorySha256: '0' * 64,
        xMm: x!,
        yMm: y!,
        columnWidthsMm: List<num>.filled(columns, columnWidth!),
        rowHeightsMm: List<num>.filled(rows, rowHeight!),
      );
    } on FormatException {
      setState(
        () => _error =
            '크기는 0보다 크게, 위치와 전체 크기는 1000mm 이내로 입력하세요. 소수 둘째 자리까지 사용할 수 있습니다.',
      );
      return;
    }
    Navigator.of(context)
        .pop(_PptSourceTableSize(rows, columns, rowHeight, columnWidth, x, y));
  }

  @override
  void dispose() {
    for (final field in _fields.values) {
      field.removeListener(_changed);
      field.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    insetPadding: const EdgeInsets.all(16),
    title: const Text('표 추가'),
    content: SizedBox(
      width: 360,
      child: SingleChildScrollView(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth >= 300
                ? (constraints.maxWidth - 12) / 2
                : constraints.maxWidth;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 12,
                  runSpacing: 16,
                  children: [
                    for (final field in const {
                      'rows': '행 수',
                      'columns': '열 수',
                      'row-height': '행 높이(mm)',
                      'column-width': '열 너비(mm)',
                      'x': '가로 위치(mm)',
                      'y': '세로 위치(mm)',
                    }.entries)
                      SizedBox(
                        width: width,
                        child: TextField(
                          key: ValueKey('office-ppt-table-${field.key}'),
                          controller: _fields[field.key],
                          keyboardType: TextInputType.numberWithOptions(
                            decimal:
                                field.key != 'rows' && field.key != 'columns',
                            signed: field.key == 'x' || field.key == 'y',
                          ),
                          decoration: InputDecoration(
                            labelText: field.value,
                            border: const OutlineInputBorder(),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                const Text('최대 100셀 · 슬라이드당 표 20개'),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
              ],
            );
          },
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('취소'),
      ),
      FilledButton(
        key: const ValueKey('office-ppt-add-table-confirm'),
        onPressed: _composing ? null : _submit,
        child: const Text('추가'),
      ),
    ],
  );
}

bool _pptSameValue(Object? left, Object? right) {
  if (identical(left, right) || left == right) return true;
  if (left is List && right is List) {
    return left.length == right.length &&
        List.generate(
          left.length,
          (index) => index,
        ).every((index) => _pptSameValue(left[index], right[index]));
  }
  if (left is Map && right is Map) {
    return left.length == right.length &&
        left.keys.every(
          (key) =>
              right.containsKey(key) && _pptSameValue(left[key], right[key]),
        );
  }
  return false;
}

Object? _pptNativeText(WindowsOfficeTextDetails? details) => details == null
    ? null
    : [
        details.utf16Length,
        details.textSha256,
        details.canReplace,
        details.canStyle,
        details.truncated,
        for (final run in details.runs)
          [
            run.startUtf16,
            run.endUtf16,
            run.fontSize,
            run.bold,
            run.italic,
            run.underline,
            run.color,
            run.fontFamily,
          ],
        [
          for (final range in details.protectedRanges)
            [range.startUtf16, range.endUtf16, range.type],
        ],
      ];

Object _pptNativeShape(WindowsOfficeShape shape) => [
  shape.id,
  shape.type,
  shape.text,
  shape.editableText,
  shape.x,
  shape.y,
  shape.width,
  shape.height,
  shape.fontSize,
  shape.bold,
  shape.color,
  shape.shapeKind,
  shape.fillStyle,
  shape.fillColor,
  shape.lineStyle,
  shape.lineColor,
  shape.lineWidth,
  shape.canEditFill,
  shape.canEditLine,
  shape.ownerKind,
  shape.ownerId,
  shape.presentationObject,
  shape.emptyPresentationObject,
  shape.canEditGeometry,
  shape.canDelete,
  shape.canEditTextStyle,
  _pptNativeText(shape.textDetails),
  if (shape.image case final image?)
    [
      image.mimeType,
      image.pixelWidth,
      image.pixelHeight,
      image.canReplace,
      image.rotationHundredths,
      image.canRotate,
      image.thumbnailBase64,
      image.thumbnailMimeType,
      image.thumbnailSha256,
      image.thumbnailTruncated,
    ],
];

Object _pptNativeTable(
  WindowsOfficePresentationTable table, {
  String? sourceSha256,
}) {
  final caps = table.capabilities;
  return [
    table.id,
    table.ownerId,
    table.tableSha256,
    table.rowCount,
    table.columnCount,
    table.totalCellCount,
    table.truncated,
    table.rowHeightsHmm,
    table.columnWidthsHmm,
    table.nativeBoundsHmm,
    table.authoredGeometry,
    table.rawStyle,
    [
      caps.canEditText,
      caps.canEditTextStyle,
      caps.canEditAppearance,
      caps.canInsertRows,
      caps.canDeleteRows,
      caps.canInsertColumns,
      caps.canDeleteColumns,
      caps.canMerge,
      caps.canSplit,
      caps.canDeleteTable,
    ],
    if (table.sourceTextPatchAuthority case final authority?)
      {...authority.toJson(), 'sourceSha256': ?sourceSha256}
    else
      null,
    for (final cell in table.cells)
      [
        cell.id,
        cell.row,
        cell.column,
        cell.rowSpan,
        cell.columnSpan,
        cell.covered,
        cell.anchorCellId,
        cell.text,
        _pptNativeText(cell.textDetails),
        cell.rawStyle,
      ],
  ];
}

List<List<Object>> _pptSourceIntervals(WindowsOfficeSourceTextPatch proof) {
  final result = <List<Object>>[];
  for (final segment in proof.segments) {
    if (segment.startUtf16 == segment.endUtf16 && segment.editable) continue;
    final previous = result.lastOrNull;
    if (previous != null &&
        previous[2] == segment.editable &&
        previous[1] == segment.startUtf16 &&
        previous[0] != previous[1] &&
        segment.startUtf16 != segment.endUtf16) {
      previous[1] = segment.endUtf16;
    } else {
      result.add([segment.startUtf16, segment.endUtf16, segment.editable]);
    }
  }
  return result;
}

bool _pptSameSourceMap(
  WindowsOfficeSourceTextPatch? expected,
  WindowsOfficeSourceTextPatch? actual,
) {
  if (expected == null || actual == null) return expected == actual;
  final closedEmpty =
      expected.canReplace &&
      !actual.canReplace &&
      !expected.segments.any(
        (segment) => segment.editable && segment.startUtf16 < segment.endUtf16,
      ) &&
      !actual.segments.any((segment) => segment.editable);
  if (expected.text != actual.text ||
      expected.utf16Length != actual.utf16Length ||
      expected.textSha256 != actual.textSha256 ||
      expected.truncated != actual.truncated ||
      expected.canReplace != actual.canReplace && !closedEmpty ||
      !_pptSameValue(
        _pptSourceIntervals(expected),
        _pptSourceIntervals(actual),
      )) {
    return false;
  }
  Object protections(WindowsOfficeSourceTextPatch proof) => [
    for (final range in proof.protectedRanges)
      if (range.reason == 'comment' || range.reason == 'processingInstruction')
        [range.reason]
      else
        [range.startUtf16, range.endUtf16, range.reason],
  ];
  if (!_pptSameValue(protections(expected), protections(actual))) return false;
  for (final segment in actual.segments.where(
    (segment) => segment.editable && segment.startUtf16 == segment.endUtf16,
  )) {
    if (!expected.segments.any(
      (original) =>
          original.editable &&
          original.startUtf16 <= segment.startUtf16 &&
          segment.endUtf16 <= original.endUtf16,
    ))
      return false;
  }
  return true;
}

WindowsOfficeSourceTextPatch _pptReplaceSourceMap(
  WindowsOfficeSourceTextPatch original,
  int start,
  int end,
  String replacement,
) {
  final insertedEnd = start + replacement.length;
  final delta = replacement.length - (end - start);
  final first = original.segments.indexWhere(
    (segment) =>
        segment.editable &&
        (start == end
            ? segment.startUtf16 <= start && start <= segment.endUtf16
            : segment.startUtf16 < end && start < segment.endUtf16),
  );
  final segments = <Map<String, dynamic>>[];
  for (var index = 0; index < original.segments.length; index++) {
    final segment = original.segments[index];
    var left = segment.startUtf16, right = segment.endUtf16;
    if (start == end) {
      if (index == first) {
        right += delta;
      } else if (index > first) {
        left += delta;
        right += delta;
      }
    } else if (left >= end) {
      left += delta;
      right += delta;
    } else if (right > start) {
      if (index == first) {
        right = insertedEnd + math.max(0, right - end);
      } else {
        left = insertedEnd;
        right = insertedEnd + math.max(0, right - end);
      }
    }
    segments.add({
      'startUtf16': left,
      'endUtf16': right,
      'editable': segment.editable,
    });
  }
  int move(int offset) => offset <= start
      ? offset
      : offset >= end
      ? offset + delta
      : insertedEnd;
  final text = original.text.replaceRange(start, end, replacement);
  return WindowsOfficeSourceTextPatch.fromJson({
    'canReplace': original.canReplace,
    'truncated': original.truncated,
    'text': text,
    'utf16Length': text.length,
    'textSha256': _TextDraft._digest(text),
    'segments': segments,
    'protectedRanges': [
      for (final range in original.protectedRanges)
        {
          'startUtf16': move(range.startUtf16),
          'endUtf16': move(range.endUtf16),
          'reason': range.reason,
        },
    ],
  });
}

(int, int, int)? _pptSelectedSourceRange(
  String before,
  TextEditingValue original,
  TextEditingValue changed,
) {
  final selected = original.selection;
  final caret = changed.selection;
  if (original.text != before ||
      !selected.isValid ||
      selected.end > before.length ||
      !caret.isValid ||
      !caret.isCollapsed ||
      caret.end > changed.text.length)
    return null;
  (int, int, int)? candidate(int start, int end, int newEnd) {
    if (newEnd < start ||
        !_TextDraft._boundary(before, start) ||
        !_TextDraft._boundary(before, end) ||
        !_TextDraft._boundary(changed.text, start) ||
        !_TextDraft._boundary(changed.text, newEnd))
      return null;
    final replacement = changed.text.substring(start, newEnd);
    return before.replaceRange(start, end, replacement) == changed.text
        ? (start, end, newEnd)
        : null;
  }

  final delta = changed.text.length - before.length;
  if (!selected.isCollapsed) {
    final newEnd = selected.end + delta;
    if (caret.extentOffset == newEnd)
      return candidate(selected.start, selected.end, newEnd);
  } else {
    final cursor = selected.extentOffset;
    if (delta < 0) {
      if (caret.extentOffset == cursor + delta) {
        final backwards = candidate(cursor + delta, cursor, cursor + delta);
        if (backwards != null) return backwards;
      }
      if (caret.extentOffset == cursor)
        return candidate(cursor, cursor - delta, cursor);
    } else if (delta > 0 && caret.extentOffset == cursor + delta) {
      return candidate(cursor, cursor, cursor + delta);
    }
  }
  return null;
}

class _PptCellDraft {
  new(
    this.table,
    this.baseline,
    this.changed, {
    WindowsOfficeSourceTextPatch? current,
    List<WindowsOfficeOperation> operations = const [],
    TextSelection? selection,
  }) : current = current ?? baseline.sourceTextPatch,
       text = TextEditingController(
         text:
             current?.text ??
             baseline.sourceTextPatch?.text ??
             baseline.text ??
             '',
       ) {
    this.operations.addAll(operations);
    if (selection != null &&
        selection.isValid &&
        selection.end <= text.text.length) {
      text.selection = selection;
    }
    _accepted = text.value;
    text.addListener(_input);
  }
  final WindowsOfficePresentationTable table;
  final WindowsOfficePresentationCell baseline;
  final VoidCallback changed;
  WindowsOfficeSourceTextPatch? current;
  final TextEditingController text;
  final focus = FocusNode();
  final operations = <WindowsOfficeOperation>[];
  bool Function()? canMergePrevious;
  bool Function()? canEdit;
  late TextEditingValue _accepted;
  TextEditingValue? _compositionBase;
  var _updating = false;
  var _mergeAllowed = false;
  WindowsOfficeSourceTextPatch? _mergeBase;
  String? lastEditError;
  bool get composing =>
      text.value.composing.isValid && !text.value.composing.isCollapsed;
  (String, String, String) get key => (table.ownerId, table.id, baseline.id);
  bool get canReplace =>
      !baseline.covered &&
      table.sourceTextPatchAuthority != null &&
      current?.canReplace == true;

  WindowsOfficeOperation _operation(
    int start,
    int end,
    String replacement,
    String hash,
  ) {
    final authority = table.sourceTextPatchAuthority!;
    return WindowsOfficeOperation.presentationCellTextPatch(
      authorityVersion: authority.version,
      ownerId: table.ownerId,
      tableId: table.id,
      cellId: baseline.id,
      expectedSourceSha256: authority.sourceSha256,
      sourcePart: authority.sourcePart,
      shapeId: authority.shapeId,
      expectedSourceFrameSha256: authority.frameSha256,
      expectedTextSha256: hash,
      startUtf16: start,
      endUtf16: end,
      text: replacement,
    );
  }

  void _input() {
    if (_updating) return;
    final value = text.value;
    final before = current;
    if (composing &&
        _compositionBase == null &&
        before?.text == _accepted.text) {
      _compositionBase = _accepted;
    }
    lastEditError = null;
    if (before != null && value.text != before.text) {
      var start = 0;
      while (start < before.text.length &&
          start < value.text.length &&
          before.text.codeUnitAt(start) == value.text.codeUnitAt(start))
        start++;
      while (!_TextDraft._boundary(before.text, start) ||
          !_TextDraft._boundary(value.text, start))
        start--;
      var end = before.text.length, newEnd = value.text.length;
      while (end > start &&
          newEnd > start &&
          before.text.codeUnitAt(end - 1) ==
              value.text.codeUnitAt(newEnd - 1)) {
        end--;
        newEnd--;
      }
      while (!_TextDraft._boundary(before.text, end) ||
          !_TextDraft._boundary(value.text, newEnd)) {
        end++;
        newEnd++;
      }
      final selectedRange = _pptSelectedSourceRange(
        before.text,
        _compositionBase ?? _accepted,
        value,
      );
      if (selectedRange != null) {
        start = selectedRange.$1;
        end = selectedRange.$2;
        newEnd = selectedRange.$3;
      }
      try {
        if (!canReplace ||
            canEdit?.call() == false ||
            !before.allowsRange(start, end) ||
            value.text.length > 131072 ||
            !_TextDraft._validUtf16(value.text) ||
            value.text.runes.any(
              (scalar) =>
                  scalar < 0x20 &&
                      scalar != 9 &&
                      scalar != 10 &&
                      scalar != 13 ||
                  scalar == 0xfffe ||
                  scalar == 0xffff,
            )) {
          throw const FormatException('필드나 보호된 셀 내용을 가로지르는 변경은 적용하지 않았습니다.');
        }
        if (!composing) {
          final replacement = value.text.substring(start, newEnd);
          final next = _pptReplaceSourceMap(before, start, end, replacement);
          final previous = operations.lastOrNull?.toJson();
          final previousStart = previous?['startUtf16'] as int?;
          final previousText = previous?['text'] as String?;
          var merged = false;
          if (_mergeAllowed &&
              canMergePrevious?.call() == true &&
              previous != null &&
              previousStart != null &&
              previousText != null) {
            if (previousText.isNotEmpty &&
                start >= previousStart &&
                end <= previousStart + previousText.length) {
              operations[operations.length - 1] = _operation(
                previousStart,
                previous['endUtf16'] as int,
                previousText.replaceRange(
                  start - previousStart,
                  end - previousStart,
                  replacement,
                ),
                previous['expectedTextSha256'] as String,
              );
              merged = true;
            } else if (previousText.isEmpty &&
                replacement.isEmpty &&
                start <= previousStart &&
                end >= previousStart) {
              final int deletionStart = start;
              final int extension = end - previousStart;
              final int deletionEnd = (previous['endUtf16'] as int) + extension;
              if (_mergeBase?.textSha256 == previous['expectedTextSha256'] &&
                  _mergeBase?.allowsRange(deletionStart, deletionEnd) == true) {
                operations[operations.length - 1] = _operation(
                  deletionStart,
                  deletionEnd,
                  '',
                  previous['expectedTextSha256'] as String,
                );
                merged = true;
              }
            }
          }
          if (!merged) {
            operations.add(
              _operation(start, end, replacement, before.textSha256),
            );
            _mergeBase = before;
          }
          current = next;
          _mergeAllowed = true;
        }
      } on FormatException catch (error) {
        lastEditError = error.message;
        _updating = true;
        text.value = _accepted;
        _updating = false;
        if (!_accepted.composing.isValid || _accepted.composing.isCollapsed)
          _compositionBase = null;
        changed();
        return;
      }
    } else if (before == null && value.text != _accepted.text) {
      _updating = true;
      text.value = _accepted;
      _updating = false;
    }
    if (value.text == before?.text && value.selection != _accepted.selection)
      finishTyping();
    if (!composing) _compositionBase = null;
    _accepted = text.value;
    changed();
  }

  void finishTyping() {
    _mergeAllowed = false;
    _mergeBase = null;
  }

  void adopt(WindowsOfficeSourceTextPatch? proof) {
    current = proof;
    finishTyping();
  }

  void dispose() {
    text.dispose();
    focus.dispose();
  }
}

class _PptCellState {
  new(_PptCellDraft cell)
    : baseline = cell.baseline,
      current = cell.current,
      text = cell.text.text,
      selection = cell.text.selection,
      operations = List.of(cell.operations);
  final WindowsOfficePresentationCell baseline;
  final WindowsOfficeSourceTextPatch? current;
  final String text;
  final TextSelection selection;
  final List<WindowsOfficeOperation> operations;
  Object get content => [baseline.id, text, current?.toJson()];
  _PptCellDraft restore(
    WindowsOfficePresentationTable table,
    VoidCallback changed,
  ) => _PptCellDraft(
    table,
    baseline,
    changed,
    current: current,
    operations: operations,
    selection: selection,
  );
}

class _PptTableDraft {
  new(this.baseline, VoidCallback changed)
    : cells = [
        for (final cell in baseline.cells)
          _PptCellDraft(baseline, cell, changed),
      ];
  new restore(this.baseline, List<_PptCellState> states, VoidCallback changed)
    : cells = [for (final cell in states) cell.restore(baseline, changed)];
  final WindowsOfficePresentationTable baseline;
  final List<_PptCellDraft> cells;
  void dispose() {
    for (final cell in cells) cell.dispose();
  }
}

class _PptTableState {
  new(_PptTableDraft table)
    : baseline = table.baseline,
      cells = [for (final cell in table.cells) _PptCellState(cell)];
  final WindowsOfficePresentationTable baseline;
  final List<_PptCellState> cells;
  Object get content => [baseline.id, for (final cell in cells) cell.content];
  _PptTableDraft restore(VoidCallback changed) =>
      _PptTableDraft.restore(baseline, cells, changed);
}

_ShapeDraft _presentationShape(
  WindowsOfficeShape shape,
  VoidCallback changed, {
  bool master = false,
}) {
  final template =
      (master || shape.ownerKind == 'master') &&
      shape.presentationObject == true;
  return _ShapeDraft(
    shape.id,
    shape.editableText && !template,
    _TextDraft(
      shape.text,
      fontSize: shape.fontSize,
      bold: shape.bold,
      color: shape.color,
      details: shape.textDetails,
      targetKind: 'shape',
      id: shape.id,
      onChanged: changed,
    ),
    {'x': shape.x, 'y': shape.y, 'width': shape.width, 'height': shape.height},
    shapeKind: shape.shapeKind,
    image: shape.image,
    imageBytes: shape.image?.thumbnailBytes,
    canEditFill: shape.canEditFill && !template,
    canEditLine: shape.canEditLine && !template,
    canEditGeometry: shape.canEditGeometry && !template,
    canDelete: shape.canDelete && !template,
    canEditTextStyle: shape.canEditTextStyle && !template,
    presentationObject: shape.presentationObject,
    emptyPresentationObject: shape.emptyPresentationObject,
    fillStyle: shape.fillStyle,
    fillColor: shape.fillColor,
    lineStyle: shape.lineStyle,
    lineColor: shape.lineColor,
    lineWidth: shape.lineWidth,
  );
}

class _PptTextState {
  new(_TextDraft draft)
    : text = draft.text.text,
      font = draft.font.text,
      bold = draft.bold,
      color = draft.color,
      selection = draft._selection,
      details = draft.isRich ? _wordTextDetails(draft) : null;
  final String text;
  final String font;
  final bool bold;
  final int color;
  final TextSelection selection;
  final Map<String, dynamic>? details;

  _TextDraft restore(String id, VoidCallback changed) {
    final draft = _TextDraft(
      text,
      fontSize: double.tryParse(font),
      bold: bold,
      color: color,
      details: details == null
          ? null
          : WindowsOfficeTextDetails.fromJson(details!),
      targetKind: 'shape',
      id: id,
      onChanged: changed,
    );
    draft._updating = true;
    draft.text.selection = selection;
    draft._selection = selection;
    draft._acceptedValue = draft.text.value;
    if (draft.isRich) draft._syncStyleInputs();
    draft.font.text = font;
    draft._updating = false;
    return draft;
  }
}

class _PptShapeState {
  new(_ShapeDraft shape)
    : id = shape.id,
      text = _PptTextState(shape.text),
      editableText = shape.editableText,
      kind = shape.shapeKind,
      isNew = shape.isNew,
      geometry = {
        for (final entry in shape.geometry.entries) entry.key: entry.value.text,
      },
      fallbackGeometry = {
        for (final key in shape.geometry.keys) key: shape.value(key),
      },
      canEditFill = shape.canEditFill,
      canEditLine = shape.canEditLine,
      canEditGeometry = shape.canEditGeometry,
      canDelete = shape.canDelete,
      canEditTextStyle = shape.canEditTextStyle,
      presentationObject = shape.presentationObject,
      emptyPresentationObject = shape.emptyPresentationObject,
      fillStyle = shape.fillStyle,
      fillColor = shape.fillColor,
      lineStyle = shape.lineStyle,
      lineColor = shape.lineColor,
      lineWidth = shape.lineWidth.text,
      fallbackLineWidth =
          double.tryParse(shape.lineWidth.text)?.isFinite == true
          ? double.parse(shape.lineWidth.text)
          : shape.originalLineWidth ?? .5,
      image = shape.image,
      rotationHundredths = shape.rotationHundredths,
      assetId = shape.assetId,
      imageBytes = shape.imageBytes;
  final String id;
  final _PptTextState text;
  final bool editableText;
  final String? kind;
  final bool isNew;
  final Map<String, String> geometry;
  final Map<String, double> fallbackGeometry;
  final bool canEditFill,
      canEditLine,
      canEditGeometry,
      canDelete,
      canEditTextStyle;
  final bool? presentationObject, emptyPresentationObject;
  final String? fillStyle, lineStyle;
  final int? fillColor, lineColor;
  final String lineWidth;
  final double fallbackLineWidth;
  final WindowsOfficeImageDetails? image;
  final int? rotationHundredths;
  final String? assetId;
  final Uint8List? imageBytes;
  String get content => jsonEncode([
    id,
    text.text,
    text.font,
    text.bold,
    text.color,
    text.details,
    geometry,
    fillStyle,
    fillColor,
    lineStyle,
    lineColor,
    lineWidth,
    assetId,
    rotationHundredths,
  ]);
  _ShapeDraft restore(VoidCallback changed) {
    final shape = _ShapeDraft(
      id,
      editableText,
      text.restore(id, changed),
      Map.of(fallbackGeometry),
      shapeKind: kind,
      isNew: isNew,
      canEditFill: canEditFill,
      canEditLine: canEditLine,
      canEditGeometry: canEditGeometry,
      canDelete: canDelete,
      canEditTextStyle: canEditTextStyle,
      presentationObject: presentationObject,
      emptyPresentationObject: emptyPresentationObject,
      fillStyle: fillStyle,
      fillColor: fillColor,
      lineStyle: lineStyle,
      lineColor: lineColor,
      lineWidth: fallbackLineWidth,
      image: image,
      assetId: assetId,
      imageBytes: imageBytes,
    );
    for (final entry in geometry.entries) {
      shape.geometry[entry.key]!.text = entry.value;
    }
    shape.lineWidth.text = lineWidth;
    shape.rotationHundredths = rotationHundredths;
    return shape;
  }
}

class _PptOwnerState {
  new(_SlideDraft owner)
    : id = owner.id,
      name = owner.name,
      width = owner.width,
      height = owner.height,
      page = owner.previewPage,
      implicitShapeId = owner.implicitShapeId,
      backgroundStyle = owner.backgroundStyle,
      backgroundColor = owner.backgroundColor,
      masterId = owner.masterId,
      layoutCode = owner.layoutCode,
      designSha256 = owner.designSha256,
      visible = owner.visible,
      showMasterObjects = owner.showMasterObjects,
      tables = owner.presentationTables == null
          ? null
          : [
              for (final table in owner.presentationTables!)
                _PptTableState(table),
            ],
      tableCount = owner.presentationTableCount,
      tablesTruncated = owner.presentationTablesTruncated,
      tablesUnknownReason = owner.presentationTablesUnknownReason,
      canAddTable = owner.canAddTable,
      selectedTableId = owner.selectedTableId,
      selectedCellId = owner.selectedCellId,
      shapes = [for (final shape in owner.shapes) _PptShapeState(shape)];
  final String id;
  final String? name, implicitShapeId, backgroundStyle, masterId, designSha256;
  final double width, height;
  final int? page, backgroundColor, layoutCode;
  final bool? visible, showMasterObjects;
  final List<_PptShapeState> shapes;
  final List<_PptTableState>? tables;
  final int? tableCount;
  final bool tablesTruncated, canAddTable;
  final String? tablesUnknownReason, selectedTableId, selectedCellId;
  String get content => jsonEncode([
    id,
    backgroundStyle,
    backgroundColor,
    masterId,
    layoutCode,
    visible,
    showMasterObjects,
    for (final shape in shapes) shape.content,
    if (tables != null) [for (final table in tables!) table.content],
  ]);
  _SlideDraft restore(VoidCallback changed) => _SlideDraft(
    id,
    width,
    height,
    page,
    [for (final shape in shapes) shape.restore(changed)],
    name: name,
    implicitShapeId: implicitShapeId,
    backgroundStyle: backgroundStyle,
    backgroundColor: backgroundColor,
    masterId: masterId,
    layoutCode: layoutCode,
    designSha256: designSha256,
    visible: visible,
    showMasterObjects: showMasterObjects,
    presentationTables: tables == null
        ? null
        : [for (final table in tables!) table.restore(changed)],
    presentationTableCount: tableCount,
    presentationTablesTruncated: tablesTruncated,
    presentationTablesUnknownReason: tablesUnknownReason,
    canAddTable: canAddTable,
    selectedTableId: selectedTableId,
    selectedCellId: selectedCellId,
  );
}

class _PptCheckpoint {
  new(
    this.slides,
    this.masters,
    this.journal,
    this.assets,
    this.slideId,
    this.masterId,
    this.shapeId,
    this.layoutOptions,
  );
  final List<_PptOwnerState> slides, masters;
  final List<WindowsOfficeOperation> journal;
  final Map<String, WindowsOfficeImageAsset> assets;
  final String slideId;
  final String? masterId, shapeId;
  final List<WindowsOfficeLayoutOption> layoutOptions;
  Iterable<_PptOwnerState> get owners => [...slides, ...masters];
  String get content => jsonEncode([for (final owner in owners) owner.content]);
}

class _PptUndo {
  new(this.before, this.after, [this.textOwner]);
  final _PptCheckpoint before;
  _PptCheckpoint after;
  final Object? textOwner;
}

class _PendingPptDesign {
  new(this.before);
  final _PptCheckpoint before;
}

class _PresentationDraft {
  static final _aliasIndex = RegExp(r'^(0|[1-9][0-9]*)$');
  new(this.editor) {
    masters.addAll([
      for (final master in editor.widget.snapshot.masters!)
        _SlideDraft.fromMaster(master, editor._changed),
    ]);
    layoutOptions = editor.widget.snapshot.layoutOptions;
    _attach();
    _stable = _capture();
  }
  final WindowsOfficeEditorState editor;
  final masters = <_SlideDraft>[];
  final _journal = <WindowsOfficeOperation>[];
  final _observed = <Object, List<WindowsOfficeOperation>>{};
  final _usedIds = <String>{};
  final _undo = <_PptUndo>[], _redo = <_PptUndo>[];
  final _ownerSelections = <String, String?>{};
  late List<WindowsOfficeLayoutOption> layoutOptions;
  late _PptCheckpoint _stable;
  _PptCheckpoint? _batchBefore;
  _PendingPptDesign? _pending;
  String? editingMasterId;
  String? previewPath;
  String? _previewError;
  var previewing = false;
  var _restoring = false;
  var _disposed = false;
  var _version = 0;

  Iterable<_SlideDraft> get owners => [...editor._slides, ...masters];
  _SlideDraft get normalSlide => editor._slides[editor._selectedSlide];
  _SlideDraft get owner =>
      masters.where((item) => item.id == editingMasterId).singleOrNull ??
      normalSlide;
  bool get composing => owners.any(
    (owner) =>
        owner.shapes.any((shape) => shape.text._composing) ||
        (owner.presentationTables ?? <_PptTableDraft>[]).any(
          (table) => table.cells.any((cell) => cell.composing),
        ),
  );
  Iterable<_PptCellDraft> get sourceCells => [
    for (final owner in owners)
      for (final table in owner.presentationTables ?? <_PptTableDraft>[])
        ...table.cells,
  ];
  String? get sourceTextError => sourceCells
      .map((cell) => cell.lastEditError)
      .whereType<String>()
      .firstOrNull;
  _PptTableDraft? get selectedTable => editor._selectedShape != null
      ? null
      : owner.presentationTables
            ?.where((table) => table.baseline.id == owner.selectedTableId)
            .singleOrNull;
  _PptCellDraft? get selectedCell => selectedTable?.cells
      .where((cell) => cell.baseline.id == owner.selectedCellId)
      .singleOrNull;

  bool get hasSourceStructure =>
      _journal.any((op) => op.toJson()['op'] == 'presentationSourceTableAdd');
  bool get _sourceStructureOnly =>
      _journal.isNotEmpty &&
      _journal.every((op) => op.toJson()['op'] == 'presentationSourceTableAdd');
  WindowsOfficeSlide? get _sourceOwner => editor.widget.snapshot.slides
      .where((slide) => slide.id == normalSlide.id)
      .singleOrNull;
  bool get canAddSourceTable {
    final original = _sourceOwner;
    final authority = original?.sourceStructureAuthority;
    final count =
        (original?.presentationTableCount ?? 20) +
        _journal
            .where(
              (op) =>
                  op.toJson()['op'] == 'presentationSourceTableAdd' &&
                  op.toJson()['ownerId'] == original?.id,
            )
            .length;
    return !_disposed &&
        editingMasterId == null &&
        editor.widget.allowFormatting &&
        editor.widget.onPreview != null &&
        !editor._busy &&
        !editor._pickingImage &&
        !contextLocked &&
        (_journal.isEmpty || _sourceStructureOnly) &&
        _journal.length < 100 &&
        authority?.canAddTable == true &&
        authority?.sourceSha256 == editor.widget.snapshot.sourceSha256 &&
        count < 20;
  }

  Future<void> addSourceTable() async {
    if (!canAddSourceTable) return;
    final generation = editor._generation, version = _version;
    final original = _sourceOwner!;
    final authority = original.sourceStructureAuthority!;
    final size = await showDialog<_PptSourceTableSize>(
      context: editor.context,
      builder: (_) => _PptSourceTableDialog(
        slideWidth: normalSlide.width,
        slideHeight: normalSlide.height,
      ),
    );
    if (size == null ||
        _disposed ||
        !editor.mounted ||
        generation != editor._generation ||
        version != _version ||
        original.id != normalSlide.id ||
        !canAddSourceTable)
      return;
    final before = _capture();
    _journal.add(
      WindowsOfficeOperation.presentationSourceTableAdd(
        id: 'new-table-${freshId()}',
        ownerId: original.id,
        expectedSourceSha256: authority.sourceSha256,
        sourcePart: authority.sourcePart,
        expectedSourcePartSha256: authority.partSha256,
        expectedShapeIdInventorySha256: authority.shapeIdInventorySha256,
        xMm: size.x,
        yMm: size.y,
        columnWidthsMm: List<num>.filled(size.columns, size.columnWidth),
        rowHeightsMm: List<num>.filled(size.rows, size.rowHeight),
      ),
    );
    _pending = _PendingPptDesign(before);
    _version++;
    editor._changed();
    await refreshPreview();
  }

  void _verifyStructurePreview(WindowsOfficeDraftPreview result) {
    final proof = result.structuralPreview;
    final baseline = editor.widget.snapshot;
    if (!_sourceStructureOnly ||
        proof == null ||
        !identical(proof.snapshot, result.snapshot) ||
        proof.baseSourceSha256 != baseline.sourceSha256 ||
        proof.candidateSourceSha256 != result.snapshot.sourceSha256 ||
        proof.operationsSha256 != _pptOperationsHash(_journal) ||
        proof.additions.length != _journal.length) {
      throw const FormatException('요청한 표 추가와 일치하지 않는 미리보기입니다.');
    }
    final aliases = {for (final op in _journal) op.toJson()['id']: op.toJson()};
    final createdIds = <String>{};
    for (final addition in proof.additions) {
      final op = aliases.remove(addition.alias);
      final origin = baseline.slides
          .where((slide) => slide.id == addition.ownerId)
          .singleOrNull;
      final authority = origin?.sourceStructureAuthority;
      if (op == null ||
          authority?.canAddTable != true ||
          op['ownerId'] != addition.ownerId ||
          op['sourcePart'] != addition.sourcePart ||
          op['expectedSourceSha256'] != baseline.sourceSha256 ||
          op['expectedSourcePartSha256'] != authority!.partSha256 ||
          op['expectedShapeIdInventorySha256'] !=
              authority.shapeIdInventorySha256 ||
          !createdIds.add(addition.tableId)) {
        throw const FormatException('표 추가의 원본 문서나 소유자를 확인하지 못했습니다.');
      }
      final slide = result.snapshot.slides
          .where((slide) => slide.id == addition.ownerId)
          .single;
      final table = slide.presentationTables!
          .where((table) => table.id == addition.tableId)
          .single;
      final widths = [
        for (final value in op['columnWidthsMm'] as List)
          ((value as num) * 100).round() * 360,
      ];
      final heights = [
        for (final value in op['rowHeightsMm'] as List)
          ((value as num) * 100).round() * 360,
      ];
      final expectedGeometry = {
        'sourcePart': addition.sourcePart,
        'shapeId': addition.shapeId,
        'positionEmu': {
          'x': ((op['xMm'] as num) * 100).round() * 360,
          'y': ((op['yMm'] as num) * 100).round() * 360,
        },
        'extentEmu': {
          'width': widths.fold<int>(0, (a, b) => a + b),
          'height': heights.fold<int>(0, (a, b) => a + b),
        },
        'columnWidthsEmu': widths,
        'rowHeightsEmu': heights,
      };
      final shape = slide.shapes
          .where((shape) => shape.id == addition.tableId)
          .singleOrNull;
      final bounds = table.nativeBoundsHmm;
      if (table.rowCount != heights.length ||
          table.columnCount != widths.length ||
          !_pptSameValue(table.authoredGeometry, expectedGeometry) ||
          table.rowHeightsHmm.any((value) => value == null || value <= 0) ||
          table.columnWidthsHmm.any((value) => value == null || value <= 0) ||
          shape == null ||
          bounds == null ||
          shape.type != 'com.sun.star.drawing.TableShape' ||
          shape.text.isNotEmpty ||
          shape.editableText ||
          shape.canEditTextStyle ||
          shape.canEditGeometry ||
          shape.canDelete ||
          shape.canEditFill ||
          shape.canEditLine ||
          (shape.x * 100).round() != bounds['x'] ||
          (shape.y * 100).round() != bounds['y'] ||
          (shape.width * 100).round() != bounds['width'] ||
          (shape.height * 100).round() != bounds['height']) {
        throw const FormatException('생성된 표의 셀이나 크기가 요청과 일치하지 않습니다.');
      }
    }
    if (aliases.isNotEmpty) {
      throw const FormatException('요청한 표 일부가 미리보기에 없습니다.');
    }
    Object slideCore(WindowsOfficeSlide slide) => [
      slide.id,
      slide.width,
      slide.height,
      slide.backgroundStyle,
      slide.backgroundColor,
      slide.masterId,
      slide.layoutCode,
      slide.designSha256,
      slide.visible,
      slide.showMasterObjects,
      slide.canAddTable,
      slide.presentationTablesTruncated,
      slide.presentationTablesUnknownReason,
      [
        for (final shape in slide.shapes)
          if (!createdIds.contains(shape.id)) _pptNativeShape(shape),
      ],
      [
        for (final table
            in slide.presentationTables ?? <WindowsOfficePresentationTable>[])
          if (!createdIds.contains(table.id))
            _pptStructureTable(table, sourceSha256: baseline.sourceSha256),
      ],
    ];
    Object masterCore(WindowsOfficeMaster master) => [
      master.id,
      master.name,
      master.width,
      master.height,
      master.backgroundStyle,
      master.backgroundColor,
      master.presentationTableCount,
      master.presentationTablesTruncated,
      master.presentationTablesUnknownReason,
      master.canAddTable,
      [for (final shape in master.shapes) _pptNativeShape(shape)],
      [
        for (final table
            in master.presentationTables ?? <WindowsOfficePresentationTable>[])
          _pptStructureTable(table, sourceSha256: baseline.sourceSha256),
      ],
    ];
    if (!_pptSameValue(
          [for (final slide in baseline.slides) slideCore(slide)],
          [for (final slide in result.snapshot.slides) slideCore(slide)],
        ) ||
        !_pptSameValue(
          [for (final master in baseline.masters!) masterCore(master)],
          [for (final master in result.snapshot.masters!) masterCore(master)],
        ) ||
        !_pptSameValue(
          [
            for (final option in baseline.layoutOptions)
              [option.code, option.label],
          ],
          [
            for (final option in result.snapshot.layoutOptions)
              [option.code, option.label],
          ],
        )) {
      throw const FormatException('표 추가 외의 문서 정보가 달라 미리보기를 사용하지 않았습니다.');
    }
    for (final original in baseline.slides) {
      final returned = result.snapshot.slides
          .where((slide) => slide.id == original.id)
          .single;
      final additions = proof.additions
          .where((item) => item.ownerId == original.id)
          .length;
      final originalCount = original.presentationTableCount;
      if (additions == 0 && returned.presentationTableCount != originalCount ||
          additions > 0 &&
              (originalCount == null ||
                  returned.presentationTableCount !=
                      originalCount + additions ||
                  returned.presentationTables?.length !=
                      originalCount + additions ||
                  originalCount + additions > 20) ||
          returned.shapes.length != original.shapes.length + additions) {
        throw const FormatException('표 목록과 실제 생성된 표의 수가 일치하지 않습니다.');
      }
    }
  }

  bool get _hasSourceText =>
      _journal.any((op) => op.toJson()['op'] == 'presentationCellTextPatch');
  bool get _sourceTextOnly =>
      _journal.isNotEmpty &&
      _journal.every((op) => op.toJson()['op'] == 'presentationCellTextPatch');
  bool canEditCell(_PptCellDraft cell) =>
      editingMasterId == null &&
      !editor._busy &&
      !locked &&
      cell.canReplace &&
      _journal.every((op) => op.toJson()['op'] == 'presentationCellTextPatch');

  void selectTable(String id) {
    if (editor._pptContextLocked) return;
    final table = owner.presentationTables
        ?.where((table) => table.baseline.id == id)
        .singleOrNull;
    if (table == null) return;
    if (owner.selectedTableId != id) {
      for (final cell in sourceCells) cell.finishTyping();
    }
    editor._selectedShape = null;
    owner.selectedTableId = id;
    if (!table.cells.any((cell) => cell.baseline.id == owner.selectedCellId))
      owner.selectedCellId = null;
    selectionChanged();
    editor._rebuildPresentation(() {});
  }

  void selectCell(String id) {
    if (editor._pptContextLocked ||
        selectedTable == null ||
        !selectedTable!.cells.any((cell) => cell.baseline.id == id))
      return;
    if (owner.selectedCellId != id) {
      for (final cell in sourceCells) cell.finishTyping();
    }
    owner.selectedCellId = id;
    selectionChanged();
    editor._rebuildPresentation(() {});
  }

  bool get locked => previewing || _pending != null;
  bool get contextLocked => locked || composing;
  bool get canUndo =>
      !previewing && !composing && (_pending != null || _undo.isNotEmpty);
  bool get canRedo => !locked && !composing && _redo.isNotEmpty;
  List<WindowsOfficeOperation> get operations => List.unmodifiable(_journal);
  Set<String> get pinnedAssets => {
    for (final operation in _journal)
      if (operation.toJson()['assetId'] case final String id) id,
    for (final change in [..._undo, ..._redo]) ...[
      ...change.before.assets.keys,
      ...change.after.assets.keys,
    ],
    ...?_batchBefore?.assets.keys,
    ...?_pending?.before.assets.keys,
  };

  String freshId() {
    var id = newId();
    while (!_usedIds.add(id)) id = newId();
    return id;
  }

  void _attach() {
    _observed.clear();
    for (final owner in owners) {
      _usedIds.add(owner.id);
      for (final table in owner.presentationTables ?? <_PptTableDraft>[]) {
        _usedIds.add(table.baseline.id);
        for (final cell in table.cells) {
          _usedIds.add(cell.baseline.id);
          _observed[cell.key] = List.of(cell.operations);
          cell.canEdit = () => canEditCell(cell);
          cell.canMergePrevious = () =>
              cell.operations.isNotEmpty &&
              _journal.isNotEmpty &&
              identical(_journal.last, cell.operations.last);
        }
      }
      for (final shape in owner.shapes) {
        _usedIds.add(shape.id);
        _observed[shape.id] = List.of(shape.text.operations);
        shape.text.canMergePrevious = () =>
            shape.text.operations.isNotEmpty &&
            _journal.isNotEmpty &&
            identical(_journal.last, shape.text.operations.last);
      }
    }
  }

  _PptCheckpoint _capture() => _PptCheckpoint(
    [for (final slide in editor._slides) _PptOwnerState(slide)],
    [for (final master in masters) _PptOwnerState(master)],
    List.of(_journal),
    Map.of(editor._imageAssets),
    normalSlide.id,
    editingMasterId,
    editor._selectedShape,
    layoutOptions,
  );

  void _remember(
    _PptCheckpoint before,
    _PptCheckpoint after, [
    Object? textOwner,
  ]) {
    _undo.add(_PptUndo(before, after, textOwner));
    if (_undo.length > 100) _undo.removeAt(0);
    _redo.clear();
  }

  void action(VoidCallback change, {String? movedSlideId}) {
    if (_disposed || contextLocked || hasSourceStructure) return;
    final outer = _batchBefore != null;
    _batchBefore ??= _capture();
    try {
      change();
      editor._changed(movedSlideId: movedSlideId);
    } finally {
      if (!outer) endGesture();
    }
  }

  void beginGesture() {
    if (!_disposed && !contextLocked) _batchBefore ??= _capture();
  }

  void endGesture() {
    final before = _batchBefore;
    if (before == null || _disposed) return;
    _batchBefore = null;
    final after = _capture();
    if (before.content != after.content ||
        !_sameJournal(before.journal, after.journal)) {
      _remember(before, after);
    }
    _stable = after;
    editor._pruneAssets();
  }

  static bool _sameJournal(
    List<WindowsOfficeOperation> left,
    List<WindowsOfficeOperation> right,
  ) {
    if (left.length != right.length) return false;
    for (var i = 0; i < left.length; i++) {
      if (!identical(left[i], right[i])) return false;
    }
    return true;
  }

  String? _aliasChangeId(String identifier, String kind, Set<String> changes) {
    if (identifier.length > 256) return null;
    for (final change in changes) {
      final prefix = '$change/$kind-';
      if (identifier.startsWith(prefix) &&
          _aliasIndex.hasMatch(identifier.substring(prefix.length))) {
        return change;
      }
    }
    return null;
  }

  void record({String? movedSlideId}) {
    if (_disposed ||
        _restoring ||
        locked ||
        composing ||
        editor._slides.isEmpty)
      return;
    final before = _stable;
    final oldOwners = {for (final item in before.owners) item.id: item};
    final logical = before.slides.map((slide) => slide.id).toList();
    for (final old in before.slides) {
      if (!editor._slides.any((slide) => slide.id == old.id)) {
        _journal.add(WindowsOfficeOperation.slideDelete(old.id));
        logical.remove(old.id);
      }
    }
    if (movedSlideId != null) {
      final from = logical.indexOf(movedSlideId);
      final to = editor._slides.indexWhere((slide) => slide.id == movedSlideId);
      if (from >= 0 && to >= 0 && to < logical.length && from != to) {
        // A permutation can be reproduced by moving a neighbor instead, but
        // that would give the neighbor the destination section on save.
        _journal.add(WindowsOfficeOperation.slideMove(movedSlideId, to));
        logical.insert(to, logical.removeAt(from));
      }
    }
    for (var index = 0; index < editor._slides.length; index++) {
      final slide = editor._slides[index];
      if (!logical.contains(slide.id)) {
        final implicit = slide.shapes
            .where((shape) => shape.id == slide.implicitShapeId)
            .singleOrNull;
        _journal.add(
          WindowsOfficeOperation.slideAdd(
            id: slide.id,
            index: index,
            text: implicit?.text.text.text ?? '',
          ),
        );
        logical.insert(index, slide.id);
      } else if (logical[index] != slide.id) {
        _journal.add(WindowsOfficeOperation.slideMove(slide.id, index));
        logical.remove(slide.id);
        logical.insert(index, slide.id);
      }
    }
    Object? textOwner;
    var merged = false;
    for (final current in owners) {
      final old = oldOwners[current.id];
      for (final table in current.presentationTables ?? <_PptTableDraft>[]) {
        for (final cell in table.cells) {
          final observed =
              _observed[cell.key] ?? const <WindowsOfficeOperation>[];
          final currentOps = cell.operations;
          var prefix = 0;
          while (prefix < observed.length &&
              prefix < currentOps.length &&
              identical(observed[prefix], currentOps[prefix]))
            prefix++;
          if (prefix != observed.length || prefix != currentOps.length) {
            final replaceLast =
                currentOps.length == observed.length &&
                prefix == currentOps.length - 1 &&
                _journal.isNotEmpty &&
                identical(_journal.last, observed.last);
            if (replaceLast) {
              _journal[_journal.length - 1] = currentOps[prefix];
              merged = true;
            } else {
              _journal.addAll(currentOps.skip(prefix));
            }
            textOwner = cell.key;
            _observed[cell.key] = List.of(currentOps);
          }
        }
      }
      if (old != null &&
          (old.backgroundStyle != current.backgroundStyle ||
              old.backgroundColor != current.backgroundColor)) {
        _journal.add(
          WindowsOfficeOperation.slideBackground(
            current.id,
            fillStyle: old.backgroundStyle != current.backgroundStyle
                ? current.backgroundStyle
                : null,
            fillColor: old.backgroundColor != current.backgroundColor
                ? current.backgroundColor
                : null,
          ),
        );
      }
      if (old != null &&
          (old.visible != current.visible ||
              old.showMasterObjects != current.showMasterObjects)) {
        _journal.add(
          WindowsOfficeOperation.slideDisplay(
            id: current.id,
            visible: old.visible != current.visible ? current.visible : null,
            showMasterObjects:
                old.showMasterObjects != current.showMasterObjects
                ? current.showMasterObjects
                : null,
          ),
        );
      }
      final oldShapes = {
        for (final shape in old?.shapes ?? <_PptShapeState>[]) shape.id: shape,
      };
      for (final shape in old?.shapes ?? <_PptShapeState>[]) {
        if (!current.shapes.any((candidate) => candidate.id == shape.id)) {
          _journal.add(WindowsOfficeOperation.shapeDelete(shape.id));
          _observed.remove(shape.id);
        }
      }
      for (final shape in current.shapes) {
        final previous = oldShapes[shape.id];
        if (previous == null) {
          if (shape.id != current.implicitShapeId) {
            _journal.add(
              shape.shapeKind == 'image'
                  ? WindowsOfficeOperation.imageAdd(
                      id: shape.id,
                      slideId: current.id,
                      assetId: shape.assetId!,
                      x: shape.value('x'),
                      y: shape.value('y'),
                      width: shape.value('width'),
                      height: shape.value('height'),
                    )
                  : WindowsOfficeOperation.shapeAdd(
                      id: shape.id,
                      slideId: current.id,
                      shapeKind: shape.shapeKind ?? 'text',
                      x: shape.value('x'),
                      y: shape.value('y'),
                      width: shape.value('width'),
                      height: shape.value('height'),
                      text: shape.text.text.text,
                    ),
            );
          } else if (editor.widget.allowFormatting) {
            _journal.add(
              WindowsOfficeOperation.shapeStyle(
                shape.id,
                fontSize: double.tryParse(shape.text.font.text),
                bold: shape.text.bold,
                color: shape.text.color,
              ),
            );
          }
          _observed[shape.id] = List.of(shape.text.operations);
          shape.text.canMergePrevious = () =>
              shape.text.operations.isNotEmpty &&
              _journal.isNotEmpty &&
              identical(_journal.last, shape.text.operations.last);
          continue;
        }
        if (shape.text.isRich) {
          final observed =
              _observed[shape.id] ?? const <WindowsOfficeOperation>[];
          final currentOps = shape.text.operations;
          var prefix = 0;
          while (prefix < observed.length &&
              prefix < currentOps.length &&
              identical(observed[prefix], currentOps[prefix]))
            prefix++;
          if (prefix != observed.length || prefix != currentOps.length) {
            final replaceLast =
                currentOps.length == observed.length &&
                prefix == currentOps.length - 1 &&
                _journal.isNotEmpty &&
                identical(_journal.last, observed.last);
            if (replaceLast) {
              _journal[_journal.length - 1] = currentOps[prefix];
              merged = true;
            } else {
              _journal.addAll(currentOps.skip(prefix));
            }
            textOwner = shape.id;
            _observed[shape.id] = List.of(currentOps);
          }
        } else if (shape.editableText &&
            previous.text.text != shape.text.text.text) {
          final operation = WindowsOfficeOperation.shapeText(
            shape.id,
            shape.text.text.text,
          );
          if (_journal.lastOrNull?.toJson()
              case {'op': 'shapeText', 'id': final String id}
              when id == shape.id) {
            _journal[_journal.length - 1] = operation;
            merged = true;
          } else {
            _journal.add(operation);
          }
          textOwner = shape.id;
        }
        final font = double.tryParse(shape.text.font.text);
        final fontChanged =
            previous.text.font != shape.text.font.text &&
            font != null &&
            font.isFinite &&
            font >= 1 &&
            font <= 400;
        final boldChanged = previous.text.bold != shape.text.bold;
        final colorChanged = previous.text.color != shape.text.color;
        if (shape.canEditTextStyle &&
            !shape.text.isRich &&
            (fontChanged || boldChanged || colorChanged)) {
          _journal.add(
            WindowsOfficeOperation.shapeStyle(
              shape.id,
              fontSize: fontChanged ? font : null,
              bold: boldChanged ? shape.text.bold : null,
              color: colorChanged ? shape.text.color : null,
            ),
          );
        }
        if (shape.assetId != null && shape.assetId != previous.assetId) {
          _journal.add(
            WindowsOfficeOperation.imageReplace(
              id: shape.id,
              assetId: shape.assetId!,
            ),
          );
        }
        try {
          shape.validateGeometry();
          if (shape.canEditGeometry &&
              shape.geometry.entries.any(
                (entry) => entry.value.text != previous.geometry[entry.key],
              )) {
            final operation = WindowsOfficeOperation.shapeGeometry(
              shape.id,
              x: shape.value('x'),
              y: shape.value('y'),
              width: shape.value('width'),
              height: shape.value('height'),
            );
            if (_journal.lastOrNull?.toJson()
                case {'op': 'shapeGeometry', 'id': final String id}
                when id == shape.id) {
              _journal[_journal.length - 1] = operation;
            } else {
              _journal.add(operation);
            }
          }
        } on FormatException {
          // The raw input remains in the checkpoint until it is valid.
        }
        final rotation = shape.rotationHundredths;
        final previousRotation = previous.rotationHundredths;
        if (rotation != null &&
            previousRotation != null &&
            rotation != previousRotation) {
          _journal.add(
            WindowsOfficeOperation.imageRotate(
              id: shape.id,
              expectedRotationHundredths: previousRotation,
              rotationHundredths: rotation,
            ),
          );
        }
        final fillStyle =
            shape.canEditFill && shape.fillStyle != previous.fillStyle
            ? shape.fillStyle
            : null;
        final fillColor =
            shape.canEditFill && shape.fillColor != previous.fillColor
            ? shape.fillColor
            : null;
        final lineStyle =
            shape.canEditLine && shape.lineStyle != previous.lineStyle
            ? shape.lineStyle
            : null;
        final lineColor =
            shape.canEditLine && shape.lineColor != previous.lineColor
            ? shape.lineColor
            : null;
        final parsedLineWidth = double.tryParse(shape.lineWidth.text);
        final lineWidth =
            shape.canEditLine &&
                shape.lineWidth.text != previous.lineWidth &&
                parsedLineWidth != null &&
                parsedLineWidth.isFinite &&
                parsedLineWidth >= 0 &&
                parsedLineWidth <= 100
            ? parsedLineWidth
            : null;
        if (fillStyle != null ||
            fillColor != null ||
            lineStyle != null ||
            lineColor != null ||
            lineWidth != null) {
          _journal.add(
            WindowsOfficeOperation.shapeAppearance(
              shape.id,
              fillStyle: fillStyle,
              fillColor: fillColor,
              lineStyle: lineStyle,
              lineColor: lineColor,
              lineWidth: lineWidth,
            ),
          );
        }
      }
    }
    final after = _capture();
    final changed =
        before.content != after.content ||
        !_sameJournal(before.journal, after.journal);
    if (changed) {
      _version++;
      previewPath = null;
      editor._showOriginalSlide = false;
      if (_batchBefore == null) {
        if (merged &&
            textOwner != null &&
            _undo.lastOrNull?.textOwner == textOwner &&
            _redo.isEmpty) {
          _undo.last.after = after;
        } else {
          _remember(before, after, textOwner);
        }
      }
    }
    _stable = after;
  }

  void selectionChanged() {
    if (!_disposed && !composing && !locked) _stable = _capture();
  }

  void switchSlide(int index) {
    if (editor._pptContextLocked || index < 0 || index >= editor._slides.length)
      return;
    _ownerSelections[owner.id] = editor._selectedShape;
    editingMasterId = null;
    editor._selectedSlide = index;
    editor._selectedShape = _ownerSelections[owner.id];
    if (!owner.shapes.any((shape) => shape.id == editor._selectedShape))
      editor._selectedShape = null;
    editor._showOriginalSlide = false;
    selectionChanged();
    editor._rebuildPresentation(() {});
  }

  void editMaster() {
    if (editor._pptContextLocked) return;
    final id = normalSlide.masterId;
    if (id == null || !masters.any((master) => master.id == id)) return;
    _ownerSelections[owner.id] = editor._selectedShape;
    editingMasterId = id;
    editor._selectedShape = _ownerSelections[id];
    if (!owner.shapes.any((shape) => shape.id == editor._selectedShape))
      editor._selectedShape = null;
    editor._showOriginalSlide = false;
    selectionChanged();
    editor._rebuildPresentation(() {});
  }

  void returnToSlide() {
    if (editor._pptContextLocked) return;
    _ownerSelections[owner.id] = editor._selectedShape;
    editingMasterId = null;
    editor._selectedShape = _ownerSelections[owner.id];
    if (!owner.shapes.any((shape) => shape.id == editor._selectedShape))
      editor._selectedShape = null;
    editor._showOriginalSlide = false;
    selectionChanged();
    editor._rebuildPresentation(() {});
  }

  void _restore(_PptCheckpoint checkpoint) {
    FocusManager.instance.primaryFocus?.unfocus();
    for (final owner in owners) owner.dispose();
    editor._slides
      ..clear()
      ..addAll([
        for (final owner in checkpoint.slides) owner.restore(editor._changed),
      ]);
    masters
      ..clear()
      ..addAll([
        for (final owner in checkpoint.masters) owner.restore(editor._changed),
      ]);
    _journal
      ..clear()
      ..addAll(checkpoint.journal);
    editor._imageAssets.addAll(checkpoint.assets);
    layoutOptions = checkpoint.layoutOptions;
    editor._selectedSlide = math.max(
      0,
      editor._slides.indexWhere((slide) => slide.id == checkpoint.slideId),
    );
    editingMasterId = checkpoint.masterId;
    editor._selectedShape = checkpoint.shapeId;
    previewPath = null;
    editor._showOriginalSlide = false;
    _attach();
    _stable = _capture();
    _version++;
    final version = _version;
    final ownerId = owner.id;
    final selected = owner.shapes
        .where((shape) => shape.id == editor._selectedShape)
        .singleOrNull;
    final selectedSourceCell = selectedCell;
    if (selectedSourceCell != null && canEditCell(selectedSourceCell)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_disposed &&
            editor.mounted &&
            version == _version &&
            owner.id == ownerId &&
            identical(selectedCell, selectedSourceCell) &&
            !editor._pptEditingLocked)
          selectedSourceCell.focus.requestFocus();
      });
    }
    if (selected != null && selected.editableText) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_disposed &&
            editor.mounted &&
            version == _version &&
            owner.id == ownerId &&
            editor._selectedShape == selected.id &&
            owner.shapes.contains(selected) &&
            !editor._pptEditingLocked) {
          selected.textFocus.requestFocus();
        }
      });
    }
  }

  void undo() {
    if (!canUndo || editor._busy || editor._pickingImage) return;
    _restoring = true;
    try {
      final pending = _pending;
      if (pending != null) {
        _pending = null;
        _previewError = null;
        _restore(pending.before);
      } else {
        final change = _undo.removeLast();
        _redo.add(change);
        _restore(change.before);
      }
    } finally {
      _restoring = false;
    }
    editor._pruneAssets();
    editor._changed();
  }

  void redo() {
    if (!canRedo || editor._busy || editor._pickingImage) return;
    final change = _redo.removeLast();
    _restoring = true;
    try {
      _undo.add(change);
      _restore(change.after);
    } finally {
      _restoring = false;
    }
    editor._pruneAssets();
    editor._changed();
  }

  void validate() {
    if (locked) throw const FormatException('미리보기를 완료하거나 변경을 되돌린 뒤 저장하세요.');
    if (hasSourceStructure && !_sourceStructureOnly) {
      throw const FormatException('표 추가와 다른 변경은 각각 저장하세요.');
    }
    if (composing) throw const FormatException('입력 중인 글자를 완성한 뒤 저장하세요.');
    if (_hasSourceText && !_sourceTextOnly) {
      throw const FormatException('표 내용 변경과 다른 개체 변경은 각각 저장하세요.');
    }
    if (_hasSourceText && _journal.length > 100)
      throw const FormatException('변경 내용이 많습니다. 먼저 저장한 뒤 계속 편집하세요.');
  }

  Future<void> design({String? masterId, int? layoutCode}) async {
    if (editor._pptContextLocked ||
        hasSourceStructure ||
        !editor.widget.allowFormatting ||
        editor.widget.onPreview == null ||
        editingMasterId != null)
      return;
    final slide = normalSlide;
    if (slide.designSha256 == null ||
        masterId != null && masterId == slide.masterId ||
        layoutCode != null && layoutCode == slide.layoutCode)
      return;
    try {
      editor._validateDrafts();
    } catch (error) {
      editor._rebuildPresentation(() => editor._error = '$error');
      return;
    }
    record();
    final before = _capture();
    _journal.add(
      WindowsOfficeOperation.slideDesign(
        id: slide.id,
        changeId: freshId(),
        expectedDesignSha256: slide.designSha256!,
        masterId: masterId,
        layoutCode: layoutCode,
      ),
    );
    _pending = _PendingPptDesign(before);
    _version++;
    editor._changed();
    await refreshPreview();
  }

  void _verifySourcePreview(WindowsOfficeSnapshot snapshot) {
    final baseline = editor.widget.snapshot;
    Object? tableMetadata(List<WindowsOfficePresentationTable>? tables) =>
        tables == null
        ? null
        : {for (final table in tables) table.id: _pptNativeTable(table)};
    Object slideMetadata(WindowsOfficeSlide slide) => [
      slide.id,
      slide.width,
      slide.height,
      slide.backgroundStyle,
      slide.backgroundColor,
      slide.masterId,
      slide.layoutCode,
      slide.designSha256,
      slide.visible,
      slide.showMasterObjects,
      slide.presentationTableCount,
      slide.presentationTablesTruncated,
      slide.presentationTablesUnknownReason,
      slide.canAddTable,
      tableMetadata(slide.presentationTables),
      [for (final shape in slide.shapes) _pptNativeShape(shape)],
    ];
    Object masterMetadata(WindowsOfficeMaster master) => [
      master.id,
      master.name,
      master.width,
      master.height,
      master.backgroundStyle,
      master.backgroundColor,
      master.presentationTableCount,
      master.presentationTablesTruncated,
      master.presentationTablesUnknownReason,
      master.canAddTable,
      tableMetadata(master.presentationTables),
      [for (final shape in master.shapes) _pptNativeShape(shape)],
    ];
    if (snapshot.sourceSha256 != baseline.sourceSha256 ||
        !_pptSameValue(
          [for (final slide in baseline.slides) slideMetadata(slide)],
          [for (final slide in snapshot.slides) slideMetadata(slide)],
        ) ||
        !_pptSameValue(
          [for (final master in baseline.masters!) masterMetadata(master)],
          [for (final master in snapshot.masters!) masterMetadata(master)],
        ) ||
        !_pptSameValue(
          [
            for (final option in baseline.layoutOptions)
              [option.code, option.label],
          ],
          [
            for (final option in snapshot.layoutOptions)
              [option.code, option.label],
          ],
        )) {
      throw const FormatException('미리보기의 표나 개체 정보가 현재 문서와 일치하지 않습니다.');
    }
    final returned = {
      for (final slide in snapshot.slides)
        for (final table
            in slide.presentationTables ?? <WindowsOfficePresentationTable>[])
          (slide.id, table.id): table,
      for (final master in snapshot.masters!)
        for (final table
            in master.presentationTables ?? <WindowsOfficePresentationTable>[])
          (master.id, table.id): table,
    };
    for (final owner in owners) {
      for (final table in owner.presentationTables ?? <_PptTableDraft>[]) {
        final actual = returned[(owner.id, table.baseline.id)];
        if (actual == null)
          throw const FormatException('미리보기에서 원래 표를 확인하지 못했습니다.');
        final cells = {for (final cell in actual.cells) cell.id: cell};
        for (final cell in table.cells) {
          final actualCell = cells[cell.baseline.id];
          if (actualCell == null ||
              !_pptSameSourceMap(cell.current, actualCell.sourceTextPatch)) {
            throw const FormatException(
              '미리보기의 셀 내용이나 편집 범위가 요청한 변경과 일치하지 않습니다.',
            );
          }
        }
      }
    }
  }

  void _acceptSourcePreview(WindowsOfficeSnapshot snapshot) {
    final returned = {
      for (final slide in snapshot.slides)
        for (final table
            in slide.presentationTables ?? <WindowsOfficePresentationTable>[])
          for (final cell in table.cells)
            (slide.id, table.id, cell.id): cell.sourceTextPatch,
      for (final master in snapshot.masters!)
        for (final table
            in master.presentationTables ?? <WindowsOfficePresentationTable>[])
          for (final cell in table.cells)
            (master.id, table.id, cell.id): cell.sourceTextPatch,
    };
    for (final cell in sourceCells) cell.adopt(returned[cell.key]);
  }

  Future<void> refreshPreview() async {
    final callback = editor.widget.onPreview;
    if (_disposed ||
        previewing ||
        composing ||
        editor._busy ||
        editor._pickingImage ||
        callback == null)
      return;
    if (_pending == null) {
      try {
        editor._validateDrafts();
      } catch (error) {
        editor._rebuildPresentation(() => editor._error = '$error');
        return;
      }
      record();
    }
    final generation = editor._generation, version = _version;
    final source = editor.widget.snapshot.sourceSha256;
    final formatting = editor.widget.allowFormatting;
    final ownerId = owner.id;
    final selected = editor._selectedShape;
    final selections = {
      for (final owner in owners)
        for (final shape in owner.shapes) shape.id: shape.text._selection,
    };
    previewPath = null;
    previewing = true;
    _previewError = null;
    editor._rebuildPresentation(() => editor._error = null);
    bool current() =>
        !_disposed &&
        editor.mounted &&
        identical(editor._pptDraft, this) &&
        generation == editor._generation &&
        source == editor.widget.snapshot.sourceSha256 &&
        formatting == editor.widget.allowFormatting &&
        version == _version &&
        owner.id == ownerId;
    try {
      final assetIds = {
        for (final operation in _journal)
          if (operation.toJson()['assetId'] case final String id) id,
      };
      final assets = {for (final id in assetIds) id: editor._imageAssets[id]!};
      final result = await callback(
        List.unmodifiable(_journal),
        Map.unmodifiable(assets),
      );
      if (!current()) return;
      if (result.baseSourceSha256 != source ||
          result.snapshot.kind != 'presentation' ||
          result.snapshot.masters == null ||
          result.signature.isEmpty ||
          result.pdfPath.isEmpty ||
          !listEquals(
            result.snapshot.slides.map((slide) => slide.id).toList(),
            editor._slides.map((slide) => slide.id).toList(),
          )) {
        throw const FormatException('현재 문서와 일치하지 않는 디자인 미리보기입니다.');
      }
      if (_sourceStructureOnly) {
        _verifyStructurePreview(result);
      } else if (result.structuralPreview != null) {
        throw const FormatException('표 추가가 아닌 변경에 구조 미리보기를 사용할 수 없습니다.');
      }
      final existingMasters = masters.map((master) => master.id).toSet();
      final returnedMasters = result.snapshot.masters!
          .map((master) => master.id)
          .toSet();
      if (!returnedMasters.containsAll(existingMasters)) {
        throw const FormatException('공통 디자인 목록이 현재 문서와 일치하지 않습니다.');
      }
      final changes = <String>{
        for (final operation in _journal)
          if (operation.toJson() case {
            'op': 'slideDesign',
            'changeId': final String id,
          })
            id,
      };
      for (final master in result.snapshot.masters!) {
        if (existingMasters.contains(master.id)) continue;
        final change = _aliasChangeId(master.id, 'master', changes);
        if (change == null || _usedIds.contains(master.id)) {
          throw const FormatException('현재 디자인 변경에서 생성한 공통 디자인이 아닙니다.');
        }
        for (final shape in master.shapes) {
          if (shape.ownerKind != 'master' ||
              shape.ownerId != master.id ||
              _usedIds.contains(shape.id) ||
              _aliasChangeId(shape.id, 'shape', {change}) != change) {
            throw const FormatException('새 공통 디자인 개체의 소유자를 확인하지 못했습니다.');
          }
        }
      }
      for (final slide in result.snapshot.slides) {
        if (slide.masterId != null &&
            !returnedMasters.contains(slide.masterId)) {
          throw const FormatException('슬라이드의 공통 디자인이 미리보기 목록에 없습니다.');
        }
      }
      final ids = <String>{};
      for (final page in result.snapshot.slides) {
        if (!ids.add(page.id)) throw const FormatException('중복된 슬라이드입니다.');
      }
      for (final page in result.snapshot.masters!) {
        if (!ids.add(page.id)) throw const FormatException('중복된 공통 디자인입니다.');
      }
      void verifyShapes(
        String ownerId,
        String kind,
        List<WindowsOfficeShape> shapes,
      ) {
        for (final shape in shapes) {
          if (!ids.add(shape.id) ||
              shape.ownerId != null && shape.ownerId != ownerId ||
              shape.ownerKind != null && shape.ownerKind != kind) {
            throw const FormatException('개체의 소유자가 현재 문서와 일치하지 않습니다.');
          }
        }
      }

      for (final slide in result.snapshot.slides)
        verifyShapes(slide.id, 'slide', slide.shapes);
      for (final master in result.snapshot.masters!)
        verifyShapes(master.id, 'master', master.shapes);
      if (_sourceTextOnly || _journal.isEmpty) {
        _verifySourcePreview(result.snapshot);
        _acceptSourcePreview(result.snapshot);
        previewPath = result.pdfPath;
        previewing = false;
        final after = _capture();
        final last = _undo.lastOrNull;
        if (last != null && _sameJournal(last.after.journal, _journal))
          last.after = after;
        final next = _redo.lastOrNull;
        if (next != null && _sameJournal(next.before.journal, _journal)) {
          _redo[_redo.length - 1] = _PptUndo(after, next.after, next.textOwner);
        }
        _stable = after;
        editor._showOriginalSlide = false;
        editor._changed();
        return;
      }
      final tableSelections = {
        for (final owner in owners)
          owner.id: (owner.selectedTableId, owner.selectedCellId),
      };
      final nextSlides = <_SlideDraft>[], nextMasters = <_SlideDraft>[];
      try {
        nextSlides.addAll([
          for (var i = 0; i < result.snapshot.slides.length; i++)
            _SlideDraft.fromSnapshot(
              result.snapshot.slides[i],
              i + 1,
              editor._changed,
            ),
        ]);
        nextMasters.addAll([
          for (final master in result.snapshot.masters!)
            _SlideDraft.fromMaster(master, editor._changed),
        ]);
      } catch (_) {
        for (final page in [...nextSlides, ...nextMasters]) page.dispose();
        rethrow;
      }
      final slideId = normalSlide.id;
      final pending = _pending;
      _restoring = true;
      for (final owner in owners) owner.dispose();
      editor._slides
        ..clear()
        ..addAll(nextSlides);
      masters
        ..clear()
        ..addAll(nextMasters);
      editor._selectedSlide = editor._slides.indexWhere(
        (slide) => slide.id == slideId,
      );
      editor._selectedShape = selected;
      if (!owner.shapes.any((shape) => shape.id == selected))
        editor._selectedShape = null;
      for (final owner in owners) {
        final selectedTable = tableSelections[owner.id];
        if (selectedTable != null &&
            owner.presentationTables?.any(
                  (table) => table.baseline.id == selectedTable.$1,
                ) ==
                true) {
          owner.selectedTableId = selectedTable.$1;
          owner.selectedCellId = selectedTable.$2;
        }
        for (final shape in owner.shapes) {
          final selection = selections[shape.id];
          if (selection != null &&
              selection.isValid &&
              selection.end <= shape.text.text.text.length) {
            shape.text._updating = true;
            shape.text.text.selection = selection;
            shape.text._selection = selection;
            shape.text._acceptedValue = shape.text.text.value;
            shape.text._updating = false;
          }
        }
      }
      layoutOptions = result.snapshot.layoutOptions;
      _attach();
      previewPath = result.pdfPath;
      _pending = null;
      previewing = false;
      _restoring = false;
      final after = _capture();
      if (pending != null) _remember(pending.before, after);
      _stable = after;
      editor._showOriginalSlide = false;
      editor._changed();
    } catch (error) {
      if (current()) {
        _restoring = false;
        _previewError = '미리보기를 만들지 못했습니다. 편집 내용은 남아 있습니다.\n$error';
      }
    } finally {
      if (!_disposed && editor.mounted && generation == editor._generation) {
        previewing = false;
        editor._rebuildPresentation(() {});
      }
    }
  }

  KeyEventResult keyEvent(KeyEvent event) {
    if (event is! KeyDownEvent || composing) return KeyEventResult.ignored;
    final keys = HardwareKeyboard.instance;
    if (!keys.isControlPressed && !keys.isMetaPressed)
      return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.keyZ) {
      if (keys.isShiftPressed) {
        redo();
      } else {
        undo();
      }
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.keyY) {
      redo();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void dispose() {
    _disposed = true;
    for (final master in masters) master.dispose();
    masters.clear();
    _undo.clear();
    _redo.clear();
  }
}

extension _PresentationEditorTools on WindowsOfficeEditorState {
  Widget _presentationTableInspector() {
    final draft = _pptDraft!;
    final tables = draft.owner.presentationTables;
    final table = draft.selectedTable;
    final cell = draft.selectedCell;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (tables == null)
          const Text('표 목록을 확인하지 못했습니다.')
        else if (tables.isNotEmpty) ...[
          Text('표', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (var index = 0; index < tables.length; index++)
                ChoiceChip(
                  key: ValueKey(
                    'office-ppt-table-${tables[index].baseline.id}',
                  ),
                  label: Text('표 ${index + 1}'),
                  selected: identical(table, tables[index]),
                  onSelected: _pptContextLocked
                      ? null
                      : (_) => draft.selectTable(tables[index].baseline.id),
                ),
            ],
          ),
        ],
        if (table != null) ...[
          const SizedBox(height: 8),
          Text('${table.baseline.rowCount}행 × ${table.baseline.columnCount}열'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final target in table.cells)
                ChoiceChip(
                  key: ValueKey('office-ppt-cell-${target.baseline.id}'),
                  label: Text(
                    '${target.baseline.row + 1}행 ${target.baseline.column + 1}열${target.baseline.covered ? ' · 병합됨' : ''}',
                  ),
                  selected: identical(cell, target),
                  onSelected: _pptContextLocked
                      ? null
                      : (_) => draft.selectCell(target.baseline.id),
                ),
            ],
          ),
          const SizedBox(height: 12),
          if (cell == null)
            const Text('내용을 확인하거나 바꿀 셀을 선택하세요.')
          else ...[
            TextField(
              key: const ValueKey('office-ppt-cell-text'),
              controller: cell.text,
              focusNode: cell.focus,
              readOnly: !draft.canEditCell(cell),
              minLines: 2,
              maxLines: 6,
              decoration: const InputDecoration(
                labelText: '셀 내용',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              draft.editingMasterId != null
                  ? '공통 디자인의 표는 읽기 전용입니다.'
                  : draft.hasSourceStructure
                  ? '표를 저장하면 셀을 편집할 수 있습니다'
                  : !cell.canReplace
                  ? '이 셀은 현재 읽기 전용입니다.'
                  : !draft.canEditCell(cell) && !draft.locked
                  ? '다른 개체 변경을 저장한 뒤 표 내용을 편집하세요.'
                  : '셀의 글자를 선택해 내용을 바꿀 수 있습니다. 필드와 병합된 영역은 보호됩니다.',
            ),
          ],
        ],
        if (tables?.isNotEmpty == true) const SizedBox(height: 16),
      ],
    );
  }

  Widget _presentationDesignTools() {
    final draft = _pptDraft!;
    final master = draft.masters
        .where((owner) => owner.id == draft.normalSlide.masterId)
        .singleOrNull;
    final editingMaster = draft.editingMasterId != null;
    final canDesign =
        !draft.hasSourceStructure &&
        widget.allowFormatting &&
        widget.onPreview != null &&
        draft.normalSlide.designSha256 != null &&
        !_pptContextLocked;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton.icon(
                key: const ValueKey('office-ppt-add-table'),
                onPressed: draft.canAddSourceTable
                    ? () => unawaited(draft.addSourceTable())
                    : null,
                icon: const Icon(Icons.table_chart_outlined),
                label: const Text('표 추가'),
              ),
              IconButton(
                key: const ValueKey('office-ppt-undo'),
                tooltip: '되돌리기',
                onPressed: draft.canUndo && !_busy && !_pickingImage
                    ? draft.undo
                    : null,
                icon: const Icon(Icons.undo),
              ),
              IconButton(
                key: const ValueKey('office-ppt-redo'),
                tooltip: '다시 실행',
                onPressed: draft.canRedo && !_busy && !_pickingImage
                    ? draft.redo
                    : null,
                icon: const Icon(Icons.redo),
              ),
              if (draft.hasSourceStructure) const Text('표를 저장하면 셀을 편집할 수 있습니다'),
              if (editingMaster) ...[
                Text(
                  draft.owner.name ?? '공통 디자인',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                OutlinedButton.icon(
                  key: const ValueKey('office-ppt-return-slide'),
                  onPressed: _pptContextLocked ? null : draft.returnToSlide,
                  icon: const Icon(Icons.slideshow_outlined),
                  label: const Text('슬라이드로 돌아가기'),
                ),
              ] else ...[
                PopupMenuButton<String>(
                  key: const ValueKey('office-ppt-master'),
                  tooltip: '공통 디자인 적용',
                  enabled: canDesign && draft.masters.isNotEmpty,
                  onSelected: (id) => unawaited(draft.design(masterId: id)),
                  itemBuilder: (_) => [
                    for (final owner in draft.masters)
                      PopupMenuItem<String>(
                        key: ValueKey('office-ppt-master-${owner.id}'),
                        value: owner.id,
                        child: Text(owner.name ?? '공통 디자인'),
                      ),
                  ],
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text('디자인: ${master?.name ?? '선택 안 됨'}'),
                  ),
                ),
                PopupMenuButton<int>(
                  key: const ValueKey('office-ppt-layout'),
                  tooltip: '레이아웃 적용',
                  enabled: canDesign && draft.layoutOptions.isNotEmpty,
                  onSelected: (code) =>
                      unawaited(draft.design(layoutCode: code)),
                  itemBuilder: (_) => [
                    for (final layout in draft.layoutOptions)
                      PopupMenuItem<int>(
                        key: ValueKey('office-ppt-layout-${layout.code}'),
                        value: layout.code,
                        child: Text(layout.label),
                      ),
                  ],
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      '레이아웃: ${draft.layoutOptions.where((item) => item.code == draft.normalSlide.layoutCode).firstOrNull?.label ?? '원본'}',
                    ),
                  ),
                ),
                OutlinedButton.icon(
                  key: const ValueKey('office-ppt-edit-master'),
                  onPressed: master == null || _pptContextLocked
                      ? null
                      : draft.editMaster,
                  icon: const Icon(Icons.dashboard_customize_outlined),
                  label: const Text('공통 디자인 편집'),
                ),
                if (draft.normalSlide.visible case final bool visible
                    when widget.allowFormatting)
                  FilterChip(
                    key: const ValueKey('office-ppt-visible'),
                    label: const Text('발표에 표시'),
                    selected: visible,
                    onSelected: _pptContextLocked
                        ? null
                        : (value) => _presentationChange(
                            () => draft.normalSlide.visible = value,
                          ),
                  ),
                if (draft.normalSlide.showMasterObjects case final bool shown
                    when widget.allowFormatting)
                  FilterChip(
                    key: const ValueKey('office-ppt-master-objects'),
                    label: const Text('공통 개체 표시'),
                    selected: shown,
                    onSelected: _pptContextLocked
                        ? null
                        : (value) => _presentationChange(
                            () => draft.normalSlide.showMasterObjects = value,
                          ),
                  ),
              ],
              if (widget.onPreview != null)
                TextButton.icon(
                  key: const ValueKey('office-ppt-refresh-preview'),
                  onPressed: _pptContextLocked
                      ? null
                      : () => unawaited(draft.refreshPreview()),
                  icon: const Icon(Icons.preview_outlined),
                  label: const Text('미리보기 새로 만들기'),
                ),
              Text(
                draft.previewPath != null
                    ? editingMaster
                          ? '공통 디자인 개략보기 · 슬라이드 미리보기 갱신됨'
                          : '변경 내용 미리보기'
                    : draft.operations.isNotEmpty
                    ? '변경 내용 개략보기'
                    : '저장된 문서 편집 보기',
              ),
            ],
          ),
          if (editingMaster) ...[
            const Text('이 공통 디자인의 변경은 연결된 슬라이드에 함께 적용됩니다.'),
            Wrap(
              spacing: 8,
              children: [
                for (var i = 0; i < _slides.length; i++)
                  if (_slides[i].masterId == draft.editingMasterId)
                    ActionChip(
                      key: ValueKey('office-ppt-linked-slide-${_slides[i].id}'),
                      label: Text('슬라이드 ${i + 1}'),
                      onPressed: _pptContextLocked
                          ? null
                          : () => draft.switchSlide(i),
                    ),
              ],
            ),
          ],
          if (draft._previewError != null)
            Material(
              color: Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Row(
                  children: [
                    Expanded(child: Text(draft._previewError!)),
                    TextButton(
                      key: const ValueKey('office-ppt-retry-preview'),
                      onPressed: draft.previewing || _busy
                          ? null
                          : () => unawaited(draft.refreshPreview()),
                      child: const Text('미리보기 재시도'),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
