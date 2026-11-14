import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as im;
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/mcp/vault_mcp_bridge.dart';
import 'package:saber/data/mcp/vault_mcp_service.dart';
import 'package:saber/data/vault/block_page_document.dart';
import 'package:saber/data/vault/block_page_media.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/pages/workspace/workspace_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late WorkspaceController controller;
  late VaultMcpService service;
  var active = true;
  final context = VaultMcpCallContext(
    isActive: () => active,
    canWrite: () => false,
  );

  setUp(() async {
    active = true;
    directory = await Directory.systemTemp.createTemp('mcp-page-media-');
    controller = WorkspaceController(
      await NoteRepository.open(directory, createFormatVersion: 2),
    );
    service = VaultMcpService(controller);
  });
  tearDown(() async {
    controller.dispose();
    await controller.repository.close();
    await directory.delete(recursive: true);
  });
  Matcher error(String code) =>
      isA<VaultMcpException>().having((e) => e.code, 'code', code);
  Future<(NoteSession, BlockPageDocument, BlockPageMediaAsset)> fixture({
    bool image = false,
  }) async {
    final asset = image
        ? BlockPageMediaAsset.image(
            name: '연구 사진.png',
            bytes: im.encodePng(im.Image(width: 3, height: 2)),
          )
        : BlockPageMediaAsset.attachment(
            name: '../강의 자료.pdf',
            bytes: utf8.encode('한글 abc 😀'),
          );
    final block = BlockPageBlock.create(
      type: image ? 'image' : 'attachment',
      text: '미디어 설명',
    );
    final page = const BlockPageDocument.empty().copyWith(
      blocks: [block],
      media: {block.id: asset.reference},
    );
    final note = await controller.store.create(
      'Page',
      documentKind: VaultDocumentKind.page,
    );
    final session = await controller.store.open(note);
    await session.saveInk({
      'page.json': Uint8List.fromList(utf8.encode(jsonEncode(page.toJson()))),
      asset.reference.path: asset.bytes,
    });
    return (session, page, asset);
  }

  Map<String, dynamic> selector(NoteSession session, BlockPageDocument page) =>
      {
        'noteId': session.note.id,
        'revisionId': session.inkParents.single,
        'blockId': page.blocks.single.id,
      };
  Future<Map<String, dynamic>> read(Map<String, dynamic> args) async =>
      Map<String, dynamic>.from(
        await service.call('read_page_media', args, context: context) as Map,
      );

  test(
    'read-only metadata binds a registered block and does not expose payloads',
    () async {
      final (session, page, asset) = await fixture();
      final count = (await controller.repository.revisions()).length;
      final result = await read(selector(session, page));
      expect(result['noteId'], session.note.id);
      expect(result['revisionId'], session.inkParents.single);
      expect(result['media'], asset.reference.toJson());
      expect(result.containsKey('dataBase64'), false);
      expect(result.containsKey('image'), false);
      expect((await controller.repository.revisions()).length, count);
    },
  );

  test(
    'original byte chunks reconstruct exact Unicode bytes and bounded EOF',
    () async {
      final (session, page, asset) = await fixture();
      final collected = BytesBuilder();
      var offset = 0;
      while (true) {
        final result = await read({
          ...selector(session, page),
          'mode': 'bytes',
          'offset': offset,
          'limit': 3,
        });
        final bytes = base64Decode(result['dataBase64'] as String);
        expect(bytes.length, lessThanOrEqualTo(3));
        expect(result['offset'], offset);
        collected.add(bytes);
        offset += bytes.length;
        if (result['eof'] == true) break;
        expect(result['nextOffset'], offset);
      }
      expect(collected.takeBytes(), asset.bytes);
      final eof = await read({
        ...selector(session, page),
        'mode': 'bytes',
        'offset': asset.bytes.length,
      });
      expect(eof['dataBase64'], '');
      expect(eof['eof'], true);
      await expectLater(
        read({
          ...selector(session, page),
          'mode': 'bytes',
          'offset': asset.bytes.length + 1,
        }),
        throwsA(error('invalid_arguments')),
      );
    },
  );

  test(
    'image preview returns a real bounded PNG without changing source bytes',
    () async {
      final (session, page, asset) = await fixture(image: true);
      final result = await read({
        ...selector(session, page),
        'mode': 'preview',
        'maxDimension': 64,
      });
      final image = result['image'] as Map;
      expect(image['mimeType'], 'image/png');
      final bytes = base64Decode(image['data'] as String);
      final decoded = im.decodePng(bytes)!;
      expect(decoded.width, lessThanOrEqualTo(64));
      expect(decoded.height, lessThanOrEqualTo(64));
      expect(bytes.length, lessThanOrEqualTo(1024 * 1024));
      final record = (await controller.repository.revisions()).singleWhere(
        (r) => r.revisionId == session.inkParents.single,
      );
      expect(
        (await controller.repository.readFiles(record))[asset.reference.path],
        asset.bytes,
      );
    },
  );

  test(
    'attachment preview is explicit unsupported and never executes the file',
    () async {
      final (session, page, _) = await fixture();
      await expectLater(
        read({...selector(session, page), 'mode': 'preview'}),
        throwsA(error('unsupported')),
      );
    },
  );

  test('foreign page revisions metadata revisions and unregistered blocks cannot read bytes', () async {
    final (session, page, _) = await fixture();
    final (other, _, _) = await fixture();
    await expectLater(
      read({...selector(session, page), 'revisionId': other.inkParents.single}),
      throwsA(error('revision_not_owned')),
    );
    final metadata = (await controller.repository.heads(session.note.id))
        .single;
    await expectLater(
      read({...selector(session, page), 'revisionId': metadata.revisionId}),
      throwsA(error('revision_not_owned')),
    );
    await expectLater(
      read({...selector(session, page), 'blockId': newId()}),
      throwsA(error('not_found')),
    );
  });

  test('historical owned media remains readable after removal from the current page', () async {
    final (session, page, asset) = await fixture();
    final historical = selector(session, page);
    await session.saveInk({
      'page.json': Uint8List.fromList(
        utf8.encode(jsonEncode(page.copyWith(blocks: []).toJson())),
      ),
    });
    final result = await read({...historical, 'mode': 'bytes'});
    expect(base64Decode(result['dataBase64'] as String), asset.bytes);
  });

  test('missing registered payload is an integrity error rather than empty success', () async {
    final (session, page, _) = await fixture();
    await session.saveInk({
      'page.json': Uint8List.fromList(utf8.encode(jsonEncode(page.toJson()))),
    });
    await expectLater(
      read(selector(session, page)),
      throwsA(error('media_integrity_error')),
    );
  });

  test('closed selectors and mode budgets reject paths hashes nulls and incompatible arguments', () async {
    final (session, page, _) = await fixture();
    final base = selector(session, page);
    final invalid = <Map<String, dynamic>>[
      for (final key in ['path', 'hash', 'url', 'source'])
        {...base, key: 'outside'},
      for (final key in ['noteId', 'revisionId', 'blockId'])
        {...base, key: null},
      {...base, 'blockId': '../../other'},
      {...base, 'mode': null},
      {...base, 'mode': 'execute'},
      {...base, 'offset': 0},
      {...base, 'mode': 'bytes', 'offset': -1},
      {...base, 'mode': 'bytes', 'limit': 0},
      {...base, 'mode': 'bytes', 'limit': 262145},
      {...base, 'mode': 'bytes', 'offset': null},
      {...base, 'mode': 'bytes', 'maxDimension': 64},
      {...base, 'mode': 'preview', 'maxDimension': 63},
      {...base, 'mode': 'preview', 'maxDimension': 2049},
      {...base, 'mode': 'preview', 'limit': 1},
    ];
    for (final args in invalid) {
      await expectLater(
        read(args),
        throwsA(error('invalid_arguments')),
        reason: '$args',
      );
    }
  });

  test(
    'revocation during asynchronous reading prevents a payload response',
    () async {
      final (session, page, _) = await fixture();
      final pending = read({...selector(session, page), 'mode': 'bytes'});
      active = false;
      await expectLater(pending, throwsA(error('authorization_revoked')));
    },
  );

  test('ordinary MCP body update cannot downgrade a media page or invent a missing asset', () async {
    final (session, page, _) = await fixture();
    final writable = VaultMcpCallContext(
      isActive: () => true,
      canWrite: () => true,
    );
    final before = session.inkParents.single;
    Future<Object?> update(Object content) => service.call('update_document', {
      'noteId': session.note.id,
      'target': 'body',
      'expectedRevisionId': before,
      'requestId': newId(),
      'content': content,
    }, context: writable);
    await expectLater(
      update(const BlockPageDocument.empty().toJson()),
      throwsA(error('invalid_arguments')),
    );
    final forged = BlockPageMediaAsset.attachment(
      name: 'missing.txt',
      bytes: [1, 2],
    );
    final changed = page.copyWith(
      media: {page.blocks.single.id: forged.reference},
    );
    await expectLater(
      update(changed.toJson()),
      throwsA(error('invalid_arguments')),
    );
    expect(
      (await controller.repository.heads(session.note.inkEntityId))
          .single
          .revisionId,
      before,
    );
  });

  test('metadata chunks and preview share one successful validation for the same immutable asset', () async {
    final (session, page, _) = await fixture(image: true);
    var verifications = 0;
    service = VaultMcpService(
      controller,
      pageMediaVerifier: (media, bytes) async {
        verifications++;
        media.verifyBytes(bytes);
      },
    );
    await read(selector(session, page));
    await read({...selector(session, page), 'mode': 'bytes', 'limit': 3});
    await read({...selector(session, page), 'mode': 'preview'});
    expect(verifications, 1);
  });

  test('failed media validation is not cached as success or made permanently unretryable', () async {
    final (session, page, _) = await fixture(image: true);
    var verifications = 0;
    service = VaultMcpService(
      controller,
      pageMediaVerifier: (media, bytes) async {
        if (++verifications == 1)
          throw const FormatException('interrupted validation');
        media.verifyBytes(bytes);
      },
    );
    await expectLater(
      read(selector(session, page)),
      throwsA(error('media_integrity_error')),
    );
    await read(selector(session, page));
    await read(selector(session, page));
    expect(verifications, 2);
  });
}
