import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/vault/library_store.dart';
import 'package:saber/data/vault/obsidian_vault_source.dart';
import 'package:saber/data/vault/workspace_store.dart';

/// Lookup candidates refer to real metadata branches, never the joined label.
class KnowledgeCatalog {
  new _(
    this.revisions,
    this.heads,
    this.notes,
    this.folders,
    this.documents,
    this.pathIssues,
  );

  final List<RevisionRecord> revisions;
  final Map<String, List<RevisionRecord>> heads;
  final Map<String, List<VaultNote>> notes;
  final Map<String, List<VaultFolder>> folders;
  final Map<String, Map<String, Object?>> documents;
  final Set<String> pathIssues;

  static Future<KnowledgeCatalog> capture(NoteRepository repository) async {
    final revisions = await repository.revisions();
    final parents = revisions.expand((r) => r.parentRevisionIds).toSet();
    final heads = <String, List<RevisionRecord>>{};
    for (final revision in revisions) {
      if (!parents.contains(revision.revisionId)) {
        (heads[revision.entityId] ??= []).add(revision);
      }
    }
    final notes = <String, List<VaultNote>>{};
    for (final note in await WorkspaceStore(repository).list()) {
      (notes[note.id] ??= []).add(note);
    }
    final folders = <String, List<VaultFolder>>{};
    if (repository.formatVersion >= 2) {
      for (final folder in await LibraryStore(
        repository,
      ).listFolders(includeDeleted: true)) {
        (folders[folder.id] ??= []).add(folder);
      }
    }
    final pathIssues = <String>{};
    Set<String> folderPaths(
      String? id,
      Set<String> ancestors, {
      bool forAttachment = false,
    }) {
      if (id == null) return {''};
      final branches = folders[id];
      if (ancestors.contains(id) ||
          ancestors.length >= 64 ||
          branches == null ||
          branches.isEmpty) {
        throw StateError('The logical folder path is unresolved');
      }
      final paths = <String>{};
      for (final branch in branches) {
        if (branch.trashed || branch.deletionConflict) {
          throw StateError('The logical folder path has a deletion conflict');
        }
        _segment(branch.title);
        if (forAttachment && !isObsidianPathSegment(branch.title)) {
          throw const FormatException(
            'Invalid imported attachment folder path',
          );
        }
        for (final parent in folderPaths(branch.parentId, {
          ...ancestors,
          id,
        }, forAttachment: forAttachment)) {
          paths.add('$parent${branch.title}/');
          if (paths.length > 256) {
            throw StateError('Too many unresolved logical folder paths');
          }
        }
      }
      return paths;
    }

    final documents = <String, Map<String, Object?>>{};
    for (final entry in notes.entries) {
      final titles = entry.value.map((n) => n.title).toSet().toList()..sort();
      final lookupTitles = <String>{};
      final aliases = <String>{};
      final paths = <String>{};
      final attachmentPaths = <String>{};
      var attachmentAvailable = false;
      for (final note in entry.value) {
        final attachmentName = note.obsidianAttachmentName;
        final isImportedAttachment =
            attachmentName != null &&
            obsidianAttachmentKind(attachmentName) == note.documentKind.name;
        if (!isImportedAttachment) {
          lookupTitles.add(note.title);
          final rawAliases = note.json['aliases'];
          if (rawAliases is String) aliases.add(rawAliases);
          if (rawAliases is List)
            aliases.addAll(rawAliases.whereType<String>());
        }
        if (repository.formatVersion >= 2) {
          try {
            if (isImportedAttachment) {
              final source = heads[note.sourceEntityId]?.singleOrNull;
              final board = heads[note.inkEntityId]?.singleOrNull;
              for (final folder in folderPaths(
                note.folderId,
                {},
                forAttachment: true,
              )) {
                attachmentPaths.add('$folder$attachmentName');
              }
              attachmentAvailable =
                  heads[note.id]?.length == 1 &&
                  !note.trashed &&
                  !note.deletionConflict &&
                  source != null &&
                  !source.deleted &&
                  source.kind == EntityKind.attachment &&
                  source.ownerNoteId == note.id &&
                  (source.blobs[attachmentName]?.length ?? 0) > 0 &&
                  (note.documentKind != VaultDocumentKind.canvas ||
                      (board != null &&
                          !board.deleted &&
                          board.kind == EntityKind.ink &&
                          board.ownerNoteId == note.id &&
                          (board.blobs['board.canvas']?.length ?? 0) > 0));
              continue;
            }
            _segment(note.title);
            final exportedNames = note.notionExportNames;
            for (final folder in folderPaths(note.folderId, {})) {
              if (exportedNames.isEmpty) {
                paths.add('$folder${note.title}.md');
              } else {
                paths.addAll(exportedNames.map((name) => '$folder$name'));
              }
            }
          } on StateError {
            pathIssues.add(note.id);
          } on FormatException {
            pathIssues.add(note.id);
          }
        }
      }
      documents[entry.key] = {
        'id': entry.key,
        'title': titles.join(' / '),
        'lookupTitles': List<String>.unmodifiable(
          lookupTitles.toList()..sort(),
        ),
        'aliases': List<String>.unmodifiable(aliases.toList()..sort()),
        if (repository.formatVersion >= 2)
          'paths': List<String>.unmodifiable(
            pathIssues.contains(entry.key) ? [] : (paths.toList()..sort()),
          ),
        if (!pathIssues.contains(entry.key) && attachmentPaths.isNotEmpty) ...{
          'attachmentPaths': List<String>.unmodifiable(
            attachmentPaths.toList()..sort(),
          ),
          if (!attachmentAvailable) 'attachmentUnavailable': true,
        },
        'markdown': '',
      };
    }
    final current = await repository.revisions();
    final ids = revisions.map((r) => r.revisionId).toSet();
    if (current.length != ids.length ||
        current.any((r) => !ids.contains(r.revisionId))) {
      throw StateError('The workspace changed while collecting link targets');
    }
    return KnowledgeCatalog._(
      revisions,
      heads,
      notes,
      folders,
      documents,
      pathIssues,
    );
  }

  static void _segment(String value) {
    validateLogicalPath(value);
    if (value.contains('/')) {
      throw const FormatException('A title is not a logical path segment');
    }
  }
}
