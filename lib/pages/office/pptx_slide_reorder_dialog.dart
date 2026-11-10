import 'dart:math';

import 'package:flutter/material.dart';
import 'package:saber/data/office/pptx_slide_reorder.dart';

typedef PptxSlideMoveSelection = ({
  int sourceIndex,
  int targetIndex,
  bool after,
});

Future<PptxSlideMoveSelection?> choosePptxSlideMove(
  BuildContext context,
  PptxSlideReorderPlan plan,
) {
  int? sourceIndex, targetIndex;
  var after = false;
  return showDialog<PptxSlideMoveSelection>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, update) {
        final source = sourceIndex;
        final target = targetIndex;
        final destination = source != null && target != null
            ? PptxSlideReorderEngine.destinationIndex(
                source,
                target,
                after: after,
              )
            : null;
        final canMove =
            source != null &&
            target != null &&
            plan.canMove(source, target, after: after);
        final sectionOnly = canMove && destination == source;
        return AlertDialog(
          title: const Text('슬라이드 순서 변경'),
          scrollable: true,
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  source == null
                      ? '이동할 슬라이드를 선택하세요.'
                      : '슬라이드 ${source + 1}의 새 위치를 선택하세요.',
                ),
                if (source != null) ...[
                  TextButton(
                    onPressed: () => update(() {
                      sourceIndex = null;
                      targetIndex = null;
                      after = false;
                    }),
                    child: const Text('다른 슬라이드 선택'),
                  ),
                  Wrap(
                    spacing: 8,
                    children: [
                      ChoiceChip(
                        key: const ValueKey('pptx-slide-reorder-before'),
                        label: const Text('대상 앞'),
                        selected: !after,
                        onSelected: (_) => update(() => after = false),
                      ),
                      ChoiceChip(
                        key: const ValueKey('pptx-slide-reorder-after'),
                        label: const Text('대상 뒤'),
                        selected: after,
                        onSelected: (_) => update(() => after = true),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 8),
                SizedBox(
                  height: min(
                    MediaQuery.sizeOf(context).height * .4,
                    plan.slideCount * 84.0,
                  ),
                  child: ListView.builder(
                    primary: false,
                    itemCount: plan.slideCount,
                    itemBuilder: (context, index) {
                      final slide = plan.slides[index];
                      final number = slide.index + 1;
                      final enabled = slide.index != source;
                      final selected = slide.index == target;
                      final description = [
                        if (slide.title case final title?
                            when title.trim().isNotEmpty)
                          title.trim(),
                        if (slide.sectionTitle case final section?
                            when section.trim().isNotEmpty)
                          '${section.trim()} 구역'
                        else if (slide.sectionGroup != null)
                          '이름 없는 구역',
                      ].join('\n');
                      return ListTile(
                        key: ValueKey(
                          'pptx-slide-reorder-${source == null ? 'source' : 'target'}-$number',
                        ),
                        enabled: enabled,
                        selected: selected,
                        title: Text(
                          '슬라이드 $number${slide.hidden ? ' · 숨김' : ''}',
                        ),
                        subtitle: description.isEmpty
                            ? null
                            : Text(
                                description,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                        trailing: selected ? const Icon(Icons.check) : null,
                        onTap: !enabled
                            ? null
                            : () => update(() {
                                if (source == null) {
                                  sourceIndex = slide.index;
                                } else {
                                  targetIndex = slide.index;
                                }
                              }),
                      );
                    },
                  ),
                ),
                if (destination != null)
                  Text(
                    sectionOnly
                        ? '번호는 그대로 두고 대상 슬라이드의 구역으로 옮깁니다.'
                        : destination == source
                        ? '선택한 위치는 현재 순서와 같습니다.'
                        : '이동 후 ${destination + 1}번 슬라이드가 됩니다.',
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              key: const ValueKey('pptx-slide-reorder-cancel'),
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('취소'),
            ),
            FilledButton(
              key: const ValueKey('pptx-slide-reorder-confirm'),
              onPressed: source == null || target == null || !canMove
                  ? null
                  : () => Navigator.of(context).pop((
                      sourceIndex: source,
                      targetIndex: target,
                      after: after,
                    )),
              child: Text(sectionOnly ? '구역을 바꾸고 저장' : '순서를 바꾸고 저장'),
            ),
          ],
        );
      },
    ),
  );
}
