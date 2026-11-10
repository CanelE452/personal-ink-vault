import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/vault/dataview_frontmatter.dart';
import 'package:saber/data/vault/knowledge_catalog.dart';
import 'package:saber/data/vault/library_store.dart';
import 'package:saber/data/vault/note_link.dart';
import 'package:saber/data/vault/structured_document_text.dart';
import 'package:saber/data/vault/workspace_store.dart';

typedef KnowledgeInvoke = Map<String, dynamic> Function(Map<String, Object?>);

const _bodyLinkRecoveryVersion = 1;
const _propertyLinkRecoveryVersion = 2;

bool knowledgeNoteDeletionObserved(
  RevisionRecord tombstone,
  List<RevisionRecord> capturedRevisions,
) {
  if (!tombstone.deleted || tombstone.kind != EntityKind.metadata) return false;
  final parents = capturedRevisions.expand((r) => r.parentRevisionIds).toSet();
  final heads = <String, List<String>>{};
  for (final record in capturedRevisions) {
    if (record.ownerNoteId == tombstone.entityId &&
        !parents.contains(record.revisionId)) {
      (heads[record.entityId] ??= []).add(record.revisionId);
    }
  }
  return _equalKnowledgeHeads(heads, tombstone.baseRefs);
}

class PreparedKnowledgeChange {
  new _(this._plan);
  final _PublicationPlan _plan;
  String get operation => _plan.operation;
  String get sourceRevisionId => _plan.oldRevision;
  RevisionRecord get record => _plan.steps.last.record;
  Map<String, Object?> toRecoveryDescriptor() => {
    'version': _plan.recoveryVersion,
    'operation': operation,
    'oldRevision': sourceRevisionId,
    'capturedHeads': {
      for (final e in _plan.initialHeads.entries) e.key: List.of(e.value),
    },
    'capturedRevisionIds': _plan.initialIds.toList(),
    'steps': [for (final step in _plan.steps) step.toRecoveryDescriptor()],
  };
  List<Map<String, Uint8List>> copyRecoveryFiles() => [
    for (final files in _plan.files)
      {for (final e in files.entries) e.key: Uint8List.fromList(e.value)},
  ];
  Future<void> publish(
    NoteRepository repository, {
    void Function()? requireWrite,
  }) {
    final coordinator = _renames[repository] ??= _RenameCoordinator();
    return coordinator.enqueue(() async {
      requireWrite?.call();
      var pending = coordinator.pending;
      if (pending != null && !await pending.canRetry(repository)) {
        coordinator.pending = null;
        pending = null;
      }
      if (pending != null &&
          !_same(
            pending.steps.map((s) => s.record.revisionId).toSet(),
            _plan.steps.map((s) => s.record.revisionId).toSet(),
          ))
        throw StateError('Retry the pending document or folder change first');
      if (_plan.steps.any((step) => !step.belongsTo(repository))) {
        throw const FormatException('Foreign prepared knowledge change');
      }
      if (_plan.next == _plan.steps.length) {
        for (final step in _plan.steps) {
          requireWrite?.call();
          await _verifyKnowledgeManifest(repository, step.record);
          await repository.confirmPublishedCommit(step);
        }
        requireWrite?.call();
        _requireKnowledgeDirectory(repository);
      }
      await _publishKnowledgePlan(
        repository,
        coordinator,
        _plan,
        requireWrite,
        null,
      );
    });
  }
}

Future<PreparedKnowledgeChange> resumePreparedKnowledgeChange(
  NoteRepository repository, {
  required Map<String, dynamic> descriptor,
  required List<Map<String, Uint8List>> files,
  KnowledgeInvoke? invoke,
  void Function()? requireWrite,
}) async {
  requireWrite?.call();
  const keys = {
    'version',
    'operation',
    'oldRevision',
    'capturedHeads',
    'capturedRevisionIds',
    'steps',
  };
  final recoveryVersion = descriptor['version'];
  if (descriptor.length != keys.length ||
      !descriptor.keys.toSet().containsAll(keys) ||
      recoveryVersion is! int ||
      (recoveryVersion != _bodyLinkRecoveryVersion &&
          recoveryVersion != _propertyLinkRecoveryVersion) ||
      descriptor['operation'] is! String ||
      descriptor['oldRevision'] is! String ||
      descriptor['steps'] is! List ||
      descriptor['capturedRevisionIds'] is! List) {
    throw const FormatException('Invalid prepared knowledge change');
  }
  final operation = descriptor['operation'] as String;
  final oldRevision = descriptor['oldRevision'] as String;
  validateId(oldRevision);
  final ids = <String>{};
  for (final id in descriptor['capturedRevisionIds'] as List) {
    if (id is! String)
      throw const FormatException('Invalid captured revision identity');
    validateId(id);
    if (!ids.add(id))
      throw const FormatException('Duplicate captured revision identity');
  }
  final actual = {
    for (final record in await repository.revisions())
      record.revisionId: record,
  };
  if (!ids.contains(oldRevision) || ids.any((id) => !actual.containsKey(id))) {
    throw const FormatException('Missing original knowledge change revisions');
  }
  final original = [for (final id in ids) actual[id]!];
  for (final record in original) {
    if (record.parentRevisionIds.any((id) => !ids.contains(id))) {
      throw const FormatException(
        'Incomplete original knowledge revision graph',
      );
    }
    await _verifyKnowledgeManifest(repository, record);
  }
  final descriptors = descriptor['steps'] as List;
  if (descriptors.isEmpty || descriptors.length != files.length) {
    throw const FormatException('Invalid prepared knowledge step files');
  }
  final steps = <PreparedCommit>[
    for (var i = 0; i < descriptors.length; i++)
      repository.resumePreparedCommit(
        descriptor: jsonObject(descriptors[i]),
        files: files[i],
      ),
  ];
  final stepIds = steps.map((s) => s.record.revisionId).toSet();
  if (stepIds.length != steps.length || stepIds.any(ids.contains)) {
    throw const FormatException('Reused knowledge change revision identity');
  }
  final replay = _ReplayRepository(repository, original, steps);
  final raw = jsonDecode(operation);
  if (raw is! List || raw.length < 3 || raw[1] is! String) {
    throw const FormatException('Invalid knowledge operation');
  }
  validateId(raw[1] as String);
  final source = original.singleWhere((r) => r.revisionId == oldRevision);
  if (source.entityId != raw[1])
    throw const FormatException('Foreign knowledge operation source');
  final sourceFiles = await replay.readFiles(source);
  _PublicationPlan? plan;
  if (raw[0] == 'rename' &&
      raw.length == 3 &&
      raw[2] is String &&
      source.kind == EntityKind.metadata) {
    final note = _recoveryNote(source, sourceFiles);
    plan = await _RenamePlan.create(
      replay,
      note,
      raw[2] as String,
      invoke,
      recoveryVersion: recoveryVersion,
    );
  } else if ((raw[0] == EntityKind.metadata.name ||
          raw[0] == EntityKind.folder.name) &&
      raw.length == 4 &&
      raw[0] == source.kind.name &&
      raw[2] is Map &&
      (raw[3] == null || raw[3] is bool)) {
    final changes = jsonObject(raw[2]);
    final allowed = source.kind == EntityKind.metadata
        ? {'folderId'}
        : {'parentId', 'title'};
    if (changes.keys.any((key) => !allowed.contains(key)) ||
        (raw[3] == null ? changes.length != 1 : changes.isNotEmpty)) {
      throw const FormatException('Invalid knowledge metadata change');
    }
    for (final entry in changes.entries) {
      if (entry.key == 'title') {
        if (entry.value is! String || (entry.value as String).trim().isEmpty) {
          throw const FormatException('Invalid knowledge title');
        }
      } else if (entry.value != null) {
        if (entry.value is! String)
          throw const FormatException('Invalid knowledge destination');
        validateId(entry.value as String);
      }
    }
    VaultNote? note;
    VaultFolder? folder;
    if (source.kind == EntityKind.metadata) {
      note = _recoveryNote(source, sourceFiles);
    } else {
      final metadata = jsonObject(
        jsonDecode(utf8.decode(sourceFiles['folder.json']!)),
      );
      final title = metadata['title'], parent = metadata['parentId'];
      if (title is! String || parent != null && parent is! String) {
        throw const FormatException('Invalid original folder metadata');
      }
      if (parent != null) validateId(parent as String);
      folder = VaultFolder(
        source.entityId,
        title,
        parent as String?,
        source,
        trashed: source.deleted,
      );
    }
    plan = await _preparePathChange(
      replay,
      operation,
      source,
      note,
      folder,
      changes,
      raw[3] as bool?,
      invoke,
      recoveryVersion: recoveryVersion,
    );
  } else {
    throw const FormatException('Unsupported knowledge recovery operation');
  }
  if (plan == null ||
      replay.next != steps.length ||
      plan.operation != operation ||
      !_equalKnowledgeHeads(
        plan.initialHeads,
        jsonObject(descriptor['capturedHeads']),
      )) {
    throw const FormatException(
      'Knowledge change does not match its original source snapshot',
    );
  }
  var prefix = 0;
  var missing = false;
  for (final step in steps) {
    _requireKnowledgeDirectory(repository);
    final manifest = File(
      p.join(
        repository.root.path,
        'revisions',
        '${step.record.revisionId}.json',
      ),
    );
    final type = FileSystemEntity.typeSync(manifest.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      if (actual.containsKey(step.record.revisionId)) {
        throw const FormatException(
          'A published knowledge manifest is missing',
        );
      }
      missing = true;
      continue;
    }
    if (missing || type != FileSystemEntityType.file) {
      throw const FormatException(
        'Knowledge publication is not an unchanged prefix',
      );
    }
    await _verifyKnowledgeManifest(repository, step.record);
    await repository.confirmPublishedCommit(step);
    prefix++;
  }
  final current = (await repository.revisions())
      .map((r) => r.revisionId)
      .toSet();
  if (prefix < steps.length &&
      !_same(current, {
        ...ids,
        ...steps.take(prefix).map((s) => s.record.revisionId),
      })) {
    throw StateError('Workspace changed before knowledge recovery');
  }
  for (final step in steps.take(prefix)) plan.acknowledge(step.record);
  requireWrite?.call();
  return PreparedKnowledgeChange._(plan);
}

