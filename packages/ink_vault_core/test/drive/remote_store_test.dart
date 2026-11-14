import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ink_vault_core/drive.dart';
import 'package:ink_vault_core/ink_vault_core.dart';
import 'package:test/test.dart';

class _UploadCheckpoint implements DriveUploadSessions {
  String? value;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String value) async => this.value = value;

  @override
  Future<void> clear() async => value = null;
}

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
    int version = 1,
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
      'format': 'ink-vault-v$version',
      'type': type,
      if (hash != null) 'sha256': hash,
      if (length != null) 'length': '$length',
      if (revisionId != null) 'revisionId': revisionId,
    },
  };
  test(
    'discovery and connection distinguish v1 and v2 vault formats',
    () async {
      final drive = transport((r) async {
        if (r.url.path.endsWith('/files')) {
          final query = r.url.queryParameters['q']!;
          expect(query, contains("value='ink-vault-v1'"));
          expect(query, contains("value='ink-vault-v2'"));
          return http.Response(
            jsonEncode({
              'files': [
                metadata('old', 'vault'),
                metadata('new', 'vault', version: 2),
              ],
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode(metadata('new', 'vault', version: 2)),
          200,
        );
      });
      expect((await drive.listVaults()).map((v) => v.formatVersion), [1, 2]);
      expect((await drive.connectVault('new')).formatVersion, 2);
      expect(
        () => DriveVault(
          id: 'bad',
          vaultId: vaultId,
          name: 'bad',
          formatVersion: 3,
        ),
        throwsFormatException,
      );
      drive.close();
    },
  );

  test(
    'v2 creation retries preserve the reserved ID and reject format collisions',
    () async {
      Map<String, dynamic>? saved;
      var posts = 0;
      final drive = transport((r) async {
        if (r.method == 'GET')
          return saved == null
              ? http.Response('{}', 404)
              : http.Response(jsonEncode(saved), 200);
        posts++;
        saved = jsonDecode(r.body) as Map<String, dynamic>;
        expect((saved!['appProperties'] as Map)['format'], 'ink-vault-v2');
        return http.Response(jsonEncode(saved), 200);
      });
      final created = await drive.createVault(
        vaultId: vaultId,
        intentFileId: 'reserved',
        formatVersion: 2,
      );
      expect(created.formatVersion, 2);
      expect(
        (await drive.createVault(
          vaultId: vaultId,
          intentFileId: 'reserved',
          formatVersion: 2,
        )).id,
        'reserved',
      );
      expect(posts, 1);
      await expectLater(
        drive.createVault(vaultId: vaultId, intentFileId: 'reserved'),
        throwsFormatException,
      );
      drive.close();
    },
  );

  test(
    'bound v2 queries exclude v1 manifests and reject v2 publication to v1',
    () async {
      var requests = 0;
      final drive = transport((r) async {
        requests++;
        expect(r.url.queryParameters['q'], contains("value='ink-vault-v2'"));
        return http.Response(
          jsonEncode({
            'files': [
              metadata('old', 'manifest'),
              metadata('new', 'manifest', version: 2),
            ],
          }),
          200,
        );
      });
      final remote = drive.bind(
        DriveVault(
          id: 'folder',
          vaultId: vaultId,
          name: 'v2',
          formatVersion: 2,
        ),
      );
      expect((await remote.listManifests()).changes.map((c) => c.fileId), [
        'new',
      ]);
      final newer = RevisionRecord(
        vaultId: vaultId,
        entityId: newId(),
        kind: EntityKind.folder,
        revisionId: newId(),
        parentRevisionIds: [],
        deviceId: newId(),
        blobs: {},
        formatVersion: 2,
      );
      await expectLater(
        drive
            .bind(DriveVault(id: 'folder', vaultId: vaultId, name: 'v1'))
            .publishRevision(newer, 'reserved'),
        throwsFormatException,
      );
      expect(requests, 1);
      drive.close();
    },
  );

  test('v2 upload metadata and manifest media retain their format', () async {
    final record = RevisionRecord(
      vaultId: vaultId,
      entityId: newId(),
      kind: EntityKind.folder,
      revisionId: newId(),
      parentRevisionIds: [],
      deviceId: newId(),
      blobs: {},
      formatVersion: 2,
    );
    Map<String, dynamic>? saved;
    Uint8List? media;
    final drive = transport((r) async {
      if (r.method == 'GET' && r.url.queryParameters['alt'] == 'media')
        return http.Response.bytes(media!, 200);
      if (r.method == 'GET')
        return saved == null
            ? http.Response('{}', 404)
            : http.Response(jsonEncode(saved), 200);
      if (r.method == 'POST') {
        saved = jsonDecode(r.body) as Map<String, dynamic>;
        expect((saved!['appProperties'] as Map)['format'], 'ink-vault-v2');
        return http.Response(
          '',
          200,
          headers: {'location': 'https://www.googleapis.com/upload/session'},
        );
      }
      media = r.bodyBytes;
      return http.Response('{"id":"reserved"}', 200);
    });
    final remote = drive.bind(
      DriveVault(id: 'folder', vaultId: vaultId, name: 'v2', formatVersion: 2),
    );
    await remote.publishRevision(record, 'reserved');
    expect((await remote.readManifest('reserved')).toJson(), record.toJson());
    drive.close();
  });
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
  for (final reopen in [false, true]) {
    test(
      'retries probe accepted PDF bytes after interruptions${reopen ? ' across new clients' : ''}',
      () async {
        const chunkSize = 1024 * 1024;
        final bytes = Uint8List.fromList([
          ...ascii.encode('%PDF-1.7\n'),
          ...List<int>.generate(chunkSize + 14, (index) => index % 251),
        ]);
        final ref = BlobRef(
          hash: sha256.convert(bytes).toString(),
          length: bytes.length,
        );
        final accepted = BytesBuilder();
        final chunks = <String>[];
        final probes = <int>[];
        var posts = 0;
        Future<http.Response> handle(http.Request r) async {
          if (r.method == 'GET') return http.Response('{}', 404);
          if (r.method == 'POST') {
            posts++;
            expect(
              posts,
              1,
              reason: 'reuse the server session after interruption',
            );
            expect(jsonDecode(r.body)['id'], 'reserved');
            return http.Response(
              '',
              200,
              headers: {'location': 'https://www.googleapis.com/upload/pdf'},
            );
          }
          expect(r.method, 'PUT');
          expect(r.url.path, '/upload/pdf');
          final range = r.headers['content-range']!;
          if (range == 'bytes */${ref.length}') {
            expect(r.bodyBytes, isEmpty);
            probes.add(accepted.length);
            return http.Response(
              '',
              308,
              headers: {'range': 'bytes=0-${accepted.length - 1}'},
            );
          }
          final offset = accepted.length;
          expect(
            range,
            'bytes $offset-${offset + r.bodyBytes.length - 1}/${ref.length}',
          );
          chunks.add(range);
          if (offset == 0) {
            accepted.add(r.bodyBytes);
            return http.Response(
              '',
              308,
              headers: {'range': 'bytes=0-${chunkSize - 1}'},
            );
          }
          if (offset == chunkSize) {
            accepted.add(r.bodyBytes.sublist(0, 4));
            throw http.ClientException('connection interrupted');
          }
          if (offset == chunkSize + 4) {
            accepted.add(r.bodyBytes.sublist(0, 3));
            return http.Response('', 503, headers: {'retry-after': '2'});
          }
          expect(offset, chunkSize + 7);
          accepted.add(r.bodyBytes);
          return http.Response('{"id":"reserved"}', 200);
        }

        final vault = DriveVault(id: 'folder', vaultId: vaultId, name: 'test');
        final checkpoint = reopen ? _UploadCheckpoint() : null;
        var drive = transport(handle);
        addTearDown(() => drive.close());
        var remote = drive.bind(vault, uploadSessions: checkpoint);
        for (final code in [null, 503]) {
          await expectLater(
            remote.putBlob(ref, bytes, 'reserved'),
            throwsA(
              isA<RemoteException>()
                  .having((e) => e.failure, 'failure', RemoteFailure.retryable)
                  .having((e) => e.statusCode, 'status', code)
                  .having(
                    (e) => e.retryAfter,
                    'retry delay',
                    code == 503 ? const Duration(seconds: 2) : null,
                  ),
            ),
          );
          if (reopen) {
            expect(checkpoint!.value, isNotNull);
            drive.close();
            drive = transport(handle);
            remote = drive.bind(vault, uploadSessions: checkpoint);
          }
        }
        await remote.putBlob(ref, bytes, 'reserved');
        expect(posts, 1);
        expect(probes, [chunkSize + 4, chunkSize + 7]);
        expect(chunks, hasLength(4));
        expect(accepted.length, ref.length);
        expect(sha256.convert(accepted.takeBytes()).toString(), ref.hash);
        expect(checkpoint?.value, isNull);
      },
    );
  }
  for (final expired in [404, 410]) {
    test(
      'expired upload probe $expired restarts with the same reserved ID',
      () async {
        final bytes = Uint8List.fromList([1, 2, 3]);
        final ref = BlobRef(hash: sha256.convert(bytes).toString(), length: 3);
        var posts = 0;
        var probes = 0;
        Future<http.Response> handle(http.Request r) async {
          if (r.method == 'GET') return http.Response('{}', 404);
          if (r.method == 'POST') {
            expect(jsonDecode(r.body)['id'], 'reserved');
            return http.Response(
              '',
              200,
              headers: {
                'location':
                    'https://www.googleapis.com/upload/session-${++posts}',
              },
            );
          }
          expect(r.method, 'PUT');
          if (r.headers['content-range'] == 'bytes */3') {
            expect(r.url.path, '/upload/session-1');
            expect(r.bodyBytes, isEmpty);
            probes++;
            return http.Response('', expired);
          }
          expect(r.headers['content-range'], 'bytes 0-2/3');
          expect(r.bodyBytes, bytes);
          if (posts == 1) throw http.ClientException('connection interrupted');
          expect(r.url.path, '/upload/session-2');
          return http.Response('{"id":"reserved"}', 200);
        }

        final vault = DriveVault(id: 'folder', vaultId: vaultId, name: 'test');
        final checkpoint = _UploadCheckpoint();
        final initial = transport(handle);
        addTearDown(initial.close);
        await expectLater(
          initial
              .bind(vault, uploadSessions: checkpoint)
              .putBlob(ref, bytes, 'reserved'),
          throwsA(
            isA<RemoteException>().having(
              (e) => e.failure,
              'failure',
              RemoteFailure.retryable,
            ),
          ),
        );
        expect(checkpoint.value, isNotNull);
        final restarted = transport(handle);
        addTearDown(restarted.close);
        await restarted
            .bind(vault, uploadSessions: checkpoint)
            .putBlob(ref, bytes, 'reserved');
        expect(probes, 1);
        expect(posts, 2);
        expect(checkpoint.value, isNull);
      },
    );
  }
  for (final corrupt in [false, true]) {
    test(
      'completed upload probe verifies ${corrupt ? 'corrupt' : 'exact'} reserved content',
      () async {
        final bytes = Uint8List.fromList([1, 2, 3]);
        final ref = BlobRef(hash: sha256.convert(bytes).toString(), length: 3);
        final requests = <String>[];
        var probed = false;
        final drive = transport((r) async {
          final media = r.url.queryParameters['alt'] == 'media';
          requests.add('${r.method}${media ? ' media' : ''}');
          if (r.method == 'GET') {
            expect(r.url.path, '/drive/v3/files/reserved');
            if (!probed) return http.Response('{}', 404);
            if (media)
              return http.Response.bytes(corrupt ? [1, 2, 0] : bytes, 200);
            return http.Response(
              jsonEncode(
                metadata('reserved', 'blob', hash: ref.hash, length: 3),
              ),
              200,
            );
          }
          if (r.method == 'POST')
            return http.Response(
              '',
              200,
              headers: {
                'location': 'https://www.googleapis.com/upload/session',
              },
            );
          expect(r.url.path, '/upload/session');
          if (r.headers['content-range'] == 'bytes */3') {
            expect(r.bodyBytes, isEmpty);
            probed = true;
            return http.Response('{"id":"reserved"}', 201);
          }
          expect(r.headers['content-range'], 'bytes 0-2/3');
          throw http.ClientException('final response lost');
        });
        addTearDown(drive.close);
        final checkpoint = _UploadCheckpoint();
        final remote = drive.bind(
          DriveVault(id: 'folder', vaultId: vaultId, name: 'test'),
          uploadSessions: checkpoint,
        );
        await expectLater(
          remote.putBlob(ref, bytes, 'reserved'),
          throwsA(isA<RemoteException>()),
        );
        final retry = remote.putBlob(ref, bytes, 'reserved');
        if (corrupt) {
          await expectLater(retry, throwsFormatException);
        } else {
          await retry;
          expect(checkpoint.value, isNull);
        }
        expect(requests.where((method) => method == 'POST'), hasLength(1));
        expect(requests.where((method) => method == 'PUT'), hasLength(2));
        expect(requests.last, 'GET media');
      },
    );
  }
  for (final badRange in [false, true]) {
    test(
      'upload probe ${badRange ? 'rejects an out-of-bounds' : 'allows an absent'} range',
      () async {
        final bytes = Uint8List.fromList([1, 2, 3]);
        final ref = BlobRef(hash: sha256.convert(bytes).toString(), length: 3);
        var posts = 0, transfers = 0, probes = 0;
        final drive = transport((r) async {
          if (r.method == 'GET') return http.Response('{}', 404);
          if (r.method == 'POST') {
            posts++;
            return http.Response(
              '',
              200,
              headers: {
                'location': 'https://www.googleapis.com/upload/session',
              },
            );
          }
          expect(r.method, 'PUT');
          if (r.headers['content-range'] == 'bytes */3') {
            expect(r.bodyBytes, isEmpty);
            probes++;
            return http.Response(
              '',
              308,
              headers: {if (badRange) 'range': 'bytes=0-3'},
            );
          }
          expect(r.headers['content-range'], 'bytes 0-2/3');
          expect(r.bodyBytes, bytes);
          if (++transfers == 1)
            throw http.ClientException('connection interrupted');
          return http.Response('{"id":"reserved"}', 200);
        });
        addTearDown(drive.close);
        final remote = drive.bind(
          DriveVault(id: 'folder', vaultId: vaultId, name: 'test'),
        );
        await expectLater(
          remote.putBlob(ref, bytes, 'reserved'),
          throwsA(isA<RemoteException>()),
        );
        final retry = remote.putBlob(ref, bytes, 'reserved');
        if (badRange) {
          await expectLater(retry, throwsFormatException);
          expect(transfers, 1);
        } else {
          await retry;
          expect(transfers, 2);
        }
        expect(posts, 1);
        expect(probes, 1);
      },
    );
  }
  test(
    'empty blob uses distinct data and status requests after a lost response',
    () async {
      final bytes = Uint8List(0);
      final ref = BlobRef(hash: sha256.convert(bytes).toString(), length: 0);
      final ranges = <String?>[];
      var posts = 0;
      final drive = transport((r) async {
        if (r.method == 'GET') return http.Response('{}', 404);
        if (r.method == 'POST') {
          posts++;
          expect(r.headers['x-upload-content-length'], '0');
          return http.Response(
            '',
            200,
            headers: {'location': 'https://www.googleapis.com/upload/empty'},
          );
        }
        expect(r.method, 'PUT');
        expect(r.url.path, '/upload/empty');
        expect(r.bodyBytes, isEmpty);
        final range = r.headers['content-range'];
        ranges.add(range);
        if (ranges.length == 2) {
          expect(
            range,
            'bytes */0',
            reason: 'request status of the same session',
          );
          return http.Response('', 308);
        }
        expect(range, isNull, reason: 'submit the entire empty blob');
        if (ranges.length == 1)
          throw http.ClientException('connection interrupted');
        return http.Response('{"id":"reserved"}', 200);
      });
      addTearDown(drive.close);
      final checkpoint = _UploadCheckpoint();
      final remote = drive.bind(
        DriveVault(id: 'folder', vaultId: vaultId, name: 'test'),
        uploadSessions: checkpoint,
      );
      await expectLater(
        remote.putBlob(ref, bytes, 'reserved'),
        throwsA(isA<RemoteException>()),
      );
      await remote.putBlob(ref, bytes, 'reserved');
      expect(posts, 1);
      expect(ranges, [null, 'bytes */0', null]);
      expect(checkpoint.value, isNull);
    },
  );
  test('acknowledged chunk and probe can rotate the trusted session URL', () async {
    const chunkSize = 1024 * 1024;
    final bytes = Uint8List(chunkSize + 1)..last = 7;
    final ref = BlobRef(
      hash: sha256.convert(bytes).toString(),
      length: bytes.length,
    );
    final paths = <String>[];
    var posts = 0;
    Future<http.Response> handle(http.Request r) async {
      if (r.method == 'GET') return http.Response('{}', 404);
      if (r.method == 'POST') {
        posts++;
        return http.Response(
          '',
          200,
          headers: {'location': 'https://www.googleapis.com/upload/session-1'},
        );
      }
      expect(r.method, 'PUT');
      paths.add(r.url.path);
      final range = r.headers['content-range'];
      if (paths.length == 1 || paths.length == 3) {
        expect(
          range,
          paths.length == 1
              ? 'bytes 0-${chunkSize - 1}/${ref.length}'
              : 'bytes */${ref.length}',
        );
        return http.Response(
          '',
          308,
          headers: {
            'range': 'bytes=0-${chunkSize - 1}',
            'location':
                'https://www.googleapis.com/upload/session-${paths.length == 1 ? 2 : 3}',
          },
        );
      }
      expect(range, 'bytes $chunkSize-$chunkSize/${ref.length}');
      expect(r.bodyBytes, [7]);
      if (paths.length == 2)
        throw http.ClientException('connection interrupted');
      return http.Response('{"id":"reserved"}', 200);
    }

    final checkpoint = _UploadCheckpoint();
    final vault = DriveVault(id: 'folder', vaultId: vaultId, name: 'test');
    final first = transport(handle);
    addTearDown(first.close);
    await expectLater(
      first
          .bind(vault, uploadSessions: checkpoint)
          .putBlob(ref, bytes, 'reserved'),
      throwsA(isA<RemoteException>()),
    );
    final reopened = transport(handle);
    addTearDown(reopened.close);
    await reopened
        .bind(vault, uploadSessions: checkpoint)
        .putBlob(ref, bytes, 'reserved');
    expect(paths, [
      '/upload/session-1',
      '/upload/session-2',
      '/upload/session-2',
      '/upload/session-3',
    ]);
    expect(posts, 1);
    expect(checkpoint.value, isNull);
  });
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
