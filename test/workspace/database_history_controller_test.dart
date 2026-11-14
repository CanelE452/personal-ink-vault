import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/mcp/vault_mcp_bridge.dart';
import 'package:saber/data/mcp/vault_mcp_service.dart';
import 'package:saber/data/native/ink_vault_native.dart';
import 'package:saber/data/vault/database_actions.dart';
import 'package:saber/data/vault/workspace_database.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/pages/workspace/workspace_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();

  late Directory directory;
  late NoteRepository repository;
  late WorkspaceController controller;
  late NoteSession session;
  late WorkspaceDatabase initial;
  final nativePath = Platform.environment['INK_VAULT_NATIVE_LIBRARY'];
  final nativeAvailable = nativePath != null && File(nativePath).existsSync();

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'piv-db-history-controller-',
    );
    repository = await NoteRepository.open(directory, createFormatVersion: 2);
    controller = WorkspaceController(
      repository,
      native: nativeAvailable
          ? InkVaultNative.open(libraryPath: nativePath)
          : null,
      directoryProvider: () async => directory,
    );
    await controller.createNote(
      'Research',
      documentKind: VaultDocumentKind.database,
    );
    session = controller.activeSession!;
    initial = await controller.loadDatabase(session: session);
  });

  tearDown(() async {
    controller.dispose();
    await repository.close();
    await directory.delete(recursive: true);
  });

  test(
    'compares a saved database and restores as a new current body',
    () async {
      final first = (await repository.heads(session.note.inkEntityId)).single;
      final row = DatabaseRow.create(
        values: {initial.properties.single.id: 'new row'},
      );
      await controller.saveDatabase(
        initial.copyWith(rows: [row]),
        session: session,
      );
      controller.editMarkdown('Current summary', session: session);
      await controller.saveMarkdown();
      final summary = (await repository.heads(session.note.markdownEntityId))
          .single;
      final history = await controller.databaseHistory(session: session);
      expect(
        history.revisions.map((item) => item.revisionId),
        contains(first.revisionId),
      );
      final difference = await history.compare(first);
      expect(difference.rows.added, 1);
      final generation = controller.editorGeneration;

      await controller.restoreDatabaseRevision(
        history,
        first,
        session: session,
      );

      final latest = (await repository.heads(session.note.inkEntityId)).single;
      expect(latest.revisionId, isNot(first.revisionId));
      expect(latest.parentRevisionIds, [history.currentRevision.revisionId]);
      expect(controller.editorGeneration, greaterThan(generation));
      expect((await controller.loadDatabase(session: session)).rows, isEmpty);
      expect(
        (await repository.heads(session.note.markdownEntityId))
            .single
            .revisionId,
        summary.revisionId,
      );
      expect(controller.markdown, 'Current summary');

      final service = VaultMcpService(controller);
      final readOnly = VaultMcpCallContext(
        isActive: () => true,
        canWrite: () => false,
      );
      final listed = jsonObject(
        await service.call('list_revisions', {
          'noteId': session.note.id,
          'target': 'body',
        }, context: readOnly),
      );
      expect(listed['total'], 3);
      final historical = jsonObject(
        await service.call('read_revision', {
          'noteId': session.note.id,
          'revisionId': history.currentRevision.revisionId,
        }, context: readOnly),
      );
      final record = jsonObject(historical['revision']);
      final previous = WorkspaceDatabase.fromJson(
        jsonObject(record['content']),
      );
      expect(previous.rows.single.id, row.id);
    },
  );

  test('rejects an open draft and a newer body after comparison', () async {
    final first = (await repository.heads(session.note.inkEntityId)).single;
    final row = DatabaseRow.create(
      values: {initial.properties.single.id: 'current row'},
    );
    await controller.saveDatabase(
      initial.copyWith(rows: [row]),
      session: session,
    );
    final history = await controller.databaseHistory(session: session);
    controller.editMarkdown('Unsaved summary', session: session);
    await expectLater(
      controller.restoreDatabaseRevision(history, first, session: session),
      throwsStateError,
    );
    await controller.saveMarkdown();
    final concurrent = DatabaseRow.create(
      values: {initial.properties.single.id: 'newer row'},
    );
    await controller.saveDatabase(
      initial.copyWith(rows: [row, concurrent]),
      session: session,
    );
    final newer = (await repository.heads(session.note.inkEntityId)).single;
    await expectLater(
      controller.restoreDatabaseRevision(history, first, session: session),
      throwsStateError,
    );
    expect(
      (await repository.heads(session.note.inkEntityId)).single.revisionId,
      newer.revisionId,
    );
  });

  test(
    'restoring earlier rows retains an actual Rust schedule receipt',
    () async {
      final first = (await repository.heads(session.note.inkEntityId)).single;
      final runtime = DatabaseActionRuntime(
        deviceId: repository.deviceId,
        invoke: controller.native!.invoke,
      );
      final scheduled = runtime.putRule(initial, {
        'id': newId(),
        'name': 'Daily test',
        'enabled': true,
        'ownerDeviceId': repository.deviceId,
        'trigger': {
          'type': 'schedule',
          'frequency': 'daily',
          'interval': 1,
          'timeZone': 'UTC',
          'startDate': '2026-10-30',
          'time': '09:00',
          'ambiguous': 'earlier',
          'gap': 'skip',
        },
        'actions': [
          {
            'id': newId(),
            'type': 'addRow',
            'values': {initial.properties.single.id: 'Generated'},
          },
        ],
      });
      await controller.saveDatabase(scheduled, session: session);
      final runner = controller.createAutomationCoordinator(
        clock: () => DateTime.utc(2026, 10, 30, 12),
      );
      final initialPass = await runner.runOnce();
      expect(initialPass.committedNotes, 1, reason: '${initialPass.toJson()}');
      await controller.refresh();
      final history = await controller.databaseHistory(session: session);
      final before = await controller.loadDatabase(session: session);
      expect(runtime.receipts(before), hasLength(1));
      expect(before.rows, hasLength(1));

      await controller.restoreDatabaseRevision(
        history,
        first,
        session: session,
      );

      final restored = await controller.loadDatabase(session: session);
      expect(restored.rows, isEmpty);
      expect(runtime.rules(restored), runtime.rules(before));
      expect(runtime.receipts(restored), runtime.receipts(before));
      final secondPass = await runner.runOnce();
      expect(secondPass.committedNotes, 0, reason: '${secondPass.toJson()}');
      expect((await controller.loadDatabase(session: session)).rows, isEmpty);
    },
    skip: !nativeAvailable,
  );
}
