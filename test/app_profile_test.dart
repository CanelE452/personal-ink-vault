import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:saber/data/app_profile.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    final originalPaths = PathProviderPlatform.instance;
    final originalPreferences = SharedPreferencesStorePlatform.instance;
    PathProviderPlatform.instance = _TrapPaths();
    SharedPreferencesStorePlatform.instance = _TrapPreferences();
    SharedPreferences.resetStatic();
    addTearDown(() {
      SharedPreferences.resetStatic();
      PathProviderPlatform.instance = originalPaths;
      SharedPreferencesStorePlatform.instance = originalPreferences;
    });
  });

  test('default and verbose options keep profile selection explicit', () {
    final defaults = AppStartupOptions.parse([]);
    expect(defaults.verbose, isFalse);
    expect(defaults.profileDirectory, isNull);
    for (final flag in ['--verbose', '-v']) {
      final options = AppStartupOptions.parse([flag]);
      expect(options.verbose, isTrue);
      expect(options.profileDirectory, isNull);
    }
  });

  test(
    'profile argument accepts a spaced absolute path in both forms',
    () async {
      final sandbox = await _sandbox();
      final profile = Directory(path.join(sandbox.path, '프로필 with spaces'));
      for (final args in [
        ['--profile-directory', profile.path, '-v'],
        ['--profile-directory=${profile.path}', '--verbose'],
      ]) {
        final options = AppStartupOptions.parse(args);
        expect(options.profileDirectory!.absolute.path, profile.absolute.path);
        expect(options.verbose, isTrue);
      }
      expect(profile.existsSync(), isFalse);
    },
  );

  test(
    'empty relative and unknown arguments fail without opening settings',
    () {
      final originalPaths = PathProviderPlatform.instance;
      final originalPreferences = SharedPreferencesStorePlatform.instance;
      for (final args in [
        ['--profile-directory='],
        ['--profile-directory', 'relative/profile'],
        ['--profile-directory'],
        ['--unknown-option'],
      ]) {
        expect(() => AppStartupOptions.parse(args), throwsFormatException);
      }
      expect(PathProviderPlatform.instance, same(originalPaths));
      expect(
        SharedPreferencesStorePlatform.instance,
        same(originalPreferences),
      );
    },
  );

  test('normal startup does not replace or read platform stores', () async {
    final originalPaths = PathProviderPlatform.instance;
    final originalPreferences = SharedPreferencesStorePlatform.instance;
    await configureAppProfile(null);
    expect(PathProviderPlatform.instance, same(originalPaths));
    expect(SharedPreferencesStorePlatform.instance, same(originalPreferences));
  });

  test(
    'profile paths stay below the explicit root and preserve sibling data',
    () async {
      final sandbox = await _sandbox();
      final personal = File(
        path.join(sandbox.path, 'personal', 'preferences.json'),
      );
      await personal.parent.create(recursive: true);
      await personal.writeAsBytes([9, 8, 7]);
      final profile = Directory(path.join(sandbox.path, 'profile'));

      if (!Platform.isWindows) {
        final originalPaths = PathProviderPlatform.instance;
        final originalPreferences = SharedPreferencesStorePlatform.instance;
        await expectLater(configureAppProfile(profile), throwsUnsupportedError);
        expect(PathProviderPlatform.instance, same(originalPaths));
        expect(
          SharedPreferencesStorePlatform.instance,
          same(originalPreferences),
        );
      } else {
        await configureAppProfile(profile);
        expect(
          (await getApplicationSupportDirectory()).path,
          path.join(profile.path, 'support'),
        );
        expect(
          (await getApplicationDocumentsDirectory()).path,
          path.join(profile.path, 'documents'),
        );
        expect(
          (await getApplicationCacheDirectory()).path,
          path.join(profile.path, 'cache'),
        );
        expect(
          (await getTemporaryDirectory()).path,
          path.join(profile.path, 'temp'),
        );
        expect(
          (await getDownloadsDirectory())!.path,
          path.join(profile.path, 'downloads'),
        );
        final preferences = await SharedPreferences.getInstance();
        expect(preferences.getKeys(), isEmpty);
        await preferences.setString('profile-name', '새 프로필');
        expect(_preferencesFile(profile).existsSync(), isTrue);
      }
      expect(await personal.readAsBytes(), [9, 8, 7]);
    },
  );

  test(
    'real preferences persist all supported value types across reopening',
    () async {
      final profile = await _sandbox();
      await configureAppProfile(profile);
      final preferences = await SharedPreferences.getInstance();
      await preferences.setBool('enabled', true);
      await preferences.setInt('count', 9007199254740993);
      await preferences.setDouble('scale', 1.5);
      await preferences.setString('title', '한글 😀');
      await preferences.setStringList('items', ['alpha', '나😀']);
      expect(jsonDecode(await _preferencesFile(profile).readAsString()), {
        'flutter.enabled': true,
        'flutter.count': 9007199254740993,
        'flutter.scale': 1.5,
        'flutter.title': '한글 😀',
        'flutter.items': ['alpha', '나😀'],
      });

      SharedPreferences.resetStatic();
      await configureAppProfile(profile);
      final reopened = await SharedPreferences.getInstance();
      expect(reopened.getBool('enabled'), isTrue);
      expect(reopened.getInt('count'), 9007199254740993);
      expect(reopened.getDouble('scale'), 1.5);
      expect(reopened.getString('title'), '한글 😀');
      expect(reopened.getStringList('items'), ['alpha', '나😀']);
    },
    skip: !Platform.isWindows,
  );

  test(
    'prefix and allow-list clearing preserve unrelated persisted keys',
    () async {
      final profile = await _sandbox();
      await configureAppProfile(profile);
      final store = SharedPreferencesStorePlatform.instance;
      await store.setValue('String', 'flutter.keep', 'kept');
      await store.setValue('String', 'flutter.remove', 'removed');
      await store.setValue('String', 'foreign.keep', 'foreign');
      await store.clearWithParameters(
        ClearParameters(
          filter: PreferencesFilter(
            prefix: 'flutter.',
            allowList: {'flutter.remove', 'foreign.keep'},
          ),
        ),
      );
      expect(await store.getAll(), {'flutter.keep': 'kept'});
      expect(
        await store.getAllWithParameters(
          GetAllParameters(
            filter: PreferencesFilter(prefix: '', allowList: {'foreign.keep'}),
          ),
        ),
        {'foreign.keep': 'foreign'},
      );
      await store.clear();

      await configureAppProfile(profile);
      expect(
        await SharedPreferencesStorePlatform.instance.getAllWithParameters(
          GetAllParameters(filter: PreferencesFilter(prefix: '')),
        ),
        {'foreign.keep': 'foreign'},
      );
    },
    skip: !Platform.isWindows,
  );

  test('concurrent eager preference writes survive a new backend', () async {
    final profile = await _sandbox();
    await configureAppProfile(profile);
    final preferences = await SharedPreferences.getInstance();
    await Future.wait([
      for (var index = 0; index < 24; index++)
        preferences.setInt('entry-$index', index),
    ]);

    SharedPreferences.resetStatic();
    await configureAppProfile(profile);
    final reopened = await SharedPreferences.getInstance();
    expect(reopened.getKeys(), hasLength(24));
    for (var index = 0; index < 24; index++) {
      expect(reopened.getInt('entry-$index'), index);
    }
  }, skip: !Platform.isWindows);

  test(
    'failed write preserves prior JSON and a later write can retry',
    () async {
      final sandbox = await _sandbox();
      final profile = Directory(path.join(sandbox.path, 'profile'));
      await configureAppProfile(profile);
      final store = SharedPreferencesStorePlatform.instance;
      await store.setValue('String', 'flutter.keep', 'original');
      final originalBytes = await _preferencesFile(profile).readAsBytes();
      final support = Directory(path.join(profile.path, 'support'));
      final preserved = Directory(path.join(sandbox.path, 'preserved-support'));
      await support.rename(preserved.path);
      final blocker = File(support.path);
      await blocker.writeAsString('test-owned parent collision');

      await expectLater(
        store.setValue('String', 'flutter.failed', 'must not persist'),
        throwsA(isA<FileSystemException>()),
      );
      expect(
        await File(path.join(preserved.path, 'shared_preferences.json'))
            .readAsBytes(),
        originalBytes,
      );
      await blocker.delete();
      await preserved.rename(support.path);
      await store.setValue('String', 'flutter.retry', 'saved');

      await configureAppProfile(profile);
      expect(await SharedPreferencesStorePlatform.instance.getAll(), {
        'flutter.keep': 'original',
        'flutter.retry': 'saved',
      });
    },
    skip: !Platform.isWindows,
  );

  test(
    'malformed profile JSON never installs partial providers or falls back',
    () async {
      final profile = await _sandbox();
      final preferencesFile = _preferencesFile(profile);
      await preferencesFile.parent.create(recursive: true);
      final originalPaths = PathProviderPlatform.instance;
      final originalPreferences = SharedPreferencesStorePlatform.instance;

      for (final invalid in [
        '{broken',
        '[]',
        '{"flutter.bad":{"nested":"value"}}',
      ]) {
        await preferencesFile.writeAsString(invalid);
        await expectLater(configureAppProfile(profile), throwsFormatException);
        expect(PathProviderPlatform.instance, same(originalPaths));
        expect(
          SharedPreferencesStorePlatform.instance,
          same(originalPreferences),
        );
        expect(await preferencesFile.readAsString(), invalid);
      }
    },
    skip: !Platform.isWindows,
  );
}

