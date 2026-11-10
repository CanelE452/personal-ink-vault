import 'package:flutter/material.dart';
import 'package:saber/data/office/pptx_shape_order.dart';

typedef PptxShapeOrderDraft = ({
  int slideIndex,
  int shapeId,
  PptxShapeOrderDirection direction,
  int fromIndex,
  int shapeCount,
});

Future<PptxShapeOrderDraft?> choosePptxShapeOrder(
  BuildContext context,
  PptxShapeOrderPlan plan,
  Future<List<PptxShapeOrderTarget>> Function(int slideIndex) loadSlide,
) => showDialog<PptxShapeOrderDraft>(
  context: context,
  builder: (_) => _PptxShapeOrderDialog(plan, loadSlide),
);

class _PptxShapeOrderDialog extends StatefulWidget {
  const new(this.plan, this.loadSlide);

  final PptxShapeOrderPlan plan;
  final Future<List<PptxShapeOrderTarget>> Function(int slideIndex) loadSlide;

  @override
  State<_PptxShapeOrderDialog> createState() => _PptxShapeOrderDialogState();
}

class _PptxShapeOrderDialogState extends State<_PptxShapeOrderDialog> {
  int? _slide;
  int? _position;
  PptxShapeOrderDirection? _direction;
  Future<List<PptxShapeOrderTarget>>? _targets;

  void _selectSlide(int index) => setState(() {
    _slide = index;
    _position = null;
    _direction = null;
    _targets = widget.loadSlide(index);
  });

  @override
  Widget build(
    BuildContext context,
  ) => FutureBuilder<List<PptxShapeOrderTarget>>(
    future: _targets,
    builder: (context, snapshot) {
      final slide = _slide;
      final position = _position;
      final direction = _direction;
      final targets = snapshot.connectionState == ConnectionState.done
          ? snapshot.data
          : null;
      final destination = position == null || targets == null
          ? null
          : direction?.destination(position, targets.length);
      return AlertDialog(
        title: const Text('개체 겹침 순서'),
        scrollable: true,
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('같은 슬라이드에서 개체를 앞이나 뒤로 옮깁니다. 목록은 뒤에서 앞으로 표시됩니다.'),
              const SizedBox(height: 12),
              DropdownButton<int>(
                key: const ValueKey('pptx-shape-order-slide'),
                value: slide,
                isExpanded: true,
                hint: const Text('슬라이드 선택'),
                items: [
                  for (final choice in widget.plan.slides)
                    DropdownMenuItem(
                      value: choice.index,
                      child: Text(
                        [
                          '슬라이드 ${choice.index + 1}',
                          if (choice.hidden) '숨김',
                          if (choice.title?.trim() case final title?
                              when title.isNotEmpty)
                            title,
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (index) {
                  if (index != null && index != slide) _selectSlide(index);
                },
              ),
              if (slide != null && targets == null)
                if (snapshot.connectionState != ConnectionState.done)
                  const LinearProgressIndicator(semanticsLabel: '개체 순서를 불러오는 중')
                else ...[
                  const Text('개체 순서를 불러오지 못했습니다.'),
                  TextButton(
                    onPressed: () => _selectSlide(slide),
                    child: const Text('다시 시도'),
                  ),
                ],
              if (targets != null)
                if (targets.length < 2)
                  const Text('이 슬라이드에는 순서를 바꿀 수 있는 개체가 없습니다.')
                else ...[
                  DropdownButton<int>(
                    key: const ValueKey('pptx-shape-order-target'),
                    value: position,
                    isExpanded: true,
                    hint: const Text('개체 선택'),
                    items: [
                      for (final (index, target) in targets.indexed)
                        DropdownMenuItem(
                          value: index,
                          child: Text(
                            _targetLabel(target, index),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (index) => setState(() {
                      _position = index;
                      _direction = null;
                    }),
                  ),
                  if (position != null)
                    DropdownButton<PptxShapeOrderDirection>(
                      key: const ValueKey('pptx-shape-order-direction'),
                      value: direction,
                      isExpanded: true,
                      hint: const Text('이동 방향 선택'),
                      items: [
                        for (final option in PptxShapeOrderDirection.values)
                          DropdownMenuItem(
                            value: option,
                            enabled:
                                option.destination(position, targets.length) !=
                                null,
                            child: Text(option.label),
                          ),
                      ],
                      onChanged: (value) => setState(() => _direction = value),
                    ),
                ],
              if (destination != null)
                Text('${position! + 1}단에서 ${destination + 1}단으로 이동'),
            ],
          ),
        ),
        actions: [
          TextButton(
            key: const ValueKey('pptx-shape-order-cancel'),
            onPressed: () => Navigator.pop(context),
            child: const Text('취소'),
          ),
          FilledButton(
            key: const ValueKey('pptx-shape-order-confirm'),
            onPressed:
                slide == null ||
                    position == null ||
                    targets == null ||
                    direction == null ||
                    destination == null
                ? null
                : () => Navigator.pop(context, (
                    slideIndex: slide,
                    shapeId: targets[position].shapeId,
                    direction: direction,
                    fromIndex: position,
                    shapeCount: targets.length,
                  )),
            child: const Text('순서를 바꾸고 저장'),
          ),
        ],
      );
    },
  );

  String _targetLabel(PptxShapeOrderTarget target, int index) {
    final kind = switch (target.kind) {
      'picture' => '사진',
      'textBox' => '텍스트 상자',
      'group' => '그룹',
      'connector' => '연결선',
      'graphicFrame' => '그래픽',
      _ => '도형',
    };
    final name = target.name.trim();
    return '${index + 1}단 · $kind${name.isEmpty ? '' : ' · $name'}';
  }
}
