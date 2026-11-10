import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:saber/data/office/docx_paragraph_insert.dart';
import 'package:saber/data/office/docx_photo_replacement.dart';
import 'package:saber/data/office/office_image_asset.dart';
import 'package:saber/data/office/pptx_photo_addition.dart';
import 'package:saber/data/office/pptx_photo_replacement.dart';

enum OfficePhotoAction { replace, remove, rotate }

typedef _DocxPhotoLocation = ({
  DocxParagraphAnchor anchor,
  DocxParagraphPosition position,
});

Future<
  ({
    int anchorParagraphIndex,
    DocxParagraphPosition position,
    WindowsOfficeImageAsset image,
  })?
>
chooseDocxPhotoInsertion(
  BuildContext context,
  DocxParagraphInsertPlan plan,
) async {
  final choice = await _showReplacementDialog(
    context,
    _OfficePhotoDialog<_DocxPhotoLocation>(
      photos: [
        for (final anchor in plan.paragraphs)
          for (final position in DocxParagraphPosition.values)
            if (anchor.allows(position)) (anchor: anchor, position: position),
      ],
      keyPrefix: 'docx-photo-add',
      title: 'DOCX 사진 추가',
      instructions: '기준 문단의 앞이나 뒤를 고르고 PNG 또는 JPEG를 선택하세요.',
      empty: '사진을 추가할 수 있는 본문 위치가 없습니다.',
      targetKey: (target) => '${target.anchor.index}-${target.position.name}',
      targetLabel: (target) =>
          '${target.anchor.index + 1}번 문단 '
          '${target.position == DocxParagraphPosition.before ? '앞' : '뒤'}',
      targetName: (target) =>
          target.anchor.text.trim().isEmpty ? '빈 문단' : target.anchor.text,
      applyLabel: '추가하고 저장',
    ),
  );
  return choice == null
      ? null
      : (
          anchorParagraphIndex: choice.target.anchor.index,
          position: choice.target.position,
          image: choice.image,
        );
}

Future<({int slideIndex, WindowsOfficeImageAsset image})?>
choosePptxPhotoAddition(
  BuildContext context,
  PptxPhotoAdditionPlan plan,
) async {
  final choice = await _showReplacementDialog(
    context,
    _OfficePhotoDialog<PptxPhotoAdditionSlide>(
      photos: plan.slides.where((slide) => slide.canAdd).toList(),
      keyPrefix: 'pptx-photo-add',
      title: 'PPTX 사진 추가',
      instructions: '슬라이드를 고르고 PNG 또는 JPEG를 선택하세요. 사진은 비율을 유지해 가운데에 놓입니다.',
      empty: '이 프레젠테이션에 사진을 추가할 수 있는 슬라이드가 없습니다.',
      targetKey: (slide) => '${slide.index}',
      targetLabel: (slide) =>
          '슬라이드 ${slide.index + 1}${slide.hidden ? ' · 숨김' : ''}',
      targetName: (slide) => [
        if (slide.title case final title? when title.isNotEmpty) title,
        if (slide.sectionName case final section? when section.isNotEmpty)
          '$section 구역',
      ].join(' · '),
      applyLabel: '추가하고 저장',
    ),
  );
  return choice == null
      ? null
      : (slideIndex: choice.target.index, image: choice.image);
}

Future<({PptxPhotoTarget target, WindowsOfficeImageAsset image})?>
choosePptxPhotoReplacement(BuildContext context, Uint8List source) async {
  final dialog = await _pptxPhotoDialog(source);
  if (!context.mounted) return null;
  return _showReplacementDialog(context, dialog);
}

Future<PptxPhotoTarget?> choosePptxPhotoTarget(
  BuildContext context,
  Uint8List source,
  OfficePhotoAction action,
) async {
  final dialog = await _pptxPhotoDialog(source, action: action);
  if (!context.mounted) return null;
  return (await _showPhotoDialog(context, dialog))?.target;
}

