import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ink_vault_core/drive.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/drive/drive_auth.dart';
import 'package:saber/data/drive/drive_background.dart';
import 'package:saber/data/drive/drive_connection.dart';
import 'package:saber/data/drive/oauth_flow.dart';
import 'package:saber/data/vault/database_actions.dart';

class NoUiAuth extends DriveAuth {
  new({this.token});
  final String? token;
  var closed = false;
  var tokenRequests = 0;
  @override
  String? get accountId => 'account';
  @override
  Future<void> restore() async {}
  @override
  Future<String> accessToken() async {
    tokenRequests++;
    return token ?? (throw const OAuthFailure('Authorization required'));
  }
  @override
  Future<void> signIn() async =>
      throw StateError('Background must never open UI');
  @override
  Future<void> signOut() async =>
      throw StateError('Background must not sign out');
  @override
  Future<void> cancel() async {}
  @override
  void close() {
    closed = true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'periodic registration failure leaves foreground sync running',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'drive-scheduler-test-',
      );
      final repo = await NoteRepository.open(Directory('${dir.path}/vault'));
      final settings = DriveConnectionSettings()
        ..accountId = 'account'
        ..folderId = 'folder'
        ..vaultId = repo.vaultId
        ..rootPath = repo.root.path
        ..vaultFormatVersion = repo.formatVersion;
      await settings.save(dir);
      var registrations = 0;
      final drive = DriveConnectionController(
        repository: () => repo,
        onRepositoryChanged: (_) async {},
        onRemoteUpdated: () async {},
        onResumeReload: () async {},
        directoryProvider: () async => dir,
        authFactory: (_) => NoUiAuth(token: 'synthetic-token'),
        registerBackgroundWork: () async {
          if (++registrations == 1) throw StateError('Scheduler unavailable');
        },
        remoteFactory: (token) => DriveRemoteStore(
          accessToken: token,
          client: MockClient((request) async {
            return http.Response(switch (request.url.path) {
              '/drive/v3/changes/startPageToken' =>
                '{"startPageToken":"first"}',
              '/drive/v3/files' => '{"files":[]}',
              '/drive/v3/changes' =>
                '{"changes":[],"newStartPageToken":"next"}',
              _ => fail('Unexpected synthetic request ${request.url.path}'),
            }, 200);
          }),
        ),
      );
      addTearDown(() async {
        await drive.close();
        await repo.close();
        await dir.delete(recursive: true);
      });

