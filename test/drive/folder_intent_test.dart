import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/drive.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/drive/drive_auth.dart';
import 'package:saber/data/drive/drive_connection.dart';

class IntentAuth extends DriveAuth {
  @override
  String get accountId => 'test-account';
  @override
  Future<void> restore() async {}
  @override
  Future<void> signIn() async {}
  @override
  Future<String> accessToken() async => 'never-uploaded-test-token';
  @override
  Future<void> signOut() async {}
  @override
  Future<void> cancel() async {}
  @override
  void close() {}
}

class LostFolderResponse extends DriveRemoteStore {
  final Directory directory;
  final List<String> creations;
  final void Function() generated;
  new(this.directory, this.creations, this.generated)
    : super(accessToken: () async => 'unused');
  @override
  Future<String> generateId() async {
    generated();
    return 'preallocated-folder-id';
  }

  @override
  Future<DriveVault> createVault({
    required String vaultId,
    String name = 'Personal Ink Vault',
    String? intentFileId,
  }) async {
    // The HTTP create boundary can observe a flushed intent before it acts.
    final onDisk = await DriveConnectionSettings.load(directory);
    expect(onDisk.intentFileId, intentFileId);
    expect(onDisk.accountId, 'test-account');
    creations.add(intentFileId!);
    throw RemoteException.retryable(
      'Response lost after server created the folder',
    );
  }
}

void main() {
  test(
    'folder response loss and app restart reuse durable preallocated file ID',
    () async {
      final dir = await Directory.systemTemp.createTemp('folder-intent-test-');
      addTearDown(() => dir.delete(recursive: true));
      final repo = await NoteRepository.open(Directory('${dir.path}/vault'));
      final creations = <String>[];
      var generated = 0;
      DriveConnectionController make() => DriveConnectionController(
        repository: () => repo,
        onRepositoryChanged: (_) async {},
        onRemoteUpdated: () async {},
        onResumeReload: () async {},
        directoryProvider: () async => dir,
        authFactory: (_) => IntentAuth(),
        remoteFactory: (_) =>
            LostFolderResponse(dir, creations, () => generated++),
      );
      final first = make();
      await first.initialize();
      await first.createCurrentVault();
      expect(first.error, isNotNull);
      await first.close();
      final restarted = make();
      await restarted.initialize();
      await restarted.createCurrentVault();
      expect(creations, ['preallocated-folder-id', 'preallocated-folder-id']);
      expect(generated, 1);
      expect(repo.vaultId, (await DriveConnectionSettings.load(dir)).vaultId);
      await restarted.close();
      await repo.close();
    },
  );
}
