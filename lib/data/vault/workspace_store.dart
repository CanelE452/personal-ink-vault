import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/native/ink_vault_native.dart';
import 'package:saber/data/vault/block_page_media_worker.dart';
import 'package:saber/data/vault/database_history.dart';
import 'package:saber/data/vault/database_media_snapshot.dart';
import 'package:saber/data/vault/knowledge_rename.dart';
import 'package:saber/data/vault/library_store.dart';
import 'package:saber/data/vault/obsidian_vault_source.dart';
import 'package:saber/data/vault/structured_document_text.dart';
import 'package:saber/data/vault/workspace_database.dart';

typedef SharedOfficeOriginal = ({String fileName, Uint8List bytes});

enum VaultDocumentKind {
  handwriting,
  pdf,
  markdown,
  infinite,
  image,
  office,
  canvas,
  page,
  database,
}

class VaultNote {
  final String id;
  final String title;
  final String inkEntityId;
  final String markdownEntityId;
  final RevisionRecord revision;
  final bool deletionConflict;
  final String? folderId;
  final VaultDocumentKind documentKind;
  final String? sourceEntityId;
  final bool trashed;
  final Map<String, dynamic> _metadata;
  new(
    this.id,
    this.title,
    this.inkEntityId,
    this.markdownEntityId,
    this.revision, {
    this.deletionConflict = false,
    this.folderId,
    this.documentKind = VaultDocumentKind.handwriting,
    this.sourceEntityId,
    this.trashed = false,
    Map<String, dynamic> metadata = const {},
  }) : _metadata = Map.unmodifiable(metadata);

  String? get obsidianAttachmentName {
    final value = _metadata['obsidianAttachmentName'];
    return value is String ? value : null;
  }

  List<String> get notionExportNames {
    final value = _metadata['notionExportNames'];
    if (value == null) return const [];
    if (value is! List ||
        value.any((name) => name is! String) ||
        !_validNotionExportNames(value.cast<String>(), documentKind)) {
      throw const FormatException('Invalid Notion export filenames');
    }
    return List.unmodifiable(value.cast<String>());
  }

  Map<String, dynamic> get json => {
    ..._metadata,
    'title': title,
    'inkEntityId': inkEntityId,
    'markdownEntityId': markdownEntityId,
    if (folderId != null || _metadata.containsKey('folderId'))
      'folderId': folderId,
    if (documentKind != VaultDocumentKind.handwriting ||
        _metadata.containsKey('documentKind'))
      'documentKind': documentKind.name,
    if (sourceEntityId != null || _metadata.containsKey('sourceEntityId'))
      'sourceEntityId': sourceEntityId,
  };
}

class DailyNoteUnavailable extends StateError {
  new(super.message, {this.trashed = false});

  final bool trashed;
}

bool _validNotionExportNames(List<String> names, VaultDocumentKind kind) {
  if (names.isEmpty) return true;
  final extension = switch (kind) {
    VaultDocumentKind.markdown => '.md',
    VaultDocumentKind.database => '.csv',
    _ => null,
  };
  return extension != null &&
      names.length <= 2 &&
      names.toSet().length == names.length &&
      names.every(
        (name) =>
            !name.startsWith('.') &&
            name.toLowerCase().endsWith(extension) &&
            isObsidianPathSegment(name),
      );
}

