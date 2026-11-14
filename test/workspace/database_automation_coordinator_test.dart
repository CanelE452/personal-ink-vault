import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/drive/drive_background.dart';
import 'package:saber/data/drive/drive_connection.dart';
import 'package:saber/data/native/ink_vault_native.dart';
import 'package:saber/data/vault/block_page_document.dart';
import 'package:saber/data/vault/block_page_media.dart';
import 'package:saber/data/vault/database_actions.dart';
import 'package:saber/data/vault/database_automation_coordinator.dart';
import 'package:saber/data/vault/database_media_snapshot.dart';
import 'package:saber/data/vault/workspace_database.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/pages/workspace/workspace_controller.dart';

import '../drive/background_test.dart' show NoUiAuth;

class FakeActionRuntime extends DatabaseActionRuntime {
  new(String device)
    : super(
        deviceId: device,
        invoke: (_) => throw StateError('Use typed fake methods'),
      );
  final queried = <Map<String, Object?>>[];
  final prepared = <Map<String, Object?>>[];
  final eventIds = <String, String>{};
  void Function(WorkspaceDatabase)? beforePrepare;
  DatabaseActionDue Function(
    WorkspaceDatabase,
    int,
    Map<String, dynamic>?,
    int?,
  )?
  query;
  @override
  DatabaseActionDue due(
    WorkspaceDatabase database, {
    required int capturedAtUtcMs,
    Map<String, dynamic>? cursor,
    int? sinceUtcMs,
  }) {
    queried.add({
      'id': database.id,
      'cutoff': capturedAtUtcMs,
      'cursor': cursor,
      'since': sinceUtcMs,
    });
    if (query != null)
      return query!(database, capturedAtUtcMs, cursor, sinceUtcMs);
    final ledger = database.toJson()['automationExecutions'] as List? ?? [];
    return DatabaseActionDue(
      events: ledger.isNotEmpty ? [] : [event(database, capturedAtUtcMs)],
      hasMore: false,
      cursor: null,
      capturedAtUtcMs: capturedAtUtcMs,
    );
  }

