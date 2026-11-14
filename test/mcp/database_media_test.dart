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
import 'package:saber/data/vault/workspace_database.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/pages/workspace/workspace_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late WorkspaceController controller;
  late VaultMcpService service;
  late NoteSession session;
  late WorkspaceDatabase database;
  late BlockPageMediaAsset picture, attachment;
  late String imageRow, attachmentRow, blockId;
  var active = true;
  final readContext = VaultMcpCallContext(
    isActive: () => active,
    canWrite: () => false,
  );
  final writeContext = VaultMcpCallContext(
    isActive: () => active,
    canWrite: () => true,
  );
  Matcher error(String code) =>
      isA<VaultMcpException>().having((e) => e.code, 'code', code);

  setUp(() async {
    active = true;
    directory = await Directory.systemTemp.createTemp('mcp-db-media-');
    controller = WorkspaceController(
      await NoteRepository.open(directory, createFormatVersion: 2),
    );
    service = VaultMcpService(controller);
    picture = BlockPageMediaAsset.image(
      name: '도표.png',
      bytes: im.encodePng(im.Image(width: 3, height: 2)),
    );
    attachment = BlockPageMediaAsset.attachment(
      name: '자료.txt',
      bytes: utf8.encode('원본 😀 한글'),
    );
    blockId = newId();
    BlockPageDocument body(String type, BlockPageMediaAsset asset) =>
        const BlockPageDocument.empty().copyWith(
          blocks: [
            BlockPageBlock.fromJson({
              'id': blockId,
              'type': type,
              'text': '설명',
            }),
          ],
          media: {blockId: asset.reference},
        );
    final first = DatabaseRow.create(body: body('image', picture).toJson());
    final second = DatabaseRow.create(
      body: body('attachment', attachment).toJson(),
    );
    imageRow = first.id;
    attachmentRow = second.id;
    database = WorkspaceDatabase.empty().copyWith(rows: [first, second]);
    final note = await controller.store.create(
      '자료 DB',
      documentKind: VaultDocumentKind.database,
    );
    session = await controller.store.open(note);
    await session.saveInk({
      'database.json': Uint8List.fromList(
        utf8.encode(jsonEncode(database.toJson())),
      ),
      picture.reference.path: picture.bytes,
      attachment.reference.path: attachment.bytes,
      'opaque.bin': Uint8List.fromList([8, 0, 255]),
      'page.json': Uint8List.fromList(utf8.encode('opaque future file')),
    });
    await session.saveMarkdown('독립 정리 😀');
  });
  tearDown(() async {
    controller.dispose();
    await controller.repository.close();
    await directory.delete(recursive: true);
  });

  Map<String, dynamic> selector(String row) => {
    'noteId': session.note.id,
    'revisionId': session.inkParents.single,
    'rowId': row,
    'blockId': blockId,
  };
  Future<Map> read(Map<String, dynamic> args) async =>
      await service.call('read_page_media', args, context: readContext) as Map;

  test('DB media selector binds the row even when block IDs match', () async {
    final result = await read({...selector(imageRow), 'mode': 'preview'});
    expect(result['rowId'], imageRow);
    expect(result['media'], picture.reference.toJson());
    final image = result['image'] as Map;
    final decoded = im.decodePng(base64Decode(image['data'] as String))!;
    expect((decoded.width, decoded.height), (3, 2));
    final bytes = await read({...selector(attachmentRow), 'mode': 'bytes'});
    expect(bytes['rowId'], attachmentRow);
    expect(base64Decode(bytes['dataBase64'] as String), attachment.bytes);
    await expectLater(
      read({...selector(attachmentRow), 'mode': 'preview'}),
      throwsA(error('unsupported')),
    );
    await expectLater(read(selector(newId())), throwsA(error('not_found')));
  });

  test('DB media requires a row and standalone page rejects one', () async {
    final noRow = selector(imageRow)..remove('rowId');
    await expectLater(read(noRow), throwsA(error('invalid_arguments')));
    for (final value in [null, '', '../row']) {
      await expectLater(
        read({...selector(imageRow), 'rowId': value}),
        throwsA(error('invalid_arguments')),
      );
    }
    final note = await controller.store.create(
      'Page',
      documentKind: VaultDocumentKind.page,
    );
    final page = await controller.store.open(note);
    await page.saveInk({
      'page.json': Uint8List.fromList(
        utf8.encode(jsonEncode(database.rows.first.body)),
      ),
      picture.reference.path: picture.bytes,
    });
    await expectLater(
      read({
        ...selector(imageRow),
        'noteId': note.id,
        'revisionId': page.inkParents.single,
      }),
      throwsA(error('invalid_arguments')),
    );
  });

  test(
    'MCP DB caption edit preserves all files, old edition and retry identity',
    () async {
      final previous = session.inkParents.single;
      final row = database.rows.first;
      final page = BlockPageDocument.fromJson(row.body);
      final changed = database.updateRow(
        row.copyWith(
          body: page
              .copyWith(
                blocks: [page.blocks.single.copyWith(text: '수정한 캡션 😀')],
              )
              .toJson(),
        ),
      );
      final args = {
        'noteId': session.note.id,
        'target': 'body',
        'content': changed.toJson(),
        'expectedRevisionId': previous,
        'requestId': newId(),
      };
      final result = await service.call(
        'update_document',
        args,
        context: writeContext,
      ) as Map;
      final replay = await service.call(
        'update_document',
        args,
        context: writeContext,
      );
      expect(replay, result);
      final records = await controller.repository.revisions();
      final oldFiles = await controller.repository.readFiles(
        records.singleWhere((r) => r.revisionId == previous),
      );
      final newFiles = await controller.repository.readFiles(
        records.singleWhere((r) => r.revisionId == result['revisionId']),
      );
      expect(newFiles.keys.toSet(), oldFiles.keys.toSet());
      for (final path in oldFiles.keys.where(
        (path) => path != 'database.json',
      )) {
        expect(newFiles[path], oldFiles[path], reason: path);
      }
      expect(
        WorkspaceDatabase.fromJson(
          jsonObject(jsonDecode(utf8.decode(newFiles['database.json']!))),
        ).toJson(),
        changed.toJson(),
      );
      expect(
        WorkspaceDatabase.fromJson(
          jsonObject(jsonDecode(utf8.decode(oldFiles['database.json']!))),
        ).toJson(),
        database.toJson(),
      );
      expect(
        (await controller.repository.heads(session.note.markdownEntityId))
            .single
            .revisionId,
        session.markdownParents.single,
      );
      expect(
        records.where((r) => r.entityId == session.note.inkEntityId),
        hasLength(2),
      );
    },
  );

  test(
    'MCP DB cannot downgrade a media row or refer to missing bytes',
    () async {
      final previous = session.inkParents.single;
      Future<Object?> update(WorkspaceDatabase value) =>
          service.call('update_document', {
            'noteId': session.note.id,
            'target': 'body',
            'content': value.toJson(),
            'expectedRevisionId': previous,
            'requestId': newId(),
          }, context: writeContext);
      await expectLater(
        update(
          database.updateRow(
            database.rows.first.copyWith(
              body: const BlockPageDocument.empty().toJson(),
            ),
          ),
        ),
        throwsA(error('invalid_arguments')),
      );
      final forged = BlockPageMediaAsset.attachment(
        name: 'missing.bin',
        bytes: [1, 9, 8],
      );
      final body = BlockPageDocument.fromJson(database.rows.last.body);
      await expectLater(
        update(
          database.updateRow(
            database.rows.last.copyWith(
              body: body.copyWith(media: {blockId: forged.reference}).toJson(),
            ),
          ),
        ),
        throwsA(error('invalid_arguments')),
      );
      expect(
        (await controller.repository.heads(session.note.inkEntityId))
            .single
            .revisionId,
        previous,
      );
    },
  );

  test(
    'DB media still checks revision ownership and active authorization',
    () async {
      final note = await controller.store.create(
        'Other',
        documentKind: VaultDocumentKind.database,
      );
      final other = await controller.store.open(note);
      await other.saveInk({
        'database.json': Uint8List.fromList(
          utf8.encode(jsonEncode(WorkspaceDatabase.empty().toJson())),
        ),
      });
      await expectLater(
        read({...selector(imageRow), 'revisionId': other.inkParents.single}),
        throwsA(error('revision_not_owned')),
      );
      final pending = read({...selector(imageRow), 'mode': 'bytes'});
      active = false;
      await expectLater(pending, throwsA(error('authorization_revoked')));
    },
  );
}
