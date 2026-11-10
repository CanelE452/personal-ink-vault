import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:saber/components/canvas/image/editor_image.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/vault/workspace_store.dart';

typedef PdfPageDestination = ({String pageId, PdfEditorImage background});

class PdfTextSearchHit {
  final int pageNumber;
  final PdfPageDestination destination;
  final String snippet;

  const new({
    required this.pageNumber,
    required this.destination,
    required this.snippet,
  });

  String get pageId => destination.pageId;
}

class PdfTextSearchResult {
  final List<PdfTextSearchHit> hits;
  final bool hasText;
  final bool truncated;
  final bool unavailable;

  const new({
    this.hits = const [],
    this.hasText = false,
    this.truncated = false,
    this.unavailable = false,
  });
}

class PdfImportMarker {
  static const fileName = 'pdf-import.json';
  final String vaultId;
  final String noteId;
  final String sourceEntityId;
  final String sourceRevisionId;
  final String sourceSha256;

  const new({
    required this.vaultId,
    required this.noteId,
    required this.sourceEntityId,
    required this.sourceRevisionId,
    required this.sourceSha256,
  });

  factory fromBytes(Uint8List bytes) {
    if (bytes.length > 2048)
      throw const FormatException('Invalid PDF import marker');
    final json = jsonObject(jsonDecode(utf8.decode(bytes)));
    String id(String key) {
      final value = json[key];
      if (value is! String)
        throw const FormatException('Invalid PDF import marker');
      validateId(value);
      return value;
    }

    final hash = json['sourceSha256'];
    if (json['version'] != 1 ||
        hash is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash))
      throw const FormatException('Invalid PDF import marker');
    return PdfImportMarker(
      vaultId: id('vaultId'),
      noteId: id('noteId'),
      sourceEntityId: id('sourceEntityId'),
      sourceRevisionId: id('sourceRevisionId'),
      sourceSha256: hash,
    );
  }

  Uint8List encode() => Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'version': 1,
        'vaultId': vaultId,
        'noteId': noteId,
        'sourceEntityId': sourceEntityId,
        'sourceRevisionId': sourceRevisionId,
        'sourceSha256': sourceSha256,
      }),
    ),
  );
}

class PdfImportPreparation {
  final String signature;
  final PdfImportMarker? marker;
  final String? path;
  final String? message;
  final bool complete;
  final bool peerPreview;
  const new _(
    this.signature, {
    this.marker,
    this.path,
    this.message,
    this.complete = false,
    this.peerPreview = false,
  });

  PdfImportPreparation completed() =>
      PdfImportPreparation._(signature, marker: marker, complete: true);

  static bool applies(NoteSession session) =>
      session.note.documentKind == VaultDocumentKind.pdf &&
      session.note.sourceEntityId != null;

  static String _signature(NoteSession session, List<RevisionRecord> heads) =>
      '${session.note.revision.revisionId}/${(heads.map((r) => r.revisionId).toList()..sort()).join(',')}/${(List.of(session.inkParents)..sort()).join(',')}';

  static Future<String> signatureFor(NoteSession session) async => _signature(
    session,
    await session.repository.heads(session.note.sourceEntityId!),
  );