  Map<String, dynamic> event(WorkspaceDatabase database, int cutoff) => {
    'ruleId': rules(database).single['id'],
    'event': {
      'id': eventIds.putIfAbsent(database.id, newId),
      'type': 'schedule',
      'scheduledForUtcMs': cutoff - 1000,
    },
  };
  @override
  DatabaseActionPrepared prepare(
    WorkspaceDatabase database, {
    required Map<String, dynamic> event,
    String? ruleId,
    required String inputRevision,
    required int capturedAtUtcMs,
  }) {
    beforePrepare?.call(database);
    prepared.add({
      'id': database.id,
      'event': event,
      'revision': inputRevision,
      'at': capturedAtUtcMs,
    });
    final ledger = List<Map<String, dynamic>>.from(
      database.toJson()['automationExecutions'] as List? ?? [],
    );
    final receipt = <String, dynamic>{
      'id': newId(),
      'eventId': event['id'],
      'ruleId': ruleId,
      'inputRevision': inputRevision,
      'deviceId': deviceId,
      'capturedAtUtcMs': capturedAtUtcMs,
      'status': 'completed',
    };
    final next = database.addRow(
      DatabaseRow.create(values: {database.properties.first.id: '일정 실행'}),
    );
    return DatabaseActionPrepared(
      database: WorkspaceDatabase.fromJson({
        ...next.toJson(),
        'automationExecutions': [...ledger, receipt],
      }),
      receipts: [receipt],
      duplicate: false,
      changed: true,
      request: {},
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late NoteRepository repo;
  late WorkspaceController controller;
  late FakeActionRuntime runtime;
  final moment = DateTime.utc(2026, 10, 30, 12);
  final libraryPath =
      Platform.environment['INK_VAULT_NATIVE_LIBRARY'] ??
      File('build/native/windows/ink_vault_native.dll').absolute.path;
  final nativeAvailable = Platform.isWindows && File(libraryPath).existsSync();
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('database-automation-');
    repo = await NoteRepository.open(
      Directory('${temp.path}/vault'),
      createFormatVersion: 2,
    );
    controller = WorkspaceController(repo);
    runtime = FakeActionRuntime(repo.deviceId);
  });
  tearDown(() async {
    controller.dispose();
    await repo.close();
    await temp.delete(recursive: true);
  });
  Future<VaultNote> note(String title) async {
    final note = await controller.store.create(
      title,
      documentKind: VaultDocumentKind.database,
    );
    final empty = WorkspaceDatabase.empty(id: note.id);
    final db = WorkspaceDatabase.fromJson({
      ...empty.toJson(),
      'automationRules': [
        {
          'id': newId(),
          'version': 1,
          'name': '매일',
          'enabled': true,
          'ownerDeviceId': repo.deviceId,
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
              'values': {empty.properties.first.id: '일정 실행'},
            },
          ],
        },
      ],
    });
    await (await controller.store.open(note)).saveInk({
      'database.json': Uint8List.fromList(utf8.encode(jsonEncode(db.toJson()))),
    });
    return note;
  }

  Future<WorkspaceDatabase> saved(VaultNote note) async {
    final head = (await repo.heads(note.inkEntityId)).single;
    return WorkspaceDatabase.fromJson(
      jsonObject(
        jsonDecode(utf8.decode((await repo.readFiles(head))['database.json']!)),
      ),
    );
  }

  Future<
    ({
      VaultNote note,
      String templateId,
      String titleId,
      String numberId,
      BlockPageBlock heading,
      BlockPageBlock attachment,
      BlockPageMediaAsset asset,
    })
  >
  savedTemplate({required bool storeMedia}) async {
    final item = await note('반복 주간 기록');
    final base = await saved(item);
    final titleId = base.properties.first.id;
    final number = DatabaseProperty.create(name: '횟수', type: 'number');
    final attachment = BlockPageBlock.create(type: 'attachment', text: '자료');
    final heading = BlockPageBlock.create(
      type: 'toggle',
      text: '회고 항목',
    ).copyWith(children: [attachment]);
    final asset = BlockPageMediaAsset.attachment(
      name: 'agenda.txt',
      bytes: utf8.encode('읽을 자료'),
    );
    final templateId = newId();
    final source = DatabaseRow.create(
      values: {titleId: '팀 회고', number.id: 2},
      body: const BlockPageDocument.empty()
          .copyWith(blocks: [heading], media: {attachment.id: asset.reference})
          .toJson(),
    );
    final database = base
        .copyWith(properties: [...base.properties, number])
        .addRow(source)
        .captureRowTemplate(
          rowId: source.id,
          templateId: templateId,
          name: '회고',
        )
        .removeRow(source.id);
    final rule = runtime.rules(database).single;
    final scheduled = WorkspaceDatabase.fromJson({
      ...database.toJson(),
      'automationRules': [
        {
          ...rule,
          'trigger': {...rule['trigger'] as Map, 'startDate': '2026-10-29'},
          'actions': [
            {
              'id': newId(),
              'type': 'addRowFromTemplate',
              'templateId': templateId,
              'values': {number.id: 3},
            },
          ],
        },
      ],
    });
    await (await controller.store.open(item)).saveInk({
      'database.json': Uint8List.fromList(
        utf8.encode(jsonEncode(scheduled.toJson())),
      ),
      if (storeMedia) asset.reference.path: asset.bytes,
    });
    return (
      note: item,
      templateId: templateId,
      titleId: titleId,
      numberId: number.id,
      heading: heading,
      attachment: attachment,
      asset: asset,
    );
  }

  DatabaseAutomationCoordinator runner({
    int maxNotes = 16,
    int maxPages = 4,
    Duration interval = const Duration(minutes: 1),
    DateTime Function()? clock,
  }) => controller.createAutomationCoordinator(
    actionRuntime: runtime,
    clock: clock ?? () => moment,
    interval: interval,
    maxNotes: maxNotes,
    maxPagesPerNote: maxPages,
  );

  test('runs stored schedules for every clean database and commits rows and receipts once', () async {
    final notes = [await note('A'), await note('B')];
    final work = runner();
    final result = await work.runOnce();
    expect(result.committedNotes, 2);
    for (final item in notes) {
      final body = await saved(item);
      expect(body.rows, hasLength(1));
      expect(body.toJson()['automationExecutions'], hasLength(1));
    }
    await work.runOnce();
    for (final item in notes) {
      expect((await saved(item)).rows, hasLength(1));
    }
  });
  test(
    'a missing template attachment rejects the whole scheduled revision',
    () async {
      final fixture = await savedTemplate(storeMedia: false);
      final entityId = fixture.note.inkEntityId;
      final original = (await repo.heads(entityId)).single;
      final work = runner();
      final result = await work.runOnce();
      expect(runtime.prepared, hasLength(1));
      expect(result.committedNotes, 0);
      expect(result.outcomes.single.code, 'invalid_database');
      expect(
        (await repo.heads(entityId)).single.revisionId,
        original.revisionId,
      );
      expect(
        (await saved(fixture.note)).toJson()['automationExecutions'],
        isNull,
      );
      await work.runOnce();
      expect(runtime.queried.last['since'], isNull);
    },
  );
  test('Rust schedules persist missed template pages and shared media once', () async {
    final fixture = await savedTemplate(storeMedia: true);
    final entityId = fixture.note.inkEntityId;
    final original = (await repo.heads(entityId)).single;
    final native = InkVaultNative.open(libraryPath: libraryPath);
    final work = controller.createAutomationCoordinator(
      actionRuntime: DatabaseActionRuntime(
        deviceId: repo.deviceId,
        invoke: native.invoke,
      ),
      clock: () => moment,
    );
    final result = await work.runOnce();
    expect(result.committedNotes, 1, reason: '${result.toJson()}');
    expect(result.outcomes.single.events, 2);
    expect(result.outcomes.single.receipts, 2);
    final head = (await repo.heads(entityId)).single;
    expect(head.parentRevisionIds, [original.revisionId]);
    expect(
      head.blobs[fixture.asset.reference.path]!.toJson(),
      original.blobs[fixture.asset.reference.path]!.toJson(),
    );
    expect(
      head.blobs.keys,
      unorderedEquals(['database.json', fixture.asset.reference.path]),
    );
    final checkpoint = File(
      '${repo.root.path}/.workspace/automation-runner/notes/${fixture.note.id}.json',
    );
    await checkpoint.delete();
    controller.dispose();
    await repo.close();
    repo = await NoteRepository.open(repo.root);
    controller = WorkspaceController(repo);
    final reopened = DatabaseMediaSnapshot.fromFiles(
      await repo.readFiles(head),
    );
    final receipts = DatabaseActionRuntime(
      deviceId: repo.deviceId,
      invoke: native.invoke,
    ).receipts(reopened.database);
    expect(receipts.map((item) => item['inputRevision']).toSet(), {
      original.revisionId,
    });
    expect(receipts.map((item) => item['scheduledForUtcMs']), [
      DateTime.utc(2026, 10, 29, 9).millisecondsSinceEpoch,
      DateTime.utc(2026, 10, 30, 9).millisecondsSinceEpoch,
    ]);
    final generatedIds = <String>{fixture.heading.id, fixture.attachment.id};
    expect(reopened.database.rows, hasLength(2));
    for (final row in reopened.database.rows) {
      expect(row.values, {fixture.titleId: '팀 회고', fixture.numberId: 3});
      final body = BlockPageDocument.fromJson(row.body);
      final heading = body.blocks.single;
      final attachment = heading.children.single;
      expect(heading.text, '회고 항목');
      expect(attachment.text, '자료');
      expect(generatedIds.add(heading.id), isTrue);
      expect(generatedIds.add(attachment.id), isTrue);
      expect(body.media[attachment.id]?.path, fixture.asset.reference.path);
      expect(reopened.mediaBytes(row.id, attachment.id), fixture.asset.bytes);
    }
    expect(
      receipts.map(
        (receipt) => (receipt['actionResults'] as List).single['rowId'],
      ),
      unorderedEquals(reopened.database.rows.map((row) => row.id)),
    );
    final rerun = await controller
        .createAutomationCoordinator(
          actionRuntime: DatabaseActionRuntime(
            deviceId: repo.deviceId,
            invoke: native.invoke,
          ),
          clock: () => moment,
        )
        .runOnce();
    expect(rerun.failedNotes, 0, reason: '${rerun.toJson()}');
    expect(rerun.committedNotes, 0);
    expect((await repo.heads(entityId)).single.revisionId, head.revisionId);
  }, skip: !nativeAvailable);
  test('same in-flight pass is shared and captures the clock once', () async {
    await note('A');
    var clockReads = 0;
    final work = runner(
      clock: () {
        clockReads++;
        return moment;
      },
    );
    final first = work.runOnce(), second = work.runOnce();
    expect(identical(first, second), isTrue);
    await first;
    expect(clockReads, 1);
    expect(runtime.prepared.map((event) => event['at']).toSet(), {
      moment.millisecondsSinceEpoch,
    });
  });
  test('dirty or busy active editor prevents automatic writes without submitting or closing it', () async {
    final item = await note('A');
    await controller.openNote(item);
    controller.setInkDirty(true, session: controller.activeSession);
    final session = controller.activeSession;
    await runner().runOnce();
    expect(runtime.queried, isEmpty);
    expect(controller.activeSession, same(session));
    controller.setInkDirty(false, session: session);
    controller.setInkBusy(true, session: session);
    await runner().runOnce();
    expect(runtime.queried, isEmpty);
    expect((await saved(item)).rows, isEmpty);
    controller.setInkBusy(false, session: session);
  });
  test('new edit activity during preparation discards the plan', () async {
    final item = await note('A');
    await controller.openNote(item);
    runtime.beforePrepare = (_) =>
        controller.setInkDirty(true, session: controller.activeSession);
    final result = await runner().runOnce();
    expect(result.committedNotes, 0);
    expect((await saved(item)).rows, isEmpty);
    expect(controller.dirty, isTrue);
  });
  test('remote head arriving during preparation is preserved and automatic plan is discarded', () async {
    final item = await note('A');
    Future<RevisionRecord>? remote;
    runtime.beforePrepare = (_) {
      runtime.beforePrepare = null;
      remote = repo.commit(
        entityId: item.inkEntityId,
        kind: EntityKind.ink,
        ownerNoteId: item.id,
        files: {
          'database.json': Uint8List.fromList(
            utf8.encode(
              jsonEncode(WorkspaceDatabase.empty(id: item.id).toJson()),
            ),
          ),
        },
        parentRevisionIds: [],
      );
    };
    final result = await runner().runOnce();
    await remote;
    expect(result.committedNotes, 0);
    expect(await repo.heads(item.inkEntityId), hasLength(2));
    expect(runtime.prepared, hasLength(1));
  });
  test(
    'active clean database adopts the committed head and reloads its editor',
    () async {
      final item = await note('A');
      await controller.openNote(item);
      final session = controller.activeSession!,
          generation = controller.editorGeneration;
      final result = await runner().runOnce();
      expect(result.committedNotes, 1);
      expect(controller.activeSession, same(session));
      expect(controller.editorGeneration, greaterThan(generation));
      expect(session.inkParents, [
        (await repo.heads(item.inkEntityId)).single.revisionId,
      ]);
      expect(
        (await controller.loadDatabase(session: session)).rows,
        hasLength(1),
      );
      expect(controller.externalBusy, isFalse);
    },
  );
  test('one invalid database cannot block another database', () async {
    final first = await note('Bad'), second = await note('Good');
    runtime.query = (db, time, cursor, since) {
      if (db.id == first.id)
        throw const DatabaseActionException('invalid_schedule', 'Bad schedule');
      return DatabaseActionDue(
        events: [runtime.event(db, time)],
        hasMore: false,
        cursor: null,
        capturedAtUtcMs: time,
      );
    };
    final result = await runner().runOnce();
    expect(result.failedNotes, 1);
    expect(result.committedNotes, 1);
    expect((await saved(second)).rows, hasLength(1));
    expect((await saved(first)).rows, isEmpty);
  });
  test(
    'metadata and ink conflicts are skipped without new snapshots',
    () async {
      final item = await note('A');
      await repo.commit(
        entityId: item.inkEntityId,
        kind: EntityKind.ink,
        ownerNoteId: item.id,
        files: {
          'database.json': Uint8List.fromList(
            utf8.encode(jsonEncode((await saved(item)).toJson())),
          ),
        },
        parentRevisionIds: [],
      );
      final count = (await repo.revisions()).length;
      final result = await runner().runOnce();
      expect(result.committedNotes, 0);
      expect((await repo.revisions()).length, count);
      expect(runtime.prepared, isEmpty);
    },
  );
  test(
    'bounded note scans rotate instead of starving later databases',
    () async {
      final notes = [await note('A'), await note('B'), await note('C')];
      final work = runner(maxNotes: 1);
      for (var i = 0; i < 3; i++) {
        await work.runOnce();
      }
      for (final item in notes) {
        expect((await saved(item)).rows, hasLength(1));
      }
    },
  );
  test('opaque due cursor and original cutoff survive coordinator and process recreation', () async {
    final item = await note('A');
    runtime.query = (db, time, cursor, since) => DatabaseActionDue(
      events: cursor == null ? [] : [runtime.event(db, time)],
      hasMore: cursor == null,
      cursor: cursor == null ? {'page': 1} : null,
      capturedAtUtcMs: time,
    );
    await runner(maxPages: 1).runOnce();
    expect((await saved(item)).rows, isEmpty);
    controller.dispose();
    await repo.close();
    repo = await NoteRepository.open(repo.root);
    controller = WorkspaceController(repo);
    final later = moment.add(const Duration(hours: 1));
    await runner(maxPages: 1, clock: () => later).runOnce();
    expect((await saved(item)).rows, hasLength(1));
    expect(runtime.queried.last['cursor'], {'page': 1});
    expect(runtime.queried.last['cutoff'], moment.millisecondsSinceEpoch);
  });
  test(
    'successful completed horizon is supplied as since on the next scan',
    () async {
      await note('A');
      var now = moment;
      final work = runner(clock: () => now);
      await work.runOnce();
      now = now.add(const Duration(minutes: 1));
      await work.runOnce();
      expect(runtime.queried.last['since'], moment.millisecondsSinceEpoch);
    },
  );
  test(
    'failure never advances a horizon or skips an uncommitted scheduled effect',
    () async {
      final item = await note('A');
      var failed = false;
      runtime.beforePrepare = (_) {
        if (!failed) {
          failed = true;
          throw const DatabaseActionException('failure', 'First failed');
        }
      };
      final work = runner();
      await work.runOnce();
      expect((await saved(item)).rows, isEmpty);
      await work.runOnce();
      expect((await saved(item)).rows, hasLength(1));
      expect(runtime.queried.last['since'], isNull);
    },
  );
  test(
    'invalid checkpoint calendar time resets its scan without losing data',
    () async {
      final item = await note('A');
      runtime.query = (db, time, cursor, since) => DatabaseActionDue(
        events: [],
        hasMore: cursor == null,
        cursor: cursor == null ? {'page': 1} : null,
        capturedAtUtcMs: time,
      );
      final work = runner(maxPages: 1);
      await work.runOnce();
      final state = File(
        '${repo.root.path}/.workspace/automation-runner/notes/${item.id}.json',
      );
      final broken =
          jsonDecode(await state.readAsString()) as Map<String, dynamic>;
      broken['scanCutoffUtcMs'] = -9999999999999999;
      await state.writeAsString(jsonEncode(broken));
      await work.runOnce();
      expect(runtime.queried.last['cutoff'], moment.millisecondsSinceEpoch);
      expect(runtime.queried.last['cursor'], isNull);
      expect((await saved(item)).rows, isEmpty);
    },
  );

  test('runner report stays private after pause during preparation', () async {
    final item = await note('A');
    final work = runner();
    runtime.beforePrepare = (_) => work.pause();
    await work.runOnce();
    expect((await saved(item)).rows, isEmpty);
    expect(work.lastPass, isNull);
    runtime.beforePrepare = null;
    work.resume();
    final resumed = await work.runOnce();
    expect(resumed.committedNotes, 1);
    expect((await saved(item)).rows, hasLength(1));
    work.dispose();
  });

  test(
    'runner report clears immediately when its context is invalidated',
    () async {
      await note('A');
      final work = runner();
      await work.runOnce();
      expect(work.lastPass, isNotNull);
      work.pause();
      work.invalidate();
      expect(work.lastPass, isNull);
    },
  );

  test('runner report rejects a late completion after disposal', () async {
    await note('A');
    final work = runner();
    runtime.beforePrepare = (_) => work.dispose();
    await work.runOnce();
    expect(work.lastPass, isNull);
  });

  test(
    'runner report cannot be published into a different repository object',
    () async {
      await note('A');
      final replacement = await NoteRepository.open(
        Directory('${temp.path}/replacement'),
        createFormatVersion: 2,
      );
      final work = runner();
      runtime.beforePrepare = (_) => controller.repository = replacement;
      try {
        await work.runOnce();
        expect(work.lastPass, isNull);
      } finally {
        controller.repository = repo;
        await replacement.close();
      }
    },
  );
  test(
    'timer stops on pause and disposal and resumes without overlapping jobs',
    () async {
      await note('A');
      final work = runner(interval: const Duration(milliseconds: 20));
      work.start();
      for (var i = 0; i < 100 && runtime.queried.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(runtime.queried, isNotEmpty);
      work.pause();
      await work.runOnce();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      final before = runtime.queried.length;
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(runtime.queried.length, before);
      work.resume();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(runtime.queried.length, greaterThan(before));
      work.dispose();
      await work.runOnce();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      final stopped = runtime.queried.length;
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(runtime.queried.length, stopped);
    },
  );
  test('headless Drive opportunity executes local schedules even when consent needs reconnection', () async {
    final item = await note('A');
    final settingsDir = Directory('${temp.path}/drive')..createSync();
    final settings = await DriveConnectionSettings.load(settingsDir);
    final lease = await DriveSyncLease.acquire(0);
    settings.leasePort = lease.port;
    await lease.close();
    settings.accountId = 'account';
    settings.folderId = 'folder';
    settings.rootPath = repo.root.path;
    settings.vaultId = repo.vaultId;
    settings.vaultFormatVersion = 2;
    await settings.save(settingsDir);
    final auth = NoUiAuth();
    final result = await runDriveBackgroundSync(
      directory: settingsDir,
      authFactory: (_) => auth,
      actionRuntimeFactory: (repository) => runtime,
    );
    expect(result, isTrue);
    expect(auth.closed, isTrue);
    final fresh = await NoteRepository.open(repo.root);
    try {
      final body = WorkspaceDatabase.fromJson(
        jsonObject(
          jsonDecode(
            utf8.decode(
              (await fresh.readFiles(
                (await fresh.heads(item.inkEntityId)).single,
              ))['database.json']!,
            ),
          ),
        ),
      );
      expect(body.rows, hasLength(1));
      final status = jsonDecode(
        await File('${settingsDir.path}/automation-background-status.json')
            .readAsString(),
      ) as Map;
      expect(status['before']['committedNotes'], 1);
    } finally {
      await fresh.close();
    }
  });
}