// Backups retain entity and revision IDs when they change the vault ID.
String _dailyNoteId(String role, String date) {
  final bytes = sha256
      .convert(utf8.encode('personal-ink-vault:daily-note:v1:$role:$date'))
      .bytes
      .take(16)
      .toList();
  bytes[6] = (bytes[6] & 0x0f) | 0x80;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

bool _missingDailyGenesis(
  List<RevisionRecord> revisions,
  RevisionRecord expected,
) {
  final roots = revisions
      .where(
        (revision) =>
            revision.entityId == expected.entityId &&
            revision.parentRevisionIds.isEmpty,
      )
      .toList();
  if (roots.isEmpty) return true;
  if (roots.length != 1 ||
      jsonEncode(roots.single.toJson()) != jsonEncode(expected.toJson())) {
    throw DailyNoteUnavailable('날짜별 노트의 최초 판본이 일치하지 않습니다.');
  }
  return false;
}

class WorkspaceStore {
  final NoteRepository repository;
  final KnowledgeInvoke? _knowledgeInvoke;
  new(
    this.repository, {
    InkVaultNative? native,
    KnowledgeInvoke? knowledgeInvoke,
  }) : _knowledgeInvoke = knowledgeInvoke ?? native?.invoke;

  Future<VaultNote> _decode(
    RevisionRecord revision, {
    bool deletionConflict = false,
    bool? trashed,
  }) async {
    final files = await repository.readFiles(revision);
    final json =
        jsonDecode(utf8.decode(files['note.json']!)) as Map<String, dynamic>;
    final ink = json['inkEntityId'] as String;
    final markdown = json['markdownEntityId'] as String;
    validateId(ink);
    validateId(markdown);
    final folder = json['folderId'] as String?;
    final source = json['sourceEntityId'] as String?;
    if (folder != null) validateId(folder);
    if (source != null) validateId(source);
    final kind = json['documentKind'] == null
        ? VaultDocumentKind.handwriting
        : VaultDocumentKind.values
              .where((k) => k.name == json['documentKind'])
              .singleOrNull;
    if (kind == null) throw const FormatException('Unsupported document kind');
    return VaultNote(
      revision.entityId,
      json['title'] as String,
      ink,
      markdown,
      revision,
      deletionConflict: deletionConflict,
      folderId: folder,
      sourceEntityId: source,
      documentKind: kind,
      trashed: trashed ?? revision.deleted,
      metadata: json,
    );
  }

  Future<List<VaultNote>> list({bool includeDeleted = false}) async {
    final records = await repository.revisions();
    final parents = records.expand((r) => r.parentRevisionIds).toSet();
    final headsByEntity = <String, List<RevisionRecord>>{};
    for (final record in records) {
      if (!parents.contains(record.revisionId)) {
        (headsByEntity[record.entityId] ??= []).add(record);
      }
    }
    final locations = repository.formatVersion >= 2
        ? await LibraryStore(repository).documentLocations()
        : <String, LibraryLocation>{};
    final ids = records
        .where((r) => r.kind == EntityKind.metadata)
        .map((r) => r.entityId)
        .toSet();
    final result = <VaultNote>[];
    for (final id in ids) {
      final heads = headsByEntity[id]!;
      // Each metadata branch stays visible, including a delete-vs-edit conflict.
      for (final head in heads) {
        var conflict = head.deleted && heads.length > 1;
        if (head.deleted) {
          final children = records
              .where((r) => r.ownerNoteId == id)
              .map((r) => r.entityId)
              .toSet();
          for (final child in children) {
            final childHeads = headsByEntity[child] ?? const <RevisionRecord>[];
            if (childHeads.any(
              (r) => !(head.baseRefs[child] ?? const []).contains(r.revisionId),
            ))
              conflict = true;
          }
        }
        final location = locations[head.revisionId] ?? const LibraryLocation();
        conflict = conflict || location.deletionConflict;
        final trashed = head.deleted || location.trashed;
        if (trashed && !includeDeleted && !conflict) continue;
        result.add(
          await _decode(head, deletionConflict: conflict, trashed: trashed),
        );
      }
    }
    result.sort(
      (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
    );
    return result;
  }

  Future<VaultNote> create(
    String title, {
    String? folderId,
    VaultDocumentKind documentKind = VaultDocumentKind.handwriting,
  }) => _create(title, folderId: folderId, documentKind: documentKind);

  Future<VaultNote> createNotionDatabase(
    String title, {
    String? folderId,
    required List<String> notionExportNames,
  }) => _create(
    title,
    folderId: folderId,
    documentKind: VaultDocumentKind.database,
    notionExportNames: notionExportNames,
  );

  Future<VaultNote> createMarkdown(
    String title,
    Uint8List markdown, {
    String? folderId,
    List<String> aliases = const [],
    List<String> notionExportNames = const [],
  }) => _create(
    title,
    folderId: folderId,
    documentKind: VaultDocumentKind.markdown,
    initialMarkdown: Uint8List.fromList(markdown),
    aliases: List<String>.of(aliases),
    notionExportNames: notionExportNames,
  );

  Future<VaultNote> openDailyNote(
    DateTime date, {
    Future<({Uint8List bytes, Map<String, List<String>> expectedHeads})?>
    Function(String title)?
    loadInitialMarkdown,
    void Function()? beforePublish,
  }) async {
    final (title, noteId, inkId, markdownId) = _dailyIdentity(date);

    // The first revisions must match on devices that create offline, including
    // the author field. Later commits still use the device's own identity.
    final authorId = _dailyNoteId('author', 'genesis');
    final metadata = _dailyNoteRevision(
      revisionId: _dailyNoteId('metadata-genesis', title),
      entityId: noteId,
      kind: EntityKind.metadata,
      authorId: authorId,
      file: 'note.json',
      bytes: Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'title': title,
            'dailyDate': title,
            'inkEntityId': inkId,
            'markdownEntityId': markdownId,
            'folderId': null,
            'documentKind': VaultDocumentKind.markdown.name,
          }),
        ),
      ),
    );
    final markdown = _dailyNoteRevision(
      revisionId: _dailyNoteId('markdown-genesis', title),
      entityId: markdownId,
      kind: EntityKind.markdown,
      authorId: authorId,
      ownerNoteId: noteId,
      file: 'summary.md',
      bytes: Uint8List(0),
    );
    final revisions = await repository.revisions();
    final missingMetadata = _missingDailyGenesis(revisions, metadata.record);
    final missingMarkdown = _missingDailyGenesis(revisions, markdown.record);
    Future<VaultNote> readNote() async => _readDailyNote(
      await repository.heads(noteId),
      title,
      inkId,
      markdownId,
    );

    if (!missingMetadata && !missingMarkdown) return readNote();
    if (missingMetadata && missingMarkdown && loadInitialMarkdown != null) {
      if (await repository.hasKnownRevisions([noteId, markdownId])) {
        return openDailyNote(date, beforePublish: beforePublish);
      }
      final initial = await loadInitialMarkdown(title);
      if (initial != null) {
        final child = initial.bytes.isEmpty
            ? null
            : _dailyNoteRevision(
                revisionId: _dailyNoteId(
                  'markdown-template',
                  '$title:${sha256.convert(initial.bytes)}',
                ),
                entityId: markdownId,
                kind: EntityKind.markdown,
                authorId: authorId,
                ownerNoteId: noteId,
                file: 'summary.md',
                bytes: initial.bytes,
                parentRevisionIds: [markdown.record.revisionId],
              );
        final published = await repository.importInitialNoteIfHeads(
          metadata: metadata.record,
          markdown: markdown.record,
          initialMarkdown: child?.record,
          blobsByHash: {
            ...metadata.blobs,
            ...markdown.blobs,
            if (child != null) ...child.blobs,
          },
          expectedHeads: initial.expectedHeads,
          beforePublish: beforePublish,
        );
        if (published) return readNote();
        return openDailyNote(date, beforePublish: beforePublish);
      }
    }
    if (!missingMetadata) await readNote();
    if (missingMarkdown) {
      await repository.importRevision(
        markdown.record,
        blobsByHash: markdown.blobs,
        beforePublish: beforePublish,
      );
    }
    if (missingMetadata) {
      await repository.importRevision(
        metadata.record,
        blobsByHash: metadata.blobs,
        beforePublish: beforePublish,
      );
    }
    return readNote();
  }

  Future<VaultNote?> readDailyNote(DateTime date) async {
    final (title, noteId, inkId, markdownId) = _dailyIdentity(date);
    final heads = await repository.heads(noteId);
    if (heads.isEmpty) return null;
    return _readDailyNote(heads, title, inkId, markdownId);
  }

  (String, String, String, String) _dailyIdentity(DateTime date) {
    if (repository.formatVersion < 2) {
      throw const FormatException('Daily notes require vault format 2');
    }
    if (date.year < 1 || date.year > 9999) {
      throw const FormatException('Daily note year is out of range');
    }
    final year = date.year.toString().padLeft(4, '0');
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    final title = '$year-$month-$day';
    return (
      title,
      _dailyNoteId('note', title),
      _dailyNoteId('ink', title),
      _dailyNoteId('markdown', title),
    );
  }

  ({RevisionRecord record, Map<String, Uint8List> blobs}) _dailyNoteRevision({
    required String revisionId,
    required String entityId,
    required EntityKind kind,
    required String authorId,
    String? ownerNoteId,
    required String file,
    required Uint8List bytes,
    List<String> parentRevisionIds = const [],
  }) {
    final hash = sha256.convert(bytes).toString();
    return (
      record: RevisionRecord(
        vaultId: repository.vaultId,
        revisionId: revisionId,
        entityId: entityId,
        kind: kind,
        deviceId: authorId,
        ownerNoteId: ownerNoteId,
        parentRevisionIds: parentRevisionIds,
        blobs: {file: BlobRef(hash: hash, length: bytes.length)},
        formatVersion: 2,
      ),
      blobs: {hash: bytes},
    );
  }

  Future<VaultNote> _readDailyNote(
    List<RevisionRecord> heads,
    String date,
    String inkId,
    String markdownId,
  ) async {
    final head = heads.singleOrNull;
    if (head == null ||
        head.kind != EntityKind.metadata ||
        head.ownerNoteId != null) {
      throw DailyNoteUnavailable('날짜별 노트의 메타데이터 판본을 확인하세요.');
    }
    if (head.deleted) {
      throw DailyNoteUnavailable('휴지통에서 날짜별 노트를 복원하세요.', trashed: true);
    }
    final note = await _decode(head);
    if (note.json['dailyDate'] != date ||
        note.documentKind != VaultDocumentKind.markdown ||
        note.inkEntityId != inkId ||
        note.markdownEntityId != markdownId) {
      throw DailyNoteUnavailable('날짜별 노트의 저장 정보가 일치하지 않습니다.');
    }
    if (note.folderId != null) {
      final location = await LibraryStore(repository).location(
        note.folderId,
        documentRevisions: [
          head,
          ...await repository.heads(markdownId),
          ...await repository.heads(inkId),
        ],
      );
      if (location.deletionConflict) {
        throw DailyNoteUnavailable('날짜별 노트가 있는 폴더의 판본 충돌을 확인하세요.');
      }
      if (location.trashed) {
        throw DailyNoteUnavailable(
          '날짜별 노트가 있는 폴더를 휴지통에서 복원하세요.',
          trashed: true,
        );
      }
    }
    return note;
  }

  Future<VaultNote> createWithSource(
    String title, {
    required String fileName,
    required Uint8List bytes,
    required VaultDocumentKind documentKind,
    String? folderId,
    bool fromObsidian = false,
    String? sharedRequestId,
    SharedOfficeOriginal? sharedOfficeOriginal,
  }) async {
    if (repository.formatVersion < 2)
      throw const FormatException('Attachments require vault format 2');
    if (!const {
          VaultDocumentKind.office,
          VaultDocumentKind.image,
          VaultDocumentKind.pdf,
        }.contains(documentKind) &&
        !(documentKind == VaultDocumentKind.canvas &&
            fromObsidian &&
            obsidianAttachmentKind(fileName) == 'canvas')) {
      throw const FormatException(
        'This document type does not accept an original',
      );
    }
    _validateSourceFileName(fileName);
    if (bytes.isEmpty) throw const FormatException('Empty source original');
    if (sharedOfficeOriginal != null &&
        (sharedRequestId == null || documentKind != VaultDocumentKind.pdf)) {
      throw const FormatException('Expected a shared Office PDF import');
    }
    final original = Uint8List.fromList(bytes);
    if (sharedRequestId != null) {
      if (fromObsidian ||
          documentKind != VaultDocumentKind.pdf &&
              documentKind != VaultDocumentKind.office) {
        throw const FormatException('Unsupported shared document receipt');
      }
      validateId(sharedRequestId);
      final receipt = sharedOfficeOriginal == null
          ? _sharedSourceReceipt(documentKind.name, fileName, original)
          : _sharedOfficePdfReceipt(sharedOfficeOriginal);
      final existing = await _readSharedDocument(sharedRequestId, {receipt});
      if (existing != null) return existing;
      try {
        return await _create(
          title,
          folderId: folderId,
          documentKind: documentKind,
          sourceFileName: fileName,
          sourceBytes: original,
          sharedRequestId: sharedRequestId,
          sharedReceipt: receipt,
        );
      } on StateError {
        final published = await _readSharedDocument(sharedRequestId, {receipt});
        if (published != null) return published;
        rethrow;
      }
    }
    return _create(
      title,
      folderId: folderId,
      documentKind: documentKind,
      sourceFileName: fileName,
      sourceBytes: original,
      fromObsidian: fromObsidian,
    );
  }

  Future<VaultNote> createOfficeCopy(
    String title, {
    required VaultNote originalNote,
    required RevisionRecord originalSource,
    required String fileName,
    required Map<String, Uint8List> Function(String sourceEntityId)
    buildSourceFiles,
    void Function()? beforePublish,
  }) async {
    if (repository.formatVersion < 2 ||
        originalNote.documentKind != VaultDocumentKind.office ||
        originalNote.revision.vaultId != repository.vaultId ||
        originalNote.revision.entityId != originalNote.id ||
        originalNote.revision.kind != EntityKind.metadata ||
        originalNote.revision.deleted ||
        originalNote.trashed ||
        originalNote.deletionConflict ||
        originalSource.vaultId != repository.vaultId ||
        originalSource.kind != EntityKind.attachment ||
        originalSource.entityId != originalNote.sourceEntityId ||
        originalSource.ownerNoteId != originalNote.id ||
        originalSource.deleted) {
      throw const FormatException('Expected a current Office original');
    }
    _validateSourceFileName(fileName);
    final extension = fileName.lastIndexOf('.');
    if (extension < 1 ||
        !const {
          'docx',
          'pptx',
        }.contains(fileName.substring(extension + 1).toLowerCase())) {
      throw const FormatException('Expected a DOCX or PPTX copy');
    }
    return _create(
      title,
      folderId: originalNote.folderId,
      documentKind: VaultDocumentKind.office,
      sourceFileName: fileName,
      buildSourceFiles: (source) {
        final files = buildSourceFiles(source);
        if (files.length != 3 ||
            files[fileName]?.isNotEmpty != true ||
            !files.containsKey('preview.pdf') ||
            !files.containsKey('edition.json')) {
          throw const FormatException('Expected the Office preview bundle');
        }
        return files;
      },
      expectedSourceHeads: {
        originalNote.id: [originalNote.revision.revisionId],
        originalSource.entityId: [originalSource.revisionId],
      },
      beforePublish: beforePublish,
    );
  }

  static void _validateSourceFileName(String fileName) {
    validateLogicalPath(fileName);
    if (fileName.contains('/') ||
        RegExp(r'[<>"|?*]').hasMatch(fileName) ||
        fileName.endsWith('.') ||
        fileName.endsWith(' ') ||
        RegExp(
          r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)',
          caseSensitive: false,
        ).hasMatch(fileName)) {
      throw const FormatException('Unsafe source file name');
    }
  }

  static String _sharedSourceReceipt(
    String kind,
    String fileName,
    Uint8List bytes,
  ) => sha256
      .convert(
        utf8.encode(jsonEncode([kind, fileName, '${sha256.convert(bytes)}'])),
      )
      .toString();

  static String _sharedOfficePdfReceipt(SharedOfficeOriginal original) {
    _validateSourceFileName(original.fileName);
    if (original.bytes.isEmpty)
      throw const FormatException('Empty Office original');
    return _sharedSourceReceipt(
      'office-pdf',
      original.fileName,
      original.bytes,
    );
  }

  Future<VaultNote?> readSharedOfficeImport(
    String requestId,
    SharedOfficeOriginal original,
  ) {
    validateId(requestId);
    return _readSharedDocument(requestId, {
      _sharedSourceReceipt('office', original.fileName, original.bytes),
      _sharedOfficePdfReceipt(original),
    });
  }

  Future<VaultNote?> _readSharedDocument(
    String id,
    Set<String> receipts,
  ) async {
    final heads = await repository.heads(id);
    if (heads.isEmpty) return null;
    final head = heads.singleOrNull;
    if (head == null || head.kind != EntityKind.metadata) {
      throw StateError('공유 문서 식별자가 기존 문서와 충돌했습니다.');
    }
    final location = (await LibraryStore(repository)
        .documentLocations())[head.revisionId];
    final note = await _decode(
      head,
      trashed: head.deleted || (location?.trashed ?? false),
    );
    if (!receipts.contains(note.json['sharedDocumentReceipt'])) {
      throw StateError('공유 문서의 원본을 확인할 수 없습니다.');
    }
    return note;
  }

  Future<VaultNote> _create(
    String title, {
    String? folderId,
    required VaultDocumentKind documentKind,
    String? sourceFileName,
    Uint8List? sourceBytes,
    Uint8List? initialMarkdown,
    List<String> aliases = const [],
    List<String> notionExportNames = const [],
    bool fromObsidian = false,
    String? sharedRequestId,
    String? sharedReceipt,
    Map<String, Uint8List> Function(String sourceEntityId)? buildSourceFiles,
    Map<String, List<String>>? expectedSourceHeads,
    void Function()? beforePublish,
  }) async {
    if (repository.formatVersion < 2 &&
        (folderId != null || documentKind != VaultDocumentKind.handwriting)) {
      throw const FormatException(
        'Document types and folders require vault format 2',
      );
    }
    final exportedNames = List<String>.of(notionExportNames);
    if (!_validNotionExportNames(exportedNames, documentKind)) {
      throw const FormatException('Invalid Notion export filenames');
    }
    await LibraryStore(repository).validateDestination(folderId);
    final id = sharedRequestId ?? newId(), ink = newId(), markdown = newId();
    final source = sourceFileName == null ? null : newId();
    if (source != null) {
      final prepared = repository.prepareCommit(
        entityId: source,
        kind: EntityKind.attachment,
        ownerNoteId: id,
        files:
            buildSourceFiles?.call(source) ?? {sourceFileName!: sourceBytes!},
        parentRevisionIds: [],
      );
      if (expectedSourceHeads == null) {
        await repository.commitPrepared(prepared);
      } else {
        await repository.commitPreparedIfHeads(
          prepared,
          expectedHeads: {...expectedSourceHeads, source: const []},
          beforePublish: beforePublish,
        );
      }
    }
    await repository.commit(
      entityId: markdown,
      kind: EntityKind.markdown,
      ownerNoteId: id,
      files: {'summary.md': initialMarkdown ?? Uint8List(0)},
      parentRevisionIds: [],
    );
    final metadata = {
      'note.json': Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'title': title.trim().isEmpty ? '새 노트' : title.trim(),
            'inkEntityId': ink,
            'markdownEntityId': markdown,
            if (aliases.isNotEmpty) 'aliases': aliases,
            if (exportedNames.isNotEmpty) 'notionExportNames': exportedNames,
            'sourceEntityId': ?source,
            if (fromObsidian) 'obsidianAttachmentName': sourceFileName!,
            if (repository.formatVersion >= 2) 'folderId': folderId,
            if (repository.formatVersion >= 2)
              'documentKind': documentKind.name,
            'sharedDocumentReceipt': ?sharedReceipt,
          }),
        ),
      ),
    };
    final revision = sharedRequestId == null && expectedSourceHeads == null
        ? await repository.commit(
            entityId: id,
            kind: EntityKind.metadata,
            files: metadata,
            parentRevisionIds: [],
          )
        : await repository.commitPreparedIfHeads(
            repository.prepareCommit(
              entityId: id,
              kind: EntityKind.metadata,
              files: metadata,
              parentRevisionIds: [],
            ),
            expectedHeads: {...?expectedSourceHeads, id: const []},
            beforePublish: beforePublish,
          );
    return _decode(revision);
  }

  Future<void> rename(
    VaultNote note,
    String title, {
    void Function()? requireWrite,
    Future<void> Function(PreparedKnowledgeChange)? onPrepared,
  }) async {
    if (title.trim().isEmpty) throw const FormatException('제목을 입력하세요');
    await renameKnowledgeNote(
      repository,
      note,
      title.trim(),
      invoke: _knowledgeInvoke,
      requireWrite: requireWrite,
      onPrepared: onPrepared,
    );
  }

  Future<void> moveNote(
    VaultNote note,
    String? folderId, {
    void Function()? requireWrite,
    Future<void> Function(PreparedKnowledgeChange)? onPrepared,
  }) async {
    if (repository.formatVersion < 2)
      throw const FormatException('Moving requires vault format 2');
    await changeKnowledgePath(
      repository,
      note: note,
      changes: {'folderId': folderId},
      invoke: _knowledgeInvoke,
      requireWrite: requireWrite,
      onPrepared: onPrepared,
    );
  }

  Future<VaultNote> attachSource(
    VaultNote note, {
    required String fileName,
    required Uint8List bytes,
  }) async {
    if (repository.formatVersion < 2)
      throw const FormatException('Attachments require vault format 2');
    if (note.sourceEntityId != null)
      throw StateError('The document already has a source');
    validateLogicalPath(fileName);
    if (fileName.contains('/'))
      throw const FormatException('Expected a file name');
    final source = newId();
    await repository.commit(
      entityId: source,
      kind: EntityKind.attachment,
      ownerNoteId: note.id,
      files: {fileName: bytes},
      parentRevisionIds: [],
    );
    return _decode(await _update(note, {'sourceEntityId': source}));
  }

  Future<RevisionRecord> _update(
    VaultNote note,
    Map<String, dynamic> changes, {
    bool? deleted,
    Map<String, List<String>>? baseRefs,
  }) async {
    final files = await repository.readFiles(note.revision);
    final json = jsonObject(jsonDecode(utf8.decode(files['note.json']!)));
    return repository.commit(
      entityId: note.id,
      kind: EntityKind.metadata,
      files: {
        ...files,
        'note.json': Uint8List.fromList(
          utf8.encode(jsonEncode({...json, ...changes})),
        ),
      },
      parentRevisionIds: [note.revision.revisionId],
      deleted: deleted ?? note.revision.deleted,
      baseRefs: baseRefs ?? note.revision.baseRefs,
    );
  }

  Future<void> setDeleted(
    VaultNote note,
    bool deleted, {
    void Function()? requireWrite,
    Future<void> Function(PreparedKnowledgeChange)? onPrepared,
  }) async {
    await changeKnowledgePath(
      repository,
      note: note,
      deleted: deleted,
      invoke: _knowledgeInvoke,
      requireWrite: requireWrite,
      onPrepared: onPrepared,
    );
  }

  Future<List<VaultNote>> search(String query) async {
    final q = query.toLowerCase();
    final result = <VaultNote>[];
    for (final note in await list()) {
      if (note.title.toLowerCase().contains(q)) {
        result.add(note);
        continue;
      }
      for (final head in await repository.heads(note.markdownEntityId)) {
        final files = await repository.readFiles(head);
        if (utf8.decode(files['summary.md']!).toLowerCase().contains(q)) {
          result.add(note);
          break;
        }
      }
      if (!result.any(
            (matched) =>
                matched.revision.revisionId == note.revision.revisionId,
          ) &&
          const {
            'page',
            'canvas',
            'database',
          }.contains(note.documentKind.name)) {
        for (final head in await repository.heads(note.inkEntityId)) {
          if (!head.deleted &&
              structuredDocumentText(
                note.documentKind.name,
                await repository.readFiles(head),
              ).toLowerCase().contains(q)) {
            result.add(note);
            break;
          }
        }
      }
    }
    return result;
  }

  Future<NoteSession> open(VaultNote note) async => NoteSession(
    repository,
    note,
    await repository.heads(note.inkEntityId),
    await repository.heads(note.markdownEntityId),
  );
}

