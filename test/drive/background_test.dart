import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/drive/drive_auth.dart';
import 'package:saber/data/drive/drive_background.dart';
import 'package:saber/data/drive/drive_connection.dart';
import 'package:saber/data/drive/oauth_flow.dart';

class NoUiAuth extends DriveAuth {
  var closed = false;
  @override
  String? get accountId => 'account';
  @override
  Future<void> restore() async {}
  @override
  Future<String> accessToken() async =>
      throw const OAuthFailure('Authorization required');
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
    'background auth failure preserves durable queue and closes auth',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'drive-background-test-',
      );
      addTearDown(() => dir.delete(recursive: true));
      final repo = await NoteRepository.open(Directory('${dir.path}/vault'));
      final settings = await DriveConnectionSettings.load(dir);
      final lease = await DriveSyncLease.acquire(0);
      settings.leasePort = lease.port;
      await lease.close();
      settings.accountId = 'account';
      settings.folderId = 'folder';
      settings.vaultId = repo.vaultId;
      settings.rootPath = repo.root.path;
      await repo.close();
      await settings.save(dir);
      final queue = File('${dir.path}/state/folder/sync-state.json');
      await queue.parent.create(recursive: true);
      await queue.writeAsString('durable queue remains byte-identical');
      final auth = NoUiAuth();
      expect(
        await runDriveBackgroundSync(directory: dir, authFactory: (_) => auth),
        isTrue,
      );
      expect(
        await queue.readAsString(),
        'durable queue remains byte-identical',
      );
      expect(auth.closed, isTrue);
      expect(
        await File('${dir.path}/background-status.json').readAsString(),
        contains('authenticationRequired'),
      );
      final again = await DriveSyncLease.acquire(settings.leasePort);
      await again.close();
    },
  );
}
