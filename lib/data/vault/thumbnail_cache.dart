import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/painting.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';
import 'package:saber/components/canvas/image/editor_image.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/editor/editor_exporter.dart';
import 'package:saber/data/office/office_document_store.dart';
import 'package:saber/data/office/office_preview_engine.dart';
import 'package:saber/data/vault/block_page_document.dart';
import 'package:saber/data/vault/card_canvas_document.dart';
import 'package:saber/data/vault/infinite_document.dart';
import 'package:saber/data/vault/saber_ink_adapter.dart';
import 'package:saber/data/vault/workspace_database.dart';
import 'package:saber/data/vault/workspace_store.dart';

class RenderedSnapshotPage {
  final Uint8List png;
  final int pageCount;
  final String pageId;
  final int pageIndex;
  const new(this.png, this.pageCount, this.pageId, this.pageIndex);
}

class ThumbnailCache {
  static const rendererVersion = 2;
  static const _width = 240;
  static const _maxHeight = 320;
  static const _maxPngBytes = 1024 * 1024;
  static const _maxSnapshotBytes = 64 * 1024 * 1024;
  static const _maxBodyBytes = 16 * 1024 * 1024;
  static const _maxAssetBytes = 48 * 1024 * 1024;
  final Directory root;
  final _inFlight = <String, Future<File?>>{};
  final _officeBindings = <String, Future<String?>>{};
  Future<void> _renderQueue = Future.value();
  Future<void>? _publication;
  var _retired = false;
  final OfficePreviewEngine officePreviewEngine;
  final Future<void> Function(File, Uint8List)? _writePng;
  new(
    this.root, {
    OfficePreviewEngine? officePreviewEngine,
    @visibleForTesting this._writePng,
  }) : officePreviewEngine = officePreviewEngine ?? OfficePreviewEngine();

  /// Stops new cover work and drains only PNG publication already in progress.
  Future<void> retire() {
    _retired = true;
    return _publication ?? Future<void>.value();
  }

  Future<String?> coverKey(NoteRepository repository, VaultNote note) async {
    if (_retired) return null;
    try {
      final revision = await _coverRevision(repository, note);
      return _retired || revision == null
          ? null
          : _key(
              note,
              revision.officePdf?.revision ?? revision.body,
              annotation: revision.annotation,
            );
    } catch (_) {
      return null;
    }
  }

  String _key(
    VaultNote note,
    RevisionRecord revision, {
    RevisionRecord? annotation,
  }) =>
      'r$rendererVersion-${note.documentKind.name}-${revision.revisionId}${annotation == null ? '' : '-${annotation.revisionId}'}';

  Future<
    ({
      RevisionRecord body,
      RevisionRecord? annotation,
      OfficePdfVariant? officePdf,
    })?
  >
  _coverRevision(NoteRepository repository, VaultNote note) async {
    if (_retired || note.revision.vaultId != repository.vaultId) return null;
    final entity = switch (note.documentKind) {
      VaultDocumentKind.markdown => note.markdownEntityId,
      VaultDocumentKind.office => note.sourceEntityId,
      _ => note.inkEntityId,
    };
    if (entity == null) return null;
    final heads = await repository.heads(entity);
    if (_retired || heads.length != 1) return null;
    final revision = heads.single;
    if (!_matchesRevision(repository, note, revision)) return null;
    RevisionRecord? annotation;
    OfficePdfVariant? officePdf;
    if (note.documentKind == VaultDocumentKind.office) {
      if (revision.blobs.length > 3 ||
          revision.blobs.values.fold<int>(0, (sum, blob) => sum + blob.length) >
              128 * 1024 * 1024)
        return null;
      final String? binding;
      if (revision.blobs.containsKey('edition.json')) {
        binding = await _officeBinding(repository, note, revision);
      } else {
        final variants = await OfficeDocumentStore(repository)
            .readDerivedPdfVariants(note, revision);
        if (variants.length > 1) return null;
        officePdf = variants.singleOrNull;
        binding = officePdf?.bindingId;
      }
      if (_retired) return null;
      if (binding != null) {
        final annotations = await repository.heads(binding);
        if (annotations.length > 1) return null;
        annotation = annotations.singleOrNull;
        if (annotation != null &&
            (annotation.vaultId != repository.vaultId ||
                annotation.entityId != binding ||
                annotation.kind != EntityKind.ink ||
                annotation.ownerNoteId != note.id ||
                annotation.deleted))
          return null;
      }
    }
    return (body: revision, annotation: annotation, officePdf: officePdf);
  }

  Future<String?> _officeBinding(
    NoteRepository repository,
    VaultNote note,
    RevisionRecord revision,
  ) async {
    final key = '${repository.vaultId}/${revision.revisionId}';
    final binding = _officeBindings.putIfAbsent(
      key,
      () =>
          OfficeDocumentStore(repository)
              .readLatest(note, revisionId: revision.revisionId)
              .then((edition) => edition.bindingId),
    );
    try {
      return await binding;
    } catch (_) {
      if (identical(_officeBindings[key], binding)) _officeBindings.remove(key);
      rethrow;
    }
  }

