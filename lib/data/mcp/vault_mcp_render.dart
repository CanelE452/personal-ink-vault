import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';
import 'package:saber/data/editor/page.dart';
import 'package:saber/data/mcp/vault_mcp_bridge.dart';
import 'package:saber/data/office/office_document_store.dart';
import 'package:saber/data/office/office_page_link.dart';
import 'package:saber/data/office/office_preview_engine.dart';
import 'package:saber/data/vault/note_link.dart';
import 'package:saber/data/vault/thumbnail_cache.dart';
import 'package:saber/data/vault/workspace_store.dart';

Future<Map<String, Object?>> renderVaultMcpPage(
  NoteRepository repository,
  Map<String, dynamic> arguments,
  VaultMcpCallContext context, {
  OfficePreviewEngine? previewEngine,
}) async {
  context.requireActive();
  if (arguments.keys.any(
        (key) => !{
          'noteId',
          'pageIndex',
          'revisionId',
          'officePageTarget',
        }.contains(key),
      ) ||
      arguments['noteId'] is! String ||
      (arguments['pageIndex'] ?? 0) is! int ||
      (arguments['revisionId'] != null && arguments['revisionId'] is! String)) {
    throw const VaultMcpException('invalid_arguments', '문서와 페이지 번호를 확인하세요.');
  }
  final id = arguments['noteId'] as String;
  _validateSelector(id);
  final cache = ThumbnailCache(
    Directory('${repository.root.path}/.cache/thumbnails'),
  );
  if (arguments.containsKey('officePageTarget')) {
    final target = _officePageTarget(arguments);
    return _renderOfficePageLink(repository, id, target, context, cache);
  }
  final pageIndex = arguments['pageIndex'] as int? ?? 0;
  if (pageIndex < 0)
    throw const VaultMcpException('invalid_arguments', '페이지 번호는 0부터 시작합니다.');
  final revisionId = arguments['revisionId'] as String?;
  if (revisionId != null) _validateSelector(revisionId);
  final notes = (await WorkspaceStore(repository).list(includeDeleted: true))
      .where((note) => note.id == id)
      .toList();
  if (notes.length != 1)
    throw const VaultMcpException('revision_conflict', '문서 판본을 먼저 확인하세요.');
  final note = notes.single;
  final Uint8List png;
  final int pages;
  final String selectedRevision;
  if (note.documentKind == VaultDocumentKind.office) {
    final edition = await OfficeDocumentStore(repository)
        .readLatest(note, revisionId: revisionId);
    final pdf =
        edition.pdfBytes ??
        await _previewOriginal(
          edition,
          context,
          previewEngine ?? OfficePreviewEngine(),
        );
    selectedRevision = edition.revision.revisionId;
    final annotations = edition.bindingId == null
        ? <RevisionRecord>[]
        : await repository.heads(edition.bindingId!);
    if (annotations.length > 1)
      throw const VaultMcpException('revision_conflict', '서로 다른 필기 판본이 있습니다.');
    if (annotations.isNotEmpty) {
      if (annotations.single.ownerNoteId != id || annotations.single.deleted)
        throw const VaultMcpException(
          'revision_not_owned',
          '이 문서의 필기 판본이 아닙니다.',
        );
      final image = await _renderSnapshot(
        cache,
        repository,
        annotations.single,
        pageIndex,
      );
      png = image.png;
      pages = image.pageCount;
    } else {
      final rendered = await _renderPdfPage(pdf, pageIndex);
      png = rendered.png;
      pages = rendered.pageCount;
    }
  } else if ({
    VaultDocumentKind.handwriting,
    VaultDocumentKind.pdf,
    VaultDocumentKind.image,
  }.contains(note.documentKind)) {
    final candidates = revisionId == null
        ? await repository.heads(note.inkEntityId)
        : (await repository.revisions())
              .where((record) => record.revisionId == revisionId)
              .toList();
    if (candidates.length != 1)
      throw const VaultMcpException('revision_conflict', '필기 판본을 먼저 선택하세요.');
    final revision = candidates.single;
    if (revision.ownerNoteId != id ||
        revision.entityId != note.inkEntityId ||
        revision.deleted ||
        revision.kind != EntityKind.ink)
      throw const VaultMcpException('revision_not_owned', '이 문서의 필기 판본이 아닙니다.');
    final image = await _renderSnapshot(cache, repository, revision, pageIndex);
    png = image.png;
    pages = image.pageCount;
    selectedRevision = revision.revisionId;
  } else {
    throw const VaultMcpException(
      'unsupported',
      '이 문서는 read_document로 본문을 읽으세요.',
    );
  }
  context.requireActive();
  return {
    'noteId': id,
    'revisionId': selectedRevision,
    'pageIndex': pageIndex,
    'pageCount': pages,
    'image': {'mimeType': 'image/png', 'data': base64Encode(png)},
  };
}

