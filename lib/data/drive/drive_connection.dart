import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:ink_vault_core/drive.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path_provider/path_provider.dart';

import 'package:saber/data/drive/drive_auth.dart';
import 'package:saber/data/drive/drive_background.dart';
import 'package:saber/data/drive/oauth_flow.dart';

class DriveConnectionSettings {
  var androidServerClientId = const String.fromEnvironment(
    'DRIVE_ANDROID_SERVER_CLIENT_ID',
  );
  var desktopClientId = const String.fromEnvironment('DRIVE_DESKTOP_CLIENT_ID');
  String? accountId, folderId, vaultId, rootPath, intentFileId;
  var leasePort = 0;
  int? vaultFormatVersion;
  static Future<DriveConnectionSettings> load(Directory directory) async {
    final result = DriveConnectionSettings();
    final file = File('${directory.path}/connection.json');
    if (!file.existsSync()) return result;
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    if (json['version'] != 1)
      throw const FormatException('Unsupported Drive connection settings');
    result.androidServerClientId =
        json['androidServerClientId'] as String? ??
        result.androidServerClientId;
    result.desktopClientId =
        json['desktopClientId'] as String? ?? result.desktopClientId;
    result.accountId = json['accountId'] as String?;
    result.folderId = json['folderId'] as String?;
    result.vaultId = json['vaultId'] as String?;
    result.rootPath = json['rootPath'] as String?;
    result.intentFileId = json['intentFileId'] as String?;
    result.leasePort = json['leasePort'] as int? ?? 0;
    result.vaultFormatVersion = json['vaultFormatVersion'] as int?;
    if (result.vaultFormatVersion != null &&
        result.vaultFormatVersion != 1 &&
        result.vaultFormatVersion != 2) {
      throw const FormatException('Unsupported connected vault format');
    }
    if (result.leasePort < 0 || result.leasePort > 65535)
      throw const FormatException('Invalid local sync lease');
    return result;
  }

  Future<void> save(Directory directory) async {
    await directory.create(recursive: true);
    final target = File('${directory.path}/connection.json');
    final temp = File('${target.path}.${newId()}.tmp');
    try {
      await temp.writeAsString(
        jsonEncode({
          'version': 1,
          'androidServerClientId': androidServerClientId,
          'desktopClientId': desktopClientId,
          'accountId': accountId,
          'folderId': folderId,
          'vaultId': vaultId,
          'rootPath': rootPath,
          'intentFileId': intentFileId,
          'leasePort': leasePort,
          'vaultFormatVersion': vaultFormatVersion,
        }),
        flush: true,
      );
      await temp.rename(target.path);
    } finally {
      if (temp.existsSync()) await temp.delete();
    }
  }

  void requireAccount(String? actual) {
    if (actual == null || accountId != null && accountId != actual) {
      throw const OAuthFailure(
        'Reconnect the original Google account, or disconnect Drive before choosing another account. Local notes are preserved.',
      );
    }
  }

  void clearConnection() {
    accountId = folderId = vaultId = rootPath = intentFileId = null;
    vaultFormatVersion = null;
  }
}

/// TCP binding supplies mutual exclusion even between Android isolates, unlike
/// process-scoped POSIX advisory file locks. No data is served on this socket.
class DriveSyncLease {
  final ServerSocket _socket;
  int get port => _socket.port;
  new _(this._socket) {
    _socket.listen((socket) => socket.destroy());
  }
  static Future<DriveSyncLease> acquire(int port) async => DriveSyncLease._(
    await ServerSocket.bind(InternetAddress.loopbackIPv4, port, shared: false),
  );
  Future<void> close() async {
    await _socket.close();
  }
}

Future<Directory> driveSettingsDirectory() async =>
    Directory('${(await getApplicationSupportDirectory()).path}/drive');

