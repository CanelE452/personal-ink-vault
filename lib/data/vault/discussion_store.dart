import 'dart:convert';
import 'dart:io' show FileSystemException;
import 'dart:typed_data';

import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/vault/block_page_document.dart';
import 'package:saber/data/vault/discussion_anchor.dart';

enum DiscussionThreadStatus { open, resolved, conflict }

typedef DiscussionStatusHead = ({String id, bool resolved});

/// Pins the stored body head. A null revision ID requires no stored body head.
typedef DiscussionBodyRevision = ({String? revisionId});

/// Persists a receipt for the prepared event and its independent byte copy.
typedef DiscussionPreparedHook = Future<void> Function(
  PreparedCommit prepared,
  Uint8List eventBytes,
);

final class DiscussionMessage {
  const new _(this.id, this.authorDeviceId, this.body, {this.replyToId});

  final String id;
  final String authorDeviceId;
  final String body;
  final String? replyToId;
}

final class DiscussionThread {
  new _({
    required this.anchor,
    required this.anchorStatus,
    required this.root,
    required List<DiscussionMessage> replies,
    required List<DiscussionStatusHead> statusHeads,
  }) : replies = List.unmodifiable(replies),
       statusHeads = List.unmodifiable(statusHeads);

  final DiscussionAnchor anchor;
  final DiscussionAnchorStatus anchorStatus;
  final DiscussionMessage root;
  final List<DiscussionMessage> replies;
  final List<DiscussionStatusHead> statusHeads;

  String get id => root.id;
  List<String> get statusHeadIds =>
      List.unmodifiable(statusHeads.map((head) => head.id));

  DiscussionThreadStatus get status {
    final resolved = statusHeads.first.resolved;
    if (statusHeads.any((head) => head.resolved != resolved)) {
      return DiscussionThreadStatus.conflict;
    }
    return resolved
        ? DiscussionThreadStatus.resolved
        : DiscussionThreadStatus.open;
  }
}

final class DiscussionReadSnapshot {
  const new _({
    required this.metadataRevisionId,
    required this.deleted,
    required this.bodyAvailable,
    required this.bodyRevisionId,
    required this.threads,
  });

  final String metadataRevisionId;
  final bool deleted;
  final bool bodyAvailable;
  final String? bodyRevisionId;
  final List<DiscussionThread> threads;
}

/// Write guards run synchronously at publication and before idempotent returns.
/// A publication can check the same guard more than once.
final class DiscussionStore {
  const new(this.repository);

  final NoteRepository repository;

  Future<List<DiscussionThread>> listThreads(String pageId) async {
    final page = await _readPage(pageId);
    return List.unmodifiable(await _threads(page));
  }

  Future<DiscussionReadSnapshot> readSnapshot(String pageId) async {
    final page = await _readPage(pageId, allowUnreadableBody: true);
    return DiscussionReadSnapshot._(
      metadataRevisionId: page.metadata.revisionId,
      deleted: page.metadata.deleted,
      bodyAvailable: page.document != null,
      bodyRevisionId: page.bodyRevisionId,
      threads: List.unmodifiable(await _threads(page)),
    );
  }

  /// Confirms an immutable event associated with a caller-authenticated receipt.
  /// Later page edits and deletion preserve the acknowledgment of that event.
  Future<RevisionRecord> confirmPublication({
    required Map<String, dynamic> descriptor,
    required Uint8List eventBytes,
    required String pageId,
    required String eventId,
    required String expectedKind,
    required void Function() requireWrite,
  }) async {
    requireWrite();
    _id(pageId);
    _id(eventId);
    if (repository.formatVersion != 2 ||
        eventBytes.isEmpty ||
        eventBytes.length > _maxEventBytes) {
      throw const FormatException('Invalid discussion recovery input');
    }
    final prepared = repository.resumePreparedCommit(
      descriptor: descriptor,
      files: {_eventFile: eventBytes},
    );
    final record = prepared.record;
    if (record.formatVersion != 2 ||
        record.kind != EntityKind.attachment ||
        record.ownerNoteId != pageId ||
        record.entityId != eventId ||
        record.deviceId != repository.deviceId ||
        record.deleted ||
        record.parentRevisionIds.isNotEmpty ||
        record.baseRefs.isNotEmpty ||
        record.blobs.length != 1 ||
        !record.blobs.containsKey(_eventFile)) {
      throw const FormatException('Discussion recovery record scope mismatch');
    }

    final raw = utf8.decode(eventBytes);
    final json = jsonObject(jsonDecode(raw));
    final event = _DiscussionEvent.fromJson(json, record, pageId);
    if (json['kind'] != expectedKind ||
        jsonEncode(event.toJson(pageId)) != raw) {
      throw const FormatException('Discussion recovery event mismatch');
    }

    final published = await repository.confirmPublishedCommit(prepared);
    requireWrite();
    return published;
  }

