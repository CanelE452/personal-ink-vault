import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ink_vault_core/drive.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:test/test.dart';

void main() {
  late String vaultId;
  setUp(() => vaultId = newId());
  DriveRemoteStore transport(
    Future<http.Response> Function(http.Request) handler,
  ) => DriveRemoteStore(
    accessToken: () async => 'test-access-token',
    client: MockClient(handler),
  );
  Map<String, dynamic> metadata(
    String id,
    String type, {
    String? hash,
    int? length,
    String? revisionId,
  }) => {
    'id': id,
    'name': id,
    'parents': ['folder'],
    'trashed': false,
    'mimeType': type == 'vault'
        ? 'application/vnd.google-apps.folder'
        : 'application/octet-stream',
    'appProperties': {
      'vaultId': vaultId,
      'format': 'ink-vault-v1',
      'type': type,
      if (hash != null) 'sha256': hash,
      if (length != null) 'length': '$length',
      if (revisionId != null) 'revisionId': revisionId,
    },
  };
  test('discovers app-created vaults with paginated scoped query and bearer header', () async {
    var calls = 0;
    final drive = transport((r) async {
      expect(r.headers['authorization'], 'Bearer test-access-token');
      expect(
        r.url.queryParameters['q'],
        contains("appProperties has { key='format'"),
      );
      calls++;
      return http.Response(
        jsonEncode({
          'files': [metadata('f$calls', 'vault')],
          if (calls == 1) 'nextPageToken': 'page2',
        }),
        200,
      );
    });
    final vaults = await drive.listVaults();
    expect(vaults, hasLength(2));
    expect(calls, 2);
    drive.close();
  });
  test('resumable blob upload preserves reserved ID and validates existing bytes on retry', () async {
    final bytes = Uint8List.fromList(utf8.encode('payload'));
    final ref = BlobRef(
      hash: sha256.convert(bytes).toString(),
      length: bytes.length,
    );
    var committed = false, posts = 0;
    final drive = transport((r) async {
      if (r.method == 'GET' && r.url.queryParameters['alt'] == 'media')
        return http.Response.bytes(bytes, 200);
      if (r.method == 'GET')
        return committed
            ? http.Response(
                jsonEncode(
                  metadata(
                    'reserved',
                    'blob',
                    hash: ref.hash,
                    length: ref.length,
                  ),
                ),
                200,
              )
            : http.Response('{}', 404);
      if (r.method == 'POST') {
        posts++;
        expect(jsonDecode(r.body)['id'], 'reserved');
        expect(r.url.queryParameters['uploadType'], 'resumable');
        return http.Response(
          '',
          200,
          headers: {'location': 'https://www.googleapis.com/upload/session'},
        );
      }
      expect(r.headers['content-range'], 'bytes 0-6/7');
      committed = true;
      throw http.ClientException('response lost');
    });
    final remote = drive.bind(
      DriveVault(id: 'folder', vaultId: vaultId, name: 'test'),
    );
    await expectLater(
      remote.putBlob(ref, bytes, 'reserved'),
      throwsA(isA<RemoteException>()),
    );
    await remote.putBlob(ref, bytes, 'reserved');
    expect(posts, 1);
    drive.close();
  });
  test('folder creation and connection preserve vault identity and private app properties', () async {
    Map<String, dynamic>? saved;
    final drive = transport((r) async {
      if (r.url.path.endsWith('/generateIds'))
        return http.Response('{"ids":["reserved-folder"]}', 200);
      if (r.method == 'GET')
        return saved == null
            ? http.Response('{}', 404)
            : http.Response(jsonEncode(saved), 200);
      saved = jsonDecode(r.body) as Map<String, dynamic>;
      expect(saved!['id'], 'reserved-folder');
      expect(saved!['mimeType'], 'application/vnd.google-apps.folder');
      expect((saved!['appProperties'] as Map)['vaultId'], vaultId);
      expect(saved!.containsKey('permissions'), isFalse);
      return http.Response(jsonEncode(saved), 200);
    });
    final id = await drive.generateId();
    final created = await drive.createVault(vaultId: vaultId, intentFileId: id);
    expect(created.id, id);
    expect((await drive.connectVault(id)).vaultId, vaultId);
    expect(
      (await drive.createVault(vaultId: vaultId, intentFileId: id)).id,
      id,
    );
    drive.close();
  });
  test(
    'large blob upload advances only acknowledged resumable chunk offsets',
    () async {
      final bytes = Uint8List(1024 * 1024 + 7);
      final ref = BlobRef(
        hash: sha256.convert(bytes).toString(),
        length: bytes.length,
      );
      var puts = 0;
      final drive = transport((r) async {
        if (r.method == 'GET') return http.Response('{}', 404);
        if (r.method == 'POST')
          return http.Response(
            '',
            200,
            headers: {'location': 'https://www.googleapis.com/upload/session'},
          );
        puts++;
        if (puts == 1) {
          expect(r.bodyBytes, hasLength(1024 * 1024));
          expect(r.headers['content-range'], 'bytes 0-1048575/1048583');
          return http.Response('', 308, headers: {'range': 'bytes=0-1048575'});
        }
        expect(r.bodyBytes, hasLength(7));
        expect(r.headers['content-range'], 'bytes 1048576-1048582/1048583');
        return http.Response('{"id":"reserved"}', 200);
      });
      await drive
          .bind(DriveVault(id: 'folder', vaultId: vaultId, name: 'test'))
          .putBlob(ref, bytes, 'reserved');
      expect(puts, 2);
      drive.close();
    },
  );
  test(
    'resumable redirect cannot send a token to an untrusted server',
    () async {
      final bytes = Uint8List.fromList([1]);
      final ref = BlobRef(hash: sha256.convert(bytes).toString(), length: 1);
      var requests = 0;
      final drive = transport((r) async {
        requests++;
        if (r.method == 'GET') return http.Response('{}', 404);
        return http.Response(
          '',
          200,
          headers: {'location': 'https://attacker.invalid/collect'},
        );
      });
      await expectLater(
        drive
            .bind(DriveVault(id: 'folder', vaultId: vaultId, name: 'test'))
            .putBlob(ref, bytes, 'reserved'),
        throwsFormatException,
      );
      expect(requests, 2);
      drive.close();
    },
  );
  test(
    'reused file ID with mismatched metadata cannot overwrite foreign data',
    () async {
      final bytes = Uint8List.fromList([1]);
      final ref = BlobRef(hash: sha256.convert(bytes).toString(), length: 1);
      final drive = transport(
        (r) async => http.Response(
          jsonEncode(metadata('same', 'blob', hash: 'a' * 64, length: 1)),
          200,
        ),
      );
      await expectLater(
        drive
            .bind(DriveVault(id: 'folder', vaultId: vaultId, name: 'test'))
            .putBlob(ref, bytes, 'same'),
        throwsFormatException,
      );
      drive.close();
    },
  );
  test('change pages retain removed IDs and next/new cursor fields', () async {
    final drive = transport(
      (r) async => http.Response(
        jsonEncode({
          'changes': [
            {'fileId': 'gone', 'removed': true},
            {
              'fileId': 'r',
              'file': metadata('r', 'manifest', revisionId: newId()),
            },
            {
              'fileId': 'other',
              'file': {
                ...metadata('other', 'manifest'),
                'parents': ['other-folder'],
              },
            },
          ],
          'nextPageToken': 'next',
          'newStartPageToken': 'end',
        }),
        200,
      ),
    );
    final page = await drive
        .bind(DriveVault(id: 'folder', vaultId: vaultId, name: 'test'))
        .readChanges('cursor');
    expect(page.changes.map((c) => c.fileId), ['gone', 'r']);
    expect(page.changes.first.removed, isTrue);
    expect(page.nextPageToken, 'next');
    expect(page.newStartPageToken, 'end');
    drive.close();
  });
  test('status classes distinguish authentication, quota, retry and invalid cursor', () async {
    for (final entry in [
      (401, 'auth', RemoteFailure.authentication),
      (403, 'insufficientPermissions', RemoteFailure.authentication),
      (403, 'storageQuotaExceeded', RemoteFailure.permanent),
      (429, 'rateLimitExceeded', RemoteFailure.retryable),
      (503, 'backendError', RemoteFailure.retryable),
      (410, 'gone', RemoteFailure.invalidCursor),
    ]) {
      final drive = transport(
        (r) async => http.Response(
          jsonEncode({
            'error': {
              'errors': [
                {'reason': entry.$2},
              ],
            },
          }),
          entry.$1,
        ),
      );
      final remote = drive.bind(
        DriveVault(id: 'folder', vaultId: vaultId, name: 'test'),
      );
      await expectLater(
        remote.readChanges('x'),
        throwsA(
          isA<RemoteException>().having((e) => e.failure, 'failure', entry.$3),
        ),
      );
      drive.close();
    }
  });
  test('foreign vault and corrupt blob are rejected before import', () async {
    final bytes = Uint8List.fromList([1]);
    final ref = BlobRef(hash: sha256.convert(bytes).toString(), length: 1);
    final drive = transport((r) async {
      if (r.url.path.endsWith('/files'))
        return http.Response(
          jsonEncode({
            'files': [metadata('blob', 'blob', hash: ref.hash, length: 1)],
          }),
          200,
        );
      return http.Response.bytes([2], 200);
    });
    await expectLater(
      drive
          .bind(DriveVault(id: 'folder', vaultId: vaultId, name: 'test'))
          .readBlob(ref),
      throwsFormatException,
    );
    drive.close();
  });
}
