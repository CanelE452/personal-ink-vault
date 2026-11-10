import 'package:flutter/material.dart';
import 'package:saber/data/office/pptx_shape_text.dart';

typedef PptxShapeTextDraft = ({
  int slideIndex,
  PptxShapeTextShape shape,
  List<PptxShapeTextChange> changes,
  PptxShapeTextFormat? format,
  PptxShapeParagraphAlignmentChange? alignment,
});

Future<PptxShapeTextDraft?> choosePptxShapeText(
  BuildContext context,
  PptxShapeTextPlan plan,
  Future<List<PptxShapeTextShape>> Function(int slideIndex) loadSlide, {
  bool formatOnly = false,
  bool alignmentOnly = false,
}) => showDialog<PptxShapeTextDraft>(
  context: context,
  builder: (context) =>
      _PptxShapeTextDialog(plan, loadSlide, formatOnly, alignmentOnly),
);

enum _PptxCharacterStyle {
  bold('굵게'),
  italic('기울임'),
  underline('밑줄');

  new(this.label);

  final String label;
}

enum _PptxStyleOverride {
  keep('유지', null),
  apply('적용', true),
  remove('해제', false);

  new(this.label, this.value);

  final String label;
  final bool? value;
}

class _PptxShapeTextDialog extends StatefulWidget {
  const new(this.plan, this.loadSlide, this.formatOnly, this.alignmentOnly)
    : assert(!(formatOnly && alignmentOnly));

  final PptxShapeTextPlan plan;
  final Future<List<PptxShapeTextShape>> Function(int slideIndex) loadSlide;
  final bool formatOnly;
  final bool alignmentOnly;

  @override
  State<_PptxShapeTextDialog> createState() => _PptxShapeTextDialogState();
}

class _PptxShapeTextDialogState extends State<_PptxShapeTextDialog> {
  static final _pointPattern = RegExp(r'^([0-9]{1,4})(?:\.([0-9]{1,2}))?$');
  static const _colors = [
    ('검정', '000000'),
    ('빨강', 'C62828'),
    ('파랑', '1565C0'),
    ('초록', '2E7D32'),
    ('노랑', 'F9A825'),
  ];

  final _changes = <(int, int), String>{};
  final _styles = <_PptxCharacterStyle, _PptxStyleOverride>{};
  final _fontSize = TextEditingController();
  final _fontColor = TextEditingController();
  ({PptxShapeTextRun run, int start, int end})? _formatSelection;
  PptxShapeTextParagraph? _paragraph;
  PptxParagraphAlignment? _paragraphAlignment;
  int? _slideIndex;
  List<PptxShapeTextShape>? _shapes;
  PptxShapeTextShape? _shape;
  var _loadGeneration = 0;
  var _loadFailed = false;

  bool get _withinTotalLimit =>
      _changes.values.fold(0, (total, text) => total + text.length) <=
      PptxShapeTextEngine.maxTotalRunLength;

  int? get _parsedFontSize {
    final match = _pointPattern.firstMatch(_fontSize.text.trim());
    if (match == null) return null;
    final points = int.parse(match[1]!);
    final hundredths = int.parse((match[2] ?? '').padRight(2, '0'));
    final value = points * 100 + hundredths;
    return PptxShapeTextEngine.validFormatFontSize(value) ? value : null;
  }

  String? get _parsedFontColor {
    final input = _fontColor.text.trim();
    final value = input.startsWith('#') ? input.substring(1) : input;
    return PptxShapeTextEngine.validFormatFontColor(value)
        ? value.toUpperCase()
        : null;
  }

  bool get _hasFormatChanges =>
      _styles.isNotEmpty ||
      _fontSize.text.trim().isNotEmpty ||
      _fontColor.text.trim().isNotEmpty;

  bool get _invalidFontSize =>
      _fontSize.text.trim().isNotEmpty && _parsedFontSize == null;

  bool get _invalidFontColor =>
      _fontColor.text.trim().isNotEmpty && _parsedFontColor == null;

  bool get _alignmentChanged =>
      _paragraphAlignment != null &&
      _paragraphAlignment != _paragraph?.alignment;

