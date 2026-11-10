import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/vault/workspace_store.dart';

class OfficeEdition {
  const new _({
    required this.revision,
    required this.originalFileName,
    required this.originalBytes,
    this.pdfBytes,
    this.bindingId,
    this.engineVersion,
    this.pageCount,
  });

  final RevisionRecord revision;
  final String originalFileName;
  final Uint8List originalBytes;
  final Uint8List? pdfBytes;
  final String? bindingId;
  final String? engineVersion;
  final int? pageCount;
  String get originalSha256 => revision.blobs[originalFileName]!.hash;
  String? get pdfSha256 => revision.blobs['preview.pdf']?.hash;
  OfficeEditionSummary get summary => OfficeEditionSummary._(
    revision,
    hasPairedPdf: pdfBytes != null,
    pageCount: pageCount,
  );
}

/// History labels. The original and PDF still need validation when selected.
class OfficeEditionSummary {
  const new _(
    this.revision, {
    required this.hasPairedPdf,
    this.pageCount,
    this.metadataUnavailable = false,
  });

  final RevisionRecord revision;
  final bool hasPairedPdf;
  final int? pageCount;
  final bool metadataUnavailable;
}

/// An immutable PDF for one original revision. Legacy paired editions retain
/// their original revision and annotation binding.
class OfficePdfVariant {
  const new _(
    this.revision,
    this.sourceRevisionId,
    this.bindingId,
    this.pageCount,
  );

  final RevisionRecord revision;
  final String sourceRevisionId;
  final String bindingId;
  final int? pageCount;
  String get pdfSha256 => revision.blobs['preview.pdf']!.hash;
}

class OfficeEditSession {
  const new _(
    this._repositoryScope, {
    required this.note,
    required this.sourceEntityId,
    required this.sourceRevision,
    required this.parentRevisionIds,
    required this.originalFileName,
    required this.originalBytes,
  });

  final VaultNote note;
  final String sourceEntityId;
  final RevisionRecord sourceRevision;
  final List<String> parentRevisionIds;
  final String originalFileName;
  final Uint8List originalBytes;
  final (String, String, String, int) _repositoryScope;

  /// Contains no bytes or authentication. The caller must bind this descriptor
  /// to its durable operation receipt before recovering it in another process.
  Map<String, Object?> toRecoveryDescriptor() => {
    'version': 1,
    'rootUri': _repositoryScope.$1,
    'vaultId': _repositoryScope.$2,
    'deviceId': _repositoryScope.$3,
    'formatVersion': _repositoryScope.$4,
    'noteId': note.id,
    'noteRevisionId': note.revision.revisionId,
    'sourceEntityId': sourceEntityId,
    'sourceRevisionId': sourceRevision.revisionId,
    'parentRevisionIds': List.of(parentRevisionIds),
    'originalFileName': originalFileName,
    'originalSha256': sourceRevision.blobs[originalFileName]!.hash,
  };
}

/// Verified historical facts for retaining files. This does not authorize
/// resuming an editor or publishing an edition against the current note.
class OfficeRecoverySource {
  new _(OfficeEditSession session)
    : noteId = session.note.id,
      noteRevisionId = session.note.revision.revisionId,
      sourceEntityId = session.sourceEntityId,
      sourceRevisionId = session.sourceRevision.revisionId,
      parentRevisionIds = List.unmodifiable(session.parentRevisionIds),
      originalFileName = session.originalFileName,
      originalSha256 =
          session.sourceRevision.blobs[session.originalFileName]!.hash,
      originalLength = session.originalBytes.length;

  final String noteId;
  final String noteRevisionId;
  final String sourceEntityId;
  final String sourceRevisionId;
  final List<String> parentRevisionIds;
  final String originalFileName;
  final String originalSha256;
  final int originalLength;
}

/// One original/PDF publication. Retain the token, or persist its descriptor and
/// exact files before publication, to retry the same edition and binding.
final class OfficePreparedEdition {
  new _(
    this._session,
    this._prepared,
    this._edition,
    this._requireCurrentHeads,
    this._beforePublish,
    Map<String, Uint8List> files,
  ) : _files = Map.unmodifiable(
        files.map((name, bytes) => MapEntry(name, bytes.asUnmodifiableView())),
      );

  final OfficeEditSession _session;
  final PreparedCommit _prepared;
  final OfficeEdition _edition;
  final bool _requireCurrentHeads;
  final void Function()? _beforePublish;
  final Map<String, Uint8List> _files;

  /// The descriptor does not authenticate its association with a native result
  /// or its publication policy. The durable receipt must preserve that binding.
  Map<String, Object?> toRecoveryDescriptor() => {
    'version': 1,
    'noteRevisionId': _session.note.revision.revisionId,
    'sourceRevisionId': _session.sourceRevision.revisionId,
    'requireCurrentHeads': _requireCurrentHeads,
    'prepared': _prepared.toRecoveryDescriptor(),
  };

