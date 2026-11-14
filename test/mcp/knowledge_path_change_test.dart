import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/mcp/vault_mcp_bridge.dart';
import 'package:saber/data/mcp/vault_mcp_service.dart';
import 'package:saber/data/native/ink_vault_native.dart';
import 'package:saber/data/vault/knowledge_index.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/pages/workspace/workspace_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late WorkspaceController controller;
  late VaultMcpService service;
  var writable = true;
  final context = VaultMcpCallContext(
    isActive: () => true,
    canWrite: () => writable,
  );
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('mcp-path-change-');
    controller = WorkspaceController(
      await NoteRepository.open(temp, createFormatVersion: 2),
      native: InkVaultNative.open(libraryPath: _nativePath),
    );
    service = VaultMcpService(controller);
    writable = true;
  });
  tearDown(() async {
    await controller.flush();
    controller.dispose();
    await controller.repository.close();
    final actual = await temp.resolveSymbolicLinks();
    final parent = await Directory.systemTemp.resolveSymbolicLinks();
    expect(
      actual,
      startsWith('$parent${Platform.pathSeparator}mcp-path-change-'),
    );
    await Directory(actual).delete(recursive: true);
  });

  Future<(VaultNote, VaultNote, String)> seed() async {
    final course = await controller.library.createFolder('Course');
    final other = await controller.library.createFolder('Other');
    final target = await controller.store.create(
      'B',
      folderId: course.id,
      documentKind: VaultDocumentKind.markdown,
    );
    final source = await controller.store.create(
      'Outside',
      documentKind: VaultDocumentKind.markdown,
    );
    await (await controller.store.open(source))
        .saveMarkdown('[read](Course/B.md#Heading)');
    await controller.refresh();
    return (target, source, other.id);
  }

  Map<String, dynamic> request(
    VaultNote note,
    String action, {
    String? folderId,
  }) => {
    'noteId': note.id,
    'action': action,
    if (action == 'move') 'folderId': folderId,
    'expectedRevisionId': note.revision.revisionId,
    'requestId': newId(),
  };

  group(
    'installed native path actions',
    () {
      test('MCP move preserves old targets and an identical request publishes once', () async {
        final (target, source, other) = await seed();
        final args = request(target, 'move', folderId: other);

        await service.call('document_action', args, context: context);
        final before = (await controller.repository.revisions())
            .map((r) => r.revisionId)
            .toSet();
        await service.call('document_action', args, context: context);

        expect(
          (await controller.repository.revisions())
              .map((r) => r.revisionId)
              .toSet(),
          before,
        );
        expect(
          await (await controller.store.open(source)).readMarkdown(),
          '[read](inkvault://note/${target.id}?view=markdown#Heading)',
        );
        final replacement = await controller.store.create(
          'B',
          folderId: target.folderId,
        );
        final index = await KnowledgeIndex.build(
          controller.repository,
          controller.native!,
        );
        expect(index.backlinks(target.id).map((n) => n.id), [source.id]);
        expect(index.backlinks(replacement.id), isEmpty);
      });

      for (final action in ['move', 'trash']) {
        test(
          'MCP $action rechecks write permission after link publication before metadata',
          () async {
            final (target, source, other) = await seed();
            final before = (await controller.repository.revisions())
                .map((r) => r.revisionId)
                .toSet();
            final args = request(target, action, folderId: other);
            final subscription = controller.repository.changes.listen(
              (_) => writable = false,
            );
            try {
              await expectLater(
                service.call('document_action', args, context: context),
                throwsA(
                  isA<VaultMcpException>().having(
                    (e) => e.code,
                    'code',
                    'read_only',
                  ),
                ),
              );
            } finally {
              await subscription.cancel();
            }

            final current = (await controller.store.list()).singleWhere(
              (n) => n.id == target.id,
            );
            expect(current.folderId, target.folderId);
            expect(current.trashed, isFalse);
            final published = (await controller.repository.revisions())
                .where((r) => !before.contains(r.revisionId))
                .toList();
            expect(published, hasLength(1));
            expect(published.single.entityId, source.markdownEntityId);
            expect(
              await (await controller.store.open(source)).readMarkdown(),
              '[read](inkvault://note/${target.id}?view=markdown#Heading)',
            );
            writable = true;
            await service.call('document_action', args, context: context);
            final finished = (await controller.store.list(includeDeleted: true))
                .singleWhere((n) => n.id == target.id);
            expect(
              finished.folderId,
              action == 'move' ? other : target.folderId,
            );
            expect(finished.trashed, action == 'trash');
          },
        );
      }

      test(
        'MCP trash and restore preserve the original target through path reuse',
        () async {
          final (target, source, _) = await seed();
          final trash = request(target, 'trash');
          await service.call('document_action', trash, context: context);
          final deleted = (await controller.store.list(includeDeleted: true))
              .singleWhere((n) => n.id == target.id);
          final bases = deleted.revision.baseRefs;
          final replacement = await controller.store.create(
            'B',
            folderId: target.folderId,
          );
          final restore = request(deleted, 'restore');

          await service.call('document_action', restore, context: context);
          final beforeRetry = (await controller.repository.revisions())
              .map((r) => r.revisionId)
              .toSet();
          await service.call('document_action', restore, context: context);

          expect(
            (await controller.repository.revisions())
                .map((r) => r.revisionId)
                .toSet(),
            beforeRetry,
          );
          expect(
            (await controller.repository.heads(target.id)).single.baseRefs,
            bases,
          );
          final index = await KnowledgeIndex.build(
            controller.repository,
            controller.native!,
          );
          expect(index.backlinks(target.id).map((n) => n.id), [source.id]);
          expect(index.backlinks(replacement.id), isEmpty);
        },
      );
    },
    skip: File(_nativePath).existsSync() ? false : 'Set INK_VAULT_NATIVE_LIBRARY to the installed common-engine library.',
  );
}

final _nativePath =
    Platform.environment['INK_VAULT_NATIVE_LIBRARY'] ??
    p.absolute('build', 'native', 'windows', 'ink_vault_native.dll');
