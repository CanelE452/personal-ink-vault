import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/vault/note_link.dart';

enum WorkspaceBookmarkKind { group, note, folder, search, url }

final class WorkspaceBookmarkSpec {
  const new({
    required this.kind,
    this.title,
    this.groupId,
    this.target,
    this.pdfPageNumber,
    this.literalSearch = false,
    this.expressionSearch = false,
    this.order,
  });

  final WorkspaceBookmarkKind kind;
  final String? title;
  final String? groupId;
  final String? target;
  final int? pdfPageNumber;
  final bool literalSearch;
  final bool expressionSearch;
  final int? order;
}

final class WorkspaceBookmark {
  const new({
    required this.id,
    required this.revisionId,
    required this.spec,
    this.conflicted = false,
  }) : _observedHeads = null;

  new _(RevisionRecord record, this.spec, List<String> heads)
    : id = record.entityId,
      revisionId = record.revisionId,
      conflicted = heads.length > 1,
      _observedHeads = List.unmodifiable(heads);

  final String id;
  final String revisionId;
  final WorkspaceBookmarkSpec spec;
  final bool conflicted;
  final List<String>? _observedHeads;
}

/// Bookmark revisions share the vault's ordinary attachment sync and backup.
/// A target is a reference and does not own the bookmark's lifecycle.
final class WorkspaceBookmarkStore {
  const new(this.repository);

  final NoteRepository repository;

  static const _file = 'workspace-bookmark.json';
  static const _maxBytes = 64 * 1024;
  static final _controls = RegExp(r'[\x00-\x1f\x7f-\x9f]');

  Future<List<WorkspaceBookmark>> list() async {
    final revisions = await repository.revisions();
    final parents = {
      for (final revision in revisions) ...revision.parentRevisionIds,
    };
    final headsByEntity = <String, List<RevisionRecord>>{};
    for (final revision in revisions) {
      if (revision.kind == EntityKind.attachment &&
          revision.ownerNoteId == null &&
          !parents.contains(revision.revisionId)) {
        (headsByEntity[revision.entityId] ??= []).add(revision);
      }
    }
    final bookmarks = <WorkspaceBookmark>[];
    for (final heads in headsByEntity.values) {
      final headIds = heads.map((head) => head.revisionId).toList();
      for (final head in heads) {
        try {
          final spec = await _read(head);
          if (spec != null) {
            bookmarks.add(WorkspaceBookmark._(head, spec, headIds));
          }
        } on FormatException {
          // A malformed bookmark does not hide unrelated entries.
        } on FileSystemException {
          // A missing payload is reported by the repository's integrity check.
        }
      }
    }
    bookmarks.sort((left, right) {
      final byOrder = left.spec.order!.compareTo(right.spec.order!);
      if (byOrder != 0) return byOrder;
      final byId = left.id.compareTo(right.id);
      return byId != 0 ? byId : left.revisionId.compareTo(right.revisionId);
    });
    return List.unmodifiable(bookmarks);
  }

  Future<WorkspaceBookmark> add(WorkspaceBookmarkSpec spec) async {
    final normalized = _normalize(spec, DateTime.now().microsecondsSinceEpoch);
    return _publish(
      newId(),
      const [],
      normalized,
      groupGuard: await _groupGuard(normalized.groupId),
    );
  }

  Future<WorkspaceBookmark> update(
    WorkspaceBookmark prior,
    WorkspaceBookmarkSpec spec,
  ) async {
    final current = await _requireCurrent(prior);
    final normalized = _normalize(spec, current.spec.order!);
    final groupChanged = current.spec.groupId != normalized.groupId;
    if (current.spec.kind != normalized.kind ||
        (current.spec.kind == WorkspaceBookmarkKind.group && groupChanged) ||
        normalized.groupId == current.id) {
      throw const FormatException('Invalid bookmark update');
    }
    return _publish(
      current.id,
      [current.revisionId],
      normalized,
      groupGuard: groupChanged ? await _groupGuard(normalized.groupId) : null,
    );
  }

  Future<void> remove(WorkspaceBookmark prior) async {
    final current = await _requireCurrent(prior);
    final prepared = repository.prepareCommit(
      entityId: current.id,
      kind: EntityKind.attachment,
      files: const {},
      parentRevisionIds: [current.revisionId],
      deleted: true,
    );
    await repository.commitPreparedIfHeads(
      prepared,
      expectedHeads: {
        current.id: [current.revisionId],
      },
    );
  }

  /// Publishes the chosen active variant with every observed head as a parent.
  Future<WorkspaceBookmark> resolve(WorkspaceBookmark prior) async {
    final observed = prior._observedHeads;
    if (observed == null || observed.length < 2) {
      throw StateError('Refresh bookmark conflicts before choosing a revision');
    }
    final current = await _requireCurrent(prior, expectedHeads: observed);
    return _publish(current.id, observed, current.spec);
  }

  Future<WorkspaceBookmark> _requireCurrent(
    WorkspaceBookmark prior, {
    List<String>? expectedHeads,
  }) async {
    final expected = expectedHeads ?? [prior.revisionId];
    final heads = await repository.heads(prior.id);
    if (heads.length != expected.length ||
        !heads.every((head) => expected.contains(head.revisionId))) {
      throw StateError('Bookmark changed or has conflicting revisions');
    }
    final revision = heads.singleWhere(
      (head) => head.revisionId == prior.revisionId,
    );
    final spec = await _read(revision);
    if (spec == null) throw StateError('Bookmark is no longer available');
    return WorkspaceBookmark._(revision, spec, expected);
  }

