import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:ink_vault_core/drive.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:saber/components/drive/drive_panel.dart';
import 'package:saber/data/app_external_screen.dart';
import 'package:saber/data/drive/drive_auth.dart';
import 'package:saber/data/drive/drive_background.dart';
import 'package:saber/data/drive/drive_connection.dart';
import 'package:saber/data/file_manager/file_manager.dart';
import 'package:saber/data/flavor_config.dart';
import 'package:saber/data/vault/workspace_store.dart';
import 'package:saber/i18n/strings.g.dart';
import 'package:saber/pages/workspace/study_workspace.dart';

import '../utils/test_mock_channel_handlers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlavorConfig.setup();
  setupMockPathProvider();
  setupMockPrinting();
  setupMockWindowManager();

  late Directory directory;
  late _GatedWorkspaceController workspace;
  late VaultNote note;
  late _FixtureRemote remote;
  late Directory settingsDirectory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('drive-workspace-');
    await FileManager.init(
      documentsDirectory: '${directory.path}/documents',
      shouldWatchRootDirectory: false,
    );
    final repository = await NoteRepository.open(
      Directory('${directory.path}/vault'),
      createFormatVersion: 2,
    );
    workspace = _GatedWorkspaceController(repository);
    note = await workspace.store.create(
      'Drive lifecycle note',
      documentKind: VaultDocumentKind.markdown,
    );
    await workspace.refresh();
    remote = _FixtureRemote(repository.vaultId);
    settingsDirectory = Directory('${directory.path}/drive');
    await (DriveConnectionSettings()
          ..accountId = _FixtureAuth.fixtureAccount
          ..folderId = remote.remoteId
          ..rootPath = repository.root.path
          ..vaultId = repository.vaultId
          ..vaultFormatVersion = repository.formatVersion)
        .save(settingsDirectory);
  });

  tearDown(() async {
    await workspace.repository.close();
    final root = await Directory.systemTemp.resolveSymbolicLinks();
    final owned = await directory.resolveSymbolicLinks();
    expect(owned, startsWith('$root${Platform.pathSeparator}drive-workspace-'));
    await Directory(owned).delete(recursive: true);
  });

  test(
    'foreground startup retries a held background lease automatically',
    () async {
      final holder = await DriveSyncLease.acquire(0);
      final settings = await DriveConnectionSettings.load(settingsDirectory);
      settings.leasePort = holder.port;
      await settings.save(settingsDirectory);
      final auth = _FixtureAuth();
      var reloads = 0;
      final connection = DriveConnectionController(
        repository: () => workspace.repository,
        onRepositoryChanged: (_) async => fail('Unexpected vault switch'),
        onRemoteUpdated: () async {},
        onResumeReload: () async => reloads++,
        directoryProvider: () async => settingsDirectory,
        authFactory: (_) => auth,
        remoteFactory: (token) => _FixtureTransport(remote, token),
      );
      addTearDown(connection.close);
      final started = Completer<void>();
      connection.addListener(() {
        if (connection.connected && !started.isCompleted) started.complete();
      });
      final starting = connection.initialize();
      try {
        await starting.timeout(const Duration(milliseconds: 500));
        expect(connection.connected, isFalse);
        expect(connection.waitingForLease, isTrue);
        expect(connection.error, isNull);
        expect(reloads, 0);
      } finally {
        await holder.close();
        await starting;
      }
      await started.future.timeout(const Duration(seconds: 3));
      expect(connection.waitingForLease, isFalse);
      expect(reloads, 1);
      expect(auth.signInCalls, 0);
      expect(connection.settings.accountId, _FixtureAuth.fixtureAccount);
      expect(connection.settings.folderId, remote.remoteId);
    },
  );

  for (final (reason, stop)
      in <(String, Future<void> Function(DriveConnectionController))>[
        ('pausing', (connection) => connection.setForeground(false)),
        ('disconnecting', (connection) => connection.signOut()),
        ('closing', (connection) => connection.close()),
      ]) {
    test('$reason cancels a foreground lease retry', () async {
      final holder = await DriveSyncLease.acquire(0);
      final settings = await DriveConnectionSettings.load(settingsDirectory);
      settings.leasePort = holder.port;
      await settings.save(settingsDirectory);
      var closed = false;
      var reloads = 0;
      final connection = DriveConnectionController(
        repository: () => workspace.repository,
        onRepositoryChanged: (_) async => fail('Unexpected vault switch'),
        onRemoteUpdated: () async => fail('Unexpected Drive sync'),
        onResumeReload: () async => reloads++,
        directoryProvider: () async => settingsDirectory,
        authFactory: (_) => _FixtureAuth(allowSignOut: true),
        remoteFactory: (_) => fail('Unexpected Drive transport'),
      );
      addTearDown(() async {
        if (!closed) await connection.close();
      });
      try {
        await connection.initialize();
        expect(connection.waitingForLease, isTrue);
        await stop(connection);
        closed = reason == 'closing';
        expect(connection.waitingForLease, isFalse);
      } finally {
        await holder.close();
      }
      await Future<void>.delayed(const Duration(milliseconds: 1250));
      expect(reloads, 0);
      expect(connection.connected, isFalse);
      expect(connection.error, isNull);
    });
  }

  test(
    'starting a local copy leaves the previous Drive binding idle',
    () async {
      final local = await NoteRepository.open(
        Directory('${directory.path}/local-copy'),
        createFormatVersion: 2,
      );
      final auth = _FixtureAuth(allowSignIn: true);
      final connection = DriveConnectionController(
        repository: () => local,
        onRepositoryChanged: (_) async => fail('Unexpected vault switch'),
        onRemoteUpdated: () async => fail('Unexpected Drive sync'),
        onResumeReload: () async => fail('Unexpected reload of the copy'),
        directoryProvider: () async => settingsDirectory,
        authFactory: (_) => auth,
        remoteFactory: (_) => fail('Unexpected Drive transport'),
      );
      addTearDown(local.close);
      addTearDown(connection.close);

      await connection.initialize();

      expect(connection.ready, isTrue);
      expect(connection.signedIn, isTrue);
      expect(connection.connected, isFalse);
      expect(connection.error, isNull);
      expect(connection.settings.rootPath, workspace.repository.root.path);

      await connection.signIn();
      expect(auth.signInCalls, 1);
      expect(connection.connected, isFalse);
      expect(connection.error, isNull);
      await connection.retry();
      expect(connection.error, contains('현재 로컬 vault를 Drive에 만들기'));
    },
  );

  for (final (name, useOpenVault, selectionFails, refreshFails) in [
    ('Open vault', true, false, false),
    ('Previously bound vault', false, false, false),
    ('Vault whose first refresh fails', false, false, true),
    ('Vault whose first selection fails', false, true, false),
  ]) {
    test('$name keeps offline edits on reconnect', () async {
      final imported = workspace.repository;
      final markdown = await workspace.store.open(note);
      await markdown.saveMarkdown('Offline edit with [[Local reference]]');
      final offlineHead = (await imported.heads(note.markdownEntityId)).single;
      final support = Directory('${directory.path}/support');
      final previousPaths = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _FixturePaths(support.path);
      addTearDown(() => PathProviderPlatform.instance = previousPaths);

      final duplicate = await NoteRepository.open(
        Directory('${support.path}/vaults/drive-${imported.vaultId}'),
        vaultId: imported.vaultId,
        createFormatVersion: 2,
      );
      final settings = await DriveConnectionSettings.load(settingsDirectory);
      if (useOpenVault) {
        settings.rootPath = duplicate.root.path;
        await settings.save(settingsDirectory);
      }
      await duplicate.close();

      var current = useOpenVault
          ? imported
          : await NoteRepository.open(
              Directory('${support.path}/vaults/another'),
              createFormatVersion: 2,
            );
      var switches = 0;
      final connection = DriveConnectionController(
        repository: () => current,
        onRepositoryChanged: (next) async {
          switches++;
          final duringSwitch = await DriveConnectionSettings.load(
            settingsDirectory,
          );
          await expectLater(
            DriveSyncLease.acquire(duringSwitch.leasePort)
                .then((lease) => lease.close()),
            throwsA(isA<SocketException>()),
          );
          if (selectionFails && switches == 1) {
            throw StateError('Selection failed before adoption');
          }
          final old = current;
          current = next;
          if (!identical(old, imported)) await old.close();
          if (refreshFails) throw StateError('Refresh failed after selection');
        },
        onRemoteUpdated: () async {},
        onResumeReload: () => current.reloadFromDisk(),
        directoryProvider: () async => settingsDirectory,
        authFactory: (_) => _FixtureAuth(),
        remoteFactory: (token) => _FixtureTransport(remote, token),
        registerBackgroundWork: () async {},
      );
      addTearDown(() async {
        await connection.close();
        if (!identical(current, imported)) await current.close();
      });

      await connection.initialize();
      expect(connection.connected, isFalse);
      final selected = DriveVault(
        id: remote.remoteId,
        vaultId: imported.vaultId,
        name: 'Synthetic Drive',
        formatVersion: 2,
      );
      await connection.connectExisting(selected);
      if (selectionFails) {
        expect(connection.error, isNotNull);
        expect(current.vaultId, isNot(imported.vaultId));
        expect(
          (await DriveConnectionSettings.load(settingsDirectory)).rootPath,
          imported.root.path,
        );
        await connection.connectExisting(selected);
      } else if (refreshFails) {
        expect(connection.error, isNotNull);
        expect(
          (await current.heads(note.markdownEntityId)).single.revisionId,
          offlineHead.revisionId,
        );
        await connection.repositoryChanged();
      }
      expect(connection.error, isNull);
      expect(connection.connected, isTrue);
      expect(current.root.path, imported.root.path);
      expect(current.deviceId, imported.deviceId);
      expect(switches, useOpenVault ? 0 : (selectionFails ? 2 : 1));
      expect(
        (await DriveConnectionSettings.load(settingsDirectory)).rootPath,
        imported.root.path,
      );
      await connection.retry();
      expect(
        remote.records.values.map((r) => r.revisionId),
        contains(offlineHead.revisionId),
      );

      final otherDevice = await NoteRepository.open(
        Directory('${directory.path}/second-device'),
        vaultId: imported.vaultId,
        createFormatVersion: 2,
      );
      final otherSync = SyncCoordinator(
        repository: otherDevice,
        remote: remote,
        stateDirectory: Directory('${directory.path}/second-device-state'),
      );
      addTearDown(() async {
        await otherSync.close();
        await otherDevice.close();
      });
      await otherSync.syncOnce();
      expect(otherSync.status.phase, SyncPhase.synced);
      final otherStore = WorkspaceStore(otherDevice);
      final received = (await otherStore.list()).single;
      expect(received.id, note.id);
      expect(
        await (await otherStore.open(received)).readMarkdown(),
        'Offline edit with [[Local reference]]',
      );
    });
  }

  test('Drive reopens a uniquely matching Obsidian import', () async {
    final support = Directory('${directory.path}/support');
    final previousPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _FixturePaths(support.path);
    addTearDown(() => PathProviderPlatform.instance = previousPaths);
    final imported = await NoteRepository.open(
      Directory(p.join(support.path, 'vaults', 'obsidian-research')),
      createFormatVersion: 2,
    );
    final store = WorkspaceStore(imported);
    final saved = await store.createMarkdown(
      'Research',
      Uint8List.fromList(utf8.encode('Imported [[Reference]]')),
    );
    final importedVaultId = imported.vaultId;
    final importedDeviceId = imported.deviceId;
    final importedPath = imported.root.path;
    await imported.close();
    final otherRemote = _FixtureRemote(
      importedVaultId,
      'imported-drive-folder',
    );
    final otherVault = DriveVault(
      id: otherRemote.remoteId,
      vaultId: importedVaultId,
      name: 'Imported vault',
      formatVersion: 2,
    );
    final currentVault = workspace.repository;
    var current = currentVault;
    final connection = DriveConnectionController(
      repository: () => current,
      onRepositoryChanged: (next) async => current = next,
      onRemoteUpdated: () async {},
      onResumeReload: () => current.reloadFromDisk(),
      directoryProvider: () async => settingsDirectory,
      authFactory: (_) => _FixtureAuth(),
      remoteFactory: (token) =>
          _FixtureTransport(remote, token, alternate: otherRemote),
      registerBackgroundWork: () async {},
    );
    addTearDown(() async {
      await connection.close();
      if (!identical(current, currentVault)) await current.close();
    });
    await connection.initialize();
    await connection.connectExisting(otherVault);
    expect(connection.error, isNull);
    expect(current.root.path, importedPath);
    expect(current.deviceId, importedDeviceId);
    final receivedStore = WorkspaceStore(current);
    final received = (await receivedStore.list()).single;
    expect(received.id, saved.id);
    expect(
      await (await receivedStore.open(received)).readMarkdown(),
      'Imported [[Reference]]',
    );
    await connection.retry();
    expect(
      otherRemote.records.values.any((record) => record.entityId == saved.id),
      isTrue,
    );
  });

  test(
    'copying a legacy Drive vault keeps the binding and uses disk data',
    () async {
      final sourceRoot = Directory('${directory.path}/legacy');
      var current = await NoteRepository.open(sourceRoot);
      final sourceVaultId = current.vaultId;
      final first = await WorkspaceStore(current).create('First legacy note');
      final legacyRemote = _FixtureRemote(sourceVaultId);
      await (DriveConnectionSettings()
            ..accountId = _FixtureAuth.fixtureAccount
            ..folderId = legacyRemote.remoteId
            ..rootPath = current.root.path
            ..vaultId = sourceVaultId)
          .save(settingsDirectory);

      late final DriveConnectionController connection;
      Future<void> expectLeaseHeld() => expectLater(
        DriveSyncLease.acquire(connection.settings.leasePort)
            .then((lease) => lease.close()),
        throwsA(isA<SocketException>()),
      );

      connection = DriveConnectionController(
        repository: () => current,
        onRepositoryChanged: (next) async {
          await expectLeaseHeld();
          final previous = current;
          current = next;
          await previous.close();
        },
        onRemoteUpdated: () async {},
        onResumeReload: () async {
          await expectLeaseHeld();
          await current.close();
          current = await NoteRepository.open(sourceRoot);
        },
        directoryProvider: () async => settingsDirectory,
        authFactory: (_) => _FixtureAuth(),
        remoteFactory: (token) => _FixtureTransport(legacyRemote, token),
      );
      addTearDown(() => current.close());
      addTearDown(connection.close);

      await connection.initialize();
      expect(connection.connected, isTrue);
      final firstSync = connection.coordinator;
      final previousConnection = await File(
        '${settingsDirectory.path}/connection.json',
      ).readAsString();
      final occupied = Directory('${directory.path}/occupied');
      await occupied.create();
      final existing = File('${occupied.path}/keep.txt');
      await existing.writeAsString('keep');
      expect(
        await connection.upgradeLegacyRepository(current, occupied),
        isFalse,
      );
      expect(await existing.readAsString(), 'keep');
      expect(current.vaultId, sourceVaultId);
      expect(connection.connected, isTrue);
      expect(connection.coordinator, isNot(same(firstSync)));

      await connection.setForeground(false);
      final otherLease = await DriveSyncLease.acquire(
        connection.settings.leasePort,
      );
      final otherRepository = await NoteRepository.open(sourceRoot);
      final later = await WorkspaceStore(otherRepository)
          .create('Later legacy note');
      await otherRepository.close();
      await otherLease.close();
      expect(
        (await current.revisions()).map((r) => r.entityId),
        isNot(contains(later.id)),
      );

      expect(
        await connection.upgradeLegacyRepository(
          current,
          Directory('${directory.path}/upgraded'),
        ),
        isTrue,
      );
      expect(current.formatVersion, 2);
      expect(current.vaultId, isNot(sourceVaultId));
      expect(
        (await current.revisions()).map((r) => r.entityId),
        containsAll([first.id, later.id]),
      );
      final original = await NoteRepository.open(sourceRoot);
      try {
        expect(original.formatVersion, 1);
        expect(original.vaultId, sourceVaultId);
        expect(
          (await original.revisions()).map((r) => r.entityId),
          containsAll([first.id, later.id]),
        );
      } finally {
        await original.close();
      }
      expect(
        await File('${settingsDirectory.path}/connection.json').readAsString(),
        previousConnection,
      );
      await connection.setForeground(true);
      expect(connection.connected, isFalse);
      expect(connection.error, isNull);
      final released = await DriveSyncLease.acquire(
        connection.settings.leasePort,
      );
      await released.close();
    },
  );

  for (final (label, platform, width) in [
    ('Android drawer', TargetPlatform.android, 600.0),
    ('Android rail', TargetPlatform.android, 1400.0),
    ('Windows drawer', TargetPlatform.windows, 600.0),
  ]) {
    testWidgets('$label keeps Drive active while editing', (tester) async {
      final previousPlatform = debugDefaultTargetPlatformOverride;
      final previousLifecycle = tester.binding.lifecycleState;
      debugDefaultTargetPlatformOverride = platform;
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 900);
      _changeLifecycle(tester, AppLifecycleState.resumed);

      final auth = _FixtureAuth();
      final transports = <_FixtureTransport>[];
      var factoryCalls = 0;
      var diskReloads = 0;
      var failNextTransport = false;
      _ObservedConnection? drive;
      final panel = find.byType(DrivePanel, skipOffstage: false);
      try {
        await tester.pumpWidget(
          TranslationProvider(
            child: MaterialApp(
              home: StudyWorkspace(
                controller: workspace,
                createDriveConnection: (owner) {
                  factoryCalls++;
                  return drive = _ObservedConnection(
                    repository: () => owner.repository,
                    onRepositoryChanged: owner.replaceRepository,
                    onRemoteUpdated: owner.refresh,
                    onResumeReload: () async {
                      diskReloads++;
                      await owner.reloadFromDisk();
                    },
                    directoryProvider: () async => settingsDirectory,
                    authFactory: (_) => auth,
                    remoteFactory: (token) {
                      if (failNextTransport) {
                        failNextTransport = false;
                        throw StateError(
                          'Fixture transport startup failed once',
                        );
                      }
                      final transport = _FixtureTransport(remote, token);
                      transports.add(transport);
                      return transport;
                    },
                  );
                },
              ),
            ),
          ),
        );
        await _until(
          tester,
          () => drive?.status.phase == SyncPhase.synced,
          'the persisted Drive connection should start from the library',
        );
        final connection = drive!;
        final firstSync = connection.coordinator;
        expect(firstSync, isNotNull);
        expect(factoryCalls, 1);
        expect(diskReloads, 1);

        if (width < 1000) {
          expect(panel, findsNothing);
          final scaffold = tester.state<ScaffoldState>(
            find.byType(Scaffold).first,
          );
          scaffold.openDrawer();
          await tester.pumpAndSettle();
          expect(panel, findsOneWidget);
          scaffold.closeDrawer();
          await tester.pumpAndSettle();
          expect(panel, findsNothing);
          expect(connection.coordinator, same(firstSync));
        } else {
          expect(panel, findsOneWidget);
        }

        await tester.tap(
          find.byKey(ValueKey('library-note-${note.revision.revisionId}')),
        );
        await _until(
          tester,
          () =>
              workspace.activeSession?.note.id == note.id &&
              panel.evaluate().isEmpty,
          'the note should open from its library card and hide the Drive panel',
        );
        expect(panel, findsNothing);
        expect(connection.coordinator, same(firstSync));
        expect(transports.single.closeCalls, 0);

        if (platform == TargetPlatform.android && width == 600) {
          await _roundTrip(
            tester,
            workspace,
            remote,
            directory,
            note,
            connection,
          );
          expect(panel, findsNothing);
        }

        final foregroundCount = connection.foregroundEvents.length;
        _changeLifecycle(tester, AppLifecycleState.paused);
        await _until(
          tester,
          () => connection.coordinator == null && !connection.busy,
          'pausing should stop the coordinator with the panel absent',
        );
        expect(transports.single.closeCalls, 1);
        _changeLifecycle(tester, AppLifecycleState.resumed);
        await _until(
          tester,
          () {
            expect(connection.error, isNull);
            return connection.coordinator != null &&
                !connection.busy &&
                connection.coordinator?.status.phase == SyncPhase.synced;
          },
          'resuming should restart Drive with the panel absent',
          details: () =>
              'phase=${connection.coordinator?.status.phase} '
              'reloads=$diskReloads auth restores=${auth.restoreCalls}',
        );
        expect(connection.foregroundEvents.skip(foregroundCount), [
          false,
          true,
        ]);
        expect(connection.coordinator, isNot(same(firstSync)));
        expect(factoryCalls, 1);
        expect(diskReloads, 2);
        expect(auth.restoreCalls, 2);
        expect(workspace.activeSession?.note.id, note.id);
        expect(panel, findsNothing);

        if (platform == TargetPlatform.windows) {
          _changeLifecycle(tester, AppLifecycleState.paused);
          await _until(
            tester,
            () => connection.coordinator == null && !connection.busy,
            'pause before exercising a failed restart',
          );
          failNextTransport = true;
          _changeLifecycle(tester, AppLifecycleState.resumed);
          await _until(
            tester,
            () => connection.error != null && !connection.busy,
            'a failed restart should settle and retain the error',
          );
          await tester.pump(const Duration(seconds: 1));
          expect(connection.error, isNotNull);
          expect(connection.coordinator, isNull);
          expect(diskReloads, 3);
          expect(auth.restoreCalls, 3);
          expect(transports, hasLength(2));

          unawaited(connection.retry());
          await _until(
            tester,
            () =>
                connection.connected &&
                !connection.busy &&
                connection.coordinator?.status.phase == SyncPhase.synced,
            'an explicit retry should recover the failed restart',
          );
          expect(connection.error, isNull);
          expect(diskReloads, 4);
          expect(auth.restoreCalls, 4);
          expect(transports, hasLength(3));
          expect(panel, findsNothing);
        }

        await tester.pumpWidget(const SizedBox.shrink());
        await _until(
          tester,
          () => connection.closed,
          'workspace disposal should close its Drive connection',
        );
        expect(connection.closeCalls, 1);
        expect(connection.coordinator, isNull);
        expect(auth.closeCalls, 1);
        expect(
          transports.every((transport) => transport.closeCalls == 1),
          isTrue,
        );
        expect(tester.takeException(), isNull);
      } finally {
        try {
          await tester.pumpWidget(const SizedBox.shrink());
          final connection = drive;
          if (connection != null && !connection.closed) {
            if (connection.closeCalls == 0) unawaited(connection.close());
            await _until(tester, () => connection.closed, 'close the fixture');
          }
          await _finish(tester, workspace.flush(), 'flush the local fixture');
        } finally {
          workspace.dispose();
          await _finish(
            tester,
            workspace.repository.close(),
            'close the local repository',
          );
          _changeLifecycle(
            tester,
            previousLifecycle ?? AppLifecycleState.resumed,
          );
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
          debugDefaultTargetPlatformOverride = previousPlatform;
        }
      }
    });
  }

  testWidgets('Android Drive hands off only after the latest edit is saved', (
    tester,
  ) async {
    final previousPlatform = debugDefaultTargetPlatformOverride;
    final previousLifecycle = tester.binding.lifecycleState;
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1100, 900);
    _changeLifecycle(tester, AppLifecycleState.resumed);
    final saveStarted = Completer<void>();
    final releaseSave = Completer<void>();
    final quickSaveStarted = Completer<void>();
    final releaseQuickSave = Completer<void>();
    _ObservedConnection? drive;
    Future<void> startSave(
      String text,
      Completer<void> entered,
      Completer<void> release,
    ) async {
      workspace.beforeNextFlush = () {
        entered.complete();
        return release.future;
      };
      workspace.editMarkdown(text);
      await tester.tap(find.byTooltip('기기에 저장'));
      await _until(
        tester,
        () => entered.isCompleted,
        'the real Save action should be in flight before pausing',
      );
    }

    try {
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: StudyWorkspace(
              controller: workspace,
              createDriveConnection: (owner) => drive = _ObservedConnection(
                repository: () => owner.repository,
                onRepositoryChanged: owner.replaceRepository,
                onRemoteUpdated: owner.refresh,
                onResumeReload: owner.reloadFromDisk,
                directoryProvider: () async => settingsDirectory,
                authFactory: (_) => _FixtureAuth(),
                remoteFactory: (token) => _FixtureTransport(remote, token),
              ),
            ),
          ),
        ),
      );
      await _until(
        tester,
        () => drive?.status.phase == SyncPhase.synced,
        'the connected Android workspace should start syncing',
      );
      final connection = drive!;
      final first = connection.coordinator;
      final foregroundCount = connection.foregroundEvents.length;
      await tester.tap(
        find.byKey(ValueKey('library-note-${note.revision.revisionId}')),
      );
      await _until(
        tester,
        () =>
            workspace.activeSession?.note.id == note.id &&
            find.byType(LinearProgressIndicator).evaluate().isEmpty,
        'the note should be open before backgrounding',
      );

      await startSave('latest Android edit', saveStarted, releaseSave);
      _changeLifecycle(tester, AppLifecycleState.paused);
      await tester.pump(const Duration(milliseconds: 100));
      expect(workspace.dirty, isTrue);
      expect(
        connection.foregroundEvents.skip(foregroundCount),
        isEmpty,
        reason: 'the background worker must not be scheduled against the old on-disk revision',
      );
      expect(connection.coordinator, same(first));

      releaseSave.complete();
      await _until(
        tester,
        () =>
            !workspace.dirty &&
            connection.coordinator == null &&
            !connection.busy,
        'the committed edit should be followed by Drive handoff',
      );
      expect(connection.foregroundEvents.skip(foregroundCount), [false]);
      final (receivedRevision, receivedText) = (await tester.runAsync(() async {
        final sent = await runDriveBackgroundSync(
          directory: settingsDirectory,
          authFactory: (_) => _FixtureAuth(),
          remoteFactory: (token) => _FixtureTransport(remote, token),
          actionRuntimeFactory: (_) => null,
        );
        if (!sent) throw StateError('Background worker did not finish');
        final peer = await NoteRepository.open(
          Directory('${directory.path}/windows-peer'),
          vaultId: workspace.repository.vaultId,
          createFormatVersion: 2,
        );
        final receive = SyncCoordinator(
          repository: peer,
          remote: remote,
          stateDirectory: Directory('${directory.path}/windows-drive'),
        );
        try {
          await receive.syncOnce();
          final store = WorkspaceStore(peer);
          final session = await store.open((await store.list()).single);
          return (session.markdownParents.single, await session.readMarkdown());
        } finally {
          await receive.close();
          await peer.close();
        }
      }))!;
      expect(receivedText, 'latest Android edit');
      expect(workspace.activeSession?.markdownParents, [receivedRevision]);
      _changeLifecycle(tester, AppLifecycleState.resumed);
      await _until(
        tester,
        () =>
            connection.coordinator?.status.phase == SyncPhase.synced &&
            !connection.busy &&
            find.byType(LinearProgressIndicator).evaluate().isEmpty,
        'resuming should restart the foreground coordinator',
      );
      expect(connection.foregroundEvents.skip(foregroundCount), [false, true]);

      final resumed = connection.coordinator;
      final quickForegroundCount = connection.foregroundEvents.length;
      const quickEdit = 'edit while briefly backgrounded';
      await startSave(quickEdit, quickSaveStarted, releaseQuickSave);
      _changeLifecycle(tester, AppLifecycleState.paused);
      _changeLifecycle(tester, AppLifecycleState.resumed);
      expect(workspace.dirty, isTrue);
      expect(connection.foregroundEvents.skip(quickForegroundCount), [true]);
      releaseQuickSave.complete();
      await _until(
        tester,
        () =>
            !workspace.dirty &&
            connection.status.phase == SyncPhase.synced &&
            remote.records.values.any((record) {
              if (record.entityId != note.markdownEntityId) return false;
              final blob = remote.blobs[record.blobs['summary.md']?.hash];
              return blob != null && utf8.decode(blob) == quickEdit;
            }),
        'the retained foreground coordinator should upload the second edit',
      );
      expect(connection.foregroundEvents.skip(quickForegroundCount), [true]);
      expect(connection.coordinator, same(resumed));
    } finally {
      if (!releaseSave.isCompleted) releaseSave.complete();
      if (!releaseQuickSave.isCompleted) releaseQuickSave.complete();
      try {
        await _finish(tester, workspace.flush(), 'flush the local fixture');
        _changeLifecycle(tester, AppLifecycleState.resumed);
        await tester.pumpWidget(const SizedBox.shrink());
        if (drive case final connection?) {
          if (connection.closeCalls == 0) unawaited(connection.close());
          await _until(tester, () => connection.closed, 'close the fixture');
        }
      } finally {
        workspace.dispose();
        await _finish(
          tester,
          workspace.repository.close(),
          'close the local repository',
        );
        _changeLifecycle(
          tester,
          previousLifecycle ?? AppLifecycleState.resumed,
        );
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        debugDefaultTargetPlatformOverride = previousPlatform;
      }
    }
  });

  testWidgets(
    "Android keeps Drive in the foreground while the app's own picker or Office engine is in front",
    (tester) async {
      final previousPlatform = debugDefaultTargetPlatformOverride;
      final previousLifecycle = tester.binding.lifecycleState;
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1100, 900);
      _changeLifecycle(tester, AppLifecycleState.resumed);
      final screen = Completer<void>();
      final leftDuringScreen = Completer<void>();
      _ObservedConnection? drive;
      try {
        await tester.pumpWidget(
          TranslationProvider(
            child: MaterialApp(
              home: StudyWorkspace(
                controller: workspace,
                createDriveConnection: (owner) => drive = _ObservedConnection(
                  repository: () => owner.repository,
                  onRepositoryChanged: owner.replaceRepository,
                  onRemoteUpdated: owner.refresh,
                  onResumeReload: owner.reloadFromDisk,
                  directoryProvider: () async => settingsDirectory,
                  authFactory: (_) => _FixtureAuth(),
                  remoteFactory: (token) => _FixtureTransport(remote, token),
                ),
              ),
            ),
          ),
        );
        await _until(
          tester,
          () => drive?.status.phase == SyncPhase.synced,
          'the connected Android workspace should start syncing',
        );
        final connection = drive!;
        final first = connection.coordinator;
        final foregroundCount = connection.foregroundEvents.length;

        // Android resumes the app just before the screen's result arrives.
        final returned = AppExternalScreen.run(() => screen.future);
        _changeLifecycle(tester, AppLifecycleState.paused);
        await tester.pump(const Duration(milliseconds: 100));
        _changeLifecycle(tester, AppLifecycleState.resumed);
        screen.complete();
        await tester.pump();
        await returned;
        await tester.pump(const Duration(seconds: 3));
        expect(AppExternalScreen.active, isFalse);
        expect(
          connection.foregroundEvents.skip(foregroundCount),
          isEmpty,
          reason: "returning from the app's own screen is not a Drive handoff",
        );
        expect(connection.coordinator, same(first));

        final left = AppExternalScreen.run(() => leftDuringScreen.future);
        _changeLifecycle(tester, AppLifecycleState.paused);
        await tester.pump(const Duration(milliseconds: 100));
        expect(
          connection.foregroundEvents.skip(foregroundCount),
          isEmpty,
          reason: "Drive waits while the app's own screen is in front",
        );
        leftDuringScreen.complete();
        await tester.pump();
        await left;
        await _until(
          tester,
          () => connection.coordinator == null && !connection.busy,
          'leaving the app during its own screen hands Drive off once the screen closes',
        );
        expect(connection.foregroundEvents.skip(foregroundCount), [false]);
        _changeLifecycle(tester, AppLifecycleState.resumed);
        await _until(
          tester,
          () =>
              connection.coordinator?.status.phase == SyncPhase.synced &&
              !connection.busy,
          'resuming should restart the foreground coordinator',
        );
        expect(connection.foregroundEvents.skip(foregroundCount), [false, true]);
      } finally {
        if (!screen.isCompleted) screen.complete();
        if (!leftDuringScreen.isCompleted) leftDuringScreen.complete();
        try {
          await _finish(tester, workspace.flush(), 'flush the local fixture');
          _changeLifecycle(tester, AppLifecycleState.resumed);
          await tester.pumpWidget(const SizedBox.shrink());
          if (drive case final connection?) {
            if (connection.closeCalls == 0) unawaited(connection.close());
            await _until(tester, () => connection.closed, 'close the fixture');
          }
        } finally {
          workspace.dispose();
          await _finish(
            tester,
            workspace.repository.close(),
            'close the local repository',
          );
          _changeLifecycle(
            tester,
            previousLifecycle ?? AppLifecycleState.resumed,
          );
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
          debugDefaultTargetPlatformOverride = previousPlatform;
        }
      }
    },
  );
}

