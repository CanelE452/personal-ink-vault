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
  late Directory root;
  late WorkspaceController controller;
  late VaultMcpService service;
  var writable = true;
  final context = VaultMcpCallContext(
    isActive: () => true,
    canWrite: () => writable,
  );
  setUp(() async {
    root = await Directory.systemTemp.createTemp('mcp-knowledge-');
    final native = InkVaultNative.open(
      libraryPath:
          Platform.environment['INK_VAULT_NATIVE_LIBRARY'] ??
          p.absolute('build', 'native', 'windows', 'ink_vault_native.dll'),
    );
    controller = WorkspaceController(
      await NoteRepository.open(root, createFormatVersion: 2),
      native: native,
    );
    service = VaultMcpService(controller);
    writable = true;
  });
  tearDown(() async {
    await controller.flush();
    controller.dispose();
    await controller.repository.close();
    await root.delete(recursive: true);
  });

  Future<(VaultNote, VaultNote)> seed() async {
    final target = await controller.store.create(
      'Old',
      documentKind: VaultDocumentKind.markdown,
    );
    final source = await controller.store.create(
      'Source',
      documentKind: VaultDocumentKind.markdown,
    );
    await (await controller.store.open(source))
        .saveMarkdown('[[Old#Late|read]] [read](Old.md#Late)');
    await controller.refresh();
    return (target, source);
  }

  Map<String, dynamic> request(VaultNote target) => {
    'noteId': target.id,
    'action': 'rename',
    'title': 'New',
    'expectedRevisionId': target.revision.revisionId,
    'requestId': newId(),
  };

  test('MCP rename normalizes real inbound references once and preserves their target after title reuse', () async {
    final (target, source) = await seed();
    final args = request(target);
    await service.call('document_action', args, context: context);
    final revisions = (await controller.repository.revisions()).length;
    await service.call('document_action', args, context: context);
    expect((await controller.repository.revisions()).length, revisions);
    final text = await (await controller.store.open(source)).readMarkdown();
    expect(text, contains('[[${target.id}#Late|read]]'));
    expect(text, contains('inkvault://note/${target.id}?view=markdown#Late'));
    await controller.store.create(
      'Old',
      documentKind: VaultDocumentKind.markdown,
    );
    final index = await KnowledgeIndex.build(
      controller.repository,
      controller.native!,
    );
    expect(
      index.documents[source.id]!.links.map((link) => link.targetId).toSet(),
      {target.id},
    );
    await expectLater(
      service.call('document_action', {
        ...args,
        'requestId': newId(),
      }, context: context),
      throwsA(
        isA<VaultMcpException>().having(
          (error) => error.code,
          'code',
          'revision_conflict',
        ),
      ),
    );
  });

  test('MCP permission revocation between inbound publication and title publication preserves the old title', () async {
    final (target, source) = await seed();
    final before = (await controller.repository.revisions())
        .map((revision) => revision.revisionId)
        .toSet();
    final subscription = controller.repository.changes.listen((_) {
      writable = false;
    });
    try {
      await expectLater(
        service.call('document_action', request(target), context: context),
        throwsA(
          isA<VaultMcpException>().having(
            (error) => error.code,
            'code',
            'read_only',
          ),
        ),
      );
    } finally {
      await subscription.cancel();
    }
    final current = (await controller.store.list()).singleWhere(
      (note) => note.id == target.id,
    );
    expect(current.title, 'Old');
    final published = (await controller.repository.revisions())
        .where((revision) => !before.contains(revision.revisionId))
        .toList();
    expect(published, hasLength(1));
    expect(published.single.entityId, source.markdownEntityId);
    writable = true;
    await service.call('document_action', request(target), context: context);
    expect(
      (await controller.store.list())
          .singleWhere((note) => note.id == target.id)
          .title,
      'New',
    );
    expect(
      await (await controller.store.open(source)).readMarkdown(),
      contains(target.id),
    );
  });
}