  Future<String> createThread({
    required RevisionRecord page,
    required DiscussionAnchor anchor,
    required String body,
    String? eventId,
    DiscussionBodyRevision? expectedBodyRevision,
    void Function()? beforePublish,
    DiscussionPreparedHook? onPrepared,
  }) async {
    final id = _eventId(eventId, [page.entityId]);
    final text = _body(body);
    if (anchor.blockId case final blockId?) _id(blockId);
    final current = await _readPage(
      page.entityId,
      expected: page,
      expectedBodyRevision: expectedBodyRevision,
    );
    final event = _RootEvent(id, repository.deviceId, anchor, text);
    if (await _isPublished(current, event)) {
      beforePublish?.call();
      return id;
    }
    if (anchor.resolve(pageId: current.id, document: current.document) !=
        DiscussionAnchorStatus.attached) {
      throw StateError('Discussion anchor is no longer current');
    }
    return _publish(
      current,
      event,
      beforePublish: beforePublish,
      onPrepared: onPrepared,
    );
  }

  Future<String> reply({
    required RevisionRecord page,
    required String threadId,
    required String replyToId,
    required String body,
    String? eventId,
    DiscussionBodyRevision? expectedBodyRevision,
    void Function()? beforePublish,
    DiscussionPreparedHook? onPrepared,
  }) async {
    _id(threadId);
    _id(replyToId);
    final id = _eventId(eventId, [page.entityId, threadId, replyToId]);
    final event = _ReplyEvent(
      id,
      threadId,
      repository.deviceId,
      replyToId,
      _body(body),
    );
    final current = await _readPage(
      page.entityId,
      expected: page,
      expectedBodyRevision: expectedBodyRevision,
    );
    if (await _isPublished(current, event)) {
      beforePublish?.call();
      return id;
    }
    final thread = await _findThread(current, threadId);
    if (replyToId != thread.id &&
        !thread.replies.any((reply) => reply.id == replyToId)) {
      throw StateError('Reply target is unavailable in this discussion');
    }
    return _publish(
      current,
      event,
      beforePublish: beforePublish,
      onPrepared: onPrepared,
    );
  }

  Future<String> setResolved({
    required RevisionRecord page,
    required String threadId,
    required bool resolved,
    required List<String> expectedStatusIds,
    String? eventId,
    DiscussionBodyRevision? expectedBodyRevision,
    void Function()? beforePublish,
    DiscussionPreparedHook? onPrepared,
  }) async {
    _id(threadId);
    final expected = _statusIds(expectedStatusIds)..sort();
    final id = _eventId(eventId, [page.entityId, threadId, ...expected]);
    final event = _StatusEvent(
      id,
      threadId,
      repository.deviceId,
      resolved,
      expected,
    );
    final current = await _readPage(
      page.entityId,
      expected: page,
      expectedBodyRevision: expectedBodyRevision,
    );
    if (await _isPublished(current, event)) {
      beforePublish?.call();
      return id;
    }
    final thread = await _findThread(current, threadId);
    final statusIds = thread.statusHeadIds;
    if (statusIds.length != expected.length ||
        !expected.toSet().containsAll(statusIds)) {
      throw StateError('Discussion status changed before publication');
    }
    return _publish(
      current,
      event,
      beforePublish: beforePublish,
      onPrepared: onPrepared,
    );
  }

  Future<bool> _isPublished(
    _DiscussionPage page,
    _DiscussionEvent event,
  ) async {
    final record = page.eventRecords
        .where((record) => record.entityId == event.id)
        .singleOrNull;
    if (record == null) return false;
    if (record.deviceId != repository.deviceId ||
        record.blobs[_eventFile]!.length > _maxEventBytes ||
        utf8.decode(await repository.readRevisionFile(record, _eventFile)) !=
            jsonEncode(event.toJson(page.id))) {
      throw StateError(
        'Discussion event ID already has a different publication',
      );
    }
    return true;
  }

  Future<DiscussionThread> _findThread(_DiscussionPage page, String id) async {
    final thread = (await _threads(page))
        .where((thread) => thread.id == id)
        .singleOrNull;
    if (thread == null) throw StateError('Discussion thread is unavailable');
    return thread;
  }

