import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:google_sign_in/google_sign_in.dart';
import 'package:google_sign_in_platform_interface/google_sign_in_platform_interface.dart'
    as google;
import 'package:http/http.dart' as http;
import 'package:saber/data/drive/drive_auth.dart';
import 'package:saber/data/drive/oauth_flow.dart';
import 'package:url_launcher/url_launcher.dart';

const calendarEventsScope = 'https://www.googleapis.com/auth/calendar.events';
const calendarListScope =
    'https://www.googleapis.com/auth/calendar.calendarlist.readonly';
const _calendarScopes = [calendarEventsScope, calendarListScope];

/// Google Calendar sign-in, separate from Drive so that Drive keeps working
/// with its own narrower scope for people who never connect the calendar.
abstract class CalendarAuth {
  bool get connected;

  /// Loads the saved connection without showing any UI.
  Future<void> restore();
  Future<void> connect();
  Future<String> accessToken();

  /// Drops the cached access token so the next [accessToken] asks again.
  Future<void> invalidateToken() async {}
  Future<void> disconnect();

  /// Lets go of what this sign-in holds open; it is not used after.
  void close() {}

  static CalendarAuth platform({
    required String androidServerClientId,
    required String desktopClientId,
    DriveSecrets secrets = const OsDriveSecrets(),
  }) {
    if (Platform.isAndroid && androidServerClientId.trim().isNotEmpty) {
      return AndroidCalendarAuth(
        androidServerClientId.trim(),
        secrets: secrets,
      );
    }
    if (Platform.isWindows && desktopClientId.trim().isNotEmpty) {
      return DesktopCalendarAuth(
        clientId: desktopClientId.trim(),
        secrets: secrets,
      );
    }
    throw const OAuthFailure(
      'Configure a Google OAuth client ID for this platform first.',
    );
  }
}

class AndroidCalendarAuth extends CalendarAuth {
  new(this.serverClientId, {required this.secrets});

  static const _accountKey = 'calendar.android.account';

  final String serverClientId;
  final DriveSecrets secrets;
  String? _accountId, _email, _lastToken;

  @override
  bool get connected => _accountId != null;

  @override
  Future<void> restore() async {
    _accountId = _email = _lastToken = null;
    try {
      final stored = await secrets.read(_accountKey);
      if (stored == null) return;
      final json = jsonDecode(stored) as Map<String, dynamic>;
      final id = json['accountId'], email = json['email'];
      if (json['clientId'] != serverClientId ||
          id is! String ||
          id.isEmpty ||
          email is! String ||
          email.isEmpty) {
        return;
      }
      _accountId = id;
      _email = email;
    } catch (_) {
      throw const OAuthFailure(
        'Could not restore the Google Calendar account.',
      );
    }
  }

  @override
  Future<void> connect() async {
    _accountId = _email = _lastToken = null;
    await ensureGoogleSignInInitialized(serverClientId);
    try {
      final account = await GoogleSignIn.instance.authenticate(
        scopeHint: _calendarScopes,
      );
      await account.authorizationClient.authorizeScopes(_calendarScopes);
      await secrets.write(
        _accountKey,
        jsonEncode({
          'clientId': serverClientId,
          'accountId': account.id,
          'email': account.email,
        }),
      );
      _accountId = account.id;
      _email = account.email;
    } on google.GoogleSignInException catch (e) {
      throw OAuthFailure('Google sign-in failed (${e.code.name}).');
    } catch (_) {
      throw const OAuthFailure(
        'Google sign-in or secure account storage failed. Reconnect the calendar.',
      );
    }
  }

  @override
  Future<String> accessToken() async {
    final id = _accountId, email = _email;
    if (id == null || email == null) {
      throw const OAuthFailure('Google Calendar sign-in required.');
    }
    try {
      await ensureGoogleSignInInitialized(serverClientId);
      final authorization = await google.GoogleSignInPlatform.instance
          .clientAuthorizationTokensForScopes(
            google.ClientAuthorizationTokensForScopesParameters(
              request: google.AuthorizationRequestDetails(
                scopes: _calendarScopes,
                userId: id,
                email: email,
                promptIfUnauthorized: false,
              ),
            ),
          );
      if (authorization == null) {
        throw const OAuthFailure(
          'Google Calendar permission required. Reconnect the calendar.',
        );
      }
      return _lastToken = authorization.accessToken;
    } on OAuthFailure {
      rethrow;
    } catch (_) {
      throw const OAuthFailure(
        'Google Calendar sign-in or permission required.',
      );
    }
  }

  @override
  Future<void> invalidateToken() async {
    final token = _lastToken;
    _lastToken = null;
    if (token == null) return;
    try {
      await google.GoogleSignInPlatform.instance.clearAuthorizationToken(
        google.ClearAuthorizationTokenParams(accessToken: token),
      );
    } catch (_) {
      throw const OAuthFailure(
        'Could not renew Google Calendar authorization.',
      );
    }
  }

  @override
  Future<void> disconnect() async {
    // GoogleSignIn.signOut would also end the Drive account session, so only
    // this feature's saved account and token are dropped.
    final token = _lastToken;
    _accountId = _email = _lastToken = null;
    await secrets.delete(_accountKey);
    if (token != null) {
      try {
        await google.GoogleSignInPlatform.instance.clearAuthorizationToken(
          google.ClearAuthorizationTokenParams(accessToken: token),
        );
      } catch (_) {}
    }
  }
}

