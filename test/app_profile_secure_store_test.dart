import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_secure_storage_windows/flutter_secure_storage_windows.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:saber/data/app_profile.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'native Windows credentials persist only in their selected profile',
    () async {
      final originalPaths = PathProviderPlatform.instance;
      final originalPreferences = SharedPreferencesStorePlatform.instance;
      final originalSecureStorage = FlutterSecureStoragePlatform.instance;
      final originalTarget = debugDefaultTargetPlatformOverride;
      final sandbox = await Directory.systemTemp.createTemp(
        'ink-profile-dpapi-',
      );
      const legacyChannel = MethodChannel(
        'plugins.it_nomads.com/flutter_secure_storage',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(legacyChannel, (_) async {
        throw StateError('Profile credentials must never read legacy storage');
      });
      addTearDown(() async {
        PathProviderPlatform.instance = originalPaths;
        SharedPreferencesStorePlatform.instance = originalPreferences;
        FlutterSecureStoragePlatform.instance = originalSecureStorage;
        debugDefaultTargetPlatformOverride = originalTarget;
        messenger.setMockMethodCallHandler(legacyChannel, null);
        await sandbox.delete(recursive: true);
      });

      PathProviderPlatform.instance = _NoDefaultSupport();
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      FlutterSecureStorageWindows.registerWith();
      final first = Directory(path.join(sandbox.path, 'first'));
      final second = Directory(path.join(sandbox.path, 'second'));
      const storage = FlutterSecureStorage();
      const key = 'synthetic-profile-token';
      const firstValue = 'profile-first-synthetic-credential-8472';
      const secondValue = 'profile-second-synthetic-credential-9158';

      await configureAppProfile(first);
      await storage.write(key: key, value: firstValue);
      expect(await storage.read(key: key), firstValue);
      expect(await storage.containsKey(key: key), isTrue);
      final firstFile = File(
        path.join(first.path, 'support', 'flutter_secure_storage.dat'),
      );
      final firstBytes = await firstFile.readAsBytes();
      expect(firstBytes, isNotEmpty);
      expect(
        utf8.decode(firstBytes, allowMalformed: true),
        isNot(contains(firstValue)),
      );

      FlutterSecureStorageWindows.registerWith();
      expect(await storage.readAll(), {key: firstValue});

      await configureAppProfile(second);
      FlutterSecureStorageWindows.registerWith();
      expect(await storage.read(key: key), isNull);
      await storage.write(key: key, value: secondValue);
      expect(await storage.readAll(), {key: secondValue});
      final secondFile = File(
        path.join(second.path, 'support', 'flutter_secure_storage.dat'),
      );
      expect(secondFile.existsSync(), isTrue);
      expect(await firstFile.readAsBytes(), firstBytes);

      await configureAppProfile(first);
      FlutterSecureStorageWindows.registerWith();
      expect(await storage.readAll(), {key: firstValue});
      expect(await firstFile.readAsBytes(), firstBytes);
    },
    skip: !Platform.isWindows,
  );
}

class _NoDefaultSupport extends PathProviderPlatform {
  @override
  Future<String?> getApplicationSupportPath() async =>
      throw StateError('Default user support directory must not be read');
}