  bool get _canSubmit {
    if (widget.alignmentOnly) return _alignmentChanged;
    return widget.formatOnly
        ? _formatSelection != null &&
              _hasFormatChanges &&
              !_invalidFontSize &&
              !_invalidFontColor
        : _changes.isNotEmpty &&
              _withinTotalLimit &&
              _changes.values.every(PptxShapeTextEngine.validText);
  }

  void _clearFormatOverrides() {
    _styles.clear();
    _fontSize.clear();
    _fontColor.clear();
  }

  @override
  void dispose() {
    _fontSize.dispose();
    _fontColor.dispose();
    super.dispose();
  }

  Future<bool> _discardChanges() async {
    if (_changes.isEmpty && !_hasFormatChanges && !_alignmentChanged) {
      return true;
    }
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('이 도형의 변경 사항을 버릴까요?'),
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
    return discard == true;
  }

  Future<void> _selectSlide(int index) async {
    if (!await _discardChanges() || !mounted) return;
    final generation = ++_loadGeneration;
    setState(() {
      _slideIndex = index;
      _shapes = null;
      _shape = null;
      _loadFailed = false;
      _changes.clear();
      _formatSelection = null;
      _clearFormatOverrides();
      _paragraph = null;
      _paragraphAlignment = null;
    });
    try {
      final shapes = await widget.loadSlide(index);
      if (!mounted || generation != _loadGeneration) return;
      setState(() => _shapes = shapes);
    } on Object {
      if (!mounted || generation != _loadGeneration) return;
      setState(() => _loadFailed = true);
    }
  }

  Future<void> _selectShape(PptxShapeTextShape shape) async {
    if (identical(_shape, shape) || !await _discardChanges() || !mounted)
      return;
    setState(() {
      _shape = shape;
      _changes.clear();
      _formatSelection = null;
      _clearFormatOverrides();
      _paragraph = null;
      _paragraphAlignment = null;
    });
  }

  void _selectFormatRange(
    PptxShapeTextShape shape,
    PptxShapeTextRun run,
    TextSelection selection,
  ) {
    if (!mounted || !identical(_shape, shape)) return;
    final next =
        PptxShapeTextEngine.validFormatRange(
          run.text,
          selection.start,
          selection.end,
        )
        ? (run: run, start: selection.start, end: selection.end)
        : null;
    if (_formatSelection == next) return;
    setState(() {
      _formatSelection = next;
      _clearFormatOverrides();
    });
  }

