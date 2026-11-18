import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:saber/data/drive/drive_auth.dart';
import 'package:saber/data/planner/calendar_auth.dart';

/// The OS secure store, in memory.
class _Secrets implements DriveSecrets {
  final values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the desktop calendar signs in with the client secret Drive stored '
      'for the same client', () async {
    final secrets = _Secrets()
      ..values['calendar.desktop.credentials'] = jsonEncode({
        'clientId': 'client',
        'refreshToken': 'refresh',
      });
    // Drive's settings keep the desktop client's secret (drive_connection).
    final drive = DesktopDriveAuth(
      clientId: 'client',
      secrets: secrets,
      client: MockClient((_) async => http.Response('', 500)),
    );
    await drive.setClientSecret('drive-secret');
    drive.close();

    final sent = <Map<String, String>>[];
    final calendar = DesktopCalendarAuth(
      clientId: 'client',
      secrets: secrets,
      client: MockClient((request) async {
        sent.add(request.bodyFields);
        return http.Response(
          jsonEncode({'access_token': 'access', 'expires_in': 3600}),
          200,
        );
      }),
    );
    addTearDown(calendar.close);
    await calendar.restore();
    expect(calendar.connected, isTrue);
    expect(await calendar.accessToken(), 'access');
    expect(sent.single['grant_type'], 'refresh_token');
    expect(sent.single['client_id'], 'client');
    expect(sent.single['client_secret'], 'drive-secret');

    // A secret stored for the calendar itself comes first.
    secrets.values['calendar.desktop.secret.client'] = 'calendar-secret';
    await calendar.invalidateToken();
    await calendar.accessToken();
    expect(sent.last['client_secret'], 'calendar-secret');
  });

  test('without any stored secret the token request has none', () async {
    final secrets = _Secrets()
      ..values['calendar.desktop.credentials'] = jsonEncode({
        'clientId': 'client',
        'refreshToken': 'refresh',
      });
    final sent = <Map<String, String>>[];
    final calendar = DesktopCalendarAuth(
      clientId: 'client',
      secrets: secrets,
      client: MockClient((request) async {
        sent.add(request.bodyFields);
        return http.Response(
          jsonEncode({'access_token': 'access', 'expires_in': 3600}),
          200,
        );
      }),
    );
    addTearDown(calendar.close);
    await calendar.restore();
    await calendar.accessToken();
    expect(sent.single.containsKey('client_secret'), isFalse);
  });
}