  Map<String, Uint8List> copyRecoveryFiles() => {
    for (final entry in _files.entries)
      entry.key: Uint8List.fromList(entry.value),
  };
}

class OfficeDocumentStore {
  const new(this.repository);
  final NoteRepository repository;
  static const supportedExtensions = [
    'doc',
    'docx',
    'ppt',
    'pptx',
    'odt',
    'odp',
    'hwp',
    'hwpx',
  ];

  Future<VaultNote> importDocument({
    required String title,
    required String fileName,
    required Uint8List bytes,
    String? folderId,
    bool fromObsidian = false,
    String? sharedRequestId,
  }) async {
    final extension = _validateFileName(fileName);
    if (bytes.isEmpty) throw const FormatException('Empty Office original');
    if (sharedRequestId != null && !_hasOfficeSignature(extension, bytes)) {
      throw const FormatException('공유 파일의 문서 형식을 확인할 수 없습니다.');
    }
    final original = Uint8List.fromList(bytes);
    final workspace = WorkspaceStore(repository);
    return workspace.createWithSource(
      title,
      fileName: fileName,
      bytes: original,
      folderId: folderId,
      documentKind: VaultDocumentKind.office,
      fromObsidian: fromObsidian,
      sharedRequestId: sharedRequestId,
    );
  }

  Future<VaultNote> createConvertedCopy(
    OfficeEditSession session, {
    required Uint8List originalBytes,
    required Uint8List pdfBytes,
    required String engineVersion,
    required int pageCount,
    void Function()? beforePublish,
  }) async {
    _validateSession(session);
    final legacyExtension = _validateFileName(session.originalFileName);
    final extension = switch (legacyExtension) {
      'doc' => 'docx',
      'ppt' => 'pptx',
      _ => throw const FormatException('Expected a DOC or PPT original'),
    };
    if (!_hasOfficeSignature(legacyExtension, session.originalBytes)) {
      throw const FormatException('Invalid legacy Office container');
    }
    final separator = session.originalFileName.lastIndexOf('.');
    final fileName =
        '${session.originalFileName.substring(0, separator)}.$extension';
    final original = Uint8List.fromList(originalBytes);
    final pdf = Uint8List.fromList(pdfBytes);
    _validateEditedOriginal(fileName, original);
    _validatePdf(pdf, pageCount);
    final version = engineVersion.trim();
    if (version.isEmpty) {
      throw const FormatException('Missing Office engine identity');
    }
    final bindingId = newId();
    return WorkspaceStore(repository).createOfficeCopy(
      '${session.note.title} (편집용)',
      originalNote: session.note,
      originalSource: session.sourceRevision,
      fileName: fileName,
      buildSourceFiles: (sourceEntityId) => {
        fileName: original,
        'preview.pdf': pdf,
        'edition.json': _encodeEditionMetadata(
          sourceEntityId: sourceEntityId,
          bindingId: bindingId,
          fileName: fileName,
          original: original,
          pdf: pdf,
          engineVersion: version,
          pageCount: pageCount,
        ),
      },
      beforePublish: beforePublish,
    );
  }

  Future<OfficeEditSession> beginEdit(
    VaultNote note, {
    String? revisionId,
  }) async {
    final edition = await readLatest(note, revisionId: revisionId);
    return OfficeEditSession._(
      _repositoryScope,
      note: note,
      sourceEntityId: edition.revision.entityId,
      sourceRevision: edition.revision,
      parentRevisionIds: List.unmodifiable([edition.revision.revisionId]),
      originalFileName: edition.originalFileName,
      originalBytes: edition.originalBytes,
    );
  }

  Future<OfficeEditSession> resumeEditSession(
    VaultNote note, {
    required Map<String, dynamic> descriptor,
  }) => _readSessionRecovery(note, descriptor, requireCurrentAssociation: true);

  Future<OfficeRecoverySource> readRecoverySource(
    VaultNote note, {
    required Map<String, dynamic> descriptor,
  }) async => OfficeRecoverySource._(
    await _readSessionRecovery(
      note,
      descriptor,
      requireCurrentAssociation: false,
    ),
  );

