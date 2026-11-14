import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path/path.dart' as p;
import 'package:saber/data/mcp/vault_mcp_bridge.dart';
import 'package:saber/data/mcp/vault_mcp_service.dart';
import 'package:saber/data/native/ink_vault_native.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/pages/workspace/workspace_controller.dart';

Matcher _error(String code) =>
    isA<VaultMcpException>().having((e) => e.code, 'code', code);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late NoteRepository repo;
  late WorkspaceController controller;
  late VaultMcpService service;
  late VaultNote target, source;
  late String other;
  var writable = true;
  final context = VaultMcpCallContext(
    isActive: () => true,
    canWrite: () => writable,
  );
  Future<void> attach() async {
    controller = WorkspaceController(
      repo,
      native: InkVaultNative.open(libraryPath: _nativePath),
    );
    service = VaultMcpService(controller);
  }

  Future<void> restart() async {
    await controller.flush();
    controller.dispose();
    await repo.close();
    repo = await NoteRepository.open(Directory(p.join(temp.path, 'vault')));
    await attach();
  }

  Future<Map<String, dynamic>> call(Map<String, dynamic> args) async =>
      jsonObject(await service.call('document_action', args, context: context));
  File receipt(Map<String, dynamic> args) => File(
    p.join(
      repo.root.path,
      '.workspace',
      'mcp',
      'requests',
      args['requestId'] + '.json',
    ),
  );
  Future<Map<String, dynamic>> saved(Map<String, dynamic> args) async =>
      jsonObject(jsonDecode(await receipt(args).readAsString()));
  List<RevisionRecord> planned(Map<String, dynamic> record) => [
    for (final raw in record['plan']['steps'] as List)
      RevisionRecord.fromJson(jsonObject(raw['record'])),
  ];
  Map<String, dynamic> arguments(String action) => {
    'noteId': target.id,
    'action': action,
    if (action == 'rename') 'title': 'Renamed',
    if (action == 'move') 'folderId': other,
    'expectedRevisionId': target.revision.revisionId,
    'requestId': newId(),
  };
  Future<Map<String, dynamic>> prepare(Map<String, dynamic> args) async {
    final fault = _PathReceiptIo(
      (path, body) =>
          path.endsWith('/${args['requestId']}.json') &&
          body?['state'] == 'prepared',
      afterRename: true,
    );
    await IOOverrides.runWithIOOverrides(() async {
      await expectLater(call(args), throwsA(isA<VaultMcpException>()));
    }, fault);
    expect(fault.fired, true);
    final record = await saved(args);
    expect(record['version'], 2);
    expect(record['operation'], 'document_action');
    expect(record['state'], 'prepared');
    expect(
      (await repo.heads(target.id)).single.revisionId,
      target.revision.revisionId,
    );
    return record;
  }

  Future<Map<String, dynamic>> suspendAfterFirstBody(
    Map<String, dynamic> args,
  ) async {
    final subscription = repo.changes.listen((_) => writable = false);
    try {
      await expectLater(call(args), throwsA(_error('read_only')));
    } finally {
      await subscription.cancel();
    }
    final record = await saved(args);
    expect(record['state'], 'prepared');
    expect(
      (await repo.heads(target.id)).single.revisionId,
      target.revision.revisionId,
    );
    writable = true;
    return record;
  }

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('mcp-path-receipt-');
    repo = await NoteRepository.open(
      Directory(p.join(temp.path, 'vault')),
      createFormatVersion: 2,
    );
    await attach();
    writable = true;
    final course = await controller.library.createFolder('Course');
    other = (await controller.library.createFolder('Other')).id;
    target = await controller.store.create(
      'B',
      folderId: course.id,
      documentKind: VaultDocumentKind.markdown,
    );
    source = await controller.store.create(
      'Outside',
      documentKind: VaultDocumentKind.markdown,
    );
    await (await controller.store.open(source))
        .saveMarkdown('[read](Course/B.md#Heading)');
    await controller.refresh();
  });
  tearDown(() async {
    await controller.flush();
    controller.dispose();
    await repo.close();
    final actual = await temp.resolveSymbolicLinks();
    final parent = await Directory.systemTemp.resolveSymbolicLinks();
    expect(
      actual,
      startsWith('$parent${Platform.pathSeparator}mcp-path-receipt-'),
    );
    await Directory(actual).delete(recursive: true);
  });

  group(
    'durable document action receipts',
    () {
      test('a new request adopts the exact pending body prefix and survives prepared receipt response loss', () async {
        final original = arguments('rename');
        final before = (await repo.revisions())
            .map((r) => r.revisionId)
            .toSet();
        final old = await suspendAfterFirstBody(original);
        final expected = planned(old);
        final retry = {...original, 'requestId': newId()};
        final fault = _PathReceiptIo(
          (path, body) =>
              path.endsWith('/${retry['requestId']}.json') &&
              body?['state'] == 'prepared',
          afterRename: true,
        );
        await IOOverrides.runWithIOOverrides(() async {
          await expectLater(call(retry), throwsA(isA<VaultMcpException>()));
        }, fault);
        expect(fault.fired, true);
        final adopted = await saved(retry);
        expect(adopted['state'], 'prepared');
        expect(
          planned(adopted).map((r) => r.revisionId),
          expected.map((r) => r.revisionId),
        );
        expect(
          (adopted['baselineRevisionIds'] as List).toSet(),
          (old['baselineRevisionIds'] as List).toSet(),
        );
        expect(
          (await repo.heads(target.id)).single.revisionId,
          target.revision.revisionId,
        );
        await restart();
        final result = await call(retry);
        expect(result['metadataRevisionId'], expected.last.revisionId);
        expect(
          (await repo.revisions())
              .where((r) => !before.contains(r.revisionId))
              .map((r) => r.revisionId)
              .toSet(),
          expected.map((r) => r.revisionId).toSet(),
        );
        final count = (await repo.revisions()).length;
        expect(await call(original), result);
        expect(await call(retry), result);
        expect((await repo.revisions()).length, count);
        await expectLater(
          call({...original, 'requestId': newId()}),
          throwsA(_error('revision_conflict')),
        );
      });

      test('a new pending retry rejects a foreign head committed after its request baseline was captured', () async {
        final original = arguments('rename');
        final old = await suspendAfterFirstBody(original);
        final oldBytes = await receipt(original).readAsBytes();
        final before = (await repo.revisions())
            .map((r) => r.revisionId)
            .toSet();
        final retry = {...original, 'requestId': newId()};
        VaultNote? external;
        final fault = _PathReceiptIo(
          (path, body) =>
              path.endsWith('/${retry['requestId']}.json') &&
              body?['state'] == 'started',
          afterRename: true,
          throwFailure: false,
          onMatch: () async {
            external = await controller.store.create('Unrelated late document');
          },
        );
        await IOOverrides.runWithIOOverrides(() async {
          await expectLater(call(retry), throwsA(_error('revision_conflict')));
        }, fault);
        expect(fault.fired, true);
        expect(external, isNotNull);
        final added = (await repo.revisions())
            .where((r) => !before.contains(r.revisionId))
            .toList();
        expect(added, isNotEmpty);
        expect(
          added.every(
            (r) => r.entityId == external!.id || r.ownerNoteId == external!.id,
          ),
          true,
        );
        expect(
          (await repo.heads(target.id)).single.revisionId,
          target.revision.revisionId,
        );
        expect(
          (await repo.revisions()).any(
            (r) => r.revisionId == planned(old).last.revisionId,
          ),
          false,
        );
        expect((await saved(retry))['state'], 'started');
        expect(await receipt(original).readAsBytes(), oldBytes);
      });

      test('a new repeated trash request observes late child heads without changing the deleted body', () async {
        final offline = await controller.store.open(target);
        await call(arguments('trash'));
        const raw = 'Unobserved [raw](B.md#Heading)';
        await offline.saveMarkdown(raw);
        target = (await controller.store.list(includeDeleted: true))
            .singleWhere((n) => n.id == target.id);
        expect(target.deletionConflict, true);
        final previous = target.revision;
        final body = (await repo.heads(target.markdownEntityId)).single;
        expect(
          previous.baseRefs[target.markdownEntityId],
          isNot([body.revisionId]),
        );
        final args = arguments('trash');
        final result = await call(args);
        final deleted = (await controller.store.list(includeDeleted: true))
            .singleWhere((n) => n.id == target.id);
        expect(deleted.revision.revisionId, isNot(previous.revisionId));
        expect(deleted.revision.parentRevisionIds, [previous.revisionId]);
        expect(deleted.revision.baseRefs[target.markdownEntityId], [
          body.revisionId,
        ]);
        expect(deleted.deletionConflict, false);
        expect(result['conflict'], false);
        expect(result['trashed'], true);
        expect(
          await (await controller.store.open(deleted)).readMarkdown(),
          raw,
        );
        final count = (await repo.revisions()).length;
        expect(await call(args), result);
        expect((await repo.revisions()).length, count);
      });

      test('fresh no-op uses the same folder state as its captured baseline and remains replayable', () async {
        final args = arguments('move')..['folderId'] = target.folderId;
        final folder = (await controller.library.listFolders()).singleWhere(
          (f) => f.id == target.folderId,
        );
        final files = await repo.readFiles(folder.revision);
        final records = await repo.revisions();
        final parents = records.expand((r) => r.parentRevisionIds).toSet();
        final bases = <String, List<String>>{
          for (final record in records)
            if (!parents.contains(record.revisionId) &&
                (record.entityId == target.id ||
                    record.ownerNoteId == target.id))
              record.entityId: [record.revisionId],
        };
        final metadataHash = target.revision.blobs['note.json']!.hash;
        var targetReads = 0;
        Future<RevisionRecord>? concurrent;
        final race = _PathReceiptIo(
          (_, _) => false,
          afterRename: false,
          afterRead: (path) {
            if (p.basename(path) != metadataHash || ++targetReads != 2) return;
            concurrent = repo.commit(
              entityId: folder.id,
              kind: EntityKind.folder,
              files: files,
              parentRevisionIds: [folder.revision.revisionId],
              deleted: true,
              baseRefs: bases,
            );
          },
        );
        await IOOverrides.runWithIOOverrides(() async {
          final result = await call(args);
          expect(concurrent, isNotNull);
          await concurrent;
          final current = (await controller.store.list(includeDeleted: true))
              .singleWhere((n) => n.id == target.id);
          expect(current.trashed, true);
          expect(current.deletionConflict, false);
          expect(result['trashed'], current.trashed);
          expect(result['conflict'], current.deletionConflict);
          final count = (await repo.revisions()).length;
          expect(await call(args), result);
          expect((await repo.revisions()).length, count);
        }, race);
      });

      test('no-op acknowledgement accepts a canonical metadata source imported from another device', () async {
        final files = await repo.readFiles(target.revision);
        final remote = RevisionRecord.fromJson({
          ...target.revision.toJson(),
          'revisionId': newId(),
          'parentRevisionIds': [target.revision.revisionId],
          'deviceId': newId(),
        });
        await repo.importRevision(
          remote,
          blobsByHash: {
            for (final entry in remote.blobs.entries)
              entry.value.hash: files[entry.key]!,
          },
        );
        target = (await controller.store.list()).singleWhere(
          (n) => n.id == target.id,
        );
        expect(target.revision.deviceId, isNot(repo.deviceId));
        final args = arguments('move')..['folderId'] = target.folderId;
        final result = await call(args);
        final count = (await repo.revisions()).length;
        await restart();
        expect(await call(args), result);
        expect((await repo.revisions()).length, count);
      });

      test('format1 source metadata remains replayable after an actual format2 clone', () async {
        final legacy = await NoteRepository.open(
          Directory(p.join(temp.path, 'legacy')),
          createFormatVersion: 1,
        );
        NoteRepository? upgraded;
        WorkspaceController? upgradedController;
        try {
          await WorkspaceStore(legacy).create('Legacy');
          final directory = Directory(p.join(temp.path, 'upgraded'));
          upgraded = await legacy.cloneToEmpty(
            directory,
            targetFormatVersion: 2,
          );
          upgradedController = WorkspaceController(
            upgraded,
            native: InkVaultNative.open(libraryPath: _nativePath),
          );
          final cloned = (await upgradedController.store.list()).single;
          expect(upgraded.formatVersion, 2);
          expect(cloned.revision.formatVersion, 1);
          expect(cloned.revision.deviceId, isNot(upgraded.deviceId));
          final args = <String, dynamic>{
            'noteId': cloned.id,
            'action': 'move',
            'folderId': null,
            'expectedRevisionId': cloned.revision.revisionId,
            'requestId': newId(),
          };
          final result = await VaultMcpService(upgradedController)
              .call('document_action', args, context: context);
          final count = (await upgraded.revisions()).length;
          await upgradedController.flush();
          upgradedController.dispose();
          upgradedController = null;
          await upgraded.close();
          upgraded = await NoteRepository.open(directory);
          upgradedController = WorkspaceController(
            upgraded,
            native: InkVaultNative.open(libraryPath: _nativePath),
          );
          expect(
            await VaultMcpService(upgradedController)
                .call('document_action', args, context: context),
            result,
          );
          expect((await upgraded.revisions()).length, count);
        } finally {
          await upgradedController?.flush();
          upgradedController?.dispose();
          await upgraded?.close();
          await legacy.close();
        }
      });

      for (final action in ['trash', 'restore']) {
        test(
          '$action reports the captured folder deletion conflict and keeps the exact acknowledgement',
          () async {
            if (action == 'restore') {
              await controller.store.setDeleted(target, true);
              target = (await controller.store.list(includeDeleted: true))
                  .singleWhere((n) => n.id == target.id);
            }
            final folder = (await controller.library.listFolders()).singleWhere(
              (f) => f.id == target.folderId,
            );
            await controller.library.setDeleted(folder, true);
            target = (await controller.store.list(includeDeleted: true))
                .singleWhere((n) => n.id == target.id);
            expect(target.deletionConflict, false);
            final args = arguments(action);
            final result = await call(args);
            final current = (await controller.store.list(includeDeleted: true))
                .singleWhere((n) => n.id == target.id);
            expect(current.deletionConflict, true);
            expect(result['trashed'], current.trashed);
            expect(result['conflict'], current.deletionConflict);
            final count = (await repo.revisions()).length;
            await restart();
            expect(await call(args), result);
            expect((await repo.revisions()).length, count);
          },
        );
      }

      test('fresh publication rechecks the original metadata manifest after durable preparation', () async {
        final args = arguments('move');
        final original = File(
          p.join(
            repo.root.path,
            'revisions',
            '${target.revision.revisionId}.json',
          ),
        );
        final before = (await repo.revisions())
            .map((r) => r.revisionId)
            .toSet();
        final fault = _PathReceiptIo(
          (path, body) =>
              path.endsWith('/${args['requestId']}.json') &&
              body?['state'] == 'prepared',
          afterRename: true,
          throwFailure: false,
          onMatch: () async {
            final json = jsonObject(jsonDecode(await original.readAsString()))
              ..['deviceId'] = newId();
            await original.writeAsString(jsonEncode(json));
          },
        );
        await IOOverrides.runWithIOOverrides(() async {
          await expectLater(
            call(args),
            throwsA(_error('operation_state_unknown')),
          );
        }, fault);
        expect(fault.fired, true);
        expect(
          (await repo.revisions()).map((r) => r.revisionId).toSet(),
          before,
        );
        expect(
          (await repo.heads(target.id)).single.revisionId,
          target.revision.revisionId,
        );
      });

      for (final state in ['prepared', 'completed']) {
        test(
          '$state acknowledgement rejects an exact linked canonical revisions directory',
          () async {
            final args = arguments('move');
            if (state == 'prepared') {
              await prepare(args);
            } else {
              await call(args);
            }
            final canonical = Directory(p.join(repo.root.path, 'revisions'));
            final retained = Directory(p.join(temp.path, 'retained-revisions'));
            final outside = await Directory(
              p.join(temp.path, 'outside-revisions'),
            ).create();
            final bytes = <String, Uint8List>{};
            await for (final entry in canonical.list(followLinks: false)) {
              expect(entry, isA<File>());
              final name = p.basename(entry.path);
              bytes[name] = await File(entry.path).readAsBytes();
              await File(entry.path).copy(p.join(outside.path, name));
            }
            final owned = await temp.resolveSymbolicLinks();
            expect(
              await canonical.resolveSymbolicLinks(),
              p.join(owned, 'vault', 'revisions'),
            );
            expect(await retained.parent.resolveSymbolicLinks(), owned);
            expect(
              await outside.resolveSymbolicLinks(),
              p.join(owned, 'outside-revisions'),
            );
            expect(
              FileSystemEntity.typeSync(retained.path, followLinks: false),
              FileSystemEntityType.notFound,
            );
            await canonical.rename(retained.path);
            try {
              await Link(canonical.path).create(outside.path);
              await expectLater(
                call(args),
                throwsA(_error('operation_state_unknown')),
              );
              expect(outside.listSync(followLinks: false).length, bytes.length);
              for (final entry in bytes.entries) {
                expect(
                  await File(p.join(outside.path, entry.key)).readAsBytes(),
                  entry.value,
                );
              }
            } finally {
              if (FileSystemEntity.typeSync(
                    canonical.path,
                    followLinks: false,
                  ) ==
                  FileSystemEntityType.link) {
                await Link(canonical.path).delete();
              }
              expect(
                await retained.resolveSymbolicLinks(),
                p.join(owned, 'retained-revisions'),
              );
              expect(
                await canonical.parent.resolveSymbolicLinks(),
                p.join(owned, 'vault'),
              );
              await retained.rename(canonical.path);
            }
          },
        );
      }

      test(
        'a linked prepared payload with the exact expected bytes is rejected',
        () async {
          final args = arguments('move');
          final record = await prepare(args);
          final hash = record['files'][0]['summary.md']['sha256'] as String;
          final private = File(
            p.join(
              repo.root.path,
              '.workspace',
              'mcp',
              'requests',
              args['requestId'],
              'path',
              record['recoveryId'],
              '0',
              hash,
            ),
          );
          final outside = File(p.join(temp.path, 'outside-payload'));
          await private.copy(outside.path);
          final bytes = await outside.readAsBytes();
          await private.delete();
          await Link(private.path).create(outside.path);
          final count = (await repo.revisions()).length;
          try {
            await expectLater(
              call(args),
              throwsA(_error('operation_state_unknown')),
            );
            expect((await repo.revisions()).length, count);
            expect(await outside.readAsBytes(), bytes);
          } finally {
            await Link(private.path).delete();
          }
        },
      );

      test('an oversized rehashed payload manifest is rejected before reading or publishing', () async {
        final args = arguments('move');
        final record = await prepare(args);
        record['files'][0]['summary.md']['byteLength'] = 128 * 1024 * 1024 + 1;
        record['plan']['steps'][0]['record']['blobs']['summary.md']['length'] =
            128 * 1024 * 1024 + 1;
        record['planDigest'] = _planDigest(record);
        await receipt(args).writeAsString(jsonEncode(record));
        final count = (await repo.revisions()).length;
        await expectLater(
          call(args),
          throwsA(_error('operation_state_unknown')),
        );
        expect((await repo.revisions()).length, count);
      });

      for (final damage in [
        'sourceOwner',
        'finalDeletion',
        'bodyBytes',
        'metadataBytes',
      ]) {
        test(
          'an internally rehashed $damage plan cannot change its original role or requested action',
          () async {
            final args = arguments('move');
            final record = await prepare(args);
            final steps = record['plan']['steps'] as List;
            if (damage == 'sourceOwner') {
              steps.first['record']['ownerNoteId'] = target.id;
            } else if (damage == 'finalDeletion') {
              steps.last['record']['deleted'] = true;
            } else {
              final index = damage == 'bodyBytes' ? 0 : steps.length - 1;
              final name = damage == 'bodyBytes' ? 'summary.md' : 'note.json';
              final manifest = record['files'][index][name];
              final oldHash = manifest['sha256'] as String;
              final directory = p.join(
                repo.root.path,
                '.workspace',
                'mcp',
                'requests',
                args['requestId'],
                'path',
                record['recoveryId'],
                index.toString(),
              );
              final old = File(p.join(directory, oldHash));
              final bytes = damage == 'bodyBytes'
                  ? Uint8List.fromList(
                      utf8.encode('Unrelated arbitrary source content'),
                    )
                  : Uint8List.fromList(
                      utf8.encode(
                        jsonEncode(
                          jsonObject(jsonDecode(await old.readAsString()))
                            ..['folderId'] = target.folderId,
                        ),
                      ),
                    );
              final hash = sha256.convert(bytes).toString();
              await File(p.join(directory, hash)).writeAsBytes(bytes);
              await old.delete();
              record['files'][index][name] = {
                'sha256': hash,
                'byteLength': bytes.length,
              };
              steps[index]['record']['blobs'][name] = {
                'hash': hash,
                'length': bytes.length,
              };
            }
            record['planDigest'] = _planDigest(record);
            await receipt(args).writeAsString(jsonEncode(record));
            final bytes = await receipt(args).readAsBytes();
            final count = (await repo.revisions()).length;
            await restart();
            await expectLater(
              call(args),
              throwsA(_error('operation_state_unknown')),
            );
            expect((await repo.revisions()).length, count);
            expect(await receipt(args).readAsBytes(), bytes);
            expect(
              (await repo.heads(target.id)).single.revisionId,
              target.revision.revisionId,
            );
          },
        );
      }

      test('a changed original metadata manifest blocks prepared publication in the same repository instance', () async {
        final args = arguments('move');
        await prepare(args);
        final source = File(
          p.join(
            repo.root.path,
            'revisions',
            '${target.revision.revisionId}.json',
          ),
        );
        final changed = jsonObject(jsonDecode(await source.readAsString()))
          ..['deviceId'] = newId();
        await source.writeAsString(jsonEncode(changed));
        final bytes = await source.readAsBytes();
        final count = (await repo.revisions()).length;
        await expectLater(
          call(args),
          throwsA(_error('operation_state_unknown')),
        );
        expect((await repo.revisions()).length, count);
        expect(await source.readAsBytes(), bytes);
      });

      test('moving to the same folder records an exact no-op acknowledgement without new revisions', () async {
        final args = arguments('move')..['folderId'] = target.folderId;
        final before = (await repo.revisions())
            .map((r) => r.revisionId)
            .toSet();
        final result = await call(args);
        expect(result['metadataRevisionId'], target.revision.revisionId);
        expect((await saved(args))['version'], 2);
        await restart();
        expect(await call(args), result);
        expect(
          (await repo.revisions()).map((r) => r.revisionId).toSet(),
          before,
        );
      });

      test('a completed result acknowledges its exact metadata after a later normal descendant', () async {
        final args = arguments('move');
        final result = await call(args);
        final current = (await controller.store.list()).singleWhere(
          (n) => n.id == target.id,
        );
        await controller.store.rename(current, 'Later title');
        final count = (await repo.revisions()).length;
        await restart();
        expect(await call(args), result);
        expect((await repo.revisions()).length, count);
        expect(
          (await controller.store.list())
              .singleWhere((n) => n.id == target.id)
              .title,
          'Later title',
        );
      });

      for (final action in ['rename', 'move', 'trash', 'restore']) {
        test(
          '$action resumes the exact prepared editions after full repository restart',
          () async {
            if (action == 'restore') {
              await controller.store.setDeleted(target, true);
              target = (await controller.store.list(includeDeleted: true))
                  .singleWhere((n) => n.id == target.id);
            }
            final args = arguments(action);
            final record = await prepare(args);
            final steps = planned(record);
            expect(
              record['rootUri'],
              repo.root.absolute.uri.normalizePath().toString(),
            );
            expect(record['vaultId'], repo.vaultId);
            expect(record['deviceId'], repo.deviceId);
            expect(record['formatVersion'], repo.formatVersion);
            expect(record['noteId'], target.id);
            expect(record['action'], action);
            expect(record['sourceRevisionId'], target.revision.revisionId);
            final old = (await repo.revisions())
                .map((r) => r.revisionId)
                .toSet();
            await restart();
            final result = await call(args);
            expect(result['metadataRevisionId'], steps.last.revisionId);
            expect(
              (await repo.revisions())
                  .where((r) => !old.contains(r.revisionId))
                  .map((r) => r.revisionId)
                  .toSet(),
              steps.map((r) => r.revisionId).toSet(),
            );
            final count = (await repo.revisions()).length;
            expect(await call(args), result);
            expect((await repo.revisions()).length, count);
            expect((await saved(args))['state'], 'completed');
          },
        );
      }

      for (final loss in ['firstBody', 'finalMetadata', 'completedReceipt']) {
        test(
          '$loss response loss survives full restart without sibling editions',
          () async {
            final args = arguments('move');
            final fault = _PathReceiptIo((path, body) {
              if (loss == 'completedReceipt')
                return path.endsWith('/${args['requestId']}.json') &&
                    body?['state'] == 'completed';
              return path.contains('/revisions/') &&
                  body?['entityId'] ==
                      (loss == 'firstBody'
                          ? source.markdownEntityId
                          : target.id);
            }, afterRename: loss != 'completedReceipt');
            final before = (await repo.revisions())
                .map((r) => r.revisionId)
                .toSet();
            await IOOverrides.runWithIOOverrides(() async {
              await expectLater(call(args), throwsA(isA<VaultMcpException>()));
            }, fault);
            expect(fault.fired, true);
            final record = await saved(args);
            expect(record['state'], 'prepared');
            final steps = planned(record);
            await restart();
            final result = await call(args);
            expect(result['metadataRevisionId'], steps.last.revisionId);
            expect(
              (await repo.revisions())
                  .where((r) => !before.contains(r.revisionId))
                  .map((r) => r.revisionId)
                  .toSet(),
              steps.map((r) => r.revisionId).toSet(),
            );
            expect(
              await (await controller.store.open(source)).readMarkdown(),
              '[read](inkvault://note/${target.id}?view=markdown#Heading)',
            );
          },
        );
      }

      test('permission revoked after a body publication resumes exact metadata after restart', () async {
        final args = arguments('trash');
        final listener = repo.changes.listen((_) => writable = false);
        try {
          await expectLater(call(args), throwsA(_error('read_only')));
        } finally {
          await listener.cancel();
        }
        final record = await saved(args);
        expect(record['state'], 'prepared');
        final steps = planned(record);
        expect(
          (await repo.heads(target.id)).single.revisionId,
          target.revision.revisionId,
        );
        writable = true;
        await restart();
        final result = await call(args);
        expect(result['metadataRevisionId'], steps.last.revisionId);
        expect((await repo.heads(target.id)).single.deleted, true);
      });

      for (final race in ['sourceHead', 'metadata', 'lateEntity']) {
        test(
          '$race after durable preparation cannot rebase or publish the captured plan',
          () async {
            final args = arguments('move');
            final record = await prepare(args);
            if (race == 'sourceHead') {
              await (await controller.store.open(source))
                  .saveMarkdown('Concurrent source');
            } else if (race == 'metadata') {
              final current = await repo.readFiles(target.revision);
              final metadata = jsonObject(
                jsonDecode(utf8.decode(current['note.json']!)),
              )..['title'] = 'Concurrent title';
              await repo.commit(
                entityId: target.id,
                kind: EntityKind.metadata,
                files: {
                  ...current,
                  'note.json': Uint8List.fromList(
                    utf8.encode(jsonEncode(metadata)),
                  ),
                },
                parentRevisionIds: [target.revision.revisionId],
              );
            } else {
              await controller.store.create('Late document');
            }
            final count = (await repo.revisions()).length;
            await restart();
            await expectLater(call(args), throwsA(_error('revision_conflict')));
            expect((await repo.revisions()).length, count);
            expect(
              (await repo.revisions()).where(
                (r) => planned(record).any((s) => s.revisionId == r.revisionId),
              ),
              isEmpty,
            );
          },
        );
      }

      for (final damage in [
        'rootUri',
        'vaultId',
        'deviceId',
        'formatVersion',
        'action',
        'sourceRevisionId',
        'planDigest',
      ]) {
        test(
          'damaged $damage recovery binding is rejected without publication',
          () async {
            final args = arguments('move');
            final record = await prepare(args);
            record[damage] = switch (damage) {
              'formatVersion' => 999,
              'action' => 'trash',
              'rootUri' => Directory(
                p.join(temp.path, 'other-vault'),
              ).absolute.uri.toString(),
              'planDigest' => '0' * 64,
              _ => newId(),
            };
            await receipt(args).writeAsString(jsonEncode(record));
            final bytes = await receipt(args).readAsBytes();
            final count = (await repo.revisions()).length;
            await restart();
            await expectLater(
              call(args),
              throwsA(_error('operation_state_unknown')),
            );
            expect((await repo.revisions()).length, count);
            expect(await receipt(args).readAsBytes(), bytes);
          },
        );
      }

      for (final damage in ['missing', 'malformed', 'different']) {
        test(
          'completed acknowledgement checks the actual $damage final manifest',
          () async {
            final args = arguments('move');
            final result = await call(args);
            final manifest = File(
              p.join(
                repo.root.path,
                'revisions',
                result['metadataRevisionId'] + '.json',
              ),
            );
            if (damage == 'missing') {
              await manifest.delete();
            } else if (damage == 'malformed') {
              await manifest.writeAsString('{');
            } else {
              final json = jsonObject(jsonDecode(await manifest.readAsString()))
                ..['deviceId'] = newId();
              await manifest.writeAsString(jsonEncode(json));
            }
            final bytes = manifest.existsSync()
                ? await manifest.readAsBytes()
                : null;
            await expectLater(
              call(args),
              throwsA(_error('operation_state_unknown')),
            );
            expect(
              manifest.existsSync() ? await manifest.readAsBytes() : null,
              bytes,
            );
          },
        );
      }

      test(
        'a version-only downgrade cannot bypass actual manifest validation',
        () async {
          final args = arguments('move');
          final result = await call(args);
          final record = await saved(args);
          record['version'] = 1;
          await receipt(args).writeAsString(jsonEncode(record));
          await File(
            p.join(
              repo.root.path,
              'revisions',
              result['metadataRevisionId'] + '.json',
            ),
          ).delete();
          await expectLater(
            call(args),
            throwsA(_error('operation_state_unknown')),
          );
        },
      );

      for (final state in ['started', 'completed']) {
        test(
          'genuine legacy v1 $state document receipt preserves its original contract',
          () async {
            final args = arguments('move');
            final digest = sha256
                .convert(
                  utf8.encode(
                    jsonEncode(
                      _canonical({
                        'operation': 'document_action',
                        'arguments': args,
                      }),
                    ),
                  ),
                )
                .toString();
            final legacyResult = {'noteId': target.id, 'legacy': true};
            await receipt(args).parent.create(recursive: true);
            await receipt(args).writeAsString(
              jsonEncode({
                'version': 1,
                'requestId': args['requestId'],
                'digest': digest,
                'state': state,
                if (state == 'completed') 'result': legacyResult,
              }),
            );
            await restart();
            if (state == 'completed') {
              expect(await call(args), legacyResult);
            } else {
              await expectLater(
                call(args),
                throwsA(_error('operation_state_unknown')),
              );
            }
            expect(
              (await repo.heads(target.id)).single.revisionId,
              target.revision.revisionId,
            );
          },
        );
      }

      test('a linked receipt file is rejected without following its completed result', () async {
        final args = arguments('move');
        await receipt(args).parent.create(recursive: true);
        final outside = File(p.join(temp.path, 'outside.json'));
        final digest = sha256
            .convert(
              utf8.encode(
                jsonEncode(
                  _canonical({
                    'operation': 'document_action',
                    'arguments': args,
                  }),
                ),
              ),
            )
            .toString();
        await outside.writeAsString(
          jsonEncode({
            'version': 1,
            'requestId': args['requestId'],
            'digest': digest,
            'state': 'completed',
            'result': {'noteId': target.id, 'forged': true},
          }),
        );
        final bytes = await outside.readAsBytes();
        await Link(receipt(args).path).create(outside.path);
        try {
          await expectLater(
            call(args),
            throwsA(_error('operation_state_unknown')),
          );
          expect(await outside.readAsBytes(), bytes);
        } finally {
          await Link(receipt(args).path).delete();
        }
      });
    },
    skip: File(_nativePath).existsSync() ? false : 'Set INK_VAULT_NATIVE_LIBRARY to the installed common-engine library.',
  );
}

