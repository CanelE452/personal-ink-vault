import 'dart:convert';
import 'dart:typed_data';

import 'package:ink_vault_core/ink_vault_core.dart';

class VaultNote {
  final String id;
  final String title;
  final String inkEntityId;
  final String markdownEntityId;
  final RevisionRecord revision;
  final bool deletionConflict;
  new(
    this.id,
    this.title,
    this.inkEntityId,
    this.markdownEntityId,
    this.revision, {
    this.deletionConflict = false,
  });
  Map<String, Object> get json => {
    'title': title,
    'inkEntityId': inkEntityId,
    'markdownEntityId': markdownEntityId,
  };
}

class WorkspaceStore {
  final NoteRepository repository;
  new(this.repository);

  Future<VaultNote> _decode(
    RevisionRecord revision, {
    bool deletionConflict = false,
  }) async {
    final files = await repository.readFiles(revision);
    final json =
        jsonDecode(utf8.decode(files['note.json']!)) as Map<String, dynamic>;
    final ink = json['inkEntityId'] as String;
    final markdown = json['markdownEntityId'] as String;
    validateId(ink);
    validateId(markdown);
    return VaultNote(
      revision.entityId,
      json['title'] as String,
      ink,
      markdown,
      revision,
      deletionConflict: deletionConflict,
    );
  }

  Future<List<VaultNote>> list({bool includeDeleted = false}) async {
    final records = await repository.revisions();
    final ids = records
        .where((r) => r.kind == EntityKind.metadata)
        .map((r) => r.entityId)
        .toSet();
    final result = <VaultNote>[];
    for (final id in ids) {
      final heads = await repository.heads(id);
      // Each metadata branch stays visible, including a delete-vs-edit conflict.
      for (final head in heads) {
        var conflict = head.deleted && heads.length > 1;
        if (head.deleted) {
          final children = records
              .where((r) => r.ownerNoteId == id)
              .map((r) => r.entityId)
              .toSet();
          for (final child in children) {
            final childHeads = await repository.heads(child);
            if (childHeads.any(
              (r) => !(head.baseRefs[child] ?? const []).contains(r.revisionId),
            ))
              conflict = true;
          }
        }
        if (head.deleted && !includeDeleted && !conflict) continue;
        result.add(await _decode(head, deletionConflict: conflict));
      }
    }
    result.sort(
      (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
    );
    return result;
  }

  Future<VaultNote> create(String title) async {
    final id = newId(), ink = newId(), markdown = newId();
    await repository.commit(
      entityId: markdown,
      kind: EntityKind.markdown,
      ownerNoteId: id,
      files: {'summary.md': Uint8List(0)},
      parentRevisionIds: [],
    );
    final revision = await repository.commit(
      entityId: id,
      kind: EntityKind.metadata,
      files: {
        'note.json': Uint8List.fromList(
          utf8.encode(
            jsonEncode({
              'title': title.trim().isEmpty ? '새 노트' : title.trim(),
              'inkEntityId': ink,
              'markdownEntityId': markdown,
            }),
          ),
        ),
      },
      parentRevisionIds: [],
    );
    return _decode(revision);
  }

  Future<void> rename(VaultNote note, String title) async {
    if (title.trim().isEmpty) throw const FormatException('제목을 입력하세요');
    await repository.commit(
      entityId: note.id,
      kind: EntityKind.metadata,
      files: {
        'note.json': Uint8List.fromList(
          utf8.encode(jsonEncode({...note.json, 'title': title.trim()})),
        ),
      },
      parentRevisionIds: [note.revision.revisionId],
    );
  }

  Future<void> setDeleted(VaultNote note, bool deleted) async {
    final bases = <String, List<String>>{};
    for (final r in await repository.revisions()) {
      if (r.ownerNoteId == note.id)
        bases[r.entityId] = (await repository.heads(r.entityId))
            .map((h) => h.revisionId)
            .toList();
    }
    await repository.commit(
      entityId: note.id,
      kind: EntityKind.metadata,
      deleted: deleted,
      files: {
        'note.json': Uint8List.fromList(utf8.encode(jsonEncode(note.json))),
      },
      parentRevisionIds: [note.revision.revisionId],
      baseRefs: bases,
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

  Future<void> saveMarkdown(String text) async {
    final r = await repository.commit(
      entityId: note.markdownEntityId,
      kind: EntityKind.markdown,
      ownerNoteId: note.id,
      files: {'summary.md': Uint8List.fromList(utf8.encode(text))},
      parentRevisionIds: List.of(markdownParents),
    );
    markdownParents = [r.revisionId];
  }

  Future<void> saveInk(Map<String, Uint8List> files) async {
    final r = await repository.commit(
      entityId: note.inkEntityId,
      kind: EntityKind.ink,
      ownerNoteId: note.id,
      files: files,
      parentRevisionIds: List.of(inkParents),
    );
    inkParents = [r.revisionId];
  }

  Future<void> mergeMarkdown(String text) async {
    final heads = await repository.heads(note.markdownEntityId);
    final revision = await repository.commit(
      entityId: note.markdownEntityId,
      kind: EntityKind.markdown,
      ownerNoteId: note.id,
      files: {'summary.md': Uint8List.fromList(utf8.encode(text))},
      parentRevisionIds: heads.map((r) => r.revisionId).toList(),
    );
    markdownParents = [revision.revisionId];
  }

  Future<void> resolve(RevisionRecord chosen) async {
    final heads = await repository.heads(chosen.entityId);
    final r = await repository.commit(
      entityId: chosen.entityId,
      kind: chosen.kind,
      ownerNoteId: chosen.ownerNoteId,
      files: await repository.readFiles(chosen),
      parentRevisionIds: heads.map((h) => h.revisionId).toList(),
      deleted: chosen.deleted,
      baseRefs: chosen.baseRefs,
    );
    if (chosen.kind == EntityKind.markdown) markdownParents = [r.revisionId];
    if (chosen.kind == EntityKind.ink) inkParents = [r.revisionId];
  }
}
