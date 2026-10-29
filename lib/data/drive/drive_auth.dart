import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
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

abstract class DriveAuth {
  String? get accountId;
  Future<void> restore();
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
      return AndroidDriveAuth(androidServerClientId.trim());
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
  final GoogleSignIn _google = GoogleSignIn.instance;
  GoogleSignInAccount? _account;
  String? _lastToken;
  var _initialized = false;
  // The platform singleton must be initialized exactly once per Flutter engine.
  static Future<void>? _initialization;
  static String? _initializedClient;
  new(this.serverClientId);
  @override
  String? get accountId => _account?.id;
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
  Future<void> restore() async {
    await _initialize();
    try {
      _account = await _google.attemptLightweightAuthentication();
    } catch (_) {
      _account = null;
      throw const OAuthFailure(
        'Google sign-in required. Open Drive settings to reconnect.',
      );
    }
  }

  @override
  Future<void> signIn() async {
    await _initialize();
    try {
      final account = await _google.authenticate(scopeHint: [driveFileScope]);
      await account.authorizationClient.authorizeScopes([driveFileScope]);
      _account = account;
    } catch (_) {
      _account = null;
      throw const OAuthFailure(
        'Sign-in cancelled, permission denied, or Android OAuth configuration invalid.',
      );
    }
  }

  @override
  Future<String> accessToken() async {
    try {
      final authorization = await _account?.authorizationClient
          .authorizationForScopes([driveFileScope]);
      if (authorization == null)
        throw const OAuthFailure('Google Drive permission required.');
      _lastToken = authorization.accessToken;
      return authorization.accessToken;
    } catch (_) {
      throw const OAuthFailure('Google Drive sign-in or permission required.');
    }
  }

  @override
  Future<void> invalidateToken() async {
    final token = _lastToken;
    _lastToken = null;
    if (token != null && _account != null) {
      try {
        await _account!.authorizationClient.clearAuthorizationToken(
          accessToken: token,
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
    await _initialize();
    await _google.signOut();
    _account = null;
  }

  @override
  Future<void> cancel() async {
    /* Native account chooser owns its cancel action. */
  }
  @override
  void close() {}
}

class DesktopDriveAuth extends DriveAuth {
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
  String? get accountId => _accountId;
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

  @override
  Future<void> restore() async {
    try {
      final stored = await secrets.read('drive.desktop.credentials');
      if (stored == null) return;
      final json = jsonDecode(stored) as Map<String, dynamic>;
      if (json['clientId'] != clientId) return;
      final id = json['accountId'];
      final refresh = json['refreshToken'];
      if (id is! String || id.isEmpty || refresh is! String || refresh.isEmpty)
        throw const FormatException();
      _accountId = id;
      _refreshToken = refresh;
    } catch (_) {
      throw const OAuthFailure(
        'OS secure storage could not restore Drive credentials.',
      );
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

  Future<Map<String, dynamic>> _exchange(Map<String, String> fields) async {
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
      final response = await http.Response.fromStream(
        await _client.send(request).timeout(const Duration(seconds: 30)),
      ).timeout(const Duration(seconds: 30));
      if (response.statusCode != 200)
        throw const OAuthFailure(
          'Google authorization expired or was rejected. Reconnect Drive.',
        );
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
    try {
      await secrets.write(
        'drive.desktop.credentials',
        jsonEncode({
          'clientId': clientId,
          'accountId': id,
          'refreshToken': refresh,
        }),
      );
    } catch (_) {
      throw const OAuthFailure(
        'OS secure storage could not save Drive credentials. Sign-in was not completed.',
      );
    }
    _accountId = id;
    _refreshToken = refresh;
    _remember(json);
  }

  void _remember(Map<String, dynamic> json) {
    _token = json['access_token'] as String;
    _expires = DateTime.now().add(
      Duration(seconds: (json['expires_in'] as num).toInt()),
    );
  }

  @override
  Future<String> accessToken() async {
    if (_refreshToken == null || _accountId == null)
      throw const OAuthFailure('Google sign-in required.');
    if (_token != null &&
        DateTime.now().add(const Duration(seconds: 60)).isBefore(_expires))
      return _token!;
    return _refreshing ??= _refresh().whenComplete(() => _refreshing = null);
  }

  Future<String> _refresh() async {
    final json = await _exchange({
      'grant_type': 'refresh_token',
      'refresh_token': _refreshToken!,
    });
    final rotated = json['refresh_token'];
    if (rotated is String && rotated.isNotEmpty && rotated != _refreshToken) {
      try {
        await secrets.write(
          'drive.desktop.credentials',
          jsonEncode({
            'clientId': clientId,
            'accountId': _accountId,
            'refreshToken': rotated,
          }),
        );
      } catch (_) {
        throw const OAuthFailure(
          'OS secure storage could not save renewed Drive credentials.',
        );
      }
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
    await cancel();
    try {
      await secrets.delete('drive.desktop.credentials');
    } catch (_) {
      throw const OAuthFailure(
        'OS secure storage could not remove Drive credentials.',
      );
    }
    _accountId = null;
    _refreshToken = null;
    _token = null;
  }

  @override
  Future<void> cancel() async {
    await _callback?.cancel();
  }

  @override
  void close() {
    unawaited(_callback?.cancel() ?? Future.value());
    _client.close();
  }
}