Future<_OfficePhotoDialog<PptxPhotoTarget>> _pptxPhotoDialog(
  Uint8List source, {
  OfficePhotoAction action = OfficePhotoAction.replace,
}) async {
  final photos = await compute(switch (action) {
    OfficePhotoAction.replace => listPptxPhotos,
    OfficePhotoAction.remove => listPptxDeletablePhotos,
    OfficePhotoAction.rotate => listPptxRotatablePhotos,
  }, source);
  return _OfficePhotoDialog<PptxPhotoTarget>(
    photos: photos,
    keyPrefix: switch (action) {
      OfficePhotoAction.replace => 'pptx-photo',
      OfficePhotoAction.remove => 'pptx-photo-delete',
      OfficePhotoAction.rotate => 'pptx-photo-rotate',
    },
    title: switch (action) {
      OfficePhotoAction.replace => 'PPTX 사진 교체',
      OfficePhotoAction.remove => 'PPTX 사진 삭제',
      OfficePhotoAction.rotate => 'PPTX 사진 회전',
    },
    instructions: switch (action) {
      OfficePhotoAction.replace => '슬라이드에서 바꿀 사진을 고른 다음 새 사진을 선택하세요.',
      OfficePhotoAction.remove => '삭제할 슬라이드 사진을 고르세요. 이전 원본과 필기는 판본 기록에 남습니다.',
      OfficePhotoAction.rotate => '오른쪽으로 90도 돌릴 사진을 고르세요.',
    },
    empty: switch (action) {
      OfficePhotoAction.replace => '이 프레젠테이션에 교체할 수 있는 사진이 없습니다.',
      OfficePhotoAction.remove => '이 프레젠테이션에 삭제할 수 있는 사진이 없습니다.',
      OfficePhotoAction.rotate => '이 프레젠테이션에 회전할 수 있는 사진이 없습니다.',
    },
    targetKey: (photo) => '${photo.slideNumber}-${photo.photoNumber}',
    targetLabel: (photo) =>
        '슬라이드 ${photo.slideNumber} · 사진 ${photo.photoNumber}',
    targetName: (photo) => photo.name,
    loadPreview: (photo) => compute(_loadPptxPhotoPreview, (source, photo)),
    targetOnlyLabel: switch (action) {
      OfficePhotoAction.replace => null,
      OfficePhotoAction.remove => '삭제하고 저장',
      OfficePhotoAction.rotate => '오른쪽 90도 회전하고 저장',
    },
  );
}

Future<({DocxPhotoTarget target, WindowsOfficeImageAsset image})?>
chooseDocxPhotoReplacement(
  BuildContext context,
  Uint8List source,
  DocxPhotoPlan plan,
) => _showReplacementDialog(context, _docxPhotoDialog(source, plan));

Future<DocxPhotoTarget?> chooseDocxPhotoTarget(
  BuildContext context,
  Uint8List source,
  DocxPhotoPlan plan,
  OfficePhotoAction action,
) async => (await _showPhotoDialog(
  context,
  _docxPhotoDialog(source, plan, action: action),
))?.target;