  void _submit() {
    final slide = _slideIndex;
    final shape = _shape;
    final selection = _formatSelection;
    if (slide == null || shape == null || !_canSubmit) return;
    Navigator.of(context).pop((
      slideIndex: slide,
      shape: shape,
      changes: List<PptxShapeTextChange>.unmodifiable([
        for (final run in shape.runs)
          if (_changes[(run.paragraphIndex, run.runIndex)] case final text?)
            PptxShapeTextChange(
              paragraphIndex: run.paragraphIndex,
              runIndex: run.runIndex,
              text: text,
            ),
      ]),
      format: selection != null
          ? PptxShapeTextFormat(
              paragraphIndex: selection.run.paragraphIndex,
              runIndex: selection.run.runIndex,
              start: selection.start,
              end: selection.end,
              bold: _styles[_PptxCharacterStyle.bold]?.value,
              italic: _styles[_PptxCharacterStyle.italic]?.value,
              underline: _styles[_PptxCharacterStyle.underline]?.value,
              fontSize: _parsedFontSize,
              fontColor: _parsedFontColor,
            )
          : null,
      alignment: _paragraphAlignment == null
          ? null
          : PptxShapeParagraphAlignmentChange(
              paragraphIndex: _paragraph!.index,
              value: _paragraphAlignment!,
            ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final slide = _slideIndex;
    final shape = _shape;
    final runs = shape?.runs ?? const <PptxShapeTextRun>[];
    final formatOnly = widget.formatOnly;
    final alignmentOnly = widget.alignmentOnly;
    final keyPrefix = alignmentOnly
        ? 'pptx-shape-align'
        : formatOnly
        ? 'pptx-shape-format'
        : 'pptx-shape-text';
    final fields = ListView.builder(
      itemCount: alignmentOnly ? 4 : runs.length + 3,
      itemBuilder: (context, index) => switch (index) {
        0 => _slidePicker(),
        1 => _shapePicker(),
        2 => Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text(
            alignmentOnly
                ? '정렬을 바꿀 문단을 선택하세요.'
                : formatOnly
                ? '한 글자 구간에서 길게 눌러 바꿀 글자를 선택하세요.'
                : '선택한 도형의 글자를 수정합니다. 서식, 자동 필드와 링크는 유지됩니다.',
          ),
        ),
        _ when alignmentOnly => _alignmentControls(shape),
        _ => _runField(slide!, shape!, index - 3),
      },
    );
    return AlertDialog(
      title: Text(
        alignmentOnly
            ? 'PPTX 도형 문단 정렬'
            : formatOnly
            ? 'PPTX 도형 글자 서식'
            : 'PPTX 도형 글자 수정',
      ),
      content: SizedBox(
        width: 480,
        height: 400,
        child: formatOnly
            ? LayoutBuilder(
                builder: (context, constraints) => Column(
                  children: [
                    Expanded(child: fields),
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: constraints.maxHeight / 2,
                      ),
                      child: SingleChildScrollView(child: _formatControls()),
                    ),
                  ],
                ),
              )
            : fields,
      ),
      actions: [
        if (!_withinTotalLimit)
          Text(
            '한 번에 저장할 수 있는 글자 길이를 넘었습니다.',
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        TextButton(
          key: ValueKey('$keyPrefix-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        FilledButton(
          key: ValueKey('$keyPrefix-confirm'),
          onPressed: _canSubmit ? _submit : null,
          child: Text(
            alignmentOnly
                ? '정렬 저장'
                : formatOnly
                ? '서식 저장'
                : '수정하고 저장',
          ),
        ),
      ],
    );
  }

  Widget _slidePicker() => InputDecorator(
    decoration: const InputDecoration(labelText: '슬라이드'),
    child: DropdownButtonHideUnderline(
      child: DropdownButton<int>(
        key: const ValueKey('pptx-shape-text-slide'),
        value: _slideIndex,
        isDense: true,
        isExpanded: true,
        hint: const Text('슬라이드 선택'),
        items: [
          for (final slide in widget.plan.slides)
            DropdownMenuItem(
              value: slide.index,
              child: Text(
                [
                  '슬라이드 ${slide.index + 1}',
                  if (slide.hidden) '숨김',
                  if (slide.title case final title? when title.isNotEmpty)
                    title,
                ].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
        onChanged: (index) async {
          if (index != null && index != _slideIndex) await _selectSlide(index);
        },
      ),
    ),
  );

  Widget _shapePicker() {
    final slide = _slideIndex;
    if (slide == null) return const SizedBox.shrink();
    final shapes = _shapes;
    final Widget content;
    if (_loadFailed) {
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('이 슬라이드의 도형 글자를 읽지 못했습니다.'),
          TextButton(
            onPressed: () => _selectSlide(slide),
            child: const Text('다시 읽기'),
          ),
        ],
      );
    } else if (shapes == null) {
      content = const LinearProgressIndicator(semanticsLabel: '도형 글자 읽는 중');
    } else if (shapes.isEmpty) {
      content = const Text('이 슬라이드에 수정할 수 있는 도형 글자가 없습니다.');
    } else {
      final counts = <String, int>{};
      for (final shape in shapes) {
        final name = shape.name.trim();
        counts[name] = (counts[name] ?? 0) + 1;
      }
      content = InputDecorator(
        decoration: const InputDecoration(labelText: '도형'),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<PptxShapeTextShape>(
            key: const ValueKey('pptx-shape-text-shape'),
            value: _shape,
            isDense: true,
            isExpanded: true,
            hint: const Text('도형 선택'),
            items: [
              for (final shape in shapes)
                DropdownMenuItem(
                  value: shape,
                  child: Text(
                    _shapeLabel(shape, counts),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: (shape) async {
              if (shape != null) await _selectShape(shape);
            },
          ),
        ),
      );
    }
    return Padding(padding: const EdgeInsets.only(top: 12), child: content);
  }

  String _shapeLabel(PptxShapeTextShape shape, Map<String, int> counts) {
    final name = shape.name.trim();
    if (name.isEmpty) return '도형 ${shape.shapeId}';
    if (counts[name] != 1) return '$name · ${shape.shapeId}';
    return name;
  }

  Widget _alignmentControls(PptxShapeTextShape? shape) {
    if (shape == null) return const SizedBox.shrink();
    final paragraph = _paragraph;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InputDecorator(
          decoration: const InputDecoration(labelText: '문단'),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<PptxShapeTextParagraph>(
              key: const ValueKey('pptx-shape-paragraph'),
              value: paragraph,
              isDense: true,
              isExpanded: true,
              hint: const Text('문단 선택'),
              items: [
                for (final item in shape.paragraphs)
                  DropdownMenuItem(
                    value: item,
                    child: Text(
                      '문단 ${item.index + 1} · ${item.text.trim().isEmpty ? '빈 문단' : item.text.trim()}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (item) async {
                if (item == null ||
                    identical(item, paragraph) ||
                    !await _discardChanges() ||
                    !mounted ||
                    !identical(shape, _shape)) {
                  return;
                }
                setState(() {
                  _paragraph = item;
                  _paragraphAlignment = null;
                });
              },
            ),
          ),
        ),
        if (paragraph != null) ...[
          const SizedBox(height: 12),
          Text('현재 정렬 · ${_alignmentLabel(paragraph.alignment)}'),
          InputDecorator(
            decoration: const InputDecoration(labelText: '새 정렬'),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<PptxParagraphAlignment>(
                key: const ValueKey('pptx-shape-paragraph-alignment'),
                value: _paragraphAlignment,
                isDense: true,
                isExpanded: true,
                hint: const Text('정렬 선택'),
                items: [
                  for (final value in PptxParagraphAlignment.values)
                    if (value.canSet)
                      DropdownMenuItem(
                        value: value,
                        child: Text(_alignmentLabel(value)),
                      ),
                ],
                onChanged: (value) =>
                    setState(() => _paragraphAlignment = value),
              ),
            ),
          ),
        ],
      ],
    );
  }

  String _alignmentLabel(PptxParagraphAlignment value) => switch (value) {
    .inherited => '상속',
    .left => '왼쪽',
    .center => '가운데',
    .right => '오른쪽',
    .justify => '양쪽',
    .justifyLow => '좁은 간격 양쪽',
    .distributed => '균등 분할',
    .thaiDistributed => '태국어 균등 분할',
  };

  Widget _formatControls() {
    final selection = _formatSelection;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Divider(height: 12),
        Text(
          selection == null
              ? '서식을 바꿀 글자를 선택하세요.'
              : '선택한 글자  ${selection.run.text.substring(selection.start, selection.end)}',
          key: const ValueKey('pptx-shape-format-selection'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final style in _PptxCharacterStyle.values)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: DropdownButton<_PptxStyleOverride>(
                    key: ValueKey('pptx-shape-format-${style.name}'),
                    value: _styles[style] ?? _PptxStyleOverride.keep,
                    items: [
                      for (final choice in _PptxStyleOverride.values)
                        DropdownMenuItem(
                          value: choice,
                          child: Text('${style.label} ${choice.label}'),
                        ),
                    ],
                    onChanged: selection == null
                        ? null
                        : (choice) {
                            if (!mounted || _formatSelection != selection)
                              return;
                            setState(() {
                              if (choice == null ||
                                  choice == _PptxStyleOverride.keep) {
                                _styles.remove(style);
                              } else {
                                _styles[style] = choice;
                              }
                            });
                          },
                  ),
                ),
            ],
          ),
        ),
        if (selection != null) ...[
          const SizedBox(height: 4),
          TextField(
            key: const ValueKey('pptx-shape-format-font-size'),
            controller: _fontSize,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(
              labelText: '글자 크기',
              hintText: '예: 12.5',
              suffixText: 'pt',
              isDense: true,
              border: const OutlineInputBorder(),
              errorText: _invalidFontSize ? '1~4000, 소수점 두 자리까지' : null,
              errorMaxLines: 2,
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 8),
          TextField(
            key: const ValueKey('pptx-shape-format-font-color'),
            controller: _fontColor,
            autocorrect: false,
            enableSuggestions: false,
            textCapitalization: TextCapitalization.characters,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              labelText: '글자 색상',
              hintText: '예: 1A2B3C',
              isDense: true,
              border: const OutlineInputBorder(),
              errorText: _invalidFontColor ? 'RGB 16진수 여섯 자리를 입력하세요.' : null,
              errorMaxLines: 2,
              suffixIcon: PopupMenuButton<String>(
                tooltip: '기본 글자 색상',
                icon: const Icon(Icons.palette_outlined),
                itemBuilder: (context) => [
                  for (final (label, value) in _colors)
                    PopupMenuItem(
                      value: value,
                      child: Row(
                        children: [
                          Icon(
                            Icons.circle,
                            color: Color(
                              0xff000000 | int.parse(value, radix: 16),
                            ),
                            size: 18,
                          ),
                          const SizedBox(width: 12),
                          Text(label),
                        ],
                      ),
                    ),
                ],
                onSelected: (value) {
                  if (!mounted || _formatSelection != selection) return;
                  setState(() {
                    _fontColor.text = value;
                  });
                },
              ),
            ),
            onChanged: (_) => setState(() {}),
          ),
        ],
      ],
    );
  }

  Widget _runField(int slideIndex, PptxShapeTextShape shape, int index) {
    final runs = shape.runs;
    final run = runs[index];
    final paragraph = run.paragraphIndex;
    final runIndex = run.runIndex;
    final key = (paragraph, runIndex);
    final value = _changes[key] ?? run.text;
    final beginsParagraph =
        index == 0 || runs[index - 1].paragraphIndex != paragraph;
    return KeyedSubtree(
      key: ValueKey((slideIndex, shape.shapeId, key)),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (beginsParagraph) ...[
              Text(
                '문단 ${paragraph + 1}',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 4),
            ],
            if (widget.formatOnly)
              _PptxFormatRunField(
                run,
                (selection) => _selectFormatRange(shape, run, selection),
              )
            else
              TextFormField(
                key: ValueKey('pptx-shape-text-run-$paragraph-$runIndex'),
                initialValue: value,
                minLines: 1,
                maxLines: 3,
                keyboardType: TextInputType.text,
                textInputAction: TextInputAction.done,
                decoration: InputDecoration(
                  labelText: '글자 구간 ${runIndex + 1}',
                  border: const OutlineInputBorder(),
                  errorText: PptxShapeTextEngine.validText(value)
                      ? null
                      : '글자 길이, 줄바꿈과 제어 문자를 확인하세요.',
                ),
                onChanged: (text) => setState(() {
                  if (text == run.text) {
                    _changes.remove(key);
                  } else {
                    _changes[key] = text;
                  }
                }),
              ),
          ],
        ),
      ),
    );
  }
}

class _PptxFormatRunField extends StatefulWidget {
  const new(this.run, this.onSelectionChanged);

  final PptxShapeTextRun run;
  final ValueChanged<TextSelection> onSelectionChanged;

  @override
  State<_PptxFormatRunField> createState() => _PptxFormatRunFieldState();
}

class _PptxFormatRunFieldState extends State<_PptxFormatRunField> {
  late final _controller = TextEditingController(text: widget.run.text)
    ..addListener(_report);

  void _report() => widget.onSelectionChanged(_controller.selection);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
    key: ValueKey(
      'pptx-shape-format-run-${widget.run.paragraphIndex}-${widget.run.runIndex}',
    ),
    controller: _controller,
    readOnly: true,
    minLines: 1,
    maxLines: 3,
    onTap: _report,
    decoration: InputDecoration(
      labelText: '글자 구간 ${widget.run.runIndex + 1}',
      border: const OutlineInputBorder(),
    ),
  );
}