      await drive.initialize();
      expect(registrations, 1);
      expect(drive.connected, isTrue);
      expect(drive.error, isNull);
      expect(drive.backgroundRegistrationFailed, isTrue);
      final foreground = drive.coordinator!;
      if (drive.status.phase != SyncPhase.synced) {
        await foreground.statuses
            .firstWhere((status) => status.phase == SyncPhase.synced)
            .timeout(const Duration(seconds: 4));
      }
      await drive.retry();
      expect(registrations, 2);
      expect(drive.backgroundRegistrationFailed, isFalse);
      expect(drive.coordinator, same(foreground));
      expect(drive.status.phase, SyncPhase.synced);
    },
  );
  for (final hasToken in [true, false]) {
    test(
      'an unwritable status does not change ${hasToken ? 'successful sync' : 'required reauthentication'}',
      () async {
        final dir = await Directory.systemTemp.createTemp('drive-status-test-');
        addTearDown(() => dir.delete(recursive: true));
        final repo = await NoteRepository.open(Directory('${dir.path}/vault'));
        final lease = await DriveSyncLease.acquire(0);
        final settings = DriveConnectionSettings()
          ..leasePort = lease.port
          ..accountId = 'account'
          ..folderId = 'folder'
          ..vaultId = repo.vaultId
          ..rootPath = repo.root.path
          ..vaultFormatVersion = repo.formatVersion;
        await lease.close();
        await repo.close();
        await settings.save(dir);

        final statusPath = await Directory(
          '${dir.path}/background-status.json',
        ).create();
        final sentinel = await File('${statusPath.path}/preserve').writeAsString(
          'existing file',
        );
        final auth = NoUiAuth(token: hasToken ? 'synthetic-token' : null);
        var remoteRequests = 0;
        expect(
          await runDriveBackgroundSync(
            directory: dir,
            authFactory: (_) => auth,
            remoteFactory: (token) => DriveRemoteStore(
              accessToken: token,
              client: MockClient((request) async {
                remoteRequests++;
                return http.Response(switch (request.url.path) {
                  '/drive/v3/files/folder' => jsonEncode({
                    'id': 'folder',
                    'name': 'Fixture',
                    'mimeType': 'application/vnd.google-apps.folder',
                    'appProperties': {
                      'vaultId': settings.vaultId,
                      'format': 'ink-vault-v1',
                      'type': 'vault',
                    },
                  }),
                  '/drive/v3/changes/startPageToken' => '{"startPageToken":"first"}',
                  '/drive/v3/files' => '{"files":[]}',
                  '/drive/v3/changes' => '{"changes":[],"newStartPageToken":"next"}',
                  _ => fail('Unexpected synthetic request ${request.url.path}'),
                }, 200);
              }),
            ),
          ),
          isTrue,
        );
        final queue = File('${dir.path}/state/folder/sync-state.json');
        if (hasToken) {
          expect(remoteRequests, greaterThan(1));
          final state = jsonObject(jsonDecode(await queue.readAsString()));
          expect(state['lastSuccess'], isA<String>());
          expect(state['attempts'], 0);
        } else {
          expect(remoteRequests, 0);
          expect(queue.existsSync(), isFalse);
        }
        expect(auth.closed, isTrue);
        expect(await sentinel.readAsString(), 'existing file');
        expect(
          dir.listSync().map((entry) => entry.path),
          isNot(anyElement(endsWith('.pending'))),
        );
        final again = await DriveSyncLease.acquire(settings.leasePort);
        await again.close();
      },
    );
  }
  for (final hasExistingQueue in [false, true]) {
    test(
      'background folder retry is durable with ${hasExistingQueue ? 'an existing queue' : 'no state'}',
      () async {
        final dir = await Directory.systemTemp.createTemp('drive-folder-retry-');
        DriveConnectionController? controller;
        NoteRepository? foregroundRepo;
        addTearDown(() async {
          await controller?.close();
          await foregroundRepo?.close();
          await dir.delete(recursive: true);
        });
        final repo = await NoteRepository.open(Directory('${dir.path}/vault'));
        final lease = await DriveSyncLease.acquire(0);
        final settings = DriveConnectionSettings()
          ..leasePort = lease.port
          ..accountId = 'account'
          ..folderId = 'folder'
          ..vaultId = repo.vaultId
          ..rootPath = repo.root.path
          ..vaultFormatVersion = repo.formatVersion;
        await lease.close();
        await repo.close();
        await settings.save(dir);
        final file = File('${dir.path}/state/folder/sync-state.json');
        final previous = <String, Object?>{
          'version': 1,
          'vaultId': settings.vaultId,
          'remoteId': 'folder',
          'uploaded': ['published-revision'],
          'pending': ['pending-download'],
          'intents': {'queued-revision': 'reserved-id'},
          'knownFiles': {'known-file': 'known-revision'},
          'removedFiles': ['removed-file'],
          'cursor': 'saved-cursor',
          'attempts': 3,
          'retryAt': DateTime.utc(2024).toIso8601String(),
          'lastSuccess': DateTime.utc(2023).toIso8601String(),
          'authStopped': false,
          'blocked': false,
        };
        if (hasExistingQueue) {
          await file.parent.create(recursive: true);
          await file.writeAsString(jsonEncode(previous));
        }
        final backgroundAuth = NoUiAuth(token: 'synthetic-token');
        var firstRequests = 0;
        final before = DateTime.now().toUtc();
        const serverDelay = Duration(minutes: 1);
        final dateHeader = HttpDate.format(before.add(serverDelay));
        expect(
          await runDriveBackgroundSync(
            directory: dir,
            authFactory: (_) => backgroundAuth,
            remoteFactory: (token) => DriveRemoteStore(
              accessToken: token,
              client: MockClient((request) async {
                firstRequests++;
                expect(request.url.path, '/drive/v3/files/folder');
                return http.Response(
                  '',
                  503,
                  headers: {'retry-after': hasExistingQueue ? dateHeader : '60'},
                );
              }),
            ),
          ),
          isFalse,
        );
        final after = DateTime.now().toUtc();
        expect(firstRequests, 1);
        expect(backgroundAuth.closed, isTrue);
        final statusFile = File('${dir.path}/background-status.json');
        expect(
          jsonObject(jsonDecode(await statusFile.readAsString()))['phase'],
          'retryWaiting',
        );
        final stored = await file.readAsString();
        final state = jsonObject(jsonDecode(stored));
        final retryAt = DateTime.parse(state['retryAt'] as String);
        final earliest = hasExistingQueue
            ? HttpDate.parse(dateHeader)
            : before.add(serverDelay);
        expect(retryAt.isBefore(earliest), isFalse);
        expect(retryAt.isAfter(after.add(serverDelay)), isFalse);
        expect(state['attempts'], hasExistingQueue ? 4 : 1);
        if (hasExistingQueue) {
          expect(state, {
            ...previous,
            'attempts': 4,
            'retryAt': state['retryAt'],
          });
        }

        expect(
          await runDriveBackgroundSync(
            directory: dir,
            authFactory: (_) => fail('Background retried authentication too early'),
            remoteFactory: (_) => fail('Background retried Drive too early'),
          ),
          isFalse,
        );
        expect(await file.readAsString(), stored);
        if (hasExistingQueue) return;

        foregroundRepo = await NoteRepository.open(
          Directory(settings.rootPath!),
          vaultId: settings.vaultId,
        );
        final foregroundAuth = NoUiAuth(token: 'synthetic-token');
        var foregroundRequests = 0;
        final connection = controller = DriveConnectionController(
          repository: () => foregroundRepo!,
          onRepositoryChanged: (_) async => fail('Unexpected vault change'),
          onRemoteUpdated: () async {},
          onResumeReload: () async {},
          directoryProvider: () async => dir,
          authFactory: (_) => foregroundAuth,
          remoteFactory: (token) => DriveRemoteStore(
            accessToken: token,
            client: MockClient((request) async {
              foregroundRequests++;
              return http.Response(
                switch (request.url.path) {
                  '/drive/v3/changes/startPageToken' => '{"startPageToken":"first"}',
                  '/drive/v3/files' => '{"files":[]}',
                  '/drive/v3/changes' => '{"changes":[],"newStartPageToken":"second"}',
                  _ => fail('Unexpected synthetic Drive request: ${request.url.path}'),
                },
                200,
              );
            }),
          ),
        );
        await connection.initialize();
        expect(connection.error, isNull);
        final foregroundSync = connection.coordinator!;
        await foregroundSync.syncOnce();
        expect(foregroundSync.status.phase, SyncPhase.retryWaiting);
        expect(foregroundSync.status.retryAt, retryAt);
        expect(foregroundAuth.tokenRequests, 0);
        expect(foregroundRequests, 0);

        await connection.retry();
        expect(connection.error, isNull);
        expect(foregroundSync.status.phase, SyncPhase.synced);
        expect(foregroundRequests, greaterThan(0));
        final finished = jsonObject(jsonDecode(await file.readAsString()));
        expect(finished['retryAt'], isNull);
        expect(finished['attempts'], 0);
      },
    );
  }
  final cases = [
    (
      name: 'no state',
      phase: 'authenticationRequired',
      runsAuth: true,
      done: true,
    ),
    (
      name: 'expired hold',
      phase: 'authenticationRequired',
      runsAuth: true,
      done: true,
    ),
    (name: 'future hold', phase: 'retryWaiting', runsAuth: false, done: false),
    (
      name: 'auth stopped',
      phase: 'authenticationRequired',
      runsAuth: false,
      done: true,
    ),
    (name: 'blocked', phase: 'error', runsAuth: false, done: true),
    (name: 'foreign vault', phase: 'error', runsAuth: false, done: false),
    (name: 'foreign folder', phase: 'error', runsAuth: false, done: false),
    (name: 'invalid state', phase: 'error', runsAuth: false, done: false),
    (name: 'invalid queue', phase: 'error', runsAuth: false, done: false),
    (name: 'invalid folder ID', phase: 'error', runsAuth: false, done: false),
  ];
  for (final scenario in cases) {
    test('background preflight handles ${scenario.name}', () async {
      final dir = await Directory.systemTemp.createTemp(
        'drive-background-test-',
      );
      addTearDown(() => dir.delete(recursive: true));
      final hasLocalAutomation = scenario.name == 'future hold';
      final repo = await NoteRepository.open(
        Directory('${dir.path}/vault'),
        createFormatVersion: hasLocalAutomation ? 2 : 1,
      );
      final settings = await DriveConnectionSettings.load(dir);
      final lease = await DriveSyncLease.acquire(0);
      settings.leasePort = lease.port;
      await lease.close();
      settings.accountId = 'account';
      settings.folderId = scenario.name == 'invalid folder ID'
          ? '../outside'
          : 'folder';
      settings.vaultId = repo.vaultId;
      settings.rootPath = repo.root.path;
      settings.vaultFormatVersion = repo.formatVersion;
      await repo.close();
      await settings.save(dir);
      final queue = File('${dir.path}/state/folder/sync-state.json');
      final now = DateTime.now().toUtc();
      final deadline = scenario.name == 'expired hold'
          ? now.subtract(const Duration(minutes: 5))
          : now.add(const Duration(minutes: 5));
      final original = switch (scenario.name) {
        'no state' || 'invalid folder ID' => null,
        'invalid state' => 'malformed state bytes',
        _ =>
          '${jsonEncode({
            'version': 1,
            'vaultId': scenario.name == 'foreign vault' ? newId() : repo.vaultId,
            'remoteId': scenario.name == 'foreign folder' ? 'other-folder' : 'folder',
            'uploaded': scenario.name == 'invalid queue' ? [1] : <String>[],
            'pending': ['pending-file'],
            'intents': <String, String>{},
            'knownFiles': <String, String>{},
            'removedFiles': <String>[],
            'cursor': null,
            'attempts': 1,
            'retryAt': deadline.toIso8601String(),
            'lastSuccess': null,
            'authStopped': scenario.name == 'auth stopped',
            'blocked': scenario.name == 'blocked',
          })}\n',
      };
      if (original != null) {
        await queue.parent.create(recursive: true);
        await queue.writeAsString(original);
      }
      final auth = NoUiAuth();
      var authCreations = 0;
      expect(
        await runDriveBackgroundSync(
          directory: dir,
          authFactory: (_) {
            authCreations++;
            return auth;
          },
          actionRuntimeFactory: (repository) => DatabaseActionRuntime(
            deviceId: repository.deviceId,
            invoke: (_) => fail('Empty vault must not evaluate a rule'),
          ),
        ),
        scenario.done,
      );
      expect(authCreations, scenario.runsAuth ? 1 : 0);
      expect(auth.closed, scenario.runsAuth);
      if (original == null) {
        expect(queue.existsSync(), isFalse);
      } else {
        expect(await queue.readAsString(), original);
      }
      final status = jsonObject(
        jsonDecode(
          await File('${dir.path}/background-status.json').readAsString(),
        ),
      );
      expect(status['phase'], scenario.phase);
      if (hasLocalAutomation) {
        final automationStatus = jsonObject(
          jsonDecode(
            await File('${dir.path}/automation-background-status.json')
                .readAsString(),
          ),
        );
        expect(automationStatus['before'], containsPair('committedNotes', 0));
        expect(automationStatus['after'], containsPair('committedNotes', 0));
      }
      final again = await DriveSyncLease.acquire(settings.leasePort);
      await again.close();
    });
  }
}