_OfficePhotoDialog<DocxPhotoTarget> _docxPhotoDialog(
  Uint8List source,
  DocxPhotoPlan plan, {
  OfficePhotoAction action = OfficePhotoAction.replace,
}) => _OfficePhotoDialog<DocxPhotoTarget>(
  photos: plan.photos,
  keyPrefix: switch (action) {
    OfficePhotoAction.replace => 'docx-photo',
    OfficePhotoAction.remove => 'docx-photo-delete',
    OfficePhotoAction.rotate => 'docx-photo-rotate',
  },
  title: switch (action) {
    OfficePhotoAction.replace => 'DOCX 사진 교체',
    OfficePhotoAction.remove => 'DOCX 사진 삭제',
    OfficePhotoAction.rotate => 'DOCX 사진 회전',
  },
  instructions: switch (action) {
    OfficePhotoAction.replace => '본문 문단에 삽입된 PNG·JPEG 중 바꿀 사진을 고르세요.',
    OfficePhotoAction.remove => '삭제할 본문 사진을 고르세요. 이전 원본과 필기는 판본 기록에 남습니다.',
    OfficePhotoAction.rotate => '오른쪽으로 90도 돌릴 본문 사진을 고르세요.',
  },
  empty: switch (action) {
    OfficePhotoAction.replace => '본문 문단에 교체할 수 있는 인라인 사진이 없습니다.',
    OfficePhotoAction.remove => '본문 문단에 삭제할 수 있는 인라인 사진이 없습니다.',
    OfficePhotoAction.rotate => '본문 문단에 회전할 수 있는 인라인 사진이 없습니다.',
  },
  targetKey: (photo) => '${photo.index + 1}',
  targetLabel: (photo) => '본문 사진 ${photo.index + 1}',
  targetName: (photo) => photo.title ?? '',
  loadPreview: (photo) => compute(_loadDocxPhotoPreview, (source, photo)),
  targetOnlyLabel: switch (action) {
    OfficePhotoAction.replace => null,
    OfficePhotoAction.remove => '삭제하고 저장',
    OfficePhotoAction.rotate => '오른쪽 90도 회전하고 저장',
  },
);

Future<({T target, WindowsOfficeImageAsset image})?> _showReplacementDialog<
  T extends Object
>(BuildContext context, _OfficePhotoDialog<T> dialog) async {
  final choice = await _showPhotoDialog(context, dialog);
  final image = choice?.image;
  if (choice == null || image == null) return null;
  return (target: choice.target, image: image);
}

Future<({T target, WindowsOfficeImageAsset? image})?> _showPhotoDialog<
  T extends Object
>(BuildContext context, _OfficePhotoDialog<T> dialog) =>
    showDialog<({T target, WindowsOfficeImageAsset? image})>(
      context: context,
      builder: (_) => dialog,
    );

Uint8List? _loadPptxPhotoPreview((Uint8List, PptxPhotoTarget) input) =>
    readPptxPhotoPreview(input.$1, input.$2);

Uint8List? _loadDocxPhotoPreview((Uint8List, DocxPhotoTarget) input) =>
    readDocxPhotoPreview(input.$1, input.$2);

class _OfficePhotoDialog<T extends Object> extends StatefulWidget {
  const new({
    required this.photos,
    required this.keyPrefix,
    required this.title,
    required this.instructions,
    required this.empty,
    required this.targetKey,
    required this.targetLabel,
    required this.targetName,
    this.loadPreview,
    this.targetOnlyLabel,
    this.applyLabel = '교체 적용',
  });

  final List<T> photos;
  final String keyPrefix, title, instructions, empty;
  final String Function(T) targetKey, targetLabel, targetName;
  final Future<Uint8List?> Function(T)? loadPreview;
  final String? targetOnlyLabel;
  final String applyLabel;

  @override
  State<_OfficePhotoDialog<T>> createState() => _OfficePhotoDialogState<T>();
}