class PreparedPageRestore {
  new _(
    this._prepared,
    this.selectedRevisionId,
    Map<String, List<String>> expectedHeads,
  ) : expectedHeads = _immutableRestoreHeads(expectedHeads);

  final PreparedCommit _prepared;
  final String selectedRevisionId;
  final Map<String, List<String>> expectedHeads;
  RevisionRecord get record => _prepared.record;

  Map<String, dynamic> toJson() => {
    'version': 1,
    'selectedRevisionId': selectedRevisionId,
    'expectedHeads': {
      for (final entry in expectedHeads.entries)
        entry.key: List.of(entry.value),
    },
    'prepared': _prepared.toRecoveryDescriptor(),
  };
}

Map<String, List<String>> _immutableRestoreHeads(
  Map<String, List<String>> heads,
) => Map.unmodifiable({
  for (final entry in heads.entries)
    entry.key: List<String>.unmodifiable(entry.value),
});

bool _sameRestoreHeads(
  Map<String, List<String>> left,
  Map<String, List<String>> right,
) =>
    left.length == right.length &&
    left.entries.every(
      (entry) =>
          right[entry.key]?.length == entry.value.length &&
          entry.value.toSet().containsAll(right[entry.key]!),
    );

Future<
  ({
    WorkspaceDatabase database,
    Map<String, Uint8List> files,
    bool needsNativeValidation,
  })
