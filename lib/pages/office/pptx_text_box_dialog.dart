import 'package:flutter/material.dart';
import 'package:saber/data/office/pptx_text_box.dart';

typedef PptxTextBoxDraft = ({
  int slideIndex,
  String text,
  PptxTextBoxPlacement placement,
  int fontSize,
  ({PptxPresetShape kind, String? fillColor, String lineColor})? shape,
});

Future<PptxTextBoxDraft?> choosePptxTextBox(
  BuildContext context,
  PptxTextBoxPlan plan, {
  bool addPresetShape = false,
}) => showDialog<PptxTextBoxDraft>(
  context: context,
  builder: (context) =>
      _PptxTextBoxDialog(plan, addPresetShape: addPresetShape),
);

class _PptxTextBoxDialog extends StatefulWidget {
  const new(this.plan, {required this.addPresetShape});

  final PptxTextBoxPlan plan;
  final bool addPresetShape;

  @override
  State<_PptxTextBoxDialog> createState() => _PptxTextBoxDialogState();
}

class _PptxTextBoxDialogState extends State<_PptxTextBoxDialog> {
  final _form = GlobalKey<FormState>();
  final _text = TextEditingController();
  final _font = TextEditingController(text: '24');
  int? _slideIndex;
  var _placement = PptxTextBoxPlacement.middle;
  var _shape = PptxPresetShape.rectangle;
  var _fillColor = 'DBEAFE';
  var _lineColor = '1E3A8A';

  static const _colors = {
    'DBEAFE': '연한 파랑',
    '1E3A8A': '진한 파랑',
    '166534': '초록',
    'B91C1C': '빨강',
    'FDE68A': '노랑',
    '1F2937': '진회색',
    'FFFFFF': '흰색',
  };

  ValueKey<String> _fieldKey(String name) => ValueKey(
    'pptx-${widget.addPresetShape ? 'preset-shape' : 'text-box'}-$name',
  );

  @override
  void dispose() {
    _text.dispose();
    _font.dispose();
    super.dispose();
  }

  void _submit() {
    final index = _slideIndex;
    if (index == null || !_form.currentState!.validate()) return;
    Navigator.of(context).pop((
      slideIndex: index,
      text: PptxTextBoxEngine.normalizeText(_text.text),
      placement: _placement,
      fontSize: int.parse(_font.text.trim(), radix: 10),
      shape: widget.addPresetShape
          ? (
              kind: _shape,
              fillColor: _fillColor.isEmpty ? null : _fillColor,
              lineColor: _lineColor,
            )
          : null,
    ));
  }

