import 'package:flutter/material.dart';
import 'package:saber/data/office/pptx_text_box.dart';

typedef PptxTableAddDraft = ({int slideIndex, int rows, int columns});

Future<PptxTableAddDraft?> choosePptxTable(
  BuildContext context,
  PptxTextBoxPlan plan,
) => showDialog<PptxTableAddDraft>(
  context: context,
  builder: (context) => _PptxTableAddDialog(plan),
);

class _PptxTableAddDialog extends StatefulWidget {
  const new(this.plan);

  final PptxTextBoxPlan plan;

  @override
  State<_PptxTableAddDialog> createState() => _PptxTableAddDialogState();
}

class _PptxTableAddDialogState extends State<_PptxTableAddDialog> {
  int? _slideIndex;
  var _rows = 2;
  var _columns = 2;

  Widget _sizeField({
    required String name,
    required String label,
    required int value,
    required int maximum,
    required ValueChanged<int> onChanged,
  }) => DropdownButtonFormField<int>(
    key: ValueKey('pptx-table-add-$name'),
    initialValue: value,
    decoration: InputDecoration(labelText: label),
    isExpanded: true,
    items: [
      for (var count = 1; count <= maximum; count++)
        DropdownMenuItem(value: count, child: Text('$count')),
    ],
    onChanged: (value) {
      if (value != null) setState(() => onChanged(value));
    },
  );

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('PPTX 표 추가'),
    scrollable: true,
    content: SizedBox(
      width: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DropdownButtonFormField<int>(
            key: const ValueKey('pptx-table-add-slide'),
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
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _sizeField(
                  name: 'rows',
                  label: '행',
                  value: _rows,
                  maximum: PptxTableAddEngine.maxRows,
                  onChanged: (value) => _rows = value,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _sizeField(
                  name: 'columns',
                  label: '열',
                  value: _columns,
                  maximum: PptxTableAddEngine.maxColumns,
                  onChanged: (value) => _columns = value,
                ),
              ),
            ],
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        key: const ValueKey('pptx-table-add-cancel'),
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('취소'),
      ),
      FilledButton(
        key: const ValueKey('pptx-table-add-confirm'),
        onPressed: _slideIndex == null
            ? null
            : () => Navigator.of(
                context,
              ).pop((slideIndex: _slideIndex!, rows: _rows, columns: _columns)),
        child: const Text('추가하고 저장'),
      ),
    ],
  );
}
