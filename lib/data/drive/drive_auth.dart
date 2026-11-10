import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:google_sign_in_platform_interface/google_sign_in_platform_interface.dart'
    as google;
import 'package:http/http.dart' as http;
import 'package:ink_vault_core/drive.dart'
    show
        DriveUploadSessions,
        RemoteException,
        RemoteFailure,
        parseDriveRetryAfter;
import 'package:saber/data/drive/oauth_flow.dart';
import 'package:url_launcher/url_launcher.dart';

const driveFileScope = 'https://www.googleapis.com/auth/drive.file';

abstract interface class DriveSecrets {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class OsDriveSecrets implements DriveSecrets {
  final FlutterSecureStorage storage;
  const new([this.storage = const FlutterSecureStorage()]);
  @override
  Future<String?> read(String key) => storage.read(key: key);
  @override
  Future<void> write(String key, String value) =>
      storage.write(key: key, value: value);
  @override
  Future<void> delete(String key) => storage.delete(key: key);
}

class SecureDriveUploadSessions implements DriveUploadSessions {
  final DriveSecrets _secrets;
  final String _key;

  new({
    required String accountId,
    required String folderId,
    required String deviceId,
    this._secrets = const OsDriveSecrets(),
  }) : _key =
           'drive.upload-session.v1.'
           '${sha256.convert(utf8.encode(jsonEncode([accountId, folderId, deviceId])))}';

  @override
  Future<String?> read() => _secrets.read(_key);

  @override
  Future<void> write(String value) => _secrets.write(_key, value);

  @override
  Future<void> clear() => _secrets.delete(_key);
}

abstract class DriveAuth {
  String? get accountId;
  Future<void> restore();
  Future<void> restoreForSync() => restore();
  Future<void> signIn();
  Future<String> accessToken();
  Future<void> invalidateToken() async {}
  Future<void> signOut();
  Future<void> cancel();
  void close();

  static DriveAuth platform({
    required String androidServerClientId,
    required String desktopClientId,
    DriveSecrets secrets = const OsDriveSecrets(),
  }) {
    if (Platform.isAndroid && androidServerClientId.trim().isNotEmpty) {
      return AndroidDriveAuth(androidServerClientId.trim(), secrets: secrets);
    }
    if (Platform.isWindows && desktopClientId.trim().isNotEmpty) {
      return DesktopDriveAuth(
        clientId: desktopClientId.trim(),
        secrets: secrets,
      );
    }
    throw const OAuthFailure(
      'Configure a Google OAuth client ID for this platform first.',
    );
  }
}

class AndroidDriveAuth extends DriveAuth {
  final String serverClientId;
  final DriveSecrets secrets;
  final GoogleSignIn _google = GoogleSignIn.instance;
  String? _accountId, _email, _lastToken;
  var _initialized = false;
  // The platform singleton must be initialized exactly once per Flutter engine.
  static Future<void>? _initialization;
  static String? _initializedClient;
  new(this.serverClientId, {this.secrets = const OsDriveSecrets()});
  @override
  String? get accountId => _accountId;
  Future<void> _initialize() async {
    if (_initialized) return;
    if (_initializedClient != null && _initializedClient != serverClientId) {
      throw const OAuthFailure(
        'Restart the app after changing the Android OAuth client ID.',
      );
    }
    _initializedClient = serverClientId;
    try {
      await (_initialization ??= _google.initialize(
        serverClientId: serverClientId,
      ));
      _initialized = true;
    } catch (_) {
      _initialization = null;
      throw const OAuthFailure('Android Google Sign-In configuration failed.');
    }
  }

  @override
  Future<void> restore() => _restore(authorize: true);

  @override
  Future<void> restoreForSync() => _restore(authorize: false);

  Future<void> _restore({required bool authorize}) async {
    _accountId = _email = _lastToken = null;
    try {
      final stored = await secrets.read('drive.android.account');
      if (stored == null) return;
      final json = jsonDecode(stored) as Map<String, dynamic>;
      if (json['clientId'] != serverClientId) return;
      final id = json['accountId'], email = json['email'];
      if (id is! String || id.isEmpty || email is! String || email.isEmpty) {
        throw const FormatException();
      }
      if (authorize) {
        await _initialize();
        // Account-bound authorization does not open the account chooser.
        await _authorize(id, email);
      }
      _accountId = id;
      _email = email;
    } on google.GoogleSignInException catch (e) {
      throw OAuthFailure(
        'Google sign-in required (${e.code.name}). Open Drive settings to reconnect.',
      );
    } on OAuthFailure {
      rethrow;
    } catch (_) {
      throw const OAuthFailure(
        'Could not restore the saved Google account. Open Drive settings to reconnect.',
      );
    }
  }