  Future<RevisionRecord?> _groupGuard(String? id) async {
    if (id == null) return null;
    final heads = await repository.heads(id);
    if (heads.length != 1 ||
        (await _read(heads.single))?.kind != WorkspaceBookmarkKind.group) {
      throw StateError(
        'Bookmark group is missing or has conflicting revisions',
      );
    }
    return heads.single;
  }

  Future<WorkspaceBookmark> _publish(
    String id,
    List<String> parents,
    WorkspaceBookmarkSpec spec, {
    RevisionRecord? groupGuard,
  }) async {
    final encoded = utf8.encode(
      jsonEncode({
        'version': 1,
        'kind': spec.kind.name,
        'title': spec.title,
        'groupId': spec.groupId,
        'target': spec.target,
        'pdfPageNumber': spec.pdfPageNumber,
        if (spec.literalSearch) 'literalSearch': true,
        if (spec.expressionSearch) 'expressionSearch': true,
        'order': spec.order,
      }),
    );
    if (encoded.length > _maxBytes) {
      throw const FormatException('Bookmark payload is too large');
    }
    final prepared = repository.prepareCommit(
      entityId: id,
      kind: EntityKind.attachment,
      files: {_file: Uint8List.fromList(encoded)},
      parentRevisionIds: parents,
    );
    final record = await repository.commitPreparedIfHeads(
      prepared,
      expectedHeads: {
        id: parents,
        if (groupGuard != null) groupGuard.entityId: [groupGuard.revisionId],
      },
    );
    return WorkspaceBookmark._(record, spec, [record.revisionId]);
  }

  Future<WorkspaceBookmarkSpec?> _read(RevisionRecord record) async {
    final ref = record.blobs[_file];
    if (record.formatVersion != 2 ||
        record.kind != EntityKind.attachment ||
        record.ownerNoteId != null ||
        record.deleted ||
        record.baseRefs.isNotEmpty ||
        record.blobs.length != 1 ||
        ref == null) {
      return null;
    }
    if (ref.length > _maxBytes) {
      throw const FormatException('Bookmark payload is too large');
    }
    final bytes = await repository.readRevisionFile(record, _file);
    final data = jsonObject(jsonDecode(utf8.decode(bytes)));
    if (data['version'] is! int ||
        data['version'] != 1 ||
        data['kind'] is! String ||
        data['order'] is! int ||
        (data['pdfPageNumber'] != null && data['pdfPageNumber'] is! int) ||
        (data['literalSearch'] != null && data['literalSearch'] is! bool) ||
        (data['expressionSearch'] != null &&
            data['expressionSearch'] is! bool)) {
      throw const FormatException('Unsupported bookmark payload');
    }
    String? optionalText(String key) {
      final value = data[key];
      if (value == null || value is String) return value as String?;
      throw const FormatException('Invalid bookmark field');
    }

    final kind = WorkspaceBookmarkKind.values
        .where((kind) => kind.name == data['kind'])
        .firstOrNull;
    final groupId = optionalText('groupId');
    if (kind == null || groupId == record.entityId) {
      throw const FormatException('Invalid bookmark kind or parent');
    }
    return _normalize(
      WorkspaceBookmarkSpec(
        kind: kind,
        title: optionalText('title'),
        groupId: groupId,
        target: optionalText('target'),
        pdfPageNumber: data['pdfPageNumber'] as int?,
        literalSearch: data['literalSearch'] == true,
        expressionSearch: data['expressionSearch'] == true,
        order: data['order'] as int,
      ),
      0,
    );
  }

  static WorkspaceBookmarkSpec _normalize(
    WorkspaceBookmarkSpec spec,
    int defaultOrder,
  ) {
    final title = spec.title?.trim();
    final group = spec.groupId;
    final target = spec.target;
    final page = spec.pdfPageNumber;
    final order = spec.order ?? defaultOrder;
    if ((title != null &&
            (title.isEmpty ||
                title.length > 256 ||
                _controls.hasMatch(title))) ||
        (target != null &&
            (target.trim().isEmpty ||
                target.length > 16384 ||
                _controls.hasMatch(target))) ||
        (page != null &&
            (spec.kind != WorkspaceBookmarkKind.note ||
                page < 1 ||
                page > 0x7fffffff)) ||
        ((spec.literalSearch || spec.expressionSearch) &&
            spec.kind != WorkspaceBookmarkKind.search) ||
        (spec.literalSearch && spec.expressionSearch) ||
        order < 0 ||
        order > 0x1fffffffffffff) {
      throw const FormatException('Invalid bookmark fields');
    }
    if (group != null) validateId(group);
    switch (spec.kind) {
      case WorkspaceBookmarkKind.group:
        if (title == null || target != null) {
          throw const FormatException('Bookmark group must have a title only');
        }
      case WorkspaceBookmarkKind.note:
        final link = target == null ? null : NoteLink.parse(target);
        if (link == null ||
            link.toString() != target ||
            (page != null &&
                (link.isMarkdown ||
                    link.pageId != null ||
                    link.officePageTarget != null))) {
          throw const FormatException('Invalid bookmarked note location');
        }
      case WorkspaceBookmarkKind.folder:
        if (target == null) {
          throw const FormatException('Missing bookmarked folder');
        }
        validateId(target);
      case WorkspaceBookmarkKind.search:
        if (target == null || target.length > 2048) {
          throw const FormatException('Invalid bookmarked search');
        }
      case WorkspaceBookmarkKind.url:
        if (target == null ||
            target != target.trim() ||
            !isSafeExternalLink(target)) {
          throw const FormatException('Invalid bookmarked URL');
        }
    }
    return WorkspaceBookmarkSpec(
      kind: spec.kind,
      title: title,
      groupId: group,
      target: target,
      pdfPageNumber: page,
      literalSearch: spec.literalSearch,
      expressionSearch: spec.expressionSearch,
      order: order,
    );
  }
}