class DriveConnectionController extends ChangeNotifier {
  final NoteRepository Function() repository;
  final Future<void> Function(NoteRepository) onRepositoryChanged;
  final Future<void> Function() onRemoteUpdated;
  final Future<void> Function() onResumeReload;
  final Future<Directory> Function() directoryProvider;
  final DriveAuth Function(DriveConnectionSettings)? authFactory;
  final DriveRemoteStore Function(Future<String> Function()) remoteFactory;
  final DriveSecrets uploadSessionSecrets;
  final Future<void> Function() registerBackgroundWork;
  late Directory settingsDirectory;
  late DriveConnectionSettings settings;
  DriveAuth? auth;
  SyncCoordinator? coordinator;
  DriveRemoteStore? _remote;
  DriveSyncLease? _lease;
  ({Timer timer, bool resume})? _leaseRetry;
  StreamSubscription<SyncStatus>? _statuses;
  var status = const SyncStatus(SyncPhase.idle);
  String? error, recoveryBackupPath;
  var ready = false, busy = false, _closed = false, _foreground = true;
  var _backgroundRegistrationFailed = false;
  var _reloadingRepository = false;
  Future<void> _tail = Future.value();
  new({
    required this.repository,
    required this.onRepositoryChanged,
    required this.onRemoteUpdated,
    required this.onResumeReload,
    this.directoryProvider = driveSettingsDirectory,
    this.authFactory,
    this.uploadSessionSecrets = const OsDriveSecrets(),
    this.registerBackgroundWork = registerDriveBackgroundWork,
    DriveRemoteStore Function(Future<String> Function())? remoteFactory,
  }) : remoteFactory = remoteFactory ?? _defaultRemote;
  static DriveRemoteStore _defaultRemote(Future<String> Function() token) =>
      DriveRemoteStore(accessToken: token);
  bool get signedIn => auth?.accountId != null;
  bool get backgroundRegistrationFailed => _backgroundRegistrationFailed;
  bool get waitingForLease => _leaseRetry != null;
  bool get connected =>
      ready &&
      settings.folderId != null &&
      identical(coordinator?.repository, repository());
  Future<void> run(Future<void> Function() action, {bool Function()? when}) {
    final next = _tail.then((_) async {
      if (_closed || (when != null && !when())) return;
      busy = true;
      error = null;
      notifyListeners();
      try {
        await action();
      } catch (e) {
        error = e is OAuthFailure
            ? e.message
            : e is RemoteException
            ? e.message
            : 'Drive operation failed. Check configuration, connection, and local storage.';
      } finally {
        busy = false;
        if (!_closed) notifyListeners();
      }
    });
    _tail = next.catchError((Object _) {});
    return next;
  }

  Future<void> initialize() => run(() async {
    if (ready) return;
    settingsDirectory = await directoryProvider();
    settings = await DriveConnectionSettings.load(settingsDirectory);
    ready = true;
    final configured =
        authFactory != null ||
        (Platform.isAndroid
            ? settings.androidServerClientId.isNotEmpty
            : settings.desktopClientId.isNotEmpty);
    if (!configured) return;
    _makeAuth();
    if (settings.folderId != null && _foreground) {
      await auth!.restoreForSync();
      if (_canResumeRepository()) {
        settings.requireAccount(auth!.accountId);
        await _start();
      }
    } else {
      await auth!.restore();
    }
  });
  Future<void> recoverSettings() => run(() async {
    if (ready) return;
    final directory = await directoryProvider();
    await directory.create(recursive: true);
    await _stop();
    if (Platform.isAndroid) await cancelDriveBackgroundWork();
    final original = File('${directory.path}/connection.json');
    if (original.existsSync()) {
      final backup = await directory.createTemp('connection-backup-');
      final preserved = await original.rename('${backup.path}/connection.json');
      recoveryBackupPath = preserved.path;
    }
    final reset = DriveConnectionSettings();
    try {
      await reset.save(directory);
    } catch (_) {
      throw const OAuthFailure(
        '연결 설정 복구를 완료하지 못했습니다. 보관된 원본과 기기 자료는 유지됩니다. 저장 공간과 접근 권한을 확인한 뒤 다시 시도하세요.',
      );
    }
    settingsDirectory = directory;
    settings = reset;
    auth?.close();
    auth = null;
    status = const SyncStatus(
      SyncPhase.idle,
      message: '연결 설정을 복구했습니다. Google 로그인 후 기존 Drive vault를 다시 연결하세요.',
    );
    ready = true;
  });
  void _makeAuth() {
    auth?.close();
    auth =
        authFactory?.call(settings) ??
        DriveAuth.platform(
          androidServerClientId: settings.androidServerClientId,
          desktopClientId: settings.desktopClientId,
        );
  }