  @override
  Future<void> signIn() async {
    _accountId = _email = _lastToken = null;
    await _initialize();
    try {
      final account = await _google.authenticate(scopeHint: [driveFileScope]);
      await account.authorizationClient.authorizeScopes([driveFileScope]);
      await secrets.write(
        'drive.android.account',
        jsonEncode({
          'clientId': serverClientId,
          'accountId': account.id,
          'email': account.email,
        }),
      );
      _accountId = account.id;
      _email = account.email;
    } on google.GoogleSignInException catch (e) {
      throw OAuthFailure(
        'Google sign-in failed (${e.code.name}). Check the account and Android OAuth settings.',
      );
    } catch (_) {
      throw const OAuthFailure(
        'Google sign-in or secure account storage failed. Reconnect Drive.',
      );
    }
  }

  Future<String> _authorize(String id, String email) async {
    final authorization = await google.GoogleSignInPlatform.instance
        .clientAuthorizationTokensForScopes(
          google.ClientAuthorizationTokensForScopesParameters(
            request: google.AuthorizationRequestDetails(
              scopes: const [driveFileScope],
              userId: id,
              email: email,
              promptIfUnauthorized: false,
            ),
          ),
        );
    if (authorization == null) {
      throw const OAuthFailure(
        'Google Drive permission required. Open Drive settings to reconnect.',
      );
    }
    _lastToken = authorization.accessToken;
    return authorization.accessToken;
  }

  @override
  Future<String> accessToken() async {
    final id = _accountId, email = _email;
    if (id == null || email == null) {
      throw const OAuthFailure('Google Drive sign-in required.');
    }
    try {
      await _initialize();
      return await _authorize(id, email);
    } on google.GoogleSignInException catch (e) {
      throw OAuthFailure(
        'Google Drive sign-in or permission required (${e.code.name}).',
      );
    } on OAuthFailure {
      rethrow;
    } catch (_) {
      throw const OAuthFailure('Google Drive sign-in or permission required.');
    }
  }

  @override
  Future<void> invalidateToken() async {
    final token = _lastToken;
    _lastToken = null;
    if (token != null) {
      try {
        await google.GoogleSignInPlatform.instance.clearAuthorizationToken(
          google.ClearAuthorizationTokenParams(accessToken: token),
        );
      } catch (_) {
        throw const OAuthFailure(
          'Could not renew Google Drive authorization. Reconnect Drive.',
        );
      }
    }
  }

  @override
  Future<void> signOut() async {
    _accountId = _email = _lastToken = null;
    await secrets.delete('drive.android.account');
    await _initialize();
    await _google.signOut();
  }

  @override
  Future<void> cancel() async {
    /* Native account chooser owns its cancel action. */
  }
  @override
  void close() {}
}

class DesktopDriveAuth extends DriveAuth {
  static const _credentialsKey = 'drive.desktop.credentials';
  final String clientId;
  final DriveSecrets secrets;
  final http.Client _client;
  final Future<bool> Function(Uri) _launch;
  String? _accountId;
  String? _refreshToken;
  String? _token;
  var _expires = DateTime.fromMillisecondsSinceEpoch(0);
  OAuthLoopback? _callback;
  Future<String>? _refreshing;
  var _credentialStore = Future<void>.value();
  var _sessionGeneration = 0;
  var _checkingCredentials = false;
  new({
    required this.clientId,
    required this.secrets,
    http.Client? client,
    Future<bool> Function(Uri)? launch,
  }) : _client = client ?? http.Client(),
       _launch =
           launch ??
           ((uri) => launchUrl(uri, mode: LaunchMode.externalApplication));
  @override
  String? get accountId => _checkingCredentials ? null : _accountId;
  String get _secretKey => 'drive.desktop.secret.$clientId';
  Future<void> setClientSecret(String value) async {
    try {
      if (value.isEmpty) {
        await secrets.delete(_secretKey);
      } else {
        await secrets.write(_secretKey, value);
      }
    } catch (_) {
      throw const OAuthFailure(
        'OS secure storage could not save the desktop client credential.',
      );
    }
  }

  // Serialize local credential mutations so an earlier refresh write cannot
  // finish after a newer sign-in or recreate credentials after sign-out.
  Future<T> _withCredentialStore<T>(Future<T> Function() action) {
    final operation = _credentialStore.then((_) => action());
    _credentialStore = operation.then<void>((_) {}, onError: (Object _) {});
    return operation;
  }