Future<VaultNote> readCapturedKnowledgeNote(
  NoteRepository repository, {
  required List<String> revisionIds,
  required String sourceRevisionId,
}) async {
  validateId(sourceRevisionId);
  for (final id in revisionIds) validateId(id);
  final ids = revisionIds.toSet();
  if (ids.length != revisionIds.length || !ids.contains(sourceRevisionId)) {
    throw const FormatException('Invalid captured document snapshot');
  }
  final actual = {
    for (final record in await repository.revisions())
      record.revisionId: record,
  };
  if (ids.any((id) => !actual.containsKey(id))) {
    throw const FormatException('Missing captured document revision');
  }
  final records = [for (final id in revisionIds) actual[id]!];
  for (final record in records) {
    if (record.parentRevisionIds.any((id) => !ids.contains(id))) {
      throw const FormatException('Incomplete captured document graph');
    }
    await _verifyKnowledgeManifest(repository, record);
  }
  final notes = await WorkspaceStore(_SnapshotRepository(repository, records))
      .list(includeDeleted: true);
  final note = notes
      .where((n) => n.revision.revisionId == sourceRevisionId)
      .singleOrNull;
  if (note == null)
    throw const FormatException(
      'The captured document was not a metadata head',
    );
  return note;
}

VaultNote _recoveryNote(RevisionRecord source, Map<String, Uint8List> files) {
  final bytes = files['note.json'];
  if (bytes == null)
    throw const FormatException('Missing original document metadata');
  final metadata = jsonObject(jsonDecode(utf8.decode(bytes)));
  final title = metadata['title'],
      ink = metadata['inkEntityId'],
      markdown = metadata['markdownEntityId'];
  final folder = metadata['folderId'], original = metadata['sourceEntityId'];
  if (title is! String ||
      ink is! String ||
      markdown is! String ||
      folder != null && folder is! String ||
      original != null && original is! String) {
    throw const FormatException('Invalid original document metadata');
  }
  for (final id in [
    ink,
    markdown,
    if (folder != null) folder as String,
    if (original != null) original as String,
  ])
    validateId(id);
  final kind = metadata['documentKind'] == null
      ? VaultDocumentKind.handwriting
      : VaultDocumentKind.values
            .where((k) => k.name == metadata['documentKind'])
            .singleOrNull;
  if (kind == null)
    throw const FormatException('Unsupported original document kind');
  return VaultNote(
    source.entityId,
    title,
    ink,
    markdown,
    source,
    folderId: folder as String?,
    sourceEntityId: original as String?,
    documentKind: kind,
    trashed: source.deleted,
    metadata: metadata,
  );
}

bool _equalKnowledgeHeads(
  Map<String, List<String>> expected,
  Map<String, dynamic> actual,
) =>
    expected.length == actual.length &&
    expected.entries.every(
      (entry) =>
          actual[entry.key] is List &&
          (actual[entry.key] as List).every((id) => id is String) &&
          (actual[entry.key] as List).length == entry.value.length &&
          _same(
            entry.value.toSet(),
            (actual[entry.key] as List).cast<String>().toSet(),
          ),
    );

void _requireKnowledgeDirectory(NoteRepository repository) {
  final revisions = Directory(p.join(repository.root.path, 'revisions'));
  if (FileSystemEntity.typeSync(revisions.path, followLinks: false) !=
          FileSystemEntityType.directory ||
      !p.equals(
        revisions.resolveSymbolicLinksSync(),
        p.join(repository.root.resolveSymbolicLinksSync(), 'revisions'),
      )) {
    throw const FormatException(
      'Knowledge revisions must use the canonical directory',
    );
  }
}

Future<void> _verifyKnowledgeManifest(
  NoteRepository repository,
  RevisionRecord record,
) async {
  _requireKnowledgeDirectory(repository);
  final manifest = File(
    p.join(repository.root.path, 'revisions', '${record.revisionId}.json'),
  );
  if (FileSystemEntity.typeSync(manifest.path, followLinks: false) !=
      FileSystemEntityType.file) {
    throw const FormatException(
      'Knowledge source must be a canonical manifest',
    );
  }
  final handle = await manifest.open();
  try {
    _checkKnowledgeManifest(record, await handle.read(1024 * 1024 + 1));
  } finally {
    await handle.close();
  }
}

void _checkKnowledgeManifest(RevisionRecord record, Uint8List bytes) {
  if (bytes.length > 1024 * 1024) {
    throw const FormatException(
      'Knowledge source manifest exceeds the recovery limit',
    );
  }
  final actual = jsonObject(jsonDecode(utf8.decode(bytes)));
  if (_knowledgeJson(actual) != _knowledgeJson(record.toJson())) {
    throw const FormatException('Knowledge source manifest changed');
  }
}

String _knowledgeJson(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return '{${keys.map((key) => '${jsonEncode(key)}:${_knowledgeJson(value[key])}').join(',')}}';
  }
  if (value is List) return '[${value.map(_knowledgeJson).join(',')}]';
  return jsonEncode(value);
}