  Future<void> configure({
    required String androidServerClientId,
    required String desktopClientId,
    String? desktopSecret,
  }) => run(() async {
    final androidId = androidServerClientId.trim();
    final desktopId = desktopClientId.trim();
    final secret = desktopSecret?.trim() ?? '';
    final changed =
        settings.androidServerClientId != androidId ||
        settings.desktopClientId != desktopId;
    final replaceAuth = changed || auth == null;
    if (replaceAuth) {
      await _stop();
      if (changed) {
        await auth?.signOut();
        settings.clearConnection();
      }
      settings.androidServerClientId = androidId;
      settings.desktopClientId = desktopId;
      await settings.save(settingsDirectory);
      _makeAuth();
    }
    if (auth case final DesktopDriveAuth desktop when secret.isNotEmpty) {
      await desktop.setClientSecret(secret);
    }
    if (replaceAuth) await auth!.restore();
  });
  Future<void> signIn() => run(() async {
    if (auth == null) _makeAuth();
    await _stop();
    await auth!.signIn();
    settings.requireAccount(auth!.accountId);
    if (_canResumeRepository()) await _start(resume: true);
  });
  Future<List<DriveVault>> listVaults() async {
    settings.requireAccount(auth?.accountId);
    final remote = remoteFactory(auth!.accessToken);
    try {
      return await remote.listVaults();
    } finally {
      remote.close();
    }
  }

  Future<void> createCurrentVault() => run(() async {
    settings.requireAccount(auth?.accountId);
    await _stop();
    final repo = repository();
    final remote = remoteFactory(auth!.accessToken);
    try {
      if (settings.rootPath != repo.root.path ||
          settings.vaultId != repo.vaultId) {
        settings.intentFileId = null;
        settings.folderId = null;
      }
      settings.accountId = auth!.accountId;
      settings.rootPath = repo.root.path;
      settings.vaultId = repo.vaultId;
      settings.vaultFormatVersion = repo.formatVersion;
      settings.intentFileId ??= settings.folderId ?? await remote.generateId();
      await settings.save(settingsDirectory); // Durable before folder creation.
      final vault = await remote.createVault(
        vaultId: repo.vaultId,
        intentFileId: settings.intentFileId,
        formatVersion: repo.formatVersion,
      );
      settings.folderId = vault.id;
      await settings.save(settingsDirectory);
    } finally {
      remote.close();
    }
    await _start(resume: true);
  });
  Future<void> connectExisting(DriveVault selected) => run(() async {
    settings.requireAccount(auth?.accountId);
    await _stop();
    final remote = remoteFactory(auth!.accessToken);
    try {
      final vault = await remote.connectVault(selected.id);
      final support = await getApplicationSupportDirectory();
      final next = await NoteRepository.open(
        Directory('${support.path}/vaults/drive-${vault.vaultId}'),
        vaultId: vault.vaultId,
        createFormatVersion: vault.formatVersion,
      );
      if (next.formatVersion != vault.formatVersion) {
        await next.close();
        throw const FormatException('Local and Drive vault formats differ');
      }
      final previous = await DriveConnectionSettings.load(settingsDirectory);
      try {
        settings.accountId = auth!.accountId;
        settings.folderId = vault.id;
        settings.vaultId = vault.vaultId;
        settings.vaultFormatVersion = vault.formatVersion;
        settings.rootPath = next.root.path;
        settings.intentFileId = null;
        // Publish the connection before the workspace switches to this vault.
        await settings.save(settingsDirectory);
        await onRepositoryChanged(next);
      } catch (_) {
        settings = previous;
        await settings.save(settingsDirectory);
        await next.close();
        rethrow;
      }
    } finally {
      remote.close();
    }
    await _start(resume: true);
  });

  Future<bool> upgradeLegacyRepository(
    NoteRepository source,
    Directory destination,
  ) async {
    var upgraded = false;
    await run(() async {
      if (!ready) {
        throw const OAuthFailure('Drive 설정을 읽은 뒤 보관함 복사를 다시 시도해 주세요.');
      }
      _requireCurrentLegacyRepository(source);
      final bound = settings.folderId != null && _matchesRepository(source);
      final restartSync = bound && (coordinator != null || waitingForLease);
      final resumeSync = _leaseRetry?.resume ?? false;
      NoteRepository? next;
      try {
        var latest = source;
        if (bound) {
          await _stop(keepLease: true);
          await _acquireLease();
          _requireCurrentLegacyRepository(source);
          await _reloadRepository();
          latest = repository();
          _requireMatchingRepository(latest);
        }
        if (latest.pendingRevisionCount != 0 ||
            latest.integrityIssues.isNotEmpty) {
          throw const OAuthFailure(
            '아직 내려받지 못했거나 확인이 필요한 자료가 있습니다. 동기화 또는 보관함 확인을 마친 뒤 다시 복사해 주세요.',
          );
        }
        next = await BackupService.cloneToEmpty(
          latest,
          destination,
          targetFormatVersion: 2,
        );
        _requireCurrentLegacyRepository(latest);
        await onRepositoryChanged(next);
        upgraded = true;
      } finally {
        if (next != null && !identical(repository(), next)) await next.close();
        if (bound) {
          status = const SyncStatus(SyncPhase.idle);
          if (!upgraded && restartSync && _canResumeRepository()) {
            try {
              await _start(resume: resumeSync);
            } catch (_) {
              // Keep the copy failure available to the caller.
              await _stop();
            }
          } else {
            await _stop();
          }
        }
      }
    });
    return upgraded;
  }