  static Future<PdfImportPreparation> prepare(
    NoteSession session, {
    bool initializeHere = false,
  }) async {
    final repository = session.repository;
    final note = session.note;
    final heads = await repository.heads(note.sourceEntityId!);
    final signature = _signature(session, heads);
    PdfImportPreparation blocked(String message) =>
        PdfImportPreparation._(signature, message: message);
    try {
      if (note.trashed || note.deletionConflict)
        return blocked('문서의 삭제 또는 판본 충돌을 먼저 해결하세요. 원본은 보존됩니다.');
      if (heads.isEmpty) return blocked('PDF 원본을 아직 받지 못했습니다. 동기화 후 다시 시도하세요.');
      if (heads.length != 1 || heads.single.deleted)
        return blocked('PDF 원본의 판본이 충돌하거나 삭제되었습니다. 기존 원본과 필기는 보존됩니다.');
      final source = heads.single;
      if (source.vaultId != repository.vaultId ||
          source.entityId != note.sourceEntityId ||
          source.kind != EntityKind.attachment ||
          source.ownerNoteId != note.id ||
          source.blobs.length != 1 ||
          !source.blobs.keys.single.toLowerCase().endsWith('.pdf'))
        return blocked('이 문서에 연결된 PDF 원본을 확인할 수 없습니다. 원본은 보존됩니다.');
      final marker = PdfImportMarker(
        vaultId: repository.vaultId,
        noteId: note.id,
        sourceEntityId: source.entityId,
        sourceRevisionId: source.revisionId,
        sourceSha256: source.blobs.values.single.hash,
      );
      final fromPeer = source.deviceId != repository.deviceId;
      final peerPreview = fromPeer && !initializeHere;
      if (session.inkHeads.length > 1 ||
          session.inkHeads.any((head) => head.deleted))
        return blocked('PDF 필기의 판본 충돌을 먼저 해결하세요. 원본과 모든 필기는 보존됩니다.');
      if (session.inkParents.isNotEmpty) {
        final revisions = await repository.revisions();
        final ink = revisions
            .where((r) => r.revisionId == session.inkParents.single)
            .single;
        if (ink.kind != EntityKind.ink ||
            ink.ownerNoteId != note.id ||
            ink.vaultId != repository.vaultId)
          return blocked('저장된 PDF 필기의 소유권을 확인할 수 없습니다.');
        final files = await repository.readFiles(ink);
        final savedMarker = files[PdfImportMarker.fileName];
        if (savedMarker != null) {
          final saved = PdfImportMarker.fromBytes(savedMarker);
          if (saved.vaultId != marker.vaultId ||
              saved.noteId != marker.noteId ||
              saved.sourceEntityId != marker.sourceEntityId ||
              saved.sourceRevisionId != marker.sourceRevisionId ||
              saved.sourceSha256 != marker.sourceSha256)
            return blocked('저장된 필기와 PDF 원본의 판본이 다릅니다. 기존 필기는 보존됩니다.');
          return PdfImportPreparation._(
            signature,
            marker: marker,
            complete: true,
          );
        }
        if (fromPeer &&
            ink.blobs.values.any((blob) => blob.hash == marker.sourceSha256)) {
          return PdfImportPreparation._(
            signature,
            marker: marker,
            peerPreview: peerPreview,
          );
        }
      }
      final files = await repository.readFiles(source);
      final bytes = files.values.single;
      if (bytes.isEmpty) return blocked('저장된 PDF 원본이 비어 있습니다.');
      final target = FileManager.getFile(
        '/.working/pdf-import/${note.id}/${source.revisionId}/original.pdf',
      );
      await target.parent.create(recursive: true);
      if (!target.existsSync() ||
          sha256.convert(await target.readAsBytes()).toString() !=
              marker.sourceSha256) {
        final pending = File('${target.path}.${newId()}.pending');
        try {
          await pending.writeAsBytes(bytes, flush: true);
          await pending.rename(target.path);
        } finally {
          if (pending.existsSync()) await pending.delete();
        }
      }
      return PdfImportPreparation._(
        signature,
        marker: marker,
        path: target.path,
        peerPreview: peerPreview,
      );
    } catch (_) {
      return blocked('저장된 PDF 원본이나 필기를 읽지 못했습니다. 원본을 보존한 채 다시 시도할 수 있습니다.');
    }
  }

  Future<void> validateCurrent(NoteSession session) async {
    final value = marker;
    if (value == null || message != null)
      throw StateError(message ?? 'PDF 원본을 확인하지 못했습니다.');
    final heads = await session.repository.heads(value.sourceEntityId);
    if (heads.length != 1 ||
        heads.single.deleted ||
        heads.single.revisionId != value.sourceRevisionId)
      throw StateError('저장 중 PDF 원본의 판본이 바뀌었습니다. 원본과 필기를 보존하고 다시 시도하세요.');
  }

  Future<PdfPageDestination?> findPage(EditorCoreInfo core, int number) async {
    final hash = marker?.sourceSha256;
    if (!complete || hash == null) return null;
    return findBoundPage(core, number, pdfSha256: hash, isCurrent: () => true);
  }