  Future<OfficeEditSession> _readSessionRecovery(
    VaultNote note,
    Map<String, dynamic> descriptor, {
    required bool requireCurrentAssociation,
  }) async {
    final json = _copyRecoveryJson(descriptor);
    _requireRecoveryKeys(json, const {
      'version',
      'rootUri',
      'vaultId',
      'deviceId',
      'formatVersion',
      'noteId',
      'noteRevisionId',
      'sourceEntityId',
      'sourceRevisionId',
      'parentRevisionIds',
      'originalFileName',
      'originalSha256',
    });
    if (json['version'] is! int ||
        json['version'] != 1 ||
        json['formatVersion'] is! int ||
        (
              json['rootUri'],
              json['vaultId'],
              json['deviceId'],
              json['formatVersion'],
            ) !=
            _repositoryScope ||
        json['noteId'] != note.id ||
        note.revision.vaultId != repository.vaultId ||
        (requireCurrentAssociation &&
            json['sourceEntityId'] != _sourceEntity(note)))
      throw const FormatException('Foreign Office session recovery descriptor');
    final noteRevisionId = _recoveryId(json['noteRevisionId']);
    final sourceRevisionId = _recoveryId(json['sourceRevisionId']);
    final sourceEntityId = _recoveryId(json['sourceEntityId']);
    final parents = json['parentRevisionIds'];
    if (parents is! List ||
        parents.length != 1 ||
        parents.single != sourceRevisionId ||
        json['originalFileName'] is! String ||
        json['originalSha256'] is! String)
      throw const FormatException('Invalid Office session recovery binding');
    final fileName = json['originalFileName'] as String;
    _validateFileName(fileName);
    validateHash(json['originalSha256'] as String);
    final session = await _readCapturedSession(
      note,
      noteRevisionId,
      sourceRevisionId,
      historicalSourceEntityId: sourceEntityId,
      requireCurrentAssociation: requireCurrentAssociation,
    );
    if (session.originalFileName != fileName ||
        session.sourceRevision.blobs[fileName]?.hash != json['originalSha256'])
      throw const FormatException('Office recovery original binding mismatch');
    return session;
  }

  Future<OfficePreparedEdition> resumePreparedEdition(
    VaultNote note, {
    required Map<String, dynamic> descriptor,
    required Map<String, Uint8List> files,
    void Function()? beforePublish,
  }) async {
    final json = _copyRecoveryJson(descriptor);
    final copiedFiles = {
      for (final entry in files.entries)
        entry.key: Uint8List.fromList(entry.value),
    };
    _requireRecoveryKeys(json, const {
      'version',
      'noteRevisionId',
      'sourceRevisionId',
      'requireCurrentHeads',
      'prepared',
    });
    if (json['version'] is! int ||
        json['version'] != 1 ||
        json['requireCurrentHeads'] is! bool)
      throw const FormatException(
        'Invalid prepared Office recovery descriptor',
      );
    final noteRevisionId = _recoveryId(json['noteRevisionId']);
    final sourceRevisionId = _recoveryId(json['sourceRevisionId']);
    final session = await _readCapturedSession(
      note,
      noteRevisionId,
      sourceRevisionId,
    );
    final prepared = repository.resumePreparedCommit(
      descriptor: jsonObject(json['prepared']),
      files: copiedFiles,
    );
    final record = prepared.record;
    if (record.entityId != session.sourceEntityId ||
        record.ownerNoteId != note.id ||
        record.kind != EntityKind.attachment ||
        record.deleted ||
        record.baseRefs.isNotEmpty ||
        record.parentRevisionIds.length != 1 ||
        record.parentRevisionIds.single != sourceRevisionId ||
        copiedFiles.length != 3 ||
        !copiedFiles.containsKey('edition.json'))
      throw const FormatException('Invalid prepared Office recovery identity');
    final edition = _decodeEdition(session.note, record, copiedFiles);
    if (edition.originalFileName != session.originalFileName ||
        edition.bindingId == null ||
        edition.pdfBytes == null)
      throw const FormatException('Invalid prepared Office recovery files');
    return OfficePreparedEdition._(
      session,
      prepared,
      edition,
      json['requireCurrentHeads'] == true || beforePublish != null,
      beforePublish,
      copiedFiles,
    );
  }

  Future<OfficePdfVariant> commitDerivedPdf(
    OfficeEditSession session, {
    required Uint8List pdfBytes,
    required int pageCount,
  }) async {
    _validateSession(session);
    if (pdfBytes.length > _maxDerivedPdfBytes) {
      throw const FormatException('Derived Office PDF exceeds the size limit');
    }
    final pdf = Uint8List.fromList(pdfBytes);
    _validatePdf(pdf, pageCount);
    final source = await readLatest(
      session.note,
      revisionId: session.sourceRevision.revisionId,
    );
    if (!_sameRecord(source.revision, session.sourceRevision) ||
        source.pdfBytes != null) {
      throw const FormatException(
        'Expected the captured original without a PDF',
      );
    }
    final ref = BlobRef(
      hash: sha256.convert(pdf).toString(),
      length: pdf.length,
    );
    final variant = _derivedPdfVariant(source.revision, ref);
    await repository.importRevision(
      variant.revision,
      blobsByHash: {ref.hash: pdf},
    );
    final heads = await repository.heads(variant.revision.entityId);
    if (heads.length != 1 || !_sameRecord(heads.single, variant.revision)) {
      throw const FormatException('Derived Office PDF is no longer available');
    }
    return variant;
  }

  Future<List<OfficePdfVariant>> readPdfVariants(
    VaultNote note,
    OfficeEdition source,
  ) => _readPdfVariants(note, source.revision, legacy: source);

  /// Finds derived previews without loading the original or PDF blob bytes.
  Future<List<OfficePdfVariant>> readDerivedPdfVariants(
    VaultNote note,
    RevisionRecord original,
  ) => _readPdfVariants(note, original);

