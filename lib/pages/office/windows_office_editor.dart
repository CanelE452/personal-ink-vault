import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ink_vault_core/ink_vault_core.dart' show newId;
import 'package:pdfrx/pdfrx.dart';
import 'package:saber/data/office/hwp_office_engine.dart' show HwpOfficeEngine;
import 'package:saber/data/office/office_image_asset.dart';
import 'package:saber/data/office/windows_office_engine.dart';
import 'package:saber/pages/office/docx_table_dialog.dart';
import 'package:saber/pages/office/hwp_table_structure_dialog.dart';

part 'windows_word_editor.dart';
part 'windows_presentation_editor.dart';

class WindowsOfficeEditor extends StatefulWidget {
  const new({
    super.key,
    required this.snapshot,
    required this.onCommit,
    required this.onBack,
    this.previewPath,
    this.onDirtyChanged,
    this.allowFormatting = true,
    this.allowedTextStyleProperties,
    this.allowParagraphAlignment = false,
    this.allowHwpTableStructure = false,
    this.allowHwpParagraphDeletion = false,
    this.previewNotice,
    this.onCommitWithAssets,
    this.imagePicker,
    this.onPreview,
  });
  final WindowsOfficeSnapshot snapshot;
  final Future<void> Function(List<WindowsOfficeOperation>) onCommit;
  final FutureOr<void> Function() onBack;
  final String? previewPath;
  final ValueChanged<bool>? onDirtyChanged;
  final bool allowFormatting;
  final Set<String>? allowedTextStyleProperties;
  final bool allowParagraphAlignment;
  final bool allowHwpTableStructure;
  final bool allowHwpParagraphDeletion;
  final String? previewNotice;
  final Future<void> Function(
    List<WindowsOfficeOperation>,
    Map<String, WindowsOfficeImageAsset>,
  )?
  onCommitWithAssets;
  final Future<WindowsOfficeImageAsset?> Function()? imagePicker;
  final Future<WindowsOfficeDraftPreview> Function(
    List<WindowsOfficeOperation>,
    Map<String, WindowsOfficeImageAsset>,
  )?
  onPreview;
  @override
  State<WindowsOfficeEditor> createState() => WindowsOfficeEditorState();
}

class WindowsOfficeEditorState extends State<WindowsOfficeEditor> {
  static const _teal = Color(0xff16828a);
  final _paragraphs = <String, _TextDraft>{};
  final _paragraphAlignments = <String, String>{};
  final _paragraphInsertions = <String, ({String id, String text})>{};
  WindowsOfficeParagraph? _paragraphDeletion;
  ({
    String id,
    String referenceId,
    int rows,
    int columns,
    List<List<String>>? cells,
  })?
  _hwpTableInsertion;
  ({String id, HwpTableStructureChoice choice})? _hwpTableStructure;
  final _cells = <String, Map<String, _TextDraft>>{};
  final _slides = <_SlideDraft>[];
  final _legacySlideOperations = <WindowsOfficeOperation>[];
  final _imageAssets = <String, WindowsOfficeImageAsset>{};
  _WordDocumentDraft? _wordDraft;
  _PresentationDraft? _pptDraft;
  Future<void>? _saving;
  var _busy = false;
  var _dirty = false;
  var _showPreview = false;
  var _showOriginalSlide = false;
  String? _slideDuplicationId;
  String? _error;
  String? _selectedShape;
  var _selectedSlide = 0;
  var _generation = 0;
  var _pickingImage = false;

  @override
  void initState() {
    super.initState();
    _loadDrafts();
  }

  void _loadDrafts() {
    if (widget.snapshot.kind == 'word' && widget.snapshot.blocks != null) {
      _wordDraft = _WordDocumentDraft(widget.snapshot, _changed, this);
      return;
    }
    for (final paragraph in widget.snapshot.paragraphs) {
      final alignment = paragraph.paragraphFormat?.alignment;
      if (alignment != null) _paragraphAlignments[paragraph.id] = alignment;
      _paragraphs[paragraph.id] = _TextDraft(
        paragraph.text,
        fontSize: paragraph.fontSize,
        bold: paragraph.bold,
        color: paragraph.color,
        details: paragraph.textDetails,
        targetKind: 'paragraph',
        id: paragraph.id,
        requireGraphemeBoundaries: widget.allowedTextStyleProperties != null,
        onChanged: _changed,
      );
    }
    for (final table in widget.snapshot.tables) {
      _cells[table.id] = {
        for (final cell in table.cells.entries)
          cell.key: _TextDraft(
            cell.value,
            details: table.cellTextDetails[cell.key],
            targetKind: 'cell',
            id: table.id,
            cell: cell.key,
            requireGraphemeBoundaries:
                widget.allowedTextStyleProperties != null,
            onChanged: _changed,
          ),
      };
    }
    for (var i = 0; i < widget.snapshot.slides.length; i++) {
      _slides.add(
        _SlideDraft.fromSnapshot(widget.snapshot.slides[i], i + 1, _changed),
      );
    }
    if (_slides.isNotEmpty &&
        widget.snapshot.kind == 'presentation' &&
        widget.snapshot.masters != null) {
      _pptDraft = _PresentationDraft(this);
    }
  }

