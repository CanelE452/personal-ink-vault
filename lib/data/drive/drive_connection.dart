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
  late Directory settingsDirectory;
  late DriveConnectionSettings settings;
  DriveAuth? auth;
  SyncCoordinator? coordinator;
  DriveRemoteStore? _remote;
  DriveSyncLease? _lease;
  StreamSubscription<SyncStatus>? _statuses;
  var status = const SyncStatus(SyncPhase.idle);
  String? error, recoveryBackupPath;
  var ready = false, busy = false, _closed = false, _foreground = true;
  Future<void> _tail = Future.value();
  new({
    required this.repository,
    required this.onRepositoryChanged,
    required this.onRemoteUpdated,
    required this.onResumeReload,
    this.directoryProvider = driveSettingsDirectory,
    this.authFactory,
    DriveRemoteStore Function(Future<String> Function())? remoteFactory,
  }) : remoteFactory = remoteFactory ?? _defaultRemote;
  static DriveRemoteStore _defaultRemote(Future<String> Function() token) =>
      DriveRemoteStore(accessToken: token);
  bool get signedIn => auth?.accountId != null;
  bool get connected =>
      ready && settings.folderId != null && coordinator != null;
  Future<void> run(Future<void> Function() action) {
    final next = _tail.then((_) async {
      if (_closed) return;
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
    await auth!.restore();
    if (settings.folderId != null) {
      settings.requireAccount(auth!.accountId);
      await _start();
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
    await _stop();
    final changed =
        settings.androidServerClientId != androidServerClientId.trim() ||
        settings.desktopClientId != desktopClientId.trim();
    if (changed) {
      await auth?.signOut();
      settings.clearConnection();
    }
    settings.androidServerClientId = androidServerClientId.trim();
    settings.desktopClientId = desktopClientId.trim();
    await settings.save(settingsDirectory);
    _makeAuth();
    if (auth case final DesktopDriveAuth desktop) {
      if (desktopSecret != null)
        await desktop.setClientSecret(desktopSecret.trim());
    }
    await auth!.restore();
  });
  Future<void> signIn() => run(() async {
    if (auth == null) _makeAuth();
    await _stop();
    await auth!.signIn();
    settings.requireAccount(auth!.accountId);
    if (settings.folderId != null) await _start();
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
      settings.intentFileId ??= settings.folderId ?? await remote.generateId();
      await settings.save(settingsDirectory); // Durable before folder creation.
      final vault = await remote.createVault(
        vaultId: repo.vaultId,
        intentFileId: settings.intentFileId,
      );
      settings.folderId = vault.id;
      await settings.save(settingsDirectory);
    } finally {
      remote.close();
    }
    await _start();
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
      );
      final previous = await DriveConnectionSettings.load(settingsDirectory);
      try {
        settings.accountId = auth!.accountId;
        settings.folderId = vault.id;
        settings.vaultId = vault.vaultId;
        settings.rootPath = next.root.path;
        settings.intentFileId = null;
        // A keyed panel may be recreated as soon as this callback switches root.
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
    await _start();
  });
  Future<void> _acquireLease() async {
    if (_lease != null) return;
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (true) {
      try {
        _lease = await DriveSyncLease.acquire(settings.leasePort);
        if (settings.leasePort == 0) {
          settings.leasePort = _lease!.port;
          await settings.save(settingsDirectory);
        }
        return;
      } on SocketException {
        if (DateTime.now().isAfter(deadline))
          throw const OAuthFailure(
            'Another sync task is still active. Retry shortly.',
          );
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }
  }

  Future<void> _start() async {
    if (!_foreground || _closed || settings.folderId == null) return;
    settings.requireAccount(auth?.accountId);
    if (repository().root.path != settings.rootPath ||
        repository().vaultId != settings.vaultId) {
      throw const OAuthFailure(
        'This local vault differs from the Drive connection. Select an existing Drive vault or disconnect before connecting this vault.',
      );
    }
    await _acquireLease();
    try {
      await onResumeReload();
      _remote = remoteFactory(auth!.accessToken);
      // Previously validated binding starts offline; transport retry/backoff
      // handles temporary network loss without requiring a settings dialog.
      final vault = DriveVault(
        id: settings.folderId!,
        vaultId: settings.vaultId!,
        name: 'Personal Ink Vault',
      );
      if (vault.vaultId != repository().vaultId)
        throw const FormatException('Vault identity mismatch');
      coordinator = SyncCoordinator(
        repository: repository(),
        remote: _remote!.bind(vault),
        stateDirectory: Directory(
          '${settingsDirectory.path}/state/${vault.id}',
        ),
      );
      _statuses = coordinator!.statuses.listen((next) {
        status = next;
        if (!_closed) notifyListeners();
        if (next.phase == SyncPhase.synced ||
            next.phase == SyncPhase.conflict) {
          unawaited(onRemoteUpdated().catchError((Object _) {}));
        }
      });
      coordinator!.resume();
      coordinator!.start();
      if (Platform.isAndroid) await registerDriveBackgroundWork();
    } catch (_) {
      await _stop();
      rethrow;
    }
  }

  Future<void> _stop() async {
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
        await _lease?.close();
        _lease = null;
      }
    }
  }

  Future<void> retry() => run(() async {
    if (coordinator != null) {
      if (status.phase == SyncPhase.authenticationRequired)
        await auth?.invalidateToken();
      coordinator!.resume();
      await coordinator!.syncOnce(force: true);
    } else {
      await auth?.restore();
      await _start();
    }
  });
  Future<void> setForeground(bool foreground) => run(() async {
    _foreground = foreground;
    if (!ready) return;
    if (foreground) {
      if (settings.folderId != null && coordinator == null) {
        await auth?.restore();
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
    settings.clearConnection();
    await settings.save(settingsDirectory);
    if (Platform.isAndroid) await cancelDriveBackgroundWork();
    await auth?.signOut();
    status = const SyncStatus(SyncPhase.idle);
  });
  Future<void> cancelSignIn() async => auth?.cancel();
  Future<void> close() async {
    _closed = true;
    await auth?.cancel();
    await _tail;
    await _stop();
    auth?.close();
    super.dispose();
  }
}
