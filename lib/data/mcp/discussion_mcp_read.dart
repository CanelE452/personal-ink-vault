import 'package:saber/data/mcp/vault_mcp_bridge.dart';
import 'package:saber/data/vault/discussion_store.dart';

Map<String, Object?> discussionReadPage(
  List<DiscussionThread> threads, {
  required int limit,
  String? threadId,
  String? afterThreadId,
  String? afterReplyId,
}) {
  if (threadId == null) {
    final start = _startAfter(
      threads.map((thread) => thread.id),
      afterThreadId,
    );
    final page = threads.skip(start).take(limit).toList(growable: false);
    return {
      'threads': [for (final thread in page) _threadData(thread)],
      'totalThreads': threads.length,
      'nextAfterThreadId': start + page.length < threads.length
          ? page.last.id
          : null,
    };
  }

  final thread = threads.where((thread) => thread.id == threadId).singleOrNull;
  if (thread == null) {
    throw const VaultMcpException('not_found', '댓글 스레드를 찾을 수 없습니다.');
  }
  final replies = thread.replies;
  final start = _startAfter(replies.map((reply) => reply.id), afterReplyId);
  final page = replies.skip(start).take(limit).toList(growable: false);
  return {
    'thread': {
      ..._threadData(thread),
      'statusHeads': [
        for (final head in thread.statusHeads)
          {'id': head.id, 'resolved': head.resolved},
      ],
    },
    'replies': [for (final reply in page) _messageData(reply)],
    'totalReplies': replies.length,
    'nextAfterReplyId': start + page.length < replies.length
        ? page.last.id
        : null,
  };
}

int _startAfter(Iterable<String> ids, String? cursor) {
  if (cursor == null) return 0;
  var index = 0;
  for (final id in ids) {
    index++;
    if (id == cursor) return index;
  }
  throw const VaultMcpException(
    'stale_cursor',
    '댓글 목록이 바뀌었습니다. 첫 항목부터 다시 읽으세요.',
  );
}

Map<String, Object?> _threadData(DiscussionThread thread) => {
  'threadId': thread.id,
  'anchor': thread.anchor.toJson(),
  'anchorStatus': thread.anchorStatus.name,
  'status': thread.status.name,
  'statusHeadCount': thread.statusHeads.length,
  'root': _messageData(thread.root),
  'replyCount': thread.replies.length,
};

Map<String, Object?> _messageData(DiscussionMessage message) => {
  'id': message.id,
  'authorDeviceId': message.authorDeviceId,
  'body': message.body,
  'replyToId': ?message.replyToId,
};
