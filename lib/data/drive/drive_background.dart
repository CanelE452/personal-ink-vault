import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:ink_vault_core/drive.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/drive/drive_auth.dart';
import 'package:saber/data/drive/drive_connection.dart';
import 'package:saber/data/drive/oauth_flow.dart';
import 'package:saber/data/native/ink_vault_native.dart';
import 'package:saber/data/vault/database_actions.dart';
import 'package:saber/data/vault/database_automation_coordinator.dart';
import 'package:saber/pages/workspace/workspace_controller.dart';
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

Future<void> _initialize() async {
  final attempt = _initialization ??= Workmanager().initialize(
    driveCallbackDispatcher,
  );
  try {
    await attempt;
  } catch (_) {
    if (identical(_initialization, attempt)) _initialization = null;
    rethrow;
  }
}

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
  DriveRemoteStore Function(Future<String> Function())? remoteFactory,
  DriveSecrets uploadSessionSecrets = const OsDriveSecrets(),
  DatabaseActionRuntime? Function(NoteRepository)? actionRuntimeFactory,
}) async {
  NoteRepository? repository;
  SyncCoordinator? coordinator;
  DriveRemoteStore? remote;
  DriveAuth? auth;
  DriveSyncLease? lease;
  Directory? settingsDirectory;
  WorkspaceController? automationWorkspace;
  DatabaseAutomationCoordinator? automations;
  final automationResults = <String, Object?>{};
  final captured = DateTime.now().toUtc().millisecondsSinceEpoch;

  Future<void> writeDiagnostics(String name, Map<String, Object?> data) async {
    final folder = settingsDirectory;
    if (folder == null) return;
    final target = File('${folder.path}/$name');
    final pending = File('${target.path}.${newId()}.pending');
    try {
      await pending.writeAsString(jsonEncode(data), flush: true);
      await pending.rename(target.path);
    } catch (_) {
      // Diagnostics must not change the outcome of a Drive task.
    } finally {
      try {
        if (pending.existsSync()) await pending.delete();
      } on FileSystemException {
        // The task outcome also takes precedence over diagnostic cleanup.
      }
    }
  }

  Future<DatabaseAutomationPass?> runAutomations(String stage) async {
    DatabaseAutomationPass? result;
    try {
      result = await automations?.runOnce(capturedAtUtcMs: captured);
      automationResults[stage] = result == null
          ? {'status': 'unavailable'}
          : {
              ...result.toJson(),
              'outcomeCount': result.outcomes.length,
              'outcomes': result.outcomes
                  .take(16)
                  .map((item) => item.toJson())
                  .toList(),
            };
    } catch (_) {
      automationResults[stage] = {
        'status': 'error',
        'code': 'automation_error',
      };
    }
    await writeDiagnostics('automation-background-status.json', {
      'capturedAtUtcMs': captured,
      ...automationResults,
    });
    return result;
  }

  Future<void> status(String phase) =>
      writeDiagnostics('background-status.json', {
        'phase': phase,
        'at': DateTime.now().toUtc().toIso8601String(),
      });

  try {
    settingsDirectory = directory ?? await driveSettingsDirectory();
    final leasePort = (await DriveConnectionSettings.load(settingsDirectory))
        .leasePort;
    if (leasePort == 0) return true;
    try {
      lease = await DriveSyncLease.acquire(leasePort);
    } on SocketException {
      return true;
    } // Foreground owns the current repository.
    // A pending worker may have read its lease before the user disconnected.
    final settings = await DriveConnectionSettings.load(settingsDirectory);
    if (settings.accountId == null ||
        settings.folderId == null ||
        settings.rootPath == null ||
        settings.vaultId == null ||
        settings.leasePort != leasePort)
      return true;
    if (!File('${settings.rootPath}/vault.json').existsSync())
      throw const FormatException('The selected vault is missing');
    repository = await NoteRepository.open(
      Directory(settings.rootPath!),
      vaultId: settings.vaultId,
    );
    if (repository.formatVersion != (settings.vaultFormatVersion ?? 1))
      throw const FormatException('Vault format mismatch');
    if (repository.formatVersion >= 2) {
      try {
        final core = actionRuntimeFactory == null
            ? InkVaultNative.open()
            : null;
        final runtime =
            actionRuntimeFactory?.call(repository) ??
            (core == null
                ? null
                : DatabaseActionRuntime(
                    deviceId: repository.deviceId,
                    invoke: core.invoke,
                  ));
        if (runtime != null) {
          automationWorkspace = WorkspaceController(repository, native: core);
          automations = automationWorkspace.createAutomationCoordinator(
            actionRuntime: runtime,
          );
        }
      } catch (_) {
        automationResults['initialization'] = {'status': 'unavailable'};
      }
      await runAutomations('before');
    }
    final selected = DriveVault(
      id: settings.folderId!,
      vaultId: repository.vaultId,
      name: 'Personal Ink Vault',
      formatVersion: repository.formatVersion,
    );
    final stateDirectory = Directory(
      '${settingsDirectory.path}/state/${selected.id}',
    );
    final hold = await SyncCoordinator.readPersistedHold(
      stateDirectory: stateDirectory,
      vaultId: selected.vaultId,
      remoteId: selected.id,
    );
    if (hold != null) {
      await runAutomations('after');
      await status(hold.name);
      return hold != SyncPhase.retryWaiting;
    }
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
    remote =
        remoteFactory?.call(auth.accessToken) ??
        DriveRemoteStore(accessToken: auth.accessToken);
    coordinator = SyncCoordinator(
      repository: repository,
      remote: remote.bind(
        selected,
        uploadSessions: SecureDriveUploadSessions(
          accountId: settings.accountId!,
          folderId: selected.id,
          deviceId: repository.deviceId,
          secrets: uploadSessionSecrets,
        ),
      ),
      stateDirectory: stateDirectory,
    );
    final DriveVault vault;
    try {
      vault = await remote.connectVault(selected.id);
    } on RemoteException catch (failure) {
      if (failure.failure != RemoteFailure.retryable) rethrow;
      await coordinator.recordPreflightRetry(failure);
      await status(SyncPhase.retryWaiting.name);
      return false;
    }
    if (vault.id != selected.id ||
        vault.vaultId != selected.vaultId ||
        vault.formatVersion != selected.formatVersion)
      throw const FormatException('Vault identity mismatch');
    await coordinator.syncOnce();
    final after = await runAutomations('after');
    if ((after?.committedNotes ?? 0) > 0 &&
        coordinator.status.phase != SyncPhase.retryWaiting)
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
      automations?.dispose();
      automationWorkspace?.dispose();
      try {
        await repository?.close();
      } finally {
        auth?.close();
        await lease?.close();
      }
    }
  }
}
