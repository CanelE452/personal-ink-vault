import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/nextcloud/nextcloud_client_extension.dart';
import 'package:saber/data/nextcloud/saber_syncer.dart';
import 'package:saber/data/prefs.dart';
import 'package:saber/data/sentry/sentry_init.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();

  test('app-declared plugin startup providers have installed Android sources', () {
    final manifest = File('android/app/src/main/AndroidManifest.xml')
        .readAsStringSync();
    final configFile = File('.dart_tool/package_config.json').absolute;
    final config =
        jsonDecode(configFile.readAsStringSync()) as Map<String, dynamic>;
    final packageRoots = (config['packages'] as List<dynamic>).map((entry) {
      final package = entry as Map<String, dynamic>;
      return Directory.fromUri(
        configFile.uri.resolve(package['rootUri'] as String),
      ).uri;
    });
    final sourceRoots = [
      Directory('android/app/src/main').absolute.uri,
      ...packageRoots.map((root) => root.resolve('android/src/main/')),
    ];
    final providers = RegExp(r'<provider\b[^>]*\bandroid:name="([^"]+)"')
        .allMatches(manifest);

    for (final provider in providers) {
      final className = provider.group(1)!;
      final classPath = className.replaceAll('.', '/');
      final hasSource = sourceRoots.any(
        (root) =>
            File.fromUri(root.resolve('java/$classPath.java')).existsSync() ||
            File.fromUri(root.resolve('kotlin/$classPath.kt')).existsSync(),
      );
      expect(
        hasSource,
        isTrue,
        reason:
            '$className is initialized before Flutter but its plugin source is missing',
      );
    }
  });

  test('legacy credentials cannot create an upstream client', () {
    stows.url.value = 'https://example.invalid';
    stows.username.value = 'synthetic-user';
    stows.ncPassword.value = 'synthetic-password';
    stows.encPassword.value = 'synthetic-encryption-password';
    expect(stows.loggedIn, isFalse);
    expect(NextcloudClientExtension.withSavedDetails(), isNull);
    expect(SaberSyncInterface.client, isNull);
  });

  test('local write, rename and delete preserve sibling upstream data and never enqueue uploads', () async {
    final sandbox = await Directory.systemTemp.createTemp(
      'ink-vault-isolation-',
    );
    addTearDown(() => sandbox.delete(recursive: true));
    final upstream = File('${sandbox.path}/Saber/original.sbn2');
    await upstream.create(recursive: true);
    await upstream.writeAsBytes([9, 8, 7]);
    await FileManager.init(
      documentsDirectory:
          '${sandbox.path}/${FileManager.appRootDirectoryPrefix}',
      shouldWatchRootDirectory: false,
    );
    final pendingBefore = syncer.uploader.pending.toList();
    await FileManager.writeFile('/draft.sbn2', [1, 2, 3], awaitWrite: true);
    expect(await FileManager.readFile('/draft.sbn2'), [1, 2, 3]);
    await FileManager.moveFile('/draft.sbn2', '/renamed.sbn2');
    expect(await FileManager.readFile('/renamed.sbn2'), [1, 2, 3]);
    await FileManager.deleteFile('/renamed.sbn2');
    expect(FileManager.doesFileExist('/renamed.sbn2'), isFalse);
    expect(await upstream.readAsBytes(), [9, 8, 7]);
    expect(syncer.uploader.pending, orderedEquals(pendingBefore));
  });

  test('previous Sentry consent cannot re-enable telemetry', () async {
    stows.sentryConsent.value = .granted;
    var appRuns = 0;
    await initSentry(() => appRuns++);
    expect(appRuns, 1);
    expect(isSentryAvailable, isFalse);
    expect(isSentryEnabled, isFalse);
  });
}
