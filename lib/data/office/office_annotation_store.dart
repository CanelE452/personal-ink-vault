import 'dart:typed_data';

import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/editor/editor_core_info.dart';
import 'package:saber/data/office/office_document_store.dart';
import 'package:saber/data/vault/saber_ink_adapter.dart';
import 'package:saber/data/vault/workspace_store.dart';

class OfficeAnnotationStore {
  final NoteRepository repository;
  const new(this.repository);

  Future<OfficeAnnotationSession> open(
    VaultNote note,
    OfficeEdition edition, {
    String? revisionId,
    OfficePdfVariant? preview,
  }) async {
    if (edition.revision.vaultId != repository.vaultId ||
        edition.revision.entityId != note.sourceEntityId ||
        edition.revision.ownerNoteId != note.id ||
        edition.revision.kind != EntityKind.attachment)
      throw const FormatException('Foreign Office edition');
    final documents = OfficeDocumentStore(repository);
    final verified = await documents.readLatest(
      note,
      revisionId: edition.revision.revisionId,
    );
    final binding = preview?.bindingId ?? verified.bindingId;
    if (binding == null) {
      throw const FormatException('Office edition has no bound PDF');
    }
    if (preview == null) {
      if (verified.pdfBytes == null || binding != edition.bindingId) {
        throw const FormatException('Office edition has no bound PDF');
      }
    } else {
      final variants = await documents.readPdfVariants(note, verified);
      if (preview.revision.vaultId != repository.vaultId ||
          preview.sourceRevisionId != verified.revision.revisionId ||
          !variants.any(
            (candidate) =>
                candidate.bindingId == binding &&
                candidate.revision.revisionId == preview.revision.revisionId,
          )) {
        throw const FormatException('Office PDF is not bound to this original');
      }
    }
    final heads = await repository.heads(binding);
    RevisionRecord? selected;
    if (revisionId != null) {
      validateId(revisionId);
      final matches = (await repository.revisions()).where(
        (record) =>
            record.entityId == binding && record.revisionId == revisionId,
      );
      if (matches.length != 1)
        throw StateError('Office annotation revision not found');
      selected = matches.single;
    } else {
      if (heads.length > 1)
        throw StateError(
          'Select an Office annotation branch before opening it',
        );
      selected = heads.singleOrNull;
    }
    if (selected != null &&
        (selected.vaultId != repository.vaultId ||
            selected.ownerNoteId != note.id ||
            selected.kind != EntityKind.ink ||
            selected.deleted))
      throw const FormatException('Foreign or deleted Office annotation');
    return OfficeAnnotationSession._(
      repository,
      note.id,
      verified.revision.revisionId,
      binding,
      selected,
    );
  }
}

class OfficeAnnotationSession {
  final String bindingId;
  final NoteRepository _repository;
  final String noteId;
  final String editionRevisionId;
  List<String> _parents;
  RevisionRecord? _revision;
  Future<void> _tail = Future.value();
  new _(
    this._repository,
    this.noteId,
    this.editionRevisionId,
    this.bindingId,
    this._revision,
  ) : _parents = _revision == null ? [] : [_revision.revisionId];
  List<String> get parentRevisionIds => List.unmodifiable(_parents);
  RevisionRecord? get revision => _revision;
  String get workingPath =>
      '/.working/office/$noteId/$editionRevisionId/annotations/$bindingId/main';

  Future<EditorCoreInfo> load() async {
    final selected = _revision;
    if (selected == null) return EditorCoreInfo(filePath: workingPath);
    return SaberInkAdapter.load(_repository, selected);
  }

  Future<RevisionRecord> saveFiles(Map<String, Uint8List> files) async =>
      _serialize(() async {
        if (!files.containsKey('main.sbn2') ||
            files.keys.any(
              (name) => !RegExp(r'^main\.sbn2(?:\.[0-9]+)?$').hasMatch(name),
            ))
          throw const FormatException(
            'Expected a standard Saber annotation snapshot',
          );
        final record = await _repository.commit(
          entityId: bindingId,
          kind: EntityKind.ink,
          ownerNoteId: noteId,
          files: files,
          parentRevisionIds: _parents,
        );
        _revision = record;
        _parents = [record.revisionId];
        return record;
      });
  Future<void> saveSnapshot(EditorCoreInfo core, int pageIndex) async =>
      _serialize(() async {
        final files = await SaberInkAdapter.capture(core, pageIndex);
        final record = await _repository.commit(
          entityId: bindingId,
          kind: EntityKind.ink,
          ownerNoteId: noteId,
          files: files,
          parentRevisionIds: _parents,
        );
        _revision = record;
        _parents = [record.revisionId];
      });

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final result = _tail.then((_) => operation());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> flush() => _tail;
}