Future<void> _roundTrip(
  WidgetTester tester,
  WorkspaceController workspace,
  _FixtureRemote remote,
  Directory directory,
  VaultNote note,
  DriveConnectionController connection,
) async {
  workspace.editMarkdown('from Android');
  final markdown = remote.records.values.where((record) {
    if (record.entityId != note.markdownEntityId) return false;
    final blob = remote.blobs[record.blobs['summary.md']?.hash];
    return blob != null && utf8.decode(blob) == 'from Android';
  });
  await _until(
    tester,
    () => connection.status.phase == SyncPhase.synced && markdown.isNotEmpty,
    'saving the open note should automatically upload to Drive',
  );
  expect(markdown, hasLength(1));

  final peerRevision = (await tester.runAsync(() async {
    final peer = await NoteRepository.open(
      Directory('${directory.path}/peer'),
      createFormatVersion: 2,
      vaultId: workspace.repository.vaultId,
    );
    final sync = SyncCoordinator(
      repository: peer,
      remote: remote,
      stateDirectory: Directory('${directory.path}/peer-drive'),
    );
    try {
      await sync.syncOnce();
      final store = WorkspaceStore(peer);
      final session = await store.open((await store.list()).single);
      expect(await session.readMarkdown(), 'from Android');
      await session.saveMarkdown('from peer');
      final change = (await peer.heads(note.markdownEntityId)).single;
      await sync.syncOnce();
      return change;
    } finally {
      await sync.close();
      await peer.close();
    }
  }))!;
  expect(
    remote.records.values.any((r) => r.revisionId == peerRevision.revisionId),
    isTrue,
  );
  await tester.pump(const Duration(seconds: 16));
  await _until(
    tester,
    () => workspace.markdown == 'from peer',
    'polling Drive should refresh the open note automatically',
  );
  expect(workspace.activeSession?.markdownParents, [peerRevision.revisionId]);
}