OfficePageTarget _officePageTarget(Map<String, dynamic> arguments) {
  if (arguments['pageIndex'] != null || arguments['revisionId'] != null) {
    throw const VaultMcpException(
      'invalid_arguments',
      'Office 페이지 대상과 기존 페이지 선택자를 함께 사용할 수 없습니다.',
    );
  }
  final value = arguments['officePageTarget'];
  if (value is! Map<String, dynamic> ||
      value.length != 3 ||
      value['sourceRevisionId'] is! String ||
      value['pdfBindingId'] is! String ||
      value['pageId'] is! String) {
    throw const VaultMcpException(
      'invalid_arguments',
      'Office 원본 판본, PDF 결합과 페이지 ID를 모두 입력하세요.',
    );
  }
  final target = (
    sourceRevisionId: value['sourceRevisionId'] as String,
    pdfBindingId: value['pdfBindingId'] as String,
    pageId: value['pageId'] as String,
  );
  _validateSelector(target.sourceRevisionId);
  _validateSelector(target.pdfBindingId);
  _validateSelector(target.pageId);
  return target;
}

typedef _PageImage = ({Uint8List png, int pageIndex, int pageCount});

Future<Map<String, Object?>> _renderOfficePageLink(
  NoteRepository repository,
  String noteId,
  OfficePageTarget target,
  VaultMcpCallContext context,
  ThumbnailCache cache,
) async {
  try {
    final selection = await resolveOfficePageLink(
      repository: repository,
      noteId: noteId,
      target: target,
    );
    context.requireActive();
    final ink = selection.annotation.revision;
    final _PageImage rendered;
    if (ink == null) {
      rendered = await _renderPdfPage(selection.bytes, 0, target: target);
    } else {
      final page = await _renderSnapshot(
        cache,
        repository,
        ink,
        0,
        pageId: target.pageId,
        expectedPdfSha256: selection.preview.pdfSha256,
      );
      rendered = (
        png: page.png,
        pageIndex: page.pageIndex,
        pageCount: page.pageCount,
      );
    }
    context.requireActive();
    await verifyOfficePageLinkSelection(selection);
    context.requireActive();
    return {
      'noteId': noteId,
      'revisionId': target.sourceRevisionId,
      'sourceRevisionId': target.sourceRevisionId,
      'pdfBindingId': target.pdfBindingId,
      'pageId': target.pageId,
      'pageIndex': rendered.pageIndex,
      'pageCount': rendered.pageCount,
      if (ink != null) 'annotationRevisionId': ink.revisionId,
      'officePageLink': NoteLink.officePage(noteId, target).toString(),
      'image': {'mimeType': 'image/png', 'data': base64Encode(rendered.png)},
    };
  } on OfficePageLinkException catch (error) {
    throw VaultMcpException(error.code, error.message);
  } on FormatException {
    throw const VaultMcpException(
      'office_source_mismatch',
      'Office 원본과 PDF 필기 판본을 확인할 수 없습니다.',
    );
  }
}

void _validateSelector(String id) {
  try {
    validateId(id);
  } on FormatException {
    throw const VaultMcpException('invalid_arguments', '올바른 문서·판본 ID를 입력하세요.');
  }
}

