import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:saber/data/native/ink_vault_native.dart';
import 'package:saber/main.dart' as app;
import 'package:saber/pages/workspace/library_home.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'support/windows_flow_harness.dart';
import 'support/windows_library_flow.dart';
import 'support/windows_office_flow.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Windows document creation, editing and reopening', (
    tester,
  ) async {
    final owned = await _OwnedRun.load();
    final h = WindowsFlowHarness(
      tester: tester,
      profile: owned.profile,
      fixturePdf: owned.fixture,
      artifacts: owned.artifacts,
    );
    expect(defaultTargetPlatform, TargetPlatform.windows);
    PathProviderPlatform.instance = _RejectDefaultPaths();
    SharedPreferencesStorePlatform.instance = _RejectDefaultPreferences();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (_) async => throw StateError('Unexpected legacy secure storage access'),
    );
    try {
      await h.record('native runner', {
        'pid': pid,
        'executable': Platform.resolvedExecutable,
        'profile': h.profile.path,
        'phase': owned.phase,
        'fixtureSha256': owned.fixtureSha256,
        'nativeVersion': InkVaultNative.open().version,
      });
      await app.main(['--profile-directory', h.profile.path, '--verbose']);
      final home = find.byType(LibraryHome);
      await h.waitUntil(
        'actual workspace startup',
        () => home.evaluate().length == 1,
      );
      await h.capture('library-startup');

      if (owned.phase == 'create') {
        expect(tester.widget<LibraryHome>(home).currentFolderId, isNull);
        await createLibraryFlow(h);
        await createOfficeFlow(h);
      } else {
        await reopenLibraryFlow(h);
        await reopenOfficeFlow(h);
      }

      await h.tapAppBarBack('상위 폴더로');
      await h.waitUntil(
        'return to root library',
        () =>
            home.evaluate().length == 1 &&
            tester.widget<LibraryHome>(home).currentFolderId == null &&
            find
                .text(WindowsFlowHarness.folderTitle)
                .hitTestable()
                .evaluate()
                .isNotEmpty,
      );
      await h.capture('root-library');
      await h.record('completed', {'phase': owned.phase});
      if (owned.phase == 'create') {
        final marker = owned.created;
        await marker.create(exclusive: true);
        await marker.writeAsString(
          jsonEncode({
            'pid': pid,
            'profile': h.profile.path,
            'fixtureSha256': owned.fixtureSha256,
          }),
          flush: true,
        );
      }
    } catch (error, stack) {
      try {
        await h.record('failed', {
          'error': error.toString(),
          'stack': '$stack',
        });
        await h.capture('failure').timeout(const Duration(seconds: 5));
      } on Object catch (captureError) {
        debugPrint('Failure evidence could not be saved: $captureError');
      }
      rethrow;
    }
  }, timeout: const Timeout(Duration(minutes: 12)));
}

class _OwnedRun {
  new(
    this.phase,
    this.profile,
    this.fixture,
    this.artifacts,
    this.created,
    this.fixtureSha256,
  );

  final String phase;
  final Directory profile, artifacts;
  final File fixture, created;
  final String fixtureSha256;

  static Future<_OwnedRun> load() async {
    const ownerPath = String.fromEnvironment('PIV_TEST_OWNER');
    const ownerSha = String.fromEnvironment('PIV_TEST_OWNER_SHA');
    final owner = File(ownerPath);
    if (!Platform.isWindows || !path.isAbsolute(ownerPath)) {
      throw StateError('Use the owned Windows integration test launcher');
    }
    final stage = owner.parent;
    if (!RegExp(r'^wi1-[0-9a-f]{16}$').hasMatch(path.basename(stage.path)) ||
        !path.equals(stage.parent.path, r'E:\CodexBuilds\personal-ink-vault') ||
        !path.equals(await stage.resolveSymbolicLinks(), stage.path)) {
      throw StateError('Unexpected integration stage location');
    }
    final bytes = await owner.readAsBytes();
    if (sha256.convert(bytes).toString() != ownerSha) {
      throw StateError('Owned test launch receipt changed');
    }
    final config = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    final phase = config['phase'];
    final attempt = config['attempt'] ?? 1;
    if (config['schemaVersion'] != 1 ||
        config['purpose'] != 'windows-native-workspace-flow' ||
        attempt is! int ||
        attempt < 1 ||
        attempt > 99 ||
        (phase != 'create' && phase != 'reopen')) {
      throw StateError('Unexpected Windows test launch receipt');
    }
    final run = attempt == 1
        ? stage
        : Directory(path.join(stage.path, 'run$attempt'));
    if (!path.equals(await run.resolveSymbolicLinks(), run.path)) {
      throw StateError('Unexpected integration attempt location');
    }
    final profile = Directory(path.join(run.path, '통합 시험 프로필'));
    final artifacts = Directory(
      path.join(run.path, 'evidence', phase as String),
    );
    final fixture = File(path.join(stage.path, 'fixtures', 'native-flow.pdf'));
    final created = File(path.join(run.path, 'create-completed.json'));
    final fixtureSha256 = sha256
        .convert(await fixture.readAsBytes())
        .toString();
    if (fixtureSha256 != config['fixtureSha256'] ||
        !path.equals(await fixture.resolveSymbolicLinks(), fixture.path) ||
        !path.equals(await profile.resolveSymbolicLinks(), profile.path) ||
        !path.equals(
          await artifacts.parent.resolveSymbolicLinks(),
          artifacts.parent.path,
        ) ||
        FileSystemEntity.typeSync(artifacts.path, followLinks: false) !=
            FileSystemEntityType.notFound) {
      throw StateError('Unexpected fixture, profile or evidence location');
    }
    if (phase == 'create') {
      if (!await profile.list().isEmpty || created.existsSync()) {
        throw StateError('Creation requires an empty test profile');
      }
    } else {
      final first =
          jsonDecode(await created.readAsString()) as Map<String, dynamic>;
      if (first['pid'] == pid ||
          first['profile'] != profile.path ||
          first['fixtureSha256'] != fixtureSha256) {
        throw StateError(
          'Reopen requires a successful separate create process',
        );
      }
    }
    await artifacts.create();
    return _OwnedRun(
      phase,
      profile,
      fixture,
      artifacts,
      created,
      fixtureSha256,
    );
  }
}

class _RejectDefaultPaths extends PathProviderPlatform {
  Never _reject() => throw StateError('App requested a default user directory');

  @override
  Future<String?> getApplicationSupportPath() async => _reject();
  @override
  Future<String?> getApplicationDocumentsPath() async => _reject();
  @override
  Future<String?> getApplicationCachePath() async => _reject();
  @override
  Future<String?> getDownloadsPath() async => _reject();
  @override
  Future<String?> getTemporaryPath() async => _reject();
}

class _RejectDefaultPreferences extends SharedPreferencesStorePlatform {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError(
    'App requested default preferences: ${invocation.memberName}',
  );
}