  @override
  void didUpdateWidget(covariant WindowsOfficeEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.snapshot, widget.snapshot)) {
      _generation++;
      _disposeDrafts();
      _paragraphs.clear();
      _paragraphAlignments.clear();
      _paragraphInsertions.clear();
      _paragraphDeletion = null;
      _hwpTableInsertion = null;
      _hwpTableStructure = null;
      _cells.clear();
      _slides.clear();
      _legacySlideOperations.clear();
      _imageAssets.clear();
      _slideDuplicationId = null;
      _selectedShape = null;
      _selectedSlide = 0;
      _dirty = false;
      _busy = false;
      _pickingImage = false;
      _error = null;
      _showPreview = false;
      _showOriginalSlide = false;
      _loadDrafts();
    }
  }

  List<WindowsOfficeOperation> _operations() {
    if (_wordDraft case final word?) return word.operations;
    if (_pptDraft case final presentation?) return presentation.operations;
    final result = <WindowsOfficeOperation>[];
    for (final paragraph in widget.snapshot.paragraphs) {
      final draft = _paragraphs[paragraph.id]!;
      if (draft.isRich) {
        result.addAll(draft.operations);
      } else if (draft.text.text != paragraph.text)
        result.add(
          WindowsOfficeOperation.paragraphText(paragraph.id, draft.text.text),
        );
      if (!draft.isRich && widget.allowFormatting && draft.styleChanged)
        result.add(
          WindowsOfficeOperation.paragraphStyle(
            paragraph.id,
            fontSize: draft.changedFont,
            bold: draft.changedBold,
            color: draft.changedColor,
          ),
        );
      final alignment = _paragraphAlignments[paragraph.id];
      if (widget.allowParagraphAlignment &&
          paragraph.paragraphFormat?.alignment != null &&
          alignment != null &&
          alignment != paragraph.paragraphFormat!.alignment)
        result.add(
          WindowsOfficeOperation.paragraphFormat(
            id: paragraph.id,
            expectedTextSha256: sha256
                .convert(utf8.encode(paragraph.text))
                .toString(),
            alignment: alignment,
          ),
        );
    }
    for (final table in widget.snapshot.tables) {
      for (final cell in table.cells.entries) {
        final draft = _cells[table.id]![cell.key]!;
        final value = draft.text.text;
        if (draft.isRich) {
          result.addAll(draft.operations);
        } else if (value != cell.value)
          result.add(
            WindowsOfficeOperation.tableCellText(table.id, cell.key, value),
          );
      }
    }
    final slidesById = {for (final slide in _slides) slide.id: slide};
    for (final operation in _legacySlideOperations) {
      if (operation.toJson() case {
        'op': 'slideAdd',
        'id': final String id,
        'index': final int index,
      }) {
        final slide = slidesById[id];
        final title = slide?.shapes
            .where((shape) => shape.id == slide.implicitShapeId)
            .singleOrNull;
        result.add(
          WindowsOfficeOperation.slideAdd(
            id: id,
            index: index,
            text: title?.text.text.text ?? '',
          ),
        );
      } else {
        result.add(operation);
      }
    }
    for (final slide in _slides) {
      for (final id in slide.sourceShapeIds) {
        if (!slide.shapes.any((shape) => shape.id == id)) {
          result.add(WindowsOfficeOperation.shapeDelete(id));
        }
      }
      if (widget.allowFormatting && slide.backgroundChanged) {
        result.add(
          WindowsOfficeOperation.slideBackground(
            slide.id,
            fillStyle: slide.changedBackgroundStyle,
            fillColor: slide.changedBackgroundColor,
          ),
        );
      }
      for (final shape in slide.shapes) {
        if (shape.isNew && shape.shapeKind == 'image') {
          result.add(
            WindowsOfficeOperation.imageAdd(
              id: shape.id,
              slideId: slide.id,
              assetId: shape.assetId!,
              x: shape.value('x'),
              y: shape.value('y'),
              width: shape.value('width'),
              height: shape.value('height'),
            ),
          );
        } else if (shape.isNew) {
          result.add(
            WindowsOfficeOperation.shapeAdd(
              id: shape.id,
              slideId: slide.id,
              shapeKind: shape.shapeKind!,
              x: shape.value('x'),
              y: shape.value('y'),
              width: shape.value('width'),
              height: shape.value('height'),
              text: shape.text.text.text,
            ),
          );
        } else if (shape.text.isRich) {
          result.addAll(shape.text.operations);
        } else if (slide.previewPage != null &&
            shape.text.text.text != shape.text.originalText)
          result.add(
            WindowsOfficeOperation.shapeText(shape.id, shape.text.text.text),
          );
        if (!shape.isNew &&
            shape.shapeKind == 'image' &&
            shape.assetId != null) {
          result.add(
            WindowsOfficeOperation.imageReplace(
              id: shape.id,
              assetId: shape.assetId!,
            ),
          );
        }
        if (widget.allowFormatting && shape.id == slide.implicitShapeId)
          result.add(
            WindowsOfficeOperation.shapeStyle(
              shape.id,
              fontSize: double.tryParse(shape.text.font.text) ?? 12,
              bold: shape.text.bold,
              color: shape.text.color,
            ),
          );
        else if (!shape.text.isRich &&
            widget.allowFormatting &&
            shape.text.styleChanged)
          result.add(
            WindowsOfficeOperation.shapeStyle(
              shape.id,
              fontSize: shape.text.changedFont,
              bold: shape.text.changedBold,
              color: shape.text.changedColor,
            ),
          );
        if (!shape.isNew && shape.geometryChanged)
          result.add(
            WindowsOfficeOperation.shapeGeometry(
              shape.id,
              x: shape.value('x'),
              y: shape.value('y'),
              width: shape.value('width'),
              height: shape.value('height'),
            ),
          );
        if (shape.rotationChanged) {
          result.add(
            WindowsOfficeOperation.imageRotate(
              id: shape.id,
              expectedRotationHundredths: shape.image!.rotationHundredths!,
              rotationHundredths: shape.rotationHundredths!,
            ),
          );
        }
        if (widget.allowFormatting && shape.appearanceChanged) {
          result.add(
            WindowsOfficeOperation.shapeAppearance(
              shape.id,
              fillStyle: shape.changedFillStyle,
              fillColor: shape.changedFillColor,
              lineStyle: shape.changedLineStyle,
              lineColor: shape.changedLineColor,
              lineWidth: shape.changedLineWidth,
            ),
          );
        }
      }
    }
    for (final entry in _paragraphInsertions.entries) {
      result.add(
        WindowsOfficeOperation.paragraphInsert(
          id: entry.value.id,
          referenceId: entry.key,
          position: 'after',
          expectedTextSha256: _TextDraft._digest(
            _paragraphs[entry.key]!.originalText,
          ),
          text: entry.value.text,
        ),
      );
    }
    if (_paragraphDeletion case final paragraph?) {
      result.add(
        WindowsOfficeOperation.paragraphDelete(
          id: paragraph.id,
          expectedTextSha256: _TextDraft._digest(paragraph.text),
        ),
      );
    }
    if (_hwpTableInsertion case final table?) {
      result.add(
        WindowsOfficeOperation.hwpTableInsert(
          id: table.id,
          referenceId: table.referenceId,
          expectedTextSha256: _TextDraft._digest(
            _paragraphs[table.referenceId]!.originalText,
          ),
          rows: table.rows,
          columns: table.columns,
          cells: table.cells,
        ),
      );
    }
    if (_hwpTableStructure case final draft?) {
      result.add(
        WindowsOfficeOperation.hwpTableStructure(
          id: draft.id,
          action: draft.choice.action.name,
          index: draft.choice.index,
        ),
      );
    }
    return result;
  }

  void _changed({String? movedSlideId}) {
    if (!mounted) return;
    _pptDraft?.record(movedSlideId: movedSlideId);
    var invalid = false;
    try {
      _validateDrafts();
    } on FormatException {
      invalid = true;
    }
    final dirty =
        invalid || _slideDuplicationId != null || _operations().isNotEmpty;
    setState(() {
      _error =
          _wordDraft?.error ??
          _pptDraft?.sourceTextError ??
          [
            ..._paragraphs.values,
            for (final cells in _cells.values) ...cells.values,
            for (final slide in _pptDraft?.owners ?? _slides)
              for (final shape in slide.shapes) shape.text,
          ].map((draft) => draft.lastEditError).whereType<String>().firstOrNull;
      if (_dirty != dirty) {
        _dirty = dirty;
        widget.onDirtyChanged?.call(dirty);
      }
    });
  }

  void _validateDrafts() {
    _pptDraft?.validate();
    _wordDraft?.validate();
    for (final insertion in _paragraphInsertions.values) {
      if (!HwpOfficeEngine.isValidParagraphInsertText(insertion.text)) {
        throw const FormatException('추가할 문단은 비어 있지 않은 한 줄로 4,096자까지 입력하세요.');
      }
    }
    for (final paragraph in _paragraphs.values) {
      paragraph.validate(
        typography:
            widget.allowFormatting ||
            _showsRestrictedTextStyle(paragraph) &&
                _allowsTextStyle('fontSize'),
      );
    }
    for (final table in _cells.values) {
      for (final draft in table.values) {
        draft.validate();
      }
    }
    for (final slide in _pptDraft?.owners ?? _slides) {
      for (final shape in slide.shapes) {
        shape.validate();
      }
    }
  }

  Future<void> save() {
    final pending = _saving;
    if (pending != null) return pending;
    late Future<void> tracked;
    tracked = _saveNow().whenComplete(() {
      if (identical(_saving, tracked)) _saving = null;
    });
    _saving = tracked;
    return tracked;
  }

  Future<void> _saveNow() async {
    if (!mounted ||
        (_wordDraft?.locked ?? false) ||
        (_wordDraft?.composing ?? false))
      return;
    final generation = _generation;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      _validateDrafts();
      FocusManager.instance.primaryFocus?.unfocus();
      var operations = _operations();
      if (_slideDuplicationId case final id?) {
        if (operations.isNotEmpty) {
          throw const FormatException('슬라이드 복제를 취소한 뒤 기존 편집을 먼저 저장하세요.');
        }
        operations = [WindowsOfficeOperation.slideDuplicate(id)];
      }
      if (_hwpTableInsertion != null && operations.length != 1) {
        throw const FormatException('표 추가를 취소한 뒤 기존 편집을 먼저 저장하세요.');
      }
      if (_hwpTableStructure != null && operations.length != 1) {
        throw const FormatException('표 편집을 취소한 뒤 기존 편집을 먼저 저장하세요.');
      }
      if (_paragraphDeletion != null && operations.length != 1) {
        throw const FormatException('문단 삭제를 취소한 뒤 기존 편집을 먼저 저장하세요.');
      }
      if (operations.isNotEmpty) {
        final assetIds = {
          for (final operation in operations)
            if (operation.toJson()['assetId'] case final String id) id,
        };
        final assets = {for (final id in assetIds) id: _imageAssets[id]!};
        if (assets.isNotEmpty) {
          final commit = widget.onCommitWithAssets;
          if (commit == null)
            throw const FormatException('이 편집기에서는 이미지 저장을 지원하지 않습니다.');
          await commit(operations, Map.unmodifiable(assets));
        } else {
          await widget.onCommit(operations);
        }
      }
      if (!mounted || generation != _generation) return;
      _slideDuplicationId = null;
      if (_dirty) {
        _dirty = false;
        widget.onDirtyChanged?.call(false);
      }
      await widget.onBack();
    } catch (error) {
      if (mounted && generation == _generation)
        setState(() => _error = '저장하지 못했습니다. 편집 내용은 남아 있습니다.\n$error');
      rethrow;
    } finally {
      if (mounted && generation == _generation) setState(() => _busy = false);
    }
  }

  void _trySave() => unawaited(save().catchError((Object _) {}));

  bool get _wordTextLocked =>
      _busy ||
      _hwpTableInsertion != null ||
      _hwpTableStructure != null ||
      _paragraphDeletion != null;
  bool get _formattingLocked => _pptMutationLocked || _wordTextLocked;

  Widget _style(_TextDraft draft, String id, {bool shape = false}) =>
      draft.isRich
      ? _rangeStyle(draft, id, shape: shape)
      : Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            IconButton.filledTonal(
              key: ValueKey('office-bold-$id'),
              tooltip: '굵게',
              isSelected: draft.bold,
              onPressed: _formattingLocked
                  ? null
                  : () {
                      if (_formattingLocked || !mounted) return;
                      draft.bold = !draft.bold;
                      _changed();
                    },
              icon: const Icon(Icons.format_bold),
            ),
            SizedBox(
              width: 120,
              child: TextField(
                key: ValueKey(shape ? 'office-shape-font' : 'office-font-$id'),
                controller: draft.font,
                readOnly: _formattingLocked,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: '글자 크기(pt)',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                onChanged: (_) => _changed(),
              ),
            ),
            PopupMenuButton<int>(
              enabled: !_formattingLocked,
              tooltip: '글자 색',
              onSelected: (color) {
                if (_formattingLocked || !mounted) return;
                draft.color = color;
                _changed();
              },
              itemBuilder: (_) => [
                for (final color in const <int, String>{
                  0: '검정',
                  0xb3261e: '빨강',
                  0x2457a7: '파랑',
                  0x16828a: '청록',
                  0xa86500: '황토',
                }.entries)
                  PopupMenuItem(
                    value: color.key,
                    child: Row(
                      children: [
                        Icon(
                          Icons.circle,
                          color: Color(0xff000000 | color.key),
                          size: 18,
                        ),
                        const SizedBox(width: 12),
                        Text(color.value),
                      ],
                    ),
                  ),
              ],
              icon: Icon(
                Icons.format_color_text,
                color: Color(0xff000000 | draft.color),
              ),
            ),
          ],
        );

  bool _allowsTextStyle(String property) =>
      widget.allowedTextStyleProperties?.contains(property) ??
      widget.allowFormatting;

  bool _showsRestrictedTextStyle(_TextDraft draft) =>
      draft.isRich &&
      draft.details!.canStyle &&
      (widget.allowedTextStyleProperties?.any(
            const {
              'bold',
              'italic',
              'underline',
              'fontSize',
              'fontFamily',
              'color',
            }.contains,
          ) ??
          false);

  Widget _rangeStyle(_TextDraft draft, String id, {required bool shape}) {
    final enabled = !_formattingLocked && draft.canStyleSelection;
    void apply(Map<String, Object?> style) {
      if (_formattingLocked) return;
      try {
        draft.applySelectedStyle(style);
        _changed();
      } on FormatException catch (error) {
        setState(() => _error = error.message);
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final item in [
              ('bold', '굵게', Icons.format_bold),
              ('italic', '기울임', Icons.format_italic),
              ('underline', '밑줄', Icons.format_underlined),
            ].where((item) => _allowsTextStyle(item.$1)))
              IconButton.filledTonal(
                key: ValueKey('office-${item.$1}-$id'),
                tooltip: item.$2,
                isSelected: draft.selectedStyle(item.$1) as bool?,
                onPressed: enabled
                    ? () =>
                          apply({item.$1: draft.selectedStyle(item.$1) != true})
                    : null,
                icon: Icon(item.$3),
              ),
            if (_allowsTextStyle('fontSize'))
              SizedBox(
                width: 120,
                child: TextField(
                  key: ValueKey(
                    shape ? 'office-shape-font' : 'office-font-$id',
                  ),
                  controller: draft.font,
                  enabled: enabled,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '글자 크기(pt)',
                    hintText: '혼합',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (value) {
                    final size = double.tryParse(value);
                    if (size != null &&
                        size.isFinite &&
                        size >= 1 &&
                        size <= 400) {
                      apply({'fontSize': size});
                    } else {
                      _changed();
                    }
                  },
                ),
              ),
            if (_allowsTextStyle('fontFamily'))
              SizedBox(
                width: 170,
                child: TextField(
                  key: ValueKey('office-font-family-$id'),
                  controller: draft.fontFamily,
                  enabled: enabled,
                  decoration: const InputDecoration(
                    labelText: '글꼴',
                    hintText: '혼합',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (value) {
                    if (value.trim().isNotEmpty)
                      apply({'fontFamily': value.trim()});
                  },
                ),
              ),
            if (_allowsTextStyle('color'))
              PopupMenuButton<int>(
                key: ValueKey('office-text-color-$id'),
                tooltip: '글자 색',
                enabled: enabled,
                onSelected: (color) => apply({'color': color}),
                itemBuilder: (_) => [
                  for (final entry in const <int, String>{
                    0: '검정',
                    0xb3261e: '빨강',
                    0x2457a7: '파랑',
                    0x16828a: '청록',
                    0xa86500: '황토',
                  }.entries)
                    PopupMenuItem(value: entry.key, child: Text(entry.value)),
                ],
                icon: Icon(
                  Icons.format_color_text,
                  color: draft.selectedStyle('color') == null
                      ? null
                      : Color(
                          0xff000000 | (draft.selectedStyle('color') as int),
                        ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          draft.canStyleSelection
              ? '선택한 글자에 서식 적용'
              : '글자를 선택하면 해당 범위의 서식을 바꿀 수 있습니다.',
          style: Theme.of(context).textTheme.labelSmall,
        ),
      ],
    );
  }

  Widget _paragraphAlignment(WindowsOfficeParagraph paragraph) => Wrap(
    spacing: 4,
    runSpacing: 4,
    children: [
      for (final item in const [
        ('left', '왼쪽 정렬', Icons.format_align_left),
        ('center', '가운데 정렬', Icons.format_align_center),
        ('right', '오른쪽 정렬', Icons.format_align_right),
        ('justify', '양쪽 정렬', Icons.format_align_justify),
      ])
        IconButton.filledTonal(
          key: ValueKey(
            'office-paragraph-alignment-${paragraph.id}-${item.$1}',
          ),
          tooltip: item.$2,
          isSelected: _paragraphAlignments[paragraph.id] == item.$1,
          onPressed: _wordTextLocked
              ? null
              : () {
                  if (_wordTextLocked || !mounted) return;
                  _paragraphAlignments[paragraph.id] = item.$1;
                  _changed();
                },
          icon: Icon(item.$3),
        ),
    ],
  );

  Widget _paragraphInsertion(WindowsOfficeParagraph paragraph) {
    final insertion = _paragraphInsertions[paragraph.id];
    if (insertion == null) {
      return Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: _wordTextLocked
              ? null
              : () {
                  _paragraphInsertions.putIfAbsent(
                    paragraph.id,
                    () => (id: newId(), text: ''),
                  );
                  _changed();
                },
          icon: const Icon(Icons.add),
          label: const Text('이 문단 아래 추가'),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: TextFormField(
              key: ValueKey('office-hwpx-insert-text-${paragraph.id}'),
              initialValue: insertion.text,
              autofocus: true,
              readOnly: _wordTextLocked,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: '추가할 문단',
              ),
              onChanged: (text) {
                if (_wordTextLocked) return;
                _paragraphInsertions[paragraph.id] = (
                  id: insertion.id,
                  text: text,
                );
                _changed();
              },
            ),
          ),
          IconButton(
            key: ValueKey('office-hwpx-remove-insert-${paragraph.id}'),
            tooltip: '추가 문단 취소',
            onPressed: _wordTextLocked
                ? null
                : () {
                    _paragraphInsertions.remove(paragraph.id);
                    _changed();
                  },
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
  }

  Widget _paragraphDeletionControl(WindowsOfficeParagraph paragraph) {
    if (_paragraphDeletion?.id == paragraph.id) {
      return ListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('삭제 예정'),
        subtitle: const Text('저장하고 닫으면 문서와 PDF에 반영됩니다.'),
        trailing: TextButton(
          key: ValueKey('office-hwp-undo-delete-paragraph-${paragraph.id}'),
          onPressed: _busy
              ? null
              : () {
                  _paragraphDeletion = null;
                  _changed();
                },
          child: const Text('삭제 취소'),
        ),
      );
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        key: ValueKey('office-hwp-delete-paragraph-${paragraph.id}'),
        onPressed: _wordTextLocked
            ? null
            : () {
                if (_dirty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('기존 편집을 저장한 뒤 문단을 삭제하세요.')),
                  );
                  return;
                }
                FocusManager.instance.primaryFocus?.unfocus();
                _paragraphDeletion = paragraph;
                _changed();
              },
        icon: const Icon(Icons.delete_outline),
        label: const Text('이 문단 삭제'),
      ),
    );
  }

  Future<void> _chooseHwpTable(WindowsOfficeParagraph paragraph) async {
    if (_wordTextLocked) return;
    if (_dirty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('기존 편집을 저장한 뒤 표를 추가하세요.')));
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    final generation = _generation;
    final cells = await chooseHwpTable(context);
    if (!mounted ||
        generation != _generation ||
        cells == null ||
        _wordTextLocked) {
      return;
    }
    if (_dirty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('기존 편집을 저장한 뒤 표를 추가하세요.')));
      return;
    }
    _hwpTableInsertion = (
      id: newId(),
      referenceId: paragraph.id,
      rows: cells.length,
      columns: cells.first.length,
      cells: cells.any((row) => row.any((text) => text.isNotEmpty))
          ? cells
          : null,
    );
    _changed();
  }

  Widget _hwpxTableInsertion(WindowsOfficeParagraph paragraph) {
    final table = _hwpTableInsertion;
    if (table != null && table.referenceId == paragraph.id) {
      return ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(
          '${table.cells == null ? '빈 표' : '표'} '
          '${table.rows}행 × ${table.columns}열',
        ),
        subtitle: Text(
          table.cells == null
              ? '저장한 뒤 원본 편집을 다시 열어 셀을 수정할 수 있습니다.'
              : '저장하면 표와 셀 내용이 함께 추가됩니다.',
        ),
        trailing: IconButton(
          key: ValueKey('office-hwpx-cancel-table-${paragraph.id}'),
          tooltip: '표 추가 취소',
          onPressed: _busy
              ? null
              : () {
                  _hwpTableInsertion = null;
                  _changed();
                },
          icon: const Icon(Icons.close),
        ),
      );
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        key: ValueKey('office-hwpx-add-table-${paragraph.id}'),
        onPressed: _wordTextLocked ? null : () => _chooseHwpTable(paragraph),
        icon: const Icon(Icons.table_chart_outlined),
        label: const Text('표 추가'),
      ),
    );
  }

  Future<void> _chooseHwpTableStructure(
    String id,
    WindowsOfficeHwpTableStructure structure,
  ) async {
    if (_wordTextLocked || !widget.allowHwpTableStructure) return;
    if (_dirty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('기존 편집을 저장한 뒤 표를 편집하세요.')));
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    final generation = _generation;
    final choice = await chooseHwpTableStructure(context, structure);
    if (!mounted ||
        choice == null ||
        generation != _generation ||
        _wordTextLocked ||
        _dirty ||
        !widget.allowHwpTableStructure) {
      return;
    }
    _hwpTableStructure = (id: id, choice: choice);
    _changed();
  }

  Widget _hwpTableStructureControl(
    String id,
    WindowsOfficeHwpTableStructure structure,
  ) {
    final staged = _hwpTableStructure;
    if (staged?.id == id) {
      final choice = staged!.choice;
      final position = hwpTableStructurePosition(
        choice.action,
        choice.index,
        structure,
      );
      return ListTile(
        contentPadding: EdgeInsets.zero,
        title: Text('${hwpTableStructureLabel(choice.action)} · $position'),
        subtitle: const Text('저장하고 닫으면 표에 반영됩니다.'),
        trailing: IconButton(
          key: ValueKey('office-hwpx-cancel-structure-$id'),
          tooltip: '표 편집 취소',
          onPressed: _busy
              ? null
              : () {
                  _hwpTableStructure = null;
                  _changed();
                },
          icon: const Icon(Icons.close),
        ),
      );
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        key: ValueKey('office-hwpx-edit-structure-$id'),
        onPressed: _wordTextLocked
            ? null
            : () => _chooseHwpTableStructure(id, structure),
        icon: const Icon(Icons.table_chart_outlined),
        label: Text(hwpTableStructureTitle(structure)),
      ),
    );
  }

  Widget _word() => _wordDraft != null
      ? _structuredWord()
      : ListView(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 40),
          children: [
            for (var i = 0; i < widget.snapshot.paragraphs.length; i++) ...[
              Text(
                '문단 ${i + 1}',
                style: Theme.of(context).textTheme.labelLarge,
              ),
              const SizedBox(height: 8),
              if (widget.allowFormatting ||
                  _showsRestrictedTextStyle(
                    _paragraphs[widget.snapshot.paragraphs[i].id]!,
                  ))
                _style(
                  _paragraphs[widget.snapshot.paragraphs[i].id]!,
                  widget.snapshot.paragraphs[i].id,
                ),
              if (widget.allowParagraphAlignment &&
                  widget.snapshot.paragraphs[i].paragraphFormat?.alignment !=
                      null)
                _paragraphAlignment(widget.snapshot.paragraphs[i]),
              const SizedBox(height: 8),
              TextField(
                key: ValueKey(
                  'office-paragraph-${widget.snapshot.paragraphs[i].id}',
                ),
                controller: _paragraphs[widget.snapshot.paragraphs[i].id]!.text,
                textAlign: switch (_paragraphAlignments[widget
                    .snapshot
                    .paragraphs[i]
                    .id]) {
                  'center' => TextAlign.center,
                  'right' => TextAlign.right,
                  'justify' => TextAlign.justify,
                  _ => TextAlign.start,
                },
                readOnly:
                    _wordTextLocked ||
                    !_paragraphs[widget.snapshot.paragraphs[i].id]!.canReplace,
                minLines: 2,
                maxLines: null,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  filled: true,
                  fillColor: Colors.white,
                ),
                onChanged: (_) => _changed(),
              ),
              if (widget.snapshot.paragraphs[i].structure?.canInsertAfter ==
                  true)
                _paragraphInsertion(widget.snapshot.paragraphs[i]),
              if (_paragraphDeletion?.id == widget.snapshot.paragraphs[i].id ||
                  (widget.allowHwpParagraphDeletion &&
                      widget.snapshot.paragraphs[i].structure?.canDelete == true))
                _paragraphDeletionControl(widget.snapshot.paragraphs[i]),
              if (widget.snapshot.supportsHwpTableInsert &&
                  widget.snapshot.paragraphs[i].tableInsertAnchor)
                _hwpxTableInsertion(widget.snapshot.paragraphs[i]),
              const SizedBox(height: 24),
            ],
            for (var i = 0; i < widget.snapshot.tables.length; i++) ...[
              Text(
                '표 ${i + 1}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              if (widget.snapshot.tables[i].structure case final structure?
                  when widget.allowHwpTableStructure &&
                      HwpTableStructureAction.values.any(structure.allows))
                _hwpTableStructureControl(
                  widget.snapshot.tables[i].id,
                  structure,
                ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (final cell
                      in _cells[widget.snapshot.tables[i].id]!.entries)
                    SizedBox(
                      width: _showsRestrictedTextStyle(cell.value) ? 320 : 210,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (_showsRestrictedTextStyle(cell.value))
                            _rangeStyle(
                              cell.value,
                              '${widget.snapshot.tables[i].id}-${cell.key}',
                              shape: false,
                            ),
                          TextField(
                            key: ValueKey(
                              'office-cell-${widget.snapshot.tables[i].id}-${cell.key}',
                            ),
                            controller: cell.value.text,
                            readOnly: _wordTextLocked || !cell.value.canReplace,
                            minLines: 1,
                            maxLines: null,
                            decoration: InputDecoration(
                              labelText: cell.key,
                              border: const OutlineInputBorder(),
                              filled: true,
                              fillColor: Colors.white,
                            ),
                            onChanged: (_) => _changed(),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 24),
            ],
            if (_paragraphs.isEmpty && _cells.isEmpty)
              const Text('편집할 문단이나 표가 없습니다. 원본 미리보기에서 내용을 확인하세요.'),
          ],
        );

  _SlideDraft get _slide => _pptDraft?.owner ?? _slides[_selectedSlide];
  _ShapeDraft? get _shape =>
      _slide.shapes.where((shape) => shape.id == _selectedShape).singleOrNull;
  bool get _pptContextLocked =>
      _busy ||
      _pickingImage ||
      _slideDuplicationId != null ||
      (_pptDraft?.contextLocked ?? false);
  bool get _pptMutationLocked =>
      _pptContextLocked || (_pptDraft?.hasSourceStructure ?? false);
  bool get _pptEditingLocked =>
      _busy ||
      _pickingImage ||
      (_pptDraft?.locked ?? false) ||
      (_pptDraft?.composing ?? false) ||
      (_wordDraft?.locked ?? false) ||
      (_wordDraft?.composing ?? false);
  void _rebuildPresentation(VoidCallback change) {
    if (mounted) setState(change);
  }

  void _presentationChange(VoidCallback change, {String? movedSlideId}) {
    final draft = _pptDraft;
    if (draft != null) {
      draft.action(change, movedSlideId: movedSlideId);
    } else {
      change();
      _changed();
    }
  }

  bool _canRotatePicture(_ShapeDraft shape) =>
      widget.allowFormatting &&
      _pptDraft?.editingMasterId == null &&
      shape.shapeKind == 'image' &&
      !shape.isNew &&
      shape.image?.canRotate == true &&
      shape.rotationHundredths != null;

  bool get _pictureRotationLocked =>
      _pptMutationLocked || (_pptDraft?._hasSourceText ?? false);

  void _rotatePicture(_ShapeDraft shape, int delta) {
    if (_pictureRotationLocked ||
        !_canRotatePicture(shape) ||
        !identical(_shape, shape))
      return;
    _presentationChange(() {
      shape.rotationHundredths = (shape.rotationHundredths! + delta) % 36000;
      _showOriginalSlide = false;
    });
  }

  void _addSlide() {
    if (_pptMutationLocked ||
        !widget.allowFormatting ||
        _pptDraft?.editingMasterId != null)
      return;
    final old = _slide;
    _presentationChange(() {
      final added = _SlideDraft.blank(
        _pptDraft?.freshId() ?? newId(),
        old.width,
        old.height,
      );
      _slides.insert(++_selectedSlide, added);
      if (_pptDraft == null) {
        _legacySlideOperations.add(
          WindowsOfficeOperation.slideAdd(
            id: added.id,
            index: _selectedSlide,
            text: '',
          ),
        );
      }
      _selectedShape = null;
    });
  }

  bool get _canDuplicateSlide => widget.snapshot.slides.any(
    (slide) => slide.id == _slide.id && slide.canDuplicate,
  );

  void _stageSlideDuplicate() {
    if (_pptMutationLocked || !_canDuplicateSlide) return;
    if (_dirty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('기존 편집을 저장한 뒤 슬라이드를 복제하세요.')),
      );
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    _slideDuplicationId = _slide.id;
    _changed();
  }

  void _deleteSlide() {
    if (_pptMutationLocked ||
        !widget.allowFormatting ||
        _slides.length < 2 ||
        _pptDraft?.editingMasterId != null)
      return;
    _presentationChange(() {
      final removed = _slides.removeAt(_selectedSlide);
      if (_pptDraft == null) {
        if (_legacySlideOperations.lastOrNull?.toJson()
            case {'op': 'slideAdd', 'id': final String id}
            when id == removed.id) {
          _legacySlideOperations.removeLast();
        } else {
          _legacySlideOperations.add(
            WindowsOfficeOperation.slideDelete(removed.id),
          );
        }
      }
      removed.dispose();
      _selectedSlide = math.min(_selectedSlide, _slides.length - 1);
      _selectedShape = null;
    });
    _pruneAssets();
  }

  void _moveSlide(int delta) {
    if (_pptMutationLocked ||
        !widget.allowFormatting ||
        _pptDraft?.editingMasterId != null)
      return;
    final target = _selectedSlide + delta;
    if (target < 0 || target >= _slides.length) return;
    final movedSlideId = _slide.id;
    _presentationChange(() {
      _slides.insert(target, _slides.removeAt(_selectedSlide));
      _selectedSlide = target;
      if (_pptDraft == null) {
        _legacySlideOperations.add(
          WindowsOfficeOperation.slideMove(movedSlideId, target),
        );
      }
    }, movedSlideId: movedSlideId);
  }

  void _addShape(String kind) {
    if (_pptMutationLocked ||
        !mounted ||
        !widget.allowFormatting ||
        _slides.isEmpty ||
        (_pptDraft?.editingMasterId != null &&
            (kind == 'roundedRectangle' || kind == 'rightArrow')))
      return;
    _presentationChange(() {
      final shape = _ShapeDraft.added(
        _pptDraft?.freshId() ?? newId(),
        kind,
        _slide.width,
        _slide.height,
      );
      _slide.shapes.add(shape);
      _selectedShape = shape.id;
      _showOriginalSlide = false;
    });
  }

  void _deleteShape() {
    if (_pptMutationLocked || !widget.allowFormatting) return;
    final shape = _shape;
    if (shape == null || !shape.canDelete) return;
    _presentationChange(() {
      _selectedShape = null;
      _slide.shapes.remove(shape);
      shape.dispose();
    });
    _pruneAssets();
  }

  void _pruneAssets() {
    final used = {
      for (final slide in _pptDraft?.owners ?? _slides)
        for (final shape in slide.shapes)
          if (shape.assetId != null) shape.assetId!,
      ...?_pptDraft?.pinnedAssets,
      ...?_wordDraft?.pinnedAssets,
    };
    _imageAssets.removeWhere((id, _) => !used.contains(id));
  }

  Future<WindowsOfficeImageAsset?> _defaultImagePicker() async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['png', 'jpg', 'jpeg'],
      dialogTitle: '문서에 넣을 사진 선택',
    );
    if (file == null) return null;
    final length = await file.length();
    if (length != null && length > WindowsOfficeImageAsset.maxBytes) {
      throw const FormatException('사진은 20MiB 이하로 선택하세요.');
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in file.readAsByteStream()) {
      if (bytes.length + chunk.length > WindowsOfficeImageAsset.maxBytes) {
        throw const FormatException('사진은 20MiB 이하로 선택하세요.');
      }
      bytes.add(chunk);
    }
    return WindowsOfficeImageAsset.fromBytes(bytes.takeBytes());
  }

  Future<void> _pickWordImage([String? id]) async {
    final word = _wordDraft;
    if (word == null ||
        _pickingImage ||
        !(id == null ? word.canAddImage : word.canReplaceImage(id)))
      return;
    final target = id == null ? word._imageTarget(moving: false) : null;
    final generation = _generation;
    setState(() {
      _pickingImage = true;
      _error = null;
    });
    bool current() =>
        mounted && generation == _generation && identical(_wordDraft, word);
    try {
      final asset = await (widget.imagePicker ?? _defaultImagePicker)();
      if (!current() ||
          asset == null ||
          !widget.allowFormatting ||
          widget.onCommitWithAssets == null)
        return;
      if (_imageAssets.values.fold<int>(
                0,
                (sum, image) => sum + image.byteLength,
              ) +
              asset.byteLength >
          WindowsOfficeImageAsset.maxBatchBytes) {
        throw const FormatException('한 번에 저장할 사진은 총 80MiB 이하로 선택하세요.');
      }
      setState(() => _pickingImage = false);
      if (id == null) {
        if (!word.canAddImage || word._imageTarget(moving: false) != target)
          return;
      } else if (!word.canReplaceImage(id))
        return;
      final assetId = newId();
      _imageAssets[assetId] = asset;
      if (id == null)
        word.addImage(assetId, asset);
      else
        word.replaceImage(id, assetId);
      _pruneAssets();
    } catch (error) {
      if (current())
        setState(
          () => _error = error is FormatException
              ? error.message.toString()
              : '사진을 가져오지 못했습니다. 다시 선택하세요.',
        );
    } finally {
      if (current()) setState(() => _pickingImage = false);
    }
  }

  Future<void> _pickImage({bool replace = false}) async {
    if (_pptMutationLocked ||
        _pickingImage ||
        !mounted ||
        !widget.allowFormatting ||
        widget.onCommitWithAssets == null ||
        _slides.isEmpty)
      return;
    final slide = _slide;
    final shape = replace ? _shape : null;
    if (replace &&
        (shape == null ||
            shape.shapeKind != 'image' ||
            (_pptDraft?.editingMasterId != null &&
                shape.presentationObject == true) ||
            !(shape.isNew || shape.image?.canReplace == true)))
      return;
    final generation = _generation;
    setState(() {
      _pickingImage = true;
      _error = null;
    });
    try {
      final asset = await (widget.imagePicker ?? _defaultImagePicker)();
      if (!mounted ||
          generation != _generation ||
          !widget.allowFormatting ||
          widget.onCommitWithAssets == null ||
          asset == null ||
          !(_pptDraft?.owners ?? _slides).contains(slide) ||
          _slide != slide ||
          replace && (!slide.shapes.contains(shape) || _shape != shape))
        return;
      final replacedId = shape?.assetId;
      final usedBytes = _imageAssets.entries
          .where((entry) => _pptDraft != null || entry.key != replacedId)
          .fold<int>(0, (sum, entry) => sum + entry.value.byteLength);
      if (usedBytes + asset.byteLength >
          WindowsOfficeImageAsset.maxBatchBytes) {
        throw const FormatException('한 번에 저장할 사진은 총 80MiB 이하로 선택하세요.');
      }
      _presentationChange(() {
        final assetId = newId();
        _imageAssets[assetId] = asset;
        if (replace) {
          shape!.assetId = assetId;
          shape.imageBytes = asset.bytes;
        } else {
          final added = _ShapeDraft.image(
            _pptDraft?.freshId() ?? newId(),
            assetId,
            asset,
            slide.width,
            slide.height,
          );
          slide.shapes.add(added);
          _selectedShape = added.id;
        }
        _showOriginalSlide = false;
      });
      _pruneAssets();
    } catch (error) {
      if (mounted && generation == _generation)
        setState(() => _error = '사진을 가져오지 못했습니다.\n$error');
    } finally {
      if (mounted && generation == _generation)
        setState(() => _pickingImage = false);
    }
  }

  Widget _fillControls({
    required String prefix,
    required String label,
    required String? style,
    required int? color,
    required ValueChanged<String> onStyle,
    required ValueChanged<int> onColor,
  }) => Wrap(
    spacing: 8,
    runSpacing: 8,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      PopupMenuButton<String>(
        key: ValueKey('$prefix-style'),
        enabled: !_pptMutationLocked,
        tooltip: '$label 방식',
        onSelected: (value) {
          if (_pptMutationLocked || !mounted) return;
          onStyle(value);
          _showOriginalSlide = false;
          _changed();
        },
        itemBuilder: (_) => [
          PopupMenuItem(
            key: ValueKey('$prefix-none'),
            value: 'none',
            child: const Text('없음'),
          ),
          PopupMenuItem(
            key: ValueKey('$prefix-solid'),
            value: 'solid',
            child: const Text('단색'),
          ),
        ],
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            border: Border.all(color: const Color(0xffaab8b2)),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(switch (style) {
                'none' => '없음',
                'solid' => '단색',
                _ => '기존 효과 유지',
              }),
              const SizedBox(width: 8),
              const Icon(Icons.arrow_drop_down, size: 18),
            ],
          ),
        ),
      ),
      PopupMenuButton<int>(
        key: ValueKey('$prefix-color'),
        enabled: !_pptMutationLocked,
        tooltip: '$label 색',
        onSelected: (value) {
          if (_pptMutationLocked || !mounted) return;
          onColor(value);
          _showOriginalSlide = false;
          _changed();
        },
        itemBuilder: (_) => [
          for (final entry in const <int, String>{
            0: '검정',
            0xffffff: '흰색',
            0xb3261e: '빨강',
            0x2457a7: '파랑',
            0x16828a: '청록',
            0xa86500: '황토',
          }.entries)
            PopupMenuItem(
              key: ValueKey('$prefix-color-${entry.key}'),
              value: entry.key,
              child: Row(
                children: [
                  Icon(
                    Icons.circle,
                    color: Color(0xff000000 | entry.key),
                    size: 18,
                  ),
                  const SizedBox(width: 12),
                  Text(entry.value),
                ],
              ),
            ),
        ],
        icon: Icon(
          Icons.color_lens_outlined,
          color: color == null ? null : Color(0xff000000 | color),
        ),
      ),
    ],
  );

  Widget _slideList(bool narrow) => ListView(
    scrollDirection: narrow ? Axis.horizontal : Axis.vertical,
    padding: const EdgeInsets.all(8),
    children: [
      for (var i = 0; i < _slides.length; i++)
        SizedBox(
          width: narrow ? 110 : null,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 8, right: 6),
            child: OutlinedButton(
              key: ValueKey('office-slide-${_slides[i].id}'),
              style: OutlinedButton.styleFrom(
                backgroundColor: i == _selectedSlide
                    ? const Color(0xffdff0ed)
                    : Colors.white,
                side: BorderSide(
                  color: i == _selectedSlide ? _teal : const Color(0xffd5ddd8),
                ),
                minimumSize: const Size(90, 62),
              ),
              onPressed: _pptDraft != null
                  ? _pptContextLocked
                        ? null
                        : () => _pptDraft!.switchSlide(i)
                  : () => setState(() {
                      _selectedSlide = i;
                      _selectedShape = null;
                    }),
              child: Text('슬라이드 ${i + 1}'),
            ),
          ),
        ),
    ],
  );

  Widget _slideCanvas() => LayoutBuilder(
    builder: (context, constraints) {
      final slide = _slide;
      final width = math
          .min(
            constraints.maxWidth - 32,
            (constraints.maxHeight - 32) * slide.width / slide.height,
          )
          .clamp(1.0, double.infinity)
          .toDouble();
      final scale = width / slide.width;
      final presentation = _pptDraft;
      final sourcePath = widget.previewPath ?? widget.snapshot.previewPdfPath;
      final originalPage =
          widget.snapshot.slides.indexWhere((item) => item.id == slide.id) + 1;
      final path = presentation == null
          ? sourcePath
          : presentation.editingMasterId != null
          ? null
          : _showOriginalSlide
          ? sourcePath
          : presentation.previewPath ??
                (presentation.operations.isEmpty ? sourcePath : null);
      final page = presentation == null
          ? slide.previewPage
          : _showOriginalSlide || presentation.previewPath == null
          ? originalPage > 0
                ? originalPage
                : null
          : _selectedSlide + 1;
      final draftView =
          !_showOriginalSlide &&
          (path == null ||
              page == null ||
              presentation == null && slide.originalChanged);
      Widget background = ColoredBox(
        color: slide.backgroundStyle == 'solid'
            ? Color(0xff000000 | (slide.backgroundColor ?? 0xffffff))
            : Colors.white,
      );
      final master = presentation?.masters
          .where((item) => item.id == slide.masterId)
          .singleOrNull;
      if (draftView &&
          slide.backgroundStyle == 'none' &&
          master?.backgroundStyle == 'solid') {
        background = ColoredBox(
          color: Color(0xff000000 | (master!.backgroundColor ?? 0xffffff)),
        );
      }
      if (!draftView && path != null && page != null) {
        background = PdfDocumentViewBuilder.file(
          path,
          key: ValueKey('office-preview-$path'),
          builder: (context, document) => document == null
              ? const Center(child: CircularProgressIndicator())
              : PdfPageView(
                  document: document,
                  pageNumber: page,
                  decoration: const BoxDecoration(),
                ),
          errorBuilder: (_, _, _) => const Center(
            child: Text('원본 미리보기를 열지 못했습니다. 문서 내용 편집은 계속할 수 있습니다.'),
          ),
        );
      }
      return Center(
        child: SizedBox(
          width: width,
          height: slide.height * scale,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: const Color(0xffcbd5ce)),
            ),
            child: ClipRect(
              child: Stack(
                children: [
                  Positioned.fill(child: background),
                  if (draftView &&
                      presentation?.editingMasterId == null &&
                      slide.showMasterObjects == true &&
                      master != null)
                    for (final shape in master.shapes.where(
                      (shape) => shape.presentationObject != true,
                    ))
                      _shapeCanvas(
                        shape,
                        scale,
                        paint: true,
                        interactive: false,
                      ),
                  for (final shape in slide.shapes)
                    _shapeCanvas(
                      shape,
                      scale,
                      paint: draftView || (!_showOriginalSlide && shape.isNew),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );

  Widget _shapeCanvas(
    _ShapeDraft shape,
    double scale, {
    required bool paint,
    bool interactive = true,
  }) {
    final size = Size(
      math.max(0, shape.value('width') * scale),
      math.max(0, shape.value('height') * scale),
    );
    final target = Size(math.max(20, size.width), math.max(20, size.height));
    final inset = Offset(
      (target.width - size.width) / 2,
      (target.height - size.height) / 2,
    );
    return Positioned(
      left: shape.value('x') * scale - inset.dx,
      top: shape.value('y') * scale - inset.dy,
      width: target.width,
      height: target.height,
      child: GestureDetector(
        key: ValueKey(
          interactive
              ? 'office-shape-${shape.id}'
              : 'office-master-decoration-${shape.id}',
        ),
        behavior: HitTestBehavior.opaque,
        onTap: !interactive || _pptContextLocked
            ? null
            : () => setState(() {
                _selectedShape = shape.id;
                _pptDraft?.selectionChanged();
              }),
        onPanStart:
            interactive &&
                widget.allowFormatting &&
                shape.canEditGeometry &&
                !_pptMutationLocked
            ? (_) => setState(() {
                _selectedShape = shape.id;
                _pptDraft?.selectionChanged();
                _pptDraft?.beginGesture();
              })
            : null,
        onPanEnd: interactive ? (_) => _pptDraft?.endGesture() : null,
        onPanCancel: interactive ? () => _pptDraft?.endGesture() : null,
        onPanUpdate:
            !interactive ||
                !widget.allowFormatting ||
                !shape.canEditGeometry ||
                _pptMutationLocked
            ? null
            : (details) {
                if (_busy) return;
                shape.setValue(
                  'x',
                  shape.value('x') + details.delta.dx / scale,
                );
                shape.setValue(
                  'y',
                  shape.value('y') + details.delta.dy / scale,
                );
                _changed();
              },
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(
              color: !interactive
                  ? Colors.transparent
                  : shape.id == _selectedShape
                  ? _teal
                  : _teal.withValues(alpha: .22),
              width: shape.id == _selectedShape ? 2 : 1,
            ),
          ),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              if (paint && shape.shapeKind == 'image')
                Positioned(
                  left: inset.dx,
                  top: inset.dy,
                  width: size.width,
                  height: size.height,
                  child: IgnorePointer(
                    child: shape.imageBytes == null
                        ? const ColoredBox(
                            color: Color(0xffeef1eb),
                            child: Center(child: Icon(Icons.image_outlined)),
                          )
                        : Transform.rotate(
                            angle:
                                (shape.rotationHundredths ?? 0) *
                                math.pi /
                                18000,
                            child: Image.memory(
                              shape.imageBytes!,
                              fit: BoxFit.fill,
                              cacheWidth: 1024,
                              cacheHeight: 1024,
                              errorBuilder: (_, _, _) => const Center(
                                child: Icon(Icons.broken_image_outlined),
                              ),
                            ),
                          ),
                  ),
                ),
              if (paint && shape.shapeKind != 'image')
                Positioned.fill(
                  child: IgnorePointer(
                    child: CustomPaint(
                      painter: _ShapePainter(shape, scale, inset, size),
                    ),
                  ),
                ),
              if (interactive &&
                  widget.allowFormatting &&
                  shape.canEditGeometry &&
                  shape.id == _selectedShape)
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: GestureDetector(
                    key: const ValueKey('office-shape-resize'),
                    behavior: HitTestBehavior.opaque,
                    onPanStart: (_) => _pptDraft?.beginGesture(),
                    onPanEnd: (_) => _pptDraft?.endGesture(),
                    onPanCancel: () => _pptDraft?.endGesture(),
                    onPanUpdate: (details) {
                      if (_pptMutationLocked) return;
                      final minimum = shape.shapeKind == 'line' ? 0.0 : .1;
                      final nextWidth = math.max(
                        minimum,
                        shape.value('width') + details.delta.dx / scale,
                      );
                      final nextHeight = math.max(
                        minimum,
                        shape.value('height') + details.delta.dy / scale,
                      );
                      if (nextWidth == 0 && nextHeight == 0) return;
                      shape.setValue('width', nextWidth);
                      shape.setValue('height', nextHeight);
                      _changed();
                    },
                    child: const SizedBox(
                      width: 20,
                      height: 20,
                      child: Icon(Icons.open_in_full, size: 16, color: _teal),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _inspector() {
    final shape = _shape;
    return AbsorbPointer(
      absorbing: _pptDraft?.locked ?? false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '선택한 개체',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (widget.allowFormatting && shape != null && shape.canDelete)
                  IconButton(
                    key: const ValueKey('office-delete-shape'),
                    tooltip: '개체 삭제',
                    onPressed: _pptMutationLocked ? null : _deleteShape,
                    icon: const Icon(Icons.delete_outline),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            if (_pptDraft != null) _presentationTableInspector(),
            if (_pptDraft?.selectedTable != null)
              const SizedBox.shrink()
            else if (shape == null)
              const Text('슬라이드의 테두리를 누르면 글자와 위치를 바꿀 수 있습니다.')
            else ...[
              if (_pptDraft?.editingMasterId != null &&
                  shape.presentationObject == true)
                const Text('이 자리표시자의 내용은 슬라이드에서 편집하세요.'),
              if (shape.shapeKind == 'image' &&
                  widget.allowFormatting &&
                  widget.onCommitWithAssets != null &&
                  !(_pptDraft?.editingMasterId != null &&
                      shape.presentationObject == true) &&
                  (shape.isNew || shape.image?.canReplace == true)) ...[
                OutlinedButton.icon(
                  key: const ValueKey('office-replace-image'),
                  onPressed: _pptMutationLocked
                      ? null
                      : () => unawaited(_pickImage(replace: true)),
                  icon: const Icon(Icons.image_outlined),
                  label: const Text('사진 교체'),
                ),
                const SizedBox(height: 16),
              ],
              if (_canRotatePicture(shape)) ...[
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 4,
                  children: [
                    IconButton(
                      key: const ValueKey('office-image-rotate-left'),
                      tooltip: '왼쪽으로 90° 회전',
                      onPressed: _pictureRotationLocked
                          ? null
                          : () => _rotatePicture(shape, -9000),
                      icon: const Icon(Icons.rotate_left),
                    ),
                    IconButton(
                      key: const ValueKey('office-image-rotate-right'),
                      tooltip: '오른쪽으로 90° 회전',
                      onPressed: _pictureRotationLocked
                          ? null
                          : () => _rotatePicture(shape, 9000),
                      icon: const Icon(Icons.rotate_right),
                    ),
                    Text(
                      '회전 ${shape.rotationLabel}°',
                      key: const ValueKey('office-image-rotation-angle'),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
              ],
              if (shape.editableText) ...[
                TextField(
                  key: const ValueKey('office-shape-text'),
                  controller: shape.text.text,
                  focusNode: shape.textFocus,
                  readOnly: !shape.text.canReplace || _pptMutationLocked,
                  minLines: 2,
                  maxLines: 6,
                  decoration: const InputDecoration(
                    labelText: '내용',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (_) => _changed(),
                ),
                const SizedBox(height: 16),
                if (widget.allowFormatting && shape.canEditTextStyle)
                  _style(shape.text, shape.id, shape: true),
                const SizedBox(height: 20),
              ],
              if (widget.allowFormatting) ...[
                const Text('위치와 크기(mm)'),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 12,
                  children: [
                    for (final item in const {
                      'x': '가로 위치',
                      'y': '세로 위치',
                      'width': '너비',
                      'height': '높이',
                    }.entries)
                      SizedBox(
                        width: 105,
                        child: TextField(
                          key: ValueKey('office-shape-${item.key}'),
                          controller: shape.geometry[item.key],
                          readOnly:
                              _pptMutationLocked ||
                              !shape.canEditGeometry ||
                              (_pptDraft?.composing ?? false),
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                            signed: true,
                          ),
                          decoration: InputDecoration(
                            labelText: item.value,
                            border: const OutlineInputBorder(),
                            isDense: true,
                          ),
                          onChanged: (_) => _changed(),
                        ),
                      ),
                  ],
                ),
                if (shape.canEditFill) ...[
                  const SizedBox(height: 20),
                  const Text('채우기'),
                  const SizedBox(height: 8),
                  _fillControls(
                    prefix: 'office-shape-fill',
                    label: '채우기',
                    style: shape.fillStyle,
                    color: shape.fillColor,
                    onStyle: (value) {
                      shape.fillStyle = value;
                      if (value == 'solid') shape.fillColor ??= 0xffffff;
                    },
                    onColor: (value) {
                      shape.fillStyle = 'solid';
                      shape.fillColor = value;
                    },
                  ),
                ],
                if (shape.canEditLine) ...[
                  const SizedBox(height: 20),
                  const Text('윤곽선'),
                  const SizedBox(height: 8),
                  _fillControls(
                    prefix: 'office-shape-line',
                    label: '윤곽선',
                    style: shape.lineStyle,
                    color: shape.lineColor,
                    onStyle: (value) {
                      shape.lineStyle = value;
                      if (value == 'solid') shape.lineColor ??= 0;
                    },
                    onColor: (value) {
                      shape.lineStyle = 'solid';
                      shape.lineColor = value;
                    },
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: 150,
                    child: TextField(
                      key: const ValueKey('office-shape-line-width'),
                      controller: shape.lineWidth,
                      readOnly: _pptMutationLocked,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(
                        labelText: '선 굵기(mm)',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      onChanged: (_) => _changed(),
                    ),
                  ),
                ],
              ],
            ],
            if (widget.allowFormatting) ...[
              const Divider(height: 36),
              Text(
                _pptDraft?.editingMasterId == null ? '슬라이드 배경' : '공통 디자인 배경',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              _fillControls(
                prefix: 'office-slide-background',
                label: '배경',
                style: _slide.backgroundStyle,
                color: _slide.backgroundColor,
                onStyle: (value) {
                  _slide.backgroundStyle = value;
                  if (value == 'solid') _slide.backgroundColor ??= 0xffffff;
                },
                onColor: (value) {
                  _slide.backgroundStyle = 'solid';
                  _slide.backgroundColor = value;
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _presentation() {
    if (_slides.isEmpty) return const Center(child: Text('이 문서에 슬라이드가 없습니다.'));
    return Column(
      children: [
        if (_pptDraft != null) _presentationDesignTools(),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (widget.allowFormatting) ...[
                if (widget.onCommitWithAssets != null)
                  IconButton(
                    key: const ValueKey('office-insert-image'),
                    tooltip: '사진 추가',
                    onPressed: _pptMutationLocked
                        ? null
                        : () => unawaited(_pickImage()),
                    icon: const Icon(Icons.add_photo_alternate_outlined),
                  ),
                PopupMenuButton<String>(
                  key: const ValueKey('office-insert-shape'),
                  tooltip: '개체 추가',
                  enabled: !_pptMutationLocked,
                  onSelected: _addShape,
                  itemBuilder: (_) => [
                    for (final entry in <String, String>{
                      'text': '텍스트 상자',
                      'rectangle': '사각형',
                      if (_pptDraft?.editingMasterId == null)
                        'roundedRectangle': '둥근 사각형',
                      'ellipse': '타원',
                      if (_pptDraft?.editingMasterId == null)
                        'rightArrow': '오른쪽 화살표',
                      'line': '선',
                    }.entries)
                      PopupMenuItem(
                        key: ValueKey('office-insert-${entry.key}'),
                        value: entry.key,
                        child: Text(entry.value),
                      ),
                  ],
                  icon: const Icon(Icons.add_box_outlined),
                ),
                if (_pptDraft?.editingMasterId == null) ...[
                  IconButton(
                    tooltip: '슬라이드 추가',
                    onPressed: _pptMutationLocked ? null : _addSlide,
                    icon: const Icon(Icons.add),
                  ),
                  if (_canDuplicateSlide)
                    IconButton(
                      tooltip: '슬라이드 복제',
                      onPressed: _pptMutationLocked
                          ? null
                          : _stageSlideDuplicate,
                      icon: const Icon(Icons.content_copy),
                    ),
                  IconButton(
                    tooltip: '슬라이드 삭제',
                    onPressed: !_pptMutationLocked && _slides.length > 1
                        ? _deleteSlide
                        : null,
                    icon: const Icon(Icons.delete_outline),
                  ),
                  IconButton(
                    tooltip: '슬라이드 위로',
                    onPressed: !_pptMutationLocked && _selectedSlide > 0
                        ? () => _moveSlide(-1)
                        : null,
                    icon: const Icon(Icons.arrow_upward),
                  ),
                  IconButton(
                    tooltip: '슬라이드 아래로',
                    onPressed:
                        !_pptMutationLocked &&
                            _selectedSlide < _slides.length - 1
                        ? () => _moveSlide(1)
                        : null,
                    icon: const Icon(Icons.arrow_downward),
                  ),
                ],
              ],
              if ((widget.previewPath ?? widget.snapshot.previewPdfPath) !=
                      null &&
                  _slide.previewPage != null &&
                  _pptDraft?.editingMasterId == null)
                TextButton.icon(
                  onPressed: _pptContextLocked
                      ? null
                      : () => setState(
                          () => _showOriginalSlide = !_showOriginalSlide,
                        ),
                  icon: Icon(
                    _showOriginalSlide ? Icons.edit_outlined : Icons.preview,
                    size: 18,
                  ),
                  label: Text(_showOriginalSlide ? '개체 편집 보기' : '저장된 원본 보기'),
                ),
              const Text('편집 보기에서는 일부 원본 효과가 생략됩니다. 저장 후 확인하세요.'),
            ],
          ),
        ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) => constraints.maxWidth < 820
                ? Column(
                    children: [
                      SizedBox(height: 78, child: _slideList(true)),
                      Expanded(child: _slideCanvas()),
                      SizedBox(
                        height: math.min(280, constraints.maxHeight * .5),
                        child: _inspector(),
                      ),
                    ],
                  )
                : Row(
                    children: [
                      SizedBox(width: 150, child: _slideList(false)),
                      Expanded(child: _slideCanvas()),
                      SizedBox(width: 270, child: _inspector()),
                    ],
                  ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _trySave();
    },
    child: Scaffold(
      backgroundColor: const Color(0xfff8f9f3),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 16, 8),
              child: Row(
                children: [
                  IconButton(
                    tooltip: '문서로 돌아가기',
                    onPressed: _pptEditingLocked ? null : _trySave,
                    icon: const Icon(Icons.arrow_back),
                  ),
                  Expanded(
                    child: Text(
                      widget.snapshot.kind == 'word' ? '문서 편집' : '발표 편집',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  if (widget.snapshot.kind == 'word' &&
                      (_wordDraft?.previewPath ??
                              widget.previewPath ??
                              widget.snapshot.previewPdfPath) !=
                          null)
                    IconButton(
                      tooltip: _wordDraft?.previewPath != null
                          ? '편집 미리보기'
                          : '원본 미리보기',
                      onPressed: _pptEditingLocked
                          ? null
                          : () => setState(() => _showPreview = !_showPreview),
                      icon: Icon(
                        _showPreview ? Icons.edit_note : Icons.preview_outlined,
                      ),
                    ),
                  FilledButton.icon(
                    onPressed: _pptEditingLocked ? null : _trySave,
                    icon: const Icon(Icons.save_outlined),
                    label: const Text('저장하고 닫기'),
                  ),
                ],
              ),
            ),
            if (_busy ||
                _pickingImage ||
                _pptDraft?.previewing == true ||
                _wordDraft?.previewing == true)
              const LinearProgressIndicator(),
            if (_error != null)
              Material(
                color: Theme.of(context).colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Expanded(child: Text(_error!)),
                      TextButton(
                        onPressed: _busy ? null : _trySave,
                        child: const Text('저장 재시도'),
                      ),
                    ],
                  ),
                ),
              ),
            if (_slideDuplicationId != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text('저장하면 선택한 슬라이드 바로 뒤에 복제본이 추가됩니다.'),
                    ),
                    IconButton(
                      tooltip: '슬라이드 복제 취소',
                      onPressed: _busy
                          ? null
                          : () {
                              _slideDuplicationId = null;
                              _changed();
                            },
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
            const Divider(height: 1),
            if (widget.previewNotice != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Text(widget.previewNotice!),
              ),
            Expanded(
              child: AbsorbPointer(
                absorbing:
                    _busy ||
                    _pickingImage ||
                    _slideDuplicationId != null ||
                    _pptDraft?.previewing == true,
                child: _showPreview
                    ? PdfViewer.file(
                        _wordDraft?.previewPath ??
                            widget.previewPath ??
                            widget.snapshot.previewPdfPath!,
                      )
                    : widget.snapshot.kind == 'word'
                    ? _word()
                    : Focus(
                        canRequestFocus: _slideDuplicationId == null,
                        descendantsAreFocusable: _slideDuplicationId == null,
                        onKeyEvent: (_, event) =>
                            _pptDraft?.keyEvent(event) ??
                            KeyEventResult.ignored,
                        child: _presentation(),
                      ),
              ),
            ),
          ],
        ),
      ),
    ),
  );

  @override
  void dispose() {
    _generation++;
    _disposeDrafts();
    super.dispose();
  }

  void _disposeDrafts() {
    _pptDraft?.dispose();
    _pptDraft = null;
    _wordDraft?.dispose();
    _wordDraft = null;
    for (final draft in _paragraphs.values) {
      draft.dispose();
    }
    for (final table in _cells.values) {
      for (final controller in table.values) {
        controller.dispose();
      }
    }
    for (final slide in _slides) {
      slide.dispose();
    }
  }
}

class _ShapePainter extends CustomPainter {
  new(this.shape, this.scale, this.inset, this.objectSize);
  final _ShapeDraft shape;
  final double scale;
  final Offset inset;
  final Size objectSize;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = inset & objectSize;
    final shortSide = math.min(rect.width, rect.height);
    late final rounded = RRect.fromRectAndRadius(
      rect,
      Radius.circular(shortSide / 6),
    );
    final shaftEnd = rect.right - shortSide / 2;
    final shaftTop = rect.top + rect.height / 4;
    final shaftBottom = rect.bottom - rect.height / 4;
    late final arrow = Path()
      ..moveTo(rect.left, shaftTop)
      ..lineTo(shaftEnd, shaftTop)
      ..lineTo(shaftEnd, rect.top)
      ..lineTo(rect.right, rect.center.dy)
      ..lineTo(shaftEnd, rect.bottom)
      ..lineTo(shaftEnd, shaftBottom)
      ..lineTo(rect.left, shaftBottom)
      ..close();

    void drawShape(Paint paint) {
      switch (shape.shapeKind) {
        case 'line':
          canvas.drawLine(rect.topLeft, rect.bottomRight, paint);
        case 'ellipse':
          canvas.drawOval(rect, paint);
        case 'roundedRectangle':
          canvas.drawRRect(rounded, paint);
        case 'rightArrow':
          canvas.drawPath(arrow, paint);
        default:
          canvas.drawRect(rect, paint);
      }
    }

    if (shape.shapeKind != 'line' &&
        shape.fillStyle == 'solid' &&
        shape.fillColor != null) {
      drawShape(Paint()..color = Color(0xff000000 | shape.fillColor!));
    }
    if (shape.lineStyle == 'solid') {
      final parsedWidth = double.tryParse(shape.lineWidth.text);
      final width = parsedWidth != null && parsedWidth.isFinite
          ? parsedWidth.clamp(0, 100).toDouble()
          : shape.originalLineWidth ?? .5;
      final paint = Paint()
        ..color = Color(0xff000000 | (shape.lineColor ?? 0))
        ..style = PaintingStyle.stroke
        ..strokeWidth = width * scale;
      drawShape(paint);
    }
    if (!shape.editableText || objectSize.isEmpty) return;
    final parsed = double.tryParse(shape.text.font.text);
    final font = parsed != null && parsed.isFinite ? parsed.clamp(1, 400) : 12;
    final text = TextPainter(
      text: shape.text.isRich
          ? shape.text.buildSpan(
              const TextStyle(color: Colors.black),
              scale: 25.4 / 72 * scale,
            )
          : TextSpan(
              text: shape.text.text.text,
              style: TextStyle(
                fontSize: font * 25.4 / 72 * scale,
                fontWeight: shape.text.bold
                    ? FontWeight.bold
                    : FontWeight.normal,
                color: Color(0xff000000 | shape.text.color),
              ),
            ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: math.max(1, objectSize.width));
    canvas.save();
    canvas.clipRect(rect);
    text.paint(canvas, inset);
    canvas.restore();
    text.dispose();
  }

  @override
  bool shouldRepaint(covariant _ShapePainter oldDelegate) => true;
}

class _OfficeTextController extends TextEditingController {
  new({required String text}) : super(text: text);
  TextSpan Function(TextStyle?)? spanBuilder;
  void refreshStyles() => notifyListeners();
  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    if (spanBuilder == null ||
        withComposing &&
            value.composing.isValid &&
            !value.composing.isCollapsed) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }
    return spanBuilder!(style);
  }
}

class _DraftRun {
  new(this.start, this.end, this.style, {required this.origin});
  int start;
  int end;
  final Map<String, Object?> style;
  final int origin;
  _DraftRun section(
    int first,
    int last, {
    Map<String, Object?>? style,
    int? origin,
  }) => _DraftRun(
    first,
    last,
    Map.of(style ?? this.style),
    origin: origin ?? this.origin,
  );
}

class _ProtectedDraft {
  new(this.start, this.end, [this.type = 'Protected']);
  int start;
  int end;
  final String type;
}

class _TextDraft {
  new(
    this.originalText, {
    double? fontSize,
    bool? bold,
    int? color,
    this.details,
    this.targetKind = '',
    this.id = '',
    this.cell,
    this.requireGraphemeBoundaries = false,
    this.onChanged,
    this.canMergePrevious,
    this.interceptInput,
  }) : originalFont = fontSize ?? 12,
       originalBold = bold ?? false,
       originalColor = color ?? 0,
       text = _OfficeTextController(text: originalText),
       font = TextEditingController(text: '${fontSize ?? 12}'),
       fontFamily = TextEditingController(),
       bold = bold ?? false,
       color = color ?? 0,
       _currentText = originalText,
       _baseStyle = {'fontSize': fontSize, 'bold': bold, 'color': color} {
    _acceptedValue = text.value;
    if (details != null) {
      _validSnapshot =
          !details!.truncated &&
          details!.utf16Length == originalText.length &&
          details!.textSha256 == _digest(originalText) &&
          _validUtf16(originalText);
      for (final run in details!.runs) {
        if (run.startUtf16 < 0 ||
            run.endUtf16 < run.startUtf16 ||
            run.endUtf16 > originalText.length ||
            !_boundary(originalText, run.startUtf16) ||
            !_boundary(originalText, run.endUtf16)) {
          _validSnapshot = false;
          continue;
        }
        _runs.add(
          _DraftRun(run.startUtf16, run.endUtf16, {
            'fontSize': run.fontSize,
            'bold': run.bold,
            'italic': run.italic,
            'underline': run.underline,
            'color': run.color,
            'fontFamily': run.fontFamily,
          }, origin: _nextOrigin++),
        );
      }
      for (final range in details!.protectedRanges) {
        if (range.startUtf16 < 0 ||
            range.endUtf16 < range.startUtf16 ||
            range.endUtf16 > originalText.length) {
          _validSnapshot = false;
          continue;
        }
        _protected.add(
          _ProtectedDraft(range.startUtf16, range.endUtf16, range.type),
        );
      }
      if (_runs.isEmpty)
        _runs.add(
          _DraftRun(
            0,
            originalText.length,
            Map.of(_baseStyle),
            origin: _nextOrigin++,
          ),
        );
      text.spanBuilder = (style) => buildSpan(style);
      _syncStyleInputs();
    }
    text.addListener(_textChanged);
  }
  final String originalText;
  final double originalFont;
  final bool originalBold;
  final int originalColor;
  final _OfficeTextController text;
  final TextEditingController font;
  final TextEditingController fontFamily;
  final WindowsOfficeTextDetails? details;
  final String targetKind;
  final String id;
  final String? cell;
  final bool requireGraphemeBoundaries;
  final VoidCallback? onChanged;
  bool Function()? canMergePrevious;
  final bool Function(TextEditingValue)? interceptInput;
  final Map<String, Object?> _baseStyle;
  final _runs = <_DraftRun>[];
  final _protected = <_ProtectedDraft>[];
  final operations = <WindowsOfficeOperation>[];
  late TextEditingValue _acceptedValue;
  var _selection = const TextSelection.collapsed(offset: 0);
  String _currentText;
  var _validSnapshot = true;
  var _updating = false;
  var _nextOrigin = 0;
  int? _lastReplacementOrigin;
  bool bold;
  int color;
  String? lastEditError;
  bool get isRich => details != null;
  bool get canReplace => !isRich || _validSnapshot && details!.canReplace;
  bool get _composing =>
      text.value.composing.isValid && !text.value.composing.isCollapsed;

  static String _digest(String value) =>
      sha256.convert(utf8.encode(value)).toString();
  static bool _boundary(String value, int offset) =>
      offset >= 0 &&
      offset <= value.length &&
      !(offset > 0 &&
          offset < value.length &&
          value.codeUnitAt(offset - 1) >= 0xd800 &&
          value.codeUnitAt(offset - 1) <= 0xdbff &&
          value.codeUnitAt(offset) >= 0xdc00 &&
          value.codeUnitAt(offset) <= 0xdfff);

  bool _editBoundary(String value, int offset) {
    if (!_boundary(value, offset)) return false;
    if (!requireGraphemeBoundaries || offset == 0 || offset == value.length) {
      return true;
    }
    var cursor = 0;
    for (final grapheme in value.characters) {
      cursor += grapheme.length;
      if (cursor >= offset) return cursor == offset;
    }
    return false;
  }

  static bool _validUtf16(String value) {
    for (var i = 0; i < value.length; i++) {
      final code = value.codeUnitAt(i);
      if (code >= 0xd800 && code <= 0xdbff) {
        if (++i >= value.length ||
            value.codeUnitAt(i) < 0xdc00 ||
            value.codeUnitAt(i) > 0xdfff)
          return false;
      } else if (code >= 0xdc00 && code <= 0xdfff) {
        return false;
      }
    }
    return true;
  }

  bool _protectedOverlap(int start, int end, {bool styling = false}) =>
      _protected.any(
        (range) => range.start == range.end
            ? !styling && start <= range.start && end >= range.end
            : start == end
            ? start >= range.start && start < range.end
            : start < range.end && end > range.start,
      );

  void _textChanged() {
    if (_updating) return;
    final value = text.value;
    if (interceptInput?.call(value) == true) return;
    lastEditError = null;
    if (value.text != _currentText) {
      var start = 0;
      while (start < _currentText.length &&
          start < value.text.length &&
          _currentText.codeUnitAt(start) == value.text.codeUnitAt(start)) {
        start++;
      }
      while (!_editBoundary(_currentText, start) ||
          !_editBoundary(value.text, start)) {
        start--;
      }
      var end = _currentText.length;
      var newEnd = value.text.length;
      while (end > start &&
          newEnd > start &&
          _currentText.codeUnitAt(end - 1) ==
              value.text.codeUnitAt(newEnd - 1)) {
        end--;
        newEnd--;
      }
      while (!_editBoundary(_currentText, end) ||
          !_editBoundary(value.text, newEnd)) {
        end++;
        newEnd++;
      }
      final replacement = value.text.substring(start, newEnd);
      final structuralNewline =
          isRich &&
          targetKind == 'paragraph' &&
          (replacement.contains('\n') || replacement.contains('\r'));
      if (isRich &&
          (!canReplace ||
              !_validUtf16(value.text) ||
              structuralNewline ||
              _protectedOverlap(start, end))) {
        lastEditError = structuralNewline
            ? '현재 편집에서는 새 문단을 추가할 수 없습니다. 기존 문단의 내용은 계속 바꿀 수 있습니다.'
            : '필드나 포함된 개체를 가로지르는 변경은 적용하지 않았습니다. 원본을 확인하세요.';
        _updating = true;
        text.value = _acceptedValue;
        _updating = false;
        onChanged?.call();
        return;
      }
      if (!_composing) {
        if (isRich) {
          _appendReplacement(start, end, replacement);
          _replaceRuns(start, end, replacement.length);
        }
        _currentText = value.text;
      }
    }
    _acceptedValue = value;
    if (value.selection.isValid && value.selection.end <= value.text.length)
      _selection = value.selection;
    if (isRich && !_composing) _syncStyleInputs();
    if (isRich) onChanged?.call();
  }

  int? _uniformOrigin(int start, int end) {
    if (start == end) {
      final left = _runs
          .where((run) => run.start < start && run.end >= start)
          .lastOrNull;
      final right = _runs
          .where((run) => run.start <= start && run.end > start)
          .firstOrNull;
      return left?.origin ??
          right?.origin ??
          (_currentText.isEmpty ? _runs.firstOrNull?.origin : null);
    }
    int? origin;
    var covered = start;
    for (final run in _runs.where(
      (run) => run.start < end && run.end > start,
    )) {
      if (run.start > covered || origin != null && origin != run.origin)
        return null;
      origin = run.origin;
      covered = math.min(end, run.end);
    }
    return covered == end ? origin : null;
  }

  void _appendReplacement(int start, int end, String replacement) {
    final origin = _uniformOrigin(start, end);
    final previous = operations.lastOrNull?.toJson();
    if (previous != null &&
        previous['op'] == 'textReplace' &&
        (canMergePrevious?.call() ?? true)) {
      final oldStart = previous['startUtf16'] as int;
      final oldEnd = previous['endUtf16'] as int;
      final inserted = previous['text'] as String;
      final insertedEnd = oldStart + inserted.length;
      final sameOrigin = origin != null && origin == _lastReplacementOrigin;
      final deletions = inserted.isEmpty && replacement.isEmpty;
      if (start <= insertedEnd &&
          end >= oldStart &&
          (sameOrigin || deletions)) {
        final prefix = start > oldStart
            ? inserted.substring(0, start - oldStart)
            : '';
        final suffix = end < insertedEnd
            ? inserted.substring(end - oldStart)
            : '';
        operations[operations.length - 1] = WindowsOfficeOperation.textReplace(
          targetKind: targetKind,
          id: id,
          cell: cell,
          startUtf16: math.min(oldStart, start),
          endUtf16: oldEnd + math.max(0, end - insertedEnd),
          expectedTextSha256: previous['expectedTextSha256'] as String,
          text: prefix + replacement + suffix,
        );
        if (!sameOrigin) _lastReplacementOrigin = null;
        return;
      }
    }
    operations.add(
      WindowsOfficeOperation.textReplace(
        targetKind: targetKind,
        id: id,
        cell: cell,
        startUtf16: start,
        endUtf16: end,
        expectedTextSha256: _digest(_currentText),
        text: replacement,
      ),
    );
    _lastReplacementOrigin = origin;
  }

  void _replaceRuns(int start, int end, int length) {
    final delta = length - (end - start);
    final inheritedRun = _runs
        .where((run) => run.start <= start && run.end >= start)
        .firstOrNull;
    final inherited = inheritedRun?.style ?? _baseStyle;
    final inheritedOrigin = inheritedRun?.origin ?? _nextOrigin++;
    final next = <_DraftRun>[];
    for (final run in _runs) {
      if (run.start < start)
        next.add(run.section(run.start, math.min(start, run.end)));
      if (run.end > end)
        next.add(
          run.section(math.max(end, run.start) + delta, run.end + delta),
        );
    }
    if (length > 0)
      next.add(
        _DraftRun(
          start,
          start + length,
          Map.of(inherited),
          origin: inheritedOrigin,
        ),
      );
    _runs
      ..clear()
      ..addAll(next.where((run) => run.end > run.start));
    _runs.sort((a, b) => a.start.compareTo(b.start));
    if (_runs.isEmpty)
      _runs.add(_DraftRun(0, 0, Map.of(inherited), origin: inheritedOrigin));
    var index = 1;
    while (index < _runs.length) {
      final previous = _runs[index - 1], current = _runs[index];
      if (previous.end == current.start && previous.origin == current.origin) {
        previous.end = current.end;
        _runs.removeAt(index);
      } else {
        index++;
      }
    }
    for (final range in _protected) {
      if (range.start >= end) {
        range.start += delta;
        range.end += delta;
      }
    }
  }

  bool get canStyleSelection =>
      isRich &&
      _validSnapshot &&
      details!.canStyle &&
      !_composing &&
      _selection.isValid &&
      !_selection.isCollapsed &&
      _selection.end <= _currentText.length &&
      _editBoundary(_currentText, _selection.start) &&
      _editBoundary(_currentText, _selection.end) &&
      !_protectedOverlap(_selection.start, _selection.end, styling: true);

  Object? selectedStyle(String name) {
    final start = _selection.isCollapsed ? 0 : _selection.start;
    final end = _selection.isCollapsed ? _currentText.length : _selection.end;
    final values = _runs
        .where((run) => run.start < end && run.end > start)
        .map((run) => run.style[name])
        .toSet();
    return values.length == 1 ? values.single : null;
  }

  void _syncStyleInputs() {
    final size = selectedStyle('fontSize') as num?;
    final display = size == null
        ? ''
        : size.toDouble() == size.toInt()
        ? '${size.toInt()}'
        : '$size';
    if (font.text != display) font.text = display;
    final family = selectedStyle('fontFamily') as String? ?? '';
    if (fontFamily.text != family) fontFamily.text = family;
  }

  void applySelectedStyle(Map<String, Object?> style) {
    if (!canStyleSelection) throw const FormatException('바꿀 글자를 먼저 선택하세요.');
    final start = _selection.start;
    final end = _selection.end;
    operations.add(
      WindowsOfficeOperation.textStyle(
        targetKind: targetKind,
        id: id,
        cell: cell,
        startUtf16: start,
        endUtf16: end,
        expectedTextSha256: _digest(_currentText),
        fontSize: (style['fontSize'] as num?)?.toDouble(),
        bold: style['bold'] as bool?,
        italic: style['italic'] as bool?,
        underline: style['underline'] as bool?,
        color: style['color'] as int?,
        fontFamily: style['fontFamily'] as String?,
      ),
    );
    final next = <_DraftRun>[];
    for (final run in _runs) {
      if (run.end <= start || run.start >= end) {
        next.add(run);
        continue;
      }
      if (run.start < start) next.add(run.section(run.start, start));
      next.add(
        run.section(
          math.max(run.start, start),
          math.min(run.end, end),
          style: {...run.style, ...style},
          origin: _nextOrigin++,
        ),
      );
      if (run.end > end) next.add(run.section(end, run.end));
    }
    _runs
      ..clear()
      ..addAll(next);
    _syncStyleInputs();
    text.refreshStyles();
  }

  TextSpan buildSpan(TextStyle? base, {double scale = 96 / 72}) {
    final value = text.text;
    if (!isRich || _composing || !_validSnapshot)
      return TextSpan(text: value, style: base);
    final children = <TextSpan>[];
    var offset = 0;
    for (final run in _runs) {
      final start = run.start.clamp(offset, value.length);
      final end = run.end.clamp(start, value.length);
      if (start > offset)
        children.add(TextSpan(text: value.substring(offset, start)));
      if (end > start) {
        children.add(
          TextSpan(
            text: value.substring(start, end),
            style: TextStyle(
              fontSize: run.style['fontSize'] == null
                  ? null
                  : (run.style['fontSize'] as num).toDouble() * scale,
              fontFamily: run.style['fontFamily'] as String?,
              fontWeight: switch (run.style['bold']) {
                true => FontWeight.bold,
                false => FontWeight.normal,
                _ => null,
              },
              fontStyle: switch (run.style['italic']) {
                true => FontStyle.italic,
                false => FontStyle.normal,
                _ => null,
              },
              decoration: switch (run.style['underline']) {
                true => TextDecoration.underline,
                false => TextDecoration.none,
                _ => null,
              },
              color: run.style['color'] == null
                  ? null
                  : Color(0xff000000 | (run.style['color'] as int)),
            ),
          ),
        );
      }
      offset = end;
    }
    if (offset < value.length)
      children.add(TextSpan(text: value.substring(offset)));
    return TextSpan(style: base, children: children);
  }

  double? get changedFont {
    final parsed = double.tryParse(font.text);
    return parsed != null && parsed.isFinite && parsed != originalFont
        ? parsed
        : null;
  }

  bool? get changedBold => bold != originalBold ? bold : null;
  int? get changedColor => color != originalColor ? color : null;
  bool get styleChanged => isRich
      ? operations.any((operation) => operation.toJson()['op'] == 'textStyle')
      : changedFont != null || changedBold != null || changedColor != null;
  void validate({bool typography = true}) {
    if (_composing) throw const FormatException('입력 중인 글자를 확정한 뒤 저장하세요.');
    if (!typography) return;
    if (isRich && font.text.isEmpty) return;
    final value = double.tryParse(font.text);
    if (value == null || !value.isFinite || value < 1 || value > 400)
      throw const FormatException('글자 크기는 1~400pt로 입력하세요.');
  }

  void dispose() {
    text.removeListener(_textChanged);
    text.dispose();
    font.dispose();
    fontFamily.dispose();
  }
}

class _ShapeDraft {
  new(
    this.id,
    this.editableText,
    this.text,
    Map<String, double> values, {
    this.shapeKind,
    this.isNew = false,
    this.canEditFill = false,
    this.canEditLine = false,
    this.canEditGeometry = true,
    this.canDelete = true,
    this.canEditTextStyle = true,
    this.presentationObject,
    this.emptyPresentationObject,
    this.image,
    this.assetId,
    this.imageBytes,
    String? fillStyle,
    int? fillColor,
    String? lineStyle,
    int? lineColor,
    double? lineWidth,
  }) : originalGeometry = values,
       rotationHundredths = image?.rotationHundredths,
       originalFillStyle = fillStyle,
       originalFillColor = fillColor,
       originalLineStyle = lineStyle,
       originalLineColor = lineColor,
       originalLineWidth = lineWidth,
       fillStyle = fillStyle,
       fillColor = fillColor,
       lineStyle = lineStyle,
       lineColor = lineColor,
       lineWidth = TextEditingController(text: '${lineWidth ?? .5}'),
       geometry = {
         for (final item in values.entries)
           item.key: TextEditingController(text: '${item.value}'),
       };
  factory added(String id, String kind, double slideWidth, double slideHeight) {
    final filled = const {
      'rectangle',
      'roundedRectangle',
      'ellipse',
      'rightArrow',
    }.contains(kind);
    return _ShapeDraft(
      id,
      kind != 'line',
      _TextDraft('', fontSize: 18),
      {
        'x': math.min(20, slideWidth / 4),
        'y': math.min(20, slideHeight / 4),
        'width': math.max(1, math.min(100, slideWidth / 2)),
        'height': kind == 'line'
            ? 0
            : math.max(1, math.min(45, slideHeight / 3)),
      },
      shapeKind: kind,
      isNew: true,
      canEditFill: kind != 'line',
      canEditLine: true,
      fillStyle: filled ? 'solid' : 'none',
      fillColor: filled ? 0x16828a : null,
      lineStyle: kind == 'text' ? 'none' : 'solid',
      lineColor: 0,
      lineWidth: .5,
    );
  }
  factory image(
    String id,
    String assetId,
    WindowsOfficeImageAsset asset,
    double slideWidth,
    double slideHeight,
  ) {
    var width = math.min(100.0, slideWidth * .5);
    var height = width * asset.height / asset.width;
    if (height > slideHeight * .65) {
      height = slideHeight * .65;
      width = height * asset.width / asset.height;
    }
    return _ShapeDraft(
      id,
      false,
      _TextDraft(''),
      {
        'x': math.min(20, slideWidth / 4),
        'y': math.min(20, slideHeight / 4),
        'width': width,
        'height': height,
      },
      shapeKind: 'image',
      isNew: true,
      assetId: assetId,
      imageBytes: asset.bytes,
    );
  }
  final String id;
  final bool editableText;
  final _TextDraft text;
  final textFocus = FocusNode();
  final String? shapeKind;
  final bool isNew;
  final bool canEditFill;
  final bool canEditLine;
  final bool canEditGeometry;
  final bool canDelete;
  final bool canEditTextStyle;
  final bool? presentationObject;
  final bool? emptyPresentationObject;
  final WindowsOfficeImageDetails? image;
  int? rotationHundredths;
  bool get rotationChanged =>
      image?.rotationHundredths != null &&
      rotationHundredths != null &&
      rotationHundredths != image!.rotationHundredths;
  String get rotationLabel {
    final angle = rotationHundredths!;
    return angle % 100 == 0
        ? '${angle ~/ 100}'
        : (angle / 100).toStringAsFixed(2);
  }

  String? assetId;
  Uint8List? imageBytes;
  final Map<String, double> originalGeometry;
  final Map<String, TextEditingController> geometry;
  final String? originalFillStyle;
  final int? originalFillColor;
  final String? originalLineStyle;
  final int? originalLineColor;
  final double? originalLineWidth;
  final TextEditingController lineWidth;
  String? fillStyle;
  int? fillColor;
  String? lineStyle;
  int? lineColor;
  String? get changedFillStyle =>
      canEditFill && fillStyle != originalFillStyle ? fillStyle : null;
  int? get changedFillColor =>
      canEditFill && fillColor != originalFillColor ? fillColor : null;
  String? get changedLineStyle =>
      canEditLine && lineStyle != originalLineStyle ? lineStyle : null;
  int? get changedLineColor =>
      canEditLine && lineColor != originalLineColor ? lineColor : null;
  double? get changedLineWidth {
    if (!canEditLine || lineWidth.text == '${originalLineWidth ?? .5}') {
      return null;
    }
    final parsed = double.tryParse(lineWidth.text);
    return parsed != null && parsed.isFinite && parsed != originalLineWidth
        ? parsed
        : null;
  }

  bool get appearanceChanged =>
      changedFillStyle != null ||
      changedFillColor != null ||
      changedLineStyle != null ||
      changedLineColor != null ||
      changedLineWidth != null;

  double value(String key) {
    final parsed = double.tryParse(geometry[key]!.text);
    return parsed != null && parsed.isFinite ? parsed : originalGeometry[key]!;
  }

  void setValue(String key, double value) {
    geometry[key]!.text = value.toStringAsFixed(2);
  }

  bool get geometryChanged =>
      originalGeometry.entries.any((item) => value(item.key) != item.value);
  void validate() {
    text.validate();
    validateGeometry();
    if (canEditLine) {
      final width = double.tryParse(lineWidth.text);
      if (width == null || !width.isFinite || width < 0 || width > 100) {
        throw const FormatException('선 굵기는 0~100mm로 입력하세요.');
      }
    }
  }

  void validateGeometry() {
    final line = shapeKind == 'line';
    for (final item in geometry.entries) {
      final value = double.tryParse(item.value.text);
      if (value == null ||
          !value.isFinite ||
          value.abs() > 100000 ||
          ((item.key == 'width' || item.key == 'height') &&
              value < (line ? 0 : .01)))
        throw const FormatException('위치와 크기를 올바른 mm 값으로 입력하세요.');
    }
    if (line && value('width') == 0 && value('height') == 0) {
      throw const FormatException('선의 너비와 높이 중 하나는 0보다 커야 합니다.');
    }
  }

  void dispose() {
    text.dispose();
    textFocus.dispose();
    lineWidth.dispose();
    for (final controller in geometry.values) {
      controller.dispose();
    }
  }
}

class _SlideDraft {
  new(
    this.id,
    this.width,
    this.height,
    this.previewPage,
    this.shapes, {
    this.implicitShapeId,
    this.name,
    this.masterId,
    this.layoutCode,
    this.designSha256,
    this.visible,
    this.showMasterObjects,
    this.presentationTables,
    this.presentationTableCount,
    this.presentationTablesTruncated = false,
    this.presentationTablesUnknownReason,
    this.canAddTable = false,
    this.selectedTableId,
    this.selectedCellId,
    String? backgroundStyle,
    int? backgroundColor,
  }) : sourceShapeIds = shapes.map((shape) => shape.id).toSet(),
       originalBackgroundStyle = backgroundStyle,
       originalBackgroundColor = backgroundColor,
       backgroundStyle = backgroundStyle,
       backgroundColor = backgroundColor;
  factory fromSnapshot(
    WindowsOfficeSlide slide,
    int page,
    VoidCallback onChanged,
  ) => _SlideDraft(
    slide.id,
    slide.width,
    slide.height,
    page,
    [for (final shape in slide.shapes) _presentationShape(shape, onChanged)],
    backgroundStyle: slide.backgroundStyle,
    backgroundColor: slide.backgroundColor,
    masterId: slide.masterId,
    layoutCode: slide.layoutCode,
    designSha256: slide.designSha256,
    visible: slide.visible,
    showMasterObjects: slide.showMasterObjects,
    presentationTables: slide.presentationTables == null
        ? null
        : [
            for (final table in slide.presentationTables!)
              _PptTableDraft(table, onChanged),
          ],
    presentationTableCount: slide.presentationTableCount,
    presentationTablesTruncated: slide.presentationTablesTruncated,
    presentationTablesUnknownReason: slide.presentationTablesUnknownReason,
    canAddTable: slide.canAddTable,
  );
  factory fromMaster(WindowsOfficeMaster master, VoidCallback onChanged) =>
      _SlideDraft(
        master.id,
        master.width,
        master.height,
        null,
        [
          for (final shape in master.shapes)
            _presentationShape(shape, onChanged, master: true),
        ],
        name: master.name,
        backgroundStyle: master.backgroundStyle,
        backgroundColor: master.backgroundColor,
        presentationTables: master.presentationTables == null
            ? null
            : [
                for (final table in master.presentationTables!)
                  _PptTableDraft(table, onChanged),
              ],
        presentationTableCount: master.presentationTableCount,
        presentationTablesTruncated: master.presentationTablesTruncated,
        presentationTablesUnknownReason: master.presentationTablesUnknownReason,
        canAddTable: master.canAddTable,
      );
  factory blank(String id, double width, double height) =>
      _SlideDraft(id, width, height, null, [
        _ShapeDraft(
          '$id/shape-0',
          true,
          _TextDraft(''),
          {'x': 10, 'y': 10, 'width': math.max(10, width - 20), 'height': 30},
          shapeKind: 'text',
          canEditFill: true,
          canEditLine: true,
          fillStyle: 'none',
          lineStyle: 'none',
        ),
      ], implicitShapeId: '$id/shape-0');
  final String id;
  final double width;
  final double height;
  final int? previewPage;
  final List<_ShapeDraft> shapes;
  final List<_PptTableDraft>? presentationTables;
  final int? presentationTableCount;
  final bool presentationTablesTruncated, canAddTable;
  final String? presentationTablesUnknownReason;
  String? selectedTableId, selectedCellId;
  final Set<String> sourceShapeIds;
  final String? implicitShapeId;
  final String? name;
  String? masterId;
  int? layoutCode;
  String? designSha256;
  bool? visible;
  bool? showMasterObjects;
  final String? originalBackgroundStyle;
  final int? originalBackgroundColor;
  String? backgroundStyle;
  int? backgroundColor;
  String? get changedBackgroundStyle =>
      backgroundStyle != originalBackgroundStyle ? backgroundStyle : null;
  int? get changedBackgroundColor =>
      backgroundColor != originalBackgroundColor ? backgroundColor : null;
  bool get backgroundChanged =>
      changedBackgroundStyle != null || changedBackgroundColor != null;
  bool get originalChanged =>
      backgroundChanged ||
      sourceShapeIds.any((id) => !shapes.any((shape) => shape.id == id)) ||
      shapes.any(
        (shape) =>
            !shape.isNew &&
            (shape.text.text.text != shape.text.originalText ||
                shape.text.styleChanged ||
                shape.assetId != null ||
                shape.geometryChanged ||
                shape.rotationChanged ||
                shape.appearanceChanged),
      );
  void dispose() {
    for (final shape in shapes) {
      shape.dispose();
    }
    for (final table in presentationTables ?? <_PptTableDraft>[])
      table.dispose();
  }
}
