import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/pages/workspace/workspace_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('Office source branches are visible and resolution preserves both originals', () async {
    final root = await Directory.systemTemp.createTemp('workspace-source-conflict-');
    final repo = await NoteRepository.open(root, createFormatVersion: 2);
    final c = WorkspaceController(repo);
    var note = await c.store.create('Slides', documentKind: VaultDocumentKind.office);
    note = await c.store.attachSource(note, fileName: 'slides.pptx', bytes: Uint8List.fromList([1]));
    await c.openNote(note);
    final base = (await repo.heads(note.sourceEntityId!)).single;
    final versions = <RevisionRecord>[];
    for (final contents in [[2], [3]]) {
      versions.add(await repo.commit(entityId: note.sourceEntityId!, kind: EntityKind.attachment,
        ownerNoteId: note.id, files: {'slides.pptx': Uint8List.fromList(contents)},
        parentRevisionIds: [base.revisionId]));
    }
    await c.refresh();
    final conflictVisible = c.remoteConflict;
    await c.chooseRevision(versions.first);
    expect(c.remoteConflict, isFalse);
    expect(await repo.heads(note.sourceEntityId!), hasLength(1));
    for (final version in versions) {
      expect(await repo.readFiles(version), contains('slides.pptx'));
    }
    c.dispose();
    await repo.close();
    await root.delete(recursive: true);
    expect(conflictVisible, isTrue);
  });
}
