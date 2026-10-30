import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in_platform_interface/google_sign_in_platform_interface.dart';
import 'package:saber/data/drive/drive_auth.dart';
import 'package:saber/data/drive/oauth_flow.dart';

const clientId = 'android-web-test-client';
const identityKey = 'drive.android.account';

class AndroidSignInPlatform extends GoogleSignInPlatform {
  final requests = <AuthorizationRequestDetails>[];
  final cleared = <String>[];
  var lightweightCalls = 0, authenticateCalls = 0, signOutCalls = 0;
  var authorized = true, headless = false;
  GoogleSignInException? failure;

  void reset() {
    requests.clear();
    cleared.clear();
    lightweightCalls = authenticateCalls = signOutCalls = 0;
    authorized = true;
    headless = false;
    failure = null;
  }

  @override
  Future<void> init(InitParameters params) async {}
  @override
  Future<AuthenticationResults?> attemptLightweightAuthentication(
    AttemptLightweightAuthenticationParameters params,
  ) async {
    lightweightCalls++;
    if (headless) {
      throw const GoogleSignInException(
        code: GoogleSignInExceptionCode.uiUnavailable,
      );
    }
    return null;
  }

  @override
  Future<AuthenticationResults> authenticate(
    AuthenticateParameters params,
  ) async {
    authenticateCalls++;
    if (failure case final error?) throw error;
    return const AuthenticationResults(
      user: GoogleSignInUserData(id: 'account-a', email: 'a@example.test'),
      authenticationTokens: AuthenticationTokenData(idToken: null),
    );
  }

  @override
  Future<ClientAuthorizationTokenData?> clientAuthorizationTokensForScopes(
    ClientAuthorizationTokensForScopesParameters params,
  ) async {
    requests.add(params.request);
    if (failure case final error?) throw error;
    if (!authorized) return null;
    return const ClientAuthorizationTokenData(
      accessToken: 'native-cache-token',
    );
  }

  @override
  Future<void> clearAuthorizationToken(
    ClearAuthorizationTokenParams params,
  ) async {
    cleared.add(params.accessToken);
  }

  @override
  bool supportsAuthenticate() => true;
  @override
  bool authorizationRequiresUserInteraction() => false;
  @override
  Future<void> signOut(SignOutParams params) async => signOutCalls++;
  @override
  Future<void> disconnect(DisconnectParams params) async {}
  @override
  Future<ServerAuthorizationTokenData?> serverAuthorizationTokensForScopes(
    ServerAuthorizationTokensForScopesParameters params,
  ) => throw UnimplementedError();
}

class UnwritableSecrets implements DriveSecrets {
  @override
  Future<String?> read(String key) async => null;
  @override
  Future<void> write(String key, String value) =>
      throw StateError('unavailable');
  @override
  Future<void> delete(String key) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final native = AndroidSignInPlatform();
  final previous = GoogleSignInPlatform.instance;
  setUpAll(() => GoogleSignInPlatform.instance = native);
  tearDownAll(() => GoogleSignInPlatform.instance = previous);
  setUp(() {
    native.reset();
    FlutterSecureStorage.setMockInitialValues({});
  });

  Future<void> saveIdentity({String client = clientId}) =>
      const FlutterSecureStorage().write(
        key: identityKey,
        value: jsonEncode({
          'clientId': client,
          'accountId': 'account-a',
          'email': 'a@example.test',
        }),
      );

  test('fresh install restore never opens an account chooser', () async {
    final auth = AndroidDriveAuth(clientId);
    await auth.restore();
    expect(auth.accountId, isNull);
    expect(native.lightweightCalls, 0);
    expect(native.authenticateCalls, 0);
    expect(native.requests, isEmpty);
  });

  test('headless restore silently authorizes the saved account only', () async {
    await saveIdentity();
    native.headless = true;
    final auth = AndroidDriveAuth(clientId);
    await auth.restore();
    expect(auth.accountId, 'account-a');
    expect(await auth.accessToken(), 'native-cache-token');
    expect(native.lightweightCalls, 0);
    expect(native.authenticateCalls, 0);
    expect(native.requests, isNotEmpty);
    for (final request in native.requests) {
      expect(request.userId, 'account-a');
      expect(request.email, 'a@example.test');
      expect(request.scopes, [driveFileScope]);
      expect(request.promptIfUnauthorized, isFalse);
    }
    await auth.invalidateToken();
    expect(native.cleared, ['native-cache-token']);
  });

  test('explicit sign-in stores account identity without tokens', () async {
    final auth = AndroidDriveAuth(clientId);
    await auth.signIn();
    expect(auth.accountId, 'account-a');
    expect(native.authenticateCalls, 1);
    expect(native.requests.single.promptIfUnauthorized, isTrue);
    final saved = await const FlutterSecureStorage().read(key: identityKey);
    expect(saved, isNotNull);
    expect(jsonDecode(saved!), {
      'clientId': clientId,
      'accountId': 'account-a',
      'email': 'a@example.test',
    });
    expect(saved, isNot(contains('native-cache-token')));
    await auth.signOut();
    expect(auth.accountId, isNull);
    expect(await const FlutterSecureStorage().read(key: identityKey), isNull);
  });

  test('revoked permission cannot trust saved identity or prompt', () async {
    await saveIdentity();
    native.authorized = false;
    final auth = AndroidDriveAuth(clientId);
    await expectLater(auth.restore(), throwsA(isA<OAuthFailure>()));
    expect(auth.accountId, isNull);
    expect(native.lightweightCalls, 0);
    expect(native.authenticateCalls, 0);
    expect(native.requests.single.promptIfUnauthorized, isFalse);
    expect(
      await const FlutterSecureStorage().read(key: identityKey),
      isNotNull,
    );
  });

  test('identity from another client does not authorize', () async {
    await saveIdentity(client: 'other-client');
    final auth = AndroidDriveAuth(clientId);
    await auth.restore();
    expect(auth.accountId, isNull);
    expect(native.requests, isEmpty);
    expect(native.lightweightCalls, 0);
  });

  test('malformed saved identity cannot select an unbound account', () async {
    await const FlutterSecureStorage().write(
      key: identityKey,
      value: jsonEncode({'clientId': clientId, 'accountId': 'account-a'}),
    );
    final auth = AndroidDriveAuth(clientId);
    await expectLater(auth.restore(), throwsA(isA<OAuthFailure>()));
    expect(auth.accountId, isNull);
    expect(native.requests, isEmpty);
    expect(native.lightweightCalls, 0);
  });

  test(
    'failed secure save cannot report a restorable signed-in account',
    () async {
      final auth = AndroidDriveAuth(clientId, secrets: UnwritableSecrets());
      await expectLater(auth.signIn(), throwsA(isA<OAuthFailure>()));
      expect(auth.accountId, isNull);
      expect(await const FlutterSecureStorage().read(key: identityKey), isNull);
    },
  );

  test('native errors expose a diagnostic code without payload', () async {
    native.failure = const GoogleSignInException(
      code: GoogleSignInExceptionCode.clientConfigurationError,
      description: 'never-expose-native-payload',
      details: 'secret-detail',
    );
    await expectLater(
      AndroidDriveAuth(clientId).signIn(),
      throwsA(
        isA<OAuthFailure>()
            .having(
              (e) => e.message,
              'code',
              contains('clientConfigurationError'),
            )
            .having(
              (e) => e.message,
              'payload',
              isNot(contains('never-expose')),
            )
            .having(
              (e) => e.message,
              'details',
              isNot(contains('secret-detail')),
            ),
      ),
    );
  });
}
