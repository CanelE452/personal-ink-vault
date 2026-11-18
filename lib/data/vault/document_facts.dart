import 'dart:io';

import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/vault/workspace_store.dart';

/// Facts the library screen shows about one document.
final class DocumentFacts {
  const new({this.changed, this.created, this.format, this.pages, this.aspect});

  final DateTime? changed;
  final DateTime? created;

  /// Lowercase extension without a dot, for example `pptx` or `pdf`.
  final String? format;
  final int? pages;

  /// Cover width divided by height.
  final double? aspect;

  DocumentFacts withCover({int? pages, double? aspect}) => DocumentFacts(
    changed: changed,
    created: created,
    format: format,
    pages: pages ?? this.pages,
    aspect: aspect ?? this.aspect,
  );
}

/// Reads revision file times once for all [notes]. A revision file is written
/// when the revision is committed, so its time is when that change happened.
/// A committed revision file never changes: [times] keeps the times found,
/// by revision id, for the caller's next read of the same vault.
Future<Map<String, DocumentFacts>> readDocumentFacts(
  NoteRepository repository,
  List<VaultNote> notes, {
  Map<String, DateTime>? times,
}) async {
  final records = await repository.revisions();
  final parents = {for (final r in records) ...r.parentRevisionIds};
  final headsByEntity = <String, List<RevisionRecord>>{};
  final rootsByEntity = <String, List<RevisionRecord>>{};
  for (final record in records) {
    if (!parents.contains(record.revisionId)) {
      (headsByEntity[record.entityId] ??= []).add(record);
    }
    if (record.parentRevisionIds.isEmpty) {
      (rootsByEntity[record.entityId] ??= []).add(record);
    }
  }

  final known = times ?? <String, DateTime>{};
  final missing = <String>{};
  DateTime? timeOf(RevisionRecord record) {
    final id = record.revisionId;
    if (known[id] case final time?) return time;
    if (missing.contains(id)) return null;
    try {
      return known[id] = File(
        '${repository.root.path}/revisions/$id.json',
      ).lastModifiedSync();
    } on FileSystemException {
      missing.add(id);
      return null;
    }
  }

  DateTime? later(DateTime? a, DateTime? b) =>
      a == null ? b : (b == null || a.isAfter(b) ? a : b);

  final facts = <String, DocumentFacts>{};
  for (final note in notes) {
    final sourceId = note.sourceEntityId;
    final sourceHeads = sourceId == null
        ? const <RevisionRecord>[]
        : headsByEntity[sourceId] ?? const <RevisionRecord>[];
    final changing = <RevisionRecord>[
      note.revision,
      ...?headsByEntity[note.inkEntityId],
      ...?headsByEntity[note.markdownEntityId],
      ...sourceHeads,
    ];
    DateTime? changed;
    for (final record in changing) {
      changed = later(changed, timeOf(record));
    }
    DateTime? created;
    for (final record in rootsByEntity[note.id] ?? const <RevisionRecord>[]) {
      final time = timeOf(record);
      if (time != null && (created == null || time.isBefore(created))) {
        created = time;
      }
    }
    facts[note.id] = DocumentFacts(
      changed: changed,
      created: created,
      format: _format(note, sourceHeads),
    );
  }
  return facts;
}

String? _format(VaultNote note, List<RevisionRecord> sourceHeads) {
  switch (note.documentKind) {
    case VaultDocumentKind.pdf:
      return 'pdf';
    case VaultDocumentKind.office:
      for (final head in sourceHeads) {
        for (final name in head.blobs.keys) {
          if (name == 'preview.pdf' || name == 'edition.json') continue;
          final dot = name.lastIndexOf('.');
          if (dot < 0 || dot == name.length - 1) continue;
          return name.substring(dot + 1).toLowerCase();
        }
      }
      return null;
    default:
      return null;
  }
}
