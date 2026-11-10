import 'package:flex_color_picker/flex_color_picker.dart';
import 'package:flutter/material.dart';
import 'package:saber/data/office/pptx_slide_clone.dart';
import 'package:saber/data/office/pptx_slide_delete.dart';
import 'package:saber/data/office/pptx_slide_insert.dart';
import 'package:saber/data/office/pptx_slide_layout.dart';
import 'package:saber/data/office/pptx_slide_reorder.dart';

Future<({int index, int? layoutId})?> choosePptxSlideToInsert(
  BuildContext context,
  PptxSlideInsertPlan plan,
) async {
  final index = await _chooseSlide(
    context,
    [
      for (final slide in plan.slides)
        (
          index: slide.index,
          hidden: slide.hidden,
          enabled: slide.canInsert,
          title: slide.title,
          section: slide.sectionName,
        ),
    ],
    title: '슬라이드를 추가할 위치 선택',
    description: '선택한 슬라이드 바로 뒤에 새 슬라이드를 추가합니다.',
    action: '추가하고 저장',
    selectedAction: (index) =>
        plan.slides[index].layouts.isEmpty ? '추가하고 저장' : '레이아웃 선택',
    unavailable: '추가 불가',
    keyPrefix: 'pptx-slide-insert',
  );
  if (!context.mounted || index == null) return null;
  final layouts = plan.slides[index].layouts;
  if (layouts.isEmpty) return (index: index, layoutId: null);

  final layoutId = await _chooseLayout(
    context,
    layouts,
    title: '새 슬라이드 레이아웃',
    action: '추가하고 저장',
    keyPrefix: 'pptx-slide-insert',
    includeBlank: true,
  );
  if (layoutId == null) return null;
  return (index: index, layoutId: layoutId == 0 ? null : layoutId);
}

Future<({int index, int layoutId})?> choosePptxSlideLayout(
  BuildContext context,
  PptxSlideLayoutPlan plan,
) async {
  final index = await _chooseSlide(
    context,
    [
      for (final slide in plan.slides)
        (
          index: slide.index,
          hidden: slide.hidden,
          enabled: slide.layouts.isNotEmpty,
          title: slide.title,
          section: slide.sectionName,
        ),
    ],
    title: '레이아웃을 변경할 슬라이드 선택',
    description: '현재 슬라이드와 호환되는 레이아웃을 선택할 수 있습니다.',
    action: '레이아웃 선택',
    unavailable: '호환 레이아웃 없음',
    keyPrefix: 'pptx-slide-change',
  );
  if (!context.mounted || index == null) return null;
  final layoutId = await _chooseLayout(
    context,
    plan.slides[index].layouts,
    title: '슬라이드 레이아웃 변경',
    action: '변경하고 저장',
    keyPrefix: 'pptx-slide-change',
  );
  return layoutId == null ? null : (index: index, layoutId: layoutId);
}

Future<int?> _chooseLayout(
  BuildContext context,
  List<PptxSlideInsertLayout> layouts, {
  required String title,
  required String action,
  required String keyPrefix,
  bool includeBlank = false,
}) {
  const blankLabel = '빈 슬라이드';
  final labels = layouts.map(_layoutLabel).toList();
  final labelCounts = <String, int>{if (includeBlank) blankLabel: 1};
  for (final label in labels) {
    labelCounts.update(label, (count) => count + 1, ifAbsent: () => 1);
  }
  int? selected = includeBlank ? 0 : null;
  return showDialog<int>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, update) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 420,
          child: DropdownButtonFormField<int>(
            key: ValueKey('$keyPrefix-layout'),
            initialValue: selected,
            isExpanded: true,
            decoration: const InputDecoration(labelText: '레이아웃'),
            items: [
              if (includeBlank)
                const DropdownMenuItem(value: 0, child: Text(blankLabel)),
              for (var index = 0; index < layouts.length; index++)
                DropdownMenuItem(
                  value: layouts[index].id,
                  child: Text(
                    labelCounts[labels[index]]! > 1
                        ? '${index + 1} · ${labels[index]}'
                        : labels[index],
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: (value) => update(() => selected = value),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('취소'),
          ),
          FilledButton(
            key: ValueKey('$keyPrefix-layout-confirm'),
            onPressed: selected == null
                ? null
                : () => Navigator.of(context).pop(selected),
            child: Text(action),
          ),
        ],
      ),
    ),
  );
}

String _layoutLabel(PptxSlideInsertLayout layout) => layout.name == layout.kind
    ? switch (layout.kind) {
        'blank' => '마스터 빈 레이아웃',
        'title' => '제목 슬라이드',
        'tx' || 'obj' => '제목 및 내용',
        'titleOnly' => '제목만',
        'secHead' => '구역 제목',
        'cust' => '사용자 지정 레이아웃',
        _ => layout.name,
      }
    : layout.name;

Future<int?> choosePptxSlideToClone(
  BuildContext context,
  PptxSlideClonePlan plan,
) => _chooseSlide(
  context,
  [
    for (final slide in plan.slides)
      (
        index: slide.index,
        hidden: slide.hidden,
        enabled: slide.canDuplicate,
        title: slide.title,
        section: null,
      ),
  ],
  title: '복제할 슬라이드 선택',
  description: '복제본은 선택한 슬라이드 바로 다음에 추가됩니다.',
  action: '복제하고 저장',
  unavailable: '복제 불가',
  keyPrefix: 'pptx-slide-clone',
);

