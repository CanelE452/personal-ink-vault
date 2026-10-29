import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/drive/drive_connection.dart';
import 'package:saber/data/drive/oauth_flow.dart';

void main() {
  test(
    'connection intent survives restart and settings contain no tokens',
    () async {
      final dir = await Directory.systemTemp.createTemp('drive-settings-test-');
      addTearDown(() => dir.delete(recursive: true));
      final settings = await DriveConnectionSettings.load(dir);
      settings.accountId = 'account-a';
      settings.rootPath = '/local/vault';
      settings.intentFileId = 'durable-folder-id';
      await settings.save(dir);
      final reopened = await DriveConnectionSettings.load(dir);
      expect(reopened.intentFileId, 'durable-folder-id');
      expect(reopened.accountId, 'account-a');
      expect(
        await File('${dir.path}/connection.json').readAsString(),
        isNot(contains('token')),
      );
      expect(
        () => reopened.requireAccount('account-b'),
        throwsA(isA<OAuthFailure>()),
      );
      reopened.requireAccount('account-a');
      reopened.clearConnection();
      expect(reopened.accountId, isNull);
      expect(reopened.rootPath, isNull);
      expect(reopened.intentFileId, isNull);
    },
  );

  test(
    'lease excludes a second foreground/background engine until close',
    () async {
      final first = await DriveSyncLease.acquire(0);
      final port = first.port;
      await expectLater(
        DriveSyncLease.acquire(port),
        throwsA(isA<SocketException>()),
      );
      await first.close();
      final second = await DriveSyncLease.acquire(port);
      await second.close();
    },
  );
}