  Future<List<OfficePdfVariant>> _readPdfVariants(
    VaultNote note,
    RevisionRecord original, {
    OfficeEdition? legacy,
  }) async {
    final sourceId = _sourceEntity(note);
    if (original.vaultId != repository.vaultId ||
        original.entityId != sourceId ||
        original.kind != EntityKind.attachment ||
        original.ownerNoteId != note.id ||
        original.deleted) {
      throw const FormatException('Foreign Office PDF source');
    }
    final records = await repository.revisions();
    if (!records.any(
      (record) =>
          record.revisionId == original.revisionId &&
          _sameRecord(record, original),
    )) {
      throw const FormatException('Office PDF source no longer exists');
    }
    if (original.blobs.containsKey('edition.json')) {
      final binding = legacy?.bindingId;
      return binding == null
          ? const []
          : List.unmodifiable([
              OfficePdfVariant._(
                original,
                original.revisionId,
                binding,
                legacy?.pageCount,
              ),
            ]);
    }
    final nonHeads = records
        .expand((record) => record.parentRevisionIds)
        .toSet();
    final variants = <OfficePdfVariant>[];
    for (final record in records) {
      final pdf = record.blobs['preview.pdf'];
      if (record.kind != EntityKind.attachment ||
          record.ownerNoteId != note.id ||
          record.baseRefs[sourceId]?.singleOrNull != original.revisionId ||
          nonHeads.contains(record.revisionId) ||
          pdf == null ||
          pdf.length == 0 ||
          pdf.length > _maxDerivedPdfBytes) {
        continue;
      }
      final expected = _derivedPdfVariant(original, pdf);
      if (_sameRecord(record, expected.revision)) variants.add(expected);
    }
    variants.sort((a, b) => a.bindingId.compareTo(b.bindingId));
    return List.unmodifiable(variants);
  }

  Future<Uint8List> readPdfVariantBytes(
    VaultNote note,
    OfficeEdition source,
    OfficePdfVariant variant,
  ) async {
    final verified = (await readPdfVariants(note, source))
        .where(
          (candidate) =>
              candidate.bindingId == variant.bindingId &&
              _sameRecord(candidate.revision, variant.revision),
        )
        .singleOrNull;
    if (verified == null) {
      throw const FormatException('Office PDF is not bound to this original');
    }
    final bytes = await repository.readRevisionFile(
      verified.revision,
      'preview.pdf',
    );
    _validatePdf(bytes, verified.pageCount ?? 1);
    return bytes;
  }

  Future<OfficeEdition> commitEdited(
    OfficeEditSession session, {
    required Uint8List originalBytes,
    required Uint8List pdfBytes,
    required String engineVersion,
    required int pageCount,
    bool requireCurrentHeads = false,
    void Function()? beforePublish,
  }) async {
    final prepared = prepareEdited(
      session,
      originalBytes: originalBytes,
      pdfBytes: pdfBytes,
      engineVersion: engineVersion,
      pageCount: pageCount,
      requireCurrentHeads: requireCurrentHeads,
      beforePublish: beforePublish,
    );
    return commitPreparedEdition(prepared);
  }

  OfficePreparedEdition prepareEdited(
    OfficeEditSession session, {
    required Uint8List originalBytes,
    required Uint8List pdfBytes,
    required String engineVersion,
    required int pageCount,
    bool requireCurrentHeads = false,
    void Function()? beforePublish,
  }) {
    _validateSession(session);
    final sourceEntityId = _sourceEntity(session.note);
    final original = Uint8List.fromList(originalBytes);
    final pdf = Uint8List.fromList(pdfBytes);
    _validateEditedOriginal(session.originalFileName, original);
    _validatePdf(pdf, pageCount);
    if (engineVersion.trim().isEmpty) {
      throw const FormatException('Missing Office engine identity');
    }
    final bindingId = newId();
    final version = engineVersion.trim();
    final files = {
      session.originalFileName: original,
      'preview.pdf': pdf,
      'edition.json': _encodeEditionMetadata(
        sourceEntityId: sourceEntityId,
        bindingId: bindingId,
        fileName: session.originalFileName,
        original: original,
        pdf: pdf,
        engineVersion: version,
        pageCount: pageCount,
      ),
    };
    final prepared = repository.prepareCommit(
      entityId: sourceEntityId,
      kind: EntityKind.attachment,
      ownerNoteId: session.note.id,
      files: files,
      parentRevisionIds: session.parentRevisionIds,
    );
    return OfficePreparedEdition._(
      session,
      prepared,
      OfficeEdition._(
        revision: prepared.record,
        originalFileName: session.originalFileName,
        originalBytes: original.asUnmodifiableView(),
        pdfBytes: pdf.asUnmodifiableView(),
        bindingId: bindingId,
        engineVersion: version,
        pageCount: pageCount,
      ),
      requireCurrentHeads || beforePublish != null,
      beforePublish,
      files,
    );
  }

