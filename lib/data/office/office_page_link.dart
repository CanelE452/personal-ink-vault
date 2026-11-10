import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/office/office_annotation_store.dart';
import 'package:saber/data/office/office_document_store.dart';
import 'package:saber/data/vault/note_link.dart';
import 'package:saber/data/vault/workspace_store.dart';

class OfficePageLinkException implements Exception {
  const new(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => message;
}

class OfficePageLinkSelection {
  new _({
    required this.repository,
    required this.note,
    required this.target,
    required this.edition,
    required this.variants,
    required this.preview,
    required Uint8List bytes,
    required this.annotation,
  }) : bytes = bytes.asUnmodifiableView(),
       _annotationRevisionId = annotation.revision?.revisionId;

  final NoteRepository repository;
  final VaultNote note;
  final OfficePageTarget target;
  final OfficeEdition edition;
  final List<OfficePdfVariant> variants;
  final OfficePdfVariant preview;
  final Uint8List bytes;
  final OfficeAnnotationSession annotation;
  final String? _annotationRevisionId;
}

String officePdfBaselinePageId(String bindingId, int pageIndex) {
  final hash = sha256
      .convert(utf8.encode('office-pdf-baseline-v1:$bindingId:$pageIndex'))
      .bytes
      .take(16)
      .toList();
  hash[6] = (hash[6] & 0x0f) | 0x80;
  hash[8] = (hash[8] & 0x3f) | 0x80;
  final hex = hash.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

Future<OfficePageLinkSelection> resolveOfficePageLink({
  required NoteRepository repository,
  required String noteId,
  required OfficePageTarget target,
}) async {
  validateId(noteId);
  validateId(target.sourceRevisionId);
  validateId(target.pdfBindingId);
  validateId(target.pageId);
  final note = await _readLiveOfficeNote(repository, noteId);
  final source = (await repository.revisions())
      .where((record) => record.revisionId == target.sourceRevisionId)
      .singleOrNull;
  if (source == null || source.deleted) {
    throw const OfficePageLinkException(
      'not_found',
      '페이지 링크의 Office 원본 판본을 찾을 수 없습니다.',
    );
  }
  if (source.vaultId != repository.vaultId ||
      source.kind != EntityKind.attachment ||
      source.ownerNoteId != note.id ||
      source.entityId != note.sourceEntityId) {
    throw const OfficePageLinkException(
      'office_source_mismatch',
      '페이지 링크의 원본 판본이 이 Office 문서에 속하지 않습니다.',
    );
  }
  final documents = OfficeDocumentStore(repository);
  final edition = await documents.readLatest(
    note,
    revisionId: target.sourceRevisionId,
  );
  final variants = await documents.readPdfVariants(note, edition);
  final preview = variants
      .where((variant) => variant.bindingId == target.pdfBindingId)
      .singleOrNull;
  if (preview == null) {
    throw const OfficePageLinkException(
      'office_source_mismatch',
      '페이지 링크의 PDF 필기 버전을 찾을 수 없습니다.',
    );
  }
  final bytes = await documents.readPdfVariantBytes(note, edition, preview);
  final before = await _readAnnotationHead(
    repository,
    noteId,
    preview.bindingId,
  );
  final OfficeAnnotationSession annotation;
  try {
    annotation = await OfficeAnnotationStore(repository)
        .open(note, edition, preview: preview);
  } on StateError {
    await _requireAnnotationHead(
      repository,
      noteId,
      preview.bindingId,
      before?.revisionId,
    );
    rethrow;
  }
  if (annotation.revision?.revisionId != before?.revisionId) {
    throw _annotationChanged;
  }
  final selection = OfficePageLinkSelection._(
    repository: repository,
    note: note,
    target: target,
    edition: edition,
    variants: variants,
    preview: preview,
    bytes: bytes,
    annotation: annotation,
  );
  await verifyOfficePageLinkSelection(selection);
  return selection;
}

Future<void> verifyOfficePageLinkSelection(
  OfficePageLinkSelection selection,
) async {
  final repository = selection.repository;
  final observedRevisionIds = (await repository.revisions())
      .map((revision) => revision.revisionId)
      .toSet();
  final note = await _readLiveOfficeNote(repository, selection.note.id);
  final variants = await OfficeDocumentStore(repository)
      .readPdfVariants(note, selection.edition);
  final preview = variants
      .where((variant) => variant.bindingId == selection.target.pdfBindingId)
      .singleOrNull;
  if (preview?.revision.revisionId != selection.preview.revision.revisionId ||
      preview?.pdfSha256 != selection.preview.pdfSha256) {
    throw const OfficePageLinkException(
      'revision_conflict',
      '페이지 링크의 PDF 필기 버전이 변경됐습니다.',
    );
  }
  await _requireAnnotationHead(
    repository,
    note.id,
    selection.preview.bindingId,
    selection._annotationRevisionId,
  );
  // Note, PDF and ink are checked by separate reads. They must describe the
  // same repository state, including a folder or note that was just trashed.
  final current = await repository.revisions();
  if (current.length != observedRevisionIds.length ||
      current.any(
        (revision) => !observedRevisionIds.contains(revision.revisionId),
      )) {
    throw const OfficePageLinkException(
      'revision_conflict',
      '페이지 링크를 확인하는 동안 보관함이 변경됐습니다. 다시 시도하세요.',
    );
  }
}

Future<VaultNote> _readLiveOfficeNote(
  NoteRepository repository,
  String noteId,
) async {
  final notes = (await WorkspaceStore(repository).list(includeDeleted: true))
      .where((note) => note.id == noteId)
      .toList();
  if (notes.length > 1 || notes.singleOrNull?.deletionConflict == true) {
    throw const OfficePageLinkException(
      'revision_conflict',
      '페이지 링크의 Office 문서 판본이 여러 개 있습니다.',
    );
  }
  final note = notes.singleOrNull;
  if (note == null || note.trashed) {
    throw const OfficePageLinkException(
      'not_found',
      '페이지 링크의 Office 문서를 열 수 없습니다.',
    );
  }
  if (note.documentKind != VaultDocumentKind.office ||
      note.sourceEntityId == null) {
    throw const OfficePageLinkException(
      'office_source_mismatch',
      '페이지 링크의 Office 문서를 열 수 없습니다.',
    );
  }
  return note;
}

Future<RevisionRecord?> _readAnnotationHead(
  NoteRepository repository,
  String noteId,
  String bindingId,
) async {
  final heads = await repository.heads(bindingId);
  if (heads.length > 1) {
    throw const OfficePageLinkException(
      'revision_conflict',
      '페이지 링크의 필기 판본이 여러 개 있습니다.',
    );
  }
  final head = heads.singleOrNull;
  if (head != null &&
      (head.vaultId != repository.vaultId ||
          head.ownerNoteId != noteId ||
          head.kind != EntityKind.ink ||
          head.deleted)) {
    throw const OfficePageLinkException(
      'office_source_mismatch',
      '페이지 링크의 필기 판본을 열 수 없습니다.',
    );
  }
  return head;
}

const _annotationChanged = OfficePageLinkException(
  'revision_conflict',
  '페이지 링크의 필기 판본이 변경됐습니다. 다시 시도하세요.',
);

Future<void> _requireAnnotationHead(
  NoteRepository repository,
  String noteId,
  String bindingId,
  String? expectedRevisionId,
) async {
  final head = await _readAnnotationHead(repository, noteId, bindingId);
  if (head?.revisionId != expectedRevisionId) throw _annotationChanged;
}
