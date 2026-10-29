import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:saber/data/drive/drive_auth.dart';
import 'package:saber/data/drive/oauth_flow.dart';

class MemorySecrets implements DriveSecrets {
  final values = <String, String>{};
  var failWrites = false;
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    if (failWrites) throw StateError('OS secure storage unavailable');
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async => values.remove(key);
}

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
    expect(await auth.accessToken(), 'fresh-access');
    expect(requests, 1);
    await auth.signOut();
    expect(secrets.values['drive.desktop.credentials'], isNull);
    await expectLater(auth.accessToken(), throwsA(isA<OAuthFailure>()));
    auth.close();
  });

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