  Future<OfficeEdition> commitPreparedEdition(
    OfficePreparedEdition edition,
  ) async {
    final session = edition._session;
    _validateSession(session);
    if (!edition._prepared.belongsTo(repository)) {
      throw const FormatException('Foreign prepared Office edition');
    }
    final record = edition._prepared.record;
    final known = (await repository.revisions()).any(
      (r) => r.revisionId == record.revisionId,
    );
    final manifest = File(
      '${repository.root.path}/revisions/${record.revisionId}.json',
    );
    if (known || manifest.existsSync()) {
      edition._beforePublish?.call();
      final actual = RevisionRecord.fromJson(
        jsonObject(jsonDecode(await manifest.readAsString())),
      );
      if (!_sameRecord(actual, record))
        throw const FormatException(
          'The published Office edition manifest was changed',
        );
      final actualFiles = await repository.readFiles(actual);
      if (!edition._prepared.matchesFiles(actualFiles))
        throw const FormatException(
          'The published Office edition payload was changed',
        );
      final verified = _decodeEdition(session.note, actual, actualFiles);
      if (!known) await repository.confirmPublishedCommit(edition._prepared);
      edition._beforePublish?.call();
      return verified;
    }
    if (edition._requireCurrentHeads) {
      await repository.commitPreparedIfHeads(
        edition._prepared,
        expectedHeads: {
          session.sourceEntityId: session.parentRevisionIds,
          session.note.id: [session.note.revision.revisionId],
        },
        beforePublish: edition._beforePublish,
      );
    } else {
      await repository.commitPrepared(edition._prepared);
    }
    return edition._edition;
  }

  (String, String, String, int) get _repositoryScope => (
    repository.root.absolute.uri.normalizePath().toString(),
    repository.vaultId,
    repository.deviceId,
    repository.formatVersion,
  );

  void _validateSession(OfficeEditSession session) {
    final sourceEntityId = _sourceEntity(session.note);
    if (session._repositoryScope != _repositoryScope ||
        session.sourceRevision.vaultId != repository.vaultId ||
        session.sourceEntityId != sourceEntityId ||
        session.sourceRevision.entityId != sourceEntityId ||
        session.sourceRevision.kind != EntityKind.attachment ||
        session.sourceRevision.ownerNoteId != session.note.id) {
      throw const FormatException('Foreign Office edit session');
    }
  }

  Future<OfficeEditSession> _readCapturedSession(
    VaultNote note,
    String noteRevisionId,
    String sourceRevisionId, {
    String? historicalSourceEntityId,
    bool requireCurrentAssociation = true,
  }) async {
    final sourceId = historicalSourceEntityId ?? _sourceEntity(note);
    final records = {
      for (final r in await repository.revisions()) r.revisionId: r,
    };
    final currentMetadata = records[note.revision.revisionId];
    final capturedMetadata = records[noteRevisionId];
    final source = records[sourceRevisionId];
    if (capturedMetadata == null ||
        capturedMetadata.entityId != note.id ||
        capturedMetadata.kind != EntityKind.metadata ||
        capturedMetadata.deleted ||
        source == null ||
        source.vaultId != repository.vaultId ||
        source.entityId != sourceId ||
        source.ownerNoteId != note.id ||
        source.kind != EntityKind.attachment ||
        source.deleted)
      throw const FormatException(
        'Office recovery history is missing or foreign',
      );
    final captured = await _readRecoveryNote(capturedMetadata);
    if (captured.sourceEntityId != sourceId)
      throw const FormatException('Office recovery source identity changed');
    if (requireCurrentAssociation) {
      if (sourceId != _sourceEntity(note) ||
          currentMetadata == null ||
          !_sameRecord(currentMetadata, note.revision) ||
          currentMetadata.entityId != note.id ||
          currentMetadata.kind != EntityKind.metadata)
        throw const FormatException('Office recovery note identity changed');
      final current = await _readRecoveryNote(currentMetadata);
      final currentHeads = await repository.heads(note.id);
      if (currentHeads.isEmpty)
        throw const FormatException('Missing current Office recovery metadata');
      final verifiedNotes = [
        current,
        captured,
        for (final head in currentHeads) await _readRecoveryNote(head),
      ];
      for (final verified in verifiedNotes) {
        if (verified.id != note.id ||
            verified.sourceEntityId != sourceId ||
            verified.inkEntityId != note.inkEntityId ||
            verified.markdownEntityId != note.markdownEntityId)
          throw const FormatException('Office recovery note identity changed');
      }
    }
    final edition = await _readEdition(captured, source);
    return OfficeEditSession._(
      _repositoryScope,
      note: captured,
      sourceEntityId: sourceId,
      sourceRevision: source,
      parentRevisionIds: List.unmodifiable([source.revisionId]),
      originalFileName: edition.originalFileName,
      originalBytes: edition.originalBytes,
    );
  }

