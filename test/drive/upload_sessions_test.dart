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

const _account = 'fixture-account';
const _folder = 'fixture-folder';

class _MemorySecrets implements DriveSecrets {
  final values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

class _FixtureAuth extends DriveAuth {
  @override
  String? get accountId => _account;

  @override
  Future<void> restore() async {}

  @override
  Future<String> accessToken() async => 'synthetic-token';

  @override
  Future<void> signIn() async => fail('Unexpected interactive login');

  @override
  Future<void> signOut() async {}

  @override
  Future<void> cancel() async {}

  @override
  void close() {}
}

class _RecordingDrive extends DriveRemoteStore {
  DriveUploadSessions? sessions;

  new(Future<String> Function() token, String vaultId)
    : super(
        accessToken: token,
        client: MockClient((request) async {
          expect(request.method, 'GET');
          return http.Response(switch (request.url.path) {
            '/drive/v3/files/$_folder' => jsonEncode({
              'id': _folder,
              'name': 'Fixture',
              'mimeType': 'application/vnd.google-apps.folder',
              'appProperties': {
                'vaultId': vaultId,
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
      );

  @override
  RemoteStore bind(DriveVault vault, {DriveUploadSessions? uploadSessions}) {
    sessions = uploadSessions;
    return super.bind(vault, uploadSessions: uploadSessions);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('background and fresh foreground share only the scoped secure slot', () async {
    final dir = await Directory.systemTemp.createTemp('piv-drive-upload-slot-');
    addTearDown(() => dir.delete(recursive: true));
    final vaultDir = Directory('${dir.path}/vault');
    final original = await NoteRepository.open(vaultDir);
    final vaultId = original.vaultId;
    final deviceId = original.deviceId;
    await original.close();

    final lease = await DriveSyncLease.acquire(0);
    final settings = DriveConnectionSettings()
      ..accountId = _account
      ..folderId = _folder
      ..rootPath = vaultDir.path
      ..vaultId = vaultId
      ..vaultFormatVersion = 1
      ..leasePort = lease.port;
    await lease.close();
    await settings.save(dir);

    final secrets = _MemorySecrets();
    late _RecordingDrive background;
    expect(
      await runDriveBackgroundSync(
        directory: dir,
        authFactory: (_) => _FixtureAuth(),
        remoteFactory: (token) => background = _RecordingDrive(token, vaultId),
        uploadSessionSecrets: secrets,
      ),
      isTrue,
    );
    final checkpoint = jsonEncode({
      'uri':
          'https://www.googleapis.com/upload/drive/v3/files?upload_id=fixture',
    });
    await background.sessions!.write(checkpoint);
    final expectedKey = secrets.values.keys.single;
    expect(expectedKey, matches(r'^drive\.upload-session\.v1\.[0-9a-f]{64}$'));

    final differentScopes = [
      (account: 'other-account', folder: _folder, device: deviceId),
      (account: _account, folder: 'other-folder', device: deviceId),
      (account: _account, folder: _folder, device: newId()),
    ];
    for (final scope in differentScopes) {
      final slot = SecureDriveUploadSessions(
        accountId: scope.account,
        folderId: scope.folder,
        deviceId: scope.device,
        secrets: secrets,
      );
      expect(await slot.read(), isNull);
      await slot.write('unrelated checkpoint');
    }

    final reopened = await NoteRepository.open(vaultDir);
    addTearDown(reopened.close);
    late _RecordingDrive foreground;
    final controller = DriveConnectionController(
      repository: () => reopened,
      onRepositoryChanged: (_) async => fail('Unexpected vault change'),
      onRemoteUpdated: () async {},
      onResumeReload: () async {},
      directoryProvider: () async => dir,
      authFactory: (_) => _FixtureAuth(),
      remoteFactory: (token) => foreground = _RecordingDrive(token, vaultId),
      uploadSessionSecrets: secrets,
    );
    addTearDown(controller.close);
    await controller.initialize();
    expect(controller.error, isNull);
    expect(controller.connected, isTrue);
    expect(await foreground.sessions!.read(), checkpoint);
    for (final path in ['connection.json', 'state/$_folder/sync-state.json']) {
      expect(
        await File('${dir.path}/$path').readAsString(),
        isNot(contains('upload_id')),
      );
    }

    await controller.signOut();
    expect(controller.error, isNull);
    expect(controller.connected, isFalse);
    expect(await foreground.sessions!.read(), isNull);
    expect(secrets.values, hasLength(3));
    expect(secrets.values.values, everyElement('unrelated checkpoint'));
  });
}
