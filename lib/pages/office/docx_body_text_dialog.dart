import 'package:flutter/material.dart';
import 'package:saber/data/office/docx_body_text.dart';

typedef DocxBodyTextDraft = ({int paragraphIndex, int runIndex, String text});
typedef DocxTableCellTextDraft = ({
  DocxTableCellAddress address,
  int paragraphIndex,
  int runIndex,
  String text,
});
typedef _DocxTextDraft = ({
  DocxTableCellAddress? address,
  int paragraphIndex,
  int runIndex,
  String text,
});

Future<DocxBodyTextDraft?> chooseDocxBodyText(
  BuildContext context,
  DocxBodyTextPlan plan,
) async {
  final draft = await showDialog<_DocxTextDraft>(
    context: context,
    barrierDismissible: false,
    builder: (context) => _DocxBodyTextDialog(bodyParagraphs: plan.paragraphs),
  );
  if (draft == null) return null;
  return (
    paragraphIndex: draft.paragraphIndex,
    runIndex: draft.runIndex,
    text: draft.text,
  );
}

Future<DocxTableCellTextDraft?> chooseDocxTableCellText(
  BuildContext context,
  DocxTableCellTextPlan plan,
) async {
  final draft = await showDialog<_DocxTextDraft>(
    context: context,
    barrierDismissible: false,
    builder: (context) => _DocxBodyTextDialog(cells: plan.cells),
  );
  final address = draft?.address;
  if (draft == null || address == null) return null;
  return (
    address: address,
    paragraphIndex: draft.paragraphIndex,
    runIndex: draft.runIndex,
    text: draft.text,
  );
}

class _DocxBodyTextDialog extends StatefulWidget {
  const new({this.bodyParagraphs = const [], this.cells});

  final List<DocxBodyTextParagraph> bodyParagraphs;
  final List<DocxTableCellText>? cells;

  @override
  State<_DocxBodyTextDialog> createState() => _DocxBodyTextDialogState();
}

class _DocxBodyTextDialogState extends State<_DocxBodyTextDialog> {
  DocxTableCellText? _cell;
  late DocxBodyTextParagraph? _paragraph;
  late DocxBodyTextRun? _run;
  late final TextEditingController _text;

  bool get _dirty => _run != null && _text.text != _run!.text;
  List<DocxBodyTextParagraph> get _paragraphs =>
      _cell?.paragraphs ?? widget.bodyParagraphs;

  @override
  void initState() {
    super.initState();
    _cell = widget.cells?.firstOrNull;
    _paragraph = _paragraphs.firstOrNull;
    _run = _paragraph?.runs.firstOrNull;
    _text = TextEditingController(text: _run?.text ?? '');
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _select(
    DocxTableCellText? cell,
    DocxBodyTextParagraph paragraph,
    DocxBodyTextRun run,
  ) async {
    if (_cell == cell && _paragraph == paragraph && _run == run) return;
    if (_dirty) {
      final discard = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('수정을 버릴까요?'),
          content: const Text('다른 글자 구간을 열면 현재 수정 내용이 사라집니다.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('계속 수정'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('수정 버리기'),
            ),
          ],
        ),
      );
      if (!mounted || discard != true) return;
    }
    setState(() {
      _cell = cell;
      _paragraph = paragraph;
      _run = run;
      _text.value = TextEditingValue(
        text: run.text,
        selection: TextSelection.collapsed(offset: run.text.length),
      );
    });
  }

  Widget _picker<T>({
    required Key key,
    required String label,
    required T value,
    required Iterable<T> options,
    required String Function(T) describe,
    required ValueChanged<T?> onChanged,
  }) => InputDecorator(
    decoration: InputDecoration(labelText: label),
    child: DropdownButtonHideUnderline(
      child: DropdownButton<T>(
        key: key,
        value: value,
        isDense: true,
        isExpanded: true,
        items: [
          for (final option in options)
            DropdownMenuItem<T>(
              value: option,
              child: Text(
                describe(option),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
        onChanged: onChanged,
      ),
    ),
  );

  String _preview(String text) => text.trim().isEmpty ? '빈 글자 구간' : text;

  String _describeCell(DocxTableCellText cell) {
    final address = cell.address;
    return '표 ${address.tableIndex + 1} · '
        '${address.rowIndex + 1}행 ${address.cellIndex + 1}열 · '
        '${_preview(cell.paragraphs.first.runs.first.text)}';
  }

  @override
  Widget build(BuildContext context) {
    final cells = widget.cells;
    final cell = _cell;
    final paragraph = _paragraph;
    final run = _run;
    final valid = DocxBodyTextEngine.validText(_text.text);
    return AlertDialog(
      title: Text(cells == null ? 'DOCX 본문 글자 수정' : 'DOCX 표 셀 글자 수정'),
      scrollable: true,
      content: SizedBox(
        width: 440,
        child: paragraph == null || run == null
            ? Text(
                cells == null
                    ? '직접 수정할 수 있는 본문 글자 구간이 없습니다.'
                    : '직접 수정할 수 있는 표 셀이 없습니다.',
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (cells != null && cell != null) ...[
                    _picker<DocxTableCellText>(
                      key: const ValueKey('docx-table-cell-address'),
                      label: '표 셀',
                      value: cell,
                      options: cells,
                      describe: _describeCell,
                      onChanged: (option) async {
                        if (option != null && option != cell) {
                          final first = option.paragraphs.first;
                          await _select(option, first, first.runs.first);
                        }
                      },
                    ),
                    const SizedBox(height: 12),
                  ],
                  _picker<DocxBodyTextParagraph>(
                    key: const ValueKey('docx-body-text-paragraph'),
                    label: '문단',
                    value: paragraph,
                    options: _paragraphs,
                    describe: (option) =>
                        '문단 ${option.paragraphIndex + 1} · '
                        '${_preview(option.runs.first.text)}',
                    onChanged: (option) async {
                      if (option != null && option != paragraph) {
                        await _select(cell, option, option.runs.first);
                      }
                    },
                  ),
                  const SizedBox(height: 12),
                  _picker<DocxBodyTextRun>(
                    key: const ValueKey('docx-body-text-run'),
                    label: '글자 구간',
                    value: run,
                    options: paragraph.runs,
                    describe: (option) =>
                        '구간 ${option.runIndex + 1} · ${_preview(option.text)}',
                    onChanged: (option) async {
                      if (option != null)
                        await _select(cell, paragraph, option);
                    },
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    key: const ValueKey('docx-body-text-input'),
                    controller: _text,
                    keyboardType: TextInputType.text,
                    textInputAction: TextInputAction.done,
                    minLines: 2,
                    maxLines: 4,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      labelText: cells == null ? '본문 글자' : '셀 글자',
                      helperText: '선택한 글자 구간의 서식을 유지합니다.',
                      errorText: valid
                          ? null
                          : '줄바꿈 없이 입력하세요. 길이와 문자를 확인해 주세요.',
                      errorMaxLines: 3,
                    ),
                  ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('취소'),
        ),
        FilledButton(
          key: const ValueKey('docx-body-text-confirm'),
          onPressed: paragraph != null && run != null && _dirty && valid
              ? () => Navigator.pop(context, (
                  address: cell?.address,
                  paragraphIndex: paragraph.paragraphIndex,
                  runIndex: run.runIndex,
                  text: _text.text,
                ))
              : null,
          child: const Text('수정하고 저장'),
        ),
      ],
    );
  }
}