  int _beginSessionChange({bool checking = false}) {
    _refreshing = null;
    _checkingCredentials = checking;
    return ++_sessionGeneration;
  }

  void _requireCurrentSession(int generation) {
    if (generation != _sessionGeneration) {
      throw const OAuthFailure('Drive credentials changed. Retry the operation.');
    }
  }

  void _clearCredentials() => _accountId = _refreshToken = _token = null;

  Future<void> _saveCredentials(int generation, String id, String refresh) =>
      _withCredentialStore(() async {
        if (generation != _sessionGeneration) return;
        await secrets.write(
          _credentialsKey,
          jsonEncode({
            'clientId': clientId,
            'accountId': id,
            'refreshToken': refresh,
          }),
        );
      });

  @override
  Future<void> restore() async {
    final generation = _beginSessionChange(checking: true);
    try {
      final stored = await _withCredentialStore(() => secrets.read(_credentialsKey));
      _requireCurrentSession(generation);
      if (stored == null) {
        _clearCredentials();
        return;
      }
      final json = jsonDecode(stored) as Map<String, dynamic>;
      if (json['clientId'] != clientId) {
        _clearCredentials();
        return;
      }
      final id = json['accountId'];
      final refresh = json['refreshToken'];
      if (id is! String || id.isEmpty || refresh is! String || refresh.isEmpty)
        throw const FormatException();
      if (id != _accountId || refresh != _refreshToken) _token = null;
      _accountId = id;
      _refreshToken = refresh;
    } catch (_) {
      _requireCurrentSession(generation);
      _clearCredentials();
      throw const OAuthFailure(
        'OS secure storage could not restore Drive credentials.',
      );
    } finally {
      if (generation == _sessionGeneration) _checkingCredentials = false;
    }
  }

  @override
  Future<void> signIn() async {
    if (_callback != null)
      throw const OAuthFailure('Sign-in already in progress.');
    final callback = await OAuthLoopback.open();
    _callback = callback;
    final verifier = oauthRandom();
    // Attach an error handler before opening a browser (cancel can occur there).
    final codeResult = callback.code.then<String>((code) => code);
    unawaited(
      codeResult.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
    try {
      final uri = Uri.https('accounts.google.com', '/o/oauth2/v2/auth', {
        'client_id': clientId,
        'redirect_uri': callback.redirect.toString(),
        'response_type': 'code',
        'scope': 'openid email $driveFileScope',
        'state': callback.state,
        'code_challenge': pkceChallenge(verifier),
        'code_challenge_method': 'S256',
        'access_type': 'offline',
        'prompt': 'consent select_account',
      });
      if (!await _launch(uri))
        throw const OAuthFailure('Could not open the system browser.');
      final code = await codeResult;
      await acceptCode(
        code: code,
        verifier: verifier,
        redirect: callback.redirect,
      );
    } on OAuthFailure {
      rethrow;
    } catch (_) {
      throw const OAuthFailure(
        'Desktop sign-in failed. Check OAuth configuration and connection.',
      );
    } finally {
      await callback.close();
      _callback = null;
    }
  }

  Future<Map<String, dynamic>> _exchange(
    Map<String, String> fields, {
    bool forRefresh = false,
  }) async {
    try {
      final secret = await secrets.read(_secretKey);
      final request = http.Request(
        'POST',
        Uri.https('oauth2.googleapis.com', '/token'),
      )..followRedirects = false;
      request.bodyFields = {
        'client_id': clientId,
        ...fields,
        if (secret != null && secret.isNotEmpty) 'client_secret': secret,
      };
      final http.Response response;
      try {
        response = await http.Response.fromStream(
          await _client.send(request).timeout(const Duration(seconds: 30)),
        ).timeout(const Duration(seconds: 30));
      } catch (error) {
        if (forRefresh &&
            (error is TimeoutException || error is http.ClientException || error is IOException)) {
          throw RemoteException.retryable('Drive token refresh interrupted');
        }
        rethrow;
      }
      final status = response.statusCode;
      if (status != 200) {
        if (forRefresh && (status == 408 || status == 429 || status >= 500 && status < 600)) {
          throw RemoteException(
            RemoteFailure.retryable,
            'Drive token refresh temporarily unavailable',
            statusCode: status,
            retryAfter: parseDriveRetryAfter(
              response.headers['retry-after'],
              maxDelay: const Duration(days: 1),
            ),
          );
        }
        throw const OAuthFailure(
          'Google authorization expired or was rejected. Reconnect Drive.',
        );
      }
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      if (json['access_token'] is! String ||
          (json['access_token'] as String).isEmpty ||
          json['token_type'] != 'Bearer' ||
          json['expires_in'] is! num ||
          (json['expires_in'] as num) <= 0) {
        throw const OAuthFailure(
          'Google returned an invalid authorization response.',
        );
      }
      return json;
    } on OAuthFailure {
      rethrow;
    } on RemoteException {
      rethrow;
    } catch (_) {
      throw const OAuthFailure(
        'Drive authorization unavailable. Check connection and OS secure storage.',
      );
    }
  }

  Future<void> acceptCode({
    required String code,
    required String verifier,
    required Uri redirect,
  }) async {
    final previous = _sessionGeneration;
    final json = await _exchange({
      'grant_type': 'authorization_code',
      'code': code,
      'code_verifier': verifier,
      'redirect_uri': redirect.toString(),
    });
    if (!(json['scope'] as String? ?? '').split(' ').contains(driveFileScope))
      throw const OAuthFailure('Google Drive permission was not granted.');
    final refresh = json['refresh_token'];
    if (refresh is! String || refresh.isEmpty)
      throw const OAuthFailure(
        'Offline authorization was not granted. Reconnect Drive and grant consent.',
      );
    String id;
    try {
      final request = http.Request(
        'GET',
        Uri.https('openidconnect.googleapis.com', '/v1/userinfo'),
      )..followRedirects = false;
      request.headers['authorization'] = 'Bearer ${json['access_token']}';
      final response = await http.Response.fromStream(
        await _client.send(request).timeout(const Duration(seconds: 30)),
      ).timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) throw const FormatException();
      id = (jsonDecode(response.body) as Map<String, dynamic>)['sub'] as String;
      if (id.isEmpty) throw const FormatException();
    } catch (_) {
      throw const OAuthFailure(
        'Could not verify the signed-in Google account.',
      );
    }
    _requireCurrentSession(previous);
    final generation = _beginSessionChange(checking: true);
    try {
      try {
        await _saveCredentials(generation, id, refresh);
      } catch (_) {
        throw const OAuthFailure(
          'OS secure storage could not save Drive credentials. Sign-in was not completed.',
        );
      }
      _requireCurrentSession(generation);
      _accountId = id;
      _refreshToken = refresh;
      _remember(json);
    } finally {
      if (generation == _sessionGeneration) _checkingCredentials = false;
    }
  }