class _OfficePhotoDialogState<T extends Object>
    extends State<_OfficePhotoDialog<T>> {
  T? _target;
  Uint8List? _preview;
  ({WindowsOfficeImageAsset image, String name})? _replacement;
  String? _error;
  var _previewing = false;
  var _picking = false;

  Future<void> _select(T target) async {
    if (_picking || _previewing || _target == target) return;
    final loadPreview = widget.loadPreview;
    setState(() {
      _target = target;
      _preview = null;
      _previewing = loadPreview != null;
      _replacement = null;
      _error = null;
    });
    if (loadPreview == null) return;
    Uint8List? preview;
    try {
      preview = await loadPreview(target);
    } catch (_) {
      // A thumbnail is optional, so the photo can still be selected.
    }
    if (!mounted) return;
    setState(() {
      _preview = preview;
      _previewing = false;
    });
  }

  Future<void> _pick() async {
    if (_target == null || _picking) return;
    setState(() {
      _picking = true;
      _error = null;
    });
    try {
      final file = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: const ['png', 'jpg', 'jpeg'],
        dialogTitle: '새 사진 선택',
      );
      if (!mounted || file == null) return;
      setState(() => _replacement = null);
      const tooLarge = FormatException('사진은 20 MiB 이하로 선택하세요.');
      const maxBytes = WindowsOfficeImageAsset.maxBytes;
      final length = await file.length();
      if (!mounted) return;
      if (length != null && length > maxBytes) throw tooLarge;
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in file.readAsByteStream()) {
        if (!mounted) return;
        if (chunk.length > maxBytes - bytes.length) throw tooLarge;
        bytes.add(chunk);
      }
      final WindowsOfficeImageAsset image;
      try {
        image = await compute(
          WindowsOfficeImageAsset.fromBytes,
          bytes.takeBytes(),
        );
      } on FormatException {
        throw const FormatException('열 수 있는 PNG 또는 JPEG 사진을 선택하세요.');
      }
      if (!mounted) return;
      setState(() => _replacement = (image: image, name: file.name));
    } on FormatException catch (error) {
      if (mounted) {
        setState(() {
          _replacement = null;
          _error = error.message;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _replacement = null;
          _error = '사진 파일을 읽지 못했습니다. 다시 선택하세요.';
        });
      }
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final target = _target;
    final replacement = _replacement;
    final preview = _preview;
    final targetOnlyLabel = widget.targetOnlyLabel;
    return AlertDialog(
      title: Text(widget.title),
      scrollable: true,
      content: SizedBox(
        width: 480,
        child: widget.photos.isEmpty
            ? Text(widget.empty)
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.instructions),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 152,
                    child: ListView.builder(
                      primary: false,
                      itemCount: widget.photos.length,
                      itemBuilder: (context, index) {
                        final photo = widget.photos[index];
                        final name = widget.targetName(photo).trim();
                        return ListTile(
                          key: ValueKey(
                            '${widget.keyPrefix}-target-${widget.targetKey(photo)}',
                          ),
                          title: Text(widget.targetLabel(photo)),
                          subtitle: name.isEmpty
                              ? null
                              : Text(
                                  name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                          selected: target == photo,
                          onTap: _picking || _previewing
                              ? null
                              : () => unawaited(_select(photo)),
                        );
                      },
                    ),
                  ),
                  if (_previewing)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Text('원본 사진 미리보기를 준비하고 있습니다.'),
                    )
                  else if (preview != null)
                    SizedBox(
                      height: 96,
                      width: double.infinity,
                      child: Image.memory(
                        preview,
                        key: ValueKey('${widget.keyPrefix}-thumbnail'),
                        cacheWidth: 320,
                        fit: BoxFit.contain,
                        semanticLabel: '선택한 원본 사진',
                        errorBuilder: (_, _, _) =>
                            const Text('원본 사진 미리보기를 열 수 없습니다.'),
                      ),
                    ),
                  if (targetOnlyLabel == null) ...[
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      key: ValueKey('${widget.keyPrefix}-pick'),
                      onPressed: target == null || _picking
                          ? null
                          : () => unawaited(_pick()),
                      icon: const Icon(Icons.photo_library_outlined),
                      label: Text(_picking ? '사진을 확인하고 있습니다.' : '새 사진 선택'),
                    ),
                  ],
                  if (replacement != null)
                    Text(
                      '선택한 사진 · ${replacement.name} · '
                      '${replacement.image.width} × ${replacement.image.height}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  if (_error case final error?)
                    Text(
                      error,
                      key: ValueKey('${widget.keyPrefix}-error'),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(widget.photos.isEmpty ? '닫기' : '취소'),
        ),
        if (widget.photos.isNotEmpty)
          FilledButton(
            key: ValueKey('${widget.keyPrefix}-apply'),
            onPressed:
                target == null ||
                    _picking ||
                    (targetOnlyLabel == null
                        ? replacement == null
                        : _previewing)
                ? null
                : () =>
                      Navigator.of(context)
                          .pop((target: target, image: replacement?.image)),
            child: Text(targetOnlyLabel ?? widget.applyLabel),
          ),
      ],
    );
  }
}