  Future<VaultNote> _readRecoveryNote(RevisionRecord revision) async {
    if (revision.vaultId != repository.vaultId ||
        revision.kind != EntityKind.metadata)
      throw const FormatException('Foreign Office recovery metadata');
    final files = await repository.readFiles(revision);
    final bytes = files['note.json'];
    if (bytes == null)
      throw const FormatException('Missing Office recovery metadata');
    final json = jsonObject(jsonDecode(utf8.decode(bytes)));
    final title = json['title'];
    final ink = _recoveryId(json['inkEntityId']);
    final markdown = _recoveryId(json['markdownEntityId']);
    final source = _recoveryId(json['sourceEntityId']);
    final folder = json['folderId'] == null
        ? null
        : _recoveryId(json['folderId']);
    if (title is! String ||
        json['documentKind'] != VaultDocumentKind.office.name)
      throw const FormatException('Invalid Office recovery metadata');
    return VaultNote(
      revision.entityId,
      title,
      ink,
      markdown,
      revision,
      sourceEntityId: source,
      folderId: folder,
      documentKind: VaultDocumentKind.office,
      trashed: revision.deleted,
      metadata: json,
    );
  }

  bool _sameRecord(RevisionRecord left, RevisionRecord right) =>
      jsonEncode(left.toJson()) == jsonEncode(right.toJson());

  Future<List<OfficeEdition>> readEditions(VaultNote note) async =>
      List.unmodifiable([
        for (final revision in await _editionRevisions(note))
          await _readEdition(note, revision),
      ]);

  Future<List<OfficeEditionSummary>> readEditionSummaries(
    VaultNote note,
  ) async => List.unmodifiable([
    for (final revision in await _editionRevisions(note))
      await _readEditionSummary(note, revision),
  ]);

  Future<List<RevisionRecord>> _editionRevisions(VaultNote note) async {
    final source = _sourceEntity(note);
    final revisions = (await repository.revisions())
        .where((r) => r.entityId == source && !r.deleted)
        .toList();
    final byId = {
      for (final revision in revisions) revision.revisionId: revision,
    };
    final depths = <String, int>{};
    int depth(RevisionRecord revision) => depths.putIfAbsent(
      revision.revisionId,
      () => revision.parentRevisionIds.fold<int>(0, (current, parent) {
        final previous = byId[parent];
        final candidate = previous == null ? 0 : depth(previous) + 1;
        return candidate > current ? candidate : current;
      }),
    );
    revisions.sort((a, b) {
      final difference = depth(b).compareTo(depth(a));
      return difference == 0
          ? a.revisionId.compareTo(b.revisionId)
          : difference;
    });
    return revisions;
  }

  Future<OfficeEditionSummary> _readEditionSummary(
    VaultNote note,
    RevisionRecord revision,
  ) async {
    try {
      _validateEditionIdentity(note, revision);
      final manifest = revision.blobs['edition.json'];
      if (manifest == null) {
        _rawOriginalName(revision);
        return OfficeEditionSummary._(revision, hasPairedPdf: false);
      }
      final metadata = await _readBoundedEditionManifest(revision, manifest);
      return OfficeEditionSummary._(
        revision,
        hasPairedPdf: true,
        pageCount: metadata.pageCount,
      );
    } on FormatException {
      return _unavailableEditionSummary(revision);
    } on FileSystemException {
      return _unavailableEditionSummary(revision);
    }
  }

  Future<String?> readOriginalFileName(
    VaultNote note,
    RevisionRecord revision,
  ) async {
    try {
      _validateEditionIdentity(note, revision);
      final manifest = revision.blobs['edition.json'];
      return manifest == null
          ? _rawOriginalName(revision)
          : (await _readBoundedEditionManifest(revision, manifest)).fileName;
    } on FormatException {
      return null;
    } on FileSystemException {
      return null;
    }
  }

  Future<
    ({String fileName, String bindingId, String engineVersion, int pageCount})
  >
  _readBoundedEditionManifest(RevisionRecord revision, BlobRef manifest) async {
    if (manifest.length > _maxEditionSummaryManifestBytes) {
      throw const FormatException('Office edition manifest is too large');
    }
    final encoded = await repository.readRevisionFile(revision, 'edition.json');
    return _decodeEditionManifest(revision, encoded);
  }

  OfficeEditionSummary _unavailableEditionSummary(RevisionRecord revision) =>
      OfficeEditionSummary._(
        revision,
        hasPairedPdf: revision.blobs.containsKey('preview.pdf'),
        metadataUnavailable: true,
      );

  Future<OfficeEdition> readLatest(VaultNote note, {String? revisionId}) async {
    final source = _sourceEntity(note);
    RevisionRecord revision;
    if (revisionId != null) {
      validateId(revisionId);
      final candidates = (await repository.revisions()).where(
        (r) => r.entityId == source && r.revisionId == revisionId && !r.deleted,
      );
      if (candidates.length != 1) throw StateError('Office edition not found');
      revision = candidates.single;
    } else {
      final heads = await repository.heads(source);
      if (heads.length != 1 || heads.single.deleted) {
        throw StateError('Select an Office source revision before opening it');
      }
      revision = heads.single;
    }
    return _readEdition(note, revision);
  }