void _verifyKnowledgeSourceSync(
  NoteRepository repository,
  RevisionRecord record,
) {
  _requireKnowledgeDirectory(repository);
  final manifest = File(
    p.join(repository.root.path, 'revisions', '${record.revisionId}.json'),
  );
  if (FileSystemEntity.typeSync(manifest.path, followLinks: false) !=
      FileSystemEntityType.file) {
    throw const FormatException(
      'Knowledge source must be a canonical manifest',
    );
  }
  final manifestHandle = manifest.openSync();
  try {
    _checkKnowledgeManifest(record, manifestHandle.readSync(1024 * 1024 + 1));
  } finally {
    manifestHandle.closeSync();
  }
  for (final ref in record.blobs.values) {
    final file = File(p.join(repository.root.path, 'blobs', ref.hash));
    if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw const FormatException(
        'Knowledge source must use a regular immutable blob',
      );
    }
    final digest = _KnowledgeDigest();
    final hashing = sha256.startChunkedConversion(digest);
    final handle = file.openSync();
    var length = 0;
    try {
      while (true) {
        final remaining = ref.length - length + 1;
        final chunk = handle.readSync(remaining < 65536 ? remaining : 65536);
        if (chunk.isEmpty) break;
        length += chunk.length;
        if (length > ref.length)
          throw const FormatException('Knowledge source blob length changed');
        hashing.add(chunk);
      }
    } finally {
      handle.closeSync();
      hashing.close();
    }
    if (length != ref.length || digest.value.toString() != ref.hash) {
      throw const FormatException('Knowledge source blob changed');
    }
  }
}

class _KnowledgeDigest implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

final _renames = Expando<_RenameCoordinator>();

Future<void> renameKnowledgeNote(
  NoteRepository repository,
  VaultNote note,
  String title, {
  KnowledgeInvoke? invoke,
  void Function()? requireWrite,
  Future<void> Function(PreparedKnowledgeChange)? onPrepared,
}) {
  return _changeKnowledge(
    repository,
    jsonEncode(['rename', note.id, title]),
    note.revision.revisionId,
    () => _RenamePlan.create(repository, note, title, invoke),
    requireWrite,
    onPrepared,
  );
}

Future<void> _changeKnowledge(
  NoteRepository repository,
  String operation,
  String openedRevision,
  Future<_PublicationPlan?> Function() create,
  void Function()? requireWrite,
  Future<void> Function(PreparedKnowledgeChange)? onPrepared,
) {
  final coordinator = _renames[repository] ??= _RenameCoordinator();
  return coordinator.enqueue(() async {
    requireWrite?.call();
    var plan = coordinator.pending;
    if (plan != null && !await plan.canRetry(repository)) {
      coordinator.pending = null;
      plan = null;
    }
    if (plan != null && !plan.matches(operation, openedRevision)) {
      throw StateError('Retry the pending document or folder change first');
    }
    plan ??= await create();
    if (plan == null) return;
    await _publishKnowledgePlan(
      repository,
      coordinator,
      plan,
      requireWrite,
      onPrepared,
    );
  });
}

Future<void> _publishKnowledgePlan(
  NoteRepository repository,
  _RenameCoordinator coordinator,
  _PublicationPlan plan,
  void Function()? requireWrite,
  Future<void> Function(PreparedKnowledgeChange)? onPrepared,
) async {
  coordinator.pending = plan;
  try {
    await onPrepared?.call(PreparedKnowledgeChange._(plan));
    requireWrite?.call();
    for (final source in plan.validationSources) {
      _verifyKnowledgeSourceSync(repository, source);
    }
    await plan.publish(repository, requireWrite);
    coordinator.pending = null;
  } on Object {
    if (!await plan.canRetry(repository)) coordinator.pending = null;
    rethrow;
  }
}

class _RenameCoordinator {
  Future<void> _tail = Future.value();
  _PublicationPlan? pending;

  Future<void> enqueue(Future<void> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}

class _RenamePlan extends _PublicationPlan {
  new _(
    String noteId,
    String oldRevision,
    String title,
    List<PreparedCommit> steps,
    Map<String, List<String>> heads,
    Set<String> ids,
    List<Map<String, Uint8List>> files,
    List<RevisionRecord> validationSources,
    int recoveryVersion,
  ) : super(
        jsonEncode(['rename', noteId, title]),
        oldRevision,
        steps,
        heads,
        ids,
        files,
        validationSources,
        recoveryVersion,
      );

  static Future<_RenamePlan> create(
    NoteRepository repository,
    VaultNote note,
    String title,
    KnowledgeInvoke? invoke, {
    int recoveryVersion = _propertyLinkRecoveryVersion,
  }) async {
    if (repository.pendingRevisionCount != 0 ||
        repository.integrityIssues.isNotEmpty) {
      throw StateError(
        'Finish receiving or repair the workspace before renaming',
      );
    }
    final catalog = await KnowledgeCatalog.capture(repository);
    final targetHeads = catalog.heads[note.id] ?? const <RevisionRecord>[];
    final current = catalog.notes[note.id];
    final currentDeleted =
        targetHeads.length == 1 &&
        targetHeads.single.deleted &&
        note.revision.deleted &&
        note.trashed &&
        !note.deletionConflict &&
        current == null;
    if (targetHeads.length != 1 ||
        targetHeads.single.revisionId != note.revision.revisionId ||
        !currentDeleted &&
            (current == null ||
                current.length != 1 ||
                current.single.trashed ||
                current.single.deletionConflict)) {
      throw StateError(
        'Reopen the current unambiguous document before renaming',
      );
    }
    final metadataFiles = await repository.readFiles(note.revision);
    final bytes = metadataFiles['note.json'];
    if (bytes == null) throw const FormatException('Missing note metadata');
    final metadata = _JsonStrings(utf8.decode(bytes));
    final token = metadata.stringAt(['title']);
    if (token == null || token.value != note.title) {
      throw StateError(
        'The opened title no longer matches the source metadata',
      );
    }
    final nextMetadataFiles = <String, Uint8List>{
      ...metadataFiles,
      'note.json': _rewrittenBytes(bytes, metadata.replace({token: title})),
    };
    final lookupTitles = catalog.documents[note.id]?['lookupTitles'];
    final affectsLinks =
        !currentDeleted && !(lookupTitles is List && lookupTitles.isEmpty);
    final prospective =
        affectsLinks && recoveryVersion == _propertyLinkRecoveryVersion
        ? await _projectKnowledgeCatalog(
            repository,
            catalog,
            note.revision,
            nextMetadataFiles,
          )
        : null;
    final planner = _LinkPlanner.targets(
      catalog,
      {note.id},
      invoke,
      prospectiveDocuments: prospective?.documents.values.toList(),
    );
    final changed = <String, (RevisionRecord, Map<String, Uint8List>)>{};
    final checked = <String>{};
    for (final branches
        in affectsLinks ? catalog.notes.values : const <List<VaultNote>>[]) {
      for (final source in branches) {
        if (source.trashed) continue;
        for (final entity in [source.markdownEntityId, source.inkEntityId]) {
          final isMarkdown = entity == source.markdownEntityId;
          if (!isMarkdown &&
              !const {
                'page',
                'canvas',
                'database',
              }.contains(source.documentKind.name)) {
            continue;
          }
          for (final head
              in catalog.heads[entity] ?? const <RevisionRecord>[]) {
            if (head.deleted ||
                !checked.add('${head.revisionId}/${source.documentKind.name}'))
              continue;
            final files = await repository.readFiles(head);
            final rewritten = isMarkdown
                ? planner.markdown(
                    source.id,
                    files,
                    includeProperties:
                        recoveryVersion >= _propertyLinkRecoveryVersion &&
                        source.documentKind == VaultDocumentKind.markdown,
                  )
                : planner.structured(
                    source.id,
                    source.documentKind.name,
                    files,
                  );
            if (rewritten == null) continue;
            if ((catalog.heads[entity]?.length ?? 0) != 1 ||
                branches.length != 1 ||
                source.deletionConflict) {
              throw StateError(
                'Resolve the referenced source branch before renaming',
              );
            }
            if (head.ownerNoteId != source.id ||
                head.kind !=
                    (isMarkdown ? EntityKind.markdown : EntityKind.ink)) {
              throw StateError('The linked source has inconsistent ownership');
            }
            final previous = changed[entity];
            if (previous != null)
              throw StateError('The same source belongs to multiple documents');
            changed[entity] = (head, rewritten);
          }
        }
      }
    }
    final prepared = <PreparedCommit>[
      for (final (head, files) in changed.values)
        repository.prepareCommit(
          entityId: head.entityId,
          kind: head.kind,
          files: files,
          parentRevisionIds: [head.revisionId],
          ownerNoteId: head.ownerNoteId,
          deleted: head.deleted,
          baseRefs: head.baseRefs,
        ),
      repository.prepareCommit(
        entityId: note.id,
        kind: EntityKind.metadata,
        files: nextMetadataFiles,
        parentRevisionIds: [note.revision.revisionId],
        deleted: note.revision.deleted,
        baseRefs: note.revision.baseRefs,
      ),
    ];
    return _RenamePlan._(
      note.id,
      note.revision.revisionId,
      title,
      prepared,
      {
        for (final entry in catalog.heads.entries)
          entry.key: entry.value.map((r) => r.revisionId).toList(),
      },
      catalog.revisions.map((r) => r.revisionId).toSet(),
      [for (final (_, files) in changed.values) files, nextMetadataFiles],
      _knowledgeValidationSources(catalog, note.revision.revisionId, checked),
      recoveryVersion,
    );
  }
}

class _PublicationPlan {
  new(
    this.operation,
    this.oldRevision,
    this.steps,
    Map<String, List<String>> capturedHeads,
    Set<String> capturedIds,
    List<Map<String, Uint8List>> sourceFiles,
    this.validationSources,
    this.recoveryVersion,
  ) : heads = {for (final e in capturedHeads.entries) e.key: List.of(e.value)},
      ids = capturedIds.toSet(),
      initialHeads = {
        for (final e in capturedHeads.entries) e.key: List.of(e.value),
      },
      initialIds = capturedIds.toSet(),
      files = [
        for (final source in sourceFiles)
          {for (final e in source.entries) e.key: Uint8List.fromList(e.value)},
      ];
  final String operation;
  final String oldRevision;
  final List<PreparedCommit> steps;
  final Map<String, List<String>> heads;
  final Set<String> ids;
  final Map<String, List<String>> initialHeads;
  final Set<String> initialIds;
  final List<Map<String, Uint8List>> files;
  final List<RevisionRecord> validationSources;
  final int recoveryVersion;
  var next = 0;

