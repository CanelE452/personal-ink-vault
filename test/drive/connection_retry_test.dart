import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/drive/drive_connection.dart';

class FailingRecoveryDirectory implements Directory {
  final Directory directory;
  final bool failBackup, failSave;
  var creates = 0;
  new(
    this.directory, {
    this.failBackup = false,
    this.failSave = false,
  });
  @override
  String get path => directory.path;
  @override
  Future<Directory> create({bool recursive = false}) async {
    creates++;
    if (failSave && creates == 2) {
      throw const FileSystemException('Storage unavailable');
    }
    return directory.create(recursive: recursive);
  }

  @override
  Future<Directory> createTemp([String? prefix]) async {
    if (failBackup) throw const FileSystemException('Cannot preserve settings');
    return directory.createTemp(prefix);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'failed settings load can retry without overwriting the original',
    () async {
      final dir = await Directory.systemTemp.createTemp('drive-retry-test-');
      final repo = await NoteRepository.open(Directory('${dir.path}/vault'));
      final file = File('${dir.path}/connection.json');
      await file.writeAsString('broken-settings');
      final controller = DriveConnectionController(
        repository: () => repo,
        onRepositoryChanged: (_) async {},
        onRemoteUpdated: () async {},
        onResumeReload: () async {},
        directoryProvider: () async => dir,
      );
      addTearDown(() async {
        await controller.close();
        await repo.close();
        await dir.delete(recursive: true);
      });
      await controller.initialize();
      expect(controller.ready, isFalse);
      expect(controller.error, isNotNull);
      expect(await file.readAsString(), 'broken-settings');

      await DriveConnectionSettings().save(dir);
      await controller.initialize();
      expect(controller.ready, isTrue);
      expect(controller.error, isNull);
    },
  );
  test(
    'recovery preserves unique originals, local state, and secure account',
    () async {
      final dir = await Directory.systemTemp.createTemp('drive-recovery-test-');
      final repo = await NoteRepository.open(Directory('${dir.path}/vault'));
      final vaultConfig = await File('${repo.root.path}/vault.json')
          .readAsString();
      final queue = File('${dir.path}/state/existing-folder/sync-state.json');
      await queue.parent.create(recursive: true);
      await queue.writeAsString('durable pending changes');
      const identity = '{"accountId":"original-account"}';
      FlutterSecureStorage.setMockInitialValues({
        'drive.android.account': identity,
      });
      final original = File('${dir.path}/connection.json');
      final controllers = <DriveConnectionController>[];
      addTearDown(() async {
        for (final controller in controllers) {
          await controller.close();
        }
        await repo.close();
        await dir.delete(recursive: true);
      });
      final backupPaths = <String>[];
      for (final broken in [
        'first damaged settings',
        'second damaged settings',
      ]) {
        await original.writeAsString(broken);
        final controller = DriveConnectionController(
          repository: () => repo,
          onRepositoryChanged: (_) async =>
              fail('Must preserve local repository'),
          onRemoteUpdated: () async => fail('Recovery must not contact Drive'),
          onResumeReload: () async {},
          directoryProvider: () async => dir,
          authFactory: (_) =>
              throw StateError('Recovery must not touch authentication'),
          remoteFactory: (_) =>
              throw StateError('Recovery must not contact Drive'),
        );
        controllers.add(controller);
        await controller.initialize();
        expect(controller.ready, isFalse);
        await controller.recoverSettings();
        expect(controller.error, isNull);
        expect(controller.ready, isTrue);
        expect(controller.connected, isFalse);
        expect(controller.signedIn, isFalse);
        expect(controller.settings.accountId, isNull);
        expect(controller.settings.folderId, isNull);
        expect(controller.settings.rootPath, isNull);
        expect(controller.settings.vaultId, isNull);
        expect(controller.settings.intentFileId, isNull);
        backupPaths.add(controller.recoveryBackupPath!);
        expect(await File(backupPaths.last).readAsString(), broken);
        await controller
            .recoverSettings(); // A ready connection cannot be reset.
        expect(controller.recoveryBackupPath, backupPaths.last);
      }
      expect(backupPaths.toSet(), hasLength(2));
      expect(
        await File(backupPaths.first).readAsString(),
        'first damaged settings',
      );
      expect(
        await File('${repo.root.path}/vault.json').readAsString(),
        vaultConfig,
      );
      expect(await queue.readAsString(), 'durable pending changes');
      expect(
        await const FlutterSecureStorage().read(key: 'drive.android.account'),
        identity,
      );
    },
  );

  for (final failBackup in [true, false]) {
    test(
      'recovery failure ${failBackup ? 'before' : 'after'} archival preserves original bytes',
      () async {
        final dir = await Directory.systemTemp.createTemp(
          'drive-recovery-failure-',
        );
        final repo = await NoteRepository.open(Directory('${dir.path}/vault'));
        final original = File('${dir.path}/connection.json');
        await original.writeAsString('damaged settings');
        final directory = FailingRecoveryDirectory(
          dir,
          failBackup: failBackup,
          failSave: !failBackup,
        );
        final controller = DriveConnectionController(
          repository: () => repo,
          onRepositoryChanged: (_) async {},
          onRemoteUpdated: () async {},
          onResumeReload: () async {},
          directoryProvider: () async => directory,
        );
        addTearDown(() async {
          await controller.close();
          await repo.close();
          await dir.delete(recursive: true);
        });
        await controller.initialize();
        await controller.recoverSettings();
        expect(controller.ready, isFalse);
        expect(controller.error, isNotNull);
        if (failBackup) {
          expect(await original.readAsString(), 'damaged settings');
          expect(controller.recoveryBackupPath, isNull);
        } else {
          final backup = File(controller.recoveryBackupPath!);
          expect(await backup.readAsString(), 'damaged settings');
          expect(original.existsSync(), isFalse);
          await controller.recoverSettings();
          expect(controller.ready, isTrue);
          expect(await backup.readAsString(), 'damaged settings');
        }
      },
    );
  }
}
