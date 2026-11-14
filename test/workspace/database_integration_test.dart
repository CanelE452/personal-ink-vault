import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/vault/workspace_database.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/pages/workspace/workspace_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('database body and row pages survive save close reopen while Markdown stays independent', () async {
    final root = await Directory.systemTemp.createTemp('database-workspace-');
    final c = WorkspaceController(
      await NoteRepository.open(root, createFormatVersion: 2),
    );
    try {
      final note = await c.createNote(
        'Tasks',
        documentKind: VaultDocumentKind.database,
      );
      final session = c.activeSession!;
      final initial = await c.loadDatabase(session: session);
      expect(initial.id, note.id);
      await expectLater(
        c.saveDatabase(WorkspaceDatabase.empty(), session: session),
        throwsFormatException,
      );
      expect((await c.loadDatabase(session: session)).id, initial.id);
      final row = DatabaseRow.create(
        values: {initial.properties.single.id: 'Read paper'},
      );
      final sourceView = initial.views.single;
      final dashboard = DatabaseView.create(
        type: databaseDashboardViewType,
        name: 'Overview',
        config: {
          'dashboardRows': [
            {
              'id': newId(),
              'widgets': [
                {
                  'id': newId(),
                  'databaseId': initial.id,
                  'viewId': sourceView.id,
                },
              ],
            },
          ],
        },
      );
      final db = initial.addRow(row).addView(dashboard);
      c.editMarkdown('Separate notes');
      await c.flush();
      await c.saveDatabase(db, session: session);
      await c.closeNote(session: session);
      await c.openNote((await c.store.list()).single);
      final reopened = await c.loadDatabase(session: c.activeSession!);
      expect(reopened.rows.single.id, row.id);
      expect(reopened.views.first.toJson(), sourceView.toJson());
      expect(reopened.views.last.toJson(), dashboard.toJson());
      expect(c.markdown, 'Separate notes');
      await expectLater(c.saveDatabase(db, session: session), throwsStateError);
      await c.flush();
    } finally {
      c.dispose();
      await c.repository.close();
      await root.delete(recursive: true);
    }
  });
}
