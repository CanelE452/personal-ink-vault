import 'package:flutter/material.dart';
import 'package:saber/data/office/pptx_shape_delete.dart';

typedef PptxShapeDeleteDraft = ({int slideIndex, int shapeId});

Future<PptxShapeDeleteDraft?> choosePptxShapeToDelete(
  BuildContext context,
  PptxShapeDeletePlan plan,
  Future<List<PptxShapeDeleteTarget>> Function(int slideIndex) loadSlide,
) => showDialog<PptxShapeDeleteDraft>(
  context: context,
  builder: (context) => _PptxShapeDeleteDialog(plan, loadSlide),
);

class _PptxShapeDeleteDialog extends StatefulWidget {
  const new(this.plan, this.loadSlide);

  final PptxShapeDeletePlan plan;
  final Future<List<PptxShapeDeleteTarget>> Function(int slideIndex) loadSlide;

  @override
  State<_PptxShapeDeleteDialog> createState() => _PptxShapeDeleteDialogState();
}

class _PptxShapeDeleteDialogState extends State<_PptxShapeDeleteDialog> {
  int? _slideIndex;
  int? _shapeId;
  Future<List<PptxShapeDeleteTarget>>? _shapes;

  void _selectSlide(int index) => setState(() {
    _slideIndex = index;
    _shapeId = null;
    _shapes = widget.loadSlide(index);
  });

  @override
  Widget build(BuildContext context) {
    final index = _slideIndex;
    final shapeId = _shapeId;
    final colors = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('삭제할 도형 선택'),
      scrollable: true,
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('선택한 도형은 새 판본에서 삭제됩니다. 이전 원본과 PDF 필기는 판본 기록에 남습니다.'),
            const SizedBox(height: 12),
            DropdownButton<int>(
              key: const ValueKey('pptx-shape-delete-slide'),
              hint: const Text('슬라이드 선택'),
              value: index,
              isExpanded: true,
              items: [
                for (final slide in widget.plan.slides)
                  DropdownMenuItem(
                    value: slide.index,
                    child: Text(
                      _slideLabel(slide),
                      key: ValueKey('pptx-shape-delete-slide-${slide.index}'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (value) {
                if (value != null && value != index) _selectSlide(value);
              },
            ),
            if (index != null)
              FutureBuilder<List<PptxShapeDeleteTarget>>(
                future: _shapes,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const LinearProgressIndicator(
                      semanticsLabel: '도형 목록을 불러오는 중',
                    );
                  }
                  if (snapshot.hasError) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('도형 목록을 불러오지 못했습니다.'),
                        TextButton(
                          onPressed: () => _selectSlide(index),
                          child: const Text('다시 시도'),
                        ),
                      ],
                    );
                  }
                  final shapes = snapshot.data!;
                  if (shapes.isEmpty) {
                    return const Text('이 슬라이드에는 삭제할 수 있는 도형이 없습니다.');
                  }
                  return DropdownButton<int>(
                    key: const ValueKey('pptx-shape-delete-target'),
                    hint: const Text('도형 선택'),
                    value: shapeId,
                    isExpanded: true,
                    items: [
                      for (final shape in shapes)
                        DropdownMenuItem(
                          value: shape.shapeId,
                          child: Text(
                            _shapeLabel(shape),
                            key: ValueKey(
                              'pptx-shape-delete-target-${shape.shapeId}',
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (value) => setState(() => _shapeId = value),
                  );
                },
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('pptx-shape-delete-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        FilledButton(
          key: const ValueKey('pptx-shape-delete-confirm'),
          style: FilledButton.styleFrom(
            backgroundColor: colors.error,
            foregroundColor: colors.onError,
          ),
          onPressed: index == null || shapeId == null
              ? null
              : () =>
                    Navigator.of(context)
                        .pop((slideIndex: index, shapeId: shapeId)),
          child: const Text('삭제하고 저장'),
        ),
      ],
    );
  }

  String _slideLabel(PptxShapeDeleteSlide slide) => [
    '슬라이드 ${slide.index + 1}',
    if (slide.hidden) '숨김',
    if (slide.title?.trim() case final title? when title.isNotEmpty) title,
  ].join(' · ');

  String _shapeLabel(PptxShapeDeleteTarget shape) {
    final kind = switch (shape.kind) {
      'textBox' => '텍스트 상자',
      'freeform' => '자유형 도형',
      _ => '도형',
    };
    final name = shape.name.trim();
    return [if (name.isNotEmpty) name, '$kind ${shape.shapeId}'].join(' · ');
  }
}
