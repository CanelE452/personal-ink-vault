import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as im;
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/vault/block_page_document.dart';
import 'package:saber/data/vault/block_page_media.dart';
import 'package:saber/data/vault/block_page_snapshot.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/pages/workspace/workspace_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('new repository navigation may start valid page media reads during its active-session notification', () async {
    final directory = await Directory.systemTemp.createTemp(
      'block-media-repository-switch-',
    );
    final previous = await NoteRepository.open(
      Directory('${directory.path}/previous'),
      createFormatVersion: 2,
    );
    final next = await NoteRepository.open(
      Directory('${directory.path}/next'),
      createFormatVersion: 2,
    );
    final incoming = WorkspaceController(next);
    final controller = WorkspaceController(
      previous,
      directoryProvider: () async => Directory('${directory.path}/support'),
    );
    final asset = BlockPageMediaAsset.image(
      name: 'New repository.png',
      bytes: im.encodePng(im.Image(width: 2, height: 2)),
    );
    try {
      final note = await incoming.createNote(
        'Incoming page',
        documentKind: VaultDocumentKind.page,
      );
      final block = BlockPageBlock.create(
        type: 'image',
        text: 'Read after switch',
      );
      final page = const BlockPageDocument.empty().copyWith(
        blocks: [block],
        media: {block.id: asset.reference},
      );
      await incoming.saveBlockPage(
        page,
        session: incoming.activeSession!,
        mediaFiles: {asset.reference.path: asset.bytes},
      );
      await incoming.flush();
      expect(incoming.navigation.current.noteId, note.id);
      final savedNavigation = jsonDecode(
        await File('${next.root.path}/.workspace/navigation.json')
            .readAsString(),
      ) as Map;
      expect((savedNavigation['current'] as Map)['noteId'], note.id);

      final expectedRevisionId = (await next.heads(note.inkEntityId))
          .single
          .revisionId;
      Future<void>? switchingSave;
      Future<BlockPageMediaSnapshot>? firstSnapshot;
      Future<List<int>>? firstMedia;
      controller.addListener(() {
        final session = controller.activeSession;
        if (firstSnapshot != null ||
            !identical(controller.repository, next) ||
            session == null ||
            !identical(session.repository, next) ||
            session.note.id != note.id ||
            session.note.documentKind != VaultDocumentKind.page) {
          return;
        }
        switchingSave = controller.saveBlockPage(page, session: session);
        unawaited(
          switchingSave!.then<void>(
            (_) {},
            onError: (Object _, StackTrace _) {},
          ),
        );
        firstSnapshot = controller.loadBlockPageSnapshot(session: session);
        firstMedia = controller.readBlockPageMedia(
          asset.reference,
          session: session,
        );
        unawaited(
          firstSnapshot!.then<void>(
            (_) {},
            onError: (Object _, StackTrace _) {},
          ),
        );
        unawaited(
          firstMedia!.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
        );
      });

      await controller.replaceRepository(next);
      expect(controller.activeSession, isNotNull, reason: controller.error);
      expect(
        controller.activeSession!.note.id,
        note.id,
        reason: controller.error,
      );
      expect(firstSnapshot, isNotNull, reason: controller.error);
      expect(firstMedia, isNotNull);
      expect(switchingSave, isNotNull);
      await expectLater(switchingSave!, throwsStateError);
      expect(
        (await next.heads(note.inkEntityId)).single.revisionId,
        expectedRevisionId,
      );
      expect(controller.activeSession!.note.id, note.id);
      final snapshot = await firstSnapshot!;
      expect(snapshot.document.toJson(), page.toJson());
      expect(snapshot.mediaBytes(block.id), asset.bytes);
      expect(await firstMedia!, asset.bytes);
      await controller.flush();
    } finally {
      incoming.dispose();
      controller.dispose();
      await previous.close();
      await next.close();
      await directory.delete(recursive: true);
    }
  });
}
