import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

class OAuthFailure implements Exception {
  final String message;
  const new(this.message);
  @override
  String toString() => message;
}

String oauthRandom() =>
    base64UrlEncode(List<int>.generate(32, (_) => Random.secure().nextInt(256)))
        .replaceAll('=', '');
String pkceChallenge(String verifier) =>
    base64UrlEncode(sha256.convert(ascii.encode(verifier)).bytes)
        .replaceAll('=', '');

/// A single-use listener bound only to an ephemeral IPv4 loopback port.
class OAuthLoopback {
  final HttpServer _server;
  final String state = oauthRandom();
  final _code = Completer<String>();
  late final Timer _timer;
  late final Uri redirect = Uri.parse(
    'http://127.0.0.1:${_server.port}/oauth/callback',
  );
  Future<String> get code => _code.future;
  new _(this._server, Duration timeout) {
    _timer = Timer(timeout, () {
      if (!_code.isCompleted)
        _code.completeError(const OAuthFailure('Sign-in timed out'));
      unawaited(close());
    });
    _server.listen(_request);
  }
  static Future<OAuthLoopback> open({
    Duration timeout = const Duration(minutes: 3),
  }) async => OAuthLoopback._(
    await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    timeout,
  );
  Future<void> _request(HttpRequest request) async {
    final q = request.uri.queryParametersAll;
    final host = request.headers.value(HttpHeaders.hostHeader);
    final valid =
        !_code.isCompleted &&
        request.method == 'GET' &&
        host == '127.0.0.1:${_server.port}' &&
        request.uri.path == redirect.path &&
        q['state']?.length == 1 &&
        q['state']!.single == state &&
        ((q['code']?.length == 1 &&
                q['code']!.single.isNotEmpty &&
                !q.containsKey('error')) ||
            (q['error']?.length == 1 && !q.containsKey('code')));
    request.response.statusCode = valid ? 200 : 400;
    request.response.headers.set('cache-control', 'no-store');
    request.response.headers.set('content-type', 'text/plain; charset=utf-8');
    request.response.headers.set(
      'content-security-policy',
      "default-src 'none'",
    );
    request.response.write(
      valid ? 'Return to Personal Ink Vault.' : 'Invalid sign-in response.',
    );
    await request.response.close();
    if (valid) {
      _timer.cancel();
      if (q.containsKey('error')) {
        _code.completeError(
          const OAuthFailure('Sign-in cancelled or permission denied'),
        );
      } else {
        _code.complete(q['code']!.single);
      }
    }
  }

  Future<void> cancel() async {
    if (!_code.isCompleted)
      _code.completeError(const OAuthFailure('Sign-in cancelled'));
    await close();
  }

  Future<void> close() async {
    _timer.cancel();
    await _server.close(force: true);
  }
}