  static Future<PdfPageDestination?> findBoundPage(
    EditorCoreInfo core,
    int number, {
    required String pdfSha256,
    required bool Function() isCurrent,
  }) async {
    if (number < 1) return null;
    PdfPageDestination? match;
    await for (final page in _originalPages(
      core,
      pdfSha256,
      from: number,
      through: number,
      isCurrent: isCurrent,
    )) {
      if (match != null) return null;
      match = page.destination;
    }
    return isCurrent() ? match : null;
  }

  static Future<Map<int, PdfPageDestination>> findBoundPages(
    EditorCoreInfo core, {
    required String pdfSha256,
    required int pageCount,
    required bool Function() isCurrent,
  }) async {
    final matches = <int, PdfPageDestination>{};
    final ambiguous = <int>{};
    await for (final page in _originalPages(
      core,
      pdfSha256,
      through: pageCount,
      isCurrent: isCurrent,
    )) {
      if (ambiguous.contains(page.number)) continue;
      if (matches.remove(page.number) != null) {
        ambiguous.add(page.number);
      } else {
        matches[page.number] = page.destination;
      }
    }
    return isCurrent() ? matches : const {};
  }

  static const _maxSearchBytes = 64 * 1024 * 1024;
  static const _maxSearchPages = 1000;
  static const _maxSearchHits = 80;
  static const _maxPageText = 250000;
  static final _whitespace = RegExp(r'\s+', unicode: true);

  Future<PdfTextSearchResult> searchText(
    EditorCoreInfo core,
    String query, {
    required bool Function() isCurrent,
  }) async {
    if (!isCurrent()) return const PdfTextSearchResult();
    final hash = marker?.sourceSha256;
    if (!complete || hash == null) {
      return const PdfTextSearchResult(unavailable: true);
    }
    return searchBoundPdfText(
      core,
      query,
      pdfSha256: hash,
      isCurrent: isCurrent,
    );
  }

  static Future<PdfTextSearchResult> searchBoundPdfText(
    EditorCoreInfo core,
    String query, {
    required String pdfSha256,
    required bool Function() isCurrent,
  }) async {
    const empty = PdfTextSearchResult();
    const unavailable = PdfTextSearchResult(unavailable: true);
    if (!isCurrent()) return empty;
    if (query.length > 160) return unavailable;
    final normalized = query.replaceAll(_whitespace, '');
    if (normalized.isEmpty) return empty;
    final pattern = RegExp(
      normalized.runes
          .map((rune) => RegExp.escape(String.fromCharCode(rune)))
          .join(r'\s*'),
      caseSensitive: false,
      unicode: true,
    );

    try {
      final destinations = <int, PdfPageDestination>{};
      final ambiguous = <int>{};
      await for (final page in _originalPages(
        core,
        pdfSha256,
        through: _maxSearchPages,
        maxBytes: _maxSearchBytes,
        isCurrent: isCurrent,
      )) {
        if (ambiguous.contains(page.number)) continue;
        if (destinations.remove(page.number) != null) {
          ambiguous.add(page.number);
        } else {
          destinations[page.number] = page.destination;
        }
      }
      if (!isCurrent()) return empty;
      if (destinations.isEmpty) {
        return ambiguous.isEmpty
            ? unavailable
            : const PdfTextSearchResult(truncated: true);
      }
      final bytes = await _readSearchBytes(
        destinations.values.first.background,
        pdfSha256,
        isCurrent,
      );
      if (!isCurrent()) return empty;
      if (bytes == null) return unavailable;

      final document = await PdfDocument.openData(bytes);
      final PdfTextSearchResult result;
      try {
        final hits = <PdfTextSearchHit>[];
        var hasText = false;
        var truncated = document.pages.length > _maxSearchPages;
        final pageLimit = math.min(document.pages.length, _maxSearchPages);
        for (var number = 1; number <= pageLimit; number++) {
          if (!isCurrent()) return empty;
          final destination = destinations[number];
          if (destination == null) {
            truncated = true;
            continue;
          }
          final page = await document.pages[number - 1].ensureLoaded();
          if (!isCurrent()) return empty;
          final raw = (await page.loadText())?.fullText;
          if (!isCurrent()) return empty;
          if (raw == null) return unavailable;
          final text = raw.length > _maxPageText
              ? raw.substring(0, _maxPageText)
              : raw;
          truncated = truncated || raw.length > text.length;
          if (text.trim().isEmpty) continue;
          hasText = true;
          final match = pattern.firstMatch(text);
          if (match == null) continue;
          if (hits.length == _maxSearchHits) {
            truncated = true;
            break;
          }
          hits.add(
            PdfTextSearchHit(
              pageNumber: number,
              destination: destination,
              snippet: _snippet(text, match),
            ),
          );
        }
        result = PdfTextSearchResult(
          hits: List.unmodifiable(hits),
          hasText: hasText,
          truncated: truncated,
        );
      } finally {
        await document.dispose();
      }
      return isCurrent() ? result : empty;
    } catch (_) {
      return isCurrent() ? unavailable : empty;
    }
  }

