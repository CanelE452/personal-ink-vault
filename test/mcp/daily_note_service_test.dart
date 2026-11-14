import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/mcp/vault_mcp_bridge.dart';
import 'package:saber/data/mcp/vault_mcp_service.dart';
import 'package:saber/data/vault/workspace_markdown_templates.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/pages/workspace/workspace_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const date = '2024-02-29';
  final owner = Directory.systemTemp;
  final write = VaultMcpCallContext(isActive: () => true, canWrite: () => true);
  final readOnly = VaultMcpCallContext(
    isActive: () => true,
    canWrite: () => false,
  );
  late Directory temporary;
  late WorkspaceController controller;
  late NoteRepository repository;
  late VaultMcpService service;

  setUp(() async {
    temporary = await owner.createTemp('piv-daily-mcp-');
    addTearDown(() async {
      final resolved = await temporary.resolveSymbolicLinks();
      expect(p.dirname(resolved), await owner.resolveSymbolicLinks());
      expect(p.basename(resolved), startsWith('piv-daily-mcp-'));
      await Directory(resolved).delete(recursive: true);
    });
    repository = await NoteRepository.open(
      Directory(p.join(temporary.path, 'vault')),
      createFormatVersion: 2,
    );
    addTearDown(repository.close);
    controller = WorkspaceController(
      repository,
      directoryProvider: () async => temporary,
    );
    addTearDown(controller.dispose);
    service = VaultMcpService(controller);
  });

  Future<Map<String, dynamic>> call(
    String tool,
    Map<String, dynamic> args, {
    VaultMcpCallContext? context,
  }) async =>
      (await service.call(tool, args, context: context ?? write))
          as Map<String, dynamic>;

  Matcher error(String code) => throwsA(
    isA<VaultMcpException>().having((error) => error.code, 'code', code),
  );

  test('read daily note is a read-only canonical date lookup', () async {
    final sameTitle = await controller.store.create(
      date,
      documentKind: VaultDocumentKind.markdown,
    );
    final baseline = await repository.revisions();
    await expectLater(
      call('read_daily_note', {'date': date}, context: readOnly),
      error('not_found'),
    );
    expect(await repository.revisions(), baseline);
    final note = await controller.store.openDailyNote(DateTime(2024, 2, 29));
    final session = await controller.store.open(note);
    await session.saveMarkdown('# 정확한 날짜 본문');
    final changed = await repository.commit(
      entityId: note.id,
      kind: EntityKind.metadata,
      parentRevisionIds: [note.revision.revisionId],
      files: {
        'note.json': Uint8List.fromList(
          utf8.encode(jsonEncode({...note.json, 'title': '바꾼 제목'})),
        ),
      },
    );
    final read = await call('read_daily_note', {
      'date': date,
    }, context: readOnly);
    expect(read['noteId'], note.id);
    expect(read['noteId'], isNot(sameTitle.id));
    expect(read['date'], date);
    expect(read['title'], '바꾼 제목');
    expect(read['metadataRevisionId'], changed.revisionId);
    expect(read['markdown']['revisionId'], session.markdownParents.single);
    expect(read['markdown']['content'], '# 정확한 날짜 본문');
    expect(controller.activeSession, isNull);
  });

  test('ensure daily note seeds once and retries after restart without resetting text', () async {
    final folder = await controller.library.createFolder('날짜 양식');
    await controller.store.createMarkdown(
      '양식',
      Uint8List.fromList(utf8.encode('# {{title}}\n오늘 할 일')),
      folderId: folder.id,
    );
    final templates = WorkspaceMarkdownTemplateStore(repository);
    final settings = await templates.dailyNoteTemplateSettings();
    await templates.saveDailyNoteTemplateSettings(
      settings,
      choice: (await templates.templates(folder.id)).single,
    );

    final requestId = newId();
    final args = {'date': date, 'requestId': requestId};
    final ensured = await call('ensure_daily_note', args);
    final noteId = ensured['noteId'];
    expect(ensured, {'date': date, 'noteId': noteId});
    expect(controller.activeSession, isNull);
    final read = await call('read_daily_note', {
      'date': date,
    }, context: readOnly);
    expect(read['markdown']['content'], '# $date\n오늘 할 일');
    await call('update_document', {
      'noteId': noteId,
      'target': 'markdown',
      'content': '# 기존 편집 유지',
      'expectedRevisionId': read['markdown']['revisionId'],
      'requestId': newId(),
    });
    final revisions = await repository.revisions();
    service = VaultMcpService(controller);
    expect(await call('ensure_daily_note', args), ensured);
    await expectLater(
      call('ensure_daily_note', {...args, 'date': '2024-03-01'}),
      error('request_id_reused'),
    );

    final receipt = File(
      p.join(
        repository.root.path,
        '.workspace',
        'mcp',
        'requests',
        '$requestId.json',
      ),
    );
    final recorded = jsonObject(jsonDecode(await receipt.readAsString()));
    recorded.remove('result');
    recorded['state'] = 'started';
    await receipt.writeAsString(jsonEncode(recorded));
    service = VaultMcpService(controller);
    expect(await call('ensure_daily_note', args), ensured);
    expect(jsonDecode(await receipt.readAsString())['state'], 'completed');
    expect(
      await call('ensure_daily_note', {'date': date, 'requestId': newId()}),
      ensured,
    );
    expect(await repository.revisions(), revisions);
    expect(
      (await call('read_daily_note', {'date': date}))['markdown']['content'],
      '# 기존 편집 유지',
    );
  });

  test('daily note validates exact Gregorian dates and permissions before receipts', () async {
    final requestId = newId();
    for (final invalid in [
      '2023-02-29',
      '0000-01-01',
      '2024-04-31',
      '2024-2-29',
      '$date ',
      '${date}T00:00:00Z',
      '２０２４-02-29',
    ]) {
      await expectLater(
        call('read_daily_note', {'date': invalid}),
        error('invalid_arguments'),
      );
      await expectLater(
        call('ensure_daily_note', {'date': invalid, 'requestId': requestId}),
        error('invalid_arguments'),
      );
    }
    await expectLater(
      call('ensure_daily_note', {
        'date': date,
        'requestId': requestId,
        'title': '추가 필드',
      }),
      error('invalid_arguments'),
    );
    await expectLater(
      call('ensure_daily_note', {
        'date': date,
        'requestId': requestId,
      }, context: readOnly),
      error('read_only'),
    );
    expect(await repository.revisions(), isEmpty);
    expect(
      Directory(
        p.join(repository.root.path, '.workspace', 'mcp', 'requests'),
      ).existsSync(),
      isFalse,
    );
    expect(
      (await call('ensure_daily_note', {
        'date': date,
        'requestId': requestId,
      }))['date'],
      date,
    );
  });

  test(
    'daily lookup exposes a Markdown branch conflict and never picks a branch',
    () async {
      final note = await controller.store.openDailyNote(DateTime(2024, 2, 29));
      final genesis = (await repository.heads(note.markdownEntityId)).single;
      for (final body in ['첫 번째', '두 번째']) {
        await repository.commit(
          entityId: note.markdownEntityId,
          kind: EntityKind.markdown,
          ownerNoteId: note.id,
          parentRevisionIds: [genesis.revisionId],
          files: {'summary.md': Uint8List.fromList(utf8.encode(body))},
        );
      }
      final revisions = await repository.revisions();
      await expectLater(
        call('read_daily_note', {'date': date}),
        error('revision_conflict'),
      );
      expect(await repository.revisions(), revisions);
    },
  );

  test(
    'a daily note in a trashed folder remains closed until restoration',
    () async {
      final day = DateTime(2024, 2, 29);
      final note = await controller.store.openDailyNote(day);
      final folder = await controller.library.createFolder('연구');
      await controller.store.moveNote(note, folder.id);
      expect(
        (await call('read_daily_note', {'date': date}))['folderId'],
        folder.id,
      );
      await controller.library.setDeleted(folder, true);
      final revisions = await repository.revisions();
      final args = {'date': date, 'requestId': newId()};
      await expectLater(
        call('read_daily_note', {'date': date}),
        error('not_found'),
      );
      await expectLater(call('ensure_daily_note', args), error('not_found'));
      expect(await repository.revisions(), revisions);
      final trash = (await controller.library.listFolders(includeDeleted: true))
          .single;
      await controller.library.setDeleted(trash, false);
      expect(await call('ensure_daily_note', args), {
        'date': date,
        'noteId': note.id,
      });
    },
  );

  test(
    'a missing template blocks only new date creation and can be repaired',
    () async {
      final existing = await controller.store.openDailyNote(
        DateTime(2024, 2, 28),
      );
      final folder = await controller.library.createFolder('양식');
      final template = await controller.store.createMarkdown(
        '기본 양식',
        Uint8List.fromList(utf8.encode('# {{title}}')),
        folderId: folder.id,
      );
      final templates = WorkspaceMarkdownTemplateStore(repository);
      final settings = await templates.saveDailyNoteTemplateSettings(
        await templates.dailyNoteTemplateSettings(),
        choice: (await templates.templates(folder.id)).single,
      );
      await controller.store.setDeleted(template, true);
      final revisions = await repository.revisions();
      final args = {'date': date, 'requestId': newId()};
      await expectLater(
        call('ensure_daily_note', args),
        error('revision_conflict'),
      );
      await expectLater(
        call('read_daily_note', {'date': date}),
        error('not_found'),
      );
      expect(
        (await call('ensure_daily_note', {
          'date': '2024-02-28',
          'requestId': newId(),
        }))['noteId'],
        existing.id,
      );
      expect(await repository.revisions(), revisions);
      await templates.saveDailyNoteTemplateSettings(settings, choice: null);
      await call('ensure_daily_note', args);
      expect(
        (await call('read_daily_note', {'date': date}))['markdown']['content'],
        '',
      );
    },
  );

  test(
    'vault format one rejects daily requests before creating receipts',
    () async {
      final old = await NoteRepository.open(
        Directory(p.join(temporary.path, 'legacy')),
      );
      addTearDown(old.close);
      final legacy = WorkspaceController(
        old,
        directoryProvider: () async => temporary,
      );
      addTearDown(legacy.dispose);
      service = VaultMcpService(legacy);
      await expectLater(
        call('read_daily_note', {'date': date}),
        error('unsupported'),
      );
      await expectLater(
        call('ensure_daily_note', {'date': date, 'requestId': newId()}),
        error('unsupported'),
      );
      expect(await old.revisions(), isEmpty);
      expect(
        Directory(
          p.join(old.root.path, '.workspace', 'mcp', 'requests'),
        ).existsSync(),
        isFalse,
      );
    },
  );
}
