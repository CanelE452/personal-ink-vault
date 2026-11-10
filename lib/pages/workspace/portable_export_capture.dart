import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/vault/database_query.dart';
import 'package:saber/data/vault/database_query_native.dart';
import 'package:saber/data/vault/obsidian_canvas_export.dart';
import 'package:saber/data/vault/portable_document_export.dart';
import 'package:saber/data/vault/workspace_database.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/pages/workspace/workspace_controller.dart';

final class PortableExportCapture {
  new(this.source, this._check);
  final PortableExportSource source;
  final void Function() _check;
  void ensureCurrent() => _check();
}

({
  NoteRepository repository,
  VaultNote note,
  List<String> selected,
  VoidCallback check,
})
_captureExportSelection(WorkspaceController controller, NoteSession session) {
  final repository = controller.repository;
  final generation = controller.editorGeneration;
  final repositoryGeneration = controller.repositoryGeneration;
  final note = session.note;
  final selected = List<String>.of(session.inkParents);
  void check() {
    final current = session.note;
    if (!controller.canCreateDocument ||
        controller.dirty ||
        !identical(controller.repository, repository) ||
        controller.repositoryGeneration != repositoryGeneration ||
        !identical(controller.activeSession, session) ||
        !identical(session.repository, repository) ||
        controller.editorGeneration != generation ||
        current.id != note.id ||
        current.title != note.title ||
        current.documentKind != note.documentKind ||
        current.inkEntityId != note.inkEntityId ||
        current.markdownEntityId != note.markdownEntityId ||
        current.revision.revisionId != note.revision.revisionId ||
        current.trashed ||
        !listEquals(session.inkParents, selected)) {
      throw StateError('문서가 변경되었거나 저장 중입니다. 저장을 마친 뒤 다시 내보내세요.');
    }
  }

  check();
  return (repository: repository, note: note, selected: selected, check: check);
}

Future<({PortableExportBundle bundle, Future<void> Function() ensureCurrent})>
captureObsidianCanvasExport(
  WorkspaceController controller,
  NoteSession session,
) async {
  final (:repository, :note, :selected, :check) = _captureExportSelection(
    controller,
    session,
  );
  if (note.documentKind != VaultDocumentKind.canvas || selected.length != 1) {
    throw const FormatException('내보낼 캔버스의 본문 판본을 선택하세요.');
  }
  final native = controller.native;
  if (native == null) throw StateError('Obsidian 내보내기에는 공통 엔진이 필요합니다.');
  final result = await buildObsidianCanvasExport(
    repository: repository,
    native: native,
    noteId: note.id,
    metadataRevisionId: note.revision.revisionId,
    bodyRevisionId: selected.single,
  );
  check();
  return (
    bundle: result.bundle,
    ensureCurrent: () async {
      check();
      await result.ensureCurrent();
      check();
    },
  );
}

