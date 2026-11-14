import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/vault/block_page_document.dart';
import 'package:saber/data/vault/block_page_snapshot.dart';
import 'package:saber/data/vault/workspace_database.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/pages/workspace/portable_export_capture.dart';
import 'package:saber/pages/workspace/workspace_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late _HoldingController controller;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('portable-capture-');
    controller = _HoldingController(
      await NoteRepository.open(
        Directory('${directory.path}/vault'),
        createFormatVersion: 2,
      ),
      directoryProvider: () async => Directory('${directory.path}/support'),
    );
    await controller.refresh();
  });
  tearDown(() async {
    if (controller.release case final pending? when !pending.isCompleted)
      pending.complete();
    controller.release = null;
    controller.dispose();
    await controller.repository.close();
    expect(
      directory.absolute.path,
      startsWith(
        '${Directory.systemTemp.absolute.path}${Platform.pathSeparator}',
      ),
    );
    await directory.delete(recursive: true);
  });

  Future<NoteSession> page(String text) async {
    await controller.createNote('고정 판본', documentKind: VaultDocumentKind.page);
    final session = controller.activeSession!;
    await controller.saveBlockPage(
      const BlockPageDocument.empty().copyWith(
        blocks: [BlockPageBlock.create(text: text)],
      ),
      session: session,
    );
    await controller.flush();
    return session;
  }

  test(
    'captures exact selected historical page, not newest body head',
    () async {
      final session = await page('선택한 첫 판본');
      final selected = session.inkParents.single;
      await controller.saveBlockPage(
        const BlockPageDocument.empty().copyWith(
          blocks: [BlockPageBlock.create(text: '최신 두 번째 판본')],
        ),
        session: session,
      );
      await controller.flush();
      await controller.refresh();
      expect(session.inkParents.single, isNot(selected));
      final newestHead = (await controller.repository.heads(
        session.note.inkEntityId,
      )).single.revisionId;
      session.inkParents = [selected];
      final capture = await capturePortableExport(controller, session);
      expect(capture.source.bodyRevisionId, selected);
      expect(capture.source.page!.document.blocks.single.text, '선택한 첫 판본');
      expect(capture.source.metadataRevisionIds, [
        session.note.revision.revisionId,
      ]);
      capture.ensureCurrent();
      expect(
        (await controller.repository.heads(session.note.inkEntityId))
            .single
            .revisionId,
        newestHead,
      );
    },
  );

  test(
    'capture source bytes remain immutable after caller changes returned files',
    () async {
      final session = await page('변경되지 않는 본문');
      final before = (await controller.repository.revisions())
          .map((r) => r.revisionId)
          .toSet();
      final capture = await capturePortableExport(controller, session);
      capture.source.page!.files['page.json']![0] = 0;
      final json = jsonDecode(
        utf8.decode(capture.source.page!.files['page.json']!),
      ) as Map;
      expect((json['blocks'] as List).single['text'], '변경되지 않는 본문');
      expect(
        (await controller.repository.revisions())
            .map((r) => r.revisionId)
            .toSet(),
        before,
      );
    },
  );

  test(
    'unsaved edits are rejected rather than silently exporting stale content',
    () async {
      final session = await page('저장된 본문');
      controller.inkDirty = true;
      await expectLater(
        capturePortableExport(controller, session),
        throwsStateError,
      );
      controller.inkDirty = false;
    },
  );

  test(
    'closed session is rejected at capture and at final destination guard',
    () async {
      final session = await page('열린 본문');
      final capture = await capturePortableExport(controller, session);
      controller.activeSession = null;
      expect(capture.ensureCurrent, throwsStateError);
      await expectLater(
        capturePortableExport(controller, session),
        throwsStateError,
      );
    },
  );

  test(
    'new editor generation invalidates an already captured document',
    () async {
      final session = await page('세대 확인');
      final capture = await capturePortableExport(controller, session);
      controller.editorGeneration++;
      expect(capture.ensureCurrent, throwsStateError);
    },
  );

  test(
    'selected revision change during snapshot read rejects capture',
    () async {
      final session = await page('중간 변경');
      controller.started = Completer<void>();
      controller.release = Completer<void>();
      final result = capturePortableExport(controller, session);
      await Future.any<void>([
        controller.started!.future,
        result.then<void>((_) {}),
      ]);
      session.inkParents = [newId()];
      controller.release!.complete();
      controller.release = null;
      await expectLater(result, throwsStateError);
    },
  );

  test('title changes invalidate captured identity before export', () async {
    final session = await page('이름과 판본');
    final capture = await capturePortableExport(controller, session);
    final note = session.note;
    session.note = VaultNote(
      note.id,
      '바뀐 이름',
      note.inkEntityId,
      note.markdownEntityId,
      note.revision,
      documentKind: note.documentKind,
    );
    expect(capture.ensureCurrent, throwsStateError);
  });

  test('database captures computed values and preserves archived rows with explicit errors', () async {
    await controller.createNote(
      '계산 내보내기',
      documentKind: VaultDocumentKind.database,
    );
    final session = controller.activeSession!;
    final base = await controller.loadDatabase(session: session);
    final amount = DatabaseProperty.create(name: '수량', type: 'number');
    final formula = DatabaseProperty.create(
      name: '두 배',
      type: 'formula',
      config: {'expression': 'prop("${amount.id}") * 2'},
    );
    final row = DatabaseRow.create(values: {amount.id: 7});
    final archived = DatabaseRow.create(values: {amount.id: 20})
        .copyWith(archived: true);
    await controller.saveDatabase(
      base.copyWith(properties: [amount, formula], rows: [row, archived]),
      session: session,
    );
    await controller.flush();
    final capture = await capturePortableExport(controller, session);
    expect(capture.source.values[row.id]![formula.id]!.value, 14);
    expect(capture.source.values[archived.id]![formula.id]!.error, isNotNull);
    expect(capture.source.database!.database.rows.last.archived, isTrue);
    expect(capture.source.evaluatedAtUtc!.isUtc, isTrue);
  });

  test(
    'rollup uses saved related database and records its actual revision',
    () async {
      await controller.createNote(
        '연결 대상',
        documentKind: VaultDocumentKind.database,
      );
      final targetSession = controller.activeSession!;
      final targetBase = await controller.loadDatabase(session: targetSession);
      final amount = DatabaseProperty.create(name: '값', type: 'number');
      final targetRow = DatabaseRow.create(values: {amount.id: 23});
      final target = targetBase.copyWith(
        properties: [amount],
        rows: [targetRow],
      );
      await controller.saveDatabase(target, session: targetSession);
      await controller.flush();
      final targetRevision = targetSession.inkParents.single;
      await controller.createNote(
        '연결 원본',
        documentKind: VaultDocumentKind.database,
      );
      final session = controller.activeSession!;
      final base = await controller.loadDatabase(session: session);
      final relation = DatabaseProperty.create(
        name: '대상',
        type: 'relation',
        config: {'databaseId': target.id},
      );
      final rollup = DatabaseProperty.create(
        name: '합계',
        type: 'rollup',
        config: {
          'relationPropertyId': relation.id,
          'targetPropertyId': amount.id,
          'calculation': 'sum',
        },
      );
      final row = DatabaseRow.create(
        values: {
          relation.id: [
            {'databaseId': target.id, 'rowId': targetRow.id},
          ],
        },
      );
      await controller.saveDatabase(
        base.copyWith(properties: [relation, rollup], rows: [row]),
        session: session,
      );
      await controller.flush();
      final capture = await capturePortableExport(controller, session);
      expect(capture.source.values[row.id]![rollup.id]!.value, 23);
      expect(capture.source.relatedRevisionIds[target.id], targetRevision);
    },
  );
}

final class _HoldingController extends WorkspaceController {
  new(super.repository, {required super.directoryProvider});
  Completer<void>? started, release;
  @override
  Future<BlockPageMediaSnapshot> loadBlockPageSnapshot({
    required NoteSession session,
  }) async {
    final snapshot = await super.loadBlockPageSnapshot(session: session);
    final waiting = release;
    if (waiting != null) {
      started!.complete();
      await waiting.future;
    }
    return snapshot;
  }
}