Future<int?> choosePptxSlideToDelete(
  BuildContext context,
  PptxSlideDeletePlan plan,
) => _chooseSlide(
  context,
  [
    for (final slide in plan.slides)
      (
        index: slide.index,
        hidden: slide.hidden,
        enabled: slide.canDelete,
        title: slide.title,
        section: slide.sectionName,
      ),
  ],
  title: '삭제할 슬라이드 선택',
  description: '선택한 슬라이드를 새 판본에서 삭제합니다. 이전 판본과 PDF 필기는 판본 기록에 남습니다.',
  action: '삭제하고 저장',
  unavailable: '삭제 불가',
  keyPrefix: 'pptx-slide-delete',
  destructive: true,
);

Future<int?> choosePptxSlideDisplay(
  BuildContext context,
  PptxSlideReorderPlan plan,
) => _chooseSlide(
  context,
  [
    for (final slide in plan.slides)
      (
        index: slide.index,
        hidden: slide.hidden,
        enabled: true,
        title: slide.title,
        section: slide.sectionTitle,
      ),
  ],
  title: '발표에서 숨기거나 표시할 슬라이드 선택',
  description: '발표에서 숨겨도 필기용 PDF에는 슬라이드가 포함됩니다.',
  action: '변경하고 저장',
  selectedAction: (index) => plan.slides[index].hidden ? '표시하고 저장' : '숨기고 저장',
  unavailable: '변경 불가',
  keyPrefix: 'pptx-slide-display',
);

Future<({int index, String background})?> choosePptxSlideBackground(
  BuildContext context,
  PptxSlideReorderPlan plan,
) async {
  final index = await _chooseSlide(
    context,
    [
      for (final slide in plan.slides)
        (
          index: slide.index,
          hidden: slide.hidden,
          enabled:
              slide.background != null && slide.background != 'unsupported',
          title: slide.title,
          section: null,
        ),
    ],
    title: '배경을 바꿀 슬라이드 선택',
    description: '선택한 슬라이드의 단색 배경을 바꿉니다.',
    action: '색상 선택',
    unavailable: '편집 불가',
    keyPrefix: 'pptx-slide-background',
  );
  if (!context.mounted || index == null) return null;
  final original = plan.slides[index].background!;
  final inherited = original == 'inherited';
  var color = inherited
      ? Colors.white
      : Color(0xff000000 | int.parse(original.substring(1), radix: 16));
  String rgb() =>
      '#${(color.toARGB32() & 0xffffff).toRadixString(16).padLeft(6, '0').toUpperCase()}';
  final background = await showDialog<String>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, update) => AlertDialog(
        title: Text('슬라이드 ${index + 1} 배경색'),
        content: SingleChildScrollView(
          child: ColorPicker(
            key: const ValueKey('pptx-slide-background-picker'),
            color: color,
            pickersEnabled: const {ColorPickerType.wheel: true},
            showColorCode: true,
            onColorChanged: (value) => update(() => color = value),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('취소'),
          ),
          if (!inherited)
            TextButton(
              key: const ValueKey('pptx-slide-background-reset'),
              onPressed: () => Navigator.of(context).pop('inherited'),
              child: const Text('기본 배경으로 복원'),
            ),
          FilledButton(
            key: const ValueKey('pptx-slide-background-save'),
            onPressed: rgb() == original
                ? null
                : () => Navigator.of(context).pop(rgb()),
            child: const Text('배경 저장'),
          ),
        ],
      ),
    ),
  );
  return background == null ? null : (index: index, background: background);
}

Future<int?> _chooseSlide(
  BuildContext context,
  List<({int index, bool hidden, bool enabled, String? title, String? section})>
  slides, {
  required String title,
  required String description,
  required String action,
  required String unavailable,
  required String keyPrefix,
  String Function(int)? selectedAction,
  bool destructive = false,
}) {
  int? selected;
  return showDialog<int>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, update) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(description),
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(context).height * .45,
                ),
                child: ListView.builder(
                  primary: false,
                  shrinkWrap: true,
                  itemCount: slides.length,
                  itemBuilder: (context, index) {
                    final slide = slides[index];
                    final number = slide.index + 1;
                    final details = [
                      if (slide.title?.trim() case final title?
                          when title.isNotEmpty)
                        title,
                      if (slide.section?.trim() case final section?
                          when section.isNotEmpty)
                        '$section 구역',
                    ];
                    return ListTile(
                      key: ValueKey('$keyPrefix-target-$number'),
                      enabled: slide.enabled,
                      selected: selected == slide.index,
                      title: Text('슬라이드 $number${slide.hidden ? ' · 숨김' : ''}'),
                      subtitle: details.isEmpty
                          ? null
                          : Text(
                              details.join(' · '),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                      trailing: !slide.enabled
                          ? Text(unavailable)
                          : selected == slide.index
                          ? const Icon(Icons.check)
                          : null,
                      onTap: slide.enabled
                          ? () => update(() => selected = slide.index)
                          : null,
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            key: ValueKey('$keyPrefix-cancel'),
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('취소'),
          ),
          FilledButton(
            key: ValueKey('$keyPrefix-confirm'),
            style: destructive
                ? FilledButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.error,
                    foregroundColor: Theme.of(context).colorScheme.onError,
                  )
                : null,
            onPressed: selected == null
                ? null
                : () => Navigator.of(context).pop(selected),
            child: Text(
              selected == null
                  ? action
                  : selectedAction?.call(selected!) ?? action,
            ),
          ),
        ],
      ),
    ),
  );
}