  bool matches(String requested, String openedRevision) =>
      requested == operation &&
      (openedRevision == oldRevision ||
          openedRevision == steps.last.record.revisionId);

  void acknowledge(RevisionRecord published) {
    ids.add(published.revisionId);
    heads[published.entityId] = [
      ...?(heads[published.entityId]?.where(
        (id) => !published.parentRevisionIds.contains(id),
      )),
      published.revisionId,
    ];
    next++;
  }

  Future<void> publish(
    NoteRepository repository,
    void Function()? requireWrite,
  ) async {
    while (next < steps.length) {
      requireWrite?.call();
      final step = steps[next];
      void validateSources() {
        requireWrite?.call();
        _requireKnowledgeDirectory(repository);
        for (final source in validationSources) {
          if (next == steps.length - 1 ||
              step.record.parentRevisionIds.contains(source.revisionId)) {
            _verifyKnowledgeSourceSync(repository, source);
          }
        }
      }

      validateSources();
      final published = await repository.commitPreparedIfHeads(
        step,
        expectedHeads: heads,
        expectedRevisionIds: ids.toList(),
        beforePublish: () {
          validateSources();
        },
        allowHistoricalParents: !_same(
          (heads[step.record.entityId] ?? []).toSet(),
          step.record.parentRevisionIds.toSet(),
        ),
      );
      acknowledge(published);
    }
  }