>
_prepareDatabaseRestore(
  Map<String, Uint8List> selectedFiles,
  Map<String, Uint8List> currentFiles,
) => Isolate.run(() {
  final selected = DatabaseMediaSnapshot.fromFiles(selectedFiles).database;
  final current = DatabaseMediaSnapshot.fromFiles(currentFiles).database;
  final database = databaseContentForRestore(
    current: current,
    chosen: selected,
  );
  final json = database.toJson();
  final rules = json['automationRules'];
  final executions = json['automationExecutions'];
  if (rules != null && rules is! List) {
    throw const FormatException('Invalid database automation rules');
  }
  final files = {
    ...selectedFiles,
    if (!const DeepCollectionEquality().equals(json, selected.toJson()))
      'database.json': Uint8List.fromList(utf8.encode(jsonEncode(json))),
  };
  DatabaseMediaSnapshot.fromFiles(files);
  return (
    database: database,
    files: files,
    needsNativeValidation:
        rules is List && rules.isNotEmpty ||
        executions is List && executions.isNotEmpty,
  );
});

class NoteSession {
  NoteRepository repository;
  VaultNote note;
  List<RevisionRecord> inkHeads;
  List<RevisionRecord> markdownHeads;
  late List<String> inkParents = inkHeads.isEmpty
      ? []
      : [inkHeads.first.revisionId];
  late List<String> markdownParents = markdownHeads.isEmpty
      ? []
      : [markdownHeads.first.revisionId];
  Future<void> _writeTail = Future.value();
  final _pending =
      <
        String,
        (String, PreparedCommit, Map<String, List<String>>?, void Function()?)
      >{};
  new(this.repository, this.note, this.inkHeads, this.markdownHeads);

  Future<String> readMarkdown({List<String>? parents}) async {
    final selected = parents ?? markdownParents;
    if (selected.isEmpty) return '';
    final revision = (await repository.revisions()).singleWhere(
      (r) => r.revisionId == selected.first,
    );
    final files = await repository.readFiles(revision);
    return utf8.decode(files['summary.md']!);
  }

  Future<void> saveMarkdown(
    String text, {
    Map<String, List<String>>? expectedHeads,
    void Function()? requireWrite,
  }) {
    final files = {'summary.md': Uint8List.fromList(utf8.encode(text))};
    final guards = expectedHeads == null
        ? null
        : _immutableRestoreHeads(expectedHeads);
    return _write(
      (repo, target) => _saveFiles(
        repo,
        target,
        entityId: target.markdownEntityId,
        kind: EntityKind.markdown,
        ownerNoteId: target.id,
        operation: 'save',
        files: files,
        parents: () async => List.of(markdownParents),
        expectedHeads: guards,
        requireWrite: requireWrite,
      ),
    );
  }

  Future<void> saveInk(
    Map<String, Uint8List> files, {
    Map<String, List<String>>? expectedHeads,
    void Function()? requireWrite,
  }) {
    final copied = files.map(
      (key, value) => MapEntry(key, Uint8List.fromList(value)),
    );
    final guards = expectedHeads == null
        ? null
        : _immutableRestoreHeads(expectedHeads);
    return _write(
      (repo, target) => _saveFiles(
        repo,
        target,
        entityId: target.inkEntityId,
        kind: EntityKind.ink,
        ownerNoteId: target.id,
        operation: 'save',
        files: copied,
        parents: () async => List.of(inkParents),
        expectedHeads: guards,
        requireWrite: requireWrite,
      ),
    );
  }

