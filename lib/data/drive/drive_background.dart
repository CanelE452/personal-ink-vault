import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:ink_vault_core/drive.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/drive/drive_auth.dart';
import 'package:saber/data/drive/drive_connection.dart';
import 'package:saber/data/drive/oauth_flow.dart';
import 'package:workmanager/workmanager.dart';

const _periodicName = 'ink-vault-drive-periodic';
const _oneOffName = 'ink-vault-drive-pending';
const _task = 'ink-vault-drive-sync';
Future<void>? _initialization;

@pragma('vm:entry-point')
void driveCallbackDispatcher() {
  WidgetsFlutterBinding.ensureInitialized();
  Workmanager().executeTask((task, input) async {
    if (task != _task) return true;
    return runDriveBackgroundSync();
  });
}

Future<void> _initialize() =>
    _initialization ??= Workmanager().initialize(driveCallbackDispatcher);

Future<void> registerDriveBackgroundWork() async {
  if (!Platform.isAndroid) return;
  await _initialize();
  await Workmanager().registerPeriodicTask(
    _periodicName,
    _task,
    frequency: const Duration(minutes: 15),
    constraints: Constraints(networkType: NetworkType.connected),
    existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
  );
}

Future<void> scheduleDriveBackgroundSync() async {
  if (!Platform.isAndroid) return;
  await _initialize();
  await Workmanager().registerOneOffTask(
    _oneOffName,
    _task,
    constraints: Constraints(networkType: NetworkType.connected),
    existingWorkPolicy: ExistingWorkPolicy.keep,
    backoffPolicy: BackoffPolicy.exponential,
    backoffPolicyDelay: const Duration(seconds: 30),
  );
}

Future<void> cancelDriveBackgroundWork() async {
  if (!Platform.isAndroid) return;
  await _initialize();
  await Workmanager().cancelByUniqueName(_periodicName);
  await Workmanager().cancelByUniqueName(_oneOffName);
}

/// Runs with its own repository and noninteractive authorization only. The local
/// sync lease excludes the foreground coordinator and other background engines.
Future<bool> runDriveBackgroundSync({
  Directory? directory,
  DriveAuth Function(DriveConnectionSettings)? authFactory,
}) async {
  NoteRepository? repository;
  SyncCoordinator? coordinator;
  DriveRemoteStore? remote;
  DriveAuth? auth;
  DriveSyncLease? lease;
  Directory? settingsDirectory;
  Future<void> status(String phase) async {
    if (settingsDirectory == null) return;
    await File('${settingsDirectory.path}/background-status.json')
        .writeAsString(
          jsonEncode({
            'phase': phase,
            'at': DateTime.now().toUtc().toIso8601String(),
          }),
          flush: true,
        );
  }

  try {
    settingsDirectory = directory ?? await driveSettingsDirectory();
    final settings = await DriveConnectionSettings.load(settingsDirectory);
    if (settings.accountId == null ||
        settings.folderId == null ||
        settings.rootPath == null ||
        settings.vaultId == null ||
        settings.leasePort == 0)
      return true;
    try {
      lease = await DriveSyncLease.acquire(settings.leasePort);
    } on SocketException {
      return true;
    } // Foreground owns the current repository.
    auth =
        authFactory?.call(settings) ??
        DriveAuth.platform(
          androidServerClientId: settings.androidServerClientId,
          desktopClientId: settings.desktopClientId,
        );
    await auth.restore();
    settings.requireAccount(auth.accountId);
    // Deliberately never calls signIn/authorizeScopes or shows foreground UI.
    await auth.accessToken();
    repository = await NoteRepository.open(
      Directory(settings.rootPath!),
      vaultId: settings.vaultId,
    );
    remote = DriveRemoteStore(accessToken: auth.accessToken);
    final vault = await remote.connectVault(settings.folderId!);
    if (vault.vaultId != repository.vaultId)
      throw const FormatException('Vault identity mismatch');
    coordinator = SyncCoordinator(
      repository: repository,
      remote: remote.bind(vault),
      stateDirectory: Directory('${settingsDirectory.path}/state/${vault.id}'),
    );
    await coordinator.syncOnce();
    await status(coordinator.status.phase.name);
    return coordinator.status.phase != SyncPhase.retryWaiting;
  } on OAuthFailure {
    await status('authenticationRequired');
    return true; // A user must reconnect; do not loop on missing consent.
  } on RemoteException catch (e) {
    await status(
      e.failure == RemoteFailure.authentication
          ? 'authenticationRequired'
          : 'error',
    );
    return e.failure != RemoteFailure.retryable;
  } catch (_) {
    await status('error');
    return false;
  } finally {
    try {
      await coordinator?.close();
    } finally {
      remote?.close();
      try {
        await repository?.close();
      } finally {
        auth?.close();
        await lease?.close();
      }
    }
  }
}