  Widget _colorField({
    required String name,
    required String label,
    required String selected,
    required ValueChanged<String> onChanged,
    bool allowNone = false,
  }) => DropdownButtonFormField<String>(
    key: _fieldKey(name),
    initialValue: selected,
    decoration: InputDecoration(labelText: label),
    isExpanded: true,
    items: [
      if (allowNone) const DropdownMenuItem(value: '', child: Text('없음')),
      for (final MapEntry(key: code, value: name) in _colors.entries)
        DropdownMenuItem(
          value: code,
          child: Row(
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  color: Color(int.parse('FF$code', radix: 16)),
                  border: Border.all(
                    color: Theme.of(context).colorScheme.outline,
                  ),
                  borderRadius: BorderRadius.circular(3),
                ),
                child: const SizedBox.square(dimension: 16),
              ),
              const SizedBox(width: 8),
              Text(name),
            ],
          ),
        ),
    ],
    onChanged: (value) {
      if (value != null) onChanged(value);
    },
  );

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.addPresetShape ? 'PPTX 도형 추가' : 'PPTX 텍스트 상자 추가'),
    scrollable: true,
    content: SizedBox(
      width: 420,
      child: Form(
        key: _form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<int>(
              key: _fieldKey('slide'),
              initialValue: _slideIndex,
              decoration: const InputDecoration(labelText: '슬라이드'),
              isExpanded: true,
              items: [
                for (final slide in widget.plan.slides)
                  DropdownMenuItem(
                    value: slide.index,
                    enabled: slide.canAdd,
                    child: Text(
                      [
                        '슬라이드 ${slide.index + 1}',
                        if (slide.hidden) '숨김',
                        if (slide.title case final title? when title.isNotEmpty)
                          title,
                        if (slide.sectionName case final section?
                            when section.isNotEmpty)
                          '$section 구역',
                        if (!slide.canAdd) '추가 불가',
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (index) => setState(() => _slideIndex = index),
            ),
            if (widget.addPresetShape) ...[
              const SizedBox(height: 12),
              DropdownButtonFormField<PptxPresetShape>(
                key: _fieldKey('kind'),
                initialValue: _shape,
                decoration: const InputDecoration(labelText: '도형'),
                items: const [
                  DropdownMenuItem(
                    value: PptxPresetShape.rectangle,
                    child: Text('사각형'),
                  ),
                  DropdownMenuItem(
                    value: PptxPresetShape.roundedRectangle,
                    child: Text('둥근 사각형'),
                  ),
                  DropdownMenuItem(
                    value: PptxPresetShape.ellipse,
                    child: Text('타원'),
                  ),
                  DropdownMenuItem(
                    value: PptxPresetShape.rightArrow,
                    child: Text('오른쪽 화살표'),
                  ),
                ],
                onChanged: (value) {
                  if (value != null) setState(() => _shape = value);
                },
              ),
              const SizedBox(height: 12),
              _colorField(
                name: 'fill',
                label: '채우기',
                selected: _fillColor,
                allowNone: true,
                onChanged: (value) => setState(() => _fillColor = value),
              ),
              const SizedBox(height: 12),
              _colorField(
                name: 'line',
                label: '윤곽선',
                selected: _lineColor,
                onChanged: (value) => setState(() => _lineColor = value),
              ),
            ],
            const SizedBox(height: 12),
            TextFormField(
              key: _fieldKey('text'),
              controller: _text,
              keyboardType: TextInputType.multiline,
              textInputAction: TextInputAction.newline,
              minLines: widget.addPresetShape ? 2 : 3,
              maxLines: 6,
              decoration: InputDecoration(
                labelText: widget.addPresetShape ? '도형 안 텍스트 (선택)' : '텍스트',
                helperText: '최대 8줄 · 600자',
              ),
              validator: (value) {
                final text = PptxTextBoxEngine.normalizeText(value ?? '');
                final valid = widget.addPresetShape
                    ? PptxTextBoxEngine.validPresetText(text)
                    : PptxTextBoxEngine.validText(text);
                return valid ? null : '최대 8줄 · 600자 범위에서 텍스트를 입력하세요.';
              },
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<PptxTextBoxPlacement>(
                    key: _fieldKey('placement'),
                    initialValue: _placement,
                    decoration: InputDecoration(
                      labelText: widget.addPresetShape ? '도형 위치' : '상자 위치',
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: PptxTextBoxPlacement.top,
                        child: Text('위쪽'),
                      ),
                      DropdownMenuItem(
                        value: PptxTextBoxPlacement.middle,
                        child: Text('가운데'),
                      ),
                      DropdownMenuItem(
                        value: PptxTextBoxPlacement.bottom,
                        child: Text('아래쪽'),
                      ),
                    ],
                    onChanged: (value) {
                      if (value != null) setState(() => _placement = value);
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    key: _fieldKey('size'),
                    controller: _font,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: '글자 크기 (pt)'),
                    validator: (value) {
                      final size = int.tryParse(value?.trim() ?? '', radix: 10);
                      return size != null &&
                              size >= PptxTextBoxEngine.minFontSize &&
                              size <= PptxTextBoxEngine.maxFontSize
                          ? null
                          : '12~40pt를 입력하세요.';
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        key: _fieldKey('cancel'),
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('취소'),
      ),
      FilledButton(
        key: _fieldKey('confirm'),
        onPressed: _slideIndex == null ? null : _submit,
        child: const Text('추가하고 저장'),
      ),
    ],
  );
}