  void _requireCurrentLegacyRepository(NoteRepository source) {
    if (_closed ||
        !identical(repository(), source) ||
        source.formatVersion != 1) {
      throw const OAuthFailure('보관함이 바뀌었습니다. 현재 보관함에서 다시 시도해 주세요.');
    }
  }

  Future<void> _acquireLease() async {
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (!await _tryAcquireLease()) {
      if (DateTime.now().isAfter(deadline))
        throw const OAuthFailure(
          'Another sync task is still active. Retry shortly.',
        );
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
  }

  Future<bool> _tryAcquireLease() async {
    if (_lease != null) return true;
    final port = settings.leasePort;
    final DriveSyncLease lease;
    try {
      lease = await DriveSyncLease.acquire(port);
    } on SocketException catch (error) {
      final code = error.osError?.errorCode;
      // Windows Dart can omit the native address-in-use error code.
      if (port != 0 &&
          (const {48, 98, 10048}.contains(code) ||
              Platform.isWindows && code == -1)) {
        return false;
      }
      rethrow;
    }
    if (port == 0) {
      settings.leasePort = lease.port;
      try {
        await settings.save(settingsDirectory);
      } catch (_) {
        settings.leasePort = 0;
        await lease.close();
        rethrow;
      }
    }
    _lease = lease;
    return true;
  }

  void _cancelLeaseRetry() {
    _leaseRetry?.timer.cancel();
    _leaseRetry = null;
  }

  void _scheduleLeaseRetry({required bool resume}) {
    late final Timer timer;
    timer = Timer(const Duration(seconds: 1), () {
      unawaited(
        run(() async {
          if (coordinator == null && _canResumeRepository()) {
            await _start();
          } else {
            _cancelLeaseRetry();
          }
        }, when: () => identical(_leaseRetry?.timer, timer)),
      );
    });
    _leaseRetry = (timer: timer, resume: resume);
  }

  bool _matchesRepository(NoteRepository repo) =>
      repo.root.path == settings.rootPath &&
      repo.vaultId == settings.vaultId &&
      repo.formatVersion == (settings.vaultFormatVersion ?? 1);

  void _requireMatchingRepository(NoteRepository repo) {
    if (!_matchesRepository(repo)) {
      throw const OAuthFailure(
        'This local vault differs from the Drive connection. Select an existing Drive vault or disconnect before connecting this vault.',
      );
    }
  }

  Future<void> _reloadRepository() async {
    _reloadingRepository = true;
    try {
      await onResumeReload();
    } finally {
      _reloadingRepository = false;
    }
  }

  Future<void> _start({bool resume = false}) async {
    resume = resume || (_leaseRetry?.resume ?? false);
    _cancelLeaseRetry();
    if (!_foreground || _closed || settings.folderId == null) return;
    final accountId = auth?.accountId;
    settings.requireAccount(accountId);
    _requireMatchingRepository(repository());
    if (!await _tryAcquireLease()) {
      if (!_closed) _scheduleLeaseRetry(resume: resume);
      return;
    }
    if (_closed) {
      await _stop();
      return;
    }
    try {
      await _reloadRepository();
      final repo = repository();
      _requireMatchingRepository(repo);
      _remote = remoteFactory(auth!.accessToken);
      // Previously validated binding starts offline; transport retry/backoff
      // handles temporary network loss without requiring a settings dialog.
      final vault = DriveVault(
        id: settings.folderId!,
        vaultId: settings.vaultId!,
        name: 'Personal Ink Vault',
        formatVersion: settings.vaultFormatVersion ?? 1,
      );
      coordinator = SyncCoordinator(
        repository: repo,
        remote: _remote!.bind(
          vault,
          uploadSessions: SecureDriveUploadSessions(
            accountId: accountId!,
            folderId: vault.id,
            deviceId: repo.deviceId,
            secrets: uploadSessionSecrets,
          ),
        ),
        stateDirectory: Directory(
          '${settingsDirectory.path}/state/${vault.id}',
        ),
      );
      _statuses = coordinator!.statuses.listen((next) {
        status = next;
        if (!_closed) notifyListeners();
        if (identical(repository(), repo) &&
            (next.phase == SyncPhase.synced ||
                next.phase == SyncPhase.conflict)) {
          unawaited(onRemoteUpdated().catchError((Object _) {}));
        }
      });
      if (resume) coordinator!.resume();
      coordinator!.start();
    } catch (_) {
      await _stop();
      rethrow;
    }
    await _registerBackgroundWork();
  }

  Future<void> _registerBackgroundWork() async {
    try {
      await registerBackgroundWork();
      _backgroundRegistrationFailed = false;
    } catch (_) {
      _backgroundRegistrationFailed = true;
    }
  }

  Future<void> _stop({bool keepLease = false}) async {
    _cancelLeaseRetry();
    try {
      await coordinator?.close();
    } finally {
      coordinator = null;
      try {
        await _statuses?.cancel();
      } finally {
        _statuses = null;
        _remote?.close();
        _remote = null;
        if (!keepLease) {
          await _lease?.close();
          _lease = null;
        }
      }
    }
  }

  Future<void> retry() => run(() async {
    if (coordinator != null) {
      if (status.phase == SyncPhase.authenticationRequired)
        await auth?.invalidateToken();
      coordinator!.resume();
      await coordinator!.syncOnce(force: true);
      if (_backgroundRegistrationFailed) await _registerBackgroundWork();
    } else {
      if (settings.folderId != null && !_matchesRepository(repository())) {
        throw const OAuthFailure(
          '현재 보관함을 동기화하려면 ‘현재 로컬 vault를 Drive에 만들기’를 선택해 주세요.',
        );
      }
      await auth?.restore();
      await _start(resume: true);
    }
  });
  bool _canResumeRepository() =>
      _foreground &&
      ready &&
      auth != null &&
      settings.folderId != null &&
      _matchesRepository(repository());

  Future<void> repositoryChanged() {
    // _start binds the repository it just reloaded. Its own change must not
    // queue another start if that binding fails.
    if (_reloadingRepository) return Future.value();
    return run(
      () async {
        if (coordinator != null) {
          await _stop();
          status = const SyncStatus(SyncPhase.idle);
        }
        if (_canResumeRepository()) {
          await auth!.restoreForSync();
          await _start();
        } else {
          _cancelLeaseRetry();
        }
      },
      when: () {
        final sync = coordinator;
        return sync == null
            ? waitingForLease || _canResumeRepository()
            : !identical(sync.repository, repository());
      },
    );
  }

  Future<void> setForeground(bool foreground) => run(() async {
    _foreground = foreground;
    if (!ready) return;
    if (foreground) {
      if (coordinator == null && _canResumeRepository()) {
        await auth!.restoreForSync();
        await _start();
      }
    } else {
      await _stop();
      if (Platform.isAndroid && settings.folderId != null)
        await scheduleDriveBackgroundSync();
    }
  });
  Future<void> signOut() => run(() async {
    await _stop();
    final accountId = settings.accountId ?? auth?.accountId;
    final folderId = settings.folderId;
    final rootPath = settings.rootPath;
    final vaultId = settings.vaultId;
    settings.clearConnection();
    await settings.save(settingsDirectory);
    if (Platform.isAndroid) await cancelDriveBackgroundWork();
    if (accountId != null && folderId != null) {
      try {
        final repo = repository();
        if (repo.root.path == rootPath && repo.vaultId == vaultId) {
          final lease = settings.leasePort == 0
              ? null
              : await DriveSyncLease.acquire(settings.leasePort);
          try {
            await SecureDriveUploadSessions(
              accountId: accountId,
              folderId: folderId,
              deviceId: repo.deviceId,
              secrets: uploadSessionSecrets,
            ).clear();
          } finally {
            await lease?.close();
          }
        }
      } catch (_) {
        // A busy lease or secure storage failure must not prevent disconnect.
      }
    }
    await auth?.signOut();
    status = const SyncStatus(SyncPhase.idle);
  });
  Future<void> cancelSignIn() async => auth?.cancel();
  Future<void> close() async {
    _closed = true;
    _cancelLeaseRetry();
    await auth?.cancel();
    await _tail;
    await _stop();
    auth?.close();
    super.dispose();
  }
}
