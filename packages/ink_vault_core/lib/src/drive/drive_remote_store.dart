import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:ink_vault_core/src/drive/remote_store.dart';
import 'package:ink_vault_core/src/revision.dart';

const _format = 'ink-vault-v1';
const _folderMime = 'application/vnd.google-apps.folder';
const _fields = 'id,name,mimeType,parents,trashed,appProperties,size';

String _fileId(String value) {
  if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value))
    throw const FormatException('Invalid Drive file ID');
  return value;
}

String _quoted(String value) =>
    value.replaceAll(r'\', r'\\').replaceAll("'", r"\'");
String _property(String key, String value) =>
    "appProperties has { key='$key' and value='${_quoted(value)}' }";
Map<String, dynamic> _properties(Map<String, dynamic> file) =>
    jsonObject(file['appProperties']);

class DriveVault {
  final String id;
  final String vaultId;
  final String name;
  DriveVault({required this.id, required this.vaultId, required this.name}) {
    _fileId(id);
    validateId(vaultId);
  }
}

/// Drive v3 transport. The caller owns OAuth and secure token storage.
/// No account tokens or resumable-session URLs are persisted or logged here.
class DriveRemoteStore {
  final Future<String> Function() accessToken;
  final http.Client _client;
  final Duration requestTimeout;
  DriveRemoteStore({
    required this.accessToken,
    http.Client? client,
    this.requestTimeout = const Duration(seconds: 90),
  }) : _client = client ?? http.Client();

  Uri _uri(String path, [Map<String, String> query = const {}]) =>
      Uri.https('www.googleapis.com', '/drive/v3/$path', query);

  Future<http.Response> _request(
    String method,
    Uri uri, {
    Map<String, String> headers = const {},
    List<int>? body,
    Set<int> allowed = const {200, 201},
  }) async {
    if (uri.scheme != 'https' || uri.host != 'www.googleapis.com')
      throw const FormatException('Untrusted Drive endpoint');
    String token;
    try {
      token = await accessToken();
    } catch (_) {
      throw RemoteException.authentication();
    }
    if (token.isEmpty || token.contains(RegExp(r'[\r\n]')))
      throw RemoteException.authentication();
    try {
      final request = http.Request(method, uri)..followRedirects = false;
      request.headers.addAll({'authorization': 'Bearer $token', ...headers});
      if (body != null) request.bodyBytes = body;
      final response = await http.Response.fromStream(
        await _client.send(request).timeout(requestTimeout),
      ).timeout(requestTimeout);
      if (allowed.contains(response.statusCode)) return response;
      String? reason;
      try {
        final error = jsonObject(jsonDecode(response.body))['error'];
        final errors = jsonObject(error)['errors'];
        if (errors is List && errors.isNotEmpty)
          reason = jsonObject(errors.first)['reason'] as String?;
      } catch (_) {
        /* Error bodies are untrusted and never included in status. */
      }
      final code = response.statusCode;
      final retrySeconds = int.tryParse(response.headers['retry-after'] ?? '');
      final failure =
          code == 401 ||
              code == 403 &&
                  {
                    'authError',
                    'insufficientPermissions',
                    'forbidden',
                  }.contains(reason)
          ? RemoteFailure.authentication
          : code == 410
          ? RemoteFailure.invalidCursor
          : code == 404
          ? RemoteFailure.missing
          : code == 408 ||
                code == 429 ||
                code >= 500 ||
                code == 403 &&
                    {
                      'rateLimitExceeded',
                      'userRateLimitExceeded',
                    }.contains(reason)
          ? RemoteFailure.retryable
          : RemoteFailure.permanent;
      throw RemoteException(
        failure,
        'Drive request failed (HTTP $code)',
        statusCode: code,
        retryAfter: retrySeconds == null
            ? null
            : Duration(seconds: retrySeconds),
      );
    } on TimeoutException {
      throw RemoteException.retryable('Drive request timed out');
    } on http.ClientException {
      throw RemoteException.retryable('Drive connection interrupted');
    } on IOException {
      throw RemoteException.retryable('Drive connection unavailable');
    }
  }

  Future<Map<String, dynamic>> _get(
    String path, [
    Map<String, String> query = const {},
  ]) async =>
      jsonObject(jsonDecode((await _request('GET', _uri(path, query))).body));
  Future<Map<String, dynamic>?> _metadata(String id) async {
    try {
      return await _get('files/${_fileId(id)}', {'fields': _fields});
    } on RemoteException catch (e) {
      if (e.failure == RemoteFailure.missing) return null;
      rethrow;
    }
  }

  DriveVault _vault(Map<String, dynamic> file) {
    final p = _properties(file);
    if (file['mimeType'] != _folderMime ||
        file['trashed'] == true ||
        p['format'] != _format ||
        p['type'] != 'vault') {
      throw const FormatException('Not an Ink Vault folder');
    }
    return DriveVault(
      id: file['id'] as String,
      vaultId: p['vaultId'] as String,
      name: file['name'] as String,
    );
  }

  Future<List<DriveVault>> listVaults() async {
    final result = <DriveVault>[];
    String? token;
    do {
      final page = await _get('files', {
        'q':
            "trashed=false and mimeType='$_folderMime' and ${_property('format', _format)} and ${_property('type', 'vault')}",
        'spaces': 'drive',
        'fields': 'nextPageToken,files($_fields)',
        'pageSize': '1000',
        if (token != null) 'pageToken': token,
      });
      for (final file in page['files'] as List) {
        result.add(_vault(jsonObject(file)));
      }
      token = page['nextPageToken'] as String?;
    } while (token != null);
    return result;
  }

  Future<String> generateId() async {
    final response = await _get('files/generateIds', {
      'count': '1',
      'space': 'drive',
      'type': 'files',
    });
    return _fileId((response['ids'] as List).single as String);
  }

  Future<DriveVault> createVault({
    required String vaultId,
    String name = 'Personal Ink Vault',
    String? intentFileId,
  }) async {
    validateId(vaultId);
    final id = intentFileId ?? await generateId();
    final existing = await _metadata(id);
    if (existing != null) {
      final vault = _vault(existing);
      if (vault.vaultId != vaultId)
        throw const FormatException('Vault ID collision');
      return vault;
    }
    final body = {
      'id': id,
      'name': name,
      'mimeType': _folderMime,
      'appProperties': {'vaultId': vaultId, 'format': _format, 'type': 'vault'},
    };
    try {
      final response = await _request(
        'POST',
        _uri('files', {'fields': _fields}),
        headers: {'content-type': 'application/json; charset=utf-8'},
        body: utf8.encode(jsonEncode(body)),
      );
      return _vault(jsonObject(jsonDecode(response.body)));
    } on RemoteException catch (e) {
      if (e.statusCode != 409) rethrow;
      final vault = await connectVault(id);
      if (vault.vaultId != vaultId)
        throw const FormatException('Vault ID collision');
      return vault;
    }
  }

  Future<DriveVault> connectVault(String folderId) async {
    final metadata = await _metadata(folderId);
    if (metadata == null)
      throw RemoteException.missing('Vault folder unavailable');
    return _vault(metadata);
  }

  RemoteStore bind(DriveVault vault) => _BoundDrive(this, vault);
  void close() => _client.close();
}

class _BoundDrive implements RemoteStore {
  final DriveRemoteStore drive;
  final DriveVault vault;
  _BoundDrive(this.drive, this.vault);
  @override
  String get vaultId => vault.vaultId;
  @override
  String get remoteId => vault.id;
  String _query(String type) =>
      "trashed=false and '${_quoted(vault.id)}' in parents and ${_property('vaultId', vaultId)} and ${_property('format', _format)} and ${_property('type', type)}";
  bool _belongs(Map<String, dynamic> file, String type) {
    final p = file['appProperties'];
    final parents = file['parents'];
    return file['trashed'] != true &&
        p is Map &&
        p['vaultId'] == vaultId &&
        p['format'] == _format &&
        p['type'] == type &&
        parents is List &&
        parents.contains(vault.id);
  }

  @override
  Future<String> generateId() => drive.generateId();
  @override
  Future<String?> findBlob(BlobRef ref) async {
    String? pageToken;
    do {
      final page = await drive._get('files', {
        'q':
            "${_query('blob')} and ${_property('sha256', ref.hash)} and ${_property('length', '${ref.length}')}",
        'spaces': 'drive',
        'pageSize': '1000',
        'fields': 'nextPageToken,files($_fields)',
        if (pageToken != null) 'pageToken': pageToken,
      });
      for (final value in page['files'] as List) {
        final file = jsonObject(value);
        if (_belongs(file, 'blob') &&
            _properties(file)['sha256'] == ref.hash &&
            _properties(file)['length'] == '${ref.length}')
          return _fileId(file['id'] as String);
      }
      pageToken = page['nextPageToken'] as String?;
    } while (pageToken != null);
    return null;
  }

  Future<Uint8List> _media(String id) async => (await drive._request(
    'GET',
    drive._uri('files/${_fileId(id)}', {'alt': 'media'}),
  )).bodyBytes;
  void _validateBytes(BlobRef ref, List<int> bytes) {
    if (bytes.length != ref.length ||
        sha256.convert(bytes).toString() != ref.hash)
      throw const FormatException('Drive blob hash or length mismatch');
  }

  @override
  Future<Uint8List> readBlob(BlobRef ref) async {
    final id = await findBlob(ref);
    if (id == null)
      throw RemoteException.missing('Referenced Drive blob unavailable');
    final bytes = await _media(id);
    _validateBytes(ref, bytes);
    return bytes;
  }

  Future<bool> _verifyExisting(
    String id,
    Map<String, String> props,
    Uint8List bytes,
  ) async {
    final existing = await drive._metadata(id);
    if (existing == null) return false;
    final p = _properties(existing);
    if (!_belongs(existing, props['type']!) ||
        props.entries.any((e) => p[e.key] != e.value))
      throw const FormatException('Drive immutable file ID collision');
    final actual = await _media(id);
    if (actual.length != bytes.length ||
        sha256.convert(actual) != sha256.convert(bytes))
      throw const FormatException('Drive immutable content mismatch');
    return true;
  }

  Future<void> _upload(
    String id,
    String name,
    Uint8List bytes,
    Map<String, String> props,
  ) async {
    _fileId(id);
    if (await _verifyExisting(id, props, bytes)) return;
    final metadata = {
      'id': id,
      'name': name,
      'parents': [vault.id],
      'mimeType': 'application/octet-stream',
      'appProperties': props,
    };
    http.Response begin;
    try {
      begin = await drive._request(
        'POST',
        Uri.https('www.googleapis.com', '/upload/drive/v3/files', {
          'uploadType': 'resumable',
          'fields': 'id',
        }),
        headers: {
          'content-type': 'application/json; charset=utf-8',
          'x-upload-content-type': 'application/octet-stream',
          'x-upload-content-length': '${bytes.length}',
        },
        body: utf8.encode(jsonEncode(metadata)),
      );
    } on RemoteException catch (e) {
      if (e.statusCode == 409 && await _verifyExisting(id, props, bytes))
        return;
      rethrow;
    }
    final location = begin.headers['location'];
    if (location == null)
      throw const FormatException('Drive resumable session missing');
    final session = Uri.parse(location);
    const chunkSize = 1024 * 1024;
    var offset = 0;
    do {
      final end = min(offset + chunkSize, bytes.length);
      final response = await drive._request(
        'PUT',
        session,
        headers: {
          'content-type': 'application/octet-stream',
          'content-range': bytes.isEmpty
              ? 'bytes */0'
              : 'bytes $offset-${end - 1}/${bytes.length}',
        },
        body: bytes.sublist(offset, end),
        allowed: {200, 201, 308},
      );
      if (response.statusCode == 308) {
        final range = response.headers['range'];
        final match = range == null
            ? null
            : RegExp(r'^bytes=0-(\d+)$').firstMatch(range);
        if (match == null)
          throw RemoteException.retryable('Drive upload progress unavailable');
        final next = int.parse(match[1]!) + 1;
        if (next <= offset || next > end)
          throw const FormatException('Invalid Drive upload progress');
        offset = next;
      } else {
        if (end != bytes.length)
          throw const FormatException('Drive completed upload prematurely');
        return;
      }
    } while (offset < bytes.length);
    throw RemoteException.retryable('Drive upload did not commit');
  }

  Map<String, String> _props(String type) => {
    'vaultId': vaultId,
    'format': _format,
    'type': type,
  };
  @override
  Future<void> putBlob(
    BlobRef ref,
    Uint8List bytes,
    String intentFileId,
  ) async {
    _validateBytes(ref, bytes);
    await _upload(intentFileId, ref.hash, bytes, {
      ..._props('blob'),
      'sha256': ref.hash,
      'length': '${ref.length}',
    });
  }

  @override
  Future<void> publishRevision(
    RevisionRecord record,
    String intentFileId,
  ) async {
    if (record.vaultId != vaultId)
      throw const FormatException('Foreign vault revision');
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(record.toJson())));
    await _upload(intentFileId, '${record.revisionId}.json', bytes, {
      ..._props('manifest'),
      'revisionId': record.revisionId,
      'sha256': sha256.convert(bytes).toString(),
      'length': '${bytes.length}',
    });
  }

  @override
  Future<RevisionRecord> readManifest(String fileId) async {
    final metadata = await drive._metadata(fileId);
    if (metadata == null)
      throw RemoteException.missing('Drive manifest unavailable');
    if (!_belongs(metadata, 'manifest'))
      throw const FormatException('Foreign Drive manifest');
    final bytes = await _media(fileId);
    final p = _properties(metadata);
    if (p['sha256'] != sha256.convert(bytes).toString() ||
        p['length'] != '${bytes.length}')
      throw const FormatException('Drive manifest checksum mismatch');
    final record = RevisionRecord.fromJson(
      jsonObject(jsonDecode(utf8.decode(bytes))),
    );
    if (record.vaultId != vaultId || p['revisionId'] != record.revisionId)
      throw const FormatException('Drive manifest identity mismatch');
    return record;
  }

  @override
  Future<String> startPageToken() async =>
      (await drive._get('changes/startPageToken', {
            'fields': 'startPageToken',
          }))['startPageToken']
          as String;
  @override
  Future<RemotePage> listManifests({String? pageToken}) async {
    final page = await drive._get('files', {
      'q': _query('manifest'),
      'spaces': 'drive',
      'pageSize': '1000',
      'fields': 'nextPageToken,files($_fields)',
      if (pageToken != null) 'pageToken': pageToken,
    });
    return RemotePage(
      (page['files'] as List)
          .map(jsonObject)
          .where((f) => _belongs(f, 'manifest'))
          .map((f) => RemoteChange(_fileId(f['id'] as String)))
          .toList(),
      nextPageToken: page['nextPageToken'] as String?,
    );
  }

  @override
  Future<RemotePage> readChanges(String pageToken) async {
    final page = await drive._get('changes', {
      'pageToken': pageToken,
      'spaces': 'drive',
      'pageSize': '1000',
      'fields':
          'nextPageToken,newStartPageToken,changes(fileId,removed,file($_fields))',
      'includeRemoved': 'true',
    });
    final changes = <RemoteChange>[];
    for (final value in page['changes'] as List) {
      final change = jsonObject(value);
      final file = change['file'];
      if (change['removed'] == true ||
          file is Map<String, dynamic> && file['trashed'] == true) {
        changes.add(
          RemoteChange(_fileId(change['fileId'] as String), removed: true),
        );
      } else if (file is Map<String, dynamic> && _belongs(file, 'manifest')) {
        changes.add(RemoteChange(_fileId(change['fileId'] as String)));
      }
    }
    return RemotePage(
      changes,
      nextPageToken: page['nextPageToken'] as String?,
      newStartPageToken: page['newStartPageToken'] as String?,
    );
  }

  @override
  void close() => drive.close();
}
