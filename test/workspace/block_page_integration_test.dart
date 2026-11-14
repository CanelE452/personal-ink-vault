import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/vault/block_page_document.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/pages/workspace/workspace_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('block page persists its typed body independently of personal Markdown', () async {
    final root = await Directory.systemTemp.createTemp('block-page-workspace-');
    final c = WorkspaceController(await NoteRepository.open(root, createFormatVersion: 2));
    try {
      final note = await c.createNote('Lecture', documentKind: VaultDocumentKind.page);
      final session = c.activeSession!;
      c.editMarkdown('My separate summary');
      await c.flush();
      final body = BlockPageDocument.template('lecture');
      await c.saveBlockPage(body, session: session);
      await c.closeNote(session: session);
      await c.openNote((await c.store.list()).singleWhere((n) => n.id == note.id));
      expect((await c.loadBlockPage(session: c.activeSession!)).toJson(), body.toJson());
      expect(c.markdown, 'My separate summary');
      await expectLater(c.saveBlockPage(body, session: session), throwsStateError);
      await c.flush();
    } finally {
      c.dispose();
      await c.repository.close();
      await root.delete(recursive: true);
    }
  });
}