  Future<void> saveDetachedPage(
    Map<String, Uint8List> files, {
    required Map<String, List<String>> expectedHeads,
    required void Function() requireWrite,
  }) {
    final guards = _immutableRestoreHeads(expectedHeads);
    return _write((repo, target) async {
      _requireLivePage(target);
      requireWrite();
      final entityId = target.inkEntityId;
      if (_pending.containsKey(entityId)) {
        throw StateError('진행 중인 페이지 저장을 먼저 다시 시도하세요.');
      }
      final parents = List<String>.of(inkParents);
      if (parents.length != 1 ||
          guards[entityId]?.singleOrNull != parents.single) {
        throw StateError('연결된 페이지의 저장 판본이 바뀌었습니다.');
      }
      final prepared = repo.prepareCommit(
        entityId: entityId,
        kind: EntityKind.ink,
        ownerNoteId: target.id,
        files: files,
        parentRevisionIds: parents,
      );
      try {
        await _publish(repo, target, entityId, prepared, guards, requireWrite);
      } catch (error, stack) {
        // An unpublished detach is an abandoned operation. A manifest that did
        // reach disk can be acknowledged without reusing a stale UI callback.
        final manifest =
            '${repo.root.path}/revisions/'
            '${prepared.record.revisionId}.json';
        if (FileSystemEntity.typeSync(manifest, followLinks: false) !=
            FileSystemEntityType.file) {
          Error.throwWithStackTrace(error, stack);
        }
        final record = await repo.confirmPublishedCommit(prepared);
        final current = (await repo.heads(entityId)).singleOrNull;
        _requireNote(target);
        if (!identical(repo, repository) ||
            current?.revisionId != record.revisionId) {
          Error.throwWithStackTrace(error, stack);
        }
        inkParents = [record.revisionId];
      }
    });
  }

  Future<void> mergeMarkdown(String text) {
    final files = {'summary.md': Uint8List.fromList(utf8.encode(text))};
    return _write(
      (repo, target) => _saveFiles(
        repo,
        target,
        entityId: target.markdownEntityId,
        kind: EntityKind.markdown,
        ownerNoteId: target.id,
        operation: 'merge',
        files: files,
        parents: () async =>
            (await repo.heads(target.markdownEntityId))
                .map((head) => head.revisionId)
                .toList(),
      ),
    );
  }

  Future<void> resolve(RevisionRecord chosen) => _write((repo, target) async {
    await _saveFiles(
      repo,
      target,
      entityId: chosen.entityId,
      kind: chosen.kind,
      ownerNoteId: chosen.ownerNoteId,
      operation: 'resolve:${chosen.revisionId}',
      files: await repo.readFiles(chosen),
      parents: () async =>
          (await repo.heads(chosen.entityId))
              .map((head) => head.revisionId)
              .toList(),
      deleted: chosen.deleted,
      baseRefs: chosen.baseRefs,
    );
  });

  Future<void> restoreInkRevision(
    RevisionRecord chosen, {
    required List<String> expectedHeadRevisionIds,
    Map<String, List<String>>? expectedHeads,
  }) {
    final expected = List<String>.unmodifiable(expectedHeadRevisionIds);
    final guards = expectedHeads == null
        ? null
        : _immutableRestoreHeads(expectedHeads);
    return _write((repo, target) async {
      final plan = await _prepareInkRestore(
        repo,
        target,
        chosen,
        expected,
        guards,
      );
      await _publishInkRestore(repo, target, plan, null);
    });
  }

  Future<PreparedPageRestore> prepareInkRevisionRestore(
    RevisionRecord chosen, {
    required List<String> expectedHeadRevisionIds,
    Map<String, List<String>>? expectedHeads,
  }) {
    final expected = List<String>.unmodifiable(expectedHeadRevisionIds);
    final guards = expectedHeads == null
        ? null
        : _immutableRestoreHeads(expectedHeads);
    return _write(
      (repo, target) =>
          _prepareInkRestore(repo, target, chosen, expected, guards),
    );
  }

  Future<PreparedPageRestore> resumeInkRevisionRestore(
    Map<String, dynamic> descriptor,
  ) {
    final Map<String, dynamic> json;
    try {
      json = jsonObject(jsonDecode(jsonEncode(descriptor)));
    } on Object {
      return Future.error(
        const FormatException('Invalid page restore plan JSON'),
      );
    }
    return _write((repo, target) async {
      if (json.length != 4 ||
          !json.keys.toSet().containsAll({
            'version',
            'selectedRevisionId',
            'expectedHeads',
            'prepared',
          }) ||
          json['version'] is! int ||
          json['version'] != 1 ||
          json['selectedRevisionId'] is! String)
        throw const FormatException('Invalid page restore plan');
      final selectedId = json['selectedRevisionId'] as String;
      validateId(selectedId);
      final guards = _decodeRestoreHeads(jsonObject(json['expectedHeads']));
      final records = await repo.revisions();
      final selected = _ownedPageRevision(repo, target, records, selectedId);
      final files = await repo.readFiles(selected);
      final prepared = repo.resumePreparedCommit(
        descriptor: jsonObject(json['prepared']),
        files: files,
      );
      final plan = PreparedPageRestore._(prepared, selectedId, guards);
      await _validateRestorePlan(
        repo,
        target,
        plan,
        records: records,
        selectedFiles: files,
      );
      return plan;
    });
  }

  Future<RevisionRecord> publishInkRevisionRestore(
    PreparedPageRestore plan, {
    void Function()? requireWrite,
  }) => _write(
    (repo, target) => _publishInkRestore(repo, target, plan, requireWrite),
  );

  Future<Map<String, List<String>>> captureInkRevisionRestoreHeads(
    RevisionRecord observed,
  ) => _write((repo, target) async {
    _requireLivePage(target);
    final records = await repo.revisions();
    final actual = _ownedPageRevision(
      repo,
      target,
      records,
      observed.revisionId,
    );
    if (!_sameRecord(actual, observed))
      throw const FormatException('The observed page revision was changed');
    final guards = await _restoreHeads(repo, target, actual, records);
    await _requireRestoreHeads(repo, guards);
    return guards;
  });

  Future<void> validateInkRevisionRestoreHeads(
    Map<String, List<String>> expectedHeads,
  ) {
    final guards = _immutableRestoreHeads(expectedHeads);
    return _write((repo, target) async {
      _requireLivePage(target);
      final records = await repo.revisions();
      final body = guards[target.inkEntityId];
      if (body == null || body.length != 1)
        throw const FormatException('Missing observed page revision');
      final observed = _ownedPageRevision(repo, target, records, body.single);
      await _restoreHeads(
        repo,
        target,
        observed,
        records,
        expectedHeads: guards,
      );
      await _requireRestoreHeads(repo, guards);
    });
  }

  Future<
    ({
      RevisionRecord current,
      List<RevisionRecord> revisions,
      Map<String, List<String>> expectedHeads,
    })
  >
  captureDatabaseHistory() => _write((repo, target) async {
    _requireLiveDatabase(repo, target);
    final records = await repo.revisions();
    final heads = await repo.heads(target.inkEntityId);
    if (heads.length != 1) {
      throw StateError(
        'Resolve database revision conflicts before opening history',
      );
    }
    final current = _ownedDatabaseRevision(
      repo,
      target,
      records,
      heads.single.revisionId,
    );
    if (!_sameRecord(current, heads.single)) {
      throw const FormatException('The observed database revision was changed');
    }
    final revisions = _databaseHistoryOrder(repo, target, records, current);
    final guards = await _restoreHeads(
      repo,
      target,
      current,
      records,
      documentKind: VaultDocumentKind.database,
    );
    await _requireRestoreHeads(
      repo,
      guards,
      documentKind: VaultDocumentKind.database,
    );
    return (
      current: current,
      revisions: List<RevisionRecord>.unmodifiable(revisions),
      expectedHeads: guards,
    );
  });