  Future<bool> canRetry(NoteRepository repository) async {
    try {
      if (next >= steps.length ||
          repository.pendingRevisionCount != 0 ||
          repository.integrityIssues.isNotEmpty)
        return false;
      final records = await repository.revisions();
      final current = records.map((r) => r.revisionId).toSet();
      final step = steps[next].record;
      final ownPublished = current.contains(step.revisionId);
      if (!_same(current, {...ids, if (ownPublished) step.revisionId}))
        return false;
      final parents = records.expand((r) => r.parentRevisionIds).toSet();
      final actual = <String, Set<String>>{};
      for (final r in records.where((r) => !parents.contains(r.revisionId))) {
        (actual[r.entityId] ??= {}).add(r.revisionId);
      }
      return heads.entries.every(
        (entry) => _same(
          actual[entry.key] ?? {},
          ownPublished && entry.key == step.entityId
              ? {
                  ...entry.value.where(
                    (id) => !step.parentRevisionIds.contains(id),
                  ),
                  step.revisionId,
                }
              : entry.value.toSet(),
        ),
      );
    } on Object {
      // A read failure cannot establish whether publication happened.
      return true;
    }
  }
}

Future<void> changeKnowledgePath(
  NoteRepository repository, {
  VaultNote? note,
  VaultFolder? folder,
  Map<String, Object?> changes = const {},
  bool? deleted,
  KnowledgeInvoke? invoke,
  void Function()? requireWrite,
  Future<void> Function(PreparedKnowledgeChange)? onPrepared,
}) {
  final revision = note?.revision ?? folder!.revision;
  final operation = jsonEncode([
    revision.kind.name,
    revision.entityId,
    changes,
    deleted,
  ]);
  return _changeKnowledge(
    repository,
    operation,
    revision.revisionId,
    () => _preparePathChange(
      repository,
      operation,
      revision,
      note,
      folder,
      changes,
      deleted,
      invoke,
    ),
    requireWrite,
    onPrepared,
  );
}

Future<_PublicationPlan?> _preparePathChange(
  NoteRepository repository,
  String operation,
  RevisionRecord revision,
  VaultNote? note,
  VaultFolder? folder,
  Map<String, Object?> changes,
  bool? deleted,
  KnowledgeInvoke? invoke, {
  int recoveryVersion = _propertyLinkRecoveryVersion,
}) async {
  if (repository.pendingRevisionCount != 0 ||
      repository.integrityIssues.isNotEmpty) {
    throw StateError(
      'Finish receiving or repair the workspace before changing paths',
    );
  }
  final catalog = await KnowledgeCatalog.capture(repository);
  if (!catalog.revisions.any(
    (r) =>
        r.revisionId == revision.revisionId &&
        r.entityId == revision.entityId &&
        r.kind == revision.kind,
  )) {
    throw StateError(
      'The opened document or folder does not belong to this workspace',
    );
  }
  final metadataFiles = await repository.readFiles(revision);
  final name = note == null ? 'folder.json' : 'note.json';
  final bytes = metadataFiles[name];
  if (bytes == null) throw FormatException('Missing $name');
  final metadata = _JsonStrings(utf8.decode(bytes));
  final json = jsonObject(jsonDecode(metadata.text));
  if (json['title'] != (note?.title ?? folder!.title) ||
      (note != null &&
          (json['folderId'] != note.folderId ||
              json['inkEntityId'] != note.inkEntityId ||
              json['markdownEntityId'] != note.markdownEntityId)) ||
      (folder != null && json['parentId'] != folder.parentId)) {
    throw StateError(
      'The opened metadata no longer matches its original revision',
    );
  }
  final currentHeads =
      catalog.heads[revision.entityId] ?? const <RevisionRecord>[];
  final unchanged =
      changes.entries.every((e) => json[e.key] == e.value) &&
      (deleted == null || deleted == revision.deleted);
  final unchangedHead =
      unchanged &&
      currentHeads.length == 1 &&
      currentHeads.single.revisionId == revision.revisionId;
  if (unchangedHead &&
      (deleted != true ||
          note != null &&
              knowledgeNoteDeletionObserved(revision, catalog.revisions)))
    return null;
  if (deleted == false) {
    final captured = _SnapshotRepository(repository, catalog.revisions);
    final conflict = note != null
        ? (await WorkspaceStore(captured).list(includeDeleted: true))
              .where((n) => n.revision.revisionId == revision.revisionId)
              .singleOrNull
              ?.deletionConflict
        : (await LibraryStore(captured).listFolders(includeDeleted: true))
              .where((f) => f.revision.revisionId == revision.revisionId)
              .singleOrNull
              ?.deletionConflict;
    if (currentHeads.length != 1 ||
        currentHeads.single.revisionId != revision.revisionId ||
        conflict != false) {
      throw StateError(
        'Compare the current deletion and child changes before restoring',
      );
    }
  }
  if (changes.containsKey('folderId') || changes.containsKey('parentId')) {
    await LibraryStore(repository).validateDestination(
      (changes['folderId'] ?? changes['parentId']) as String?,
    );
  }
  final folders = <String>{if (folder != null) folder.id};
  final folderParents = <String, Set<String?>>{};
  final noteFolders = <String, Set<String?>>{};
  for (final entry in catalog.heads.entries) {
    for (final head in entry.value) {
      if (head.kind != EntityKind.folder && head.kind != EntityKind.metadata)
        continue;
      final files = await repository.readFiles(head);
      final raw = jsonObject(
        jsonDecode(
          utf8.decode(
            files[head.kind == EntityKind.folder
                ? 'folder.json'
                : 'note.json']!,
          ),
        ),
      );
      if (head.kind == EntityKind.folder) {
        (folderParents[head.entityId] ??= {}).add(raw['parentId'] as String?);
      } else {
        (noteFolders[head.entityId] ??= {}).add(raw['folderId'] as String?);
      }
    }
  }
  if (folder != null) {
    var added = true;
    while (added) {
      added = false;
      for (final entry in folderParents.entries) {
        if (entry.value.any(folders.contains) && folders.add(entry.key))
          added = true;
      }
    }
    if (changes['parentId'] != null && folders.contains(changes['parentId'])) {
      throw const FormatException('A folder cannot contain itself');
    }
  }
  final ownedNotes = <String>{
    if (note != null) note.id,
    if (folder != null)
      for (final entry in noteFolders.entries)
        if (entry.value.any(folders.contains)) entry.key,
  };
  final active = deleted != false && !revision.deleted;
  final repeatedTrash = deleted == true && revision.deleted;
  final affected = active || repeatedTrash
      ? ownedNotes.intersection(catalog.documents.keys.toSet())
      : <String>{};
  final movedSources = active ? affected : <String>{};
  final heads = <String, List<String>>{
    for (final entry in catalog.heads.entries)
      entry.key: entry.value.map((r) => r.revisionId).toList(),
  };
  final scope = <String>{
    if (folder != null) ...folders.difference({folder.id}),
    if (folder != null) ...ownedNotes,
    for (final entry in catalog.heads.entries)
      if (entry.value.any((r) => ownedNotes.contains(r.ownerNoteId))) entry.key,
  };
  if (unchangedHead &&
      deleted == true &&
      folder != null &&
      _equalKnowledgeHeads({
        for (final id in scope) id: heads[id] ?? <String>[],
      }, revision.baseRefs)) {
    return null;
  }
  final nextMetadataFiles = <String, Uint8List>{
    ...metadataFiles,
    if (changes.isNotEmpty)
      name: _rewrittenBytes(bytes, metadata.replaceFields(changes)),
  };
  List<Map<String, Object?>>? prospectiveDocuments;
  if (affected.isNotEmpty || deleted == false) {
    final prospective = await _projectKnowledgeCatalog(
      repository,
      catalog,
      revision,
      nextMetadataFiles,
      deleted: deleted,
      baseRefs: deleted == true
          ? {for (final id in scope) id: heads[id] ?? <String>[]}
          : null,
    );
    if (deleted != true &&
        prospective.pathIssues
            .difference(catalog.pathIssues)
            .any(
              (id) =>
                  affected.contains(id) &&
                  (prospective.notes[id]?.any(
                        (note) => note.obsidianAttachmentName != null,
                      ) ??
                      false),
            )) {
      throw const FormatException('가져온 첨부를 보존할 수 있는 폴더 이름이 필요합니다.');
    }
    prospectiveDocuments = prospective.documents.values.toList();
  }
  final changed = <String, (RevisionRecord, Map<String, Uint8List>)>{};
  final checked = <String>{};
  if (affected.isNotEmpty || deleted == false) {
    for (final branches in catalog.notes.values) {
      for (final source in branches) {
        if (source.trashed || repeatedTrash && ownedNotes.contains(source.id))
          continue;
        final planner = _LinkPlanner.targets(
          catalog,
          movedSources.contains(source.id)
              ? catalog.documents.keys.toSet()
              : affected,
          invoke,
          requireResolved: movedSources.contains(source.id),
          prospectiveDocuments: movedSources.contains(source.id)
              ? null
              : prospectiveDocuments,
          deletingPathIds: repeatedTrash ? ownedNotes : const {},
        );
        for (final entity in [source.markdownEntityId, source.inkEntityId]) {
          final markdown = entity == source.markdownEntityId;
          if (!markdown &&
              !const {
                'page',
                'canvas',
                'database',
              }.contains(source.documentKind.name))
            continue;
          for (final head
              in catalog.heads[entity] ?? const <RevisionRecord>[]) {
            if (head.deleted ||
                !checked.add('${head.revisionId}/${source.documentKind.name}'))
              continue;
            final files = await repository.readFiles(head);
            final rewritten = markdown
                ? planner.markdown(
                    source.id,
                    files,
                    includeProperties:
                        recoveryVersion >= _propertyLinkRecoveryVersion &&
                        source.documentKind == VaultDocumentKind.markdown,
                  )
                : planner.structured(
                    source.id,
                    source.documentKind.name,
                    files,
                  );
            if (rewritten == null) continue;
            if ((catalog.heads[entity]?.length ?? 0) != 1 ||
                branches.length != 1 ||
                source.deletionConflict) {
              throw StateError(
                'Resolve the referenced source branch before changing paths',
              );
            }
            if (head.ownerNoteId != source.id ||
                head.kind !=
                    (markdown ? EntityKind.markdown : EntityKind.ink)) {
              throw StateError('The linked source has inconsistent ownership');
            }
            if (changed.containsKey(entity)) {
              throw StateError('The same source belongs to multiple documents');
            }
            changed[entity] = (head, rewritten);
          }
        }
      }
    }
  }
  final steps = <PreparedCommit>[
    for (final (head, files) in changed.values)
      repository.prepareCommit(
        entityId: head.entityId,
        kind: head.kind,
        files: files,
        parentRevisionIds: [head.revisionId],
        ownerNoteId: head.ownerNoteId,
        deleted: head.deleted,
        baseRefs: head.baseRefs,
      ),
  ];
  final bases = <String, List<String>>{};
  if (deleted == true) {
    for (final id in scope) {
      final rewritten = steps
          .where((s) => s.record.entityId == id)
          .singleOrNull;
      bases[id] = rewritten == null
          ? List.of(heads[id] ?? [])
          : [rewritten.record.revisionId];
    }
  }
  steps.add(
    repository.prepareCommit(
      entityId: revision.entityId,
      kind: revision.kind,
      files: nextMetadataFiles,
      parentRevisionIds: [revision.revisionId],
      deleted: deleted ?? revision.deleted,
      baseRefs: deleted == true ? bases : revision.baseRefs,
    ),
  );
  return _PublicationPlan(
    operation,
    revision.revisionId,
    steps,
    heads,
    catalog.revisions.map((r) => r.revisionId).toSet(),
    [for (final (_, files) in changed.values) files, nextMetadataFiles],
    _knowledgeValidationSources(catalog, revision.revisionId, checked),
    recoveryVersion,
  );
}

Future<KnowledgeCatalog> _projectKnowledgeCatalog(
  NoteRepository repository,
  KnowledgeCatalog catalog,
  RevisionRecord revision,
  Map<String, Uint8List> files, {
  bool? deleted,
  Map<String, List<String>>? baseRefs,
}) {
  final projected = RevisionRecord.fromJson({
    ...revision.toJson(),
    'revisionId': newId(),
    'parentRevisionIds': [revision.revisionId],
    'deleted': deleted ?? revision.deleted,
    'baseRefs': baseRefs ?? revision.baseRefs,
  });
  return KnowledgeCatalog.capture(
    _SnapshotRepository(
      repository,
      [...catalog.revisions, projected],
      virtualFiles: {projected.revisionId: files},
    ),
  );
}

bool _same(Set<String> a, Set<String> b) =>
    a.length == b.length && a.containsAll(b);

List<RevisionRecord> _knowledgeValidationSources(
  KnowledgeCatalog catalog,
  String openedRevision,
  Set<String> checked,
) {
  final ids = {
    openedRevision,
    for (final key in checked) key.split('/').first,
    for (final branches in catalog.heads.values)
      for (final record in branches)
        if (record.kind == EntityKind.metadata ||
            record.kind == EntityKind.folder)
          record.revisionId,
  };
  return catalog.revisions
      .where((record) => ids.contains(record.revisionId))
      .toList();
}

class _SnapshotRepository implements NoteRepository {
  new(this.inner, this.records, {this.virtualFiles = const {}});
  final NoteRepository inner;
  final List<RevisionRecord> records;
  final Map<String, Map<String, Uint8List>> virtualFiles;
  @override
  Directory get root => inner.root;
  @override
  String get vaultId => inner.vaultId;
  @override
  String get deviceId => inner.deviceId;
  @override
  int get formatVersion => inner.formatVersion;
  @override
  int get pendingRevisionCount => inner.pendingRevisionCount;
  @override
  List<String> get integrityIssues => inner.integrityIssues;
  @override
  Future<List<RevisionRecord>> revisions() async => List.unmodifiable(records);
  @override
  Future<List<RevisionRecord>> heads(String id) async {
    final parents = records.expand((r) => r.parentRevisionIds).toSet();
    return records
        .where((r) => r.entityId == id && !parents.contains(r.revisionId))
        .toList();
  }

