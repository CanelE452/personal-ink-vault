import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/mcp/vault_mcp_bridge.dart';
import 'package:saber/data/mcp/vault_mcp_service.dart';
import 'package:saber/data/vault/block_page_document.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/pages/workspace/workspace_controller.dart';

typedef _SavedPage = ({
  VaultNote note,
  BlockPageBlock block,
  RevisionRecord body,
});

Matcher _mcpError(String code) =>
    isA<VaultMcpException>().having((error) => error.code, 'code', code);

Map<String, dynamic> _createThread(Map<String, dynamic> anchor, String body) =>
    {'type': 'create_thread', 'anchor': anchor, 'body': body};

Map<String, dynamic> _mutation(
  VaultNote note,
  Map<String, dynamic> expectedBody,
  Map<String, dynamic> action,
) => {
  'noteId': note.id,
  'expectedMetadataRevisionId': note.revision.revisionId,
  'expectedBody': expectedBody,
  'requestId': newId(),
  'action': action,
};

Map<String, dynamic> _savedBody(RevisionRecord record) => {
  'kind': 'saved',
  'revisionId': record.revisionId,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late WorkspaceController controller;
  late VaultMcpService service;
  final writable = VaultMcpCallContext(
    isActive: () => true,
    canWrite: () => true,
  );
  final readOnly = VaultMcpCallContext(
    isActive: () => true,
    canWrite: () => false,
  );
  final revoked = VaultMcpCallContext(
    isActive: () => false,
    canWrite: () => true,
  );

  Future<void> open() async {
    controller = WorkspaceController(
      await NoteRepository.open(temp, createFormatVersion: 2),
    );
    service = VaultMcpService(controller);
  }

  Future<void> close() async {
    await controller.flush();
    controller.dispose();
    await controller.repository.close();
  }

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('discussion-mcp-service-');
    await open();
  });

  tearDown(() async {
    await close();
    final actual = await temp.resolveSymbolicLinks();
    final parent = await Directory.systemTemp.resolveSymbolicLinks();
    expect(p.dirname(actual), p.normalize(parent));
    expect(p.basename(actual), startsWith('discussion-mcp-service-'));
    await Directory(actual).delete(recursive: true);
  });

  Future<Map<String, dynamic>> call(
    String operation,
    Map<String, dynamic> arguments, {
    VaultMcpCallContext? access,
  }) async => Map<String, dynamic>.from(
    await service.call(operation, arguments, context: access ?? writable)
        as Map,
  );

  Future<VaultNote> newPage() =>
      controller.store.create('댓글 페이지', documentKind: VaultDocumentKind.page);

  Future<RevisionRecord> writeBody(
    VaultNote note,
    BlockPageBlock block, {
    List<String> parents = const [],
  }) {
    final document = const BlockPageDocument.empty().copyWith(blocks: [block]);
    return controller.repository.commit(
      entityId: note.inkEntityId,
      kind: EntityKind.ink,
      ownerNoteId: note.id,
      parentRevisionIds: parents,
      files: {
        'page.json': Uint8List.fromList(
          utf8.encode(jsonEncode(document.toJson())),
        ),
      },
    );
  }

  Future<_SavedPage> savedPage() async {
    final note = await newPage();
    final block = BlockPageBlock.create(type: 'paragraph', text: '앞😀한뒤');
    final body = await writeBody(note, block);
    return (note: note, block: block, body: body);
  }

  Future<Set<String>> revisionIds() async => {
    for (final record in await controller.repository.revisions())
      record.revisionId,
  };

  Future<Map<String, dynamic>> mutate(
    _SavedPage page,
    Map<String, dynamic> action,
  ) => call(
    'mutate_page_discussion',
    _mutation(page.note, _savedBody(page.body), action),
  );

  test('discussion routes preserve UTF-16 anchors and paginate threads and replies', () async {
    final page = await savedPage();
    final anchors = <Map<String, dynamic>>[
      {'kind': 'page'},
      {'kind': 'block', 'blockId': page.block.id},
      {
        'kind': 'quote',
        'blockId': page.block.id,
        'startUtf16': 1,
        'endUtf16': 4,
      },
    ];
    final created = <String, String>{};
    for (final anchor in anchors) {
      final kind = anchor['kind'] as String;
      final result = await mutate(page, _createThread(anchor, '댓글 $kind'));
      final threadId = result['threadId'] as String;
      created[kind] = threadId;
      expect(result['noteId'], page.note.id);
      expect(result['eventId'], threadId);
      final saved = (await controller.repository.heads(threadId)).single;
      expect(result['revisionId'], saved.revisionId);
      expect(saved.ownerNoteId, page.note.id);
    }

    final orderedIds = created.values.toList()..sort();
    final first = await call('list_page_discussions', {
      'noteId': page.note.id,
      'limit': 1,
    }, access: readOnly);
    expect(first['metadataRevisionId'], page.note.revision.revisionId);
    expect(first['body'], _savedBody(page.body));
    expect(first['totalThreads'], 3);
    expect(first['nextAfterThreadId'], orderedIds.first);
    final second = await call('list_page_discussions', {
      'noteId': page.note.id,
      'afterThreadId': first['nextAfterThreadId'],
      'limit': 2,
    }, access: readOnly);
    expect(second['nextAfterThreadId'], isNull);
    final summaries = [
      ...(first['threads'] as List).cast<Map>(),
      ...(second['threads'] as List).cast<Map>(),
    ];
    expect(summaries.map((thread) => thread['threadId']), orderedIds);
    for (final summary in summaries) {
      final anchor = summary['anchor'] as Map;
      expect(anchor['pageId'], page.note.id);
      expect(summary['anchorStatus'], 'attached');
      expect(created[anchor['kind']], summary['threadId']);
      if (anchor['kind'] != 'page') expect(anchor['blockId'], page.block.id);
      if (anchor['kind'] == 'quote') {
        expect(anchor['startUtf16'], 1);
        expect(anchor['endUtf16'], 4);
        expect(anchor['quote'], '😀한');
      }
    }

    final threadId = created['quote']!;
    final replies = <String, String>{};
    for (final body in ['답글 하나', '답글 둘']) {
      final result = await mutate(page, {
        'type': 'reply',
        'threadId': threadId,
        'replyToId': threadId,
        'body': body,
      });
      expect(result['threadId'], threadId);
      replies[result['eventId'] as String] = body;
    }
    final resolved = await mutate(page, {
      'type': 'set_resolved',
      'threadId': threadId,
      'resolved': true,
      'expectedStatusIds': [threadId],
    });
    final replyIds = replies.keys.toList()..sort();
    final detail = await call('list_page_discussions', {
      'noteId': page.note.id,
      'threadId': threadId,
      'limit': 1,
    }, access: readOnly);
    expect(detail['metadataRevisionId'], page.note.revision.revisionId);
    expect(detail['body'], _savedBody(page.body));
    final thread = detail['thread'] as Map;
    expect(thread['threadId'], threadId);
    expect(thread['status'], 'resolved');
    expect(thread['statusHeads'], [
      {'id': resolved['eventId'], 'resolved': true},
    ]);
    expect(detail['totalReplies'], 2);
    final firstReply = (detail['replies'] as List).single as Map;
    expect(firstReply['id'], replyIds.first);
    expect(firstReply['replyToId'], threadId);
    expect(firstReply['body'], replies[replyIds.first]);
    expect(detail['nextAfterReplyId'], replyIds.first);
    final tail = await call('list_page_discussions', {
      'noteId': page.note.id,
      'threadId': threadId,
      'afterReplyId': detail['nextAfterReplyId'],
      'limit': 1,
    }, access: readOnly);
    final lastReply = (tail['replies'] as List).single as Map;
    expect(lastReply['id'], replyIds.last);
    expect(lastReply['body'], replies[replyIds.last]);
    expect(tail['nextAfterReplyId'], isNull);

    final before = await revisionIds();
    await expectLater(
      mutate(
        page,
        _createThread({
          'kind': 'quote',
          'blockId': page.block.id,
          'startUtf16': 2,
          'endUtf16': 4,
        }, '잘못된 범위'),
      ),
      throwsA(_mcpError('invalid_arguments')),
    );
    expect(await revisionIds(), before);
  });

  test(
    'read-only connections can list and cannot reserve a mutation',
    () async {
      final note = await newPage();
      final listed = await call('list_page_discussions', {
        'noteId': note.id,
      }, access: readOnly);
      expect(listed['metadataRevisionId'], note.revision.revisionId);
      expect(listed['body'], {'kind': 'empty'});
      expect(listed['threads'], isEmpty);
      await expectLater(
        call('list_page_discussions', {'noteId': note.id}, access: revoked),
        throwsA(_mcpError('authorization_revoked')),
      );
      final request = _mutation(note, {
        'kind': 'empty',
      }, _createThread({'kind': 'page'}, '읽기 권한 대조'));
      final before = await revisionIds();
      await expectLater(
        call('mutate_page_discussion', request, access: readOnly),
        throwsA(_mcpError('read_only')),
      );
      expect(await revisionIds(), before);
      final allowed = await call('mutate_page_discussion', request);
      expect(allowed['noteId'], note.id);
      expect((await revisionIds()).difference(before), {allowed['revisionId']});
    },
  );

  test(
    'revocation while writing a receipt keeps the same request retryable',
    () async {
      final note = await newPage();
      final request = _mutation(note, {
        'kind': 'empty',
      }, _createThread({'kind': 'page'}, '영수증 쓰기 중 권한 철회'));
      final journal = Directory(
        p.join(temp.path, '.workspace', 'mcp', 'requests'),
      );
      final receipt = File(
        p.join(journal.path, '${request['requestId']}.json'),
      );
      var sawStagedReceipt = false;
      final revoking = VaultMcpCallContext(
        isActive: () => true,
        canWrite: () {
          if (journal.existsSync() &&
              journal.listSync().any(
                (entry) => p.basename(entry.path).endsWith('.pending'),
              )) {
            sawStagedReceipt = true;
          }
          return !sawStagedReceipt;
        },
      );
      final before = await revisionIds();
      await expectLater(
        call('mutate_page_discussion', request, access: revoking),
        throwsA(_mcpError('read_only')),
      );
      expect(sawStagedReceipt, isTrue);
      expect(receipt.existsSync(), isFalse);
      expect(journal.listSync(), isEmpty);
      expect(await revisionIds(), before);
      final saved = await call('mutate_page_discussion', request);
      expect((await revisionIds()).difference(before), {saved['revisionId']});
    },
  );

  test(
    'revocation after the receipt keeps an unpublished event out of the vault',
    () async {
      final note = await newPage();
      final request = _mutation(note, {
        'kind': 'empty',
      }, _createThread({'kind': 'page'}, '게시 직전 권한 철회'));
      final receipt = File(
        p.join(
          temp.path,
          '.workspace',
          'mcp',
          'requests',
          '${request['requestId']}.json',
        ),
      );
      final revoking = VaultMcpCallContext(
        isActive: () => true,
        canWrite: () => !receipt.existsSync(),
      );
      final before = await revisionIds();
      await expectLater(
        call('mutate_page_discussion', request, access: revoking),
        throwsA(_mcpError('read_only')),
      );
      expect(receipt.existsSync(), isTrue);
      expect(await revisionIds(), before);
      await expectLater(
        call('mutate_page_discussion', request),
        throwsA(_mcpError('operation_state_unknown')),
      );
      expect(await revisionIds(), before);
    },
  );

  test(
    'invalid list arguments are rejected before looking up a page',
    () async {
      final missingPage = newId();
      for (final extra in [
        {'limit': 0},
        {'limit': 101},
        {'limit': null},
        {'threadId': null},
        {'afterThreadId': 'bad-id'},
        {'afterReplyId': newId()},
        {'threadId': newId(), 'afterThreadId': newId()},
      ]) {
        await expectLater(
          call('list_page_discussions', {'noteId': missingPage, ...extra}),
          throwsA(_mcpError('invalid_arguments')),
        );
      }
    },
  );

  test('saved body guard rejects stale text with unchanged metadata', () async {
    final page = await savedPage();
    final request = _mutation(
      page.note,
      _savedBody(page.body),
      _createThread({'kind': 'page'}, '오래된 본문 기준'),
    );
    final updated = await writeBody(
      page.note,
      BlockPageBlock.create(type: 'paragraph', text: '갱신한 본문'),
      parents: [page.body.revisionId],
    );
    final listed = await call('list_page_discussions', {
      'noteId': page.note.id,
    });
    expect(listed['metadataRevisionId'], page.note.revision.revisionId);
    expect(listed['body'], _savedBody(updated));
    final before = await revisionIds();
    await expectLater(
      call('mutate_page_discussion', request),
      throwsA(_mcpError('revision_conflict')),
    );
    expect(await revisionIds(), before);
  });

  test(
    'conflicted body is reported unavailable through the read route',
    () async {
      final page = await savedPage();
      await writeBody(
        page.note,
        BlockPageBlock.create(type: 'paragraph', text: '독립 분기'),
      );
      expect(
        await controller.repository.heads(page.note.inkEntityId),
        hasLength(2),
      );
      final result = await call('list_page_discussions', {
        'noteId': page.note.id,
      });
      expect(result['metadataRevisionId'], page.note.revision.revisionId);
      expect(result['body'], {'kind': 'unavailable'});
    },
  );

  test('cold retry after trash returns the original event and rejects a changed digest', () async {
    final page = await savedPage();
    final request = _mutation(
      page.note,
      _savedBody(page.body),
      _createThread({'kind': 'page'}, '처음 저장한 댓글 😀'),
    );
    final created = await call('mutate_page_discussion', request);
    final repo = controller.repository;
    final tombstone = await repo.commit(
      entityId: page.note.id,
      kind: EntityKind.metadata,
      parentRevisionIds: [page.note.revision.revisionId],
      files: await repo.readFiles(page.note.revision),
      deleted: true,
    );
    final before = await revisionIds();
    await close();
    await open();
    final current = (await controller.repository.heads(page.note.id)).single;
    expect(current.deleted, isTrue);
    expect(current.revisionId, tombstone.revisionId);
    final archived = await call('list_page_discussions', {
      'noteId': page.note.id,
    }, access: readOnly);
    expect(archived['deleted'], isTrue);
    expect(archived['metadataRevisionId'], tombstone.revisionId);
    expect(
      (archived['threads'] as List).single['threadId'],
      created['threadId'],
    );

    final replay = await call('mutate_page_discussion', request);
    expect(replay, created);
    expect(await revisionIds(), before);
    await expectLater(
      call('mutate_page_discussion', {
        ...request,
        'action': {
          ...(request['action'] as Map<String, dynamic>),
          'body': '같은 요청 ID로 다른 댓글',
        },
      }),
      throwsA(_mcpError('request_id_reused')),
    );
    expect(await revisionIds(), before);
  });
}