  Future<void> validateDatabaseRevisionRestoreHeads(
    Map<String, List<String>> expectedHeads,
    RevisionRecord observed,
  ) {
    final guards = _immutableRestoreHeads(expectedHeads);
    return _write((repo, target) async {
      _requireLiveDatabase(repo, target);
      final records = await repo.revisions();
      final current = _observedDatabaseRevision(repo, target, records, guards);
      if (!_sameRecord(current, observed)) {
        throw const FormatException(
          'The observed database revision was changed',
        );
      }
      await _restoreHeads(
        repo,
        target,
        current,
        records,
        expectedHeads: guards,
        documentKind: VaultDocumentKind.database,
      );
      await _requireRestoreHeads(
        repo,
        guards,
        documentKind: VaultDocumentKind.database,
      );
    });
  }

  Future<void> restoreDatabaseRevision(
    RevisionRecord chosen, {
    required Map<String, List<String>> expectedHeads,
    required RevisionRecord observed,
    void Function(WorkspaceDatabase)? validateActions,
    void Function()? requireWrite,
  }) {
    final guards = _immutableRestoreHeads(expectedHeads);
    return _write((repo, target) async {
      _requireLiveDatabase(repo, target);
      requireWrite?.call();
      final records = await repo.revisions();
      final current = _observedDatabaseRevision(repo, target, records, guards);
      if (!_sameRecord(current, observed)) {
        throw const FormatException(
          'The observed database revision was changed',
        );
      }
      final selected = _databaseHistoryOrder(
        repo,
        target,
        records,
        current,
      ).where((record) => record.revisionId == chosen.revisionId).singleOrNull;
      if (selected == null || !_sameRecord(selected, chosen)) {
        throw const FormatException(
          'The selected revision is not owned database history',
        );
      }
      if (selected.revisionId == current.revisionId) {
        throw StateError('Select an earlier database revision');
      }
      await _restoreHeads(
        repo,
        target,
        current,
        records,
        expectedHeads: guards,
        documentKind: VaultDocumentKind.database,
      );
      final operation =
          'database-restore:${selected.revisionId}:${current.revisionId}';
      final pending = _pending[target.inkEntityId];
      final pendingGuards = pending?.$3;
      if (pending?.$1 != operation ||
          pendingGuards == null ||
          !_sameRestoreHeads(pendingGuards, guards)) {
        await _requireRestoreHeads(
          repo,
          guards,
          documentKind: VaultDocumentKind.database,
        );
      }
      for (final revision in [selected, current]) {
        final length = revision.blobs.values.fold(
          0,
          (total, ref) => total + ref.length,
        );
        if (length > DatabaseMediaSnapshot.maxSnapshotBytes) {
          throw const FormatException(
            'Database snapshot must be at most 128 MiB',
          );
        }
      }
      final selectedFiles = await repo.readFiles(selected);
      final currentFiles = await repo.readFiles(current);
      final restored = await _prepareDatabaseRestore(
        selectedFiles,
        currentFiles,
      );
      requireWrite?.call();
      if (validateActions == null && restored.needsNativeValidation) {
        throw StateError(
          'Automation validation is required for this database restore',
        );
      }
      validateActions?.call(restored.database);
      await _saveFiles(
        repo,
        target,
        entityId: target.inkEntityId,
        kind: EntityKind.ink,
        ownerNoteId: target.id,
        operation: operation,
        files: restored.files,
        parents: () async => [current.revisionId],
        baseRefs: selected.baseRefs,
        expectedHeads: guards,
        requireWrite: requireWrite,
      );
    });
  }

  RevisionRecord _observedDatabaseRevision(
    NoteRepository repo,
    VaultNote target,
    List<RevisionRecord> records,
    Map<String, List<String>> guards,
  ) {
    final observed = guards[target.inkEntityId]?.singleOrNull;
    if (observed == null) {
      throw const FormatException('Missing observed database revision');
    }
    return _ownedDatabaseRevision(repo, target, records, observed);
  }

  RevisionRecord _ownedDatabaseRevision(
    NoteRepository repo,
    VaultNote target,
    List<RevisionRecord> records,
    String revisionId,
  ) {
    final record = records
        .where((record) => record.revisionId == revisionId)
        .singleOrNull;
    if (record == null ||
        !_belongsToDatabase(repo, target, record) ||
        record.deleted ||
        !record.blobs.containsKey('database.json')) {
      throw const FormatException(
        'The revision is not live owned database history',
      );
    }
    return record;
  }

  bool _belongsToDatabase(
    NoteRepository repo,
    VaultNote target,
    RevisionRecord record,
  ) =>
      record.vaultId == repo.vaultId &&
      record.formatVersion == 2 &&
      record.entityId == target.inkEntityId &&
      record.ownerNoteId == target.id &&
      record.kind == EntityKind.ink;

  List<RevisionRecord> _databaseHistoryOrder(
    NoteRepository repo,
    VaultNote target,
    List<RevisionRecord> records,
    RevisionRecord current,
  ) {
    final owned = {
      for (final record in records)
        if (_belongsToDatabase(repo, target, record)) record.revisionId: record,
    };
    final children = <String, int>{current.revisionId: 0};
    final seen = <String>{};
    final remaining = [current];
    while (remaining.isNotEmpty) {
      final record = remaining.removeLast();
      if (!seen.add(record.revisionId)) continue;
      for (final id in record.parentRevisionIds) {
        final parent = owned[id];
        if (parent == null)
          throw const FormatException('Missing database revision ancestor');
        children.update(id, (count) => count + 1, ifAbsent: () => 1);
        remaining.add(parent);
      }
    }
    final ready = HeapPriorityQueue<String>()
      ..addAll(children.keys.where((id) => children[id] == 0));
    final revisions = <RevisionRecord>[];
    var visited = 0;
    while (ready.isNotEmpty) {
      final record = owned[ready.removeFirst()]!;
      visited++;
      if (!record.deleted && record.blobs.containsKey('database.json'))
        revisions.add(record);
      for (final parent in record.parentRevisionIds) {
        if (children.update(parent, (count) => count - 1) == 0)
          ready.add(parent);
      }
    }
    if (visited != seen.length)
      throw const FormatException('Invalid database revision graph');
    return revisions;
  }

  void _requireLiveDatabase(NoteRepository repo, VaultNote target) {
    if (repo.formatVersion != 2 ||
        target.documentKind != VaultDocumentKind.database ||
        target.trashed ||
        target.deletionConflict) {
      throw StateError(
        'Open a live format-2 database before restoring history',
      );
    }
  }

  Future<PreparedPageRestore> _prepareInkRestore(
    NoteRepository repo,
    VaultNote target,
    RevisionRecord chosen,
    List<String> expected,
    Map<String, List<String>>? expectedHeads,
  ) async {
    _requireLivePage(target);
    if (expected.length != 1)
      throw StateError('Restore requires one observed page head');
    validateId(expected.single);
    final records = await repo.revisions();
    final selected = _ownedPageRevision(
      repo,
      target,
      records,
      chosen.revisionId,
    );
    if (!_sameRecord(selected, chosen))
      throw const FormatException(
        'The selected revision is not owned page history',
      );
    final observed = _ownedPageRevision(repo, target, records, expected.single);
    final files = await repo.readFiles(selected);
    await _validatePageFiles(files);
    final operation = 'restore:${selected.revisionId}:${observed.revisionId}';
    final previous = _pending[target.inkEntityId];
    if (previous != null) {
      final previousGuards = previous.$3;
      if (previous.$1 == operation &&
          previous.$2.matchesFiles(files) &&
          previousGuards != null &&
          (expectedHeads == null ||
              _sameRestoreHeads(previousGuards, expectedHeads))) {
        final plan = PreparedPageRestore._(
          previous.$2,
          selected.revisionId,
          previousGuards,
        );
        await _validateRestorePlan(
          repo,
          target,
          plan,
          records: records,
          selectedFiles: files,
        );
        return plan;
      }
      if (previousGuards != null)
        await _discardStaleConditional(
          repo,
          target.inkEntityId,
          previous.$2,
          previousGuards,
        );
      if (identical(_pending[target.inkEntityId]?.$2, previous.$2))
        throw StateError(
          'Retry the pending page save before restoring another revision',
        );
    }
    final guards = await _restoreHeads(
      repo,
      target,
      observed,
      records,
      expectedHeads: expectedHeads,
    );
    await _requireRestoreHeads(repo, guards);
    return PreparedPageRestore._(
      repo.prepareCommit(
        entityId: target.inkEntityId,
        kind: EntityKind.ink,
        ownerNoteId: target.id,
        files: files,
        parentRevisionIds: expected,
        baseRefs: selected.baseRefs,
      ),
      selected.revisionId,
      guards,
    );
  }