Future<PortableExportCapture> capturePortableExport(
  WorkspaceController controller,
  NoteSession session,
) async {
  final (:repository, :note, :selected, :check) = _captureExportSelection(
    controller,
    session,
  );
  if (!const {
        VaultDocumentKind.page,
        VaultDocumentKind.database,
      }.contains(note.documentKind) ||
      selected.length != 1) {
    throw const FormatException('내보낼 페이지 또는 데이터베이스의 본문 판본을 선택하세요.');
  }
  final metadata = note.revision;
  if (metadata.vaultId != repository.vaultId ||
      metadata.entityId != note.id ||
      metadata.kind != EntityKind.metadata ||
      metadata.deleted) {
    throw const FormatException('문서의 이름과 판본을 확인하지 못했습니다.');
  }
  final metadataBytes = await repository.readRevisionFile(
    metadata,
    'note.json',
  );
  check();
  final savedMetadata = jsonObject(jsonDecode(utf8.decode(metadataBytes)));
  if (savedMetadata['title'] != note.title ||
      savedMetadata['inkEntityId'] != note.inkEntityId ||
      savedMetadata['markdownEntityId'] != note.markdownEntityId ||
      savedMetadata['documentKind'] != note.documentKind.name) {
    throw const FormatException('문서의 이름과 저장된 판본이 일치하지 않습니다.');
  }
  if (note.documentKind == VaultDocumentKind.page) {
    final snapshot = await controller.loadBlockPageSnapshot(session: session);
    check();
    return PortableExportCapture(
      PortableExportSource.page(
        noteId: note.id,
        title: note.title,
        bodyRevisionId: selected.single,
        metadataRevisionIds: [metadata.revisionId],
        snapshot: snapshot,
      ),
      check,
    );
  }

  final snapshot = await controller.loadDatabaseSnapshot(session: session);
  check();
  final database = snapshot.database;
  final computed = database.properties
      .where((property) => property.isComputed)
      .toList();
  final related = <String, WorkspaceDatabase>{};
  final relatedRevisions = <String, String>{};
  final ambiguous = <String>{};
  final now = DateTime.now().toUtc();
  if (computed.isNotEmpty) {
    final notes = await controller.store.list();
    check();
    final noteCounts = <String, int>{};
    for (final candidate in notes) {
      noteCounts.update(candidate.id, (count) => count + 1, ifAbsent: () => 1);
    }
    for (final candidate in notes) {
      if (candidate.id == note.id ||
          noteCounts[candidate.id] != 1 ||
          candidate.documentKind != VaultDocumentKind.database ||
          candidate.trashed ||
          candidate.deletionConflict)
        continue;
      try {
        final metadataHeads = await repository.heads(candidate.id);
        check();
        if (metadataHeads.length != 1 ||
            metadataHeads.single.revisionId != candidate.revision.revisionId ||
            metadataHeads.single.deleted)
          continue;
        final heads = await repository.heads(candidate.inkEntityId);
        check();
        if (heads.length != 1) continue;
        final revision = heads.single;
        if (revision.vaultId != repository.vaultId ||
            revision.entityId != candidate.inkEntityId ||
            revision.ownerNoteId != candidate.id ||
            revision.kind != EntityKind.ink ||
            revision.deleted)
          continue;
        final bytes = await repository.readRevisionFile(
          revision,
          'database.json',
        );
        check();
        final value = WorkspaceDatabase.fromJson(
          jsonObject(jsonDecode(utf8.decode(bytes))),
        );
        final currentMetadata = await repository.heads(candidate.id);
        check();
        final currentBody = await repository.heads(candidate.inkEntityId);
        check();
        if (currentMetadata.length != 1 ||
            currentMetadata.single.revisionId !=
                candidate.revision.revisionId ||
            currentBody.length != 1 ||
            currentBody.single.revisionId != revision.revisionId ||
            value.id == database.id)
          continue;
        if (related.containsKey(value.id)) ambiguous.add(value.id);
        related[value.id] = value;
        relatedRevisions[value.id] = revision.revisionId;
      } on FormatException {
        check();
      } on FileSystemException {
        check();
      }
    }
    for (final id in ambiguous) {
      related.remove(id);
      relatedRevisions.remove(id);
    }
  }
  final query = controller.native == null
      ? DatabaseQuery(database, resolver: (id) => related[id], now: now)
      : DatabaseQueryRuntime(invoke: controller.native!.invoke).project(
          database,
          view: DatabaseView.create(),
          databases: related,
          now: now,
          valuePropertyIds: computed.map((property) => property.id).toList(),
        );
  final values = <String, Map<String, DatabaseValue>>{
    for (final row in database.rows)
      row.id: {
        for (final property in computed)
          property.id: query.value(row, property.id),
      },
  };
  check();
  return PortableExportCapture(
    PortableExportSource.database(
      noteId: note.id,
      title: note.title,
      bodyRevisionId: selected.single,
      metadataRevisionIds: [metadata.revisionId],
      snapshot: snapshot,
      values: values,
      relatedRevisionIds: relatedRevisions,
      evaluatedAtUtc: now,
    ),
    check,
  );
}
