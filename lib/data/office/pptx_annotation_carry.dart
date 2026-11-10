import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:crypto/crypto.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';
import 'package:saber/components/canvas/image/editor_image.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/office/office_annotation_store.dart';
import 'package:saber/data/office/office_document_store.dart';
import 'package:saber/data/office/office_page_link.dart';
import 'package:saber/data/office/pptx_slide_identity.dart';
import 'package:saber/data/vault/pdf_import_state.dart';
import 'package:saber/data/vault/saber_ink_adapter.dart';
import 'package:saber/data/vault/workspace_store.dart';

Future<({int copiedPages, int skippedPages})> carryPreviousPptxAnnotations({
  required NoteRepository repository,
  required VaultNote note,
  required OfficeEdition edition,
  required bool Function() isCurrent,
  PptxSlideIdentityEngine slideIdentity = const PptxSlideIdentityEngine(),
}) async {
  void requireCurrent() {
    if (!isCurrent()) throw StateError('필기를 가져올 원본이 바뀌었습니다.');
  }

  requireCurrent();
  final documents = OfficeDocumentStore(repository);
  final current = await documents.readLatest(note);
  final binding = current.bindingId;
  final previousId = current.revision.parentRevisionIds.singleOrNull;
  final newPdf = current.pdfBytes;
  if (current.revision.revisionId != edition.revision.revisionId ||
      !current.originalFileName.toLowerCase().endsWith('.pptx') ||
      binding == null ||
      previousId == null ||
      newPdf == null) {
    throw StateError('최신 PPTX의 저장된 PDF에서 이전 필기를 가져올 수 있습니다.');
  }
  if ((await repository.heads(binding)).isNotEmpty) {
    throw StateError('현재 PDF에 이미 필기가 있습니다.');
  }
  final previous = await documents.readLatest(note, revisionId: previousId);
  if (!previous.originalFileName.toLowerCase().endsWith('.pptx')) {
    throw StateError('바로 이전 판본에 PPTX 원본이 없습니다.');
  }
  final annotations = OfficeAnnotationStore(repository);
  OfficePdfVariant? previousPdf;
  for (final variant in await documents.readPdfVariants(note, previous)) {
    if ((await repository.heads(variant.bindingId)).isEmpty) continue;
    if (previousPdf != null) {
      throw StateError('이전 PDF 필기가 여러 버전에 있습니다. 판본 기록에서 확인하세요.');
    }
    previousPdf = variant;
  }
  if (previousPdf == null) return (copiedPages: 0, skippedPages: 0);
  final previousInk = await annotations.open(
    note,
    previous,
    preview: previousPdf,
  );
  final previousInkId = previousInk.revision?.revisionId;
  if (previousInkId == null || previousPdf.bindingId == binding) {
    throw StateError('이전 필기 판본이 바뀌었습니다.');
  }
  final previousBytes = await documents.readPdfVariantBytes(
    note,
    previous,
    previousPdf,
  );
  requireCurrent();
  final match = await _matchSlides(previous, current, slideIdentity);
  requireCurrent();

  final source = await previousInk.load();
  try {
    final sourcePages = await PdfImportPreparation.findBoundPages(
      source,
      pdfSha256: previousPdf.pdfSha256,
      pageCount: match.previousSlideCount,
      isCurrent: isCurrent,
    );
    requireCurrent();
    final oldDocument = await PdfDocument.openData(
      previousBytes,
      useProgressiveLoading: false,
    );
    try {
      final newDocument = await PdfDocument.openData(
        newPdf,
        useProgressiveLoading: false,
      );
      try {
        if (oldDocument.pages.length != match.previousSlideCount ||
            newDocument.pages.length != match.currentSlideCount) {
          throw const FormatException('원본 슬라이드 수와 PDF 쪽 수가 일치하지 않습니다.');
        }
        if (newDocument.pages.any(
          (page) =>
              !page.width.isFinite ||
              !page.height.isFinite ||
              page.width <= 0 ||
              page.height <= 0 ||
              !(EditorPage.defaultWidth * page.height / page.width).isFinite,
        )) {
          throw const FormatException('현재 PDF에서 슬라이드 크기를 확인하지 못했습니다.');
        }
        final pagesByBackground = Map<PdfEditorImage, EditorPage>.identity();
        for (final page in source.pages) {
          if (page.backgroundImage case final PdfEditorImage background) {
            pagesByBackground[background] = page;
          }
        }
        final carried = <int, EditorPage>{};
        for (var index = 0; index < match.previousSlideCount; index++) {
          requireCurrent();
          final destination = match.previousToCurrent[index];
          final oldPage = pagesByBackground[sourcePages[index + 1]?.background];
          if (destination == null || oldPage == null || !_hasInk(oldPage))
            continue;
          final before = oldDocument.pages[index];
          final after = newDocument.pages[destination];
          final background = oldPage.backgroundImage! as PdfEditorImage;
          if (background.naturalSize == before.size &&
              await _samePage(before, after, isCurrent)) {
            carried[destination] = oldPage;
          }
        }
        requireCurrent();
        final skipped = source.pages.where(_hasInk).length - carried.length;
        if (carried.isEmpty) return (copiedPages: 0, skippedPages: skipped);

        final target = EditorCoreInfo(filePath: previousInk.workingPath)
          ..backgroundColor = source.backgroundColor
          ..backgroundPattern = source.backgroundPattern
          ..lineHeight = source.lineHeight
          ..lineThickness = source.lineThickness
          ..nextImageId = source.nextImageId;
        try {
          for (var index = 0; index < newDocument.pages.length; index++) {
            final pdf = newDocument.pages[index];
            final oldPage = carried[index];
            final oldBackground = oldPage?.backgroundImage as PdfEditorImage?;
            final size =
                oldPage?.size ??
                Size(
                  EditorPage.defaultWidth,
                  EditorPage.defaultWidth * pdf.height / pdf.width,
                );
            final page = EditorPage(
              pageId: officePdfBaselinePageId(binding, index),
              size: size,
              strokes: oldPage?.strokes.map((stroke) => stroke.copy()).toList(),
              images: oldPage?.images.map((image) => image.copy()).toList(),
              quill: oldPage?.quill.cloneForScreenshot(),
              backgroundImage: PdfEditorImage(
                id: target.nextImageId++,
                assetCache: target.assetCache,
                pdfBytes: newPdf,
                pdfFile: null,
                pdfPage: index,
                pageIndex: index,
                pageSize: size,
                naturalSize: pdf.size,
                invertible: oldBackground?.invertible ?? true,
                backgroundFit: oldBackground?.backgroundFit ?? .contain,
                dstRect: oldBackground?.dstRect ?? Rect.zero,
                onMoveImage: null,
                onDeleteImage: null,
                onMiscChange: null,
              ),
            );
            page.updatePageIndex(index);
            target.pages.add(page);
          }
          target.pages.add(
            EditorPage(pageId: officePdfBaselinePageId(binding, -1)),
          );
          final files = await SaberInkAdapter.capture(
            target,
            carried.keys.first,
          );
          requireCurrent();
          await repository.commitPreparedIfHeads(
            repository.prepareCommit(
              entityId: binding,
              kind: EntityKind.ink,
              ownerNoteId: note.id,
              files: files,
              parentRevisionIds: const [],
            ),
            expectedHeads: {
              current.revision.entityId: [current.revision.revisionId],
              note.id: [note.revision.revisionId],
              previousPdf.bindingId: [previousInkId],
              binding: const [],
            },
            beforePublish: requireCurrent,
          );
        } finally {
          target.dispose();
        }
        return (copiedPages: carried.length, skippedPages: skipped);
      } finally {
        await newDocument.dispose();
      }
    } finally {
      await oldDocument.dispose();
    }
  } finally {
    source.dispose();
  }
}