  Future<RevisionRecord> _publishInkRestore(
    NoteRepository repo,
    VaultNote target,
    PreparedPageRestore plan,
    void Function()? requireWrite,
  ) async {
    final existing = await _validateRestorePlan(repo, target, plan);
    if (existing != null)
      return _acknowledgeRestore(
        repo,
        target,
        plan._prepared,
        existing,
        requireWrite,
      );
    _requireLivePage(target);
    final operation =
        'restore:${plan.selectedRevisionId}:${plan.record.parentRevisionIds.single}';
    final previous = _pending[target.inkEntityId];
    if (previous != null &&
        previous.$2.record.revisionId != plan.record.revisionId) {
      if (previous.$3 != null)
        await _discardStaleConditional(
          repo,
          target.inkEntityId,
          previous.$2,
          previous.$3!,
        );
      if (identical(_pending[target.inkEntityId]?.$2, previous.$2))
        throw StateError('Retry the exact pending page restore first');
    }
    _pending[target.inkEntityId] = (
      operation,
      plan._prepared,
      plan.expectedHeads,
      requireWrite,
    );
    return _publish(
      repo,
      target,
      target.inkEntityId,
      plan._prepared,
      plan.expectedHeads,
      requireWrite,
    );
  }

  Future<RevisionRecord?> _validateRestorePlan(
    NoteRepository repo,
    VaultNote target,
    PreparedPageRestore plan, {
    List<RevisionRecord>? records,
    Map<String, Uint8List>? selectedFiles,
  }) async {
    if (!plan._prepared.belongsTo(repo) ||
        target.documentKind != VaultDocumentKind.page ||
        plan.record.entityId != target.inkEntityId ||
        plan.record.ownerNoteId != target.id ||
        plan.record.kind != EntityKind.ink ||
        plan.record.deleted ||
        plan.record.parentRevisionIds.length != 1)
      throw const FormatException(
        'The page restore plan has a foreign identity',
      );
    records ??= await repo.revisions();
    final selected = _ownedPageRevision(
      repo,
      target,
      records,
      plan.selectedRevisionId,
    );
    final observed = _ownedPageRevision(
      repo,
      target,
      records,
      plan.record.parentRevisionIds.single,
    );
    await _restoreHeads(
      repo,
      target,
      observed,
      records,
      expectedHeads: plan.expectedHeads,
    );
    final files = selectedFiles ?? await repo.readFiles(selected);
    await _validatePageFiles(files);
    if (!plan._prepared.matchesFiles(files) ||
        jsonEncode(plan.record.toJson()['baseRefs']) !=
            jsonEncode(selected.toJson()['baseRefs']))
      throw const FormatException(
        'The page restore plan does not match the selected files',
      );
    final existing = records
        .where((r) => r.revisionId == plan.record.revisionId)
        .singleOrNull;
    if (existing != null && !_sameRecord(existing, plan.record))
      throw const FormatException(
        'The page restore revision identity is already in use',
      );
    return existing;
  }

  RevisionRecord _ownedPageRevision(
    NoteRepository repo,
    VaultNote target,
    List<RevisionRecord> records,
    String revisionId,
  ) {
    final record = records
        .where((r) => r.revisionId == revisionId)
        .singleOrNull;
    if (record == null ||
        record.vaultId != repo.vaultId ||
        record.entityId != target.inkEntityId ||
        record.ownerNoteId != target.id ||
        record.kind != EntityKind.ink ||
        record.deleted)
      throw const FormatException(
        'The revision is not live owned page history',
      );
    return record;
  }

  bool _sameRecord(RevisionRecord left, RevisionRecord right) =>
      jsonEncode(left.toJson()) == jsonEncode(right.toJson());

  void _requireLivePage(VaultNote target) {
    if (target.documentKind != VaultDocumentKind.page ||
        target.trashed ||
        target.deletionConflict)
      throw StateError('Open a live block page before restoring history');
  }

  Future<void> _validatePageFiles(Map<String, Uint8List> files) async {
    await decodeBlockPageMediaInWorker(files);
  }

  Map<String, List<String>> _decodeRestoreHeads(Map<String, dynamic> json) {
    final heads = <String, List<String>>{};
    for (final entry in json.entries) {
      validateId(entry.key);
      final value = entry.value;
      if (value is! List || value.length != 1 || value.single is! String)
        throw const FormatException('Invalid page restore head guard');
      validateId(value.single as String);
      heads[entry.key] = [value.single as String];
    }
    return _immutableRestoreHeads(heads);
  }

  Future<Map<String, List<String>>> _restoreHeads(
    NoteRepository repo,
    VaultNote target,
    RevisionRecord observed,
    List<RevisionRecord> records, {
    Map<String, List<String>>? expectedHeads,
    VaultDocumentKind documentKind = VaultDocumentKind.page,
  }) async {
    RevisionRecord historical(String entityId, EntityKind kind) {
      final ids = expectedHeads?[entityId];
      if (ids == null || ids.length != 1)
        throw const FormatException('Missing page restore head guard');
      final record = records
          .where((r) => r.revisionId == ids.single)
          .singleOrNull;
      if (record == null ||
          record.vaultId != repo.vaultId ||
          record.entityId != entityId ||
          record.kind != kind ||
          record.deleted)
        throw const FormatException('Invalid historical page restore guard');
      return record;
    }

    Future<RevisionRecord> current(String entityId, EntityKind kind) async {
      final heads = await repo.heads(entityId);
      if (heads.length != 1 ||
          heads.single.kind != kind ||
          heads.single.deleted)
        throw StateError('Reopen the live unambiguous page before restoring');
      return heads.single;
    }

    if (expectedHeads != null &&
        (expectedHeads[target.inkEntityId]?.length != 1 ||
            expectedHeads[target.inkEntityId]!.single != observed.revisionId))
      throw const FormatException(
        'The observed body does not match the restore guard',
      );
    final metadataHead = expectedHeads == null
        ? await current(target.id, EntityKind.metadata)
        : historical(target.id, EntityKind.metadata);
    final metadataFiles = await repo.readFiles(metadataHead);
    final metadataBytes = metadataFiles['note.json'];
    if (metadataBytes == null)
      throw const FormatException('Missing note metadata');
    final metadata = jsonObject(jsonDecode(utf8.decode(metadataBytes)));
    if (metadata['inkEntityId'] != target.inkEntityId ||
        metadata['markdownEntityId'] != target.markdownEntityId ||
        metadata['documentKind'] != documentKind.name)
      throw FormatException(
        'The saved ${documentKind.name} identity changed before restoring',
      );
    final rawFolderId = metadata['folderId'];
    if (rawFolderId != null && rawFolderId is! String)
      throw const FormatException('Invalid folder identity');
    var folderId = rawFolderId as String?;
    if (expectedHeads == null)
      await LibraryStore(repo).validateDestination(folderId);
    final ancestryHeads = <String, List<String>>{
      target.inkEntityId: [observed.revisionId],
      target.id: [metadataHead.revisionId],
    };
    while (folderId != null) {
      validateId(folderId);
      if (ancestryHeads.containsKey(folderId)) {
        if (expectedHeads != null)
          throw const FormatException(
            'The page restore ancestry contains a cycle',
          );
        throw StateError('The page folder ancestry contains a cycle');
      }
      final folderHead = expectedHeads == null
          ? await current(folderId, EntityKind.folder)
          : historical(folderId, EntityKind.folder);
      final folderFiles = await repo.readFiles(folderHead);
      final folderBytes = folderFiles['folder.json'];
      if (folderBytes == null)
        throw const FormatException('Missing folder metadata');
      final folder = jsonObject(jsonDecode(utf8.decode(folderBytes)));
      final parentId = folder['parentId'];
      if (folder['title'] is! String || parentId != null && parentId is! String)
        throw const FormatException('Invalid folder metadata');
      ancestryHeads[folderId] = [folderHead.revisionId];
      folderId = parentId as String?;
    }
    if (expectedHeads != null &&
        !_sameRestoreHeads(ancestryHeads, expectedHeads))
      throw const FormatException(
        'The restore guards do not match the complete page ancestry',
      );
    return _immutableRestoreHeads(ancestryHeads);
  }

