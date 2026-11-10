import 'package:flutter/material.dart';
import 'package:saber/data/office/pptx_shape_text.dart';

typedef PptxSpeakerNotesDraft = ({int slideIndex, String text});

Future<PptxSpeakerNotesDraft?> choosePptxSpeakerNotes(
  BuildContext context,
  PptxShapeTextPlan plan,
  Future<PptxSpeakerNotes> Function(int slideIndex) loadSlide,
) => showDialog<PptxSpeakerNotesDraft>(
  context: context,
  builder: (context) => _PptxSpeakerNotesDialog(plan, loadSlide),
);

class _PptxSpeakerNotesDialog extends StatefulWidget {
  const new(this.plan, this.loadSlide);

  final PptxShapeTextPlan plan;
  final Future<PptxSpeakerNotes> Function(int slideIndex) loadSlide;

  @override
  State<_PptxSpeakerNotesDialog> createState() =>
      _PptxSpeakerNotesDialogState();
}

class _PptxSpeakerNotesDialogState extends State<_PptxSpeakerNotesDialog> {
  final _controller = TextEditingController();
  int? _slideIndex;
  Future<PptxSpeakerNotes>? _pending;
  PptxSpeakerNotes? _notes;
  var _loadFailed = false;

  bool get _changed => _notes != null && _notes!.text != _controller.text;

  bool get _canSave {
    final notes = _notes;
    final text = _controller.text;
    return notes != null &&
        notes.editable &&
        _changed &&
        (notes.hasNotes || text.trim().isNotEmpty) &&
        PptxSpeakerNotesEngine.validText(text);
  }

  Future<void> _selectSlide(int? index) async {
    if (index == null || index == _slideIndex) return;
    if (_changed) {
      final discard = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('저장하지 않은 변경이 있습니다'),
          content: const Text('다른 슬라이드로 이동하면 현재 입력한 내용이 사라집니다.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('계속 편집'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('슬라이드 이동'),
            ),
          ],
        ),
      );
      if (!mounted || discard != true) return;
    }
    final request = Future<PptxSpeakerNotes>.sync(
      () => widget.loadSlide(index),
    );
    setState(() {
      _slideIndex = index;
      _pending = request;
      _notes = null;
      _loadFailed = false;
      _controller.clear();
    });
    try {
      final notes = await request;
      if (!mounted || _pending != request) return;
      setState(() {
        _pending = null;
        _notes = notes;
        _controller.text = notes.text;
      });
    } on Exception {
      if (!mounted || _pending != request) return;
      setState(() {
        _pending = null;
        _loadFailed = true;
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('발표자 노트'),
    scrollable: true,
    content: SizedBox(
      width: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('노트는 선택한 슬라이드에 저장됩니다.'),
          const SizedBox(height: 12),
          InputDecorator(
            decoration: const InputDecoration(labelText: '슬라이드'),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<int>(
                key: const ValueKey('pptx-speaker-notes-slide'),
                value: _slideIndex,
                hint: const Text('슬라이드 선택'),
                isDense: true,
                isExpanded: true,
                items: [
                  for (final slide in widget.plan.slides)
                    DropdownMenuItem(
                      value: slide.index,
                      child: Text(
                        [
                          '슬라이드 ${slide.index + 1}',
                          if (slide.hidden) '숨김',
                          if (slide.title case final title?
                              when title.isNotEmpty)
                            title,
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: _selectSlide,
              ),
            ),
          ),
          if (_pending != null) const LinearProgressIndicator(),
          if (_loadFailed) const Text('발표자 노트를 읽지 못했습니다.'),
          if (_notes case final notes?) ...[
            const SizedBox(height: 12),
            if (!notes.editable) const Text('이 발표자 노트는 읽기 전용입니다.'),
            TextField(
              key: const ValueKey('pptx-speaker-notes-text'),
              controller: _controller,
              readOnly: !notes.editable,
              minLines: 4,
              maxLines: 6,
              keyboardType: TextInputType.multiline,
              textInputAction: TextInputAction.newline,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: '노트 내용',
                errorText:
                    notes.editable &&
                        !PptxSpeakerNotesEngine.validText(_controller.text)
                    ? '8,000자와 128줄 이내로 입력하고 특수 제어 문자를 지워주세요.'
                    : null,
              ),
            ),
          ],
        ],
      ),
    ),
    actions: [
      TextButton(
        key: const ValueKey('pptx-speaker-notes-cancel'),
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('닫기'),
      ),
      FilledButton(
        key: const ValueKey('pptx-speaker-notes-save'),
        onPressed: _canSave
            ? () =>
                  Navigator.of(context)
                      .pop((slideIndex: _slideIndex!, text: _controller.text))
            : null,
        child: const Text('저장'),
      ),
    ],
  );
}