  Future<String> _publish(
    _DiscussionPage page,
    _DiscussionEvent event, {
    void Function()? beforePublish,
    DiscussionPreparedHook? onPrepared,
  }) async {
    final bytes = utf8.encode(jsonEncode(event.toJson(page.id)));
    if (bytes.length > _maxEventBytes) {
      throw const FormatException('Discussion event is too large');
    }
    final prepared = repository.prepareCommit(
      entityId: event.id,
      kind: EntityKind.attachment,
      ownerNoteId: page.id,
      files: {_eventFile: Uint8List.fromList(bytes)},
      parentRevisionIds: [],
    );
    if (onPrepared != null) {
      beforePublish?.call();
      await onPrepared(prepared, Uint8List.fromList(bytes));
      beforePublish?.call();
    }
    await repository.commitPreparedIfHeads(
      prepared,
      expectedHeads: {...page.expectedHeads, event.id: []},
      expectedRevisionIds: page.revisionIds,
      beforePublish: beforePublish,
    );
    return event.id;
  }

  Future<_DiscussionPage> _readPage(
    String pageId, {
    RevisionRecord? expected,
    DiscussionBodyRevision? expectedBodyRevision,
    bool allowUnreadableBody = false,
  }) async {
    _id(pageId);
    if (expectedBodyRevision?.revisionId case final revisionId?) {
      _id(revisionId);
    }
    if (repository.formatVersion != 2 ||
        (expected != null &&
            (expected.vaultId != repository.vaultId ||
                expected.kind != EntityKind.metadata ||
                expected.ownerNoteId != null ||
                expected.deleted))) {
      throw StateError('Discussion requires a current page in this vault');
    }

    final records = await repository.revisions();
    final parents = records
        .expand((record) => record.parentRevisionIds)
        .toSet();
    final heads = <String, List<RevisionRecord>>{};
    final eventCounts = <String, int>{};
    for (final record in records) {
      if (!parents.contains(record.revisionId)) {
        (heads[record.entityId] ??= []).add(record);
      }
      if (record.kind == EntityKind.attachment &&
          record.ownerNoteId == pageId &&
          record.blobs.containsKey(_eventFile)) {
        eventCounts.update(
          record.entityId,
          (count) => count + 1,
          ifAbsent: () => 1,
        );
      }
    }

    final metadata = heads[pageId]?.singleOrNull;
    if (metadata == null ||
        metadata.kind != EntityKind.metadata ||
        metadata.ownerNoteId != null ||
        metadata.vaultId != repository.vaultId ||
        (expected != null &&
            (metadata.deleted || metadata.revisionId != expected.revisionId))) {
      throw StateError('Discussion page is missing, changed, or conflicted');
    }
    final values = await _readJson(metadata, 'note.json');
    if (values['documentKind'] != 'page' || values['title'] is! String) {
      throw StateError('Discussions belong to stored block pages');
    }
    final inkId = _id(values['inkEntityId']);
    final markdownId = _id(values['markdownEntityId']);
    if ({pageId, inkId, markdownId}.length != 3) {
      throw const FormatException('Invalid discussion page identities');
    }

    final expectedHeads = <String, List<String>>{
      pageId: [metadata.revisionId],
    };
    if (expected != null) {
      var folder = values['folderId'];
      while (folder != null) {
        final folderId = _id(folder);
        if (expectedHeads.length > 64 ||
            expectedHeads.containsKey(folderId) ||
            folderId == inkId ||
            folderId == markdownId) {
          throw const FormatException('Invalid discussion folder hierarchy');
        }
        final head = heads[folderId]?.singleOrNull;
        if (head == null ||
            head.kind != EntityKind.folder ||
            head.ownerNoteId != null ||
            head.deleted) {
          throw StateError('Discussion page folder is unavailable or in trash');
        }
        expectedHeads[folderId] = [head.revisionId];
        final folderJson = await _readJson(head, 'folder.json');
        if (folderJson['title'] is! String) {
          throw const FormatException('Invalid discussion folder metadata');
        }
        folder = folderJson['parentId'];
      }
    }

    final inkHeads = heads[inkId] ?? const [];
    final ink = inkHeads.singleOrNull;
    BlockPageDocument? document;
    if (inkHeads.isEmpty) {
      document = const BlockPageDocument.empty();
    } else if (ink != null &&
        ink.kind == EntityKind.ink &&
        ink.ownerNoteId == pageId &&
        !ink.deleted &&
        ink.blobs.containsKey('page.json')) {
      try {
        document = BlockPageDocument.fromJson(
          await _readJson(ink, 'page.json'),
        );
      } on FormatException {
        if (expected != null) rethrow;
      } on FileSystemException {
        if (!allowUnreadableBody) rethrow;
      }
    }
    if (expected != null && document == null) {
      throw StateError('Discussion page content is unavailable or conflicted');
    }
    if (expectedBodyRevision != null &&
        ink?.revisionId != expectedBodyRevision.revisionId) {
      throw StateError('Discussion page body changed before publication');
    }
    expectedHeads[inkId] = [for (final head in inkHeads) head.revisionId];
    final eventRecords = [
      for (final id in eventCounts.keys)
        if (eventCounts[id] == 1)
          if (heads[id]?.singleOrNull case final record?)
            if (record.kind == EntityKind.attachment &&
                record.ownerNoteId == pageId &&
                !record.deleted &&
                record.parentRevisionIds.isEmpty &&
                record.baseRefs.isEmpty &&
                record.blobs.length == 1 &&
                record.blobs.containsKey(_eventFile))
              record,
    ];
    return (
      id: pageId,
      metadata: metadata,
      document: document,
      bodyRevisionId: document == null ? null : ink?.revisionId,
      expectedHeads: expectedHeads,
      revisionIds: records.map((record) => record.revisionId).toList(),
      eventRecords: eventRecords,
    );
  }