  String _sourceEntity(VaultNote note) {
    if (note.revision.vaultId != repository.vaultId ||
        note.documentKind != VaultDocumentKind.office ||
        note.sourceEntityId == null) {
      throw const FormatException('Expected an Office note in this vault');
    }
    return note.sourceEntityId!;
  }

  Future<OfficeEdition> _readEdition(
    VaultNote note,
    RevisionRecord revision,
  ) async {
    _validateEditionIdentity(note, revision);
    return _decodeEdition(note, revision, await repository.readFiles(revision));
  }

  void _validateEditionIdentity(VaultNote note, RevisionRecord revision) {
    if (revision.kind != EntityKind.attachment ||
        revision.ownerNoteId != note.id ||
        revision.entityId != _sourceEntity(note))
      throw const FormatException('Office source identity mismatch');
  }

  OfficeEdition _decodeEdition(
    VaultNote note,
    RevisionRecord revision,
    Map<String, Uint8List> files,
  ) {
    _validateEditionIdentity(note, revision);
    final encoded = files['edition.json'];
    if (encoded == null) {
      final fileName = _rawOriginalName(revision);
      final original = files[fileName];
      if (files.length != 1 || original == null) {
        throw const FormatException('Ambiguous Office original');
      }
      if (original.isEmpty)
        throw const FormatException('Empty Office original');
      return OfficeEdition._(
        revision: revision,
        originalFileName: fileName,
        originalBytes: original.asUnmodifiableView(),
      );
    }
    final metadata = _decodeEditionManifest(revision, encoded);
    final original = files[metadata.fileName];
    final pdf = files['preview.pdf'];
    if (files.length != 3 || original == null || pdf == null) {
      throw const FormatException('Office edition payload binding mismatch');
    }
    _validateEditedOriginal(metadata.fileName, original);
    _validatePdf(pdf, metadata.pageCount);
    return OfficeEdition._(
      revision: revision,
      originalFileName: metadata.fileName,
      originalBytes: original.asUnmodifiableView(),
      pdfBytes: pdf.asUnmodifiableView(),
      bindingId: metadata.bindingId,
      engineVersion: metadata.engineVersion,
      pageCount: metadata.pageCount,
    );
  }

  String _rawOriginalName(RevisionRecord revision) {
    if (revision.blobs.length != 1 ||
        revision.blobs.containsKey('edition.json')) {
      throw const FormatException('Ambiguous Office original');
    }
    final original = revision.blobs.entries.single;
    _validateFileName(original.key);
    if (original.value.length == 0) {
      throw const FormatException('Empty Office original');
    }
    return original.key;
  }

  ({String fileName, String bindingId, String engineVersion, int pageCount})
  _decodeEditionManifest(RevisionRecord revision, Uint8List encoded) {
    final metadata = jsonObject(jsonDecode(utf8.decode(encoded)));
    final fileName = metadata['originalFileName'];
    final binding = metadata['bindingId'];
    final version = metadata['engineVersion'];
    final pages = metadata['pageCount'];
    if (metadata['schemaVersion'] != 1 ||
        metadata['sourceEntityId'] != revision.entityId ||
        fileName is! String ||
        binding is! String ||
        version is! String ||
        version.trim().isEmpty ||
        pages is! int) {
      throw const FormatException('Invalid Office edition manifest');
    }
    _validateFileName(fileName);
    validateId(binding);
    final original = revision.blobs[fileName];
    final pdf = revision.blobs['preview.pdf'];
    if (revision.blobs.length != 3 ||
        !revision.blobs.containsKey('edition.json') ||
        original == null ||
        original.length == 0 ||
        pdf == null ||
        pdf.length == 0 ||
        metadata['originalSha256'] != original.hash ||
        metadata['pdfSha256'] != pdf.hash) {
      throw const FormatException('Office edition payload binding mismatch');
    }
    if (pages < 1) {
      throw const FormatException('Invalid derived Office PDF');
    }
    return (
      fileName: fileName,
      bindingId: binding,
      engineVersion: version,
      pageCount: pages,
    );
  }
}

const _maxEditionSummaryManifestBytes = 64 * 1024;
const _maxDerivedPdfBytes = 128 * 1024 * 1024;

OfficePdfVariant _derivedPdfVariant(RevisionRecord source, BlobRef pdf) {
  // Vault identity is excluded from the IDs because cloning remaps vaultId.
  final key =
      '${source.ownerNoteId}:${source.entityId}:${source.revisionId}:${pdf.hash}';
  final record = RevisionRecord(
    vaultId: source.vaultId,
    entityId: _officePdfId('attachment', key),
    kind: EntityKind.attachment,
    revisionId: _officePdfId('revision', key),
    parentRevisionIds: const [],
    // A derived file has no edit author. Use the original's stable identity.
    deviceId: source.deviceId,
    blobs: {'preview.pdf': pdf},
    ownerNoteId: source.ownerNoteId,
    baseRefs: {
      source.entityId: [source.revisionId],
    },
    formatVersion: 2,
  );
  return OfficePdfVariant._(
    record,
    source.revisionId,
    _officePdfId('ink', key),
    null,
  );
}

