import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ink_vault_core/drive.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:saber/data/drive/drive_auth.dart';
import 'package:saber/data/drive/drive_connection.dart';
import 'package:saber/data/drive/oauth_flow.dart';

class MemorySecrets implements DriveSecrets {
  final values = <String, String>{};
  var failWrites = false;
  Future<void> Function()? beforeWrite;
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    if (failWrites) throw StateError('OS secure storage unavailable');
    if (beforeWrite case final wait?) await wait();
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async => values.remove(key);
}

String _credentials(String account, {String clientId = 'client'}) => jsonEncode({
  'clientId': clientId,
  'accountId': account,
  'refreshToken': 'refresh-$account',
});

http.Response _token(String access, {String? rotated}) => http.Response(
  jsonEncode({
    'access_token': access,
    'expires_in': 3600,
    'token_type': 'Bearer',
    'refresh_token': ?rotated,
  }),
  200,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('system-browser login exchanges code with S256 verifier and persists account only after secure save', () async {
    final secrets = MemorySecrets();
    Uri? launched;
    final auth = DesktopDriveAuth(
      clientId: 'public-client',
      secrets: secrets,
      launch: (uri) async {
        launched = uri;
        final redirect = Uri.parse(uri.queryParameters['redirect_uri']!);
        final browser = await Socket.connect(redirect.host, redirect.port);
        final path = redirect.replace(
          queryParameters: {
            'state': uri.queryParameters['state']!,
            'code': 'private-code',
          },
        );
        browser.write(
          'GET ${path.path}?${path.query} HTTP/1.1\r\nHost: ${redirect.host}:${redirect.port}\r\nConnection: close\r\n\r\n',
        );
        await browser.flush();
        await browser.drain<void>();
        await browser.close();
        return true;
      },
      client: MockClient((request) async {
        if (request.url.path.endsWith('/userinfo'))
          return http.Response('{"sub":"account-1"}', 200);
        expect(request.bodyFields['code'], 'private-code');
        expect(
          pkceChallenge(request.bodyFields['code_verifier']!),
          launched!.queryParameters['code_challenge'],
        );
        expect(
          request.bodyFields['redirect_uri'],
          launched!.queryParameters['redirect_uri'],
        );
        expect(launched!.queryParameters['code_challenge_method'], 'S256');
        expect(launched!.queryParameters['access_type'], 'offline');
        return http.Response(
          jsonEncode({
            'access_token': 'private-access',
            'refresh_token': 'private-refresh',
            'expires_in': 3600,
            'token_type': 'Bearer',
            'scope': driveFileScope,
          }),
          200,
        );
      }),
    );
    await auth.signIn();
    expect(auth.accountId, 'account-1');
    expect(
      secrets.values['drive.desktop.credentials'],
      contains('private-refresh'),
    );
    expect(await auth.accessToken(), 'private-access');
    auth.close();
  });

  test('partial grant without Drive scope cannot become connected', () async {
    final secrets = MemorySecrets();
    final auth = DesktopDriveAuth(
      clientId: 'client',
      secrets: secrets,
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'access_token': 'access',
            'refresh_token': 'refresh',
            'expires_in': 3600,
            'token_type': 'Bearer',
            'scope': 'openid email',
          }),
          200,
        ),
      ),
    );
    await expectLater(
      auth.acceptCode(
        code: 'private',
        verifier: oauthRandom(),
        redirect: Uri.parse('http://127.0.0.1:1234/oauth/callback'),
      ),
      throwsA(isA<OAuthFailure>()),
    );
    expect(auth.accountId, isNull);
    expect(secrets.values, isEmpty);
    auth.close();
  });
  test('expired access refreshes using securely stored refresh; logs expose no tokens', () async {
    final secrets = MemorySecrets();
    secrets.values['drive.desktop.credentials'] = jsonEncode({
      'clientId': 'client',
      'accountId': 'account-1',
      'refreshToken': 'private-refresh',
    });
    var requests = 0;
    final auth = DesktopDriveAuth(
      clientId: 'client',
      secrets: secrets,
      client: MockClient((request) async {
        requests++;
        expect(request.url.toString(), 'https://oauth2.googleapis.com/token');
        expect(request.bodyFields['refresh_token'], 'private-refresh');
        return http.Response(
          jsonEncode({
            'access_token': 'fresh-access',
            'expires_in': 3600,
            'token_type': 'Bearer',
          }),
          200,
        );
      }),
    );
    await auth.restore();
    expect(auth.accountId, 'account-1');
    expect(await auth.accessToken(), 'fresh-access');
    await auth.restore();
    expect(await auth.accessToken(), 'fresh-access');
    expect(requests, 1);
    await auth.signOut();
    expect(secrets.values['drive.desktop.credentials'], isNull);
    await expectLater(auth.accessToken(), throwsA(isA<OAuthFailure>()));
    auth.close();
  });

  test('restoring a different account replaces the cached Drive bearer', () async {
    const key = 'drive.desktop.credentials';
    final secrets = MemorySecrets()..values[key] = _credentials('first');
    final auth = DesktopDriveAuth(
      clientId: 'client',
      secrets: secrets,
      client: MockClient((request) async {
        final refresh = request.bodyFields['refresh_token'];
        return switch (refresh) {
          'refresh-first' => _token('access-first'),
          'refresh-second' => _token('access-second'),
          _ => throw StateError('Unexpected synthetic refresh'),
        };
      }),
    );
    addTearDown(auth.close);
    await auth.restore();
    expect(await auth.accessToken(), 'access-first');

    secrets.values[key] = _credentials('second');
    await auth.restore();
    expect(auth.accountId, 'second');
    final drive = DriveRemoteStore(
      accessToken: auth.accessToken,
      client: MockClient((request) async {
        expect(request.headers['authorization'], 'Bearer access-second');
        return http.Response('{"files":[]}', 200);
      }),
    );
    addTearDown(drive.close);
    expect(await drive.listVaults(), isEmpty);
  });

  for (final entry in <String, String?>{
    'missing': null,
    'mismatched': _credentials('second', clientId: 'other-client'),
    'malformed': '{',
  }.entries) {
    test('restoring ${entry.key} credentials clears the previous session', () async {
      const key = 'drive.desktop.credentials';
      final secrets = MemorySecrets()..values[key] = _credentials('first');
      final auth = DesktopDriveAuth(
        clientId: 'client',
        secrets: secrets,
        client: MockClient((_) async => _token('access-first')),
      );
      addTearDown(auth.close);
      await auth.restore();
      expect(await auth.accessToken(), 'access-first');

      if (entry.value case final value?) {
        secrets.values[key] = value;
      } else {
        secrets.values.remove(key);
      }
      if (entry.key == 'malformed') {
        await expectLater(auth.restore(), throwsA(isA<OAuthFailure>()));
      } else {
        await auth.restore();
      }
      expect(auth.accountId, isNull);
      await expectLater(auth.accessToken(), throwsA(isA<OAuthFailure>()));
    });
  }

  test('a stale in-flight refresh cannot rotate or return the old account', () async {
    const key = 'drive.desktop.credentials';
    final secrets = MemorySecrets()..values[key] = _credentials('first');
    final requested = Completer<void>();
    final firstResponse = Completer<http.Response>();
    final secondRequested = Completer<void>();
    final secondResponse = Completer<http.Response>();
    var secondRequests = 0;
    final auth = DesktopDriveAuth(
      clientId: 'client',
      secrets: secrets,
      client: MockClient((request) async {
        if (request.bodyFields['refresh_token'] == 'refresh-first') {
          requested.complete();
          return firstResponse.future;
        }
        expect(request.bodyFields['refresh_token'], 'refresh-second');
        secondRequests++;
        if (!secondRequested.isCompleted) secondRequested.complete();
        return secondResponse.future;
      }),
    );
    addTearDown(() {
      if (!secondResponse.isCompleted) secondResponse.complete(_token('access-second'));
      auth.close();
    });
    await auth.restore();
    final oldRejected = expectLater(auth.accessToken(), throwsA(isA<OAuthFailure>()));
    await requested.future;

    final second = _credentials('second');
    secrets.values[key] = second;
    await auth.restore();
    final current = auth.accessToken();
    firstResponse.complete(_token('access-first', rotated: 'stale-rotation'));

    await oldRejected;
    await secondRequested.future;
    final shared = auth.accessToken();
    await Future<void>.delayed(Duration.zero);
    expect(secondRequests, 1);
    secondResponse.complete(_token('access-second'));
    expect(await current, 'access-second');
    expect(await shared, 'access-second');
    expect(auth.accountId, 'second');
    expect(secrets.values[key], second);
    expect(await auth.accessToken(), 'access-second');
  });

  test('sign-out cannot be undone by an already-started rotation write', () async {
    const key = 'drive.desktop.credentials';
    final started = Completer<void>();
    final finish = Completer<void>();
    final secrets = MemorySecrets()
      ..values[key] = _credentials('first')
      ..beforeWrite = () async {
        started.complete();
        await finish.future;
      };
    final auth = DesktopDriveAuth(
      clientId: 'client',
      secrets: secrets,
      client: MockClient((_) async => _token('access-first', rotated: 'rotation')),
    );
    addTearDown(auth.close);
    await auth.restore();
    final stale = expectLater(auth.accessToken(), throwsA(isA<OAuthFailure>()));
    await started.future;
    final signedOut = auth.signOut();
    final blocked = expectLater(auth.accessToken(), throwsA(isA<OAuthFailure>()));
    finish.complete();

    await signedOut;
    await stale;
    await blocked;
    expect(auth.accountId, isNull);
    expect(secrets.values[key], isNull);
  });

  final failures = <String, http.Response Function()>{
    for (final status in [408, 429, 503])
      'HTTP $status': () => http.Response(
        'untrusted-token-error-body',
        status,
        headers: {'retry-after': '12'},
      ),
    'HTTP date': () => http.Response(
      'untrusted-token-error-body',
      503,
      headers: {
        'retry-after': HttpDate.format(DateTime.now().toUtc().add(const Duration(seconds: 20))),
      },
    ),
    'timeout': () => throw TimeoutException('untrusted-token-error-body'),
    'transport': () => throw http.ClientException('untrusted-token-error-body'),
    'invalid_grant': () => http.Response(
      '{"error":"invalid_grant","error_description":"untrusted-token-error-body"}',
      400,
    ),
  };
  for (final failure in failures.entries) {
    test('Drive sync classifies ${failure.key} at token refresh', () async {
      final folder = await Directory.systemTemp.createTemp('drive-auth-retry-');
      final repo = await NoteRepository.open(Directory('${folder.path}/vault'));
      final secrets = MemorySecrets()
        ..values['drive.desktop.credentials'] = _credentials('current');
      var refreshes = 0;
      var requests = 0;
      final auth = DesktopDriveAuth(
        clientId: 'client',
        secrets: secrets,
        client: MockClient((_) async {
          if (++refreshes == 1) return failure.value();
          return _token('access-current');
        }),
      );
      final drive = DriveRemoteStore(
        accessToken: auth.accessToken,
        client: MockClient((request) async {
          requests++;
          expect(request.headers['authorization'], 'Bearer access-current');
          return http.Response(switch (request.url.path) {
            '/drive/v3/changes/startPageToken' => '{"startPageToken":"first"}',
            '/drive/v3/files' => '{"files":[]}',
            '/drive/v3/changes' => '{"changes":[],"newStartPageToken":"second"}',
            _ => throw StateError('Unexpected synthetic Drive request'),
          }, 200);
        }),
      );
      final coordinator = SyncCoordinator(
        repository: repo,
        remote: drive.bind(DriveVault(id: 'folder', vaultId: repo.vaultId, name: 'test')),
        stateDirectory: Directory('${folder.path}/state'),
      );
      addTearDown(() async {
        await coordinator.close();
        drive.close();
        auth.close();
        await repo.close();
        await folder.delete(recursive: true);
      });
      await auth.restore();
      final started = DateTime.now().toUtc();
      await coordinator.syncOnce();
      expect(refreshes, 1);
      expect(requests, 0);
      expect(coordinator.status.message, isNot(contains('untrusted-token-error-body')));

      if (failure.key == 'invalid_grant') {
        expect(coordinator.status.phase, SyncPhase.authenticationRequired);
        await coordinator.syncOnce(force: true);
        expect(refreshes, 1);
        return;
      }
      expect(coordinator.status.phase, SyncPhase.retryWaiting);
      if (failure.key.startsWith('HTTP')) {
        expect(coordinator.status.retryAt, isNotNull);
        expect(coordinator.status.retryAt!.difference(started),
            greaterThanOrEqualTo(const Duration(seconds: 12)));
      }
      await coordinator.syncOnce();
      expect(refreshes, 1);
      await coordinator.syncOnce(force: true);
      expect(coordinator.status.phase, SyncPhase.synced);
      expect(refreshes, 2);
      expect(requests, 3);
    });
  }

  for (final action in ['foreground return', 'reopen', 'OAuth settings save']) {
    test(
      'Drive preserves a token retry deadline on $action',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'drive-retry-lifecycle-',
        );
        final repo = await NoteRepository.open(
          Directory('${directory.path}/vault'),
        );
        final settingsDirectory = Directory('${directory.path}/settings');
        final savedState = File(
          '${settingsDirectory.path}/state/folder/sync-state.json',
        );
        const secretKey = 'drive.desktop.secret.client';
        final secrets = MemorySecrets()
          ..values['drive.desktop.credentials'] = _credentials('current')
          ..values[secretKey] = 'original-test-secret';
        final refreshSecrets = <String?>[];
        var refreshes = 0;
        var driveRequests = 0;
        DriveConnectionController makeController() => DriveConnectionController(
          repository: () => repo,
          onRepositoryChanged: (_) async => fail('Unexpected vault change'),
          onRemoteUpdated: () async {},
          onResumeReload: () async {},
          directoryProvider: () async => settingsDirectory,
          authFactory: (settings) => DesktopDriveAuth(
            clientId: settings.desktopClientId,
            secrets: secrets,
            client: MockClient((request) async {
              expect(request.url.path, '/token');
              refreshSecrets.add(request.bodyFields['client_secret']);
              if (++refreshes == 1) {
                return http.Response('', 503, headers: {'retry-after': '60'});
              }
              return _token('access-current');
            }),
          ),
          remoteFactory: (token) => DriveRemoteStore(
            accessToken: token,
            client: MockClient((request) async {
              driveRequests++;
              expect(request.headers['authorization'], 'Bearer access-current');
              return http.Response(switch (request.url.path) {
                '/drive/v3/changes/startPageToken' => '{"startPageToken":"first"}',
                '/drive/v3/files' => '{"files":[]}',
                '/drive/v3/changes' => '{"changes":[],"newStartPageToken":"second"}',
                _ => throw StateError('Unexpected synthetic Drive request'),
              }, 200);
            }),
          ),
        );
        var controller = makeController();
        addTearDown(() async {
          await controller.close();
          await repo.close();
          await directory.delete(recursive: true);
        });
        await (DriveConnectionSettings()
              ..desktopClientId = 'client'
              ..accountId = 'current'
              ..folderId = 'folder'
              ..vaultId = repo.vaultId
              ..rootPath = repo.root.path
              ..vaultFormatVersion = repo.formatVersion)
            .save(settingsDirectory);
        await controller.initialize();
        expect(controller.error, isNull);
        await controller.coordinator!.syncOnce();
        final before = controller.coordinator!.status;
        expect(before.phase, SyncPhase.retryWaiting);
        expect(before.retryAt, isNotNull);
        expect(refreshes, 1);
        expect(driveRequests, 0);
        final state = jsonDecode(await savedState.readAsString()) as Map;
        expect(state['attempts'], 1);
        expect(state['retryAt'], before.retryAt!.toIso8601String());

        if (action == 'reopen') {
          await controller.close();
          controller = makeController();
          await controller.initialize();
        } else if (action == 'foreground return') {
          await controller.setForeground(false);
          await controller.setForeground(true);
        } else {
          final coordinator = controller.coordinator;
          final auth = controller.auth;
          Future<void> saveSecret(String? secret) => controller.configure(
            androidServerClientId: ' ',
            desktopClientId: ' client ',
            desktopSecret: secret,
          );

          for (final blank in [null, '', '  \t']) {
            await saveSecret(blank);
            expect(controller.error, isNull);
            expect(controller.connected, isTrue);
            expect(controller.coordinator, same(coordinator));
            expect(controller.auth, same(auth));
            expect(secrets.values[secretKey], 'original-test-secret');
          }

          secrets.failWrites = true;
          await saveSecret('new-test-secret');
          expect(controller.error, contains('secure storage'));
          expect(controller.coordinator, same(coordinator));
          expect(controller.auth, same(auth));
          expect(secrets.values[secretKey], 'original-test-secret');

          secrets.failWrites = false;
          await saveSecret(' new-test-secret ');
          expect(controller.connected, isTrue);
          expect(controller.coordinator, same(coordinator));
          expect(controller.auth, same(auth));
          expect(secrets.values[secretKey], 'new-test-secret');
        }
        expect(controller.error, isNull);
        await controller.coordinator!.syncOnce();
        expect(refreshes, 1, reason: 'Automatic start must honor Retry-After');
        expect(driveRequests, 0);
        expect(controller.coordinator!.status.phase, SyncPhase.retryWaiting);
        expect(controller.coordinator!.status.retryAt, before.retryAt);
        final resumed = jsonDecode(await savedState.readAsString()) as Map;
        expect(resumed['attempts'], 1);
        expect(resumed['retryAt'], state['retryAt']);

        await controller.retry();
        expect(controller.error, isNull);
        expect(controller.coordinator!.status.phase, SyncPhase.synced);
        expect(refreshes, 2);
        expect(driveRequests, 3);
        expect(refreshSecrets, [
          'original-test-secret',
          if (action == 'OAuth settings save')
            'new-test-secret'
          else
            'original-test-secret',
        ]);
      },
    );
  }

  test(
    'failed secure storage never produces a connected in-memory session',
    () async {
      final secrets = MemorySecrets()..failWrites = true;
      final auth = DesktopDriveAuth(
        clientId: 'client',
        secrets: secrets,
        client: MockClient((request) async {
          if (request.url.path.endsWith('/userinfo'))
            return http.Response('{"sub":"account-1"}', 200);
          return http.Response(
            jsonEncode({
              'access_token': 'private-access',
              'refresh_token': 'private-refresh',
              'expires_in': 3600,
              'token_type': 'Bearer',
              'scope': driveFileScope,
            }),
            200,
          );
        }),
      );
      await expectLater(
        auth.acceptCode(
          code: 'private-code',
          verifier: oauthRandom(),
          redirect: Uri.parse('http://127.0.0.1:1234/oauth/callback'),
        ),
        throwsA(
          isA<OAuthFailure>().having(
            (e) => e.message,
            'message',
            contains('secure storage'),
          ),
        ),
      );
      expect(auth.accountId, isNull);
      await expectLater(auth.accessToken(), throwsA(isA<OAuthFailure>()));
      auth.close();
    },
  );

  test('denied Drive scope, provider errors, mismatched client require new consent', () async {
    final secrets = MemorySecrets();
    final auth = DesktopDriveAuth(
      clientId: 'client',
      secrets: secrets,
      client: MockClient(
        (_) async => http.Response(
          '{"error":"invalid_grant","error_description":"private-code"}',
          400,
        ),
      ),
    );
    await expectLater(
      auth.acceptCode(
        code: 'private-code',
        verifier: oauthRandom(),
        redirect: Uri.parse('http://127.0.0.1:1234/oauth/callback'),
      ),
      throwsA(
        isA<OAuthFailure>().having(
          (e) => e.toString(),
          'message',
          isNot(contains('private-code')),
        ),
      ),
    );
    secrets.values['drive.desktop.credentials'] = jsonEncode({
      'clientId': 'another',
      'accountId': 'a',
      'refreshToken': 'private',
    });
    await auth.restore();
    expect(auth.accountId, isNull);
    auth.close();
  });
}