  @override
  Future<Map<String, Uint8List>> readFiles(RevisionRecord revision) async =>
      virtualFiles[revision.revisionId] ?? await inner.readFiles(revision);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ReplayRepository extends _SnapshotRepository {
  new(super.inner, super.records, this.steps);
  final List<PreparedCommit> steps;
  var next = 0;
  @override
  PreparedCommit prepareCommit({
    required String entityId,
    required EntityKind kind,
    required Map<String, Uint8List> files,
    required List<String> parentRevisionIds,
    String? ownerNoteId,
    bool deleted = false,
    Map<String, List<String>> baseRefs = const {},
  }) {
    if (next >= steps.length)
      throw const FormatException('Missing original knowledge change step');
    final step = steps[next];
    final record = step.record;
    if (record.entityId != entityId ||
        record.kind != kind ||
        record.ownerNoteId != ownerNoteId ||
        record.deleted != deleted ||
        jsonEncode(record.parentRevisionIds) != jsonEncode(parentRevisionIds) ||
        _knowledgeJson(record.baseRefs) != _knowledgeJson(baseRefs) ||
        !step.matchesFiles(files)) {
      throw const FormatException(
        'Prepared knowledge bytes or source association changed',
      );
    }
    next++;
    return step;
  }
}

class _LinkPlanner {
  const new targets(
    this.catalog,
    this.targetIds,
    this.invoke, {
    this.requireResolved = false,
    this.prospectiveDocuments,
    this.deletingPathIds = const {},
  });
  final KnowledgeCatalog catalog;
  final Set<String> targetIds;
  final KnowledgeInvoke? invoke;
  final bool requireResolved;
  final List<Map<String, Object?>>? prospectiveDocuments;
  final Set<String> deletingPathIds;

  Map<String, dynamic> analyze(
    String sourceId,
    String text,
    Iterable<Map<String, Object?>> documents,
  ) {
    if (invoke == null) {
      throw StateError(
        'The common link engine is required to preserve document references',
      );
    }
    return invoke!({
      'op': 'analyze_documents',
      'documents': [
        for (final document in documents)
          {...document, 'markdown': document['id'] == sourceId ? text : ''},
      ],
    });
  }

  Set<String> selectedTargets(String sourceId, String text) {
    final prospective = prospectiveDocuments;
    if (prospective == null || !_possibleReference(text)) return targetIds;
    List<Map<String, dynamic>> links(Map<String, dynamic> result) {
      final documents = result['documents'];
      if (documents is! List)
        throw const FormatException('Invalid link analysis result');
      final source = documents
          .map(jsonObject)
          .where((d) => d['id'] == sourceId)
          .singleOrNull;
      final values = source?['links'];
      if (values is! List)
        throw const FormatException('Missing analyzed source');
      return values.map(jsonObject).toList();
    }

    final before = links(analyze(sourceId, text, catalog.documents.values));
    final after = links(analyze(sourceId, text, prospective));
    if (before.length != after.length) {
      throw const FormatException('Inconsistent projected source references');
    }
    final selected = targetIds.toSet();
    for (var i = 0; i < before.length; i++) {
      final old = before[i], next = after[i];
      if (old['target'] != next['target'] || old['anchor'] != next['anchor']) {
        throw const FormatException(
          'Projected source reference changed identity',
        );
      }
      final id = old['targetId'];
      if (id is String &&
          (id != next['targetId'] ||
              old['attachmentName'] != next['attachmentName'])) {
        selected.add(id);
      }
    }
    return selected;
  }

  void verifyReferences(String sourceId, String text) {
    if (!requireResolved || !_possibleReference(text)) return;
    final result = analyze(sourceId, text, catalog.documents.values);
    final unresolved = result['unresolved'];
    if (unresolved is! List)
      throw const FormatException('Invalid link analysis result');
    for (final value in unresolved) {
      final link = jsonObject(value);
      final target = link['target'];
      if (target is! String)
        throw const FormatException('Invalid unresolved reference');
      if (!_stableReference(target)) {
        throw StateError(
          'Resolve ambiguous or missing document references before changing this source path',
        );
      }
    }
  }