String _officePdfId(String kind, String key) {
  final bytes = sha256
      .convert(utf8.encode('office-derived-pdf-v1:$kind:$key'))
      .bytes
      .take(16)
      .toList();
  bytes[6] = (bytes[6] & 0x0f) | 0x80;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

Map<String, dynamic> _copyRecoveryJson(Map<String, dynamic> json) {
  try {
    return jsonObject(jsonDecode(jsonEncode(json)));
  } on Object {
    throw const FormatException('Expected Office recovery JSON');
  }
}

void _requireRecoveryKeys(Map<String, dynamic> json, Set<String> keys) {
  if (json.length != keys.length || !json.keys.toSet().containsAll(keys))
    throw const FormatException('Unexpected Office recovery descriptor fields');
}

String _recoveryId(Object? value) {
  if (value is! String)
    throw const FormatException('Expected Office recovery UUID');
  validateId(value);
  return value;
}

Uint8List _encodeEditionMetadata({
  required String sourceEntityId,
  required String bindingId,
  required String fileName,
  required Uint8List original,
  required Uint8List pdf,
  required String engineVersion,
  required int pageCount,
}) => Uint8List.fromList(
  utf8.encode(
    jsonEncode({
      'schemaVersion': 1,
      'sourceEntityId': sourceEntityId,
      'bindingId': bindingId,
      'originalFileName': fileName,
      'originalSha256': sha256.convert(original).toString(),
      'pdfSha256': sha256.convert(pdf).toString(),
      'engineVersion': engineVersion,
      'pageCount': pageCount,
    }),
  ),
);

String _validateFileName(String fileName) {
  validateLogicalPath(fileName);
  if (fileName.contains('/'))
    throw const FormatException('Expected a file name');
  final separator = fileName.lastIndexOf('.');
  if (separator < 1 || separator == fileName.length - 1) {
    throw const FormatException('Expected an Office file name and extension');
  }
  final extension = fileName.substring(separator + 1).toLowerCase();
  if (!OfficeDocumentStore.supportedExtensions.contains(extension)) {
    throw const FormatException('Unsupported Office source extension');
  }
  return extension;
}

bool _startsWith(Uint8List bytes, List<int> prefix) =>
    bytes.length >= prefix.length &&
    List.generate(
      prefix.length,
      (i) => bytes[i] == prefix[i],
    ).every((same) => same);

bool _hasOfficeSignature(String extension, Uint8List bytes) {
  if (extension != 'doc' && extension != 'ppt' && extension != 'hwp') {
    return _startsWith(bytes, const [0x50, 0x4b, 0x03, 0x04]);
  }
  return _startsWith(bytes, const [
        0xd0,
        0xcf,
        0x11,
        0xe0,
        0xa1,
        0xb1,
        0x1a,
        0xe1,
      ]) ||
      extension == 'hwp' &&
          _startsWith(bytes, ascii.encode('HWP Document File'));
}

void _validateEditedOriginal(String fileName, Uint8List bytes) {
  final extension = _validateFileName(fileName);
  if (bytes.isEmpty)
    throw const FormatException('Empty edited Office original');
  if (extension == 'doc' || extension == 'ppt' || extension == 'hwp') {
    if (!_hasOfficeSignature(extension, bytes)) {
      throw const FormatException('Invalid edited Office container');
    }
    return;
  }
  Archive? archive;
  try {
    if (!_hasOfficeSignature(extension, bytes)) {
      throw const FormatException('Invalid edited Office ZIP header');
    }
    archive = ZipDecoder().decodeBytes(bytes);
    final requiredParts = switch (extension) {
      'docx' => const ['[Content_Types].xml', 'word/document.xml'],
      'pptx' => const ['[Content_Types].xml', 'ppt/presentation.xml'],
      'odt' || 'odp' => const ['mimetype', 'content.xml'],
      'hwpx' => const ['mimetype'],
      _ => const <String>[],
    };
    for (final name in requiredParts) {
      final part = archive.find(name);
      if (part == null || !part.isFile || part.isSymbolicLink) {
        throw const FormatException('Missing edited Office document part');
      }
      final content = part.readBytes();
      if (content == null ||
          content.isEmpty ||
          getCrc32(content) != part.crc32) {
        throw const FormatException('Corrupt edited Office document part');
      }
    }
  } on Object {
    throw const FormatException('Invalid edited Office package');
  } finally {
    archive?.clearSync();
  }
}

void _validatePdf(Uint8List bytes, int pageCount) {
  if (pageCount < 1 || !_startsWith(bytes, ascii.encode('%PDF-'))) {
    throw const FormatException('Invalid derived Office PDF');
  }
  final tail = latin1.decode(
    bytes.sublist(bytes.length > 2048 ? bytes.length - 2048 : 0),
  );
  if (!tail.contains('%%EOF'))
    throw const FormatException('Incomplete derived Office PDF');
}