Future<RenderedSnapshotPage> _renderSnapshot(
  ThumbnailCache cache,
  NoteRepository repository,
  RevisionRecord revision,
  int pageIndex, {
  String? pageId,
  String? expectedPdfSha256,
}) async {
  try {
    return await cache.renderSnapshotPage(
      repository,
      revision,
      pageIndex: pageIndex,
      pageId: pageId,
      expectedPdfSha256: expectedPdfSha256,
    );
  } on RangeError {
    throw const VaultMcpException('page_out_of_range', '문서에 없는 페이지입니다.');
  }
}

Future<Uint8List> _previewOriginal(
  OfficeEdition edition,
  VaultMcpCallContext context,
  OfficePreviewEngine engine,
) async {
  final work = await Directory.systemTemp.createTemp('piv-mcp-preview-');
  OfficePreviewResult? preview;
  try {
    context.requireActive();
    final source = await File(p.join(work.path, edition.originalFileName))
        .writeAsBytes(edition.originalBytes, flush: true);
    preview = await engine.preview(sourcePath: source.path, sessionId: newId());
    context.requireActive();
    final result = preview;
    if (result == null)
      throw const VaultMcpException('preview_cancelled', '미리보기 생성을 취소했습니다.');
    return await File(result.pdfPath).readAsBytes();
  } finally {
    try {
      await preview?.dispose();
    } finally {
      if (p.isWithin(Directory.systemTemp.path, work.path) &&
          p.basename(work.path).startsWith('piv-mcp-preview-')) {
        await work.delete(recursive: true);
      }
    }
  }
}

Future<_PageImage> _renderPdfPage(
  Uint8List bytes,
  int pageIndex, {
  OfficePageTarget? target,
}) async {
  final document = await PdfDocument.openData(bytes);
  try {
    final pages = document.pages.length;
    final int index;
    if (target == null) {
      index = pageIndex;
    } else if (pages > 0 &&
        target.pageId == officePdfBaselinePageId(target.pdfBindingId, -1)) {
      return (
        png: await _renderBlankPage(),
        pageIndex: pages,
        pageCount: pages + 1,
      );
    } else {
      index = document.pages.indexWhere(
        (page) =>
            officePdfBaselinePageId(target.pdfBindingId, page.pageNumber - 1) ==
            target.pageId,
      );
    }
    if (index < 0 || index >= pages)
      throw const VaultMcpException('page_out_of_range', '문서에 없는 페이지입니다.');
    final page = document.pages[index];
    await page.ensureLoaded();
    final scale = math.min(1200 / page.width, 2400 / page.height);
    final width = math.max(1, (page.width * scale).round());
    final height = math.max(1, (page.height * scale).round());
    final rendered = await page.render(
      width: width,
      height: height,
      fullWidth: width.toDouble(),
      fullHeight: height.toDouble(),
    );
    if (rendered == null)
      throw const VaultMcpException('render_failed', 'PDF 페이지를 표시하지 못했습니다.');
    try {
      return (
        png: await _encodePng(await rendered.createImage()),
        pageIndex: index,
        pageCount: pages + (target == null ? 0 : 1),
      );
    } finally {
      rendered.dispose();
    }
  } finally {
    await document.dispose();
  }
}

Future<Uint8List> _renderBlankPage() async {
  const width = 1200;
  final height = (width * EditorPage.defaultHeight / EditorPage.defaultWidth)
      .round();
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawColor(const ui.Color(0xffffffff), ui.BlendMode.src);
  final picture = recorder.endRecording();
  try {
    return await _encodePng(await picture.toImage(width, height));
  } finally {
    picture.dispose();
  }
}

Future<Uint8List> _encodePng(ui.Image image) async {
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null || data.lengthInBytes > 5 * 1024 * 1024)
      throw const VaultMcpException('result_too_large', '페이지 이미지가 너무 큽니다.');
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } finally {
    image.dispose();
  }
}