Object? _canonical(Object? value) {
  if (value is Map)
    return {
      for (final key in value.keys.cast<String>().toList()..sort())
        key: _canonical(value[key]),
    };
  if (value is List) return value.map(_canonical).toList();
  return value;
}

String _planDigest(Map<String, dynamic> receipt) => sha256
    .convert(
      utf8.encode(
        jsonEncode(
          _canonical({
            for (final entry in receipt.entries)
              if (!{'state', 'result', 'planDigest'}.contains(entry.key))
                entry.key: entry.value,
          }),
        ),
      ),
    )
    .toString();

final _nativePath =
    Platform.environment['INK_VAULT_NATIVE_LIBRARY'] ??
    p.absolute('build', 'native', 'windows', 'ink_vault_native.dll');

final class _PathReceiptIo extends IOOverrides {
  new(
    this.select, {
    required this.afterRename,
    this.throwFailure = true,
    this.onMatch,
    this.afterRead,
  });
  final bool Function(String target, Map<String, dynamic>? body) select;
  final bool afterRename;
  final bool throwFailure;
  final Future<void> Function()? onMatch;
  final void Function(String path)? afterRead;
  var fired = false;
  @override
  File createFile(String path) =>
      _PathReceiptFile(super.createFile(path), this);
}

class _PathReceiptFile implements File {
  new(this.inner, this.fault);
  final File inner;
  final _PathReceiptIo fault;
  @override
  String get path => inner.path;
  @override
  Uri get uri => inner.uri;
  @override
  File get absolute => inner.absolute;
  @override
  Directory get parent => inner.parent;
  @override
  bool existsSync() => inner.existsSync();
  @override
  Future<bool> exists() async => inner.existsSync();
  @override
  int lengthSync() => inner.lengthSync();
  @override
  Future<int> length() => inner.length();
  @override
  FileStat statSync() => inner.statSync();
  @override
  Future<FileStat> stat() async => inner.statSync();
  @override
  DateTime lastModifiedSync() => inner.lastModifiedSync();
  @override
  Stream<List<int>> openRead([int? start, int? end]) =>
      inner.openRead(start, end);
  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) =>
      inner.open(mode: mode);
  @override
  RandomAccessFile openSync({FileMode mode = FileMode.read}) =>
      inner.openSync(mode: mode);
  @override
  Future<File> create({bool recursive = false, bool exclusive = false}) =>
      inner.create(recursive: recursive, exclusive: exclusive);
  @override
  Future<String> readAsString({Encoding encoding = utf8}) =>
      inner.readAsString(encoding: encoding);
  @override
  String readAsStringSync({Encoding encoding = utf8}) =>
      inner.readAsStringSync(encoding: encoding);
  @override
  Future<Uint8List> readAsBytes() async {
    final bytes = await inner.readAsBytes();
    fault.afterRead?.call(path);
    return bytes;
  }

  @override
  Uint8List readAsBytesSync() => inner.readAsBytesSync();
  @override
  Future<File> writeAsString(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) => inner.writeAsString(
    contents,
    mode: mode,
    encoding: encoding,
    flush: flush,
  );
  @override
  Future<File> writeAsBytes(
    List<int> bytes, {
    FileMode mode = FileMode.write,
    bool flush = false,
  }) => inner.writeAsBytes(bytes, mode: mode, flush: flush);
  @override
  Future<File> rename(String newPath) async {
    final target = newPath.replaceAll('\\', '/');
    Map<String, dynamic>? body;
    if (target.endsWith('.json')) {
      try {
        final parsed = jsonDecode(await inner.readAsString());
        if (parsed is Map) body = jsonObject(parsed);
      } on FormatException {
        body = null;
      }
    }
    final selected = !fault.fired && fault.select(target, body);
    if (selected) fault.fired = true;
    if (selected && !fault.afterRename) {
      await fault.onMatch?.call();
      if (fault.throwFailure)
        throw FileSystemException('Injected path durable rename failure', path);
    }
    final result = await inner.rename(newPath);
    if (selected && fault.afterRename) {
      await fault.onMatch?.call();
      if (fault.throwFailure)
        throw FileSystemException(
          'Injected path response loss after actual rename',
          path,
        );
    }
    return result;
  }

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) =>
      inner.delete(recursive: recursive);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