  void _remember(Map<String, dynamic> json) {
    _token = json['access_token'] as String;
    _expires = DateTime.now().add(
      Duration(seconds: (json['expires_in'] as num).toInt()),
    );
  }

  @override
  Future<String> accessToken() async {
    final id = accountId;
    final refresh = _refreshToken;
    if (id == null || refresh == null)
      throw const OAuthFailure('Google sign-in required.');
    if (_token != null &&
        DateTime.now().add(const Duration(seconds: 60)).isBefore(_expires))
      return _token!;
    final existing = _refreshing;
    if (existing != null) return existing;
    late final Future<String> pending;
    pending = _refresh(_sessionGeneration, id, refresh).whenComplete(() {
      if (identical(_refreshing, pending)) _refreshing = null;
    });
    return _refreshing = pending;
  }

  Future<String> _refresh(int generation, String id, String refresh) async {
    final Map<String, dynamic> json;
    try {
      json = await _exchange({
        'grant_type': 'refresh_token',
        'refresh_token': refresh,
      }, forRefresh: true);
    } catch (_) {
      _requireCurrentSession(generation);
      rethrow;
    }
    _requireCurrentSession(generation);
    final rotated = json['refresh_token'];
    if (rotated is String && rotated.isNotEmpty && rotated != refresh) {
      try {
        await _saveCredentials(generation, id, rotated);
      } catch (_) {
        throw const OAuthFailure(
          'OS secure storage could not save renewed Drive credentials.',
        );
      }
      _requireCurrentSession(generation);
      _refreshToken = rotated;
    }
    _remember(json);
    return _token!;
  }

  @override
  Future<void> invalidateToken() async {
    _token = null;
  }

  @override
  Future<void> signOut() async {
    _beginSessionChange();
    _clearCredentials();
    try {
      await _withCredentialStore(() async {
        await cancel();
        await secrets.delete(_credentialsKey);
      });
    } catch (_) {
      throw const OAuthFailure(
        'OS secure storage could not remove Drive credentials.',
      );
    }
  }

  @override
  Future<void> cancel() async {
    await _callback?.cancel();
  }

  @override
  void close() {
    _beginSessionChange();
    _clearCredentials();
    unawaited(_callback?.cancel() ?? Future.value());
    _client.close();
  }
}