  Future<Map<String, dynamic>> _readJson(
    RevisionRecord record,
    String file,
  ) async => jsonObject(
    jsonDecode(utf8.decode(await repository.readRevisionFile(record, file))),
  );

  Future<List<DiscussionThread>> _threads(_DiscussionPage page) async {
    final groups = <String, List<_DiscussionEvent>>{};
    for (final record in page.eventRecords) {
      if (record.blobs[_eventFile]!.length > _maxEventBytes) continue;
      try {
        final event = _DiscussionEvent.fromJson(
          await _readJson(record, _eventFile),
          record,
          page.id,
        );
        (groups[event.threadId] ??= []).add(event);
      } on FormatException {
        // Other valid conversations can still be read alongside a malformed event.
      }
    }

    return [
      for (final id in groups.keys.toList()..sort())
        if (groups[id]!.whereType<_RootEvent>().singleOrNull case final root?)
          _project(page, root, groups[id]!),
    ];
  }
}

typedef _DiscussionPage = ({
  String id,
  RevisionRecord metadata,
  BlockPageDocument? document,
  String? bodyRevisionId,
  Map<String, List<String>> expectedHeads,
  List<String> revisionIds,
  List<RevisionRecord> eventRecords,
});

DiscussionThread _project(
  _DiscussionPage page,
  _RootEvent root,
  List<_DiscussionEvent> events,
) {
  events.sort((a, b) => a.id.compareTo(b.id));
  final repliesByParent = <String, List<_ReplyEvent>>{};
  final statusByParent = <String, List<_StatusEvent>>{};
  final waiting = <String, int>{};
  for (final event in events) {
    switch (event) {
      case _ReplyEvent(:final replyToId):
        (repliesByParent[replyToId] ??= []).add(event);
      case _StatusEvent(:final parentIds):
        waiting[event.id] = parentIds.length;
        for (final parent in parentIds) {
          (statusByParent[parent] ??= []).add(event);
        }
      case _RootEvent():
        break;
    }
  }

  final messages = <DiscussionMessage>[root.message];
  for (var index = 0; index < messages.length; index++) {
    final children = repliesByParent[messages[index].id];
    if (children != null)
      messages.addAll(children.map((child) => child.message));
  }

  final ready = <String>[root.id];
  final heads = <String, bool>{root.id: false};
  for (var index = 0; index < ready.length; index++) {
    for (final status
        in statusByParent[ready[index]] ?? const <_StatusEvent>[]) {
      final missing = waiting.update(status.id, (count) => count - 1);
      if (missing != 0) continue;
      for (final parent in status.parentIds) {
        heads.remove(parent);
      }
      heads[status.id] = status.resolved;
      ready.add(status.id);
    }
  }
  return DiscussionThread._(
    anchor: root.anchor,
    anchorStatus: root.anchor.resolve(pageId: page.id, document: page.document),
    root: root.message,
    replies: messages.sublist(1),
    statusHeads: [
      for (final id in heads.keys.toList()..sort())
        (id: id, resolved: heads[id]!),
    ],
  );
}

const _eventFile = 'discussion-event.json';
const _maxEventBytes = 64 * 1024;
const _maxBodyBytes = 8 * 1024;
const _maxStatusParents = 1024;