void _changeLifecycle(WidgetTester tester, AppLifecycleState target) {
  final binding = tester.binding;
  final previous = binding.lifecycleState;
  if (previous == target) return;
  if (previous == null) {
    binding.handleAppLifecycleStateChanged(target);
    return;
  }
  const states = AppLifecycleState.values;
  final start = states.indexOf(previous), end = states.indexOf(target);
  if (target == AppLifecycleState.detached) {
    for (var i = start + 1; i < states.length; i++) {
      binding.handleAppLifecycleStateChanged(states[i]);
    }
    binding.handleAppLifecycleStateChanged(target);
    return;
  }
  final step = start < end ? 1 : -1;
  for (var i = start + step; i != end + step; i += step) {
    binding.handleAppLifecycleStateChanged(states[i]);
  }
}

Future<void> _until(
  WidgetTester tester,
  bool Function() condition,
  String reason, {
  String Function()? details,
}) async {
  for (var attempt = 0; attempt < 300 && !condition(); attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
  if (!condition()) {
    fail(details == null ? reason : '$reason (${details()})');
  }
}

Future<void> _finish(
  WidgetTester tester,
  Future<void> operation,
  String reason,
) async {
  var complete = false;
  unawaited(operation.whenComplete(() => complete = true));
  await _until(tester, () => complete, reason);
}

class _ObservedConnection extends DriveConnectionController {
  final foregroundEvents = <bool>[];
  var closeCalls = 0;
  var closed = false;

  new({
    required super.repository,
    required super.onRepositoryChanged,
    required super.onRemoteUpdated,
    required super.onResumeReload,
    required super.directoryProvider,
    required super.authFactory,
    required super.remoteFactory,
  });

  @override
  Future<void> setForeground(bool foreground) {
    foregroundEvents.add(foreground);
    return super.setForeground(foreground);
  }

  @override
  Future<void> close() async {
    closeCalls++;
    await super.close();
    closed = true;
  }
}

class _GatedWorkspaceController extends WorkspaceController {
  new(super.repository);

  Future<void> Function()? beforeNextFlush;

  @override
  Future<void> flush() {
    final before = beforeNextFlush;
    beforeNextFlush = null;
    return before == null ? super.flush() : before().then((_) => super.flush());
  }
}

class _FixtureAuth extends DriveAuth {
  static const fixtureAccount = 'synthetic-drive-account';
  final bool allowSignIn, allowSignOut;
  var restoreCalls = 0;
  var signInCalls = 0;
  var closeCalls = 0;

  new({this.allowSignIn = false, this.allowSignOut = false});

  @override
  String get accountId => fixtureAccount;

  @override
  Future<void> restore() async => restoreCalls++;

  @override
  Future<String> accessToken() async => 'synthetic-token';

  @override
  Future<void> signIn() async {
    if (!allowSignIn) fail('No interactive OAuth is expected');
    signInCalls++;
  }

  @override
  Future<void> signOut() async {
    if (!allowSignOut) fail('No sign-out is expected');
  }

  @override
  Future<void> cancel() async {}

  @override
  void close() => closeCalls++;
}

class _FixturePaths extends PathProviderPlatform {
  new(this.support);

  final String support;

  @override
  Future<String?> getApplicationSupportPath() async => support;
}

class _FixtureTransport extends DriveRemoteStore {
  final _FixtureRemote remote;
  final _FixtureRemote? alternate;
  var closeCalls = 0;

  new(this.remote, Future<String> Function() token, {this.alternate})
    : super(
        accessToken: token,
        client: MockClient((_) async => fail('No Google HTTP is expected')),
      );

  @override
  Future<DriveVault> connectVault(String folderId) async {
    final found = _remoteFor(folderId);
    return DriveVault(
      id: folderId,
      vaultId: found.vaultId,
      name: 'Synthetic Drive',
      formatVersion: 2,
    );
  }

  @override
  RemoteStore bind(DriveVault vault, {DriveUploadSessions? uploadSessions}) {
    final found = _remoteFor(vault.id);
    if (vault.vaultId != found.vaultId) {
      throw StateError('Fixture transport received a different vault');
    }
    return found;
  }

  _FixtureRemote _remoteFor(String folderId) {
    if (folderId == remote.remoteId) return remote;
    if (alternate case final candidate? when candidate.remoteId == folderId) {
      return candidate;
    }
    throw StateError('Unexpected Drive folder');
  }

  @override
  void close() {
    closeCalls++;
    super.close();
  }
}

class _FixtureRemote implements RemoteStore {
  @override
  final String vaultId;
  @override
  final String remoteId;
  final blobs = <String, Uint8List>{};
  final records = <String, RevisionRecord>{};
  var _nextId = 0;

  new(this.vaultId, [this.remoteId = 'synthetic-drive-folder']);

  @override
  Future<String> generateId() async => 'synthetic-file-${_nextId++}';

  @override
  Future<String?> findBlob(BlobRef ref) async =>
      blobs.containsKey(ref.hash) ? ref.hash : null;

  @override
  Future<void> putBlob(
    BlobRef ref,
    Uint8List bytes,
    String intentFileId,
  ) async {
    blobs[ref.hash] = bytes;
  }

  @override
  Future<void> publishRevision(
    RevisionRecord record,
    String intentFileId,
  ) async {
    records.putIfAbsent(intentFileId, () => record);
  }

  @override
  Future<RevisionRecord> readManifest(String fileId) async => records[fileId]!;

  @override
  Future<Uint8List> readBlob(BlobRef ref) async => blobs[ref.hash]!;

  @override
  Future<String> startPageToken() async => '${records.length}';

  @override
  Future<RemotePage> listManifests({String? pageToken}) async =>
      RemotePage(records.keys.map(RemoteChange.new).toList());

  @override
  Future<RemotePage> readChanges(String pageToken) async => RemotePage(
    records.keys.skip(int.parse(pageToken)).map(RemoteChange.new).toList(),
    newStartPageToken: '${records.length}',
  );

  @override
  void close() {}
}