Future<Directory> _sandbox() async {
  final directory = await Directory.systemTemp.createTemp(
    'ink-app-profile-test-',
  );
  addTearDown(() => directory.delete(recursive: true));
  return directory;
}

File _preferencesFile(Directory profile) =>
    File(path.join(profile.path, 'support', 'shared_preferences.json'));

class _TrapPaths extends PathProviderPlatform {
  @override
  Future<String?> getApplicationSupportPath() async =>
      throw StateError('Default application support must not be read');

  @override
  Future<String?> getApplicationDocumentsPath() async =>
      throw StateError('Default documents must not be read');

  @override
  Future<String?> getApplicationCachePath() async =>
      throw StateError('Default cache must not be read');

  @override
  Future<String?> getTemporaryPath() async =>
      throw StateError('Default temporary path must not be read');

  @override
  Future<String?> getDownloadsPath() async =>
      throw StateError('Default downloads must not be read');
}

class _TrapPreferences extends SharedPreferencesStorePlatform {
  Never _unexpected() =>
      throw StateError('Default preferences must not be used');

  @override
  Future<Map<String, Object>> getAll() async => _unexpected();

  @override
  Future<Map<String, Object>> getAllWithParameters(
    GetAllParameters parameters,
  ) async => _unexpected();

  @override
  Future<bool> clear() async => _unexpected();

  @override
  Future<bool> clearWithParameters(ClearParameters parameters) async =>
      _unexpected();

  @override
  Future<bool> remove(String key) async => _unexpected();

  @override
  Future<bool> setValue(String valueType, String key, Object value) async =>
      _unexpected();
}