bool _hasInk(EditorPage page) =>
    page.strokes.isNotEmpty ||
    page.images.isNotEmpty ||
    !page.quill.controller.document.isEmpty();

Future<bool> _samePage(
  PdfPage before,
  PdfPage after,
  bool Function() isCurrent,
) async {
  if (before.size != after.size ||
      before.rotation != after.rotation ||
      !before.width.isFinite ||
      !before.height.isFinite ||
      before.width <= 0 ||
      before.height <= 0)
    return false;
  final scale = math.min(2.0, 1600 / math.max(before.width, before.height));
  final width = math.max(1, (before.width * scale).round());
  final height = math.max(1, (before.height * scale).round());
  Future<Digest?> hash(PdfPage page) async {
    final image = await page.render(
      width: width,
      height: height,
      fullWidth: width.toDouble(),
      fullHeight: height.toDouble(),
    );
    if (image == null) return null;
    try {
      return sha256.convert(image.pixels);
    } finally {
      image.dispose();
    }
  }

  final original = await hash(before);
  return original != null && isCurrent() && original == await hash(after);
}

Future<PptxSlideIdentityMatch> _matchSlides(
  OfficeEdition previous,
  OfficeEdition current,
  PptxSlideIdentityEngine slideIdentity,
) async {
  final directory = await Directory.systemTemp.createTemp('piv-pptx-ink-');
  final before = File(p.join(directory.path, 'previous.pptx'));
  final after = File(p.join(directory.path, 'current.pptx'));
  try {
    await before.writeAsBytes(previous.originalBytes, flush: true);
    await after.writeAsBytes(current.originalBytes, flush: true);
    return await slideIdentity.match(
      previousPath: before.path,
      previousSha256: previous.originalSha256,
      currentPath: after.path,
      currentSha256: current.originalSha256,
    );
  } finally {
    if (before.existsSync()) await before.delete();
    if (after.existsSync()) await after.delete();
    await directory.delete();
  }
}