  bool _matchesRevision(
    NoteRepository repository,
    VaultNote note,
    RevisionRecord revision,
  ) {
    final (entity, kind) = switch (note.documentKind) {
      VaultDocumentKind.markdown => (
        note.markdownEntityId,
        EntityKind.markdown,
      ),
      VaultDocumentKind.office => (note.sourceEntityId, EntityKind.attachment),
      _ => (note.inkEntityId, EntityKind.ink),
    };
    return revision.vaultId == repository.vaultId &&
        revision.entityId == entity &&
        revision.kind == kind &&
        revision.ownerNoteId == note.id &&
        !revision.deleted;
  }

  Future<RenderedSnapshotPage> renderSnapshotPage(
    NoteRepository repository,
    RevisionRecord revision, {
    int pageIndex = 0,
    String? pageId,
    String? expectedPdfSha256,
    int width = 1200,
  }) async {
    if (width < 64 || width > 1600) throw RangeError.range(width, 64, 1600);
    if (revision.kind != EntityKind.ink ||
        revision.vaultId != repository.vaultId ||
        !await _validSnapshot(repository, revision)) {
      throw const FormatException('읽을 수 있는 필기 저장본이 아닙니다.');
    }
    final core = await SaberInkAdapter.load(repository, revision);
    final pinned = <_PinnedImage>[];
    ui.Image? image;
    try {
      final index = pageId == null
          ? pageIndex
          : core.pages.indexed
                    .where((entry) => entry.$2.pageId == pageId)
                    .singleOrNull
                    ?.$1 ??
                -1;
      if (index < 0 || index >= core.pages.length)
        throw RangeError.index(index, core.pages);
      final page = core.pages[index];
      final background = page.backgroundImage;
      if (expectedPdfSha256 != null && background is PdfEditorImage) {
        final bytes = background.pdfBytes;
        final file = background.pdfFile;
        final reference = file == null
            ? null
            : revision.blobs[p.basename(file.path)];
        final digest = bytes != null
            ? sha256.convert(bytes).toString()
            : reference?.hash;
        if (digest != expectedPdfSha256) {
          throw const FormatException('필기의 PDF 배경이 선택한 PDF와 다릅니다.');
        }
        // Keep PDFium on the verified revision bytes if another reader
        // materializes the same snapshot while this page is rendering.
        background.pdfBytes = bytes ?? await repository.readBlob(digest!);
      }
      final size = page.size;
      if (!size.width.isFinite ||
          !size.height.isFinite ||
          size.width <= 0 ||
          size.height <= 0 ||
          size.width > 100000 ||
          size.height > 100000)
        throw const FormatException('Invalid page size');
      final scale = math.min(width / size.width, 2400 / size.height);
      final targetWidth = math.max(1, (size.width * scale).round());
      final targetHeight = math.max(1, (size.height * scale).round());
      final images = [?page.backgroundImage, ...page.images];
      if (images.length > 16) throw const FormatException('이미지가 너무 많은 페이지입니다.');
      for (final source in images) {
        final natural = source.naturalSize;
        if (!natural.width.isFinite ||
            !natural.height.isFinite ||
            natural.width < 0 ||
            natural.height < 0 ||
            natural.width * natural.height > 40000000)
          throw const FormatException('이미지가 너무 큽니다.');
        await _loadSnapshotImage(source);
        EditorImage rendered = source;
        if (source is PdfEditorImage) {
          final raster = await _rasterizePdf(
            source,
            maxWidth: targetWidth,
            maxHeight: targetHeight,
          );
          if (identical(page.backgroundImage, source)) {
            page.backgroundImage = raster;
          } else {
            page.images[page.images.indexOf(source)] = raster;
          }
          source.dispose();
          rendered = raster;
        }
        if (rendered is PngEditorImage)
          pinned.add(await _PinnedImage.load(rendered.imageProvider));
      }
      image = await EditorExporter.screenshotPage(
        coreInfo: core,
        pageIndex: index,
        rasterizeAllStrokes: true,
        targetSize: ui.Size(targetWidth.toDouble(), targetHeight.toDouble()),
        pixelRatio: 1,
      );
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null || data.lengthInBytes > 5 * 1024 * 1024)
        throw const FormatException('페이지 이미지가 너무 큽니다.');
      return RenderedSnapshotPage(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        core.pages.length,
        page.pageId,
        index,
      );
    } finally {
      image?.dispose();
      for (final entry in pinned) {
        entry.dispose();
      }
      core.dispose();
    }
  }

  Future<File?> getOrCreate(NoteRepository repository, VaultNote note) async {
    if (_retired) return null;
    try {
      final revision = await _coverRevision(repository, note);
      if (_retired || revision == null) return null;
      return await _ensure(
        repository,
        note,
        revision.body,
        annotation: revision.annotation,
        officePdf: revision.officePdf,
      );
    } catch (_) {
      return null;
    }
  }

  Future<File?> capture(
    NoteRepository repository,
    VaultNote note,
    RevisionRecord revision,
    EditorCoreInfo core,
  ) async {
    if (_retired) return null;
    try {
      if (!_inkCover(note)) return null;
      final matches = (await repository.revisions()).where(
        (record) => record.revisionId == revision.revisionId,
      );
      if (_retired || matches.length != 1) return null;
      // Render the committed snapshot, rather than an editor that can change
      // while a PNG is being generated. The caller retains ownership of core.
      return await _ensure(repository, note, matches.single);
    } catch (_) {
      return null;
    }
  }

  bool _inkCover(VaultNote note) => switch (note.documentKind) {
    VaultDocumentKind.handwriting ||
    VaultDocumentKind.pdf ||
    VaultDocumentKind.image => true,
    _ => false,
  };

  Future<File?> _ensure(
    NoteRepository repository,
    VaultNote note,
    RevisionRecord revision, {
    RevisionRecord? annotation,
    OfficePdfVariant? officePdf,
  }) async {
    if (_retired || !_matchesRevision(repository, note, revision)) return null;
    final coverRevision = officePdf?.revision ?? revision;
    for (final id in [
      repository.vaultId,
      note.id,
      coverRevision.revisionId,
      if (annotation != null) annotation.revisionId,
    ]) {
      validateId(id);
    }
    final destination = File(
      '${root.path}/${repository.vaultId}/${note.id}/${_key(note, coverRevision, annotation: annotation)}.png',
    );
    final existing = _inFlight[destination.path];
    if (existing != null) return existing;
    final rendering = _renderQueue.then(
      (_) => _renderOrRead(
        repository,
        note,
        revision,
        destination,
        annotation: annotation,
        officePdf: officePdf,
      ),
    );
    _renderQueue = rendering.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    final result = rendering.whenComplete(() {
      _inFlight.remove(destination.path);
    });
    _inFlight[destination.path] = result;
    return result;
  }

  Future<File?> _renderOrRead(
    NoteRepository repository,
    VaultNote note,
    RevisionRecord revision,
    File destination, {
    RevisionRecord? annotation,
    OfficePdfVariant? officePdf,
  }) async {
    if (_retired) return null;
    EditorCoreInfo? core;
    ui.Image? image;
    final pinnedImages = <_PinnedImage>[];
    try {
      final cached = await _validCachedFile(destination);
      if (_retired) return null;
      if (cached) return destination;
      if (_inkCover(note) || annotation != null) {
        final snapshot = annotation ?? revision;
        if (!await _validSnapshot(repository, snapshot)) return null;
        core = await SaberInkAdapter.load(repository, snapshot);
        if (core.pages.isEmpty) return null;
        final page = core.pages.first;
        final size = page.size;
        if (!size.width.isFinite ||
            !size.height.isFinite ||
            size.width <= 0 ||
            size.height <= 0 ||
            size.width > 100000 ||
            size.height > 100000)
          return null;
        final pageImages = [?page.backgroundImage, ...page.images];
        if (pageImages.length > 16) return null;
        for (final pageImage in pageImages) {
          final natural = pageImage.naturalSize;
          if (!natural.width.isFinite ||
              !natural.height.isFinite ||
              natural.width < 0 ||
              natural.height < 0 ||
              natural.width * natural.height > 40000000)
            return null;
          await _loadSnapshotImage(pageImage);
          EditorImage renderImage = pageImage;
          if (pageImage is PdfEditorImage) {
            final raster = await _rasterizePdf(pageImage);
            if (identical(page.backgroundImage, pageImage)) {
              page.backgroundImage = raster;
            } else {
              page.images[page.images.indexOf(pageImage)] = raster;
            }
            pageImage.dispose();
            renderImage = raster;
          }
          if (renderImage is PngEditorImage) {
            pinnedImages.add(
              await _PinnedImage.load(renderImage.imageProvider),
            );
          }
        }
        final cropHeight = math.min(
          size.height,
          size.width * _maxHeight / _width,
        );
        final height = (_width * cropHeight / size.width).round().clamp(
          1,
          _maxHeight,
        );
        image = await EditorExporter.screenshotPage(
          coreInfo: core,
          pageIndex: 0,
          rasterizeAllStrokes: true,
          targetSize: ui.Size(_width.toDouble(), height.toDouble()),
          cropHeight: cropHeight,
          pixelRatio: 1,
        );
      } else {
        image = note.documentKind == VaultDocumentKind.office
            ? await _renderOffice(repository, note, revision, officePdf)
            : await _renderBody(repository, note, revision);
      }
      if (_retired || image == null) return null;
      final encoded = await image.toByteData(format: ui.ImageByteFormat.png);
      if (_retired || encoded == null) return null;
      final bytes = encoded.buffer.asUint8List(
        encoded.offsetInBytes,
        encoded.lengthInBytes,
      );
      if (!_validPngHeader(bytes) || bytes.length > _maxPngBytes) return null;
      return await _publishPng(destination, bytes);
    } catch (_) {
      return null;
    } finally {
      image?.dispose();
      for (final pinned in pinnedImages) {
        pinned.dispose();
      }
      core?.dispose();
    }
  }

  Future<File?> _publishPng(File destination, Uint8List bytes) async {
    if (_retired) return null;
    // The render queue serializes publication. Admit it before the first I/O.
    final finished = Completer<void>();
    _publication = finished.future;
    File? temporary;
    try {
      await destination.parent.create(recursive: true);
      temporary = File('${destination.path}.${newId()}.tmp');
      final writePng = _writePng;
      if (writePng == null) {
        await temporary.writeAsBytes(bytes, flush: true);
      } else {
        await writePng(temporary, bytes);
      }
      await temporary.rename(destination.path);
      temporary = null;
      return _retired ? null : destination;
    } finally {
      try {
        if (temporary != null && temporary.existsSync())
          await temporary.delete();
      } catch (_) {
        // The thumbnail remains optional if temporary cleanup fails.
      } finally {
        _publication = null;
        finished.complete();
      }
    }
  }

  Future<ui.Image?> _renderBody(
    NoteRepository repository,
    VaultNote note,
    RevisionRecord revision,
  ) async {
    if (revision.blobs.length > 8 ||
        revision.blobs.values.fold<int>(0, (sum, blob) => sum + blob.length) >
            _maxBodyBytes)
      return null;
    final files = await repository.readFiles(revision);
    Map<String, dynamic> json(String name) {
      final bytes = files[name];
      if (bytes == null || bytes.isEmpty)
        throw const FormatException('Missing document body');
      return jsonObject(jsonDecode(utf8.decode(bytes)));
    }

    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawColor(const ui.Color(0xffffffff), ui.BlendMode.src);
    ui.Picture? picture;
    try {
      switch (note.documentKind) {
        case VaultDocumentKind.markdown:
          final bytes = files['summary.md'];
          if (bytes == null) return null;
          final text = utf8.decode(bytes);
          if (text.trim().isEmpty) return null;
          _paintMarkdown(canvas, text);
        case VaultDocumentKind.page:
          final page = BlockPageDocument.fromJson(json('page.json'));
          var y = 18.0;
          void paintBlocks(List<BlockPageBlock> blocks, int depth) {
            for (final block in blocks) {
              if (y >= _maxHeight - 16) return;
              final heading = block.type.startsWith('heading');
              if (block.type == 'divider') {
                canvas.drawLine(
                  ui.Offset(18, y + 5),
                  ui.Offset(_width - 18, y + 5),
                  ui.Paint()..color = const ui.Color(0xffc9d5d2),
                );
                y += 16;
              } else {
                final prefix = switch (block.type) {
                  'todo' => block.checked ? '☑ ' : '☐ ',
                  'bullet' => '• ',
                  'toggle' => '▸ ',
                  'quote' => '│ ',
                  _ => '',
                };
                y +=
                    _paintText(
                      canvas,
                      '$prefix${block.text}',
                      ui.Offset(18 + math.min(depth, 5) * 9, y),
                      width: _width - 36 - math.min(depth, 5) * 9,
                      size: heading ? (block.type == 'heading1' ? 19 : 16) : 12,
                      bold: heading,
                      maxLines: heading ? 2 : 4,
                    ) +
                    9;
              }
              paintBlocks(block.children, depth + 1);
            }
          }
          paintBlocks(page.blocks, 0);
        case VaultDocumentKind.database:
          _paintDatabase(
            canvas,
            WorkspaceDatabase.fromJson(json('database.json')),
          );
        case VaultDocumentKind.canvas:
          _paintCardCanvas(
            canvas,
            CardCanvasDocument.fromJson(json('board.canvas')),
          );
        case VaultDocumentKind.infinite:
          _paintInfinite(
            canvas,
            InfiniteDocument.fromJson(json('infinite.json')),
          );
        default:
          return null;
      }
      picture = recorder.endRecording();
      return await picture.toImage(_width, _maxHeight);
    } finally {
      if (recorder.isRecording) recorder.endRecording().dispose();
      picture?.dispose();
    }
  }

  double _paintText(
    ui.Canvas canvas,
    String text,
    ui.Offset position, {
    double width = _width - 36,
    double size = 12,
    bool bold = false,
    int maxLines = 4,
    ui.Color color = const ui.Color(0xff263532),
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: text.length > 2000 ? text.substring(0, 2000) : text,
        style: TextStyle(
          fontSize: size,
          fontWeight: bold ? ui.FontWeight.w700 : ui.FontWeight.w400,
          height: 1.35,
          color: color,
        ),
      ),
      textDirection: ui.TextDirection.ltr,
      maxLines: maxLines,
      ellipsis: '…',
    );
    try {
      painter.layout(maxWidth: math.max(1, width));
      painter.paint(canvas, position);
      return painter.height;
    } finally {
      painter.dispose();
    }
  }

  void _paintMarkdown(ui.Canvas canvas, String body) {
    var y = 18.0;
    final sample = body.length > 16000 ? body.substring(0, 16000) : body;
    var code = false;
    for (final raw in sample.split('\n').take(100)) {
      if (y >= _maxHeight - 16) break;
      if (raw.trimLeft().startsWith('```')) {
        code = !code;
        continue;
      }
      final heading = RegExp(r'^\s{0,3}(#{1,6})\s+').firstMatch(raw);
      var text = heading == null ? raw : raw.substring(heading.end);
      text = text.replaceAllMapped(
        RegExp(r'!?\[([^\]]*)\]\([^)]*\)'),
        (match) => match[1]!,
      );
      text = text.replaceAll(RegExp(r'\*\*|__|`'), '');
      if (text.trim().isEmpty) {
        y += 7;
        continue;
      }
      if (code)
        canvas.drawRect(
          ui.Rect.fromLTWH(14, y - 2, _width - 28, 22),
          ui.Paint()..color = const ui.Color(0xfff0f3f2),
        );
      y +=
          _paintText(
            canvas,
            text,
            ui.Offset(18, y),
            size: heading == null ? 12 : (heading[1]!.length == 1 ? 20 : 16),
            bold: heading != null,
            maxLines: 5,
          ) +
          8;
    }
  }

  void _paintDatabase(ui.Canvas canvas, WorkspaceDatabase database) {
    final columns = database.properties.take(3).toList();
    if (columns.isEmpty) return;
    final columnWidth = (_width - 24) / columns.length;
    const rowHeight = 32.0;
    canvas.drawRect(
      const ui.Rect.fromLTWH(12, 18, _width - 24, rowHeight),
      ui.Paint()..color = const ui.Color(0xffe9f1ee),
    );
    for (var i = 0; i < columns.length; i++) {
      _paintText(
        canvas,
        columns[i].name,
        ui.Offset(17 + i * columnWidth, 25),
        width: columnWidth - 10,
        size: 11,
        bold: true,
        maxLines: 1,
      );
    }
    var y = 18 + rowHeight;
    for (final row in database.rows.where((row) => !row.archived).take(8)) {
      for (var i = 0; i < columns.length; i++) {
        final value = row.values[columns[i].id];
        final text = switch (value) {
          null => '',
          final bool value => value ? '✓' : '—',
          final List value => value.join(', '),
          _ => value.toString(),
        };
        _paintText(
          canvas,
          text,
          ui.Offset(17 + i * columnWidth, y + 7),
          width: columnWidth - 10,
          size: 10,
          maxLines: 1,
        );
      }
      canvas.drawLine(
        ui.Offset(12, y + rowHeight),
        ui.Offset(_width - 12, y + rowHeight),
        ui.Paint()..color = const ui.Color(0xffdce5e2),
      );
      y += rowHeight;
    }
    for (var i = 0; i <= columns.length; i++) {
      canvas.drawLine(
        ui.Offset(12 + i * columnWidth, 18),
        ui.Offset(12 + i * columnWidth, y),
        ui.Paint()..color = const ui.Color(0xffdce5e2),
      );
    }
  }

  double _fitBody(ui.Canvas canvas, ui.Rect bounds) {
    if (!bounds.left.isFinite ||
        !bounds.top.isFinite ||
        !bounds.width.isFinite ||
        !bounds.height.isFinite ||
        bounds.width <= 0 ||
        bounds.height <= 0 ||
        bounds.width > 1e9 ||
        bounds.height > 1e9)
      throw const FormatException('Invalid document bounds');
    final scale = math.min(
      (_width - 24) / bounds.width,
      (_maxHeight - 24) / bounds.height,
    );
    canvas.translate(
      (_width - bounds.width * scale) / 2,
      (_maxHeight - bounds.height * scale) / 2,
    );
    canvas.scale(scale);
    canvas.translate(-bounds.left, -bounds.top);
    return scale;
  }

  void _paintInfinite(ui.Canvas canvas, InfiniteDocument document) {
    if (document.strokes.isEmpty) return;
    if (document.strokes.length > 10000 ||
        document.strokes.fold<int>(
              0,
              (count, stroke) => count + stroke.points.length,
            ) >
            200000)
      throw const FormatException('Infinite cover resource limit');
    final bounds = document.strokes
        .map((stroke) => stroke.bounds)
        .reduce((a, b) => a.expandToInclude(b));
    final scale = _fitBody(canvas, bounds.inflate(12));
    for (final stroke in document.strokes) {
      final color = ui.Color(stroke.color);
      final paint = ui.Paint()
        ..color = stroke.tool == InfiniteInkTool.highlighter
            ? color.withValues(alpha: color.a * .35)
            : color
        ..style = ui.PaintingStyle.stroke
        ..strokeCap = ui.StrokeCap.round
        ..strokeJoin = ui.StrokeJoin.round
        ..strokeWidth = math.max(stroke.width, .7 / scale);
      if (stroke.points.length == 1) {
        canvas.drawCircle(
          stroke.points.first.offset,
          paint.strokeWidth / 2,
          paint..style = ui.PaintingStyle.fill,
        );
      } else {
        final path = ui.Path()
          ..moveTo(stroke.points.first.x, stroke.points.first.y);
        for (final point in stroke.points.skip(1)) {
          path.lineTo(point.x, point.y);
        }
        canvas.drawPath(path, paint);
      }
    }
  }

  void _paintCardCanvas(ui.Canvas canvas, CardCanvasDocument document) {
    if (document.nodes.isEmpty) return;
    if (document.nodes.length > 2000 || document.edges.length > 5000)
      throw const FormatException('Canvas cover resource limit');
    final bounds = document.nodes
        .map((node) => node.bounds)
        .reduce((a, b) => a.expandToInclude(b));
    final scale = _fitBody(canvas, bounds.inflate(10));
    final nodes = {for (final node in document.nodes) node.id: node};
    for (final edge in document.edges) {
      final from = nodes[edge.fromNode], to = nodes[edge.toNode];
      if (from != null && to != null)
        canvas.drawLine(
          from.bounds.center,
          to.bounds.center,
          ui.Paint()
            ..color = const ui.Color(0xff829b94)
            ..strokeWidth = 1.3 / scale,
        );
    }
    for (final node in document.nodes) {
      final rect = ui.RRect.fromRectAndRadius(
        node.bounds,
        const ui.Radius.circular(9),
      );
      canvas.drawRRect(rect, ui.Paint()..color = const ui.Color(0xfff4f8f5));
      canvas.drawRRect(
        rect,
        ui.Paint()
          ..color = const ui.Color(0xff7fa298)
          ..style = ui.PaintingStyle.stroke
          ..strokeWidth = 1 / scale,
      );
      canvas.save();
      canvas.clipRect(node.bounds.deflate(8));
      _paintText(
        canvas,
        node.text ??
            node.label ??
            node.file ??
            (node.type == 'link' ? node.toJson()['url'] as String : ''),
        node.bounds.topLeft + const ui.Offset(12, 12),
        width: math.max(1, node.width - 24),
        size: 16,
        maxLines: 12,
      );
      canvas.restore();
    }
  }

  Future<ui.Image?> _renderOffice(
    NoteRepository repository,
    VaultNote note,
    RevisionRecord revision,
    OfficePdfVariant? officePdf,
  ) async {
    const maxOfficeBytes = 128 * 1024 * 1024;
    if (revision.blobs.length > 3 ||
        revision.blobs.values.fold<int>(0, (sum, blob) => sum + blob.length) >
            maxOfficeBytes)
      return null;
    final documents = OfficeDocumentStore(repository);
    final edition = await documents.readLatest(
      note,
      revisionId: revision.revisionId,
    );
    if (_retired) return null;
    var bytes = officePdf == null
        ? edition.pdfBytes
        : await documents.readPdfVariantBytes(note, edition, officePdf);
    Directory? work;
    OfficePreviewResult? preview;
    try {
      if (_retired) return null;
      if (bytes == null) {
        await root.create(recursive: true);
        if (_retired) return null;
        work = await root.createTemp('.office-cover-');
        if (_retired) return null;
        final original = await File(p.join(work.path, edition.originalFileName))
            .writeAsBytes(edition.originalBytes, flush: true);
        if (_retired) return null;
        preview = await officePreviewEngine.preview(
          sourcePath: original.absolute.path,
          sessionId: 'cover-${newId()}',
        );
        if (_retired || preview == null) return null;
        final pdf = File(preview.pdfPath);
        if (p.equals(p.absolute(pdf.path), original.absolute.path) ||
            FileSystemEntity.typeSync(pdf.path, followLinks: false) !=
                FileSystemEntityType.file ||
            await pdf.length() > maxOfficeBytes)
          return null;
        bytes = await pdf.readAsBytes();
      }
      if (bytes.length < 10 ||
          bytes.length > maxOfficeBytes ||
          !ascii
              .decode(bytes.sublist(0, 5), allowInvalid: true)
              .startsWith('%PDF-'))
        return null;
      final document = await PdfDocument.openData(bytes);
      try {
        if (document.pages.isEmpty || document.pages.length > 10000)
          return null;
        final page = document.pages.first;
        await page.ensureLoaded();
        if (!page.width.isFinite ||
            !page.height.isFinite ||
            page.width <= 0 ||
            page.height <= 0)
          return null;
        final scale = math.min(_width / page.width, _maxHeight / page.height);
        final height = math.max(1, (page.height * scale).round());
        final width = math.max(1, (page.width * scale).round());
        final rendered = await page.render(
          width: width,
          height: height,
          fullWidth: width.toDouble(),
          fullHeight: height.toDouble(),
        );
        if (rendered == null) return null;
        try {
          final image = await rendered.createImage();
          try {
            final recorder = ui.PictureRecorder();
            final canvas = ui.Canvas(recorder)
              ..drawColor(const ui.Color(0xffffffff), ui.BlendMode.src);
            canvas.drawImage(
              image,
              ui.Offset((_width - width) / 2, 0),
              ui.Paint(),
            );
            final picture = recorder.endRecording();
            try {
              return await picture.toImage(_width, height);
            } finally {
              picture.dispose();
            }
          } finally {
            image.dispose();
          }
        } finally {
          rendered.dispose();
        }
      } finally {
        await document.dispose();
      }
    } finally {
      try {
        await preview?.dispose();
      } finally {
        if (work != null) {
          try {
            if (work.existsSync()) await work.delete(recursive: true);
          } catch (_) {}
        }
      }
    }
  }

  Future<void> _loadSnapshotImage(EditorImage source) async {
    if (source is PdfEditorImage) {
      final document = await source.assetCache.pdfDocumentCache.load(
        source.pdfFile?.path ?? 'inline_pdf_${source.id}.pdf',
        pdfBytes: source.pdfBytes,
      );
      final index = source.pdfPage;
      // Headless rendering has no viewer to start loading later pages.
      if (!document.pages[index].isLoaded) {
        await document.loadPagesProgressively<void>(
          onPageLoadProgress: (loaded, _, _) => loaded <= index,
        );
      }
      if (!document.pages[index].isLoaded) {
        throw const FormatException('PDF page did not load');
      }
    }
    // The second call waits for firstLoad to finish.
    await source.loadIn();
    await source.loadIn();
  }

  Future<PngEditorImage> _rasterizePdf(
    PdfEditorImage source, {
    int maxWidth = _width * 2,
    int maxHeight = _maxHeight * 2,
  }) async {
    final document = await source.assetCache.pdfDocumentCache.load(
      source.pdfFile?.path ?? 'inline_pdf_${source.id}.pdf',
      pdfBytes: source.pdfBytes,
    );
    final page = document.pages[source.pdfPage];
    if (!page.width.isFinite ||
        !page.height.isFinite ||
        page.width <= 0 ||
        page.height <= 0)
      throw const FormatException('Invalid PDF page size');
    final scale = math.min(maxWidth / page.width, maxHeight / page.height);
    final width = math.max(1, (page.width * scale).round());
    final height = math.max(1, (page.height * scale).round());
    final rendered = await page.render(
      width: width,
      height: height,
      fullWidth: width.toDouble(),
      fullHeight: height.toDouble(),
    );
    if (rendered == null)
      throw const FormatException('PDF thumbnail render failed');
    try {
      final image = await rendered.createImage();
      try {
        final encoded = await image.toByteData(format: ui.ImageByteFormat.png);
        if (encoded == null)
          throw const FormatException('PDF thumbnail encode failed');
        return PngEditorImage(
          id: source.id,
          assetCache: source.assetCache,
          extension: '.png',
          imageProvider: MemoryImage(
            encoded.buffer.asUint8List(
              encoded.offsetInBytes,
              encoded.lengthInBytes,
            ),
          ),
          pageIndex: source.pageIndex,
          pageSize: source.pageSize,
          naturalSize: ui.Size(width.toDouble(), height.toDouble()),
          srcRect: ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
          dstRect: source.dstRect,
          backgroundFit: source.backgroundFit,
          invertible: source.invertible,
          newImage: false,
          onMoveImage: null,
          onDeleteImage: null,
          onMiscChange: null,
        );
      } finally {
        image.dispose();
      }
    } finally {
      rendered.dispose();
    }
  }

  Future<bool> _validCachedFile(File file) async {
    try {
      if (_retired ||
          FileSystemEntity.typeSync(file.path, followLinks: false) !=
              FileSystemEntityType.file)
        return false;
      final length = await file.length();
      if (_retired || length < 33 || length > _maxPngBytes) return false;
      final bytes = await file.readAsBytes();
      if (_retired || !_validPngHeader(bytes)) return false;
      final codec = await ui.instantiateImageCodec(bytes);
      try {
        final frame = await codec.getNextFrame();
        try {
          return frame.image.width == _width &&
              frame.image.height > 0 &&
              frame.image.height <= _maxHeight;
        } finally {
          frame.image.dispose();
        }
      } finally {
        codec.dispose();
      }
    } catch (_) {
      return false;
    }
  }

  Future<bool> _validSnapshot(
    NoteRepository repository,
    RevisionRecord revision,
  ) async {
    final bodyRef = revision.blobs['main.sbn2'];
    if (bodyRef == null ||
        bodyRef.length < 5 ||
        bodyRef.length > _maxBodyBytes ||
        revision.blobs.length > 256)
      return false;
    var total = 0;
    for (final entry in revision.blobs.entries) {
      if (!RegExp(r'^main\.sbn2(?:\.[0-9]+)?$').hasMatch(entry.key) ||
          entry.value.length > _maxAssetBytes)
        return false;
      total += entry.value.length;
      if (total > _maxSnapshotBytes) return false;
    }
    final files = await repository.readFiles(revision);
    final body = files['main.sbn2']!;
    if (ByteData.sublistView(body).getUint32(0, Endian.little) != body.length ||
        body.last != 0)
      return false;
    for (final entry in files.entries) {
      if (entry.key != 'main.sbn2' && !_safeRasterHeader(entry.value))
        return false;
    }
    return true;
  }

  bool _validPngHeader(Uint8List bytes) {
    if (bytes.length < 33 || !_isPng(bytes)) return false;
    final data = ByteData.sublistView(bytes);
    return data.getUint32(8) == 13 &&
        data.getUint32(12) == 0x49484452 &&
        data.getUint32(16) == _width &&
        data.getUint32(20) > 0 &&
        data.getUint32(20) <= _maxHeight;
  }

  bool _isPng(Uint8List bytes) {
    const signature = [137, 80, 78, 71, 13, 10, 26, 10];
    if (bytes.length < signature.length) return false;
    for (var i = 0; i < signature.length; i++) {
      if (bytes[i] != signature[i]) return false;
    }
    return true;
  }

  bool _safeRasterHeader(Uint8List bytes) {
    if (_isPng(bytes)) {
      if (bytes.length < 33) return false;
      final data = ByteData.sublistView(bytes);
      final width = data.getUint32(16);
      final height = data.getUint32(20);
      return data.getUint32(8) == 13 &&
          data.getUint32(12) == 0x49484452 &&
          width > 0 &&
          height > 0 &&
          width * height <= 40000000;
    }
    if (bytes.length >= 2 && bytes[0] == 0xff && bytes[1] == 0xd8) {
      var offset = 2;
      final limit = math.min(bytes.length, 65536);
      while (offset + 3 < limit) {
        if (bytes[offset] != 0xff) return false;
        while (offset < limit && bytes[offset] == 0xff) {
          offset++;
        }
        if (offset >= limit) return false;
        final marker = bytes[offset++];
        if (marker == 0xd9 || marker == 0xda) return false;
        if (marker == 0x01 || (marker >= 0xd0 && marker <= 0xd7)) continue;
        if (offset + 2 > limit) return false;
        final length = (bytes[offset] << 8) | bytes[offset + 1];
        if (length < 2 || offset + length > limit) return false;
        if ((marker >= 0xc0 && marker <= 0xc3) ||
            (marker >= 0xc5 && marker <= 0xc7) ||
            (marker >= 0xc9 && marker <= 0xcb) ||
            (marker >= 0xcd && marker <= 0xcf)) {
          if (length < 7) return false;
          final height = (bytes[offset + 3] << 8) | bytes[offset + 4];
          final width = (bytes[offset + 5] << 8) | bytes[offset + 6];
          return width > 0 && height > 0 && width * height <= 40000000;
        }
        offset += length;
      }
      return false;
    }
    return true;
  }
}

class _PinnedImage {
  final ImageStream stream;
  final ready = Completer<void>();
  late final ImageStreamListener listener;
  ImageInfo? image;

  new(this.stream) {
    listener = ImageStreamListener(
      (info, synchronous) {
        image?.dispose();
        image = info;
        if (!ready.isCompleted) ready.complete();
      },
      onError: (Object error, StackTrace? stack) {
        if (!ready.isCompleted) ready.completeError(error, stack);
      },
    );
    stream.addListener(listener);
  }

  static Future<_PinnedImage> load(ImageProvider provider) async {
    final pinned = _PinnedImage(provider.resolve(ImageConfiguration.empty));
    try {
      await pinned.ready.future;
      return pinned;
    } catch (_) {
      pinned.dispose();
      rethrow;
    }
  }

  void dispose() {
    stream.removeListener(listener);
    image?.dispose();
    image = null;
  }
}