  _TextRewrite rewrite(String sourceId, String text, {Set<String>? selected}) {
    final targets = selected ?? targetIds;
    if (targets.isEmpty || !_possibleReference(text))
      return _TextRewrite(text, const []);
    if (invoke == null)
      throw StateError(
        'The common link engine is required to preserve document references',
      );
    final result = invoke!({
      'op': 'rewrite_note_links',
      'documents': catalog.documents.values.toList(),
      'sourceId': sourceId,
      'text': text,
      if (targets.length == 1)
        'targetId': targets.single
      else
        'targetIds': targets.toList(),
    });
    if (result['unsupported'] is! List || result['replacements'] is! List)
      throw const FormatException('Invalid link rewrite result');
    if (catalog.pathIssues.difference(deletingPathIds).isNotEmpty &&
        ((result['unsupported'] as List).isNotEmpty ||
            (result['replacements'] as List).isNotEmpty)) {
      throw StateError(
        'An unresolved logical path could change the linked target',
      );
    }
    if ((result['unsupported'] as List).isNotEmpty)
      throw StateError(
        'A reference to this document cannot be safely rewritten',
      );
    final edits = <(int, int, String, String)>[];
    for (final item in result['replacements'] as List) {
      final edit = jsonObject(item);
      final start = edit['start'],
          end = edit['end'],
          original = edit['original'],
          replacement = edit['replacement'];
      if (start is! int ||
          end is! int ||
          original is! String ||
          replacement is! String ||
          start < 0 ||
          end <= start ||
          end > text.length ||
          !_boundary(text, start) ||
          !_boundary(text, end) ||
          text.substring(start, end) != original) {
        throw const FormatException('Unsafe link rewrite range');
      }
      final destination = _preserveNotionDatabaseView(original, replacement);
      if (original != destination) {
        edits.add((start, end, original, destination));
      }
    }
    edits.sort((a, b) => a.$1.compareTo(b.$1));
    var cursor = 0;
    final output = StringBuffer();
    final signatures = <String>[];
    for (final (start, end, original, replacement) in edits) {
      if (start < cursor)
        throw const FormatException('Overlapping link rewrite ranges');
      output.write(text.substring(cursor, start));
      output.write(replacement);
      signatures.add(jsonEncode([original, replacement]));
      cursor = end;
    }
    output.write(text.substring(cursor));
    return _TextRewrite(output.toString(), signatures, edits: edits);
  }

  String _preserveNotionDatabaseView(String original, String replacement) {
    final link = NoteLink.parse(replacement);
    if (link == null || !link.isMarkdown || link.markdownAnchor != null) {
      return replacement;
    }
    final target = catalog.notes[link.noteId]?.singleOrNull;
    if (target == null ||
        target.documentKind != VaultDocumentKind.database ||
        target.notionExportNames.isEmpty) {
      return replacement;
    }
    final previous = Uri.tryParse(original);
    if (previous == null ||
        previous.hasScheme ||
        previous.hasAuthority ||
        previous.hasQuery ||
        previous.hasFragment ||
        previous.pathSegments.lastOrNull?.toLowerCase().endsWith('.csv') !=
            true) {
      return replacement;
    }
    // The stable UUID wiki route keeps the DB grid and backlink identity.
    return 'inkwiki:${link.noteId}';
  }

  Map<String, Uint8List>? markdown(
    String sourceId,
    Map<String, Uint8List> files, {
    required bool includeProperties,
  }) {
    final bytes = files['summary.md'];
    if (bytes == null) throw const FormatException('Missing Markdown source');
    final original = utf8.decode(bytes);
    verifyReferences(sourceId, original);
    final body = rewrite(
      sourceId,
      original,
      selected: selectedTargets(sourceId, original),
    ).text;
    final next = includeProperties ? _rewriteProperties(sourceId, body) : body;
    return next == original
        ? null
        : {...files, 'summary.md': _rewrittenBytes(bytes, next)};
  }

  String _rewriteProperties(String sourceId, String text) {
    final header = DataviewFrontmatter.parse(text, includePropertySpans: true);
    if (header == null || header.propertyLinks.isEmpty) return text;
    final projection = StringBuffer();
    final offsets = <int>[];
    for (final link in header.propertyLinks) {
      offsets.add(projection.length);
      projection.write(link.text);
      projection.write('\n\n');
    }
    final links = projection.toString();
    verifyReferences(sourceId, links);
    final result = rewrite(
      sourceId,
      links,
      selected: selectedTargets(sourceId, links),
    );
    if (result.edits.isEmpty) return text;
    final replacements = <(int, int, String)>[];
    final expected = <String>[];
    var editIndex = 0;
    for (var i = 0; i < offsets.length; i++) {
      final link = header.propertyLinks[i];
      final base = offsets[i];
      final end = base + link.text.length;
      final changed = StringBuffer();
      var cursor = 0;
      while (editIndex < result.edits.length &&
          result.edits[editIndex].$1 < end) {
        final (from, to, _, replacement) = result.edits[editIndex++];
        if (from < base || to > end) {
          throw const FormatException(
            'A YAML link rewrite crosses scalar values',
          );
        }
        changed.write(link.text.substring(cursor, from - base));
        changed.write(replacement);
        cursor = to - base;
      }
      if (cursor == 0) {
        expected.add(link.text);
        continue;
      }
      changed.write(link.text.substring(cursor));
      final value = changed.toString();
      expected.add(value);
      final raw = text.substring(link.start, link.end);
      replacements.add((
        link.start,
        link.end,
        link.encodeReplacement(raw, value),
      ));
    }
    if (editIndex != result.edits.length) {
      throw const FormatException('A YAML link rewrite has no source scalar');
    }
    replacements.sort((a, b) => a.$1.compareTo(b.$1));
    final output = StringBuffer();
    var cursor = 0;
    for (final (start, end, replacement) in replacements) {
      if (start < cursor || end > header.bodyStart) {
        throw const FormatException('Overlapping YAML link rewrites');
      }
      output.write(text.substring(cursor, start));
      output.write(replacement);
      cursor = end;
    }
    output.write(text.substring(cursor));
    final rewritten = output.toString();
    final verified = DataviewFrontmatter.parse(
      rewritten,
      includePropertySpans: true,
    )?.propertyLinks;
    if (verified == null ||
        verified.length != expected.length ||
        verified.indexed.any((entry) => entry.$2.text != expected[entry.$1])) {
      throw StateError(
        'The rewritten YAML would lose recognized property links',
      );
    }
    return rewritten;
  }