  static String _snippet(String text, Match match) {
    var start = math.max(0, match.start - 55);
    var end = math.min(text.length, match.end + 75);
    bool lowSurrogateAt(int offset) {
      final code = text.codeUnitAt(offset);
      return code >= 0xdc00 && code <= 0xdfff;
    }

    if (start > 0 && lowSurrogateAt(start)) start--;
    if (end < text.length && lowSurrogateAt(end)) end++;
    final snippet = text
        .substring(start, end)
        .replaceAll(_whitespace, ' ')
        .trim();
    return '${start == 0 ? '' : '…'}$snippet${end == text.length ? '' : '…'}';
  }

  static Future<Uint8List?> _readSearchBytes(
    PdfEditorImage image,
    String hash,
    bool Function() isCurrent,
  ) async {
    final Uint8List bytes;
    final inline = image.pdfBytes;
    if (inline != null) {
      if (inline.length > _maxSearchBytes) return null;
      bytes = Uint8List.fromList(inline);
    } else {
      final file = image.pdfFile;
      if (file == null) return null;
      final buffer = BytesBuilder(copy: false);
      await for (final chunk in file.openRead()) {
        if (!isCurrent() || buffer.length + chunk.length > _maxSearchBytes) {
          return null;
        }
        buffer.add(chunk);
      }
      bytes = buffer.takeBytes();
    }
    if (!isCurrent() || sha256.convert(bytes).toString() != hash) {
      return null;
    }
    return bytes;
  }

  static Stream<({int number, PdfPageDestination destination})> _originalPages(
    EditorCoreInfo core,
    String hash, {
    int from = 1,
    required int through,
    int? maxBytes,
    required bool Function() isCurrent,
  }) async* {
    final matchesByPath = <String, bool>{};
    final matchesByBytes = Map<Uint8List, bool>.identity();
    Future<bool> matchesOriginal(PdfEditorImage image) async {
      final bytes = image.pdfBytes;
      if (bytes != null) {
        return matchesByBytes.putIfAbsent(
          bytes,
          () =>
              (maxBytes == null || bytes.length <= maxBytes) &&
              sha256.convert(bytes).toString() == hash,
        );
      }
      final file = image.pdfFile;
      if (file == null) return false;
      final cached = matchesByPath[file.path];
      if (cached != null) return cached;
      try {
        if (maxBytes != null && await file.length() > maxBytes) {
          return matchesByPath[file.path] = false;
        }
        if (!isCurrent()) return false;
        final digest = await sha256
            .bind(file.openRead().takeWhile((_) => isCurrent()))
            .single;
        return matchesByPath[file.path] =
            isCurrent() && digest.toString() == hash;
      } on FileSystemException {
        return matchesByPath[file.path] = false;
      }
    }

    for (final page in List.of(core.pages)) {
      if (!isCurrent()) return;
      final image = page.backgroundImage;
      if (image is! PdfEditorImage) continue;
      final number = image.pdfPage + 1;
      if (number < from || number > through) continue;
      if (!await matchesOriginal(image)) continue;
      if (!isCurrent()) return;
      yield (
        number: number,
        destination: (pageId: page.pageId, background: image),
      );
    }
  }
}
