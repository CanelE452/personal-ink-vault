import 'dart:convert';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/mcp/vault_mcp_bridge.dart';

typedef DiscussionMcpReceipt = ({
  Map<String, dynamic> descriptor,
  Uint8List eventBytes,
  String eventId,
  String kind,
  String threadId,
});

const _maxEventBytes = 64 * 1024;
const _receiptFields = {
  'version',
  'operation',
  'requestId',
  'digest',
  'descriptor',
  'eventBytes',
};

DiscussionMcpReceipt readDiscussionMcpReceipt(
  Map<String, dynamic> stored, {
  required String noteId,
  required String requestId,
  required String digest,
  required Map<String, dynamic> action,
}) {
  if (stored['requestId'] == requestId && stored['digest'] != digest) {
    throw const VaultMcpException(
      'request_id_reused',
      '같은 요청 ID에 다른 내용을 사용할 수 없습니다.',
    );
  }

  try {
    final encoded = stored['eventBytes'];
    if (stored.length != _receiptFields.length ||
        !stored.keys.every(_receiptFields.contains) ||
        stored['version'] is! int ||
        stored['version'] != 1 ||
        stored['operation'] != 'mutate_page_discussion' ||
        stored['requestId'] != requestId ||
        encoded is! String ||
        encoded.length > ((_maxEventBytes + 2) ~/ 3) * 4) {
      throw const FormatException('Invalid discussion receipt envelope');
    }
    final bytes = base64Decode(encoded);
    if (bytes.length > _maxEventBytes || base64Encode(bytes) != encoded) {
      throw const FormatException('Invalid discussion receipt encoding');
    }
    final descriptor = jsonObject(stored['descriptor']);
    final record = jsonObject(descriptor['record']);
    final event = jsonObject(jsonDecode(utf8.decode(bytes)));
    final id = event['eventId'];
    final thread = event['threadId'];
    final kind = event['kind'];
    if (id is! String ||
        thread is! String ||
        kind is! String ||
        event['pageId'] != noteId ||
        record['entityId'] != id ||
        !_matchesAction(action, event, id)) {
      throw const FormatException('Discussion receipt action changed');
    }
    validateId(id);
    validateId(thread);
    return (
      descriptor: descriptor,
      eventBytes: bytes,
      eventId: id,
      kind: kind,
      threadId: thread,
    );
  } on FormatException {
    throw const VaultMcpException(
      'operation_state_unknown',
      '이전 댓글 요청의 저장 기록을 확인하지 못했습니다.',
    );
  }
}

bool _matchesAction(
  Map<String, dynamic> action,
  Map<String, dynamic> event,
  String eventId,
) => switch (action['type']) {
  'create_thread' =>
    event['kind'] == 'thread' &&
        event['threadId'] == eventId &&
        event['body'] == action['body'] &&
        _matchesAnchor(
          jsonObject(action['anchor']),
          jsonObject(event['anchor']),
        ),
  'reply' =>
    event['kind'] == 'reply' &&
        event['threadId'] == action['threadId'] &&
        event['replyToId'] == action['replyToId'] &&
        event['body'] == action['body'],
  'set_resolved' =>
    event['kind'] == 'status' &&
        event['threadId'] == action['threadId'] &&
        event['resolved'] == action['resolved'] &&
        _matchesParents(action['expectedStatusIds'], event['statusParentIds']),
  _ => false,
};

bool _matchesAnchor(Map<String, dynamic> input, Map<String, dynamic> anchor) {
  if (input['kind'] != anchor['kind']) return false;
  return switch (input['kind']) {
    'page' => true,
    'block' => input['blockId'] == anchor['blockId'],
    'quote' =>
      input['blockId'] == anchor['blockId'] &&
          input['startUtf16'] == anchor['startUtf16'] &&
          input['endUtf16'] == anchor['endUtf16'],
    _ => false,
  };
}

bool _matchesParents(Object? input, Object? stored) {
  if (input is! List ||
      input.any((value) => value is! String) ||
      stored is! List) {
    return false;
  }
  final expected = input.cast<String>().toList()..sort();
  return const ListEquality<Object?>().equals(expected, stored);
}