  Map<String, Uint8List>? structured(
    String sourceId,
    String kind,
    Map<String, Uint8List> files,
  ) {
    final name = switch (kind) {
      'page' => 'page.json',
      'canvas' => 'board.canvas',
      _ => 'database.json',
    };
    final bytes = files[name];
    if (bytes == null) return null;
    final source = _JsonStrings(utf8.decode(bytes));
    final json = jsonObject(jsonDecode(source.text));
    final projection = structuredDocumentText(kind, files);
    verifyReferences(sourceId, projection);
    final selected = selectedTargets(sourceId, projection);
    final diagnostic = rewrite(
      sourceId,
      projection,
      selected: selected,
    ).signatures.toList();
    final replacements = <_JsonString, String>{};
    void field(List<Object> path) {
      final token = source.stringAt(path);
      if (token == null) return;
      final result = rewrite(sourceId, token.value, selected: selected);
      for (final signature in result.signatures) {
        if (!diagnostic.remove(signature))
          throw StateError(
            'The structured reference context cannot be preserved safely',
          );
      }
      if (result.text != token.value) replacements[token] = result.text;
    }

    void blocks(Object? value, List<Object> path) {
      if (value is! List) return;
      for (var i = 0; i < value.length; i++) {
        final block = jsonObject(value[i]);
        if (const {
          'paragraph',
          'heading1',
          'heading2',
          'heading3',
          'todo',
          'bullet',
          'numbered',
          'quote',
          'callout',
          'toggle',
        }.contains(block['type'])) {
          field([...path, i, 'text']);
        }
        blocks(block['children'], [...path, i, 'children']);
      }
    }

    if (kind == 'page') blocks(json['blocks'], ['blocks']);
    if (kind == 'canvas') {
      final nodes = json['nodes'] as List? ?? const [];
      for (var i = 0; i < nodes.length; i++) {
        final node = jsonObject(nodes[i]);
        if (node['type'] == 'text') field(['nodes', i, 'text']);
        if (node['type'] == 'file' && node['file'] is String) {
          final hasBinding = node.containsKey('inkVaultNoteId');
          final noteId = hasBinding ? node['inkVaultNoteId'] : node['file'];
          if (hasBinding && noteId == null) continue;
          try {
            if (noteId is! String) {
              throw const FormatException('Invalid canvas binding');
            }
            validateId(noteId);
          } on FormatException {
            throw StateError(
              'Resolve filename-based canvas references before renaming; their path base is unknown',
            );
          }
        }
      }
    }
    if (kind == 'database') {
      final properties = <String, String>{
        for (final value in json['properties'] as List? ?? const [])
          jsonObject(value)['id'] as String:
              jsonObject(value)['type'] as String,
      };
      final rows = json['rows'] as List? ?? const [];
      for (var i = 0; i < rows.length; i++) {
        final row = jsonObject(rows[i]);
        if (row['archived'] == true) continue;
        final values = jsonObject(row['values'] ?? <String, dynamic>{});
        for (final key in values.keys) {
          if (const {'title', 'text'}.contains(properties[key]) &&
              values[key] is String)
            field(['rows', i, 'values', key]);
        }
        final body = row['body'];
        if (body is Map<String, dynamic>)
          blocks(body['blocks'], ['rows', i, 'body', 'blocks']);
      }
    }
    if (diagnostic.isNotEmpty)
      throw StateError(
        'An active structured reference has no safe source range',
      );
    if (replacements.isEmpty) return null;
    final next = {
      ...files,
      name: _rewrittenBytes(bytes, source.replace(replacements)),
    };
    if (rewrite(
      sourceId,
      structuredDocumentText(kind, next),
      selected: selected,
    ).signatures.isNotEmpty)
      throw StateError(
        'A structured reference remains dependent on the old title',
      );
    return next;
  }
}

class _TextRewrite {
  const new(this.text, this.signatures, {this.edits = const []});
  final String text;
  final List<String> signatures;
  final List<(int, int, String, String)> edits;
}

Uint8List _rewrittenBytes(Uint8List original, String text) =>
    Uint8List.fromList([
      if (original.length >= 3 &&
          original[0] == 239 &&
          original[1] == 187 &&
          original[2] == 191) ...[
        239,
        187,
        191,
      ],
      ...utf8.encode(text),
    ]);

bool _possibleReference(String text) {
  if (RegExp(r'<inkwiki:[^>\r\n]*>').hasMatch(text)) return true;
  final wiki = RegExp(r'!?\[\[([^\]\r\n]+)\]\]');
  for (final match in wiki.allMatches(text)) {
    final target = match.group(1)!.split('|').first.split('#').first.trim();
    if (!_stableReference(target)) return true;
  }
  if (text.replaceAll(wiki, '').contains('[[') ||
      RegExp(r'^\s{0,3}\[[^\]]+\]:', multiLine: true).hasMatch(text))
    return true;
  for (final match in RegExp(r'\]\(\s*<?([^\s)>]+)').allMatches(text)) {
    final value = match.group(1)!;
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !uri.hasScheme && !_stableReference(value) ||
        uri.scheme == 'inkwiki' && !_stableReference(value))
      return true;
  }
  return false;
}

bool _stableReference(String value) {
  try {
    final target = value.split('#').first;
    validateId(
      target.toLowerCase().endsWith('.md')
          ? target.substring(0, target.length - 3)
          : target,
    );
    return true;
  } on FormatException {
    final uri = Uri.tryParse(value);
    if (uri == null) return false;
    String? id;
    if (uri.scheme == 'inkvault' &&
        uri.host == 'note' &&
        uri.pathSegments.length == 1) {
      id = uri.pathSegments.single;
    } else if (uri.scheme == 'inkwiki' && !uri.hasAuthority && !uri.hasQuery) {
      try {
        id = Uri.decodeComponent(uri.path);
      } on FormatException {
        return false;
      }
    }
    if (id == null) return false;
    try {
      validateId(id);
      return true;
    } on FormatException {
      return false;
    }
  }
}

bool _boundary(String text, int offset) =>
    offset == 0 ||
    offset == text.length ||
    !(text.codeUnitAt(offset - 1) >= 0xd800 &&
        text.codeUnitAt(offset - 1) <= 0xdbff &&
        text.codeUnitAt(offset) >= 0xdc00 &&
        text.codeUnitAt(offset) <= 0xdfff);

class _JsonString {
  const new(this.start, this.end, this.value);
  final int start;
  final int end;
  final String value;
}

/// Only changed string tokens are encoded again; unknown JSON stays byte exact.
class _JsonStrings {
  new(this.text) {
    jsonDecode(text);
    _value([], 0);
  }
  final String text;
  final _strings = <String, _JsonString>{};
  final _ranges = <String, (int, int)>{};
  var _cursor = 0;

  _JsonString? stringAt(List<Object> path) => _strings[jsonEncode(path)];

  String replaceFields(Map<String, Object?> changes) {
    final edits = <(int, int, String)>[];
    final missing = <String, Object?>{};
    for (final entry in changes.entries) {
      final range = _ranges[jsonEncode([entry.key])];
      if (range == null) {
        missing[entry.key] = entry.value;
      } else {
        edits.add((range.$1, range.$2, jsonEncode(entry.value)));
      }
    }
    if (missing.isNotEmpty) {
      final root = _ranges[jsonEncode([])]!;
      final empty = (jsonDecode(text) as Map).isEmpty;
      edits.add((
        root.$2 - 1,
        root.$2 - 1,
        '${empty ? '' : ','}${missing.entries.map((e) => '${jsonEncode(e.key)}:${jsonEncode(e.value)}').join(',')}',
      ));
    }
    edits.sort((a, b) => a.$1.compareTo(b.$1));
    final result = StringBuffer();
    var cursor = 0;
    for (final (start, end, replacement) in edits) {
      result.write(text.substring(cursor, start));
      result.write(replacement);
      cursor = end;
    }
    result.write(text.substring(cursor));
    return result.toString();
  }

  String replace(Map<_JsonString, String> changes) {
    final ordered = changes.keys.toList()
      ..sort((a, b) => a.start.compareTo(b.start));
    final result = StringBuffer();
    var position = 0;
    for (final token in ordered) {
      result.write(text.substring(position, token.start));
      result.write(jsonEncode(changes[token]));
      position = token.end;
    }
    result.write(text.substring(position));
    return result.toString();
  }

  void _space() {
    while (_cursor < text.length &&
        const [9, 10, 13, 32].contains(text.codeUnitAt(_cursor)))
      _cursor++;
  }

  _JsonString _string() {
    final start = _cursor++;
    while (_cursor < text.length) {
      final char = text.codeUnitAt(_cursor++);
      if (char == 92) {
        _cursor++;
      } else if (char == 34) {
        return _JsonString(
          start,
          _cursor,
          jsonDecode(text.substring(start, _cursor)) as String,
        );
      }
    }
    throw const FormatException('Unterminated JSON string');
  }

  void _value(List<Object> path, int depth) {
    if (depth > 128)
      throw const FormatException(
        'JSON nesting is too deep for safe link rewriting',
      );
    _space();
    final start = _cursor;
    final char = text.codeUnitAt(_cursor);
    if (char == 34) {
      _strings[jsonEncode(path)] = _string();
    } else if (char == 123) {
      _cursor++;
      _space();
      final keys = <String>{};
      while (text.codeUnitAt(_cursor) != 125) {
        final key = _string().value;
        if (!keys.add(key))
          throw const FormatException(
            'Duplicate JSON keys prevent safe link rewriting',
          );
        _space();
        _cursor++;
        _value([...path, key], depth + 1);
        _space();
        if (text.codeUnitAt(_cursor) != 44) break;
        _cursor++;
        _space();
      }
      _cursor++;
    } else if (char == 91) {
      _cursor++;
      _space();
      var index = 0;
      while (text.codeUnitAt(_cursor) != 93) {
        _value([...path, index++], depth + 1);
        _space();
        if (text.codeUnitAt(_cursor) != 44) break;
        _cursor++;
      }
      _cursor++;
    } else {
      while (_cursor < text.length &&
          !const [
            9,
            10,
            13,
            32,
            44,
            93,
            125,
          ].contains(text.codeUnitAt(_cursor)))
        _cursor++;
    }
    _ranges[jsonEncode(path)] = (start, _cursor);
  }
}