  Future<void> _requireRestoreHeads(
    NoteRepository repo,
    Map<String, List<String>> guards, {
    VaultDocumentKind documentKind = VaultDocumentKind.page,
  }) async {
    for (final entry in guards.entries) {
      final current = (await repo.heads(entry.key))
          .map((r) => r.revisionId)
          .toSet();
      if (current.length != entry.value.length ||
          !current.containsAll(entry.value))
        throw StateError(
          'The ${documentKind.name} or its folder heads changed; compare again',
        );
    }
  }

  Future<T> _write<T>(
    Future<T> Function(NoteRepository repo, VaultNote target) action,
  ) {
    final repo = repository;
    final target = note;
    final scope = (
      repo.root.absolute.uri.normalizePath().toString(),
      repo.vaultId,
      repo.deviceId,
      repo.formatVersion,
    );
    final next = _writeTail.then((_) async {
      if (scope !=
          (
            repository.root.absolute.uri.normalizePath().toString(),
            repository.vaultId,
            repository.deviceId,
            repository.formatVersion,
          ))
        throw StateError('The session repository changed during a save');
      _requireNote(target);
      return action(repository, target);
    });
    _writeTail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  void _requireNote(VaultNote target) {
    if (note.id != target.id ||
        note.inkEntityId != target.inkEntityId ||
        note.markdownEntityId != target.markdownEntityId) {
      throw StateError('The session note changed during a save');
    }
  }

  Future<void> _saveFiles(
    NoteRepository repo,
    VaultNote target, {
    required String entityId,
    required EntityKind kind,
    required String? ownerNoteId,
    required String operation,
    required Map<String, Uint8List> files,
    required Future<List<String>> Function() parents,
    bool deleted = false,
    Map<String, List<String>> baseRefs = const {},
    Map<String, List<String>>? expectedHeads,
    void Function()? requireWrite,
  }) async {
    if (requireWrite != null && expectedHeads == null)
      throw StateError('Write validation requires observed revision heads');
    requireWrite?.call();
    final previous = _pending[entityId];
    if (previous != null) {
      final same =
          previous.$1 == operation &&
          previous.$2.matchesFiles(files) &&
          (expectedHeads == null ||
              previous.$3 != null &&
                  _sameRestoreHeads(previous.$3!, expectedHeads));
      if (expectedHeads != null && !same) {
        final previousGuards = previous.$3;
        if (previousGuards != null)
          await _discardStaleConditional(
            repo,
            entityId,
            previous.$2,
            previousGuards,
          );
        if (identical(_pending[entityId]?.$2, previous.$2))
          throw StateError(
            'Retry the pending page save before restoring another revision',
          );
      } else {
        final previousWrite = previous.$4;
        final void Function()? validatePending =
            previousWrite == null && requireWrite == null
            ? null
            : () {
                previousWrite?.call();
                requireWrite?.call();
              };
        await _publish(
          repo,
          target,
          entityId,
          previous.$2,
          previous.$3,
          validatePending,
        );
        if (same) return;
      }
    }
    final parentIds = await parents();
    final prepared = repo.prepareCommit(
      entityId: entityId,
      kind: kind,
      ownerNoteId: ownerNoteId,
      files: files,
      parentRevisionIds: parentIds,
      deleted: deleted,
      baseRefs: baseRefs,
    );
    final guards = expectedHeads == null
        ? null
        : Map<String, List<String>>.unmodifiable({
            for (final entry in expectedHeads.entries)
              entry.key: List<String>.unmodifiable(entry.value),
          });
    _pending[entityId] = (operation, prepared, guards, requireWrite);
    await _publish(repo, target, entityId, prepared, guards, requireWrite);
  }

  Future<RevisionRecord> _publish(
    NoteRepository repo,
    VaultNote target,
    String entityId,
    PreparedCommit prepared,
    Map<String, List<String>>? expectedHeads,
    void Function()? requireWrite,
  ) async {
    _requireNote(target);
    if (!prepared.belongsTo(repository))
      throw StateError('The session repository changed during a save');
    final RevisionRecord record;
    try {
      requireWrite?.call();
      if (expectedHeads != null) {
        final existing = (await repo.revisions())
            .where((r) => r.revisionId == prepared.record.revisionId)
            .singleOrNull;
        if (existing != null) {
          if (!_sameRecord(existing, prepared.record))
            throw const FormatException(
              'Immutable page restore revision collision',
            );
          return await _acknowledgeRestore(
            repo,
            target,
            prepared,
            existing,
            requireWrite,
          );
        }
      }
      record = expectedHeads == null
          ? await repo.commitPrepared(prepared)
          : await repo.commitPreparedIfHeads(
              prepared,
              expectedHeads: expectedHeads,
              beforePublish: () {
                requireWrite?.call();
                _requireNote(target);
                if (!prepared.belongsTo(repository))
                  throw StateError(
                    'The session repository changed during a save',
                  );
              },
            );
    } on Object {
      if (expectedHeads != null) {
        await _discardStaleConditional(repo, entityId, prepared, expectedHeads);
      }
      rethrow;
    }
    _requireNote(target);
    if (!prepared.belongsTo(repository))
      throw StateError('The session repository changed during a save');
    _pending.remove(entityId);
    if (record.kind == EntityKind.markdown)
      markdownParents = [record.revisionId];
    if (record.kind == EntityKind.ink) inkParents = [record.revisionId];
    return record;
  }

  Future<RevisionRecord> _acknowledgeRestore(
    NoteRepository repo,
    VaultNote target,
    PreparedCommit prepared,
    RevisionRecord existing,
    void Function()? requireWrite,
  ) async {
    requireWrite?.call();
    _requireNote(target);
    if (!prepared.belongsTo(repository))
      throw StateError('The session repository changed during a save');
    final manifest = File(
      '${repo.root.path}/revisions/${existing.revisionId}.json',
    );
    final actual = RevisionRecord.fromJson(
      jsonObject(jsonDecode(await manifest.readAsString())),
    );
    if (!_sameRecord(actual, prepared.record))
      throw const FormatException(
        'The published page restore manifest was changed',
      );
    final heads = await repo.heads(existing.entityId);
    _requireNote(target);
    if (!prepared.belongsTo(repository))
      throw StateError('The session repository changed during a save');
    final parents = existing.kind == EntityKind.markdown
        ? markdownParents
        : inkParents;
    if (heads.length == 1 &&
        heads.single.revisionId == existing.revisionId &&
        parents.every(
          (id) =>
              id == existing.revisionId ||
              existing.parentRevisionIds.contains(id),
        )) {
      if (existing.kind == EntityKind.markdown)
        markdownParents = [existing.revisionId];
      else
        inkParents = [existing.revisionId];
    }
    if (_pending[existing.entityId]?.$2.record.revisionId ==
        existing.revisionId)
      _pending.remove(existing.entityId);
    return existing;
  }

  Future<void> _discardStaleConditional(
    NoteRepository repo,
    String entityId,
    PreparedCommit prepared,
    Map<String, List<String>> expectedHeads,
  ) async {
    if (!prepared.belongsTo(repo)) return;
    try {
      for (final entry in expectedHeads.entries) {
        final current = (await repo.heads(entry.key))
            .map((r) => r.revisionId)
            .toSet();
        final ownHead =
            entry.key == entityId &&
            current.length == 1 &&
            current.contains(prepared.record.revisionId);
        if (!ownHead &&
            (current.length != entry.value.length ||
                !current.containsAll(entry.value))) {
          if (identical(_pending[entityId]?.$2, prepared))
            _pending.remove(entityId);
          return;
        }
      }
    } on Object {
      // A read failure cannot establish whether the exact publication succeeded.
    }
  }
}