class DesktopCalendarAuth extends CalendarAuth {
  new({
    required this.clientId,
    required this.secrets,
    http.Client? client,
    Future<bool> Function(Uri)? launch,
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null,
       _launch =
           launch ??
           ((uri) => launchUrl(uri, mode: LaunchMode.externalApplication));

  static const _credentialsKey = 'calendar.desktop.credentials';

  final String clientId;
  final DriveSecrets secrets;
  final http.Client _client;

  /// A client made here is closed here; a given one belongs to the giver.
  final bool _ownsClient;
  final Future<bool> Function(Uri) _launch;
  String? _refreshToken, _token;
  var _expires = DateTime.fromMillisecondsSinceEpoch(0);
  OAuthLoopback? _callback;

  String get _secretKey => 'calendar.desktop.secret.$clientId';

  /// The calendar signs in with Drive's OAuth client, whose secret Drive's
  /// settings store (DesktopDriveAuth.setClientSecret).
  String get _driveSecretKey => 'drive.desktop.secret.$clientId';

  /// The client's secret: one stored for the calendar, else Drive's.
  Future<String?> _clientSecret() async {
    final own = await secrets.read(_secretKey);
    if (own != null && own.isNotEmpty) return own;
    return secrets.read(_driveSecretKey);
  }

  @override
  bool get connected => _refreshToken != null;

  @override
  Future<void> restore() async {
    _refreshToken = _token = null;
    try {
      final stored = await secrets.read(_credentialsKey);
      if (stored == null) return;
      final json = jsonDecode(stored) as Map<String, dynamic>;
      final refresh = json['refreshToken'];
      if (json['clientId'] == clientId &&
          refresh is String &&
          refresh.isNotEmpty) {
        _refreshToken = refresh;
      }
    } catch (_) {
      throw const OAuthFailure(
        'Could not restore Google Calendar credentials.',
      );
    }
  }

  @override
  Future<void> connect() async {
    if (_callback != null) {
      throw const OAuthFailure('Sign-in already in progress.');
    }
    final callback = await OAuthLoopback.open();
    _callback = callback;
    final verifier = oauthRandom();
    final codeResult = callback.code.then<String>((code) => code);
    unawaited(
      codeResult.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
    try {
      final uri = Uri.https('accounts.google.com', '/o/oauth2/v2/auth', {
        'client_id': clientId,
        'redirect_uri': callback.redirect.toString(),
        'response_type': 'code',
        'scope': 'openid email ${_calendarScopes.join(' ')}',
        'state': callback.state,
        'code_challenge': pkceChallenge(verifier),
        'code_challenge_method': 'S256',
        'access_type': 'offline',
        'prompt': 'consent select_account',
      });
      if (!await _launch(uri)) {
        throw const OAuthFailure('Could not open the system browser.');
      }
      final json = await _exchange({
        'grant_type': 'authorization_code',
        'code': await codeResult,
        'code_verifier': verifier,
        'redirect_uri': callback.redirect.toString(),
      });
      final granted = (json['scope'] as String? ?? '').split(' ');
      if (!_calendarScopes.every(granted.contains)) {
        throw const OAuthFailure('Google Calendar permission was not granted.');
      }
      final refresh = json['refresh_token'];
      if (refresh is! String || refresh.isEmpty) {
        throw const OAuthFailure(
          'Offline authorization was not granted. Reconnect and grant consent.',
        );
      }
      try {
        await secrets.write(
          _credentialsKey,
          jsonEncode({'clientId': clientId, 'refreshToken': refresh}),
        );
      } catch (_) {
        throw const OAuthFailure(
          'OS secure storage could not save Google Calendar credentials.',
        );
      }
      _refreshToken = refresh;
      _remember(json);
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
      final secret = await _clientSecret();
      final response = await _client
          .post(
            Uri.https('oauth2.googleapis.com', '/token'),
            body: {
              'client_id': clientId,
              ...fields,
              if (secret != null && secret.isNotEmpty) 'client_secret': secret,
            },
          )
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) {
        throw const OAuthFailure(
          'Google authorization expired or was rejected. Reconnect the calendar.',
        );
      }
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      if (json['access_token'] is! String ||
          (json['access_token'] as String).isEmpty ||
          json['expires_in'] is! num) {
        throw const OAuthFailure(
          'Google returned an invalid authorization response.',
        );
      }
      return json;
    } on OAuthFailure {
      rethrow;
    } catch (_) {
      throw const OAuthFailure(
        'Calendar authorization unavailable. Check connection and OS secure storage.',
      );
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
    final refresh = _refreshToken;
    if (refresh == null) {
      throw const OAuthFailure('Google Calendar sign-in required.');
    }
    final token = _token;
    if (token != null &&
        DateTime.now().add(const Duration(seconds: 60)).isBefore(_expires)) {
      return token;
    }
    final json = await _exchange({
      'grant_type': 'refresh_token',
      'refresh_token': refresh,
    });
    _remember(json);
    return _token!;
  }

  @override
  Future<void> invalidateToken() async => _token = null;

  @override
  Future<void> disconnect() async {
    _refreshToken = _token = null;
    await _callback?.cancel();
    await secrets.delete(_credentialsKey);
  }

  @override
  void close() {
    if (_ownsClient) _client.close();
  }
}
