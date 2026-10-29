import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:saber/data/drive/oauth_flow.dart';

void main() {
  test('PKCE uses RFC 7636 S256 vector and fresh secure state', () {
    expect(
      pkceChallenge('dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk'),
      'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM',
    );
    expect(oauthRandom(), isNot(oauthRandom()));
    expect(oauthRandom().length, greaterThanOrEqualTo(43));
  });

  test('loopback ignores wrong method, host, path, state and duplicates', () async {
    final callback = await OAuthLoopback.open(
      timeout: const Duration(seconds: 2),
    );
    final client = HttpClient();
    addTearDown(client.close);
    final result = callback.code;
    Future<int> send(String path, {String method = 'GET', String? host}) async {
      final req = await client.openUrl(
        method,
        callback.redirect.replace(
          path: path.split('?').first,
          query: path.contains('?') ? path.split('?').last : '',
        ),
      );
      if (host != null) req.headers.set('host', host);
      final response = await req.close();
      await response.drain<void>();
      return response.statusCode;
    }

    expect(await send('/other?state=${callback.state}&code=secret'), 400);
    expect(await send('/oauth/callback?state=wrong&code=secret'), 400);
    expect(
      await send(
        '/oauth/callback?state=${callback.state}&code=secret',
        method: 'POST',
      ),
      400,
    );
    expect(
      await send(
        '/oauth/callback?state=${callback.state}&code=secret',
        host: 'evil.test',
      ),
      400,
    );
    expect(
      await send(
        '/oauth/callback?state=${callback.state}&state=${callback.state}&code=secret',
      ),
      400,
    );
    expect(
      await send('/oauth/callback?state=${callback.state}&code=valid-code'),
      200,
    );
    expect(await result, 'valid-code');
    await callback.close();
  });

  test(
    'cancel and timeout terminate callback without exposing codes',
    () async {
      final callback = await OAuthLoopback.open();
      final expected = expectLater(
        callback.code,
        throwsA(
          isA<OAuthFailure>().having(
            (e) => e.message,
            'message',
            'Sign-in cancelled',
          ),
        ),
      );
      await callback.cancel();
      await expected;
      final timeout = await OAuthLoopback.open(
        timeout: const Duration(milliseconds: 15),
      );
      await expectLater(timeout.code, throwsA(isA<OAuthFailure>()));
      await timeout.close();
    },
  );
}