String _eventId(String? value, List<String> reserved) {
  final id = _id(value ?? newId());
  if (reserved.contains(id)) {
    throw const FormatException('Discussion event ID has a different role');
  }
  return id;
}

String _id(Object? value) {
  if (value is! String || value.length != 36) {
    throw const FormatException('Invalid discussion UUID');
  }
  validateId(value);
  return value;
}

String _body(Object? value) {
  if (value is! String ||
      value.length > _maxBodyBytes ||
      value.trim().isEmpty ||
      value.contains('\u0000')) {
    throw const FormatException('Invalid discussion message');
  }
  final bytes = utf8.encode(value);
  if (bytes.length > _maxBodyBytes || utf8.decode(bytes) != value) {
    throw const FormatException('Invalid discussion message encoding or size');
  }
  return value;
}

List<String> _statusIds(Object? value) {
  if (value is! List || value.isEmpty || value.length > _maxStatusParents) {
    throw const FormatException('Invalid discussion status parents');
  }
  final ids = value.map(_id).toList();
  if (ids.toSet().length != ids.length) {
    throw const FormatException('Duplicate discussion status parents');
  }
  return ids;
}

sealed class _DiscussionEvent {
  const new(this.id, this.threadId, this.authorDeviceId);

  final String id;
  final String threadId;
  final String authorDeviceId;

  factory fromJson(
    Map<String, dynamic> json,
    RevisionRecord record,
    String pageId,
  ) {
    final id = _id(json['eventId']);
    final thread = _id(json['threadId']);
    final author = _id(json['authorDeviceId']);
    if (json['version'] is! int ||
        json['version'] != 1 ||
        _id(json['pageId']) != pageId ||
        id != record.entityId ||
        id == pageId ||
        thread == pageId ||
        author != record.deviceId) {
      throw const FormatException('Discussion event scope mismatch');
    }
    switch (json['kind']) {
      case 'thread':
        final anchor = DiscussionAnchor.fromJson(jsonObject(json['anchor']));
        if (json.length != 8 || id != thread || _id(anchor.pageId) != pageId) {
          throw const FormatException('Invalid discussion root');
        }
        if (anchor.blockId case final blockId?) _id(blockId);
        return _RootEvent(id, author, anchor, _body(json['body']));
      case 'reply':
        final target = _id(json['replyToId']);
        if (json.length != 8 ||
            id == thread ||
            target == id ||
            target == pageId) {
          throw const FormatException('Invalid discussion reply');
        }
        return _ReplyEvent(id, thread, author, target, _body(json['body']));
      case 'status':
        final parents = _statusIds(json['statusParentIds']);
        final resolved = json['resolved'];
        if (json.length != 8 ||
            id == thread ||
            resolved is! bool ||
            parents.contains(id) ||
            parents.contains(pageId)) {
          throw const FormatException('Invalid discussion status');
        }
        return _StatusEvent(id, thread, author, resolved, parents);
      default:
        throw const FormatException('Unknown discussion event kind');
    }
  }

  Map<String, Object?> toJson(String pageId) => {
    'version': 1,
    'pageId': pageId,
    'eventId': id,
    'threadId': threadId,
    'authorDeviceId': authorDeviceId,
    ...switch (this) {
      _RootEvent(:final anchor, :final body) => {
        'kind': 'thread',
        'anchor': anchor.toJson(),
        'body': body,
      },
      _ReplyEvent(:final replyToId, :final body) => {
        'kind': 'reply',
        'replyToId': replyToId,
        'body': body,
      },
      _StatusEvent(:final resolved, :final parentIds) => {
        'kind': 'status',
        'resolved': resolved,
        'statusParentIds': parentIds,
      },
    },
  };
}

final class _RootEvent extends _DiscussionEvent {
  const new(String id, String author, this.anchor, this.body)
    : super(id, id, author);

  final DiscussionAnchor anchor;
  final String body;

  DiscussionMessage get message =>
      DiscussionMessage._(id, authorDeviceId, body);
}

final class _ReplyEvent extends _DiscussionEvent {
  const new(
    super.id,
    super.threadId,
    super.authorDeviceId,
    this.replyToId,
    this.body,
  );

  final String replyToId;
  final String body;

  DiscussionMessage get message =>
      DiscussionMessage._(id, authorDeviceId, body, replyToId: replyToId);
}

final class _StatusEvent extends _DiscussionEvent {
  const new(
    super.id,
    super.threadId,
    super.authorDeviceId,
    this.resolved,
    this.parentIds,
  );

  final bool resolved;
  final List<String> parentIds;
}
