import 'package:flutter/material.dart';
import 'package:saber/data/office/docx_paragraph_insert.dart';

typedef DocxParagraphDraft = ({
  int anchorParagraphIndex,
  DocxParagraphPosition position,
  String text,
});

Future<DocxParagraphDraft?> chooseDocxParagraph(
  BuildContext context,
  DocxParagraphInsertPlan plan,
) => showDialog<DocxParagraphDraft>(
  context: context,
  barrierDismissible: false,
  builder: (context) => _DocxParagraphDialog(plan),
);

class _DocxParagraphDialog extends StatefulWidget {
  const new(this.plan);

  final DocxParagraphInsertPlan plan;

  @override
  State<_DocxParagraphDialog> createState() => _DocxParagraphDialogState();
}

class _DocxParagraphDialogState extends State<_DocxParagraphDialog> {
  late final List<DocxParagraphAnchor> _anchors;
  late DocxParagraphAnchor? _anchor;
  var _position = DocxParagraphPosition.after;
  var _text = '';

  @override
  void initState() {
    super.initState();
    _anchors = widget.plan.paragraphs
        .where((anchor) => anchor.canBefore || anchor.canAfter)
        .toList();
    _anchor = _anchors.firstOrNull;
    if (_anchor?.canAfter == false) _position = DocxParagraphPosition.before;
  }

  void _selectAnchor(DocxParagraphAnchor? anchor) {
    if (anchor == null) return;
    setState(() {
      _anchor = anchor;
      if (!anchor.allows(_position)) {
        _position = anchor.canBefore
            ? DocxParagraphPosition.before
            : DocxParagraphPosition.after;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final anchor = _anchor;
    final valid = DocxParagraphInsertEngine.validText(_text);
    return AlertDialog(
      title: const Text('본문 문단 추가'),
      scrollable: true,
      content: SizedBox(
        width: 440,
        child: anchor == null
            ? const Text('새 문단을 넣을 수 있는 본문 위치가 없습니다.')
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  DropdownButtonFormField<DocxParagraphAnchor>(
                    key: const ValueKey('docx-paragraph-anchor'),
                    initialValue: anchor,
                    decoration: const InputDecoration(labelText: '기준 문단'),
                    isExpanded: true,
                    items: [
                      for (final item in _anchors)
                        DropdownMenuItem(
                          value: item,
                          child: Text(
                            '${item.index + 1}번 문단 · '
                            '${item.text.trim().isEmpty ? '빈 문단' : item.text}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: _selectAnchor,
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final position in DocxParagraphPosition.values)
                        ChoiceChip(
                          key: ValueKey('docx-paragraph-${position.name}'),
                          label: Text(
                            position == DocxParagraphPosition.before
                                ? '문단 앞'
                                : '문단 뒤',
                          ),
                          selected: position == _position,
                          onSelected: anchor.allows(position)
                              ? (_) => setState(() => _position = position)
                              : null,
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const ValueKey('docx-paragraph-text'),
                    onChanged: (text) => setState(() => _text = text),
                    decoration: InputDecoration(
                      labelText: '새 문단 내용',
                      helperText: '한 줄을 입력하면 기본 문단 서식으로 추가됩니다.',
                      errorText: _text.isNotEmpty && !valid
                          ? '빈 문단은 추가할 수 없습니다. 2,000자 이내로 입력하세요.'
                          : null,
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
          key: const ValueKey('docx-paragraph-apply'),
          onPressed: anchor != null && valid
              ? () => Navigator.of(context).pop((
                  anchorParagraphIndex: anchor.index,
                  position: _position,
                  text: _text,
                ))
              : null,
          child: const Text('추가하고 저장'),
        ),
      ],
    );
  }
}
